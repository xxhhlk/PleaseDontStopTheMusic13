TARGET = iphone:clang:13.7:13.0
# arm64e is required: Settings and other system processes on A12+ devices are
# arm64e, and an arm64-only slice cannot be loaded into them. The iOS 13.7 SDK
# plus this toolchain produce arm64e with the pre-iOS-14 ABI (cpusubtype 0x02).
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PleaseDontStopTheMusic

PleaseDontStopTheMusic_FILES = ../Tweak.x
PleaseDontStopTheMusic_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PleaseDontStopTheMusic_FRAMEWORKS = AVFoundation AudioToolbox MediaPlayer
PleaseDontStopTheMusic_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = PDSTMPrefs

PDSTMPrefs_FILES = prefs/PDSTMPrefs.m
PDSTMPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I$(THEOS)/vendor/include
PDSTMPrefs_FRAMEWORKS = UIKit
# Preferences.framework ships as a .tbd in the 13.7 SDK, so it can be linked
# properly and the real PSListController ivar layout stays intact.
PDSTMPrefs_PRIVATE_FRAMEWORKS = Preferences
PDSTMPrefs_INSTALL_PATH = /Library/PreferenceBundles
PDSTMPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
