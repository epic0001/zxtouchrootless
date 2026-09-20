// TODO: multiple client write back support


#include "SocketServer.h"
#include "Task.h"


CFSocketRef socketRef;
CFWriteStreamRef writeStreamRef = NULL;
CFReadStreamRef readStreamRef = NULL;
static NSMutableDictionary *socketClients = NULL;
static NSMutableDictionary *socketClientBuffers = NULL;
static NSMutableDictionary *socketClientQueues = NULL;
void report_memory(void);

// Reference: https://www.jianshu.com/p/9353105a9129

void socketServer()
{
    @autoreleasepool {
        CFSocketRef _socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, TCPServerAcceptCallBack, NULL);
        
        if (_socket == NULL) {
            NSLog(@"### com.zjx.springboard: failed to create socket.");
            return;
        }
        
        UInt32 reused = 1;
        
        setsockopt(CFSocketGetNative(_socket), SOL_SOCKET, SO_REUSEADDR, (const void *)&reused, sizeof(reused));
        
        struct sockaddr_in Socketaddr;
        memset(&Socketaddr, 0, sizeof(Socketaddr));
        Socketaddr.sin_len = sizeof(Socketaddr);
        Socketaddr.sin_family = AF_INET;
        
        Socketaddr.sin_addr.s_addr = inet_addr(ADDR);

        Socketaddr.sin_port = htons(PORT);
        
        CFDataRef address = CFDataCreate(kCFAllocatorDefault,  (UInt8 *)&Socketaddr, sizeof(Socketaddr));
        
        if (CFSocketSetAddress(_socket, address) != kCFSocketSuccess) {
            NSLog(@"### com.zjx.springboard: failed to bind socket on port %d", PORT);
            [@"socket-bind-failed" writeToFile:@"/var/mobile/d_sockfail.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if (_socket) CFRelease(_socket);
            return;
        }
        [@"socket-bound-ok" writeToFile:@"/var/mobile/d_sockbound.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
        socketClients = [[NSMutableDictionary alloc] init];
        socketClientBuffers = [[NSMutableDictionary alloc] init];
        socketClientQueues = [[NSMutableDictionary alloc] init];

        NSLog(@"### com.zjx.springboard: connection waiting");
        CFRunLoopRef cfrunLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);

        CFRunLoopAddSource(cfrunLoop, source, kCFRunLoopCommonModes);

        CFRelease(source);
        CFRunLoopRun();
    }

}

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo)
{
    // This callback and TCPServerAcceptCallBack both run on the socket server's
    // run loop thread, so every access to the client dictionaries happens on one
    // thread and needs no locking. Only the parsed command is handed off.
    NSNumber *clientKey = @((long)readStream);

    if (eventype == kCFStreamEventEndEncountered || eventype == kCFStreamEventErrorOccurred)
    {
        // The client disconnected. Drop its state, otherwise the dictionaries
        // grow by one entry per connection for as long as SpringBoard runs.
        [socketClients removeObjectForKey:clientKey];
        [socketClientBuffers removeObjectForKey:clientKey];
        [socketClientQueues removeObjectForKey:clientKey];

        CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFReadStreamClose(readStream);
        return;
    }

    UInt8 readDataBuff[2048];
    CFIndex hasRead = CFReadStreamRead(readStream, readDataBuff, sizeof(readDataBuff));
    if (hasRead <= 0) {
        return;
    }

    NSMutableData *pendingData = [socketClientBuffers objectForKey:clientKey];
    if (!pendingData) {
        pendingData = [NSMutableData data];
        [socketClientBuffers setObject:pendingData forKey:clientKey];
    }
    [pendingData appendBytes:readDataBuff length:(NSUInteger)hasRead];

    // Each client gets its own serial queue. Commands from one client stay in
    // order, but a slow task (a screenshot encode, OCR, or a sleep task) no
    // longer blocks every other connection the way a single shared serial queue
    // would.
    dispatch_queue_t clientQueue = [socketClientQueues objectForKey:clientKey];
    id writeStreamValue = [socketClients objectForKey:clientKey];
    CFWriteStreamRef clientWriteStream =
        (writeStreamValue != nil) ? (CFWriteStreamRef)[writeStreamValue longValue] : NULL;

    while ([pendingData length] >= 2) {
        const UInt8 *bytes = (const UInt8 *)[pendingData bytes];
        NSUInteger commandLength = NSNotFound;
        for (NSUInteger index = 0; index + 1 < [pendingData length]; index++) {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
                commandLength = index;
                break;
            }
        }

        if (commandLength == NSNotFound) {
            break;
        }

        NSData *commandData = [pendingData subdataWithRange:NSMakeRange(0, commandLength)];
        [pendingData replaceBytesInRange:NSMakeRange(0, commandLength + 2)
                               withBytes:NULL
                                  length:0];

        if ([commandData length] < 2) {
            continue;
        }

        NSMutableData *nullTerminatedCommand = [commandData mutableCopy];
        const UInt8 terminator = 0;
        [nullTerminatedCommand appendBytes:&terminator length:1];

        void (^runTask)(void) = ^{
            @autoreleasepool {
                if (clientWriteStream != NULL) {
                    processTask((UInt8 *)[nullTerminatedCommand mutableBytes], clientWriteStream);
                } else {
                    processTask((UInt8 *)[nullTerminatedCommand mutableBytes]);
                }
            }
        };

        if (clientQueue != nil) {
            dispatch_async(clientQueue, runTask);
        } else {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), runTask);
        }
    }
}

