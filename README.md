# Debian-based Pet VPS: Secure Multi-Site VPS Deployment

A reference configuration and runbook for a hardened, single-VPS web stack using:

- **systemd-nspawn** — lightweight OS container isolating services from the host
- **Varnish** — HTTP caching reverse proxy (host, private network only)
- **Caddy** — TLS termination and HTTPS front-end (host, public-facing)
- **nftables** — host firewall permitting only 22 / 80 / 443
- **OpenSSH** — hardened with a dedicated tunnel-only user

---

> **License:** [MIT-0](LICENSE) — no attribution required. This is reference
> configuration, not owned code.

---

## Template Ladder: web1 → web2 → web3

This repo is organised as a progression of templates. Start at web1 and move
forward only when you need the additional capability:

| Template | What it does | When to use |
|----------|-------------|-------------|
| **web1** | Containerised Apache serving local files on the VPS | Start here. Get a working, hardened site before adding complexity. |
| **web2** | Same as web1 but the webroot is a remote directory mounted via SSHFS | Dev / testing: mirror a remote host's directory live without a full deploy pipeline. Best-effort — see [web2 caveats](#web2-caveats-sshfs). |
| **web3** | Containerised Caddy acting as a reverse proxy to a remote upstream | Production "pet VPS" style: the VPS is the public face; all origin traffic goes through the proxy container to a private upstream. |

