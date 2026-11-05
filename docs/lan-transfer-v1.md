# Native LAN file transfer v1

Scope: Windows native host + iOS native client. Existing web/Scriptable/cloud relay stays wire-compatible. No backend file API is called for a LAN task. This is device transfer, not another URL for the cloud server. Source files and logs must not contain deployment addresses, personal paths or credentials.

## Discovery and authentication

Windows advertises `_workbench._tcp.local.` via mDNS, with an HTTPS listener on an ephemeral port. Advertising is opt-in; firewalls are not changed automatically. Bonjour TXT fields: `v=1`, `id` (32 lower hex stable host ID), `scope` (64 hex), `key` (existing 16 hex key_id), `fp` (64 hex SHA256 of leaf certificate DER), `name` (UTF-8 friendly name, <=64 bytes), `mac` (standard base64 HMAC-SHA256).

Server base canonicalization: trim whitespace, remove trailing `/`, lowercase scheme and hostname; preserve explicit non-default port; omit default HTTPS port 443. Scope = lowercase hex SHA256 of UTF-8 `workbench-lan-scope-v1\n{canonical_server}\n{username}\n{key_id}`. Username is the login response username, unchanged. No account token is involved.

Authentication key = HKDF-SHA256(account DEK, salt=UTF-8 `workbench:lan:v1`, info=UTF-8 `authentication`, output=32 bytes). Discovery canonical text, UTF-8 with no final newline:

```text
workbench-lan-discovery-v1
{scope}
{key_id}
{host_device_id}
{certificate_sha256}
{port_decimal}
{name}
```

`mac` authenticates that text. Verify scope, key_id, field bounds and MAC before showing a connectable peer. Only discovered `.local`/LAN endpoints are eligible; no arbitrary URL or redirects. TLS certificate pin must match verified `fp`, on a dedicated ephemeral URLSession/client with cookies, proxy and cache disabled. Do not weaken the account API's HTTPS/same-origin checks. Host private key is protected using Windows DPAPI. Client Ed25519 signing identity is saved in iOS Keychain per account scope.

Every request carries these headers: `X-WB-Device` (32 lower hex client ID), `X-WB-Key` (standard base64 32-byte Ed25519 public key), `X-WB-Time` (Unix seconds), `X-WB-Nonce` (32 lower hex fresh random), `X-WB-Account` (base64 HMAC-SHA256), `X-WB-Signature` (base64 64-byte Ed25519 signature). Both MAC and signature cover UTF-8, without final newline:

```text
workbench-lan-request-v1
{host_device_id}
{client_device_id}
{timestamp_decimal}
{nonce}
{uppercase_method}
{exact_path}
{lowercase_sha256_of_body}
```

No query strings or Authorization/Bearer headers. Reject timestamps outside +/-60 seconds and replays; nonce replay state is bounded but never evict live entries to accept more requests (429 instead). Limit pair attempts and simultaneous connections. Trusted requests must match the stored client ID/public key binding. Discovery proves possession of the existing account DEK, but first pairing still needs explicit approval on Windows; iOS asks before requesting trust. Key changes, logout or account changes stop the listener/client tasks and invalidate account-scoped trust. An account-authenticated but unpaired caller may only call hello/pair; no file metadata or bytes are exposed before approval. Pairing is not implemented using an unauthenticated six-digit password.

## Endpoints

JSON response/error bodies use UTF-8, `Cache-Control: no-store`; error = `{ "detail": "safe localized message" }`. HTTP redirects are never followed. Request headers <=16 KiB, JSON <=128 KiB, chunk <=4MiB+28. Require bounded Content-Length for request bodies; reject transfer-encoding and duplicate security/content-length headers. Restrict paths and IDs, never accept filesystem paths over HTTP.

