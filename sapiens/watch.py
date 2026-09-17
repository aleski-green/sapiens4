"""Deterministic, read-only change detector. Timer polls never call a model.

A Sapi supplies a bounded observation plan after discovering an AX container.
No generated shell/code is executed by the scheduler; the reusable script only
runs the two allowlisted Blindly reads below.
"""
from datetime import datetime, timedelta
import hashlib
import json
import re
import subprocess
import unicodedata


DEFAULTS = dict(mode='changes', probe=None, cooldown_minutes=30, max_per_hour=2, max_per_day=8)


def validate(value):
    from .service import APIError
    if not isinstance(value, dict) or set(value)-set(DEFAULTS):
        raise APIError(400, 'Invalid watcher plan')
    result = {**DEFAULTS, **value}
    if result['mode'] not in {'changes', 'always'}:
        raise APIError(400, 'Watcher mode must be changes or always')
    for key, maximum in [('cooldown_minutes', 1440), ('max_per_hour', 12), ('max_per_day', 48)]:
        if type(result[key]) is not int or not 1 <= result[key] <= maximum:
            raise APIError(400, f'{key} must be 1–{maximum}')
    p = result['probe']
    if p is not None:
        if not isinstance(p, dict) or set(p)-{'bundle_id','container_id','names'}:
            raise APIError(400, 'Probe needs bundle_id, container_id, and optional names')
        for key in ('bundle_id', 'container_id'):
            if not isinstance(p.get(key), str) or not p[key].strip() or len(p[key]) > 200:
                raise APIError(400, f'Probe {key} must be nonempty text, at most 200 characters')
        names = p.get('names', [])
        if not isinstance(names, list) or len(names)>50 or any(not isinstance(n,str) or not n.strip() or len(n)>120 for n in names):
            raise APIError(400, 'Choose at most 50 nonempty chat names')
        result['probe'] = {**p, 'names': list(dict.fromkeys(n.strip() for n in names))}
    return result


def clean(text):
    # Directional marks and relative display clocks aren't message changes.
    text = ''.join(c for c in str(text) if unicodedata.category(c) != 'Cf')
    text = re.sub(r'\b\d+\s*(?:minutes?|hours?|seconds?)\s+ago\b', '<relative-time>', text, flags=re.I)
    return ' '.join(text.split())


def extract(document, plan):
    """Keep only direct chat rows in a discovered container; no AX paths persist."""
    def find(node):
        if node.get('identifier') == plan['container_id']:
            return node
        for child in node.get('children', []):
            found = find(child)
            if found is not None:
                return found
    container = find(document.get('tree', {}))
    if container is None:
        raise ValueError('Watched list is unavailable. Open the configured list; no agent was started.')
    if document.get('truncated'):
        raise ValueError('Observation was truncated; narrow the observation plan before monitoring.')
    names = {clean(n).casefold() for n in plan.get('names', [])}
    rows = {}
    found_names = set()
    for node in container.get('children', []):
        # Sidebar filter chips/archive controls are groups, not conversation rows.
        if node.get('role') not in {'AXButton', 'AXRow', 'AXCell'}:
            continue
        label = clean(node.get('description') or node.get('title') or '')
        name = re.sub(r',\s*\d+\s+unread.*$', '', label, flags=re.I)
        if not name or (names and name.casefold() not in names):
            continue
        found_names.add(name.casefold())
        content = clean(node.get('value', ''))
        # Include unread count and preview, excluding selection/focus/geometry.
        digest = hashlib.sha256(json.dumps([label, content], ensure_ascii=False).encode()).hexdigest()
        key = hashlib.sha256(name.encode()).hexdigest()
        rows[key] = dict(name=name[:120], digest=digest,
                         priority='phone-number label' if re.match(r'^\+?[\d\s().-]{7,}$', name) else 'named chat')
    if not rows:
        raise ValueError('No matching chat rows are visible; no agent was started.')
    if names-found_names:
        raise ValueError('Some selected chats are not visible. Restore the list or narrow the selection.')
    return dict(rows=rows, coverage='Visible chat-list previews only; DM/contact identity, archived chats and off-screen messages are not verified.')


def observe(binary, plan):
    def read(*args):
        process = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=8)
        if process.returncode:
            raise ValueError('Blindly observation failed. Check application availability and Accessibility access.')
        if len(process.stdout)>2_000_000:
            raise ValueError('Observation is too large; narrow the plan.')
        return json.loads(process.stdout)
    apps = read('apps')
    app = next((a for a in apps.get('apps', []) if a.get('bundleId') == plan['bundle_id']), None)
    if app is None:
        raise ValueError('Watched app is closed. Open it to resume script checks.')
    return extract(read('tree', '--pid', str(app['pid']), '--depth', '16', '--max-nodes', '800'), plan)


def poll(row, binary, instant, can_admit):
    """Update durable detector state and return whether an LLM should be admitted."""
    policy = row.get('watch', DEFAULTS)
    state = row.setdefault('detector', {})
    if policy['mode'] == 'changes' and not policy.get('probe'):
        state.update(status='needs_plan', reason='Configure a change detector before automatic runs. Ask the Sapi to discover the relevant list once.')
        return False
    if state.get('retry_at') and instant < datetime.fromisoformat(state['retry_at']):
        return False
    state['last_check'] = instant.isoformat()
    if policy['mode'] == 'changes':
        state['checks'] = state.get('checks', 0)+1
        try:
            current = observe(binary, policy['probe'])
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            state['failures'] = state.get('failures', 0)+1
            delay = min(60, row['minutes'] * 2**min(state['failures'], 6))
            state.update(status='blocked', reason=str(error), retry_at=(instant+timedelta(minutes=delay)).isoformat())
            return False
        state.pop('retry_at', None)
        state['failures'] = 0
        state['coverage'] = current['coverage']
        baseline = state.get('baseline')
        if baseline is None:
            state.update(baseline=current['rows'], status='baseline', reason='Baseline saved; waiting for a visible change.')
            return False
        # Disappearing rows alone are often scrolling, filtering or virtualization.
        # Treat these as a coverage issue, not evidence of a new message.
        changed = [r for key,r in current['rows'].items() if baseline.get(key, {}).get('digest') != r['digest']]
        if not changed:
            missing = set(baseline)-set(current['rows'])
            state.update(status='partial' if missing else 'unchanged',
                         reason='Previously observed rows are no longer visible.' if missing else 'No visible changes; no model call.')
            state.pop('pending', None)
            state['skipped'] = state.get('skipped', 0)+1
            return False
        changed.sort(key=lambda r: (r['priority'] != 'phone-number label', r['name']))
        state['pending'] = dict(rows=current['rows'], changed=[{k:r[k] for k in ('name','priority')} for r in changed[:20]], observed_at=instant.isoformat())
    wakes = [t for t in state.get('wakes', []) if datetime.fromisoformat(t)>instant-timedelta(days=1)]
    state['wakes'] = wakes
    hour = sum(datetime.fromisoformat(t)>instant-timedelta(hours=1) for t in wakes)
    cooldown = wakes and datetime.fromisoformat(wakes[-1])+timedelta(minutes=policy['cooldown_minutes'])>instant
    if cooldown or hour>=policy['max_per_hour'] or len(wakes)>=policy['max_per_day']:
        state.update(status='throttled', reason='Wake-up limit reached; changes are retained for a later check.')
        return False
    if not can_admit:
        state.update(status='budget_blocked', reason='Changes are waiting for model allowance; script checks continue.')
        return False
    state.update(status='changed' if policy['mode']=='changes' else 'ready', reason='Ready for agent review.')
    return True
