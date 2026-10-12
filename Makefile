# cluster-platform-wip — lab harness.
#
# Three commands do the work:
#
#   make up            bring the platform to its desired state (idempotent)
#   make down          stop the lab
#   make demo N=<n>    up, start N nodes, print the timing table
#
# N is a variable everywhere. Nothing in this repo knows a node count.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

REPO_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
export REPO_ROOT

S := $(REPO_ROOT)/scripts
RUN := bash

# Node count. Passed through to every script; never baked into one.
N ?=
export N

.PHONY: help up down down-hard demo nodes-up nodes-down status timings \
        discover \
        systemd-install verify verify-isolation verify-idempotent \
        redfish redfish-demo converge rollback drill-nic-swap drill-reprovision \
        acceptance \
        check-host-values lint lint-yaml lint-ansible lint-shell secrets \
        tracked-secrets git-identity cold-start-check

help: ## Show this help
	@printf 'cluster-platform-wip\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@printf '\nnode count:   make demo N=4\n'

# --- lifecycle -------------------------------------------------------------

up: ## Bring the platform to its desired state (idempotent)
	@$(RUN) $(S)/up.sh

converge: ## Apply the Ansible play (NetBox, dnsmasq, Warewulf, Redfish, Slurm)
	@$(RUN) $(S)/converge.sh

rollback: ## One-command image rollback. make rollback TAG=sha-<previous> [NODE=<n>]
	@$(RUN) $(S)/rollback.sh

drill-nic-swap: ## Swap a node's MAC; prove hostname and NetBox identity hold
	@$(RUN) $(S)/drill-nic-swap.sh

drill-reprovision: ## Rebuild one node from bare metal; every neighbour stays up
	@$(RUN) $(S)/drill-reprovision.sh

acceptance: ## Run the acceptance drills in order (TAG=<tag> for the rollback)
	@$(RUN) $(S)/acceptance-drills.sh

down: ## Stop nodes and the provisioning segment; units stay enabled
	@$(RUN) $(S)/down.sh

down-hard: ## Stop everything and disable the units too
	@HARD=1 $(RUN) $(S)/down.sh

demo: ## up + start N nodes + timing table.  make demo N=4
	@$(RUN) $(S)/demo.sh

nodes-up: ## Define and start N nodes on the segment
	@$(RUN) $(S)/nodes-up.sh

nodes-down: ## Stop and undefine every lab node.  WIPE=1 also deletes disks
	@$(RUN) $(S)/nodes-down.sh

systemd-install: ## Render and install the lab systemd units
	@$(RUN) $(S)/systemd-install.sh

status: ## Show units, segment, nodes, leases
	@$(RUN) $(S)/status.sh

discover: ## Boot a node into the discovery image and verify its NetBox record. NODE=cn01
	@$(RUN) $(S)/discover.sh

# --- management plane ------------------------------------------------------

redfish: ## List the systems sushy-emulator exposes over Redfish
	@$(RUN) $(S)/redfish.sh list

redfish-demo: ## Power-cycle the first node and flip its boot order over Redfish
	@$(RUN) -c 'source $(S)/lib/common.sh; lab_load_env; \
	  node=$$(node_name 1); \
	  bash $(S)/redfish.sh power "$$node" cycle; \
	  bash $(S)/redfish.sh boot  "$$node" hd; \
	  bash $(S)/redfish.sh boot  "$$node" pxe'

timings: ## Print the timing table for the most recent run
	@$(RUN) -c 'source $(S)/lib/common.sh; lab_load_env; source $(S)/lib/timing.sh; timing_report'

# --- gates -----------------------------------------------------------------

verify: verify-isolation verify-idempotent ## Run every lab-host verification

verify-isolation: ## Prove the segment cannot reach the home LAN
	@$(RUN) $(S)/verify-isolation.sh

verify-idempotent: ## Prove a second 'make up' changes nothing
	@$(RUN) $(S)/verify-idempotent.sh

cold-start-check: ## Confirm every lab unit is enabled at boot
	@$(RUN) $(S)/cold-start-check.sh

# --- repo hygiene. Same checks CI runs. ------------------------------------
#
# A gate whose tool is missing must say so. Bare `gitleaks` exits 127 and make
# does fail, but the message is "command not found", which reads like a broken
# gate rather than an uninstalled one. A gate is never skipped: a skipped gate
# and a passing gate look identical in a log, and only one of them is safe.
need = @command -v $(1) >/dev/null 2>&1 || { \
	  printf 'error: %s not found, so this gate cannot run.\n       %s\n' '$(1)' '$(2)' >&2; \
	  exit 127; }

lint: check-host-values secrets tracked-secrets git-identity lint-yaml lint-ansible lint-shell ## Run every repo gate

check-host-values: ## Fail if any host-specific value is in a tracked file
	@$(RUN) $(S)/check-no-host-values.sh

tracked-secrets: ## Fail if a tracked file is named like key material or lab state
	@$(RUN) $(S)/check-no-tracked-secrets.sh

git-identity: ## Fail if key material ever existed in git history, not just the tip
	@$(RUN) $(S)/check-no-identity-in-git.sh

secrets: ## Run gitleaks over the worktree and the full history
	$(call need,gitleaks,Install step is in docs/lab-host-setup.md.)
	@gitleaks dir . --redact --no-banner --verbose
	@gitleaks git . --redact --no-banner

lint-yaml: ## yamllint
	$(call need,yamllint,Install step is in docs/lab-host-setup.md.)
	@yamllint -s .

lint-ansible: ## ansible-lint
	$(call need,ansible-lint,Install step is in docs/lab-host-setup.md.)
	@ansible-lint

lint-shell: ## shellcheck
	$(call need,shellcheck,Install step is in docs/lab-host-setup.md.)
	@shellcheck -x -S style -P SCRIPTDIR $$(git ls-files '*.sh')
