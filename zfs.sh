#!/bin/sh

sudo nano /etc/apt/sources.list
deb http://deb.debian.org/debian/ bullseye main contrib

sudo apt update

sudo -i

apt install --yes debootstrap gdisk dkms dpkg-dev linux-headers-$(uname -r)

apt install --yes --no-install-recommends zfs-dkms

modprobe zfs
apt install --yes zfsutils-linux

DISK=/dev/disk/by-id/xxx

# create partition
#uefi
sgdisk     -n2:1M:+512M   -t2:EF00 $DISK

#boot pool
sgdisk     -n3:0:+1G      -t3:BF01 $DISK
#root pool
sgdisk     -n4:0:0        -t4:BF00 $DISK

# boot pool
zpool create -o cachefile=/etc/zfs/zpool.cache -o ashift=12 -d -o feature@async_destroy=enabled -o feature@bookmarks=enabled -o feature@embedded_data=enabled -o feature@empty_bpobj=enabled -o feature@enabled_txg=enabled -o feature@extensible_dataset=enabled -o feature@filesystem_limits=enabled -o feature@hole_birth=enabled -o feature@large_blocks=enabled -o feature@lz4_compress=enabled -o feature@spacemap_histogram=enabled -o feature@zpool_checkpoint=enabled -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off -O normalization=formD -O relatime=on -O xattr=sa -O mountpoint=/boot -R /mnt bpool ${DISK}-part3

# root pool
zpool create -o ashift=12 -O acltype=posixacl -O canmount=off -O compression=lz4 -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa -O mountpoint=/ -R /mnt rpool ${DISK}-part4

zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian

zfs create -o mountpoint=/boot bpool/BOOT/debian

zfs create rpool/home
zfs create -o mountpoint=/root rpool/home/root
chmod 700 /mnt/root
zfs create -o canmount=off rpool/var
zfs create -o canmount=off rpool/var/lib
zfs create rpool/var/log
zfs create rpool/var/spool

zfs create -o canmount=off rpool/usr
zfs create rpool/usr/local

mkdir /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir /mnt/run/lock

debootstrap bullseye /mnt

mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

echo bullzfs > /mnt/etc/hostname
vi /mnt/etc/hosts

Add a line:
127.0.1.1       HOSTNAME

vi /mnt/etc/apt/sources.list

deb http://deb.debian.org/debian bullseye main contrib
deb-src http://deb.debian.org/debian bullseye main contrib

deb http://deb.debian.org/debian-security bullseye-security main contrib
deb-src http://deb.debian.org/debian-security bullseye-security main contrib

deb http://deb.debian.org/debian bullseye-updates main contrib
deb-src http://deb.debian.org/debian bullseye-updates main contrib

mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
chroot /mnt /usr/bin/env DISK=$DISK bash --login

ln -s /proc/self/mounts /etc/mtab
apt update

apt install --yes console-setup locales

apt install --yes dpkg-dev linux-headers-amd64 linux-image-amd64

apt install --yes zfs-initramfs

echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

'UEFI boot:
apt install dosfstools
mkdosfs -F 32 -s 1 -n EFI ${DISK}-part2
mkdir /boot/efi
echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK}-part2) /boot/efi vfat defaults 0 0 >> /etc/fstab
mount /boot/efi
apt-get install --yes grub-efi-amd64 shim-signed


apt remove --yes --purge os-prober

passwd

vi /etc/systemd/system/zfs-import-bpool.service

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

systemctl enable zfs-import-bpool.service

cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

grub-probe /boot

update-initramfs -c -k all

vi /etc/default/grub
# Set: GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"
# Remove quiet from: GRUB_CMDLINE_LINUX_DEFAULT
# Uncomment: GRUB_TERMINAL=console
# Save and quit.

update-grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy

mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
zed -F &

cat /etc/zfs/zfs-list.cache/bpool
cat /etc/zfs/zfs-list.cache/rpool

# stop zed
fg
# Press CTRL+C

# fix the paths to eliminate /mnt
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*

# first boot
apt install --yes openssh-server

zfs snapshot bpool/BOOT/debian@install
zfs snapshot rpool/ROOT/debian@install

exit

mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a

reboot

# get an ip address
dhclient

zfs create rpool/home/user
adduser user

cp -a /etc/skel/. /home/user
chown -R user:user /home/user
usermod -a -G audio,cdrom,dip,floppy,netdev,plugdev,sudo,video user

apt dist-upgrade --yes

# install desktop environment
tasksel

for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
done

vi /etc/network/interfaces
auto ens32
iface ens32 inet dhcp

reboot

sudo zfs destroy bpool/BOOT/debian@install
sudo zfs destroy rpool/ROOT/debian@install
