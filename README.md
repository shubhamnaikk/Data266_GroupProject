# 📊 DBLens: Agentic Natural-Language Querying Across Structured Databases  

**DBLens** is an experimental **NL-to-SQL assistant** that combines large language models (LLMs), retrieval-augmented generation (RAG), schema-aware prompting, and human-in-the-loop safeguards.  
It bridges the gap between **research benchmarks** and **real-world deployment** by emphasizing **safety, efficiency, and transparency**.  

---

## 🚀 Project Overview  
Natural Language Interfaces to Databases (NLIDBs) are powerful but fragile in real-world use. Queries can be unsafe, costly, or incorrect.  
**DBLens** introduces a multi-agent workflow:  

**Ask → Plan → Approve**  

✔️ Generates multiple candidate SQL queries  
✔️ Runs cost & safety checks before execution  
✔️ Lets users preview SQL, provenance, and results  

---

## ✨ Features  

- **Benchmark-Driven Research**
  - Evaluates on **WikiSQL**, **Spider**, and **UNITE** benchmarks  
  - Studies schema-aware prompting, chain-of-thought, retrieval augmentation, and LoRA fine-tuning  

- **Agentic Query Workflow**
  - Multi-agent debate with constrained SQL decoding  
  - Safety-first execution with read-only sandboxes, `EXPLAIN` checks, and audit trails  

- **System Controls**
  - Cost-aware query routing  
  - Sample-first execution for efficiency  
  - Provenance and lineage always visible  

- **Human-in-the-Loop**
  - Users preview SQL and results before execution  
  - Error self-repair and taxonomy tracking  

---

## 📈 Performance Metrics  

- **Research Side:** Execution accuracy, SQL validity, schema generalization  
- **System Side:** Safety violations, latency, cost savings, provenance completeness, approval rates  

---

## 🛠️ Tech Stack  

- **Databases:** PostgreSQL, DuckDB, MySQL  
- **Models & Methods:** LLMs (schema-aware prompting, CoT, RAG), LoRA fine-tuning, multi-agent orchestration  
- **UI:** Minimal web interface for query results, provenance, and approval workflow  


---

## 👥 Team  

- **Shreyas Mohite**  
- **Shubham Naik**   
- **Rutuja Kadam** 

