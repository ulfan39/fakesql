#!/usr/bin/env python3
"""Installs the FakeSQL library (schema fk) into a PostgreSQL database.

    DATABASE_URL=postgresql://user:pass@host/db?sslmode=require python tools/install_db.py
"""
import os
import sys
from pathlib import Path

import psycopg

url = os.environ.get("DATABASE_URL") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not url:
    sys.exit("set DATABASE_URL or pass the connection string as an argument")
files = sorted((Path(__file__).resolve().parent.parent / "db").glob("0*.sql"))
with psycopg.connect(url, autocommit=True) as conn:
    for f in files:
        print("running", f.name, flush=True)
        conn.execute(f.read_text(encoding="utf-8"))
    n = conn.execute("SELECT count(*) FROM fk.names").fetchone()[0]
    print(f"done: {n} names loaded")
