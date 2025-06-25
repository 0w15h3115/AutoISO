#!/bin/bash
# Enhanced AutoISO v3.0.0 - Professional Live ISO Creator
# Optimized for reliability, performance, and user experience

set -euo pipefail

# ========================================
#    ENHANCED AUTOISO - ENTERPRISE GRADE
# ========================================

# Global configuration
readonly SCRIPT_VERSION="3.0.0"
readonly MIN_SPACE_GB=20
readonly RECOMMENDED_SPACE_GB=30
readonly MAX_PATH_LENGTH=180
readonly DEFAULT_WORKDIR="/tmp/autoiso-build"

# Global state management
declare -A SCRIPT_STATE=(
    [stage]="init"
    [cleanup_required]="false"
    [mounts_active]="false"
    [start_time]=$(date +%s)
)

# Color codes for better UX
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# Progress indicators
declare -A PROGRESS_CHARS=(
    [0]="⠋" [1]="⠙" [2]="⠹" [3]="⠸" [4]="⠼" [5]="⠴" [6]="⠦" [7]="⠧" [8]="⠇" [9]="⠏"
)
PROGRESS_INDEX=0

# ========================================
#    LOGGING AND UI FUNCTIONS
# ========================================

setup_logging() {
    local log_dir="$WORKDIR/logs"
    mkdir -p "$log_dir"
    
    # Setup log files with descriptive names
    exec 3>"$log_dir/debug-$(date +%Y%m%d-%H%M%S).log"
    exec 4>"$log_dir/error-$(date +%Y%m%d-%H%M%S).log"
    exec 5>"$log_dir/progress-$(date +%Y%m%d-%H%M%S).log"
    
    log_info "AutoISO Enhanced v$SCRIPT_VERSION initialized"
    log_info "Process ID: $$"
    log_info "Work directory: $WORKDIR"
    log_info "System: $(uname -a)"
    log_info "Available memory: $(free -h | awk '/^Mem:/ {print $2}')"
    log_info "CPU cores: $(nproc)"
}

# Enhanced logging with colors and icons
log_debug() {
    echo "[DEBUG $(date '+%H:%M:%S')] $*" >&3
}

log_info() {
    echo -e "${BLUE}ℹ${NC}  [$(date '+%H:%M:%S')] $*" | tee -a /dev/fd/5
}

log_success() {
    echo -e "${GREEN}✓${NC}  [$(date '+%H:%M:%S')] $*" | tee -a /dev/fd/5
}

log_error() {
    echo -e "${RED}✗${NC}  [$(date '+%H:%M:%S')] $*" | tee -a /dev/fd/4 >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  [$(date '+%H:%M:%S')] $*" | tee -a /dev/fd/4
}

log_progress() {
    local msg="$1"
    local spinner="${PROGRESS_CHARS[$PROGRESS_INDEX]}"
    PROGRESS_INDEX=$(((PROGRESS_INDEX + 1) % 10))
    echo -ne "\r${CYAN}${spinner}${NC} $msg"
    echo "[PROGRESS] $msg" >> /dev/fd/5
}

log_progress_done() {
    echo -e "\r${GREEN}✓${NC} $1"
    echo "[DONE] $1" >> /dev/fd/5
}

# Display a styled header
show_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title}) / 2 ))
    
    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 $width))${NC}"
    printf "${BOLD}${BLUE}%*s%s%*s${NC}\n" $padding "" "$title" $padding ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo ""
}

# Progress bar function
show_progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((percentage * width / 100))
    
    printf "\r["
    printf "%-${width}s" "$(printf '█%.0s' $(seq 1 $filled))"
    printf "] %3d%%" "$percentage"
}

# ========================================
#    STATE MANAGEMENT
# ========================================

save_state() {
    local stage="$1"
    SCRIPT_STATE[stage]="$stage"
    
    cat > "$STATE_FILE" << EOF
STAGE=${SCRIPT_STATE[stage]}
CLEANUP_REQUIRED=${SCRIPT_STATE[cleanup_required]}
MOUNTS_ACTIVE=${SCRIPT_STATE[mounts_active]}
WORKDIR=$WORKDIR
TIMESTAMP=$(date +%s)
START_TIME=${SCRIPT_STATE[start_time]}
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
        SCRIPT_STATE[start_time]="${START_TIME:-$(date +%s)}"
        log_info "Loaded previous state: ${SCRIPT_STATE[stage]}"
        return 0
    fi
    return 1
}

