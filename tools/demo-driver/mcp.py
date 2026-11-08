#!/usr/bin/env python3
"""Calls Native Screen MCP tools from the command line.

    mcp.py '{"tool": "get_project", "args": {...}}'
    mcp.py '[{"tool": ...}, {"tool": ...}]'      # several calls in one session, stops at the first error

The app is NATIVE_SCREEN_APP (default /Applications/Native Screen.app). AI Agents must be on in Settings.
Long results are cut to MAXOUT characters (default 4000).
"""
import json, os, subprocess, sys

app = os.environ.get("NATIVE_SCREEN_APP", "/Applications/Native Screen.app")
maxout = int(os.environ.get("MAXOUT", "4000"))
p = subprocess.Popen([os.path.join(app, "Contents/MacOS/Native Screen"), "--mcp"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

def send(o):
    p.stdin.write(json.dumps(o) + "\n")
    p.stdin.flush()

def recv(want):
    while True:
        line = p.stdout.readline()
        if not line:
            sys.exit("MCP server closed")
        m = json.loads(line)
        if m.get("id") == want:
            return m

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "demo-driver", "version": "1"}}})
recv(1)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

calls = json.loads(sys.argv[1]) if len(sys.argv) > 1 else []
if isinstance(calls, dict):
    calls = [calls]
for i, c in enumerate(calls, start=2):
    send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": c["tool"], "arguments": c.get("args", {})}})
    res = recv(i).get("result", {})
    for item in res.get("content", []):
        if item.get("type") == "text":
            t = item["text"]
            print(t if len(t) <= maxout else t[:maxout] + "...")
        elif item.get("type") == "image":
            print("[image]")
    if res.get("isError"):
        print("ERROR")
        break
p.stdin.close()
