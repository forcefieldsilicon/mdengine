#!/usr/bin/env python3
"""MCP (Model Context Protocol) over Streamable HTTP for the hosted endpoint: `POST /mcp`.

Any MCP client that speaks HTTP -- Claude Code (`claude mcp add --transport http ...`), Claude.ai
custom connectors, Cursor, Goose, ... -- can drive the hosted GPU tier without installing the macOS
`mdengine-mcp` binary. Same trust model as the REST API: an API key (`Authorization: Bearer mde_...`)
IS the account; anyone holding it can spend its credit.

Design (stdlib only, no sessions):
  * Stateless Streamable HTTP: every JSON-RPC request is one POST; responses are plain JSON
    (no SSE, no Mcp-Session-Id). GET/DELETE /mcp answer 405. Notifications answer 202 with no body.
  * `initialize`, `ping`, `tools/list` need no key so directories and clients can inspect the server.
    `tools/call` without a valid key returns an in-band `isError` result explaining how to get one
    (not HTTP 401: a 401 makes clients start an OAuth dance we do not offer).
  * Tools are thin wrappers over App.create_job/start_job/cancel_job/job_results and the status
    query -- the REST routes call the same methods, so behaviour and billing cannot diverge.
  * `submit_job` accepts the deck INLINE (files as text, <= MAX_INLINE_BYTES): the endpoint builds the
    tarball itself, so an agent needs no PUT step. Big decks use create_job -> PUT upload_url -> start_job.
  * `GET /.well-known/mcp/server-card.json` (SEP-2127 draft, not yet in the MCP spec) advertises the
    remote for clients that probe a host for MCP.
"""
import io, json, tarfile, time

import mde_endpoint as E          # resolved at call time; mde_endpoint imports this module

PROTOCOL_VERSIONS = ("2025-03-26", "2025-06-18", "2025-11-25")
DEFAULT_PROTOCOL = "2025-06-18"
SERVER_NAME = "com.forcefieldsilicon/mdengine"          # MCP Registry name (server.json)
SERVER_TITLE = "MDEngine (hosted GPU)"
MAX_INLINE_BYTES = 8_000_000                               # inline deck cap; larger decks use create_job + PUT
MAX_BODY = 16_000_000
SIGNUP_URL = "https://forcefieldsilicon.com/mdengine"
CORS = {"Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id"}

def _ann(read_only, destructive=False, idempotent=False):
    return {"readOnlyHint": read_only, "destructiveHint": destructive, "idempotentHint": idempotent, "openWorldHint": True}

JOB_ID = {"type": "string", "description": "Job id, e.g. MDJOB-20260907-3F200C"}
SPEC_PROPS = {
    "input": {"type": "string", "description": "Relative path of the LAMMPS (or runner) input script inside the deck, e.g. in.lmp"},
    "label": {"type": "string", "description": "Free text <= 120 chars shown in job lists"},
    "gpu": {"type": "string", "description": "GPU class: any (cheapest available, default), rtx4090, a100 -- see account.rate_table"},
    "wall_limit_s": {"type": "integer", "description": "Hard cap in seconds (default 14400, max 86400); the job fails at the cap and is billed to it"},
    "estimate_s": {"type": "integer", "description": "Your runtime guess in seconds; only used for the balance pre-check (min 900 s at the rate)"},
    "runner": {"type": "string", "description": "Runner flavour: lammps (default) or openmm"},
    "launch": {"type": "string", "description": "Launch template; omit for the default KOKKOS/CUDA LAMMPS command line"},
}

