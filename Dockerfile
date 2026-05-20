# syntax=docker/dockerfile:1.7
#
# PgBouncer multi-stage build.
# Produces a slim Alpine runtime image with the pgbouncer binary,
# built with c-ares (async DNS) and OpenSSL/TLS support.
#
# Build:
#   docker build -t <registry>/pgbouncer:<tag> .
#
# Run with env-driven config:
#   docker run -p 6432:6432 \
#       -e DB_HOST=postgres.internal \
#       -e DB_USER=appuser \
#       -e DB_PASSWORD=s3cret \
#       -e DB_NAME=appdb \
#       <registry>/pgbouncer:<tag>
#
# Or mount your own config (takes precedence over env vars):
#   docker run -p 6432:6432 \
#       -v ./pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
#       -v ./userlist.txt:/etc/pgbouncer/userlist.txt:ro \
#       <registry>/pgbouncer:<tag>
#
# See docker-entrypoint.sh for the full list of supported env vars.

ARG ALPINE_VERSION=3.20


############################
# Stage 1: builder
############################
FROM alpine:${ALPINE_VERSION} AS builder

RUN apk add --no-cache \
        autoconf \
        automake \
        build-base \
        c-ares-dev \
        libevent-dev \
        libtool \
        openssl-dev \
        pkgconf \
        python3

WORKDIR /src
COPY . .

RUN ./autogen.sh \
 && ./configure \
        --prefix=/usr/local \
        --with-cares \
        --disable-debug \
 && make -j"$(nproc)" pgbouncer \
 && strip pgbouncer \
 && install -D -m 0755 pgbouncer /out/usr/local/bin/pgbouncer


############################
# Stage 2: runtime
############################
FROM alpine:${ALPINE_VERSION} AS runtime

LABEL org.opencontainers.image.title="pgbouncer" \
      org.opencontainers.image.description="Lightweight connection pooler for PostgreSQL (internal build)" \
      org.opencontainers.image.source="https://github.com/pgbouncer/pgbouncer" \
      org.opencontainers.image.licenses="ISC"

RUN apk add --no-cache \
        c-ares \
        ca-certificates \
        libcrypto3 \
        libevent \
        libssl3 \
        tini

ARG PGBOUNCER_UID=70
ARG PGBOUNCER_GID=70
RUN addgroup -g "${PGBOUNCER_GID}" -S pgbouncer \
 && adduser  -u "${PGBOUNCER_UID}" -S -D -G pgbouncer -H -s /sbin/nologin pgbouncer \
 && mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer \
 && chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

COPY --from=builder /out/ /
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 6432

USER pgbouncer
WORKDIR /etc/pgbouncer

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
