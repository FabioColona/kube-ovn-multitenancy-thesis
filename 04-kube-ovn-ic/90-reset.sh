#!/bin/bash
# 90-reset.sh — removes K3s and Kube-OVN from the two sites and the IC database member of the third machine.
#
# What it does : copies lib/ and 02-kube-ovn-setup/ to the site and runs 02-kube-ovn-setup/90-reset.sh there.
# Environment  : the lab of config.env
# Changes      : DESTRUCTIVE (both clusters are deleted, with the OVN-IC database)
# Requires     : bash >= 3.2, ssh, scp; sudo on the sites (the password is asked in this terminal)
# Usage        : ./90-reset.sh [a|b|both]      (default: both)
# Variables    : SITE_A_*, SITE_B_*, REMOTE_DIR (from config.env)
# Duration     : about 1 minute per site
# Exit code    : 0 = both sites clean; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
ssh_to r "sudo -n docker rm -f ovn-ic-db >/dev/null 2>&1; sudo -n rm -rf $IC_DB_DIR; true"
for s in a b; do ssh_to "$s" "sudo -n rm -rf $IC_DB_DIR; true"; done
WHICH="${1:-both}"
case "$WHICH" in a) LIST="a";; b) LIST="b";; both) LIST="a b";; *) die "usage: $0 [a|b|both]";; esac
for s in $LIST; do
  sec "Site $s"
  push_repo "$s" || die "cannot copy the scripts to site $s"
  ssh_tty "$s" "cd \"\$HOME/$REMOTE_DIR/02-kube-ovn-setup\" && ./90-reset.sh --yes"
  RC=$?
  record "reset of site $s" "exit 0" "exit $RC" "$( [ "$RC" -eq 0 ] && echo PASS || echo FAIL )"
done
table
