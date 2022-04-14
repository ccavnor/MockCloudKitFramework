[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fccavnor%2FMockCloudKitFramework%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ccavnor/MockCloudKitFramework)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fccavnor%2FMockCloudKitFramework%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ccavnor/MockCloudKitFramework)

# ``MockCloudKitFramework``

A framework for testing of CloudKit operations. It mocks CloudKit classes to provide a seamless way to test CloudKit operations in your App's code.

## Why do you need this?
CloudKit is rich framework for shared records, but it resists testing strategies mainly because it hides its initializers from the developer - making it impossible to just create a test instance of CKContainer. CloudKit does offer a test environment that uses your app’s com.apple.developer.icloud-container-environment entitlement, but that is more of a sandbox for records than the API to manage them. 

MockCloudKitFramework attempts to fill this gap.

The two most vital classes of CloudKit, CKContainer and CKDatabase are (unfortunately) functionally implemented as finals. They can be subclassed but their init methods are not accessable. Therefore, MockCloudKitFramework cannot simply subclass CloudKit classes. 

Perhaps worse, they both inherit directly from NSObject as their common Protocol. So that IOC would force generic functions to be open to NSObject types - leaving functions wide open for injection of everything that inherits from NSObject.

To close this gap, MockCloudKitFramework (MCF) creates its own Protocols and extends CloudKit with mocks for the objects that it implements. 

Here is a movie of using a simple app that lets you type a message and post that message into iCloud. The UI has no idea that we are using MCF instead of CloudKit here:

<img src="https://github.com/ccavnor/MockCloudKitFramework/blob/main/resources/successful_test.gif" alt="testing with success conditions" width="250"/>


However, we can easily tell MCF that we want the transaction to fail with a certain error:

<img src="https://github.com/ccavnor/MockCloudKitFramework/blob/main/resources/failure_test.gif" alt="testing with failure conditions" width="250"/>

## Requirements
MockCloudKitFramework is built and tested for iOS 15.0 and onward only. This is to take advantage of the cleaner implementation of CKDatabaseOperation functionality. However, some "legacy" (not deprecated as of yet, but the CloudKit documentation specifies alternative CKDatabaseOperations to use) methods from CKDatabase are included in the framework. Their implementation merely returns an error through their completion handler. I opted to not mark them as throwing because that would make the mocked methods conflict with the non-throwing signatures of their CloudKit counterparts. In general, I strived to maintain all method signatures exactly as CloudKit implements them.

## Overview
The MockCloudKitFramework (MCF) implements mock operations for CKContainer and CKDatabase functionality mainly, but also mocks operations that inherit from CKDatabaseOperation. These comprise a big chunk of CloudKit interoperatability, but there are still areas of CloudKit functionality that are not mocked. 

> Note: Zone operations are not handled, but more significantly the CloudKit asynchronous API operations added for Swift 5.5 async/await support have not (as of yet) been implemented in MockCloudKitFramework. 

OK, that's enough about what MockCloudKitFramework cannot or will not do. Lets take a look at what it _does_ do.

## Using MockCloudKitFramework
> Tip: MockCloudKitFramework is designed to follow the API of CloudKit as closely as possible. So using it will be as familiar as using CloudKit itself. 

### Working Example
Below is a general example of how to proceed with MockCloudKitFramework. See project documentation and the accompanying MockCloudKitFrameworkTestProject for more details.

##### A First Step
Let's say that we have a View or View Controller that contains some code that calls the CloudKit API:
```swift
let cloudContainer: CKContainer = CKContainer.default()
let database: CKDatabase = cloudContainer.publicCloudDatabase

// CKAccountStatus codes are constants that indicate the availability of 
// the user’s iCloud account. Note that ONLY the return of CKAccountStatus.available
// signifies that the user is signed into iCloud. Any other return value indicates an error.
func accountStatus(completion: @escaping (Result<CKAccountStatus, Error>) -> Void) {
    cloudContainer.accountStatus { status, error in
        switch status {
        case .available:
            completion(.success(.available))
        default:
                guard let error = error else {
                    let error = NSError.init(domain: "AccountStatusError", code: 0) as Error
                    completion(.failure(error))
                    return
                }
            completion(.failure(error))
        }
    }
}
```
That's great, but how do we test when CloudKit responds with anything but CKAccountStatus.available? We could always turn off the wifi on the laptop to force CloudKit to respond with some other CKAccountStatus (you know you've done it).

