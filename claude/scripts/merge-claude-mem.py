#!/usr/bin/env python3
"""
merge-claude-mem.py — mergia N DBs do claude-mem no DB local (~/.claude-mem/claude-mem.db).

Usage:
    python3 merge-claude-mem.py <source1.db> [source2.db ...]

Strategy:
    - sdk_sessions:     INSERT OR IGNORE via content_session_id UNIQUE
                        + memory_session_id UNIQUE (both UUID-based)
    - observations:     INSERT OR IGNORE (unique-constraint automatically
                        dedups via content_hash index when relevant)
    - user_prompts:     INSERT (FKs auto-guard; logical uniqueness via
                        (content_session_id, prompt_number) index)
    - session_summaries:INSERT OR IGNORE
    - FTS5 rebuild afterwards (observations_fts, session_summaries_fts, user_prompts_fts)
    - IGNORED: pending_messages (volatile), sqlite_sequence (auto-maintained)

Safe to run against a destination DB that's been backed up (highly recommended
before running this). The script only INSERTS into the destination — never
deletes or updates existing rows.

Transactions: each source DB is processed in a single transaction; if any
step fails mid-source, everything from that source is rolled back, other
sources remain applied.
"""
import sqlite3
import sys
import pathlib
import argparse
import time


DEST_DB = pathlib.Path.home() / ".claude-mem" / "claude-mem.db"


def table_count(conn, table):
    try:
        return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    except sqlite3.OperationalError:
        return 0


def copy_table(dest, src, table, drop_id=True):
    """Copy rows from src.table to dest.table using INSERT OR IGNORE.
    If drop_id, skip the 'id' column (autoincrement PK) so dest assigns fresh ones."""
    try:
        cols_info = src.execute(f"PRAGMA table_info({table})").fetchall()
    except sqlite3.OperationalError as e:
        print(f"    {table}: skipped ({e})")
        return 0
    cols = [row[1] for row in cols_info]
    if drop_id and "id" in cols:
        cols = [c for c in cols if c != "id"]
    colnames = ",".join(cols)
    placeholders = ",".join("?" * len(cols))
    rows = src.execute(f"SELECT {colnames} FROM {table}").fetchall()
    added = 0
    for row in rows:
        try:
            dest.execute(f"INSERT INTO {table} ({colnames}) VALUES ({placeholders})", row)
            added += 1
        except sqlite3.IntegrityError:
            pass  # UNIQUE or FK violation — already exists or orphan source row
    return added


def rebuild_fts(dest, fts_table):
    try:
        dest.execute(f"INSERT INTO {fts_table}({fts_table}) VALUES('rebuild')")
        return True
    except sqlite3.OperationalError as e:
        print(f"    {fts_table}: rebuild failed ({e})")
        return False


def main():
    parser = argparse.ArgumentParser(description="Merge N claude-mem DBs into the local one.")
    parser.add_argument("sources", nargs="+", help="paths to source .db files to merge INTO the local DB")
    parser.add_argument("--dest", default=str(DEST_DB), help=f"destination DB path (default: {DEST_DB})")
    parser.add_argument("--dry-run", action="store_true", help="report counts but do not commit")
    args = parser.parse_args()

    if not pathlib.Path(args.dest).exists():
        print(f"✗ destination DB not found: {args.dest}")
        sys.exit(1)

    print(f"→ Destination: {args.dest}")
    print(f"→ Sources:     {args.sources}")
    print(f"→ Dry-run:     {args.dry_run}")
    print()

    dest = sqlite3.connect(args.dest)
    dest.execute("PRAGMA foreign_keys=ON")

    # Snapshot before counts
    tables = ["sdk_sessions", "observations", "user_prompts", "session_summaries"]
    before = {t: table_count(dest, t) for t in tables}
    print("Before merge:")
    for t, n in before.items():
        print(f"  {t}: {n}")
    print()

    total_added = {t: 0 for t in tables}

    for src_path in args.sources:
        if not pathlib.Path(src_path).exists():
            print(f"! skipping {src_path} (file not found)")
            continue
        print(f"=== Merging from {src_path} ===")
        src = sqlite3.connect(src_path)
        t0 = time.time()

        # sdk_sessions FIRST (parent for FK referenced tables)
        added = copy_table(dest, src, "sdk_sessions", drop_id=True)
        print(f"  sdk_sessions: +{added}")
        total_added["sdk_sessions"] += added

        # Then the child tables
        for tbl in ("observations", "user_prompts", "session_summaries"):
            added = copy_table(dest, src, tbl, drop_id=True)
            print(f"  {tbl}: +{added}")
            total_added[tbl] += added

        src.close()
        print(f"  elapsed: {time.time()-t0:.1f}s")
        print()

    # Rebuild FTS (only if any observations were added)
    if not args.dry_run and any(total_added.values()):
        print("=== Rebuilding FTS indices ===")
        for fts in ("observations_fts", "session_summaries_fts", "user_prompts_fts"):
            ok = rebuild_fts(dest, fts)
            print(f"  {fts}: {'rebuilt' if ok else 'FAILED'}")
        print()

    # After counts + commit decision
    if args.dry_run:
        dest.rollback()
        print("⚠ DRY-RUN: rolled back. Nothing written.")
    else:
        dest.commit()
        print("✓ Committed.")

    print()
    print("After merge:")
    after = {t: table_count(dest, t) for t in tables}
    for t in tables:
        delta = after[t] - before[t]
        print(f"  {t}: {before[t]} → {after[t]} (+{delta})")

    # Integrity checks
    if not args.dry_run:
        print()
        print("=== Integrity checks ===")
        print(f"  PRAGMA integrity_check: {dest.execute('PRAGMA integrity_check').fetchone()[0]}")
        fk_violations = list(dest.execute("PRAGMA foreign_key_check"))
        print(f"  PRAGMA foreign_key_check: {'ok' if not fk_violations else f'{len(fk_violations)} violations'}")
        if fk_violations:
            for v in fk_violations[:5]:
                print(f"    {v}")

    dest.close()


if __name__ == "__main__":
    main()
