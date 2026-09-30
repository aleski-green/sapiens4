"""PR #16's Call/Triage/Delegation flow, without WorkGraph or timed activation."""
from copy import deepcopy
from hashlib import sha256
import json
from time import monotonic
from uuid import uuid4

from sapiens.corpora.host.database import now
from sapiens.prompts import prompt
from sapiens.paths import ROOT
from sapiens.files import atomic_bytes
from sapiens.runtime.settings import execution_settings, model_defaults
from sapiens.validation import APIError, sapi_name, text_field


# Same state/event vocabulary as documentation/specs/WorkGraph.md, copied from PR #16.
TRANSITIONS = {
    ('Assessing', 'FitsSpecialization'): 'ReadyToWork',
    ('Assessing', 'OutsideSpecialization'): 'ChiefTriage',
    ('ChiefTriage', 'SpecialistSelected'): 'Assessing',
    ('ChiefTriage', 'NewSpecialistNeeded'): 'CreatingSapi',
    ('CreatingSapi', 'SpecialistCreated'): 'Assessing',
    ('ChiefTriage', 'RequestUnclear'): 'WaitingForAdmin',
    ('WaitingForAdmin', 'RequestClarified'): 'ChiefTriage',
    # Chief's ability to work itself is specified in the PR's prose.
    ('ChiefTriage', 'FitsSpecialization'): 'ReadyToWork',
}
PROMPTS = {
    'Assessing': 'decision-triage', 'ChiefTriage': 'decision-chief-triage',
    'CreatingSapi': 'decision-create-sapi', 'ReadyToWork': 'decision-prepare-task',
    'Delegation': 'decision-delegation', 'Execution': 'decision-execution',
}
EVENTS = {
    'Assessing': {'FitsSpecialization', 'OutsideSpecialization'},
    'ChiefTriage': {'FitsSpecialization', 'SpecialistSelected', 'NewSpecialistNeeded', 'RequestUnclear'},
    'CreatingSapi': {'SapiSpecified'}, 'ReadyToWork': {'TaskPrepared'},
    'Delegation': {'HandoffPrepared'}, 'Execution': {'Outcome', 'OutsideSpecialization'},
}
MAX_HANDOFFS = 8
FIELDS = {
    'FitsSpecialization': {'mode', 'reply'}, 'OutsideSpecialization': set(),
    'SpecialistSelected': {'target'}, 'NewSpecialistNeeded': set(), 'RequestUnclear': {'question'},
    'SapiSpecified': {'name', 'role'}, 'TaskPrepared': {'taskType', 'specification'},
    'HandoffPrepared': {'request'}, 'Outcome': {'reply', 'outcome'},
}


def yaml_scalar(value):
    # YAML does not combine JSON's surrogate-pair escapes. Keep non-BMP text
    # literal, while escaping YAML line separators and non-printable ranges.
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False)
    return ''.join('\\u%04x' % ord(c) if 0x7f <= ord(c) <= 0x9f or
                   0xd800 <= ord(c) <= 0xdfff or c in '\u2028\u2029' else c for c in raw)


def yaml_text(value, indent=0):
    """Emit the JSON-shaped read model as block YAML; all scalars use JSON quoting.

    Deliberately no YAML loader, tags, anchors, implicit scalar typing or arbitrary
    objects. JSON string escaping is also YAML double-quoted string escaping.
    """
    space = ' ' * indent
    if isinstance(value, dict) and value:
        lines = []
        for key, item in value.items():
            label = yaml_scalar(str(key))
            nested = isinstance(item, (dict, list)) and bool(item)
            lines.append(space + label + (':\n' + yaml_text(item, indent + 2) if nested
                                         else ': ' + yaml_scalar(item)))
        return '\n'.join(lines)
    if isinstance(value, list) and value:
        return '\n'.join(space + ('-\n' + yaml_text(item, indent + 2)
            if isinstance(item, (dict, list)) and item else
            '- ' + yaml_scalar(item)) for item in value)
    return space + yaml_scalar(value)


