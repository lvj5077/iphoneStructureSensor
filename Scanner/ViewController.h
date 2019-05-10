/*
  This file is part of the Structure SDK.
  Copyright © 2015 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>

#import <CoreLocation/CoreLocation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <opencv2/videoio/cap_ios.h>


#define HAS_LIBCXX
#import <Structure/Structure.h>
#import "GPUImage.h" //updated sdk12.1

#include <string>
#include <vector>


using namespace cv;

struct Options //TODO get rid of mesh view/tracking params
{
    // Whether we should use depth aligned to the color viewpoint when Structure Sensor was calibrated.
    // This setting may get overwritten to false if no color camera can be used.
    
    bool useHardwareRegisteredDepth = TRUE;
    
    // Focus position for the color camera (between 0 and 1). Must remain fixed one depth streaming
    // has started when using hardware registered depth.
    const float lensPosition = 0.75f;
    
    unsigned int colorEncodeBitrate = 5000;
    
    //meta-data (res, intrinsics)
    unsigned int colorWidth = 640;
    unsigned int colorHeight = 480;
    unsigned int depthWidth = 640;
    unsigned int depthHeight = 480;
    float colorFocalX = 578.0f; float colorFocalY = 578.0f; float colorCenterX = 320.0f; float colorCenterY = 240.0f; //default for VGA
    float depthFocalX = 570.5f; float depthFocalY = 570.5f; float depthCenterX = 320.0f; float depthCenterY = 240.0f; //default for VGA
    bool useHalfResColor = false;
 
    float colorToDepthExtrinsics[16];
    
    std::string deviceId = "";
    std::string deviceName = "";
    
};

enum ScannerState
{
    // scene label - wait for label (can't do until have one)
    ScannerStateInitiating = 0,
    
    // Scanning (scan!)
    ScannerStateScanning,

};

// SLAM-related members.
struct SlamData
{
    SlamData ()
    : initialized (false)
    , scannerState (ScannerStateInitiating)
    {}
    
    BOOL initialized;
    BOOL showingMemoryWarning = false;
    
    NSTimeInterval prevFrameTimeStamp = -1.0;
    
    ScannerState scannerState;
};

struct AppStatus
{
    NSString* const pleaseConnectSensorMessage = @"Please connect Structure Sensor.";
    NSString* const pleaseChargeSensorMessage = @"Please charge Structure Sensor.";
    NSString* const needColorCameraAccessMessage = @"This app requires camera access to capture color.\nAllow access by going to Settings → Privacy → Camera.";
    NSString* const needIntrinsicsMessage = @"No intrinsics received. Please restart the app.";
    
    enum SensorStatus
    {
        SensorStatusOk,
        SensorStatusNeedsUserToConnect,
        SensorStatusNeedsUserToCharge,
        SensorStatusNeedsIntrinsics,
    };
    
    // Structure Sensor status.
    SensorStatus sensorStatus = SensorStatusOk;
    
    // Whether iOS camera access was granted by the user.
    bool colorCameraIsAuthorized = true;
    
    // Whether there is currently a message to show.
    bool needsDisplayOfStatusMessage = false;
    
    // Flag to disable entirely status message display.
    bool statusMessageDisabled = false;
};

// Display related members.
struct DisplayData
{
    DisplayData ()
    {
    }
    
    ~DisplayData ()
    {
        if (lumaTexture)
        {
            CFRelease (lumaTexture);
            lumaTexture = NULL;
        }
        
        if (chromaTexture)
        {
            CFRelease (chromaTexture);
            lumaTexture = NULL;
        }
        
        if (videoTextureCache)
        {
            CFRelease(videoTextureCache);
            videoTextureCache = NULL;
        }
        
        /*
        if (corners)
        {
            corners = NULL;
        }*/
    }
    
    // OpenGL context.
    EAGLContext *context;
    
    // OpenGL Texture reference for y images.
    CVOpenGLESTextureRef lumaTexture;
    
    // OpenGL Texture reference for color images.
    CVOpenGLESTextureRef chromaTexture;
    
    // OpenGL Texture cache for the color camera.
    CVOpenGLESTextureCacheRef videoTextureCache;
    
    // Shader to render a GL texture as a simple quad.
    STGLTextureShaderYCbCr *yCbCrTextureShader;
    STGLTextureShaderRGBA *rgbaTextureShader;
    STGLTextureShaderGray *grayTextureShader;
    
    GLuint depthAsRgbaTexture;
    GLuint grayTexture;
    
    //uint8_t* cornerBuffer;

    // Renders the volume boundaries as a cube.
    //STCubeRenderer *cubeRenderer;
    
    // OpenGL viewport.
    GLfloat viewport[4];
    
    // OpenGL projection matrix for the color camera.
    GLKMatrix4 colorCameraGLProjectionMatrix = GLKMatrix4Identity;
    
    // OpenGL projection matrix for the depth camera.
    GLKMatrix4 depthCameraGLProjectionMatrix = GLKMatrix4Identity;
};

