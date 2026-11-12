#!/bin/bash
# usage: run.sh <name> <seconds> [VAR=value ...] -- <collector args...>
# Runs the collector with the fake perf for <seconds>, stops it, and prints what happened.
HERE=$(cd "$(dirname "$0")" && pwd)
name="$1"; secs="$2"; shift 2
envs=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
shift
O=/tmp/opstest/${name}_$(date +%H%M%S); mkdir -p "$O"
S=${COLLECTOR:-$HERE/../ops_metric_push.sh}
PROC=${PROC:-$HERE/proc_intel}
( env PATH=$HERE/fake_perf_bin:$PATH OPS_PUSH_PROC_ROOT=$PROC FAKE_PERF_LOG=$O/perf.log ${envs[@]+"${envs[@]}"} bash "$S" "$@" > "$O/run.log" 2>&1 & )
sleep "$secs"
bash "$S" --stop > "$O/stop.log" 2>&1
sleep 1
echo "##### $name  dir=$O"
if [ "${SHOW:-brief}" = "full" ]; then cat "$O/run.log"; else grep -v "^ - \(host\|CSV\|Ops tree\|started\|support probe\|mode  \)\|^=====\|^$" "$O/run.log" | cut -c1-230; fi
echo "--- csv"; for f in "$O"/*.csv; do [ -f "$f" ] && cut -c1-${CSVCUT:-400} "$f"; done
echo "--- perf invocations: total $(grep -c . "$O/perf.log" 2>/dev/null), collection runs $(grep -c -- "-I [0-9]*000 \| sleep 5$\| sleep 55$" "$O/perf.log" 2>/dev/null)"
echo "--- leftover: $(ps -ef | grep -E 'opstest/bin/perf|keeper' | grep -v grep | wc -l | tr -d ' ') perf/keeper processes"
echo "$O" > /tmp/opstest/last_dir
