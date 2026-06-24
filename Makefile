TARGET := iphone:clang:latest:9.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iOSAuthSystem

iOSAuthSystem_FILES = Verification.m
iOSAuthSystem_FRAMEWORKS = UIKit Foundation Security
iOSAuthSystem_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
