#!/usr/bin/env bash
# shellcheck shell=bash
#
# Apply the platform's Ansible play. Shared by `make converge` and by the
# acceptance drills that need the role half of the platform reconciled after
# they change an environment variable (an image tag, a node MAC).
#
# The caller is responsible for `lab_load_env` having run, so that every
# WAREWULF_* / NETBOX_* variable the roles read is present and any change the
# caller made to one of them is visible to `lookup('env', ...)`.

converge_run() {
  # The play uses netbox.netbox and community.docker. A fresh clone has
  # neither. Install only when missing, so the common path costs nothing.
  if ! ansible-galaxy collection list 2>/dev/null | grep -q '^netbox\.netbox'; then
    log "installing the Ansible collections the play needs"
    ansible-galaxy collection install \
      -r "$REPO_ROOT/ansible/collections/requirements.yml"
  fi
  ( cd "$REPO_ROOT/ansible" \
      && ansible-playbook -i inventory/lab.yml site.yml "$@" )
}
