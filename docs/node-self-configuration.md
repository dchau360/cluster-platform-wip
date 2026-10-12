# Node self-configuration

A compute node configures itself. It has no inbound SSH and holds no
credential of its own. The head node runs four jobs a node cannot do for
itself: the Slurm controller and its configuration, the day-2 plays, the
burn-in acceptance gate, and promotion of the `deployed` ref.

```text
                         head node                                   compute node (xN)
  ┌──────────────────────────────────────────────┐      ┌──────────────────────────────────────┐
  │ GitHub ──mirror──> /git/platform.git (HTTP)  │◄─────│ cluster-pull.service  (boot, once)   │
  │                    ref: deployed only        │ git  │ cluster-pull.timer    (splayed)      │
  │                                              │      │   ansible-pull -C deployed local.yml │
  │ cluster-node-api :8002 ──token──> NetBox     │◄─────│   GET  /v1/self          facts, once │
  │   identity = source address on br-prov       │ HTTP │   POST /v1/self/convergence          │
  │                                              │      │   POST /v1/self/burnin   (staged)    │
  │ slurmctld  (configless)                      │◄─────│ slurmd --conf-server  (active only)  │
  │   slurm.conf cgroup.conf gres.conf           │ RPC  │   no slurm.conf on the node, ever    │
  │   topology.conf   <- rendered from NetBox    │      │                                      │
  │                                              │      │ Warewulf runtime overlays:           │
  │ day-2 plays, burn-in gate (push)             │      │   cluster-identity: Munge key, image │
  │ Prometheus: convergence + node_exporter      │      │   cluster-pull: wrapper, units, env  │
  └──────────────────────────────────────────────┘      └──────────────────────────────────────┘
```

## The pull path

| Piece | Where it comes from |
| --- | --- |
| `cluster-pull` wrapper, `cluster-pull.service`, `cluster-pull.timer`, `/etc/cluster-pull/pull.env` | the `cluster-pull` Warewulf runtime overlay, built by `ansible/roles/warewulf_server/tasks/pull_overlay.yml` |
| `ansible-core`, `git` | the node image, `cluster-images-wip/images/compute-base` |
| the playbook, `ansible/local.yml`, and its roles | `ansible-pull` from the head node's mirror, **pinned `deployed` ref** |
| the node's facts | the head-node API, from NetBox, **fetched once per run** and cached at `/var/cache/cluster-node/facts.json` |
| the Munge key and the image reference | the `cluster-identity` runtime overlay, generated on the head node, never in git or an image |

**Boot run immediate, timer splayed.** `cluster-pull.service` is wanted by
`multi-user.target`, so the first run starts as soon as the network is up.
`cluster-pull.timer` repeats it `PULL_INTERVAL` after the previous run ends,
plus a random `RandomizedDelaySec=PULL_SPLAY`, so N nodes never hit the
mirror in the same second.

**Pinned ref, never `main`.** The mirror publishes only `deployed`. A commit
reaches it only through `make promote`, which refuses any commit whose CI is
not green, including the `pull check-mode` job (below). GitHub enforces the
same rule on the branch itself.

**Node-local roles.** `node_facts`, `network_from_netbox`, `munge`,
`node_exporter`, `burnin`, `slurm_compute`, `convergence_report`. None uses
`delegate_to`, `local_action`, `run_once` or another host's `hostvars`.
`scripts/check-node-roles-are-local.sh` reads the role list from `local.yml`
and fails CI on any of them. That constraint is what lets one role set serve
pull and push: a role that reaches for another host only works where that
host is in the inventory, and under `ansible-pull` the inventory is the node.

**No half-apply.** `local.yml` fetches the facts first: if the head node is
unreachable, nothing has been touched. Every later failure is caught by a
`rescue`, reported as `failed` with the failing task's name, and the run
still exits non-zero. If the mirror is unreachable, `ansible-pull` fails
before the play exists; the previous checkout and every running service are
untouched (that *is* the last-known-good configuration), and the wrapper
reports the run as `failed` with `fetch deployed from mirror` as the failed
step.

**What each run records.** Commit, image tag, result, duration, finish time,
run id and failed task, as custom fields on the node's own NetBox device:

```sh
make convergence-status        # one query; exit 1 when a node is stale or failed
```

A node that cannot reach the API at all cannot report; its
`last_converged_at` simply stops moving. `cluster-node-api` exports
`cluster_node_last_converged_timestamp_seconds` and Prometheus raises
`ClusterNodeConvergenceStale` after `CONVERGENCE_STALE_SECONDS`.

## No credential on the node

