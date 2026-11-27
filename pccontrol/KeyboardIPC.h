#ifndef ZX_KEYBOARD_IPC_H
#define ZX_KEYBOARD_IPC_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <notify.h>
#include <stdint.h>
#include <string.h>

#define ZX_KBD_INSERT_TEXT 1
#define ZX_KBD_VIRTUAL_KEYBOARD 2
#define ZX_KBD_MOVE_CURSOR 3
#define ZX_KBD_DELETE_CHARACTER 4
#define ZX_KBD_PASTE_FROM_CLIPBOARD 5
#define ZX_KBD_GET_CLIPBOARD 6
#define ZX_KBD_SAVE_CLIPBOARD 7

#define ZX_KBD_VIRTUAL_HIDE 1
#define ZX_KBD_VIRTUAL_SHOW 2

#define ZX_KBD_NOTIFY_CMD "com.zjx.zxtouch.kbd.cmd"
#define ZX_KBD_NOTIFY_ACK "com.zjx.zxtouch.kbd.ack"

#define ZX_KBD_DATA_SLOTS 8
#define ZX_KBD_MAX_CHUNK_BYTES (ZX_KBD_DATA_SLOTS * 8)

static inline const char *zxKbdDataSlotName(int index) {
    static const char *const kSlotNames[ZX_KBD_DATA_SLOTS] = {
        "com.zjx.zxtouch.kbd.d0",
        "com.zjx.zxtouch.kbd.d1",
        "com.zjx.zxtouch.kbd.d2",
        "com.zjx.zxtouch.kbd.d3",
        "com.zjx.zxtouch.kbd.d4",
        "com.zjx.zxtouch.kbd.d5",
        "com.zjx.zxtouch.kbd.d6",
        "com.zjx.zxtouch.kbd.d7",
    };
    if (index < 0 || index >= ZX_KBD_DATA_SLOTS) return kSlotNames[0];
    return kSlotNames[index];
}

static inline uint64_t zxKbdPackCmd(uint32_t seq, uint8_t taskId, uint8_t payloadLen, int16_t arg16) {
    return ((uint64_t)seq << 32)
         | ((uint64_t)taskId << 24)
         | ((uint64_t)payloadLen << 16)
         | ((uint64_t)(uint16_t)arg16);
}

static inline void zxKbdUnpackCmd(uint64_t state, uint32_t *seq, uint8_t *taskId, uint8_t *payloadLen, int16_t *arg16) {
    if (seq) *seq = (uint32_t)(state >> 32);
    if (taskId) *taskId = (uint8_t)((state >> 24) & 0xFF);
    if (payloadLen) *payloadLen = (uint8_t)((state >> 16) & 0xFF);
    if (arg16) *arg16 = (int16_t)(state & 0xFFFF);
}

static inline uint64_t zxKbdPackAck(uint32_t seq, uint32_t status) {
    return ((uint64_t)seq << 32) | (uint64_t)status;
}

static inline void zxKbdUnpackAck(uint64_t state, uint32_t *seq, uint32_t *status) {
    if (seq) *seq = (uint32_t)(state >> 32);
    if (status) *status = (uint32_t)(state & 0xFFFFFFFF);
}

@interface UIWindow (ZXKeyboardIPCPrivate)
- (UIResponder *)firstResponder;
+ (NSArray<UIWindow *> *)allWindowsIncludingInternalWindows:(BOOL)internal onlyVisibleWindows:(BOOL)visibleOnly;
@end

@interface ZXUIKeyboardImplProxy : UIView
+ (id)activeInstance;
- (void)insertText:(id)arg1;
- (void)hideKeyboard;
- (void)showKeyboard;
- (void)moveCursorByAmount:(long long)arg1;
- (void)deleteBackward;
- (id)inputDelegate;
- (id)privateInputDelegate;
@end

static inline NSArray<UIWindow *> *zxKbdCollectVisibleWindows(void) {
    NSMutableArray<UIWindow *> *keyWindows = [NSMutableArray array];
    NSMutableArray<UIWindow *> *otherWindows = [NSMutableArray array];
    NSHashTable<UIWindow *> *seen = [NSHashTable weakObjectsHashTable];

    void (^addWindow)(UIWindow *) = ^(UIWindow *win) {
        if (!win || [seen containsObject:win]) return;
        if (win.hidden || win.alpha <= 0.01) return;
        [seen addObject:win];
        if (win.isKeyWindow) {
            [keyWindows addObject:win];
        } else {
            [otherWindows addObject:win];
        }
    };

    if ([UIWindow respondsToSelector:@selector(allWindowsIncludingInternalWindows:onlyVisibleWindows:)]) {
        NSArray<UIWindow *> *allWins = [UIWindow allWindowsIncludingInternalWindows:YES onlyVisibleWindows:YES];
        for (UIWindow *win in allWins) {
            addWindow(win);
        }
    }

    UIApplication *app = [UIApplication respondsToSelector:@selector(sharedApplication)]
        ? [UIApplication sharedApplication]
        : nil;
    if (app) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        if ([app respondsToSelector:@selector(connectedScenes)]) {
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                    addWindow(win);
                }
            }
        }
#pragma clang diagnostic pop
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([app respondsToSelector:@selector(windows)]) {
            for (UIWindow *win in app.windows) {
                addWindow(win);
            }
        }
#pragma clang diagnostic pop
    }

    [keyWindows addObjectsFromArray:otherWindows];
    return keyWindows;
}

