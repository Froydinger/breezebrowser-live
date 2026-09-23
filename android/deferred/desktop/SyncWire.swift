import CryptoKit
import Foundation
import Security

public enum SyncCollection: String, Codable, CaseIterable {
    case bookmarks
    case history
    case chats
}

/// One encrypted, revision-checked mutation in the shared sync log.
/// Binary nonce and ciphertext use unpadded base64url on the wire.
public struct SyncEnvelope: Codable, Equatable {
    public let recordId: UUID
    public let collection: SyncCollection
    public let operationId: UUID
    public let deviceId: UUID
    public let keyEpoch: Int
    public let nonce: String
    /// AES-GCM ciphertext followed by its 16-byte authentication tag.
    public let ciphertext: String
    public let deleted: Bool
    public let expectedRevision: Int

    public init(
        recordId: UUID,
        collection: SyncCollection,
        operationId: UUID,
        deviceId: UUID,
        keyEpoch: Int,
        nonce: Data,
        ciphertext: Data,
        deleted: Bool,
        expectedRevision: Int
    ) throws {
        self.recordId = recordId
        self.collection = collection
        self.operationId = operationId
        self.deviceId = deviceId
        self.keyEpoch = keyEpoch
        self.nonce = SyncBase64URL.encode(nonce)
        self.ciphertext = SyncBase64URL.encode(ciphertext)
        self.deleted = deleted
        self.expectedRevision = expectedRevision
        try validate()
    }

    public var nonceData: Data { SyncBase64URL.decode(nonce) ?? Data() }
    public var ciphertextData: Data { SyncBase64URL.decode(ciphertext) ?? Data() }

    private enum CodingKeys: String, CodingKey {
        case recordId, collection, operationId, deviceId, keyEpoch, nonce, ciphertext, deleted, expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func canonicalUUID(_ key: CodingKeys) throws -> UUID {
            let raw = try values.decode(String.self, forKey: key)
            guard let value = UUID(uuidString: raw), value.uuidString.lowercased() == raw else {
                throw SyncWireError.invalidEnvelope
            }
            return value
        }
        recordId = try canonicalUUID(.recordId)
        collection = try values.decode(SyncCollection.self, forKey: .collection)
        operationId = try canonicalUUID(.operationId)
        deviceId = try canonicalUUID(.deviceId)
        keyEpoch = try values.decode(Int.self, forKey: .keyEpoch)
        nonce = try values.decode(String.self, forKey: .nonce)
        ciphertext = try values.decode(String.self, forKey: .ciphertext)
        deleted = try values.decode(Bool.self, forKey: .deleted)
        expectedRevision = try values.decode(Int.self, forKey: .expectedRevision)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recordId.uuidString.lowercased(), forKey: .recordId)
        try values.encode(collection, forKey: .collection)
        try values.encode(operationId.uuidString.lowercased(), forKey: .operationId)
        try values.encode(deviceId.uuidString.lowercased(), forKey: .deviceId)
        try values.encode(keyEpoch, forKey: .keyEpoch)
        try values.encode(nonce, forKey: .nonce)
        try values.encode(ciphertext, forKey: .ciphertext)
        try values.encode(deleted, forKey: .deleted)
        try values.encode(expectedRevision, forKey: .expectedRevision)
    }

    public func validate() throws {
        guard keyEpoch >= 1, expectedRevision >= 0,
              let nonceBytes = SyncBase64URL.decode(nonce), nonceBytes.count == SyncCrypto.nonceByteCount,
              let ciphertextBytes = SyncBase64URL.decode(ciphertext), ciphertextBytes.count >= SyncCrypto.tagByteCount,
              ciphertext.utf8.count <= SyncWireLimits.maxCiphertextCharacters,
              nonce.utf8.count + ciphertext.utf8.count + SyncWireLimits.envelopeJSONOverheadBytes <= SyncWireLimits.maxOperationBytes
        else { throw SyncWireError.invalidEnvelope }
    }
}

/// AES-256-GCM wire crypto shared with the Android client.
public enum SyncCrypto {
    public static let vaultKeyByteCount = 32
    public static let nonceByteCount = 12
    public static let tagByteCount = 16

