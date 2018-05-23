#import "Voice.h"
#import <React/RCTLog.h>
#import <UIKit/UIKit.h>
#import <Accelerate/Accelerate.h>
#import <React/RCTUtils.h>
#import <React/RCTEventEmitter.h>
#import <Speech/Speech.h>


OSStatus audioConverterCallback(AudioConverterRef aAudioConverter, UInt32* ioDataPacketCount, AudioBufferList* ioData, AudioStreamPacketDescription** outDataPacketDescription, void* inUserData)
{
    AudioBufferList inputBufferList = *(AudioBufferList *)inUserData;
    *ioData = inputBufferList;
    *ioDataPacketCount = (UInt32)(inputBufferList.mBuffers[0].mDataByteSize/2);
    return noErr;
}

@interface Voice () <SFSpeechRecognizerDelegate>

@property (nonatomic) SFSpeechRecognizer* speechRecognizer;
@property (nonatomic) SFSpeechAudioBufferRecognitionRequest* recognitionRequest;
@property (nonatomic) AVAudioEngine* audioEngine;
@property (nonatomic) SFSpeechRecognitionTask* recognitionTask;
@property (nonatomic) AVAudioSession* audioSession;
@property (nonatomic) NSString *sessionId;
@property (nonatomic) NSMutableData* audioSample;

@end

@implementation Voice
{
}

