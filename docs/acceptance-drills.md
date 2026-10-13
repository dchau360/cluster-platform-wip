# Acceptance drills

Operational criteria a boot chain can be built without ever proving. Each is
a command, not a checklist, and each leaves its evidence on the console it
ran on.

| Criterion | Command | What proves it |
| --- | --- | --- |
| From power-off to a cluster that takes work, no manual step | `make demo N=<n>` | the timing table, `sinfo`, and a job array that ran on every node |
| The same code runs at any node count | `make demo N=<a>` / `N=<b>` | the per-phase timing tables at each count |
| A real RDMA bandwidth number | `make rdma-test` | `perftest` output from a node pair over `rdma_rxe` |
| One node re-provisions alone | `make drill-reprovision` | neighbours' CPU time and consoles keep going |
| Identity survives a NIC swap | `make drill-nic-swap` | hostname and NetBox device unchanged, MAC changed |
| Rollback to the previous image | `make rollback TAG=sha-<previous>` | the booted node reports the older tag |
| Rolling image update, one node at a time | `make rolling-update TAG=sha-<new>` | jobs keep completing while nodes are reimaged |
| `deployed`-ref rollback | `make promote SHA=<previous>` | every node converges on the commit the ref names |
| The burn-in gate holds a failed node | `make burnin-gate` | a degraded node is set `failed` and never joins Slurm |
| Cold-start recovery after a WSL restart | `scripts/windows/drill-cold-start.ps1` | a new boot id, then the lab back to Slurm-ready |

`make acceptance` runs everything that can be driven from inside the lab, in
order, and stops at the first failure, so a partial record cannot be mistaken
for a complete one. It needs `TAG=` for the image rollback, `ROLLING_TAG=`
for the rolling update and `ROLLBACK_SHA=` for the ref rollback; each is
reported as skipped when not given rather than quietly passed over.

Two drills are not in `make acceptance`, each for a reason worth stating:

- **Cold start.** `wsl --shutdown` kills the process that asks for it, so the
  drill is driven from the Windows side. See below.
- **The burn-in gate holding a failed node.** It needs a node deliberately
  degraded from the hypervisor, which is a hand on the lab rather than a step
  in a pipeline. The procedure is below and it has been run.

## `make demo` — power-off to a cluster, with nothing done by hand

```sh
make demo N=4
```

`make demo` used to stop where a node could be logged in to. That is not a
cluster. The two steps between a login prompt and a node that takes work are
the ones this design refuses to shortcut:

1. A new node is `staged` in NetBox. `staged` means burn-in, and a node in
   burn-in must not take jobs, so `slurm_compute` deliberately leaves
   `slurmd` stopped.
2. The node runs its own burn-in and posts the raw measurements to the
   head-node API. The gate judges them on the head node and sets the status.
   The node never supplies its own verdict.

`make nodes-activate` waits for each staged node to report, runs the gate, and
power-cycles the nodes it promoted so their boot pull run sees `active` and
starts `slurmd`. A power cycle because nobody can log in to a node to hurry
it along; the node's own pull timer would get there within `PULL_INTERVAL`
plus its splay, which is correct and up to twenty minutes.

`make slurm-ready` then waits for every node to register with `slurmctld` and
submits a job array of one task per node, each asking for a whole node. The
check is not "the array finished": it is that every task is `COMPLETED` with
exit `0:0` **and** that the union of the nodes the tasks ran on is every node.
Read from `scontrol`, not `sacct` — this cluster runs no accounting database.

Both steps are idempotent, which is why `make demo` on a live lab is cheap:
an already-`active` node skips the burn-in phases and an already-registered
node is recorded as `skip` for `slurm-join` rather than as a fast join.

## Adding a node: a NetBox entry and a power-on

Nothing is edited by hand. `N` is the only input, and from it:

- the seeder creates the NetBox device, interface, MAC and addresses,
- `render_dnsmasq.py` renders the DHCP reservations from NetBox,
- the Warewulf role defines the node and its address from the same place,
- `render_slurm.py` renders `slurm.conf` and `topology.conf` from NetBox,
- `nodes-up.sh` defines and powers on the VM.

