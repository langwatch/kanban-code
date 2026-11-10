#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Long-lived AWS keys as a vault secret stores them, or the temporary
/// credentials of an SSO session (with `sessionToken`) that sign the
/// AssumeRole narrowing them.
public struct AwsAccessKey: Codable, Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// What `credential_process` prints (Version 1).
public struct AwsProcessCredentials: Codable, Sendable, Equatable, Hashable {
    public var Version: Int
    public var AccessKeyId: String
    public var SecretAccessKey: String
    public var SessionToken: String
    public var Expiration: String

    public init(Version: Int = 1, AccessKeyId: String, SecretAccessKey: String, SessionToken: String, Expiration: String) {
        self.Version = Version
        self.AccessKeyId = AccessKeyId
        self.SecretAccessKey = SecretAccessKey
        self.SessionToken = SessionToken
        self.Expiration = Expiration
    }

    public var expiresAt: Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: Expiration) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: Expiration)
    }
}

/// An AWS profile the vault serves as short-lived credentials. The base
/// credentials come from one of two sources:
/// - `sourceSecret`: a long-lived key whose value is
///   `{"accessKeyId","secretAccessKey"}`, used for STS AssumeRole (or
///   GetSessionToken without a role);
/// - `ssoProfile`: a profile of the Mac's `~/.aws/config` signed in through
///   IAM Identity Center; the Mac exports its credentials, then assumes
///   `roleArn` with them when one is set.
public struct VaultAwsRole: Codable, Sendable, Equatable, Hashable {
    /// Empty for an SSO profile.
    public var sourceSecret: String
    public var ssoProfile: String?
    public var roleArn: String?
    /// Session policies narrowing the role, e.g. ReadOnlyAccess.
    public var policyArns: [String]
    public var durationSeconds: Int
    public var region: String?

    public init(sourceSecret: String, roleArn: String?, policyArns: [String] = [], durationSeconds: Int = 3600,
                region: String? = nil, ssoProfile: String? = nil) {
        self.sourceSecret = sourceSecret
        self.ssoProfile = ssoProfile
        self.roleArn = roleArn
        self.policyArns = policyArns
        self.durationSeconds = durationSeconds
        self.region = region
    }

    /// A profile minted from the Mac's SSO sign-in.
    public static func sso(profile: String, roleArn: String? = nil, policyArns: [String] = [], durationSeconds: Int = 3600,
                           region: String? = nil) -> VaultAwsRole {
        VaultAwsRole(sourceSecret: "", roleArn: roleArn, policyArns: policyArns, durationSeconds: durationSeconds,
                     region: region, ssoProfile: profile)
    }

    public var isSso: Bool { !(ssoProfile ?? "").isEmpty }

    public var hasRole: Bool { !(roleArn ?? "").isEmpty }

    /// Where the credentials come from, for people: "SSO profile lw-prod-sso"
    /// or "key AWS_KEY_X".
    public var sourceLabel: String {
        if let ssoProfile, isSso { return "SSO profile \(ssoProfile)" }
        return "key \(sourceSecret)"
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSecret, ssoProfile, roleArn, policyArns, durationSeconds, region
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceSecret = try c.decodeIfPresent(String.self, forKey: .sourceSecret) ?? ""
        ssoProfile = try c.decodeIfPresent(String.self, forKey: .ssoProfile)
        roleArn = try c.decodeIfPresent(String.self, forKey: .roleArn)
        policyArns = try c.decodeIfPresent([String].self, forKey: .policyArns) ?? []
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 3600
        region = try c.decodeIfPresent(String.self, forKey: .region)
    }
}

/// STS AssumeRole / GetSessionToken over the query API, signed with SigV4.
public struct AwsSts: Sendable {
    /// Sends a signed request: the answer's body and HTTP status.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public var endpoint: URL
    public var region: String
    public var transport: Transport

