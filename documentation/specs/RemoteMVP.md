# CORPORA remote control MVP

This opt-in testing implementation connects one browser page to a local Sapiens4
instance. Communication works in both directions. **The local PC is the source of
truth**: agents, chat history, execution and authorization remain local. A relay
stores encrypted messages until the receiver acknowledges them or they expire.
It does not run agents or hold application decryption keys.

After QR approval, the phone mounts the same CORPORA HTML, JavaScript, and styles
used by the local app. Sapis, Groups, chat, Work, Notes, settings, attachments and
workspace controls use a shared API dispatcher on the desktop. The browser's API
adapter encrypts requests and decrypts replies, including note images, without a
plaintext API fallback. Pairing grants full CORPORA admin access.

The local PC owns state and performs actions. The relay serves public UI assets
and stores encrypted envelopes only; it does not expose `/api/state` or other
CORPORA data endpoints. Native desktop browser views, screen streaming, persistent
phone login, and multiple phones are outside this MVP. Text file previews work
through the existing browser fallback. Remote control of existing workspace tabs
still runs on the desktop.

## Run locally for testing

Use Python 3.9+ and an existing Sapiens4 checkout with its usual runtime setup.
Install the optional remote dependencies into the Python environment
used to start Sapiens4:

```sh
python3 -m pip install -r sapiens/corpora/host/remote-requirements.txt
python3 -m sapiens --port 4174 --open
```

In another terminal, start the relay. No token needs to be invented or copied:

```sh
python3 -m sapiens.corpora.host.remote_relay \
  --origin http://127.0.0.1:4180 --port 4180 \
  --db .sapiens4/relay.sqlite3
```

The relay uses aiohttp for HTTP and WebSockets. The desktop uses websocket-client
and PyNaCl. Installing the remote requirements on both machines supplies these
dependencies. The relay does not need a running Sapiens runtime. Assets are included
in the checkout.
On first launch the relay generates a random provisioning token and writes a private
`relay.connection.json` beside its database (0600 on POSIX). It prints the file's
location, never its contents. Subsequent launches reuse the token. An explicit
`SAPIENS_RELAY_ADMIN_TOKEN` overrides/rotates it; `--connection-file` selects a
custom destination. Keep that file private and transfer it securely to the desktop
owner. It is never served over HTTP. Windows requires a private directory/ACL.
The token authorizes mailbox creation; it is not an encryption key. Never give
it to the phone or embed it in a URL. Desktop pairing does not persist it.

1. In local CORPORA, open **Connect phone**, or visit
   `http://127.0.0.1:4174/remote/` in your desktop browser.
2. Select **Use local test relay**. CORPORA reads the default connection file
   from this checkout's `.sapiens4/relay.connection.json` on the server side;
   the token is never returned to the browser. This shortcut only accepts loopback
   HTTP origins. For a custom database/location or another server, select
   **Import relay connection file**, review the displayed address, then select
   **Create pairing QR**. Manual address/token entry remains available.
   Save the QR PNG; the invitation expires after two minutes.
3. For a same-computer browser test, open `http://127.0.0.1:4180/` and upload the
   image. For an actual iPhone, use the HTTPS deployment described below;
   `127.0.0.1` on the phone refers to the phone, not the PC.
4. Compare the phone fingerprint on both screens and select **Approve phone** on
   desktop. This binds approval to that exact phone key.
5. CORPORA opens automatically in the paired page. Use its normal Sapi/Group
   navigation, composer, Work, Notes and settings. Wait for desktop confirmation.
   Use **Revoke / disable remote access** to disconnect and delete the relay room.

QR decoding happens entirely in the phone browser; the uploaded image is never
sent to a server. There is no camera permission or native QR-scanner dependency.
The QR grants a one-time pairing opportunity, so treat its image as a temporary
credential and delete it after use.

## Self-hosting and real iPhone testing

Deploy this same checkout on a server you control, serving the relay and remote
web app from one HTTPS origin. No project-operated account or server is required.
An official hosted service could run this same relay; this branch does not deploy
`remote.sapiens4.ai` or provision a public service.

