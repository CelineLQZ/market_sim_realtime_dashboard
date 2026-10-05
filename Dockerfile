FROM python:3.11-slim

WORKDIR /app
COPY simulator ./simulator
COPY data ./data

EXPOSE 1337

# Pass options after the image name, e.g.:
#   docker run --rm -p 1337:1337 market-sim --interval-min 400 --interval-max 800
ENTRYPOINT ["python", "-m", "simulator"]
