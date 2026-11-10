#!/bin/bash
# 44-move-router-port.sh — moves the router port of the OVN Gateway VPC (the active chassis of the SNAT) to a chosen machine.
#
# What it does : raises the priority of the OVN gateway chassis of the chosen machine above the others and waits until the
#                port cr-<vpc>-external is bound to that machine. It is a deliberate manipulation of the state, used to test whether
#                the throughput depends on WHERE the router port is (same machine as the client pods or not). It does not change
#                the ECMP routes, the BFD sessions or the workloads.
# Environment  : the cluster, with the OVN Gateway configured (./31-ovn-gateway.sh). Kube-OVN may reset the priorities later
#                (for example after a BFD state change): always check the position with the benchmark, which prints it.
# Usage        : ./44-move-router-port.sh <machine number, as in config.env: 1 or 2> [--yes]
# Duration     : up to a minute
# Exit code    : 0 if the port is on the chosen machine at the end, 1 otherwise
# In the thesis: Chapter 6 (north-south throughput: effect of the position of the active chassis)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars OVNGW_VPC
TARGET="${ARGS[0]:-}"; [ -n "$TARGET" ] || die "usage: ./44-move-router-port.sh <machine number> (one of: $CLUSTER_NODES)"
in_list "$TARGET" $CLUSTER_NODES || die "machine $TARGET is not in the cluster ($CLUSTER_NODES)"
for c in $CLUSTER_NODES; do eval "HN_$c=\"\$(nssh $c hostname | tr -d '\r')\""; done
hn() { eval "echo \$HN_$1"; }
machine_of() { local c; for c in $CLUSTER_NODES; do [ "$(hn "$c")" = "$1" ] && { echo "$c"; return; }; done; }
sbq() { rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl $*" 2>/dev/null | tr -d '\r'; }
nbq() { rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl $*" 2>/dev/null | tr -d '\r'; }
where() {
  local C H; C="$(sbq --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external | tr -d '\n ')"
  [ -n "$C" ] || { echo none; return; }
  H="$(sbq --bare --columns=hostname list chassis "$C" | tr -d '\n ')"; machine_of "$H"
}

sec "1. Router port"
CUR="$(where)"; info "router port cr-$OVNGW_VPC-external now on machine: $CUR; wanted: $TARGET"
if [ "$CUR" = "$TARGET" ]; then info "already there: nothing to do"; exit 0; fi
confirm "This changes the priority of the gateway chassis of machine $TARGET to move the router port. Continue?"

sec "2. Priority"
CH="$(sbq --bare --columns=name find chassis hostname="$(hn "$TARGET")" | tr -d '\n ')"
[ -n "$CH" ] || die "chassis of machine $TARGET not found"
GC="$(nbq --bare --columns=_uuid find gateway_chassis chassis_name="$CH" | tr -d '\n ')"
[ -n "$GC" ] || die "gateway_chassis of machine $TARGET not found"
MAXP="$(nbq --bare --columns=priority list gateway_chassis | grep -E '^[0-9]+$' | sort -n | tail -1)"
NEWP=$(( ${MAXP:-100} + 10 ))
info "chassis $CH: priority -> $NEWP (highest now: ${MAXP:-?})"
nbq set gateway_chassis "$GC" priority="$NEWP" >/dev/null

sec "3. Waiting for the port"
_moved() { [ "$(where)" = "$TARGET" ]; }
WAIT_MSG="waiting for the router port" waitf 12 5 _moved
NOW="$(where)"; expect "router port on the chosen machine" "$TARGET" "$NOW"
table
[ "${RES_STATUS[0]}" = PASS ]; exit $?
