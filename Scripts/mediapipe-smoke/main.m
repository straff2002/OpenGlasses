// Exercises the real Tasks API and graph, independently of app startup and downloaded-model UI.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPipeTasksVision/MediaPipeTasksVision.h>
#include <math.h>

// The fingerspelling windower consumes all three landmark families, so a registration that
// survives for pose but not for face or hands would still decode into silence. Asserting the
// counts is what makes a missing anchor a failed smoke rather than a degraded model input.
static const NSUInteger kPoseLandmarks = 33;
static const NSUInteger kHandLandmarks = 21;
// HolisticWindower reads face landmarks 0–467. The mesh with iris refinement returns 478, so
// require the contract's 468 rather than an exact count.
static const NSUInteger kMinimumFaceLandmarks = 468;

static BOOL AllFinite(NSArray<MPPNormalizedLandmark *> *landmarks, const char *name, int frame) {
  for (MPPNormalizedLandmark *point in landmarks) {
    if (!isfinite(point.x) || !isfinite(point.y) || !isfinite(point.z)) {
      fprintf(stderr, "Frame %d: non-finite %s landmark\n", frame, name);
      return NO;
    }
  }
  return YES;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 3) {
      fprintf(stderr, "Usage: smoke <holistic_landmarker.task> <image-with-face-hands-and-body>\n");
      return 1;
    }
    fprintf(stderr, "MediaPipe smoke: entered main\n");
    MPPHolisticLandmarkerOptions *options = [MPPHolisticLandmarkerOptions new];
    options.baseOptions.modelAssetPath = @(argv[1]);
    options.runningMode = MPPRunningModeVideo; // Same default CPU delegate as HolisticLandmarkService.
    NSError *error = nil;
    MPPHolisticLandmarker *landmarker = [[MPPHolisticLandmarker alloc] initWithOptions:options error:&error];
    if (!landmarker) {
      fprintf(stderr, "Graph construction failed: %s\n", error.description.UTF8String);
      return 1;
    }
    UIImage *image = [UIImage imageWithContentsOfFile:@(argv[2])];
    if (!image) {
      fprintf(stderr, "Cannot read smoke-test image\n");
      return 1;
    }
    MPPImage *frame = [[MPPImage alloc] initWithUIImage:image error:&error];
    if (!frame) {
      fprintf(stderr, "Image conversion failed: %s\n", error.description.UTF8String);
      return 1;
    }
    for (int i = 0; i < 3; ++i) {
      MPPHolisticLandmarkerResult *result = [landmarker detectVideoFrame:frame
                                              timestampInMilliseconds:i * 33 error:&error];
      if (!result || result.poseLandmarks.count != kPoseLandmarks ||
          result.faceLandmarks.count < kMinimumFaceLandmarks ||
          result.leftHandLandmarks.count != kHandLandmarks ||
          result.rightHandLandmarks.count != kHandLandmarks) {
        fprintf(stderr, "Frame %d: expected pose=%lu face>=%lu leftHand=%lu rightHand=%lu; got "
                "pose=%lu face=%lu leftHand=%lu rightHand=%lu. %s\n", i,
                (unsigned long)kPoseLandmarks, (unsigned long)kMinimumFaceLandmarks,
                (unsigned long)kHandLandmarks, (unsigned long)kHandLandmarks,
                (unsigned long)result.poseLandmarks.count, (unsigned long)result.faceLandmarks.count,
                (unsigned long)result.leftHandLandmarks.count,
                (unsigned long)result.rightHandLandmarks.count, error.description.UTF8String ?: "");
        return 1;
      }
      if (!AllFinite(result.poseLandmarks, "pose", i) ||
          !AllFinite(result.faceLandmarks, "face", i) ||
          !AllFinite(result.leftHandLandmarks, "left hand", i) ||
          !AllFinite(result.rightHandLandmarks, "right hand", i)) {
        return 1;
      }
      fprintf(stderr, "Frame %d: pose=%lu face=%lu leftHand=%lu rightHand=%lu\n", i,
              (unsigned long)result.poseLandmarks.count, (unsigned long)result.faceLandmarks.count,
              (unsigned long)result.leftHandLandmarks.count, (unsigned long)result.rightHandLandmarks.count);
    }
    fprintf(stderr, "MediaPipe smoke: PASS\n");
    return 0;
  }
}
