#!/usr/bin/env python3
"""RunPod pod launcher for the MDEngine hosted endpoint (hosted/CONTRACT.md "Pod lifecycle"). Stdlib only.

One pod per job. The pod is the runner image with MDE_ENDPOINT / MDE_JOB_ID / MDE_JOB_TOKEN in its env;
docker/runner-gpu/start.sh execs runner.sh when MDE_JOB_ID is set. The endpoint deletes the pod at every
terminal job state and the reaper (mde_endpoint.App.reaper_once) clears anything that slipped through.

RunPod REST v2 (https://api.runpod.io/v2/openapi.json):
  POST   /v2/pods        201 Pod            create; any other status = this ladder rung failed
  GET    /v2/pods/{id}   200 Pod            status in PROVISIONING STARTING RUNNING EXITED ERROR TERMINATED
  DELETE /v2/pods/{id}   204 (404 = gone)   idempotent
  GET    /v2/pods        200 {"pods":[Pod]} (live) | {"items":[Pod]} (docs) | bare list

Logging discipline: the API key is only ever a header; request bodies (they carry the job token) are never
logged; Pod objects returned by RunPod carry the pod env (job token) and are never logged either -- only
error bodies, truncated to LOG_BODY_MAX.
"""
import json, threading, time, urllib.error, urllib.request
from datetime import datetime, timezone

RUNPOD_BASE = "https://api.runpod.io"
DEFAULT_IMAGE = "ghcr.io/forcefieldsilicon/mdengine-runner-gpu:ADA89"
DEFAULT_LADDER = [("COMMUNITY", "NVIDIA GeForce RTX 4090"), ("SECURE", "NVIDIA GeForce RTX 4090")]
CLOUDS = ("COMMUNITY", "SECURE")
HTTP_TIMEOUT_S = 30
LOG_BODY_MAX = 300
POD_NAME_PREFIX = "mde-"

class LauncherError(Exception):
    """Transport or protocol failure talking to RunPod (never carries the API key or a token)."""

class NoCapacity(LauncherError):
    """Every rung of the fallback ladder refused to create a pod."""

def log(ev, **kw):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ev": ev}; rec.update(kw)
    print(json.dumps(rec, separators=(",", ":"), default=str), flush=True)

def trunc(s, n=LOG_BODY_MAX):
    s = s if isinstance(s, str) else str(s)
    return s if len(s) <= n else s[:n] + "...(%d more)" % (len(s) - n)

def parse_ladder(s):
    """MDE_GPU_LADDER="COMMUNITY:NVIDIA GeForce RTX 4090,SECURE:NVIDIA GeForce RTX 4090" -> [(cloud, gpu_id)]."""
    if not (s or "").strip(): return list(DEFAULT_LADDER)
    out = []
    for item in s.split(","):
        item = item.strip()
        if not item: continue
        if ":" not in item: raise ValueError("MDE_GPU_LADDER entry needs CLOUD:gpu id, got %r" % item)
        cloud, gid = item.split(":", 1); cloud = cloud.strip().upper(); gid = gid.strip()
        if cloud not in CLOUDS or not gid: raise ValueError("bad MDE_GPU_LADDER entry %r" % item)
        out.append((cloud, gid))
    if not out: raise ValueError("MDE_GPU_LADDER is empty")
    return out

def parse_iso(s):
    """RunPod createdAt ('2026-09-06T12:34:56.789Z' or with an offset) -> unix seconds, or None."""
    if not s: return None
    try:
        if s.endswith("Z"): s = s[:-1] + "+00:00"
        d = datetime.fromisoformat(s)
        if d.tzinfo is None: d = d.replace(tzinfo=timezone.utc)
        return d.timestamp()
    except ValueError: return None

def pod_age_s(pod, now_ts=None):
    t = parse_iso((pod or {}).get("createdAt")); return None if t is None else max(0.0, (now_ts or time.time()) - t)

def iso_now(ts=None): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))

# ----------------------------------------------------------------------------- RunPod

