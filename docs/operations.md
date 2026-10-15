# Operations

The commands an operator actually runs, and where the consoles are. Run them
on the **lab host** (inside WSL) unless a step says otherwise. `make help`
lists every target.

## Use the cluster from your workstation

Two commands on the lab host set everything up, once:

```sh
make authorize-key KEY='ssh-ed25519 AAAA... you@laptop'   # your workstation's public key
make -s ssh-config                                         # prints a ~/.ssh/config block
```

Append the printed block to `~/.ssh/config` on your workstation. It reaches
the head node through the Windows box with `wsl -e nc`, so nothing on Windows
is reconfigured and no WSL address that changes on restart is written down.
Then, from the workstation:

| You want to | Run |
| --- | --- |
| A shell on the head node | `ssh cluster` |
| A root shell on a node | `ssh cn01` (jumps through the head node) |
| NetBox, Prometheus, Alertmanager in a browser | `ssh -N cluster-tunnel`, then open `http://localhost:8000`, `:9090`, `:9093` |
| Copy files in or out | `scp file cluster:` or `scp file cn01:/tmp/` |

On the head node itself, `sudo ssh cn01` works, and so does `ssh cn01` as a
job user (see below). Node names resolve on the head node from the same
NetBox addresses Warewulf uses.

### Log in to nodes

