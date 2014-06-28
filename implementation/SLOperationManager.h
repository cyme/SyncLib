//
//  SLOperationManager.h
//  ShoppingList
//
//  Created by Cyril Meurillon on 4/18/14.
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>

@class PFObject;
@class PFQuery;

// SLOperationManager is a singleton class that provides
// 1) serialization for SyncLib operations and
// 2) offline-resistant versions of the Parse methods we are using

@interface SLOperationManager : NSObject

// returns a pointer to the singleton instance

+ (SLOperationManager *)sharedOperationManager;

// methods to serialize SyncLib operations

- (void)serialize:(BOOL)waitForConnection operation:(void(^)(NSError *))block;
- (void)runNextOperation;
- (void)unblockOnlineOnlyOperationsWithError:(NSError *)error;

// offline-resistant versions of Parse methods

- (void)fetchPFObjectInBackground:(PFObject *)object waitForConnection:(BOOL)waitForConnection block:(void(^)(PFObject *, NSError *))completion;
- (void)savePFObjectInBackground:(PFObject *)object waitForConnection:(BOOL)waitForConnection block:(void(^)(NSError *))completion;
- (void)savePFObjectsInBackground:(NSArray *)objects waitForConnection:(BOOL)waitForConnection block:(void(^)(NSError *))completion;
- (void)deletePFObjectInBackground:(PFObject *)object waitForConnection:(BOOL)waitForConnection block:(void(^)(NSError *))completion;
- (void)findQueryObjectsInBackground:(PFQuery *)query waitForConnection:(BOOL)waitForConnection block:(void(^)(NSArray *, NSError *))completion;

@end
