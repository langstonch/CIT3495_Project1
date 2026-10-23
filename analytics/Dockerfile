# Production image. The C3 baseline is Dockerfile.baseline.
FROM python:3.12-slim AS build
WORKDIR /w
COPY requirements.runtime.txt .
RUN python -m venv /venv && /venv/bin/pip install --no-cache-dir -r requirements.runtime.txt

FROM python:3.12-slim
COPY --from=build /venv /venv
WORKDIR /app
COPY stats.py job.py ./
RUN useradd -r -u 10001 app
USER app
ENV PATH=/venv/bin:$PATH PYTHONUNBUFFERED=1
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD ["python", "-c", "import os,time,sys; p=os.environ.get('HEARTBEAT_PATH','/tmp/heartbeat'); sys.exit(0 if time.time()-os.stat(p).st_mtime<60 else 1)"]
CMD ["python", "job.py"]
