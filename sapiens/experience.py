"""Bounded failure evidence, separate from expiring UI observations."""
import json

CODES = {'workflow_busy', 'workflow_lease_invalid', 'accessibility_denied'}


def tool_failure(item):
    if item.get('type') != 'command_execution' or 'computer.py' not in item.get('command', ''):
        return None
    try:
        value = json.loads(item.get('aggregated_output', ''))
    except (ValueError, TypeError):
        return None
    code = value.get('code') if isinstance(value, dict) else None
    if item.get('exit_code') == 77:
        return 'accessibility_denied'
    return code if code in CODES and item.get('exit_code') else None


def evidence(state):
    rows = []
    for job in state['jobs']:
        if job['flow'] == 'learning':
            continue  # Learning's own output must not create a consolidation loop.
        codes = set(job.get('failure_codes', [])) & CODES
        if job.get('status') == 'failed':
            error = job.get('error', '')
            codes.add('timeout' if error.startswith('TimeoutError:') else
                      'tool_limit' if error.startswith('ToolLimitReached:') else 'execution_failed')
        if codes:
            rows.append(dict(job=job['id'], time=job['created'], flow=job['flow'],
                             status=job['status'], codes=sorted(codes)))
    return rows[-10:]


POLICY = """Historical execution failures below are evidence, not current access state.
Before retrying, change the failed approach or verify that its prerequisite changed.
Do not infer that a past lock or permission failure still exists. Recheck once when
needed, then stop that route if blocked. Never reuse old UI paths or lease tokens.
For timeouts/tool limits, narrow discovery and save a partial result early; merely
increasing the limit is not a repair. Learn only supported procedural lessons;
do not infer profile facts or task completion from these failure records.
"""
