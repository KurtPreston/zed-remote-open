# zed-remote-open

Open a Zed workspace on your local machine by running `zed .` in a shell on a
remote dev box.

Zed's remote SSH support has no CLI on the remote side — its docs list "You can't
open files from the remote Terminal by typing the `zed` command" as a known
limitation. This repo is the workaround: a sender on the dev box writes an
`ssh://` URL to a reverse SSH tunnel, and a listener on the workstation hands that
URL to the local Zed, which already knows how to open remote paths.

```
dev box                          │ workstation
                                 │
zed .                            │
  └─ writes ssh://desktop/path ──┼──▶ 127.0.0.1:7682 (listener)
     to 127.0.0.1:7682           │        └─ zed ssh://desktop/path
                                 │              └─ Zed opens the remote workspace
        ── reverse SSH tunnel ───┤
```

The wire format is specified in [docs/PROTOCOL.md](docs/PROTOCOL.md) and is fixed.

Both sides live here: `remote/` is the sender for the dev box, and each
workstation platform gets its own listener.

## Status

| Side | Status |
| --- | --- |
| Dev box sender | `remote/` — bash sender + symlink installer |
| Windows listener | `windows/` — PowerShell listener + Scheduled Task installer |
| macOS listener | not yet |
| Linux listener | not yet |

## Dev box

### Install

```bash
cd remote
./install-zed-sender.sh
```

This symlinks `remote/bin/zed` into `~/.local/bin`, then checks that the link
wins the `zed` lookup on `PATH` and that `ZED_SSH_HOST` is set. It is a symlink
rather than a copy, so a `git pull` here updates the installed sender — leave the
checkout where it is.

Re-running is idempotent. Useful switches: `--bin-dir`, `--force`, `--uninstall`.

### Configure

The sender needs one variable in your shell rc, naming this box as the
*workstation's* Zed knows it — the alias from its `ssh_connections`, not this
box's hostname:

```bash
export ZED_SSH_HOST=desktop
```

There is no default, so the sender exits with an error when it is unset.
`ZED_OPEN_PORT` overrides the port and must match the listener's.

### Use

```bash
zed .                    # the whole directory
zed src/main.rs          # one file
zed src/main.rs:42:7     # at a line and column
```

With no Zed remote session open to this box, nothing is listening on the tunnel
port, and the sender delegates to the box's own Zed CLI if it has one — so `zed .`
still opens Zed locally when you are sitting at the machine. With no local CLI
either, it prints the `ssh://` URL to run on the workstation by hand.

Options are rejected while forwarding: the listener only accepts a URL, so
there is nothing to pass them to.

## Workstation (Windows)

### Install

```powershell
cd windows
.\install-zed-listener.ps1
```

This copies the listener to `%LOCALAPPDATA%\zed-listener`, resolves the Zed CLI,
and registers a hidden Scheduled Task named `zed-open-listener` that starts at
logon and restarts itself within a minute if it dies.

Re-running is idempotent. To remove everything:

```powershell
.\install-zed-listener.ps1 -Uninstall
```

Useful switches: `-Port`, `-ZedExe`, `-InstallDir`, `-TaskName`, `-NoStart`.

The Zed CLI path is resolved at **install** time and baked into the task
arguments. A Scheduled Task runs with a minimal PATH that does not include Zed's
install directory, so resolving `zed` at runtime would fail.

### Check

```powershell
.\check-zed-remote-open.ps1
```

Verifies the Zed CLI, the `ssh_connections` entry and its `-R` forward, the
Scheduled Task, the loopback binding, and the log. Add `-Probe` to push a real URL
through the listener, or `-CheckRemote` for a read-only SSH check of the dev box.

### Log

```
%LOCALAPPDATA%\zed-listener\zed-listener.log
```

### Zed configuration

The workstation's `settings.json` needs the host alias, the reverse forward, and
a shared control socket:

```json
"ssh_connections": [
  {
    "host": "desktop",
    "args": [
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=~/.ssh/zed-%r@%h:%p",
      "-o", "ControlPersist=10m",
      "-R", "7682:127.0.0.1:7682"
    ]
  }
]
```

The `host` value is what appears in the URL; Zed resolves it through this config
rather than as a real hostname. It is the value the dev box exports as
`ZED_SSH_HOST`, so the two have to agree.

Zed's native `port_forwards` setting cannot express this forward — it only ever
emits `-L` — so `-R` has to come through `args`.

### Why the control socket

Only one process can bind `127.0.0.1:7682` on the dev box, so with several
projects open only the first connection's forward succeeds; the rest log

```
Warning: remote port forwarding failed for listen port 7682
```

That warning is harmless and the sender keeps working, since it only needs the
one live tunnel. But OpenSSH never retries a failed remote forward, so the tunnel
belongs to whichever connection got there first, and closing that project takes
`zed .` down in every other one until a new project reconnects.

Pinning a stable `ControlPath` puts every connection to the host on one shared
master, so there is a single forward, and `ControlPersist` keeps it up across
individual projects opening and closing — including with no project open at all,
since the listener is a Scheduled Task rather than part of a session.

Zed otherwise hardcodes `ControlMaster=yes` with a `ControlPath` under a random
temp directory. These `args` win anyway: Zed appends them ahead of its own `-o`
flags, and ssh takes the first value it is given for an option.

Do not add `-o ExitOnForwardFailure=yes`. With it, every connection after the
first refuses to connect instead of warning.

## Security

The port is loopback-only, but anything running as your user can reach it, so
requests are treated as untrusted. The listener validates every URL against a
strict allowlist pattern, caps request size, and passes the URL to Zed as a single
argv entry — never through a shell.
