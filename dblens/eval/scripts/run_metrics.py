import csv
import time
import json
import requests
import statistics as stats


def run_suite(path="eval/data/demo_suite.csv"):
    rows = list(csv.DictReader(open(path)))
    latencies, ok_count = [], 0
    for r in rows:
        q = r["question"]
        t0 = time.time()
        resp = requests.post(
            "http://localhost:8000/v1/ask", json={"question": q}, timeout=60
        )
        dt = time.time() - t0
        try:
            j = resp.json()
            has_safe = any(
                c.get("safe") and c.get("cost_ok") for c in j.get("candidates", [])
            )
            latencies.append(dt)
            ok_count += int(has_safe)
            print(
                json.dumps(
                    {"q": q, "latency_s": round(dt, 2), "has_safe": has_safe}, indent=2
                )
            )
        except Exception:
            print(
                json.dumps(
                    {"q": q, "status": resp.status_code, "body_start": resp.text[:200]},
                    indent=2,
                )
            )
            latencies.append(dt)
    p50 = round(stats.median(latencies), 2)
    p95 = round(sorted(latencies)[max(0, int(len(latencies) * 0.95) - 1)], 2)
    rate = round(100 * ok_count / len(rows))
    print(f"p50: {p50}s, p95: {p95}s, valid-SQL rate: {rate}%")


if __name__ == "__main__":
    run_suite()
