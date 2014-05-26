//
//  SLObject.m
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLObject.h"
#import "SLObject_Private.h"
#import "SLObjectRegistry.h"
#import "SLClientManager.h"
#import "SLChange.h"
#import "SLObjectObserving.h"


#import <Parse/PFObject.h>
#import <objc/runtime.h>

NSString *kSLObjectObjectIDName = @"SLOObjectID";
NSString *kSLObjectClassNameName = @"SLOClassName";
NSString *kSLObjectValuesName = @"SLOValues";
NSString *kSLObjectLocalChangesName = @"SLOLocalChanges";
NSString *kSLObjectReferencesName= @"SLOReferences";
NSString *kSLObjectDeletedName = @"SLODeleted";


@implementation SLObject


// implementation of public methods

#pragma mark - Public interface implementation

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

// objectWithValues: creates a new database object of the sublass it is invoked on

+ (SLObject *)objectWithValues:(NSDictionary *)values
{
    SLObject                        *instance;
    NSArray                         *observers;
    
    // fail if invoked on the SLObject class
    
    if (![self className])
        return nil;
    
    // allocate and init instance
    // objectID is set to nil until a database object is created on the store
    
    instance = [[self alloc] init];
    if (!instance)
        return nil;
    
    instance.objectID = nil;
    instance.className = [self className];
    instance.createdRemotely = FALSE;
    
    // create the value dictionary
    
    instance.values = [NSMutableDictionary dictionary];
    if (!instance.values)
        return nil;
    
    if (values)
        for (NSString *key in values) {
            id      value;
            value = values[key];
            if (value == [NSNull null])
                value = nil;
            [instance setDictionaryValue:values[key] forKey:key];
        }
    
    // add new object to the registry
    
    [instance.registry addObject:instance];
    
    // notify the observers of object creation
    
    observers = [instance.registry observersForClassWithName:self.className];
    if (observers) {
        
        // notify the beginning of change notifications
        
        for(NSObject<SLObjectObserving> *observer in observers)
            if ([observer respondsToSelector:@selector(willChangeObjectsForClass:)])
                [observer willChangeObjectsForClass:[self class]];
        
        // notify of the object creation
        
        for(NSObject<SLObjectObserving> *observer in observers) {
            
            // if the object has been deleted by an observer, no further notification to send
            if (!instance.operable)
                break;
            
            // keep track of the last observer notified of the object creation, so that reentrant
            // object operations (e.g. setting an attribute) do not reveal the object to observers
            // that have not been notified of its creation yet
            
            instance.lastObserverNotified = observer;
            if ([observer respondsToSelector:@selector(didCreateObject:remotely:)])
                [observer didCreateObject:instance remotely:FALSE];
        }
        
        instance.lastObserverNotified = nil;
    
        // notify the end of change notifications (in reverse order of registration)
        
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator])
            if ([observer respondsToSelector:@selector(didChangeObjectsForClass:)])
                [observer didChangeObjectsForClass:[self class]];
    }
    
    // schedule a sync as we have modified the database
    
    [instance.registry scheduleSync];
    
    return instance;
}


// delete marks an object instance for deletion and deletes it as soon as practical

- (void)delete
{
    NSArray             *observers;
    
    // if the object is not in an operable state, gracefully return
    
    if (![self modifiable])
        return;
    
    self.willDelete = TRUE;
    
    // set to nil all reference to the deleted object.
    // the reference list (NSCountedSet) holds strong references. It will be gradually
    // depopulated as the references are nil-ified.
    // all modified objects are marked changed and will be saved on the next sync
    
    // iterate over a copy of the reference list and value keys as they are modified by the body of the loop
    
    for(SLObject *object in [self.references copy]) {
        for (NSString *key in [object.values copy]) {
            if ([object dictionaryValueForKey:key] == self) {
                
                // nil-ify the reference through the public accessor so that proper change tracking and notification is performed
                
                [object setValue:nil forKey:key];
            }
        }
    }
    assert([self.references count] == 0);
    
    // notify the observers
    
    observers = [self.registry observersForClassWithName:self.className];
    if (observers) {
        
        BOOL        found;
        
        // notify the beginning of change notifications
        
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
            if ([observer respondsToSelector:@selector(willChangeObjectsForClass:)])
                [observer willChangeObjectsForClass:[self class]];
            
            // if this is an object operation issued from within the notification for the object creation, do not notify beyond the
            // observer notified of the object creation
            
            if (observer == self.lastObserverNotified)
                break;
        }
        
        // notify of the object deletion (in reverse order of registration)
        
        found = FALSE;
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
            
            // in case of an object operation issued from within the notification of the object creation, skip all observers that have not been notified
            
            if (!found && self.lastObserverNotified && (observer != self.lastObserverNotified))
                continue;
            found = TRUE;

            // if the object has been deleted by an observer, no further notification to send
            
            if (!self.operable)
                break;

            if ([observer respondsToSelector:@selector(willDeleteObject:remotely:)])
                [observer willDeleteObject:self remotely:FALSE];
        }
        
        // notify the end of change notifications
        
        found = FALSE;
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
            
            // in case of an object operation issued from within the notification of the object creation, skip all observers that have not been notified
            
            if (!found && self.lastObserverNotified && (observer != self.lastObserverNotified))
                continue;
            found = TRUE;
            
            if ([observer respondsToSelector:@selector(didChangeObjectsForClass:)])
                [observer didChangeObjectsForClass:[self class]];
        }
    }
    
    
    // mark the object for deletion
    
    self.deleted = TRUE;
    
    // set to nil all references this object makes to other objects.
    // we make a copy of the value keys as we're modifying the dictionary while iterating over it
    
    for(NSString *key in [self.values allKeys]) {
        id          value;
        value = [self dictionaryValueForKey:key];
        if (!value || ![SLObject isRelation:value])
            continue;
        
        // perform the change through the private accessor, as we don't want change tracking nor notifications.
        
        [self setDictionaryValue:nil forKey:key];
    }
    
    // forget about any local changes to the object
    
    self.localChanges = nil;
    
    // remove object from registry
    
    [self.registry removeObject:self];
}


