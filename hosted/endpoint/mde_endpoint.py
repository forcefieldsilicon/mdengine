#!/usr/bin/env python3
"""MDEngine hosted endpoint (hosted/CONTRACT.md v1). Python 3.12 stdlib only.

Evolved from hosted/mock/mock_endpoint.py: same routes and JSON shapes for the client-facing
(/v1/*), blob (/blob/*), and pod-facing (/internal/*) APIs, plus:

  * API keys stored as sha256 hashes only (table `keys`); balance derived from a credit ledger
    (table `credits`) minus billed job cost -- there is no mutable balance column.
  * GET  /v1/health                        liveness + whether GPU runners are open
  * GET  /welcome?session_id=...           Stripe Checkout redirect target: issue/credit a key
  * POST /v1/stripe/webhook                checkout.session.completed backstop (same handler)
  * Job submission gated by MDE_RUNNERS_OPEN=1 (auth + balance still checked while closed).
  * RunPod pod launcher (mde_launcher.py) when RUNPOD_API_KEY is set: one pod per job, deleted at every
    terminal state; watchdog handles launch timeout / pod_lost; reaper enforces "a pod exists only while
    a job is launching/running" (CONTRACT.md, GJOB-099). Without the key `start` writes launch.env (dev).

Runs behind Caddy (TLS) on 127.0.0.1:8080 under systemd; see deploy/ and README.md.

  python3 mde_endpoint.py --env-file /etc/mde/endpoint.env
"""
import argparse, hashlib, hmac, json, os, secrets, sqlite3, sys, threading, time, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mde_launcher import RunPodLauncher, FakeLauncher, NoCapacity, LauncherError, parse_ladder, pod_age_s

VERSION = "0.1.0"
STATES = "created uploaded queued launching running uploading done failed cancelled".split()
TERMINAL = ("done", "failed", "cancelled")
NOT_BILLED_ERRORS = ("pod_lost", "no_capacity")
MAX_BLOB = 2_000_000_000            # 2 GB tarball cap (CONTRACT.md)
BLOB_TTL_S = 7 * 86400              # signed blob URLs stay valid for a week (results linger)
HEARTBEAT_LOST_S = 120              # 30 s heartbeat, 3 missed -> pod_lost
PENDING_KEY_TTL_S = 7 * 86400       # unshown keys from webhook-first purchases are purged after this
STRIPE_TOLERANCE_S = 300
REAPER_GRACE_S = 1200               # reaper kills a pod older than its job's wall_limit_s + this (CONTRACT: +20 min)
POD_PREFIX = "mde-"

# ----------------------------------------------------------------------------- helpers

def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def parse_ts(s): return time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone if s else None
def job_id(): return "MDJOB-%s-%s" % (time.strftime("%Y%m%d", time.gmtime()), secrets.token_hex(3).upper())
def sha256(s): return hashlib.sha256(s.encode() if isinstance(s, str) else s).hexdigest()

def log(ev, **kw):
    """One JSON line per event on stdout (journald). Never pass full keys or secrets."""
    rec = {"ts": now(), "ev": ev}; rec.update(kw)
    print(json.dumps(rec, separators=(",", ":"), default=str), flush=True)

def new_api_key():
    """Returns (full_key, key_id, key_hash). Only key_id/key_hash are ever stored."""
    full = "mde_" + secrets.token_hex(16); h = sha256(full); return full, h[:8], h

def load_env_file(path):
    if not path or not os.path.exists(path): return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            k, v = line.split("=", 1); v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
            os.environ.setdefault(k.strip(), v)

def parse_packs(s):
    """MDE_PACKS="price_xxx:25:12.5,price_yyy:100:50" -> {price_id: (usd, gpu_hours)}"""
    out = {}
    for item in (s or "").split(","):
        item = item.strip()
        if not item: continue
        pid, usd, hours = item.split(":"); out[pid] = (float(usd), float(hours))
    return out

def parse_rates(s):
    if not s: return {"any": 2.0, "rtx4090": 2.0}
    return {k.strip(): float(v) for k, v in (kv.split(":") for kv in s.split(",") if kv.strip())}

class Config:
    def __init__(self, env=None):
        e = env if env is not None else os.environ
        self.db = e.get("MDE_DB", "/var/lib/mde/mde.sqlite")
        self.blobs = e.get("MDE_BLOBS", "/var/lib/mde/blobs")
        self.bind = e.get("MDE_BIND", "127.0.0.1:8080")
        self.public_url = e.get("MDE_PUBLIC_URL", "").rstrip("/")   # what clients/pods can reach, e.g. https://api.example.com
        self.stripe_secret = e.get("STRIPE_SECRET_KEY", "")
        self.webhook_secret = e.get("STRIPE_WEBHOOK_SECRET", "")
        self.packs = parse_packs(e.get("MDE_PACKS", ""))
        self.rates = parse_rates(e.get("MDE_RATES", ""))
        self.runners_open = e.get("MDE_RUNNERS_OPEN", "") == "1"
        self.admin_token = e.get("MDE_ADMIN_TOKEN", "")
        self.brand = "ForceField Silicon / MDEngine"
        # RunPod launcher (mde_launcher.py). No RUNPOD_API_KEY -> no launcher -> `start` writes launch.env.
        self.runpod_api_key = e.get("RUNPOD_API_KEY", "")
        self.runner_image = e.get("MDE_RUNNER_IMAGE", "")             # default in mde_launcher.DEFAULT_IMAGE
        self.pod_disk_gb = int(e.get("MDE_POD_DISK_GB", "20") or 20)
        self.min_cuda = e.get("MDE_MIN_CUDA", "12.4")
        self.gpu_ladder = parse_ladder(e.get("MDE_GPU_LADDER", ""))
        self.launch_timeout_s = int(e.get("MDE_LAUNCH_TIMEOUT_S", "600") or 600)
        self.reaper_interval_s = int(e.get("MDE_REAPER_INTERVAL_S", "300") or 300)

