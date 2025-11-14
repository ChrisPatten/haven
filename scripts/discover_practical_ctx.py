import json
import math
import time
import requests

# ----------------- CONFIG -----------------

OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_SHOW_URL = "http://localhost:11434/api/show"
MODEL = "qwen2.5vl:3b"


# Smallest and largest ctx to search over
MIN_CTX = 4096

# Number of approximate tokens in a test prompt
# (roughly 50% of the context being tested)
TEST_TOKENS_FRACTION = 0.95

# Timeout for each HTTP request (seconds)
REQUEST_TIMEOUT = 120

# Pause between tests (seconds)
PAUSE_BETWEEN_TESTS = 0.3


# ----------------- HELPERS -----------------
def get_model_max_ctx(model: str) -> int:
    """
    Query Ollama /api/show to discover the model's configured context limit.

    For your llama3.2 response, this comes from:
      model_info["llama.context_length"] == 131072

    More generally, this scans model_info and details for any key that
    looks like a context-length field.
    """
    resp = requests.post(OLLAMA_SHOW_URL, json={"model": model}, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    data = resp.json()

    candidates = []

    # 1. Look in model_info for keys like "*.context_length", "ctx_len", "num_ctx"
    mi = data.get("model_info") or {}
    for key, val in mi.items():
        key_lower = key.lower()
        if (
            "context_length" in key_lower
            or "ctx_len" in key_lower
            or key_lower.endswith(".ctx")
            or key_lower.endswith(".num_ctx")
        ):
            try:
                candidates.append(int(val))
            except (TypeError, ValueError):
                pass

    # 2. Look in details as a fallback (some builds may expose it there)
    details = data.get("details") or {}
    for key, val in details.items():
        key_lower = key.lower()
        if (
            "context_length" in key_lower
            or "ctx_len" in key_lower
            or key_lower.endswith("ctx")
            or key_lower.endswith("num_ctx")
        ):
            try:
                candidates.append(int(val))
            except (TypeError, ValueError):
                pass

    # 3. (Optional) parse parameters if Ollama returns it as a dict in other versions.
    # In your response, `parameters` is a flat string, so this will just be skipped.
    params = data.get("parameters")
    if isinstance(params, dict):
        for key, val in params.items():
            key_lower = key.lower()
            if "num_ctx" in key_lower or "context" in key_lower:
                try:
                    candidates.append(int(val))
                except (TypeError, ValueError):
                    pass

    if not candidates:
        raise RuntimeError(
            f"Could not find a context limit for model '{model}' "
            f"in /api/show response (keys seen in model_info: {list(mi.keys())})"
        )

    max_ctx = max(candidates)
    return max_ctx

# ----------------- CORE LOGIC -----------------


def make_prompt(approx_tokens: int) -> str:
    """
    Generate a dummy prompt with roughly `approx_tokens` tokens.
    For LLaMA-style tokenizers, 1 word ≈ 1 token, so we just repeat a word.
    """
    # Ensure minimum of 512 tokens for testing
    approx_tokens = max(approx_tokens, 512)
    # Avoid huge join overhead by using repetition
    # The trailing space is fine; tokenizer will handle it.
    return ("word " * approx_tokens).strip()


def probe_context_size(num_ctx: int):
    """
    Test a given num_ctx by sending a prompt with the specified fraction of tokens
    and checking for:
      - API / stream errors
      - Successful completion
      - Reported context length
    Returns:
      (success: bool, details: dict)
    """
    probe_start_time = time.time()
    target_tokens = int(num_ctx * TEST_TOKENS_FRACTION)
    prompt = make_prompt(target_tokens)

    payload = {
        "model": MODEL,
        "num_ctx": num_ctx,
        "prompt": prompt,
        # Keep generation tiny so we're mostly testing prompt+ctx, not output
        "options": {
            "num_predict": 4
        }
    }

    test_start_time = time.time()

    try:
        resp = requests.post(
            OLLAMA_URL,
            json=payload,
            stream=True,
            timeout=REQUEST_TIMEOUT,
        )
    except Exception as e:
        elapsed = time.time() - test_start_time
        return False, {
            "stage": "request_error",
            "num_ctx": num_ctx,
            "target_tokens": target_tokens,
            "error": str(e),
            "elapsed_seconds": elapsed,
        }

    if resp.status_code != 200:
        elapsed = time.time() - test_start_time
        return False, {
            "stage": "http_status",
            "num_ctx": num_ctx,
            "target_tokens": target_tokens,
            "status_code": resp.status_code,
            "text": resp.text[:1000],
            "elapsed_seconds": elapsed,
        }

    context_len = None
    saw_done = False
    error_msg = None

    for line in resp.iter_lines():
        if not line:
            continue

        try:
            obj = json.loads(line.decode("utf-8"))
        except Exception:
            # Ignore malformed lines; keep going
            continue

        if "error" in obj:
            error_msg = obj["error"]
            break

        if obj.get("done"):
            saw_done = True
            ctx = obj.get("context")
            if isinstance(ctx, list):
                context_len = len(ctx)
            break

    elapsed = time.time() - test_start_time

    if error_msg:
        return False, {
            "stage": "stream_error",
            "num_ctx": num_ctx,
            "target_tokens": target_tokens,
            "error": error_msg,
            "elapsed_seconds": elapsed,
        }

    if not saw_done:
        return False, {
            "stage": "no_done",
            "num_ctx": num_ctx,
            "target_tokens": target_tokens,
            "info": "Stream ended without done=true",
            "elapsed_seconds": elapsed,
        }

    total_probe_time = time.time() - probe_start_time

    return True, {
        "num_ctx": num_ctx,
        "target_tokens": target_tokens,
        "context_len_reported": context_len,
        "elapsed_seconds": elapsed,
        "total_elapsed_seconds": total_probe_time,
    }


def binary_search_max_ctx():
    """
    Binary search for the maximum num_ctx that:
      - Does not error out
      - Handles prompts at multiple payload sizes for that ctx
    """
    low = MIN_CTX
    high = get_model_max_ctx(MODEL)
    best_success = None
    best_details = None
    search_start_time = time.time()

    print(f"Starting binary search for practical num_ctx between {MIN_CTX} and {high}")
    print(f"Model: {MODEL}\n")

    while low <= high:
        mid = int(math.floor((low + high) / 2 / 1024) * 1024)
        mid = max(mid, MIN_CTX)

        print(f"Testing num_ctx={mid} ...")
        ok, details = probe_context_size(mid)

        if ok:
            elapsed = details.get("elapsed_seconds", 0)
            print(f"  SUCCESS at num_ctx={mid} (took {elapsed:.2f}s)")
            print(
                f"    target_tokens≈{details['target_tokens']}, "
                f"context_len_reported={details['context_len_reported']}"
            )
            best_success = mid
            best_details = details
            low = mid + 1024
        else:
            elapsed = details.get("elapsed_seconds", 0)
            print(f"  FAILURE at num_ctx={mid} (took {elapsed:.2f}s)")
            print(f"    stage={details.get('stage')}, error/info={details.get('error') or details.get('info')}")
            high = mid - 1024

        print()

    search_total_time = time.time() - search_start_time
    return best_success, best_details, search_total_time


def main():

    print(f"Warmin up model {MODEL}...")
    warmup_start_time = time.time()
    payload = {
        "model": MODEL,
        "prompt": "Hello, world!",
        "options": {
            "num_predict": 4
        }
    }
    try:
        resp = requests.post(OLLAMA_URL, json=payload, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
    except Exception as e:
        print(f"Error warming up model {MODEL}: {e}")
        return
    print(f"Model {MODEL} warmed up in {time.time() - warmup_start_time:.2f}s")
    
    main_start_time = time.time()
    best_ctx, details, search_time = binary_search_max_ctx()

    print("\n================ FINAL RESULT ================\n")
    if best_ctx is None:
        print("Could not find any working num_ctx in the given range.")
        total_time = time.time() - main_start_time
        print(f"\nTotal elapsed time: {total_time:.2f}s")
        return

    print(f"Best practical num_ctx on this machine: {best_ctx}")
    print("\nTest result at that setting:")
    print(
        f"  target_tokens≈{details['target_tokens']}, "
        f"context_len_reported={details['context_len_reported']}, "
        f"time={details['elapsed_seconds']:.2f}s"
    )

    print("\nInterpretation:")
    print("  - If this best num_ctx is close to the model max (131072), your hardware can likely handle the full window.")
    print("  - If it is much lower, that value is a good 'practical' context limit to use in real workloads.")

    total_time = time.time() - main_start_time
    print(f"\nTiming summary:")
    print(f"  Search phase: {search_time:.2f}s")
    print(f"  Total elapsed: {total_time:.2f}s")


if __name__ == "__main__":
    main()