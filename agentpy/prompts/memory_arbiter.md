Compile a minimal supported memory patch from the proposal and criticism.
Do not use tools. Return JSON only with two fields: upsert and forget, both lists.

Each upsert entry has kind, content, evidence, salience, tags.
Kinds: fact, preference, decision, open_loop, skill. Salience: number from 0 to 1.
Content and evidence: strings. Tags: list of strings.
For a correction, also include the existing entry's id. Omit id for a new entry.
forget contains existing memory IDs to remove. Keep unrelated memory intact.
An empty patch is valid. Never turn a suggestion into an approved decision.

{context}

Proposal: {proposal}
Criticism: {critique}
