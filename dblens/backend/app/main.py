from fastapi import FastAPI
from backend.app.core.logging import init_logging
from backend.app.routers import ask

init_logging()
app = FastAPI(title="DBLens")
app.include_router(ask.router, prefix="/v1")
