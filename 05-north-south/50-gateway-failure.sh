#!/bin/bash
# 50-gateway-failure.sh — measures how long tenant traffic is interrupted when a gateway fails, and when it is restored.
#
# What it does : starts FAIL_PODS tenant pods that ping the customer host every FAIL_INTERVAL seconds (with timestamps). In
#                every repetition it lets traffic run for FAIL_PHASE seconds, injects a failure, keeps it for FAIL_PHASE seconds,
#                restores it, and watches FAIL_PHASE more seconds. From the timestamps of the replies it computes, for every pod,
#                the longest interruption while the failure is on ("failover") and after restoring ("restore"), and how many
#                pods were affected (the gateway of a pod depends on the hash of its address, so not all pods are affected).
#                Failures:
#                  ovngw nic   : EXT_NIC of one gateway machine goes down (upstream link lost, the node itself is alive)
#                  ovngw node  : Geneve (UDP 6081) is dropped in and out on one gateway machine (the node disappears from the overlay;
#                                its EXT_NIC stays up, so its BFD session and its ECMP next hop stay up: a PARTIAL failure)
#                  ovngw full  : node + EXT_NIC down: the machine loses the overlay AND the external segment, but stays powered on
#                                (its BFD session goes down, as with a real failure of the node's network)
#                  ovngw crash : the gateway machine is rebooted abruptly (sysrq "b": no shutdown, no sync; the kernel and every
#                                process disappear, as in a power loss). Only a machine that is neither the K3s server nor the
#                                fabric machine can be crashed. The machine comes back by itself, but the objects that are not
#                                persistent (ext0, ovnext, NIC prefix) are gone: run ./52-recover-gateway-machine.sh <n> afterwards.
#                                Needs FAIL_PHASE >= 60, and FAIL_REPS=1 unless the machine has the boot service of
#                                ./62-persist-gateway-machine.sh (then the machine comes back by itself and FAIL_REPS can be > 1).
#                                The end of the failure (T2) is the moment the machine answers ssh again.
#                  ovngw poweroff : the gateway machine is shut down for real (sudo poweroff, a clean shutdown) and stays off for
#                                FAIL_PHASE seconds. Then the script asks you to power the machine on (CrownLabs dashboard; if the
#                                platform restarts it by itself, nothing to do), waits up to POWER_ON_TIMEOUT s (default 600) for ssh,
#                                runs ./52-recover-gateway-machine.sh on it, lets the traffic run FAIL_PHASE more seconds and stops.
#                                Same machine restrictions as crash. The "restore" figure of this mode includes your power-on, the boot
#                                and the recovery: it is not comparable with the other modes (the times are in poweroff-r<n>.txt).
#                  natgw pod   : the gateway pod is deleted (Kubernetes recreates it)
#                  natgw node  : Geneve is dropped on the machine that hosts the gateway pod
#                  natgw poweroff : the machine that hosts the gateway pod is shut down for real (as ovngw poweroff)
#                Which OVN gateway fails: "active" = the machine that hosts the chassis-redirect port of the VPC router
#                (cr-<OVNGW_VPC>-external, where the SNAT is done), "other" = another gateway machine.
#                Run it for each configuration, with the same parameters:
#                  ./31-ovn-gateway.sh 2 bfd   && ./50-gateway-failure.sh ovngw node active|other   (ECMP + BFD)
#                  ./31-ovn-gateway.sh 2 nobfd && ./50-gateway-failure.sh ovngw node active|other   (no BFD: OVN chassis failover only)
#                  ./30-nat-gateway.sh         && ./50-gateway-failure.sh natgw pod                 (NAT Gateway pod deleted)
# Environment  : the cluster, the customer network and the gateway under test. Every number is valid for THIS environment only.
# Changes      : creates pods fail-0.. in the tenant namespace (deleted at the end); injects and ALWAYS removes the failure
#                (also if interrupted: a trap restores the link / the firewall rule)
# Requires     : the gateway configuration under test is up and a tenant pod reaches the customer host
# Usage        : ./50-gateway-failure.sh <ovngw|natgw> [nic|node|full|crash|poweroff|pod] [active|other] [--yes]
#                COLLECT=1 ./50-gateway-failure.sh ovngw node other   (also saves timeline and OVN logs of repetition 1)
# Settled state : before every repetition (ovngw) the script waits until the gateway is settled, at most SETTLE_MAX s (default 300):
#                  SETTLE=stable (default) : every BFD session towards a gateway node is up AND the chassis priorities and the
#                                            machine of the router port do not change for SETTLE_QUIET s (default 30)
#                  SETTLE=equal            : the old criterion (BFD up and all the chassis priorities equal), kept for comparison
# Machine to fail: with nic and node the machine is chosen again at every repetition from where the router port is at that moment
#                (role active = the machine with the port, role other = another gateway machine); if it changes, the tenant pods
#                are recreated away from it. Only VALID repetitions (measurement window covered) enter the summary.
# Analysis     : for every pod, every gap between two replies longer than 0.5 s after removing the ping interval; the last gap
#                of a pod is measured up to the end of ITS OWN pings (marker written in the pod), and a gap with no reply until
#                that end is "open" (the pod did not come back: its length is a lower bound). Per repetition: longest gap during
#                the failure and after the restore, number of pods with more than one gap, pods with an open gap, the events
#                (events-r<n>.txt: pod, start of the gap from T1, length, open).
# UDP=1        : during the same repetitions every pod ALSO sends one numbered UDP datagram every FAIL_INTERVAL s to the
#                customer host (port UDP_PORT, default 9999; one way, no reply, no connection). A receiver in namespace cust
#                of the fabric machine records the arrival time of each datagram. The UDP stream is analysed like the pings
#                (gaps between arrivals, last gap up to the end of the pod's sender, open gap = lower bound): files
#                udp-raw-r<n>.txt, udp-pods-r<n>.txt, udp-events-r<n>.txt, udp-runs.txt; datagrams sent/received per pod in
#                udp-count-r<n>.txt. Not with poweroff.
# Variables    : PROBE_CMD/PROBE_AT (a command run during the failure, e.g. ./64-bfd-probe.sh), RESET_PRIO=1 (ovngw+BFD: before every repetition the gateway chassis priorities are set back to the values
#                read after the configuration, so that every repetition starts from the same state), NAT_NEIGH_FLUSH=1 (natgw pod:
#                as soon as the EIP of the new pod is ready, the neighbour entry of the EIP is deleted on the customer side),
#                SETTLE, SETTLE_MAX, SETTLE_QUIET, COLLECT (timeline of every repetition), POWER_ON_TIMEOUT (poweroff, default 600), FAIL_*, NS_OVNGW, NS_NAT, NAT_GW, PROBE_IMAGE, CUST_HOST_IP, EXT_NIC (from config.env)
# Duration     : about 5 minutes with the defaults (5 repetitions x about 50 s)
# Exit code    : 0 = completed and the traffic came back after every repetition; 1 = it did not; 2 = prerequisite missing
# In the thesis: Chapter 6 (north-south, gateway failure)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars OVNGW_VPC FAIL_REPS FAIL_PODS FAIL_INTERVAL FAIL_PHASE NS_OVNGW NS_NAT NAT_GW PROBE_IMAGE CUST_HOST_IP EXT_NIC

