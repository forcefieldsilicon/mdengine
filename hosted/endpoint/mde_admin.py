#!/usr/bin/env python3
"""Operator CLI for the MDEngine hosted endpoint. Same sqlite file as mde_endpoint.py; stdlib only.

  mde_admin.py key new --email E --credit USD [--label L]   # prints the full key ONCE
  mde_admin.py key list
  mde_admin.py credit add --key KEYID --usd X [--note TEXT]
  mde_admin.py ledger [--key KEYID]
  mde_admin.py stats
  mde_admin.py pending [--reveal SESSION_ID]                 # keys bought via webhook, not yet shown
  mde_admin.py statement --month YYYY-MM|prev [--key KEYID] [--out DIR]   # plain-text monthly statements, one per key

DB path: --db, else $MDE_DB, else the value in --env-file / /etc/mde/endpoint.env.
"""
import argparse, calendar, os, secrets, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mde_endpoint as E

OPEN = []

def open_db(a):
    E.load_env_file(a.env_file)
    path = a.db or os.environ.get("MDE_DB")
    if not path: sys.exit("no db: pass --db or set MDE_DB (or --env-file)")
    db = E.DB(path); OPEN.append(db)
    return db, E.Config()

def rate(cfg): return cfg.rates.get("any", 2.0)

def cmd_key_new(a):
    db, cfg = open_db(a)
    full, kid = db.create_key(email=a.email, label=a.label)
    if a.credit:
        db.add_credit("admin-" + secrets.token_hex(6), kid, a.credit, a.credit / rate(cfg) * 3600, "admin")
    print(f"key_id  {kid}\nemail   {a.email}\nbalance ${db.balance(kid):.2f}\n\n{full}\n\n(shown once; only the hash is stored)  mdengine login {full}")
    E.log("admin.key_new", key_id=kid, usd=a.credit, has_email=bool(a.email))

def cmd_key_list(a):
    db, _ = open_db(a)
    print(f"{'key_id':<10}{'balance':>10}  {'created':<21}{'email':<32}label")
    for k in db.q("select * from keys order by created"):
        print(f"{k['key_id']:<10}{db.balance(k['key_id']):>10.2f}  {k['created']:<21}{(k['email'] or '-'):<32}{k['label'] or ''}")

def cmd_credit_add(a):
    db, cfg = open_db(a)
    if not db.key_by_id(a.key): sys.exit(f"no key {a.key}")
    sid = "admin-" + secrets.token_hex(6)
    db.add_credit(sid, a.key, a.usd, a.usd / rate(cfg) * 3600, a.note or "admin")
    print(f"{sid}: +${a.usd:.2f} -> key {a.key} balance ${db.balance(a.key):.2f}")
    E.log("admin.credit_add", key_id=a.key, usd=a.usd, session=sid)

def cmd_ledger(a):
    db, _ = open_db(a)
    where, args = ("where key_id=?", (a.key,)) if a.key else ("", ())
    print("-- credits")
    for c in db.q(f"select * from credits {where} order by created", *args):
        print(f"{c['created']}  {c['key_id']}  +${c['usd']:>8.2f}  {c['gpu_s']/3600:>7.2f} h  {c['price_id'] or '-':<32} {c['session_id']}")
    print("-- billed jobs")
    for j in db.q(f"select * from jobs {where} order by created", *args):
        if j["state"] in ("created", "uploaded", "queued", "launching"): continue
        print(f"{j['created']}  {j['key_id']}  -${E.job_cost(j):>8.4f}  {E.billed_seconds(j):>7d} s  {j['state']:<10} {j['error'] or '':<12} {j['id']}")

def cmd_stats(a):
    db, cfg = open_db(a)
    keys = db.one("select count(*) n from keys")["n"]
    credits = db.one("select coalesce(sum(usd),0) s, count(*) n from credits")
    billed = sum(E.job_cost(j) for j in db.q("select * from jobs where state not in ('created','uploaded','queued','launching')"))
    print(f"keys           {keys}\ncredit rows    {credits['n']}\ncredited usd   {credits['s']:.2f}\nbilled usd     {billed:.4f}\noutstanding    {credits['s']-billed:.2f}")
    for r in db.q("select state, count(*) n from jobs group by state order by state"): print(f"jobs {r['state']:<10} {r['n']}")
    print(f"pending keys   {db.one('select count(*) n from pending_keys')['n']}\nrunners        {'open' if cfg.runners_open else 'closed'}\nrates          {cfg.rates}\npacks          {len(cfg.packs)}")

def cmd_pending(a):
    db, _ = open_db(a)
    if a.reveal:
        p = db.one("select * from pending_keys where session_id=?", a.reveal)
        if not p: sys.exit("no pending key for that session")
        k = db.key_by_id(p["key_id"])
        print(f"key_id {p['key_id']}  email {k['email'] if k else '-'}\n\n{p['full_key']}\n")
        if not a.keep: db.x("delete from pending_keys where session_id=?", a.reveal); print("(removed from pending; deliver it now)")
        E.log("admin.pending_reveal", key_id=p["key_id"], session=a.reveal)
        return
    rows = db.q("select p.*, k.email from pending_keys p left join keys k on k.key_id=p.key_id order by p.created")
    if not rows: print("no pending keys"); return
    for p in rows: print(f"{p['created']}  {p['key_id']}  {p['email'] or '-':<32} {p['session_id']}")


# ----------------------------------------------------------------------------- statements

def month_bounds(month):
    """'YYYY-MM' or 'prev' -> (label, start_iso, end_iso); end is the first instant of the next month (exclusive)."""
    if month == "prev":
        y, m = time.gmtime()[:2]; y, m = (y - 1, 12) if m == 1 else (y, m - 1); month = "%04d-%02d" % (y, m)
    try: y, m = (int(x) for x in month.split("-")); assert 1 <= m <= 12 and 2000 <= y <= 2999
    except (ValueError, AssertionError): sys.exit("--month must be YYYY-MM or prev")
    ny, nm = (y + 1, 1) if m == 12 else (y, m + 1)
    return month, "%04d-%02d-01T00:00:00Z" % (y, m), "%04d-%02d-01T00:00:00Z" % (ny, nm)

def balance_before(db, key_id, iso):
    """Balance from credits created before `iso` minus cost of jobs that reached a terminal state before it."""
    cred = float(db.one("select coalesce(sum(usd),0) s from credits where key_id=? and created<?", key_id, iso)["s"])
    billed = sum(E.job_cost(j) for j in db.q("select * from jobs where key_id=? and state in ('done','failed','cancelled') and finished<?", key_id, iso))
    return round(cred - billed, 6)

