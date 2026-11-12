#!/bin/bash
# usage: mkproc.sh <vendor_id> <family> <model> <new dir>
# Makes a stand-in /proc folder (cpuinfo, meminfo, vmstat, sys) for the given CPUID family and model
# (decimal), to be passed to the guest collector with OPS_PUSH_PROC_ROOT.
HERE=$(cd "$(dirname "$0")" && pwd)
vendor="$1"; fam="$2"; model="$3"; dst="$4"
[ -n "$dst" ] || { echo "usage: mkproc.sh <vendor_id> <family> <model> <new dir>" >&2; exit 1; }
[ -e "$dst" ] && { echo "exists: $dst" >&2; exit 1; }
mkdir -p "$dst" && cp -R "$HERE/proc_intel/meminfo" "$HERE/proc_intel/vmstat" "$HERE/proc_intel/sys" "$dst/"
printf 'processor\t: 0\nvendor_id\t: %s\ncpu family\t: %s\nmodel\t\t: %s\nmodel name\t: test CPU family %s model %s\nstepping\t: 1\n' \
    "$vendor" "$fam" "$model" "$fam" "$model" > "$dst/cpuinfo"
