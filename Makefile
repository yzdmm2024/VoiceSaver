export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.5:15.0
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = com.tencent.xin

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VoiceSaver
VoiceSaver_FILES = src/Tweak.xm \
	src/shine/bitstream.c src/shine/huffman.c src/shine/l3bitstream.c \
	src/shine/l3loop.c src/shine/l3mdct.c src/shine/l3subband.c \
	src/shine/layer3.c src/shine/reservoir.c src/shine/tables.c
VoiceSaver_CFLAGS = -fobjc-arc -Isrc/shine
VoiceSaver_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat"
