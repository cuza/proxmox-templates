# proxmox-templates

These scripts require `libguestfs-tools` to be installed in your Proxmox VE.

## Current LTS / stable templates

`current-lts.sh` builds checksum-verified cloud images with `virt-customize`,
without bind-mounting host directories or modifying existing templates.
Run it as root on Proxmox:

```sh
./current-lts.sh ubuntu  # 8004 ubuntu-resolute, Ubuntu 26.04 LTS
./current-lts.sh bookworm # 8052 debian-bookworm, Debian 12 oldstable
./current-lts.sh debian  # 8053 debian-trixie, Debian 13 stable
```

Defaults match Friday's existing conventions: `local-lvm`, `vmbr2`, 512 MiB
base template, host CPU, VirtIO SCSI, serial console, DHCP, cloud-init disk and
enabled QEMU guest agent. Override `TEMPLATE_ID`, `STORAGE_ID`, or `BRIDGE` as
needed. Working images expand to a sparse 20 GiB disk before package updates
(override `DISK_SIZE` if needed). IDs 8000–8004 track Ubuntu 18.04–26.04; IDs 8050–8053 track Debian
10–13, with 8052 assigned to Bookworm.

Use generic `amd64`, not `amd64v3`, for compatibility with older Xeons.
Templates contain no SSH authorized keys or application secrets; supply those
per clone. SSH host keys and cloud-init identity are reset before sealing.
Package updates remain enabled for clones. These images still need security
updates; LTS reduces the frequency of major OS upgrades.

The Ubuntu image URL is date-pinned. The Debian `latest` URL is constrained by
a pinned SHA-512: if upstream rotates the image, the script fails closed until
the URL/checksum is deliberately refreshed from Debian's published sums.
Existing matching templates are left untouched on a rerun; occupied IDs fail
without deletion. If a build fails after VM creation, inspect the partial VM
manually rather than automatically destroying anything.

### Proxmox xterm.js console

New templates explicitly configure `serial0: socket` and `vga: serial0`, a
115200-baud GRUB serial terminal, kernel consoles `tty0` and `ttyS0`, and
`serial-getty@ttyS0.service`. This gives both boot output and a login prompt
through Proxmox Console → xterm.js (or `qm terminal VMID`). Cloud images lock
password login by default; xterm.js showing a login prompt does not create a
password. Use SSH keys or set an appropriate per-clone cloud-init credential
if interactive console login is needed. Never bake a shared password into a
template. Serial-only display intentionally does not provide a graphical GUI.
