import Foundation

/// The production `LocalModelRepositoryMetadataFetching`: two JSON endpoints, no HTML, no scripts.
///
/// Splitting decode from transport is deliberate — `parseMetadata` and `parseFileListing` are pure
/// and carry every field rule, so the whole contract is pinned by fixtures and the suite never
/// touches the network.
struct LocalModelRepositoryClient: LocalModelRepositoryMetadataFetching {

    /// Faults that belong to the transport rather than to the repository's contents.
    enum ClientError: Error, Equatable {
        case requestNotBuildable
        case badStatus(Int)
        case malformedResponse
        /// A response arrived from somewhere other than the allowlisted domain family. Checked on
        /// the response, not only on the request, so a redirect cannot move the conversation.
        case responseHostRejected
    }

    /// Metadata responses are small; a model repository listing with thousands of files is not.
    /// The cap makes a hostile response a bounded read rather than a memory event.
    static let maximumResponseBytes = 4 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(for reference: LocalModelRepositoryReference) async throws -> LocalModelRepositoryMetadata {
        let data = try await get(path: "/api/models/\(reference.owner)/\(reference.repository)",
                                 host: reference.host)
        return try Self.parseMetadata(data)
    }

    func files(for reference: LocalModelRepositoryReference,
               revision: String) async throws -> [LocalModelRemoteFile] {
        guard LocalModelRepositoryReference.isValidRevision(revision) else {
            throw LocalModelImportFault.revisionNotResolved
        }
        let data = try await get(
            path: "/api/models/\(reference.owner)/\(reference.repository)/tree/\(revision)",
            host: reference.host,
            query: [URLQueryItem(name: "recursive", value: "1")])
        return try Self.parseFileListing(data)
    }

    // MARK: - Transport

    private func get(path: String, host: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let endpoint = components.url,
              LocalModelRepositoryReference.isAllowedDownloadURL(endpoint) else {
            throw ClientError.requestNotBuildable
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No credentials are sent and none are stored: the first importer is anonymous-public only.
        request.httpShouldHandleCookies = false

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard LocalModelRepositoryReference.isAllowedDownloadURL(http.url ?? endpoint) else {
            throw ClientError.responseHostRejected
        }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badStatus(http.statusCode) }
        guard data.count <= Self.maximumResponseBytes else { throw ClientError.malformedResponse }
        return data
    }

    // MARK: - Decoding

    /// `{ "sha": …, "private": Bool, "gated": false | "auto" | "manual", "cardData": { "license": … } }`
    static func parseMetadata(_ data: Data) throws -> LocalModelRepositoryMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse
        }
        guard let sha = object["sha"] as? String else { throw LocalModelImportFault.revisionNotResolved }

        // `gated` is a bool when open and a string naming the gate when not, so anything that is
        // not literally `false` counts as gated. Defaulting the unknown shape to "gated" is the
        // fail-closed reading.
        let isGated: Bool
        switch object["gated"] {
        case let flag as Bool: isGated = flag
        case is NSNull, nil: isGated = false
        default: isGated = true
        }

        let card = object["cardData"] as? [String: Any]
        // A repository may declare one licence or several; several is not something the app can
        // summarize, so only the single-string form is read.
        let license = (card?["license"] as? String) ?? (object["license"] as? String)

        return LocalModelRepositoryMetadata(revision: sha,
                                            licenseIdentifier: license,
                                            isGated: isGated,
                                            isPrivate: (object["private"] as? Bool) ?? false)
    }

    /// `[{ "type": "file", "path": …, "size": …, "lfs": { "oid": <sha256>, "size": … } }]`
    ///
    /// The digest comes from the large-file record. A file the repository does not track that way
    /// has no recorded digest, and the candidate carrying it is marked uninstallable rather than
    /// installed on trust.
    static func parseFileListing(_ data: Data) throws -> [LocalModelRemoteFile] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClientError.malformedResponse
        }
        return rows.compactMap { row in
            guard (row["type"] as? String) == "file", let path = row["path"] as? String else { return nil }
            let lfs = row["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value
                ?? (row["size"] as? NSNumber)?.int64Value
                ?? 0
            let digest = (lfs?["oid"] as? String).flatMap { isSHA256($0) ? $0.lowercased() : nil }
            return LocalModelRemoteFile(path: path, byteCount: size, sha256: digest)
        }
    }

    /// 64 lowercase hex characters. A digest of any other shape is treated as no digest at all —
    /// a store that one day records a different hash must not have it silently compared as SHA-256.
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
