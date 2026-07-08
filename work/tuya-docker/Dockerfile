FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN python -m pip install --no-cache-dir tinytuya==1.20.0

WORKDIR /data

ENTRYPOINT ["python", "-m", "tinytuya"]
CMD ["help"]