But that's not exactly handy for testing. And testing should be deterministic and fast. Oh, and automatable.

##### Test
Since the object here is to test our code, lets take the calling code that we have in the view and put it into a test:

```swift
import XCTest
import CloudKit
@testable import OurProject // required for access to CloudController

class MockCloudKitTestProjectIntegrationTest: XCTestCase {
    var cloudContainer: CKContainer!

    /// Lookup table for CKAccountStatus codes
    let ckAccountStatuses: [CKAccountStatus] = [
        CKAccountStatus.couldNotDetermine,
        CKAccountStatus.available,
        CKAccountStatus.restricted,
        CKAccountStatus.noAccount,
        CKAccountStatus.temporarilyUnavailable
    ]

    override func setUpWithError() throws {
        try? super.setUpWithError()
        cloudContainer = CKContainer.default()
    }

    // ================================
    // test accountStatus()
    // ================================
    // test that we get errors for all CKAccountStatus except for CKAccountStatus.available and that status is expected message.
    func test_accountStatus() {
        XCTAssertNotNil(cloudContainer)

        for (status, message) in ckAccountStatusMessageMappings {
            let expect = expectation(description: "CKAccountStatus")
                cloudContainer.accountStatus { result in
                switch result {
                case .success:
                    XCTAssertEqual(self.ckAccountStatusMessageMappings[status],
                                   CKAccountStatusMessage.available.rawValue)
                    expect.fulfill()
                case .failure(let error):
                    XCTAssertNotNil(error)
                    XCTAssertEqual(self.ckAccountStatusMessageMappings[status], message)
                    expect.fulfill()
                }
            }
            waitForExpectations(timeout: 1)
        }
    }
}
```
Our problem now is that the function is testable via unit test, but we are subject to the state of CloudKit to make the test pass. And we have little control over CloudKit state. This is where MockCloudKit framework comes in.

##### Controller Class
Let's define the following class, CloudController, in our project. CloudController is essentially a wrapper around the CloudKit API. It contains two methods:
- accountStatus: calls CloudKit to get user account information. 
- checkCloudRecordExists: uses the CloudKit CKFetchRecordsOperation operation to find out if CloudKit has a certain record added to the database of whichever scope we pass in.

> Note: Note the use of Generics, here. The CloudController class is typed to an object that conforms to the CloudContainable protocol.

```swift
import CloudKit

/// Example Class to handle iCloud related transactions. 
class CloudController<T: CloudContainable> {
    let cloudContainer: T
    let database: T.DatabaseType

    init(container: T, databaseScope: CKDatabase.Scope) {
        self.cloudContainer = container
        self.database = container.database(with: databaseScope)
    }

    func accountStatus(completion: @escaping (Result<CKAccountStatus, Error>) -> Void) {
        cloudContainer.accountStatus { status, error in
            switch status {
            case .available:
                completion(.success(.available))
            default:
                guard let error = error else {
                    let error = NSError.init(
                        domain: "AccountStatusError", 
                        code: 0) as Error
                    completion(.failure(error))
                    return
                }
                completion(.failure(error))
            }
        }
    }

/// Check if a record exists in iCloud.
/// - Parameters:
///   - recordId: the record id to locate
///   - completion: closure to execute on caller
/// - Returns: success(true) when record is located, success(false) when record is 
///   not found, failure if an error occurred.
func checkCloudRecordExists(recordId: CKRecord.ID, 
                            _ completion: @escaping (Result<Bool, Error>) -> Void) {
        let dbOperation = CKFetchRecordsOperation(recordIDs: [recordId])
        dbOperation.recordIDs = [recordId]
        var record: CKRecord?
        dbOperation.desiredKeys = ["recordID"]
        // perRecordResultBlock doesn't get called if the record doesn't exist
        dbOperation.perRecordResultBlock = { _, result in
            // success iff no partial failure
            switch result {
            case .success(let r):
                record = r
            case .failure:
                record = nil
            }
        }
        // fetchRecordsResultBlock always gets called when finished processing.
        dbOperation.fetchRecordsResultBlock = { result in
            // success if no transaction error
            switch result {
            case .success():
                if let _ = record { // record exists and no errors
                    completion(.success(true))
                } else { // record does not exist
                    completion(.success(false))
                }
            case .failure(let error): // either transaction or partial failure occurred
                completion(.failure(error))
            }
        }
        database.add(dbOperation)
    }
}
```
##### Another pass at testing
Now that we have our CloudController set up for Generics, lets redefine our test, this time using MockCloudKitFramework. 

