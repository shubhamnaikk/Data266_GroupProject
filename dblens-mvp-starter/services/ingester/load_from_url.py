#!/usr/bin/env python3
import argparse, os, sys, re, json, csv, gzip, zipfile, hashlib, tempfile
from urllib.parse import urlparse
import requests
try:
    import magic
    HAVE_MAGIC = True
except Exception:
    magic = None
    HAVE_MAGIC = False
import pandas as pd
import pyarrow.parquet as pq
import psycopg
from psycopg import sql

MAX_BYTES_DEFAULT = 250 * 1024 * 1024  # 250MB

def sanitize_identifier(name: str) -> str:
    name = str(name).strip().lower()
    name = re.sub(r'[^a-z0-9_]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    if not name:
        name = 'col'
    if re.match(r'^\d', name):
        name = '_' + name
    return name

def _looks_date(s: pd.Series) -> bool:
    sample = s.dropna().astype(str).head(200)
    if len(sample) > 10:
        sample = sample.sample(10, random_state=42)
    parsed = pd.to_datetime(sample, errors='coerce', utc=False)
    return parsed.notna().mean() >= 0.7

def map_dtype_to_pg(series: pd.Series) -> str:
    dtype = str(series.dtype)
    if dtype.startswith('int'):
        return 'bigint'
    if dtype.startswith('float'):
        return 'double precision'
    if dtype == 'bool':
        return 'boolean'
    if dtype.startswith('datetime64') or (dtype == 'object' and _looks_date(series)):
        # date-vs-timestamp heuristic kept simple
        return 'timestamp'
    return 'text'

def infer_schema(df: pd.DataFrame):
    cols, seen = [], set()
    for c in df.columns:
        name = sanitize_identifier(c)
        base, i = name, 1
        while name in seen:
            i += 1
            name = f"{base}_{i}"
        seen.add(name)
        cols.append((c, name, map_dtype_to_pg(df[c])))
    return cols

def sniff_format(url, explicit_format, tmp_path):
    if explicit_format and explicit_format != 'auto':
        return explicit_format.lower()
    mime = ''
    if HAVE_MAGIC:
        try: mime = magic.Magic(mime=True).from_file(tmp_path)
        except Exception: mime = ''
    ext = os.path.splitext(urlparse(url).path)[1].lower()
    if ext in ('.csv', '.tsv'): return 'csv'
    if ext in ('.parquet', '.pq'): return 'parquet'
    if ext in ('.json', '.ndjson'): return 'json'
    if 'parquet' in mime: return 'parquet'
    if 'json' in mime: return 'json'
    if 'csv' in mime or 'text/plain' in mime: return 'csv'
    return 'csv'
