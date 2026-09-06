#!/usr/bin/env python3
"""Tests for mde_endpoint.py / mde_admin.py. Stdlib unittest; starts the server on a random port with a
temp db and a fake Stripe (stripe_fetch_session monkeypatched). No network beyond 127.0.0.1.

  python3 hosted/endpoint/test_endpoint.py -v
"""
import io, json, os, re, shutil, sys, tempfile, threading, time, unittest, urllib.error, urllib.request
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mde_endpoint as E
import mde_admin as A
import mde_launcher as L

PRICE_STARTER, PRICE_LAB = "price_test_starter", "price_test_lab"
WEBHOOK_SECRET = "whsec_test_" + "a" * 20

FAKE_SESSIONS = {}

def fake_session(sid, price=PRICE_STARTER, paid=True, amount=2500, ref=None, email="buyer@example.test"):
    s = {"id": sid, "object": "checkout.session", "payment_status": "paid" if paid else "unpaid", "amount_total": amount,
         "client_reference_id": ref, "customer_details": {"email": email},
         "line_items": {"data": [{"price": {"id": price}}]}}
    FAKE_SESSIONS[sid] = s; return s

def fake_fetch(sid, secret):
    if sid not in FAKE_SESSIONS: raise urllib.error.HTTPError("https://api.stripe.com", 404, "no such session", {}, None)
    return FAKE_SESSIONS[sid]

def lines(out):
    """Human lines of a CLI run (its JSON log lines go to the same stdout)."""
    return [l for l in out.splitlines() if l.strip() and not l.startswith("{")]

class Server:
    def __init__(self, runners_open=False, launcher=None):
        self.dir = tempfile.mkdtemp(prefix="mde-test-")
        env = {"MDE_DB": os.path.join(self.dir, "t.sqlite"), "MDE_BLOBS": os.path.join(self.dir, "blobs"), "MDE_BIND": "127.0.0.1:0",
               "STRIPE_SECRET_KEY": "sk_test_fake", "STRIPE_WEBHOOK_SECRET": WEBHOOK_SECRET,
               "MDE_PACKS": f"{PRICE_STARTER}:25:12.5,{PRICE_LAB}:100:50", "MDE_RUNNERS_OPEN": "1" if runners_open else "",
               "MDE_ADMIN_TOKEN": "admintok",
               "MDE_RUNNER_IMAGES": "openmm:ghcr.io/example/openmm:latest"}
        self.cfg = E.Config(env); self.srv, self.app = E.make_server(self.cfg)
        self.base = self.app.public_url
        if launcher is not None: launcher.public_url = self.base; self.app.launcher = launcher
        self.t = threading.Thread(target=self.srv.serve_forever, daemon=True); self.t.start()
    def close(self):
        self.srv.shutdown(); self.srv.server_close(); self.app.db.c.close(); shutil.rmtree(self.dir, ignore_errors=True)

    def req(self, method, path, body=None, key=None, headers=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        url = path if path.startswith("http") else self.base + path
        r = urllib.request.Request(url, data=data, method=method)
        if key: r.add_header("Authorization", "Bearer " + key)
        if body is not None: r.add_header("Content-Type", "application/json")
        for k, v in (headers or {}).items(): r.add_header(k, v)
        try:
            with urllib.request.urlopen(r, timeout=10) as resp: return resp.status, resp.read(), resp.headers
        except urllib.error.HTTPError as e:
            with e: return e.code, e.read(), e.headers

    def js(self, *a, **kw):
        code, body, _ = self.req(*a, **kw); return code, json.loads(body)

    def admin_key(self, credit, email="op@example.test"):
        """Create a key via the admin CLI against the same sqlite file; returns (full_key, key_id)."""
        out = io.StringIO()
        with redirect_stdout(out): A.main(["--db", self.cfg.db, "--env-file", "/nonexistent", "key", "new", "--email", email, "--credit", str(credit)])
        full = re.search(r"\b(mde_[0-9a-f]{32})\b", out.getvalue()).group(1)
        kid = re.search(r"key_id\s+(\w+)", out.getvalue()).group(1)
        return full, kid

class Base(unittest.TestCase):
    runners_open = False
    fake_launcher = False
    def setUp(self):
        self._orig = E.stripe_fetch_session; E.stripe_fetch_session = fake_fetch; FAKE_SESSIONS.clear()
        self.fake = L.FakeLauncher() if self.fake_launcher else None
        self.s = Server(self.runners_open, launcher=self.fake); self._log = io.StringIO(); self._logpatch = redirect_stdout(self._log); self._logpatch.__enter__()
    def tearDown(self):
        self._logpatch.__exit__(None, None, None); self.s.close(); E.stripe_fetch_session = self._orig

class TestAuthAndBalance(Base):
    def test_health(self):
        code, j = self.s.js("GET", "/v1/health")
        self.assertEqual(code, 200); self.assertTrue(j["ok"]); self.assertEqual(j["runners"], "closed"); self.assertEqual(j["version"], E.VERSION)

    def test_me_and_key_hashing(self):
        full, kid = self.s.admin_key(20)
        code, j = self.s.js("GET", "/v1/me", key=full)
        self.assertEqual(code, 200); self.assertEqual(j["balance_usd"], 20.0); self.assertEqual(j["key_id"], kid)
        self.assertIn("rate_table", j); self.assertIn("keys_created", j)
        # Only the hash is at rest.
        row = self.s.app.db.one("select * from keys where key_id=?", kid)
        self.assertEqual(row["key_hash"], E.sha256(full)); self.assertNotIn(full, json.dumps(dict(row)))
        self.assertEqual(kid, E.sha256(full)[:8])
        # Bad / missing keys.
        self.assertEqual(self.s.js("GET", "/v1/me", key="mde_" + "0" * 32)[0], 401)
        self.assertEqual(self.s.js("GET", "/v1/me")[0], 401)
        # Log output never contains the full key.
        self.assertNotIn(full, self._log.getvalue())

    def test_submit_closed_503_after_auth_and_balance(self):
        full, _ = self.s.admin_key(20)
        spec = {"input": "in.lmp", "gpu": "any", "estimate_s": 3600, "wall_limit_s": 7200}
        code, j = self.s.js("POST", "/v1/jobs", body=spec, key=full)
        self.assertEqual(code, 503); self.assertEqual(j["error"], "gpu_runners_open_soon"); self.assertIn("never expire", j["message"])
        # Auth failure wins over the flag, and so does an insufficient balance.
        self.assertEqual(self.s.js("POST", "/v1/jobs", body=spec, key="mde_" + "f" * 32)[0], 401)
        poor, _ = self.s.admin_key(0.10)
        self.assertEqual(self.s.js("POST", "/v1/jobs", body=spec, key=poor)[0], 402)
        self.assertEqual(self.s.js("GET", "/v1/jobs", key=full)[1], {"jobs": [], "next_cursor": None})

class TestPurchase(Base):
    def welcome(self, sid):
        code, body, _ = self.s.req("GET", "/welcome?session_id=" + sid); return code, body.decode()

    def test_first_purchase_creates_key(self):
        fake_session("cs_test_1")
        code, html = self.welcome("cs_test_1")
        self.assertEqual(code, 200); self.assertIn("ForceField Silicon / MDEngine", html); self.assertIn("Shown once", html)
        full = re.search(r"mdengine login (mde_[0-9a-f]{32})", html).group(1)
        code, j = self.s.js("GET", "/v1/me", key=full)
        self.assertEqual(code, 200); self.assertEqual(j["balance_usd"], 25.0)     # 12.5 h * $2
        c = self.s.app.db.one("select * from credits where session_id='cs_test_1'")
        self.assertEqual(c["gpu_s"], 45000); self.assertEqual(c["price_id"], PRICE_STARTER); self.assertEqual(c["key_id"], j["key_id"])
        self.assertEqual(self.s.app.db.key_by_id(j["key_id"])["email"], "buyer@example.test")
        self.assertNotIn(full, self._log.getvalue())
        # Revisit: idempotent, no key shown.
        code, html2 = self.welcome("cs_test_1")
        self.assertEqual(code, 200); self.assertIn("Already issued", html2); self.assertNotIn(full, html2); self.assertIn(j["key_id"], html2)
        self.assertEqual(self.s.app.db.one("select count(*) n from credits")["n"], 1)
        self.assertEqual(self.s.app.db.one("select count(*) n from keys")["n"], 1)
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 25.0)

    def test_coupon_discount_still_grants_full_hours(self):
        fake_session("cs_coupon", price=PRICE_LAB, amount=1)   # paid $0.01 with a coupon
        code, html = self.welcome("cs_coupon")
        full = re.search(r"mdengine login (mde_[0-9a-f]{32})", html).group(1)
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 100.0)     # 50 h * $2

    def test_topup_existing_key_by_client_reference_id(self):
        full, kid = self.s.admin_key(5)
        fake_session("cs_topup", ref=kid)
        code, html = self.welcome("cs_topup")
        self.assertEqual(code, 200); self.assertIn("existing key", html); self.assertIn(kid, html); self.assertIn("$30.00", html)
        self.assertNotRegex(html, r"mde_[0-9a-f]{32}")
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 30.0)
        self.assertEqual(self.s.app.db.one("select count(*) n from keys")["n"], 1)

    def test_unknown_reference_id_creates_new_key(self):
        fake_session("cs_badref", ref="deadbeef")
        code, html = self.welcome("cs_badref")
        self.assertEqual(code, 200); self.assertRegex(html, r"mde_[0-9a-f]{32}")

    def test_unpaid_and_missing_sessions(self):
        fake_session("cs_unpaid", paid=False)
        self.assertEqual(self.welcome("cs_unpaid")[0], 402)
        self.assertEqual(self.welcome("cs_nope")[0], 404)
        self.assertEqual(self.s.req("GET", "/welcome")[0], 400)
        self.assertEqual(self.s.app.db.one("select count(*) n from credits")["n"], 0)

