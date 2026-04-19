# Sidetone

Native Apple-ecosystem GUI for ARDOP keyboard-to-keyboard chat and file
transfer on top of a running [`ardopcf`](https://github.com/pflarue/ardop)
modem. macOS, iPadOS, iOS.

Think VarAC for ARDOP but as a real Mac app that also gives you a
companion iPhone in the field.

---

## Architecture at a glance

```
┌─────────────────────┐    ┌─────────────────────┐
│  Sidetone UI        │    │  Sidetone UI        │
│  (SwiftUI)          │    │  (SwiftUI)          │
└──────────┬──────────┘    └──────────┬──────────┘
           │                          │
           ▼                          ▼
      AppState ── MainActor observable single source of truth
           │                          │
           ▼                          ▼
     ┌──────────────┐         ┌──────────────┐
     │ LocalDriver  │         │ RemoteDriver │
     │ (local TNC)  │         │ (HTTPS + WS) │
     └──────┬───────┘         └──────┬───────┘
            │                        │
            ▼                        ▼
     ┌──────────┐             ┌──────────────┐
     │ ardopcf  │             │ Sidetone     │
     │ 8515/16  │             │ Server (Mac) │
     └──────────┘             └──────┬───────┘
                                     │
                                     ▼
                                LocalDriver → ardopcf
```

Two drivers, one `SessionDriver` protocol. UI never branches on which is
live — the iPad/iPhone can drive a Mac/Pi-hosted session with the same
code as the Mac driving its own ardopcf.

---

## Install & run

### Prerequisites

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode 26 / Swift 6 toolchain
- [`ardopcf`](https://github.com/pflarue/ardop) built and installed
- Optional: [`rigctld`](https://hamlib.sourceforge.net) for CAT

### Build the Mac app

```sh
git clone https://github.com/morria/sidetone.git
cd sidetone
swift build -c release
```

This produces `.build/release/SidetoneMac`. Run it:

```sh
swift run -c release SidetoneMac
```

A proper signed `.app` bundle requires an Xcode project (planned in M8
polish per the spec; not yet created).

### Run ardopcf

The simplest development setup loops audio through
[BlackHole](https://github.com/ExistentialAudio/BlackHole) so you can
iterate without a radio:

```sh
brew install --cask blackhole-2ch
ardopcf 8515 "BlackHole 2ch" "BlackHole 2ch"
```

For a real setup: point ardopcf at your radio's sound-card interface,
then launch Sidetone.

### First run

Sidetone opens a setup sheet. Choose *Local ardopcf*, enter your
callsign + grid + `127.0.0.1:8515`, click Connect. The three-pane
UI opens.

---

## Pairing an iPad or iPhone

With the Mac running Sidetone next to its ardopcf:

1. Mac: enable pairing (Connection → Enable Pairing). A six-digit code
   displays for five minutes.
2. iPad/iPhone: open Sidetone, tap *Add Sidetone server*. The Mac
   appears in the Bonjour list automatically.
3. Pick the Mac, enter the code, give the device a name.
4. The token is stored in the device's Keychain. Subsequent launches
   auto-connect.

The server presents a self-signed TLS certificate; its SHA-256
fingerprint is pinned at pairing time and verified on every
subsequent connection. Rogue "Sidetone" servers on your LAN can't
hijack an already-paired device.

---

## Troubleshooting

### ardopcf won't connect

```sh
lsof -i:8515
```

If nothing is listening, ardopcf isn't running. If something else is
listening, use a different port on both sides.

### iPad can't find the Mac

Both devices need to be on the same Wi-Fi network, and mDNS must be
unfiltered on the router. Guest networks and some corporate networks
block Bonjour.

Manual fallback: enter the Mac's IP + port directly in the setup form.

### My PTT isn't firing

Check the inspector — the PTT indicator goes red on transmit. If it
doesn't light up:

- ardopcf isn't wired to your radio's PTT (CAT, VOX, or an external
  interface)
- Check ardopcf's own log output for audio level / keying errors

### Messages look garbled

ARQ assumes a stable path. Watch link quality in the inspector. Under
30, the session is unlikely to hold. Drop to a narrower bandwidth
(ARQBW 200 Hz) on noisy bands.

---

## Platform notes

- **macOS** — full station experience. Menu bar, menu bar extra,
  preferences, help, multi-window (log in its own window via View →
  Activity Log).
- **iPad** — same UI, adaptive layout. Pair with a Magic Keyboard and
  a Pi running Sidetone-server for a portable station controller.
- **iOS** — phone-optimized. Always a client, never runs ardopcf
  itself. Live Activities, App Intents, and push notifications are
  planned for M7/M9.

---

## What's in the tree

```
Packages/
  SidetoneCore/          # Pure Swift: protocol, persistence, DTOs
    Sources/SidetoneCore/
      TNC/               # ARDOP host-interface client + framing
      Session/           # SessionDriver abstraction + Local/Remote drivers
      Persistence/       # SwiftData models + CRUD facade
      Rig/               # rigctld client
      Server/            # DTOs for the Sidetone server API
      Bonjour/           # Discovery
      Files/             # File transfer chunking
      Models/            # Callsign, Grid, Station, Message, SessionState
  SidetoneUI/            # SwiftUI views, shared across platforms
  SidetoneServer/        # swift-nio HTTP + WebSocket server (Mac/Pi)
  SidetoneTestSupport/   # Mock TNC + Mock rigctld + integration parent suite
Apps/
  Sidetone-Mac/          # SPM executableTarget for the Mac app
```

`docs/`:
- `protocol-notes.md` — captured quirks and deviations against
  `ardopcf`'s HostInterfaceCommands.md
- `server-api.md` — wire contract for `/api/v1/*`

---

## Known gaps

- No `Sidetone.xcodeproj` yet — Mac app runs via `swift run`. A real
  signed bundle, iPad/iOS targets, Widgets, Live Activities, and App
  Intents need an Xcode project (planned M6–M9).
- Auto-shrink behavior for image attachments is referenced in SPEC but
  the content is missing from both spec files.
- TLS uses a self-signed cert generated on first launch. There's no
  cert rotation story yet.
- Resume-on-reconnect for file transfers is structurally supported
  (`FileReassembler.missingChunks`) but the actual resume orchestration
  isn't wired to session lifecycle events yet.

See `docs/protocol-notes.md` for ARDOP-protocol specifics, and
`docs/server-api.md` for the client/server API contract.
