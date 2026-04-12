# SSH Hardening

This guide covers recommended `sshd_config` settings, firewall rate-limiting,
and optional Fail2ban for a **Debian 12 (bookworm)** pet VPS.

SSH (port 22) is kept open as the primary admin path and as a break-glass
fallback when Cloudflare Tunnel is unavailable.

---

## 1. sshd_config Recommended Settings

The repo already includes a drop-in config at
[`ssh/sshd_config.d/tunnel-user.conf`](../ssh/sshd_config.d/tunnel-user.conf)
for the dedicated `tunnel` user. The settings below document the full
recommended baseline.

Deploy as a drop-in file:

```bash
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
```

```sshd_config
# /etc/ssh/sshd_config.d/99-hardening.conf
#
# Hardened SSH baseline for a Debian 12 (bookworm) VPS.
# Keys only; no passwords; no root login.

# ── Authentication ────────────────────────────────────────────────────────────
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes

# ── Access control ────────────────────────────────────────────────────────────
# Uncomment one of these to restrict which OS users may log in:
# AllowUsers  <YOUR_ADMIN_USER>
# AllowGroups ssh-users

# ── Forwarding (globally off; see tunnel-user.conf for the Match block) ───────
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
PermitTunnel no
AllowTcpForwarding no
GatewayPorts no
PermitOpen none

# ── Connection hardening ──────────────────────────────────────────────────────
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 20
MaxAuthTries 3
MaxSessions 10

# ── Logging ───────────────────────────────────────────────────────────────────
LogLevel VERBOSE
```

Verify and reload:

```bash
sudo sshd -t            # Check syntax — must print nothing
sudo systemctl restart ssh
```

### Key settings explained

| Setting | Value | Why |
|---------|-------|-----|
| `PasswordAuthentication no` | no | Eliminates brute-force password attacks entirely. |
| `PermitRootLogin no` | no | Forces use of a named sudo user; limits blast radius. |
| `AllowUsers` / `AllowGroups` | your user/group | Explicit allowlist — even valid system users can't log in unless listed. |
| `AllowTcpForwarding no` | no (global) | Prevents use as a jump host; re-enabled for `tunnel` user only via Match block. |
| `MaxAuthTries 3` | 3 | Limits attempts per connection before disconnect. |
| `LoginGraceTime 20` | 20 s | Closes unauthenticated connections quickly. |
| `LogLevel VERBOSE` | VERBOSE | Logs key fingerprints used; useful for auditing. |

---

## 2. Authorised Keys

Add your public key to `~/.ssh/authorized_keys` (or `/root/.ssh/authorized_keys`
if you temporarily need root access):

```bash
# On the VPS, for your admin user
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA...yourkey... comment" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Use **Ed25519** keys (or ECDSA-521). Avoid RSA below 4096 bits.

For the `tunnel` user, restrict each key to specific forwarding targets using
`permitopen=` — see
[`ssh/authorized_keys.example`](../ssh/authorized_keys.example).

---

## 3. Firewall — nftables

The repo's [`nftables/nftables.conf`](../nftables/nftables.conf) opens ports
22, 80, and 443. With Cloudflare Tunnel you can close 80 and 443. A minimal
ruleset looks like:

```nftables
#!/usr/sbin/nft -f
# /etc/nftables.conf — SSH-only inbound (Cloudflare Tunnel handles HTTP/S)

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Established / related connections
        ct state established,related accept

        # Loopback
        iif lo accept

        # ICMP
        ip  protocol icmp   accept
        ip6 nexthdr  icmpv6 accept

        # SSH — optionally restrict to known source IPs:
        # ip saddr { <HOME_IP>, <WORK_IP> } tcp dport 22 accept
        tcp dport 22 accept

        # Log and drop everything else
        log prefix "[nft-drop] " level warn drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

Apply:

```bash
sudo nft -f /etc/nftables.conf
sudo systemctl enable --now nftables
```

### Rate-limiting SSH connections (nftables)

Add a rate-limit rule _before_ the `tcp dport 22 accept` line to slow down
scanners:

```nftables
        # Rate-limit new SSH connections: max 5 per minute per source IP
        tcp dport 22 ct state new limit rate 5/minute accept
        tcp dport 22 ct state new log prefix "[nft-ssh-drop] " level warn drop
```

---

## 4. Firewall — ufw (alternative)

If you prefer `ufw`:

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
# Do NOT add 80 or 443 when using Cloudflare Tunnel
sudo ufw enable
sudo ufw status verbose
```

Rate-limit SSH with ufw's built-in limit rule:

```bash
sudo ufw limit 22/tcp
```

---

## 5. Fail2ban (optional)

Fail2ban bans IPs that repeatedly fail authentication.

```bash
sudo apt install fail2ban
```

Create a local override:

```bash
sudo nano /etc/fail2ban/jail.d/sshd-local.conf
```

```ini
[sshd]
enabled  = true
port     = 22
filter   = sshd
backend  = systemd
maxretry = 3
findtime = 300
bantime  = 3600
```

Enable and start:

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

Check banned IPs:

```bash
sudo fail2ban-client status sshd
```

---

## 6. Optional — Restrict to Known Source IPs

If your admin IPs are stable (home, VPN, office), restrict SSH to those ranges
in nftables:

```nftables
        ip saddr { <HOME_IP>/32, <VPN_CIDR> } tcp dport 22 accept
```

This is the strongest protection short of closing SSH entirely.

---

## 7. Break-Glass Access

If you lock yourself out (e.g. misconfigured `AllowUsers`, lost key):

1. **VPS provider console** — most providers offer an in-browser or out-of-band
   console that bypasses SSH. This is your recovery path.
2. **Recovery mode / rescue boot** — boot into a recovery image via the
   provider's control panel, mount the disk, and fix `sshd_config` or add a
   key.
3. **Cloudflare Tunnel** — if the tunnel is still up, you can deploy a
   short-lived SSH-over-tunnel session (Cloudflare Access + `cloudflared access
   ssh`) without needing port 22.

> **Always verify** that you can log in with your key _before_ disabling
> password authentication or restricting `AllowUsers`.

---

## Related Documents

- [ingress.md](ingress.md) — architecture overview
- [cloudflare-tunnel.md](cloudflare-tunnel.md) — Cloudflare Tunnel setup
- [`ssh/sshd_config.d/tunnel-user.conf`](../ssh/sshd_config.d/tunnel-user.conf) — tunnel user drop-in
- [`nftables/nftables.conf`](../nftables/nftables.conf) — full nftables example