ARM="${ARGS[0]:-}"; MODE="${ARGS[1]:-}"; ROLE="${ARGS[2]:-active}"
case "$ARM" in
  ovngw) NS="$NS_OVNGW"; MODE="${MODE:-node}"; case "$MODE" in nic|node|full|crash|poweroff) ;; *) die "ovngw: mode must be nic, node, full, crash or poweroff" ;; esac ;;
  natgw) NS="$NS_NAT";   MODE="${MODE:-pod}";  case "$MODE" in pod|node|poweroff) ;; *) die "natgw: mode must be pod, node or poweroff" ;; esac ;;
  *) die "usage: ./50-gateway-failure.sh <ovngw|natgw> [nic|node|full|crash|poweroff|pod] [active|other]" ;;
esac
case "$ROLE" in active|other) ;; *) die "the third argument must be active or other" ;; esac
PH=$FAIL_PHASE; INT=$FAIL_INTERVAL; R=$FAIL_REPS; P=$FAIL_PODS; POT="${POWER_ON_TIMEOUT:-600}"
UDP="${UDP:-0}"; UDP_PORT="${UDP_PORT:-9999}"
[ "$UDP" = 1 ] && [ "$MODE" = poweroff ] && die "UDP=1 is not supported with poweroff"
for c in $CLUSTER_NODES; do eval "HN_$c=\"\$(nssh $c hostname | tr -d '\r')\""; done
hn() { eval "echo \$HN_$1"; }
machine_of() { local c; for c in $CLUSTER_NODES; do [ "$(hn "$c")" = "$1" ] && { echo "$c"; return; }; done; }
nb_sb() { rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl $*" 2>/dev/null; }

sec "1. Gateway under test and machine to fail"
rk "$SERVER" "kubectl get ns $NS" >/dev/null 2>&1 || die "the namespace $NS does not exist: configure the gateway first"
GWM=""
if [ "$ARM" = ovngw ]; then
  for h in $(rk "$SERVER" "kubectl get ovn-eip -o jsonpath='{range .items[?(@.spec.type==\"lsp\")]}{.metadata.name}{\"\\n\"}{end}'"); do GWM="$GWM $(machine_of "$h")"; done
  GWM="${GWM# }"
  BFDS="$(rk "$SERVER" "kubectl get vpc $OVNGW_VPC -o jsonpath='{.status.enableBfd}'" 2>/dev/null)"
  CH="$(nb_sb --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external | tr -d '\r' | head -1)"
  ACT_H="$(nb_sb --bare --columns=hostname list chassis "$CH" | tr -d '\r' | head -1)"
  ACT="$(machine_of "$ACT_H")"
  NGW=0; for g in $GWM; do NGW=$((NGW+1)); done
  [ "$NGW" -ge 2 ] || die "a failure test needs at least two OVN gateway nodes (now $NGW)"
  if [ "$ROLE" = active ]; then FM="$ACT"; else FM=""; for g in $GWM; do
      [ "$g" = "$ACT" ] && continue
      # a machine that is shut down or crashed cannot be the K3s server or the customer host
      if [ "$MODE" = crash ] || [ "$MODE" = poweroff ]; then [ "$g" = "$SERVER" ] || [ "$g" = "$FABRIC_NODE" ] && continue; fi
      FM="$g"
    done; fi
  [ -n "$FM" ] || die "cannot choose the machine to fail"
  if [ "$BFDS" = true ]; then TAG="ovngw-n$NGW-ecmp-bfd"; else TAG="ovngw-n$NGW-nobfd"; fi
  echo "  OVN Gateway, $NGW nodes (machines $GWM), BFD: ${BFDS:-false}; the VPC router port cr-$OVNGW_VPC-external is on machine $ACT ($ACT_H)"
else
  H="$(rk "$SERVER" "kubectl -n kube-system get pod vpc-nat-gw-$NAT_GW-0 -o jsonpath='{.spec.nodeName}'" 2>/dev/null | tr -d '\r')"
  [ -n "$H" ] || die "the NAT Gateway pod vpc-nat-gw-$NAT_GW-0 does not exist: run ./30-nat-gateway.sh first"
  FM="$(machine_of "$H")"; TAG="natgw-pod"; ROLE="-"
  [ "$MODE" = poweroff ] && TAG="natgw"
  echo "  NAT Gateway pod vpc-nat-gw-$NAT_GW-0 on machine $FM ($H)"
fi
FAILSTR="$ARM $MODE (role $ROLE) on machine $FM"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BENCH_RESULTS_DIR:-$HERE/results}/failure/$TAG-$MODE-$ROLE-$STAMP"; mkdir -p "$OUT"
echo "  failure: $FAILSTR; $P pods, ping every ${INT}s, phases of ${PH}s, $R repetitions"
echo "  results: $OUT"
if [ "$MODE" = crash ]; then
  [ "$FM" != "$SERVER" ] && [ "$FM" != "$FABRIC_NODE" ] || die "machine $FM hosts the K3s server or the customer network: it cannot be crashed (use the role that selects the other machine)"
  PERSIST="$(nssh "$FM" 'systemctl is-enabled gw-ext.service 2>/dev/null' | tr -d '\r')"
  [ "$R" = 1 ] || [ "$PERSIST" = enabled ] || die "crash: use FAIL_REPS=1, or run ./62-persist-gateway-machine.sh first (the machine must rebuild its external interface by itself)"
  [ "$PH" -ge 60 ] 2>/dev/null || die "crash: use FAIL_PHASE=60 or more"
  confirm "This REBOOTS machine $FM abruptly (like a power loss). Afterwards you must run ./52-recover-gateway-machine.sh $FM. Continue?"
elif [ "$MODE" = poweroff ]; then
  [ "$FM" != "$SERVER" ] && [ "$FM" != "$FABRIC_NODE" ] || die "machine $FM hosts the K3s server or the customer network: it cannot be shut down (for ovngw use the role that selects another machine; for natgw move the pod first)"
  confirm "This SHUTS DOWN machine $FM (sudo poweroff) $R times. Each time you must power it on again from the dashboard (the script waits up to ${POT}s). Continue?"
else
  confirm "This injects a failure on machine $FM $R times (and removes it each time). Continue?"
fi