class TestWebhook(Base):
    def event(self, sid, etype="checkout.session.completed"):
        return json.dumps({"id": "evt_1", "type": etype, "data": {"object": {"id": sid, "object": "checkout.session", "payment_status": "paid"}}}).encode()

    def post(self, payload, sig):
        return self.s.js("POST", "/v1/stripe/webhook", raw=payload, headers={"Stripe-Signature": sig, "Content-Type": "application/json"})

    def test_signature_reject(self):
        fake_session("cs_wh"); p = self.event("cs_wh")
        self.assertEqual(self.post(p, "")[0], 400)
        self.assertEqual(self.post(p, E.stripe_sign(p, "whsec_wrong"))[0], 400)
        self.assertEqual(self.post(p, E.stripe_sign(p, WEBHOOK_SECRET, ts=time.time() - 600))[0], 400)   # stale
        self.assertEqual(self.post(p + b" ", E.stripe_sign(p, WEBHOOK_SECRET))[0], 400)                 # tampered body
        self.assertEqual(self.s.app.db.one("select count(*) n from credits")["n"], 0)

    def test_accept_then_welcome_reveals_once(self):
        fake_session("cs_wh"); p = self.event("cs_wh")
        code, j = self.post(p, E.stripe_sign(p, WEBHOOK_SECRET))
        self.assertEqual(code, 200); self.assertEqual(j["result"], "new")
        # Duplicate delivery: 200, nothing double-credited.
        code, j2 = self.post(p, E.stripe_sign(p, WEBHOOK_SECRET))
        self.assertEqual(code, 200); self.assertEqual(j2["result"], "already"); self.assertEqual(j2["key_id"], j["key_id"])
        self.assertEqual(self.s.app.db.one("select count(*) n from credits")["n"], 1)
        # The buyer lands on /welcome after the webhook already ran: key shown exactly once.
        code, body, _ = self.s.req("GET", "/welcome?session_id=cs_wh"); html = body.decode()
        self.assertEqual(code, 200); full = re.search(r"mdengine login (mde_[0-9a-f]{32})", html).group(1)
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 25.0)
        self.assertEqual(self.s.app.db.one("select count(*) n from pending_keys")["n"], 0)
        code, body, _ = self.s.req("GET", "/welcome?session_id=cs_wh")
        self.assertIn("Already issued", body.decode()); self.assertNotIn(full, body.decode())

    def test_welcome_then_webhook_is_idempotent(self):
        fake_session("cs_both")
        code, body, _ = self.s.req("GET", "/welcome?session_id=cs_both")
        full = re.search(r"mdengine login (mde_[0-9a-f]{32})", body.decode()).group(1)
        p = self.event("cs_both"); code, j = self.post(p, E.stripe_sign(p, WEBHOOK_SECRET))
        self.assertEqual(code, 200); self.assertEqual(j["result"], "already")
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 25.0)
        self.assertEqual(self.s.app.db.one("select count(*) n from pending_keys")["n"], 0)

    def test_other_events_ignored(self):
        p = self.event("cs_x", etype="payment_intent.succeeded")
        code, j = self.post(p, E.stripe_sign(p, WEBHOOK_SECRET)); self.assertEqual(code, 200); self.assertEqual(j["ignored"], "payment_intent.succeeded")