The node never holds a NetBox token. `cluster-node-api` runs on the head node,
bound to the provisioning address only, and is the one thing that holds one.
It offers a node exactly three calls, all about itself:

| Call | What it does |
| --- | --- |
| `GET /v1/self` | the node's facts: device, status, hostname, interfaces, inventory, controller |
| `POST /v1/self/convergence` | validates and writes the seven convergence fields, and nothing else |
| `POST /v1/self/burnin` | writes raw measurements; any `passed`/`verdict` key the node sends is dropped |

**"Self" is the client's source address.** The provisioning segment has no
uplink, every node address is a NetBox reservation, and the API binds to that
segment only. So this is an isolation argument, not a cryptographic one: a
machine that could put itself on `br-prov` with another node's address could
speak for that node. On this lab that machine would be a VM the harness
created. Per-node mTLS from a Warewulf overlay is the step up if that changes.
What a node can *never* do, even speaking for another node, is change a status
or a name: the API has no call that writes either.

## The push path

| Job | Entry point | Touches |
| --- | --- | --- |
| Slurm controller and configuration | `make converge` (`slurm_controller`, `slurm_config`) | the head node only |
| Drain, resume | `make drain NODES=...`, `make resume NODES=...` | slurmctld |
| Controller reconfigure | `make reconfigure` | the head node only |
| Rolling image update, rollback under failure | `make rolling-update TAG=sha-...` | Warewulf, Redfish, slurmctld |
| Burn-in acceptance gate | `make burnin-gate` | NetBox status, then slurmctld |
| Promotion, rollback of config | `make promote SHA=...` | the `deployed` ref |

None of these logs in to a node. Rebooting is Redfish; draining is slurmctld;
health is what the node itself reported to NetBox.

### Configless Slurm

`slurmctld` runs with `SlurmctldParameters=enable_configless`. A compute node
runs `slurmd --conf-server <head>:6817` (from `/etc/sysconfig/slurmd`) and
fetches `slurm.conf`, `cgroup.conf`, `gres.conf` and `topology.conf` at start.
No Slurm file exists on a compute node; `slurm_compute` fails the run if one
does. Distribution is O(1) in node count: `make reconfigure` writes one host,
and every slurmd re-fetches over Slurm's own RPC.

**Every value traces to NetBox or `local.env`.** `render_slurm.py` reads:

| slurm.conf / topology.conf value | NetBox source |
| --- | --- |
| `NodeName` | `dns_name` on the device's provisioning address |
| `NodeAddr` | that address |
| `CPUs` | `discovered_cpu_count` (written by the discovery boot) |
| `RealMemory` | `discovered_memory_mib` minus `SLURM_MEM_RESERVE_MIB` |
| `Gres=gpu:N`, `gres.conf` | `discovered_gpu_count` |
| `SwitchName ... Nodes=` | cables from each node's provisioning interface to a leaf |
| `SwitchName ... Switches=` | cables from each leaf's uplink to the spine |

Site values (`ClusterName`, ports, partition name, memory reserve) come from
`lab/local.env`. Only `active` compute devices become Slurm nodes. A device
NetBox does not fully describe is an error that names the device and the
field, never a default.

**Versions.** Configless `slurmd` must speak the controller's RPC, and Slurm
keeps compatibility with only the three previous major releases. The head
node's controller is Ubuntu's 25.11; EPEL 9 ships 22.05. The node image
therefore builds 25.11 from the pinned SchedMD tarball
(`cluster-images-wip/images/compute-slurm`).

**A node that starts while slurmctld is down** retries: `slurmd` loops on the
config fetch, and the unit drop-in (`Restart=always`, `RestartSec=10`,
`StartLimitIntervalSec=0`) restarts it if it exits. The pull run starts
`slurmd` without blocking, so the node's convergence does not depend on
another host being up.

### Burn-in acceptance gate

A new device is created `staged` by the seeder; after that, the gate owns its
status. On a `staged` node, `local.yml` runs `burnin`: `stress-ng` across every
CPU with verification, `stress-ng` walking and verifying a share of RAM, and a
`fio` write-then-verify of the raw scratch disk. The measurements, not a
verdict, go to the device's `burnin_results` JSON field. `slurmd` does not run
on a `staged` node.

`make burnin-gate` runs on the head node. It recomputes pass/fail from the raw
numbers against floors held in this repository, then sets the device `active`
(and reconfigures Slurm, which adds the node) or `failed`, with the reasons in
`burnin_verdict`. The gate never asks the node anything, and nothing the node
can reach can write its status.

### Rolling image update

