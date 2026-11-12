#!/bin/python
# -*- coding: utf-8 -*-
# =====================================================================
#  USER SETTINGS  -  edit this block only (everything below is logic)
# =====================================================================
# Connection settings are NOT in this script. They are read from ops_local.conf
# (KEY=VALUE lines):
#   OPS_HOST       VCF Operations address or IP     (--ops-host or env OPS_HOST overrides)
#   OPS_USER       Operations account               (--ops-user or env OPS_USER overrides)
#   OPS_PASS_ENC   encrypted password               (--pass-file or env OPS_PASSWORD overrides)
#   OPS_ENC_KEY    key that decrypts OPS_PASS_ENC
# The file is looked for beside this script, then in the folder above it
# (another place: --config PATH or env OPS_PUSH_CONFIG). It is read as text, never executed.
# It holds the credential: chmod 600. Git holds this file with the keys only; never commit it with values.
CONFIG_NAME      = "ops_local.conf"
OPS_AUTHSOURCE   = "LOCAL"                        # Operations auth source
OPS_INSECURE_DEFAULT = True                       # True = skip TLS verification (same as --insecure)

# Password scheme, the same as in the shell collectors (their --encrypt makes OPS_PASS_ENC):
#   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass pass:<OPS_ENC_KEY> -base64 -A

OPS_HOST_NAME_DEFAULT = ""        # HostSystem object name in Operations; "" = esxcli system hostname FQDN
INTERVAL_DEFAULT = 60             # seconds between readings
OUT_DIR_DEFAULT  = "/tmp/vmkperf" # CSV directory; use a datastore path, e.g. /vmfs/volumes/datastore1/vmkperf
MODE_DEFAULT     = "ops"          # ops = Operations push only (no file on the host) | file = CSV only | both
GROUPS_DEFAULT   = ""             # pCPU groups, e.g. "VM1=0-15,VM2=16-31"; only for VMs pinned to disjoint pCPUs
STAT_ROOT        = "Custom Metrics|Host Perf"      # metric group in Operations (metrics appear as Host Perf|LLC_Miss ...)

# LLC occupancy per rmID (the qos_monitor data), read from vsish every interval alongside vmkperf
QOS_ENABLE = False                # default off; True here or --qos on the command line turns it on
QOS_ROOT   = "/sched/qos/resources/llc"
QOS_LEAF   = ""                   # occupancy leaf under rmID/<r>/ ; "" = auto-detect ('qosprobe' lists candidates)
QOS_RMIDS  = "reserved"           # "reserved" = rmID 0 + every rmID with reserved=1 | "all" | "0,1,2"
# =====================================================================

"""
vmkperf_ops_push.py v1.5 - ESXi host PMU collector -> VCF Operations custom metrics

v1.5 (2026-11-12): the metrics are the designed ones again (events/metrics.json, 15 metrics)
  - one metrics file for every CPU: events/metrics.json, as in v1.0. The AMD metric files
    events/metrics_amd.json and events/metrics_amd_zen2.json of v1.1 .. v1.4 are gone.
  - the AMD event files (naples, rome, milan, genoa, turin .json) hold the two events of the
    designed set that an AMD core counter has: cycles (PMCx076) and instr (PMCx0C0). The other
    seven event keys of the designed set (llc_miss, llc_ref, l3_load_miss, l3miss_rd,
    l3miss_rd_outst, l3_stall, l3_load_hit) have no AMD core event, so the files do not hold them.
    On an AMD host Cycles, Instructions and IPC have values; the other twelve metrics have
    no input, stay empty in the CSV and are not pushed. 'check' and the start log name them.
  - taken out: the AMD-only event keys of v1.1 .. v1.4 (l2_dtlb_miss, dc_fill_mem, l2_miss,
    dc_fill_all, dmnd_fill_mem, dmnd_fill_all, l1_dtlb_miss, l2_itlb_miss, dc_fill_l3) and the
    metrics that used them.
  - 'probe' and 'worldprobe' use cycles / instr on an event file that holds nothing else.
  Intel hosts behave as in v1.0: events/metrics.json and the three Intel event files are the
  files of v1.0. The versions with the AMD metrics stay in Git under their tags
  (vmkperf_ops_push-v1.4 and earlier).

v1.4 (2026-11-12): event key dc_fill_l3 and three L1D_Fill_L3 metrics for AMD Zen 3, 4 and 5.
  [removed in v1.5]

v1.3 (2026-11-12): connection settings moved out of the script
  - the Operations address, account, encrypted password and its key are read from
    ops_local.conf (beside this script, then the folder above; --config PATH or env
    OPS_PUSH_CONFIG for another place). The script holds no address and no credential,
    so it can be kept in Git; Git holds ops_local.conf with the keys only.
  - --cred-from and the search for an ops_metric_push_v4*.sh beside the script are gone:
    the config file is the one place for the credential.
  - OPS_HOST may be a host name or IP (https is used) or a full http(s):// address,
    as in the shell collectors that share the config file.
  Collection is as in v1.2.

v1.2 (2026-11-12): AMD hosts of every Zen generation that ESXi 8.0 and later support
  - events/naples.json (Zen 1), rome.json (Zen 2), milan.json (Zen 3), genoa.json (Zen 4)
    next to turin.json (Zen 5). Codes come from the Linux kernel event list of each
    generation (tools/perf/pmu-events/arch/x86/amdzen1 .. amdzen5).
  - events/cpu_map.json: the CPUID family-model values the Broadcom Compatibility Guide
    lists for ESXi 8.0 and later, plus the model ranges the kernel uses to choose the list
  - a metric whose input event is not in the event file of the CPU stays empty in the CSV
    and is not pushed; 'check' and the start log name such metrics.
  - an event file may carry 'label' (shown in the log) and 'log_keys' (per-interval line)
  [the AMD-only metric files of this version: removed in v1.5]
  Intel hosts behave as in v1.0.

v1.1 (2026-11-12): AMD Zen 5 hosts (Family 1Ah: Turin, Turin Dense)
  - events/turin.json, generated by make_event_json_amd.py from the Linux kernel event list
    for Zen 5 (tools/perf/pmu-events/arch/x86/amdzen5)
  - the number of general counters and the cycle source come from the event file
    (Zen 5: six counters, no fixed counter, so cycles uses a general counter)
  - cpu_map.json may hold '_ranges' (family + model ranges) besides exact lines
  [the AMD-only metrics of this version: removed in v1.5]
  Intel hosts behave as in v1.0.

Runs ON THE ESXi HOST (busybox shell + the python3 that ships with ESXi).
Standard library only; works on python 3.5+ (no f-strings on purpose).

What it does, once a minute:
  1. reads every vmkperf event this script started      (vmkperf read <name>)
  2. subtracts the previous reading per pCPU            (cumulative -> interval delta)
     (general counters are assigned with -q. Intel: events limited to counters 0-3 take
      0-3, the others take 4-7; cycles comes from ESXi's fixed counter.
      AMD Zen: six counters, any event on any of them; cycles takes one of the six)
  3. sums the deltas over the whole host and, optionally, over pCPU groups
     given with --groups (e.g. VM1=0-15,VM2=16-31)
  4. derives rates/ratios from events/metrics.json
  5. pushes them to the HostSystem object in Operations (default) and/or appends a CSV row (--mode file|both)

Event codes are NOT hard-coded. The CPU generation is detected from the
CPUID family/model (esxcli hardware cpu list) and mapped through
events/cpu_map.json to events/<generation>.json, which was generated from
intel/perfmon by make_event_json.py, or from the Linux kernel event list of the
AMD Zen generation by make_event_json_amd.py.

Sub-commands
  check   preflight only: python, vmkperf, CPU detection, event file,
          firewall httpClient ruleset, Operations auth + host lookup, smoke push
  probe   start one event, read it, print the RAW vmkperf output, stop it.
          Use this first on a new host to confirm the 'read' row layout.
  diag    one copy-from-screen report: esxcli version/cpu/hostname/firewall, vmkperf
          usage + listevents + readall, start/read raw output of every event. Use this
          when collection fails on a host you cannot move files from.
  worldprobe  dump the raw output of the undocumented per-world mode
          (startwdstats + poll -w all) for one event, for evaluation only.
  qosprobe  list the vsish LLC/rmID tree and show which leaf will be read as
          cache occupancy (QOS_LEAF auto-detect result).
  start   start the events and loop (foreground; run under nohup)
  stop    stop the running loop and release this script's vmkperf events
  status  show pid, running events, last CSV row

Typical run (Operations only; nothing is written on the host)
  nohup python3 vmkperf_ops_push.py start > /dev/null 2>&1 &
CSV as well (file kept until you delete it; the script never removes files)
  nohup python3 vmkperf_ops_push.py start --mode both --out /vmfs/volumes/datastore1/vmkperf \\
        > /vmfs/volumes/datastore1/vmkperf/push.log 2>&1 &
  (--groups NAME=cpus,... only when the VMs are pinned to DISJOINT pCPUs;
   if their affinity sets overlap, the host total is the comparison unit)
"""
import sys, os, re, json, time, datetime, subprocess, signal, argparse, ssl, base64

