"""Validate canonical OMP model modes and expand one into upstream settings."""

import json


SOURCE = ".claude/source/omp-model-modes.json"
MODES = {"gpt-only", "opus-only", "hybrid-gpt-lead", "hybrid-opus-lead"}
INTENTS = {"leader", "worker", "helper", "reviewer"}
WORKLOADS = {
    "default", "plan", "slow", "task", "smol", "tiny",
    "memory", "commit", "vision", "judge", "advisor",
}
SELECTORS = {"G": "openai-codex/gpt-6.1-sol", "O": "anthropic/claude-opus-5-5"}
MODEL_KIND_ROLES = {"judge"}


def require(condition, message):
    if not condition:
        raise ValueError("OMP model modes: " + message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate key " + key)
        result[key] = value
    return result


def parse_model_modes(raw: str) -> dict:
    spec = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(spec, dict), "expected object")
    require(set(spec) == {
        "schema", "default", "modeled_selectors", "workloads",
        "modes", "named_agent_roles",
    }, "source fields")
    require(type(spec["schema"]) is int and spec["schema"] == 1, "schema")
    require(isinstance(spec["default"], str) and spec["default"] in MODES, "default")
    require(spec["modeled_selectors"] == SELECTORS, "exact G/O selectors")
    modes, workloads, agents = spec["modes"], spec["workloads"], spec["named_agent_roles"]
    require(isinstance(modes, dict) and set(modes) == MODES, "four modes")
    for assignment in modes.values():
        require(isinstance(assignment, dict) and set(assignment) == INTENTS, "intents")
        require(all(isinstance(v, str) and v in SELECTORS
                    for v in assignment.values()), "intent selector")
    require(isinstance(workloads, dict) and set(workloads) == WORKLOADS, "workloads")
    for row in workloads.values():
        require(isinstance(row, list) and len(row) == 2
                and all(isinstance(v, str) for v in row)
                and row[0] in INTENTS
                and row[1] in {"low", "medium", "high", "xhigh", "max"}, "workload")
    require(isinstance(agents, dict) and bool(agents), "named agents")
    require(all(isinstance(k, str) and k.strip() == k and k
                and isinstance(v, str) and v in INTENTS
                for k, v in agents.items()), "agent intent")
    return spec


def expand_model_mode(spec: dict, mode: str) -> dict:
    """Upstream OMP settings for one mode; merged into the bundle's --config overlay."""
    require(mode in MODES, "unknown selected mode")
    models = {intent: spec["modeled_selectors"][selector]
              for intent, selector in spec["modes"][mode].items()}
    aliases = {"reviewer": "@advisor", "worker": "@task"}
    require(all(v in aliases for v in spec["named_agent_roles"].values()),
            "agent intent must be reviewer or worker")
    g, o = SELECTORS["G"], SELECTORS["O"]
    return {
        # Model-kind roles (judge) take no chat thinking suffix.
        "modelRoles": {name: models[intent] if name in MODEL_KIND_ROLES else f"{models[intent]}:{effort}"
                       for name, (intent, effort) in spec["workloads"].items()},
        "task": {"agentModelOverrides": {agent: aliases[intent]
                                         for agent, intent in spec["named_agent_roles"].items()}},
        "retry": {"modelFallback": True, "fallbackOn": "usage-limit",
                  "fallbackRevertPolicy": "cooldown-expiry",
                  "fallbackChains": {o: [g], g: [o]}},
        "contextPromotion": {"enabled": False},
    }
