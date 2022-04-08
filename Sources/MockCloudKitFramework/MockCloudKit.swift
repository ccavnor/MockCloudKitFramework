//
//  MockCloudKit.swift
//  MockCloudKitFramework
//
//  Created by Christopher Charles Cavnor on 2/2/22.
//

#if DEBUG
import CloudKit

// ========================================
// MARK: MockCloudKitFramework Protocols
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

// ========================================
// MARK: Reflectable API
// ========================================
/// Get the properties and values from a class that implements. Uses Mirror API for Swift objects and class_copyPropertyList
/// for Objective-C classes. Objective-C class members must be annotated with @objc. Unfortunately, MockCKDatabase operations don't map
/// cleanly into pure @objc or @nonobjc, so that Reflectable will return an incomplete inventory. This is compensated for with hard-coded
/// mappings where necessary. This Key-Value coding is used simply because Swift provides no way to set a property using an interpolated
/// string. But Objective-C provides func setValue(Any?, forKey: String) and others for doing exactly that.
///
/// See the following resources for background information:
/// - [Mirror API with Objective-C classes](https://stackoverflow.com/a/68909430/4698449)
/// - [About Key-Value Coding](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/KeyValueCoding/index.html#//apple_ref/doc/uid/10000107-SW1)
public protocol Reflectable: AnyObject {
    var reflectedString: String { get }
    func reflected() -> [String: Any?]
    subscript(key: String) -> Any? { get }
    func properties() -> [String]
}
extension Reflectable {
    /// A concatenated string of object properties and values
    public var reflectedString: String {
        let reflection = reflected()
        var result = String(describing: self)
        result += " { \n"
        for (key, val) in reflection {
            result += "\t\(key): \(val ?? "null")\n"
        }
        return result + "}"
    }

    /// Get a dictionary of property names and bodies
    func reflected() -> [String: Any?] {
        let mirror = Mirror(reflecting: self)
        var dict: [String: Any?] = [:]
        for child in mirror.children {
            guard let key = child.label else {
                continue
            }
            dict[key] = child.value
        }
        return dict
    }

    /// Allow property access via subscript
    public subscript(key: String) -> Any? {
        let m = Mirror(reflecting: self)
        return m.children.first { $0.label == key }?.value
    }

    /// return a list of the property names
    public func properties() -> [String] {
        return reflected().map{ (k,v) in return k }
    }

    /// Generic function that is typed to MockCKDatabase or one of its subclasses that maps  properties that are exposable to reflection from CKDatabaseOperation
    /// to MockCKDatabaseOperation.
    /// - Returns: MockCKDatabaseOperation mapped from the CKDatabaseOperation
    fileprivate func convertToMock<DBOperation: MockCKDatabaseOperation>(database: MockCKDatabase) -> DBOperation {
        let mockOp: DBOperation = DBOperation.init()

        // reflection returns only properties with set values
        let ckDict = self.reflected()
        let mockDict = mockOp.reflected()

        // we can only set the objc members else get runtime NSUnknownKeyException:
        // ("this class is not key value coding-compliant for the key")
        _ = ckDict
            .filter { (k,v) in return mockDict.contains(where: { _ in mockDict[k] != nil }) } // filter out fields not in mock
            .map { (k,v) in mockOp.setValue(v, forKey: k) }

        return mockOp
    }
}

// used for Objective-C classes
extension Reflectable where Self: NSObject {
    public func reflected() -> [String : Any?] {
        var count: UInt32 = 0

        guard let properties = class_copyPropertyList(Self.self, &count) else {
            print(">>> no objc properties found for \(self)")
            return [:]
        }

        var dict: [String: Any] = [:]
        for i in 0..<Int(count) {
            let name = property_getName(properties[i])
            guard let nsKey = NSString(utf8String: name) else {
                continue
            }
            let key = nsKey as String
            guard responds(to: Selector(key)) else {
                continue
            }
            // nil (unset) values not added to dict
            dict[key] = value(forKey: key)
        }
        free(properties)
        return dict
    }
}

// ================================================
// MARK: CKDatabaseOperation conversion functions
// ================================================

/// Mapping functions in case we need to convert a CloudKit CKDatabaseOperation to a MCF MockCKDatabaseOperation
extension CKModifyRecordsOperation: Reflectable {
    /// Maps relevant properties from CKDatabaseOperation to MockCKDatabaseOperation for type conversion. If left untyped, T is a MockCKDatabaseOperation.
    /// - Returns: MockCKDatabaseOperation mapped from the CKDatabaseOperation
    public func getMock<T: MockCKModifyRecordsOperation>(database: MockCKDatabase) -> T {
        // do the mapping that we can via reflection
        let mockOp: T = self.convertToMock(database: database)

        // since mirroring will be incomplete (via reflection), the failsafe is to explicity map some mock fields
        mockOp.database = database
        mockOp.recordsToSave = self.recordsToSave
        mockOp.recordIDsToDelete = self.recordIDsToDelete
        mockOp.modifyRecordsResultBlock = self.modifyRecordsResultBlock
        mockOp.perRecordSaveBlock = self.perRecordSaveBlock
        mockOp.perRecordDeleteBlock = self.perRecordDeleteBlock
        mockOp.perRecordProgressBlock = self.perRecordProgressBlock
        mockOp.configuration = self.configuration
        // and these inherited members
        mockOp.name = self.name
        mockOp.completionBlock = self.completionBlock

        return mockOp
    }
}

extension CKFetchRecordsOperation: Reflectable {
    /// Maps relevant properties from CKDatabaseOperation to MockCKDatabaseOperation for type conversion. If left untyped, T is a MockCKDatabaseOperation.
    /// - Returns: MockCKDatabaseOperation mapped from the CKDatabaseOperation
    public func getMock<T: MockCKFetchRecordsOperation>(database: MockCKDatabase) -> T {
        // do the mapping that we can via reflection
        let mockOp: T = self.convertToMock(database: database)

        // since mirroring will be incomplete (via reflection), the failsafe is to explicity map some mock fields
        mockOp.database = database
        mockOp.recordIDs = self.recordIDs
        mockOp.desiredKeys = self.desiredKeys
        mockOp.configuration = self.configuration
        mockOp.fetchRecordsResultBlock = self.fetchRecordsResultBlock
        mockOp.perRecordResultBlock = self.perRecordResultBlock
        mockOp.perRecordProgressBlock = self.perRecordProgressBlock
        // and these inherited members
        mockOp.name = self.name
        mockOp.completionBlock = self.completionBlock

        return mockOp
    }
}

extension CKQueryOperation: Reflectable {
    /// Maps relevant properties from CKDatabaseOperation to MockCKDatabaseOperation for type conversion. If left untyped, T is a MockCKDatabaseOperation.
    /// - Returns: MockCKDatabaseOperation mapped from the CKDatabaseOperation
    public func getMock<T: MockCKQueryOperation>(database: MockCKDatabase) -> T {
        // do the mapping that we can via reflection
        let mockOp: T = self.convertToMock(database: database)

        // since mirroring will be incomplete (via reflection), the failsafe is to explicity map some mock fields
        mockOp.database = database
        mockOp.desiredKeys = self.desiredKeys
        mockOp.configuration = self.configuration
        mockOp.query = self.query
        mockOp.cursor = self.cursor
        mockOp.resultsLimit = self.resultsLimit
        mockOp.queryResultBlock = self.queryResultBlock
        mockOp.recordMatchedBlock = self.recordMatchedBlock
        // and these inherited members
        mockOp.name = self.name
        mockOp.completionBlock = self.completionBlock

        return mockOp
    }
}


// ====================================
// MARK: CKContainer mocking
// ====================================
// holds the state of the MockCKDatabase that is used in CKDatabase extension
fileprivate struct MockCKContainerState {
    fileprivate var cKAccountStatus: CKAccountStatus?
    fileprivate var ckRecord: CKRecord?
    fileprivate var containerIdentifier: String?
}

/**
 The mock of CloudKit.CKContainer.
 The entryway to all CloudKit interactions is CKContainer, which provides three main areas of functionality:
 1) Determining whether the user has an iCloud account.
 2) Making the user's information discoverable and discovering other users who the current user knows.
 3) Getting the databases associated with the container.
 Of these, only #2 (identity discovery) has no current MockCloudKitFramework implementation.
## Creating a mock CKContainer
CloudKit's CKContainer can be created in one of two ways. Because of typealiasing (see setup section of ``MockCloudKitFramework``), we can treat the mock CKContainer (MockCKContainer) as CloudKit.CKContainer:
 ```swift
 // really a MockCKContainer
 let container = CKContainer.default()
 ```
 Or
 ```swift
 // get a MockCKContainer that matches the container identifier
 let container = CKContainer.`init`(identifier: String)
 ```
 Note that the backticks around "init" are required for this form.
 ```swift
 // the actual CloudKit init signature looks like this
 let container = CKContainer.init(identifier: String)
 ```
 CloudKit doesn't allow us to override the init methods, so we use get as close as we can by using a function pretending to be the initializer for CloudKit.CKContainer.
 ## Operations
 ##### Setting CKContainer State
 - ``containerIdentifier``
 There are three scopes of database associated with the container: public, private, and shared. See CloudKit.CKDatabase for details. They can be accessed through their respective MockCKContainer instance properties:
 - ``publicCloudDatabase``
 - ``privateCloudDatabase``
 - ``sharedCloudDatabase``
 ##### CKContainer Methods
- ``database(with:)``
- ``accountStatus(completionHandler:)``
- ``fetchUserRecordID(completionHandler:)``
 ##### Setting Test State
 MockCKContainer allows you to set the following state for testing:
 - ``setAccountStatus``
 - ``setAccountStatusError``
 - ``setUserRecord``
 - ``resetContainer()``
## Example
 ```swift
 // Same method signature for CloudKit and MockCloudKitFramework:
 // func accountStatus(completionHandler: @escaping (CKAccountStatus, Error?) -> Void)
 cloudContainer.accountStatus { status, error  in
     if let error = error {
         print("There was an error!")
     } else {
         switch status {
         case .available:
             print("User is ok to proceed")
         case .couldNotDetermine, .noAccount, .restricted, .temporarilyUnavailable:
             print("Here is your problem --> \(status)")
         }
     }
 }
 ```
 */
