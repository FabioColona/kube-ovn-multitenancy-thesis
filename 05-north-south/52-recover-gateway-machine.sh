#!/bin/bash
# 52-recover-gateway-machine.sh — brings a gateway machine back into service after it was rebooted abruptly
#                                 (./50-gateway-failure.sh ovngw crash ...).
#
# What it does : waits until the machine answers ssh, then rebuilds what a reboot removes and is not persistent:
#                  - the address with prefix NIC_PREFIX_FIX on the NIC (when the NIC address is a /32),
#                  - the external VXLAN interface EXT_NIC towards the fabric machine (same parameters as 10-external-network.sh),
#                  - the network namespace "ovnext" (only when the VPC has BFD enabled; see 31-ovn-gateway.sh, step 2b).
#                Then it restarts kube-ovn-cni on that machine (it configures ovnext0 and attaches EXT_NIC to the bridge) and checks
#                the node, the interface, the namespace, the BFD sessions and the gateway chassis priorities.
# Environment  : the cluster, the customer network and the OVN gateway configuration of the earlier tests (nothing is reconfigured
#                in Kubernetes: the VPC, the EIPs and the routes are still there).
# Changes      : CHANGES THE MACHINE (network interface, namespace, --node-ip of k3s-agent when the address changed); deletes the kube-ovn-cni pod of that machine (recreated at once)
# Requires     : the machine has booted again; passwordless sudo
# Usage        : ./52-recover-gateway-machine.sh <machine number> [--yes]
# Variables    : NODES, NODE_USER, SSH_JUMP, FABRIC_NODE, EXT_*, NIC_PREFIX_FIX, OVNGW_VPC (from config.env)
# Duration     : about 2 minutes plus the wait for the machine
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south, gateway failure with a crashed machine)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars EXT_NIC EXT_VNI OVNGW_VPC FABRIC_NODE

M="${ARGS[0]:-}"
[ -n "$M" ] || die "usage: ./52-recover-gateway-machine.sh <machine number>"
F="$FABRIC_NODE"
[ "$M" != "$F" ] || die "machine $M is the fabric machine: it was not the one that was crashed"
confirm "This recreates $EXT_NIC (and the namespace ovnext) on machine $M and restarts kube-ovn-cni there. Continue?"

sec "1. Machine $M reachable again"
_up() { nssh "$M" true >/dev/null 2>&1; }
WAIT_MSG="waiting for machine $M to answer ssh" waitf 60 5 _up || die "machine $M does not answer ssh after 5 minutes"
info "machine $M up since: $(nssh "$M" 'uptime -s')"
expect "machine $M: sudo works" ok "$(nssh "$M" 'sudo -n true && echo ok || echo fail')"

sec "2. NIC prefix, external interface, namespace ovnext"
fix_nic_prefix "$M"

