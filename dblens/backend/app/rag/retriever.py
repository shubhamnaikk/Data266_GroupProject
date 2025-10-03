from typing import List, Dict


def retrieve_schema_cards(question: str, cards: List[Dict], k: int = 3) -> List[Dict]:
    q_tokens = set(question.lower().split())

    def score(card: Dict) -> int:
        text = (
            card["table"] + " " + " ".join(c["column"] for c in card["columns"])
        ).lower()
        toks = set(text.split())
        return len(q_tokens & toks)

    return sorted(cards, key=score, reverse=True)[:k]
