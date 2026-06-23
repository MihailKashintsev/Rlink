#!/bin/sh
echo "== KEY POLICY =="
sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|pubkeyauth|usepam|authenticationmethods|allowusers|denyusers|allowgroups|denygroups' || echo '(sshd -T failed)'
echo "== ACCESS.CONF =="
grep -vE '^#|^[[:space:]]*$' /etc/security/access.conf 2>/dev/null || echo 'empty/none'
echo "== PAM sshd account lines =="
grep -nE '^[^#].*account' /etc/pam.d/sshd 2>/dev/null || echo 'none'
echo "== ROOT shadow status =="
passwd -S root 2>/dev/null || echo '(passwd -S n/a)'
echo "== >>> LAST SSHD DENIAL REASON (read this) <<< =="
( journalctl -u ssh --no-pager 2>/dev/null | tail -400 \
  || journalctl -u sshd --no-pager 2>/dev/null | tail -400 \
  || tail -400 /var/log/auth.log 2>/dev/null ) \
  | grep -Ei 'refus|denied|not allowed|locked|expired|pam_|preauth|authentication failure|publickey for root|accepted publickey' \
  | tail -15
echo "== END WHY =="
