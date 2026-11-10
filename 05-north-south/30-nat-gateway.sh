#!/bin/bash
# 30-nat-gateway.sh — creates a VPC NAT Gateway with an EIP and a SNAT rule and checks it reaches the customer host.
#
# What it does : enables the NAT Gateway in Kube-OVN, creates the external network of the gateway (macvlan + subnet), a
#                VPC with one subnet and one namespace, the gateway pod (pinned to one gateway machine), an
#                IptablesEIP and an IptablesSnatRule, then a client pod in the tenant. It waits for the EIP to become
#                Ready (the step that failed on a network with proxy ARP, because the gateway runs a duplicate address
#                detection on the external network), and checks ping, HTTP and the source address the customer sees (it
#                must be the EIP). If the EIP never becomes Ready it prints the diagnostics and marks the rest BLOCKED.
# Environment  : the cluster of 20-install-cluster.sh and the customer network of 10-external-network.sh
# Changes      : CHANGES THE CLUSTER (ConfigMaps in kube-system, one VPC, one namespace, one gateway pod, EIP, SNAT)
# Requires     : phases 10 and 20 done; Internet on the machines (container images)
# Usage        : ./30-nat-gateway.sh [--yes]        (NAT_EXTERNAL=nic ./30-nat-gateway.sh to use the real network)
# Variables    : NAT_* , EXT_POOL_SIZE (optional), NS_NAT, PROBE_IMAGE, EXT_*, CUST_* (from config.env)
# Duration     : about 5 minutes (about 8 if the EIP never gets Ready)
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south, NAT Gateway)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars NAT_EXTERNAL NS_NAT NAT_VPC NAT_SUBNET NAT_SUBNET_CIDR NAT_LAN_IP NAT_GW NAT_EXT_SUBNET PROBE_IMAGE EXT_CIDR EXT_GATEWAY CUST_HOST_IP

GWN="${NAT_GW_NODE:-${GATEWAY_NODES%% *}}"
GWHOST="$(nssh "$GWN" hostname | tr -d '\r')"; [ -n "$GWHOST" ] || die "cannot read the hostname of machine $GWN"
case "$NAT_EXTERNAL" in
  segment) MASTER="$EXT_NIC"; ECIDR="$EXT_CIDR"; EGW="$EXT_GATEWAY"; EXCL="${EXT_GATEWAY%.*}.1..${EXT_GATEWAY%.*}.$((EXT_POOL_START-1))" ;;
  nic)     require_vars NAT_NIC_CIDR NAT_NIC_GATEWAY NAT_NIC_EXCLUDE
           MASTER="$(node_iface "$GWN")"; ECIDR="$NAT_NIC_CIDR"; EGW="$NAT_NIC_GATEWAY"; EXCL="$NAT_NIC_EXCLUDE" ;;
  *) die "NAT_EXTERNAL must be 'segment' or 'nic'" ;;
esac
# EXT_POOL_SIZE (optional, segment only): keep only this many free addresses in the external pool (to test pool exhaustion)
EXCL_YAML="\"$EXCL\""
if [ -n "${EXT_POOL_SIZE:-}" ] && [ "$NAT_EXTERNAL" = segment ]; then
  EXCL_YAML="$EXCL_YAML, \"${EXT_GATEWAY%.*}.$((EXT_POOL_START+EXT_POOL_SIZE))..${EXT_GATEWAY%.*}.254\""
  echo "  external pool limited to $EXT_POOL_SIZE free address(es): ${EXT_GATEWAY%.*}.$EXT_POOL_START .. ${EXT_GATEWAY%.*}.$((EXT_POOL_START+EXT_POOL_SIZE-1))"
fi
EXTPROV="$NAT_EXT_SUBNET.kube-system"
echo "  gateway pod on machine $GWN ($GWHOST); external network: $NAT_EXTERNAL ($ECIDR via macvlan on $MASTER)"
confirm "This creates the VPC $NAT_VPC and a NAT Gateway in the cluster. Continue?"

sec "1. Preconditions"
rk "$SERVER" 'kubectl get nodes' >/dev/null 2>&1 || die "the cluster does not answer: run ./20-install-cluster.sh first"
rk "$SERVER" "kubectl get vpc $NAT_VPC" >/dev/null 2>&1 && die "the VPC $NAT_VPC already exists: run ./39-remove-nat-gateway.sh first"
if [ "$NAT_EXTERNAL" = segment ]; then
  [ "$(nssh "$FABRIC_NODE" 'sudo -n ip netns list | grep -c "^fabric"')" = 1 ] || die "the fabric namespace is missing: run ./10-external-network.sh first"
