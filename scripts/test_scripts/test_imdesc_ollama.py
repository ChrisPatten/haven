#!/usr/bin/env python3
"""
Quick integration tester for imdesc + Ollama.

Usage: scripts/test_imdesc_ollama.py /path/to/image.jpg [--imdesc /path/to/imdesc] [--ollama http://localhost:11434/api/generate] [--model qwen2.5vl]

Examples:
    # Use system-installed `imdesc` and default Ollama URL/model
    scripts/test_imdesc_ollama.py ~/Pictures/photo.jpg

    # Specify a local imdesc binary and Ollama model
    scripts/test_imdesc_ollama.py ~/Pictures/photo.jpg --imdesc /usr/local/bin/imdesc --ollama http://localhost:11434/api/generate --model qwen2.5vl

Behavior:
    - Calls the `imdesc` CLI with `--format json` and pretty-prints OCR results.
    - Posts the image bytes to the Ollama generate API to request a concise caption.
    - Prints both outputs in a human-friendly format.
"""
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Optional

import requests


def run_imdesc(imdesc_exec: str, image_path: Path, timeout: float = 15.0) -> Optional[Dict[str, Any]]:
    try:
        completed = subprocess.run(
            [imdesc_exec, str(image_path)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=True,
        )
    except FileNotFoundError:
        print(f"imdesc executable not found: {imdesc_exec}", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        print(f"imdesc timed out after {timeout}s", file=sys.stderr)
        return None
    except subprocess.CalledProcessError as exc:
        print(f"imdesc failed (rc={exc.returncode}): {exc.stderr}", file=sys.stderr)
        return None

    output = (completed.stdout or "").strip()
    if not output:
        print("imdesc returned no output", file=sys.stderr)
        return None

    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        print("imdesc returned invalid JSON:\n", output, file=sys.stderr)
        return None

    if not isinstance(data, dict):
        print("imdesc returned unexpected JSON shape", file=sys.stderr)
        return None

    return data


def request_ollama_caption(ollama_url: str, model: str, image_path: Path, timeout: float = 20.0) -> Optional[str]:
    try:
        image_bytes = image_path.read_bytes()
    except FileNotFoundError:
        print(f"image not found: {image_path}", file=sys.stderr)
        return None
    except Exception as exc:
        print(f"failed to read image: {exc}", file=sys.stderr)
        return None

    image_b64 = base64.b64encode(image_bytes).decode("utf-8")
    payload = {
        "model": model,
        "prompt": "describe the image scene and contents. ignore text. short response",
        "images": [image_b64],
        "stream": False,
    }

    try:
        resp = requests.post(ollama_url, json=payload, timeout=timeout)
        resp.raise_for_status()
    except requests.RequestException as exc:
        print(f"ollama request failed: {exc}", file=sys.stderr)
        return None

    try:
        data = resp.json()
    except ValueError:
        print("ollama returned invalid JSON", file=sys.stderr)
        return None

    caption = data.get("response")
    if isinstance(caption, str) and caption.strip():
        return caption.strip()

    message = data.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content.strip()

    # Fallback: try text body
    text = data.get("text")
    if isinstance(text, str) and text.strip():
        return text.strip()

    return None


def pretty_print_imdesc(data: Dict[str, Any]) -> None:
    text = data.get("text") or ""
    boxes = data.get("boxes") or []
    entities = data.get("entities") or {}

    print("=== imdesc OCR result ===")
    if text:
        print("Text:")
        print(text)
    else:
        print("No OCR text found")

    if boxes:
        print(f"\n{len(boxes)} bounding box(es):")
        for i, b in enumerate(boxes, start=1):
            try:
                x = b.get("x")
                y = b.get("y")
                w = b.get("w")
                h = b.get("h")
                print(f" {i}. x={x:.4f} y={y:.4f} w={w:.4f} h={h:.4f}")
            except Exception:
                print(f" {i}. {b}")
    else:
        print("No bounding boxes")

    if entities:
        print("\nEntities:")
        for key, vals in entities.items():
            if not vals:
                continue
            print(f" {key}: {', '.join(str(v) for v in vals)}")


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Test imdesc + Ollama integration")
    parser.add_argument("image", type=Path, help="Path to the image file to analyze")
    parser.add_argument("--imdesc", default="imdesc", help="Path to imdesc executable (default: imdesc)")
    parser.add_argument("--ollama", default="http://localhost:11434/api/generate", help="Ollama generate API URL")
    parser.add_argument("--model", default="qwen2.5vl", help="Ollama vision model name")
    parser.add_argument("--no-ollama", action="store_true", help="Skip calling Ollama, only run imdesc")
    args = parser.parse_args(argv)

    image_path = args.image
    if not image_path.exists():
        print(f"image does not exist: {image_path}", file=sys.stderr)
        return 2

    imdesc_data = run_imdesc(args.imdesc, image_path)
    if imdesc_data is None:
        print("imdesc failed or returned no data", file=sys.stderr)
    else:
        pretty_print_imdesc(imdesc_data)

    if args.no_ollama:
        return 0

    print("\n=== Ollama caption ===")
    caption = request_ollama_caption(args.ollama, args.model, image_path)
    if caption:
        print(caption)
    else:
        print("(no caption returned)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
