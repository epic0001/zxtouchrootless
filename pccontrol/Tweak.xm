#include "headers/BKUserEventTimer.h"
#import <QuartzCore/QuartzCore.h>

#include <UIKit/UIKit.h>
#include <objc/runtime.h>
#include <sys/sysctl.h>
#include <sys/xattr.h>
#include <substrate.h>
#include <math.h>

#include <mach/mach.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDService.h>

#include<mach-o/dyld.h>

#include <stdlib.h>
#include "socketConfig.h"

#include <stdio.h>
#include <unistd.h>
#include <signal.h>

#include <notify.h>
#include "headers/CFUserNotification.h"
#import <os/lock.h>

#include "Touch.h"
#include "SocketServer.h"
#include "RemoteDashboardServer.h"
#include "Common.h"
#include "Screen.h"
#include "AlertBox.h"
#include "Popup.h"
#include "Record.h"
#include "Toast.h"
#include "Play.h"
#include "TouchIndicator/TouchIndicatorWindow.h"
#include <roothide.h>

#define IPHONE7P_HEIGHT 1920
#define IPHONE7P_WIDTH 1080

#define IPADPRO_HEIGHT 2732
#define IPADPRO_WIDTH 2048

#define SET_SIZE 9




int daemonSock = -1;
static int remoteDashboardNotificationToken = 0;


typedef struct　eventInfo_s* eventInfo;
typedef struct Node* llNodePtr;
typedef struct eventData_s* eventDataPtr;


const int TOUCH_EVENT_ARR_LEN = 20;

Boolean isCrazyTapping = false;
Boolean isRecording = false;



const NSString *recordingScriptName = @"rec";


eventInfo touchEventArr[TOUCH_EVENT_ARR_LEN] = {0};


llNodePtr eventLinkedListHead = NULL;


Boolean isInitializedSuccess = true;

int getDaemonSocket();
void *(*IOHIDEventAppendEventOld)(IOHIDEventRef parent, IOHIDEventRef child);


float getRandomNumberFloat(float min, float max);

int getTaskType(UInt8* dataArray);

void handle_event (void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event);




void setSenderIdCallback(void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event);

static void stopCrazyTapCallback();
void crazyTapTimeUpCallback();
void stopCrazyTap();
void processTask(UInt8 *buff);

void updateSwtichAppBeforeRunScript(BOOL value);
BOOL openPopUpByDoubleVolumnDown = true;

// -------------
IOHIDEventSystemClientRef ioHIDEventSystemForPopupDectect = NULL;
PopupWindow *popupWindow;

#define ZX_ACTION_SMART_TOGGLE @"smart_toggle"
#define ZX_ACTION_TOGGLE_PANEL @"toggle_panel"
#define ZX_ACTION_STOP_SCRIPT @"stop_script"
#define ZX_ACTION_TOGGLE_RECORDING @"toggle_recording"
#define ZX_ACTION_RUN_SCRIPT @"run_script"

#define ZX_TRIGGER_VOLUME_UP @"volume_up"
#define ZX_TRIGGER_VOLUME_DOWN @"volume_down"
#define ZX_TRIGGER_HOME @"home"


void stopCrazyTap()
{
    isCrazyTapping = false;
}




/*
A callback to stop crazy tap.

Note: using a callback to stop crazy tap is because the socket server may not respond while crazy tapping
*/
static void stopCrazyTapCallback()
{
    stopCrazyTap();
}


void crazyTapTimeUpCallback(int sig)
{
    NSLog(@"com.zjx.springboard: crazy tap stop.");
    stopCrazyTap();
}

void dontPutThisFileIntoIda()
{
    return;
}

void becauseTheSourceCodeWillBeReleasedAtGithub()
{
    return;
}

void repoNameIsIOS13SimulateTouch()
{
    return;
}

/*
Get the sender id and unregister itself.
*/
static NSMutableDictionary *triggerClickState = nil;
static void showOrHidePopup()
{
    if (![popupWindow isShown])
        [popupWindow show];
    else
        [popupWindow hide];
}

