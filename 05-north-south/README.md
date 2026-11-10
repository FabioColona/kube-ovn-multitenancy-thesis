# 05-north-south — gateways towards the customer network

Measures how Kube-OVN reaches the outside (north-south traffic) and how it scales:

* **VPC NAT Gateway** — one pod per VPC (iptables / conntrack).
* **OVN Gateway** — no pod: the VPC router of OVN, with one or **several gateway nodes** (ECMP + BFD).

The question behind the folder: does the OVN Gateway scale with the number of gateway nodes while the NAT Gateway, a single pod, does not?

> Status: all the scripts listed below were run on CrownLabs, with four virtual machines (three cluster machines, one for the fabric and the customer host). A BGP announcement of the OVN Gateway addresses is not scripted.

## How the scripts run

On **your computer**, over SSH (optionally through a jump host, `SSH_JUMP`). Machines are numbered by their position in `NODES`.

| File | What it is |
|---|---|
| `config.env` | defaults — do not edit |
| `config.local.env` | your own values (ignored by git) |
| `lib-ns.sh` | SSH helpers (`nssh`, `nroot`, `rk`, `push_repo`) |

## Requirements

* 2 to 4 Linux machines (Ubuntu 24.04+), same vCPU and RAM on the ones that are gateways, SSH access with passwordless `sudo`, Internet access (apt, GitHub, container registries).
* One machine for the fabric and the customer host is best kept **outside** the cluster, so it does not compete with the gateways for CPU.
* Kernel with Open vSwitch and Geneve (Ubuntu generic kernels have them).

## How to set up your environment

Copy `config.env` values you need to change into `config.local.env`:

| Environment | What to set |
|---|---|
| **CrownLabs (or any cloud)** | `NODES` = the SSH names of the VMs, `NODE_USER`, `SSH_JUMP` = the bastion. Machines have no shared layer 2 and a proxy ARP on the network: the external segment is built with VXLAN (phase 10), nothing to configure. |
| **Other virtual machines** | `NODES` = the VM addresses, `NODE_USER`, empty `SSH_JUMP`. Check the NIC MTU: the pod MTU is derived from it. |
| **Local (kind/minikube)** | not supported: Kube-OVN needs real nodes with Open vSwitch. |

`GATEWAY_NODES` lists the machines that may act as gateways; a test with N gateways uses the first N.

## Order of execution

```
./00-preflight.sh                 read-only check of the machines
./10-external-network.sh          external segment (VXLAN), fabric router, customer host
./20-install-cluster.sh           K3s + Kube-OVN on all cluster machines
./15-install-multus.sh            Multus (needed only by the NAT Gateway)

# Arm 1: OVN Gateway (no pod; configuration on the nodes)
./31-ovn-gateway.sh 1 nobfd       one gateway node, static route
./40-benchmark.sh ovngw
./39-remove-ovn-gateway.sh
./31-ovn-gateway.sh 2 bfd         two gateway nodes, ECMP + BFD (also 3 bfd)
./40-benchmark.sh ovngw
./50-gateway-failure.sh ovngw full active     (also: other; modes node, nic)
./62-persist-gateway-machine.sh 2 3            before the mode crash: ext0 and ovnext survive a reboot
./50-gateway-failure.sh ovngw crash active    (also: other)
./39-remove-ovn-gateway.sh

# Arm 2: NAT Gateway (a pod)
./30-nat-gateway.sh
./40-benchmark.sh natgw
./50-gateway-failure.sh natgw pod
./39-remove-nat-gateway.sh

./90-reset.sh                     removes everything
```

Run the arms in the same session, with the same resources per machine. Repeat the whole sequence in a different order if you can, to see order effects. The NAT Gateway and the OVN Gateway cannot be installed at the same time on the same external NIC (macvlan and OVS exclude each other): remove one before configuring the other.

## Index of the scripts

