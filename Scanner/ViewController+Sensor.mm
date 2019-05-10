/*
  This file is part of the Structure SDK.
  Copyright © 2015 Occipital, Inc. All rights reserved.
  http://structure.io
*/

/*
 modified by Lingqiu Jin 05/10/2019
 - (void)sensorDidOutputSynchronizedDepthFrame:(STDepthFrame*)depthFrame
 andColorFrame:(STColorFrame*)colorFrame
 */

#import "ViewController.h"
#import "ViewController+Camera.h"
#import "ViewController+Sensor.h"
#import "ViewController+OpenGL.h"

#import <Structure/Structure.h>

#include <string>

#include "EncoderConfig.h"
#include "Encoder.h"
#include "uplinksimple_image-codecs.h"

static const std::string BUILD_ID = [[[NSBundle mainBundle] objectForInfoDictionaryKey: (NSString*)kCFBundleVersionKey] UTF8String];
static const std::string APP_VERSION_ID = "Scanner.v1." + BUILD_ID;

static Encoder *g_encoder = nullptr;
//static NSTimer *g_timer;

static unsigned g_frameCount = 0;
static unsigned g_encodedFrameCount = 0;
static bool g_running = false;
static bool g_receivedIntrinsics = false;
// TODO: Split up writing logic to a separate class

#ifdef WRITE_LOCAL
#define WRITE fwrite
#else
#define WRITE sendNalu
#endif

static std::string g_dataDir;
static std::string g_filePrefix;
static FILE *g_h264File;
static FILE *g_depthFile;
static FILE *g_metaFile;
static NSLock* g_h264Lock = [NSLock new];
static NSLock* g_depthLock = [NSLock new];


// 4-byte NALU start code
static uint8_t g_startCode[4] = {0, 0, 0, 1};

uint8_t* g_depthCompressed = nullptr;

void writeIntrinsics(const Options& options)
{
    unsigned int colorWidth = options.useHalfResColor ? options.colorWidth / 2 : options.colorWidth;
    unsigned int colorHeight = options.useHalfResColor ? options.colorHeight / 2 : options.colorHeight;
    fprintf(g_metaFile, "colorWidth = %d\r\n", colorWidth);
    fprintf(g_metaFile, "colorHeight = %d\r\n", colorHeight);
    fprintf(g_metaFile, "depthWidth = %d\r\n", options.depthWidth);
    fprintf(g_metaFile, "depthHeight = %d\r\n", options.depthHeight);
    
    fprintf(g_metaFile, "fx_color = %f\r\n", options.colorFocalX);
    fprintf(g_metaFile, "fy_color = %f\r\n", options.colorFocalY);
    fprintf(g_metaFile, "mx_color = %f\r\n", options.colorCenterX);
    fprintf(g_metaFile, "my_color = %f\r\n", options.colorCenterY);
    
    fprintf(g_metaFile, "fx_depth = %f\r\n", options.depthFocalX);
    fprintf(g_metaFile, "fy_depth = %f\r\n", options.depthFocalY);
    fprintf(g_metaFile, "mx_depth = %f\r\n", options.depthCenterX);
    fprintf(g_metaFile, "my_depth = %f\r\n", options.depthCenterY);
    
    std::string colorToDepthExt = "";
    for(int i = 0; i < 16; i++) {
        colorToDepthExt += std::to_string(options.colorToDepthExtrinsics[i]) + " ";
    }
    
    fprintf(g_metaFile, "colorToDepthExtrinsics = %s\r\n", colorToDepthExt.c_str());
    
    fprintf(g_metaFile, "deviceId = %s\r\n", options.deviceId.c_str());
    fprintf(g_metaFile, "deviceName = %s\r\n", options.deviceName.c_str());
//    fprintf(g_metaFile, "sceneLabel = %s\r\n", options.sceneLabel.c_str());
//    fprintf(g_metaFile, "sceneType = %s\r\n", options.specifiedSceneType.c_str());
//    fprintf(g_metaFile, "userName = %s\r\n", options.userName.c_str());
    fprintf(g_metaFile, "appVersionId = %s\r\n", APP_VERSION_ID.c_str());
    fflush(g_metaFile);
}

