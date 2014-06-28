//
//  SLTransaction.h
//
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^SLTransactionBlock)();
@protocol SLTransactionDecoding;

@interface SLTransaction : NSObject <NSCoding>

+ (id)transactionInBackgroundWithBlock:(SLTransactionBlock)block;
+ (id)speculativeTransactionWithBlock:(SLTransactionBlock)block;                 // exposes transient states outside transaction block

+ (void)setTransactionDecoder:(id<SLTransactionDecoding>)decoder;

- (void)prepareForEncoderWithIdentifier:(NSString *)identifier context:(NSDictionary *)context;

@end
