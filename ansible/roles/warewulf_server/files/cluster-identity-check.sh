#!/bin/bash
#
# cluster-identity-check — prove the per-node identity material is present.
#
# This runs *inside the booted node*, from a Warewulf runtime overlay, after
# the overlay has been applied. It is the evidence for the identity criterion:
# the runtime overlay was not merely built and served, it landed on the node.
#
# It never prints key material. Private keys are reported by path, mode, owner
# and size; SSH host keys additionally by their public fingerprint, which
# `ssh-keygen -l` derives without the private bytes leaving the node. The one
# digest it prints is the Munge key's SHA-256, so two nodes can be compared
# without either key leaving the node.
#
# The unit sends stdout to the journal *and* the serial console, so the boot
# transcript is itself the proof.

set -u

# The files the identity criterion names. The SSH host keys are generated
# per node by warewulf's built-in `ssh.host_keys` system overlay; the Munge
# key is the cluster-wide secret delivered by the cluster-identity runtime
# overlay.
IDENTITY_FILES=(
  /etc/munge/munge.key
  /etc/ssh/ssh_host_ed25519_key
  /etc/ssh/ssh_host_ecdsa_key
  /etc/ssh/ssh_host_rsa_key
)

status=0

echo "=== cluster identity check ==="

for f in "${IDENTITY_FILES[@]}"; do
  if [[ -e "$f" ]]; then
    stat -c 'present %n mode=%a owner=%u:%g size=%s' "$f"
  else
    echo "MISSING $f"
    status=1
  fi
done

# Public fingerprints only, and only for keys that exist.
shopt -s nullglob
for pub in /etc/ssh/ssh_host_*_key.pub; do
  ssh-keygen -l -f "$pub" || status=1
done

if [[ -r /etc/munge/munge.key ]]; then
  digest="$(sha256sum /etc/munge/munge.key | awk '{print $1}')"
  echo "munge-key sha256=${digest}"
else
  echo "munge-key sha256=unreadable"
  status=1
fi

echo "=== end cluster identity check ==="

exit "$status"
