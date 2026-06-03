# Prerequisites

## Minimum requirements

| Resource | Minimum |
|----------|---------|
| CPU | 2 cores |
| RAM | 4 GB |
| Disk | 20 GB |
| OS | Ubuntu 22.04+ / Debian 12+ |

## Required software

### Docker

The only local dependency. Install on Ubuntu/Debian:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker          # apply group change without logout
docker --version       # verify
```

Everything else (bitcoind, LND, Mostro, MostriX, RTL) runs as Docker containers built by `setup.sh`. No Rust, no Bitcoin Core, no Python.

## Optional: external proxy (for public domains)

If you want `RTL_DOMAIN` or `LNURL_DOMAIN`, you also need:

- A VPS with a public IP
- Two DNS A records pointing your domains to that IP
- nginx + certbot running in Docker (see [security.md](security.md))

The proxy lives in `~/Server/` and is set up independently of `setup.sh`.
