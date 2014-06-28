//
//  SLChange.m
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

#import "SLChange.h"
#import "SLObject-Internal.h"
#import "SLObjectRegistry.h"
#import "SLTransaction-Internal.h"


static NSString * const kSLChangeObjectKey = @"SLCObject";
static NSString * const kSLChangeTimeStampKey = @"SLCTimeStamp";
static NSString * const kSLChangeCounterKey = @"SLCCounter";
static NSString * const kSLChangeKeyKey = @"SLCKey";
static NSString * const kSLChangeOValueKey = @"SLCOValue";
static NSString * const kSLChangeNValueKey = @"SLCNValue";


@interface SLChange ()

+ (id)changeWithObject:(SLObject *)object
                   key:(NSString *)key
              oldValue:(id)oldValue
              newValue:(id)newValue
                 local:(BOOL)local
           transaction:(SLTransaction *)transaction
             timeStamp:(NSDate *)timeStamp
               counter:(uint64_t)counter;

+ (uint64_t)counter;

- (id)initWithObject:(SLObject *)object
                 key:(NSString *)key
            oldValue:(id)oldValue
            newValue:(id)newValue
               local:(BOOL)local
         transaction:(SLTransaction *)transaction
           timeStamp:(NSDate *)timeStamp
             counter:(uint64_t)counter;

@end


@implementation SLChange

#pragma mark - Lifecycle management

+ (id)localChangeWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue
{
    return [SLChange changeWithObject:object
                                  key:key
                             oldValue:oldValue
                             newValue:newValue
                                local:TRUE
                          transaction:nil
                            timeStamp:[NSDate date]
                              counter:[SLChange counter]];
}

+ (id)remoteChangeWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue timeStamp:(NSDate *)timeStamp
{
    return [SLChange changeWithObject:object
                                  key:key
                             oldValue:oldValue
                             newValue:newValue
                                local:FALSE
                          transaction:nil
                            timeStamp:timeStamp
                              counter:[SLChange counter]];
}

+ (id)transactionChangeWithObject:(SLObject *)object key:(NSString *)key oldValue:(id)oldValue newValue:(id)newValue transaction:(SLTransaction *)transaction
{
    return [SLChange changeWithObject:object
                                  key:key
                             oldValue:oldValue
                             newValue:newValue
                                local:TRUE
                          transaction:transaction
                            timeStamp:[NSDate date]
                              counter:[SLChange counter]];
}

// log a new property change. this may or may not create a new SLChange object, as necessary.

+ (id)changeWithObject:(SLObject *)object
                   key:(NSString *)key
              oldValue:(id)oldValue
              newValue:(id)newValue
                 local:(BOOL)local
           transaction:(SLTransaction *)transaction
             timeStamp:(NSDate *)timeStamp
               counter:(uint64_t)counter
{
    SLChange            *change;
    SLObjectRegistry    *registry;
    
    registry = [SLObjectRegistry sharedObjectRegistry];
    
    if (transaction)
        change = [transaction changeForObject:object key:key];
    else
        if (local)
            change = object.localChanges[key];
        else
            change = object.remoteChanges[key];
    
    if (!change || change.issuingTransaction) {
        
        // this is a transactional change or no change exists for this key
        // create a new change object
        
        change = [[SLChange alloc] initWithObject:object
                                              key:key
                                         oldValue:oldValue
                                         newValue:newValue
                                            local:local
                                      transaction:transaction
                                        timeStamp:timeStamp
                                          counter:counter];
        [object addChange:change];
        if (transaction)
            [transaction addChange:change];
        if (!local)
            [registry addRemoteChange:change];
        
    } else {
        
        // a change exists for this key and this isn't a transactional change
        // update the value and timestamp
        
        change.nValue = newValue;
        [change updateTimeStamp];
    }
    
    if (!transaction) {
        SLChange        *oppositeChange;
        
        // check whether there's a change of the opposite type recorded for this key
        // i.e. whether there's a local change for the same key when logging a remote change
        // or a remote change for the same key when logging a local change
        // if that's the case, the change of the opposite type is dropped
        
        if (local)
            oppositeChange = object.remoteChanges[key];
        else
            oppositeChange = object.localChanges[key];
        if (oppositeChange)
            [oppositeChange detach];
    }
    
    return change;
}

// initialize an empty SLChange object

