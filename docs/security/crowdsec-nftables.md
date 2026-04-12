# CrowdSec + nftables — SSH-only VPS (Cloudflare Tunnel + optional WireGuard)

This document shows how to use **CrowdSec** with **nftables** on a Debian 12
(bookworm) VPS following this repo’s patterns:

- **SSH is the only public inbound port** (preferably a non-standard `${SSH_PORT}`).
- **HTTP/S inbound (80/443) is not needed** when using **Cloudflare Tunnel**.
- **WireGuard** is optional for remote admin; if enabled, it can carry SSH/admin
dashboards over `wg0`.

The goal is to replace (or complement) Fail2ban with CrowdSec by having CrowdSec
detect hostile behavior and **block it at the firewall** via nftables.

---

## 0. Threat model & when CrowdSec helps

CrowdSec is most useful when:

- You keep SSH reachable from the public internet (even on a non-standard port).
- You want collaborative threat intel (shared blocklists).
- You want to ban at the firewall layer, not just in application config.

If your most restrictive posture is **SSH only over WireGuard** (`iif "wg0" ...`)
then CrowdSec provides less value for SSH brute-force (because the public
internet can’t reach SSH at all). It can still be useful for:
- local logs (auth, sudo, etc.)
- other services you might expose later (even temporarily)

---

## 1. Preconditions

- You are on **Debian 12 (bookworm)**.
- You already use nftables (see `nftables/nftables.conf`).
- You have SSH hardening in place (see `docs/security/ssh-hardening.md`).

**Ports with Cloudflare Tunnel:**
- Public: only `${SSH_PORT}` (or 22 if you didn’t move it yet)
- Closed: `80/tcp`, `443/tcp` (Cloudflare Tunnel handles HTTP/S ingress)

---

## 2. Install CrowdSec

Install CrowdSec engine:

```bash
sudo apt update
sudo apt install crowdsec
sudo systemctl enable --now crowdsec
sudo systemctl status crowdsec
```

Check status:

```bash
sudo cscli version
sudo cscli metrics
sudo cscli decisions list
```

> CrowdSec parses logs and generates “decisions” (ban/timeout) based on
> scenarios. Those decisions must be **enforced** by a “bouncer”.

---

## 3. Install an nftables bouncer

Install the nftables bouncer:

```bash
sudo apt install crowdsec-firewall-bouncer-nftables
sudo systemctl enable --now crowdsec-firewall-bouncer
sudo systemctl status crowdsec-firewall-bouncer
```

Check bouncer logs:

```bash
sudo journalctl -u crowdsec-firewall-bouncer -n 200 --no-pager
```

**What this does:**
- The bouncer reads decisions from CrowdSec (via the local API).
- It programs nftables rules/sets so blocked IPs are dropped at the firewall.

---

## 4. Ensure SSH is actually being monitored

CrowdSec needs logs. For OpenSSH on Debian, logs are typically in journald.
Verify CrowdSec sees SSH events:

```bash
sudo cscli metrics | sed -n '1,200p'
sudo journalctl -u crowdsec -n 200 --no-pager
```

If your SSH logs are only in journald, ensure your CrowdSec installation is set
up to read systemd journal (common on Debian). If you’ve configured rsyslog or
auth logs, ensure those are present and readable by CrowdSec.

---

## 5. nftables integration patterns

There are two common ways to integrate CrowdSec bans with nftables:

### Pattern A (recommended): Let the bouncer manage its nftables rules

This is the simplest operational model:
- Keep your baseline `nftables.conf` as your “allowlist + drop” policy.
- The bouncer manages its own set/table for banned IPs.

**You still should verify ordering:** bans must be evaluated *before* your SSH
accept rule, otherwise malicious IPs can still reach SSH.

To inspect what the bouncer created:

```bash
sudo nft list ruleset | less
```

### Pattern B: Wire the CrowdSec set into your existing `inet filter input` chain

