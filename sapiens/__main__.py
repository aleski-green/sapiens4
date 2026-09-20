from pathlib import Path
import argparse
import signal
import threading
import webbrowser

from .assets import index, javascript
from .paths import ROOT
from .server import Server
from .service import Service


def main():
    parser = argparse.ArgumentParser(description="Run local Sapiens4 / CORPORA")
    parser.add_argument("--port", type=int, default=4174)
    parser.add_argument("--data-dir", type=Path, default=ROOT / ".sapiens4")
    parser.add_argument("--timeout", type=int, default=300, help="Codex call deadline in seconds")
    parser.add_argument("--open", action="store_true", help="Open the UI in your browser")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    index(), javascript()  # Fail early if the pinned frontend contract changed.
    service = Service(args.data_dir, timeout=args.timeout, start_worker=False)
    try:
        server = Server(args.port, service)
    except BaseException:
        service.close()
        raise
    service.start()  # Recovered jobs need the host-control endpoint attached first.
    url = f"http://127.0.0.1:{server.server_port}/workspace/"
    print(f"Sapiens4: {url}\nUI database: {service.store.path}", flush=True)

    def shutdown(signum, frame):
        print("Stopping; waiting for the current bounded Codex call to finish…", flush=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        service.close()


if __name__ == "__main__":
    main()