Root logs in with a key from the head node's `/root/.ssh/authorized_keys`,
which Warewulf delivers to every node; `make authorize-key` adds yours there.
Job users (`hpc`) log in with the key in their own `~/.ssh`, which every node
sees because `/home` is shared; the head-node play gives each job user a
cluster key that is already authorized, which is what MPI launchers need.
The full picture, and what to do when a login fails, is in
[Log in to a node](#log-in-to-a-node).

### Shared storage

The head node exports two directories to the provisioning segment
(`roles/nfs_server`), and every node mounts them (`roles/shared_storage`):

| Path | On nodes | Use it for |
| --- | --- | --- |
| `/home` | read-write | job users' files, job output, their ssh keys |
| `/opt/software` | read-only | software you install once and use everywhere |

### Install software

Nodes are stateless and have no route to the internet, so `dnf install` on a
node has no repository to reach, and anything installed by hand disappears at
the next reboot. There are two right places:

1. **Applications and toolchains: `/opt/software` on the head node.**
   Install there as `hpc` or root, and every node sees it at once. Binary
   releases, Python virtual environments, conda environments and Spack all
   work this way:
   ```sh
   ssh cluster
   sudo -u hpc python3 -m venv /opt/software/venvs/sci
   sudo -u hpc /opt/software/venvs/sci/bin/pip install numpy
   sudo -u hpc srun -N4 /opt/software/venvs/sci/bin/python -c 'import numpy; print(numpy.__version__)'
   ```
   The head node is Ubuntu and the nodes are Rocky 9. Pure-Python packages
   and static binaries do not care; anything that links against system
   libraries should be built for Rocky 9, for example in a scratch copy of the
   node image (below).
2. **System packages, drivers, libraries every node needs: the image.** See
   the next section. It is the only route that survives a reboot and is the
   same on every node.

### Images

Images are built in GitHub, never edited on the server. Every merge to
`cluster-images-wip` publishes an immutable `sha-<commit>` tag to GHCR.

```sh
sudo wwctl image list                            # what is imported
sudo wwctl node list -a cn01 | grep -i image     # what a node runs
```

- **Add a package:** add it to `images/compute-base/packages.txt` (every node)
  or `images/compute-slurm/packages.txt`, open a PR, merge. The tag is in the
  Actions run summary.
- **Roll it out:** `make rolling-update TAG=sha-<commit>`: drain, reboot onto
  the new image, health-check and resume, one node at a time, stopping and
  restoring the old image on a failure. `make rollback TAG=sha-<previous>`
  goes back.
- **A new image:** add `images/<name>/` with a `Containerfile` (usually
  `FROM` compute-base) and a `packages.txt`. CI builds every directory under
  `images/`. Import it with `sudo wwctl image import --build
  docker://ghcr.io/<owner>/cluster-images-wip/<name>:sha-<commit> <name>` and
  point a node at it with `sudo wwctl node set -y <node> --image <name>`.
- **Experiments only:** `sudo wwctl image copy compute-slurm scratch && sudo
  wwctl image shell scratch`, then `sudo wwctl image build scratch`. That copy
  traces to no commit; move anything worth keeping into the repo.

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
host-local proxy on `10.44.0.1:8001` that only nodes use (see
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

## Accounting

Every job and step is recorded in a MariaDB database on the head node.
`slurmctld` sends the records to `slurmdbd`, the only client of the database;
nodes talk to neither. The `slurm_accounting` role installs and configures
both. `slurm.conf` sets `AccountingStorageType=accounting_storage/slurmdbd`
and `JobAcctGatherType=jobacct_gather/cgroup`, so each step's CPU, memory and
I/O come from its cgroup on the node.

Read the history on the lab host:

```sh
sacct                                      # your jobs since midnight
sacct -a -S now-1day -X \
  -o JobID,User,Account,NodeList,Elapsed,State,ExitCode   # everyone's, one line per job
sacct -j <jobid> -o JobID,NodeList,Elapsed,MaxRSS,TotalCPU,State,ExitCode   # with steps
sreport cluster utilization start=now-7days             # cluster busy/idle/down
sreport user topusage start=now-30days                  # who used the hours
sacctmgr show association format=Cluster,Account,User   # who may run where
```

An array task is `<jobid>_<index>`. `-X` shows allocations only and hides
the steps.

What the role creates, and how to change it:

| Thing | Where | Change it with |
| --- | --- | --- |
| Cluster | `SLURM_CLUSTER_NAME` | `lab/local.env`, then `make converge` |
| Account the job users belong to | `SLURM_ACCOUNT` | `lab/local.env`, then `make converge` |
| Users in that account | `cluster_job_users` in `ansible/group_vars/all.yml` | the file, then `make converge` |
| `slurmdbd` port | `SLURMDBD_PORT` | `lab/local.env`, then `make converge` |
| Retention (jobs 12 months, steps 6) | `slurm_accounting_purge_after` | role defaults |

The role reads each association first and adds only the missing ones, so it
never removes anything. To remove a user or account, run `sacctmgr remove
user <name>` or `sacctmgr remove account <name>` by hand, and take it out of
the variables too, or the next converge adds it back.
`AccountingStorageEnforce` is not set. Every job is recorded, and a user
with no association can still run jobs. Turn enforcement on once every
submitting user has an association.

The database password is generated on the head node the first time the role
runs. It is stored in `/etc/cluster-lab/slurmdbd-db.password`, mode `0600`
root, and rendered into `/etc/slurm/slurmdbd.conf`, mode `0600` slurm. It is
not in git, not in an image, and not in any variable. To rotate it, delete the
file and run `make converge`: the role makes a new password, resets the
database user to it, re-renders `slurmdbd.conf` and restarts `slurmdbd`.
`slurmctld` keeps records it cannot send while `slurmdbd` is away and sends
them when it comes back.

On a cold start, systemd brings up `mariadb`, then `slurmdbd`, then
`slurmctld`. `slurmdbd`'s start job ends only once it is listening, and
`make cold-start-check` checks that order. To find out why a job went
missing:

```sh
systemctl status mariadb slurmdbd slurmctld
sudo tail -n 50 /var/log/slurm/slurmdbd.log
sacctmgr show cluster          # the cluster is registered, with a ControlHost
sdiag | grep -A3 'DBD Agent'   # records waiting for slurmdbd; non-zero for long = trouble
```

## Log in to a node

From the head node, as root, by name:

```sh
sudo ssh cn01
sudo ssh cn01 hostname          # one command
```

What makes that work, and where each piece comes from:

| Piece | Source |
| --- | --- |
| sshd running on the node, key only (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`) | `node_sshd`, a node-local role in `ansible/local.yml`; the node applies it itself on its first pull run after boot |
| The head node's root key in the node's `/root/.ssh/authorized_keys` | warewulf's `ssh.authorized_keys` runtime overlay |
| The node's host keys | warewulf's `ssh.host_keys` overlay: one key set per cluster, generated by `wwctl configure ssh` |
| No host-key prompt on first login, from the head node or from another node | the `warewulf_server` role writes a marked block in the head node's `/etc/ssh/ssh_known_hosts`: that key set, for every node name and address NetBox lists. The same lines reach every node's `/etc/ssh/ssh_known_hosts` through the `cluster-identity` runtime overlay, so `ssh cn02` from a job on cn01 asks nothing |
| Node names resolving on the head node | a marked block in `/etc/hosts` (`<ip> <node> <node>.<domain>`), rendered from NetBox by the `dnsmasq` role. WSL rewrites `/etc/hosts` at every start, so `scripts/net-up.sh` restores the block at boot from the last render |

Do not edit either marked block by hand; change NetBox and run
`make converge`. A node added to NetBox gets its name and host-key entry on the
next converge.

Who can log in, and with what:

- **root**, with the head node's root key or any key added with
  `make authorize-key` (your workstation's). Both reach the node through
  that one `authorized_keys` file and the overlay.
- **job users**, with the key in their own `~/.ssh/authorized_keys` on the
  shared `/home`. The head-node play generates and authorizes a cluster key
  for each one, so `hpc` can `ssh cn02` from the head node or from any node.

Users can also reach a node through Slurm: `srun -w cn01 --pty bash`. On a
production cluster, user SSH is fenced with `pam_slurm_adopt`, which lets a
user log in only to a node running one of their jobs and adopts the session
into that job's cgroup. It is not built here: the Slurm image does not ship
`slurm-pam_slurm`, and it belongs with directory-backed users
([production-readiness 5.5](production-readiness.md#55-ldapsssd-identity)).

Login is for looking. Nothing in this repository configures a node over SSH;
a change made by hand in a session is undone by the next pull run or the next
reboot. Make the change in a role and promote it.

If `sudo ssh cn01` fails:

- `Could not resolve hostname`: the `/etc/hosts` block is missing. Run
  `make converge`, or `bash scripts/net-up.sh` to restore it from the last render.
- `Connection refused`: the node's pull run has not reached `node_sshd` yet,
  or it failed. `make convergence-status` shows the node's last run;
  the serial log is `$LAB_VM_DIR/console/<node>.log`.
- `Permission denied (publickey)`: the `ssh.authorized_keys` overlay did not
  reach the node. `srun -w cn01 cat /root/.ssh/authorized_keys` shows what did.

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
| NetBox API, node-facing | `http://10.44.0.1:8001` | the provisioning segment only |
| Redfish (sushy-emulator) | `http://10.44.0.1:8000` | the provisioning segment |
| Node API | `http://10.44.0.1:8002` | the provisioning segment |
| warewulfd, iPXE and images | `http://10.44.0.1:9873` | the provisioning segment |
| node_exporter | `<node>:9100` | the segment; scraped by Prometheus on the head node |
| slurmctld / slurmd | `:6817` / `:6818` | the segment |
| slurmdbd | `:6819` | listens on every address, Munge-authenticated; its clients are on the head node (`slurmctld`, `sacct`, `sacctmgr`) |
| sshd, head node | `:22` | your workstation, through `ssh cluster` |
| sshd, nodes, key only | `<node>:22` | the head node; your workstation through `ssh <node>`. See [Log in to a node](#log-in-to-a-node) |
| NFS (`/home`, `/opt/software`) | `10.44.0.1:2049` | the provisioning segment |
| Prometheus | `:9090` | the lab host; your workstation through `ssh -N cluster-tunnel` |
| Alertmanager | `:9093` | the lab host; your workstation through `ssh -N cluster-tunnel` |
| MariaDB (accounting) | `127.0.0.1:3306` and the local socket | `slurmdbd` only |

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
