//
//  SLObjectRegistry.m
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLObjectRegistry.h"
#import "SLClientManager.h"
#import "SLObject_Private.h"
#import "SLOperationManager.h"
#import "SLChange.h"
#import "SLObjectObserving.h"
#import "BlockCondition.h"
#import <Parse/Parse.h>
#import <objc/runtime.h>



static NSString * const kPFObjectDeleteFlagKey = @"DELETED";
static NSString * const kPFObjectLastModifiedKey = @"updatedAt";

static NSSet *kPFObjectSystemKeys;

static NSString * const kSLObjectRegistryObjectsName = @"SLORObjects";
static NSString * const kSLObjectRegistryLocallyModifiedObjectsName = @"SLORLocallyModifiedObject";
static NSString * const kSLObjectRegistryLocallyCreatedObjectsName = @"SLORLocallyCreatedObjects";
static NSString * const kSLObjectRegistryLocallyDeletedObjectsName = @"SLORLocallyDeletedObjects";
static NSString * const kSLObjectRegistryLastSyncName = @"SLORLastSync";

static NSString * const kSLCacheFileName = @"SLCache";

static NSTimeInterval const kSLSyncSoonTimeInterval = 10.0;
static NSTimeInterval const kSLDefaultSyncInterval = 120.0;



#pragma mark - Private Interface

@interface SLObjectRegistry ()

@property (weak, nonatomic) SLClientManager *clientMgr;
@property (nonatomic) SLOperationManager    *operationMgr;

@property (nonatomic) NSTimeInterval        syncInterval;
@property (nonatomic) NSDate                *lastSync;
@property (nonatomic) NSTimer               *timer;

@property (nonatomic) NSMutableSet          *objects;
@property (nonatomic) NSMapTable            *objectIDMap;

@property (nonatomic) NSMutableSet          *locallyModifiedObjects;
@property (nonatomic) NSMapTable            *locallyModifiedObjectIDMap;
@property (nonatomic) NSMutableSet          *locallyCreatedObjects;
@property (nonatomic) NSMutableSet          *locallyDeletedObjects;
@property (nonatomic) NSMapTable            *locallyDeletedObjectIDMap;

@property (nonatomic) NSMutableSet          *remotelyModifiedObjects;
@property (nonatomic) NSMutableSet          *remotelyCreatedObjects;
@property (nonatomic) NSMutableSet          *remotelyDeletedObjects;

@property (nonatomic) NSMutableDictionary   *registeredClasses;
@property (nonatomic) NSMutableDictionary   *observers;

@property (nonatomic) NSMutableDictionary   *cloudPersistedProperties;
@property (nonatomic) NSMutableDictionary   *localPersistedProperties;
@property (nonatomic) NSMutableDictionary   *localTransientProperties;

// properties used by syncAllInBackground method

@property (nonatomic) NSMutableArray        *downloadedObjects;
@property (nonatomic) NSMapTable            *downloadedObjectIDMap;

@property (nonatomic) NSMutableSet          *savedLocallyModifiedObjects;
@property (nonatomic) NSMapTable            *savedLocallyModifiedObjectIDMap;
@property (nonatomic) NSMutableSet          *savedLocallyCreatedObjects;
@property (nonatomic) NSMutableSet          *savedLocallyDeletedObjects;
@property (nonatomic) NSMapTable            *savedLocallyDeletedObjectIDMap;


// factory methods

- (id)init;

// Sync helper methods

