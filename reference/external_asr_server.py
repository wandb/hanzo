"""
Reference hosted-compatible Hanzo streaming server.

Implements the unified contract:
  - GET  /v1/capabilities
  - POST /v1/stream/start
  - POST /v1/stream/chunk?session_id=...
  - POST /v1/stream/finish?session_id=...

Optional endpoint:
  - POST /v1/transcribe

Auth:
  - X-API-Key header when API_KEY is set.
"""

import asyncio
import io
import os
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Header, HTTPException, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from qwen_asr import Qwen3ASRModel

MODEL_NAME = os.getenv("MODEL_NAME", "Qwen/Qwen3-ASR-1.7B")
API_KEY = os.getenv("API_KEY")  # if unset, auth is disabled
MAX_UPLOAD_MB = int(os.getenv("MAX_UPLOAD_MB", "50"))
MAX_CHUNK_BYTES = int(os.getenv("MAX_CHUNK_BYTES", "1048576"))
CONTRACT_API_VERSION = int(os.getenv("CONTRACT_API_VERSION", "1"))

# Qwen backend knobs
GPU_MEMORY_UTIL = float(os.getenv("GPU_MEMORY_UTIL", "0.85"))
MAX_NEW_TOKENS = int(os.getenv("MAX_NEW_TOKENS", "256"))
UNFIXED_CHUNK_NUM = int(os.getenv("UNFIXED_CHUNK_NUM", "2"))
UNFIXED_TOKEN_NUM = int(os.getenv("UNFIXED_TOKEN_NUM", "5"))
CHUNK_SIZE_SEC = float(os.getenv("CHUNK_SIZE_SEC", "2.0"))
SESSION_TTL_SEC = int(os.getenv("SESSION_TTL_SEC", "600"))

# Unified streaming contract audio format.
STREAM_ENCODING = "pcm_f32le"
STREAM_SAMPLE_RATE = 16000
STREAM_CHANNELS = 1

app = FastAPI(title="Hanzo Reference ASR Service", version="1.0.0")

model: Optional[Qwen3ASRModel] = None
inference_lock = asyncio.Lock()


@dataclass
class Session:
    state: object  # Qwen streaming state
    audio_encoding: str
    sample_rate_hz: int
    channels: int
    created_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)


sessions: dict[str, Session] = {}


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


def require_api_key(x_api_key: Optional[str]) -> None:
    if API_KEY and x_api_key != API_KEY:
        api_error(
            status_code=401,
            code="auth_failed",
            message="Invalid API key",
            retryable=False,
        )


def require_model_loaded() -> None:
    if model is None:
        api_error(
            status_code=503,
            code="runtime_unavailable",
            message="Model not loaded",
            retryable=True,
        )


def cleanup_sessions() -> None:
    now = time.time()
    expired = [sid for sid, s in sessions.items() if now - s.last_seen > SESSION_TTL_SEC]
    for sid in expired:
        stale = sessions.pop(sid)
        try:
            model.finish_streaming_transcribe(stale.state)
        except Exception:
            pass


def parse_start_audio_contract(payload: object) -> tuple[str, int, int]:
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
            message=(
                "`audio.encoding` (string), `audio.sample_rate_hz` (int), and "
                "`audio.channels` (int) are required"
            ),
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

    return encoding, sample_rate_hz, channels


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


@app.on_event("startup")
def startup() -> None:
    global model
    print(
        "Loading model "
        f"MODEL_NAME={MODEL_NAME}, "
        f"GPU_MEMORY_UTIL={GPU_MEMORY_UTIL}, "
        f"MAX_NEW_TOKENS={MAX_NEW_TOKENS}"
    )
    model = Qwen3ASRModel.LLM(
        model=MODEL_NAME,
        gpu_memory_utilization=GPU_MEMORY_UTIL,
        max_inference_batch_size=1,
        max_new_tokens=MAX_NEW_TOKENS,
    )


