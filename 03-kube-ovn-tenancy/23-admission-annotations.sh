#!/bin/bash
# 23-admission-annotations.sh — test: can a tenant remove the port_security and security_groups annotations of its own
#                               pod, and does a ValidatingAdmissionPolicy on CREATE and UPDATE stop it?
#
# What it does : round A, no policy: in ns-an a pod with both annotations is created; the annotations are removed from the
#                running pod; the script reads from OVN whether the port still has port security and whether the port is
#                still in the port group of the security group (Kube-OVN applies the change to a running pod).
#                Round B, with manifests/32-admission-policy-annotations.yaml and the labels on ns-an: a pod with the
#                annotations is accepted; pods without port_security, or with another security group, are rejected; on a
#                running pod the removal of port_security and the change of the security group are rejected (the OVN state
#                does not change), a harmless annotation is accepted.
# Environment  : a cluster with Kube-OVN and Kubernetes with ValidatingAdmissionPolicy (1.30 or later); kubectl-ko
# Changes      : creates and deletes the namespace ns-an, the security group sg-an, test pods, one policy and its binding;
#                everything is removed at the end, also if the script is interrupted
# Requires     : bash >= 4, kubectl
# Usage        : ./23-admission-annotations.sh
# Variables    : REPETITIONS (rounds A and B are repeated; a row is PASS only if every repetition gives the expected result)
# Duration     : about 4 minutes per repetition
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (the logical_switch annotation and the admission policy; port security and security groups)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl ko nbctl show >/dev/null 2>&1 || die "the kubectl-ko plugin is not available (installed by Kube-OVN in /usr/local/bin)"
NS="ns-an"; SG="sg-an"; PG="ovn.sg.sg.an"
NSM="$HERE/manifests/78-annotation-ns.yaml"; PODS="$HERE/manifests/79-annotation-pods.yaml"; POLICY="$HERE/manifests/32-admission-policy-annotations.yaml"

cleanup() {
  kubectl delete -f "$POLICY" --ignore-not-found >/dev/null 2>&1
  kubectl delete -f "$PODS" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete -f "$NSM" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl wait --for=delete "ns/$NS" --timeout=180s >/dev/null 2>&1   # the next repetition needs the namespace to be gone
  kubectl wait --for=delete "sg/$SG" --timeout=60s >/dev/null 2>&1
}
trap cleanup EXIT
declare -A EXPV GOTV; ORDER=()
# chk <label> <expected> <obtained>: collects the result of one repetition; the table is written at the end
chk() { [ -n "${EXPV[$1]+x}" ] || { ORDER+=("$1"); EXPV[$1]="$2"; GOTV[$1]=""; }; GOTV[$1]+="$3 "; }

for ((REP=1; REP<=REPETITIONS; REP++)); do
tick "round A+B" "$REP" "$REPETITIONS"
cleanup; sleep 5
kubectl apply -f "$NSM" >/dev/null || die "cannot create $NSM"

# try_create <case>: yes (created), no (rejected by the admission policy) or error (the request failed for another reason)
try_create() { admitted apply -f "$PODS" -l "case=$1"; }
wait_pod() { kubectl -n "$NS" wait --for=condition=Ready "pod/$1" --timeout=120s >/dev/null 2>&1; }
# has_port_security <pod>: yes if the logical port of the pod has a port-security entry in OVN
# (error if OVN cannot be read or the port does not exist)
has_port_security() { local o; o="$(kubectl ko nbctl lsp-get-port-security "$1.$NS" 2>/dev/null)" || { echo error; return; }; [ -n "$(printf '%s' "$o" | tr -d '[:space:]')" ] && echo yes || echo no; }
# in_group <pod>: yes if the logical port of the pod is a member of the port group of the security group
in_group() {
  local u g
  u="$(kubectl ko nbctl --bare --columns=_uuid find logical_switch_port "name=$1.$NS" 2>/dev/null)" || { echo error; return; }
  u="$(printf '%s' "$u" | tr -d '[:space:]')"; [ -n "$u" ] || { echo error; return; }
  g="$(kubectl ko nbctl get port_group "$PG" ports 2>/dev/null)" || { echo error; return; }
  grep -q "$u" <<<"$g" && echo yes || echo no
}
# try_annotate <pod> <annotation args...>: yes (accepted), no (rejected by the admission policy) or error
try_annotate() { local p=$1; shift; admitted -n "$NS" annotate pod "$p" --overwrite "$@"; }

