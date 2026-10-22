import Foundation
import Security

/// Credentials are kept separately from the note document and Codex's own login.
/// Call these synchronous Keychain operations away from the UI's main actor.
public protocol APIKeyStore: Sendable {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// The narrow Security boundary makes denied/locked Keychain behavior testable
/// without accessing a user's credentials or displaying authentication prompts.
public protocol KeychainQueryBackend: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct KeychainAPIKeyStore: APIKeyStore {
    private let service: String
    private let account: String
    private let backend: any KeychainQueryBackend

    public init(service: String = "app.floatingai.openai-api-key", account: String = "default") {
        self.init(service: service, account: account, backend: SecurityKeychainBackend())
    }

    public init(service: String, account: String = "default", backend: any KeychainQueryBackend) {
        self.service = service
        self.account = account
        self.backend = backend
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         // Stay in this application's local Keychain item. Never match synced
         // credentials or any of the Codex CLI's independently managed items.
         kSecAttrSynchronizable as String: false]
    }

    public func read() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = backend.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw APIKeyStoreError.keychain(operation: .read, status: result.status)
        }
        guard let data = result.data, let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIKeyStoreError.invalidStoredValue
        }
        return key
    }

    public func save(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw APIKeyStoreError.emptyKey }
        let value: [String: Any] = [kSecValueData as String: Data(normalized.utf8)]
        let status = backend.update(identity, attributes: value)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(operation: .save, status: status)
        }
        var attributes = identity
        attributes[kSecValueData as String] = value[kSecValueData as String]
        attributes[kSecAttrLabel as String] = "Floating AI OpenAI API key"
        let added = backend.add(attributes)
        if added == errSecSuccess { return }
        // Another instance may have created the same item after our update.
        // Update in place rather than deleting an existing credential first.
        if added == errSecDuplicateItem {
            let retry = backend.update(identity, attributes: value)
            if retry == errSecSuccess { return }
            throw APIKeyStoreError.keychain(operation: .save, status: retry)
        }
        throw APIKeyStoreError.keychain(operation: .save, status: added)
    }

    public func delete() throws {
        let status = backend.delete(identity)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(operation: .delete, status: status)
        }
    }
}

public enum APIKeyStoreError: LocalizedError, Equatable, Sendable {
    public enum Operation: String, Sendable { case read, save, delete }
    case emptyKey
    case invalidStoredValue
    case keychain(operation: Operation, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Enter an OpenAI API key before saving."
        case .invalidStoredValue:
            return "The saved OpenAI API key could not be read. Enter it again in Settings."
        case .keychain(let operation, let status):
            let reason: String
            switch status {
            case errSecAuthFailed: reason = "Keychain access was denied."
            case errSecUserCanceled: reason = "Keychain access was cancelled."
            case errSecInteractionNotAllowed: reason = "Keychain is locked or requires permission. Unlock it and try again."
            case errSecNotAvailable: reason = "Keychain is unavailable. Try again after signing in to macOS."
            case errSecMissingEntitlement: reason = "This application is not permitted to access Keychain."
            default: reason = "Keychain returned status \(status)."
            }
            return "Could not \(operation.rawValue) the OpenAI API key. \(reason)"
        }
    }
}

private struct SecurityKeychainBackend: KeychainQueryBackend {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
