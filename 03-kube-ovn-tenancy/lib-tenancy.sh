#!/bin/bash
# lib-tenancy.sh — helpers shared by the scripts of 03-kube-ovn-tenancy. Loaded after lib/common.sh and load_config.
#
# What it provides : need_cluster, pod_ip, in_cidr, wait_pod_ready, probe (ping + TCP 8080), probe_n (repeated probe,
#                    summarized), flow/check_flow (one kind of traffic), who_is/check_who (which server answers),
#                    admitted (was a kubectl request accepted, rejected by an admission policy, or did it fail?).
# A probe that cannot run in the pod (kubectl exec fails, the pod is gone) prints "error", never "blocked": a check that
# expects "blocked" does not pass because the probe could not run.
# Writes files     : none.

need_cluster() {
  have kubectl || die "kubectl not found: run 02-kube-ovn-setup/10-install-kube-ovn.sh first"
  kubectl get nodes >/dev/null 2>&1 || die "no cluster reachable: run 02-kube-ovn-setup/10-install-kube-ovn.sh first"
  kubectl get crd subnets.kubeovn.io >/dev/null 2>&1 || die "Kube-OVN is not installed in this cluster"
}

pod_ip() {   # pod_ip <namespace> <pod>
  kubectl -n "$1" get pod "$2" -o jsonpath='{.status.podIP}' 2>/dev/null
}

# in_cidr <address> <cidr>: prints yes or no.
in_cidr() {
  python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$1') in ipaddress.ip_network('$2') else 1)" 2>/dev/null && echo yes || echo no
}

# wait_pod_ready <namespace> <pod>: waits (with a spinner) until the pod is Ready; the first run downloads the image.
wait_pod_ready() {
  run_spin "waiting for pod $1/$2" "image download, up to 3 minutes" kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout=180s
}

# probe <namespace> <pod> <destination IP>
# Prints: open (ping AND TCP 8080 work) | blocked (neither works) | ping-only | tcp-only (only that one works) |
# error (the two commands did not run in the pod).
probe() {
  local out p t
  out="$(kubectl -n "$1" exec "$2" -- sh -c "ping -c 1 -W 2 $3 >/dev/null 2>&1; echo P=\$?; nc -z -w 2 $3 8080 >/dev/null 2>&1; echo T=\$?" 2>/dev/null)"
  p="$(printf '%s\n' "$out" | sed -n 's/^P=\([0-9]*\).*/\1/p' | head -1)"
  t="$(printf '%s\n' "$out" | sed -n 's/^T=\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$p" ] && [ -n "$t" ] || { echo error; return; }
  [ "$p" = 0 ] && p=1 || p=0
  [ "$t" = 0 ] && t=1 || t=0
  case "$p$t" in 11) echo open;; 00) echo blocked;; 10) echo ping-only;; 01) echo tcp-only;; esac
}

# probe_n <namespace> <pod> <destination IP>: runs probe REPETITIONS times.
# Prints "open x5" when all runs agree, otherwise a count per result ("open 3, blocked 2").
probe_n() {
  local i r out=()
  for ((i=0;i<REPETITIONS;i++)); do tick "probing $2 -> $3" $((i+1)) "$REPETITIONS"; out+=("$(probe "$@")"); done
  clear_line
  r="$(printf '%s\n' "${out[@]}" | sort | uniq -c | awk '{print $2" "$1}' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ "$(printf '%s\n' "${out[@]}" | sort -u | wc -l)" -eq 1 ]; then echo "${out[0]} x$REPETITIONS"; else echo "$r"; fi
}

# check_probe <label> <expected: open|blocked> <namespace> <pod> <destination IP>
check_probe() {
  local got; got="$(probe_n "$3" "$4" "$5")"
  expect "$1" "$2 x$REPETITIONS" "$got"
}

# flow <namespace> <pod> <destination IP> <ping|tcp|ping@SOURCE-IP>
# Prints: ok | blocked | error (the command did not run in the pod). "tcp" means TCP 8080; "ping@A.B.C.D" is a ping
# that uses A.B.C.D as its source address.
flow() {
  local cmd out r
  case "$4" in
    ping@*) cmd="ping -c 1 -W 2 -I ${4#ping@} $3";;
    ping)   cmd="ping -c 1 -W 2 $3";;
    tcp)    cmd="nc -z -w 2 $3 8080";;
    *) die "internal error: flow kind '$4'";;
  esac
  out="$(kubectl -n "$1" exec "$2" -- sh -c "$cmd >/dev/null 2>&1; echo R=\$?" 2>/dev/null)"
  r="$(printf '%s\n' "$out" | sed -n 's/^R=\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$r" ] || { echo error; return; }
  [ "$r" = 0 ] && echo ok || echo blocked
}

# admitted <kubectl arguments...>: runs the kubectl command and prints yes (accepted), no (rejected by a
# ValidatingAdmissionPolicy) or error (any other failure: a missing namespace, the API server not answering...).
# The text of the last rejection or error is left in the file $ADMIT_LOG.
ADMIT_LOG="${TMPDIR:-/tmp}/admitted.$$"
admitted() {
  local e
  if e="$(kubectl "$@" 2>&1 >/dev/null)"; then echo yes
  else
    printf '%s\n' "$e" > "$ADMIT_LOG" 2>/dev/null
    if grep -q "ValidatingAdmissionPolicy" <<<"$e"; then echo no; else echo error; fi
  fi
}

# check_flow <label> <expected: ok|blocked> <namespace> <pod> <destination IP> <ping|tcp|ping@SOURCE-IP>
# Repeats the flow REPETITIONS times; PASS only if every run gives the expected result.
check_flow() {
  local i out=() got
  for ((i=0;i<REPETITIONS;i++)); do tick "probing $4 -> $5 ($6)" $((i+1)) "$REPETITIONS"; out+=("$(flow "$3" "$4" "$5" "$6")"); done
  clear_line
  if [ "$(printf '%s\n' "${out[@]}" | sort -u | wc -l)" -eq 1 ]; then got="${out[0]} x$REPETITIONS"
  else got="$(printf '%s\n' "${out[@]}" | sort | uniq -c | awk '{print $2" "$1}' | paste -sd, - | sed 's/,/, /g')"; fi
  expect "$1" "$2 x$REPETITIONS" "$got"
}

# wait_flow <expected> <seconds> <namespace> <pod> <destination IP> <ping|tcp>: waits until a single run gives the
# expected result (with the progress bar of waitf).
_flow_is() { [ "$(flow "${@:2}")" = "$1" ]; }
wait_flow() {
  local want=$1 secs=$2; shift 2
  WAIT_MSG="${WAIT_MSG:-waiting for the traffic to be $want}" waitf $((secs/2)) 2 _flow_is "$want" "$@"
}

# who_is <namespace> <pod> <destination IP>: prints the content of /who served by the destination (the name of the
# server that answered), or nothing if the request fails.
who_is() {
  kubectl -n "$1" exec "$2" -- wget -qO- -T 3 "http://$3:8080/who" 2>/dev/null | tr -d '\r\n '
}

# check_who <label> <expected name> <namespace> <pod> <destination IP>: repeats who_is REPETITIONS times; PASS only if
# every run returns the expected name.
check_who() {
  local i out=() got
  for ((i=0;i<REPETITIONS;i++)); do tick "asking $5 from $4" $((i+1)) "$REPETITIONS"; out+=("$(who_is "$3" "$4" "$5")"); done
  clear_line
  if [ "$(printf '%s\n' "${out[@]}" | sort -u | wc -l)" -eq 1 ]; then got="${out[0]:-no answer} x$REPETITIONS"
  else got="$(printf '%s\n' "${out[@]}" | sed 's/^$/no-answer/' | sort | uniq -c | awk '{print $2" "$1}' | paste -sd, - | sed 's/,/, /g')"; fi
  expect "$1" "$2 x$REPETITIONS" "$got"
}

# seen_source <namespace> <pod> <destination IP>: prints the source address the destination sees
# (asks the destination's /cgi-bin/ip over HTTP; empty if the request fails).
seen_source() {
  # busybox httpd writes IPv4 clients as [::ffff:a.b.c.d]: strip the IPv6 wrapper.
  kubectl -n "$1" exec "$2" -- wget -qO- -T 3 "http://$3:8080/cgi-bin/ip" 2>/dev/null | tr -d '\r\n ' | sed 's/^\[::ffff:\(.*\)\]$/\1/'
}

# wait_bound <namespace> <subnet>: waits until Kube-OVN has bound the namespace to the subnet (a pod created earlier
# would stay in the default subnet).
wait_bound() {
  WAIT_MSG="waiting for $1 to be bound to $2" waitf 60 2 bash -c "[ \"\$(kubectl get ns '$1' -o jsonpath='{.metadata.annotations.ovn\\.kubernetes\\.io/logical_switch}' 2>/dev/null)\" = '$2' ]"
}

# route_listed <router> <text>: succeeds when the logical router's route list contains <text>.
route_listed() {
  local out; out="$(kubectl ko nbctl lr-route-list "$1" 2>/dev/null)"
  grep -qF -- "$2" <<<"$out"
}