For example, run the relay on loopback with
`--origin https://remote.example.com --port 4180` and put an HTTPS reverse proxy in
front of it. A minimal Caddy site is:

```caddyfile
remote.example.com {
    reverse_proxy 127.0.0.1:4180
}
```

Configure DNS/certificates, request and connection rate limits, a private service
account, filesystem permissions, a restart policy, and OS/application updates.
The bundled HTTP server is an MVP backend, not a production internet edge. Keep
its port private behind the proxy. The proxy must preserve the public Host header;
requests with a different Host or Origin are rejected. Redact authorization headers
and request bodies from proxy logs. Keep the provisioning token in protected
service configuration and rotate it when needed.

Retrieve `relay.connection.json` from your server using your normal secure file
transfer method. In desktop CORPORA, select **Import relay connection file** and
create the pairing QR. Open the configured HTTPS origin on the iPhone and upload
the QR PNG. The public relay site never displays the provisioning token. Hosted
Sapiens sign-in/automatic account provisioning is not implemented. Desktop and phone both make outbound HTTP(S)
requests, so there is no inbound port or router change on the desktop. Origin
changes require new pairing; QR upload never navigates to an arbitrary encoded URL.

## Encryption and storage boundaries

The implementation has three local responsibilities:

- `remote_pairing.py`: NaCl authenticated boxes, key and payload validation.
- `remote_relay.py`: bounded opaque mailboxes, bearer authorization, static mobile assets.
- `remote_bridge.py`: local approval/revocation, replay ledger, allowlisted service operations.

Python PyNaCl and browser TweetNaCl implement compatible NaCl `crypto_box`
(X25519 / XSalsa20-Poly1305). Sender uses its private key and the receiver's public
key; receiver uses its own private key and the sender's public key. Every frame
uses a fresh random 24-byte nonce. The encrypted body binds protocol version,
room, direction, request ID, kind, and expiry. Wrong keys, modified ciphertext,
wrong room/direction, and expired messages are rejected before any operation runs.

The QR carries the desktop public key, a random invitation secret, mailbox
address/access token, and expiry. Phone generates a private key locally and sends
its public key with an encrypted pairing proof. Desktop verifies the secret and
requires fingerprint approval before accepting commands. Private keys never
appear in the QR or travel to the relay. The invitation is consumed on approval.

The relay stores public sender keys, nonces, ciphertext, routing IDs and expiry.
Mailbox bearer tokens are hashed in its database. It can observe traffic metadata,
drop traffic, or deny service, but cannot decrypt application content. The mobile
web app's host remains trusted: hostile JavaScript served by that host could use
phone keys or read decrypted content. Self-hosting both components lets users
choose that trust boundary. Dependencies are bundled on the same origin; no CDN
scripts or analytics are loaded. The existing CORPORA rendering and Notes sanitization
are reused. Inline CSS is allowed for the shared UI; inline scripts are blocked.

### Explicit testing limitations

- This is an application integration using established NaCl primitives, not an
  independently audited messaging protocol. **There is no forward secrecy or key
  ratchet**: a later stolen device private key can expose retained ciphertext.
- Phone key is an in-memory JavaScript byte array, not a non-extractable hardware
  key. No private key or chat data is written to browser storage. Reloading or an
  iOS page discard loses the key: revoke on desktop and pair again. This MVP does
  not claim persistent Safari login or Secure Enclave protection.
- Desktop keeps its key and mailbox credential in `remote-device.json` under its
  existing data directory, created atomically with mode 0600 on POSIX. Windows
  needs a private per-user data directory/ACL. This is not an OS keychain-backed
  credential store. Desktop data, backups, and the local replay ledger are not
  encrypted by this feature; the encryption boundary is the remote transport.
- A page can display a last-received snapshot while desktop is offline; desktop
  must be running to execute commands or supply new state. There is no persistent
  offline mobile cache or indefinite chat history on the relay.

## Delivery, expiry, and failure semantics

