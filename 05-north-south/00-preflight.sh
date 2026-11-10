#!/bin/bash
# 00-preflight.sh — read-only check of the machines before building the north-south test bed.
#
# What it does : connects to every machine in NODES and reports OS, kernel, CPUs, memory, free disk, KVM, sudo, NIC and MTU;
#                checks the path MTU between machine 1 and the others; checks whether the network answers ARP for an
#                address nobody owns (proxy ARP: it makes the duplicate address detection of the NAT Gateway fail).
# Environment  : Linux machines (Ubuntu 24.04 or newer) reachable with SSH; run from YOUR COMPUTER
# Changes      : READ-ONLY (the only side effect is the SSH connection kept open for 10 minutes)
# Requires     : bash >= 3.2, ssh, scp; passwordless sudo on the machines
# Usage        : ./00-preflight.sh
# Variables    : NODES, NODE_USER, SSH_PORT, SSH_JUMP, NODE_IFACE, CLUSTER_NODES, FABRIC_NODE, GATEWAY_NODES (from config.env)
# Duration     : about 30 seconds
# Exit code    : 0 = no FAIL; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south test bed)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup

PROBE=$(cat <<'EOS'
IF=$(ip -4 route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
echo "os=$(. /etc/os-release; echo "$PRETTY_NAME")"
echo "kernel=$(uname -r)"
echo "cpus=$(nproc)"
echo "memmb=$(free -m | awk '/Mem:/{print $2}')"
echo "diskgb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)"
echo "kvm=$([ -c /dev/kvm ] && echo yes || echo no)"
echo "nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -1)"
echo "iface=$IF"
echo "ip=$IP"
echo "mtu=$(cat /sys/class/net/$IF/mtu)"
echo "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)"
echo "k3s=$([ -x /usr/local/bin/k3s ] && echo yes || echo no)"
if command -v arping >/dev/null 2>&1; then
  FREE="${IP%.*}.250"
  sudo -n arping -D -I "$IF" -c 2 -w 3 "$FREE" >/dev/null 2>&1; echo "dad_rc=$? ($FREE)"
else echo "dad_rc=noarping"; fi
EOS
)

get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

N=$(node_n)
sec "1. Machines"
for ((i=1;i<=N;i++)); do
  H=$(node_host "$i")
  OUT=$(nssh "$i" 'bash -s' <<<"$PROBE" 2>/dev/null) || OUT=""
  if [ -z "$OUT" ]; then bad "machine $i ($H): SSH does not answer"; eval "UP_$i=no"; continue; fi
  eval "UP_$i=yes IP_$i=$(get ip) MTU_$i=$(get mtu) IF_$i=$(get iface) CPUS_$i=$(get cpus) MEM_$i=$(get memmb)"
  ok "machine $i ($H): $(get os), kernel $(get kernel), $(get cpus) vCPU, $(get memmb) MB, $(get diskgb) GB free"
  info "   NIC $(get iface) $(get ip), MTU $(get mtu); /dev/kvm $(get kvm), nested $(get nested)"
  [ "$(get sudo)" = yes ] && ok "machine $i: passwordless sudo" || bad "machine $i: sudo needs a password (the scripts need passwordless sudo)"
  [ "$(get memmb)" -ge 3500 ] 2>/dev/null && ok "machine $i: memory >= 3.5 GB" || wrn "machine $i: less than 3.5 GB of memory"
  [ "$(get diskgb)" -ge 8 ] 2>/dev/null && ok "machine $i: free disk >= 8 GB" || wrn "machine $i: less than 8 GB free on /"
  [ "$(get k3s)" = no ] && ok "machine $i: K3s not installed" || wrn "machine $i: K3s already installed (./90-reset.sh removes it)"
  case "$(get dad_rc)" in
    1*) wrn "machine $i: the network answers ARP for a free address $(get dad_rc | sed 's/^[0-9]* //') — proxy ARP: duplicate address detection always fails on $(get iface)" ;;
    0*) ok  "machine $i: no proxy ARP on $(get iface) ($(get dad_rc | sed 's/^[0-9]* //') is free)" ;;
    *)  info "   proxy ARP check skipped (arping not installed; 10-external-network.sh installs it)" ;;
  esac
done

sec "2. Roles and uniformity"
for r in CLUSTER_NODES GATEWAY_NODES; do
  for i in ${!r}; do
    [ "$i" -ge 1 ] && [ "$i" -le "$N" ] 2>/dev/null && ok "$r: machine $i exists" || bad "$r: machine $i is not in NODES"
  done
done
[ "$FABRIC_NODE" -ge 1 ] && [ "$FABRIC_NODE" -le "$N" ] 2>/dev/null && ok "FABRIC_NODE: machine $FABRIC_NODE exists" || bad "FABRIC_NODE $FABRIC_NODE is not in NODES"
for i in $GATEWAY_NODES; do in_list "$i" $CLUSTER_NODES || bad "gateway machine $i is not in CLUSTER_NODES"; done
in_list "$FABRIC_NODE" $GATEWAY_NODES && wrn "the fabric machine ($FABRIC_NODE) is also a gateway: it will compete with the gateway for CPU in the benchmarks"
FIRSTC=$(eval echo "\${CPUS_${CLUSTER_NODES%% *}:-}"); DIFF=0
for i in $CLUSTER_NODES; do [ "$(eval echo "\${CPUS_$i:-}")" = "$FIRSTC" ] || DIFF=1; done
[ "$DIFF" = 0 ] && ok "all cluster machines have the same number of vCPUs ($FIRSTC)" || wrn "cluster machines have different vCPU counts: gateways must have equal limits to compare fairly"

sec "3. Path between the machines (from machine 1)"
if [ "${UP_1:-no}" = yes ]; then
  M1=$(eval echo "\${MTU_1:-1500}")
  for ((j=2;j<=N;j++)); do
    [ "$(eval echo "\${UP_$j:-no}")" = yes ] || continue
    IPJ=$(eval echo "\${IP_$j}"); SZ=$((M1-28))
    R=$(nssh 1 "ping -c 5 -W 2 $IPJ | tail -1" 2>/dev/null)
    [ -n "$R" ] && ok "1 -> $j ($IPJ): $R" || bad "1 -> $j ($IPJ): no answer"
    nssh 1 "ping -c 2 -W 2 -M do -s $SZ $IPJ >/dev/null 2>&1" && ok "1 -> $j: packets of $((SZ+28)) bytes pass without fragmenting (path MTU = NIC MTU $M1)" \
      || bad "1 -> $j: packets of $((SZ+28)) bytes do not pass: the path MTU is lower than the NIC MTU $M1"
  done
fi
summary
