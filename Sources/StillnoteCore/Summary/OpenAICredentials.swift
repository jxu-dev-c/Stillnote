import Foundation
import Security

/// Finds the OpenAI API key used for meeting tags. A key saved in Settings lives in the login
/// Keychain, never in the settings record. Without one, `OPENAI_API_KEY` is read from the app's
/// own environment and then from the user's login shell, the same place the agent CLIs find
/// their configuration.
public enum OpenAICredentials {
    public enum Source: String, Sendable {
        case keychain, environment, shell

        public var label: String {
            switch self {
            case .keychain: "Saved in Keychain"
            case .environment: "OPENAI_API_KEY from Stillnote's environment"
            case .shell: "OPENAI_API_KEY from your login shell"
            }
        }
    }

    public static let variable = "OPENAI_API_KEY"
    static let service = "com.stillnote.openai"
    static let account = "api-key"

    /// The key and where it came from, or nil when none is set anywhere. Reading the login shell
    /// starts a process, so call this off the main actor.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        useKeychain: Bool = true, useShell: Bool = true
    ) -> (key: String, source: Source)? {
        if useKeychain, let key = keychainKey() { return (key, .keychain) }
        if let key = usable(environment[variable]) { return (key, .environment) }
        if useShell, let key = usable((try? AgentEnvironment.resolve(environment: environment))?[variable]) {
            return (key, .shell)
        }
        return nil
    }

    /// The key, or a message saying how to provide one.
    public static func require() throws -> String {
        guard let key = resolve()?.key else {
            throw SummaryError("Add an OpenAI API key in Settings → Summarize, or export \(variable) in your shell.")
        }
        return key
    }

    static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || ($0.asciiValue.map { $0 < 32 } ?? false) })
        else { return nil }
        return trimmed
    }

    // MARK: - Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Set by check harnesses that run freshly built, unsigned binaries. macOS ties Keychain access
    /// to the binary's code signature, so each rebuild would otherwise ask for the login password.
    static let disableKeychainVariable = "STILLNOTE_DISABLE_KEYCHAIN"

    public static func keychainKey() -> String? {
        guard ProcessInfo.processInfo.environment[disableKeychainVariable] == nil else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return usable(String(decoding: data, as: UTF8.self))
    }

    public static func save(_ key: String) throws {
        guard let key = usable(key) else { throw ValidationError("Enter an OpenAI API key without spaces.") }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    public static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static func keychainError(_ status: OSStatus) -> ValidationError {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        return ValidationError("The Keychain couldn't save the key: \(detail).")
    }
}
