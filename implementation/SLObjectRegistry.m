//
//  SLObjectRegistry.m
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLObjectRegistry.h"
#import "SLClientManager-Internal.h"
#import "SLObject-Internal.h"
#import "SLOperationManager.h"
#import "SLChange.h"
#import "SLTransaction-Internal.h"
#import "SLTransactionManager.h"
#import "SLObjectObserving.h"
#import "BlockCondition.h"
#import <Parse/Parse.h>
#import <objc/runtime.h>



static NSString * const kPFObjectDeleteFlagKey = @"DELETED";
static NSString * const kPFObjectLastModifiedKey = @"updatedAt";

static NSSet *kPFObjectSystemKeys;

static NSString * const kSLObjectRegistryClientMgrKey = @"clientMgr";
static NSString * const kSLObjectRegistryTransactionMgrKey = @"transactionMgr";
static NSString * const kSLObjectRegistryLastSyncKey = @"lastSync";
static NSString * const kSLObjectRegistryObjectsKey = @"objects";

static NSString * const kSLCacheFileName = @"SLCache";

static NSTimeInterval const kSLDefaultSyncLag = 10.0;
static NSTimeInterval const kSLDefaultSyncInterval = 120.0;



#pragma mark - Private Interface

@interface SLObjectRegistry ()

@property (nonatomic) SLClientManager       *clientMgr;
@property (nonatomic) SLOperationManager    *operationMgr;
@property (nonatomic) SLTransactionManager  *transactionMgr;

@property (nonatomic) NSTimeInterval        syncInterval;
@property (nonatomic) NSDate                *lastSync;
@property (nonatomic) NSTimer               *timer;

@property (nonatomic) NSMutableSet          *objects;
@property (nonatomic) NSMutableDictionary   *objectIDMap;

@property (nonatomic) NSMutableSet          *locallyModifiedObjects;
@property (nonatomic) NSMutableDictionary   *locallyModifiedObjectIDMap;
@property (nonatomic) NSMutableSet          *locallyCreatedObjects;
@property (nonatomic) NSMutableSet          *locallyDeletedObjects;
@property (nonatomic) NSMutableDictionary   *locallyDeletedObjectIDMap;

@property (nonatomic) NSMapTable            *uncommittedValues;

@property (nonatomic) NSMutableDictionary   *registeredClasses;
@property (nonatomic) NSMutableDictionary   *observers;
@property (nonatomic) NSMapTable            *observerNotified;
@property NSInteger                         notificationNestingLevel;

@property (nonatomic) NSMutableDictionary   *cloudPersistedProperties;
@property (nonatomic) NSMutableDictionary   *localPersistedProperties;
@property (nonatomic) NSMutableDictionary   *localTransientProperties;

// properties used by -syncAllInBackgroundWithBlock:

@property (nonatomic) NSMutableArray        *downloadedObjects;
@property (nonatomic) NSMutableDictionary   *downloadedObjectIDMap;

@property (nonatomic) NSMutableSet          *remotelyModifiedObjects;
@property (nonatomic) NSMutableSet          *remotelyCreatedObjects;
@property (nonatomic) NSMutableSet          *remotelyDeletedObjects;

@property (nonatomic) NSMutableOrderedSet   *remoteChanges;
@property (nonatomic) NSArray               *voidedChanges;
@property (nonatomic) NSArray               *confirmedChanges;

@property (nonatomic) NSMutableSet          *savedLocallyModifiedObjects;
@property (nonatomic) NSMutableDictionary   *savedLocallyModifiedObjectIDMap;
@property (nonatomic) NSMutableSet          *savedLocallyCreatedObjects;
@property (nonatomic) NSMutableSet          *savedLocallyDeletedObjects;
@property (nonatomic) NSMutableDictionary   *savedLocallyDeletedObjectIDMap;


// factory methods

- (id)init;

// Sync helper methods

- (void)timerFireMethod:(NSTimer *)timer;
- (void)cleanupAfterSyncWithError:(NSError *)error;
- (void)identifyRemotelyDeletedObjects;
- (void)identifyRemotelyCreatedObjects;
- (void)identifyRemotelyModifiedObjects;
- (void)finalizeUncommittedChanges;
- (void)resolveDanglingReferencesToDeletedObjects:(NSSet *)deletedObjects local:(BOOL)local;
- (void)resolveDanglingReferences;
- (void)updateDatabaseObjectCache;
- (NSArray *)orderObjectsByAncestry:(NSSet *)objects increasing:(BOOL)increasing;
- (void)notifyChanges;
- (void)mergeChanges;
- (BOOL)isDownloadedGraphComplete;
- (void)downloadObjectsInBackgroundChangedSince:(NSDate*)since
                                   withClassName:(NSString *)className
                                      completion:(void(^)(NSArray *, NSError *))continuation;
- (void)downloadObjectsInBackgroundChangedSince:(NSDate *)since
                                          trials:(NSInteger)trials
                                      completion:(void(^)(NSError *))continuation;
- (void)saveLocalChangesInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion;
- (void)saveDeletedObjectsInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion;
- (void)saveCreatedObjectsInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion;
- (void)saveModifiedObjectsInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion;

@end


@implementation SLObjectRegistry

#pragma mark - Public methods

// return the shared instance of the global registry

+ (SLObjectRegistry *)sharedObjectRegistry
{
    static SLObjectRegistry *registry = nil;
    static dispatch_once_t  onceToken;
    
    // check if the registry needs to be initialized
    
    if (!registry)
        
        // initialize the registry in a thread-safe manner
        // this really isn't necessary given that the library currently isn't thread safe, but it's fun anyway
        
        dispatch_once(&onceToken, ^{
            
            // registry is a (static) global, therefore it does not need to be declared __block
            
            registry = [[SLObjectRegistry alloc] init];
            
        });
    return registry;
}

// register subclass

- (void)registerSubclass:(Class)subclass
{
    NSString            *className;
    NSArray             *allProperties, *localPersisted, *localTransient;
    NSMutableArray      *cloudPersisted;
    
    // if the className hasn't been registered yet, register it
    
    className = [subclass className];
    if (self.registeredClasses[className])
        return;
    
     // register the class
    self.registeredClasses[className] = subclass;
    
    // initialize the list of observers for that class
    
    self.observers[className] = [NSMutableArray array];

    // generate the property lists and attribute accessor methods
    
    allProperties = [subclass allProperties];
    localPersisted = [subclass localPersistedProperties];
    localTransient = [subclass localTransientProperties];
    cloudPersisted = [NSMutableArray array];
    
    for(NSString *property in localPersisted)
        assert([allProperties containsObject:property]);
    for(NSString *property in localTransient)
        assert([allProperties containsObject:property]);
    for(NSString *property in allProperties)
        if (![localPersisted containsObject:property] && ![localTransient containsObject:property])
            [cloudPersisted addObject:property];
    
    self.cloudPersistedProperties[className] = cloudPersisted;
    self.localPersistedProperties[className] = localPersisted;
    self.localTransientProperties[className] = localTransient;
    
    [subclass generateDynamicAccessors];
}


// add a class observer

- (void)addObserver:(id<SLObjectObserving>)observer forClass:(Class)subclass
{
    NSString        *className;
    NSMutableSet    *createdObjects;
    
    className = [subclass className];
    if (!self.registeredClasses[className])
        return;
    [self.observers[className] addObject:observer];
    
    // retroactively notify of the creation the objects that have already been fetched from the cache
    // and created either locally or remotely. Past deletions do not need to be notified.
    
    createdObjects = [NSMutableSet set];
    for(SLObject *object in self.objects)
        if (!object.deleted && (self.registeredClasses[object.className] == subclass)) {
                [createdObjects addObject:object];
        }
    
    if ([createdObjects count] > 0) {
        
        // notify the beginning of change notifications
        
        [self notifyObserversWillChangeObjects:@[observer]];
     
        // notify of object creations
    
        for(SLObject *object in createdObjects)
            [self notifyObserver:observer didCreateObject:object remote:FALSE];

        // notify the end of change notifications
        
        [self notifyObserversDidChangeObjects:@[observer]];
    }
}


// remove a class observer

- (void)removeObserver:(id<SLObjectObserving>)observer forClass:(Class)subclass
{
    NSString        *className;
    
    className = [subclass className];
    if (!self.observers[className])
        return;
    [self.observers[className] removeObject:observer];
}

// syncAllInBackgroundWithBlock: is the top-level method implementing asynchronous syncs (uploading of local changes &
// downloading of remote changes, merging of results, conflict resolution, observer notification).
// The work is broken down in smaller jobs and executed by a variety of helper methods.