public final class MockCKContainer: CloudContainable {

    // self reference
    fileprivate static var container: MockCKContainer?

    fileprivate static var publicDatabase: MockCKDatabase = MockCKDatabase(with: CKDatabase.Scope.public)
    fileprivate static var privateDatabase: MockCKDatabase = MockCKDatabase(with: CKDatabase.Scope.private)
    fileprivate static var sharedDatabase: MockCKDatabase = MockCKDatabase(with: CKDatabase.Scope.shared)

    /// The identifier set on a CKContainer. Set to "MockCKContainer" by default.
    public var containerIdentifier: String? {
        get {
            return Self.state.containerIdentifier ?? "MockCKContainer"
        }
        set {
            Self.state.containerIdentifier = newValue
        }
    }

    // Initializers
    // ---------------------------------
    /// The  init method for MockCKContainer instance. It is called via the mocked CKContainer initializers (``init(identifier:)`` and ``default()``).
    required init(identifier: String) {
        Self.state.containerIdentifier = identifier
        Self.container = self
    }
    /// Initialize a new MockCKContainer using a custom identifier. Mocks CloudKit's CKContainer init(identifier: String) initializer.
    ///
    /// CloudKit will return a container matching the given identifier, if it exists. MockCloudKitFramework always returns a new MockCKContainer (ignoring the identifier).
    /// Note that the backticks around "init" are required for this form. CloudKit doesn't allow us to override the init methods, so we use get as close as we can by using a function pretending to be the initializer for CloudKit.CKContainer.
    ///
    /// - Parameter identifier: CloudKit specifies that the "identifier must correspond to one of the ubiquity containers in the iCloud capabilities section of your Xcode project"
    /// - Returns: MockCKContainer instance
    public static func `init`(identifier: String) -> MockCKContainer {
        Self.state.containerIdentifier = identifier
        return Self.init(identifier: identifier)
    }
    /// Get an instance of MockCKContainer. Mocks CloudKit CKContainer.default() initializer.
    ///
    /// Note that the backticks around "default" are required for this form. CloudKit doesn't allow us to override the init methods, so we use get as close as we can by using a function pretending to be the initializer for CloudKit.CKContainer.
    ///
    /// - Returns: MockContainer instance
    public static func `default`() -> MockCKContainer {
        return Self.`init`(identifier: "MockCKContainer")
    }

    // CKDatabase accessors
    // ---------------------------------
    /// Get and set the public instance of MockCKDatabase
    public var publicCloudDatabase: MockCKDatabase {
        get {
            return MockCKContainer.publicDatabase
        }
        set {
            MockCKContainer.publicDatabase = newValue
        }
    }
    /// Get and set the private instance of MockCKDatabase
    public var privateCloudDatabase: MockCKDatabase {
        get {
            return MockCKContainer.privateDatabase
        }
        set {
            MockCKContainer.privateDatabase = newValue
        }
    }
    /// Get and set the shared instance of MockCKDatabase
    public var sharedCloudDatabase: MockCKDatabase {
        get {
            return MockCKContainer.sharedDatabase
        }
        set {
            MockCKContainer.sharedDatabase = newValue
        }
    }

    /// Accessor for a mocked CKDatabase with the given CloudKit.CKDatabase.Scope.
    /// - Parameter databaseScope: one of: public, private, shared
    /// - Returns: MockCKDatabase instance with the given scope.
    public func database(with databaseScope: CKDatabase.Scope) -> MockCKDatabase {
        switch databaseScope {
        case .public:
            return MockCKContainer.publicDatabase
        case .private:
            return MockCKContainer.privateDatabase
        case .shared:
            return MockCKContainer.sharedDatabase
        @unknown default:
            return MockCKContainer.publicDatabase
        }
    }

    /**
     Mocks CloudKit.CKContainer func of same signature. Gets the status of the User's iCloud account authentication. Any error returned is in domain of CKAccountStatus.
     CKAccountStatus codes are constants that indicate the availability of the user’s iCloud account. Note that ONLY the return of CKAccountStatus.available signifies
     that the user is signed into iCloud. Any other return value indicates an error.
     - Parameter completionHandler: returns CKAccountStatus of the user iCloud account or Error
     ##### Get and set CKAccountStatus
     setAccountStatus holds the CKAccountStatus value that your test expects. Only CKAccountStatus.available is considered by CloudKit to be success condition.
     ```swift
     cloudContainer.setAccountStatus = CKAccountStatus.available
     ```
     ##### Get and set CKAccountStatus as an error condition
     setAccountStatusError holds the CKAccountStatus value of the failure condition that your test expects. Failure conditions are any CKAccountStatus other than
     .available (namely: .noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine).
     ```swift
     cloudContainer.setAccountStatusError = CKAccountStatus.noAccount
     ```
     */
    public func accountStatus(completionHandler: @escaping (CKAccountStatus, Error?) -> Void) {
        if let status = setAccountStatus {
            if status == .available {
                completionHandler(.available, nil)
            } else {
                let error = NSError(domain: "CKAccountStatus", code: status.rawValue, userInfo: nil)
                completionHandler(status, error)
            }
        } else {
            // in case status wasn't set
            let error = NSError(domain: "CKAccountStatus",
                                code: CKAccountStatus.couldNotDetermine.rawValue,
                                userInfo: nil)
            completionHandler(CKAccountStatus.couldNotDetermine, error)
        }
    }
    /// Mocks CKContainer func of same signature.
    ///  Gets the user record that is set via ``setUserRecord``
    /// - Parameter completionHandler: returns CKRecord.ID if the user account exists and user is authenticated, else Error.
    /// - Returns RecordID of iCloud account user iff it exists and user is signed in (CKAccountStatus.available).
    /// - Returns CKError.notAuthenticated when no record exists.
    /// - Returns  or a CKAccountStatus other than .available for all other scenarios.
    ///
    /// ##### Get and set CKRecord that represents the User record
    /// setUserRecord holds the CKRecord that you set as a user record.
    /// ```swift
    /// let recordId = CKRecord.ID(recordName: "myRecord")
    /// let recordType = "TestRecordType"
    /// let userRecord: CKRecord = CKRecord(recordType: recordType, recordID: recordId)
    /// cloudContainer.setUserRecord = userRecord
    /// ```
    public func fetchUserRecordID(completionHandler: @escaping (CKRecord.ID?, Error?) -> Void) {
        guard let record = setUserRecord else {
            // Apple docs specify that a device that doesn’t have an iCloud account, or has an iCloud account with
            // restricted access, generates a CKError.Code.notAuthenticated error. Since we have no record, we simulate that condition.
            let error = NSError(domain: "CKErrorDomain", code: CKError.notAuthenticated.rawValue, userInfo: nil)
            completionHandler(nil, error)
            return
        }
        if setAccountStatus == .available { // success
            completionHandler(record.recordID, nil)
        } else {
            let error = NSError(domain: "CKAccountStatus",
                                code: setAccountStatus?.rawValue ?? CKAccountStatus.couldNotDetermine.rawValue,
                                userInfo: nil)
            completionHandler(nil, error)
        }
    }

    /// Reset the state of the mock CloudKit framework.
    ///
    /// resetContainer() will take the following actions when called:
    /// - reset all state on MockCKContainer
    /// - call resetState on MockCKDatabaseOperation to reset the state of all CKDatabaseOperation inheritants
    /// - call ``MockCKDatabase/resetStore()`` to reset the state of MockCKDatabase
    ///
    /// ###### In most circumstances, you will only need to call resetContainer().
    public static func resetContainer() {
        Self.state.cKAccountStatus = nil
        Self.state.ckRecord = nil
        MockCKDatabaseOperation.resetState()
        self.publicDatabase.resetStore()
        self.privateDatabase.resetStore()
        self.sharedDatabase.resetStore()
    }
}

extension MockCKContainer {
    static fileprivate var state = MockCKContainerState.init()

    /// Get and set CKAccountStatus.
    /// setAccountStatus holds the CKAccountStatus value that your test expects. Only CKAccountStatus.available is considered by CloudKit to be success condition.
    /// ```swift
    /// cloudContainer.setAccountStatus = CKAccountStatus.available
    /// ```
    public var setAccountStatus: CKAccountStatus? {
        get {
            return Self.state.cKAccountStatus
        }
        set {
            Self.state.cKAccountStatus = newValue
        }
    }
    /// Get and set  CKRecord that represents the User record.
    /// setUserRecord holds the CKRecord that you set as a user record.
    /// ```swift
    /// let recordId = CKRecord.ID(recordName: "myRecord")
    /// let recordType = "TestRecordType"
    /// let userRecord: CKRecord = CKRecord(recordType: recordType, recordID: recordId)
    /// cloudContainer.setUserRecord = userRecord
    /// ```
    public var setUserRecord: CKRecord? {
        // The user record could be inserted into CKDatabase like other records in the framework,
        // but its treated seperately to reduce the complexity of MockCKDatabase.
        get {
            return Self.state.ckRecord
        }
        set {
            Self.state.ckRecord = newValue
        }
    }
    /// Get and set  CKAccountStatus as an error condition.
    /// setAccountStatusError holds the CKAccountStatus value of the failure condition that your test expects.
    /// ```swift
    /// cloudContainer.setAccountStatusError = CKAccountStatus.noAccount
    /// ```
    public var setAccountStatusError: CKAccountStatus? {
        get {
            return Self.state.cKAccountStatus
        }
        set {
            switch newValue {
            case .available:
                fatalError("Must be set to an CKAccountStatus other than .available")
            case .couldNotDetermine:
                Self.state.cKAccountStatus = newValue
            case .noAccount:
                Self.state.cKAccountStatus = newValue
            case .restricted:
                Self.state.cKAccountStatus = newValue
            case .temporarilyUnavailable:
                Self.state.cKAccountStatus = newValue
            default:
                fatalError("Must be set to an CKAccountStatus other than .available")
            }
        }
    }
}