TOOLS = [
    {"name": "account", "title": "Account balance and rates",
     "description": "Balance in USD, the per-GPU hourly rate table, and the key id of the API key in use.",
     "inputSchema": {"type": "object", "properties": {}}, "annotations": _ann(True, idempotent=True)},
    {"name": "submit_job", "title": "Submit a deck (inline files) and start it",
     "description": "One call: create a hosted GPU job, upload the deck given INLINE as {relative_path: text}, and queue it. "
                    "Total inline size <= 8 MB; for larger decks use create_job, PUT the tarball to upload_url, then start_job. "
                    "Billing starts at the first heartbeat (state running) and stops at done/failed/cancelled. Decks are programs: only submit what you have read.",
     "inputSchema": {"type": "object", "properties": {**SPEC_PROPS,
                     "files": {"type": "object", "additionalProperties": {"type": "string"},
                               "description": "Deck contents: {\"in.lmp\": \"...\", \"data.al\": \"...\"}; paths relative, no '..'; must include `input`"}},
                     "required": ["input", "files"]}, "annotations": _ann(False)},
    {"name": "create_job", "title": "Create a job (returns upload URL)",
     "description": "Step 1 of the two-step path for big decks: validates the spec, reserves a job id, returns a presigned upload_url. "
                    "PUT the deck as a .tar.gz (<= 2 GB, relative paths, input at `input`) to upload_url, then call start_job.",
     "inputSchema": {"type": "object", "properties": SPEC_PROPS, "required": ["input"]}, "annotations": _ann(False)},
    {"name": "start_job", "title": "Start an uploaded job",
     "description": "Step 2: queue a job whose deck tarball has been uploaded. A GPU pod is launched; billing starts when it reports running.",
     "inputSchema": {"type": "object", "properties": {"id": JOB_ID}, "required": ["id"]}, "annotations": _ann(False)},
    {"name": "job_status", "title": "Job status",
     "description": "State (created|uploaded|queued|launching|running|uploading|done|failed|cancelled), GPU, rate, billed seconds, cost so far, exit code, error, last thermo lines.",
     "inputSchema": {"type": "object", "properties": {"id": JOB_ID}, "required": ["id"]}, "annotations": _ann(True, idempotent=True)},
    {"name": "job_log", "title": "Job log tail",
     "description": "The last <= 20 thermo/log lines the running pod reported (30 s heartbeat). Full log.lammps is in the results tarball.",
     "inputSchema": {"type": "object", "properties": {"id": JOB_ID}, "required": ["id"]}, "annotations": _ann(True, idempotent=True)},
    {"name": "job_results", "title": "Results download URL",
     "description": "For a done/failed job: a presigned download_url (valid ~7 days) for the results tarball (work/, log.lammps, exitcode). Results are deleted 30 days after the run.",
     "inputSchema": {"type": "object", "properties": {"id": JOB_ID}, "required": ["id"]}, "annotations": _ann(True, idempotent=True)},
    {"name": "list_jobs", "title": "List jobs",
     "description": "Jobs of this API key, newest first.",
     "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer", "description": "1..200, default 50"}}}, "annotations": _ann(True, idempotent=True)},
    {"name": "cancel_job", "title": "Cancel job",
     "description": "Cancel a job that is not finished. A running job is billed up to the cancel time; its pod is terminated.",
     "inputSchema": {"type": "object", "properties": {"id": JOB_ID}, "required": ["id"]}, "annotations": _ann(False, destructive=True, idempotent=True)},
]

class ToolError(Exception):
    pass

def build_tarball(files, input_path):
    """{relative_path: text} -> .tar.gz bytes. Rejects absolute paths, '..', empty names, non-text, missing input."""
    if not isinstance(files, dict) or not files: raise ToolError("files must be a non-empty object {path: text}")
    if input_path not in files: raise ToolError("`input` (%s) must be one of the files" % input_path)
    total = 0; buf = io.BytesIO(); mtime = int(time.time())
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for path, content in files.items():
            if not isinstance(path, str) or not path or path.startswith("/") or path.startswith("~") or ".." in path.split("/") or "\\" in path:
                raise ToolError("bad path %r: relative, no '..'" % path)
            if not isinstance(content, str): raise ToolError("file %s: content must be text" % path)
            data = content.encode("utf-8"); total += len(data)
            if total > MAX_INLINE_BYTES: raise ToolError("inline deck exceeds %d bytes; use create_job + PUT upload_url + start_job" % MAX_INLINE_BYTES)
            ti = tarfile.TarInfo(path); ti.size = len(data); ti.mtime = mtime; ti.mode = 0o644
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()

