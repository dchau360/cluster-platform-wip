#!/usr/bin/env bash
#
# Preflight. Confirms the lab host can run the harness, and creates the
# state directories. Safe to run any number of times.

export LAB_SCRIPT_NAME=preflight
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lab_load_env

missing=()
for t in virsh qemu-system-x86_64 qemu-img dnsmasq ip ansible docker; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
(( ${#missing[@]} == 0 )) || die "missing tools: ${missing[*]} — see docs/lab-host-setup.md"
ok "required tools present"

[[ -c /dev/kvm ]] || die "/dev/kvm missing — enable nested virtualization"
ok "/dev/kvm present"

[[ -f "$OVMF_CODE" ]] || die "OVMF firmware not found at $OVMF_CODE"
[[ -f "$OVMF_VARS" ]] || die "OVMF vars template not found at $OVMF_VARS"
ok "OVMF firmware present"

if [[ "$(systemctl is-system-running 2>/dev/null || true)" =~ ^(running|degraded)$ ]]; then
  ok "systemd is running"
else
  die "systemd is not running in this WSL distribution — set systemd=true in /etc/wsl.conf"
fi

sudo -n true 2>/dev/null || die "passwordless sudo is required"
ok "passwordless sudo"

LAB_OWNER="${LAB_WSL_USER:-$USER}"
ensure_dir "$LAB_STATE_DIR"            0755
ensure_dir "$LAB_TFTP_DIR"             0755
ensure_dir "$LAB_RUN_DIR"              0755 "$LAB_OWNER"
ensure_dir "$LAB_TIMING_DIR"           0755 "$LAB_OWNER"
ensure_dir "$LAB_STATE_DIR/dnsmasq"    0755
ensure_dir "$LAB_VM_DIR"               0711
ensure_dir "$LAB_VM_DIR/nvram"         0711

if systemctl is-active --quiet libvirtd || systemctl is-active --quiet libvirtd.socket; then
  ok "libvirt unit is active"
else
  sudo systemctl start libvirtd.socket 2>/dev/null || sudo systemctl start libvirtd
  changed "libvirt started"
fi

# Unit active is not the same as ready to answer. Straight after a cold
# start libvirtd accepts the socket before it has finished initialising,
# and `virsh start` fails with a systemd scope error. Wait for a real
# answer, not for a unit state. This was a live failure, not a theory.
deadline=$(( $(date +%s) + 60 ))
until sudo virsh --connect "$LIBVIRT_URI" list --all >/dev/null 2>&1; do
  (( $(date +%s) < deadline )) || die "libvirt did not answer on $LIBVIRT_URI within 60s"
  sleep 1
done
ok "libvirt answers on $LIBVIRT_URI"

# `make up` must work after a cold start with no manual step, so the
# daemons the lab depends on are enabled at boot, not merely running now.
ensure_unit_enabled libvirtd.socket
ensure_unit_enabled docker.service

if [[ ! -f "$LAB_ENV_FILE" ]]; then
  warn "no $LAB_ENV_FILE — running on example defaults.
     Host-specific checks such as 'make verify-isolation' need it.
     cp lab/local.env.example lab/local.env"
fi
