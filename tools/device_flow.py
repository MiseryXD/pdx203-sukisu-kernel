import json, time, urllib.request, urllib.parse, sys

CLIENT_ID = "178c6fc778ccc68e1d6a"   # GitHub CLI OAuth app (public client id)
SCOPE = "repo workflow read:org"

def post(url, data, headers=None):
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

d = post("https://github.com/login/device/code", {"client_id": CLIENT_ID, "scope": SCOPE})
print("CODE:", d["user_code"], flush=True)
print("URL:", d["verification_uri"], flush=True)
print("EXPIRES_IN:", d["expires_in"], flush=True)

interval = d.get("interval", 5)
deadline = time.time() + d["expires_in"]
while time.time() < deadline:
    time.sleep(interval)
    try:
        r = post("https://github.com/login/oauth/access_token", {
            "client_id": CLIENT_ID,
            "device_code": d["device_code"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        })
    except Exception as e:
        print("POLL_ERR", e, flush=True)
        continue
    err = r.get("error")
    if err == "authorization_pending":
        continue
    if err == "slow_down":
        interval += 5
        continue
    if err:
        print("ERROR:", err, r.get("error_description"), flush=True)
        sys.exit(1)
    tok = r.get("access_token")
    if tok:
        open(r"C:\Users\Blut233\ksu-cloud\.token", "w").write(tok)
        print("TOKEN_OK", flush=True)
        sys.exit(0)

print("EXPIRED", flush=True)
sys.exit(2)
