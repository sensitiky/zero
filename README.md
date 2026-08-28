<p align="center">
  <img src="Design/logo.png" width="120" alt="Zero logo — a glyph built from two crescents forming a zero">
</p>

<h1 align="center">Zero</h1>
<p align="center">A native macOS harness for AI coding agents.</p>

<p align="center">
  <a href="https://github.com/sensitiky/zero/actions/workflows/ci.yml"><img src="https://github.com/sensitiky/zero/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-informational" alt="macOS 15+">
  <img src="https://img.shields.io/badge/swift-6.3-orange" alt="Swift 6.3">
</p>

Agent CLIs — Claude Code, Codex, anything speaking [ACP](https://agentclientprotocol.com) — talk
in raw NDJSON. Zero is the app around them: one designed shell, real sidebar, diffs, transcript
and permission prompts, so working with an agent looks like using an app instead of piping through
`cat`. That's the whole premise — see [`docs/DESIGN.md`](docs/DESIGN.md) for the rule it's built on.

## Requirements

- macOS 15.0+
- Swift 6.3.3 (see `.swift-version`) — install via [swiftly](https://www.swift.org/install) or Xcode

## Building

There is no Xcode project on purpose — SPM picks up sources by directory, so a `.pbxproj` merge
conflict is a cost with no benefit here.

```bash
swift build            # build the package
swift test              # run the test suite
Scripts/make-app.sh     # assemble build/Zero.app around the SPM-built binary
```

Pass `release` to `make-app.sh` for a release build.

## Project structure

```
Sources/
  ZeroCore/     domain, persistence, git, providers, transport — no UI
  ZeroBridge/   server/API layer bridging ZeroCore to the app
  Zero/         the SwiftUI app (sidebar, transcript, permissions, previews, ...)
Tests/          ZeroCoreTests, ZeroBridgeTests
Scripts/        build, packaging, notarization, and design-token lint
docs/           architecture docs, PRDs, bug reports, requirements
Design/         design tokens and assets
```

## Providers

Agent CLIs are integrated under `Sources/ZeroCore/Providers/`: Claude Code, Codex, and generic
[ACP](https://agentclientprotocol.com) agents, registered through `ProviderRegistry`.

## Contributing

Branch flow is `feat/{slug}` or `fix/{slug}` → `develop` → `main`, always via PR. CI
(`.github/workflows/ci.yml`) runs the design-token lint, build, and tests on every PR and on pushes
to `main`/`develop`.
