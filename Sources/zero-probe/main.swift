import Foundation
import ZeroCore

// Manual verification tool: opens a real session against an installed provider CLI and dumps the
// normalized events. Never runs in CI and no test depends on it — its whole job is to catch the
// case where an adapter agrees with its own fixtures and both are wrong.
//
// Filled in per provider as each adapter lands (B4, B5, B6).

let usage = """
zero-probe — drive a real provider CLI and print normalized AgentEvents.

usage: zero-probe <provider> <prompt>

providers: (none wired yet — see Sources/ZeroCore/Providers)
"""

FileHandle.standardError.write(Data(usage.utf8))
exit(1)
