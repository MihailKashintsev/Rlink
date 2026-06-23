#!/bin/sh
# Diagnose + safely fix why root key-login is refused even though the key is
# accepted. Safe to run repeatedly.

echo "== sshd -T (auth-related) =="
sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|pubkeyauth|usepam|allowusers|denyusers|allowgroups|denygroups|authenticationmethods|authorizedkeysfile' \
  || echo '(sshd -T failed)'

echo "== Match/Allow blocks in config =="
grep -RInE 'Match|AllowUsers|DenyUsers|AllowGroups|DenyGroups' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
  || echo 'none'

echo "== root passwd line (shell) =="
getent passwd root

echo "== root account status / expiry =="
passwd -S root 2>/dev/null || true
chage -l root 2>/dev/null | grep -Ei 'expire|password' || true

echo "== nologin files =="
ls -la /etc/nologin /run/nologin /var/run/nologin 2>/dev/null || echo 'none'

echo "== access.conf active rules =="
grep -vE '^#|^[[:space:]]*$' /etc/security/access.conf 2>/dev/null || echo 'none/empty'

echo "== /root + authorized_keys perms =="
ls -ld /root /root/.ssh 2>/dev/null
ls -l /root/.ssh/authorized_keys 2>/dev/null

echo "== RECENT SSHD LOG (the real reason) =="
( journalctl -u ssh -n 40 --no-pager 2>/dev/null \
  || journalctl -u sshd -n 40 --no-pager 2>/dev/null \
  || tail -n 60 /var/log/auth.log 2>/dev/null ) \
  | grep -Ei 'sshd|root|denied|refus|accept|fail|pam|not allowed|expired' | tail -30

echo "== APPLYING SAFE FIXES =="
# Remove account expiry / lock-by-expiry for root.
usermod -e '' root 2>/dev/null && echo 'cleared root expiry' || true
chage -E -1 -M -1 root 2>/dev/null && echo 'cleared chage expiry/maxdays' || true
# Ensure root has a real shell.
cur_shell=$(getent passwd root | cut -d: -f7)
case "$cur_shell" in
  */nologin|*/false|"")
    usermod -s /bin/bash root 2>/dev/null && echo "fixed root shell -> /bin/bash" || true
    ;;
  *) echo "root shell ok: $cur_shell" ;;
esac

echo "== DONE FIXSSH =="
