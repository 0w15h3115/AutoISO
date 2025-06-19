### Post-copy cleanup and fixes
echo "[AutoISO] Performing post-copy cleanup..."

# Fix any broken symlinks
echo "[AutoISO] Fixing broken symbolic links..."
if [ -d "$EXTRACT_DIR" ]; then
    $SUDO find "$EXTRACT_DIR" -type l 2>/dev/null | while IFS= read -r link; do
        if [ ! -e "$link" ]; then
            echo "Removing broken symlink: $link"
            $SUDO rm -f "$link" 2>/dev/null || true
        fi
    done
fi

# Ensure essential directories exist
echo "[AutoISO] Creating essential directories..."
$SUDO mkdir -p "$EXTRACT_DIR/dev" "$EXTRACT_DIR/proc" "$EXTRACT_DIR/sys" "$EXTRACT_DIR/run" "$EXTRACT_DIR/tmp" "$EXTRACT_DIR/var/tmp"
$SUDO chmod 1777 "$EXTRACT_DIR/tmp" 2>/dev/null || true
$SUDO chmod 1777 "$EXTRACT_DIR/var/tmp" 2>/dev/null || true#!/bin/bash
# Ensure we're using bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires bash. Please run with: bash $0"
    exit 1
fi
# ========================================
#         A U T O M A T E D   I S O        
# ========================================
# AutoISO - Persistent Bootable Linux ISO Creator (Corrected Version)
set -e

### Configuration
# Allow override of work directory via environment variable
WORKDIR=${WORKDIR:-/tmp/iso}
EXTRACT_DIR="$WORKDIR/extract"
CDROOT_DIR="$WORKDIR/cdroot"
ISO_NAME="autoiso-persistent-$(date +%Y%m%d).iso"

# Dynamic kernel detection
KERNEL_VERSION=$(uname -r)
KERNEL_FILE="/boot/vmlinuz-$KERNEL_VERSION"
INITRD_FILE="/boot/initrd.img-$KERNEL_VERSION"

# Alternative kernel paths for different distributions
if [ ! -f "$KERNEL_FILE" ]; then
    KERNEL_FILE="/boot/vmlinuz"
fi
if [ ! -f "$INITRD_FILE" ]; then
    INITRD_FILE="/boot/initrd.img"
fi

EXCLUDE_DIRS=(
    "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*" 
    "/lost+found" "/home/*" ".cache" "/var/cache/*" "/var/log/*"
    "/var/lib/docker/*" "/var/lib/containerd/*" "/snap/*" "/var/snap/*"
    "/usr/src/*" "/var/lib/apt/lists/*" "/root/.cache/*"
    "/swapfile" "/pagefile.sys" "*.log" "/var/crash/*"
    "/var/lib/lxcfs/*" "/var/lib/systemd/coredump/*"
    "/var/spool/*" "/var/backups/*" "/boot/efi/*"
)

### Validation
echo "[AutoISO] Validating system requirements..."

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
    echo "[AutoISO] Running with sudo privileges"
fi

# Validate kernel files exist
if [ ! -f "$KERNEL_FILE" ]; then
    echo "[ERROR] Kernel file not found: $KERNEL_FILE"
    echo "Available kernels:"
    ls -la /boot/vmlinuz* 2>/dev/null || echo "No kernels found in /boot/"
    exit 1
fi

if [ ! -f "$INITRD_FILE" ]; then
    echo "[ERROR] Initrd file not found: $INITRD_FILE"
    echo "Available initrd files:"
    ls -la /boot/initrd* 2>/dev/null || echo "No initrd files found in /boot/"
    exit 1
fi

echo "[AutoISO] Using kernel: $KERNEL_FILE"
echo "[AutoISO] Using initrd: $INITRD_FILE"

# Check available disk space (minimum 12GB recommended due to duplication during build)
AVAILABLE_SPACE=$(df /tmp | awk 'NR==2 {print $4}')
AVAILABLE_GB=$((AVAILABLE_SPACE / 1024 / 1024))
echo "[AutoISO] Available space in /tmp: ${AVAILABLE_GB}GB"

