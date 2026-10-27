import Foundation
import Testing
@testable import ChatGaugeCore

@Suite struct VoiceTests {
    @Test func modelNames() {
        #expect(WhisperModelPicker.modelName(fromFile: "ggml-base.en.bin") == "base.en")
        #expect(WhisperModelPicker.modelName(fromFile: "ggml-large-v3-turbo.bin") == "large-v3-turbo")
        #expect(WhisperModelPicker.modelName(fromFile: "ggml-silero-v5.1.2.bin") == nil)
        #expect(WhisperModelPicker.modelName(fromFile: "ggml-base.en-encoder.mlmodelc") == nil)
        #expect(WhisperModelPicker.modelName(fromFile: "notes.txt") == nil)
    }

    @Test func pickByTier() {
        let all = ["base.en", "large-v3-turbo", "small.en"]
        #expect(WhisperModelPicker.pick(installed: all, tier: .pro) == "large-v3-turbo")
        #expect(WhisperModelPicker.pick(installed: all, tier: .air) == "base.en")
        #expect(WhisperModelPicker.pick(installed: all, tier: .air, override: "small.en") == "small.en")
        #expect(WhisperModelPicker.pick(installed: all, tier: .air, override: "missing") == "base.en")
        #expect(WhisperModelPicker.pick(installed: ["medium", "tiny"], tier: .air) == "tiny")
        #expect(WhisperModelPicker.pick(installed: ["medium", "tiny"], tier: .pro) == "medium")
        #expect(WhisperModelPicker.pick(installed: [], tier: .pro) == nil)
        #expect(WhisperModelPicker.suggested(tier: .air) == "base.en")
    }

    @Test func pickFromFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cg-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["ggml-small.en.bin", "ggml-silero-v5.bin", "readme.md"] {
            try Data().write(to: dir.appendingPathComponent(f))
        }
        #expect(WhisperModelPicker.installed(in: dir) == ["small.en"])
    }

    @Test func commandLines() {
        let f = VoiceCommands.ffmpegArgs(input: "/tmp/a.caf", output: "/tmp/a.wav")
        #expect(f.contains("16000"))
        #expect(f.suffix(1) == ["/tmp/a.wav"])
        let w = VoiceCommands.whisperArgs(model: "/m/ggml-base.en.bin", modelName: "base.en", wav: "/tmp/a.wav", prompt: "retroCombs, MEGA65", threads: 12)
        #expect(w.contains("--prompt"))
        #expect(w[w.firstIndex(of: "-l")! + 1] == "en")
        #expect(w[w.firstIndex(of: "-t")! + 1] == "8")
        let w2 = VoiceCommands.whisperArgs(model: "m", modelName: "large-v3-turbo", wav: "a", prompt: "  ", threads: 4)
        #expect(!w2.contains("--prompt"))
        #expect(w2[w2.firstIndex(of: "-l")! + 1] == "auto")
    }

    @Test func transcriptCleanup() {
        let out = "\n [BLANK_AUDIO]\n  Hello from   retroCombs.\n(music)\n[00:00:01.000 --> 00:00:02.000]  Second line\n"
        #expect(VoiceCommands.cleanTranscript(out) == "Hello from retroCombs. Second line")
        #expect(VoiceCommands.cleanTranscript("[BLANK_AUDIO]") == "")
    }

    @Test func insertNeverSendsJustAppends() {
        #expect(VoiceCommands.insert("hi there", into: "") == "hi there")
        #expect(VoiceCommands.insert("more", into: "Draft") == "Draft more")
        #expect(VoiceCommands.insert("more", into: "Draft\n") == "Draft\nmore")
        #expect(VoiceCommands.insert("  ", into: "Draft") == "Draft")
    }
}
