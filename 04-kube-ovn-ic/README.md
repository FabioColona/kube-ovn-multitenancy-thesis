# 04 — OVN-IC between two sites

Two Kube-OVN clusters (one node each) interconnected with OVN-IC, plus a third machine that is the third member of the
IC database (Raft). The scripts run on **your computer** and reach the three machines (site A, site B, third machine)
with SSH, optionally through a jump host. The thesis results were measured on three CrownLabs machines on the same
network; copy `config.local.env.example` to `config.local.env` and fill in your values (see `config.env`).

```
site A (10.1.0.10) ── network A ── router (10.1.0.1 | 10.2.0.1) ── network B ── site B (10.2.0.10)
```

The scripts call the third machine `router`. In the thesis, the three machines are on the same network: the third machine
is only the third member of the IC database and does not forward packets. With two networks (the drawing above), the
third machine must forward packets (`ip_forward=1`, no NAT) and each site needs a route to the other network through it;
creating such a network is not scripted (it depends on the platform). `00-preflight.sh` checks `ip_forward` only in
that case.

```bash
./00-preflight.sh          # machines, addresses, router, CIDRs
./10-install-sites.sh      # K3s + Kube-OVN on both sites (runs 02-kube-ovn-setup remotely)
./11-install-ic.sh         # OVN-IC: database on site A, ConfigMap and controller on both
./20-ic-state.sh           # zones, learned routes, ping between pods of the two sites, MTU
./30-netpol-cross-site.sh  # tests that need no tenants
./31-sg-cross-site.sh
./21-ic-tenants.sh         # tenants T and U on both sites (fixture of 40-44 and of 50-51)
./40-private-subnets.sh
./41-default-custom.sh
./42-custom-custom.sh
./43-ic-overlap.sh
./44-ic-rbac.sh
./12-ic-db-raft.sh         # ONCE: the IC database becomes a Raft cluster of three members (needs Docker on the third machine)
./50-ic-db-failover.sh
./51-ic-db-quorum.sh
./29-ic-tenants-remove.sh  # last: 50 and 51 need the tenants
./90-reset.sh              # removes K3s and Kube-OVN from both sites
```

The third machine needs Docker only for `12-ic-db-raft.sh` and the two tests after it (`sudo apt install -y docker.io`).
Run the tests **after** `43-ic-overlap.sh` in this order: with the Raft database of `12` there is one transit switch
instead of three, so the route counts of `20` and `43` are those of the single-pod database only before `12`.

| Script | Changes | What it does |
|---|---|---|
| `00-preflight.sh` | nothing | SSH, addresses, path between the sites, `ip_forward` (only with two networks), no overlap between the CIDRs of the two sites |
| `10-install-sites.sh` | the sites | copies the scripts and runs `02-kube-ovn-setup/10-install-kube-ovn.sh` with the values of each site |
| `11-install-ic.sh` | the sites | label `ovn.kubernetes.io/ic-gw`, IC database (`install-ic-server.sh`, 3 transit switches), `ovn-ic-config`, `ovn-ic-controller` |
| `20-ic-state.sh` | a temporary namespace per site | both zones in the IC database, routes learned (one per transit switch), ping A↔B, MTU |
| `90-reset.sh` | the sites | runs `02-kube-ovn-setup/90-reset.sh` on both |

Notes:
- macOS is fine (bash 3.2). SSH keeps one connection per machine open for 10 minutes, so the password is asked once.
- Pod, service and join CIDRs **must differ** between the sites.
- Edit nothing in `config.env`: copy the lines to change into `config.local.env`.

## Tests between the two sites

Run them in the order of the table. A probe prints `open` (ping and TCP 8080 work), `blocked` (neither works),
`ping-only`, `tcp-only`, or `error` when the commands could not run (SSH, `kubectl exec` or the pod failed); `error` is
never an expected result.

| Script | Changes | What it tests |
|---|---|---|
| `30-netpol-cross-site.sh` | a temporary namespace per site | NetworkPolicy between sites: deny-all, podSelector, namespaceSelector, ipBlock, egress |
| `31-sg-cross-site.sh` | a temporary namespace and group per site | Security Group between sites: membership, address rules, TCP only, egress |
| `21-ic-tenants.sh` | creates tenants T and U with private subnets and custom VPCs on both sites | fixture of the next four tests |
| `40-private-subnets.sh` | one temporary ACL | private subnets of two tenants on two sites, ACL on a port |
| `41-default-custom.sh` | routes and allowSubnets (restored at the end) | default VPC against custom VPC on different sites, steps to open a private subnet |
| `42-custom-custom.sh` | one route (restored) | custom VPC against custom VPC, double peering |
| `43-ic-overlap.sh` | temporary subnets and pods | same CIDR announced twice, more specific prefix announced by the other site |
| `44-ic-rbac.sh` | a temporary RoleBinding | what a tenant administrator can do on the Kube-OVN resources |
| `12-ic-db-raft.sh` | the IC database becomes a Raft cluster of three members (site A, site B, router) | setup for the next two tests (private host directories, one transit switch, see the header) |
| `50-ic-db-failover.sh` | kills and restarts the leader of the IC database | election, traffic, announce with 2 members out of 3 |
| `51-ic-db-quorum.sh` | kills and restarts two members | loss of the quorum: no new announcements, existing traffic unaffected, automatic recovery |
| `29-ic-tenants-remove.sh` | deletes the tenants | cleanup of `21-ic-tenants.sh` |