static inline UIResponder *zxKbdActiveFirstResponderInWindow(UIWindow *win) {
    if (!win || ![win respondsToSelector:@selector(firstResponder)]) return nil;
    UIResponder *r = [win firstResponder];
    if (!r) return nil;
    if ([r respondsToSelector:@selector(isFirstResponder)] && ![r isFirstResponder]) {
        return nil;
    }
    if ([r isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)r;
        if (v.hidden || !v.window || v.window.hidden || v.window.alpha <= 0.01) {
            return nil;
        }
    }
    return r;
}

static inline id zxKbdActiveKeyboardInstance(id *outDelegate) {
    Class kbdClass = NSClassFromString(@"UIKeyboardImpl");
    if (!kbdClass || ![kbdClass respondsToSelector:@selector(activeInstance)]) {
        if (outDelegate) *outDelegate = nil;
        return nil;
    }
    id kbd = [(id)kbdClass activeInstance];
    id delegate = nil;
    if (kbd && [kbd respondsToSelector:@selector(inputDelegate)]) {
        delegate = [kbd inputDelegate];
    }
    if (!delegate && kbd && [kbd respondsToSelector:@selector(privateInputDelegate)]) {
        delegate = [kbd privateInputDelegate];
    }
    if (outDelegate) *outDelegate = delegate;
    return kbd;
}

static inline BOOL zxKbdMoveCursorOnTextInput(id candidate, int16_t offset) {
    if (!candidate || ![candidate conformsToProtocol:@protocol(UITextInput)]) return NO;
    id<UITextInput> ti = (id<UITextInput>)candidate;
    UITextRange *selected = ti.selectedTextRange;
    if (!selected) return NO;
    UITextPosition *base = (offset < 0) ? selected.start : selected.end;
    UITextPosition *target = [ti positionFromPosition:base offset:(NSInteger)offset];
    if (!target) {
        target = (offset < 0) ? ti.beginningOfDocument : ti.endOfDocument;
    }
    if (!target) return NO;
    UITextRange *newRange = [ti textRangeFromPosition:target toPosition:target];
    if (!newRange) return NO;
    ti.selectedTextRange = newRange;
    return YES;
}

// Must be called on the main thread. Returns YES only if an active text input
// in this process actually handled the command.
static inline BOOL zxKbdPerformInCurrentProcess(uint8_t taskId, NSString *content, int16_t arg16) {
    NSArray<UIWindow *> *windows = zxKbdCollectVisibleWindows();
    id kbdDelegate = nil;
    id kbd = zxKbdActiveKeyboardInstance(&kbdDelegate);

    if (taskId == ZX_KBD_INSERT_TEXT) {
        NSString *text = content ?: @"";
        for (UIWindow *win in windows) {
            UIResponder *r = zxKbdActiveFirstResponderInWindow(win);
            if (r && [r respondsToSelector:@selector(insertText:)]) {
                [(id)r insertText:text];
                return YES;
            }
        }
        if (kbdDelegate && [kbdDelegate respondsToSelector:@selector(insertText:)]) {
            [kbdDelegate insertText:text];
            return YES;
        }
        if (kbdDelegate && kbd && [kbd respondsToSelector:@selector(insertText:)]) {
            [kbd insertText:text];
            return YES;
        }
        return NO;
    }

    if (taskId == ZX_KBD_DELETE_CHARACTER) {
        int count = (arg16 > 0) ? (int)arg16 : 1;
        for (UIWindow *win in windows) {
            UIResponder *r = zxKbdActiveFirstResponderInWindow(win);
            if (r && [r respondsToSelector:@selector(deleteBackward)]) {
                for (int i = 0; i < count; i++) {
                    [(id)r deleteBackward];
                }
                return YES;
            }
        }
        if (kbdDelegate && [kbdDelegate respondsToSelector:@selector(deleteBackward)]) {
            for (int i = 0; i < count; i++) {
                [kbdDelegate deleteBackward];
            }
            return YES;
        }
        if (kbdDelegate && kbd && [kbd respondsToSelector:@selector(deleteBackward)]) {
            for (int i = 0; i < count; i++) {
                [kbd deleteBackward];
            }
            return YES;
        }
        return NO;
    }

    if (taskId == ZX_KBD_MOVE_CURSOR) {
        for (UIWindow *win in windows) {
            UIResponder *r = zxKbdActiveFirstResponderInWindow(win);
            if (zxKbdMoveCursorOnTextInput(r, arg16)) {
                return YES;
            }
        }
        if (zxKbdMoveCursorOnTextInput(kbdDelegate, arg16)) {
            return YES;
        }
        if (kbdDelegate && kbd && [kbd respondsToSelector:@selector(moveCursorByAmount:)]) {
            [kbd moveCursorByAmount:(long long)arg16];
            return YES;
        }
        return NO;
    }

    if (taskId == ZX_KBD_VIRTUAL_KEYBOARD) {
        if (arg16 == ZX_KBD_VIRTUAL_HIDE) {
            for (UIWindow *win in windows) {
                UIResponder *r = zxKbdActiveFirstResponderInWindow(win);
                if (r) {
                    if ([r resignFirstResponder]) return YES;
                    if ([win endEditing:YES]) return YES;
                }
            }
            if (kbdDelegate && kbd && [kbd respondsToSelector:@selector(hideKeyboard)]) {
                [kbd hideKeyboard];
                return YES;
            }
            return NO;
        } else if (arg16 == ZX_KBD_VIRTUAL_SHOW) {
            if (kbdDelegate && kbd && [kbd respondsToSelector:@selector(showKeyboard)]) {
                [kbd showKeyboard];
                return YES;
            }
            return NO;
        }
        return NO;
    }

    return NO;
}

#endif
