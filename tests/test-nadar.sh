#!/usr/bin/env bash
set -Eeuo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config/nadar" "$TMP/state"

cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
cat "$SS_FIXTURE"
MOCK
cat > "$TMP/bin/logger" <<'MOCK'
#!/usr/bin/env bash
printf 'LOG %s\n' "$*" >> "$TEST_LOG"
MOCK
cat > "$TMP/bin/notify-send" <<'MOCK'
#!/usr/bin/env bash
printf 'NOTIFY %s\n' "$*" >> "$TEST_LOG"
MOCK
cat > "$TMP/bin/xdg-open" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin"/*

cat > "$TMP/fixture" <<'DATA'
udp UNCONN 0 0 0.0.0.0:1900 0.0.0.0:* users:(("spotify",pid=1567,fd=310))
udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:(("spotify",pid=1668,fd=312))
udp UNCONN 0 0 0.0.0.0:54661 0.0.0.0:* users:(("firefox",pid=1447,fd=421))
tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("spotify",pid=1567,fd=10),("sshd",pid=900,fd=9))
tcp LISTEN 0 128 0.0.0.0:50000 0.0.0.0:* users:(("other",pid=3999,fd=10),("firefox",pid=1447,fd=9))
tcp LISTEN 0 128 0.0.0.0:445 0.0.0.0:*
tcp LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=900,fd=1))
DATA

export PATH="$TMP/bin:$PATH" SS_FIXTURE="$TMP/fixture" \
  XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  TEST_LOG="$TMP/log" NO_COLOR=1
NADAR="$BASE/nadar"
CONF="$TMP/config/nadar/nadar.conf"

cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS="UDP:1900"
EXCLUDE_PROCESSES="Spotify, firefox"
EXCLUDE_PIDS="0003999"
NADAR_INTERVAL=10
CONF
"$NADAR" --list > "$TMP/list"
! grep -Eq 'spotify|firefox|3999|1900|50000' "$TMP/list"
grep -q '8080.*sshd.*900' "$TMP/list"
grep -q '445' "$TMP/list" # ei piiloteta tuntemattoman prosessin portteja
"$NADAR" --summary > "$TMP/summary"
grep -q '8080.*sshd' "$TMP/summary"
! grep -q 'spotify' "$TMP/summary"
"$NADAR" --once
"$NADAR" --once
[[ $(grep -c '^LOG ' "$TMP/log") == 1 ]]
! grep -q '^NOTIFY ' "$TMP/log"

cat > "$CONF" <<'CONF'
LISTENPROTO="TCP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES="spotify"
EXCLUDE_PIDS=""
CONF
"$NADAR" --summary > "$TMP/summary"
grep -q '50000.*other, firefox.*3999, 1447' "$TMP/summary"
! grep -q '54661' "$TMP/summary"
NADAR_HTML_PATH="$TMP/summary.html" "$NADAR" --summary-html > /dev/null
grep -q 'other, firefox' "$TMP/summary.html"

cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES=""
EXCLUDE_PIDS="1567"
CONF
"$NADAR" --list > "$TMP/list"
grep -q '5353.*spotify.*1668' "$TMP/list"
! grep -q '1900' "$TMP/list"
grep -q '8080.*sshd' "$TMP/list"

cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES=""
EXCLUDE_PIDS="abc"
CONF
if "$NADAR" --list > /dev/null 2> "$TMP/error"; then
  echo 'FAIL: invalid EXCLUDE_PIDS accepted' >&2; exit 1
fi
grep -q 'virheellinen PID' "$TMP/error"

echo 'OK: NADAR process/PID exclusions, shared sockets, summaries, HTML, baseline and validation'
