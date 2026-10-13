# Operations

The commands an operator actually runs, and where the consoles are. Run them
on the **lab host** (inside WSL) unless a step says otherwise. `make help`
lists every target.

## Check the lab

```sh
make status              # units, segment, node states, DHCP leases, last runs
make convergence-status  # NetBox: each node's commit, image, result, staleness
```

`make status` answers "is it up". `make convergence-status` is one NetBox
query: it prints every compute node's last pull run and exits non-zero when a
node failed or has not converged for `CONVERGENCE_STALE_SECONDS`.

## See the inventory: NetBox

NetBox is the source of truth. It runs as a container on the lab host and is
published on the **host loopback only** — `http://127.0.0.1:8000`. It is not
on the home LAN. The provisioning segment reaches it through a separate,
host-local proxy on `10.42.0.1:8001` that only nodes use (see
[`discovery.md`](discovery.md)).

Browse it from your workstation by forwarding the port over the same SSH
connection you use to reach the lab. `$LAB_HOST_SSH` is the value from
`lab/local.env`:

```sh
ssh -N -L 8000:localhost:8000 "$LAB_HOST_SSH"
# then open http://localhost:8000
# (if 8000 is busy locally, forward 8080 instead: -L 8080:localhost:8000)
```

The superuser name, email and password are in `/etc/cluster-lab/netbox.env`
on the lab host, mode `0600` root. They are not in git and not in any image.
Read them there:

```sh
sudo grep -E '^SUPERUSER_(NAME|EMAIL|PASSWORD)=' /etc/cluster-lab/netbox.env
```

The API token is the same file's `SUPERUSER_API_KEY` and
`SUPERUSER_API_TOKEN`, combined as `nbt_<key>.<token>`. `scripts/lib/netbox.sh`
builds it for the harness and never prints it. A query straight from the lab
host:

```sh
source scripts/lib/netbox.sh
netbox_get '/api/dcim/devices/?role=compute' | jq '.results[] | {name, status}'
```

What the inventory holds:

| Object | Carries |
| --- | --- |
| Device (site `lab`, rack `rack-a`) | rack position and serial; discovery facts; burn-in measurements and verdict; convergence `last_git_sha`, `image_tag`, `convergence_result`, `last_converged_at` |
| Interface | the real NICs, and the primary MAC a node is matched by |
| IP address | the BMC, provisioning and data addresses from the three pools |

## Add a machine

### A node in the lab

Nothing is edited per node. `N` is the only input:

```sh
make demo N=5        # seed the device, render reservations, define and boot the VM
```

`NODE_COUNT` in `lab/local.env` sets the default; `N=...` overrides it for one
run. `make converge` re-seeds NetBox from `NODE_COUNT` without booting
anything, and `make nodes-up` defines and starts the nodes. The seeder creates
the device, its interface, its primary MAC and its three addresses, and the
same data drives the DHCP reservations, the Warewulf node and the Slurm
configuration. A node that already exists is left alone.

### A machine the lab did not create

The machine is added to the source of truth, then it introduces itself.

1. Add a device in NetBox (site `lab`, role `Compute`) and record its
   provisioning NIC as an interface, with the real MAC as the primary MAC.
   Matching is by MAC, so a device that owns it is adopted rather than
   duplicated. Without a match the DHCP pool still serves the machine and
   discovery creates the device from its hostname or DMI serial.
2. Run `make converge` so the DHCP reservation and the Warewulf node
   definition are rendered from the new record.
3. Set the machine to network boot and power it on. It PXE-boots the
   **discovery** image, scrapes its own DMI, CPU, memory, NICs, disks and
   GPUs, writes or updates its NetBox record, and claims its IPAM address.
   For a lab node the same flow is `make discover NODE=<name>`.
4. The device arrives `staged`. It runs its own burn-in and posts raw
   measurements; the gate on the head node is the only writer of its status.
   `make nodes-activate` runs the gate and promotes the ones that pass.

Nothing else is edited: no host file, no inventory list, no playbook.

## Remove or rebuild a node

| Want | Command |
| --- | --- |
| Stop and undefine every lab node, keep disks | `make nodes-down` |
| ...and delete their disks and nvram | `make nodes-down WIPE=1` |
| Rebuild one node without touching its neighbours | `make drill-reprovision` |

