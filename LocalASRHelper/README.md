# LocalASRHelper (Qwen3 Example)

This folder contains an optional local Qwen3 ASR server implementation for advanced users.

- It is **not bundled** into the distributed Hanzo app.
- It is intended for users who want to run their own runtime and connect via Hanzo's **Custom Server** provider.

## Run

```bash
python3 -m pip install -r LocalASRHelper/requirements.txt
LocalASRHelper/HanzoLocalASR --host 127.0.0.1 --port 8765 --preset balanced
```

Then configure Hanzo to use:

- Provider: `Custom Server`
- Endpoint: `http://127.0.0.1:8765`