The grep that proves it: `scripts/check-node-count-is-variable.sh` fails CI on
a literal `NODE_COUNT` assignment, a literal loop bound, or a hardcoded
node-name list anywhere in the repository.

## Soft-RoCE RDMA

```sh
make rdma-test
```

A genuine verbs data path — queue pairs, registered memory, completion
queues, RDMA `WRITE` and `SEND` — over the `rdma_rxe` software provider on
each node's ordinary Ethernet NIC. **Not InfiniBand hardware, and there is no
subnet manager anywhere in this lab.** What is real and what is not is set
out in [`rdma-soft-roce.md`](rdma-soft-roce.md), along with the measured
numbers and the TCP reference over the same link.

## One-command image rollback

```sh
make rollback TAG=sha-1bb6b9f6f98e
```

Under the hood, and still one command:

1. `WAREWULF_IMAGE_TAG` is set to the pinned tag and the Warewulf role runs.
   The role re-imports
   `docker://ghcr.io/dchau360/cluster-images-wip/compute-slurm:<tag>` (no
   credential; the packages are public) and rebuilds the runtime overlays.
2. The node is stopped, started, and its boot watched to the login prompt.
3. The `image-reference` line the in-node identity check writes to the serial
   console is read back and compared to the tag that was asked for.

The tag is pinned on purpose. `latest` names whatever was pushed most
recently, which is exactly what a rollback must not do.

The node reports the tag because the platform delivers it in the same runtime
overlay as the identity material (`/etc/cluster-lab/image-reference`, written
by `warewulf_server` from `warewulf_server_image_uri`). That makes "roll back,
reboot, read the version back" a closed loop instead of one that depends on a
human remembering what was imported.

## Rolling image update

```sh
make rolling-update TAG=sha-<new>
```

One node at a time: drain it in Slurm, wait for its jobs to finish, reimage
it, reboot it, wait for it to come back healthy, resume it, move on. A node
whose pull run fails after the new image is put back on the previous one,
resumed, and the rollout stops — the remaining nodes are never touched. Jobs
running on the other nodes keep completing throughout, which is the point of
draining rather than rebooting.

## `deployed`-ref rollback

```sh
make promote SHA=<previous commit>
```

Configuration rollback is one ref move. Nodes pull the pinned `deployed` ref,
never `main`, so whichever commit the ref names is what the fleet converges
on; `make convergence-status` is the one query that says which node is on
which commit. `promote.sh` refuses any commit whose CI is not green, and
GitHub enforces the same rule on the branch, so a rollback cannot reach a
commit that was never proven.

## Cold-start recovery after a WSL restart

```powershell
.\scripts\windows\drill-cold-start.ps1 -Repo /home/<user>/src/cluster-platform-wip -N 4
```

Driven from the Windows side because the thing being restarted is the thing
the lab scripts run inside: `wsl --shutdown` kills every process in the
distribution, including the script that asked for it. The driver runs the
`before` stage inside WSL, shuts the distribution down, and re-enters it —
and that re-entry is what starts it again.

The boot id is the evidence. `/proc/sys/kernel/random/boot_id` is recorded
before and compared after, and the drill refuses to call it a restart if the
id did not change. Every other signal — uptime, a stopped VM, an inactive
unit — can be produced without restarting anything.

What the `after` stage measures, in order: how long systemd takes to reach
`running` or `degraded`, whether `lab-net` and `lab-dnsmasq` come back
unasked, that `make cold-start-check` still passes, and then how long `make
up` (idempotent — the change count is how much repair was needed), `make
nodes-up` and `make slurm-ready` take to get back to a cluster. A stopped VM
is a powered-off machine, and nothing restores one but a power-on.

**This stops the whole distribution.** Anything else living in it stops too
and comes back only if its unit is enabled at boot. Know what else is in the
distribution before running it.

## The burn-in gate holds a failed node

The gate is only meaningful if it fails something. Degrading a node from
outside it, so the node itself is honest and the measurement is genuinely
bad:

