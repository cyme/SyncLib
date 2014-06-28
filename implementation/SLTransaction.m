//
//  SLTransaction.m
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import "SLTransaction-Internal.h"
#import "SLTransactionManager.h"
#import "SLObject-Internal.h"
#import "SLObjectRegistry.h"
#import "SLChange.h"
#import "SLClientManager-Internal.h"
#import "SLTransactionDecoding.h"

static NSString * const kSLTransactionSpeculativeKey = @"SLTSpeculative";
static NSString * const kSLTransactionRunCountKey = @"SLTRunCount";
static NSString * const kSLTransactionContextKey = @"SLTContext";
static NSString * const kSLTransactionIdentifierKey = @"SLTIdentifier";


@interface SLTransaction ()

@property (nonatomic, weak) SLTransactionManager    *transactionManager;
@property (nonatomic, strong) SLTransactionBlock    transactionBlock;
@property (nonatomic, strong) void                  (^completionBlock)();

@property (readwrite) BOOL                          speculative;
@property BOOL                                      voided;
@property BOOL                                      completed;
@property NSInteger                                 runCount;

// dictionary of object properties captured by this transaction
// key is object, value is a NSMutableDictionary of (property key - SLChange)
// SLChange is the transactional change captured or [NSNull null] if the value captured is committed

@property (nonatomic) NSMapTable                    *capturedObjectKeyChanges;

// list of references (referenced objects) this transaction captures

@property (nonatomic) NSMutableSet                  *capturedReferences;

// dictionary of uncommitted changes to object properties executed by this transaction
// key is object, value is a NSMutableDictionary of (property key - SLChange) pairs

@property (nonatomic) NSMapTable                    *uncommittedChanges;

// list of transactions that depend on the output of this transaction (read-after-write dependencies)

@property (nonatomic) NSCountedSet                  *dependingTransactions;

// properties for serialization operations

@property (nonatomic) NSDictionary                  *context;
@property (nonatomic) NSString                      *identifier;


+ (id)transactionWithBlock:(void(^)())block speculative:(BOOL)speculative;

@end

@implementation SLTransaction

#pragma mark - Public Methods

+ (id)transactionInBackgroundWithBlock:(void(^)())block
{
    SLTransaction       *transaction;
    SLObjectRegistry    *registry;
    
    registry = [SLObjectRegistry sharedObjectRegistry];
    if ([registry inNotification]) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"transaction created in a notification handler"
                                          userInfo:nil];
        @throw exception;
        return nil;
    }
    
    if (![SLClientManager sharedClientManager].syncing) {
        block();
        return nil;
    }
    
    transaction = [SLTransaction transactionWithBlock:block speculative:FALSE];
    [transaction.transactionManager addPendingTransaction:transaction];
    
    // schedule a sync to execute the transaction
    
    [registry scheduleSync];
    
    return transaction;
}

+ (id)speculativeTransactionWithBlock:(void(^)())block
{
    SLTransaction       *transaction;
    
    if ([[SLObjectRegistry sharedObjectRegistry] inNotification]) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"transaction created in a notification handler"
                                          userInfo:nil];
        @throw exception;
        return nil;
    }

    if (![SLClientManager sharedClientManager].syncing) {
        block();
        return nil;
    }

    transaction = [SLTransaction transactionWithBlock:block speculative:TRUE];
    [transaction execute];
    return transaction;
}

+ (void)setTransactionDecoder:(id<SLTransactionDecoding>)decoder
{
    [[SLTransactionManager sharedTransactionManager] setTransactionDecoder:decoder];
}

- (void)decodeWithDecoder:(id<SLTransactionDecoding>)decoder
{
    self.transactionBlock = [decoder decodeTransactionWithIdentifier:self.identifier context:self.context];
    if (!self.transactionBlock) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"transaction decoder returned nil block"
                                          userInfo:nil];
        @throw exception;
        return;
    }
}

- (void)prepareForEncoderWithIdentifier:(NSString *)identifier context:(NSDictionary *)context
{
    if (self.completed)
        return;
    if (self.identifier)
        return;
    if (!identifier) {
        NSException     *exception;
        exception = [NSException exceptionWithName:NSInvalidArgumentException
                                            reason:@"prepareForEncoderWithIdentifier:context: called with no identifier"
                                          userInfo:nil];
        @throw exception;
        return;
    }
    
    [self.transactionManager registerTransaction:self];
    self.context = context;
    self.identifier = identifier;
}

#pragma mark - Internal Methods

