#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <substrate.h>
#import <dlfcn.h>
#import <unistd.h>

// PleaseDontStopTheMusic — iOS 13 build
//
// Core rule (unchanged from upstream v2.3.1): an app that activates a
// non-mixable session while something else is already playing is demoted to
// AVAudioSessionCategoryOptionMixWithOthers, so the existing music keeps the
// primary session (and its lock screen / Control Center controls) instead of
// being interrupted.
//
// iOS 13 additions:
//   1. Three independent "is something else playing" probes, because
//      isOtherAudioPlaying alone is unreliable on 13.x inside a process that
//      has not activated its session yet:
//        a. isOtherAudioPlaying
//        b. secondaryAudioShouldBeSilencedHint
//        c. MediaRemote now-playing-is-playing query (private framework,
//           50 ms cap, result cached for 1 s)
//   2. Legacy AudioSession C API hooks (AudioSessionSetActive /
//      AudioSessionSetProperty), still used by plenty of iOS 13 era apps.
//   3. Per-app overrides via /var/mobile/Library/Preferences/com.xxhhlk.pdstm.plist
//        AlwaysMix  (array of bundle ids) — always demoted to mixing
//        NeverMix   (array of bundle ids) — never touched
//        AlwaysMixAll (bool)              — demote every app except NeverMix
//        DebugLog   (bool, default YES)   — write /var/mobile/Library/Logs/PDSTM.log
//
// TikTok Live PiP keeps its upstream special case: it stays primary so its
// sample-buffer renderer keeps ticking, and it asks the background music app to
// go secondary instead.

static NSString *const kBegin     = @"com.pdstm.pip.begin";
static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.xxhhlk.pdstm.plist";
static const unsigned long long kLogMaxBytes = 512 * 1024;

static NSString *gBundleID     = nil;
static BOOL      gIsVideoApp   = NO;   // TikTok: kept primary so its PiP clock runs
static BOOL      gSessionActive = NO;  // tracks setActive: state (are we playing?)
static BOOL      gAlwaysMixAll = NO;
static BOOL      gDebug        = YES;
static NSArray  *gAlwaysMix    = nil;
static NSArray  *gNeverMix     = nil;
static NSArray  *gForcePlayback = nil;

static __thread BOOL tInHook = NO;

#pragma mark - logging

static NSString *gLogFile = nil;

// Sandboxed apps cannot write to /var/mobile/Library/Logs, so fall back to the
// app's own container. Both files are readable from a root shell.
static NSString *PDSTMLogPath(void) {
    if (gLogFile) return gLogFile;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/var/mobile/Library/Logs";
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm isWritableFileAtPath:dir]) {
        gLogFile = [dir stringByAppendingPathComponent:@"PDSTM.log"];
    } else {
        gLogFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pdstm.log"];
    }
    return gLogFile;
}

static void PDSTMLog(NSString *fmt, ...) {
    if (!gDebug) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [df stringFromDate:[NSDate date]], gBundleID ?: @"?", msg];

    NSString *path = PDSTMLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs fileSize] > kLogMaxBytes) {
        [fm removeItemAtPath:path error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [fm createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

#pragma mark - config

static void PDSTMLoadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    id v = d[@"AlwaysMix"];
    if ([v isKindOfClass:[NSArray class]]) gAlwaysMix = v;
    v = d[@"NeverMix"];
    if ([v isKindOfClass:[NSArray class]]) gNeverMix = v;
    v = d[@"ForcePlayback"];
    if ([v isKindOfClass:[NSArray class]]) gForcePlayback = v;
    v = d[@"AlwaysMixAll"];
    if ([v respondsToSelector:@selector(boolValue)]) gAlwaysMixAll = [v boolValue];
    v = d[@"DebugLog"];
    if ([v respondsToSelector:@selector(boolValue)]) gDebug = [v boolValue];
}

#pragma mark - other-audio probes

// MediaRemote: MRMediaRemoteGetNowPlayingApplicationIsPlaying(queue, block)
typedef void (*PDSTMMRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));

static BOOL PDSTMMediaRemotePlaying(void) {
    static PDSTMMRIsPlayingFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                         RTLD_LAZY);
        if (h) fn = (PDSTMMRIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    });
    if (!fn) return NO;

    __block BOOL playing = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    fn(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(Boolean p) {
        playing = p;
        dispatch_semaphore_signal(sem);
    });
    // Blocks the caller at most 10 ms: this runs on whatever thread configures
    // the session, and a longer stall shows up as an audible glitch. The block
    // keeps `sem` alive if we time out.
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_MSEC));
    return playing;
}

