#!/bin/bash
# 10-external-network.sh — builds the simulated customer network: an external layer-2 segment shared by the gateway nodes
#                          (VXLAN), a "fabric" router and a "customer" host behind it.
#
# What it does : on the fabric machine creates the bridge br-priv, the namespace "fabric" (EXT_GATEWAY on the external
#                segment, CUST_FABRIC_IP towards the customer, IP forwarding on) and the namespace "cust" (CUST_HOST_IP,
#                default route to the fabric). Every gateway machine gets a VXLAN interface EXT_NIC (VNI EXT_VNI + its number) attached to br-priv
#                (on the fabric machine itself EXT_NIC is a veth). Then it checks, from every gateway machine, that the
#                fabric is reachable with full-size packets and that the duplicate address detection (arping -D) works on
#                the external segment (it does not on the real network when a proxy ARP is there).
# Environment  : the machines of config.env (Ubuntu with iproute2); no Kubernetes needed
# Changes      : CHANGES THE MACHINES (network namespaces, bridge, VXLAN and veth interfaces; installs iputils-arping;
#                removes the same objects if they already exist, so it can be run again)
# Requires     : bash >= 3.2, ssh; passwordless sudo and Internet access (apt) on the machines; phase 00 without FAIL
# Usage        : ./10-external-network.sh [--yes]
# Variables    : NODES, NODE_USER, SSH_JUMP, FABRIC_NODE, GATEWAY_NODES, EXT_*, CUST_* (from config.env)
# Duration     : about 1 minute
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south test bed)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars EXT_NIC EXT_VNI EXT_CIDR EXT_GATEWAY CUST_CIDR CUST_FABRIC_IP CUST_HOST_IP

F="$FABRIC_NODE"
FIP=$(node_ip "$F"); FIF=$(node_iface "$F"); NICMTU=$(node_mtu "$F")
[ -n "$FIP" ] && [ -n "$FIF" ] && [ -n "$NICMTU" ] || die "cannot read the address, interface or MTU of machine $F"
MTU="${EXT_MTU:-$((NICMTU-50))}"
PFX="${EXT_CIDR#*/}"; CPFX="${CUST_CIDR#*/}"
echo "  fabric machine $F ($FIP on $FIF, NIC MTU $NICMTU); external segment $EXT_CIDR VNI $EXT_VNI MTU $MTU"
echo "  gateway machines: $GATEWAY_NODES"
confirm "This builds the external segment and the customer network on the machines. Continue?"