VERSION = "1.5"
HERE = os.path.dirname(os.path.abspath(__file__))
PID_FILE = "/tmp/vmkperf_ops_push.pid"
STATE_FILE = "/tmp/vmkperf_ops_push.state"

TOKEN_FALLBACK_SEC = 1500
TOKEN_MARGIN_SEC = 300
OPS_PASS_ENC = ""                 # both filled from the config file by main()
OPS_ENC_KEY = ""

# ----------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------
def log(msg):
    sys.stdout.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stdout.flush()

def run(cmd, timeout=30):
    """run a command list, return (rc, stdout, stderr); never raises"""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = p.communicate(timeout=timeout)
        except TypeError:                     # python < 3.3 has no timeout
            out, err = p.communicate()
        return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
    except OSError as e:
        return 127, "", str(e)

def which(name):
    for d in os.environ.get("PATH", "").split(":") + ["/bin", "/sbin", "/usr/bin", "/usr/sbin",
                                                       "/usr/lib/vmware/bin"]:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None

def read_config(path):
    """KEY=VALUE lines of the connection settings file -> dict, or None when it cannot be read.
    The file is read as text, never executed. Quotes around a value are optional."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except (IOError, OSError):
        return None
    if raw.startswith(b"\xef\xbb\xbf"):            # UTF-8 mark some Windows editors write
        raw = raw[3:]
    out = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        if key.startswith("#"):
            continue
        if key.startswith("export "):
            key = key[7:].strip()
        val = val.strip()
        if val[:1] in ('"', "'"):
            q = val[0]
            val = val[1:]
            if q in val:
                val = val[:val.rfind(q)]
        else:
            m = re.search(r"\s#", val)
            if m:
                val = val[:m.start()]
            val = val.rstrip()
        out[key] = val
    return out

def find_config(explicit=None):
    """-> (path, dict or None). An explicit path, else ops_local.conf beside this script, else in the folder above."""
    if explicit:
        return explicit, read_config(explicit)
    for d in (HERE, os.path.dirname(HERE)):
        path = os.path.join(d, CONFIG_NAME)
        if os.path.isfile(path):
            return path, read_config(path)
    return os.path.join(HERE, CONFIG_NAME), None

def decrypt_pass():
    """decrypt OPS_PASS_ENC with the openssl binary that ships with ESXi. '' when unset or on failure."""
    if not OPS_PASS_ENC or not OPS_ENC_KEY:
        return ""
    ob = which("openssl")
    if not ob:
        return ""
    try:
        p = subprocess.Popen([ob, "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "100000",
                              "-pass", "pass:" + OPS_ENC_KEY, "-base64", "-A"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate(OPS_PASS_ENC.encode("ascii"))
        return out.decode("utf-8", "replace").strip() if p.returncode == 0 else ""
    except OSError:
        return ""

def parse_cpu_set(spec):
    """'0-15,32,40-41' -> set of ints"""
    s = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            s.update(range(int(a), int(b) + 1))
        else:
            s.add(int(part))
    return s

def parse_groups(spec):
    """'VM1=0-15,VM2=16-31;OTHER=32-63' -> [(name, set)].  ';' or ' ' between groups."""
    groups = []
    if not spec:
        return groups
    # groups are split on ';', whitespace, or a ',' that is followed by NAME=
    for item in re.split(r"[; ]+|,(?=[A-Za-z_][A-Za-z0-9_]*=)", spec.strip()):
        if not item:
            continue
        if "=" not in item:
            raise ValueError("group needs NAME=cpus: %s" % item)
        name, cpus = item.split("=", 1)
        groups.append((name.strip(), parse_cpu_set(cpus)))
    return groups

def kst(ts):
    return datetime.datetime.utcfromtimestamp(ts + 9 * 3600).strftime("%Y-%m-%d %H:%M:%S")

def utc(ts):
    return datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")

# ----------------------------------------------------------------------
# CPU generation detection
# ----------------------------------------------------------------------
def detect_family_model():
    """return 'family-model' (decimal, e.g. '6-143') or None"""
    esx = which("esxcli")
    if esx:
        rc, out, err = run([esx, "--formatter=keyvalue", "hardware", "cpu", "list"])
        if rc == 0:
            fam = re.search(r"\.Family\.integer=(\d+)", out, re.I)
            mod = re.search(r"\.Model\.integer=(\d+)", out, re.I)
            if fam and mod:
                return "%s-%s" % (fam.group(1), mod.group(1))
    vs = which("vsish")
    if vs:
        rc, out, err = run([vs, "-e", "get", "/hardware/cpu/cpuList/0"])
        if rc == 0:
            fam = re.search(r"[Ff]amily[^0-9]*(\d+)", out)
            mod = re.search(r"[Mm]odel[^0-9]*(\d+)", out)
            if fam and mod:
                return "%s-%s" % (fam.group(1), mod.group(1))
    return None

def map_cpu(cpu_map, fm):
    """family-model 'F-M' -> event file name: an exact line first, then the '_ranges' entries"""
    cpu = cpu_map.get(fm)
    if isinstance(cpu, str):
        return cpu
    try:
        fam, mod = [int(x) for x in fm.split("-", 1)]
    except ValueError:
        return None
    for r in cpu_map.get("_ranges") or []:
        if int(r.get("family", -1)) == fam and mod in parse_cpu_set(str(r.get("models", ""))):
            return r.get("cpu")
    return None

def load_events(cpu_override, events_dir):
    global GP_COUNTERS
    cpu_map = json.load(open(os.path.join(events_dir, "cpu_map.json")))
    fm = detect_family_model()
    if cpu_override:
        cpu = cpu_override
    else:
        if not fm:
            raise SystemExit("[ERROR] CPU family/model not detected; pass --cpu <name> (see events/*.json)")
        cpu = map_cpu(cpu_map, fm)
        if not cpu:
            raise SystemExit("[ERROR] family-model %s not in cpu_map.json; generate events/<name>.json "
                             "with make_event_json.py (Intel) or make_event_json_amd.py (AMD) and add a mapping, "
                             "or pass --cpu" % fm)
    path = os.path.join(events_dir, cpu + ".json")
    if not os.path.isfile(path):
        raise SystemExit("[ERROR] event file missing: %s" % path)
    ev = json.load(open(path))
    # general counters per logical CPU: 8 on the Intel generations in use, 6 on AMD Zen (from the event file)
    GP_COUNTERS = list(range(int(ev.get("gp_counters", 8))))
    mpath = os.path.join(events_dir, ev.get("metrics_file", "metrics.json"))
    if not os.path.isfile(mpath):
        raise SystemExit("[ERROR] metrics file missing: %s" % mpath)
    metrics = json.load(open(mpath))
    return fm, cpu, ev, metrics

# ----------------------------------------------------------------------
# vmkperf wrapper
# ----------------------------------------------------------------------
class Vmkperf(object):
    """Wrapper for the ESXi vmkperf tool. Syntax follows the VMware 'Vmkperf Introduction' sheet
    (ESXi 8 usage text), archived as docs/ref/Vmkperf_intro_ESXi8_usage.pdf:
      start <name> -e 0x.. -u 0x.. [-c 0x..] [-d ukei] [-t 0|1] [-q n] [-o 0xab:0xcd] [-m]
      read <name>|all | readall | poll <name> -i -n -f [-w all|id] | stop <name>|all | stopall
      reset | listpmc | listevents | startwdstats | stopwdstats
    'read' output: header 'pcpuID ctrVal timeStamp ctrType ctrNum', then one numeric row per pCPU:
      0 273642 1090909151918407 0 1
    """
    ROW_RE = re.compile(r"^\s*(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s*$", re.M)   # pcpuID ctrVal ts type num
    ROW_RE_LOOSE = re.compile(r"^\s*(\d+)\s+(\d+)(?:\s|$)", re.M)               # pcpuID ctrVal ... (any tail)
    FIXED_CYCLES = "fixed_unhalted_core_cycles"   # event ESXi itself keeps active on Intel hosts (fixed counter)

    def __init__(self, binary, line_re=None):
        self.bin = binary
        self.re = re.compile(line_re, re.M) if line_re else None

    def name(self, key):
        return key

    def _run(self, *args):
        rc, out, err = run([self.bin] + list(args))
        return rc, (out + err)

    @staticmethod
    def failed(rc, text):
        return rc != 0 or re.search(r"\berror\b|not permitted|out of resources|invalid|unknown|usage:", text, re.I) is not None

    def start(self, e, ctr=None):
        """register the event, on general counter 'ctr' when given (-q). The same name left over
        from an earlier run makes 'start' fail, so the name is stopped first (only this name;
        ESXi's own events are not touched)."""
        n = self.name(e["key"])
        self._run("stop", n)
        cmd = ["start", n, "-e", e["event"], "-u", e["umask"]]
        cmask = int(e.get("cmask", 0))
        if cmask > 0:
            cmd += ["-c", "0x%02x" % cmask]
        if e.get("modifiers"):                       # optional 'u','k','e','i' from the event file
            cmd += ["-d", e["modifiers"]]
        if ctr is not None:
            cmd += ["-q", str(ctr)]
        rc, text = self._run(*cmd)
        shown = " ".join(cmd) + ((" -> " + text.strip().replace("\n", " | ")) if text.strip() else "")
        return (not self.failed(rc, text)), shown

    def stop(self, key):
        return self._run("stop", self.name(key))

    def read_raw(self, key):
        return self._run("read", self.name(key))

    def parse(self, text):
        """-> dict pcpu -> cumulative count from a 'read' output"""
        pats = [self.re] if self.re else [self.ROW_RE, self.ROW_RE_LOOSE]
        for pat in pats:
            vals = {}
            for m in pat.finditer(text):
                vals[int(m.group(1))] = int(m.group(2))
            if vals:
                return vals
        return {}

    def read(self, key):
        rc, text = self.read_raw(key)
        vals = self.parse(text)
        return vals or None

    def active_events(self):
        """names listed under 'Active' in listevents (best effort); [] if the layout is unknown"""
        rc, text = self._run("listevents")
        names, active = [], False
        for line in text.splitlines():
            if re.search(r"active", line, re.I):
                active = True; continue
            if re.search(r"pre-?defined", line, re.I):
                active = False; continue
            m = re.match(r"^\s*([A-Za-z_][\w.\-]*)", line)
            if active and m:
                names.append(m.group(1))
        return names

    def fixed_cycles_readable(self):
        """True when ESXi's own fixed cycle event can be read (no GP counter needed for cycles)"""
        rc, text = self.read_raw(self.FIXED_CYCLES)
        return bool(self.parse(text)) and not self.failed(rc, text)

    def listevents_raw(self):
        return self._run("listevents")[1]

    def listpmc_raw(self):
        return self._run("listpmc")[1]

    def readall_raw(self):
        return self._run("readall")[1]

# ----------------------------------------------------------------------
# Operations client (suite-api)
# ----------------------------------------------------------------------
class Ops(object):
    def __init__(self, host, user, password, cacert=None, insecure=False, timeout=20):
        import urllib.request
        # OPS_HOST as the shell collectors take it: a host name or IP (https is used), or a full http(s):// address
        host = (host or "").strip().rstrip("/")
        self.base = host if host.startswith(("http://", "https://")) else "https://%s" % host
        self.user, self.password = user, password
        self.timeout = timeout
        self.token, self.exp, self.scheme = None, 0, "OpsToken"
        self.resource_id, self.resource_kind = None, None
        if insecure:
            ctx = ssl._create_unverified_context()
        else:
            ctx = ssl.create_default_context(cafile=cacert) if cacert else ssl.create_default_context()
        self.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))

    def _req(self, method, path, body=None, auth=True, query=None):
        import urllib.request, urllib.parse
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if auth and self.token:
            req.add_header("Authorization", "%s %s" % (self.scheme, self.token))
        try:
            resp = self.opener.open(req, timeout=self.timeout)
            code, text = resp.getcode(), resp.read().decode("utf-8", "replace")
        except Exception as e:                      # HTTPError has .code / .read()
            code = getattr(e, "code", 0)
            try:
                text = e.read().decode("utf-8", "replace")
            except Exception:
                text = str(e)
        return code, text

    def acquire_token(self):
        code, text = self._req("POST", "/suite-api/api/auth/token/acquire",
                               {"username": self.user, "password": self.password,
                                "authSource": OPS_AUTHSOURCE}, auth=False)
        try:
            d = json.loads(text)
        except ValueError:
            d = {}
        self.token = d.get("token")
        if not self.token:
            return False, "HTTP %s %s" % (code, text[:200])
        v = d.get("validity")
        self.exp = int(v) // 1000 if isinstance(v, int) and v > 10 ** 10 else int(time.time()) + TOKEN_FALLBACK_SEC
        # header scheme differs between Ops builds
        for s in ("OpsToken", "vRealizeOpsToken"):
            self.scheme = s
            c, t = self._req("GET", "/suite-api/api/resources", query={"pageSize": 1, "_no_links": "true"})
            if c == 200:
                return True, "token ok (%s)" % s
        return False, "auth header rejected (OpsToken / vRealizeOpsToken), HTTP %s" % c

    def ensure_token(self):
        if self.token and time.time() < self.exp - TOKEN_MARGIN_SEC:
            return True
        ok, msg = self.acquire_token()
        if not ok:
            log("[WARN] token: " + msg)
        return ok

    def lookup_host(self, name):
        q = {"adapterKindKey": "VMWARE", "resourceKind": "HostSystem", "name": name, "_no_links": "true"}
        code, text = self._req("GET", "/suite-api/api/resources", query=q)
        try:
            rl = json.loads(text).get("resourceList") or []
        except ValueError:
            rl = []
        exact = [r for r in rl if (r.get("resourceKey") or {}).get("name") == name]
        if not exact:
            exact = [r for r in rl if ((r.get("resourceKey") or {}).get("name") or "").lower() == name.lower()]
        if not exact:
            return False, "HostSystem '%s' not found (HTTP %s, %d candidates)" % (name, code, len(rl))
        self.resource_id = exact[0].get("identifier")
        self.resource_kind = (exact[0].get("resourceKey") or {}).get("resourceKindKey")
        return True, "%s -> %s (%s)" % (name, self.resource_id, self.resource_kind)

    def push(self, stat_content):
        if not self.ensure_token():
            return False, "no token"
        body = {"stat-content": stat_content}
        for attempt in (1, 2):
            code, text = self._req("POST", "/suite-api/api/resources/%s/stats" % self.resource_id, body)
            if code in (200, 201, 204):
                return True, "HTTP %s" % code
            if code in (401, 403):
                self.token = None
                if not self.ensure_token():
                    return False, "re-auth failed"
                continue
            time.sleep(1)
        return False, "HTTP %s %s" % (code, text[:160])