#pragma mark Lifecycle Management

+ (id)speculativeTransaction
{
    return [SLTransaction transactionWithBlock:nil speculative:TRUE];
}

// initWithCoder: is called when a transaction is brought back to life from the device cache, at application startup time.

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    
    _transactionManager = [SLTransactionManager sharedTransactionManager];
    _transactionBlock = nil;
    _completionBlock = nil;
    _speculative = [coder decodeBoolForKey:kSLTransactionSpeculativeKey];
    _voided = FALSE;
    _completed = FALSE;
    
    _runCount = [coder decodeIntegerForKey:kSLTransactionRunCountKey];
    
    _capturedObjectKeyChanges = [NSMapTable strongToStrongObjectsMapTable];
    assert(_capturedObjectKeyChanges);
    _capturedReferences = [NSMutableSet set];
    assert(_capturedReferences);
    _uncommittedChanges = [NSMapTable strongToStrongObjectsMapTable];
    assert(_uncommittedChanges);
    _dependingTransactions = [NSCountedSet set];
    assert(_dependingTransactions);

    _context = [coder decodeObjectForKey:kSLTransactionContextKey];
    _identifier = [coder decodeObjectForKey:kSLTransactionIdentifierKey];
    
    return self;
}

// encode a transaction to save to the local cache file. Only transactions that have an identifier are archived.

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (!self.identifier)
        return;
    
    // the transaction may be in the pending or uncommitted state
    // if it is uncommitted (executed but uncommitted), the uncommitted state of the transaction and associated object
    // is not archived. The transaction will be put in the pending state when it is unarchived and decoded.
    
    [coder encodeBool:self.speculative forKey:kSLTransactionSpeculativeKey];
    [coder encodeInteger:self.runCount forKey:kSLTransactionRunCountKey];
    [coder encodeObject:self.context forKey:kSLTransactionContextKey];
    [coder encodeObject:self.identifier forKey:kSLTransactionIdentifierKey];
}

#pragma mark Object Management

- (void)captureKey:(NSString *)key forObject:(SLObject *)object
{
    NSMutableDictionary     *capturedKeyChanges;
    SLChange                *change;
    
    // dont capture the key if it is already captured

    capturedKeyChanges = [self.capturedObjectKeyChanges objectForKey:object];
    if (!capturedKeyChanges) {
        capturedKeyChanges = [NSMutableDictionary dictionary];
        assert(capturedKeyChanges);
        [self.capturedObjectKeyChanges setObject:capturedKeyChanges forKey:object];
    } else {
        if (capturedKeyChanges[key])
            return;
    }

    // we can capture the key now.
    // note that this remains correct if the key has already been modified by the transaction
    // (read after write). See the following scenario:
    //      transaction writes an object key
    //      transaction reads the same object key
    //      transaction takes actions based on the value of the object key
    //      the object is noted as remotely deleted at the next sync
    //      -> the transaction must be voided as the transaction outcome is impacted by the remote
    //         deletion
    
    change = [object lastUncommittedChangeForKey:key];
    if (change) {
        capturedKeyChanges[key] = change;
        [change addCapturingTransaction:self];
    } else
        capturedKeyChanges[key] = [NSNull null];
}

- (void)captureReference:(SLObject *)object
{
    [self.capturedReferences addObject:object];
}

- (void)addChange:(SLChange *)change
{
    NSMutableDictionary *changes;
    SLObject            *object;
    NSString            *key;
    
    assert(change.issuingTransaction == self);
    object = change.object;
    key = change.key;
    changes = [self.uncommittedChanges objectForKey:object];
    if (!changes) {
        changes = [NSMutableDictionary dictionary];
        assert(changes);
        [self.uncommittedChanges setObject:changes forKey:object];
    }
    changes[key] = change;
}

- (void)removeChange:(SLChange *)change
{
    NSMutableDictionary *changes;
    SLObject            *object;
    NSString            *key;
    
    assert(change.issuingTransaction == self);
    object = change.object;
    key = change.key;
    changes = [self.uncommittedChanges objectForKey:object];
    assert(changes);
    [changes removeObjectForKey:key];
    if ([changes count] == 0)
        [self.uncommittedChanges removeObjectForKey:object];
}

- (SLChange *)changeForObject:(SLObject *)object key:(NSString *)key
{
    NSMutableDictionary     *changes;
    
    changes = [self.uncommittedChanges objectForKey:object];
    if (!changes)
        return nil;
    return changes[key];
}