# --- injection / restore -----------------------------------------------------------------------------------------------
inject() {   # prints the epoch time (machine clock) at which the failure was injected
  case "$ARM:$MODE" in
    ovngw:nic)  nroot "$FM" EXT_NIC="$EXT_NIC" <<<'date +%s.%N; ip link set "$EXT_NIC" down' ;;
    *:node)     nroot "$FM" <<<'date +%s.%N; iptables -I INPUT -p udp --dport 6081 -j DROP; iptables -I OUTPUT -p udp --dport 6081 -j DROP' ;;
    ovngw:full) nroot "$FM" EXT_NIC="$EXT_NIC" <<<'date +%s.%N; iptables -I INPUT -p udp --dport 6081 -j DROP; iptables -I OUTPUT -p udp --dport 6081 -j DROP; ip link set "$EXT_NIC" down' ;;
    ovngw:crash) nssh "$SERVER" 'date +%s.%N'   # time on the server machine, where the tenant pods are (the failed machine cannot answer later)
                nroot "$FM" <<<'nohup sh -c "sleep 0.5; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger" >/dev/null 2>&1 &' >/dev/null 2>&1 ;;
    *:poweroff) nssh "$SERVER" 'date +%s.%N'   # time on the server machine (the failed machine cannot answer later)
                nroot "$FM" <<<'nohup sh -c "sleep 0.5; poweroff" >/dev/null 2>&1 &' >/dev/null 2>&1 ;;
    natgw:pod)  rk "$SERVER" "date +%s.%N; kubectl -n kube-system delete pod vpc-nat-gw-$NAT_GW-0 --wait=false >/dev/null" ;;
  esac
}
restore() {  # prints the epoch time at which the failure was removed
  case "$ARM:$MODE" in
    ovngw:nic)  nroot "$FM" EXT_NIC="$EXT_NIC" <<<'date +%s.%N; ip link set "$EXT_NIC" up' ;;
    *:node)     nroot "$FM" <<<'date +%s.%N; while iptables -D INPUT -p udp --dport 6081 -j DROP 2>/dev/null; do :; done; while iptables -D OUTPUT -p udp --dport 6081 -j DROP 2>/dev/null; do :; done' ;;
    ovngw:full) nroot "$FM" EXT_NIC="$EXT_NIC" <<<'date +%s.%N; ip link set "$EXT_NIC" up; while iptables -D INPUT -p udp --dport 6081 -j DROP 2>/dev/null; do :; done; while iptables -D OUTPUT -p udp --dport 6081 -j DROP 2>/dev/null; do :; done' ;;
    ovngw:crash) nssh "$SERVER" 'date +%s.%N' ;;   # nothing to remove: the machine boots by itself; this only marks the end of the failure phase
    *:poweroff) nssh "$SERVER" 'date +%s.%N' ;;   # nothing to remove here: the machine is powered on by the user (see the repetition loop)
    natgw:pod)  date +%s.%N ;;
  esac
}
cleanup() { restore >/dev/null 2>&1; rk "$SERVER" "kubectl -n $NS delete pod -l app=fail --ignore-not-found --wait=false" >/dev/null 2>&1; }
trap cleanup EXIT

sec "2. Tenant pods"
# make_pods <machine to avoid> : (re)creates the tenant pods fail-0.. on the cluster machines except the one that will fail
make_pods() {
  local AV="$1" i c PLACE
  # The old pods must be completely gone before the new ones (same names) are created: a pod created while its predecessor is
  # still terminating gets a CNI request for the old UID ("expected pod UID ... but got ...") and starts minutes late.
  rk "$SERVER" "kubectl -n $NS delete pod -l app=fail --ignore-not-found --wait=false" >/dev/null 2>&1
  _nopods() { [ -z "$(rk "$SERVER" "kubectl -n $NS get pod -l app=fail -o name" 2>/dev/null | tr -d '\r')" ]; }
  WAIT_MSG="waiting for the old tenant pods to be gone" waitf 12 5 _nopods || {
    rk "$SERVER" "kubectl -n $NS delete pod -l app=fail --force --grace-period=0 --ignore-not-found" >/dev/null 2>&1
    WAIT_MSG="waiting for the old tenant pods to be gone (forced)" waitf 24 5 _nopods; }
  sleep 10
  # Pods go on machines other than the failed one (a pod on the failed machine would lose its own node, not only the gateway),
  # except when the failure does not touch the overlay (nic, pod).
  PLACE=""; for c in $CLUSTER_NODES; do if { [ "$MODE" = node ] || [ "$MODE" = full ] || [ "$MODE" = crash ] || [ "$MODE" = poweroff ]; } && [ "$c" = "$AV" ]; then continue; fi; PLACE="$PLACE $c"; done
  PLACE="${PLACE# }"; [ -n "$PLACE" ] || die "no machine left for the tenant pods"
  for i in $(seq 0 $((P-1))); do
    c=$(set -- $PLACE; eval "echo \${$((i % $# + 1))}")
    kapply <<Y >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fail-$i, namespace: $NS, labels: {app: fail}}
spec:
  nodeName: $(hn "$c")
  containers:
  - name: c
    image: "$PROBE_IMAGE"
    command: ["sleep", "7200"]
Y
  done
  run_spin "waiting for the tenant pods" "up to 8 minutes" rk "$SERVER" "kubectl -n $NS wait --for=condition=Ready pod -l app=fail --timeout=480s" || { tail -5 "$RUN_LOG"; die "the tenant pods are not Ready"; }
  for i in $(seq 0 $((P-1))); do echo "  fail-$i: $(rk "$SERVER" "kubectl -n $NS get pod fail-$i -o jsonpath='{.spec.nodeName} {.status.podIP}'")"; done
  PODS_AVOID="$AV"
  # a new pod, or a router port that has just moved, needs several seconds before the first ping goes through (data-plane warm-up)
  WAIT_MSG="waiting for the data path (warm-up of new pods / moved router port, up to 2 minutes)" waitf 24 5 _ping0 || true
}
_ping0() { rk "$SERVER" "kubectl -n $NS exec fail-0 -- ping -c 2 -W 2 $CUST_HOST_IP >/dev/null 2>&1"; }
make_pods "$FM"
expect "tenant pod -> customer host (ping)" ok "$(_ping0 && echo ok || echo fail)"
[ "${RES_STATUS[0]}" = PASS ] || { table; die "the tenant does not reach the customer host"; }
SK=$( { nssh "$SERVER" 'date +%s.%N'; nssh "$FM" 'date +%s.%N'; } | awk 'NR==1{a=$1} NR==2{printf "%.3f", $1-a}')
info "clock difference between the server machine and machine $FM: ${SK}s (the ssh round trip adds to it)"
{ echo "date: $(date -u +%FT%TZ)"; echo "tag: $TAG  failure: $FAILSTR"; echo "pods: $P  interval: ${INT}s  phase: ${PH}s  repetitions: $R  clock difference: ${SK}s"
  rk "$SERVER" "kubectl -n kube-system get deploy kube-ovn-controller -o jsonpath='{.spec.template.spec.containers[0].image}'"; echo; } > "$OUT/environment.txt"

