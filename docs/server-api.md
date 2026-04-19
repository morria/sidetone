# Sidetone Server API

This document is the wire contract for the Sidetone server that runs on
a Mac (or eventually a Pi) and is consumed by iOS, iPadOS, and Mac
clients in remote mode.

Once there are iOS builds in users' hands, this API is effectively
public: changes that aren't additive require bumping the version path.

## Base URL

- `https://<host>:<port>/api/v1/`
- TLS is mandatory for production. Development on localhost may use
  `http://` but clients should refuse unless explicitly configured.
- Server certificates are self-signed; clients pin the SHA-256 DER
  fingerprint captured at pairing time.

## Auth

- All endpoints except `POST /api/v1/pair` require
  `Authorization: Bearer <token>`.
- Unauthorized requests return `401` with a JSON `ErrorResponse`:

  ```json
  {"code": "unauthorized", "message": "missing or invalid token"}
  ```

## Error envelope

Non-2xx responses use the standard envelope:

```json
{"code": "wrong_code", "message": "code does not match"}
```

## Endpoints

### `POST /api/v1/pair`

Exchange a six-digit pairing code for a persistent token. Public;
pairing must be enabled on the server for this to succeed.

Request:

```json
{"code": "123456", "deviceName": "Andrew's iPhone"}
```

Response `200`:

```json
{
  "token": "<32-byte base64url>",
  "certificateFingerprint": "abc123…",
  "serverName": "Andrew's MacBook"
}
```

Error codes: `pairing_disabled`, `pairing_inactive`, `wrong_code`,
`code_expired`.

### `GET /api/v1/status`

```json
{
  "session": {
    "kind": "connected",
    "peer": "W1ABC",
    "bandwidth": 500,
    "since": "2026-04-18T21:00:00Z"
  },
  "tncConnected": true,
  "rigConnected": false,
  "myCall": "K7ABC",
  "myGrid": "FN30aq"
}
```

### `GET /api/v1/stations` · `POST /api/v1/stations`

- `GET` — `{"stations": [...StationDTO]}`
- `POST` body is a single `StationDTO`. Returns `201` with the saved
  station.

### `POST /api/v1/connect`

```json
{"callsign": "W1ABC", "bandwidth": "500MAX", "repeats": 5}
```

- `bandwidth` is one of `200|500|1000|2000` optionally suffixed
  `MAX` or `FORCED`. Omitted = `500MAX`.
- Returns `202 Accepted`.

### `POST /api/v1/disconnect` · `POST /api/v1/abort`

No body. `disconnect` is a graceful ARQ teardown, `abort` is a hard
stop. `202 Accepted`.

### `POST /api/v1/listen`

```json
{"enabled": true}
```

### `POST /api/v1/messages`

```json
{"peer": "W1ABC", "body": "Hi from Vermont"}
```

Server queues the text on the TNC. `202 Accepted`; actual transmission
progress comes via the WebSocket stream.

### `POST /api/v1/files`

Raw-body upload. Metadata in headers (no multipart):

- `Content-Type` — the MIME type
- `X-Sidetone-Filename` — required, basename only
- `X-Sidetone-MimeType` — preferred over `Content-Type` for the file
  metadata

Body: raw file bytes. Server chunks via `FileChunker` (1 KB default
payload) and queues chunks on the TNC data port.

`202 Accepted`.

### `GET /api/v1/log`

Query: `?limit=N` (default 200).

```json
{"messages": [...MessageDTO]}  // newest first, across all peers
```

### `WS /api/v1/events`

WebSocket. Auth via `Authorization` header on the upgrade request.
Server pushes JSON `EventEnvelope` frames. First frame after
subscription is a `state_changed` snapshot so clients don't need a
separate `GET /status`.

Envelope:

```json
{
  "kind": "state_changed",
  "data": { ...payload for this kind... }
}
```

Kinds and their payloads:

| kind                | payload                                               |
| ------------------- | ----------------------------------------------------- |
| `state_changed`     | `SessionStateDTO`                                     |
| `message_received`  | `MessageDTO`                                          |
| `message_sent`      | `MessageDTO`                                          |
| `link_quality`      | `{"snr": Int, "quality": Int}`                        |
| `ptt`               | `{"value": Bool}`                                     |
| `busy`              | `{"value": Bool}`                                     |
| `buffer`            | `{"value": Int}`                                      |
| `fault`             | `{"message": String}`                                 |
| `heard`             | `StationDTO`                                          |
| `file_progress`     | `FileTransferDTO` (without payload bytes)             |
| `file_received`     | `FileTransferDTO`; full payload fetched out of band   |

**Forward compatibility:** unknown `kind` values are silently skipped
by clients that don't recognize them. Server can add new kinds without
breaking old clients. Never rename or remove a kind without bumping
to `/api/v2`.

## Data types

### `SessionStateDTO`

```json
{
  "kind": "connected",  // disconnected | listening | connecting | connected | disconnecting | error
  "peer": "W1ABC",      // optional
  "bandwidth": 500,     // optional, Hz
  "startedAt": "…",     // connecting only
  "since": "…",         // connected only
  "reason": "…"         // error only
}
```

### `StationDTO`

```json
{
  "callsign": "W1ABC",
  "grid": "FN33",
  "notes": "…",
  "lastHeard": "2026-04-18T21:00:00Z"
}
```

### `MessageDTO`

```json
{
  "id": "uuid",
  "timestamp": "2026-04-18T21:00:00Z",
  "direction": "sent",  // sent | received | system
  "peer": "W1ABC",
  "body": "Hi"
}
```

### `FileTransferDTO`

```json
{
  "id": "uuid",
  "filename": "photo.jpg",
  "mimeType": "image/jpeg",
  "totalBytes": 12345,
  "totalChunks": 13,
  "direction": "inbound",
  "peer": "W1ABC",
  "chunksCompleted": 4,
  "isComplete": false
}
```

## Dates

All dates are ISO 8601 with timezone, encoded and decoded with
`JSONEncoder.dateEncodingStrategy = .iso8601`.

## Versioning

This document describes `v1`. When we add breaking changes (renaming
a field, removing a kind), we'll introduce `/api/v2` and both versions
will run in parallel long enough for every pairing in the wild to
upgrade.
