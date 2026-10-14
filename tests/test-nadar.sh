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
# Puuttuvan prosessin UTF-8-viiva ei saa siirtää PID-saraketta.
header=$(head -n 1 "$TMP/list")
row=$(grep -E '^tcp[[:space:]]+LISTEN[[:space:]]+0\.0\.0\.0[[:space:]]+445' "$TMP/list")
col_prefix=${header%%PID*}
normalized=${row//—/-}
[[ ${normalized:${#col_prefix}:1} == '-' ]] || {
  echo 'FAIL: --list PID column is misaligned after a UTF-8 dash' >&2; exit 1;
}
"$NADAR" --summary > "$TMP/summary"
grep -q '8080.*sshd' "$TMP/summary"
! grep -q 'spotify' "$TMP/summary"
"$NADAR" --once
"$NADAR" --once
[[ $(grep -c '^LOG ' "$TMP/log") == 1 ]]
! grep -q '^NOTIFY ' "$TMP/log"

# Hälytys näyttää uuden kuuntelijan prosessinimen, yhdistää samalle
# osoitteelle/portille kuuluvat nimet ja jättää nimet pois jos ss ei niitä näytä.
cat >> "$TMP/fixture" <<'DATA'
tcp LISTEN 0 128 127.0.0.1:9090 0.0.0.0:* users:(("python3",pid=2030,fd=2))
tcp LISTEN 0 128 127.0.0.1:9090 0.0.0.0:* users:(("python3",pid=2030,fd=3))
tcp LISTEN 0 128 127.0.0.1:9090 0.0.0.0:* users:(("uvicorn",pid=2031,fd=4))
tcp LISTEN 0 128 127.0.0.1:9091 0.0.0.0:*
tcp LISTEN 0 128 127.0.0.1:9393 0.0.0.0:* users:(("spotify",pid=1567,fd=11))
DATA
"$NADAR" --once
[[ $(grep -c '^NOTIFY ' "$TMP/log") == 2 ]] || {
  echo 'FAIL: newly listening ports did not trigger exactly two alerts' >&2; exit 1;
}
[[ $(grep -c 'Process: python3, uvicorn' "$TMP/log") == 1 ]] || {
  echo 'FAIL: incorrect process name aggregation or notification text' >&2; exit 1;
}
grep -q 'NEW LISTENER tcp 127.0.0.1:9090 process=python3, uvicorn' "$TMP/log"
grep '^NOTIFY ' "$TMP/log" | grep -q '9091.*external reachability not checked'
! grep -q '9393' "$TMP/log"
"$NADAR" --once
[[ $(grep -c '^NOTIFY ' "$TMP/log") == 2 ]] || {
  echo 'FAIL: duplicate listener alert' >&2; exit 1;
}

cat > "$CONF" <<'CONF'
LISTENPROTO="TCP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES="spotify"
EXCLUDE_PIDS=""
CONF
"$NADAR" --summary > "$TMP/summary"
grep -q '50000.*other, firefox.*3999, 1447' "$TMP/summary"
# --summary: sekä PID että SOCKETS pysyvät otsikkonsa alla.
header=$(sed -n '2p' "$TMP/summary")
row=$(grep -E '^tcp[[:space:]]+LISTEN[[:space:]]+0\.0\.0\.0[[:space:]]+445' "$TMP/summary")
normalized=${row//—/-}
col_prefix=${header%%PID*}
[[ ${normalized:${#col_prefix}:1} == '-' ]] || {
  echo 'FAIL: --summary PID column is misaligned' >&2; exit 1;
}
col_prefix=${header%%SOCKETS*}
[[ ${normalized:${#col_prefix}:1} == '1' ]] || {
  echo 'FAIL: --summary SOCKETS column is misaligned' >&2; exit 1;
}
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
grep -q 'invalid PID' "$TMP/error"

echo 'OK: NADAR exclusions, shared sockets, new-listener notifications, summaries, HTML, baseline and validation'
