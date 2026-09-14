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
ssh://<host><absolute-posix-path>[/][:line[:col]]
```

- `<host>` is an alias from the workstation's Zed `ssh_connections`, not a real
  hostname. Zed resolves it against that config.
- The path is absolute and POSIX-style; it belongs to the dev box, not the
  workstation.
- A **trailing `/` means the path is a directory**, and its absence means the path
  is a file. See below.
- `line` and `col` are optional decimal positions, and only a file carries them.

Examples:

```
ssh://desktop/home/kpreston/Code/salsa/release-next/
ssh://desktop/home/kpreston/Code/dotfiles/README.md
ssh://desktop/home/kpreston/Code/dotfiles/README.md:42
ssh://desktop/home/kpreston/Code/dotfiles/README.md:42:7
```

## Directory or file

Only the sender can tell the two apart: the path is on the dev box, so the sender
stats it and the listener has nothing to stat. Yet the listener is the side that
has to know, because a directory and a file want opposite window placement — a
directory may join the window as another project, and a file must be opened
*into* whichever project already holds it. Guessing from the path is hopeless: an
extension is not a file and its absence is not a directory.

So the sender states it, using the one character POSIX already spends on this
distinction. A directory is sent with a trailing `/` and a file without one. The
sender resolves the path before deciding, so the marker describes what is really
there rather than how it was typed.

The trailing `/` is for the listener alone, and does not go any further: a
listener strips it before handing the path to Zed, so Zed receives exactly the
path it would have received before this marker existed, and its workspace
database keeps storing project roots unslashed. That matters because the listener
compares those stored roots against the requested path to decide placement.

A request for `/` is the one path whose slash is structural rather than a marker.
It is a directory either way, so nothing special is needed to read it.

## Handling

The listener passes the URL to the local Zed CLI as a single argument:

```
zed <url>
```

Zed parses the `:line:col` suffix itself; the listener must not split it off.

A listener may add flags of its own to decide which window the project lands in —
both listeners here pass `--reuse` to keep projects together. Those are literals
it chooses for itself: the URL is still one argv entry, and nothing in a request
can become a flag.

`--reuse` is for directories only. It sets Zed's workspace matching to `None`,
which switches off the search for a project already holding the path, and names a
window to open in. For a file that is destructive: instead of opening a tab in the
project the file belongs to, Zed builds a workspace whose only root is that one
file and shows it where the project was.

## Requirements on the listener

Anything running as the workstation user can reach the port, so a request is
untrusted input even though it arrives on loopback.

- Bind loopback only. Never `0.0.0.0`.
- Validate the URL against a strict allowlist pattern before use. Reject anything
  that is not an `ssh://` URL of the shape above.
- Treat a missing trailing `/` as a file. A sender too old to send the marker then
  reads as all files, which costs a window per project but opens everything in the
  right place; reading an unmarked path as a directory would `--reuse` files and
  replace the open project instead.
- Pass the URL as one argv entry. Never interpolate it into a shell command
  string.
- Cap the request size and time out slow senders.
- A rejected request, a timeout, or a failed launch is logged and the accept loop
  continues. One bad request must never stop the service.
