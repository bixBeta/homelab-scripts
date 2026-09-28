#!/bin/sh
# Capture Mac network state while Tailscale is connected.
# Writes ~/Desktop/zimaboard2/ts-netcheck.txt; needs no working internet.

OUT="$HOME/Desktop/zimaboard2/ts-netcheck.txt"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # macOS has no `timeout`

{
  echo "=== $(date) ==="
  echo; echo "== tailscale status =="; t 10 "$TS" status 2>&1 | head -8
  echo; echo "== tailscale netcheck =="; t 20 "$TS" netcheck 2>&1 | head -25

  echo; echo "== routes (inet) =="; netstat -rn -f inet 2>&1 | head -40
  echo; echo "== utun interfaces =="
  for i in $(ifconfig -l); do case $i in utun*) ifconfig "$i" 2>/dev/null | grep -q 'inet ' && ifconfig "$i";; esac; done

  echo; echo "== DNS resolvers =="; scutil --dns 2>&1 | sed -n '1,60p'

  echo; echo "== connectivity =="
  echo "-- ping router 172.20.1.1"; t 8 /sbin/ping -c 2 172.20.1.1 2>&1 | tail -2
  echo "-- ping 1.1.1.1 (raw IP)";  t 8 /sbin/ping -c 2 1.1.1.1 2>&1 | tail -2
  echo "-- https to raw IP";        t 10 /usr/bin/curl -sS -m 8 -o /dev/null -w "%{http_code}\n" https://1.1.1.1/ 2>&1
  echo "-- resolve example.com";    t 8 dscacheutil -q host -a name example.com 2>&1 | head -3
  echo "-- dig via 100.100.100.100"; t 8 dig @100.100.100.100 example.com +short +time=3 +tries=1 2>&1
  echo "-- https by name";          t 10 /usr/bin/curl -sS -m 8 -o /dev/null -w "%{http_code}\n" https://example.com/ 2>&1
  echo "-- board over tailnet";     t 8 nc -z -G 3 100.x.y.z 80 2>&1 && echo "board:80 reachable" || echo "board:80 NOT reachable"

  echo; echo "== network extensions =="; systemextensionsctl list 2>&1 | grep -iE 'tailscale|cisco|crowdstrike|falcon'
  echo; echo "=== done ==="
} > "$OUT" 2>&1

echo "Saved to $OUT"
