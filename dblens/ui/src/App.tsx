import { useState } from "react";

type Cand = { sql: string; safe: boolean; cost_ok: boolean };

function Badge({ok, label}:{ok:boolean; label:string}) {
  const bg = ok ? "#e7f8ed" : "#fde8e8";
  const col = ok ? "#127a3a" : "#a11d1d";
  return <span style={{background:bg,color:col,borderRadius:8,padding:"2px 8px",fontSize:12,marginRight:8}}>{label}</span>;
}

export default function App() {
  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [result, setResult] = useState<any>(null);
  const [plan, setPlan] = useState<any>(null);
  const [lint, setLint] = useState<any>(null);
  const [editSQL, setEditSQL] = useState<string>("");

  const ask = async () => {
    setResult(null); setPlan(null); setLint(null); setEditSQL("");
    const r = await fetch("http://localhost:8000/v1/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: q }),
    });
    const j = await r.json();
    setResp(j);
    if (j?.candidates?.[0]?.sql) setEditSQL(j.candidates[0].sql);
  };

  const approve = async (sql: string) => {
    const r = await fetch("http://localhost:8000/v1/approve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql }),
    });
    setResult(await r.json());
  };

  const explain = async (sql: string) => {
    setPlan(null);
    const r = await fetch("http://localhost:8000/v1/explain", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql }),
    });
    setPlan(await r.json());
  };

  const doLint = async () => {
    const r = await fetch("http://localhost:8000/v1/lint", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql: editSQL }),
    });
    setLint(await r.json());
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif,system-ui" }}>
      <h1>DBLens MVP</h1>
      <div style={{ display: "flex", gap: 8 }}>
        <input style={{ flex: 1, padding: 8 }} value={q} onChange={(e)=>setQ(e.target.value)} placeholder="Ask a question…" />
        <button onClick={ask} disabled={!q}>Ask</button>
      </div>

      {resp && (
        <div style={{ marginTop: 16 }}>
          <h3>Context tables</h3>
          <pre>{JSON.stringify(resp.context_tables, null, 2)}</pre>

          <h3>Candidate SQLs</h3>
          {resp.candidates.map((c: Cand, i: number) => (
            <div key={i} style={{ border: "1px solid #ddd", padding: 8, margin: "8px 0" }}>
              <code>{c.sql}</code>
              <div style={{marginTop:6}}>
                <Badge ok={c.safe} label={c.safe ? "safe" : "unsafe"} />
                <Badge ok={c.cost_ok} label={c.cost_ok ? "cost-ok" : "cost-high"} />
              </div>
              <div style={{display:"flex", gap:8, marginTop:8}}>
                <button onClick={()=>explain(c.sql)}>Explain</button>
                <button onClick={()=>approve(c.sql)} disabled={!c.safe || !c.cost_ok}>Approve & Run</button>
              </div>
            </div>
          ))}

          <h3>Edit & Lint</h3>
          <textarea
            value={editSQL}
            onChange={(e)=>setEditSQL(e.target.value)}
            rows={4}
            style={{width:"100%", fontFamily:"monospace", padding:8}}
            placeholder="Edit SQL here..."
          />
          <div style={{display:"flex", gap:8, marginTop:8}}>
            <button onClick={doLint}>Lint Edited</button>
            <button onClick={()=>approve(editSQL)}>Approve Edited</button>
          </div>
          {lint && (
            <div style={{marginTop:8}}>
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
  );
}
