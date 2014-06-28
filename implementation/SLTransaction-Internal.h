//
//  SLTransaction-Internal.h
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SLTransaction.h"

@class SLObject;
@class SLChange;

@interface SLTransaction ()

+ (id)speculativeTransaction;

- (void)decodeWithDecoder:(id<SLTransactionDecoding>)decoder;

- (void)captureKey:(NSString *)key forObject:(SLObject *)object;
- (void)captureReference:(SLObject *)object;

- (SLChange *)changeForObject:(SLObject *)object key:(NSString *)key;
- (void)addChange:(SLChange *)change;
- (void)removeChange:(SLChange *)change;

- (void)forgetCapturedKeysForObject:(SLObject *)object;
- (void)forgetUncommittedKeysForObject:(SLObject *)object;

- (void)execute;
- (void)markVoided;
- (void)completeVoiding:(NSMutableArray *)voidedChanges;
- (void)commit:(NSMutableArray *)confirmedChanges;

// getter for read-only property

- (BOOL)speculative;
- (BOOL)voided;

@end
