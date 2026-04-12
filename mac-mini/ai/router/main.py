import httpx
import os
import json
import traceback
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from dotenv import load_dotenv
from classify import build_intent_embeddings, classify
from ha_commands import handle_home_command

# Load environment variables from .env file (if present)
load_dotenv()

app = FastAPI()

# ========== Configuration ==========
OPENWEBUI_HOST = os.getenv("OPENWEBUI_HOST", "http://localhost:2000")
OPENWEBUI_API_KEY = os.getenv("OPENWEBUI_API_KEY", "")

# Map each intent to a specific LLM model (adjust as needed)
MODELS = {
    "home_command":"llama3.2:latest",
    "chat":      "llama3.2:latest",
    "personal":  "llama3.2:latest",
    "coding":    "llama3.2:latest",
    "law":       "llama3.2:latest",
    "medicine":  "llama3.2:latest",
}

# All intents use the same OpenAI‑compatible endpoint
ENDPOINTS = {
    intent: f"{OPENWEBUI_HOST}/api/chat/completions"
    for intent in MODELS.keys()
}

# Will be populated at startup
intent_embeddings = {}

# ========== Helper Functions ==========
def openwebui_headers():
    """Return headers required by Open WebUI."""
    return {"Authorization": f"Bearer {OPENWEBUI_API_KEY}"}

def strip_device_context(messages: list) -> list:
    """
    Remove device context (e.g., "Current Time: ...") from system messages.
    This prevents the LLM from receiving irrelevant Home Assistant device info.
    """
    print("=== STRIP DEVICE CONTEXT ===")
    print(f"Input messages count: {len(messages)}")
    cleaned = []
    for msg in messages:
        if msg["role"] == "system":
            original = msg["content"]
            print(f"Original system prompt length: {len(original)}")
            # Remove everything after and including "Current Time:"
            if "Current Time:" in original:
                stripped = original[:original.index("Current Time:")].strip()
                print(f"Stripped system prompt length: {len(stripped)}")
                print(f"First 200 chars of stripped prompt: {stripped[:200]}")
                cleaned.append({**msg, "content": stripped})
            else:
                cleaned.append(msg)
        else:
            cleaned.append(msg)
    print("=== END STRIP ===")
    return cleaned

def build_home_command_messages(original_messages: list, user_text: str, action: str, success: bool) -> list:
    """
    Build the message list sent to the LLM after a home command has been executed.
    Replaces the conversation with a focused prompt asking for a natural confirmation.
    """
    if success:
        instruction = (
            f"The user said: \"{user_text}\". "
            f"You successfully performed the following action: {action}. "
            "Confirm this in a single natural, friendly sentence. "
            "Do not ask any follow-up questions."
        )
    else:
        instruction = (
            f"The user said: \"{user_text}\". "
            f"You tried to perform a home automation command but it failed: {action}. "
            "Apologise briefly and suggest the user check their device or try again."
        )
 
    # Preserve any existing system message so the assistant keeps its persona,
    # but swap out the user turn for our instruction.
    system_msgs = [m for m in original_messages if m["role"] == "system"]
    return system_msgs + [{"role": "user", "content": instruction}]
 
async def call_llm(model: str, endpoint: str, messages: list) -> str:
    """Forward a message list to Open WebUI and return the assistant text."""
    forward_body = {
        "model": model,
        "messages": messages,
        "stream": False,
    }
    print(f"\n📤 Forwarding to LLM — model: {model} (first 400 chars):")
    print(json.dumps(forward_body, indent=2)[:400])
 
    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(endpoint, headers=openwebui_headers(), json=forward_body)
        print(f"\n📥 LLM response status: {resp.status_code}")
        resp.raise_for_status()
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        print(f"💬 LLM reply preview: {content[:200]}")
        return content

# ========== Startup: Build Intent Embeddings ==========
@app.on_event("startup")
async def startup_event():
    global intent_embeddings
    print("\n🚀 Starting up – building intent embeddings...")
    try:
        intent_embeddings = build_intent_embeddings()
        print("✅ Intent embeddings ready.")
        print(f"   Loaded intents: {list(intent_embeddings.keys())}")
    except Exception as e:
        print(f"❌ Failed to build intent embeddings: {e}")
        traceback.print_exc()
        raise
    print("🏁 Ready to accept requests.\n")

