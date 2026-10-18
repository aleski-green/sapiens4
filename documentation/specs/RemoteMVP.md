# CORPORA remote control MVP

This opt-in testing implementation connects one browser page to a local Sapiens4
instance. Communication works in both directions. **The local PC is the source of
truth**: agents, chat history, execution and authorization remain local. A relay
stores encrypted messages until the receiver acknowledges them or they expire.
It does not run agents or hold application decryption keys.

The phone opens the same workspace shell used by the local app, with installation
and connection flows before its first CORPORA opens. Sapis, Groups, chat, Work, Notes, settings, attachments and
workspace controls use a shared API dispatcher on the desktop. The browser's API
adapter encrypts requests and decrypts replies, including note images, without a
plaintext API fallback. Pairing grants full CORPORA admin access.

The local PC owns state and performs actions. The relay serves public UI assets
and stores encrypted envelopes only; it does not expose `/api/state` or other
CORPORA data endpoints. Native desktop browser views, screen streaming, multiple phones are outside this MVP. Text file previews work
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
it to the phone or embed it in a URL. Desktop saves it privately in `remote-relay.json` after successful setup, so subsequent invitations need only **Show QR**. It is never returned by the status API or sent to the phone.

1. In local CORPORA, open the hamburger menu's **Remote control**. Enter the relay
   address and provisioning token once, then select **Show QR**. Saved relay settings
   are reused for later invitations. Each corpora trusts one remote device.
2. For file-based setup, the legacy host setup page remains available at
   `http://127.0.0.1:4174/remote/`. Its **Use local test relay** option reads the connection file
   from this checkout's `.sapiens4/relay.connection.json` on the server side;
   the token is never returned to the browser. This shortcut only accepts loopback
   HTTP origins. For a custom database/location or another server, select
   **Import relay connection file**, review the displayed address, then select
   **Show QR**. Manual address/token entry remains available.
   This is a one-time setup on each desktop. Future connections use **Show QR**.
   The QR remains available on this local page until approved, revoked, or expired (three days).
3. On mobile, add the app to the Home Screen and launch its icon before pairing.
   Choose **Connect remote corpora**, then scan/upload the host QR or paste its
   invitation. No CORPORA ID entry is required. For a same-computer browser test use
   `http://127.0.0.1:4180/`. For an actual iPhone, use the HTTPS deployment described below;
   `127.0.0.1` on the phone refers to the phone, not the PC.
4. Compare the eight-letter confirmation code on both screens and select **Approve device** on
   desktop. This binds approval to that exact phone key.
5. CORPORA opens automatically in the paired page. Use its normal Sapi/Group
   navigation, composer, Work, Notes and settings. Wait for desktop confirmation.
   Use host **Revoke access** to disconnect and delete the relay room.

The QR encodes an HTTPS URL with the compact invitation in its fragment (`/#s4.…`).
Fragments are not included in HTTP requests or referrer headers. The phone removes
the fragment from its current history entry immediately, before asynchronous work.
The full link remains a temporary pairing credential: do not share it. QR uploads
accept both links and legacy JSON invitations, always validating the relay origin.

The compact `s4.` code encodes the same invitation as the QR, omitting verbose
field names. This is encoding, not encryption: a fixed shared key would provide
no secrecy. The code contains a temporary invitation secret, never either
device’s private key or the relay provisioning token. Origin, expiry, phone
confirmation-code approval, and encrypted transport checks apply equally to both flows.
Do not share the code publicly.

After approval, the phone stores its device identity and mailbox credential in
origin-scoped IndexedDB, separately for each corpora. Reopening the installed app
restores the last workspace snapshot, draft and layout with **Connecting…** while
authenticating an encrypted `resume` request. The invitation secret is discarded;
the bounded snapshot and device preferences are stored locally. Public shell assets
are cached for offline launch; API responses and credentials never enter that cache.
Closing or backgrounding a page neither pauses execution nor revokes trust. Host
**Revoke access** blocks access immediately. Clearing website data or storage eviction requires
a new pairing. Private browsing may not retain the device.

QR image decoding happens entirely in the phone browser; the uploaded image is never
sent to a server. Camera access is requested only when **Scan QR** is selected;
upload and paste remain available without camera permission.
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
create the pairing QR. Scan it with the iPhone Camera app and open the link;
confirm the matching code on desktop once. The public relay site never displays the provisioning token. Hosted
Sapiens sign-in/automatic account provisioning is not implemented. Desktop and phone both make outbound HTTP(S)
requests, so there is no inbound port or router change on the desktop. Origin
changes require new pairing; QR upload never navigates to an arbitrary encoded URL.

## Deploy this relay on Railway

The root `Dockerfile` packages only the relay and public web assets; it does not
include the local runtime, workspace data, desktop credentials, or Git metadata.
Connect the repository and select the `codex/remote-control-mvp` branch. Railway
automatically detects the Dockerfile. Keep the repository root as the build root.

Before deploying:

