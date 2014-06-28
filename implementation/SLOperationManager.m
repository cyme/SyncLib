//
//  SLOperationManager.m
//  ShoppingList
//
//  Created by Cyril Meurillon on 4/18/14.
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import "SLOperationManager.h"
#import "SLObject-Internal.h"
#import "BlockCondition.h"
#import <Parse/Parse.h>

#define USE_REACHABILITY_LIBRARY    0

#if USE_REACHABILITY_LIBRARY
#import "Reachability.h"
#else
#import <SystemConfiguration/SystemConfiguration.h>
#endif


@interface SLOperationManager ()

@property (nonatomic) BlockCondition            *online;
@property (nonatomic) NSMutableArray            *operationQueue;
@property (nonatomic) NSMutableSet              *onlineOnlyOperationQueue;
@property (nonatomic) NSMutableSet              *pendingIOs;

#if USE_REACHABILITY_LIBRARY
@property (nonatomic) Reachability              *reachability;
#else
@property (nonatomic) SCNetworkReachabilityRef  reachability;
#endif

@end


@implementation SLOperationManager

+ (SLOperationManager *)sharedOperationManager
{
    static SLOperationManager *operationMgr = nil;
    static dispatch_once_t  onceToken;
    
    // check if the registry needs to be initialized
    
    if (!operationMgr)
        
        // initialize the registry in a thread-safe manner
        // this really isn't necessary given that the library currently isn't thread safe, but it's fun anyway
        
        dispatch_once(&onceToken, ^{
            
            // registry is a (static) global, therefore it does not need to be declared __block
            
            operationMgr = [[SLOperationManager alloc] init];
            
        });
    return operationMgr;
}


#if !USE_REACHABILITY_LIBRARY
static void reachabilityChanged(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    
    SLOperationManager            *operationMgr;
    
    operationMgr = (__bridge SLOperationManager *)info;
    if (flags & kSCNetworkReachabilityFlagsReachable) {
        
        // verify we are coming back online. notifications may also be sent to indicate changes of types of connectivity (e.g. cellular to wifi)
        
        if (operationMgr.online.condition)
            return;
        
        // coming back online. Unblock all IOs currently waiting for connectivity.

        [operationMgr.online broadcast];
        
    } else {
        
        // ensure we are going offline.
        
        if (!operationMgr.online.condition)
            return;

        // going offline. Unblock all pending operations that are online-only

        [operationMgr.online reset];
        [operationMgr unblockOnlineOnlyOperationsWithError:[NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil]];
        
    }
}

#endif


- (id)init
{
    self = [super init];
    assert(self);
    
    _online = [BlockCondition blockCondition];
    assert(_online);
    _operationQueue = [NSMutableArray array];
    assert(_operationQueue);
    _onlineOnlyOperationQueue = [NSMutableSet set];
    assert(_onlineOnlyOperationQueue);
    _pendingIOs = [NSMutableSet set];
    
    
#if USE_REACHABILITY_LIBRARY
    
    __weak typeof(self)                 weakSelf = self;

    _reachability = [Reachability reachabilityWithHostName:@"wwww.parse.com"];
    assert(_reachability);
    
    _reachability.reachableBlock = ^(Reachability *reachability) {
        
        // the block does not get called on the main thread. therefore we need to
        // dispatch another block on the main thread to get the work done.
        
        dispatch_async(dispatch_get_main_queue(), ^() {
            
            // verify we are coming back online. notifications may also be sent to indicate changes of types of connectivity (e.g. cellular to wifi)
            
            if (slio.online.condition)
                return;
            
            // coming back online. Unblock all IOs currently waiting for connectivity.
            
            [weakSelf.online broadcast];
        });
    };
    
    _reachability.unreachableBlock = ^(Reachability *reachability) {
        
        // the block does not get called on the main thread. therefore we need to
        // dispatch another block on the main thread to get the work done.
        
        dispatch_async(dispatch_get_main_queue(), ^() {

            // ensure we are going offline.
            
            if (!slio.online.condition)
                return;
            
            // going offline. Unblock all pending operations that are online-only
            
            [weakSelf.online reset];
            [weakSelf unblockOnlineOnlyOperationsWithError:[NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil]];
        });
    };
    assert([_reachability startNotifier]);
    
    // set the online condition now if a connection is available. we can't wait until the reachability status block is called to capture the
    // initial state, as the block is asynchronously dispatched on the main thread. waiting until then would cause any IO fired before the block
    // is invoked to block or fail
    
    if ([_reachability isReachable])
        [_online broadcast];
    
#else
    
    SCNetworkReachabilityContext        context;
    CFRunLoopRef                        runLoop;
    SCNetworkReachabilityFlags          flags;
    
    _reachability = SCNetworkReachabilityCreateWithName(NULL, "www.parse.com");
    context.version = 0;
    context.info = (__bridge void *)self;
    context.retain = NULL;
    context.release = NULL;
    context.copyDescription = NULL;
    SCNetworkReachabilitySetCallback(_reachability, &reachabilityChanged, &context);
    runLoop = [[NSRunLoop mainRunLoop] getCFRunLoop];
    SCNetworkReachabilityScheduleWithRunLoop(_reachability, runLoop, kCFRunLoopDefaultMode);
    SCNetworkReachabilityGetFlags(_reachability, &flags);
    
    // set the online condition now if a connection is available. we can't wait until the reachability status block is called to capture the
    // initial state, as the block is asynchronously dispatched on the main thread. waiting until then would cause any IO fired before the block
    // is invoked to block or fail

    if (flags & kSCNetworkReachabilityFlagsReachable)
        [_online broadcast];

#endif
    return self;
}