# --- analysis of one repetition. Every pod writes "# start <epoch>" and "# end <epoch>" around its pings; the last gap of a pod
# is measured up to ITS OWN end (not to the last reply of all the pods: the pods stop one after the other). A gap with no reply
# up to the end of the pod is "open" (lower bound). Without the markers (old files) the end of a pod is the last reply of all pods.
# Prints "pod failover_s restore_s replies gaps open lost_s"; writes the events (pod, start from T1, length, open) to $4.
analyse() {   # analyse <file> <T1> <T2> <events file>
  awk -v T1="$2" -v T2="$3" -v I="$INT" -v EV="$4" '
    /^=== pod/ {p=$3; pods[p]=1; next}
    /^# end/ {pe[p]=$3+0; next}
    /bytes from/ { ts=$1; gsub(/[\[\]]/,"",ts); ts=ts+0; n=++cnt[p]; t[p,n]=ts; if(ts>tend)tend=ts }
    function cls(p,start,gap,open,   o){ o=gap-I; if(o<0.5) return;
        ng[p]++; lost[p]+=o; if(open)op[p]=1
        printf "%s %.2f %.2f %d\n", p, start-T1, o, open >> EV
        if(start>=T1-1 && start<T2-0.5){ if(o>fo[p])fo[p]=o } else if(start>=T2-1){ if(o>rs[p])rs[p]=o } }
    END{ printf "" > EV
         for(p in pods){ for(k=2;k<=cnt[p];k++) cls(p,t[p,k-1],t[p,k]-t[p,k-1],0);
            e=(p in pe)?pe[p]:tend
            if(cnt[p]>0 && e-t[p,cnt[p]]-I>=0.5) cls(p,t[p,cnt[p]],e-t[p,cnt[p]],1)
            printf "%s %.2f %.2f %d %d %d %.2f\n", p, fo[p]+0, rs[p]+0, cnt[p], ng[p]+0, op[p]+0, lost[p]+0 } }' "$1" | sort -n
}

# State of the OVN gateway during the failure (first repetition only, ovngw): chassis of the router port, BFD, routes.
snap() {   # snap <label>
  echo "=== $1  ($(date +%T))"
  echo "--- chassis hosting cr-$OVNGW_VPC-external (empty = port not bound to any chassis)"
  local C; C="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external" 2>&1 | tr -d '\r\n ')"
  if [ -z "$C" ]; then echo "(none)"; else rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --columns=hostname list chassis $C" 2>&1; fi
  echo "--- gateway chassis priorities (NB)"
  rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --columns=name,chassis_name,priority list gateway_chassis" 2>&1
  echo "--- BFD sessions (NB)"
  rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --columns=dst_ip,status find bfd" 2>&1
  echo "--- BFD sessions (SB: as reported by the chassis that hosts the port)"
  rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --columns=dst_ip,status,disc,min_tx,detect_mult list bfd" 2>&1
  echo "--- routes of the VPC"
  rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl lr-route-list $OVNGW_VPC" 2>&1
}

# Machine that hosts the router port (where the SNAT is done) right now; empty if the port is not bound
cr_machine() {
  local C H
  C="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external" 2>/dev/null | tr -d '\r\n ')"
  [ -n "$C" ] || return 0
  H="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=hostname list chassis $C" 2>/dev/null | tr -d '\r\n ')"
  machine_of "$H"
}

# Settled state before a repetition: every BFD session towards a gateway node is up and all the gateway chassis have the same
# priority (Kube-OVN lowers the priority of a chassis whose BFD is down; it takes some time to be raised again).
settled() {   # SETTLE=equal: the old criterion
  local PR UP
  # without BFD Kube-OVN does not touch the chassis priorities (they stay different by design): nothing to wait for
  [ "$BFDS" = true ] || return 0
  PR="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=priority list gateway_chassis" 2>/dev/null | tr -d '\r' | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
  UP="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=status find bfd status=up" 2>/dev/null | tr -d '\r' | grep -c up)"
  [ "$PR" = 1 ] && [ "$UP" -ge "$NGW" ]
}
# state_sig: one line with the chassis priorities (by chassis), the machine of the router port and the number of BFD sessions up
state_sig() {
  local PR UP
  PR="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=chassis_name,priority list gateway_chassis" 2>/dev/null | tr -d '\r' | grep -v '^$' | paste -d= - - | sort | tr '\n' ' ')"
  UP="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=status find bfd status=up" 2>/dev/null | tr -d '\r' | grep -c up)"
  echo "port=$(cr_machine) bfd_up=$UP prio: $PR"
}
# wait_settled: returns 0 when settled; prints the seconds waited and the final state to settle-r<rep>.txt
wait_settled() {   # wait_settled <rep>
  local t0=$SECONDS S1 S2 UP
  if [ "${SETTLE:-stable}" = equal ]; then
    WAIT_MSG="waiting for a settled state (BFD up, equal priorities)" waitf $(( ${SETTLE_MAX:-300} / 5 )) 5 settled; local rc=$?
    echo "criterion=equal waited=$((SECONDS-t0))s settled=$([ $rc = 0 ] && echo yes || echo no) $(state_sig)" > "$OUT/settle-r$1.txt"; return $rc
  fi
  [ "$BFDS" = true ] || { echo "criterion=stable no BFD: nothing to wait for" > "$OUT/settle-r$1.txt"; return 0; }
  while [ $((SECONDS-t0)) -lt "${SETTLE_MAX:-300}" ]; do
    S1="$(state_sig)"; UP="$(echo "$S1" | sed -n 's/.*bfd_up=\([0-9]*\).*/\1/p')"
    if [ "${UP:-0}" -ge "$NGW" ]; then
      sleep "${SETTLE_QUIET:-30}"; S2="$(state_sig)"
      if [ "$S1" = "$S2" ]; then echo "criterion=stable quiet=${SETTLE_QUIET:-30}s waited=$((SECONDS-t0))s settled=yes $S2" > "$OUT/settle-r$1.txt"; return 0; fi
    else sleep 5; fi
  done
  echo "criterion=stable waited=$((SECONDS-t0))s settled=no $(state_sig)" > "$OUT/settle-r$1.txt"; return 1
}

# COLLECT=1 (ovngw, repetition 1 only): a timeline of the router-port binding sampled every second during the failure, and the
# logs of ovn-controller (every ovs-ovn pod) and of the OVN central components, to see WHO releases the port and when.
timeline() {   # timeline <seconds>   (runs on the server machine; prints "epoch chassis-host priorities")
  rk "$SERVER" "for i in \$(seq 1 $1); do T=\$(date +%s.%N); C=\$(kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=chassis find port_binding logical_port=cr-$OVNGW_VPC-external 2>/dev/null | tr -d '\\r\\n '); H=none; [ -n \"\$C\" ] && H=\$(kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-sbctl --bare --columns=hostname list chassis \$C 2>/dev/null | tr -d '\\r\\n '); P=\$(kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=priority list gateway_chassis 2>/dev/null | tr '\\n' ' '); echo \"\$T \$H prio: \$P\"; sleep 0.5; done" 2>&1
}
collect_logs() {   # collect_logs <file>
  {
    echo "=== ovn-controller logs (last 300 lines of each ovs-ovn pod)"
    for pod in $(rk "$SERVER" "kubectl -n kube-system get pod -l app=ovs -o jsonpath='{range .items[*]}{.metadata.name}{\":\"}{.spec.nodeName}{\"\\n\"}{end}'" | tr -d '\r'); do
      echo "--- ${pod%%:*} on ${pod##*:}"; rk "$SERVER" "kubectl -n kube-system exec ${pod%%:*} -- tail -n 300 /var/log/ovn/ovn-controller.log 2>&1"
    done
    echo "=== ovn-central: northd and SB database logs (last 200 lines)"
    rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- sh -c 'tail -n 200 /var/log/ovn/ovn-northd.log; echo ---; tail -n 200 /var/log/ovn/ovsdb-server-sb.log'" 2>&1
    echo "=== kube-ovn-controller (BFD, chassis, gateway)"
    rk "$SERVER" "kubectl -n kube-system logs deploy/kube-ovn-controller --since=3m 2>&1 | grep -i -E 'bfd|chassis|gateway|priority' | tail -60"
  } > "$1" 2>&1
}

