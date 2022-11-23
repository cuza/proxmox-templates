#!/bin/bash

set -xe

export IMGID=9021
export STORAGEID="local-lvm"
export VLAN_TAG=

export RELEASE=8

export BASE_IMG="AlmaLinux-$RELEASE-GenericCloud-latest.x86_64.qcow2"
export IMG="AlmaLinux-$RELEASE-GenericCloud-latest.x86_64-${IMGID}.qcow2"

# vlan settings 
if [ -z "$VLAN_TAG" ];then
      export VLAN_SECTION=
else
      export VLAN_SECTION=,tag=$VLAN_TAG
fi

if [ ! -f "${BASE_IMG}" ];then
  wget https://repo.almalinux.org/almalinux/$RELEASE/cloud/x86_64/images/AlmaLinux-$RELEASE-GenericCloud-latest.x86_64.qcow2
fi

if [ ! -f "${IMG}" ];then
  cp -f "${BASE_IMG}" "${IMG}"
fi



# prepare mounts
mkdir -p /tmp/img/almalinux-$RELEASE
guestmount -a ${IMG} -m /dev/sda2 /tmp/img/almalinux-$RELEASE/

# https://www.reddit.com/r/homelab/comments/9s9bcc/proxmoxqemu_question_10023_dns_server/
# https://stackoverflow.com/questions/49826047/cloud-init-manage-resolv-conf
# https://www.centos.org/forums/viewtopic.php?t=66712

rm -rf /tmp/img/almalinux-$RELEASE/etc/resolv.conf

# https://www.electrictoolbox.com/sshd-hostname-lookups/
sed -i 's:#UseDNS yes:UseDNS no:' /tmp/img/almalinux-$RELEASE/etc/ssh/sshd_config

cat > /tmp/img/almalinux-$RELEASE/etc/cloud/cloud.cfg.d/99_custom.cfg << '__EOF__'
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
packages:
 - iscsi-initiator-utils
 - nfs-utils
 - qemu-guest-agent
 - cloud-utils-growpart
 - wget
 - curl

ntp:
  enabled: true

datasource_list: [ NoCloud, ConfigDrive ]
__EOF__

# umount everything
umount /tmp/img/almalinux-$RELEASE
rm -rf /tmp/img/almalinux-$RELEASE


# create template
qm create ${IMGID} --memory 512 --net0 virtio,bridge=vmbr0${VLAN_SECTION} --name almalinux-${RELEASE}
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
