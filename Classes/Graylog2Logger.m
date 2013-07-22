//
//  Graylog2Logger.m
//  shakka.me
//
//  Created by Shay Erlichmen on 27/10/12.
//  Copyright (c) 2012 shakka.me. All rights reserved.
//

#import "Graylog2Logger.h"
#import "AMQPExchange.h"
#import "AMQPConnection.h"
#import "AMQPChannel.h"
#import "IPOfflineQueue.h"
#import "OpenUDID.h"
#include <arpa/inet.h>

#define retaintionDays (7)

#define secondsInDays(days) ((days) * 24 * 60 * 60)

@interface Graylog2Logger() <IPOfflineQueueDelegate> {
    AMQPExchange *_exchange;
    AMQPConnection *_connection;
    AMQPChannel *_channel;
    
    BOOL _resetChannel;
    NSString* _connectToServer;
    NSString* _connectToServerAddress;
    IPOfflineQueue *_outgoingMsgQueue;
    
    NSString *_host;
    NSString* _appName;
    NSNumber* _appPid;
}

- (IPOfflineQueueResult)offlineQueue:(IPOfflineQueue *)queue taskId:(int)taskId executeActionWithUserInfo:(NSDictionary *)userInfo;

- (BOOL)offlineQueueShouldAutomaticallyResume:(IPOfflineQueue *)queue;
@end

@implementation Graylog2Logger

-(void)connectToServer:(NSString*)host {
    _connectToServer = host;
    _connectToServerAddress = nil;
    [self closeQueue];
    [self resolveHost];
}

-(id)init {
    self = [super init];
    
    if (self) {
        _host = [NSString stringWithFormat:@"%@-%@", [[UIDevice currentDevice] name], [OpenUDID value]];
        _appName = [[NSProcessInfo processInfo] processName];
        _appPid = [NSNumber numberWithInt:getpid()];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appHasGoneInBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appIsInForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
    }
    
    return self;
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    _outgoingMsgQueue.delegate = nil;
    
    [self closeQueue];
    
    [_outgoingMsgQueue close];
    _outgoingMsgQueue = nil;
}

-(void)closeQueue {
    [_channel close];
    
    _exchange = nil;
    _channel = nil;
    _connection = nil;
}

-(void)appHasGoneInBackground {
    NSLog(@"Going into background.");
    _resetChannel = YES;
}

-(void)appIsInForeground {
    NSLog(@"And we are back.");
}

-(NSDictionary*)makeMessageDict:(DDLogMessage *)logMessage {
    int logLevel = 0;
    switch (logMessage->logFlag) {
        case LOG_FLAG_ERROR:
            logLevel = 3;
            break;
            
        case LOG_FLAG_WARN:
            logLevel = 4;
            break;
            
        case LOG_FLAG_INFO:
            logLevel = 6;
            break;
            
        case LOG_FLAG_VERBOSE:
            logLevel = 7;
            break;
            
        default:
            logLevel = 7;
            break;
    }
    
    return @{
             @"version": @"1.0",
             @"host": _host,
             @"facility": @"application",
             @"short_message": logMessage->logMsg,
             @"timestamp": [NSNumber numberWithDouble:[logMessage->timestamp timeIntervalSince1970]],
             @"level": [NSNumber numberWithInt:logLevel],
             @"_tid": [NSNumber numberWithInt:logMessage->machThreadID],
             @"_pid": _appPid,
             @"_app_name": _appName
             };
}

-(NSString*)buildMessage:(NSDictionary *)logMessage {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization
                        dataWithJSONObject:logMessage
                        options:0
                        error:&error];
    
    if (! jsonData) {
        NSLog(@"Got an error: %@", error);
    } else {
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    
    return nil;
}

