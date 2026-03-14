import httpx
import os
import json
import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from dotenv import load_dotenv
from classify import build_intent_embeddings, classify, get_embedding
from intents import INTENTS
import re

load_dotenv()

app = FastAPI()

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OPENWEBUI_HOST = os.getenv("OPENWEBUI_HOST", "http://localhost:2000")
OPENWEBUI_API_KEY = os.getenv("OPENWEBUI_API_KEY", "")

MODELS = {
    "home":     "llama3.2:latest",
    "chat":     "llama3.2:latest",
    "code":     "llama3.2:latest",
    "personal": "llama3.2:latest",
}

ENDPOINTS = {
    "home":     f"{OLLAMA_HOST}/v1/chat/completions",
    "chat":     f"{OPENWEBUI_HOST}/api/chat/completions",
    "code":     f"{OPENWEBUI_HOST}/api/chat/completions",
    "personal": f"{OPENWEBUI_HOST}/api/chat/completions",
}

intent_embeddings = {}

# Build embeddings once at startup so every request is fast
@app.on_event("startup")
async def startup_event():
    global intent_embeddings
    print("Building intent embeddings at startup...")
    intent_embeddings = build_intent_embeddings()
    print("Ready.")

def openwebui_headers():
    return {"Authorization": f"Bearer {OPENWEBUI_API_KEY}"}

def strip_device_context(messages: list) -> list:
    cleaned = []
    for msg in messages:
        if msg["role"] == "system":
            content = msg["content"]
            if "Current Time:" in content:
                content = content[:content.index("Current Time:")].strip()
            cleaned.append({**msg, "content": content})
        else:
            cleaned.append(msg)
    return cleaned

@app.post("/v1/chat/completions")
async def route(request: Request):
    body = await request.json()
    messages = body.get("messages", [])

    # Debug — print all message roles
    print("=== INCOMING MESSAGES ===")
    for msg in messages:
        print(f"  role: {msg['role']} | content: {str(msg.get('content', ''))[:80]}")
    print("=== END ===")

    # Get last user message for classification
    user_messages = [m for m in messages if m["role"] == "user"]
    last_user_msg = user_messages[-1]["content"] if user_messages else ""

    # Classify intent using embeddings
    intent, scores = classify(last_user_msg, intent_embeddings)
    model = MODELS[intent]

    print(f"Intent: {intent} → Model: {model} | Query: {last_user_msg[:60]}")
    print(f"Scores: { {k: round(v, 4) for k, v in sorted(scores.items(), key=lambda x: x[1], reverse=True)} }")

    # Home keeps full context, everything else gets stripped
    if intent == "home":
        routed_messages = messages
    else:
        routed_messages = strip_device_context(messages)
        # Debug — confirm what stripped prompt looks like
        for msg in routed_messages:
            if msg["role"] == "system":
                print("=== STRIPPED SYSTEM PROMPT ===")
                print(msg["content"])
                print("=== END ===")
                break

    # Forward to Open WebUI
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            forward_body = {
                "model": model,
                "messages": routed_messages,
                "stream": False,
            }

            # Only pass tools for home intent
            if intent == "home":
                if body.get("tools"):
                    forward_body["tools"] = body["tools"]
                if body.get("tool_choice"):
                    forward_body["tool_choice"] = body["tool_choice"]

            headers = {"Content-Type": "application/json"} if intent == "home" else openwebui_headers()
            
            if intent == "home":
                print(f"Tools in forward_body: {bool(forward_body.get('tools'))}")
                print(f"Tool count: {len(forward_body.get('tools', []))}")
            resp = await client.post(
                ENDPOINTS[intent],
                headers=openwebui_headers(),
                json=forward_body
            )
            resp.raise_for_status()
            response_data = resp.json()
            
             # Debug — print full response for home intent
            if intent == "home":
                print("=== HOME RESPONSE ===")
                print(json.dumps(response_data, indent=2))
                print("=== END ===")

            return response_data
    except Exception as e:
        print(f"Forward failed: {e}")
        return JSONResponse(status_code=500, content={
            "id": "chatcmpl-error",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "I appear to be having a malfunction. How typical."
                },
                "finish_reason": "stop"
            }]
        })

@app.get("/health")
async def health():
    return {"status": "ok", "intents": list(MODELS.keys())}