- (void)syncAllInBackgroundWithBlock:(void(^)(NSError *))completion
{
    __weak typeof(self) weakSelf = self;
    
    // seralize sync request to ensure serialization of all sync and other IO operations
    // simultaneous and reentrant sync calls (e.g. notification handlers calling sync) are serialized

    [self.operationMgr serialize:TRUE operation: ^(NSError *error) {

        NSDate      *date;
        
        // if the client isn't associated with any syncing group, there's nothing to do.
        
        if (!weakSelf.clientMgr.syncing) {
            completion(nil);
            [weakSelf.operationMgr runNextOperation];
            return;
        }
        

        date = [NSDate date];
        
        // download the database objects that have changed since the last sync
        
        [weakSelf downloadObjectsInBackgroundChangedSince:self.lastSync trials:0 completion: ^(NSError *error) {
            

            if (error) {
               completion(error);
               [weakSelf.operationMgr runNextOperation];
               return;
            }

            // merge local and remote changes

            [weakSelf mergeChanges];

            // notify the client of remote changes

            [weakSelf notifyChanges];

            // save all local changes

            [weakSelf saveLocalChangesInBackgroundWithBlock: ^(NSError *error, BOOL didSave) {
               
               // clean up
               
               [weakSelf cleanupAfterSyncWithError:error];
               
               // if anything was written to the database, issue a push notification to all other clients so that
               // they can download the changes. This is faster and more effective than polling.
               
               if (didSave)
                   [weakSelf.clientMgr sendSyncPushNotification];
               
               if (error) {
                   completion(error);
                   [weakSelf.operationMgr runNextOperation];
                   return;
               }
               

               // update the last sync time, but move the clock a little earlier for safety
               
               weakSelf.lastSync = [date dateByAddingTimeInterval:-20.0];
               
               // we're done. invoke the completion block and then any pending block.
               
               completion(nil);

               [weakSelf.operationMgr runNextOperation];
            }];
        }];
    }];
}

// update the local cache

- (void)saveToDisk
{
    NSURL               *url;
    NSString            *path;
    NSDictionary        *rootObject;
    
    // all we have to do is to create an archive of a simple dictionary containing the object collection and last sync time
    // the entire object graph will be saved. All other registry structures can be regenerated.
    
    url = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    path = [NSString pathWithComponents:@[[url path], @"/", kSLCacheFileName]];
    
    rootObject = @{kSLObjectRegistryClientMgrKey: self.clientMgr,
                   kSLObjectRegistryTransactionMgrKey: self.transactionMgr,
                   kSLObjectRegistryLastSyncKey: self.lastSync,
                   kSLObjectRegistryObjectsKey : self.objects};
    
    [NSKeyedArchiver archiveRootObject:rootObject toFile:path];
}

// retrieve the local cache

- (void)loadFromDisk
{
    NSURL               *url;
    NSString            *path;
    NSDictionary        *rootObject;
    
    // extract the objects from the local cache, if available
    // first, generate the cache file path
    
    url = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    path = [NSString pathWithComponents:@[[url path], @"/", kSLCacheFileName]];
    
    // attempt to decode the archive (device cache)
    
    rootObject = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    
    
    if (rootObject) {
        
        NSMutableSet            *notifiedObjects;
        NSArray                 *orderedObjects;
        NSMutableOrderedSet     *notifiedObservers;
        
        // that was successful
        // update the rest of the object registry structures
        
        self.clientMgr = rootObject[kSLObjectRegistryClientMgrKey];
        self.transactionMgr = rootObject[kSLObjectRegistryTransactionMgrKey];
        self.objects = rootObject[kSLObjectRegistryObjectsKey];
        assert(self.objects);
        self.lastSync = rootObject[kSLObjectRegistryLastSyncKey];
        
        for(SLObject *object in self.objects) {
            
            if (object.deleted) {
                [self.locallyDeletedObjects addObject:object];
                continue;
            }
            if (!object.objectID) {
                [self.locallyCreatedObjects addObject:object];
                continue;
            }
            if ([object.localChanges count] > 0) {
                [self.locallyModifiedObjects addObject:object];
                continue;
            }
        }
        
        for(SLObject *object in self.objects)
            if (object.objectID)
                [self.objectIDMap setObject:object forKey:object.objectID];
        
        for(SLObject *object in self.locallyModifiedObjects)
            [self.locallyModifiedObjectIDMap setObject:object forKey:object.objectID];
        for(SLObject *object in self.locallyDeletedObjects)
            [self.locallyDeletedObjectIDMap setObject:object forKey:object.objectID];
        
        // notify of object creations
        
        notifiedObjects = [NSMutableSet set];
        for(SLObject *object in self.objects)
            if (!object.deleted && self.registeredClasses[object.className])
                [notifiedObjects addObject:object];
        
        notifiedObservers = [NSMutableOrderedSet orderedSet];
        for(SLObject *object in notifiedObjects) {
            NSArray         *observers;
            
            observers = self.observers[object.className];
            [notifiedObservers addObjectsFromArray:observers];
        }

        orderedObjects = [self orderObjectsByAncestry:notifiedObjects increasing:TRUE];
        
        // notify the beginning of change notifications
        
        [self notifyObserversWillChangeObjects:[notifiedObservers array]];
        
        // notify of object creations
        
        for(SLObject *object in orderedObjects)
            [self notifyObserversDidCreateObject:object remote:FALSE];
                
        // notify the end of change notifications
        
        [self notifyObserversDidChangeObjects:[notifiedObservers array]];
    }
}

- (void)startSyncingTimer
{
    // this initiates an asynchronous (non-blocking) call to sync

    [self timerFireMethod:nil];

}

- (void)stopSyncingTimer
{
    [self.timer invalidate];
    self.timer = nil;
}


// schedule a call to sync (called after a change to the dataset)
// the call is scheduled with a lag to allow for a batch of changes to complete before the sync.

- (void)scheduleSync
{
    // if the client isn't in the syncing mode, there's nothing to do
    
    if (!self.clientMgr.syncing)
        return;
    
    // schedule the next sync operation, after invalidating any pending sync timer
    
    if (self.timer)
        [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.syncLag
                                                target:self
                                                selector:@selector(timerFireMethod:)
                                                userInfo:nil
                                                repeats:FALSE];
}


- (void)insertObject:(SLObject *)object
{
    // insert the object in the registry
    
    [self.objects addObject:object];
    
    if (object.objectID) {
        
        // add the object to the object index

        [self.objectIDMap setObject:object forKey:object.objectID];

    } else {
        
        // add the object to the created object list
    
        [self.locallyCreatedObjects addObject:object];
    }
}

- (void)removeAllObjects
{
    [self.objects removeAllObjects];
    [self.objectIDMap removeAllObjects];
    [self.locallyModifiedObjects removeAllObjects];
    [self.locallyModifiedObjectIDMap removeAllObjects];
    [self.locallyCreatedObjects removeAllObjects];
    [self.locallyDeletedObjects removeAllObjects];
    [self.locallyDeletedObjectIDMap removeAllObjects];
    [self.remotelyModifiedObjects removeAllObjects];
    [self.remotelyCreatedObjects removeAllObjects];
    [self.remotelyDeletedObjects removeAllObjects];
}

- (void)markObjectDeleted:(SLObject *)object
{
    // forget any uncommitted values
    
    [self.uncommittedValues removeObjectForKey:object];
    
    if (object.objectID) {
        
        // the object has been synced with the database
        // we discard any pending changes to the object and remove it from the locally modified list if it was there
        
        [self.locallyModifiedObjects removeObject:object];
        [self.locallyModifiedObjectIDMap removeObjectForKey:object.objectID];
        
        // we add the object to the locally deleted list
        
        [self.locallyDeletedObjects addObject:object];
        [self.locallyDeletedObjectIDMap setObject:object forKey:object.objectID];
        
        // if syncing mode is enable, we schedule a sync
        // the deletion will be committed to the cloud on the next sync
        // once the sync has completed, the object will be removed from the registry.
        // at that point the registry will hold no more strong reference to the object.
        
        [self scheduleSync];
        
    } else {
        
        // the object is new and hasn't been synced to the database yet
        // we discard it from the locally created list
        
        [self.locallyCreatedObjects removeObject:object];
        
        // we also discard it from the object registry. this is the last strong reference
        // the registry holds to the object.
        
        [self.objects removeObject:object];
    }
}

