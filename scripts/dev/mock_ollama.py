#!/usr/bin/env python3
"""Tiny Ollama stand-in for scripts/ui-selftest.sh. Streams /api/chat like Ollama 0.40 (captured shape)."""
import hashlib, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "qwen2.5vl:7b"
loaded = []
# A fake whisper ggml file for the setup self-test (served under /whisper/, with Hugging Face's X-Linked-Etag hash).
WHISPER = bytes((i * 7 + 3) % 251 for i in range(96_000))
WHISPER_SHA = hashlib.sha256(WHISPER).hexdigest()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): sys.stderr.write("mock: " + (a[0] % a[1:]) + "\n")
    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _whisper_head(self):
        self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(WHISPER))); self.send_header("X-Linked-Etag", '"%s"' % WHISPER_SHA)
        self.send_header("X-Linked-Size", str(len(WHISPER))); self.end_headers()
    def do_HEAD(self):
        if self.path.startswith("/whisper/"): return self._whisper_head()
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        if self.path.startswith("/whisper/"):
            self._whisper_head()
            try:
                for i in range(0, len(WHISPER), 8000):
                    self.wfile.write(WHISPER[i:i + 8000]); self.wfile.flush(); time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path == "/api/version": return self._json({"version": "0.40.11"})
        if self.path == "/api/tags": return self._json({"models": [{"name": MODEL, "model": MODEL, "size": 6000000000,
            "details": {"family": "qwen25vl", "parameter_size": "8.3B"}, "capabilities": ["completion", "vision"]}]})
        if self.path == "/api/ps": return self._json({"models": [{"name": m, "model": m, "size": 6000000000, "size_vram": 6000000000} for m in loaded]})
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/api/generate":
            time.sleep(1.0)
            if MODEL not in loaded: loaded.append(MODEL)
            return self._json({"model": MODEL, "response": "", "done": True})
        if self.path == "/api/pull":
            # Streams progress like Ollama, then writes a manifest into OLLAMA_MODELS (the setup self-test's folder).
            name, _, tag = body.get("model", "x").partition(":")
            self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            def pl(o):
                b = (json.dumps(o) + "\n").encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b)); self.wfile.flush()
            try:
                pl({"status": "pulling manifest"})
                total = 3_000_000_000
                for i in range(1, 26):
                    time.sleep(0.12)
                    pl({"status": "pulling 5a3c1e", "digest": "sha256:5a3c1e", "total": total, "completed": total * i // 25})
                pl({"status": "verifying sha256 digest"}); pl({"status": "writing manifest"})
                root = os.environ.get("OLLAMA_MODELS")
                if root:
                    d = os.path.join(root, "manifests", "registry.ollama.ai", "library", name)
                    os.makedirs(d, exist_ok=True)
                    open(os.path.join(d, tag or "latest"), "w").write("{}")
                pl({"status": "success"})
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path == "/api/chat" and body.get("stream") is False:
            if any("Say OK" in m.get("content", "") for m in body.get("messages", [])):
                return self._json({"model": body.get("model", MODEL), "message": {"role": "assistant", "content": "OK"}, "done": True})
            # A title request (non-streaming), answered the way small models often do: quoted, with a period.
            return self._json({"model": MODEL, "message": {"role": "assistant", "content": "\"Status Check.\""}, "done": True})
        if self.path == "/api/chat":
            self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            def line(o):
                b = (json.dumps(o) + "\n").encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b)); self.wfile.flush()
            time.sleep(1.5)  # a slow first token, so the "Thinking…" row is on screen for the 2-pending snapshot
            for w in ["Yes", ",", " I'm", " working", "!"]:
                line({"model": MODEL, "message": {"role": "assistant", "content": w}, "done": False}); time.sleep(0.03)
            line({"model": MODEL, "message": {"role": "assistant", "content": ""}, "done": True, "done_reason": "stop",
                  "eval_count": 5, "eval_duration": 80000000})
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush(); return
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
