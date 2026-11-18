#!/bin/bash
# usage: bash tests/run_guest_config.sh [port]
# Runs collection_etc/guest_config_push.sh against tests/fake_ops.py (the Operations mock) and checks
# what the mock received: the VM target, the bare-metal target (--target bm: object used or created),
# --target auto, --check, --dry-run, the config file and the failures. Prints one line per check;
# the exit code is 1 when a check failed. Another copy of the script: env GCP=<path>.
HERE=$(cd "$(dirname "$0")" && pwd)
S=${GCP:-$HERE/../collection_etc/guest_config_push.sh}
PORT=${1:-18197}
T=$(mktemp -d /tmp/gcptest.XXXXXX)
PASS=0; FAIL=0; SRV=
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }      # check <text> <condition>
start() {       # start <record dir> [preset json]: a new mock with these objects
    mkdir -p "$1"
    [ -n "${2:-}" ] && printf '%s' "$2" > "$1/preset.json"
    python3 "$HERE/fake_ops.py" "$1" "$PORT" > "$1/server.log" 2>&1 &
    SRV=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        curl -s -o /dev/null "http://127.0.0.1:$PORT/suite-api/api/resources" && return 0
        sleep 0.2
    done
    echo "the mock did not start on port $PORT"; exit 2
}
stop() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=; }
trap 'stop; rm -rf "$T"' EXIT
run() {         # run <out file> <args...>: connection by environment variables, no config file
    local out=$1; shift
    env OPS_HOST="http://127.0.0.1:$PORT" OPS_USER=tester OPS_PASSWORD=testpw OPS_PUSH_CONFIG="$T/none.conf" \
        GCP_ROOT="$ROOT" bash "$S" "$@" > "$out" 2>&1
    echo $? > "$out.rc"
}
rc() { cat "$1.rc"; }
lines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
jget() { python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

# a fake /sys and /proc (GCP_ROOT): a VMware guest and a bare-metal host
mkroot() {      # mkroot <dir> <sys_vendor> <cpu flags>
    mkdir -p "$1/sys/kernel/mm/transparent_hugepage/khugepaged" "$1/sys/kernel/mm/hugepages/hugepages-2048kB" \
             "$1/sys/kernel/mm/hugepages/hugepages-1048576kB" "$1/proc/sys/kernel" "$1/sys/class/dmi/id"
    echo "always [madvise] never" > "$1/sys/kernel/mm/transparent_hugepage/enabled"
    echo "always defer defer+madvise [madvise] never" > "$1/sys/kernel/mm/transparent_hugepage/defrag"
    echo 10000 > "$1/sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs"
    echo 4096 > "$1/sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan"
    echo 0 > "$1/proc/sys/kernel/numa_balancing"
    echo 0 > "$1/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    echo 16 > "$1/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 ro default_hugepagesz=1G hugepagesz=1G hugepages=16" > "$1/proc/cmdline"
    echo "$2" > "$1/sys/class/dmi/id/sys_vendor"
    echo "flags : fpu vme de pse $3 lm" > "$1/proc/cpuinfo"
}
mkroot "$T/root_vm" "VMware, Inc." "hypervisor"
mkroot "$T/root_bm" "Dell Inc." "aes"
mkroot "$T/root_hidden" "Dell Inc." "hypervisor"         # the DMI strings do not name a VM, the CPU flag does
VM1='[{"identifier":"res-vm-1","name":"testvm","adapterKindKey":"VMWARE","resourceKindKey":"VirtualMachine"}]'

echo "== 1. VM target (default): the VirtualMachine object, nothing is created"
D=$T/s1; ROOT=$T/root_vm; start "$D" "$VM1"
run "$D/a.out" --name testvm
check "exit 0" '[ "$(rc "$D/a.out")" = 0 ]'
check "last line: [OPS] testvm Guest properties 10 recorded ... [VirtualMachine]" \
      'tail -n 1 "$D/a.out" | grep -q "^\[OPS\] testvm Guest properties 10 recorded .* \[VirtualMachine\]$"'
check "properties written to res-vm-1 through the plain path" \
      '[ "$(jget "$D/props_paths.jsonl" "[(r[\"id\"], r[\"push_kind\"]) for r in rows]")" = "[('"'"'res-vm-1'"'"', None)]" ]'
check "ten properties under Custom Configuration|Guest with the values of this machine" \
      'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))[\"property-content\"]
v=dict((x[\"statKey\"], x[\"values\"][0]) for x in d)
p=\"Custom Configuration|Guest|\"
assert len(d)==10, len(d)
assert v[p+\"THP enabled\"]==\"madvise\" and v[p+\"THP defrag\"]==\"madvise\" and v[p+\"kernel.numa_balancing\"]==\"0\", v
assert v[p+\"hugepages 1GB nr_hugepages\"]==\"16\" and v[p+\"default_hugepagesz (cmdline)\"]==\"1G\" and v[p+\"khugepaged pages_to_scan\"]==\"4096\", v
assert p+\"Collected At\" in v and p+\"kernel\" in v
" "$D/props.json"'
check "no object was created" '[ ! -f "$D/created.jsonl" ]'
run "$D/b.out" --name nosuchvm
check "unknown VM name: exit 1, the message names --target bm, nothing created" \
      '[ "$(rc "$D/b.out")" = 1 ] && grep -q "VirtualMachine .nosuchvm. not found in Operations" "$D/b.out" && grep -q -- "--target bm" "$D/b.out" && [ ! -f "$D/created.jsonl" ]'
run "$D/c.out" --name testvm --check
check "--check: ready, no property write" 'grep -q "^\[CHECK\] token ok (OpsToken), target vm, testvm -> res-vm-1 \[VirtualMachine\], RESULT: ready$" "$D/c.out" && [ "$(lines "$D/props_paths.jsonl")" = 1 ]'
N=$(lines "$D/requests.jsonl")
run "$D/d.out" --name testvm --dry-run --out "$D/d.csv"
check "--dry-run: no request to Operations, values printed, csv saved" \
      '[ "$(lines "$D/requests.jsonl")" = "$N" ] && grep -q "dry-run: nothing written to Operations" "$D/d.out" && grep -q "^\"THP enabled\",\"madvise\"$" "$D/d.csv"'
stop

echo "== 2. bare-metal target (--target bm): the object is created, then used again"
D=$T/s2; ROOT=$T/root_bm; start "$D" "$VM1"
run "$D/c.out" --target bm --name bm-node01 --check
check "--check without an object: says that the first run creates it, creates nothing" \
      'grep -q "^\[CHECK\] token ok (OpsToken), target bm, no object named .bm-node01. yet. The first run creates it: BareMetalServer of BareMetalPush, RESULT: ready$" "$D/c.out" && [ ! -f "$D/created.jsonl" ]'
run "$D/a.out" --target bm --name bm-node01
check "exit 0, object created: BareMetalServer of BareMetalPush" \
      '[ "$(rc "$D/a.out")" = 0 ] && [ "$(jget "$D/created.jsonl" "[(r[\"name\"], r[\"adapterKindKey\"], r[\"resourceKindKey\"]) for r in rows]")" = "[('"'"'bm-node01'"'"', '"'"'BareMetalPush'"'"', '"'"'BareMetalServer'"'"')]" ]'
check "last line names the object: created now" \
      'tail -n 1 "$D/a.out" | grep -q "^\[OPS\] bm-node01 Guest properties 10 recorded .* \[BareMetalServer of BareMetalPush, created now\]$"'
check "properties written through the push adapter kind" \
      '[ "$(jget "$D/props_paths.jsonl" "[(r[\"id\"], r[\"push_kind\"]) for r in rows]")" = "[('"'"'res-bm-1'"'"', '"'"'BareMetalPush'"'"')]" ]'
run "$D/b.out" --target bm --name bm-node01
check "second run: the same object, not created again" \
      '[ "$(rc "$D/b.out")" = 0 ] && [ "$(lines "$D/created.jsonl")" = 1 ] && tail -n 1 "$D/b.out" | grep -q "created by an earlier run\]$" && [ "$(jget "$D/props_paths.jsonl" "[r[\"id\"] for r in rows]")" = "['"'"'res-bm-1'"'"', '"'"'res-bm-1'"'"']" ]'
run "$D/e.out" --target bm --name BM-NODE01
check "the name is matched without regard to case" '[ "$(lines "$D/created.jsonl")" = 1 ] && [ "$(rc "$D/e.out")" = 0 ]'
run "$D/f.out" --target bm --name bm-node05 --adapter-kind LabPush --resource-kind LabServer
check "--adapter-kind, --resource-kind: kinds of a created object" \
      '[ "$(jget "$D/created.jsonl" "[(r[\"adapterKindKey\"], r[\"resourceKindKey\"]) for r in rows][-1]")" = "('"'"'LabPush'"'"', '"'"'LabServer'"'"')" ] && tail -n 1 "$D/f.out" | grep -q "\[LabServer of LabPush, created now\]$"'
run "$D/g.out" --target bm --name x --adapter-kind "bad kind"
check "a kind with other characters is refused" '[ "$(rc "$D/g.out")" = 1 ] && grep -q "letters, digits, _ . - only" "$D/g.out"'
stop

echo "== 3. bare-metal target: objects that exist already"
D=$T/s3; ROOT=$T/root_bm
start "$D" '[{"identifier":"res-pm-7","name":"bm-node02","adapterKindKey":"BareMetalPush","resourceKindKey":"BareMetalServer"},
{"identifier":"res-hw-3","name":"bm-node03","adapterKindKey":"PhysicalServerAdapter","resourceKindKey":"Server"},
{"identifier":"res-pm-8","name":"bm-node03","adapterKindKey":"BareMetalPush","resourceKindKey":"BareMetalServer"}]'
run "$D/a.out" --target bm --name bm-node02
check "the object that ops_metric_push --target bm created is used (no new object)" \
      '[ "$(rc "$D/a.out")" = 0 ] && [ ! -f "$D/created.jsonl" ] && [ "$(jget "$D/props_paths.jsonl" "[(r[\"id\"], r[\"push_kind\"]) for r in rows]")" = "[('"'"'res-pm-7'"'"', '"'"'BareMetalPush'"'"')]" ]'
run "$D/b.out" --target bm --name bm-node03
check "an object of another adapter is preferred and written through the plain path" \
      '[ "$(rc "$D/b.out")" = 0 ] && [ "$(jget "$D/props_paths.jsonl" "[(r[\"id\"], r[\"push_kind\"]) for r in rows][-1]")" = "('"'"'res-hw-3'"'"', None)" ] && grep -q "2 objects share the name" "$D/b.out" && tail -n 1 "$D/b.out" | grep -q "\[Server of PhysicalServerAdapter, existing object\]$"'
stop

echo "== 4. bare-metal target: failures"
D=$T/s4; ROOT=$T/root_bm; start "$D" "$VM1"
: > "$D/fail_create"
run "$D/a.out" --target bm --name bm-node09
check "Operations refuses the creation: exit 1, the answer and the hint about the account are shown" \
      '[ "$(rc "$D/a.out")" = 1 ] && grep -q "could not be created \[HTTP 403, BareMetalPush / BareMetalServer\]" "$D/a.out" && grep -q "may create objects in Operations" "$D/a.out" && [ ! -f "$D/props_paths.jsonl" ]'
rm -f "$D/fail_create"; : > "$D/fail_lookup"
run "$D/b.out" --target bm --name bm-node09
check "the lookup fails: exit 1, nothing is created" \
      '[ "$(rc "$D/b.out")" = 1 ] && grep -q "object lookup failed \[HTTP 500\]" "$D/b.out" && [ ! -f "$D/created.jsonl" ]'
stop

echo "== 5. --target auto"
D=$T/s5; start "$D" "$VM1"
ROOT=$T/root_vm; run "$D/a.out" --target auto --name testvm
check "a VMware guest: the VM object" 'grep -q "target: vm (auto: this machine is a virtual machine)" "$D/a.out" && tail -n 1 "$D/a.out" | grep -q "\[VirtualMachine\]$"'
ROOT=$T/root_vm; run "$D/b.out" --target auto --name nosuchvm
check "a VMware guest whose name is not in Operations: error, nothing created" '[ "$(rc "$D/b.out")" = 1 ] && [ ! -f "$D/created.jsonl" ]'
ROOT=$T/root_hidden; run "$D/c.out" --target auto --name testvm
check "the CPU flag hypervisor alone is enough: the VM object" 'grep -q "target: vm (auto" "$D/c.out" && [ "$(rc "$D/c.out")" = 0 ]'
ROOT=$T/root_bm; run "$D/d.out" --target auto --name bm-node04
check "a bare-metal host: the object is created" \
      'grep -q "target: bm (auto: this machine is not a virtual machine)" "$D/d.out" && [ "$(lines "$D/created.jsonl")" = 1 ] && tail -n 1 "$D/d.out" | grep -q "created now\]$"'
run "$D/e.out" --target cloud
check "an unknown target is refused" '[ "$(rc "$D/e.out")" = 1 ] && grep -q -- "--target must be one of: vm | bm | auto" "$D/e.out"'
stop

echo "== 6. connection settings: ops_local.conf"
D=$T/s6; ROOT=$T/root_vm; start "$D" "$VM1"
ENC=$(printf 'testpw' | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass "pass:testkey" -base64 -A 2>/dev/null)
printf 'OPS_HOST=http://127.0.0.1:%s\r\nOPS_USER=confuser\r\n# comment\r\nOPS_ENC_KEY=testkey\r\nOPS_PASS_ENC=%s\r\n' "$PORT" "$ENC" > "$D/ops_local.conf"
env -u OPS_HOST -u OPS_USER -u OPS_PASSWORD GCP_ROOT="$ROOT" bash "$S" --config "$D/ops_local.conf" --name testvm > "$D/a.out" 2>&1; echo $? > "$D/a.out.rc"
check "address, account and password from the config file (CR+LF line ends)" \
      '[ "$(rc "$D/a.out")" = 0 ] && grep -q "\"username\": \"confuser\"" "$D/auth.json"'
env -u OPS_PASSWORD OPS_HOST="http://127.0.0.1:$PORT" OPS_USER=envuser GCP_ROOT="$ROOT" bash "$S" --config "$D/ops_local.conf" --name testvm --ops-user argument > "$D/b.out" 2>&1
check "an option comes before the environment variable and the config file" 'grep -q "\"username\": \"argument\"" "$D/auth.json"'
env -u OPS_PASSWORD OPS_USER=envuser GCP_ROOT="$ROOT" bash "$S" --config "$D/ops_local.conf" --name testvm > "$D/c.out" 2>&1
check "an environment variable comes before the config file" 'grep -q "\"username\": \"envuser\"" "$D/auth.json"'
mkdir -p "$D/copy/collection_etc" && cp "$S" "$D/copy/collection_etc/" && cp "$D/ops_local.conf" "$D/copy/"
env -u OPS_HOST -u OPS_USER -u OPS_PASSWORD -u OPS_PUSH_CONFIG GCP_ROOT="$ROOT" bash "$D/copy/collection_etc/guest_config_push.sh" --name testvm > "$D/d.out" 2>&1; echo $? > "$D/d.out.rc"
check "without --config: ops_local.conf one folder above the script is found" '[ "$(rc "$D/d.out")" = 0 ] && grep -q "\"username\": \"confuser\"" "$D/auth.json"'
sed 's/^OPS_ENC_KEY=.*/OPS_ENC_KEY=wrongkey/' "$D/ops_local.conf" > "$D/bad.conf"
env -u OPS_HOST -u OPS_USER -u OPS_PASSWORD GCP_ROOT="$ROOT" bash "$S" --config "$D/bad.conf" --name testvm > "$D/e.out" 2>&1; echo $? > "$D/e.out.rc"
check "a wrong key: exit 1 with the message about the password" '[ "$(rc "$D/e.out")" = 1 ] && grep -q "no Operations password" "$D/e.out"'
env -u OPS_HOST -u OPS_USER -u OPS_PASSWORD GCP_ROOT="$ROOT" bash "$S" --config "$D/none.conf" --name testvm > "$D/f.out" 2>&1; echo $? > "$D/f.out.rc"
check "no config file and no values: exit 1, the message names the file" '[ "$(rc "$D/f.out")" = 1 ] && grep -q "OPS_HOST is empty in .*none.conf \[not found\]" "$D/f.out"'
check "--version" '[ "$(bash "$S" --version)" = "1.1" ]'
stop

echo "== 7. JSON parsing with jq (a machine without python)"
if command -v jq >/dev/null 2>&1; then
    D=$T/s7; ROOT=$T/root_bm
    start "$D" '[{"identifier":"res-hw-3","name":"bm-node03","adapterKindKey":"PhysicalServerAdapter","resourceKindKey":"Server"},
{"identifier":"res-vm-1","name":"testvm","adapterKindKey":"VMWARE","resourceKindKey":"VirtualMachine"}]'
    mkdir -p "$T/bin"
    for c in bash sh env curl jq sed grep head tail tr cut date hostname uname mktemp rm cat sysctl openssl dirname; do
        p=$(command -v "$c") && ln -sf "$p" "$T/bin/$c"
    done
    jrun() {    # like run, with a PATH that has no python
        local out=$1; shift
        env PATH="$T/bin" OPS_HOST="http://127.0.0.1:$PORT" OPS_USER=tester OPS_PASSWORD=testpw OPS_PUSH_CONFIG="$T/none.conf" \
            GCP_ROOT="$ROOT" bash "$S" "$@" > "$out" 2>&1
        echo $? > "$out.rc"
    }
    jrun "$D/a.out" --target bm --name bm-node06
    check "bare-metal host: object created and properties written" \
          '[ "$(rc "$D/a.out")" = 0 ] && tail -n 1 "$D/a.out" | grep -q "\[BareMetalServer of BareMetalPush, created now\]$" && [ "$(jget "$D/props_paths.jsonl" "[(r[\"id\"], r[\"push_kind\"]) for r in rows]")" = "[('"'"'res-bm-1'"'"', '"'"'BareMetalPush'"'"')]" ]'
    jrun "$D/b.out" --target bm --name bm-node06
    check "second run: the same object" '[ "$(lines "$D/created.jsonl")" = 1 ] && tail -n 1 "$D/b.out" | grep -q "created by an earlier run\]$"'
    jrun "$D/c.out" --target bm --name bm-node03
    check "an existing object of another adapter is used" 'tail -n 1 "$D/c.out" | grep -q "\[Server of PhysicalServerAdapter, existing object\]$"'
    jrun "$D/d.out" --target vm --name testvm
    check "VM target" '[ "$(rc "$D/d.out")" = 0 ] && tail -n 1 "$D/d.out" | grep -q "\[VirtualMachine\]$"'
    stop
else
    echo "  (skipped: jq is not installed)"
fi

echo ""
echo "guest_config_push checks: $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
