# 03 — Kube-OVN tenancy (one site)

Creates two tenants with **private subnets** in the default VPC and tests that they are isolated; then custom VPCs,
peering with the default VPC, admission policies on the Kube-OVN annotations, port security, NetworkPolicies and the
restart of the Kube-OVN components.
Needs a cluster installed by `02-kube-ovn-setup`.

```bash
./10-apply-tenants.sh      # namespaces, subnets, pods + checks
./20-private-subnet.sh     # isolation test, results table at the end
./21-subnet-acl.sh         # ACL on a subnet: one port blocked, ping open
./22-admission-policy.sh   # logical_switch annotation attack, with and without the admission policy
./23-admission-annotations.sh   # port_security / security_groups annotations: removal on a running pod, with and without the admission policy
./30-apply-vpcs.sh         # two custom VPCs with subnet and pods
./31-vpc-isolation.sh      # custom VPCs are isolated before any peering
./32-vpc-peering.sh        # peering with the default VPC: routes, policy 29600, private subnet
./33-vpc-transit.sh        # two tenants peered with the default VPC: transit opened by routes, closed by drop policies
./40-port-security.sh      # port_security annotation against a fake source address (own namespace, no tenants needed)
./41-netpol-vpc.sh         # NetworkPolicy on a pod of the default VPC with a client in a custom VPC, and inside a custom VPC
./42-vpc-overlap.sh        # the same address range (and the same pod address) in two VPCs, and against the default VPC
./43-component-restart.sh  # restarts a Kube-OVN component (controller | ovn-central | ovs-ovn | cni): is anything lost?
./90-remove-tenants.sh     # removes the objects (the cluster stays)
./91-remove-vpcs.sh        # removes the custom VPCs and any peering left
```

| Script | Changes | What it does |
|---|---|---|
| `10-apply-tenants.sh` | cluster objects | applies `manifests/`, waits for the pods, checks subnets/bindings/addresses |
| `20-private-subnet.sh` | nothing | probes ping + TCP 8080 inside a tenant, between tenants, and to/from the default subnet |
| `21-subnet-acl.sh` | subnet sub-t (restored) | `spec.acls` drops TCP 8080 inside the tenant; ping must stay open; ACL removed at the end |
| `22-admission-policy.sh` | test pods, policy, 2 labels (all removed) | a pod of tenant u asks for the subnet of tenant t with the annotation; then the same with a `ValidatingAdmissionPolicy` |
| `23-admission-annotations.sh` | ns-an, security group sg-an, test pods, policy (all removed) | the tenant removes `port_security` / `security_groups` from a running pod: accepted and effective without policy; with `32-admission-policy-annotations.yaml` creation and UPDATE are rejected and OVN state is unchanged. `REPETITIONS` repeats both rounds |
| `30-apply-vpcs.sh` | cluster objects | applies `manifests/50-` and `51-`: 2 VPCs, 2 subnets, 3 pods |
| `31-vpc-isolation.sh` | nothing | custom VPCs against each other and against the default VPC, no peering |
| `32-vpc-peering.sh` | vpc-t, ovn-cluster, sub-t (restored) | peering and routes, then the allow policy at 29600, then the private subnet |
| `33-vpc-transit.sh` | vpc-t, vpc-u, ovn-cluster (restored) | both tenants peered with ovn-cluster: one route per side opens the transit, two drops at 29800 close it |
| `40-port-security.sh` | namespace ns-ps and 3 pods (removed) | a pod with NET_ADMIN uses an unassigned address as source: answered without `port_security`, dropped with it |
| `41-netpol-vpc.sh` | vpc-t, ovn-cluster, 5 NetworkPolicies, 3 labels (all restored) | deny-all, `ipBlock`, `namespaceSelector` towards the default VPC; deny-all and `podSelector` inside the custom VPC |
| `42-vpc-overlap.sh` | 3 namespaces, 2 VPCs, 3 subnets, 7 pods (removed) | the same CIDR in two custom VPCs and in a custom VPC and the default VPC; each client reaches the server of its own VPC |
| `43-component-restart.sh` | peering patches (restored), restarts one component, 1 temporary pod | no ping lost, same OVN routes/policies/ACLs, same isolation results, a new pod gets an address |
| `90-remove-tenants.sh` | cluster objects | deletes what 10 created |
| `91-remove-vpcs.sh` | cluster objects | deletes what 30 created and clears the routing fields of `ovn-cluster` |

The files in `manifests/` keep the real values used for the thesis; every value you may want to change is marked
with `# CHANGE:`. `REPETITIONS=1 ./20-private-subnet.sh` gives a quick run.

Reading the results: a traffic probe prints `open` (ping and TCP 8080 work), `blocked` (neither works), `ping-only`,
`tcp-only`, or `error` when the commands could not run in the pod; an admission attempt prints `yes` (accepted), `no`
(rejected by a `ValidatingAdmissionPolicy`) or `error` (any other failure). `error` is never an expected result.
