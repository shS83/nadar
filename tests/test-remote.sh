#!/usr/bin/env bash
# End-to-end CLI tests with mocked Nmap-over-SSH and a local test responder.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
SERVER_PID=''
cleanup() { if [[ -n $SERVER_PID ]]; then kill "$SERVER_PID" 2>/dev/null || :; wait "$SERVER_PID" 2>/dev/null || :; fi; rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/config/nadar" "$TMP/state"
cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
cat "$SS_FIXTURE"
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '198.51.100.42\n'
MOCK
cat > "$TMP/bin/notify-send" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTIFY_LOG"
MOCK
cat > "$TMP/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
case "$*" in
  *'nadar-scan tcp '*)
    printf 'Host: 198.51.100.42 ()\tPorts: 420/open/tcp//unknown///, 2222/filtered/tcp////, 445/closed/tcp////\n' ;;
  *'nadar-scan udp '*)
    if [[ ${MOCK_UDP_UNAVAILABLE:-} == 1 ]]; then
      printf 'UDP_REQUIRES_ROOT\n' >&2
      exit 78
    fi
    printf 'Host: 198.51.100.42 ()\tPorts: 11000/open|filtered/udp////\n' ;;
  *) echo 'Unexpected mock ssh command' >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMP/bin"/*
cat > "$TMP/fixture" <<'DATA'
tcp LISTEN 0 128 0.0.0.0:420 0.0.0.0:* users:(("python3",pid=1001,fd=11))
tcp LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1002,fd=12))
udp UNCONN 0 0 0.0.0.0:11000 0.0.0.0:* users:(("spotify",pid=1003,fd=13))
tcp LISTEN 0 128 127.0.0.1:5555 0.0.0.0:* users:(("localhost",pid=1004,fd=14))
DATA
export PATH="$TMP/bin:$PATH" SS_FIXTURE="$TMP/fixture" \
  XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  SSH_LOG="$TMP/ssh.log" NOTIFY_LOG="$TMP/notify.log" NO_COLOR=1
NADAR="$ROOT/nadar"
CONF="$TMP/config/nadar/nadar.conf"
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDE_PROCESS_NOTIFY="spotify"
REMOTE_SSH_HOST="ouroboros"
REMOTE_SCAN_TARGET=""
CONF
fail() { echo "FAIL: $*" >&2; exit 1; }
# Help must be fully English, contain the product name and all new flags.
"$NADAR" --help > "$TMP/help"
grep -Fq 'NADAR - Network Anomaly Detection and Reporting v0.6.0' "$TMP/help" || fail 'wrong help banner'
for flag in --test-notify --poke-remote --remote-verify --scan; do
  grep -Fq -- "$flag" "$TMP/help" || fail "missing $flag in help"
done
"$NADAR" --test-notify > "$TMP/test-notify"
grep -Fq 'NADAR: test notification' "$TMP/notify.log" || fail 'test notification not sent'
grep -Fq 'Test notification sent.' "$TMP/test-notify" || fail 'test notification message incorrect'

"$NADAR" --scan 'TCP:420,UDP:11000,TCP:2222' > "$TMP/scan"
grep -Eq 'TCP[[:space:]]+420[[:space:]]+open$' "$TMP/scan" || fail 'TCP open not reported'
grep -Eq 'TCP[[:space:]]+2222[[:space:]]+filtered$' "$TMP/scan" || fail 'TCP filtered not reported'
grep -Eq 'UDP[[:space:]]+11000[[:space:]]+open\|filtered$' "$TMP/scan" || fail 'UDP uncertainty not preserved'
grep -Fq 'ouroboros' "$TMP/scan" || fail 'scanner host missing'
grep -Fq -- 'sudo -n /usr/local/libexec/nadar-scan tcp 420,2222 198.51.100.42' "$TMP/ssh.log" || fail 'TCP scan command incorrect'
grep -Fq -- 'sudo -n /usr/local/libexec/nadar-scan udp 11000 198.51.100.42' "$TMP/ssh.log" || fail 'UDP scan command incorrect'

"$NADAR" --scan > "$TMP/default"
grep -Eq 'TCP[[:space:]]+420[[:space:]]+open$' "$TMP/default" || fail 'default TCP port absent'
grep -Eq 'UDP[[:space:]]+11000[[:space:]]+open\|filtered$' "$TMP/default" || fail 'default UDP port absent'
! grep -q -- '5555' "$TMP/ssh.log" || fail 'loopback-only port incorrectly scanned'

: > "$TMP/ssh.log"
for bad in 'TCP:0' 'TCP:65536' 'UDP:100-99' 'TCP:420;id' 'TCP:1-200' 'BOGUS:420'; do
  if "$NADAR" --scan "$bad" > "$TMP/output" 2> "$TMP/error"; then
    fail "invalid port list accepted: $bad"
  fi
done
[[ ! -s "$TMP/ssh.log" ]] || fail 'SSH was invoked for invalid ports'

export MOCK_UDP_UNAVAILABLE=1
if "$NADAR" --scan UDP:11000 > "$TMP/output" 2> "$TMP/error"; then
  fail 'UDP privilege failure was incorrectly accepted'
fi
grep -Fq 'UDP ports not verified' "$TMP/error" || fail 'missing UDP privilege warning'
unset MOCK_UDP_UNAVAILABLE

# Use an actual localhost TCP server to test the PING -> OK handshake.
cat > "$TMP/test-server.py" <<'PY'
import socket, sys
s = socket.socket()
s.bind(('127.0.0.1', 0))
s.listen(1)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.getsockname()[1]))
conn, addr = s.accept()
with conn:
    payload = b''
    while not payload.endswith(b'\n') and len(payload) < 100:
        piece = conn.recv(100)
        if not piece:
            break
        payload += piece
    conn.sendall(b'OK\n' if payload == b'PING\n' else b'ERR\n')
s.close()
PY
python3 "$TMP/test-server.py" "$TMP/port" & SERVER_PID=$!
for ((i=0; i<100; i++)); do [[ -s "$TMP/port" ]] && break; sleep .02; done
[[ -s $TMP/port ]] || fail 'test server did not start'
cat > "$CONF" <<CONF
REMOTE_POKE_HOST="127.0.0.1"
REMOTE_POKE_PORT=$(cat "$TMP/port")
CONF
"$NADAR" --poke-remote > "$TMP/poke" || fail 'PING/OK failed'
grep -Fq 'Remote health: OK' "$TMP/poke" || fail 'poke output incorrect'
wait "$SERVER_PID"; SERVER_PID=''

[[ $(printf 'PING\n' | "$ROOT/remote/nadar-pong") == OK ]] || fail 'socket responder did not return OK to PING'
[[ $(printf 'INVALID\n' | "$ROOT/remote/nadar-pong") == ERR ]] || fail 'socket responder did not reject invalid input'
grep -q '^ListenStream=42000$' "$ROOT/remote/nadar-pong.socket" || fail 'wrong remote systemd socket port'
printf 'OK: English help, notifications, restricted SSH scanner TCP/UDP, implicit port discovery, input validation and TCP PING/OK\n' 
