import { useState } from "react";
import axios from "axios";

export default function App() {
  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const ask = async () => {
    setLoading(true);
    try {
      const r = await axios.post("http://localhost:8000/v1/ask", { question: q });
      setResp(r.data);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif, system-ui" }}>
      <h1>DBLens MVP</h1>
      <div style={{ display: "flex", gap: 8 }}>
        <input
          style={{ flex: 1, padding: 8 }}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Ask a question…"
        />
        <button onClick={ask} disabled={!q || loading}>
          {loading ? "Running…" : "Ask"}
        </button>
      </div>

      {resp && (
        <div style={{ marginTop: 16 }}>
          <h3>Candidates</h3>
          <pre>{JSON.stringify(resp.candidates, null, 2)}</pre>
          <h3>Preview</h3>
          <pre>{JSON.stringify(resp.preview, null, 2)}</pre>
        </div>
      )}
    </div>
  );
}