> Note: Note the use of the setError property on MockCKContainer to set the fail condition for MCF's MockCKContainer. 

Now, CloudController's accountStatus method will return success only for CKAccountStatus.available. Boom. Testable.

```swift
    // ================================
    // test accountStatus()
    // ================================
    // test that we get errors for all CKAccountStatus except for 
    // CKAccountStatus.available and that status is expected message.
    func test_accountStatus() {
        XCTAssertNotNil(cloudContainer)

        for (status, message) in ckAccountStatusMessageMappings {
            let expect = expectation(description: "CKAccountStatus")
            // NOTE that we are setting both success (.available) and error statuses 
            // (all others) on MockCKContainer now
            cloudContainer.setAccountStatus = status
            cloudController.accountStatus { result in
                switch result {
                case .success:
                    XCTAssertEqual(self.ckAccountStatusMessageMappings[status],
                                   CKAccountStatusMessage.available.rawValue)
                case .failure(let error):
                    XCTAssertNotNil(error)
                    XCTAssertEqual(self.ckAccountStatusMessageMappings[status], message)
                }
                expect.fulfill()
            }
            waitForExpectations(timeout: 1)
        }
    }
}
```

##### Test CKFetchRecordsOperation operation on CKDatabase
Ok, lets see what else we can do. 

###### Test CKFetchRecordsOperation success
Suppose that we wanted to check if a record exists in the public scope of our CloudKit database? Well, CloudController has the checkCloudRecordExists() method that calls through CloudKit's CKFetchRecordsOperation operation to fetch records. But what record do we check for? MockCloudKitFramework has you covered. With it, we can set records on a local (mocked) instance of CKDatabase (MockCKDatabase) and again inject our mock CKContainer into CloudController.

```swift
func test_checkCloudRecordExists_success() {
    let expect = expectation(description: "CKDatabase fetch")
    let record = makeCKRecord()
    // First, add the record to MockCKDatabase
    cloudDatabase.addRecords(records: [record])
    // Then check for its existence
    cloudController.checkCloudRecordExists(recordId: record.recordID) { result in
        switch result {
        case .success(let exists):
            XCTAssertTrue(exists)
            expect.fulfill()
        case .failure:
            XCTFail("failure only when error occurs")
        }
    }
    waitForExpectations(timeout: 1)
}
```
That's it!! All we had to do is add the record to MockCKDatabase (the MCF version of the CloudKit CKContainer class) and then call checkCloudRecordExists(). Note that it would have been perfectly fine to use a CKModifyRecordsOperation operation to add the records to MockCKDatabase first (this is what we would do when dealing with CloudKit), but the ``MockCKDatabase`` API lets us mutate the database simply.

Let's test it again, but this time set the error that we want CloudKit to fail with:

```swift
// call checkCloudRecordExists() when the record is present but error is set
func test_checkCloudRecordExists_error() {
    let expect = expectation(description: "CKDatabase fetch")
    let record = makeCKRecord()
    cloudDatabase.addRecords(records: [record])
    // set an error on operation
    let nsErr = createNSError(with: CKError.Code.internalError)
    MockCKDatabaseOperation.setError = nsErr
    cloudController.checkCloudRecordExists(recordId: record.recordID) { result in
        switch result {
        case .success:
            XCTFail("should have failed")
            expect.fulfill()
        case .failure(let error):
            XCTAssertEqual(error.createCKError().code.rawValue, nsErr.code)
            expect.fulfill()
        }
    }
    waitForExpectations(timeout: 1)
}
```

The only difference here is that we created an NSError and added it to our MockCKDatabaseOperation via the static setError property:

```swift
let nsErr = createNSError(with: CKError.Code.internalError)
MockCKDatabaseOperation.setError = nsErr
```

