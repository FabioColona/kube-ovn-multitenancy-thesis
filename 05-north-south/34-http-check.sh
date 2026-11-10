#!/bin/bash
# 34-http-check.sh — read-only: repeats ping and HTTP from the OVN Gateway test pod to the customer host and counts the results.
#
# What it does : from the pod oprobe (created by 31-ovn-gateway.sh) sends N pings and N HTTP requests (one per second, timeout 3 s)
#                to the customer host and prints how many worked and the HTTP time of each request. It tells whether an HTTP failure
#                seen right after the configuration was a warm-up transient or a stable problem (ping can work while TCP does not).
# Environment  : the cluster after ./31-ovn-gateway.sh
# Changes      : nothing
# Usage        : ./34-http-check.sh [N]        (default 20)
# Duration     : about N*2 seconds
# Exit code    : 0 = all HTTP requests worked, 1 = some failed
# In the thesis: not cited (support script; its output is raw evidence)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
N="${ARGS[0]:-20}"
STAMP="$(date +%Y%m%d-%H%M%S)"; OUT="${BENCH_RESULTS_DIR:-$HERE/results}/ovn-gateway/diagnostics/http-check-$STAMP.txt"; mkdir -p "$(dirname "$OUT")"
rk "$SERVER" "kubectl -n $NS_OVNGW get pod oprobe" >/dev/null 2>&1 || die "the pod oprobe does not exist in $NS_OVNGW: run ./31-ovn-gateway.sh first"
sec "$N ping + HTTP requests to $CUST_HOST_IP from oprobe"
rks "$SERVER" 2>&1 <<EOS | tee "$OUT"
OK=0; PK=0
for i in \$(seq 1 $N); do
  kubectl -n $NS_OVNGW exec oprobe -- ping -c 1 -W 2 $CUST_HOST_IP >/dev/null 2>&1 && P=ok || P=FAIL
  R=\$(kubectl -n $NS_OVNGW exec oprobe -- curl -s -m 3 -o /dev/null -w '%{http_code} %{time_total}' http://$CUST_HOST_IP:8080/ 2>/dev/null)
  C=\${R%% *}; [ "\$C" = 200 ] && OK=\$((OK+1)); [ "\$P" = ok ] && PK=\$((PK+1))
  echo "\$(date +%T) request \$i: ping \$P  http \${R:-timeout}"
  sleep 1
done
echo "ping ok: \$PK/$N   http 200: \$OK/$N"
EOS
echo "  raw output: $OUT"
# exit code: 0 only if every HTTP request got 200
grep -q "http 200: $N/$N" "$OUT"
