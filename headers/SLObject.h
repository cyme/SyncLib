//
//  SLObject.h
//
//  Copyright (c) 2013 Cyril Meurillon. All rights reserved.
//

// TO DO
// - support for timing settings (sync heartbeat interval)
// - support for carrying over unsaved PFObject creation/changes/deletion from one app session to the next (journaling)
// - transactions
// - support for collection properties
// - support for queries
// - support for large data set

// WHAT IS SYNCLIB?
// It's a strawman for a simple framework to store structured data in the cloud and keep it synchronized across multiple clients.
// This has been an area of recent development in the industry, with for example Core Data for iCloud (Apple), Parse Data (Parse)
// and the DataStore API (Dropbox). Despite those recent development, challenges remain for the developer:
// - Core Data for iCloud is most certainly the most sophisticated and capable of all, but too complex for simple needs
// - Parse Data offers simple APIs, but offers no synchronization or offline management capability. It does not offer instance uniquing either
// - DataStore API offers simple interfaces for most part, but suffers from serious issues, e.g. synchronization unnecessarily complex
// SyncLib attemps to provide the following:
// - a simple framework for storing and retrieving structured data to the cloud based on the existing Parse Data framework and service
// - object oriented database interface: subclasses define tables, attributes are mapped to properties (ala NSManagedObject)
// - basic to-one relations: references from one object to another  are supported and treated as weak pointers (zeroed when the referenced object is deleted)
// - instance uniquing: database objects are instantiated exactly once in memory, which eliminates the need to manage and merge multiple copies of the same object
// - simple real time synchronization: object observers are notified of changes, changes are propagated to other devices through push notifications
// - simple conflict resolution: conflicting changes to objects are automatically handled (on a best-effort basis)
// - simple threading model: all blocking methods are asynchronous, which allows them to take place on the main thread
// - basic offline management and local caching: the framework is fully functional during transient or permanent loss of connectivity
// - storage class control: persistent/non persistent and local/cloud storage classes are available on a per-attribute basis
// - ... and all of this delivered through developer-friendly APIs
//
//
//
// WHAT IS IT NOT?
// - a viable framework. Aspects critical to any production-ready framework are left completely unaddressed, e.g. account management, queries, etc.
// - a bug-free framework. The code has received minimal unit-testing and no stress-testing.
// - a framework to handle large data sets
// - take it as a coding and framework design exercise, a 2-3 months side project
//
//
//
// BASIC OPERATION
// classes:
// - SLObject.h and SLObjectObserving.h are the public interfaces to the library
// - SLObject is an abstract class and must be subclassed to implement a database table
// - subclasses must be registered with the framework
// - subclass attributes may choose between 3 storage classes: 1) cloud persisted (& synchronized), 2) locally persisted only (in device cache), 3) transient (memory only)
// - sublclass attribute may be objects or scalar types. collections are not supported.
// memory management:
// - objects are instantiated either explicitely (local object creation) or implicitely (read from the device cache, remote object creation)
// - database objects are instantiated only once ("uniquing")
// - objects are automatically disposed of when they are deleted
// synching:
// - the client is synced with the database to upload local changes and download remote changes
// - conflicts between local and remote changes are handled automatically (attribute conflicts: last attribute change wins, on a best effort basis - object conflicts: delete trumps anything)
// - sync are triggered by 1) local changes, 2) push notification from remote clients and 3) on regular intervals (polling)
// - when a synching operation changes the state of the cloud store, it sends a push notification to all registered clients so that they can retrieve the new state
// - note: push notifications currently only enabled on the devices attached to my developer account due to push activation process
// observers:
// - observers register to listen to changes to all object instances of a subclass
// - locally and remotely initiated changes are notified to class observers
// - objects interested in changes, such as data controllers and view controllers, can register as observers on relevant classes
// - the framework uses the observer design pattern rather than delegates to allow for a single change to be notified to multiple parties, e.g. to multiple view controllers.
// - observers need to unregister before their object can be disposed of
// - observer notification handlers may themselves alter the state of the observed object (change object attributes, delete the object)
// - the observation protocol attempts to present a coherent view to each registered observer, as follows:
//      - 2 observers observing the same class are notified of an event in the order they registered, or the opposite order depending on the nature of the change
//      - this allows for observers to be "stacked" (i.e. an observer depends on the state of another observer registered earlier)
//      - if 2 objects in the object graph are connected, but not in a cycle, changes to the child are are notified before changes to the parent.
//      - if 2 objects in the object graph are connected with a cycle, the order of change notification is undetermined.
//      - in the case of nested change notifications (observer making changes to the observed object), observers are guaranteed to always be notified of an object creation before of any other object change
//
//
// A FEW KNOWN LIMITATIONS AND ISSUES
// 1. It's a hack
//      Many of the library features, e.g. synchronization, uniquing, etc really need to be implemented at the core of the cloud database
//      service and framework. Implementing them as a layer on top of an existing architecture as it is done here with Parse leads to several
//      correctness and performance issues that are difficult or impossible to fix.
// 2. No query support
//      SyncLib does not offer any object query API.
// 3. APIs not designed for large data sets
//      the APIs is not adequate to handle large data sets. For example, the client receives notification on the entire data set. A design based
//      on live queries would be better suited for large data sets. In such a design, the client would be notified of changes on the subsets of
//      data sets it is interested in.
// 4. The entire data set is loaded and kept in memory at all times
//      This could be remedied by implementing a faulting mechanism inspired from Core Data
// 5. The database has a limit of 1000 objects per class
//      Due to a limitation in the Parse query implementation, each database class cannot
//      contain more than 1,000 objects. This could be remedied at the expense of a more
//      complex implementation.
// 6. No blob support
//      SyncLib does not offer a mechanism to store large, unstructured data
// 7. Not optimized for performance or power management
//      SyncLib has not beed profiled or optimized in any manner.
// 8. Delete leaks.
//      Deleted objects are merely marked for deletion in the cloud store rather than actually deleted.
//      Memory instances are properly disposed of.
// 9. Robustness and user data integrity can be improved
//      The current implementation offers little in the way of robustness. A corruption in the cloud
//      database will likely crash the client. Additionally, the resolution of some transient states
//      of the cloud store can be optimized
// 10. to-many object attributes are not supported
// 11. scalar object attributes are not supported
// 12. No transaction support
//      This is due to the fact that Parse Data does not support transaction. Therefore the database
//      does not guarantee the integrity of user data and causality of change.
// 13. The framework is not thread-safe
//      The framework currently assumes all methods are called on the main thread.
// 14. Circular relations are not supported
//      This is a Parse limitation. This can be remedied by abstracting the reference class.
// 15. Little error checking



