#!/bin/bash
# 63-baseline-ext.sh — reference measurement: TCP throughput from a gateway machine to the customer host through the simulated
#                      external segment (EXT_NIC VXLAN -> bridge br-priv on the fabric machine -> router fabric -> customer),
#                      with no Kubernetes and no gateway on the path.
#
# What it does : puts a temporary address on EXT_NIC of machine M (host number 200+M) and a route to CUST_CIDR through the
#                fabric router, then runs iperf3 from the host of machine M to the customer host for every value of
#                BENCH_FLOWS, BENCH_REPS repetitions of BENCH_DURATION seconds, recording throughput, retransmissions and the
#                CPU (mean, busiest core, %soft) of machine M and of the fabric machine. It tells whether the ceiling seen
#                with the gateways is the limit of the simulated external segment itself. Address and route are removed at the end.
# Environment  : the external network of this folder; NO gateway may be configured (EXT_NIC must be free: not in OVS, no macvlan)
# Changes      : temporary address and route on machine M (removed); iperf3 server in the namespace cust (stopped)
# Usage        : ./63-baseline-ext.sh [M, default 1] [--yes]
# Exit code    : 0 = completed; 1 = a run gave no traffic; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south throughput: limit of the environment)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
M="${ARGS[0]:-1}"; F="$FABRIC_NODE"; D=$BENCH_DURATION; R=$BENCH_REPS
PFX="${EXT_CIDR#*/}"; TMPIP="${EXT_GATEWAY%.*}.$((200+M))"
STAMP="$(date +%Y%m%d-%H%M%S)"; OUT="${BENCH_RESULTS_DIR:-$HERE/results}/benchmark/baseline-ext-m$M-$STAMP"; mkdir -p "$OUT"

sec "1. Prerequisites"
for c in $M $F; do   # tools (a new machine has neither iperf3 nor mpstat)
  nroot "$c" <<'EOS' >/dev/null 2>&1
command -v mpstat >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat >/dev/null 2>&1; }
command -v iperf3 >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null 2>&1; }
true
EOS
  nssh "$c" "command -v iperf3 >/dev/null && command -v mpstat >/dev/null" || die "machine $c: iperf3 or mpstat missing and not installable"
done
nssh "$M" "ip link show $EXT_NIC >/dev/null 2>&1" || die "machine $M has no $EXT_NIC: run ./10-external-network.sh first"
[ "$(nssh "$M" "ip -d link show $EXT_NIC | grep -c 'master'" | tr -d ' \r')" = 0 ] || die "$EXT_NIC of machine $M is attached to a bridge (a gateway is configured): remove it first (39-remove-*)"
[ "$(nssh "$M" "ip -d link show type macvlan 2>/dev/null | grep -c 'link $EXT_NIC'" | tr -d ' \r')" = 0 ] || die "a macvlan sits on $EXT_NIC (NAT Gateway still there?)"
confirm "This adds $TMPIP to $EXT_NIC of machine $M and a route to $CUST_CIDR (both removed at the end). Continue?"
cleanup() { nssh "$M" "sudo -n ip route del $CUST_CIDR via $EXT_GATEWAY dev $EXT_NIC 2>/dev/null; sudo -n ip addr del $TMPIP/$PFX dev $EXT_NIC 2>/dev/null; true" >/dev/null 2>&1
            nroot "$F" <<<'pkill -f "iperf3 -s -B" 2>/dev/null; true' >/dev/null 2>&1; }
trap cleanup EXIT
nssh "$M" "sudo -n ip addr add $TMPIP/$PFX dev $EXT_NIC 2>/dev/null; sudo -n ip link set $EXT_NIC up; sudo -n ip route replace $CUST_CIDR via $EXT_GATEWAY dev $EXT_NIC"
sleep 2
expect "machine $M -> customer host through $EXT_NIC (ping)" ok "$(nssh "$M" "ping -c 3 -W 2 -I $TMPIP $CUST_HOST_IP >/dev/null 2>&1 && echo ok || echo fail")"
[ "${RES_STATUS[0]}" = PASS ] || { table; die "the customer host is not reachable through $EXT_NIC"; }
{ echo "date: $(date -u +%FT%TZ)"; echo "machine $M via $EXT_NIC ($TMPIP) -> $CUST_HOST_IP; flows: $BENCH_FLOWS; $R x ${D}s (iperf3 -O 2)"
  for c in $M $F; do echo "machine $c: $(nssh "$c" 'uname -r; nproc; iperf3 --version | head -1' | tr '\n' ' ')"; done; } > "$OUT/environment.txt"