- (void)timerFireMethod:(NSTimer *)timer;
- (void)cleanupAfterSyncWithError:(NSError *)error;
- (void)identifyRemotelyDeletedObjects;
- (void)identifyRemotelyCreatedObjects;
- (void)identifyRemotelyModifiedObjects;
- (void)resolveDanglingReferencesToDeletedObjects:(NSSet *)deletedObjects local:(BOOL)local;
- (void)resolveDanglingReferences;
- (void)updateDatabaseObjectCache;
- (NSDictionary *)orderClassesByAncestry:(NSArray *)objects;
- (void)performOnAllClasses:(NSDictionary *)dictionary inOrder:(BOOL)order block:(void(^)(NSArray *observers, Class subclass, NSArray *objectArrays)) block;
- (void)notifyRemoteChanges;
- (void)mergeChanges;
- (BOOL)isDownloadedGraphComplete;
- (void) downloadObjectsInBackgroundChangedSince:(NSDate*)since
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


#pragma mark - Public interface implementation

@implementation SLObjectRegistry

#pragma mark Public methods

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
    NSMutableSet    *fetchedObjects, *createdObjects;
    
    className = [subclass className];
    if (!self.registeredClasses[className])
        return;
    [self.observers[className] addObject:observer];
    
    // retroactively invoke didCreateObject: on the objects that have already been fetched from the cache and
    // created locally and remotely. Past deletions do not need to be notified.
    
    fetchedObjects = [NSMutableSet set];
    createdObjects = [NSMutableSet set];
    for(SLObject *object in self.objects)
        if (!object.deleted && (self.registeredClasses[object.className] == subclass)) {
            if (object.createdFromCache)
                [fetchedObjects addObject:object];
            if (object.createdRemotely)
                [createdObjects addObject:object];

            }
    
    if (([fetchedObjects count] != 0) || ([createdObjects count] != 0)) {
        
        // notify the beginning of change notifications
        
        if ([observer respondsToSelector:@selector(willChangeObjectsForClass:)])
            [observer willChangeObjectsForClass:subclass];
     
        // notify of object creations
        // no need to handle reentrant object operations here because this observer only is notified
        
        if ([observer respondsToSelector:@selector(didCreateObject:remotely:)]) {
            for(SLObject *object in fetchedObjects)
                [observer didCreateObject:object remotely:FALSE];
            for(SLObject *object in createdObjects)
                [observer didCreateObject:object remotely:object.createdRemotely];
        }
       
        // notify the end of change notifications
        
        if ([observer respondsToSelector:@selector(didChangeObjectsForClass:)])
            [observer didChangeObjectsForClass:subclass];
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

            [weakSelf notifyRemoteChanges];

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
    
    rootObject = @{@"clientMgr": [self.clientMgr archiveToDictionary],
                   @"lastSync": self.lastSync,
                   @"objects" : self.objects};
    
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
        NSDictionary            *orderedClassesDictionary;
        
        // that was successful
        
        [self.clientMgr unarchiveFromDictionary:rootObject[@"clientMgr"]];
        
        // update the rest of the object registry structures
        
        self.objects = rootObject[@"objects"];
        assert(self.objects);
        self.lastSync = rootObject[@"lastSync"];
        
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
        
        // invoke didCreateObject: on all instances of registered subclasses, one subclass at a time
        
        notifiedObjects = [NSMutableSet set];
        for(SLObject *object in self.objects)
            if (!object.deleted && self.registeredClasses[object.className])
                [notifiedObjects addObject:object];
        
        orderedClassesDictionary = [self orderClassesByAncestry:@[notifiedObjects]];
        
        // notify the beginning of change notifications
        
        [self performOnAllClasses:orderedClassesDictionary inOrder:TRUE block:^(NSArray *observers, Class subclass, NSArray *objectArrays) {
            for(NSObject<SLObjectObserving> *observer in observers)
                if ([observer respondsToSelector:@selector(willChangeObjectsForClass:)])
                    [observer willChangeObjectsForClass:subclass];
            
        }];
        
        // notify of object creations
        
        [self performOnAllClasses:orderedClassesDictionary inOrder:TRUE block:^(NSArray *observers, Class subclass, NSArray *objectArrays) {
            for(SLObject *object in objectArrays[0]) {
                for(NSObject<SLObjectObserving> *observer in observers) {
                    
                    // if the object has been deleted by an observer, no further notification to send
                    if (!object.operable)
                        break;
                    
                    // keep track of the last observer notified of the object creation, so that reentrant
                    // object operations (e.g. setting an attribute) do not reveal the object to observers
                    // that have not been notified of its creation yet
                    
                    object.lastObserverNotified = observer;
                    if ([observer respondsToSelector:@selector(didCreateObject:remotely:)])
                        [observer didCreateObject:object remotely:FALSE];
                }
                object.lastObserverNotified = nil;
            }
        }];
        
        // notify the end of change notifications (in reverse order of registration)
        
        [self performOnAllClasses:orderedClassesDictionary inOrder:TRUE block:^(NSArray *observers, Class subclass, NSArray *objectArrays) {
            for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator])
                if ([observer respondsToSelector:@selector(didChangeObjectsForClass:)])
                    [observer didChangeObjectsForClass:subclass];
        }];
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
    self.timer = [NSTimer scheduledTimerWithTimeInterval:kSLSyncSoonTimeInterval
                                                target:self
                                                selector:@selector(timerFireMethod:)
                                                userInfo:nil
                                                repeats:FALSE];
}


