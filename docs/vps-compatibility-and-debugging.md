# **PET‑VPS: VPS Compatibility & Debugging Guide**
### *How to verify whether your VPS can run systemd‑nspawn, systemd‑machined, and PET‑VPS networking*

This guide gives you a reproducible, deterministic way to test any VPS provider before committing to it. This document walks through the exact debugging process used to diagnose a VPS that *claimed* to be KVM but silently blocked containerization features required by PET‑VPS.

If you follow these steps on your own VPS, you will quickly discover whether your provider is giving you:

- a **real KVM hypervisor**,  
- a **crippled container‑based VPS**, or  
- a **nested virtualization environment** that pretends to be KVM but blocks key kernel features.

This guide is intentionally thorough so you can reproduce the investigation and avoid deploying PET‑VPS on incompatible infrastructure.

---

# **1. Verify systemd‑machined is present and functional**

PET‑VPS requires:

- `systemd-machined.service`
- `systemd-machined.socket`
- `systemd-nspawn@.service`
- `machinectl`

On a healthy Debian 12 system:

```
systemctl status systemd-machined.socket
systemctl status systemd-machined.service
```

You should see:

```
Active: active (running)
```

### **If the socket is missing**
Some VPS providers ship “minimal Debian” images that remove systemd units.

Restore it manually:

```
sudo tee /lib/systemd/system/systemd-machined.socket >/dev/null <<'EOF'
[Unit]
Description=Virtual Machine and Container Registration Service Socket
Documentation=man:systemd-machined.service(8)
Before=sockets.target

[Socket]
ListenStream=/run/systemd/machine1.sock
SocketMode=0666

[Install]
WantedBy=sockets.target
EOF
```

Then:

```
systemctl daemon-reload
systemctl enable --now systemd-machined.socket
```

If this fails, your provider is shipping a crippled systemd build.

---

# **2. Verify the container root filesystem exists**

PET‑VPS expects containers under:

```
/var/lib/machines/<name>/
```

Check:

```
ls /var/lib/machines/web1
```

You should see a full Debian rootfs.

If missing, create it:

```
sudo debootstrap stable /var/lib/machines/web1 http://deb.debian.org/debian
```

---

# **3. Verify the container has a machine ID**

systemd‑nspawn will not register a machine without:

```
/var/lib/machines/web1/etc/machine-id
```

If missing:

```
sudo systemd-machine-id-setup --root=/var/lib/machines/web1
```

---

# **4. Attempt to start the machine**

```
machinectl start web1
machinectl list
```

Expected:

```
web1   container   running
```

If you still see:

```
No machines.
```

continue to the kernel tests.

---

# **5. Kernel Capability Tests (Critical)**

These tests determine whether your VPS hypervisor supports containerization.

Run all three:

---

## **5.1 Check cgroups version**

```
ls -l /sys/fs/cgroup
```

You should see:

```
cgroup.controllers
cgroup.subtree_control
```

This indicates **cgroups v2 unified**, which is required.

---

## **5.2 Check user namespaces**

```
cat /proc/sys/kernel/unprivileged_userns_clone
```

Expected:

```
1
```

If `0`, your provider disables user namespaces → PET‑VPS cannot run.

---

## **5.3 Check CAP_SYS_ADMIN**

```
capsh --print | grep cap_sys_admin
```

Expected:

```
cap_sys_admin
```

If missing → PET‑VPS cannot run.

---

## **5.4 Check network namespaces (the final boss)**

```
unshare -n true; echo $?
```

Expected:

```
0
```

If you get:

```
1
```

your VPS hypervisor **forbids network namespaces**, which makes:

- systemd‑nspawn  
- machinectl  
- machined  
- veth creation  
- PET‑VPS networking  

**impossible**, even though everything else appears correct.

This is the exact failure mode we discovered.

---

# **6. Final Diagnosis: Fake or Crippled KVM**

If:

- systemd is correct  
- machined is running  
- machine-id exists  
- rootfs exists  
- cgroups v2 is present  
- user namespaces are enabled  
- CAP_SYS_ADMIN is present  
- **but network namespaces fail (`unshare -n` returns 1)**  

then your VPS is **not real KVM**, even if advertised as such.

This is the signature of:

- OpenVZ  
- Virtuozzo  
- LXC masquerading as KVM  
- Nested virtualization  
- “Container VPS”  
- Hardened kernels with namespace restrictions  

PET‑VPS **cannot** run on these environments.

---

# **7. Recommended Providers (Confirmed Compatible)**

These providers support:

- full KVM  
- systemd‑machined  
- systemd‑nspawn  
- cgroups v2  
- user namespaces  
- network namespaces  
- veth creation  

### **Best options**
- **Azure** (custom images, full API, global regions)  
- **Hetzner** (CX/CPX)  
- **Vultr High Frequency**  
- **DigitalOcean**  
- **Linode (Akamai)**  
- **Dynu KVM NVMe (Custom ISO)**  

---

# **8. Known Incompatible Providers (Fake or Crippled VPS)**

*(You can expand this list as you test more providers.)*

- Providers using OpenVZ  
- Providers using Virtuozzo  
- Providers using LXC/LXD  
- Providers advertising “KVM” but blocking namespaces  
- Providers shipping “minimal Debian” with systemd units removed  
- Providers blocking network namespaces (`unshare -n` fails)  

---

# **9. Summary**

PET‑VPS depends on:

- systemd‑machined  
- systemd‑nspawn  
- cgroups v2  
- user namespaces  
- network namespaces  
- CAP_SYS_ADMIN  
- veth creation  

If any of these are blocked by the VPS hypervisor, PET‑VPS cannot run.
