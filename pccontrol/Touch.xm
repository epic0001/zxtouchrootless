#include "Touch.h"
#include "Common.h"
#include "Screen.h"
#include "AlertBox.h"
#include <os/lock.h>
#include <string.h>

#define TOUCH_SENDER_ID_PLIST_FILE_NAME @"senderid.plist"

#define MAX_FINGER_INDEX 20

// Persist active fingers in normalized IOHID coordinates so an event for
// another finger cannot reinterpret them using a different screen orientation.
typedef struct {
    int type;
    ZXNormalizedPoint point;
    bool active;
} ActiveFinger;

static ActiveFinger activeFingers[MAX_FINGER_INDEX];
static os_unfair_lock touchLock = OS_UNFAIR_LOCK_INIT;

IOHIDEventSystemClientRef ioHIDEventSystemForSenderID = NULL;
unsigned long long int senderID = 0x0;

static int readDigits(const UInt8 *digits, int length)
{
    int value = 0;
    for (int i = 0; i < length; i++) {
        value = value * 10 + (digits[i] - '0');
    }
    return value;
}

static void appendChildEvent(IOHIDEventRef parent, int type, int index, ZXNormalizedPoint point)
{
    int eventMask = type == TOUCH_DOWN ? 3 : type == TOUCH_MOVE ? 4 : 2;
    bool touching = type != TOUCH_UP;
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, mach_absolute_time(), index, 3, eventMask,
        point.x, point.y, 0.0f, 0.0f, 0.0f, touching, touching, 0);
    if (!child) {
        return;
    }
    IOHIDEventSetFloatValue(child, 0xb0014, 0.04f);
    IOHIDEventSetFloatValue(child, 0xb0015, 0.04f);
    IOHIDEventAppendEvent(parent, child);
    CFRelease(child);
}

static void performTouchPacket(const UInt8 *eventData, ZXScreenFrame frame)
{
    const char *packet = (const char *)eventData;
    size_t digits = strspn(packet, "0123456789");
    if (digits < 1 || digits != strcspn(packet, "\r\n") || frame.width <= 0 || frame.height <= 0) {
        return;
    }
    int count = eventData[0] - '0';
    if (count == 0 || digits != 1 + (size_t)count * TOUCH_DATA_LEN) {
        return;
    }

    for (int i = 0; i < count; i++) {
        const UInt8 *touch = eventData + 1 + i * TOUCH_DATA_LEN;
        if (touch[0] - '0' > TOUCH_MOVE || readDigits(touch + 1, 2) >= MAX_FINGER_INDEX) {
            return;
        }
    }

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                         3, 99, 1, 0, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0, 0, 0);
    if (!parent) {
        return;
    }
    IOHIDEventSetIntegerValue(parent, 0xb0019, 1);
    IOHIDEventSetIntegerValue(parent, 0x4, 1);

    bool included[MAX_FINGER_INDEX] = {};
    os_unfair_lock_lock(&touchLock);
    for (int i = 0; i < count; i++) {
        const UInt8 *touch = eventData + 1 + i * TOUCH_DATA_LEN;
        int type = touch[0] - '0';
        int index = readDigits(touch + 1, 2);
        double x = readDigits(touch + 3, 5) / 10.0;
        double y = readDigits(touch + 8, 5) / 10.0;
        ZXNormalizedPoint point = ZXNormalizeTouch(frame, x, y);

        appendChildEvent(parent, type, index, point);
        activeFingers[index] = (ActiveFinger){type, point, type != TOUCH_UP};
        included[index] = true;
    }
    for (int index = 0; index < MAX_FINGER_INDEX; index++) {
        ActiveFinger finger = activeFingers[index];
        if (finger.active && !included[index]) {
            appendChildEvent(parent, finger.type, index, finger.point);
        }
    }

    IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);
    IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1);
    IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1);
    postIOHIDEvent(parent);
    os_unfair_lock_unlock(&touchLock);
    CFRelease(parent);
}

void performTouchFromRawData(const UInt8 *eventData)
{
    performTouchPacket(eventData, [Screen getScreenFrame]);
}

