#!/bin/sh
# Copy files from a machine that can only reach your tailnet outbound — a
# cluster login node, a box behind a corporate VPN — to any tailnet machine
# that accepts your SSH key.
#
#   sh push-to-tailnet.sh SRC DEST
#   sh push-to-tailnet.sh results/ zima:/media/sda2/pipeline_out/
#   sh push-to-tailnet.sh results/ 100.x.y.z:/media/sda2/pipeline_out/
#   sh push-to-tailnet.sh -n results/ zima:/data/          # dry run
#
# SRC   a file or directory. A trailing slash on a directory copies its
#       *contents*; without one, the directory itself lands inside DEST.
# DEST  [user@]host:/path — host is a tailnet name or 100.x address.
#       A bare /path uses $TAILNET_HOST.
#
# Starts tailscaled in userspace mode if it isn't running, and routes SSH
# through its SOCKS proxy, because a userspace node has no tun device and
# cannot make ordinary outbound connections.
#
# Options:
#   -n  dry run: list what would transfer, change nothing
#   -k  keep symlinks as links (default: send what they point at, which is
#       what Nextflow publishDir output needs)
#   -q  quiet: no per-file progress
#   -h  help
#
# Env: TS_DIR (default ~/.tailscale), TS_BIN (default ~/bin), SOCKS_PORT
#      (default 1055), TAILNET_HOST, SSH_KEY (default ~/.ssh/id_ed25519).

set -eu

TS_DIR=${TS_DIR:-$HOME/.tailscale}
TS_BIN=${TS_BIN:-$HOME/bin}
SOCKS_PORT=${SOCKS_PORT:-1055}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
SOCK="$TS_DIR/sock"
STATE="$TS_DIR/state"

DRY=""; DEREF="-L"; PROGRESS="--info=progress2"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "nkqh" opt 2>/dev/null; do
  case "$opt" in
    n) DRY="--dry-run" ;;
    k) DEREF="" ;;
    q) PROGRESS="" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))

[ $# -eq 2 ] || { echo "need SRC and DEST" >&2; usage 1; }
SRC=$1
DEST=$2

# A bare path needs a default host.
case "$DEST" in
  *:*) ;;
  *)
    [ -n "${TAILNET_HOST:-}" ] || { echo "DEST has no host and TAILNET_HOST is unset" >&2; exit 1; }
    DEST="$TAILNET_HOST:$DEST"
    ;;
esac

[ -e "$SRC" ] || { echo "no such source: $SRC" >&2; exit 1; }

# --- tailscaled -----------------------------------------------------------
if [ ! -x "$TS_BIN/tailscaled" ]; then
  echo "tailscaled not found at $TS_BIN/tailscaled" >&2
  echo "install it without root:" >&2
  echo "  mkdir -p $TS_BIN && cd $TS_BIN && curl -fsSL -O https://pkgs.tailscale.com/stable/tailscale_1.102.4_amd64.tgz && tar -xzf tailscale_1.102.4_amd64.tgz --strip-components=1 tailscale_1.102.4_amd64/tailscale tailscale_1.102.4_amd64/tailscaled" >&2
  exit 1
fi

socks_up() { (exec 3<>/dev/tcp/127.0.0.1/"$SOCKS_PORT") 2>/dev/null; }

if ! socks_up; then
  echo "starting tailscaled (userspace, SOCKS on $SOCKS_PORT)..."
  mkdir -p "$TS_DIR"
  nohup "$TS_BIN/tailscaled" --tun=userspace-networking \
    --socks5-server=localhost:"$SOCKS_PORT" \
    --state="$STATE" --socket="$SOCK" > "$TS_DIR/daemon.log" 2>&1 &
  i=0
  while [ $i -lt 15 ] && ! socks_up; do sleep 1; i=$((i + 1)); done
  socks_up || { echo "tailscaled did not open the SOCKS port; see $TS_DIR/daemon.log" >&2; exit 1; }
fi

# Logged in? The state file survives restarts, so this is usually a no-op.
if ! "$TS_BIN/tailscale" --socket="$SOCK" status >/dev/null 2>&1; then
  echo "tailscale is not logged in. Run this, open the URL it prints, then retry:" >&2
  echo "  $TS_BIN/tailscale --socket=$SOCK up --hostname=\$(hostname -s)" >&2
  exit 1
fi

# --- SSH through the SOCKS proxy ------------------------------------------
# Pick whichever proxy-capable tool exists; their flags all differ.
if command -v ncat >/dev/null 2>&1; then
  PROXY="ncat --proxy-type socks5 --proxy 127.0.0.1:$SOCKS_PORT %h %p"
elif nc -h 2>&1 | grep -q -- '-X'; then
  PROXY="nc -X 5 -x 127.0.0.1:$SOCKS_PORT %h %p"
elif command -v socat >/dev/null 2>&1; then
  PROXY="socat - SOCKS5:127.0.0.1:%h:%p,socksport=$SOCKS_PORT"
else
  echo "need ncat, an nc with -X, or socat to reach the SOCKS proxy" >&2
  exit 1
fi

SSH_CMD="ssh -o ProxyCommand='$PROXY' -o StrictHostKeyChecking=accept-new"
[ -f "$SSH_KEY" ] && SSH_CMD="$SSH_CMD -i $SSH_KEY -o IdentitiesOnly=yes"

# --- transfer -------------------------------------------------------------
# No --delete, ever: a push never removes anything on the far side.
# --no-perms/-owner/-group: the destination may be a share that cannot store them.
echo "pushing: $SRC -> $DEST"
set -x
rsync -rt --partial $DRY $PROGRESS $DEREF \
  --no-perms --no-owner --no-group \
  -e "$SSH_CMD" \
  "$SRC" "$DEST"
