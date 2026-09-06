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

class Server:
    def __init__(self, runners_open=False):
        self.dir = tempfile.mkdtemp(prefix="mde-test-")
        env = {"MDE_DB": os.path.join(self.dir, "t.sqlite"), "MDE_BLOBS": os.path.join(self.dir, "blobs"), "MDE_BIND": "127.0.0.1:0",
               "STRIPE_SECRET_KEY": "sk_test_fake", "STRIPE_WEBHOOK_SECRET": WEBHOOK_SECRET,
               "MDE_PACKS": f"{PRICE_STARTER}:25:12.5,{PRICE_LAB}:100:50", "MDE_RUNNERS_OPEN": "1" if runners_open else "",
               "MDE_ADMIN_TOKEN": "admintok"}
        self.cfg = E.Config(env); self.srv, self.app = E.make_server(self.cfg)
        self.base = self.app.public_url
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
    def setUp(self):
        self._orig = E.stripe_fetch_session; E.stripe_fetch_session = fake_fetch; FAKE_SESSIONS.clear()
        self.s = Server(self.runners_open); self._log = io.StringIO(); self._logpatch = redirect_stdout(self._log); self._logpatch.__enter__()
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

class TestUnits(unittest.TestCase):
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
