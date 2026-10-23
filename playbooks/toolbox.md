# Toolbox

Every approved tool in this repo, and the playbook step that uses it. Look
here before you build anything. If you add a make target, a script, a gate
or a doc, add its row in the same PR. `make help` is the source of truth for
target descriptions; this file says when to reach for each one.

## Bring up and inspect

| Tool | Use it for | Playbook |
|---|---|---|
| `make up` / `make down` / `make down-hard` | Platform to desired state, or stopped | lab-session 4 |
| `make status` | Units, segment, nodes, leases | lab-session 2, 4 |
| `make nodes-up N=<n>` / `make nodes-down` | Start or remove lab nodes | lab-session 4 |
| `make demo N=<n>` | Full run with timing table | — |
| `make systemd-install` | Install units after `systemd/` changed | change-the-platform 9 |
| `make cold-start-check` | Every unit enabled at boot | change-the-platform 9 |
| `make ssh-config`, `make authorize-key KEY=...` | Operator access to head node and nodes | lab-session 1 |
| `make lan-ports` | LAN port forwards via the Windows host | — |
| `make redfish` / `make redfish-demo` | Systems on the Redfish emulator; power-cycle and boot order | — |

## Change and deliver

| Tool | Use it for | Playbook |
|---|---|---|
| `make converge` | Apply the head-node play | change-the-platform 6, 9 |
| `make promote SHA=<commit>` | Move `deployed`, the ref nodes pull | change-the-platform 9 |
| `make convergence-status` | Each node's last pull; non-zero if stale or failed | change-the-platform 9 |
| `make rolling-update TAG=...` / `make rollback TAG=...` | Node image rollout and rollback | image-release 5, 7, 8 |
| `make drain` / `make resume` / `make reconfigure` | Slurm day-2 | fix-a-cluster-defect 1 |
| `make nodes-activate`, `make burnin-gate` | Staged nodes through burn-in to active | add-a-machine 6 |
| `make discover NODE=<node>` | Discovery boot and NetBox record check (lab nodes) | fix-a-cluster-defect 1 |

## Gates (all run by `make lint` and CI)

| Tool | Catches | Playbook |
|---|---|---|
| `make check-host-values` | Host-specific values, home-LAN addresses, real MACs | change-the-platform 5 |
| `make check-env-example` | An unsafe `lab/local.env.example` | change-the-platform 5 |
| `make secrets`, `make tracked-secrets`, `make git-identity` | Key material in the tree or history | change-the-platform 5, 7 |
| `make check-node-roles` | A node role that reaches another host | fix-a-cluster-defect 2 |
| `make check-playbooks` | A make target missing from this toolbox; a playbook with no Done when or not in the index | change-the-platform 4, 5 |
| `scripts/check-node-count-is-variable.sh` | Literal node counts and node lists, docs included | change-the-platform 5 |
| `make lint-yaml`, `make lint-ansible`, `make lint-shell` | Style and correctness | change-the-platform 5 |
| `make test-python` | Address plan, NetBox renderers, node API, burn-in gate | fix-a-cluster-defect 6 |
| Molecule (`molecule/`) | Managed roles in isolation | fix-a-cluster-defect 6 |

## Proof

| Tool | Proves | Playbook |
|---|---|---|
| `make acceptance` and `make drill-*` | Rollback, re-provision, NIC swap, cold start | fix-a-cluster-defect 6 |
| `make slurm-ready`, `make rdma-test` | Slurm jobs on every node; RDMA path | fix-a-cluster-defect 1, image-release 6, add-a-machine 7 |
| `make verify` (`make verify-isolation`, `make verify-idempotent`) | Isolation and idempotence | change-the-platform 9 |
| `make timings`, `make record-demo` | Measured runs, recorded | — |
| Alert rules (`monitoring/`) | StalePull, BurnInFailed, NodeDown, SlurmctldDown | fix-a-cluster-defect 6 |

## Node images (`cluster-images-wip`)

| Tool | Use it for | Playbook |
|---|---|---|
| `make lint` (in `cluster-images-wip`) | That repo's gates: host values, secrets, yaml, shell, Containerfiles | image-release 2 |
| `make build IMAGE=<name>` | Local build check of one image | image-release 2 |
| `.github/workflows/images.yml` | Publishes `sha-<12>` and `latest` to GHCR on merge to `main` | image-release 3, 4 |

## Docs

| Doc | Read it when |
|---|---|
| `CLAUDE.md` (`AGENTS.md` links to it) | Starting any session. It sends you to the playbooks |
| `docs/operations.md` | Any operator step. Update it when one changes |
| `docs/architecture.md` | Deciding where a fix belongs |
| `docs/node-self-configuration.md` | Changing a node role or `ansible-pull` |
| `docs/lab-host-setup.md`, `lab/README.md` | Lab host and `lab/local.env` |
| `docs/acceptance-drills.md` | Adding or running a drill |
| `docs/production-readiness.md` | A gap is found that the lab accepts but production would not |
| `docs/operations.md` "Images" | Releasing a node image |
| `docs/operations.md` "Add a machine", `docs/discovery.md` | Adding a lab node or a real machine |
| `docs/redfish.md`, `docs/network-isolation.md` | Those subsystems |

`scripts/lib/` holds the shared shell helpers (`common.sh`, `netbox.sh`,
`converge.sh`, `node-reboot.sh`, `timing.sh`). New scripts source them
rather than copying their logic.
