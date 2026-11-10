import Foundation

/// Credentials of an AWS profile signed in through IAM Identity Center, as
/// `aws configure export-credentials --format process` prints them. Only
/// the Mac holds the SSO sign-in; it runs the CLI, this reads the answer.
public enum AwsSso {
    /// The credentials of one `~/.aws/config` profile.
    public typealias Source = @Sendable (_ profile: String) async throws -> AwsProcessCredentials

    /// A device without the SSO sign-in (the phone, a box).
    public static let unavailable: Source = { _ in throw SsoError.onlyOnMac }

    public enum SsoError: Error, CustomStringConvertible, Equatable {
        /// The sign-in is missing or past its time. `session` is the
        /// profile's `sso_session`, when the config names one.
        case expired(profile: String, session: String?)
        case profileMissing(String)
        case noCli
        case onlyOnMac
        /// The profile narrows with session policies but names no role to
        /// assume with them: handing out the SSO role itself would give its
        /// full access.
        case cannotNarrow(String)
        case failed(String)

        public var description: String {
            switch self {
            case .expired(let profile, let session):
                let login = session.map { "aws sso login --sso-session \($0)" } ?? "aws sso login --profile \(profile)"
                return "AWS SSO session expired: run \(login) on the Mac, then approve again"
            case .profileMissing(let profile):
                return "The AWS profile \(profile) is not set up on the Mac (~/.aws/config)"
            case .noCli:
                return "The aws CLI is not installed on the Mac"
            case .onlyOnMac:
                return "AWS credentials from SSO are minted on the Mac: approve this in Kanban Code on the Mac"
            case .cannotNarrow(let profile):
                return "\(profile) is read-only but has no role to narrow the SSO credentials with, so nothing is handed out"
            case .failed(let text):
                return "aws configure export-credentials failed: \(text)"
            }
        }
    }

    /// The CLI arguments that print a profile's credentials.
    public static func exportArguments(profile: String) -> [String] {
        ["configure", "export-credentials", "--profile", profile, "--format", "process"]
    }

    /// Environment variables that would make the CLI ignore `--profile`'s
    /// sign-in or pick up other credentials: they are left out of its run.
    public static let ignoredEnvironment: Set<String> = [
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN",
        "AWS_PROFILE", "AWS_DEFAULT_PROFILE",
    ]

    /// What one run of `aws configure export-credentials` means.
    public static func credentials(exitCode: Int32, stdout: String, stderr: String, profile: String,
                                   session: String?) throws -> AwsProcessCredentials {
        guard exitCode == 0 else {
            let lower = stderr.lowercased()
            if lower.contains("could not be found") && lower.contains("profile") {
                throw SsoError.profileMissing(profile)
            }
            // "Token for <session> does not exist" (never signed in),
            // "Token has expired and refresh failed", "The SSO session
            // associated with this profile has expired or is otherwise invalid".
            if lower.contains("sso") && ["expired", "invalid", "sso login", "refresh", "does not exist"].contains(where: lower.contains)
                || lower.contains("token has expired") {
                throw SsoError.expired(profile: profile, session: session)
            }
            let line = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "exit \(exitCode)"
            throw SsoError.failed(String(line.prefix(300)))
        }
        guard let credentials = try? JSONDecoder().decode(AwsProcessCredentials.self, from: Data(stdout.utf8)),
              !credentials.AccessKeyId.isEmpty, !credentials.SessionToken.isEmpty, credentials.expiresAt != nil
        else { throw SsoError.failed("its output is not credential_process JSON with an expiry") }
        return credentials
    }

    /// The `sso_session` a profile of `~/.aws/config` names, nil when the
    /// profile is missing or signs in without one.
    public static func ssoSession(ofProfile profile: String, config: String) -> String? {
        var inProfile = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                inProfile = header == "profile \(profile)" || (profile == "default" && header == "default")
                continue
            }
            guard inProfile, let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == "sso_session" {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
