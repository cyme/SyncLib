//
//  SLTransactionManager.m
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import "SLTransactionManager.h"
#import "SLTransaction-Internal.h"
#import "SLObjectRegistry.h"
#import "SLObject-Internal.h"
#import "SLChange.h"

static NSString * const kSLTransactionManagerRegisteredTransactionsKey = @"SLTMRegisteredTransactions";

@interface SLTransactionManager ()

// list of running transactions. this is a stack of nested transactions presently running

@property (nonatomic) NSMutableArray                    *currentTransactions;

// list of transactions that have been submitted but have yet to be run

@property (nonatomic) NSMutableOrderedSet               *pendingTransactions;

// list of transactions that have been speculatively run and waiting to be either committed or retried

@property (nonatomic) NSMutableOrderedSet               *uncommittedTransactions;

// list of registered transaction

@property (nonatomic) NSMutableOrderedSet               *registeredTransactions;

// list of decoded transactions

@property (nonatomic) NSMutableOrderedSet               *encodedTransactions;

// transaction decoder

@property (nonatomic, weak) id<SLTransactionDecoding>   decoder;


- (void)decodeTransactions;

@end


@implementation SLTransactionManager

#pragma mark - Internal Methods

+ (SLTransactionManager *)sharedTransactionManager
{
    static SLTransactionManager     *transactionMgr = nil;
    static dispatch_once_t  onceToken;
    
    // check if the registry needs to be initialized
    
    if (!transactionMgr)
        
        // initialize the registry in a thread-safe manner
        // this really isn't necessary given that the library currently isn't thread safe, but it's fun anyway
        
        dispatch_once(&onceToken, ^{
            
            // registry is a (static) global, therefore it does not need to be declared __block
            
            transactionMgr = [[SLTransactionManager alloc] init];
            
        });
    return transactionMgr;
}

// bring back to life the transaction manager from the disk cache

- (id)initWithCoder:(NSCoder *)aDecoder
{
    // the transaction manager is a singleton class. we use the existing instance if it
    // has already been created.
    
    self = [SLTransactionManager sharedTransactionManager];
    assert(self);
    
    // unarchive the dictionary of transactions with identifiers.
    // the transactions won't be functional until they are decoded.
    
    self.encodedTransactions = [aDecoder decodeObjectForKey:kSLTransactionManagerRegisteredTransactionsKey];

    [self decodeTransactions];

    return self;
}

// encode the state of the transaction manager to save to disk

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeObject:self.registeredTransactions forKey:kSLTransactionManagerRegisteredTransactionsKey];
}

- (void)registerTransaction:(SLTransaction *)transaction
{
    [self.registeredTransactions addObject:transaction];
}

- (void)unregisterTransaction:(SLTransaction *)transaction
{
    assert([self.registeredTransactions containsObject:transaction]);
    [self.registeredTransactions removeObject:transaction];
}

- (void)setTransactionDecoder:(id<SLTransactionDecoding>)decoder
{
    self.decoder = decoder;
    [self decodeTransactions];
}

- (SLTransaction *)currentTransaction
{
    return [self.currentTransactions lastObject];
}

- (void)pushTransaction:(SLTransaction *)transaction
{
    [self.currentTransactions addObject:transaction];
}

- (void)popTransaction
{
    [self.currentTransactions removeLastObject];
}

- (void)addUncommittedTransaction:(SLTransaction *)transaction
{
    [self.uncommittedTransactions addObject:transaction];
}

- (void)removeUncommittedTransaction:(SLTransaction *)transaction
{
    [self.uncommittedTransactions removeObject:transaction];
}

- (void)insertPendingTransaction:(SLTransaction *)transaction
{
    [self.pendingTransactions insertObject:transaction atIndex:0];
}

- (void)addPendingTransaction:(SLTransaction *)transaction
{
    [self.pendingTransactions addObject:transaction];
}

- (void)removePendingTransaction:(SLTransaction *)transaction
{
    [self.pendingTransactions removeObject:transaction];
}

- (void)runPendingTransactions
{
    for(SLTransaction *transaction in self.pendingTransactions)
        [transaction execute];
    [self.pendingTransactions removeAllObjects];
}

- (NSArray *)voidedChanges
{
    NSMutableArray                  *voidedChanges;
    BOOL                            needSync;
    
    needSync = FALSE;
    voidedChanges = [NSMutableArray array];
    assert(voidedChanges);
    
    // unroll voided transactions in reverse chronological order
    
    for(SLTransaction *transaction in [[self.uncommittedTransactions copy] reverseObjectEnumerator]) {
        if (!transaction.voided)
            continue;
        
        // this transaction has been voided
        
        [transaction completeVoiding:voidedChanges];
        
        // move the voided transaction from the uncommitted list to the pending list so that it
        // is run again. do this in a manner to maintain the chronological order

        [self removeUncommittedTransaction:transaction];
        [self insertPendingTransaction:transaction];
        
        // remember we need to execute the transaction again
        
        needSync = TRUE;
    }

    // sort the voided changes in reverse chronological order
    
    [voidedChanges sortedArrayUsingComparator: ^ NSComparisonResult (SLChange *changeA, SLChange *changeB) {
        return [changeB compareTimeStamp:changeA];
    }];
    
    // we apply the voided changes in chronological order so that they can be unrolled in reverse chronological order
    
    for(SLChange *change in [voidedChanges reverseObjectEnumerator]) {
        [change.object setDictionaryValue:change.nValue forKey:change.key speculative:FALSE change:nil];
    }
    
    // schedule a sync if any transaction was voided so that it can be executed again
    
    if (needSync)
        [[SLObjectRegistry sharedObjectRegistry] scheduleSync];
    
    return voidedChanges;
}

- (NSArray *)confirmedChanges
{
    NSMutableArray                  *confirmedChanges;
    
    confirmedChanges = [NSMutableArray array];
    assert(confirmedChanges);
    
    // confirm all changes that have not been voided, in chronological order
    
    for(SLTransaction *transaction in [self.uncommittedTransactions copy]) {
        if (transaction.voided)
            continue;
        
        // this transaction is confirmed
        // let's commit the speculative changes.
        
        [transaction commit:confirmedChanges];
        
        // remove the transaction from the uncommitted transaction list
        
        [self removeUncommittedTransaction:transaction];
    }
    
    // sort the changes in chronological order
    
    [confirmedChanges sortedArrayUsingComparator: ^ NSComparisonResult (SLChange *changeA, SLChange *changeB) {
        return [changeA compareTimeStamp:changeB];
    }];
    
    return confirmedChanges;
}


#pragma mark - Private methods

- (id)init
{
    self = [super init];
    assert(self);
    
    _currentTransactions = [NSMutableArray array];
    assert(_currentTransactions);
    _pendingTransactions = [NSMutableOrderedSet orderedSet];
    assert(_pendingTransactions);
    _uncommittedTransactions = [NSMutableOrderedSet orderedSet];
    assert(_uncommittedTransactions);
    _registeredTransactions = [NSMutableOrderedSet orderedSet];
    assert(_registeredTransactions);
    _encodedTransactions = nil;
    
    return self;
}

- (void)decodeTransactions
{
    if (!self.decoder)
        return;
    
    for(SLTransaction *transaction in self.encodedTransactions) {
        [transaction decodeWithDecoder:self.decoder];
        [self registerTransaction:transaction];
        if (transaction.speculative) {
            [transaction execute];
        } else {
            [self addPendingTransaction:transaction];
        }
    }
    self.encodedTransactions = nil;
}

@end
