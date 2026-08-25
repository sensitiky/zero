import Foundation
import ZeroCore

/// ZeroCore values → the wire contract.
///
/// Pure and static on purpose: this is the whole of what the bridge *knows*, and it holds no state
/// of its own (FR-5). Every read endpoint and every event frame is a function of a value the window
/// already has, so the phone and the window cannot disagree about what a session is doing.
public enum Projection {

    // MARK: - Status (FR-11)

    /// The five `SessionState` cases onto the five wire names, which are not the same five.
    ///
    /// **No `default:`.** If a sixth `SessionState` case is ever added, this must stop compiling —
    /// a mapping that silently reports a new state as `waiting` is worse than one that fails the
    /// build, because the phone would show a session as needing an instruction when it does not.
    ///
    /// `.idle` and `.waitingPermission` share `waiting` deliberately: a client tells them apart by
    /// `pendingPermission`, not by a second status, because it needs that payload anyway.
    /// `cancelled` is never produced — cancelling a turn in Zero leaves the session alive.
    public static func status(of state: SessionState) -> SessionStatus {
        switch state {
        case .running: .running
        case .waitingPermission: .waiting
        case .idle: .waiting
        case .finished: .completed
        case .error: .failed
        }
    }

    /// The failure text, for the one state that has one.
    public static func error(of state: SessionState) -> String? {
        switch state {
        case .error(let message): message
        case .idle, .running, .waitingPermission, .finished: nil
        }
    }

    public static func workspace(_ workspace: SessionRuntime.Workspace) -> WorkspaceDTO {
        switch workspace {
        case .currentCheckout: .currentCheckout
        case .isolatedWorktree: .isolatedWorktree
        }
    }

    public static func permissionMode(_ mode: PermissionMode) -> PermissionModeDTO {
        switch mode {
        case .ask: .ask
        case .auto: .auto
        case .bypass: .bypass
        }
    }

    public static func permissionMode(_ mode: PermissionModeDTO) -> PermissionMode {
        switch mode {
        case .ask: .ask
        case .auto: .auto
        case .bypass: .bypass
        }
    }

    // MARK: - Transcript (FR-12, FR-13)

    public static func entry(_ entry: Transcript.Entry) -> EntryDTO {
        switch entry {
        case .userText(let id, let text):
            EntryDTO(id: id.uuidString, kind: .userText, text: text)
        case .assistantText(let id, let text):
            EntryDTO(id: id.uuidString, kind: .assistantText, text: text)
        case .thinking(let id, let text):
            EntryDTO(id: id.uuidString, kind: .thinking, text: text)
        case .notice(let id, let text):
            EntryDTO(id: id.uuidString, kind: .notice, text: text)
        case .plan(let id, let items):
            EntryDTO(id: id.uuidString, kind: .plan, items: items.map(planItem))
        case .tool(let id, let call):
            EntryDTO(id: id.uuidString, kind: .tool, call: toolCall(call))
        }
    }

    public static func planItem(_ item: PlanItem) -> PlanItemDTO {
        PlanItemDTO(id: item.id, title: item.title, status: planItemStatus(item.status))
    }

    public static func planItemStatus(_ status: PlanItem.Status) -> PlanItemStatus {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        }
    }

    /// The whole call — `input` and `output` untruncated. The client decides how much to show; the
    /// bridge does not decide for it.
    public static func toolCall(_ call: ToolCall) -> ToolCallDTO {
        ToolCallDTO(
            id: call.id,
            name: call.name,
            status: toolStatus(call.status),
            statusDetail: toolStatusDetail(call.status),
            input: call.input,
            output: call.output,
            edit: call.edit.map(fileEdit),
            startedAt: call.startedAt,
            endedAt: call.endedAt
        )
    }

    public static func toolStatus(_ status: ToolCall.Status) -> ToolStatus {
        switch status {
        case .pending: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .denied: .denied
        }
    }

    /// The `failed(String)` payload, flattened out of the status so the status stays a closed set.
    public static func toolStatusDetail(_ status: ToolCall.Status) -> String? {
        switch status {
        case .failed(let message): message
        case .pending, .running, .succeeded, .denied: nil
        }
    }

    public static func fileEdit(_ edit: FileEdit) -> FileEditDTO {
        FileEditDTO(path: edit.path, oldText: edit.oldText, newText: edit.newText)
    }

    // MARK: - Permissions and usage

    public static func permissionRequest(_ request: PermissionRequest) -> PermissionRequestDTO {
        PermissionRequestDTO(
            id: request.id,
            toolName: request.toolName,
            detail: request.detail,
            options: request.options.map(permissionOption)
        )
    }

    public static func permissionOption(_ option: PermissionOption) -> PermissionOptionDTO {
        PermissionOptionDTO(
            id: option.id,
            kind: permissionOptionKind(option.kind),
            label: option.label
        )
    }

    public static func permissionOptionKind(_ kind: PermissionOption.Kind) -> PermissionOptionKind {
        switch kind {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .denyOnce: .denyOnce
        case .denyAlways: .denyAlways
        }
    }

    public static func usage(_ usage: Usage) -> UsageDTO {
        UsageDTO(
            model: usage.model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            thinkingTokens: usage.thinkingTokens,
            contextWindowUsed: usage.contextWindowUsed,
            contextWindowTotal: usage.contextWindowTotal,
            costUSD: usage.costUSD
        )
    }
}