static void runConfiguredTriggerAction(NSString *action, NSString *scriptPath)
{
    if (!action || [action length] == 0) action = ZX_ACTION_SMART_TOGGLE;

    if ([action isEqualToString:ZX_ACTION_STOP_SCRIPT])
    {
        NSError *err = nil;
        stopScriptPlaying(&err);
        showAlertBox(@"ZXTouch", @"Script stopped.", 1);
        return;
    }

    if ([action isEqualToString:ZX_ACTION_TOGGLE_RECORDING])
    {
        if (isRecordingStart())
        {
            stopRecording();
            showAlertBox(@"ZXTouch", @"Recording stopped and saved.", 1);
        }
        else
        {
            NSError *err = nil;
            startRecording(0, &err);
            if (err) showAlertBox(@"Error", [NSString stringWithFormat:@"Unable to start recording: %@", [err localizedDescription]], 999);
            else showAlertBox(@"ZXTouch", @"Recording started.", 1);
        }
        return;
    }

    if ([action isEqualToString:ZX_ACTION_RUN_SCRIPT])
    {
        if (scriptPath && [scriptPath length] > 0)
        {
            NSError *err = nil;
            playScript((UInt8*)[scriptPath UTF8String], &err);
            if (err) showAlertBox(@"Error", [err localizedDescription], 999);
        }
        else
        {
            showAlertBox(@"ZXTouch", @"No default trigger script is set.", 2);
        }
        return;
    }

    if ([action isEqualToString:ZX_ACTION_TOGGLE_PANEL])
    {
        showOrHidePopup();
        return;
    }

    if (isScriptPlaying())
    {
        NSError *err = nil;
        stopScriptPlaying(&err);
        showAlertBox(@"ZXTouch", @"Script stopped.", 1);
        return;
    }
    if (isRecordingStart())
    {
        stopRecording();
        showAlertBox(@"ZXTouch", @"Recording stopped and saved.", 1);
        [popupWindow show];
        return;
    }
    showOrHidePopup();
}

static NSString *triggerKeyForKeyboardUsage(long usage)
{
    if (usage == 233) return ZX_TRIGGER_VOLUME_UP;
    if (usage == 234) return ZX_TRIGGER_VOLUME_DOWN;
    if (usage == 64 || usage == 74) return ZX_TRIGGER_HOME;
    return nil;
}

static NSDictionary *configForTrigger(NSDictionary *config, NSString *triggerKey)
{
    NSDictionary *triggers = config[@"trigger_configs"];
    NSDictionary *trigger = [triggers isKindOfClass:[NSDictionary class]] ? triggers[triggerKey] : nil;
    if ([trigger isKindOfClass:[NSDictionary class]]) return trigger;

    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_DOWN]) {
        BOOL enabled = config[@"double_click_volume_show_popup"] ? [config[@"double_click_volume_show_popup"] boolValue] : YES;
        NSString *action = config[@"double_click_volume_action"] ?: ZX_ACTION_SMART_TOGGLE;
        NSString *script = config[@"double_click_volume_script"] ?: @"";
        return @{
            @"enabled": @(enabled),
            @"count": @(2),
            @"action": action,
            @"script": script
        };
    }
    return @{@"enabled": @(NO), @"count": @(2), @"action": ZX_ACTION_SMART_TOGGLE, @"script": @""};
}

static void handleConfiguredTriggerClick(NSString *triggerKey)
{
    if (!triggerClickState) triggerClickState = [NSMutableDictionary dictionary];
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:getCommonConfigFilePath()] ?: @{};
    NSDictionary *trigger = configForTrigger(config, triggerKey);
    if (![trigger[@"enabled"] boolValue]) return;

    int requiredCount = [trigger[@"count"] intValue];
    if (requiredCount < 1) requiredCount = 1;
    if (requiredCount > 5) requiredCount = 5;

    CFTimeInterval now = CACurrentMediaTime();
    NSMutableDictionary *state = [triggerClickState[triggerKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    CFTimeInterval lastTime = [state[@"time"] doubleValue];
    int count = (now - lastTime <= 0.55) ? [state[@"count"] intValue] + 1 : 1;
    state[@"time"] = @(now);
    state[@"count"] = @(count);
    triggerClickState[triggerKey] = state;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.58 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMutableDictionary *currentState = triggerClickState[triggerKey];
        if ([currentState[@"count"] intValue] != count) return;
        if (fabs([currentState[@"time"] doubleValue] - now) > 0.01) return;
        currentState[@"count"] = @(0);

        NSDictionary *latestConfig = [[NSDictionary alloc] initWithContentsOfFile:getCommonConfigFilePath()] ?: @{};
        NSDictionary *latestTrigger = configForTrigger(latestConfig, triggerKey);
        int latestRequired = [latestTrigger[@"count"] intValue];
        if (latestRequired < 1) latestRequired = 1;
        if (latestRequired > 5) latestRequired = 5;
        if ([latestTrigger[@"enabled"] boolValue] && count == latestRequired) {
            runConfiguredTriggerAction(latestTrigger[@"action"], latestTrigger[@"script"]);
        }
    });
}