void writeDepthFrame(STDepthFrame* depthFrame)
{
    uint32_t size = uplinksimple::encode([depthFrame shiftData],
                                         [depthFrame height] * [depthFrame width],
                                         g_depthCompressed, sizeof(uint8_t)*[depthFrame height] * (2*[depthFrame width]+1));
    
    [g_depthLock lock];
    WRITE((uint8_t *) &size, sizeof(uint32_t), 1, g_depthFile);
    WRITE(g_depthCompressed, sizeof(uint8_t), size, g_depthFile); //size is #bytes
    [g_depthLock unlock];
}

void sendNalu(const void *src, size_t chunkSize, size_t numChunks, FILE *unused)
{
    static int i = 0;
    // Assumes chunkSize is always 1 (byte)
    // Does not use FILE*. Included for fwrite compatibility
//    [g_client sendNalU:(UInt8 *)src length:numChunks];
    fwrite(src, chunkSize, numChunks, unused);
    NSLog(@"Sent %d %zu chunks", i++, numChunks);
}

void writeToFile(CMSampleBufferRef sampleBuffer)
{
    if (!CMSampleBufferDataIsReady(sampleBuffer))
    {
        NSLog(@"sampleBuffer is not ready ");
        return;
    }
    
    bool keyFrame = !CFDictionaryContainsKey((CFDictionaryRef) CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0), kCMSampleAttachmentKey_NotSync);

    // SPS, PPS are their own NALUs
    if (keyFrame)
    {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);

        size_t sparameterSetSize, sparameterSetCount;
        const uint8_t *sparameterSet;
        OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0 );
        if (statusCode == noErr)
        {
            // Found sps and now check for pps
            size_t pparameterSetSize, pparameterSetCount;
            const uint8_t *pparameterSet;
            OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0 );
            if (statusCode == noErr)
            {
                WRITE(g_startCode, 1, 4, g_h264File);
                WRITE(sparameterSet, 1, sparameterSetSize, g_h264File);
                WRITE(g_startCode, 1, 4, g_h264File);
                WRITE(pparameterSet, 1, pparameterSetSize, g_h264File);
            }
        }
    }
    
    CMBlockBufferRef buf = CMSampleBufferGetDataBuffer(sampleBuffer);
    
    size_t length, totalLength;
    char *dataPointer;

    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(buf, 0, &length, &totalLength, &dataPointer);
    
    if (statusCodeRet == noErr)
    {
        size_t bufferOffset = 0;
        static const int AVCCHeaderLength = 4;
//        unsigned counter = 0;
        // Iterate through the NALUs
        while (bufferOffset < totalLength - AVCCHeaderLength) {
            // Read the NAL unit length
            uint32_t NALUnitLength = 0;
            memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
            
            // Convert the length value from Big-endian to Little-endian
            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);

            WRITE(g_startCode, 1, 4, g_h264File);
            WRITE(dataPointer + bufferOffset + AVCCHeaderLength, 1, NALUnitLength, g_h264File);
            
            bufferOffset += AVCCHeaderLength + NALUnitLength;
        }
    }
}

void h264EncodedFrameCallback(CMSampleBufferRef sampleBuffer, void *userData)
{
    if (g_running) {
        [g_h264Lock lock];
        writeToFile(sampleBuffer);
        [g_h264Lock unlock];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            g_encodedFrameCount++;
        });
    }
}

@implementation ViewController (Sensor)

#pragma mark -  Structure Sensor delegates

