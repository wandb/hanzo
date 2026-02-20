"""
Reference: External Qwen3 ASR Server
=====================================
This is the external ASR (Automatic Speech Recognition) server we will integrate with.
It runs Qwen3-ASR-1.7B via a FastAPI service with both batch and streaming endpoints.

Endpoints:
  GET  /healthz              - Health check
  POST /v1/transcribe        - Batch transcription (upload audio file)
  POST /v1/stream/start      - Start a streaming session
  POST /v1/stream/chunk      - Send audio chunk to streaming session (float32 PCM)
  POST /v1/stream/finish     - Finish streaming session and get final transcript

Auth: X-API-Key header (optional, controlled by API_KEY env var)
"""

import io
import os
import time
import uuid
import asyncio
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import soundfile as sf
from fastapi import FastAPI, Request, UploadFile, File, Header, HTTPException
from qwen_asr import Qwen3ASRModel

MODEL_NAME = os.getenv("MODEL_NAME", "Qwen/Qwen3-ASR-1.7B")
API_KEY = os.getenv("API_KEY")  # if unset, auth is disabled
MAX_UPLOAD_MB = int(os.getenv("MAX_UPLOAD_MB", "50"))

# Tunable hyperparameters for latency optimization
GPU_MEMORY_UTIL = float(os.getenv("GPU_MEMORY_UTIL", "0.85"))
MAX_NEW_TOKENS = int(os.getenv("MAX_NEW_TOKENS", "256"))

# Streaming transcription config
UNFIXED_CHUNK_NUM = int(os.getenv("UNFIXED_CHUNK_NUM", "2"))
UNFIXED_TOKEN_NUM = int(os.getenv("UNFIXED_TOKEN_NUM", "5"))
CHUNK_SIZE_SEC = float(os.getenv("CHUNK_SIZE_SEC", "2.0"))
SESSION_TTL_SEC = int(os.getenv("SESSION_TTL_SEC", "600"))

app = FastAPI(title="Qwen3 ASR Service", version="1.0.0")

model: Optional[Qwen3ASRModel] = None
inference_lock = asyncio.Lock()


@dataclass
class Session:
    state: object  # ASRStreamingState
    created_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)


sessions: dict[str, Session] = {}


def cleanup_sessions() -> None:
    """Remove sessions not touched within SESSION_TTL_SEC."""
    now = time.time()
    expired = [sid for sid, s in sessions.items() if now - s.last_seen > SESSION_TTL_SEC]
    for sid in expired:
        s = sessions.pop(sid)
        try:
            model.finish_streaming_transcribe(s.state)
        except Exception:
            pass


def require_api_key(x_api_key: Optional[str]) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.on_event("startup")
def startup() -> None:
    global model
    # Use vLLM backend for lowest latency
    # Parameters configurable via env vars for hyperparameter sweeps
    # vLLM automatically uses flash attention if installed
    print(f"Loading model with GPU_MEMORY_UTIL={GPU_MEMORY_UTIL}, MAX_NEW_TOKENS={MAX_NEW_TOKENS}")
    model = Qwen3ASRModel.LLM(
        model=MODEL_NAME,
        gpu_memory_utilization=GPU_MEMORY_UTIL,
        max_inference_batch_size=1,
        max_new_tokens=MAX_NEW_TOKENS,
    )


@app.get("/healthz")
def healthz():
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "gpu_memory_util": GPU_MEMORY_UTIL,
        "max_new_tokens": MAX_NEW_TOKENS,
        "unfixed_chunk_num": UNFIXED_CHUNK_NUM,
        "unfixed_token_num": UNFIXED_TOKEN_NUM,
        "chunk_size_sec": CHUNK_SIZE_SEC,
        "session_ttl_sec": SESSION_TTL_SEC,
    }


@app.post("/v1/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    source_lang: Optional[str] = None,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    data = await file.read()
    if len(data) > MAX_UPLOAD_MB * 1024 * 1024:
        raise HTTPException(
            status_code=413, detail=f"File too large (>{MAX_UPLOAD_MB}MB)"
        )

    # Read directly from bytes into numpy array
    try:
        waveform, sr = sf.read(io.BytesIO(data), dtype="float32")
    except Exception as e:
        raise HTTPException(
            status_code=400, detail=f"Could not decode audio: {e}"
        )

    # Ensure mono
    if waveform.ndim > 1:
        waveform = waveform.mean(axis=1)

    # Qwen3-ASR accepts (np.ndarray, sample_rate) tuple directly
    audio_input = (np.asarray(waveform, dtype=np.float32), int(sr))

    # Map source_lang to Qwen3-ASR language format
    # Qwen3-ASR uses full language names like "English", "Chinese"
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

    start = time.time()

    async with inference_lock:
        results = await asyncio.to_thread(
            model.transcribe,
            audio=audio_input,
            language=language,
            return_time_stamps=False,
        )

    result = results[0]
    text = result.text
    detected_lang = result.language

    return {
        "text": text,
        "model": MODEL_NAME,
        "elapsed_ms": int((time.time() - start) * 1000),
        "language": detected_lang,
    }


@app.post("/v1/stream/start")
async def stream_start(
    source_lang: Optional[str] = None,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    cleanup_sessions()

    state = model.init_streaming_state(
        unfixed_chunk_num=UNFIXED_CHUNK_NUM,
        unfixed_token_num=UNFIXED_TOKEN_NUM,
        chunk_size_sec=CHUNK_SIZE_SEC,
    )
    session_id = str(uuid.uuid4())
    sessions[session_id] = Session(state=state)

    return {"session_id": session_id}


@app.post("/v1/stream/chunk")
async def stream_chunk(
    request: Request,
    session_id: str,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    session = sessions.get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")

    data = await request.body()
    if len(data) == 0:
        raise HTTPException(status_code=400, detail="Empty chunk")
    if len(data) % 4 != 0:
        raise HTTPException(
            status_code=400,
            detail=f"Byte length {len(data)} is not a multiple of 4 (expected float32 PCM)",
        )

    pcm = np.frombuffer(data, dtype=np.float32)
    session.last_seen = time.time()

    async with inference_lock:
        result = await asyncio.to_thread(
            model.streaming_transcribe, pcm, session.state
        )

    return {"language": result.language, "text": result.text}


@app.post("/v1/stream/finish")
async def stream_finish(
    session_id: str,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    require_api_key(x_api_key)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    session = sessions.pop(session_id, None)
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")

    async with inference_lock:
        result = await asyncio.to_thread(
            model.finish_streaming_transcribe, session.state
        )

    return {"language": result.language, "text": result.text}