# RESET_PRIO=1: the priorities of the gateway chassis right after the configuration (first settled state) are the reference;
# before every repetition they are set back to it, so that every repetition starts from the same state (Kube-OVN lowers the
# priority of a chassis whose BFD went down and does not always raise it again).
prio_now() { rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=chassis_name,priority list gateway_chassis" 2>/dev/null | tr -d '\r' | grep -v '^$' | paste -d= - - | sort | tr '\n' ' '; }
prio_reset() {   # sets every gateway chassis back to the reference priority; prints how many were changed
  local kv ch pr n=0 u cur
  for kv in $PREF; do ch="${kv%%=*}"; pr="${kv##*=}"
    for u in $(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare --columns=_uuid find gateway_chassis chassis_name=$ch" 2>/dev/null | tr -d '\r'); do
      cur="$(rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl --bare get gateway_chassis $u priority" 2>/dev/null | tr -d '\r ')"
      [ "$cur" = "$pr" ] || { rk "$SERVER" "kubectl -n kube-system exec deploy/ovn-central -c ovn-central -- ovn-nbctl set gateway_chassis $u priority=$pr" >/dev/null 2>&1; n=$((n+1)); }
    done
  done; echo "$n"
}
PREF=""
if [ "$ARM" = ovngw ] && [ "$BFDS" = true ] && [ "${RESET_PRIO:-0}" = 1 ]; then
  wait_settled 0 || warn "the gateway is not settled before the first repetition"
  PREF="$(prio_now)"; echo "reference priorities: $PREF" | tee -a "$OUT/environment.txt"
fi

sec "3. Repetitions"
printf '  %-4s %-26s %-26s %s\n' rep "failover per pod (s)" "restore per pod (s)" "affected pods / longest failover (s) / longest restore (s)"
echo "rep longest_failover_s affected_pods longest_restore_s failed_machine router_port_machine_before settled_before valid port_at_failure role_ok pods_not_back pods_more_gaps" > "$OUT/runs.txt"
BAD=0; INVALID=0
for rep in $(seq 1 "$R"); do
  TOTAL=$((3*PH+4)); [ "$MODE" = poweroff ] && TOTAL=$((3*PH+POT+400)); [ "$MODE" = crash ] && TOTAL=$((4*PH+4))   # poweroff: the pings stop when /tmp/stop is created
  CRM="-"; SETTLED="-"
  if [ "$ARM" = ovngw ]; then
    if wait_settled "$rep"; then SETTLED=yes; else SETTLED=no; warn "repetition $rep starts from a state that is not settled (BFD or priorities): see settle-r$rep.txt"; fi
    if [ -n "$PREF" ] && [ "$(prio_now)" != "$PREF" ]; then
      NCH=$(prio_reset); info "repetition $rep: $NCH gateway chassis priorities set back to the reference ($PREF)"; echo "reset of $NCH priorities to: $PREF" >> "$OUT/settle-r$rep.txt"
      if wait_settled "$rep"; then SETTLED=yes; else SETTLED=no; fi
    fi
    CRM="$(cr_machine)"; CRM="${CRM:--}"
    # the router port moves after a failure and does not always come back: for nic and node, choose the machine to fail from
    # where the port is now, so that every repetition tests the same situation (role active / other)
    if { [ "$MODE" = nic ] || [ "$MODE" = node ] || [ "$MODE" = full ] || [ "$MODE" = crash ]; } && [ "$CRM" != "-" ]; then
      if [ "$ROLE" = active ]; then FM="$CRM"; else
        # "other": a gateway machine without the port, chosen at random among the possible ones (not always the same machine)
        CAND=""; for g in $GWM; do [ "$g" = "$CRM" ] && continue
          if [ "$MODE" = crash ]; then [ "$g" = "$SERVER" ] || [ "$g" = "$FABRIC_NODE" ] && continue; fi; CAND="$CAND $g"; done
        [ -n "$CAND" ] && FM=$(set -- $CAND; eval "echo \${$((RANDOM % $# + 1))}"); fi
      if [ "$MODE" = crash ] && { [ "$FM" = "$SERVER" ] || [ "$FM" = "$FABRIC_NODE" ]; }; then
        warn "repetition $rep: the router port is on machine $FM, which cannot be crashed: repetition skipped"; echo "$rep - - - $FM $CRM $SETTLED skipped - - - -" >> "$OUT/runs.txt"; continue
      fi
      if { [ "$MODE" = node ] || [ "$MODE" = full ] || [ "$MODE" = crash ]; } && [ "$FM" != "$PODS_AVOID" ]; then
        info "repetition $rep: the machine to fail is now $FM (router port on machine $CRM): recreating the tenant pods away from it"
        make_pods "$FM"
        if wait_settled "$rep"; then SETTLED=yes; else SETTLED=no; warn "repetition $rep starts from a state that is not settled (BFD or priorities): see settle-r$rep.txt"; fi
        CRM="$(cr_machine)"; CRM="${CRM:--}"
        [ "$ROLE" = active ] && [ "$CRM" != "$FM" ] && warn "repetition $rep: the router port moved again (now machine $CRM) while the pods were recreated"
      fi
    fi
  fi
  if [ "$UDP" = 1 ]; then
    # receiver of the UDP stream on the customer host (namespace cust of the fabric machine): one line per datagram,
    # "<arrival epoch> <source address> <payload>", until TOTAL+25 s from now. Started BEFORE the senders.
    nroot "$FABRIC_NODE" CUST_HOST_IP="$CUST_HOST_IP" UDP_PORT="$UDP_PORT" DUR="$((TOTAL+25))" <<'EOS' > "$OUT/udp-recv-start-r$rep.txt" 2>&1
pkill -f /tmp/udp-recv.py 2>/dev/null; sleep 0.5; rm -f /tmp/udp-recv.txt
cat > /tmp/udp-recv.py <<'PY'
import socket, sys, time
ip, port, dur, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ip, port)); s.settimeout(0.5)
end = time.time() + dur
with open(out, "w", buffering=1) as f:
    while time.time() < end:
        try: d, a = s.recvfrom(512)
        except socket.timeout: continue
        f.write("%.6f %s %s\n" % (time.time(), a[0], d.decode(errors="replace").strip()))