#pragma mark - Private interface implementation

#pragma mark Lifecycle


// init is called when an object is created locally (with objectWithValues:) or remotely (instantiated during sync).

- (id)init
{
    self = [super init];
    
    _registry = [SLObjectRegistry sharedObjectRegistry];
    _objectID = nil;
    _className = nil;
    _databaseObject = nil;
    _values = nil;
    _references = [NSCountedSet set];
    if (!_references)
        return nil;
    _localChanges = nil;
    _remoteChanges = nil;
    _savedLocalChanges = nil;
    _lastObserverNotified = nil;
    _willDelete = FALSE;
    _deleted = FALSE;
    _index = 0;
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
    _objectID = [coder decodeObjectForKey:kSLObjectObjectIDName];
    _className = [coder decodeObjectForKey:kSLObjectClassNameName];
    _values = [coder decodeObjectForKey:kSLObjectValuesName];
    _localChanges = [coder decodeObjectForKey:kSLObjectLocalChangesName];
    _references = [coder decodeObjectForKey:kSLObjectReferencesName];
    _deleted = [coder decodeBoolForKey:kSLObjectDeletedName];
    _remoteChanges = nil;
    _willDelete = FALSE;
    _savedLocalChanges = nil;
    _index = 0;
    _createdFromCache = TRUE;
    _createdRemotely = FALSE;
    
    return self;
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
            value = self.values[key];
            if (value)
                persistedValues[key] = value;
        }
    
    [coder encodeObject:self.objectID forKey:kSLObjectObjectIDName];
    [coder encodeObject:self.className forKey:kSLObjectClassNameName];
    [coder encodeObject:persistedValues forKey:kSLObjectValuesName];
    [coder encodeObject:self.localChanges forKey:kSLObjectLocalChangesName];
    [coder encodeObject:self.references forKey:kSLObjectReferencesName];
    [coder encodeBool:self.deleted forKey:kSLObjectDeletedName];
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


// accessor functions for dynamic object attributes

// dynamicValueForKey: is the implementation of the getter accessors for object properties of all storage classes.
// the getter accessors are dynamically added to a subclass when it registers with SyncLib

- (id)dynamicValueForKey:(NSString *)key
{
    if (!self.operable)
        return nil;
    
    return [self dictionaryValueForKey:key];
}

// dynamicSetValueForKey:logChange: is the implementation of the setter accessors for object properties of all storage
// classes. the setter accessors are dynamically added to a subclass when it registers with SyncLib.
// the logChange flag indicates whether the change should be logged. the flag is set for cloud persisted properties,
// not for others.

