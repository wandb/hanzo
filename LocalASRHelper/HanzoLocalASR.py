#!/usr/bin/env python3
"""
HanzoLocalASR helper.

Provides Hanzo's streaming contract on Apple Silicon using mlx-audio:
  - GET  /v1/capabilities
  - POST /v1/stream/start
  - POST /v1/stream/chunk?session_id=...
  - POST /v1/stream/finish?session_id=...

Also provides model management endpoints for onboarding:
  - GET  /v1/model/status
  - POST /v1/model/download
"""

from __future__ import annotations

import argparse
import asyncio
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np
from huggingface_hub import HfApi, hf_hub_download

try:
    from fastapi import FastAPI, HTTPException, Query, Request
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse
    import uvicorn
    from mlx_audio.stt.utils import load_model
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Missing local ASR helper dependency. Install with:\n"
        "  python3 -m pip install -r LocalASRHelper/requirements.txt"
    ) from exc

MODEL_PRESETS = {
    "fast": "mlx-community/Qwen3-ASR-0.6B-8bit",
    "balanced": "mlx-community/Qwen3-ASR-1.7B-4bit",
}

# Required to run mlx-audio Qwen3 ASR from a local directory.
CORE_MODEL_FILES = {
    "config.json",
    "model.safetensors",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "chat_template.json",
    "generation_config.json",
}

STREAM_SAMPLE_RATE = 16_000
STREAM_CHANNELS = 1
STREAM_ENCODING = "pcm_f32le"
CONTRACT_API_VERSION = 1
MAX_CHUNK_BYTES = 1_048_576


@dataclass
class Session:
    audio_accum: np.ndarray = field(
        default_factory=lambda: np.zeros((0,), dtype=np.float32)
    )
    audio_encoding: str = STREAM_ENCODING
    sample_rate_hz: int = STREAM_SAMPLE_RATE
    channels: int = STREAM_CHANNELS
    text: str = ""
    language: str = "unknown"
    created_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)
    last_decode_at: float = 0.0
    decoded_samples: int = 0


@dataclass
class DownloadState:
    phase: str = "idle"  # idle | downloading | loading | ready | error
    progress: float = 0.0
    downloaded_bytes: int = 0
    total_bytes: int = 0
    error: Optional[str] = None
    updated_at: float = field(default_factory=time.time)

    def as_dict(self) -> dict:
        return {
            "phase": self.phase,
            "progress": self.progress,
            "downloaded_bytes": self.downloaded_bytes,
            "total_bytes": self.total_bytes,
            "error": self.error,
            "updated_at": self.updated_at,
        }


