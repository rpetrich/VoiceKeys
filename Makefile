TWEAK_NAME = VoiceKeys
VoiceKeys_FILES = VoiceKeys.m
VoiceKeys_FRAMEWORKS = Foundation UIKit CoreAudio AudioToolbox
VoiceKeys_PRIVATE_FRAMEWORKS = JSON
VoiceKeys_LDFLAGS = -lspeex

ADDITIONAL_CFLAGS = -std=c99

include framework/makefiles/common.mk
include framework/makefiles/tweak.mk