PY
ip netns exec cust nohup python3 /tmp/udp-recv.py "$CUST_HOST_IP" "$UDP_PORT" "$DUR" /tmp/udp-recv.txt >/tmp/udp-recv.log 2>&1 &
sleep 1; pgrep -f /tmp/udp-recv.py >/dev/null && echo "receiver started" || { echo "receiver NOT started"; cat /tmp/udp-recv.log; }
EOS
    grep -q "receiver started" "$OUT/udp-recv-start-r$rep.txt" || warn "repetition $rep: the UDP receiver did not start (udp-recv-start-r$rep.txt)"
    # senders: one numbered datagram ("<pod name> <n>") every INT s, for TOTAL s, in the background inside every pod
    rk "$SERVER" "for i in \$(seq 0 $((P-1))); do kubectl -n $NS exec fail-\$i -- sh -c 'rm -f /tmp/udp.txt; E=\$((\$(date +%s) + $TOTAL)); H=\$(hostname); n=0; { echo \"# start \$(date +%s.%N)\"; while [ \$(date +%s) -lt \$E ]; do n=\$((n+1)); echo \"\$H \$n\" | socat -u - UDP4-SENDTO:$CUST_HOST_IP:$UDP_PORT 2>/dev/null; sleep $INT; done; echo \"# sent \$n\"; echo \"# end \$(date +%s.%N)\"; } > /tmp/udp.txt 2>&1 </dev/null &' </dev/null; done" >/dev/null 2>&1
  fi
  # the pings run INSIDE the pods (started in the background, output in a file of the pod) and are collected afterwards: a
  # kubectl exec stream that is cut at the moment of the failure would otherwise end the measurement. ping is restarted in a loop
  # because it exits by itself when it receives an ICMP Redirect from the NAT Gateway pod being replaced (seen with natgw pod)
  rk "$SERVER" "for i in \$(seq 0 $((P-1))); do kubectl -n $NS exec fail-\$i -- sh -c 'rm -f /tmp/ping.txt /tmp/stop; E=\$((\$(date +%s) + $TOTAL)); { echo \"# start \$(date +%s.%N)\"; while [ \$(date +%s) -lt \$E ] && [ ! -f /tmp/stop ]; do ping -D -i $INT -w 5 -W 1 $CUST_HOST_IP; sleep 0.1; done; echo \"# end \$(date +%s.%N)\"; } > /tmp/ping.txt 2>&1 </dev/null &' </dev/null; done" >/dev/null 2>&1
  if [ "$MODE" = poweroff ]; then   # collected after the script has stopped the pings (/tmp/stop)
    ( while [ ! -f "$OUT/.collect-r$rep" ]; do sleep 1; done; sleep 7
      for i in $(seq 0 $((P-1))); do echo "=== pod $i"
        # the ssh connection to the server can time out after a machine has been shut down: retry (the output stays in the pod)
        for t in 1 2 3 4 5 6 7 8 9 10; do
          o="$(rk "$SERVER" "kubectl -n $NS exec fail-$i -- cat /tmp/ping.txt" 2>&1 | tr -d '\r')"
          case "$o" in *"banner exchange"*|*"timed out"*|*"Connection closed"*|"") sleep 10 ;; *) break ;; esac
        done
        printf '%s\n' "$o"
      done ) > "$OUT/raw-r$rep.txt" 2>&1 &
  else
    # each pod leaves its loop only when its last "ping -w 5" ends (up to TOTAL+5 s after it started): wait long enough that
    # every pod has written its "# end" marker
    ( sleep $((TOTAL+9)); for i in $(seq 0 $((P-1))); do echo "=== pod $i"; rk "$SERVER" "kubectl -n $NS exec fail-$i -- cat /tmp/ping.txt" 2>&1 | tr -d '\r'; done ) > "$OUT/raw-r$rep.txt" 2>&1 &
  fi
  PID=$!
  sleep $((PH+2))
  CRI="-"; ROLEOK="-"
  if [ "$ARM" = ovngw ]; then   # where is the router port at the moment of the failure? (the role must still be right)
    CRI="$(cr_machine)"; CRI="${CRI:--}"
    if [ "$ROLE" = active ]; then [ "$CRI" = "$FM" ] && ROLEOK=yes || ROLEOK=no; else [ "$CRI" != "$FM" ] && ROLEOK=yes || ROLEOK=no; fi
    [ "$ROLEOK" = yes ] || warn "repetition $rep: at the moment of the failure the router port is on machine $CRI: role $ROLE not respected"
  fi
  T1=$(inject | head -1)
  # PROBE_CMD (optional): a command run PROBE_AT seconds (default 10) after the failure, with the output prefix as argument
  if [ -n "${PROBE_CMD:-}" ]; then ( sleep "${PROBE_AT:-10}"; "$PROBE_CMD" "$OUT/probe-r$rep" > "$OUT/probe-r$rep.log" 2>&1 ) & fi
  if [ "$ARM" = ovngw ]; then   # BFD sessions up during the failure (a failure that takes the node out of the path brings one down)
    ( sleep 8; echo "+8s $(state_sig)" > "$OUT/state-r$rep.txt"; sleep 20; echo "+28s $(state_sig)" >> "$OUT/state-r$rep.txt" ) &
  fi
  if [ "$ARM:$MODE" = natgw:pod ] && [ "${NAT_NEIGH_FLUSH:-0}" = 1 ]; then   # delete the neighbour entry of the EIP once the new EIP is ready
    ( EIPIP="$(rk "$SERVER" "kubectl get iptables-eip -o jsonpath='{.items[0].status.ip}'" 2>/dev/null | tr -d '\r')"
      sleep 3
      for _ in $(seq 1 $((PH*2))); do
        [ "$(rk "$SERVER" "kubectl get iptables-eip -o jsonpath='{.items[0].status.ready}'" 2>/dev/null | tr -d '\r')" = true ] && break; sleep 0.5; done
      nroot "$FABRIC_NODE" EIPIP="$EIPIP" <<<'date +%s.%N; ip netns exec fabric ip neigh del "$EIPIP" dev fab0 2>&1; ip netns exec fabric ping -c 1 -W 1 "$EIPIP" >/dev/null 2>&1; ip netns exec fabric ip neigh show "$EIPIP"' > "$OUT/neigh-flush-r$rep.txt" 2>&1 ) &
  fi
  if [ "$MODE" = crash ]; then   # when is the crashed machine reachable again by ssh? (written to machine-up-r$rep.txt)
    ( sleep 5; for _ in $(seq 1 $((3*PH))); do sleep 1; nssh "$FM" true >/dev/null 2>&1 && { echo "$(nssh "$SERVER" 'date +%s.%N') reachable"; break; }; done > "$OUT/machine-up-r$rep.txt" 2>&1 ) &
  fi
  if [ "$ARM:$MODE" = natgw:pod ]; then   # when is the new gateway pod Running/Ready, and when are the EIP and the SNAT ready again?
    ( rk "$SERVER" "for i in \$(seq 1 $((PH*2))); do T=\$(date +%s.%N); S=\$(kubectl -n kube-system get pod vpc-nat-gw-$NAT_GW-0 -o jsonpath='{.metadata.uid} {.status.phase} ready={.status.containerStatuses[*].ready}' 2>&1); E=\$(kubectl get iptableseip.kubeovn.io -o jsonpath='{range .items[*]}{.status.ready}{\" \"}{end}' 2>&1); N=\$(kubectl get iptablessnatrule.kubeovn.io -o jsonpath='{range .items[*]}{.status.ready}{\" \"}{end}' 2>&1); echo \"\$T pod: \$S eip_ready: \$E snat_ready: \$N\"; sleep 0.5; done" > "$OUT/natpod-timeline-r$rep.txt" 2>&1
      rk "$SERVER" "kubectl -n kube-system logs deploy/kube-ovn-controller --since=3m 2>&1 | grep -i -E 'nat|eip|snat' | tail -80" > "$OUT/natpod-controller-r$rep.txt" 2>&1 ) &
  fi
  if [ "$ARM" = ovngw ] && [ "$rep" = 1 ]; then ( sleep 2; snap "3 s after the failure" > "$OUT/state-during-failure.txt" 2>&1; sleep 4; snap "9 s after the failure" >> "$OUT/state-during-failure.txt" 2>&1; sleep 6; snap "about 25 s after the failure" >> "$OUT/state-during-failure.txt" 2>&1; sleep 15; snap "about 50 s after the failure" >> "$OUT/state-during-failure.txt" 2>&1; sleep 20; snap "about 80 s after the failure" >> "$OUT/state-during-failure.txt" 2>&1; sleep 20; snap "about 110 s after the failure" >> "$OUT/state-during-failure.txt" 2>&1 ) & fi
  if [ "$ARM" = ovngw ] && [ "${COLLECT:-0}" = 1 ]; then ( timeline $([ "$MODE" = crash ] && echo $((PH*4)) || echo $((PH*2+20))) > "$OUT/timeline-rep$rep.txt" 2>&1 ) & fi
  if [ "$MODE" = crash ]; then   # the failure ends when the machine answers ssh again (T2); then PH more seconds
    for _ in $(seq 1 $((2*PH))); do [ -s "$OUT/machine-up-r$rep.txt" ] && break; sleep 1; done
    T2="$(awk 'NR==1{print $1}' "$OUT/machine-up-r$rep.txt" 2>/dev/null)"; [ -n "$T2" ] || T2=$(restore | head -1)
    _left=$(awk -v t2="$T2" -v now="$(nssh "$SERVER" 'date +%s.%N')" -v ph="$PH" 'BEGIN{x=t2+ph-now; if(x<0)x=0; printf "%d", x+1}')
    sleep "$_left"
  else
    sleep "$PH"
    T2=$(restore | head -1)
  fi
  if [ "$MODE" = poweroff ]; then
    STOPCMD="for i in \$(seq 0 $((P-1))); do kubectl -n $NS exec fail-\$i -- touch /tmp/stop; done"
    echo "  >>> repetition $rep: machine $FM was shut down ${PH}s ago. POWER IT ON NOW from the CrownLabs dashboard (waiting up to ${POT}s for ssh) <<<"
    printf '\a'
    TUP=""; _t0=$(date +%s)
    while [ $(( $(date +%s) - _t0 )) -lt "$POT" ]; do nssh "$FM" true >/dev/null 2>&1 && { TUP=$(nssh "$SERVER" 'date +%s.%N'); break; }; sleep 3; done
    if [ -z "$TUP" ]; then
      warn "machine $FM did not answer ssh within ${POT}s: repetition $rep not valid, stopping"
      { for _t in 1 2 3 4 5 6; do rk "$SERVER" "$STOPCMD" >/dev/null 2>&1 && break; sleep 10; done; }; touch "$OUT/.collect-r$rep"; wait $PID
      BAD=$((BAD+1)); INVALID=$((INVALID+1)); break
    fi
    echo "  machine $FM answers ssh again $(awk -v a="$T2" -v b="$TUP" 'BEGIN{printf "%.0f", b-a}') s after the end of the failure phase; recovering it"
    "$HERE/52-recover-gateway-machine.sh" "$FM" --yes > "$OUT/recover-r$rep.log" 2>&1; REC=$?
    TREC=$(nssh "$SERVER" 'date +%s.%N')
    echo "T1=$T1 T2=$T2 ssh_up=$TUP recovered=$TREC recover_exit=$REC" > "$OUT/poweroff-r$rep.txt"
    [ "$REC" = 0 ] || warn "52-recover-gateway-machine.sh exited with $REC (see recover-r$rep.log)"
    sleep "$PH"
    { for _t in 1 2 3 4 5 6; do rk "$SERVER" "$STOPCMD" >/dev/null 2>&1 && break; sleep 10; done; }
    touch "$OUT/.collect-r$rep"
  fi
  wait $PID
  if [ "$ARM" = ovngw ] && [ "$rep" = 1 ] && [ "${COLLECT:-0}" = 1 ]; then wait; collect_logs "$OUT/logs-rep1.txt"; echo "  logs and timeline of repetition 1 saved (logs-rep1.txt, timeline-rep1.txt); T1=$T1 T2=$T2" | tee -a "$OUT/environment.txt"; fi
  echo "$T1 $T2" > "$OUT/times-r$rep.txt"
  # the measurement is valid only if every pod was still answering (or at least pinging) well after the failure was removed
  NSHORT=$(awk -v T2="$T2" -v PH="$PH" '/^=== pod/{p=$3; if(p>mx)mx=p} /bytes from/{ts=$1; gsub(/[\[\]]/,"",ts); if(ts+0>last[p])last[p]=ts+0} END{n=0; for(q=0;q<=mx;q++) if(last[q]<T2+PH/2) n++; print n}' "$OUT/raw-r$rep.txt")
  # ... and only if every pod was answering right before the failure (last reply at most 3 s before T1): otherwise the traffic
  # was already interrupted (for example the gateway had not recovered from the previous repetition) and "no gap" means nothing
  NPRE=$(awk -v T1="$T1" '/^=== pod/{p=$3; if(p>mx)mx=p} /bytes from/{ts=$1; gsub(/[\[\]]/,"",ts); ts+=0; if(ts<T1 && ts>pre[p])pre[p]=ts} END{n=0; for(q=0;q<=mx;q++) if(T1-pre[q]>3) n++; print n}' "$OUT/raw-r$rep.txt")
  VALID=yes
  if [ "${NSHORT:-0}" != 0 ]; then VALID=no; warn "repetition $rep: $NSHORT pod(s) have no replies after the failure was removed: measurement window not covered (INVALID)"; fi
  if [ "${NPRE:-0}" != 0 ]; then VALID=no; warn "repetition $rep: $NPRE pod(s) were not answering in the 3 s before the failure: the traffic was already interrupted (INVALID; report it as a result of its own)"; fi
  [ "$VALID" = no ] && INVALID=$((INVALID+1))
  analyse "$OUT/raw-r$rep.txt" "$T1" "$T2" "$OUT/events-r$rep.txt" > "$OUT/pods-r$rep.txt"
  OPEN=$(awk '$6>0{n++} END{print n+0}' "$OUT/pods-r$rep.txt"); MULTI=$(awk '$5>1{n++} END{print n+0}' "$OUT/pods-r$rep.txt")
  FOS=$(awk '{printf "%s ", $2}' "$OUT/pods-r$rep.txt"); RSS=$(awk '{printf "%s ", $3}' "$OUT/pods-r$rep.txt")
  AFF=$(awk '$2>0.5{n++} END{print n+0}' "$OUT/pods-r$rep.txt")
  LF=$(awk 'BEGIN{m=0} $2>m{m=$2} END{print m}' "$OUT/pods-r$rep.txt"); LR=$(awk 'BEGIN{m=0} $3>m{m=$3} END{print m}' "$OUT/pods-r$rep.txt")
  printf '  %-4s %-26s %-26s %s / %s / %s   (port at failure: machine %s, failed machine %s, role ok: %s, settled: %s, valid: %s, pods not back: %s, pods with >1 gap: %s)\n' "$rep" "$FOS" "$RSS" "$AFF" "$LF" "$LR" "$CRI" "$FM" "$ROLEOK" "$SETTLED" "$VALID" "$OPEN" "$MULTI"
  echo "$rep $LF $AFF $LR $FM $CRM $SETTLED $VALID $CRI $ROLEOK $OPEN $MULTI" >> "$OUT/runs.txt"
  if [ "$UDP" = 1 ]; then
    # UDP of this repetition: what each pod sent (markers) and what the customer host received
    for i in $(seq 0 $((P-1))); do echo "=== pod $i"; rk "$SERVER" "kubectl -n $NS exec fail-$i -- cat /tmp/udp.txt" 2>&1 | tr -d '\r'; done > "$OUT/udp-sent-r$rep.txt"
    nroot "$FABRIC_NODE" <<<'cat /tmp/udp-recv.txt' > "$OUT/udp-recv-r$rep.txt" 2>&1
    # same format as the ping output, so that the same analysis applies: "[arrival] bytes from ..." per pod, then the pod's end
    for i in $(seq 0 $((P-1))); do
      echo "=== pod $i"
      awk -v h="fail-$i" '$3==h {printf "[%s] bytes from udp seq=%s\n", $1, $4}' "$OUT/udp-recv-r$rep.txt"
      awk -v p="$i" '/^=== pod/{q=$3} q==p && /^# end/' "$OUT/udp-sent-r$rep.txt"
    done > "$OUT/udp-raw-r$rep.txt"
    { echo "pod sent received lost"
      for i in $(seq 0 $((P-1))); do
        S=$(awk -v p="$i" '/^=== pod/{q=$3} q==p && /^# sent/{print $3}' "$OUT/udp-sent-r$rep.txt"); S="${S:-0}"
        G=$(awk -v h="fail-$i" '$3==h{n++} END{print n+0}' "$OUT/udp-recv-r$rep.txt")
        echo "$i $S $G $((S-G))"; done; } > "$OUT/udp-count-r$rep.txt"
    analyse "$OUT/udp-raw-r$rep.txt" "$T1" "$T2" "$OUT/udp-events-r$rep.txt" > "$OUT/udp-pods-r$rep.txt"
    UOPEN=$(awk '$6>0{n++} END{print n+0}' "$OUT/udp-pods-r$rep.txt")
    UFOS=$(awk '{printf "%s ", $2}' "$OUT/udp-pods-r$rep.txt"); URSS=$(awk '{printf "%s ", $3}' "$OUT/udp-pods-r$rep.txt")
    UAFF=$(awk '$2>0.5{n++} END{print n+0}' "$OUT/udp-pods-r$rep.txt")
    ULF=$(awk 'BEGIN{m=0} $2>m{m=$2} END{print m}' "$OUT/udp-pods-r$rep.txt"); ULR=$(awk 'BEGIN{m=0} $3>m{m=$3} END{print m}' "$OUT/udp-pods-r$rep.txt")
    ULOST=$(awk 'NR>1{s+=$2; l+=$4} END{printf "%d of %d", l, s}' "$OUT/udp-count-r$rep.txt")
    UNONE=$(awk 'NR>1 && $3==0{n++} END{print n+0}' "$OUT/udp-count-r$rep.txt")
    printf '  %-4s %-26s %-26s %s / %s / %s   (UDP: pods not back: %s, datagrams lost: %s, pods with nothing received: %s)\n' "udp" "$UFOS" "$URSS" "$UAFF" "$ULF" "$ULR" "$UOPEN" "$ULOST" "$UNONE"
    [ "$UNONE" = 0 ] || warn "repetition $rep: $UNONE pod(s) delivered no UDP datagram at all (sender or receiver not working?)"
    [ -f "$OUT/udp-runs.txt" ] || echo "rep longest_failover_s affected_pods longest_restore_s pods_not_back lost sent valid_ping_rep" > "$OUT/udp-runs.txt"
    echo "$rep $ULF $UAFF $ULR $UOPEN $(awk 'NR>1{s+=$2; l+=$4} END{print l+0, s+0}' "$OUT/udp-count-r$rep.txt") $VALID" >> "$OUT/udp-runs.txt"
  fi
  # the traffic must be back before the next repetition
  # every pod must reach the customer again (one pod = one ECMP hash only)
  _back() { rk "$SERVER" "for i in \$(seq 0 $((P-1))); do kubectl -n $NS exec fail-\$i -- ping -c 2 -W 2 $CUST_HOST_IP >/dev/null 2>&1 || exit 1; done"; }
  WAIT_MSG="waiting for the traffic to come back" waitf 40 5 _back || { BAD=$((BAD+1)); warn "the traffic did not come back after repetition $rep"; }
  sleep 10
