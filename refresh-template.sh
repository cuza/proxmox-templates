#!/usr/bin/env bash
# Refresh console and clone hygiene on an independent COPY; retain original disk.
set -euo pipefail
[[ $EUID == 0 && ${1:-} =~ ^[0-9]+$ ]] || { echo 'Usage (root): refresh-template.sh TEMPLATE_ID' >&2; exit 2; }
id=$1
config=$(qm config "$id")
grep -qx 'template: 1' <<< "$config"
volume=$(awk '/^scsi0:/ {split($2,a,",");print a[1]}' <<< "$config")
[[ $volume == local-lvm:base-* ]] || { echo 'Only local-lvm base disks are supported.' >&2; exit 1; }
base=${volume#*:}
# Fail closed on linked children; do not alter templates used by existing VMs.
if lvs --noheadings -o origin pve | awk '{$1=$1;print}' | grep -qx "$base"; then
  echo "SKIP $id: $base has linked children; leave template and VMs untouched."
  exit 0
fi
disk=$(pvesm path "$volume")
activated=0
if [[ ! -e $disk ]]; then lvchange -ay -K "pve/$base"; activated=1; fi
work=$(mktemp -d /var/tmp/template-refresh.XXXXXX)
cleanup() {
  rm -rf "$work"
  if (( activated )); then lvchange -an "pve/$base"; fi
}
trap cleanup EXIT
revision=serial-v1
if [[ $(virt-cat -a "$disk" /etc/proxmox-template-revision 2>/dev/null || true) == "$revision" ]]; then
  echo "Template $id already refreshed."
  exit 0
fi
backup_dir=/root/proxmox-template-backups
install -d -m 700 "$backup_dir"
backup="$backup_dir/$id-$(date -u +%Y%m%dT%H%M%SZ).conf"
printf '%s\n' "$config" > "$backup"
chmod 600 "$backup"
qemu-img convert -f raw -O qcow2 "$disk" "$work/refreshed.qcow2"
cat > "$work/customize.sh" <<'GUEST'
#!/bin/sh
set -eu
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/99-proxmox-serial.cfg <<'GRUB'
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB
if command -v update-grub >/dev/null; then
  if [ -d /usr/lib/grub/i386-pc ]; then grub-install --target=i386-pc /dev/sda; fi
  update-grub
else
  # RHEL-family GRUB does not consistently source grub.d snippets.
  sed -i '/^GRUB_CMDLINE_LINUX=/ s/"$/ console=tty0 console=ttyS0,115200n8"/' /etc/default/grub
  grub2-mkconfig -o /boot/grub2/grub.cfg
fi
systemctl enable serial-getty@ttyS0.service
if systemctl list-unit-files qemu-guest-agent.service | grep -q qemu-guest-agent; then
  systemctl enable qemu-guest-agent.service
fi
# Use the main config for old OpenSSH releases without Include support.
if ! grep -q '^UseDNS no$' /etc/ssh/sshd_config; then printf '\nUseDNS no\n' >> /etc/ssh/sshd_config; fi
cloud-init clean --logs
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id /etc/ssh/ssh_host_*
ln -s /etc/machine-id /var/lib/dbus/machine-id
printf 'serial-v1\n' > /etc/proxmox-template-revision
GUEST
virt-customize --memsize 2048 -a "$work/refreshed.qcow2" --run "$work/customize.sh"
[[ $(virt-cat -a "$work/refreshed.qcow2" /etc/proxmox-template-revision) == "$revision" ]]
# Import while the old template remains intact. Select only the newly imported disk.
qm importdisk "$id" "$work/refreshed.qcow2" local-lvm
new_volume=$(qm config "$id" | awk '/^unused[0-9]+:/ {print $2}' | grep -E "^local-lvm:vm-$id-disk-[0-9]+$" | tail -1)
[[ -n $new_volume && $new_volume != "$volume" ]]
echo "Saved configuration: $backup; retained original disk: $volume"
# No guest can boot during this short config transition. Never remove original disk.
qm set "$id" --template 0
qm set "$id" --scsi0 "$new_volume" --serial0 socket --vga serial0 --agent enabled=1 --boot order=scsi0
qm template "$id" --disk scsi0
qm config "$id"
echo "Restore by reattaching $volume; configuration backup: $backup"
