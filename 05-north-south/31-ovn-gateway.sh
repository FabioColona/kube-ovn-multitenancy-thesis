#!/bin/bash
# 31-ovn-gateway.sh — configures the OVN Gateway (no gateway pod) on N nodes, with ECMP and optionally BFD, and checks it.
#
# What it does : labels the first N machines of GATEWAY_NODES as external gateways, creates the provider network on EXT_NIC,
#                the external subnet, one OvnEip (type lsp) per gateway node (named like the node), a VPC with
#                enableExternal and enableBfd, a subnet with enableEcmp, an OvnEip + OvnSnatRule for the tenant, and a
#                client pod. Checks: ECMP routes (one per gateway), BFD sessions up (if enabled), the ovnext namespace and
#                default route on every gateway node, ping / full-size ping / HTTP to the customer host, and that the
#                customer sees the SNAT address of the tenant. N=1 is the single-gateway baseline.
# Environment  : the cluster of 20-install-cluster.sh (with 15-install-multus.sh not required) and the customer network of
#                10-external-network.sh (EXT_NIC present on every gateway machine)
# Changes      : CHANGES THE CLUSTER (node labels, ProviderNetwork/Vlan/Subnets, VPC, OVN EIPs, SNAT rule, one namespace and pod;
#                the provider network moves EXT_NIC into an OVS bridge on the gateway nodes)
# Requires     : phases 10 and 20 done; no previous OVN Gateway test (run ./39-remove-ovn-gateway.sh first)
# Usage        : ./31-ovn-gateway.sh [N] [bfd|nobfd] [noecmp] [--yes]       defaults: N = all GATEWAY_NODES, bfd (BFD needs N >= 2)
# Variables    : GATEWAY_NODES, EXT_*, CUST_*, OVNGW_*, NS_OVNGW, PROBE_IMAGE (from config.env)
# Duration     : about 4 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south, OVN Gateway)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars EXT_NIC EXT_CIDR EXT_GATEWAY EXT_POOL_START CUST_HOST_IP OVNGW_VPC OVNGW_SUBNET OVNGW_SUBNET_CIDR NS_OVNGW OVNGW_PROVIDER OVNGW_EXT_SUBNET PROBE_IMAGE

ALLGW=0; for g in $GATEWAY_NODES; do ALLGW=$((ALLGW+1)); done
N=$ALLGW; BFD=true; ECMP=true; ECMP_SET=0
for a in "${ARGS[@]:-}"; do
  case "$a" in
    bfd) BFD=true ;; nobfd) BFD=false ;; noecmp) ECMP=false; ECMP_SET=1 ;; "") ;;
    *[!0-9]*) die "unknown argument '$a' (use: N, bfd, nobfd, noecmp)" ;;
    *) N=$a ;;
  esac
done
[ "$BFD" = false ] && ECMP=false      # ECMP is meaningful only with BFD in Kube-OVN
[ "$N" -ge 1 ] && [ "$N" -le "$ALLGW" ] || die "N must be between 1 and $ALLGW (machines in GATEWAY_NODES)"
if [ "$N" = 1 ] && [ "$BFD" = true ]; then
  die "ECMP with BFD needs at least two gateway nodes (Kube-OVN $KUBEOVN_VERSION: \"ecmp route with bfd for HA, which need two lsp type eips at least\"). Use: ./31-ovn-gateway.sh 1 nobfd, or N >= 2"
fi
GW=""; k=0; for g in $GATEWAY_NODES; do k=$((k+1)); [ "$k" -le "$N" ] && GW="$GW $g"; done
GW="${GW# }"
HOSTS=(); for g in $GW; do h="$(nssh "$g" hostname | tr -d '\r')"; [ -n "$h" ] || die "cannot read the hostname of machine $g"; HOSTS+=("$h"); done
EXCL=""; for c in $CLUSTER_NODES; do
  in_list "$c" "$GW" && continue
  EXCL="$EXCL, \"$(nssh "$c" hostname | tr -d '\r')\""; done
EXCL="[${EXCL#, }]"
echo "  OVN Gateway on $N node(s): ${HOSTS[*]};  subnet enableEcmp: $ECMP;  BFD: $BFD"
confirm "This configures the OVN Gateway on the nodes above. Continue?"

