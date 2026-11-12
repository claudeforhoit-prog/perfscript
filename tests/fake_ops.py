#!/usr/bin/env python3
# Mock of the VCF Operations suite-api calls the collectors use. For local tests only.
#   usage: python3 fake_ops.py <record dir> <port>
# Objects: <record dir>/preset.json may hold a list of
#   {"identifier": "...", "name": "...", "adapterKindKey": "...", "resourceKindKey": "..."}
# Without that file there is one object: VirtualMachine "testvm" (identifier res-vm-1).
# Objects created through POST /api/resources/adapterkinds/{key} are kept in memory.
# Control files in <record dir>:  fail_create = that POST answers 403,  fail_lookup = GET /api/resources answers 500.
# Records: auth.json (last login), requests.jsonl (method, path, query), stats.jsonl (stat bodies),
#          created.jsonl (objects created), props.json (last property body).
import json, os, re, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

OUT = sys.argv[1]; PORT = int(sys.argv[2]); TOKEN = "tok123"
PRESET = os.path.join(OUT, "preset.json")
OBJECTS = (json.load(open(PRESET)) if os.path.isfile(PRESET) else
           [{"identifier": "res-vm-1", "name": "testvm", "adapterKindKey": "VMWARE", "resourceKindKey": "VirtualMachine"}])
SEQ = [0]

def rec(name, obj):
    with open(os.path.join(OUT, name), "a") as f:
        f.write(json.dumps(obj) + "\n")

def as_resource(o):
    return {"identifier": o["identifier"],
            "resourceKey": {"name": o["name"], "adapterKindKey": o["adapterKindKey"], "resourceKindKey": o["resourceKindKey"]}}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None):
        b = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth(self):
        return self.headers.get("Authorization", "") == "OpsToken " + TOKEN
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0")); body = self.rfile.read(n).decode()
        u = urlparse(self.path).path
        if u.endswith("/auth/token/acquire"):
            d = json.loads(body)
            open(os.path.join(OUT, "auth.json"), "w").write(json.dumps({"username": d.get("username"), "authSource": d.get("authSource")}))
            return self._send(200, {"token": TOKEN, "validity": int((time.time() + 1800) * 1000)})
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        rec("requests.jsonl", {"method": "POST", "path": u})
        m = re.search(r"/suite-api/api/resources/adapterkinds/([^/]+)$", u)
        if m:                                           # Create Resource Using Adapter Kind
            if os.path.isfile(os.path.join(OUT, "fail_create")):
                return self._send(403, {"message": "The user does not have the privilege to perform this operation"})
            d = json.loads(body); rk = d.get("resourceKey") or {}
            if not rk.get("name") or not rk.get("resourceKindKey") or rk.get("adapterKindKey") != m.group(1):
                return self._send(500, {"message": "invalid resourceKey"})
            for o in OBJECTS:                           # the same key again: answer with the existing object
                if (o["name"], o["adapterKindKey"], o["resourceKindKey"]) == (rk["name"], rk["adapterKindKey"], rk["resourceKindKey"]):
                    return self._send(201, as_resource(o))
            SEQ[0] += 1
            o = {"identifier": "res-bm-%d" % SEQ[0], "name": rk["name"], "adapterKindKey": rk["adapterKindKey"], "resourceKindKey": rk["resourceKindKey"]}
            OBJECTS.append(o); rec("created.jsonl", dict(o, body=d))
            return self._send(201, as_resource(o))
        m = re.search(r"/suite-api/api/resources/([^/]+)/stats(/adapterkinds/([^/]+))?$", u)
        if m and any(o["identifier"] == m.group(1) for o in OBJECTS):
            json.loads(body); rec("stats.jsonl", json.loads(body)); rec("stats_paths.jsonl", {"id": m.group(1), "push_kind": m.group(3)})
            return self._send(200)
        m = re.search(r"/suite-api/api/resources/([^/]+)/properties(/adapterkinds/([^/]+))?$", u)
        if m and any(o["identifier"] == m.group(1) for o in OBJECTS):
            json.loads(body); open(os.path.join(OUT, "props.json"), "w").write(body); rec("props_paths.jsonl", {"id": m.group(1), "push_kind": m.group(3)})
            return self._send(200)
        self._send(404, {"message": "no such resource or operation"})
    def do_GET(self):
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        pu = urlparse(self.path); q = parse_qs(pu.query)
        rec("requests.jsonl", {"method": "GET", "path": pu.path, "query": {k: v[0] for k, v in q.items()}})
        if not pu.path.endswith("/suite-api/api/resources"):
            return self._send(404, {"message": "no"})
        if os.path.isfile(os.path.join(OUT, "fail_lookup")) and "name" in q:
            return self._send(500, {"message": "internal error"})
        name = (q.get("name") or [""])[0]
        ak = (q.get("adapterKind") or q.get("adapterKindKey") or [""])[0]
        rkind = (q.get("resourceKind") or [""])[0]
        rl = [as_resource(o) for o in OBJECTS
              if (not name or o["name"].lower() == name.lower()) and (not ak or o["adapterKindKey"] == ak)
              and (not rkind or o["resourceKindKey"] == rkind)]
        self._send(200, {"resourceList": rl})

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
