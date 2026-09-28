#!/bin/sh
# Run ON OMARCHY, as your normal user (not root), from a terminal inside your
# Hyprland session. Authorizes the Mac's clipboard-only key (paste it into PUBKEY below) and installs the
# forced-command handler it is pinned to. Safe to re-run.
set -eu

PUBKEY='ssh-ed25519 AAAA...PASTE_YOUR_MACS_PUBLIC_KEY... you@yourmac'

if ! command -v wl-copy >/dev/null 2>&1; then
  echo "Installing wl-clipboard..."
  sudo pacman -S --needed --noconfirm wl-clipboard
fi

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/clipd" <<'HANDLER'
#!/bin/sh
# Forced command for the Mac's clipboard key. Accepts only `copy` and
# `paste`; anything else is refused, so the key can never open a shell.

# An SSH session has no Wayland environment. Point it at the running
# Hyprland session's socket.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
sock=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 -E '^wayland-[0-9]+$' || true)
if [ -z "$sock" ]; then
  echo "clipd: no Wayland session running for $(id -un)" >&2
  exit 2
fi
export WAYLAND_DISPLAY="$sock"

case "${SSH_ORIGINAL_COMMAND:-}" in
  copy)
    # wl-copy forks a background process to own the selection. Detach its
    # stdout/stderr so the SSH session can close instead of hanging.
    exec wl-copy >/dev/null 2>&1
    ;;
  paste)
    # -n: don't append a newline that wasn't in the clipboard.
    exec wl-paste -n 2>/dev/null
    ;;
  *)
    echo "clipd: only 'copy' and 'paste' are allowed" >&2
    exit 1
    ;;
esac
HANDLER
chmod 755 "$HOME/.local/bin/clipd"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

KEYBODY=$(echo "$PUBKEY" | awk '{print $2}')
# Drop any earlier entry for this key, then add the restricted one.
grep -v "$KEYBODY" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp" || true
mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
echo "command=\"$HOME/.local/bin/clipd\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding $PUBKEY" \
  >> "$HOME/.ssh/authorized_keys"

echo
echo "Done. Tell Claude this username: $(id -un)"
