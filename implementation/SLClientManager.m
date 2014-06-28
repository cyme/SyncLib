//
//  SLSyncManager.m
//  ShoppingList
//
//  Created by Cyril Meurillon on 5/20/14.
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import "SLClientManager-Internal.h"
#import "SLObjectRegistry.h"
#import "SLObject-Internal.h"
#import "SLOperationManager.h"
#import "BlockCondition.h"
#import <Parse/Parse.h>


#define KSLINVITATIONCODEDIGITS     (5)
#define KSLINVITATIONCODERANGE      ((NSInteger)pow(10.0, KSLINVITATIONCODEDIGITS))

NSInteger const SLInvitationCodeDigits = KSLINVITATIONCODEDIGITS;
NSTimeInterval const SLInvitationTimeout = (100*60);
NSString * const SLErrorDomain = @"com.cymelabs.synclib.ErrorDomain";

static NSString * const kSLClientManagerSyncingKey = @"SLCMSyncing";
static NSString * const kSLClientManagerSyncingGroupNameKey = @"SLCMSyncingGroupName";
static NSString * const kSLClientManagerParseUserRegisteredKey = @"SLCLParseUserRegistered";

static NSString * const kSLInvitationClassName = @"invitation";
static NSString * const kSLInvitationCodeKey = @"code";
static NSString * const kSLInvitationUserKey = @"user";

static NSString * const kSLSyncingGroupNameKey = @"name";
static NSString * const kSLSyncingGroupClassNamesKey = @"classes";
static NSString * const kSLSyncingGroupCountKey = @"count";

static NSString * const kSLInstallationUserKey = @"user";

static NSString * const kSLInstallationChannelKey = @"channels";

static NSString * const kSLNotificationPayloadTypeKey = @"type";
static NSString * const kSLNotificationPayloadGroupNameKey = @"group";
static NSString * const kSLNotificationPayloadCodeKey = @"code";

static NSString * const kSLNotificationTypeSync = @"sync";
static NSString * const kSLNotificationTypeApproval = @"approval";


@interface SLClientManager ()

@property (nonatomic) SLOperationManager        *operationMgr;
@property (nonatomic) SLObjectRegistry          *registry;

@property BOOL                                  parseUserRegistered;
@property (nonatomic) NSData                    *deviceToken;
@property BlockCondition                        *deviceTokenRegistered;

@property (readwrite) BOOL                      syncing;
@property BOOL                                  syncingChangePending;
@property BOOL                                  syncingArchivedState;

@property (readwrite, nonatomic) PFRole         *syncingGroupObject;
@property (readwrite, nonatomic) NSString       *syncingGroupName;

@property (nonatomic, strong) void              (^pendingSyncingRequestCancelationBlock)(NSError *);
@property (nonatomic, strong) void              (^pendingSyncingRequestApprovalBlock)(NSInteger, NSString *);


// syncing management methods

- (void)initParseUserInBackground;
- (void)initSyncingInBackground;
- (void)setDefaultACL;
- (PFObject *)createInvitationObjectInBackgroundWithCode:(NSInteger)invitationCode block: (void (^) (NSError *))completion;
- (void)deleteInvitationObjectInBackground: (PFObject *) invitationObject;
- (void)waitForSyncingRequestApprovalInBackgroundWithCode:(NSInteger)invitationCode block:(void (^) (NSError *))completion;
- (void)createSyncingGroupObjectInBackgroundWithBlock: (void (^)(NSError *))completion;
- (void)deleteSyncingGroupObjectInBackground;
- (void)grantGuestAccessToGroupInBackgroundWithCode: (NSInteger)invitationCode block: (void (^)(NSError *))completion;
- (void)relinquishClientAccessToGroupInBackground;
- (void)addClientToGroupInBackgroundWithBlock: (void(^)(NSError *))completion;
- (void)removeClientFromGroupInBackground;
- (void)downloadSyncingGroupObjectInBackground:(BOOL)waitForConnection block: (void (^)(NSError *))completion;
- (void)subscribeToChannelInBackgroundWithBlock: (void (^) (NSError *))completion;
- (void)unsubscribeFromChannelInBackground;
- (void)sendPushNotificationToChannel:(NSString *)channel payload:(NSDictionary *)payload;
- (void)sendPushNotificationToUser:(PFUser *)user payload:(NSDictionary *)payload;

@end


@implementation SLClientManager

#pragma mark - Public Methods

// registerSyncClient:appID:syncInterval: real implementation is in SLObjectRegistry

+ (void)registerSyncClient:(NSString *)clientKey appID:(NSString *)appID
{
    [[SLClientManager sharedClientManager] registerSyncClient:clientKey appID:appID];
}

// enablePush: implementation is in SLObjectRegistry

+ (void)enablePush:(NSData *)deviceToken
{
    [[SLClientManager sharedClientManager] enablePush:deviceToken];
}

// handlePushNotification: real implementation is in SLObjectRegistry

