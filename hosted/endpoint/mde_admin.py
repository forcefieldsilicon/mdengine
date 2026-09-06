#!/usr/bin/env python3
"""Operator CLI for the MDEngine hosted endpoint. Same sqlite file as mde_endpoint.py; stdlib only.

  mde_admin.py key new --email E --credit USD [--label L]   # prints the full key ONCE
  mde_admin.py key list
  mde_admin.py credit add --key KEYID --usd X [--note TEXT]
  mde_admin.py ledger [--key KEYID]
  mde_admin.py stats
  mde_admin.py pending [--reveal SESSION_ID]                 # keys bought via webhook, not yet shown

DB path: --db, else $MDE_DB, else the value in --env-file / /etc/mde/endpoint.env.
"""
import argparse, os, secrets, sys
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
    a = ap.parse_args(argv)
    try: a.f(a)
    finally:
        while OPEN: OPEN.pop().c.close()

if __name__ == "__main__":
    main()
