from fastapi import FastAPI, Header, HTTPException, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from loguru import logger
import os

# Routers (ensure we import only the routers we expose)
from backend.app.routers import ask, approve, lint, history

app = FastAPI(title="DBLens", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def api_key_guard(x_api_key: str | None = Header(default=None)):
    need = os.getenv("API_KEY")
    if need and x_api_key != need:
        raise HTTPException(status_code=401, detail="invalid api key")


# Mount routers with guard
app.include_router(ask.router, prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(approve.router, prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(lint.router, prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(history.router, prefix="/v1", dependencies=[Depends(api_key_guard)])
# Note: 'explain' router is not imported here - keep imports consistent with codebase


@app.exception_handler(Exception)
async def _unhandled_error(request: Request, exc: Exception):
    logger.error("unhandled", exception=exc)
    # re-raise so FastAPI generates the proper error response
    raise exc