# ----------------------------------------------------------------------------- storage

SCHEMA = """
create table if not exists keys(key_id text primary key, key_hash text unique not null, email text,
  created text not null, label text);
create table if not exists credits(session_id text primary key, key_id text not null, usd real not null,
  gpu_s integer not null, price_id text, created text not null);
create table if not exists jobs(id text primary key, key_id text not null, token_hash text, spec text not null,
  state text not null, created text not null, started text, finished text, gpu text, rate real,
  billed_s integer default 0, thermo text default '[]', exitcode integer, error text, attempt integer default 1,
  last_hb real, pod_id text, launched_at text);
create table if not exists pending_keys(session_id text primary key, key_id text not null, full_key text not null,
  created text not null);
create table if not exists meta(k text primary key, v text not null);
create index if not exists jobs_key on jobs(key_id, created);
create index if not exists credits_key on credits(key_id);
"""
MIGRATIONS = ["alter table jobs add column pod_id text", "alter table jobs add column launched_at text"]

class DB:
    """sqlite wrapper shared by the service and the admin CLI. All access under one RLock."""
    def __init__(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        self.lock = threading.RLock()
        self.c = sqlite3.connect(path, check_same_thread=False, timeout=10)
        self.c.row_factory = sqlite3.Row
        with self.lock:
            self.c.execute("pragma journal_mode=wal"); self.c.executescript(SCHEMA)
            for m in MIGRATIONS:                     # idempotent: pre-launcher databases gain the new columns
                try: self.c.execute(m); self.c.commit()
                except sqlite3.OperationalError as e:
                    if "duplicate column" not in str(e): raise
            if not self.meta("blob_secret"): self.set_meta("blob_secret", secrets.token_hex(32))

    def q(self, sql, *args):
        with self.lock: return self.c.execute(sql, args).fetchall()
    def one(self, sql, *args):
        with self.lock: return self.c.execute(sql, args).fetchone()
    def x(self, sql, *args):
        with self.lock: self.c.execute(sql, args); self.c.commit()
    def meta(self, k):
        r = self.one("select v from meta where k=?", k); return r["v"] if r else None
    def set_meta(self, k, v): self.x("insert or replace into meta(k,v) values(?,?)", k, v)

    # keys
    def key_by_hash(self, h): return self.one("select * from keys where key_hash=?", h)
    def key_by_id(self, kid): return self.one("select * from keys where key_id=?", kid)
    def create_key(self, email=None, label=None):
        full, kid, h = new_api_key()
        self.x("insert into keys(key_id,key_hash,email,created,label) values(?,?,?,?,?)", kid, h, email, now(), label)
        return full, kid

    # ledger
    def add_credit(self, session_id, key_id, usd, gpu_s, price_id):
        """Idempotent on session_id. Returns True if inserted, False if it already existed."""
        with self.lock:
            if self.one("select 1 from credits where session_id=?", session_id): return False
            self.x("insert into credits(session_id,key_id,usd,gpu_s,price_id,created) values(?,?,?,?,?,?)",
                   session_id, key_id, float(usd), int(gpu_s), price_id, now())
            return True

    def billed_usd(self, key_id):
        total = 0.0
        for j in self.q("select * from jobs where key_id=? and state not in ('created','uploaded','queued','launching')", key_id):
            total += job_cost(j)
        return total

    def credited_usd(self, key_id):
        r = self.one("select coalesce(sum(usd),0) s from credits where key_id=?", key_id); return float(r["s"])

    def balance(self, key_id): return round(self.credited_usd(key_id) - self.billed_usd(key_id), 6)

    # jobs
    def job(self, jid): return self.one("select * from jobs where id=?", jid)
    def job_by_pod(self, pod_id): return self.one("select * from jobs where pod_id=?", pod_id) if pod_id else None
    def set_job(self, jid, **kw):
        cols = ", ".join(f"{k}=?" for k in kw); self.x(f"update jobs set {cols} where id=?", *kw.values(), jid)

def billed_seconds(j):
    """Live seconds for a running job; stored value otherwise."""
    if j["state"] == "running" and j["started"]:
        return max(int(time.time() - parse_ts(j["started"])), j["billed_s"] or 0)
    return j["billed_s"] or 0

def job_cost(j):
    if j["error"] in NOT_BILLED_ERRORS: return 0.0
    return round(billed_seconds(j) * (j["rate"] or 0) / 3600, 6)

def status(j):
    spec = json.loads(j["spec"]); billed = billed_seconds(j)
    return {"id": j["id"], "state": j["state"], "states": "|".join(STATES), "created": j["created"],
            "started": j["started"], "finished": j["finished"], "gpu": j["gpu"], "rate_usd_per_h": j["rate"],
            "billed_s": billed, "cost_usd": round(job_cost(j), 4), "thermo_tail": json.loads(j["thermo"] or "[]"),
            "exitcode": j["exitcode"], "error": j["error"], "attempt": j["attempt"], "label": spec.get("label"),
            "pod_id": j["pod_id"]}

# ----------------------------------------------------------------------------- Stripe

def stripe_fetch_session(session_id, secret_key):
    """GET the Checkout Session with line_items expanded. Module-level so tests can monkeypatch it."""
    url = "https://api.stripe.com/v1/checkout/sessions/%s?expand[]=line_items" % urllib.parse.quote(session_id, safe="")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + secret_key, "User-Agent": "mde-endpoint/" + VERSION})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

