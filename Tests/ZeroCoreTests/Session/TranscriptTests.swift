import Foundation
import Testing

@testable import ZeroCore

@Suite("Transcript")
struct TranscriptTests {
    private func assistantTexts(_ transcript: Transcript) -> [String] {
        transcript.entries.compactMap {
            if case .assistantText(_, let text) = $0 { return text }
            return nil
        }
    }

    private func userTexts(_ transcript: Transcript) -> [String] {
        transcript.entries.compactMap {
            if case .userText(_, let text) = $0 { return text }
            return nil
        }
    }

    // MARK: - The bug this file exists for

    @Test("two turns produce two replies, not one that swallowed the first")
    func turnsDoNotMerge() {
        // The regression: assembly used to extend "the last assistant entry", which across a turn
        // boundary is the previous reply. Turn two was appended to turn one and the history read as
        // if the agent had overwritten itself.
        var transcript = Transcript()
        transcript.apply(.textDelta("first answer"))
        transcript.apply(.turnEnded(.endTurn))
        transcript.apply(.textDelta("second answer"))

        #expect(assistantTexts(transcript) == ["first answer", "second answer"])
    }

    @Test("a message from the user closes the assistant's message")
    func userMessageClosesTheReply() {
        var transcript = Transcript()
        transcript.apply(.textDelta("answer one"))
        transcript.appendUserMessage("and now this")
        transcript.apply(.textDelta("answer two"))

        #expect(userTexts(transcript) == ["and now this"])
        #expect(assistantTexts(transcript) == ["answer one", "answer two"])
    }

    @Test("what the user sent is in the transcript")
    func userMessagesAreRecorded() {
        // They used to be shown nowhere: the send path wrote to the process and not to the
        // conversation, so a message vanished the moment you sent it.
        var transcript = Transcript()
        transcript.appendUserMessage("do the thing")
        #expect(userTexts(transcript) == ["do the thing"])
    }

    @Test("streamed deltas inside one turn are one message")
    func deltasWithinATurnMerge() {
        var transcript = Transcript()
        transcript.apply(.textDelta("Hello"))
        transcript.apply(.textDelta(", "))
        transcript.apply(.textDelta("world"))

        #expect(assistantTexts(transcript) == ["Hello, world"])
    }

    @Test("text on either side of a tool call is two messages")
    func toolCallSplitsTheReply() {
        // Text before and after a tool call are separate paragraphs, not one sentence interrupted.
        var transcript = Transcript()
        transcript.apply(.textDelta("Let me look."))
        transcript.apply(.toolCall(ToolCall(id: "t1", name: "Read", status: .running)))
        transcript.apply(.textDelta("Found it."))

        #expect(assistantTexts(transcript) == ["Let me look.", "Found it."])
    }

    @Test("thinking does not get glued to the reply that follows it")
    func thinkingSplitsTheReply() {
        var transcript = Transcript()
        transcript.apply(.textDelta("Part one."))
        transcript.apply(.thinkingDelta("considering"))
        transcript.apply(.textDelta("Part two."))

        #expect(assistantTexts(transcript) == ["Part one.", "Part two."])
    }

    // MARK: - Tool calls

    @Test("a tool call and its result stay one row")
    func toolCallUpdatesInPlace() {
        var transcript = Transcript()
        transcript.apply(.toolCall(ToolCall(id: "t1", name: "Bash", status: .running)))
        transcript.apply(.toolCall(ToolCall(id: "t1", name: "Bash", output: "done", status: .succeeded)))

        let calls = transcript.entries.compactMap { entry -> ToolCall? in
            if case .tool(_, let call) = entry { return call }
            return nil
        }
        #expect(calls.count == 1)
        #expect(calls.first?.status == .succeeded)
        #expect(calls.first?.output == "done")
    }

    // MARK: - Summary and usage

    @Test("the summary follows the latest reply")
    func summaryFollowsLatestReply() {
        var transcript = Transcript()
        transcript.apply(.textDelta("old news"))
        transcript.apply(.turnEnded(.endTurn))
        transcript.apply(.textDelta("what it is doing now"))

        #expect(transcript.summary == "what it is doing now")
    }

    @Test("the summary is one bounded line")
    func summaryIsOneLine() {
        var transcript = Transcript()
        transcript.apply(.textDelta("line one\nline two\n" + String(repeating: "x", count: 200)))

        #expect(!transcript.summary.contains("\n"))
        #expect(transcript.summary.count <= 91)
    }

    @Test("usage merges field by field and a reported cost wins")
    func usageMerges() {
        var transcript = Transcript()
        transcript.apply(.usage(Usage(model: "m", inputTokens: 10)))
        transcript.apply(.usage(Usage(outputTokens: 20, costUSD: 0.5)))

        #expect(transcript.usage.model == "m")
        #expect(transcript.usage.inputTokens == 10)
        #expect(transcript.usage.outputTokens == 20)
        #expect(transcript.usage.costUSD == 0.5)
    }

    @Test("a thinking-token estimate is not a message and not usage")
    func thinkingProgressIsNeither() {
        var transcript = Transcript()
        transcript.apply(.thinkingProgress(estimatedTokens: 42))

        #expect(transcript.entries.isEmpty)
        #expect(transcript.usage.thinkingTokens == nil)
    }

    // MARK: - State

    @Test("events drive the states the sidebar shows")
    func eventsDriveState() {
        var transcript = Transcript()
        #expect(transcript.apply(.turnStarted(id: "1")) == .running)
        #expect(transcript.apply(.textDelta("x")) == nil)
        #expect(
            transcript.apply(
                .permissionRequested(
                    PermissionRequest(id: "p", toolName: "Bash", detail: "rm -rf", options: [])
                )
            ) == .waitingPermission
        )
        #expect(transcript.apply(.turnEnded(.endTurn)) == .idle)
        #expect(transcript.apply(.failed(reason: "boom")) == .error("boom"))
    }

    @Test("a permission request is held until it is resolved")
    func permissionIsHeldUntilResolved() {
        var transcript = Transcript()
        transcript.apply(
            .permissionRequested(
                PermissionRequest(id: "p", toolName: "Write", detail: "/tmp/x", options: [])
            )
        )
        #expect(transcript.pendingPermission?.id == "p")
        transcript.resolvePermission()
        #expect(transcript.pendingPermission == nil)
    }
}
