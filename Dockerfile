# One image for every Python service of the project (simulator, ingest, processor, API).
# The default entrypoint is the simulator, so `docker run market-sim --interval-min 400` still works.
# docker-compose.yml overrides the entrypoint/command for the other services.
FROM python:3.11-slim

# psql is needed by the one-shot schema job (the SQL install files use \ir and \copy)
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY simulator ./simulator
COPY ingest ./ingest
COPY pipeline ./pipeline
COPY api ./api
COPY dashboard ./dashboard
COPY sql ./sql
COPY data ./data

ENV PYTHONUNBUFFERED=1
EXPOSE 1337 8000

ENTRYPOINT ["python", "-m", "simulator"]