class TestAdmin(Base):
    def run_admin(self, *args):
        out = io.StringIO()
        with redirect_stdout(out): A.main(["--db", self.s.cfg.db, "--env-file", "/nonexistent", *args])
        return out.getvalue()

    def test_key_new_and_credit_add(self):
        full, kid = self.s.admin_key(10, email="a@example.test")
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 10.0)
        out = self.run_admin("credit", "add", "--key", kid, "--usd", "15")
        self.assertIn("balance $25.00", out)
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 25.0)
        lst = self.run_admin("key", "list"); self.assertIn(kid, lst); self.assertIn("a@example.test", lst); self.assertNotIn(full, lst)
        led = self.run_admin("ledger"); self.assertEqual(led.count("admin-"), 2)
        st = self.run_admin("stats"); self.assertIn("keys           1", st); self.assertIn("credited usd   25.00", st)
        with self.assertRaises(SystemExit): self.run_admin("credit", "add", "--key", "nokey000", "--usd", "1")

    def test_admin_http_stats(self):
        self.assertEqual(self.s.js("GET", "/v1/admin/stats")[0], 403)
        code, j = self.s.js("GET", "/v1/admin/stats", key="admintok"); self.assertEqual(code, 200); self.assertEqual(j["keys"], 0)


    def test_statement_month(self):
        full, kid = self.s.admin_key(10, email="stmt@example.test")                     # admin credit, this month
        self.s.app.db.add_credit("cs_test_stmt", kid, 25.0, 45000, PRICE_STARTER)          # Stripe credit, this month
        ts = E.now(); month = ts[:7]
        # A billed job that finished this month, an unbilled pod_lost one, and one that finished last year (not listed).
        self.s.app.db.x("insert into jobs(id,key_id,spec,state,created,started,finished,gpu,rate,billed_s,exitcode) values(?,?,?,?,?,?,?,?,?,?,?)",
                        "MDJOB-20260901-STMT01", kid, json.dumps({"input": "in.lmp", "label": "Al slab"}), "done", ts, ts, ts, "rtx4090", 2.0, 900, 0)
        self.s.app.db.x("insert into jobs(id,key_id,spec,state,created,finished,gpu,rate,error) values(?,?,?,?,?,?,?,?,?)",
                        "MDJOB-20260901-STMT02", kid, json.dumps({"input": "in.lmp"}), "failed", ts, ts, "rtx4090", 2.0, "pod_lost")
        self.s.app.db.x("insert into jobs(id,key_id,spec,state,created,started,finished,gpu,rate,billed_s,exitcode) values(?,?,?,?,?,?,?,?,?,?,?)",
                        "MDJOB-20250101-OLD001", kid, json.dumps({"input": "in.lmp"}), "done", "2025-01-01T00:00:00Z", "2025-01-01T00:00:00Z", "2025-01-01T01:00:00Z", "rtx4090", 2.0, 3600, 0)
        quiet_full, quiet_kid = self.s.admin_key(0, email="quiet@example.test")           # no activity: no file
        out = os.path.join(self.s.dir, "stmts")
        res = self.run_admin("statement", "--month", month, "--out", out)
        path = os.path.join(out, kid + ".txt")
        self.assertEqual(lines(res), [path]); self.assertFalse(os.path.exists(os.path.join(out, quiet_kid + ".txt")))
        with open(path) as fh: txt = fh.read()
        self.assertIn(f"statement {month}", txt); self.assertIn(f"key id     {kid}", txt); self.assertIn("stmt@example.test", txt)
        self.assertIn("+$   25.00    12.50 GPU-h  Stripe session cs_test_stmt  (price_test_starter)", txt)
        self.assertIn("+$   10.00     5.00 GPU-h  manual credit admin-", txt)
        self.assertRegex(txt, r"MDJOB-20260901-STMT01\s+Al slab\s+done\s+-\s+rtx4090\s+900  \$0\.5000")
        self.assertRegex(txt, r"MDJOB-20260901-STMT02\s+-\s+failed\s+pod_lost\s+rtx4090\s+0  \$0\.0000")
        self.assertNotIn("MDJOB-20250101-OLD001", txt)
        self.assertIn("credits added        $35.00", txt); self.assertIn("jobs finished        2 (billed 1, unbilled 1)", txt)
        self.assertIn("GPU seconds billed   900", txt); self.assertIn("charges              $0.5000", txt)
        self.assertIn(f"Opening balance ({month}-01)   $-2.00", txt)                       # last year's $2 job precedes this month's credits
        self.assertRegex(txt, rf"Closing balance \({month}-\d\d\)   \$32\.50"); self.assertIn("Balance now                     $32.50", txt)
        self.assertNotIn(full, txt)
        # --key restricts; default --out lands next to the db; 'prev' is accepted; bad month exits.
        res = self.run_admin("statement", "--month", month, "--key", kid)
        default_path = os.path.join(os.path.dirname(self.s.cfg.db), "statements", month, kid + ".txt")
        self.assertEqual(lines(res), [default_path]); self.assertTrue(os.path.exists(default_path))
        self.assertIn("no activity", self.run_admin("statement", "--month", "2001-01", "--out", out))
        self.assertIn("no activity", self.run_admin("statement", "--month", "prev", "--out", out))
        with self.assertRaises(SystemExit): self.run_admin("statement", "--month", "2026-13", "--out", out)
        with self.assertRaises(SystemExit): self.run_admin("statement", "--month", month, "--key", "nokey000", "--out", out)

    def test_month_bounds(self):
        self.assertEqual(A.month_bounds("2026-12"), ("2026-12", "2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z"))
        self.assertEqual(A.month_bounds("2026-02")[1:], ("2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z"))
        y, m = time.gmtime()[:2]; py, pm = (y - 1, 12) if m == 1 else (y, m - 1)
        self.assertEqual(A.month_bounds("prev")[0], "%04d-%02d" % (py, pm))

