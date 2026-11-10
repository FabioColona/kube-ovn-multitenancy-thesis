#!/bin/bash
# 10-install-sites.sh — installs K3s and Kube-OVN on the two sites, each with its own networks.
#
# What it does : copies lib/ and 02-kube-ovn-setup/ to the site, then runs 02-kube-ovn-setup/10-install-kube-ovn.sh there
#                with the hostname, interface, node address and pod/service/join CIDRs of that site (config.env).
#                The remote script prints its own table of 11 checks; this script adds one line per site.
# Environment  : the lab of config.env, sites without K3s (use 90-reset.sh otherwise)
# Changes      : CHANGES THE MACHINES (installs K3s and Kube-OVN, sets the hostname, as 02-kube-ovn-setup does)
# Requires     : bash >= 3.2, ssh, scp; on the sites: curl, python3, sudo (the password is asked in this terminal)
# Usage        : ./10-install-sites.sh [a|b|both]      (default: both)
# Variables    : SITE_A_*, SITE_B_*, REMOTE_DIR (from config.env)
# Duration     : about 5 minutes per site
# Exit code    : 0 = both sites installed with no FAIL; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (multi-site laboratory)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
WHICH="${1:-both}"
case "$WHICH" in a) LIST="a";; b) LIST="b";; both) LIST="a b";; *) die "usage: $0 [a|b|both]";; esac

for s in $LIST; do
  P=SITE_$(echo "$s" | tr a-z A-Z)
  eval "NAME=\${${P}_NAME} IFACE=\${${P}_IFACE} IP=\${${P}_IP} PODC=\${${P}_POD_CIDR} SVCC=\${${P}_SVC_CIDR} JOINC=\${${P}_JOIN_CIDR}"
  sec "Site $s ($NAME, $IP)"
  info "NIC prefix: $(fix_nic_prefix "$s" 2>/dev/null)"
  push_repo "$s" || die "cannot copy the scripts to site $s"
  info "scripts copied to ~/$REMOTE_DIR"
  ssh_tty "$s" "cd \"\$HOME/$REMOTE_DIR/02-kube-ovn-setup\" && NODE_HOSTNAME='$NAME' NODE_IFACE='$IFACE' NODE_IP='$IP' POD_CIDR='$PODC' SVC_CIDR='$SVCC' JOIN_CIDR='$JOINC' ./10-install-kube-ovn.sh --yes"
  RC=$?
  record "installation on site $s ($NAME)" "exit 0" "exit $RC" "$( [ "$RC" -eq 0 ] && echo PASS || echo FAIL )"
done
table
