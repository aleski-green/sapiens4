# CORPORA remote control MVP

This opt-in testing implementation connects one browser page to a local Sapiens4
instance. Communication works in both directions. **The local PC is the source of
truth**: agents, chat history, execution and authorization remain local. A relay
stores encrypted messages until the receiver acknowledges them or they expire.
It does not run agents or hold application decryption keys.

The initial remote UI lists Sapis, shows their eight most recent chat turns, and
sends text messages through the existing local chat path. Agent replies appear
when the phone refreshes its encrypted snapshot. Groups, attachments, notes,
computer controls, persistent phone login, and multiple phones are not included.
Chat messages can still instruct agents to act, so pairing grants meaningful
admin access and requires explicit approval on desktop.

## Run locally for testing

Use Python 3.9+ and an existing Sapiens4 checkout with its usual runtime setup.
Install the optional desktop cryptography dependency into the Python environment
used to start Sapiens4:

```sh
python3 -m pip install -r sapiens/corpora/host/remote-requirements.txt
python3 -m sapiens --port 4174 --open
```

In another terminal, choose a strong random provisioning token (at least 32 ASCII
characters), keep it private, and start the relay:

```sh
export SAPIENS_RELAY_ADMIN_TOKEN="YOUR_RANDOM_PROVISIONING_TOKEN"
python3 -m sapiens.corpora.host.remote_relay \
  --origin http://127.0.0.1:4180 --port 4180 \
  --db .sapiens4/relay.sqlite3
```

The relay itself uses only the Python standard library; it does not need a running
Sapiens runtime or the optional PyNaCl package. Assets are included in the checkout.
The provisioning token only authorizes creation of bounded mailboxes. Never give
it to the phone or embed it in a URL. The desktop does not persist it.

1. In local CORPORA, open **Connect phone**, or visit
   `http://127.0.0.1:4174/remote/` in your desktop browser.
2. Enter `http://127.0.0.1:4180` and the provisioning token. Create the QR and save
   its PNG image. The invitation expires after two minutes.
3. For a same-computer browser test, open `http://127.0.0.1:4180/` and upload the
   image. For an actual iPhone, use the HTTPS deployment described below;
   `127.0.0.1` on the phone refers to the phone, not the PC.
4. Compare the phone fingerprint on both screens and select **Approve phone** on
   desktop. This binds approval to that exact phone key.
5. Read a Sapi's chat, send a text message, and wait for desktop confirmation.
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

Enter that HTTPS origin in the desktop pairing page, then open the same origin
on the iPhone and upload the QR PNG. Desktop and phone both make outbound HTTP(S)
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
scripts or analytics are loaded, and chat is rendered as text.

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

Both endpoints poll the relay approximately every two seconds. Phone requests a
fresh snapshot about every five seconds. Commands expire after two minutes;
unexpired queued commands execute when desktop reconnects. The UI says this
explicitly. After a missing confirmation, inspect desktop history before manually
sending the same instruction again.

Retries preserve the exact request ID and ciphertext. Desktop writes a durable
receipt before executing a command and caches the encrypted response. A duplicate
request returns the saved response without repeating the operation. If the process
crashes between recording intent and recording the outcome, retries report an
uncertain outcome instead of re-executing. This is deliberately not a guarantee
of exactly-once completion. Local receipts outlive the request replay window.

The receiver acknowledges each fetched relay message. Ciphertext expires after
24 hours, with an automatic sweep at least every minute while the relay runs.
Mailbox credentials expire after seven days; re-pair afterwards. Limits are 100
rooms per relay, 100 queued messages / 8 MB per room, and 512 KB per incoming frame.
Deployments serving more users need operational review of limits and abuse control.

Local revocation removes the desktop credential immediately and attempts to delete
the mailbox, even if the relay is unavailable. Offline relay cleanup may wait for
expiry. Already received plaintext cannot be recalled. Disconnecting the phone
page clears its volatile key but does not remotely revoke desktop authorization.
Existing desktop HTTP remains loopback-only with its original Host/Origin guards;
there is no generic remote proxy to local endpoints.

## Development and validation

```sh
python3 -m pip install -r tests/requirements.txt
npm ci --prefix tests
node tests/build_remote.cjs
python3 -m unittest discover -s tests -p test_remote.py -v
node tests/remote.test.cjs
```

The vendor bundle is checked in so users do not need Node to run the relay. Rebuild
it with the pinned dependencies in `tests/package-lock.json`; dependency licenses
are recorded in `license/REMOTE_DEPENDENCIES.txt`.

Tests cover real QR generation/decoding, upload-driven browser pairing, safe chat
rendering, Python/JavaScript crypto interoperability, HTTP pairing/approval,
reverse delivery, ciphertext-only relay persistence, tampering, expiry, bearer
access, host/origin checks, revocation, and durable deduplication. Physical iPhone
Safari testing and an external HTTPS deployment are still required before calling
this ready for general use.
