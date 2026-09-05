#!/usr/bin/env python3
"""Local mock of the MDEngine hosted endpoint (hosted/CONTRACT.md v1). Stdlib only.

Purpose: let the pull-runner (docker/runner-gpu/runner.sh) and the clients (CLI/MCP/app) be
developed and tested offline. Same routes and JSON as the real endpoint; storage = sqlite + a local
blob dir served at /blob/<name> (GET/PUT) standing in for presigned object-storage URLs. NOT the
production server: no TLS, no key hashing, no pod launcher (a "launch" here just marks the job
queued and prints the env a pod would get).

  python3 mock_endpoint.py --port 8787 --data /tmp/mde-mock
  curl -H 'Authorization: Bearer mde_test' localhost:8787/v1/me
"""
import argparse, json, os, secrets, sqlite3, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

RATES = {"any": 2.0, "rtx4090": 2.0, "a100": 4.0}   # $/GPU-h placeholder until GJOB-092
STATES = "created uploaded queued launching running uploading done failed cancelled".split()

def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def job_id(): return "MDJOB-%s-%s" % (time.strftime("%Y%m%d", time.gmtime()), secrets.token_hex(3).upper())

class DB:
    def __init__(self, path):
        self.c = sqlite3.connect(path, check_same_thread=False); self.c.row_factory = sqlite3.Row
        self.c.executescript("""
        create table if not exists keys(key text primary key, balance_usd real, created text);
        create table if not exists jobs(id text primary key, key text, token text, spec text, state text,
          created text, started text, finished text, gpu text, rate real, billed_s int default 0,
          thermo text default '[]', exitcode int, error text, attempt int default 1, last_hb real);
        """)
        if not self.c.execute("select 1 from keys where key='mde_test'").fetchone():
            self.c.execute("insert into keys values('mde_test', 20.0, ?)", (now(),)); self.c.commit()
    def key(self, k): return self.c.execute("select * from keys where key=?", (k,)).fetchone()
    def job(self, jid): return self.c.execute("select * from jobs where id=?", (jid,)).fetchone()
    def set(self, jid, **kw):
        cols = ", ".join(f"{k}=?" for k in kw); self.c.execute(f"update jobs set {cols} where id=?", (*kw.values(), jid)); self.c.commit()

def status(j):
    spec = json.loads(j["spec"])
    billed = j["billed_s"]
    if j["state"] == "running" and j["started"]:
        billed = int(time.time() - time.mktime(time.strptime(j["started"], "%Y-%m-%dT%H:%M:%SZ")) + time.timezone)
    return {"id": j["id"], "state": j["state"], "states": "|".join(STATES), "created": j["created"],
            "started": j["started"], "finished": j["finished"], "gpu": j["gpu"], "rate_usd_per_h": j["rate"],
            "billed_s": billed, "cost_usd": round(billed * j["rate"] / 3600, 4), "thermo_tail": json.loads(j["thermo"]),
            "exitcode": j["exitcode"], "error": j["error"], "attempt": j["attempt"], "label": spec.get("label")}

