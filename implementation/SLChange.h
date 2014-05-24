//
//  SLChange.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import <Foundation/Foundation.h>


// SLChange is the class that capture a change log entry. All property changes that need to be logged
// are captured in a SLChange instance

@class SLObject;

@interface SLChange : NSObject <NSCoding>

@property (nonatomic, weak) SLObject    *object;
@property (nonatomic) BOOL              local;
@property (nonatomic) NSDate            *when;
@property (nonatomic) NSString          *key;
@property (nonatomic) id                oValue;
@property (nonatomic) id                nValue;

// Lifecycle management

+ (id) changeWithObject:(SLObject *)object local:(BOOL)local key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue when:(NSDate*)date;
- (void) detachFromObject;

// NSCoding protocol functions

- (id) initWithCoder:(NSCoder *)coder;
- (void) encodeWithCoder:(NSCoder *)coder;

@end


extern NSString *kSLChangeObjectName;
extern NSString *kSLChangeWhenName;
extern NSString *kSLChangeKeyName;
extern NSString *kSLChangeOValueName;
extern NSString *kSLChangeNValueName;

