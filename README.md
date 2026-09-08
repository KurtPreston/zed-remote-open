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

## Status

| Platform | Listener |
| --- | --- |
| Windows | `windows/` — PowerShell listener + Scheduled Task installer |
| macOS | not yet |
| Linux | not yet |

The sender (`bin/zed` on the dev box) lives in the dotfiles repo, not here.

## Windows

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

The workstation's `settings.json` needs the host alias and the reverse forward:

```json
"ssh_connections": [
  {
    "host": "desktop",
    "args": ["-R", "7682:127.0.0.1:7682"]
  }
]
```

The `host` value is what appears in the URL; Zed resolves it through this config
rather than as a real hostname.

## Security

The port is loopback-only, but anything running as your user can reach it, so
requests are treated as untrusted. The listener validates every URL against a
strict allowlist pattern, caps request size, and passes the URL to Zed as a single
argv entry — never through a shell.
