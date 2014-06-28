//
//  SLTransactionManager.h
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SLTransaction.h"

@interface SLTransactionManager : NSObject <NSCoding>

+ (SLTransactionManager *)sharedTransactionManager;

- (void)registerTransaction:(SLTransaction *)transaction;
- (void)unregisterTransaction:(SLTransaction *)transaction;
- (void)setTransactionDecoder:(id<SLTransactionDecoding>)decoder;

- (SLTransaction *)currentTransaction;
- (void)pushTransaction:(SLTransaction *)transaction;
- (void)popTransaction;
- (void)addUncommittedTransaction:(SLTransaction *)transaction;
- (void)removeUncommittedTransaction:(SLTransaction *)transaction;
- (void)insertPendingTransaction:(SLTransaction *)transaction;
- (void)addPendingTransaction:(SLTransaction *)transaction;
- (void)removePendingTransaction:(SLTransaction *)transaction;

- (void)runPendingTransactions;
- (NSArray *)voidedChanges;
- (NSArray *)confirmedChanges;

@end
