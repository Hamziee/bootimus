#!/bin/bash
set -e

WORK_DIR="/tmp/alpine-nbd-build"
BOOTENV_DIR="bootloaders/bootenv"
ALPINE_VERSION="3.19"

echo "=== Building Custom Alpine NBD Boot Environment ==="

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "[1/6] Setting up Alpine chroot environment..."
wget -q "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"
mkdir -p rootfs
tar -xzf alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz -C rootfs

echo "[2/6] Installing required packages in chroot..."
cat > rootfs/build-initramfs.sh << 'EOFCHROOT'
#!/bin/sh
set -e

apk add --no-cache \
    alpine-base \
    busybox \
    nbd-client \
    e2fsprogs \
    kmod \
    util-linux \
    alpine-conf \
    mkinitfs

echo "Packages installed:"
apk info | grep -E "(nbd|busybox|kmod)"
EOFCHROOT

chmod +x rootfs/build-initramfs.sh
sudo chroot rootfs /build-initramfs.sh

echo "[3/6] Creating custom init script..."
mkdir -p rootfs/etc/bootimus

cat > rootfs/etc/bootimus/nbd-boot.sh << 'EOFINIT'
#!/bin/sh

echo "=== Bootimus NBD Boot ==="

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
    echo "ERROR: Missing iso= or server= parameters"
    /bin/sh
    exit 1
fi

echo "ISO: $ISO_NAME"
echo "Server: $SERVER_IP:$NBD_PORT"

echo "Configuring network..."
ip link set eth0 up
udhcpc -i eth0 -q -n -t 5

echo "Loading NBD module..."
modprobe nbd max_part=8

echo "Connecting to NBD server..."
nbd-client $SERVER_IP $NBD_PORT /dev/nbd0 -N "$ISO_NAME" -persist

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to connect to NBD server"
    /bin/sh
    exit 1
fi

echo "Mounting ISO..."
mkdir -p /mnt/iso
mount -t iso9660 -o ro /dev/nbd0 /mnt/iso

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to mount ISO"
    nbd-client -d /dev/nbd0
    /bin/sh
    exit 1
fi

echo "ISO mounted successfully!"
echo "Detecting bootable files..."

KERNEL=""
INITRD=""

if [ -f /mnt/iso/casper/vmlinuz ]; then
    KERNEL="/mnt/iso/casper/vmlinuz"
    INITRD="/mnt/iso/casper/initrd"
    echo "Found Ubuntu Live: $KERNEL"
elif [ -f /mnt/iso/live/vmlinuz ]; then
    KERNEL="/mnt/iso/live/vmlinuz"
    INITRD="/mnt/iso/live/initrd.img"
    echo "Found Debian Live: $KERNEL"
elif [ -f /mnt/iso/arch/boot/x86_64/vmlinuz-linux ]; then
    KERNEL="/mnt/iso/arch/boot/x86_64/vmlinuz-linux"
    INITRD="/mnt/iso/arch/boot/x86_64/initramfs-linux.img"
    echo "Found Arch Linux: $KERNEL"
fi

if [ -n "$KERNEL" ] && [ -f "$KERNEL" ]; then
    echo "Copying kernel and initrd..."
    cp "$KERNEL" /tmp/vmlinuz
    if [ -f "$INITRD" ]; then
        cp "$INITRD" /tmp/initrd
    fi

    echo "Booting via kexec..."
    if [ -f /tmp/initrd ]; then
        kexec -l /tmp/vmlinuz --initrd=/tmp/initrd --append="boot=live ip=dhcp"
    else
        kexec -l /tmp/vmlinuz --append="boot=live ip=dhcp"
    fi

    umount /mnt/iso 2>/dev/null || true
    kexec -e
fi

echo "WARNING: Could not detect bootable files"
echo "NBD device is available at /dev/nbd0"
echo "ISO is mounted at /mnt/iso"
ls -la /mnt/iso
/bin/sh
EOFINIT

chmod +x rootfs/etc/bootimus/nbd-boot.sh

echo "[4/6] Creating custom mkinitfs features..."
sudo mkdir -p rootfs/etc/mkinitfs/features.d

cat > rootfs/etc/mkinitfs/features.d/bootimus.modules << 'EOF'
kernel/drivers/block/nbd.ko
EOF

cat > rootfs/etc/mkinitfs/features.d/bootimus.files << 'EOF'
/usr/bin/nbd-client
/etc/bootimus/nbd-boot.sh
EOF

echo "[5/6] Building initramfs with mkinitfs..."
cat > rootfs/build-final.sh << 'EOFBUILD'
#!/bin/sh
set -e

echo "features=\"ata base bootimus cdrom ext4 kms mmc nvme scsi usb virtio network dhcp\"" > /etc/mkinitfs/mkinitfs.conf

mkinitfs -o /boot/initramfs-bootimus $(ls /lib/modules/ | head -1)

ls -lh /boot/initramfs-bootimus
EOFBUILD

chmod +x rootfs/build-final.sh
sudo chroot rootfs /build-final.sh

echo "[6/6] Copying files to bootenv..."
cd ../..
sudo cp "$WORK_DIR/rootfs/boot/initramfs-bootimus" "$BOOTENV_DIR/initramfs-bootimus"
sudo chown $(whoami):$(whoami) "$BOOTENV_DIR/initramfs-bootimus"

echo ""
echo "=== Build Complete ==="
ls -lh "$BOOTENV_DIR/initramfs-bootimus"
echo ""
echo "Custom Alpine initramfs with NBD support created!"
echo "Next: Rebuild bootimus binary with 'go build'"