// ====================================
// MARK: CKDatabase mocking
// ====================================
// holds the state of the MockCKDatabase that is used in CKDatabase extension
fileprivate struct MockCKDatabaseState {
    fileprivate var _records = [CKRecord.ID: CKRecord]()
    fileprivate var scope: CKDatabase.Scope = .public
}

/**
Implements a backend that represents a CKDatabase. There are three (Mock)CKDatabase instances associated with any given (Mock)CKContainer - public, private, and shared.
 Each of these represents a CKDatabase.Scope. The database instances are distinct from each other in that they do not share data and their operations are independent. However,
 Any (Mock)CKContainer instance is essentially a singleton that points to these same three databases.
## Operations
##### Setting MockCKDatabase State
The following methods are direct accessors of MockCKDatabase for persisting mocked state and do not appear in CKDatabase API:
- ``addRecords(records:)`` : Add records to MockCKDatabase
- ``getRecords()`` : Get all records
- ``getRecords(matching:)-297wt`` : Get records with matching CKRecord.ID
- ``getRecords(matching:)-1x15c`` : Get all records satisfying the query
- ``removeRecords(with:)`` : Remove all records with matching CKRecord.ID
- ``resetStore()`` : Reset the state of the mock CKDatabase.
##### Setting CKDatabase State
This is the only mocked method of CloudKit.CKDatabase that is supported - it takes a MockCKDatabaseOperation as its sole argument:
- ``add(_:)``
The CloudKit API for CKDatabase specifies a set of functions to add and remove records from CKDatabase. However, the docs suggest
that CKDatabaseOperation operations can/should be used as more robust alternative functions. For this reason, MockCloudKitFramework
implements mocking functionality for the alternative CKDatabaseOperation operations only. The non-CKDatabaseOperation are stubbed to
return a ``OperationError/operationNotImplemented(operationName:recoveryMessage:)`` error via their registered completion handlers that contain information on
substitute CKDatabaseOperation operations to use. However, for the sake of testing convenience, a set of functions that perform transactions
directly on the mock of CKDatabase is exposed to the user:
Following are stubbed functions from CKDatabase, along with the direct accessor methods that can be used as functional equivalents:
- use ``addRecords(records:)`` instead of ``save(_:completionHandler:)``
- use ``getRecords()`` instead of ``fetch(withRecordID:completionHandler:)`` or ``fetch(withRecordIDs:desiredKeys:completionHandler:)``
- use ``getRecords(matching:)-297wt`` instead of ``fetch(withRecordID:completionHandler:)`` or ``fetch(withRecordIDs:desiredKeys:completionHandler:)``
- use ``getRecords(matching:)-1x15c`` instead of ``perform(_:inZoneWith:completionHandler:)`` or ``fetch(withQuery:inZoneWith:desiredKeys:resultsLimit:completionHandler:)``
- use ``removeRecords(with:)`` instead of ``delete(withRecordID:completionHandler:)``
## Example
```swift
// add the records and verify count
var records: [CKRecord] = [CKRecord]()
for _ in 1...100 {
    records.append(makeCKRecord())
}
Self.mockCKDatabase.addRecords(records: records)
if let records = Self.mockCKDatabase.getRecords() {
    XCTAssertEqual(records.count, 100)
} else {
    XCTFail()
}
// remove half and verify
let recordIDs = records.map { $0.recordID }
let halfRecordIds = Array(recordIDs.dropLast(50))
Self.mockCKDatabase.removeRecords(with: halfRecordIds)
if let records = Self.mockCKDatabase.getRecords() {
    XCTAssertEqual(records.count, 50)
} else {
    XCTFail()
}
// try to remove the original set even though half are gone
Self.mockCKDatabase.removeRecords(with: recordIDs)
if let records = Self.mockCKDatabase.getRecords() {
    XCTAssertEqual(records.count, 0)
} else {
    XCTFail()
}
```
 */
public final class MockCKDatabase: CloudStorable {

    private var state = MockCKDatabaseState.init()
    /// The last MockCKDatabaseOperation to have executed
    public var lastExecuted: MockCKDatabaseOperation?

    /// Init MockCKDatabase with specified CloudKit.CKDatabase.Scope
    public init(with scope: CKDatabase.Scope) {
        state.scope = scope
    }
    /// Init MockCKDatabase with CloudKit.CKDatabase.Scope of public
    public convenience init() {
        self.init(with: CKDatabase.Scope.public)
    }
}

extension MockCKDatabase {
    var _records: [CKRecord.ID: CKRecord] {
        get {
            return self.state._records
        }
        set {
            self.state._records = newValue
        }
    }
    /// Get the CKDatabase.Scope for this MockCKDatabase instance.
    public var databaseScope: CKDatabase.Scope {
        get {
            return self.state.scope
        }
        set {
            self.state.scope = newValue
        }
    }

    /// Add record to MockCKDatabase
    /// - Parameter records: an array of CKRecord to add
    public func addRecords(records: [CKRecord]) {
        _ = records.map { _records[$0.recordID] = $0 }
    }

    /// Get all records from MockCKDatabase
    /// - Returns: an array of CKRecord to get
    public func getRecords() -> [CKRecord]? {
        return self._records.map { rec in rec.value }
    }
    /// Get records with the given set of CKRecord.ID from MockCKDatabase
    /// - Parameter ids: an array of CKRecord.ID to get
    /// - Returns: the records that match the given ids
    public func getRecords(matching ids: [CKRecord.ID]) -> [CKRecord]? {
        let records = self._records.values.filter { rec in
            return ids.contains(rec.recordID)
        }
        return records
    }
    /// Get the records using a CKQuery
    /// - Parameter matching: CKQuery to match
    /// - Returns: All matching records
    public func getRecords(matching: CKQuery) -> [CKRecord]? {
        return self._records.values.filter { rec in
            matching.predicate.evaluate(with: rec)
        }
    }
    /// Remove the specified records from MockCKDatabase
    /// - Parameter ids: array of CKRecord.ID to remove
    public func removeRecords(with ids: [CKRecord.ID]) {
        _ = ids.map { id in
            self._records.removeValue(forKey: id)
        }
    }

    /// Reset the state of MockCKDatabase.
    /// Calling ``MockCKContainer/resetContainer()`` will call this.
    public func resetStore() {
        self._records.removeAll()
        assert(_records.isEmpty)
    }
}

