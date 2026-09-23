# mcl-mpong
#
# Two bots play pong over the mesh, and the match reports how the mesh carried it
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ THE BUILD IMAGE IS PINNED IN TWO PLACES AND THEY MUST BE THE SAME: here and
# `lint.yml' beside it, the team's macula-ci-otp by digest (OTP 28.4.3, rebar3
# and Rust pinned exactly). A test (mcl_mpong_service_tests) fails when the two
# differ, or when the release running the suite is not the one `.tool-versions'
# names. The runtime below is the matching macula-pq-runtime pair, by digest:
# Debian trixie with OpenSSL 3.5+, which macula 12's ML-DSA needs at run time.
#
# It was `erlang:28-alpine', a floating major with a floating Rust and rebar3
# from S3's unversioned latest: any rebuild could change the compiler.
ARG CI_OTP=ghcr.io/macula-io/macula-ci-otp:20260923-1347@sha256:b2260d084a3d3c5e0b74932c4ee052a0cadfddddb6587d5d2214873e6bb06330
ARG PQ_RUNTIME=ghcr.io/macula-io/macula-pq-runtime:20260923-1347@sha256:255b503cf87c26510fd12e8fcb92be6bd0dc56b5ff6d9145477b636b5c11d261

FROM ${CI_OTP} AS builder
WORKDIR /build

# macula's NIFs build from source with the image's pinned Rust rather than
# fetching a prebuilt binary: the build is then fully determined by this file.
ENV MACULA_FORCE_SOURCE_BUILD=1

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/ and the Rust toolchain is not re-run per commit.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ${PQ_RUNTIME}
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-mpong"
# The commit this image was built from, set by build-push.yml. "unknown" on a
# local build, which is then visibly not a CI image.
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# Nothing to install: macula-pq-runtime carries libstdc++, ncurses, OpenSSL 3.5+,
# ca-certificates and curl (the health check below). mcl_om >= 0.27 holds no
# rocksdb, so no compression libraries either.
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_mpong ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_mpong
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_mpong
ENV MCL_HEALTH_PORT=8472

VOLUME ["/etc/mcl/secrets"]

EXPOSE 8472
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_mpong", "foreground"]
