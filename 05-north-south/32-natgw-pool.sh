#!/bin/bash
# 32-natgw-pool.sh — NAT Gateway with a small external address pool: what happens to the EIP (NoAvailableAddress).
#
# What it does : runs 30-nat-gateway.sh with the external pool of the gateway limited to N free addresses (the gateway pod
#                takes one for its interface net1, an EIP needs another one) and keeps the whole output, the status and events of
#                the EIP and the lines of kube-ovn-controller about it. With N=1 the EIP is expected to stay not Ready
#                (NoAvailableAddress); with N=2 (control) it is expected to become Ready.
# Environment  : the cluster of 20-install-cluster.sh and the customer network of 10-external-network.sh. No NAT Gateway
#                configured (run ./39-remove-nat-gateway.sh first, and ./39-remove-ovn-gateway.sh if the OVN Gateway is up).
# Changes      : CHANGES THE CLUSTER (same objects as 30-nat-gateway.sh). Remove them afterwards with ./39-remove-nat-gateway.sh.
# Usage        : ./32-natgw-pool.sh <free addresses in the pool: 1 or 2>
# Duration     : about 8 minutes (N=1: the EIP never gets Ready)
# Exit code    : 0 = outcome as expected, 1 = not as expected, 2 = prerequisite missing
# In the thesis: Section 4.7.1 and Chapter 6 (external pool must have at least two free addresses)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
N="${ARGS[0]:-}"; case "$N" in 1|2) ;; *) die "usage: ./32-natgw-pool.sh <1|2>  (free addresses left in the external pool)" ;; esac
[ "$NAT_EXTERNAL" = segment ] || die "this test is written for NAT_EXTERNAL=segment"
rk "$SERVER" "kubectl get vpc $NAT_VPC" >/dev/null 2>&1 && die "the VPC $NAT_VPC already exists: run ./39-remove-nat-gateway.sh first (an old gateway would be measured, not this one)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BENCH_RESULTS_DIR:-$HERE/results}/natgw-pool/pool-$N-$STAMP"; mkdir -p "$OUT"
echo "  results: $OUT"
{ echo "date: $(date -u +%FT%TZ)"; echo "purpose: EIP of the NAT Gateway with $N free address(es) in the external pool"
  echo "hypothesis: N=1 -> gateway Running, EIP not Ready (NoAvailableAddress); N=2 -> EIP Ready"
  rk "$SERVER" "kubectl -n kube-system get deploy kube-ovn-controller -o jsonpath='{.spec.template.spec.containers[0].image}'"; echo; } > "$OUT/environment.txt"

EXT_POOL_SIZE="$N" "$HERE/30-nat-gateway.sh" $([ "$ASSUME_YES" = 1 ] && echo --yes) 2>&1 | tee "$OUT/30-output.txt"
RC30=${PIPESTATUS[0]}
[ "$RC30" != 2 ] || die "30-nat-gateway.sh stopped on a missing prerequisite (exit 2): nothing was measured"

sec "Status of the EIP"
{ rk "$SERVER" "kubectl get iptables-eip eip-nat -o yaml 2>&1"
  echo "--- events"; rk "$SERVER" "kubectl describe iptables-eip eip-nat 2>&1 | sed -n '/Events/,\$p'"
  echo "--- kube-ovn-controller (EIP, NoAvailableAddress)"; rk "$SERVER" "kubectl -n kube-system logs deploy/kube-ovn-controller --since=15m 2>&1 | grep -i -E 'eip-nat|NoAvailableAddress|no address|exhaust' | tail -30"
  echo "--- addresses of the external subnet"; rk "$SERVER" "kubectl get subnet $NAT_EXT_SUBNET -o yaml | grep -i -E 'availableIPs|usingIPs|excludeIps|^  - |ip:'"
  echo "--- gateway pod"; rk "$SERVER" "kubectl -n kube-system get pod vpc-nat-gw-$NAT_GW-0 --no-headers 2>&1"; } > "$OUT/eip-status.txt" 2>&1
cat "$OUT/eip-status.txt"
READY="$(rk "$SERVER" "kubectl get iptables-eip eip-nat -o jsonpath='{.status.ready}'" 2>/dev/null | tr -d '\r')"
if [ "$N" = 1 ]; then EXP=false; else EXP=true; fi
expect "EIP Ready with $N free address(es) in the pool" "$EXP" "${READY:-false}"
table
echo "  raw output and status: $OUT   (remove the objects with ./39-remove-nat-gateway.sh)"
[ "${RES_STATUS[0]}" = PASS ]; exit $?
