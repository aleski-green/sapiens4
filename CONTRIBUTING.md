# Code guidelines

## Hardcoded model prompts

All hardcoded model prompts must live in the repository's root `prompts/`
directory as separate, descriptively named `.md` files, such as
`prompts/conversation.md` and `prompts/computer-use.md`.

Application code must load these files instead of embedding prompt text in source
code. This includes system instructions, prompt prefixes/suffixes, reference
wrappers, and installer model-check prompts. Dynamic values may be inserted using
template placeholders; user messages, Notes contents, and generated state are data,
not hardcoded prompts.
