#import <UIKit/UIKit.h>
#import <CaptainHook/CaptainHook.h>
#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>
#import <JSON/JSON.h>

#include <speex/speex.h>
#include <speex/speex_echo.h>
#include <speex/speex_resampler.h>
#include <speex/speex_jitter.h>
#include <speex/speex_types.h>

#define AUDIO_INPUT_MIC_FREQUENCY          16000
#define AUDIO_INPUT_BITRATE                48000
#define AUDIO_INPUT_VOICE_DETECTION_CUTOFF 0.20f
#define AUDIO_INPUT_MAX_FRAME_LENGTH       110

#define XSTR(s) STR(s)
#define STR(s) #s
#define PASSTHRU(v) v
#define APPEND(a,b) a ## b
     
#define ProductTokenAppend(value) VoiceKeys ## value
#define ProductLog(args...) NSLog(@XSTR(ProductTokenAppend()) ": " args)

//
// AudioInput
//

static struct {
	SpeexResamplerState *micResampler;
	SpeexBits speexBits;
	void *speexEncoder;
	
	void (*frameCallback)(char *buffer, size_t length);
	
	AudioUnit audioUnit;
	AudioBufferList buflist;
	int micSampleSize;
	int numMicChannels;
	
	int frameSize;
	int sampleRate;

	int micFilled;
	int micLength;

	BOOL previousVoice;

	short *psMic;
	short *psOut;

	BOOL hasSpeech;
} audioInputData;

static inline void AudioInputEncodeFrame()
{
	int maxFrameLength = AUDIO_INPUT_MAX_FRAME_LENGTH;
	char buffer[maxFrameLength];
	size_t len = 0;

	int vbr = 0;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_GET_VBR_MAX_BITRATE, &vbr);
	if (vbr != AUDIO_INPUT_BITRATE) {
		vbr = AUDIO_INPUT_BITRATE;
		speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_VBR_MAX_BITRATE, &vbr);
	}
	if (! audioInputData.previousVoice)
		speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_RESET_STATE, NULL);
	short *bytesToEncode = audioInputData.micResampler ? audioInputData.psOut : audioInputData.psMic;
	if (!audioInputData.hasSpeech && (AUDIO_INPUT_VOICE_DETECTION_CUTOFF > 0.0f)) {
		float powerSum = 0.0f;
		for (int i = 0; i < maxFrameLength; i++) {
			int value = bytesToEncode[i];
			powerSum += value * value;
		}
		float power = powerSum / (32768.0f * 32768.0f * maxFrameLength);
		if (power > AUDIO_INPUT_VOICE_DETECTION_CUTOFF)
			audioInputData.hasSpeech = YES;
	}
	speex_encode_int(audioInputData.speexEncoder, bytesToEncode, &audioInputData.speexBits);
	len = speex_bits_write(&audioInputData.speexBits, (char *)buffer, maxFrameLength);
	speex_bits_reset(&audioInputData.speexBits);

	audioInputData.frameCallback(buffer, len);

	audioInputData.previousVoice = YES;
}

static OSStatus audioInputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
	OSStatus err;

	if (! audioInputData.buflist.mBuffers->mData) {
		audioInputData.buflist.mNumberBuffers = 1;
		AudioBuffer *b = audioInputData.buflist.mBuffers;
		b->mNumberChannels = audioInputData.numMicChannels;
		b->mDataByteSize = audioInputData.micSampleSize * nframes;
		b->mData = calloc(1, b->mDataByteSize);
	} else if (audioInputData.buflist.mBuffers->mDataByteSize < (nframes/audioInputData.micSampleSize)) {
		AudioBuffer *b = audioInputData.buflist.mBuffers;
		free(b->mData);
		b->mDataByteSize = audioInputData.micSampleSize * nframes;
		b->mData = calloc(1, b->mDataByteSize);
	}

	err = AudioUnitRender(audioInputData.audioUnit, flags, ts, busnum, nframes, &audioInputData.buflist);
	if (err != noErr) {
#if 0
		ProductLog(@"AudioUnitRender failed. err = %i", err);
#endif
		return err;
	}

	short *input = (short *)audioInputData.buflist.mBuffers->mData;
	while (nframes > 0) {
		unsigned int left = MIN(nframes, audioInputData.micLength - audioInputData.micFilled);

		short *output = audioInputData.psMic + audioInputData.micFilled;
		
		memcpy(output, input, left * sizeof(short));

		input += left;
		audioInputData.micFilled += left;
		nframes -= left;

		if (audioInputData.micFilled == audioInputData.micLength) {
			// Should we resample?
			if (audioInputData.micResampler) {
				spx_uint32_t inlen = audioInputData.micLength;
				spx_uint32_t outlen = audioInputData.frameSize;
				speex_resampler_process_int(audioInputData.micResampler, 0, audioInputData.psMic, &inlen, audioInputData.psOut, &outlen);
			}
			audioInputData.micFilled = 0;
			AudioInputEncodeFrame();
		}
	}

	return noErr;
}

