# QEMU Lab — disk images, overlays, snapshots, and live boot tests

This section adds a **QEMU-first lab workflow** that pairs well with the repo’s template ladder (**web1 → web2 → web3**) described in the root `README.md`.

Goal: **build an image → modify safely → test boot live → iterate via overlays/snapshots → promote to a real VM**.

> Scope note
> 
> - This doc focuses on *repeatable image workflows* you can run on a Debian VPS or a dev box.
> - It is not meant to be an exhaustive QEMU reference.
> - Commands below assume you understand the risk of working as `root` around block devices.

---

## 12.1 Why QEMU here?

Even though QEMU is “old”, it is still one of the most practical tools for:

- Creating and converting images (`raw`, `qcow2`, etc.).
- Building **overlay** images (copy-on-write) for fast iteration.
- Taking **snapshots** and rolling back.
- Booting an image “live” to validate that it actually works.
- Doing all of the above **without needing a hypervisor UI**.

In this repo’s terms, QEMU lets you treat images the same way you treat your templates:

- **web1** → local, simple, direct
- **web2** → remote dev workflow / live editing (SSHFS)
- **web3** → multi-tenant / multi-app patterns (Traefik routing)

So Section 12 mirrors that ladder with:

- **dev1.example.com** → image manipulation & overlays (local, simple)
- **dev2.example.com** → mount/edit images (SSHFS-style workflow)
- **dev3.example.com** → subdomain-per-dev patterns (Traefik / routing)

---

## 12.2 Packages you will typically need

On Debian (host), these are the usual baseline tools:

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-system-x86 \
  qemu-utils \
  ovmf \
  cloud-image-utils \
  libguestfs-tools \
  sshfs
```

Notes:

- `qemu-utils` provides `qemu-img`.
- `ovmf` is for UEFI boot testing (`OVMF_CODE.fd` / `OVMF_VARS.fd`).
- `libguestfs-tools` provides `guestfish`, `virt-filesystems`, etc. (often safer than attaching images with `qemu-nbd`).
- `sshfs` is optional, but aligns with your web2 pattern.

---

## 12.3 Directory layout convention (recommended)

Pick one place to store images and keep it consistent:

```bash
sudo mkdir -p /srv/qemu/{base,overlays,snapshots,iso,notes}
sudo chmod 0755 /srv/qemu
```

Example naming:

- Base images: `/srv/qemu/base/debian-trixie-amd64.qcow2`
- Overlays: `/srv/qemu/overlays/dev1-web1.qcow2`
- Snapshots (optional external snapshots): `/srv/qemu/snapshots/...`

---

## 12.4 dev1.example.com (web1-style): create images, overlays, snapshots

This subsection is the **image lab**. The idea is: keep one stable base image, and do all experimentation in overlays.

### 12.4.1 Create a base image

If you want a blank disk image:

```bash
sudo qemu-img create -f qcow2 /srv/qemu/base/dev1-base.qcow2 20G
qemu-img info /srv/qemu/base/dev1-base.qcow2
```

If you already have a `.raw` or `.img`:

```bash
# raw/img → qcow2 (smaller, supports overlays/snapshots)
sudo qemu-img convert -p -O qcow2 input.raw /srv/qemu/base/dev1-base.qcow2
qemu-img info /srv/qemu/base/dev1-base.qcow2
```

### 12.4.2 Create an overlay (copy-on-write)

Overlays are the “pet VPS safe mode” for images:

```bash
sudo qemu-img create -f qcow2 \
  -b /srv/qemu/base/dev1-base.qcow2 \
  -F qcow2 \
  /srv/qemu/overlays/dev1-web1.qcow2

qemu-img info /srv/qemu/overlays/dev1-web1.qcow2
```

### 12.4.3 Internal snapshots (qcow2)

If you’re using `qcow2`, you can snapshot while iterating:

```bash
# List snapshots
sudo qemu-img snapshot -l /srv/qemu/overlays/dev1-web1.qcow2

# Create a snapshot
sudo qemu-img snapshot -c before-upgrade /srv/qemu/overlays/dev1-web1.qcow2

# Revert to a snapshot
sudo qemu-img snapshot -a before-upgrade /srv/qemu/overlays/dev1-web1.qcow2
```

> Recommendation
> 
> Use overlays + snapshots for fast iteration, but periodically **flatten** a “known good” overlay into a new base.

---

## 12.5 Boot-test an image live (QEMU system mode)

### 12.5.1 Minimal BIOS boot test (headless)

If your image is bootable already:

```bash
sudo qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -drive file=/srv/qemu/overlays/dev1-web1.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

Then from another terminal on the host:

```bash
ssh -p 2222 root@127.0.0.1
```

### 12.5.2 UEFI boot test (OVMF)

If you’re working with UEFI images:

```bash
sudo qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/srv/qemu/notes/dev1-ovmf-vars.fd \
  -drive file=/srv/qemu/overlays/dev1-web1.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

First time, create a writable VARS copy:

```bash
sudo cp /usr/share/OVMF/OVMF_VARS.fd /srv/qemu/notes/dev1-ovmf-vars.fd
sudo chmod 0644 /srv/qemu/notes/dev1-ovmf-vars.fd
```

---

## 12.6 dev2.example.com (web2-style): mount/edit images (SSHFS pattern)

In web2, the host mounts a remote directory via SSHFS and bind-mounts it into a container.

For images, the analogous pattern is:

- Keep images “somewhere else” (a dev workstation, NAS, or another box).
- Mount them on the VPS for manipulation/testing.

### 12.6.1 Mount a remote image directory via SSHFS

Example:

```bash
sudo mkdir -p /srv/sshfs/dev2-images

# Example only: use the same hardening approach as web2 (dedicated key, known_hosts, IdentitiesOnly, etc.)
sudo sshfs \
  -o IdentityFile=/etc/sshfs/dev2-deploy-key \
  -o UserKnownHostsFile=/etc/sshfs/dev2-known_hosts \
  -o StrictHostKeyChecking=yes \
  -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
  <REMOTE_USER>@<REMOTE_HOST>:/path/to/images \
  /srv/sshfs/dev2-images

ls -lah /srv/sshfs/dev2-images
```

Now you can:

- Create overlays on the VPS that reference the remote base image.
- Run QEMU against the overlay (local) while keeping the base elsewhere.

> Caveat
> 
> QEMU needs fast, consistent disk IO. Running *the active disk image* over SSHFS may be slow or flaky.
> Prefer: remote base (read-mostly) + local overlay (write-heavy).

### 12.6.2 Recommended pattern: remote base + local overlay

```bash
# Remote base (read-mostly)
REMOTE_BASE=/srv/sshfs/dev2-images/debian-base.qcow2

# Local overlay (write-heavy)
sudo qemu-img create -f qcow2 -b "${REMOTE_BASE}" -F qcow2 /srv/qemu/overlays/dev2-web2.qcow2

# Boot-test using the local overlay
sudo qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -drive file=/srv/qemu/overlays/dev2-web2.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2223-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

---

## 12.7 dev3.example.com (web3-style): subdomain-per-dev via Traefik (multi-tenant pattern)

This repo’s `/docs` folder treats **Traefik** as an optional routing layer for multi-app cases.

A practical extension is: **one subdomain per dev user**, e.g.: 

- `dev1.example.com`
- `dev2.example.com`
- `dev3.example.com`

Each dev can choose a workflow:

- Container-only (no QEMU)
- QEMU-based image lab on a separate box
- “Promote” a tested image into a VM

### 12.7.1 Why do this?

- Keeps “pet VPS” production clean.
- Gives experimentation space without making the main host fragile.
- Makes it easy to revoke access by removing one router rule.

### 12.7.2 Minimal conceptual routing model

- Traefik terminates/handles routing.
- Each dev subdomain points to one backend (container, upstream service, or a VM).
- QEMU activity should ideally happen off the main production VPS, unless you explicitly accept the CPU/RAM impact.

> Security note
>
> If you allow untrusted devs to run arbitrary workloads, you need real isolation:
> quotas, separate hosts, VMs per dev, and a clear threat model.

---

## 12.8 Safer ways to edit images than “attaching them”

Two common options:

### Option A: libguestfs (recommended)

```bash
# Inspect partitions/filesystems
sudo virt-filesystems -a /srv/qemu/overlays/dev1-web1.qcow2 --all --long --uuid

# Interactive editing
sudo guestfish -a /srv/qemu/overlays/dev1-web1.qcow2
```

### Option B: qemu-nbd (powerful, but be careful)

```bash
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 /srv/qemu/overlays/dev1-web1.qcow2

# Then use lsblk/parted/mount as needed...
lsblk /dev/nbd0

# When done:
sudo qemu-nbd --disconnect /dev/nbd0
```

---

## 12.9 Promote a “known good” overlay into a new base image

When an overlay has reached a stable point, you can flatten it:

```bash
sudo qemu-img convert -p -O qcow2 \
  /srv/qemu/overlays/dev1-web1.qcow2 \
  /srv/qemu/base/dev1-promoted-$(date +%F).qcow2

qemu-img info /srv/qemu/base/dev1-promoted-$(date +%F).qcow2
```

Now you can:

- Use that promoted image as the new backing file for future overlays.
- Convert it into whatever your VM platform expects.

---

## 12.10 Convert images into VMs (high-level)

The exact “promotion to VM” step depends on what you use:

- **libvirt / virt-install**
- **Proxmox**
- **Cloud images** (OpenStack-style)

But the general pattern is always:

1. Start from a **promoted** qcow2.
2. Ensure it boots under QEMU (BIOS/UEFI as needed).
3. Ensure network + SSH works.
4. Import/attach it to your VM platform.

---

## 12.11 Troubleshooting tips

- If the guest won’t boot: confirm the image is the right architecture and has a bootloader.
- If SSH hostfwd doesn’t work: verify the guest runs `sshd` and listens on port 22.
- If performance is poor: keep write-heavy overlays on local SSD, not over SSHFS.

---

## 12.12 Next steps (suggested)

When you do your “today on the VPS” test run, consider capturing:

- `qemu-img info` output for base + overlay.
- Snapshot list output.
- A successful `ssh -p 2222 ...` into the booted image.
- A diagram similar to the web1/web2/web3 diagrams in the root README.