- (void)addObject:(SLObject *)object
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


- (void)removeObject:(SLObject *)object
{
    if (object.objectID) {
        
        // the object has been synced with the database
        // we discard any pending changes to the object and remove it from the locally modified list if it was there
        
        [self.locallyModifiedObjects removeObject:self];
        [self.locallyModifiedObjectIDMap removeObjectForKey:object.objectID];
        
        // we add the object to the locally deleted list
        
        [self.locallyDeletedObjects addObject:self];
        [self.locallyDeletedObjectIDMap setObject:self forKey:object.objectID];
        
        // schedule a sync
        // the deletion will be committed to the cloud on the next sync
        // once the sync has completed, the object will be removed from the registry.
        // at that point the registry will hold no more strong reference to the object.
        
        [self scheduleSync];
        
    } else {
        
        // the object is new and hasn't been synced to the database yet
        // we discard it from the locally created list
        
        [self.locallyCreatedObjects removeObject:self];
        
        // we also discard it from the object registry. this is the last strong reference
        // the registry holds to the object.
        
        [self.objects removeObject:self];
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


- (void)markObjectModified:(SLObject *)object remotely:(BOOL)remotely
{
    if (remotely)
        [self.remotelyModifiedObjects addObject:object];
    else {
        [self.locallyModifiedObjects addObject:object];
        [self.locallyModifiedObjectIDMap setObject:object forKey:object.objectID];
    }
}

- (void)markObjectUnmodified:(SLObject *)object remotely:(BOOL)remotely
{
    if (remotely)
        [self.remotelyModifiedObjects removeObject:object];
    else {
        [self.locallyModifiedObjects removeObject:object];
        [self.locallyModifiedObjectIDMap removeObjectForKey:object.objectID];
    }
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

#pragma mark - Private interface implementation

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
    _objectIDMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];
    if (!_objectIDMap)
        return nil;
    
    _downloadedObjects = [NSMutableArray array];
    if (!_downloadedObjects)
        return nil;
    _downloadedObjectIDMap = [NSMapTable mapTableWithKeyOptions:NSMapTableWeakMemory valueOptions:NSMapTableWeakMemory];
    if (!_downloadedObjectIDMap)
        return nil;

    _locallyModifiedObjects = [NSMutableSet set];
    if (!_locallyModifiedObjects)
        return nil;
    _locallyModifiedObjectIDMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];
    if (!_locallyModifiedObjectIDMap)
        return nil;
    
    _locallyCreatedObjects = [NSMutableSet set];
    if (!_locallyCreatedObjects)
        return nil;

    _locallyDeletedObjects = [NSMutableSet set];
    if (!_locallyDeletedObjects)
        return nil;
    _locallyDeletedObjectIDMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];
    if (!_locallyDeletedObjectIDMap)
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

    _registeredClasses = [NSMutableDictionary dictionary];
    if (!_registeredClasses)
        return nil;
    
    _observers = [NSMutableDictionary dictionary];
    if (!_observers)
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
    
    _lastSync = [NSDate distantPast];
    if (!_lastSync)
        return nil;
    _timer = nil;
    _syncInterval = kSLDefaultSyncInterval;

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

    // remove the remotely deleted objects from the registry and mark them deleted
    // so that they cannot be operated on
    // this triggers their eventual disposal
    
    for(SLObject *object in self.remotelyDeletedObjects) {
        object.deleted = TRUE;
        [self.objects removeObject:object];
        [self.objectIDMap removeObjectForKey:object.objectID];
    }

    if (error) {
        
        // in case of error, the local changes need to be preserved so that they may be
        // saved to the cloud or stored in the cache later.
        // remote changes don't need to be saved as they've been already processed
 
        for(SLObject *object in self.savedLocallyModifiedObjects) {
            
            for(NSString *key in object.savedLocalChanges) {
                SLChange        *change;
                
                change = object.savedLocalChanges[key];
                
                // preserve the change if the value hasn't been changed since (by a notification handler)
                
                if (!object.localChanges[key])
                    object.localChanges[key] = change;
            }
        }

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

    }
    
    // dispose of the saved local change dictionary for all locally modified objects
    
    for(SLObject *object in self.savedLocallyModifiedObjects) {
        object.savedLocalChanges = nil;
    }

    // dispose of the remote change dictionary for all remotely modified objects

    for(SLObject *object in self.remotelyModifiedObjects) {
        object.remoteChanges = nil;
    }

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