def verify_stripe_signature(payload: bytes, header: str, secret: str, tolerance=STRIPE_TOLERANCE_S, now_ts=None):
    """Stripe-Signature: t=<unix>,v1=<hex>[,v1=<hex>...]; v1 = HMAC-SHA256(secret, f"{t}.{payload}")."""
    if not header or not secret: return False
    parts = dict(p.split("=", 1) for p in header.split(",") if "=" in p)
    t = parts.get("t"); sigs = [p.split("=", 1)[1] for p in header.split(",") if p.startswith("v1=")]
    if not t or not sigs or not t.isdigit(): return False
    if abs((now_ts or time.time()) - int(t)) > tolerance: return False
    expected = hmac.new(secret.encode(), f"{t}.".encode() + payload, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, s) for s in sigs)

def stripe_sign(payload: bytes, secret: str, ts=None):
    """Produce a Stripe-Signature header (used by tests and the README's rotation check)."""
    ts = int(ts or time.time()); sig = hmac.new(secret.encode(), f"{ts}.".encode() + payload, hashlib.sha256).hexdigest()
    return f"t={ts},v1={sig}"

# ----------------------------------------------------------------------------- application

class App:
    def __init__(self, cfg: Config):
        self.cfg = cfg; self.db = DB(cfg.db)
        os.makedirs(cfg.blobs, exist_ok=True)
        self.grant_lock = threading.Lock()
        self.public_url = cfg.public_url or "http://" + cfg.bind
        self.launch_env = os.path.join(os.path.dirname(os.path.abspath(cfg.blobs)), "launch.env")
        self.launcher = RunPodLauncher(cfg, public_url=self.public_url) if cfg.runpod_api_key else None   # tests inject FakeLauncher
        self.reaper_fail = {}          # pod_id -> consecutive reaper delete failures (in memory; 3 = reaper.stuck)
        self.last_reap = 0.0
        self._bg = []; self._bg_lock = threading.Lock()

    # -- background work (pod create/delete never blocks an HTTP response); join_bg() is for tests
    def spawn(self, target, *args):
        t = threading.Thread(target=target, args=args, daemon=True)
        with self._bg_lock:
            self._bg = [x for x in self._bg if x.is_alive()]; self._bg.append(t)
        t.start(); return t
    def join_bg(self, timeout=10):
        deadline = time.time() + timeout
        while True:
            with self._bg_lock: live = [x for x in self._bg if x.is_alive()]
            if not live or time.time() > deadline: return not live
            live[0].join(max(0.01, deadline - time.time()))

    # -- blob URLs stand in for presigned object-storage URLs: HMAC over name|exp
    def blob_path(self, name): return os.path.join(self.cfg.blobs, name)
    def blob_sig(self, name, exp): return hmac.new(self.db.meta("blob_secret").encode(), f"{name}|{exp}".encode(), hashlib.sha256).hexdigest()[:32]
    def blob_url(self, name, ttl=BLOB_TTL_S):
        exp = int(time.time()) + ttl; return f"{self.public_url}/blob/{name}?exp={exp}&sig={self.blob_sig(name, exp)}", exp
    def blob_ok(self, name, query):
        q = parse_qs(query); exp = (q.get("exp") or [""])[0]; sig = (q.get("sig") or [""])[0]
        if not exp.isdigit() or int(exp) < time.time(): return False
        return hmac.compare_digest(self.blob_sig(name, int(exp)), sig)

    # -- purchase: one idempotent handler for /welcome and the webhook
    def grant(self, sess, source):
        """Credit a paid Checkout Session once. Returns dict(kind, key_id, full_key|None, usd, gpu_h, balance)."""
        sid = sess.get("id");
        if not sid: raise ValueError("session has no id")
        if sess.get("payment_status") != "paid": raise ValueError("payment_status=%s" % sess.get("payment_status"))
        with self.grant_lock:
            existing = self.db.one("select * from credits where session_id=?", sid)
            if existing:
                pend = self.db.one("select * from pending_keys where session_id=?", sid)
                full = None
                if pend and source == "welcome":            # first visit after a webhook-first grant: show once
                    full = pend["full_key"]; self.db.x("delete from pending_keys where session_id=?", sid)
                    log("key.revealed", key_id=existing["key_id"], session=sid)
                return {"kind": "already", "key_id": existing["key_id"], "full_key": full, "usd": existing["usd"],
                        "gpu_h": existing["gpu_s"] / 3600, "balance": self.db.balance(existing["key_id"])}
            price_id, usd, gpu_h = self.pack_for(sess)
            ref = (sess.get("client_reference_id") or "").strip()
            details = sess.get("customer_details") or {}
            email = details.get("email") or sess.get("customer_email")
            k = self.db.key_by_id(ref) if ref else None
            if k:
                self.db.add_credit(sid, k["key_id"], usd, gpu_h * 3600, price_id)
                log("credit.topup", key_id=k["key_id"], usd=usd, gpu_h=gpu_h, price_id=price_id, session=sid, source=source)
                return {"kind": "topup", "key_id": k["key_id"], "full_key": None, "usd": usd, "gpu_h": gpu_h, "balance": self.db.balance(k["key_id"])}
            full, kid = self.db.create_key(email=email, label="stripe:" + sid[-8:])
            self.db.add_credit(sid, kid, usd, gpu_h * 3600, price_id)
            if source != "welcome":   # buyer has not seen the key yet: hold it for the welcome page
                self.db.x("insert or replace into pending_keys(session_id,key_id,full_key,created) values(?,?,?,?)", sid, kid, full, now())
            log("credit.new_key", key_id=kid, usd=usd, gpu_h=gpu_h, price_id=price_id, session=sid, source=source, has_email=bool(email))
            return {"kind": "new", "key_id": kid, "full_key": full, "usd": usd, "gpu_h": gpu_h, "balance": self.db.balance(kid)}

    def pack_for(self, sess):
        """price id decides the hours (coupons do not reduce them); usd credited = hours * rate."""
        rate = self.cfg.rates.get("any", 2.0)
        price_id = None
        try: price_id = sess["line_items"]["data"][0]["price"]["id"]
        except (KeyError, IndexError, TypeError): pass
        if price_id in self.cfg.packs:
            _, gpu_h = self.cfg.packs[price_id]; return price_id, round(gpu_h * rate, 2), gpu_h
        # Unknown price id: honor the amount actually paid at the base rate, and say so in the log.
        usd = (sess.get("amount_total") or 0) / 100.0
        log("pack.unknown_price", price_id=price_id, amount_total=sess.get("amount_total"))
        return price_id, round(usd, 2), round(usd / rate, 4)

    def purge_pending(self):
        cutoff = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - PENDING_KEY_TTL_S))
        self.db.x("delete from pending_keys where created < ?", cutoff)

    # -- pods: one per job, created after `start`, deleted at every terminal state
    def launch_job(self, jid, token, wall, gpu):
        """Background: walk the launcher's ladder; queued -> launching(pod_id) or failed:no_capacity (unbilled)."""
        try: pod_id = self.launcher.create(jid, token, wall, gpu)
        except NoCapacity as e:
            log("job.no_capacity", job=jid, error=str(e)); self.fail_unlaunched(jid); return
        except Exception as e:
            log("launch.error", job=jid, error=repr(e)); self.fail_unlaunched(jid); return
        j = self.db.job(jid)
        if not j: self.release_pod(jid, pod_id, "job_vanished"); return
        if j["state"] == "queued": self.db.set_job(jid, state="launching", pod_id=pod_id, launched_at=now())
        elif j["state"] in ("launching", "running"): self.db.set_job(jid, pod_id=pod_id, launched_at=j["launched_at"] or now())
        else:                                        # cancelled while the create call was in flight: no orphan
            self.db.set_job(jid, pod_id=pod_id); self.release_pod(jid, pod_id, "terminal_during_launch"); return
        log("job.launching", job=jid, key_id=j["key_id"], pod_id=pod_id)

    def fail_unlaunched(self, jid):
        j = self.db.job(jid)
        if j and j["state"] in ("queued", "launching"):
            self.db.set_job(jid, state="failed", finished=now(), error="no_capacity", token_hash=None)

    def release_pod(self, jid, pod_id, reason):
        """Delete the job's pod in the background (never from the request thread)."""
        if not self.launcher or not pod_id: return
        def run():
            try: self.launcher.delete(pod_id); log("pod.deleted", job=jid, pod_id=pod_id, reason=reason)
            except Exception as e: log("pod.delete_failed", job=jid, pod_id=pod_id, reason=reason, error=repr(e))
        self.spawn(run)

    def finish_job(self, j, log_ev, **fields):
        """Terminal write + pod release + log, in that order (state first so a crash mid-way leaves the reaper a terminal job)."""
        self.db.set_job(j["id"], **fields)
        cur = self.db.job(j["id"])
        log(log_ev, job=j["id"], key_id=j["key_id"], **{k: v for k, v in fields.items() if k in ("state", "error", "billed_s", "exitcode")},
            cost_usd=round(job_cost(cur), 4), pod_id=cur["pod_id"])
        self.release_pod(j["id"], cur["pod_id"], fields.get("error") or fields.get("state"))
        return cur

    # -- watchdog: lost heartbeats -> pod_lost; launching too long -> no_capacity (neither is billed)
    def watchdog_once(self):
        cutoff = time.time() - HEARTBEAT_LOST_S
        for j in self.db.q("select * from jobs where state='running' and last_hb is not null and last_hb < ?", cutoff):
            self.finish_job(j, "job.pod_lost", state="failed", finished=now(), error="pod_lost", token_hash=None)
        lcut = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - self.cfg.launch_timeout_s))
        for j in self.db.q("select * from jobs where state='launching' and last_hb is null and launched_at is not null and launched_at < ?", lcut):
            self.finish_job(j, "job.launch_timeout", state="failed", finished=now(), error="no_capacity", token_hash=None)

    # -- reaper (CONTRACT "Pod lifecycle", GJOB-099): a pod exists only while a job is launching/running
    def reaper_once(self):
        if not self.launcher: return 0
        try: pods = self.launcher.list_pods()
        except Exception as e: log("reaper.list_failed", error=repr(e)); return 0
        self.last_reap = time.time(); n = 0
        for p in pods:
            pid = p.get("id"); name = p.get("name") or ""
            if not pid or not name.startswith(POD_PREFIX): continue
            j = self.db.job_by_pod(pid) or self.db.job(name[len(POD_PREFIX):])
            reason = None
            if not j: reason = "no_job"
            elif j["state"] in TERMINAL: reason = "job_terminal"
            else:
                age = pod_age_s(p); wall = int((json.loads(j["spec"]).get("wall_limit_s")) or 86400)
                if age is not None and age > wall + REAPER_GRACE_S: reason = "overage"
            if not reason: self.reaper_fail.pop(pid, None); continue
            try:
                self.launcher.delete(pid); self.reaper_fail.pop(pid, None); n += 1
                log("reaper.deleted", pod_id=pid, name=name, job=j["id"] if j else None, reason=reason, status=p.get("status"))
            except Exception as e:
                k = self.reaper_fail[pid] = self.reaper_fail.get(pid, 0) + 1
                log("reaper.delete_failed", pod_id=pid, name=name, reason=reason, failures=k, error=repr(e))
                if k >= 3: log("reaper.stuck", pod_id=pid, name=name, reason=reason, failures=k)
        return n

    def watchdog_loop(self, stop):
        while not stop.wait(30):
            try: self.watchdog_once(); self.purge_pending()
            except Exception as e: log("watchdog.error", error=repr(e))
            if self.launcher and time.time() - self.last_reap >= self.cfg.reaper_interval_s:
                try: self.reaper_once()
                except Exception as e: log("reaper.error", error=repr(e))