@app.get("/healthz")
def healthz():
    require_model_loaded()
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "gpu_memory_util": GPU_MEMORY_UTIL,
        "max_new_tokens": MAX_NEW_TOKENS,
        "session_ttl_sec": SESSION_TTL_SEC,
    }


@app.get("/v1/capabilities")
def capabilities(
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)
    return {
        "api_version": CONTRACT_API_VERSION,
        "limits": {"max_chunk_bytes": MAX_CHUNK_BYTES},
    }


@app.post("/v1/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    source_lang: Optional[str] = None,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)
    require_model_loaded()

    data = await file.read()
    if len(data) > MAX_UPLOAD_MB * 1024 * 1024:
        api_error(
            status_code=413,
            code="payload_too_large",
            message=f"File too large (>{MAX_UPLOAD_MB}MB)",
            retryable=False,
        )

    try:
        waveform, sr = sf.read(io.BytesIO(data), dtype="float32")
    except Exception as exc:  # noqa: BLE001
        api_error(
            status_code=400,
            code="invalid_audio_payload",
            message=f"Could not decode audio: {exc}",
            retryable=False,
        )

    if waveform.ndim > 1:
        waveform = waveform.mean(axis=1)

    audio_input = (np.asarray(waveform, dtype=np.float32), int(sr))

    lang_map = {
        "en": "English",
        "zh": "Chinese",
        "ja": "Japanese",
        "ko": "Korean",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "ru": "Russian",
        "ar": "Arabic",
    }
    language = lang_map.get(source_lang, source_lang) if source_lang else None

    started = time.time()
    async with inference_lock:
        result = await asyncio.to_thread(
            model.transcribe,
            audio=audio_input,
            language=language,
            return_time_stamps=False,
        )

    first = result[0]
    return {
        "text": first.text,
        "language": first.language,
        "elapsed_ms": int((time.time() - started) * 1000),
    }


@app.post("/v1/stream/start")
async def stream_start(
    request: Request,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)
    require_model_loaded()

    try:
        payload = await request.json()
    except Exception:  # noqa: BLE001
        api_error(
            status_code=400,
            code="invalid_request",
            message="Expected JSON request body",
            retryable=False,
        )

    encoding, sample_rate_hz, channels = parse_start_audio_contract(payload)
    cleanup_sessions()

    state = model.init_streaming_state(
        unfixed_chunk_num=UNFIXED_CHUNK_NUM,
        unfixed_token_num=UNFIXED_TOKEN_NUM,
        chunk_size_sec=CHUNK_SIZE_SEC,
    )

    session_id = str(uuid.uuid4())
    sessions[session_id] = Session(
        state=state,
        audio_encoding=encoding,
        sample_rate_hz=sample_rate_hz,
        channels=channels,
    )

    return {"session_id": session_id}


@app.post("/v1/stream/chunk")
async def stream_chunk(
    request: Request,
    session_id: str,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)
    require_model_loaded()

    session = sessions.get(session_id)
    if session is None:
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
    session.last_seen = time.time()

    async with inference_lock:
        try:
            result = await asyncio.to_thread(model.streaming_transcribe, pcm, session.state)
        except Exception as exc:  # noqa: BLE001
            api_error(
                status_code=500,
                code="inference_failure",
                message=str(exc),
                retryable=False,
            )

    return {"language": result.language, "text": result.text}


@app.post("/v1/stream/finish")
async def stream_finish(
    session_id: str,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)
    require_model_loaded()

    session = sessions.pop(session_id, None)
    if session is None:
        api_error(
            status_code=404,
            code="session_not_found",
            message="Session not found",
            retryable=False,
        )

    async with inference_lock:
        try:
            result = await asyncio.to_thread(model.finish_streaming_transcribe, session.state)
        except Exception as exc:  # noqa: BLE001
            api_error(
                status_code=500,
                code="finalize_failure",
                message=str(exc),
                retryable=False,
            )

    return {"language": result.language, "text": result.text}