//@interface ViewController : UIViewController <STBackgroundTaskDelegate, //MeshViewDelegate,
//UIPopoverControllerDelegate, UIGestureRecognizerDelegate, NSURLSessionTaskDelegate, UITableViewDelegate, UITableViewDataSource, UIPickerViewDataSource, UIPickerViewDelegate>

@interface ViewController : UIViewController <STBackgroundTaskDelegate,
UIPopoverControllerDelegate, UIGestureRecognizerDelegate>
{
    // Structure Sensor controller.
    STSensorController *_sensorController;
    STStreamConfig _structureStreamConfig;
    
    SlamData _slamState;
    
    Options _options;
    
    // Manages the app status messages.
    AppStatus _appStatus;
    
    DisplayData _display;
    
    // Most recent gravity vector from IMU.
    GLKVector3 _lastGravity;
    
    // IMU handling.
    CMMotionManager *_motionManager;
    NSOperationQueue *_imuQueue;
//    NSOperationQueue *_uploadQueue;
//    NSOperationQueue *_verifyQueue;
    NSOperationQueue *accelQueue;
    NSOperationQueue *gyroQueue;
    
    CMGyroData *gyroData;
    CMAccelerometerData *accelData;
    
    STDepthToRgba *_depthAsRgbaVisualizer;
    
    bool _useColorCamera;
    bool _renderDepthOverlay;
    
    NSArray *exposureLevels;
    
    NSString* exposureValue;
    
    
    
    ////////////////////////////////////////
    NSString *theDate;
    NSDateFormatter *dateFormat;
    
    NSMutableString  *logStringRAWAccel;
    NSMutableString  *logStringRAWGyro;
    
    
    NSMutableString  *logStringUserAccel;
    NSMutableString  *logStringGyro;
    NSMutableString  *logStringRPY;
    NSMutableString  *logStringGravity;
    NSMutableString  *logStringFrameStamps;

}


@property (nonatomic, retain) AVCaptureSession *avCaptureSession;
@property (nonatomic, retain) AVCaptureDevice *videoDevice;

@property (weak, nonatomic) IBOutlet UILabel *appStatusMessageLabel;
@property (weak, nonatomic) IBOutlet UIButton *scanButton;
@property (weak, nonatomic) IBOutlet UIButton *resetButton;
@property (weak, nonatomic) IBOutlet UIButton *doneButton;


//- (IBAction)enableNewTrackerSwitchChanged:(id)sender;
- (IBAction)scanButtonPressed:(id)sender;
- (IBAction)resetButtonPressed:(id)sender;
- (IBAction)doneButtonPressed:(id)sender;

- (void)enterScannerInitiatingState;
- (void)enterScanningState;
- (void)enterViewingState;
- (void)updateAppStatusMessage;
- (BOOL)currentStateNeedsSensor;
- (void)updateIdleTimer;


- (void)updateColorRes:(NSInteger)index;
- (void)loadOptions;


- (void)cleanUpAndReset;

@end
