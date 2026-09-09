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
| Windows listener | `windows/` — PowerShell listener + tunnel supervisor + Scheduled Task installer |
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

A workstation that keeps the tunnel up as its own task, as the Windows installer
does, leaves the port listening whether or not a Zed window is open, so this works
at any time. With nothing on the other end of the tunnel, the sender delegates to
the box's own Zed CLI if it has one — so `zed .` still opens Zed locally when you
are sitting at the machine. With no local CLI either, it prints the `ssh://` URL
to run on the workstation by hand.

Options are rejected while forwarding: the listener only accepts a URL, so
there is nothing to pass them to.

## Workstation (Windows)

### Install

```powershell
cd windows
.\install-zed-listener.ps1
```

This copies both scripts to `%LOCALAPPDATA%\zed-listener`, resolves the Zed CLI
and `ssh.exe`, and registers two hidden Scheduled Tasks that start at logon and
restart themselves within a minute if they die:

| Task | Does |
| --- | --- |
| `zed-open-listener` | serves `127.0.0.1:7682` and hands each URL to the local Zed |
| `zed-open-tunnel` | keeps `ssh -N -R 7682:127.0.0.1:7682 desktop` up |

Pass `-RemoteHost` if your dev box is not the default `desktop`; the tunnel needs
it, and it has to be the same alias Zed and `ZED_SSH_HOST` use.

Re-running is idempotent. To remove everything:

```powershell
.\install-zed-listener.ps1 -Uninstall
```

Useful switches: `-Port`, `-RemoteHost`, `-ZedExe`, `-SshExe`, `-InstallDir`,
`-TaskName`, `-TunnelTaskName`, `-NoTunnel`, `-NoStart`.

Both the Zed CLI and `ssh.exe` are resolved at **install** time and baked into the
task arguments. A Scheduled Task runs with a minimal PATH that does not include
Zed's install directory, so resolving `zed` at runtime would fail.

The tunnel authenticates with `BatchMode=yes`, so nothing can prompt an invisible
process. Key auth to the dev box has to already work unattended — an encrypted key
with no agent, or a host key not yet in `known_hosts`, fails the connection.

### Check

```powershell
.\check-zed-remote-open.ps1
```

Verifies the Zed CLI, the `ssh_connections` entry, both Scheduled Tasks, the
tunnel, the loopback binding, and the logs. Add `-Probe` to push a real URL
through the listener, or `-CheckRemote` for a read-only SSH check of the dev box.

### Logs

```
%LOCALAPPDATA%\zed-listener\zed-listener.log
%LOCALAPPDATA%\zed-listener\zed-tunnel.log
```

### Zed configuration

The workstation's `settings.json` only needs the host alias:

```json
"ssh_connections": [
  {
    "host": "desktop"
  }
]
```

The `host` value is what appears in the URL; Zed resolves it through your
`~/.ssh/config` rather than as a real hostname. It is the value the dev box
exports as `ZED_SSH_HOST`, so the two have to agree.

Do **not** add `-R 7682:127.0.0.1:7682` to `args`. The `zed-open-tunnel` task owns
that forward, and only one process can bind the port on the dev box, so a second
claimant just loses the race and retries.

### Why a separate tunnel task

The forward used to ride Zed's own connections through `args`, since Zed's native
`port_forwards` setting only ever emits `-L`. That works with one project open and
degrades from there: only the first connection's forward succeeds and the rest log

```
Warning: remote port forwarding failed for listen port 7682
```

OpenSSH never retries a failed remote forward, so the tunnel belongs to whichever
connection got there first, and closing that project takes `zed .` down in every
other one until a new project reconnects.

On Linux or macOS the fix is a shared control socket — pin `ControlPath`, set
`ControlPersist`, and every connection to the host rides one master with a single
forward. **Windows OpenSSH cannot do this.** Multiplexing needs a Unix-domain
socket feature Win32-OpenSSH has never implemented
([#1328](https://github.com/PowerShell/Win32-OpenSSH/issues/1328),
[#405](https://github.com/PowerShell/Win32-OpenSSH/issues/405)), and it is out of
that project's scope. Setting `ControlPath` there does not fall back to an
unshared connection — it breaks every connection outright:

```
getsockname failed: Not a socket
Read from remote host <dev box>: Unknown error
```

So the forward is given its own connection instead. `zed-open-tunnel` runs one
`ssh -N -R`, restarts it with exponential backoff whenever it drops, and is
governed by the same watchdog trigger as the listener. Nothing about the forward
depends on Zed any more: it survives projects opening and closing, and stays up
with no project open at all, so `zed .` on the dev box opens a fresh window rather
than failing.

The tunnel's ssh does carry `-o ExitOnForwardFailure=yes` — a connection without
the forward is useless to it, and exiting hands the retry to the supervisor. That
is the opposite of the right setting for Zed's own `args`, where it would make
every connection after the first refuse to connect instead of warning.

### Stale forwards after the workstation sleeps

When the workstation sleeps, its end of the connection dies without the dev box
noticing, and that sshd session goes on holding the port. The tunnel then cannot
rebind, because OpenSSH never retries a remote forward, and the log fills with

```
Error: remote port forwarding failed for listen port 7682
```

This fails as a black hole rather than as an outage: the port still *accepts*
connections on the dev box, so `zed .` prints `Opening ssh://…` and no window ever
appears. `check-zed-remote-open.ps1 -CheckRemote` names the condition, and the
tunnel log calls it out after a run of failures.

The dev box reaps the abandoned session on its own once TCP keepalive gives up,
which takes roughly two hours. To clear it now, find the session holding the port
and kill it:

```bash
# on the dev box -- sessions with no pty and no command are abandoned -R forwards
pgrep -u "$USER" -f '^sshd:' | while read -r pid; do
  [ "$(tr -d '\0' < /proc/$pid/cmdline)" = "sshd: $USER" ] && ps -o pid=,lstart= -p "$pid"
done
```

Kill the one whose start time matches no live `ssh.exe` on the workstation. Your
Zed sessions and terminals are not candidates: they appear as `sshd: user@pts/N`
or `sshd: user@notty` and the filter above skips them.

The tunnel cannot do this for you. Identifying the holder exactly would mean
mapping the listening socket's inode to a process, and sshd drops privileges,
which leaves `/proc/<pid>/fd` readable only by root — `ss -p`, `lsof` and `fuser`
are blocked by the same thing.

Two settings would fix this properly, and both live in the dev box's
`sshd_config`, so they need whoever administers it:

- `ClientAliveInterval` makes sshd notice the dead peer in seconds instead of
  hours.
- `StreamLocalBindUnlink yes` would let the forward move to a Unix socket
  (`-R /run/user/$UID/zed-open.sock:127.0.0.1:7682`), where a new tunnel unlinks
  a stale socket and takes over. The client-side option of that name does not
  cover remote forwards, so setting it here has no effect.

## Security

The port is loopback-only, but anything running as your user can reach it, so
requests are treated as untrusted. The listener validates every URL against a
strict allowlist pattern, caps request size, and passes the URL to Zed as a single
argv entry — never through a shell.
