#include "UIKeyboard.h"
#include "KeyboardIPC.h"
#import <UIKit/UIKit.h>
#include <stdatomic.h>

static dispatch_queue_t gKbdSendQueue = nil;
static dispatch_queue_t gKbdAckQueue = nil;
static dispatch_semaphore_t gKbdAckSem = nil;

static int gCmdToken = NOTIFY_TOKEN_INVALID;
static int gAckToken = NOTIFY_TOKEN_INVALID;
static int gDataTokens[ZX_KBD_DATA_SLOTS];

static uint32_t gNextSeq = 1;
static _Atomic uint32_t gExpectedSeq = 0;

static void zxKbdInitSenderIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gKbdSendQueue = dispatch_queue_create("com.zjx.zxtouch.kbd.send", DISPATCH_QUEUE_SERIAL);
        gKbdAckQueue = dispatch_queue_create("com.zjx.zxtouch.kbd.ack", DISPATCH_QUEUE_SERIAL);
        gKbdAckSem = dispatch_semaphore_create(0);

        notify_register_check(ZX_KBD_NOTIFY_CMD, &gCmdToken);
        for (int i = 0; i < ZX_KBD_DATA_SLOTS; i++) {
            gDataTokens[i] = NOTIFY_TOKEN_INVALID;
            notify_register_check(zxKbdDataSlotName(i), &gDataTokens[i]);
        }

        notify_register_dispatch(ZX_KBD_NOTIFY_ACK, &gAckToken, gKbdAckQueue, ^(int token) {
            uint64_t ackState = 0;
            if (notify_get_state(token, &ackState) != NOTIFY_STATUS_OK) return;
            uint32_t ackSeq = 0;
            uint32_t status = 0;
            zxKbdUnpackAck(ackState, &ackSeq, &status);
            if (ackSeq == 0 || status != 1) return;

            uint32_t expected = ackSeq;
            if (atomic_compare_exchange_strong(&gExpectedSeq, &expected, 0)) {
                dispatch_semaphore_signal(gKbdAckSem);
            }
        });
    });
}

static BOOL zxKbdTryInSpringBoard(uint8_t taskId, NSString *content, int16_t arg16) {
    __block BOOL handled = NO;
    void (^work)(void) = ^{
        handled = zxKbdPerformInCurrentProcess(taskId, content, arg16);
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return handled;
}

static BOOL zxKbdSendSingleCommandViaNotify(uint8_t taskId, const uint8_t *utf8Bytes, uint8_t utf8Len, int16_t arg16) {
    __block BOOL acked = NO;
    dispatch_sync(gKbdSendQueue, ^{
        // Write payload slots before posting command trigger
        int slotCount = (utf8Len + 7) / 8;
        for (int i = 0; i < slotCount && i < ZX_KBD_DATA_SLOTS; i++) {
            uint64_t word = 0;
            size_t offset = (size_t)i * 8;
            size_t copyLen = (utf8Len - offset < 8) ? (utf8Len - offset) : 8;
            memcpy(&word, utf8Bytes + offset, copyLen);
            notify_set_state(gDataTokens[i], word);
        }

        uint32_t seq = gNextSeq++;
        if (gNextSeq == 0) gNextSeq = 1;

        atomic_store(&gExpectedSeq, seq);
        notify_set_state(gCmdToken, zxKbdPackCmd(seq, taskId, utf8Len, arg16));
        notify_post(ZX_KBD_NOTIFY_CMD);

        long waitResult = dispatch_semaphore_wait(
            gKbdAckSem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC))
        );

        if (waitResult == 0) {
            acked = YES;
        } else {
            // Clear expected sequence so any late ACK does not drift semaphore count.
            uint32_t expected = seq;
            if (!atomic_compare_exchange_strong(&gExpectedSeq, &expected, 0)) {
                // ACK arrived concurrently just as wait timed out — drain the signal.
                dispatch_semaphore_wait(gKbdAckSem, DISPATCH_TIME_NOW);
                acked = YES;
            }
        }
    });
    return acked;
}