    public init(region: String = "us-east-1", session: URLSession = .shared) {
        self.init(region: region) { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public init(region: String = "us-east-1", transport: @escaping Transport) {
        self.region = region
        endpoint = region == "us-east-1"
            ? URL(string: "https://sts.amazonaws.com/")!
            : URL(string: "https://sts.\(region).amazonaws.com/")!
        self.transport = transport
    }

    public enum StsError: Error, CustomStringConvertible {
        case http(Int, String)
        case unreadable
        /// STS no longer knows the long-lived key: it was deleted or rotated.
        case keyGone(String)

        public var description: String {
            switch self {
            case .http(let status, let message): "STS answered HTTP \(status): \(message)"
            case .unreadable: "STS answered something unreadable"
            case .keyGone(let name):
                "The long-lived AWS key \(name) no longer works (deleted or rotated): this profile mints nothing until it gets a new key or an SSO profile"
            }
        }

        /// The answer STS gives a key that does not exist (any more).
        public var isUnknownKey: Bool {
            guard case .http(let status, let message) = self, status == 403 else { return false }
            let lower = message.lowercased()
            return lower.contains("security token included in the request is invalid") || lower.contains("invalidclienttokenid")
        }
    }

    /// Session lengths to try, longest first: a role allows up to its
    /// MaxSessionDuration (1 to 12 hours), a user's session token up to 36.
    /// A role assumed with temporary credentials (role chaining) gets one
    /// hour at most.
    public static func durations(role: Bool, chained: Bool = false) -> [Int] {
        if chained { return [3600] }
        return role ? [43200, 28800, 14400, 7200, 3600] : [129_600, 43200, 3600]
    }

    /// Credentials for the longest session STS grants: a length it refuses
    /// as too long is tried again shorter.
    public func longestCredentials(key: AwsAccessKey, role: VaultAwsRole, sessionName: String) async throws -> AwsProcessCredentials {
        let lengths = Self.durations(role: role.hasRole, chained: key.sessionToken != nil)
        for (i, seconds) in lengths.enumerated() {
            do {
                return try await credentials(key: key, role: role, sessionName: sessionName, seconds: seconds)
            } catch StsError.http(let status, let message) where status == 400 && i < lengths.count - 1 && Self.isTooLong(message) {
                continue
            }
        }
        throw StsError.unreadable
    }

    static func isTooLong(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("durationseconds") || lower.contains("duration")
    }

    /// Credentials for the role's own `durationSeconds` (one hour at most).
    public func credentials(key: AwsAccessKey, role: VaultAwsRole, sessionName: String) async throws -> AwsProcessCredentials {
        let hasRole = !(role.roleArn ?? "").isEmpty
        return try await credentials(key: key, role: role, sessionName: sessionName,
                                     seconds: hasRole ? min(max(role.durationSeconds, 900), 3600) : max(role.durationSeconds, 900))
    }

    func credentials(key: AwsAccessKey, role: VaultAwsRole, sessionName: String, seconds: Int) async throws -> AwsProcessCredentials {
        var params: [(String, String)] = [("Version", "2011-06-15")]
        if let arn = role.roleArn, !arn.isEmpty {
            params.append(("Action", "AssumeRole"))
            params.append(("RoleArn", arn))
            params.append(("RoleSessionName", Self.sessionName(sessionName)))
            params.append(("DurationSeconds", String(seconds)))
            for (i, policy) in role.policyArns.enumerated() {
                params.append(("PolicyArns.member.\(i + 1).arn", policy))
            }
        } else {
            params.append(("Action", "GetSessionToken"))
            params.append(("DurationSeconds", String(seconds)))
        }
        let body = Self.formEncode(params)
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        var headers = ["content-type": "application/x-www-form-urlencoded; charset=utf-8"]
        if let token = key.sessionToken, !token.isEmpty { headers["x-amz-security-token"] = token }
        let signed = Self.sign(
            method: "POST", url: endpoint, body: Data(body.utf8),
            headers: headers,
            key: key, region: region, service: "sts", date: Date()
        )
        for (name, value) in signed where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        let (data, status) = try await transport(request)
        let text = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            throw StsError.http(status, Self.tag("Message", in: text) ?? String(text.prefix(300)))
        }
        guard let id = Self.tag("AccessKeyId", in: text),
              let secret = Self.tag("SecretAccessKey", in: text),
              let token = Self.tag("SessionToken", in: text),
              let expiration = Self.tag("Expiration", in: text)
        else { throw StsError.unreadable }
        return AwsProcessCredentials(Version: 1, AccessKeyId: id, SecretAccessKey: secret, SessionToken: token, Expiration: expiration)
    }

    static func sessionName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "=,.@-_"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        let trimmed = String(cleaned.prefix(64))
        return trimmed.count >= 2 ? trimmed : "kanban-vault"
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func formEncode(_ params: [(String, String)]) -> String {
        params.map { "\(uriEncode($0.0))=\(uriEncode($0.1))" }.joined(separator: "&")
    }

    static func uriEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex(_ data: some Sequence<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// SigV4 headers (`host`, `x-amz-date`, `authorization`, plus the given
    /// ones) for a request with no query string.
    static func sign(method: String, url: URL, body: Data, headers: [String: String], key: AwsAccessKey,
                     region: String, service: String, date: Date) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))

        var all = headers
        all["host"] = url.host ?? ""
        all["x-amz-date"] = amzDate
        let names = all.keys.map { $0.lowercased() }.sorted()
        let canonicalHeaders = names.map { "\($0):\(all[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let payloadHash = hex(SHA256.hash(data: body))
        let path = url.path.isEmpty ? "/" : url.path
        let canonical = [method, path, "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data("AWS4\(key.secretAccessKey)".utf8), day)
        let kSigning = hmac(hmac(hmac(kDate, region), service), "aws4_request")
        let signature = hex(hmac(kSigning, toSign))
        all["authorization"] = "AWS4-HMAC-SHA256 Credential=\(key.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return all
    }
}
