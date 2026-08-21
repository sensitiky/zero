# Claude Code fixtures

All three fixtures are **captured**: real stdout from `claude` 2.1.237 on macOS 26.5.2,
2026-08-21. `system/hook_started` and `system/hook_response` records were stripped because they
carry this machine's local hook text; every other record is shape-faithful to the wire.

| Fixture | Command | Contains |
|---|---|---|
| `text-turn.ndjson` | `claude --print --output-format stream-json --verbose --model claude-haiku-4-5-20251001 'Reply with exactly: hi'` | `system/init`, `system/thinking_tokens`, `assistant` (thinking + text), `rate_limit_event`, `system/post_turn_summary`, `result/success` |
| `tool-use-turn.ndjson` | same flags plus `--input-format stream-json --permission-mode manual`, prompt asking for a Bash call | adds `assistant` with a `tool_use` block, `user` with a `tool_result` block, `system/task_summary` |
| `permission-denied-turn.ndjson` | same, prompt asking for a `Write` outside any allow rule, scrubbed environment | adds `system/permission_denied`; the file was **not** created |

## What these captures disprove

The PRD and PLAN specified `--permission-prompt-tool stdio` and a `control_request` /
`can_use_tool` handshake. Verified against the real CLI:

1. **`--permission-prompt-tool` does not exist** in 2.1.237. `claude --help` has no such flag.
2. **No `control_request` or `can_use_tool` record appears on the wire** in any capture, including
   with `--input-format stream-json` and `--permission-mode manual`.
3. A tool call outside the allow rules produces `system/permission_denied` and is **denied**, not
   escalated to the host process. Headless mode denies; it does not ask.
4. The official headless documentation attributes "tool approval callbacks" to the Python and
   TypeScript SDK packages, not to the CLI.

So FR-23 — permission UI inside the chat — has no transport for Claude Code as designed. This is
tracked as an open architecture decision, not a bug in the adapter.

## Two further findings

- `result/success` carries **`total_cost_usd`** directly, plus a full `usage` breakdown including
  `cache_creation_input_tokens`, `cache_read_input_tokens` and `output_tokens_details.thinking_tokens`.
  For Claude Code the pricing table of FR-30 is redundant: the CLI reports actual cost.
- These captures contain whole-message `assistant` records, not token deltas. True incremental
  streaming (FR-18) requires `--include-partial-messages`, which adds `stream_event` records.