+ (void)handlePushNotification: (NSDictionary *)userInfo
{
    [[SLClientManager sharedClientManager] handlePushNotification:userInfo];
}


// saveToDisk real implementation is in SLObjectRegistry

+ (void)saveToDisk
{
    [[SLObjectRegistry sharedObjectRegistry] saveToDisk];
}


// syncAllInBackgroundWithBlock: real implementation is in SLObjectRegistry

+ (void)syncAllInBackgroundWithBlock:(void(^)(NSError *))completion
{
    [[SLObjectRegistry sharedObjectRegistry] syncAllInBackgroundWithBlock: ^(NSError *error) {
        completion(error);
    }];
}

+ (void)setSyncLag:(NSTimeInterval)lag
{
    [[SLObjectRegistry sharedObjectRegistry] setSyncLag:lag];
}


+ (NSInteger)requestSyncingInBackgroundWithBlock:(void(^)(NSError *))completion
{
    return [[SLClientManager sharedClientManager] requestSyncingInBackgroundWithBlock:completion];
}

+ (void)cancelSyncingRequest
{
    [[SLClientManager sharedClientManager] cancelSyncingRequest];
}

+ (void)acceptSyncingRequestInBackgroundWithCode:(NSInteger)code block:(void(^)(NSError *))completion
{
    [[SLClientManager sharedClientManager] acceptSyncingRequestInBackgroundWithCode:code block:completion];
}

+ (void)stopSyncingInBackgroundWithBlock:(void(^)(NSError *))completion
{
    [[SLClientManager sharedClientManager] stopSyncingInBackgroundWithBlock:completion];
}

+ (BOOL)isSyncing
{
    return [SLClientManager sharedClientManager].syncing;
}

// registers the sync client, initializes the registry and loads the device cache, if available
// note that the registration is not complete until enablePush is called.

- (void)registerSyncClient:(NSString *)clientKey appID:(NSString *)appID
{
    UIApplication       *application;
    
    // initialize Parse
    
    [Parse setApplicationId:appID clientKey:clientKey];
    
    application = [UIApplication sharedApplication];
    [application registerForRemoteNotificationTypes:
     UIRemoteNotificationTypeBadge |
     UIRemoteNotificationTypeAlert |
     UIRemoteNotificationTypeSound];
    
    // initialize the registry if it wasn't already
    
    self.registry = [SLObjectRegistry sharedObjectRegistry];
    
    [self.registry loadFromDisk];
    
    // register the user with Parse if it hasn't yet. Multiple registrations are possible if the application quits before - saveToDisk
    // is called. This is harmless.
    
    if (!self.parseUserRegistered)
        [self initParseUserInBackground];
    
    // initialize syncing mode if the app was previously in syncing mode. This call is serialized with initParseUserInBackground and all
    // other IO operations to ensure correct behavior.
    
    if (self.syncingArchivedState)
        [self initSyncingInBackground];
}

#pragma mark - Internal Methods

// return the shared instance of the client manager singleton

+ (SLClientManager *)sharedClientManager
{
    static SLClientManager *clientMgr = nil;
    static dispatch_once_t  onceToken;
    
    // check if the registry needs to be initialized
    
    if (!clientMgr)
        
        // initialize the registry in a thread-safe manner
        // this really isn't necessary given that the library currently isn't thread safe, but it's fun anyway
        
        dispatch_once(&onceToken, ^{
            
            // registry is a (static) global, therefore it does not need to be declared __block
            
            clientMgr = [[SLClientManager alloc] init];
            
        });
    return clientMgr;
}

// bring back to life the client manager from the disk cache

- (id)initWithCoder:(NSCoder *)aDecoder
{
    // SLClientManager is a singleton class. Use the existing instance if one has already been created.
    
    self = [SLClientManager sharedClientManager];
    assert(self);
    
    self.syncingArchivedState = [aDecoder decodeBoolForKey:kSLClientManagerSyncingKey];
    self.syncingGroupName = [aDecoder decodeObjectForKey:kSLClientManagerSyncingGroupNameKey];
    self.parseUserRegistered = [aDecoder decodeBoolForKey:kSLClientManagerParseUserRegisteredKey];
     
    return self;
}

// encode the state of the client manager to save to disk

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeBool:self.syncing forKey:kSLClientManagerSyncingKey];
    [aCoder encodeObject:self.syncingGroupName forKey:kSLClientManagerSyncingGroupNameKey];
    [aCoder encodeBool:self.parseUserRegistered forKey:kSLClientManagerParseUserRegisteredKey];
}


- (void)enablePush:(NSData *)deviceToken
{
    __weak typeof(self) weakSelf = self;
    PFInstallation      *installation;
    
    self.deviceToken = deviceToken;
    
    installation = [PFInstallation currentInstallation];
    [installation setDeviceTokenFromData:self.deviceToken];
    [self.operationMgr savePFObjectInBackground:installation waitForConnection:TRUE block: ^(NSError *error) {
        assert(!error);
        [weakSelf.deviceTokenRegistered broadcast];
    }];
}

