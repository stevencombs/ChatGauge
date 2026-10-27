#!/usr/bin/env python3
"""Tiny Ollama stand-in for scripts/ui-selftest.sh. Streams /api/chat like Ollama 0.40 (captured shape)."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "qwen2.5vl:7b"
loaded = []

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): sys.stderr.write("mock: " + (a[0] % a[1:]) + "\n")
    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
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
