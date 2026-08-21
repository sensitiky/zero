# ACP Fixture Provenance

All fixtures are **derived** from the Agent Client Protocol v1 specification, not captured from live agents.

## Sources

- **initialize.ndjson**
  - Derived from: https://agentclientprotocol.com/protocol/v1/schema
  - Section: InitializeRequest example
  - Example of a client initialize request to establish connection with an ACP agent

- **session-updates.ndjson**
  - Derived from: https://agentclientprotocol.com/protocol/v1/prompt-turn
  - Sections: "Agent Reports Output", "Tool Invocation and Status Reporting"
  - Multiple session/update notifications showing:
    - agent_message_chunk (text delta)
    - tool_call creation
    - tool_call_update with progress
    - tool_call_update with file diff
    - plan reporting
    - usage_update
    - current_mode_update (unsupported by AgentEvent)

- **permission-request.ndjson**
  - Derived from: https://agentclientprotocol.com/protocol/v1/tool-calls
  - Section: "Requesting Permission"
  - Example of a session/request_permission notification from agent requesting user approval

- **turn-completion.ndjson**
  - Derived from: https://agentclientprotocol.com/protocol/v1/prompt-turn
  - Section: "Stop Reasons"
  - Examples of session/prompt responses with different stop reasons:
    - end_turn: normal completion
    - max_tokens: hit token limit
    - cancelled: user cancelled
    - refusal: agent refused to proceed