nb() { rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl $*" 2>/dev/null; }

sec "1. Preconditions"
rk "$SERVER" 'kubectl get nodes' >/dev/null 2>&1 || die "the cluster does not answer: run ./20-install-cluster.sh first"
rk "$SERVER" "kubectl get vpc $OVNGW_VPC" >/dev/null 2>&1 && die "the VPC $OVNGW_VPC already exists: run ./39-remove-ovn-gateway.sh first"
rk "$SERVER" "kubectl get provider-network $OVNGW_PROVIDER" >/dev/null 2>&1 && die "the provider network exists: run ./39-remove-ovn-gateway.sh first"
for g in $GW; do
  nssh "$g" "ip link show $EXT_NIC >/dev/null 2>&1" || die "machine $g has no $EXT_NIC: run ./10-external-network.sh first"
  # a macvlan on EXT_NIC (the external interface of a NAT Gateway pod) keeps the device busy: OVS cannot add it to the provider bridge
  [ "$(nssh "$g" "ip -d link show type macvlan 2>/dev/null | grep -c 'link $EXT_NIC'" | tr -d ' ')" = 0 ] || die "machine $g: a macvlan sits on $EXT_NIC (NAT Gateway still there?): run ./39-remove-nat-gateway.sh first"
done
info "kernel: $(nssh "${GW%% *}" uname -r);  OVN: $(rk "$SERVER" "kubectl -n kube-system get deploy ovn-central -o jsonpath='{.spec.template.spec.containers[0].image}'")"

sec "2. Gateway nodes and external network"
for h in "${HOSTS[@]}"; do rk "$SERVER" "kubectl label node $h ovn.kubernetes.io/external-gw=true --overwrite" | sed 's/^/  /'; done
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: ProviderNetwork
metadata: {name: $OVNGW_PROVIDER}
spec:
  defaultInterface: $EXT_NIC
  excludeNodes: $EXCL
---
apiVersion: kubeovn.io/v1
kind: Vlan
metadata: {name: vlan-ext}
spec: {id: 0, provider: $OVNGW_PROVIDER}
Y
_pn_ready() { [ "$(rk "$SERVER" "kubectl get provider-network $OVNGW_PROVIDER -o jsonpath='{.status.ready}'")" = true ]; }
WAIT_MSG="waiting for the provider network" waitf 30 3 _pn_ready && PR=true || PR=false
expect "provider network ready" true "$PR"
[ "$PR" = true ] || { rk "$SERVER" "kubectl get provider-network $OVNGW_PROVIDER -o yaml | tail -30"; table; exit 1; }
for i in "${!HOSTS[@]}"; do
  g="$(set -- $GW; eval echo \${$((i+1))})"
  OP="$(rk "$SERVER" "kubectl -n kube-system get pods -l app=ovs --field-selector spec.nodeName=${HOSTS[$i]} -o name | head -1" | tr -d '\r')"
  expect "node ${HOSTS[$i]}: $EXT_NIC is a port of the provider bridge" yes "$(rk "$SERVER" "kubectl -n kube-system exec $OP -c openvswitch -- ovs-vsctl --if-exists get interface $EXT_NIC ofport" 2>/dev/null | tr -d '\r' | awk '{print ($1>0)?"yes":"no"}')"
done
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: $OVNGW_EXT_SUBNET}
spec:
  protocol: IPv4
  cidrBlock: $EXT_CIDR
  gateway: $EXT_GATEWAY
  excludeIps: ["${EXT_CIDR%.*/*}.1..${EXT_CIDR%.*/*}.$((EXT_POOL_START-1))"]
  vlan: vlan-ext
Y

if [ "$BFD" = true ]; then
  sec "2b. Namespace ovnext on the gateway machines"
  # kube-ovn-cni creates the namespace "ovnext" (unshare + bind mount) for the BFD endpoint of the node. In this environment the
  # DaemonSet (privileged: false, only SYS_ADMIN) is refused with "permission denied" on the mount. The namespace
  # is therefore created from the host; kube-ovn-cni only has to configure ovnext0 inside it. 39-remove-ovn-gateway.sh removes it.
  for g in $GW; do
    nssh "$g" "sudo -n ip netns list | grep -q '^ovnext' || sudo -n ip netns add ovnext"
    info "machine $g: namespace ovnext $(nssh "$g" "sudo -n ip netns list | grep -c '^ovnext'" | tr -d ' ') (created from the host);  AppArmor mount denials in the kernel log: $(nssh "$g" "sudo -n dmesg 2>/dev/null | grep -c 'apparmor=\"DENIED\".*operation=\"mount\"'" | tr -d ' ')"
  done
