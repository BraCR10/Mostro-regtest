FROM rust:1.86 AS builder

ARG MOSTRIX_REPO=https://github.com/MostroP2P/mostrix.git
ARG MOSTRIX_REF=main

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git cmake build-essential pkg-config libssl-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --branch ${MOSTRIX_REF} --single-branch ${MOSTRIX_REPO} /mostrix

WORKDIR /mostrix
RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl3 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /mostrix/target/release/mostrix /usr/local/bin/mostrix

ENTRYPOINT ["/usr/local/bin/mostrix"]
