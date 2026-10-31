TARGET = iphone:clang:latest:13.0
ARCHS = arm64
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
PDSTMPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PDSTMPrefs_FRAMEWORKS = UIKit
# Preferences.framework is not shipped in current SDKs. Settings has it loaded
# already, so the symbols are resolved at load time instead of link time.
PDSTMPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
PDSTMPrefs_INSTALL_PATH = /Library/PreferenceBundles
PDSTMPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