static BOOL PDSTMMediaRemotePlayingCached(void) {
    static NSTimeInterval lastCheck = 0;
    static BOOL lastResult = NO;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastCheck < 1.0) return lastResult;
    lastCheck = now;
    lastResult = PDSTMMediaRemotePlaying();
    return lastResult;
}

// MediaRemote: MRMediaRemoteGetNowPlayingApplicationPID(queue, block)
//
// Whoever owns Now Playing must never be demoted to a mixable session: doing so
// hands the lock screen / Control Center transport to someone else and the
// "Now Playing" entry loses its track info. This is what kept happening to the
// music app itself when a video was playing alongside it.
typedef void (*PDSTMMRNowPlayingPIDFn)(dispatch_queue_t, void (^)(pid_t));

static PDSTMMRNowPlayingPIDFn PDSTMNowPlayingPIDFn(void) {
    static PDSTMMRNowPlayingPIDFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                         RTLD_LAZY);
        if (h) fn = (PDSTMMRNowPlayingPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    });
    return fn;
}

static BOOL PDSTMIsNowPlayingApp(void) {
    PDSTMMRNowPlayingPIDFn fn = PDSTMNowPlayingPIDFn();
    if (!fn) return NO;

    __block pid_t pid = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    fn(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(pid_t p) {
        pid = p;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_MSEC));
    return pid > 0 && pid == getpid();
}

static BOOL PDSTMIsNowPlayingAppCached(void) {
    static NSTimeInterval lastCheck = 0;
    static BOOL lastResult = NO;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastCheck < 1.0) return lastResult;
    lastCheck = now;
    lastResult = PDSTMIsNowPlayingApp();
    return lastResult;
}

static BOOL PDSTMOtherAudioPlaying(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (s.isOtherAudioPlaying) return YES;
    if (s.secondaryAudioShouldBeSilencedHint) return YES;
    // Last resort: a MediaRemote round trip is too slow to run on every hook
    // invocation, hence the 1 s cache.
    return PDSTMMediaRemotePlayingCached();
}

static BOOL PDSTMShouldMix(void);

// A single logical "configure my session" from an app can arrive as several
// nested calls (withOptions: → error: → mode:options:). Re-applying the same
// category a second time costs another route reconfiguration, which is audible
// as a short glitch, so identical requests are answered without touching the
// session again.
static BOOL PDSTMSessionAlreadyMixed(AVAudioSession *s, NSString *category, NSString *mode,
                                     AVAudioSessionCategoryOptions options) {
    if (![s.category isEqualToString:category]) return NO;
    if (mode && ![s.mode isEqualToString:mode]) return NO;
    AVAudioSessionCategoryOptions want = options | AVAudioSessionCategoryOptionMixWithOthers;
    return s.categoryOptions == want;
}

// Debug only: records every non-mixable session request together with the three
// probe results, so a failing case can be traced without guessing.
static void PDSTMProbeLog(NSString *what, NSString *category, AVAudioSessionCategoryOptions options) {
    if (!gDebug) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    BOOL other = s.isOtherAudioPlaying;
    BOOL hint = s.secondaryAudioShouldBeSilencedHint;
    // Only pay for the MediaRemote round trip when the cheap probes say nothing.
    BOOL mr = (other || hint) ? YES : PDSTMMediaRemotePlayingCached();
    PDSTMLog(@"probe %@ cat=%@ opts=0x%lx other=%d silencedHint=%d mr=%d mix=%d",
             what, category, (unsigned long)options, other, hint, mr, PDSTMShouldMix());
}

