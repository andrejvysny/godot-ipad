import json, os, sys, urllib.request, urllib.error
A = os.environ["A"]; URL = os.environ["URL"] + "/api/integration/v1"
def tok(n="desktop"): return open(f"{A}/tok/{n}.token").read().strip()
def req(method, path, token="desktop", body=None, raw=False, headers=None):
    h = {"Authorization": "Bearer " + tok(token)} if token else {}
    h.update(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r) as resp:
            b = resp.read(); return resp.status, (b if raw else json.loads(b))
    except urllib.error.HTTPError as e:
        b = e.read()
        try: return e.code, json.loads(b)
        except Exception: return e.code, b
if __name__ == "__main__":
    m, p = sys.argv[1], sys.argv[2]; tk = sys.argv[3] if len(sys.argv) > 3 else "desktop"
    s, b = req(m, p, tk); print(s); print(json.dumps(b, indent=1)[:6000])
