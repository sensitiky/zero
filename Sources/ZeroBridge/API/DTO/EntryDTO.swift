import Foundation

/// A file edit carried by a tool call, so a client can render a diff rather than raw text.
public struct FileEditDTO: Codable, Sendable, Equatable {
    public var path: String
    public var oldText: String?
    public var newText: String?

    public init(path: String, oldText: String? = nil, newText: String? = nil) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }

    enum CodingKeys: String, CodingKey { case path, oldText, newText }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeExplicit(oldText, forKey: .oldText)
        try container.encodeExplicit(newText, forKey: .newText)
    }
}

/// One tool call, whole (FR-13).
///
/// `input`/`output` are sent complete: the client decides how much to show, and the server does not
/// decide for it by truncating. A truncated tool output is how a user approves or believes something
/// they did not read.
public struct ToolCallDTO: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: ToolStatus
    /// The `failed(String)` payload, or nil. Flattened out of the status so the status stays a
    /// closed set of five strings.
    public var statusDetail: String?
    public var input: String?
    public var output: String?
    public var edit: FileEditDTO?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        id: String,
        name: String,
        status: ToolStatus,
        statusDetail: String? = nil,
        input: String? = nil,
        output: String? = nil,
        edit: FileEditDTO? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.statusDetail = statusDetail
        self.input = input
        self.output = output
        self.edit = edit
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, statusDetail, input, output, edit, startedAt, endedAt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encodeExplicit(statusDetail, forKey: .statusDetail)
        try container.encodeExplicit(input, forKey: .input)
        try container.encodeExplicit(output, forKey: .output)
        try container.encodeExplicit(edit, forKey: .edit)
        try container.encodeExplicit(startedAt, forKey: .startedAt)
        try container.encodeExplicit(endedAt, forKey: .endedAt)
    }
}

/// One item of a plan.
public struct PlanItemDTO: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: PlanItemStatus

    public init(id: String, title: String, status: PlanItemStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// One `Transcript.Entry`, typed on the wire (FR-12).
///
/// One object per case rather than a flattened string: a tool call, a diff and a plan are different
/// things to look at, and `id` is the entry's own UUID so a client upserts by it instead of
/// re-fetching the transcript. Only the field the kind uses is written — a `userText` entry carrying
/// `"call": null` would invite a client to look for one.
public struct EntryDTO: Codable, Sendable, Equatable {
    public var id: String
    public var kind: EntryKind
    public var text: String?
    public var items: [PlanItemDTO]?
    public var call: ToolCallDTO?

    public init(
        id: String,
        kind: EntryKind,
        text: String? = nil,
        items: [PlanItemDTO]? = nil,
        call: ToolCallDTO? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.items = items
        self.call = call
    }

    enum CodingKeys: String, CodingKey { case id, kind, text, items, call }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(call, forKey: .call)
    }
}
