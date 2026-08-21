import Darwin
import Foundation
import ZeroCore

// Runs before every matched tool call, so its cost is paid on every one: read stdin, ask the app
// over the session socket, print the answer. Nothing else is loaded.
//
// Every failure path prints deny. This binary is the last thing standing between an agent and the
// user's filesystem, and an error here must never read as approval.

func emitDeny(_ reason: String) -> Never {
    FileHandle.standardOutput.write(HookResponse(decision: .deny, reason: "Zero: \(reason)").stdoutPayload())
    exit(0)
}

// 5s to reach the app; the app's own deliberation timeout is longer and lives in the broker.
let connectTimeout: TimeInterval = 5
// Generous: this is the human's thinking time, bounded by the broker's own timeout.
let answerTimeout: TimeInterval = 300

guard CommandLine.arguments.count >= 2 else { emitDeny("no socket path given") }
let socketPath = CommandLine.arguments[1]

guard let stdinData = try? FileHandle.standardInput.readToEnd(), !stdinData.isEmpty else {
    emitDeny("no hook payload on stdin")
}

// Claude Code sends its own field names; re-encode into our wire shape so the broker sees one
// format regardless of which provider or version produced it.
guard let hook = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
    emitDeny("hook payload was not JSON")
}
guard let toolName = hook["tool_name"] as? String else { emitDeny("hook payload had no tool_name") }

let toolInput: String = {
    guard let raw = hook["tool_input"],
          let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .prettyPrinted])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
}()

let sessionID = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
let request = HookRequest(
    toolName: toolName,
    toolInput: toolInput,
    requestID: UUID().uuidString,
    sessionID: sessionID,
    cwd: hook["cwd"] as? String ?? "",
    permissionMode: hook["permission_mode"] as? String ?? ""
)

guard let payload = try? JSONEncoder().encode(request) else { emitDeny("could not encode request") }
guard let fd = SocketIO.connect(path: socketPath, timeout: connectTimeout) else {
    emitDeny("app unreachable")
}
defer { Darwin.close(fd) }

guard SocketIO.writeFrame(fd, payload) else { emitDeny("could not send request") }
SocketIO.setTimeouts(fd, answerTimeout)

guard let responsePayload = SocketIO.readFrame(fd) else { emitDeny("no answer from app") }
guard let response = try? JSONDecoder().decode(HookResponse.self, from: responsePayload) else {
    emitDeny("unreadable answer from app")
}

FileHandle.standardOutput.write(response.stdoutPayload())
exit(0)
