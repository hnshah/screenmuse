#!/usr/bin/env python3
"""
ScreenMuse helper for OpenClaw skills.
Usage:
  python3 screenmuse_helper.py start <name>
  python3 screenmuse_helper.py stop
  python3 screenmuse_helper.py chapter <name>
  python3 screenmuse_helper.py highlight
  python3 screenmuse_helper.py status
  python3 screenmuse_helper.py is_running

Returns JSON on stdout.
"""
import sys
import json
import urllib.request
import urllib.error

BASE_URL = "http://localhost:7823"


def call(method: str, path: str, body: dict = None) -> dict:
    url = f"{BASE_URL}{path}"
    data = json.dumps(body).encode() if body else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except urllib.error.URLError as e:
        return {"error": str(e), "running": False}


def main():
    args = sys.argv[1:]
    if not args:
        print(json.dumps({"error": "no command"}))
        sys.exit(1)

    cmd = args[0]

    if cmd == "start":
        name = args[1] if len(args) > 1 else "recording"
        result = call("POST", "/start", {"name": name})
    elif cmd == "stop":
        result = call("POST", "/stop")
    elif cmd == "chapter":
        name = args[1] if len(args) > 1 else "Chapter"
        result = call("POST", "/chapter", {"name": name})
    elif cmd == "highlight":
        result = call("POST", "/highlight")
    elif cmd == "status":
        result = call("GET", "/status")
    elif cmd == "is_running":
        status = call("GET", "/status")
        result = {"running": status.get("recording", False)}
    else:
        result = {"error": f"unknown command: {cmd}"}

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
