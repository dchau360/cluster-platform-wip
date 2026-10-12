# Soft-RoCE: a real RDMA data path, and not InfiniBand

This lab has no InfiniBand hardware. It has a Windows box running WSL2, and
the nodes are KVM guests with virtio NICs on a software bridge. What it does
have is a genuine RDMA data path, and this document is careful about the
difference, because the difference is the whole point.

## What is real

`rdma_rxe` — Soft-RoCE — is the kernel's software RoCE provider. Loaded on a
node, it presents that node's ordinary Ethernet NIC as an RDMA device. A
program that links `libibverbs` then does the real thing against it:

- creates a protection domain and registers memory,
- creates queue pairs and completion queues,
- exchanges addressing with the peer and moves the QP through
  `INIT → RTR → RTS`,
- posts RDMA `WRITE` and `SEND` work requests,
- reaps completions from the CQ.

Those are the verbs, not a simulation of them. `perftest` is the standard
benchmark from `rdma-core`'s own toolchain, unmodified, and it is the same
binary people run against an HCA. The bandwidth it reports here is measured
from real completions on a real queue pair.

## What is not real

- **There is no HCA.** Every packet is built, copied and checksummed by the
  host CPU. The number below is a property of this software path on this
  host; it is not a prediction of what a ConnectX would do, and nothing in
  this repository claims otherwise.
- **There is no subnet manager.** No OpenSM, no `opensm.service`, nothing to
  assign LIDs. RoCE runs over Ethernet and UDP, so there is nothing for a
  subnet manager to do. An InfiniBand fabric would need one, and standing one
  up is a step this lab has never performed.
- **There is no offload, no hardware GID table and no hardware PFC.** RoCE at
  speed needs lossless Ethernet — PFC, ECN, DCQCN — configured on real
  switches. This lab has a Linux bridge.
- **The port speed is fiction.** `ibv_devinfo` reports what the underlying
  netdev claims. It describes the virtio link, not an IB rate.

The honest one-line summary: *the verbs path is genuine, the fabric is not.*

## How the device gets there

The node configures it, in its own pull run, because the node is the only
thing that knows which of its links holds the provisioning address — and
because nobody can log in to a compute node to do it by hand.

`ansible/roles/rdma_soft_roce`, run from `local.yml` on every pull:

1. finds the interface holding the node's NetBox address,
2. writes `/etc/modules-load.d/cluster-rdma-rxe.conf` so the driver is loaded
   on every boot, and loads it now if it is not loaded,
3. `rdma link add <name> type rxe netdev <that interface>`, skipped when the
   link already exists, which is what makes a second pull run change nothing,
4. confirms `ibv_devinfo -d <name>` opens the device, so a link with no verbs
   device behind it fails here rather than inside the benchmark,
5. writes `/etc/cluster-lab/rdma-device`, which the test reads back.

The userspace comes from the node image
(`cluster-images-wip/images/compute-base`): `rdma-core`,
`libibverbs-utils`, `perftest`. It has to come from the image — the
provisioning segment has no uplink and no package mirror, so a node cannot
install a benchmark for itself at boot.

## How the benchmark runs without logging in to a node

It does not log in. A compute node has no inbound SSH and holds no
credential of its own; that invariant is not suspended for a test.

`make rdma-test` submits two Slurm jobs: the `perftest` server pinned to one
node of the pair, the client pinned to the other. That is the same path any
user's job takes. The client's result table is the measurement, and
`$LAB_STATE_DIR/rdma/` keeps both logs and an appended `results.tsv`.

```sh
make rdma-test                 # the pair from RDMA_TEST_{SERVER,CLIENT}_INDEX
```

The pair is given by node index, not by name, so nothing in the harness knows
a node name or a node count.

## Measured

Recorded on the lab host. `ib_write_bw` is the one-sided verb (the initiator
writes straight into the peer's registered memory, with no peer CPU
involvement in the data path) and `ib_send_bw` the two-sided one (the peer
posts receives). Both ran over `rdma_rxe` on the provisioning NIC of two
nodes.

<!-- MEASURED-RDMA -->

### Reading it

The figure to compare against is not an HCA's line rate. It is `iperf3` over
the same virtio link on the same host: that is the TCP path this software
RDMA path is substituting for, and the comparison says what Soft-RoCE costs
and buys *here*. Against an HCA the comparison is meaningless, because the
thing an HCA provides — the data path in silicon — is exactly what is absent.

## Stated plainly: what this does not test

Two gaps follow from having no hardware, and they are gaps in the evidence,
not in the design:

- **Real HCA behaviour.** Device discovery against a vendor driver, firmware
  versions, GID table layout, link training, PFC and ECN configuration,
  and the per-vendor quirks that make up most of the real work of bringing
  up an IB or RoCE fabric. None of it is exercised here.
- **A subnet manager.** The lab has never run one. The topology this
  repository renders (`topology.conf`, from NetBox) describes a fabric that
  does not physically exist; see
  [`ib-and-dhcp-option61.md`](ib-and-dhcp-option61.md), which is equally
  explicit that the GUID work was written against synthetic data.