// These are the mocked implementations for a CKDatabaseOperation added to CKDatabase
extension MockCKDatabase {
    /// Register a CKDatabaseOperation by Operation type. The processing blocks are called according to operation.
    /// - Parameter operation: the CloudKit CKOperation
    public func add(_ operation: MockCKDatabaseOperation) {
        self.lastExecuted = operation
        // assign the database associated with the operation on operation
        operation.database = self
        // CKModifyRecordsResultOperation
        // ===============================
        if let modifyOperation = operation as? MockCKModifyRecordsOperation {
            let recordsToSave: [CKRecord] = modifyOperation.recordsToSave ?? []
            let recordsIdsToDelete: [CKRecord.ID] = modifyOperation.recordIDsToDelete ?? []
            // handle per record failures (for CKError.partialFailure)
            let recordErrors: [CKRecord.ID] = MockCKDatabaseOperation.setRecordErrors ?? []
            // the userInfo dict that maps a CKRecord id to its error
            var assignedErrorUserInfo: [String : Any] = [String : Any]()

            // add the records to CKDatabase
            addRecords(records: recordsToSave)

            // map to callbacks - note that the perRecordProgressBlock docs say that the modify records operation
            // executes the perRecordProgressBlock closure one or more times for each record in the recordsToSave property.
            // So that only recordsToSave mapping will call the perRecordProgressBlock closure.
            _ = recordsToSave.map({ record in
                if recordErrors.contains(record.recordID) {
                    // set random (but incomplete) progress on record
                    modifyOperation.perRecordProgressBlock?(record, Double(Float.random(in: 0..<1)))
                    // set a random CKError for record id
                    let randoErrIndex = Int.random(in: 0..<ckErrorCodes.count)
                    let perRecordError = CKError.init(ckErrorCodes[randoErrIndex])
                    // doing this since I can't figure out how to stringify CKRecord.ID
                    let recordHandle: String = record.recordID.recordName
                    // set the error on the error userInfo dict for this record id
                    assignedErrorUserInfo[recordHandle] = perRecordError
                    // set the same error on the perRecordSaveBlock
                    modifyOperation.perRecordSaveBlock?(record.recordID, .failure(perRecordError))
                } else {
                    modifyOperation.perRecordProgressBlock?(record, 1.0)
                    modifyOperation.perRecordSaveBlock?(record.recordID, .success(record))
                }
            })
            // map to callbacks
            _ = recordsIdsToDelete.map({ recordId in
                // look up the record
                if let record = getRecords(matching: [recordId])?.first {
                    if recordErrors.contains(record.recordID) {
                        // set a random CKError for record id
                        let randoErrIndex = Int.random(in: 0..<ckErrorCodes.count)
                        let perRecordError = CKError.init(ckErrorCodes[randoErrIndex])
                        let recordHandle: String = record.recordID.recordName
                        // set the error on the error userInfo dict for this record id
                        assignedErrorUserInfo[recordHandle] = perRecordError
                        // set the same error on the perRecordDeleteBlock
                        modifyOperation.perRecordDeleteBlock?(record.recordID, .failure(perRecordError))
                    } else {
                        modifyOperation.perRecordDeleteBlock?(record.recordID, .success(()))
                    }
                }
            })
            // remove the records from CKDatabase
            removeRecords(with: recordsIdsToDelete)

            // The closure to execute after CloudKit modifies all of the records.
            if recordErrors.isEmpty {
                // fail with the transaction level error that is set
                if let transactionError: NSError = modifyOperation.setError {
                    modifyOperation.modifyRecordsResultBlock?(.failure(transactionError))
                } else {
                    // If there were no record-based errors AND setError is unset, then we send success
                    modifyOperation.modifyRecordsResultBlock?(.success(()))
                }
            } else {
                // Apple docs state "Batch operations, such as CKModifyRecordsOperation, can complete with a partialFailure error."
                // However, the CloudKit documentation for modifyRecordsResultBlock says that:
                //  "The top-level error will never be `CKError.partialFailure`. Instead, per-item errors are surfaced in prior
                //  invocations of `perRecordSaveBlock` and `perRecordDeleteBlock`.
                // These statements seem to be contrary. MCF tries to reconciles these by adding the recordID of each failed record
                // to error mappings as a dictionary literal with lookup key `CKPartialErrorsByItemIDKey` (per Apple docs)
                // but setting the the transaction wide error as `CKError.partialFailure` (because its the only place that makes sense
                // to use that error code).
                // BUT: There is some (unknown) logic in CloudKit that prevents the modifyRecordsResultBlock from being set as:
                //  let transactionError = NSError(domain: CKError.errorDomain,
                //                         code: CKError.Code.partialFailure.rawValue,
                //                         userInfo: userInfoDict)
                // If either the domain or the code are changed, this works fine. This doesn't matter at all for MockCKModifyRecordsOperation,
                // but when CKModifyRecordsOperation is converted, the modifyRecordsResultBlock returns a success result even though we set it
                // failure below. The work-around here will be to set the domain to 'MockCKErrorDomain' instead of CKError.errorDomain (which
                // resolves to 'CKErrorDomain').
                let userInfoDict: [String: Any] = [CKPartialErrorsByItemIDKey: assignedErrorUserInfo ]
                let transactionError = NSError(domain: "MockCKErrorDomain",
                                               code: CKError.Code.partialFailure.rawValue,
                                               userInfo: userInfoDict)
                modifyOperation.modifyRecordsResultBlock?(.failure(transactionError))
            }
        }

        // CKFetchRecordsOperation
        // ===============================
        else if let fetchOperation = operation as? MockCKFetchRecordsOperation {
            var records: [CKRecord]?
            if let ids = fetchOperation.recordIDs {
                records = getRecords(matching: ids)
            }
            // handle per record failures (for CKError.partialFailure)
            let recordErrors: [CKRecord.ID] = fetchOperation.setRecordErrors ?? []
            // the userInfo dict that maps a CKRecord id to its error
            var assignedErrorUserInfo: [String : Any] = [String : Any]()

            _ = records?.map({ record in
                // set desired keys
                let kvps = record.dictionaryWithValues(forKeys: record.allKeys())
                for key in kvps.keys {
                    if let desiredKeys = fetchOperation.desiredKeys {
                        if !(desiredKeys.contains(key)) {
                            record.setNilValueForKey(key) // excludes from field set
                        }
                    }
                }
                // handle per record failures (for CKError.partialFailure)
                if recordErrors.contains(record.recordID) {
                    // set a random CKError for record id
                    let randoErrIndex = Int.random(in: 0..<ckErrorCodes.count)
                    let perRecordError = CKError.init(ckErrorCodes[randoErrIndex])
                    let recordHandle: String = record.recordID.recordName
                    // set the error on the error userInfo dict for this record id
                    assignedErrorUserInfo[recordHandle] = perRecordError
                    // set random (but incomplete) progress on record
                    fetchOperation.perRecordProgressBlock?(record.recordID, Double(Float.random(in: 0..<1)))
                    // set the same error on the perRecordResultBlock
                    fetchOperation.perRecordResultBlock?(record.recordID, .failure(perRecordError))
                } else {
                    fetchOperation.perRecordProgressBlock?(record.recordID, 1.0)
                    fetchOperation.perRecordResultBlock?(record.recordID, .success(record))
                }
            })
            // The closure to execute after CloudKit modifies all of the records.
            if recordErrors.isEmpty {
                // fail with the transaction level error that is set
                if let transactionError: NSError = fetchOperation.setError {
                    fetchOperation.fetchRecordsResultBlock?(.failure(transactionError))
                } else {
                    // If there were no record-based errors AND setError is unset, then we send success
                    fetchOperation.fetchRecordsResultBlock?(.success(()))
                }
            } else {
                // Apple docs state "Batch operations, such as CKModifyRecordsOperation, can complete with a partialFailure error."
                // However, the CloudKit documentation for modifyRecordsResultBlock says that:
                //  "The top-level error will never be `CKError.partialFailure`. Instead, per-item errors are surfaced in prior invocations of `perRecordResultBlock`.
                // These statements seem to be contrary. MCF tries to reconciles these by adding the recordID of each failed record
                // to error mappings as a dictionary literal with lookup key `CKPartialErrorsByItemIDKey` (per Apple docs)
                // but setting the the transaction wide error as `CKError.partialFailure` (because its the only place that makes sense
                // to use that error code).
                // BUT: There is some (unknown) logic in CloudKit that prevents the fetchRecordsResultBlock from being set as:
                //  let transactionError = NSError(domain: CKError.errorDomain,
                //                         code: CKError.Code.partialFailure.rawValue,
                //                         userInfo: userInfoDict)
                // If either the domain or the code are changed, this works fine. This doesn't matter at all for MockCKFetchRecordsOperation,
                // but when CKFetchRecordsOperation is converted, the fetchRecordsResultBlock returns a success result even though we set it
                // failure below. The work-around here will be to set the domain to 'MockCKErrorDomain' instead of CKError.errorDomain (which
                // resolves to 'CKErrorDomain').
                let userInfoDict: [String: Any] = [CKPartialErrorsByItemIDKey: assignedErrorUserInfo ]
                let transactionError = NSError(domain: "MockCKErrorDomain",
                                               code: CKError.Code.partialFailure.rawValue,
                                               userInfo: userInfoDict)
                fetchOperation.fetchRecordsResultBlock?(.failure(transactionError))
            }
        }
        // CKQueryOperation
        // ===============================
        else if let queryOperation = operation as? MockCKQueryOperation {
            // CloudKit dynamically determines the actual limit according to various conditions at runtime,
            // but we set to arbitrary limit of 50
            var resultsLimit: Int {
                if queryOperation.resultsLimit == 0 {
                    return 50
                } else if queryOperation.resultsLimit > 50 {
                    return 50
                } else {
                    return queryOperation.resultsLimit
                }
            }
            var matchedRecords = [CKRecord]()
            // filter records that match the predicate, then filter on desired keys.
            _ = getRecords()?.map { record in
                if let predicate = queryOperation.query?.predicate {
                    if predicate.evaluate(with: record) {
                        let kvps = record.dictionaryWithValues(forKeys: record.allKeys())
                        for key in kvps.keys {
                            if let desiredKeys = queryOperation.desiredKeys {
                                if !(desiredKeys.contains(key)) {
                                    record.setNilValueForKey(key) // excludes from field set
                                }
                            }
                        }
                        matchedRecords.append(record)
                    }
                }
            }
            // return records only up to resultsLimit
            if matchedRecords.count > resultsLimit {
                matchedRecords = Array(matchedRecords[0..<resultsLimit])
            }

            if let err = queryOperation.setError {
                // called for each match: up to the results limit
                _ = matchedRecords.map({ record in
                    queryOperation.recordMatchedBlock?(record.recordID, .failure(err))
                })
                // The closure to execute after CloudKit modifies all of the records.
                queryOperation.queryResultBlock?(.failure((err)))
            } else {
                // called for each match: up to the results limit
                _ = matchedRecords.map({ record in
                    queryOperation.recordMatchedBlock?(record.recordID, .success(record))
                })
                // The closure to execute after CloudKit modifies all of the records.
                queryOperation.queryResultBlock?(.success(nil))
            }
        } else {
            print(">>> !!! unexpected operation passed ==> \(operation.description)")
            //operation.setFailure = OperationError.operationNotImplemented(operation.description)
            return
        }
        // call the custom completion block iff set
        operation.completionBlock?()
    }

    // ----------------------------------------------------------------------------------------------------------------------------------------
    // Following are non-implemented functions from CKDatabase. They are included here because they return errors via their registered completion
    // handlers that contain information on substitute methods to use (all of which are CKDatabaseOperation operations).
    // ----------------------------------------------------------------------------------------------------------------------------------------
    // Substitute CKModifyRecordsOperation
    // ------------------------------------