class TestJobFlowWhenOpen(Base):
    """The mock's job logic, behind the flag, end to end with a stand-in pod."""
    runners_open = True
    def launch_token(self):
        with open(self.s.app.launch_env) as fh: return dict(l.split("=", 1) for l in fh.read().splitlines())["MDE_JOB_TOKEN"]

    def test_submit_upload_start_pod_done_billed(self):
        full, kid = self.s.admin_key(20)
        self.assertEqual(self.s.js("GET", "/v1/health")[1]["runners"], "open")
        code, j = self.s.js("POST", "/v1/jobs", body={"input": "in.lmp", "gpu": "rtx4090", "estimate_s": 600, "label": "t"}, key=full)
        self.assertEqual(code, 201); jid = j["id"]; self.assertRegex(jid, r"^MDJOB-\d{8}-[A-Z0-9]{6}$")
        up = j["upload_url"]; self.assertIn("sig=", up)
        # Unsigned PUT refused; signed PUT accepted; state -> uploaded.
        self.assertEqual(self.s.req("PUT", up.split("?")[0], raw=b"x")[0], 403)
        self.assertEqual(self.s.req("PUT", up, raw=b"deck-tarball")[0], 200)
        self.assertEqual(self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]["state"], "uploaded")
        code, j = self.s.js("POST", f"/v1/jobs/{jid}/start", key=full); self.assertEqual(code, 202); self.assertEqual(j["state"], "queued")
        tok = self.launch_token(); self.assertTrue(tok.startswith("jt_"))
        self.assertEqual(self.s.app.db.job(jid)["token_hash"], E.sha256(tok))
        # Pod side.
        self.assertEqual(self.s.js("GET", f"/internal/jobs/{jid}", key="jt_" + "0" * 32)[0], 401)
        code, spec = self.s.js("GET", f"/internal/jobs/{jid}", key=tok)
        self.assertEqual(code, 200); self.assertEqual(spec["input"], "in.lmp"); self.assertEqual(spec["launch"], "default")
        self.assertEqual(self.s.req("GET", spec["input_url"])[1], b"deck-tarball")
        self.assertEqual(self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": ["Step Temp", "1 300"], "elapsed_s": 1}, key=tok)[0], 200)
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]; self.assertEqual(st["state"], "running"); self.assertEqual(st["thermo_tail"], ["Step Temp", "1 300"])
        self.assertEqual(self.s.req("PUT", spec["results_put_url"], raw=b"results-tarball")[0], 200)
        code, j = self.s.js("POST", f"/internal/jobs/{jid}/done", body={"exitcode": 0, "elapsed_s": 36, "results_bytes": 15}, key=tok)
        self.assertEqual(code, 200); self.assertEqual(j["state"], "done")
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual(st["state"], "done"); self.assertEqual(st["billed_s"], 36); self.assertEqual(st["cost_usd"], 0.02); self.assertEqual(st["exitcode"], 0)
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 19.98)
        # Token invalidated after terminal state; results fetchable.
        self.assertEqual(self.s.js("GET", f"/internal/jobs/{jid}", key=tok)[0], 401)
        code, r = self.s.js("GET", f"/v1/jobs/{jid}/results", key=full); self.assertEqual(code, 200); self.assertEqual(r["bytes"], 15)
        self.assertEqual(self.s.req("GET", r["download_url"])[1], b"results-tarball")
        lst = self.s.js("GET", "/v1/jobs", key=full)[1]; self.assertEqual([x["id"] for x in lst["jobs"]], [jid])
        self.assertEqual(self.s.js("DELETE", f"/v1/jobs/{jid}", key=full)[0], 409)
        # Ledger from the CLI agrees.
        out = io.StringIO()
        with redirect_stdout(out): A.main(["--db", self.s.cfg.db, "--env-file", "/nonexistent", "ledger", "--key", kid])
        self.assertIn(jid, out.getvalue()); self.assertIn("-$  0.0200", out.getvalue())

    def test_pod_lost_not_billed_and_cancel(self):
        full, kid = self.s.admin_key(20)
        jid = self.s.js("POST", "/v1/jobs", body={"input": "in.lmp"}, key=full)[1]["id"]
        up = self.s.app.blob_url(f"{jid}.in.tar.gz")[0]; self.s.req("PUT", up, raw=b"x"); self.s.js("POST", f"/v1/jobs/{jid}/start", key=full)
        tok = self.launch_token()
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": [], "elapsed_s": 0}, key=tok)
        self.s.app.db.set_job(jid, last_hb=time.time() - 1000, started="2020-01-01T00:00:00Z")
        self.s.app.watchdog_once()
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["cost_usd"]), ("failed", "pod_lost", 0.0))
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)
        # Cancel a fresh job.
        j2 = self.s.js("POST", "/v1/jobs", body={"input": "in.lmp"}, key=full)[1]["id"]
        code, st = self.s.js("DELETE", f"/v1/jobs/{j2}", key=full); self.assertEqual(code, 202); self.assertEqual(st["state"], "cancelled")

class TestLauncherFlow(Base):
    """Job lifecycle with a FakeLauncher injected: pods are created at start and gone at every terminal state."""
    runners_open = True; fake_launcher = True

    def started_job(self, credit=20):
        full, kid = self.s.admin_key(credit)
        jid = self.s.js("POST", "/v1/jobs", body={"input": "in.lmp", "gpu": "rtx4090", "wall_limit_s": 3600}, key=full)[1]["id"]
        self.s.req("PUT", self.s.app.blob_url(f"{jid}.in.tar.gz")[0], raw=b"deck")
        code, j = self.s.js("POST", f"/v1/jobs/{jid}/start", key=full); self.assertEqual((code, j["state"]), (202, "queued"))
        self.assertTrue(self.s.app.join_bg()); return full, jid

    def pod_token(self, jid):
        pod = self.s.app.db.job(jid)["pod_id"]; return self.fake.pods[pod]["env"]["MDE_JOB_TOKEN"]

    def test_runner_selection(self):
        # unknown runner -> 400 naming the known ones; known runner -> pod created from that image
        full, kid = self.s.admin_key(20)
        code, body = self.s.js("POST", "/v1/jobs", body={"input": "run.py", "runner": "nope"}, key=full)
        self.assertEqual(code, 400); self.assertIn("unknown runner", body["error"]); self.assertIn("openmm", body["message"])
        jid = self.s.js("POST", "/v1/jobs", body={"input": "run.py", "launch": "python3 {input}", "runner": "openmm", "wall_limit_s": 1800}, key=full)[1]["id"]
        self.s.req("PUT", self.s.app.blob_url(f"{jid}.in.tar.gz")[0], raw=b"pkg")
        self.assertEqual(self.s.js("POST", f"/v1/jobs/{jid}/start", key=full)[0], 202)
        self.assertTrue(self.s.app.join_bg())
        pod = self.fake.pods[self.s.app.db.job(jid)["pod_id"]]
        self.assertEqual(pod.get("image"), "ghcr.io/example/openmm:latest")
        self.assertEqual(pod["env"]["MDE_WALL_LIMIT_S"], "1800")

    def test_start_launches_pod_then_done_deletes_it(self):
        self.assertEqual(self.s.js("GET", "/v1/health")[1]["launcher"], "fake")
        full, jid = self.started_job()
        self.assertFalse(os.path.exists(self.s.app.launch_env))                       # no dev launch.env with a launcher
        row = self.s.app.db.job(jid); st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual(st["state"], "launching"); self.assertEqual(st["pod_id"], row["pod_id"]); self.assertTrue(row["launched_at"])
        pod = self.fake.pods[row["pod_id"]]
        self.assertEqual(pod["name"], "mde-" + jid); self.assertEqual(pod["env"]["MDE_JOB_ID"], jid); self.assertEqual(pod["env"]["MDE_ENDPOINT"], self.s.base)
        tok = pod["env"]["MDE_JOB_TOKEN"]; self.assertTrue(tok.startswith("jt_")); self.assertEqual(row["token_hash"], E.sha256(tok))
        self.assertNotIn(tok, self._log.getvalue())
        # Pod boots, heartbeats -> running; results; done -> pod deleted in the background.
        code, spec = self.s.js("GET", f"/internal/jobs/{jid}", key=tok); self.assertEqual(code, 200); self.assertEqual(spec["wall_limit_s"], 3600)
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": ["x"], "elapsed_s": 1}, key=tok)
        self.assertEqual(self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]["state"], "running")
        self.s.req("PUT", spec["results_put_url"], raw=b"out")
        code, j = self.s.js("POST", f"/internal/jobs/{jid}/done", body={"exitcode": 0, "elapsed_s": 10, "results_bytes": 3}, key=tok)
        self.assertEqual((code, j["state"]), (200, "done")); self.assertTrue(self.s.app.join_bg())
        self.assertEqual(self.fake.deleted, [row["pod_id"]]); self.assertEqual(self.fake.pods, {})
        self.assertIn('"ev":"pod.deleted"', self._log.getvalue())
        self.assertEqual(self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]["billed_s"], 10)

    def test_cancel_deletes_pod(self):
        full, jid = self.started_job(); pod = self.s.app.db.job(jid)["pod_id"]
        code, st = self.s.js("DELETE", f"/v1/jobs/{jid}", key=full); self.assertEqual((code, st["state"]), (202, "cancelled"))
        self.assertTrue(self.s.app.join_bg()); self.assertEqual(self.fake.deleted, [pod]); self.assertEqual(self.fake.pods, {})

    def test_pod_lost_deletes_pod_unbilled(self):
        """Final loss (attempt 2; attempt 1 relaunches, see test_pod_lost_relaunches_once_*)."""
        full, jid = self.started_job(); pod = self.s.app.db.job(jid)["pod_id"]; tok = self.pod_token(jid)
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": [], "elapsed_s": 0}, key=tok)
        self.s.app.db.set_job(jid, last_hb=time.time() - 1000, started="2020-01-01T00:00:00Z", attempt=2)
        self.s.app.watchdog_once(); self.assertTrue(self.s.app.join_bg())
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["cost_usd"]), ("failed", "pod_lost", 0.0))
        self.assertEqual(self.fake.deleted, [pod]); self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)

    def test_launch_timeout_is_no_capacity_and_deletes_pod(self):
        """Final launch timeout (attempt 2; attempt 1 relaunches, see test_launch_timeout_relaunches_once_*)."""
        full, jid = self.started_job(); pod = self.s.app.db.job(jid)["pod_id"]
        self.s.app.watchdog_once(); self.assertEqual(self.s.app.db.job(jid)["state"], "launching")         # fresh: untouched
        self.s.app.db.set_job(jid, launched_at="2020-01-01T00:00:00Z", attempt=2)
        self.s.app.watchdog_once(); self.assertTrue(self.s.app.join_bg())
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["cost_usd"]), ("failed", "no_capacity", 0.0))
        self.assertEqual(self.fake.deleted, [pod]); self.assertIsNone(self.s.app.db.job(jid)["token_hash"])
        self.assertIn('"ev":"job.launch_timeout"', self._log.getvalue())
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)

    def test_no_capacity_from_launcher(self):
        self.fake.fail_create = True
        full, jid = self.started_job()
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["cost_usd"], st["pod_id"]), ("failed", "no_capacity", 0.0, None))
        self.assertEqual(self.fake.pods, {}); self.assertIsNone(self.s.app.db.job(jid)["token_hash"])
        self.assertIn('"ev":"job.no_capacity"', self._log.getvalue())
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)

    def test_reaper(self):
        full, jid = self.started_job(); live = self.s.app.db.job(jid)["pod_id"]
        orphan = self.fake.add_pod("mde-MDJOB-20260101-NOJOB1")
        other = self.fake.add_pod("someone-elses-pod")                                             # not ours: never touched
        # A terminal job whose pod delete failed earlier (simulate by re-adding the pod after cancel).
        full2, jid2 = self.started_job(); self.s.js("DELETE", f"/v1/jobs/{jid2}", key=full2); self.s.app.join_bg()
        stale = self.fake.add_pod("mde-" + jid2, pod_id=self.s.app.db.job(jid2)["pod_id"]); self.fake.deleted.clear()
        # A running job whose pod is older than wall_limit_s + 20 min.
        full3, jid3 = self.started_job(); old = self.s.app.db.job(jid3)["pod_id"]
        self.fake.pods[old]["createdAt"] = "2020-01-01T00:00:00.000Z"
        n = self.s.app.reaper_once()
        self.assertEqual(n, 3); self.assertEqual(sorted(self.fake.deleted), sorted([orphan, stale, old]))
        self.assertIn(live, self.fake.pods); self.assertIn(other, self.fake.pods)
        logs = self._log.getvalue()
        for reason in ("no_job", "job_terminal", "overage"): self.assertIn('"reason":"%s"' % reason, logs)
        # Stuck pod: three failed passes -> reaper.stuck.
        stuck = self.fake.add_pod("mde-MDJOB-20260101-STUCK1"); self.fake.fail_delete.add(stuck)
        for _ in range(3): self.s.app.reaper_once()
        self.assertEqual(self.s.app.reaper_fail[stuck], 3); self.assertIn('"ev":"reaper.stuck"', self._log.getvalue())
        self.fake.fail_delete.clear(); self.s.app.reaper_once(); self.assertNotIn(stuck, self.s.app.reaper_fail)

    def lose_pod(self, jid):
        """Simulate 3 missed heartbeats on a running job (clock pushed back so any billing would be visible)."""
        self.s.app.db.set_job(jid, last_hb=time.time() - 1000, started="2020-01-01T00:00:00Z")
        self.s.app.watchdog_once(); self.assertTrue(self.s.app.join_bg())

    def test_pod_lost_relaunches_once_and_bills_attempt_2_only(self):
        full, jid = self.started_job(); pod1 = self.s.app.db.job(jid)["pod_id"]; tok1 = self.pod_token(jid)
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": ["old"], "elapsed_s": 5}, key=tok1)
        self.assertEqual(self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]["attempt"], 1)
        self.lose_pod(jid)
        row = self.s.app.db.job(jid); pod2 = row["pod_id"]
        self.assertEqual((row["attempt"], row["state"]), (2, "launching")); self.assertTrue(pod2 and pod2 != pod1)
        self.assertIsNone(row["started"]); self.assertIsNone(row["last_hb"]); self.assertEqual((row["billed_s"], row["thermo"]), (0, "[]"))
        self.assertEqual(self.fake.deleted, [pod1]); self.assertEqual(set(self.fake.pods), {pod2})           # never two live pods
        self.assertEqual([c for c in self.fake.calls if c[0] == "create"], [("create", jid), ("create", jid)])
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["attempt"], st["state"], st["billed_s"], st["cost_usd"], st["thermo_tail"], st["error"]), (2, "launching", 0, 0.0, [], None))
        logs = self._log.getvalue(); self.assertIn('"ev":"job.relaunch"', logs); self.assertIn('"attempt":2', logs); self.assertIn('"reason":"pod_lost"', logs)
        # The attempt-1 token is dead: a zombie pod can neither heartbeat nor finish the job.
        self.assertEqual(self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": ["zombie"], "elapsed_s": 9}, key=tok1)[0], 401)
        self.assertEqual(self.s.js("POST", f"/internal/jobs/{jid}/done", body={"exitcode": 0, "elapsed_s": 9}, key=tok1)[0], 401)
        self.assertEqual(self.s.js("GET", f"/internal/jobs/{jid}", key=tok1)[0], 401)
        # The new pod's token works; its first heartbeat starts the billing clock afresh.
        tok2 = self.pod_token(jid); self.assertNotEqual(tok2, tok1); self.assertEqual(self.s.app.db.job(jid)["token_hash"], E.sha256(tok2))
        self.assertNotIn(tok2, self._log.getvalue())
        code, spec = self.s.js("GET", f"/internal/jobs/{jid}", key=tok2); self.assertEqual(code, 200); self.assertEqual(spec["wall_limit_s"], 3600)
        self.assertEqual(self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": ["new"], "elapsed_s": 1}, key=tok2)[0], 200)
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["thermo_tail"]), ("running", ["new"])); self.assertLess(st["billed_s"], 5)
        self.assertGreater(E.parse_ts(st["started"]), time.time() - 5)                                          # not 2020
        # A stale pod1 that survived its delete is reaped as superseded (never as the job's live pod).
        self.fake.add_pod("mde-" + jid, pod_id=pod1); self.fake.deleted.clear()
        self.assertEqual(self.s.app.reaper_once(), 1); self.assertEqual(self.fake.deleted, [pod1]); self.assertIn('"reason":"superseded"', self._log.getvalue())
        self.assertIn(pod2, self.fake.pods)
        # Finish attempt 2: 100 s of GPU time billed, nothing from attempt 1.
        self.s.app.db.set_job(jid, started=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 100)))
        self.s.req("PUT", spec["results_put_url"], raw=b"out2")
        code, j = self.s.js("POST", f"/internal/jobs/{jid}/done", body={"exitcode": 0, "elapsed_s": 100, "results_bytes": 4}, key=tok2)
        self.assertEqual((code, j["state"]), (200, "done")); self.assertTrue(self.s.app.join_bg())
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["attempt"], st["billed_s"], st["cost_usd"]), ("done", 2, 100, round(100 * 2 / 3600, 4)))
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], round(20 - 100 * 2 / 3600, 6))
        self.assertEqual(self.fake.pods, {}); self.assertIn(pod2, self.fake.deleted)

    def test_second_pod_loss_fails_unbilled(self):
        full, jid = self.started_job(); pod1 = self.s.app.db.job(jid)["pod_id"]
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": [], "elapsed_s": 0}, key=self.pod_token(jid))
        self.lose_pod(jid); pod2 = self.s.app.db.job(jid)["pod_id"]; tok2 = self.pod_token(jid)
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": ["x"], "elapsed_s": 1}, key=tok2)
        self.assertEqual(self.s.app.db.job(jid)["state"], "running")
        self.lose_pod(jid)                                                                                     # attempt 2 lost too
        row = self.s.app.db.job(jid); st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["attempt"], st["cost_usd"], st["billed_s"]), ("failed", "pod_lost", 2, 0.0, 0))
        self.assertIsNone(row["token_hash"]); self.assertEqual(self.fake.deleted, [pod1, pod2]); self.assertEqual(self.fake.pods, {})
        self.assertEqual(self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={}, key=tok2)[0], 401)
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)
        logs = self._log.getvalue(); self.assertEqual(logs.count('"ev":"job.relaunch"'), 1); self.assertIn('"ev":"job.pod_lost"', logs)
        self.assertEqual([c for c in self.fake.calls if c[0] == "create"], [("create", jid)] * 2)               # no third attempt

    def test_launch_timeout_relaunches_once_then_no_capacity(self):
        full, jid = self.started_job(); pod1 = self.s.app.db.job(jid)["pod_id"]; tok1 = self.pod_token(jid)
        self.s.app.db.set_job(jid, launched_at="2020-01-01T00:00:00Z")
        self.s.app.watchdog_once(); self.assertTrue(self.s.app.join_bg())
        row = self.s.app.db.job(jid); pod2 = row["pod_id"]
        self.assertEqual((row["attempt"], row["state"]), (2, "launching")); self.assertTrue(pod2 and pod2 != pod1)
        self.assertGreater(E.parse_ts(row["launched_at"]), time.time() - 5)                                    # fresh timeout clock
        self.assertEqual(self.fake.deleted, [pod1]); self.assertEqual(set(self.fake.pods), {pod2})
        self.assertIn('"reason":"launch_timeout"', self._log.getvalue())
        self.assertEqual(self.s.js("GET", f"/internal/jobs/{jid}", key=tok1)[0], 401)
        self.assertEqual(self.s.js("GET", f"/internal/jobs/{jid}", key=self.pod_token(jid))[0], 200)
        self.s.app.watchdog_once(); self.assertEqual(self.s.app.db.job(jid)["state"], "launching")            # not yet timed out
        self.s.app.db.set_job(jid, launched_at="2020-01-01T00:00:00Z")
        self.s.app.watchdog_once(); self.assertTrue(self.s.app.join_bg())
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["attempt"], st["cost_usd"]), ("failed", "no_capacity", 2, 0.0))
        self.assertEqual(self.fake.deleted, [pod1, pod2]); self.assertEqual(self.fake.pods, {}); self.assertIsNone(self.s.app.db.job(jid)["token_hash"])
        self.assertIn('"ev":"job.launch_timeout"', self._log.getvalue())
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)

    def test_relaunch_with_no_capacity_fails_unbilled(self):
        full, jid = self.started_job(); pod1 = self.s.app.db.job(jid)["pod_id"]
        self.s.js("POST", f"/internal/jobs/{jid}/heartbeat", body={"thermo_tail": [], "elapsed_s": 0}, key=self.pod_token(jid))
        self.fake.fail_create = True; self.lose_pod(jid)
        st = self.s.js("GET", f"/v1/jobs/{jid}", key=full)[1]
        self.assertEqual((st["state"], st["error"], st["attempt"], st["cost_usd"], st["pod_id"]), ("failed", "no_capacity", 2, 0.0, None))
        self.assertEqual(self.fake.deleted, [pod1]); self.assertEqual(self.fake.pods, {})
        self.assertEqual(self.s.js("GET", "/v1/me", key=full)[1]["balance_usd"], 20.0)

class TestBlobRetention(Base):
    runners_open = True; fake_launcher = True
    def blob(self, name, data=b"x", age_s=None):
        p = self.s.app.blob_path(name)
        with open(p, "wb") as fh: fh.write(data)
        if age_s: os.utime(p, (time.time() - age_s, time.time() - age_s))
        return p

    def test_purge_deletes_only_old_terminal_jobs_and_old_strays(self):
        full, kid = self.s.admin_key(20); ids = []
        for _ in range(3):
            jid = self.s.js("POST", "/v1/jobs", body={"input": "in.lmp"}, key=full)[1]["id"]; ids.append(jid)
            self.s.req("PUT", self.s.app.blob_url(f"{jid}.in.tar.gz")[0], raw=b"deck-" + jid.encode())
            self.blob(f"{jid}.out.tar.gz", b"results-" + jid.encode())
        old, fresh, live = ids
        days = self.s.app.cfg.blob_retention_days; self.assertEqual(days, 30.0)
        self.s.app.db.set_job(old, state="done", finished=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - (days + 1) * 86400)))
        self.s.app.db.set_job(fresh, state="done", finished=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - (days - 1) * 86400)))
        # `live` stays in state uploaded (no finished): its blobs are never touched however old the files are.
        for suffix in (".in.tar.gz", ".out.tar.gz"): os.utime(self.s.app.blob_path(live + suffix), (0, 0))
        self.blob(f"{old}.out.tar.gz.part", b"partial")
        stray_old = self.blob("MDJOB-20200101-GONE01.out.tar.gz", b"orphan", age_s=(days + 2) * 86400)
        stray_new = self.blob("MDJOB-20260901-GONE02.in.tar.gz", b"orphan", age_s=3600)
        other = self.blob("notes.txt", b"not ours", age_s=(days + 2) * 86400)                                # not a job blob: ignored
        n = self.s.app.purge_blobs_once()
        self.assertEqual(n, 4)                                                                                # old .in, .out, .part + stray_old
        for suffix in (".in.tar.gz", ".out.tar.gz"):
            self.assertFalse(os.path.exists(self.s.app.blob_path(old + suffix)))
            self.assertTrue(os.path.exists(self.s.app.blob_path(fresh + suffix))); self.assertTrue(os.path.exists(self.s.app.blob_path(live + suffix)))
        self.assertFalse(os.path.exists(self.s.app.blob_path(f"{old}.out.tar.gz.part")))
        self.assertFalse(os.path.exists(stray_old)); self.assertTrue(os.path.exists(stray_new)); self.assertTrue(os.path.exists(other))
        logs = [json.loads(l) for l in self._log.getvalue().splitlines() if '"ev":"blob.purged"' in l]
        self.assertEqual(len(logs), 4)
        by_name = {l["name"]: l for l in logs}
        self.assertEqual(by_name[f"{old}.out.tar.gz"]["job"], old); self.assertEqual(by_name[f"{old}.out.tar.gz"]["bytes"], len(b"results-" + old.encode()))
        self.assertEqual(by_name[f"{old}.out.tar.gz"]["reason"], "retention"); self.assertEqual(by_name["MDJOB-20200101-GONE01.out.tar.gz"]["reason"], "stray")
        self.assertGreater(self.s.app.last_blob_purge, 0)
        # Second pass is a no-op; fresh job's results still downloadable; old job's results answer 410.
        self.assertEqual(self.s.app.purge_blobs_once(), 0)
        self.assertEqual(self.s.js("GET", f"/v1/jobs/{fresh}/results", key=full)[0], 200)
        code, j = self.s.js("GET", f"/v1/jobs/{old}/results", key=full); self.assertEqual(code, 410); self.assertEqual(j["error"], "results expired")
        self.assertEqual(self.s.js("GET", f"/v1/jobs/{old}", key=full)[1]["state"], "done")                 # metadata kept

    def test_retention_config(self):
        self.assertEqual(E.Config({"MDE_BLOB_RETENTION_DAYS": "7", "MDE_DB": "/nonexistent/x"}).blob_retention_days, 7.0)
        self.assertEqual(E.Config({"MDE_DB": "/nonexistent/x"}).blob_retention_days, 30.0)
        self.assertEqual(E.BLOB_PURGE_INTERVAL_S, 3600)

