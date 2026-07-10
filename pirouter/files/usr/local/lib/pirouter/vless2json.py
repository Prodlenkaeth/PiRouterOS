#!/usr/bin/env python3
# ==========================================================================
#  vless2json.py  -  turn a vless:// share link into an Xray outbound object
#  usage: vless2json.py 'vless://uuid@host:port?...#name'
#  prints the outbound JSON to stdout. Exits non-zero with a message on error.
# ==========================================================================
import sys, json, urllib.parse


def _truthy(v: str) -> bool:
    return str(v).lower() in ("1", "true", "yes", "on")


def build(link: str) -> dict:
    link = link.strip()
    if not link.startswith("vless://"):
        raise ValueError("not a vless:// link")

    u = urllib.parse.urlparse(link)
    q = {k.lower(): v for k, v in urllib.parse.parse_qsl(u.query)}

    uuid = urllib.parse.unquote(u.username or "")
    host = u.hostname or ""
    port = int(u.port or 443)
    if not uuid:
        raise ValueError("missing UUID in vless link")
    if not host:
        raise ValueError("missing host in vless link")

    net = (q.get("type") or "tcp").lower()          # tcp|ws|grpc|h2|http
    security = (q.get("security") or "none").lower() # none|tls|reality
    sni = q.get("sni") or q.get("host") or host
    flow = q.get("flow", "")
    fp = q.get("fp", "")
    alpn = q.get("alpn", "")
    allow_insecure = _truthy(q.get("allowinsecure", "0"))

    stream = {"network": net, "security": security}

    if security == "tls":
        tls = {"serverName": sni, "allowInsecure": allow_insecure}
        if fp:
            tls["fingerprint"] = fp
        if alpn:
            tls["alpn"] = [a for a in alpn.split(",") if a]
        stream["tlsSettings"] = tls
    elif security == "reality":
        rs = {
            "serverName": sni,
            "publicKey": q.get("pbk", ""),
            "shortId": q.get("sid", ""),
            "spiderX": q.get("spx", "/"),
            "fingerprint": fp or "chrome",
        }
        stream["realitySettings"] = rs

    if net == "ws":
        stream["wsSettings"] = {
            "path": q.get("path", "/"),
            "headers": {"Host": q.get("host") or sni},
        }
    elif net == "grpc":
        gs = {"serviceName": q.get("servicename") or q.get("serviceName", "")}
        if (q.get("mode") or "") == "multi":
            gs["multiMode"] = True
        stream["grpcSettings"] = gs
    elif net in ("h2", "http"):
        stream["network"] = "h2"
        stream["httpSettings"] = {
            "path": q.get("path", "/"),
            "host": [h for h in (q.get("host") or sni).split(",") if h],
        }

    user = {"id": uuid, "encryption": q.get("encryption", "none")}
    if flow:
        user["flow"] = flow

    return {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {"vnext": [{"address": host, "port": port, "users": [user]}]},
        "streamSettings": stream,
    }


if __name__ == "__main__":
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        sys.exit("usage: vless2json.py <vless://...>")
    try:
        print(json.dumps(build(sys.argv[1]), indent=2))
    except Exception as e:  # noqa: BLE001
        sys.exit(f"vless parse error: {e}")
