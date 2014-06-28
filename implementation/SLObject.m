//
//  SLObject.m
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLObject-Internal.h"
#import "SLObjectRegistry.h"
#import "SLClientManager-Internal.h"
#import "SLChange.h"
#import "SLTransaction-Internal.h"
#import "SLTransactionManager.h"
#import "SLObjectObserving.h"


#import <Parse/PFObject.h>
#import <objc/runtime.h>

static NSString * const kSLObjectObjectIDKey = @"SLOObjectID";
static NSString * const kSLObjectClassNameKey = @"SLOClassName";
static NSString * const kSLObjectCommittedValuesKey = @"SLOCommittedValues";
static NSString * const kSLObjectLocalChangesKey = @"SLOLocalChanges";
static NSString * const kSLObjectReferencingObjectKeysKey = @"SLOReferencingObjectKeys";
static NSString * const kSLObjectDeletedKey = @"SLODeleted";

#pragma

@interface SLObject ()

@property (nonatomic, weak) SLObjectRegistry        *registry;

@property (nonatomic) NSString                      *className;

// maintained list of all references to this object
// key is referencing object, value is a NSMutableSet of property keys referencing the object

@property (nonatomic) NSMapTable                    *referencingObjectKeys;

@property BOOL                                      createdFromCache;
@property BOOL                                      createdRemotely;
@property BOOL                                      deleted;
@property BOOL                                      willDelete;

@property (nonatomic) NSMutableDictionary           *committedValues;

@property (nonatomic) NSMutableDictionary           *localChanges;
@property (nonatomic) NSMutableDictionary           *savedLocalChanges;
@property (nonatomic) NSMutableDictionary           *remoteChanges;
@property (nonatomic) NSMutableDictionary           *uncommittedChanges;
@property (nonatomic) NSMutableOrderedSet           *uncommittedReferences;

@property (nonatomic) NSMutableDictionary           *keyCapturingTransactions;
@property (nonatomic) NSMutableSet                  *referenceCapturingTransactions;

- (id) init;

// NSCoding protocol functions

- (id)initWithCoder:(NSCoder *)coder;
- (void)encodeWithCoder:(NSCoder *)coder;

// dynamic accessors for properties

- (id)dynamicValueForKey:(NSString *)key;
- (void)dynamicSetValue:(id)value forKey:(NSString *)key logChange:(BOOL)change;


@end


@implementation SLObject


// implementation of public methods

#pragma mark - Public Methods

// default className implementation returns nil, this must be overriden.

+ (NSString *)className
{
    return nil;
}


// default localPersisted implementation returns an empty list (all properties are by default cloud-persisted)

+ (NSArray *)localPersistedProperties
{
    return [NSArray array];
}


// default localTransientProperties returns an empty list (all properties are by default cloud-persisted)

+ (NSArray *)localTransientProperties
{
    return [NSArray array];
}


// registerSubClass real implementation is in SLObjectRegistry

+ (void)registerSubclass
{
    [[SLObjectRegistry sharedObjectRegistry] registerSubclass:self];
}


// addObserver: real implementation is in SLObjectRegistry

+ (void)addObserver:(id<SLObjectObserving>)observer
{
    [[SLObjectRegistry sharedObjectRegistry] addObserver:observer forClass:self];
}


// removeObserver: real implementation is in SLObjectRegistry

+ (void)removeObserver:(id<SLObjectObserving>)observer
{
    [[SLObjectRegistry sharedObjectRegistry] removeObserver:observer forClass:self];
}

// objectWithValues: creates a new database object of the sublass it is invoked on

+ (SLObject *)objectWithValues:(NSDictionary *)values
{
    SLObject                        *instance;
    NSArray                         *observers;
    
    // fail if invoked on the SLObject class
    
    if (![self className])
        return nil;
    
    // objects cannot be created in transactions

    if ([[SLTransactionManager sharedTransactionManager] currentTransaction]) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"objectWithValues: called inside a transaction block"
                                          userInfo:nil];
        @throw exception;
        return nil;
    }
    
    // allocate and init instance
    // objectID is set to nil until a database object is created on the store
    
    instance = [[self alloc] init];
    if (!instance)
        return nil;
    
    instance.objectID = nil;
    instance.className = [self className];
    instance.createdRemotely = FALSE;
    
    // create the value dictionary

    instance.committedValues = [NSMutableDictionary dictionary];
    if (!instance.committedValues)
        return nil;
    
    if (values)
        for (NSString *key in values) {
            id      value;
            value = values[key];
            if (value == [NSNull null])
                value = nil;
            [instance setDictionaryValue:values[key] forKey:key speculative:FALSE change:nil];
        }
    
    // add new object to the registry
    
    [instance.registry insertObject:instance];
    
    // notify the observers of object creation
    
    observers = [instance.registry observersForClassWithName:self.className];
    if (observers) {
        
        // notify the beginning of change notifications
        
        [instance.registry notifyObserversWillChangeObjects:observers];
        
        // notify of the object creation
        
        [instance.registry notifyObserversDidCreateObject:instance remote:FALSE];
    
        // notify the end of change notifications
        
        [instance.registry notifyObserversDidChangeObjects:observers];
    }
    
    // schedule a sync as we have modified the database
    
    [instance.registry scheduleSync];
    
    return instance;
}


// delete marks an object instance for deletion and deletes it as soon as practical

