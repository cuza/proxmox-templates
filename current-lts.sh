#!/usr/bin/env bash
# Build a NEW cloud-init template; never overwrite an existing VM or template.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root on the Proxmox node.' >&2; exit 1; }
case ${1:-} in
  ubuntu)
    template_id=${TEMPLATE_ID:-8004}
    name=ubuntu-resolute
    image=ubuntu-26.04-server-cloudimg-amd64.img
    url=https://cloud-images.ubuntu.com/releases/resolute/release-20260927
    checksum=8800651811af9a85465ad1d552add729947bb16488dddb4a9b5305a3d97332b2
    hash_command=sha256sum
    ;;
  bookworm)
    template_id=${TEMPLATE_ID:-8052}
    name=debian-bookworm
    image=debian-12-genericcloud-amd64.qcow2
    url=https://cloud.debian.org/images/cloud/bookworm/latest
    checksum=a09170d17e13af43da61774666f520e3bbec0f8bd96b4db37c15f3426fb327ccad950b80dbe78c09aa5ca90ce5015e99334b0ba5188fd4018736bc3fb5f0882c
    hash_command=sha512sum
    ;;
  debian)
    template_id=${TEMPLATE_ID:-8053}
    name=debian-trixie
    image=debian-13-genericcloud-amd64.qcow2
    url=https://cloud.debian.org/images/cloud/trixie/latest
    checksum=f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d
    hash_command=sha512sum
    ;;
  *) echo 'Usage: current-lts.sh ubuntu|bookworm|debian' >&2; exit 2 ;;
esac
storage=${STORAGE_ID:-local-lvm}
bridge=${BRIDGE:-vmbr2}
[[ $template_id =~ ^[0-9]+$ ]]
for command in qm pvesm curl virt-customize virt-cat virt-resize qemu-img "$hash_command"; do command -v "$command" >/dev/null; done
if existing=$(qm config "$template_id" 2>/dev/null); then
  if [[ $existing == *"name: $name"* && $existing == *'template: 1'* ]]; then
    echo "Template $template_id $name already exists; leaving it untouched."
    exit 0
  fi
  echo "ID $template_id is occupied; refusing to overwrite it." >&2
  exit 1
fi
ip link show "$bridge" >/dev/null
pvesm status --storage "$storage"
work=$(mktemp -d /var/tmp/proxmox-lts.XXXXXX)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 3 "$url/$image" -o "$work/base.qcow2"
printf '%s  %s\n' "$checksum" "$work/base.qcow2" | "$hash_command" -c -
qemu-img create -f qcow2 "$work/template.qcow2" "${DISK_SIZE:-20G}"
virt-resize --expand /dev/sda1 "$work/base.qcow2" "$work/template.qcow2"
virt-customize --memsize 2048 -a "$work/template.qcow2" \
  --update \
  --install qemu-guest-agent,curl,jq,net-tools,nfs-common,open-iscsi,lsscsi,sg3-utils,multipath-tools \
  --run-command 'systemctl enable qemu-guest-agent.service serial-getty@ttyS0.service' \
  --run-command 'printf '"'"'GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"\nGRUB_TERMINAL="console serial"\nGRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"\n'"'"' > /etc/default/grub.d/99-proxmox-serial.cfg; update-grub' \
  --run-command 'printf "UseDNS no\n" > /etc/ssh/sshd_config.d/90-template.conf' \
  --run-command 'cloud-init clean --logs --machine-id' \
  --run-command 'rm -f /etc/ssh/ssh_host_*' \
  --run-command 'apt-get clean'
virt-cat -a "$work/template.qcow2" /etc/os-release
qm create "$template_id" --name "$name" --memory 512 --cores 1 \
  --cpu host --net0 "virtio,bridge=$bridge" --agent enabled=1 \
  --scsihw virtio-scsi-pci --serial0 socket --vga serial0 \
  --ostype l26 --onboot 1 --ipconfig0 ip=dhcp
qm importdisk "$template_id" "$work/template.qcow2" "$storage"
# Ask Proxmox for the imported volume rather than assuming backend-specific names.
volume=$(qm config "$template_id" | awk '/^unused0:/ {print $2}')
[[ -n $volume ]]
qm set "$template_id" --scsi0 "$volume" --ide2 "$storage:cloudinit" --boot order=scsi0
qm template "$template_id"
qm config "$template_id"