# CrownLabs gives a machine a new address when it is powered on again; K3s keeps the --node-ip of the installation
HN="$(nssh "$M" hostname | tr -d '\r')"
NIPN="$(node_ip "$M")"
_kip() { rk "$SERVER" "kubectl get node $HN -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null | tr -d '\r'; }
if [ -n "$NIPN" ] && [ "$(_kip)" != "$NIPN" ]; then
  info "machine $M has address $NIPN, Kubernetes knows $(_kip): updating --node-ip of k3s-agent"
  nroot "$M" NEWIP="$NIPN" <<'EOS' >/dev/null 2>&1
set -e
U=$(systemctl show -p FragmentPath --value k3s-agent)
sed -i "s/--node-ip=[0-9.]*/--node-ip=$NEWIP/" "$U"
systemctl daemon-reload
systemctl restart k3s-agent
EOS
  _kok() { [ "$(_kip)" = "$NIPN" ]; }
  WAIT_MSG="waiting for Kubernetes to report $NIPN for $HN" waitf 36 5 _kok
  for a in ovs kube-ovn-cni kube-ovn-pinger; do
    rk "$SERVER" "kubectl -n kube-system delete pod -l app=$a --field-selector spec.nodeName=$HN --wait=false" >/dev/null 2>&1
  done
  _ovs() { rk "$SERVER" "kubectl -n kube-system get pod -l app=ovs --field-selector spec.nodeName=$HN -o jsonpath='{.items[0].status.containerStatuses[0].ready}'" 2>/dev/null | grep -q true; }
  sleep 10
  WAIT_MSG="waiting for ovs-ovn on $HN" waitf 36 5 _ovs
fi
expect "machine $M: node address in Kubernetes equals the NIC address" "$NIPN" "$(_kip)"

# The fabric machine has one VXLAN tunnel per gateway with a fixed remote address (10-external-network.sh): it must follow the
# new address of the machine. The tunnel is recreated with the same parameters (VNI, local address, bridge br-priv).
FFIP="$(node_ip "$F")"; FFIF="$(node_iface "$F")"; FMTU="${EXT_MTU:-$(( $(node_mtu "$F") - 50 ))}"
FR="$(nroot "$F" GN="$M" VNI="$((EXT_VNI+M))" LOCALIP="$FFIP" REMOTEIP="$NIPN" FIF="$FFIF" TMTU="$FMTU" <<'EOS' 2>&1
ip link del vxg$GN 2>/dev/null
ip link add vxg$GN type vxlan id $VNI local $LOCALIP remote $REMOTEIP dstport 4789 dev $FIF && ip link set vxg$GN master br-priv && ip link set vxg$GN mtu $TMTU up
ip -d link show vxg$GN | grep -o 'remote [0-9.]*' | awk '{print $2}'
EOS
)"
FDST="$(echo "$FR" | tail -1)"
[ "$FDST" = "$NIPN" ] || info "fabric tunnel recreation output: $(echo "$FR" | tr '\n' ' ')"
expect "fabric: tunnel vxg$M points to the address of machine $M" "$NIPN" "$FDST"
FIP=$(node_ip "$F"); NIP=$(node_ip "$M"); NIF=$(node_iface "$M"); NICMTU=$(node_mtu "$F")
[ -n "$FIP" ] && [ -n "$NIP" ] && [ -n "$NIF" ] && [ -n "$NICMTU" ] || die "cannot read address, interface or MTU"
MTU="${EXT_MTU:-$((NICMTU-50))}"
R=$(nroot "$M" MTU="$MTU" GN="$M" EXT_NIC="$EXT_NIC" EXT_VNI="$EXT_VNI" FIP="$FIP" NODE_IP="$NIP" NODE_IF="$NIF" <<'EOS' 2>&1 | tail -1
set -e
ip link del "$EXT_NIC" 2>/dev/null || true
ip link add "$EXT_NIC" type vxlan id "$((EXT_VNI+GN))" local "$NODE_IP" remote "$FIP" dstport 4789 dev "$NODE_IF"
ip link set "$EXT_NIC" mtu "$MTU" up
echo "gateway interface ready"
EOS
)
expect "machine $M: $EXT_NIC (VXLAN) created" "gateway interface ready" "$R"
BFD="$(rk "$SERVER" "kubectl get vpc $OVNGW_VPC -o jsonpath='{.status.enableBfd}'" 2>/dev/null | tr -d '\r')"
if [ "$BFD" = true ]; then
  nssh "$M" "sudo -n ip netns list | grep -q '^ovnext' || sudo -n ip netns add ovnext"
  expect "machine $M: namespace ovnext" present "$(nssh "$M" "sudo -n ip netns list | grep -q '^ovnext' && echo present || echo absent")"
else
  info "BFD is not enabled on the VPC: namespace ovnext not needed"
fi