void performRecordedTouchFromRawData(const UInt8 *eventData)
{
    // The on-disk .raw format stores physical portrait pixels.
    ZXScreenFrame frame = {(int)[Screen getScreenWidth], (int)[Screen getScreenHeight], ZXFrameUpright};
    performTouchPacket(eventData, frame);
}

static void postIOHIDEvent(IOHIDEventRef event)
{
    static IOHIDEventSystemClientRef ioSystemClient = NULL;
    if (!ioSystemClient) {
        ioSystemClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    if (senderID != 0) {
        IOHIDEventSetSenderID(event, senderID);
    } else {
        NSLog(@"### com.zjx.springboard: sender id is 0!");
        return;
    }
    IOHIDEventSystemClientDispatchEvent(ioSystemClient, event);
}

/*
Get sender id. If the device has not been rebooted, read senderid from file. Otherwise start set sender id callback
*/
void initSenderId()
{
    NSString *plistPath = [NSString stringWithFormat:@"%@/coreutils/touching/%@", getDocumentRoot(), TOUCH_SENDER_ID_PLIST_FILE_NAME];
    if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath])
    {
        // check start time
        NSInteger currentTime = [[NSDate date] timeIntervalSince1970];
        NSInteger timeSinceReboot = [NSProcessInfo processInfo].systemUptime;
        NSInteger thisRebootTime = currentTime - timeSinceReboot;
        NSLog(@"com.zjx.springboard: currentTime: %ld, time since reboot: %ld, last reboot time: %ld", currentTime, timeSinceReboot, thisRebootTime);
        
        NSDictionary *data = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSInteger lastRebootTime = [data[@"lastReboot"] longValue];
        
        if (abs(lastRebootTime - thisRebootTime) <= 3)
        {
            senderID = [data[@"senderID"] longLongValue];
            NSLog(@"com.zjx.springboard: since the device has not been rebooted. Read sender id from the file. SenderID get: %qX", senderID);
            return;
        }
    }
    
    NSLog(@"com.zjx.springboard: cannot read the sender id from file because the file doesn't exist or the device has restarted. Start set senderid callback.");
    startSetSenderIDCallBack();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // I know the code here is bad here, change this later.
        while (true)
        {
            [NSThread sleepForTimeInterval:2.0f];

            if (ioHIDEventSystemForSenderID != NULL && senderID != 0x0) // unregister the callback
            {
                IOHIDEventSystemClientUnregisterEventCallback(ioHIDEventSystemForSenderID);
                IOHIDEventSystemClientUnscheduleWithRunLoop(ioHIDEventSystemForSenderID, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
                NSLog(@"com.zjx.springboard: unregister get sender id callback!");
                break;
            }
        }
    });

}


/*
Get the sender id and unregister itself.
*/
static void setSenderIdCallback(void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    if (IOHIDEventGetType(event) == kIOHIDEventTypeDigitizer){
		if (senderID == 0x0)
        {
            NSError *err = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithFormat:@"%@/coreutils/touching/", getDocumentRoot()] withIntermediateDirectories:YES attributes:nil error:&err];
            if (err)
            {
                NSLog(@"Cannot save senderid for future use, but the tweak should work fine. Error: %@", err);
            }

			senderID = IOHIDEventGetSenderID(event);

            NSInteger currentTime = [[NSDate date] timeIntervalSince1970];
            NSInteger timeSinceReboot = [NSProcessInfo processInfo].systemUptime;
            NSInteger rebootTime = currentTime - timeSinceReboot;

            NSDictionary *dict = @{@"lastReboot":@(rebootTime), @"senderID": @(senderID)};

            [dict writeToFile:[NSString stringWithFormat:@"%@/coreutils/touching/%@", getDocumentRoot(), TOUCH_SENDER_ID_PLIST_FILE_NAME] atomically: YES];

            NSLog(@"com.zjx.springboard: sender id is: %qX", senderID);
        }
    }
}

/**
Start the callback for setting sender id
*/
void startSetSenderIDCallBack()
{
    ioHIDEventSystemForSenderID = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientScheduleWithRunLoop(ioHIDEventSystemForSenderID, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDEventSystemClientRegisterEventCallback(ioHIDEventSystemForSenderID, (IOHIDEventSystemClientEventCallback)setSenderIdCallback, NULL, NULL);
}
