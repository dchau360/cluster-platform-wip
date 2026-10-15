# Lab host setup

The lab runs inside WSL2 on a single Windows workstation. Everything below
is installed once; after that `make up` is the only command needed.

## Requirements

| Requirement | Why |
| --- | --- |
| WSL2 with `systemd=true` in `/etc/wsl.conf` | Every lab service is a systemd unit enabled at boot |
| Nested virtualization on, `/dev/kvm` present | Nodes are KVM guests, not emulated |
| Passwordless `sudo` inside WSL | The harness configures the network and libvirt unattended |
| Free disk for node images | `NODE_DISK_GB` per node, thin-provisioned qcow2 |

## Packages

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  libvirt-daemon-system libvirt-clients libvirt-daemon-driver-qemu \
  qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools \
  bridge-utils iproute2 nftables \
  dnsmasq dnsmasq-utils \
  docker.io \
  ansible-core ansible-lint python3-libvirt python3-lxml \
  yamllint shellcheck make jq curl
```

On Ubuntu 26.04 there is no `qemu-kvm` package. `qemu-system-x86` provides
the emulator; KVM comes from the kernel.

`gitleaks` is not packaged. Install the release binary:

```sh
GL=8.30.1
curl -fsSL -o /tmp/gitleaks.tgz \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GL}/gitleaks_${GL}_linux_x64.tar.gz"
sudo tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks
```

## Two services must be masked

The distribution's `dnsmasq.service` and `tftpd-hpa.service` would both
claim ports our own `lab-dnsmasq.service` needs, and neither is bound to
the provisioning bridge. Mask them so they can never start:

```sh
sudo systemctl disable --now dnsmasq.service tftpd-hpa.service
sudo systemctl mask dnsmasq.service tftpd-hpa.service
```

`make cold-start-check` asserts this, because the failure mode is a lab
that comes back after a reboot with DHCP answering on the wrong interface.

## libvirt

```sh
sudo systemctl enable --now libvirtd.socket
sudo usermod -aG kvm,libvirt,docker "$USER"
# libvirt's default NAT network is NOT used. Nodes live on the isolated
# bridge, so leaving it autostarted only invites confusion -- and it is a
# routed network, which is exactly what this project must not have.
sudo virsh net-destroy default || true
sudo virsh net-autostart --disable default || true
```

Node disks and per-VM UEFI nvram go under `LAB_VM_DIR`, which defaults to a
path inside the libvirt image tree. That is not cosmetic: the libvirt
AppArmor profile already grants QEMU access there, and a path outside it
gets denied at VM start.

## Keep WSL running when nobody is logged in

By default WSL powers a distribution off about a minute after its last
session closes, and that takes the head node and every node VM with it. It
happens even with `vmIdleTimeout=-1`: that setting keeps the WSL VM alive,
not the distribution. Both settings go in `%USERPROFILE%\.wslconfig` on
Windows:

```ini
[general]
instanceIdleTimeout=-1

[wsl2]
vmIdleTimeout=-1
nestedVirtualization=true
```

Then `wsl --shutdown` once to apply them. This was measured on the lab: with
only `vmIdleTimeout` set, the distribution logged `The system will power off
now!` 40 seconds after the last SSH session closed, part-way through a
`make demo`. With both set, it stayed up.

## Cold start

WSL does not boot with Windows. It starts when something first enters the
distribution. For the lab to come back by itself after a Windows reboot,
Windows needs to enter it once at logon:

```powershell
# Run once, in an elevated PowerShell on the Windows side.
.\scripts\windows\install-autostart.ps1
```

That registers a logon task that runs `wsl -d <distro> -- /bin/true`, which
is enough to boot the distribution. systemd then starts `lab.target` and
everything with it.

After a `wsl --shutdown`, the next command into the distribution does the
same thing. Either way `make up` is idempotent, so running it costs
nothing and changes nothing if the units already came back.

## Verifying the host

```sh
make up                   # should end with RESULT: changed=0 on a second run
make cold-start-check     # every lab unit enabled at boot
make verify-isolation     # the segment cannot reach the home LAN
make demo N=2             # two UEFI nodes, DHCP leases, timing table
```