1. Attach a persistent volume at `/data`. Start with one service replica; SQLite
   and the in-process delivery notifications are designed for one relay process.
2. Generate a Railway public domain targeting the service's `PORT`. The relay
   reads `RAILWAY_PUBLIC_DOMAIN` to validate the public HTTPS origin. For a custom
   domain, set `SAPIENS_RELAY_ORIGIN=https://your-domain.example` instead.
3. Configure the healthcheck path `/healthz`. It returns only an availability
   result and accepts Railway's healthcheck Host; all other routes retain the
   configured Host/Origin checks.
4. Deploy. If running on Railway without the persistent mount, startup fails
   instead of silently creating an ephemeral mailbox database.
5. Retrieve `/data/relay.connection.json` using Railway's authenticated volume
   file download or SSH tools, and import it in desktop CORPORA. Do not publish
   this file or paste it in build logs. The phone receives its own room credential
   through the QR and never needs the provisioning token.

The database and generated provisioning credential survive redeployments on the
volume. SIGTERM drains socket connections so clients can reconnect. Resource
usage is charged to the selected Railway plan; choose account spending limits
in Railway before expanding traffic. Changing the public origin requires a fresh
pairing. Configure a private backup policy for the volume if retained mailboxes
are important; the local PC remains the source of truth.

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
requires confirmation-code approval before accepting commands. Private keys never
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
- The approved phone key and mailbox credential are stored in origin-scoped
  IndexedDB. They are accessible to same-origin JavaScript, not non-extractable
  hardware keys or Secure Enclave credentials. This supports persistent Safari
  login but does not protect against a compromised relay web host, browser profile,
  or same-origin script. No chat data is persisted by the remote transport.
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
clients. HTTP room creation/revocation and mailbox endpoints remain available.
Desktop delivery uses only the socket loop. Application requests use the shared
CORPORA API; the earlier chat-only `state` and `chat` operations are removed.

The server sends protocol pings every 25 seconds. Clients reconnect with delays
up to 30 seconds (browser adds jitter); the browser keeps a local timer for request
expiry and identical-ciphertext retries. A relay restart preserves paired mailboxes
and queued data. Approved devices remain valid until revoked. Unapproved rooms
expire after seven days; only the desktop bearer can promote a room through
`POST /api/rooms/:id/trust`, immediately before local confirmation-code approval.
Existing pairings created by older clients need one final re-pair after upgrading
both desktop and relay, because those clients did not save the phone key.

A returning browser never replays application commands from an earlier page. It
resumes its authenticated identity and loads a fresh snapshot. Outstanding work
may still have reached the desktop before the previous page closed; check desktop
history before manually repeating an unconfirmed action.

A connection has at most one bounded delivery batch awaiting acknowledgment. The
relay limits live sockets to 128 overall and four per room, disables compression,
and checks mailbox expiry/revocation on open connections. Reverse proxies must
forward WebSocket upgrades and allow idle connections beyond the heartbeat period.
Each mailbox has one active socket consumer. Opening another phone tab replaces
the older socket with close code 4002 without forgetting device credentials; the
old tab reconnects only when foregrounded or brought online, rather than competing
for the same encrypted replies.
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
Unapproved mailboxes expire after seven days; approved mailboxes remain until revoked. Limits are 100
rooms per relay, 100 queued messages / 48 MB per room, 22 MB per incoming frame, and 16 MB
per decrypted message. This accommodates the normal 10 MB attachment limit;
responses exceeding the envelope limit return an explicit error. Fetches contain
at most 20 messages and are bounded by the frame-size budget.
Deployments serving more users need operational review of limits and abuse control.

Local revocation removes the desktop credential immediately and attempts to delete
the mailbox, even if the relay is unavailable. Offline relay cleanup may wait for
expiry. Already received plaintext cannot be recalled. Disconnecting the phone
page clears its remembered and in-memory key but does not remotely revoke desktop authorization.
Existing desktop HTTP remains loopback-only with its original Host/Origin guards;
remote requests dispatch to the same explicit service operations instead of
proxying arbitrary URLs. Pairing/revocation endpoints and native browser event
reporting remain desktop-only.

## Development and validation

