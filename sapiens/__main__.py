from pathlib import Path
import argparse
import signal
import threading
import webbrowser
import sys

from sapiens.corpora.host.assets import index, javascript
from sapiens.paths import ROOT
from sapiens.corpora.host.server import Server
from sapiens.corpora.host.service import Service
from sapiens.files import atomic_json


def main():
    parser = argparse.ArgumentParser(description="Run local Sapiens4 / CORPORA")
    parser.add_argument("--port", type=int, default=4174)
    parser.add_argument("--data-dir", type=Path, default=ROOT / ".sapiens4")
    parser.add_argument("--open", action="store_true", help="Open the UI in your browser")
    parser.add_argument("--desktop", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    index(), javascript()  # Check required frontend assets before starting workers.
    service = Service(args.data_dir, start_worker=False)
    try:
        server = Server(args.port, service)
    except BaseException:
        service.close()
        raise
    service.start()  # Recovered chat turns need the host-control endpoint attached first.
    if args.desktop:
        atomic_json(service.root / 'config.json', {'port': server.server_port})
    url = f"http://127.0.0.1:{server.server_port}/workspace/"
    print(f"Sapiens4: {url}\nUI database: {service.store.path}", flush=True)

    def shutdown(signum, frame):
        print("Stopping; waiting for the current Codex call to finish…", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    if args.desktop:
        def watch_parent():
            # A private inherited pipe: EOF also shuts down after a desktop crash.
            sys.stdin.readline()
            with service._lock:
                for agent in service._agents.values():
                    agent.runner.cancel_event.set()
            server.shutdown()
        threading.Thread(target=watch_parent, daemon=True).start()
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        service.close()


if __name__ == "__main__":
    main()
