#!/bin/sh
# Install the new passphrase-less maintenance SSH public key for root.
# (The previous key was passphrase-protected, so non-interactive login failed.)
# Contains only a PUBLIC key.
set -e
mkdir -p "$HOME/.ssh"
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIlupeVExU++svNp+55W+oksJBymWnLttYCwrIhVs7YH rlink-relay2'
touch "$HOME/.ssh/authorized_keys"
if ! grep -qF "$KEY" "$HOME/.ssh/authorized_keys"; then
  printf '%s\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
echo "---- NEW KEY INSTALLED ----"
grep -c 'rlink-relay2' "$HOME/.ssh/authorized_keys"
tail -n2 "$HOME/.ssh/authorized_keys"
echo "---- DONE ----"
