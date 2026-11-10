#!/bin/bash
# lib-cni.sh — functions shared by the L3/L4 tests of this folder (20-paper-wall.sh, 21-closed-door.sh, 22-flannel-controller.sh).
# Not run directly: loaded after ../lib/common.sh.
#
# Scenario: two tenants plus a pod in the default namespace; three rounds on the same pods:
#   R1 no policy | R2 default-deny-ingress on tenant-a | R3 allow-list: only tenant-b -> role=frontend.
# Result of one probe = "<http code> <curl exit code>": "200 0" = open, "000 28" = blocked (timeout),
# "000 7" = refused (the connection is rejected, as the K3s policy controller does with an ICMP port-unreachable).

PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"        # seconds for each curl
MAX_STABLE_SECS="${MAX_STABLE_SECS:-30}"   # cap on the wait for a stable result
declare -A IP AGG
PROBE_RESULT=""

# Flows: key, source namespace, source pod, destination pod. Keys start with the round (R1, R2, R3).
FLOWS=(
  "R1_BA tenant-b app-b app-a"       "R1_BF tenant-b app-b frontend-a"
  "R1_DA default app-default app-a"  "R1_DB default app-default app-b"
  "R2_BA tenant-b app-b app-a"       "R2_BF tenant-b app-b frontend-a"
  "R2_DA default app-default app-a"  "R2_DB default app-default app-b"
  "R3_BA tenant-b app-b app-a"       "R3_BF tenant-b app-b frontend-a"
  "R3_DA default app-default app-a"  "R3_DF default app-default frontend-a"
)
declare -A ROUND_NAME=( [R1]="no policy" [R2]="default-deny" [R3]="allow-list" )
dst_ns() { case "$1" in app-b) echo tenant-b;; *) echo tenant-a;; esac; }

# detect_cni: prints flannel | calico | calico-ebpf | cilium-strict | cilium-legacy | unknown.
# CNI_OVERRIDE=<name> forces the answer (use it if the detection is wrong on your cluster).
detect_cni() {
  [ -n "${CNI_OVERRIDE:-}" ] && { echo "$CNI_OVERRIDE"; return; }
  if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    local kpr; kpr=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}' 2>/dev/null)
    case "$kpr" in disabled|false) echo cilium-legacy;; *) echo cilium-strict;; esac
  elif kubectl get ns calico-system >/dev/null 2>&1; then
    local dp; dp=$(kubectl get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null)
    [ "$dp" = BPF ] && echo calico-ebpf || echo calico
  elif ip link show flannel.1 >/dev/null 2>&1; then echo flannel
  else echo unknown; fi
}

# classify "<http> <exit>" -> open | blocked | refused | raw value
classify() { case "$1" in "200 0") echo open;; "000 28") echo blocked;; "000 7") echo refused;; *) echo "${1// /\/}";; esac; }

# ------------------------------------------------------------------ scenario
scenario_up() {
  scenario_down
  kubectl create namespace tenant-a >/dev/null && kubectl create namespace tenant-b >/dev/null || die "cannot create the namespaces"
  kubectl run app-a      --image=nginx:alpine --namespace=tenant-a --labels="app=web,role=backend"  >/dev/null
  kubectl run frontend-a --image=nginx:alpine --namespace=tenant-a --labels="app=web,role=frontend" >/dev/null
  # app-b is both a server (nginx, target of the default -> tenant-b flow) and the client of the tenant-b flows (curl)
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: app-b
  namespace: tenant-b
  labels: {app: web, role: backend}
  annotations: {kubectl.kubernetes.io/default-container: curl}
spec:
  containers:
  - {name: web,  image: "nginx:alpine"}
  - {name: curl, image: "curlimages/curl:8.5.0", command: ["sleep", "3600"]}
YAML
  kubectl run app-default --image=curlimages/curl:8.5.0 --namespace=default --labels="app=web" --command -- sleep 3600 >/dev/null
  local spec
  for spec in "tenant-a app-a" "tenant-a frontend-a" "tenant-b app-b" "default app-default"; do
    # shellcheck disable=SC2086
    set -- $spec
    kubectl wait --for=condition=Ready "pod/$2" -n "$1" --timeout=300s >/dev/null 2>&1 || die "pod $1/$2 not ready after 5 minutes"
  done
  IP[app-a]=$(kubectl get pod app-a -n tenant-a -o jsonpath='{.status.podIP}')
  IP[frontend-a]=$(kubectl get pod frontend-a -n tenant-a -o jsonpath='{.status.podIP}')
  IP[app-b]=$(kubectl get pod app-b -n tenant-b -o jsonpath='{.status.podIP}')
}
scenario_down() {
  kubectl delete namespace tenant-a tenant-b --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl delete pod app-default -n default --ignore-not-found --wait=true >/dev/null 2>&1
  return 0
}
apply_default_deny() {
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress, namespace: tenant-a}
spec: {podSelector: {}, policyTypes: [Ingress]}
YAML
}
apply_allow_list() {
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-from-tenant-b-to-frontend, namespace: tenant-a}
spec:
  podSelector: {matchLabels: {role: frontend}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: tenant-b}}
