//
//  SLSyncManager-Internal.h
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SLClientManager.h"


@interface SLClientManager ()

+ (SLClientManager *)sharedClientManager;

- (void)registerSyncClient:(NSString *)clientKey appID:(NSString *)appID;

- (void)enablePush:(NSData *)deviceToken;
- (void)handlePushNotification: (NSDictionary *)userInfo;
- (void)sendSyncPushNotification;

- (NSInteger)requestSyncingInBackgroundWithBlock:(void(^)(NSError *))completion;
- (void)cancelSyncingRequest;
- (void)acceptSyncingRequestInBackgroundWithCode:(NSInteger)invitationCode block:(void(^)(NSError *))completion;
- (void)stopSyncingInBackgroundWithBlock:(void(^)(NSError *))completion;

- (void)fetchClassListInBackgroundWithBlock:(void(^)(NSError *, NSArray *))completion;
- (void)saveClassListInBackgroundWithBlock:(void(^)(NSError *))completion;

// getter for read-only property

- (BOOL)syncing;

@end
