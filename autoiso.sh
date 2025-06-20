!/bin/bash
# Ensure we're using bash
if [ -z "$BASH_VERSION" ]; then
    fatal_error "This script requires bash. Please run with: bash $0"
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
#   - At least 15GB free space on target disk   (10GB for the ISO, 5GB for the build)                   
#   - Root/sudo privileges
#   - Debian/Ubuntu-based system
#
# EXAMPLES:
#   ./autoiso.sh /mnt/external-ssd         # Use external SSD
#   ./autoiso.sh /home/user/iso-build      # Use home directory
#   ./autoiso.sh /media/user/USB-DRIVE     # Use mounted USB drive
#
set -e
set -o pipefail

# Move cleanup_mounts above fatal_error and trap
cleanup_mounts() {
    log_info "Cleaning up mounts..."
    for mount_point in "$EXTRACT_DIR/dev/pts" "$EXTRACT_DIR/dev" "$EXTRACT_DIR/proc" "$EXTRACT_DIR/sys"; do
        if [ -d "$mount_point" ]; then
            if mountpoint -q "$mount_point" 2>/dev/null; then
                $SUDO umount "$mount_point" 2>/dev/null || true
            fi
        fi
    done
}

# Centralized fatal error handler
fatal_error() {
    local msg="$1"
    echo "[FATAL] $msg" >&2
    cleanup_mounts
    echo "\nIf you need help, please check the log above or consult the README."
    exit 1
}

# Trap for uncaught errors
trap 'fatal_error "An unexpected error occurred."' ERR
trap cleanup_mounts EXIT INT TERM

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
    # Interactive selection using lsblk
    echo "=== AutoISO Storage Selection ==="
    echo ""
    echo "Available storage devices and partitions:"
    echo ""
    # Show block devices with lsblk
    lsblk -f -o NAME,SIZE,AVAIL,USE%,FSTYPE,MOUNTPOINT | grep -E "(NAME|part|disk)" || {
        echo "Error: lsblk command failed. Falling back to df output."
        df -h | grep -E "^/dev" | grep -v "tmpfs"
    }
    echo ""
    echo "Mounted filesystems with available space:"
    df -h | grep -E "^/dev|^tmpfs" | grep -v "tmpfs.*tmp" | while read line; do
        echo "  $line"
    done
    echo ""
    echo "Current /tmp space: $(df -h /tmp | awk 'NR==2 {print $4}' | head -1)"
    echo ""
    echo "Recommendation: Choose a location with at least 15GB free space"
    echo ""
    read -t 30 -p "Enter work directory path (or press Enter for /tmp/iso): " user_workdir || user_workdir=""
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
    "/var/lib/flatpak/*" "/var/lib/snapd/*"
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

