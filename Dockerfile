# This image runs only the public remote relay, never the local CORPORA runtime.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY libs4/python/relay-requirements.txt ./libs4/python/relay-requirements.txt
RUN pip install --no-cache-dir -r libs4/python/relay-requirements.txt
COPY sapiens/__init__.py sapiens/paths.py sapiens/files.py ./sapiens/
COPY sapiens/corpora/__init__.py ./sapiens/corpora/
COPY sapiens/corpora/host/__init__.py sapiens/corpora/host/assets.py sapiens/corpora/host/identity.py sapiens/corpora/host/remote_pairing.py sapiens/corpora/host/remote_setup.py sapiens/corpora/host/remote_relay.py ./sapiens/corpora/host/
COPY web/ ./web/
COPY libs4/web/ ./libs4/web/
COPY libs4/license/ ./libs4/license/
COPY license/ ./license/
ENV SAPIENS_RELAY_BIND=0.0.0.0 SAPIENS_RELAY_DB=/data/relay.sqlite3
CMD ["python", "-m", "sapiens.corpora.host.remote_relay"]
