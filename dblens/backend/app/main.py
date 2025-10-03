from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from backend.app.core.logging import init_logging
from backend.app.routers import ask
from backend.app.routers import approve

init_logging()
app = FastAPI(title="DBLens")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ask.router, prefix="/v1")
app.include_router(approve.router, prefix="/v1")
