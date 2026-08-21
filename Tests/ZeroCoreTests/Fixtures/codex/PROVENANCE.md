# Codex Adapter Protocol Fixtures — Provenance

All fixtures are **derived** from authoritative Codex app-server documentation and were not captured from a live CLI.

## Primary Sources

1. **https://gist.github.com/oneryalcin/ee2c27e2d8aa040da8fbe7eebcc2ecea** — "Building on codex app-server: a developer's guide"
   - Confirms JSON-RPC 2.0 with omitted `"jsonrpc":"2.0"` member
   - Lists core methods: `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, `review/start`
   - Describes notification lifecycle: `turn/started`, `turn/completed`, `item/started`, `item/completed`
   - Documents delta notifications: `item/agentMessage/delta`, `item/reasoning/textDelta`, `item/reasoning/summaryTextDelta`
   - Describes approval flow: server sends `execCommandApproval` / `applyPatchApproval` with `id`, client responds with same `id` and `decision`
   - Mentions `optOutNotificationMethods` to suppress high-volume channels

2. **https://codex.danielvaughan.com/2026/04/15/codex-app-server-complete-guide/** — Complete guide
   - Describes item types: `userMessage`, `agentMessage`, `commandExecution`, `fileChange`, `mcpToolCall`, `webSearch`
   - Documents delta structure: `{ "method": "item/agentMessage/delta", "params": { "itemId", "deltaIndex", "text" } }`
   - Confirms command execution approvals with `itemId`, `threadId`, `turnId`
   - Describes responses with `decision` field: `"accept"`, `"acceptForSession"`, `"decline"`, `"cancel"`

3. **https://learn.chatgpt.com/docs/app-server** — Official Codex app-server documentation
   - Confirms item lifecycle: `item/started` → deltas → `item/completed`
   - Documents notification structure omits `id`, uses only `method` and `params`
   - Confirms MCP tool call structure with `server`, `tool`, `arguments`, `result`

4. **https://github.com/openai/codex/blob/main/codex-rs/docs/codex_mcp_interface.md** — MCP interface docs
   - States "this interface is experimental. Method names, fields, and event shapes may evolve."
   - References types living in `app-server-protocol/src/protocol/{common,v1,v2}.rs`

## Ambiguities and TODOs

The following are marked `TODO(B5):` in the implementation where the protocol was unclear or had multiple reasonable readings:

1. **Tool call execution model**: Whether a single tool call can span multiple items or is always one item with embedded call state
2. **Error notification structure**: Exact JSON shape of error notifications and error code mappings
3. **Plan/task list structure**: Whether plans come as notifications or only in turn completion
4. **Reasoning vs thinking**: Whether "reasoning" (preview of internal thoughts) maps to `thinkingDelta` or another AgentEvent kind
5. **File edit delta vs item/completed**: Whether file edits stream via deltas or appear only in item/completed with full old+new text
6. **Turn start id correlation**: Whether `turn/start` response includes a `turnId` for correlation or if `turn/started` notification provides it
7. **Token usage event timing**: Whether usage is only in `turn/completed` or also emitted separately via `thread/tokenUsage/updated`

## Fixture Coverage

- `sample-turn-lifecycle.ndjson` — Complete turn: initialization, turn started, agent message delta, reasoning delta, turn completed with usage
- `sample-tool-call.ndjson` — Tool call execution: request, approval, execution, result
- `sample-approval-round-trip.ndjson` — Permission request/response correlation with JSON-RPC id preservation
- `sample-errors.ndjson` — Invalid JSON, unknown method, unrecognized notification
- `sample-usage.ndjson` — Token usage in turn completed with cache read/write tokens

## Confidence Levels

- **High (90%+)**: JSON-RPC structure, notification vs request distinction, initialization handshake, turn lifecycle
- **Medium (70-89%)**: Exact field names in delta notifications, approval decision vocabulary, error notification format
- **Low (< 70%)**: Plan/task updates structure, exact tool call item structure, reasoning vs thinking mapping
