#!/bin/bash
# 32-side-door.sh — test "side-door": what the application really receives behind a Cilium HTTP rule.
#
# What it does : a Python server behind a CiliumNetworkPolicy "only GET /public" records every byte it receives
#                (hash and X-Req identifier). A client then tries:
#                1) five non-HTTP payloads (ascii, redis, mysql-like, binary, tls-like) on port 80, with three
#                   rounds: no policy (positive control: all arrive), HTTP rule (expected: none arrives),
#                   L3/L4 ingressDeny (negative control: none arrives). Each round is run twice: with a client
#                   that closes its sending side right after the payload ("half-closed", rows as in the first
#                   version of the test) and with a client that keeps the connection open. In every round the
#                   same raw client also sends an allowed request (GET /public, own X-Req): it is the control
#                   that tells "blocked because of the content" from "blocked because of how the client
#                   behaves". Under the HTTP rule it must arrive with the connection kept open; with the
#                   half-closed client its row is PASS if it arrives and INCONCLUSIVE if it does not (then
#                   the half-closed payload rows prove nothing by themselves and the kept-open rows decide);
#                2) forbidden HTTP requests (POST /admin, GET /secret, DELETE /public), HTTP_REQUESTS of each,
#                   one new connection per request and a unique X-Req: the client must see 403 AND the
#                   request must never reach the server; GET /public must reach it every time.
#                A FAIL on "reached the server" means: the proxy answered 403 but the request was forwarded
#                anyway (not observed with Cilium 1.18.6, the version used in the thesis).
# Environment  : single-node K3s with Cilium, strict or legacy (phase 13)
# Changes      : CHANGES THE CLUSTER (creates and deletes the namespace side-door)
# Requires     : bash >= 4, kubectl, Cilium cluster running, Internet to pull the python:3.12-alpine image
# Usage        : ./32-side-door.sh [--yes]      (CNI_OVERRIDE=<name> to skip the CNI detection)
# Variables    : REPETITIONS (payload rounds), HTTP_REQUESTS (requests per type, default 30)
# Duration     : about 12 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Section 3.5 (test side-door)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/lib-cni.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail
HTTP_REQUESTS="${HTTP_REQUESTS:-30}"
NS=side-door

have kubectl || die "kubectl not found: install the cluster first (phase 13)"
kubectl get nodes >/dev/null 2>&1 || die "the cluster does not answer: is K3s running? (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)"
CNI=$(detect_cni); info "CNI detected: $CNI"
case "$CNI" in
  cilium-strict|cilium-legacy) ;;
  calico|calico-ebpf) die "Calico has no HTTP rules: use 30-blind-spot.sh" ;;
  flannel) die "Flannel enforces no policy at all: use 20-paper-wall.sh" ;;
  *) die "CNI not recognised: install Cilium with phase 13, or set CNI_OVERRIDE" ;;
esac
confirm "This creates and deletes the namespace $NS on this cluster. Continue?"
trap 'kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

# ------------------------------------------------------------------ client programs (run inside the client pod)
read -r -d '' PY_PAYLOADS <<'PY'
import socket, hashlib, random, sys
ip, rounds, mode, base = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
r = random.Random(42)
P = {
 "ascii":  b"HELLO-NON-HTTP\r\n",
 "redis":  b"*1\r\n$4\r\nPING\r\n",
 "mysql":  bytes([0x4a, 0, 0, 0, 0x0a]) + b"8.0.36\x00" + r.randbytes(60),
 "binary": r.randbytes(256),
 "tls":    bytes([0x16, 3, 1, 0, 0x2e, 1, 0, 0, 0x2a, 3, 3]) + r.randbytes(40),
}
n = 0
for _ in range(rounds):
    n += 1
    rid = base + n
    ok = b"GET /public HTTP/1.1\r\nHost: x\r\nX-Req: %d\r\nConnection: close\r\n\r\n" % rid
    for name, d in list(P.items()) + [("http-ok", ok)]:
        try:
            s = socket.create_connection((ip, 80), timeout=4); s.sendall(d)
            if mode == "halfclose": s.shutdown(socket.SHUT_WR)
            s.settimeout(4); s.recv(200); s.close()
        except Exception:
            pass
        print("%s\t%s\t%s" % (name, hashlib.sha256(d).hexdigest()[:16], rid if name == "http-ok" else "-"))