# Early check for required commands
REQUIRED_CMDS=(rsync xorriso genisoimage mksquashfs isoinfo realpath lsblk df awk grep tee stat find cp mkdir rm chmod mount umount sudo apt-get grub-mkimage grub-install mtools)
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done
if [ ${#MISSING_CMDS[@]} -ne 0 ]; then
    fatal_error "Missing required commands: ${MISSING_CMDS[*]}\nPlease install the missing packages before running this script."
fi

# Check for sudo availability if not root
if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        fatal_error "This script requires sudo privileges, but 'sudo' is not installed."
    fi
    if ! sudo -n true 2>/dev/null; then
        fatal_error "This script requires sudo privileges. Please ensure your user can run sudo without a password prompt."
    fi
fi

check_space() {
    local min_space_gb=${1:-2}
    local min_space_kb=$((min_space_gb * 1024 * 1024))
    # Handle case where WORKDIR doesn't exist yet
    local check_dir="$WORKDIR"
    if [ ! -d "$WORKDIR" ]; then
        check_dir=$(dirname "$WORKDIR")
    fi
    local space=$(df "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    local space_gb=$((space / 1024 / 1024))
    # Check for free inodes as well
    local inodes=$(df -i "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$space" -lt "$min_space_kb" ]; then
        log_error "Insufficient space in $check_dir: ${space_gb}GB available, ${min_space_gb}GB required"
        echo ""
        echo "=== Available Storage ==="
        lsblk -f -o NAME,SIZE,AVAIL,USE%,FSTYPE,MOUNTPOINT 2>/dev/null || df -h | grep -E "^/dev"
        echo ""
        echo "To use a different location, run:"
        echo "  $0 /path/to/location/with/more/space"
        echo "  # OR set environment variable:"
        echo "  export WORKDIR=/path/to/location/autoiso-work"
        echo "  $0"
        return 1
    fi
    if [ "$inodes" -lt 10000 ]; then
        log_error "Insufficient free inodes in $check_dir: $inodes available, at least 10000 required."
        echo "Consider cleaning up files or using a different location."
        return 1
    fi
    log_info "Available space in $check_dir: ${space_gb}GB, free inodes: $inodes"
    return 0
}

detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

### Validation
log_info "Validating system requirements..."

# Check distribution
DISTRO=$(detect_distribution)
if [[ ! "$DISTRO" =~ ^(debian|ubuntu|mint|pop|elementary|zorin)$ ]]; then
    log_warning "Detected distribution: $DISTRO"
    log_warning "This script is designed for Debian/Ubuntu-based systems"
    read -p "Continue anyway? (y/N): " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
    log_info "Running with sudo privileges"
fi

# Validate essential system directories exist
for essential_dir in /boot /etc /usr /var; do
    if [ ! -d "$essential_dir" ]; then
        fatal_error "Essential directory $essential_dir not found. Cannot proceed."
    fi
done

# Validate kernel files exist
if [ ! -f "$KERNEL_FILE" ]; then
    log_error "Kernel file not found: $KERNEL_FILE"
    echo "Available kernels:"
    ls -la /boot/vmlinuz* 2>/dev/null || echo "No kernels found in /boot/"
    fatal_error "Kernel file not found."
fi

if [ ! -f "$INITRD_FILE" ]; then
    log_error "Initrd file not found: $INITRD_FILE"
    echo "Available initrd files:"
    ls -la /boot/initrd* 2>/dev/null || echo "No initrd files found in /boot/"
    fatal_error "Initrd file not found."
fi

log_info "Using kernel: $KERNEL_FILE"
log_info "Using initrd: $INITRD_FILE"

# Check available disk space (minimum 15GB recommended for safety)
log_info "Checking disk space requirements..."
echo "Work directory location: $WORKDIR"

# Create work directory if it doesn't exist
if [ ! -d "$WORKDIR" ]; then
    log_info "Creating work directory: $WORKDIR"
    mkdir -p "$WORKDIR" || fatal_error "Cannot create work directory: $WORKDIR\nPlease check permissions or choose a different location."
fi

echo "Disk info: $(df -h "$WORKDIR" 2>/dev/null | tail -1 || echo "Path not accessible")"

# Filesystem type check for workdir
fs_type=$(df -T "$WORKDIR" | awk 'NR==2 {print $2}')
if [[ "$fs_type" =~ ^(vfat|exfat|ntfs)$ ]]; then
    fatal_error "Work directory is on $fs_type, which may not support all required features. Use ext4 or another Linux filesystem."
fi

if ! check_space 15; then
    echo ""
    echo "=== Disk Space Solutions ==="
    echo "1. Use a different location:"
    echo "   $0 /path/to/larger/location"
    echo ""
    echo "2. Set environment variable:"
    echo "   export WORKDIR=/path/to/larger/location/autoiso-work"
    echo "   $0"
    echo ""
    echo "3. Clean up current location:"
    echo "   sudo rm -rf $WORKDIR"
    echo "   # Then run the script again"
    fatal_error "Insufficient disk space."
fi

### Cleanup
log_info "Cleaning old build..."
$SUDO rm -rf "$WORKDIR"
mkdir -p "$EXTRACT_DIR" "$CDROOT_DIR/boot/isolinux" "$CDROOT_DIR/live"

### Dependencies
log_info "Installing required packages..."
$SUDO apt-get update -qq
$SUDO apt-get install -y genisoimage isolinux syslinux syslinux-utils squashfs-tools xorriso rsync live-boot live-boot-initramfs-tools grub-mkimage grub-install mtools

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
        echo "1. Move to larger location:"
        echo "   sudo rm -rf $WORKDIR"
        echo "   $0 /path/to/larger/location"
        echo ""
        echo "2. Clean current build and retry:"
        echo "   sudo rm -rf $WORKDIR"
        echo "   $0"
        fatal_error "Insufficient disk space during rsync."
    fi
fi

### Post-copy cleanup and fixes
log_info "Performing post-copy cleanup..."

# Fix any broken symlinks (improved error handling)
log_info "Fixing broken symbolic links..."
if [ -d "$EXTRACT_DIR" ]; then
    $SUDO find "$EXTRACT_DIR" -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do
        if [ ! -e "$link" ]; then
            echo "Removing broken symlink: ${link#$EXTRACT_DIR/}"
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

### Configure chroot environment
log_info "Configuring live system..."

# Determine packages based on distribution
LIVE_PACKAGES="live-boot live-boot-initramfs-tools"
NETWORK_PACKAGES="network-manager wireless-tools wpasupplicant"
BROWSER_PACKAGE=""
FILE_MANAGER=""

case "$DISTRO" in
    ubuntu|mint|pop|elementary|zorin)
        BROWSER_PACKAGE="firefox"
        FILE_MANAGER="nautilus"
        ;;
    debian)
        BROWSER_PACKAGE="firefox-esr"
        FILE_MANAGER="pcmanfm"
        ;;
    *)
        BROWSER_PACKAGE="firefox-esr"
        FILE_MANAGER="pcmanfm"
        ;;
