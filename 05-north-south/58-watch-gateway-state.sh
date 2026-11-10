#!/bin/bash
# 58-watch-gateway-state.sh — watches the OVN Gateway with no failure, to see whether and when it reaches a stable state (read only).
#
# What it does : every STEP seconds, for DURATION seconds, records the machine that holds the router port cr-<vpc>-external (where
#                the SNAT is done), the priority of every gateway chassis and the status of every BFD session. At the end it
#                prints how many different states were seen, when the last change happened and the final state. It answers the
#                question "does the gateway settle by itself after the configuration, and how long does it take?", which decides
#                the criterion that 50-gateway-failure.sh uses before every repetition (SETTLE=stable or equal).
# Environment  : the cluster with the OVN Gateway configured (./31-ovn-gateway.sh). No failure is injected, nothing is changed.
# Usage        : ./58-watch-gateway-state.sh [DURATION seconds, default 600] [STEP seconds, default 10]
# Output       : the table on screen and, with BENCH_RESULTS_DIR, a copy in $BENCH_RESULTS_DIR/failure/watch-<date>.txt
# Duration     : DURATION seconds
# Exit code    : 0 always (it only observes)
# In the thesis: Chapter 6 (gateway failures: method)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars OVNGW_VPC
DUR="${ARGS[0]:-600}"; STEP="${ARGS[1]:-10}"
OUTD="${BENCH_RESULTS_DIR:-$HERE/results}/failure"; mkdir -p "$OUTD"
OUTF="$OUTD/watch-$(date +%Y%m%d-%H%M%S).txt"

sec "State of the OVN Gateway every ${STEP}s for ${DUR}s (no failure)"
info "columns: elapsed s | machine of the router port | chassis priorities | BFD sessions (dst_ip=status)"
# one ssh session on the server runs the whole loop (no ssh overhead between samples)
rks "$SERVER" <<EOS 2>&1 | grep -v -E "WARNING|post-quantum|openssh|vulnerable|upgraded" | tee "$OUTF"
N="kubectl -n kube-system exec deploy/ovn-central -c ovn-central --"
T0=\$(date +%s)
while [ \$(( \$(date +%s) - T0 )) -le $DUR ]; do
  E=\$(( \$(date +%s) - T0 ))
  C=\$(\$N ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external 2>/dev/null | tr -d '\r\n ')
  H=none; [ -n "\$C" ] && H=\$(\$N ovn-sbctl --bare --columns=hostname list chassis "\$C" 2>/dev/null | tr -d '\r\n ')
  P=\$(\$N ovn-nbctl --bare --columns=chassis_name,priority list gateway_chassis 2>/dev/null | tr -d '\r' | grep -v '^\$' | paste -d= - - | sort | tr '\n' ' ')
  B=\$(\$N ovn-nbctl --bare --columns=dst_ip,status list bfd 2>/dev/null | tr -d '\r"' | grep -v '^\$' | paste -d= - - | sort | tr '\n' ' ')
  echo "\$E | port: \$H | prio: \$P| bfd: \$B"
  sleep $STEP
done
EOS

sec "Summary"
awk -F'|' '{st=$2"|"$3"|"$4; if(st!=last){n++; lastchg=$1+0; last=st}} END{
  printf "  samples: %d   different states: %d   last change at: %d s\n", NR, n, lastchg;
  printf "  final state: %s\n", last }' "$OUTF"
info "a state that stops changing early (and stays) means SETTLE=stable is the right criterion; priorities that are never all equal mean SETTLE=equal cannot work"
info "saved: $OUTF"
exit 0
