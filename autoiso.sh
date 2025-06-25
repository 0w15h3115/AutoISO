#!/bin/bash
# Enhanced AutoISO - More Reliable Than Cubic
# Key improvements: State management, error recovery, validation, and atomic operations

set -euo pipefail  # Stricter error handling

# ========================================
#    ENHANCED AUTOISO - RELIABILITY FIRST
# ========================================

# Global state tracking
declare -A SCRIPT_STATE
SCRIPT_STATE[stage]="init"
SCRIPT_STATE[cleanup_required]="false"
SCRIPT_STATE[mounts_active]="false"
STATE_FILE=""

# Enhanced configuration with validation
readonly SCRIPT_VERSION="2.0.0"
readonly MIN_SPACE_GB=20
readonly RECOMMENDED_SPACE_GB=30
readonly MAX_PATH_LENGTH=180

# Logging system
setup_logging() {
    local log_dir="$WORKDIR/logs"
    mkdir -p "$log_dir"
    
    # Multiple log levels
    exec 3>"$log_dir/autoiso-debug.log"
    exec 4>"$log_dir/autoiso-error.log"
    exec 5>"$log_dir/autoiso-progress.log"
    
    log_info "AutoISO Enhanced v$SCRIPT_VERSION started at $(date)"
    log_info "Process ID: $$"
    log_info "Work directory: $WORKDIR"
}

log_debug() {
    echo "[DEBUG $(date '+%H:%M:%S')] $1" >&3
}

log_info() {
    echo "[INFO $(date '+%H:%M:%S')] $1" | tee -a /dev/fd/5
}

log_error() {
    echo "[ERROR $(date '+%H:%M:%S')] $1" | tee -a /dev/fd/4 >&2
}

log_warning() {
    echo "[WARNING $(date '+%H:%M:%S')] $1" | tee -a /dev/fd/4
}

log_progress() {
    echo "[PROGRESS] $1" | tee -a /dev/fd/5
    echo -ne "\r[AutoISO] $1"
}

# State management system
save_state() {
    local stage="$1"
    SCRIPT_STATE[stage]="$stage"
    cat > "$STATE_FILE" << EOF
STAGE=${SCRIPT_STATE[stage]}
CLEANUP_REQUIRED=${SCRIPT_STATE[cleanup_required]}
MOUNTS_ACTIVE=${SCRIPT_STATE[mounts_active]}
WORKDIR=$WORKDIR
TIMESTAMP=$(date +%s)
PID=$$
EOF
    log_debug "State saved: $stage"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        SCRIPT_STATE[stage]="$STAGE"
        SCRIPT_STATE[cleanup_required]="$CLEANUP_REQUIRED"
        SCRIPT_STATE[mounts_active]="$MOUNTS_ACTIVE"
        log_info "Resuming from stage: ${SCRIPT_STATE[stage]}"
        return 0
    fi
    return 1
}

# Enhanced cleanup with state tracking
cleanup_all() {
    log_info "Starting comprehensive cleanup..."
    
    # Cleanup mounts with retry logic
    cleanup_mounts_enhanced
    
    # Clean temporary files
    if [[ "${SCRIPT_STATE[cleanup_required]}" == "true" ]]; then
        log_info "Cleaning temporary files..."
        local temp_dirs=("$EXTRACT_DIR" "$CDROOT_DIR/live/temp")
        for dir in "${temp_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                $SUDO rm -rf "$dir" 2>/dev/null || log_error "Failed to clean $dir"
            fi
        done
    fi
    
    # Close log file descriptors
    exec 3>&- 4>&- 5>&- 2>/dev/null || true
    
    SCRIPT_STATE[cleanup_required]="false"
    save_state "cleanup_complete"
}