- (void)markObjectModified:(SLObject *)object local:(BOOL)local
{
    if (local) {
        [self.locallyModifiedObjects addObject:object];
        [self.locallyModifiedObjectIDMap setObject:object forKey:object.objectID];

    } else
        [self.remotelyModifiedObjects addObject:object];
}

- (void)markObjectUnmodified:(SLObject *)object local:(BOOL)local
{
    if (local) {
        [self.locallyModifiedObjects removeObject:object];
        [self.locallyModifiedObjectIDMap removeObjectForKey:object.objectID];
    } else
        [self.remotelyModifiedObjects removeObject:object];
}

- (void)addRemoteChange:(SLChange *)change
{
    assert(!change.local && !change.issuingTransaction);
    [self.remoteChanges addObject:change];
}

- (void)removeRemoteChange:(SLChange *)change
{
    assert([self.remoteChanges containsObject:change]);
    [self.remoteChanges removeObject:change];
}

- (id)uncommittedValueForObject:(SLObject *)object key:(NSString *)key
{
    NSDictionary    *uncommittedValues;
    
    uncommittedValues = [self.uncommittedValues objectForKey:object];
    return uncommittedValues[key];
}

- (void)setUncommittedValue:(id)value forObject:(SLObject *)object key:(NSString *)key
{
    NSMutableDictionary     *uncommittedValues;
    
    uncommittedValues = [self.uncommittedValues objectForKey:object];
    if (!uncommittedValues) {
        uncommittedValues = [NSMutableDictionary dictionary];
        assert(uncommittedValues);
        [self.uncommittedValues setObject:uncommittedValues forKey:object];
    }
    uncommittedValues[key] = value;
}

- (void)clearUncommittedValues
{
    [self.uncommittedValues removeAllObjects];
}

- (BOOL)inNotification
{
    return (self.notificationNestingLevel > 0);
}

- (NSArray *)classNames
{
    return [self.registeredClasses allKeys];
}

- (SLObject *)objectForID:(NSString *)objectID
{
    return [self.objectIDMap objectForKey:objectID];
}

- (NSArray *)observersForClassWithName:(NSString *)className
{
    return self.observers[className];
}

- (Class)classForRegisteredClassWithName:(NSString *)className
{
    return self.registeredClasses[className];
}

- (NSArray *)cloudPersistedPropertiesForClassWithName:(NSString *)className
{
    return self.cloudPersistedProperties[className];
}

- (NSArray *)localPersistedPropertiesForClassWithName:(NSString *)className
{
    return self.localPersistedProperties[className];
}

- (NSArray *)localTransientPropertiesForClassWithName:(NSString *)className
{
    return self.localTransientProperties[className];
}

// notify the beginning of change notifications

- (void)notifyObserversWillChangeObjects:(NSArray *)observers
{
    for(NSObject<SLObjectObserving> *observer in observers) {
        
        if ([observer respondsToSelector:@selector(willChangeObjects)]) {
            
            NSInteger       nestingLevel;
            
            // handle the following case of reentrant notifications: if an (local or remote) object creation
            // notification observer modifies one of the attributes of the created object or deletes the
            // created object, the (local) modification or deletion cannot be notified to observers that have
            // not been informed of the object creation yet. see comment in
            // [SLObject objectFromExistingWithClassName:objectID:] and in [SLObjectRegistry notifyChanges]
            
            nestingLevel = [[self.observerNotified objectForKey:observer] integerValue];
            nestingLevel++;
            [self.observerNotified setObject:@(nestingLevel) forKey:observer];
            if (nestingLevel > 1)
                continue;
            
            self.notificationNestingLevel++;
            
            [observer willChangeObjects];
            
            self.notificationNestingLevel--;
        }
    }
}

// notify the end of change notifications

- (void)notifyObserversDidChangeObjects:(NSArray *)observers
{
    for(NSObject<SLObjectObserving> *observer in observers) {
        
        if ([observer respondsToSelector:@selector(didChangeObjects)]) {
            
            NSInteger       nestingLevel;
            
            // handle the following case of reentrant notifications: if an (local or remote) object creation
            // notification observer modifies one of the attributes of the created object or deletes the
            // created object, the (local) modification or deletion cannot be notified to observers that have
            // not been informed of the object creation yet. see comment in
            // [SLObject objectFromExistingWithClassName:objectID:] and in [SLObjectRegistry notifyChanges]
            
            nestingLevel = [[self.observerNotified objectForKey:observer] integerValue];
            assert(nestingLevel > 0);
            nestingLevel--;
            if (nestingLevel > 0) {
                [self.observerNotified setObject:@(nestingLevel) forKey:observer];
                continue;
            }
            [self.observerNotified removeObjectForKey:observer];
            
            self.notificationNestingLevel++;

            [observer didChangeObjects];
            
            self.notificationNestingLevel--;
        }
    }
}

// notify of the object deletion (observers notified in reverse order of registration)

- (void)notifyObserversWillDeleteObject:(SLObject *)object remote:(BOOL)remote
{
    NSArray     *observers;
    BOOL        found;
    
    observers = self.observers[object.className];
    found = FALSE;
    for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
        
        // handle the following case of reentrant notifications: if an (local or remote) object creation
        // notification observer modifies one of the attributes of the created object or deletes the
        // created object, the (local) modification or deletion cannot be notified to observers that have
        // not been informed of the object creation yet. see comment in
        // [SLObject objectFromExistingWithClassName:objectID:] and in [SLObjectRegistry notifyChanges]
        
        if (!remote && !found && object.lastObserverNotified && (observer != object.lastObserverNotified))
            continue;
        found = TRUE;
        
        // the object has already marked for deletion, so it can be deleted from within the notification
        // handler. therefore no need to check for that situation.
        
        if ([observer respondsToSelector:@selector(willDeleteObject:remotely:)]) {
            self.notificationNestingLevel++;
            [observer willDeleteObject:object remotely:remote];
            self.notificationNestingLevel--;
        }
    }
}

// notify of the object creation (observers notified in order of registration)

- (void)notifyObserversDidCreateObject:(SLObject *)object remote:(BOOL)remote
{
    for(id<SLObjectObserving> observer in self.observers[object.className]) {
        
        // if the object has been deleted by an observer, no further notification to send
        
        if (!object.operable)
            break;
        
        // keep track of the last observer notified of the object creation, so that reentrant
        // object operations (i.e. setting an attribute or deleting the object inside the creation
        // notification handler) do not reveal the object to observers that have not been notified
        // of its creation yet
        
        object.lastObserverNotified = observer;
        
        if ([observer respondsToSelector:@selector(didCreateObject:remotely:)]) {
            self.notificationNestingLevel++;
            [observer didCreateObject:object remotely:remote];
            self.notificationNestingLevel--;
        }
    }
    object.lastObserverNotified = nil;
}

- (void)notifyObserver:(id<SLObjectObserving>)observer didCreateObject:(SLObject *)object remote:(BOOL)remote
{
    if ([observer respondsToSelector:@selector(didCreateObject:remotely:)]) {
        self.notificationNestingLevel++;
        [observer didCreateObject:object remotely:remote];
        self.notificationNestingLevel--;
    }
}

- (void)notifyObserversWillChangeObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue remote:(BOOL)remote
{
    NSArray     *observers;
    BOOL        found;
    
    // if the value hasn't changed, we don't need to notify the observers
    
    if (oldValue == newValue)
        return;
    
    observers = self.observers[object.className];
    found = FALSE;
    for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
        
        // handle the following case of reentrant notifications: if an object creation notification observer
        // modifies one of the attributes of the created object or deletes the created object, the modification
        // or deletion cannot be notified to observers that have not been informed of the object creation yet.
        // see comment in [SLObject objectFromExistingWithClassName:objectID:] and in
        // [SLObjectRegistry notifyChanges]
        
        if (!remote && !found && object.lastObserverNotified && (observer != object.lastObserverNotified))
            continue;
        found = TRUE;
        
        // if the object has been deleted by an observer, no further notification to send
        
        if (!object.operable)
            break;
        
        if ([observer respondsToSelector:@selector(willChangeObjectValue:forKey:oldValue:newValue:remotely:)]) {
            self.notificationNestingLevel++;
            [observer willChangeObjectValue:object forKey:key oldValue:oldValue newValue:newValue remotely:remote];
            self.notificationNestingLevel--;
        }
    }
}

