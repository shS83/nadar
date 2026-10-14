#!/usr/bin/env bash
# All NADAR EXCLUDE* settings, including notify-only process exclusions.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config/nadar" "$TMP/state"

cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
cat -- "$SS_FIXTURE"
MOCK
cat > "$TMP/bin/logger" <<'MOCK'
#!/usr/bin/env bash
printf 'LOG: %s\n' "$*" >> "$TEST_LOG"
MOCK
cat > "$TMP/bin/notify-send" <<'MOCK'
#!/usr/bin/env bash
# A single line per call; represent embedded newlines as literal backslash-n.
msg=$(printf '%s' "$*" | tr '\n' '|')
printf 'NOTIFY: %s\n' "$msg" >> "$TEST_LOG"
MOCK
cat > "$TMP/bin/xdg-open" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin"/*

cat > "$TMP/fixture" <<'DATA'
udp UNCONN 0 0 0.0.0.0:1900 0.0.0.0:* users:(("spotify",pid=1567,fd=1))
udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:(("spotify",pid=1668,fd=2))
udp UNCONN 0 0 0.0.0.0:50001 0.0.0.0:* users:(("firefox",pid=1447,fd=3))
tcp LISTEN 0 128 0.0.0.0:445 0.0.0.0:*
tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("spotify",pid=1567,fd=5),("sshd",pid=900,fd=6))
tcp LISTEN 0 128 0.0.0.0:8081 0.0.0.0:* users:(("spotify",pid=1567,fd=7))
tcp LISTEN 0 128 0.0.0.0:8082 0.0.0.0:* users:(("firefox",pid=1447,fd=8))
tcp LISTEN 0 128 0.0.0.0:8083 0.0.0.0:* users:(("other",pid=4004,fd=9))
tcp LISTEN 0 128 0.0.0.0:8084 0.0.0.0:* users:(("firefox",pid=1447,fd=10),("other",pid=4004,fd=11))
tcp LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=900,fd=12))
DATA

export PATH="$TMP/bin:$PATH" \
  SS_FIXTURE="$TMP/fixture" XDG_CONFIG_HOME="$TMP/config" \
  XDG_STATE_HOME="$TMP/state" TEST_LOG="$TMP/events" NO_COLOR=1
NADAR="$ROOT/nadar"
CONF="$TMP/config/nadar/nadar.conf"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_absent() { if grep -Fq -- "$2" "$1"; then fail "unexpected '$2' in $1"; fi; }

# 1: Portti- ja protokollarajaus, myös protokollakohtainen porttialue.
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS="UDP:1900,UDP:50000-50003,TCP:8083"
EXCLUDE_PROCESSES=""
EXCLUDE_PIDS=""
EXCLUDE_PROCESS_NOTIFY=""
CONF
"$NADAR" --list > "$TMP/list"
assert_absent "$TMP/list" '1900'
assert_absent "$TMP/list" '50001'
assert_absent "$TMP/list" '8083'
assert_contains "$TMP/list" '5353'
assert_contains "$TMP/list" '8082'

# 2: Nimirajaus koskee kaikkia saman sovelluksen PID:itä.
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES="SpOtIfY"
EXCLUDE_PIDS=""
EXCLUDE_PROCESS_NOTIFY=""
CONF
"$NADAR" --list > "$TMP/list"
assert_absent "$TMP/list" '1900'
assert_absent "$TMP/list" '5353'
assert_absent "$TMP/list" '8081'
assert_contains "$TMP/list" '8080'
assert_contains "$TMP/list" 'sshd'
assert_absent "$TMP/list" 'spotify'

# 3: PID-rajaus ei hävitä samaa nimeä käyttävää toista prosessia.
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES=""
EXCLUDE_PIDS="1567"
EXCLUDE_PROCESS_NOTIFY=""
CONF
"$NADAR" --list > "$TMP/list"
assert_absent "$TMP/list" '1900'
assert_absent "$TMP/list" '8081'
assert_contains "$TMP/list" '5353'
assert_contains "$TMP/list" '1668'
assert_contains "$TMP/list" '8080'
assert_contains "$TMP/list" 'sshd'