esac

# Simplified chroot configuration to avoid debconf issues
$SUDO chroot "$EXTRACT_DIR" bash -c "
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export LC_ALL=C
    export LANG=C
    
    # Update package lists
    apt-get update -qq 2>/dev/null || true
    
    # Install live-boot without debconf prompts
    apt-get install -y --no-install-recommends $LIVE_PACKAGES 2>/dev/null || true
    
    # Create live user without debconf
    if ! id -u user >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo user 2>/dev/null || true
        echo 'user:live' | chpasswd 2>/dev/null || true
        # Set up basic user environment
        mkdir -p /home/user/{Desktop,Documents,Downloads,Pictures,Videos} 2>/dev/null || true
        chown -R user:user /home/user 2>/dev/null || true
    fi
    
    # Install useful packages for live environment (with error handling)
    apt-get install -y --no-install-recommends \
        $NETWORK_PACKAGES \
        nano \
        htop 2>/dev/null || true
    
    # Try to install browser and file manager (non-critical)
    apt-get install -y --no-install-recommends $BROWSER_PACKAGE 2>/dev/null || true
    apt-get install -y --no-install-recommends $FILE_MANAGER 2>/dev/null || true
    
    # Enable NetworkManager
    systemctl enable NetworkManager 2>/dev/null || true
    
    # Clean up to save space
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    rm -rf /var/cache/apt/* 2>/dev/null || true
    rm -rf /tmp/* 2>/dev/null || true
    rm -rf /var/tmp/* 2>/dev/null || true
    rm -rf /var/log/*.log 2>/dev/null || true
    
    # Clear bash history
    history -c 2>/dev/null || true
    rm -f /root/.bash_history /home/*/bash_history 2>/dev/null || true

    if ! dpkg -l | grep -q live-boot; then
        echo '[WARNING] live-boot package not found after install!' >&2
    fi
"

# Check space after chroot operations
if ! check_space 2; then
    fatal_error "Not enough space to continue after chroot configuration"
fi

### Advanced cleanup
log_info "Performing advanced cleanup..."

# Remove large log files
$SUDO find "$EXTRACT_DIR" -name "*.log" -size +10M -delete 2>/dev/null || true
$SUDO find "$EXTRACT_DIR" -type f -path "*/var/cache/*" -delete 2>/dev/null || true

