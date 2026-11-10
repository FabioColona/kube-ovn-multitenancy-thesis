#!/bin/bash
# 42-baseline-overlay.sh — reference measurement: pod-to-pod TCP throughput across the two machines, over the Geneve overlay,
# WITHOUT any gateway.
#
# What it does : creates a namespace in the default Kube-OVN subnet, one server pod on FABRIC_NODE (or on the last cluster machine when FABRIC_NODE is outside the cluster) (iperf3 servers on
#                BENCH_CLIENT_PODS ports) and BENCH_CLIENT_PODS client pods on the client machines, then runs the same flows /
#                repetitions / duration as 40-benchmark.sh and records throughput, retransmissions and CPU (average and most
#                loaded core) of both machines. Compared with 41 (host to host) it adds the overlay; compared with 40 it lacks the
#                gateway: the three together tell where the limit is (link, overlay or gateway).
# Environment  : the Kube-OVN cluster only. The value is valid for THIS environment only (pod MTU is reported).
# Changes      : creates the namespace "ovl-test" and its pods (deleted at the end)
# Usage        : ./42-baseline-overlay.sh [--yes]
# Variables    : BENCH_*, PROBE_IMAGE, FABRIC_NODE, CLUSTER_NODES (from config.env)
# Duration     : about 7 minutes with the defaults
# Exit code    : 0 = completed; 1 = a run gave no traffic; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south throughput: where the limit is)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars BENCH_CLIENT_PODS BENCH_FLOWS BENCH_REPS BENCH_DURATION PROBE_IMAGE FABRIC_NODE CLUSTER_NODES

NS=ovl-test; P=$BENCH_CLIENT_PODS; D=$BENCH_DURATION; R=$BENCH_REPS
for c in $CLUSTER_NODES; do eval "HN_$c=\"\$(nssh $c hostname | tr -d '\r')\""; done
hn() { eval "echo \$HN_$1"; }
# Machine of the server pod: FABRIC_NODE when it is a cluster machine; when the customer host is outside the cluster, the last
# cluster machine (the pods of the clients go on the other ones, so that every flow crosses the overlay)
SRVM="$FABRIC_NODE"; case " $CLUSTER_NODES " in *" $FABRIC_NODE "*) ;; *) SRVM="${CLUSTER_NODES##* }" ;; esac
CLIENTM="${BENCH_CLIENT_NODES:-}"
if [ -z "$CLIENTM" ]; then for c in $CLUSTER_NODES; do [ "$c" = "$SRVM" ] || CLIENTM="$CLIENTM $c"; done; CLIENTM="${CLIENTM# }"; fi
[ -n "$CLIENTM" ] || die "no client machine (need a machine other than the server machine $SRVM)"
PORTS=""; for i in $(seq 0 $((P-1))); do PORTS="$PORTS $((5201+i))"; done
OUT="${BENCH_RESULTS_DIR:-$HERE/results}/benchmark/baseline-overlay-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"

sec "1. Reference measurement pod to pod (overlay, no gateway)"
echo "  server pod on machine $SRVM, $P client pods on machine(s) $CLIENTM; flows: $BENCH_FLOWS; $R x ${D}s"
echo "  results: $OUT"
confirm "This creates pods in the namespace $NS and sends traffic for several minutes. Continue?"
cleanup() { rk "$SERVER" "kubectl delete ns $NS --ignore-not-found --wait=false" >/dev/null 2>&1; }
trap cleanup EXIT

sec "2. Tools and pods"
for c in $CLUSTER_NODES; do
  nroot "$c" <<'EOS' >/dev/null 2>&1
command -v mpstat >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat >/dev/null 2>&1; }
true
EOS
done
rk "$SERVER" "kubectl delete ns $NS --ignore-not-found --wait=true --timeout=90s" >/dev/null 2>&1
rk "$SERVER" "kubectl create ns $NS" >/dev/null || die "cannot create the namespace $NS"
kapply <<Y >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ovl-srv, namespace: $NS, labels: {app: ovl}}
spec:
  nodeName: $(hn "$SRVM")
  containers:
  - name: c
    image: "$PROBE_IMAGE"
    command: ["sleep", "7200"]
Y
for i in $(seq 0 $((P-1))); do
  c=$(set -- $CLIENTM; eval "echo \${$((i % $# + 1))}")
  kapply <<Y >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ovl-c$i, namespace: $NS, labels: {app: ovl}}
spec:
  nodeName: $(hn "$c")
  containers:
  - name: c
    image: "$PROBE_IMAGE"
    command: ["sleep", "7200"]
Y
done
run_spin "waiting for the pods" "up to 4 minutes" rk "$SERVER" "kubectl -n $NS wait --for=condition=Ready pod -l app=ovl --timeout=240s" || { tail -5 "$RUN_LOG"; die "the pods are not Ready"; }
SIP="$(rk "$SERVER" "kubectl -n $NS get pod ovl-srv -o jsonpath='{.status.podIP}'" | tr -d '\r')"
PM="$(rk "$SERVER" "kubectl -n $NS exec ovl-srv -- cat /sys/class/net/eth0/mtu" | tr -d '\r')"
echo "  server pod ovl-srv $SIP, pod MTU $PM"
expect "client pod -> server pod (ping)" ok "$(rk "$SERVER" "kubectl -n $NS exec ovl-c0 -- ping -c 2 -W 2 $SIP >/dev/null 2>&1 && echo ok || echo fail")"
[ "${RES_STATUS[0]}" = PASS ] || { table; die "client and server pods do not reach each other"; }
{ echo "date: $(date -u +%FT%TZ)"; echo "pod to pod over the overlay, no gateway; server on machine $SRVM, clients on $CLIENTM; pods: $P; flows: $BENCH_FLOWS; repetitions: $R; duration ${D}s (iperf3 -O 2); pod MTU: $PM"
  rk "$SERVER" "kubectl -n kube-system get deploy kube-ovn-controller -o jsonpath='{.spec.template.spec.containers[0].image}'"; echo; } > "$OUT/environment.txt"