- (void)delete
{
    NSArray         *observers;
    
    // if the object is not in an modifiable state, gracefully return
    
    if (!self.modifiable)
        return;

    // objects cannot be deleted in transaction blocks
    
    if ([[SLTransactionManager sharedTransactionManager] currentTransaction]) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"delete called inside a transaction block"
                                          userInfo:nil];
        @throw exception;
        return;
    }
    
    [self startDeletion];
    
    // handle the transactions that capture and change the deleted object
    
    [self handleTransactionsForDeletedObject:TRUE];
    
    // set to nil all reference to the deleted object.
    // all modified objects are marked changed and will be saved on the next sync
    
    // iterate over a copy of the reference list and value keys as they are modified by the body of the loop
    
    for(SLObject *object in [self.referencingObjectKeys copy]) {
        NSSet       *keys;
        
        keys = [self.referencingObjectKeys objectForKey:object];
        for (NSString *key in [keys copy]) {
            if ([object dictionaryValueForKey:key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE] == self) {
                
                // set the refering to nil using the public accessor so that proper change tracking and notification is performed
                
                [object dynamicSetValue:nil forKey:key logChange:TRUE];
            }
        }
    }
    assert([self.referencingObjectKeys count] == 0);
    
    // notify the observers
    
    observers = [self.registry observersForClassWithName:self.className];
    if (observers) {
        
        // notify the beginning of change notifications
        
        [self.registry notifyObserversWillChangeObjects:observers];
        
        // notify of the object deletion (in reverse order of registration)
        
        [self.registry notifyObserversWillDeleteObject:self remote:FALSE];
        
        // notify the end of change notifications
        
        [self.registry notifyObserversDidChangeObjects:observers];
        
    }
    
    // mark the object locally deleted in the registry
    
    [self.registry markObjectDeleted:self];

    // complete the deletion (this part is common to local and remote deletions)
    
    [self completeDeletion];
}


#pragma mark - Library Internal Methods

#pragma mark Lifecycle


// init is called when an object is created locally (with objectWithValues:) or remotely (instantiated during sync).

- (id)init
{
    self = [super init];
    
    _registry = [SLObjectRegistry sharedObjectRegistry];
    _objectID = nil;
    _className = nil;
    _databaseObject = nil;
    _referencingObjectKeys = [NSMapTable strongToStrongObjectsMapTable];
    if (!_referencingObjectKeys)
        return nil;
    _deleted = FALSE;
    _committedValues = nil;
    _keyCapturingTransactions = nil;
    _referenceCapturingTransactions = nil;
    _uncommittedChanges = nil;
    _localChanges = nil;
    _remoteChanges = nil;
    _savedLocalChanges = nil;
    _lastObserverNotified = nil;
    _willDelete = FALSE;
    _depth = 0;
    _createdFromCache = FALSE;
    _createdRemotely = FALSE;
    
    return self;
}


// initWithCoder: is called when an object is brought back to life from the device cache, at application startup time.
// even though the archiving class for an object is its natural class, subclasses must not override this method. Nor do
// they need to: all attributes marked as persistent (cloud or local) are automatically archived by this implementation.
// if further initialization is needed, it can be done in the didCreateObject:remotely: notification handler

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    
    _registry = [SLObjectRegistry sharedObjectRegistry];
    _objectID = [coder decodeObjectForKey:kSLObjectObjectIDKey];
    _className = [coder decodeObjectForKey:kSLObjectClassNameKey];
    _databaseObject = nil;
    _referencingObjectKeys = [coder decodeObjectForKey:kSLObjectReferencingObjectKeysKey];
    _deleted = [coder decodeBoolForKey:kSLObjectDeletedKey];
    _committedValues = [coder decodeObjectForKey:kSLObjectCommittedValuesKey];
    _keyCapturingTransactions = nil;
    _referenceCapturingTransactions = nil;
    _uncommittedChanges = nil;
    _localChanges = [coder decodeObjectForKey:kSLObjectLocalChangesKey];
    _remoteChanges = nil;
    _savedLocalChanges = nil;
    _lastObserverNotified = nil;
    _willDelete = FALSE;
    _depth = 0;
    _createdFromCache = TRUE;
    _createdRemotely = FALSE;
    
    return self;
}

// objectFromExistingWithClassName:objectID: instantiates an existing object, but leaves its value directory empty.
// this is the first part of remote object instantiation

+ (SLObject *)objectFromExistingWithClassName:(NSString *)className objectID:(NSString *)objectID
{
    id                  subclass;
    SLObjectRegistry    *registry;
    SLObject            *instance;
    
    registry = [SLObjectRegistry sharedObjectRegistry];
    
    subclass = [registry classForRegisteredClassWithName:className];
    if (!subclass)
        subclass = [SLObject class];
    instance = [[subclass alloc] init];
    
    // add the object to the registry
    
    instance.objectID = objectID;
    instance.className = className;
    instance.createdRemotely = TRUE;
    
    // add this instance to the registry
    
    [registry insertObject:instance];
    
    return instance;
}


// populatWithDictionary: assign a value directory to an object. this is the second part of remote object instantiation

- (void)populateWithDictionary:(NSDictionary *)databaseDictionary
{
    // instantiate the dictionary value
    
    self.committedValues = [NSMutableDictionary dictionary];
    
    // iterate over the database values and populate the dictionary
    
    for (NSString *key in databaseDictionary) {
        id value;
        
        value = [self databaseToDictionaryValue:databaseDictionary[key]];
        [self setDictionaryValue:value forKey:key speculative:FALSE change:nil];
    }
    
}

