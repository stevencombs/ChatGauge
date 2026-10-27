import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct UpdatesTests {
    @Test func semver() {
        #expect(SemVer("v0.1.0") == SemVer(major: 0, minor: 1, patch: 0))
        #expect(SemVer("1.2")! < SemVer("1.10.0")!)
        #expect(SemVer("1.0.0-beta.2")! < SemVer("1.0.0")!)
        #expect(SemVer("1.0.0-beta.2")! < SemVer("1.0.0-beta.10")!)
        #expect(SemVer("abc") == nil)
        #expect(SemVer("1.2.3.4") == nil)
    }

    @Test func parsesRelease() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/o/r/releases/tag/v0.2.0","body":"Notes","draft":false,"prerelease":false,"assets":[{"name":"ChatGauge-0.2.0.zip","browser_download_url":"https://example.com/z.zip"}]}"#
        let r = try #require(ReleaseInfo.parseLatest(Data(json.utf8)))
        #expect(r.version == SemVer("0.2.0"))
        #expect(r.zipURL?.absoluteString == "https://example.com/z.zip")
        let pre = #"{"tag_name":"v0.3.0","html_url":"https://x","prerelease":true}"#
        #expect(ReleaseInfo.parseLatest(Data(pre.utf8)) == nil)
        #expect(ReleaseInfo.parseLatest(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
    }

    @Test func parsesBrew() {
        let json = #"{"formulae":[{"name":"ollama","installed_versions":["0.40.10"],"current_version":"0.40.11"},{"name":"git","installed_versions":["2.0"],"current_version":"2.1"}],"casks":[]}"#
        let o = BrewOutdated.parse(Data(json.utf8))
        #expect(o == [BrewOutdated(name: "ollama", installed: "0.40.10", current: "0.40.11")])
        #expect(BrewOutdated.parse(Data("nope".utf8)).isEmpty)
    }

    @Test func digests() {
        #expect(ModelDigest.manifestURL(for: "qwen2.5vl:7b")?.absoluteString == "https://registry.ollama.ai/v2/library/qwen2.5vl/manifests/7b")
        #expect(ModelDigest.manifestURL(for: "llava")?.absoluteString == "https://registry.ollama.ai/v2/library/llava/manifests/latest")
        #expect(ModelDigest.manifestURL(for: "someone/model:q4")?.absoluteString == "https://registry.ollama.ai/v2/someone/model/manifests/q4")
        let m = Data("manifest".utf8)
        let d = ModelDigest.digest(ofManifest: m)
        #expect(d.count == 64)
        #expect(!ModelDigest.isNewer(local: "sha256:" + d, remoteManifest: m))
        #expect(ModelDigest.isNewer(local: "abc", remoteManifest: m))
        #expect(!ModelDigest.isNewer(local: nil, remoteManifest: m))
    }

    @Test func policy() {
        let tool = UpdateItem(kind: .tool, name: "ollama", installed: "1", available: "2", detail: "")
        let app = UpdateItem(kind: .app, name: "ChatGauge", installed: "0.1.0", available: "0.2.0", detail: "")
        let quiet = UpdatePolicy.Context(generating: false, loading: false, resolveOpen: false, idleFor: 600)
        #expect(UpdatePolicy.shouldAutoInstall(tool, mode: .autoWhenIdle, context: quiet))
        #expect(!UpdatePolicy.shouldAutoInstall(tool, mode: .notify, context: quiet))
        #expect(!UpdatePolicy.shouldAutoInstall(app, mode: .autoWhenIdle, context: quiet))
        var busy = quiet; busy.generating = true
        #expect(!UpdatePolicy.shouldAutoInstall(tool, mode: .autoWhenIdle, context: busy))
        var resolve = quiet; resolve.resolveOpen = true
        #expect(UpdatePolicy.blockedReason(resolve) == "DaVinci Resolve is open")
        var fresh = quiet; fresh.idleFor = 10
        #expect(!UpdatePolicy.shouldAutoInstall(tool, mode: .autoWhenIdle, context: fresh))
        #expect(UpdatePolicy.isDue(lastChecked: nil))
        #expect(!UpdatePolicy.isDue(lastChecked: Date().addingTimeInterval(-3600)))
        #expect(UpdatePolicy.isDue(lastChecked: Date().addingTimeInterval(-90_000)))
        #expect(UpdatePolicy.summary(["Ollama", "qwen2.5vl:7b", "ChatGauge"]) == "Ollama, qwen2.5vl:7b and ChatGauge")
    }
}