- (void) dealloc {
    
#if USE_REACHABILITY_LIBRARY
    
    [self.reachability stopNotifier];

#else
    
    CFRunLoopRef                        runLoop;

    runLoop = [[NSRunLoop mainRunLoop] getCFRunLoop];
    SCNetworkReachabilityUnscheduleFromRunLoop(self.reachability, runLoop, kCFRunLoopDefaultMode);
    CFRelease(self.reachability);
    
#endif
}

// serialize:operation:
// serialize the execution of the passed block, i.e. defer its execution until all current and pending operations have completed.
// offline indicates whether the serialized operation is offline capable. Offline capable operations block indefinitely when no connectivity
// is available. Online-only operations return with an error when no connectivity is available

- (void) serialize:(BOOL)waitForConnection operation:(void(^)(NSError *))operation {
    
    NSUInteger count;
    
    // fail an online-only operation if we currently are offline
    
    if (!waitForConnection && !self.online.condition) {
        NSError         *error;
        
        error = [NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil];
        operation(error);
        return;
    }
    
    count = [self.operationQueue count];
    [self.operationQueue addObject:operation];
    
    // add the operation to the list of pending online only capable operations if the queue isn't empty
    
    if (!waitForConnection && (count > 0))
        [self.onlineOnlyOperationQueue addObject:operation];
    
    // run the block if it's the only one on theclass queue
    
    if (count == 0)
        operation(nil);
}


// runNextOperation dequeues the next operation to be executed asynchronously from the FIFO queue
// all operation blocks must invoke runNextOperation before they complete

- (void) runNextOperation {
    
    NSUInteger  count;
    
    void        (^operation)(NSError *);
    
    count = [self.operationQueue count];
    assert(count > 0);
    
    operation = self.operationQueue[0];
    [self.operationQueue removeObjectAtIndex:0];
    [self.onlineOnlyOperationQueue removeObject:operation];
    
    if (count > 1) {
        operation = self.operationQueue[0];
        [self.onlineOnlyOperationQueue removeObject:operation];
        operation(nil);
    }
}


// unblockOnlineOnlyOperationsWithError: dequeues all operations that are online-only and invokes
// their completion block with a network unavailable error

- (void) unblockOnlineOnlyOperationsWithError:(NSError *)error {
    
    void        (^operation)(NSError *);
    NSSet       *onlineOnlyOperations;
    
    // nothing to do if there are no online-only operations in the queue
    
    if ([self.onlineOnlyOperationQueue count] == 0)
        return;
    
    // make a copy of the queue of online-only operations as we are going to empty it before we invoke the operations.
    
    onlineOnlyOperations = [NSSet setWithSet:self.onlineOnlyOperationQueue];
    
    // remove all online only IO operations from the queue

    [self.onlineOnlyOperationQueue removeAllObjects];
    for (operation in onlineOnlyOperations)
        [self.operationQueue removeObject:operation];
    
    // unblock the IO operations with an error
    
    for (operation in onlineOnlyOperations)
        operation(error);
}