fi

sec "3. One OVN EIP (type lsp) per gateway node"
for h in "${HOSTS[@]}"; do
  kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: OvnEip
metadata: {name: $h}
spec: {externalSubnet: $OVNGW_EXT_SUBNET, type: lsp}
Y
done
sleep 4
if [ "$BFD" = true ]; then
  _eips_ready() { [ "$(rk "$SERVER" "kubectl get ovn-eip -o jsonpath='{range .items[?(@.spec.type==\"lsp\")]}{.status.ready}{\"\\n\"}{end}'" | grep -c true)" = "$N" ]; }
  WAIT_MSG="waiting for the node EIPs (ovnext0 configured by kube-ovn-cni)" waitf 30 3 _eips_ready && NR_=$N || NR_=$(rk "$SERVER" "kubectl get ovn-eip -o jsonpath='{range .items[?(@.spec.type==\"lsp\")]}{.status.ready}{\"\\n\"}{end}'" | grep -c true)
  info "node EIPs (type lsp) with status.ready=true: $NR_ of $N (informational: the routes below are the check)"
fi
echo "  $(rk "$SERVER" "kubectl get ovn-eip --no-headers" | awk '{printf "%s=%s  ", $1, $2}')"

sec "4. VPC (external, BFD $BFD), subnet (ECMP), namespace"
rk "$SERVER" "kubectl create namespace $NS_OVNGW --dry-run=client -o yaml | kubectl apply -f -" >/dev/null
# With BFD the controller installs the ECMP routes by itself. Without BFD (Kube-OVN 1.13.0) it does not install any route
# towards the external network: the default route is declared in the VPC, as in the single-gateway setup.
STATIC=""
[ "$BFD" = false ] && STATIC="  staticRoutes:
  - {cidr: 0.0.0.0/0, nextHopIP: $EXT_GATEWAY, policy: policyDst}"
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: Vpc
metadata: {name: $OVNGW_VPC}
spec:
  namespaces: [$NS_OVNGW]
  enableExternal: true
  enableBfd: $BFD
$STATIC
---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: $OVNGW_SUBNET}
spec:
  vpc: $OVNGW_VPC
  protocol: IPv4
  cidrBlock: $OVNGW_SUBNET_CIDR
  gateway: ${OVNGW_SUBNET_CIDR%.*}.1
  namespaces: [$NS_OVNGW]
  enableEcmp: $ECMP
  gatewayType: distributed
  natOutgoing: false
  disableInterConnection: true
Y
_vpc_ext() { [ "$(rk "$SERVER" "kubectl get vpc $OVNGW_VPC -o jsonpath='{.status.enableExternal}'")" = true ]; }
WAIT_MSG="waiting for the VPC external port" waitf 30 3 _vpc_ext && VE=true || VE=false
expect "VPC enableExternal" true "$VE"
expect "VPC enableBfd" "$BFD" "$(rk "$SERVER" "kubectl get vpc $OVNGW_VPC -o jsonpath='{.status.enableBfd}'")"

sec "5. SNAT for the tenant subnet"
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: OvnEip
metadata: {name: eip-ovngw}
spec: {externalSubnet: $OVNGW_EXT_SUBNET, type: nat}
Y
sleep 3
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: OvnSnatRule
metadata: {name: snat-ovngw}
spec: {ovnEip: eip-ovngw, vpcSubnet: $OVNGW_SUBNET}
Y
sleep 5
SNATIP="$(rk "$SERVER" "kubectl get ovn-eip eip-ovngw -o jsonpath='{.status.v4Ip}'")"
expect "OVN SNAT rule ready" true "$(rk "$SERVER" "kubectl get ovn-snat-rule snat-ovngw -o jsonpath='{.status.ready}'" || echo false)"
info "SNAT address of the tenant: ${SNATIP:--}"

sec "6. State of the gateway (no gateway pod)"
echo "--- routes of the VPC ---";  nb lr-route-list "$OVNGW_VPC" | sed 's/^/  /'
if [ "$ECMP" = true ] && [ "$BFD" = true ]; then
  expect "ECMP routes for the tenant subnet" "$N" "$(nb lr-route-list "$OVNGW_VPC" | grep -c 'ecmp')"
else
  expect "default route towards the external gateway (single next hop)" 1 "$(nb lr-route-list "$OVNGW_VPC" | grep -c '0.0.0.0/0')"