-(void)resolveHost {
    CFHostRef hostRef = CFHostCreateWithName(kCFAllocatorDefault, (__bridge CFStringRef)_connectToServer);
    if (hostRef) {
        Boolean result = CFHostStartInfoResolution(hostRef, kCFHostAddresses, NULL); // pass an error instead of NULL here to find out why it failed
        CFArrayRef addresses;
        if (result) {
            addresses = CFHostGetAddressing(hostRef, &result);
        }
        if (result) {
            for (int i = 0; i < CFArrayGetCount(addresses); i++){
                struct sockaddr_in* remoteAddr;
                CFDataRef saData = (CFDataRef)CFArrayGetValueAtIndex(addresses, i);
                remoteAddr = (struct sockaddr_in*)CFDataGetBytePtr(saData);
                
                if (remoteAddr != NULL){
                    // Extract the ip address
                    _connectToServerAddress = [NSString stringWithCString:inet_ntoa(remoteAddr->sin_addr) encoding:NSASCIIStringEncoding];
                    NSLog(@"RESOLVED %@ -> %@", _connectToServer, _connectToServerAddress);
                    break;
                }
            }
            
            CFRelease(addresses);
        } else {
            NSLog(@"%@ Not resolved", _connectToServer);
        }
    }
}

-(void)createExchangeIfNeeded {
    if (!_resetChannel && _exchange) {
        return;
    }
    
    if (_connectToServerAddress == nil) {
        [NSException raise:@"GrayLog2" format:@"server log address %@ not resolved", _connectToServer];
    }
    
    
    @try {
        _connection = [[AMQPConnection alloc] init];
        [_connection connectToHost:_connectToServerAddress onPort:5672]; // TODO: DNS Lookup
        [_connection loginAsUser:@"guest" withPassword:@"guest" onVHost:@"/"];
        
        _channel = [_connection openChannel];
        
        _exchange = [[AMQPExchange alloc] initFanoutExchangeWithName:@"logging.gelf" onChannel:_channel isPassive:NO isDurable:YES getsAutoDeleted:NO];
        
        _resetChannel = NO;
    } @catch (NSException *exception) {
        NSLog(@"Failed to create an exchange %@: %@", [exception name], [exception reason]);
        @throw exception;
    }
}

-(void)createQueueIfNeeded {
    if (_outgoingMsgQueue != nil) {
        return;
    }
    
    _outgoingMsgQueue = [[IPOfflineQueue alloc] initWithName:@"outgoingLogs" stopped:NO delegate:self];
}

- (void)logMessage:(DDLogMessage *)logMessage {
    [self createQueueIfNeeded];
    
    [_outgoingMsgQueue enqueueActionWithUserInfo:[self makeMessageDict:logMessage]];
}

-(BOOL)shouldDiscardLogMessage:(NSDictionary *)userInfo {
    NSDate *currentLogDate = [NSDate dateWithTimeIntervalSince1970:[userInfo[@"timestamp"] doubleValue]];
    
    NSTimeInterval diff = [[NSDate date] timeIntervalSinceDate:currentLogDate];
    
    return diff > secondsInDays(retaintionDays);
}

-(IPOfflineQueueResult)offlineQueue:(IPOfflineQueue *)queue taskId:(int)taskId executeActionWithUserInfo:(NSDictionary *)userInfo {
    if ([self shouldDiscardLogMessage:userInfo]) {
        return IPOfflineQueueResultSuccess; // discard this log msg its too old
    }
    
    @try {
        [self createExchangeIfNeeded];
    } @catch (NSException *exception) {
        NSLog(@"Failed to create a logging channel %@: %@", [exception name], [exception reason]);
        
        return IPOfflineQueueResultFailureShouldRetry;
    }
    
    @try {
        NSString* message = [self buildMessage:userInfo];
        [_exchange publishMessage:message usingRoutingKey:@""];
    } @catch (NSException *exception) {
        NSLog(@"Failed to send message %@: %@", [exception name], [exception reason]);
        
        return IPOfflineQueueResultFailureShouldRetry;
    }
    
    return IPOfflineQueueResultSuccess;
}

-(BOOL)offlineQueueShouldAutomaticallyResume:(IPOfflineQueue *)queue {
    return TRUE;
}
@end