| Script | What it does | Status |
|---|---|---|
| `00-preflight.sh` | OS, kernel, CPUs, memory, disk, KVM, sudo, MTU, path MTU between machines, proxy ARP | written, run |
| `10-external-network.sh` | bridge `br-priv`, namespaces `fabric` and `cust`, VXLAN segment, checks | written, run |
| `15-install-multus.sh` | Multus thick DaemonSet and CRD | written, run |
| `20-install-cluster.sh` | K3s server + agents, Kube-OVN, cross-node pod test, pod MTU | written, run |
| `30-nat-gateway.sh` | VPC NAT Gateway with EIP and SNAT | written, run |
| `31-ovn-gateway.sh [N] [bfd\|nobfd] [noecmp]` | OVN Gateway on N nodes; ECMP, BFD | written, run (N=1, 2, 3) |
| `39-remove-*.sh` | remove one gateway type and check the node is clean | written, run |
| `40-benchmark.sh <ovngw\|natgw>` | iperf3 from several tenant pods, 1/4/16/64 flows, 5 repetitions, CPU of the nodes, share per gateway | written, run |
| `41-baseline-hosts.sh` | iperf3 host to host between the two machines (reference for the link limit) | written, run |
| `42-baseline-overlay.sh` | iperf3 pod to pod across the machines over the overlay, no gateway (separates overlay from gateway) | written, run |
| `50-gateway-failure.sh <arm> [mode] [role]` | gateway failure during continuous ping: outage and restore time per pod, open gaps reported as lower bounds. Modes: `nic`, `node` (Geneve dropped), `full` (Geneve dropped and external interface down), `crash` (abrupt reboot), `poweroff`, `pod` (NAT Gateway). `UDP=1`: each pod also sends one numbered UDP datagram every interval, recorded by the customer host; `PROBE_CMD`/`PROBE_AT`: runs a probe (for example 64) during the failure | written, run |
| `52-recover-gateway-machine.sh <n>` | after `crash` or `poweroff`: recreates `ext0`, the namespace `ovnext` and the NIC prefix, updates the node address, restarts `kube-ovn-cni`, checks BFD | written, run |
| `53-gateway-state.sh` | read-only: gateway chassis priorities, BFD sessions, machine with the router port | written, run |
| `54-diag-gateway-machine.sh <n>` | read-only diagnosis of one gateway machine (`ext0`, `ovnext`, bridge ports, tunnels, BFD) | written, run |
| `55-cluster-state.sh` | read-only: addresses of the machines against those known to Kubernetes, nodes, pods not ready | written, run |
| `56-diag-fabric.sh` | read-only diagnosis of the fabric machine (tunnels, MAC table of `br-priv`, neighbours) | written, run |
| `57-diag-node-pods.sh <n>` | read-only: why the system pods of one machine do not start | written, run |
| `58-watch-gateway-state.sh [s] [step]` | watches the OVN Gateway without failures, until its state is stable | written, run |
| `59-cpu-online.sh <n> <count\|all\|show>` | sets how many CPUs are online on one machine | written, run |
| `60-natgw-info.sh` | read-only: iptables back-end of the NAT Gateway pod, iperf3 versions | written, run |
| `61-fabric-neigh-watch.sh <s> <file>` | records every 0.5 s what the customer side knows about the external addresses (neighbour table) | written, run |
| `62-persist-gateway-machine.sh <n>... [--remove]` | boot service that rebuilds `ext0`, the NIC prefix and `ovnext` after a reboot | written, run |
| `63-baseline-ext.sh [n]` | iperf3 from a gateway machine to the customer host through the external segment (limit of the environment) | written, run |
| `64-bfd-probe.sh <prefix>` | BFD rows, routes and ECMP flows in the OVN databases, and the BFD packets captured on the wire | written, run |
| `32-natgw-pool.sh <1\|2>` | NAT Gateway with an external pool of 1 or 2 free addresses (the EIP needs at least 2) | written, run |
| `34-http-check.sh [N]` | read-only: N ping + HTTP requests from a tenant pod to the customer host | written, run |
| `44-move-router-port.sh <n>` | moves the router port `cr-<vpc>-external` to machine n (deliberate manipulation: declare it with the results) | written, run |
| `90-reset.sh` | removes cluster, interfaces, bridge and namespaces | written |

Results are saved under `results/` (raw output, `runs.txt`, `summary.txt`, `environment.txt`); the folder is ignored by git and not published.

Parameters of the final campaign (they differ from the defaults of `config.env`): benchmark with `BENCH_CLIENT_PODS=6` on
the three cluster machines; failure tests with `FAIL_REPS=8`, `FAIL_PHASE=45` (60 for `crash`) and the gateway priorities
reset between repetitions. In `50-gateway-failure.sh` a repetition is **not valid** when a pod has no replies after the
failure was removed, or was not answering in the 3 seconds before the failure (the traffic was already interrupted): such
repetitions are listed in `runs.txt` with `valid no` and are left out of `summary.txt`; report how many they were. A gap
that is still open at the end of the pings is a lower bound, not a recovery time. After the gateway is configured with
ECMP and BFD the first ping may take minutes: check with `34-http-check.sh` before measuring.

## Notes on the environment

* The NIC MTU of a cloud may be lower than 1500 (CrownLabs: 1340, so the pods get 1240, as in the rest of the thesis). Report it with the results and use the **same** value in every arm of a comparison.
* Throughput numbers are valid only inside one environment and one run: never compare them with those of another environment.
* The OVN ECMP/BFD gateway of Kube-OVN needs the VPC flags `enableExternal` and `enableBfd`, the subnet flag `enableEcmp`, one `OvnEip` of type `lsp` per gateway node named like the node, and nodes labelled `ovn.kubernetes.io/external-gw=true` (see the Kube-OVN documentation, "OVN SNAT L3 HA based ECMP with BFD").
* `kube-ovn-cni` could not create the `ovnext` network namespace needed by BFD on the CrownLabs machines (bind mount denied, cause not identified). `31-ovn-gateway.sh` creates it from the host as a workaround; declare it with the results.
* Kube-OVN 1.13.0 refuses ECMP+BFD with one gateway node, and without BFD it installs no external route: the script declares a static route in the VPC. With two or more nodes, BFD without ECMP (`noecmp`) does not work in v1.13.0: no route is installed.
