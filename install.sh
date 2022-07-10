#!/bin/bash

# Variables
HOSTNAME=""
DISK="/dev/disk/by-id/xxx"
NETWORK=""
LUKS_PASSWORD=""
ROOT_PASSWORD=""

### Installation
# Preparing the live system
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian/ bullseye main contrib
deb http://deb.debian.org/debian/ bullseye-updates main contrib
deb http://deb.debian.org/debian-security bullseye-security main contrib
EOF
apt update
apt install dosfstools gdisk debootstrap dkms dpkg-dev linux-headers-$(uname -r) -y
apt install --no-install-recommends zfs-dkms -y
modprobe zfs
apt install zfsutils-linux -y

## Creating partitions
# UEFI
sgdisk -n2:1M:+512M -t2:EF00 $DISK
# boot pool
sgdisk -n3:0:+1G -t3:BF01 $DISK
# swap
sgdisk -n4:0:+8G -t4:BF00 $DISK
# root pool
sgdisk -n5:0:0 -t5:BF00 $DISK

# LUKS encryption for rpool
echo $LUKS_PASSWORD | cryptsetup -q luksFormat ${DISK}-part5
echo $LUKS_PASSWORD | cryptsetup luksOpen /dev/sda2 crypt_system
dd if=/dev/zero of=/dev/mapper/crypt_system
## Installing ZFS
# boot pool
zpool create -o cachefile=/etc/zfs/zpool.cache -o ashift=12 -d -o feature@async_destroy=enabled -o feature@bookmarks=enabled -o feature@embedded_data=enabled -o feature@empty_bpobj=enabled -o feature@enabled_txg=enabled -o feature@extensible_dataset=enabled -o feature@filesystem_limits=enabled -o feature@hole_birth=enabled -o feature@large_blocks=enabled -o feature@lz4_compress=enabled -o feature@spacemap_histogram=enabled -o feature@zpool_checkpoint=enabled -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off -O normalization=formD -O relatime=on -O xattr=sa -O mountpoint=/boot -R /mnt bpool ${DISK}-part3
# root pool
zpool create -o ashift=12 -O acltype=posixacl -O canmount=off -O compression=lz4 -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa -O mountpoint=/ -R /mnt rpool /dev/mapper/crypt_system
zfs create -o mountpoint=/ rpool/ROOT
zfs create -o mountpoint=/boot bpool/BOOT
zfs create rpool/home
zfs create -o mountpoint=/root rpool/home/root
zfs create -o mountpoint=/home rpool/home/users
chmod 700 /mnt/root
mkdir /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir /mnt/run/lock
debootstrap bullseye /mnt
mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/
echo $HOSTNAME > /mnt/etc/hostname
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
chroot /mnt /usr/bin/env DISK=$DISK bash --login
cat > /usr/sbin/policy-rc.d <<EOF
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d
cat > /etc/crypttab <<EOF
crypt_swap $(blkid ${DISK}-part4 | awk '{print $2}' | tr -d '"') none luks,swap,discard
crypt_system $(blkid ${DISK}-part5 | awk '{print $2}' | tr -d '"') none luks,discard
EOF
ln -s /proc/self/mounts /etc/mtab
apt update
apt install --yes console-setup locales
apt install --yes dpkg-dev linux-headers-amd64 linux-image-amd64
apt install --yes zfs-initramfs
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf
apt install dosfstools
mkdosfs -F 32 -s 1 -n EFI ${DISK}-part2
mkdir /boot/efi
echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK}-part2) /boot/efi vfat defaults 0 0 >> /etc/fstab
mount /boot/efi
apt-get install --yes grub-efi-amd64 shim-signed

# root password
echo $ROOT_PASSWORD | passwd --stdin

cat > /etc/systemd/system/zfs-import-bpool.service <<EOF
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
# Work-around to preserve zpool cache:
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
EOF

systemctl enable zfs-import-bpool.service
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount
grub-probe /boot
update-initramfs -c -k all

sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT=""/g' /etc/default/grub
sed -i 's@GRUB_CMDLINE_LINUX=""@GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT"@g' /etc/default/grub
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy

mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d

zed -F &
cat /etc/zfs/zfs-list.cache/bpool
cat /etc/zfs/zfs-list.cache/rpool
killall zed

# fix the paths to eliminate /mnt
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
# first boot
apt install --yes openssh-server
zfs snapshot bpool/BOOT@install
zfs snapshot rpool/ROOT@install
zfs snapshot rpool/home/root@install
zfs snapshot rpool/home/users@install
exit

mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a
cryptsetup luksClose crypt_system

echo "System installed. You can reboot now."
