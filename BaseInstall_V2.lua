#!/usr/bin/lua

local log_file = '/tmp/install_log.txt'

-- Función para validar contraseñas
local function validate_password(pass, name)
  if not pass or pass == "" then
    error(name .. " no puede estar vacía.")
  elseif #pass < 8 then
    error(name .. " debe tener al menos 8 caracteres.")
  end
  return true
end

-- Función para validar nombre de usuario
local function validate_username(username)
  if not username or username == "" then
    error("El nombre de usuario no puede estar vacío.")
  elseif not username:match("^[a-zA-Z0-9_]+$") then
    error("El nombre de usuario solo puede contener letras, números y guiones bajos.")
  elseif #username < 3 then
    error("El nombre de usuario debe tener al menos 3 caracteres.")
  end
  return true
end

-- Función para ejecutar comandos y registrar salida
local function run(cmd, check_error)
  print('[Ejecutando] ' .. cmd)
  local full_cmd = cmd .. ' >> ' .. log_file .. ' 2>&1'
  local success = os.execute(full_cmd)
  if check_error and not success then
    error('Error ejecutando: ' .. cmd .. '. Revisa ' .. log_file .. ' para más detalles.')
  end
  return success
end

-- Inicializar el archivo de log
os.execute('echo "Inicio de la instalación: $(date)" > ' .. log_file)

-- Solicitar y validar entradas
io.write('Ingrese la contraseña para LUKS: ')
local pass_crypt = io.read()
validate_password(pass_crypt, "Contraseña de LUKS")

io.write('Ingrese la contraseña para root: ')
local pass_root = io.read()
validate_password(pass_root, "Contraseña de root")

io.write('Ingrese el nombre de usuario: ')
local user_name = io.read()
validate_username(user_name)

io.write('Ingrese la contraseña para ' .. user_name .. ': ')
local pass_user = io.read()
validate_password(pass_user, "Contraseña de usuario")

-- Variables
local timezone = 'America/Buenos_Aires'
local myhostname = 'hostname'
local pkgs_base = 'base linux linux-firmware btrfs-progs intel-ucode neovim opendoas fish networkmanager'
local btrfs_subvols = {'@', '@home', '@snapshots', '@var_cache', '@var_log', '@var_tmp', '@var_lib_flatpak', '@var_lib_libvirt'}

-- 00. Cambiar tamaño de fuente
run('setfont ter-132b', true)

-- Sincronizar reloj
run('timedatectl set-ntp true', true)

-- 01. Particionar discos
run('sgdisk --zap-all /dev/sda', true)
run('sgdisk --clear --set-alignment=2048 /dev/sda', true)
run('sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFIBOOT" /dev/sda', true)
run('sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"ROOT" /dev/sda', true)

-- 02. Cifrado
run(string.format('echo -e "YES\n%s\n%s" | cryptsetup --verbose --type luks2 --cipher aes-xts-plain64 --hash sha512 --iter-time 5000 --key-size 512 --pbkdf argon2id --use-urandom --verify-passphrase luksFormat /dev/sda2', pass_crypt, pass_crypt), true)
run(string.format('echo "%s" | cryptsetup --allow-discards --persistent open /dev/sda2 cryptroot', pass_crypt), true)

-- 03. Formatear particiones
run('mkfs.vfat -F32 -n "EFIBOOT" /dev/sda1', true)
run('mkfs.btrfs --label ROOT /dev/mapper/cryptroot', true)

-- 04. Montar sistemas de archivos
run('mount --types btrfs /dev/mapper/cryptroot /mnt', true)
run('mkdir -p /mnt/{boot,home,.snapshots,var/{cache,log,tmp,lib/{flatpak,libvirt}}}', true)
for _, subvol in ipairs(btrfs_subvols) do
  run('btrfs subvolume create /mnt/' .. subvol, true)
end
run('umount /mnt', true)
for _, subvol in ipairs(btrfs_subvols) do
  local mount_point = subvol == '@' and '/mnt' or '/mnt/' .. subvol:sub(2)
  run('mount --types btrfs -o subvol=' .. subvol .. ',defaults,ssd,nodiscard,compress-force=zstd:2,noatime,space_cache=v2,autodefrag /dev/mapper/cryptroot ' .. mount_point, true)
end
run('mount -t vfat /dev/sda1 /mnt/boot', true)

-- 05. Instalación base
run('pacman-key --init', true)
run('pacman-key --populate', true)
run('pacstrap -K /mnt ' .. pkgs_base, true)
run('genfstab -U /mnt >> /mnt/etc/fstab', true)

-- Entrar en chroot y ejecutar configuraciones
run([[arch-chroot /mnt /bin/bash -c "
  ln -sf /usr/share/zoneinfo/]] .. timezone .. [[ /etc/localtime &&
  hwclock --systohc &&
  sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen &&
  locale-gen &&
  echo 'LANG=en_US.UTF-8' > /etc/locale.conf &&
  echo 'KEYMAP=us' > /etc/vconsole.conf &&
  echo -e '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t]] .. myhostname .. [[.localdomain\t]] .. myhostname .. [[' > /etc/hosts &&
  echo -e 'HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)' > /etc/mkinitcpio.conf &&
  mkinitcpio -P &&
  echo -e ']] .. pass_root .. [[\n]] .. pass_root .. [[' | passwd
"]], true)

-- 06. Configurar el cargador de arranque
run('arch-chroot /mnt bootctl --path=/boot install', true)
local file = io.open('/mnt/boot/loader/loader.conf', 'w')
if file then
  file:write('default arch*\ntimeout 4\nconsole-mode auto\neditor no\n')
  file:close()
end
local handle = io.popen('blkid -s UUID -o value /dev/sda2')
local uuid = handle and handle:read('*a'):gsub('\n', '') or error('No se pudo obtener el UUID')
handle:close()
file = io.open('/mnt/boot/loader/entries/arch.conf', 'w')
if file then
  file:write('title Arch Linux\nlinux /vmlinuz-linux\ninitrd /intel-ucode.img\ninitrd /initramfs-linux.img\n')
  file:write('options rd.luks.name=' .. uuid .. '=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=/@ rw rootfstype=btrfs i915.enable_guc=2 i915.enable_psr=0 i915.enable_fbc=1\n')
  file:close()
end

-- 08. Crear usuario
run('arch-chroot /mnt useradd -m -g users -G wheel -s /usr/bin/fish ' .. user_name, true)
run('arch-chroot /mnt bash -c "echo -e \'' .. pass_user .. '\\n' .. pass_user .. '\' | passwd ' .. user_name .. '"', true)

-- 09. Configurar opendoas
file = io.open('/mnt/etc/doas.conf', 'w')
if file then
  file:write('permit setenv {PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin} :wheel\n')
  file:close()
  run('chown -c root:root /mnt/etc/doas.conf', true)
  run('chmod -c 0400 /mnt/etc/doas.conf', true)
end

-- 10. Finalizar
run('arch-chroot /mnt systemctl enable NetworkManager.service', true)
print('[✅] Instalación completada. Revisa ' .. log_file .. ' para detalles. Desmonta con "umount -R /mnt" y reinicia.')
