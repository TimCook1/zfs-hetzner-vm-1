#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Debian 10 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power sysle
Next, connect via SSH to console, and run the script 
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

set -o errexit
set -o pipefail
set -o nounset


#v_deb_packages_repo=http://deb.debian.org/debian
#v_deb_security_repo=http://security.debian.org

v_deb_packages_repo=http://mirror.hetzner.de/debian/packages
v_deb_security_repo=http://mirror.hetzner.de/debian/security


function chroot_execute {
  chroot /mnt bash -c "$1"
}

function initial_load_debian_zed_cache {
  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/rpool"
  chroot_execute "ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/"

  chroot_execute "zed -F &"

  local success=0
  
  if [[ ! -e /mnt/etc/zfs/zfs-list.cache/rpool ]] || [[ -e /mnt/etc/zfs/zfs-list.cache/rpool && (( $(ls -l /mnt/etc/zfs/zfs-list.cache/rpool 2> /dev/null | cut -d ' ' -f 5) == 0 )) ]]; then
    chroot_execute "zfs set canmount=noauto rpool"

    SECONDS=0

    while (( SECONDS++ <= 120 )); do
      if [[ -e /mnt/etc/zfs/zfs-list.cache/rpool ]] && (( "$(ls -l /mnt/etc/zfs/zfs-list.cache/rpool | cut -d ' ' -f 5)" > 0 )); then
        success=1
        break
      else
        sleep 1
      fi      
    done
  else 
    success=1
  fi

  if (( success != 1 )); then
    echo "Fatal zed daemon error: the ZFS cache hasn't been updated by ZED!"
    exit 1
  fi

  chroot_execute "pkill zed"

  sed -Ei 's|/mnt/?|/|g' /mnt/etc/zfs/zfs-list.cache/rpool
}

function unmount_and_export_fs {

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "/mnt/$virtual_fs_dir"
  done

  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "/mnt/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "/mnt/$virtual_fs_dir"; then
      echo "Re-issuing umount for /mnt/$virtual_fs_dir"
      umount --recursive --force --lazy "/mnt/$virtual_fs_dir"
    fi
  done

  SECONDS=0
  zpools_exported=99
  echo "===========exporting zfs pools============="
  set +e
  while (( zpools_exported == 99 )) && (( SECONDS++ <= 60 )); do
    zpool export -a 2> /dev/null
    if [[ $? == 0 ]]; then
      zpools_exported=1
      echo "all zfs pools were succesfully exported"
      break;
    else  
      sleep 1
     fi  
  done 
  set -e
  if (( zpools_exported != 1 )); then
    echo "fatal error: failed to export zfs pools"
    exit 1
  fi
}

export LC_ALL=en_US.UTF-8

if [[ ! -r /root/.ssh/authorized_keys ]]; then
  echo "SSH pubkey file is absent, please add it to the rescue system setting, then reboot into rescue system and run the script"
  exit 1
fi

read -r -p "Enter desired hostname [terem]: " v_hostname
v_hostname=${v_hostname:-terem}

read -r -p "Enter desired ZFS ARC max cache size in bytes [250000000]: " v_zfs_arc_max
v_zfs_arc_max=${v_zfs_arc_max:-250000000}

echo "NOTE: password login via SSH will be disabled for all accounts"
read -r -p "Enter root password [test1234]: " v_root_password
v_root_password=${v_root_password:-test1234}


echo "===========remove unused kernels in rescue system========="
for kver in $(ls /lib/modules/ -1 | grep -v "$(uname -r)"); do 
  apt purge --yes "linux-headers-$kver"
  apt purge --yes "linux-image-$kver"  
done


echo "======= installing zfs on rescue system =========="
echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

apt update
apt install --yes -t buster-backports zfs-dkms
modprobe zfs
zfs --version

echo "======= partitioning the disk =========="
DISK=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-0