fi
info "kernel on the gateway machine: $(nssh "$GWN" uname -r)   image of the gateway: docker.io/kubeovn/vpc-nat-gateway:$KUBEOVN_VERSION"

sec "2. NAT Gateway enabled, external network, VPC"
kapply <<Y >/dev/null
apiVersion: v1
kind: ConfigMap
metadata: {name: ovn-vpc-nat-config, namespace: kube-system}
data: {image: "docker.io/kubeovn/vpc-nat-gateway:$KUBEOVN_VERSION"}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: ovn-vpc-nat-gw-config, namespace: kube-system}
data: {enable-vpc-nat-gw: "true"}
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: {name: $NAT_EXT_SUBNET, namespace: kube-system}
spec:
  config: '{"cniVersion":"0.3.0","type":"macvlan","master":"$MASTER","mode":"bridge","ipam":{"type":"kube-ovn","server_socket":"/run/openvswitch/kube-ovn-daemon.sock","provider":"$EXTPROV"}}'
---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: $NAT_EXT_SUBNET}
spec:
  protocol: IPv4
  provider: $EXTPROV
  cidrBlock: $ECIDR
  gateway: $EGW
  excludeIps: [$EXCL_YAML]
---
apiVersion: v1
kind: Namespace
metadata: {name: $NS_NAT}
---
apiVersion: kubeovn.io/v1
kind: Vpc
metadata: {name: $NAT_VPC}
spec:
  namespaces: [$NS_NAT]
  staticRoutes:
  - {cidr: 0.0.0.0/0, nextHopIP: $NAT_LAN_IP, policy: policyDst}
---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: $NAT_SUBNET}
spec:
  vpc: $NAT_VPC
  protocol: IPv4
  cidrBlock: $NAT_SUBNET_CIDR
  gateway: ${NAT_SUBNET_CIDR%.*}.1
  excludeIps: ["$NAT_LAN_IP"]
  namespaces: [$NS_NAT]
Y
expect "VPC, subnets and external network created" yes "$(rk "$SERVER" "kubectl get vpc $NAT_VPC -o name >/dev/null 2>&1 && kubectl get subnet $NAT_SUBNET $NAT_EXT_SUBNET -o name >/dev/null 2>&1 && echo yes || echo no")"
[ "${RES_OBT[0]}" = yes ] || { table; die "the objects were not created"; }

sec "3. Gateway pod"
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: VpcNatGateway
metadata: {name: $NAT_GW}
spec:
  vpc: $NAT_VPC
  subnet: $NAT_SUBNET
  lanIp: $NAT_LAN_IP
  externalSubnets: [$NAT_EXT_SUBNET]
  selector: ["kubernetes.io/hostname: $GWHOST"]
Y
GWPOD="vpc-nat-gw-$NAT_GW-0"
_gw_ready() { rk "$SERVER" "kubectl -n kube-system get pod $GWPOD --no-headers" 2>/dev/null | grep -qE '1/1 +Running'; }
WAIT_MSG="waiting for the gateway pod" waitf 72 5 _gw_ready && G=Running || G="$(rk "$SERVER" "kubectl -n kube-system get pod $GWPOD --no-headers 2>/dev/null | awk '{print \$3}'")"
expect "gateway pod Running" Running "${G:-absent}"