# ----------------------------------------------------------------------
# LLC occupancy per rmID via vsish  (qos_monitor equivalent)
# ----------------------------------------------------------------------
class Qos(object):
    LEAF_RE = re.compile(r"occup|cache|used|bytes|usage", re.I)
    PCPU_LEAVES = ("pcpus", "pcpuList", "cpus", "pcpuMask")

    def __init__(self, root=QOS_ROOT, leaf=QOS_LEAF, rmids=QOS_RMIDS):
        self.vs = which("vsish")
        self.root, self.leaf, self.rmid_sel = root.rstrip("/"), leaf, rmids
        self.instances, self.rmids, self.leaf_note = [], [], ""
        self.pcpus = {}
        self.reserved = {}            # (instance, rmid) -> "Y"/"N", read once at discover

    def ls(self, path):
        rc, out, err = run([self.vs, "-e", "ls", path + "/"])
        return [l.strip().rstrip("/") for l in out.splitlines() if l.strip()] if rc == 0 else []

    def get(self, path):
        rc, out, err = run([self.vs, "-e", "get", path])
        return out if rc == 0 else None

    @staticmethod
    def num(text, key=None):
        """integer out of a vsish 'get' result: plain number, or 'key:number' inside a struct"""
        if text is None:
            return None
        t = text.strip()
        if re.match(r"^-?\d+$", t):
            return int(t)
        if key:
            m = re.search(r"%s\s*[:=]\s*(-?\d+)" % re.escape(key), t)
            if m:
                return int(m.group(1))
        m = re.search(r"[:=]\s*(-?\d+)\s*$", t, re.M)
        return int(m.group(1)) if m else None

    def discover(self):
        """-> (ok, message). fills instances, rmids, leaf"""
        if not self.vs:
            return False, "vsish not found"
        self.instances = [i for i in self.ls(self.root) if re.match(r"^\d+$", i)]
        if not self.instances:
            return False, "no LLC instances under %s (CAT/RDT unsupported or path changed)" % self.root
        i0 = self.instances[0]
        all_rmids = [r for r in self.ls("%s/%s/rmID" % (self.root, i0)) if re.match(r"^\d+$", r)]
        if not all_rmids:
            return False, "no rmID nodes under %s/%s/rmID" % (self.root, i0)
        # rmID selection
        if self.rmid_sel == "all":
            self.rmids = all_rmids
        elif self.rmid_sel == "reserved":
            self.rmids = [r for r in all_rmids
                          if r == "0" or self.num(self.get("%s/%s/rmID/%s/reserved" % (self.root, i0, r))) == 1]
        else:
            self.rmids = [r.strip() for r in self.rmid_sel.split(",") if r.strip() in all_rmids]
        # occupancy leaf
        leaves = self.ls("%s/%s/rmID/%s" % (self.root, i0, all_rmids[0]))
        cand = [self.leaf] if self.leaf else [l for l in leaves if self.LEAF_RE.search(l) and l != "reserved"]
        chosen = None
        for l in cand:
            v = self.num(self.get("%s/%s/rmID/%s/%s" % (self.root, i0, all_rmids[0], l)), l)
            if v is not None:
                chosen = l; break
        if chosen is None and not self.leaf:
            # maybe the rmID node itself is a struct holding the value
            v = self.get("%s/%s/rmID/%s" % (self.root, i0, all_rmids[0]))
            m = re.search(r"^\s*([A-Za-z_]*(?:occup|cache|used|bytes)[A-Za-z_]*)\s*[:=]\s*\d+", v or "", re.I | re.M)
            if m:
                chosen = "." + m.group(1)        # '.' prefix = read the node and pick this key
        if chosen is None:
            return False, "occupancy leaf not found under rmID/<r>/ (leaves: %s). Set QOS_LEAF or run qosprobe" % ", ".join(leaves)
        self.leaf = chosen
        for i in self.instances:                   # pcpus column (best effort)
            self.pcpus[i] = ""
            for pl in self.PCPU_LEAVES:
                v = self.get("%s/%s/%s" % (self.root, i, pl))
                if v and v.strip():
                    self.pcpus[i] = v.strip().splitlines()[0][:40]; break
        for i in self.instances:
            for r in self.rmids:
                self.reserved[(i, r)] = "Y" if self.num(self.get("%s/%s/rmID/%s/reserved" % (self.root, i, r))) == 1 else "N"
        self.leaf_note = "leaf=%s instances=%s rmIDs=%s" % (self.leaf, ",".join(self.instances), ",".join(self.rmids))
        return True, self.leaf_note

    def read_one(self, i, r):
        if self.leaf.startswith("."):
            return self.num(self.get("%s/%s/rmID/%s" % (self.root, i, r)), self.leaf[1:])
        return self.num(self.get("%s/%s/rmID/%s/%s" % (self.root, i, r, self.leaf)), self.leaf)

    def sample(self):
        """-> list of (llc, pcpus, rmid, reserved_flag, bytes)"""
        rows = []
        for i in self.instances:
            for r in self.rmids:
                b = self.read_one(i, r)
                if b is None:
                    continue
                rows.append((i, self.pcpus.get(i, ""), r, self.reserved.get((i, r), "N"), b))
        return rows

