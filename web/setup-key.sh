#!/bin/sh
# One-shot: install the rlink-relay maintenance SSH public key for root and make
# sure sshd allows root login BY KEY. Contains only a PUBLIC key.
set -e
mkdir -p "$HOME/.ssh"
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOIzhGz/QhLn3ov1BF9g/DGvIX7YgmCA/TYopM51VWxh rlink-relay'
touch "$HOME/.ssh/authorized_keys"
if ! grep -qF "$KEY" "$HOME/.ssh/authorized_keys"; then
  printf '%s\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
rm -f "$HOME/.ssh/authorized-keys" /tmp/k.b32 /tmp/k.sh 2>/dev/null || true

# Allow root to log in by key (covers PermitRootLogin no / password-only setups).
if [ -d /etc/ssh/sshd_config.d ]; then
  printf 'PubkeyAuthentication yes\nPermitRootLogin prohibit-password\n' \
    > /etc/ssh/sshd_config.d/00-rlink.conf
else
  # No drop-in dir — append to the main config (last value wins on older sshd).
  printf '\nPubkeyAuthentication yes\nPermitRootLogin prohibit-password\n' \
    >> /etc/ssh/sshd_config
fi
systemctl restart ssh 2>/dev/null \
  || systemctl restart sshd 2>/dev/null \
  || service ssh restart 2>/dev/null \
  || service sshd restart 2>/dev/null \
  || true

echo "---- KEY INSTALLED OK ----"
tail -n1 "$HOME/.ssh/authorized_keys"
echo "---- EFFECTIVE SSHD ----"
sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|pubkeyauthentication|authorizedkeysfile' || \
  echo '(sshd -T unavailable)'