- (id)initWithObject:(SLObject *)object
                 key:(NSString *)key
            oldValue:(id)oldValue
            newValue:(id)newValue
               local:(BOOL)local
         transaction:(SLTransaction *)transaction
           timeStamp:(NSDate *)timeStamp
             counter:(uint64_t)counter
{
    self = [super init];
    
    _object = object;
    _key = key;
    _oValue = oldValue;
    _nValue = newValue;
    _timeStamp = timeStamp;
    _counter = counter;
    _local = local;
    _issuingTransaction = transaction;
    _capturingTransactions = nil;
    return self;
}

// unarchive an SLChange object

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    
    _object = [coder decodeObjectForKey:kSLChangeObjectKey];
    _timeStamp = [coder decodeObjectForKey:kSLChangeTimeStampKey];
    _counter =[coder decodeInt64ForKey:kSLChangeCounterKey];
    _key = [coder decodeObjectForKey:kSLChangeKeyKey];
    _oValue = [coder decodeObjectForKey:kSLChangeOValueKey];
    _nValue = [coder decodeObjectForKey:kSLChangeNValueKey];
    _local = TRUE;
    _issuingTransaction = nil;
    _capturingTransactions = nil;
    return self;
}


// archive a SLChange object

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.object forKey:kSLChangeObjectKey];
    [coder encodeObject:self.timeStamp forKey:kSLChangeTimeStampKey];
    [coder encodeInt64:self.counter forKey:kSLChangeCounterKey];
    [coder encodeObject:self.key forKey:kSLChangeKeyKey];
    [coder encodeObject:self.oValue forKey:kSLChangeOValueKey];
    [coder encodeObject:self.nValue forKey:kSLChangeNValueKey];
}



// commit takes an uncommitted transactional change and creates an equivalent local change.
// it leaves the uncommitted change untouched

- (void)commit
{
    assert(self.issuingTransaction);
    [SLChange changeWithObject:self.object
                           key:self.key
                      oldValue:self.oValue
                      newValue:self.nValue
                         local:TRUE
                   transaction:nil
                     timeStamp:self.timeStamp
                       counter:self.counter];
}

// detach detaches a change from its object and removes it from all lists to prepare it for deallocation

- (void)detach
{
    SLObjectRegistry        *registry;
    
    registry = [SLObjectRegistry sharedObjectRegistry];
    
    [self.object removeChange:self];
    if (self.issuingTransaction)
        [self.issuingTransaction removeChange:self];
    if (!self.local)
        [registry removeRemoteChange:self];
    
    // capturingTransactions contains strong references to transactions that may in turn contain
    // strong references to self. we set it to nil here to take care of the retain cycle
    
    self.capturingTransactions = nil;
}

- (void)addCapturingTransaction:(SLTransaction *)transaction
{
    if (!self.capturingTransactions) {
        self.capturingTransactions = [NSCountedSet set];
        assert(self.capturingTransactions);
    }
    [self.capturingTransactions addObject:transaction];
}

- (void)removeCapturingTransaction:(SLTransaction *)transaction
{
    assert(self.capturingTransactions);
    assert([self.capturingTransactions containsObject:transaction]);
    [self.capturingTransactions removeObject:transaction];
    if ([self.capturingTransactions count] == 0)
        self.capturingTransactions = nil;
}

- (void)updateTimeStamp
{
    self.timeStamp = [NSDate date];
    self.counter = [SLChange counter];
}

- (NSComparisonResult)compareTimeStamp:(SLChange *)otherChange
{
    NSComparisonResult      result;
    
    // first compare the time stamps of the changes
    // if they are equal, use the counter to disambiguate
    
    result = [self.timeStamp compare:otherChange.timeStamp];
    if (result != NSOrderedSame)
        return result;
    
    if (self.counter < otherChange.counter)
        return NSOrderedAscending;
    if (self.counter > otherChange.counter)
        return NSOrderedDescending;
    return NSOrderedSame;
}

- (NSComparisonResult)compareTimeStampToDate:(NSDate *)date
{
    return [self.timeStamp compare:date];
}

// NSCoding protocol methods. SLChange objects are archived when writing the device cache, and unarchived when reading it.

#pragma mark - NSCoding protocol methods

// increment and return an internal long long counter

+ (uint64_t)counter
{
    static uint64_t internalCounter = 0;
    
    return internalCounter++;
}


@end
