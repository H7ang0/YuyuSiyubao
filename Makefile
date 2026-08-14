ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YuyuSiyubao

YuyuSiyubao_FILES = Sources/Tweak.xm
YuyuSiyubao_CFLAGS = -fobjc-arc -DYYSP_DEBUG=1
YuyuSiyubao_FRAMEWORKS = UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