# ----------------------------------------------------------------------
# general-counter placement
# ----------------------------------------------------------------------
GP_COUNTERS = list(range(8))          # general counters per logical CPU (ctrType 0); load_events() sets it from
                                      # the event file: 8 on Sapphire/Emerald/Granite Rapids, 6 on AMD Zen

def allowed_counters(e):
    """counter numbers Intel lists for the event ('Counter' field), e.g. {0,1,2,3} or {0..7}"""
    spec = str(e.get("counters", "")).strip()
    if not spec:
        return set(GP_COUNTERS)
    out = set()
    for part in spec.split(","):
        part = part.strip()
        if part.isdigit():
            out.add(int(part))
    return out or set(GP_COUNTERS)

def plan_counters(events):
    """-> list of (event, counter or None). Events that only run on a subset (0-3) are placed
    first, on the lowest free counter of their subset; unrestricted events take the highest
    free counters, so the restricted slots stay available. None = no admissible counter left."""
    free = set(GP_COUNTERS)
    plan = {}
    order = sorted(events, key=lambda e: (len(allowed_counters(e)), events.index(e)))
    for e in order:
        cand = sorted(allowed_counters(e) & free)
        if not cand:
            plan[e["key"]] = None
            continue
        c = cand[0] if len(allowed_counters(e)) < len(GP_COUNTERS) else cand[-1]
        plan[e["key"]] = c
        free.discard(c)
    return [(e, plan[e["key"]]) for e in events]

# ----------------------------------------------------------------------
# metric evaluation
# ----------------------------------------------------------------------
def eval_metrics(mdefs, sums):
    """sums: event key -> interval delta (int) for one pCPU set. returns ordered [(key, value|None)]"""
    out = []
    def val(expr):
        tot = 0
        for k in expr.split("+"):
            k = k.strip()
            if k not in sums or sums[k] is None:
                return None
            tot += sums[k]
        return tot
    for m in mdefs:
        t = m["type"]
        if t == "sum":
            v = val(m["src"])
        else:
            n, d = val(m["num"]), val(m["den"])
            if n is None or d is None or d == 0:
                v = None
            elif t == "pct":
                v = round(100.0 * n / d, 4)
            else:
                v = round(float(m.get("scale", 1)) * n / d, 4)
        out.append((m["key"], v))
    return out

def metrics_without_events(mdefs, events):
    """metric keys with an input event that the event file of this CPU generation does not hold"""
    have = set(e["key"] for e in events)
    out = []
    for m in mdefs:
        srcs = []
        for f in ("src", "num", "den"):
            if m.get(f):
                srcs += [k.strip() for k in str(m[f]).split("+")]
        if [k for k in srcs if k not in have]:
            out.append(m["key"])
    return out

