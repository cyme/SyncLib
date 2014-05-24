//
//  SLObject_Private.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLObject.h"


// this is the private side of SLObject

@class PFObject;
@class SLObjectRegistry;
@protocol SLObjectObserving;

#define LOCALCHANGES            (1)
#define REMOTECHANGES           (0)


@interface SLObject ()

@property (nonatomic, weak) SLObjectRegistry        *registry;
@property (nonatomic) NSString                      *objectID;
@property (nonatomic) NSString                      *className;
@property (nonatomic) PFObject                      *databaseObject;
@property (nonatomic) NSMutableDictionary           *values;
@property (nonatomic) NSMutableDictionary           *localChanges;
@property (nonatomic) NSMutableDictionary           *remoteChanges;
@property (nonatomic) NSMutableDictionary           *savedLocalChanges;
@property (nonatomic) NSCountedSet                  *references;
@property (nonatomic) NSObject <SLObjectObserving>  *lastObserverNotified;
@property BOOL                                      willDelete;
@property BOOL                                      deleted;
@property BOOL                                      createdFromCache;
@property BOOL                                      createdRemotely;
@property NSUInteger                                index;


- (id) init;

// NSCoding protocol functions

- (id)initWithCoder:(NSCoder *)coder;
- (void)encodeWithCoder:(NSCoder *)coder;

// Create an instance from an existing database object with an empty value dictionary.
// Calls to objectFromExistingWithClassName:objectID: need to be paired with a call to populateDictionary:

+ (SLObject *)objectFromExistingWithClassName:(NSString *)className objectID:(NSString *)objectID;

// Populate the object attributes, including relations. This is the 2nd phase of local object replication. The
// dictionary contains database key-value pairs. In the case of Value is the objectId of the pointed-to object.

- (void)populateWithDictionary: (NSDictionary *)dbDictionary;

// Returns whether the object instance is operable, i.e. can receive a user-sent message

- (BOOL)operable;

// Returns whether the object instance can be modified. Objects in the process of being deleted cannot be modified (written to or deleted).

- (BOOL)modifiable;

// generate the property accessors for a subclass

+ (void)generateDynamicAccessors;

// generates the list of subclass property names

+ (NSArray *)allProperties;

// dynamic accessors for properties

- (id)dynamicValueForKey:(NSString *)key;
- (void)dynamicSetValue:(id)value forKey:(NSString *)key logChange:(BOOL)change;

// Utility methods to set and retrieve dictionary values

- (id)dictionaryValueForKey:(NSString *)key;
- (void)setDictionaryValue:(id)value forKey:(NSString *)key;

// Utility methods to convert between dictionary and database values

- (id)dictionaryToDatabaseValue:(id)value;
- (id)databaseToDictionaryValue:(id)value;

// Utility methods to test whether a attribute is a relation (SLObject *) or a database relation (PFObject *)

+ (BOOL)isDBRelation:(id)attribute;
+ (BOOL)isRelation:(id)attribute;

@end

extern NSString *kSLObjectObjectIDName;
extern NSString *kSLObjectClassNameName;
extern NSString *kSLObjectValuesName;
extern NSString *kSLObjectChangesName;
extern NSString *kSLObjectReferencesName;
extern NSString *kSLObjectDeletedName;