static BOOL PDSTMShouldMix(void) {
    if (gIsVideoApp) return NO;
    if (gNeverMix && [gNeverMix containsObject:gBundleID]) return NO;
    if (gAlwaysMix && [gAlwaysMix containsObject:gBundleID]) return YES;
    if (gAlwaysMixAll) return YES;
    // The app that currently owns Now Playing keeps the primary session, so the
    // lock screen / Control Center entry keeps its track info and controls.
    if (PDSTMIsNowPlayingAppCached()) return NO;
    return PDSTMOtherAudioPlaying();
}

#pragma mark - music side (TikTok PiP case, upstream behaviour)

static void PDSTMPost(NSString *name) { notify_post(name.UTF8String); }

static void PDSTMGoSecondary(void) {
    if (gIsVideoApp) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSString *cat = s.category;
    BOOL playbackish = [cat isEqualToString:AVAudioSessionCategoryPlayback]
                    || [cat isEqualToString:AVAudioSessionCategoryPlayAndRecord];
    if (!gSessionActive || !playbackish) return;
    if (s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers) return;
    PDSTMLog(@"pip: going secondary (cat=%@)", cat);
    [s setCategory:cat mode:s.mode
           options:(s.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers) error:nil];
    [s setActive:YES error:nil];
}

static void PDSTMDarwinCallback(CFNotificationCenterRef c, void *obs, CFStringRef name,
                                const void *obj, CFDictionaryRef info) {
    if ([(__bridge NSString *)name isEqualToString:kBegin]) PDSTMGoSecondary();
}

#pragma mark - policy

static BOOL PDSTMForcePlaybackForBundle(void) {
    return gForcePlayback && [gForcePlayback containsObject:gBundleID];
}