if [ "$AVAILABLE_SPACE" -lt 12582912 ]; then
    echo "[ERROR] Insufficient space! Need at least 12GB, have ${AVAILABLE_GB}GB"
    echo "Free up space or change WORKDIR to a location with more space:"
    echo "  export WORKDIR=/path/to/larger/disk/iso"
    echo "  $0"
    exit 1
fi

### Cleanup
echo "[AutoISO] Cleaning old build..."
$SUDO rm -rf "$WORKDIR"
mkdir -p "$EXTRACT_DIR" "$CDROOT_DIR/boot/isolinux" "$CDROOT_DIR/live"

### Dependencies
echo "[AutoISO] Installing required packages..."
$SUDO apt-get update
$SUDO apt-get install -y genisoimage isolinux syslinux syslinux-utils squashfs-tools xorriso rsync live-boot live-boot-initramfs-tools

### Copy system files
echo "[AutoISO] Copying system files (this may take several minutes)..."

# Check initial space
SPACE_BEFORE=$(df "$WORKDIR" | awk 'NR==2 {print $4}')
echo "[AutoISO] Space before copy: $((SPACE_BEFORE / 1024 / 1024))GB"

EXCLUDE_ARGS=()
for dir in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$dir")
done

# More conservative rsync options to handle space constraints
RSYNC_OPTS=(
    -a                    # Archive mode
    --progress           # Show progress
    --partial            # Keep partially transferred files
    --ignore-errors      # Don't stop on errors
    --numeric-ids        # Don't map uid/gid values by user/group name
    --one-file-system    # Don't cross filesystem boundaries
    --compress           # Compress during transfer
    --prune-empty-dirs   # Don't create empty directories
)

# Copy with better error handling and space monitoring
echo "[AutoISO] Starting system copy with space monitoring..."
if ! $SUDO rsync "${RSYNC_OPTS[@]}" "${EXCLUDE_ARGS[@]}" / "$EXTRACT_DIR/"; then
    echo "[WARNING] Some files failed to copy due to space or permission issues"
    
    # Check remaining space
    SPACE_AFTER=$(df "$WORKDIR" | awk 'NR==2 {print $4}')
    echo "[AutoISO] Space after copy attempt: $((SPACE_AFTER / 1024 / 1024))GB"
    
    if [ "$SPACE_AFTER" -lt 1048576 ]; then  # Less than 1GB
        echo "[ERROR] Insufficient space to continue. Please:"
        echo "1. Free up space in $WORKDIR"
        echo "2. Or set WORKDIR to a location with more space:"
        echo "   export WORKDIR=/path/to/larger/disk"
        echo "   $0"
        exit 1
    fi
fi

### Prepare chroot environment
echo "[AutoISO] Preparing chroot environment..."
$SUDO mount --bind /dev "$EXTRACT_DIR/dev"
$SUDO mount --bind /proc "$EXTRACT_DIR/proc"
$SUDO mount --bind /sys "$EXTRACT_DIR/sys"
$SUDO mount --bind /dev/pts "$EXTRACT_DIR/dev/pts" 2>/dev/null || true

# Function to cleanup mounts on exit
cleanup_mounts() {
    echo "[AutoISO] Cleaning up mounts..."
    $SUDO umount "$EXTRACT_DIR/dev/pts" 2>/dev/null || true
    $SUDO umount "$EXTRACT_DIR/dev" 2>/dev/null || true
    $SUDO umount "$EXTRACT_DIR/proc" 2>/dev/null || true
    $SUDO umount "$EXTRACT_DIR/sys" 2>/dev/null || true
}
trap cleanup_mounts EXIT

### Configure chroot environment
echo "[AutoISO] Configuring live system..."

# Monitor disk space during chroot operations
check_space() {
    local space=$(df "$WORKDIR" | awk 'NR==2 {print $4}')
    local space_gb=$((space / 1024 / 1024))
    if [ "$space" -lt 2097152 ]; then  # Less than 2GB
        echo "[ERROR] Running low on space: ${space_gb}GB remaining"
        return 1
    fi
    return 0
}

