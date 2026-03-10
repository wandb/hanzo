# Hanzo Reference Server

This folder contains a hosted-compatible reference implementation of Hanzo's unified streaming contract and a conformance test runner.

## Contract

- `GET /v1/capabilities`
- `POST /v1/stream/start`
- `POST /v1/stream/chunk?session_id=...`
- `POST /v1/stream/finish?session_id=...`

Non-2xx responses return:

```json
{
  "error": {
    "code": "string",
    "message": "human-readable",
    "retryable": false
  }
}
```

## Run The Server

```bash
python3 -m pip install -r reference/requirements.txt
uvicorn external_asr_server:app --app-dir reference --host 127.0.0.1 --port 8000
```

Optional environment variables:

- `API_KEY` (enable auth)
- `MODEL_NAME`
- `MAX_CHUNK_BYTES` (default `1048576`)
- `CONTRACT_API_VERSION` (default `1`)

## Run Conformance

```bash
python3 reference/conformance_test.py --base-url http://127.0.0.1:8000
```

With auth:

```bash
python3 reference/conformance_test.py --base-url http://127.0.0.1:8000 --api-key YOUR_KEY
```

## Using Your Own Model

`reference/external_asr_server.py` isolates model-specific logic in `startup`, `/v1/stream/start`, `/v1/stream/chunk`, and `/v1/stream/finish`. Replace those internals with your own backend while keeping endpoint shapes and error envelopes unchanged.
