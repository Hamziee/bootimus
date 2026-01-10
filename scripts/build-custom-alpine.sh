#!/bin/bash
set -e

ALPINE_DIR="../bootloaders/bootenv"
WORK_DIR="$ALPINE_DIR/work"
INITRD_SRC="$ALPINE_DIR/initramfs-lts"
INITRD_CUSTOM="$ALPINE_DIR/initramfs-bootimus"

echo "Building custom Bootimus Alpine initramfs..."

if [ ! -f "$INITRD_SRC" ]; then
    echo "Error: $INITRD_SRC not found. Run download-alpine.sh first."
    exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "Extracting initramfs..."
gunzip -c "../initramfs-lts" | cpio -idm 2>/dev/null

echo "Creating NBD boot script..."
mkdir -p etc/bootimus

cat > etc/bootimus/nbd-boot.sh << 'EOFSCRIPT'
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
udhcpc -i eth0 -q -n

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
EOFSCRIPT

chmod +x etc/bootimus/nbd-boot.sh

echo "Creating custom init..."
cat > init.new << 'EOFINIT'
#!/bin/sh

exec /sbin/init
EOFINIT

chmod +x init.new

echo "Modifying init to run NBD boot script..."
if [ -f init ]; then
    sed -i '/^exec \/sbin\/init/i\/etc\/bootimus\/nbd-boot.sh' init
fi

echo "Repacking initramfs..."
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "../initramfs-bootimus"

cd ..
rm -rf "$WORK_DIR"

echo "Custom initramfs created: $INITRD_CUSTOM"
ls -lh initramfs-bootimus