// colorize is used to recursively explore the object graph and order subclasses, from children to parents

static NSUInteger colorize(SLObject *object, NSUInteger index, NSMutableDictionary *classOrders)
{
    NSUInteger      maxIndex, thisIndex;
    NSNumber        *classOrder;
    
    // if the object has already been reached, return its color index
    
    if (object.index != 0)
        return object.index;
    
    // asign a color index to this object
    
    object.index = index;
    
    // assign a color index to the subclass associated with this object, if this subclass hasn't been assigned one yet
    
    classOrder = classOrders[object.className];
    if (!classOrder) {
        classOrders[object.className] = [NSNumber numberWithUnsignedInteger:index];
    } else {
        if ([classOrder unsignedIntegerValue] < index)
            classOrders[object.className] = [NSNumber numberWithUnsignedInteger:index];
    }
    
    // recursively explore all relations of the object
    
    maxIndex = index;
    for(NSString *key in object.values) {
        id          value;
        SLObject    *relation;
        
        value = [object dictionaryValueForKey:key];
        if (!value || ![SLObject isRelation:value])
            continue;
        relation = (SLObject *)value;
        thisIndex = colorize(relation, index+1, classOrders);
        if (thisIndex > maxIndex)
            maxIndex = thisIndex;
    }
    
    // return the highest color index found
    
    return maxIndex;
}


// uncolorize resets the object color so that colorize can be called again

static void uncolorize(SLObject *object)
{
    // return if this object has already been reset
    
    if (object.index == 0)
        return;
    
    // recursively reset this object and all its relations
    
    object.index = 0;
    for(NSString *key in object.values) {
        id          value;
        SLObject    *relation;
        
        value = [object dictionaryValueForKey:key];
        if (!value || ![SLObject isRelation:value])
            continue;
        relation = (SLObject *)value;
        uncolorize(relation);
    }
}


// orderClassesByAncestry takes a list of objects and builds a dictionary with the following:
// - a list of ordered subclass names, (children subclass before its parents)
// - a list of ordered object instances (ordered according to the subclass ordering above)
// this method is used to determine the notification order provided an arbitrary list of objects with pending notifications

