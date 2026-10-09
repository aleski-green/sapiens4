"""Chat-authored scheduled prompts, admitted by the existing minute Pulse."""
from datetime import datetime, timedelta
import re
from uuid import uuid4, uuid5, NAMESPACE_URL

from sapiens.clock import utcnow
from sapiens.validation import APIError, text_field


class ScheduledRoutines:
    RUN_LIMIT = 1000

    def __init__(self, service):
        self.service = service
        # Existing routines inherit their actual admitted occurrences, not zero.
        legacy = [r for r in service.store.routines() if 'runCount' not in r]
        if legacy:
            works = service.store.workloads()
            for routine in legacy:
                if routine['owner'].startswith('group_'):
                    runs = service.groups.get(routine['owner'])['tasks']
                    count = sum(t.get('routine') == routine['id'] for t in runs)
                else:
                    count = sum(w['origin'].get('routine') == routine['id'] for w in works)
                routine.update(runCount=count, paused=count >= self.RUN_LIMIT)
                service.store.save_routine(routine)

    def command(self, owner, text, attachments=()):
        """Recognize only the explicit chat templates, before any model execution."""
        creating = text.startswith('Add New Scheduled Routine:')
        editing = text.startswith('Edit @routine_sch_')
        changing = text.startswith(('Pause Schedule Riutine', 'Pause Scheduled Routine', 'Resume Scheduled Routine'))
        if not creating and not editing and not changing:
            return None
        if attachments:
            raise APIError(400, 'Put the execution instructions in the routine prompt')
        if changing:
            match = re.fullmatch(r'(Pause Schedule Riutine|Pause Scheduled Routine|Resume Scheduled Routine):?\s*\n@(routine_sch_[0-9]{5,})', text)
            if not match:
                raise APIError(400, 'Put the Scheduled Routine ID on the next line')
            return self.set_paused(owner, match[2], match[1].startswith('Pause'))
        pattern = (r'Add New Scheduled Routine:\s*\nFrequency: every ([0-9]+) minutes?\s*\nExecute: ([\s\S]+)'
                   if creating else
                   r'Edit @(routine_sch_[0-9]{5,}) \( [^\n]* \)\s*\nEdit Frequency \(prev every ([0-9]+) minutes?\): new every ([0-9]+) minutes?\s*\nEdit Execution Prompt as: ([\s\S]+)')
        match = re.fullmatch(pattern, text)
        if not match:
            raise APIError(400, 'Use the Scheduled Routine template with a whole number of minutes and an execution prompt')
        fields = match.groups()
        minutes, execution = int(fields[-2]), fields[-1].strip()
        return self.save(owner, minutes, execution,
                         routine_id=None if creating else fields[0],
                         previous_minutes=None if creating else int(fields[1]))

    def save(self, owner, minutes, execution, *, routine_id=None, previous_minutes=None, source_call=None):
        """One persistence path for Admin templates and Sapi host-control calls."""
        execution = text_field(dict(prompt=execution), 'prompt', 16000)
        if type(minutes) is not int or not 1 <= minutes <= 525600 or execution in {'PROMPT', 'TODO'}:
            raise APIError(400, 'Choose 1–525600 minutes and replace PROMPT with the work to execute')
        service = self.service
        with service._lock:
            if owner.startswith('group_'):
                service.groups.get(owner, active=True)
            else:
                service.lifecycle.require_active(service._agent(owner))
            routines = [r for r in service.store.routines() if r['owner'] == owner]
            routine = next((r for r in routines if r['id'] == routine_id), None)
            if routine_id and routine is None:
                raise APIError(404, 'Unknown Scheduled Routine in this conversation')
            if routine and previous_minutes is not None and routine['minutes'] != previous_minutes:
                raise APIError(409, 'Frequency changed; open Edit again for the current routine')
            if not routine_id and source_call:
                existing = next((r for r in routines if r.get('sourceCall') == source_call
                                 and r['minutes'] == minutes and r['prompt'] == execution), None)
                if existing:
                    return existing
            at = utcnow()
            value = dict(owner=owner, title=' '.join(execution.split()[:7]), minutes=minutes,
                         prompt=execution, updated=at.isoformat(),
                         nextDue=(at + timedelta(minutes=minutes)).isoformat())
            if routine:
                value = {**routine, **value}
            else:
                value['created'] = at.isoformat()
                value.update(runCount=0, paused=False)
                if source_call:
                    value['sourceCall'] = source_call
            routine = service.store.save_routine(value)
            return routine

    def set_paused(self, owner, routine_id, paused):
        with self.service._lock:
            routine = next((r for r in self.service.store.routines()
                            if r['owner'] == owner and r['id'] == routine_id), None)
            if routine is None:
                raise APIError(404, 'Unknown Scheduled Routine in this conversation')
            if routine['paused'] != paused:
                at = utcnow()
                routine.update(paused=paused, updated=at.isoformat())
                if not paused:
                    if routine['runCount'] >= self.RUN_LIMIT:
                        routine['runCount'] = 0
                    routine['nextDue'] = (at + timedelta(minutes=routine['minutes'])).isoformat()
                self.service.store.save_routine(routine)
            return routine

    @staticmethod
    def receipt(routine, text):
        action = {'Pause': 'Paused', 'Resume': 'Resumed', 'Add': 'Created'}.get(text.split()[0], 'Updated')
        status = 'Paused' if routine['paused'] else 'Planned'
        return f"{action} @{routine['id']} ( {routine['title']} )\nStatus: {status} · {routine['runCount']}/{ScheduledRoutines.RUN_LIMIT} runs\nFrequency: every {routine['minutes']} minutes\nExecute: {routine['prompt']}"

    def acknowledge(self, agent, text, routine):
        """Keep create/edit and its receipt in chat without executing the prompt."""
        turn_id = uuid4().hex
        at = utcnow().isoformat()
        reply = self.receipt(routine, text)
        with agent.transaction() as state:
            state['turns'].append(dict(id=turn_id, flow='chat', input=text, status='done',
                                      created=at, output_at=at))
            state['chat'].extend([dict(role='user', content=text, turn=turn_id, time=at),
                                  dict(role='agent', content=reply, turn=turn_id, time=at)])
        self.service._sync(agent)
        return dict(id=turn_id, agent=agent.agid, status='done', flow='chat')

    def dispatch(self, tick):
        if tick['frequency'] != 'bph60':
            return
        service = self.service
        at = utcnow()
        for routine in service.store.routines():
            if routine['paused']:
                continue
            if routine['runCount'] >= self.RUN_LIMIT:
                routine['paused'] = True
                service.store.save_routine(routine)
                continue
            due = datetime.fromisoformat(routine['nextDue'])
            if due > at:
                continue
            owner = routine['owner']
            group = service.groups.get(owner) if owner.startswith('group_') else None
            if group and group['archived']:
                continue
            agent = service._agent(group['lead'] if group else owner)
            if service.lifecycle.retired(agent):
                continue
            # A deterministic occurrence ID makes enqueue recovery idempotent.
            turn_id = uuid5(NAMESPACE_URL, routine['id'] + ':' + routine['nextDue']).hex
            origin = dict(routine=routine['id'], routineOwner=owner, title=routine['title'],
                          minutes=routine['minutes'], taskType='automated', executionPrompt=routine['prompt'])
            if group:
                origin.update(group=owner, author='admin')
                if not any(r['id'] == turn_id for r in group['requests']):
                    message = service.groups.chat.message('admin', routine['prompt'])
                    message.update(id=turn_id, routine=routine['id'])
                    group['messages'].append(message)
                    task_id = 'gtask_' + turn_id
                    group['tasks'].append(dict(id=task_id, title=routine['title'], body=routine['prompt'],
                        assignee=agent.agid, state='in_progress', deleted=False, revision=1,
                        created=at.isoformat(), author='admin', updated_by='admin', history=[], results=[],
                        taskType='automated', routine=routine['id']))
                    group['requests'].append(dict(id=turn_id, message=turn_id, target=agent.agid,
                        root=turn_id, created=at.isoformat(), status='queued', settled=False,
                        task=task_id, task_revision=1, origin=origin))
                    service.groups.save(group, 'admin', 'scheduled routine', routine['id'])
            else:
                if not service.store.projected_turn(turn_id):
                    agent.runner.submit('chat', routine['prompt'], turn_id=turn_id, origin=origin, batchable=True)
                    service._sync(agent)
                turn = dict(id=turn_id, input=routine['prompt'], origin=origin)
                work, call = service.delegation.begin(agent.agid, turn)
                if call['state'] == 'Running' and not work['decisions']:
                    call['state'] = 'Queued'
                    service.delegation.save(work)
            # Missed intervals are coalesced; waking never replays a backlog.
            interval = timedelta(minutes=routine['minutes'])
            routine['nextDue'] = (due + interval * ((at - due) // interval + 1)).isoformat()
            routine['runCount'] += 1
            routine['paused'] = routine['runCount'] >= self.RUN_LIMIT
            service.store.save_routine(routine)
        service.groups.chat.dispatch()