// handle a push notification

- (void)handlePushNotification:(NSDictionary *)payload
{
    // check if this is a sync notification
    
    if ([payload[kSLNotificationPayloadTypeKey] isEqualToString:kSLNotificationTypeSync]) {
        
        // verify that the sync notification applies to the group we've subscribed to
        // syncAllInBackgroundWithBlock: is serialized with respect to any ongoing operation.
        // this guards us against processing a sync push notification while another
        // operation is ongoing.
                
        if ([payload[kSLNotificationPayloadGroupNameKey] isEqualToString:self.syncingGroupName])
            [self.registry syncAllInBackgroundWithBlock: ^(NSError *error) { }];
    }
    
    // check if this is a syncing request approval notification
    
    if ([payload[kSLNotificationPayloadTypeKey] isEqualToString:kSLNotificationTypeApproval]) {
        void            (^block)(NSInteger, NSString *);
        
        block = self.pendingSyncingRequestApprovalBlock;
        if (block) {
            NSInteger       approvedCode;
            NSString        *groupName;
            
            approvedCode = [payload[kSLNotificationPayloadCodeKey] integerValue];
            groupName = payload[kSLNotificationPayloadGroupNameKey];
            block(approvedCode, groupName);
        }
    }
}

- (NSInteger)requestSyncingInBackgroundWithBlock:(void (^) (NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    __block BOOL        operationCompleted;
    __block BOOL        operationCanceled;
    __block BOOL        operationTimedOut;
    dispatch_time_t     when;
    __block PFObject    *invitationObject;
    NSInteger           invitationCode;
    
    operationCompleted = FALSE;
    operationCanceled = FALSE;
    operationTimedOut = FALSE;
    
    // throw an exception if the client is already in syncing mode or in the midst of a syncing mode change
    
    if (self.syncing || self.syncingChangePending) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"request Syncing in wrong mode"
                                          userInfo:nil];
        @throw exception;
    }
    
    // generate a pseudo-unique number in the proper range
    
    invitationCode = (NSInteger)(((int64_t)([[NSDate date] timeIntervalSince1970]*1000) )% KSLINVITATIONCODERANGE);
    
    self.syncingChangePending = TRUE;
    
    // register a cancelation block
    
    self.pendingSyncingRequestCancelationBlock = ^ (NSError *error) {
        operationCanceled = TRUE;
        if (weakSelf.pendingSyncingRequestApprovalBlock)
            weakSelf.pendingSyncingRequestApprovalBlock(invitationCode, nil);
        weakSelf.pendingSyncingRequestCancelationBlock = nil;
    };
    
    // schedule a timeout block
    
    when = dispatch_time(DISPATCH_TIME_NOW, (dispatch_time_t)(SLInvitationTimeout*NSEC_PER_SEC));
    
    dispatch_after(when, dispatch_get_main_queue(), ^ (void) {
        if (operationCompleted || operationCanceled)
            return;
        operationTimedOut = TRUE;
        if (weakSelf.pendingSyncingRequestApprovalBlock)
            weakSelf.pendingSyncingRequestApprovalBlock(invitationCode, nil);
        weakSelf.pendingSyncingRequestCancelationBlock = nil;
    });
    
    // serialize this rest of this call with any ongoing or pending IO operations
    // fail if no connectivity is available
    
    [self.operationMgr serialize:FALSE operation: ^(NSError *error) {
        
        // handle an error, request cancelation or timeout
        
        if (error || operationCanceled || operationTimedOut) {
            if (error)
                operationCompleted = TRUE;
            weakSelf.syncingChangePending = FALSE;
            weakSelf.pendingSyncingRequestCancelationBlock = nil;
            if (operationCanceled)
                error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestCancelled userInfo:nil];
            if (operationTimedOut)
                error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestTimeout userInfo:nil];
            completion(error);
            
            // execute the next IO only if serialize: was successful
            
            if (operationCanceled || operationTimedOut)
                [weakSelf.operationMgr runNextOperation];
            return;
        }
        
        invitationObject = [weakSelf createInvitationObjectInBackgroundWithCode:invitationCode block: ^ (NSError *error) {
            
            // handle an error, request cancelation or timeout
            
            if (error || operationCanceled || operationTimedOut) {
                
                // delete the invitation object only if createInvitationObjectInBackgroundWithCode: was successful
                
                if (error)
                    operationCompleted = TRUE;
                else
                    [weakSelf deleteInvitationObjectInBackground:invitationObject];
                weakSelf.syncingChangePending = FALSE;
                weakSelf.pendingSyncingRequestCancelationBlock = nil;
                if (operationCanceled)
                    error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestCancelled userInfo:nil];
                if (operationTimedOut)
                    error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestTimeout userInfo:nil];
                completion(error);
                [weakSelf.operationMgr runNextOperation];
                return;
            }
            
            // wait for push notifications to be enabled (if they haven't yet)
            // this call will wait indefinitely if the app is unable to save the installation object because
            // of the lack of connectivity. this is potentially a problem. however if that's the case, chances
            // are that we wouldn't make it that far as serialize: or createInvitationObject: would have
            // failed. a proper solution would be a non-indefinitely blocking wait for the token registration.
            
            [weakSelf.deviceTokenRegistered waitInBackgroundWithBlock:^(){
                
                // now we're ready to receive the acceptance notification. Note that there's a race condition, as the invitation code
                // is returned synchronously from the call before we create the invitation object. This is however unlikely
                // and fairly harmless as this merely results in an approval failure. A subsequent approval attempt
                // will succeed.
                
                [weakSelf waitForSyncingRequestApprovalInBackgroundWithCode:invitationCode block:^(NSError *error) {
                    
                    weakSelf.pendingSyncingRequestApprovalBlock = nil;
                    
                    // the invitation object can now be safely deleted
                    
                    [weakSelf deleteInvitationObjectInBackground:invitationObject];
                    
                    // handle an error, request cancelation or timeout
                    // there is a race condition between a request approval, cancelation and timeout. this translates in the
                    // possibility that the request was approved, but the approval never received and acknowledged.
                    // this results in a syncing group object that is readable and writable by a client that isn't syncing
                    // with that group. It's potentially a security problem as the client could grant itself access to the
                    // database objects under the management of the syncing group.
                    
                    if (error || operationCanceled || operationTimedOut) {
                        if (error)
                            operationCompleted = TRUE;
                        weakSelf.syncingChangePending = FALSE;
                        weakSelf.pendingSyncingRequestCancelationBlock = nil;
                        if (operationCanceled)
                            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestCancelled userInfo:nil];
                        if (operationTimedOut)
                            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestTimeout userInfo:nil];
                        completion(error);
                        [weakSelf.operationMgr runNextOperation];
                        return;
                    }
                    
                    // after this point, the request cannot be canceled and will no longer time out. this minimizes the
                    // security risk highlighted above
                    
                    weakSelf.pendingSyncingRequestCancelationBlock = nil;
                    operationCompleted = TRUE;
                    
                    // download the syncing group object. fail if no connectivity is available as we don't want to wait
                    // indefinitely.
                    
                    [weakSelf downloadSyncingGroupObjectInBackground:FALSE block:^(NSError *error) {
                        
                        // handle an error
                        
                        if (error) {
                            weakSelf.syncingChangePending = FALSE;
                            completion(error);
                            [weakSelf.operationMgr runNextOperation];
                            return;
                        }
                        
                        // subscribe to the channel
                        // note that the handling of any sync push notification received is deferred until the completion of
                        // requestSyncingInBackgroundWithBlock: (see handlePushNotification:)
                        
                        [weakSelf subscribeToChannelInBackgroundWithBlock:^(NSError *error) {
                            
                            // handle an error
                            
                            if (error) {
                                
                                // relinquish the access we were granted to the syncing group object
                                
                                [weakSelf relinquishClientAccessToGroupInBackground];
                                
                                weakSelf.syncingGroupObject = nil;
                                [weakSelf removeClientFromGroupInBackground];
                                weakSelf.syncingChangePending = FALSE;
                                completion(error);
                                [weakSelf.operationMgr runNextOperation];
                                return;
                            }
                            
                            // add ourselves to the syncing group, which effectively grants us access to the database objects managed
                            // by the syncing group. this is the last step.
                            
                            [weakSelf addClientToGroupInBackgroundWithBlock:^(NSError *error) {
                                
                                // handle an error
                                
                                if (error) {
                                    [weakSelf unsubscribeFromChannelInBackground];
                                    [weakSelf relinquishClientAccessToGroupInBackground];
                                    weakSelf.syncingGroupObject = nil;
                                    weakSelf.syncingChangePending = FALSE;
                                    completion(error);
                                    [weakSelf.operationMgr runNextOperation];
                                    return;
                                }
                                
                                // set the default ACL to be the syncing group object
                                
                                [weakSelf setDefaultACL];
                                
                                weakSelf.syncing = TRUE;
                                weakSelf.syncingChangePending = FALSE;
                                
                                // ok, we're done. Now kick off the sync heartbeat
                                
                                [weakSelf.registry startSyncingTimer];
                                
                                completion(nil);
                                [weakSelf.operationMgr runNextOperation];
                            }];
                        }];
                    }];
                }];
            }];
        }];
    }];
    
    return invitationCode;
}

