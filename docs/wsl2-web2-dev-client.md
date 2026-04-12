# Using Debian on WSL2 as a Dev Client to Preview VPS Web2 Stack

This guide outlines how to set up Debian on WSL2 as a development client to preview the VPS web2 stack via an SSH local port-forward to Varnish running on `127.0.0.1:6081`.

## Step-by-Step Instructions

### 1. Setting Up WSL2 with Debian
Install Debian from the Microsoft Store or use your preferred method to set up WSL2.

### 2. SSH Local Port-Forwarding
Use the following command to set up SSH local port-forwarding:
```bash
ssh -L 6081:127.0.0.1:6081 user@your-vps-ip
```
Replace `user@your-vps-ip` with your VPS SSH login details.

### 3. Verify Web2 is Up
To ensure that your web2 stack is functioning correctly, run the following checks:
- Check systemd services:
  ```bash
  systemctl status srv-sshfs-web2.mount
  systemctl status systemd-nspawn@web2
  ```
- Check Apache inside the container:
  ```bash
  machinectl shell web2 systemctl status apache2
  ```
- Check Varnish:
  ```bash
  systemctl status varnish
  ```
- Check Caddy:
  ```bash
  systemctl status caddy
  ```
- Check mountpoint:
  Ensure that the mountpoint is correctly set up:
  ```bash
  mount | grep srv-sshfs-web2
  ```
- Perform curl checks:
  ```bash
  curl http://127.0.0.1:6081
  ```

This should return your web2 site's response.

## Conclusion
Following these steps will set you up with a WSL2 client capable of interacting with the VPS's web2 stack. For further information, consult your VPS documentation.