- `GET /lan/v1/hello` -> `{ "v":1,"id":host_id,"name":name,"state":"trusted|unpaired|pending","max_file":209715200 }`.
- `POST /lan/v1/pair`, body `{ "name": "iPhone" }` -> `{ "state":"pending|trusted|declined" }`. Request identity comes only from verified headers; same signed request with a fresh nonce is an idempotent poll, never reset a declined request automatically. Host UI approves/declines. Revoking a trusted device requires a new explicit pairing decision.
- `GET /lan/v1/inbox` -> `{ "files": [manifest, ...] }`: only host-to-client offers targeted at this verified client. Each manifest includes `state`.
- `POST /lan/v1/transfers`, body existing encrypted manifest -> `{ "state":"pending|accepted|received|declined", "missing":[indices] }`: client-to-host offer. Host explicitly accepts each file; optional trusted-device auto-receive is off by default. Registration is idempotent by account, direction, client ID and fid, immutable manifest on retries; conflicts return 409. Do not create a cloud relay row.
- `GET /lan/v1/transfers/{fid}` -> `{ "state":..., "missing":[indices] }` for incoming host-side upload or outgoing offer, always restricted to client owner/target.
- `POST /lan/v1/transfers/{fid}/accept` -> state: client accepts host-to-client offer, allowing GET chunks.
- `POST /lan/v1/transfers/{fid}/decline` -> state: explicit rejection/cancellation, no automatic cloud fallback.
- `PUT /lan/v1/transfers/{fid}/chunks/{index}`: client uploads an accepted file, exact encrypted chunk bytes. Verify declared lengths/GCM before acknowledging; atomically save encrypted chunk. Return `{ "ok":true }`.
- `GET /lan/v1/transfers/{fid}/chunks/{index}`: client downloads an accepted host offer, exact encrypted bytes. Only offer target may read. No base64 wrappers.
- `POST /lan/v1/transfers/{fid}/complete` -> `{ "state":"received" }`: host assembles accepted incoming file to a private `.part`, verifies size and SHA256, synchronizes, atomically renames to a unique safe filename in app-owned received directory, persists receipt, then responds. Idempotent completion. Do not open received files automatically.
- `POST /lan/v1/transfers/{fid}/received`, body `{ "sha256": expected_hash, "size": plain_size }` -> `{ "state":"received" }`: iOS sends only after complete verification and durable atomic storage in its protected received library. Host validates expected hash/size and persists receipt; repeated receipt returns same state.

Manifest fields retain existing relay semantics: `fid`, `key_id`, `chunks`, `cipher_size`, `meta`, optional `thumb`, `source`, `device`. Incoming metadata MUST be authenticated/decrypted and validated before asking for acceptance; `meta` includes `name,size,type,sha256,chunk`. Fixed chunk is 4194304, empty file has one 28-byte encrypted chunk, count is max(1, ceil(size/chunk)), cipher_size=size+28*count. Validate all arithmetic and enforce advertised per-file limit (initially 200 MiB both directions), disk capacity, pending count and encrypted queue capacity. Filename is display data, never a path. Keep nonce/ciphertext/AAD layout and existing file vectors unchanged.

## Lifecycle and UI

Windows: opt-in local receive with listener status; pending pairing and incoming file accept/decline; trusted device selection; file picker AND OS drag/drop must choose LAN target or explicit cloud relay, not silently upload. Existing cloud relay remains available under its own name. Outgoing LAN data is an immutable encrypted spool, targeted at one paired device; persist sufficient queue/receipt state for restart, prune abandoned temp data with bounds, never delete delivered files on TTL cleanup. Provide open received folder. No global firewall rules or background service installation.

iOS: nearby peers, validated/pairing/connected states; explicit target/send confirmation; pending offers with accept/decline; persistent received files with Share/Save, not temporary share-sheet ownership. App-level manager owns tasks so navigating away does not destroy them. Backgrounding pauses/cancels network work safely and resumes only in foreground, preserving encrypted partial chunks; no iOS background execution promise. Switching account or key cancels old work with generation guards.

Default transfer policy never silently uploads a LAN task to cloud. On failure offer explicit 'Use cloud relay' and 'Keep for direct transfer'; only the explicit cloud action may invoke /api/relay. For queued LAN data preserve target intent; a legacy upload queue must not accidentally pick it up. UI distinguishes: preparing, waiting acceptance, transferring, paused, peer received, cloud uploaded, exported. Cloud fallback may need full server upload even if receiver already owns some LAN blocks.

No production acceptance or unsigned IPA claim follows from local syntax checks. Test current platform compilation, negative auth cases, tampered/replayed requests, cross-account isolation, chunk ordering/length/digest, interruptions/restarts, no-cloud invariant and foreground/durable receive behavior. iOS Xcode/UI tests require macOS; do not dispatch the manual workflow without an explicit build request.
