# Security

## Port model

All services from `setup.sh` bind to `127.0.0.1` — unreachable from the internet by design. The only thing exposed publicly is the nginx proxy in `~/Server/`.

```
Internet
   │
   ▼
nginx (~/Server/)         ← only public-facing component
ports 80 / 443
   │
   ├── btcpanel.website → RTL     (127.0.0.1:3000)
   └── lndpanel.site   → satdress (127.0.0.1:17422)

Everything else: 127.0.0.1 only
  bitcoind   :18443 (RPC)  :18444 (P2P)  :28332/:28333 (ZMQ)
  lnd1       :9735  (P2P)  :10009 (gRPC) :8080  (REST)
  lnd2       :9736          :10010         :8081
  lnd3       :9737          :10011         :8082
  RTL        :3000
  satdress   :17422
```

## Firewall (ufw)

Only three ports open to the internet:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP (certbot challenge + redirect)
sudo ufw allow 443/tcp   # HTTPS (nginx proxy)
sudo ufw --force enable
```

Even without the firewall, services bound to `127.0.0.1` can't receive external connections. ufw is a second layer.

## nginx proxy (~/Server/)

nginx runs as a Docker container and is managed independently of `setup.sh`:

```
~/Server/
├── docker-compose.yml
└── nginx/
    ├── conf.d/
    │   ├── rtl.conf        # btcpanel.website → RTL
    │   └── lnurl.conf      # lndpanel.site → satdress
    └── certbot/
        ├── conf/           # Let's Encrypt certs
        └── www/            # ACME challenge webroot
```

nginx only proxies to explicitly configured domains. LND, Mostro, bitcoind, and macaroons are not reachable through it.

## SSL certificates

Certificates are obtained via certbot (Docker) and renewed automatically via a daily cron job:

```bash
# Manual renewal (if needed)
docker run --rm \
  -v ~/Server/nginx/certbot/conf:/etc/letsencrypt \
  -v ~/Server/nginx/certbot/www:/var/www/certbot \
  certbot/certbot renew --quiet

docker exec nginx nginx -s reload
```

The cron job runs at 3am daily and only acts when a cert is within 30 days of expiry.

## Verification

```bash
# Check what's listening on public interfaces
ss -tlnp | grep -v 127.0.0
# Should only show: 22, 80, 443

# Verify nginx doesn't leak internal services
curl -s https://btcpanel.website/v1/getinfo    # should NOT return LND data
curl -s https://btcpanel.website/admin.macaroon # should return 404

# Check firewall status
sudo ufw status verbose
```

## Sensitive files

| File | Contains | Protection |
|------|----------|------------|
| `mostro/nostr-private.txt` | Mostro nsec key | chmod 600, git-ignored |
| `lndN/data/seed.txt` | 24-word wallet seed | chmod 600, git-ignored |
| `lndN/data/wallet-password.txt` | Wallet unlock password | chmod 600, git-ignored |
| `.env` | All credentials | git-ignored |
| `summary.txt` | Keys + addresses summary | chmod 600, git-ignored |
