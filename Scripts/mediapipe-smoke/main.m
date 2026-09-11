// Exercises the real Tasks API and graph, independently of app startup and downloaded-model UI.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPipeTasksVision/MediaPipeTasksVision.h>
#include <math.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 3) {
      fprintf(stderr, "Usage: smoke <holistic_landmarker.task> <image-with-visible-person>\n");
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
      if (!result || result.poseLandmarks.count != 33) {
        fprintf(stderr, "Frame %d: expected 33 pose landmarks; got %lu. %s\n", i,
                (unsigned long)result.poseLandmarks.count, error.description.UTF8String ?: "");
        return 1;
      }
      for (MPPNormalizedLandmark *point in result.poseLandmarks) {
        if (!isfinite(point.x) || !isfinite(point.y) || !isfinite(point.z)) {
          fprintf(stderr, "Frame %d: non-finite pose landmark\n", i);
          return 1;
        }
      }
      fprintf(stderr, "Frame %d: pose=%lu face=%lu leftHand=%lu rightHand=%lu\n", i,
              (unsigned long)result.poseLandmarks.count, (unsigned long)result.faceLandmarks.count,
              (unsigned long)result.leftHandLandmarks.count, (unsigned long)result.rightHandLandmarks.count);
    }
    fprintf(stderr, "MediaPipe smoke: PASS\n");
    return 0;
  }
}