# ----------------------------------------------------------------------
# main loop
# ----------------------------------------------------------------------
class Collector(object):
    def __init__(self, a):
        self.a = a
        self.vbin = which("vmkperf")
        if not self.vbin:
            raise SystemExit("[ERROR] vmkperf not found in PATH or /usr/lib/vmware/bin")
        self.fm, self.cpu, self.evfile, self.mfile = load_events(a.cpu, a.events_dir)
        self.vk = Vmkperf(self.vbin, a.line_regex)
        self.events = self.evfile["events"]
        self.cycles_from_fixed = False
        if a.events:
            want = set(a.events.split(","))
            self.events = [e for e in self.events if e["key"] in want]
        self.mdefs = self.mfile["metrics"]
        self.stat_root = STAT_ROOT
        self.groups = parse_groups(a.groups)
        self.running = []            # event dicts actually started
        self.prev = {}               # key -> {pcpu: cumulative}
        self.ops = None
        self.csv = None
        self.pcpu_csv = None
        self.qos = None
        self.qos_csv = None
        self.stop_flag = False

    # ---- vmkperf lifecycle ------------------------------------------
    def start_events(self):
        label = self.evfile.get("label")
        log("CPU family-model %s -> %s%s (%s)" % (self.fm, self.cpu, " [%s]" % label if label else "",
                                                 self.evfile.get("source")))
        absent = metrics_without_events(self.mdefs, self.evfile["events"])
        if absent:
            log("no event for these metrics in %s.json (CSV column stays empty, not pushed): %s"
                % (self.cpu, ", ".join(absent)))
        gp_events = []
        for e in self.events:
            if (e["key"] == "cycles" and not self.a.gp_cycles and self.evfile.get("fixed_cycles", True)
                    and self.vk.fixed_cycles_readable()):
                # ESXi keeps fixed_unhalted_core_cycles active (ctrType 1); reading it costs no general counter
                self.cycles_from_fixed = True
                self.running.append(e)
                log("cycles           read from %s (ESXi fixed counter, no start)" % self.vk.FIXED_CYCLES)
                continue
            gp_events.append(e)
        used = set()
        for e, ctr in plan_counters(gp_events):
            if ctr is None:
                log("[WARN] start %-16s SKIPPED: needs counter %s, none left  (metrics using it are skipped)"
                    % (e["key"], ",".join(str(c) for c in sorted(allowed_counters(e)))))
                continue
            ok, msg = self.vk.start(e, ctr)
            if not ok:
                # the planned counter was refused (e.g. held by ESXi): try the other admissible free ones
                for alt in sorted(allowed_counters(e) - used - {ctr}, reverse=(len(allowed_counters(e)) == len(GP_COUNTERS))):
                    ok, msg = self.vk.start(e, alt)
                    if ok:
                        ctr = alt; break
            if not ok and len(allowed_counters(e)) == len(GP_COUNTERS):
                # every counter number was refused. An event that may run on any counter can also be
                # started without -q, leaving the choice to vmkperf (never done for events tied to 0-3).
                ok, msg = self.vk.start(e, None)
                if ok:
                    ctr = None
            if ok:
                if ctr is not None:
                    used.add(ctr)
                self.running.append(e)
                log("start %-16s %s" % (e["key"], msg))
            else:
                log("[WARN] start %-16s FAILED: %s  (metrics using it are skipped)" % (e["key"], msg))
        if not self.running:
            raise SystemExit("[ERROR] no event could be started (see 'vmkperf listevents' / 'vmkperf listpmc')")
        self.save_state()

    def stop_events(self):
        n = 0
        for e in self.running:
            if e["key"] == "cycles" and self.cycles_from_fixed:
                continue                                   # not ours to stop
            self.vk.stop(e["key"]); n += 1
        log("stopped %d events" % n)

    def save_state(self):
        json.dump({"pid": os.getpid(), "events": [e["key"] for e in self.running
                                                  if not (e["key"] == "cycles" and self.cycles_from_fixed)],
                   "cpu": self.cpu, "started": utc(time.time()) + " UTC"}, open(STATE_FILE, "w"))

    # ---- one interval ----------------------------------------------
    def read_all(self):
        cur = {}
        for e in self.running:
            src = self.vk.FIXED_CYCLES if (e["key"] == "cycles" and self.cycles_from_fixed) else e["key"]
            cur[e["key"]] = self.vk.read(src)
            if cur[e["key"]] is None:
                log("[WARN] read %s returned nothing parseable" % e["key"])
        return cur

    def deltas(self, cur):
        """-> key -> {pcpu: delta} ; None where the counter reset or the read failed"""
        d = {}
        for k, now in cur.items():
            before = self.prev.get(k)
            if now is None or before is None:
                d[k] = None
                continue
            dd = {}
            for p, v in now.items():
                if p in before and v >= before[p]:
                    dd[p] = v - before[p]
            d[k] = dd if dd else None
        return d

    def sums_for(self, deltas, cpuset=None):
        s = {}
        for k, dd in deltas.items():
            if dd is None:
                s[k] = None
            else:
                s[k] = sum(v for p, v in dd.items() if cpuset is None or p in cpuset)
        return s

    def interval(self, ts):
        cur = self.read_all()
        d = self.deltas(cur)
        self.prev = cur
        if all(v is None for v in d.values()):
            return None, d
        rows = [("", eval_metrics(self.mdefs, self.sums_for(d)))]
        for gname, cpus in self.groups:
            rows.append((gname, eval_metrics(self.mdefs, self.sums_for(d, cpus))))
        return rows, d

    # ---- outputs ----------------------------------------------------
    def stat_key(self, group, mkey):
        root = self.stat_root if not group else self.stat_root + " " + group
        return root + "|" + mkey

    def csv_header(self):
        cols = ["ts_utc", "ts_kst"]
        for g in [""] + [g for g, _ in self.groups]:
            for m in self.mdefs:
                cols.append((g + "." if g else "") + m["key"])
        return cols

    def open_outputs(self):
        if self.a.mode in ("file", "both"):
            os.makedirs(self.a.out, exist_ok=True)
            tag = time.strftime("%Y%m%d_%H%M", time.gmtime())
            path = os.path.join(self.a.out, "vmkperf_%s_%s.csv" % (self.a.name.split(".")[0], tag))
            self.csv = open(path, "a")
            self.csv.write(",".join(self.csv_header()) + "\n"); self.csv.flush()
            log("csv  " + path)
            if self.a.pcpu_csv:
                ppath = path.replace(".csv", "_pcpu.csv")
                self.pcpu_csv = open(ppath, "a")
                self.pcpu_csv.write("ts_utc,ts_kst,event,pcpu,delta\n"); self.pcpu_csv.flush()
                log("csv  " + ppath + " (per-pCPU deltas)")
        if QOS_ENABLE or self.a.qos:
            self.qos = Qos()
            ok, msg = self.qos.discover()
            if ok:
                log("qos  " + msg)
                if self.a.mode in ("file", "both"):
                    tag = time.strftime("%Y%m%d_%H%M", time.gmtime())
                    qpath = os.path.join(self.a.out, "qos_monitor_%s_%s.csv" % (self.a.name.split(".")[0], tag))
                    self.qos_csv = open(qpath, "a")
                    self.qos_csv.write("timestamp,llc,pcpus,rmid,reserved,cache_used_bytes\n"); self.qos_csv.flush()
                    log("csv  " + qpath + " (LLC occupancy per rmID, UTC, same layout as qos_monitor)")
            else:
                log("[WARN] qos sampling disabled: " + msg)
                self.qos = None
        if self.a.mode in ("ops", "both") and not self.a.dry_run:
            self.ops = Ops(self.a.ops_host, self.a.ops_user, self.a.password, self.a.cacert, self.a.insecure)
            ok, msg = self.ops.acquire_token()
            if not ok:
                raise SystemExit("[ERROR] Operations auth: " + msg)
            log("ops  " + msg)
            ok, msg = self.ops.lookup_host(self.a.name)
            if not ok:
                raise SystemExit("[ERROR] Operations: " + msg)
            log("ops  " + msg)

    def emit(self, ts, rows, deltas):
        ms = int(ts) * 1000
        if self.csv:
            vals = [utc(ts), kst(ts)]
            for g, mv in rows:
                vals += ["" if v is None else str(v) for _, v in mv]
            self.csv.write(",".join(vals) + "\n"); self.csv.flush()
        if self.pcpu_csv:
            for k, dd in deltas.items():
                if dd:
                    for p in sorted(dd):
                        self.pcpu_csv.write("%s,%s,%s,%d,%d\n" % (utc(ts), kst(ts), k, p, dd[p]))
            self.pcpu_csv.flush()
        content = []
        for g, mv in rows:
            for mk, v in mv:
                if v is not None:
                    content.append({"statKey": self.stat_key(g, mk), "timestamps": [ms], "data": [v]})
        if self.qos:
            qrows = self.qos.sample()
            per_rmid = {}
            for (i, pc, r, res, b) in qrows:
                per_rmid[r] = per_rmid.get(r, 0) + b
                content.append({"statKey": self.stat_key("", "LLC_Occ_llc%s_rmID%s_MB" % (i, r)),
                                "timestamps": [ms], "data": [round(b / 1048576.0, 3)]})
                if self.qos_csv:
                    self.qos_csv.write("%s,%s,%s,%s,%s,%d\n" % (utc(ts), i, pc, r, res, b))
            for r, b in sorted(per_rmid.items(), key=lambda x: int(x[0])):
                content.append({"statKey": self.stat_key("", "LLC_Occ_rmID%s_MB" % r),
                                "timestamps": [ms], "data": [round(b / 1048576.0, 3)]})
            if self.qos_csv:
                self.qos_csv.flush()
        if self.a.dry_run and self.a.mode in ("ops", "both"):
            print(json.dumps({"stat-content": content}))
        elif self.ops:
            ok, msg = self.ops.push(content)
            if not ok:
                log("[WARN] push failed: " + msg)
        return len(content)

    # ---- loop -------------------------------------------------------
    def loop(self):
        iv = self.a.interval
        def on_sig(signum, frame):
            self.stop_flag = True
        signal.signal(signal.SIGTERM, on_sig)
        signal.signal(signal.SIGINT, on_sig)
        open(PID_FILE, "w").write(str(os.getpid()))
        self.open_outputs()
        self.start_events()
        self.prev = self.read_all()                       # baseline; first interval is a delta
        log("loop interval %ds, groups %s, mode %s" % (iv, [g for g, _ in self.groups] or "host-only", self.a.mode))
        n = 0
        try:
            while not self.stop_flag:
                now = time.time()
                nxt = (int(now) // iv + 1) * iv
                while time.time() < nxt and not self.stop_flag:
                    time.sleep(min(1.0, nxt - time.time()))
                if self.stop_flag:
                    break
                t_read0 = time.time()
                rows, d = self.interval(nxt)
                n += 1
                if rows is None:
                    log("#%d %s no usable delta" % (n, kst(nxt)))
                    continue
                cnt = self.emit(nxt, rows, d)
                head = dict(rows[0][1])
                log_keys = self.evfile.get("log_keys") or self.mfile.get("log_keys")
                if log_keys:                           # event file or metrics file names what the per-interval line shows
                    shown = "  ".join("%s %s" % (k, head.get(k)) for k in log_keys)
                else:
                    shown = "LLC_Miss %s  MissRate %s%%  L3Stall %s%%  IPC %s" % (
                        head.get("LLC_Miss"), head.get("LLC_MissRate_Pct"), head.get("L3_Stall_Pct"), head.get("IPC"))
                log("#%d %s KST  %d stats | %s | work %d ms" % (
                    n, kst(nxt), cnt, shown, int((time.time() - t_read0) * 1000)))
                if n == 1 and self.a.max_iter == 0:
                    pass
                if self.a.max_iter and n >= self.a.max_iter:
                    break
        finally:
            self.stop_events()
            for f in (self.csv, self.pcpu_csv, self.qos_csv):
                if f:
                    f.close()
            for p in (PID_FILE, STATE_FILE):
                try:
                    os.remove(p)
                except OSError:
                    pass
            log("exit after %d intervals" % n)

# ----------------------------------------------------------------------
# sub-commands
# ----------------------------------------------------------------------
def cmd_check(a):
    ok_all = True
    def item(ok, text):
        print("[%s] %s" % ("OK " if ok else "NG ", text))
        return ok
    print("vmkperf_ops_push v%s preflight" % VERSION)
    ok_all &= item(sys.version_info >= (3, 5), "python %s" % sys.version.split()[0])
    vb = which("vmkperf")
    ok_all &= item(bool(vb), "vmkperf binary: %s" % (vb or "NOT FOUND"))
    fm = detect_family_model()
    item(bool(fm), "CPU family-model: %s" % (fm or "not detected (use --cpu)"))
    ev = None
    try:
        fm2, cpu, ev, mf = load_events(a.cpu, a.events_dir)
        item(True, "event file: %s.json  (%s)" % (cpu, ev.get("source")))
        if ev.get("label"):
            item(True, "event file covers: %s" % ev["label"])
        item(True, "general counters per logical CPU: %d%s" % (len(GP_COUNTERS),
             "" if ev.get("fixed_cycles", True) else "  (no fixed counter: cycles takes one of them)"))
        for e in ev["events"]:
            print("      %-16s %-52s -e %s -u %s%s" % (e["key"], e["name"], e["event"], e["umask"],
                                                   "  cmask %d (-r)" % e["cmask"] if e["cmask"] else ""))
        absent = metrics_without_events(mf["metrics"], ev["events"])
        if absent:
            item(True, "metrics without an event on this CPU generation (stay empty): %s" % ", ".join(absent))
    except SystemExit as e:
        ok_all &= item(False, str(e))
    if vb:
        vk = Vmkperf(vb)
        act = vk.active_events()
        item(True, "vmkperf active events: %s" % (", ".join(act) if act else "(none parsed)"))
        cyc = [e for e in (ev.get("events", []) if isinstance(ev, dict) else []) if e["key"] == "cycles"]
        gp_txt = "GP counter (-e %s -u %s)" % (cyc[0]["event"], cyc[0]["umask"]) if cyc else "GP counter"
        use_fixed = isinstance(ev, dict) and ev.get("fixed_cycles", True) and vk.fixed_cycles_readable()
        item(True, "cycles source: %s" % ("ESXi fixed counter %s (readable)" % vk.FIXED_CYCLES if use_fixed else gp_txt))
    esx = which("esxcli")
    if esx:
        rc, out, err = run([esx, "--formatter=keyvalue", "network", "firewall", "ruleset", "list", "-r", "httpClient"])
        en = re.search(r"Enabled\.boolean=(\w+)", out, re.I)
        fw = en.group(1) if en else "unknown"
        fw_ok = item(fw == "true", "firewall ruleset httpClient enabled: %s%s" % (
            fw, "" if fw == "true" else "   -> esxcli network firewall ruleset set -e true -r httpClient"))
        if a.mode in ("ops", "both"):
            ok_all &= fw_ok
        rc, out, err = run([esx, "--formatter=keyvalue", "system", "hostname", "get"])
        m = re.search(r"FullyQualifiedDomainName\.string=(\S+)", out, re.I)
        item(bool(m), "host FQDN: %s (push target name%s)" % (m.group(1) if m else "?", "" if not a.name else ", overridden by --name " + a.name))
        if m and not a.name:
            a.name = m.group(1)
    if QOS_ENABLE or a.qos:
        q = Qos(); ok, msg = q.discover()
        item(ok, "LLC occupancy via vsish: " + msg)
    else:
        item(True, "LLC occupancy via vsish: off (enable with --qos or QOS_ENABLE = True)")
    if a.mode in ("ops", "both"):
        ok_all &= item(a.config_state == "read", "config file: %s [%s]%s" % (
            a.config_path, a.config_state,
            "" if a.config_state == "read" else "   -> put ops_local.conf there and fill in its four keys"))
        if not a.ops_host or not a.ops_user:
            ok_all &= item(False, "Operations address or account not set: put OPS_HOST and OPS_USER into the config file "
                                  "(or --ops-host / --ops-user, env OPS_HOST / OPS_USER)")
        elif not a.password:
            if OPS_PASS_ENC and OPS_ENC_KEY:
                ok_all &= item(False, "Operations password: OPS_PASS_ENC and OPS_ENC_KEY found in the config file but openssl "
                                      "decrypt failed (openssl present? both values copied intact?)")
            else:
                ok_all &= item(False, "Operations password: OPS_PASS_ENC or OPS_ENC_KEY is empty in the config file "
                                      "(fill both in, or use --pass-file, env OPS_PASSWORD)")
        else:
            ops = Ops(a.ops_host, a.ops_user, a.password, a.cacert, a.insecure)
            ok, msg = ops.acquire_token()
            ok_all &= item(ok, "Operations auth %s as %s [%s]: %s" % (a.ops_host, a.ops_user, a.password_source, msg))
            if ok:
                ok, msg = ops.lookup_host(a.name or "")
                ok_all &= item(ok, "HostSystem lookup: " + msg)
                if ok:
                    ok, msg = ops.push([{"statKey": STAT_ROOT + "|_smoke", "timestamps": [int(time.time()) * 1000], "data": [1]}])
                    ok_all &= item(ok, "smoke push %s|_smoke: %s" % (STAT_ROOT, msg))
    print("RESULT:", "ready" if ok_all else "fix the NG lines above")
    return 0 if ok_all else 1

def cmd_probe(a):
    """start one or two events, show the raw 'read' output and how it parses, stop them"""
    vb = which("vmkperf")
    if not vb:
        raise SystemExit("[ERROR] vmkperf not found")
    fm, cpu, ev, mf = load_events(a.cpu, a.events_dir)
    vk = Vmkperf(vb, a.line_regex)
    print("== vmkperf listevents:"); print(vk.listevents_raw().rstrip()[:2000] or "(empty)")
    print("== %s readable: %s" % (vk.FIXED_CYCLES, vk.fixed_cycles_readable()))
    have = [x["key"] for x in ev["events"]]
    if a.events:
        keys = a.events.split(",")
    elif "llc_miss" in have and "l3_stall" in have:
        keys = ["llc_miss", "l3_stall"]
    else:                                   # event file without those keys (AMD): the first two non-cycle events,
        keys = [k for k in have if k not in ("cycles", "instr")][:2] or have[:2]   # or cycles / instr when it holds nothing else
    for key in keys:
        e = [x for x in ev["events"] if x["key"] == key]
        if not e:
            print("unknown event key", key); continue
        ctr = plan_counters([e[0]])[0][1]
        ok, msg = vk.start(e[0], ctr)
        print("== start %s: %s -> %s" % (key, msg, "ok" if ok else "FAILED"))
        if not ok:
            continue
        time.sleep(a.probe_sleep)
        rc, raw = vk.read_raw(key)
        print("-- read (rc=%d, raw):" % rc); print(raw.rstrip()[:1500])
        parsed = vk.parse(raw)
        print("-- parsed: %s" % ("%d pCPUs, first %s" % (len(parsed), sorted(parsed.items())[:3])
                                  if parsed else "NOTHING (expected rows: '<pcpuID> <ctrVal> <timeStamp> <ctrType> <ctrNum>')"))
        vk.stop(key); print("-- stopped")
    return 0

def cmd_worldprobe(a):
    """dump the raw output of vmkperf's undocumented per-world mode so it can be judged before use"""
    vb = which("vmkperf")
    if not vb:
        raise SystemExit("[ERROR] vmkperf not found")
    fm, cpu, ev, mf = load_events(a.cpu, a.events_dir)
    vk = Vmkperf(vb, a.line_regex)
    have = [x["key"] for x in ev["events"]]
    key = a.events.split(",")[0] if a.events else ("llc_miss" if "llc_miss" in have else
                                                    ([k for k in have if k not in ("cycles", "instr")] or have)[0])
    e = [x for x in ev["events"] if x["key"] == key][0]
    ok, msg = vk.start(e)
    print("== start %s: %s -> %s" % (key, msg, "ok" if ok else "FAILED"))
    if not ok:
        return 1
    try:
        for cmd in (["startwdstats"],
                    ["poll", vk.name(key), "-w", "all", "-i", str(a.probe_sleep), "-n", "2", "-f", "avgPerSecond"],
                    ["stopwdstats"]):
            rc, out, err = run([vb] + cmd, timeout=a.probe_sleep * 4 + 20)
            print("-- vmkperf %s (rc=%d):" % (" ".join(cmd), rc)); print((out + err).rstrip()[:6000])
        esx = which("esxcli")
        if esx:
            rc, out, err = run([esx, "vm", "process", "list"])
            print("-- esxcli vm process list (world IDs to match against):"); print(out.rstrip()[:3000])
    finally:
        vk.stop(key); print("-- stopped")
    return 0

def cmd_qosprobe(a):
    q = Qos()
    if not q.vs:
        raise SystemExit("[ERROR] vsish not found")
    print("== vsish -e ls %s/" % q.root); print("\n".join(q.ls(q.root)) or "(empty)")
    inst = [i for i in q.ls(q.root) if re.match(r"^\d+$", i)]
    if not inst:
        return 1
    i0 = inst[0]
    print("== vsish -e ls %s/%s/" % (q.root, i0)); print("\n".join(q.ls("%s/%s" % (q.root, i0))))
    rm = q.ls("%s/%s/rmID" % (q.root, i0))
    print("== rmIDs under %s/%s/rmID/: %s" % (q.root, i0, " ".join(rm)))
    for r in rm[:3]:
        node = "%s/%s/rmID/%s" % (q.root, i0, r)
        print("== vsish -e get %s" % node); print((q.get(node) or "").rstrip())
        for l in q.ls(node):
            print("   -- get %s/%s -> %s" % (node, l, (q.get(node + "/" + l) or "").strip().replace("\n", " | ")[:200]))
    ok, msg = q.discover()
    print("== auto-detect:", "OK  " + msg if ok else "FAILED  " + msg)
    if ok:
        print("== sample:"); [print("   ", row) for row in q.sample()[:12]]
    return 0 if ok else 1

def cmd_diag(a):
    """one compact, copy-from-screen report of everything the collector depends on"""
    def sec(t):
        print("\n#### " + t)
    print("vmkperf_ops_push diag v%s  %s UTC  python %s" % (VERSION, utc(time.time()), sys.version.split()[0]))
    esx = which("esxcli")
    if esx:
        for args in (["system", "version", "get"], ["hardware", "cpu", "global", "get"], ["system", "hostname", "get"]):
            rc, out, err = run([esx, "--formatter=keyvalue"] + args)
            sec("esxcli " + " ".join(args)); print((out + err).strip()[:800])
        rc, out, err = run([esx, "--formatter=keyvalue", "hardware", "cpu", "list"])
        sec("esxcli hardware cpu list (first CPU)"); print("\n".join(l for l in out.splitlines() if l.startswith("structure[0].") or "[0]" in l)[:600])
        rc, out, err = run([esx, "--formatter=keyvalue", "network", "firewall", "ruleset", "list", "-r", "httpClient"])
        sec("firewall httpClient"); print((out + err).strip()[:300])
    sec("CPU family-model -> event file"); print(detect_family_model())
    vb = which("vmkperf")
    sec("vmkperf binary"); print(vb or "NOT FOUND")
    if not vb:
        return 1
    fm, cpu, ev, mf = load_events(a.cpu, a.events_dir)
    vk = Vmkperf(vb, a.line_regex)
    sec("vmkperf usage (raw)"); print(vk._run()[1].rstrip()[:1500] or "(empty)")
    sec("vmkperf listpmc (raw)"); print(vk.listpmc_raw().rstrip()[:1500] or "(empty)")
    sec("vmkperf listevents (raw) - active + pre-defined"); print(vk.listevents_raw().rstrip()[:2500] or "(empty)")
    sec("%s readable" % vk.FIXED_CYCLES); print(vk.fixed_cycles_readable())
    sec("event file"); print("%s.json  general counters %d  fixed cycle counter expected: %s" % (
        cpu, len(GP_COUNTERS), ev.get("fixed_cycles", True)))
    keys = a.events.split(",") if a.events else [e["key"] for e in ev["events"]]
    # cycles is skipped only where ESXi's fixed cycle event exists; without one it is an ordinary event
    chosen = [x for x in ev["events"] if x["key"] in keys and (x["key"] != "cycles" or not ev.get("fixed_cycles", True))]
    started = []
    for e, ctr in plan_counters(chosen):
        if ctr is None:
            sec("start %s" % e["key"]); print("SKIPPED: no admissible counter left"); continue
        ok, msg = vk.start(e, ctr)
        sec("start %s" % e["key"]); print(msg, "->", "ok" if ok else "FAILED")
        if ok:
            started.append(e["key"])
    time.sleep(a.probe_sleep)
    for key in started:
        rc, raw = vk.read_raw(key)
        sec("read %s (rc=%d, raw)" % (key, rc)); print(raw.rstrip()[:1200])
        parsed = vk.parse(raw)
        print("-> parsed %d pCPUs %s" % (len(parsed), sorted(parsed.items())[:2]))
    sec("readall AFTER start (raw)"); print(vk.readall_raw().rstrip()[:2000] or "(empty)")
    for key in started:
        vk.stop(key)
    sec("stopped"); print(" ".join(started))
    return 0

def cmd_start(a):
    if os.path.isfile(PID_FILE):
        pid = open(PID_FILE).read().strip()
        try:
            os.kill(int(pid), 0)
            raise SystemExit("[ERROR] already running [pid %s]; use 'stop' first" % pid)
        except (OSError, ValueError):
            os.remove(PID_FILE)
    if not a.name:
        esx = which("esxcli")
        if esx:
            rc, out, err = run([esx, "--formatter=keyvalue", "system", "hostname", "get"])
            m = re.search(r"FullyQualifiedDomainName\.string=(\S+)", out, re.I)
            if m:
                a.name = m.group(1)
    if not a.name:
        a.name = os.uname()[1]
    if a.mode in ("ops", "both") and not a.dry_run:
        if not a.ops_host or not a.ops_user:
            raise SystemExit("[ERROR] Operations address or account not set: put OPS_HOST and OPS_USER into %s [%s] "
                             "(fill in that file), or use --ops-host / --ops-user, or --mode file"
                             % (a.config_path, a.config_state))
        if not a.password:
            raise SystemExit("[ERROR] Operations password unavailable: OPS_PASS_ENC or OPS_ENC_KEY is empty in %s [%s] "
                             "(or openssl decrypt failed). Fill both in, or use --pass-file FILE / env OPS_PASSWORD, "
                             "or --mode file" % (a.config_path, a.config_state))
    Collector(a).loop()
    return 0

def cmd_stop(a):
    vb = which("vmkperf")
    stopped = 0
    if os.path.isfile(PID_FILE):
        pid = int(open(PID_FILE).read().strip() or 0)
        try:
            os.kill(pid, signal.SIGTERM)
            print("sent SIGTERM to pid %d (loop stops its own events on exit)" % pid)
            for _ in range(15):
                time.sleep(1)
                try:
                    os.kill(pid, 0)
                except OSError:
                    break
        except OSError:
            print("pid %d not running" % pid)
    # belt and braces: release any leftover events of ours
    if os.path.isfile(STATE_FILE) and vb:
        st = json.load(open(STATE_FILE))
        for k in st.get("events", []):
            run([vb, "stop", k]); stopped += 1
        os.remove(STATE_FILE)
    if os.path.isfile(PID_FILE):
        os.remove(PID_FILE)
    print("done (%d leftover events released)" % stopped)
    return 0

def cmd_status(a):
    if os.path.isfile(PID_FILE):
        pid = open(PID_FILE).read().strip()
        try:
            os.kill(int(pid), 0); print("running  pid", pid)
        except (OSError, ValueError):
            print("stale pid file", pid)
    else:
        print("not running")
    if os.path.isfile(STATE_FILE):
        print("state   ", open(STATE_FILE).read().strip())
    vb = which("vmkperf")
    if vb and os.path.isfile(STATE_FILE):
        for k in json.load(open(STATE_FILE)).get("events", []):
            vals = Vmkperf(vb).read(k)
            print("  %-20s %s" % (k, "%d pCPU values" % len(vals) if vals else "(no readable value)"))
    return 0

# ----------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description="ESXi vmkperf -> VCF Operations host custom metrics")
    p.add_argument("cmd", choices=["check", "probe", "diag", "worldprobe", "qosprobe", "start", "stop", "status"])
    p.add_argument("--cpu", help="event file name override (events/<cpu>.json); default: detect via cpu_map.json")
    p.add_argument("--events-dir", default=os.path.join(HERE, "events"))
    p.add_argument("--events", help="comma list of event keys to run (default: all in the event file, in priority order)")
    p.add_argument("--groups", default=GROUPS_DEFAULT, help="pCPU groups, e.g. 'VM1=0-15,VM2=16-31' or 'VM1=0-7,24-31;VM2=8-23'. "
                   "Only meaningful when the VMs' affinity sets do not overlap")
    p.add_argument("--interval", type=int, default=INTERVAL_DEFAULT)
    p.add_argument("--mode", choices=["ops", "file", "both"], default=MODE_DEFAULT)
    p.add_argument("--out", default=OUT_DIR_DEFAULT, help="CSV directory for --mode file|both (use a datastore path)")
    p.add_argument("--pcpu-csv", action="store_true", help="also write per-pCPU deltas CSV")
    p.add_argument("--qos", action="store_true", help="also sample LLC occupancy per rmID via vsish (default off; QOS_ENABLE in USER SETTINGS)")
    p.add_argument("--name", default=OPS_HOST_NAME_DEFAULT or None, help="HostSystem name in Operations (default: esxcli system hostname FQDN)")
    p.add_argument("--config", default=os.environ.get("OPS_PUSH_CONFIG") or None,
                   help="connection settings file (default: %s beside this script, then the folder above)" % CONFIG_NAME)
    p.add_argument("--ops-host", default=None, help="Operations address (default: env OPS_HOST, then OPS_HOST of the config file)")
    p.add_argument("--ops-user", default=None, help="Operations account (default: env OPS_USER, then OPS_USER of the config file)")
    p.add_argument("--pass-file", help="file holding the Operations password (chmod 600)")
    p.add_argument("--cacert", help="CA bundle for TLS verification")
    p.add_argument("--insecure", action="store_true", default=OPS_INSECURE_DEFAULT, help="skip TLS verification (default from OPS_INSECURE_DEFAULT)")
    p.add_argument("--verify-tls", action="store_true", help="force TLS verification even if OPS_INSECURE_DEFAULT is True")
    p.add_argument("--line-regex", help="override the 'vmkperf read' row parser (2 groups: pcpu, value); default expects '<pcpuID> <ctrVal> <timeStamp> <ctrType> <ctrNum>'")
    p.add_argument("--gp-cycles", action="store_true", help="count cycles on a GP counter even if ESXi's fixed cycle event is readable")
    p.add_argument("--dry-run", action="store_true", help="print the push JSON instead of sending")
    p.add_argument("--max-iter", type=int, default=0, help="stop after N intervals (0 = run until stop)")
    p.add_argument("--probe-sleep", type=int, default=5)
    a = p.parse_args()
    if a.verify_tls:
        a.insecure = False
    # connection settings: command-line option > environment variable > config file
    global OPS_PASS_ENC, OPS_ENC_KEY
    a.config_path, cfg = find_config(a.config)
    if a.config and cfg is None:
        raise SystemExit("[ERROR] config file not found or not readable: %s" % a.config)
    a.config_state = "read" if cfg is not None else "not found"
    cfg = cfg or {}
    a.ops_host = a.ops_host or os.environ.get("OPS_HOST") or cfg.get("OPS_HOST", "")
    a.ops_user = a.ops_user or os.environ.get("OPS_USER") or cfg.get("OPS_USER", "")
    OPS_PASS_ENC, OPS_ENC_KEY = cfg.get("OPS_PASS_ENC", ""), cfg.get("OPS_ENC_KEY", "")
    # password precedence: --pass-file > env OPS_PASSWORD > config file (openssl decrypt)
    a.password = os.environ.get("OPS_PASSWORD", "")
    if a.pass_file:
        a.password = open(a.pass_file).read().strip()
    a.password_source = "pass-file" if a.pass_file else ("env OPS_PASSWORD" if a.password else "")
    if not a.password and OPS_PASS_ENC and OPS_ENC_KEY:
        a.password = decrypt_pass()
        a.password_source = "decrypted from " + os.path.basename(a.config_path)
    return {"check": cmd_check, "probe": cmd_probe, "diag": cmd_diag, "worldprobe": cmd_worldprobe, "qosprobe": cmd_qosprobe, "start": cmd_start,
            "stop": cmd_stop, "status": cmd_status}[a.cmd](a)

if __name__ == "__main__":
    sys.exit(main())