def strings(value, name, *, nonempty=False):
    if not isinstance(value, list) or len(value) > 50 or any(
            not isinstance(s, str) or not s.strip() or len(s) > 16000 for s in value) or (nonempty and not value):
        raise ValueError(f'{name} must be a list of nonempty strings')
    return value


class Delegation:
    def __init__(self, service):
        self.service = service

    def find(self, call_id):
        for work in self.service.store.workloads():
            for call in work['calls']:
                if call['callId'] == call_id:
                    return work, call
        return None, None

    def save(self, work):
        self.service.store.save_workload(work)

    def templates(self):
        rows = []
        for node, name in PROMPTS.items():
            path = self.service.root / 'decision-prompts' / (name + '.md')
            if not path.exists():
                path = ROOT / 'prompts' / (name + '.md')
            rows.append(dict(node=node, template=name + '.md', path=str(path), content=path.read_text()))
        return rows

    def edit_template(self, node, data):
        if node not in PROMPTS or set(data) != {'content'}:
            raise APIError(400, 'Unknown decision node or field')
        content = text_field(data, 'content', 20000)
        path = self.service.root / 'decision-prompts' / (PROMPTS[node] + '.md')
        atomic_bytes(path, content.encode())
        return dict(saved=True, path=str(path))

    def records(self, agid):
        rows = []
        for work in self.service.store.workloads():
            for record in work['decisions']:
                if record['agent'] == agid:
                    rows.append(json.loads(self.service._agent(agid).archive_path('decisions/' + record['decisionId']).read_text()))
        return dict(decisions=rows)

    def begin(self, agid, turn):
        work, call = self.find(turn['id'])
        if work is None:
            call = dict(callId=turn['id'], addressedTo=agid, causedBy=None,
                        node='Assessing', state='Running', request=turn['input'], attempt=1)
            work = dict(workloadId=turn['id'], originalIntent=turn['input'], tracked=False,
                        allowCreate=bool(turn.get('origin', {}).get('allowCreate')) if turn.get('origin') else False,
                        task=dict(taskId='task_' + turn['id'], taskType='work', specification=None),
                        origin=dict(agent=agid, call=turn['id']), calls=[call], decisions=[], outcome=None)
        if call.get('output') is None:
            call['state'] = 'Running'
            call.pop('error', None)
        call['attempt'] = turn.get('attempt', 1)
        self.save(work)
        return work, call

    def decide(self, agid, runner, turn, snapshot, result, node, extra=None):
        # A fresh file read makes edits effective on the next invocation; the
        # archived rendered prompt remains immutable for this invocation.
        template = PROMPTS[node]
        source = next(p for p in self.templates() if p['node'] == node)
        instruction = source['content']
        with self.service._lock:
            work, call = self.find(turn['id'])
            prepared = runner.context(snapshot, turn['input'], runner.config)
            context = dict(originalIntent=work['originalIntent'], task=work['task'], tracked=work['tracked'],
                currentCall=call, selfId=agid, chiefId=self.service.registry.main,
                team=self.service.orchestration.team(), allowCreate=work['allowCreate'],
                routingHistory=[dict(callId=c['callId'], addressedTo=c['addressedTo'], node=c['node']) for c in work['calls']],
                conversation=json.loads(prepared['context']),
                observation=extra)
            wiki = prompt('notes-wiki', notes_example=prepared['notes_example'])
            # Budget the complete decision envelope, including routing and wiki
            # guidance, before retaining optional conversation history.
            while True:
                rendered = prompt('decision-envelope', node=node, instruction=instruction,
                                  notes_wiki=wiki, context=json.dumps(context, ensure_ascii=False),
                                  events=', '.join(sorted(EVENTS[node])))
                if len(rendered) <= 60000 or not context['conversation']['chat']:
                    break
                context['conversation']['chat'].pop(0)
                context['conversation']['history_truncated'] = True
            model, effort = model_defaults()
            if execution_settings(runner.store.root)['mode'] == 'deep':
                effort = 'xhigh'
            record = dict(decisionId=uuid4().hex, callId=turn['id'], node=node,
                template=template + '.md', promptHash=sha256(instruction.encode()).hexdigest(),
                templatePath=source['path'],
                renderedPrompt=rendered, model=model, effort=effort, created=now(), accepted=False)
            runner.store.archive('decisions/' + record['decisionId'], record)
            work['decisions'].append(dict(decisionId=record['decisionId'], callId=turn['id'],
                agent=agid, node=node, promptTemplate=record['template'], promptHash=record['promptHash'], accepted=False))
            self.save(work)
        try:
            record['rawResponse'] = runner.invoke(rendered, node, result,
                                                  timeout_seconds=runner.decision_deadline - monotonic())
            if len(record['rawResponse']) > 100000:
                raise ValueError('Decision response exceeds 100000 characters')
            response = json.loads(record['rawResponse'])
            if not isinstance(response, dict) or response.get('event') not in EVENTS[node]:
                raise ValueError('Unknown decision event for ' + node)
            if set(response) - FIELDS[response['event']] - {'event', 'reason', 'evidence'}:
                raise ValueError('Unknown field in decision response')
            text_field(response, 'reason', 4000)
            strings(response.get('evidence'), 'evidence')
            record['response'] = response
        except Exception as error:
            record['error'] = str(error)
            self.record(agid, record)
            raise
        self.record(agid, record)
        return response, record

    def record(self, agid, record):
        with self.service._lock:
            agent = self.service._agent(agid)
            agent.archive('decisions/' + record['decisionId'], record)
            work, _ = self.find(record['callId'])
            summary = next(d for d in work['decisions'] if d['decisionId'] == record['decisionId'])
            summary.update({k: deepcopy(record[k]) for k in ('accepted', 'response', 'error', 'transition') if k in record})
            self.save(work)
            self.service.store.event(agid, 'decision', json.dumps(summary), turn=record['callId'])

    def accept(self, agid, record, before, after):
        event = record.get('hostEvent', record['response']['event'])
        record.update(accepted=True, transition=dict(before=before, event=event,
            after=TRANSITIONS.get((before, event), after), nextNode=after))
        self.record(agid, record)

    def validate_target(self, work, source, target):
        chief = self.service.registry.main
        if target == source or (source != chief and target != chief):
            raise APIError(400, 'Routes are Chief → Sapi or Sapi → Chief')
        recipient = self.service.orchestration.resolve(target)
        if any(t['status'] in {'queued', 'running'} for t in recipient.state['turns']):
            raise APIError(409, 'Recipient is busy; responsibility remains with the sender')
        if any(c['state'] == 'Queued' and c['addressedTo'] == target
               for w in self.service.store.workloads() for c in w['calls']):
            raise APIError(409, 'Recipient already has an accepted call')
        if len(work['calls']) > MAX_HANDOFFS:
            raise APIError(409, 'Routing limit reached; Admin must resolve the request')
        if target != chief and any(c['addressedTo'] == target for c in work['calls']):
            raise APIError(409, 'This specialist already assessed the request; ask Admin to resolve routing')
        return recipient

    def transfer(self, agid, turn, response, record, target):
        with self.service._lock:
            work, call = self.find(turn['id'])
            existing = next((c for c in work['calls'] if c['causedBy'] == turn['id']), None)
            if existing:
                return existing
            if self.service._agent(agid).runner.cancel_event.is_set():
                raise APIError(409, 'Stopped before handoff acceptance')
            self.validate_target(work, agid, target)
            request = text_field(response, 'request', 16000)
            child = dict(callId=uuid4().hex, addressedTo=target, causedBy=turn['id'],
                node='ChiefTriage' if target == self.service.registry.main else 'Assessing',
                state='Queued', request=request, handoffReason=response['reason'], attempt=1)
            call.update(state='Delegated', output='Delegated to ' + target + '.', node='Delegation')
            work['tracked'] = True
            work['calls'].append(child)
            # This is the durable dispatch intent, before touching recipient JSON.
            self.save(work)
            self.accept(agid, record, 'Delegation', child['node'])
            return child

    def apply(self, agid, decision_id):
        """Only a recorded decision for this active call can admit a handoff."""
        turn_id = self.service._active_turn(agid)
        work, call = self.find(turn_id)
        if not call or call['node'] != 'Delegation' or not any(
                d['decisionId'] == decision_id and d['callId'] == turn_id and d['node'] == 'Delegation'
                for d in work['decisions']):
            raise APIError(409, 'Delegation requires this call\'s recorded Delegation decision')
        record = json.loads(self.service._agent(agid).archive_path('decisions/' + decision_id).read_text())
        if record.get('error') or record.get('response', {}).get('event') != 'HandoffPrepared':
            raise APIError(409, 'Delegation decision has not produced a valid response')
        child = self.transfer(agid, {'id': turn_id}, record['response'], record, call['target'])
        return dict(saved=True, callId=child['callId'], target=child['addressedTo'])

    def dispatch_pending(self):
        """Startup and completion reconciliation; never a recurring Sapi job."""
        with self.service._lock:
            for work in self.service.store.workloads():
                for call in work['calls']:
                    if call['state'] != 'Queued':
                        continue
                    agent = self.service._agent(call['addressedTo'])
                    origin = dict(workloadId=work['workloadId'], taskId=work['task']['taskId'],
                                  caller=next(c['addressedTo'] for c in work['calls'] if c['callId'] == call['causedBy']),
                                  parentCall=call['causedBy'])
                    # A permanent SQL projection and active JSON both count as
                    # delivery receipts, including when old turns were archived.
                    saved = self.service.store.projected_turn(call['callId'])
                    if saved is None:
                        agent.runner.submit('chat', call['request'], turn_id=call['callId'], origin=origin)
                        self.service._sync(agent)
                    self.service._queue.put(agent.agid)

    def run(self, agid, runner, turn, snapshot, result):
        runner.decision_deadline = monotonic() + execution_settings(runner.store.root)['timeout_seconds']
        with self.service._lock:
            work, call = self.begin(agid, turn)
            if call.get('output') is not None:
                return call['output']  # A saved outcome/handoff is never replayed.
        record = None
        try:
            for _ in range(12):
                with self.service._lock:
                    work, call = self.find(turn['id'])
                    node = call['node']
                    extra = call.get('observation')
                    if node == 'CreatingSapi' and call.get('creation'):
                        # Recover a saved creation intent with the same identity.
                        created = self.service.orchestration.control(agid, dict(op='create_agent', **call['creation']))
                        call.update(target=created['agent']['id'], node='Delegation', creationReceipt=created)
                        self.save(work)
                        continue
                response, record = self.decide(agid, runner, turn, snapshot, result, node, extra)
                with self.service._lock:
                    work, call = self.find(turn['id'])
                    if runner.cancel_event.is_set():
                        raise APIError(409, 'Stopped by Admin')
                    event = response['event']
                    following = node
                    if node in {'Assessing', 'ChiefTriage'}:
                        following = TRANSITIONS[node, event]
                        if event == 'FitsSpecialization':
                            if response.get('mode') == 'Repl':
                                if work['tracked']:
                                    raise ValueError('An accepted Task must execute and report its completion criteria')
                                reply = text_field(response, 'reply', 64000)
                                call.update(output=reply, state='Completed')
                                self.accept(agid, record, node, 'Outcome')
                                work, call = self.find(turn['id'])
                                call.update(output=reply, state='Completed')
                                self.save(work)
                                return reply
                            if response.get('mode') != 'Exec':
                                raise ValueError('FitsSpecialization requires mode Repl or Exec')
                            work['tracked'] = True
                        elif event == 'OutsideSpecialization':
                            if agid != self.service.registry.main:
                                call['target'] = self.service.registry.main
                                following = 'Delegation'
                        elif event == 'SpecialistSelected':
                            target = self.service.orchestration.resolve(response.get('target')).agid
                            self.validate_target(work, agid, target)
                            call['target'] = target
                            following = 'Delegation'
                        elif event == 'NewSpecialistNeeded':
                            if not work['allowCreate']:
                                raise APIError(403, 'Admin has not enabled Sapi creation for this request')
                        elif event == 'RequestUnclear':
                            question = text_field(response, 'question', 4000)
                            call.update(state='WaitingForAdmin', output=question)
                            work['tracked'] = True
                    elif node == 'CreatingSapi':
                        if agid != self.service.registry.main or not work['allowCreate']:
                            raise APIError(403, 'Only an authorized Chief call can create a Sapi')
                        name, role = sapi_name(response), text_field(response, 'role', 60)
                        # Save the chosen creation intent before the idempotent host operation.
                        call['creation'] = dict(name=name, role=role)
                        self.save(work)
                        self.accept(agid, record, node, 'CreatingSapi')
                        try:
                            created = self.service.orchestration.control(agid, dict(op='create_agent', name=name, role=role))
                        except APIError:
                            work, call = self.find(turn['id'])
                            call.pop('creation', None)  # Definite rejection, not an uncertain side effect.
                            self.save(work)
                            raise
                        work, call = self.find(turn['id'])
                        call['target'] = created['agent']['id']
                        call['creationReceipt'] = created
                        record['hostEvent'] = 'SpecialistCreated'
                        following = 'Delegation'
                    elif node == 'ReadyToWork':
                        task_type = text_field(response, 'taskType', 60)
                        spec = response.get('specification')
                        if not isinstance(spec, dict) or set(spec) != {'objective','inputs','expectedOutputs','completionCriteria'}:
                            raise ValueError('Task specification requires objective, inputs, expectedOutputs, completionCriteria')
                        text_field(spec, 'objective', 16000)
                        for field in ('inputs', 'expectedOutputs', 'completionCriteria'):
                            strings(spec[field], field, nonempty=field != 'inputs')
                        previous = work['task']['specification']
                        if previous and not set(previous['completionCriteria']).issubset(spec['completionCriteria']):
                            raise ValueError('A handoff cannot remove accepted completion criteria')
                        work['task'].update(taskType=task_type, specification=spec)
                        following = 'Execution'
                    elif node == 'Delegation':
                        self.service.orchestration.control(agid, dict(op='delegate', decision=record['decisionId']))
                        return self.find(turn['id'])[1]['output']
                    elif node == 'Execution':
                        if event == 'OutsideSpecialization':
                            call['target'] = self.service.registry.main
                            following = 'ChiefTriage' if agid == self.service.registry.main else 'Delegation'
                        else:
                            reply = text_field(response, 'reply', 64000)
                            outcome = response.get('outcome')
                            if not isinstance(outcome, dict) or set(outcome) != {'status','satisfiedCriteria','artifacts'}:
                                raise ValueError('Outcome requires status, satisfiedCriteria, artifacts')
                            if outcome['status'] not in {'Completed', 'Unresolved'}:
                                raise ValueError('Outcome status must be Completed or Unresolved')
                            strings(outcome['satisfiedCriteria'], 'satisfiedCriteria')
                            strings(outcome['artifacts'], 'artifacts')
                            if outcome['status'] == 'Completed' and (not response['evidence'] or
                                    not set(work['task']['specification']['completionCriteria']).issubset(outcome['satisfiedCriteria'])):
                                raise ValueError('Completed outcome requires evidence for all completion criteria')
                            work['outcome'] = dict(outcome, reply=reply, evidence=response['evidence'], author=agid)
                            call.update(state=outcome['status'], output=reply)
                            following = 'Outcome'
                    call['node'] = following
                    call['observation'] = response
                    self.save(work)
                    self.accept(agid, record, node, following)
                    if call.get('output') is not None:
                        return call['output']
            raise ValueError('Decision transition limit reached; Admin must resolve the request')
        except Exception as error:
            if record and not record['accepted']:
                # A handoff may already be committed even if returning its receipt failed.
                work, _ = self.find(turn['id'])
                saved = next(d for d in work['decisions'] if d['decisionId'] == record['decisionId'])
                if saved['accepted']:
                    raise
                record['error'] = str(error)
                self.record(agid, record)
            raise

    def reconcile(self, agid=None):
        with self.service._lock:
            for work in self.service.store.workloads():
                changed = False
                for call in work['calls']:
                    if agid and call['addressedTo'] != agid:
                        continue
                    turn = self.service.store.projected_turn(call['callId'])
                    if turn and turn['status'] in {'failed', 'interrupted', 'cancelled'} and not call.get('output'):
                        call.update(state=turn['status'].capitalize(), error=turn['error'])
                        changed = True
                if changed:
                    self.save(work)

    def tasks(self, agid, full=False):
        items = []
        with self.service._lock:
            for work in self.service.store.workloads():
                if not work['tracked'] or not any(c['addressedTo'] == agid for c in work['calls']):
                    continue
                last = work['calls'][-1]
                item = dict(task=work['task'], workloadId=work['workloadId'], originalIntent=work['originalIntent'],
                    execution=dict(state=last['state'], owner=last['addressedTo'], currentCall=last['callId'],
                                   attempt=last['attempt']), calls=work['calls'], decisions=deepcopy(work['decisions']), outcome=work['outcome'])
                if full:
                    for decision in item['decisions']:
                        path = self.service._agent(decision['agent']).archive_path('decisions/' + decision['decisionId'])
                        decision.update(json.loads(path.read_text()))
                items.append(item)
        return dict(tasks=items)

    def task_list(self, agid):
        """Small UI envelope; only the task specification is a YAML body."""
        rows = []
        for item in self.tasks(agid)['tasks']:
            body = item['task']['specification'] or dict(objective=item['originalIntent'])
            rows.append(dict(id=item['workloadId'], title=body['objective'],
                state=item['execution']['state'], owner=item['execution']['owner'],
                sender=item['calls'][0]['addressedTo'], body=yaml_text(body) + '\n',
                result=(item['outcome'] or {}).get('reply'),
                error=item['calls'][-1].get('error')))
        return dict(tasks=list(reversed(rows)))

    def clarify(self, agid, workload_id, message):
        work = next((w for w in self.service.store.workloads() if w['workloadId'] == workload_id), None)
        if not work or work['calls'][-1]['state'] != 'WaitingForAdmin' or agid != self.service.registry.main:
            raise APIError(409, 'Clarification requires the waiting Chief call')
        previous = work['calls'][-1]
        call = dict(callId=uuid4().hex, addressedTo=agid, causedBy=previous['callId'],
                    node='ChiefTriage', state='Queued', request=message,
                    activation='RequestClarified', attempt=1)
        work['calls'].append(call)
        self.save(work)
        self.dispatch_pending()
        return call['callId']

    def summaries(self, workloads):
        result = []
        for work in workloads:
            if not work['tracked']:
                continue
            call = work['calls'][-1]
            result.append(dict(id=work['workloadId'], taskId=work['task']['taskId'], origin=work['origin'],
                callId=call['callId'], owner=call['addressedTo'], state=call['state'],
                participants=list(dict.fromkeys(c['addressedTo'] for c in work['calls'])),
                output=call.get('output'), error=call.get('error'),
                decisions=len(work['decisions']), calls=len(work['calls'])))
        return result