// encode an object to save to the local cache file. the archiving class of an object is its natural class.
// this method must not be overriden.

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSMutableDictionary         *persistedValues;
    
    persistedValues = [NSMutableDictionary dictionary];
    for(NSArray *properties in @[[self.registry cloudPersistedPropertiesForClassWithName:self.className],
                                 [self.registry localPersistedPropertiesForClassWithName:self.className]])
        for(NSString *key in properties) {
            id      value;
            value = self.committedValues[key];
            if (value)
                persistedValues[key] = value;
        }
    
    [coder encodeObject:self.objectID forKey:kSLObjectObjectIDKey];
    [coder encodeObject:self.className forKey:kSLObjectClassNameKey];
    [coder encodeObject:persistedValues forKey:kSLObjectCommittedValuesKey];
    [coder encodeObject:self.localChanges forKey:kSLObjectLocalChangesKey];
    [coder encodeObject:self.referencingObjectKeys forKey:kSLObjectReferencingObjectKeysKey];
    [coder encodeBool:self.deleted forKey:kSLObjectDeletedKey];
}

- (void)handleTransactionsForDeletedObject:(BOOL)local
{
    // if this is a local deletion, the transactions that have captured properties of the
    // deleted object are still valid. But they need to forget all references to the object.

    // if this is a remote deletion, the transactions that have captured properties of the
    // deleted object must be voided because the transactions were speculatively executed
    // while the object still existed.
    
    for(NSString *key in self.keyCapturingTransactions) {
        
        NSOrderedSet        *capturingTransactions;
        
        capturingTransactions = self.keyCapturingTransactions[key];
        for(SLTransaction *capturingTransaction in capturingTransactions)
            if (local)
                [capturingTransaction forgetCapturedKeysForObject:self];
            else
                [capturingTransaction markVoided];
    }
    self.keyCapturingTransactions = nil;
    
    // if this is a local deletion, the transactions that have captured references to the
    // deleted object are still valid.
    
    // if this is a remote deletion, the transactions that have captured references to the
    // deleted object must be voided because the transactions were speculatively executed
    // while the object still existed.

    if (!local)
        for(SLTransaction *capturingTransaction in self.referenceCapturingTransactions)
            [capturingTransaction markVoided];
    self.referenceCapturingTransactions = nil;
    
    // the transactions that have uncommitted references to the deleted object are still
    // valid. But they need to adjust those changes to point to nil instead.
    
    for(SLChange *change in self.uncommittedReferences)
        change.nValue = nil;
    self.uncommittedReferences = nil;
    
    // the transactions that have modified the deleted object must drop their changes
    // to the object
    
    for(NSString *key in self.uncommittedChanges) {
        
        NSOrderedSet        *uncommittedChanges;
        
        uncommittedChanges = self.uncommittedChanges[key];
        for(SLChange *uncommittedChange in uncommittedChanges)
            [uncommittedChange.issuingTransaction forgetUncommittedKeysForObject:self];
    }
    self.uncommittedChanges = nil;
}

- (void)startDeletion
{
    self.willDelete = TRUE;
}

- (void)completeDeletion
{
    // mark the object for deletion
    
    self.deleted = TRUE;
    
    // set to nil all references this object makes to other objects. this ensures that the object is
    // removed from all referencing object lists
    
    for(NSString *key in [self.committedValues allKeys]) {
        id          value;
        value = [self dictionaryValueForKey:key useSpeculative:FALSE wasSpeculative:NULL capture:FALSE];
        if (!value || ![SLObject isRelation:value])
            continue;
        
        // perform the change through the internal accessor, as we don't want change tracking nor notifications.
        
        [self setDictionaryValue:nil forKey:key speculative:FALSE change:nil];
    }
    
    // forget about any local changes to the object
    
    self.localChanges = nil;
}


// function to check whether an object can receive a user message

- (BOOL)operable
{
    // The object can receive user-sent messages if it's not deleted;
    
    return (!self.deleted);
}


// function to check whether an object can be written (property set or object deleted)

- (BOOL)modifiable
{
    // The object can be written to if it's not in the process of being deleted
    
    return (!self.deleted && !self.willDelete);
}


#pragma mark Object Value Management

- (void)saveLocalChanges
{
    self.savedLocalChanges = self.localChanges;
    self.localChanges = [NSMutableDictionary dictionary];
}

- (void)doneWithSavedLocalChanges:(BOOL)merge
{
    if (merge) {
        for(NSString *key in self.savedLocalChanges) {
            SLChange        *change;
            
            change = self.savedLocalChanges[key];
            
            // preserve the change if the property hasn't been changed since it was saved
            
            if (!self.localChanges[key])
                self.localChanges[key] = change;
        }
    }
    self.savedLocalChanges = nil;
}

- (void)removeAllRemoteChanges
{
    self.remoteChanges = nil;
}

