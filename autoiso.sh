#!/bin/bash
# Ensure we're using bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires bash. Please run with: bash $0"
    exit 1
fi

# ========================================
#    O P T I M I Z E D   A U T O I S O    
# ========================================
# AutoISO - Highly Optimized Persistent Bootable Linux ISO Creator
#
# USAGE:
#   ./autoiso.sh                           # Interactive disk selection
#   ./autoiso.sh /mnt/external-drive       # Use specific disk
#   WORKDIR=/mnt/ssd/build ./autoiso.sh    # Environment variable
#
# REQUIREMENTS:
#   - At least 8GB free space on target disk (optimized)
#   - Root/sudo privileges
#   - Debian/Ubuntu-based system
#
set -euo pipefail  # Improved error handling

# Performance and optimization settings
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export LC_ALL=C
export LANG=C

# Show help if requested
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat << 'EOF'
AutoISO - Highly Optimized Persistent Bootable Linux ISO Creator

USAGE:
  ./autoiso.sh [WORK_DIRECTORY] [OPTIONS]

OPTIONS:
  --minimal         Create minimal ISO (faster, smaller)
  --fast           Skip some optimizations for speed
  --compression     Compression level (1-9, default: 6)
  --exclude-home   Exclude /home directory
  --help           Show this help

EXAMPLES:
  ./autoiso.sh                                    # Interactive selection
  ./autoiso.sh /mnt/external-drive               # Use external drive
  ./autoiso.sh /tmp/build --minimal              # Minimal ISO
  ./autoiso.sh /home/user/iso-build --fast       # Fast build

ENVIRONMENT VARIABLES:
  WORKDIR          Set work directory
  COMPRESSION      Compression level (1-9)
  THREADS          Number of threads (default: all cores)

REQUIREMENTS:
  - 8GB+ free space (optimized from 15GB)
  - Root/sudo privileges
  - Debian/Ubuntu-based system

The script will create a subdirectory 'autoiso-build' in your chosen location.
EOF
    exit 0
fi

# Parse command line arguments
MINIMAL_BUILD=false
FAST_BUILD=false
COMPRESSION_LEVEL=6
EXCLUDE_HOME=false
THREADS=$(nproc)

while [[ $# -gt 0 ]]; do
    case $1 in
        --minimal)
            MINIMAL_BUILD=true
            shift
            ;;
        --fast)
            FAST_BUILD=true
            shift
            ;;
        --compression)
            COMPRESSION_LEVEL="$2"
            shift 2
            ;;
        --exclude-home)
            EXCLUDE_HOME=true
            shift
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "${WORKDIR_ARG:-}" ]; then
                WORKDIR_ARG="$1"
            fi
            shift
            ;;
    esac
done

# Validate compression level
if [[ ! "$COMPRESSION_LEVEL" =~ ^[1-9]$ ]]; then
    echo "Error: Compression level must be 1-9"
    exit 1
fi

### Configuration with optimizations
if [ -n "${WORKDIR_ARG:-}" ]; then
    WORKDIR="$WORKDIR_ARG/autoiso-build"
elif [ -n "${WORKDIR:-}" ]; then
    WORKDIR="${WORKDIR}/autoiso-build"
else
    # Smart disk selection
    echo "=== AutoISO Optimized Disk Selection ==="
    echo "Analyzing available storage..."
    
    # Find best disk automatically
    BEST_DISK=""
    BEST_SPACE=0
    
    while IFS= read -r line; do
        if [[ $line =~ ^/dev/ ]]; then
            DISK=$(echo "$line" | awk '{print $1}')
            SPACE=$(echo "$line" | awk '{print $4}' | sed 's/[^0-9]//g')
            SPACE_GB=$((SPACE / 1024 / 1024))
            
            echo "  $DISK: ${SPACE_GB}GB available"
            
            if [ "$SPACE" -gt "$BEST_SPACE" ] && [ "$SPACE_GB" -gt 8 ]; then
                BEST_DISK="$DISK"
                BEST_SPACE="$SPACE"
            fi
        fi
    done < <(df -k | grep -E "^/dev")
    
    if [ -n "$BEST_DISK" ]; then
        WORKDIR="$(df "$BEST_DISK" | awk 'NR==2 {print $6}')/autoiso-$(date +%s)"
        echo "Auto-selected: $BEST_DISK ($(($BEST_SPACE / 1024 / 1024))GB)"
    else
        echo "No suitable disk found with 8GB+ space"
        read -p "Enter work directory path: " user_workdir
        WORKDIR="${user_workdir:-/tmp/autoiso-$(date +%s)}"
    fi
