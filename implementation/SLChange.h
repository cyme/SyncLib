//
//  SLChange.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>


// SLWrite is the class that capture a write operation to an object property. All writes to object properties that need to be logged
// are captured in a SLWrite instance

@class SLObject;
@class SLTransaction;

@interface SLChange : NSObject <NSCoding>

@property (nonatomic, weak) SLObject        *object;
@property (nonatomic) NSString              *key;
@property (nonatomic) NSDate                *timeStamp;
@property (nonatomic) uint64_t              counter;
@property (nonatomic) id                    oValue;
@property (nonatomic) id                    nValue;
@property BOOL                              local;
@property (weak, nonatomic) SLTransaction   *issuingTransaction;
@property (nonatomic) NSMutableSet          *capturingTransactions;

// Lifecycle management

+ (id)localChangeWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue;
+ (id)remoteChangeWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue timeStamp:(NSDate *)timeStamp;
+ (id)transactionChangeWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue transaction:(SLTransaction *)transaction;

- (void)commit;
- (void)detach;

- (void)addCapturingTransaction:(SLTransaction *)transaction;
- (void)removeCapturingTransaction:(SLTransaction *)transaction;

- (void)updateTimeStamp;
- (NSComparisonResult)compareTimeStamp:(SLChange *)otherChange;
- (NSComparisonResult)compareTimeStampToDate:(NSDate *)date;

// NSCoding protocol functions

- (id)initWithCoder:(NSCoder *)coder;
- (void)encodeWithCoder:(NSCoder *)coder;

@end