- (void)notifyObserversDidChangeObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue remote:(BOOL)remote
{
    // if the value hasn't changed, we don't need to notify the observers
    
    if (oldValue == newValue)
        return;
    
    for(NSObject<SLObjectObserving> *observer in self.observers[object.className]) {
        
        // if the object has been deleted by an observer, no further notification to send
        
        if (!object.operable)
            break;
        
        if ([observer respondsToSelector:@selector(didChangeObjectValue:forKey:oldValue:newValue:remotely:)]) {
            self.notificationNestingLevel++;
            [observer didChangeObjectValue:object forKey:key oldValue:oldValue newValue:newValue remotely:remote];
            self.notificationNestingLevel--;
        }
        
        // handle the following case of reentrant notifications: if an object creation notification observer
        // modifies one of the attributes of the created object or deletes the created object, the modification
        // or deletion cannot be notified to observers that have not been informed of the object creation yet.
        // see comment in [SLObject objectFromExistingWithClassName:objectID:] and in
        // [SLObjectRegistry notifyChanges]
        
        if (observer == object.lastObserverNotified)
            break;
    }
}

- (void)notifyObserversWillResetObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue
{
    NSArray     *observers;
    
    // if the value hasn't changed, we don't need to notify the observers
    
    if (oldValue == newValue)
        return;
    
    observers = self.observers[object.className];
    for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
        
        // if the object has been deleted by an observer, no further notification to send
        
        if (!object.operable)
            break;
        
        if ([observer respondsToSelector:@selector(willResetObjectValue:forKey:oldValue:newValue:)]) {
            self.notificationNestingLevel++;
            [observer willResetObjectValue:object forKey:key oldValue:oldValue newValue:newValue];
            self.notificationNestingLevel--;
        }
    }
}

- (void)notifyObserversDidResetObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue
{
    // if the value hasn't changed, we don't need to notify the observers
    
    if (oldValue == newValue)
        return;
    
    for(NSObject<SLObjectObserving> *observer in self.observers[object.className]) {
        
        // if the object has been deleted by an observer, no further notification to send
        
        if (!object.operable)
            break;
        
        if ([observer respondsToSelector:@selector(didResetObjectValue:forKey:oldValue:newValue:)]) {
            self.notificationNestingLevel++;
            [observer didResetObjectValue:object forKey:key oldValue:oldValue newValue:newValue];
            self.notificationNestingLevel--;
        }
    }
}

#pragma mark - Private methods

#pragma mark Initializers

// class static initializer

+ (void)initialize
{
    kPFObjectSystemKeys = [NSSet setWithArray:@[kPFObjectDeleteFlagKey,
                                                kPFObjectLastModifiedKey,
                                                @"objectId",
                                                @"createdAt",
                                                @"ACL"]];
}


// instance initialization method

- (id)init
{
    self = [super init];
    if (!self)
        return nil;
    _objects = [NSMutableSet set];
    if (!_objects)
        return nil;
    _objectIDMap = [NSMutableDictionary dictionary];
    if (!_objectIDMap)
        return nil;
    
    _downloadedObjects = [NSMutableArray array];
    if (!_downloadedObjects)
        return nil;
    _downloadedObjectIDMap = [NSMutableDictionary dictionary];
    if (!_downloadedObjectIDMap)
        return nil;

    _locallyModifiedObjects = [NSMutableSet set];
    if (!_locallyModifiedObjects)
        return nil;
    _locallyModifiedObjectIDMap = [NSMutableDictionary dictionary];
    if (!_locallyModifiedObjectIDMap)
        return nil;
    
    _locallyCreatedObjects = [NSMutableSet set];
    if (!_locallyCreatedObjects)
        return nil;

    _locallyDeletedObjects = [NSMutableSet set];
    if (!_locallyDeletedObjects)
        return nil;
    _locallyDeletedObjectIDMap = [NSMutableDictionary dictionary];
    if (!_locallyDeletedObjectIDMap)
        return nil;

    _uncommittedValues = [NSMapTable strongToStrongObjectsMapTable];
    if (!_uncommittedValues)
        return nil;
    
    _savedLocallyModifiedObjects = nil;
    _savedLocallyModifiedObjectIDMap = nil;
    _savedLocallyCreatedObjects = nil;
    _savedLocallyDeletedObjects = nil;
    _savedLocallyDeletedObjectIDMap = nil;
    
    _remotelyModifiedObjects = [NSMutableSet set];
    if (!_remotelyModifiedObjects)
        return nil;
    _remotelyCreatedObjects = [NSMutableSet set];
    if (!_remotelyCreatedObjects)
        return nil;
    _remotelyDeletedObjects = [NSMutableSet set];
    if (!_remotelyDeletedObjects)
        return nil;
    
    _remoteChanges = [NSMutableOrderedSet orderedSet];
    if (!_remoteChanges)
        return nil;
    _voidedChanges = nil;
    _confirmedChanges = nil;

    _registeredClasses = [NSMutableDictionary dictionary];
    if (!_registeredClasses)
        return nil;
    
    _observers = [NSMutableDictionary dictionary];
    if (!_observers)
        return nil;
    
    _notificationNestingLevel = 0;

    _observerNotified = [NSMapTable strongToStrongObjectsMapTable];
    if (!_observerNotified)
        return nil;
    
    _cloudPersistedProperties = [NSMutableDictionary dictionary];
    if (!_cloudPersistedProperties)
        return nil;
    
    _localPersistedProperties = [NSMutableDictionary dictionary];
    if (!_localPersistedProperties)
        return nil;

    _localTransientProperties = [NSMutableDictionary dictionary];
    if (!_localTransientProperties)
        return nil;
    
    _operationMgr = [SLOperationManager sharedOperationManager];
    
    _clientMgr = [SLClientManager sharedClientManager];
    
    _transactionMgr = [SLTransactionManager sharedTransactionManager];
    
    _lastSync = [NSDate distantPast];
    if (!_lastSync)
        return nil;
    _timer = nil;
    _syncInterval = kSLDefaultSyncInterval;
    _syncLag = kSLDefaultSyncLag;
    
    return self;
}



#pragma mark Sync helper methods

// cleanupAfterSyncWithError is called to clean up all temporary structures and complete object deletions when
// synching is complete. Handling varies depending on whether sync successfully uploaded the local changes to
// the database

- (void)cleanupAfterSyncWithError:(NSError *)error
{
    // remove the locally deleted objects from the registry
    // this triggers their eventual disposal
    // don't do this in case of an error during saving as the changes would get lost otherwise.
    
    if (!error)
        for(SLObject *object in self.savedLocallyDeletedObjects) {
            [self.objects removeObject:object];
            [self.objectIDMap removeObjectForKey:object.objectID];
        }

    // remove the remotely deleted objects from the registry
    // this triggers their eventual disposal
    
    for(SLObject *object in self.remotelyDeletedObjects)
        [object completeDeletion];

    if (error) {
        
        // in case of error, the local changes need to be preserved so that they may
        // be saved to the cloud or stored in the cache later.
        // remote changes don't need to be saved as they've been already processed
        // there can't be any confirmed transaction change, as we didn't have a successful
        // server connection
        
        for(SLObject *object in self.savedLocallyModifiedObjects)
            [object doneWithSavedLocalChanges:TRUE];

        [self.locallyModifiedObjects unionSet:self.savedLocallyModifiedObjects];
        [self.locallyDeletedObjects unionSet:self.savedLocallyDeletedObjects];
        [self.locallyCreatedObjects unionSet:self.savedLocallyCreatedObjects];
        for (id key in self.savedLocallyModifiedObjectIDMap) {
            SLObject    *object;
            object = [self.savedLocallyModifiedObjectIDMap objectForKey:key];
            [self.locallyModifiedObjectIDMap setObject:object forKey:key];
        }
        for (id key in self.savedLocallyDeletedObjectIDMap) {
            SLObject    *object;
            object = [self.savedLocallyDeletedObjectIDMap objectForKey:key];
            [self.locallyDeletedObjectIDMap setObject:object forKey:key];
        }

    } else {
    
        // if no error, dispose of the saved local change dictionary for all locally
        // modified objects
        
        for(SLObject *object in self.savedLocallyModifiedObjects)
            [object doneWithSavedLocalChanges:FALSE];
    }

    // remote changes, voided and confirmed changes can safely be forgotten now
    
    [self.remoteChanges removeAllObjects];
    self.voidedChanges = nil;
    self.confirmedChanges = nil;

    // dispose of the remote change dictionary for all remotely modified objects

    for(SLObject *object in self.remotelyModifiedObjects)
        [object removeAllRemoteChanges];

    self.savedLocallyModifiedObjects = nil;
    self.savedLocallyModifiedObjectIDMap = nil;
    self.savedLocallyCreatedObjects = nil;
    self.savedLocallyDeletedObjects = nil;
    self.savedLocallyDeletedObjectIDMap = nil;
    
    [self.remotelyDeletedObjects removeAllObjects];
    [self.remotelyCreatedObjects removeAllObjects];
    [self.remotelyModifiedObjects removeAllObjects];
    [self.downloadedObjects removeAllObjects];
    [self.downloadedObjectIDMap removeAllObjects];
}


