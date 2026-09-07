#!/usr/bin/env python3
"""OAuth 2.1 authorization server for the hosted MCP remote (Anthropic directory policy 5D).

The account model does not change: an API key (mde_...) IS the account. OAuth is a wrapper that lets an
MCP client (Claude.ai, Claude Desktop, Claude Code, ...) obtain tokens for a key without the user ever
pasting the key into the client:

  client -> GET  /.well-known/oauth-protected-resource       who protects /mcp, where the AS is
         -> GET  /.well-known/oauth-authorization-server     endpoints + PKCE S256 + DCR + CIMD
         -> POST /oauth/register                             RFC 7591 dynamic client registration (public client)
         -> GET  /oauth/authorize?...code_challenge...        consent page: user pastes their API key once
         -> POST /oauth/authorize                            key checked -> single-use code bound to PKCE, client, redirect
         -> POST /oauth/token                                code + code_verifier -> access token (24 h) + rotating refresh token (90 d)
         -> tools/call with Authorization: Bearer mat_...    resolved to the key that consented

Clients are public (token_endpoint_auth_method "none"); PKCE S256 is mandatory; codes are single use and
expire in 10 minutes; refresh tokens rotate (the old one dies when the new one is issued). Client identity
comes from DCR (client_id "dc_...") or from a Client ID Metadata Document (client_id is an https URL whose
JSON lists redirect_uris -- Claude Code uses this). Loopback redirect URIs match with the port ignored
(RFC 8252 7.3). Every code and token is stored as a sha256 hash; the raw API key is never stored.
Stdlib only. Tests monkeypatch `fetch_client_metadata`.
"""
import hashlib, hmac, json, secrets, time, urllib.parse, urllib.request
from urllib.parse import urlparse, parse_qs

import mde_endpoint as E          # resolved at call time; mde_endpoint imports this module

CODE_TTL_S = 600
ACCESS_TTL_S = 86400
REFRESH_TTL_S = 90 * 86400
SCOPE = "jobs"
LOOPBACK = ("localhost", "127.0.0.1", "::1")
CIMD_TTL_S = 3600
MAX_META_BYTES = 65536

def s256(s): return hashlib.sha256(s.encode() if isinstance(s, str) else s).hexdigest()
def b64url_sha256(verifier):
    import base64
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()

def fetch_client_metadata(url):
    """GET a Client ID Metadata Document. Module-level so tests can monkeypatch it."""
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "mde-endpoint/" + E.VERSION})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read(MAX_META_BYTES + 1)[:MAX_META_BYTES].decode())

def redirect_uri_allowed(uri):
    """Registration-time rule: https anywhere, or http on a loopback host (native clients)."""
    try: u = urlparse(uri)
    except ValueError: return False
    if not u.netloc or u.fragment: return False
    if u.scheme == "https": return True
    return u.scheme == "http" and u.hostname in LOOPBACK

def redirect_matches(registered, requested):
    """Exact match, except loopback hosts ignore the port (RFC 8252 section 7.3; Claude Code picks a port per session)."""
    try: r, q = urlparse(registered), urlparse(requested)
    except ValueError: return False
    if (r.scheme, r.path, r.query) != (q.scheme, q.path, q.query): return False
    if r.hostname in LOOPBACK and q.hostname in LOOPBACK: return r.hostname == q.hostname
    return r.netloc == q.netloc

class OAuthError(Exception):
    def __init__(self, error, description="", status=400):
        super().__init__(description or error); self.error, self.description, self.status = error, description, status