static BOOL isParseConnectionError(NSError *error) {
    if (error && [error.domain isEqualToString:@"Parse"] && (error.code == kPFErrorConnectionFailed))
        return TRUE;
    return FALSE;
}


- (void) fetchPFObjectInBackground:(PFObject *)object waitForConnection:(BOOL)waitForConnection block:(void(^)(PFObject *, NSError *))completion {
    
    __weak typeof(self) weakSelf = self;
    __block void        (^operation)(BOOL);
    void                (^continuation)(PFObject *, NSError *);
    
    // create a continuation block to be called after the operation completes or an error occurs
    
    continuation = ^(PFObject *refreshedObject, NSError *error) {
        
        // deal with errors
        
        if (error) {
            
            // for all other errors than Parse connection errors, report the error to the caller
            
            if (!isParseConnectionError(error)) {
                
                // report the error to the caller if a completion block was provided
                
                if (completion)
                    completion(refreshedObject, error);
                
                // set the operation block to nil to trigger a release and deallocation of the block objects.
                // this is necessary because the operation and continuation blocks reference each other and therefore
                // create a retain cycle.
                
                operation = nil;
                return;
            }
            
            // this is a Parse connection error. restart the operation once a connection becomes available
            // note 1: the operation variable has not been set when it is captured by this block, which is why it's declared as __block
            // note 2: the operation block is strongly captured here, so that it is not released before we invoke it
            
            [weakSelf.online waitInBackground:waitForConnection block:operation];
            return;
        }
        
        // the operation completed without error. invoke the caller completion block if one was provided
        
        if (completion)
            completion(refreshedObject, nil);
        
        // set the operation block to nil to trigger a release of the block objects. see earlier comment.
        
        operation = nil;
    };
    
    // create an operation block to perform the Parse operation
    
    operation = ^(BOOL success) {
        
        // check if we have a connectivity error. that's the case of an online-only operation that was started without connectivity.
        
        if (!success) {
            
            // invoke the continuation block with a network error
            
            NSError         *error;
            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil];
            continuation(nil, error);
            return;
        }
        
        // start the Parse operation and pass the continuation block as the completion handler.
        // note 1: the continuation variable has aready been set when it is captured by this block, so no need to declare it __block.\
        // note 2: the operation and continuation blocks strongly reference each other, which creates a retain cycle. the cycle is
        // manually removed in the continuation block.
        
        [object fetchInBackgroundWithBlock:continuation];
    };
    
    // start the operation when a connection is available. if this is an online-only operation, don't block and invoke the operation
    // block with an error if no connection was available
    
    [self.online waitInBackground:waitForConnection block:operation];
}

- (void) savePFObjectInBackground:(PFObject *)object waitForConnection:(BOOL)waitForConnection block:(void(^)(NSError *))completion {
    
    __weak typeof(self) weakSelf = self;
    __block void        (^operation)(BOOL);
    void                (^continuation)(BOOL, NSError *);
    
    // create a continuation block to be called after the operation completes or an error occurs

    continuation = ^(BOOL succeeded, NSError *error) {
        
        // deal with errors

        if (!succeeded) {
            
            // for all other errors than Parse connection errors, report the error to the caller

            if (!isParseConnectionError(error)) {
                
                // report the error to the caller if a completion block was provided

                if (completion)
                    completion(error);
                
                // set the operation block to nil to trigger a release and deallocation of the block objects.
                // this is necessary because the operation and continuation blocks reference each other and therefore
                // create a retain cycle.

                operation = nil;
                return;
            }
            
            // this is a Parse connection error. restart the operation once a connection becomes available
            // note 1: the operation variable has not been set when it is captured by this block, which is why it's declared as __block
            // note 2: the operation block is strongly captured here, so that it is not released before we invoke it
            
            [weakSelf.online waitInBackground:waitForConnection block:operation];
            return;
        }
        
        // the operation completed without error. invoke the caller completion block if one was provided

        if (completion)
            completion(nil);
        
        // set the operation block to nil to trigger a release of the block objects. see earlier comment.

        operation = nil;
    };
    
    // create an operation block to perform the Parse operation

    operation = ^(BOOL success) {
        
        // check if we have a connectivity error. that's the case of an online-only operation that was started without connectivity.

        if (!success) {
            
            // invoke the continuation block with a network error

            NSError         *error;
            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil];
            continuation(FALSE, error);
            return;
        }
        
        // start the Parse operation and pass the continuation block as the completion handler.
        // note 1: the continuation variable has aready been set when it is captured by this block, so no need to declare it __block.\
        // note 2: the operation and continuation blocks strongly reference each other, which creates a retain cycle. the cycle is
        // manually removed in the continuation block.
        
        [object saveInBackgroundWithBlock:continuation];
    };
    
    // start the operation when a connection is available. if this is an online-only operation, don't block and invoke the operation
    // block with an error if no connection was available
    
    [self.online waitInBackground:waitForConnection block:operation];
}