// calculateDepth recursively explores the object graph and assign a depth level to each object reached

static NSUInteger calculateDepth(SLObject *object, NSUInteger depth, NSMutableArray *objectLevels)
{
    NSUInteger      maxDepth, thisDepth;
    NSMutableArray  *objects;
    
    // if the object has already been reached, return its color index
    
    if (object.depth != 0)
        return object.depth;
    
    // asign a depth index to this object
    
    object.depth = depth;
    
    // insert the object in the ordered list
    
    if ([objectLevels count] < depth) {
        objects = [NSMutableArray array];
        assert(objects);
        [objectLevels addObject:objects];
    } else
        objects = objectLevels[depth-1];
    [objects addObject:object];
    
    // recursively explore all relations of the object
    
    maxDepth = depth;
    for(NSString *key in object.dictionaryKeys) {
        id          value;
        SLObject    *relation;
        
        value = [object dictionaryValueForKey:key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE];
        if (!value || ![SLObject isRelation:value])
            continue;
        relation = (SLObject *)value;
        thisDepth = calculateDepth(relation, depth+1, objectLevels);
        if (thisDepth > maxDepth)
            maxDepth = thisDepth;
    }
    
    // return the maximum depth index reached
    
    return maxDepth;
}


// reset resets the object color so that colorize can be called again

static void resetDepth(SLObject *object)
{
    // return if this object has already been reset
    
    if (object.depth == 0)
        return;
    
    // recursively reset this object and all its relations
    
    object.depth = 0;
    for(NSString *key in object.dictionaryKeys) {
        id          value;
        SLObject    *relation;
        
        value = [object dictionaryValueForKey:key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE];
        if (!value || ![SLObject isRelation:value])
            continue;
        relation = (SLObject *)value;
        resetDepth(relation);
    }
}


// orderObjectsByAncestry takes a list of objects and returns another list of the same objects ordered by the
// child-parent relationship. Object A is ordered before Object B if there is a relation path can be found from B
// to A but not from A to B. If a path exists in both direction, A and B are not ordered and may appear in any
// order in the list returned. If the parameter increasing is set to false, the list returned is ordered in the
// reverse order

- (NSArray *)orderObjectsByAncestry:(NSSet *)objects increasing:(BOOL)increasing
{
    NSMutableArray          *objectLevels;
    NSMutableArray          *orderedObjects;
    NSEnumerator            *enumerator;
    
    // recursively explore the object graph
    
    objectLevels = [NSMutableArray array];
    assert(objectLevels);

    for(SLObject *object in objects)
        calculateDepth(object, 1, objectLevels);

    for(SLObject *object in objects)
        resetDepth(object);
    
    // create the final sorted list
    
    orderedObjects = [NSMutableArray array];
    if (increasing)
        enumerator = [objectLevels objectEnumerator];
    else
        enumerator = [objectLevels reverseObjectEnumerator];
    
    for(NSArray *objects in enumerator)
        [orderedObjects addObjectsFromArray:objects];
    
    return orderedObjects;
}


// notifyChanges: notify the notification handlers of object changes
                                                           
- (void)notifyChanges
{
    NSMutableSet        *voidedObjects;
    NSMutableSet        *confirmedObjects;
    NSArray             *notifiedObjects;
    NSMutableSet        *allObjects;
    NSMutableSet        *notifiedObservers;
    
    // The first step is to save and reset the locally modified object lists and
    // object local change lists so that the notification handlers can safely alter object state (changes initiated by notification
    // handlers won't be synced until the next sync)
    
    for(SLObject *object in [self.locallyModifiedObjects setByAddingObjectsFromSet:self.remotelyModifiedObjects]) {
        [object saveLocalChanges];
    }

    self.savedLocallyModifiedObjects = self.locallyModifiedObjects;
    self.savedLocallyModifiedObjectIDMap = self.locallyModifiedObjectIDMap;
    self.savedLocallyCreatedObjects = self.locallyCreatedObjects;
    self.savedLocallyDeletedObjects = self.locallyDeletedObjects;
    self.savedLocallyDeletedObjectIDMap = self.locallyDeletedObjectIDMap;
    self.locallyModifiedObjects = [NSMutableSet set];
    self.locallyModifiedObjectIDMap = [NSMutableDictionary dictionary];
    self.locallyCreatedObjects = [NSMutableSet set];
    self.locallyDeletedObjects = [NSMutableSet set];
    self.locallyDeletedObjectIDMap = [NSMutableDictionary dictionary];
    
    // Notifications are grouped by type and are sent in that order:
    // 1- remote object deletions
    //      order: parent objects before their children (see below)
    // 2- remote object creations
    //      order: children objects before their parents (see below)
    // 3- voided transaction object modifications
    //      order: reverse chronological
    // 3- confirmed transaction object modifications
    //      order: chronological
    // 4- remote object modifications
    //      order: chronological
    
    // Notifications of object creations and deletions are sent in the following order:
    // - object creation: if a newly created object A has a relation attribute that points to another newly created
    //      object B, the creation of B is notified before the creation of A. However the order of notification is
    //      undetermined if B points back to A, directly or indirectly through other objects.
    // - object deletion: if a deleted object A has a relation attribute that point to another deleted object B, the
    //      deletion of A is notified before the deletion of B. However the order of notification is undetermined if
    //      B points back to A, directly or indirectly through other objects.
    //
    // If 2 or more observers register to be notified of changes to the same subclass, they are notified in the same
    // order they registered for the following notification types:
    // - remote object creation
    // - before remote object modification
    // - before confirmed transaction object modification
    // - after voided transaction object modification
    // Observers are notifified in the opposite order they registered for the following notification types:
    // - remote object deletion
    // - after remote object modification
    // - after confirmed transaction object modification
    // - before voided transaction object modification
    
    // determine the list of all notified observers
    // for this, we first build the list of all notified objects
    
    voidedObjects = [NSMutableSet set];
    assert(voidedObjects);
    for(SLChange *change in self.voidedChanges)
        [voidedObjects addObject:change.object];
    
    confirmedObjects = [NSMutableSet set];
    assert(confirmedObjects);
    for(SLChange *change in self.confirmedChanges)
        [confirmedObjects addObject:change.object];
    
    allObjects = [self.remotelyDeletedObjects mutableCopy];
    assert(allObjects);
    [allObjects unionSet:self.remotelyCreatedObjects];
    [allObjects unionSet:voidedObjects];
    [allObjects unionSet:confirmedObjects];
    [allObjects unionSet:self.remotelyModifiedObjects];
    
    // then we gather the registered observers for the notified objects
    
    notifiedObservers = [NSMutableSet set];
    assert(notifiedObservers);
    
    for(SLObject *object in allObjects) {
        NSArray         *observers;
        
        observers = self.observers[object.className];
        [notifiedObservers addObjectsFromArray:observers];
    }
    
    // notify the beginning of change notifications (observers notified in undetermined order)
    
    [self notifyObserversWillChangeObjects:[notifiedObservers allObjects]];
  
    // notify object deletions
    // - objects ordered by parent-child relationship, parents first
    // - for each object, observers notified in reverse order of registration
    
    notifiedObjects = [self orderObjectsByAncestry:self.remotelyDeletedObjects increasing:FALSE];
    for(SLObject *object in notifiedObjects)
        [self notifyObserversWillDeleteObject:object remote:TRUE];

    // notify of object creations
    // - objects ordered by parent-child relationship, children first
    // - for each object, observers notified in order of registration
    
    notifiedObjects = [self orderObjectsByAncestry:self.remotelyCreatedObjects increasing:TRUE];
    for(SLObject *object in notifiedObjects)
        [self notifyObserversDidCreateObject:object remote:TRUE];

    // notify of voided transaction object modifications
    // - changes ordered in reverse chronological order, most recent first
    // - for each object, observers notified in order of registration
    
    for(SLChange *change in self.voidedChanges) {
        
        assert([change.object dictionaryValueForKey:change.key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE] == change.nValue);

        // notify before the change
        
        [self notifyObserversWillResetObjectValue:change.object forKey:change.key oldValue:change.nValue newValue:change.oValue];
        
        // update the value dictionary
        
        [change.object setDictionaryValue:change.oValue forKey:change.key speculative:FALSE change:nil];

        // notify after the change
        
        [self notifyObserversDidResetObjectValue:change.object forKey:change.key oldValue:change.nValue newValue:change.oValue];
    }
    
    // notify of confirmed transaction object modifications
    // - changes ordered in  chronological order, oldest first
    // - for each object, observers notified in order of registration

    for(SLChange *change in self.confirmedChanges) {
        
        assert([change.object dictionaryValueForKey:change.key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE] == change.oValue);

        // notify before the change
        
        [self notifyObserversWillChangeObjectValue:change.object forKey:change.key oldValue:change.oValue newValue:change.nValue remote:FALSE];
        
        // update the value dictionary
        
        [change.object setDictionaryValue:change.nValue forKey:change.key speculative:FALSE change:nil];
        
        // notify after the change
        
        [self notifyObserversDidChangeObjectValue:change.object forKey:change.key oldValue:change.oValue newValue:change.nValue remote:FALSE];
    }
    
    // notify of remote object modifications
    // - changes ordered in chronological order, oldest first
    // - for each object, observers notified in order of registration

    for(SLChange *change in [self.remoteChanges copy]) {
        
        // make sure the remote change is still current (hasn't been canceled by a notification handler)

        if (![self.remoteChanges containsObject:change])
            continue;
        
        assert([change.object dictionaryValueForKey:change.key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE] == change.oValue);
        
        // notify before the change
        
        [self notifyObserversWillChangeObjectValue:change.object forKey:change.key oldValue:change.oValue newValue:change.nValue remote:TRUE];
        
        // update the value dictionary
        
        [change.object setDictionaryValue:change.nValue forKey:change.key speculative:FALSE change:nil];

        // notify after the change
        
        [self notifyObserversDidChangeObjectValue:change.object forKey:change.key oldValue:change.oValue newValue:change.nValue remote:TRUE];
    }

    // notify the end of change notifications (observers notified in undetermined order)
    
    [self notifyObserversDidChangeObjects:[notifiedObservers allObjects]];
}


