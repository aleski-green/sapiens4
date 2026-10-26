from pathlib import Path
from time import monotonic
import threading
from sapiens.corpora.sapis.registry import Registry
from sapiens.corpora.sapis.retirement import Lifecycle
from sapiens.corpora.host.agency import ChatAgencies
from sapiens.corpora.host.routines import ScheduledRoutines
from sapiens.corpora.host.pulsation import SystemPulse
from sapiens.corpora.host.commands import Orchestration
from sapiens.corpora.host.delegation import Delegation
from sapiens.paths import blindly_binary
from sapiens.corpora.host.groups import Groups
from sapiens.files import lock_file
from sapiens.corpora.host.database import Store
from sapiens.corpora.host.identity import corpora_id
from sapiens.corpora.host.corpora_settings import CorporaSettings
from sapiens.corpora.browser import Workspace

from .population import Population, random_avatar
from .execution import Execution
from .projection import Projection


class Service:
    def __init__(self, data_dir, *, factory_builder=None, start_worker=True, max_parallel_agents=4, pulse_clock=monotonic):
        if type(max_parallel_agents) is not int or not 1 <= max_parallel_agents <= 32:
            raise ValueError("max_parallel_agents must be between 1 and 32")
        self.root = Path(data_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.corpora_id = corpora_id(self.root)
        self._file_lock = (self.root / "host.lock").open("a")
        try:
            lock_file(self._file_lock, blocking=False)
        except BlockingIOError:
            self._file_lock.close()
            raise RuntimeError("Another Sapiens4 server is using this data directory") from None
        self.store = Store(self.root / "corpora.sqlite3")
        self.population = Population(self)
        self.execution = Execution(self)
        self.projection = Projection(self)
        self.workspace = Workspace(self)
        # Repair old repeated default faces once; the resulting avatars persist.
        used = set()
        for row in self.store.agents():
            if row["face"] in used:
                row.update(random_avatar(used))
                self.store.update_avatar(row["id"], row)
            used.add(row["face"])
        self.binary = blindly_binary()
        self.factory_builder = factory_builder
        self._lock = threading.RLock()
        self.execution.max_parallel_agents = max_parallel_agents
        self.orchestration = Orchestration(self)
        self.lifecycle = Lifecycle(self)
        self.registry = Registry(self)
        self.corpora_settings = CorporaSettings(self)
        self.delegation = Delegation(self)
        self.groups = Groups(self)
        self.agencies = ChatAgencies(self)
        self.routines = ScheduledRoutines(self)
        self.pulse = SystemPulse(self.store, self.execution.on_pulse, clock=pulse_clock)
        if not self.store.agents():
            self.population.create_agent({"name": "ChiefSapi", "role": "Head of Corpora"})
        for row in self.store.agents():
            agent = self.population.agent(row["id"])
            self.agencies.recover(agent)
            self.projection.sync(agent)
            # Public run() recovers running turns to interrupted without replaying.
            # Only previously queued, never-started work is admitted automatically.
            if not self.lifecycle.retired(agent) and any(j["status"] in {"queued", "running"} for j in agent.state["turns"]):
                self.execution.queue.put(row["id"])
        self.registry.repair()
        self.delegation.reconcile()
        self.delegation.dispatch_pending()
        self.groups.chat.reconcile()
        self.groups.chat.dispatch()
        self.store.events.record(self.registry.main, 'corpora', 'system.started', {}, actor='system')
        if start_worker:
            self.start()


    def start(self):
        self.execution.start()

    def close(self):
        self.execution.close()