# Simplified chroot configuration to avoid debconf issues
$SUDO chroot "$EXTRACT_DIR" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export LC_ALL=C
    export LANG=C
    
    # Update package lists
    apt-get update || true
    
    # Install live-boot without debconf prompts
    apt-get install -y --no-install-recommends live-boot live-boot-initramfs-tools || true
    
    # Create live user without debconf
    if ! id -u user >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo user || true
        echo 'user:live' | chpasswd || true
    fi
    
    # Clean up to save space
    apt-get clean || true
    rm -rf /var/lib/apt/lists/* || true
    rm -rf /var/cache/apt/* || true
    rm -rf /tmp/* || true
    rm -rf /var/tmp/* || true
"

# Check space after chroot operations
if ! check_space; then
    echo "[ERROR] Not enough space to continue"
    exit 1
fi

# Cleanup mounts
cleanup_mounts
trap - EXIT

### Clean problematic files
echo "[AutoISO] Cleaning up problematic files..."
$SUDO find "$EXTRACT_DIR" -name "*.log" -size +10M -delete 2>/dev/null || true
$SUDO find "$EXTRACT_DIR" -type f -path "*/var/cache/*" -delete 2>/dev/null || true

# Remove files with paths longer than ISO9660 limit (more aggressive cleanup)
echo "[AutoISO] Removing files with long paths..."
$SUDO find "$EXTRACT_DIR" -type f | while IFS= read -r file; do
    # Calculate relative path from extract dir
    rel_path="${file#$EXTRACT_DIR/}"
    if [[ ${#rel_path} -gt 180 ]]; then
        echo "Removing long path: $rel_path"
        $SUDO rm -f "$file" 2>/dev/null || true
    fi
done

# Remove problematic directories that often cause issues
PROBLEMATIC_DIRS=(
    "$EXTRACT_DIR/var/lib/docker"
    "$EXTRACT_DIR/var/lib/containerd"
    "$EXTRACT_DIR/snap"
    "$EXTRACT_DIR/var/snap"
    "$EXTRACT_DIR/usr/src"
    "$EXTRACT_DIR/var/lib/apt/lists"
    "$EXTRACT_DIR/var/cache"
    "$EXTRACT_DIR/tmp"
    "$EXTRACT_DIR/var/tmp"
    "$EXTRACT_DIR/root/.cache"
    "$EXTRACT_DIR/home/*/.cache"
    "$EXTRACT_DIR/home/*/.local/share/Trash"
    "$EXTRACT_DIR/home/*/.mozilla/firefox/*/cache2"
    "$EXTRACT_DIR/home/*/.config/google-chrome/*/Cache"
)

for dir_pattern in "${PROBLEMATIC_DIRS[@]}"; do
    if [[ "$dir_pattern" == *"*"* ]]; then
        # Handle glob patterns
        for dir in $dir_pattern; do
            if [[ -d "$dir" ]]; then
                echo "Removing problematic directory: $dir"
                $SUDO rm -rf "$dir" 2>/dev/null || true
            fi
        done
    else
        if [[ -d "$dir_pattern" ]]; then
            echo "Removing problematic directory: $dir_pattern"
            $SUDO rm -rf "$dir_pattern" 2>/dev/null || true
        fi
    fi
done

### Create SquashFS filesystem
echo "[AutoISO] Creating SquashFS filesystem (this may take several minutes)..."
$SUDO mksquashfs "$EXTRACT_DIR" "$CDROOT_DIR/live/filesystem.squashfs" \
    -e boot \
    -no-exports \
    -noappend \
    -comp xz \
    -processors $(nproc)

### Copy kernel and initrd
echo "[AutoISO] Copying kernel and initrd files..."
$SUDO cp "$KERNEL_FILE" "$CDROOT_DIR/live/vmlinuz"
$SUDO cp "$INITRD_FILE" "$CDROOT_DIR/live/initrd"

### Setup ISOLINUX bootloader
echo "[AutoISO] Setting up ISOLINUX bootloader..."

# Find correct isolinux paths (different distributions use different locations)
ISOLINUX_BIN=""
SYSLINUX_MODULES=""

