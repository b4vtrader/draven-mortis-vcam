TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DravenMortis

DravenMortis_FILES = src/DravenMortis.m
DravenMortis_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
DravenMortis_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics QuartzCore ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk
