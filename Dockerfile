# syntax=docker/dockerfile:1.7
FROM python:3.11-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev && rm -rf /var/lib/apt/lists/*

FROM base AS builder
WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
COPY services ./services
COPY shared ./shared
COPY schema ./schema
ARG SERVICE=search
RUN pip install --upgrade pip && \
    mkdir -p /wheels && \
    case "$SERVICE" in \
      search)   pip wheel --no-cache-dir .[search,common] -w /wheels/$SERVICE ;; \
      gateway)  pip wheel --no-cache-dir .[gateway,common] -w /wheels/$SERVICE ;; \
      catalog)  pip wheel --no-cache-dir .[catalog,common] -w /wheels/$SERVICE ;; \
      worker_service) pip wheel --no-cache-dir .[common] -w /wheels/$SERVICE ;; \
      *)        pip wheel --no-cache-dir . -w /wheels/$SERVICE ;; \
    esac && \
    rm -rf /wheels/current || true && \
    cp -a /wheels/$SERVICE /wheels/current

FROM base AS runtime
WORKDIR /app
ARG SERVICE=search
COPY --from=builder /wheels /wheels
RUN pip install --no-cache /wheels/current/* && rm -rf /wheels
COPY src ./src
COPY services ./services
COPY shared ./shared
COPY schema ./schema
ENV SERVICE=${SERVICE}
ENTRYPOINT ["bash","-lc","case \"$SERVICE\" in search) exec search-service --host 0.0.0.0 --port 8080 ;; gateway) exec uvicorn services.gateway_api.app:app --host 0.0.0.0 --port 8080 ;; catalog) exec uvicorn services.catalog_api.app:app --host 0.0.0.0 --port 8081 ;; worker_service) exec python services/worker_service/main.py ;; *) exec search-service --host 0.0.0.0 --port 8080 ;; esac"]
