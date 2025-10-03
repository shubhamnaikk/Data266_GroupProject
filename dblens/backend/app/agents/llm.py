import os
from typing import List, Dict, Optional, Any, cast


class LLMClient:
    def __init__(self):
        self.provider = os.getenv("LLM_PROVIDER", "openai")
        self.model = os.getenv("LLM_MODEL", "gpt-4o-mini")
        self.api_key = os.getenv("LLM_API_KEY")

    def chat(
        self,
        messages: List[Dict[str, str]],
        n: int = 1,
        stop: Optional[List[str]] = None,
    ) -> List[str]:
        # No key -> deterministic safe fallback
        if not self.api_key:
            return ["SELECT 1 /* fallback: no_api_key */"]

        try:
            if self.provider == "openai":
                from openai import OpenAI

                client = OpenAI(api_key=self.api_key)
                resp = client.chat.completions.create(  # type: ignore[arg-type]
                    model=self.model,
                    messages=cast(Any, messages),
                    n=n,
                    stop=stop,
                    temperature=0.2,
                )
                return [c.message.content or "" for c in resp.choices]
            raise NotImplementedError(f"Unsupported provider {self.provider}")
        except Exception as e:
            # Fail-safe fallback so /v1/ask always returns JSON
            return [f"SELECT 1 /* fallback: llm_error {type(e).__name__} */"]