- (void)addChange:(SLChange *)change
{
    NSString        *key;
    
    key = change.key;

    if (change.issuingTransaction) {
        
        NSMutableOrderedSet     *changes;
        
        if (!self.uncommittedChanges) {
            self.uncommittedChanges = [NSMutableDictionary dictionary];
            assert(self.uncommittedChanges);
        }
        changes = self.uncommittedChanges[key];
        if (!changes) {
            changes = [NSMutableOrderedSet orderedSet];
            assert(changes);
            self.uncommittedChanges[key] = changes;
        }
        
        [changes addObject:change];
        
    } else {
        
        NSMutableDictionary     *changes;
        
        if (change.local) {

            if (!self.localChanges) {
                self.localChanges = [NSMutableDictionary dictionary];
                assert(self.localChanges);
            }
            changes = self.localChanges;
        } else {
            if (!self.remoteChanges) {
                self.remoteChanges = [NSMutableDictionary dictionary];
                assert(self.remoteChanges);
            }
            changes = self.remoteChanges;
        }
        
        changes[key] = change;
        
        // remember the object was modified
        
        [self.registry markObjectModified:self local:change.local];
    }
}

- (void)removeChange:(SLChange *)change
{
    NSString        *key;
    
    key = change.key;

    if (change.issuingTransaction) {
        
        NSMutableOrderedSet     *changes;
        
        changes = self.uncommittedChanges[key];
        assert(changes);
        assert([changes containsObject:change]);
        [changes removeObject:change];
        if ([changes count] == 0) {
            [self.uncommittedChanges removeObjectForKey:key];
            if ([self.uncommittedChanges count] == 0)
                self.uncommittedChanges = nil;
        }
        
    } else {
        
        NSMutableDictionary     *changes;
        
        if (change.local)
            changes = self.localChanges;
        else
            changes = self.remoteChanges;
        
        assert(changes[key]);
        [changes removeObjectForKey:key];
        
        // drop the object from the modified list if no more change left for this object
        
        if ([changes count] == 0)
            [self.registry markObjectUnmodified:self local:change.local];
    }
}

- (NSArray *)uncommittedKeys
{
    return [self.uncommittedChanges allKeys];
}

- (SLChange *)lastUncommittedChangeForKey:(NSString *)key
{
    NSOrderedSet    *keyChanges;
    
    keyChanges = [self.uncommittedChanges objectForKey:key];
    return keyChanges.lastObject;
}

- (NSArray *)referencingObjects
{
    return [[self.referencingObjectKeys keyEnumerator] allObjects];
}

- (NSSet *)referencingKeysForObject:(SLObject *)object
{
    return [self.referencingObjectKeys objectForKey:object];
}

- (void)addReferenceCapturingTransaction:(SLTransaction *)transaction
{
    NSMutableSet        *capturingTransactions;
    
    capturingTransactions = self.referenceCapturingTransactions;
    if (!capturingTransactions) {
        capturingTransactions = [NSMutableSet set];
        assert(capturingTransactions);
        self.referenceCapturingTransactions = capturingTransactions;
    }
    [capturingTransactions addObject:transaction];
}

- (void)removeReferenceCapturingTransaction:(SLTransaction *)transaction
{
    NSMutableSet        *capturingTransactions;

    capturingTransactions = self.referenceCapturingTransactions;
    assert(capturingTransactions);
    assert([capturingTransactions containsObject:transaction]);
    [capturingTransactions removeObject:transaction];
    if ([capturingTransactions count] == 0)
        self.referenceCapturingTransactions = nil;
}

- (void)addCapturingTransaction:(SLTransaction *)transaction forKey:(NSString *)key
{
    NSMutableOrderedSet     *capturingTransactions;
    
    if (!self.keyCapturingTransactions) {
        self.keyCapturingTransactions = [NSMutableDictionary dictionary];
        assert(self.keyCapturingTransactions);
    }
    capturingTransactions = self.keyCapturingTransactions[key];
    if (!capturingTransactions) {
        capturingTransactions = [NSMutableOrderedSet orderedSet];
        assert(capturingTransactions);
        self.keyCapturingTransactions[key] = capturingTransactions;
    }
    [capturingTransactions addObject:transaction];
}

- (void)removeCapturingTransaction:(SLTransaction *)transaction forKey:(NSString *)key
{
    NSMutableOrderedSet     *capturingTransactions;
    
    capturingTransactions = self.keyCapturingTransactions[key];
    assert([capturingTransactions containsObject:transaction]);
    [capturingTransactions removeObject:transaction];
    if ([capturingTransactions count] == 0)
        [self.keyCapturingTransactions removeObjectForKey:key];
}

- (NSOrderedSet *)capturingTransactionsForKey:(NSString *)key
{
    return [self.keyCapturingTransactions objectForKey:key];
}

- (void)voidKeyCapturingTransactions
{
    for(NSString *key in self.keyCapturingTransactions)
        for(SLTransaction *transaction in self.keyCapturingTransactions[key])
            [transaction markVoided];
}

- (void)voidTransactionsCapturingKey:(NSString *)key
{
    for(SLTransaction *transaction in self.keyCapturingTransactions[key])
        [transaction markVoided];
}


// accessor functions for dynamic object attributes

// dynamicValueForKey: is the implementation of the getter accessors for object properties of all storage classes.
// the getter accessors are dynamically added to a subclass when it registers with SyncLib

- (id)dynamicValueForKey:(NSString *)key
{
    id                  value;

    if (!self.operable)
        return nil;

    value = [self dictionaryValueForKey:key useSpeculative:TRUE wasSpeculative:NULL capture:TRUE];
    
    return value;
}

// dynamicSetValueForKey:logChange: is the implementation of the setter accessors for object properties of all storage
// classes. the setter accessors are dynamically added to a subclass when it registers with SyncLib.
// the logChange flag indicates whether the change should be logged. the flag is set for cloud persisted properties,
// not for others.

