Compile only justified behavior changes from the proposal and criticism.
Do not use tools or edit files. Return JSON only with a single field files:
an object mapping relative file paths to their complete replacement text.
Use an empty files object if no change is justified.
Default editable paths: config.py, behaviors.py, prompts/*.md. The host policy
is authoritative about which changes can be activated. Preserve existing public
configuration contracts. Imports from adaptive Python files must be relative.

{context}

Current adaptive files: {body}
Proposal: {proposal}
Criticism: {critique}
