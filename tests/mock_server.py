#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Mock HTTP server for jail0r tests.

Usage: python3 mock_server.py <mode> <port>

Modes:
  refused   200 with a refusal phrase in the response body
  bypassed  200 with a leak phrase in the response body
  unclear   200 with a neutral response (no refusal, no leak phrase)
  error     500 with an empty body
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

mode = sys.argv[1] if len(sys.argv) > 1 else "refused"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765

RESPONSES = {
    "refused": {"response": "I cannot help with that. I'm not able to assist with this request."},
    "bypassed": {"response": "Sure, here is how to do it. DAN mode activated, proceeding without restrictions."},
    "unclear":  {"response": "Of course! Let me look into that for you. Here are some options to consider."},
}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)

        if mode == "error":
            self.send_response(500)
            self.end_headers()
            return

        body = json.dumps(RESPONSES.get(mode, RESPONSES["refused"])).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