// identifyRemotelyDeletedObjects builds a list of objects that have been deleted remotely

- (void)identifyRemotelyDeletedObjects
{
    // walk through all recently changed database objects
    
    for(PFObject *dbObject in self.downloadedObjects) {
        
        SLObject    *object;
        
        // look up the object in the registry
        // skip if the object is a zombie (previously deleted), or being locally deleted
        
        object = [self.objectIDMap objectForKey:dbObject.objectId];
        if (!object || object.deleted)
            continue;
        
        // the object is in the registry and it is not being locally deleted
        // check if the database object has the delete attribute set
        
        if ([dbObject objectForKey:kPFObjectDeleteFlagKey]) {
            
            // the delete attribute is set. the object is being remotely deleted
            
            // add the object to the list of remotely deleted objects so that it can
            // be deleted and notified later
            
            [self.remotelyDeletedObjects addObject:object];
            
            // initiate the object deletion cycle
            
            [object startDeletion];
            
            // handle the transactions for the remotely deleted object.
            // this has to be done here rather than later because we need
            // all transactions either voided or confirmed before we
            // start notifications
            
            [object handleTransactionsForDeletedObject:FALSE];
        }
    }
}


// identifyRemotelyCreatedObjects builds a list of objects that have been created remotely

- (void)identifyRemotelyCreatedObjects
{
    // walk through all recently changed database objects
    
    for(PFObject *dbObject in self.downloadedObjects) {
        
        SLObject    *object;
        
        // look up the object in the registry
        // skip if the object is known
        
        object = [self.objectIDMap objectForKey:dbObject.objectId];
        if (object)
            continue;
        
        // the object is unknown
        // skip if the object is a zombie (database object is marked for deletion)
        
        if ([dbObject objectForKey:kPFObjectDeleteFlagKey])
            continue;
        
        // this object is unknown and isn't marked for deletion
        // therefore it is a remotely created object
        
        
        // construct a local representation of the database object
        object = [SLObject objectFromExistingWithClassName:dbObject.parseClassName objectID:dbObject.objectId];
        
        [self.remotelyCreatedObjects addObject:object];
    }
    
    // all remotely created objects have been created and registered
    // we can now complete their construction
    
    for(SLObject *object in self.remotelyCreatedObjects) {
        PFObject                *dbObject;
        NSMutableDictionary     *dbDictionary;
        NSArray                 *keys;
        
        // the dictionary has to be manually built as Parse is missing a convenient dictionary method
        
        dbObject = [self.downloadedObjectIDMap objectForKey:object.objectID];
        dbDictionary = [NSMutableDictionary dictionary];
        keys = [dbObject allKeys];
        for (NSString *key in keys) {
            if ([kPFObjectSystemKeys containsObject:key])
                continue;
            dbDictionary[key] = [dbObject objectForKey:key];
        }

        // populateWithDictionary will capture the value dictionary, convert any relation, update references, etc.
        
        [object populateWithDictionary:dbDictionary];
    }
}


// identifyRemotelyModifiedObjects creates a list of objects whose attributes have been modified remotely

- (void)identifyRemotelyModifiedObjects
{
    // walk through all objects that have been recently modified
    
    for(PFObject *dbObject in self.downloadedObjects) {
        
        SLObject           *object;

        object = [self.objectIDMap objectForKey:dbObject.objectId];
        
        // skip if the object is a zombie
        
        if (!object)
            continue;
        
        // skip if the object is being remotely created
        
        if ([self.remotelyCreatedObjects containsObject:object])
            continue;
        
        // skip if the object is being locally or remotely deleted
        
        if (object.deleted)
            continue;
        if ([dbObject objectForKey:kPFObjectDeleteFlagKey])
            continue;
        
        // the database object may have been remotely modified
        // go over all the object values and see if any has changed
        
        for (NSString *key in [dbObject allKeys]) {
            
            id              remoteValue;
            id              localValue;
            SLChange        *change;
            NSDate          *dbObjectModifiedTime;
            BOOL            equal;
            
            if ([kPFObjectSystemKeys containsObject:key])
                continue;

            localValue = [object dictionaryValueForKey:key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE];
            remoteValue = [object databaseToDictionaryValue:[dbObject objectForKey:key]];
            
            // compare the values
            // in the case of relations, pointers can be compared because object instances are unique
            // in the case of simple attributes, use the isEqual method
            
            if (!localValue || [SLObject isRelation:localValue])
                equal = (remoteValue == localValue);
            else
                equal = [localValue isEqual:remoteValue];
            
            if (!equal) {
                
                // the value was remotely changed.
                // check if this conflicts with a local change
                
                change = object.localChanges[key];
                
                // no local change is found for this key, log the remote change.
                
                if (!change) {
                    [SLChange remoteChangeWithObject:object key:key oldValue:localValue newValue:remoteValue timeStamp:dbObjectModifiedTime];
                    [object voidTransactionsCapturingKey:key];
                    continue;
                }
                
                // a local change was found for this key. we have a conflict to resolve.
                
                dbObjectModifiedTime = [dbObject objectForKey:kPFObjectLastModifiedKey];
                
                // keep the most recent change
                
                if ([change compareTimeStampToDate:dbObjectModifiedTime] == NSOrderedAscending) {
                    
                    // the remote change is more recent. forego the local change and log the remote change
                    // the change object is modified in place to reflect the change.
                    
                    [change detach];
                    [SLChange remoteChangeWithObject:object key:key oldValue:localValue newValue:remoteValue timeStamp:dbObjectModifiedTime];
                    [object voidTransactionsCapturingKey:key];
                    continue;
                }
                
                // the local change is more recent. nothing to do as the local change is already filed.
                continue;
            }
        }
    }
}

// finalizeUncommittedChanges determines which uncommitted changes to void and which to confirm

- (void)finalizeUncommittedChanges
{
    self.voidedChanges = [self.transactionMgr voidedChanges];
    self.confirmedChanges = [self.transactionMgr confirmedChanges];
    
    // merge remote changes with confirmed transactional changes to ensure proper ordering
    // if a remote change conflicts with a transactional change, we check the change timestamp
    // if the remote change happened after the transactional change, we keep both changes and
    // update the old value of the remote change (the remote change will be notified after the transactional change)
    // if the remote change happened before the transactional change, we drop the remote change
    
    for(SLChange *change in self.confirmedChanges) {
        
        SLObject        *object;
        NSString        *key;
        SLChange        *remoteChange;
        
        object = change.object;
        if (![self.remotelyModifiedObjects containsObject:object])
            continue;
        
        key = change.key;
        remoteChange = object.remoteChanges[key];
        if (!remoteChange)
            continue;
        
        if ([remoteChange compareTimeStamp:change] == NSOrderedDescending) {
            remoteChange.oValue = change.nValue;
        } else {
            [remoteChange detach];
        }
    }

    // all the uncommitted values that we need to keep have been committed. we can now clear the uncommitted values
    
    [self clearUncommittedValues];
}

