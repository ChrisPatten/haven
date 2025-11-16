import Foundation
import Security

public protocol SecretResolving: Sendable {
    func resolve(secretRef: String) throws -> Data
}

public enum SecretResolverError: Error, LocalizedError {
    case invalidReference(String)
    case itemNotFound(String)
    case unexpectedResult
    case keychainError(OSStatus)
    
    public var errorDescription: String? {
        switch self {
        case .invalidReference(let ref):
            return "Invalid secret reference: \(ref)"
        case .itemNotFound(let ref):
            return "Secret not found for reference: \(ref)"
        case .unexpectedResult:
            return "Unexpected data returned from secret resolver"
        case .keychainError(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error \(status): \(message)"
            }
            return "Keychain error \(status)"
        }
    }
}

public struct KeychainSecretResolver: SecretResolving {
    public init() {}
    
    public func resolve(secretRef: String) throws -> Data {
        let descriptor = try KeychainDescriptor(reference: secretRef)
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        query[kSecAttrService] = descriptor.service
        query[kSecAttrAccount] = descriptor.account
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw SecretResolverError.itemNotFound(secretRef)
        }
        // Check for user interaction required (password prompt needed)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw SecretResolverError.keychainError(status)
        }
        guard status == errSecSuccess else {
            throw SecretResolverError.keychainError(status)
        }
        guard let data = item as? Data else {
            throw SecretResolverError.unexpectedResult
        }
        return data
    }
    
    private struct KeychainDescriptor {
        var service: String
        var account: String
        
        init(reference: String) throws {
            guard let url = URL(string: reference), url.scheme == "keychain" else {
                throw SecretResolverError.invalidReference(reference)
            }
            let service = url.host ?? ""
            let account: String
            if let queryItem = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "account" })?.value {
                account = queryItem
            } else {
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                account = path
            }
            guard !service.isEmpty, !account.isEmpty else {
                throw SecretResolverError.invalidReference(reference)
            }
            self.service = service
            self.account = account
        }
    }
}

public struct InlineSecretResolver: SecretResolving {
    private let storage: [String: Data]
    
    public init(storage: [String: Data]) {
        self.storage = storage
    }
    
    public func resolve(secretRef: String) throws -> Data {
        guard let value = storage[secretRef] else {
            throw SecretResolverError.itemNotFound(secretRef)
        }
        return value
    }
}

public struct ChainSecretResolver: SecretResolving {
    private let resolvers: [any SecretResolving]
    
    public init(_ resolvers: [any SecretResolving]) {
        self.resolvers = resolvers
    }
    
    public func resolve(secretRef: String) throws -> Data {
        var lastError: Error = SecretResolverError.itemNotFound(secretRef)
        for resolver in resolvers {
            do {
                return try resolver.resolve(secretRef: secretRef)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