    /// Generate a vault key on the trusted client. Callers own keychain storage and recovery.
    public static func generateVaultKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: vaultKeyByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw SyncWireError.randomGenerationFailed }
        return Data(bytes)
    }

    public static func seal(
        _ plaintext: Data,
        vaultKey: Data,
        recordId: UUID,
        collection: SyncCollection,
        operationId: UUID,
        deviceId: UUID,
        keyEpoch: Int,
        deleted: Bool,
        expectedRevision: Int
    ) throws -> SyncEnvelope {
        guard vaultKey.count == vaultKeyByteCount, keyEpoch >= 1, expectedRevision >= 0,
              plaintext.count <= SyncWireLimits.maxPlaintextBytes else { throw SyncWireError.invalidInput }
        var nonceBytes = [UInt8](repeating: 0, count: nonceByteCount)
        let status = nonceBytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw SyncWireError.randomGenerationFailed }
        let nonceData = Data(nonceBytes)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let aad = try associatedData(recordId: recordId, collection: collection, operationId: operationId,
                                     deviceId: deviceId, keyEpoch: keyEpoch, deleted: deleted,
                                     expectedRevision: expectedRevision)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: vaultKey), nonce: nonce, authenticating: aad)
        let combinedCiphertext = sealed.ciphertext + sealed.tag
        return try SyncEnvelope(recordId: recordId, collection: collection, operationId: operationId,
                                deviceId: deviceId, keyEpoch: keyEpoch, nonce: nonceData,
                                ciphertext: combinedCiphertext, deleted: deleted,
                                expectedRevision: expectedRevision)
    }

    public static func open(_ envelope: SyncEnvelope, vaultKey: Data) throws -> Data {
        guard vaultKey.count == vaultKeyByteCount else { throw SyncWireError.invalidInput }
        try envelope.validate()
        let nonceBytes = envelope.nonceData
        let combined = envelope.ciphertextData
        guard combined.count >= tagByteCount else { throw SyncWireError.invalidEnvelope }
        let ciphertext = combined.dropLast(tagByteCount)
        let tag = combined.suffix(tagByteCount)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
        let aad = try associatedData(recordId: envelope.recordId, collection: envelope.collection,
                                     operationId: envelope.operationId, deviceId: envelope.deviceId,
                                     keyEpoch: envelope.keyEpoch, deleted: envelope.deleted,
                                     expectedRevision: envelope.expectedRevision)
        return try AES.GCM.open(box, using: SymmetricKey(data: vaultKey), authenticating: aad)
    }

    /// Exact cross-client AAD encoding: compact UTF-8 JSON array, in this order:
    /// [version, recordId, collection, operationId, deviceId, keyEpoch, deleted, expectedRevision].
    public static func associatedData(
        recordId: UUID,
        collection: SyncCollection,
        operationId: UUID,
        deviceId: UUID,
        keyEpoch: Int,
        deleted: Bool,
        expectedRevision: Int
    ) throws -> Data {
        guard keyEpoch >= 1, expectedRevision >= 0 else { throw SyncWireError.invalidInput }
        let values: [Any] = [
            1,
            recordId.uuidString.lowercased(),
            collection.rawValue,
            operationId.uuidString.lowercased(),
            deviceId.uuidString.lowercased(),
            keyEpoch,
            deleted,
            expectedRevision,
        ]
        return try JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }
}

public struct SyncPushOperationResult: Codable, Equatable {
    public let operationId: UUID
    public let cursor: Int64
    public let revision: Int?

    private enum CodingKeys: String, CodingKey { case operationId, cursor, revision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let operationId = UUID(uuidString: try values.decode(String.self, forKey: .operationId)) else {
            throw SyncWireError.invalidResponse
        }
        self.operationId = operationId
        cursor = try values.decode(Int64.self, forKey: .cursor)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(operationId.uuidString.lowercased(), forKey: .operationId)
        try values.encode(cursor, forKey: .cursor)
        try values.encodeIfPresent(revision, forKey: .revision)
    }
}

public struct SyncPushResponse: Codable {
    public let accepted: Int
    public let duplicate: Bool
    public let operations: [SyncPushOperationResult]
    public let cursor: Int64
}

public struct SyncPulledEntry: Codable {
    public let cursor: Int64
    public let revision: Int
    public let envelope: SyncEnvelope
}

public struct SyncPullResponse: Codable {
    public let entries: [SyncPulledEntry]
    public let cursor: Int64
    public let hasMore: Bool
}

public enum SyncWireError: Error {
    case invalidInput
    case invalidEnvelope
    case invalidResponse
    case randomGenerationFailed
    case insecureEndpoint
    case responseTooLarge
    case httpStatus(Int)
}