- (void)dynamicSetValue:(id)value forKey:(NSString *)key logChange:(BOOL)withChange
{
    id              oldValue;
    NSArray         *observers;
    SLTransaction   *transaction;
    SLChange        *change;
    BOOL            speculative;
    
    if (!self.modifiable)
        return;
    
    // if the value is a relation and the referenced object has been deleted, change the value to nil.
    // all references to an object are set to nil when the object is deleted. However it is still possible for
    // code to keep a strong pointer to the object after it is deleted. This covers this situation and ensures
    // that the relation is set to nil.
    
    if ([SLObject isRelation:value] && ![(SLObject *)value operable])
        value = nil;

    // retrieve the current (old) value

    oldValue = [self dictionaryValueForKey:key useSpeculative:TRUE wasSpeculative:&speculative capture:FALSE];

    // if this write is not part of a transaction and it is following a speculative write (synchronous write after speculative write),
    // we need to make it a speculative write too. This is necessary to preserve the ordering of write operations in case the speculative
    // write gets cancelled and the transaction retried.
    // note that the ordering of synchronous writes with respect to asynchronous writes is not guaranteed.
    
    transaction = [[SLTransactionManager sharedTransactionManager] currentTransaction];
    if (!transaction && speculative)
        transaction = [SLTransaction speculativeTransaction];
    
    // log the change if 1) it is part of a transaction
    // or 2) the object is replicated in the cloud and the property synced.
    
    change = nil;
    if (transaction || (self.objectID && withChange))
        change = [SLChange transactionChangeWithObject:self key:key oldValue:oldValue newValue:value transaction:transaction];
    
    // notify the observers if
    // 1) this change isn't part of a transaction
    // or 2) this change is part of a synchronous transaction
    
    if (!transaction || transaction.speculative) {

        // notify the observers, part I
        
        observers = [self.registry observersForClassWithName:self.className];
        if (observers) {
            
            // notify the beginning of change notifications
            
            [self.registry notifyObserversWillChangeObjects:observers];
            
            // notify prior the value change (in reverse order of registration)
            
            [self.registry notifyObserversWillChangeObjectValue:self forKey:key oldValue:oldValue newValue:value remote:FALSE];
        }
    }
        
    // set the property to the new value
    
    [self setDictionaryValue:value forKey:key speculative:(transaction != nil) change:change];
        
    // notify the observers, part II
    
    if (!transaction || transaction.speculative) {
        
        if (observers) {
            
            // notify after the value change
            
            [self.registry notifyObserversDidChangeObjectValue:self forKey:key oldValue:oldValue newValue:value remote:FALSE];
            
            // notify the end of change notifications (in reverse order of registration)
            
            [self.registry notifyObserversDidChangeObjects:observers];
        }
        
        // schedule a sync soon if we just modified a cloud persisted property
        
        if ([[self.registry cloudPersistedPropertiesForClassWithName:self.className] containsObject:key])
            [self.registry scheduleSync];
    }
}

// allProperties is a helper method that returns an array with all the object properties
// it also ensures that all object properties are @dynamic

+ (NSArray *)allProperties
{
    unsigned int        count, i;
    objc_property_t     *properties, property;
    const char          *name;
    NSMutableArray      *array;
    
    array = [NSMutableArray array];
    properties = class_copyPropertyList(self, &count);
    for (i = 0; i < count; i++) {
        property = properties[i];
        assert(isDynamicProperty(property_getAttributes(property)));
        
        name = property_getName(property);
        [array addObject:[NSString stringWithCString:name encoding:NSASCIIStringEncoding]];
    }
    free(properties);
    return array;
}

- (NSArray *)dictionaryKeys
{
    return [self.committedValues allKeys];
}

// retrieve a dictionary value
// [NSNUll null] values are converted to nil

- (id)dictionaryValueForKey:(NSString *)key useSpeculative:(BOOL)useSpeculative wasSpeculative:(BOOL *)wasSpeculative capture:(BOOL)capture
{
    id              value;
    SLTransaction   *transaction;
    
    value = nil;
    if (![SLClientManager sharedClientManager].syncing) {
        capture = FALSE;
        useSpeculative = FALSE;
        if (wasSpeculative)
            *wasSpeculative = FALSE;
    }
    if (useSpeculative) {
        value = [self.registry uncommittedValueForObject:self key:key];
        if (wasSpeculative)
            *wasSpeculative = (value != nil);
    }
    if (!value)
        value = self.committedValues[key];
    if (capture) {
        transaction = [[SLTransactionManager sharedTransactionManager] currentTransaction];
        if (transaction) {
            [transaction captureKey:key forObject:self];
            [self addCapturingTransaction:transaction forKey:key];
            if ([SLObject isRelation:value]) {
                SLObject    *referencedObject;
                
                referencedObject = (SLObject *)value;
                [transaction captureReference:referencedObject];
                [referencedObject addReferenceCapturingTransaction:transaction];
            }
        }
    }
    
    // convert from NSNull back to nil if needed
    
    if (value == [NSNull null])
        value = nil;
    return value;
}


// store a dictionary value
// nil values are convert to [NSNUll null]
// reference lists are maintained

