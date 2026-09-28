"""Chat execution with durable usage accounting and per-Sapi allowances."""
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo
import json

from .sdk import LLMSpec, Outcome, PersistentAgent, atomic_bytes
from .usage import backfill, counters, save_record, settings


class SapiAgent(PersistentAgent):

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        backfill(self)
        self.configure()
        # Discount only verifiable cached usage in old ledgers. Preserve unknown
        # retry/crash charges. Atomic marker prevents crediting twice on restart.
        if not self.state.get('budget_policy'):
            with self.store.transaction() as state:
                for turn in state['turns']:
                    ledger = state['budgets'].get(turn.get('sprint'))
                    if not ledger or turn['status'] == 'running':
                        continue
                    logs = self.transcript(turn['id'])
                    raw = sum((counters(l.get('usage')) or {}).get('total', 0) for l in logs)
                    units = sum((counters(l.get('usage')) or {}).get('units', 0) for l in logs)
                    if raw and raw == turn['tokens']:
                        ledger['spent'] = max(0, ledger['spent']-(raw-units))
                        turn['budget_units'] = units
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
        reset = datetime.fromisoformat(sprint).replace(tzinfo=ZoneInfo(self.budget_calendar['timezone'])) + timedelta(days=self.budget_calendar['sprint_days'])
        return dict(**ledger, limit=self.limits.tokens_per_sprint,
                    remaining=max(0, self.limits.tokens_per_sprint-ledger['spent']-ledger['reserved']),
                    resets_at=reset.isoformat(), cached_weight_percent=10)

    def can_admit(self, flow, instant=None):
        required = sum(isinstance(s, str) for s in self.config.flows[flow].steps)*self.limits.tokens_per_call
        return self.budget_status(instant)['remaining'] >= required


    def _work(self, turn, snapshot, config):
        result = Outcome()
        try:
            context = self._context(snapshot, turn['input'])
            llm_index = 0
            for step in config.flows[turn['flow']].steps:
                role = config.roles[step]
                prompt = role.prompt.format_map(context).strip()
                if len(prompt) > self.limits.context_chars:
                    raise ValueError('Prompt exceeds context limit; shorten the conversation or notes')
                if result.tokens+self.limits.tokens_per_call > turn['reserved']:
                    raise ValueError('Flow budget allowance exhausted')
                llm = self.factory.spawn(LLMSpec(role=step, model=role.model))
                started = datetime.now(timezone.utc).isoformat()
                row = dict(id=uuid4().hex, turn=turn['id'], flow=turn['flow'], role=step,
                           time=started, started=started, status='running', usage=None,
                           historical=False, approximate_time=False, prompt_chars=len(prompt))
                save_record(self, row)
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
                if result.tokens > turn['reserved']:
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
        except Exception as error:
            result.error = f'{type(error).__name__}: {error}'
        return result


    def _settle(self, state, turn, tokens):
        super()._settle(state, turn, tokens)
        turn['budget_units'] = tokens
        # _finish archives the outcome before settling. Keep legacy turn.tokens
        # raw for every existing UI consumer; admission uses only budget_units.
        logs = self.transcript(turn['id'])
        warnings = [l['warning'] for l in logs if l.get('warning')]
        if warnings:
            turn['warning'] = ' '.join(warnings)
        else:
            turn.pop('warning', None)
        known = [counters(l.get('usage')) for l in logs]
        turn['tokens'] = sum(c['total'] for c in known if c) if known else 0