sec "4. EIP and SNAT"
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: IptablesEIP
metadata: {name: eip-nat}
spec: {natGwDp: $NAT_GW, externalSubnet: $NAT_EXT_SUBNET}
Y
_eip_ready() { [ "$(rk "$SERVER" "kubectl get iptables-eip eip-nat -o jsonpath='{.status.ready}'" 2>/dev/null)" = true ]; }
START=$SECONDS
WAIT_MSG="waiting for the EIP to be Ready" waitf 30 5 _eip_ready && ER=true || ER=false
EIP="$(rk "$SERVER" "kubectl get iptables-eip eip-nat -o jsonpath='{.status.ip}'" 2>/dev/null)"
expect "EIP Ready (external network: $NAT_EXTERNAL)" true "$ER"
echo "  EIP ${EIP:--} ; $((SECONDS-START)) s"
if [ "$ER" != true ]; then
  sec "Diagnostics (the EIP is not Ready)"
  rk "$SERVER" "kubectl describe iptables-eip eip-nat | tail -25"
  echo "--- gateway pod log (last 30 lines) ---"; rk "$SERVER" "kubectl -n kube-system logs $GWPOD --tail=30 2>&1"
  echo "--- kube-ovn-controller, lines about the EIP ---"; rk "$SERVER" "kubectl -n kube-system logs deploy/kube-ovn-controller --tail=500 2>&1 | grep -i -E 'eip|arping|duplicate' | tail -15"
  record "SNAT rule created" yes "-" BLOCKED; record "ping tenant pod -> customer host" ok "-" BLOCKED
  record "HTTP tenant pod -> customer host" 200 "-" BLOCKED; record "source address seen by the customer = EIP" "${EIP:-EIP}" "-" BLOCKED
  table; exit 1
fi
kapply <<Y >/dev/null
apiVersion: kubeovn.io/v1
kind: IptablesSnatRule
metadata: {name: snat-nat}
spec: {eip: eip-nat, internalCIDR: $NAT_SUBNET_CIDR}
Y
sleep 5
expect "SNAT rule ready" true "$(rk "$SERVER" "kubectl get iptables-snat-rule snat-nat -o jsonpath='{.status.ready}'" 2>/dev/null || echo false)"

sec "5. Customer servers and the client pod"
[ "$(start_cust_servers | tail -1)" = 2 ] && info "customer servers up (HTTP 8080, iperf3 5201)" || warn "customer servers not both listening"
# The pod is created AFTER the namespace is bound to the subnet (otherwise it gets an address of the default subnet).
kapply <<Y >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: nprobe, namespace: $NS_NAT}
spec:
  containers:
  - name: c
    image: "$PROBE_IMAGE"
    command: ["sleep", "7200"]
Y
run_spin "waiting for the client pod" "image download, up to 4 minutes" rk "$SERVER" "kubectl -n $NS_NAT wait --for=condition=Ready pod/nprobe --timeout=240s" || { tail -5 "$RUN_LOG"; }
PIP="$(rk "$SERVER" "kubectl -n $NS_NAT get pod nprobe -o jsonpath='{.status.podIP}'")"
echo "  client pod $PIP, MTU $(rk "$SERVER" "kubectl -n $NS_NAT exec nprobe -- cat /sys/class/net/eth0/mtu" | tr -d '\r')"
IN=no; case "$PIP" in "${NAT_SUBNET_CIDR%.*}".*) IN=yes ;; esac
expect "client pod address in $NAT_SUBNET_CIDR" yes "$IN"

sec "6. Traffic to the customer host $CUST_HOST_IP"
expect "ping tenant pod -> customer host" ok "$(rk "$SERVER" "kubectl -n $NS_NAT exec nprobe -- ping -c 3 -W 2 $CUST_HOST_IP >/dev/null 2>&1 && echo ok || echo fail")"
PM="$(rk "$SERVER" "kubectl -n $NS_NAT exec nprobe -- cat /sys/class/net/eth0/mtu" | tr -d '\r')"
expect "full-size packets ($PM bytes, DF) tenant pod -> customer host" ok "$(rk "$SERVER" "kubectl -n $NS_NAT exec nprobe -- ping -c 3 -W 2 -M do -s $((PM-28)) $CUST_HOST_IP >/dev/null 2>&1 && echo ok || echo fail")"
expect "HTTP tenant pod -> customer host" 200 "$(rk "$SERVER" "kubectl -n $NS_NAT exec nprobe -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://$CUST_HOST_IP:8080/" | tr -d '\r')"
SEEN="$(nssh "$FABRIC_NODE" "tail -1 /tmp/ns-cust-http.log" | awk '{print $1}')"
expect "source address seen by the customer = EIP" "$EIP" "${SEEN:--}"
echo "--- inside the gateway: addresses and NAT rules ---"
rk "$SERVER" "kubectl -n kube-system exec $GWPOD -c vpc-nat-gw -- sh -c 'ip -br addr; ip route; iptables-legacy -t nat -S 2>/dev/null | grep -i -E \"snat|eip\"'" 2>&1 | head -20
table