    /// Stubbed implementation that always returns ``OperationError/operationNotImplemented(operationName:recoveryMessage:)`` with a message to use a CKDatabaseOperation instead.
    /// - Parameters:
    ///   - record: a CKRecord to save
    ///   - completionHandler: returns the saved record or error
    /// - Returns OperationError.operationNotImplemented  with a message to use the appropriate CKDatabaseOperation instead.
    public func save(_ record: CKRecord, completionHandler: @escaping (CKRecord?, Error?) -> Void) {
        let err = OperationError.operationNotImplemented(
            operationName: "save",
            recoveryMessage: "Use CKModifyRecordsOperation via CKDatabase add operation."
        )
        completionHandler(nil, err)
    }
    /// Stubbed implementation that always returns ``OperationError/operationNotImplemented(operationName:recoveryMessage:)``with a message to use a CKDatabaseOperation instead.
    /// - Parameters:
    ///   - recordID: the CKRecord.ID to delete
    ///   - completionHandler: returns the deleted recordID or error
    /// - Returns OperationError.operationNotImplemented  with a message to use the appropriate CKDatabaseOperation instead.
    public func delete(withRecordID recordID: CKRecord.ID, completionHandler: @escaping (CKRecord.ID?, Error?) -> Void) {
        let err = OperationError.operationNotImplemented(
            operationName: "delete(withRecordID:)",
            recoveryMessage: "Use CKModifyRecordsOperation via CKDatabase add operation."
        )
        completionHandler(nil, err)
    }

    // Substitute CKFetchRecordsOperation
    // ------------------------------------
    /// Stubbed implementation that always returns ``OperationError/operationNotImplemented(operationName:recoveryMessage:)`` with a message to use a CKDatabaseOperation instead.
    /// - Parameters:
    ///   - recordID: the CKRecord.ID to fetch
    ///   - completionHandler: returns the fetched record or error
    /// - Returns OperationError.operationNotImplemented  with a message to use the appropriate CKDatabaseOperation instead.
    public func fetch(withRecordID recordID: CKRecord.ID, completionHandler: @escaping (CKRecord?, Error?) -> Void) {
        let err = OperationError.operationNotImplemented(
            operationName: "fetch(withRecordID:)",
            recoveryMessage: "Use CKFetchRecordsOperation via CKDatabase add operation."
        )
        completionHandler(nil, err)
    }
    /// Stubbed implementation that always returns ``OperationError/operationNotImplemented(operationName:recoveryMessage:)`` with a message to use a CKDatabaseOperation instead.
    /// - Parameters:
    ///   - recordID: an array of CKRecord.ID to fetch
    ///   - desiredKeys: an array of CKRecord.FieldKey to limit fetch results
    ///   - completionHandler: returns a dictionary of Record.ID as keys and Result<CKRecord, Error> as values, or an error
    /// - Returns OperationError.operationNotImplemented  with a message to use the appropriate CKDatabaseOperation instead.
    public func fetch(withRecordIDs recordIDs: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]? = nil,
                      completionHandler: @escaping (Result<[CKRecord.ID: Result<CKRecord, Error>], Error>) -> Void) {
        let err = OperationError.operationNotImplemented(
            operationName: "fetch(withRecordIDs:)",
            recoveryMessage: "Use CKFetchRecordsOperation via CKDatabase add operation."
        )
        completionHandler(.failure(err))
    }

    // Substitute CKQueryOperation
    // ------------------------------------
    /// Stubbed implementation that always returns ``OperationError/operationNotImplemented(operationName:recoveryMessage:)`` with a message to use a CKDatabaseOperation instead.
    /// - Parameters:
    ///   - query: a CKQuery to perform
    ///   - inZoneWith: the optional record zone
    ///   - completionHandler: returns an array of CKRecord that satisfy query, or  an error
    /// - Returns OperationError.operationNotImplemented  with a message to use the appropriate CKDatabaseOperation instead.
    public func perform(_ query: CKQuery, inZoneWith zoneID: CKRecordZone.ID?, completionHandler: @escaping ([CKRecord]?, Error?) -> Void) {
        let err = OperationError.operationNotImplemented(
            operationName: "perform(_:CKQuery:inZoneWith)",
            recoveryMessage: "Use CKQueryOperation via CKDatabase add operation."
        )
        completionHandler(nil, err)
    }
    /// Stubbed implementation that always returns ``OperationError/operationNotImplemented(operationName:recoveryMessage:)`` with a message to use a CKDatabaseOperation instead.
    /// - Parameters:
    ///   - query: a CKQuery to perform
    ///   - inZoneWith: the optional record zone
    ///   - desiredKeys: an array of CKRecord.FieldKey to limit fetch results
    ///   - resultsLimit: the limit of results to return
    ///   - completionHandler: returns a dictionary of matchResults and an optional cursor if the results exceed the resultLimit
    /// - Returns OperationError.operationNotImplemented  with a message to use the appropriate CKDatabaseOperation instead.
    public func fetch(withQuery: CKQuery,
                      inZoneWith: CKRecordZone.ID?,
                      desiredKeys: [CKRecord.FieldKey]? = nil,
                      resultsLimit: Int,
                      completionHandler: @escaping (
                        Result<(
                            matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                            queryCursor: CloudKit.CKQueryOperation.Cursor?
                        ), Error>
                      ) -> Void) {
        let err = OperationError.operationNotImplemented(
            operationName: "fetch(withQuery:inZoneWith:desiredKeys:resultsLimit)",
            recoveryMessage: "Use CKQueryOperation via CKDatabase add operation."
        )
        completionHandler(.failure(err))
    }
}


// ====================================
// MARK: CKDatabaseOperation mocking
// ====================================
/**
 This is the mock of CKDatabaseOperation, the abstract base class for operations that act upon databases in CloudKit. It holds the state of the executable completion blocks that are set via tests.
 ## Completion Handler
- ``MockCKDatabaseOperation/completionBlock``:  A custom completion handler that is inherited by all CKDatabaseOperation subclasses. It will be called once, after all other completion handlers have finished.

 ## Setting Test State
 Optionally set the error on the MockCKDatabaseOperation type (or the type of any of its subclasses) if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setError-swift.type.property``

 Or on an instance of MockCKDatabaseOperation type (or on an instance of any of its subclasses)
 - ``MockCKDatabaseOperation/setError-swift.property``

 Optionally set errors on individual records to set up CKError.Code.partialFailure error for batching operations on MockCKDatabaseOperation type (or the type of any of its subclasses)
 if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setRecordErrors-swift.type.property``

 Set errors on individual records to set up CKError.Code.partialFailure error for batching operations  on an instance of MockCKDatabaseOperation type (or on an instance of any of its subclasses)
 - ``MockCKDatabaseOperation/setRecordErrors-swift.property``


 ## Example
 ```swift
let noOp: CKDatabaseOperation = CKDatabaseOperation()
noOp.completionBlock = {
    // called when all other operations have completed
}
mockCKDatabase.add(noOp)
 ```
 */
public class MockCKDatabaseOperation: CKOperation, DatabaseOperational, Reflectable { // NSObject conformance via CKOperation
    /*
     Note: Some members of MockCKDatabaseOperation and its subcalsses are annotated with @objc. These inherit from NSObject
     and the @objc annotation is used for Reflectable conformance so that they can be pulled out via reflection.
     class_copyPropertyList (see Reflectable) doesn't seem to check for inherited members, so that MockCKDatabaseOperation
     annotated fields are not picked up by its subclasses.
     */
    /// Default init. Calls CKOperation init.
    required public override init() {
        super.init()
    }

    /// The operation’s configuration. Called on CKOperation.
    @objc public override var configuration: CKOperation.Configuration! {
        get {
            return Hold.operationConfiguration
        }
        set {
            Hold.operationConfiguration = newValue
        }
    }

