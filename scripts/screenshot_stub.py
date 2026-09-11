#!/usr/bin/env python3
"""Local stand-in for api.forcefieldsilicon.com/v1, for App Store screenshots ONLY.

Job ids and gpu names below match what production actually returns (MDJOB-<date>-<hex>, and a
rate_table key such as "rtx4090") — the app prints both verbatim, so invented formats would put a
shape in the App Store listing that the service never emits.
Serves plausible sample data so the balance and job-list screens render without
using arvand's real API key. Accepts any bearer token."""
import json, http.server, socketserver

ACCOUNT = {"balance_usd": 41.80, "rate_table": {"any": 2.0, "rtx4090": 2.0}, "keys_created": "2026-08-14"}

JOBS = {"jobs": [
    {"id": "MDJOB-20260909-D95435", "state": "running", "created": "2026-09-09T17:41:02Z",
     "started": "2026-09-09T17:43:15Z", "finished": None, "gpu": "rtx4090",
     "rate_usd_per_h": 2.0, "billed_s": 4110, "cost_usd": 2.28,
     "thermo_tail": ["   240000   1198.42   -8421.33   1.0021",
                     "   245000   1201.07   -8419.88   1.0018",
                     "   250000   1199.65   -8422.41   1.0023"],
     "exitcode": None, "error": None, "attempt": 1,
     "label": "alumina oxidation 1200K"},
    {"id": "MDJOB-20260908-7C04AB", "state": "done", "created": "2026-09-08T22:10:44Z",
     "started": "2026-09-08T22:11:20Z", "finished": "2026-09-09T01:36:55Z",
     "gpu": "rtx4090", "rate_usd_per_h": 2.0, "billed_s": 12335, "cost_usd": 6.85,
     "thermo_tail": ["  1000000    298.11   -9903.72   0.9998"],
     "exitcode": 0, "error": None, "attempt": 1, "label": "LHRH adhesion window 4"},
    {"id": "MDJOB-20260908-5B9D17", "state": "done", "created": "2026-09-08T14:02:09Z",
     "started": "2026-09-08T14:02:51Z", "finished": "2026-09-08T15:20:33Z",
     "gpu": "rtx4090", "rate_usd_per_h": 2.0, "billed_s": 4662, "cost_usd": 2.59,
     "thermo_tail": ["   500000    300.04   -7188.20   1.0005"],
     "exitcode": 0, "error": None, "attempt": 1, "label": "nacre SLLOD conc3"},
    {"id": "MDJOB-20260907-4A7E88", "state": "failed", "created": "2026-09-07T09:14:00Z",
     "started": "2026-09-07T09:14:38Z", "finished": "2026-09-07T09:16:02Z",
     "gpu": "rtx4090", "rate_usd_per_h": 2.0, "billed_s": 84, "cost_usd": 0.05,
     "thermo_tail": [], "exitcode": 1,
     "error": "ERROR: Unknown pair style reax/c (src/force.cpp:270)", "attempt": 1,
     "label": "AlO ladder RUN-020R"},
]}

class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path.rstrip("/")
        if p.endswith("/me"): return self._send(ACCOUNT)
        if p.endswith("/jobs"): return self._send(JOBS)
        for j in JOBS["jobs"]:
            if p.endswith("/jobs/" + j["id"]): return self._send(j)
        self._send({"error": "not found"}, 404)
    def log_message(self, *a): pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 8790), H) as s:
    print("stub on 8790", flush=True); s.serve_forever()
