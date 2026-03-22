import httpx
import numpy as np
import sys
import os
from intents import INTENTS

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
EMBED_MODEL = "nomic-embed-text"

def cosine_similarity(a: list, b: list) -> float:
    a = np.array(a)
    b = np.array(b)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))

def get_embedding(text: str) -> list:
    resp = httpx.post(
        f"{OLLAMA_HOST}/api/embeddings",
        json={"model": EMBED_MODEL, "prompt": text},
        timeout=10
    )
    return resp.json()["embedding"]

def build_intent_embeddings() -> dict:
    print("Building intent embeddings...")
    intent_embeddings = {}
    for intent, phrases in INTENTS.items():
        embeddings = [get_embedding(phrase) for phrase in phrases]
        # Average all example embeddings into one representative vector
        intent_embeddings[intent] = np.mean(embeddings, axis=0).tolist()
        print(f"  {intent}: {len(phrases)} examples embedded")
    return intent_embeddings

def classify(query: str, intent_embeddings: dict) -> tuple:
    query_embedding = get_embedding(query)
    scores = {
        intent: cosine_similarity(query_embedding, centroid)
        for intent, centroid in intent_embeddings.items()
    }
    best_intent = max(scores, key=scores.get)
    return best_intent, scores

if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "turn off the lights"
    
    intent_embeddings = build_intent_embeddings()
    
    print(f"\nQuery: '{query}'")
    intent, scores = classify(query, intent_embeddings)
    
    print(f"Scores:")
    for k, v in sorted(scores.items(), key=lambda x: x[1], reverse=True):
        print(f"  {k}: {v:.4f}")
    print(f"\nResult: {intent}")
