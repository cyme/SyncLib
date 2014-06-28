//
//  SLTransactionDecoding.h
//  ShoppingList
//
//  Created by Cyril Meurillon on 6/19/14.
//  Copyright (c) 2014 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SLTransaction.h"

@protocol SLTransactionDecoding <NSObject>

- (SLTransactionBlock)decodeTransactionWithIdentifier:(NSString *)identifier context:(NSDictionary *)context;

@end
