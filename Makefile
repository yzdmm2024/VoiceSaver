export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.5:15.0
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = com.tencent.xin

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VoiceSaver
VoiceSaver_FILES = src/Tweak.xm src/shine/*.c
VoiceSaver_CFLAGS = -fobjc-arc -Isrc/shine
VoiceSaver_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat"
