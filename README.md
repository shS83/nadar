# NADAR — Network Anomaly Detection and Reporting

**Version 0.6.0** — Bash-based local socket watcher with KDE notifications, terminal and HTML reports, and optional independent remote reachability checks.

This release adds `--scan` and a restricted remote sudo helper. `--remote-verify` remains an alias, and `--test-notify` and `--poke-remote` are unchanged.

## Requirements

**Local computer (Arch Linux / KDE Plasma)**

- Bash 5+, `iproute2` (`ss`), GNU coreutils, `awk`, `sort`, `paste`, `comm`
- `libnotify` (`notify-send`) for KDE notifications
- `curl` for public IPv4 discovery
- OpenSSH client for remote Nmap scans; an SSH alias named `ouroboros` (or configure another host)
- `xdg-utils` for opening HTML reports

```bash
sudo pacman -S --needed bash iproute2 coreutils gawk libnotify curl openssh xdg-utils
```

**Remote server (Ouroboros, Ubuntu/Debian)**

- `nmap`, OpenSSH server (for independent remote scans)
- systemd (for the separate TCP 42000 health-check responder)

```bash
sudo apt update
sudo apt install nmap openssh-server
```

## Local installation

From this extracted directory:

```bash
install -Dm755 nadar "$HOME/.local/bin/nadar"
install -Dm644 nadar.service "$HOME/.config/systemd/user/nadar.service"
mkdir -p "$HOME/.config/nadar"
# Only for a new install. Preserve your existing settings on upgrades:
[[ -e "$HOME/.config/nadar/nadar.conf" ]] || \
  install -m644 nadar.conf "$HOME/.config/nadar/nadar.conf"

systemctl --user daemon-reload
systemctl --user enable --now nadar.service
```

If updating an already running service:

```bash
systemctl --user restart nadar.service
```

A service restart is needed for changes to the Bash executable or configuration to take effect. `--list` and other new CLI invocations read the configuration afresh.

## Commands

```text
NADAR - Network Anomaly Detection and Reporting v0.6.0

nadar --list                         Colorized individual sockets
nadar --summary                      Grouped endpoints and socket counts
nadar --summary-html                 Write ./summary.html and open via xdg-open
nadar --watch                        Poll new listeners and send KDE alerts
nadar --once                         Single listener change check
nadar --test-notify                  Test KDE desktop notifications
nadar --poke-remote                  TCP PING/OK health check
nadar --scan                         Remote Nmap of current local listener ports
nadar --scan TCP:420,UDP:11000       Scan specific TCP/UDP ports
nadar --remote-verify                Backward-compatible alias of --scan
nadar --status                       Show systemd user service status
nadar --reset                        Reset the baseline (no alerts on first run)
nadar --version, -v                  Show version and exit
nadar --help                         Full English help
```

Terminal colors: purple protocols, blue IPs, amber ports, green processes, red PIDs. The `NO_COLOR=1` environment variable disables ANSI coloring.

## Configuration

File: `~/.config/nadar/nadar.conf` (or `$XDG_CONFIG_HOME/nadar/nadar.conf`). It is parsed as data; this file is **not** sourced as executable shell code.

```bash
LISTENPROTO="TCP,UDP"              # or TCP / UDP
EXCLUDEPORTS="UDP:1900,UDP:5353"    # accepts port ranges, e.g. TCP:8000-8010
EXCLUDE_PROCESSES=""                # exact, case-insensitive names
EXCLUDE_PIDS=""                     # comma-separated PID numbers
EXCLUDE_PROCESS_NOTIFY="spotify"    # visible in reports; no Spotify alert
NADAR_INTERVAL=10                    # seconds; environment override allowed

REMOTE_POKE_HOST="prometheus-alexander.fi"
REMOTE_POKE_PORT=42000
REMOTE_SSH_HOST="ouroboros"           # an SSH alias from ~/.ssh/config
REMOTE_SCAN_TARGET=""                # optional public IPv4 (if empty, auto-detect)
```

Be mindful of the distinction: excluding an application from **notifications** does not exclude its ports from `--list`, `--summary`, or `--remote-verify` (only `EXCLUDE_PROCESSES` / `EXCLUDE_PIDS` do).

A listener with no visible process name remains visible, and it is not automatically treated as an excluded process.

## Configure the TCP health responder on Ouroboros

The included responder is deliberately simple: it accepts exactly a line containing `PING` and sends back `OK`, otherwise `ERR`. It does **not** run any scans, execute shell commands sent over the network, or expose an API.

Copy the three files under `remote/` to Ouroboros, then run on **Ouroboros** from that copied folder:

```bash
sudo install -Dm755 nadar-pong /usr/local/libexec/nadar-pong
sudo install -Dm644 nadar-pong.socket /etc/systemd/system/nadar-pong.socket
sudo install -Dm644 'nadar-pong@.service' /etc/systemd/system/'nadar-pong@.service'
sudo systemctl daemon-reload
sudo systemctl enable --now nadar-pong.socket
sudo systemctl status nadar-pong.socket
```

The `.socket` unit listens on TCP/42000; systemd activates a fresh restricted instance of `nadar-pong@.service` per connection. Open inbound TCP/42000 in Ouroboros's firewall **only if you want it publicly reachable**. Prefer limiting access to your trusted IP address(es) if possible. The endpoint is plaintext and unauthenticated, intended only as a health indicator, not as a secure identity proof.