- (NSDictionary *)orderClassesByAncestry:(NSArray *)sets
{
    NSUInteger              maxIndex, thisIndex;
    NSMutableDictionary     *classOrders;
    NSDictionary            *orderedClassDictionary;
    
    // initialize the dictionary with empty structures
    
    maxIndex = 1;
    orderedClassDictionary = @{ @"classNames" : [NSMutableArray array], @"instances" : [NSMutableDictionary dictionary]};
    classOrders = [NSMutableDictionary dictionary];
    
    // recursively colorize the object graph
    
    for(NSSet *set in sets)
        for(SLObject *object in set) {
            thisIndex = colorize(object, 1, classOrders);
            if (thisIndex > maxIndex)
                maxIndex = thisIndex;
            uncolorize(object);
        }
    
    // build the ordered list of object instances and subclasses based on subclass indexes
    
    for(NSUInteger i=maxIndex; i!=0; i--) {
        for(NSString *className in classOrders) {
            NSNumber    *classOrder;
            
            classOrder = classOrders[className];
            if ([classOrder integerValue] == i) {
                
                NSMutableArray *instanceArray;
                
                [orderedClassDictionary[@"classNames"] addObject:className];
                instanceArray = [NSMutableArray array];
                [orderedClassDictionary[@"instances"] addObject:instanceArray forKey:className];
                for(NSSet *set in sets) {
                    NSMutableArray  *instances;
                    
                    instances = [NSMutableArray array];
                    [instanceArray addObject:instances];
                    for(SLObject *object in set)
                        if ([object.className isEqualToString:className])
                            [instances addObject:object];
                }
            }
        }
    }
    return orderedClassDictionary;
}


// performOnAllClasses: is a utility method to perform a block on an ordered list of objects in a dictionary
// following the format returned by orderClassesByAncestry:

- (void)performOnAllClasses:(NSDictionary *)dictionary
                    inOrder:(BOOL)inOrder
                      block:(void(^)(NSArray *observers, Class subclass, NSArray *objectArrays))block
{
    NSArray             *classNames;
    NSEnumerator        *enumerator;

    classNames = dictionary[@"classNames"];
    if (inOrder)
        enumerator = [classNames objectEnumerator];
    else
        enumerator = [classNames reverseObjectEnumerator];
    
    for(NSString *className in enumerator) {
        NSArray                         *observers;
        Class                           subclass;
        NSArray                         *objectArrays;
        
        subclass = self.registeredClasses[className];
        observers = self.observers[className];
        if (!observers)
            continue;
        
        objectArrays = dictionary[@"instances"][className];

        block(observers, subclass, objectArrays);
    }
}


// notifyRemoteChanges: invokes the notification handlers for all registered observers on the objects that have been flagged as remotely modified
                                                           