`make rolling-update TAG=sha-<new>` imports the image once under a
tag-specific Warewulf name, then for each node in turn: drain and wait for
running jobs to finish, set the node's image and `image_reference` tag,
rebuild its overlays, power-cycle it over Redfish, wait until it has pulled
and reported `success` on the new tag to NetBox *after* the reboot and its new
`slurmd` has registered, resume, next. Each phase is timed into the run's
NDJSON. If a node is not healthy within `HEALTHY_TIMEOUT`, or reports a failed
pull, it is put back on the image it had, rebooted, verified, resumed, and the
rollout stops.

### Promotion

```sh
make promote SHA=<commit>      # moves `deployed`; prints the rollback command
make promote SHA=<previous>    # that is the rollback
```

The `pull check-mode` CI job runs `local.yml --check` inside the node image,
under systemd, with the node's own `ansible-core`, exactly as `ansible-pull`
would. `make promote` refuses a commit unless every CI job on that exact
commit passed, and the `deployed` branch is protected on GitHub with the same
required check.

## Evidence

Recorded on the lab at N=2 on 2026-10-12; the full output is in the SRE-7
issue thread.

| Check | Result |
|-------|--------|
| Self-configuration, no inbound SSH | `root@<node>:22` refused; the serial log shows `cluster-pull` cloning `deployed` from the head mirror, fetching facts from the node API, installing the overlay Munge key |
| Idempotence | second pull run on each node `ok=38 changed=0 failed=0`; head converge `ok=119 changed=0` |
| Slurm | `sinfo`: both nodes `idle`; `sbatch -N2 -n4` ran two ranks on each node |
| Burn-in gate | cn02's disk throttled to 4 MiB/s from the hypervisor: gate set it `failed` (`disk write_mib_per_second 4.0 < 20.0`) and cn01 `active`; throttle removed, cn02 re-staged, re-burned at 1299.5 MiB/s, gate set it `active` |
| slurmctld down at node start | pull run succeeded; `slurmd` retried the config fetch for ~2 min and registered 10 s after slurmctld started |
| Mirror unreachable | run reported `failed` (`fetch deployed from mirror (exit 2)`), checkout and services untouched, node stayed `idle`; `convergence-status` exits non-zero |
| Bad commit | a variable typo passes yamllint and ansible-lint; `pull check-mode` fails it; `make promote` prints `REFUSED`; a direct push to `deployed` is rejected by branch protection |
| Promote / rollback | one ref move each way (rollback 2.95 s); both nodes converged on whichever commit `deployed` named |
| Stale detection | `CONVERGENCE_STALE_SECONDS=60 make convergence-status` flags both nodes `STALE` and exits 2; the Prometheus rules are loaded and inactive while nodes are healthy |
| Rolling update | `sha-54a0b45db3a1` to `sha-2c46934beb6c` across both nodes in 190 s while 9 jobs ran: 9/9 `COMPLETED Restarts=0 ExitCode=0:0` |
| Rollback under failure | rollout to an image without `slurmd`: cn01's pull reported `failed`, cn01 was put back on `sha-2c46934beb6c`, resumed, rollout stopped; cn02 never touched; 5/5 jobs completed |

Per-node phases of the rollback drill (`make timings`):

```
PHASE                    NODE          SECONDS   STATUS
rolling-drain            cn01           62.464       ok
rolling-reimage          cn01            1.402       ok   (to the broken image)
rolling-reimage          cn01            1.344       ok   (back to the previous image)
rolling-healthy          cn01           42.439       ok
day2-rolling_update      -             236.623     fail
```

Faults the drills found, all fixed:

- The controller's `munged` predated the cluster key (a lost handler), so
  slurmctld rejected every node. The role now restarts a `munged` older than
  its key, judged by wall clock because WSL's monotonic clock drifts.
- The source-built image had no `slurm` account, so configless `slurmd`
  exited. `cluster_slurm_user` is created by `slurm_compute` and shipped in
  the image.
- Docker's `br_netfilter` dropped node-to-node frames on the bridge; batch
  steps failed while `srun` from the head worked. `net-up.sh` accepts traffic
  within the segment.
- Every push to `deployed` started a CI run the next promotion cancelled,
  leaving a red check on a green commit. CI skips `deployed`, and
  `promote.sh` judges the latest run per check.
- Day-2 per-node timings were written but unreadable by the report, and
  `now(utc=true).timestamp()` skewed starts by the zone offset.
- The node API exported convergence times an hour old (DST in `mktime`) and
  exported planned devices, so both alerts fired on a healthy fleet.