class TestRunPodLauncher(unittest.TestCase):
    """Request shaping against a monkeypatched transport; no network."""
    KEY = "rpa_TESTKEY_" + "z" * 24
    def launcher(self, **env):
        base = {"RUNPOD_API_KEY": self.KEY, "MDE_PUBLIC_URL": "https://api.example.test/", "MDE_DB": "/nonexistent/x.sqlite"}
        base.update(env); return L.RunPodLauncher(E.Config(base))

    def test_create_body_and_ladder(self):
        lc = self.launcher(); calls = []
        def fake_request(method, path, body=None):
            calls.append((method, path, body)); return (500, '{"error":"no capacity"}') if len(calls) == 1 else (201, '{"id":"pod123","name":"x"}')
        lc._request = fake_request
        log = io.StringIO()
        with redirect_stdout(log): pid = lc.create("MDJOB-20260906-ABC123", "jt_" + "0" * 32, 3600, "rtx4090")
        self.assertEqual(pid, "pod123"); self.assertEqual(len(calls), 2)
        for (m, p, b), (cloud, gid) in zip(calls, L.DEFAULT_LADDER):
            self.assertEqual((m, p), ("POST", "/v2/pods")); self.assertEqual(b["cloud"], cloud)
            self.assertEqual(b["gpu"], {"id": gid, "count": 1, "minCudaVersion": "12.4"}); self.assertEqual(b["disk"], 20)
            self.assertEqual(b["name"], "mde-MDJOB-20260906-ABC123"); self.assertEqual(b["image"], L.DEFAULT_IMAGE)
            self.assertEqual(b["env"], {"MDE_ENDPOINT": "https://api.example.test", "MDE_JOB_ID": "MDJOB-20260906-ABC123", "MDE_JOB_TOKEN": "jt_" + "0" * 32, "MDE_WALL_LIMIT_S": "3600"})
            self.assertNotIn("dataCenterIds", b)
        out = log.getvalue(); self.assertEqual(out.count('"ev":"launch.attempt"'), 2); self.assertIn('"code":500', out)
        self.assertNotIn(self.KEY, out); self.assertNotIn("jt_" + "0" * 32, out)

    def test_config_overrides(self):
        lc = self.launcher(MDE_RUNNER_IMAGE="ghcr.io/x/y:z", MDE_POD_DISK_GB="40", MDE_MIN_CUDA="12.8",
                           MDE_GPU_LADDER="SECURE:NVIDIA A100 80GB PCIe, community:NVIDIA GeForce RTX 4090")
        self.assertEqual(lc.ladder, [("SECURE", "NVIDIA A100 80GB PCIe"), ("COMMUNITY", "NVIDIA GeForce RTX 4090")])
        b = lc.pod_body("J", "t", "SECURE", "NVIDIA A100 80GB PCIe")
        self.assertEqual((b["image"], b["disk"], b["gpu"]["minCudaVersion"]), ("ghcr.io/x/y:z", 40, "12.8"))
        with self.assertRaises(ValueError): L.parse_ladder("PRIVATE:foo")
        with self.assertRaises(ValueError): L.parse_ladder("nocolon")

    def test_all_rungs_fail_is_no_capacity(self):
        lc = self.launcher(); lc._request = lambda m, p, body=None: (422, '{"error":"bad"}')
        with redirect_stdout(io.StringIO()), self.assertRaises(L.NoCapacity): lc.create("J", "t", 60, "any")
        # 201 without an id is also a failed rung, and its body is not echoed.
        lc._request = lambda m, p, body=None: (201, '{"env":{"MDE_JOB_TOKEN":"jt_secret"}}'); out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(L.NoCapacity): lc.create("J", "t", 60, "any")
        self.assertNotIn("jt_secret", out.getvalue())

    def test_delete_semantics(self):
        lc = self.launcher(); lc.backoff_s = 0; seq = []
        def scripted(codes):
            it = iter(codes)
            def f(m, p, body=None):
                seq.append((m, p)); return next(it), "{}"
            return f
        lc._request = scripted([204]); self.assertTrue(lc.delete("p1"))
        lc._request = scripted([404]); self.assertTrue(lc.delete("p1"))
        lc._request = scripted([429, 500, 204]); self.assertTrue(lc.delete("p1"))
        lc._request = scripted([500, 500, 500])
        with self.assertRaises(L.LauncherError): lc.delete("p1")
        seq.clear(); lc._request = scripted([403])
        with self.assertRaises(L.LauncherError): lc.delete("p1")
        self.assertEqual(seq, [("DELETE", "/v2/pods/p1")])                     # other 4xx: no retry

    def test_get_and_list(self):
        lc = self.launcher()
        lc._request = lambda m, p, body=None: (200, '{"items":[{"id":"a","name":"mde-x"}]}')
        self.assertEqual([p["id"] for p in lc.list_pods()], ["a"])
        lc._request = lambda m, p, body=None: (200, '[{"id":"b"}]'); self.assertEqual(lc.list_pods()[0]["id"], "b")
        lc._request = lambda m, p, body=None: (200, '{"pods":[{"id":"c","name":"mde-y"}]}')   # LIVE shape (2026-09-06)
        self.assertEqual([p["id"] for p in lc.list_pods()], ["c"])
        lc._request = lambda m, p, body=None: (404, ""); self.assertIsNone(lc.get("zz"))
        lc._request = lambda m, p, body=None: (200, '{"id":"zz","status":"RUNNING"}'); self.assertEqual(lc.get("zz")["status"], "RUNNING")
        lc._request = lambda m, p, body=None: (500, "boom")
        with self.assertRaises(L.LauncherError): lc.list_pods()

    def test_authorization_header_and_url(self):
        lc = self.launcher(); seen = []
        def fake_open(req):
            seen.append(req); return 204, ""
        lc._open = fake_open; lc.delete("p9")
        req = seen[0]; self.assertEqual(req.full_url, "https://api.runpod.io/v2/pods/p9"); self.assertEqual(req.get_method(), "DELETE")
        auth = req.get_header("Authorization"); self.assertTrue(auth and auth.startswith("Bearer ") and len(auth) == len("Bearer ") + len(self.KEY))
        self.assertEqual(req.timeout if hasattr(req, "timeout") else lc.timeout, lc.timeout)
        with self.assertRaises(ValueError): L.RunPodLauncher(E.Config({"RUNPOD_API_KEY": "", "MDE_DB": "/nonexistent/x"}))

    def test_pod_age(self):
        self.assertAlmostEqual(L.pod_age_s({"createdAt": "2020-01-01T00:00:00.000Z"}, now_ts=1577836800 + 90), 90, places=3)
        self.assertAlmostEqual(L.pod_age_s({"createdAt": "2020-01-01T01:00:00+01:00"}, now_ts=1577836800 + 5), 5, places=3)
        self.assertIsNone(L.pod_age_s({"createdAt": "garbage"})); self.assertIsNone(L.pod_age_s({}))

