//
//  SLObjectRegistry.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>


// SLObjectRegistry is a singleton class that holds a registry of all SLObjects and performs sync operations


@class SLObject;
@class SLChange;
@class PFObject;
@protocol SLObjectObserving;


@interface SLObjectRegistry : NSObject

@property (nonatomic) NSTimeInterval        syncLag;

// return the shared SLObjectRegistry instance, creating it if necessary

+ (SLObjectRegistry *)sharedObjectRegistry;

- (void)registerSubclass:(Class)subclass;
- (void)addObserver:(id<SLObjectObserving>)observer forClass:(Class)subclass;
- (void)removeObserver:(id<SLObjectObserving>)observer forClass:(Class)subclass;

- (void)syncAllInBackgroundWithBlock: (void(^)(NSError *))completion;
- (void)setSyncLag:(NSTimeInterval)lag;
- (void)scheduleSync;
- (void)loadFromDisk;
- (void)saveToDisk;
- (void)startSyncingTimer;
- (void)stopSyncingTimer;

- (void)removeAllObjects;

- (void)insertObject:(SLObject *)object;
- (void)markObjectDeleted:(SLObject *)object;
- (void)markObjectModified:(SLObject *)object local:(BOOL)local;
- (void)markObjectUnmodified:(SLObject *)object local:(BOOL)local;

- (void)addRemoteChange:(SLChange *)change;
- (void)removeRemoteChange:(SLChange *)change;

- (id)uncommittedValueForObject:(SLObject *)object key:(NSString *)key;
- (void)setUncommittedValue:(id)value forObject:(SLObject *)object key:(NSString *)key;
- (void)clearUncommittedValues;

- (BOOL)inNotification;

- (NSArray *)classNames;
- (SLObject *)objectForID:(NSString *)objectID;
- (NSArray *)observersForClassWithName:(NSString *)className;
- (Class)classForRegisteredClassWithName:(NSString *)className;
- (NSArray *)cloudPersistedPropertiesForClassWithName:(NSString *)className;
- (NSArray *)localPersistedPropertiesForClassWithName:(NSString *)className;
- (NSArray *)localTransientPropertiesForClassWithName:(NSString *)className;

- (void)notifyObserversWillChangeObjects:(NSArray *)observers;
- (void)notifyObserversDidChangeObjects:(NSArray *)observers;
- (void)notifyObserversWillDeleteObject:(SLObject *)object remote:(BOOL)remote;
- (void)notifyObserversDidCreateObject:(SLObject *)object remote:(BOOL)remote;
- (void)notifyObserver:(id<SLObjectObserving>)observer didCreateObject:(SLObject *)object remote:(BOOL)remote;
- (void)notifyObserversWillChangeObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue remote:(BOOL)remote;
- (void)notifyObserversDidChangeObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue remote:(BOOL)remote;

@end