- (void)setupStructureSensor
{
    // Get the sensor controller singleton
    _sensorController = [STSensorController sharedController];
    
    // Set ourself as the delegate to receive sensor data.
    _sensorController.delegate = self;
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains
    (NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    documentsDirectory = [documentsDirectory stringByAppendingString:@"/"];
    g_dataDir = [documentsDirectory UTF8String];
}

- (BOOL)isStructureConnectedAndCharged
{
    return [_sensorController isConnected] && ![_sensorController isLowPower];
}

- (void)sensorDidConnect
{
    NSLog(@"[Structure] Sensor connected!");
    
    if (![self currentStateNeedsSensor])
    {
        [self enterScannerInitiatingState];
        //[self enterCubePlacementState];
    }
    [self connectToStructureSensorAndStartStreaming];
}

- (void)sensorDidLeaveLowPowerMode
{
    _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToConnect;
    [self updateAppStatusMessage];
}

- (void)sensorBatteryNeedsCharging
{
    [self cleanUpAndReset];
    // Notify the user that the sensor needs to be charged.
    _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToCharge;
    [self updateAppStatusMessage];
}

- (void)cleanUpFileWriting
{
    if (g_encoder) { delete g_encoder; g_encoder = nullptr; }
    if (g_depthCompressed) { delete [] g_depthCompressed; g_depthCompressed = nullptr; }
}

- (void)sensorDidStopStreaming:(STSensorControllerDidStopStreamingReason)reason
{
    if (reason == STSensorControllerDidStopStreamingReasonAppWillResignActive)
    {
        [self stopColorCamera];
        NSLog(@"[Structure] Stopped streaming because the app will resign its active state.");
    }
    else
    {
        NSLog(@"[Structure] Stopped streaming for an unknown reason.");
        [self enterViewingState];
    }
}

- (void)sensorDidDisconnect
{
    // If we receive the message while in background, do nothing. We'll check the status when we
    // become active again.
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive)
        return;
    
    NSLog(@"[Structure] Sensor disconnected!");
    
    // Reset the scan on disconnect, since we won't be able to recover afterwards.
    if (_slamState.scannerState == ScannerStateScanning)
    {
        [self resetButtonPressed:self];
        [self enterViewingState];
    }
    
    if (_useColorCamera)
        [self stopColorCamera];
    
    [self updateIdleTimer];
}


- (STSensorControllerInitStatus)connectToStructureSensorAndStartStreaming
{
    
    // Try connecting to a Structure Sensor.
    STSensorControllerInitStatus result = [_sensorController initializeSensorConnection];
    
    if (result == STSensorControllerInitStatusSuccess || result == STSensorControllerInitStatusAlreadyInitialized)
    {
        // Even though _useColorCamera was set in viewDidLoad by asking if an approximate calibration is guaranteed,
        // it's still possible that the Structure Sensor that has just been plugged in has a custom or approximate calibration
        // that we couldn't have known about in advance.
        
        STCalibrationType calibrationType = [_sensorController calibrationType];
        if(calibrationType == STCalibrationTypeApproximate || calibrationType == STCalibrationTypeDeviceSpecific)
        {
            _useColorCamera = true;
        }
        else
        {
            _useColorCamera = false;
        }

        // If we can't use the color camera, then don't try to use registered depth.
        if (!_useColorCamera)
            _options.useHardwareRegisteredDepth = false;
        
        _appStatus.sensorStatus = AppStatus::SensorStatusOk;
        [self updateAppStatusMessage];
        
        // Start streaming depth data.
        [self startStructureSensorStreaming];
    }
    else
    {
        switch (result)
        {
            case STSensorControllerInitStatusSensorNotFound:
                NSLog(@"[Structure] No sensor found"); break;
            case STSensorControllerInitStatusOpenFailed:
                NSLog(@"[Structure] Error: Open failed."); break;
            case STSensorControllerInitStatusSensorIsWakingUp:
                NSLog(@"[Structure] Error: Sensor still waking up."); break;
            default: {}
        }
        
        _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToConnect;
        [self updateAppStatusMessage];
    }
    
    [self updateIdleTimer];
    
    return result;
}

