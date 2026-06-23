#!/bin/sh
# Decisive test: does root pubkey login work AT ALL (server -> itself)?
# If LOCAL_SSH_OK prints, pubkey is fine and the remote problem is network/IP.
# If it fails, the log right below shows the exact server-side reason.
TK=/tmp/rlink_test_key
rm -f "$TK" "$TK.pub"
if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
  echo "NO ssh client on host — installing openssh-client..."
  apt-get update -y >/dev/null 2>&1
  apt-get install -y openssh-client >/dev/null 2>&1 || echo "apt install failed"
fi
ssh-keygen -t ed25519 -N '' -f "$TK" -q
mkdir -p /root/.ssh
cat "$TK.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "== LOCAL PUBKEY TEST (root@localhost) =="
ssh -i "$TK" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o BatchMode=yes -o ConnectTimeout=8 root@localhost \
    'echo LOCAL_SSH_OK; whoami; hostname' 2>&1 | tail -6
echo "== sshd log for THIS local test =="
sleep 1
( journalctl -u ssh -n 20 --no-pager 2>/dev/null \
  || journalctl _COMM=sshd -n 20 --no-pager 2>/dev/null ) \
  | grep -Ei '127.0.0.1|localhost|publickey|accepted|fail|refus|denied|pam_' | tail -12
# cleanup the temp test key from authorized_keys
if [ -f "$TK.pub" ]; then
  grep -vxF "$(cat "$TK.pub")" /root/.ssh/authorized_keys > /tmp/ak.tmp 2>/dev/null \
    && mv /tmp/ak.tmp /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
rm -f "$TK" "$TK.pub"
echo "== rlink-relay maintenance key still present? =="
grep -c 'rlink-relay' /root/.ssh/authorized_keys 2>/dev/null
echo "== END SELFTEST =="