fi

# Ensure workdir is absolute path and unique
WORKDIR=$(realpath "$WORKDIR" 2>/dev/null || echo "$WORKDIR")
EXTRACT_DIR="$WORKDIR/extract"
CDROOT_DIR="$WORKDIR/cdroot"
ISO_NAME="autoiso-$(hostname)-$(date +%Y%m%d-%H%M).iso"

echo ""
echo "=== Optimized Build Configuration ==="
echo "Work Directory: $WORKDIR"
echo "Build Mode: $([ "$MINIMAL_BUILD" = true ] && echo "MINIMAL" || echo "FULL")"
echo "Speed Mode: $([ "$FAST_BUILD" = true ] && echo "FAST" || echo "OPTIMIZED")"
echo "Compression: Level $COMPRESSION_LEVEL"
echo "Threads: $THREADS"
echo "Final ISO: $WORKDIR/$ISO_NAME"
echo ""

# Optimized kernel detection with caching
KERNEL_VERSION=$(uname -r)
KERNEL_CACHE="/tmp/autoiso-kernel-$KERNEL_VERSION"

if [ -f "$KERNEL_CACHE" ]; then
    source "$KERNEL_CACHE"
else
    # Find best kernel and initrd
    KERNEL_FILE=""
    INITRD_FILE=""
    
    # Priority order for kernels
    for kernel_path in \
        "/boot/vmlinuz-$KERNEL_VERSION" \
        "/boot/vmlinuz" \
        "/boot/kernel-$KERNEL_VERSION" \
        $(find /boot -name "vmlinuz*" | head -1); do
        if [ -f "$kernel_path" ]; then
            KERNEL_FILE="$kernel_path"
            break
        fi
    done
    
    # Priority order for initrd
    for initrd_path in \
        "/boot/initrd.img-$KERNEL_VERSION" \
        "/boot/initramfs-$KERNEL_VERSION.img" \
        "/boot/initrd.img" \
        "/boot/initramfs.img" \
        $(find /boot -name "initrd*" -o -name "initramfs*" | head -1); do
        if [ -f "$initrd_path" ]; then
            INITRD_FILE="$initrd_path"
            break
        fi
    done
    
    # Cache the results
    echo "KERNEL_FILE='$KERNEL_FILE'" > "$KERNEL_CACHE"
    echo "INITRD_FILE='$INITRD_FILE'" >> "$KERNEL_CACHE"
fi

# Optimized exclusion patterns
BASE_EXCLUDES=(
    "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*"
    "/lost+found" "/var/cache/*" "/var/log/*" "/var/tmp/*"
    "/root/.cache/*" "/swapfile" "/pagefile.sys" "*.log"
    "/var/lib/systemd/coredump/*" "/var/crash/*"
    "${WORKDIR}/*"
)

OPTIMIZATION_EXCLUDES=(
    "/var/lib/docker/*" "/var/lib/containerd/*" "/snap/*" "/var/snap/*"
    "/usr/src/*" "/var/lib/apt/lists/*" "/var/backups/*"
    "/var/lib/lxcfs/*" "/var/spool/*" "/boot/efi/*"
    "/var/lib/flatpak/*" "/var/lib/snapd/*"
    "/usr/share/doc/*" "/usr/share/man/*" "/usr/share/info/*"
    "/usr/share/locale/*" "/var/lib/locales/*"
)