fi
if [ "$BFD" = true ]; then
  _bfd_up() { [ "$(nb find bfd status=up | grep -c '^_uuid')" = "$N" ]; }
  WAIT_MSG="waiting for the BFD sessions" waitf 30 3 _bfd_up
  echo "--- BFD sessions ---"; nb --columns=dst_ip,status,min_tx,min_rx,detect_mult find bfd | sed 's/^/  /'
  expect "BFD sessions up" "$N" "$(nb find bfd status=up | grep -c '^_uuid')"
else
  expect "BFD sessions" 0 "$(nb find bfd | grep -c '^_uuid')"
fi
for i in "${!HOSTS[@]}"; do
  g="$(set -- $GW; eval echo \${$((i+1))})"
  nssh "$g" 'sudo -n ip netns list | grep -q ovnext' && O=present || O=absent
  # ovnext (the BFD endpoint of the node) exists only when BFD is on
  if [ "$BFD" = true ]; then expect "node ${HOSTS[$i]}: namespace ovnext" present "$O"; else info "node ${HOSTS[$i]}: namespace ovnext $O (expected absent without BFD)"; fi
  info "node ${HOSTS[$i]}: $(nssh "$g" 'sudo -n ip netns exec ovnext ip -br addr 2>/dev/null | grep ovnext0; sudo -n ip netns exec ovnext ip route 2>/dev/null | head -1' | tr '\n' ' ')"
done

sec "7. Tenant client pod and traffic to the customer host $CUST_HOST_IP"
[ "$(start_cust_servers | tail -1)" = 2 ] && info "customer servers up (HTTP 8080, iperf3 5201)" || warn "customer servers not both listening"
kapply <<Y >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: oprobe, namespace: $NS_OVNGW}
spec:
  containers:
  - name: c
    image: "$PROBE_IMAGE"
    command: ["sleep", "7200"]
Y
run_spin "waiting for the client pod" "image download, up to 4 minutes" rk "$SERVER" "kubectl -n $NS_OVNGW wait --for=condition=Ready pod/oprobe --timeout=240s" || { tail -5 "$RUN_LOG"; }
PIP="$(rk "$SERVER" "kubectl -n $NS_OVNGW get pod oprobe -o jsonpath='{.status.podIP}'")"
PM="$(rk "$SERVER" "kubectl -n $NS_OVNGW exec oprobe -- cat /sys/class/net/eth0/mtu" | tr -d '\r')"
echo "  client pod $PIP, MTU $PM"
IN=no; case "$PIP" in "${OVNGW_SUBNET_CIDR%.*}".*) IN=yes ;; esac
expect "client pod address in $OVNGW_SUBNET_CIDR" yes "$IN"
_ping1() { rk "$SERVER" "kubectl -n $NS_OVNGW exec oprobe -- ping -c 2 -W 2 $CUST_HOST_IP >/dev/null 2>&1"; }
_ping2() { rk "$SERVER" "kubectl -n $NS_OVNGW exec oprobe -- ping -c 2 -W 2 -M do -s $((PM-28)) $CUST_HOST_IP >/dev/null 2>&1"; }
T0=$SECONDS; WAIT_MSG="waiting for the first ping to the customer" waitf 36 5 _ping1 && R1=ok || R1=fail
if [ "$R1" = ok ]; then info "first successful ping after $((SECONDS-T0))s from the start of the check (data plane warm-up)"; else warn "no successful ping in $((SECONDS-T0))s"; fi
expect "ping tenant pod -> customer host" ok "$R1"
_ping2 && R2=ok || R2=fail
expect "full-size packets ($PM bytes, DF) tenant pod -> customer host" ok "$R2"
expect "HTTP tenant pod -> customer host" 200 "$(rk "$SERVER" "kubectl -n $NS_OVNGW exec oprobe -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://$CUST_HOST_IP:8080/" | tr -d '\r')"
SEEN="$(nssh "$FABRIC_NODE" "tail -1 /tmp/ns-cust-http.log" | awk '{print $1}')"
expect "source address seen by the customer = SNAT address" "${SNATIP:-EIP}" "${SEEN:--}"

sec "Diagnostics (only useful if something failed)"
echo "--- kube-ovn-controller, lines about the gateway ---"
rk "$SERVER" "kubectl -n kube-system logs deploy/kube-ovn-controller --tail=600 2>&1 | grep -i -E 'ovn-eip|snat|bfd|external|ecmp' | tail -12" | cut -c1-220
echo
table
