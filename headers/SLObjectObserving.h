//
//  SLObjectDelegate.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SLObject;

@protocol SLObjectObserving <NSObject>

#pragma mark - Notification handlers

@optional

// Observer change notification methods, to be used for example by data and view controllers

// Implement the following 2 methods to catch respectively the beginning and the end of the change notification session

- (void)willChangeObjects;
- (void)didChangeObjects;

// Implement the following 2 methods to catch an object attribute change respectively before and after it is effected

- (void)willChangeObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue remotely:(BOOL)remotely;
- (void)didChangeObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue remotely:(BOOL)remotely;

// Implement the following 2 methods to catch the reset of an object attribute value caused by a voided transaction

- (void)willResetObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue;
- (void)didResetObjectValue:(SLObject *)object forKey:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue;

// Implement the following method to prepare for an object deletion

- (void)willDeleteObject:(SLObject *)object remotely:(BOOL)remotely;

// Implement the following method to catch an object creation

- (void)didCreateObject:(SLObject *)object remotely:(BOOL)remotely;

@end