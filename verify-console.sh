#!/usr/bin/env bash
# Boot a disposable snapshot of a template through QEMU serial, without editing
# the template or creating a persistent Proxmox VM. External network access stays disabled.
set -euo pipefail
[[ $EUID == 0 ]]
[[ ${1:-} =~ ^[0-9]+$ ]] || { echo 'Usage: verify-console.sh TEMPLATE_ID' >&2; exit 2; }
config=$(qm config "$1")
grep -qx 'template: 1' <<< "$config"
grep -qx 'serial0: socket' <<< "$config"
grep -qx 'vga: serial0' <<< "$config"
volume=$(awk '/^scsi0:/ {split($2,a,",");print a[1]}' <<< "$config")
disk=$(pvesm path "$volume")
activated=0
if [[ ! -e $disk && $disk == /dev/pve/* ]]; then
  lvchange -ay -K "pve/${disk##*/}"
  activated=1
fi
log=$(mktemp)
cleanup() {
  rm -f "$log"
  if (( activated )); then lvchange -an "pve/${disk##*/}" || echo "Leaving base active: another operation is using it." >&2; fi
}
trap cleanup EXIT
# A shell timeout only terminates this disposable QEMU process. snapshot=on
# redirects guest writes to a temporary overlay; the source template is read-only.
status=0
timeout --kill-after=10 300 /usr/bin/kvm -machine accel=kvm -cpu host -m 2048 -smp 2 \
  -drive "file=$disk,format=raw,if=virtio,snapshot=on" \
  -nic user,restrict=on,model=virtio-net-pci -display none -serial stdio -monitor none -no-reboot > "$log" 2>&1 || status=$?
if [[ $status != 0 && $status != 124 ]]; then tail -40 "$log" >&2; exit 1; fi
tail -20 "$log"
grep -E 'Linux version|Started.*Serial Getty|ttyS0|login:' "$log" | tail -12
grep -Eq 'Started.*Serial Getty|login:' "$log"
echo "PASS: template $1 booted to a serial getty in an isolated temporary snapshot"