class OAuth:
    def __init__(self, app):
        self.app = app
        self._cimd = {}                      # url -> (fetched_at, metadata)

    # ------------------------------------------------------------------ discovery
    @property
    def issuer(self): return self.app.public_url
    @property
    def resource(self): return self.app.public_url + "/mcp"

    def protected_resource_metadata(self):
        return {"resource": self.resource, "authorization_servers": [self.issuer], "bearer_methods_supported": ["header"],
                "scopes_supported": [SCOPE], "resource_name": "MDEngine hosted GPU",
                "resource_documentation": "https://github.com/forcefieldsilicon/mdengine#mcp-server"}

    def server_metadata(self):
        return {"issuer": self.issuer, "authorization_endpoint": self.issuer + "/oauth/authorize", "token_endpoint": self.issuer + "/oauth/token",
                "registration_endpoint": self.issuer + "/oauth/register", "response_types_supported": ["code"],
                "response_modes_supported": ["query"], "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"],
                "client_id_metadata_document_supported": True, "scopes_supported": [SCOPE],
                "service_documentation": "https://github.com/forcefieldsilicon/mdengine#mcp-server"}

    def www_authenticate(self, invalid=False):
        v = 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource"' % self.issuer
        if invalid: v += ', error="invalid_token", error_description="expired or unknown token"'
        return v

    # ------------------------------------------------------------------ clients
    def register(self, body):
        """RFC 7591. Public clients only; we issue no secret."""
        if not isinstance(body, dict): raise OAuthError("invalid_client_metadata", "JSON object expected")
        uris = body.get("redirect_uris")
        if not isinstance(uris, list) or not uris or not all(isinstance(u, str) and redirect_uri_allowed(u) for u in uris):
            raise OAuthError("invalid_redirect_uri", "redirect_uris must be https URLs or http loopback URLs")
        if body.get("token_endpoint_auth_method", "none") != "none":
            raise OAuthError("invalid_client_metadata", "only public clients (token_endpoint_auth_method=none) are supported")
        grants = body.get("grant_types") or ["authorization_code", "refresh_token"]
        if not set(grants) <= {"authorization_code", "refresh_token"}: raise OAuthError("invalid_client_metadata", "unsupported grant_types")
        cid = "dc_" + secrets.token_hex(16); created = int(time.time())
        meta = {"client_id": cid, "client_id_issued_at": created, "redirect_uris": uris, "token_endpoint_auth_method": "none",
                "grant_types": grants, "response_types": ["code"], "client_name": str(body.get("client_name") or "")[:120],
                "client_uri": str(body.get("client_uri") or "")[:300], "scope": SCOPE}
        self.app.db.x("insert into oauth_clients(client_id,metadata,created) values(?,?,?)", cid, json.dumps(meta), E.now())
        E.log("oauth.register", client_id=cid, name=meta["client_name"], redirects=len(uris))
        return meta

    def client(self, client_id):
        """DCR client from the DB, or a CIMD client fetched from its https client_id URL (cached)."""
        if not client_id: raise OAuthError("invalid_client", "client_id required", 401)
        if client_id.startswith("dc_"):
            r = self.app.db.one("select metadata from oauth_clients where client_id=?", client_id)
            if not r: raise OAuthError("invalid_client", "unknown client_id", 401)
            return json.loads(r["metadata"])
        u = urlparse(client_id)
        if u.scheme != "https" or not u.netloc or u.path in ("", "/"): raise OAuthError("invalid_client", "client_id must be a DCR id or an https metadata URL", 401)
        hit = self._cimd.get(client_id)
        if hit and time.time() - hit[0] < CIMD_TTL_S: return hit[1]
        try: meta = fetch_client_metadata(client_id)
        except Exception as e:
            E.log("oauth.cimd_fetch_failed", client_id=client_id, error=repr(e)); raise OAuthError("invalid_client", "could not fetch client metadata", 401)
        if not isinstance(meta, dict) or meta.get("client_id") != client_id: raise OAuthError("invalid_client", "metadata client_id mismatch", 401)
        uris = meta.get("redirect_uris")
        if not isinstance(uris, list) or not uris or not all(isinstance(x, str) and redirect_uri_allowed(x) for x in uris):
            raise OAuthError("invalid_client", "metadata has no acceptable redirect_uris", 401)
        meta.setdefault("client_name", u.netloc); meta["token_endpoint_auth_method"] = "none"
        self._cimd[client_id] = (time.time(), meta)
        if len(self._cimd) > 500: self._cimd = {k: v for k, v in self._cimd.items() if time.time() - v[0] < CIMD_TTL_S}
        return meta

    # ------------------------------------------------------------------ authorize
    def check_authorize_request(self, q):
        """Validate everything that must be right BEFORE we may redirect anywhere. Returns (client_meta, params)."""
        p = {k: (q.get(k) or [""])[0] if isinstance(q.get(k), list) else (q.get(k) or "") for k in
             ("response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource")}
        meta = self.client(p["client_id"])
        if not p["redirect_uri"] or not any(redirect_matches(r, p["redirect_uri"]) for r in meta["redirect_uris"]):
            raise OAuthError("invalid_request", "redirect_uri is not registered for this client")
        return meta, p

    def authorize_errors(self, p):
        """Errors that are safe to report by redirect (client + redirect already validated)."""
        if p["response_type"] != "code": return "unsupported_response_type", "response_type must be code"
        if not p["code_challenge"] or p["code_challenge_method"] != "S256": return "invalid_request", "PKCE with code_challenge_method=S256 is required"
        if len(p["code_challenge"]) < 43 or len(p["code_challenge"]) > 128: return "invalid_request", "bad code_challenge"
        if p["resource"] and p["resource"].rstrip("/") != self.resource: return "invalid_target", "resource must be " + self.resource
        if p["scope"] and not set(p["scope"].split()) <= {SCOPE}: return "invalid_scope", "supported scope: " + SCOPE
        return None

    def consent_page(self, meta, p, error=None):
        host = urlparse(p["redirect_uri"]).hostname or "?"
        warn = ('<p class=warn>The client redirects to <b>%s</b> on this computer (a native app). Continue only if you started this from an app you trust.</p>' % E.esc(host)
                if host in LOOPBACK else '<p class=muted>After you approve, you return to <b>%s</b>.</p>' % E.esc(host))
        hidden = "".join('<input type=hidden name="%s" value="%s">' % (k, E.esc(v)) for k, v in p.items() if v)
        err = '<p class=warn><b>%s</b></p>' % E.esc(error) if error else ""
        return ('<h1>Connect %s to MDEngine</h1>%s<div class=card><p><b>%s</b> asks to run jobs and read results with your MDEngine account.</p>%s'
                '<form method=post action="/oauth/authorize">%s<label>Your API key (<code>mde_…</code>, from your credit pack)<br>'
                '<input type=password name=api_key autocomplete=off required style="width:100%%;font-family:monospace"></label>'
                '<p><button type=submit>Approve</button></p></form>'
                '<p class=muted>The key stays with us: the app receives a token it can use until you revoke it. No key yet? '
                '<a href="https://forcefieldsilicon.com/mdengine">Get one</a>.</p></div>'
                % (E.esc(meta.get("client_name") or "an app"), err, E.esc(meta.get("client_name") or "This app"), warn, hidden))

    def issue_code(self, meta, p, api_key):
        k = self.app.db.key_by_hash(s256(api_key)) if api_key.startswith("mde_") else None
        if not k: return None
        code = "ac_" + secrets.token_hex(24)
        self.app.db.x("insert into oauth_codes(code_hash,client_id,redirect_uri,code_challenge,key_id,scope,expires,used) values(?,?,?,?,?,?,?,0)",
                      s256(code), meta["client_id"], p["redirect_uri"], p["code_challenge"], k["key_id"], p["scope"] or SCOPE, int(time.time()) + CODE_TTL_S)
        E.log("oauth.authorize", client_id=meta["client_id"], key_id=k["key_id"])
        return code

    @staticmethod
    def redirect_with(uri, **params):
        u = urlparse(uri); q = dict(urllib.parse.parse_qsl(u.query)); q.update({k: v for k, v in params.items() if v is not None and v != ""})
        return u._replace(query=urllib.parse.urlencode(q)).geturl()

    # ------------------------------------------------------------------ token
    def token(self, form):
        grant = form.get("grant_type")
        if grant == "authorization_code": return self._exchange_code(form)
        if grant == "refresh_token": return self._refresh(form)
        raise OAuthError("unsupported_grant_type", "authorization_code or refresh_token")

    def _exchange_code(self, form):
        code, verifier, client_id, redirect = form.get("code", ""), form.get("code_verifier", ""), form.get("client_id", ""), form.get("redirect_uri", "")
        if not code or not verifier or not client_id: raise OAuthError("invalid_request", "code, code_verifier and client_id are required")
        row = self.app.db.one("select * from oauth_codes where code_hash=?", s256(code))
        if not row: raise OAuthError("invalid_grant", "unknown code")
        if row["used"] or row["expires"] < time.time(): raise OAuthError("invalid_grant", "code used or expired")
        if row["client_id"] != client_id: raise OAuthError("invalid_grant", "code was issued to another client")
        if redirect and redirect != row["redirect_uri"]: raise OAuthError("invalid_grant", "redirect_uri mismatch")
        if not (43 <= len(verifier) <= 128) or not hmac.compare_digest(b64url_sha256(verifier), row["code_challenge"]): raise OAuthError("invalid_grant", "PKCE verification failed")
        self.app.db.x("update oauth_codes set used=1 where code_hash=?", row["code_hash"])
        if not self.app.db.key_by_id(row["key_id"]): raise OAuthError("invalid_grant", "account no longer exists")
        return self._mint(row["key_id"], client_id, row["scope"], "code")

    def _refresh(self, form):
        rt, client_id = form.get("refresh_token", ""), form.get("client_id", "")
        row = self.app.db.one("select * from oauth_tokens where token_hash=? and kind='refresh'", s256(rt)) if rt else None
        if not row or row["revoked"] or row["expires"] < time.time(): raise OAuthError("invalid_grant", "refresh token invalid, expired or revoked")
        if client_id and row["client_id"] != client_id: raise OAuthError("invalid_grant", "refresh token belongs to another client")
        if not self.app.db.key_by_id(row["key_id"]): raise OAuthError("invalid_grant", "account no longer exists")
        with self.app.db.lock:                                # rotate: the presented refresh token dies with this exchange
            self.app.db.x("update oauth_tokens set revoked=1 where token_hash=? or (kind='access' and parent_hash=?)", row["token_hash"], row["token_hash"])
        return self._mint(row["key_id"], row["client_id"], row["scope"], "refresh")

    def _mint(self, key_id, client_id, scope, via):
        now = int(time.time()); at = "mat_" + secrets.token_hex(24); rt = "mrt_" + secrets.token_hex(24)
        with self.app.db.lock:
            self.app.db.x("insert into oauth_tokens(token_hash,kind,key_id,client_id,scope,expires,created,revoked,parent_hash) values(?,?,?,?,?,?,?,0,NULL)",
                          s256(rt), "refresh", key_id, client_id, scope, now + REFRESH_TTL_S, E.now())
            self.app.db.x("insert into oauth_tokens(token_hash,kind,key_id,client_id,scope,expires,created,revoked,parent_hash) values(?,?,?,?,?,?,?,0,?)",
                          s256(at), "access", key_id, client_id, scope, now + ACCESS_TTL_S, E.now(), s256(rt))
        E.log("oauth.token", key_id=key_id, client_id=client_id, via=via)
        return {"access_token": at, "token_type": "Bearer", "expires_in": ACCESS_TTL_S, "refresh_token": rt, "scope": scope}

    # ------------------------------------------------------------------ resource side
    def key_for_access_token(self, token):
        """Bearer mat_... -> keys row (or None). Used by Handler.api_key for /mcp and /v1/*."""
        if not token or not token.startswith("mat_"): return None
        row = self.app.db.one("select * from oauth_tokens where token_hash=? and kind='access'", s256(token))
        if not row or row["revoked"] or row["expires"] < time.time(): return None
        return self.app.db.key_by_id(row["key_id"])

    def revoke_key(self, key_id):
        """Called by `mde-admin key revoke`: every token and pending code of the key dies with it."""
        self.app.db.x("update oauth_tokens set revoked=1 where key_id=?", key_id)
        self.app.db.x("delete from oauth_codes where key_id=?", key_id)

    def purge_expired(self):
        cutoff = int(time.time()) - 86400
        self.app.db.x("delete from oauth_codes where expires < ?", cutoff)
        self.app.db.x("delete from oauth_tokens where expires < ? or (revoked=1 and expires < ?)", cutoff, int(time.time()) + REFRESH_TTL_S)