# ========================================
#    CLEANUP AND ERROR HANDLING
# ========================================

cleanup_all() {
    log_info "Starting cleanup process..."
    
    # Show cleanup progress
    local cleanup_steps=("Unmounting filesystems" "Removing temporary files" "Closing logs")
    local step=0
    
    for desc in "${cleanup_steps[@]}"; do
        log_progress "$desc..."
        case $step in
            0) cleanup_mounts_enhanced ;;
            1) cleanup_temp_files ;;
            2) cleanup_logs ;;
        esac
        log_progress_done "$desc"
        ((step++))
    done
    
    SCRIPT_STATE[cleanup_required]="false"
    save_state "cleanup_complete"
}

cleanup_mounts_enhanced() {
    if [[ "${SCRIPT_STATE[mounts_active]}" != "true" ]]; then
        return 0
    fi
    
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
                    break
                fi
                sleep 1
                ((retries--))
                
                if [[ $retries -eq 0 ]]; then
                    $SUDO umount -f "$mount_point" 2>/dev/null || \
                    $SUDO umount -l "$mount_point" 2>/dev/null || true
                fi
            done
        fi
    done
    
    SCRIPT_STATE[mounts_active]="false"
}

cleanup_temp_files() {
    if [[ "${SCRIPT_STATE[cleanup_required]}" == "true" ]]; then
        local temp_dirs=("$EXTRACT_DIR" "$CDROOT_DIR/live/temp")
        for dir in "${temp_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                $SUDO rm -rf "$dir" 2>/dev/null || true
            fi
        done
    fi
}

cleanup_logs() {
    exec 3>&- 4>&- 5>&- 2>/dev/null || true
}

# Enhanced error handler
error_handler() {
    local line_no=$1
    local error_code=$2
    log_error "Error occurred in script at line $line_no (exit code: $error_code)"
    log_error "Stage: ${SCRIPT_STATE[stage]}"
    cleanup_all
    exit $error_code
}

# Set up error handling
trap 'error_handler ${LINENO} $?' ERR
trap cleanup_all EXIT INT TERM

# ========================================
#    VALIDATION FUNCTIONS
# ========================================

validate_system() {
    show_header "System Validation"
    
    local validation_steps=(
        "Distribution compatibility:validate_distribution"
        "Required tools:validate_required_tools"
        "Disk space:validate_space_detailed"
        "System health:validate_system_health"
        "Kernel files:validate_kernel_files"
    )
    
    local errors=0
    for step in "${validation_steps[@]}"; do
        local desc="${step%:*}"
        local func="${step#*:}"
        
        log_progress "Checking $desc..."
        if $func; then
            log_progress_done "✓ $desc"
        else
            log_error "✗ $desc"
            ((errors++))
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        log_error "Validation failed with $errors errors"
        return 1
    fi
    
    log_success "System validation completed successfully"
    return 0
}

validate_distribution() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_debug "Detected: $NAME $VERSION"
        
        case "$ID" in
            ubuntu|debian|linuxmint|pop|elementary|zorin)
                return 0
                ;;
            *)
                log_warning "Distribution '$ID' not explicitly tested"
                read -p "Continue anyway? (y/N): " -r continue_anyway
                [[ "$continue_anyway" =~ ^[Yy]$ ]]
                ;;
        esac
    else
        log_error "Cannot detect distribution"
        return 1
    fi
}

validate_required_tools() {
    local required_tools=(
        "rsync:rsync"
        "mksquashfs:squashfs-tools"
        "xorriso:xorriso"
        "genisoimage:genisoimage"
        "chroot:coreutils"
        "mount:mount"
        "umount:mount"
    )
    
    local missing_packages=()
    
    for tool_spec in "${required_tools[@]}"; do
        local tool="${tool_spec%:*}"
        local package="${tool_spec#*:}"
        
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_error "Missing required packages: ${missing_packages[*]}"
        log_info "Install with: sudo apt-get install ${missing_packages[*]}"
        return 1
    fi
    
    return 0
}

