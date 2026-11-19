import CryptoKit
import Foundation
import LocalAuthentication
import Security

@MainActor
struct CredentialStore {
    // The enclave exports only a device-wrapped key. Opening it requires the
    // same device and an unlocked user session, without an interactive ACL.
    private struct Envelope: Codable {
        let deviceKey: Data
        let ephemeralPublicKey: Data
        let sealed: Data
    }
    let root: URL
    private var directory: URL { root.appendingPathComponent("Credentials", isDirectory: true) }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }

    private func cipherKey(device: SecureEnclave.P256.KeyAgreement.PrivateKey,
                           peer: P256.KeyAgreement.PublicKey, id: UUID) throws -> SymmetricKey {
        let shared = try device.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.uuidString.utf8),
                                              sharedInfo: Data("app.folio.reader.api.v1".utf8), outputByteCount: 32)
    }
    private func context() -> LAContext {
        let auth = LAContext()
        auth.interactionNotAllowed = true
        return auth
    }
    func get(_ id: UUID) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: file(id)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard let old = try legacyKey(id) else {
                throw ReaderError(bilingual("请在「设置 → AI 服务」粘贴并保存一次 API Key。", "Paste and save your API key once in Settings → AI services."))
            }
            try set(old, for: id)
            _ = legacyOperation(id, delete: true)
            return old
        }
        let box = try JSONDecoder().decode(Envelope.self, from: data)
        let device = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: box.deviceKey, authenticationContext: context())
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: box.ephemeralPublicKey)
        let key = try cipherKey(device: device, peer: peer, id: id)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: box.sealed), using: key)
        return String(decoding: bytes, as: UTF8.self)
    }
    func set(_ key: String, for id: UUID) throws {
        guard SecureEnclave.isAvailable else {
            throw ReaderError(bilingual("这台 Mac 的安全隔区不可用，无法保存密钥。", "The Secure Enclave on this Mac is unavailable. The key could not be saved."))
        }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil) else {
            throw ReaderError(bilingual("无法创建密钥的设备保护策略。", "Could not create the device protection policy for this key."))
        }
        let device = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context())
        let peer = P256.KeyAgreement.PrivateKey().publicKey
        let cipher = try cipherKey(device: device, peer: peer, id: id)
        let sealed = try AES.GCM.seal(Data(key.utf8), using: cipher)
        guard let combined = sealed.combined else { throw CryptoKitError.incorrectParameterSize }
        let box = Envelope(deviceKey: device.dataRepresentation, ephemeralPublicKey: peer.x963Representation, sealed: combined)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(box).write(to: file(id), options: [.atomic])
    }
    func remove(_ id: UUID) throws {
        let status = legacyOperation(id, delete: true).0
        if status != errSecItemNotFound && status != errSecSuccess && status != errSecInteractionNotAllowed && status != errSecAuthFailed {
            throw ReaderError(bilingual("无法删除旧密钥（\(status)）。", "Could not delete the legacy key (\(status))."))
        }
        do { try FileManager.default.removeItem(at: file(id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
    private func legacyKey(_ id: UUID) throws -> String? {
        let (status, result) = legacyOperation(id, delete: false)
        switch status {
        case errSecSuccess: return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return nil
        default: throw ReaderError(bilingual("无法读取旧密钥（\(status)）。", "Could not read the legacy key (\(status))."))
        }
    }
    // Older builds used the classic macOS file-based keychain, which has its
    // own UI switch. Scope it to this synchronous migration or deletion.
    private func legacyOperation(_ id: UUID, delete: Bool) -> (OSStatus, CFTypeRef?) {
        var allowed = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            return (errSecInteractionNotAllowed, nil)
        }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "app.folio.reader.api",
                                    kSecAttrAccount as String: id.uuidString]
        if delete { return (SecItemDelete(query as CFDictionary), nil) }
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
}
