ARG GOLANG_VERSION=1.25

FROM golang:${GOLANG_VERSION}

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    git \
  && rm -rf /var/lib/apt/lists/*

ENV CC=clang \
    CGO_ENABLED=1
