/*
  This file is part of the Structure SDK.
  Copyright © 2015 Occipital, Inc. All rights reserved.
  http://structure.io
*/
#import <CommonCrypto/CommonDigest.h>

#include <sstream>
#import "ViewController.h"
#import "ViewController+Camera.h"
#import "ViewController+Sensor.h"
#import "ViewController+OpenGL.h"
#import "PersistentStore.h"
#import "EAGLView.h"
#import "Utils/DeviceUID.h"

#include <cmath>

// Needed to determine platform string
#include <sys/types.h>
#include <sys/sysctl.h>
#include <tgmath.h>


NSUInteger g_uploadedCount = 0;
NSUInteger g_fileCount = 0;
NSInteger g_numCurrentUploads = 0;
unsigned long long g_uploadedByteCount = 0;
unsigned long long g_totalUploadBytes = 0;

#pragma mark - Utilities

namespace // anonymous namespace for local functions.
{
    BOOL isIpadAir2()
    {
        const char* kernelStringName = "hw.machine";
        NSString* deviceModel;
        {
            size_t size;
            sysctlbyname(kernelStringName, NULL, &size, NULL, 0); // Get the size first
            
            char *stringNullTerminated = (char*)malloc(size);
            sysctlbyname(kernelStringName, stringNullTerminated, &size, NULL, 0); // Now, get the string itself
            
            deviceModel = [NSString stringWithUTF8String:stringNullTerminated];
            free(stringNullTerminated);
        }
        
        if ([deviceModel isEqualToString:@"iPad5,3"]) return YES; // Wi-Fi
        if ([deviceModel isEqualToString:@"iPad5,4"]) return YES; // Wi-Fi + LTE
        return NO;
    }
    
    BOOL getDefaultHighResolutionSettingForCurrentDevice()
    {
        // iPad Air 2 can handle 30 FPS high-resolution, so enable it by default.
        if (isIpadAir2())
            return TRUE;
        
        // Older devices can only handle 15 FPS high-resolution, so keep it disabled by default
        // to avoid showing a low framerate.
        return FALSE;
    }
} // anonymous

#pragma mark - ViewController Setup

@implementation ViewController

- (void)dealloc
{
    [self.avCaptureSession stopRunning];
    
    if ([EAGLContext currentContext] == _display.context)
    {
        [EAGLContext setCurrentContext:nil];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self setupGL];
    
    [self setupUserInterface];
    
    [self setupIMU];
    
    [self setupStructureSensor];
    
    // Later, we’ll set this true if we have a device-specific calibration
    _useColorCamera = [STSensorController approximateCalibrationGuaranteedForDevice];
    
    _renderDepthOverlay = true;
    
    // Make sure we get notified when the app becomes active to start/restore the sensor state if necessary.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    
    self.scanButton.hidden = NO;
    self.doneButton.hidden = YES;
    self.resetButton.hidden = YES;
    
    
    [self loadOptions];
    
    NSLog(@"View did load");
    
    exposureLevels = [[NSArray alloc] initWithObjects:@"auto (low light)", @"2", @"5", @"10", @"15", @"20", nil];
    exposureValue = [exposureLevels objectAtIndex:0];
    ////////
    dateFormat = [[NSDateFormatter alloc] init];
    [dateFormat setDateFormat:@"yyyy-MM-dd'T'HH-mm-ss"]; //"dd-MM-yyyy-HH-mm-SS"
    
    logStringRAWAccel = [NSMutableString stringWithString: @""];
    logStringRAWGyro = [NSMutableString stringWithString: @""];
    
    logStringUserAccel = [NSMutableString stringWithString: @""];
    logStringGyro = [NSMutableString stringWithString: @""];
    logStringRPY = [NSMutableString stringWithString: @""];
    logStringGravity = [NSMutableString stringWithString: @""];
    logStringFrameStamps = [NSMutableString stringWithString: @""];
    
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    // The framebuffer will only be really ready with its final size after the view appears.
    [(EAGLView *)self.view setFramebuffer];
    
    [self setupGLViewport];

    [self updateAppStatusMessage];
    
    // We will connect to the sensor when we receive appDidBecomeActive.
}

