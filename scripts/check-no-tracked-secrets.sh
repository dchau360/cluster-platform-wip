#!/usr/bin/env bash
#
# The secret and state boundaries, as a gate.
#
# gitleaks catches secrets by content. This catches them by shape, which is
# the other half: a tracked file whose NAME says it holds key material is a
# finding even if the file is empty or still a placeholder, because the next
# commit fills it in and that commit is the one nobody reads carefully.
#
# .gitignore is not this gate. `git add -f` ignores .gitignore; nothing
# ignores a failing build.

set -euo pipefail

# Needs bash 4 (mapfile). Say so plainly: a gate that dies with
# "mapfile: command not found" looks broken rather than unsupported.
# macOS ships bash 3.2; use `brew install bash`.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer required, found $BASH_VERSION" >&2
  exit 2
fi
cd "$(git rev-parse --show-toplevel)"

findings=0
finding() { findings=$((findings + 1)); printf 'FAIL %s\n' "$*"; }
pass()    { printf 'ok   %s\n' "$*"; }

# Names that may never be tracked, whatever they contain. Key material for
# this lab is generated on the host and delivered by a Warewulf per-node
# overlay at boot, so none of these has a legitimate reason to exist here.
FORBIDDEN_NAMES=(
  'munge\.key$'
  'ssh_host_.*'
  'id_rsa($|\.)'
  'id_ed25519($|\.)'
  'id_ecdsa($|\.)'
  '\.pem$'
  '\.p12$'
  '\.jks$'
  '\.key$'
  '\.vault$'
  'vault-pass'
  '(^|/)\.env$'
  '(^|/)local\.env$'
)

mapfile -t TRACKED < <(git ls-files)

echo "== check 1: no file whose name says it holds key material"
before=$findings
for pat in "${FORBIDDEN_NAMES[@]}"; do
  for f in "${TRACKED[@]}"; do
    if [[ "$f" =~ $pat ]]; then
      finding "tracked file matches forbidden name pattern /$pat/: $f"
    fi
  done
done
(( findings > before )) || pass "no tracked file is named like key material"

echo
echo "== check 2: no lab state is tracked"
# Lab state lives under LAB_STATE_DIR, outside the repo. A disk image or a
# TFTP tree in git is both a large file forever and a disclosure risk: a
# node image carries whatever was baked into it.
#
# `*.fd` covers the OVMF nvram files (OVMF_VARS_4M.fd) as well; a separate
# `*_VARS.fd` arm is unreachable, and shellcheck says so (SC2222).
before=$findings
for f in "${TRACKED[@]}"; do
  case "$f" in
    *.qcow2|*.img|*.iso|*.squashfs|*.raw|*.vmdk|*.vhdx|\
    *.fd|*.nvram|\
    *.retry|\
    *.tar|*.tar.gz|*.tar.zst|*.cpio|*.cpio.gz|\
    vmlinuz*|initramfs*|initrd*|\
    */tftp/*|tftp/*|*/leases/*|*.leases|\
    *netbox*.sql|*netbox*.dump|*.sql.gz)
      finding "tracked lab state or artefact: $f" ;;
  esac
done
(( findings > before )) || pass "no lab state or build artefact is tracked"

echo
if (( findings > 0 )); then
  echo "RESULT: $findings finding(s). Key material comes from a Warewulf overlay at boot, never from git; lab state lives in LAB_STATE_DIR, never in git."
  exit 1
fi
echo "RESULT: no secret material and no lab state is tracked"
