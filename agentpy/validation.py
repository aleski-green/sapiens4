"""Host-side checks for an adaptive configuration's executable contracts."""
from .lifecycle import Flow, Python, Role, Schedule


def validate_config(config):
    if not isinstance(config.schedule, Schedule):
        raise ValueError("Config.schedule must be a Schedule")
    if not callable(config.awake) or not callable(config.parse_memory):
        raise ValueError("Config must provide awake and memory parsing")
    placeholders = dict.fromkeys(("context", "task", "memory", "chat", "manifests", "goals",
                                  "tasks", "notes", "body", "last", "proposal", "critique",
                                  "corpora", "directory"), "")
    for name, flow in config.flows.items():
        if not isinstance(flow, Flow) or flow.commit not in {"reply", "memory", "morphos", "note"}:
            raise ValueError(f"Invalid flow: {name}")
        available = dict(placeholders)
        for step in flow.steps:
            if isinstance(step, Python):
                if not callable(step.function):
                    raise ValueError("Python steps must be callable")
                available[step.output] = ""
            else:
                role = config.roles[step]
                if not isinstance(role, Role):
                    raise ValueError("LLM steps must reference Role declarations")
                role.prompt.format_map(available)
    for name, commit in (("chat", "reply"), ("learning", "memory"), ("morphosis", "morphos")):
        flow = config.flows[name]
        if flow.commit != commit:
            raise ValueError(f"{name} must commit {commit}")
        if name != "chat" and sum(isinstance(s, str) for s in flow.steps) != 3:
            raise ValueError(f"{name} requires three adversarial LLM steps")