- (void)appDidBecomeActive
{    
    if ([self currentStateNeedsSensor])
    {
        [self connectToStructureSensorAndStartStreaming];
    }
    
    // Abort the current scan if we were still scanning before going into background since we
    // are not likely to recover well.
    if (_slamState.scannerState == ScannerStateScanning)
    {
        [self resetButtonPressed:self];
    }
    
    [self changeExposureValue];
    //NSLog(@"Resolution: ");
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    [self respondToMemoryWarning];
}

- (void)setupUserInterface
{
    // Make sure the status bar is hidden.
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationSlide];
    
    // Fully transparent message label, initially.
    self.appStatusMessageLabel.alpha = 0;
    
    // Make sure the label is on top of everything else.
    self.appStatusMessageLabel.layer.zPosition = 100;
    
    //make progress bars thicker
    CGAffineTransform transform = CGAffineTransformMakeScale(1.0f, 10.0f);
    
    [self changeExposureValue];
}

// Make sure the status bar is disabled (iOS 7+)
- (BOOL)prefersStatusBarHidden
{
    return YES;
}

-(double)getPercentUsedDiskspace {
    uint64_t totalSpace = 0;
    uint64_t totalFreeSpace = 0;
    NSError *error = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[paths lastObject] error: &error];
    
    if (dictionary) {
        NSNumber *fileSystemSizeInBytes = [dictionary objectForKey: NSFileSystemSize];
        NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];
        totalSpace = [fileSystemSizeInBytes unsignedLongLongValue];
        totalFreeSpace = [freeFileSystemSizeInBytes unsignedLongLongValue];
        //NSLog(@"Memory Capacity of %llu MiB with %llu MiB Free memory available.", ((totalSpace/1024ll)/1024ll), ((totalFreeSpace/1024ll)/1024ll)); // TMI for log
    } else {
        NSLog(@"Error Obtaining System Memory Info: Domain = %@, Code = %ld", [error domain], (long)[error code]);
    }
    
    //return totalFreeSpace;
    double precentUsed = 1 - (double)totalFreeSpace/(double)totalSpace;
    //NSLog(@"percent used memory = %f", precentUsed); // TMI for log
    return precentUsed;
}


- (void)enterScannerInitiatingState
{
    NSLog(@"[enterScannerInitiatingState]");

    self.scanButton.hidden = NO;
    self.doneButton.hidden = YES;
    self.resetButton.hidden = YES;
    
    
    _slamState.scannerState = ScannerStateInitiating;
    
    [self updateIdleTimer];
}


- (void)enterScanningState
{

    [self startTrackingIMU];
    [self startScanningAndOpen];
    
    // Switch to the Done button.
    self.scanButton.hidden = YES;
    self.doneButton.hidden = NO;
    self.resetButton.hidden = NO;

    _slamState.scannerState = ScannerStateScanning;
}

namespace { // anonymous namespace for utility function.
    
    float keepInRange(float value, float minValue, float maxValue)
    {
        if (isnan (value))
            return minValue;
        
        if (value > maxValue)
            return maxValue;
        
        if (value < minValue)
            return minValue;
        
        return value;
    }
    
}

#pragma mark -  Structure Sensor Management

-(BOOL)currentStateNeedsSensor
{
    switch (_slamState.scannerState)
    {
        // Initialization and scanning need the sensor.
        case ScannerStateInitiating:
        case ScannerStateScanning:
            return TRUE;
            
        // Other states don't need the sensor.
        default:
            return FALSE;
    }
}

#pragma mark - IMU