# Script run on the fabric machine (stdin). Variables come from the environment.
FABRIC_SH=$(cat <<'EOS'
set -e
cleanup() {
  ip netns del fabric 2>/dev/null || true; ip netns del cust 2>/dev/null || true
  for l in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(vxg[0-9]+|br-priv|ext0p?|fab-br)$'); do ip link del "$l" 2>/dev/null || true; done
}
cleanup
ip link add br-priv type bridge stp_state 0
ip link set br-priv mtu "$MTU" up
ip netns add fabric; ip netns add cust
ip link add fab-br type veth peer name fab0
ip link set fab-br master br-priv; ip link set fab-br mtu "$MTU" up
ip link set fab0 netns fabric
ip link add fab1 type veth peer name cust0
ip link set fab1 netns fabric; ip link set cust0 netns cust
ip netns exec fabric bash -c "ip link set lo up; ip link set fab0 mtu $MTU up; ip addr add $EXT_GATEWAY/$PFX dev fab0
  ip link set fab1 mtu $MTU up; ip addr add $CUST_FABRIC_IP/$CPFX dev fab1
  sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0"
ip netns exec cust bash -c "ip link set lo up; ip link set cust0 mtu $MTU up; ip addr add $CUST_HOST_IP/$CPFX dev cust0; ip route add default via $CUST_FABRIC_IP"
if [ "$FABRIC_IS_GW" = yes ]; then
  ip link add "$EXT_NIC" type veth peer name "${EXT_NIC}p"
  ip link set "${EXT_NIC}p" master br-priv; ip link set "${EXT_NIC}p" mtu "$MTU" up
  ip link set "$EXT_NIC" mtu "$MTU" up
fi
for g in $PEERS; do   # PEERS = "<number>:<address of that machine>" for the other gateway machines
  n=${g%%:*}; a=${g#*:}
  ip link add "vxg$n" type vxlan id "$((EXT_VNI+n))" local "$FIP" remote "$a" dstport 4789 dev "$FIF"   # one VNI per peer: Linux refuses two tunnels with the same VNI and port
  ip link set "vxg$n" master br-priv; ip link set "vxg$n" mtu "$MTU" up
done
echo "fabric ready"
EOS
)
# Script run on every other gateway machine (stdin).
GW_SH=$(cat <<'EOS'
set -e
ip link del "$EXT_NIC" 2>/dev/null || true
ip link add "$EXT_NIC" type vxlan id "$((EXT_VNI+GN))" local "$NODE_IP" remote "$FIP" dstport 4789 dev "$NODE_IF"
ip link set "$EXT_NIC" mtu "$MTU" up
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iputils-arping >/dev/null 2>&1 || true
echo "gateway interface ready"
EOS
)

sec "1. Fabric machine ($F)"
nssh "$F" "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iputils-arping >/dev/null 2>&1; true"
PEERS=""; FIS_GW=no
in_list "$F" $GATEWAY_NODES && FIS_GW=yes
for g in $GATEWAY_NODES; do [ "$g" = "$F" ] && continue; PEERS="$PEERS $g:$(node_ip "$g")"; done
R=$(nroot "$F" MTU="$MTU" PFX="$PFX" CPFX="$CPFX" EXT_GATEWAY="$EXT_GATEWAY" CUST_FABRIC_IP="$CUST_FABRIC_IP" CUST_HOST_IP="$CUST_HOST_IP" \
    EXT_NIC="$EXT_NIC" EXT_VNI="$EXT_VNI" FIP="$FIP" FIF="$FIF" FABRIC_IS_GW="$FIS_GW" PEERS="\"$PEERS\"" <<<"$FABRIC_SH" 2>&1 | tail -3)
echo "  $R"
expect "fabric machine configured" "fabric ready" "$(echo "$R" | tail -1)"

sec "2. Gateway machines"
for g in $GATEWAY_NODES; do
  [ "$g" = "$F" ] && continue
  R=$(nroot "$g" MTU="$MTU" GN="$g" EXT_NIC="$EXT_NIC" EXT_VNI="$EXT_VNI" FIP="$FIP" NODE_IP="$(node_ip "$g")" NODE_IF="$(node_iface "$g")" <<<"$GW_SH" 2>&1 | tail -2)
  expect "machine $g: $EXT_NIC (VXLAN) created" "gateway interface ready" "$(echo "$R" | tail -1)"
done

sec "3. Checks from every gateway machine"
# A temporary address on EXT_NIC (host number 200+machine) is used only for the checks and removed afterwards.
for g in $GATEWAY_NODES; do
  TMPIP="${EXT_GATEWAY%.*}.$((200+g))"
  nssh "$g" "sudo -n ip addr add $TMPIP/$PFX dev $EXT_NIC 2>/dev/null; sudo -n ip link set $EXT_NIC up"
  sleep 1
  L=$(nssh "$g" "ping -c 5 -W 2 -I $EXT_NIC $EXT_GATEWAY 2>&1 | tail -2" 2>/dev/null)
  LOSS=$(echo "$L" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' | head -1)
  expect "machine $g -> fabric $EXT_GATEWAY (loss %)" 0 "${LOSS:-100}"
  SZ=$((MTU-28))
  nssh "$g" "ping -c 2 -W 2 -M do -s $SZ -I $EXT_NIC $EXT_GATEWAY >/dev/null 2>&1" && T=ok || T=fail
  expect "machine $g -> fabric with $MTU-byte packets" ok "$T"
  nssh "$g" "sudo -n arping -D -I $EXT_NIC -c 2 -w 3 ${EXT_GATEWAY%.*}.250 >/dev/null 2>&1"; RC=$?
  expect "machine $g: DAD on $EXT_NIC (0 = no proxy ARP)" 0 "$RC"
  nssh "$g" "sudo -n ip addr del $TMPIP/$PFX dev $EXT_NIC 2>/dev/null; true"
done
# The customer host must answer through the fabric (checked from the fabric machine, no route needed on the gateways).
nssh "$F" "sudo -n ip netns exec fabric ping -c 3 -W 2 $CUST_HOST_IP >/dev/null 2>&1" && C=ok || C=fail
expect "fabric -> customer host $CUST_HOST_IP" ok "$C"
table
