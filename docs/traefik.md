# Traefik — Optional Routing Layer

Traefik is an optional reverse proxy that sits between `cloudflared` and your
local services. Use it when you need:

- **Hostname-based routing** across many apps on one VPS.
- **Middleware** (auth headers, rate limits, redirects).
- A single place to manage routing rules rather than many `cloudflared`
  ingress entries.

For simple setups with one or two services, route directly from `cloudflared`
to each service instead. See [ingress.md](ingress.md).

---

## Architecture with Traefik

```
cloudflared
    │
    └── http://127.0.0.1:8080  (Traefik web entrypoint)
              │
              ├── app.example.com  → http://127.0.0.1:3000
              ├── api.example.com  → http://127.0.0.1:4000
              └── db.example.com   → http://127.0.0.1:5050
```

Traefik binds to `127.0.0.1:8080` (not `0.0.0.0`). Public TLS is handled by
Cloudflare; Traefik only speaks plain HTTP on the local leg.

---

## Run Mode A — Traefik as a systemd Service (Binary)

This is the most consistent approach for a systemd-first VPS.

### 1. Download the binary

```bash
# Find the latest release at https://github.com/traefik/traefik/releases
# Replace <VERSION> with the version you want, e.g. v3.2.0
TRAEFIK_VERSION=<VERSION>
curl -fsSL "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin traefik
sudo chmod +x /usr/local/bin/traefik
```

Verify:

```bash
traefik version
```

### 2. Directory layout

```
/etc/traefik/
├── traefik.yml          # Static configuration
└── dynamic/
    └── services.yml     # Dynamic (file provider) configuration
```

```bash
sudo mkdir -p /etc/traefik/dynamic
```

### 3. Static configuration — /etc/traefik/traefik.yml

```yaml
# /etc/traefik/traefik.yml

# Entrypoints
entryPoints:
  web:
    address: "127.0.0.1:8080"   # Only reachable from localhost (cloudflared)

# File provider — reads dynamic config from /etc/traefik/dynamic/
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true                  # Reload without restart when files change

# API / dashboard — local only, no auth needed on localhost
api:
  dashboard: true
  insecure: true                 # Safe because we bind to 127.0.0.1 only

# Logging
log:
  level: INFO

accessLog: {}
```

> **Dashboard access:** The dashboard is served on `127.0.0.1:8080/dashboard/`.
> To view it from your workstation, use an SSH port-forward:
> ```bash
> ssh -L 8080:127.0.0.1:8080 user@<VPS_IP>
> ```
> Then open `http://localhost:8080/dashboard/`.

### 4. Dynamic configuration — /etc/traefik/dynamic/services.yml

```yaml
# /etc/traefik/dynamic/services.yml

http:
  routers:
    app:
      rule: "Host(`app.example.com`)"
      service: app-svc
      entryPoints:
        - web

    api:
      rule: "Host(`api.example.com`)"
      service: api-svc
      entryPoints:
        - web

  services:
    app-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:3000"

    api-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:4000"
```

Add or edit files under `/etc/traefik/dynamic/` at any time; Traefik picks up
changes automatically (no restart needed when `watch: true`).

### 5. systemd unit

Create `/etc/systemd/system/traefik.service`:

```ini
[Unit]
Description=Traefik Reverse Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5s

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/traefik

# Run as an unprivileged user
User=traefik
Group=traefik

[Install]
WantedBy=multi-user.target
```

Create the user and enable the service:

```bash
sudo adduser --system --no-create-home --group traefik
sudo systemctl daemon-reload
sudo systemctl enable --now traefik
sudo systemctl status traefik
journalctl -u traefik -f
```

---

## Run Mode B — Traefik via Podman (or Docker)

Use this mode if you prefer containerised Traefik or if you also run other
Podman/Docker services.

**Note:** Debian 12 includes `podman` and `podman-compose` in the standard
repositories (`oldstable` component). Install them with:

```bash
sudo apt install podman podman-compose
```

### Directory layout

```
/etc/traefik/
├── traefik.yml
└── dynamic/
    └── services.yml
```

(Same configuration files as Run Mode A.)

### docker-compose.yml / podman-compose equivalent

Create `/etc/traefik/compose.yml`:

```yaml
# /etc/traefik/compose.yml

services:
  traefik:
    image: traefik:v3.2
    restart: unless-stopped
    network_mode: host          # Use host networking so Traefik can reach 127.0.0.1:<port>
    volumes:
      - /etc/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik/dynamic:/etc/traefik/dynamic:ro
```

> **Why `network_mode: host`?** Traefik needs to connect to services on
> `127.0.0.1` on the host. With host networking it shares the host's network
> namespace, so `http://127.0.0.1:3000` resolves correctly.

Start with:

```bash
# Docker
sudo docker compose -f /etc/traefik/compose.yml up -d

# Podman
podman-compose -f /etc/traefik/compose.yml up -d
```

### Manage Podman container as a systemd service

Generate a systemd unit from the running container:

```bash
# Start the container first
podman-compose -f /etc/traefik/compose.yml up -d

# Generate the unit file
podman generate systemd --new --name traefik-traefik-1 \
  | sudo tee /etc/systemd/system/container-traefik.service

sudo systemctl daemon-reload
sudo systemctl enable --now container-traefik
```

---

## Dashboard Exposure Options

| Option | How | Notes |
|--------|-----|-------|
| Local access only | Bind to `127.0.0.1:8080` (default above) + SSH port-forward | Recommended for single-admin setups |
| Behind Cloudflare Access | Add a Cloudflare Access policy for the dashboard hostname | Zero-trust; no extra VPS config needed |
| Disabled entirely | Set `api.dashboard: false` in `traefik.yml` | If you don't need the UI |

To expose the dashboard via Cloudflare Access without opening it publicly:

1. Add an ingress rule in `config.yml` for `traefik.example.com` → `http://127.0.0.1:8080`.
2. In the Cloudflare Zero Trust dashboard, create an Access policy requiring
   your identity (email OTP, SSO, etc.) for `traefik.example.com`.
3. The dashboard is then only accessible to authenticated users, routed through
   the tunnel.

---

## Security Notes

- Traefik's entrypoint binds to `127.0.0.1`, so it is not reachable from the
  internet even if the firewall is misconfigured.
- The dashboard is served on the same port as the web entrypoint. If you
  prefer a separate port for the dashboard, set `api.insecure: false` and use
  a dedicated router rule that matches only from localhost.
- Avoid enabling the Docker or Podman socket provider unless your containers
  use labels for configuration and you understand the privilege implications of
  exposing the socket.

---

## Related Documents

- [ingress.md](ingress.md) — architecture overview and decision matrix
- [cloudflare-tunnel.md](cloudflare-tunnel.md) — cloudflared setup and ingress rules
- [ssh.md](ssh.md) — SSH hardening
