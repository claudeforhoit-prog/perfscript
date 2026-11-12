import json, time, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
OUT = sys.argv[1]; PORT = int(sys.argv[2]); TOKEN = "tok123"; RID = "res-vm-1"; NAME = "testvm"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None):
        b = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth(self): return self.headers.get("Authorization", "") == "OpsToken " + TOKEN
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0")); body = self.rfile.read(n).decode()
        u = urlparse(self.path).path
        if u.endswith("/auth/token/acquire"):
            d = json.loads(body)
            open(OUT + "/auth.json", "w").write(json.dumps({"username": d.get("username"), "authSource": d.get("authSource")}))
            return self._send(200, {"token": TOKEN, "validity": int((time.time() + 1800) * 1000)})
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        if u.endswith("/resources/%s/stats" % RID):
            json.loads(body); open(OUT + "/stats.jsonl", "a").write(body + "\n"); return self._send(200)
        self._send(404, {"message": "no"})
    def do_GET(self):
        if not self._auth(): return self._send(401, {"message": "unauthorized"})
        q = parse_qs(urlparse(self.path).query)
        name = (q.get("name") or [""])[0]
        rl = [{"identifier": RID, "resourceKey": {"name": NAME, "resourceKindKey": "VirtualMachine"}}] if name in ("", NAME) else []
        self._send(200, {"resourceList": rl})
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
