# Proposal: CORPORA remote control from iPhone

Status: proposed; documentation only. This document does not enable remote access.

## Goal and user experience

An administrator opens Sapiens Remote in an iPhone browser, scans a pairing QR
shown by their local Sapiens4 desktop app, and uses a mobile CORPORA interface to
control that same running instance. Desktop remains the authority for data and
execution. The phone is an additional admin client, not another agent runtime.

1. On desktop, the admin selects **Connect phone** and sees an expiring QR.
2. On the phone, the HTTPS remote page offers **Scan desktop QR** and requests
   camera permission. An invalid, expired, or consumed QR produces a retry screen.
3. After the authenticated pairing handshake, desktop shows a pending phone and
   asks the admin to approve access. Both clients show the desktop identity and
   a matching verification value derived from the handshake.
4. The phone opens mobile CORPORA. **Remember this iPhone** is an explicit option;
   otherwise the pairing credential is held only for the current page lifetime.
5. Desktop lists paired phones and offers **Revoke** and **Disable remote access**.
   The phone offers **Forget this desktop**, deleting its saved credential and
   requesting revocation when connected. If offline, deletion is local only;
   desktop revocation remains available.

Proposed initial surface: agent/group navigation, chat history and message
submission, tasks/routines, and notes. Each feature uses an explicit remote
operation allowlist. Native desktop settings, arbitrary filesystem access, and
raw computer-control forwarding need separate review before inclusion. The
long-term goal is mobile admin parity with CORPORA, implemented incrementally.

## Architecture and integration

The design has three responsibilities, following CONTRIBUTING.md:

- **Pairing and device authorization:** desktop identity, one-time invitations,
  approved phone identities, expiry, revocation, and permission checks.
- **Encrypted transport:** authenticated connections, relay routing, session keys,
  bounded messages, replay protection, reconnect, and request deduplication.
- **Mobile presentation:** responsive CORPORA views, scanning, connection status,
  and the existing admin workflows through an authenticated transport adapter.

These are responsibility boundaries, not a request to create speculative package
scaffolding. Host integration belongs under `sapiens/corpora/host/`; presentation
belongs within `web/`'s existing shell/features/theme structure. Runtime remains
independent of CORPORA and desktop code. Desktop pairing UI can use the existing
local host interface; native integration belongs in `macos/` where needed.

Today `sapiens/corpora/host/server.py` binds to `127.0.0.1` and enforces loopback
Host and same-origin checks. Preserve those checks. Do not publish port 4174,
change the bind address, or treat the `X-Sapiens-Local` header as remote auth.
The authenticated remote adapter invokes explicitly permitted service operations
with the paired device's authorization context and existing validation/locking.
It is not an arbitrary HTTP proxy into the local API.

Proposed network topology: desktop and phone each open an outbound TLS connection
to a relay. This supports separate networks without router configuration. The
relay routes opaque encrypted frames; it cannot grant admin access or decrypt
application payloads. A relay outage affects availability, not local CORPORA.
Remote access is disabled by default and starts only after desktop opt-in.

## Pairing and encryption

The QR establishes trust; it is not a permanent master key used for every message.
Use a cryptographically random, single-use pairing secret (proposed 256 bits), an
invitation identifier, desktop identity/fingerprint, protocol version, and a
validated relay identifier. Proposed invitation lifetime: two minutes. Consume
it atomically after a successful authenticated pairing; cancelled or expired
invitations cannot authorize a device. Rate-limit attempts and pending sessions.

Use a reviewed protocol/library for an authenticated key exchange with forward
secrecy, binding the QR secret, desktop identity, phone identity, protocol version,
and handshake transcript. The exact protocol, cipher suite, and interoperable
Python/browser library are implementation decisions requiring review before code
ships. Do not assemble a new protocol from raw Web Crypto primitives.

After approval, retain an independently revocable identity for this phone and
remove the invitation secret. Authenticate subsequent connections against the
approved device record and desktop identity, deriving fresh traffic keys for
each session. An unknown or changed desktop identity requires explicit re-pairing.
Separate directional keys, nonce rules, session identifiers, authenticated
sequence numbers, and replay rejection must be defined by the selected protocol.
Never reuse a nonce with the same key or resume a lost session's counters blindly.

Encrypt and authenticate all remote application payloads end to end: snapshots,
chat and notes content, commands, responses, errors, and any later attachments.
Encryption terminates only at desktop and phone. TLS remains required for the
web page and both relay connections. The relay may observe IP addresses, routing
identifiers, timing, and message sizes; this proposal does not hide metadata.
Encryption in transit does not encrypt the existing desktop SQLite database or
files at rest. Any future offline phone cache must be encrypted separately;
initially persist no CORPORA content on the phone.

