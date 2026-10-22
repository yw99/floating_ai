import Foundation
import Security
import FloatingAICore

public enum CredentialChecks {
    /// Offline checks use only injected backends, never the real Keychain.
    public static func run() throws {
        try testAuthenticationModePersistence()
        try testKeychainCRUDQueriesAndDuplicateRace()
        try testKeychainDenialAndInvalidValues()
    }

    public static func testAuthenticationModePersistence() throws {
        let legacy = Data(#"{"version":1,"cliPath":"","defaultModelID":"","defaultEffort":"","notes":[]}"#.utf8)
        let old = try JSONDecoder().decode(AppDocument.self, from: legacy)
        try require(old.authenticationMode == nil, "Older documents preserve the existing sign-in default")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-credential-document-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NotePersistence(directory: directory)
        for mode in [AuthenticationMode.codexSignIn, .openAIAPIKey] {
            var document = old
            document.authenticationMode = mode
            try persistence.save(document)
            try require(try persistence.load().authenticationMode == mode, "Authentication mode survives an atomic save")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.documentURL)) as! [String: Any]
            // Authentication metadata is a single mode value; credential storage
            // has no field in the on-disk document.
            try require(Set(object.keys) == ["version", "cliPath", "defaultModelID", "defaultEffort", "authenticationMode", "notes"],
                        "Authentication persistence adds no credential fields")
        }
        var unknown = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        unknown["authenticationMode"] = "unsupported-future-billing-mode"
        let invalid = try JSONSerialization.data(withJSONObject: unknown)
        try invalid.write(to: persistence.documentURL, options: .atomic)
        do {
            _ = try persistence.load()
        } catch is DecodingError {
            try require(try Data(contentsOf: persistence.documentURL) == invalid, "Unknown mode leaves the original document untouched")
            return
        }
        throw Failure(description: "Unknown authentication mode silently selected a fallback")
    }

    public static func testKeychainCRUDQueriesAndDuplicateRace() throws {
        let fixtureKey = "fixture-credential-not-an-api-key"
        let service = "app.floatingai.credential-check.\(UUID())"
        let backend = FakeKeychainBackend(readStatus: errSecSuccess, data: Data(fixtureKey.utf8),
                                          updateStatuses: [errSecItemNotFound, errSecSuccess], addStatus: errSecDuplicateItem)
        let store = KeychainAPIKeyStore(service: service, backend: backend)
        try require(try store.read() == fixtureKey, "Read returns the stored UTF-8 credential")
        try store.save(fixtureKey)
        try store.delete()
        let calls = backend.calls()
        try require(calls.map(\.operation) == ["read", "update", "add", "update", "delete"],
                    "Duplicate creation retries update without deleting the previous credential")
        for call in calls {
            try require(call.query[kSecAttrService as String] as? String == service, "Every operation targets the application service")
            try require(call.query[kSecAttrAccount as String] as? String == "default", "Every operation targets the selected account")
            try require(call.query[kSecAttrSynchronizable as String] as? Bool == false, "Credentials never synchronize")
            try require(call.query[kSecClass as String] as? String == kSecClassGenericPassword as String, "Credential is a generic password")
        }
        try require(calls[0].query[kSecReturnData as String] as? Bool == true, "Only the credential read requests secret data")
        try require(calls[0].query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String, "Read limits matching to one item")
        try require(calls[1].attributes?[kSecValueData as String] as? Data == Data(fixtureKey.utf8), "Update stores data in Keychain")
        try require(calls[2].query[kSecValueData as String] as? Data == Data(fixtureKey.utf8), "Add stores data in Keychain")
        try require(calls[4].query[kSecValueData as String] == nil, "Delete never supplies secret data")

        let missing = KeychainAPIKeyStore(service: service,
            backend: FakeKeychainBackend(readStatus: errSecItemNotFound, deleteStatus: errSecItemNotFound))
        try require(try missing.read() == nil, "Only item-not-found is an absent credential")
        try missing.delete()
        let existing = FakeKeychainBackend(updateStatuses: [errSecSuccess])
        try KeychainAPIKeyStore(service: service, backend: existing).save(fixtureKey)
        try require(existing.calls().map(\.operation) == ["update"], "Replacing an existing key preserves the Keychain item")
    }

    public static func testKeychainDenialAndInvalidValues() throws {
        let secret = "fixture-secret-never-in-errors"
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecNotAvailable, errSecMissingEntitlement] {
            let backend = FakeKeychainBackend(readStatus: status, updateStatuses: [status], deleteStatus: status)
            let store = KeychainAPIKeyStore(service: "app.floatingai.denied-fixture", backend: backend)
            try expect(.keychain(operation: .read, status: status)) { _ = try store.read() }
            try expect(.keychain(operation: .save, status: status)) { try store.save(secret) }
            try expect(.keychain(operation: .delete, status: status)) { try store.delete() }
            try require(backend.calls().map(\.operation) == ["read", "update", "delete"], "Denied access does not trigger replacement or a fallback")
            for operation in [APIKeyStoreError.Operation.read, .save, .delete] {
                let error = APIKeyStoreError.keychain(operation: operation, status: status)
                try require(!error.localizedDescription.contains(secret), "Keychain failures never include the credential")
                try require(error.localizedDescription.contains(operation.rawValue), "Keychain errors identify the failed operation")
            }
        }
        for data: Data? in [nil, Data([0xff]), Data(), Data(" \n".utf8)] {
            let store = KeychainAPIKeyStore(service: "app.floatingai.invalid-fixture",
                backend: FakeKeychainBackend(readStatus: errSecSuccess, data: data))
            try expect(.invalidStoredValue) { _ = try store.read() }
        }
        let backend = FakeKeychainBackend()
        let store = KeychainAPIKeyStore(service: "app.floatingai.empty-fixture", backend: backend)
        try expect(.emptyKey) { try store.save(" \n") }
        try require(backend.calls().isEmpty, "Empty input never changes Keychain")
        let failedAdd = KeychainAPIKeyStore(service: "app.floatingai.failed-add-fixture",
            backend: FakeKeychainBackend(updateStatuses: [errSecItemNotFound], addStatus: errSecAuthFailed))
        try expect(.keychain(operation: .save, status: errSecAuthFailed)) { try failedAdd.save(secret) }
    }

    /// Explicit integration check only: a random service prevents reading or
    /// replacing real credentials. No API request is made using these fake values.
    public static func testLocalKeychainRoundTrip() throws {
        let store = KeychainAPIKeyStore(service: "app.floatingai.credential-check.\(UUID())")
        defer { try? store.delete() }
        try require(try store.read() == nil, "Namespaced Keychain fixture starts empty")
        try store.save("fixture-first-not-an-api-key")
        try require(try store.read() == "fixture-first-not-an-api-key", "Keychain reads a newly saved item")
        try store.save("fixture-second-not-an-api-key")
        try require(try store.read() == "fixture-second-not-an-api-key", "Keychain updates an existing item")
        try store.delete()
        try require(try store.read() == nil, "Keychain deletes the fixture item")
        try store.delete()
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
        if try !value() { throw Failure(description: description) }
    }
    private static func expect(_ expected: APIKeyStoreError, operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as APIKeyStoreError {
            try require(error == expected, "Unexpected Keychain error classification")
            return
        }
        throw Failure(description: "Expected Keychain error was not reported")
    }
}

private final class FakeKeychainBackend: KeychainQueryBackend, @unchecked Sendable {
    struct Call {
        let operation: String
        let query: [String: Any]
        var attributes: [String: Any]?
    }
    private let lock = NSLock()
    private let readStatus: OSStatus
    private let data: Data?
    private var updateStatuses: [OSStatus]
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus
    private var recorded: [Call] = []
    init(readStatus: OSStatus = errSecItemNotFound, data: Data? = nil,
         updateStatuses: [OSStatus] = [errSecSuccess], addStatus: OSStatus = errSecSuccess,
         deleteStatus: OSStatus = errSecSuccess) {
        self.readStatus = readStatus; self.data = data; self.updateStatuses = updateStatuses
        self.addStatus = addStatus; self.deleteStatus = deleteStatus
    }
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(operation: "read", query: query))
        return (readStatus, data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(operation: "add", query: attributes))
        return addStatus
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(operation: "update", query: query, attributes: attributes))
        return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(operation: "delete", query: query))
        return deleteStatus
    }
    func calls() -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