- (void)startStructureSensorStreaming
{
    if (![self isStructureConnectedAndCharged])
        return;
    
    // Tell the driver to start streaming.
    NSError *error = nil;
    BOOL optionsAreValid = FALSE;
    if (_useColorCamera)
    {
        // We can use either registered or unregistered depth.
        _structureStreamConfig = _options.useHardwareRegisteredDepth ? STStreamConfigRegisteredDepth640x480 : STStreamConfigDepth640x480;
        
        if (_options.useHardwareRegisteredDepth)
        {
            // We are using the color camera, so let's make sure the depth gets synchronized with it.
            // If we use registered depth, we also need to specify a fixed lens position value for the color camera.
            optionsAreValid = [_sensorController startStreamingWithOptions:@{kSTStreamConfigKey : @(_structureStreamConfig),
                                                                             kSTFrameSyncConfigKey : @(STFrameSyncDepthAndRgb),
                                                                             kSTColorCameraFixedLensPositionKey: @(_options.lensPosition)}
                                                                     error:&error];
        }
        else
        {
            // We are using the color camera, so let's make sure the depth gets synchronized with it.
            optionsAreValid = [_sensorController startStreamingWithOptions:@{kSTStreamConfigKey : @(_structureStreamConfig),
                                                                             kSTFrameSyncConfigKey : @(STFrameSyncDepthAndRgb)}
                                                                     error:&error];
        }
        
        [self startColorCamera];
    }
    else
    {
        _structureStreamConfig = STStreamConfigDepth640x480;
        
        optionsAreValid = [_sensorController startStreamingWithOptions:@{kSTStreamConfigKey : @(_structureStreamConfig),
                                                                         kSTFrameSyncConfigKey : @(STFrameSyncOff)} error:&error];
    }
    
    if (!optionsAreValid)
    {
        NSLog(@"Error during streaming start: %s", [[error localizedDescription] UTF8String]);
        return;
    }
    
    NSLog(@"[Structure] Streaming started.");
    
    // Notify and initialize streaming dependent objects.
    [self onStructureSensorStartedStreaming];
}

- (void)onStructureSensorStartedStreaming
{
    NSLog(@"onStructureSensorStartedStreaming");
    
    if (!_slamState.initialized)
    {
        [self enterScannerInitiatingState];

        _depthAsRgbaVisualizer = [[STDepthToRgba alloc] initWithOptions:@{kSTDepthToRgbaStrategyKey: @(STDepthToRgbaStrategyRedToBlueGradient)}
                                                                  error:nil];

        _slamState.initialized = true;
    }
}

- (void)sensorDidOutputDeviceMotion:(CMDeviceMotion*)motion
{
    //[self processDeviceMotion:motion withError:nil];
}

GLKVector4 getIntrinsicsFromGlProj(const GLKMatrix4& matrix, unsigned int width, unsigned int height, bool useHalf)
{
    float fov = 2.0f * atan(1.0f / matrix.m00);
    float aspect = (float)width / height;
    float t = tan(0.5f * fov);
    float fx = 0.5f * width / t;
    float fy = 0.5f * height / t * aspect;
    
    float mx = (float)(width - 1.0f) / 2.0f;
    float my = (float)(height - 1.0f) / 2.0f;
 
    if (useHalf) {
        fx *= 0.5f; fy *= 0.5f;
        mx *= 0.5f; my *= 0.5f;
    }
    GLKVector4 ret = GLKVector4Make(fx, fy, mx, my);
    return ret;
}

-(UIImage *) imageFromFrame:(STColorFrame*) colorFrame{
    CMSampleBufferRef sampleBuffer = colorFrame.sampleBuffer;
    @autoreleasepool {
        CVImageBufferRef imBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        CVPixelBufferLockBaseAddress(imBuffer, 0);
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
        
        CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddressOfPlane(imBuffer, 0), CVPixelBufferGetWidth(imBuffer), CVPixelBufferGetHeight(imBuffer), 8, CVPixelBufferGetBytesPerRowOfPlane(imBuffer,0), colorSpace, kCGImageAlphaNone);
        
        CGImageRef cgImage = CGBitmapContextCreateImage(context);
        CVPixelBufferUnlockBaseAddress(imBuffer,0);
        
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        
        CGImageRelease(cgImage);
        
        return image;
    }
}

- (bool)sensorTooClose:(STDepthFrame*)depthFrame
{
    float *depth = depthFrame.depthInMillimeters;
    int totalSize = depthFrame.width * depthFrame.height;
    int numNotNan = 0;
    int numValidDistance = 0;
    
    const double distanceThreshold = 750.0;
    const double threshold = 0.45;
    
    for(int i = 0; i < totalSize; i++)
    {
        if(!isnan(depth[i]))
        {
            numNotNan++;
            if(depth[i] < distanceThreshold)
            {
                numValidDistance++;
            }
        }
    }
    
    double percentGood = ((double) numValidDistance) / numNotNan;
    return (percentGood > threshold) || isnan(percentGood);
    
}