- (void)dynamicSetValue:(id)value forKey:(NSString *)key logChange:(BOOL)withChange
{
    id              oldValue;
    NSArray         *observers;
    BOOL            found;
    
    if (!self.modifiable)
        return;
    
    // if the value is a relation and the referenced object has been deleted, change the value to nil.
    // all references to an object are set to nil when the object is deleted. However it is still possible for
    // code to keep a strong pointer to the object after it is deleted. This covers this situation and ensures
    // that the relation is set to nil.
    
    if ([SLObject isRelation:value] && ![(SLObject *)value operable])
        value = nil;

    // retrieve the current (old) value

    oldValue = [self dictionaryValueForKey:key];
    
    // if value isn't changed, nothing to do
    
    if ((oldValue == value) || (value && [value isEqual:oldValue]))
        return;
    
    // don't log the change if 1) the object is new and hasn't been uploaded to the database yet (no need for property-level reconciliation)
    // or 2) the property set is not of the cloud persisted storage class
    
    if (self.objectID && withChange) {
        
        [SLChange changeWithObject:self local:TRUE key:key oldValue:oldValue newValue:value when:[NSDate date]];
    
    }
    
    // notify the observers, part I
    
    observers = [self.registry observersForClassWithName:self.className];
    if (observers) {
        
        // notify the beginning of change notifications
        
        for(NSObject<SLObjectObserving> *observer in observers) {
            if ([observer respondsToSelector:@selector(willChangeObjectsForClass:)])
                [observer willChangeObjectsForClass:[self class]];
            
            // if this is an object operation issued from within the notification for the object creation, do not notify beyond the
            // observer notified of the object creation
            
            if (observer == self.lastObserverNotified)
                break;
        }
        
        // notify prior the value change (in reverse order of registration)
        
        found = FALSE;
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
            
            // in case of an object operation issued from within the notification of the object creation, skip all observers that have not been notified
            
            if (!found && self.lastObserverNotified && (observer != self.lastObserverNotified))
                continue;
            found = TRUE;
            
            // if the object has been deleted by an observer, no further notification to send
            
            if (!self.operable)
                break;
            
            if ([observer respondsToSelector:@selector(willChangeObjectValue:forKey:oldValue:newValue:remotely:)])
                [observer willChangeObjectValue:self forKey:key oldValue:oldValue newValue:value remotely:FALSE];
        }
    }
    
    // set the property to the new value
    
    [self setDictionaryValue:value forKey:key];
    
    // notify the observers, part II
    
    if (observers) {
        
        // notify after the value change
        
        for(NSObject<SLObjectObserving> *observer in observers) {
            
            // if the object has been deleted by an observer, no further notification to send
            
            if (!self.operable)
                break;
            
            if ([observer respondsToSelector:@selector(didChangeObjectValue:forKey:oldValue:newValue:remotely:)])
                [observer didChangeObjectValue:self forKey:key oldValue:oldValue newValue:value remotely:FALSE];
            
            // if this is an object operation issued from within a notification for the object creation, do not notify beyond the
            // observer notified of the object creation
            
            if (observer == self.lastObserverNotified)
                break;
        }
        
        // notify the end of change notifications (in reverse order of registration)
        
        found = FALSE;
        for(NSObject<SLObjectObserving> *observer in [observers reverseObjectEnumerator]) {
            
            // if the object has been deleted by an observer, no further notification to send

            if (!found && self.lastObserverNotified && (observer != self.lastObserverNotified))
                continue;
            found = TRUE;
            if ([observer respondsToSelector:@selector(didChangeObjectsForClass:)])
                [observer didChangeObjectsForClass:[self class]];
        }
    }
    
    // schedule a sync soon if we just modified a cloud persisted property
    
    if ([[self.registry cloudPersistedPropertiesForClassWithName:self.className] containsObject:key])
        [self.registry scheduleSync];
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


// retrieve a dictionary value
// [NSNUll null] values are converted to nil

- (id)dictionaryValueForKey:(NSString *)key
{
    id      value;
    
    // lookup the value directory
    // this is nil if the value hasn't been set before
    
    value = self.values[key];
    
    // convert from NSNull back to nil if needed
    
    if ((id)value == [NSNull null])
        value = nil;
    return value;
}


// store a dictionary value
// nil values are convert to [NSNUll null]
// reference lists are maintained

- (void)setDictionaryValue:(id)value forKey:(NSString *)key
{
    id          oldValue;
    SLObject    *relation;
    
    // retrieve the old (current) value and convert from NSNull back to nil if needed
    
    oldValue = [self dictionaryValueForKey:key];
    if ((id)oldValue == [NSNull null])
        oldValue = nil;
    
    // maintain the reference lists
    
    if ([SLObject isRelation:oldValue]) {
        relation = (SLObject *)oldValue;
        [relation.references removeObject:self];
    }
    
    if ([SLObject isRelation:value]) {
        relation = (SLObject *)value;
        [relation.references addObject:self];
    }
    
    // convert nil values to [NSNull null];
    
    if (!value)
        value = [NSNull null];

    self.values[key] = value;
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
    
    [registry addObject:instance];
    
    return instance;
}


// populatWithDictionary: assign a value directory to an object. this is the second part of remote object instantiation

- (void)populateWithDictionary:(NSDictionary *)databaseDictionary
{
    // instantiate the dictionary value
    
    self.values = [NSMutableDictionary dictionary];
    
    // iterate over the database values and populate the dictionary
    
    for (NSString *key in databaseDictionary) {
        id value;
        
        value = [self databaseToDictionaryValue:databaseDictionary[key]];
        [self setDictionaryValue:value forKey:key];
    }
    
}

@end