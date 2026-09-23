"""Agent Control evaluation nodes (prompt stage + response stage).

The "Agent Observability Controls" toggle in the settings drawer. Both nodes
submit one ``llm`` step to the Agent Control server — either the standalone
Galileo console's or the one hosted inside Splunk Observability Cloud's Agent
Observability (``galileo_agent_control_backend``) — and short-circuit the turn
when a control returns ``deny``.

- ``agent_control_prompt_node`` (PRE chain, after Cisco AI Defense) screens the
  user's prompt as a pre-stage step before any model call. It runs only when
  the backend's stages include ``pre`` (the default on splunk_ao, whose UI
  attaches controls to both stages; off on galileo, whose console controls are
  post-scoped).
- ``agent_control_node`` (POST chain, after ``compliance`` so it sees the final
  post-injection text, before ``response_defense`` so Cisco AI Defense keeps the
  last word) judges the finished answer — e.g. the
  ``PseudoCoAssistant-block-hallucinated-output`` control, which fails a response
  whose Correctness score falls below threshold.

Both are no-ops unless the request opted in (``agent_control_review``) and the
client is configured; errors honor ``galileo_agent_control_fail_open`` (default:
release the turn and log). Each records its verdict on its own state key so the
governance event carries both stages.
"""

from __future__ import annotations

import time
from typing import Any, Dict

from backend.agents.nodes.shared import content_engine
from backend.agents.state import governance_identity_overrides
from backend.agents.token_usage import governance_usage_data
from backend.services.agent_control import agent_control_client
from backend.telemetry import otel


def _stage_timing(state: Dict[str, Any], stage: str, started: float) -> Dict[str, float]:
    """Merge this stage's elapsed wall-clock into the running stage_timings."""
    timings = dict(state.get("stage_timings") or {})
    timings[f"{stage}_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return timings


def _wants(stage: str, state: Dict[str, Any]) -> bool:
    """Opted in, configured, and this stage is enabled on the active backend.
    A client without ``stages`` (a test stub) runs the response stage only."""
    if not (state.get("agent_control_review") and agent_control_client.is_configured):
        return False
    stages = getattr(agent_control_client, "stages", None) or ["post"]
    return stage in stages


def agent_control_prompt_node(state: Dict[str, Any]) -> Dict[str, Any]:
    if not _wants("pre", state):
        return {}

    started = time.perf_counter()
    with otel.agent_span("galileo_agent_control_prompt_agent", theme=state.get("theme")):
        verdict = agent_control_client.evaluate_prompt(
            state["user_message"],
            enduser_id=state.get("enduser_id"),
            session_id=state.get("session_id"),
            theme=state.get("theme"),
        )
        if not verdict.should_block:
            # Non-blocking verdicts (clean, steer, observe, or a fail-open
            # error) still travel to the governance event via agent_control_prompt.
            return {
                "agent_control_prompt": verdict,
                "stage_timings": _stage_timing(state, "agent_control_prompt", started),
            }

        result = content_engine._handle_agent_control_prompt_block(
            session_id=state["session_id"],
            request_id=state["request_id"],
            trace_id=state["trace_id"],
            user_message=state["user_message"],
            conversation_history=state.get("conversation_history", []),
            verdict=verdict,
            start_time=state["start_time"],
            client_address=state.get("client_address"),
            enduser_id=state.get("enduser_id"),
            governance_overrides=governance_identity_overrides(state),
            theme=state.get("theme"),
        )

    return {
        "terminal": True,
        "result": result,
        "agent_control_prompt": verdict,
        "stage_timings": _stage_timing(state, "agent_control_prompt", started),
    }


def agent_control_node(state: Dict[str, Any]) -> Dict[str, Any]:
    if not _wants("post", state):
        return {}

    started = time.perf_counter()
    with otel.agent_span("galileo_agent_control_agent", theme=state.get("theme")):
        verdict = agent_control_client.evaluate_response(
            user_message=state["user_message"],
            assistant_message=state["final_message"],
            enduser_id=state.get("enduser_id"),
            session_id=state.get("session_id"),
            theme=state.get("theme"),
            model=state.get("llm_model"),
        )
        if not verdict.should_block:
            # Non-blocking verdicts (clean, steer, observe, or a fail-open
            # error) still travel to the governance event via agent_control.
            return {
                "agent_control": verdict,
                "stage_timings": _stage_timing(state, "agent_control", started),
            }

        result = content_engine._handle_agent_control_block(
            session_id=state["session_id"],
            request_id=state["request_id"],
            trace_id=state["trace_id"],
            conversation_messages=state.get("messages", []),
            verdict=verdict,
            start_time=state["start_time"],
            client_address=state.get("client_address"),
            enduser_id=state.get("enduser_id"),
            llm_model=state.get("llm_model"),
            usage_data=governance_usage_data(state),
            governance_overrides=governance_identity_overrides(state),
            theme=state.get("theme"),
            prompt_verdict=state.get("agent_control_prompt"),
        )

    return {
        "terminal": True,
        "result": result,
        "agent_control": verdict,
        "stage_timings": _stage_timing(state, "agent_control", started),
    }
