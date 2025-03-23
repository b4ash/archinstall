#!/usr/bin/lua
--[[
======================= CAUTION /\ DANGER =======================
The use of this script is only and exclusively for my laptop and my preferences.
* ssd:sda
* locale:en_US
* systemd-boot
* luks2:cryptroot
* secure boot
* tpm2
* shell:fish
* opendoas
* intel-ucode

Before execute this script do:
# Modify variables
# Verify the boot mode
ls /sys/firmware/efi/efivars
# Check internet connection
ping -c3 archlinux.org
# Delete efibootmgr entries
efibootmgr
efibootmgr -b # -B
# Remove a key enrolled (tpm2)
systemd-cryptenroll /dev/sda --wipe-slot=tpm2
# Wipe LUKS header
cryptsetup erase /dev/sda2
wipefs -a /dev/sda
# Defrag ssd
fstrim --all --minimum 1MiB --verbose
# Modify fstab - note 04
Replace `discard=async` with `nodiscard` or add it.
# Edit /etc/makepkg.conf to work with doas - note 09

Run
1- chmod +x install.lua
2- lua install.lua
======================= CAUTION /\ DANGER / =======================
--]]

local function run(cmd)
  print('[Running] ' .. cmd)
  os.execute(cmd)
end

-- Variables
local file_path, file, handle, output, uuid
local pass_crypt = 'crypt_password'
local timezone = 'America/Buenos_Aires'
local pass_root = 'root_password'
local user_name = 'user_name'
local pass_user = 'user_password'
local pkgs_base = 'base linux linux-firmware btrfs-progs intel-ucode neovim opendoas fish networkmanager'
local myhostname = 'hostname'
local btrfs_subvols = {'@', '@home', '@snapshots', '@var_cache', '@var_log', '@var_tmp', '@var_lib_flatpak', '@var_lib_libvirt'}

-- 00. Change font size
run('setfont ter-132b')

-- Clock sync
run('timedatectl set-ntp true')

-- 01. Partition the disks
run('sgdisk --zap-all /dev/sda')
run('sgdisk --clear --set-alignment=2048 /dev/sda')
run('sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFIBOOT" /dev/sda')
run('sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"ROOT" /dev/sda')

-- 02. Encryption
run(string.format('echo -e "YES\n%s\n%s" | cryptsetup --verbose --type luks2 --cipher aes-xts-plain64 --hash sha512 --iter-time 5000 --key-size 512 --pbkdf argon2id --use-urandom --verify-passphrase luksFormat /dev/sda2', pass_crypt, pass_crypt))
run(string.format('echo "%s" | cryptsetup --allow-discards --persistent open /dev/sda2 cryptroot', pass_crypt))

-- 03. Format the partitions
run('mkfs.vfat -F32 -n "EFIBOOT" /dev/sda1')
run('mkfs.btrfs --label ROOT /dev/mapper/cryptroot')

-- 04. Mount the file systems
run('mount --types btrfs /dev/mapper/cryptroot /mnt')
-- Create directories
run('mkdir -p /mnt/{boot,home,.snapshots,var/{cache,log,tmp,lib/{flatpak,libvirt}}}')
-- Create subvolumes
for _, subvol in ipairs(btrfs_subvols) do
  run("btrfs subvolume create /mnt/" .. subvol)
end
-- Umount /mnt
run('umount /mnt')
-- Mount subvolumes
for _, subvol in ipairs(btrfs_subvols) do
  local mount_point = subvol == '@' and '/mnt' or '/mnt/' .. subvol:sub(2)
  run('mount --types btrfs -o subvol=' .. subvol .. ',defaults,ssd,nodiscard,compress-force=zstd:2,noatime,space_cache=v2,autodefrag /dev/mapper/cryptroot ' .. mount_point)
end
-- Mount EFI partition
run('mount -t vfat /dev/sda1 /mnt/boot')

-- 05. Installation
run('pacman-key --init')
run('pacman-key --populate')
run('pacstrap -K /mnt ' .. pkgs_base)
-- Gen fstab
run('genfstab -U /mnt >> /mnt/etc/fstab')
-- Chroot
run('arch-chroot /mnt')
-- Time zone
run('ln -sf /usr/share/zoneinfo/' .. timezone .. ' /etc/localtime')
run('hwclock --systohc')
-- Localization
file_path = '/etc/locale.gen'
file = io.open(file_path, 'r')
if not file then
  error('Can not open file: ' .. file_path)
