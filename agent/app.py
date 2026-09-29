"""HTTP wrapper around the cert-lab agent, following the Agent Manager chat
contract (same shape as WSO2's sample agents):
  GET  /health -> {"status": "ok", "agent_version": ...}
  POST /chat   {"message", "session_id"?, "context"?} -> {"response", "session_id", "agent_version"}
Conversation history is kept per session_id by LangGraph's in-memory
checkpointer, so it is lost when the process restarts.
"""
from __future__ import annotations

import os
import uuid

from fastapi import FastAPI
from langchain_core.messages import AIMessage
from langgraph.checkpoint.memory import MemorySaver
from pydantic import BaseModel

from graph import build_agent

AGENT_VERSION = os.environ.get("AGENT_VERSION", "1.0.0")

app = FastAPI(title="TLS cert lab agent")
agent = build_agent(checkpointer=MemorySaver())


class ChatRequest(BaseModel):
    message: str
    session_id: str | None = None
    context: dict | None = None


class ChatResponse(BaseModel):
    response: str
    session_id: str
    agent_version: str


def _text(content) -> str:
    if isinstance(content, list):
        return "\n".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in content)
    return str(content)


@app.get("/health")
def health():
    return {"status": "ok", "agent_version": AGENT_VERSION}


# Plain `def` on purpose: the tools block on subprocesses, so FastAPI runs
# this in its threadpool instead of stalling the event loop.
@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest):
    session_id = req.session_id or str(uuid.uuid4())
    result = agent.invoke(
        {"messages": [("user", req.message)]},
        config={"configurable": {"thread_id": session_id}},
    )
    reply = next((m for m in reversed(result["messages"]) if isinstance(m, AIMessage)), None)
    return ChatResponse(
        response=_text(reply.content) if reply else "",
        session_id=session_id,
        agent_version=AGENT_VERSION,
    )
