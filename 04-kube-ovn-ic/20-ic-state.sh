#!/bin/bash
# 20-ic-state.sh — state of the interconnection: zones, routes learned and traffic between pods of the two sites.
#
# What it does : checks that both zones are in the OVN-IC database, that each site has learned the pod CIDR of the other
#                (one route per transit switch, ECMP), then creates one pod per site and pings each from the other
#                (REPETITIONS times) and reads the MTU of the pods. The pods are removed at the end.
# Environment  : sites with OVN-IC installed by 11-install-ic.sh
# Changes      : creates and deletes a namespace with one pod per site; nothing else
# Requires     : bash >= 3.2, ssh
# Usage        : ./20-ic-state.sh          (REPETITIONS=1 ./20-ic-state.sh for a quick run)
# Variables    : SITE_A_*, SITE_B_*, IC_TS_NUM, CHECK_IMAGE, REPETITIONS (from config.env)
# Duration     : about 2 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (baseline of the OVN-IC laboratory)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
REPETITIONS="${REPETITIONS:-5}"
for s in a b; do rk "$s" 'kubectl get nodes >/dev/null 2>&1' || die "site $s has no working cluster"; done

cleanup() { for s in a b; do rk "$s" 'kubectl delete namespace ic-check --wait=false >/dev/null 2>&1'; done; }
trap cleanup EXIT
for s in a b; do rk "$s" 'kubectl delete namespace ic-check --wait=true >/dev/null 2>&1'; done

sec "1. Zones and routes"
O="$(ic_icsb_show 2>/dev/null)"
expect "zone $SITE_A_AZ in the IC database" yes "$(grep -q "availability-zone $SITE_A_AZ" <<<"$O" && echo yes || echo no)"
expect "zone $SITE_B_AZ in the IC database" yes "$(grep -q "availability-zone $SITE_B_AZ" <<<"$O" && echo yes || echo no)"
RA="$(rk a "kubectl ko nbctl lr-route-list ovn-cluster" 2>/dev/null | grep -c "$SITE_B_POD_CIDR.*learned")"
RB="$(rk b "kubectl ko nbctl lr-route-list ovn-cluster" 2>/dev/null | grep -c "$SITE_A_POD_CIDR.*learned")"
expect "routes to $SITE_B_POD_CIDR learned on site A" "$IC_TS_NUM" "$RA"
expect "routes to $SITE_A_POD_CIDR learned on site B" "$IC_TS_NUM" "$RB"

sec "2. Test pods"
for s in a b; do
  rk "$s" "kubectl create namespace ic-check >/dev/null && kubectl -n ic-check run p --image=$CHECK_IMAGE --restart=Never -- sleep 3600 >/dev/null" || die "cannot create the pod on site $s"
done
for s in a b; do
  run_spin "site $s: waiting for the test pod" "image download, up to 3 minutes" rk "$s" 'kubectl -n ic-check wait --for=condition=Ready pod/p --timeout=180s' || warn "pod of site $s not Ready"
done
PA="$(rk a "kubectl -n ic-check get pod p -o jsonpath='{.status.podIP}'" 2>/dev/null)"
PB="$(rk b "kubectl -n ic-check get pod p -o jsonpath='{.status.podIP}'" 2>/dev/null)"
[ -n "$PA" ] && [ -n "$PB" ] || die "the test pods have no address"
echo "pod of site A = $PA   pod of site B = $PB   ($REPETITIONS repetitions per row)"

# ping_n <site> <destination>: pings REPETITIONS times from the test pod of the site; prints "N/REPETITIONS".
ping_n() {
  local i ok=0
  for ((i=0;i<REPETITIONS;i++)); do
    tick "pinging $2 from site $1" $((i+1)) "$REPETITIONS"
    rk "$1" "kubectl -n ic-check exec p -- ping -c 1 -W 2 $2 >/dev/null 2>&1" && ok=$((ok+1))
  done
  clear_line; echo "$ok/$REPETITIONS"
}
sec "3. Traffic between the sites"
expect "site A -> site B ($PB)" "$REPETITIONS/$REPETITIONS" "$(ping_n a "$PB")"
expect "site B -> site A ($PA)" "$REPETITIONS/$REPETITIONS" "$(ping_n b "$PA")"
# Kube-OVN v1.13.0 subtracts 100 bytes from the MTU of the node interface (1500 -> 1400, CrownLabs 1340 -> 1240).
NODE_MTU="$(ssh_to a "cat /sys/class/net/$SITE_A_IFACE/mtu" 2>/dev/null | tr -d '\r')"
expect "MTU of the pod on site A (node NIC ${NODE_MTU:-?} minus 100)" "$(( ${NODE_MTU:-1500} - 100 ))" "$(rk a "kubectl -n ic-check exec p -- cat /sys/class/net/eth0/mtu" 2>/dev/null | tr -d '\r')"
NODE_MTU_B="$(ssh_to b "cat /sys/class/net/$SITE_B_IFACE/mtu" 2>/dev/null | tr -d '\r')"
expect "MTU of the pod on site B (node NIC ${NODE_MTU_B:-?} minus 100)" "$(( ${NODE_MTU_B:-1500} - 100 ))" "$(rk b "kubectl -n ic-check exec p -- cat /sys/class/net/eth0/mtu" 2>/dev/null | tr -d '\r')"
table