end
local content = file:read('*a')
file:close()
local new_content = content:gsub('#(en_US%.UTF%-8 UTF%-8)', '%1')
file = io.open(file_path, 'w')
if not file then
  error('Can not write on file: ' .. file_path)
end
file:write(new_content)
file:close()
print('Line uncommented correctly.')
run('locale-gen')
-- Create locale.conf
file_path = '/etc/locale.conf'
file = io.open(file_path, 'w')
if file then
  file:write('LANG=en_US.UTF-8\n')
  file:close()
  print('File created successfully in ' .. file_path)
else
  print('Error: Could not create file in ' .. file_path)
end
-- Keyboard layout
file_path = '/etc/vconsole.conf'
file = io.open(file_path, 'w')
if file then
  file:write('KEYMAP=us\n')
  file:close()
  print('File created successfully in ' .. file_path)
else
  print('Error: Could not create file in ' .. file_path)
end
-- Network config
file_path = '/etc/hosts'
file = io.open(file_path, 'a')
if file then
  file:write('127.0.0.1\tlocalhost\n')
  file:write('::1\t\tlocalhost\n')
  file:write('127.0.1.1\t' .. myhostname .. '.localdomain\t' .. myhostname .. '\n')
  file:close()
  print('File created successfully in ' .. file_path)
else
  print('Error: Could not create file in ' .. file_path)
end
-- Initramfs


run('mkinitcpio -p linux')





-- Root pass
run(string.format('echo -e "%s\n%s" | passwd', pass_root, pass_root))

-- 06. Boot loader
run('bootctl --path=/boot install')
file_path = '/boot/loader/loader.conf'
file = io.open(file_path, 'w')
if file then
  file:write('default arch*\n')
  file:write('timeout 4\n')
  file:write('console-mode auto\n')
  file:write('editor no\n')
  file:close()
  print('File created successfully in ' .. file_path)
else
  print('Error: Could not create file in ' .. file_path)
end

handle = io.popen('blkid -s UUID -o value /dev/sda2')
if handle then
  uuid = handle:read("*a"):gsub("\n", "")
  handle:close()
  print('UUID successfully copied')
else
  print('Error: Could not copy UUID')
end
file_path = '/boot/loader/entries/arch.conf'
file = io.open(file_path, 'w')
if file then
  file:write('title Arch Linux\n')
  file:write('linux /vmlinuz-linux\n')
  file:write('initrd /intel-ucode.img\n')
  file:write('initrd /initramfs-linux.img\n')
  file:write('options rd.luks.name=' .. uuid .. '=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=/@ rw rootfstype=btrfs i915.enable_guc=2 i915.enable_psr=0 i915.enable_fbc=1\n')
  file:close()
  print('File created successfully in ' .. file_path)
else
  print('Error: Could not create file in ' .. file_path)
end

-- 08. Create user
run('useradd -m -g users -G wheel -s /usr/bin/fish ' .. user_name)
run(string.format('echo -e "%s\n%s" | passwd %s', pass_user, pass_user, user_name))

-- 09. opendoas
file_path = '/etc/doas.conf'
file = io.open(file_path, 'w')
if file then
  file:write('permit setenv {PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin} :wheel\n')
  file:close()
  run('chown -c root:root /etc/doas.conf')
  run('chmod -c 0400 /etc/doas.conf')
  print('File created successfully in ' .. file_path)
  handle = io.popen('if doas -C /etc/doas.conf; then echo "config ok"; else echo "config error"; fi')
  if handle then
    output = handle:read('*a')
    handle:close()
    if output:match("config ok") then
      print('doas: config OK')
    else
      print('doas: config ERROR')
    end
  else
    print('Error: Could not handle command output')
  end
else
  print('Error: Could not create file in ' .. file_path)
end

-- Finish - modify mkinitcpio.conf
print('[✅] Base installation completed\n')
print('Edit mkinitcpio.conf\n')
print('Starting NetworkManager service\nsystemctl enable NetworkManager.service')
print('Turn off the computer and disconnect the pendrive\n')
print('Continue with note #11 obsidian')
-- 10. Reboot
-- run('exit')
-- run('umount -R /mnt/')
-- run('poweroff')