sec "Round A: no admission policy"
C="$(try_create free)"; chk "A: pod with both annotations created" yes "$C"
chk "A: the pod is Ready" yes "$(wait_pod an-free && echo yes || echo no)"
sleep "$SETTLE_SECONDS"
chk "A: port security on the port of the pod" yes "$(has_port_security an-free)"
chk "A: port of the pod in the group of $SG" yes "$(in_group an-free)"
chk "A: the tenant removes port_security from the running pod (accepted)" yes "$(try_annotate an-free ovn.kubernetes.io/port_security-)"
chk "A: the tenant removes security_groups from the running pod (accepted)" yes "$(try_annotate an-free ovn.kubernetes.io/security_groups-)"
info "waiting 30 s for Kube-OVN to apply the change"; sleep 30
chk "A: after the removal: port security on the port" no "$(has_port_security an-free)"
chk "A: after the removal: port of the pod in the group of $SG" no "$(in_group an-free)"
kubectl -n "$NS" delete pod an-free --ignore-not-found --wait=true >/dev/null 2>&1

sec "Round B: policy enforce-pod-annotations active"
kubectl label ns "$NS" tenant-isolation=enforced "kubeovn-sg=$SG" --overwrite >/dev/null
kubectl apply -f "$POLICY" >/dev/null || die "cannot create the policy"
info "waiting for the policy to take effect (up to 60 s)"
waitf 30 2 bash -c "! kubectl apply --dry-run=server -f '$PODS' -l case=noanno" || warn "policy not enforced after 60 s"
chk "B: pod with both annotations (legit) created" yes "$(try_create legit)"
chk "B: legit: the pod is Ready" yes "$(wait_pod an-legit && echo yes || echo no)"
sleep "$SETTLE_SECONDS"
chk "B: legit: port security on the port" yes "$(has_port_security an-legit)"
chk "B: legit: port in the group of $SG" yes "$(in_group an-legit)"
chk "B: pod without annotations (noanno) created" no "$(try_create noanno)"
chk "B: pod without port_security (nops) created" no "$(try_create nops)"
chk "B: pod with another security group (othersg) created" no "$(try_create othersg)"
chk "B: UPDATE: remove port_security from a running pod (accepted)" no "$(try_annotate an-legit ovn.kubernetes.io/port_security-)"
chk "B: UPDATE: set port_security to false (accepted)" no "$(try_annotate an-legit ovn.kubernetes.io/port_security=false)"
chk "B: UPDATE: remove security_groups (accepted)" no "$(try_annotate an-legit ovn.kubernetes.io/security_groups-)"
chk "B: UPDATE: change security_groups to sg-other (accepted)" no "$(try_annotate an-legit ovn.kubernetes.io/security_groups=sg-other)"
chk "B: UPDATE: an unrelated annotation (accepted)" yes "$(try_annotate an-legit note=ok)"
sleep 15
chk "B: after the attempts: port security on the port" yes "$(has_port_security an-legit)"
chk "B: after the attempts: port in the group of $SG" yes "$(in_group an-legit)"
done

cleanup; rm -f "$ADMIT_LOG"
for l in "${ORDER[@]}"; do
  u="$(printf '%s\n' ${GOTV[$l]} | sort -u | tr '\n' ' ')"
  if [ "$u" = "${EXPV[$l]} " ]; then expect "$l" "${EXPV[$l]} x$REPETITIONS" "${EXPV[$l]} x$REPETITIONS"
  else expect "$l" "${EXPV[$l]} x$REPETITIONS" "mixed: ${GOTV[$l]}"; fi
done
table
