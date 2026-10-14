#!/usr/bin/env bash
# Offline regression tests for the root-owned remote scanner's input validation.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCAN="$ROOT/remote/nadar-scan"
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$SCAN" || fail 'scanner syntax'
for cmd in \
  'tcp 0 198.51.100.4' \
  'tcp 65536 198.51.100.4' \
  'udp 22 999.51.100.4' \
  'tcp 22 198.51.100.4;id' \
  'tcp 22,-sS 198.51.100.4' \
  'tcp 22, 198.51.100.4' \
  'bogus 22 198.51.100.4' \
  'tcp 22 example.com'; do
  # Test commands are fixed literals; split on whitespace to exercise argv parsing.
  read -r -a args <<< "$cmd"
  if "$SCAN" "${args[@]}" >/dev/null 2>&1; then fail "accepted invalid scanner arguments: $cmd"; fi
done

# More than 128 ports is rejected before Nmap or privilege handling.
port_csv=$(seq -s, 1 129)
if "$SCAN" tcp "$port_csv" 198.51.100.4 > /dev/null 2>&1; then
  fail 'accepted more than 128 ports'
fi

grep -Fq 'NOPASSWD: /usr/local/libexec/nadar-scan' "$ROOT/remote/nadar-scan.sudoers" || fail 'sudoers template missing restricted executable'
! grep -Eq '^santeri.*NOPASSWD:.*(/usr/bin/nmap|ALL)' "$ROOT/remote/nadar-scan.sudoers" || fail 'unrestricted sudo command'
printf 'OK: scanner argument validation, 128-port bound, sudoers command restriction\n'