class MCP:
    def __init__(self, app):
        self.app = app

    # ------------------------------------------------------------------ discovery
    def server_card(self):
        """SEP-2127-style card; field names follow the MCP Registry server.json `remotes` shape."""
        return {"name": SERVER_NAME, "title": SERVER_TITLE, "version": E.VERSION,
                "description": "Hosted GPU molecular dynamics for agents: submit LAMMPS/OpenMM decks, poll status and logs, fetch results. Prepaid credit; API key = account.",
                "websiteUrl": SIGNUP_URL,
                "repository": {"url": "https://github.com/forcefieldsilicon/mdengine", "source": "github"},
                "remotes": [{"type": "streamable-http", "url": self.app.public_url + "/mcp",
                             "headers": [{"name": "Authorization", "description": "Bearer mde_... -- the API key issued with a credit pack (" + SIGNUP_URL + ")",
                                          "isRequired": True, "isSecret": True}]}],
                "supportedProtocolVersions": list(PROTOCOL_VERSIONS),
                "capabilities": {"tools": {}}}

    # ------------------------------------------------------------------ JSON-RPC
    def handle(self, raw, key=None, bearer=None):
        """-> (http_code, json_obj|None). 202/None for notifications; JSON-RPC errors travel as HTTP 200 bodies."""
        try: msg = json.loads(raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else raw)
        except (ValueError, UnicodeDecodeError): return 200, self.err(None, -32700, "parse error")
        if isinstance(msg, list): return 200, self.err(None, -32600, "JSON-RPC batching is not supported (MCP 2025-06-18)")
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
            return 200, self.err(msg.get("id") if isinstance(msg, dict) else None, -32600, "invalid request")
        mid = msg.get("id"); method = msg["method"]; params = msg.get("params") or {}
        if mid is None:                                        # notification (initialized, cancelled, progress...)
            return 202, None
        if method == "initialize":
            want = params.get("protocolVersion") if isinstance(params, dict) else None
            return 200, self.ok(mid, {"protocolVersion": want if want in PROTOCOL_VERSIONS else DEFAULT_PROTOCOL,
                                      "capabilities": {"tools": {}},
                                      "serverInfo": {"name": SERVER_NAME, "title": SERVER_TITLE, "version": E.VERSION},
                                      "instructions": "Hosted GPU runs for MDEngine. Every tool except this handshake needs "
                                                      "`Authorization: Bearer mde_...` (API key from a credit pack at " + SIGNUP_URL + "). "
                                                      "Typical flow: account -> submit_job (inline deck) -> job_status/job_log until done -> job_results. "
                                                      "Free local CPU runs: install the mdengine-mcp bundle instead."})
        if method == "ping": return 200, self.ok(mid, {})
        if method == "tools/list": return 200, self.ok(mid, {"tools": TOOLS})
        if method == "tools/call":
            name = params.get("name") if isinstance(params, dict) else None
            args = params.get("arguments") if isinstance(params, dict) else None
            if not isinstance(args, dict): args = {}
            if name not in {t["name"] for t in TOOLS}: return 200, self.err(mid, -32602, "unknown tool %r" % name)
            if key is None:
                why = ("Invalid API key." if bearer else "No API key.") + \
                      " Send the header `Authorization: Bearer mde_...`. Keys come with a prepaid credit pack at " + SIGNUP_URL + \
                      "; local CPU runs are free through the mdengine-mcp bundle."
                return 200, self.ok(mid, self.tool_error(why))
            try: return 200, self.ok(mid, self.tool_ok(self.call(name, args, key)))
            except ToolError as e: return 200, self.ok(mid, self.tool_error(str(e)))
            except Exception as e:                            # never leak a traceback to the client
                E.log("mcp.tool_error", tool=name, key_id=key["key_id"], error=repr(e))
                return 200, self.ok(mid, self.tool_error("internal error running %s" % name))
        return 200, self.err(mid, -32601, "method not found: %s" % method)

    @staticmethod
    def ok(mid, result): return {"jsonrpc": "2.0", "id": mid, "result": result}
    @staticmethod
    def err(mid, code, message): return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}
    @staticmethod
    def tool_ok(obj): return {"content": [{"type": "text", "text": json.dumps(obj, indent=1)}], "structuredContent": obj, "isError": False}
    @staticmethod
    def tool_error(text): return {"content": [{"type": "text", "text": text}], "isError": True}

    # ------------------------------------------------------------------ tools
    def job_for(self, args, key):
        jid = args.get("id")
        if not isinstance(jid, str) or not jid: raise ToolError("id required")
        j = self.app.db.job(jid)
        if not j or j["key_id"] != key["key_id"]: raise ToolError("no job %s for this key" % jid)
        return j

    def unwrap(self, code, obj):
        if code >= 400: raise ToolError(obj.get("message") or obj.get("error") or ("HTTP %d" % code))
        return obj

    def call(self, name, args, key):
        app, db = self.app, self.app.db
        if name == "account":
            return {"balance_usd": db.balance(key["key_id"]), "rate_table": app.cfg.rates, "key_id": key["key_id"], "keys_created": key["created"],
                    "runners": "open" if app.cfg.runners_open else "closed"}
        if name == "list_jobs":
            try: limit = max(1, min(int(args.get("limit") or 50), 200))
            except (TypeError, ValueError): raise ToolError("limit must be an integer")
            rows = db.q("select * from jobs where key_id=? order by created desc, id desc limit ?", key["key_id"], limit)
            return {"jobs": [E.status(j) for j in rows]}
        if name == "job_status": return E.status(self.job_for(args, key))
        if name == "job_log":
            j = self.job_for(args, key); st = E.status(j)
            return {"id": j["id"], "state": st["state"], "thermo_tail": st["thermo_tail"], "exitcode": st["exitcode"], "error": st["error"]}
        if name == "job_results": return self.unwrap(*app.job_results(self.job_for(args, key)))
        if name == "cancel_job": return self.unwrap(*app.cancel_job(self.job_for(args, key)))
        if name == "start_job": return self.unwrap(*app.start_job(self.job_for(args, key)))
        if name == "create_job":
            spec = {k: v for k, v in args.items() if k in SPEC_PROPS}
            obj = self.unwrap(*app.create_job(key, spec))
            obj["next"] = "PUT the deck .tar.gz to upload_url (Content-Type application/gzip) before upload_expires, then call start_job"
            return obj
        if name == "submit_job":
            spec = {k: v for k, v in args.items() if k in SPEC_PROPS}
            tar = build_tarball(args.get("files"), spec.get("input"))          # validate the deck BEFORE creating anything
            created = self.unwrap(*app.create_job(key, spec)); jid = created["id"]
            name_ = f"{jid}.in.tar.gz"
            with open(app.blob_path(name_), "wb") as fh: fh.write(tar)
            db.set_job(jid, state="uploaded"); E.log("blob.put", job=jid, name=name_, bytes=len(tar), via="mcp")
            started = self.unwrap(*app.start_job(db.job(jid)))
            return {"id": jid, "state": started["state"], "deck_bytes": len(tar), "files": sorted(args["files"]), "gpu": created.get("gpu"),
                    "next": "poll job_status / job_log; job_results when state is done or failed"}
        raise ToolError("unknown tool")
