# Intercom Emulator: Implemented Protocol and Server Capability Gaps

## Scope

This document is based on the currently implemented backend code in `mobile-id-systems` (staging target: `https://staging.igcsolutions.org`).
The emulator in this repository uses only real protocol surfaces already implemented on server side.

## Implemented server protocol used by emulator

### 1) Hub websocket endpoint

- Endpoint: `wss://staging.igcsolutions.org/api/cloud/hub/ws`
- Authentication message type: `auth`
- Required auth fields:
  - `family`
  - `serial`
  - `ts` (unix seconds)
  - `nonce`
  - `sign` (hex HMAC-SHA256)
  - `body` (signed JSON object)
- Signature formula:
  - `HMAC_SHA256(hub_key, "${ts}.${nonce}.${JSON.stringify(body)}")`

### 2) Runtime message types supported by backend websocket gateway

Inbound from device/hub to server:
- `auth`
- `status`
- `command_results`
- `events`
- `pull`
- `get_last_uid`
- `ping`

Outbound from server to device/hub:
- `auth_ok`
- `auth_error`
- `status_ok`
- `results_ok`
- `command`
- `command_batch`
- `init_uid`
- `pong`
- `error`

### 3) Intercom/installation CRUD APIs (not call runtime)

Implemented routes under `/api/intercom` include subscriber and route/member management.
These configure data but do not provide end-user call signaling or media runtime.

## Capability gaps blocking full intercom call emulator

### Missing for real app-style intercom call flow

The backend currently does not expose dedicated mobile intercom runtime APIs for:
- Incoming intercom call invitation to end-user mobile app (subscriber-member level)
- Call accept/decline/cancel lifecycle endpoints or WS topics
- SDP offer/answer and ICE candidate signaling API between panel and mobile app
- TURN/STUN policy endpoint and session token issuance
- Explicit door-open command from mobile call UI context
- Call session telemetry stream tied to subscriber/mobile identity

### What exists instead

Current command path is controller tunnel transport (`tunnel_packet`, `tunnel_job`, related file/config jobs) designed for low-level controller communication. It is not a complete mobile user-call protocol.

## Emulator behavior in this repository

- Connects to real hub websocket endpoint with real HMAC auth.
- Sends periodic `status` messages.
- Accepts `command` and `command_batch` from server.
- Sends `command_results` back.
- Marks low-level tunnel commands as `unsupported` in result payload to make protocol gaps explicit.

## Minimal server additions needed for end-to-end intercom calls

1. Add dedicated intercom runtime WS namespace or REST+WS pair for mobile app sessions.
2. Add call session API contract:
   - create incoming call
   - accept
   - decline
   - hangup
   - timeout
3. Add WebRTC signaling contract:
   - offer/answer exchange
   - ICE candidate exchange
   - renegotiation/reconnect events
4. Add access-control action contract from active call:
   - door open request
   - command acknowledgement
   - audit event
5. Add authorization model connecting subscriber/member/mobile identifier to runtime call rights.

## Safety and environment notes

- Emulator is intended for staging only.
- Do not point emulator to production while protocol is incomplete.
- No production code or DB changes are performed by this repository.
