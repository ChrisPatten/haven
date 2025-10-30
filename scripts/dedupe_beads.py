#!/usr/bin/env python3
"""
Deduplicate beads JSONL by title.

Usage:
  python3 scripts/dedupe_beads.py [path/to/beads.jsonl]

Outputs:
  - A newline-separated list of bead IDs to delete to `.tmp/beads_to_delete.md`.
  - Optionally writes a deduplicated JSONL of kept items via `--out-jsonl`.

Notes:
  - If no file path is provided, this will run `bd export --format jsonl` to
    create an export at `.tmp/beads_export.jsonl` and operate on that file.
  - Only the earliest bead (by created_at, then file order) for each title is kept.
"""
import argparse
import json
import os
import subprocess
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
    p.add_argument("file", nargs="?", default=None, help="Optional path to an existing beads JSONL file. If omitted, the script will run 'bd export' and use the exported file.")
    p.add_argument("-o", "--output", default=".tmp/beads_to_delete.md", help="Output file path (one id per line)")
    p.add_argument("--out-jsonl", default=None, help="Optional path to write deduplicated JSONL of kept items")
    p.add_argument("--export-path", default=".tmp/beads_export.jsonl", help="Where to write the JSONL exported by 'bd export' when no file is provided")
    args = p.parse_args()

    groups = defaultdict(list)
    infile = args.file
    # If no input file is provided, export via `bd export` first
    if infile is None:
        export_path = args.export_path
        export_dir = os.path.dirname(export_path)
        if export_dir and not os.path.exists(export_dir):
            os.makedirs(export_dir, exist_ok=True)
        try:
            result = subprocess.run(
                ["bd", "export", "--format", "jsonl", "--output", export_path],
                check=True,
                capture_output=True,
                text=True,
            )
            if result.stdout:
                print(result.stdout.strip())
            if result.stderr:
                # Some CLIs emit progress on stderr; still show it
                print(result.stderr.strip())
        except FileNotFoundError:
            print("Error: 'bd' CLI not found on PATH. Please install 'bd' or provide an input file.")
            raise SystemExit(2)
        except subprocess.CalledProcessError as e:
            print("Error: 'bd export' failed.")
            if e.stdout:
                print(e.stdout.strip())
            if e.stderr:
                print(e.stderr.strip())
            raise SystemExit(e.returncode)
        infile = export_path
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

    # Determine duplicates and identify items to keep/delete
    ids_to_delete = []
    keep_lines = set()
    
    def get_numeric_id(id_str):
        """Extract numeric part of ID (e.g., 'hv-27' -> 27)"""
        if not id_str:
            return float('inf')  # treat missing IDs as highest value
        try:
            return int(id_str.split('-')[1])
        except (IndexError, ValueError):
            return float('inf')
    
    for title, items in groups.items():
        if len(items) <= 1:
            # keep the only item (if it has a line index)
            if items:
                keep_lines.add(items[0]["line"])
            continue
        # sort by numeric ID to find the lowest
        def keyfn(x):
            return get_numeric_id(x.get("id"))

        sorted_items = sorted(items, key=keyfn)
        # keep the first (lowest ID), delete the rest
        if sorted_items:
            keep_lines.add(sorted_items[0]["line"])
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

    # Optionally write a deduplicated JSONL containing only kept items
    if args.out_jsonl:
        out_jsonl_dir = os.path.dirname(args.out_jsonl)
        if out_jsonl_dir and not os.path.exists(out_jsonl_dir):
            os.makedirs(out_jsonl_dir, exist_ok=True)

        # Re-read and stream out only kept lines to preserve original formatting/order
        written = 0
        with open(infile, "r", encoding="utf-8") as inf, open(args.out_jsonl, "w", encoding="utf-8") as outf:
            for idx, raw in enumerate(inf, start=1):
                if idx in keep_lines:
                    # ensure single trailing newline per record
                    outf.write(raw.strip() + "\n")
                    written += 1
        print(f"Wrote deduplicated JSONL with {written} records to: {args.out_jsonl}")


if __name__ == "__main__":
    main()