# ----------------------------------------------------------------------------- HTTP

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{brand}</title><style>
:root{{color-scheme:dark}}body{{margin:0;background:#0b0d10;color:#e6e8eb;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}}
main{{max-width:640px;margin:8vh auto;padding:0 20px}}h1{{font-size:22px;font-weight:600;margin:0 0 4px}}.brand{{color:#8b949e;font-size:13px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:28px}}
.card{{background:#12161b;border:1px solid #232a33;border-radius:10px;padding:20px 22px;margin:18px 0}}code,pre{{font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}}
pre{{background:#0b0d10;border:1px solid #232a33;border-radius:8px;padding:12px 14px;overflow-x:auto;margin:10px 0;user-select:all}}
.warn{{color:#f2c55c}}.muted{{color:#8b949e}}.big{{font-size:28px;font-weight:600}}ol{{padding-left:22px}}li{{margin:6px 0}}a{{color:#7cb7ff}}
</style></head><body><main><div class="brand">{brand}</div>{body}</main></body></html>"""

def page(brand, body): return PAGE.format(brand=brand, body=body).encode()
def esc(s): return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

class Handler(BaseHTTPRequestHandler):
    app: App
    server_version = "mde-endpoint/" + VERSION; sys_version = ""
    def log_message(self, *a): pass
    def send(self, code, obj=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
    def html(self, code, body): return self.send(code, raw=page(self.app.cfg.brand, body), ctype="text/html; charset=utf-8")
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return self.rfile.read(n) if n else b""
    def bearer(self):
        a = self.headers.get("Authorization", ""); return a[7:].strip() if a.startswith("Bearer ") else None
    def api_key(self):
        b = self.bearer()
        if not b or not b.startswith("mde_"): return None
        return self.app.db.key_by_hash(sha256(b))
    def pod_job(self, jid):
        j = self.app.db.job(jid); b = self.bearer()
        if not j or not b or not j["token_hash"] or not hmac.compare_digest(j["token_hash"], sha256(b)): return None
        return j
    def json_body(self):
        try: return json.loads(self.body() or b"{}")
        except json.JSONDecodeError: return None

    # ------------------------------------------------------------------ GET
    def do_GET(self):
        u = urlparse(self.path); p = u.path.rstrip("/") or "/"; parts = p.split("/")
        db = self.app.db
        if p == "/v1/health":
            return self.send(200, {"ok": True, "version": VERSION, "runners": "open" if self.app.cfg.runners_open else "closed",
                                   "launcher": self.app.launcher.kind if self.app.launcher else "none"})
        if p == "/welcome": return self.welcome(parse_qs(u.query))
        if parts[1] == "blob" and len(parts) == 3:
            name = parts[2]
            if not self.app.blob_ok(name, u.query): return self.send(403, {"error": "bad or expired blob url"})
            f = self.app.blob_path(name)
            if not os.path.exists(f): return self.send(404, {"error": "no blob"})
            self.send_response(200); self.send_header("Content-Type", "application/gzip"); self.send_header("Content-Length", str(os.path.getsize(f))); self.end_headers()
            with open(f, "rb") as fh:
                while chunk := fh.read(1 << 20): self.wfile.write(chunk)
            return
        if parts[1] == "internal":                                   # pod side
            j = self.pod_job(parts[3]) if len(parts) == 4 and parts[2] == "jobs" else None
            if not j: return self.send(401, {"error": "bad token"})
            spec = json.loads(j["spec"])
            in_url, _ = self.app.blob_url(f"{j['id']}.in.tar.gz"); out_url, _ = self.app.blob_url(f"{j['id']}.out.tar.gz")
            return self.send(200, {"input_url": in_url, "input": spec["input"], "launch": spec.get("launch", "default"),
                                   "wall_limit_s": spec.get("wall_limit_s", 86400), "results_put_url": out_url})
        if parts[1] == "v1" and len(parts) > 2 and parts[2] == "admin": return self.admin(parts[3:])
        k = self.api_key()
        if not k: return self.send(401, {"error": "bad api key"})
        if p == "/v1/me":
            return self.send(200, {"balance_usd": db.balance(k["key_id"]), "rate_table": self.app.cfg.rates, "keys_created": k["created"], "key_id": k["key_id"]})
        if p == "/v1/jobs":
            q = parse_qs(u.query); limit = max(1, min(int((q.get("limit") or ["50"])[0] or 50), 200)); cursor = (q.get("cursor") or [None])[0]
            if cursor and (cj := db.job(cursor)) and cj["key_id"] == k["key_id"]:
                rows = db.q("select * from jobs where key_id=? and (created<? or (created=? and id<?)) order by created desc, id desc limit ?", k["key_id"], cj["created"], cj["created"], cj["id"], limit)
            else:
                rows = db.q("select * from jobs where key_id=? order by created desc, id desc limit ?", k["key_id"], limit)
            return self.send(200, {"jobs": [status(j) for j in rows], "next_cursor": rows[-1]["id"] if len(rows) == limit else None})
        if len(parts) >= 4 and parts[1] == "v1" and parts[2] == "jobs":
            j = db.job(parts[3])
            if not j or j["key_id"] != k["key_id"]: return self.send(404, {"error": "no job"})
            if len(parts) == 4: return self.send(200, status(j))
            if parts[4] == "results":
                if j["state"] not in ("done", "failed"): return self.send(409, {"error": "not finished"})
                f = self.app.blob_path(f"{j['id']}.out.tar.gz"); sz = os.path.getsize(f) if os.path.exists(f) else 0
                url, exp = self.app.blob_url(f"{j['id']}.out.tar.gz")
                return self.send(200, {"download_url": url, "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp)), "bytes": sz})
        self.send(404, {"error": "no route"})

    def admin(self, parts):
        tok = self.app.cfg.admin_token
        if not tok or not self.bearer() or not hmac.compare_digest(tok, self.bearer()): return self.send(403, {"error": "forbidden"})
        db = self.app.db
        if parts == ["stats"]:
            by_state = {r["state"]: r["n"] for r in db.q("select state, count(*) n from jobs group by state")}
            return self.send(200, {"keys": db.one("select count(*) n from keys")["n"], "credits_usd": db.one("select coalesce(sum(usd),0) s from credits")["s"],
                                   "credit_rows": db.one("select count(*) n from credits")["n"], "jobs": by_state, "pending_keys": db.one("select count(*) n from pending_keys")["n"]})
        return self.send(404, {"error": "no route"})

    def welcome(self, q):
        sid = (q.get("session_id") or [""])[0].strip()
        if not sid or len(sid) > 200: return self.html(400, "<h1>Missing session</h1><p class=muted>This page is reached from the payment confirmation link.</p>")
        if not self.app.cfg.stripe_secret: log("welcome.no_stripe_key", session=sid); return self.html(503, "<h1>Not configured</h1><p class=muted>Payment lookup is unavailable right now. Your payment is safe; try again shortly.</p>")
        try:
            sess = stripe_fetch_session(sid, self.app.cfg.stripe_secret)
        except urllib.error.HTTPError as e:
            log("welcome.stripe_http", session=sid, code=e.code); return self.html(404 if e.code == 404 else 502, "<h1>Session not found</h1><p class=muted>We could not find that payment session. If you were charged, reply to your Stripe receipt.</p>")
        except Exception as e:
            log("welcome.stripe_error", session=sid, error=repr(e)); return self.html(502, "<h1>Temporary problem</h1><p class=muted>Could not reach the payment provider. Reload in a minute; your payment is safe.</p>")
        if sess.get("payment_status") != "paid":
            return self.html(402, "<h1>Payment not completed</h1><p class=muted>Stripe reports this session as <code>%s</code>. Once it is paid, reload this page.</p>" % esc(sess.get("payment_status")))
        try: g = self.app.grant(sess, "welcome")
        except Exception as e:
            log("welcome.grant_error", session=sid, error=repr(e)); return self.html(500, "<h1>Something went wrong</h1><p class=muted>Your payment is recorded; reply to your Stripe receipt and we will fix it.</p>")
        bal = "$%.2f" % g["balance"]; hours = ("%.4g" % g["gpu_h"])
        if g["full_key"]:
            body = f"""<h1>Your MDEngine key</h1><p>Credited <b>{hours} GPU-hours</b> (${g['usd']:.2f}). Balance <span class=big>{bal}</span></p>
<div class=card><p class=warn><b>Shown once.</b> Copy it now; it is stored hashed and cannot be displayed again.</p><pre>{esc(g['full_key'])}</pre>
<p>Key id <code>{esc(g['key_id'])}</code> (this short id is what appears in support and top-ups).</p></div>
<div class=card><p><b>Command line</b></p><pre>mdengine login {esc(g['full_key'])}
mdengine run --gpu in.lmp</pre>
<p><b>App</b></p><ol><li>MDEngine ▸ Settings ▸ Accelerated (API key)</li><li>Paste the key</li><li>File ▸ Run Accelerated… (⇧⌘R)</li></ol>
<p><b>MCP</b>: <code>submit_lammps host=cloud</code> once the key is saved by <code>mdengine login</code>.</p></div>
<p class=muted>Credits never expire. Check the balance any time with <code>mdengine account</code>.</p>"""
            return self.html(200, body)
        if g["kind"] == "topup":
            return self.html(200, f"""<h1>Credits added</h1><p>Credited <b>{hours} GPU-hours</b> (${g['usd']:.2f}) to your existing key <code>{esc(g['key_id'])}</code>.</p>
<div class=card><p>New balance <span class=big>{bal}</span></p><p class=muted><code>mdengine account</code> shows the same figure.</p></div>""")
        return self.html(200, f"""<h1>Already issued</h1><p>This purchase was already credited to key <code>{esc(g['key_id'])}</code>; balance <span class=big>{bal}</span>.</p>
<div class=card><p class=muted>The full key is shown only once, right after payment. If you did not save it, <code>mdengine account</code> works if you already logged in; otherwise reply to your Stripe receipt and quote the key id above and we will issue a replacement.</p></div>""")

    # ------------------------------------------------------------------ PUT (blob upload)
    def do_PUT(self):
        u = urlparse(self.path); parts = u.path.split("/")
        if len(parts) != 3 or parts[1] != "blob": return self.send(404, {"error": "no route"})
        name = parts[2]
        if not self.app.blob_ok(name, u.query): return self.send(403, {"error": "bad or expired blob url"})
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BLOB: return self.send(413, {"error": "tarball exceeds 2 GB"})
        jid = name.split(".")[0]; j = self.app.db.job(jid)
        if not j: return self.send(404, {"error": "no job"})
        if name.endswith(".in.tar.gz") and j["state"] != "created": return self.send(409, {"error": f"state is {j['state']}"})
        tmp = self.app.blob_path(name + ".part"); left = n
        with open(tmp, "wb") as fh:
            while left > 0:
                chunk = self.rfile.read(min(left, 1 << 20))
                if not chunk: break
                fh.write(chunk); left -= len(chunk)
        if left: os.remove(tmp); return self.send(400, {"error": "short body"})
        os.replace(tmp, self.app.blob_path(name))
        if name.endswith(".in.tar.gz"): self.app.db.set_job(jid, state="uploaded")
        log("blob.put", job=jid, name=name, bytes=n)
        self.send(200, {"ok": True})

    # ------------------------------------------------------------------ POST
    def do_POST(self):
        p = urlparse(self.path).path.rstrip("/"); parts = p.split("/"); db = self.app.db
        if p == "/v1/stripe/webhook": return self.webhook()
        if parts[1] == "internal":                                   # pod side: heartbeat / done
            j = self.pod_job(parts[3]) if len(parts) == 5 and parts[2] == "jobs" else None
            if not j: return self.send(401, {"error": "bad token"})
            b = self.json_body()
            if b is None: return self.send(400, {"error": "bad json"})
            if parts[4] == "heartbeat":
                kw = {"thermo": json.dumps([str(x) for x in (b.get("thermo_tail") or [])][-20:]), "last_hb": time.time()}
                if j["state"] in ("queued", "launching"): kw.update(state="running", started=now()); log("job.running", job=j["id"])
                db.set_job(j["id"], **kw); return self.send(200, {"ok": True})
            if parts[4] == "done":
                if j["state"] in TERMINAL: return self.send(200, {"ok": True, "state": j["state"]})
                rc = int(b.get("exitcode", 1)); err = b.get("error")
                started = j["started"] or now(); billed = int(b.get("elapsed_s", 0))
                if j["started"]: billed = min(billed, int(time.time() - parse_ts(j["started"])) + 60)   # pod cannot bill more than wall time
                have = os.path.exists(self.app.blob_path(f"{j['id']}.out.tar.gz"))
                state = "done" if rc == 0 and have else "failed"
                if not have and not err: err = "no_results"
                self.app.finish_job(j, "job.finished", state=state, finished=now(), started=started, exitcode=rc, error=err, billed_s=billed, token_hash=None)
                return self.send(200, {"ok": True, "state": state})
            return self.send(404, {"error": "no route"})
        k = self.api_key()
        if not k: return self.send(401, {"error": "bad api key"})
        if p == "/v1/jobs":
            spec = self.json_body()
            if spec is None or "input" not in spec: return self.send(400, {"error": "input required"})
            gpu = spec.get("gpu", "any"); rate = self.app.cfg.rates.get(gpu)
            if rate is None: return self.send(400, {"error": "unknown gpu"})
            try: est = int(spec.get("estimate_s", 0)); wall = int(spec.get("wall_limit_s", 14400))
            except (TypeError, ValueError): return self.send(400, {"error": "bad numbers"})
            if wall > 86400 or wall <= 0: return self.send(400, {"error": "wall_limit_s must be 1..86400"})
            if len(str(spec.get("label") or "")) > 120: return self.send(400, {"error": "label too long"})
            if db.balance(k["key_id"]) < rate * max(est, 900) / 3600: return self.send(402, {"error": "insufficient balance"})
            if not self.app.cfg.runners_open:
                log("job.refused_closed", key_id=k["key_id"])
                return self.send(503, {"error": "gpu_runners_open_soon", "message": "GPU runners open this week; your credits are safe and never expire."})
            jid = job_id()
            spec["wall_limit_s"] = wall
            db.x("insert into jobs(id,key_id,spec,state,created,gpu,rate) values(?,?,?,?,?,?,?)",
                 jid, k["key_id"], json.dumps(spec), "created", now(), gpu, rate)
            url, exp = self.app.blob_url(f"{jid}.in.tar.gz", ttl=3600)
            log("job.created", job=jid, key_id=k["key_id"], gpu=gpu)
            return self.send(201, {"id": jid, "upload_url": url, "upload_expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp))})
        if len(parts) == 5 and parts[1] == "v1" and parts[2] == "jobs" and parts[4] == "start":
            j = db.job(parts[3])
            if not j or j["key_id"] != k["key_id"]: return self.send(404, {"error": "no job"})
            if j["state"] != "uploaded": return self.send(409, {"error": f"state is {j['state']}"})
            tok = "jt_" + secrets.token_hex(16)                      # minted here, stored hashed, handed to the pod only
            db.set_job(j["id"], state="queued", token_hash=sha256(tok))
            spec = json.loads(j["spec"]); wall = int(spec.get("wall_limit_s") or 86400)
            if self.app.launcher:                                    # background: queued -> launching | failed:no_capacity
                self.app.spawn(self.app.launch_job, j["id"], tok, wall, j["gpu"])
            else:                                                    # dev path: launch env on disk for a hand-run pod
                with open(self.app.launch_env, "w", opener=lambda f, fl: os.open(f, fl, 0o600)) as fh:
                    fh.write(f"MDE_ENDPOINT={self.app.public_url}\nMDE_JOB_ID={j['id']}\nMDE_JOB_TOKEN={tok}\n")
            log("job.queued", job=j["id"], key_id=k["key_id"], launcher=bool(self.app.launcher))
            return self.send(202, {"id": j["id"], "state": "queued"})
        self.send(404, {"error": "no route"})

    def webhook(self):
        payload = self.body(); cfg = self.app.cfg
        if not verify_stripe_signature(payload, self.headers.get("Stripe-Signature", ""), cfg.webhook_secret):
            log("webhook.bad_signature"); return self.send(400, {"error": "bad signature"})
        try: event = json.loads(payload)
        except json.JSONDecodeError: return self.send(400, {"error": "bad json"})
        etype = event.get("type"); obj = (event.get("data") or {}).get("object") or {}
        if etype != "checkout.session.completed": return self.send(200, {"ok": True, "ignored": etype})
        sid = obj.get("id")
        if not sid: return self.send(400, {"error": "no session id"})
        sess = obj
        if cfg.stripe_secret:                     # webhook payloads carry no line_items; fetch to learn the price id
            try: sess = stripe_fetch_session(sid, cfg.stripe_secret)
            except Exception as e: log("webhook.stripe_fetch_failed", session=sid, error=repr(e))
        if sess.get("payment_status") != "paid": return self.send(200, {"ok": True, "ignored": "unpaid"})
        try: g = self.app.grant(sess, "webhook")
        except Exception as e:
            log("webhook.grant_error", session=sid, error=repr(e)); return self.send(500, {"error": "grant failed"})
        return self.send(200, {"ok": True, "result": g["kind"], "key_id": g["key_id"]})

    # ------------------------------------------------------------------ DELETE (cancel)
    def do_DELETE(self):
        parts = urlparse(self.path).path.rstrip("/").split("/"); db = self.app.db
        k = self.api_key()
        if not k: return self.send(401, {"error": "bad api key"})
        if len(parts) != 4 or parts[1] != "v1" or parts[2] != "jobs": return self.send(404, {"error": "no route"})
        j = db.job(parts[3])
        if not j or j["key_id"] != k["key_id"]: return self.send(404, {"error": "no job"})
        if j["state"] in TERMINAL: return self.send(409, {"error": "terminal"})
        billed = billed_seconds(j) if j["state"] == "running" else 0
        cur = self.app.finish_job(j, "job.cancelled", state="cancelled", finished=now(), error="cancelled", billed_s=billed, token_hash=None)
        self.send(202, status(cur))

# ----------------------------------------------------------------------------- server

def make_server(cfg: Config):
    """Bind and return (server, app). Port 0 in MDE_BIND picks a free port (tests)."""
    app = App(cfg)
    handler = type("BoundHandler", (Handler,), {"app": app})
    host, _, port = cfg.bind.rpartition(":")
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port or 8080)), handler)
    srv.daemon_threads = True
    if not cfg.public_url: app.public_url = "http://%s:%d" % srv.server_address[:2]
    if app.launcher: app.launcher.public_url = app.public_url
    return srv, app

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--env-file", default=os.environ.get("MDE_ENV_FILE"), help="KEY=VALUE file; existing env wins")
    a = ap.parse_args(argv); load_env_file(a.env_file)
    cfg = Config(); srv, app = make_server(cfg)
    log("start", version=VERSION, bind=cfg.bind, public_url=app.public_url, runners="open" if cfg.runners_open else "closed",
        packs=len(cfg.packs), stripe=bool(cfg.stripe_secret), webhook=bool(cfg.webhook_secret), db=cfg.db,
        launcher=app.launcher.kind if app.launcher else "none", ladder=cfg.gpu_ladder if app.launcher else None)
    if app.launcher:                                  # boot-time reap: an endpoint outage must not leave orphans behind it
        try: log("reaper.boot", deleted=app.reaper_once())
        except Exception as e: log("reaper.error", error=repr(e))
    stop = threading.Event(); threading.Thread(target=app.watchdog_loop, args=(stop,), daemon=True).start()
    try: srv.serve_forever()
    except KeyboardInterrupt: pass
    finally: stop.set(); srv.server_close(); log("stop")

if __name__ == "__main__":
    main()