AGGRESSIVE_EXCLUDES=(
    "/usr/share/fonts/*" "/usr/lib/firmware/*"
    "/lib/modules/*/kernel/drivers/gpu/*"
    "/lib/modules/*/kernel/sound/*"
    "/usr/share/pixmaps/*" "/usr/share/icons/*/scalable/*"
)

# Build exclusion list based on mode
EXCLUDE_DIRS=("${BASE_EXCLUDES[@]}")

if [ "$EXCLUDE_HOME" = true ]; then
    EXCLUDE_DIRS+=("/home/*")
fi

if [ "$FAST_BUILD" = false ]; then
    EXCLUDE_DIRS+=("${OPTIMIZATION_EXCLUDES[@]}")
fi

if [ "$MINIMAL_BUILD" = true ]; then
    EXCLUDE_DIRS+=("${AGGRESSIVE_EXCLUDES[@]}")
fi

### Optimized Functions
log_info() {
    echo "[$(date +'%H:%M:%S')] $1"
}

log_error() {
    echo "[$(date +'%H:%M:%S')] ERROR: $1" >&2
}

log_warning() {
    echo "[$(date +'%H:%M:%S')] WARNING: $1" >&2
}

# Optimized space checking with caching
check_space() {
    local min_space_gb=${1:-2}
    local min_space_kb=$((min_space_gb * 1024 * 1024))
    
    # Use cached df result if recent
    local df_cache="/tmp/autoiso-df-$(stat -c %Y "$WORKDIR" 2>/dev/null || echo 0)"
    if [ -f "$df_cache" ] && [ $(($(date +%s) - $(stat -c %Y "$df_cache"))) -lt 30 ]; then
        local space=$(cat "$df_cache")
    else
        local space=$(df "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
        echo "$space" > "$df_cache"
    fi
    
    local space_gb=$((space / 1024 / 1024))
    
    if [ "$space" -lt "$min_space_kb" ]; then
        log_error "Insufficient space: ${space_gb}GB available, ${min_space_gb}GB required"
        return 1
    fi
    
    log_info "Available space: ${space_gb}GB"
    return 0
}

# Optimized cleanup with parallel unmounting
cleanup_mounts() {
    log_info "Cleaning up mounts..."
    local mounts=("$EXTRACT_DIR/dev/pts" "$EXTRACT_DIR/dev" "$EXTRACT_DIR/proc" "$EXTRACT_DIR/sys")
    
    for mount in "${mounts[@]}"; do
        $SUDO umount "$mount" 2>/dev/null || true &
    done
    wait
}

# Parallel package installation
install_packages() {
    log_info "Installing packages with optimizations..."
    
    # Pre-configure to avoid interactive prompts
    echo 'debconf debconf/frontend select Noninteractive' | $SUDO debconf-set-selections
    
    # Update with minimal output
    $SUDO apt-get update -o Acquire::Languages=none -o APT::Get::List-Cleanup=no -qq
    
    # Install with optimizations
    $SUDO apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confnew" \
        -o APT::Install-Suggests=0 \
        -o APT::Install-Recommends=0 \
        genisoimage isolinux syslinux syslinux-utils \
        squashfs-tools xorriso rsync \
        live-boot live-boot-initramfs-tools live-config live-config-systemd
}

# Optimized file copying with intelligence
smart_copy() {
    log_info "Starting intelligent system copy..."
    
    # Build exclude arguments
    local exclude_args=()
    for dir in "${EXCLUDE_DIRS[@]}"; do
        exclude_args+=(--exclude="$dir")
    done
    
    # Optimized rsync options
    local rsync_opts=(
        -aHAX                    # Archive with hard links, ACLs, xattrs
        --progress              # Progress display
        --numeric-ids           # Preserve numeric IDs
        --one-file-system       # Don't cross filesystems
        --prune-empty-dirs      # Skip empty directories
        --delete-excluded       # Remove excluded files
    )
    
    # Add compression only for slow storage
    if [ "$FAST_BUILD" = false ]; then
        rsync_opts+=(--compress --compress-level="$COMPRESSION_LEVEL")
    fi
    
    # Execute with timeout and retry logic
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if timeout 3600 $SUDO rsync "${rsync_opts[@]}" "${exclude_args[@]}" / "$EXTRACT_DIR/"; then
            break
        else
            log_warning "Rsync attempt $attempt failed, retrying..."
            attempt=$((attempt + 1))
            sleep 5
        fi
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log_error "All rsync attempts failed"
        return 1
    fi
}

# Parallel cleanup operations
optimize_extracted_system() {
    log_info "Optimizing extracted system..."
    
    # Cleanup operations in parallel
    {
        # Remove broken symlinks
        find "$EXTRACT_DIR" -xtype l -delete 2>/dev/null || true
    } &
    
    {
        # Clean package caches
        $SUDO rm -rf "$EXTRACT_DIR/var/lib/apt/lists"/* 2>/dev/null || true
        $SUDO rm -rf "$EXTRACT_DIR/var/cache/apt"/* 2>/dev/null || true
    } &
    
    {
        # Clean logs and temporary files
        $SUDO find "$EXTRACT_DIR" -name "*.log" -size +1M -delete 2>/dev/null || true
        $SUDO find "$EXTRACT_DIR/tmp" -type f -delete 2>/dev/null || true
    } &
    
    {
        # Remove problematic directories
        local problematic_dirs=(
            "$EXTRACT_DIR/var/lib/docker" "$EXTRACT_DIR/var/lib/containerd"
            "$EXTRACT_DIR/snap" "$EXTRACT_DIR/var/snap"
            "$EXTRACT_DIR/usr/src" "$EXTRACT_DIR/root/.cache"
        )
        
        for dir in "${problematic_dirs[@]}"; do
            [ -d "$dir" ] && $SUDO rm -rf "$dir" 2>/dev/null || true
        done
    } &
    
    wait  # Wait for all cleanup operations
    
    # Ensure essential directories exist
    $SUDO mkdir -p "$EXTRACT_DIR"/{dev,proc,sys,run,tmp,var/tmp}
    $SUDO chmod 1777 "$EXTRACT_DIR"/{tmp,var/tmp} 2>/dev/null || true
}

# High-performance SquashFS creation
create_squashfs() {
    log_info "Creating optimized SquashFS filesystem..."
    
    if ! check_space 2; then
        log_error "Insufficient space for SquashFS creation"
        return 1
    fi
    
    # Determine optimal compression based on mode
    local comp_algo="xz"
    local comp_opts="-Xbcj x86 -Xdict-size 100%"
    
    if [ "$FAST_BUILD" = true ]; then
        comp_algo="lz4"
        comp_opts=""
    elif [ "$MINIMAL_BUILD" = true ]; then
        comp_opts="-Xbcj x86 -Xdict-size 100% -b 256K"
    fi
    
    # Create SquashFS with optimal settings
    $SUDO mksquashfs "$EXTRACT_DIR" "$CDROOT_DIR/live/filesystem.squashfs" \
        -e boot \
        -no-exports -no-sparse -noappend \
        -comp "$comp_algo" $comp_opts \
        -processors "$THREADS" \
        -mem 512M \
        -progress \
        2>/dev/null || {
        log_warning "High-performance mksquashfs failed, trying basic mode..."
        $SUDO mksquashfs "$EXTRACT_DIR" "$CDROOT_DIR/live/filesystem.squashfs" \
            -e boot -noappend -processors "$THREADS"
    }
}

# Optimized bootloader setup with caching
setup_bootloader() {
    log_info "Setting up optimized bootloader..."
    
    # Cache bootloader files detection
    local bootloader_cache="/tmp/autoiso-bootloader"
    if [ -f "$bootloader_cache" ]; then
        source "$bootloader_cache"
    else
        # Find bootloader files
        ISOLINUX_BIN=""
        SYSLINUX_MODULES=""
        MBR_BIN=""
        
        for path in /usr/lib/isolinux /usr/lib/ISOLINUX /usr/share/isolinux; do
            [ -f "$path/isolinux.bin" ] && ISOLINUX_BIN="$path/isolinux.bin" && break
        done
        
        for path in /usr/lib/syslinux/modules/bios /usr/share/syslinux /usr/lib/syslinux; do
            [ -d "$path" ] && [ -f "$path/menu.c32" ] && SYSLINUX_MODULES="$path" && break
        done
        
        for path in /usr/lib/syslinux/mbr /usr/lib/ISOLINUX /usr/share/syslinux; do
            [ -f "$path/isohdpfx.bin" ] && MBR_BIN="$path/isohdpfx.bin" && break
        done
        
        # Cache results
        cat > "$bootloader_cache" << EOF
ISOLINUX_BIN='$ISOLINUX_BIN'
SYSLINUX_MODULES='$SYSLINUX_MODULES'
MBR_BIN='$MBR_BIN'
EOF
    fi
    
    [ -z "$ISOLINUX_BIN" ] && { log_error "isolinux.bin not found"; return 1; }
    [ -z "$SYSLINUX_MODULES" ] && { log_error "Syslinux modules not found"; return 1; }
    
    # Copy bootloader files
    $SUDO cp "$ISOLINUX_BIN" "$CDROOT_DIR/boot/isolinux/"
    
    # Copy essential modules
    for module in menu.c32 chain.c32 reboot.c32 poweroff.c32 libutil.c32 libcom32.c32; do
        [ -f "$SYSLINUX_MODULES/$module" ] && $SUDO cp "$SYSLINUX_MODULES/$module" "$CDROOT_DIR/boot/isolinux/"
    done
    
    # Create optimized boot configuration
    cat > /tmp/isolinux.cfg << 'EOF'
UI menu.c32
PROMPT 0
MENU TITLE AutoISO Optimized Live System
MENU COLOR screen 37;40
MENU COLOR border 30;44
MENU COLOR title 1;36;44
TIMEOUT 150
DEFAULT live

LABEL live
  MENU LABEL ^Live Mode (Fast Boot)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso quiet splash

LABEL persistent  
  MENU LABEL ^Persistent Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistence locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso quiet splash

LABEL safe
  MENU LABEL ^Safe Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso nomodeset noapic acpi=off

LABEL toram
  MENU LABEL Load to ^RAM
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram locales=en_US.UTF-8 keyboard-layouts=us username=user hostname=autoiso quiet splash

MENU SEPARATOR

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL ^Power Off
  COM32 poweroff.c32
EOF
    
    $SUDO mv /tmp/isolinux.cfg "$CDROOT_DIR/boot/isolinux/isolinux.cfg"
    $SUDO touch "$CDROOT_DIR/boot/isolinux/boot.cat"
}

# Optimized ISO creation with multiple methods
create_iso() {
    log_info "Creating optimized hybrid ISO..."
    
    cd "$CDROOT_DIR"
    
    if ! check_space 1; then
        log_error "Insufficient space for ISO creation"
        return 1
    fi
    
    # Try xorriso first (best method)
    if command -v xorriso >/dev/null 2>&1 && [ -n "$MBR_BIN" ]; then
        log_info "Using xorriso with hybrid EFI/BIOS support..."
        
        $SUDO xorriso -as mkisofs \
            -r -V "AutoISO-$(date +%Y%m%d)" \
            -o "$WORKDIR/$ISO_NAME" \
            -J -joliet-long \
            -isohybrid-mbr "$MBR_BIN" \
            -partition_offset 16 \
            -c boot/isolinux/boot.cat \
            -b boot/isolinux/isolinux.bin \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -eltorito-alt-boot \
            . 2>/dev/null || {
            log_warning "xorriso failed, trying genisoimage..."
            create_iso_fallback
        }
    else
        create_iso_fallback
    fi
    
    # Make hybrid bootable
    if command -v isohybrid >/dev/null 2>&1; then
        $SUDO isohybrid "$WORKDIR/$ISO_NAME" 2>/dev/null || true
    fi
    
    # Set proper permissions
    $SUDO chmod 644 "$WORKDIR/$ISO_NAME"
}

create_iso_fallback() {
    log_info "Using genisoimage fallback..."
    $SUDO genisoimage \
        -o "$WORKDIR/$ISO_NAME" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -J -R -V "AutoISO-$(date +%Y%m%d)" \
        .
}

### Main execution with performance monitoring
main() {
    local start_time=$(date +%s)
    
    # Validation
    log_info "Validating system requirements..."
    
    if [ "$EUID" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
    
    [ ! -f "$KERNEL_FILE" ] && { log_error "Kernel not found: $KERNEL_FILE"; exit 1; }
    [ ! -f "$INITRD_FILE" ] && { log_error "Initrd not found: $INITRD_FILE"; exit 1; }
    
    log_info "Kernel: $KERNEL_FILE"
    log_info "Initrd: $INITRD_FILE"
    
    # Create work directories
    mkdir -p "$WORKDIR" || { log_error "Cannot create work directory"; exit 1; }
    
    if ! check_space 8; then
        log_error "Need at least 8GB free space"
        exit 1
    fi
    
    # Clean previous build
    log_info "Preparing build environment..."
    $SUDO rm -rf "$WORKDIR"/{extract,cdroot} 2>/dev/null || true
    mkdir -p "$EXTRACT_DIR" "$CDROOT_DIR/boot/isolinux" "$CDROOT_DIR/live"
    
    # Install dependencies
    install_packages
    
    # Main build process
    smart_copy
    optimize_extracted_system
    
    # Setup chroot and configure live system
    log_info "Configuring live system..."
    $SUDO mount --bind /dev "$EXTRACT_DIR/dev"
    $SUDO mount --bind /proc "$EXTRACT_DIR/proc"  
    $SUDO mount --bind /sys "$EXTRACT_DIR/sys"
    
    trap cleanup_mounts EXIT
    
    # Minimal chroot configuration for speed
    $SUDO chroot "$EXTRACT_DIR" bash -c "
        apt-get update -qq || true
        
        # Create live user
        if ! id -u user >/dev/null 2>&1; then
            useradd -m -s /bin/bash -G sudo user
            echo 'user:live' | chpasswd
        fi
        
        # Essential packages only
        apt-get install -y --no-install-recommends live-boot live-config || true
        
        # Configure autologin
        mkdir -p /etc/systemd/system/getty@tty1.service.d/
        echo -e '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin user --noclear %I \$TERM' > /etc/systemd/system/getty@tty1.service.d/autologin.conf
        
        # Cleanup
        apt-get clean
        rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
        history -c
    " 2>/dev/null || log_warning "Some chroot operations failed"
    
    cleanup_mounts
    trap - EXIT
    
    # Create filesystem and bootloader
    create_squashfs
    
    # Copy kernel files
    $SUDO cp "$KERNEL_FILE" "$CDROOT_DIR/live/vmlinuz"
    $SUDO cp "$INITRD_FILE" "$CDROOT_DIR/live/initrd"
    
    setup_bootloader
    create_iso
    
    # Performance summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    echo ""
    echo "=============================="
    echo "[✓] OPTIMIZED BUILD COMPLETE!"
    echo "=============================="
    echo "ISO: $WORKDIR/$ISO_NAME"
    echo "Size: $(du -h "$WORKDIR/$ISO_NAME" | cut -f1)"
    echo "Build time: ${minutes}m ${seconds}s"
    echo "Compression: Level $COMPRESSION_LEVEL"
    echo "Threads used: $THREADS"
    echo ""
    echo "=== QUICK START ==="
    echo "Write to USB: sudo dd if='$WORKDIR/$ISO_NAME' of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "Test in VM: qemu-system-x86_64 -cdrom '$WORKDIR/$ISO_NAME' -m 2048"
    echo "Login: user/live (has sudo)"
    echo ""
    echo "=== PERFORMANCE TIPS ==="
    echo "• Use SSD storage for 3x faster builds"
    echo "• Add --minimal for smaller ISO"
    echo "• Add --fast for quicker builds"
    echo "• Use --compression 1 for fastest compression"
    echo ""
    echo "=== CLEANUP ==="
    echo "Free space: sudo rm -rf '$WORKDIR'"
    echo "=============================="
}

# Execute main function
main "$@"
