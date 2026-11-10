#!/bin/bash
# 00-preflight.sh — checks whether this machine can host a single-node Kube-OVN cluster.
#
# What it does : reads the machine and reports: OS, kernel, CPU, memory, disk, tools, Internet access,
#                root/sudo, kernel modules (openvswitch, geneve), Open vSwitch already running on the host,
#                overlap of pod/service/join CIDRs, K3s or Kube-OVN already installed.
# Environment  : any Linux machine (x86_64 or aarch64) with systemd
# Changes      : READ-ONLY (changes nothing, asks nothing)
# Requires     : bash >= 4, python3 (optional: only for the CIDR overlap check)
# Usage        : ./00-preflight.sh
# Variables    : POD_CIDR, SVC_CIDR, JOIN_CIDR, NODE_IFACE, NODE_IP (from config.env)
# Duration     : a few seconds
# Exit code    : 0 = no FAIL; 1 = at least one FAIL
# In the thesis: Chapter 5 (test bed: environment of the Kube-OVN tests)

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
[ "$(nproc)" -ge 2 ] && ok "CPUs: $(nproc)" || wrn "1 CPU: Kube-OVN will be very slow, 2 or more recommended"
FREE=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9); [ "${FREE:-0}" -ge 10 ] && ok "disk space in /var/lib: ${FREE} GB" || wrn "little space in /var/lib (${FREE:-?} GB): at least 10 GB recommended"

sec "2. Root or sudo"
if [ "$(id -u)" = 0 ]; then ok "running as root"
elif have sudo; then
  if sudo -n true 2>/dev/null; then ok "sudo works without a password"
  else ok "sudo available: the scripts will ask for the password once, at the start"; fi
else bad "neither root nor sudo: the install script needs root"; fi

sec "3. Tools"
for t in curl awk sed grep ip; do have "$t" && ok "$t" || bad "$t not found"; done
have kubectl || info "kubectl: not found (K3s installs its own, no action needed)"

sec "4. Internet access (K3s, Kube-OVN manifest, container images)"
for u in https://get.k3s.io https://raw.githubusercontent.com https://registry-1.docker.io; do
  # any HTTP answer counts (the Docker registry answers 401 without credentials)
  if have curl && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null)" != 000 ]; then ok "$u reachable"; else wrn "$u NOT reachable (proxy or firewall?)"; fi
done

sec "5. Kernel modules (Kube-OVN needs openvswitch; tunnels use geneve)"
for m in openvswitch geneve; do
  if grep -q "^$m " /proc/modules 2>/dev/null; then ok "$m loaded"
  elif have modinfo && modinfo "$m" >/dev/null 2>&1; then ok "$m available (the installer loads it)"
  else
    [ "$m" = openvswitch ] && bad "$m not available: Kube-OVN cannot work on this kernel" \
                           || wrn "$m not available as a module (it may be built into the kernel)"
  fi
done

sec "6. Open vSwitch on the host (it would conflict with the one inside Kube-OVN)"
if systemctl is-active --quiet openvswitch-switch 2>/dev/null || systemctl is-active --quiet ovs-vswitchd 2>/dev/null || pgrep -x ovs-vswitchd >/dev/null 2>&1; then
  wrn "Open vSwitch is running on the host: set ALLOW_STOP_HOST_OVS=yes in config.local.env, or stop it yourself"
else ok "no Open vSwitch running on the host"; fi

sec "7. Networks"
IFACE_NOW="${NODE_IFACE:-$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)}"
IP_NOW="${NODE_IP:-$(ip -4 -o addr show dev "$IFACE_NOW" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)}"
[ -n "$IFACE_NOW" ] && [ -n "$IP_NOW" ] && ok "node interface $IFACE_NOW, address $IP_NOW" || bad "cannot determine interface/address: set NODE_IFACE and NODE_IP in config.local.env"
echo "pod $POD_CIDR   service $SVC_CIDR   join $JOIN_CIDR"
if have python3 && have ip; then
  python3 - "$POD_CIDR" "$SVC_CIDR" "$JOIN_CIDR" <<'PY'
import ipaddress, subprocess, sys
names = ["pod", "service", "join"]
nets = [ipaddress.ip_network(a) for a in sys.argv[1:4]]
clash = False
for i in range(3):
    for j in range(i + 1, 3):
        if nets[i].overlaps(nets[j]):
            print(f"  {names[i]} {nets[i]} overlaps with {names[j]} {nets[j]}"); clash = True
host = subprocess.run(["ip", "-4", "-o", "route"], capture_output=True, text=True).stdout.split("\n")
host += subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True).stdout.split("\n")
for line in host:
    if any(x in line for x in ("ovn0", "br-int", "ovs-system")): continue   # left by a previous Kube-OVN, not a real conflict
    for tok in line.split():
        if "/" in tok and tok[0].isdigit():
            try: n = ipaddress.ip_network(tok, strict=False)
            except ValueError: continue
            if n.prefixlen == 0: continue
            for k in range(3):
                if n.overlaps(nets[k]):
                    print(f"  {names[k]} {nets[k]} overlaps with {n} ({line.strip()[:60]})"); clash = True
sys.exit(1 if clash else 0)
PY
  case $? in
    0) ok "pod, service and join networks do not overlap with each other nor with the machine";;
    1) bad "overlap: choose other values in config.local.env";;
    *) wrn "overlap check failed to run";;
  esac
else wrn "python3 or ip not found: overlap not checked"; fi

sec "8. State left by previous installations"
if k3s_installed; then bad "K3s is already installed: run ./90-reset.sh before a new installation"; else ok "K3s not installed"; fi
for d in /etc/origin/ovn /etc/origin/openvswitch; do
  [ -e "$d" ] && wrn "$d exists (left by a previous Kube-OVN: ./90-reset.sh removes it)" || ok "$d absent"
done
ip link show ovn0 >/dev/null 2>&1 && wrn "interface ovn0 exists (previous Kube-OVN)" || ok "interface ovn0 absent"

summary