```sh
bundle install
python3 -m pip install -r spec/requirements.txt
npm ci --prefix tests --ignore-scripts
node tests/build_remote.cjs
bundle exec rspec spec/remote_spec.rb spec/platform_spec.rb
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

### CORPORA identity

Each data directory has a permanent UUID `corpora_id` in `corpora-identity.json`.
It survives restarts, code updates, relay invitations and device revocation; include
it in backups and migrations. Independent new data directories receive different
IDs. Copying a complete backup preserves the identity; it does not create a new
account or synchronize two concurrently running copies.

The local snapshot and encrypted pair/resume response expose the corpora ID, name,
device, scope, execution status, revision and ChiefSapi ID. Approved browser credentials retain
this ID, and subsequent requests include it inside the encrypted envelope. Both
ends reject a mismatched identity. The ID is a public identifier, never a password
or authorization credential; the approved device key remains the authority.
Legacy saved device credentials bind to the first authenticated identity returned
by their existing desktop key. Update the desktop before using this client; an
older desktop that returns no identity cannot open the workspace.

The corpora menu switches between remembered connections and remains open while
the selected workspace comes forward. Switching pauses the previous corpora before
activating the target. An unreachable host preserves the previous selection;
uncertain lifecycle writes are reconciled without replaying them. Archived corpora
are paused and hidden by default. Editing opens a prefilled message to its ChiefSapi.
Mobile and Linux offer remote corpora only; native macOS/Windows also create local
corpora with separate data directories. Hosted account recovery, multi-host
synchronization and ownership transfer remain outside this implementation.

### Installed remote web apps

The shared web app works in browsers and installed app windows. Use the relay's
HTTPS domain with the entry point for your device:

| Device | Entry point | Installation |
| --- | --- | --- |
| iPhone / iPad | `/ios` | Safari → Share → Add to Home Screen |
| Android | `/android` | Chrome → menu → Install and create shortcut (or Add to Home screen) → Install |
| macOS | `/mac` | Safari → File → Add to Dock, or Chrome's Install icon |
| Windows | `/windows` | Chrome or Edge's Install icon |

Trailing slashes are supported; `/` detects the device for installation guidance.
Each platform page links to a manifest whose start URL preserves that entry point.
An HTTPS redirect can forward these paths to the relay's existing HTTPS hostname.
The browser and installed app then use the destination origin; the redirect does
not require adding a custom domain to Railway or transferring existing trust.

Assets and API routes remain rooted at the origin. Hosting the app itself on a
custom hostname needs Railway domain verification and DNS records,
then `SAPIENS_RELAY_ORIGIN` set to that HTTPS origin (without `/ios`). Import the
updated private relay connection file and pair again after changing hostnames;
browser trust does not transfer across origins.

The relay serves a standalone web app manifest and 180/192/512-pixel icons derived
from the existing workspace favicon in `web/shell/bootstrap.js`. The **Add to Home
Screen** card opens the browser's installation prompt when available, otherwise a
three-page guide. In Safari, use Share (inside the page menu in the compact layout), choose
**Add to Home Screen**, leave **Open as Web App** on, and tap **Add**. The app opens
in its own window, with safe-area spacing and no further installation prompt.

On touch devices, portrait keeps exactly one panel selected; landscape allows up
to two side by side. Opening a third replaces the least recently selected panel.
Rotation retains the most recent visible selection, and opening a Sapi or browser
tab follows the same limits. The software keyboard does not change the phone's
orientation mode. Narrow non-touch windows also use the compact panel controls;
ordinary desktop windows retain independent toggles for all three panels.

Mobile pairing requires installation first: open the Home Screen app, choose
**Connect remote corpora**, scan/upload the host QR or paste its invitation, and
approve the matching code once. Safari and the installed
app have separate IndexedDB storage; existing Safari approval does not transfer.
Use host **Replace device** to replace an existing browser approval under the
one-device-per-corpora limit. Afterwards, the same
trusted-device reconnect and revocation rules apply.

The saved workspace can be viewed while reconnecting, but live actions require
the relay and host to be reachable. There is no App Store distribution. The manifest's start URL matches
the entry point (`/`, `/ios`, `/android`, `/mac`, or `/windows`); it never contains
an invitation, private key, or bearer token. All manifests retain the same app ID
and scope, so these are entry points to one app, not separate installations.
Credentials are not copied to cookies or other installation metadata.

### Public CORPORA addresses and QR pairing

The stable public address is `sapi4_` plus three lowercase letters, three digits and three lowercase letters derived from the
existing immutable UUID. It is an address, not a login secret. The relay registers
it only through authenticated provisioning, rejects collisions with another UUID,
and keeps the reservation across revocation. `/api/corpora/<address>` exposes only
the address, invited desktop public key and QR expiry while an invitation is active.
It never returns mailbox credentials, the QR secret, workspace names or content.
The app verifies the scanned/uploaded QR against its public address and desktop
key, then requires the existing explicit desktop approval. Legacy QR links remain
readable. New invitations expire in 72 hours; approved device trust does not.

The unapproved invitation is retained only in the desktop’s private mode-0600
configuration so reopening Connect phone can redraw its QR. Approval removes that
invitation and closes public discovery. Camera images are decoded locally; streams
stop on cancellation, successful decoding, backgrounding and page exit. Pairing
loads the same CORPORA theme files and preference handler as the workspace.

The comparison code uses eight mixed-case letters in two groups of four, excluding
ambiguous `I`, `L`, `O`, `i`, `l`, and `o`. Both endpoints derive it from a
domain-separated SHA-256 hash of the invitation room and the ordered desktop/phone
public keys. It is a short human comparison (about 44 bits), not an authentication
credential or replacement encryption key. Approval still submits and checks the
full phone public key; existing approved connections are unchanged.
