#!/usr/bin/env bash
#
# make authorize-key KEY='ssh-ed25519 AAAA... you@laptop'
#
# Lets a workstation key log in to the head node as you and to every node as
# root. Nodes get root's keys from the Warewulf ssh.authorized_keys overlay,
# which is rendered from the head node's /root/.ssh/authorized_keys, so the key
# goes there and the overlays are rebuilt. A running node picks it up within a
# minute (wwclient refreshes runtime overlays); a booting one has it at once.
#
# The key is host state, never repo state: it is written on the lab host only.

export LAB_SCRIPT_NAME=authorize-key
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

KEY="${KEY:-}"
[[ -n "$KEY" ]] || die "usage: make authorize-key KEY='ssh-ed25519 AAAA... comment'"
printf '%s\n' "$KEY" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1 \
  || die "KEY is not an ssh public key"
blob="$(awk '{print $2}' <<<"$KEY")"

add_key() {  # add_key <authorized_keys> <owner> [sudo]
  local file="$1" owner="$2" sudo="${3:-}"
  $sudo install -d -m 0700 -o "$owner" -g "$owner" "$(dirname "$file")"
  if $sudo grep -qF "$blob" "$file" 2>/dev/null; then
    ok "already in $file"
  else
    printf '%s\n' "$KEY" | $sudo tee -a "$file" >/dev/null
    $sudo chown "$owner:$owner" "$file"
    $sudo chmod 0600 "$file"
    changed "added to $file"
  fi
}

add_key "$HOME/.ssh/authorized_keys" "$(id -un)"
add_key /root/.ssh/authorized_keys root sudo
sudo wwctl overlay build >/dev/null
ok "node overlays rebuilt; nodes accept the key as root"
