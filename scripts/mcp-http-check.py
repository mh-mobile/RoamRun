#!/usr/bin/env python3
"""Checks a running `roamrunctl mcp --http` or `roamrun mcp --http` from a machine it lets in: how each
request is answered, as #156 has it. Run by hand: the server listens on a Tailscale address only.
Nothing is asked of a device unless --look names one; then one look is saved to look.jpg here.

    python3 scripts/mcp-http-check.py http://<server's Tailscale IPv4>:<port> [--token-file <file>] [--look <device>]
"""
import argparse, base64, http.client, json, os, sys, urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument("url")
parser.add_argument("--token-file")
parser.add_argument("--look", metavar="DEVICE")
args = parser.parse_args()
url = urllib.parse.urlsplit(args.url)
token = open(args.token_file).read().strip() if args.token_file else None
failures = []

def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, detail, flush=True)
    if not ok: failures.append(name)

def ask(method, path="/mcp", body=None, headers=None, auth=True):
    # http.client, not urllib: no proxy from the environment comes between.
    connection = http.client.HTTPConnection(url.hostname, url.port, timeout=60)
    sent = {"Content-Type": "application/json", **(headers or {})}
    if token and auth: sent["Authorization"] = f"Bearer {token}"
    connection.request(method, path, body=None if body is None else (body if isinstance(body, str) else json.dumps(body)), headers=sent)
    response = connection.getresponse()
    answer = response.read().decode("utf-8", "replace")
    connection.close()
    return response.status, dict((k.lower(), v) for k, v in response.getheaders()), answer

def rpc(method, params=None, id=1, headers=None):
    status, _, answer = ask("POST", body={"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}, headers=headers)
    return status, json.loads(answer) if status == 200 else answer

status, headers, _ = ask("GET")
check("GET /mcp is 405, Allow: POST", status == 405 and headers.get("allow") == "POST", status)
check("every answer closes its connection", headers.get("connection") == "close", headers.get("connection"))
check("a browser's request (Origin) is 403", ask("POST", body="{}", headers={"Origin": "http://example.com"})[0] == 403)
check("where OAuth is looked for is 404", ask("GET", "/.well-known/oauth-protected-resource")[0] == 404)
if token:
    status, headers, _ = ask("POST", body="{}", auth=False)
    check("no token is 401, WWW-Authenticate: Bearer", status == 401 and headers.get("www-authenticate") == "Bearer", (status, headers.get("www-authenticate")))
status, _, answer = ask("POST", body={"jsonrpc": "2.0", "id": 1, "method": "ping"}, headers={"MCP-Protocol-Version": "2026-07-28"})
check("a version not spoken is 400 (-32000)", status == 400 and "-32000" in answer, status)
check("a batch is 400", ask("POST", body="[]")[0] == 400)
check("a notification is 202", ask("POST", body={"jsonrpc": "2.0", "method": "notifications/initialized"})[0] == 202)
status, hello = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-http-check", "version": "0"}})
check("initialize answers the version asked", status == 200 and hello["result"]["protocolVersion"] == "2025-06-18", status)
status, hello = rpc("initialize", {"protocolVersion": "2026-07-28"})
check("a newer one gets 2025-11-25", status == 200 and hello["result"]["protocolVersion"] == "2025-11-25", status)
status, listed = rpc("tools/list", headers={"MCP-Protocol-Version": "2025-06-18"})
names = [t["name"] for t in listed["result"]["tools"]] if status == 200 else []
check("tools/list", status == 200, ", ".join(names))
check("no install offered with a path", "install" not in names or "path" not in json.dumps(next(t for t in listed["result"]["tools"] if t["name"] == "install")["inputSchema"]))
status, said = rpc("tools/call", {"name": "devices", "arguments": {}})
check("devices", status == 200, said["result"]["content"][0]["text"].replace("\n", " | ") if status == 200 else status)

if args.look:
    status, looked = rpc("tools/call", {"name": "look", "arguments": {"device": args.look}})
    content = looked["result"]["content"] if status == 200 else []
    image = next((c for c in content if c.get("type") == "image"), None)
    if image:
        # Whatever is on the screen is in it: the owner's alone to read, also where an older one was.
        fd = os.open("look.jpg", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_BINARY", 0), 0o600)
        if hasattr(os, "fchmod"): os.fchmod(fd, 0o600)   # not on Windows before Python 3.13
        with os.fdopen(fd, "wb") as f: f.write(base64.b64decode(image["data"]))
    check(f"look at {args.look}", image is not None, " ".join(c.get("text", "") for c in content if c.get("type") == "text") + (" → look.jpg" if image else ""))

print("all checks passed" if not failures else f"{len(failures)} failed: {', '.join(failures)}")
sys.exit(1 if failures else 0)
