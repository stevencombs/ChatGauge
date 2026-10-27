import Carbon.HIToolbox
import Foundation
import Testing
@testable import ChatGaugeCore

/// ⌃⌥C did nothing in build 7: ⌃ was stored as Carbon's right-Shift bit.
@Suite struct HotKeyBitsTests {
    @Test func modifierBitsMatchCarbon() {
        #expect(HotKey.cmdKey == UInt32(cmdKey))
        #expect(HotKey.shiftKey == UInt32(shiftKey))
        #expect(HotKey.optionKey == UInt32(optionKey))
        #expect(HotKey.controlKey == UInt32(controlKey))
        #expect(HotKey.legacyControlKey == UInt32(rightShiftKey))
    }

    @Test func standardIsControlOptionC() {
        #expect(HotKey.standard.keyCode == UInt32(kVK_ANSI_C))
        #expect(HotKey.standard.carbonModifiers == UInt32(controlKey | optionKey))
        #expect(HotKey.standard.carbonModifiers == 6144)
        #expect(HotKey.standard.display == "⌃⌥C")
    }

    @Test func build7SettingsMigrate() throws {
        // The exact hotKey that build 7 saved (optionKey | rightShiftKey = 10240).
        let json = #"{"app":"ChatGauge","schema":1,"settings":{"hotKey":{"enabled":true,"keyCode":8,"carbonModifiers":10240}}}"#
        let env = try JSONDecoder().decode(SettingsEnvelope.self, from: Data(json.utf8))
        #expect(env.settings.hotKey.carbonModifiers == 6144)
        #expect(env.settings.hotKey == .standard)
    }

    @Test func migrationKeepsOtherKeys() throws {
        #expect(HotKey.migrated(UInt32(cmdKey | shiftKey)) == UInt32(cmdKey | shiftKey))
        #expect(HotKey.migrated(UInt32(controlKey | optionKey)) == UInt32(controlKey | optionKey))
        #expect(HotKey.migrated(HotKey.legacyControlKey | UInt32(cmdKey)) == UInt32(controlKey | cmdKey))
        // Saved again after loading: the new bits round-trip unchanged.
        let k = HotKey(keyCode: 8, carbonModifiers: UInt32(controlKey | cmdKey))
        let back = try JSONDecoder().decode(HotKey.self, from: JSONEncoder().encode(k))
        #expect(back == k)
        let noEnabled = try JSONDecoder().decode(HotKey.self, from: Data(#"{"keyCode":8,"carbonModifiers":6144}"#.utf8))
        #expect(noEnabled.enabled)
    }

    @Test func validity() {
        #expect(HotKey(keyCode: 8, carbonModifiers: UInt32(controlKey)).isValid)
        #expect(!HotKey(keyCode: 8, carbonModifiers: UInt32(shiftKey)).isValid)
        #expect(!HotKey(keyCode: 8, carbonModifiers: 0).isValid)
    }
}

/// Prompts "spun" in build 7: the "Thinking…" row outlived the reply.
@Suite struct PendingReplyTests {
    private func convo(reply: String, error: String? = nil) -> (Conversation, UUID) {
        var c = Conversation()
        c.messages.append(ChatMessage(role: .user, text: "Are you working"))
        var r = ChatMessage(role: .assistant, text: reply)
        r.error = error
        c.messages.append(r)
        return (c, r.id)
    }

    @Test func pendingOnlyWhileStreamingWithNoText() {
        let (c, id) = convo(reply: "")
        #expect(c.pendingReplyID(streaming: true) == id)
        #expect(c.pendingReplyID(streaming: false) == nil)
    }

    @Test func firstWordsEndPending() {
        let (c, _) = convo(reply: "Yes")
        #expect(c.pendingReplyID(streaming: true) == nil)
    }

    @Test func errorEndsPending() {
        let (c, _) = convo(reply: "", error: "Ollama stopped.")
        #expect(c.pendingReplyID(streaming: true) == nil)
    }

    @Test func onlyTheLastMessage() {
        var (c, _) = convo(reply: "")
        c.messages.append(ChatMessage(role: .user, text: "again"))
        #expect(c.pendingReplyID(streaming: true) == nil)
        #expect(Conversation().pendingReplyID(streaming: true) == nil)
    }
}
