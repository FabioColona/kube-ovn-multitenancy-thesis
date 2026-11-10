#!/bin/bash
# 00-preflight.sh — checks whether this machine is ready for the flat-network CNI tests.
#
# What it does : reads the machine and reports: OS, kernel, CPU, memory, disk, tools, Internet access,
#                root/sudo, pod CIDR overlap, K3s already installed, leftover CNI rules.
# Environment  : any Linux machine (x86_64 or aarch64) with systemd
# Changes      : READ-ONLY (changes nothing, asks nothing)
# Requires     : bash >= 4
# Usage        : ./00-preflight.sh
# Variables    : K3S_VERSION, POD_CIDR (from config.env)
# Duration     : a few seconds
# Exit code    : 0 = no FAIL; 1 = at least one FAIL
# In the thesis: Section 3.5 (environment of the flat-network CNI tests)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
set -uo pipefail

sec "1. Machine"
echo "host: $(hostname)   user: $(id -un) (uid $(id -u))"
[ -r /etc/os-release ] && { . /etc/os-release; echo "OS: ${PRETTY_NAME:-?}"; }
echo "kernel: $(uname -r)   architecture: $(uname -m)"
case "$(uname -m)" in x86_64|aarch64) ok "supported architecture";; *) bad "architecture $(uname -m) not supported";; esac
[ -d /run/systemd/system ] && ok "systemd present" || bad "systemd not found: K3s needs it"
echo "CPUs: $(nproc)   memory: $(free -m 2>/dev/null | awk 'NR==2{print $2" MB"}')   virtualization: $(systemd-detect-virt 2>/dev/null; true)"
MEM=$(free -m 2>/dev/null | awk 'NR==2{print $2}'); [ "${MEM:-0}" -ge 3500 ] && ok "memory sufficient (${MEM} MB)" || wrn "low memory (${MEM:-?} MB): at least 4 GB recommended"
FREE=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9); [ "${FREE:-0}" -ge 10 ] && ok "disk space in /var/lib: ${FREE} GB" || wrn "little space in /var/lib (${FREE:-?} GB): at least 10 GB recommended"

sec "2. Root or sudo"
CAN_ROOT=0
if [ "$(id -u)" = 0 ]; then ok "running as root"; CAN_ROOT=1
elif have sudo; then
  if sudo -n true 2>/dev/null; then ok "sudo works without a password"; CAN_ROOT=1
  else ok "sudo available: the scripts will ask for the password once, at the start"; fi
else bad "neither root nor sudo: the install scripts need root"; fi

sec "3. Tools"
for t in curl tar awk sed grep ip kubectl iptables-save; do
  if have "$t"; then ok "$t"
  else case "$t" in
    kubectl) info "kubectl: not found (K3s installs its own, no action needed)";;
    iptables-save) wrn "iptables-save not found: leftover rules cannot be counted";;
    *) bad "$t not found";; esac
  fi
done

sec "4. Internet access (needed to download K3s, Calico, Cilium and the images)"
for u in https://get.k3s.io https://github.com https://raw.githubusercontent.com; do
  if have curl && curl -sfI --max-time 8 "$u" >/dev/null 2>&1; then ok "$u reachable"; else wrn "$u NOT reachable (proxy or firewall?)"; fi
done

sec "5. Pod CIDR ($POD_CIDR) against the machine's own networks"
if have python3 && have ip; then
  python3 - "$POD_CIDR" <<'PY'
import ipaddress, subprocess, sys
want = ipaddress.ip_network(sys.argv[1])
out = subprocess.run(["ip", "-4", "-o", "route"], capture_output=True, text=True).stdout.split("\n")
out += subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True).stdout.split("\n")
clash = False
for line in out:
    for tok in line.split():
        if "/" in tok and tok[0].isdigit():
            try: n = ipaddress.ip_network(tok, strict=False)
            except ValueError: continue
            if n.prefixlen > 0 and n.overlaps(want):
                print("  overlaps with", n, "(", line.strip()[:70], ")"); clash = True
sys.exit(1 if clash else 0)
PY
  case $? in
    0) ok "no overlap with addresses or routes of this machine";;
    1) bad "overlap: choose another POD_CIDR in config.local.env";;
    *) wrn "overlap check failed to run";;
  esac
else wrn "python3 or ip not found: overlap not checked"; fi

sec "6. State left by previous tests"
if k3s_installed; then bad "K3s is already installed: run ./90-reset.sh before a new installation"; else ok "K3s not installed"; fi
if [ "$CAN_ROOT" = 1 ] && have iptables-save; then
  # shellcheck disable=SC2034  # SUDO is read by as_root / count_rules in lib/common.sh
  [ "$(id -u)" = 0 ] && SUDO="" || SUDO="sudo"
  for p in 'KUBE-NWPLCY' 'cali-' 'CILIUM'; do
    n=$(count_rules "$p"); [ "$n" -eq 0 ] && ok "no '$p' rules" || wrn "$n '$p' rules left over: ./90-reset.sh removes them"
  done
else info "leftover rules not counted (needs root or passwordless sudo)"; fi

summary
