"""Simple REPL for chatting with the cert-lab agent."""
import sys
import time

from langchain_core.messages import HumanMessage

from graph import build_agent


def main():
    agent = build_agent()
    print("TLS lab agent ready (Ctrl-C or Ctrl-D to exit).")
    messages = []
    while True:
        try:
            user_input = input("\nyou> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user_input:
            continue
        messages.append(HumanMessage(content=user_input))
        print("agent is thinking...", end="", flush=True)
        start = time.monotonic()
        try:
            result = agent.invoke({"messages": messages})
        except Exception as e:
            print(f"\rError after {time.monotonic() - start:.0f}s: {e}", file=sys.stderr)
            messages.pop()  # don't leave a dangling unanswered turn in history
            continue
        print(f"\r(took {time.monotonic() - start:.1f}s)     ")
        messages = result["messages"]
        print(f"agent> {messages[-1].content}")


if __name__ == "__main__":
    main()