- (void) savePFObjectsInBackground:(NSArray *)objects waitForConnection:(BOOL)waitForConnection block:(void(^)(NSError *))completion {

    __weak typeof(self) weakSelf = self;
    __block void        (^operation)(BOOL);
    void                (^continuation)(BOOL, NSError *);
    
    // create a continuation block to be called after the operation completes or an error occurs
    
    continuation = ^(BOOL succeeded, NSError *error) {
        
        // deal with errors
        
        if (!succeeded) {
            
            // for all other errors than Parse connection errors, report the error to the caller
            
            if (!isParseConnectionError(error)) {
                
                // report the error to the caller if a completion block was provided
                
                if (completion)
                    completion(error);
                
                // set the operation block to nil to trigger a release and deallocation of the block objects.
                // this is necessary because the operation and continuation blocks reference each other and therefore
                // create a retain cycle.
                
                operation = nil;
                return;
            }
            
            // this is a Parse connection error. restart the operation once a connection becomes available
            // note 1: the operation variable has not been set when it is captured by this block, which is why it's declared as __block
            // note 2: the operation block is strongly captured here, so that it is not released before we invoke it
            
            [weakSelf.online waitInBackground:waitForConnection block:operation];
            return;
        }
        
        // the operation completed without error. invoke the caller completion block if one was provided
        
        if (completion)
            completion(nil);
        
        // set the operation block to nil to trigger a release of the block objects. see earlier comment.
        
        operation = nil;
    };
    
    // create an operation block to perform the Parse operation
    
    operation = ^(BOOL success) {
        
        // check if we have a connectivity error. that's the case of an online-only operation that was started without connectivity.
        
        if (!success) {
            
            // invoke the continuation block with a network error
            
            NSError         *error;
            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil];
            continuation(FALSE, error);
            return;
        }
        
        // start the Parse operation and pass the continuation block as the completion handler.
        // note 1: the continuation variable has aready been set when it is captured by this block, so no need to declare it __block.\
        // note 2: the operation and continuation blocks strongly reference each other, which creates a retain cycle. the cycle is
        // manually removed in the continuation block.
        
        [PFObject saveAllInBackground:objects block:continuation];
    };
    
    // start the operation when a connection is available. if this is an online-only operation, don't block and invoke the operation
    // block with an error if no connection was available
    
    [self.online waitInBackground:waitForConnection block:operation];
}