class LocalASRService:
    def __init__(
        self,
        *,
        preset: str,
        models_dir: Path,
        session_ttl_sec: int,
        decode_min_interval_sec: float,
        decode_min_new_audio_sec: float,
        partial_max_new_tokens: int,
        final_max_new_tokens: int,
        default_language: str,
    ) -> None:
        if preset not in MODEL_PRESETS:
            raise ValueError(f"Unknown preset: {preset}")

        self.preset = preset
        self.model_repo = MODEL_PRESETS[preset]
        self.model_dir = models_dir / self.model_repo.replace("/", "--")
        self.model_dir.mkdir(parents=True, exist_ok=True)

        self.session_ttl_sec = session_ttl_sec
        self.decode_min_interval_sec = decode_min_interval_sec
        self.decode_min_new_audio_sec = decode_min_new_audio_sec
        self.partial_max_new_tokens = partial_max_new_tokens
        self.final_max_new_tokens = final_max_new_tokens
        self.default_language = default_language

        self.sessions: dict[str, Session] = {}
        self.model = None
        self.model_lock = threading.Lock()
        self.inference_lock = asyncio.Lock()
        self.download_state = DownloadState()
        self.download_thread: Optional[threading.Thread] = None

    # MARK: Model State

    def model_is_downloaded(self) -> bool:
        for file_name in CORE_MODEL_FILES:
            if not (self.model_dir / file_name).exists():
                return False
        return True

    def _set_download_state(
        self,
        *,
        phase: Optional[str] = None,
        progress: Optional[float] = None,
        downloaded_bytes: Optional[int] = None,
        total_bytes: Optional[int] = None,
        error: Optional[str] = None,
    ) -> None:
        if phase is not None:
            self.download_state.phase = phase
        if progress is not None:
            self.download_state.progress = max(0.0, min(1.0, progress))
        if downloaded_bytes is not None:
            self.download_state.downloaded_bytes = max(0, downloaded_bytes)
        if total_bytes is not None:
            self.download_state.total_bytes = max(0, total_bytes)
        self.download_state.error = error
        self.download_state.updated_at = time.time()

    def _fetch_repo_file_manifest(self) -> list[dict]:
        try:
            info = HfApi().model_info(self.model_repo, files_metadata=True)
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"Unable to fetch model manifest: {exc}") from exc

        by_name = {item.rfilename: item for item in info.siblings}

        missing = sorted(CORE_MODEL_FILES - set(by_name.keys()))
        if missing:
            raise RuntimeError(
                f"Model manifest missing required files: {', '.join(missing)}"
            )

        files = []
        for name in sorted(CORE_MODEL_FILES):
            item = by_name[name]
            size = int(item.size or 0)
            files.append(
                {
                    "name": name,
                    "size": size,
                }
            )
        return files

    def _download_file(self, *, file_name: str, destination: Path, expected_size: int) -> int:
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            downloaded_path = hf_hub_download(
                repo_id=self.model_repo,
                filename=file_name,
                local_dir=str(self.model_dir),
            )
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"Failed to download {file_name}: {exc}") from exc

        final_size = Path(downloaded_path).stat().st_size
        if expected_size > 0 and final_size != expected_size:
            raise RuntimeError(
                f"Downloaded size mismatch for {destination.name}: expected {expected_size}, got {final_size}"
            )
        return final_size

    def download_model_blocking(self) -> None:
        if self.model_is_downloaded():
            self._set_download_state(
                phase="idle",
                progress=1.0,
                downloaded_bytes=0,
                total_bytes=0,
                error=None,
            )
            return

        files = self._fetch_repo_file_manifest()
        total_bytes = sum(item["size"] for item in files)
        downloaded = 0
        self._set_download_state(
            phase="downloading",
            progress=0.0,
            downloaded_bytes=0,
            total_bytes=total_bytes,
            error=None,
        )

        for item in files:
            destination = self.model_dir / item["name"]
            expected_size = item["size"]

            if destination.exists():
                existing_size = destination.stat().st_size
                if expected_size <= 0 or existing_size == expected_size:
                    downloaded += existing_size
                    self._set_download_state(
                        progress=(downloaded / total_bytes) if total_bytes > 0 else 1.0,
                        downloaded_bytes=downloaded,
                    )
                    continue

            written = self._download_file(
                file_name=item["name"],
                destination=destination,
                expected_size=expected_size,
            )
            downloaded += written
            self._set_download_state(
                progress=(downloaded / total_bytes) if total_bytes > 0 else 1.0,
                downloaded_bytes=downloaded,
            )

        self._set_download_state(
            phase="idle",
            progress=1.0,
            downloaded_bytes=total_bytes,
            total_bytes=total_bytes,
            error=None,
        )

    def start_download(self) -> None:
        if self.download_thread is not None and self.download_thread.is_alive():
            return

        def worker() -> None:
            try:
                self.download_model_blocking()
            except Exception as exc:  # noqa: BLE001
                self._set_download_state(
                    phase="error",
                    error=str(exc),
                )

        self.download_thread = threading.Thread(target=worker, daemon=True)
        self.download_thread.start()

    def ensure_model_loaded_blocking(self) -> None:
        with self.model_lock:
            if self.model is not None:
                return

            if not self.model_is_downloaded():
                raise RuntimeError("Model is not downloaded yet")

            self._set_download_state(phase="loading", error=None)
            try:
                self.model = load_model(str(self.model_dir))
            except Exception as exc:  # noqa: BLE001
                self._set_download_state(phase="error", error=str(exc))
                raise RuntimeError(f"Failed to load model: {exc}") from exc

            self._set_download_state(
                phase="ready",
                progress=1.0,
                error=None,
            )

    def download_and_load_blocking(self) -> None:
        self.download_model_blocking()
        self.ensure_model_loaded_blocking()

    # MARK: Streaming

    def cleanup_sessions(self) -> None:
        now = time.time()
        stale = [
            session_id
            for session_id, session in self.sessions.items()
            if (now - session.last_seen) > self.session_ttl_sec
        ]
        for session_id in stale:
            self.sessions.pop(session_id, None)

    def start_session(
        self,
        *,
        encoding: str,
        sample_rate_hz: int,
        channels: int,
    ) -> str:
        self.cleanup_sessions()
        session_id = str(uuid.uuid4())
        self.sessions[session_id] = Session(
            audio_encoding=encoding,
            sample_rate_hz=sample_rate_hz,
            channels=channels,
        )
        return session_id

    def get_session(self, session_id: str) -> Session:
        session = self.sessions.get(session_id)
        if session is None:
            raise KeyError(session_id)
        session.last_seen = time.time()
        return session

    def pop_session(self, session_id: str) -> Session:
        session = self.sessions.pop(session_id, None)
        if session is None:
            raise KeyError(session_id)
        return session

    def append_pcm_chunk(self, *, session: Session, pcm: np.ndarray) -> None:
        if pcm.ndim != 1:
            pcm = pcm.reshape(-1)

        if pcm.dtype != np.float32:
            pcm = pcm.astype(np.float32, copy=False)

        if session.audio_accum.size == 0:
            session.audio_accum = pcm.copy()
        else:
            session.audio_accum = np.concatenate([session.audio_accum, pcm], axis=0)

    def maybe_decode_partial(self, *, session: Session, force: bool = False) -> tuple[str, str]:
        if session.audio_accum.size == 0:
            return session.text, session.language

        now = time.time()
        new_samples = max(0, session.audio_accum.size - session.decoded_samples)
        new_audio_sec = new_samples / STREAM_SAMPLE_RATE
        elapsed = now - session.last_decode_at

        if not force:
            if elapsed < self.decode_min_interval_sec:
                return session.text, session.language
            if new_audio_sec < self.decode_min_new_audio_sec:
                return session.text, session.language

        max_tokens = self.final_max_new_tokens if force else self.partial_max_new_tokens
        result = self.model.generate(
            session.audio_accum,
            language=self.default_language,
            max_tokens=max_tokens,
        )
        text = (result.text or "").strip()

        if text:
            session.text = text
        session.last_decode_at = now
        session.decoded_samples = session.audio_accum.size
        return session.text, session.language


