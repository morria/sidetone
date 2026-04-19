<div align="center">

# Sidetone

**A native Apple-ecosystem GUI for ARDOP keyboard-to-keyboard chat and file transfer.**

*macOS at the desk, iPad on the couch, iPhone in the field — one codebase.*

[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000?logo=apple&logoColor=white)](https://apple.com/macos)
[![iPadOS 17+](https://img.shields.io/badge/iPadOS-17+-000?logo=apple&logoColor=white)](https://apple.com/ipados)
[![iOS 17+](https://img.shields.io/badge/iOS-17+-000?logo=apple&logoColor=white)](https://apple.com/ios)
[![Tests](https://img.shields.io/badge/tests-101%20passing-brightgreen)](#status)

</div>

---

## Why

In CW, the *sidetone* is the local audio the operator hears while keying — the confirmation of what's going out over the air. This app is that: your local interface to a conversation happening on HF.

Most digital-mode clients on HF are Windows applications ported reluctantly to the Mac, if at all. Sidetone flips that: native SwiftUI, Swift 6 strict concurrency, idiomatic Apple-ecosystem integrations (Bonjour discovery, Keychain-backed pairing, Live Activities, App Intents). The goal is a real app you'd use with your FT-891 at home and your iPhone at a POTA site — not a demo.

Sidetone is the GUI. [`ardopcf`](https://github.com/pflarue/ardop) is the DSP and radio-facing daemon. The two talk over TCP.

---

## Feature snapshot

| Platform | Role |
|---|---|
| **macOS** | Full station. Local `ardopcf` + `rigctld`, three-pane adaptive layout, menu bar, menu bar extra with live state, in-app help, ADIF export for your logger, state restoration. |
| **iPadOS** | Co-primary. Same UI, adaptive. Pair with a Magic Keyboard and a Raspberry Pi and run a portable station controller from a picnic table. |
| **iOS** | Companion client. Never runs the modem itself — it drives a Mac or Pi over the LAN. Quick check-ins, monitor a net, send a short message. *"Carry the station in your pocket"* not *"run a station from your pocket."* |

| Capability | State |
|---|---|
| ARDOP protocol (commands, events, data port) | done, 101 tests |
| Multi-station persistence (SwiftData) | done |
| Hamlib `rigctld` CAT control | done |
| Sidetone server (Bonjour, pairing, TLS + pinning) | done |
| File transfer (chunked, resumable structure) | done, end-to-end |
| Mac signed bundle, iPad/iOS targets | needs `.xcodeproj` |
| Live Activities, Widgets, App Intents | planned (iOS target) |

---

## Architecture

```mermaid
flowchart LR
    subgraph Devices["Any Apple device"]
        UI[SwiftUI views]
        STATE[AppState<br/>@Observable]
        UI --> STATE
    end

    STATE --> DRIVER{SessionDriver<br/>protocol}

    subgraph Local["Local mode (Mac)"]
        LD[LocalDriver]
        TNC[TNCClient]
        RIG[RigctldClient]
        LD --> TNC
        LD --> RIG
    end

    subgraph Remote["Remote mode (iPhone/iPad/Mac)"]
        RD[RemoteDriver]
        HTTP[HTTPS + WebSocket]
        RD --> HTTP
    end

    DRIVER -->|"ardopcf on this device"| LD
    DRIVER -->|"ardopcf elsewhere"| RD
    HTTP -.-> SERVER[Sidetone Server<br/>on Mac/Pi]
    SERVER --> LD

    TNC -->|"TCP 8515/8516"| ARDOP[ardopcf]
    ARDOP -->|"HF"| RADIO(Radio)
```

The `SessionDriver` protocol is the architectural anchor: the UI never branches on whether it's talking to a local TNC or a remote server. An iPad on the couch drives a Pi on the shelf with the same code that a Mac uses to drive its own ardopcf.

Five layered Swift packages:

- **`SidetoneCore`** — pure domain logic, no UIKit/AppKit/SwiftUI. Protocol, drivers, persistence, DTOs.
- **`SidetoneUI`** — SwiftUI views, shared across platforms, `#if os(...)` only for genuine feature differences.
- **`SidetoneServer`** — swift-nio HTTP+WebSocket server with TLS. Mac/Pi only.
- **`SidetoneTestSupport`** — real-TCP mocks for ardopcf and rigctld, integration-test parent suite.
- **`SidetoneMac`** — the Mac app (SPM executable target today; proper Xcode project is the next step).

---

## Install & run

### Prerequisites

- macOS 14 (Sonoma) or later on Apple Silicon
- Xcode 26 / Swift 6.0+
- [`ardopcf`](https://github.com/pflarue/ardop) built and in `$PATH`
- Optional: [`rigctld`](https://hamlib.sourceforge.net) for CAT control

### Dev setup without a radio

For iterating on the UI you don't need a real radio — loop audio through [BlackHole](https://github.com/ExistentialAudio/BlackHole):

```sh
brew install --cask blackhole-2ch
ardopcf 8515 "BlackHole 2ch" "BlackHole 2ch"
```

### Build and run

```sh
git clone https://github.com/morria/sidetone.git
cd sidetone
swift build
swift run SidetoneMac
```

A setup sheet opens. Enter your callsign + grid square, leave host/port as `127.0.0.1:8515`, click Connect. The three-pane UI opens — stations sidebar, chat transcript, live-telemetry inspector.

---

## Quick tour

<details>
<summary><b>Calling a station</b></summary>

Press **⌘K** (or **Connection → Connect to Station…**). Pick a saved station or type a callsign. Choose an ARQ bandwidth — 500 Hz is a safe default. Click Connect. The inspector pane shows live state transitions, PTT indicator, link quality as it comes back.

</details>

<details>
<summary><b>Sending a file</b></summary>

In any chat, tap the paperclip in the composer. Pick any file. A banner appears with a progress bar, and the far side sees chunks arrive over ARQ. Sidetone warns on files over 512 KB — at 500 Hz those take a while.

</details>

<details>
<summary><b>Multi-device setup</b></summary>

On the Mac running ardopcf: **Connection → Enable Pairing**. A 6-digit code appears for 5 minutes. On the iPad or iPhone: **Add Sidetone server**. The Mac appears in the Bonjour list. Pick it, enter the code, give the device a name.

The pairing exchange returns a persistent token (stored in the device's Keychain) and the server's TLS certificate SHA-256 fingerprint (pinned on every subsequent connection). Rogue "Sidetone" servers on your LAN can't hijack a paired device.

</details>

<details>
<summary><b>Exporting QSOs to your logger</b></summary>

**View → Activity Log (⌘L)**. The toolbar has an Export button that writes ADIF v3.1.5. Feed the file to MacLoggerDX, N1MM, or LoTW — standard format.

</details>

---

## Development

```sh
swift test   # 101 tests, ~1.2s
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for code layout, protocol-change rules, and a note about Swift Testing's parallelism + Network.framework deadlocks. (Short version: socket-touching tests must nest under the shared `IntegrationTests` parent, or things hang.)

The wire contract for the Sidetone server API is in [`docs/server-api.md`](docs/server-api.md). ARDOP host-protocol quirks Sidetone has discovered are in [`docs/protocol-notes.md`](docs/protocol-notes.md).

---

## Status

**Shipping** (pushed to `main`):

- M1 ARDOP protocol — commands, events, data-port framing (the spec's 4-byte tag is actually 3; we code against reality)
- M2 Mac MVP — connect, transcript, send/receive
- M3 persistence — SwiftData for stations and messages
- M4 rigctld integration — frequency + mode get/set
- M5 multi-device — server, RemoteDriver, Bonjour, pairing, TLS + pinning
- M8 polish — connect dialog, help, log view, menu bar extra, state restoration, ADIF export
- M10 file transfer — end-to-end chunking, inbound demux, outbound via data port, composer UI, remote upload endpoint

**Blocked on `Sidetone.xcodeproj`** (needs to be created by a human in Xcode):

- M6 iPad app target
- M7 iOS app target (Live Activities, widgets, App Intents, push notifications)
- M9 signed Mac `.app` bundle with Sparkle auto-update

**Known gaps:**

- The "§9 Pat features" auto-shrink behavior referenced in SPEC is missing from both spec files. M10 splits files but doesn't shrink them.
- No cert rotation story (self-signed cert lives forever; acceptable for LAN).
- Resume-on-reconnect for file transfers is structurally supported (`FileReassembler.missingChunks` reports gaps) but the orchestration against session lifecycle events isn't wired.

---

## Non-goals

- Reimplementing ARDOP or any DSP. ardopcf is the modem, and it's good.
- Windows, Linux, or Android. [Pat](https://getpat.io) owns those niches.
- Winlink CMS. Pat does Winlink well; Sidetone is for P2P keyboard-to-keyboard.
- Packet / AX.25 / VARA.
- Running `ardopcf` *on* iOS. Apple's audio sandbox makes this a losing battle.

---

## License

Not yet specified. Pick one before distributing.

## Acknowledgements

- [Peter LaRue, KD2GGZ](https://github.com/pflarue) for `ardopcf`.
- The VarAC team for defining what a "keyboard-to-keyboard chat client for HF" should feel like.
- [Pat](https://getpat.io) — its `transport/ardop` implementation was a useful reference.
- [RadioMail](https://radiomail.app) — the "phone is a client, the radio is somewhere else" philosophy lives here too.