- (void) deletePFObjectInBackground:(PFObject *)object waitForConnection:(BOOL)waitForConnection block:(void(^)(NSError *))completion {
    
    __weak typeof(self) weakSelf = self;
    __block void        (^operation)(BOOL);
    void                (^continuation)(BOOL, NSError *);
    
    // create a continuation block to be called after the operation completes or an error occurs
    
    continuation = ^(BOOL succeeded, NSError *error) {
        
        // deal with errors
        
        if (!succeeded) {
            
            // for all other errors than Parse connection errors, report the error to the caller
            
            if (!isParseConnectionError(error)) {
                
                // report the error to the caller if a completion block was provided
                
                if (completion)
                    completion(error);
                
                // set the operation block to nil to trigger a release and deallocation of the block objects.
                // this is necessary because the operation and continuation blocks reference each other and therefore
                // create a retain cycle.
                
                operation = nil;
                return;
            }
            
            // this is a Parse connection error. restart the operation once a connection becomes available
            // note 1: the operation variable has not been set when it is captured by this block, which is why it's declared as __block
            // note 2: the operation block is strongly captured here, so that it is not released before we invoke it
            
            [weakSelf.online waitInBackground:waitForConnection block:operation];
            return;
        }
        
        // the operation completed without error. invoke the caller completion block if one was provided
        
        if (completion)
            completion(nil);
        
        // set the operation block to nil to trigger a release of the block objects. see earlier comment.
        
        operation = nil;
    };
    
    // create an operation block to perform the Parse operation
    
    operation = ^(BOOL success) {
        
        // check if we have a connectivity error. that's the case of an online-only operation that was started without connectivity.
        
        if (!success) {
            
            // invoke the continuation block with a network error
            
            NSError         *error;
            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil];
            continuation(FALSE, error);
            return;
        }
        
        // start the Parse operation and pass the continuation block as the completion handler.
        // note 1: the continuation variable has aready been set when it is captured by this block, so no need to declare it __block.\
        // note 2: the operation and continuation blocks strongly reference each other, which creates a retain cycle. the cycle is
        // manually removed in the continuation block.
        
        [object deleteInBackgroundWithBlock:continuation];
    };
    
    // start the operation when a connection is available. if this is an online-only operation, don't block and invoke the operation
    // block with an error if no connection was available
    
    [self.online waitInBackground:waitForConnection block:operation];
}


- (void) findQueryObjectsInBackground:(PFQuery *)query waitForConnection:(BOOL)waitForConnection block:(void(^)(NSArray *, NSError *))completion {
    
    __weak typeof(self) weakSelf = self;
    __block void        (^operation)(BOOL);
    void                (^continuation)(NSArray *, NSError *);
    
    // create a continuation block to be called after the operation completes or an error occurs
    
    continuation = ^(NSArray *results, NSError *error) {
        
        // deal with errors
        
        if (error) {
            
            // for all other errors than Parse connection errors, report the error to the caller
            
            if (!isParseConnectionError(error)) {
                
                // report the error to the caller if a completion block was provided
                
                if (completion)
                    completion(nil, error);
                
                // set the operation block to nil to trigger a release and deallocation of the block objects.
                // this is necessary because the operation and continuation blocks reference each other and therefore
                // create a retain cycle.
                
                operation = nil;
                return;
            }
            
            // this is a Parse connection error. restart the operation once a connection becomes available
            // note 1: the operation variable has not been set when it is captured by this block, which is why it's declared as __block
            // note 2: the operation block is strongly captured here, so that it is not released before we invoke it
            
            [weakSelf.online waitInBackground:waitForConnection block:operation];
            return;
        }
        
        // the operation completed without error. invoke the caller completion block if one was provided
        
        if (completion)
            completion(results, nil);
        
        // set the operation block to nil to trigger a release of the block objects. see earlier comment.
        
        operation = nil;
    };
    
    // create an operation block to perform the Parse operation
    
    operation = ^(BOOL success) {
        
        // check if we have a connectivity error. that's the case of an online-only operation that was started without connectivity.
        
        if (!success) {
            
            // invoke the continuation block with a network error
            
            NSError         *error;
            error = [NSError errorWithDomain:SLErrorDomain code:SLErrorNoConnection userInfo:nil];
            continuation(FALSE, error);
            return;
        }
        
        // start the Parse operation and pass the continuation block as the completion handler.
        // note 1: the continuation variable has aready been set when it is captured by this block, so no need to declare it __block.\
        // note 2: the operation and continuation blocks strongly reference each other, which creates a retain cycle. the cycle is
        // manually removed in the continuation block.
        
        [query findObjectsInBackgroundWithBlock:continuation];
    };
    
    // start the operation when a connection is available. if this is an online-only operation, don't block and invoke the operation
    // block with an error if no connection was available
    
    [self.online waitInBackground:waitForConnection block:operation];
}


@end
