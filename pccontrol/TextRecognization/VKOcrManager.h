#ifndef VKOcrManager_H
#define VKOcrManager_H

#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

@interface VKOcrManager : NSObject
- (id)initWithCGImage:(CGImageRef)cgimage area:(CGRect)aarea;

- (NSString*)recognize:(NSError**)error;
- (NSArray*)areasOfText;
- (void)outputDebugImage:(NSString*)imagePath error:(NSError**)error;

- (void)setMinimumHeight:(float)height;
- (void)setCustomWords:(NSArray*)customWords;
- (void)setRecognitionLevel:(VNRequestTextRecognitionLevel)level;
- (void)setLanguages:(NSArray*)languages;
- (void)setCorrection:(BOOL)correct;

@end

#endif