- (void)setDictionaryValue:(id)value forKey:(NSString *)key speculative:(BOOL)speculative change:(SLChange *)change
{
    id          oldValue;
    BOOL        wasSpeculative;
    
    // no need for speculative execution if syncing is off
    
    if (![SLClientManager sharedClientManager].syncing)
        speculative = FALSE;
    
    // retrieve the old (current) value and convert from NSNull back to nil if needed

    oldValue = [self dictionaryValueForKey:key useSpeculative:speculative wasSpeculative:&wasSpeculative capture:FALSE];
    
    // maintain the reference lists

    NSMutableSet        *keys;
    SLObject            *relation;
    
    if ([SLObject isRelation:oldValue]) {
        relation = (SLObject *)oldValue;
        if (!speculative) {
            keys = [relation.referencingObjectKeys objectForKey:self];
            assert(keys);
            [keys removeObject:key];
            if ([keys count] == 0)
                [relation.referencingObjectKeys removeObjectForKey:self];
        }
    }
    
    if ([SLObject isRelation:value]) {
        relation = (SLObject *)value;
        if (speculative) {
            [relation.uncommittedReferences addObject:change];
        } else {
            keys = [relation.referencingObjectKeys objectForKey:self];
            if (!keys) {
                keys = [NSMutableSet set];
                assert(keys);
                [relation.referencingObjectKeys setObject:keys forKey:self];
            }
            [keys addObject:key];
        }
    }

    // convert nil values to [NSNull null];
    
    if (!value)
        value = [NSNull null];

    if (speculative) {
        [self.registry setUncommittedValue:value forObject:self key:key];
        
        // create an entry in the committed value dictionary if none exists
        
        if (!self.committedValues[key])
            self.committedValues[key] = [NSNull null];
    } else
        self.committedValues[key] = value;
}


// utility method to convert a database value to a dictionary value.
// PFObject * are converted to SLObject *.
// [NSNull null] is converted to nil
// All other object types/values are left untouched.

- (id)databaseToDictionaryValue:(id)value
{
    PFObject    *dbObject;
    
    if (value == [NSNull null])
        return nil;
    
    // convert if attribute is a relation (class of PFObject)
    
    if ([SLObject isDBRelation:value]) {
        dbObject = (PFObject *)value;
        
        // this returns nil if the object has an unknown objectID. this may
        // happen if a reference to a deleted object is left dangling in the database
        // (see discussion under resolveDanglingReferencesToDeletedObjects:local:)
        
        return [self.registry objectForID:dbObject.objectId];
    }
    
    return value;
}


// utility method to convert a dictionary value to a database value.
// SLObject * are converted to PFObject *.
// nil values are converted to [NSNull null]
// All other object types/values are left untouched.

- (id)dictionaryToDatabaseValue:(id)value
{
    SLObject        *relation;
    
    // convert if attribute is a relation (class of SLObject)
    // a reference to the same database object is created
    
    if ([SLObject isRelation:value]) {
        relation = (SLObject *)value;
        
        // lazily create a database object for the relation
        
        if (!relation.databaseObject) {
            assert(relation.objectID);
            relation.databaseObject = [PFObject objectWithoutDataWithClassName:relation.className objectId:relation.objectID];
            assert(relation.databaseObject);
        }
        return relation.databaseObject;
    }
    
    if (!value)
        return [NSNull null];

    return value;;
}


// utility method to check whether a given attribute is a database relation

+ (BOOL)isDBRelation:(id)attribute
{
    return (attribute && [attribute isKindOfClass:[PFObject class]]);
}


// utility method to check whether a given attribute is a memory relation

+ (BOOL)isRelation:(id)attribute
{
    return (attribute && [attribute isKindOfClass:[SLObject class]]);
}

#pragma mark - Private Methods


// xxxGetterGlue are the glue functions for getter accessors

static id objectGetterGlue(id self, SEL _cmd)
{
    NSString      *propertyName;
    
    propertyName = [NSString stringWithCString:sel_getName(_cmd) encoding:NSASCIIStringEncoding];
    return [self dynamicValueForKey:propertyName];
}

static char charGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number charValue];
}

static short shortGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number shortValue];
}

static int intGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number intValue];
}

static long longGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number longValue];
}

static long long longLongGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number longLongValue];
}

static unsigned char unsignedCharGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number unsignedCharValue];
}

static unsigned short unsignedShortGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number unsignedShortValue];
}

static unsigned int unsignedIntGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number unsignedIntValue];
}

static unsigned long unsignedLongGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number unsignedLongValue];
}

static unsigned long long unsignedLongLongGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number unsignedLongLongValue];
}

static float floatGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number floatValue];
}

static double doubleGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    number = objectGetterGlue(self, _cmd);
    return [number doubleValue];
}

static bool boolGetterGlue(id self, SEL _cmd)
{
    NSNumber        *number;
    
    // this returns a BOOL rather than a bool, but that's safe
    
    number = objectGetterGlue(self, _cmd);
    return [number boolValue];
}

// setterGlueWithChange is the glue for setter accessors for cloud persited properties

static void objectSetterGlueWithChange(id self, SEL _cmd, id value)
{
    const char      *selName;
    char            buffer[128];
    NSString        *propertyName;
    
    selName = sel_getName(_cmd);
    sprintf(&buffer[0], "%c%s", tolower(selName[3]), &selName[4]);
    buffer[strlen(&selName[0])-4] = 0;
    propertyName = [NSString stringWithCString:&buffer[0] encoding:NSASCIIStringEncoding];
    [self dynamicSetValue:value forKey:propertyName logChange:TRUE];
}

