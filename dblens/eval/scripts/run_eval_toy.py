import time
import json
import requests
import statistics as stats

QS = [
    "Show 5 rows from items",
    "How many rows are in items?",
    "List items with price < 1",
]


def ask(q: str):
    t0 = time.time()
    r = requests.post("http://localhost:8000/v1/ask", json={"question": q}, timeout=60)
    dt = time.time() - t0
    try:
        j = r.json()
        ok_any = any(
            c.get("safe") and c.get("cost_ok") for c in j.get("candidates", [])
        )
        print(
            json.dumps(
                {"q": q, "latency_s": round(dt, 2), "has_safe": ok_any}, indent=2
            )
        )
        return dt, ok_any, j
    except Exception:
        print(
            json.dumps(
                {
                    "q": q,
                    "latency_s": round(dt, 2),
                    "status": r.status_code,
                    "non_json_body_start": r.text[:400],
                },
                indent=2,
            )
        )
        return dt, False, None


latencies: list[float] = []
oks = 0
for q in QS:
    dt, ok, _ = ask(q)
    latencies.append(dt)
    oks += int(ok)
    time.sleep(0.6)  # gentle backoff

print(
    "p50 latency:",
    round(stats.median(latencies), 2),
    "s; valid-SQL rate:",
    f"{100*oks/len(QS):.0f}%",
)