int notifyClientData(const UInt8 *data, CFIndex length, CFWriteStreamRef client)
{
    if (client == NULL || data == NULL || length < 0) {
        return -1;
    }

    CFIndex totalWritten = 0;
    int stalledAttempts = 0;
    const int maxStalledAttempts = 2500;   // ~5 seconds at 2ms per attempt

    while (totalWritten < length) {
        CFIndex written = CFWriteStreamWrite(client, data + totalWritten, length - totalWritten);

        if (written > 0) {
            totalWritten += written;
            stalledAttempts = 0;
            continue;
        }

        if (written == 0) {
            // The stream cannot accept bytes at this instant. That is ordinary
            // back-pressure rather than a failure, and it is routine when
            // sending a payload as large as a screenshot. Returning here would
            // abandon the transfer half sent, so wait briefly and retry.
            CFStreamStatus status = CFWriteStreamGetStatus(client);
            if (status == kCFStreamStatusError || status == kCFStreamStatusClosed ||
                status == kCFStreamStatusNotOpen) {
                NSLog(@"com.zjx.springboard: socket closed after %ld/%ld bytes (status %ld)",
                      (long)totalWritten, (long)length, (long)status);
                return -1;
            }
            if (++stalledAttempts > maxStalledAttempts) {
                NSLog(@"com.zjx.springboard: socket write timed out after %ld/%ld bytes",
                      (long)totalWritten, (long)length);
                return -1;
            }
            usleep(2000);
            continue;
        }

        CFStreamError error = CFWriteStreamGetError(client);
        NSLog(@"com.zjx.springboard: socket write failed after %ld/%ld bytes (domain: %ld, error: %d)",
              (long)totalWritten, (long)length, (long)error.domain, (int)error.error);
        return -1;
    }

    return 0;
}

int notifyClient(UInt8* msg, CFWriteStreamRef client)
{
    if (msg == NULL) {
        return -1;
    }
    return notifyClientData(msg, (CFIndex)strlen((char *)msg), client);
}

static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if (kCFSocketAcceptCallBack == type) {
        
        CFSocketNativeHandle  nativeSocketHandle = *(CFSocketNativeHandle *)data;
        
        uint8_t name[SOCK_MAXADDRLEN];
        socklen_t namelen = sizeof(name);
        
        if (getpeername(nativeSocketHandle, (struct sockaddr *)name, &namelen) != 0) {
            
            NSLog(@"### com.zjx.springboard: ++++++++getpeername+++++++");
            
            exit(1);
        }
        
        struct sockaddr_in *addr_in = (struct sockaddr_in *)name;
        NSLog(@"### com.zjx.springboard: connection from %s:%d", inet_ntoa(addr_in->sin_addr), addr_in->sin_port);
        
        readStreamRef = NULL;
        writeStreamRef = NULL;

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle, &readStreamRef, &writeStreamRef);
       
        if (readStreamRef && writeStreamRef) {
            CFReadStreamOpen(readStreamRef);
            CFWriteStreamOpen(writeStreamRef);
            
            CFStreamClientContext context = {0, NULL, NULL, NULL };

            CFOptionFlags streamEvents = kCFStreamEventHasBytesAvailable |
                                         kCFStreamEventEndEncountered |
                                         kCFStreamEventErrorOccurred;
            if (!CFReadStreamSetClient(readStreamRef, streamEvents, readStream, &context)) {
                NSLog(@"### com.zjx.springboard: error 1");
                return;
            }
            
            CFReadStreamScheduleWithRunLoop(readStreamRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

			[socketClients setObject:@((long)writeStreamRef) forKey:@((long)readStreamRef)];
            [socketClientBuffers setObject:[NSMutableData data] forKey:@((long)readStreamRef)];

            dispatch_queue_t clientQueue =
                dispatch_queue_create("com.zjx.springboard.socket-client", DISPATCH_QUEUE_SERIAL);
            if (clientQueue) {
                [socketClientQueues setObject:clientQueue forKey:@((long)readStreamRef)];
            }
            //const char *str = "+++welcome++++\n";
            
            //CFWriteStreamWrite(writeStreamRef, (UInt8 *)str, strlen(str) + 1);	
        }
        else
        {
            close(nativeSocketHandle);
        }
		
    }
    
}
