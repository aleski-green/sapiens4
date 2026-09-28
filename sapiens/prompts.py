"""Load repository-owned model instructions."""
from .paths import ROOT


def prompt(template, **values):
    text = (ROOT / 'prompts' / (template + '.md')).read_text(encoding='utf-8')
    return text.format_map(values) if values else text
