import Foundation
import Security

struct SharedKeychain {
    enum Error: Swift.Error, Equatable {
        case missingAccessGroup
        case unexpectedStatus(OSStatus)
        case unexpectedData
    }

    let accessGroup: String
    let service: String

    init(
        accessGroup: String,
        service: String = "com.yahsiu.FitbitWidget.shared"
    ) {
        self.accessGroup = accessGroup
        self.service = service
    }

    init(bundle: Bundle = .main) throws {
        guard let accessGroup = bundle.object(
            forInfoDictionaryKey: SharedConfiguration.keychainAccessGroupInfoKey
        ) as? String,
        !accessGroup.isEmpty,
        !accessGroup.contains("$(") else {
            throw Error.missingAccessGroup
        }

        self.init(accessGroup: accessGroup)
    }

    func store(_ data: Data, forKey key: String) throws {
        let query = itemQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Error.unexpectedStatus(updateStatus)
        }

        let addStatus = SecItemAdd(
            query.merging(attributes) { _, new in new } as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw Error.unexpectedStatus(addStatus)
        }
    }

    func data(forKey key: String) throws -> Data? {
        var query = itemQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw Error.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw Error.unexpectedData
        }

        return data
    }

    func deleteData(forKey key: String) throws {
        let status = SecItemDelete(itemQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unexpectedStatus(status)
        }
    }

    private func itemQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
