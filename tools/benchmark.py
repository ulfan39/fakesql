#!/usr/bin/env python3
"""Measures generation speed (users/second) of fk.benchmark().

    DATABASE_URL=postgresql://... python tools/benchmark.py [users]
"""
import os, sys, platform
import psycopg

url = os.environ.get("DATABASE_URL", "postgresql://postgres@/fake?host=/tmp&port=5433")
total = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
with psycopg.connect(url, autocommit=True) as c:
    ver = c.execute("SHOW server_version").fetchone()[0]
    print(f"PostgreSQL {ver}; client {platform.system()}; {total} users per run, 3 runs per locale/batch size\n")
    print("| locale | batch size | users | seconds | users/second |")
    print("|---|---|---|---|---|")
    for loc, in c.execute("SELECT code FROM fk.locales ORDER BY code").fetchall():
        for bs in (10, 1000):
            best = None
            for _ in range(3):
                r = c.execute("SELECT * FROM fk.benchmark(%s, 1, %s, %s)", (loc, total, bs)).fetchone()
                if best is None or r[2] > best[2]:
                    best = r
            print(f"| {loc} | {bs} | {best[0]} | {best[1]} | {int(best[2]):,} |")
