#!/bin/bash

set -x
set -e

export IMGID=9000
export CODENAME=jammy
export VLAN_TAG=
export STORAGEID="local-lvm"
export BASE_IMG="$CODENAME-server-cloudimg-amd64.img"
export IMG="$CODENAME-server-cloudimg-amd64-${IMGID}.qcow2"

# vlan settings 
if [ -z "$VLAN_TAG" ];then
      export VLAN_SECTION=
else
      export VLAN_SECTION=,tag=$VLAN_TAG
fi

if [ ! -f "${BASE_IMG}" ];then
  wget https://cloud-images.ubuntu.com/$CODENAME/current/$CODENAME-server-cloudimg-amd64.img
fi

if [ ! -f "${IMG}" ];then
  cp -f "${BASE_IMG}" "${IMG}"
fi

# prepare mounts
mkdir -p /tmp/img/$CODENAME
guestmount -a ${IMG} -m /dev/sda1 /tmp/img/$CODENAME/
mount --bind /dev/ /tmp/img/$CODENAME/dev/
mount --bind /proc/ /tmp/img/$CODENAME/proc/

# get resolving working
mv /tmp/img/$CODENAME/etc/resolv.conf /tmp/img/$CODENAME/etc/resolv.conf.orig
cp -a --force /etc/resolv.conf /tmp/img/$CODENAME/etc/resolv.conf

# install desired apps
chroot /tmp/img/$CODENAME /bin/bash -c "apt-get update"
chroot /tmp/img/$CODENAME /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y net-tools curl cloud-initramfs-growroot qemu-guest-agent nfs-common open-iscsi lsscsi sg3-utils multipath-tools scsitools"

# https://www.electrictoolbox.com/sshd-hostname-lookups/
sed -i 's:#UseDNS no:UseDNS no:' /tmp/img/$CODENAME/etc/ssh/sshd_config

sed -i '/package-update-upgrade-install/d' /tmp/img/$CODENAME/etc/cloud/cloud.cfg

cat > /tmp/img/$CODENAME/etc/cloud/cloud.cfg.d/99_custom.cfg << '__EOF__'
#cloud-config

# Install additional packages on first boot
#
# Default: none
#
# if packages are specified, this apt_update will be set to true
#
# packages may be supplied as a single package name or as a list
# with the format [<package>, <version>] wherein the specifc
# package version will be installed.
#packages:
# - qemu-guest-agent
# - nfs-common

ntp:
  enabled: true

# datasource_list: [ NoCloud, ConfigDrive ]
__EOF__

cat > /tmp/img/$CODENAME/etc/multipath.conf << '__EOF__'
defaults {
    user_friendly_names yes
    find_multipaths yes
}
__EOF__

# enable services
chroot /tmp/img/$CODENAME systemctl enable open-iscsi.service || true
chroot /tmp/img/$CODENAME systemctl enable multipath-tools.service || true

# restore systemd-resolved settings
mv /tmp/img/$CODENAME/etc/resolv.conf.orig /tmp/img/$CODENAME/etc/resolv.conf

# umount everything
umount /tmp/img/$CODENAME/dev
umount /tmp/img/$CODENAME/proc
umount /tmp/img/$CODENAME
rm -rf /tmp/img/$CODENAME

# create template
qm create ${IMGID} --memory 512 --name ubuntu-${CODENAME} --net0 virtio,bridge=vmbr0${VLAN_SECTION}
qm importdisk ${IMGID} ${IMG} ${STORAGEID} --format qcow2
qm set ${IMGID} --scsihw virtio-scsi-pci --scsi0 ${STORAGEID}:vm-${IMGID}-disk-0
qm set ${IMGID} --ide2 ${STORAGEID}:cloudinit
qm set ${IMGID} --boot c --bootdisk scsi0
qm set ${IMGID} --serial0 socket --vga serial0
qm template ${IMGID}

# set host cpu, ssh key, etc
qm set ${IMGID} --scsihw virtio-scsi-pci
qm set ${IMGID} --cpu host
qm set ${IMGID} --agent enabled=1
qm set ${IMGID} --autostart
qm set ${IMGID} --onboot 1
qm set ${IMGID} --ostype l26
qm set ${IMGID} --ipconfig0 "ip=dhcp"

# cleaning up
rm $BASE_IMG
rm $IMG