# ========== Main Routing Endpoint ==========
@app.post("/v1/chat/completions")
async def route(request: Request):
    print("\n" + "="*60)
    print("📨 NEW REQUEST RECEIVED")
    print("="*60)

    # Parse request body
    body = await request.json()
    messages = body.get("messages", [])
    print(f"Total messages in request: {len(messages)}")
    for idx, msg in enumerate(messages):
        print(f"  [{idx}] role: {msg['role']} | content preview: {str(msg.get('content', ''))[:80]}")

    # Extract last user message for intent classification
    user_messages = [m for m in messages if m["role"] == "user"]
    if not user_messages:
        print("⚠️ No user message found in request. Returning error.")
        return JSONResponse(
            status_code=400,
            content={"response": "No user message provided.", "commands": []}
        )
    last_user_msg = user_messages[-1]["content"]
    print(f"\n🔍 Last user message: \"{last_user_msg[:150]}\"")

    # Classify intent using pre‑built embeddings
    try:
        intent, scores = classify(last_user_msg, intent_embeddings)
        print(f"\n🎯 Intent classification result: {intent}")
        print("   Scores (sorted descending):")
        for k, v in sorted(scores.items(), key=lambda x: x[1], reverse=True):
            print(f"      {k}: {v:.4f}")
    except Exception as e:
        print(f"❌ Intent classification failed: {e}")
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"response": "Intent recognition error.", "commands": []}
        )

    # ------------------------------------------------------------------ #
    #  HOME COMMAND BRANCH                                                 #
    # ------------------------------------------------------------------ #
    if intent == "home_command":
        print("\n🏠 Home command detected — executing via HA REST API")
 
        # 1. Execute the command against HA
        ha_result = await handle_home_command(last_user_msg)
        print(f"   HA result: {ha_result}")
 
        action_description = ha_result.get("action") or ha_result.get("error") or "unknown action"
 
        # 2. Ask the LLM to produce a natural spoken confirmation
        model    = MODELS["home_command"]
        endpoint = ENDPOINTS["home_command"]
        llm_messages = build_home_command_messages(
            original_messages=strip_device_context(messages),
            user_text=last_user_msg,
            action=action_description,
            success=ha_result["success"],
        )
 
        try:
            spoken_response = await call_llm(model, endpoint, llm_messages)
        except Exception as e:
            print(f"⚠️ LLM confirmation call failed, using fallback: {e}")
            spoken_response = action_description   # Graceful fallback
 
        final_response = {
            "response": spoken_response,
            "commands": [ha_result],
        }
        print("\n✅ Returning home command response.")
        print("="*60 + "\n")
        return JSONResponse(content=final_response)
 
    # ------------------------------------------------------------------ #
    #  NORMAL LLM ROUTING                                                  #
    # ------------------------------------------------------------------ #
    # Select model and endpoint based on intent
    model = MODELS.get(intent)
    endpoint = ENDPOINTS.get(intent)
    if not model or not endpoint:
        print(f"⚠️ No model/endpoint configured for intent '{intent}'. Falling back to 'chat'.")
        model = MODELS.get("chat", "llama3.2:latest")
        endpoint = ENDPOINTS.get("chat", f"{OPENWEBUI_HOST}/api/chat/completions")

    print(f"\n🔄 Routing to → model: {model}, endpoint: {endpoint}")

    # Strip device context from system messages
    routed_messages = strip_device_context(messages)

    # Prepare forward payload (OpenAI‑compatible)
    forward_body = {
        "model": model,
        "messages": routed_messages,
        "stream": False,          # Buffer full response
    }
    print(f"\n📤 Forwarding payload to Open WebUI (first 400 chars):")
    print(json.dumps(forward_body, indent=2)[:400])

    # Send request to Open WebUI
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                endpoint,
                headers=openwebui_headers(),
                json=forward_body
            )
            print(f"\n📥 Open WebUI response status: {resp.status_code}")
            resp.raise_for_status()
            response_data = resp.json()
            print(f"   Response body preview (first 400 chars): {resp.text[:400]}")

            # Extract assistant's reply (OpenAI‑compatible format)
            try:
                content = response_data["choices"][0]["message"]["content"]
                print(f"\n💬 Assistant reply preview: {content[:200]}")
            except (KeyError, IndexError) as e:
                print(f"❌ Unexpected response structure from Open WebUI: {e}")
                print(f"   Full response: {json.dumps(response_data, indent=2)[:500]}")
                return JSONResponse(
                    status_code=502,
                    content={"response": "Invalid response from LLM backend.", "commands": []}
                )

            # Build final response (commands always empty for now)
            final_response = {
                "response": content,
                "commands": []    # No Home Assistant command handling in this version
            }
            print("\n✅ Returning final response to client.")
            print(f"   Response text preview: {final_response['response'][:200]}")
            print("="*60 + "\n")
            return JSONResponse(content=final_response)

    except httpx.HTTPStatusError as e:
        print(f"❌ Open WebUI returned error status {e.response.status_code}")
        print(f"   Response body: {e.response.text[:500]}")
        traceback.print_exc()
        return JSONResponse(
            status_code=502,
            content={"response": "LLM backend error.", "commands": []}
        )
    except Exception as e:
        print(f"❌ Unexpected error while forwarding to Open WebUI: {e}")
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"response": "Internal server error. Check logs.", "commands": []}
        )

# ========== Health Check Endpoint ==========
@app.get("/health")
async def health():
    return {
        "status": "ok",
        "intents": list(MODELS.keys()),
        "models": MODELS,
        "openwebui_host": OPENWEBUI_HOST
    }

# ========== Optional: Run with uvicorn directly (for local testing) ==========
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=11000)
