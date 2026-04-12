# w3dev.tech — Secure Multi-Site VPS Deployment

A reference configuration and runbook for a hardened, single-VPS web stack using:

- **systemd-nspawn** — lightweight OS container isolating Apache from the host
- **Varnish** — HTTP caching reverse proxy (host, private network only)
- **Caddy** — TLS termination and HTTPS front-end (host, public-facing)
- **nftables** — host firewall permitting only 22 / 80 / 443
- **OpenSSH** — hardened with a dedicated tunnel-only user

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Network Topology](#network-topology)
3. [Quick-Start Setup](#quick-start-setup)
4. [Component Configs](#component-configs)
5. [Systemd Hardening](#systemd-hardening)
6. [Boot-Time Audit](#boot-time-audit)
7. [SSH Admin Access](#ssh-admin-access)
8. [Security Rationale](#security-rationale)
9. [Placeholder Reference](#placeholder-reference)

---

## Architecture Overview

```
Internet
   │
   │  443 (HTTPS) / 80 (HTTP → redirect)
   ▼
┌──────────────────────────────────────────┐
│  HOST (Debian Bookworm)                  │
│                                          │
│  ┌──────────────────────────────────┐    │
│  │  Caddy  :443 / :80               │    │
│  │  TLS termination + www→apex      │    │
│  └──────────┬───────────────────────┘    │
│             │ plain HTTP → 127.0.0.1:6081│
│  ┌──────────▼───────────────────────┐    │
│  │  Varnish  127.0.0.1:6081         │    │
│  │  cache + backend routing         │    │
│  └──────────┬───────────────────────┘    │
│             │ plain HTTP                 │
│    ┌────────▼──────────────────┐         │
│    │  veth (ve-web1)           │         │
│    │  host IP: 10.200.1.1/24  │         │
│    └────────┬──────────────────┘         │
└────────────────────────────────────────  │
             │ private virtual ethernet    │
┌────────────▼──────────────────────────┐  │
│  systemd-nspawn container: web1       │  │
│  container IP: 10.200.1.2/24          │  │
│                                       │  │
│  Apache  10.200.1.2:8080              │  │
└───────────────────────────────────────┘  │
```

**Key properties:**
- Apache never listens on a public address — it is reachable only via the private veth.
- Varnish never handles TLS — Caddy terminates all TLS before proxying.
- The nspawn container runs with a hardened systemd unit (dropped capabilities, namespacing, read-only host paths).

---

## Network Topology

| Component              | Interface   | IP / Port           | Publicly reachable? |
|------------------------|-------------|---------------------|---------------------|
| Caddy                  | eth0 / all  | `:80`, `:443`       | Yes                 |
| Varnish                | lo          | `127.0.0.1:6081`    | No                  |
| Apache                 | ve-web1     | `10.200.1.2:8080`   | No                  |
| nspawn veth (host)     | ve-web1     | `10.200.1.1/24`     | No                  |

---

## Quick-Start Setup

### 1. Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y systemd-container varnish caddy apache2 nftables
```

### 2. Bootstrap the container rootfs

```bash
sudo apt-get install -y debootstrap
sudo debootstrap --variant=minbase trixie /var/lib/machines/web1
```

### 3. Configure host networking (systemd-networkd)

```bash
sudo cp systemd/network/80-ve-web1.network /etc/systemd/network/
sudo systemctl enable --now systemd-networkd
```

### 4. Install nspawn container config

```bash
sudo cp systemd/nspawn/web1.nspawn /etc/systemd/nspawn/
```

### 5. Apply nspawn unit hardening override

```bash
sudo mkdir -p /etc/systemd/system/systemd-nspawn@web1.service.d/
sudo cp systemd/system/web1-nspawn-override.conf \
       /etc/systemd/system/systemd-nspawn@web1.service.d/override.conf
sudo systemctl daemon-reload
```

### 6. Start and enable the container

```bash
sudo systemctl enable --now systemd-nspawn@web1
```

### 7. Set up Apache inside the container

```bash
sudo machinectl shell web1
# Inside container:
apt-get update && apt-get install -y apache2
# Copy apache configs (adjust paths as needed)
systemctl enable --now apache2
exit
```

### 8. Configure Varnish on host

```bash
sudo cp varnish/default.vcl /etc/varnish/default.vcl
# Edit /etc/varnish/default.vcl to set your backend IP/port if changed
sudo systemctl restart varnish
```

### 9. Configure Caddy on host

```bash
# Edit caddy/Caddyfile — replace all <PLACEHOLDER> values with real values
sudo cp caddy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
```

### 10. Configure nftables firewall

```bash
sudo cp nftables/nftables.conf /etc/nftables.conf
sudo systemctl enable --now nftables
```

### 11. Harden SSH and create tunnel user

```bash
sudo adduser --disabled-password --gecos "" tunnel
sudo install -d -m 0700 -o tunnel -g tunnel /home/tunnel/.ssh
sudo install -m 0600 -o tunnel -g tunnel /dev/null /home/tunnel/.ssh/authorized_keys
# Append your public key with options from ssh/authorized_keys.example
sudo cp ssh/sshd_config.d/tunnel-user.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl restart ssh
```

### 12. Enable boot-time audit

```bash
sudo cp scripts/web1-audit.sh /usr/local/libexec/web1-audit.sh
sudo chmod 0755 /usr/local/libexec/web1-audit.sh
sudo cp systemd/system/web1-audit.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now web1-audit.service
journalctl -u web1-audit.service -e --no-pager
```

---

## Component Configs

| File | Deployed to |
|------|-------------|
| `caddy/Caddyfile` | `/etc/caddy/Caddyfile` |
| `varnish/default.vcl` | `/etc/varnish/default.vcl` |
| `apache/conf-available/security.conf` | `/etc/apache2/conf-available/security.conf` (in container) |
| `apache/ports.conf` | `/etc/apache2/ports.conf` (in container) |
| `apache/sites-available/000-default.conf` | `/etc/apache2/sites-available/000-default.conf` (in container) |
| `apache/sites-available/example-site.conf` | `/etc/apache2/sites-available/<YOUR_DOMAIN>.conf` (in container) |
| `nftables/nftables.conf` | `/etc/nftables.conf` (on host) |
| `ssh/sshd_config.d/tunnel-user.conf` | `/etc/ssh/sshd_config.d/tunnel-user.conf` (on host) |
| `ssh/authorized_keys.example` | `/home/tunnel/.ssh/authorized_keys` (on host) |
| `systemd/nspawn/web1.nspawn` | `/etc/systemd/nspawn/web1.nspawn` |
| `systemd/network/80-ve-web1.network` | `/etc/systemd/network/80-ve-web1.network` (on host) |
| `systemd/network/80-host0.network` | `/etc/systemd/network/80-host0.network` (in container) |
| `systemd/system/web1-nspawn-override.conf` | `/etc/systemd/system/systemd-nspawn@web1.service.d/override.conf` |
| `systemd/system/web1-audit.service` | `/etc/systemd/system/web1-audit.service` |
| `scripts/web1-audit.sh` | `/usr/local/libexec/web1-audit.sh` |

---

## Systemd Hardening

The container service is hardened via a drop-in override (`systemd/system/web1-nspawn-override.conf`).
Key settings:

| Setting | Effect |
|---------|--------|
| `NoNewPrivileges=yes` | Prevents privilege escalation via setuid/setgid |
| `PrivateUsers=yes` | Maps container UIDs/GIDs into a user namespace (root inside ≠ root outside) |
| `ProtectSystem=strict` | Mounts host `/usr`, `/boot`, `/etc` read-only |
| `ProtectHome=yes` | Blocks access to `/home`, `/root`, `/run/user` |
| `PrivateTmp=yes` | Private `/tmp` and `/var/tmp` namespaces |
| `PrivateDevices=yes` | Restricts device node access |
| `DevicePolicy=closed` | Denies all block/char devices not explicitly allowed |
| `MemoryDenyWriteExecute=yes` | Prevents creation of executable+writable memory mappings |
| `RestrictSUIDSGID=yes` | Blocks setuid/setgid file creation |
| `LockPersonality=yes` | Prevents changes to the execution domain |
| `ProtectKernelTunables=yes` | `/proc/sys` and `/sys` are read-only |
| `ProtectKernelModules=yes` | Blocks module loading syscalls |
| `ProtectControlGroups=yes` | Makes cgroups hierarchy read-only |
| `RestrictNamespaces=yes` | Prevents creation of new namespaces from within the container |
| `RestrictRealtime=yes` | Prevents real-time scheduling |
| `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` | Limits socket address families |

> **Note:** Enable `PrivateUsers=yes` only after verifying Apache boots correctly. Some modules
> may require relaxing other settings. Check `journalctl -u systemd-nspawn@web1` after each change.

---

## Boot-Time Audit

`web1-audit.service` runs as a `oneshot` unit after the container and Varnish are started.
It executes `scripts/web1-audit.sh`, which checks:

- Container service is active
- Apache is reachable on the private container IP
- Varnish service is active
- Port 8080 is **not** exposed on the host's public interface
- nftables firewall is loaded and active
- Caddy service is active
- Key systemd hardening flags are in effect on the container unit

If any check fails the script exits non-zero, causing `web1-audit.service` to fail and log a clear
error via `journald`. This makes configuration drift immediately visible after any reboot.

---

## SSH Admin Access

Day-to-day access to Apache inside the container is done **without running sshd in the container**:

```bash
# From your workstation — interactive shell in container via host SSH + machinectl
ssh admin@<VPS_PUBLIC_IP>
sudo machinectl shell web1

# Or: port-forward Apache for local inspection (tunnel user, no shell)
ssh -N -l tunnel <VPS_PUBLIC_IP> -L 8080:10.200.1.2:8080
# then browse http://localhost:8080/
```

The `tunnel` OS user is restricted to port-forwarding only.
See `ssh/sshd_config.d/tunnel-user.conf` and `ssh/authorized_keys.example` for details.

---

## Security Rationale

### Why systemd-nspawn instead of Docker/Podman?

For a single-service "pet VPS" running a full Debian init stack, `systemd-nspawn` provides native
systemd integration (journal, machinectl, networkd), zero registry dependency, and deep
OS-level isolation without a container daemon attack surface. Docker/Podman add value for
image registries, orchestration, and multi-service environments.

### Why not run sshd inside the container?

Every listening daemon is an additional attack surface. Using `machinectl shell` on the host
provides the same interactive access without exposing a second SSH port. If the host SSH is
compromised, the attacker is still limited by the container namespace boundary.

### Why Caddy over nginx/Traefik for TLS?

Caddy automates Let's Encrypt issuance and renewal with zero extra tooling (no certbot cron,
no renewal hooks). Its HTTPS-by-default stance means misconfigurations that would silently
serve HTTP on nginx are impossible. Traefik's dynamic configuration model adds unnecessary
complexity for a static single-VPS setup.

### Why Varnish between Caddy and Apache?

Varnish provides HTTP-layer caching, graceful backend timeouts, and a powerful VCL language
for request routing. It listens only on `127.0.0.1:6081`, is never exposed to the public
network, and Apache remains unreachable from outside the private veth. This isolates caching
logic from TLS termination and from the application server.

### Why nftables over iptables?

nftables is the modern Linux firewall subsystem (replaces iptables/ip6tables/ebtables with a
single unified ruleset). Debian Bookworm ships nftables by default. The provided ruleset is
deliberately minimal: accept 22/80/443, drop everything else.

---

## Placeholder Reference

All sensitive values that **must be replaced** before deployment are marked with angle brackets:

| Placeholder | Replace with |
|-------------|-------------|
| `<YOUR_DOMAIN>` | Your primary domain, e.g. `example.com` |
| `<YOUR_WWW_DOMAIN>` | `www.example.com` |
| `<YOUR_SECOND_DOMAIN>` | Additional domain if multi-site, e.g. `other.com` |
| `<YOUR_SECOND_WWW_DOMAIN>` | `www.other.com` |
| `<YOUR_ADMIN_EMAIL>` | Email for Let's Encrypt account |
| `<CONTAINER_IP>` | Container veth IP, e.g. `10.200.1.2` |
| `<HOST_VETH_IP>` | Host veth IP, e.g. `10.200.1.1` |
| `<VPS_PUBLIC_IP>` | Your VPS public IPv4 address |
| `<YOUR_PUBLIC_KEY>` | `ssh-ed25519 AAAA...` public key string |
| `<KEY_COMMENT>` | Comment/label for your SSH public key |
| `<ADMIN_SOURCE_IP>` | Your workstation IP (for `from=` key restriction) |
