#!/bin/bash
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

fullname=$(dialog --stdout --inputbox "Enter full name" 0 0) || exit 1
clear
: ${fullname:?"name cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

### Set timezonme ###
timedatectl set-timezone Europe/Vienna
timedatectl set-ntp true

### Create partitions ###
parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 513MiB \
  set 1 boot on \
  mkpart primary ext4 513MiB 100%

part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

## Format partitions ###
wipefs "${part_boot}"
wipefs "${part_root}"

mkfs.fat -F32 "${part_boot}"
mkfs.ext4 "${part_root}"

### Mount partitions ###
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

### Edit mirrorlist ##
mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak && touch /etc/pacman.d/mirrorlist

grep -E -A 1 ".*Austria.*$" /etc/pacman.d/mirrorlist.bak | sed '/--/d' >> /etc/pacman.d/mirrorlist
grep -E -A 1 ".*Germany.*$" /etc/pacman.d/mirrorlist.bak | sed '/--/d' >> /etc/pacman.d/mirrorlist

rm /etc/pacman.d/mirrorlist.bak

### Install and configure the system ###
pacstrap /mnt base base-devel linux linux-firmware amd-ucode zsh git grub efibootmgr os-prober ntfs-3g gnome gdm nvidia firefox firefox-i18n-de

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mtn systemctl enable dhcpcd

echo "${hostname}" > /mnt/etc/hostname

echo KEYMAP=de-latin1 > /mnt/etc/vconsole.conf

echo 'LANG="de_AT.UTF-8"' >> /mnt/etc/locale.conf
echo 'LANG="en_US.UTF-8"' >> /mnt/etc/locale.conf
arch-chroot /mnt locale-gen

arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime
arch-chroot /mnt hwclock --systohc

### Initramfs ###
arch-chroot /mnt mkinitcpio -p linux

### Install GRUB ###
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

### Create user ###
arch-chroot /mnt useradd -m -g users -c '"$fullname"' -s /bin/zsh "$user"

### Change passwords ###
echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

### Add user to sudoers ###
arch-chroot /mnt sed -i '/%wheel ALL=(ALL) ALL/s/^#//g' sudoers
arch-chroot /mnt gpasswd -a "$user" wheel

### Install yay ###
arch-chroot /mnt git clone https://aur.archlinux.org/yay.git
arch-chroot /mnt cd yay && makepkg -si
arch-chroot /mnt cd .. && rm .rf yay