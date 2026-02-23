# Custom Fly Postgres with extensions for AI knowledge graph workloads.
# Based on fly-apps/postgres-flex with TimescaleDB, adding:
#   pgvector, Apache AGE, pg_textsearch
# Already included via postgresql-contrib: pg_trgm, ltree

ARG PG_VERSION=17.4
ARG PG_MAJOR_VERSION=17
ARG VERSION=custom

# Pin fly postgres-flex source (latest release v0.0.66)
ARG POSTGRES_FLEX_COMMIT=19b3e1311aca

# Extension versions
ARG PG_TEXTSEARCH_VERSION=0.5.1

# ---- Fetch postgres-flex source ----
FROM alpine/git:2.47.2 AS source
ARG POSTGRES_FLEX_COMMIT
RUN git clone https://github.com/fly-apps/postgres-flex.git /src \
    && cd /src && git checkout ${POSTGRES_FLEX_COMMIT}

# ---- Go builder (same as upstream) ----
FROM golang:1.23 AS builder

WORKDIR /go/src/github.com/fly-apps/fly-postgres
COPY --from=source /src/ .

RUN CGO_ENABLED=0 GOOS=linux \
    go build -v -o /fly/bin/event_handler ./cmd/event_handler && \
    go build -v -o /fly/bin/failover_validation ./cmd/failover_validation && \
    go build -v -o /fly/bin/pg_unregister ./cmd/pg_unregister && \
    go build -v -o /fly/bin/start_monitor ./cmd/monitor && \
    go build -v -o /fly/bin/start_admin_server ./cmd/admin_server && \
    go build -v -o /fly/bin/start ./cmd/start && \
    go build -v -o /fly/bin/flexctl ./cmd/flexctl

COPY --from=source /src/bin/* /fly/bin/

# ---- Main image ----
FROM ubuntu:24.04

ARG VERSION
ARG PG_MAJOR_VERSION
ARG PG_VERSION
ARG PG_TEXTSEARCH_VERSION
ARG POSTGIS_MAJOR=3
ARG HAPROXY_VERSION=2.8
ARG REPMGR_VERSION=5.5.0+debpgdg-3.pgdg24.04+1

ENV PGDATA=/data/postgresql
ENV PGPASSFILE=/data/.pgpass
ENV AWS_SHARED_CREDENTIALS_FILE=/data/.aws/credentials
ENV PG_MAJOR_VERSION=${PG_MAJOR_VERSION}
ENV PATH="/usr/lib/postgresql/${PG_MAJOR_VERSION}/bin:$PATH"

LABEL fly.app_role=postgres_cluster
LABEL fly.version=${VERSION}
LABEL fly.pg-version=${PG_VERSION}
LABEL fly.pg-manager=repmgr

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; \
    if [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \
        grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
        sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \
        ! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
    fi; \
    apt-get update; apt-get install -y --no-install-recommends locales; rm -rf /var/lib/apt/lists/*; \
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen; \
    locale-gen; \
    locale -a | grep 'en_US.utf8'
ENV LANG en_US.utf8

RUN apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates iproute2 curl bash dnsutils vim socat procps ssh gnupg rsync barman-cli barman barman-cli-cloud python3-setuptools cron gosu unzip \
    && apt autoremove -y && apt clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install PostgreSQL + extensions (pgvector, AGE from pgdg)
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install --no-install-recommends -y \
        postgresql-${PG_MAJOR_VERSION} \
        postgresql-client-${PG_MAJOR_VERSION} \
        postgresql-contrib-${PG_MAJOR_VERSION} \
        postgresql-${PG_MAJOR_VERSION}-repmgr=${REPMGR_VERSION} \
        postgresql-${PG_MAJOR_VERSION}-pgvector \
        postgresql-${PG_MAJOR_VERSION}-age

# TimescaleDB and PostGIS
RUN echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ jammy main" > /etc/apt/sources.list.d/timescaledb.list \
    && curl -L https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add -

RUN apt-get update && apt-get install --no-install-recommends -y \
    postgresql-$PG_MAJOR_VERSION-postgis-$POSTGIS_MAJOR \
    postgresql-$PG_MAJOR_VERSION-postgis-$POSTGIS_MAJOR-scripts \
    timescaledb-2-postgresql-$PG_MAJOR_VERSION \
    && apt autoremove -y && apt clean

# pg_textsearch — BM25 full-text search (prebuilt binaries from Timescale)
RUN curl -fsSL -o /tmp/pg_textsearch.zip \
    "https://github.com/timescale/pg_textsearch/releases/download/v${PG_TEXTSEARCH_VERSION}/pg-textsearch-v${PG_TEXTSEARCH_VERSION}-pg${PG_MAJOR_VERSION}-amd64.zip" \
    && cd /tmp && unzip pg_textsearch.zip -d pg_textsearch \
    && cp -r /tmp/pg_textsearch/* / \
    && rm -rf /tmp/pg_textsearch /tmp/pg_textsearch.zip

# Haproxy
RUN apt-get update && apt-get install --no-install-recommends -y \
    haproxy=$HAPROXY_VERSION.\* \
    && apt autoremove -y && apt clean

# Copy Go binaries from the builder stage
COPY --from=builder /fly/bin/* /usr/local/bin

# Copy Postgres exporter
COPY --from=wrouesnel/postgres_exporter:latest /postgres_exporter /usr/local/bin/

# Move pg_rewind into path.
RUN ln -s /usr/lib/postgresql/${PG_MAJOR_VERSION}/bin/pg_rewind /usr/bin/pg_rewind

COPY --from=source /src/config/* /fly/
RUN mkdir -p /run/haproxy/
RUN usermod -d /data postgres

ENV TIMESCALEDB_ENABLED=true

EXPOSE 5432

CMD ["start"]
