import Foundation

/// Masks secret-shaped text before Flash keeps it anywhere: Flash.log,
/// activity.json, the inbox. One copy, shared by the app and the hook binary.
///
/// Shapes, not values: a token's prefix and length (`ghp_…`, `sk-ant-…`, a
/// JWT, a PEM block), `NAME=value` where the name says secret, credentials
/// in URLs and `Authorization:` headers. A value only a lookup can know (a
/// plain keychain password) has no shape; Flash never stores command output,
/// so that one never reaches here.
///
/// Masks read `[REDACTED kind]`, which no rule matches, so running a string
/// through twice changes nothing.
public enum Redact {

    struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// Specific enough to say "the output held a secret". The loose
        /// ones (a `--password x` flag, `password: "…"` in source) only
        /// mask; as evidence they'd fire on ordinary code.
        let strong: Bool
    }

    /// Order matters only where shapes overlap: PEM first, so a key's body
    /// isn't chewed into smaller matches.
    static let rules: [Rule] = [
        ("private-key", #"(?<secret>-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z))"#),
        ("anthropic-key", #"(?<secret>\bsk-ant-[A-Za-z0-9_-]{20,})"#),
        ("openai-key", #"(?<secret>\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,})"#),
        ("github-token", #"(?<secret>\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}))"#),
        ("gitlab-token", #"(?<secret>\bglpat-[A-Za-z0-9_-]{20,})"#),
        ("aws-key-id", #"(?<secret>\b(?:AKIA|ASIA)[0-9A-Z]{16}\b)"#),
        ("slack-token", #"(?<secret>\bxox[abprs]-[A-Za-z0-9-]{10,})"#),
        ("google-key", #"(?<secret>\bAIza[0-9A-Za-z_-]{35})"#),
        ("npm-token", #"(?<secret>\bnpm_[A-Za-z0-9]{36}\b)"#),
        ("huggingface-token", #"(?<secret>\bhf_[A-Za-z0-9]{30,}\b)"#),
        ("stripe-key", #"(?<secret>\b[rs]k_(?:live|test)_[A-Za-z0-9]{20,})"#),
        ("jwt", #"(?<secret>\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#),
        ("auth-header", #"(?i)\b(?:authorization\s*[:=]\s*["']?)?(?:bearer|basic)\s+(?<secret>[A-Za-z0-9._~+/=-]{12,})"#),
        ("url-password", #"(?i)\b[a-z][a-z0-9+.-]*://[^\s:/@'"]+:(?<secret>[^\s@/'"]+)@"#),
        // An env-style dump line (`cat .env`, `printenv`): upper-case name,
        // `=` with no spaces, at the start of a line.
        ("env-assignment", #"(?m)^[ \t]*(?:export[ \t]+)?[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY)[A-Z0-9_]*=(?<secret>"[^"$\n]{6,}"|'[^'\n]{6,}'|[^\s'"$\[][^\s]{5,})"#),
        ("cli-secret", #"(?i)--(?:password|passphrase|token|api-key|secret|auth-token|client-secret)(?:=|\s+)(?<secret>[^\s'"$\[-][^\s'"]{5,})"#),
        // NAME=value / NAME: value in shell and YAML, "name": "value" in
        // JSON. Values starting with $ or [ are references or masks. A
        // quoted name needs quotes on both sides and a quoted value, so
        // `find-generic-password": Script` in prose isn't an assignment.
        ("secret-assignment",
         #"(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*"#
            + #"\s*[=:]\s*(?<secret>"[^"$\[\n]{6,}"|'[^'\[\n]{6,}'|[^\s'"$\[&|;)(,}]{6,})"#),
        ("secret-assignment",
         #"(?i)["'][A-Z0-9_-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_-]*["']"#
            + #"\s*:\s*["'](?<secret>[^"'$\[\n]{6,})["']"#),
    ].map { Rule(kind: $0.0, regex: try! NSRegularExpression(pattern: $0.1),
                 strong: !weakKinds.contains($0.0)) }

    static let weakKinds: Set<String> = ["cli-secret", "secret-assignment"]

    /// `text` with every secret-shaped part masked.
    public static func text(_ text: String) -> String {
        scan(text).text
    }

    /// Which kinds of secret `text` holds, without keeping them. Sorted,
    /// each once: "github-token", "jwt", …. Strong shapes only.
    public static func kinds(in text: String) -> [String] {
        Array(Set(scan(text).kinds).subtracting(weakKinds)).sorted()
    }

    static func scan(_ input: String) -> (text: String, kinds: [String]) {
        guard !input.isEmpty else { return (input, []) }
        var text = input
        var kinds: [String] = []
        for rule in rules {
            let ns = text as NSString
            let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let mutable = NSMutableString(string: text)
            for match in matches.reversed() {
                let range = match.range(withName: "secret")
                guard range.location != NSNotFound, range.length > 0 else { continue }
                mutable.replaceCharacters(in: range, with: "[REDACTED \(rule.kind)]")
                kinds.append(rule.kind)
            }
            text = mutable as String
        }
        return (text, kinds)
    }

    /// Every string inside a JSON value, masked; structure kept.
    public static func json(_ value: Any) -> Any {
        switch value {
        case let string as String: return text(string)
        case let array as [Any]: return array.map(json)
        case let dict as [String: Any]: return dict.mapValues(json)
        default: return value
        }
    }
}
