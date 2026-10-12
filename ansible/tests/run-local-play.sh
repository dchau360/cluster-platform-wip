#!/bin/bash
#
# Run local.yml inside a node-image container the way ansible-pull runs it on
# a node: the node's own ansible-core, connection local, inventory localhost.
# Extra arguments go to ansible-playbook (CI passes --check --diff).
#
# Prints the recap; exits with ansible-playbook's status.

set -euo pipefail
SRC="${SRC:-/src}"
export CLUSTER_NODE_FACTS_FILE=/etc/cluster-lab/node-facts.json
export ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1
# The checkout is bind-mounted from the runner with another owner.
git config --global --add safe.directory "$SRC" 2>/dev/null || true
cd "$SRC"
ansible-playbook --version | head -1
exec ansible-playbook -i localhost, ansible/local.yml "$@"