class RunPodLauncher:
    kind = "runpod"
    def __init__(self, cfg, public_url=None):
        self.api_key = cfg.runpod_api_key
        if not self.api_key: raise ValueError("RUNPOD_API_KEY is empty")
        self.image = getattr(cfg, "runner_image", "") or DEFAULT_IMAGE
        self.disk_gb = int(getattr(cfg, "pod_disk_gb", 20) or 20)
        self.min_cuda = getattr(cfg, "min_cuda", "") or "12.4"
        self.ladder = list(getattr(cfg, "gpu_ladder", None) or DEFAULT_LADDER)
        self.public_url = (public_url or cfg.public_url or "").rstrip("/")
        self.base = getattr(cfg, "runpod_base", "") or RUNPOD_BASE
        self.timeout = HTTP_TIMEOUT_S
        self.backoff_s = 1.0                       # delete() retry base; tests set 0
        self._lock = threading.Lock()              # serialises pod creation (one launch thread at a time is plenty)

    # -- transport (split so tests can monkeypatch either layer) ------------------------------------
    def _open(self, req):
        """urlopen -> (status, text). HTTP errors are returned, not raised; transport errors raise LauncherError."""
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r: return r.status, r.read().decode(errors="replace")
        except urllib.error.HTTPError as e:
            with e: return e.code, e.read().decode(errors="replace")
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise LauncherError("runpod transport: %s" % trunc(repr(e), 120)) from None

    def _request(self, method, path, body=None):
        """(status, text) for METHOD {base}{path}. Authorization is set here and nowhere else."""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Authorization": "Bearer " + self.api_key, "Accept": "application/json",
                                              "User-Agent": "mde-endpoint-launcher"})
        if data is not None: req.add_header("Content-Type", "application/json")
        return self._open(req)

    # -- interface ---------------------------------------------------------------------------------
    def pod_body(self, job_id, token, cloud, gpu_id):
        return {"name": POD_NAME_PREFIX + job_id, "image": self.image, "cloud": cloud,
                "gpu": {"id": gpu_id, "count": 1, "minCudaVersion": self.min_cuda}, "disk": self.disk_gb,
                "env": {"MDE_ENDPOINT": self.public_url, "MDE_JOB_ID": job_id, "MDE_JOB_TOKEN": token,
                        "MDE_WALL_LIMIT_S": str(int(wall_limit_s))}}   # pod-side TTL (start.sh): wall + 600 s

    def create(self, job_id, token, wall_limit_s, gpu):
        """Walk the ladder until one POST /v2/pods returns 201; return the pod id. Raises NoCapacity."""
        with self._lock:
            for rung, (cloud, gpu_id) in enumerate(self.ladder, 1):
                try: code, text = self._request("POST", "/v2/pods", self.pod_body(job_id, token, cloud, gpu_id))
                except LauncherError as e: code, text = 0, str(e)
                pod_id = None
                if code == 201:                                       # a Pod body: carries env, so never logged
                    try: pod_id = json.loads(text).get("id")
                    except (ValueError, AttributeError): pod_id = None
                    text = "<201 without pod id>"
                log("launch.attempt", job=job_id, rung=rung, cloud=cloud, gpu_id=gpu_id, gpu=gpu, wall_limit_s=wall_limit_s,
                    code=code, ok=bool(pod_id), **({} if pod_id else {"body": trunc(text)}))
                if pod_id: return pod_id
            raise NoCapacity("no rung of %d accepted job %s" % (len(self.ladder), job_id))

    def delete(self, pod_id, retries=3):
        """DELETE /v2/pods/{id}; 204 and 404 are success. 429/5xx/transport errors retry with backoff."""
        last = None
        for i in range(retries):
            try: code, text = self._request("DELETE", "/v2/pods/" + pod_id)
            except LauncherError as e: code, text = 0, str(e)
            if code in (200, 202, 204, 404): return True
            last = "%d %s" % (code, trunc(text))
            if code and code != 429 and code < 500: break            # other 4xx: not retryable
            if i + 1 < retries: time.sleep(self.backoff_s * (2 ** i))
        raise LauncherError("delete %s failed: %s" % (pod_id, last))

    def get(self, pod_id):
        code, text = self._request("GET", "/v2/pods/" + pod_id)
        if code == 404: return None
        if code != 200: raise LauncherError("get %s: %d %s" % (pod_id, code, trunc(text)))
        return json.loads(text)

    def list_pods(self):
        code, text = self._request("GET", "/v2/pods")
        if code != 200: raise LauncherError("list pods: %d %s" % (code, trunc(text)))
        data = json.loads(text)
        # live API (2026-09) wraps as {"pods":[...]}; OpenAPI example says {"items":[...]}; older: bare list
        items = (data.get("pods") or data.get("items")) if isinstance(data, dict) else data
        return list(items or [])

# ----------------------------------------------------------------------------- fake (tests / dry runs)

class FakeLauncher:
    """Same interface, in memory. `fail_create=True` raises NoCapacity; pod ids in `fail_delete` refuse deletion."""
    kind = "fake"
    def __init__(self, public_url=""):
        self.public_url = public_url; self.pods = {}; self.deleted = []; self.calls = []
        self.fail_create = False; self.fail_delete = set(); self._n = 0; self._lock = threading.Lock()

    def add_pod(self, name, created_at=None, pod_id=None, env=None):
        with self._lock:
            self._n += 1; pid = pod_id or "fakepod%d" % self._n
            self.pods[pid] = {"id": pid, "name": name, "status": "RUNNING", "cloud": "COMMUNITY",
                              "createdAt": created_at or iso_now(), "env": dict(env or {})}
            return pid

    def create(self, job_id, token, wall_limit_s, gpu):
        self.calls.append(("create", job_id))
        log("launch.attempt", job=job_id, rung=1, cloud="FAKE", gpu_id="fake", gpu=gpu, wall_limit_s=wall_limit_s, ok=not self.fail_create)
        if self.fail_create: raise NoCapacity("fake: no capacity")
        return self.add_pod(POD_NAME_PREFIX + job_id, env={"MDE_ENDPOINT": self.public_url, "MDE_JOB_ID": job_id, "MDE_JOB_TOKEN": token})

    def delete(self, pod_id):
        self.calls.append(("delete", pod_id))
        if pod_id in self.fail_delete: raise LauncherError("fake: delete refused for %s" % pod_id)
        with self._lock: self.pods.pop(pod_id, None); self.deleted.append(pod_id)
        return True

    def get(self, pod_id): return self.pods.get(pod_id)
    def list_pods(self): return [dict(p) for p in self.pods.values()]