```sh
sudo virsh blkdeviotune <node> vda --write-bytes-sec 4194304 --live
make nodes-down && make demo N=<n>      # the node re-burns under the throttle
make burnin-gate
```

The gate reads the node's own posted measurements, judges them against the
floors, sets the status, and `slurm_compute` keeps `slurmd` stopped on
anything that is not `active`. Remove the throttle, re-stage the node, and the
next burn-in passes.

## Measured results

All of these ran on the lab host on 2026-10-12/13 against
`cluster-platform-wip` at `5ab1a81`, node image `sha-baa648ba99c8`. The full
console output is in the SRE-8 issue thread.

### `make demo N=4` — power-off to a cluster

Run `20261013T000455Z-686422`. `make demo` printed the timing table,
`sinfo` showed four idle nodes, and the job array ran one task on every one
of them, checked from `scontrol`'s own record:

```
NODELIST   NODES PARTITION       STATE
cn01           1  compute*        idle
cn02           1  compute*        idle
cn03           1  compute*        idle
cn04           1  compute*        idle

TASK     JOBID    STATE        EXIT     NODE
1        56       COMPLETED    0:0      cn01
2        57       COMPLETED    0:0      cn02
3        58       COMPLETED    0:0      cn03
4        55       COMPLETED    0:0      cn04

SLURM READY — 4 node(s) joined and a job array ran on every one of them
```