// perform some action
static void popupWindowCallBack(void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    if (IOHIDEventGetType(event) == kIOHIDEventTypeKeyboard)
    {
        if (IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardDown) == 0)
        {
            long usage = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardUsage);
            NSString *triggerKey = triggerKeyForKeyboardUsage(usage);
            if (triggerKey) handleConfiguredTriggerClick(triggerKey);
        }
    }
}

/**
Start the callback for setting sender id
*/
void startPopupListeningCallBack()
{
    ioHIDEventSystemForPopupDectect = IOHIDEventSystemClientCreate(kCFAllocatorDefault);

    IOHIDEventSystemClientScheduleWithRunLoop(ioHIDEventSystemForPopupDectect, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDEventSystemClientRegisterEventCallback(ioHIDEventSystemForPopupDectect, (IOHIDEventSystemClientEventCallback)popupWindowCallBack, NULL, NULL);
    //NSLog(@"### com.zjx.springboard: screen width: %f, screen height: %f", device_screen_width, device_screen_height);
}


Boolean initConfig()
{
    // read config file
    // check whether config file exist
    NSString *configFilePath = getCommonConfigFilePath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:configFilePath]) // if missing, then use the default value
    {
        //showAlertBox(@"Error", configFilePath, 999);
        NSLog(@"com.zjx.springboard: unable to get config file. File not found. Using default value. Path: %@", configFilePath);
        return true;
    }
    // read indicator color from the config file
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:configFilePath];
    if ([config[@"touch_indicator"][@"show"] boolValue])
    {
        NSError *err = nil;
        startTouchIndicator(&err);
        if (err)
        {
            showAlertBox(@"Error", [NSString stringWithFormat:@"Cannot start touch indicator, error info: %@", err], 999);
        }
    }

    if (config[@"double_click_volume_show_popup"])
    {
        NSLog(@"com.zjx.springboard: show popup %d", [config[@"double_click_volume_show_popup"] boolValue]);
        openPopUpByDoubleVolumnDown = [config[@"double_click_volume_show_popup"] boolValue];
    }

    if (config[@"switch_app_before_run_script"])
    {
        updateSwtichAppBeforeRunScript([config[@"switch_app_before_run_script"] boolValue]);
    }

    return true;
}

Boolean init()
{
    initScriptPlayer();
    initConfig();

    return true;
}

%hook SBHomeScreenViewController

- (void)viewDidLoad {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [@"1-block-started" writeToFile:@"/var/mobile/d1.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

            // nativeBounds is always in portrait physical pixels, unaffected by rotation
            CGRect nativeBounds = [UIScreen mainScreen].nativeBounds;
            CGFloat width = nativeBounds.size.width;
            CGFloat height = nativeBounds.size.height;
            [Screen setScreenSize:(width<height?width:height) height:(width>height?width:height)];
            [@"3-screen-set" writeToFile:@"/var/mobile/d3.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

            popupWindow = [[PopupWindow alloc] init];
            [@"4-popup-init" writeToFile:@"/var/mobile/d4.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

            initSenderId();
            startPopupListeningCallBack();
            [@"5-sender-init" writeToFile:@"/var/mobile/d5.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

            if (!init()) { return; }
            [@"6-init-done" writeToFile:@"/var/mobile/d6.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

            call_system("chown -R mobile:mobile /var/mobile/Library/ZXTouch");
            [@"7-before-socketServer" writeToFile:@"/var/mobile/d7.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

            socketServer();
        });
    });
}

%end

%ctor {
    %init;
    notify_register_dispatch("com.zjx.zxtouch.remote-dashboard-changed", &remoteDashboardNotificationToken, dispatch_get_main_queue(), ^(int token) {
        ZXDashboardReloadConfiguration();
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        ZXDashboardReloadConfiguration();
    });
}