- (void)forgetCapturedKeysForObject:(SLObject *)object
{
    NSDictionary        *capturedKeyChanges;

    // check if the object is being captured by this transaction

    capturedKeyChanges = [self.capturedObjectKeyChanges objectForKey:object];
    if (capturedKeyChanges) {
        
        // the object is captured by this transaction
        
        // remove the references the captured changes make to this transaction
        
        for(NSString *key in capturedKeyChanges) {
            SLChange        *change;
            
            if (capturedKeyChanges[key] == [NSNull null])
                continue;
            change = capturedKeyChanges[key];
            [change removeCapturingTransaction:self];
        }
        
        // drop the key change dictionary for the object
        
        [self.capturedObjectKeyChanges removeObjectForKey:object];
    }
}

- (void)forgetUncommittedKeysForObject:(SLObject *)object
{
    NSDictionary    *changedKeys;

    // check if the object is being modified by this transaction
    
    changedKeys = [self.uncommittedChanges objectForKey:object];
    if (changedKeys) {
        
        // the object is modified by this transaction
        
        // remove from the list of depending transactions those that have no more dependency
        // on this transaction. the list of depending transactions is a NSCountedSet collection
        // and propertly remove the transaction from the list when there are no more dependencies.
        
        for(SLObject *object in self.uncommittedChanges) {
            
            NSDictionary    *keyChanges;
            
            keyChanges = [self.uncommittedChanges objectForKey:object];
            for(NSString *key in keyChanges) {
                
                SLChange    *change;
                
                change = keyChanges[key];
                for(SLTransaction *capturingTransaction in change.capturingTransactions)
                    [self.dependingTransactions removeObject:capturingTransaction];
            }
        }
        
        // drop all the changes the transaction is making to the object
        
        [self.uncommittedChanges removeObjectForKey:object];
    }
}

- (void)markVoided
{
    if (self.voided)
        return;
    self.voided = TRUE;
    assert(self.transactionBlock);
    for(SLTransaction *transaction in self.dependingTransactions)
        [transaction markVoided];
}

- (void)completeVoiding:(NSMutableArray *)voidedChanges
{
    assert(self.voided);
    
    // this transaction has been voided
    
    if (self.speculative) {
        
        // this is a speculative transaction. its changes have already been exposed to the
        // application. we add its changes to the list of changes to void so that they can
        // be unrolled and the application can be notified.
        
        for(SLObject *object in self.uncommittedChanges) {
            NSDictionary        *changes;
            
            changes = [self.uncommittedChanges objectForKey:object];
            for(NSString *key in changes) {
                
                SLChange        *change;
                
                change = changes[key];
                [voidedChanges addObject:change];
            }
        }
        
    } else {
        
        // this is an asynchronous transaction. its changes have not been exposed to the application.
        // the uncommitted values will be dropped. there's nothing to do.
        
    }
    
    // "reset" the transaction so that it can be run again later
    
    for(SLObject *object in self.capturedObjectKeyChanges) {
        NSDictionary               *capturedKeyChanges;
        
        capturedKeyChanges= [self.capturedObjectKeyChanges objectForKey:object];
        for(NSString *key in capturedKeyChanges) {
            [object removeCapturingTransaction:self forKey:key];
            if (capturedKeyChanges[key] != [NSNull null]) {
                SLChange    *change;
                
                change = capturedKeyChanges[key];
                [change removeCapturingTransaction:self];
            }
        }
    }
    
    for(SLObject *object in self.capturedReferences)
        [object removeReferenceCapturingTransaction:self];
    
    for(SLObject *object in self.uncommittedChanges) {
        NSDictionary        *uncommittedChanges;
        
        uncommittedChanges = [self.uncommittedChanges objectForKey:object];
        for(NSString *key in uncommittedChanges) {
            
            SLChange        *uncommittedChange;
            
            uncommittedChange = uncommittedChanges[key];
            [object removeChange:uncommittedChange];
        }
    }
    
    [self.capturedObjectKeyChanges removeAllObjects];
    [self.capturedReferences removeAllObjects];
    [self.uncommittedChanges removeAllObjects];
    [self.dependingTransactions removeAllObjects];
    self.voided = FALSE;
    
    // a voided transaction is not longer speculative (if it was in the first place)
    
    self.speculative = FALSE;
}