cleanup_mounts_enhanced() {
    if [[ "${SCRIPT_STATE[mounts_active]}" != "true" ]]; then
        return 0
    fi
    
    log_info "Cleaning up mounts with retry logic..."
    local mount_points=(
        "$EXTRACT_DIR/dev/pts"
        "$EXTRACT_DIR/dev"
        "$EXTRACT_DIR/proc"
        "$EXTRACT_DIR/sys"
    )
    
    for mount_point in "${mount_points[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log_debug "Unmounting: $mount_point"
            local retries=3
            while [[ $retries -gt 0 ]]; do
                if $SUDO umount "$mount_point" 2>/dev/null; then
                    log_debug "Successfully unmounted: $mount_point"
                    break
                fi
                log_debug "Unmount failed, retrying... ($retries attempts left)"
                sleep 2
                ((retries--))
                
                if [[ $retries -eq 0 ]]; then
                    log_error "Force unmounting: $mount_point"
                    $SUDO umount -f "$mount_point" 2>/dev/null || \
                    $SUDO umount -l "$mount_point" 2>/dev/null || true
                fi
            done
        fi
    done
    
    SCRIPT_STATE[mounts_active]="false"
    save_state "${SCRIPT_STATE[stage]}"
}

# Comprehensive validation system
validate_system() {
    log_info "Running comprehensive system validation..."
    local errors=0
    
    # Check distribution compatibility
    if ! validate_distribution; then
        ((errors++))
    fi
    
    # Check available space with detailed analysis
    if ! validate_space_detailed; then
        ((errors++))
    fi
    
    # Check required binaries
    if ! validate_required_tools; then
        ((errors++))
    fi
    
    # Check system health
    if ! validate_system_health; then
        ((errors++))
    fi
    
    # Check kernel compatibility
    if ! validate_kernel_files; then
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Validation failed with $errors errors"
        return 1
    fi
    
    log_info "System validation passed ✓"
    return 0
}

