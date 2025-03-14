#!/bin/bash

# Variables
pass_crypt='crypt_password'
timezone='America/Buenos_Aires'
pass_root='root_password'
user_name='user_name'
pass_user='user_password'
pkgs_base='base linux linux-firmware btrfs-progs intel-ucode neovim opendoas fish networkmanager'
myhostname='hostname'
btrfs_subvols=('@' '@home' '@snapshots' '@var_cache' '@var_log' '@var_tmp' '@var_lib_flatpak' '@var_lib_libvirt')

# Función para ejecutar comandos
run() {
  echo "[Running] $1"
  eval "$1"
  if [ $? -ne 0 ]; then
    echo "Error: Command failed"
    exit 1
  fi
}

# 00. Change font size
run 'setfont ter-132b'

# Clock sync
run 'timedatectl set-ntp true'

# 01. Partition the disks
run 'sgdisk --zap-all /dev/sda'
run 'sgdisk --clear --set-alignment=2048 /dev/sda'
run 'sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFIBOOT" /dev/sda'
run 'sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"ROOT" /dev/sda'

# 02. Encryption
run 'echo -e "YES\n$pass_crypt\n$pass_crypt" | cryptsetup --verbose --type luks2 --cipher aes-xts-plain64 --hash sha512 --iter-time 5000 --key-size 512 --pbkdf argon2id --use-urandom --verify-passphrase luksFormat /dev/sda2'
run "echo $pass_crypt | cryptsetup --allow-discards --persistent open /dev/sda2 cryptroot"

# 03. Format the partitions
run 'mkfs.vfat -F32 -n "EFIBOOT" /dev/sda1'
run 'mkfs.btrfs --label ROOT /dev/mapper/cryptroot'

# 04. Mount the file systems
run 'mount --types btrfs /dev/mapper/cryptroot /mnt'
run 'mkdir -p /mnt/{boot,home,.snapshots,var/{cache,log,tmp,lib/{flatpak,libvirt}}}'
for subvol in "${btrfs_subvols[@]}"; do
  run "btrfs subvolume create /mnt/$subvol"
done
run 'umount /mnt'
for subvol in "${btrfs_subvols[@]}"; do
  mount_point=${subvol == '@' ? '/mnt' : "/mnt/${subvol:1}"}
  run "mount --types btrfs -o subvol=$subvol,defaults,ssd,nodiscard,compress-force=zstd:2,noatime,space_cache=v2,autodefrag /dev/mapper/cryptroot $mount_point"
done
run 'mount -t vfat /dev/sda1 /mnt/boot'

# 05. Installation
run 'pacman-key --init'
run 'pacman-key --populate'
run "pacstrap -K /mnt $pkgs_base"
run 'genfstab -U /mnt >> /mnt/etc/fstab'
run 'arch-chroot /mnt'
run "ln -sf /usr/share/zoneinfo/$timezone /etc/localtime"
run 'hwclock --systohc'
run 'sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen'
run 'locale-gen'
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us' > /etc/vconsole.conf
echo -e "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t$myhostname.localdomain\t$myhostname" >> /etc/hosts
run 'mkinitcpio -p linux'
run "echo -e "$pass_root\n$pass_root" | passwd"

# 06. Boot loader
run 'bootctl --path=/boot install'
echo -e "default arch*\ntimeout 4\nconsole-mode auto\neditor no" > /boot/loader/loader.conf
uuid=$(blkid -s UUID -o value /dev/sda2)
echo -e "title Arch Linux\nlinux /vmlinuz-linux\ninitrd /intel-ucode.img\ninitrd /initramfs-linux.img\noptions rd.luks.name=$uuid=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=/@ rw rootfstype=btrfs i915.enable_guc=2 i915.enable_psr=0 i915.enable_fbc=1" > /boot/loader/entries/arch.conf

# 08. Create user
run "useradd -m -g users -G wheel -s /usr/bin/fish $user_name"
run "echo -e "$pass_user\n$pass_user" | passwd $user_name"

# 09. opendoas
echo 'permit setenv {PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin} :wheel' > /etc/doas.conf
run 'chown -c root:root /etc/doas.conf'
run 'chmod -c 0400 /etc/doas.conf'
if doas -C /etc/doas.conf; then
  echo 'doas: config OK'
else
  echo 'doas: config ERROR'
fi

# Finish
echo '[✅] Base installation completed'
echo 'Edit mkinitcpio.conf'
echo 'Starting NetworkManager service\nsystemctl enable NetworkManager.service'
echo 'Turn off the computer and disconnect the pendrive'
echo 'Continue with note #11 obsidian'
