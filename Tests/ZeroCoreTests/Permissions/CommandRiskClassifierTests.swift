import Foundation
import Testing

@testable import ZeroCore

@Suite("CommandRiskClassifier")
struct CommandRiskClassifierTests {
    private func bash(_ command: String) -> String {
        #"{"command":"\#(command)"}"#
    }

    private func write(_ path: String) -> String {
        #"{"file_path":"\#(path)","content":"x"}"#
    }

    // MARK: - The two cases named explicitly by the product owner

    @Test("WebFetch always asks, regardless of the URL")
    func webFetchAlwaysAsks() {
        let risk = CommandRiskClassifier.classify(
            toolName: "WebFetch", toolInputJSON: #"{"url":"https://example.com"}"#
        )
        #expect(risk != .routine)
    }

    @Test("dropping a database asks")
    func dropDatabaseAsks() {
        let risk = CommandRiskClassifier.classify(
            toolName: "Bash", toolInputJSON: bash("psql -c 'DROP DATABASE prod;'")
        )
        #expect(risk != .routine)
    }

    // MARK: - Destructive shell patterns

    @Test("recursive force delete asks", arguments: ["rm -rf /tmp/x", "rm -fr build"])
    func recursiveDeleteAsks(_ command: String) {
        #expect(CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: bash(command)) != .routine)
    }

    @Test("a network fetch from the shell asks the same as the WebFetch tool would")
    func curlAsks() {
        // Named explicitly: "hacer fetch de sitios web" should ask, whether it goes through the
        // WebFetch tool or a shell command that does the same thing.
        let risk = CommandRiskClassifier.classify(
            toolName: "Bash", toolInputJSON: bash("curl -s https://example.com/data")
        )
        #expect(risk != .routine)
    }

    @Test("force-pushing asks")
    func forcePushAsks() {
        #expect(
            CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: bash("git push --force origin main"))
                != .routine
        )
    }

    @Test("sudo asks")
    func sudoAsks() {
        #expect(
            CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: bash("sudo rm file.txt")) != .routine
        )
    }

    @Test("reading an SSH key asks even though nothing is being deleted")
    func touchingSecretsAsks() {
        #expect(
            CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: bash("cat ~/.ssh/id_rsa"))
                != .routine
        )
    }

    // MARK: - The routine majority this change exists for

    @Test("ordinary commands are routine", arguments: [
        "git status", "npm test", "swift build", "ls -la", "git diff", "cat README.md",
        "grep -r TODO Sources", "swift test --filter FooTests",
    ])
    func ordinaryCommandsAreRoutine(_ command: String) {
        #expect(CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: bash(command)) == .routine)
    }

    @Test("editing an ordinary source file is routine")
    func ordinaryEditIsRoutine() {
        #expect(
            CommandRiskClassifier.classify(toolName: "Edit", toolInputJSON: write("Sources/App/Handler.swift"))
                == .routine
        )
    }

    @Test("writing to a .env file asks")
    func envFileAsks() {
        #expect(CommandRiskClassifier.classify(toolName: "Write", toolInputJSON: write(".env")) != .routine)
    }

    @Test("writing to an AWS credentials path asks")
    func awsCredentialsPathAsks() {
        #expect(
            CommandRiskClassifier.classify(
                toolName: "Write", toolInputJSON: write("/Users/x/.aws/credentials")
            ) != .routine
        )
    }

    // MARK: - Fail closed on anything unrecognized

    @Test("malformed JSON asks rather than crashing or defaulting to allow")
    func malformedJSONAsks() {
        #expect(CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: "not json") != .routine)
    }

    @Test("a command field that is missing asks")
    func missingCommandFieldAsks() {
        #expect(CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: "{}") != .routine)
    }

    @Test("an unrecognized tool name asks — an allowlist gets unknown tools wrong silently")
    func unrecognizedToolAsks() {
        #expect(CommandRiskClassifier.classify(toolName: "SomeNewTool", toolInputJSON: "{}") != .routine)
    }

    @Test("classification is case-insensitive")
    func classificationIsCaseInsensitive() {
        #expect(
            CommandRiskClassifier.classify(toolName: "Bash", toolInputJSON: bash("SUDO rm -rf /tmp/x"))
                != .routine
        )
    }
}
