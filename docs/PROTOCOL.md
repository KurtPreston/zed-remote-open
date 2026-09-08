# Wire protocol

This is the contract between the sender on the dev box
([`remote/bin/zed`](../remote/bin/zed)) and the listener on the workstation. It is
deliberately tiny. Any platform-specific listener in this repo must implement
exactly this, and must not extend it — changing the wire format means changing
every side at once.

## Transport

The sender opens a TCP connection to `127.0.0.1:7682` on its **own** loopback.
SSH forwards that to `127.0.0.1:7682` on the workstation via a reverse forward
(`-R 7682:127.0.0.1:7682`), so the listener only ever sees loopback traffic.

## Framing

One connection carries exactly one request:

1. The sender writes a single URL terminated by `\n`.
2. The sender closes its end immediately.
3. The sender does **not** read a response.

A listener therefore must not write anything back. Treat EOF without a trailing
newline as a complete request, since the close may arrive coalesced with the data.

## URL shape

```
ssh://<host><absolute-posix-path>[:line[:col]]
```

- `<host>` is an alias from the workstation's Zed `ssh_connections`, not a real
  hostname. Zed resolves it against that config.
- The path is absolute and POSIX-style; it belongs to the dev box, not the
  workstation.
- `line` and `col` are optional decimal positions.

Examples:

```
ssh://desktop/home/kpreston/Code/salsa/release-next
ssh://desktop/home/kpreston/Code/dotfiles/README.md
ssh://desktop/home/kpreston/Code/dotfiles/README.md:42
ssh://desktop/home/kpreston/Code/dotfiles/README.md:42:7
```

## Handling

The listener passes the URL to the local Zed CLI as a single argument:

```
zed <url>
```

Zed parses the `:line:col` suffix itself; the listener must not split it off.

## Requirements on the listener

Anything running as the workstation user can reach the port, so a request is
untrusted input even though it arrives on loopback.

- Bind loopback only. Never `0.0.0.0`.
- Validate the URL against a strict allowlist pattern before use. Reject anything
  that is not an `ssh://` URL of the shape above.
- Pass the URL as one argv entry. Never interpolate it into a shell command
  string.
- Cap the request size and time out slow senders.
- A rejected request, a timeout, or a failed launch is logged and the accept loop
  continues. One bad request must never stop the service.