- (void)notifyRemoteChanges
{
    NSDictionary        *orderedClassesDictionary;
    
    // The first step is to save and reset the locally modified object lists and
    // object local change lists so that the notification handlers can safely alter object state (changes initiated by notification
    // handlers won't be synced until the next sync)
    
    for(SLObject *object in
                [self.locallyModifiedObjects setByAddingObjectsFromSet:self.remotelyModifiedObjects]) {
        object.savedLocalChanges = object.localChanges;
        object.localChanges = [NSMutableDictionary dictionary];
    }

    self.savedLocallyModifiedObjects = self.locallyModifiedObjects;
    self.savedLocallyModifiedObjectIDMap = self.locallyModifiedObjectIDMap;
    self.savedLocallyCreatedObjects = self.locallyCreatedObjects;
    self.savedLocallyDeletedObjects = self.locallyDeletedObjects;
    self.savedLocallyDeletedObjectIDMap = self.locallyDeletedObjectIDMap;
    self.locallyModifiedObjects = [NSMutableSet set];
    self.locallyModifiedObjectIDMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];
    self.locallyCreatedObjects = [NSMutableSet set];
    self.locallyDeletedObjects = [NSMutableSet set];
    self.locallyDeletedObjectIDMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];
    
    // Notifications are grouped by subclass, and sent to all class instances, one class at a time
    // subclasses are ordered so that, for cycle-less object graphs:
    // - the creation or modification of a child is notified before the creation or modification of its parent
    // - the deletion of a child is notified after the deletion of its parent
    // for each class, notifications are sent in that order: creations, modifications and deletions
    
    orderedClassesDictionary = [self orderClassesByAncestry:@[self.remotelyCreatedObjects, self.remotelyModifiedObjects, self.remotelyDeletedObjects]];
    
    // notify the beginning of change notifications
    
    [self performOnAllClasses:orderedClassesDictionary inOrder:TRUE block: ^(NSArray *observers, Class subclass, NSArray *objectArrays) {
        for(NSObject<SLObjectObserving> *observer in observers)
            if ([observer respondsToSelector:@selector(willChangeObjectsForClass:)])
                [observer willChangeObjectsForClass:subclass];
    }];
  
    // notify of object creations
    
    [self performOnAllClasses:orderedClassesDictionary inOrder:TRUE block: ^(NSArray *observers, Class subclass, NSArray *objectArrays) {
        for(SLObject *object in objectArrays[0]) {
            for(NSObject<SLObjectObserving> *observer in observers) {
                
                // if the object has been deleted by an observer, no further notification to send
                if (!object.operable)
                    break;
                
                // keep track of the last observer notified of the object creation, so that reentrant
                // object operations (e.g. setting an attribute within an object creation notification handler)
                // do not reveal the object to observers that have not been notified of its creation yet
                
                object.lastObserverNotified = observer;
                if ([observer respondsToSelector:@selector(didCreateObject:remotely:)])
                    [observer didCreateObject:object remotely:TRUE];
            }
            object.lastObserverNotified = nil;
        }
    }];

    // notify of remote object modifications
    
    [self performOnAllClasses:orderedClassesDictionary inOrder:TRUE block: ^(NSArray *observers, Class subclass, NSArray *objectArrays) {
        for(SLObject *object in objectArrays[1])
            
            // iterate over a copy of the remote changes, as notification handlers may set properties and cancel remote changes
            
            for(NSString *key in [object.remoteChanges copy]) {
                SLChange    *change;
                
                change = object.remoteChanges[key];
                
                // make sure the remote change is still current
                
                if (!change)
                    continue;
                
                assert(!change.local);
                
                // notify prior to the value change (in reverse order of registration)
                
                for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
                    
                    // if the object has been deleted by an observer, no further notification to send

                    if (!object.operable)
                        break;
                    
                    if ([observer respondsToSelector:@selector(willChangeObjectValue:forKey:oldValue:newValue:remotely:)])
                        [observer willChangeObjectValue:object forKey:key oldValue:change.oValue newValue:change.nValue remotely:TRUE];
                }
                
                // update the value dictionary
                
                [object setDictionaryValue:change.nValue forKey:key];
                
                // notify after the value change
                
                for(NSObject<SLObjectObserving> *observer in observers) {
                    
                    // if the object has been deleted by an observer, no further notification to send
                    
                    if (!object.operable)
                        break;

                    if ([observer respondsToSelector:@selector(didChangeObjectValue:forKey:oldValue:newValue:remotely:)])
                        [observer didChangeObjectValue:object forKey:key oldValue:change.oValue newValue:change.nValue remotely:TRUE];
                }
            }
    }];

    // notify object deletions (in reverse order of registration)

    [self performOnAllClasses:orderedClassesDictionary inOrder:FALSE block: ^(NSArray *observers, Class subclass, NSArray *objectArrays) {
        for(SLObject *object in objectArrays[2])
            for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
                
                // if the object has been deleted by an observer, no further notification to send
                
                if (!object.operable)
                    break;
                
                if ([observer respondsToSelector:@selector(willDeleteObject:remotely:)])
                    [observer willDeleteObject:object remotely:TRUE];
            }
    }];
    
    // notify the end of change notifications (in reverse order of registration)
    
    [self performOnAllClasses:orderedClassesDictionary inOrder:FALSE block: ^(NSArray *observers, Class subclass, NSArray *objectArrays) {
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator])
            if ([observer respondsToSelector:@selector(didChangeObjectsForClass:)])
                [observer didChangeObjectsForClass:subclass];
    }];
    
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
        
        // the object is locally registered and not being locally deleted
        // it is being remotely deleted if the database object is marked for deletion
        
        if ([dbObject objectForKey:kPFObjectDeleteFlagKey])
            [self.remotelyDeletedObjects addObject:object];
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


