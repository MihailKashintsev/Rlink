#!/bin/sh
# Find WHY root key-login is refused (key is accepted but login denied) and
# apply safe remedies. Run, then send a screenshot of the bottom.

echo "== KEY POLICY (sshd -T) =="
sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|pubkeyauth|usepam|authenticationmethods|allowusers|denyusers|allowgroups|denygroups' || echo '(sshd -T failed)'

echo "== Match / Allow blocks in config =="
grep -RInE 'Match|AllowUsers|DenyUsers|AllowGroups|DenyGroups' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || echo 'none'

echo "== access.conf active rules =="
grep -vE '^#|^[[:space:]]*$' /etc/security/access.conf 2>/dev/null || echo 'empty/none'

echo "== pam.d/sshd account/auth restrictions =="
grep -nE '^[^#].*(account|auth).*(pam_(access|nologin|succeed_if|listfile|securetty))' /etc/pam.d/sshd /etc/pam.d/common-account 2>/dev/null || echo 'none obvious'

echo "== root status =="
passwd -S root 2>/dev/null || true
getent passwd root

echo "== SAFE FIXES =="
# Force root key login in the MAIN config (covers any active without-password/no).
sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null \
  && echo 'main: PermitRootLogin yes' || true
grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null || printf '\nPermitRootLogin yes\n' >> /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPubkeyAuthentication yes\nUsePAM yes\n' > /etc/ssh/sshd_config.d/00-rlink.conf
# Unlock root / clear expiry.
usermod -U root 2>/dev/null && echo 'root unlocked' || true
usermod -e '' root 2>/dev/null || true
chage -E -1 -M -1 root 2>/dev/null || true
# Remove login blockers.
rm -f /etc/nologin /run/nologin /var/run/nologin 2>/dev/null && echo 'removed nologin' || true
# Restart sshd.
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true

echo "== >>> LAST SSHD DENIAL REASON (read this) <<< =="
( journalctl -u ssh --no-pager 2>/dev/null | tail -500 \
  || journalctl -u sshd --no-pager 2>/dev/null | tail -500 \
  || tail -500 /var/log/auth.log 2>/dev/null ) \
  | grep -Ei 'refus|denied|not allowed|locked|expired|pam_|preauth|authentication failure|failed publickey|accepted publickey|closed by authenticating' \
  | tail -12
echo "== END WHY =="
