#ifndef TOUCH_H
#define TOUCH_H

#import <Foundation/Foundation.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wattributes"
#include "headers/IOHIDEvent.h"
#include "headers/IOHIDEventData.h"
#include "headers/IOHIDEventTypes.h"
#include "headers/IOHIDEventSystemClient.h"
#include "headers/IOHIDEventSystem.h"
#pragma clang diagnostic pop

#include <mach/mach_time.h>

#define TOUCH_UP 0
#define TOUCH_DOWN 1
#define TOUCH_MOVE 2

const int TOUCH_DATA_LEN = 13;

void performTouchFromRawData(const UInt8 *eventData);
void performRecordedTouchFromRawData(const UInt8 *eventData);

static void postIOHIDEvent(IOHIDEventRef event);
static void setSenderIdCallback(void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event);
void startSetSenderIDCallBack();
void initSenderId();

#endif