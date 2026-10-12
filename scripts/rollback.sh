#!/usr/bin/env bash
#
# One-command image rollback — acceptance criterion #6.
#
#   make rollback TAG=sha-<previous> [NODE=<index>] [N=<n>]
#
# The image tag is the only thing that changes. Setting WAREWULF_IMAGE_TAG and
# re-running the Warewulf role re-imports `docker://<registry>/<image>:<tag>`,
# rebuilds the runtime overlays so the node can report the tag it was
# provisioned from, and restarts warewulfd. The node is then rebooted and the
# image reference is read back off its serial console.
#
# The tag is pinned rather than moving: `latest` names whatever was pushed
# most recently, which is exactly what a rollback must not do.

export LAB_SCRIPT_NAME=rollback
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
# shellcheck source=lib/boot-phases.sh
source "$HERE/lib/boot-phases.sh"
# shellcheck source=lib/node-reboot.sh
source "$HERE/lib/node-reboot.sh"
# shellcheck source=lib/converge.sh
source "$HERE/lib/converge.sh"
lab_load_env

TAG="${TAG:-}"
[[ -n "$TAG" ]] || die "set TAG to the previous image tag, e.g. make rollback TAG=sha-1bb6b9f6f98e"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "'$TAG' is not a valid container tag"

INDEX="${NODE:-1}"
if [[ ! "$INDEX" =~ ^[0-9]+$ ]] || (( INDEX < 1 )); then
  die "NODE must be a positive integer"
fi
lab_name="$(node_name "$INDEX")"

counters_init
timing_init

# lab_load_env has just sourced lab/local.env.example, whose WAREWULF_IMAGE_TAG
# default is `latest`. Set the rollback tag AFTER it, and before the role runs,
# so the role's lookup('env', 'WAREWULF_IMAGE_TAG') sees this value.
export WAREWULF_IMAGE_TAG="$TAG"

log "rollback: ${WAREWULF_IMAGE_NAME}:$TAG on ${lab_name}"
log "previous marker: $(sudo cat "$WAREWULF_STATE_ROOT/.cluster-lab-image" 2>/dev/null || echo unknown)"

# 1. Import the pinned tag and rebuild the overlays that report it.
timed rollback-converge "" -- converge_run

# 2. Reboot the node so it boots the rolled-back image.
node_stop "$lab_name"
phase_begin node-boot "$lab_name"
node_boot "$lab_name"
phase_end node-boot "$lab_name"

if ! wait "$NODE_BOOT_WATCH_PID"; then
  warn "$lab_name did not reach a login prompt in ${BOOT_PHASE_TIMEOUT:-300}s"
fi

# 3. Read the tag back off the console the in-node identity check writes to.
reference="$(node_console_value "$lab_name" 'image-reference [^ ]+')"
reference="${reference#image-reference }"
echo
echo "server imported marker : $(sudo cat "$WAREWULF_STATE_ROOT/.cluster-lab-image" 2>/dev/null || echo unknown)"
echo "node ${lab_name} reports : ${reference:-<nothing>}"
echo
timing_report "$LAB_TIMING_DIR/$LAB_RUN_ID.ndjson"

if [[ -z "$reference" ]]; then
  warn "no image reference on the console; last lines:"
  sudo tail -15 "$(node_console_path "$lab_name")" || true
  die "rollback could not be confirmed from the node"
fi
if [[ "$reference" != *":$TAG" ]]; then
  die "the node reports '${reference}', which is not tag '$TAG'"
fi

printf '%sROLLBACK OK%s — %s reports the rolled-back tag %s\n' \
  "$_C_GRN" "$_C_RST" "$lab_name" "$TAG"