static void charSetterGlueWithChange(id self, SEL _cmd, char value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithChar:value]);
}

static void shortSetterGlueWithChange(id self, SEL _cmd, short value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithShort:value]);
}

static void intSetterGlueWithChange(id self, SEL _cmd, int value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithInt:value]);
}

static void longSetterGlueWithChange(id self, SEL _cmd, long value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithLong:value]);
}

static void longLongSetterGlueWithChange(id self, SEL _cmd, long long value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithLongLong:value]);
}

static void unsignedCharSetterGlueWithChange(id self, SEL _cmd, unsigned char value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithUnsignedChar:value]);
}

static void unsignedShortSetterGlueWithChange(id self, SEL _cmd, unsigned short value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithUnsignedShort:value]);
}

static void unsignedIntSetterGlueWithChange(id self, SEL _cmd, unsigned int value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithUnsignedInt:value]);
}

static void unsignedLongSetterGlueWithChange(id self, SEL _cmd, unsigned long value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithUnsignedLong:value]);
}

static void unsignedLongLongSetterGlueWithChange(id self, SEL _cmd, unsigned long long value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithUnsignedLongLong:value]);
}

static void floatSetterGlueWithChange(id self, SEL _cmd, float value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithFloat:value]);
}

static void doubleSetterGlueWithChange(id self, SEL _cmd, double value)
{
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithDouble:value]);
}

static void boolSetterGlueWithChange(id self, SEL _cmd, bool value)
{
    // this takes a BOOL rather than a bool, but that's safe
    
    objectSetterGlueWithChange(self, _cmd, [NSNumber numberWithBool:value]);
}

// setterGlueWithoutChange is the glue for setter accessors for locally persisted and transient properties

static void objectSetterGlueWithoutChange(id self, SEL _cmd, id value)
{
    const char      *selName;
    char            buffer[128];
    NSString        *propertyName;
    
    selName = sel_getName(_cmd);
    sprintf(&buffer[0], "%c%s", tolower(selName[3]), &selName[4]);
    buffer[strlen(&selName[0])-4] = 0;
    propertyName = [NSString stringWithCString:&buffer[0] encoding:NSASCIIStringEncoding];
    [self dynamicSetValue:value forKey:propertyName logChange:FALSE];
}

static void charSetterGlueWithoutChange(id self, SEL _cmd, char value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithChar:value]);
}

static void shortSetterGlueWithoutChange(id self, SEL _cmd, short value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithShort:value]);
}

static void intSetterGlueWithoutChange(id self, SEL _cmd, int value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithInt:value]);
}

static void longSetterGlueWithoutChange(id self, SEL _cmd, long value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithLong:value]);
}

static void longLongSetterGlueWithoutChange(id self, SEL _cmd, long long value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithLongLong:value]);
}

static void unsignedCharSetterGlueWithoutChange(id self, SEL _cmd, unsigned char value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithUnsignedChar:value]);
}

static void unsignedShortSetterGlueWithoutChange(id self, SEL _cmd, unsigned short value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithUnsignedShort:value]);
}

static void unsignedIntSetterGlueWithoutChange(id self, SEL _cmd, unsigned int value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithUnsignedInt:value]);
}

static void unsignedLongSetterGlueWithoutChange(id self, SEL _cmd, unsigned long value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithUnsignedLong:value]);
}

static void unsignedLongLongSetterGlueWithoutChange(id self, SEL _cmd, unsigned long long value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithUnsignedLongLong:value]);
}

static void floatSetterGlueWithoutChange(id self, SEL _cmd, float value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithFloat:value]);
}

static void doubleSetterGlueWithoutChange(id self, SEL _cmd, double value)
{
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithDouble:value]);
}

static void boolSetterGlueWithoutChange(id self, SEL _cmd, bool value)
{
    // this takes a BOOL rather than a bool, but that's safe
    
    objectSetterGlueWithoutChange(self, _cmd, [NSNumber numberWithBool:value]);
}

// isDynamicProperty is helper function that verifies that the property is @dynamic

static BOOL isDynamicProperty(const char *attributes)
{
    NSUInteger     len, i;
    
    len = strlen(attributes);
    if (len < 2)
        return FALSE;
    
    for(i=2; i<len-1; i++)
        if ((attributes[i] == ',') && (attributes[i+1] == 'D')) {
            
            // make sure property type is either scalar or object
            
            assert(strchr("csilqCSILQfdB@", attributes[1]));
            return TRUE;
        }
    
    return FALSE;
}

// generate the dynamic attribute accessor for a subclass