class H(BaseHTTPRequestHandler):
    db: DB; data: str; base: str
    def log_message(self, *a): pass
    def send(self, code, obj=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return self.rfile.read(n) if n else b""
    def bearer(self):
        a = self.headers.get("Authorization", ""); return a[7:] if a.startswith("Bearer ") else None
    def blob(self, name): return os.path.join(self.data, "blobs", name)

    def do_GET(self):
        p = urlparse(self.path).path.rstrip("/"); parts = p.split("/")
        if parts[1] == "blob":
            f = self.blob(parts[2])
            if not os.path.exists(f): return self.send(404, {"error": "no blob"})
            with open(f, "rb") as fh: return self.send(200, raw=fh.read(), ctype="application/gzip")
        if parts[1] == "internal":                                   # pod side
            j = self.db.job(parts[3]) if len(parts) > 3 else None
            if not j or self.bearer() != j["token"]: return self.send(401, {"error": "bad token"})
            spec = json.loads(j["spec"])
            return self.send(200, {"input_url": f"{self.base}/blob/{j['id']}.in.tar.gz", "input": spec["input"],
                                   "launch": spec.get("launch", "default"), "wall_limit_s": spec.get("wall_limit_s", 86400),
                                   "results_put_url": f"{self.base}/blob/{j['id']}.out.tar.gz"})
        k = self.db.key(self.bearer() or "")
        if not k: return self.send(401, {"error": "bad api key"})
        if p == "/v1/me": return self.send(200, {"balance_usd": k["balance_usd"], "rate_table": RATES, "keys_created": k["created"]})
        if p == "/v1/jobs":
            rows = self.db.c.execute("select * from jobs where key=? order by created desc limit 50", (k["key"],)).fetchall()
            return self.send(200, {"jobs": [status(j) for j in rows]})
        if len(parts) >= 4 and parts[2] == "jobs":
            j = self.db.job(parts[3])
            if not j or j["key"] != k["key"]: return self.send(404, {"error": "no job"})
            if len(parts) == 4: return self.send(200, status(j))
            if parts[4] == "results":
                if j["state"] not in ("done", "failed"): return self.send(409, {"error": "not finished"})
                f = self.blob(f"{j['id']}.out.tar.gz"); sz = os.path.getsize(f) if os.path.exists(f) else 0
                return self.send(200, {"download_url": f"{self.base}/blob/{j['id']}.out.tar.gz", "expires": None, "bytes": sz})
        self.send(404, {"error": "no route"})

    def do_PUT(self):
        parts = urlparse(self.path).path.split("/")
        if parts[1] != "blob": return self.send(404, {"error": "no route"})
        os.makedirs(os.path.dirname(self.blob("x")), exist_ok=True)
        with open(self.blob(parts[2]), "wb") as fh: fh.write(self.body())
        jid = parts[2].split(".")[0]
        if parts[2].endswith(".in.tar.gz") and self.db.job(jid) and self.db.job(jid)["state"] == "created": self.db.set(jid, state="uploaded")
        self.send(200, {"ok": True})

    def do_POST(self):
        p = urlparse(self.path).path.rstrip("/"); parts = p.split("/")
        if parts[1] == "internal":                                   # pod side: heartbeat / done
            j = self.db.job(parts[3])
            if not j or self.bearer() != j["token"]: return self.send(401, {"error": "bad token"})
            b = json.loads(self.body() or b"{}")
            if parts[4] == "heartbeat":
                kw = {"thermo": json.dumps(b.get("thermo_tail", [])[-20:]), "last_hb": time.time()}
                if j["state"] in ("queued", "launching"): kw.update(state="running", started=now())
                self.db.set(j["id"], **kw); return self.send(200, {"ok": True})
            if parts[4] == "done":
                rc = int(b.get("exitcode", 1)); err = b.get("error")
                started = j["started"] or now(); billed = int(b.get("elapsed_s", 0))
                have = os.path.exists(self.blob(f"{j['id']}.out.tar.gz"))
                state = "done" if rc == 0 and have else "failed"
                if not have and not err: err = "no_results"
                self.db.set(j["id"], state=state, finished=now(), started=started, exitcode=rc, error=err, billed_s=billed, token=secrets.token_hex(4))  # token invalidated
                cost = billed * j["rate"] / 3600
                if err not in ("pod_lost",): self.db.c.execute("update keys set balance_usd=balance_usd-? where key=?", (cost, j["key"])); self.db.c.commit()
                print(f"[mock] {j['id']} -> {state} rc={rc} err={err} billed={billed}s cost=${cost:.4f}", flush=True)
                return self.send(200, {"ok": True, "state": state})
        k = self.db.key(self.bearer() or "")
        if not k: return self.send(401, {"error": "bad api key"})
        if p == "/v1/jobs":
            spec = json.loads(self.body() or b"{}")
            if "input" not in spec: return self.send(400, {"error": "input required"})
            gpu = spec.get("gpu", "any"); rate = RATES.get(gpu)
            if rate is None: return self.send(400, {"error": "unknown gpu"})
            if k["balance_usd"] < rate * max(int(spec.get("estimate_s", 0)), 900) / 3600: return self.send(402, {"error": "insufficient balance"})
            jid = job_id(); tok = "jt_" + secrets.token_hex(16)
            self.db.c.execute("insert into jobs(id,key,token,spec,state,created,gpu,rate) values(?,?,?,?,?,?,?,?)",
                              (jid, k["key"], tok, json.dumps(spec), "created", now(), gpu, rate)); self.db.c.commit()
            return self.send(201, {"id": jid, "upload_url": f"{self.base}/blob/{jid}.in.tar.gz", "upload_expires": None})
        if len(parts) == 5 and parts[2] == "jobs" and parts[4] == "start":
            j = self.db.job(parts[3])
            if not j or j["key"] != k["key"]: return self.send(404, {"error": "no job"})
            if j["state"] != "uploaded": return self.send(409, {"error": f"state is {j['state']}"})
            self.db.set(j["id"], state="queued")
            # The real endpoint launches a pod here. The mock prints what the launcher would inject.
            print(f"[mock] LAUNCH {j['id']}: MDE_ENDPOINT={self.base} MDE_JOB_ID={j['id']} MDE_JOB_TOKEN={j['token']}", flush=True)
            with open(os.path.join(self.data, "launch.env"), "w") as fh:
                fh.write(f"MDE_ENDPOINT={self.base}\nMDE_JOB_ID={j['id']}\nMDE_JOB_TOKEN={j['token']}\n")
            return self.send(202, {"id": j["id"], "state": "queued"})
        self.send(404, {"error": "no route"})

    def do_DELETE(self):
        parts = urlparse(self.path).path.rstrip("/").split("/")
        k = self.db.key(self.bearer() or "")
        if not k or len(parts) != 4: return self.send(401, {"error": "bad api key"})
        j = self.db.job(parts[3])
        if not j or j["key"] != k["key"]: return self.send(404, {"error": "no job"})
        if j["state"] in ("done", "failed", "cancelled"): return self.send(409, {"error": "terminal"})
        self.db.set(j["id"], state="cancelled", finished=now(), error="cancelled"); self.send(202, {"id": j["id"], "state": "cancelled"})

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--port", type=int, default=8787); ap.add_argument("--data", default="/tmp/mde-mock")
    a = ap.parse_args(); os.makedirs(os.path.join(a.data, "blobs"), exist_ok=True)
    H.db = DB(os.path.join(a.data, "mock.sqlite")); H.data = a.data; H.base = f"http://127.0.0.1:{a.port}"
    print(f"[mock] listening on {H.base}  data={a.data}  test key: mde_test ($20)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()