YAML
}

# ------------------------------------------------------------------ probes
probe_once() {   # ns pod ip -> "<http> <exit>"
  local out rc
  out=$(kubectl exec -n "$1" "$2" -- curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" "http://$3/" 2>/dev/null)
  rc=$?
  echo "${out:-000} $rc"
}
# probe_stable: repeats until two consecutive results are equal (cap MAX_STABLE_SECS); result in PROBE_RESULT.
probe_stable() {   # ns pod ip
  local start=$SECONDS prev="" cur
  while :; do
    cur=$(probe_once "$1" "$2" "$3")
    [ "$cur" = "$prev" ] && break
    prev="$cur"
    [ $((SECONDS-start)) -ge "$MAX_STABLE_SECS" ] && break
    sleep 2
  done
  PROBE_RESULT="$cur"
}
probe_round() {   # R1 | R2 | R3
  local f key sns spod dst
  for f in "${FLOWS[@]}"; do
    read -r key sns spod dst <<<"$f"
    [[ $key == "$1"* ]] || continue
    probe_stable "$sns" "$spod" "${IP[$dst]}"
    AGG[$key]+="${PROBE_RESULT};"
    info "$key  $sns/$spod -> $(dst_ns "$dst")/$dst : $(classify "$PROBE_RESULT")"
  done
}

# run_repetitions <n>: runs the three rounds n times, accumulating the results in AGG.
# If the calling script defines after_deny_hook, it runs right after the default-deny policy is applied.
run_repetitions() {
  local r
  for ((r=1; r<=$1; r++)); do
    sec "Repetition $r of $1"
    scenario_up
    info "R1 - no policy";           probe_round R1
    info "R2 - default-deny-ingress on tenant-a"; apply_default_deny
    if declare -F after_deny_hook >/dev/null; then after_deny_hook; fi
    probe_round R2
    info "R3 - allow-list (tenant-b -> frontend only)"; apply_allow_list
    probe_round R3
  done
  scenario_down
}

# ------------------------------------------------------------------ expectations
# expected_class <enforcing 0|1|2> <key>: what the flow should give.
#   0 = nothing enforces policies; 1 = the CNI drops the packets (timeout); 2 = the K3s controller rejects them (refused).
expected_class() {
  [ "$1" = 0 ] && { echo open; return; }       # nothing enforces policies: everything is open
  local deny=blocked; [ "$1" = 2 ] && deny=refused
  case "$2" in
    R2_BA|R2_BF|R2_DA) echo "$deny";;          # default-deny on tenant-a
    R3_BF) echo open;;                         # allowed by the allow-list
    R3_*) echo "$deny";;
    *) echo open;;
  esac
}
# summarize "a;a;b;" -> "a x2, b x1" (as classes)
summarize() {
  local item out=""
  declare -A cnt=(); local order=()
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    item=$(classify "$item")
    [ -z "${cnt[$item]:-}" ] && order+=("$item")
    cnt[$item]=$(( ${cnt[$item]:-0} + 1 ))
  done < <(echo "$1" | tr ';' '\n')
  for item in "${order[@]}"; do out+="${out:+, }$item x${cnt[$item]}"; done
  echo "$out"
}
# evaluate <enforcing 0|1|2>: records one row per flow in the results table.
evaluate() {
  local f key sns spod dst exp res n status item all_ok
  for f in "${FLOWS[@]}"; do
    read -r key sns spod dst <<<"$f"
    exp=$(expected_class "$1" "$key")
    res="${AGG[$key]:-}"
    if [ -z "$res" ]; then record "${key%%_*} ${ROUND_NAME[${key%%_*}]}: $sns/$spod -> $dst" "$exp" "no data" "NOT RUN"; continue; fi
    all_ok=1; n=0
    while IFS= read -r item; do
      [ -z "$item" ] && continue; n=$((n+1))
      [ "$(classify "$item")" = "$exp" ] || all_ok=0
    done < <(echo "$res" | tr ';' '\n')
    status=FAIL; [ "$all_ok" = 1 ] && status=PASS
    record "${key%%_*} ${ROUND_NAME[${key%%_*}]}: $sns/$spod -> $dst" "$exp x$n" "$(summarize "$res")" "$status"
  done
}