+ (void)generateDynamicAccessors
{
    NSString            *className;
    SLObjectRegistry    *registry;
    
    
    // accessors for attributes of all storage classes are generated
    
    registry = [SLObjectRegistry sharedObjectRegistry];
    className = [self className];
    
    // iterate over all the class properties
    
    for(NSArray *properties in @[[registry cloudPersistedPropertiesForClassWithName:className],
                                 [registry localPersistedPropertiesForClassWithName:className],
                                 [registry localTransientPropertiesForClassWithName:className]])
        for(NSString *propertyName in properties) {
            
            IMP                 implementation;
            SEL                 selector;
            objc_property_t     property;
            char                buffer[128];
            const char          *name;
            char                type;
            
            name = [propertyName cStringUsingEncoding:NSASCIIStringEncoding];
            property = class_getProperty([registry classForRegisteredClassWithName:className], name);
            type = property_getAttributes(property)[1];
            
            // identify the correct getter accessor based on the property type
            
            switch(type) {
                case 'c':
                    implementation = (IMP)charGetterGlue;
                    break;
                case 's':
                    implementation = (IMP)shortGetterGlue;
                    break;
                case 'i':
                    implementation = (IMP)intGetterGlue;
                    break;
                case 'l':
                    implementation = (IMP)longGetterGlue;
                    break;
                case 'q':
                    implementation = (IMP)longLongGetterGlue;
                    break;
                case 'C':
                    implementation = (IMP)unsignedCharGetterGlue;
                    break;
                case 'S':
                    implementation = (IMP)unsignedShortGetterGlue;
                    break;
                case 'I':
                    implementation = (IMP)unsignedIntGetterGlue;
                    break;
                case 'L':
                    implementation = (IMP)unsignedLongGetterGlue;
                    break;
                case 'Q':
                    implementation = (IMP)unsignedLongLongGetterGlue;
                    break;
                case 'f':
                    implementation = (IMP)floatGetterGlue;
                    break;
                case 'd':
                    implementation = (IMP)doubleGetterGlue;
                    break;
                case 'B':
                    implementation = (IMP)boolGetterGlue;
                    break;
                case '@':
                    implementation = (IMP)objectGetterGlue;
                    break;
                default:
                    assert(NULL);
            }
            
            // dynamically create the getter accessor for the property
            
            sprintf(&buffer[0], "%s", name);
            selector = sel_registerName(&buffer[0]);
            sprintf(&buffer[0], "%c@:", type);
            class_addMethod(self, selector, implementation, &buffer[0]);
            
            // then dynamicaly create the setter accessor for the property
            // setters for cloud persisted properties keep a change log to help the reconcilation logic
            // setters for all other properties do no need to keep a change log
            
            // identify the correct setter accessor based on the property type
            
            if (properties == [registry cloudPersistedPropertiesForClassWithName:className]) {
                switch(type) {
                    case 'c':
                        implementation = (IMP)charSetterGlueWithChange;
                        break;
                    case 's':
                        implementation = (IMP)shortSetterGlueWithChange;
                        break;
                    case 'i':
                        implementation = (IMP)intSetterGlueWithChange;
                        break;
                    case 'l':
                        implementation = (IMP)longSetterGlueWithChange;
                        break;
                    case 'q':
                        implementation = (IMP)longLongSetterGlueWithChange;
                        break;
                    case 'C':
                        implementation = (IMP)unsignedCharSetterGlueWithChange;
                        break;
                    case 'S':
                        implementation = (IMP)unsignedShortSetterGlueWithChange;
                        break;
                    case 'I':
                        implementation = (IMP)unsignedIntSetterGlueWithChange;
                        break;
                    case 'L':
                        implementation = (IMP)unsignedLongSetterGlueWithChange;
                        break;
                    case 'Q':
                        implementation = (IMP)unsignedLongLongSetterGlueWithChange;
                        break;
                    case 'f':
                        implementation = (IMP)floatSetterGlueWithChange;
                        break;
                    case 'd':
                        implementation = (IMP)doubleSetterGlueWithChange;
                        break;
                    case 'B':
                        implementation = (IMP)boolSetterGlueWithChange;
                        break;
                    case '@':
                        implementation = (IMP)objectSetterGlueWithChange;
                        break;
                    default:
                        assert(NULL);
                }
            } else {
                switch(type) {
                    case 'c':
                        implementation = (IMP)charSetterGlueWithoutChange;
                        break;
                    case 's':
                        implementation = (IMP)shortSetterGlueWithoutChange;
                        break;
                    case 'i':
                        implementation = (IMP)intSetterGlueWithoutChange;
                        break;
                    case 'l':
                        implementation = (IMP)longSetterGlueWithoutChange;
                        break;
                    case 'q':
                        implementation = (IMP)longLongSetterGlueWithoutChange;
                        break;
                    case 'C':
                        implementation = (IMP)unsignedCharSetterGlueWithoutChange;
                        break;
                    case 'S':
                        implementation = (IMP)unsignedShortSetterGlueWithoutChange;
                        break;
                    case 'I':
                        implementation = (IMP)unsignedIntSetterGlueWithoutChange;
                        break;
                    case 'L':
                        implementation = (IMP)unsignedLongSetterGlueWithoutChange;
                        break;
                    case 'Q':
                        implementation = (IMP)unsignedLongLongSetterGlueWithoutChange;
                        break;
                    case 'f':
                        implementation = (IMP)floatSetterGlueWithoutChange;
                        break;
                    case 'd':
                        implementation = (IMP)doubleSetterGlueWithoutChange;
                        break;
                    case 'B':
                        implementation = (IMP)boolSetterGlueWithoutChange;
                        break;
                    case '@':
                        implementation = (IMP)objectSetterGlueWithoutChange;
                        break;
                    default:
                        assert(NULL);
                }
            }
            
            sprintf(&buffer[0], "set%c%s:", toupper(name[0]), &name[1]);
            selector = sel_registerName(&buffer[0]);
            sprintf(&buffer[0], "v@:%c", type);
            class_addMethod(self, selector, implementation, &buffer[0]);
        }
}

@end