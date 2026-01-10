#!/bin/bash
set -e

ALPINE_VERSION="3.19"
BOOTENV_DIR="../bootloaders/bootenv"
ALPINE_BASE_URL="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/netboot"

echo "Downloading Alpine Linux ${ALPINE_VERSION} netboot files..."

mkdir -p "$BOOTENV_DIR"
cd "$BOOTENV_DIR"

if [ ! -f "vmlinuz-lts" ]; then
    echo "Downloading kernel..."
    wget -q "${ALPINE_BASE_URL}/vmlinuz-lts"
else
    echo "Kernel already exists, skipping..."
fi

if [ ! -f "initramfs-lts" ]; then
    echo "Downloading initramfs..."
    wget -q "${ALPINE_BASE_URL}/initramfs-lts"
else
    echo "Initramfs already exists, skipping..."
fi

if [ ! -f "modloop-lts" ]; then
    echo "Downloading modloop..."
    wget -q "${ALPINE_BASE_URL}/modloop-lts"
else
    echo "Modloop already exists, skipping..."
fi

echo "Alpine Linux netboot files downloaded successfully!"
echo "Files located in: ${BOOTENV_DIR}"
ls -lh
