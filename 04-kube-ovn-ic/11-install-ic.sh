#!/bin/bash
# 11-install-ic.sh — turns on OVN-IC between the two sites.
#
# What it does : labels the gateway node of each site; installs the OVN-IC database on site A (install-ic-server.sh
#                of Kube-OVN v1.13.0, IC_TS_NUM transit switches); applies the ConfigMap ovn-ic-config on both sites;
#                installs the Deployment ovn-ic-controller on both (the official install.sh creates it only if the label
#                was already there); waits until both zones show up in the OVN-IC database.
# Environment  : the two sites installed by 10-install-sites.sh, able to reach each other through the router
# Changes      : CHANGES THE CLUSTERS (a label, a Deployment and a ConfigMap on each, the IC database on site A)
# Requires     : bash >= 3.2, ssh; on site A: curl
# Usage        : ./11-install-ic.sh
# Variables    : SITE_A_*, SITE_B_*, IC_TS_NUM (from config.env); the manifests in manifests/
# Duration     : about 3 minutes
# Exit code    : 0 = both zones registered; 1 = a check failed; 2 = prerequisite missing
# In the thesis: Chapter 5 (OVN-IC installation)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
for s in a b; do rk "$s" 'kubectl get nodes >/dev/null 2>&1' || die "site $s has no working cluster: run ./10-install-sites.sh first"; done
URL="https://raw.githubusercontent.com/kubeovn/kube-ovn/v1.13.0/dist/images/install-ic-server.sh"

sec "1. Gateway nodes"
for s in a b; do
  N="$(eval "echo \${SITE_$(echo "$s" | tr a-z A-Z)_NAME}")"
  rk "$s" "kubectl label node $N ovn.kubernetes.io/ic-gw=true --overwrite" >/dev/null || die "cannot label node $N"
  info "node $N labelled ovn.kubernetes.io/ic-gw=true"
done

sec "2. OVN-IC database on site A"
if rk a 'kubectl -n kube-system get deploy ovn-ic-server >/dev/null 2>&1'; then
  info "already installed"
else
  run_spin "installing the IC database (install-ic-server.sh, $IC_TS_NUM transit switches)" "about 1 minute" \
    ssh_to a "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; curl -fsSL $URL -o /tmp/install-ic-server.sh && TS_NUM=$IC_TS_NUM bash /tmp/install-ic-server.sh" \
    || { tail -15 "$RUN_LOG"; die "install-ic-server.sh failed"; }
fi
run_spin "waiting for ovn-ic-server" "up to 3 minutes" rk a 'kubectl -n kube-system rollout status deploy/ovn-ic-server --timeout=180s' || warn "ovn-ic-server not ready after 3 minutes"

sec "3. ConfigMap and controller on both sites"
for s in a b; do
  M="$HERE/manifests/10-ovn-ic-config-site-$s.yaml"
  ic_subst < "$M" | ssh_to "$s" 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl apply -f -' >/dev/null || die "cannot apply $M"
  info "site $s: ConfigMap ovn-ic-config applied"
  IP="$(eval "echo \${SITE_$(echo "$s" | tr a-z A-Z)_IP}")"
  ic_subst < "$HERE/manifests/11-ovn-ic-controller.yaml" | sed "s|value: \"$SITE_A_IP\"|value: \"$IP\"|" \
    | ssh_to "$s" 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl apply -f -' >/dev/null || die "cannot apply the controller on site $s"
  run_spin "site $s: waiting for ovn-ic-controller" "up to 3 minutes" rk "$s" 'kubectl -n kube-system rollout status deploy/ovn-ic-controller --timeout=180s' || warn "ovn-ic-controller of site $s not ready"
done

sec "4. Zones in the OVN-IC database"
zones_ok() { local o; o="$(ic_icsb_show 2>/dev/null)"; grep -q "availability-zone $SITE_A_AZ" <<<"$o" && grep -q "availability-zone $SITE_B_AZ" <<<"$o"; }
WAIT_MSG="waiting for both zones" waitf 40 3 zones_ok
O="$(ic_icsb_show 2>/dev/null)"
expect "zone $SITE_A_AZ in the IC database" yes "$(grep -q "availability-zone $SITE_A_AZ" <<<"$O" && echo yes || echo no)"
expect "zone $SITE_B_AZ in the IC database" yes "$(grep -q "availability-zone $SITE_B_AZ" <<<"$O" && echo yes || echo no)"
table; RC=$?
info "next: ./20-ic-state.sh"
exit $RC
