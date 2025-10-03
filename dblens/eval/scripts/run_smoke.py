import time, json, requests

SMOKES = ["How many rows are in the items table?", "List 2 cheapest items."]

for q in SMOKES:
    t0 = time.time()
    r = requests.post("http://localhost:8000/v1/ask", json={"question": q}, timeout=30)
    dt = time.time() - t0
    print(json.dumps({"q": q, "latency_s": round(dt, 3), "status": r.status_code}))
    if r.ok:
        print(json.dumps(r.json(), indent=2))