If you want an explicit “CrowdSec drop” check inside your own ruleset, add a
drop check near the top of your `input` chain (after established/loopback/ICMP,
but **before** allowing `${SSH_PORT}`).

Because bouncer-managed set names can differ by distro/package version, this
repo does **not** hardcode a set name here.

Instead, tailor it on your host:

1) Install CrowdSec + the nftables bouncer (sections 2–3).

2) Generate a test decision (simplest: intentionally fail SSH auth a few times
from a test IP) and confirm a decision exists:

```bash
sudo cscli decisions list
```

3) Print the top of the active ruleset:

```bash
sudo nft list ruleset | sed -n '1,200p'
```

4) Find the **CrowdSec-created table / set** names in that output.

You’re looking for something like:
- a table name that includes `crowdsec` (common), and/or
- a set name that looks like a blacklist/banlist, e.g. `crowdsec_blacklists`,
  `crowdsec-ban`, etc.

5) Add the drop rules to your `input` chain using the names you found.

Example (placeholder names — replace with the *actual* names from your host):

```nftables
# Example only — adjust to the actual table/set created by your bouncer:
# ip saddr @crowdsec_blacklist drop
# ip6 saddr @crowdsec6_blacklist drop
```

If you paste the output of:

```bash
sudo nft list ruleset | sed -n '1,200p'
```
after installing the bouncer, we can make these lines copy/paste accurate for
*your* exact set names.

---

## 6. Baseline nftables stance for this repo’s architecture

### 6.1 SSH-only public ingress (Cloudflare Tunnel handles HTTP/S)

If you use Cloudflare Tunnel, you generally do **not** need inbound `80/443`.
Your baseline input chain should look like:

- established/related accept
- loopback accept
- ICMP/ICMPv6 accept
- (optional) CrowdSec drop check (Pattern B)
- SSH accept (ideally restricted)
- log + drop

See:
- `docs/ingress.md`
- `nftables/nftables.conf`

### 6.2 Optional WireGuard posture

If you run WireGuard and want maximum restriction, make SSH reachable only over
`wg0`:

```nftables
iif "wg0" tcp dport ${SSH_PORT} accept
```

In this mode, CrowdSec’s SSH brute-force protection becomes less important
because the public internet can’t hit SSH at all.

---

## 7. CrowdSec vs Fail2ban in this repo

This repo already documents Fail2ban as optional:
- `docs/security/ssh-hardening.md` includes a Fail2ban section.

You can choose one of these approaches:

- **Replace Fail2ban with CrowdSec**:
  - simpler operationally if you already like CrowdSec’s ecosystem
  - collaborative blocklists + scenarios

- **Run both** (not usually necessary for SSH):
  - can create overlapping bans
  - increases complexity; prefer one primary enforcement path

A common pattern is:
- CrowdSec + nftables bouncer for enforcement (primary)
- no Fail2ban, unless you have a specific legacy jail need

---

## 8. Troubleshooting checklist

1. **Is CrowdSec running?**
   ```bash
   systemctl status crowdsec
   sudo cscli metrics
   ```

2. **Is the firewall bouncer running?**
   ```bash
   systemctl status crowdsec-firewall-bouncer
   journalctl -u crowdsec-firewall-bouncer -n 200 --no-pager
   ```

3. **Are decisions being created?**
   ```bash
   sudo cscli decisions list
   ```

4. **Did nftables rules/sets change when a decision appears?**
   ```bash
   sudo nft list ruleset | less
   ```

5. **Is your allow rule bypassing bans?**
   - Ensure any CrowdSec drop check (if you added one) is above your SSH accept.
   - If the bouncer manages its own rules, ensure they’re evaluated early enough.

---

## 9. Related docs

- `docs/ingress.md` — Cloudflare Tunnel port policy (close 80/443)
- `docs/security/ssh-hardening.md` — SSH hardening baseline + nftables
- `docs/vpn/wireguard-full-tunnel-nftables.md` — optional WireGuard admin access
- `nftables/nftables.conf` — baseline firewall ruleset