You can run multiple templates simultaneously on one VPS — each gets its own
`systemd-nspawn` container and its own private veth (different `/24` subnets).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Network Topology](#network-topology)
3. [Quick-Start Setup (web1)](#quick-start-setup)
4. [web2 Setup: SSHFS Mount + Container](#web2-setup-sshfs-mount--container)
5. [web3 Setup: Reverse Proxy Container](#web3-setup-reverse-proxy-container)
6. [Component Configs](#component-configs)
7. [Systemd Hardening](#systemd-hardening)
8. [Boot-Time Audit](#boot-time-audit)
9. [SSH Admin Access](#ssh-admin-access)
10. [Security Rationale](#security-rationale)
11. [Placeholder Reference](#placeholder-reference)

---

## Architecture Overview

### web1 — containerised Apache (local files)

```
Internet
   │
   │  443 (HTTPS) / 80 (HTTP → redirect)
   ▼
┌──────────────────────────────────────────┐
│  HOST (Debian Trixie)                    │
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
│  webroot: /var/www/html (local files) │  │
└───────────────────────────────────────┘  │
```

### web2 — containerised Apache (SSHFS-mounted remote directory)

```
Remote Host (origin server)
   │
   │  SFTP/SSH (deploy key, read-only)
   ▼
┌──────────────────────────────────────────┐
│  HOST (Debian Trixie)                    │
│                                          │
│  systemd mount: /srv/sshfs/web2          │
│  (sshfs via srv-sshfs-web2.mount)        │
│                                          │
│  [Caddy → Varnish → ve-web2 veth]        │
└────────────────────────────────────────  │
             │ private virtual ethernet    │
┌────────────▼──────────────────────────┐  │
│  systemd-nspawn container: web2       │  │
│  container IP: 10.200.2.2/24          │  │
│                                       │  │
│  Apache  10.200.2.2:8080              │  │
│  webroot: /var/www/html               │  │
│   ↑ bind-mounted from /srv/sshfs/web2 │  │
└───────────────────────────────────────┘  │
```

### web3 — containerised Caddy reverse proxy

```
Internet
   │  443 / 80
   ▼
┌──────────────────────────────────────────┐
│  HOST (Debian Trixie)                    │
│                                          │
│  Caddy :443/:80 → ve-web3 veth           │
│  (no Varnish in path for web3)           │
└────────────────────────────────────────  │
             │ private virtual ethernet    │
┌────────────▼──────────────────────────┐  │
│  systemd-nspawn container: web3       │  │
│  container IP: 10.200.3.2/24          │  │
│                                       │  │
│  Caddy  10.200.3.2:8080               │  │
│  reverse proxy → <REMOTE_UPSTREAM>    │  │
└───────────────────────────────────────┘  │
                │
                │ TCP (WireGuard / Tailscale / public)
                ▼
          Remote upstream service
```

**Key properties (all templates):**
- Application containers never listen on public addresses — reachable only via private veth.
- Varnish never handles TLS — Caddy terminates all TLS before proxying.
- nspawn containers run with hardened systemd units (dropped capabilities, namespacing, read-only host paths).

---

## Network Topology

### web1

| Component              | Interface   | IP / Port           | Publicly reachable? |
|------------------------|-------------|---------------------|---------------------|
| Caddy                  | eth0 / all  | `:80`, `:443`       | Yes                 |
| Varnish                | lo          | `127.0.0.1:6081`    | No                  |
| Apache                 | ve-web1     | `10.200.1.2:8080`   | No                  |
| nspawn veth (host)     | ve-web1     | `10.200.1.1/24`     | No                  |

### web2

| Component              | Interface   | IP / Port           | Publicly reachable? |
|------------------------|-------------|---------------------|---------------------|
| Caddy                  | eth0 / all  | `:80`, `:443`       | Yes                 |
| Varnish                | lo          | `127.0.0.1:6081`    | No                  |
| Apache                 | ve-web2     | `10.200.2.2:8080`   | No                  |
| nspawn veth (host)     | ve-web2     | `10.200.2.1/24`     | No                  |
| SSHFS mount (host)     | eth0 / wg0  | outbound SSH        | Outbound only       |

### web3

| Component              | Interface   | IP / Port           | Publicly reachable? |
|------------------------|-------------|---------------------|---------------------|
| Caddy (host)           | eth0 / all  | `:80`, `:443`       | Yes                 |
| Caddy (web3 container) | ve-web3     | `10.200.3.2:8080`   | No                  |
| nspawn veth (host)     | ve-web3     | `10.200.3.1/24`     | No                  |
| Remote upstream        | wg0 / eth0  | upstream-defined    | Outbound only       |

---

## Quick-Start Setup (web1)

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

## web2 Setup: SSHFS Mount + Container

web2 extends web1 by mounting a remote host's directory onto the VPS via SSHFS,
then bind-mounting that path into the Apache container. The rest of the stack
(Caddy → Varnish → Apache) is identical to web1.

### web2 Prerequisites

```bash
sudo apt-get install -y sshfs
```

Enable `allow_other` in FUSE (allows the container's root process to read the mount):

```bash
echo "user_allow_other" | sudo tee -a /etc/fuse.conf
```

### web2 Step 1: Generate a dedicated deploy key

```bash
sudo mkdir -p /etc/sshfs
sudo ssh-keygen -t ed25519 -C "web2-sshfs@$(hostname)" \
    -f /etc/sshfs/web2-deploy-key -N ""
sudo chmod 0600 /etc/sshfs/web2-deploy-key
# Show the public key to add to the remote host:
cat /etc/sshfs/web2-deploy-key.pub
```

On the **remote host**, add the public key to `~/.ssh/authorized_keys` for the
deploy user with tight restrictions (read-only SFTP, source IP lock):

```
restrict,from="<VPS_PUBLIC_IP>",command="/usr/lib/openssh/sftp-server -R" \
ssh-ed25519 AAAA... web2-sshfs@<VPS_HOSTNAME>
```

See `ssh/web2-sshfs-ssh_config.example` for more detail and alternatives.

### web2 Step 2: Pre-populate known_hosts

```bash
ssh-keyscan -H <REMOTE_HOST> | sudo tee /etc/sshfs/web2-known_hosts
sudo chmod 0600 /etc/sshfs/web2-known_hosts
```

### web2 Step 3: Install and test the SSHFS mount unit

```bash
sudo mkdir -p /srv/sshfs/web2
# Edit the mount unit — replace REMOTE_USER, REMOTE_HOST, REMOTE_PATH
sudo cp systemd/system/srv-sshfs-web2.mount /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start srv-sshfs-web2.mount
# Verify:
mountpoint /srv/sshfs/web2 && ls /srv/sshfs/web2
sudo systemctl enable srv-sshfs-web2.mount
```

### web2 Step 4: Bootstrap the container rootfs

```bash
sudo debootstrap --variant=minbase trixie /var/lib/machines/web2
```

### web2 Step 5: Configure container-side networking

```bash
# Copy the container-side network config and edit IP placeholders:
sudo mkdir -p /var/lib/machines/web2/etc/systemd/network/
sudo cp systemd/network/80-host0.network \
    /var/lib/machines/web2/etc/systemd/network/80-host0.network
# Edit the file: set <CONTAINER_IP> = 10.200.2.2 and <HOST_VETH_IP> = 10.200.2.1
sudo nano /var/lib/machines/web2/etc/systemd/network/80-host0.network
```

### web2 Step 6: Configure host networking

```bash
# Edit 80-ve-web2.network — set <HOST_VETH_IP_WEB2> = 10.200.2.1
sudo cp systemd/network/80-ve-web2.network /etc/systemd/network/
sudo systemctl restart systemd-networkd
```

### web2 Step 7: Install nspawn config and hardening override

```bash
sudo cp systemd/nspawn/web2.nspawn /etc/systemd/nspawn/
sudo mkdir -p /etc/systemd/system/systemd-nspawn@web2.service.d/
sudo cp systemd/system/web2-nspawn-override.conf \
    /etc/systemd/system/systemd-nspawn@web2.service.d/override.conf
sudo systemctl daemon-reload
```

### web2 Step 8: Start and enable the container

```bash
sudo systemctl enable --now systemd-nspawn@web2
```

### web2 Step 9: Set up Apache inside the container

```bash
sudo machinectl shell web2
# Inside container:
apt-get update && apt-get install -y apache2
# Verify the bind-mounted webroot is visible:
ls /var/www/html
systemctl enable --now apache2
exit
```

### web2 Step 10: Enable the audit service

```bash
sudo install -m 0755 scripts/web2-audit.sh /usr/local/libexec/web2-audit.sh
sudo cp systemd/system/web2-audit.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now web2-audit.service
journalctl -u web2-audit.service -e --no-pager
```

### web2 Caveats: SSHFS

> ⚠️ **SSHFS is best-effort / hobby-grade.** Do not rely on it for
> business-critical uptime.

| Concern | Detail |
|---------|--------|
| **Network blips** | A momentary disconnect stales or freezes the mount. The `reconnect` option handles brief drops; longer outages may require manual remount or a service restart. |
| **inotify** | SSHFS does not propagate `inotify` events from the remote host. Tools that watch for file changes (webpack, live-reload) will not fire. |
| **Performance** | Every file read is a remote SFTP operation. For large sites or many small files, latency is noticeable. |
| **Stale mounts** | If the SSHFS process dies silently, reads block until timeout. Monitor with `web2-audit.service` and consider a watchdog. |
| **Alternative** | For more robustness, replace SSHFS with a scheduled `rsync` or `unison` sync to a local directory, then bind-mount that instead. This sacrifices live-edit immediacy but eliminates flakiness. |

**Troubleshooting SSHFS:**

```bash
# Check mount status
systemctl status srv-sshfs-web2.mount

# Manually test the connection (as root, using the deploy key)
ssh -i /etc/sshfs/web2-deploy-key \
    -o UserKnownHostsFile=/etc/sshfs/web2-known_hosts \
    -o StrictHostKeyChecking=yes \
    <REMOTE_USER>@<REMOTE_HOST> echo "ok"

# Force remount after a stale mount
sudo systemctl restart srv-sshfs-web2.mount

# View FUSE errors
journalctl -u srv-sshfs-web2.mount -e --no-pager
```

---

## web3 Setup: Reverse Proxy Container

web3 replaces Apache with Caddy inside the nspawn container. This Caddy instance
acts as a reverse proxy to a remote upstream — the container is the network
isolation boundary between the VPS public face and the origin service.

Varnish is **not** in the path for web3 (the upstream is remote, so caching
at the VPS level is rarely appropriate). The host-side Caddy routes directly
to the web3 container.

### Recommended upstream networking

| Option | Notes |
|--------|-------|
| **WireGuard / Tailscale** | Preferred. Private, encrypted, routable via container NAT. |
| **SSH tunnel** | `ssh -N -R 8080:localhost:8080 vps-user@<VPS>` on the remote host; set `REMOTE_UPSTREAM=http://127.0.0.1:8080` on the container. |
| **Public HTTPS** | Works but exposes the upstream. Use only with strict firewall rules on both ends. |

### web3 Step 1: Bootstrap the container rootfs and install Caddy

```bash
sudo debootstrap --variant=minbase trixie /var/lib/machines/web3
sudo systemd-nspawn -D /var/lib/machines/web3 /bin/bash -c \
    "apt-get update && apt-get install -y caddy"
```

### web3 Step 2: Configure container-side networking

```bash
sudo mkdir -p /var/lib/machines/web3/etc/systemd/network/
sudo cp systemd/network/80-host0.network \
    /var/lib/machines/web3/etc/systemd/network/80-host0.network
# Edit: <CONTAINER_IP> = 10.200.3.2 and <HOST_VETH_IP> = 10.200.3.1
sudo nano /var/lib/machines/web3/etc/systemd/network/80-host0.network
```

### web3 Step 3: Configure host networking

```bash
# Edit 80-ve-web3.network — set <HOST_VETH_IP_WEB3> = 10.200.3.1
sudo cp systemd/network/80-ve-web3.network /etc/systemd/network/
sudo systemctl restart systemd-networkd
```

### web3 Step 4: Deploy the Caddyfile

```bash
sudo mkdir -p /etc/web3
# Edit web3/Caddyfile — replace <REMOTE_UPSTREAM> with your upstream URL
sudo cp web3/Caddyfile /etc/web3/Caddyfile
```

### web3 Step 5: Install nspawn config and hardening override

```bash
sudo cp systemd/nspawn/web3.nspawn /etc/systemd/nspawn/
sudo mkdir -p /etc/systemd/system/systemd-nspawn@web3.service.d/
sudo cp systemd/system/web3-nspawn-override.conf \
    /etc/systemd/system/systemd-nspawn@web3.service.d/override.conf
sudo systemctl daemon-reload
```

### web3 Step 6: Start and enable the container

```bash
sudo systemctl enable --now systemd-nspawn@web3
```

### web3 Step 7: Update host-side Caddy to route to web3

Add a site block to `/etc/caddy/Caddyfile` that proxies to the web3 container
(no Varnish in between):

```caddy
<YOUR_DOMAIN> {
    reverse_proxy 10.200.3.2:8080 {
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Then reload Caddy: `sudo systemctl reload caddy`

### web3 Step 8: Enable the audit service

```bash
sudo install -m 0755 scripts/web3-audit.sh /usr/local/libexec/web3-audit.sh
sudo cp systemd/system/web3-audit.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now web3-audit.service
journalctl -u web3-audit.service -e --no-pager
```

---

## Component Configs

### web1

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

### web2

| File | Deployed to |
|------|-------------|
| `systemd/nspawn/web2.nspawn` | `/etc/systemd/nspawn/web2.nspawn` |
| `systemd/network/80-ve-web2.network` | `/etc/systemd/network/80-ve-web2.network` (on host) |
| `systemd/network/80-host0.network` | `/var/lib/machines/web2/etc/systemd/network/80-host0.network` (in container, edit IPs) |
| `systemd/system/web2-nspawn-override.conf` | `/etc/systemd/system/systemd-nspawn@web2.service.d/override.conf` |
| `systemd/system/srv-sshfs-web2.mount` | `/etc/systemd/system/srv-sshfs-web2.mount` |
| `systemd/system/srv-sshfs-web2.automount` | `/etc/systemd/system/srv-sshfs-web2.automount` (optional) |
| `ssh/web2-sshfs-ssh_config.example` | `/etc/sshfs/web2-ssh_config` (edit then deploy) |
| `systemd/system/web2-audit.service` | `/etc/systemd/system/web2-audit.service` |
| `scripts/web2-audit.sh` | `/usr/local/libexec/web2-audit.sh` |

### web3

| File | Deployed to |
|------|-------------|
| `systemd/nspawn/web3.nspawn` | `/etc/systemd/nspawn/web3.nspawn` |
| `systemd/network/80-ve-web3.network` | `/etc/systemd/network/80-ve-web3.network` (on host) |
| `systemd/network/80-host0.network` | `/var/lib/machines/web3/etc/systemd/network/80-host0.network` (in container, edit IPs) |
| `systemd/system/web3-nspawn-override.conf` | `/etc/systemd/system/systemd-nspawn@web3.service.d/override.conf` |
| `web3/Caddyfile` | `/etc/web3/Caddyfile` (bind-mounted into container at `/etc/caddy/Caddyfile`) |
| `systemd/system/web3-audit.service` | `/etc/systemd/system/web3-audit.service` |
| `scripts/web3-audit.sh` | `/usr/local/libexec/web3-audit.sh` |

---

## Systemd Hardening

All container services are hardened via drop-in overrides
(`systemd/system/web{1,2,3}-nspawn-override.conf`).
Key settings applied to every container:

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

**web2 additional:** the override adds `After=srv-sshfs-web2.mount` and
`Requires=srv-sshfs-web2.mount` so the container never starts without the SSHFS
mount active.

> **Note:** Enable `PrivateUsers=yes` only after verifying the workload inside
> each container boots correctly. Some modules may require relaxing other settings.
> Check `journalctl -u systemd-nspawn@web{1,2,3}` after each change.

---

## Boot-Time Audit

Each template ships a `oneshot` audit service that runs after all stack components start.

| Service | Script | What it checks |
|---------|--------|----------------|
| `web1-audit.service` | `scripts/web1-audit.sh` | Container, Apache, Varnish, Caddy, port exposure, firewall, hardening flags |
| `web2-audit.service` | `scripts/web2-audit.sh` | All of web1 + SSHFS mount active and `mountpoint` verified |
| `web3-audit.service` | `scripts/web3-audit.sh` | Container, Caddy (host), container proxy reachability, port exposure, firewall, hardening flags |

If any check fails, the audit service exits non-zero and logs a clear error via `journald`.
This makes configuration drift immediately visible after any reboot.

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
single unified ruleset). Debian Trixie ships nftables by default. The provided ruleset is
deliberately minimal: accept 22/80/443, drop everything else.

---

## Placeholder Reference

All sensitive values that **must be replaced** before deployment are marked with angle brackets:

### web1

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

### web2 (additional)

| Placeholder | Replace with |
|-------------|-------------|
| `<HOST_VETH_IP_WEB2>` | Host veth IP for web2, e.g. `10.200.2.1` |
| `<CONTAINER_IP_WEB2>` | Container veth IP for web2, e.g. `10.200.2.2` |
| `<REMOTE_HOST>` | Hostname or IP of the remote server to mount via SSHFS |
| `<REMOTE_USER>` | SSH user on the remote server (deploy user) |
| `<REMOTE_PATH>` | Path on the remote server to mount, e.g. `/srv/www/mysite` |

### web3 (additional)

| Placeholder | Replace with |
|-------------|-------------|
| `<HOST_VETH_IP_WEB3>` | Host veth IP for web3, e.g. `10.200.3.1` |
| `<CONTAINER_IP_WEB3>` | Container veth IP for web3, e.g. `10.200.3.2` |
| `<REMOTE_UPSTREAM>` | Upstream URL for the reverse proxy, e.g. `http://10.0.0.5:8080` |

---

## License

[MIT-0](LICENSE) — no attribution required.
This is reference configuration, not original intellectual property.
