#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.xxhhlk.pdstm.plist";

static NSMutableDictionary *PDSTMReadPrefs(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath];
    return d ?: [NSMutableDictionary dictionary];
}

static void PDSTMWritePrefs(NSDictionary *prefs) {
    [prefs writeToFile:kPrefsPath atomically:YES];
}

static NSArray *PDSTMList(NSString *key) {
    id v = PDSTMReadPrefs()[key];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}

static void PDSTMSetList(NSString *key, NSArray *list) {
    NSMutableDictionary *d = PDSTMReadPrefs();
    d[key] = list;
    PDSTMWritePrefs(d);
}

// LSApplicationWorkspace is what Settings itself uses to enumerate installed
// applications. It lives in MobileCoreServices.
@interface LSApplicationProxy : NSObject
- (NSString *)localizedName;
- (NSString *)applicationIdentifier;
- (NSString *)applicationType;
- (NSURL *)bundleURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

static NSArray *PDSTMInstalledApps(void) {
    static NSArray *cached = nil;
    if (cached) return cached;

    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);

    NSMutableArray *apps = [NSMutableArray array];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        NSArray *all = [workspace performSelector:@selector(allInstalledApplications)];
        for (id proxy in all) {
            NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
                                 ? [proxy performSelector:@selector(applicationIdentifier)] : nil;
            NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                           ? [proxy performSelector:@selector(localizedName)] : nil;
            if (!identifier.length || !name.length) continue;

            BOOL isUserApp = NO;
            if ([proxy respondsToSelector:@selector(applicationType)]) {
                NSString *type = [proxy performSelector:@selector(applicationType)];
                isUserApp = [type isEqualToString:@"User"];
            }
            if (!isUserApp && [proxy respondsToSelector:@selector(bundleURL)]) {
                NSURL *url = [proxy performSelector:@selector(bundleURL)];
                isUserApp = [url.path hasPrefix:@"/var/containers/Bundle/Application"];
            }
            if (!isUserApp) continue;
            [apps addObject:@{ @"id": identifier, @"name": name }];
        }
    }

    cached = [apps sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return cached;
}

#pragma mark - Root pane

@interface PDSTMRootListController : PSListController
@end

@implementation PDSTMRootListController

- (PSSpecifier *)switchSpecifierNamed:(NSString *)name key:(NSString *)key fallback:(BOOL)fallback {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                       target:self
                                                          set:@selector(setSwitch:forSpecifier:)
                                                          get:@selector(getSwitch:)
                                                       detail:nil
                                                         cell:PSSwitchCell
                                                         edit:nil];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:@(fallback) forKey:@"fallback"];
    return spec;
}

- (PSSpecifier *)listSpecifierNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                       target:self
                                                          set:nil
                                                          get:nil
                                                       detail:NSClassFromString(@"PDSTMAppListController")
                                                         cell:PSLinkCell
                                                         edit:nil];
    [spec setProperty:key forKey:@"listKey"];
    NSUInteger count = PDSTMList(key).count;
    [spec setProperty:count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : nil
               forKey:@"cellDetailTextLabel"];
    return spec;
}

- (id)getSwitch:(PSSpecifier *)spec {
    id v = PDSTMReadPrefs()[[spec propertyForKey:@"key"]];
    return @(v ? [v boolValue] : [[spec propertyForKey:@"fallback"] boolValue]);
}

- (void)setSwitch:(id)value forSpecifier:(PSSpecifier *)spec {
    NSMutableDictionary *d = PDSTMReadPrefs();
    d[[spec propertyForKey:@"key"]] = @([value boolValue]);
    PDSTMWritePrefs(d);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *general = [PSSpecifier groupSpecifierWithName:@"通用"];
        [general setProperty:@"正在播放音乐时启动的其它 App 会被降级为可混音源，音乐不再被暂停。改动在目标 App 下次冷启动时生效。"
                      forKey:@"footerText"];
        [specs addObject:general];
        [specs addObject:[self switchSpecifierNamed:@"启用" key:@"Enabled" fallback:YES]];
        [specs addObject:[self switchSpecifierNamed:@"写入调试日志" key:@"DebugLog" fallback:NO]];

        PSSpecifier *rules = [PSSpecifier groupSpecifierWithName:@"规则"];
        [rules setProperty:@"开启后除“永不处理”里的 App 外，全部降级为可混音源。"
                    forKey:@"footerText"];
        [specs addObject:rules];
        [specs addObject:[self switchSpecifierNamed:@"所有 App 都降级" key:@"AlwaysMixAll" fallback:NO]];

        PSSpecifier *lists = [PSSpecifier groupSpecifierWithName:@"应用列表"];
        [lists setProperty:@"始终降级：无论是否正在播放都会降级。\n改成纯播放：把录音会话改成播放会话，不开麦克风，避免启动/退出时的卡顿。\n永不处理：完全跳过这些 App。"
                    forKey:@"footerText"];
        [specs addObject:lists];
        [specs addObject:[self listSpecifierNamed:@"始终降级" key:@"AlwaysMix"]];
        [specs addObject:[self listSpecifierNamed:@"改成纯播放" key:@"ForcePlayback"]];
        [specs addObject:[self listSpecifierNamed:@"永不处理" key:@"NeverMix"]];

        _specifiers = specs;
    }
    return _specifiers;
}

@end

#pragma mark - App list pane

@interface PDSTMAppListController : PSListController
@end

@implementation PDSTMAppListController

- (NSString *)listKey {
    return [self.specifier propertyForKey:@"listKey"];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSString *key = [self listKey];
        NSArray *apps = PDSTMInstalledApps();

        NSMutableArray *specs = [NSMutableArray array];
        if (!apps.count) {
            PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@""];
            [empty setProperty:@"无法枚举已安装的 App。" forKey:@"footerText"];
            [specs addObject:empty];
        } else {
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:
                                  [NSString stringWithFormat:@"已选 %lu 项", (unsigned long)PDSTMList(key).count]];
            [group setProperty:@"选中即写入名单，取消即移除。" forKey:@"footerText"];
            [specs addObject:group];
            for (NSDictionary *app in apps) {
                PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:app[@"name"]
                                                                   target:self
                                                                      set:@selector(setApp:forSpecifier:)
                                                                      get:@selector(getApp:)
                                                                   detail:nil
                                                                     cell:PSSwitchCell
                                                                     edit:nil];
                [spec setProperty:app[@"id"] forKey:@"bundleID"];
                [specs addObject:spec];
            }
        }

        PSSpecifier *actions = [PSSpecifier groupSpecifierWithName:@""];
        [specs addObject:actions];
        PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:@"清空名单"
                                                            target:self
                                                               set:nil
                                                               get:nil
                                                            detail:nil
                                                              cell:PSButtonCell
                                                              edit:nil];
        clear.buttonAction = @selector(clearList);
        [specs addObject:clear];

        _specifiers = specs;
    }
    return _specifiers;
}

- (id)getApp:(PSSpecifier *)spec {
    return @([PDSTMList([self listKey]) containsObject:[spec propertyForKey:@"bundleID"]]);
}

- (void)setApp:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *identifier = [spec propertyForKey:@"bundleID"];
    NSMutableArray *list = [PDSTMList([self listKey]) mutableCopy];
    if ([value boolValue]) {
        if (![list containsObject:identifier]) [list addObject:identifier];
    } else {
        [list removeObject:identifier];
    }
    PDSTMSetList([self listKey], list);
}

- (void)clearList {
    PDSTMSetList([self listKey], @[]);
    [self reloadSpecifiers];
}

@end
