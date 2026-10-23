FROM python:3.12-slim AS build
WORKDIR /w
COPY requirements.txt .
RUN python -m venv /venv && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .
RUN useradd -r -u 10001 app
USER app
ENV PATH=/venv/bin:$PATH PYTHONUNBUFFERED=1
EXPOSE 5000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD python -c "import urllib.request as u;u.urlopen('http://127.0.0.1:5000/health',timeout=2)"
CMD ["sh","-c","python -c 'import app;app.seed_admin()' && exec gunicorn -b 0.0.0.0:5000 -w 4 app:app"]
