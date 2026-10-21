import Foundation
import Security

/// A place where Claude Code may keep its credential JSON.
///
/// Sources only read: they never create, write, modify or delete anything, and they keep nothing between calls.
public protocol CredentialSource: Sendable {
    /// A short, non-secret description such as `Keychain: Claude Code-credentials`.
    var label: String { get }

    /// The raw credential JSON, or `nil` when this source does not exist.
    func readCredentialData() throws(CredentialError) -> Data?
}

/// One generic-password item in the user's login Keychain, looked up by service name.
///
/// The only Keychain call is `SecItemCopyMatching`, which reads; nothing is added, updated or deleted.
public struct KeychainCredentialSource: CredentialSource {
    public let service: String

    public var label: String { "Keychain: \(service)" }

    public init(service: String) {
        self.service = service
    }

    public func readCredentialData() throws(CredentialError) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .malformed }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }
}

/// Claude Code's plaintext credentials file (`D/.credentials.json`).
///
/// The file is read only if it is a regular file, owned by the current user, with no group or other permission bits,
/// and at most 1 MiB. A symlink as the final path component is refused; symlinks in parent directories (for example
/// a `~/.claude` that links elsewhere) are followed. The checks run on the opened descriptor, so the file cannot be
/// swapped between the check and the read. A missing file is `nil`; a file that cannot be opened or fails a check is
/// ``CredentialError/insecureFile``.
public struct FileCredentialSource: CredentialSource {
    public let fileURL: URL

    public var label: String { "File: \(fileURL.path)" }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func readCredentialData() throws(CredentialError) -> Data? {
        // O_NOFOLLOW: a symlink fails with ELOOP. O_NONBLOCK: a FIFO cannot make open(2) wait for a writer; it has no
        // effect on reading a regular file.
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw .insecureFile
        }
        defer { close(descriptor) }

        var info = stat()
        guard
            fstat(descriptor, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(),
            info.st_mode & 0o077 == 0,
            info.st_size <= off_t(OAuthCredential.maxCredentialDataSize)
        else { throw .insecureFile }

        return try Self.readAll(descriptor, capacity: Int(info.st_size))
    }

    /// Reads to end of file, refusing to grow past the size limit if the file changes after `fstat`.
    private static func readAll(_ descriptor: Int32, capacity: Int) throws(CredentialError) -> Data {
        let limit = OAuthCredential.maxCredentialDataSize
        var data = Data(capacity: capacity)
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw .malformed
            }
            data.append(contentsOf: chunk[0..<count])
            guard data.count <= limit else { throw .insecureFile }
        }
    }
}