def statement_text(db, cfg, k, month, start, end):
    """One key's statement for the month, or None when the key had no credits and no finished jobs that month.
    A job is listed in the month it reached a terminal state (that is when its cost is final)."""
    credits = db.q("select * from credits where key_id=? and created>=? and created<? order by created", k["key_id"], start, end)
    jobs = db.q("select * from jobs where key_id=? and state in ('done','failed','cancelled') and finished>=? and finished<? order by finished", k["key_id"], start, end)
    if not credits and not jobs: return None
    y, m = (int(x) for x in month.split("-")); last_day = calendar.monthrange(y, m)[1]
    L = [f"{cfg.brand} -- statement {month}", f"key id     {k['key_id']}", f"email      {k['email'] or '-'}",
         f"generated  {E.now()}", f"rates      " + ", ".join(f"{g} ${r:.2f}/GPU-h" for g, r in sorted(cfg.rates.items())), "",
         f"Opening balance ({month}-01)   ${balance_before(db, k['key_id'], start):.2f}", "", "Credits"]
    if credits:
        for c in credits:
            src = "Stripe session " + c["session_id"] if not c["session_id"].startswith("admin-") else "manual credit " + c["session_id"]
            L.append(f"  {c['created']}  +${c['usd']:>8.2f}  {c['gpu_s']/3600:>7.2f} GPU-h  {src}" + (f"  ({c['price_id']})" if c["price_id"] and c["price_id"] != "admin" else ""))
    else: L.append("  (none)")
    L += ["", "Jobs (listed in the month they finished)", f"  {'finished':<21}{'id':<23}{'label':<24}{'state':<10}{'error':<12}{'gpu':<9}{'billed_s':>9}  cost"]
    tot_s = tot_cost = 0.0; billed_n = 0
    for j in jobs:
        label = (E.json.loads(j["spec"]).get("label") or "-")[:22]; cost = E.job_cost(j); sec = E.billed_seconds(j)
        if cost: billed_n += 1
        tot_s += sec if cost else 0; tot_cost += cost
        L.append(f"  {j['finished']:<21}{j['id']:<23}{label:<24}{j['state']:<10}{(j['error'] or '-'):<12}{(j['gpu'] or '-'):<9}{sec:>9d}  ${cost:.4f}")
    if not jobs: L.append("  (none)")
    L += ["", f"Totals {month}", f"  credits added        ${sum(c['usd'] for c in credits):.2f}",
          f"  jobs finished        {len(jobs)} (billed {billed_n}, unbilled {len(jobs) - billed_n})",
          f"  GPU seconds billed   {int(tot_s)}", f"  charges              ${tot_cost:.4f}", "",
          f"Closing balance ({month}-{last_day:02d})   ${balance_before(db, k['key_id'], end):.2f}",
          f"Balance now                     ${db.balance(k['key_id']):.2f}", "",
          "Credits never expire. Questions: reply to your Stripe receipt and quote the key id above."]
    return "\n".join(L) + "\n"

def cmd_statement(a):
    db, cfg = open_db(a)
    month, start, end = month_bounds(a.month)
    out = a.out or os.path.join(os.path.dirname(os.path.abspath(a.db or os.environ.get("MDE_DB"))), "statements", month)
    keys = [db.key_by_id(a.key)] if a.key else db.q("select * from keys order by created")
    if a.key and not keys[0]: sys.exit(f"no key {a.key}")
    written = []
    for k in keys:
        text = statement_text(db, cfg, k, month, start, end)
        if text is None: continue
        os.makedirs(out, mode=0o750, exist_ok=True)
        path = os.path.join(out, f"{k['key_id']}.txt")
        with open(path, "w", opener=lambda f, fl: os.open(f, fl, 0o640)) as fh: fh.write(text)
        written.append(path); print(path)
    if not written: print(f"no activity in {month}")
    E.log("admin.statement", month=month, files=len(written), out=out)

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db"); ap.add_argument("--env-file", default=os.environ.get("MDE_ENV_FILE", "/etc/mde/endpoint.env"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    key = sub.add_parser("key").add_subparsers(dest="sub", required=True)
    n = key.add_parser("new"); n.add_argument("--email", required=True); n.add_argument("--credit", type=float, default=0.0); n.add_argument("--label"); n.set_defaults(f=cmd_key_new)
    key.add_parser("list").set_defaults(f=cmd_key_list)
    cr = sub.add_parser("credit").add_subparsers(dest="sub", required=True)
    c = cr.add_parser("add"); c.add_argument("--key", required=True); c.add_argument("--usd", type=float, required=True); c.add_argument("--note"); c.set_defaults(f=cmd_credit_add)
    l = sub.add_parser("ledger"); l.add_argument("--key"); l.set_defaults(f=cmd_ledger)
    sub.add_parser("stats").set_defaults(f=cmd_stats)
    p = sub.add_parser("pending"); p.add_argument("--reveal", metavar="SESSION_ID"); p.add_argument("--keep", action="store_true"); p.set_defaults(f=cmd_pending)
    st = sub.add_parser("statement", help="write one plain-text statement per key with activity in the month")
    st.add_argument("--month", required=True, metavar="YYYY-MM|prev"); st.add_argument("--key", metavar="KEYID")
    st.add_argument("--out", metavar="DIR", help="default: <db dir>/statements/YYYY-MM"); st.set_defaults(f=cmd_statement)
    a = ap.parse_args(argv)
    try: a.f(a)
    finally:
        while OPEN: OPEN.pop().c.close()

if __name__ == "__main__":
    main()