- (void)processDepthFrame:(STDepthFrame *)depthFrame
          colorFrameOrNil:(STColorFrame*)colorFrame
{
    // Upload the new color image for next rendering.
    if (_useColorCamera && colorFrame != nil)
    {
        [self uploadGLColorTexture: colorFrame];
    }
    //else if(!_useColorCamera)
    //{
    [self uploadGLColorTextureFromDepth:depthFrame];
    //}

    // Update the projection matrices since we updated the frames.
    {
        _display.depthCameraGLProjectionMatrix = [depthFrame glProjectionMatrix];
        if (colorFrame)
            _display.colorCameraGLProjectionMatrix = [colorFrame glProjectionMatrix];
    }

}

- (void)sensorDidOutputSynchronizedDepthFrame:(STDepthFrame*)depthFrame
                                andColorFrame:(STColorFrame*)colorFrame
{
    
    if (_slamState.initialized)
    {
        //NSLog(@"process depth/color frame");
        [self processDepthFrame:depthFrame colorFrameOrNil:colorFrame];
        if ((_slamState.scannerState == ScannerStateInitiating) && colorFrame && depthFrame) {
            GLKVector4 colorIntrinsics = getIntrinsicsFromGlProj(colorFrame.glProjectionMatrix, _options.colorWidth, _options.colorHeight, _options.useHalfResColor);
            GLKVector4 depthIntrinsics = getIntrinsicsFromGlProj(depthFrame.glProjectionMatrix, _options.depthWidth, _options.depthHeight, false);
            //NSLog(@"color intrinsics: %f %f %f %f (%d,%d)\n", colorIntrinsics.x, colorIntrinsics.y, colorIntrinsics.z, colorIntrinsics.w, _options.colorWidth, _options.colorHeight);
            //NSLog(@"depth intrinsics: %f %f %f %f (%d,%d)\n", depthIntrinsics.x, depthIntrinsics.y, depthIntrinsics.z, depthIntrinsics.w, _options.depthWidth, _options.depthHeight);
            _options.colorFocalX = colorIntrinsics.x;
            _options.colorFocalY = colorIntrinsics.y;
            _options.colorCenterX = colorIntrinsics.z;
            _options.colorCenterY = colorIntrinsics.w;
            
            _options.depthFocalX = depthIntrinsics.x;
            _options.depthFocalY = depthIntrinsics.y;
            _options.depthCenterX = depthIntrinsics.z;
            _options.depthCenterY = depthIntrinsics.w;
            
            /*
            float *m4 = (float*) malloc(16 * sizeof(float));
            [depthFrame colorCameraPoseInDepthCoordinateFrame:m4];
            
            for(int i = 0; i < 4; i++) {
                NSLog(@"%f %f %f %f", m4[i], m4[i + 4], m4[i + 8], m4[i + 12]);
            }
            free(m4);
            */
            
            if(!_options.useHardwareRegisteredDepth) {
                float *m4 = (float*) malloc(16 * sizeof(float));
                [_sensorController colorCameraPoseInSensorCoordinateFrame:m4];
            
                for(int i = 0; i < 4; i++) {
                    for(int j = 0; j < 4; j++) {
                        _options.colorToDepthExtrinsics[4 * i + j] = m4[i + 4 * j];
                    }
                    //NSLog(@"%f %f %f %f", m4[i], m4[i + 4], m4[i + 8], m4[i + 12]);
                }
                free(m4);
            }
            else {
                for(int i = 0; i < 4; i++) {
                    for(int j = 0; j < 4; j++) {
                        _options.colorToDepthExtrinsics[4 * i + j] = (i == j);
                    }
                }
            }
            g_receivedIntrinsics = true;
        }
        if (_slamState.scannerState == ScannerStateScanning && g_running && colorFrame && depthFrame)
        {
            g_encoder->encodeFrame(colorFrame);
            writeDepthFrame(depthFrame);
            double msDate = [[NSDate date] timeIntervalSince1970];
            [logStringFrameStamps appendString: [NSString stringWithFormat:@"%f,%u\r\n",
                                                 msDate,
                                                 g_frameCount]];

            /** Capture timestamp in seconds since the iOS device boot (same clock as CoreMotion and AVCapture). */
            // using 1970 timestamp instead!!!
//            _colorTimestamps.push_back([colorFrame timestamp]);
//            _depthTimestamps.push_back([depthFrame timestamp]);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                g_frameCount++;
            });
        }
        
        // Scene rendering is triggered by new frames to avoid rendering the same view several times.
        [self renderSceneForDepthFrame:depthFrame colorFrameOrNil:colorFrame];
    }
}