class TestUnits(unittest.TestCase):
    def test_schema_migration_adds_pod_columns(self):
        d = tempfile.mkdtemp(prefix="mde-mig-"); path = os.path.join(d, "old.sqlite")
        import sqlite3
        c = sqlite3.connect(path)
        c.executescript(E.SCHEMA.replace(", pod_id text, launched_at text", "")); c.close()
        db = E.DB(path); cols = {r["name"] for r in db.q("pragma table_info(jobs)")}
        self.assertIn("pod_id", cols); self.assertIn("launched_at", cols)
        db2 = E.DB(path); db.c.close(); db2.c.close(); shutil.rmtree(d, ignore_errors=True)      # second open: duplicate column ignored

    def test_parse_ts_is_utc(self):
        self.assertEqual(E.parse_ts("2020-01-01T00:00:00Z"), 1577836800); self.assertIsNone(E.parse_ts(None))
        self.assertEqual(E.parse_ts("2026-07-01T12:00:00Z"), 1782907200)                                    # mid-DST date, still exact
        t = int(time.time()); self.assertEqual(E.parse_ts(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))), t)

    def test_signature_roundtrip(self):
        p = b'{"a":1}'; h = E.stripe_sign(p, "s")
        self.assertTrue(E.verify_stripe_signature(p, h, "s")); self.assertFalse(E.verify_stripe_signature(p, h, "t"))
        self.assertFalse(E.verify_stripe_signature(p, "t=abc,v1=00", "s")); self.assertFalse(E.verify_stripe_signature(p, h, ""))
    def test_parse_packs_rates(self):
        self.assertEqual(E.parse_packs("price_a:25:12.5, price_b:100:50"), {"price_a": (25.0, 12.5), "price_b": (100.0, 50.0)})
        self.assertEqual(E.parse_rates(""), {"any": 2.0, "rtx4090": 2.0}); self.assertEqual(E.parse_rates("any:2,a100:4"), {"any": 2.0, "a100": 4.0})
    def test_env_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f: f.write("# c\nX_MDE_T=\"v 1\"\nY_MDE_T=2\n")
        os.environ.pop("X_MDE_T", None); os.environ["Y_MDE_T"] = "keep"; E.load_env_file(f.name); os.unlink(f.name)
        self.assertEqual(os.environ["X_MDE_T"], "v 1"); self.assertEqual(os.environ["Y_MDE_T"], "keep")

if __name__ == "__main__":
    unittest.main()
