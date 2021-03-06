#!/bin/bash
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

### Variables ###
locale="de_AT"
keymap="de-latin1"
timezone="Europe/Vienna"
mirror_country="Austria"

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname:" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter username:" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

fullname=$(dialog --stdout --inputbox "Enter full name:" 0 0) || exit 1
clear
: ${fullname:?"name cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter password:" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter password again:" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk:" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

### Set timezonme ###
timedatectl set-timezone $timezone
timedatectl set-ntp true

### Create partitions ###
parted --script "${device}" -- mklabel gpt \
    mkpart ESP fat32 1Mib 513MiB \
    set 1 boot on \
    mkpart primary ext4 513MiB 100%

part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

### Format partitions ###
wipefs "${part_boot}"
wipefs "${part_root}"

mkfs.fat -F32 "${part_boot}"
mkfs.ext4 "${part_root}"

### Mount partitions ###
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

### Create mirrorlist ##
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
grep -E -A 1 ".*Austria.*$" /etc/pacman.d/mirrorlist.bak | sed '/--/d' > /etc/pacman.d/mirrorlist

### Install and configure the system ###
packages=()

cmd=(dialog --separate-output --checklist "Select options:" 0 0 0)
options=(
    01 "base linux linux-firmware" on
    02 "base-devel" on
    03 "dhcpcd" on
    04 "grub efibootmgr" on
    05 "os-prober ntfs-3g" on
    06 "amd-ucode" on
    07 "nvidia" on
    08 "gnome gdm" on
    09 "firefox" on
    10 "zsh" on
    11 "git" on)

choices=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
clear
for choice in $choices
do
    case $choice in
        01)
            packages+=("base linux linux-firmware")
            ;;
        02)
            packages+=("base-devel")
            ;;
        03)
            packages+=("dhcpcd")
            ;;
        04)
            packages+=("grub efibootmgr")
            ;;
        05)
            packages+=("os-prober ntfs-3g")
            ;;
        06)
            packages+=("amd-ucode")
            ;;
        07)
            packages+=("nvidia")
            ;;
        08)
            packages+=("gnome gdm")
            ;;
        09)
            packages+=("firefox firefox-i18n-de")
            ;;
        10)
            packages+=("zsh")
            ;;
        11)
            packages+=("git")
            ;;
    esac
done

pacstrap /mnt ${packages[@]}

genfstab -U /mnt >> /mnt/etc/fstab

### Enable services ###
for package in $packages
do
    case $package in
        dhcpcd)
            arch-chroot /mnt systemctl enable dhcpcd.service
            ;;
        gdm)
            arch-chroot /mnt systemctl enable gdm.service
            ;;
    esac
done

echo $hostname > /mnt/etc/hostname

echo KEYMAP=$keymap > /mnt/etc/vconsole.conf

echo "LANG=\"$locale.UTF-8\"" >> /mnt/etc/locale.conf
arch-chroot /mnt locale-gen

arch-chroot /mnt ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
arch-chroot /mnt hwclock --systohc

### Initramfs ###
arch-chroot /mnt mkinitcpio -p linux

### Install GRUB ###
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sed -i "s/\<quiet\>/& nvidia-drm.nomodeset=1/" /mnt/etc/default/grub
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

### Create user ###
arch-chroot /mnt useradd -m -g users -c "$fullname" -s /bin/zsh "$user"

### Change passwords ###
echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

### Add user to sudoers ###
sed -i '/%wheel ALL=(ALL) ALL/s/^# //g' /mnt/etc/sudoers
arch-chroot /mnt gpasswd -a "$user" wheel