- (void)stopScanningAndWrite
{
    if (g_running) {
        g_running = false;
        [self closeFile];
        [self cleanUpFileWriting];
        g_frameCount = 0;
        g_encodedFrameCount = 0;
    }
}

- (void)startScanningAndOpen
{
    if (!g_running) {
        unsigned int colorWidth = _options.useHalfResColor ? _options.colorWidth / 2 : _options.colorWidth;
        unsigned int colorHeight = _options.useHalfResColor ? _options.colorHeight / 2 : _options.colorHeight;
        
        NSLog(@"startScanningAndOpen (%d,%d, bitrate %d)", colorWidth, colorHeight, _options.colorEncodeBitrate);
        
        EncoderConfig config(colorWidth, colorHeight, EncoderConfig::H264, 30, _options.colorEncodeBitrate); //30fps
        g_encoder = new Encoder(config);
        g_encoder->registerEncodedFrameCallback(h264EncodedFrameCallback, 0);
        if (!g_depthCompressed) g_depthCompressed = new uint8_t[(2*_options.depthWidth+1) * _options.depthHeight];
        
        NSDateFormatter *dateFormatter=[[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd_hh-mm-ss"];
        std::string dateString = [[dateFormatter stringFromDate:[NSDate date]] UTF8String];

        if (!g_receivedIntrinsics || _options.deviceId.empty()) {
            NSLog(@"ERROR: no intrinsics/device id!");
            _appStatus.sensorStatus = AppStatus::SensorStatusNeedsIntrinsics;
            [self updateAppStatusMessage];
            g_running = false;
            return;
        }
        else {
            NSLog(@"color intrinsics: %f %f, %f %f", _options.colorFocalX, _options.colorFocalY, _options.colorCenterX, _options.colorCenterY);
            NSLog(@"depth intrinsics: %f %f, %f %f", _options.depthFocalX, _options.depthFocalY, _options.depthCenterX, _options.depthCenterY);
        }


        NSString *filePath= [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@/",theDate]];
        [self openFile:([filePath UTF8String])];
        
        NSLog(@"[Structure] opened file");
        
        writeIntrinsics(_options);
        g_running = true;
    }
}

- (void)sensorDidOutputDepthFrame:(STDepthFrame *)depthFrame
{
    if (_slamState.initialized)
    {
        [self processDepthFrame:depthFrame colorFrameOrNil:nil];
        // Scene rendering is triggered by new frames to avoid rendering the same view several times.
        [self renderSceneForDepthFrame:depthFrame colorFrameOrNil:nil];
    }
}

- (void) openFile:(std::string) filePref
{
    g_h264File = fopen((g_dataDir + filePref + "color.h264").c_str(), "wb");
    g_depthFile = fopen((g_dataDir + filePref + "depth.depth").c_str(), "wb");
    g_metaFile = fopen((g_dataDir + filePref + "camera.txt").c_str(), "w");
//    g_imuFile = fopen((g_dataDir + filePref + ".imu").c_str(), "w");
//    g_cameraFile = fopen((g_dataDir + filePref + ".camera").c_str(), "wb");
    
    
    std::string versionNum = "v1";
//    fwrite(versionNum.c_str(), versionNum.size() * sizeof(char), 1, g_cameraFile);

    g_filePrefix = filePref;
}

- (void) closeFile
{
//    if (g_frameCount > _colorTimestamps.size() || g_frameCount > _depthTimestamps.size())
//        NSLog(@"ERROR: inconsistent #frames/#timestamps (color, depth, frames) = %lu, %lu, %d\n", _colorTimestamps.size(), _depthTimestamps.size(), g_frameCount);

//    NSLog(@"framecount = %d, encodedcount = %d, #imu = %d\n", g_frameCount, g_encodedFrameCount, g_numIMUmeasurements);

    //get created at time
    NSDateFormatter *dateFormatter=[[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyyMMdd'T'hhmmssZZZ"];
    std::string dateString = [[dateFormatter stringFromDate:[NSDate date]] UTF8String];

    //write #frames
    fprintf(g_metaFile, "scanSavedAt = %s\r\n", dateString.c_str());
    fprintf(g_metaFile, "numDepthFrames = %d\r\n", g_frameCount);
    fprintf(g_metaFile, "numColorFrames = %d\r\n", g_encodedFrameCount);
//    fprintf(g_metaFile, "numIMUmeasurements = %d\r\n", g_numIMUmeasurements);
    fclose(g_metaFile);
    
    //write timestamps to end of depth file
    [g_depthLock lock];
//    WRITE(_depthTimestamps.data(), sizeof(NSTimeInterval), g_frameCount, g_depthFile);
//    WRITE(_colorTimestamps.data(), sizeof(NSTimeInterval), g_frameCount, g_depthFile);
    fclose(g_depthFile);
    [g_depthLock unlock];
    
    [g_h264Lock lock];
    fclose(g_h264File);
    [g_h264Lock unlock];
    
    [self verifyFiles];
    
    NSLog(@"[Structure] closed file");
}

- (void) verifyFiles
{
    bool remove = false;
    std::string curFilePrefix = g_dataDir + g_filePrefix;
    
    NSError *error = nil;
    NSString *absH264File = [NSString stringWithUTF8String:(curFilePrefix + ".h264").c_str()];
    NSString *h264FileSize = [NSString stringWithFormat:@"%llu",
                              [[[NSFileManager defaultManager] attributesOfItemAtPath:absH264File error:&error] fileSize]];
    if (!h264FileSize || error)
    {
        NSLog(@"H264 file %@, size %@, error: %@", absH264File, h264FileSize, error);
        remove = true;
    }
    
    error = nil;
    NSString *absDepthFile = [NSString stringWithUTF8String:(curFilePrefix + ".h264").c_str()];
    NSString *depthFileSize = [NSString stringWithFormat:@"%llu",
                              [[[NSFileManager defaultManager] attributesOfItemAtPath:absDepthFile error:&error] fileSize]];
    if (!depthFileSize || error)
    {
        NSLog(@"Depth file %@, size %@, error: %@", absDepthFile, depthFileSize, error);
        remove = true;
    }
    
    error = nil;
    NSString *absMetaFile = [NSString stringWithUTF8String:(curFilePrefix + ".h264").c_str()];
    NSString *metaFileSize = [NSString stringWithFormat:@"%llu",
                              [[[NSFileManager defaultManager] attributesOfItemAtPath:absMetaFile error:&error] fileSize]];
    if (!metaFileSize || error)
    {
        NSLog(@"Meta file %@, size %@, error: %@", absMetaFile, metaFileSize, error);
        remove = true;
    }
    
    error = nil;
    NSString *absImuFile = [NSString stringWithUTF8String:(curFilePrefix + ".h264").c_str()];
    NSString *imuFileSize = [NSString stringWithFormat:@"%llu",
                              [[[NSFileManager defaultManager] attributesOfItemAtPath:absImuFile error:&error] fileSize]];
    if (!imuFileSize || error)
    {
        NSLog(@"imu file %@, size %@, error: %@", absImuFile, imuFileSize, error);
        remove = true;
    }
    
    if (remove)
    {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtPath:absH264File error:nil];
        [fileManager removeItemAtPath:absDepthFile error:nil];
        [fileManager removeItemAtPath:absMetaFile error:nil];
        [fileManager removeItemAtPath:absImuFile error:nil];
    }
}

@end
