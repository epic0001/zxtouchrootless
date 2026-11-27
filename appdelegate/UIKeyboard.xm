#include "UIKeyboard.h"
#include "../pccontrol/KeyboardIPC.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static int gCmdToken = NOTIFY_TOKEN_INVALID;
static int gAckToken = NOTIFY_TOKEN_INVALID;
static int gDataTokens[ZX_KBD_DATA_SLOTS];
static uint32_t gLastSeq = 0;

%ctor {
    @autoreleasepool {
        // SpringBoard handles its own windows directly inside pccontrol.
        NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
        if ([bundleId isEqualToString:@"com.apple.springboard"]) {
            return;
        }

        notify_register_check(ZX_KBD_NOTIFY_ACK, &gAckToken);
        for (int i = 0; i < ZX_KBD_DATA_SLOTS; i++) {
            gDataTokens[i] = NOTIFY_TOKEN_INVALID;
            notify_register_check(zxKbdDataSlotName(i), &gDataTokens[i]);
        }

        dispatch_queue_t queue = dispatch_queue_create("com.zjx.zxtouch.appdelegate.kbd", DISPATCH_QUEUE_SERIAL);
        notify_register_dispatch(ZX_KBD_NOTIFY_CMD, &gCmdToken, queue, ^(int token) {
            uint64_t cmdState = 0;
            if (notify_get_state(token, &cmdState) != NOTIFY_STATUS_OK) return;

            uint32_t seq = 0;
            uint8_t taskId = 0;
            uint8_t payloadLen = 0;
            int16_t arg16 = 0;
            zxKbdUnpackCmd(cmdState, &seq, &taskId, &payloadLen, &arg16);

            if (seq == 0 || seq == gLastSeq) return;
            gLastSeq = seq;

            NSString *content = nil;
            if (taskId == ZX_KBD_INSERT_TEXT && payloadLen > 0) {
                if (payloadLen > ZX_KBD_MAX_CHUNK_BYTES) {
                    payloadLen = ZX_KBD_MAX_CHUNK_BYTES;
                }
                uint8_t buf[ZX_KBD_MAX_CHUNK_BYTES];
                memset(buf, 0, sizeof(buf));
                int slotCount = (payloadLen + 7) / 8;
                for (int i = 0; i < slotCount && i < ZX_KBD_DATA_SLOTS; i++) {
                    uint64_t word = 0;
                    notify_get_state(gDataTokens[i], &word);
                    size_t offset = (size_t)i * 8;
                    size_t copyLen = (payloadLen - offset < 8) ? (payloadLen - offset) : 8;
                    memcpy(buf + offset, &word, copyLen);
                }
                content = [[NSString alloc] initWithBytes:buf length:payloadLen encoding:NSUTF8StringEncoding];
                if (!content) return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    if (zxKbdPerformInCurrentProcess(taskId, content, arg16)) {
                        notify_set_state(gAckToken, zxKbdPackAck(seq, 1));
                        notify_post(ZX_KBD_NOTIFY_ACK);
                    }
                }
            });
        });
    }
}
