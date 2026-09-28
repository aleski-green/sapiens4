"""The agent's editable behavior. Prompt text lives in prompts/*.md."""
from agentpy import Debate, Flow, Request, Role, Schedule
from agentpy.lifecycle import Prompts
from agentpy.settings import FlowConfig, MemoryEntry

prompts = Prompts(__file__)


class Config(FlowConfig):
    memory_schema = MemoryEntry
    schedule = Schedule(awake_minutes=10, circa_hours=24, sprint_days=7, timezone="Asia/Dubai")

    roles = {
        "conversation": Role(prompts["conversation"]),
        "reasoner": Role(prompts["reasoner"]),
        "doubter": Role(prompts["doubter"]),
        "decision": Role(prompts["decision"]),
        "explorer": Role(prompts["explorer"]),
        "aesthetic": Role(prompts["aesthetic"]),
        "initiative": Role(prompts["initiative"]),
        "evaluator": Role(prompts["evaluator"]),
        "corpora": Role(prompts["corpora"]),
        "react": Role(prompts["react"]),
        "memory_proposer": Role(prompts["memory_proposer"]),
        "memory_critic": Role(prompts["memory_critic"]),
        "memory_arbiter": Role(prompts["memory_arbiter"]),
        "morphos_proposer": Role(prompts["morphos_proposer"]),
        "morphos_critic": Role(prompts["morphos_critic"]),
        "morphos_arbiter": Role(prompts["morphos_arbiter"]),
    }

    flows = {
        "chat": Flow(("conversation",), commit="reply"),
        "reason": Debate("reasoner", "doubter", "decision", commit="note"),
        "learning": Debate("memory_proposer", "memory_critic", "memory_arbiter", commit="memory"),
        "morphosis": Debate("morphos_proposer", "morphos_critic", "morphos_arbiter", commit="morphos"),
        "explore": Flow(("explorer",)),
        "organize": Flow(("aesthetic",)),
        "initiative": Flow(("initiative", "doubter", "decision")),
        "evaluate": Flow(("evaluator",)),
        "corpora": Flow(("corpora",)),
        "act": Flow(("react",)),
    }

    @staticmethod
    def awake(wake):
        for task in wake.due_tasks:
            yield Request(task["flow"], task["title"], key=task["id"])
        if wake.circa_due and wake.changed:
            yield Request("learning", key=f"learning:{wake.now}")
            yield Request("morphosis", key=f"morphosis:{wake.now}")
