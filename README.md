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
| macOS listener | `macos/` — bash handler + tunnel supervisor + launchd installer |
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

### Keeping projects in one window

`zed .` in a second directory adds that project to the window you already have
rather than opening another one, and the two share a single SSH connection.

Zed's CLI has no one invocation that does this. With no flag it activates a
project that is already open but opens a new window for anything else, because
`open_remote_project` ignores the sidebar preference that the local path honours.
`--reuse` names a target window but switches the already-open check off, and
re-opening a live project that way restarts its remote server underneath the
running workspace and leaves the worktree broken.

So the listener picks between the two and remembers what it has opened, in
`open-projects.txt` beside the logs. Every uncertain case resolves to no flag,
because a stray window is cheaper than a corrupted project. A path inside a
project it opened, a path carrying a line number, and a path whose last segment
matches the title of an open window all count as already open. The list resets
whenever a request arrives with no Zed window running, since a Zed the CLI starts
opens only the path it was given and never restores the previous session.

What it cannot see is a project you opened through Zed's own UI, unless that
project happens to be the active one in some window. Open one of those from the
dev box while a different project is in front and it is added a second time;
close the duplicate and open it again to clear that up. Teaching Zed to put
remote projects in the sidebar itself would retire all of this — see
[Upstream](#upstream), which names the few lines that would do it.

`-e`/`--existing` is not the flag for this, despite being the documented one.
It asks for the sidebar placement that remote opens ignore, so a project that is
not already open still gets its own window. `--reuse` is hidden from `--help`
but is the only one that names a window.

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
`port_forwards` setting only ever emits `-L`. Zed pools one SSH master per host, so
a second project does not open a second master — but the master is not the only
connection Zed makes. Because it cannot multiplex on Windows, every other
invocation is its own `ssh` process carrying the same `args`: each project's
`zed-remote-server` proxy, every terminal, every task. Each one re-attempts the
forward, and every attempt after the first logs

```
Warning: remote port forwarding failed for listen port 7682
```

OpenSSH never retries a failed remote forward, so the tunnel belongs to whichever
connection got there first — often a terminal rather than a project — and closing
that one takes `zed .` down until some later connection happens to reclaim the port.

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
every connection after the first — including every terminal you open — refuse to
connect instead of warning.

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

## Workstation (macOS)

The macOS side does the same two jobs as the Windows side — serve the loopback
port and keep the reverse tunnel up — but the shapes are native to the platform,
so read this rather than translating the Windows section.

### Install

```bash
cd macos
./install-zed-listener.sh --remote-host desktop
```

This resolves the Zed CLI and `ssh`, writes two launchd agents into
`~/Library/LaunchAgents`, and loads them. Pass `--remote-host` if your dev box is
not the default `desktop`; it has to be the same alias Zed and `ZED_SSH_HOST` use.

Re-running is idempotent. To remove everything:

```bash
./install-zed-listener.sh --uninstall
```

Useful switches: `--port`, `--remote-host`, `--zed-bin`, `--ssh-bin`,
`--no-tunnel`, `--no-start`, `--uninstall`.

The scripts run from this checkout rather than being copied, like the dev-box
sender, so a `git pull` here updates the install — leave the checkout where it is.
Only the Zed CLI and `ssh` paths are resolved at install time and baked into the
agents, because a launchd agent starts with a minimal PATH. The CLI is used from
inside its `.app` bundle and never copied out: it finds its own app by walking up
from its executable, so a copy elsewhere launches nothing.

| Agent | Does |
| --- | --- |
| `zed-remote-open.listener` | serves `127.0.0.1:7682` and hands each URL to the local Zed |
| `zed-remote-open.tunnel` | keeps `ssh -N -R 7682:127.0.0.1:7682 desktop` up |

### Two launchd agents, not two loops

The listener is socket-activated. Its plist carries `inetdCompatibility` with
`Wait: false` and a `Sockets` entry, so **launchd** binds `127.0.0.1:7682` and
hands each accepted connection to a fresh copy of `zed-open-handler.sh` on stdio.
The port is therefore bound from load onward whether or not Zed is running —
the property the Windows install gets from a watchdog Scheduled Task — and
because every request is its own short-lived process, a malformed URL, a slow
sender, or a crash takes down only that one process. "A bad request must never
stop the service" is structural here, not a `try`/`catch`. The `launchd.plist(5)`
manual calls `inetdCompatibility` legacy, but its replacement,
`launch_activate_socket(3)`, is a C API no shell can reach.

The tunnel is a plain `RunAtLoad` + `KeepAlive` agent whose own loop supervises
one `ssh -N -R`, with the same backoff and stale-forward reporting as the Windows
one. It owns the forward for the same reason: so it survives projects opening and
closing, and stays up with no project open at all. Its shutdown is signal-driven
— the backoff sleep is interruptible so a `launchctl bootout` does not wait out
the delay, and a trap kills the ssh child so the forward never outlives the
supervisor and strands the port on the dev box.

Everything in [Why a separate tunnel task](#why-a-separate-tunnel-task) and
[Stale forwards after the workstation sleeps](#stale-forwards-after-the-workstation-sleeps)
applies unchanged; `check-zed-remote-open.sh --check-remote` names the stale
condition, as its PowerShell sibling does. Unlike Windows OpenSSH, macOS `ssh`
*can* multiplex, so pinning `ControlPath` and `ControlPersist` on the host would
also work — but a dedicated tunnel agent is simpler to supervise and does not
depend on Zed making any connection at all, so this uses one anyway.

### Check

```bash
./check-zed-remote-open.sh
```

Verifies the Zed CLI, the `ssh_connections` entry, both agents, the loopback
binding, the tunnel, the logs, and the placement inputs. Add `--probe` to push a
real URL through the listener, or `--check-remote` for a read-only SSH check of
the dev box. It also confirms `ssh -o BatchMode=yes <host> true` works, because a
launchd agent inherits the GUI session's `SSH_AUTH_SOCK` and cannot answer a
passphrase prompt — key auth has to already be non-interactive.

### Logs

```
~/Library/Logs/zed-listener/zed-listener.log
~/Library/Logs/zed-listener/zed-tunnel.log
```

### Keeping projects in one window

The placement problem is the same as on Windows, and the flag it resolves to is
the same, but macOS decides it from better evidence. Instead of reading window
titles — which need a TCC grant a background agent cannot obtain — the handler
asks Zed's own workspace database at
`~/Library/Application Support/Zed/db/0-stable/db.sqlite` which remote projects
are open in the running session:

```sql
SELECT w.paths FROM workspaces w
  JOIN remote_connections c ON c.id = w.remote_connection_id
 WHERE c.kind = 'ssh' AND c.host = '<host>'
   AND w.session_id = (SELECT value FROM kv_store WHERE key = 'session_id');
```

This sees projects opened through Zed's own UI too, which the Windows window-title
heuristic misses. It gates on a live Zed process first (`pgrep`), because Zed
leaves the `session_id` bound on a workspace after a quit or crash so it can
restore next launch, and `kv_store.session_id` is not replaced until that launch
— so the query alone would report a quit Zed's last projects as still open. A
request carrying a line number, or a path equal to or inside an open project,
resolves to no flag; anything else gets `--reuse`. If the database cannot be read,
placement falls back to an `open-projects.txt` beside the state directory and
lands at Windows-level behaviour.

macOS 15 added an "App Data" TCC prompt for reading another app's
`~/Library/Application Support` folder, and a launchd agent cannot reliably show
it. On the machine this was built against (macOS 26) a `/bin/bash` agent read the
database with no prompt and no error, so the database path is the default; the
state-file fallback is there for any setup where that grant is withheld.

### Zed configuration

The same as [Zed configuration](#zed-configuration) for Windows: the
workstation's `~/.config/zed/settings.json` needs the host alias in
`ssh_connections`, and must **not** carry the `-R 7682:127.0.0.1:7682` forward in
`args`, because the `zed-remote-open.tunnel` agent owns it and the two would race
for the same remote port.

## Upstream

Zed wants a remote-side CLI and nobody there is building one, so this repo has no
scheduled end. A maintainer in
[#32214](https://github.com/zed-industries/zed/discussions/32214) sketched the
design they would take — inject an alias into Zed's own terminal sessions so
`zed` reaches the `zed-remote-server` process that owns the project, and define
message passing over it — and called it something they had wanted for a while
that needed infrastructure work first. The tracking issue is
[#56057](https://github.com/zed-industries/zed/issues/56057), never-stale and
labelled `platform:remote`; the feature request is
[#33601](https://github.com/zed-industries/zed/discussions/33601).

Two contributors have built it. [#40484](https://github.com/zed-industries/zed/pull/40484)
drew a full design review and an offer of help from Zed's own people before its
author ran out of time, and it closed unmerged.
[#50250](https://github.com/zed-industries/zed/pull/50250) implements the
suggested design — `remote_server` gains a `cli` mode, a Unix socket per session,
an `OpenPathOnClient` RPC over the SSH channel already there, a shim on `PATH`
inside remote terminals — and has sat open since February 2026 with no maintainer
review and two people offering to take it over. Receptiveness is not the
bottleneck; review attention is.

The review on #40484 is where the constraints live, and they are worth reading
before anyone writes a third attempt: one shim for every connection rather than
one each, identified by an environment variable the terminal's activation script
sets; the existing data-directory helper rather than a hand-built path; no
`ssh://` URLs from the remote side, since remoting transitively is meaningless;
and the server parsing and opening the path rather than handing a remote-only
path to the client to resolve.

The window placement above is a smaller and separate gap. Zed staff landed half
of it in [#49307](https://github.com/zed-industries/zed/pull/49307): the
already-open lookup now covers remote locations, which is why no flag reliably
activates a project that is open. The other half is that `open_remote_project`
reads `requesting_window` but never `add_dirs_to_sidebar`, so the sidebar
preference still stops at local paths. Resolving the active window into
`requesting_window` when that option is set, as the local path does, would end
the listener's guessing on every platform.

## Security

The port is loopback-only, but anything running as your user can reach it, so
requests are treated as untrusted. The listener validates every URL against a
strict allowlist pattern, caps request size, and passes the URL to Zed as a single
argv entry — never through a shell.
