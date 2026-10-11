# Network isolation

The provisioning segment runs DHCP and TFTP. Both answer anything that
asks. If that segment could reach the home LAN, a DHCP offer could land on
a family laptop and a TFTP request could be served to anything on the
network. So the rule is absolute: **DHCP and TFTP never run on an interface
that can reach the home LAN.**

## The design

`br-prov` is a Linux bridge with **no uplink port**. Nothing is ever
enslaved to it except node taps. There is no path off the segment by
construction, not by policy.

On top of that, three measures turn a property of the current
configuration into an enforced one.

**1. Forwarding off at the interface.**
`net.ipv4.conf.br-prov.forwarding = 0`. Even if a route appeared, the
kernel would not forward between the bridge and anything else.

This one is **advisory, not enforcement**, and the reason is worth knowing
because it was found the hard way. Docker writes
`net.ipv4.conf.all.forwarding = 1` when it starts, and a write to `all`
sets the same knob on every interface — including ours. So the value is
correct after `make up` and turns back on the next time Docker restarts.
Two consequences:

- `lab-net.service` is ordered `After=docker.service`, so the value is
  right after a cold start rather than being set and immediately undone.
- Nothing depends on it. Measure 2 is the enforcement, and it survives
  anything Docker does. `make verify-isolation` asserts measure 2 and only
  reports measure 1.

**2. Our own nftables table.**

```
table inet cluster_lab {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "br-prov" oifname != "br-prov" counter drop
    oifname "br-prov" iifname != "br-prov" counter drop
  }
}
```

A separate table from the one Docker manages, so the two never fight, and
a drop in any table is final. Priority `-10` puts it ahead of Docker's
chains. The counters are visible in `make status`, so a drop is evidence
rather than a guess.

**3. dnsmasq is bound, not filtered.**

```
interface=br-prov
bind-interfaces
except-interface=lo
listen-address=10.42.0.1
```

`bind-interfaces` makes dnsmasq open a socket on that interface only,
rather than binding the wildcard address and discarding what it does not
want. A misconfiguration elsewhere cannot make it answer on `eth0`.

`no-resolv` with no upstream server is deliberate: nodes on the segment get
names from the segment and nothing else. There is no DNS path outward to
leak through.

## How it is proven

`make verify-isolation` runs three tests, weakest first.

**A. Route dump.** The only forwarding route naming the bridge is its own
subnet.

**B. Host-side ping bound to the bridge.** `ping -I br-prov <home LAN>`
fails at route lookup, because the kernel has no route to that network out
of that interface.

**C. Node-side ping.** A network namespace is attached to the bridge and
configured exactly as a provisioned node would be: an address from the DHCP
pool and a default route via the segment gateway. From there:

- the segment gateway answers, so the segment genuinely carries traffic;
- the home LAN does not, so a node cannot get out.

Test C is the one that matters. A and B say the host cannot route out of
the bridge. C answers the real question, which is what a node sitting on
the segment can reach. A namespace is used instead of a booted node because
it needs no image and no boot, so the test can run on every change.

The home LAN address used as the probe target is a host value. It lives in
`lab/local.env` as `LAB_LAN_PROBE_IP` and is never in a tracked file; the
test output replaces it with `<LAB_LAN_PROBE_IP>` before printing.

## What is deliberately not done

No NAT, no masquerade, no uplink, not even a disabled one. Nodes do not
need the internet: images come from Warewulf, and packages are baked into
the image rather than pulled at boot. Adding an uplink later would mean
re-proving isolation, so it stays absent until something actually needs it.
