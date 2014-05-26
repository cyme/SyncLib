//
//  SLObjectRegistry.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>


// SLObjectRegistry is a singleton class that holds a registry of all SLObjects and performs sync operations


@class SLObject;
@class PFObject;
@protocol SLObjectObserving;


@interface SLObjectRegistry : NSObject

// return the shared SLObjectRegistry instance, creating it if necessary

+ (SLObjectRegistry *)sharedObjectRegistry;

- (void)registerSubclass:(Class)subclass;
- (void)addObserver:(id<SLObjectObserving>)observer forClass:(Class)subclass;
- (void)removeObserver:(id<SLObjectObserving>)observer forClass:(Class)subclass;

- (void)syncAllInBackgroundWithBlock: (void(^)(NSError *))completion;
- (void)scheduleSync;
- (void)loadFromDisk;
- (void)saveToDisk;
- (void)startSyncingTimer;
- (void)stopSyncingTimer;

- (void)addObject:(SLObject *)object;
- (void)removeObject:(SLObject *)object;
- (void)removeAllObjects;
- (void)markObjectModified:(SLObject *)object local:(BOOL)local;
- (void)markObjectUnmodified:(SLObject *)object local:(BOOL)local;

- (NSArray *)classNames;
- (SLObject *)objectForID:(NSString *)objectID;
- (NSArray *)observersForClassWithName:(NSString *)className;
- (Class)classForRegisteredClassWithName:(NSString *)className;
- (NSArray *)cloudPersistedPropertiesForClassWithName:(NSString *)className;
- (NSArray *)localPersistedPropertiesForClassWithName:(NSString *)className;
- (NSArray *)localTransientPropertiesForClassWithName:(NSString *)className;

@end