static void AudioInputInitialize()
{
	speex_bits_init(&audioInputData.speexBits);
	speex_bits_reset(&audioInputData.speexBits);
	audioInputData.speexEncoder = speex_encoder_init(speex_lib_get_mode(SPEEX_MODEID_WB));
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_GET_FRAME_SIZE, &audioInputData.frameSize);
	audioInputData.sampleRate = 16000;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_GET_SAMPLING_RATE, &audioInputData.sampleRate);
	
	int iArg = 1;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_VBR, &iArg);

	iArg = 0;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_VAD, &iArg);
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_DTX, &iArg);

	float fArg = 8.0;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_VBR_QUALITY, &fArg);

	iArg = AUDIO_INPUT_BITRATE;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_VBR_MAX_BITRATE, &iArg);

	iArg = 5;
	speex_encoder_ctl(audioInputData.speexEncoder, SPEEX_SET_COMPLEXITY, &iArg);

	audioInputData.previousVoice = NO;

	audioInputData.numMicChannels = 0;
}

static void AudioInputCleanup()
{
	if (audioInputData.psMic) {
		free(audioInputData.psMic);
		audioInputData.psMic = NULL;
	}
	if (audioInputData.psOut) {
		free(audioInputData.psOut);
		audioInputData.psOut = NULL;
	}

	if (audioInputData.speexEncoder)
		speex_encoder_destroy(audioInputData.speexEncoder);
	if (audioInputData.micResampler)
		speex_resampler_destroy(audioInputData.micResampler);
}

static inline void AudioInputInitializeMixer()
{
	int err;

	audioInputData.micLength = (audioInputData.frameSize * AUDIO_INPUT_MIC_FREQUENCY) / audioInputData.sampleRate;

	if (audioInputData.micResampler)
		speex_resampler_destroy(audioInputData.micResampler);

	if (audioInputData.psMic)
		free(audioInputData.psMic);
	if (audioInputData.psOut)
		free(audioInputData.psOut);

	if (AUDIO_INPUT_MIC_FREQUENCY != audioInputData.sampleRate)
		audioInputData.micResampler = speex_resampler_init(1, AUDIO_INPUT_MIC_FREQUENCY, audioInputData.sampleRate, 3, &err);

	audioInputData.psMic = malloc(audioInputData.micLength * sizeof(short));
	audioInputData.psOut = malloc(audioInputData.frameSize * sizeof(short));
	audioInputData.micSampleSize = audioInputData.numMicChannels * sizeof(short);

}

static BOOL AudioInputSetupDevice()
{
	audioInputData.hasSpeech = NO;
	
	UInt32 len;
	UInt32 val;
	OSStatus err;
	AudioComponent comp;
	AudioComponentDescription desc;
	AudioStreamBasicDescription fmt;
#if TARGET_OS_MAC == 1 && TARGET_OS_IPHONE == 0
	AudioDeviceID devId;

	// Get default device
	len = sizeof(AudioDeviceID);
	err = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice, &len, &devId);
	if (err != noErr) {
		ProductLog(@"Unable to query for default device.");
		return NO;
	}
#endif

	desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE == 1
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
#elif TARGET_OS_MAC == 1
	desc.componentSubType = kAudioUnitSubType_HALOutput;
#endif
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	desc.componentFlags = 0;
	desc.componentFlagsMask = 0;

	comp = AudioComponentFindNext(NULL, &desc);
	if (! comp) {
		ProductLog(@"Unable to find AudioUnit.");
		return NO;
	}

	err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &audioInputData.audioUnit);
	if (err != noErr) {
		ProductLog(@"Unable to instantiate new AudioUnit.");
		return NO;
	}

#if TARGET_OS_MAC == 1 && TARGET_OS_IPHONE == 0
	err = AudioUnitInitialize(audioInputData.audioUnit);
	if (err != noErr) {
		ProductLog(@"Unable to initialize AudioUnit.");
		return NO;
	}
