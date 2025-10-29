#!/usr/bin/env python3
"""
Deduplicate beads JSONL by title.

Usage:
  python3 scripts/dedupe_beads.py path/to/beads.jsonl

It writes a newline-separated list of bead IDs to delete to `.tmp/beads_to_delete.md`.
Only the earliest bead (by created_at, then file order) for each title is kept.
"""
import argparse
import json
import os
from collections import defaultdict
from datetime import datetime


def parse_created_at(s):
    if not s:
        return None
    try:
        # Python 3.7+ supports fromisoformat for most ISO timestamps including offsets
        return datetime.fromisoformat(s)
    except Exception:
        # fallback: try to strip fractional seconds or timezone if odd; return None
        try:
            return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
        except Exception:
            return None


def main():
    p = argparse.ArgumentParser(description="Find duplicate beads by title and emit IDs to delete")
    p.add_argument("file", help="Path to beads JSONL file")
    p.add_argument("-o", "--output", default=".tmp/beads_to_delete.md", help="Output file path (one id per line)")
    args = p.parse_args()

    groups = defaultdict(list)
    infile = args.file
    if not os.path.exists(infile):
        print(f"Input file not found: {infile}")
        raise SystemExit(2)

    with open(infile, "r", encoding="utf-8") as f:
        for idx, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                # skip invalid lines
                continue
            title = obj.get("title")
            created = obj.get("created_at")
            groups[title].append({
                "id": obj.get("id"),
                "created_at": created,
                "line": idx,
            })

    # Determine duplicates
    ids_to_delete = []
    for title, items in groups.items():
        if len(items) <= 1:
            continue
        # sort by created_at (parsed) then by line number
        def keyfn(x):
            dt = parse_created_at(x.get("created_at"))
            if dt is None:
                # push invalid/missing timestamps to the end by using min
                dt = datetime.min
            return (dt, x["line"]) 

        sorted_items = sorted(items, key=keyfn)
        # keep the first, delete the rest
        to_delete = [it["id"] for it in sorted_items[1:] if it.get("id")]
        ids_to_delete.extend(to_delete)

    # Ensure output dir exists
    out_dir = os.path.dirname(args.output)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    # Write one id per line, no extra text
    with open(args.output, "w", encoding="utf-8") as out:
        for _id in ids_to_delete:
            out.write(f"{_id}\n")

    print(f"Wrote {len(ids_to_delete)} ids to delete to: {args.output}")


if __name__ == "__main__":
    main()
