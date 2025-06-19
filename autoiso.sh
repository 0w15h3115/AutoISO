#!/bin/bash

# Bootable ISO Creator Script
# Tested on Debian/Ubuntu-based systems

set -e

### Configuration
WORKDIR=~/customiso
EXTRACT_DIR="$WORKDIR/extract"
CDROOT_DIR="$WORKDIR/cdroot"
ISO_NAME=custom-linux.iso
EXCLUDE_DIRS=("/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*" "/lost+found" "/home/*" ".cache")

echo "[+] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y genisoimage isolinux syslinux squashfs-tools xorriso rsync

echo "[+] Creating working directories..."
mkdir -p "$CDROOT_DIR/boot/isolinux" "$EXTRACT_DIR"

echo "[+] Copying system files..."
EXCLUDE_ARGS=()
for dir in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$dir")
done

sudo rsync -aAX "${EXCLUDE_ARGS[@]}" / "$EXTRACT_DIR"

echo "[+] Creating compressed SquashFS of system..."
sudo mksquashfs "$EXTRACT_DIR" "$CDROOT_DIR/filesystem.squashfs" -e boot

echo "[+] Copying kernel and initrd..."
KERNEL=$(ls /boot/vmlinuz-* | head -n 1)
INITRD=$(ls /boot/initrd.img-* | head -n 1)

sudo cp "$KERNEL" "$CDROOT_DIR/boot/vmlinuz"
sudo cp "$INITRD" "$CDROOT_DIR/boot/initrd"

echo "[+] Adding ISOLINUX bootloader files..."
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$CDROOT_DIR/boot/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$CDROOT_DIR/boot/isolinux/"

echo "[+] Creating isolinux.cfg..."
cat <<EOF | sudo tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
MENU TITLE Custom Live Linux
TIMEOUT 50
DEFAULT linux

LABEL linux
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd boot=live quiet splash
EOF

echo "[+] Building ISO..."
cd "$CDROOT_DIR"
sudo mkisofs -o "$WORKDIR/$ISO_NAME" \
  -b boot/isolinux/isolinux.bin \
  -c boot/isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -J -R -V "CustomLinux" .

echo "[✓] ISO created at $WORKDIR/$ISO_NAME"