- (void)setupIMU
{
//    g_imuLock = [NSLock new];
    
    // 60 FPS is responsive enough for motion events.
    // Real fps is ~53 (for device motion events
    const float fps = 200.0;
    _motionManager = [[CMMotionManager alloc] init];
    _motionManager.deviceMotionUpdateInterval = 1.0/fps;
//    _motionManager.accelerometerUpdateInterval = 1./imuFreq;
    // Limiting the concurrent ops to 1 is a simple way to force serial execution
    _imuQueue = [[NSOperationQueue alloc] init];
    [_imuQueue setMaxConcurrentOperationCount:1];
   
    _motionManager.gyroUpdateInterval = 1./fps;
    _motionManager.accelerometerUpdateInterval = 1./fps;
    
    accelQueue = [[NSOperationQueue alloc] init];
    [accelQueue setMaxConcurrentOperationCount:1];
    
    gyroQueue = [[NSOperationQueue alloc] init];
    [gyroQueue setMaxConcurrentOperationCount:1];
}


- (void)startTrackingIMU
{
//    __weak ViewController *weakSelf = self;
//    CMDeviceMotionHandler dmHandler = ^(CMDeviceMotion *motion, NSError *error)
//    {
//        // Could be nil if the self is released before the callback happens.
//        if (weakSelf) {
//            [weakSelf processDeviceMotion:motion withError:error];
//        }
//    };
//
//    [_motionManager startDeviceMotionUpdatesToQueue:_imuQueue withHandler:dmHandler];
 
    [_motionManager startDeviceMotionUpdatesToQueue:_imuQueue
                                        withHandler:^(CMDeviceMotion *motion, NSError *error){
                                            [self processDeviceMotion:motion withError:error];
                                        }];
  
    [_motionManager startGyroUpdatesToQueue:gyroQueue
                               withHandler:^(CMGyroData *gyroData, NSError *error) {
                                   [self outputRotationData:gyroData];
                               }];
    
    [_motionManager startAccelerometerUpdatesToQueue:accelQueue
                                withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
                                    [self outputAccelertionData:accelerometerData];
                                }];
    
}

-(void)outputRotationData:(CMGyroData *)gyroData
{
    double msDate = [[NSDate date] timeIntervalSince1970];
    [logStringRAWGyro appendString: [NSString stringWithFormat:@"%f,%f,%f,%f\r\n",
                                  msDate,
                                  gyroData.rotationRate.x,
                                  gyroData.rotationRate.y,
                                  gyroData.rotationRate.z]];
}
-(void)outputAccelertionData:(CMAccelerometerData *)accelData
{
    double msDate = [[NSDate date] timeIntervalSince1970];
    [logStringRAWAccel appendString: [NSString stringWithFormat:@"%f,%f,%f,%f\r\n",
                                   msDate,
                                   accelData.acceleration.x,
                                   accelData.acceleration.y,
                                   accelData.acceleration.z]];
}

- (void)stopTrackingIMU
{
    [_motionManager stopDeviceMotionUpdates];
}

- (void)processDeviceMotion:(CMDeviceMotion *)motion withError:(NSError *)error
{
    if (error != nil)
    {
        NSLog(@"processDeviceMotion error: %@", error);
        return;
    }

    //----- acceleration
    double accX = motion.userAcceleration.x;
    double accY = motion.userAcceleration.y;
    double accZ = motion.userAcceleration.z;
    
    //----- gravity
    double gravX = motion.gravity.x;
    double gravY = motion.gravity.y;
    double gravZ = motion.gravity.z;
    
    if ((accX == 0 && accY == 0 && accZ == 0) || (gravX == 0 && gravY == 0 && gravZ == 0)) return; // no valid acc/grav data
    
//    //----- rotation rate
//    double rotX = motion.rotationRate.x;
//    double rotY = motion.rotationRate.y;
//    double rotZ = motion.rotationRate.z;


//    //----- magnetometer
//    double magX = motion.magneticField.field.x;
//    double magY = motion.magneticField.field.y;
//    double magZ = motion.magneticField.field.z;
    
    double msDate = [[NSDate date] timeIntervalSince1970];
    [logStringGyro appendString: [NSString stringWithFormat:@"%f,%f,%f,%f\r\n",
                                  msDate,
                                  motion.rotationRate.x,
                                  motion.rotationRate.y,
                                  motion.rotationRate.z]];
    
    [logStringUserAccel appendString: [NSString stringWithFormat:@"%f,%f,%f,%f\r\n",
                                   msDate,
                                   motion.userAcceleration.x,
                                   motion.userAcceleration.y,
                                   motion.userAcceleration.z]];
    
    [logStringRPY appendString: [NSString stringWithFormat:@"%f,%f,%f,%f\r\n",
                                  msDate,
                                  motion.attitude.roll,
                                  motion.attitude.pitch,
                                  motion.attitude.yaw]];
    
    [logStringGravity appendString: [NSString stringWithFormat:@"%f,%f,%f,%f\r\n",
                                   msDate,
                                   motion.gravity.x,
                                   motion.gravity.y,
                                   motion.gravity.z]];
}

