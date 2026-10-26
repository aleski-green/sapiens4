from __future__ import annotations

import asyncio
import logging
import queue
import threading
from sapiens.files import unlock_file
from sapiens.validation import APIError


class Execution:
    def __init__(self, host):
        self.host = host
        self.queue = queue.Queue()
        self.stopping = threading.Event()
        self.owner: str | None = None
        self.turn: str | None = None
        self.local = threading.local()
        self.runners: dict[str, threading.Thread] = {}
        self.worker: threading.Thread | None = None

    def start(self):
        if self.host.corpora_settings.value['status'] == 'active':
            self.host.pulse.start()
        if self.worker is None:
            self.worker = threading.Thread(target=self.work, name="sapiens-runner", daemon=True)
            self.worker.start()

    def acquire_computer(self, agid):
        with self.host._lock:
            if not self.active_turn(agid):
                raise APIError(409, "Computer access requires a running Sapi turn")
            if self.owner not in (None, agid):
                raise APIError(409, "Shared computer is busy with another Sapi. Continue non-UI work or report the blocker; do not retry in a loop.")
            turn_id = self.active_turn(agid)
            if self.turn not in (None, turn_id):
                raise APIError(409, "Shared computer is busy with another AgencyRun")
            self.owner = agid
            self.turn = turn_id
            return {"owner": agid}

    def release_computer(self, agid, restore=lambda: None, *, turn_id=None):
        # Keep ownership while restoring focus; another Sapi must not begin UI
        # work between the last action and the return to CORPORA.
        with self.host._lock:
            turn_id = turn_id or getattr(self.local, 'turn', None)
            if self.owner != agid or (turn_id and self.turn != turn_id):
                return None
        try:
            return restore()
        finally:
            with self.host._lock:
                if self.owner == agid:
                    self.owner = None
                    self.turn = None

    def active_turn(self, agid):
        agent = self.host.population.agents.get(agid)
        specific = getattr(self.local, 'turn', None)
        if agent and specific:
            return next((t['id'] for t in agent.state['turns'] if t['id'] == specific and t['status'] == 'running'), None)
        if agent:
            return next((j["id"] for j in agent.state["turns"] if j["status"] == "running"), None)
        return None

    def run_queued(self, agid, *, legacy_only=False):
        host = self.host
        with host._lock:
            agent = host.population.agent(agid)
            if legacy_only and (not host.pulse.running or self.stopping.is_set()):
                return
            if host.lifecycle.retired(agent) or not any(
                    j['status'] in {'queued', 'running'} for j in agent.state['turns']):
                return
            host.orchestration.prepare(agent)
        with host.store.events.context(agid, 'chatInput'):
            asyncio.run(agent.runner.run(legacy_only=legacy_only))

    def dispatch(self, agid, tick=None):
        host = self.host
        with host._lock:
            if host.lifecycle.retired(host.population.agent(agid)):
                return False
            owners = {key[0] for key in host.agencies.slots} | set(self.runners)
            if (not host.pulse.running or self.stopping.is_set() or agid in owners
                    or len(owners) >= self.max_parallel_agents):
                return False
            host.population.agent(agid).runner.cancel_event.clear()
            def run():
                try:
                    self.run_queued(agid, legacy_only=True)
                except Exception:
                    logging.exception("Sapi runner failed: %s", agid)
                finally:
                    try:
                        self.release_computer(agid)
                        with host._lock:
                            host.projection.sync(host.population.agent(agid))
                    finally:
                        with host._lock:
                            self.runners.pop(agid, None)
                            host.delegation.reconcile(agid)
                            host.delegation.dispatch_pending()
                            host.groups.chat.reconcile()
                            host.groups.chat.dispatch()
            thread = threading.Thread(target=run, name=f'sapiens-{agid}', daemon=True)
            self.runners[agid] = thread
            if tick:
                host.store.record_pulse_call(tick, agid, 'chatInput', 1,
                    groups={t['origin']['group'] for t in host.population.agent(agid).state['turns']
                            if t['status'] in {'queued', 'running'} and (t.get('origin') or {}).get('group')})
            thread.start()
            return thread

    def on_pulse(self, tick):
        host = self.host
        with host._lock:
            if not host.pulse.running or self.stopping.is_set():
                return
            host.routines.dispatch(tick)
            host.agencies.dispatch(tick)
            if tick['frequency'] == 'bpm60' and tick['num'] % host.agencies.policies['chatInput'].every == 0:
                host.delegation.dispatch_pending()
                host.groups.chat.reconcile()
                host.groups.chat.dispatch()
                for agent in list(host.population.agents.values()):
                    if any(t['status'] == 'queued' and not t.get('batchable') for t in agent.state['turns']):
                        self.dispatch(agent.agid, tick)

    def stop_pulse(self):
        host = self.host
        with host._lock:
            host.pulse.stop()
            host.agencies.cancel_all()
            for agid in self.runners:
                host.population.agent(agid).runner.cancel_event.set()

    def work(self):
        while not self.stopping.wait(.05):
            try:
                with self.host._lock:
                    self.host.pulse.step()
                # Compatibility wakeups no longer start execution themselves.
                while True:
                    try:
                        self.queue.get_nowait()
                    except queue.Empty:
                        break
            except Exception:
                logging.exception('System Pulse dispatch failed')

    def close(self):
        host = self.host
        if host._file_lock.closed:
            return
        self.stopping.set()
        self.stop_pulse()
        self.queue.put(None)
        if self.worker:
            self.worker.join()
        with host._lock:
            runners = list(self.runners.values()) + [entry[1] for entry in host.agencies.slots.values()]
        for runner in runners:
            runner.join()  # Retain host.lock until every call has finished.
        host.store.events.record(host.registry.main, 'corpora', 'system.stopped', {}, actor='system')
        unlock_file(host._file_lock)
        host._file_lock.close()
