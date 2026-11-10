#!/bin/bash
# 30-apply-vpcs.sh — creates two custom VPCs (one per tenant) with their subnet and test pods, and checks them.
#
# What it does : applies manifests/50-custom-vpcs.yaml, waits until Kube-OVN has bound the namespaces to the subnets,
#                applies 51-custom-pods.yaml, waits for the pods, then checks VPCs, subnets and pod addresses.
# Environment  : cluster with Kube-OVN; the tenants of 10-apply-tenants.sh must exist too (the tests compare with them)
# Changes      : CREATES Kubernetes objects (2 namespaces, 2 VPCs, 2 subnets, 3 pods); nothing on the host
# Requires     : bash >= 4, python3, kubectl
# Usage        : ./30-apply-vpcs.sh
# Variables    : NS_VT, NS_VU, VPC_T, VPC_U, SUBNET_VT, SUBNET_VU, SETTLE_SECONDS (from config.env)
# Duration     : about 1 minute
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (custom VPCs)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

have python3 || die "python3 is required"
need_cluster

sec "Applying manifests"
kubectl apply -f "$HERE/manifests/50-custom-vpcs.yaml" >/dev/null || die "cannot apply manifests/50-custom-vpcs.yaml"
info "applied 50-custom-vpcs.yaml"
wait_bound "$NS_VT" "$SUBNET_VT" && wait_bound "$NS_VU" "$SUBNET_VU" || die "namespaces not bound to their subnets after 2 minutes"
info "namespaces bound to their subnets"
kubectl apply -f "$HERE/manifests/51-custom-pods.yaml" >/dev/null || die "cannot apply manifests/51-custom-pods.yaml"
info "applied 51-custom-pods.yaml"

sec "Waiting for the pods"
for spec in "$NS_VT c-t" "$NS_VT c-t2" "$NS_VU c-u"; do
  # shellcheck disable=SC2086
  set -- $spec
  run_spin "waiting for pod $1/$2" "image download, up to 3 minutes" kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout=180s || warn "pod $1/$2 not Ready after 3 minutes"
done
sleep "$SETTLE_SECONDS"

in_cidr() { python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$1') in ipaddress.ip_network('$2') else 1)" 2>/dev/null && echo yes || echo no; }

sec "Checks"
expect "VPC $VPC_T exists" "$VPC_T" "$(kubectl get vpc "$VPC_T" -o jsonpath='{.metadata.name}' 2>/dev/null)"
expect "VPC $VPC_U exists" "$VPC_U" "$(kubectl get vpc "$VPC_U" -o jsonpath='{.metadata.name}' 2>/dev/null)"
expect "subnet $SUBNET_VT in VPC" "$VPC_T" "$(kubectl get subnet "$SUBNET_VT" -o jsonpath='{.spec.vpc}' 2>/dev/null)"
expect "subnet $SUBNET_VU in VPC" "$VPC_U" "$(kubectl get subnet "$SUBNET_VU" -o jsonpath='{.spec.vpc}' 2>/dev/null)"
CIDR_VT="$(kubectl get subnet "$SUBNET_VT" -o jsonpath='{.spec.cidrBlock}')"; CIDR_VU="$(kubectl get subnet "$SUBNET_VU" -o jsonpath='{.spec.cidrBlock}')"
for spec in "$NS_VT c-t $CIDR_VT" "$NS_VT c-t2 $CIDR_VT" "$NS_VU c-u $CIDR_VU"; do
  # shellcheck disable=SC2086
  set -- $spec
  ip="$(pod_ip "$1" "$2")"
  expect "pod $2 address in $3" yes "$( [ -n "$ip" ] && in_cidr "$ip" "$3" || echo no )"
done
table