## Day 2

Every one of these is a play pushed from the head node. They are pushed
because each needs a view of the whole cluster, or an ordering; node-local
configuration stays pull. See
[`node-self-configuration.md`](node-self-configuration.md).

| Want | Command |
| --- | --- |
| Drain / resume | `make drain NODES=<node>[,<node>]` / `make resume NODES=...` |
| Re-render Slurm from NetBox and reconfigure | `make reconfigure` |
| Rolling image update, rollback on failure | `make rolling-update TAG=sha-<new>` |
| Roll the node image back | `make rollback TAG=sha-<previous>` |
| Move the config release | `make promote SHA=<commit>` |
| Judge staged nodes' burn-in | `make burnin-gate` |

## Power and consoles

Redfish is real for these nodes: `sushy-emulator` maps it to libvirt.

```sh
make redfish                                     # list the systems
bash scripts/redfish.sh power <node> on|off|cycle
bash scripts/redfish.sh boot  <node> pxe|hd
sudo virsh --connect qemu:///system console <node>
```

Each node's serial console is also written to `$LAB_VM_DIR/console/<node>.log`.

## Endpoints

| Service | Address | Reachable from |
| --- | --- | --- |
| NetBox UI and API | `http://127.0.0.1:8000` | the lab host, and your workstation over the SSH tunnel above |
| NetBox API, node-facing | `http://10.42.0.1:8001` | the provisioning segment only |
| Redfish (sushy-emulator) | `http://10.42.0.1:8000` | the provisioning segment |
| Node API | `http://10.42.0.1:8002` | the provisioning segment |
| warewulfd, iPXE and images | `http://10.42.0.1:9873` | the provisioning segment |
| node_exporter | `<node>:9100` | the segment; scraped by Prometheus on the head node |
| slurmctld / slurmd | `:6817` / `:6818` | the segment |

## Alerting and runbooks

Prometheus sends alerts to Alertmanager on the head node. Alertmanager's lab
receiver posts to `cluster-alert-webhook`, which writes notifications and
resolutions to the system journal without external credentials:

```sh
sudo journalctl -u cluster-alert-webhook -f
curl -s http://127.0.0.1:9090/api/v1/alerts | jq
curl -s http://127.0.0.1:9093/api/v2/alerts | jq
```

To use a real receiver, replace `lab-webhook` in the Ansible-owned
`alertmanager.yml`. A PagerDuty receiver uses `pagerduty_configs` with a
`routing_key` supplied from an external Ansible secret; Slack uses
`slack_configs` with an externally supplied `api_url`. Never put either value
in this public repository. Run `amtool check-config` before deploying.

### StalePull

This fires after a node's NetBox convergence timestamp is older than twice the
configured `PULL_INTERVAL_SECONDS`, or immediately after its last pull reports
failure (both conditions have a two-minute hold). Check `make
convergence-status`, the node's `cluster-pull.service` journal, mirror reachability,
and its NetBox convergence fields. Re-run the timer only after fixing the
reported failed task.

### BurnInFailed

This fires when the head-node burn-in gate sets a device to `failed` in NetBox.
Inspect its `burnin_results` and `burnin_verdict` custom fields and the node's
burn-in journal. Fix or replace the failing component, return the node to
`staged`, rerun burn-in, then run `make burnin-gate`; do not manually promote it.

### NodeDown

Confirm the VM or machine state, provisioning network, and `prometheus-node-exporter`
service. For the lab drill, stop exactly one VM, watch the alert reach the
webhook journal, restart it, and retain the firing and resolved entries.

### SlurmctldDown

Run `scontrol ping`, then inspect `slurmctld`, `munge`, and the controller log.
Restore Munge first if authentication fails. The local Slurm exporter reports
controller reachability even when `sinfo` cannot list nodes.

### SlurmNodeUnavailable

Compare `sinfo --Node --long` with the device's NetBox state and node journal.
Resolve the root cause before `make resume NODES=<node>`; an intentional drain
may be silenced in Alertmanager during its maintenance window.

For the host itself and what it needs, see
[`lab-host-setup.md`](lab-host-setup.md).