static BOOL zxKbdSendTextChunked(NSString *text) {
    if (!text || text.length == 0) return YES;

    NSUInteger index = 0;
    NSUInteger totalLen = text.length;
    while (index < totalLen) {
        NSMutableString *chunk = [NSMutableString string];
        NSUInteger chunkUtf8Len = 0;

        while (index < totalLen) {
            NSRange seqRange = [text rangeOfComposedCharacterSequenceAtIndex:index];
            NSString *piece = [text substringWithRange:seqRange];
            NSUInteger pieceUtf8Len = [piece lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

            if (chunkUtf8Len > 0 && chunkUtf8Len + pieceUtf8Len > ZX_KBD_MAX_CHUNK_BYTES) {
                break;
            }
            if (pieceUtf8Len > ZX_KBD_MAX_CHUNK_BYTES) {
                // Pathological composed sequence > 64 bytes: skip to avoid infinite loop
                index = NSMaxRange(seqRange);
                continue;
            }
            [chunk appendString:piece];
            chunkUtf8Len += pieceUtf8Len;
            index = NSMaxRange(seqRange);
        }

        if (chunkUtf8Len == 0) continue;

        NSData *utf8Data = [chunk dataUsingEncoding:NSUTF8StringEncoding];
        if (!utf8Data || utf8Data.length == 0) continue;

        if (!zxKbdSendSingleCommandViaNotify(
                ZX_KBD_INSERT_TEXT,
                (const uint8_t *)utf8Data.bytes,
                (uint8_t)utf8Data.length,
                0)) {
            return NO;
        }
    }
    return YES;
}

NSString* inputTextFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *raw = [NSString stringWithUTF8String:(const char *)eventData];
    if (!raw || raw.length == 0)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Keyboard related event length error. You have to specify the task id.\r\n"}];
        return nil;
    }

    NSRange sep = [raw rangeOfString:@";;"];
    int taskType = 0;
    NSString *taskContent = @"";
    BOOL hasContent = NO;

    if (sep.location != NSNotFound) {
        taskType = [[raw substringToIndex:sep.location] intValue];
        taskContent = [raw substringFromIndex:NSMaxRange(sep)];
        hasContent = YES;
    } else {
        taskType = [raw intValue];
    }

    if (taskType == ZX_KBD_GET_CLIPBOARD)
    {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        return pasteboard.string ?: @"";
    }
    else if (taskType == ZX_KBD_SAVE_CLIPBOARD)
    {
        if (!hasContent)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Keyboard related event error. You have to specify the content you want to paste to clipboard.\r\n"}];
            return nil;
        }
        [UIPasteboard generalPasteboard].string = taskContent;
        return @"";
    }

    zxKbdInitSenderIfNeeded();

    if (taskType == ZX_KBD_PASTE_FROM_CLIPBOARD)
    {
        NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
        if (clip.length == 0) return @"";
        taskType = ZX_KBD_INSERT_TEXT;
        taskContent = clip;
    }

    if (taskType == ZX_KBD_INSERT_TEXT)
    {
        if (taskContent.length == 0) return @"";

        if (zxKbdTryInSpringBoard(ZX_KBD_INSERT_TEXT, taskContent, 0)) {
            return @"";
        }
        if (zxKbdSendTextChunked(taskContent)) {
            return @"";
        }
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:998 userInfo:@{
            NSLocalizedDescriptionKey:@"-1;;No focused text field or target process not injected\r\n"
        }];
        return nil;
    }

    if (taskType == ZX_KBD_VIRTUAL_KEYBOARD ||
        taskType == ZX_KBD_MOVE_CURSOR ||
        taskType == ZX_KBD_DELETE_CHARACTER)
    {
        long long rawArg = [taskContent longLongValue];
        if (rawArg > INT16_MAX) rawArg = INT16_MAX;
        if (rawArg < INT16_MIN) rawArg = INT16_MIN;
        int16_t arg16 = (int16_t)rawArg;

        if (zxKbdTryInSpringBoard((uint8_t)taskType, nil, arg16)) {
            return @"";
        }
        if (zxKbdSendSingleCommandViaNotify((uint8_t)taskType, NULL, 0, arg16)) {
            return @"";
        }
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:998 userInfo:@{
            NSLocalizedDescriptionKey:@"-1;;No focused text field or target process not injected\r\n"
        }];
        return nil;
    }

    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{
        NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;Unknown keyboard task type: %d\r\n", taskType]
    }];
    return nil;
}
