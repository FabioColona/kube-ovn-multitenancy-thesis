# 01 — Flat-network CNIs: Flannel, Calico, Cilium

Scripts that install a single-node K3s with each CNI and run the functional tests of the thesis
(Chapter 3). The tests are **functional, not performance tests**: single node, ingress traffic only, TCP/80.

> **Warning.** The installation scripts delete and recreate K3s (`90-reset.sh` removes `/etc/rancher`,
> `/var/lib/rancher`, the CNI state and the iptables rules of K3s and the CNIs).
> Use a **disposable virtual machine**, never a machine you care about.

## Requirements

- Linux (x86_64 or aarch64) with systemd, bash >= 4, curl, tar, `sudo`, Internet access.
- Recommended: **4 vCPU and 6 GB RAM**. With 2 vCPU and 3.5 GB, Calico in eBPF mode went into a crash loop and made
  the machine unusable while it downloaded images.
- Nothing else to install: the scripts download K3s, Calico and the Cilium CLI at the versions pinned in `config.env`.

## Quick start

```bash
cd 01-flat-network-cni
./00-preflight.sh                      # read-only checks of the machine
./10-install-flannel.sh                # or 11-install-calico.sh / 13-install-cilium.sh
./20-paper-wall.sh                     # test for the CNI you installed (see table)
./90-reset.sh                          # back to a clean machine, then install the next CNI
```

Every script asks for confirmation before changing anything (`--yes` skips the question) and asks for the `sudo`
password once. Each one prints a header with what it does and how to use it (`head -25 <script>`), and ends
with a results table. Nothing is written to log files: the table is the result. Exit code: `0` no FAIL,
`1` at least one FAIL, `2` prerequisite missing.

## Scripts

| Script | What it does |
|---|---|
| `00-preflight.sh` | Read-only checks: OS, architecture, CPU, memory, disk, network, address overlap, tools |
| `10-install-flannel.sh` | K3s with Flannel and **no** policy controller (NetworkPolicy objects exist but nothing enforces them) |
| `11-install-calico.sh [iptables\|ebpf]` | K3s + Calico, iptables or eBPF data plane (eBPF: no kube-proxy, VXLAN) |
| `13-install-cilium.sh [strict\|legacy]` | K3s + Cilium; strict replaces kube-proxy, legacy keeps it |
| `20-paper-wall.sh` | Test **paper-wall** (Flannel): policies are accepted but nothing is blocked |
| `21-closed-door.sh` | Test **closed-door** (Calico, Cilium): default-deny and allow-list really block |
| `22-flannel-controller.sh` | Control case of **paper-wall**: Flannel with the K3s policy controller on; blocked flows are refused (curl exit 7) |
| `30-blind-spot.sh` | Test **blind-spot** (Calico): L3/L4 only, every HTTP method and path passes on an allowed port |
| `31-path-guard.sh` | Test **path-guard** (Cilium): HTTP rule "only GET /public" gives 200 / 403 |
| `32-side-door.sh` | Test **side-door** (Cilium): what the application really receives behind the HTTP rule |
| `90-reset.sh` | Removes K3s and everything the CNIs leave on the node |
| `lib-cni.sh`, `../lib/common.sh` | Shared functions (not run directly) |

Which test for which CNI:

| Installed with | Run |
|---|---|
| `10-install-flannel.sh` | `20-paper-wall.sh` |
| `FLANNEL_POLICY=on ./10-install-flannel.sh` | `22-flannel-controller.sh` |
| `11-install-calico.sh iptables` or `ebpf` | `21-closed-door.sh`, `30-blind-spot.sh` |
| `13-install-cilium.sh strict` or `legacy` | `21-closed-door.sh`, `31-path-guard.sh`, `32-side-door.sh` |

The tests detect the installed CNI by themselves and stop with a clear message if you run the wrong one.

## Configuration

Values are in `config.env` (K3s, Calico and Cilium versions, pod CIDR, repetitions). **Do not edit it:**
create `config.local.env` next to it with only the lines you want to change; it is ignored by git and wins over
`config.env`. A variable set in the environment wins over both:

```bash
REPETITIONS=1 ./21-closed-door.sh                       # quick check
CALICO_MODE=ebpf ./11-install-calico.sh                 # same as the argument
HTTP_REQUESTS=30 ./32-side-door.sh                      # requests per type in side-door
```

The pod CIDR (`10.244.0.0/16`) must **not overlap your LAN**: with `192.168.0.0/16` Calico creates blackhole
routes towards the local network.

## Reading the results

Each row is `TEST / EXPECTED / OBTAINED / STATUS`. Outcomes: `PASS` (as expected), `FAIL` (not as expected),
`INCONCLUSIVE`, `BLOCKED`, `NOT RUN`. "blocked" means the connection never completed (curl timeout);
"refused" means the connection was rejected (curl exit 7, what the K3s policy controller does);
"open" means HTTP 200.

`32-side-door.sh` deserves two remarks. A `FAIL` on the rows "reached the server" of the forbidden HTTP requests
means that **the proxy answered 403 to the client but the forbidden request still arrived at the application**. It did
not happen with Cilium 1.18.6, the version used in the thesis. For the non-HTTP payloads every phase is run with two
raw clients: one closes its sending side right after the payload ("half-closed"), the other keeps the connection open;
both also send an allowed `GET /public` as a control. With Cilium 1.18.6 and the HTTP rule the half-closed client does
not get even the allowed request through the proxy (row `INCONCLUSIVE`), so the rows that decide are those marked
"connection kept open": the payloads must not arrive and the control must. The other rows are controls: without
policy everything must arrive, with `ingressDeny` nothing must.

## Known issues

- **Calico eBPF on kernel 7.0**: `calico-node` panics at start (the kernel refuses the BPF program
  `calico_sendmsg_v46`). `11-install-calico.sh ebpf` disables connect-time load balancing in the FelixConfiguration
  (`CALICO_BPF_DISABLE_CONNECT_LB=yes`, set `no` on other kernels).
- **Cilium legacy**: `cilium-cli` forces strict when it does not see a kube-proxy pod (the K3s one is a process),
  so the script sets `kube-proxy-replacement: disabled` by hand and restarts the agent.
- **Duration**: Calico images are large; on a slow link the installation can take 20 minutes or more. Do not interrupt
  it with Ctrl+C while it says "Waiting for Calico".
- Calico `v3.28.0` and Cilium `v1.18.6` are pinned on purpose (they are the versions used for the thesis).
