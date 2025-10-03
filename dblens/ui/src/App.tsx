import { useState } from "react";

export default function App() {
  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [result, setResult] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const ask = async () => {
    setLoading(true); setResult(null);
    const r = await fetch("http://localhost:8000/v1/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: q }),
    });
    setResp(await r.json());
    setLoading(false);
  };

  const approve = async (sql: string) => {
    const r = await fetch("http://localhost:8000/v1/approve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql }),
    });
    setResult(await r.json());
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif,system-ui" }}>
      <h1>DBLens MVP</h1>
      <div style={{ display: "flex", gap: 8 }}>
        <input style={{ flex: 1, padding: 8 }} value={q} onChange={(e)=>setQ(e.target.value)} placeholder="Ask a question…" />
        <button onClick={ask} disabled={!q || loading}>{loading ? "Thinking…" : "Ask"}</button>
      </div>

      {resp && (
        <div style={{ marginTop: 16 }}>
          <h3>Context tables</h3>
          <pre>{JSON.stringify(resp.context_tables, null, 2)}</pre>

          <h3>Candidate SQLs</h3>
          {resp.candidates.map((c: any, i: number) => (
            <div key={i} style={{ border: "1px solid #ddd", padding: 8, margin: "8px 0" }}>
              <code>{c.sql}</code>
              <div>safe: {String(c.safe)} | cost_ok: {String(c.cost_ok)}</div>
              <button onClick={()=>approve(c.sql)} disabled={!c.safe || !c.cost_ok}>Approve & Run</button>
            </div>
          ))}

          <h3>Preview (top passing)</h3>
          <pre>{JSON.stringify(resp.preview, null, 2)}</pre>
        </div>
      )}

      {result && (
        <div style={{ marginTop: 16 }}>
          <h3>Full result</h3>
          <pre>{JSON.stringify(result, null, 2)}</pre>
        </div>
      )}
    </div>
  );
}