    /// Get the MockCKDatabase instance associated with the MockCKDatabaseOperation. This can only be determined after a call to ``MockCKDatabase/add(_:)``.
    public var database: MockCKDatabase? {
        get {
            return Hold.database
        }
        set {
            Hold.database = newValue
        }
    }
}
extension MockCKDatabaseOperation {
    /// Holds the state of processing blocks so that we can set them with values.
    fileprivate struct Hold {
        // NOTE: must be static to allocate memory in extension
        static var completionBlock: (() -> Void)?
        static var modifyRecordsResultBlock: ((Result<Void, Error>) -> Void)?
        static var fetchRecordsResultBlock: ((_ operationResult: Result<Void, Error>) -> Void)?
        static var modifyPerRecordProgressBlock: ((CKRecord, Double) -> Void)?
        static var fetchPerRecordProgressBlock: ((CKRecord.ID, Double) -> Void)?
        static var perRecordResultBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)?
        static var recordMatchedBlock: ((_ recordID: CKRecord.ID, _ recordResult: Result<CKRecord, Error>) -> Void)?
        static var queryResultBlock: ((_ operationResult: Result<CKQueryOperation.Cursor?, Error>) -> Void)?
        static var perRecordSaveBlock: ((_ recordID: CKRecord.ID, _ saveResult: Result<CKRecord, Error>) -> Void)?
        static var perRecordDeleteBlock: ((_ recordID: CKRecord.ID, _ deleteResult: Result<Void, Error>) -> Void)?
        static var resultsLimit: Int?
        static var desiredKeys: [CKRecord.FieldKey]?
        static var error: NSError?
        static var recordErrors: [CKRecord.ID]?
        static var database: MockCKDatabase?
        static var operationConfiguration: CKOperation.Configuration?
    }
    // reset state for MockCKDatabaseOperation subclasses (Hold is a struct, so each subclass has its own state copy)
    fileprivate static func resetState() {
        Hold.completionBlock = nil
        Hold.modifyRecordsResultBlock = nil
        Hold.fetchRecordsResultBlock = nil
        Hold.modifyPerRecordProgressBlock = nil
        Hold.fetchPerRecordProgressBlock = nil
        Hold.perRecordResultBlock = nil
        Hold.recordMatchedBlock = nil
        Hold.queryResultBlock = nil
        Hold.perRecordSaveBlock = nil
        Hold.perRecordDeleteBlock = nil
        Hold.resultsLimit = 50 // our internal default
        Hold.desiredKeys = nil
        Hold.error = nil
        Hold.recordErrors = nil
        Hold.database = nil
        Hold.operationConfiguration = nil
    }

    /// Set the custom completion block to execute once the operation finishes. It is guaranteed to be the last completion block called.
    ///
    /// ```swift
    /// let modifyOp = CKModifyRecordsOperation()
    /// modifyOp.completionBlock = {
    ///    print("all done")
    /// }
    /// Self.mockCKDatabase.add(modifyOp)
    /// ```
    @objc public override var completionBlock: (() -> Void)? {
        get {
            return Hold.completionBlock
        }
        set {
            Hold.completionBlock = newValue
        }
    }

    /// A CKError will be set on each CKRecord that corresponds to the value for a given CKRecord.ID. A transaction wide CKError of CKError.Code.partialFailure
    /// will automatically be set (overriding any set by the user via `setError`) if one or more records is set to error. The userInfo dictionary on the .partialFailure
    /// error will contain the per record errors. It can be accessed using the  "CKPartialErrorsByItemIDKey" key on the userInfo property, or via the
    /// ``CKError_Extension/getPartialErrors()`` function.
    /// The keys of the dictionary are the IDs of the records that the operation can’t modify, and the corresponding values are errors that contain information about the failures.
    ///
    /// ```swift
    /// let operation = CKFetchRecordsOperation(recordIDs: recordIds)
    /// operation.setRecordErrors = recordIds
    /// ...
    ///  // The end user can access per record errors as follows:
    ///   if let dictionary = error.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
    ///     print("partialErrors #\(dictionary.count)")
    ///  }
    /// ```
    public var setRecordErrors: [CKRecord.ID]? {
        get {
            return Hold.recordErrors
        }
        set {
            Hold.recordErrors = newValue
        }
    }

    /// A CKError will be set on each CKRecord that corresponds to the value for a given CKRecord.ID. A transaction wide CKError of CKError.Code.partialFailure
    /// will automatically be set (overriding any set by the user via `setError`) if one or more records is set to error. The userInfo dictionary on the .partialFailure
    /// error will contain the per record errors. It can be accessed using the  "CKPartialErrorsByItemIDKey" key on the userInfo property, or via the
    /// ``CKError_Extension/getPartialErrors()`` function.
    /// The keys of the dictionary are the IDs of the records that the operation can’t modify, and the corresponding values are errors that contain information about the failures.
    ///
    /// ```swift
    /// CKFetchRecordsOperation.setRecordErrors = recordIds
    /// ...
    ///  // The end user can access per record errors as follows:
    ///   if let dictionary = error.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
    ///     print("partialErrors #\(dictionary.count)")
    ///  }
    /// ```
    public static var setRecordErrors: [CKRecord.ID]? {
        get {
            return Hold.recordErrors
        }
        set {
            Hold.recordErrors = newValue
        }
    }

    /// Set the Error to occur on a MockCKDatabaseOperation instance or an instance of any of its subclasses.
    ///
    /// ```swift
    /// let operation = CKFetchRecordsOperation(recordIDs: recordIds)
    /// let errorCode: CKError.Code = .internalError
    /// operation.setError = createError(code: errorCode)
    /// ```
    public var setError: NSError? {
        get {
            return Hold.error
        }
        set {
            Hold.error = newValue
        }
    }

    /// Set the Error to occur on  a MockCKDatabaseOperation class.
    ///
    /// ```swift
    /// CKModifyRecordsOperation.setError = createError(code: errorCode)
    /// ```
    public static var setError: NSError? {
        get {
            return Hold.error
        }
        set {
            Hold.error = newValue
        }
    }
}

// =======================================
// MARK: CKModifyRecordsOperation mocking
// =======================================
/**
 This is the mock of CloudKit CKModifyRecordsOperation, an operation that modifies one or more records.

 ## Operations
 ##### CKModifyRecordsOperation Completion Handlers
 Register one or more of the completion handlers and use as you would with CloudKit. Five closures (completion handlers) can be registered on CKModifyRecordsOperation:
 - ``modifyRecordsResultBlock``: The closure to execute after CloudKit modifies all of the records.
 - ``perRecordSaveBlock``: The closure to execute once for every saved record.
 - ``perRecordDeleteBlock``: The closure to execute once for every deleted record.
 - ``perRecordProgressBlock``: The closure to execute at least once for every record with a (fake) progress update.
 - ``MockCKDatabaseOperation/completionBlock``:  A custom completion handler that is inherited by all CKDatabaseOperation subclasses. It will be called once, after all other completion handlers have finished.

 The closures report an error of type CKError.Code.partialFailure when it modifies only some of the records successfully. The userInfo dictionary of the error contains a CKPartialErrorsByItemIDKey key that has a dictionary as its value. The keys of the dictionary are the IDs of the records that the operation can’t modify, and the corresponding values are errors that contain information about the failures.

 ##### Setting CKModifyRecordsOperation State
 - ``recordIDsToDelete``: The list of CKRecord.ID instances to delete
 - ``recordsToSave``: The list of CKRecord instances to save

 ##### Setting Test State
 Optionally set the error on the MockCKModifyRecordsOperation type if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setError-swift.type.property``

 Or on an instance of MockCKModifyRecordsOperation type.
 - ``MockCKDatabaseOperation/setError-swift.property``

 Optionally set errors on individual records to set up CKError.Code.partialFailure error for batching operations on MockCKDatabaseOperation type (or the type of any of its subclasses)
 if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setRecordErrors-swift.type.property``

 Set errors on individual records to set up CKError.Code.partialFailure error for batching operations  on an instance of MockCKDatabaseOperation type (or on an instance of any of its subclasses)
 - ``MockCKDatabaseOperation/setRecordErrors-swift.property``

 ## Example
 ```swift
 // Instantiate the operation
 let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
 let error = NSError(domain: "CKAccountStatus", code: CKAccountStatus.noAccount, userInfo: nil)
 // Optionally set the error if you want the operation to fail with that error
 operation.setError = error
 // Register one or more of the completion handlers
 operation.modifyRecordsResultBlock = { result in
    switch result {
    case .success:
        // won't get here
    case .failure(let error):
        // error contains CKAccountStatus.noAccount code
    }
 }
 // Add the operation to the database to run it
 mockCKDatabase.add(operation)
 ```
 */
public final class MockCKModifyRecordsOperation: MockCKDatabaseOperation, CKModifyRecordsOperational {
    /// The list of CKRecord instances to save
    @objc public var recordsToSave: [CKRecord]?
    /// The list of CKRecord.ID instances to delete
    @objc public var recordIDsToDelete: [CKRecord.ID]?
    /// The policy to use when saving changes to records (Ignored by MockCKModifyRecordsOperation).
    @objc public var savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys

    /// Default init: set records to save via `recordsToSave` and delete via `recordIDsToDelete` after calling this.
    public required init() {
        self.recordsToSave = []
        self.recordIDsToDelete = []
    }

    /// init with records to save or delete.
    /// - Parameters:
    ///   - recordsToSave: list of records to save
    ///   - recordIDsToDelete: list of record ids to delete
    public init(recordsToSave: [CKRecord]?, recordIDsToDelete: [CKRecord.ID]?) {
        self.recordsToSave = recordsToSave ?? []
        self.recordIDsToDelete = recordIDsToDelete ?? []
    }

    /// Get and set value for perRecordProgressBlock of a CKModifyRecordsOperation. This block will be called at least once for every record with a (faked) progress update.
    ///
    /// ```swift
    ///    let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
    ///    operation.perRecordProgressBlock = { _, _ in
    ///        resultCount += 1
    ///        if resultCount == records.count {
    ///            expect.fulfill()
    ///        }
    ///    }
    ///    mockCKDatabase.add(operation)
    /// ```
    public var perRecordProgressBlock: ((CKRecord, Double) -> Void)? {
        get {
            return Hold.modifyPerRecordProgressBlock
        }
        set {
            Hold.modifyPerRecordProgressBlock = newValue
        }
    }
    /// Get and set value for perRecordSaveBlock of a CKModifyRecordsOperation. This block is called once for every deleted record.
    ///
    /// ```swift
    ///    let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
    ///    operation.perRecordSaveBlock = { _, _ in
    ///        resultCount += 1
    ///        if resultCount == records.count {
    ///            expect.fulfill()
    ///        }
    ///    }
    ///    mockCKDatabase.add(operation)
    /// ```
    public var perRecordSaveBlock: ((CKRecord.ID, Result<CKRecord, Error> ) -> Void)? {
        get {
            return Hold.perRecordSaveBlock
        }
        set {
            Hold.perRecordSaveBlock = newValue
        }
    }
    /// Get and set value for perRecordDeleteBlock of a CKModifyRecordsOperation. This block is called once for every deleted record.
    ///
    /// ```swift
    ///    let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
    ///    operation.perRecordDeleteBlock = { _, _ in
    ///        resultCount += 1
    ///        if resultCount == records.count {
    ///            expect.fulfill()
    ///        }
    ///    }
    ///    mockCKDatabase.add(operation)
    /// ```
    public var perRecordDeleteBlock: ((CKRecord.ID, Result<Void, Error>) -> Void)? {
        get {
            return Hold.perRecordDeleteBlock
        }
        set {
            Hold.perRecordDeleteBlock = newValue
        }
    }
    /// Get and set value for modifyRecordsResultBlock of a CKModifyRecordsOperation. This block is called when the operation completes.
    ///
    /// ```swift
    /// let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
    /// operation.modifyRecordsResultBlock = { result in
    ///    switch result {
    ///    case .success:
    ///        print("yippie!")
    ///    case .failure(let error):
    ///        print("oops!")
    ///    }
    /// }
    /// mockCKDatabase.add(operation)
    /// ```
    public var modifyRecordsResultBlock: ((Result<Void, Error>) -> Void)? {
        get {
            return Hold.modifyRecordsResultBlock
        }
        set {
            Hold.modifyRecordsResultBlock = newValue
        }
    }
}