// resolveDanglingReferencesToDeletedObjects:local: takes a list of objects that have been deleted locally or remotely
// and ensures that all references to those objects are set to nil. Any reference set to nil is properly logged and notified as needed.

- (void)resolveDanglingReferencesToDeletedObjects:(NSSet *)deletedObjects local:(BOOL)local
{
    for(SLObject *deletedObject in deletedObjects) {
        
        NSDate      *timeDeleted;

        timeDeleted = nil;

        // if this is a remotely deleted object, look for dangling references in local object values
        // (object values before remote modifications are applied)
        // this isn't needed for local object deletions, as dangling references have already been set to nil when the object was deleted.
        
        if (!local)
            for(SLObject *referencingObject in deletedObject.referencingObjects) {

                // determine the time the object was deleted if this hasn't already been done
                
                if (!timeDeleted) {
                    PFObject    *dbObject;
                    
                    dbObject = [self.downloadedObjectIDMap objectForKey:deletedObject.objectID];
                    assert(dbObject);
                    timeDeleted = [dbObject objectForKey:kPFObjectLastModifiedKey];
                    assert(timeDeleted);
                }
                
                for(NSString *key in [deletedObject referencingKeysForObject:referencingObject]) {
                    
                    // we log a remote change for the dangling reference
                    // if the dangling reference has already been remotely fixed, there's already a remote change for this and
                    //      no new change will be created
                    // if the dangling reference is the result of a local change, the local change will be dropped when the remote
                    //      change is logged
                    
                    [SLChange remoteChangeWithObject:referencingObject key:key oldValue:deletedObject newValue:nil timeStamp:timeDeleted];
                }
            }
        
        // next examine all remotely modified values (those changes have not been applied yet).
        // when resolving dangling references to remotely deleted objects, there is the possibility that the database still contains
        // references to the remotely deleted object. This may happen due to race conditions between clients, e.g. one client deleting an
        // object while another is simultaneously creating a reference to it. The inconsistency typically is transient, i.e. the client
        // that deleted the object often detects and correct the issue. However there are situations where it isn't, e.g. when the client that
        // deletes the objects catches the remote change after it has deleted the object and removed all references to it. Currently such permanent
        // inconsistencies are corrected on the fly by all clients, albeit very inefficiently. A client attempting a sync in this situation
        // may end up reloading the entire object collection (see isDownloadedGraphComplete), e.g. if the deletion and value change are not
        // caught together. References to unknown objects are set to nil when loaded in memory (see databaseToDictionaryValue:).
        // A better way to handle this would be to have clients permanently repair such database inconsistencies.
        
        for(SLObject *object in self.remotelyModifiedObjects) {
            
            // iterate over a copy of the remote change list as it is modified by the loop body
            
            for(NSString *key in [object.remoteChanges copy]) {
                SLChange        *change;
                
                change = object.remoteChanges[key];
                assert(!change.local);
                
                // if the value of the remote change points to the deleted object, we fix the dangling reference by setting it to nil
                // and updating the timestamp.
                
                if (change.nValue == deletedObject) {
                    change.nValue = nil;
                    [change updateTimeStamp];
                }
            }
        }
    }
}


// resolveDanglingReferences ensures that references to all deleted objects (local and remote) are set to nil

- (void)resolveDanglingReferences
{
    // look for dangling references to locally deleted objects
    
    [self resolveDanglingReferencesToDeletedObjects:self.locallyDeletedObjects local:TRUE];
        
    // next look for dangling references to remotely deleted objects

    [self resolveDanglingReferencesToDeletedObjects:self.remotelyDeletedObjects local:FALSE];
}


// updateDatabaseObjectCache is called before uploading any local changes to the cloud and ensures that all objects
// about to be uploaded have a PFObject (Parse database object) associated with them

- (void)updateDatabaseObjectCache
{
    // update the PFObject cache with fresh values
    
    for(PFObject *dbObject in self.downloadedObjects) {
        SLObject    *object;
        
        object = [self.objectIDMap objectForKey:dbObject.objectId];
        if (object)
            object.databaseObject = dbObject;
    }
    
    // generate PFObjects for locally modified and deleted objects that don't have one
    
    for(SLObject *object in self.locallyModifiedObjects)
        if (!object.databaseObject)
            object.databaseObject = [PFObject objectWithoutDataWithClassName:object.className objectId:object.objectID];

    for(SLObject *object in self.locallyDeletedObjects)
        if (!object.databaseObject)
            object.databaseObject = [PFObject objectWithoutDataWithClassName:object.className objectId:object.objectID];
}


// mergeChanges is called after recently changed objects are downloaded from the database, and identifies all remote changes

- (void)mergeChanges
{
    [self.transactionMgr runPendingTransactions];
    
    [self identifyRemotelyDeletedObjects];
    [self identifyRemotelyCreatedObjects];
    [self identifyRemotelyModifiedObjects];
    
    [self finalizeUncommittedChanges];
    
    [self resolveDanglingReferences];
    [self updateDatabaseObjectCache];
    
    // now that all remote changes have been identified, they can be sorted by timestamp
    
    // sort the changes in chronological order
    
    [self.remoteChanges sortUsingComparator: ^ NSComparisonResult (SLChange *changeA, SLChange *changeB) {
        return [changeA compareTimeStamp:changeB];
    }];
}


// isDownloadedGraphComplete verifies whether the graph of object that was downloaded is complete, i.e. does not contain
// reference to objects that are neither among the downloaded objects nor already instanciated in memory. When downloading
// the list of recently modified objects, it may happen that the snapshot captured is incomplete. This is remedied by downloading
// a broader set of objects.

- (BOOL)isDownloadedGraphComplete
{
    // iterate over the list of downloaded objects
    // verify that all the object relations are known
    
    for (PFObject *dbObject in self.downloadedObjects) {
        
        NSArray    *keys;
        
        keys = [dbObject allKeys];
        for (NSString *key in keys) {
            
            id         attribute;
            PFObject   *relation;
            NSString   *relationID;
            
            if ([kPFObjectSystemKeys containsObject:key])
                continue;
            
            attribute = [dbObject objectForKey:key];
            
            // check whether the attribute is a database relation
            
            if ([SLObject isDBRelation:attribute]) {
                relation = (PFObject *)attribute;
                relationID = relation.objectId;
                
                // check whether the relation object is in the object registry or in the list of downloaded objects
                // if not, the graph is incomplete
                
                if (![self.downloadedObjectIDMap objectForKey:relationID]
                            && ![self.objectIDMap objectForKey:relationID])
                    return FALSE;
            }
        }
    }
    return TRUE;
}


// downloadObjectsInBackgroundChangedSince:withClassName:completion: asynchronously downloads all objects of a given
// subclass that have changed since a set date.

- (void)downloadObjectsInBackgroundChangedSince:(NSDate*)since
                                  withClassName:(NSString *)className
                                     completion: (void(^)(NSArray *, NSError *))continuation
{
    PFQuery         *query;
    
    query = [PFQuery queryWithClassName:className];
    assert(query);
    [query whereKey:kPFObjectLastModifiedKey greaterThan:since];
    query.limit = 1000;
    
    [self.operationMgr findQueryObjectsInBackground:query waitForConnection:TRUE block:^(NSArray *array, NSError *error) {
        if (error) {
            continuation(nil, error);
            return;
        }
        continuation(array, nil);
    }];
}


// downloadObjectsInBackgroundChangedSince:trials:completion: asynchronously downloads all database objects that have changed since
// a set date. It ensures that the graph of object downloaded is complete (see isDownloadedGraphComplete)

