FROM python:3.11-slim

# OS libs: libmagic for python-magic, jq for local JSON viewing, certs for HTTPS
RUN apt-get update && apt-get install -y --no-install-recommends \
      libmagic1 jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Python deps (pin core libs; add FastAPI/Uvicorn)
RUN pip install --no-cache-dir \
    psycopg[binary]==3.2.1 \
    pandas==2.2.2 \
    pyarrow==16.1.0 \
    requests==2.32.3 \
    python-magic==0.4.27 \
    fastapi \
    uvicorn

WORKDIR /app
COPY . /app