// ======================================
// MARK: CKFetchRecordsOperation mocking
// ======================================
/**
 This is the mock of CloudKit CKFetchRecordsOperation, an operation that fetches one or more records.

 ## Operations
 ##### CKFetchRecordsOperation Completion Handlers
 Register one or more of the completion handlers and use as you would with CloudKit. Four closures (completion handlers) can be registered on CKFetchRecordsOperation:
 - ``fetchRecordsResultBlock``: The closure to execute after CloudKit modifies all of the records.
 - ``perRecordResultBlock``: The closure to execute once for every fetched record.
 - ``perRecordProgressBlock``: The closure to execute at least once for every record with a (fake) progress update.
 - ``MockCKDatabaseOperation/completionBlock``:  A custom completion handler that is inherited by all CKDatabaseOperation subclasses. It will be called once, after all other completion handlers have finished.

 The closure reports an error of type CKError.Code.partialFailure when it retrieves only some of the records successfully. The userInfo dictionary of the error contains a CKPartialErrorsByItemIDKey key that has a dictionary as its value. The keys of the dictionary are the IDs of the records that the operation can’t retrieve, and the corresponding values are errors that contain information about the failures.

 ##### Setting CKFetchRecordsOperation State

 - ``desiredKeys``: Optionally set the record keys to return
- ``recordIDs``: The list of CKRecord.ID instances to fetch

 ##### Setting Test State
 Optionally set the error on the MockCKFetchRecordsOperation type if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setError-swift.type.property``

 Or on an instance of MockCKFetchRecordsOperation type.
 - ``MockCKDatabaseOperation/setError-swift.property``

 Optionally set errors on individual records to set up CKError.Code.partialFailure error for batching operations on MockCKDatabaseOperation type (or the type of any of its subclasses)
 if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setRecordErrors-swift.type.property``

 Set errors on individual records to set up CKError.Code.partialFailure error for batching operations  on an instance of MockCKDatabaseOperation type (or on an instance of any of its subclasses)
 - ``MockCKDatabaseOperation/setRecordErrors-swift.property``

 ## Example
 ```swift
 // Instantiate the operation
let operation = CKFetchRecordsOperation(recordIDs: recordIds)
// Register one or more of the completion handlers
operation.fetchRecordsResultBlock = { result in
    switch result {
    case .success:
        print("I expected this")
    case .failure(let error):
        print(">>> fetchRecordsResultBlock error: \(error.localizedDescription)")
    }
}
// Add the operation to the database to run it
Self.mockCKDatabase.add(operation)
 ```
 */
public final class MockCKFetchRecordsOperation: MockCKDatabaseOperation, CKFetchRecordsOperational {
    private var myRecordIDs: [CKRecord.ID]?

    /// The list of CKRecord.ID instances to fetch
    @objc public var recordIDs: [CKRecord.ID]? {
        get {
            return myRecordIDs
        }
        set {
            myRecordIDs = newValue
        }
    }

    /// Default init. Use `recordIDs` to set records after calling.
    public required init() {
        super.init()
        self.recordIDs = []
    }

    /// Convenience init that takes a list of record ids to fetch corresponding records.
    /// - Parameter recordIDs: list of CKRecord.ID instances for fetching records.
    public convenience init(recordIDs: [CKRecord.ID]) {
        self.init()
        self.recordIDs = recordIDs
    }

    /// Get and set value for perRecordProgressBlock of a CKFetchRecordsOperation. This block will be called at least once for every record with a (fake) progress update.
    ///
    /// ```swift
    ///    let operation = CKFetchRecordsOperation(recordIDs: recordIds)
    ///    operation.perRecordProgressBlock = { recordId, _ in
    ///        print("got record with id ---> \(recordId)")
    ///    }
    ///    mockCKDatabase.add(operation)
    /// ```
    public var perRecordProgressBlock: ((CKRecord.ID, Double) -> Void)? {
        get {
            return Hold.fetchPerRecordProgressBlock
        }
        set {
            Hold.fetchPerRecordProgressBlock = newValue
        }
    }
}
extension MockCKFetchRecordsOperation {
    /// Get and set value for perRecordResultBlock of a CKFetchRecordsOperation. This block is called once for every  record.
    ///
    /// ```swift
    ///    let operation = CKFetchRecordsOperation(recordIDs: recordIds)
    ///    operation.perRecordResultBlock = { recordId, _ in
    ///        print("got record with id ---> \(recordId)")
    ///    }
    ///    mockCKDatabase.add(operation)
    /// ```
    public var perRecordResultBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)? {
        get {
            return Hold.perRecordResultBlock
        }
        set {
            Hold.perRecordResultBlock = newValue
        }
    }
    /// Get and set value for fetchRecordsResultBlock of a CKFetchRecordsOperation. This block is called when the operation completes.
    ///
    /// ```swift
    /// let operation = CKFetchRecordsOperation(recordIDs: recordIds)
    /// operation.fetchRecordsResultBlock = { result in
    /// switch result {
    ///    case .success:
    ///       print("all good")
    ///    case .failure(let error):
    ///       print("Ruh roH! \(error.localizedDescription)")
    ///    }
    /// }
    /// mockCKDatabase.add(operation)
    /// ```
    public var fetchRecordsResultBlock: ((Result<Void, Error>) -> Void)? {
        get {
            return Hold.fetchRecordsResultBlock
        }
        set {
            Hold.fetchRecordsResultBlock = newValue
        }
    }
    /// Set the desired  keys for CKFetchRecordsOperation. Only these record keys will be returned.
    ///
    /// ```swift
    /// operation.desiredKeys = ["firstName", "lastName"]
    /// ```
    @objc public var desiredKeys: [CKRecord.FieldKey]? {
        get {
            return Hold.desiredKeys
        }
        set {
            Hold.desiredKeys = newValue
        }
    }
}

// ====================================
// MARK: CKQueryOperation mocking
// ====================================
/**
 This is the mock of CloudKit CKQueryOperation, an operation for executing queries in a database. MockCKQueryOperation will evaluate the predicate of the given CKQuery and return the records that match.

 ## Operations
 ##### CKQueryOperation Completion Handlers
 Register one or more of the completion handlers and use as you would with CloudKit. Three callback blocks (completion handlers) can be registered on CKFetchRecordsOperation:
 - ``queryResultBlock``: The closure to execute after CloudKit modifies all of the records.
 - ``recordMatchedBlock``: The closure to execute once for every fetched record.
 - ``MockCKDatabaseOperation/completionBlock``:  A custom completion handler that is inherited by all CKDatabaseOperation subclasses. It will be called once, after all other completion handlers have finished.

 ##### Setting CKQueryOperation State
 - ``resultsLimit``: Optionally set how many records to be returned
 - ``desiredKeys``: Optionally set the record keys to return
 - ``query``: The CKQuery to execute

 ##### Setting Test State
 Optionally set the error on the MockCKQueryOperation type if you want the operation to fail with that error.
 - ``MockCKDatabaseOperation/setError-swift.type.property``

 Or on an instance of MockCKQueryOperation type.
 - ``MockCKDatabaseOperation/setError-swift.property``

 ## Example
 ```swift
// form the CKQuery
let pred = NSPredicate(format: "recordType == %@", "MATCH")
let query = CKQuery(recordType: "TestRecordType", predicate: pred)
// Instantiate the operation
let operation = CKQueryOperation(query: query)

// Register one or more of the completion handlers
operation.queryResultBlock = { result in
    switch result {
    case .success(let cursor):
        print("Yeah baby!")
    case .failure:
        print("OUCH!")
    }
}
// Add the operation to the database to run it
Self.mockCKDatabase.add(operation)
 ```
 */
public final class MockCKQueryOperation: MockCKDatabaseOperation, CKQueryOperational {
    /// The query for the search.
    @objc public var query: CKQuery?
    public var cursor: CKQueryOperation.Cursor!

    /// Default init. Set the CKQuery on `query` after calling.
    public required init() {
        self.query = nil
    }

    /// Convenience init that accepts the CKQuery to run.
    /// - Parameter query: The CKQuery to execute.
    public init(query: CKQuery) {
        self.query = query
    }

    /// Set the limit on returned results for CKQueryOperation
    ///
    /// ```swift
    /// operation.resultsLimit = 10
    /// ```
    @objc public var resultsLimit: Int {
        get {
            return Hold.resultsLimit ?? 50
        }
        set {
            Hold.resultsLimit = newValue
        }
    }
    /// Set the desired keys for CKQueryOperation or CKFetchRecordsOperation
    ///
    /// ```swift
    /// operation.desiredKeys = ["firstName", "lastName"]
    /// ```
    @objc public var desiredKeys: [CKRecord.FieldKey]? {
        get {
            return Hold.desiredKeys
        }
        set {
            Hold.desiredKeys = newValue
        }
    }
    /// Get and set value for queryResultBlock of a CKQueryOperation. This block is called when the operation completes.
    /// Note - As of now, MockCKFetchRecordsOperation will not return a cursor if your result set is larger than the user or system set results limit.
    ///
    /// ```swift
    /// let operation = CKFetchRecordsOperation(recordIDs: recordIds)
    /// operation.queryResultBlock = { result in
    /// switch result {
    ///    case .success(let cursor):
    ///       if let more = cursor {
    ///          print("you have more results than the resultLimit")
    ///       }
    ///    case .failure(let error):
    ///       print("Ruh roH! \(error.localizedDescription)")
    ///    }
    /// }
    /// mockCKDatabase.add(operation)
    /// ```
    public var queryResultBlock: ((Result<CKQueryOperation.Cursor?, Error>) -> Void)? {
        get {
            return Hold.queryResultBlock
        }
        set {
            Hold.queryResultBlock = newValue
        }
    }
    /// Get and set value for recordMatchedBlock of a CKQueryOperation. This block will be called once for every record that is returned as a result of the query.
    ///
    /// ```swift
    /// let operation = CKQueryOperation(query: query)
    /// operation.recordMatchedBlock = { recordID, result in
    ///    print("got record with id --->\(recordID)")
    /// }
    /// mockCKDatabase.add(operation)
    /// ```
    public var recordMatchedBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)? {
        get {
            return Hold.recordMatchedBlock
        }
        set {
            Hold.recordMatchedBlock = newValue
        }
    }
}

