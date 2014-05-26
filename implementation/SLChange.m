//
//  SLChange.m
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLChange.h"
#import "SLObject_Private.h"
#import "SLObjectRegistry.h"


NSString *kSLChangeObjectName = @"SLCObject";
NSString *kSLChangeWhenName = @"SLCWhen";
NSString *kSLChangeKeyName = @"SLCKey";
NSString *kSLChangeOValueName = @"SLCOvalue";
NSString *kSLChangeNValueName = @"SLCNValue";

@interface SLChange ()

- (id) initWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue local:(BOOL)local date:(NSDate*)date;

@end


@implementation SLChange

#pragma mark - Lifecycle management


// initialize an empty SLChange object

- (id)initWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue local:(BOOL)local date:(NSDate*)date
{
    self = [super init];
    
    _object = object;
    _key = key;
    _oValue = oldValue;
    _nValue = newValue;
    _local = local;
    _when = date;
    
    return self;
}


// log a new property change. this may or may not create a new SLChange object, as necessary.

+ (id)changeWithObject:(SLObject *)object local:(BOOL)local key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue when:(NSDate*)date
{
    NSMutableDictionary *changes;
    NSMutableDictionary *oppositeChanges;
    SLChange            *change;
    SLObjectRegistry    *registry;
 
    registry = object.registry;

    // check whether there's already a change recorded for this key
    // if not, create a new change object
    
    if (local) {
        if (!object.localChanges) {
            object.localChanges = [NSMutableDictionary dictionary];
            if (!object.localChanges)
                return nil;
        }
        changes = object.localChanges;
        oppositeChanges = object.remoteChanges;
        assert(!object.remoteChanges[key]);
    } else {
        if (!object.remoteChanges) {
            object.remoteChanges = [NSMutableDictionary dictionary];
            if (!object.remoteChanges)
                return nil;
        }
        changes = object.remoteChanges;
        oppositeChanges = object.localChanges;
        assert(!object.localChanges[key]);
    }

    change = changes[key];
    if (!change) {
        
        // if no change exist for this key, create one

        change = [[SLChange alloc] initWithObject:object key:key oldValue:oldValue newValue:newValue local:local date:date];
        changes[key] = change;
        
    } else {
        
        // if a change exist for this key, and the change is being "undone", drop the change object and return nil
        
        if (change.oValue == newValue) {
            [changes removeObjectForKey:key];
            return nil;
        }
        
        // record the new value
        
        change.nValue = newValue;
        change.when = date;
    }
    
    // check whether there's a change recorded for this key of the opposite type
    // i.e. whether there's a local change for the same key when logging a remote change
    // or a remote change for the same key when logging a local change
    // if that's the case, the other change is dropped
    
    change = oppositeChanges[key];
    if (change)
        [change detachFromObject];
    
    // remember the object was modified
    
    [registry markObjectModified:object local:local];
    
    return change;
}


// detach a SLChange instance from its object. ARC is taking care of deallocating it.

- (void)detachFromObject
{
    NSMutableDictionary     *changes;
    SLObject                *object;
    
    object = self.object;
    if (self.local)
        changes = object.localChanges;
    else
        changes = object.remoteChanges;
 
    [changes removeObjectForKey:self.key];
    
    // drop the object from the modified list if no more change left for this object
    
    if ([changes count] == 0)
        [object.registry markObjectUnmodified:object local:self.local];
}


// NSCoding protocol methods. SLChange objects are archived when writing the device cache, and unarchived when reading it.

#pragma mark - NSCoding protocol methods

// unarchive an SLChange object

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    
    _object = [coder decodeObjectForKey:kSLChangeObjectName];
    _when = [coder decodeObjectForKey:kSLChangeWhenName];
    _key = [coder decodeObjectForKey:kSLChangeKeyName];
    _oValue = [coder decodeObjectForKey:kSLChangeOValueName];
    _nValue = [coder decodeObjectForKey:kSLChangeNValueName];
    _local = TRUE;
    return self;
}


// archive a SLChange object

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.object forKey:kSLChangeObjectName];
    [coder encodeObject:self.when forKey:kSLChangeWhenName];
    [coder encodeObject:self.key forKey:kSLChangeKeyName];
    [coder encodeObject:self.oValue forKey:kSLChangeOValueName];
    [coder encodeObject:self.nValue forKey:kSLChangeNValueName];
}


@end