- (void) setupAndStartRecognizing:(NSString*)localeStr {
    [self teardown];
    self.sessionId = [[NSUUID UUID] UUIDString];

    NSLocale* locale = nil;
    if ([localeStr length] > 0) {
        locale = [NSLocale localeWithLocaleIdentifier:localeStr];
    }

    if (locale) {
        self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    } else {
        self.speechRecognizer = [[SFSpeechRecognizer alloc] init];
    }

    self.speechRecognizer.delegate = self;

    NSError* audioSessionError = nil;
    self.audioSession = [AVAudioSession sharedInstance];

    if (audioSessionError != nil) {
        [self sendResult:RCTMakeError([audioSessionError localizedDescription], nil, nil) :nil :nil :nil];
        return;
    }

    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];

    if (self.recognitionRequest == nil){
        [self sendResult:RCTMakeError(@"Unable to created a SFSpeechAudioBufferRecognitionRequest object", nil, nil) :nil :nil :nil];
        return;
    }

    if (self.audioEngine == nil) {
        self.audioEngine = [[AVAudioEngine alloc] init];
    }

    AVAudioInputNode* inputNode = self.audioEngine.inputNode;
    if (inputNode == nil) {
        [self sendResult:RCTMakeError(@"Audio engine has no input node", nil, nil) :nil :nil :nil];
        return;
    }

    self.audioSample = [[NSMutableData alloc] init];
    
    // Configure request so that results are returned before audio recording is finished
    self.recognitionRequest.shouldReportPartialResults = YES;

    [self sendEventWithName:@"onSpeechStart" body:@true];

    // A recognition task represents a speech recognition session.
    // We keep a reference to the task so that it can be cancelled.
    NSString *taskSessionId = self.sessionId;
    self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
        if (![taskSessionId isEqualToString:self.sessionId]) {
            // session ID has changed, so ignore any capture results and error
            return;
        }
        if (error != nil) {
            NSString *errorMessage = [NSString stringWithFormat:@"%ld/%@", error.code, [error localizedDescription]];
            [self sendResult:RCTMakeError(errorMessage, nil, nil) :nil :nil :nil];
            [self teardown];
            return;
        }

        BOOL isFinal = result.isFinal;
        if (result != nil) {
            NSMutableArray* transcriptionDics = [NSMutableArray new];
            for (SFTranscription* transcription in result.transcriptions) {
                [transcriptionDics addObject:transcription.formattedString];
            }
            [self sendResult:nil:result.bestTranscription.formattedString :transcriptionDics :@(isFinal)];
        }

        if (isFinal == YES) {
            if (self.recognitionTask.isCancelled || self.recognitionTask.isFinishing){
                [self sendEventWithName:@"onSpeechEnd" body:@{@"error": @false, @"base64": [self.audioSample base64EncodedStringWithOptions:0] }];
            }
            [self teardown];
        }
    }];

    //AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
    AVAudioChannelLayout *recordingChLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Mono];
    AVAudioFormat *recordingFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:44100.0
                                                            interleaved:NO
                                                            channelLayout:recordingChLayout];
    
    
    AVAudioChannelLayout *outputChLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Mono];
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:8000.0
                                                            interleaved:NO
                                                            channelLayout:outputChLayout];
    
    int bufferSize = 1024;

    [inputNode installTapOnBus:0 bufferSize:bufferSize format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        
        if (self.recognitionRequest != nil) {
            
            AudioStreamBasicDescription *inputDescription = [recordingFormat streamDescription];
            AudioStreamBasicDescription *outputDescription = [outputFormat streamDescription];
            AudioConverterRef audioConverter;
            OSStatus acCreationResult = AudioConverterNew(inputDescription, outputDescription, &audioConverter);
            if(!audioConverter)
            {
                NSLog(@"error creating audioconverter; %d", (int)acCreationResult);
            }
            
            AudioBufferList inputBufferList = {0};
            inputBufferList.mNumberBuffers = 1;
            inputBufferList.mBuffers[0].mNumberChannels = 1;
            inputBufferList.mBuffers[0].mDataByteSize = [buffer audioBufferList]->mBuffers[0].mDataByteSize;
            inputBufferList.mBuffers[0].mData = buffer.int16ChannelData[0];

            // 5.5125f = 44100 / 8000
            UInt32 outputBufferByteSize = (UInt32)(inputBufferList.mBuffers[0].mDataByteSize/5.5125f);
            UInt8 *outputBuffer = (UInt8 *)malloc(sizeof(UInt8) * outputBufferByteSize);
            
            UInt32 ioOutputDataPackets = (UInt32)outputBufferByteSize / outputDescription->mBytesPerPacket;
            
            AudioBufferList outputBufferList;
            outputBufferList.mNumberBuffers = 1;
            outputBufferList.mBuffers[0].mNumberChannels = outputDescription->mChannelsPerFrame;
            outputBufferList.mBuffers[0].mDataByteSize = outputBufferByteSize;
            outputBufferList.mBuffers[0].mData = outputBuffer;
            
            OSStatus conversionResult = AudioConverterFillComplexBuffer(audioConverter,
                                                              audioConverterCallback,
                                                              &inputBufferList,
                                                              &ioOutputDataPackets,
                                                              &outputBufferList,
                                                              NULL
                                                              );
            if (conversionResult != noErr) {
                NSLog(@"audioconverter error; %d", (int)conversionResult);
            }
            AudioConverterDispose(audioConverter);

            [self.audioSample appendBytes:outputBufferList.mBuffers[0].mData length:outputBufferList.mBuffers[0].mDataByteSize];
            [self getSamplesForVisualization:buffer];
            
            [self.recognitionRequest appendAudioPCMBuffer:buffer];
        }
    }];
    



    [self.audioEngine prepare];
    [self.audioEngine startAndReturnError:&audioSessionError];
    if (audioSessionError != nil) {
        [self sendResult:RCTMakeError([audioSessionError localizedDescription], nil, nil) :nil :nil :nil];
        return;
    }
}