#pragma mark - UI Callbacks


- (IBAction)scanButtonPressed:(id)sender
{
    [logStringRAWAccel setString:@""];
    [logStringRAWGyro setString:@""];
    
    [logStringUserAccel setString:@""];
    [logStringGyro setString:@""];
    [logStringRPY setString:@""];
    [logStringGravity setString:@""];
    [logStringFrameStamps setString:@""];

    NSDate *now = [[NSDate alloc] init];
    theDate = [dateFormat stringFromDate:now];
    [self createFolderInDocuments:theDate];
    
    [self changeExposureValue];
    [self enterScanningState];

}

- (IBAction)resetButtonPressed:(id)sender
{
    _slamState.prevFrameTimeStamp = -1.0;
    [self enterScannerInitiatingState];
}

- (IBAction)doneButtonPressed:(id)sender
{
    [self writeStringToFile:logStringRAWGyro FileName:@"GyroRaw"];
    [self writeStringToFile:logStringRAWAccel FileName:@"AccelRaw"];
    
    [self writeStringToFile:logStringGyro FileName:@"Gyro"];
    [self writeStringToFile:logStringUserAccel FileName:@"AccelUser"];
    [self writeStringToFile:logStringRPY FileName:@"RPY"];
    [self writeStringToFile:logStringGravity FileName:@"Gravity"];
    [self writeStringToFile:logStringFrameStamps FileName:@"Frames"];
    
    [self cleanUp];
    [self enterScannerInitiatingState];
}



- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(nonnull NSIndexPath *)indexPath
{
    return YES;
}