public enum SyncWireLimits {
    public static let maxOperationsPerPush = 100
    public static let maxPushBytes = 512 * 1024
    public static let maxOperationBytes = 64 * 1024
    public static let maxCiphertextCharacters = 64_000
    public static let maxPullResponseBytes = 8 * 1024 * 1024
    public static let maxPlaintextBytes = 46_000
    fileprivate static let envelopeJSONOverheadBytes = 512
    public static let maxPushResponseBytes = 1024 * 1024
}

/// Deferred sync scaffold for the current breeze-sync routes. It is not wired into app runtime.
/// The access token is passed by a future caller for each request and is never retained.
public struct SyncHTTPClient {
    private let baseURL: URL
    private let sessionConfiguration: URLSessionConfiguration

    public init(baseURL: URL) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw SyncWireError.insecureEndpoint
        }
        self.baseURL = baseURL
        self.sessionConfiguration = Self.makeEphemeralConfiguration()
    }

    public func push(_ operations: [SyncEnvelope], accessToken: String) async throws -> SyncPushResponse {
        guard !operations.isEmpty, operations.count <= SyncWireLimits.maxOperationsPerPush,
              validAccessToken(accessToken) else { throw SyncWireError.invalidInput }
        let body = try JSONEncoder().encode(SyncPushRequest(operations: operations))
        guard body.count <= SyncWireLimits.maxPushBytes else { throw SyncWireError.invalidInput }
        var request = makeRequest(path: "v1/sync/push", method: "POST", accessToken: accessToken)
        request.httpBody = body
        let (data, response) = try await boundedData(for: request, limit: SyncWireLimits.maxPushResponseBytes)
        guard (200..<300).contains(response.statusCode) else { throw SyncWireError.httpStatus(response.statusCode) }
        do { return try JSONDecoder().decode(SyncPushResponse.self, from: data) }
        catch { throw SyncWireError.invalidResponse }
    }

    public func pull(cursor: Int64, limit: Int = 100, accessToken: String) async throws -> SyncPullResponse {
        guard cursor >= 0, (1...100).contains(limit), validAccessToken(accessToken) else { throw SyncWireError.invalidInput }
        var components = URLComponents(url: endpointURL(path: ["v1", "sync", "pull"]), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "cursor", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw SyncWireError.invalidInput }
        var request = makeRequest(url: url, method: "GET", accessToken: accessToken)
        request.timeoutInterval = 30
        let (data, response) = try await boundedData(for: request, limit: SyncWireLimits.maxPullResponseBytes)
        guard (200..<300).contains(response.statusCode) else { throw SyncWireError.httpStatus(response.statusCode) }
        do { return try JSONDecoder().decode(SyncPullResponse.self, from: data) }
        catch { throw SyncWireError.invalidResponse }
    }

    private func makeRequest(path: String, method: String, accessToken: String) -> URLRequest {
        makeRequest(url: endpointURL(path: path.split(separator: "/").map(String.init)), method: method, accessToken: accessToken)
    }

    private func endpointURL(path: [String]) -> URL {
        path.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    private func validAccessToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    private func makeRequest(url: URL, method: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func boundedData(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let exchange = BoundedSyncExchange(sessionConfiguration: sessionConfiguration, byteLimit: limit)
        let (data, response) = try await exchange.perform(request)
        guard data.count <= limit else { throw SyncWireError.responseTooLarge }
        return (data, response)
    }

    private static func makeEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

private struct SyncPushRequest: Encodable {
    let operations: [SyncEnvelope]
}

private final class BoundedSyncExchange: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let configuration: URLSessionConfiguration
    private let byteLimit: Int
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var terminalError: Error?
    private var isFinished = false

    init(sessionConfiguration: URLSessionConfiguration, byteLimit: Int) {
        configuration = sessionConfiguration
        self.byteLimit = byteLimit
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            terminalError = SyncWireError.invalidResponse
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > Int64(byteLimit) {
            terminalError = SyncWireError.responseTooLarge
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count <= byteLimit, data.count <= byteLimit - body.count else {
            terminalError = SyncWireError.responseTooLarge
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        terminalError = SyncWireError.insecureEndpoint
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        session.finishTasksAndInvalidate()
        if let terminalError {
            continuation?.resume(throwing: terminalError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (body, response))
        } else {
            continuation?.resume(throwing: SyncWireError.invalidResponse)
        }
        continuation = nil
    }
}

private enum SyncBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]*$", options: .regularExpression) != nil else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: base64), encode(decoded) == value else { return nil }
        return decoded
    }
}