validate_space_detailed() {
    log_info "Analyzing disk space requirements..."
    
    # Calculate system size using multiple methods
    local system_size_kb
    system_size_kb=$(calculate_system_size_smart)
    local system_size_gb=$((system_size_kb / 1024 / 1024))
    
    # Calculate space requirements with detailed breakdown
    local space_breakdown=(
        "System copy:$((system_size_gb + 2))"
        "SquashFS:$((system_size_gb / 2 + 1))"
        "ISO overhead:2"
        "Working space:3"
        "Safety margin:5"
    )
    
    local required_space_gb=0
    echo ""
    log_info "Space requirement breakdown:"
    for item in "${space_breakdown[@]}"; do
        local desc="${item%:*}"
        local size="${item#*:}"
        printf "  %-20s %3d GB\n" "$desc:" "$size"
        ((required_space_gb += size))
    done
    printf "  %-20s %3d GB\n" "Total required:" "$required_space_gb"
    echo ""
    
    # Check available space
    local available_space_gb
    available_space_gb=$(df "$WORKDIR" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}' || echo "0")
    
    log_info "Available space: ${available_space_gb}GB"
    
    if [[ $available_space_gb -lt $required_space_gb ]]; then
        log_error "Insufficient space: need ${required_space_gb}GB, have ${available_space_gb}GB"
        suggest_space_solutions_enhanced "$required_space_gb" "$available_space_gb"
        return 1
    fi
    
    # Save space analysis
    mkdir -p "$WORKDIR"
    cat > "$WORKDIR/.space_analysis" << EOF
SYSTEM_SIZE_GB=$system_size_gb
REQUIRED_SPACE_GB=$required_space_gb
AVAILABLE_SPACE_GB=$available_space_gb
CALCULATION_TIME=$(date +%s)
EOF
    
    return 0
}

calculate_system_size_smart() {
    # Try multiple methods in order of accuracy
    local size_kb=0
    
    # Method 1: Precise du calculation
    if size_kb=$(calculate_size_du); then
        echo "$size_kb"
        return 0
    fi
    
    # Method 2: Filesystem analysis
    if size_kb=$(calculate_size_df); then
        echo "$size_kb"
        return 0
    fi
    
    # Method 3: Conservative estimate
    echo $((15 * 1024 * 1024))  # 15GB default
}

calculate_size_du() {
    local exclude_args=()
    local exclude_patterns=(
        "/dev" "/proc" "/sys" "/tmp" "/run" "/mnt" "/media"
        "/var/cache" "/var/log" "/var/tmp" "$WORKDIR"
    )
    
    for pattern in "${exclude_patterns[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done
    
    timeout 60 du -sk "${exclude_args[@]}" / 2>/dev/null | cut -f1
}

calculate_size_df() {
    local used_kb
    used_kb=$(df / | awk 'NR==2 {print $3}')
    
    # Subtract estimated cache/temp size
    local cache_size_kb=$((2 * 1024 * 1024))  # 2GB estimate
    echo $((used_kb - cache_size_kb))
}

