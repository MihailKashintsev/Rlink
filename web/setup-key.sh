#!/bin/sh
# One-shot: install the rlink-relay maintenance SSH public key for root so the
# assistant can connect by key (no password). Contains only a PUBLIC key.
set -e
mkdir -p "$HOME/.ssh"
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOIzhGz/QhLn3ov1BF9g/DGvIX7YgmCA/TYopM51VWxh rlink-relay'
touch "$HOME/.ssh/authorized_keys"
if ! grep -qF "$KEY" "$HOME/.ssh/authorized_keys"; then
  printf '%s\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
# Clean up earlier broken attempts (hyphen filename / temp files).
rm -f "$HOME/.ssh/authorized-keys" /tmp/k.b32 /tmp/k.sh 2>/dev/null || true
echo "---- KEY INSTALLED OK ----"
tail -n1 "$HOME/.ssh/authorized_keys"
