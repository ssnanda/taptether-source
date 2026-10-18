//go:build darwin && cgo

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdlib.h>
#include <math.h>

bool tt_capture_supported(void) {
    if (@available(macOS 14.0, *)) return true;
    return false;
}
bool tt_capture_permitted(void) {
    return CGPreflightScreenCaptureAccess();
}
void tt_request_capture_access(void) {
    CGRequestScreenCaptureAccess();
}

// SCScreenshotManager returns a transient CGImage. Draw directly into a
// bounded RGBA memory buffer; never create screenshot files on disk.
void *tt_primary_display(int *outW, int *outH, int maxW, int maxH) {
    @autoreleasepool {
        if (!tt_capture_supported() || maxW < 1 || maxH < 1 || maxW > 1920 || maxH > 1080) return NULL;
        __block CGImageRef captured = NULL;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:
            ^(SCShareableContent *content, NSError *shareError) {
            if (shareError != nil || content == nil || content.displays.count == 0) {
                dispatch_semaphore_signal(done);
                return;
            }
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) {
                if (candidate.displayID == CGMainDisplayID()) {
                    display = candidate;
                    break;
                }
            }
            if (display == nil) display = content.displays.firstObject;
            SCContentFilter *filter =
                [[[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]] autorelease];
            SCStreamConfiguration *config = [[[SCStreamConfiguration alloc] init] autorelease];
            config.capturesAudio = NO;
            config.showsCursor = YES;
            double sourceWidth = filter.contentRect.size.width * filter.pointPixelScale;
            double sourceHeight = filter.contentRect.size.height * filter.pointPixelScale;
            if (sourceWidth < 1 || sourceHeight < 1) {
                dispatch_semaphore_signal(done);
                return;
            }
            double ratio = fmin((double)maxW/sourceWidth, (double)maxH/sourceHeight);
            if (ratio > 1.0) ratio = 1.0;
            config.width = (size_t)(sourceWidth * ratio);
            config.height = (size_t)(sourceHeight * ratio);
            [SCScreenshotManager captureImageWithFilter:filter
                configuration:config
                completionHandler:^(CGImageRef image, NSError *captureError) {
                    if (image != NULL && captureError == nil) {
                        captured = CGImageRetain(image);
                    }
                    dispatch_semaphore_signal(done);
                }];
        }];
        if (dispatch_semaphore_wait(done,
                dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
            return NULL;
        }
        if (captured == NULL) return NULL;
        size_t originalW = CGImageGetWidth(captured);
        size_t originalH = CGImageGetHeight(captured);
        if (originalW < 1 || originalH < 1) {
            CGImageRelease(captured);
            return NULL;
        }
        double ratio = fmin((double)maxW/(double)originalW, (double)maxH/(double)originalH);
        if (ratio > 1.0) ratio = 1.0;
        size_t width = (size_t)(originalW * ratio);
        size_t height = (size_t)(originalH * ratio);
        if (width == 0 || height == 0 || width > (size_t)maxW || height > (size_t)maxH) {
            CGImageRelease(captured);
            return NULL;
        }
        void *pixels = calloc(width * height, 4);
        if (!pixels) { CGImageRelease(captured); return NULL; }
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8,
            width*4, colors, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colors);
        if (!ctx) { CGImageRelease(captured); free(pixels); return NULL; }
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        CGContextDrawImage(ctx, CGRectMake(0,0,width,height), captured);
        CGContextRelease(ctx);
        CGImageRelease(captured);
        *outW = (int)width;
        *outH = (int)height;
        return pixels;
    }
}
