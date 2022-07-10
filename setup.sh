#!/bin/sh

cryptsetup -q luksFormat --verify-passphrase --hash sha256 --key-size=512 --cipher aes-xts-plain64 /dev/sda2
cryptsetup luksOpen /dev/sda2 crypt_system
mount /dev/system/root /mnt
mkdir -p /mnt/{boot,var,tmp,home}
mount /dev/sda1 /mnt/boot
mount /dev/system/var /mnt/var
mkdir -p /mnt/var/log
mount /dev/system/log /mnt/var/log
mount /dev/system/home /mnt/home
mkdir -p /mnt/srv
mount /dev/system/srv /mnt/srv

debootstrap --arch=amd64 --variant=minbase bullseye /mnt http://deb.debian.org/debian/

mkdir -p /mnt/{proc,sys,dev}
for i in proc sys dev; do mount -o bind "/${i}" "/mnt/${i}"; done
chroot /mnt

rm /etc/apt/sources.list
mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/debian.list <<EOF
deb http://deb.debian.org/debian/ bullseye main contrib non-free
deb http://deb.debian.org/debian/ bullseye-updates main contrib non-free
deb http://deb.debian.org/debian-security bullseye-security main contrib non-free
EOF
apt update
apt dist-upgrade -y

mkdir -p /etc/network/interfaces.d
echo "source-directory /etc/network/interfaces.d" > /etc/network/interfaces
cat > /etc/network/interfaces.d/lo <<EOF
auto lo
iface lo inet loopback
EOF
cat > /etc/network/interfaces.d/enp0s20f0 <<EOF
auto enp0s20f0
iface enp0s20f0 inet static
	address X.X.X.X/24
	gateway X.X.X.1
iface enp0s20f0 inet6 static
	address XXXX:XXXX:XXXX:100::1/56
EOF

echo pony > /etc/hostname
hostname -F /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1       pony.example.org pony
127.0.0.1       localhost

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat > /etc/fstab <<EOF
proc				/proc			proc	defaults			0	0
sysfs				/sys			sysfs	defaults			0	0
cgroup				/sys/fs/cgroup	cgroup	defaults			0	0
tmpfs				/tmp			tmpfs	nodev,nosuid,nodev,noatime,size=1G	0	0
$(blkid /dev/disk/by-label/swap | awk '{print $3}' | tr -d '"')	none	swap	swap	0	0

$(blkid /dev/disk/by-label/root | awk '{print $3}' | tr -d '"')	/			ext4	errors=remount-ro,noatime	0	1
$(blkid /dev/disk/by-label/boot | awk '{print $3}' | tr -d '"')	/boot		ext4	defaults,noatime			0	2
$(blkid /dev/disk/by-label/var | awk '{print $3}' | tr -d '"')	/var		ext4	defaults,noatime			0	2
$(blkid /dev/disk/by-label/log | awk '{print $3}' | tr -d '"')	/var/log	ext4	defaults,noatime			0	2
$(blkid /dev/disk/by-label/srv | awk '{print $3}' | tr -d '"')	/srv 		ext4	defaults,noatime			0	2
EOF

cat > /etc/crypttab <<EOF
crypt_system $(blkid /dev/sda2 | awk '{print $2}' | tr -d '"') none luks
EOF

apt -y install dialog locales
apt -y install localepurge
localepurge
dpkg-reconfigure localepurge
apt -y install bash-completion less rsyslog unbound systemd-sysv kbd console-setup console-data net-tools network-manager
for i in dev sys proc var/log var home srv boot ""; do umount "/mnt/${i}"; done
vgchange -a n
cryptsetup luksClose crypt_system

reboot
