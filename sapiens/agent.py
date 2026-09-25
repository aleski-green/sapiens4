"""Host policy on the pinned SDK's transactional runtime.

The small _work override preserves SDK flow semantics and adds per-attempt
telemetry and cache-aware admission. No provider counters are rewritten.
"""
from copy import deepcopy
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo
import json

from .memory import active_tasks, fingerprint, inputs, learning_batch
from .sdk import LLMSpec, Outcome, PersistentAgent, Python, atomic_bytes
from .usage import backfill, counters, save_record, settings


class SapiAgent(PersistentAgent):
    def _trim(self, state):
        super()._trim(state)
        # Long-running recurring jobs fill the byte limit well before the SDK's
        # record-count limit. Archive settled history, preserving active work,
        # task references and the latest completed learning receipt.
        excess = len(json.dumps(state, ensure_ascii=False).encode()) - int(self.limits.state_bytes * .8)
        if excess <= 0:
            return
        protected = {t.get('job') for t in state['tasks']}
        learning = next((j for j in reversed(state['jobs']) if j['flow'] == 'learning'
                         and j['status'] == 'done' and not j.get('memory_more')), None)
        if learning:
            protected.add(learning['id'])
        terminal = [j for j in state['jobs'] if j['status'] in {'done', 'cancelled'}]
        removed = []
        for job in terminal[:-20]:
            if job['id'] in protected:
                continue
            removed.append(job)
            excess -= len(json.dumps(job, ensure_ascii=False).encode())
            if excess <= 0:
                break
        if removed:
            self.corpora.archive(self.agid, 'jobs/'+uuid4().hex, removed)
            ids = {j['id'] for j in removed}
            state['jobs'] = [j for j in state['jobs'] if j['id'] not in ids]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        backfill(self)
        self.configure()
        # Discount only verifiable cached usage in old ledgers. Preserve unknown
        # retry/crash charges. Atomic marker prevents crediting twice on restart.
        if not self.state.get('budget_policy'):
            with self.store.transaction() as state:
                for job in state['jobs']:
                    ledger = state['budgets'].get(job.get('sprint'))
                    if not ledger or job['status'] == 'running':
                        continue
                    logs = self.transcript(job['id'])
                    raw = sum((counters(l.get('usage')) or {}).get('total', 0) for l in logs)
                    units = sum((counters(l.get('usage')) or {}).get('units', 0) for l in logs)
                    if raw and raw == job['tokens']:
                        ledger['spent'] = max(0, ledger['spent']-(raw-units))
                        job['budget_units'] = units
                state['budget_policy'] = 'cache-10-percent-v1'

    def configure(self, data=None):
        if data is not None:
            atomic_bytes(self.root / 'execution.json', json.dumps(data).encode())
        policy = settings(self)
        self.limits = replace(self.limits, tokens_per_call=policy['call_allowance'],
            tokens_per_loop=policy['call_allowance']*4, tokens_per_sprint=policy['weekly_limit'])
        self.store.limits = self.limits
        if hasattr(self.factory, 'execution'):
            self.factory.execution = policy

    def budget_status(self, instant=None):
        instant = instant or datetime.now(timezone.utc)
        sprint = self._sprint(instant)
        ledger = self.state['budgets'].get(sprint, dict(spent=0, reserved=0))
        reset = datetime.fromisoformat(sprint).replace(tzinfo=ZoneInfo(self.budget_calendar.timezone)) + timedelta(days=self.budget_calendar.sprint_days)
        return dict(**ledger, limit=self.limits.tokens_per_sprint,
                    remaining=max(0, self.limits.tokens_per_sprint-ledger['spent']-ledger['reserved']),
                    resets_at=reset.isoformat(), cached_weight_percent=10)

    def can_admit(self, flow, instant=None):
        required = sum(isinstance(s, str) for s in self.config.flows[flow].steps)*self.limits.tokens_per_call
        return self.budget_status(instant)['remaining'] >= required

    def _reserve(self, state, job, loop_remaining, now):
        if getattr(self, '_selected_jobs', None) is not None and job['id'] not in self._selected_jobs:
            return None
        # No repeated blocked events during unrelated work; run() may reconsider
        # a never-started budget-blocked job when its allowance becomes available.
        if job['status'] == 'budget_blocked':
            required = sum(isinstance(s, str) for s in self.config.flows[job['flow']].steps)*self.limits.tokens_per_call
            ledger = state['budgets'].get(self._sprint(now), dict(spent=0, reserved=0))
            if ledger['spent']+ledger['reserved']+required > self.limits.tokens_per_sprint or required > loop_remaining:
                return None
        value = super()._reserve(state, job, loop_remaining, now)
        if value is None:
            job['error'] = 'Budget allowance unavailable. Resumes when enough allowance is available; limits are in Sapi settings.'
        else:
            job.pop('error', None)
            if job['flow'] == 'learning':
                job['memory_input_fingerprint'] = fingerprint(inputs(state, self.manifests))
                _, keys, receipt = learning_batch(state, self.manifests, self.limits.context_chars)
                job['memory_batch'] = keys
                job['memory_more'] = receipt['more']
                if receipt['more']:
                    # SDK must not mark all chat learned after a partial batch.
                    job['chat_revision'] = state['learned_revision']
        return value

    async def run_selected(self, job_ids):
        """Run explicit maintenance without admitting unrelated stopped work."""
        self._selected_jobs = set(job_ids)
        try:
            await self.run()
        finally:
            self._selected_jobs = None

    def _work(self, job, snapshot, config):
        result = Outcome()
        try:
            receipt = None
            if job['flow'] == 'learning':
                snapshot, _, receipt = learning_batch(snapshot, snapshot['inputs']['manifests'], self.limits.context_chars)
            if job['flow'] == 'team_review':
                snapshot = deepcopy(snapshot)
                snapshot.update(chat=[], notes=[], tasks=[], memx=[], projects=[])
                snapshot['inputs']['manifests'] = {k: v for k, v in snapshot['inputs']['manifests'].items()
                                                  if k in {'identity', 'host-control', 'host-facts'}}
            # Routine calls use relevant working state; learning visits retained
            # experience incrementally through its durable batch receipts.
            if job['flow'] in {'chat', 'computer', 'scheduled', 'task', 'strategy'}:
                snapshot = deepcopy(snapshot)
                snapshot['chat'] = snapshot['chat'][-10:]
                snapshot['notes'] = snapshot['notes'][-5:]
                snapshot['tasks'] = active_tasks(snapshot)
                if job['flow'] in {'scheduled', 'strategy'}:
                    # The detector + checkpoint in task are the working set.
                    # Old chat and timer notes cause repeated discovery/learning.
                    snapshot['chat'] = []
                    snapshot['notes'] = []
                    # The task carries this job's plan/checkpoint/feedback. Do
                    # not duplicate every peer's plans into automated turns.
                    manifests = snapshot['inputs']['manifests']
                    facts = json.loads(manifests.get('host-facts', '{}'))
                    facts.pop('recurring_jobs', None)
                    facts['team'] = [{k: v for k, v in member.items()
                                      if k in {'id', 'name', 'role', 'manager'} or
                                      (member.get('id') == self.agid and k == 'budget')}
                                     for member in facts.get('team', [])]
                    manifests['host-facts'] = json.dumps(facts)
                    manifests.pop('task-comments', None)
            context = self._context(snapshot, job['task'])
            llm_index = 0
            for step in config.flows[job['flow']].steps:
                if isinstance(step, Python):
                    context[step.output] = step.function(deepcopy(context))
                    continue
                role = config.roles[step]
                if receipt is not None:
                    # Reserve headroom for each later debate stage, even when
                    # the proposer/critic returns much more than requested.
                    allowance = max(1000, (self.limits.context_chars-len(context['context'])-2000)//2)
                    for field in ('proposal', 'critique'):
                        if len(context[field]) > allowance:
                            context[field] = context[field][:allowance] + '\n[Truncated; use source experience to validate.]'
                prompt = role.prompt.format_map(context).strip()
                if len(prompt) > self.limits.context_chars:
                    raise ValueError('Prompt exceeds context limit; consolidate memory')
                if result.tokens+self.limits.tokens_per_call > job['reserved']:
                    raise ValueError('Flow budget allowance exhausted')
                llm = self.factory.spawn(LLMSpec(role=step, model=role.model))
                started = datetime.now(timezone.utc).isoformat()
                row = dict(id=uuid4().hex, job=job['id'], flow=job['flow'], role=step,
                           time=started, started=started, status='running', usage=None,
                           historical=False, approximate_time=False, prompt_chars=len(prompt))
                save_record(self, row)
                if job['flow'] in {'scheduled','task','strategy'}:
                    def observed(item):
                        value = json.dumps(item, ensure_ascii=False)
                        row.setdefault('observations', []).append(dict(time=datetime.now(timezone.utc).isoformat(),
                            excerpt=value[:2000], truncated=len(value)>2000))
                        row['observations'] = row['observations'][-3:]
                        save_record(self, row)
                    llm.observation_sink = observed
                log = dict(role=step, prompt=prompt, session=llm.id, attempt=row['id'])
                result.logs.append(log)
                error = None
                try:
                    answer = llm.complete(prompt)
                    log['answer'] = answer
                    if getattr(llm, 'warning', None):
                        log['warning'] = llm.warning
                except Exception as exc:
                    error = str(exc)
                    raise
                finally:
                    usage = getattr(llm, 'usage', None)
                    count = counters(usage)
                    charged = count['units'] if count else self.limits.tokens_per_call
                    result.tokens += charged
                    log.update(session=llm.id, usage=usage, charged=charged)
                    row.update(time=datetime.now(timezone.utc).isoformat(), session=llm.id,
                               usage=usage, budget_units=charged, status='failed' if error else 'warning' if getattr(llm, 'warning', None) else 'done',
                               tools=getattr(llm, 'tool_count', None),
                               output_chars=getattr(llm, 'tool_output_chars', None),
                               repeated_tools=getattr(llm, 'repeated_tools', None))
                    save_record(self, row)
                if result.tokens > job['reserved']:
                    row['status'] = 'allowance_exceeded'
                    save_record(self, row)
                    raise ValueError('Call exceeded budget allowance; usage recorded. Review before retrying.')
                if not isinstance(answer, str):
                    raise ValueError('LLM output must be text')
                context['last'] = answer
                if llm_index == 0:
                    context['proposal'] = answer
                elif llm_index == 1:
                    context['critique'] = answer
                llm_index += 1
            result.output = context['last']
            if receipt is not None:
                patch = json.loads(result.output)
                if not isinstance(patch, dict) or set(patch) != {'upsert', 'forget'}:
                    raise ValueError('Memory output requires upsert and forget')
                # Only host-generated receipts can advance the learning cursor.
                patch['_batch_receipt'] = receipt
                result.output = json.dumps(patch, ensure_ascii=False)
        except Exception as error:
            result.error = f'{type(error).__name__}: {error}'
        return result

    def _memory_patch(self, state, output):
        patch = json.loads(output)
        receipt = patch.pop('_batch_receipt', None)
        super()._memory_patch(state, json.dumps(patch, ensure_ascii=False))
        if receipt is not None:
            state['memory_seen'] = receipt['seen']
            state['memory_pending'] = receipt['more']

    def _settle(self, state, job, tokens):
        super()._settle(state, job, tokens)
        job['budget_units'] = tokens
        # _finish archives the outcome before settling. Keep legacy job.tokens
        # raw for every existing UI consumer; admission uses only budget_units.
        logs = self.transcript(job['id'])
        warnings = [l['warning'] for l in logs if l.get('warning')]
        if warnings:
            job['warning'] = ' '.join(warnings)
        else:
            job.pop('warning', None)
        known = [counters(l.get('usage')) for l in logs]
        job['tokens'] = sum(c['total'] for c in known if c) if known else 0
