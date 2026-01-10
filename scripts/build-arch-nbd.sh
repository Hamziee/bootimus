#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTENV_DIR="$PROJECT_ROOT/bootloaders/bootenv"
WORK_DIR="/tmp/arch-nbd-build"

echo "=== Building Arch Linux NBD Boot Environment ==="

echo "Checking for required packages..."
if ! command -v nbd-client &> /dev/null; then
    echo "ERROR: nbd-client not found. Install with: sudo pacman -S nbd"
    exit 1
fi
if ! command -v kexec &> /dev/null; then
    echo "ERROR: kexec not found. Install with: sudo pacman -S kexec-tools"
    exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "[1/5] Creating custom initramfs build directory..."
mkdir -p "$WORK_DIR/build"
cd "$WORK_DIR/build"

echo "[2/5] Creating custom init hook for NBD..."
mkdir -p hooks install

cat > hooks/bootimus-nbd << 'EOFHOOK'
#!/usr/bin/ash

run_hook() {
    msg ":: Bootimus NBD Boot"

    ISO_NAME=""
    SERVER_IP=""
    NBD_PORT="10809"

    for param in $(cat /proc/cmdline); do
        case $param in
            iso=*) ISO_NAME="${param#iso=}" ;;
            server=*) SERVER_IP="${param#server=}" ;;
            nbdport=*) NBD_PORT="${param#nbdport=}" ;;
        esac
    done

    if [ -z "$ISO_NAME" ] || [ -z "$SERVER_IP" ]; then
        err "Missing iso= or server= kernel parameters"
        launch_interactive_shell
    fi

    msg "ISO: $ISO_NAME"
    msg "Server: $SERVER_IP:$NBD_PORT"

    msg "Configuring network..."
    ip link set eth0 up
    if command -v dhcpcd &> /dev/null; then
        dhcpcd -1 eth0
    elif command -v dhclient &> /dev/null; then
        dhclient -1 eth0
    else
        ip addr add 192.168.1.100/24 dev eth0
    fi

    msg "Loading NBD module..."
    modprobe nbd max_part=8

    msg "Connecting to NBD server..."
    nbd-client $SERVER_IP $NBD_PORT /dev/nbd0 -N "$ISO_NAME" -persist

    if [ $? -ne 0 ]; then
        err "Failed to connect to NBD server"
        launch_interactive_shell
    fi

    msg "Mounting ISO..."
    mkdir -p /mnt/iso
    mount -t iso9660 -o ro /dev/nbd0 /mnt/iso

    if [ $? -ne 0 ]; then
        err "Failed to mount ISO"
        nbd-client -d /dev/nbd0
        launch_interactive_shell
    fi

    msg "ISO mounted, detecting bootable files..."

    KERNEL=""
    INITRD=""
    APPEND="boot=live ip=dhcp"

    if [ -f /mnt/iso/casper/vmlinuz ]; then
        KERNEL="/mnt/iso/casper/vmlinuz"
        INITRD="/mnt/iso/casper/initrd"
        msg "Found Ubuntu Live"
    elif [ -f /mnt/iso/live/vmlinuz ]; then
        KERNEL="/mnt/iso/live/vmlinuz"
        INITRD="/mnt/iso/live/initrd.img"
        msg "Found Debian Live"
    elif [ -f /mnt/iso/arch/boot/x86_64/vmlinuz-linux ]; then
        KERNEL="/mnt/iso/arch/boot/x86_64/vmlinuz-linux"
        INITRD="/mnt/iso/arch/boot/x86_64/initramfs-linux.img"
        APPEND="archisobasedir=arch archisolabel=ARCH ip=dhcp"
        msg "Found Arch Linux"
    fi

    if [ -n "$KERNEL" ] && [ -f "$KERNEL" ]; then
        msg "Copying kernel and initrd to tmpfs..."
        cp "$KERNEL" /tmp/vmlinuz
        [ -f "$INITRD" ] && cp "$INITRD" /tmp/initrd

        msg "Executing kexec..."
        if [ -f /tmp/initrd ]; then
            kexec -l /tmp/vmlinuz --initrd=/tmp/initrd --append="$APPEND"
        else
            kexec -l /tmp/vmlinuz --append="$APPEND"
        fi

        umount /mnt/iso 2>/dev/null || true
        kexec -e
    fi

    err "Could not detect bootable files in ISO"
    msg "NBD device: /dev/nbd0"
    msg "ISO mounted at: /mnt/iso"
    ls -la /mnt/iso
    launch_interactive_shell
}
EOFHOOK

cat > install/bootimus-nbd << 'EOFINSTALL'
#!/bin/bash

build() {
    add_module "nbd"
    add_module "loop"
    add_binary "nbd-client"
    add_binary "kexec"
    add_binary "ip"
    if command -v dhcpcd &> /dev/null; then
        add_binary "dhcpcd"
    elif command -v dhclient &> /dev/null; then
        add_binary "dhclient"
    fi
    add_runscript
}

help() {
    cat <<HELPEOF
This hook provides NBD-based ISO mounting for Bootimus.
HELPEOF
}
EOFINSTALL

chmod +x hooks/bootimus-nbd install/bootimus-nbd

echo "[3/5] Installing hooks to system..."
sudo cp hooks/bootimus-nbd /etc/initcpio/hooks/
sudo cp install/bootimus-nbd /etc/initcpio/install/

echo "[4/5] Creating mkinitcpio config..."
cat > mkinitcpio.conf << 'EOFCONF'
MODULES=(nbd loop e1000 e1000e r8169 igb ixgbe)
BINARIES=(nbd-client kexec)
FILES=()
HOOKS=(base udev autodetect modconf block filesystems bootimus-nbd)
COMPRESSION="gzip"
EOFCONF

echo "[5/5] Building initramfs with mkinitcpio..."
sudo mkinitcpio \
    -c mkinitcpio.conf \
    -k $(uname -r) \
    -g initramfs-bootimus.img

echo "[6/6] Copying files to bootenv directory..."
if [ -f "/boot/vmlinuz-linux-lts" ]; then
    KERNEL_PATH="/boot/vmlinuz-linux-lts"
elif [ -f "/boot/vmlinuz-linux" ]; then
    KERNEL_PATH="/boot/vmlinuz-linux"
else
    echo "ERROR: No Arch kernel found in /boot"
    exit 1
fi
echo "Using kernel: $KERNEL_PATH"

sudo cp "$WORK_DIR/build/initramfs-bootimus.img" "$BOOTENV_DIR/initramfs-bootimus"
sudo cp "$KERNEL_PATH" "$BOOTENV_DIR/vmlinuz-lts"
sudo chown $(whoami):$(whoami) "$BOOTENV_DIR/initramfs-bootimus"
sudo chown $(whoami):$(whoami) "$BOOTENV_DIR/vmlinuz-lts"

echo ""
echo "=== Build Complete ==="
ls -lh "$BOOTENV_DIR/vmlinuz-lts" "$BOOTENV_DIR/initramfs-bootimus"
echo ""
echo "Arch Linux kernel and initramfs with NBD support created!"
echo ""
echo "Next steps:"
echo "  1. Rebuild bootimus: go build -o bootimus"
echo "  2. Deploy and test"