- (void)setColorCameraParametersForInit
{
    NSError *error;
    
    [self.videoDevice lockForConfiguration:&error];
    
    /*
     // Auto-exposure
     if ([self.videoDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
     [self.videoDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
     */
    // Auto-white balance.
    if ([self.videoDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance])
        [self.videoDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    
    [self.videoDevice unlockForConfiguration];
    
}

- (void)setColorCameraParametersForScanning
{
    NSError *error;
    
    [self.videoDevice lockForConfiguration:&error];
    
    /*
     // Exposure locked to its current value.
     if ([self.videoDevice isExposureModeSupported:AVCaptureExposureModeLocked])
     [self.videoDevice setExposureMode:AVCaptureExposureModeLocked];
     */
    // White balance locked to its current value.
    if ([self.videoDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked])
        [self.videoDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeLocked];
    
    [self.videoDevice unlockForConfiguration];
}

- (void)changeExposureValue
{
    if([exposureValue  isEqual: [exposureLevels objectAtIndex:0]]) {
        NSLog(@"Auto mode selected");
        NSError *error;
        
        [self.videoDevice lockForConfiguration:&error];
        
        
        // Auto-exposure
        if ([self.videoDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            [self.videoDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
        }
        
        [self.videoDevice unlockForConfiguration];
        
        return;
    }
    else {
        NSInteger duration = [exposureValue integerValue];
        NSLog(@"Duration: %ld", (long)duration);
        
        NSError *error;
        
        [self.videoDevice lockForConfiguration:&error];
        
        // Exposure locked to its current value.
        if ([self.videoDevice isExposureModeSupported:AVCaptureExposureModeLocked])
            [self.videoDevice setExposureModeCustomWithDuration:CMTimeMake(duration, 1000) ISO:200 completionHandler:nil];
        
        
        [self.videoDevice unlockForConfiguration];
    }
}



/*********************************************************************/


//+(BOOL)isNotEmpty:(NSString*)string {
BOOL isNotEmpty(NSString* string) {
    if (string == nil) return false;
    if (![[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length])
        return false; //string is all whitespace
    if ([string length] == 0) return false;
    return true;
}


// Manages whether we can let the application sleep.
-(void)updateIdleTimer
{
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
}



- (void)showAppStatusMessage:(NSString *)msg
{
    _appStatus.needsDisplayOfStatusMessage = true;
    [self.view.layer removeAllAnimations];
    
    [self.appStatusMessageLabel setText:msg];
    [self.appStatusMessageLabel setHidden:NO];
    
    // Progressively show the message label.
    [self.view setUserInteractionEnabled:false];
    [UIView animateWithDuration:0.5f animations:^{
        self.appStatusMessageLabel.alpha = 1.0f;
    }completion:nil];
}

- (void)hideAppStatusMessage
{
    if (!_appStatus.needsDisplayOfStatusMessage)
        return;
    
    _appStatus.needsDisplayOfStatusMessage = false;
    [self.view.layer removeAllAnimations];
    
    __weak ViewController *weakSelf = self;
    [UIView animateWithDuration:0.5f
                     animations:^{
                         weakSelf.appStatusMessageLabel.alpha = 0.0f;
                     }
                     completion:^(BOOL finished) {
                         // If nobody called showAppStatusMessage before the end of the animation, do not hide it.
                         if (!_appStatus.needsDisplayOfStatusMessage)
                         {
                             // Could be nil if the self is released before the callback happens.
                             if (weakSelf) {
                                 [weakSelf.appStatusMessageLabel setHidden:YES];
                                 [weakSelf.view setUserInteractionEnabled:true];
                             }
                         }
     }];
}

-(void)updateAppStatusMessage
{
    // Skip everything if we should not show app status messages (e.g. in viewing state).
    if (_appStatus.statusMessageDisabled)
    {
        [self hideAppStatusMessage];
        return;
    }
    
    // First show sensor issues, if any.
    switch (_appStatus.sensorStatus)
    {
        case AppStatus::SensorStatusOk:
        {
            break;
        }
            
        case AppStatus::SensorStatusNeedsUserToConnect:
        {
            [self showAppStatusMessage:_appStatus.pleaseConnectSensorMessage];

            return;
        }
            
        case AppStatus::SensorStatusNeedsUserToCharge:
        {
            [self showAppStatusMessage:_appStatus.pleaseChargeSensorMessage];
            return;
        }
            
        case AppStatus::SensorStatusNeedsIntrinsics:
        {
            [self showAppStatusMessage:_appStatus.needIntrinsicsMessage];
            return;
        }
    }
    
    // Then show color camera permission issues, if any.
    if (!_appStatus.colorCameraIsAuthorized)
    {
        [self showAppStatusMessage:_appStatus.needColorCameraAccessMessage];
        return;
    }

    // If we reach this point, no status to show.
    [self hideAppStatusMessage];
}


- (void) respondToMemoryWarning
{
    switch( _slamState.scannerState )
    {
        //case ScannerStateViewing: //not much to do here
        //{
        //    break;
        //}
        case ScannerStateScanning:
        {
            if( !_slamState.showingMemoryWarning )
            {
                _slamState.showingMemoryWarning = true;
                
                UIAlertController *alertCtrl= [UIAlertController alertControllerWithTitle:@"Memory Low"
                                                                                  message:@"Scanning will be stopped to avoid loss."
                                                                           preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK"
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction *action)
                                           {
                                               _slamState.showingMemoryWarning = false;
                                               //[self enterViewingState];
                                               [self cleanUp];
                                               [self enterScannerInitiatingState];
                                           }];
                
                
                [alertCtrl addAction:okAction];
                
                // show the alert
                [self presentViewController:alertCtrl animated:YES completion:nil];
            }
            
            break;
        }
        default:
        {
            // not much we can do here
        }
    }
}

- (void) updateColorRes:(NSInteger)index
{
    _options.colorWidth = 640;
    _options.colorHeight = 480;
    //if (_options.colorWidth != oldWidth || _options.colorHeight != oldHeight) {
        //NSLog(@"[updateColorRes] try to set color res to %d %d", _options.colorWidth, _options.colorHeight); // TMI for log
        if (self.avCaptureSession)
        {
            [self stopColorCamera];
            if (_useColorCamera)
                [self startColorCamera];
            else
                NSLog(@"[updateColorRes] not using color camera!");
        }
        else {
            //NSLog(@"[updateColorRes] No avCaptureSession!"); // TMI for log
        }
        
        // Force a scan reset since we cannot changing the image resolution during the scan is not
        // supported by STColorizer.
        [self resetButtonPressed:self.resetButton];
    //}
    
}

- (void) loadOptions
{
    NSLog(@"[loadoptions]");
    
    //uid
    _options.deviceId = PersistentStore::get("uid");
    NSString* name = [[UIDevice currentDevice] name];
    _options.deviceName = [name UTF8String];
    if (_options.deviceId.empty()) {
        NSString* s = [DeviceUID uid];
        _options.deviceId = [s UTF8String];
        NSLog(@"creating uid: %s", _options.deviceId.c_str());
        PersistentStore::set("uid", _options.deviceId.c_str());
    }
    else {
        NSLog(@"loaded uid: %s", _options.deviceId.c_str()); //unecessary log
    }
    
    //colorres
    int colorRes = PersistentStore::getAsInt("colorResControl");
    //NSLog(@"colorRes from persistent store: %d", colorRes);
    if (colorRes != -1)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateColorRes:colorRes];
        });
    }
}


