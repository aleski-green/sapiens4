"""Small JSON command for Sapis to call their running local host."""
import json
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    try:
        config = json.loads(Path(sys.argv[1]).read_text())
        payload = json.loads(sys.argv[2])
        if not isinstance(payload, dict):
            raise ValueError("Expected a JSON object")
        request = Request(config["url"], data=json.dumps(payload).encode(), headers={
            "Content-Type": "application/json", "X-Sapiens-Local": "1"})
        with urlopen(request, timeout=20) as response:
            print(response.read().decode())
    except HTTPError as error:
        print(error.read().decode())
        return 1
    except (IndexError, ValueError, OSError, URLError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