We can even test our function logic for [partial failures](https://developer.apple.com/documentation/cloudkit/ckerror/2325226-partialfailure) to make sure that we handle the scenario of when a record _might_ be found but some CKError occurred so we cannot be sure. All we need to do is set the setRecordErrors property on the operation to the set of record ids that should fail (MCF picks a random CKError to fail with):

```swift
// test for partial failures
func test_checkCloudRecordExists_partial_error() {
    let expect = expectation(description: "CKDatabase fetch")
    let record = makeCKRecord()
    cloudDatabase.addRecords(records: [record])
    // set an error on Record
    MockCKFetchRecordsOperation.setRecordErrors = [record.recordID]
    cloudController.checkCloudRecordExists(recordId: record.recordID) { result in
        switch result {
        case .success:
            XCTFail("should have failed")
        case .failure(let error):
            let ckError = error.createCKError()
            XCTAssertEqual(ckError.code.rawValue,
                           CKError.partialFailure.rawValue,
                           "The transaction error should always be set to CKError.partialFailure when record errors occur")
            if let partialErr: NSDictionary = error.createCKError().getPartialErrors() {
                let ckErr = partialErr.allValues.first as? CKError
                XCTAssertEqual("CKErrorDomain", ckErr?.toNSError().domain)
                expect.fulfill()
            }
        }
    }
    waitForExpectations(timeout: 1)
}
```

## Installation

#### Import MockCloudKitFramework.framework to your project
Adding to your project is simple via the [Swift Package Manager](https://www.swift.org/package-manager/). From XCode just choose File -> Add packages... and point to this repository. Make sure that the project is installed as a Framework (check Project Settings -> General -> My Target -> Frameworks, Libraries, and Embedded Content). 

The MockCloudKitTestFramework (the XCode project that provides examples of unit, integration, and UITesing of MockCloudKitFramework ) can be cloned and run as a standard XCode project.

## Setup
Setting up MockCloudKitFramework (MCF) can be done in at least two ways. The first is simple but potentially not safe for production. The second requires a few more steps. Both will require that you use generics to pass in the CloudKit or MCF classes that you implement via IOC (dependency injection). More on that later.

#### The easy way
Just import the framework as:
```swift
import MockCloudKitFramework
```
That's all it takes. But the tradeoff is that you must import MCF everywhere that you import CloudKit (assuming that you want to test that module). That might be offputting to some developers. But keep in mind that all MCF code (including these protocols and their extensions) are wrapped in `#if DEBUG` pragma - so that nothing is exposed during normal runtime, only during test runs.
But if you want to avoid the risk of importing a test dependency into production code, see the next section. 

#### The (slightly) harder way
You can use MCF purely from your test classes. You'll just have to load the MCF protocols and their extensions into your respective targets (XCode maintains seperate environments for each target). Its up to you how and when to expose the MCF protocols and extensions, but the recommended way is to wrap them in a `#if DEBUG` block minimally. That will ensure that they are only loaded during test runs and that they will be stripped from production code via the compiler.

##### Install MCF protocols
Copy the following set of Protocols into a module in your project (NOT test) target. A good place might be your root app module (see MockCloudKitTestProject/MockCloudKitTestProjectApp.app for an example): 

```swift
# if DEBUG
// ========================================
// MockCloudKitFramework Protocols
// ========================================
/// Protocol for CKFetchRecordsOperation interoperability
public protocol CKFetchRecordsOperational: DatabaseOperational {
    var recordIDs: [CKRecord.ID]? { get set }
    var desiredKeys: [CKRecord.FieldKey]? { get set }
    // `CKDatabaseOperation`s:
    /// The closure to execute with progress information for individual records
    var perRecordProgressBlock: ((CKRecord.ID, Double) -> Void)? { get set }
    /// The closure to execute after CloudKit modifies all of the records
    var fetchRecordsResultBlock: ((Result<Void, Error>) -> Void)? { get set }
    /// The closure to execute once for every fetched record
    var perRecordResultBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)? { get set }
}
/// Protocol for CKQueryOperation interoperability
public protocol CKQueryOperational: DatabaseOperational {
    var query: CKQuery? { get set }
    var desiredKeys: [CKRecord.FieldKey]? { get set }
    // `CKDatabaseOperation`s:
    /// The closure to execute after CloudKit modifies all of the records
    var queryResultBlock: ((_ operationResult: Result<CKQueryOperation.Cursor?, Error>) -> Void)? { get set }
    /// The closure to execute once for every fetched record
    var recordMatchedBlock: ((_ recordID: CKRecord.ID, _ recordResult: Result<CKRecord, Error>) -> Void)? { get set }
}
/// Protocol for CKModifyRecordsOperation interoperability
public protocol CKModifyRecordsOperational: DatabaseOperational {
    var recordsToSave: [CKRecord]? { get set }
    var recordIDsToDelete: [CKRecord.ID]? { get set }
    var savePolicy: CKModifyRecordsOperation.RecordSavePolicy { get set }
    // `CKDatabaseOperation`s:
    /// The closure to execute with progress information for individual records
    var perRecordProgressBlock: ((CKRecord, Double) -> Void)? { get set }
    /// The closure to execute after CloudKit modifies all of the records
    var modifyRecordsResultBlock: ((_ operationResult: Result<Void, Error>) -> Void)? { get set }
    /// The closure to execute once for every deleted record
    var perRecordDeleteBlock: ((_ recordID: CKRecord.ID, _ deleteResult: Result<Void, Error>) -> Void)? { get set }
    /// The closure to execute once for every saved record
    var perRecordSaveBlock: ((_ recordID: CKRecord.ID, _ saveResult: Result<CKRecord, Error>) -> Void)? { get set }
}
/// Shadow protocol to bridge CKDatabaseOperationProtocol.OperationType ==> CKContainerProtocol.DatabaseType.OperationType
public protocol AnyCKDatabaseProtocol {
    /// - Receives a parameter of Concrete Type `Any`
    func add(_ operation: Any)
}
/// Protocol for CKDatabase interoperability
/// Uses `AnyCKDatabaseProtocol` shadow protocol for type conversion. This acts as a bridge between CloudStorable
/// and the operations that extend DatabaseOperational to a common OperationType.
public protocol CloudStorable: AnyCKDatabaseProtocol {
    associatedtype OperationType: DatabaseOperational
    /// Keep track of last executed query for testing purposes
    var lastExecuted: MockCKDatabaseOperation? { get set }
    /// - Receives a parameter of Concrete Type that is a `DatabaseOperational`
    func add(_ operation: OperationType)
}
/// Default extension to conform to `DatabaseOperational` by using `AnyCKDatabaseProtocol` for type erasure
extension CloudStorable {
    public func add(_ operation: Any) {
        // ensure that we partition CloudKit operations from MCF ones
        if let operation = operation as? OperationType {
            add(operation)
        } else {
            // convert CKDatabaseOperation types to MockCKDatabaseOperation (but never the opposite)
            let mockDB = self as! MockCloudKitFramework.MockCKDatabase
            if let ckDatabaseOperation = operation as? CKFetchRecordsOperation {
                let mockOp = ckDatabaseOperation.getMock(database: mockDB)
                add(mockOp)
            } else if let ckDatabaseOperation = operation as? CKQueryOperation {
                let mockOp = ckDatabaseOperation.getMock(database: mockDB)
                 add(mockOp)
            } else if let ckDatabaseOperation = operation as? CKModifyRecordsOperation {
                let mockOp = ckDatabaseOperation.getMock(database: mockDB)
                 add(mockOp)
            } else {
                fatalError("Unknown operation attempted to convert to its mock counterpart: \(operation)")
            }
        }
    }
}
/// Used only for NSObject conformance so that we can use Key-Value Coding
public protocol DatabaseOperational: NSObject {
    associatedtype DatabaseType: CloudStorable
    var database: DatabaseType? { get set }
    /// The operation's configuration - inherited from `CKOperation`
    var configuration: CKOperation.Configuration! { get set }
    /// The custom completion block. Always the last block to be called. inherited from `Operation`
    var completionBlock: (() -> Void)? { get set }
}
extension MockCKDatabaseOperation {
    public typealias DatabaseType = MockCKDatabase
}
/// Protocol for CKContainer interoperability
public protocol CloudContainable {
    associatedtype DatabaseType: CloudStorable
    var containerIdentifier: String? { get }
    func database(with databaseScope: CKDatabase.Scope) -> DatabaseType
    func accountStatus(completionHandler: @escaping (CKAccountStatus, Error?) -> Void)
    func fetchUserRecordID(completionHandler: @escaping (CKRecord.ID?, Error?) -> Void)
}
#endif
```
##### Protocol extensions
Then copy the following protocol extension into the same module. This extends CloudKit with a common set of Protocols as MCF:
```swift
# if DEBUG
// ========================================
// MARK: CloudKit MCF protocol extensions
// ========================================
// These extensions make CloudKit comply with MCF protocols
extension CKContainer: CloudContainable {}
extension CKDatabase: CloudStorable {
    // only for state tracking in mock operations
    public var lastExecuted: MockCKDatabaseOperation? {
        get {
            return nil
        }
        set(newValue) {
            // nothing to do
        }
    }
}
extension CKDatabaseOperation: DatabaseOperational {
    public typealias DatabaseType = CKDatabase
}
extension CKFetchRecordsOperation: CKFetchRecordsOperational {}
extension CKQueryOperation: CKQueryOperational {}
extension CKModifyRecordsOperation: CKModifyRecordsOperational {}
// ====================== CloudKit MCF protocol extensions
#endif
```

##### Setting up test target

Your project and test targets don't share environments, so all you need to do is import MCF into your test class:
```swift
import MockCloudKitFramework
```

##### Setting up for IOC
The classes, structs and methods that call CloudKit must be implemented as Generics. More precisely, if you examine the set of Protocols and Protocol extensions, you will see that the following set of CloudKit classes (and their MCF mock counterparts) must be typed as their designated Protocol:


| Protocol | CloudKit class name | MCF class name |
| -------------------------- | ------------------------- | ---------------------------- |
| CloudContainable           |  CKContainer              | MockCKContainer               |
| CloudStorable              |  CKDatabase               |  MockCKDatabase               |
| DatabaseOperational        |  CKDatabaseOperation      |  MockCKDatabaseOperation      |
| CKModifyRecordsOperational |  CKModifyRecordsOperation |  MockCKModifyRecordsOperation |
| CKFetchRecordsOperational  |  CKFetchRecordsOperation  |  MockCKFetchRecordsOperation  |
| CKQueryOperational         |  CKQueryOperation         |  MockCKQueryOperation         |

Therefore, you might have a Generic class that accepts a CKContainer or MockCKContainer via their common Protocol, CloudContainable:
```swift
class CloudController<Container: CloudContainable>: ObservableObject {
    let cloudContainer: Container
    let database: Container.DatabaseType

    init(container: Container, databaseScope: CKDatabase.Scope) {
        self.cloudContainer = container
        self.database = container.database(with: databaseScope)
    }
```
> Tip: Nothing at all needs to change for any methods! MCF converts the CloudKit operations to MCF operations in the background.

That being said, you can always inject an operation into a generic method (maybe because MCF doesn't support some functionality of a given operation).
Here, we can pass in either a CKFetchRecordsOperation or a MCF MockCKFetchRecordsOperation - they both conform to CKFetchRecordsOperational.

```swift
func doSomething<O: CKFetchRecordsOperational> (
    cKFetchRecordsOperation: O,
    _ completion: @escaping (Bool) -> Void) {
        var dbOperation = cKFetchRecordsOperation

        // fetchRecordsResultBlock always gets called when finished processing.
        dbOperation.fetchRecordsResultBlock = { result in
            if let _ = record {
                completion(true)
            } else {
                completion(false)
            }
        }

        database.add(dbOperation)
    }
}
```

## More Examples
See __MockCloudKitTestProject__, the associated test project to MockCloudKitFramework, for Unit and Integration tests of MockCloudKitFramework for multiple examples (with documentation) of how to use MockCloudKitFramework in your project.

## Attribution
The following resources gave me the necessary background knowledge to build MCF:

This post informed my thinking of how to mock CloudKit objects:
- [Simulating CloudKit Errors](https://crunchybagel.com/simulating-cloudkit-errors/) by Quentin Zervaas. 

These resources helped to sort out the handling of CloudKit errors:
- [StackOverflow post by Wael Showair](https://stackoverflow.com/a/49691453/4698449)
- [StackOverflow post by Thunk](https://stackoverflow.com/a/43575025/4698449)

Utility for converting DocC archives to static Websites:
- [docc2html](https://github.com/DoccZz/docc2html)
