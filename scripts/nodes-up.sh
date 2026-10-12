#!/usr/bin/env bash
#
# Define and start NODE_COUNT UEFI nodes on the provisioning segment.
#
# Each node is a q35 machine with OVMF firmware, one virtio disk, and one
# NIC on the isolated bridge with network first in the boot order, so it
# PXE-boots. Nothing here knows how many nodes there are: `N=2` and `N=4`
# differ only in the loop bound.

export LAB_SCRIPT_NAME=nodes-up
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
# shellcheck source=lib/boot-phases.sh
source "$HERE/lib/boot-phases.sh"
lab_load_env

export LIBVIRT_DEFAULT_URI="$LIBVIRT_URI"
VIRSH=(sudo virsh --connect "$LIBVIRT_URI")

domain_exists() { "${VIRSH[@]}" dominfo "$1" >/dev/null 2>&1; }
domain_running() { [[ "$("${VIRSH[@]}" domstate "$1" 2>/dev/null || true)" == running ]]; }

render_domain_xml() {
  local name="$1" mac="$2" disk="$3" nvram="$4"
  cat <<EOF
<domain type='kvm'>
  <name>${name}</name>
  <memory unit='MiB'>${NODE_MEM_MB}</memory>
  <vcpu>${NODE_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>${OVMF_CODE}</loader>
    <nvram template='${OVMF_VARS}'>${nvram}</nvram>
    <boot dev='network'/>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none' migratable='off'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' discard='unmap'/>
      <source file='${disk}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <controller type='pci' index='0' model='pcie-root'/>
    <interface type='bridge'>
      <mac address='${mac}'/>
      <source bridge='${PROV_BRIDGE}'/>
      <model type='virtio'/>
    </interface>
    <serial type='file'>
      <source path='${LAB_VM_DIR}/console/${name}.log'/>
      <target port='0'/>
    </serial>
    <console type='file'>
      <source path='${LAB_VM_DIR}/console/${name}.log'/>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <video><model type='virtio'/></video>
    <memballoon model='virtio'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
EOF
}

ensure_dir "$LAB_VM_DIR"         0711
ensure_dir "$LAB_VM_DIR/nvram"   0711
ensure_dir "$LAB_VM_DIR/console" 0711
ensure_dir "$LAB_STATE_DIR/xml"  0755

log "bringing up ${NODE_COUNT} node(s)"

# Decide which nodes this run will actually boot, BEFORE booting any of them,
# and drop their old leases first. The dhcp-lease phase is only honest if the
# lease it finds cannot be one from a previous run.
declare -A STARTED_FRESH=()
declare -A BOOT_WATCH_PID=()
forget_macs=()
for i in $(lab_node_indexes); do
  name="$(node_name "$i")"
  if ! domain_running "$name"; then
    STARTED_FRESH["$name"]=1
    forget_macs+=("$(node_mac "$i")")
  fi
done
# An `&&` one-liner here would exit the script under `set -e` when the array
# is empty, which is the ordinary case of "everything is already running".
if (( ${#forget_macs[@]} > 0 )); then
  lease_forget "${forget_macs[@]}"
fi

for i in $(lab_node_indexes); do
  name="$(node_name "$i")"
  mac="$(node_mac "$i")"
  disk="$LAB_VM_DIR/${name}.qcow2"
  nvram="$LAB_VM_DIR/nvram/${name}.fd"
  xml="$LAB_STATE_DIR/xml/${name}.xml"

  phase_begin node-define "$name"

  if sudo test -f "$disk"; then
    ok "disk $name"
  else
    sudo qemu-img create -q -f qcow2 "$disk" "${NODE_DISK_GB}G"
    changed "disk $name created (${NODE_DISK_GB}G)"
  fi

  changes_before="$(counters_changed)"
  render_domain_xml "$name" "$mac" "$disk" "$nvram" | ensure_file_content "$xml" 0644
  xml_changed=0
  [[ "$(counters_changed)" == "$changes_before" ]] || xml_changed=1

  if domain_exists "$name" && (( xml_changed == 0 )); then
    ok "domain $name defined"
  else
    # Redefining a running domain updates the persistent config only; the
    # new definition takes effect at its next boot.
    "${VIRSH[@]}" define "$xml" >/dev/null
    changed "domain $name defined"
  fi
  phase_end node-define "$name"

  phase_begin node-start "$name"
  console_log="$LAB_VM_DIR/console/${name}.log"
  if domain_running "$name"; then
    ok "domain $name running"
  else
    # libvirt writes the per-domain console to this file from byte zero on
    # every start (the size before the start does not survive), so clear it
    # ourselves and have the watcher read from byte zero. Only for a node we
    # are actually starting: truncating a running node's console would throw
    # away the boot being observed.
    sudo truncate -s 0 "$console_log" 2>/dev/null || true

    # Retry, because on a cold start systemd-machined can still be coming
    # up when libvirt asks it to register the machine scope, and the start
    # fails with "Start job for unit machine-qemu-...scope failed". It is a
    # readiness race, not a configuration error, so it clears on a retry.
    started=0
    for attempt in 1 2 3; do
      if "${VIRSH[@]}" start "$name" >/dev/null 2>&1; then started=1; break; fi
      warn "start of $name failed (attempt $attempt) — retrying"
      sleep 5
    done
    (( started == 1 )) || die "could not start domain $name after 3 attempts"
    changed "domain $name started"
    # Observe the boot in the background so it can run while the DHCP wait
    # below and the next node's start proceed in parallel.
    boot_phases_watch "$name" "$console_log" 0 &
    BOOT_WATCH_PID["$name"]=$!
  fi
  phase_end node-start "$name"

  if [[ -z "${STARTED_FRESH[$name]-}" ]]; then
    boot_phases_skip "$name" "already running; no new boot to measure"
  fi
done

# A DHCP lease from our dnsmasq is the first externally observable proof
# that the segment carries traffic. Later tasks extend the chain from here
# to TFTP, GRUB and a booted image, reusing the same phase names.
#
# The wait is parallel, and that is not an optimisation. The nodes boot at
# the same time and contend for one dnsmasq, so waiting for them one at a
# time would add each node's delay to the next node's measurement and
# manufacture a linear 1-to-N curve out of nothing. The contention is the
# thing being measured, so it has to be observed as it happens.
#
# Only a node that this run actually started can be measured. A node that was
# already running will not ask for a new lease, so timing one for it would
# either read the lease it already holds — a measurement of nothing — or wait
# out the whole timeout and report a failure that is not one. Say `skip` and
# mean it; see lease_forget() in lib/common.sh for the lease the wait must not
# be allowed to see.
LEASES="$LAB_STATE_DIR/dnsmasq/leases"
declare -A PENDING_MAC=()
for i in $(lab_node_indexes); do
  name="$(node_name "$i")"
  if [[ -z "${STARTED_FRESH[$name]-}" ]]; then
    phase_skip dhcp-lease "$name" "already running; no new lease expected"
    continue
  fi
  phase_begin dhcp-lease "$name"
  PENDING_MAC["$name"]="$(node_mac "$i")"
done

deadline=$(( $(date +%s) + DHCP_LEASE_TIMEOUT ))
while (( ${#PENDING_MAC[@]} > 0 )) && (( $(date +%s) < deadline )); do
  for name in "${!PENDING_MAC[@]}"; do
    if sudo grep -qiF "${PENDING_MAC[$name]}" "$LEASES" 2>/dev/null; then
      phase_end dhcp-lease "$name" ok
      ok "dhcp lease for $name"
      unset 'PENDING_MAC[$name]'
    fi
  done
  (( ${#PENDING_MAC[@]} == 0 )) || sleep 1
done

for name in "${!PENDING_MAC[@]}"; do
  phase_end dhcp-lease "$name" fail
  warn "no dhcp lease for $name after ${DHCP_LEASE_TIMEOUT}s — see $LAB_STATE_DIR/dnsmasq/dnsmasq.log"
done

# Wait for the console watchers. The DHCP lease says the segment carried
# traffic; the console phases go all the way to the login prompt, so the
# demo does not report a booted node before it can actually log in.
for name in "${!BOOT_WATCH_PID[@]}"; do
  wait "${BOOT_WATCH_PID[$name]}" || true
done
