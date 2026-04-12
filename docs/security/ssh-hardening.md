# SSH Hardening — Non-Standard Port + Key-Only Auth

This guide covers hardening SSH on a Debian 12 (bookworm) VPS, including
moving away from the default port 22, enforcing key-only authentication, and
optionally deploying Fail2ban.

Pair this with a VPN (see
[wireguard-full-tunnel-nftables.md](../vpn/wireguard-full-tunnel-nftables.md))
so that SSH is only reachable over the WireGuard interface in normal operation.

> **Placeholder:** SSH port examples throughout this document use `${SSH_PORT}`.
> Replace with your chosen port number (e.g. `2222`, `2200`, or any unused
> high port below `65535`).

---

## 1. Change the SSH Port

Edit (or create) a drop-in config:

```bash
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
```

```sshd_config
# /etc/ssh/sshd_config.d/99-hardening.conf
#
# Hardened SSH baseline — non-standard port, key-only, no root.

# ── Port ──────────────────────────────────────────────────────────────────────
Port ${SSH_PORT}

# ── Authentication ────────────────────────────────────────────────────────────
PasswordAuthentication          no
KbdInteractiveAuthentication    no
ChallengeResponseAuthentication no
PermitRootLogin                 no
PubkeyAuthentication            yes

# ── Access control ────────────────────────────────────────────────────────────
# Restrict to your admin user(s):
# AllowUsers  <YOUR_ADMIN_USER>
# AllowGroups ssh-users

# ── Forwarding ────────────────────────────────────────────────────────────────
X11Forwarding        no
AllowAgentForwarding no
PermitUserEnvironment no
PermitTunnel         no
AllowTcpForwarding   no
GatewayPorts         no
PermitOpen           none

# ── Connection hardening ──────────────────────────────────────────────────────
ClientAliveInterval  300
ClientAliveCountMax  2
LoginGraceTime       20
MaxAuthTries         3
MaxSessions          10

# ── Logging ───────────────────────────────────────────────────────────────────
LogLevel VERBOSE
```

Verify syntax and restart:

```bash
sudo sshd -t                     # Must print nothing on success
sudo systemctl restart ssh
```

> **Before restarting:** open a second SSH session to verify you can still log
> in on `${SSH_PORT}` before closing your existing session.

---

## 2. Authorised Keys — Key Types

Use **Ed25519** keys (preferred) or ECDSA-521. Avoid RSA below 4096 bits.

```bash
# Generate an Ed25519 key on your local machine (not the VPS):
ssh-keygen -t ed25519 -C "your-comment"

# Copy to the VPS (while you still have access on the old port):
ssh-copy-id -p ${SSH_PORT} <YOUR_ADMIN_USER>@<VPS_IP>

# Or manually append:
cat ~/.ssh/id_ed25519.pub | ssh -p ${SSH_PORT} <YOUR_ADMIN_USER>@<VPS_IP> \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

---

## 3. Update Firewall Rules (nftables)

Update `/etc/nftables.conf` to allow `${SSH_PORT}` instead of (or in addition
to) port 22. The recommended stance when using WireGuard is:

**Option A — SSH only over WireGuard (most restrictive):**

```nftables
# Only allow SSH from the WireGuard subnet — not from the public internet
iif "wg0" tcp dport ${SSH_PORT} accept
```

**Option B — SSH on public internet with rate-limiting (fallback/break-glass):**

```nftables
# Rate-limit new SSH connections from anywhere
tcp dport ${SSH_PORT} ct state new limit rate 5/minute accept
tcp dport ${SSH_PORT} ct state new log prefix "[nft-ssh-drop] " level warn drop
```

**Option C — Restrict to known source IPs:**

```nftables
# Allow SSH only from your home/office IP range
ip saddr { <HOME_IP>/32, 10.8.0.0/24 } tcp dport ${SSH_PORT} accept
```

Apply and verify:

```bash
sudo nft -f /etc/nftables.conf
sudo nft list ruleset | grep ${SSH_PORT}
```

> If you switch from port 22 to `${SSH_PORT}`, remember to remove the old
> `tcp dport 22 accept` rule (or change it) at the same time.

---

## 4. Update Your SSH Client Config

On your local machine, add an entry to `~/.ssh/config` so you don't need to
specify the port every time:

```sshconfig
Host myvps
    HostName     <VPS_IP_OR_HOSTNAME>
    User         <YOUR_ADMIN_USER>
    Port         ${SSH_PORT}
    IdentityFile ~/.ssh/id_ed25519
    # Optional: route through WireGuard if using split-tunnel
    # ProxyJump   none
```

Connect with:

```bash
ssh myvps
```

---

## 5. Fail2ban (optional)

Fail2ban bans IPs that repeatedly fail authentication. Useful if you keep SSH
reachable from the public internet.

```bash
sudo apt install fail2ban
```

Create a local override to match your non-standard port:

```bash
sudo nano /etc/fail2ban/jail.d/sshd-local.conf
```

```ini
[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
backend  = systemd
maxretry = 3
findtime = 300
bantime  = 3600
```

Enable and verify:

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

---

## 6. Key Settings Explained

| Setting | Value | Why |
|---------|-------|-----|
| `Port ${SSH_PORT}` | non-22 | Removes the VPS from the mass-scanner target population for port 22 |
| `PasswordAuthentication no` | no | Eliminates brute-force password attacks entirely |
| `PermitRootLogin no` | no | Forces use of a named sudo user; limits blast radius |
| `AllowUsers` / `AllowGroups` | your user/group | Explicit allowlist — even valid system users can't log in unless listed |
| `AllowTcpForwarding no` | no (global) | Prevents use as a jump host; re-enable in a `Match` block only if needed |
| `MaxAuthTries 3` | 3 | Limits attempts per connection before disconnect |
| `LoginGraceTime 20` | 20 s | Closes unauthenticated connections quickly |
| `LogLevel VERBOSE` | VERBOSE | Logs key fingerprints used; useful for auditing |

> **Changing the port reduces noise but is not a security control on its own.**
> Key-only auth, disabled root login, and rate-limiting/Fail2ban are the real
> controls. The non-standard port simply keeps automated scanners out of your
> logs.

---

## 7. Break-Glass Access

If you lock yourself out (misconfigured `AllowUsers`, lost key, wrong port in
nftables):

1. **VPS provider console** — most providers offer an out-of-band or in-browser
   console that bypasses SSH entirely. This is your recovery path.
2. **Recovery mode / rescue boot** — boot into a rescue image via the
   provider's panel, mount the disk, and fix `sshd_config` or add a key.
3. **WireGuard** — if the tunnel is still up, SSH over `10.8.0.1:${SSH_PORT}`
   even if the public internet rule is locked down.

> **Always verify** that you can log in with your key on `${SSH_PORT}` before
> closing the session where you made the changes.

---

## Related Documents

- [../vpn/wireguard-full-tunnel-nftables.md](../vpn/wireguard-full-tunnel-nftables.md) — WireGuard setup (reach SSH over wg0)
- [audit-over-vpn.md](audit-over-vpn.md) — verify port exposure with nmap
- [../../ssh/sshd_config.d/tunnel-user.conf](../../ssh/sshd_config.d/tunnel-user.conf) — tunnel user drop-in (AllowTcpForwarding for that user)
- [../../nftables/nftables.conf](../../nftables/nftables.conf) — base nftables config
