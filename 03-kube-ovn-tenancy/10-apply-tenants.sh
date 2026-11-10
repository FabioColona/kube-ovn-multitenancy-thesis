#!/bin/bash
# 10-apply-tenants.sh — creates the two tenants (namespaces, private subnets, test pods) and checks them.
#
# What it does : applies manifests/00-namespaces.yaml and 10-subnets.yaml, waits until Kube-OVN has bound the
#                namespaces to their subnets, applies 20-pods.yaml, waits for the pods, then checks that each private subnet exists, is private, is bound to its
#                namespace, and that every pod got an address from the right subnet.
# Environment  : a cluster installed by 02-kube-ovn-setup/10-install-kube-ovn.sh
# Changes      : CREATES Kubernetes objects (3 namespaces, 2 subnets, 4 pods); nothing on the host
# Requires     : bash >= 4, python3, kubectl with access to the cluster
# Usage        : ./10-apply-tenants.sh
# Variables    : NS_T, NS_U, NS_SHARED, SUBNET_T, SUBNET_U (from config.env)
# Duration     : about 1 minute (image download included)
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (tenant subnets)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

have python3 || die "python3 is required"
need_cluster

sec "Applying manifests"
apply() { kubectl apply -f "$HERE/manifests/$1.yaml" >/dev/null || die "cannot apply manifests/$1.yaml"; info "applied $1.yaml"; }
apply 00-namespaces
apply 10-subnets
# Kube-OVN binds a namespace to its subnet asynchronously (it sets the annotation ovn.kubernetes.io/logical_switch
# on the namespace). A pod created BEFORE that stays in the default subnet, so wait for the binding first.
bound() { [ "$(kubectl get ns "$1" -o jsonpath='{.metadata.annotations.ovn\.kubernetes\.io/logical_switch}' 2>/dev/null)" = "$2" ]; }
WAIT_MSG="waiting for the namespaces to be bound" waitf 60 2 bound "$NS_T" "$SUBNET_T" && waitf 60 2 bound "$NS_U" "$SUBNET_U" || die "namespaces not bound to their subnets after 2 minutes"
info "namespaces bound to their subnets"
apply 20-pods

sec "Waiting for the pods"
for spec in "$NS_T t1" "$NS_T t2" "$NS_U u1" "$NS_SHARED d1"; do
  # shellcheck disable=SC2086
  set -- $spec
  run_spin "waiting for pod $1/$2" "image download, up to 3 minutes" kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout=180s || warn "pod $1/$2 not Ready after 3 minutes"
done
info "waiting $SETTLE_SECONDS s for the ACLs of the private subnets"
sleep "$SETTLE_SECONDS"

in_cidr() { python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$1') in ipaddress.ip_network('$2') else 1)" 2>/dev/null && echo yes || echo no; }

sec "Checks"
for s in "$SUBNET_T" "$SUBNET_U"; do
  expect "subnet $s private" true "$(kubectl get subnet "$s" -o jsonpath='{.spec.private}' 2>/dev/null)"
done
expect "namespace $NS_T bound to $SUBNET_T" "$SUBNET_T" "$(kubectl get ns "$NS_T" -o jsonpath='{.metadata.annotations.ovn\.kubernetes\.io/logical_switch}' 2>/dev/null)"
expect "namespace $NS_U bound to $SUBNET_U" "$SUBNET_U" "$(kubectl get ns "$NS_U" -o jsonpath='{.metadata.annotations.ovn\.kubernetes\.io/logical_switch}' 2>/dev/null)"
CIDR_T="$(kubectl get subnet "$SUBNET_T" -o jsonpath='{.spec.cidrBlock}')"; CIDR_U="$(kubectl get subnet "$SUBNET_U" -o jsonpath='{.spec.cidrBlock}')"
CIDR_D="$(kubectl get subnet ovn-default -o jsonpath='{.spec.cidrBlock}')"
for spec in "$NS_T t1 $CIDR_T" "$NS_T t2 $CIDR_T" "$NS_U u1 $CIDR_U" "$NS_SHARED d1 $CIDR_D"; do
  # shellcheck disable=SC2086
  set -- $spec
  ip="$(pod_ip "$1" "$2")"
  expect "pod $2 address in $3" yes "$( [ -n "$ip" ] && in_cidr "$ip" "$3" || echo no )"
done
table
