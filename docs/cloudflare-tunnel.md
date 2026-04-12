# Cloudflare Tunnel Setup

This guide covers installing `cloudflared`, creating a named tunnel, and
configuring ingress rules on **Debian 12 (bookworm)**.

For the overall architecture and the decision on when to use direct routing vs
Traefik, see [ingress.md](ingress.md).

---

## 1. Install cloudflared

Cloudflare provides a Debian-native package. Choose whichever method fits your
workflow.

### Option A — APT (recommended for managed updates)

```bash
# Add the Cloudflare APT repository
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
  https://pkg.cloudflare.com/cloudflared bookworm main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt update
sudo apt install cloudflared
```

### Option B — Direct .deb download (pin a specific version)

```bash
# Replace <VERSION> with the version you want, e.g. 2024.11.0
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

### Verify

```bash
cloudflared --version
```

---

## 2. Authenticate and Create a Named Tunnel

### 2.1 Authenticate with Cloudflare

```bash
cloudflared tunnel login
```

This opens a browser URL. After authorising, a certificate is saved to
`~/.cloudflared/cert.pem`.

### 2.2 Create the tunnel

```bash
cloudflared tunnel create <TUNNEL_NAME>
# Example: cloudflared tunnel create myvps
```

This creates a tunnel and saves credentials to
`~/.cloudflared/<TUNNEL_ID>.json`.

Note the **TUNNEL_ID** printed in the output (a UUID like
`a1b2c3d4-e5f6-7890-abcd-ef1234567890`).

### 2.3 Create DNS CNAME records

For each hostname you want to expose:

```bash
cloudflared tunnel route dns <TUNNEL_NAME> app.example.com
cloudflared tunnel route dns <TUNNEL_NAME> api.example.com
```

This adds a `CNAME` pointing `app.example.com` →
`<TUNNEL_ID>.cfargotunnel.com` in your Cloudflare DNS zone.

---

## 3. Configuration File

Store the tunnel config at `/etc/cloudflared/config.yml`.

```bash
sudo mkdir -p /etc/cloudflared
```

### 3.1 Direct-to-service example (no Traefik)

Use this when each hostname maps directly to a local systemd service.

```yaml
# /etc/cloudflared/config.yml

tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json

ingress:
  # Hostname A → service listening on port 3000
  - hostname: app.example.com
    service: http://127.0.0.1:3000

  # Hostname B → service listening on port 4000
  - hostname: api.example.com
    service: http://127.0.0.1:4000

  # Catch-all rule (required — must be last)
  - service: http_status:404
```

### 3.2 Forward to Traefik (multi-app case)

Use this when Traefik handles hostname-based routing.

```yaml
# /etc/cloudflared/config.yml

tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json

ingress:
  # Everything goes to Traefik's HTTP entrypoint
  - hostname: "*.example.com"
    service: http://127.0.0.1:8080

  # Or use separate explicit rules per hostname:
  # - hostname: app.example.com
  #   service: http://127.0.0.1:8080
  # - hostname: api.example.com
  #   service: http://127.0.0.1:8080

  # Catch-all rule (required — must be last)
  - service: http_status:404
```

### 3.3 Mixed: some direct, some via Traefik

```yaml
# /etc/cloudflared/config.yml

tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json

ingress:
  # Simple service — go directly
  - hostname: status.example.com
    service: http://127.0.0.1:9001

  # Apps managed by Traefik
  - hostname: app.example.com
    service: http://127.0.0.1:8080

  - hostname: api.example.com
    service: http://127.0.0.1:8080

  # Catch-all (required)
  - service: http_status:404
```

### 3.4 Move credentials to /etc/cloudflared

The tunnel credentials JSON must be accessible to the `cloudflared` process
(which runs as a system user). Copy it out of `~/.cloudflared/`:

```bash
sudo cp ~/.cloudflared/<TUNNEL_ID>.json /etc/cloudflared/<TUNNEL_ID>.json
sudo chown root:root /etc/cloudflared/<TUNNEL_ID>.json
sudo chmod 600 /etc/cloudflared/<TUNNEL_ID>.json
```

---

## 4. systemd Service

Install and enable `cloudflared` as a systemd service so it starts on boot.

### Option A — Built-in installer (simplest)

```bash
sudo cloudflared --config /etc/cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
```

This creates `/etc/systemd/system/cloudflared.service` automatically.

### Option B — Manual unit file (more control)

Create `/etc/systemd/system/cloudflared.service`:

```ini
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run
Restart=on-failure
RestartSec=5s

# Harden the service
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log/cloudflared

# Run as an unprivileged user (create with: adduser --system --no-create-home cloudflared)
User=cloudflared
Group=cloudflared

[Install]
WantedBy=multi-user.target
```

> **Create the user first:**
> ```bash
> sudo adduser --system --no-create-home --group cloudflared
> sudo chown cloudflared:cloudflared /etc/cloudflared/<TUNNEL_ID>.json
> ```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

Check logs:

```bash
journalctl -u cloudflared -f
```

---

## 5. Validate the Tunnel

```bash
# Check tunnel is connected
cloudflared tunnel info <TUNNEL_NAME>

# Verify a hostname resolves through the tunnel
curl -v https://app.example.com
```

---

## 6. Security Notes

### Origins must be localhost-only

All services referenced in `ingress` should bind to `127.0.0.1` (not `0.0.0.0`).
This ensures that only `cloudflared` can reach them — even if the VPS firewall
has a misconfiguration.

### Avoid noTLSVerify

Do not set `noTLSVerify: true` in an origin service block unless strictly
necessary (e.g. a self-signed cert on a local origin). For plain HTTP to
`127.0.0.1`, simply use `http://` — no TLS is needed on the local leg.

```yaml
# Good — plain HTTP to localhost (no TLS verification needed)
- hostname: app.example.com
  service: http://127.0.0.1:3000

# Avoid unless you have no alternative
# - hostname: app.example.com
#   service: https://127.0.0.1:3000
#   originRequest:
#     noTLSVerify: true
```

### Credentials file permissions

The tunnel credentials JSON contains a secret. Keep it root-owned and mode 600:

```bash
sudo chmod 600 /etc/cloudflared/<TUNNEL_ID>.json
sudo chown root:root /etc/cloudflared/<TUNNEL_ID>.json
# Or, if running cloudflared as its own user:
sudo chown cloudflared:cloudflared /etc/cloudflared/<TUNNEL_ID>.json
```

### Logging

`cloudflared` logs to stderr by default, which systemd captures in the journal:

```bash
journalctl -u cloudflared --since "1 hour ago"
```

To increase verbosity for debugging:

```bash
# Edit the ExecStart line or pass --loglevel:
ExecStart=/usr/bin/cloudflared tunnel --config /etc/cloudflared/config.yml \
  --loglevel debug run
```

### Firewall

With Cloudflare Tunnel, inbound ports 80 and 443 are not needed.
Update your nftables (or ufw) rules to drop them:

```nftables
# In /etc/nftables.conf — remove or comment out:
# tcp dport 80  accept
# tcp dport 443 accept
```

See the repo's [nftables config](../nftables/nftables.conf) for a full example.

---

## Related Documents

- [ingress.md](ingress.md) — architecture overview and decision matrix
- [traefik.md](traefik.md) — optional Traefik routing layer
- [ssh.md](ssh.md) — SSH hardening
