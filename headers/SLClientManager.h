//
//  SLClientManager.h
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SLClientManager : NSObject <NSCoding>

// call + registerSyncClient:appID:syncInterval: in the -application:didRegisterForRemoteNotificationsWithDeviceToken: method of
// your app delegate class to register your client. The client isn't fully registered and ready to use until +enablePush: has been called

+ (void)registerSyncClient:(NSString *)clientKey appID: (NSString *)appID;

// call +enablePush: in the -application:didRegisterForRemoteNotificationsWithDeviceToken: method of your app delegate class to enable
// push and complete the client registration. SyncLib is ready for use after this call.

+ (void)enablePush:(NSData *)deviceToken;

// call +handlePushNotification: in the -application:didReceiveRemoteNotification: method of your app delegate
// call to handle push notifications

+ (void)handlePushNotification:(NSDictionary *)userInfo;

// call +saveToDisk in the applicationDidEnterBackground: and applicationWillTerminate: methods of your app delegate class
// to save the local database cache and locally persisted objects & properties to "disk"

+ (void)saveToDisk;

// call +syncAllInBackgroundWithBlock: if you want to force a sync to the cloud database.
// clients are otherwise automatically synced:
// 1) at regular intervals as specified by registerSyncClient:appID:syncInterval:
// and 2) when you make changes to the database (with a delay)

+ (void)syncAllInBackgroundWithBlock:(void(^)(NSError *))completion;

// set time delay to use when a sync is scheduled after a database change

+ (void)setSyncLag:(NSTimeInterval)lag;

// call +requestSyncingInBackgroundWithBlock: to request to join a syncing group. The call returns an invitation code that another client can use to approve the
// request. The block is called upon approval and completion of the request or on error. The invitation code is valid for 5 minutes or until
// + cancelSyncingRequest is called. A timeout error is returned in either case. An error is also returned if the operation cannot complete
// due to lack or loss of connectivity. The call throws an exception if the calling client is already in syncing mode or in a transitional state, e.g.
// there is a pending call to + requestSyncingInBackgroundWithBlock:. Upon completion of the association, all preexisting objects on the calling client are
// preserved and added to the shared dataset.

+ (NSInteger)requestSyncingInBackgroundWithBlock:(void(^)(NSError *))completion;


+ (void)cancelSyncingRequest;

// call +acceptSyncingRequestInBackgroundWithCode:block: with an invitation code to approve the requesting client to join the syncing group. If the calling client
// isn't part of a syncing group, a new syncing group is formed. The block is called on completion of the association or on error. An error is returned if the
// operation cannot complete due to lack or loss of connectivity.

+ (void)acceptSyncingRequestInBackgroundWithCode:(NSInteger)associationCode block:(void(^)(NSError *))completion;

// call +stopSyncingInBackground  the calling client from a syncing group. the call throws an exception is the client is not in syncing mode or in a transitional state.
// Upon completion of the disassociation, the client is left with an empty dataset. Note that the call is asynchronous and the calling client
// may still receive remote change notifications after the call has returned, e.g. if the call took place while a sync is in progress.

+ (void)stopSyncingInBackgroundWithBlock:(void(^)(NSError *))completion;

// +isSyncing returns whether the calling client is associated with a syncing group

+ (BOOL)isSyncing;

@end