def api_error(
    *,
    status_code: int,
    code: str,
    message: str,
    retryable: bool = False,
) -> None:
    raise HTTPException(
        status_code=status_code,
        detail={
            "code": code,
            "message": message,
            "retryable": retryable,
        },
    )


def create_app(service: LocalASRService) -> FastAPI:
    app = FastAPI(title="Hanzo Local ASR", version="1.0.0")

    @app.exception_handler(HTTPException)
    async def on_http_exception(_: Request, exc: HTTPException):
        detail = exc.detail
        if isinstance(detail, dict):
            code = str(detail.get("code", "http_error"))
            message = str(detail.get("message", "Request failed"))
            retryable = bool(detail.get("retryable", False))
        else:
            code = "http_error"
            message = str(detail)
            retryable = False

        return JSONResponse(
            status_code=exc.status_code,
            content={
                "error": {
                    "code": code,
                    "message": message,
                    "retryable": retryable,
                }
            },
        )

    @app.exception_handler(RequestValidationError)
    async def on_validation_exception(_: Request, exc: RequestValidationError):
        return JSONResponse(
            status_code=400,
            content={
                "error": {
                    "code": "invalid_request",
                    "message": str(exc),
                    "retryable": False,
                }
            },
        )

    @app.exception_handler(Exception)
    async def on_unhandled_exception(_: Request, exc: Exception):
        return JSONResponse(
            status_code=500,
            content={
                "error": {
                    "code": "internal_error",
                    "message": str(exc),
                    "retryable": False,
                }
            },
        )

    @app.get("/healthz")
    async def healthz():
        return {
            "status": "ok",
            "ready": service.model is not None,
            "preset": service.preset,
            "model_repo": service.model_repo,
            "model_dir": str(service.model_dir),
            "download": service.download_state.as_dict(),
            "session_count": len(service.sessions),
        }

    @app.get("/v1/capabilities")
    async def capabilities():
        return {
            "api_version": CONTRACT_API_VERSION,
            "limits": {"max_chunk_bytes": MAX_CHUNK_BYTES},
        }

    @app.get("/v1/model/status")
    async def model_status():
        return {
            "ready": service.model is not None,
            "download": service.download_state.as_dict(),
            "preset": service.preset,
            "model_repo": service.model_repo,
            "model_dir": str(service.model_dir),
            "downloaded": service.model_is_downloaded(),
        }

    @app.post("/v1/model/download")
    async def model_download():
        service.start_download()
        return {"status": "started"}

    @app.post("/v1/model/prepare")
    async def model_prepare():
        try:
            await asyncio.to_thread(service.download_and_load_blocking)
        except Exception as exc:  # noqa: BLE001
            api_error(
                status_code=500,
                code="model_prepare_failed",
                message=str(exc),
                retryable=False,
            )
        return {"status": "ready"}

    @app.post("/v1/stream/start")
    async def stream_start(request: Request):
        try:
            payload = await request.json()
        except Exception:  # noqa: BLE001
            api_error(
                status_code=400,
                code="invalid_request",
                message="Expected JSON request body",
                retryable=False,
            )

        if not isinstance(payload, dict):
            api_error(
                status_code=400,
                code="invalid_request",
                message="Expected JSON object body",
                retryable=False,
            )

        audio = payload.get("audio")
        if not isinstance(audio, dict):
            api_error(
                status_code=400,
                code="invalid_request",
                message="Missing required `audio` object",
                retryable=False,
            )

        encoding = audio.get("encoding")
        sample_rate_hz = audio.get("sample_rate_hz")
        channels = audio.get("channels")

        if not isinstance(encoding, str) or not isinstance(sample_rate_hz, int) or not isinstance(channels, int):
            api_error(
                status_code=400,
                code="invalid_request",
                message="`audio.encoding` (string), `audio.sample_rate_hz` (int), and `audio.channels` (int) are required",
                retryable=False,
            )

        if encoding != STREAM_ENCODING or sample_rate_hz != STREAM_SAMPLE_RATE or channels != STREAM_CHANNELS:
            api_error(
                status_code=400,
                code="unsupported_audio_format",
                message=(
                    f"Unsupported audio format. Expected encoding={STREAM_ENCODING}, "
                    f"sample_rate_hz={STREAM_SAMPLE_RATE}, channels={STREAM_CHANNELS}"
                ),
                retryable=False,
            )

        if service.model is None:
            try:
                await asyncio.to_thread(service.ensure_model_loaded_blocking)
            except Exception as exc:  # noqa: BLE001
                api_error(
                    status_code=503,
                    code="runtime_unavailable",
                    message=f"Local model is not ready: {exc}",
                    retryable=True,
                )

        session_id = service.start_session(
            encoding=encoding,
            sample_rate_hz=sample_rate_hz,
            channels=channels,
        )
        return {"session_id": session_id}

    @app.post("/v1/stream/chunk")
    async def stream_chunk(
        request: Request,
        session_id: str = Query(...),
    ):
        try:
            session = service.get_session(session_id)
        except KeyError:
            api_error(
                status_code=404,
                code="session_not_found",
                message="Session not found",
                retryable=False,
            )

        body = await request.body()
        if len(body) > MAX_CHUNK_BYTES:
            api_error(
                status_code=413,
                code="chunk_too_large",
                message=f"Chunk exceeds max_chunk_bytes={MAX_CHUNK_BYTES}",
                retryable=False,
            )
        if len(body) == 0:
            api_error(
                status_code=400,
                code="invalid_audio_payload",
                message="Empty chunk",
                retryable=False,
            )
        if len(body) % 4 != 0:
            api_error(
                status_code=400,
                code="invalid_audio_payload",
                message="Chunk must be float32 PCM (byte length multiple of 4)",
                retryable=False,
            )

        pcm = np.frombuffer(body, dtype=np.float32)
        service.append_pcm_chunk(session=session, pcm=pcm)

        async with service.inference_lock:
            try:
                text, language = await asyncio.to_thread(
                    service.maybe_decode_partial,
                    session=session,
                    force=False,
                )
            except Exception as exc:  # noqa: BLE001
                api_error(
                    status_code=500,
                    code="inference_failure",
                    message=str(exc),
                    retryable=False,
                )

        return {"text": text, "language": language}

    @app.post("/v1/stream/finish")
    async def stream_finish(
        session_id: str = Query(...),
    ):
        try:
            session = service.pop_session(session_id)
        except KeyError:
            api_error(
                status_code=404,
                code="session_not_found",
                message="Session not found",
                retryable=False,
            )

        async with service.inference_lock:
            try:
                text, language = await asyncio.to_thread(
                    service.maybe_decode_partial,
                    session=session,
                    force=True,
                )
            except Exception as exc:  # noqa: BLE001
                api_error(
                    status_code=500,
                    code="finalize_failure",
                    message=str(exc),
                    retryable=False,
                )

        return {"text": text, "language": language}

    return app


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Hanzo local ASR helper")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--preset", default="balanced", choices=list(MODEL_PRESETS.keys()))
    parser.add_argument(
        "--models-dir",
        default=str(Path.home() / "Library" / "Application Support" / "com.hanzo.app" / "models"),
    )
    parser.add_argument("--session-ttl-sec", type=int, default=600)
    parser.add_argument("--decode-min-interval-sec", type=float, default=0.9)
    parser.add_argument("--decode-min-new-audio-sec", type=float, default=0.8)
    parser.add_argument("--partial-max-new-tokens", type=int, default=256)
    parser.add_argument("--final-max-new-tokens", type=int, default=1024)
    parser.add_argument("--language", default="English")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    service = LocalASRService(
        preset=args.preset,
        models_dir=Path(args.models_dir).expanduser(),
        session_ttl_sec=args.session_ttl_sec,
        decode_min_interval_sec=args.decode_min_interval_sec,
        decode_min_new_audio_sec=args.decode_min_new_audio_sec,
        partial_max_new_tokens=args.partial_max_new_tokens,
        final_max_new_tokens=args.final_max_new_tokens,
        default_language=args.language,
    )
    app = create_app(service)

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