// identifyRemotelyModifiedObjects creates a lits of objects whose attributes have been modified remotely

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
            
            id          remoteValue;
            id          localValue;
            SLChange    *change;
            NSDate      *dbObjectModifiedTime;
            BOOL        equal;
            
            if ([kPFObjectSystemKeys containsObject:key])
                continue;
            
            localValue = [object dictionaryValueForKey:key];
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
                    [SLChange changeWithObject:object local:FALSE key:key oldValue:localValue newValue:remoteValue when:[NSDate date]];
                    continue;
                }
                
                // a local change was found for this key. we have a conflict to resolve.
                
                dbObjectModifiedTime = [dbObject objectForKey:kPFObjectLastModifiedKey];
                
                // keep the most recent change
                
                if ([change.when laterDate:dbObjectModifiedTime] == dbObjectModifiedTime) {
                    
                    // the remote change is more recent. forego the local change and log the remote change
                    // the change object is modified in place to reflect the change.
                    
                    [change detachFromObject];
                    [SLChange changeWithObject:object local:FALSE key:key oldValue:localValue newValue:remoteValue when:[NSDate date]];

                    continue;
                }
                
                // the local change is more recent. nothing to do as the local change is already filed.
                continue;
            }
        }
    }
}


// resolveDanglingReferencesToDeletedObjects:local: takes a list of objects that have been deleted locally or remotely
// and ensures that all references to those objects are set to nil. Any reference set to nil is properly logged and notified as needed.

- (void)resolveDanglingReferencesToDeletedObjects:(NSSet *)deletedObjects local:(BOOL)local
{
    for(SLObject *deletedObject in deletedObjects) {
        
        // look for dangling references in local object values (object values before remote modifications are applied)
        // this isn't needed for local object deletions, as dangling references have already been set to nil when the object was deleted.
        // iterate over a copy of the reference list as it is modified by the loop body
        
        if (!local)
            for(SLObject *object in [deletedObject.references copy]) {
                
                // look for the relations pointing back to the deleted object
                // for each dangling reference, log a change to set the reference to nil
                // iterate over a copy of the value dictionary as it is being modified by the loop body
                
                for(NSString *key in [object.values copy]) {
                    if ([object dictionaryValueForKey:key] == deletedObject)
                        [SLChange changeWithObject:object local:FALSE key:key oldValue:deletedObject newValue:nil when:[NSDate date]];
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
                
                // if the new value of the remote change points to the deleted object, fix the dangling reference:
                // if the  value prior to the remote change was nil, we can drop the remote change (no change needs to be applied_
                // otherwise, we change the new value to be nil
                
                if (change.nValue == deletedObject) {
                    if (!change.oValue)
                        [change detachFromObject];
                    else
                        change.nValue = nil;
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
    [self identifyRemotelyDeletedObjects];
    [self identifyRemotelyCreatedObjects];
    [self identifyRemotelyModifiedObjects];
        
    [self resolveDanglingReferences];
    [self updateDatabaseObjectCache];
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
        
        for(NSString *key in object.values) {
            id      value;
            
            // capture only the cloud persisted properties
            
            if (![cloudPersistedProperties containsObject:key])
                continue;
            value = [object dictionaryToDatabaseValue:[object dictionaryValueForKey:key]];
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