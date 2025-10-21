#!/usr/bin/env python3
"""Generate a markdown file listing beads backlog (excluding open tasks).

This script depends on the `bd` CLI being available in PATH and the
workspace being initialized (bd init or similar). It calls `bd list` to
retrieve issues and writes `docs/beads_backlog.md` with a table and
per-issue details including dependencies, labels, priority, and links.

If the MCP beads server were available, an alternative would be to call
the MCP API directly. Using the CLI keeps it simple and local.
"""
import json
import shutil
import subprocess
import sys
from datetime import datetime
from typing import List, Dict, Any

OUT_PATH = "docs/beads_backlog.md"


def run_bd_list() -> List[Dict[str, Any]]:
    bd = shutil.which("bd")
    if not bd:
        print("Error: `bd` CLI not found in PATH. Install or add to PATH.", file=sys.stderr)
        sys.exit(2)

    # Use JSON output if available. Fallback to plain list parsing.
    try:
        proc = subprocess.run([bd, "list", "--json"], capture_output=True, text=True, check=True)
        data = json.loads(proc.stdout)
        return data
    except subprocess.CalledProcessError as e:
        print("bd list failed:", e.stderr or e.stdout, file=sys.stderr)
        sys.exit(3)
    except json.JSONDecodeError:
        print("bd list did not return JSON. Please ensure your bd supports --json.", file=sys.stderr)
        sys.exit(4)


def filter_closed(issues: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    # Exclude only 'closed' issues (keep 'open', 'in_progress', 'blocked', etc.)
    return [i for i in issues if i.get("status") != "closed"]


def sort_by_id_asc(issues: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    def key_fn(item: Dict[str, Any]):
        id_ = item.get("id") or item.get("issue_id") or item.get("name") or ""
        # try to extract trailing numeric suffix after the last '-'
        try:
            if "-" in id_:
                suffix = id_.rsplit("-", 1)[1]
                return (0, int(suffix))
            return (1, str(id_))
        except Exception:
            return (1, str(id_))

    return sorted(issues, key=key_fn)


def format_issue_md(issue: Dict[str, Any]) -> str:
    id_ = issue.get("id") or issue.get("issue_id") or issue.get("name")
    title = issue.get("title") or issue.get("name")
    status = issue.get("status")
    priority = issue.get("priority")
    labels = issue.get("labels") or []
    deps = issue.get("dependencies") or issue.get("deps") or []
    description = issue.get("description") or ""
    md = []
    md.append(f"### {id_} - {title}")
    md.append("")
    md.append(f"Status: **{status}**")
    if priority:
        md.append("")
        md.append(f"Priority: **{priority}**")
    if labels:
        md.append("")
        md.append(f"Labels: {', '.join(labels)}")
    if deps:
        dep_list = []
        for d in deps:
            # deps may be dicts or strings
            if isinstance(d, dict):
                dep_id = d.get("issue") or d.get("id") or str(d)
            else:
                dep_id = str(d)
            dep_list.append(str(dep_id))
        md.append("")
        md.append(f"Depends on: {', '.join(dep_list)}")

    # include the full description as a fenced code block in this same section
    md.append("")
    md.append("```md")
    md.append(description)
    md.append("```")
    md.append("---")
    md.append("")
    return "\n".join(md)
def generate_markdown(issues: List[Dict[str, Any]]) -> str:
    header = [
        "# Beads backlog (snapshot)",
        "",
        f"_Generated: {datetime.utcnow().isoformat()}Z_",
        "",
        "This file lists beads issues in the backlog. Use the table of contents to navigate to specific items.",
        "",
    ]

    if not issues:
        header.append("No backlog items found.")
        return "\n".join(header) + "\n"

    # Details only; rely on MkDocs/TOC to provide navigation
    details = ["## Details", ""]
    for i in issues:
        details.append(format_issue_md(i))

    return "\n".join(header + details) + "\n"


def main() -> int:
    issues = run_bd_list()
    backlog = filter_closed(issues)
    backlog = sort_by_id_asc(backlog)
    md = generate_markdown(backlog)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write(md)
    print(f"Wrote {OUT_PATH} with {len(backlog)} items.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
