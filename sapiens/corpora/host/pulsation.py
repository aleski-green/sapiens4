"""Global Corpora clock, batch admission policy, and durable pulse identities."""
from dataclasses import dataclass
from enum import Enum
from time import monotonic
from typing import Callable
from uuid import uuid4


class CallDecision(Enum):
    Call = 'call'
    NoCall = 'nocall'


@dataclass(frozen=True)
class AgencyBatch:
    items: tuple

    def __bool__(self):
        return bool(self.items)


@dataclass(frozen=True)
class BatchPolicy:
    pulsation: str = 'bpm60'
    every: int = 2
    decide: Callable = lambda batch: CallDecision.Call if batch else CallDecision.NoCall

    def __post_init__(self):
        if self.pulsation not in SystemPulse.INTERVALS or type(self.every) is not int or self.every < 1:
            raise ValueError('Choose a known pulsation and a positive integer batch interval')
        if not callable(self.decide):
            raise ValueError('BatchPolicy.decide must accept an AgencyBatch')

    def admits(self, tick, batch):
        return (tick['frequency'] == self.pulsation and tick['num'] % self.every == 0
                and self.decide(batch) is CallDecision.Call and bool(batch))


class SystemPulse:
    INTERVALS = {'bpm120': .5, 'bpm60': 1., 'bph60': 60.}

    def __init__(self, store, dispatch, *, clock=monotonic):
        self.store, self.dispatch, self.clock = store, dispatch, clock
        saved = store.pulse_state()
        self.identity = saved.get('pulse', 'pulse_' + uuid4().hex)
        self.numbers = {freq: saved.get('numbers', {}).get(freq, 0) for freq in self.INTERVALS}
        self.running = False
        self.deadlines = {}

    def start(self):
        if not self.running:
            at = self.clock()
            self.deadlines = {freq: at + interval for freq, interval in self.INTERVALS.items()}
            self.running = True

    def stop(self):
        self.running = False

    def step(self, at=None):
        """Advance every clock, including NoCall ticks. Never replay missed calls."""
        if not self.running:
            return
        at = self.clock() if at is None else at
        for frequency, interval in self.INTERVALS.items():
            if not self.running:
                break
            deadline = self.deadlines[frequency]
            if at < deadline:
                continue
            elapsed = int((at - deadline) // interval) + 1
            self.deadlines[frequency] += elapsed * interval
            self.numbers[frequency] += elapsed
            self.store.save_pulse_state(dict(pulse=self.identity, numbers=self.numbers))
            number = self.numbers[frequency]
            self.dispatch(dict(pulse=self.identity, frequency=frequency, num=number,
                               pulseId=f'{self.identity}:{frequency}:{number}'))
