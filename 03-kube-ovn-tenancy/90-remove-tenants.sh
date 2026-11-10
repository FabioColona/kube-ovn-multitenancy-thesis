#!/bin/bash
# 90-remove-tenants.sh — removes everything created by 10-apply-tenants.sh.
#
# What it does : deletes the three namespaces (and their pods) and the two subnets, then checks they are gone.
# Environment  : cluster with the tenants of 10-apply-tenants.sh
# Changes      : DELETES Kubernetes objects (the cluster itself stays)
# Requires     : bash >= 4, kubectl
# Usage        : ./90-remove-tenants.sh
# Duration     : about 1 minute
# Exit code    : 0 = all removed; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
sec "Deleting"
kubectl delete -f "$HERE/manifests/20-pods.yaml" --wait=true >/dev/null 2>&1
kubectl delete -f "$HERE/manifests/10-subnets.yaml" --wait=true >/dev/null 2>&1
kubectl delete -f "$HERE/manifests/00-namespaces.yaml" --wait=true >/dev/null 2>&1
sec "Checks"
for s in "$SUBNET_T" "$SUBNET_U"; do
  waitf 30 2 bash -c "! kubectl get subnet $s" && record "subnet $s removed" yes yes PASS || record "subnet $s removed" yes no FAIL
done
for n in "$NS_T" "$NS_U" "$NS_SHARED"; do
  waitf 60 2 bash -c "! kubectl get ns $n" && record "namespace $n removed" yes yes PASS || record "namespace $n removed" yes no FAIL
done
table
