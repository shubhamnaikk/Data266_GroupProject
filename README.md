# Data266_GroupProject
DBLens: Agentic Natural-Language Querying Across Structured Databases
DBLens is a research and systems project that builds a dependable natural language to SQL (NL-to-SQL) assistant. It bridges the gap between cutting-edge research and real-world deployment by combining large language models (LLMs), retrieval-augmented generation (RAG), schema-aware prompting, and human-in-the-loop safeguards.

🚀 Project Overview

Natural Language Interfaces to Databases (NLIDBs) are powerful but fragile in real-world use. Queries may be unsafe, costly, or incorrect. DBLens introduces a multi-agent, agentic workflow—Ask → Plan → Approve—to ensure safety, efficiency, and transparency.

The project evaluates multiple strategies (prompting, self-consistency, retrieval augmentation, LoRA fine-tuning) across leading text-to-SQL benchmarks and integrates them into a practical system with provenance tracking and cost-awareness.

✨ Features

Benchmark-Driven Research

Evaluates on WikiSQL (simple, single-table), Spider (cross-domain, multi-table), and UNITE (120k+ examples, 18 datasets).

Studies schema-aware prompting, chain-of-thought, retrieval augmentation, and LoRA fine-tuning.

Agentic Query Workflow (DBLens)

Ask → Plan → Approve cycle for query validation.

Multi-agent debate with constrained SQL decoding.

Safety-first execution with read-only sandboxes, EXPLAIN checks, and audit trails.

System Controls

Cost-aware query routing.

Sample-first execution for efficiency.

Provenance and lineage always visible.

Human-in-the-Loop

Users preview SQL and results before execution.

Error self-repair and taxonomy tracking.

📈 Performance Metrics

Research side: Execution accuracy, SQL validity, schema generalization.

System side: Safety violations, latency, cost savings, provenance completeness, and human approval rates.

🛠️ Tech Stack

Databases: PostgreSQL, DuckDB, MySQL.

Models & Methods: LLMs (schema-aware prompting, CoT, RAG), LoRA fine-tuning, multi-agent orchestration.

UI: Minimal web interface for query results, provenance, and approval workflow.


👥 Team

Shreyas Mohite – Infrastructure & evaluation

Shubham Naik – Modeling & guardrails

Rutuja Kadam – RAG, fine-tuning & UI
