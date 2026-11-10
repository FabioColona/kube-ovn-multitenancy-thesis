# Kube-OVN multi-tenancy: test scripts of the thesis

Scripts used for the master's thesis *Enforcing Strong Network Isolation in Kubernetes Multi-tenant Clusters*
(Politecnico di Torino, 2026). They build small Kubernetes clusters, configure tenant networks and run the isolation,
inter-site and north-south tests described in the thesis. The test scripts print a table of results
(`PASS`, `FAIL`, `INCONCLUSIVE`, `BLOCKED`, `NOT RUN`); the read-only checks (`00-preflight.sh`) and a few helper
scripts print a summary instead.

> **Warning.** The scripts change the machines they run on or reach through SSH (they install and delete K3s, create
> interfaces, namespaces and firewall rules, and some break a network on purpose). Use **disposable virtual machines**.
>
> The raw outputs of the measurements are **not** published here; the scripts reproduce them and the numbers are in the
> thesis, each with the environment it was measured in. Numbers must not be compared across environments.

## Folders

Each folder has its own README with the order of the scripts, what each one changes and the known problems.

| Folder | What it covers | Machines |
|---|---|---|
| [`01-flat-network-cni`](01-flat-network-cni) | Flannel, Calico, Cilium: what NetworkPolicy really blocks | 1 |
| [`02-kube-ovn-setup`](02-kube-ovn-setup) | K3s + Kube-OVN on one machine (one site) | 1 |
| [`03-kube-ovn-tenancy`](03-kube-ovn-tenancy) | tenants in one site: private subnets, custom VPCs, peering, `port_security`, admission policy | 1 (from 02) |
| [`04-kube-ovn-ic`](04-kube-ovn-ic) | two sites with OVN-IC: tenants across sites, route announcements, RBAC, IC database failover | 3 |
| [`05-north-south`](05-north-south) | VPC NAT Gateway against OVN Gateway (ECMP, BFD): throughput and gateway failure | 2 to 4 |
| [`lib`](lib) | shared functions (not run directly) | |

## Requirements

Linux machines (Ubuntu 24.04 or later, x86_64) with `systemd` and Internet access. Folders 01–03 run on the machine
itself (01 and 02 ask for the `sudo` password once; 03 uses only `kubectl`); folders 04 and 05 drive remote machines through SSH and need a user with
passwordless `sudo` there. On the computer where you run 04 and 05: `bash` (3.2 on macOS is fine), `ssh`, `scp`.
Versions are pinned in each `config.env` (K3s v1.34.6+k3s1, Kube-OVN v1.13.0, Multus v4.2.2).

## Configure your environment

The repository contains **no real host name, address or credential**: `config.env` holds placeholders and must not be
edited. In the folder you want to use, create `config.local.env` next to it with only the lines to change (it is ignored
by git and wins over `config.env`); a variable on the command line wins over both.

| Folder | Variables to set |
|---|---|
| 01, 02, 03 | none: the scripts run on the local machine (01 also lets you choose the CNI versions and modes) |
| 04 | `SITE_A_HOST`, `SITE_B_HOST`, `ROUTER_HOST` with their `_PORT` and `_USER`, `SSH_JUMP`, and the addresses `SITE_A_IP`, `SITE_B_IP`, `SITE_A_ROUTER_IP`, `SITE_B_ROUTER_IP`, `SITE_A_IFACE`, `SITE_B_IFACE` (see `04-kube-ovn-ic/config.local.env.example`) |
| 05 | `NODES` (SSH names or addresses, numbered 1, 2, 3 by position), `NODE_USER`, `SSH_PORT`, `SSH_JUMP`, and `CLUSTER_NODES`, `GATEWAY_NODES`, `FABRIC_NODE` (which machines join the cluster, which may be gateways, which hosts the simulated customer network) |

`SSH_JUMP` is a jump host as `user@host`, empty if you reach the machines directly.

The `10.x`, `172.31.x`, `169.254.x`, `192.168.50.x` and `192.168.70.x` addresses in scripts and `manifests/` are networks
**created inside the experiment**, not real infrastructure; the `192.0.2.x` addresses and the `*.example.org` names are
placeholders to replace in `config.local.env`. Change them only if they collide with yours, and everywhere at once. Pod, service
and join CIDRs must not overlap your LAN and must differ between sites.

## Run

```bash
cd 02-kube-ovn-setup
./00-preflight.sh          # read-only checks
./10-install-kube-ovn.sh   # asks for confirmation (--yes skips it)
cd ../03-kube-ovn-tenancy
./10-apply-tenants.sh
./20-private-subnet.sh     # prints the results table
```

Scripts are numbered by topic: `00` is a read-only check, `1x` installs, the following numbers are the tests and the
helper scripts, and `9x` removes what the folder created. Run them in the order listed in the README of each folder. There is no script that runs everything. If the scripts are not executable after the download (for example after extracting a zip on some systems), run
`chmod +x */*.sh` once from the root of the repository. Every script starts with a header
(`head -25 <script>`) saying what it does, what it changes and how long it takes. Exit code: `0` no FAIL and every check could run, `1` at least one FAIL (or a check that could not run: `BLOCKED`, `NOT RUN`), `2` a prerequisite is missing. A probe that cannot be executed (SSH or `kubectl exec` fails, the pod is gone) gives `error`, never `blocked`, so a check that expects "blocked" does not pass because the probe did not run.
