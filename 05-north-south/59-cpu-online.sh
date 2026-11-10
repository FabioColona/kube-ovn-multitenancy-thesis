#!/bin/bash
# 59-cpu-online.sh — sets how many CPUs are online on one machine (to emulate a smaller machine without recreating the VM).
#
# What it does : takes CPUs offline (or back online) through /sys/devices/system/cpu/cpuN/online, so that the machine has
#                COUNT online CPUs (cpu0 always stays online). "all" brings every CPU back. Prints the online CPUs after the change.
#                Used by the CPU-saturation benchmark of Chapter 6 (gateway and client pods on the same machine with 8, 4, 2 CPUs).
# Environment  : any machine of the test bed. The change does not survive a reboot. Kubernetes still reports the old capacity:
#                pods are not pinned to CPUs (CPU manager "none"), so they simply share the online CPUs.
# Usage        : ./59-cpu-online.sh <machine number> <COUNT|all>      ./59-cpu-online.sh <machine number> show
# Exit code    : 0 = done (or shown); 1 = the machine does not allow CPU hot-unplug or the count is not reached; 2 = usage
# In the thesis: Chapter 6 (throughput with the CPU as the bottleneck)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
M="${ARGS[0]:-}"; C="${ARGS[1]:-}"
[ -n "$M" ] && [ -n "$C" ] || die "usage: ./59-cpu-online.sh <machine> <COUNT|all|show>"
if [ "$C" != show ]; then
nroot "$M" WANT="$C" <<'EOS'
T=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
[ "$WANT" = all ] && WANT=$T
for p in /sys/devices/system/cpu/cpu[0-9]*; do
  n=${p##*cpu}; [ "$n" = 0 ] && continue; [ -w "$p/online" ] || continue
  if [ "$n" -lt "$WANT" ]; then echo 1 > "$p/online" 2>/dev/null; else echo 0 > "$p/online" 2>/dev/null; fi
done
EOS
fi
ON="$(nssh "$M" "cat /sys/devices/system/cpu/online; nproc" | tr '\n' ' ')"
info "machine $M: online CPUs $ON"
if [ "$C" != show ] && [ "$C" != all ]; then
  N="$(nssh "$M" nproc | tr -d '\r')"; [ "$N" = "$C" ] || { warn "machine $M has $N online CPUs, not $C (CPU hot-unplug not allowed?)"; exit 1; }
fi
exit 0