done

sec "4. Summary over the VALID repetitions of $R (interruption = longest gap between replies minus the ping interval)"
awk 'function add(g,a,b,af){n[g]++; sa[g]+=a; ssa[g]+=a*a; sb[g]+=b; ssb[g]+=b*b; ff[g]+=af; if(n[g]==1||a<mna[g])mna[g]=a; if(a>mxa[g])mxa[g]=a}
     function out(g,label,  ma,va){ if(!n[g])return; ma=sa[g]/n[g]; va=(n[g]>1)?(ssa[g]-n[g]*ma*ma)/(n[g]-1):0; if(va<0)va=0;
         printf "%-52s n=%d  failover mean %.2f s  sd %.2f  min %.2f  max %.2f  (affected pods, mean %.1f)  restore mean %.2f s\n", label, n[g], ma, sqrt(va), mna[g], mxa[g], ff[g]/n[g], sb[g]/n[g]}
     NR>1 && $8=="yes" && $10!="no"{ add("all",$2,$4,$3); if($6!="-"){ if($5==$6) add("on",$2,$4,$3); else add("off",$2,$4,$3) }; if($7=="yes") add("set",$2,$4,$3) }
     END{ out("all","all valid repetitions"); out("on","router port on the failed machine"); out("off","router port on the other machine"); out("set","valid and settled before") }' "$OUT/runs.txt" | tee "$OUT/summary.txt"
if [ "$UDP" = 1 ] && [ -f "$OUT/udp-runs.txt" ]; then
  echo "  UDP (one way, no reply), per repetition: longest interruption during the failure / pods affected / longest after the restore / pods not back / datagrams lost of sent"
  awk 'NR>1{printf "    rep %s: %s s / %s pods / %s s / %s not back / %s of %s lost%s\n", $1, $2, $3, $4, $5, $6, $7, ($8=="yes"?"":"  (ping window not covered)")}' "$OUT/udp-runs.txt" | tee -a "$OUT/summary.txt"
fi
expect "traffic back after every repetition" 0 "$BAD"
expect "repetitions not valid (window not covered, or traffic already down before the failure)" 0 "$INVALID"
table
echo "  raw ping output, per-pod results, events and summary: $OUT"
[ "$BAD" = 0 ]
