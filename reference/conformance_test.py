#!/usr/bin/env python3
"""
Conformance checks for Hanzo unified streaming contract.

Usage:
  python3 reference/conformance_test.py --base-url http://127.0.0.1:8000
  python3 reference/conformance_test.py --base-url https://your-server --api-key YOUR_KEY
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Hanzo streaming contract conformance test")
    parser.add_argument("--base-url", required=True, help="Server base URL, e.g. http://127.0.0.1:8000")
    parser.add_argument("--api-key", default="", help="Optional X-API-Key value")
    parser.add_argument(
        "--allow-auth-failure",
        action="store_true",
        help="Treat 401/403 as expected for servers requiring auth when no key is supplied",
    )
    return parser.parse_args()


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def request(
    *,
    base_url: str,
    path: str,
    method: str,
    api_key: str,
    body: bytes | None = None,
    content_type: str | None = None,
) -> tuple[int, bytes]:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    req = urllib.request.Request(url=url, method=method, data=body)
    if api_key:
        req.add_header("X-API-Key", api_key)
    if content_type:
        req.add_header("Content-Type", content_type)

    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def parse_json(data: bytes) -> dict:
    try:
        payload = json.loads(data.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise AssertionError(f"Response is not valid JSON: {exc}") from exc
    assert_true(isinstance(payload, dict), "Response JSON must be an object")
    return payload


def assert_error_envelope(payload: dict) -> None:
    error = payload.get("error")
    assert_true(isinstance(error, dict), "Non-2xx response must include `error` object")
    assert_true(isinstance(error.get("code"), str) and error["code"], "`error.code` must be non-empty string")
    assert_true(isinstance(error.get("message"), str) and error["message"], "`error.message` must be non-empty string")
    assert_true(isinstance(error.get("retryable"), bool), "`error.retryable` must be bool")


def pcm_f32le_bytes(sample_count: int) -> bytes:
    # Small deterministic waveform.
    values = [(i % 32) / 32.0 for i in range(sample_count)]
    return struct.pack("<" + "f" * sample_count, *values)


def main() -> int:
    args = parse_args()

    print(f"Running conformance test against {args.base_url}")

    status, raw = request(
        base_url=args.base_url,
        path="/v1/capabilities",
        method="GET",
        api_key=args.api_key,
    )

    if status in (401, 403):
        if args.allow_auth_failure and not args.api_key:
            print("PASS (auth required and no key supplied).")
            return 0
        payload = parse_json(raw)
        assert_error_envelope(payload)
        raise AssertionError("Capabilities request failed with auth error")

    assert_true(status == 200, f"Expected 200 from /v1/capabilities, got {status}")
    capabilities = parse_json(raw)
    assert_true(isinstance(capabilities.get("api_version"), int), "`api_version` must be int")

    limits = capabilities.get("limits")
    assert_true(isinstance(limits, dict), "`limits` must be object")
    max_chunk_bytes = limits.get("max_chunk_bytes")
    assert_true(isinstance(max_chunk_bytes, int) and max_chunk_bytes > 0, "`limits.max_chunk_bytes` must be positive int")

    start_body = {
        "audio": {
            "encoding": "pcm_f32le",
            "sample_rate_hz": 16000,
            "channels": 1,
        }
    }
    status, raw = request(
        base_url=args.base_url,
        path="/v1/stream/start",
        method="POST",
        api_key=args.api_key,
        body=json.dumps(start_body).encode("utf-8"),
        content_type="application/json",
    )
    assert_true(status == 200, f"Expected 200 from /v1/stream/start, got {status}")
    start_payload = parse_json(raw)
    session_id = start_payload.get("session_id")
    assert_true(isinstance(session_id, str) and session_id, "`session_id` must be non-empty string")

    chunk_data = pcm_f32le_bytes(sample_count=1600)
    status, raw = request(
        base_url=args.base_url,
        path=f"/v1/stream/chunk?session_id={urllib.parse.quote(session_id)}",
        method="POST",
        api_key=args.api_key,
        body=chunk_data,
        content_type="application/octet-stream",
    )
    assert_true(status == 200, f"Expected 200 from /v1/stream/chunk, got {status}")
    chunk_payload = parse_json(raw)
    assert_true(isinstance(chunk_payload.get("text"), str), "`/chunk text` must be string")
    assert_true(isinstance(chunk_payload.get("language"), str), "`/chunk language` must be string")

    status, raw = request(
        base_url=args.base_url,
        path=f"/v1/stream/finish?session_id={urllib.parse.quote(session_id)}",
        method="POST",
        api_key=args.api_key,
    )
    assert_true(status == 200, f"Expected 200 from /v1/stream/finish, got {status}")
    finish_payload = parse_json(raw)
    assert_true(isinstance(finish_payload.get("text"), str), "`/finish text` must be string")
    assert_true(isinstance(finish_payload.get("language"), str), "`/finish language` must be string")

    # /chunk invalid session -> 404 + error envelope
    status, raw = request(
        base_url=args.base_url,
        path="/v1/stream/chunk?session_id=missing-session",
        method="POST",
        api_key=args.api_key,
        body=chunk_data,
        content_type="application/octet-stream",
    )
    assert_true(status == 404, f"Expected 404 for invalid /chunk session, got {status}")
    assert_error_envelope(parse_json(raw))

    # /finish invalid session -> 404 + error envelope
    status, raw = request(
        base_url=args.base_url,
        path="/v1/stream/finish?session_id=missing-session",
        method="POST",
        api_key=args.api_key,
    )
    assert_true(status == 404, f"Expected 404 for invalid /finish session, got {status}")
    assert_error_envelope(parse_json(raw))

    # Invalid audio payload length -> 400 + error envelope
    status, raw = request(
        base_url=args.base_url,
        path=f"/v1/stream/chunk?session_id={urllib.parse.quote(session_id)}",
        method="POST",
        api_key=args.api_key,
        body=b"\x00\x01\x02",
        content_type="application/octet-stream",
    )
    assert_true(status in (400, 404), f"Expected 400/404 for invalid chunk payload, got {status}")
    assert_error_envelope(parse_json(raw))

    # /start with unsupported format -> 400 + error envelope
    bad_start = {
        "audio": {
            "encoding": "pcm_s16le",
            "sample_rate_hz": 16000,
            "channels": 1,
        }
    }
    status, raw = request(
        base_url=args.base_url,
        path="/v1/stream/start",
        method="POST",
        api_key=args.api_key,
        body=json.dumps(bad_start).encode("utf-8"),
        content_type="application/json",
    )
    assert_true(status == 400, f"Expected 400 for unsupported /start audio format, got {status}")
    assert_error_envelope(parse_json(raw))

    # Chunk too large check (if server advertises a finite limit)
    oversized = b"\x00" * (max_chunk_bytes + 1)
    status, raw = request(
        base_url=args.base_url,
        path="/v1/stream/chunk?session_id=missing-session",
        method="POST",
        api_key=args.api_key,
        body=oversized,
        content_type="application/octet-stream",
    )
    # Servers may validate session first or payload first.
    assert_true(status in (404, 413), f"Expected 404/413 for oversized invalid-session chunk, got {status}")
    assert_error_envelope(parse_json(raw))

    print("PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