sec "2. Runs"
cpu() { nssh "$1" "sleep 4; mpstat -P ALL 1 $((D-2)) | awk '/^Average/{ if (\$2==\"all\") { a=100-\$NF; so=\$8 } else if (\$2 ~ /^[0-9]+\$/) { u=100-\$NF; if (u>m) m=u } } END{printf \"%.1f %.1f %.1f\", a, m, so}'"; }
echo "flows rep Mbit/s retr m_avg m_core m_soft f_avg f_core f_soft" > "$OUT/runs.txt"
BAD=0
for FL in $BENCH_FLOWS; do
  for r in warm $(seq 1 "$R"); do
    nroot "$F" CUST_HOST_IP="$CUST_HOST_IP" <<<'pkill -f "iperf3 -s -B" 2>/dev/null; sleep 1; ip netns exec cust iperf3 -s -B "$CUST_HOST_IP" -p 5401 -D; sleep 1' >/dev/null 2>&1
    cpu "$M" > "$OUT/.cm" 2>/dev/null & P1=$!
    cpu "$F" > "$OUT/.cf" 2>/dev/null & P2=$!
    nssh "$M" "iperf3 -c $CUST_HOST_IP -B $TMPIP -p 5401 -P $FL -t $D -O 2 -f m" > "$OUT/raw-f$FL-r$r.txt" 2>&1
    wait $P1 $P2
    [ "$r" = warm ] && continue
    L=$(grep -E '(\[SUM\]|\[ *[0-9]+\]).*receiver' "$OUT/raw-f$FL-r$r.txt" | tail -1)
    MB=$(echo "$L" | grep -oE '[0-9.]+ Mbits/sec' | awk '{print $1}'); MB=${MB:-0}
    RT=$(grep -E '(\[SUM\]|\[ *[0-9]+\]).*sender' "$OUT/raw-f$FL-r$r.txt" | tail -1 | awk '{print $(NF-1)}'); RT=${RT:-0}
    LINE="$FL $r $MB $RT $(cat "$OUT/.cm") $(cat "$OUT/.cf")"; echo "$LINE" >> "$OUT/runs.txt"; echo "  $LINE"
    awk -v x="$MB" 'BEGIN{exit !(x+0>0)}' || BAD=$((BAD+1))
    sleep 2
  done
done
rm -f "$OUT/.cm" "$OUT/.cf"

sec "3. Summary"
awk 'NR>1{f=$1; n[f]++; v=$3; s[f]+=v; ss[f]+=v*v; for(i=5;i<=10;i++) c[f,i]+=$i; if(!(f in o)){o[f]=++k; fl[k]=f}}
     END{printf "%-6s %-11s %-8s %-7s %-7s %-7s %-7s %-7s %s\n","flows","mean Mbit/s","sd","M avg","M core","M soft","F avg","F core","F soft";
         for(j=1;j<=k;j++){f=fl[j]; m=s[f]/n[f]; v=(n[f]>1)?(ss[f]-n[f]*m*m)/(n[f]-1):0; if(v<0)v=0;
           printf "%-6s %-11.0f %-8.0f %-7.1f %-7.1f %-7.1f %-7.1f %-7.1f %.1f\n",f,m,sqrt(v),c[f,5]/n[f],c[f,6]/n[f],c[f,7]/n[f],c[f,8]/n[f],c[f,9]/n[f],c[f,10]/n[f]}}' "$OUT/runs.txt" | tee "$OUT/summary.txt"
expect "all runs carried traffic" 0 "$BAD"
table; RC=$?
echo "  results: $OUT"
exit $RC