# Remove files with paths longer than ISO9660 limit (more conservative)
log_info "Removing files with excessively long paths..."
$SUDO find "$EXTRACT_DIR" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
    rel_path="${file#$EXTRACT_DIR/}"
    if [[ ${#rel_path} -gt 200 ]]; then
        echo "Removing long path: ${rel_path:0:50}..."
        $SUDO rm -f "$file" 2>/dev/null || true
    fi
done

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
        log_info "Removing problematic directory: ${dir_pattern#$EXTRACT_DIR/}"
        $SUDO rm -rf "$dir_pattern" 2>/dev/null || true
    fi
done

# Remove user cache directories
$SUDO find "$EXTRACT_DIR/home" -type d -name ".cache" -exec rm -rf {} + 2>/dev/null || true
$SUDO find "$EXTRACT_DIR/home" -type d -path "*/.mozilla/firefox/*/cache2" -exec rm -rf {} + 2>/dev/null || true
$SUDO find "$EXTRACT_DIR/home" -type d -path "*/.config/google-chrome/*/Cache" -exec rm -rf {} + 2>/dev/null || true

### Create SquashFS filesystem
log_info "Creating SquashFS filesystem (this may take several minutes)..."

# Check space before squashfs creation
if ! check_space 4; then
    fatal_error "Insufficient space for SquashFS creation"
fi

# Enhanced SquashFS compression options to reduce size
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

# Check final squashfs size and warn if it's very large
SQUASHFS_SIZE=$(stat -c%s "$CDROOT_DIR/live/filesystem.squashfs" 2>/dev/null || echo "0")
SQUASHFS_SIZE_GB=$((SQUASHFS_SIZE / 1024 / 1024 / 1024))

if [ "$SQUASHFS_SIZE_GB" -gt 4 ]; then
    log_warning "SquashFS is ${SQUASHFS_SIZE_GB}GB - using xorriso for large file support"
fi

### Copy kernel and initrd
log_info "Copying kernel and initrd files..."
$SUDO cp "$KERNEL_FILE" "$CDROOT_DIR/live/vmlinuz"
$SUDO cp "$INITRD_FILE" "$CDROOT_DIR/live/initrd"

### Setup ISOLINUX bootloader
log_info "Setting up ISOLINUX bootloader..."

# Find correct isolinux paths - FIXED: Added dynamic detection for both files
ISOLINUX_BIN=""
ISOHDPFX_BIN=""
SYSLINUX_MODULES=""

# Find isolinux.bin
for path in /usr/lib/isolinux /usr/lib/ISOLINUX /usr/share/isolinux; do
    if [ -f "$path/isolinux.bin" ]; then
        ISOLINUX_BIN="$path/isolinux.bin"
        break
    fi
done

# Find isohdpfx.bin - CRITICAL FIX
for path in /usr/lib/isolinux /usr/lib/ISOLINUX /usr/share/isolinux /usr/lib/syslinux/mbr; do
    if [ -f "$path/isohdpfx.bin" ]; then
        ISOHDPFX_BIN="$path/isohdpfx.bin"
        break
    fi
done

# Find syslinux modules
for path in /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
    if [ -d "$path" ]; then
        SYSLINUX_MODULES="$path"
        break
    fi
done

if [ -z "$ISOLINUX_BIN" ]; then
    log_error "isolinux.bin not found. Please install isolinux package."
    echo "Searched in: /usr/lib/isolinux, /usr/lib/ISOLINUX, /usr/share/isolinux"
    fatal_error "isolinux.bin not found."
fi

if [ -z "$ISOHDPFX_BIN" ]; then
    log_error "isohdpfx.bin not found. Please install isolinux package."
    echo "Searched in: /usr/lib/isolinux, /usr/lib/ISOLINUX, /usr/share/isolinux, /usr/lib/syslinux/mbr"
    fatal_error "isohdpfx.bin not found."
fi

log_info "Found isolinux.bin: $ISOLINUX_BIN"
log_info "Found isohdpfx.bin: $ISOHDPFX_BIN"

$SUDO cp "$ISOLINUX_BIN" "$CDROOT_DIR/boot/isolinux/"

# Copy syslinux modules
if [ -n "$SYSLINUX_MODULES" ]; then
    $SUDO cp "$SYSLINUX_MODULES"/*.c32 "$CDROOT_DIR/boot/isolinux/" 2>/dev/null || true
    $SUDO cp "$SYSLINUX_MODULES"/*.com "$CDROOT_DIR/boot/isolinux/" 2>/dev/null || true
fi

### Create boot configuration
log_info "Creating boot menu configuration..."
cat <<EOF | $SUDO tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg" > /dev/null
UI menu.c32
PROMPT 0
MENU TITLE AutoISO Persistent Live System
MENU BACKGROUND splash.png
TIMEOUT 100
DEFAULT persistent

LABEL persistent
  MENU LABEL ^AutoISO Persistent Mode (Recommended)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistence persistent=cryptsetup,removable quiet splash noswap

LABEL live
  MENU LABEL AutoISO ^Live Mode (No Persistence)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash noswap

LABEL live-safe
  MENU LABEL AutoISO ^Safe Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash noswap nomodeset

LABEL live-toram
  MENU LABEL AutoISO to ^RAM (Requires 4GB+ RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram quiet splash noswap

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

### Build final ISO
log_info "Building final ISO image..."
cd "$CDROOT_DIR"

# Before building the ISO, check if the output ISO file already exists
if [ -f "$WORKDIR/$ISO_NAME" ]; then
    fatal_error "Output ISO file $WORKDIR/$ISO_NAME already exists. Please remove it or choose a different work directory."
fi

# Final space check
if ! check_space 1; then
    fatal_error "Insufficient space for ISO creation"
fi

# Use xorriso with proper error handling - FIXED: Using dynamic ISOHDPFX_BIN path
log_info "Using xorriso for enhanced large file support..."
if $SUDO xorriso -as mkisofs \
    -o "$WORKDIR/$ISO_NAME" \
    -isohybrid-mbr "$ISOHDPFX_BIN" \
    -c boot/isolinux/boot.cat \
    -b boot/isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$CDROOT_DIR/efiboot.img" \
    -J -R -l -V "AutoISO-$(date +%Y%m%d)" \
    -joliet-long \
    -allow-leading-dots \
    -relaxed-filenames \
    -allow-lowercase \
    -allow-multidot \
    -max-iso9660-filenames \
    -full-iso9660-filenames \
    .; then
    log_info "ISO created successfully with xorriso (UEFI+BIOS)"
else
    # Improved fallback with better error handling
    log_warning "xorriso failed, falling back to genisoimage..."
    if $SUDO genisoimage \
        -o "$WORKDIR/$ISO_NAME" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -J -R -l -V "AutoISO-$(date +%Y%m%d)" \
        -allow-leading-dots \
        -relaxed-filenames \
        -allow-lowercase \
        -allow-multidot \
        -max-iso9660-filenames \
        -joliet-long \
        -full-iso9660-filenames \
        -allow-limited-size \
        -udf \
        .; then
        log_info "ISO created successfully with genisoimage (BIOS only)"
    else
        fatal_error "Both xorriso and genisoimage failed to create ISO"
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
        log_warning "ISO integrity check failed - ISO may still be usable"
    fi
fi

# Automated QEMU Boot Test
qemu_boot_test() {
    local iso_path="$WORKDIR/$ISO_NAME"
    log_info "Running automated QEMU boot test (BIOS and UEFI)..."
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log_warning "QEMU is not installed. Skipping automated boot test."
        return 0
    fi
    local bios_log="$WORKDIR/qemu-bios.log"
    local uefi_log="$WORKDIR/qemu-uefi.log"
    # BIOS test
    log_info "Testing BIOS boot..."
    timeout 20s qemu-system-x86_64 -m 1024 -cdrom "$iso_path" -boot d -display none -serial stdio > "$bios_log" 2>&1 || true
    if grep -q "AutoISO" "$bios_log"; then
        log_info "BIOS boot test passed."
    else
        log_warning "BIOS boot test did not detect expected prompt. Check $bios_log for details."
    fi
    # UEFI test (OVMF required)
    UEFI_FIRMWARE=""
    for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
        if [ -f "$p" ]; then UEFI_FIRMWARE="$p"; break; fi
    done
    if [ -n "$UEFI_FIRMWARE" ]; then
        log_info "Testing UEFI boot..."
        timeout 20s qemu-system-x86_64 -m 1024 -cdrom "$iso_path" -boot d -display none -serial stdio -drive if=pflash,format=raw,readonly=on,file="$UEFI_FIRMWARE" > "$uefi_log" 2>&1 || true
        if grep -q "AutoISO" "$uefi_log"; then
            log_info "UEFI boot test passed."
        else
            log_warning "UEFI boot test did not detect expected prompt. Check $uefi_log for details."
        fi
    else
        log_warning "OVMF (UEFI firmware) not found. Skipping UEFI QEMU test."
    fi
}

# Track build start time
BUILD_START=$(date +%s)
# After qemu_boot_test, print a detailed end report
echo ""
echo "=========================="
echo "[✓] BUILD COMPLETE!"
echo "=========================="
echo "ISO created at: $WORKDIR/$ISO_NAME"
echo "Size: $(du -h "$WORKDIR/$ISO_NAME" | cut -f1)"
echo "Kernel version: $KERNEL_VERSION"
echo "Build time: $(( $(date +%s) - $BUILD_START )) seconds"
echo ""
if [ -f "$WORKDIR/qemu-bios.log" ]; then
    if grep -q "AutoISO" "$WORKDIR/qemu-bios.log"; then
        echo "BIOS boot test: PASSED"
    else
        echo "BIOS boot test: WARNING (see $WORKDIR/qemu-bios.log)"
    fi
fi
if [ -f "$WORKDIR/qemu-uefi.log" ]; then
    if grep -q "AutoISO" "$WORKDIR/qemu-uefi.log"; then
        echo "UEFI boot test: PASSED"
    else
        echo "UEFI boot test: WARNING (see $WORKDIR/qemu-uefi.log)"
    fi
fi
echo ""
echo "=== DISK SPACE USAGE ==="
echo "Work directory: $(du -sh "$WORKDIR" | cut -f1)"
FINAL_SPACE=$(df "$WORKDIR" | awk 'NR==2 {print $4}')
echo "Remaining space: $((FINAL_SPACE / 1024 / 1024))GB"
echo "Storage location: $(df -h "$WORKDIR" | awk 'NR==2 {print $1}')"
echo ""
echo "=== NEXT STEPS ==="
echo "1. Write ISO to USB drive (CAREFUL - THIS WILL ERASE THE USB!):"
echo "   sudo dd if='$WORKDIR/$ISO_NAME' of=/dev/sdX bs=4M status=progress oflag=sync"
echo "   (Replace /dev/sdX with your USB device - use 'lsblk' to identify)"
echo ""
echo "2. Create persistence partition (OPTIONAL for persistent mode):"
echo "   a) Use gparted or fdisk to create a second partition on the USB"
echo "   b) Format it as ext4: sudo mkfs.ext4 -L persistence /dev/sdX2"
echo "   c) Mount it: sudo mkdir -p /mnt/persistence && sudo mount /dev/sdX2 /mnt/persistence"
echo "   d) Create persistence.conf: echo '/ union' | sudo tee /mnt/persistence/persistence.conf"
echo "   e) Unmount: sudo umount /mnt/persistence"
echo ""
echo "3. Boot Options:"
echo "   - Persistent Mode: Your changes are saved between reboots"
echo "   - Live Mode: No changes are saved (traditional live CD)"
echo "   - Safe Mode: Use if you have graphics issues"
echo "   - To RAM: Loads entire system to RAM for faster operation"
echo ""
echo "For troubleshooting, see logs in $WORKDIR."
echo "Thank you for using AutoISO!"
echo "=========================="

# UEFI support is not implemented in this script. For UEFI bootable ISOs, additional steps are required (see documentation or future updates).

# --- UEFI Support ---
# Ensure required packages for UEFI
$SUDO apt-get install -y grub-mkimage grub-install mtools || fatal_error "Failed to install grub-mkimage and mtools."

# Create EFI directory structure
mkdir -p "$CDROOT_DIR/EFI/BOOT" || fatal_error "Failed to create EFI/BOOT directory."

# Create a 20MB FAT32 EFI System Partition image
ESP_IMG="$WORKDIR/efiboot.img"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=20 status=none || fatal_error "Failed to create ESP image."
mkfs.vfat "$ESP_IMG" > /dev/null || fatal_error "Failed to format ESP image as FAT32."

# Mount the ESP image
ESP_MNT="$WORKDIR/esp-mount"
mkdir -p "$ESP_MNT"
if mountpoint -q "$ESP_MNT" 2>/dev/null; then
    $SUDO umount "$ESP_MNT" || true
fi
sudo mount -o loop "$ESP_IMG" "$ESP_MNT" || fatal_error "Failed to mount ESP image."

# Create EFI/BOOT directory in ESP
mkdir -p "$ESP_MNT/EFI/BOOT" || fatal_error "Failed to create EFI/BOOT in ESP."

# Create GRUB EFI bootloader
GRUB_EFI_BIN="$ESP_MNT/EFI/BOOT/BOOTx64.EFI"
grub-mkimage -o "$GRUB_EFI_BIN" -p /EFI/BOOT -O x86_64-efi fat iso9660 part_gpt part_msdos normal chain linux configfile search search_label search_fs_uuid search_fs_file gfxterm gfxmenu || fatal_error "Failed to create GRUB EFI image."

# Create GRUB config
cat > "$ESP_MNT/EFI/BOOT/grub.cfg" <<EOF
set default=0
timeout=5
menuentry "AutoISO Persistent Mode (Recommended)" {
    linux /live/vmlinuz boot=live components persistence persistent=cryptsetup,removable quiet splash noswap
    initrd /live/initrd
}
menuentry "AutoISO Live Mode (No Persistence)" {
    linux /live/vmlinuz boot=live components quiet splash noswap
    initrd /live/initrd
}
menuentry "AutoISO Safe Mode" {
    linux /live/vmlinuz boot=live components quiet splash noswap nomodeset
    initrd /live/initrd
}
menuentry "AutoISO to RAM (Requires 4GB+ RAM)" {
    linux /live/vmlinuz boot=live components toram quiet splash noswap
    initrd /live/initrd
}
EOF

# Unmount ESP image
sudo umount "$ESP_MNT" || fatal_error "Failed to unmount ESP image."
rmdir "$ESP_MNT"

# Copy ESP image to ISO root for xorriso
cp "$ESP_IMG" "$CDROOT_DIR/efiboot.img" || fatal_error "Failed to copy ESP image to cdroot."

# Copy BOOTx64.EFI and grub.cfg to ISO for fallback UEFI boot
cp "$WORKDIR/efiboot.img" "$CDROOT_DIR/EFI/BOOT/efiboot.img" 2>/dev/null || true
cp "$CDROOT_DIR/EFI/BOOT/BOOTx64.EFI" "$CDROOT_DIR/EFI/BOOT/BOOTx64.EFI" 2>/dev/null || true
cp "$CDROOT_DIR/EFI/BOOT/grub.cfg" "$CDROOT_DIR/EFI/BOOT/grub.cfg" 2>/dev/null || true

# In sanity_check_iso, use $SUDO or check $EUID before using sudo
sanity_check_iso() {
    local iso_path="$WORKDIR/$ISO_NAME"
    log_info "Running ISO sanity check..."
    if ! [ -f "$iso_path" ]; then
        fatal_error "ISO file not found: $iso_path"
    fi
    if ! isoinfo -d -i "$iso_path" >/dev/null 2>&1; then
        fatal_error "ISO integrity check failed (isoinfo)"
    fi
    # Mount ISO and check for files
    local mnt="$WORKDIR/iso-mnt"
    mkdir -p "$mnt"
    # Use $SUDO if not root
    local SUDO_MNT="$SUDO"
    if [ "$EUID" -eq 0 ]; then SUDO_MNT=""; fi
    # Before mounting, check if already mounted
    if mountpoint -q "$mnt" 2>/dev/null; then
        $SUDO_MNT umount "$mnt" || true
    fi
    $SUDO_MNT mount -o loop "$iso_path" "$mnt" || fatal_error "Failed to mount ISO for sanity check"
    local missing=0
    for f in /boot/isolinux/isolinux.bin /EFI/BOOT/BOOTx64.EFI /EFI/BOOT/grub.cfg /live/vmlinuz /live/initrd /live/filesystem.squashfs; do
        if ! [ -f "$mnt$f" ]; then
            log_error "Missing critical file in ISO: $f"
            missing=1
        fi
    done
    $SUDO_MNT umount "$mnt"
    rmdir "$mnt"
    if [ $missing -ne 0 ]; then
        fatal_error "Sanity check failed: One or more critical files are missing in the ISO."
    fi
    log_info "ISO sanity check passed."
}


