#!/usr/bin/env python3
import base64
import json
import os
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    operation = request.get("operation")
    delay = request.get("arguments", {}).get("delay", 0)
    if delay:
        time.sleep(float(delay))
    if operation == "handshake":
        result = {
            "protocol": 1,
            "provider_id": os.environ.get("NETVPLAYER_PROVIDER_ID", ""),
            "runtime": "fixture",
        }
        host_capabilities = [
            value.strip()
            for value in os.environ.get("NETVPLAYER_PROVIDER_HOST_CAPABILITIES", "").split(",")
            if value.strip()
        ]
        if host_capabilities:
            result["capabilities"] = ["core-lifecycle", *host_capabilities]
    elif operation == "health":
        result = {"status": "ok"}
    elif operation == "proxy":
        parameters = request.get("arguments", {}).get("parameters", {})
        body = "provider-proxy|{}|{}".format(
            parameters.get("range", ""),
            parameters.get("x-proxy-test", ""),
        ).encode("utf-8")
        print(json.dumps({
            "request_id": request.get("request_id", ""),
            "ok": True,
            "result": None,
            "proxy": {
                "status_code": 202,
                "content_type": "application/octet-stream",
                "body_base64": base64.b64encode(body).decode("ascii"),
                "headers": {
                    "Content-Length": "999",
                    "X-Provider-Proxy": "fixture",
                    "X-Proxy-Range": parameters.get("range", ""),
                },
            },
            "error": None,
        }, separators=(",", ":")), flush=True)
        continue
    elif operation == "shutdown":
        result = {"shutdown": True}
    else:
        arguments = request.get("arguments", {})
        large_result_bytes = int(arguments.get("large_result_bytes", 0))
        if large_result_bytes:
            result = {
                "marker": arguments.get("marker", ""),
                "payload": "x" * large_result_bytes,
            }
        else:
            result = arguments
    print(json.dumps({
        "request_id": request.get("request_id", ""),
        "ok": True,
        "result": result,
        "error": None,
    }, separators=(",", ":")), flush=True)
    if operation == "shutdown":
        break
