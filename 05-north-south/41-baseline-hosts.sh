#!/bin/bash
# 41-baseline-hosts.sh — reference measurement: plain TCP throughput between two cluster machines, without overlay or gateway.
#
# What it does : runs iperf3 from the machine(s) that run the benchmark clients (BENCH_CLIENT_NODES, default: the machines other
#                than FABRIC_NODE) to the host address of FABRIC_NODE, for every value of BENCH_FLOWS, BENCH_REPS repetitions of
#                BENCH_DURATION seconds, and records throughput, retransmissions and CPU (average and most loaded core) of both
#                machines. It tells how much the link between the machines can carry at most: if the gateway benchmark
#                (40-benchmark.sh) stops at a similar value, the limit is the link and not the gateway.
# Environment  : the cluster machines only (no Kubernetes objects are touched). The value is valid for THIS environment only.
# Changes      : starts and stops an iperf3 server on FABRIC_NODE (port 5301); installs sysstat and iperf3 if missing
# Usage        : ./41-baseline-hosts.sh [--yes]
# Variables    : BENCH_FLOWS, BENCH_REPS, BENCH_DURATION, BENCH_CLIENT_NODES, FABRIC_NODE, CLUSTER_NODES (from config.env)
# Duration     : about 4 minutes with the defaults
# Exit code    : 0 = completed; 1 = a run gave no traffic
# In the thesis: Chapter 6 (north-south throughput: reference value of the environment)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars BENCH_FLOWS BENCH_REPS BENCH_DURATION FABRIC_NODE CLUSTER_NODES

D=$BENCH_DURATION; R=$BENCH_REPS; PORT=5301
CLIENTM="${BENCH_CLIENT_NODES:-}"
if [ -z "$CLIENTM" ]; then for c in $CLUSTER_NODES; do [ "$c" = "$FABRIC_NODE" ] || CLIENTM="$CLIENTM $c"; done; CLIENTM="${CLIENTM# }"; fi
[ -n "$CLIENTM" ] || die "no client machine (need a machine other than FABRIC_NODE)"
set -- $CLIENTM; CM=$1
SIP="$(node_ip "$FABRIC_NODE")"; [ -n "$SIP" ] || die "cannot get the address of machine $FABRIC_NODE"
OUT="${BENCH_RESULTS_DIR:-$HERE/results}/benchmark/baseline-hosts-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"

sec "1. Reference measurement between machines"
echo "  client machine $CM -> server machine $FABRIC_NODE ($SIP), flows: $BENCH_FLOWS, $R x ${D}s"
echo "  results: $OUT"
confirm "This sends traffic between the two machines for a few minutes. Continue?"

for c in $CM $FABRIC_NODE; do
  nroot "$c" <<'EOS' >/dev/null 2>&1
command -v mpstat >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat >/dev/null 2>&1; }
command -v iperf3 >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null 2>&1; }
true
EOS
done
{ echo "date: $(date -u +%FT%TZ)"; echo "client machine $CM -> $FABRIC_NODE ($SIP); flows: $BENCH_FLOWS; repetitions: $R; duration ${D}s (iperf3 -O 2)"
  for c in $CM $FABRIC_NODE; do echo "machine $c: $(nssh "$c" 'uname -r; nproc; iperf3 --version | head -1; ip -o link show | cut -d: -f2- | cut -c1-60 | head -4' | tr '\n' ' ')"; done; } > "$OUT/environment.txt"

cpu_cmd() { echo "sleep 4; mpstat -P ALL 1 $((D-2)) | awk '/^Average/{ if (\$2==\"all\") a=100-\$NF; else if (\$2 ~ /^[0-9]+\$/) { u=100-\$NF; if (u>m) m=u } } END{printf \"%.1f %.1f\", a, m}'"; }

echo "flows rep total_Mbps retr client_avg client_maxcore server_avg server_maxcore" > "$OUT/runs.txt"
printf '  %-6s %-4s %-9s %-8s %-9s %-11s %-9s %s\n' flows rep Mbit/s retr "cli avg%" "cli core%" "srv avg%" "srv core%"
BAD=0
for F in $BENCH_FLOWS; do
  for r in warm $(seq 1 "$R"); do
    nroot "$FABRIC_NODE" PORT="$PORT" <<'EOS' >/dev/null 2>&1
pkill -x iperf3 2>/dev/null; sleep 1; iperf3 -s -p $PORT -D; sleep 1
EOS
    nssh "$FABRIC_NODE" "$(cpu_cmd)" > "$OUT/.cs" 2>/dev/null &  P1=$!
    nssh "$CM" "$(cpu_cmd)" > "$OUT/.cc" 2>/dev/null &            P2=$!
    nssh "$CM" "iperf3 -c $SIP -p $PORT -P $F -t $D -O 2 -f m" > "$OUT/raw-f$F-r$r.txt" 2>&1 </dev/null
    wait $P1 $P2 2>/dev/null
    [ "$r" = warm ] && continue
    set -- $(parse_raw "$OUT/raw-f$F-r$r.txt"); tot=$1; retr=$2
    read -r ca cm < "$OUT/.cc"; read -r sa sm < "$OUT/.cs"
    echo "$F $r $tot $retr ${ca:-0} ${cm:-0} ${sa:-0} ${sm:-0}" >> "$OUT/runs.txt"
    printf '  %-6s %-4s %-9s %-8s %-9s %-11s %-9s %s\n' "$F" "$r" "$tot" "$retr" "${ca:-0}" "${cm:-0}" "${sa:-0}" "${sm:-0}"
    awk -v x="$tot" 'BEGIN{exit !(x+0>0)}' || BAD=$((BAD+1))
    sleep 2
  done
done
nroot "$FABRIC_NODE" <<'EOS' >/dev/null 2>&1
pkill -x iperf3 2>/dev/null; true
EOS
rm -f "$OUT"/.cs "$OUT"/.cc

sec "2. Summary (mean, standard deviation, minimum, maximum over $R runs)"
awk 'NR>1{f=$1; n[f]++; v=$3; s[f]+=v; ss[f]+=v*v; if(!(f in mn)||v<mn[f])mn[f]=v; if(v>mx[f])mx[f]=v; r[f]+=$4; ca[f]+=$5; cm[f]+=$6; sa[f]+=$7; sm[f]+=$8; if(!(f in ord)){ord[f]=++k; fl[k]=f}}
     END{printf "%-6s %-5s %-11s %-8s %-6s %-9s %-9s %-10s %-9s %-10s %-9s %-10s\n","flows","runs","mean Mbit/s","sd","CV%","min","max","retr/run","cli avg%","cli core%","srv avg%","srv core%";
         for(j=1;j<=k;j++){f=fl[j]; mean=s[f]/n[f]; var=(n[f]>1)?(ss[f]-n[f]*mean*mean)/(n[f]-1):0; if(var<0)var=0; sd=sqrt(var);
           printf "%-6s %-5d %-11.0f %-8.0f %-6.1f %-9.0f %-9.0f %-10.0f %-9.1f %-10.1f %-9.1f %-10.1f\n",f,n[f],mean,sd,(mean?100*sd/mean:0),mn[f],mx[f],r[f]/n[f],ca[f]/n[f],cm[f]/n[f],sa[f]/n[f],sm[f]/n[f]}}' "$OUT/runs.txt" | tee "$OUT/summary.txt"
expect "all runs carried traffic" 0 "$BAD"
table; RC=$?
echo "  raw output, runs.txt, summary.txt and environment.txt: $OUT"
exit $RC
