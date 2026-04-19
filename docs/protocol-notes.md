# ARDOP / ardopcf protocol notes

Notes captured while implementing `SidetoneCore` against `ardopcf` master
(commit TBD — update when we pin a version). The canonical reference is
ardopcf's `docs/Host_Interface_Commands.md` and the source at
`src/common/TCPHostInterface.c`.

## Command socket (default port 8515)

- ASCII lines terminated with `\r` (0x0d). `\n` is not used.
- Commands are case-insensitive on input. Our serializer emits uppercase
  so on-wire transcripts read consistently.
- Some commands get a response echo of the form `NAME now VALUE`
  (e.g. `MYCALL now K7ABC`); some queries respond with `NAME VALUE`
  (e.g. `MYCALL K7ABC`); some (e.g. `INITIALIZE`, `SENDID`, `TWOTONETEST`)
  produce no response at all.
- Errors come back as `FAULT <description>`.
- Async events on the same socket include: `NEWSTATE`, `BUFFER`,
  `CONNECTED`, `DISCONNECTED`, `TARGET`, `PTT`, `BUSY`, `PING`,
  `PINGACK`, `PINGREPLY`, `PENDING`, `CANCELPENDING`, `REJECTEDBW`,
  `REJECTEDBUSY`, `FAULT`, `STATUS`, and more. The ardopcf docs
  themselves note the list is incomplete; our parser therefore surfaces
  unrecognized keywords as `.ack(keyword:body:)` rather than dropping.

## Data socket (default port 8516 = command + 1)

**The SPEC.md summary is wrong about the byte layout.** The real format, from
`src/common/TCPHostInterface.c::TCPAddTagToDataAndSendToHost`:

```
[2-byte big-endian length] [3-byte ASCII tag] [payload]
```

Where `length == 3 + payload.count` — i.e. the length field **includes the
3-byte tag**. The tag is **3 bytes, not 4**.

Tags observed in source: `FEC`, `ARQ`, `ERR`, `IDF` (the last not
currently emitted by the codepath we read, but reserved).

`DataFrameParser` buffers partial reads across packet boundaries and
surfaces `badLength(<3)` / `invalidTagBytes` as recoverable errors without
tearing down the session. Unknown tags pass through as
`DataFrame.Kind.unknown(String)` so future ardopcf additions don't go
silently missing.

## Why our implementation differs from SPEC.md

SPEC.md §"Data port framing" was written from a high-level summary and
specifies a 4-byte tag. `ardopcf` uses 3 bytes. We implement what
ardopcf actually emits. When the spec is updated, this note can go.

## Open questions / TODO

- Capture a real ardopcf transcript and commit it under
  `Tests/Fixtures/` for replay tests. Deferred until we have a radio
  hooked up — loopback with BlackHole will do.
- Confirm the exact `TARGET` event format (docs silent).
- Confirm whether `STATUS` carries structured subcontext; docs hint yes
  but don't enumerate.
