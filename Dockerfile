# This image runs only the public remote relay, never the local CORPORA runtime.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN pip install --no-cache-dir aiohttp==3.13.5
COPY sapiens/__init__.py sapiens/paths.py sapiens/files.py ./sapiens/
COPY sapiens/corpora/__init__.py ./sapiens/corpora/
COPY sapiens/corpora/host/__init__.py sapiens/corpora/host/assets.py sapiens/corpora/host/identity.py sapiens/corpora/host/remote_pairing.py sapiens/corpora/host/remote_setup.py sapiens/corpora/host/remote_relay.py ./sapiens/corpora/host/
COPY web/ ./web/
COPY license/ ./license/
ENV SAPIENS_RELAY_BIND=0.0.0.0 SAPIENS_RELAY_DB=/data/relay.sqlite3
CMD ["python", "-m", "sapiens.corpora.host.remote_relay"]
