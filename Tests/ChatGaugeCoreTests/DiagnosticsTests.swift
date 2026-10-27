import Testing
@testable import ChatGaugeCore

@Suite struct DiagnosticsTests {
    @Test func scrubsHome() {
        #expect(DiagnosticsReport.scrub("/Users/someone/Library/x", home: "/Users/someone") == "~/Library/x")
        #expect(DiagnosticsReport.scrub("/Volumes/Drive/models", home: "/Users/someone") == "/Volumes/Drive/models")
        #expect(DiagnosticsReport.scrub("/a", home: "/") == "/a")
    }

    @Test func alignsColumns() {
        let r = DiagnosticsReport(lines: [("App", "0.1.0"), ("Models folder", "/Users/me/.ollama/models")])
        let t = r.text(home: "/Users/me")
        #expect(t == "App:           0.1.0\nModels folder: ~/.ollama/models")
    }
}