// ====================================
// MARK: OperationError
// ====================================
/// An Error that encapsulates failure conditions experienced in MockCloudKitFramework.
public enum OperationError: Error {
    /// An operation was attempted for an unsupported (not mocked) CKDatabaseOperation
    case invalidDatabaseOperation(operation: MockCKDatabaseOperation.Type)
    /// An operation was attempted for an unsupported (not mocked) operation
    case operationNotImplemented(operationName: String?, recoveryMessage: String?)
}
extension OperationError: LocalizedError {
    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseOperation:
            return NSLocalizedString(
                "An invalid or unsupported CKDatabaseOperation was performed.",
                comment: ""
            )
        case .operationNotImplemented(let operation, _):
            return NSLocalizedString(
                "Operation '\(operation ?? "operation")' is not implemented.",
                comment: ""
            )
        }
    }
    /// A localized message describing the reason for the failure.
    public var failureReason: String? {
        switch self {
        case .invalidDatabaseOperation(let operation):
            return NSLocalizedString(
                "\(operation) is not a supported operation.",
                comment: ""
            )
        case .operationNotImplemented(let operation, _):
            return NSLocalizedString(
                "\(operation ?? "operation") is not implemented.",
                comment: ""
            )
        }
    }
    /// A localized message describing how one might recover from the failure.
    public var recoverySuggestion: String? {
        switch self {
        case .invalidDatabaseOperation:
            return NSLocalizedString(
                "See CKDatabaseOperation docs for valid operations.",
                comment: ""
            )
        case .operationNotImplemented(_, let recovery):
            var recoveryMessage = ""
            if let recovery = recovery {
                recoveryMessage = recovery
            }
            return NSLocalizedString(
                recoveryMessage,
                comment: ""
            )
        }
    }
}

// ====================================
// MARK: CKError
// ====================================
private enum CKErrorMessage: String {
    // case .internalError, .badContainer, .badDatabase, .invalidArguments, operationCancelled:
    case fatal = "An unrecoverable error occurred with iCloud transaction."
    // case .networkFailure, .networkUnavailable, .serverResponseLost, .serviceUnavailable:
    case network = "There was a problem communicating with iCloud; please check your network connection and try again."
    // case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure:
    case account = "There was a problem with your iCloud account; please check that you're logged in to iCloud."
    // case .requestRateLimited:
    case rate = "You've hit iCloud's rate limit; please wait a moment then try again."
    // case .quotaExceeded:
    case quota = "You've exceeded your iCloud quota; please clear up some space then try again."
    // case .zoneBusy, .zoneNotFound, .userDeletedZone:
    case zone = "There was an issue accessing the specified zone."
}

// lookup table for CKError messages
private let ckErrorMessageMappings: [CKError.Code: String] = [
    // .internalError, .badContainer, .badDatabase, .invalidArguments, .operationCancelled map to CKErrorMessage.fatal
    .internalError: CKErrorMessage.fatal.rawValue,
    .badContainer: CKErrorMessage.fatal.rawValue,
    .badDatabase: CKErrorMessage.fatal.rawValue,
    .invalidArguments: CKErrorMessage.fatal.rawValue,
    .operationCancelled: CKErrorMessage.fatal.rawValue,
    // .networkFailure, .networkUnavailable, .serverResponseLost, .serviceUnavailable map to CKErrorMessage.network
    .networkFailure: CKErrorMessage.network.rawValue,
    .networkUnavailable: CKErrorMessage.network.rawValue,
    .serverResponseLost: CKErrorMessage.network.rawValue,
    .serviceUnavailable: CKErrorMessage.network.rawValue,
    // .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure map to CKErrorMessage.account
    .notAuthenticated: CKErrorMessage.account.rawValue,
    .accountTemporarilyUnavailable: CKErrorMessage.account.rawValue,
    .permissionFailure: CKErrorMessage.account.rawValue,
    // .requestRateLimited maps to CKErrorMessage.rate
    .requestRateLimited: CKErrorMessage.rate.rawValue,
    // case .quotaExceeded maps to CKErrorMessage.quota
    .quotaExceeded: CKErrorMessage.quota.rawValue,
    // case .zoneBusy, .zoneNotFound, .userDeletedZone map to CKErrorMessage.zone
    .zoneBusy: CKErrorMessage.zone.rawValue,
    .zoneNotFound: CKErrorMessage.zone.rawValue,
    .userDeletedZone: CKErrorMessage.zone.rawValue
]

// The CKError types that will be simulated
private let ckErrorCodes: [CKError.Code] = [
    .internalError, // 1
    .networkUnavailable, // 3
    .networkFailure, // 4
    .badContainer, // 5
    .serviceUnavailable, // 6
    .requestRateLimited, // 7
    .notAuthenticated, // 9
    .permissionFailure, // 10
    .invalidArguments, // 12
    .zoneBusy, // 23
    .badDatabase, // 24
    .quotaExceeded, // 25
    .zoneNotFound, // 26
    .userDeletedZone, // 28
    .serverResponseLost, // 34
    .accountTemporarilyUnavailable // 36
]

/**
 Error extension to provide convenience functions. Called on an Error instance.
 */
public protocol Error_Extension { // to force DocC to include
    /// Convert Error to NSError
    /// - Returns: Error as NSError
    /// ```swift
    /// let nsError: NSError = error.toNSError()
    /// ```
    func toNSError() -> NSError
    /// Create an CKError from Error
    /// - Returns: CKError with CKError.internalError set by default
    /// ```swift
    /// let ckError: CKError = error.createCKError()
    /// ```
    func createCKError() -> CKError
    /// Create an CKError from the provided properties.
    /// - Parameter code: a CKError.Code
    /// - Parameter userInfo: the (optional) userInfo dictionary
    /// - Returns: CKError with a CKErrorDomain domain
    /// - Returns: CKError with CKError.internalError set by default
    /// ```swift
    /// let ckError: CKError = error.createCKError(code: CKError.internalError)
    /// ```
    func createCKError(code: Int, userInfo: [String: Any]) -> CKError
}
public extension Error {
    func toNSError() -> NSError {
        return self as NSError
    }
    func createCKError() -> CKError {
        let nsErr = self as NSError
        let ckErr = createCKError(code: nsErr.code, userInfo: nsErr.userInfo)
        return ckErr
    }
    func createCKError(code: Int, userInfo: [String: Any] = [:]) -> CKError {
        let cKErrorDomain = CKError.errorDomain
        let nsErr = self as NSError
        // set to CKError.internalError iff code not present
        let code = nsErr.code >= 1 ? nsErr.code : CKError.internalError.rawValue
        // use the userInfo param unless empty - then use the error's userInfo dict
        let userInfoDict = userInfo.isEmpty ? nsErr.userInfo : userInfo
        let error = NSError(domain: cKErrorDomain, code: code, userInfo: userInfoDict)
        return CKError(_nsError: error)
    }
}

/**
 CKError extension to provide convenience functions. Called on a CKError instance.
 */
public protocol CKError_Extension { // to force DocC to include
    /// Create an NSError containing information from the provided CKAccountStatus.
    /// - Parameter code: a CKAccountStatus
    /// - Returns: NSError with a "CKAccountStatus" domain
    /// ```swift
    /// let ckError: CKError = ckError.createAccountStatusError(code: CKAccountStatus.couldNotDetermine)
    /// ```
    func createAccountStatusError(code: CKAccountStatus) -> CKError
    /// Create an NSError containing information from the provided CKError code.
    /// - Parameter code: a CKError.Code
    /// - Returns: NSError with a CKErrorDomain domain
    /// ```swift
    /// let nsError: NSError = ckError.createNSError(with: CKError.internalError)
    /// ```
    func createNSError(with code: CKError.Code) -> NSError
    /// Transaction errors of type CKError.partialFailure  contains  record errors in the userInfo dictionary.
    /// - Returns: Dictionary of userInfo errors
    /// ```swift
    /// let userInfo: NSDictionary? = ckError.getPartialErrors()
    /// ```
    func getPartialErrors() -> NSDictionary?
}
extension CKError {
    public func createAccountStatusError(code: CKAccountStatus) -> CKError {
        let nsError = NSError(domain: "CKAccountStatus", code: code.rawValue, userInfo: self.userInfo)
        return CKError(_nsError: nsError)
    }
    public func createNSError(with code: CKError.Code) -> NSError {
        let cKErrorDomain = CKError.errorDomain
        let error = NSError(domain: cKErrorDomain, code: code.rawValue, userInfo: self.userInfo)
        return error
    }
    public func getPartialErrors() -> NSDictionary? {
        // same as accessing via error userInfo with CKPartialErrorsByItemIDKey key
        let errors = partialErrorsByItemID as NSDictionary?
        return errors
    }
}

#endif
