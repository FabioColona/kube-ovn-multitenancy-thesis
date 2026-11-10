# 02 — Kube-OVN setup (one site)

Installs a single-node K3s cluster with **Kube-OVN** as CNI, and checks that it works.
Run the same scripts on every machine that will be a site; only the values in `config.local.env` change.

## Requirements

- Linux (x86_64 or aarch64) with systemd, 2+ CPUs, 4 GB RAM, 10 GB free, Internet access.
- Kernel with the `openvswitch` module (checked by `00-preflight.sh`).
- A user with `sudo` (the password is asked once).

## Quick start

```bash
./00-preflight.sh          # read-only: tells you if something is wrong
./10-install-kube-ovn.sh   # about 5 minutes, prints a results table at the end
./90-reset.sh              # removes everything (to start again)
```

## Scripts

| Script | Changes the machine | What it does |
|---|---|---|
| `00-preflight.sh` | no | machine, tools, Internet, kernel modules, CIDR overlaps, leftovers |
| `10-install-kube-ovn.sh` | yes | K3s + Kube-OVN, then checks nodes, pods, subnets, VPC, pod-to-pod, DNS, service |
| `90-reset.sh` | yes (destructive) | removes K3s and the Kube-OVN/OVS state on the host |

## Configuration

Do not edit `config.env`. Create `config.local.env` next to it with only the lines you want to change
(it is ignored by git), or set variables on the command line:

```bash
SVC_CIDR=10.97.0.0/16 JOIN_CIDR=100.65.0.0/16 POD_CIDR=10.17.0.0/16 ./10-install-kube-ovn.sh
```

With several sites interconnected by OVN-IC (later phase) the pod, service and join networks
**must be different on every site**.

## Notes

- `install.sh` of Kube-OVN ignores environment variables for the networks, so the script rewrites the
  values inside the downloaded file and stops if it cannot.
- CoreDNS fix (K3s issue 5466) is applied only if CoreDNS does not start.
- `OVN_DB_IPS` of `ovs-ovn` is pointed to the `ovn-sb` ClusterIP (a fix verified in the lab).
