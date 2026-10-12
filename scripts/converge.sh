#!/usr/bin/env bash
#
# `make converge` — apply the Ansible play that owns every lab role.
#
# The harness scripts (net-up, nodes-up) build the segment and the nodes. The
# roles build what runs on top of it: NetBox and its reservations, Warewulf,
# the node images and overlays, Redfish, the Slurm controller. `make up` and
# this command are the two halves of "bring the platform to its desired
# state", and the rollback drill and the single-node re-provision both need the
# role half as a composable step, so it has its own entry point.
#
# Idempotent, like everything else: a second run reports changed=0.
#
# This entry point necessarily runs lab_load_env, which sources the example
# and the untracked local.env. A caller that needs to override a role's
# environment (an image rollback sets WAREWULF_IMAGE_TAG) calls converge_run
# from lib/converge.sh directly, after lab_load_env, so the override is not
# reset by the files.

export LAB_SCRIPT_NAME=converge
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/timing.sh
source "$HERE/lib/timing.sh"
# shellcheck source=lib/converge.sh
source "$HERE/lib/converge.sh"
lab_load_env

# Called standalone, own the timing run. Called from a drill that has already
# started one, reuse it rather than truncating the file out from under it.
if [[ -z "${LAB_RUN_ID:-}" ]]; then
  timing_init
fi

timed converge "" -- converge_run "$@"
