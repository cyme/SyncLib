//
//  SLObject-Internal.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLObject.h"


// this is the private side of SLObject

@class PFObject;
@class SLObjectRegistry;
@class SLChange;
@class SLTransaction;
@protocol SLObjectObserving;


@interface SLObject ()

@property (nonatomic) NSString                      *objectID;
@property (nonatomic) PFObject                      *databaseObject;
@property (nonatomic) NSObject <SLObjectObserving>  *lastObserverNotified;
@property NSUInteger                                depth;


// Create an instance from an existing database object with an empty value dictionary.
// Calls to objectFromExistingWithClassName:objectID: need to be paired with a call to populateDictionary:

+ (SLObject *)objectFromExistingWithClassName:(NSString *)className objectID:(NSString *)objectID;

// Populate the object attributes, including relations. This is the 2nd phase of local object replication. The
// dictionary contains database key-value pairs. In the case of Value is the objectId of the pointed-to object.

- (void)populateWithDictionary: (NSDictionary *)dbDictionary;

// delete helper functions

- (void)startDeletion;
- (void)handleTransactionsForDeletedObject:(BOOL)local;
- (void)completeDeletion;

// Returns whether the object instance is operable, i.e. can receive a user-sent message

- (BOOL)operable;

// Returns whether the object instance can be modified. Objects in the process of being deleted cannot be modified (written to or deleted).

- (BOOL)modifiable;

// generate the property accessors for a subclass

+ (void)generateDynamicAccessors;

// generates the list of subclass property names

+ (NSArray *)allProperties;

// manage the object change lists

- (void)saveLocalChanges;
- (void)doneWithSavedLocalChanges:(BOOL)merge;
- (void)removeAllRemoteChanges;

- (void)addChange:(SLChange *)change;
- (void)removeChange:(SLChange *)change;

- (NSArray *)uncommittedKeys;
- (SLChange *)lastUncommittedChangeForKey:(NSString *)key;

// manage the object transaction list

- (void)addReferenceCapturingTransaction:(SLTransaction *)transaction;
- (void)removeReferenceCapturingTransaction:(SLTransaction *)transaction;
- (void)addCapturingTransaction:(SLTransaction *)transaction forKey:(NSString *)key;
- (void)removeCapturingTransaction:(SLTransaction *)transaction forKey:(NSString *)key;
- (NSOrderedSet *)capturingTransactionsForKey:(NSString *)key;

// access the reference lists

- (NSArray *)referencingObjects;
- (NSSet *)referencingKeysForObject:(SLObject *)object;

- (void)voidKeyCapturingTransactions;
- (void)voidTransactionsCapturingKey:(NSString *)key;

// read-only property accessors

- (NSDictionary *)localChanges;
- (NSDictionary *)savedLocalChanges;
- (NSDictionary *)remoteChanges;
- (NSString *)className;
- (BOOL)createdFromCache;
- (BOOL)createdRemotely;
- (BOOL)deleted;

// Utility methods to set and retrieve dictionary values

- (NSArray *)dictionaryKeys;

- (id)dictionaryValueForKey:(NSString *)key useSpeculative:(BOOL)useSpeculative wasSpeculative:(BOOL *)wasSpeculative capture:(BOOL)capture;
- (void)setDictionaryValue:(id)value forKey:(NSString *)key speculative:(BOOL)speculative change:(SLChange *)change;

// Utility methods to convert between dictionary and database values

- (id)dictionaryToDatabaseValue:(id)value;
- (id)databaseToDictionaryValue:(id)value;

// Utility methods to test whether an attribute is a relation

+ (BOOL)isDBRelation:(id)attribute;
+ (BOOL)isRelation:(id)attribute;

@end