cpu_cmd() { echo "sleep 4; mpstat -P ALL 1 $((D-2)) | awk '/^Average/{ if (\$2==\"all\") a=100-\$NF; else if (\$2 ~ /^[0-9]+\$/) { u=100-\$NF; if (u>m) m=u } } END{printf \"%.1f %.1f\", a, m}'"; }

one_run() {   # one_run <flows> <rep>: echoes "flows rep total_Mbps retr cli_avg cli_core srv_avg srv_core"
  local F=$1 r=$2 pids="" ca cm sa sm
  rk "$SERVER" "kubectl -n $NS exec ovl-srv -- sh -c 'pkill -x iperf3 2>/dev/null; sleep 1; for p in $PORTS; do iperf3 -s -p \$p -D; done; sleep 1'" >/dev/null 2>&1
  nssh "$SRVM" "$(cpu_cmd)" > "$OUT/.cs" 2>/dev/null & pids="$!"
  c0=$(set -- $CLIENTM; echo $1)
  nssh "$c0" "$(cpu_cmd)" > "$OUT/.cc" 2>/dev/null & pids="$pids $!"
  rks "$SERVER" > "$OUT/raw-f$F-r$r.txt" 2>&1 <<EOS
for i in \$(seq 0 $((P-1))); do
  kubectl -n $NS exec ovl-c\$i -- iperf3 -c $SIP -p \$((5201+i)) -P $F -t $D -O 2 -f m > /tmp/ovl-\$i.txt 2>&1 </dev/null &
done
wait
for i in \$(seq 0 $((P-1))); do echo "=== bench-\$i"; cat /tmp/ovl-\$i.txt; done
EOS
  wait $pids 2>/dev/null
  set -- $(parse_raw "$OUT/raw-f$F-r$r.txt")
  read -r ca cm < "$OUT/.cc"; read -r sa sm < "$OUT/.cs"
  echo "$F $r $1 $2 ${ca:-0} ${cm:-0} ${sa:-0} ${sm:-0}"
}

sec "3. Runs"
echo "flows rep total_Mbps retr client_avg client_maxcore server_avg server_maxcore" > "$OUT/runs.txt"
printf '  %-6s %-4s %-9s %-8s %-9s %-10s %-9s %s\n' flows rep Mbit/s retr "cli avg%" "cli core%" "srv avg%" "srv core%"
BAD=0
for F in $BENCH_FLOWS; do
  one_run "$F" warm >/dev/null
  for r in $(seq 1 "$R"); do
    L="$(one_run "$F" "$r")"; echo "$L" >> "$OUT/runs.txt"
    set -- $L; printf '  %-6s %-4s %-9s %-8s %-9s %-10s %-9s %s\n' "${1:-}" "${2:-}" "${3:-0}" "${4:-0}" "${5:-0}" "${6:-0}" "${7:-0}" "${8:-0}"
    awk -v x="${3:-0}" 'BEGIN{exit !(x+0>0)}' || BAD=$((BAD+1))
    sleep 3
  done
done
rm -f "$OUT"/.cs "$OUT"/.cc

sec "4. Summary (mean, standard deviation, minimum, maximum over $R runs)"
awk 'NR>1{f=$1; n[f]++; v=$3; s[f]+=v; ss[f]+=v*v; if(!(f in mn)||v<mn[f])mn[f]=v; if(v>mx[f])mx[f]=v; r[f]+=$4; ca[f]+=$5; cm[f]+=$6; sa[f]+=$7; sm[f]+=$8; if(!(f in ord)){ord[f]=++k; fl[k]=f}}
     END{printf "%-6s %-5s %-11s %-8s %-6s %-9s %-9s %-10s %-9s %-10s %-9s %-10s\n","flows","runs","mean Mbit/s","sd","CV%","min","max","retr/run","cli avg%","cli core%","srv avg%","srv core%";
         for(j=1;j<=k;j++){f=fl[j]; mean=s[f]/n[f]; var=(n[f]>1)?(ss[f]-n[f]*mean*mean)/(n[f]-1):0; if(var<0)var=0; sd=sqrt(var);
           printf "%-6s %-5d %-11.0f %-8.0f %-6.1f %-9.0f %-9.0f %-10.0f %-9.1f %-10.1f %-9.1f %-10.1f\n",f,n[f],mean,sd,(mean?100*sd/mean:0),mn[f],mx[f],r[f]/n[f],ca[f]/n[f],cm[f]/n[f],sa[f]/n[f],sm[f]/n[f]}}' "$OUT/runs.txt" | tee "$OUT/summary.txt"
expect "all runs carried traffic" 0 "$BAD"
table; RC=$?
echo "  raw output, runs.txt, summary.txt and environment.txt: $OUT"
exit $RC