Secrets must not appear in query strings, access logs, analytics, crash reports,
or relay-readable messages. Prefer scanning the QR inside the remote page so its
secret never enters browser history. Validate the QR schema and supported relay
configuration; scanning must not navigate to arbitrary QR-supplied sites.

## iPhone key storage and trust limits

Use Web Crypto keys rather than plaintext secrets in localStorage/sessionStorage.
For remembered pairing, store the phone's private credential as a non-extractable
CryptoKey in IndexedDB, where supported by the chosen protocol and actual Safari
version. Keep active session keys in memory. Verify key serialization, reload,
and protocol-library interoperability on real iPhones before promising persistence.
If secure persistence is unavailable, offer temporary pairing and re-scan instead
of silently falling back to an exportable plaintext credential.

Non-extractable prevents JavaScript from directly exporting key bytes. It does
not prevent malicious same-origin JavaScript from using the key to issue commands
or decrypt data, and does not promise hardware-backed or Secure Enclave storage.
The remote web app's hosting/deployment and every script it executes are trusted
components. End-to-end encryption protects against a relay reading traffic, but
cannot protect against a compromised frontend serving hostile JavaScript.

Use a dedicated HTTPS origin, a restrictive Content Security Policy, no third-party
analytics/scripts, and safe rendering for chats, notes, and generated content.
Treat generated HTML as untrusted; it must not execute with access to pairing
credentials. Review existing CORPORA rendering boundaries before reusing views.
Automatic reconnect grants access to anyone able to use that remembered browser
profile; an additional user-verification/unlock mechanism is a separate design
choice, not a guarantee provided by IndexedDB.

Safari may suspend/discard pages or evict storage, and users can clear site data.
A reopened page must re-authenticate or request a new scan. Lost phone credentials
must not lose desktop data. Adding the page to the Home Screen is optional and
must not be required for correctness or treated as stronger key protection.

## Authorization, reconnect, and lifecycle

Desktop owns the device registry and checks authorization before every operation.
Revocation immediately closes active sessions and rejects further handshakes and
commands for that device. Disabling remote access disconnects all phones. Revoked
phones may retain previously viewed plaintext; revocation cannot erase that data.
Do not store long-lived desktop credentials in application logs or unprotected
configuration; select an OS-protected credential store during implementation.

The phone shows connecting, connected, reconnecting, offline, and revoked states.
After backgrounding, establish a fresh authenticated session and fetch current
state. Do not silently replay queued admin actions. Assign command request IDs and
implement bounded deduplication at desktop for retries; after ambiguous failures,
show status reconciliation rather than issuing a potentially duplicate action.

Bound frame sizes, queues, timeouts, and concurrent sessions. Unknown operations,
malformed frames, unsupported versions, and unauthenticated traffic fail closed.
Record device ID, operation type, time, and outcome for admin audit without
recording keys or message content. Revoke/disable must remain available locally
when the relay or phone is unreachable.

## Delivery and acceptance

1. **Pairing foundation:** choose and review the protocol/library and relay model;
   implement QR lifecycle, desktop approval, device storage, and revocation.
2. **Transport integration:** implement the allowlisted host adapter, encrypted
   state/command exchange, authorization, limits, replay rejection, and reconnect.
3. **Mobile workflows:** adapt the initial CORPORA views, add scan/remember/forget
   flows, and verify behaviour on physical iPhones before broader admin parity.

Required validation before enabling the feature:

- Pair on a real iPhone over both the same Wi-Fi and a separate cellular network.
- Reject expired/reused QR codes, identity substitution, modified ciphertext,
  replayed frames, unauthorized operations, and revoked devices.
- Verify a relay capture contains no application plaintext or pairing secret;
  document visible metadata. Confirm secrets are absent from logs and URLs.
- Test Safari reload, tab discard, background/foreground, private browsing,
  cleared/evicted storage, Home Screen mode, and non-extractable-key persistence.
- Test connection loss during a command, deduplication, state reconciliation,
  relay failure, desktop restart, revocation during a session, and disabling access.
- Test hostile chat/notes/generated HTML against the remote origin and key store.
- Confirm existing local UI, CLI, loopback protections, and architecture tests
  continue to pass; remote access stays off on installations that never opt in.

Open decisions for the implementation PR: protocol/library and cipher suite;
relay hosting and deployment trust; exact initial operation allowlist; desktop
credential store; and whether remembered admin access requires user verification.
This proposal intentionally leaves these review gates explicit instead of
claiming a complete cryptographic specification.

## References

- [Web Crypto key storage and security considerations](https://w3c.github.io/webcrypto/#security-considerations)
- [WebKit website storage policy](https://webkit.org/blog/14403/updates-to-storage-policy/)
- [OWASP HTML5 storage guidance](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)