- (void)cancelSyncingRequest
{
    void        (^cancelation)(NSError *);
    NSError     *error;
    
    // return without doing anything if the client is not in the middle of a cancelable syncing mode change
    
    if (!self.syncingChangePending || !self.pendingSyncingRequestCancelationBlock)
        return;
    
    cancelation = self.pendingSyncingRequestCancelationBlock;
    assert(cancelation);
    self.pendingSyncingRequestCancelationBlock = nil;
    error = [NSError errorWithDomain:SLErrorDomain code:SLErrorSyncingRequestCancelled userInfo:nil];
    cancelation(error);
}

- (void)acceptSyncingRequestInBackgroundWithCode:(NSInteger)invitationCode block:(void (^) (NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    
    [weakSelf.operationMgr serialize:FALSE operation: ^(NSError *error) {
        
        if (error) {
            completion(error);
            return;
        }
        
        if (!weakSelf.syncing) {
            
            [weakSelf createSyncingGroupObjectInBackgroundWithBlock: ^ (NSError *error) {
                
                if (error) {
                    completion(error);
                    [weakSelf.operationMgr runNextOperation];
                    return;
                }
                
                [weakSelf subscribeToChannelInBackgroundWithBlock: ^ (NSError *error) {
                    
                    if (error) {
                        [weakSelf deleteSyncingGroupObjectInBackground];
                        completion(error);
                        [weakSelf.operationMgr runNextOperation];
                        return;
                    }
                    
                    // we can grant the client access to the syncing group now that we have created a syncing group
                    
                    [weakSelf grantGuestAccessToGroupInBackgroundWithCode:invitationCode block: ^ (NSError *error) {
                        if (error) {
                            [weakSelf unsubscribeFromChannelInBackground];
                            [weakSelf deleteSyncingGroupObjectInBackground];
                            completion(error);
                            [weakSelf.operationMgr runNextOperation];
                            return;
                        }
                        weakSelf.syncing = TRUE;
                        
                        // ok, we're done. Now kick off the sync heartbeat
                        
                        [weakSelf.registry startSyncingTimer];

                        completion(nil);
                        [weakSelf.operationMgr runNextOperation];
                    }];
                }];
            }];
            
        } else {
            
            [weakSelf grantGuestAccessToGroupInBackgroundWithCode:invitationCode block: ^ (NSError *error) {
                completion(error);
                [weakSelf.operationMgr runNextOperation];
            }];
        }
    }];
}


- (void)stopSyncingInBackgroundWithBlock:(void (^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    
    // serialize this call with respect to other ongoing IO operations. fail if there's no connectivity
    // rather than block indefinitely
    
    [weakSelf.operationMgr serialize:FALSE operation: ^(NSError *error) {
        
        if (error) {
            completion(error);
            [weakSelf.operationMgr runNextOperation];
            return;
        }
        
        // throw an exception if the client is not in syncing mode
        
        if (!weakSelf.syncing) {
            NSException     *exception;
            exception = [NSException exceptionWithName:NSInvalidArgumentException
                                                reason:@"stopSyncingInBackground called when syncing is not enabled"
                                              userInfo:nil];
            @throw exception;
            return;
        }
        
        // unsubscribe from channel and remove ourselves from the syncing group. We are not waiting for the completion,
        // but that's fine because:
        // 1- we'll be discarding any related sync notification from this point on
        // 2- object changes are guaranteed to be executed in order, which ensures state consistency
        
        [weakSelf unsubscribeFromChannelInBackground];
        [weakSelf removeClientFromGroupInBackground];
        
        // discard the current dataset
        
        [weakSelf.registry removeAllObjects];
        
        weakSelf.syncingGroupObject = nil;
        weakSelf.syncingGroupName = nil;
        weakSelf.syncing = FALSE;
        
        // stop the syncing timer
        
        [weakSelf.registry stopSyncingTimer];
        
        completion(nil);
        [weakSelf.operationMgr runNextOperation];
    }];
}

- (void)sendSyncPushNotification
{
    [self sendPushNotificationToChannel:self.syncingGroupName
                                payload: @{kSLNotificationPayloadTypeKey:kSLNotificationTypeSync,
                                           kSLNotificationPayloadGroupNameKey:self.syncingGroupName} ];
}


// saveClassListInBackgroundWithBlock: does what it says: it asynchronously update and save the
// class list. We need to maintain a class list because Parse does not provide a class lookup function.

- (void)saveClassListInBackgroundWithBlock:(void(^)(NSError *))completion
{
    NSArray         *registeredClassNames;
    
    // add any registered subclasses not yet in the list
    registeredClassNames = [self.registry classNames];
    
    [self.syncingGroupObject addUniqueObjectsFromArray:registeredClassNames forKey:kSLSyncingGroupClassNamesKey];
    
    // save the object asynchronously
    
    [self.operationMgr savePFObjectInBackground:self.syncingGroupObject waitForConnection:TRUE block:^(NSError *error) {
        completion(error);
    }];
}


- (void)fetchClassListInBackgroundWithBlock:(void(^)(NSError *, NSArray *))completion
{
    __weak typeof(self) weakSelf = self;

    // update the syncing group object to get the current list of class names
    
    [self.operationMgr fetchPFObjectInBackground:self.syncingGroupObject waitForConnection:TRUE block:^(PFObject *fetchedObject, NSError *error) {
        
        // the fetch call is asynchronous, this is the continuation code
        
        NSArray             *classNames;
        
        if (error) {
            completion(error, nil);
            return;
        }
        
        self.syncingGroupObject = (PFRole *)fetchedObject;
        
        classNames = weakSelf.syncingGroupObject[kSLSyncingGroupClassNamesKey];
        completion(nil, classNames);
    }];
}

#pragma mark - Private Methods

- (id)init
{
    self = [super init];
    if (!self)
        return nil;
    
    _parseUserRegistered = FALSE;
    _syncing = FALSE;
    _syncingChangePending = FALSE;
    _syncingArchivedState = FALSE;
    
    _operationMgr = [SLOperationManager sharedOperationManager];

    
    _deviceToken = nil;
    _deviceTokenRegistered = [BlockCondition blockCondition];
    if (!_deviceTokenRegistered)
        return nil;
    
    _pendingSyncingRequestCancelationBlock = nil;
    _pendingSyncingRequestApprovalBlock = nil;
    _syncingGroupName = @"";
    _syncingGroupObject = nil;
    
    return self;
}

    
// init user with Parse, to be called the first time an installation is launched

- (void)initParseUserInBackground
{
    __weak typeof(self) weakSelf = self;
    
    [self.operationMgr serialize:TRUE operation:^(NSError *error) {
        
        PFUser              *user;
        
        assert(!error);
        
        [PFUser enableAutomaticUser];
        user = [PFUser currentUser];
        
        [self.operationMgr savePFObjectInBackground:user waitForConnection:TRUE block:^(NSError * error) {
            
            PFInstallation      *installation;
            
            assert(!error);
            installation = [PFInstallation currentInstallation];
            installation[kSLInstallationUserKey] = user;
            
            [weakSelf.operationMgr savePFObjectInBackground:installation waitForConnection:TRUE block: ^(NSError *error) {
                assert(!error);
                weakSelf.parseUserRegistered = TRUE;
                [weakSelf.operationMgr runNextOperation];
            }];
        }];
    }];
}


// initiate sync operations

- (void)initSyncingInBackground
{
    __weak typeof(self) weakSelf = self;
    
    // serialize this call with respect to other IO operations
    
    [self.operationMgr serialize:TRUE operation:^(NSError *error) {
        
        // wait for push notifications to be enabled
        
        [weakSelf.deviceTokenRegistered waitInBackgroundWithBlock:^() {
            
            weakSelf.syncingChangePending = TRUE;
            
            [weakSelf downloadSyncingGroupObjectInBackground:TRUE block: ^(NSError *error) {
                
                // set the default ACL to be the syncing group object
                
                [weakSelf setDefaultACL];
                
                // schedule an initial sync.
                // timerFireMethod initiates regular syncing
                
                weakSelf.syncingChangePending = FALSE;
                weakSelf.syncing = TRUE;
                
                [weakSelf.registry startSyncingTimer];
                
                // execute next serialized IO operation, if any
                
                [weakSelf.operationMgr runNextOperation];
            }];
        }];
    }];
}


- (void)setDefaultACL
{
    PFACL       *defaultACL;
    
    // create a default ACL that will be used for all database objects created.
    // the default ACL provides read/write access to all users in the syncing group
    
    defaultACL = [PFACL ACL];
    [defaultACL setPublicReadAccess:FALSE];
    [defaultACL setPublicWriteAccess:FALSE];
    [defaultACL setReadAccess:TRUE forRole:self.syncingGroupObject];
    [defaultACL setWriteAccess:TRUE forRole:self.syncingGroupObject];
    [PFACL setDefaultACL:defaultACL withAccessForCurrentUser:TRUE];
    
}


- (PFObject *)createInvitationObjectInBackgroundWithCode:(NSInteger)invitationCode block:(void (^)(NSError *))completion
{
    PFObject            *invitationObject;
    
    // create a new invitation object
    
    invitationObject = [PFObject objectWithClassName:kSLInvitationClassName];
    assert(invitationObject);
    
    // record the invitation code (that's how it's going to be found)
    
    invitationObject[kSLInvitationCodeKey] = @(invitationCode);
    
    // record our userID
    
    invitationObject[kSLInvitationUserKey] = [PFUser currentUser];
    
    // make the object readable (visible) by all
    
    [invitationObject.ACL setPublicReadAccess:TRUE];
    
    // save the installation in background. We don't want to fail if no connectivity is available to avoid blocking indefinitely
    
    [self.operationMgr savePFObjectInBackground:invitationObject waitForConnection:FALSE block: ^(NSError *error) {
        
        completion(error);
    }];
    
    return invitationObject;
}

// delete an invitation object after it has been used

- (void)deleteInvitationObjectInBackground:(PFObject *)invitationObject
{
    [self.operationMgr deletePFObjectInBackground:invitationObject waitForConnection:TRUE block:nil];
}


// wait for a client to accept the syncing request

- (void)waitForSyncingRequestApprovalInBackgroundWithCode:(NSInteger)invitationCode
                                                    block:(void(^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    
    // register the approval block. The block is called when the approval is received in the form of a push notification.
    
    self.pendingSyncingRequestApprovalBlock = ^ (NSInteger approvedCode, NSString *groupName) {
        if (approvedCode != invitationCode)
            return;
        weakSelf.syncingGroupName = groupName;
        weakSelf.pendingSyncingRequestApprovalBlock = nil;
        completion(nil);
    };
}


// create a group name from an User ID. Group names have to start with a letter, so we prefix the name with a string.
// we also append a unique string (time) so that multiple syncing group created by the same user do not clash.

static NSString *makeGroupNameFromUserID(NSString *objectID)
{
    NSString        *timeStamp;
    
    timeStamp = [[NSNumber numberWithLongLong:(long long)([[NSDate date] timeIntervalSince1970] * 1000)] stringValue];
    
    return [[@"group" stringByAppendingString:objectID] stringByAppendingString:timeStamp];
}

// create a new syncing group object in the database

- (void)createSyncingGroupObjectInBackgroundWithBlock:(void(^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    PFUser              *user;
    PFACL               *roleACL;
    PFRole              *role;
    NSString            *name;
    NSArray             *classNames;
    
    user = [PFUser currentUser];
    assert(user);
    
    name = makeGroupNameFromUserID(user.objectId);
    
    roleACL = [PFACL ACL];
    [roleACL setPublicReadAccess:FALSE];
    [roleACL setPublicWriteAccess:FALSE];
    [roleACL setReadAccess:TRUE forUser:[PFUser currentUser]];
    [roleACL setWriteAccess:TRUE forUser:[PFUser currentUser]];
    
    role = [PFRole roleWithName:name acl:roleACL];
    assert(role);
    
    // record this user
    
    [role.users addObject:user];
    
    // set the active user count
    
    [role setObject:@1 forKey:kSLSyncingGroupCountKey];
    
    // record the list of class names
    
    classNames = [self.registry classNames];
    [role addUniqueObjectsFromArray:classNames forKey:kSLSyncingGroupClassNamesKey];
    
    // save the syncing group object. Fail if no connectivity is available to avoid blocking indefinitely
    
    [self.operationMgr savePFObjectInBackground:role waitForConnection:FALSE block:^ (NSError *error) {
        
        if (error) {
            completion(error);
            return;
        }
        
        weakSelf.syncingGroupName = name;
        weakSelf.syncingGroupObject = role;
        
        [weakSelf setDefaultACL];
        
        completion(nil);
    }];
}


// delete a syncing group object

- (void)deleteSyncingGroupObjectInBackground
{
    [self.operationMgr deletePFObjectInBackground:self.syncingGroupObject waitForConnection:TRUE block:nil];
    self.syncingGroupObject = nil;
}

- (void)grantGuestAccessToGroupInBackgroundWithCode:(NSInteger)invitationCode block:(void(^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    PFQuery             *query;
    
    query = [PFQuery queryWithClassName:kSLInvitationClassName];
    [query whereKey:kSLInvitationCodeKey equalTo:@(invitationCode)];
    
    // find the invitation object. Fail if no connectivity is available to avoid indefinitely blocking
    
    [self.operationMgr findQueryObjectsInBackground:query waitForConnection:FALSE block: ^ (NSArray *array, NSError *error) {
        
        PFObject        *invitationObject;
        PFUser          *guest;
        
        if (error) {
            completion(error);
            return;
        }
        
        if ([array count] != 1) {
            NSError     *error;
            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorInvalidCode userInfo:nil];
            completion(error);
            return;
        }
        
        invitationObject = array[0];
        guest = [invitationObject objectForKey:kSLInvitationUserKey];
        assert(guest);
        
        // refresh the syncing group object we are making the changes on a clean copy
        
        [weakSelf.operationMgr fetchPFObjectInBackground:weakSelf.syncingGroupObject waitForConnection:FALSE block: ^(PFObject *object, NSError *error) {
            
            PFRole          *groupObject;
            
            if (error) {
                completion(error);
                return;
            }
            
            // grant our guest read/write access to the syncing group
            
            groupObject = (PFRole *)object;
            weakSelf.syncingGroupObject = groupObject;
            [groupObject.ACL setReadAccess:TRUE forUser:guest];
            [groupObject.ACL setWriteAccess:TRUE forUser:guest];
            
            // save the group object. Fail if no connectivity is available to avoid indefinitely blocking
            
            [weakSelf.operationMgr savePFObjectInBackground:groupObject waitForConnection:FALSE block: ^(NSError *error) {
                
                if (error) {
                    completion(error);
                    return;
                }
                
                [weakSelf sendPushNotificationToUser:guest
                                             payload: @{kSLNotificationPayloadTypeKey: kSLNotificationTypeApproval,
                                                        kSLNotificationPayloadCodeKey: @(invitationCode),
                                                        kSLNotificationPayloadGroupNameKey: weakSelf.syncingGroupName} ];
                completion(nil);
            }];
        }];
    }];
}

- (void)relinquishClientAccessToGroupInBackground
{
    // relinquish read/write access to the syncing group (will be effective after the save)
    
    [self.syncingGroupObject.ACL setReadAccess:FALSE forUser:[PFUser currentUser]];
    [self.syncingGroupObject.ACL setWriteAccess:FALSE forUser:[PFUser currentUser]];
    
    [self.operationMgr savePFObjectInBackground:self.syncingGroupObject waitForConnection:TRUE block:^(NSError *error) {
        assert(!error);
    }];
}

- (void)addClientToGroupInBackgroundWithBlock:(void(^)(NSError *))completion
{
    PFUser      *client;
    
    client = [PFUser currentUser];
    
    // add ourselves to the users list
    
    [self.syncingGroupObject.users addObject:client];
    
    // atomically increment the active client count
    
    [self.syncingGroupObject incrementKey:kSLSyncingGroupCountKey];
    
    // save the group object. Fail if no connectivity is available to avoid indefinitely blocking
    
    [self.operationMgr savePFObjectInBackground:self.syncingGroupObject waitForConnection:FALSE block: ^(NSError *error) {
        
        if (error) {
            completion(error);
            return;
        }
        
        completion(nil);
    }];
}

- (void)removeClientFromGroupInBackground
{
    PFUser      *client;
    
    client = [PFUser currentUser];
    
    // remove ourselves from the syncing group
    
    [self.syncingGroupObject.users removeObject:client];
    
    // atomically decrement the active client count
    
    [self.syncingGroupObject incrementKey:kSLSyncingGroupCountKey byAmount:@-1];
    
    // relinquish read/write access to the syncing group (will be effective after the save)
    
    [self.syncingGroupObject.ACL setReadAccess:FALSE forUser:[PFUser currentUser]];
    [self.syncingGroupObject.ACL setWriteAccess:FALSE forUser:[PFUser currentUser]];
    
    [self.operationMgr savePFObjectInBackground:self.syncingGroupObject waitForConnection:TRUE block:^(NSError *error) {
        assert(!error);
    }];
}

// retrieve the syncing group object from the database

- (void)downloadSyncingGroupObjectInBackground:(BOOL)waitForConnection block:(void(^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    PFQuery             *query;
    
    // query the syncing group object using its name.
    
    query = [PFRole query];
    [query whereKey:kSLSyncingGroupNameKey equalTo:self.syncingGroupName];
    
    // find the syncing group
    
    [self.operationMgr findQueryObjectsInBackground:query waitForConnection:waitForConnection block: ^(NSArray *array, NSError *error) {
        
        if (error) {
            completion(error);
            return;
        }
        assert([array count] == 1);
        
        weakSelf.syncingGroupObject = array[0];
        
        completion(nil);
    }];
}


- (void)subscribeToChannelInBackgroundWithBlock:(void(^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    PFInstallation      *installation;
    
    installation = [PFInstallation currentInstallation];
    assert(installation);
    
    // wait for push notifications to be enabled, if they haven't yet
    
    [self.deviceTokenRegistered waitInBackgroundWithBlock:^(){
        
        [installation addUniqueObject:self.syncingGroupName forKey:kSLInstallationChannelKey];
        
        // save the installation object. Fail if no connectivity is available to avoid indefinitely blocking
        
        [weakSelf.operationMgr savePFObjectInBackground:installation waitForConnection:FALSE block: ^(NSError *error) {
            
            completion(error);
        }];
    }];
}

- (void)unsubscribeFromChannelInBackground
{
    PFInstallation      *installation;
    
    installation = [PFInstallation currentInstallation];
    assert(installation);
    [installation removeObject:self.syncingGroupName forKey:kSLInstallationChannelKey];
    [self.operationMgr savePFObjectInBackground:installation waitForConnection:TRUE block:nil];
}


// sendPushNotificationToChannel:message:data: sends a push notification to the specified channel (except ourselves) and with the specified payload

- (void)sendPushNotificationToChannel:(NSString *)channel payload:(NSDictionary *)payload
{
    PFPush      *push;
    PFQuery     *query;
    
    push = [[PFPush alloc] init];
    query = [PFInstallation query];
    [query whereKey:kSLInstallationChannelKey equalTo:channel];
    [query whereKey:kSLInstallationUserKey notEqualTo:[PFUser currentUser]];
    [push setQuery:query];
    [push setData:payload];
    [push sendPushInBackground];
}


// sendPushNotificationToUser:message:data: sends a push notification to the specified user and with the specified payload

- (void)sendPushNotificationToUser:(PFUser *)user payload:(NSDictionary *)payload
{    
    PFPush      *push;
    PFQuery     *query;
    
    push = [[PFPush alloc] init];
    query = [PFInstallation query];
    [query whereKey:kSLInstallationUserKey equalTo:user];
    [push setQuery:query];
    [push setData:payload];
    [push sendPushInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        NSLog(@"Push to user %@: succeeded %d, Error: %@\n", user.objectId, succeeded, error);
    }];
}


@end
