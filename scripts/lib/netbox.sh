#!/usr/bin/env bash
# shellcheck shell=bash
#
# Minimal read/write access to the lab's NetBox, for the acceptance drills.
#
# The platform owns this NetBox and generates its runtime API token into
# /etc/cluster-lab/netbox.env. The token is read from that file and passed to
# curl through the environment; it is never printed, never written to a
# tracked file, and never appears in the drill output. Only the objects the
# drills ask about are printed.
#
# This is deliberately small: the drills need "what does NetBox call this
# node, and what MAC does it hold", not a client library. The platform's real
# NetBox integration lives in ansible/roles/netbox.

# netbox_runtime_token — the composite token the NetBox role generates.
#
# The file is under /etc/cluster-lab, which is mode 0700 root:root, so an
# unprivileged `[[ -f ]]` is false and must not be the gate. `sudo sed` is
# the whole read; the key and token are only ever held in this shell.
# Prints nothing and returns non-zero when the file is absent or unreadable.
netbox_runtime_token() {
  local env_file=/etc/cluster-lab/netbox.env key token
  key="$(sudo sed -n 's/^SUPERUSER_API_KEY=//p' "$env_file" 2>/dev/null | head -1)"
  token="$(sudo sed -n 's/^SUPERUSER_API_TOKEN=//p' "$env_file" 2>/dev/null | head -1)"
  [[ -n "$key" && -n "$token" ]] || return 1
  printf 'nbt_%s.%s' "$key" "$token"
}

# netbox_get <api-path> — GET and print the JSON body.
netbox_get() {
  local path="$1" token
  token="$(netbox_runtime_token)" || return 1
  curl -fsS -H "Authorization: Token $token" -H 'Accept: application/json' \
    "http://127.0.0.1:8000$path"
}

# netbox_patch <api-path> <json> — PATCH and print the JSON body.
netbox_patch() {
  local path="$1" body="$2" token
  token="$(netbox_runtime_token)" || return 1
  curl -fsS -X PATCH -H "Authorization: Token $token" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -d "$body" "http://127.0.0.1:8000$path"
}