suggest_space_solutions_enhanced() {
    local needed="$1"
    local available="$2"
    
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━ SPACE SOLUTIONS ━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Quick solutions:"
    echo ""
    echo "1. 🧹 Clean system (saves ~2-5GB):"
    echo "   sudo apt-get autoremove --purge && sudo apt-get autoclean"
    echo "   sudo journalctl --vacuum-time=1d"
    echo ""
    echo "2. 💾 Use external storage:"
    echo "   $0 /media/usb/iso-build"
    echo ""
    echo "3. 📁 Check other partitions:"
    echo "   df -h | grep -E '^/dev/' | sort -k4 -h -r"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

validate_system_health() {
    # Check for package manager locks
    local lock_files=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend"
        "/var/cache/apt/archives/lock"
    )
    
    for lock in "${lock_files[@]}"; do
        if [[ -f "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
            log_error "Package manager is locked"
            log_info "Wait for other package operations to complete or run:"
            log_info "sudo killall apt apt-get dpkg"
            return 1
        fi
    done
    
    # Check system load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    if (( $(echo "$load_avg > 10" | bc -l 2>/dev/null || echo 0) )); then
        log_warning "High system load: $load_avg"
    fi
    
    return 0
}

validate_kernel_files() {
    local kernel_version
    kernel_version=$(uname -r)
    
    local required_files=(
        "/boot/vmlinuz-$kernel_version"
        "/boot/initrd.img-$kernel_version"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Missing: $file"
            return 1
        fi
    done
    
    return 0
}

# ========================================
#    CORE BUILD FUNCTIONS
# ========================================

enhanced_rsync() {
    show_header "System Copy"
    
    local rsync_log="$WORKDIR/logs/rsync.log"
    local rsync_partial_dir="$WORKDIR/.rsync-partial"
    mkdir -p "$rsync_partial_dir"
    
    # Optimized exclusion list
    local exclude_patterns=(
        "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*"
        "/lost+found" "/.cache" "/var/cache/*" "/var/log/*.log"
        "/var/lib/docker/*" "/snap/*" "/swapfile" "$WORKDIR"
    )
    
    local rsync_opts=(
        -aAXHx
        --info=progress2
        --partial
        --partial-dir="$rsync_partial_dir"
        --numeric-ids
        --one-file-system
        --log-file="$rsync_log"
    )
    
    for pattern in "${exclude_patterns[@]}"; do
        rsync_opts+=(--exclude="$pattern")
    done
    
    log_info "Starting system copy..."
    SCRIPT_STATE[cleanup_required]="true"
    save_state "rsync_active"
    
    if $SUDO rsync "${rsync_opts[@]}" / "$EXTRACT_DIR/"; then
        log_success "System copy completed"
        save_state "rsync_complete"
        
        # Show statistics
        local size
        size=$(du -sh "$EXTRACT_DIR" 2>/dev/null | cut -f1 || echo "N/A")
        log_info "Copied data size: $size"
        
        return 0
    else
        log_error "System copy failed"
        return 1
    fi
}

post_copy_cleanup() {
    show_header "Post-Copy Optimization"
    
    local cleanup_tasks=(
        "Package caches:clean_package_caches"
        "Log files:clean_logs"
        "Temporary files:clean_temp"
        "SSH keys:clean_ssh_keys"
        "Machine IDs:clean_machine_ids"
    )
    
    for task in "${cleanup_tasks[@]}"; do
        local desc="${task%:*}"
        local func="${task#*:}"
        log_progress "Cleaning $desc..."
        $func
        log_progress_done "Cleaned $desc"
    done
    
    log_success "Post-copy cleanup completed"
    return 0
}

clean_package_caches() {
    $SUDO rm -rf "$EXTRACT_DIR/var/cache/apt/archives/"*.deb
    $SUDO rm -rf "$EXTRACT_DIR/var/lib/apt/lists/"*
}

clean_logs() {
    $SUDO find "$EXTRACT_DIR/var/log" -type f \( -name "*.log" -o -name "*.gz" \) -delete 2>/dev/null || true
}

clean_temp() {
    $SUDO rm -rf "$EXTRACT_DIR/tmp/"* "$EXTRACT_DIR/var/tmp/"*
}

clean_ssh_keys() {
    $SUDO rm -rf "$EXTRACT_DIR/etc/ssh/ssh_host_"*
    $SUDO rm -rf "$EXTRACT_DIR/root/.ssh/"
}

clean_machine_ids() {
    $SUDO rm -f "$EXTRACT_DIR/etc/machine-id"
    $SUDO rm -f "$EXTRACT_DIR/var/lib/dbus/machine-id"
}

configure_chroot_enhanced() {
    show_header "Chroot Configuration"
    
    log_progress "Setting up chroot mounts..."
    if ! setup_chroot_mounts; then
        log_error "Failed to setup chroot mounts"
        return 1
    fi
    log_progress_done "Chroot mounts ready"
    
    SCRIPT_STATE[mounts_active]="true"
    save_state "chroot_mounts_active"
    
    # Create and execute chroot script
    local chroot_script="$EXTRACT_DIR/tmp/configure_system.sh"
    create_chroot_script "$chroot_script"
    
    log_progress "Installing live system packages..."
    if ! $SUDO chroot "$EXTRACT_DIR" /bin/bash /tmp/configure_system.sh; then
        log_error "Chroot configuration failed"
        return 1
    fi
    log_progress_done "Live system configured"
    
    $SUDO rm -f "$chroot_script"
    
    log_success "Chroot configuration completed"
    return 0
}

setup_chroot_mounts() {
    local mounts=(
        "proc:proc:/proc"
        "sysfs:sysfs:/sys"
        "devtmpfs:udev:/dev"
        "devpts:devpts:/dev/pts"
    )
    
    for mount_spec in "${mounts[@]}"; do
        IFS=: read -r fstype source target <<< "$mount_spec"
        local mount_path="$EXTRACT_DIR$target"
        
        $SUDO mkdir -p "$mount_path"
        if ! $SUDO mount -t "$fstype" "$source" "$mount_path"; then
            log_error "Failed to mount $fstype at $mount_path"
            return 1
        fi
    done
    
    return 0
}

create_chroot_script() {
    local script_path="$1"
    
    $SUDO tee "$script_path" > /dev/null << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

echo "[CHROOT] Updating package database..."
apt-get update || true

# Essential packages
PACKAGES=(
    casper
    lupin-casper
    discover
    laptop-detect
    os-prober
    linux-generic
    net-tools
    network-manager
)

echo "[CHROOT] Installing packages..."
for pkg in "${PACKAGES[@]}"; do
    echo "[CHROOT] Installing: $pkg"
    apt-get install -y "$pkg" || echo "[CHROOT] Warning: Failed to install $pkg"
done

# Configure locales
echo "[CHROOT] Configuring locales..."
locale-gen en_US.UTF-8 || true
update-locale LANG=en_US.UTF-8 || true

# Update initramfs
echo "[CHROOT] Updating initramfs..."
update-initramfs -u || update-initramfs -c -k all || true

# Clean up
apt-get autoremove -y || true
apt-get autoclean || true

echo "[CHROOT] Configuration complete"
CHROOT_SCRIPT

    $SUDO chmod +x "$script_path"
}

create_squashfs_enhanced() {
    show_header "Creating SquashFS"
    
    local squashfs_file="$CDROOT_DIR/live/filesystem.squashfs"
    
    # Calculate optimal parameters
    local processors=$(nproc)
    local mem_limit=$(($(free -m | awk '/^Mem:/ {print $2}') / 2))
    
    local squashfs_opts=(
        -no-exports
        -noappend
        -comp xz
        -Xbcj x86
        -b 1M
        -processors "$processors"
        -mem "${mem_limit}M"
    )
    
    log_info "Creating SquashFS with $processors processors and ${mem_limit}MB memory limit..."
    
    # Show progress with size estimation
    local source_size
    source_size=$(du -sm "$EXTRACT_DIR" | cut -f1)
    local estimated_size=$((source_size / 2))
    
    if ! $SUDO mksquashfs "$EXTRACT_DIR" "$squashfs_file" "${squashfs_opts[@]}"; then
        log_error "SquashFS creation failed"
        return 1
    fi
    
    # Verify and show results
    local final_size
    final_size=$(du -h "$squashfs_file" | cut -f1)
    log_success "SquashFS created: $final_size (compressed from ${source_size}MB)"
    
    return 0
}

setup_bootloader_enhanced() {
    show_header "Bootloader Setup"
    
    local tasks=(
        "Kernel files:copy_kernel_files"
        "ISOLINUX (BIOS):setup_isolinux"
        "GRUB (UEFI):setup_grub_uefi"
        "ISO metadata:create_iso_metadata"
    )
    
    for task in "${tasks[@]}"; do
        local desc="${task%:*}"
        local func="${task#*:}"
        log_progress "Setting up $desc..."
        if $func; then
            log_progress_done "✓ $desc configured"
        else
            log_warning "⚠ $desc setup incomplete"
        fi
    done
    
    log_success "Bootloader setup completed"
    return 0
}

copy_kernel_files() {
    local kernel_version
    kernel_version=$(uname -r)
    
    # Copy kernel and initrd
    for file in "vmlinuz" "initrd.img"; do
        local source="/boot/$file-$kernel_version"
        local dest="$CDROOT_DIR/live/$file"
        
        if [[ -f "$source" ]]; then
            $SUDO cp "$source" "$dest"
        else
            log_error "Not found: $source"
            return 1
        fi
    done
    
    return 0
}

setup_isolinux() {
    # Create ISOLINUX directory
    $SUDO mkdir -p "$CDROOT_DIR/boot/isolinux"
    
    # Copy ISOLINUX files
    local isolinux_files=(
        "/usr/lib/ISOLINUX/isolinux.bin"
        "/usr/lib/syslinux/modules/bios/ldlinux.c32"
        "/usr/lib/syslinux/modules/bios/libcom32.c32"
        "/usr/lib/syslinux/modules/bios/libutil.c32"
    )
    
    for file in "${isolinux_files[@]}"; do
        if [[ -f "$file" ]]; then
            $SUDO cp "$file" "$CDROOT_DIR/boot/isolinux/"
        fi
    done
    
    # Create ISOLINUX config
    $SUDO tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg" > /dev/null << 'EOF'
DEFAULT live
TIMEOUT 300

LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper quiet splash ---

LABEL check
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper integrity-check quiet splash ---
EOF
    
    return 0
}

setup_grub_uefi() {
    # Create EFI directory
    local efi_dir="$CDROOT_DIR/EFI/boot"
    $SUDO mkdir -p "$efi_dir"
    
    # Find and copy GRUB EFI
    local grub_sources=(
        "/usr/lib/grub/x86_64-efi/grubx64.efi"
        "/boot/efi/EFI/ubuntu/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
    )
    
    local found=false
    for source in "${grub_sources[@]}"; do
        if [[ -f "$source" ]]; then
            $SUDO cp "$source" "$efi_dir/bootx64.efi"
            found=true
            break
        fi
    done
    
    if [[ "$found" == "false" ]]; then
        log_warning "GRUB EFI not found - UEFI boot may not work"
    fi
    
    # Create GRUB config
    $SUDO tee "$efi_dir/grub.cfg" > /dev/null << 'EOF'
set timeout=30
set default=0

menuentry "Live System" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd
}
EOF
    
    return 0
}

create_iso_metadata() {
    # Create filesystem.size
    echo "$(du -sx --block-size=1 "$EXTRACT_DIR" | cut -f1)" | \
        $SUDO tee "$CDROOT_DIR/live/filesystem.size" >/dev/null
    
    # Create manifest
    $SUDO chroot "$EXTRACT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' | \
        $SUDO tee "$CDROOT_DIR/live/filesystem.manifest" >/dev/null || true
    
    # Create .disk info
    $SUDO mkdir -p "$CDROOT_DIR/.disk"
    echo "Ubuntu Live CD - Built $(date '+%Y-%m-%d')" | $SUDO tee "$CDROOT_DIR/.disk/info" >/dev/null
    
    return 0
}

create_iso_enhanced() {
    show_header "Creating ISO Image"
    
    local iso_file="$WORKDIR/ubuntu-live-$(date +%Y%m%d-%H%M).iso"
    local volume_label="Ubuntu_Live_$(date +%Y%m%d)"
    
    # Pre-flight checks
    if ! command -v xorriso >/dev/null 2>&1; then
        log_error "xorriso not installed"
        log_info "Install with: sudo apt-get install xorriso"
        return 1
    fi
    
    # Build xorriso command
    local xorriso_cmd=(
        xorriso
        -as mkisofs
        -iso-level 3
        -full-iso9660-filenames
        -volid "$volume_label"
        -joliet
        -joliet-long
        -rational-rock
    )
    
    # Add BIOS boot
    if [[ -f "$CDROOT_DIR/boot/isolinux/isolinux.bin" ]]; then
        xorriso_cmd+=(
            -eltorito-boot boot/isolinux/isolinux.bin
            -eltorito-catalog boot/isolinux/boot.cat
            -no-emul-boot
            -boot-load-size 4
            -boot-info-table
        )
    fi
    
    # Add UEFI boot
    if [[ -f "$CDROOT_DIR/EFI/boot/bootx64.efi" ]]; then
        xorriso_cmd+=(
            -eltorito-alt-boot
            -e EFI/boot/bootx64.efi
            -no-emul-boot
        )
    fi
    
    # Add source and output
    xorriso_cmd+=(
        -output "$iso_file"
        "$CDROOT_DIR"
    )
    
    log_info "Building ISO image..."
    
    # Execute with progress monitoring
    if ! $SUDO "${xorriso_cmd[@]}" 2>&1 | while read -r line; do
        if [[ "$line" =~ ([0-9]+)% ]]; then
            show_progress_bar "${BASH_REMATCH[1]}" 100
        fi
    done; then
        log_error "ISO creation failed"
        return 1
    fi
    
    echo ""  # New line after progress bar
    
    # Make hybrid
    if command -v isohybrid >/dev/null 2>&1; then
        log_progress "Making ISO hybrid bootable..."
        $SUDO isohybrid "$iso_file" 2>/dev/null || true
        log_progress_done "ISO is hybrid bootable"
    fi
    
    # Calculate checksums
    log_progress "Calculating checksums..."
    local checksum_file="$WORKDIR/checksums.txt"
    {
        echo "# Checksums for $(basename "$iso_file")"
        echo "# Generated on $(date)"
        echo ""
        echo "MD5: $(md5sum "$iso_file" | cut -d' ' -f1)"
        echo "SHA256: $(sha256sum "$iso_file" | cut -d' ' -f1)"
        echo "Size: $(du -h "$iso_file" | cut -f1)"
    } > "$checksum_file"
    log_progress_done "Checksums calculated"
    
    # Save ISO path
    echo "$iso_file" > "$WORKDIR/.final_iso_path"
    
    log_success "ISO created successfully: $iso_file"
    return 0
}

# ========================================
#    ATOMIC OPERATIONS
# ========================================

atomic_operation() {
    local operation_name="$1"
    local operation_function="$2"
    
    log_info "Starting: $operation_name"
    save_state "atomic_${operation_name}_start"
    
    local start_time=$(date +%s)
    
    if $operation_function; then
        local duration=$(($(date +%s) - start_time))
        save_state "atomic_${operation_name}_complete"
        log_success "$operation_name completed in ${duration}s"
        return 0
    else
        log_error "$operation_name failed"
        return 1
    fi
}

# ========================================
#    USER INTERFACE
# ========================================

show_welcome() {
    clear
    echo -e "${BOLD}${BLUE}"
    cat << 'EOF'
    ___         __        __________ ____  
   /   | __  __/ /_____  /  _/ ___// __ \ 
  / /| |/ / / / __/ __ \ / / \__ \/ / / / 
 / ___ / /_/ / /_/ /_/ // / ___/ / /_/ /  
/_/  |_\__,_/\__/\____/___//____/\____/   
                                          
EOF
    echo -e "${NC}"
    echo -e "${BOLD}Enhanced AutoISO v$SCRIPT_VERSION${NC} - Professional Live ISO Creator"
    echo -e "${CYAN}Creating bootable Ubuntu/Debian live ISOs with style${NC}"
    echo ""
}

show_usage() {
    echo "Usage: $0 [OPTIONS] [WORK_DIRECTORY]"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -v, --version     Show version information"
    echo "  -q, --quiet       Minimal output"
    echo "  -d, --debug       Enable debug output"
    echo ""
    echo "Arguments:"
    echo "  WORK_DIRECTORY    Directory for build files (default: $DEFAULT_WORKDIR)"
    echo ""
    echo "Examples:"
    echo "  $0                           # Use default directory"
    echo "  $0 /home/user/iso-build     # Use custom directory"
    echo "  $0 -q /mnt/usb/build        # Quiet mode with USB drive"
    echo ""
}

show_summary() {
    local elapsed=$(($(date +%s) - ${SCRIPT_STATE[start_time]}))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    
    echo ""
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}        ✨ ISO CREATION SUCCESSFUL! ✨${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ -f "$WORKDIR/.final_iso_path" ]]; then
        local iso_path=$(cat "$WORKDIR/.final_iso_path")
        local iso_size=$(du -h "$iso_path" 2>/dev/null | cut -f1 || echo "N/A")
        
        echo -e "📀 ${BOLD}ISO Location:${NC} $iso_path"
        echo -e "📏 ${BOLD}ISO Size:${NC} $iso_size"
    fi
    
    echo -e "📁 ${BOLD}Work Directory:${NC} $WORKDIR"
    echo -e "🔐 ${BOLD}Checksums:${NC} $WORKDIR/checksums.txt"
    echo -e "📋 ${BOLD}Logs:${NC} $WORKDIR/logs/"
    echo -e "⏱️  ${BOLD}Build Time:${NC} ${minutes}m ${seconds}s"
    echo ""
    echo -e "${CYAN}${BOLD}Next Steps:${NC}"
    echo "1. Test in VirtualBox/VMware: Just boot the ISO directly"
    echo "2. Create bootable USB:"
    echo "   ${BOLD}sudo dd if='${iso_path:-$WORKDIR/*.iso}' of=/dev/sdX bs=4M status=progress${NC}"
    echo "3. Or use GUI tools: Rufus (Windows), Etcher, or Ventoy"
    echo ""
    echo -e "${GREEN}Thank you for using AutoISO! 🎉${NC}"
}