wipefs --all $DISK
sgdisk -a1 -n1:24K:+1000K            -t1:EF02 $DISK # MBR area
sgdisk -n2:0:+512M                   -t2:BF01 $DISK # Boot pool
sgdisk -n3:0:0                       -t3:BF01 $DISK # Root pool

udevadm settle

echo "======= create zfs pools and datasets =========="
zpool create \
  -o ashift=12 -O canmount=off -O compression=lz4 -O devices=off -f \
  -O mountpoint=/boot -R /mnt bpool "${DISK}-part2"

zpool create -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/ -f -R /mnt rpool "${DISK}-part3"

zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian

zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/debian
zfs mount bpool/BOOT/debian

zfs create                                 rpool/home
zfs create -o mountpoint=/root             rpool/home/root
zfs create -o canmount=off                 rpool/var
zfs create -o canmount=off                 rpool/var/lib
zfs create                                 rpool/var/log
zfs create                                 rpool/var/spool

zfs create -o com.sun:auto-snapshot=false  rpool/var/cache
zfs create -o com.sun:auto-snapshot=false  rpool/var/tmp
chmod 1777 /mnt/var/tmp

zfs create                                 rpool/srv

zfs create -o canmount=off                 rpool/usr
zfs create                                 rpool/usr/local

zfs create                                 rpool/var/mail

zfs create -o com.sun:auto-snapshot=false  rpool/tmp
chmod 1777 /mnt/tmp

echo "======= setting up initial system backages =========="
debootstrap --arch=amd64 buster /mnt $v_deb_packages_repo

zfs set devices=off rpool

echo "======= setting up the network =========="

echo "$v_hostname" > /mnt/etc/hostname

cat > /mnt/etc/hosts <<CONF
127.0.1.1 terem terem
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
CONF

ip6addr_prefix=$(ip -6 a s | grep -E "inet6.+global" | sed -nE 's/.+inet6\s(([0-9a-z]{1,4}:){4,4}).+/\1/p')

mkdir -p /mnt/etc/network/

cat > "/mnt/etc/network/interfaces" <<CONF
auto lo
iface lo inet loopback
iface lo inet6 loopback

auto ens3
iface ens3 inet dhcp
    dns-nameservers 213.133.98.98 213.133.99.99 213.133.100.100

# control-alias ens3
iface ens3 inet6 static
    address ${ip6addr_prefix}:1/64
    gateway fe80::1
CONF

cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "======= preparing the jail for chroot =========="
for virtual_fs_dir in proc sys dev; do
  mount --rbind "/$virtual_fs_dir" "/mnt/$virtual_fs_dir"
done

echo "======= setting apt repos =========="
# Packages from the Hetzner Debian Mirror
cat > /mnt/etc/apt/sources.list <<CONF
deb [arch=i386,amd64] $v_deb_packages_repo buster main contrib non-free
deb [arch=i386,amd64] $v_deb_packages_repo buster-updates main contrib non-free
deb [arch=i386,amd64] $v_deb_packages_repo buster-backports main contrib non-free
deb [arch=i386,amd64] $v_deb_security_repo buster/updates main contrib non-free
CONF

### official Debian repo site
#cat > /mnt/etc/apt/sources.list <<CONF
#deb [arch=i386,amd64] http://deb.debian.org/debian  buster  main non-free contrib
#deb-src [arch=i386,amd64] http://deb.debian.org/debian  buster  main non-free contrib
#deb [arch=i386,amd64] http://deb.debian.org/debian  buster-updates  main non-free contrib
#deb-src [arch=i386,amd64] http://deb.debian.org/debian  buster-updates  main non-free contrib
#deb [arch=i386,amd64] http://deb.debian.org/debian  buster-backports  main non-free contrib
#deb-src [arch=i386,amd64] http://deb.debian.org/debian  buster-backports  main non-free contrib
#deb [arch=i386,amd64] http://security.debian.org  buster/updates  main contrib non-free
#deb-src [arch=i386,amd64] http://security.debian.org  buster/updates  main contrib non-free
#CONF

