"""Opt-in macOS benchmark: real model, Blindly4, timer admission and local UI.

Build tests/fixtures/AutonomyFixture.swift, then pass --fixture /path/to/binary.
Uses isolated CORPORA, never Telegram or production runtime data. The accelerated
clock tests consecutive six-hour occurrences; it is not a real-time soak test.
"""
import argparse
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import threading
import time
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sapiens.server import Server
from sapiens.service import Service


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--output', type=Path, default=Path('.test-output/autonomy-live') / uuid4().hex)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 12:
        parser.error('Use 1–12 bounded live test cycles')
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    ledger = root / 'delivery-ledger.jsonl'
    app = root/'AutonomyFixture.app'
    (app/'Contents/MacOS').mkdir(parents=True)
    shutil.copy2(args.fixture.resolve(), app/'Contents/MacOS/AutonomyFixture')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleExecutable='AutonomyFixture', CFBundleIdentifier='local.sapiens.autonomy-fixture',
        CFBundleName='Sapiens Autonomy Fixture', CFBundlePackageType='APPL', NSHighResolutionCapable=True)))
    fixture = subprocess.Popen(['/usr/bin/open', '-n', '-W', str(app), '--args', str(ledger)])
    for _ in range(100):
        if (root/'fixture.pid').exists():
            break
        time.sleep(.05)
    service = server = None
    started = time.monotonic()
    summary = dict(kind='real-model-local-UI', accelerated_clock=True, cycles=args.cycles, passed=False, runs=[])
    print('Benchmark evidence:', root, flush=True)

    def open_host():
        host = Service(root/'corpora', start_worker=False, timeout=240)
        api = Server(0, host)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        return host, api

    def close_host():
        nonlocal service, server
        if server:
            server.shutdown()
            server.server_close()
        if service:
            service.close()
        service = server = None

    try:
        service, server = open_host()
        agent = service._agent(service.hierarchy.main)
        service.orchestration.control(agent.agid, dict(op='schedule', enabled=False))
        agent.configure(dict(weekly_limit=10000000, call_allowance=1000000,
                             max_tools=35, timeout_seconds=240, output_tokens=1600))
        row = service.work.upsert(agent, dict(title='Local UI delivery benchmark', minutes=360,
            watch={'mode': 'always'}, prompt=(
                'Admin authorizes one short fresh AGI joke per admitted occurrence to Local test recipient '
                'in the running native window Sapiens Autonomy Fixture. Use Blindly4 UI only for this '
                'local submission; do not interact with other apps, inspect fixture source, or read/write '
                'fixture files. Verify window and visible recipient, avoid exact duplicates in visible '
                'outgoing history, discover and inspect the current editable Message draft control, '
                'guarded-paste the joke, and press the verified Send Message button with exact draft '
                'guard. Verify a new Outgoing message and empty draft. Save an ok/useful checkpoint '
                'only after both checks. The UI may rebuild controls after a send; never reuse historical '
                'numeric paths. Stop on uncertain outcome and report the precise blocker.')))
        due = datetime.fromisoformat(row['next_run'])
        for cycle in range(args.cycles):
            instant = due + timedelta(hours=6*cycle)
            # Permit one planning pass then timer-based execution; never run_job.
            for tick in range(2):
                service.scheduled(instant+timedelta(seconds=tick))
                saved = service.work.read(agent)[0]
                checkpoint = saved.get('checkpoint', {})
                if checkpoint.get('status') == 'ok' and checkpoint.get('run') not in {r['id'] for r in summary['runs']}:
                    break
            records = [json.loads(line) for line in ledger.read_text().splitlines()] if ledger.exists() else []
            execution = [r for r in saved['runs'] if r.get('kind') != 'strategy']
            run = next((j for j in agent.state['jobs'] if execution and j['id'] == execution[-1]['id']), None)
            passed = (len(records) == cycle+1 and len({r['text'] for r in records}) == len(records)
                      and all(r['recipient'] == 'Local test recipient' for r in records)
                      and run and run['status'] == 'done' and checkpoint.get('run') == run['id']
                      and checkpoint.get('status') == 'ok' and checkpoint.get('outcome') == 'useful'
                      and saved['strategy']['status'] == 'ready')
            summary['runs'].append(dict(id=run['id'] if run else None, passed=bool(passed),
                due=instant.isoformat(), actual_deliveries=len(records),
                strategy=saved.get('strategy'), checkpoint=checkpoint,
                feedback=saved.get('feedback'), error=run.get('error') if run else 'No execution admitted'))
            (root/'summary.json').write_text(json.dumps(summary, indent=2))
            print(f'Cycle {cycle+1}: {"PASS" if passed else "FAIL"}; independently recorded deliveries={len(records)}', flush=True)
            if not passed:
                raise RuntimeError('Autonomy benchmark failed; see retained isolated run evidence')
            # Cold provider sessions already occur per run; restart the host too.
            close_host()
            service, server = open_host()
            agent = service._agent(agent.agid)
            service.scheduled(instant+timedelta(seconds=3))
            assert len(ledger.read_text().splitlines()) == cycle+1, 'Restart duplicated delivery'
        summary['passed'] = True
    finally:
        summary['elapsed_seconds'] = round(time.monotonic()-started, 2)
        (root/'summary.json').write_text(json.dumps(summary, indent=2))
        if server:
            close_host()
        if (root/'fixture.pid').exists():
            try:
                os.kill(int((root/'fixture.pid').read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        fixture.terminate()
        fixture.wait(timeout=10)
    print(json.dumps(dict(passed=True, cycles=args.cycles, elapsed_seconds=summary['elapsed_seconds'])), flush=True)


if __name__ == '__main__':
    main()