Both endpoints maintain a WebSocket connection at `/api/socket` (`wss://` over
HTTPS). Mailbox credentials travel in the first socket message, never query
parameters. Host and Origin checks apply before upgrade; authentication must finish
within ten seconds. The relay commits ciphertext to SQLite before confirming a
send, then pushes it to the recipient. Acknowledgments delete delivered frames;
unacknowledged frames replay on reconnect. No idle mailbox polling is used by the
new clients. HTTP room creation/revocation and legacy mailbox endpoints remain
available for compatibility.

The server sends protocol pings every 25 seconds. Clients reconnect with delays
up to 30 seconds (browser adds jitter); the browser keeps a local timer for request
expiry and identical-ciphertext retries. A relay restart preserves paired mailboxes
and queued data. Existing browser pages must reload once to load this transport;
that loses their volatile key, so revoke and pair again.

A connection has at most one bounded delivery batch awaiting acknowledgment. The
relay limits live sockets to 128 overall and four per room, disables compression,
and checks mailbox expiry/revocation on open connections. Reverse proxies must
forward WebSocket upgrades and allow idle connections beyond the heartbeat period.
The bundled Caddy reverse proxy configuration supports upgrades automatically.

The shared CORPORA UI still requests a fresh encrypted snapshot two seconds after
its previous refresh completes, now over the socket. This transport change removes
HTTP mailbox polling; it does not implement desktop state-change subscriptions. Commands expire after two minutes;
unexpired queued commands execute when desktop reconnects. An unanswered request reports an uncertain outcome after expiry. After a missing confirmation, inspect desktop history before manually
sending the same instruction again.

Retries preserve the exact request ID and ciphertext. Desktop writes a durable
receipt before executing a command and caches the encrypted response. A duplicate
request returns the saved response without repeating the operation. If the process
crashes between recording intent and recording the outcome, retries report an
uncertain outcome instead of re-executing. This is deliberately not a guarantee
of exactly-once completion. Local receipts outlive the request replay window. Read-only API requests can be
repeated safely and do not write snapshots into the replay ledger.

The receiver acknowledges each fetched relay message. Ciphertext expires after
24 hours, with an automatic sweep at least every minute while the relay runs.
Mailbox credentials expire after seven days; re-pair afterwards. Limits are 100
rooms per relay, 100 queued messages / 48 MB per room, 22 MB per incoming frame, and 16 MB
per decrypted message. This accommodates the normal 10 MB attachment limit;
responses exceeding the envelope limit return an explicit error. Fetches contain
at most 20 messages and are bounded by the frame-size budget.
Deployments serving more users need operational review of limits and abuse control.

Local revocation removes the desktop credential immediately and attempts to delete
the mailbox, even if the relay is unavailable. Offline relay cleanup may wait for
expiry. Already received plaintext cannot be recalled. Disconnecting the phone
page clears its volatile key but does not remotely revoke desktop authorization.
Existing desktop HTTP remains loopback-only with its original Host/Origin guards;
remote requests dispatch to the same explicit service operations instead of
proxying arbitrary URLs. Pairing/revocation endpoints and native browser event
reporting remain desktop-only.

## Development and validation

```sh
python3 -m pip install -r tests/requirements.txt
npm ci --prefix tests
node tests/build_remote.cjs
python3 -m unittest discover -s tests -p test_remote.py -v
node tests/remote.test.cjs
node tests/remote-desktop.test.cjs
```

The vendor bundle is checked in so users do not need Node to run the relay. Rebuild
it with the pinned dependencies in `tests/package-lock.json`; dependency licenses
are recorded in `license/REMOTE_DEPENDENCIES.txt`.

Tests cover real QR generation/decoding, upload-driven browser pairing, shared CORPORA mounting, encrypted API and image
responses, route restrictions, Python/JavaScript crypto interoperability, HTTP pairing/approval,
reverse delivery, ciphertext-only relay persistence, tampering, expiry, bearer
access, host/origin checks, revocation, and durable deduplication. Physical iPhone
Safari testing and an external HTTPS deployment are still required before calling
this ready for general use.
