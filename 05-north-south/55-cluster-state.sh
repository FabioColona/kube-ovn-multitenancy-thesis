#!/bin/bash
# 55-cluster-state.sh — read-only overview: address of every machine vs address known to Kubernetes, nodes, pods that are not ready.
# Usage: ./55-cluster-state.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -o pipefail
ns_setup
F() { grep -v -E "WARNING|post-quantum|openssh|vulnerable|upgraded"; }
echo "=== machines: uptime and NIC address"
for n in $(seq 1 "$(node_n)"); do
  printf 'machine %s: ' "$n"; nssh "$n" 'echo "$(hostname)  up since $(uptime -s)  $(ip -4 -br addr show $(ip route | awk "/default/{print \$5; exit}") | awk "{print \$3,\$4}")"' 2>&1 | F | tail -1
done
echo "=== nodes (address known to Kubernetes)"
rk "$SERVER" "kubectl get node -o wide | awk '{print \$1,\$2,\$6}'" 2>&1 | F
echo "=== kube-system pods not Running 1/1 or restarted"
rk "$SERVER" "kubectl -n kube-system get pod -o wide | awk 'NR==1 || \$3!=\"Running\" || \$2 ~ /^0\\// {print \$1,\$2,\$3,\$4,\$7}'" 2>&1 | F
echo "=== tenant pods"
rk "$SERVER" "kubectl get pod -A -o wide | grep -E 'fail-|ns-ovngw' | awk '{print \$1,\$2,\$3,\$4,\$8}'" 2>&1 | F
echo "=== events of the first pod that is not ready"
rk "$SERVER" "P=\$(kubectl get pod -A --no-headers | awk '/fail-/ && \$4!=\"Running\"{print \$1\" \"\$2; exit}'); [ -n \"\$P\" ] && set -- \$P && kubectl -n \$1 describe pod \$2 | tail -12" 2>&1 | F