# 4: TCP only poistaa UDP:n myös koosteesta.
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES=""
EXCLUDE_PIDS=""
EXCLUDE_PROCESS_NOTIFY=""
CONF
"$NADAR" --summary > "$TMP/summary"
assert_absent "$TMP/summary" '1900'
assert_absent "$TMP/summary" '5353'
assert_contains "$TMP/summary" '8081'

# 5: Notify-only: prosessit näkyvät kaikissa raporteissa, mutta eivät
# aiheuta hälytystä. Testataan myös sekaomistaja ja tuntematon prosessi.
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS=""
EXCLUDE_PROCESSES=""
EXCLUDE_PIDS=""
EXCLUDE_PROCESS_NOTIFY=" SpOtIfY , firefox "
CONF
"$NADAR" --once    # ensimmäinen snapshot = baseline, ei ilmoituksia
[[ $(grep -c '^NOTIFY:' "$TMP/events" || :) == 0 ]] || fail 'baseline sent a notification'
cat >> "$TMP/fixture" <<'DATA'
tcp LISTEN 0 128 127.0.0.1:9101 0.0.0.0:* users:(("spotify",pid=1567,fd=11))
tcp LISTEN 0 128 127.0.0.1:9102 0.0.0.0:* users:(("firefox",pid=1447,fd=12))
tcp LISTEN 0 128 127.0.0.1:9103 0.0.0.0:* users:(("spotify",pid=1668,fd=13),("python3",pid=2500,fd=14))
tcp LISTEN 0 128 127.0.0.1:9104 0.0.0.0:*
tcp LISTEN 0 128 127.0.0.1:9105 0.0.0.0:* users:(("python3",pid=2500,fd=15))
tcp LISTEN 0 128 127.0.0.1:9106 0.0.0.0:* users:(("spotify",pid=1777,fd=16))
DATA
"$NADAR" --once
count=$(grep -c '^NOTIFY:' "$TMP/events" || :)
[[ $count == 3 ]] || fail "expected 3 notifications, got $count"
assert_absent "$TMP/events" '9101'
assert_absent "$TMP/events" '9102'
assert_absent "$TMP/events" '9106'
assert_contains "$TMP/events" '9103'
assert_contains "$TMP/events" '9104'
assert_contains "$TMP/events" '9105'
assert_contains "$TMP/events" 'Process: python3'
assert_absent "$TMP/events" 'Process: spotify'
assert_absent "$TMP/events" 'process=spotify'
"$NADAR" --list > "$TMP/list"
"$NADAR" --summary > "$TMP/summary"
NADAR_HTML_PATH="$TMP/report.html" "$NADAR" --summary-html >/dev/null
for report in "$TMP/list" "$TMP/summary" "$TMP/report.html"; do
  assert_contains "$report" '9101'
  assert_contains "$report" '9102'
  assert_contains "$report" '9106'
  assert_contains "$report" 'spotify'
done
"$NADAR" --once
[[ $(grep -c '^NOTIFY:' "$TMP/events" || :) == 3 ]] || fail 'unchanged ports notified again'

# 6: Kaikki rajaustavat voivat olla yhtä aikaa käytössä.
cat > "$CONF" <<'CONF'
LISTENPROTO="TCP,UDP"
EXCLUDEPORTS="UDP:1900,TCP:8083"
EXCLUDE_PROCESSES="firefox"
EXCLUDE_PIDS="1567"
EXCLUDE_PROCESS_NOTIFY="sshd"
CONF
"$NADAR" --list > "$TMP/list"
assert_absent "$TMP/list" '1900'
assert_absent "$TMP/list" '8083'
assert_absent "$TMP/list" '8082'
assert_absent "$TMP/list" '8081'
assert_contains "$TMP/list" '8080'
assert_contains "$TMP/list" 'sshd'

# 7: Kirjoitusvirhe asetuksessa ei saa jäädä huomaamatta.
printf '%s\n' 'EXCLUDE_PROCESS_NOTIFY="spotify"' 'EXCLUDE_SOMETHING="bad"' > "$CONF"
if "$NADAR" --list >/dev/null 2>"$TMP/error"; then
  fail 'unknown EXCLUDE* key accepted'
fi
assert_contains "$TMP/error" 'unknown setting'

echo 'OK: EXCLUDEPORTS, EXCLUDE_PROCESSES, EXCLUDE_PIDS, EXCLUDE_PROCESS_NOTIFY, LISTENPROTO, shared owners and no-repeat notifications'
