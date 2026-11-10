#!/bin/bash
# 64-bfd-probe.sh — snapshot of the BFD sessions of the OVN Gateway: what the databases say AND what is on the wire (read only).
#
# What it does : writes <prefix>-db.txt with, from ovn-central: the chassis that hosts the router port cr-<vpc>-external, the
#                gateway chassis priorities, the NB and SB BFD rows (all columns), the routes of the VPC and the logical flows of
#                the VPC router that use ECMP or BFD. Then, for 6 seconds and at the same time, captures the BFD packets (UDP 3784)
#                on EXT_NIC and on ovnext0 (namespace ovnext) of every gateway machine, and on the bridge br-priv of the fabric
#                machine (<prefix>-wire-m<N>.txt): for every packet the file keeps the line with the two addresses
#                ("a.b.c.d.port > e.f.g.h.3784") and the line with the BFD state (Up / Down / Init), so each packet can be
#                assigned to its session.
#                It answers: when the database shows a BFD session "up", is that session really exchanging Up packets?
# Environment  : OVN Gateway in ECMP+BFD mode (./31-ovn-gateway.sh N bfd). Used by 50-gateway-failure.sh through PROBE_CMD.
# Changes      : nothing (installs tcpdump on the machines if missing)
# Usage        : ./64-bfd-probe.sh <output prefix>
# Exit code    : 0 always
# In the thesis: Chapter 6 (failures of the OVN Gateway: BFD after the move of the router port)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
PFX="${ARGS[0]:-$HERE/results/bfd-probe-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$(dirname "$PFX")"
N="kubectl -n kube-system exec deploy/ovn-central -c ovn-central --"
GW="${GATEWAY_NODES:-1 2 3}"

# the captures start first, in parallel, so that they cover the same 6 seconds as the database snapshot
for m in $GW; do
  ( nroot "$m" EXT_NIC="$EXT_NIC" <<'EOS' > "$PFX-wire-m$m.txt" 2>&1
command -v tcpdump >/dev/null || { apt-get install -y -qq tcpdump >/dev/null 2>&1; }
echo "## $(hostname) $(date +%s.%N)"
echo "## $EXT_NIC (external interface of the machine)"
T=$(mktemp -d)
timeout 6 tcpdump -lnni "$EXT_NIC" -v udp port 3784 2>&1 | grep -E ' > |State' | head -200 > "$T/ext" &
ip netns exec ovnext timeout 6 tcpdump -lnni ovnext0 -v udp port 3784 2>&1 | grep -E ' > |State' | head -200 > "$T/ovn" &
wait
cat "$T/ext"
echo "## ovnext0 (namespace ovnext, captured during the same 6 seconds)"
cat "$T/ovn"; rm -rf "$T"
EOS
  ) &
done
( nroot "$FABRIC_NODE" <<'EOS' > "$PFX-wire-m$FABRIC_NODE.txt" 2>&1
command -v tcpdump >/dev/null || { apt-get install -y -qq tcpdump >/dev/null 2>&1; }
echo "## fabric $(date +%s.%N)"; echo "## br-priv (the external segment)"
timeout 6 tcpdump -lnni br-priv -e -v udp port 3784 2>&1 | grep -E ' > |State' | head -400
EOS
) &

{ echo "## $(date +%s.%N)"
  echo "--- chassis hosting cr-$OVNGW_VPC-external"
  rk "$SERVER" "C=\$($N ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external | tr -d '\r '); [ -n \"\$C\" ] && $N ovn-sbctl --bare --columns=hostname list chassis \$C"
  echo "--- gateway chassis (NB)"; rk "$SERVER" "$N ovn-nbctl --columns=chassis_name,priority list gateway_chassis"
  echo "--- chassis (name hostname)"; rk "$SERVER" "$N ovn-sbctl --columns=name,hostname list chassis"
  echo "--- BFD (NB, all columns)"; rk "$SERVER" "$N ovn-nbctl list bfd"
  echo "--- BFD (SB, all columns)"; rk "$SERVER" "$N ovn-sbctl list bfd"
  echo "--- routes of the VPC"; rk "$SERVER" "$N ovn-nbctl lr-route-list $OVNGW_VPC"
  echo "--- logical flows of the VPC router with ECMP or BFD"
  rk "$SERVER" "$N ovn-sbctl lflow-list $OVNGW_VPC" | grep -E 'ecmp|bfd|reg8\[0..15\]|select\(' | head -60
} > "$PFX-db.txt" 2>&1
wait
echo "saved: $PFX-db.txt and $PFX-wire-m*.txt"
exit 0
