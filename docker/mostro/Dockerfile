FROM rust:1.86 AS builder

ARG MOSTRO_REPO=https://github.com/MostroP2P/mostro.git
ARG MOSTRO_REF=main

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git cmake build-essential libsqlite3-dev pkg-config libssl-dev protobuf-compiler && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --branch ${MOSTRO_REF} --single-branch ${MOSTRO_REPO} /mostro

WORKDIR /mostro
RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends --reinstall ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m mostrouser

COPY --from=builder /mostro/target/release/mostrod /usr/local/bin/mostrod

RUN chown -R mostrouser:mostrouser /home/mostrouser

USER mostrouser

ENTRYPOINT ["/usr/local/bin/mostrod"]
CMD ["-d", "/config"]
