FROM python:3.11-slim

# OS deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    libmagic1 jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Core + API + connectors (single pip line)
RUN pip install --no-cache-dir  pymysql==1.1.0 snowflake-connector-python==3.10.0 sqlglot==25.6.0\
    fastapi==0.112.2 \
    uvicorn[standard]==0.30.6 \
    psycopg[binary]==3.2.1 \
    pandas==2.2.2 \
    pyarrow==16.1.0 \
    requests==2.32.3 \
    python-magic==0.4.27 \
    pymysql==1.1.0 \
    snowflake-connector-python==3.10.0 \
    sqlglot==25.6.0

WORKDIR /app
COPY . /app

# Default: start API with reload so edits show up
CMD ["uvicorn","api:app","--host","0.0.0.0","--port","8000","--reload"]
