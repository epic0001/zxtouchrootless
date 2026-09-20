// TODO: multiple client write back support


#include "SocketServer.h"
#include "Task.h"


CFSocketRef socketRef;
CFWriteStreamRef writeStreamRef = NULL;
CFReadStreamRef readStreamRef = NULL;
static NSMutableDictionary *socketClients = NULL;
static NSMutableDictionary *socketClientBuffers = NULL;
static dispatch_queue_t socketTaskQueue;
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
        socketTaskQueue = dispatch_queue_create("com.zjx.springboard.socket-tasks", DISPATCH_QUEUE_SERIAL);

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
    UInt8 readDataBuff[2048];
    CFIndex hasRead = CFReadStreamRead(readStream, readDataBuff, sizeof(readDataBuff));
    if (hasRead <= 0) {
        return;
    }

    NSData *chunk = [NSData dataWithBytes:readDataBuff length:(NSUInteger)hasRead];
    NSNumber *clientKey = @((long)readStream);

    dispatch_async(socketTaskQueue, ^{
        @autoreleasepool {
            NSMutableData *pendingData = [socketClientBuffers objectForKey:clientKey];
            if (!pendingData) {
                pendingData = [NSMutableData data];
                [socketClientBuffers setObject:pendingData forKey:clientKey];
            }
            [pendingData appendData:chunk];

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

                id writeStreamValue = [socketClients objectForKey:clientKey];
                if (writeStreamValue != nil) {
                    processTask((UInt8 *)[nullTerminatedCommand mutableBytes],
                                (CFWriteStreamRef)[writeStreamValue longValue]);
                } else {
                    processTask((UInt8 *)[nullTerminatedCommand mutableBytes]);
                }
            }
        }
    });

}

int notifyClientData(const UInt8 *data, CFIndex length, CFWriteStreamRef client)
{
    if (client == NULL || data == NULL || length < 0) {
        return -1;
    }

    CFIndex totalWritten = 0;
    while (totalWritten < length) {
        CFIndex written = CFWriteStreamWrite(client, data + totalWritten, length - totalWritten);
        if (written <= 0) {
            CFStreamError error = CFWriteStreamGetError(client);
            NSLog(@"com.zjx.springboard: socket write failed after %ld/%ld bytes (domain: %ld, error: %d)",
                  (long)totalWritten, (long)length, (long)error.domain, (int)error.error);
            return -1;
        }
        totalWritten += written;
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

            if (!CFReadStreamSetClient(readStreamRef, kCFStreamEventHasBytesAvailable, readStream, &context)) {
                NSLog(@"### com.zjx.springboard: error 1");
                return;
            }
            
            CFReadStreamScheduleWithRunLoop(readStreamRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

			[socketClients setObject:@((long)writeStreamRef) forKey:@((long)readStreamRef)];
            [socketClientBuffers setObject:[NSMutableData data] forKey:@((long)readStreamRef)];
            //const char *str = "+++welcome++++\n";
            
            //CFWriteStreamWrite(writeStreamRef, (UInt8 *)str, strlen(str) + 1);	
        }
        else
        {
            close(nativeSocketHandle);
        }
		
    }
    
}
