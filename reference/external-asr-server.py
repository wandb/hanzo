#!/usr/bin/env python3
"""
Compatibility wrapper for running the reference ASR server as a script.
"""

from external_asr_server import app  # noqa: F401


def main() -> None:
    import uvicorn

    uvicorn.run("external_asr_server:app", host="127.0.0.1", port=8000, log_level="info")


if __name__ == "__main__":
    main()
