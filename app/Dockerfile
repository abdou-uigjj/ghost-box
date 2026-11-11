# ghost-box submission api
# python 3.12 alpine, zero pip dependencies - nothing to scan, nothing to trust
FROM python:3.12-alpine3.22

RUN apk upgrade --no-cache \
    && addgroup -S gb && adduser -S -G gb -u 10001 gb \
    && mkdir -p /dev/shm/submissions \
    && chown gb:gb /dev/shm/submissions

COPY --chown=gb:gb submission_api.py /opt/ghost-box/submission_api.py

USER 10001
WORKDIR /opt/ghost-box
ENV GB_BIND=0.0.0.0 GB_PORT=8080 TMPDIR=/dev/shm
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"

CMD ["python", "-u", "submission_api.py"]