chroot_execute 'cat > /etc/apt/preferences.d/90_zfs <<APT
Package: libnvpair1linux libuutil1linux libzfs2linux libzpool2linux zfs-dkms zfs-initramfs zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=buster-backports
Pin-Priority: 990
APT'

chroot_execute "apt update"

echo "======= setting locale, console and language =========="
chroot_execute "apt install --yes -qq locales debconf-utils dialog apt-utils"
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen
sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' /mnt/etc/locale.gen
sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' /mnt/etc/locale.gen
sed -i 's/# de_AT.UTF-8/de_AT.UTF-8/' /mnt/etc/locale.gen
sed -i 's/# de_DE.UTF-8/de_DE.UTF-8/' /mnt/etc/locale.gen

#chroot_execute "locale-gen"
chroot_execute 'cat <<CONF | debconf-set-selections
locales locales/default_environment_locale      select  en_US.UTF-8
keyboard-configuration  keyboard-configuration/store_defaults_in_debconf_db     boolean true
keyboard-configuration  keyboard-configuration/variant  select  German
keyboard-configuration  keyboard-configuration/unsupported_layout       boolean true
keyboard-configuration  keyboard-configuration/modelcode        string  pc105
keyboard-configuration  keyboard-configuration/unsupported_config_layout        boolean true
keyboard-configuration  keyboard-configuration/layout   select  German
keyboard-configuration  keyboard-configuration/layoutcode       string  de
keyboard-configuration  keyboard-configuration/optionscode      string
keyboard-configuration  keyboard-configuration/toggle   select  No toggling
keyboard-configuration  keyboard-configuration/xkb-keymap       select  de
keyboard-configuration  keyboard-configuration/switch   select  No temporary switch
keyboard-configuration  keyboard-configuration/unsupported_config_options       boolean true
keyboard-configuration  keyboard-configuration/ctrl_alt_bksp    boolean false
keyboard-configuration  keyboard-configuration/variantcode      string
keyboard-configuration  keyboard-configuration/model    select  Generic 105-key PC (intl.)
keyboard-configuration  keyboard-configuration/altgr    select  The default for the keyboard layout
keyboard-configuration  keyboard-configuration/compose  select  No compose key
keyboard-configuration  keyboard-configuration/unsupported_options      boolean true
console-setup   console-setup/fontsize-fb47     select  8x16
console-setup   console-setup/store_defaults_in_debconf_db      boolean true
console-setup   console-setup/codeset47 select  # Latin1 and Latin5 - western Europe and Turkic languages
console-setup   console-setup/fontface47        select  Fixed
console-setup   console-setup/fontsize  string  8x16
console-setup   console-setup/charmap47 select  UTF-8
console-setup   console-setup/fontsize-text47   select  8x16
console-setup   console-setup/codesetcode       string  Lat15
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Vienna
CONF'

chroot_execute "dpkg-reconfigure locales -f noninteractive"
echo -e "LC_ALL=en_US.UTF-8\nLANG=en_US.UTF-8\n" >> /mnt/etc/environment
chroot_execute "apt install -qq --yes keyboard-configuration console-setup"
chroot_execute "dpkg-reconfigure keyboard-configuration -f noninteractive"
chroot_execute "dpkg-reconfigure console-setup -f noninteractive"
chroot_execute "setupcon"

chroot_execute "rm -f /etc/localtime /etc/timezone"
chroot_execute "dpkg-reconfigure tzdata -f noninteractive "

echo "======= installing latest kernel============="
chroot_execute "apt install --yes -t buster-backports linux-image-cloud-amd64 linux-headers-cloud-amd64"

echo "======= installing zfs packages =========="
chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
chroot_execute "apt install --yes zfs-initramfs zfs-dkms"

echo "======= installing OpenSSH and aux packages =========="
chroot_execute "apt install --yes openssh-server net-tools wget curl aptitude"

