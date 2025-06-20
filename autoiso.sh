#!/bin/bash
# Ensure we're using bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires bash. Please run with: bash $0"
    exit 1
fi

# ========================================
#         A U T O M A T E D   I S O        
# ========================================
# AutoISO - Persistent Bootable Linux ISO Creator (Fixed Version)
#
# USAGE:
#   ./autoiso.sh                           # Interactive disk selection
#   ./autoiso.sh /mnt/external-drive       # Use specific disk
#   WORKDIR=/mnt/ssd/build ./autoiso.sh    # Environment variable
#
# REQUIREMENTS:
#   - At least 15GB free space on target disk
#   - Root/sudo privileges
#   - Debian/Ubuntu-based system
#
set -e

# Show help if requested
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "AutoISO - Persistent Bootable Linux ISO Creator"
    echo ""
    echo "USAGE:"
    echo "  $0 [WORK_DIRECTORY]"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                           # Interactive selection"
    echo "  $0 /mnt/external-drive       # Use external drive"
    echo "  $0 /home/user/iso-build      # Use home directory"
    echo ""
    echo "ENVIRONMENT VARIABLES:"
    echo "  WORKDIR                      # Set work directory"
    echo ""
    echo "REQUIREMENTS:"
    echo "  - 15GB+ free space on target disk"
    echo "  - Root/sudo privileges"
    echo "  - Debian/Ubuntu-based system"
    echo ""
    echo "The script will create a subdirectory 'autoiso-build' in your chosen location."
    echo ""
    exit 0
fi

### Configuration
# Work directory selection with multiple options
if [ -n "$1" ]; then
    # Command line argument takes precedence
    WORKDIR="$1/autoiso-build"
elif [ -n "${WORKDIR}" ]; then
    # Environment variable second
    WORKDIR="${WORKDIR}"
else
    # Interactive selection if no argument provided
    echo "=== AutoISO Disk Selection ==="
    echo "Available disks and their free space:"
    echo ""
    df -h | grep -E "^/dev|^tmpfs" | grep -v "tmpfs.*tmp" | while read line; do
        echo "  $line"
    done
    echo ""
    echo "Current /tmp space: $(df -h /tmp | awk 'NR==2 {print $4}' | head -1)"
    echo ""
    echo "Recommendation: Choose a disk with at least 15GB free space"
    echo ""
    read -p "Enter work directory path (or press Enter for /tmp/iso): " user_workdir
    if [ -n "$user_workdir" ]; then
        WORKDIR="$user_workdir/autoiso-build"
    else
        WORKDIR="/tmp/iso"
    fi
fi

# Ensure workdir is absolute path
WORKDIR=$(realpath "$WORKDIR" 2>/dev/null || echo "$WORKDIR")
EXTRACT_DIR="$WORKDIR/extract"
CDROOT_DIR="$WORKDIR/cdroot"
ISO_NAME="autoiso-persistent-$(date +%Y%m%d-%H%M).iso"

echo ""
echo "=== Selected Configuration ==="
echo "Work Directory: $WORKDIR"
echo "Final ISO will be: $WORKDIR/$ISO_NAME"
echo ""

# Dynamic kernel detection - IMPROVED
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

# Additional fallbacks for initrd
if [ ! -f "$INITRD_FILE" ]; then
    INITRD_FILE="/boot/initramfs-$KERNEL_VERSION.img"
fi
if [ ! -f "$INITRD_FILE" ]; then
    INITRD_FILE="/boot/initramfs.img"
fi

EXCLUDE_DIRS=(
    "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*" 
    "/lost+found" "/home/*" ".cache" "/var/cache/*" "/var/log/*"
    "/var/lib/docker/*" "/var/lib/containerd/*" "/snap/*" "/var/snap/*"
    "/usr/src/*" "/var/lib/apt/lists/*" "/root/.cache/*"
    "/swapfile" "/pagefile.sys" "*.log" "/var/crash/*"
    "/var/lib/lxcfs/*" "/var/lib/systemd/coredump/*"
    "/var/spool/*" "/var/backups/*" "/boot/efi/*"
    "/var/lib/flatpak/*" "/var/lib/snapd/*"
    "${WORKDIR}/*"  # Exclude our own work directory
)

### Functions
log_info() {
    echo "[AutoISO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warning() {
    echo "[WARNING] $1" >&2
}