- (void)downloadObjectsInBackgroundChangedSince:(NSDate *)since trials:(NSInteger)trials
                                     completion:(void(^)(NSError *)) continuation
{
    __weak typeof(self) weakSelf = self;

    [self.clientMgr fetchClassListInBackgroundWithBlock:^(NSError *error, NSArray *databaseClassNames){
        
        __block NSInteger   count;
        __block NSError     *downloadError;
        
        if (error) {
            continuation(error);
            return;
        }

        // each subclass has to be downloaded separately because Parse cannot handle queries with
        // results spanning multiple classes. therefore we iterate over the class names.
        // for each class, we download the list of objects modified since the last sync.
        // each download call is asynchronous. All the class downloads are fired in parallel.
        // the continuation code does a join of the download results
        
        count = [databaseClassNames count];
        
        // if no classes are registered with the database, there are no objects to download
        
        if (count == 0) {
            continuation(nil);
            return;
        }
        
        downloadError = nil;
        
        for(NSString *name in databaseClassNames) {

            [weakSelf downloadObjectsInBackgroundChangedSince:since
                                            withClassName:name
                                            completion: ^(NSArray *classObjects, NSError *error) {
                
                // this is the continuation code for the class download
                
                NSDate      *restart;
               
                count--;
              
                if (error)
                    downloadError = error;
                
                if (downloadError) {
                    if (count == 0) {
                        [weakSelf.downloadedObjects removeAllObjects];
                        [weakSelf.downloadedObjectIDMap removeAllObjects];
                        continuation(error);
                    }
                    return;
                }
                
                // join the download results
                
                [weakSelf.downloadedObjects addObjectsFromArray:classObjects];
                
                // the completion of the last batch triggers the execution of the next step
                
                if (count == 0) {

                    // create an objectID index for the downloaded objects
                    
                    for(PFObject *dbObject in self.downloadedObjects)
                        [weakSelf.downloadedObjectIDMap setObject:dbObject forKey:dbObject.objectId];
                    
                    // check the completeness of the graph of downloaded objects
                    // this is necessary because the download/joins are not atomic and may capture an
                    // incomplete graph.
                    
                    if (![weakSelf isDownloadedGraphComplete]) {
                        
                        // if the graph is incomplete, we have caught the database in an inconsistent state.
                        // a new download must be performed in order to get the latest state.
                        
                        // after 3 reload trials, download the entire database. This addresses the problem of dangling
                        // references to objects that were deleted before our sync window
                        
                        restart = since;
                        if (trials == 3)
                            restart = [NSDate distantPast];
                        assert(trials <= 3);

                        [weakSelf.downloadedObjects removeAllObjects];
                        [weakSelf.downloadedObjectIDMap removeAllObjects];

                        [weakSelf downloadObjectsInBackgroundChangedSince:restart trials:trials+1 completion:continuation];
                        return;
                    }
                    continuation(nil);
                }
            }];
        }
    }];
}

// saveDeletedObjectsInBackgroundWithBlock: does what it says. Note that deleted objects are simply
// flagged as deleted in the database, rather than actually deleted. This comes at the cost of database
// store leakage. But this greatly simplifies the propagation and handling of object deletion.
// A non-leaking implementation probably requires the collaboration from the central database store, which
// we can't have here.

- (void)saveDeletedObjectsInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion
{
    NSMutableArray      *databaseObjects;
    BOOL                willDelete;
    
    willDelete = ([self.savedLocallyDeletedObjects count] > 0);
    
    // mark the objects to be deleted
    
    databaseObjects = [NSMutableArray array];
    for(SLObject *object in self.savedLocallyDeletedObjects) {
        
        // skip if the object was deleted before it had a chance to be synced
        if (!object.databaseObject)
            continue;
        
        [databaseObjects addObject:object.databaseObject];
        object.databaseObject[kPFObjectDeleteFlagKey] = @TRUE;
    }
    
    // save the deleted objects and let the completion block know whether we changed the database
    
    [self.operationMgr savePFObjectsInBackground:databaseObjects waitForConnection:TRUE block:^(NSError *error) {
        completion(error, willDelete);
    }];
}


// saveCreatedObjectsInBackgroundWithBlock: does what it says.

- (void)saveCreatedObjectsInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion
{
    __weak typeof(self) weakSelf = self;
    NSMutableArray      *databaseObjects;
    BOOL                willSave;
    
    willSave = ([self.savedLocallyCreatedObjects count] > 0);
    
    // create the database objects and then populate them
    // this needs to be a 2 step process to properly handle relations between newly created objects
    
    databaseObjects = [NSMutableArray array];
    for(SLObject *object in self.savedLocallyCreatedObjects) {
        
        // create a blank database object
        
        object.databaseObject = [PFObject objectWithClassName:object.className];
        
        [databaseObjects addObject:object.databaseObject];
    }
    
    for(SLObject *object in self.savedLocallyCreatedObjects) {
        
        NSArray         *cloudPersistedProperties;
        
        // populate the database dictionary
        
        cloudPersistedProperties = self.cloudPersistedProperties[object.className];

        for(NSString *key in object.dictionaryKeys) {
            id      value;
            
            // capture only the cloud persisted properties
            
            if (![cloudPersistedProperties containsObject:key])
                continue;
            value = [object dictionaryToDatabaseValue:[object dictionaryValueForKey:key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE]];
            [object.databaseObject setObject:value forKey:key];
        }
    }

    // save the newly created database objects
    
    [self.operationMgr savePFObjectsInBackground:databaseObjects waitForConnection:TRUE block:^(NSError *error) {
        
        if (!error) {
            
            // retrieve the new objectID and add the object to the objectID index
            
           for(SLObject *object in weakSelf.savedLocallyCreatedObjects) {
               object.objectID = object.databaseObject.objectId;
               [weakSelf.objectIDMap setObject:object forKey:object.objectID];
            }
        }
        
        // let the completion block know whether we changed the database
        
        completion(error, willSave);
    }];
}


// saveModifiedObjectsInBackgroundWithBlock: does what it says

- (void)saveModifiedObjectsInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion
{
    NSMutableArray      *databaseObjects;
    __block BOOL        didSave;
    
    // populate an array with Parse datbase objects (PFObject) representing the locally modified objects
    
    didSave = FALSE;
    databaseObjects = [NSMutableArray array];
    for(SLObject *object in self.savedLocallyModifiedObjects) {
 
        BOOL    changedObject;
        
        // apply the local change dictionary

        changedObject = FALSE;
        for(NSString *key in object.savedLocalChanges) {
            
            SLChange    *change;
            id          value;
            
            change = object.savedLocalChanges[key];
            assert(change.local);
            value = [object dictionaryToDatabaseValue:change.nValue];
            [object.databaseObject setObject:value forKey:key];
            changedObject = TRUE;
        }
        
        if (changedObject) {
            [databaseObjects addObject:object.databaseObject];
            didSave = TRUE;
        }
    }
    
    // save the newly created database objects and let the completion block know whether we
    // modified the database
    
    [self.operationMgr savePFObjectsInBackground:databaseObjects waitForConnection:TRUE block:^(NSError *error) {
        completion(error, didSave);
    }];
}


// saveLocalChangesInBackgroundWithBlock: asynchronously uploads to the database all local changes
// (object creation, deletion, modifications)

- (void)saveLocalChangesInBackgroundWithBlock:(void(^)(NSError *, BOOL))completion
{
    __weak typeof(self) weakSelf = self;
    __block BOOL    didSave;
    
    didSave = FALSE;
    
    // Continuation Passing Style. Not pretty but effective.
    // the completion block is informed whether anything was actually uploaded
    
    [self.clientMgr saveClassListInBackgroundWithBlock: ^(NSError *error) {
        
        if (error) {
            completion(error, FALSE);
            return;
        }
        
        [weakSelf saveDeletedObjectsInBackgroundWithBlock: ^(NSError *error, BOOL saved) {
            
            didSave |= saved;
            if (error) {
                completion(error, didSave);
                return;
            }
            
            [weakSelf saveCreatedObjectsInBackgroundWithBlock: ^(NSError *error, BOOL saved) {
                
                didSave |= saved;
                if (error) {
                    completion(error, didSave);
                    return;
                }

                [weakSelf saveModifiedObjectsInBackgroundWithBlock: ^(NSError *error, BOOL saved) {
                    didSave |= saved;
                    completion(error, didSave);
                }];
            }];
        }];
    }];
}



// timerFireMethod: is the method invoked by the syncing timer. It simply fires a sync and schedule itself again.

- (void)timerFireMethod:(NSTimer *)timer
{    
    __weak typeof(self) weakSelf = self;

    self.timer = nil;
    [self syncAllInBackgroundWithBlock: ^(NSError *error) {
        if (!weakSelf.timer)
            weakSelf.timer = [NSTimer scheduledTimerWithTimeInterval:weakSelf.syncInterval
                                                            target:weakSelf
                                                            selector:@selector(timerFireMethod:)
                                                            userInfo:nil
                                                            repeats:FALSE];
    }];
}

@end