# ================================================================== L7 tests (30-blind-spot, 31-path-guard)
# One namespace with: server (nginx answering 200 on every path), client-http (curl, app=client),
# client-tcp (alpine + nc, app=client), attacker (curl, app=attacker).
L7_NS=""; SERVER_IP=""
l7_up() {   # l7_up <namespace>
  L7_NS=$1
  kubectl delete namespace "$L7_NS" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create namespace "$L7_NS" >/dev/null || die "cannot create the namespace $L7_NS"
  kubectl apply -n "$L7_NS" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: {name: nginx-cfg}
data:
  default.conf: |
    server {
      listen 80;
      location / { return 200 "OK\n"; }
    }
---
apiVersion: v1
kind: Pod
metadata: {name: server, labels: {app: server}}
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports: [{containerPort: 80}]
    volumeMounts: [{name: cfg, mountPath: /etc/nginx/conf.d}]
  volumes: [{name: cfg, configMap: {name: nginx-cfg}}]
---
apiVersion: v1
kind: Pod
metadata: {name: client-http, labels: {app: client}}
spec:
  containers: [{name: curl, image: "curlimages/curl:8.5.0", command: ["sleep", "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: client-tcp, labels: {app: client}}
spec:
  containers: [{name: nc, image: "alpine:3.18", command: ["sleep", "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: attacker, labels: {app: attacker}}
spec:
  containers: [{name: curl, image: "curlimages/curl:8.5.0", command: ["sleep", "3600"]}]
YAML
  local p
  for p in server client-http client-tcp attacker; do
    kubectl wait --for=condition=Ready "pod/$p" -n "$L7_NS" --timeout=300s >/dev/null 2>&1 || die "pod $L7_NS/$p not ready after 5 minutes"
  done
  SERVER_IP=$(kubectl get pod server -n "$L7_NS" -o jsonpath='{.status.podIP}')
  waitf 30 2 l7_http_ok client-http GET /public || die "the test server does not answer"
}
l7_down() { [ -n "$L7_NS" ] && kubectl delete namespace "$L7_NS" --ignore-not-found --wait=false >/dev/null 2>&1; return 0; }

# l7_http <pod> <METHOD> <path>: prints the HTTP status, or "blocked" when the connection does not complete.
l7_http() {
  local c
  c=$(kubectl exec -n "$L7_NS" "$1" -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 5 \
        -X "$2" "http://$SERVER_IP$3" 2>/dev/null)
  if [ -z "$c" ] || [ "$c" = 000 ]; then echo blocked; else echo "$c"; fi
}
l7_http_ok() { [ "$(l7_http "$1" "$2" "$3")" = 200 ]; }

# l7_raw <ascii|redis|tls|binary>: sends a non-HTTP payload from client-tcp; prints "connected" or "blocked".
# (nc exits 0 whenever the TCP connection is established, whatever the server does with the bytes:
#  this shows reachability only, never what the server received.)
l7_raw() {
  local cmd
  case "$1" in
    ascii)  cmd="printf 'HELLO-NON-HTTP\r\n'" ;;
    redis)  cmd="printf '*1\r\n\$4\r\nPING\r\n'" ;;
    tls)    cmd="printf '\x16\x03\x01\x00\x01\x01'" ;;
    binary) cmd="dd if=/dev/urandom bs=32 count=1 2>/dev/null" ;;
    *) die "internal error: unknown payload $1" ;;
  esac
  if kubectl exec -n "$L7_NS" client-tcp -- sh -c "$cmd | nc -w 3 $SERVER_IP 80 >/dev/null 2>&1"; then echo connected; else echo blocked; fi
}

# check_repeated <test> <expected> <n> <command...>: runs the command n times; PASS only if every run prints <expected>.
check_repeated() {
  local name=$1 exp=$2 n=$3 i out all="" ok=1; shift 3
  for ((i = 0; i < n; i++)); do
    out=$("$@" 2>/dev/null); out=${out:-none}
    all+="$out"$'\n'
    [ "$out" = "$exp" ] || ok=0
  done
  local obt; obt=$(printf '%s' "$all" | sort | uniq -c | awk '{printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1}')
  record "$name" "$exp x$n" "$obt" "$([ "$ok" = 1 ] && echo PASS || echo FAIL)"
}