echo "======= setup OpenSSH  =========="
mkdir -p /mnt/root/.ssh/
cp /root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /mnt/etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' /mnt/etc/ssh/sshd_config
chroot_execute "rm /etc/ssh/ssh_host_*"
chroot_execute "dpkg-reconfigure openssh-server -f noninteractive"

echo "======= set root password =========="
chroot_execute "echo root:'"$v_root_password"' | chpasswd"

echo "======= setting up zfs services =========="
chroot_execute "cat > /etc/systemd/system/zfs-import-bpool.service <<UNIT
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c '[ -f /etc/zfs/zpool.cache ] && mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache || true'
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
ExecStartPost=/bin/sh -c '[ -f /etc/zfs/preboot_zpool.cache ] && mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache || true'

[Install]
WantedBy=zfs-import.target
UNIT"

chroot_execute "systemctl enable zfs-import-bpool.service"

chroot_execute "cp /usr/share/systemd/tmp.mount /etc/systemd/system/"
chroot_execute "systemctl enable tmp.mount"

echo "========setting up zfs module parameters========"
chroot_execute "echo options zfs zfs_arc_max=$v_zfs_arc_max >> /etc/modprobe.d/zfs.conf"

echo "======= setting up grub =========="
chroot_execute "echo 'grub-pc grub-pc/install_devices_empty   boolean true' | debconf-set-selections"
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes grub-pc"
chroot_execute "grub-install $DISK"

chroot_execute "sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=rpool/ROOT/debian\"|g'  /etc/default/grub"

chroot_execute "sed -i 's/quiet//g' /etc/default/grub"
chroot_execute "sed -i 's/splash//g' /etc/default/grub"
chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'   >> /etc/default/grub"

echo "=========set up dropbear=============="
#chroot_execute "apt remove --yes cryptsetup-initramfs"
chroot_execute "apt install --yes --no-install-recommends dropbear-initramfs"

cp /root/.ssh/authorized_keys /mnt/etc/dropbear-initramfs/authorized_keys

cp /mnt/etc/ssh/ssh_host_rsa_key /mnt/etc/ssh/ssh_host_rsa_key_temp
chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_rsa_key_temp"
chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key_temp /etc/dropbear-initramfs/dropbear_rsa_host_key"
rm -rf /mnt/etc/ssh/ssh_host_rsa_key_temp

cp /mnt/etc/ssh/ssh_host_ecdsa_key /mnt/etc/ssh/ssh_host_ecdsa_key_temp
chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_ecdsa_key_temp"
chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_ecdsa_key_temp /etc/dropbear-initramfs/dropbear_ecdsa_host_key"
chroot_execute "rm -rf /etc/ssh/ssh_host_ecdsa_key_temp"
rm -rf /mnt/etc/ssh/ssh_host_ecdsa_key_temp

echo "============setup root prompt============"
cat > /mnt/root/.bashrc <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF

echo "======= update initramfs =========="
chroot_execute "update-initramfs -u -k all"

echo "======= update grub =========="
chroot_execute "update-grub"

echo "======= setting up zed =========="
initial_load_debian_zed_cache

echo "======= setting mountpoints =========="
chroot_execute "zfs set mountpoint=legacy bpool/BOOT/debian"
chroot_execute "echo bpool/BOOT/debian /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0 > /etc/fstab"

chroot_execute "zfs set mountpoint=legacy rpool/var/log"
chroot_execute "echo rpool/var/log /var/log zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy rpool/var/spool"
chroot_execute "echo rpool/var/spool /var/spool zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy rpool/var/tmp"
chroot_execute "echo rpool/var/tmp /var/tmp zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy rpool/tmp"
chroot_execute "echo rpool/tmp /tmp zfs nodev,relatime 0 0 >> /etc/fstab"

echo "======= unmounting filesystems and zfs pools =========="
unmount_and_export_fs

echo "======== setup complete, rebooting ==============="
reboot