// Applies the tweak's policy to a requested category/options pair.
static void PDSTMApplyPolicy(NSString **category, AVAudioSessionCategoryOptions *options) {
    if ([*category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
        *category = AVAudioSessionCategoryAmbient;
    }
    if (PDSTMForcePlaybackForBundle()
        && [*category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        *category = AVAudioSessionCategoryPlayback;
        *options &= ~(AVAudioSessionCategoryOptionDefaultToSpeaker
                      | AVAudioSessionCategoryOptionAllowBluetooth);
    }
    *options |= AVAudioSessionCategoryOptionMixWithOthers;
}

// True when the live session still differs from what the policy wants.
static BOOL PDSTMSessionNeedsRewrite(AVAudioSession *s) {
    if (!(s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) return YES;
    if (PDSTMForcePlaybackForBundle()
        && [s.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) return YES;
    return NO;
}

#pragma mark - AVAudioSession hooks

%hook AVAudioSession

- (BOOL)setCategory:(NSString *)category error:(NSError **)outError {
    if (!tInHook && PDSTMShouldMix()) {
        NSString *eff = category;
        AVAudioSessionCategoryOptions opts = 0;
        PDSTMApplyPolicy(&eff, &opts);
        if (PDSTMSessionAlreadyMixed(self, eff, nil, 0)) {
            PDSTMLog(@"skip redundant setCategory:%@ error:", eff);
            return YES;
        }
        PDSTMLog(@"setCategory:%@ error: -> %@ opts=0x%lx", category, eff, (unsigned long)opts);
        tInHook = YES;
        BOOL r = [self setCategory:eff mode:AVAudioSessionModeDefault options:opts error:outError];
        tInHook = NO;
        return r;
    }
    return %orig;
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (![category isEqualToString:AVAudioSessionCategoryAmbient]) {
        PDSTMProbeLog(@"setCategory:mode:options:", category, options);
    }
    if (!tInHook && PDSTMShouldMix()) {
        NSString *eff = category;
        AVAudioSessionCategoryOptions opts = options;
        PDSTMApplyPolicy(&eff, &opts);
        if (PDSTMSessionAlreadyMixed(self, eff, mode, options)) {
            PDSTMLog(@"skip redundant setCategory:%@ mode:%@", eff, mode);
            return YES;
        }
        PDSTMLog(@"setCategory:%@ mode:%@ options:0x%lx -> %@ opts=0x%lx",
                 category, mode, (unsigned long)options, eff, (unsigned long)opts);
        category = eff;
        options = opts;
    }
    return %orig;
}

- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (!tInHook && PDSTMShouldMix()) {
        NSString *eff = category;
        AVAudioSessionCategoryOptions opts = options;
        PDSTMApplyPolicy(&eff, &opts);
        if (PDSTMSessionAlreadyMixed(self, eff, mode, options)) {
            PDSTMLog(@"skip redundant setCategory:%@ policy:%lu", eff, (unsigned long)policy);
            return YES;
        }
        PDSTMLog(@"setCategory:%@ mode:%@ policy:%lu options:0x%lx -> %@ opts=0x%lx",
                 category, mode, (unsigned long)policy, (unsigned long)options, eff, (unsigned long)opts);
        category = eff;
        options = opts;
    }
    return %orig;
}

- (BOOL)setCategory:(NSString *)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    if (!tInHook && PDSTMShouldMix()) {
        NSString *eff = category;
        AVAudioSessionCategoryOptions opts = options;
        PDSTMApplyPolicy(&eff, &opts);
        if (PDSTMSessionAlreadyMixed(self, eff, nil, options)) {
            PDSTMLog(@"skip redundant setCategory:%@ withOptions:0x%lx", eff, (unsigned long)options);
            return YES;
        }
        PDSTMLog(@"setCategory:%@ withOptions:0x%lx -> %@ opts=0x%lx",
                 category, (unsigned long)options, eff, (unsigned long)opts);
        category = eff;
        options = opts;
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    gSessionActive = active;
    if (active) PDSTMProbeLog(@"setActive:", self.category, self.categoryOptions);
    if (gIsVideoApp && active && self.isOtherAudioPlaying) PDSTMPost(kBegin);
    if (!tInHook && active && PDSTMShouldMix() && PDSTMSessionNeedsRewrite(self)) {
        NSString *cat = self.category;
        AVAudioSessionCategoryOptions opts = self.categoryOptions;
        PDSTMApplyPolicy(&cat, &opts);
        PDSTMLog(@"setActive:YES cat=%@ options:0x%lx -> %@ opts=0x%lx",
                 self.category, (unsigned long)self.categoryOptions, cat, (unsigned long)opts);
        tInHook = YES;
        [self setCategory:cat mode:self.mode options:opts error:nil];
        tInHook = NO;
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    gSessionActive = active;
    if (active) PDSTMProbeLog(@"setActive:withOptions:", self.category, self.categoryOptions);
    if (gIsVideoApp && active && self.isOtherAudioPlaying) PDSTMPost(kBegin);
    if (!tInHook && active && PDSTMShouldMix() && PDSTMSessionNeedsRewrite(self)) {
        NSString *cat = self.category;
        AVAudioSessionCategoryOptions opts = self.categoryOptions;
        PDSTMApplyPolicy(&cat, &opts);
        PDSTMLog(@"setActive:withOptions:0x%lx cat=%@ -> %@ opts=0x%lx",
                 (unsigned long)options, self.category, cat, (unsigned long)opts);
        tInHook = YES;
        [self setCategory:cat mode:self.mode options:opts error:nil];
        tInHook = NO;
    }
    return %orig;
}

%end

#pragma mark - legacy AudioSession C API hooks (iOS 13 era apps)

typedef OSStatus (*PDSTMSetActiveFn)(Boolean);
typedef OSStatus (*PDSTMSetPropertyFn)(AudioSessionPropertyID, UInt32, const void *);

static PDSTMSetActiveFn   origLegacySetActive   = NULL;
static PDSTMSetPropertyFn origLegacySetProperty = NULL;

static void PDSTMLegacyEnableMix(void);

static OSStatus PDSTMLegacySetActive(Boolean active) {
    if (!origLegacySetActive) return -1;
    if (active && !tInHook && PDSTMShouldMix()) {
        PDSTMLog(@"legacy AudioSessionSetActive(1) -> forced mix");
        PDSTMLegacyEnableMix();
    }
    return origLegacySetActive(active);
}

// The legacy API has no category+options call, so mixing is expressed through
// kAudioSessionProperty_OverrideCategoryMixWithOthers (UInt32, 1 = mix). Setting
// the category itself is left untouched: rewriting it to a CFStringRef category
// is fragile across SDK versions and unnecessary for the interruption fix.
static void PDSTMLegacyEnableMix(void) {
    if (!origLegacySetProperty) return;
    UInt32 one = 1;
    origLegacySetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(one), &one);
}

static OSStatus PDSTMLegacySetProperty(AudioSessionPropertyID prop, UInt32 size, const void *data) {
    if (!origLegacySetProperty) return -1;
    if (!tInHook && PDSTMShouldMix()
        && (prop == kAudioSessionProperty_AudioCategory
            || prop == kAudioSessionProperty_OverrideCategoryMixWithOthers)) {
        PDSTMLog(@"legacy AudioSessionSetProperty(prop=%u) -> force mix", (unsigned)prop);
        OSStatus st = origLegacySetProperty(prop, size, data);
        PDSTMLegacyEnableMix();
        return st;
    }
    return origLegacySetProperty(prop, size, data);
}

static void PDSTMInstallLegacyHooks(void) {
    void *h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    if (!h) return;
    void *p = dlsym(h, "AudioSessionSetActive");
    if (p) MSHookFunction(p, (void *)PDSTMLegacySetActive, (void **)&origLegacySetActive);
    p = dlsym(h, "AudioSessionSetProperty");
    if (p) MSHookFunction(p, (void *)PDSTMLegacySetProperty, (void **)&origLegacySetProperty);
    if (origLegacySetActive || origLegacySetProperty) {
        PDSTMLog(@"legacy AudioSession hooks installed (setActive=%d setProperty=%d)",
                 origLegacySetActive != NULL, origLegacySetProperty != NULL);
    }
}

#pragma mark - AudioUnit hooks
//
// Plenty of apps (UU Remote among them) never touch AVAudioSession. They just
// start an AudioUnit / AUGraph, and AudioToolbox activates the session behind
// their back. Nothing in the ObjC layer can see that, so the session has to be
// made mixable before the unit is started.

static void PDSTMEnsureMixable(NSString *why) {
    AVAudioSession *probe = [AVAudioSession sharedInstance];
    BOOL other = probe.isOtherAudioPlaying;
    BOOL hint = probe.secondaryAudioShouldBeSilencedHint;
    BOOL mr = (other || hint) ? YES : PDSTMMediaRemotePlayingCached();
    BOOL mix = PDSTMShouldMix();
    PDSTMLog(@"%@ probe other=%d silencedHint=%d mr=%d mix=%d cat=%@", why, other, hint, mr, mix, probe.category);
    if (!mix) return;
    AVAudioSession *s = probe;
    if (!PDSTMSessionNeedsRewrite(s)) {
        [s setActive:YES error:nil];
        return;
    }
    NSString *cat = s.category ?: AVAudioSessionCategoryAmbient;
    AVAudioSessionCategoryOptions opts = s.categoryOptions;
    PDSTMApplyPolicy(&cat, &opts);
    PDSTMLog(@"%@ -> rewrite cat=%@ opts=0x%lx", why, cat, (unsigned long)opts);
    tInHook = YES;
    [s setCategory:cat mode:s.mode options:opts error:nil];
    [s setActive:YES error:nil];
    tInHook = NO;
}

typedef OSStatus (*PDSTM_AudioOutputUnitStart_t)(AudioUnit);
typedef OSStatus (*PDSTM_AudioUnitInitialize_t)(AudioUnit);
typedef OSStatus (*PDSTM_AUGraphStart_t)(AUGraph);

static PDSTM_AudioOutputUnitStart_t origAudioOutputUnitStart = NULL;
static PDSTM_AudioUnitInitialize_t  origAudioUnitInitialize  = NULL;
static PDSTM_AUGraphStart_t         origAUGraphStart         = NULL;

static OSStatus PDSTM_AudioOutputUnitStart(AudioUnit unit) {
    PDSTMLog(@"AudioOutputUnitStart called");
    if (!tInHook) PDSTMEnsureMixable(@"AudioOutputUnitStart");
    return origAudioOutputUnitStart ? origAudioOutputUnitStart(unit) : -1;
}

static OSStatus PDSTM_AudioUnitInitialize(AudioUnit unit) {
    PDSTMLog(@"AudioUnitInitialize called");
    if (!tInHook) PDSTMEnsureMixable(@"AudioUnitInitialize");
    return origAudioUnitInitialize ? origAudioUnitInitialize(unit) : -1;
}

static OSStatus PDSTM_AUGraphStart(AUGraph graph) {
    PDSTMLog(@"AUGraphStart called");
    if (!tInHook) PDSTMEnsureMixable(@"AUGraphStart");
    return origAUGraphStart ? origAUGraphStart(graph) : -1;
}

static void PDSTMInstallToolboxHooks(void) {
    void *h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    if (!h) return;
    void *p = dlsym(h, "AudioOutputUnitStart");
    if (p) MSHookFunction(p, (void *)PDSTM_AudioOutputUnitStart, (void **)&origAudioOutputUnitStart);
    p = dlsym(h, "AudioUnitInitialize");
    if (p) MSHookFunction(p, (void *)PDSTM_AudioUnitInitialize, (void **)&origAudioUnitInitialize);
    p = dlsym(h, "AUGraphStart");
    if (p) MSHookFunction(p, (void *)PDSTM_AUGraphStart, (void **)&origAUGraphStart);
    PDSTMLog(@"AudioUnit hooks: start=%d init=%d graph=%d",
             origAudioOutputUnitStart != NULL, origAudioUnitInitialize != NULL, origAUGraphStart != NULL);
}

#pragma mark - entry

%ctor {
    gBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    PDSTMLoadPrefs();

    NSArray *video = @[ @"com.zhiliaoapp.musically",       // TikTok
                        @"com.zhiliaoapp.musically.go",
                        @"com.ss.iphone.ugc.Ame" ];        // TikTok (other region)
    gIsVideoApp = [video containsObject:gBundleID];

    if (gIsVideoApp) {
        [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidBecomeActiveNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) { PDSTMPost(kBegin); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationWillEnterForegroundNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) { PDSTMPost(kBegin); }];
        PDSTMPost(kBegin);
    } else {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            PDSTMDarwinCallback, (__bridge CFStringRef)kBegin, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }

    PDSTMInstallLegacyHooks();
    PDSTMInstallToolboxHooks();

    PDSTMLog(@"loaded (video=%d alwaysMixAll=%d alwaysMix=%@ neverMix=%@ forcePlayback=%@ nowPlayingGuard=%d)",
             gIsVideoApp, gAlwaysMixAll, gAlwaysMix ?: @[], gNeverMix ?: @[], gForcePlayback ?: @[],
             PDSTMNowPlayingPIDFn() != NULL);
}