- (void) getSamplesForVisualization:(AVAudioPCMBuffer *)buffer {
    NSMutableArray * meanSamples = [NSMutableArray arrayWithCapacity:8];
    for (int i = 0; i < 8; i++) {
        float tot = 0.0;
        for (int j = 0; j < 128; j++) {
            tot += [[NSNumber numberWithShort:*(buffer.int16ChannelData[0] + i * 128 + j)] floatValue];
        }
        [meanSamples addObject:[NSNumber numberWithFloat:tot / 128]];
         
    }
    
    [self sendEventWithName:@"onSpeechSample" body:@{@"value": meanSamples}];
    meanSamples = nil;
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[
        @"onSpeechResults",
        @"onSpeechStart",
        @"onSpeechPartialResults",
        @"onSpeechSample",
        @"onSpeechError",
        @"onSpeechEnd",
        @"onSpeechRecognized",
        @"onSpeechVolumeChanged"
    ];
}

- (void) sendResult:(NSDictionary*)error :(NSString*)bestTranscription :(NSArray*)transcriptions :(NSNumber*)isFinal {
    if (error != nil) {
        [self sendEventWithName:@"onSpeechError" body:@{@"error": error}];
    }
    if (bestTranscription != nil) {
        [self sendEventWithName:@"onSpeechResults" body:@{@"value":@[bestTranscription]} ];
    }
    if (transcriptions != nil) {
        [self sendEventWithName:@"onSpeechPartialResults" body:@{@"value":transcriptions} ];
    }
    if (isFinal != nil) {
        [self sendEventWithName:@"onSpeechRecognized" body: @{@"isFinal": isFinal}];
    }
}

- (void) teardown {
    [self.recognitionTask cancel];
    self.recognitionTask = nil;
    self.audioSession = nil;
    self.sessionId = nil;

    if (self.audioEngine.isRunning) {
        [self.audioEngine.inputNode removeTapOnBus:0];
        [self.audioEngine.inputNode reset];
        [self.audioEngine stop];
        [self.recognitionRequest endAudio];
    }

    self.recognitionRequest = nil;
    self.audioSample = nil;
}

// Called when the availability of the given recognizer changes
- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    if (available == false) {
        [self sendResult:RCTMakeError(@"Speech recognition is not available now", nil, nil) :nil :nil :nil];
    }
}

RCT_EXPORT_METHOD(stopSpeech:(RCTResponseSenderBlock)callback)
{
    [self.recognitionTask finish];
    callback(@[@false]);
}


RCT_EXPORT_METHOD(cancelSpeech:(RCTResponseSenderBlock)callback) {
    [self.recognitionTask cancel];
    callback(@[@false]);
}

RCT_EXPORT_METHOD(destroySpeech:(RCTResponseSenderBlock)callback) {
    [self teardown];
    callback(@[@false]);
}

RCT_EXPORT_METHOD(isSpeechAvailable:(RCTResponseSenderBlock)callback) {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        switch (status) {
            case SFSpeechRecognizerAuthorizationStatusAuthorized:
                callback(@[@true]);
                break;
            default:
                callback(@[@false]);
        }
    }];
}
RCT_EXPORT_METHOD(isRecognizing:(RCTResponseSenderBlock)callback) {
    if (self.recognitionTask != nil){
        switch (self.recognitionTask.state) {
            case SFSpeechRecognitionTaskStateRunning:
                callback(@[@true]);
                break;
            default:
                callback(@[@false]);
        }
    }
    else {
        callback(@[@false]);
    }
}

RCT_EXPORT_METHOD(startSpeech:(NSString*)localeStr callback:(RCTResponseSenderBlock)callback) {
    if (self.recognitionTask != nil) {
        [self sendResult:RCTMakeError(@"Speech recognition already started!", nil, nil) :nil :nil :nil];
        return;
    }

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        switch (status) {
            case SFSpeechRecognizerAuthorizationStatusNotDetermined:
                [self sendResult:RCTMakeError(@"Speech recognition not yet authorized", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusDenied:
                [self sendResult:RCTMakeError(@"User denied access to speech recognition", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusRestricted:
                [self sendResult:RCTMakeError(@"Speech recognition restricted on this device", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusAuthorized:
                [self setupAndStartRecognizing:localeStr];
                break;
        }
    }];
    callback(@[@false]);
}


- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()



@end