PY
read -r -d '' PY_HTTP <<'PY'
import sys, http.client
ip, n = sys.argv[1], int(sys.argv[2])
R = [("POST", "/admin"), ("GET", "/secret"), ("DELETE", "/public"), ("GET", "/public")]
i = 0
for _ in range(n):
    for m, p in R:
        i += 1
        try:
            c = http.client.HTTPConnection(ip, 80, timeout=4)
            c.request(m, p, headers={"Host": "x", "X-Req": str(i)})
            st = str(c.getresponse().status); c.close()
        except Exception as e:
            st = "ERR:" + type(e).__name__
        print("%d\t%s %s\t%s" % (i, m, p, st))
PY

# ------------------------------------------------------------------ scenario
sec "Preparing the scenario"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl create namespace "$NS" >/dev/null || die "cannot create the namespace $NS"
kubectl apply -n "$NS" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: {name: srv}
data:
  srv.py: |
    import socket, threading, re, sys, hashlib
    L = threading.Lock()
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", 80)); s.listen(100)
    def h(c):
        c.settimeout(2); d = b""
        try:
            while True:
                x = c.recv(65536)
                if not x: break
                d += x
                if d.startswith((b"GET", b"POST", b"DELETE")) and b"\r\n\r\n" in d: break
        except Exception: pass
        m = re.search(rb"(?i)x-req: *([0-9]+)", d)
        if d:
            with L:
                sys.stdout.write("RX id=%s len=%d sha=%s\n" % (m.group(1).decode() if m else "none", len(d), hashlib.sha256(d).hexdigest()[:16]))
                sys.stdout.flush()
        try:
            if d.startswith((b"GET", b"POST", b"DELETE")):
                c.sendall(b"HTTP/1.1 200 OK\r\ncontent-length: 3\r\nconnection: close\r\n\r\nOK\n")
            else:
                c.sendall(b"ACK\n")
        except Exception: pass
        c.close()
    while True:
        c, a = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
---
apiVersion: v1
kind: Pod
metadata: {name: server, labels: {app: server}}
spec:
  containers:
  - {name: s, image: "python:3.12-alpine", command: ["python3", "-u", "/app/srv.py"], volumeMounts: [{name: c, mountPath: /app}]}
  volumes: [{name: c, configMap: {name: srv}}]
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {app: client}}
spec:
  containers: [{name: c, image: "python:3.12-alpine", command: ["sleep", "3600"]}]
YAML
kubectl wait --for=condition=Ready pod/server pod/client -n "$NS" --timeout=300s >/dev/null 2>&1 || die "pods not ready after 5 minutes"
SRV=$(kubectl get pod server -n "$NS" -o jsonpath='{.status.podIP}')
VER=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium version 2>/dev/null | awk '/^Client:/ {print "Cilium " $2; exit}')
info "server $SRV    ${VER:-Cilium version not readable}"
# status_of <METHOD> <path>: HTTP status seen by the client (000 if nothing answers)
status_of() {
  kubectl -n "$NS" exec client -- python3 -c \
   "import http.client,sys
try:
    c=http.client.HTTPConnection(sys.argv[1],80,timeout=4); c.request(sys.argv[2],sys.argv[3]); print(c.getresponse().status)
except Exception: print('000')" "$SRV" "$1" "$2" 2>/dev/null
}
srv_log() { kubectl -n "$NS" logs server 2>/dev/null; }

# payload_round <label> <all|none> <halfclose|hold> <base id> <all|none|measure>: sends the payloads REPETITIONS times
# and counts, per payload, how many arrived at the server (only the log lines written during this round are examined).
# halfclose = the client closes its sending side right after the payload; hold = it keeps the connection open.
# The last argument is what is expected of the control (the allowed GET /public sent by the same raw client, found in
# the server log by its X-Req): all, none, or measure (PASS if all arrive, INCONCLUSIVE otherwise).
payload_round() {
  local label=$1 want=$2 mode=$3 base=$4 ctl=$5 n=$REPETITIONS before out log name sha got exp id
  before=$(srv_log | wc -l)
  out=$(kubectl -n "$NS" exec client -- python3 -c "$PY_PAYLOADS" "$SRV" "$n" "$mode" "$base" 2>/dev/null)
  [ "$(echo "$out" | grep -c '^http-ok	')" = "$n" ] || warn "$label: the client program did not complete (the rows of this round are not reliable)"
  sleep 3
  log=$(srv_log | tail -n +$((before + 1)))
  for name in ascii redis mysql binary tls; do
    sha=$(echo "$out" | grep -m1 "^$name	" | cut -f2)
    got=0; [ -n "$sha" ] && got=$(echo "$log" | grep -c "sha=$sha")
    exp=0; [ "$want" = all ] && exp=$n
    expect "$label: $name payload reached the server" "$exp/$n" "$got/$n"
  done
  got=0
  for id in $(echo "$out" | grep '^http-ok	' | cut -f3); do grep -q "id=$id " <<< "$log" && got=$((got + 1)); done
  case "$ctl" in
    all)  expect "$label: allowed GET /public from the same raw client reached the server (control)" "$n/$n" "$got/$n" ;;
    none) expect "$label: allowed GET /public from the same raw client reached the server (control)" "0/$n" "$got/$n" ;;
    *)    if [ "$got" = "$n" ]; then record "$label: allowed GET /public from the same raw client reached the server (control)" "$n/$n" "$got/$n" PASS
          else record "$label: allowed GET /public from the same raw client reached the server (control)" "$n/$n" "$got/$n" INCONCLUSIVE; fi ;;
  esac
}
rule_active() { [ "$(status_of POST /admin)" = 403 ]; }
deny_active() { [ "$(status_of GET /public)" = 000 ]; }

# ------------------------------------------------------------------ rounds
sec "Round A - no policy (positive control: every payload must reach the server)"
payload_round "no policy" all halfclose 100000 all
payload_round "no policy, connection kept open" all hold 200000 all

sec "Round B - HTTP rule (only GET /public)"
kubectl apply -n "$NS" -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: l7-get-public}
spec:
  endpointSelector: {matchLabels: {app: server}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts:
    - ports: [{port: "80", protocol: TCP}]
      rules: {http: [{method: GET, path: "/public"}]}
YAML
info "waiting for the HTTP rule to be enforced..."
waitf 60 2 rule_active || warn "the HTTP rule is still not active after 2 minutes"
sleep "${POLICY_SETTLE:-10}"
info "non-HTTP payloads on port 80..."
payload_round "HTTP rule" none halfclose 300000 measure
payload_round "HTTP rule, connection kept open" none hold 400000 all

info "forbidden HTTP requests: $HTTP_REQUESTS of each type, one connection per request..."
before=$(srv_log | wc -l)
sent=$(kubectl -n "$NS" exec client -- python3 -c "$PY_HTTP" "$SRV" "$HTTP_REQUESTS" 2>/dev/null)
sleep 3
log=$(srv_log | tail -n +$((before + 1)))
for req in "POST /admin" "GET /secret" "DELETE /public" "GET /public"; do
  if [ "$req" = "GET /public" ]; then want_status=200; want_rx="$HTTP_REQUESTS/$HTTP_REQUESTS"; else want_status=403; want_rx="0/$HTTP_REQUESTS"; fi
  seen=0; arrived=0
  while IFS=$'\t' read -r id r st; do
    [ "$r" = "$req" ] || continue
    [ "$st" = "$want_status" ] && seen=$((seen + 1))
    grep -q "id=$id " <<< "$log" && arrived=$((arrived + 1))
  done <<< "$sent"
  expect "HTTP rule: $req answered $want_status to the client" "$HTTP_REQUESTS/$HTTP_REQUESTS" "$seen/$HTTP_REQUESTS"
  expect "HTTP rule: $req reached the server"              "$want_rx"                          "$arrived/$HTTP_REQUESTS"
done

sec "Round C - control: L3/L4 ingressDeny (no payload may arrive)"
kubectl delete cnp l7-get-public -n "$NS" >/dev/null
kubectl apply -n "$NS" -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: deny-l4}
spec:
  endpointSelector: {matchLabels: {app: server}}
  ingressDeny:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts: [{ports: [{port: "80", protocol: TCP}]}]
YAML
waitf 60 2 deny_active || warn "the deny rule is still not active after 2 minutes"
payload_round "ingressDeny" none halfclose 500000 none
payload_round "ingressDeny, connection kept open" none hold 600000 none

sec "Results (CNI: $CNI, ${VER:-Cilium}, $REPETITIONS payload rounds, $HTTP_REQUESTS requests per type)"
table