#endif

	/* fixme(mkrautz): Backport some of this to the desktop CoreAudio backend? */

	val = 1;
	err = AudioUnitSetProperty(audioInputData.audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &val, sizeof(UInt32));
	if (err != noErr) {
		ProductLog(@"Unable to configure input scope on AudioUnit.");
		return NO;
	}

	val = 0;
	err = AudioUnitSetProperty(audioInputData.audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &val, sizeof(UInt32));
	if (err != noErr) {
		ProductLog(@"Unable to configure output scope on AudioUnit.");
		return NO;
	}

#if TARGET_OS_MAC == 1 && TARGET_OS_IPHONE == 0
	// Set default device
	len = sizeof(AudioDeviceID);
	err = AudioUnitSetProperty(audioInputData.audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devId, len);
	if (err != noErr) {
		ProductLog(@"Unable to set default device.");
		return NO;
	}
#endif

	AURenderCallbackStruct cb;
	cb.inputProc = audioInputCallback;
	cb.inputProcRefCon = NULL;
	len = sizeof(AURenderCallbackStruct);
	err = AudioUnitSetProperty(audioInputData.audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, len);
	if (err != noErr) {
		ProductLog(@"Unable to setup callback.");
		return NO;
	}

#if TARGET_OS_MAC == 1 && TARGET_OS_IPHONE == 1
	err = AudioUnitInitialize(audioInputData.audioUnit);
	if (err != noErr) {
		ProductLog(@"Unable to initialize AudioUnit.");
		return NO;
	}
#endif

	len = sizeof(AudioStreamBasicDescription);
	err = AudioUnitGetProperty(audioInputData.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &fmt, &len);
	if (err != noErr) {
		ProductLog(@"Unable to query device for stream info.");
		return NO;
	}

/*	if (fmt.mChannelsPerFrame > 1) {
		ProductLog(@"Input device with more than one channel detected. Defaulting to 1.");
	}*/

	audioInputData.numMicChannels = 1;
	AudioInputInitializeMixer();

	fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	fmt.mBitsPerChannel = sizeof(short) * 8;
	fmt.mFormatID = kAudioFormatLinearPCM;
	fmt.mSampleRate = AUDIO_INPUT_MIC_FREQUENCY;
	fmt.mChannelsPerFrame = audioInputData.numMicChannels;
	fmt.mBytesPerFrame = audioInputData.micSampleSize;
	fmt.mBytesPerPacket = audioInputData.micSampleSize;
	fmt.mFramesPerPacket = 1;

	len = sizeof(AudioStreamBasicDescription);
	err = AudioUnitSetProperty(audioInputData.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, len);
	if (err != noErr) {
		ProductLog(@"Unable to set stream format for output device. (output scope)");
		return NO;
	}

/*	len = sizeof(AudioStreamBasicDescription);
	err = AudioUnitSetProperty(audioInputData.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, len);
	if (err != noErr) {
		NSLog(@"AudioInput: Unable to set stream format for output device. (input scope)");
		return NO;
	}*/

	err = AudioOutputUnitStart(audioInputData.audioUnit);
	if (err != noErr) {
		ProductLog(@"Unable to start AudioUnit.");
		return NO;
	}

	return YES;
}

static BOOL AudioInputTeardownDevice()
{
	OSStatus err;

	err = AudioOutputUnitStop(audioInputData.audioUnit);
	if (err != noErr) {
		ProductLog(@"Unable to stop AudioUnit.");
		return NO;
	}

	AudioBuffer *b = audioInputData.buflist.mBuffers;
	if (b && b->mData) {
		free(b->mData);
		b->mData = NULL;
	}

	ProductLog(@"Teardown finished.");
	return YES;
}

//
// SpeechClient
//

__attribute__((visibility("hidden")))
@interface ProductTokenAppend(SpeechClient) : NSObject {
@private
	NSURLConnection *connection;
	NSMutableData *responseData;
}
@end

@interface UIKeyboardImpl : UIView {
}
+ (id)activeInstance;
- (void)addInputString:(NSString *)inputString;
@end

@implementation ProductTokenAppend(SpeechClient)

- (id)initWithSpeechData:(NSData *)speechData
{
	if ((self = [super init])) {
		responseData = [[NSMutableData alloc] init];
		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.google.com/speech-api/v1/recognize?client=chromium&lang=en-US&maxresults=1"]];
		[request setHTTPMethod:@"POST"];
		[request setHTTPBody:speechData];
		[request setValue:@"audio/x-speex-with-header-byte; rate=16000" forHTTPHeaderField:@"Content-Type"];
		connection = [[NSURLConnection connectionWithRequest:request delegate:self] retain];
		[self retain];
	}
	return self;
}

