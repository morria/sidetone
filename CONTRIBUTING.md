# Contributing to Sidetone

## Setup

1. Install Xcode 26 and Swift 6.3+.
2. Clone the repo.
3. `swift test` — runs the whole suite in ~1.2 seconds.
4. `swift run SidetoneMac` — launches the Mac app.

Running ardopcf isn't required for the test suite — a mock TNC server
stands in. You'll want it for interactive testing of the Mac app.

## Code layout

- `Packages/SidetoneCore/` — pure Swift, no UI deps, no AppKit/UIKit.
  Every model, protocol, and driver lives here.
- `Packages/SidetoneUI/` — SwiftUI views, shared across platforms.
  Only `#if os(...)` when the feature genuinely differs (composer
  keyboard behavior, iOS-only capitalization modifiers).
- `Packages/SidetoneServer/` — swift-nio HTTP+WS server. Mac/Pi only.
- `Packages/SidetoneTestSupport/` — mock TNC, mock rigctld, shared
  `IntegrationTests` parent suite.
- `Apps/Sidetone-Mac/` — SPM executable target for the Mac app
  (temporary — proper Xcode project is M8).

## Testing

- Unit tests for value types and parsers go in
  `Packages/SidetoneCore/Tests/SidetoneCoreTests/`.
- Anything that opens a real TCP socket (TNCClient, SidetoneServer,
  Bonjour browser) **must** nest inside the shared `IntegrationTests`
  enum from `SidetoneTestSupport`:

  ```swift
  extension IntegrationTests {
      @Suite("Your Feature")
      struct YourFeatureTests { ... }
  }
  ```

  Sibling `.serialized` suites in different files still run in parallel
  with each other, which reliably deadlocks Network.framework's
  dispatch queues under load. Nesting under the single serialized
  parent fixes it.

- Prefer a real mock TCP server (`MockTNCServer`, `MockRigctldServer`)
  over protocol-level fakes. The point is to exercise split-read
  buffering, which is where naive implementations break.

## Protocol changes

- Before adding a command or event to `TNCCommands`/`TNCEvents`, check
  ardopcf's [`HostInterfaceCommands.md`](https://github.com/pflarue/ardop/blob/master/docs/Host_Interface_Commands.md)
  and the relevant C source. The docs admit they're incomplete; source
  is the source of truth.
- Deviations from the SPEC (anywhere our implementation differs) go in
  `docs/protocol-notes.md`. That's where we admit we coded against
  reality rather than the spec document.
- When the wire contract (`docs/server-api.md`) changes, bump the API
  version path (`/api/v1` → `/api/v2`) before shipping to any external
  client. Unknown-kind tolerance in `EventEnvelope` means old clients
  survive additive changes, but rename/remove require a new version.

## PR style

- One reason per commit. Big commits with eight unrelated changes are
  much harder to revert.
- Use conventional prefixes: `feat(M5): ...`, `fix(...)`, `chore(...)`.
- Include a `Co-Authored-By: Claude Opus ...` trailer if AI-assisted.
- Add tests in the same PR as the code they cover.

## Strict concurrency

The whole tree is Swift 6 strict concurrency. If a test warns about
`@unchecked Sendable` or a `withLock` result being discarded, fix it
rather than silencing.

`NSLock` traps in async contexts — use `OSAllocatedUnfairLock` or make
the container an `actor`.
