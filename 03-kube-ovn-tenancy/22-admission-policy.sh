#!/bin/bash
# 22-admission-policy.sh — test: can a pod join another tenant's subnet with the logical_switch annotation, and does
#                          a ValidatingAdmissionPolicy stop it?
#
# What it does : round A, no policy: a pod created in ns-u with the annotation ovn.kubernetes.io/logical_switch=sub-t
#                is created, gets an address of sub-t and reaches t1 (the subnet binding spec.namespaces does not prevent it).
#                Round B, with manifests/31-admission-policy.yaml and the labels on the namespaces: the same pod is
#                rejected; a legitimate pod in ns-t is accepted; a pod in ns-shared (not covered) is still accepted.
# Environment  : cluster with the tenants of 10-apply-tenants.sh (Kubernetes with ValidatingAdmissionPolicy, 1.30 or later)
# Changes      : creates and deletes test pods, one policy and its binding, and two labels on ns-t and ns-u;
#                everything is removed at the end, also if the script is interrupted
# Requires     : bash >= 4, python3, kubectl
# Usage        : ./22-admission-policy.sh
# Variables    : NS_T, NS_U, NS_SHARED, SUBNET_T, SUBNET_U (from config.env)
# Duration     : about 3 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (the logical_switch annotation and the admission policy)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

have python3 || die "python3 is required"
need_cluster
PODS="$HERE/manifests/30-intruder-pods.yaml"; POLICY="$HERE/manifests/31-admission-policy.yaml"
T1="$(pod_ip "$NS_T" t1)"; [ -n "$T1" ] || die "test pods not found: run ./10-apply-tenants.sh first"
CIDR_T="$(kubectl get subnet "$SUBNET_T" -o jsonpath='{.spec.cidrBlock}')"
in_cidr() { python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$1') in ipaddress.ip_network('$2') else 1)" 2>/dev/null && echo yes || echo no; }

cleanup() {
  kubectl delete -f "$PODS" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete -f "$POLICY" --ignore-not-found >/dev/null 2>&1
  kubectl label ns "$NS_T" "$NS_U" tenant-isolation- kubeovn-subnet- >/dev/null 2>&1
  rm -f "$ADMIT_LOG"
}
trap cleanup EXIT
cleanup; sleep 3

# try_create <case>: creates the pod of the given case; prints yes (created), no (rejected by the admission policy)
# or error (the request failed for another reason).
try_create() { admitted apply -f "$PODS" -l "case=$1"; }
pod_of() { case "$1" in intruder) echo "$NS_U";; legit) echo "$NS_T";; outsider) echo "$NS_SHARED";; esac; }
wait_pod() { kubectl -n "$(pod_of "$1")" wait --for=condition=Ready "pod/$1" --timeout=120s >/dev/null 2>&1; }
drop_pod() { kubectl -n "$(pod_of "$1")" delete pod "$1" --ignore-not-found --wait=true >/dev/null 2>&1; }

sec "Round A: no admission policy"
C="$(try_create intruder)"; expect "A: intruder (ns-u asks for $SUBNET_T) created" yes "$C"
if [ "$C" = yes ] && wait_pod intruder; then
  IP="$(pod_ip "$NS_U" intruder)"
  expect "A: intruder address in $SUBNET_T ($CIDR_T)" yes "$(in_cidr "$IP" "$CIDR_T")"
  check_probe "A: intruder -> t1 (ping + TCP 8080)" open "$NS_U" intruder "$T1"
else
  record "A: intruder address in $SUBNET_T ($CIDR_T)" yes "pod not Ready" FAIL
  record "A: intruder -> t1 (ping + TCP 8080)" "open x$REPETITIONS" "pod not Ready" FAIL
fi
drop_pod intruder

sec "Round B: policy restrict-logical-switch active"
kubectl label ns "$NS_T" tenant-isolation=enforced "kubeovn-subnet=$SUBNET_T" --overwrite >/dev/null
kubectl label ns "$NS_U" tenant-isolation=enforced "kubeovn-subnet=$SUBNET_U" --overwrite >/dev/null
kubectl apply -f "$POLICY" >/dev/null || die "cannot create the policy"
info "waiting for the policy to take effect (up to 60 s)"
waitf 30 2 bash -c "! kubectl apply --dry-run=server -f '$PODS' -l case=intruder" || warn "policy not enforced after 60 s"
expect "B: intruder (ns-u asks for $SUBNET_T) created" no "$(try_create intruder)"
[ -s "$ADMIT_LOG" ] && info "rejection: $(tail -1 "$ADMIT_LOG" | cut -c1-300)"
drop_pod intruder   # in case it was created anyway
C="$(try_create legit)"; expect "B: legit (ns-t asks for $SUBNET_T) created" yes "$C"
if [ "$C" = yes ] && wait_pod legit; then
  expect "B: legit address in $SUBNET_T ($CIDR_T)" yes "$(in_cidr "$(pod_ip "$NS_T" legit)" "$CIDR_T")"
else
  record "B: legit address in $SUBNET_T ($CIDR_T)" yes "pod not Ready" FAIL
fi
# Limit: the policy is bound only to labelled namespaces.
C="$(try_create outsider)"; expect "B: outsider (ns-shared, not covered) created" yes "$C"
if [ "$C" = yes ] && wait_pod outsider; then
  check_probe "B: outsider -> t1 (ping + TCP 8080)" open "$NS_SHARED" outsider "$T1"
else
  record "B: outsider -> t1 (ping + TCP 8080)" "open x$REPETITIONS" "pod not Ready" FAIL
fi
table