sec "3. Node and kube-ovn-cni"
_ready() { [ "$(rk "$SERVER" "kubectl get node $HN -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null | tr -d '\r')" = True ]; }
WAIT_MSG="waiting for the node $HN to be Ready" waitf 36 5 _ready && RD=ok || RD=fail
expect "node $HN Ready" ok "$RD"
rk "$SERVER" "kubectl -n kube-system delete pod -l app=kube-ovn-cni --field-selector spec.nodeName=$HN --wait=false" >/dev/null 2>&1
_cni() { rk "$SERVER" "kubectl -n kube-system get pod -l app=kube-ovn-cni --field-selector spec.nodeName=$HN -o jsonpath='{.items[0].status.containerStatuses[0].ready}'" 2>/dev/null | grep -q true; }
sleep 5
WAIT_MSG="waiting for kube-ovn-cni on $HN" waitf 36 5 _cni && RD=ok || RD=fail
expect "kube-ovn-cni on $HN ready" ok "$RD"

# after a power cycle the Multus and pinger pods of the node can stay in Unknown / Init: they are recreated by their DaemonSets
# Deadlock after a reboot: the first pods ask the CNI before the Multus daemon is up; their multus-shim processes wait for it and keep
# /opt/cni/bin/multus-shim busy, so the init container of the Multus pod fails with "Text file busy". The waiting shims are ended and the
# binary removed (the init container installs it again).
nroot "$M" <<'EOS' >/dev/null 2>&1
pkill -x multus-shim
sleep 1
rm -f /opt/cni/bin/multus-shim
EOS
for pat in kube-multus-ds kube-ovn-pinger; do
  for pn in $(rk "$SERVER" "kubectl -n kube-system get pod --field-selector spec.nodeName=$HN -o name" 2>/dev/null | tr -d '\r' | grep "/$pat"); do
    rk "$SERVER" "kubectl -n kube-system delete $pn --force --grace-period=0" >/dev/null 2>&1
  done
done
sleep 5
_multus() { rk "$SERVER" "kubectl -n kube-system get pod --field-selector spec.nodeName=$HN -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].ready}{\"\\n\"}{end}'" 2>/dev/null | grep kube-multus-ds | grep -q true; }
WAIT_MSG="waiting for Multus on $HN" waitf 36 5 _multus && RD=ok || RD=fail
expect "Multus on $HN ready" ok "$RD"

sec "4. Gateway state"
if [ "$BFD" = true ]; then
  info "ovnext0 on machine $M: $(nssh "$M" 'sudo -n ip netns exec ovnext ip -br addr 2>/dev/null | grep ovnext0' | tr '\n' ' ')"
  NGW=0; for g in $GATEWAY_NODES; do NGW=$((NGW+1)); done
  _bfd() {
    local PR UP
    PR="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=priority list gateway_chassis" 2>/dev/null | tr -d '\r' | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
    UP="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=status find bfd status=up" 2>/dev/null | tr -d '\r' | grep -c up)"
    [ "$PR" = 1 ] && [ "$UP" -ge "$NGW" ]
  }
  # Kube-OVN lowers the priority of a chassis whose BFD session went down (98 instead of 101) and may leave it lowered
  # after the session is back up: once all sessions are up, the priorities are set back to the configured value.
  _allup() { [ "$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=status find bfd status=up" 2>/dev/null | tr -d '\r' | grep -c up)" -ge "$NGW" ]; }
  WAIT_MSG="waiting for the BFD sessions up" waitf 36 5 _allup
  GWPRIO="${GW_PRIORITY:-101}"
  rks "$SERVER" <<EOS >/dev/null 2>&1
N="kubectl -n kube-system exec deploy/ovn-central -c ovn-central --"
\$N ovn-nbctl --format=csv --no-headings --columns=_uuid,priority list gateway_chassis | tr -d '"\r' | awk -F, '\$2!=$GWPRIO{print \$1}' | while read u; do \$N ovn-nbctl set gateway_chassis "\$u" priority=$GWPRIO; done
EOS
  WAIT_MSG="waiting for the BFD sessions up and equal priorities" waitf 36 5 _bfd && B=ok || B=fail
  expect "BFD sessions up and equal chassis priorities" ok "$B"
fi
info "router port cr-$OVNGW_VPC-external: $(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external" 2>/dev/null | tr -d '\r\n ')"
table; RC=$?
echo "  next: ./34-http-check.sh to check that the tenant traffic passes (an outage of up to 10 minutes can follow a change of the router port, see the notes)"
exit $RC