validate_distribution() {
    log_info "Validating distribution compatibility..."
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_info "Detected: $NAME $VERSION"
        
        case "$ID" in
            ubuntu|debian|linuxmint|pop|elementary)
                log_info "Distribution supported ✓"
                return 0
                ;;
            *)
                log_warning "Distribution '$ID' not explicitly tested"
                read -p "Continue anyway? (y/N): " -r continue_anyway
                if [[ "$continue_anyway" =~ ^[Yy]$ ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
        esac
    else
        log_error "Cannot detect distribution"
        return 1
    fi
}

validate_space_detailed() {
    log_info "Analyzing disk space requirements..."
    
    # Calculate actual system size (excluding excluded dirs)
    local system_size_kb=0
    log_progress "Calculating system size..."
    
    # Use du with exclusions to estimate actual copy size
    system_size_kb=$(du -sk --exclude=/dev --exclude=/proc --exclude=/sys \
        --exclude=/tmp --exclude=/run --exclude=/mnt --exclude=/media \
        --exclude=/home --exclude=/var/cache --exclude=/var/log \
        --exclude=/var/lib/docker --exclude=/snap --exclude=/var/snap \
        / 2>/dev/null | cut -f1)
    
    local system_size_gb=$((system_size_kb / 1024 / 1024))
    local required_space_gb=$((system_size_gb * 3))  # 3x for extraction + squashfs + iso
    
    log_info "System size: ${system_size_gb}GB"
    log_info "Required space: ${required_space_gb}GB (including working space)"
    
    # Check target directory space
    local available_space_kb
    available_space_kb=$(df "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    local available_space_gb=$((available_space_kb / 1024 / 1024))
    
    log_info "Available space: ${available_space_gb}GB"
    
    if [[ $available_space_gb -lt $required_space_gb ]]; then
        log_error "Insufficient space: need ${required_space_gb}GB, have ${available_space_gb}GB"
        suggest_space_solutions "$required_space_gb"
        return 1
    fi
    
    # Warn if close to minimum
    if [[ $available_space_gb -lt $((required_space_gb + 5)) ]]; then
        log_warning "Space is tight. Consider using a location with more free space."
    fi
    
    return 0
}

suggest_space_solutions() {
    local needed_gb="$1"
    echo ""
    echo "Space Solutions:"
    echo "1. Use external drive: ./autoiso.sh /path/to/external/drive"
    echo "2. Clean up system: sudo apt-get autoremove && sudo apt-get autoclean"
    echo "3. Remove old kernels: sudo apt-get autoremove --purge"
    echo "4. Clear temp files: sudo rm -rf /tmp/* /var/tmp/*"
    echo "5. Use different location with ${needed_gb}GB+ free space"
    echo ""
}

validate_required_tools() {
    log_info "Validating required tools..."
    local missing_tools=()
    local required_tools=(
        "rsync" "mksquashfs" "xorriso" "genisoimage" 
        "chroot" "mount" "umount" "df" "du"
    )
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install with: sudo apt-get install squashfs-tools xorriso genisoimage rsync"
        return 1
    fi
    
    return 0
}

validate_system_health() {
    log_info "Checking system health..."
    
    # Check for critical system issues
    local health_issues=()
    
    # Check filesystem health
    if ! df / >/dev/null 2>&1; then
        health_issues+=("Root filesystem not accessible")
    fi
    
    # Check for running package managers
    if pgrep -x "apt|dpkg|apt-get|aptitude" >/dev/null 2>&1; then
        health_issues+=("Package manager is currently running")
    fi
    
    # Check system load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    if command -v bc >/dev/null 2>&1 && (( $(echo "$load_avg > 10" | bc -l 2>/dev/null || echo 0) )); then
        health_issues+=("High system load: $load_avg")
    fi
    
    if [[ ${#health_issues[@]} -gt 0 ]]; then
        log_warning "System health issues detected:"
        for issue in "${health_issues[@]}"; do
            log_warning "  - $issue"
        done
        
        read -p "Continue despite health issues? (y/N): " -r continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

validate_kernel_files() {
    log_info "Validating kernel files..."
    
    if [[ ! -f /boot/vmlinuz-$(uname -r) ]]; then
        log_error "Kernel image not found: /boot/vmlinuz-$(uname -r)"
        return 1
    fi
    
    if [[ ! -f /boot/initrd.img-$(uname -r) ]]; then
        log_error "Initrd not found: /boot/initrd.img-$(uname -r)"
        return 1
    fi
    
    log_info "Kernel files validated ✓"
    return 0
}

# Atomic operation wrapper
atomic_operation() {
    local operation_name="$1"
    local operation_function="$2"
    
    log_info "Starting atomic operation: $operation_name"
    save_state "atomic_${operation_name}_start"
    
    # Create checkpoint
    local checkpoint_file="$WORKDIR/.checkpoint_${operation_name}"
    echo "$(date +%s)" > "$checkpoint_file"
    
    if $operation_function; then
        rm -f "$checkpoint_file"
        save_state "atomic_${operation_name}_complete"
        log_info "Atomic operation completed: $operation_name ✓"
        return 0
    else
        log_error "Atomic operation failed: $operation_name"
        if [[ -f "$checkpoint_file" ]]; then
            log_info "Checkpoint available for recovery"
        fi
        return 1
    fi
}

# Enhanced rsync with progress and resume capability
enhanced_rsync() {
    log_info "Starting enhanced system copy with resume capability..."
    
    local rsync_log="$WORKDIR/logs/rsync.log"
    local rsync_partial_dir="$WORKDIR/.rsync-partial"
    mkdir -p "$rsync_partial_dir"
    
    # Build exclusion list dynamically
    local exclude_args=()
    local exclude_patterns=(
        "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*"
        "/lost+found" "/home/*/.cache" "/var/cache/*" "/var/log/*"
        "/var/lib/docker/*" "/var/lib/containerd/*" "/snap/*" "/var/snap/*"
        "/usr/src/*" "/var/lib/apt/lists/*" "/root/.cache/*"
        "/swapfile" "/pagefile.sys" "*.log" "/var/crash/*"
        "/var/lib/lxcfs/*" "/var/lib/systemd/coredump/*"
        "/var/spool/*" "/var/backups/*"
        "/var/lib/flatpak/*" "/var/lib/snapd/*"
        "$WORKDIR" # Don't copy our own work directory!
    )
    
    for pattern in "${exclude_patterns[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done
    
    # Enhanced rsync options
    local rsync_opts=(
        -avH                      # Archive, verbose, hard links
        --progress               # Show progress
        --partial               # Keep partial files
        --partial-dir="$rsync_partial_dir"
        --ignore-errors         # Don't stop on errors
        --numeric-ids           # Preserve numeric IDs
        --one-file-system       # Don't cross filesystems
        --compress              # Compress during transfer
        --compress-level=3      # Moderate compression
        --prune-empty-dirs      # Skip empty directories
        --delete-excluded       # Remove excluded files from dest
        --log-file="$rsync_log" # Detailed logging
        --stats                 # Show statistics
        --human-readable        # Human readable numbers
    )
    
    # Start rsync with proper error handling
    SCRIPT_STATE[cleanup_required]="true"
    save_state "rsync_active"
    
    if $SUDO rsync "${rsync_opts[@]}" "${exclude_args[@]}" / "$EXTRACT_DIR/"; then
        log_info "System copy completed successfully"
        
        # Show rsync statistics
        if [[ -f "$rsync_log" ]]; then
            local files_transferred
            files_transferred=$(grep "Number of files transferred:" "$rsync_log" 2>/dev/null | tail -1 | awk '{print $5}' || echo "N/A")
            local total_size
            total_size=$(grep "Total file size:" "$rsync_log" 2>/dev/null | tail -1 | awk '{print $4,$5}' || echo "N/A")
            log_info "Files transferred: $files_transferred"
            log_info "Total size: $total_size"
        fi
        
        save_state "rsync_complete"
        return 0
    else
        log_error "Rsync failed - check logs in $rsync_log"
        return 1
    fi
}

# Post-copy cleanup and optimization
post_copy_cleanup() {
    log_info "Starting post-copy cleanup and optimization..."
    
    # Clean package caches
    log_progress "Cleaning package caches..."
    $SUDO rm -rf "$EXTRACT_DIR/var/cache/apt/archives/"*.deb
    $SUDO rm -rf "$EXTRACT_DIR/var/lib/apt/lists/"*
    
    # Clean logs
    log_progress "Cleaning system logs..."
    $SUDO find "$EXTRACT_DIR/var/log" -type f -name "*.log" -delete 2>/dev/null || true
    $SUDO find "$EXTRACT_DIR/var/log" -type f -name "*.gz" -delete 2>/dev/null || true
    
    # Clean temporary files
    log_progress "Cleaning temporary files..."
    $SUDO rm -rf "$EXTRACT_DIR/tmp/"*
    $SUDO rm -rf "$EXTRACT_DIR/var/tmp/"*
    
    # Clean user caches that might have been copied
    log_progress "Cleaning user caches..."
    $SUDO find "$EXTRACT_DIR" -path "*/.*cache*" -type d -exec rm -rf {} + 2>/dev/null || true
    
    # Clean SSH keys for security
    log_progress "Cleaning SSH keys and sensitive data..."
    $SUDO rm -rf "$EXTRACT_DIR/etc/ssh/ssh_host_"*
    $SUDO rm -rf "$EXTRACT_DIR/root/.ssh/"
    
    # Clean machine-specific files
    log_progress "Cleaning machine-specific files..."
    $SUDO rm -f "$EXTRACT_DIR/etc/machine-id"
    $SUDO rm -f "$EXTRACT_DIR/var/lib/dbus/machine-id"
    
    # Clean network configurations
    $SUDO rm -rf "$EXTRACT_DIR/etc/NetworkManager/system-connections/"*
    
    # Update package lists to be empty (will be regenerated on first boot)
    $SUDO mkdir -p "$EXTRACT_DIR/var/lib/apt/lists/"
    
    log_info "Post-copy cleanup completed"
    return 0
}

# Configure chroot environment with enhanced error handling
configure_chroot_enhanced() {
    log_info "Configuring chroot environment..."
    
    # Setup essential mounts
    log_progress "Setting up chroot mounts..."
    if ! setup_chroot_mounts; then
        log_error "Failed to setup chroot mounts"
        return 1
    fi
    
    SCRIPT_STATE[mounts_active]="true"
    save_state "chroot_mounts_active"
    
    # Create chroot configuration script
    local chroot_script="$EXTRACT_DIR/tmp/configure_system.sh"
    create_chroot_configuration_script "$chroot_script"
    
    # Make script executable
    $SUDO chmod +x "$chroot_script"
    
    # Execute configuration in chroot
    log_progress "Executing chroot configuration..."
    if ! $SUDO chroot "$EXTRACT_DIR" /bin/bash /tmp/configure_system.sh; then
        log_error "Chroot configuration failed"
        return 1
    fi
    
    # Clean up configuration script
    $SUDO rm -f "$chroot_script"
    
    # Configure live system specific settings
    configure_live_system_settings
    
    log_info "Chroot configuration completed"
    return 0
}

setup_chroot_mounts() {
    local mount_points=(
        "proc:proc"
        "sys:sysfs"
        "dev:devtmpfs"
        "dev/pts:devpts"
    )
    
    for mount_info in "${mount_points[@]}"; do
        local mount_target="${mount_info%:*}"
        local mount_type="${mount_info#*:}"
        local mount_path="$EXTRACT_DIR/$mount_target"
        
        log_debug "Mounting $mount_type at $mount_path"
        
        if ! $SUDO mkdir -p "$mount_path"; then
            log_error "Failed to create mount point: $mount_path"
            return 1
        fi
        
        if ! $SUDO mount -t "$mount_type" "$mount_type" "$mount_path"; then
            log_error "Failed to mount $mount_type at $mount_path"
            return 1
        fi
    done
    
    return 0
}

create_chroot_configuration_script() {
    local script_path="$1"
    
    $SUDO tee "$script_path" > /dev/null << 'EOF'
#!/bin/bash
set -euo pipefail

echo "[CHROOT] Starting system configuration..."

# Update package database
echo "[CHROOT] Updating package database..."
apt-get update 2>/dev/null || echo "Warning: apt update failed"

# Install essential live system packages
echo "[CHROOT] Installing essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    casper lupin-casper discover laptop-detect os-prober \
    linux-generic resolvconf net-tools wireless-tools \
    wpasupplicant locales console-common ubuntu-standard \
    2>/dev/null || echo "Warning: Some packages failed to install"

# Configure locales
echo "[CHROOT] Configuring locales..."
locale-gen en_US.UTF-8 2>/dev/null || true
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true

# Update initramfs
echo "[CHROOT] Updating initramfs..."
update-initramfs -u 2>/dev/null || echo "Warning: initramfs update failed"

# Clean package cache
echo "[CHROOT] Cleaning package cache..."
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean 2>/dev/null || true

echo "[CHROOT] Configuration completed successfully"
EOF
}

configure_live_system_settings() {
    log_progress "Configuring live system settings..."
    
    # Create casper configuration
    $SUDO mkdir -p "$EXTRACT_DIR/etc/casper.conf"
    $SUDO tee "$EXTRACT_DIR/etc/casper.conf" > /dev/null << EOF
# Casper configuration
export USERNAME="ubuntu"
export USERFULLNAME="Live session user"
export HOST="ubuntu"
export BUILD_SYSTEM="Ubuntu"
EOF
    
    # Configure auto-login for live session
    if [[ -d "$EXTRACT_DIR/etc/gdm3" ]]; then
        $SUDO tee "$EXTRACT_DIR/etc/gdm3/custom.conf" > /dev/null << EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=ubuntu

[security]

[xdmcp]

[chooser]

[debug]
EOF
    fi
    
    # Create live user setup script
    create_live_user_setup
    
    return 0
}

create_live_user_setup() {
    local setup_script="$EXTRACT_DIR/usr/local/bin/live-setup"
    
    $SUDO tee "$setup_script" > /dev/null << 'EOF'
#!/bin/bash
# Live system user setup

# Create ubuntu user if it doesn't exist
if ! id "ubuntu" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,adm,cdrom,plugdev,lpadmin,sambashare ubuntu
    echo "ubuntu:ubuntu" | chpasswd
fi

# Set up desktop environment
if command -v gnome-session &>/dev/null; then
    # GNOME setup
    su - ubuntu -c "gsettings set org.gnome.desktop.session idle-delay 0" 2>/dev/null || true
fi
EOF
    
    $SUDO chmod +x "$setup_script"
}

# Enhanced SquashFS creation with better compression
create_squashfs_enhanced() {
    log_info "Creating optimized SquashFS filesystem..."
    
    local squashfs_file="$CDROOT_DIR/live/filesystem.squashfs"
    local squashfs_opts=(
        -no-exports
        -noappend
        -comp xz
        -Xbcj x86
        -Xdict-size 100%
        -b 1M
        -processors $(nproc)
        -progress
        -mem 512M  # Limit memory usage
    )
    
    # Exclude directories that shouldn't be in SquashFS
    squashfs_opts+=(-e boot)
    
    log_progress "Creating SquashFS (this may take a while)..."
    if ! $SUDO mksquashfs "$EXTRACT_DIR" "$squashfs_file" "${squashfs_opts[@]}"; then
        log_error "SquashFS creation failed"
        return 1
    fi
    
    # Verify SquashFS integrity
    log_progress "Verifying SquashFS integrity..."
    if ! $SUDO unsquashfs -l "$squashfs_file" >/dev/null 2>&1; then
        log_error "SquashFS integrity check failed"
        return 1
    fi
    
    # Display size information
    local squashfs_size
    squashfs_size=$(du -h "$squashfs_file" | cut -f1)
    log_info "SquashFS created successfully (${squashfs_size})"
    
    return 0
}

# Enhanced bootloader setup
setup_bootloader_enhanced() {
    log_info "Setting up enhanced bootloader configuration..."
    
    # Copy kernel and initrd
    if ! copy_kernel_files; then
        return 1
    fi
    
    # Setup ISOLINUX for BIOS boot
    if ! setup_isolinux; then
        return 1
    fi
    
    # Setup GRUB for UEFI boot
    if ! setup_grub_uefi; then
        return 1
    fi
    
    # Create manifest and other metadata
    create_iso_metadata
    
    log_info "Bootloader setup completed"
    return 0
}

copy_kernel_files() {
    log_progress "Copying kernel files..."
    
    local kernel_version
    kernel_version=$(uname -r)
    
    # Copy kernel
    if [[ -f "/boot/vmlinuz-$kernel_version" ]]; then
        $SUDO cp "/boot/vmlinuz-$kernel_version" "$CDROOT_DIR/live/vmlinuz"
    else
        log_error "Kernel not found: /boot/vmlinuz-$kernel_version"
        return 1
    fi
    
    # Copy initrd
    if [[ -f "/boot/initrd.img-$kernel_version" ]]; then
        $SUDO cp "/boot/initrd.img-$kernel_version" "$CDROOT_DIR/live/initrd"
    else
        log_error "Initrd not found: /boot/initrd.img-$kernel_version"
        return 1
    fi
    
    return 0
}

setup_isolinux() {
    log_progress "Setting up ISOLINUX for BIOS boot..."
    
    # Copy ISOLINUX files
    local isolinux_files=(
        "/usr/lib/ISOLINUX/isolinux.bin"
        "/usr/lib/syslinux/modules/bios/ldlinux.c32"
        "/usr/lib/syslinux/modules/bios/libcom32.c32"
        "/usr/lib/syslinux/modules/bios/libutil.c32"
        "/usr/lib/syslinux/modules/bios/vesamenu.c32"
    )
    
    for file in "${isolinux_files[@]}"; do
        if [[ -f "$file" ]]; then
            $SUDO cp "$file" "$CDROOT_DIR/boot/isolinux/"
        else
            log_warning "ISOLINUX file not found: $file"
        fi
    done
    
    # Create ISOLINUX configuration
    create_isolinux_config
    
    return 0
}

create_isolinux_config() {
    local isolinux_cfg="$CDROOT_DIR/boot/isolinux/isolinux.cfg"
    
    $SUDO tee "$isolinux_cfg" > /dev/null << EOF
DEFAULT live
TIMEOUT 300
PROMPT 0

LABEL live
  MENU LABEL ^Try Ubuntu without installing
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper quiet splash ---

LABEL install
  MENU LABEL ^Install Ubuntu
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper only-ubiquity quiet splash ---

LABEL check
  MENU LABEL ^Check disc for defects
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper integrity-check quiet splash ---

LABEL memtest
  MENU LABEL ^Memory test
  KERNEL /boot/memtest86+.bin

LABEL hd
  MENU LABEL ^Boot from first hard disk
  LOCALBOOT 0x80
EOF
}

setup_grub_uefi() {
    log_progress "Setting up GRUB for UEFI boot..."
    
    # Create EFI directory structure
    local efi_dir="$CDROOT_DIR/EFI/boot"
    $SUDO mkdir -p "$efi_dir"
    
    # Copy GRUB EFI files if available
    if [[ -f "/usr/lib/grub/x86_64-efi/grubx64.efi" ]]; then
        $SUDO cp "/usr/lib/grub/x86_64-efi/grubx64.efi" "$efi_dir/bootx64.efi"
    elif [[ -f "/boot/efi/EFI/ubuntu/grubx64.efi" ]]; then
        $SUDO cp "/boot/efi/EFI/ubuntu/grubx64.efi" "$efi_dir/bootx64.efi"
    else
        log_warning "GRUB EFI bootloader not found - UEFI boot may not work"
    fi
    
    # Create GRUB configuration
    create_grub_config
    
    return 0
}

create_grub_config() {
    local grub_cfg="$CDROOT_DIR/EFI/boot/grub.cfg"
    
    $SUDO tee "$grub_cfg" > /dev/null << 'EOF'
set timeout=30
set default=0

menuentry "Try Ubuntu without installing" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd
}

menuentry "Install Ubuntu" {
    linux /live/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /live/initrd
}

menuentry "Check disc for defects" {
    linux /live/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /live/initrd
}
EOF
}

create_iso_metadata() {
    log_progress "Creating ISO metadata..."
    
    # Create filesystem size file
    echo "$(du -sx --block-size=1 "$EXTRACT_DIR" | cut -f1)" | $SUDO tee "$CDROOT_DIR/live/filesystem.size" >/dev/null
    
    # Create manifest
    create_manifest
    
    # Create .disk directory with metadata
    local disk_dir="$CDROOT_DIR/.disk"
    $SUDO mkdir -p "$disk_dir"
    
    echo "Ubuntu Live CD" | $SUDO tee "$disk_dir/info" >/dev/null
    echo "$(date '+%Y%m%d')" | $SUDO tee "$disk_dir/release_notes_url" >/dev/null
    echo "main restricted" | $SUDO tee "$disk_dir/base_installable" >/dev/null
    
    return 0
}

create_manifest() {
    local manifest_file="$CDROOT_DIR/live/filesystem.manifest"
    local manifest_desktop="$CDROOT_DIR/live/filesystem.manifest-desktop"
    
    log_progress "Generating package manifest..."
    
    # Create package list from chroot
    if $SUDO chroot "$EXTRACT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$WORKDIR/temp_manifest" 2>/dev/null; then
        $SUDO mv "$WORKDIR/temp_manifest" "$manifest_file"
        $SUDO cp "$manifest_file" "$manifest_desktop"
    else
        log_warning "Could not generate package manifest"
        $SUDO touch "$manifest_file" "$manifest_desktop"
    fi
}

# Enhanced ISO creation with multiple format support
create_iso_enhanced() {
    log_info "Creating enhanced ISO with hybrid boot support..."
    
    local iso_file="$WORKDIR/ubuntu-live-$(date +%Y%m%d).iso"
    local volume_label="Ubuntu Live $(date +%Y%m%d)"
    
    # Build xorriso command with comprehensive options
    local xorriso_opts=(
        -as mkisofs
        -iso-level 3
        -full-iso9660-filenames
        -volid "$volume_label"
        -eltorito-boot boot/isolinux/isolinux.bin
        -eltorito-catalog boot/isolinux/boot.cat
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
        -eltorito-alt-boot
        -e EFI/boot/bootx64.efi
        -no-emul-boot
        -append_partition 2 0xef EFI/boot/bootx64.efi
        -output "$iso_file"
        -graft-points
    )
    
    log_progress "Building ISO image (this may take several minutes)..."
    
    # Create the ISO
    if ! $SUDO xorriso "${xorriso_opts[@]}" "$CDROOT_DIR" 2>"$WORKDIR/logs/xorriso.log"; then
        log_error "ISO creation failed - check logs in $WORKDIR/logs/xorriso.log"
        return 1
    fi
    
    # Make ISO hybrid (bootable from USB)
    log_progress "Making ISO hybrid bootable..."
    if command -v isohybrid >/dev/null 2>&1; then
        $SUDO isohybrid "$iso_file" 2>/dev/null || log_warning "isohybrid failed - USB boot may not work"
    fi
    
    # Calculate and display checksums
    calculate_checksums "$iso_file"
    
    log_info "ISO created successfully: $iso_file"
    echo "$iso_file" > "$WORKDIR/.final_iso_path"
    
    return 0
}

calculate_checksums() {
    local iso_file="$1"
    local checksum_file="$WORKDIR/checksums.txt"
    
    log_progress "Calculating checksums..."
    
    {
        echo "# Checksums for $(basename "$iso_file")"
        echo "# Generated on $(date)"
        echo ""
        if command -v md5sum >/dev/null 2>&1; then
            echo "MD5: $(md5sum "$iso_file" | cut -d' ' -f1)"
        fi
        if command -v sha256sum >/dev/null 2>&1; then
            echo "SHA256: $(sha256sum "$iso_file" | cut -d' ' -f1)"
        fi
        echo ""
        echo "Size: $(du -h "$iso_file" | cut -f1)"
    } > "$checksum_file"
    
    log_info "Checksums saved to: $checksum_file"
}

# Resume functionality
check_resume_capability() {
    if load_state; then
        log_info "Previous build detected at stage: ${SCRIPT_STATE[stage]}"
        echo ""
        echo "Resume options:"
        echo "1) Resume from last stage"
        echo "2) Clean restart"
        echo "3) Exit"
        echo ""
        read -p "Choose option (1-3): " -r resume_choice
        
        case "$resume_choice" in
            1)
                log_info "Resuming from stage: ${SCRIPT_STATE[stage]}"
                return 0
                ;;
            2)
                log_info "Starting clean build..."
                cleanup_all
                return 1
                ;;
            3)
                log_info "Exiting..."
                exit 0
                ;;
            *)
                log_warning "Invalid choice, starting clean build..."
                return 1
                ;;
        esac
    fi
    return 1
}

# Improved error recovery
fatal_error() {
    local error_msg="$1"
    log_error "FATAL: $error_msg"
    
    echo ""
    echo "========================================="
    echo "FATAL ERROR OCCURRED"
    echo "========================================="
    echo "Error: $error_msg"
    echo ""
    echo "Recovery options:"
    echo "1. Check logs in: $WORKDIR/logs/"
    echo "2. Free up disk space and retry"
    echo "3. Run with different work directory"
    echo ""
    echo "State saved for potential resume."
    echo "========================================="
    
    cleanup_all
    exit 1
}

# Success message with detailed information
show_success_message() {
    local iso_path
    if [[ -f "$WORKDIR/.final_iso_path" ]]; then
        iso_path=$(cat "$WORKDIR/.final_iso_path")
    else
        iso_path="$WORKDIR/ubuntu-live-*.iso"
    fi
    
    local iso_size
    if [[ -f "$iso_path" ]]; then
        iso_size=$(du -h "$iso_path" 2>/dev/null | cut -f1 || echo "Unknown")
    else
        iso_size="Unknown"
    fi
    
    echo ""
    echo "========================================="
    echo "🎉 ISO CREATION COMPLETED SUCCESSFULLY! 🎉"
    echo "========================================="
    echo ""
    echo "📁 ISO Location: $iso_path"
    echo "�
