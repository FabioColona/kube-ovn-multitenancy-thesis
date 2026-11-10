#!/bin/bash
# 40-benchmark.sh — measures the aggregate TCP throughput through a gateway (NAT Gateway or OVN Gateway) and its CPU cost.
#
# What it does : creates BENCH_CLIENT_PODS tenant pods spread over the cluster machines and iperf3 servers in the customer
#                namespace (one port per pod). For every value of BENCH_FLOWS (parallel streams per pod) it runs BENCH_REPS
#                repetitions of BENCH_DURATION seconds with ALL pods sending at the same time, and records for every run: the
#                aggregate rate seen by the senders (mean of the 1-second [SUM] intervals of iperf3 in the pods; iperf3 ends
#                there without its final summary, so a run covers 8-9 s), TCP retransmissions, the CPU use (mpstat) of the gateway machines and of the other
#                machines, and the share of the bytes sent on EXT_NIC by each gateway machine. Per run and per machine (cluster
#                machines and the fabric machine) it also writes machines-f<F>-r<r>.txt: mean CPU, busiest core, %soft, and the
#                bytes sent/received on EXT_NIC and on ovnext0 (namespace ovnext, ECMP+BFD only). NOTE: the bytes on EXT_NIC are
#                not the ECMP split: a flow whose next hop is another gateway machine leaves EXT_NIC twice (port machine ->
#                next hop -> fabric); the ovnext0 counters show the next hop that each machine serves.
#                Raw output of every run and a summary (mean, standard deviation, min, max per point) are written to the results folder.
#                Run it once per configuration with the SAME parameters:
#                  ./31-ovn-gateway.sh 1 nobfd  && ./40-benchmark.sh ovngw   (one OVN gateway node)
#                  ./39-remove-ovn-gateway.sh   && ./31-ovn-gateway.sh 2 bfd && ./40-benchmark.sh ovngw   (two nodes, ECMP)
#                  ./39-remove-ovn-gateway.sh   && ./30-nat-gateway.sh && ./40-benchmark.sh natgw        (NAT Gateway, one pod)
# Environment  : the cluster, the customer network and the gateway under test. Every number is valid for THIS environment only.
# Changes      : creates pods bench-0..bench-N in the tenant namespace (deleted at the end); starts iperf3 servers in the
#                namespace "cust"; installs sysstat and iperf3 on the machines if missing
# Requires     : the gateway configuration under test is up and a tenant pod reaches the customer host
# Usage        : ./40-benchmark.sh <ovngw|natgw> [--yes]
# Variables    : BENCH_*, NS_OVNGW, NS_NAT, NAT_GW, PROBE_IMAGE, CUST_HOST_IP, EXT_NIC, CLUSTER_NODES, GATEWAY_NODES (from config.env)
# Duration     : about 10 minutes with the defaults (4 flow values x (1 warm-up + 5 repetitions) x 14 s, plus the pauses)
# Exit code    : 0 = all runs completed; 1 = a run gave no traffic; 2 = prerequisite missing
# Columns      : "gw core%" in runs.txt/summary.txt is the busiest core over ALL the gateway machines (see machines-*.txt for
#                the value of each machine)
# In the thesis: Chapter 6 (north-south throughput and scalability)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars BENCH_CLIENT_PODS BENCH_FLOWS BENCH_REPS BENCH_DURATION NS_OVNGW NS_NAT NAT_GW PROBE_IMAGE CUST_HOST_IP EXT_NIC

ARM="${ARGS[0]:-}"
case "$ARM" in
  ovngw) NS="$NS_OVNGW" ;;
  natgw) NS="$NS_NAT" ;;
  *) die "usage: ./40-benchmark.sh <ovngw|natgw>" ;;
esac
P=$BENCH_CLIENT_PODS; D=$BENCH_DURATION; R=$BENCH_REPS
[ "$D" -ge 6 ] || die "BENCH_DURATION must be at least 6 seconds (the CPU window starts after the omitted seconds)"
for c in $CLUSTER_NODES; do eval "HN_$c=\"\$(nssh $c hostname | tr -d '\r')\""; done
hn() { eval "echo \$HN_$1"; }
machine_of() { local c; for c in $CLUSTER_NODES; do [ "$(hn "$c")" = "$1" ] && { echo "$c"; return; }; done; }

sec "1. Gateway under test"
rk "$SERVER" "kubectl get ns $NS" >/dev/null 2>&1 || die "the namespace $NS does not exist: configure the gateway first (31-ovn-gateway.sh or 30-nat-gateway.sh)"
GWM=""
if [ "$ARM" = ovngw ]; then
  for h in $(rk "$SERVER" "kubectl get ovn-eip -o jsonpath='{range .items[?(@.spec.type==\"lsp\")]}{.metadata.name}{\"\\n\"}{end}'"); do GWM="$GWM $(machine_of "$h")"; done
  BFDS="$(rk "$SERVER" "kubectl get vpc $OVNGW_VPC -o jsonpath='{.status.enableBfd}'" 2>/dev/null)"
  NGW=0; for g in $GWM; do NGW=$((NGW+1)); done
  [ "$NGW" -ge 1 ] || die "no OVN Gateway node found (no OvnEip of type lsp)"
  ECMPS="$(rk "$SERVER" "kubectl get subnet $OVNGW_SUBNET -o jsonpath='{.spec.enableEcmp}'" 2>/dev/null | tr -d '\r')"
  if [ "$BFDS" = true ] && [ "$ECMPS" = true ]; then TAG="ovngw-n$NGW-ecmp-bfd"; elif [ "$BFDS" = true ]; then TAG="ovngw-n$NGW-noecmp-bfd"; else TAG="ovngw-n$NGW-nobfd"; fi
else
  H="$(rk "$SERVER" "kubectl -n kube-system get pod vpc-nat-gw-$NAT_GW-0 -o jsonpath='{.spec.nodeName}'" 2>/dev/null | tr -d '\r')"
  [ -n "$H" ] || die "the NAT Gateway pod vpc-nat-gw-$NAT_GW-0 does not exist: run ./30-nat-gateway.sh first"
  GWM="$(machine_of "$H")"; NGW=1; TAG="natgw-pod"
fi
GWM="${GWM# }"
OTHERS=""; for c in $CLUSTER_NODES; do in_list "$c" "$GWM" || OTHERS="$OTHERS $c"; done; OTHERS="${OTHERS# }"
# Client pods run on the machines that do NOT host the customer network, so that every flow crosses the overlay and the gateway.
# (A pod on the machine that hosts both the gateway and the customer is delivered locally, without Geneve: ~15x faster, not comparable.)
CLIENTM="${BENCH_CLIENT_NODES:-}"
if [ -z "$CLIENTM" ]; then for c in $CLUSTER_NODES; do [ "$c" = "$FABRIC_NODE" ] || CLIENTM="$CLIENTM $c"; done; CLIENTM="${CLIENTM# }"; fi
[ -n "$CLIENTM" ] || CLIENTM="$CLUSTER_NODES"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BENCH_RESULTS_DIR:-$HERE/results}/benchmark/$TAG-$STAMP"
mkdir -p "$OUT"
echo "  arm $ARM ($TAG); gateway machine(s): $GWM; other machines: ${OTHERS:--}; client pods $P; flows: $BENCH_FLOWS; $R x ${D}s"
echo "  results: $OUT"
confirm "This starts $P tenant pods and sends traffic for several minutes. Continue?"

sec "2. Tools and customer servers"
for c in $CLUSTER_NODES $FABRIC_NODE; do
  nroot "$c" <<'EOS' >/dev/null 2>&1
command -v mpstat >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat >/dev/null 2>&1; }
command -v iperf3 >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null 2>&1; }
true
EOS
done
nroot "$FABRIC_NODE" CUST_HOST_IP="$CUST_HOST_IP" P="$P" <<'EOS'
pkill -x iperf3 2>/dev/null; sleep 1
for i in $(seq 0 $((P-1))); do ip netns exec cust iperf3 -s -B "$CUST_HOST_IP" -p $((5201+i)) -D; done
sleep 1; ip netns exec cust ss -ltn | grep -cE ":52[0-9][0-9] "
EOS
info "iperf3 servers on ports 5201..$((5200+P)) in the customer namespace"

sec "3. Client pods"
rk "$SERVER" "kubectl -n $NS delete pod -l app=bench --ignore-not-found --wait=true --timeout=60s" >/dev/null 2>&1
k=0
for i in $(seq 0 $((P-1))); do
  c=$(set -- $CLIENTM; eval "echo \${$((i % $# + 1))}")
  kapply <<Y >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: bench-$i, namespace: $NS, labels: {app: bench}}
spec:
  nodeName: $(hn "$c")
  containers:
  - name: c
    image: "$PROBE_IMAGE"
    command: ["sleep", "7200"]
Y
done
run_spin "waiting for the client pods" "up to 4 minutes" rk "$SERVER" "kubectl -n $NS wait --for=condition=Ready pod -l app=bench --timeout=240s" || { tail -5 "$RUN_LOG"; die "the client pods are not Ready"; }
for i in $(seq 0 $((P-1))); do echo "  bench-$i: $(rk "$SERVER" "kubectl -n $NS get pod bench-$i -o jsonpath='{.spec.nodeName} {.status.podIP}'")"; done
expect "tenant pod -> customer host (ping)" ok "$(rk "$SERVER" "kubectl -n $NS exec bench-0 -- ping -c 2 -W 2 $CUST_HOST_IP >/dev/null 2>&1 && echo ok || echo fail")"
[ "${RES_STATUS[0]}" = PASS ] || { table; die "the tenant does not reach the customer host"; }
PM="$(rk "$SERVER" "kubectl -n $NS exec bench-0 -- cat /sys/class/net/eth0/mtu" | tr -d '\r')"

{ echo "date: $(date -u +%FT%TZ)"; echo "arm: $ARM  tag: $TAG"; echo "gateway machines: $GWM  others: $OTHERS  client pods on machines: $CLIENTM  customer network on machine: $FABRIC_NODE"
  echo "client pods: $P  flows: $BENCH_FLOWS  repetitions: $R  duration: ${D}s (iperf3 -O 2)  pod MTU: $PM"
  for c in $CLUSTER_NODES; do echo "machine $c ($(hn "$c")): $(nssh "$c" 'uname -r; nproc; free -m | awk "/Mem:/{print \$2\" MB\"}"; iperf3 --version | head -1' | tr '\n' ' ')"; done
  rk "$SERVER" "kubectl -n kube-system get deploy kube-ovn-controller -o jsonpath='{.spec.template.spec.containers[0].image}'"; echo
} > "$OUT/environment.txt"

# The iperf3 server serves one client at a time and stays stuck when a client aborts (see below): restart them before every run.
start_servers() {
  nroot "$FABRIC_NODE" CUST_HOST_IP="$CUST_HOST_IP" P="$P" <<'EOS' >/dev/null 2>&1
pkill -x iperf3 2>/dev/null; sleep 1
for i in $(seq 0 $((P-1))); do ip netns exec cust iperf3 -s -B "$CUST_HOST_IP" -p $((5201+i)) -D; done
sleep 1
EOS
}

# counters <machine>: "ext_tx ext_rx ovnext_tx ovnext_rx" (0 when the interface does not exist)
counters() { nroot "$1" EXT_NIC="$EXT_NIC" <<'EOS' 2>/dev/null | tail -1
c() { cat "$1" 2>/dev/null || echo 0; }
o() { ip netns exec ovnext cat "/sys/class/net/ovnext0/statistics/$1" 2>/dev/null || echo 0; }
echo "$(c /sys/class/net/$EXT_NIC/statistics/tx_bytes) $(c /sys/class/net/$EXT_NIC/statistics/rx_bytes) $(o tx_bytes) $(o rx_bytes)"
EOS
}
# --- one run: all pods send at the same time; echoes "total_Mbps retr cpu_gw cpu_other shares"
one_run() {   # one_run <flows> <rep>
  local F=$1 r=$2 c g before="" after="" pids="" cg=0 co=0 cgm=0 com=0 ng=0 no=0 tot=0 retr=0 line n va vm
  start_servers
  for g in $GWM; do before="$before $(nssh "$g" "cat /sys/class/net/$EXT_NIC/statistics/tx_bytes")"; done
  for c in $CLUSTER_NODES $FABRIC_NODE; do counters "$c" > "$OUT/.cnt0-$c"; done
  for c in $CLUSTER_NODES $FABRIC_NODE; do
    nssh "$c" "sleep 4; mpstat -P ALL 1 $((D-2)) | awk '/^Average/{ if (\$2==\"all\") { a=100-\$NF; so=\$8 } else if (\$2 ~ /^[0-9]+\$/) { u=100-\$NF; if (u>m) m=u } } END{printf \"%.1f %.1f %.1f\", a, m, so}'" > "$OUT/.cpu-$c" 2>/dev/null &
    pids="$pids $!"
  done
  rks "$SERVER" > "$OUT/raw-f$F-r$r.txt" 2>&1 <<EOS
for i in \$(seq 0 $((P-1))); do
  kubectl -n $NS exec bench-\$i -- iperf3 -c $CUST_HOST_IP -p \$((5201+i)) -P $F -t $D -O 2 -f m > /tmp/bench-\$i.txt 2>&1 </dev/null &
done
wait
for i in \$(seq 0 $((P-1))); do
  echo "=== bench-\$i"; cat /tmp/bench-\$i.txt
done
EOS
  wait $pids 2>/dev/null
  for g in $GWM; do after="$after $(nssh "$g" "cat /sys/class/net/$EXT_NIC/statistics/tx_bytes")"; done
  { echo "machine cpu_avg busiest_core soft ext_tx_MB ext_rx_MB ovnext_tx_MB ovnext_rx_MB gateway"
    for c in $CLUSTER_NODES $FABRIC_NODE; do
      set -- $(cat "$OUT/.cnt0-$c") ; b1=${1:-0} b2=${2:-0} b3=${3:-0} b4=${4:-0}
      set -- $(counters "$c"); a1=${1:-0} a2=${2:-0} a3=${3:-0} a4=${4:-0}
      read -r xa xm xs < "$OUT/.cpu-$c" 2>/dev/null
      awk -v m="$c" -v xa="${xa:-0}" -v xm="${xm:-0}" -v xs="${xs:-0}" -v d1=$((a1-b1)) -v d2=$((a2-b2)) -v d3=$((a3-b3)) -v d4=$((a4-b4)) -v g="$(in_list "$c" "$GWM" && echo yes || echo no)" \
        'BEGIN{printf "%s %s %s %s %.0f %.0f %.0f %.0f %s\n", m, xa, xm, xs, d1/1e6, d2/1e6, d3/1e6, d4/1e6, g}'
    done; } > "$OUT/machines-f$F-r$r.txt"
  set -- $(parse_raw "$OUT/raw-f$F-r$r.txt"); tot=$1; retr=$2
  for c in $CLUSTER_NODES; do
    read -r va vm _ < "$OUT/.cpu-$c" 2>/dev/null; va=${va:-0}; vm=${vm:-0}
    if in_list "$c" "$GWM"; then cg=$(awk -v a="$cg" -v b="$va" 'BEGIN{print a+b}'); cgm=$(awk -v a="$cgm" -v b="$vm" 'BEGIN{print (b>a)?b:a}'); ng=$((ng+1))
    else co=$(awk -v a="$co" -v b="$va" 'BEGIN{print a+b}'); com=$(awk -v a="$com" -v b="$vm" 'BEGIN{print (b>a)?b:a}'); no=$((no+1)); fi
  done
  cg=$(awk -v a="$cg" -v n="$ng" 'BEGIN{printf "%.1f", (n?a/n:0)}'); co=$(awk -v a="$co" -v n="$no" 'BEGIN{printf "%.1f", (n?a/n:0)}')
  line=$(awk -v b="$before" -v a="$after" 'BEGIN{n=split(b,B," "); split(a,A," "); t=0; for(i=1;i<=n;i++){d[i]=A[i]-B[i]; t+=d[i]}; s=""; for(i=1;i<=n;i++){s=s (i>1?",":"") sprintf("%.0f",(t?100*d[i]/t:0))}; print s}')
  echo "$F $r $tot $retr $cg $cgm $co $com $line"
}

sec "4. Runs"
echo "flows rep total_Mbps retr cpu_gw_avg cpu_gw_maxcore cpu_other_avg cpu_other_maxcore tx_share_per_gateway_pct" > "$OUT/runs.txt"
printf '  %-6s %-4s %-9s %-8s %-8s %-9s %-8s %-9s %s\n' flows rep Mbit/s retr "gw avg%" "gw core%" "oth avg%" "oth core%" "tx share per gw (%)"
BAD=0
# machine that hosts the router port of the VPC (the active chassis for the SNAT): the path of the traffic depends on it
crm() {
  [ "$ARM" = ovngw ] || { echo "-"; return; }
  local C H
  C="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external" 2>/dev/null | tr -d '\r\n ')"
  [ -n "$C" ] || { echo "none"; return; }
  H="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=hostname list chassis $C" 2>/dev/null | tr -d '\r\n ')"
  echo "$(machine_of "$H")"
}
echo "router port machine at start: $(crm)  (client pods on machines: ${BENCH_CLIENT_NODES:-default})" | tee -a "$OUT/environment.txt"
for F in $BENCH_FLOWS; do
  echo "  [flows $F] router port on machine $(crm)" | tee -a "$OUT/environment.txt"
  # one warm-up run (not recorded) so that the first point does not pay for ARP, conntrack and cache filling
  one_run "$F" warm >/dev/null
  for r in $(seq 1 "$R"); do
    L="$(one_run "$F" "$r")"; echo "$L" >> "$OUT/runs.txt"
    set -- $L; printf '  %-6s %-4s %-9s %-8s %-8s %-9s %-8s %-9s %s\n' "${1:-}" "${2:-}" "${3:-0}" "${4:-0}" "${5:-0}" "${6:-0}" "${7:-0}" "${8:-0}" "${9:-}"
    awk -v x="$3" 'BEGIN{exit !(x+0>0)}' || BAD=$((BAD+1))
    sleep 3
  done
done

sec "5. Summary (mean, standard deviation, minimum, maximum over $R runs)"
awk 'NR>1{f=$1; n[f]++; v=$3; s[f]+=v; ss[f]+=v*v; if(!(f in mn)||v<mn[f])mn[f]=v; if(v>mx[f])mx[f]=v; r[f]+=$4; cg[f]+=$5; cgm[f]+=$6; co[f]+=$7; com[f]+=$8
      m=split($9,a,","); for(i=1;i<=m;i++){sh[f,i]+=a[i]}; mm=m; if(!(f in ord)){ord[f]=++k; fl[k]=f}}
     END{printf "%-6s %-5s %-11s %-8s %-6s %-9s %-9s %-8s %-8s %-9s %-9s %s\n","flows","runs","mean Mbit/s","sd","CV%","min","max","gw avg%","gw core%","oth avg%","oth core%","mean tx share per gateway (%)";
         for(j=1;j<=k;j++){f=fl[j]; mean=s[f]/n[f]; var=(n[f]>1)?(ss[f]-n[f]*mean*mean)/(n[f]-1):0; if(var<0)var=0; sd=sqrt(var);
           str=""; for(i=1;i<=mm;i++){str=str (i>1?",":"") sprintf("%.0f",sh[f,i]/n[f])}
           printf "%-6s %-5d %-11.0f %-8.0f %-6.1f %-9.0f %-9.0f %-8.1f %-8.1f %-9.1f %-9.1f %s\n",f,n[f],mean,sd,(mean?100*sd/mean:0),mn[f],mx[f],cg[f]/n[f],cgm[f]/n[f],co[f]/n[f],com[f]/n[f],str}}' "$OUT/runs.txt" | tee "$OUT/summary.txt"

rk "$SERVER" "kubectl -n $NS delete pod -l app=bench --ignore-not-found --wait=false" >/dev/null 2>&1
rm -f "$OUT"/.cpu-* "$OUT"/.cnt0-* 2>/dev/null
sec "6. Per machine (mean over the $R runs of each flow value)"
for F in $BENCH_FLOWS; do
  cat "$OUT"/machines-f$F-r[0-9]*.txt 2>/dev/null | awk -v f="$F" '$1!="machine"{k=$1; n[k]++; for(i=2;i<=8;i++) s[k,i]+=$i; g[k]=$9}
    END{for(k in n) printf "%-6s %-8s %-8.1f %-8.1f %-8.1f %-10.0f %-10.0f %-10.0f %-10.0f %s\n", f, k, s[k,2]/n[k], s[k,3]/n[k], s[k,4]/n[k], s[k,5]/n[k], s[k,6]/n[k], s[k,7]/n[k], s[k,8]/n[k], g[k]}' | sort -k2n
done | { echo "flows  machine cpu_avg  busiest  soft     ext_tx_MB  ext_rx_MB  ovnext_tx  ovnext_rx  gateway"; cat; } | tee "$OUT/machines-summary.txt"
expect "all runs carried traffic" 0 "$BAD"
table; RC=$?
echo "  raw output, runs.txt, summary.txt, machines-*.txt and environment.txt: $OUT"
exit $RC
