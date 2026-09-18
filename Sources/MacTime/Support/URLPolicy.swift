import Foundation

/// How much of a browser URL is kept when the user hasn't asked for whole ones.
///
/// Applied at capture, before the span is inserted — not on the way into the
/// database. A query string this never returns is never in the process's memory
/// either, which is the point: the `url` column is sealed at rest, but sealing
/// something is not a reason to have collected it.
enum URLPolicy {
    /// The origin of `raw` — scheme, host, and a port that isn't the scheme's
    /// default. `https://mail.google.com/mail/u/0/#inbox?ik=abc` becomes
    /// `https://mail.google.com`.
    ///
    /// nil when there is nothing safe to keep, and nil is also the answer
    /// whenever this is unsure. A URL it cannot take apart is dropped rather
    /// than stored on the hope that it held no secrets — the failure it exists
    /// to prevent is a token going to disk, not a missing row.
    ///
    /// The awkward ones, and what they were decided to mean:
    ///
    ///  - **Userinfo does not survive.** `https://user:pass@host/x` keeps
    ///    `https://host`. Writing down a password because someone typed it into
    ///    an address bar would be a remarkable way to fail at this.
    ///  - **Default ports go, others stay.** `:3000` says which local dev
    ///    server; it is not a secret. `localhost` and IP literals are hosts like
    ///    any other, and an IPv6 literal keeps its brackets.
    ///  - **Case is normalised.** Scheme and host are case-insensitive, so
    ///    lowercasing them stops `Mail.Google.com` splitting a span off its own
    ///    origin.
    ///  - **A URL with no host keeps only its scheme.** `file:///Users/jack/Q3
    ///    layoffs.pdf` becomes `file:`, `about:blank` becomes `about:`. There is
    ///    no site to name, and the path is precisely the private part — a
    ///    `data:` URL carries an entire document in its own.
    ///
    /// IDN hosts come back in their Unicode form — `xn--mnchen-3ya.de` and
    /// `münchen.de` both land on `https://münchen.de`, which is the useful
    /// answer: the two spellings of one site stop splitting into two origins.
    ///
    /// Nothing is ever produced by trimming the input. Every result is built
    /// from a parsed scheme, host and port, so there is no arrangement of path
    /// or query — however badly formed — that can survive into one, and every
    /// result that names a host is a URL that parses back.
    static func origin(of raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let parts = URLComponents(string: s), let scheme = parts.scheme?.lowercased(),
           !scheme.isEmpty {
            // `.host` is the host alone — userinfo lands in `.user`/`.password`,
            // which are simply never read here.
            guard let raw = parts.host?.lowercased(), !raw.isEmpty else { return scheme + ":" }
            guard let host = validHost(raw) else { return nil }
            return assemble(scheme: scheme, host: host, port: parts.port)
        }
        return textualOrigin(of: s)
    }

    /// `URLComponents` follows RFC 3986 and rejects strings browsers hand back
    /// happily — a Unicode host most of all. Returning `raw` when it balks would
    /// reintroduce the whole bug, so take the authority apart textually instead
    /// and apply the same rules to it.
    private static func textualOrigin(of s: String) -> String? {
        guard let head = s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*"#,
                                 options: .regularExpression) else { return nil }
        // The match stops before the first "/", "?" or "#", so it is exactly
        // scheme + "://" + authority and can hold no second "://".
        let split = String(s[head]).components(separatedBy: "://")
        guard split.count == 2 else { return nil }
        let scheme = split[0].lowercased()

        var authority = split[1]
        // Userinfo ends at the *last* "@": a password is allowed to contain one.
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        guard !authority.isEmpty else { return nil }

        var host = authority
        var port: Int?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let trailing = host[host.index(after: close)...]
            if trailing.hasPrefix(":") {
                guard let n = Int(trailing.dropFirst()) else { return nil }
                port = n
            } else if !trailing.isEmpty {
                return nil
            }
            host = String(host[...close])
        } else if let colon = host.lastIndex(of: ":") {
            guard let n = Int(host[host.index(after: colon)...]) else { return nil }
            port = n
            host = String(host[..<colon])
        }
        guard let host = validHost(host.lowercased()) else { return nil }
        return assemble(scheme: scheme, host: host, port: port)
    }

    /// The bare host, or nil if it isn't one.
    ///
    /// `URLComponents` is happy to hand back a host with a space in it, and a
    /// host with a space in it is not a host. Rejecting it keeps the promise
    /// that everything returned from here is a valid URL, and costs nothing: no
    /// browser produces one.
    ///
    /// Brackets come off an IPv6 literal first, because Foundation's answer for
    /// one varies and `assemble` puts them back. Colons survive for the same
    /// reason — a bare IPv6 literal is mostly colons.
    private static func validHost(_ raw: String) -> String? {
        var host = raw
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, host.rangeOfCharacter(from: forbiddenInHost) == nil else { return nil }
        return host
    }

    /// Whitespace and controls, plus the delimiters that would end the authority
    /// if the result were ever parsed again.
    private static let forbiddenInHost = CharacterSet(charactersIn: "/?#@[]")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)

    private static func assemble(scheme: String, host: String, port: Int?) -> String {
        // `URLComponents` hands back an IPv6 literal without its brackets, and
        // without them the result doesn't parse back as a URL.
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var out = scheme + "://" + h
        if let port, port != defaultPort(for: scheme) { out += ":\(port)" }
        return out
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        case "ftp": return 21
        default: return nil
        }
    }
}
