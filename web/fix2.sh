#!/bin/sh
# Likely cause: OpenSSH PerSourcePenalties blocks our IP after brute-force noise
# (localhost is exempt -> local key login works, remote doesn't). Disable it
# safely (validate config before restart so we never lock ourselves out).

echo "== OpenSSH version =="
ssh -V 2>&1 | head -1

echo "== per-source / startup settings =="
sshd -T 2>/dev/null | grep -Ei 'persource|maxstartups' || echo '(none reported)'

if sshd -T 2>/dev/null | grep -qi 'persourcepenalties'; then
  echo "== feature present -> disabling PerSourcePenalties =="
  printf 'PerSourcePenalties no\n' > /etc/ssh/sshd_config.d/10-nopenalty.conf
  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    echo 'PerSourcePenalties disabled + sshd restarted (penalty state cleared)'
  else
    rm -f /etc/ssh/sshd_config.d/10-nopenalty.conf
    echo 'CONFIG TEST FAILED -> reverted, no restart'
  fi
else
  echo "== this sshd has NO PerSourcePenalties -> cause is elsewhere =="
  echo "-- checking hosts.allow/deny (tcpwrappers) --"
  grep -vE '^#|^[[:space:]]*$' /etc/hosts.deny 2>/dev/null || echo 'hosts.deny empty'
  grep -vE '^#|^[[:space:]]*$' /etc/hosts.allow 2>/dev/null || echo 'hosts.allow empty'
  echo "-- any Match Address blocks anywhere --"
  grep -RInE '^[[:space:]]*Match' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || echo 'no Match blocks'
fi

echo "== dedupe maintenance key =="
awk '!seen[$0]++' /root/.ssh/authorized_keys > /tmp/ak 2>/dev/null && mv /tmp/ak /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "rlink-relay key lines: $(grep -c rlink-relay /root/.ssh/authorized_keys)"
echo "== END FIX2 =="