check_resume_capability() {
    if load_state; then
        echo ""
        echo -e "${YELLOW}Previous build detected${NC}"
        echo "Stage: ${SCRIPT_STATE[stage]}"
        echo ""
        echo "What would you like to do?"
        echo "1) Resume from last checkpoint"
        echo "2) Start fresh (recommended if previous build failed)"
        echo "3) Exit"
        echo ""
        read -p "Choice [1-3]: " -r choice
        
        case "$choice" in
            1) return 0 ;;
            2) cleanup_all; return 1 ;;
            3) exit 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

# ========================================
#    MAIN WORKFLOW
# ========================================

main() {
    # Show welcome
    show_welcome
    
    # Setup logging
    setup_logging
    
    # Check for resume
    local resume_build=false
    if check_resume_capability; then
        resume_build=true
    fi
    
    # Run validation for new builds
    if [[ "$resume_build" == "false" ]]; then
        if ! validate_system; then
            log_error "System validation failed"
            exit 1
        fi
        
        # Prepare workspace
        log_info "Preparing workspace..."
        $SUDO rm -rf "$WORKDIR"/{extract,cdroot}
        mkdir -p "$EXTRACT_DIR" "$CDROOT_DIR"/{boot/isolinux,live,EFI/boot}
        save_state "workspace_prepared"
    fi
    
    # Execute build stages
    case "${SCRIPT_STATE[stage]}" in
        "init"|"workspace_prepared")
            atomic_operation "system_copy" enhanced_rsync || exit 1
            ;&
        "atomic_system_copy_complete")
            atomic_operation "post_cleanup" post_copy_cleanup || exit 1
            ;&
        "atomic_post_cleanup_complete")
            atomic_operation "chroot_config" configure_chroot_enhanced || exit 1
            ;&
        "atomic_chroot_config_complete")
            atomic_operation "squashfs" create_squashfs_enhanced || exit 1
            ;&
        "atomic_squashfs_complete")
            atomic_operation "bootloader" setup_bootloader_enhanced || exit 1
            ;&
        "atomic_bootloader_complete")
            atomic_operation "iso_creation" create_iso_enhanced || exit 1
            ;&
        "atomic_iso_creation_complete")
            show_summary
            ;;
        *)
            log_error "Unknown state: ${SCRIPT_STATE[stage]}"
            exit 1
            ;;
    esac
}

# ========================================
#    ENTRY POINT
# ========================================

# Parse command line arguments
QUIET_MODE=false
DEBUG_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--version)
            echo "Enhanced AutoISO v$SCRIPT_VERSION"
            exit 0
            ;;
        -q|--quiet)
            QUIET_MODE=true
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            WORKDIR="$1/autoiso-build"
            shift
            ;;
    esac
done

# Set default work directory if not specified
: "${WORKDIR:=$DEFAULT_WORKDIR}"

# Resolve paths
WORKDIR=$(realpath "$WORKDIR" 2>/dev/null || echo "$WORKDIR")
EXTRACT_DIR="$WORKDIR/extract"
CDROOT_DIR="$WORKDIR/cdroot"
STATE_FILE="$WORKDIR/.autoiso-state"

# Check for root/sudo
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
    if ! $SUDO -n true 2>/dev/null; then
        echo "This script requires sudo access."
        $SUDO true || exit 1
    fi
fi

# Start main process
main "$@"
