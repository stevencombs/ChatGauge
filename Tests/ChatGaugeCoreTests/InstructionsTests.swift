import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct InstructionsTests {
    @Test func glossaryParsing() {
        let g = InstructionText.parseGlossary("retroCombs\nTeensyROM, MEGA65; retrocombs\n\n  .  \n")
        #expect(g == ["retroCombs", "TeensyROM", "MEGA65"])
        let long = InstructionText.parseGlossary([String(repeating: "x", count: 50)])
        #expect(long.first?.count == 40)
        let many = InstructionText.parseGlossary((0..<200).map { "term\($0)" })
        #expect(many.count <= InstructionLimits.glossaryTerms)
        #expect(InstructionText.glossaryLength(many) <= InstructionLimits.glossaryChars)
    }

    @Test func sanitizeStripsControlAndLimits() {
        let s = InstructionText.sanitize("Hi\u{0007} there  \r\n\n\n\nnext", limit: 100)
        #expect(s == "Hi there\n\nnext")
        #expect(InstructionText.sanitize(String(repeating: "a", count: 3000), limit: 2000).count == 2000)
    }

    @Test func systemPromptCombines() {
        var f = InstructionsFile.standard
        f.glossary = ["retroCombs", "MEGA65"]
        let p = f.systemPrompt()
        #expect(p?.hasPrefix("You are a helpful assistant") == true)
        #expect(p?.hasSuffix("Spell these names exactly as written: retroCombs, MEGA65.") == true)
        #expect(f.whisperPrompt() == "retroCombs, MEGA65")
        f.enabled = false
        #expect(f.systemPrompt() == nil)
        #expect(f.summary == "Off")
    }

    @Test func emptyMeansNoSystemMessage() {
        let f = InstructionsFile(presets: [InstructionPreset(name: "Blank", standing: "  ")])
        #expect(f.systemPrompt() == nil)
        #expect(f.whisperPrompt() == nil)
    }

    @Test func normalizeFixesNamesAndActive() {
        var f = InstructionsFile(presets: [InstructionPreset(name: "A", standing: ""), InstructionPreset(name: "a", standing: ""),
                                           InstructionPreset(name: "  ", standing: "")])
        f.activePresetID = UUID()
        let n = f.normalized()
        #expect(n.presets.map(\.name) == ["A", "a 2", "Untitled"])
        #expect(n.activePresetID == n.presets.first?.id)
        let empty = InstructionsFile(presets: []).normalized()
        #expect(empty.presets.count == 3)
    }

    @Test func roundTripAndBadFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-ins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instructions.json")
        #expect(InstructionsFile.load(from: url).presets.map(\.name) == ["Default", "Script helper", "Spec sheet"])
        var f = InstructionsFile.standard
        f.glossary = ["MEGA65"]
        f.activePresetID = f.presets[2].id
        try f.save(to: url)
        let back = InstructionsFile.load(from: url)
        #expect(back.active?.name == "Spec sheet")
        #expect(back.glossary == ["MEGA65"])
        try Data("nope".utf8).write(to: url)
        #expect(InstructionsFile.load(from: url).presets.count == 3)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("instructions.bad.json").path))
    }

    @Test func rejectsOtherApps() {
        let other = Data(#"{"app":"ClipGauge","schema":1,"presets":[]}"#.utf8)
        #expect(throws: SettingsFileError.notChatGauge("ClipGauge")) { try InstructionsFile.decode(other) }
        let newer = Data(#"{"app":"ChatGauge","schema":99,"presets":[]}"#.utf8)
        #expect(throws: SettingsFileError.newerSchema(99)) { try InstructionsFile.decode(newer) }
    }

    @Test func clipGaugeImport() {
        let j = Data(#"{"standing":"Name clips briefly.","glossary":["retroCombs","TeensyROM"],"next_run":{"text":"","keep":false}}"#.utf8)
        let f = ClipGaugeImport.read(j)
        #expect(f?.glossary == ["retroCombs", "TeensyROM"])
        #expect(f?.standing == "Name clips briefly.")
        #expect(ClipGaugeImport.read(Data(#"{"glossary":"a, b"}"#.utf8))?.glossary == ["a", "b"])
        #expect(ClipGaugeImport.read(Data(#"{"glossary":[]}"#.utf8)) == nil)
        #expect(ClipGaugeImport.read(Data("x".utf8)) == nil)
        #expect(ClipGaugeImport.merge(["MEGA65"], ["mega65", "C64"]) == ["MEGA65", "C64"])
    }
}