The same command at N=1 and N=2 also reached `SLURM READY` with a job array
on every node and no code change; the per-phase tables are in
[`measurements.md`](measurements.md#results).

### Soft-RoCE RDMA

```
[rdma-test] pair: cn01 (server, 10.42.0.20) and cn02 (client), device rxe0
ib_write_bw          5000 iters  peak     407.88 MB/s  average     396.21 MB/s    0.006339 Mpps
ib_send_bw           5000 iters  peak     504.71 MB/s  average     480.11 MB/s    0.007682 Mpps
iperf3 (same link)  74.8 GBytes  64.3 Gbits/sec sender / 64.0 Gbits/sec receiver
RDMA OK — a genuine verbs data path over Soft-RoCE (rdma_rxe), no InfiniBand hardware and no subnet manager
```

The `-R` requirement and what the number does and does not mean are in
[`rdma-soft-roce.md`](rdma-soft-roce.md).

### Image rollback

```
$ make rollback TAG=sha-2c46934beb6c
server imported marker : sha-2c46934beb6c
node cn01 reports       : docker://ghcr.io/dchau360/cluster-images-wip/compute-slurm:sha-2c46934beb6c
ROLLBACK OK — cn01 reports the rolled-back tag sha-2c46934beb6c
```

One command changed the tag, rebooted the node, and read the tag back off the
node's own console.

### Rolling image update

```
$ make rolling-update TAG=sha-baa648ba99c8
```

Four nodes, one at a time, on an idle cluster. Per-node phases, from the
run's NDJSON:

| Phase | cn01 | cn02 | cn03 | cn04 |
| --- | --- | --- | --- | --- |
| `rolling-drain` | 0.532 | 0.441 | 0.438 | 0.442 |
| `rolling-reimage` | 1.345 | 1.335 | 1.331 | 1.368 |
| `rolling-healthy` | 42.470 | 42.037 | 41.993 | 42.004 |
| `rolling-resume` | 0.244 | 0.242 | 0.243 | 0.278 |

`day2-rolling_update` was **211.858s** for the fleet. On an idle cluster the
dominant term is the health wait, and the drain is near-zero because there
were no jobs to wait for. The cost is serial by design and is discussed in
[`scale-analysis.md`](scale-analysis.md).

### `deployed`-ref rollback

```
$ make promote SHA=165de2f      # from the clean clone
$ make convergence-status
rack-a-u01  active  165de2fae6a0  sha-baa648ba99c8  success  8.033   63s ago
rack-a-u02  staged  165de2fae6a0  sha-baa648ba99c8  success  9.427   63s ago
rack-a-u03  staged  165de2fae6a0  sha-baa648ba99c8  success  7.967   53s ago
rack-a-u04  staged  165de2fae6a0  sha-baa648ba99c8  success  8.461   61s ago
deployed ref: 165de2fae6a0   stale after: 3600s
```

One ref move, and every node's next pull converged on the commit the ref
named. `make promote SHA=5ab1a81` moved it forward again the same way.

### One node re-provisions

```
$ make drill-reprovision N=4
cn02 state=running domid=73 cpu_ns=40317208000->41314450000 lease=1
cn03 state=running domid=74 cpu_ns=36855672000->37868124000 lease=1
cn04 state=running domid=75 cpu_ns=35433778000->36544170000 lease=1
ok   cn02: state=running domid 73->73 cpu_ns ...->... lease=1
ok   cn03: state=running domid 74->74 cpu_ns ...->... lease=1
ok   cn04: state=running domid 75->75 cpu_ns ...->... lease=1
RE-PROVISION OK — cn01 was rebuilt from bare metal; every neighbour stayed up
```

cn01 is the control: its disk was removed, so its domain id and CPU time
both reset. Every neighbour's domain id is unchanged and its QEMU CPU time
grew across the window, so it was the same running guest the whole time.

### Identity survives a NIC swap

```
$ make drill-nic-swap N=4
pre-swap identity for cn01 (index 1)
domain MAC          : 52:54:00:00:00:01
netbox interface MAC: 52:54:00:00:00:01
swap: 52:54:00:00:00:01 -> 52:54:00:00:ff:01
post-swap identity
domain MAC          : 52:54:00:00:ff:01
netbox interface MAC: 52:54:00:00:FF:01
console             : cn01 login:
dhcp lease hostname : cn01
PASS the MAC changed: 52:54:00:00:ff:01
PASS NetBox recorded the new MAC: 52:54:00:00:ff:01
PASS the NetBox device kept its name: rack-a-u01
PASS the hostname did not change: cn01
PASS the node still booted as itself: cn01 login:
NIC SWAP OK — MAC changed, cn01 kept its name in Warewulf, on the console and in NetBox
```

One caveat this drill leaves behind, now written down rather than
rediscovered: it moves the node's MAC on purpose and leaves it moved, and the
harness's own `nodes-up` renders the domain from the MAC formula. The next
`make demo` therefore puts the NIC back on the formula MAC while Warewulf and
NetBox still hold the swapped one, and the node will not boot until the
Warewulf hwaddr is restored to match. It is the last drill in
`make acceptance` for that reason.

<!-- MEASURED-BURNIN -->

### The burn-in gate holds a deliberately-failed node

The gate is only meaningful if it fails something. The way to make it fail
something honestly is to degrade the node from outside it, so the node's own
measurement is genuinely bad:

```sh
sudo virsh blkdeviotune cn02 vda --write-bytes-sec 4194304 --live
# re-stage cn02 and let its own pull timer re-burn under the throttle
make burnin-gate
# cn02 -> failed, slurmd stays stopped; remove the throttle, re-stage, re-burn
```

The `--live` throttle must be applied to the running domain and the node
re-staged *without* a rebuild: `make nodes-down` undefines the domain, and
`nodes-up` redefines it from the harness XML, which drops both the live and
the persistent throttle. Letting the node's own `cluster-pull.timer` run the
burn-in is what actually keeps the throttle in place. (This corrects the
procedure that was written before the drill was run.)

In the SRE-7 run this drill was carried out and recorded: cn02's disk
throttled to 4 MiB/s was judged `failed` (`disk write_mib_per_second 4.0 <
20.0`) while cn01 was set `active`; the throttle was then removed, cn02
re-staged, re-burned at 1299.5 MiB/s, and the gate set it `active`.

**The SRE-8 re-run is pending.** The drill was started against the current
image, cn02 re-staged under a live throttle, and the lab host stopped
answering partway through; it is recorded here as pending a working lab, not
as passed.

## Cold-start recovery after a WSL restart

**Not yet run.** `wsl --shutdown` stops the whole distribution, including
anything else in it, and the project's own rule is not to run it without Huy's
explicit go-ahead. The command and what it measures are above; the result is
recorded here once that go-ahead is given.