- (void)cleanUpAndReset
{
    [self cleanUp];
    
    [self setColorCameraParametersForInit];
    
    _slamState.scannerState = ScannerStateInitiating;
    
    [self updateIdleTimer];
}

- (void)cleanUp
{
    //write out the file
    [self stopTrackingIMU];
    [self stopScanningAndWrite];
    
    
    _appStatus.statusMessageDisabled = true;
    [self updateAppStatusMessage];
    
    // Hide the Scan/Done/Reset button.
    self.scanButton.hidden = NO;
    self.doneButton.hidden = YES;
    self.resetButton.hidden = NO;
    [self enterScannerInitiatingState];
    // [[self scanButton] setHidden:NO];
}


/////////////////

-(BOOL) writeStringToFile:(NSMutableString *)aString FileName:(NSString *)nameString
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *filePath= [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@/%@/%@.txt",documentsDirectory, theDate, nameString]];
    
    BOOL success = [[aString dataUsingEncoding:NSUTF8StringEncoding] writeToFile:filePath atomically:YES];
    
    return success;
}

-(BOOL) createFolderInDocuments:(NSString *)folderName
{
    NSError *error = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *dataPath = [documentsDirectory stringByAppendingPathComponent:folderName];
    
    BOOL success = YES;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dataPath])
        success = [[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:NO attributes:nil error:&error];
    
    if(error){
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:@"Error"
                                     message:[NSString stringWithFormat:@"Create folder: %@", error]
                                     preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction* okButton = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action){}];
        [alert addAction:okButton];
        [self presentViewController:alert animated:YES completion:nil];
    }
    
    return success;
}

@end
