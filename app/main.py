"""FakeSQL web app: renders HTML and reads fake users from PostgreSQL stored
routines.  All data generation happens in the database (see db/*.sql)."""
import hashlib
import os
import re
import threading
from pathlib import Path

import markdown
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

ROOT = Path(__file__).resolve().parent
DOC_FILE = ROOT / "DOCUMENTATION.md"
if not DOC_FILE.exists():
    DOC_FILE = ROOT.parent / "DOCUMENTATION.md"

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres@/fake?host=/tmp&port=5433")
pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=4, open=False,
                      kwargs={"row_factory": dict_row, "autocommit": True}, timeout=30)

app = FastAPI(title="FakeSQL", docs_url=None, redoc_url=None, openapi_url=None)
_bench_lock = threading.Lock()


@app.on_event("startup")
def _open_pool():
    pool.open(wait=False)


def seed_to_int(raw: str) -> int:
    """Numbers are used as they are; any other text is hashed to a 63-bit integer."""
    raw = (raw or "").strip()
    if re.fullmatch(r"-?\d{1,18}", raw):
        return int(raw)
    return int.from_bytes(hashlib.sha256(raw.encode()).digest()[:8], "big") & 0x7FFFFFFFFFFFFFFF


@app.get("/api/health")
def health():
    with pool.connection() as c:
        n = c.execute("SELECT count(*) AS n FROM fk.locales").fetchone()["n"]
    return {"ok": True, "locales": n}


@app.get("/api/locales")
def locales():
    with pool.connection() as c:
        return c.execute("SELECT code, title FROM fk.locales ORDER BY title").fetchall()


@app.get("/api/users")
def users(locale: str = Query("en_US", max_length=16), seed: str = Query("1", max_length=40),
          batch: int = Query(0, ge=0, le=10_000_000), size: int = Query(10, ge=1, le=100)):
    seed_int = seed_to_int(seed)
    with pool.connection() as c:
        if not c.execute("SELECT 1 FROM fk.locales WHERE code = %s", (locale,)).fetchone():
            raise HTTPException(404, "unknown locale")
        t0 = c.execute("SELECT clock_timestamp() AS t").fetchone()["t"]
        rows = c.execute("SELECT * FROM fk.generate_users(%s, %s, %s, %s)", (locale, seed_int, batch, size)).fetchall()
        t1 = c.execute("SELECT clock_timestamp() AS t").fetchone()["t"]
    for r in rows:
        r["gender"] = r["gender"].strip()
    return {"locale": locale, "seed": seed, "seed_value": seed_int, "batch": batch, "size": size,
            "users": rows, "db_ms": round((t1 - t0).total_seconds() * 1000, 1)}


@app.get("/api/benchmark")
def benchmark(locale: str = Query("en_US", max_length=16), n: int = Query(5000, ge=100, le=20000)):
    if not _bench_lock.acquire(blocking=False):
        return JSONResponse({"error": "a benchmark is already running"}, status_code=429)
    try:
        with pool.connection() as c:
            r = c.execute("SELECT * FROM fk.benchmark(%s, 1, %s)", (locale, n)).fetchone()
        return {"locale": locale, "users": r["users"], "seconds": float(r["seconds"]),
                "users_per_second": float(r["users_per_second"])}
    finally:
        _bench_lock.release()


@app.get("/docs", response_class=HTMLResponse)
def docs():
    body = markdown.markdown(DOC_FILE.read_text(encoding="utf-8"),
                             extensions=["tables", "fenced_code", "toc", "sane_lists"])
    page = (ROOT / "static" / "docs.html").read_text(encoding="utf-8")
    return page.replace("{{BODY}}", body)


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    from fastapi import Response
    return Response(status_code=204)


@app.get("/")
def index():
    return FileResponse(ROOT / "static" / "index.html")