- (void)commit:(NSMutableArray *)confirmedChanges
{
    assert(!self.voided);
    
    // let's commit the speculative changes.
    
    for(SLObject *object in self.uncommittedChanges) {
        NSDictionary        *changes;
        
        changes = [self.uncommittedChanges objectForKey:object];
        for(NSString *key in changes) {
            
            SLChange        *change;
            
            change = changes[key];
            
            // commit creates an equivalent local change and leaves the uncommitted change alone
            
            [change commit];
            
            if (self.speculative) {
                
                // this is a speculative transaction. its changes have already been exposed to the
                // application. we need to do is to commit the speculative value.
                
                [object setDictionaryValue:change.nValue forKey:change.key speculative:FALSE change:nil];
                
            } else {
                
                // this is an asynchronous transaction. its changes have not been exposed to the application
                // yet. we add the changes to the list of changes to confirm so that the changes can later be
                // effected and the application notified of it.
                
                [confirmedChanges addObject:change];
            }
        }
    }
    
    // we're done with the transition. it can be safely removed from the list of uncommitted
    // transactions and deallocated.
    
    self.completed = TRUE;
    if (self.identifier)
        [self.transactionManager unregisterTransaction:self];
    
    for(SLObject *object in self.capturedObjectKeyChanges) {
        NSDictionary    *capturedKeyChanges;
        
        capturedKeyChanges = [self.capturedObjectKeyChanges objectForKey:object];
        for(NSString *key in capturedKeyChanges) {
            [object removeCapturingTransaction:self forKey:key];
            if (capturedKeyChanges[key] != [NSNull null]) {
                SLChange    *change;
                
                change = capturedKeyChanges[key];
                [change removeCapturingTransaction:self];
            }
        }
    }
    
    for(SLObject *object in self.capturedReferences)
        [object removeReferenceCapturingTransaction:self];
    
    for(SLObject *object in self.uncommittedChanges) {
        NSDictionary        *uncommittedChanges;
        
        uncommittedChanges = [self.uncommittedChanges objectForKey:object];
        for(NSString *key in uncommittedChanges) {
            
            SLChange        *uncommittedChange;
            
            uncommittedChange = uncommittedChanges[key];
            [object removeChange:uncommittedChange];
        }
    }
    
    // set all collection objects to nil to break the retain cycles and allow for self to be deallocated
    
    self.capturedObjectKeyChanges = nil;
    self.capturedReferences = nil;
    self.uncommittedChanges = nil;
    self.dependingTransactions = nil;
    self.context = nil;
}

- (void)execute
{
    // push the transaction on the stack of running transactions and run it, pop it when it's done
    
    [self.transactionManager pushTransaction:self];
    self.runCount++;
    self.transactionBlock();
    [self.transactionManager popTransaction];
    
    // identify all properties captured by the transaction that are modified by a previously run transaction
    // for each such read-after-write dependency identified, add the transaction to the list of transaction
    // depending on the modifying transaction
    
    for(SLObject *object in self.capturedObjectKeyChanges) {
        NSDictionary        *keyChanges;
        
        if ([object.uncommittedKeys count] == 0)
            continue;
        
        keyChanges = [self.capturedObjectKeyChanges objectForKey:object];
        
        for(NSString *key in keyChanges) {
            SLChange            *change;
            
            if (keyChanges[key] == [NSNull null])
                continue;
            change = keyChanges[key];
            
            // add ourselves to the list of depending transactions
            // the list of depending transactions is a counted set
            
            [change.issuingTransaction.dependingTransactions addObject:self];
        }
    }
    
    // add the transaction to the list of uncommitted transactions
    
    [self.transactionManager addUncommittedTransaction:self];
}


#pragma mark - Private methods



+ (id)transactionWithBlock:(void(^)())block speculative:(BOOL)speculative
{
    SLTransaction       *instance;
    
    instance = [[SLTransaction alloc] init];
    assert(instance);
    instance.transactionManager = [SLTransactionManager sharedTransactionManager];
    instance.transactionBlock = block;
    instance.completionBlock = nil;
    instance.capturedObjectKeyChanges = [NSMapTable strongToStrongObjectsMapTable];
    assert(instance.capturedObjectKeyChanges);
    instance.capturedReferences = [NSMutableSet set];
    assert(instance.capturedReferences);
    instance.uncommittedChanges = [NSMapTable strongToStrongObjectsMapTable];
    assert(instance.uncommittedChanges);
    instance.dependingTransactions = [NSCountedSet set];
    assert(instance.dependingTransactions);
    instance.speculative = speculative;
    instance.voided = FALSE;
    instance.completed = FALSE;
    instance.identifier = nil;
    instance.context = nil;
    
    return instance;
}

@end