for path in /usr/lib/isolinux /usr/lib/ISOLINUX /usr/share/isolinux; do
    if [ -f "$path/isolinux.bin" ]; then
        ISOLINUX_BIN="$path/isolinux.bin"
        break
    fi
done

for path in /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
    if [ -d "$path" ]; then
        SYSLINUX_MODULES="$path"
        break
    fi
done

if [ -z "$ISOLINUX_BIN" ]; then
    echo "[ERROR] isolinux.bin not found. Please install isolinux package."
    exit 1
fi

$SUDO cp "$ISOLINUX_BIN" "$CDROOT_DIR/boot/isolinux/"

# Copy syslinux modules
if [ -n "$SYSLINUX_MODULES" ]; then
    $SUDO cp "$SYSLINUX_MODULES"/*.c32 "$CDROOT_DIR/boot/isolinux/" 2>/dev/null || true
    $SUDO cp "$SYSLINUX_MODULES"/*.com "$CDROOT_DIR/boot/isolinux/" 2>/dev/null || true
fi

### Create boot configuration
echo "[AutoISO] Creating boot menu configuration..."
cat <<EOF | $SUDO tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg" > /dev/null
UI menu.c32
PROMPT 0
MENU TITLE AutoISO Persistent Live System
TIMEOUT 50
DEFAULT persistent

LABEL persistent
  MENU LABEL AutoISO Persistent Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistence persistent=cryptsetup,removable quiet splash

LABEL live
  MENU LABEL AutoISO Live Mode (No Persistence)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash

LABEL memtest
  MENU LABEL Memory Test
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components memtest

MENU SEPARATOR

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL Power Off
  COM32 poweroff.c32
EOF

### Create additional boot files
echo "[AutoISO] Creating additional configuration files..."

# Create isolinux boot catalog
$SUDO touch "$CDROOT_DIR/boot/isolinux/boot.cat"

### Build final ISO
echo "[AutoISO] Building final ISO image..."
cd "$CDROOT_DIR"

# Use more compatible ISO creation with filename length handling
$SUDO genisoimage \
    -o "$WORKDIR/$ISO_NAME" \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -J -R -l -V "AutoISO" \
    -allow-leading-dots \
    -relaxed-filenames \
    -allow-lowercase \
    -allow-multidot \
    -max-iso9660-filenames \
    .

# Make ISO readable by user
$SUDO chmod 644 "$WORKDIR/$ISO_NAME"

echo ""
echo "=========================="
echo "[✓] SUCCESS!"
echo "=========================="
echo "ISO created at: $WORKDIR/$ISO_NAME"
echo "Size: $(du -h "$WORKDIR/$ISO_NAME" | cut -f1)"
echo ""
echo "=== DISK SPACE USAGE ==="
echo "Work directory: $(du -sh "$WORKDIR" | cut -f1)"
FINAL_SPACE=$(df "$WORKDIR" | awk 'NR==2 {print $4}')
echo "Remaining space: $((FINAL_SPACE / 1024 / 1024))GB"
echo ""
echo "=== USAGE INSTRUCTIONS ==="
echo ""
echo "1. Write ISO to USB drive:"
echo "   sudo dd if='$WORKDIR/$ISO_NAME' of=/dev/sdX bs=4M status=progress && sync"
echo "   (Replace /dev/sdX with your USB device)"
echo ""
echo "2. Create persistence partition:"
echo "   a) Use gparted or fdisk to create a second partition on the USB"
echo "   b) Format it as ext4: sudo mkfs.ext4 -L persistence /dev/sdX2"
echo "   c) Mount it: sudo mount /dev/sdX2 /mnt"
echo "   d) Create persistence.conf: echo '/ union' | sudo tee /mnt/persistence.conf"
echo "   e) Unmount: sudo umount /mnt"
echo ""
echo "3. Boot from USB and select 'AutoISO Persistent Mode'"
echo ""
echo "Note: Changes will be saved to the persistence partition automatically."
echo ""
echo "=== CLEANUP ==="
echo "To free up space, run: sudo rm -rf $WORKDIR"
echo "=============================="
