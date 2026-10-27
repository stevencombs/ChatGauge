import CryptoKit
import Foundation

// MARK: - Versions

/// Semantic version (`1.2.3`, a leading `v` and a `-beta.1` suffix are fine).
public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public var prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first else { return nil }
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.count <= 3, nums.allSatisfy({ $0 != nil }) else { return nil }
        let n = nums.map { $0! } + Array(repeating: 0, count: 3 - nums.count)
        self.init(major: n[0], minor: n[1], patch: n[2], prerelease: parts.count > 1 ? parts[1] : nil)
    }

    public var description: String { "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "") }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let x?, let y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

// MARK: - GitHub releases

public struct ReleaseInfo: Equatable, Sendable {
    public var version: SemVer
    public var tag: String
    public var url: URL
    public var notes: String
    public var zipURL: URL?

    /// Parses `GET /repos/{owner}/{repo}/releases/latest`. Drafts and prereleases are ignored.
    public static func parseLatest(_ data: Data) -> ReleaseInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, let v = SemVer(tag),
              (o["draft"] as? Bool) != true, (o["prerelease"] as? Bool) != true,
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        let zip = assets.compactMap { a -> URL? in
            guard let n = a["name"] as? String, n.hasSuffix(".zip"), n.hasPrefix("ChatGauge") else { return nil }
            return (a["browser_download_url"] as? String).flatMap(URL.init(string:))
        }.first
        return ReleaseInfo(version: v, tag: tag, url: page, notes: (o["body"] as? String) ?? "", zipURL: zip)
    }

    public static func latestRequest(repo: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 20)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("ChatGauge", forHTTPHeaderField: "User-Agent")
        return r
    }
}

// MARK: - Homebrew

public struct BrewOutdated: Equatable, Sendable {
    public var name: String
    public var installed: String
    public var current: String

    /// The tools ChatGauge watches (formula names).
    public static let watched = ["ollama", "whisper-cpp", "ffmpeg"]

    /// Parses `brew outdated --json=v2` and keeps the watched formulae.
    public static func parse(_ data: Data, watching: [String] = watched) -> [BrewOutdated] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let formulae = (o["formulae"] as? [[String: Any]]) ?? []
        return formulae.compactMap { f in
            guard let n = f["name"] as? String, watching.contains(n) else { return nil }
            let inst = (f["installed_versions"] as? [String])?.last ?? "?"
            return BrewOutdated(name: n, installed: inst, current: (f["current_version"] as? String) ?? "?")
        }
    }

    public static func brewPath(fm: FileManager = .default) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { fm.isExecutableFile(atPath: $0) }
    }

    /// True when the formula lives in a Homebrew Cellar (so `brew upgrade` is the right way to update it).
    public static func isBrewInstalled(_ formula: String, fm: FileManager = .default) -> Bool {
        ["/opt/homebrew/Cellar/\(formula)", "/usr/local/Cellar/\(formula)"].contains { fm.fileExists(atPath: $0) }
    }
}

// MARK: - Model digests

public enum ModelDigest {
    /// `qwen2.5vl:7b` → registry.ollama.ai/v2/library/qwen2.5vl/manifests/7b; `user/model:tag` keeps the namespace.
    public static func manifestURL(for model: String) -> URL? {
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty, !name.contains("..") else { return nil }
        let tag = parts.count > 1 ? parts[1] : "latest"
        if name.contains(".") && name.split(separator: "/").count > 2 { return nil }   // other registries: skip
        let path = name.contains("/") ? name : "library/\(name)"
        return URL(string: "https://registry.ollama.ai/v2/\(path)/manifests/\(tag)")
    }

    public static func manifestRequest(for model: String) -> URLRequest? {
        guard let u = manifestURL(for: model) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 20)
        r.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        return r
    }

    /// Ollama's local digest is the SHA-256 of the manifest bytes.
    public static func digest(ofManifest data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalized(_ d: String) -> String {
        d.lowercased().replacingOccurrences(of: "sha256:", with: "")
    }

    public static func isNewer(local: String?, remoteManifest: Data) -> Bool {
        guard let local, !local.isEmpty else { return false }
        return normalized(local) != digest(ofManifest: remoteManifest)
    }
}

// MARK: - Items and policy

public struct UpdateItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case app, tool, model }
    public var kind: Kind
    public var name: String
    public var installed: String
    public var available: String?      // nil = up to date
    public var detail: String

    public var id: String { "\(kind.rawValue):\(name)" }
    public var needsUpdate: Bool { available != nil }

    public init(kind: Kind, name: String, installed: String, available: String?, detail: String) {
        self.kind = kind; self.name = name; self.installed = installed; self.available = available; self.detail = detail
    }
}

public enum UpdatePolicy {
    public struct Context: Equatable, Sendable {
        public var generating: Bool
        public var loading: Bool
        public var resolveOpen: Bool
        public var idleFor: TimeInterval
        public init(generating: Bool, loading: Bool, resolveOpen: Bool, idleFor: TimeInterval) {
            self.generating = generating; self.loading = loading; self.resolveOpen = resolveOpen; self.idleFor = idleFor
        }
    }

    public static let idleNeeded: TimeInterval = 120
    public static let checkInterval: TimeInterval = 24 * 3600

    /// Installs never start while a chat is generating, a model is loading, or DaVinci Resolve is open.
    public static func blockedReason(_ c: Context) -> String? {
        if c.generating { return "a chat is answering" }
        if c.loading { return "a model is loading" }
        if c.resolveOpen { return "DaVinci Resolve is open" }
        return nil
    }

    /// Auto mode also waits for a couple of quiet minutes. The app itself is never auto-installed.
    public static func shouldAutoInstall(_ item: UpdateItem, mode: UpdateMode, context c: Context) -> Bool {
        guard mode == .autoWhenIdle, item.needsUpdate, item.kind != .app else { return false }
        return blockedReason(c) == nil && c.idleFor >= idleNeeded
    }

    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let l = lastChecked else { return true }
        return now.timeIntervalSince(l) >= checkInterval || l > now
    }

    /// "Ollama, qwen2.5vl:7b and ChatGauge"
    public static func summary(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