#import <Foundation/Foundation.h>

@protocol SLObjectObserving;


@interface SLObject : NSObject <NSCoding>

// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// Class methods for subclasses to override
// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

#pragma mark - Class methods to override

// all subclasses must implement this method to provide the subclass name

+ (NSString *)className;

// by default, subclass properties are stored on the cloud and synced across all app installs of the syncing group.
// app installs that are not part of a syncing group 
// subclasses can optionally declare which of their properties to not share and keep local by overriding
// the following methods:
// localPersistedProperties: should return an array of local property names that are persisted locally only
// localTransientProperties: should return an array of local property names that are not persisted at all

+ (NSArray *)localPersistedProperties;
+ (NSArray *)localTransientProperties;

// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// Class methods that pertain to specific SLObject subclasses
// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

#pragma mark - Class methods to call

// all subclasses must call this method to register.
// It can safely be called multiple times on the same subclass.
// This method will fail if used on SLObject rather than a subclass.

+ (void)registerSubclass;

// Create a new object of this subclass and add it to the database. Object property values (of all storage classes)
// can be specified in the dictionary.  The object instance is returned. This method will fail if used on SLObject
// rather than a subclass

+ (id)objectWithValues:(NSDictionary *)values;

// Call this method to set add or remove a class observer. Observers will be notified in the order they have registered
// to listen to the subclass
// addObserver: will retroactively notify the observer of any past object creations (fetched from device cache and locally/remotely created)

+ (void)addObserver:(id<SLObjectObserving>)observer;
+ (void)removeObserver:(id<SLObjectObserving>)observer;

// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// Instance methods that pertain to an instance of SLObject or a subclass
// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

#pragma mark - Instance methods to call

// Delete object from database, detach it from the global object registery and mark the object instance
// for deletion.

- (void)delete;

@end

extern NSString * const     SLErrorDomain;
extern NSInteger const      SLInvitationCodeDigits;
extern NSTimeInterval const SLInvitationTimeout;


enum {
    SLErrorSyncingRequestTimeout = 100,
    SLErrorSyncingRequestCancelled,
    SLErrorInvalidCode,
    SLErrorNoConnection
};

