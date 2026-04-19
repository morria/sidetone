# Sidetone — Build Spec for Claude Code

## Goal

Build a polished, native Apple-ecosystem application — **macOS, iPadOS, and iOS** — that provides a VarAC-style ARDOP chat experience on top of a running `ardopcf` modem. The app is the GUI; `ardopcf` is the radio-facing daemon. The app never touches audio or the radio directly — it speaks to `ardopcf` over TCP and, where possible, to `rigctld` for CAT control.

The name of the app is **Sidetone**. In CW, the sidetone is the local audio feedback the operator hears while keying — the local confirmation of what’s going out over the air. That’s exactly what this app is: the operator’s local interface to a conversation happening on HF.

Target: a real app I’d want to use with my FT-891 and loop antenna in Fort Greene, Brooklyn, on my Mac at home and my iPhone/iPad in the field. Not a demo.

## Platform roles

The three platforms are not equal peers. Each has a role.

- **macOS (primary, full-featured)**. The complete station experience. Runs alongside a local `ardopcf`, local `rigctld`, local audio interface to the radio. This is the desk setup.
- **iPadOS (co-primary)**. Same UI as macOS, same feature set where platform allows. Connects to a remote `ardopcf` over the local network — typically a Mac mini, Raspberry Pi, or Mac running Sidetone-macOS in “server mode.” Useful as the operating position on the couch, or as a portable station controller at a POTA site running off a Pi.
- **iOS (companion)**. Reduced scope: remote control of a Mac or Pi running `ardopcf`. No local audio, no local rig control, no local modem. Optimized for quick check-ins, monitoring an active net, reading the transcript of an ongoing session, and sending short messages. Think “carry the station in your pocket” not “run a station from your pocket.” Philosophy crib from [RadioMail](https://radiomail.app): the phone is a client, the radio is somewhere else.

The iPad plays both roles depending on context — full station when paired with a Magic Keyboard and a Pi, companion when used as a glance-and-chat device.

## Non-goals

- Reimplementing ARDOP or any DSP.
- Windows, Linux, or Android support (Pat already owns those niches).
- Winlink CMS integration — Pat does Winlink well; Sidetone is for P2P keyboard-to-keyboard chat and file transfer, the gap VarAC fills for VARA.
- Packet / AX.25 / VARA.
- Running `ardopcf` *on* iOS. Apple’s audio sandbox makes this a losing battle and the performance wouldn’t be there on older devices. iOS is always a client.
- Running `ardopcf` on iPadOS initially. Technically possible on M-series iPads via some very clever audio routing, but scope-cut until someone asks for it.

## Tech stack

- **Swift 6, SwiftUI**, shared codebase across platforms where sensible.
- **Deployment targets**: macOS 14 (Sonoma), iPadOS 17, iOS 17. Apple Silicon / A14+ baseline on Apple hardware.
- **Swift Package Manager**, no CocoaPods.
- **Swift Concurrency** (async/await, actors) for all networking. No GCD queues, no Combine unless SwiftUI forces it.
- **Network.framework** (`NWConnection`) for TCP to `ardopcf` and `rigctld`. Works identically across macOS, iPadOS, and iOS.
- **Bonjour** (`NWBrowser` / `NWListener`) for zero-config discovery of Sidetone servers on the local network. iOS and iPad clients should find a Mac/Pi running Sidetone-server without the user typing IP addresses.
- **Swift Testing** (not XCTest) for unit tests. Integration tests use a mock `ardopcf` TCP server.
- **SwiftLint** with a strict config. **swift-format** on save.
- No third-party UI libraries. Apple’s SF Symbols, system materials, standard controls.

## Project layout

Single Xcode project, multiple targets, one shared core package. Do **not** make this three separate apps — the duplication cost is too high.

```
Sidetone/
├── Sidetone.xcodeproj
├── Packages/
│   ├── SidetoneCore/              # Pure Swift, no UI, no platform deps
│   │   ├── Sources/SidetoneCore/
│   │   │   ├── TNCClient.swift    # ardopcf protocol client
│   │   │   ├── TNCCommands.swift  # enum of commands
│   │   │   ├── TNCEvents.swift    # enum of async events
│   │   │   ├── RigctldClient.swift
│   │   │   ├── RemoteClient.swift # talks to a Sidetone server over the network
│   │   │   ├── ConnectionManager.swift
│   │   │   └── Models/            # Station, Message, Session, Callsign, Grid, etc.
│   │   └── Tests/SidetoneCoreTests/
│   ├── SidetoneUI/                # SwiftUI views shared across platforms
│   │   └── Sources/SidetoneUI/
│   │       ├── Views/             # Platform-agnostic SwiftUI views
│   │       ├── Components/        # Shared widgets (signal meter, station row, etc.)
│   │       └── ViewModels/        # @Observable state containers
│   └── SidetoneTestSupport/       # Mock TNC server, fixtures, replay harness
├── Apps/
│   ├── Sidetone-Mac/              # macOS app target
│   │   ├── SidetoneMacApp.swift
│   │   ├── Mac-specific views     # menu bar, preferences window, multi-window
│   │   └── SidetoneServer.swift   # Bonjour-advertised local server for iOS/iPad clients
│   ├── Sidetone-iPad/             # iPadOS app target
│   │   └── SidetoneiPadApp.swift
│   └── Sidetone-iOS/              # iOS app target
│       └── SidetoneiOSApp.swift
└── README.md
```

Rules:

- `SidetoneCore` has no `import UIKit`, no `import AppKit`, no `import SwiftUI`. Pure domain logic. This makes it headlessly testable and identically usable on all three platforms.
- `SidetoneUI` uses only SwiftUI + SF Symbols + Foundation. Views check `#if os(...)` only for features that genuinely differ (multi-window on Mac, haptics on iOS).
- App targets are thin — just the app entry point, scene configuration, and platform-specific chrome (menu bar, intents, widgets).
- Code sharing goal: 80%+ of lines live in `SidetoneCore` + `SidetoneUI`. If you find yourself forking a view per-platform, step back and ask whether an adaptive layout handles it.

## ARDOP TNC protocol — what you actually need to implement

Unchanged from platform to platform. `ardopcf` exposes:

- **Command port** (default 8515): bidirectional ASCII lines, `\r` terminated. Client sends commands, TNC sends responses and async events on the same socket.
- **Data port** (default 8516, i.e. command+1): binary data frames with a 2-byte big-endian length prefix, followed by a 4-byte type tag (`ARQ`, `FEC`, `IDF`, `ERR`), then payload.

Both connections must be open simultaneously. If either drops, the session is dead.

Read the authoritative docs before writing any protocol code:

- `ardopcf` README: https://github.com/pflarue/ardop
- Host interface spec: https://github.com/pflarue/ardop/blob/master/HostInterfaceCommands.md
- Reference Pat’s ARDOP transport for a working example: https://github.com/la5nta/pat (look at `transport/ardop`).

**Do not guess at commands.** If the spec is ambiguous, spin up `ardopcf` locally, send real commands, capture the transcript, and code against observed behavior. Record the transcript in `Tests/Fixtures/` so we can replay it.

### Commands and events — minimum viable set

|Command                   |Direction|Purpose                            |
|--------------------------|---------|-----------------------------------|
|`INITIALIZE`              |→ TNC    |Reset state on connect             |
|`MYCALL <call>`           |→ TNC    |Set station callsign               |
|`GRIDSQUARE <grid>`       |→ TNC    |Set Maidenhead grid                |
|`ARQBW <bw>`              |→ TNC    |200/500/1000/2000 Hz, forced or max|
|`ARQCALL <call> <repeats>`|→ TNC    |Initiate ARQ connection            |
|`LISTEN TRUE/FALSE`       |→ TNC    |Accept inbound connections         |
|`DISCONNECT`              |→ TNC    |Graceful close                     |
|`ABORT`                   |→ TNC    |Hard abort                         |
|`SENDID`                  |→ TNC    |Send ID frame                      |
|`CWID TRUE/FALSE`         |→ TNC    |Append CW ID                       |
|`PTT TRUE/FALSE`          |← TNC    |PTT state events (for UI indicator)|
|`STATE <state>`           |← TNC    |DISC / ISS / IRS / IDLE / etc.     |
|`BUFFER <n>`              |← TNC    |Outbound TX buffer depth           |
|`CONNECTED <call> <bw>`   |← TNC    |Session established                |
|`DISCONNECTED`            |← TNC    |Session ended                      |
|`NEWSTATE <state>`        |← TNC    |FSM transition                     |
|`PING <call> <n>`         |→ TNC    |Link quality probe                 |
|`PINGACK <snr> <quality>` |← TNC    |Ping response from peer            |
|`BUSY TRUE/FALSE`         |← TNC    |Channel busy detector              |

Design `TNCCommands` as an enum with associated values; `TNCEvents` as a separate enum. Never pass raw strings around the app.

### Data port framing

```
[2 bytes BE length][4 bytes type][payload...]
```

Type tags: `ARQ`, `FEC`, `IDF`, `ERR`. `ardopcf` has added tags over time — check the current source, don’t trust this list blindly.

## Sidetone server protocol (iOS/iPad ↔ Mac/Pi)

This is the piece that makes multi-platform work. The iOS and iPad apps don’t talk to `ardopcf` directly — they talk to a Sidetone server (running on a Mac or, later, a Pi) that proxies the TNC plus exposes high-level operations.

### Why not just expose ardopcf directly over the network?

`ardopcf` has a `--host` flag that lets it bind to 0.0.0.0, so in theory an iPhone could connect straight to it. Don’t do this:

- No authentication — anyone on the LAN can key your radio.
- Mailbox lives on the server, not the client. If iOS talks directly to the TNC, it has no message history, no station list, no log.
- Concurrent clients need coordination — two phones can’t both drive one ARDOP session.
- We want multiple features beyond the TNC (rig control, log, file browse).

Instead: macOS Sidetone runs an embedded server. iOS/iPad Sidetone is a client.

### Transport

- TLS-over-TCP, self-signed certificate on first run, pinned by the client on initial pairing. Not optional.
- Authentication via a pairing code shown on the server and entered on the client once. After pairing, a persistent token in each device’s Keychain.
- Bonjour advertisement: `_sidetone._tcp` service type so clients find the server automatically on the LAN.
- WebSocket for event streaming; plain HTTPS for request/response endpoints.

### API sketch

```
GET    /api/v1/status              → current session state, TNC state, rig state
GET    /api/v1/stations            → list of saved stations
POST   /api/v1/stations            → add a station
DELETE /api/v1/stations/{call}
POST   /api/v1/connect             → initiate connect to a station
POST   /api/v1/disconnect
POST   /api/v1/abort
POST   /api/v1/listen              → toggle listener
GET    /api/v1/messages            → transcript, paginated
POST   /api/v1/messages            → send a message
GET    /api/v1/log                 → event log / QSO log
POST   /api/v1/rig/frequency       → QSY
WS     /api/v1/events              → live event stream (state changes, incoming messages, PTT, SNR, etc.)
```

Same shape regardless of which platform is the client. `RemoteClient` in `SidetoneCore` consumes this API; direct `TNCClient` usage is for when we’re running the TNC locally. Both implement a common `SessionDriver` protocol so the UI doesn’t know the difference.

### Remote mode on macOS

The Mac app can *also* be a remote client — useful if you have a dedicated station Mac/Pi in another room and a laptop Mac at the desk. Same `RemoteClient`, same UI, different transport.

## UI design

One design language across platforms. The key pattern is **adaptive layout**, not per-platform redesigns.

### Layout strategy

Use `NavigationSplitView` everywhere. It adapts automatically:

- **Mac**: three columns side-by-side (sidebar, chat, inspector). All visible by default. Windows are resizable, columns collapsible.
- **iPad landscape**: three columns side-by-side, same as Mac.
- **iPad portrait**: two columns (sidebar collapses to overlay; chat + inspector visible).
- **iPhone**: stack view — sidebar → chat → inspector as push navigation.

This is what SwiftUI’s `NavigationSplitView` does out of the box with sensible column widths. Don’t fight it.

### The three panes

```
┌─────────────────────────────────────────────────────────────┐
│ [Sidebar]  │  [Chat / Transcript]        │  [Inspector]     │
│            │                             │                  │
│ Stations   │  W1ABC: Hi from Vermont     │  Link Quality    │
│  W1ABC ●   │  me:    Hi! BK FN30AQ       │  ▓▓▓▓▓▓▓░░  72%  │
│  K2DEF     │  W1ABC: Running KX3 @ 10W   │                  │
│  N3GHI     │                             │  SNR   +4 dB     │
│            │                             │  Mode  ARQ 500   │
│ Heard      │                             │  BW    500 Hz    │
│  KQ6LMN    │                             │  State CONNECTED │
│  W0XYZ     │                             │                  │
│            │                             │  Buffer  0 bytes │
│ + New...   │  ┌───────────────────────┐  │  PTT    ● TX     │
│            │  │ Type a message…       │  │                  │
│            │  └───────────────────────┘  │  Rig             │
│            │  [Send] [File…] [Ping]      │  FT-891 14.105   │
│            │                             │  USB-D   50 W    │
└─────────────────────────────────────────────────────────────┘
 Status bar: ardopcf ● connected 127.0.0.1:8515   rigctld ● 4532
```

#### Sidebar

- **Stations** — persistent list. Green dot = heard recently, gold = in session, gray = not heard this session. Context menu / long-press: Connect, Ping, Remove.
- **Heard** — rolling list of stations decoded via ID frames in the last hour. Swipe (iOS) / drag (Mac) to save.
- **+ New…** — modal to manually add a callsign + grid + notes.

On iPhone, this is the root screen.

#### Chat pane

- Message bubbles, restrained. Left-aligned for peer, right-aligned for you, monospaced font (SF Mono) for the body because this is HF and exact characters matter.
- Timestamp + callsign per message, subtle.
- System messages inline: “Connected to W1ABC at 500 Hz”, “Link quality dropped to 40%”, “Disconnected”, in a muted style.
- Full transcript persists per-station via SwiftData.

#### Composer

- Multi-line `TextEditor`.
- **Mac/iPad with hardware keyboard**: Enter = send, Shift+Enter = newline.
- **iOS/iPad touch**: explicit Send button; Return = newline (standard iOS behavior).
- Character counter; warn past 512 chars that this will be slow on HF.
- File attachment button. See §9 of the Pat features spec for auto-shrink behavior.
- On iOS: camera and photo library pickers integrated, with size warning before attach.

#### Inspector pane

Live telemetry from the TNC:

- **Link quality bar** from `PINGACK` quality and ARQ state reports. Color: red < 30, amber 30–60, green > 60.
- **SNR** — last reported.
- **Mode / BW / State** — from `NEWSTATE` and `CONNECTED`.
- **Buffer** — outbound byte count, updates live.
- **PTT indicator** — big obvious dot that goes red on TX.
- **Rig** — frequency, mode, power from rigctld. Frequency tap/click → tuner.

On iPhone, inspector is the third screen in the stack, reachable via a status-summary button in the chat toolbar. On iPad portrait, it’s an overlay triggered by a toolbar button.

### First-run / connection setup

- **Mac**: setup sheet collecting callsign, grid, ardopcf host/port, rigctld host/port, audio device (if launching `ardopcf`), and a “Launch ardopcf for me” toggle (default off).
- **iPad/iOS**: setup sheet with two paths — “Connect to a Sidetone server on my network” (Bonjour list + manual IP fallback) or “I’ll set up a server later.” The phone app should not try to pretend it can run a modem.

### Platform-specific chrome

- **Mac**:
  - Standard menu bar. Menus: **Connection** (Connect to station…, Disconnect, Abort, Listen toggle, Send ID, Ping…), **Radio** (Tune…, Set frequency…, Set mode…), **View** (toggle panes, show log window), **Window** (multi-window support — separate log window, separate inspector window).
  - Preferences window (`Settings` scene).
  - Dock badge for unread count; red dot overlay while transmitting.
  - Menu bar extra (optional, toggleable) showing current state in a compact form.
  - Sparkle-based auto-update for direct distribution; Mac App Store build omits Sparkle.
- **iPad**:
  - Full keyboard shortcut support matching Mac (⌘K jump to connect, ⌘D disconnect, ⌘⇧P ping, ⌘1/2/3 to switch panes, etc.).
  - Stage Manager and multi-window aware.
  - Pointer hover states when used with trackpad.
- **iOS**:
  - Tab bar for top-level navigation when it makes sense, or nav stack.
  - Haptic feedback on PTT state change, incoming message, connection events.
  - Live Activity for active ARDOP sessions — show connected peer, link quality, elapsed time on Lock Screen and Dynamic Island.
  - Push notifications for incoming messages when app is backgrounded (via the Sidetone server — it knows the device’s push token).
  - Shortcuts / App Intents: “Send message via Sidetone”, “Connect to <station>”, “What’s my last message from <station>”, exposable to Siri and the Shortcuts app.
  - Focus filter: the user can have Sidetone notifications silenced outside their ham-shack Focus.
  - Home Screen widgets: current session state, last 3 messages, “quick connect” to a favorite station.

### Accessibility

Every control has a VoiceOver label and an accessibility trait that matches its role. Respect Reduce Motion, Increase Contrast, Dynamic Type on all platforms. The app must be usable by a blind operator with VoiceOver alone — this is not aspirational, it’s a gate on shipping.

## Architecture

```
 ┌────────────────────────────────────────────┐
 │                  SwiftUI Views             │
 └──────────────────────┬─────────────────────┘
                        │ @Observable
 ┌──────────────────────▼─────────────────────┐
 │   AppState (actor, single source of truth) │
 └──────────────────────┬─────────────────────┘
                        │
                        ▼
              ┌──────────────────┐
              │  SessionDriver   │◀── protocol
              └──────────────────┘
                  ▲          ▲
                  │          │
        ┌─────────┘          └──────────┐
        │                               │
   LocalDriver                     RemoteDriver
   (TNC + rigctld                 (HTTPS + WebSocket
    on this device)                to Sidetone server)
        │
        ├─ TNCClient (actor)
        ├─ RigctldClient (actor)
        ├─ Persistence (SwiftData)
        ├─ Notifier
        └─ Subprocess (ardopcf launcher, macOS only)
```

- `SessionDriver` is the abstraction that lets the same UI run over a local TNC or a remote Sidetone server. Critical.
- `TNCClient` is an actor. Owns two `NWConnection`s, parses the protocol, publishes `AsyncStream<TNCEvent>`.
- `AppState` is an `@Observable` actor that consumes events, updates domain models, drives the UI.
- Views are dumb. They read `AppState` and dispatch intents.
- All I/O is cancellable via structured concurrency. Disconnecting must tear down sockets and tasks within 100 ms.

### Session state machine

```swift
enum SessionState: Equatable, Sendable {
    case disconnected
    case listening
    case connecting(to: Callsign, startedAt: Date)
    case connected(peer: Callsign, bandwidth: Int, since: Date)
    case disconnecting
    case error(String)
}
```

Invalid transitions must be unrepresentable. Exhaustively test against the mock TNC.

## Testing

- **Mock TNC server** in `SidetoneTestSupport`: a real TCP server speaking the ARDOP host protocol well enough to drive the client through every state. Scriptable.
- **Mock Sidetone server**: same idea, for `RemoteDriver` tests. iOS/iPad test flows go through this.
- **Transcript replay tests**: feed recorded `ardopcf` output through the parser; assert events match.
- **Fuzz test** the framing parser. Truncated frames, bad length prefixes, split reads across packet boundaries. This is the #1 place naive implementations break.
- **UI tests** with XCUITest for the critical paths on each platform: first-run setup, initiate connection, send message, receive message, disconnect.
- **Cross-platform parity test**: a suite that runs against both `LocalDriver` and `RemoteDriver` and asserts identical observable behavior.

Coverage target: 80%+ on `SidetoneCore`. UI coverage is whatever XCUITest can hit without flake.

## Polish checklist

These separate “works” from “feels native.” Per-platform bullets where relevant.

**All platforms:**

- [ ] App icon that isn’t an emoji — a real icon that works at every size down to the tiny macOS menu bar extra. The sidetone concept (sine wave + envelope) gives you a strong visual.
- [ ] Proper state restoration — if killed mid-session, reopening shows the real current state, not a blank screen.
- [ ] Accessibility labels on every control. VoiceOver must work.
- [ ] Dark mode that looks considered, not just inverted.
- [ ] Dynamic Type support in all text.
- [ ] Respect Reduce Motion and Increase Contrast.
- [ ] Empty states for every list.
- [ ] Crash reporter via MetricKit.
- [ ] Help content shipped in-app, not as a link to a GitHub wiki.
- [ ] Sensible defaults for first launch. Don’t demand configuration before showing UI.
- [ ] Uppercase callsigns on input; permissive validation including portable suffixes (`/P`, `/M`, `/MM`).
- [ ] Timestamps in local TZ by default with UTC toggle. Persist as UTC.
- [ ] Frequencies in Hz internally, displayed as kHz/MHz with locale-aware formatting.
- [ ] Distances in meters. (User preference.)

**Mac:**

- [ ] Window state restoration across launches.
- [ ] Keyboard shortcuts for everything.
- [ ] Menu bar extra, toggleable, compact live status.
- [ ] Signed + notarized build in CI. Unsigned builds are hostile on modern macOS.
- [ ] Direct distribution via Sparkle; Mac App Store build available too.

**iPad:**

- [ ] All Mac keyboard shortcuts work with hardware keyboard.
- [ ] Pointer interactions with trackpad (hover states, secondary click).
- [ ] Multi-window and Stage Manager support.
- [ ] Apple Pencil is a no-op (don’t add features that need it; don’t break the app if one is attached).

**iOS:**

- [ ] Live Activity for active sessions (Lock Screen + Dynamic Island).
- [ ] Home Screen widgets.
- [ ] App Intents for Shortcuts / Siri.
- [ ] Push notifications routed via the Sidetone server.
- [ ] Haptic feedback on key events (connect, disconnect, incoming message, PTT).
- [ ] Focus filter support.
- [ ] Portrait and landscape layouts both work; no “rotate your device” empty states.
- [ ] Small-phone layout (iPhone SE) not broken.

## Milestones

1. **M1 — Protocol bones.** `SidetoneCore` with TNCClient, mock server, green tests. No UI.
1. **M2 — Mac MVP.** Connect, see state, send/receive text. Mac only. Ugly but functional.
1. **M3 — Persistence and roster.** SwiftData, stations list, transcript history. Still Mac only.
1. **M4 — rigctld integration.** Frequency/mode display and control on Mac.
1. **M5 — Sidetone server.** Extract driver abstraction, build embedded HTTPS/WS server on Mac, implement Bonjour advertisement, add pairing flow.
1. **M6 — iPad app.** Same core, same UI (adaptive), talking to Mac server. This should be mostly free if §M5 went right.
1. **M7 — iOS app.** Phone-optimized layouts, Live Activities, widgets, Shortcuts, push notifications.
1. **M8 — Mac polish.** Everything in the Mac polish checklist. This is where Claude Code projects usually stop too early. Don’t.
1. **M9 — iPad/iOS polish.** Platform-specific polish checklists. Live Activities and widgets are here, not in M7.
1. **M10 — File transfer.** Binary attachments over ARQ with progress and resume-on-reconnect, on all three clients.
1. **M11 — Stretch.** Pi-based headless server distribution; Linux port of the server only (not the GUI); spectrum waterfall; scheduled actions.

The order matters. Don’t start the iPad app before the server abstraction is solid in M5 — you’ll regret it.

## Deliverables at M9

- Signed `.app` bundle / `.dmg` for macOS (direct distribution + Mac App Store build).
- iPadOS and iOS TestFlight builds, then App Store submission.
- README with install, run, pairing, troubleshooting — platform-specific sections.
- CONTRIBUTING.md.
- `docs/protocol-notes.md` capturing every ARDOP protocol quirk discovered.
- `docs/server-api.md` for the Sidetone server API — this is effectively a public contract once iOS clients are in the wild.
- Demo screen recording covering at least one flow per platform.

## Process notes for Claude Code

- **Read the ardopcf source before writing protocol code.** Don’t write against a vibe of what the protocol is.
- **Run ardopcf locally from day one** on macOS. Loopback audio via BlackHole is fine for development — no radio needed to iterate on the GUI.
- **Start platform-agnostic.** Every time you’re tempted to write `#if os(macOS)`, ask whether the abstraction is wrong. Sometimes the answer is yes and the right fix is in `SidetoneCore`.
- **Don’t build the iOS app until M6.** Trying to build three platforms in parallel from day one burns time on coordination. Mac first, pull features into the shared packages, then iOS/iPad follow almost for free.
- **Commit in small, reviewable chunks.** Each PR should have one reason to exist.
- **When something’s ambiguous, ask.** Don’t invent requirements. If I’m not around, pick the option that’s easier to change later and leave a TODO with reasoning.
- **No placeholder callsigns like “N0CALL” shipped in UI.** Empty states or real defaults only.