- (void)dealloc
{
	[connection cancel];
	[connection release];
	[responseData release];
	[super dealloc];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse
{
	// Work around crash on OS 3.x's broken behaviour when receiving a redirect (crashes due to premature release)
    return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	[responseData setLength:0];
}	

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)httpData
{
	[responseData appendData:httpData];
}

static inline void ShowNoRecognitionAlert()
{
	static UIAlertView *noRecognitionAlert;
	if (!noRecognitionAlert) {
		noRecognitionAlert = [[UIAlertView alloc] init];
		noRecognitionAlert.title = @XSTR(ProductTokenAppend());
		noRecognitionAlert.message = @"Failed to recognize speech.";
		[noRecognitionAlert addButtonWithTitle:@"OK"];
	}
	[noRecognitionAlert show];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSDictionary *responseDict = [JSON objectWithData:responseData options:0 error:NULL];
	if (!responseDict)
		ShowNoRecognitionAlert();
	else {
		NSArray *hypotheses = [responseDict objectForKey:@"hypotheses"];
		if (!hypotheses)
			ShowNoRecognitionAlert();
		else {
			NSString *utterance = [[hypotheses objectAtIndex:0] objectForKey:@"utterance"];
			if (!utterance)
				ShowNoRecognitionAlert();
			else
				[[objc_getClass("UIKeyboardImpl") activeInstance] addInputString:utterance];
		}
	}
	[responseData setLength:0];
	[self release];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	[responseData setLength:0];
	[self release];
}

@end

//
// Notification Callbacks
//

static BOOL weOwnProximitySensor;
static BOOL hasKeyboard;
static CFMutableDataRef speechData;

static void audioInputFrameCallback(char *buffer, size_t length)
{
	UInt8 cLength = length;
	CFDataAppendBytes(speechData, &cLength, 1);
	CFDataAppendBytes(speechData, (const UInt8 *)buffer, length);
}

static void KeyboardWillShow(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	ProductLog(@"Entering text field");
	UIDevice *device = [UIDevice currentDevice];
	weOwnProximitySensor = !device.proximityMonitoringEnabled;
	if (weOwnProximitySensor)
		device.proximityMonitoringEnabled = YES;
	hasKeyboard = YES;
}

static void KeyboardWillHide(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	ProductLog(@"Exiting text field");
	hasKeyboard = NO;
	if (weOwnProximitySensor)
		[UIDevice currentDevice].proximityMonitoringEnabled = NO;
}

static CFAbsoluteTime startTime;

static void ProximityStateDidChange(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	ProductLog(@"Proximity state did change");
	if ([UIDevice currentDevice].proximityState) {
		AudioInputInitialize();
		audioInputData.frameCallback = audioInputFrameCallback;
		speechData = CFDataCreateMutable(kCFAllocatorDefault, 0);
		startTime = CFAbsoluteTimeGetCurrent();
		AudioInputSetupDevice();
	} else {
		AudioInputTeardownDevice();
		if (audioInputData.hasSpeech) {
			if (CFAbsoluteTimeGetCurrent() < startTime + 2.0)
				ProductLog(@"Speech was too short");
			else {
				ProductLog(@"Sending speech to Google");
				[[[ProductTokenAppend(SpeechClient) alloc] initWithSpeechData:(NSData *)speechData] release];
			}
		} else {
			ProductLog(@"No speech detected");
		}
		CFRelease(speechData);
		AudioInputCleanup();
	}
}

static void WillEnterForeground(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	ProductLog(@"Will enter foreground");
	if (hasKeyboard && weOwnProximitySensor) {
		[UIDevice currentDevice].proximityMonitoringEnabled = YES;
	}
}

static void DidEnterBackground(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	ProductLog(@"Did enter background");
	if (hasKeyboard && weOwnProximitySensor) {
		[UIDevice currentDevice].proximityMonitoringEnabled = NO;
	}
}

//
// Constructor
//

CHConstructor {
	CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
	CFNotificationCenterAddObserver(center, NULL, KeyboardWillShow, (CFStringRef)UIKeyboardWillShowNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
	CFNotificationCenterAddObserver(center, NULL, KeyboardWillHide, (CFStringRef)UIKeyboardWillHideNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
	CFNotificationCenterAddObserver(center, NULL, ProximityStateDidChange, (CFStringRef)UIDeviceProximityStateDidChangeNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
	CFNotificationCenterAddObserver(center, NULL, WillEnterForeground, CFSTR("UIApplicationWillEnterForegroundNotification"), NULL, CFNotificationSuspensionBehaviorCoalesce);
	CFNotificationCenterAddObserver(center, NULL, DidEnterBackground, CFSTR("UIApplicationDidEnterBackgroundNotification"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