On the local computer:

```bash
nadar --poke-remote
# Remote health: OK (prometheus-alexander.fi:42000)
```

The domain must actually resolve to the server where the socket runs. The health-check connection is initiated **from the local computer to Ouroboros**.

If you prefer not to expose TCP/42000 publicly, leave the server firewall closed and use an SSH local-forward, e.g. `ssh -N -L 42000:127.0.0.1:42000 ouroboros`; then set `REMOTE_POKE_HOST="127.0.0.1"` locally. The listener remains available on Ouroboros but does not need to be internet-accessible.

## Restricted remote Nmap from Ouroboros (`--scan`)

**`nadar --scan` runs an Nmap port scan ON Ouroboros, targeting the public IPv4 of the local computer.**
The local NADAR process does not need sudo/root for this feature. Ouroboros runs a dedicated **root-owned, argument-validating helper** via `sudo -n`. This enables UDP `-sU` without granting passwordless root access to arbitrary Nmap commands.

1. Install on **Ouroboros** (Ubuntu/Debian):

```bash
sudo apt update
sudo apt install --yes nmap sudo openssh-server

# From the extracted project's remote/ directory on Ouroboros:
sudo install -o root -g root -m 0755 nadar-scan /usr/local/libexec/nadar-scan
sudo install -o root -g root -m 0440 nadar-scan.sudoers /etc/sudoers.d/nadar-scan
sudo visudo -cf /etc/sudoers.d/nadar-scan
```

The included sudoers template authorizes the SSH user **`santeri`**. If your Ouroboros SSH username differs, edit *only that name* in the template before installation. The target helper is limited to `tcp|udp`, a list of up to 128 valid port numbers, and a literal IPv4 address. No Nmap flags or shell commands can be passed through its arguments. Because the helper runs as root, its file and its parent directories must not be writable by non-root users.

**Optional stronger restriction:** put the permitted destination IPs (one exact IPv4 per line) into **`/etc/nadar/allowed-targets`** on Ouroboros, owned by root and mode 0644. If this file exists, scans for other targets are rejected. This may be inconvenient with a dynamic mobile broadband IP, since the file must be updated after the public IP changes. Without that file, any IPv4 can be requested by the authorized SSH user, although the helper cannot execute arbitrary commands or pass arbitrary Nmap options.

2. Test Ouroboros from **EPSILONTAURI** (use your existing SSH alias):

```bash
ssh -o BatchMode=yes ouroboros 'sudo -n /usr/local/libexec/nadar-scan tcp 2222 83.245.234.142'
```

Substitute your current public IPv4 as appropriate. **The last argument is the target machine's public IP**, not Ouroboros's address. Expected output contains an Nmap `Host:` line and a `Ports:` field. A `filtered` result is a valid observation, not a scanning error.

3. Run NADAR locally:

```bash
nadar --scan
nadar --scan TCP:2222,UDP:11000
nadar --scan TCP:8000-8003
nadar --remote-verify TCP:2222   # old name still works
```

- **No argument:** inspect the currently filtered local sockets, remove duplicates and loopback-only ports, then scan their port numbers against your public IPv4 from Ouroboros. It cannot infer router port forwarding from local sockets alone.
- **With argument:** a comma-separated set of `TCP:port`, `UDP:port` and small inclusive ranges. Explicit ports need not be listening locally.
- **Target:** `REMOTE_SCAN_TARGET` overrides the public IPv4 discovered with `curl -4 https://ifconfig.co/ip`.
- **SSH:** `REMOTE_SSH_HOST` uses your OpenSSH alias, e.g. `ouroboros`; `BatchMode=yes` is used for non-interactive operation.
- **TCP:** remote Nmap `-sT -Pn -n`; **UDP:** `-sU -Pn -n` through the same privileged helper. An unavailable helper, failed sudo, or failed scan yields a nonzero exit code.
- Results include Nmap states `open`, `closed`, `filtered`, and `open|filtered`. The last state does **not** confirm an open UDP port. Results describe reachability from Ouroboros only; they do not prove worldwide access.
- TCP/42000 `nadar-pong` remains a separate minimal health responder. It **cannot** start scans. Scans happen over authenticated SSH.

Scan **only** IP addresses and machines you own or have authorization to test. Avoid exposing the scanner helper or its sudo rights to untrusted SSH users.

## Desktop notifications and baseline

New local listening endpoints trigger KDE notifications containing the protocol, address, port, and known process name. If a name is unavailable, the message remains useful without a process label. The initial snapshot is saved without firing alerts. Changes in PID alone do not create a new endpoint alert.

```bash
journalctl --user -u nadar.service -f
nadar --test-notify
nadar --reset
```

`--reset` removes the local listener baseline; the next check establishes a new one. The running watcher should be stopped before resetting it to avoid a race, then restarted.

## Run tests

Tests use fake `ss` output, a stubbed SSH/scanner invocation, and a local loopback-only PING responder; they do **not** scan the internet or change your firewall. The helper-validation tests reject invalid input before any privileged action.

```bash
bash tests/test-nadar.sh
bash tests/test-excludes.sh
bash tests/test-remote.sh
bash tests/test-scanner.sh
```

The remote health socket's full deployment must be verified on your real systemd server. The test suite does not require a running Ouroboros service.
