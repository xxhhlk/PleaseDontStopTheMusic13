# PleaseDontStopTheMusic

An iOS tweak that allows multiple audio sources to play simultaneously by preventing audio session interruptions.

## ❤️ Support the Project

If you find this project useful and would like to support development, donations are appreciated.

> The address below belongs to the **upstream author** ([mikey820](https://github.com/mikey820)), not to this fork.

### Litecoin
**Network:** Litecoin (LTC)  
**Address:** `ltc1qaz2zqcc5usl4ueg7w5m8kqcmvrfqurpn6wqyfa`

Please double-check that you're sending on the **Litecoin** network.

Thank you for your support!

---

## Overview

**PleaseDontStopTheMusic** is a tweak that hooks into iOS's `AVAudioSession` to enable audio mixing. This allows your currently playing audio (music, podcasts, etc.) to continue uninterrupted when other apps request audio playback, instead of the usual behavior where the system pauses your audio and plays only the new source.

## Features

- **Continuous Playback** - Your audio keeps playing even when other apps want to play sound.
- **Audio Mixing** - Multiple audio sources blend together using the `MixWithOthers` option.
- **Universal Support** - Works with rootful, rootless, and jailed installations.
- **Lightweight** - Minimal overhead, purely hook-based implementation.

## How It Works

The tweak intercepts `AVAudioSession` configuration calls and, **only when another app is already playing audio** (`isOtherAudioPlaying`), applies the `AVAudioSessionCategoryOptionMixWithOthers` option to the incoming app's session. This tells iOS to mix the new audio with existing playback rather than interrupting it.

Crucially, it does **not** force mixing on whichever app is the primary music source. An app that opts into `MixWithOthers` is treated by iOS as a *secondary* source and loses its lock screen / Control Center "Now Playing" transport controls. By leaving the first/primary app untouched, that app keeps full lock-screen skip & pause controls, while later apps (TikTok, games, etc.) are forced to mix in quietly without interrupting it.

### Hooked Methods

- `setCategory:error:`
- `setCategory:mode:options:error:`
- `setCategory:mode:routeSharingPolicy:options:error:` *(the modern API used by TikTok and most current apps)*
- `setCategory:withOptions:error:`
- `setActive:error:`
- `setActive:withOptions:error:`

`SoloAmbient` sessions (which cannot mix) are transparently swapped to `Ambient` when another app is playing, so they no longer silence your music.

### iOS 13 build

Fork: <https://github.com/xxhhlk/PleaseDontStopTheMusic13> (upstream: `mikey820/PleaseDontStopTheMusic`).

This build targets `firmware >= 13.0` (rootful). Both slices are produced: `arm64` and `arm64e`. The `arm64e` slice is required because Settings and other system processes on A12+ devices are `arm64e` and refuse to load an `arm64`-only binary — the preference bundle failed with `arm64 dylibs cannot be loaded into arm64e processes` until the second slice was added. iOS 12–13.7 use the pre-iOS-14 `arm64e` ABI, so this has to be built with a clang 11 toolchain (`cpusubtype 0x02`); clang 12+ emits the newer ABI and the linker rejects it.

On top of the upstream hooks it adds:

- **AudioUnit layer** — `AudioUnitInitialize`, `AudioOutputUnitStart` and `AUGraphStart` are hooked, and the session is made mixable *before* the unit starts. Apps that never touch `AVAudioSession` (UU Remote, for example) activate the session inside AudioToolbox; without this hook they still interrupt playback.
- **Legacy AudioSession C API** — `AudioSessionSetActive` / `AudioSessionSetProperty` are hooked and `kAudioSessionProperty_OverrideCategoryMixWithOthers` is forced.
- **Detection** — `isOtherAudioPlaying`, then `secondaryAudioShouldBeSilencedHint`, then a cached `MRMediaRemoteGetNowPlayingApplicationIsPlaying` query (MediaRemote private framework, 10 ms cap).
- **Now Playing ownership** — the process that currently owns Now Playing is never demoted, and a demoted app cannot publish now-playing metadata (`MPNowPlayingInfoCenter` writes are dropped while other audio is playing). The lock screen / Control Center entry therefore stays with the music app while a video plays alongside it, including across track changes and scrubbing.
- **Per-app overrides** — `/var/mobile/Library/Preferences/com.xxhhlk.pdstm.plist`:

| Key | Type | Meaning |
| --- | --- | --- |
| `Enabled` | bool | master switch |
| `AlwaysMix` | array | bundle ids that are always demoted to mixing |
| `NeverMix` | array | bundle ids that are never touched |
| `ForcePlayback` | array | bundle ids whose `PlayAndRecord` session is rewritten to `Playback` (no microphone) |
| `AlwaysMixAll` | bool | demote every app except `NeverMix` |
| `DebugLog` | bool | write `/var/mobile/Library/Logs/PDSTM.log` |

- **Settings pane** — `设置 → PleaseDontStopTheMusic`, backed by a `PreferenceLoader` bundle, so the same values can be changed without editing plists: master switch, debug logging, the `AlwaysMixAll` toggle, and one app picker per list (installed apps are enumerated through `LSApplicationWorkspace` and toggled on and off). Each list row shows its current entry count, updated as apps are toggled. The prefs file is created on the first change and is not part of the package, so upgrading never overwrites an existing configuration.

`ForcePlayback` exists for apps that never use the microphone: keeping them on a record-capable session makes iOS rebuild the input path on launch and teardown, which is audible as a short glitch in the playing music.

Example configuration — UU Remote keeps interrupting playback without ever producing sound, and Microsoft Remote Desktop opens a record session it never uses, so it glitches the music on launch and exit:

```xml
<dict>
	<key>AlwaysMix</key>
	<array>
		<string>com.netease.uuremote</string>
	</array>
	<key>ForcePlayback</key>
	<array>
		<string>com.microsoft.rdc.ios</string>
	</array>
</dict>
```

Changes apply on the next cold start of the target app; no respring required.

---

## Installation Guide

Choose the method below that applies to your device configuration.

### Method 1: Non-Jailbroken (Sideloading)
Use this method if your device is not jailbroken. You will need to inject the tweak `.dylib` from releases into your target application's IPA file.

1. **Prepare:** Ensure you have the `PleaseDontStopTheMusic.dylib` file.
2. **Select Tool:** Use a sideloading tool such as **Esign**, **Feather**, or **Sideloadly**.
3. **Inject:** Import your target application's (the app you want to listen to media on, eg if i want to listen to spotify while playing roblox i would inject it into roblox) IPA into the tool, select the `.dylib` for injection, and sign the app.
4. **Install:** Install the resulting modified IPA to your device.

### Method 2: Jailbroken
Use this method if your device is jailbroken.

1. **Add Repo:** Open https://repo.chariz.com/ and press the button to add it to your perferred package manager (this should be a defult repo but if you dont have it add it)
2. **Install:** Navigate to the repo on your list to grab it, or search for "PleaseDontStopTheMusic"
3. **Finalize:** Perform a **respring** of your device to apply the hooks. 

---

If you have any problems or questions, feel free to dm me on discord! dc: fuseegelee

```bash
make all