check_space() {
    local min_space_gb=${1:-2}
    local min_space_kb=$((min_space_gb * 1024 * 1024))
    local space=$(df "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    local space_gb=$((space / 1024 / 1024))
    
    if [ "$space" -lt "$min_space_kb" ]; then
        log_error "Insufficient space in $WORKDIR: ${space_gb}GB available, ${min_space_gb}GB required"
        echo ""
        echo "=== Available Disks ==="
        df -h | grep -E "^/dev" | grep -v "tmpfs"
        echo ""
        echo "To use a different disk, run:"
        echo "  $0 /path/to/disk/with/more/space"
        echo "  # OR set environment variable:"
        echo "  export WORKDIR=/path/to/disk/autoiso-work"
        echo "  $0"
        return 1
    fi
    log_info "Available space in $WORKDIR: ${space_gb}GB"
    return 0
}

cleanup_mounts() {
    log_info "Cleaning up mounts..."
    $SUDO umount "$EXTRACT_DIR/dev/pts" 2>/dev/null || true
    $SUDO umount "$EXTRACT_DIR/dev" 2>/dev/null || true
    $SUDO umount "$EXTRACT_DIR/proc" 2>/dev/null || true
    $SUDO umount "$EXTRACT_DIR/sys" 2>/dev/null || true
}

### Validation
log_info "Validating system requirements..."

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
    log_info "Running with sudo privileges"
fi

# Validate kernel files exist
if [ ! -f "$KERNEL_FILE" ]; then
    log_error "Kernel file not found: $KERNEL_FILE"
    echo "Available kernels:"
    ls -la /boot/vmlinuz* 2>/dev/null || echo "No kernels found in /boot/"
    exit 1
fi

if [ ! -f "$INITRD_FILE" ]; then
    log_error "Initrd file not found: $INITRD_FILE"
    echo "Available initrd files:"
    ls -la /boot/initrd* /boot/initramfs* 2>/dev/null || echo "No initrd files found in /boot/"
    exit 1
fi

log_info "Using kernel: $KERNEL_FILE"
log_info "Using initrd: $INITRD_FILE"

# Create work directory if it doesn't exist
if [ ! -d "$WORKDIR" ]; then
    log_info "Creating work directory: $WORKDIR"
    mkdir -p "$WORKDIR" || {
        log_error "Cannot create work directory: $WORKDIR"
        echo "Please check permissions or choose a different location."
        exit 1
    }
fi

if ! check_space 15; then
    echo ""
    echo "=== Disk Space Solutions ==="
    echo "1. Use a different disk:"
    echo "   $0 /path/to/larger/disk"
    echo ""
    echo "2. Set environment variable:"
    echo "   export WORKDIR=/path/to/larger/disk/autoiso-work"
    echo "   $0"
    echo ""
    echo "3. Clean up current location:"
    echo "   sudo rm -rf $WORKDIR"
    echo "   # Then run the script again"
    exit 1
fi

### Cleanup
log_info "Cleaning old build..."
$SUDO rm -rf "$WORKDIR"
mkdir -p "$EXTRACT_DIR" "$CDROOT_DIR/boot/isolinux" "$CDROOT_DIR/live"

### Dependencies
log_info "Installing required packages..."
$SUDO apt-get update -qq
$SUDO apt-get install -y genisoimage isolinux syslinux syslinux-utils squashfs-tools xorriso rsync live-boot live-boot-initramfs-tools

### Copy system files
log_info "Copying system files (this may take several minutes)..."

EXCLUDE_ARGS=()
for dir in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$dir")
done

# Enhanced rsync options for better compression and reliability
RSYNC_OPTS=(
    -a                    # Archive mode
    --progress           # Show progress
    --partial            # Keep partially transferred files
    --ignore-errors      # Don't stop on errors
    --numeric-ids        # Don't map uid/gid values by user/group name
    --one-file-system    # Don't cross filesystem boundaries
    --compress           # Compress during transfer
    --compress-level=6   # Higher compression
    --prune-empty-dirs   # Don't create empty directories
    --delete-excluded    # Delete excluded files from destination
)

# Copy with better error handling and space monitoring
log_info "Starting system copy with space monitoring..."
if ! $SUDO rsync "${RSYNC_OPTS[@]}" "${EXCLUDE_ARGS[@]}" / "$EXTRACT_DIR/"; then
    log_warning "Some files failed to copy due to space or permission issues"
    
    if ! check_space 3; then
        echo ""
        echo "=== Space Recovery Options ==="
        echo "1. Move to larger disk:"
        echo "   sudo rm -rf $WORKDIR"
        echo "   $0 /path/to/larger/disk"
        echo ""
        echo "2. Clean current build and retry:"
        echo "   sudo rm -rf $WORKDIR"
        echo "   $0"
        exit 1
    fi
fi

### Post-copy cleanup and fixes
log_info "Performing post-copy cleanup..."

# Fix any broken symlinks
log_info "Fixing broken symbolic links..."
if [ -d "$EXTRACT_DIR" ]; then
    $SUDO find "$EXTRACT_DIR" -type l 2>/dev/null | while IFS= read -r link; do
        if [ ! -e "$link" ]; then
            echo "Removing broken symlink: $link"
            $SUDO rm -f "$link" 2>/dev/null || true
        fi
    done
fi

# Ensure essential directories exist
log_info "Creating essential directories..."
$SUDO mkdir -p "$EXTRACT_DIR/dev" "$EXTRACT_DIR/proc" "$EXTRACT_DIR/sys" "$EXTRACT_DIR/run" "$EXTRACT_DIR/tmp" "$EXTRACT_DIR/var/tmp"
$SUDO chmod 1777 "$EXTRACT_DIR/tmp" 2>/dev/null || true
$SUDO chmod 1777 "$EXTRACT_DIR/var/tmp" 2>/dev/null || true

### Prepare chroot environment
log_info "Preparing chroot environment..."
$SUDO mount --bind /dev "$EXTRACT_DIR/dev"
$SUDO mount --bind /proc "$EXTRACT_DIR/proc"
$SUDO mount --bind /sys "$EXTRACT_DIR/sys"
$SUDO mount --bind /dev/pts "$EXTRACT_DIR/dev/pts" 2>/dev/null || true

# Set trap for cleanup
trap cleanup_mounts EXIT

### Configure chroot environment - IMPROVED
log_info "Configuring live system..."

# Create live-specific configuration
$SUDO chroot "$EXTRACT_DIR" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export LC_ALL=C
    export LANG=C
    
    # Update package lists
    apt-get update -qq || true
    
    # Install live-boot and essential packages
    apt-get install -y --no-install-recommends \
        live-boot \
        live-boot-initramfs-tools \
        live-config \
        live-config-systemd || true
    
    # Create live user if it doesn't exist
    if ! id -u user >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo user || true
        echo 'user:live' | chpasswd || true
        mkdir -p /home/user/{Desktop,Documents,Downloads,Pictures,Videos} || true
        chown -R user:user /home/user || true
    fi
    
    # Configure autologin for live user
    mkdir -p /etc/systemd/system/getty@tty1.service.d/
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOFAUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I \$TERM
EOFAUTOLOGIN
    
    # Install useful packages for live environment
    apt-get install -y --no-install-recommends \
        network-manager \
        wireless-tools \
        wpasupplicant \
        firefox-esr \
        pcmanfm \
        nano \
        htop \
        sudo || true
    
    # Enable NetworkManager
    systemctl enable NetworkManager || true
    
    # Configure sudo for live user
    echo 'user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/user
    
    # Update initramfs with live-boot hooks
    update-initramfs -u -k all || true
    
    # Clean up to save space
    apt-get autoremove -y || true
    apt-get autoclean || true
    apt-get clean || true
    rm -rf /var/lib/apt/lists/* || true
    rm -rf /var/cache/apt/* || true
    rm -rf /tmp/* || true
    rm -rf /var/tmp/* || true
    rm -rf /var/log/*.log || true
    
    # Clear bash history
    history -c || true
    rm -f /root/.bash_history /home/*/bash_history || true
"

# Cleanup mounts
cleanup_mounts
trap - EXIT

### Advanced cleanup
log_info "Performing advanced cleanup..."

# Remove large log files
$SUDO find "$EXTRACT_DIR" -name "*.log" -size +10M -delete 2>/dev/null || true
$SUDO find "$EXTRACT_DIR" -type f -path "*/var/cache/*" -delete 2>/dev/null || true

# Remove problematic directories
PROBLEMATIC_DIRS=(
    "$EXTRACT_DIR/var/lib/docker"
    "$EXTRACT_DIR/var/lib/containerd"
    "$EXTRACT_DIR/snap"
    "$EXTRACT_DIR/var/snap"
    "$EXTRACT_DIR/usr/src"
    "$EXTRACT_DIR/var/lib/apt/lists"
    "$EXTRACT_DIR/var/cache"
    "$EXTRACT_DIR/root/.cache"
    "$EXTRACT_DIR/var/lib/flatpak"
    "$EXTRACT_DIR/var/lib/snapd"
)

for dir_pattern in "${PROBLEMATIC_DIRS[@]}"; do
    if [[ -d "$dir_pattern" ]]; then
        log_info "Removing problematic directory: $dir_pattern"
        $SUDO rm -rf "$dir_pattern" 2>/dev/null || true
    fi
done

### Create SquashFS filesystem
log_info "Creating SquashFS filesystem (this may take several minutes)..."

if ! check_space 4; then
    log_error "Insufficient space for SquashFS creation"
    exit 1
fi

# Create SquashFS with proper exclusions
$SUDO mksquashfs "$EXTRACT_DIR" "$CDROOT_DIR/live/filesystem.squashfs" \
    -e boot \
    -no-exports \
    -noappend \
    -comp xz \
    -Xbcj x86 \
    -Xdict-size 100% \
    -b 1M \
    -processors $(nproc) \
    -progress

### Copy kernel and initrd
log_info "Copying kernel and initrd files..."
$SUDO cp "$KERNEL_FILE" "$CDROOT_DIR/live/vmlinuz"
$SUDO cp "$INITRD_FILE" "$CDROOT_DIR/live/initrd"

### Setup ISOLINUX bootloader - IMPROVED
log_info "Setting up ISOLINUX bootloader..."

# Find correct isolinux and syslinux paths
ISOLINUX_BIN=""
SYSLINUX_MODULES=""
MBR_BIN=""

# Search for isolinux.bin
for path in /usr/lib/isolinux /usr/lib/ISOLINUX /usr/share/isolinux /usr/lib/syslinux/isolinux; do
    if [ -f "$path/isolinux.bin" ]; then
        ISOLINUX_BIN="$path/isolinux.bin"
        break
    fi
done

# Search for syslinux modules
for path in /usr/lib/syslinux/modules/bios /usr/share/syslinux /usr/lib/syslinux; do
    if [ -d "$path" ] && [ -f "$path/menu.c32" ]; then
        SYSLINUX_MODULES="$path"
        break
    fi
done

# Search for MBR binary
for path in /usr/lib/syslinux/mbr /usr/lib/ISOLINUX /usr/share/syslinux; do
    if [ -f "$path/isohdpfx.bin" ]; then
        MBR_BIN="$path/isohdpfx.bin"
        break
    fi
done

if [ -z "$ISOLINUX_BIN" ]; then
    log_error "isolinux.bin not found. Please install isolinux package."
    exit 1
fi

if [ -z "$SYSLINUX_MODULES" ]; then
    log_error "Syslinux modules not found. Please install syslinux package."
    exit 1
fi

log_info "Using isolinux: $ISOLINUX_BIN"
log_info "Using syslinux modules: $SYSLINUX_MODULES"
if [ -n "$MBR_BIN" ]; then
    log_info "Using MBR: $MBR_BIN"
fi

$SUDO cp "$ISOLINUX_BIN" "$CDROOT_DIR/boot/isolinux/"

# Copy essential syslinux modules
for module in menu.c32 chain.c32 reboot.c32 poweroff.c32 libutil.c32 libcom32.c32; do
    if [ -f "$SYSLINUX_MODULES/$module" ]; then
        $SUDO cp "$SYSLINUX_MODULES/$module" "$CDROOT_DIR/boot/isolinux/"
    fi
done

### Create boot configuration - IMPROVED
log_info "Creating boot menu configuration..."
cat <<EOF | $SUDO tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg" > /dev/null
UI menu.c32
PROMPT 0
MENU TITLE AutoISO Persistent Live System
TIMEOUT 300
DEFAULT live

LABEL live
  MENU LABEL ^AutoISO Live Mode (Default)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso quiet splash

LABEL persistent
  MENU LABEL AutoISO ^Persistent Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistence locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso quiet splash

LABEL live-safe
  MENU LABEL AutoISO ^Safe Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso nomodeset noapic acpi=off

LABEL live-toram
  MENU LABEL AutoISO to ^RAM
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso quiet splash

MENU SEPARATOR

LABEL reboot
  MENU LABEL ^Reboot Computer
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL ^Power Off Computer
  COM32 poweroff.c32
EOF

### Create additional boot files
log_info "Creating additional configuration files..."
$SUDO touch "$CDROOT_DIR/boot/isolinux/boot.cat"

### Build final ISO - IMPROVED
log_info "Building final ISO image..."
cd "$CDROOT_DIR"

if ! check_space 1; then
    log_error "Insufficient space for ISO creation"
    exit 1
fi

# Build ISO with proper hybrid support
log_info "Creating bootable ISO with hybrid support..."

# First try with xorriso (preferred method)
if command -v xorriso >/dev/null 2>&1 && [ -n "$MBR_BIN" ]; then
    log_info "Using xorriso with hybrid boot support..."
    $SUDO xorriso -as mkisofs \
        -r -V "AutoISO-$(date +%Y%m%d)" \
        -o "$WORKDIR/$ISO_NAME" \
        -J -joliet-long \
        -isohybrid-mbr "$MBR_BIN" \
        -partition_offset 16 \
        -c boot/isolinux/boot.cat \
        -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        .
    
    # Make the ISO hybrid bootable
    if command -v isohybrid >/dev/null 2>&1; then
        log_info "Making ISO hybrid bootable..."
        $SUDO isohybrid "$WORKDIR/$ISO_NAME" 2>/dev/null || log_warning "isohybrid failed, but ISO should still work"
    fi
else
    # Fallback to genisoimage
    log_warning "Using genisoimage (xorriso not available or MBR not found)..."
    $SUDO genisoimage \
        -o "$WORKDIR/$ISO_NAME" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -J -R -V "AutoISO-$(date +%Y%m%d)" \
        .
    
    # Make hybrid if possible
    if command -v isohybrid >/dev/null 2>&1; then
        log_info "Making ISO hybrid bootable..."
        $SUDO isohybrid "$WORKDIR/$ISO_NAME" 2>/dev/null || log_warning "isohybrid failed"
    fi
fi

# Make ISO readable by user
$SUDO chmod 644 "$WORKDIR/$ISO_NAME"

# Verify ISO integrity
log_info "Verifying ISO integrity..."
if command -v isoinfo >/dev/null 2>&1; then
    if isoinfo -d -i "$WORKDIR/$ISO_NAME" >/dev/null 2>&1; then
        log_info "ISO integrity check passed"
    else
        log_warning "ISO integrity check failed - but ISO might still work"
    fi
fi

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
echo "Disk: $(df -h "$WORKDIR" | awk 'NR==2 {print $1}')"
echo ""
echo "=== USAGE INSTRUCTIONS ==="
echo ""
echo "1. Write ISO to USB drive (CAREFUL - THIS WILL ERASE THE USB!):"
echo "   First, identify your USB device:"
echo "   lsblk"
echo "   Then write the ISO (replace sdX with your USB device):"
echo "   sudo dd if='$WORKDIR/$ISO_NAME' of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
echo "2. Alternative: Use a GUI tool like Etcher, Rufus, or Startup Disk Creator"
echo ""
echo "3. Boot from USB:"
echo "   - Select 'AutoISO Live Mode' for normal live session"
echo "   - Select 'AutoISO Persistent Mode' if you have a persistence partition"
echo "   - Select 'Safe Mode' if you have boot issues"
echo ""
echo "4. Default login: user / live (user has sudo privileges)"
echo ""
echo "=== TROUBLESHOOTING ==="
echo "If the ISO doesn't boot:"
echo "1. Verify USB write: sudo cmp '$WORKDIR/$ISO_NAME' /dev/sdX"
echo "2. Try different USB port/drive"
echo "3. Check BIOS/UEFI settings (disable Secure Boot, enable Legacy/CSM)"
echo "4. Try Safe Mode boot option"
echo ""
echo "=== CLEANUP ==="
echo "To free up space, run: sudo rm -rf $WORKDIR"
echo ""
echo "=============================="
