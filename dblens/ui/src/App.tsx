import { useEffect, useState } from "react";

type Cand = { sql: string; safe: boolean; cost_ok: boolean };

function Badge({ ok, label }: { ok: boolean; label: string }) {
  const bg = ok ? "#e7f8ed" : "#fde8e8";
  const col = ok ? "#127a3a" : "#a11d1d";
  return (
    <span style={{ background: bg, color: col, borderRadius: 8, padding: "2px 8px", fontSize: 12, marginRight: 8 }}>
      {label}
    </span>
  );
}

// include API key from localStorage on all requests
function apiHeaders() {
  const k = localStorage.getItem("X_API_KEY");
  return k ? { "x-api-key": k } : {};
}

export default function App() {
  const [apiKey, setApiKey] = useState(localStorage.getItem("X_API_KEY") || "");
  const [err, setErr] = useState<string | null>(null);

  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [result, setResult] = useState<any>(null);
  const [plan, setPlan] = useState<any>(null);
  const [lint, setLint] = useState<any>(null);
  const [editSQL, setEditSQL] = useState<string>("");
  const [history, setHistory] = useState<any[]>([]);

  const fetchHistory = async () => {
    try {
      const r = await fetch("http://localhost:8000/v1/history/recent?limit=10", { headers: { ...apiHeaders() } });
      if (!r.ok) {
        setErr(`history failed: ${r.status}`);
        setHistory([]);
        return;
      }
      const j = await r.json();
      setErr(null);
      if (j.ok) setHistory(j.items || []);
    } catch (e: any) {
      setErr(`history error: ${e?.message || e}`);
    }
  };

  useEffect(() => {
    fetchHistory();
  }, []);

  const ask = async () => {
    try {
      setResult(null);
      setPlan(null);
      setLint(null);
      setEditSQL("");
      const r = await fetch("http://localhost:8000/v1/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...apiHeaders() },
        body: JSON.stringify({ question: q }),
      });
      if (!r.ok) {
        setErr(`ask failed: ${r.status}`);
        return;
      }
      const j = await r.json();
      setErr(null);
      setResp(j);
      if (j?.candidates?.[0]?.sql) setEditSQL(j.candidates[0].sql);
      fetchHistory();
    } catch (e: any) {
      setErr(`ask error: ${e?.message || e}`);
    }
  };

  const approve = async (sql: string) => {
    try {
      const r = await fetch("http://localhost:8000/v1/approve", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...apiHeaders() },
        body: JSON.stringify({ sql }),
      });
      if (!r.ok) {
        setErr(`approve failed: ${r.status}`);
        return;
      }
      setErr(null);
      setResult(await r.json());
    } catch (e: any) {
      setErr(`approve error: ${e?.message || e}`);
    }
  };

  const explain = async (sql: string) => {
    try {
      setPlan(null);
      const r = await fetch("http://localhost:8000/v1/explain", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...apiHeaders() },
        body: JSON.stringify({ sql }),
      });
      if (!r.ok) {
        setErr(`explain failed: ${r.status}`);
        return;
      }
      setErr(null);
      setPlan(await r.json());
    } catch (e: any) {
      setErr(`explain error: ${e?.message || e}`);
    }
  };

  const doLint = async () => {
    try {
      const r = await fetch("http://localhost:8000/v1/lint", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...apiHeaders() },
        body: JSON.stringify({ sql: editSQL }),
      });
      if (!r.ok) {
        setErr(`lint failed: ${r.status}`);
        return;
      }
      setErr(null);
      setLint(await r.json());
    } catch (e: any) {
      setErr(`lint error: ${e?.message || e}`);
    }
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif,system-ui", display: "grid", gridTemplateColumns: "2fr 1fr", gap: 24 }}>
      <div>
        <h1>DBLens MVP</h1>

        {/* API key input (only needed if server has API_KEY set) */}
        <div style={{ display: "flex", gap: 8, alignItems: "center", margin: "8px 0" }}>
          <input
            style={{ padding: 6 }}
            placeholder="API key (if required)"
            value={apiKey}
            onChange={(e) => {
              localStorage.setItem("X_API_KEY", e.target.value);
              setApiKey(e.target.value);
            }}
          />
          <button onClick={() => localStorage.setItem("X_API_KEY", apiKey)}>Save key</button>
        </div>

        {err && <div style={{ background: "#fde8e8", color: "#a11d1d", padding: 8, borderRadius: 8, margin: "8px 0" }}>Error: {err}</div>}

        <div style={{ display: "flex", gap: 8 }}>
          <input style={{ flex: 1, padding: 8 }} value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ask a question…" />
          <button onClick={ask} disabled={!q}>
            Ask
          </button>
        </div>

        {resp && (
          <div style={{ marginTop: 16 }}>
            <h3>Context tables</h3>
            <pre>{JSON.stringify(resp.context_tables, null, 2)}</pre>

            <h3>Candidate SQLs</h3>
            {resp.candidates.map((c: Cand, i: number) => (
              <div key={i} style={{ border: "1px solid #ddd", padding: 8, margin: "8px 0" }}>
                <code>{c.sql}</code>
                <div style={{ marginTop: 6 }}>
                  <Badge ok={c.safe} label={c.safe ? "safe" : "unsafe"} />
                  <Badge ok={c.cost_ok} label={c.cost_ok ? "cost-ok" : "cost-high"} />
                </div>
                <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                  <button onClick={() => explain(c.sql)}>Explain</button>
                  <button onClick={() => approve(c.sql)} disabled={!c.safe || !c.cost_ok}>
                    Approve & Run
                  </button>
                </div>
              </div>
            ))}

            <h3>Edit & Lint</h3>
            <textarea
              value={editSQL}
              onChange={(e) => setEditSQL(e.target.value)}
              rows={4}
              style={{ width: "100%", fontFamily: "monospace", padding: 8 }}
              placeholder="Edit SQL here..."
            />
            <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
              <button onClick={doLint}>Lint Edited</button>
              <button onClick={() => approve(editSQL)}>Approve Edited</button>
            </div>
            {lint && (
              <div style={{ marginTop: 8 }}>
                <Badge ok={!!lint.safe} label={lint.safe ? "safe" : "unsafe"} />
                <Badge ok={!!lint.cost_ok} label={lint.cost_ok ? "cost-ok" : "cost-high"} />
                <pre>{JSON.stringify(lint, null, 2)}</pre>
              </div>
            )}

            <h3>Preview (top passing)</h3>
            <pre>{JSON.stringify(resp.preview, null, 2)}</pre>
          </div>
        )}

        {plan && (
          <div style={{ marginTop: 16 }}>
            <h3>Explain</h3>
            <pre>{JSON.stringify(plan, null, 2)}</pre>
          </div>
        )}

        {result && (
          <div style={{ marginTop: 16 }}>
            <h3>Full result</h3>
            <pre>{JSON.stringify(result, null, 2)}</pre>
          </div>
        )}
      </div>

      <div>
        <h2>History</h2>
        <button onClick={fetchHistory} style={{ marginBottom: 8 }}>
          Refresh
        </button>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {history.map((h: any) => (
            <div key={h.id} style={{ border: "1px solid #ddd", padding: 8 }}>
              <div style={{ fontSize: 12, opacity: 0.8 }}>
                #{h.id} · {new Date(h.ts * 1000).toLocaleString()}
              </div>
              <div style={{ fontWeight: 600 }}>{h.question}</div>
              <div style={{ marginTop: 6 }}>
                <Badge ok={!!h.safe} label={h.safe ? "safe" : "unsafe"} />
                <Badge ok={!!h.cost_ok} label={h.cost_ok ? "cost-ok" : "cost-high"} />
                <span style={{ fontSize: 12, marginLeft: 8 }}>rows: {h.preview_rows}</span>
              </div>
              <pre style={{ whiteSpace: "pre-wrap" }}>{h.top_sql}</pre>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
