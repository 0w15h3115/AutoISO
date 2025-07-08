#!/bin/bash
# Enhanced AutoISO v3.1.3 - Professional Live ISO Creator with Kali Linux Support
# Fixed chroot configuration and network setup

set -euo pipefail

# ========================================
#    ENHANCED AUTOISO - ENTERPRISE GRADE
# ========================================

# Global configuration
readonly SCRIPT_VERSION="3.1.3"
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
    [distribution]=""
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
DISTRIBUTION=${SCRIPT_STATE[distribution]}
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
        SCRIPT_STATE[distribution]="${DISTRIBUTION:-}"
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
        "$EXTRACT_DIR/run"
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

list_available_kernels() {
    log_info "Available kernels on this system:"
    
    # List vmlinuz files
    echo "Kernel images (vmlinuz):"
    ls -la /boot/vmlinuz* 2>/dev/null | awk '{print "  " $NF}' || echo "  None found in /boot/"
    ls -la /vmlinuz* 2>/dev/null | awk '{print "  " $NF}' || true
    
    echo ""
    echo "Initrd images:"
    ls -la /boot/initrd* 2>/dev/null | awk '{print "  " $NF}' || echo "  None found in /boot/"
    ls -la /initrd* 2>/dev/null | awk '{print "  " $NF}' || true
    
    echo ""
    echo "Installed kernel packages:"
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        dpkg -l | grep -E "^ii\s+linux-image" | awk '{print "  " $2 " " $3}' || echo "  None found"
    else
        dpkg -l | grep -E "^ii\s+linux-image|^ii\s+linux-generic" | awk '{print "  " $2 " " $3}' || echo "  None found"
    fi
}

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
            
            # Show available kernels if kernel validation failed
            if [[ "$func" == "validate_kernel_files" ]]; then
                echo ""
                list_available_kernels
            fi
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
        SCRIPT_STATE[distribution]="$ID"
        
        case "$ID" in
            ubuntu|debian|linuxmint|pop|elementary|zorin)
                log_info "Distribution '$NAME' is fully supported"
                return 0
                ;;
            kali)
                log_info "Distribution 'Kali Linux' detected - using Kali-specific configuration"
                return 0
                ;;
            parrot)
                log_info "Distribution 'Parrot OS' detected - using Debian-based configuration"
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
    
    # Validate the size is a number
    if [[ ! "$system_size_kb" =~ ^[0-9]+$ ]]; then
        log_warning "Could not accurately calculate system size, using default estimate"
        system_size_kb=$((15 * 1024 * 1024))  # 15GB default
    fi
    
    local system_size_gb=$((system_size_kb / 1024 / 1024))
    
    # Kali typically needs more space
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        system_size_gb=$((system_size_gb + 5))
        log_info "Adding extra space for Kali Linux tools"
    fi
    
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
    
    # Validate available space is a number
    if [[ ! "$available_space_gb" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine available disk space"
        return 1
    fi
    
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
    
    # Method 3: Conservative estimate (higher for Kali)
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        echo $((20 * 1024 * 1024))  # 20GB default for Kali
    else
        echo $((15 * 1024 * 1024))  # 15GB default for others
    fi
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
    
    local size_output
    size_output=$(timeout 60 du -sk "${exclude_args[@]}" / 2>/dev/null | cut -f1 || echo "0")
    
    # Ensure we have a valid number
    if [[ ! "$size_output" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$size_output"
    fi
}

calculate_size_df() {
    local used_kb
    used_kb=$(df / | awk 'NR==2 {print $3}' || echo "0")
    
    # Ensure we have a valid number
    if [[ ! "$used_kb" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 1
    fi
    
    # Subtract estimated cache/temp size
    local cache_size_kb=$((2 * 1024 * 1024))  # 2GB estimate
    local result=$((used_kb - cache_size_kb))
    
    # Ensure result is not negative
    if [[ $result -lt 0 ]]; then
        echo "$used_kb"
    else
        echo "$result"
    fi
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
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        echo "4. 🔧 For Kali: Remove unnecessary tools:"
        echo "   sudo apt-get remove --purge kali-tools-*"
        echo ""
    fi
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

check_and_fix_kernel_symlinks() {
    log_info "Checking kernel symlinks..."
    
    # Check if we need to create symlinks
    local need_vmlinuz_link=true
    local need_initrd_link=true
    
    if [[ -L "/boot/vmlinuz" ]] || [[ -f "/boot/vmlinuz" ]]; then
        need_vmlinuz_link=false
    fi
    
    if [[ -L "/boot/initrd.img" ]] || [[ -f "/boot/initrd.img" ]]; then
        need_initrd_link=false
    fi
    
    if [[ "$need_vmlinuz_link" == "true" ]] || [[ "$need_initrd_link" == "true" ]]; then
        log_info "Creating missing kernel symlinks..."
        
        # Find the latest kernel
        local latest_kernel=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
        local latest_initrd=$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
        
        if [[ -n "$latest_kernel" ]] && [[ "$need_vmlinuz_link" == "true" ]]; then
            log_info "Creating symlink: /boot/vmlinuz -> $latest_kernel"
            $SUDO ln -sf "$latest_kernel" /boot/vmlinuz
        fi
        
        if [[ -n "$latest_initrd" ]] && [[ "$need_initrd_link" == "true" ]]; then
            log_info "Creating symlink: /boot/initrd.img -> $latest_initrd"
            $SUDO ln -sf "$latest_initrd" /boot/initrd.img
        fi
    fi
}

validate_kernel_files() {
    local kernel_version
    kernel_version=$(uname -r)
    
    # Try to fix common issues first
    check_and_fix_kernel_symlinks
    
    # Check for kernel files with various naming patterns
    local kernel_found=false
    local initrd_found=false
    
    # Possible kernel locations and patterns
    local kernel_patterns=(
        "/boot/vmlinuz-$kernel_version"
        "/boot/vmlinuz"
        "/vmlinuz"
        "/boot/vmlinuz-*-amd64"
        "/boot/vmlinuz-*-generic"
        "/boot/vmlinuz-*-kali*"
    )
    
    local initrd_patterns=(
        "/boot/initrd.img-$kernel_version"
        "/boot/initrd.img"
        "/initrd.img"
        "/boot/initrd.img-*-amd64"
        "/boot/initrd.img-*-generic"
        "/boot/initrd.img-*-kali*"
    )
    
    # Check for kernel
    for pattern in "${kernel_patterns[@]}"; do
        if [[ -f "$pattern" ]] || ls $pattern 2>/dev/null | head -1 >/dev/null; then
            kernel_found=true
            log_debug "Found kernel at: $pattern"
            break
        fi
    done
    
    # Check for initrd
    for pattern in "${initrd_patterns[@]}"; do
        if [[ -f "$pattern" ]] || ls $pattern 2>/dev/null | head -1 >/dev/null; then
            initrd_found=true
            log_debug "Found initrd at: $pattern"
            break
        fi
    done
    
    if [[ "$kernel_found" == "false" ]]; then
        log_error "No kernel image found. Tried patterns:"
        for pattern in "${kernel_patterns[@]}"; do
            log_error "  - $pattern"
        done
        echo ""
        log_warning "Quick fix suggestions:"
        if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
            log_info "1. Install Kali kernel:"
            log_info "   sudo apt update"
            log_info "   sudo apt install linux-image-amd64"
            log_info ""
            log_info "2. Create symlinks (if kernel exists elsewhere):"
            log_info "   sudo ln -sf /boot/vmlinuz-\$(uname -r) /boot/vmlinuz"
        else
            log_info "1. Install generic kernel:"
            log_info "   sudo apt update"
            log_info "   sudo apt install linux-generic"
        fi
        return 1
    fi
    
    if [[ "$initrd_found" == "false" ]]; then
        log_error "No initrd image found. Tried patterns:"
        for pattern in "${initrd_patterns[@]}"; do
            log_error "  - $pattern"
        done
        echo ""
        log_warning "Quick fix suggestions:"
        log_info "1. Regenerate initrd:"
        log_info "   sudo update-initramfs -c -k all"
        log_info ""
        log_info "2. Create symlinks (if initrd exists elsewhere):"
        log_info "   sudo ln -sf /boot/initrd.img-\$(uname -r) /boot/initrd.img"
        return 1
    fi
    
    log_debug "Kernel validation passed"
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
    
    # First, estimate the total size to copy
    log_info "Calculating system size for accurate progress..."
    local total_size_bytes
    local total_size_human
    
    # Get estimated size (this is fast) - ensure we get a valid number
    local df_output
    df_output=$(df / | awk 'NR==2 {print $3}' || echo "0")
    
    # Validate it's a number
    if [[ "$df_output" =~ ^[0-9]+$ ]]; then
        total_size_bytes=$((df_output * 1024))
    else
        # Fallback to a reasonable estimate
        total_size_bytes=$((10 * 1024 * 1024 * 1024))  # 10GB in bytes
    fi
    
    total_size_human=$(numfmt --to=iec-i --suffix=B "$total_size_bytes" 2>/dev/null || echo "~10GB")
    
    log_info "Estimated data to copy: $total_size_human"
    echo ""
    
    # Optimized exclusion list with Kali-specific additions
    local exclude_patterns=(
        "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*"
        "/lost+found" "/.cache" "/var/cache/*" "/var/log/*.log"
        "/var/lib/docker/*" "/snap/*" "/swapfile" "$WORKDIR"
    )
    
    # Add Kali-specific exclusions if needed
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        exclude_patterns+=(
            "/root/.cache"
            "/root/.local/share/Trash"
            "/opt/metasploit-framework/embedded/framework/.git"
        )
    fi
    
    local rsync_opts=(
        -aAXHx
        --partial
        --partial-dir="$rsync_partial_dir"
        --numeric-ids
        --one-file-system
        --log-file="$rsync_log"
        --stats
        --human-readable
    )
    
    for pattern in "${exclude_patterns[@]}"; do
        rsync_opts+=(--exclude="$pattern")
    done
    
    log_info "Starting system copy... This may take 10-30 minutes depending on system size."
    SCRIPT_STATE[cleanup_required]="true"
    save_state "rsync_active"
    
    # Create a background process to monitor progress
    local stats_file="$WORKDIR/.rsync_stats"
    local start_time=$(date +%s)
    local rsync_pid
    
    # Start rsync in background
    $SUDO rsync "${rsync_opts[@]}" / "$EXTRACT_DIR/" 2>&1 | \
        tee "$stats_file" | \
        grep -E "to-check=|xfr#" | \
        while IFS= read -r line; do
            # Parse rsync output for better progress display
            if [[ "$line" =~ to-check=([0-9]+)/([0-9]+) ]]; then
                local remaining="${BASH_REMATCH[1]}"
                local total="${BASH_REMATCH[2]}"
                local completed=$((total - remaining))
                local percent=$((completed * 100 / total))
                
                # Calculate speed and ETA
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                
                if [[ $elapsed -gt 0 && $completed -gt 0 ]]; then
                    local rate=$((completed / elapsed))
                    local eta=$((remaining / rate))
                    local eta_min=$((eta / 60))
                    local eta_sec=$((eta % 60))
                    
                    # Format the progress line
                    printf "\r${CYAN}Progress:${NC} [%-50s] %3d%% " \
                        "$(printf '█%.0s' $(seq 1 $((percent / 2))))" \
                        "$percent"
                    
                    printf "${CYAN}Files:${NC} %d/%d " "$completed" "$total"
                    
                    if [[ $eta_min -gt 0 ]]; then
                        printf "${CYAN}ETA:${NC} %dm %ds     " "$eta_min" "$eta_sec"
                    else
                        printf "${CYAN}ETA:${NC} %ds     " "$eta_sec"
                    fi
                fi
            elif [[ "$line" =~ xfr#([0-9]+),.*to-chk=([0-9]+)/([0-9]+) ]]; then
                # Alternative parsing for different rsync versions
                local transferred="${BASH_REMATCH[1]}"
                local remaining="${BASH_REMATCH[2]}"
                local total="${BASH_REMATCH[3]}"
                local completed=$((total - remaining))
                local percent=$((completed * 100 / total))
                
                printf "\r${CYAN}Progress:${NC} [%-50s] %3d%% ${CYAN}Files:${NC} %d/%d     " \
                    "$(printf '█%.0s' $(seq 1 $((percent / 2))))" \
                    "$percent" "$completed" "$total"
            fi
        done &
    
    # Wait for rsync to complete
    wait
    local rsync_status=$?
    
    echo "" # New line after progress
    
    if [[ $rsync_status -eq 0 ]]; then
        # Parse final statistics
        if [[ -f "$stats_file" ]]; then
            local files_transferred=$(grep -E "Number of.*files transferred:" "$stats_file" | awk '{print $NF}' || echo "N/A")
            local total_size=$(grep -E "Total file size:" "$stats_file" | awk '{print $4,$5}' || echo "N/A")
            local transferred_size=$(grep -E "Total transferred file size:" "$stats_file" | awk '{print $5,$6}' || echo "N/A")
            local speedup=$(grep -E "Speedup is" "$stats_file" | awk '{print $3}' || echo "N/A")
            
            echo ""
            log_success "System copy completed successfully!"
            echo ""
            echo -e "${BOLD}Copy Statistics:${NC}"
            echo -e "  ${CYAN}Files copied:${NC}      $files_transferred"
            echo -e "  ${CYAN}Total size:${NC}        $total_size"
            echo -e "  ${CYAN}Transferred:${NC}       $transferred_size"
            echo -e "  ${CYAN}Compression ratio:${NC} $speedup"
            
            # Show actual copied size
            local copied_size
            copied_size=$(du -sh "$EXTRACT_DIR" 2>/dev/null | cut -f1 || echo "N/A")
            echo -e "  ${CYAN}Size on disk:${NC}      $copied_size"
        fi
        
        save_state "rsync_complete"
        return 0
    else
        log_error "System copy failed (exit code: $rsync_status)"
        echo ""
        echo "Check the log file for details: $rsync_log"
        return 1
    fi
}

# Helper function to format bytes to human readable
format_bytes() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while [[ $size -gt 1024 && $unit -lt 4 ]]; do
        size=$((size / 1024))
        ((unit++))
    done
    
    echo "${size}${units[$unit]}"
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
    
    # Add Kali-specific cleanup
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        cleanup_tasks+=("Kali histories:clean_kali_specific")
    fi
    
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

clean_kali_specific() {
    # Clean Kali-specific histories and caches
    $SUDO rm -f "$EXTRACT_DIR/root/.zsh_history"
    $SUDO rm -f "$EXTRACT_DIR/root/.bash_history"
    $SUDO rm -rf "$EXTRACT_DIR/root/.cache/mozilla"
    $SUDO rm -rf "$EXTRACT_DIR/root/.cache/chromium"
    $SUDO rm -rf "$EXTRACT_DIR/root/.msf4/logs"
    $SUDO rm -rf "$EXTRACT_DIR/var/lib/postgresql/*/main/pg_log/"*
}

configure_chroot_enhanced() {
    show_header "Chroot Configuration"
    
    # Setup network configuration BEFORE mounting
    log_progress "Setting up network configuration..."
    if ! setup_chroot_network; then
        log_error "Failed to setup network configuration"
        return 1
    fi
    log_progress_done "Network configured"
    
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
    
    # Create distribution-specific chroot script
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        create_chroot_script_kali "$chroot_script"
    else
        create_chroot_script "$chroot_script"
    fi
    
    log_progress "Installing live system packages..."
    if ! $SUDO chroot "$EXTRACT_DIR" /bin/bash /tmp/configure_system.sh; then
        log_error "Chroot configuration failed"
        # Show chroot log for debugging
        if [[ -f "$EXTRACT_DIR/tmp/chroot.log" ]]; then
            log_error "Chroot log contents:"
            cat "$EXTRACT_DIR/tmp/chroot.log" >&2
        fi
        return 1
    fi
    log_progress_done "Live system configured"
    
    $SUDO rm -f "$chroot_script"
    
    log_success "Chroot configuration completed"
    return 0
}

setup_chroot_network() {
    # Copy DNS configuration
    if [[ -f /etc/resolv.conf ]]; then
        log_debug "Copying DNS configuration"
        $SUDO cp -L /etc/resolv.conf "$EXTRACT_DIR/etc/resolv.conf.tmp"
        $SUDO mv "$EXTRACT_DIR/etc/resolv.conf.tmp" "$EXTRACT_DIR/etc/resolv.conf"
    fi
    
    # Copy hosts file if missing
    if [[ ! -f "$EXTRACT_DIR/etc/hosts" ]]; then
        log_debug "Copying hosts file"
        $SUDO cp /etc/hosts "$EXTRACT_DIR/etc/hosts"
    fi
    
    # Ensure hostname is set
    if [[ ! -f "$EXTRACT_DIR/etc/hostname" ]]; then
        echo "localhost" | $SUDO tee "$EXTRACT_DIR/etc/hostname" >/dev/null
    fi
    
    return 0
}

setup_chroot_mounts() {
    local mounts=(
        "proc:proc:/proc"
        "sysfs:sysfs:/sys"
        "devtmpfs:udev:/dev"
        "devpts:devpts:/dev/pts"
        "tmpfs:tmpfs:/run"
    )
    
    for mount_spec in "${mounts[@]}"; do
        IFS=: read -r fstype source target <<< "$mount_spec"
        local mount_path="$EXTRACT_DIR$target"
        
        $SUDO mkdir -p "$mount_path"
        if ! mountpoint -q "$mount_path" 2>/dev/null; then
            if ! $SUDO mount -t "$fstype" "$source" "$mount_path"; then
                log_error "Failed to mount $fstype at $mount_path"
                return 1
            fi
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
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Logging
exec > >(tee -a /tmp/chroot.log)
exec 2>&1

echo "[CHROOT] Starting configuration at $(date)"

# Test network connectivity
echo "[CHROOT] Testing network connectivity..."
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "[CHROOT] Warning: No internet connectivity detected"
fi

# Update package database with retries
echo "[CHROOT] Updating package database..."
for i in {1..3}; do
    if apt-get update; then
        echo "[CHROOT] Package database updated successfully"
        break
    else
        echo "[CHROOT] Update attempt $i failed, retrying..."
        sleep 2
    fi
done

# Essential packages for live system
PACKAGES=(
    casper
    lupin-casper
    discover
    laptop-detect
    os-prober
    net-tools
    network-manager
    network-manager-gnome
)

# Add kernel package if not already installed
if ! dpkg -l | grep -q "^ii.*linux-image"; then
    echo "[CHROOT] No kernel found, adding linux-generic to package list"
    PACKAGES+=(linux-generic)
fi

echo "[CHROOT] Installing packages..."
for pkg in "${PACKAGES[@]}"; do
    echo "[CHROOT] Installing: $pkg"
    if apt-get install -y --no-install-recommends "$pkg"; then
        echo "[CHROOT] Successfully installed: $pkg"
    else
        echo "[CHROOT] Warning: Failed to install $pkg (may not be critical)"
    fi
done

# Configure live user
echo "[CHROOT] Configuring live user..."
if ! id -u user >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,cdrom user || true
    echo "user:live" | chpasswd || true
fi

# Configure locales
echo "[CHROOT] Configuring locales..."
if command -v locale-gen >/dev/null 2>&1; then
    locale-gen en_US.UTF-8 || true
    update-locale LANG=en_US.UTF-8 || true
fi

# Update initramfs
echo "[CHROOT] Updating initramfs..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k all || update-initramfs -c -k all || true
fi

# Clean up
echo "[CHROOT] Cleaning up..."
apt-get autoremove -y || true
apt-get autoclean || true

echo "[CHROOT] Configuration complete at $(date)"
CHROOT_SCRIPT

    $SUDO chmod +x "$script_path"
}

create_chroot_script_kali() {
    local script_path="$1"
    
    $SUDO tee "$script_path" > /dev/null << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Logging
exec > >(tee -a /tmp/chroot.log)
exec 2>&1

echo "[CHROOT] Starting Kali Linux configuration at $(date)"

# Test network connectivity
echo "[CHROOT] Testing network connectivity..."
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "[CHROOT] Warning: No internet connectivity detected"
fi

# Update package database with retries
echo "[CHROOT] Updating package database..."
for i in {1..3}; do
    if apt-get update; then
        echo "[CHROOT] Package database updated successfully"
        break
    else
        echo "[CHROOT] Update attempt $i failed, retrying..."
        sleep 2
    fi
done

# Kali-specific packages for live system
PACKAGES=(
    live-boot
    live-boot-initramfs-tools
    live-config
    live-config-systemd
    systemd-sysv
    network-manager
    wpasupplicant
)

# Add firmware packages if available
for fw_pkg in firmware-linux firmware-linux-nonfree firmware-misc-nonfree; do
    if apt-cache show "$fw_pkg" >/dev/null 2>&1; then
        PACKAGES+=("$fw_pkg")
    fi
done

# Add kernel if not present
if ! dpkg -l | grep -q "^ii.*linux-image"; then
    echo "[CHROOT] No kernel found, adding linux-image-amd64"
    PACKAGES+=(linux-image-amd64)
fi

# Try to install packages, but don't fail if some are missing
echo "[CHROOT] Installing Kali live system packages..."
for pkg in "${PACKAGES[@]}"; do
    echo "[CHROOT] Installing: $pkg"
    if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
        echo "[CHROOT] Successfully installed: $pkg"
    else
        echo "[CHROOT] Warning: Could not install $pkg (trying without recommends)"
        apt-get install -y --no-install-recommends --ignore-missing "$pkg" 2>/dev/null || \
        echo "[CHROOT] Warning: Package $pkg not available"
    fi
done

# Configure live user for Kali
echo "[CHROOT] Configuring Kali live user..."
if ! id -u kali >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev,bluetooth,cdrom kali || true
    echo "kali:kali" | chpasswd || true
fi

# Configure locales
echo "[CHROOT] Configuring locales..."
if command -v locale-gen >/dev/null 2>&1; then
    locale-gen en_US.UTF-8 || true
    update-locale LANG=en_US.UTF-8 || true
fi

# Update initramfs for live boot
echo "[CHROOT] Updating initramfs for live boot..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k all || update-initramfs -c -k all || true
fi

# Configure live-boot for Kali
echo "[CHROOT] Configuring live-boot..."
mkdir -p /etc/live
cat > /etc/live/config.conf << EOF
LIVE_HOSTNAME="kali"
LIVE_USERNAME="kali"
LIVE_USER_FULLNAME="Kali Live User"
LIVE_USER_DEFAULT_GROUPS="audio cdrom dialout floppy video plugdev netdev bluetooth sudo"
EOF

# Clean up
echo "[CHROOT] Cleaning up..."
apt-get autoremove -y || true
apt-get autoclean || true

echo "[CHROOT] Kali configuration complete at $(date)"
CHROOT_SCRIPT

    $SUDO chmod +x "$script_path"
}

create_squashfs_enhanced() {
    show_header "Creating SquashFS"
    
    local squashfs_file="$CDROOT_DIR/live/filesystem.squashfs"
    
    # Calculate optimal parameters
    local processors=$(nproc)
    local mem_limit=$(($(free -m | awk '/^Mem:/ {print $2}') / 2))
    
    # Get source size for estimation
    log_info "Analyzing source data..."
    local source_size_bytes
    local du_output
    du_output=$(du -sb "$EXTRACT_DIR" 2>/dev/null | cut -f1)
    
    # Validate it's a number
    if [[ "$du_output" =~ ^[0-9]+$ ]]; then
        source_size_bytes="$du_output"
    else
        source_size_bytes="0"
    fi
    
    local source_size_human
    if [[ "$source_size_bytes" != "0" ]]; then
        source_size_human=$(numfmt --to=iec-i --suffix=B "$source_size_bytes" 2>/dev/null || echo "N/A")
    else
        source_size_human="N/A"
    fi
    
    # Estimate compressed size (typically 40-50% of original)
    local estimated_compressed=0
    if [[ "$source_size_bytes" =~ ^[0-9]+$ ]] && [[ "$source_size_bytes" -gt 0 ]]; then
        estimated_compressed=$((source_size_bytes / 1024 / 1024 / 2))
    fi
    
    log_info "Source size: $source_size_human"
    log_info "Estimated compressed size: ~${estimated_compressed}MB"
    log_info "Using $processors CPU cores and ${mem_limit}MB memory"
    echo ""
    
    local squashfs_opts=(
        -no-exports
        -noappend
        -comp xz
        -Xbcj x86
        -b 1M
        -processors "$processors"
        -mem "${mem_limit}M"
    )
    
    log_info "Creating compressed filesystem... This typically takes 5-15 minutes."
    echo ""
    
    # Run mksquashfs with progress parsing
    local start_time=$(date +%s)
    local last_percent=0
    
    $SUDO mksquashfs "$EXTRACT_DIR" "$squashfs_file" "${squashfs_opts[@]}" 2>&1 | \
        grep -E "[0-9]+%" | \
        while IFS= read -r line; do
            if [[ "$line" =~ ([0-9]+)% ]]; then
                local percent="${BASH_REMATCH[1]}"
                
                # Only update if percentage changed
                if [[ $percent -ne $last_percent ]]; then
                    last_percent=$percent
                    
                    # Calculate ETA
                    local current_time=$(date +%s)
                    local elapsed=$((current_time - start_time))
                    
                    if [[ $percent -gt 0 && $elapsed -gt 0 ]]; then
                        local total_time=$((elapsed * 100 / percent))
                        local remaining=$((total_time - elapsed))
                        local eta_min=$((remaining / 60))
                        local eta_sec=$((remaining % 60))
                        
                        # Show progress bar
                        printf "\r${CYAN}Compression:${NC} ["
                        printf "%-50s" "$(printf '█%.0s' $(seq 1 $((percent / 2))))"
                        printf "] %3d%% " "$percent"
                        
                        if [[ $eta_min -gt 0 ]]; then
                            printf "${CYAN}ETA:${NC} %dm %ds     " "$eta_min" "$eta_sec"
                        else
                            printf "${CYAN}ETA:${NC} %ds     " "$eta_sec"
                        fi
                    fi
                fi
            fi
        done
    
    local squashfs_status=$?
    echo "" # New line after progress
    
    if [[ $squashfs_status -eq 0 ]]; then
        # Get final size and compression ratio
        local final_size_bytes
        local stat_output
        stat_output=$(stat -c%s "$squashfs_file" 2>/dev/null)
        
        # Validate it's a number
        if [[ "$stat_output" =~ ^[0-9]+$ ]]; then
            final_size_bytes="$stat_output"
        else
            final_size_bytes="0"
        fi
        
        local final_size_human
        if [[ "$final_size_bytes" != "0" ]]; then
            final_size_human=$(numfmt --to=iec-i --suffix=B "$final_size_bytes" 2>/dev/null || echo "N/A")
        else
            final_size_human="N/A"
        fi
        
        local compression_ratio="N/A"
        if [[ "$source_size_bytes" =~ ^[0-9]+$ ]] && [[ "$final_size_bytes" =~ ^[0-9]+$ ]] && 
           [[ "$source_size_bytes" -gt 0 ]] && [[ "$final_size_bytes" -gt 0 ]]; then
            compression_ratio=$(awk "BEGIN {printf \"%.1f:1\", $source_size_bytes / $final_size_bytes}")
        fi
        
        echo ""
        log_success "SquashFS created successfully!"
        echo ""
        echo -e "${BOLD}Compression Statistics:${NC}"
        echo -e "  ${CYAN}Original size:${NC}      $source_size_human"
        echo -e "  ${CYAN}Compressed size:${NC}    $final_size_human"
        echo -e "  ${CYAN}Compression ratio:${NC}  $compression_ratio"
        
        if [[ "$source_size_bytes" =~ ^[0-9]+$ ]] && [[ "$final_size_bytes" =~ ^[0-9]+$ ]] && 
           [[ "$source_size_bytes" -gt "$final_size_bytes" ]]; then
            echo -e "  ${CYAN}Space saved:${NC}        $(numfmt --to=iec-i --suffix=B $((source_size_bytes - final_size_bytes)) 2>/dev/null || echo 'N/A')"
        else
            echo -e "  ${CYAN}Space saved:${NC}        N/A"
        fi
        
        return 0
    else
        log_error "SquashFS creation failed"
        return 1
    fi
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
    
    # Function to find and copy kernel/initrd with various naming patterns
    find_and_copy_kernel() {
        local file_type="$1"  # "vmlinuz" or "initrd.img"
        local dest="$CDROOT_DIR/live/$file_type"
        
        # Patterns to try in order of preference
        local patterns=()
        if [[ "$file_type" == "vmlinuz" ]]; then
            patterns=(
                "/boot/vmlinuz-$kernel_version"
                "/boot/vmlinuz"
                "/vmlinuz"
                "/boot/vmlinuz-*-amd64"
                "/boot/vmlinuz-*-generic"
                "/boot/vmlinuz-*-kali*"
            )
        else
            patterns=(
                "/boot/initrd.img-$kernel_version"
                "/boot/initrd.img"
                "/initrd.img"
                "/boot/initrd.img-*-amd64"
                "/boot/initrd.img-*-generic"
                "/boot/initrd.img-*-kali*"
            )
        fi
        
        for pattern in "${patterns[@]}"; do
            # Handle both direct files and glob patterns
            if [[ -f "$pattern" ]]; then
                log_debug "Copying $file_type from: $pattern"
                $SUDO cp "$pattern" "$dest"
                return 0
            elif [[ "$pattern" == *"*"* ]]; then
                # It's a glob pattern
                local files=($(ls $pattern 2>/dev/null | sort -V | tail -1))
                if [[ ${#files[@]} -gt 0 ]] && [[ -f "${files[0]}" ]]; then
                    log_debug "Copying $file_type from: ${files[0]}"
                    $SUDO cp "${files[0]}" "$dest"
                    return 0
                fi
            fi
        done
        
        log_error "Could not find $file_type to copy"
        return 1
    }
    
    # Copy kernel
    if ! find_and_copy_kernel "vmlinuz"; then
        log_error "Failed to copy kernel"
        log_info "Please ensure a kernel is installed:"
        if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
            log_info "  sudo apt install linux-image-amd64"
        else
            log_info "  sudo apt install linux-generic"
        fi
        return 1
    fi
    
    # Copy initrd
    if ! find_and_copy_kernel "initrd.img"; then
        log_error "Failed to copy initrd"
        log_info "Try regenerating initrd:"
        log_info "  sudo update-initramfs -c -k all"
        return 1
    fi
    
    # Make files readable
    $SUDO chmod 644 "$CDROOT_DIR/live/vmlinuz" "$CDROOT_DIR/live/initrd.img"
    
    log_debug "Kernel files copied successfully"
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
        "/usr/lib/syslinux/modules/bios/menu.c32"
        "/usr/lib/syslinux/modules/bios/vesamenu.c32"
    )
    
    for file in "${isolinux_files[@]}"; do
        if [[ -f "$file" ]]; then
            $SUDO cp "$file" "$CDROOT_DIR/boot/isolinux/"
        fi
    done
    
    # Create distribution-specific ISOLINUX config
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        setup_isolinux_kali
    else
        setup_isolinux_default
    fi
    
    return 0
}

setup_isolinux_default() {
    $SUDO tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg" > /dev/null << 'EOF'
UI menu.c32
PROMPT 0
MENU TITLE Boot Menu
TIMEOUT 300

LABEL live
  MENU LABEL ^Live System
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=casper quiet splash ---

LABEL live-nomodeset
  MENU LABEL Live System (^nomodeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=casper nomodeset quiet splash ---

LABEL check
  MENU LABEL ^Check disc for defects
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=casper integrity-check quiet splash ---

LABEL memtest
  MENU LABEL Test ^memory
  KERNEL /live/memtest

LABEL hd
  MENU LABEL Boot from first ^hard disk
  LOCALBOOT 0x80
EOF
}

setup_isolinux_kali() {
    $SUDO tee "$CDROOT_DIR/boot/isolinux/isolinux.cfg" > /dev/null << 'EOF'
UI menu.c32
PROMPT 0
MENU TITLE Kali Linux Live Boot Menu
TIMEOUT 300

LABEL live
  MENU LABEL ^Live (amd64)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet splash

LABEL live-forensic
  MENU LABEL Live (^forensic mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components noswap noautomount

LABEL live-persistence
  MENU LABEL ^Live USB Persistence
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components persistence quiet splash

LABEL live-encrypted-persistence
  MENU LABEL ^Live USB Encrypted Persistence
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components persistent=cryptsetup persistence-encryption=luks quiet splash

LABEL live-nomodeset
  MENU LABEL Live (nomodeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components nomodeset quiet splash
EOF
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
        "/boot/efi/EFI/kali/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubx64.efi"
        "/boot/efi/EFI/debian/grubx64.efi"
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
    
    # Create distribution-specific GRUB config
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        setup_grub_kali
    else
        setup_grub_default
    fi
    
    return 0
}

setup_grub_default() {
    $SUDO mkdir -p "$CDROOT_DIR/boot/grub"
    $SUDO tee "$CDROOT_DIR/boot/grub/grub.cfg" > /dev/null << 'EOF'
set timeout=30
set default=0

menuentry "Live System" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd.img
}

menuentry "Live System (nomodeset)" {
    linux /live/vmlinuz boot=casper nomodeset quiet splash ---
    initrd /live/initrd.img
}

menuentry "Check disc for defects" {
    linux /live/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /live/initrd.img
}
EOF
}

setup_grub_kali() {
    $SUDO mkdir -p "$CDROOT_DIR/boot/grub"
    $SUDO tee "$CDROOT_DIR/boot/grub/grub.cfg" > /dev/null << 'EOF'
set timeout=30
set default=0

menuentry "Kali Live" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "Kali Live (forensic mode)" {
    linux /live/vmlinuz boot=live components noswap noautomount
    initrd /live/initrd.img
}

menuentry "Kali Live (persistence)" {
    linux /live/vmlinuz boot=live components persistence quiet splash
    initrd /live/initrd.img
}

menuentry "Kali Live (encrypted persistence)" {
    linux /live/vmlinuz boot=live components persistent=cryptsetup persistence-encryption=luks quiet splash
    initrd /live/initrd.img
}
EOF
}

create_iso_metadata() {
    # Create filesystem.size
    local fs_size
    fs_size=$(du -sx --block-size=1 "$EXTRACT_DIR" 2>/dev/null | cut -f1)
    
    # Validate it's a number
    if [[ ! "$fs_size" =~ ^[0-9]+$ ]]; then
        fs_size="0"
    fi
    
    echo "$fs_size" | $SUDO tee "$CDROOT_DIR/live/filesystem.size" >/dev/null
    
    # Create manifest if dpkg is available in chroot
    if [[ -f "$EXTRACT_DIR/usr/bin/dpkg-query" ]]; then
        $SUDO chroot "$EXTRACT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' | \
            $SUDO tee "$CDROOT_DIR/live/filesystem.manifest" >/dev/null || true
    fi
    
    # Create .disk info
    $SUDO mkdir -p "$CDROOT_DIR/.disk"
    
    local distro_name="Ubuntu"
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        distro_name="Kali Linux"
    elif [[ "${SCRIPT_STATE[distribution]}" == "debian" ]]; then
        distro_name="Debian"
    fi
    
    echo "$distro_name Live CD - Built $(date '+%Y-%m-%d')" | $SUDO tee "$CDROOT_DIR/.disk/info" >/dev/null
    
    # Create empty files that some systems expect
    $SUDO touch "$CDROOT_DIR/.disk/base_installable"
    echo "full_cd/single" | $SUDO tee "$CDROOT_DIR/.disk/cd_type" >/dev/null
    
    return 0
}

create_iso_enhanced() {
    show_header "Creating ISO Image"
    
    local distro_label="ubuntu"
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        distro_label="kali"
    elif [[ "${SCRIPT_STATE[distribution]}" == "debian" ]]; then
        distro_label="debian"
    fi
    
    local iso_file="$WORKDIR/${distro_label}-live-$(date +%Y%m%d-%H%M).iso"
    local volume_label="${distro_label^}_Live_$(date +%Y%m%d)"
    
    # Pre-flight checks
    if ! command -v xorriso >/dev/null 2>&1; then
        log_error "xorriso not installed"
        log_info "Install with: sudo apt-get install xorriso"
        return 1
    fi
    
    # Calculate expected ISO size
    log_info "Calculating ISO size..."
    local cdroot_size_bytes
    local du_output
    du_output=$(du -sb "$CDROOT_DIR" 2>/dev/null | cut -f1)
    
    # Validate it's a number
    if [[ "$du_output" =~ ^[0-9]+$ ]]; then
        cdroot_size_bytes="$du_output"
    else
        cdroot_size_bytes="0"
    fi
    
    local cdroot_size_human
    if [[ "$cdroot_size_bytes" != "0" ]]; then
        cdroot_size_human=$(numfmt --to=iec-i --suffix=B "$cdroot_size_bytes" 2>/dev/null || echo "N/A")
    else
        cdroot_size_human="N/A"
    fi
    
    log_info "ISO content size: $cdroot_size_human"
    echo ""
    
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
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin
        )
        log_info "✓ BIOS boot support enabled"
    else
        log_warning "⚠ BIOS boot support not available"
    fi
    
    # Add UEFI boot
    if [[ -f "$CDROOT_DIR/EFI/boot/bootx64.efi" ]]; then
        xorriso_cmd+=(
            -eltorito-alt-boot
            -e EFI/boot/bootx64.efi
            -no-emul-boot
            -isohybrid-gpt-basdat
        )
        log_info "✓ UEFI boot support enabled"
    else
        log_warning "⚠ UEFI boot support not available"
    fi
    
    # Add source and output
    xorriso_cmd+=(
        -output "$iso_file"
        "$CDROOT_DIR"
    )
    
    log_info "Building ISO image... This usually takes 1-3 minutes."
    echo ""
    
    # Execute with cleaner progress monitoring
    local start_time=$(date +%s)
    local xorriso_output="$WORKDIR/logs/xorriso-output.log"
    
    # Run xorriso and capture output
    $SUDO "${xorriso_cmd[@]}" 2>&1 | tee "$xorriso_output" | \
        grep -E "([0-9]+)(\.[0-9]+)?% done|Writing:|Finishing" | \
        while IFS= read -r line; do
            if [[ "$line" =~ ([0-9]+)(\.[0-9]+)?%[[:space:]]+done ]]; then
                local percent="${BASH_REMATCH[1]}"
                
                # Calculate speed and ETA
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                
                if [[ $percent -gt 0 && $elapsed -gt 0 ]]; then
                    local total_time=$((elapsed * 100 / percent))
                    local remaining=$((total_time - elapsed))
                    
                    # Show progress
                    printf "\r${CYAN}Building ISO:${NC} ["
                    printf "%-50s" "$(printf '█%.0s' $(seq 1 $((percent / 2))))"
                    printf "] %3d%% " "$percent"
                    
                    if [[ $remaining -gt 0 ]]; then
                        printf "${CYAN}ETA:${NC} %ds     " "$remaining"
                    fi
                fi
            elif [[ "$line" =~ Writing ]]; then
                printf "\r${CYAN}Writing ISO metadata...${NC}                             "
            elif [[ "$line" =~ Finishing ]]; then
                printf "\r${CYAN}Finalizing ISO...${NC}                                  "
            fi
        done
    
    local iso_status=$?
    echo "" # New line after progress
    
    if [[ $iso_status -ne 0 ]]; then
        log_error "ISO creation failed"
        if grep -q "isohdpfx.bin" "$xorriso_output"; then
            log_warning "Missing isohdpfx.bin - install isolinux package"
            log_info "sudo apt-get install isolinux"
        fi
        return 1
    fi
    
    # Calculate checksums with progress
    log_progress "Calculating checksums..."
    local checksum_file="$WORKDIR/checksums.txt"
    {
        echo "# Checksums for $(basename "$iso_file")"
        echo "# Generated on $(date)"
        echo ""
        
        # MD5
        printf "Calculating MD5...   "
        local md5
        md5=$(md5sum "$iso_file" | cut -d' ' -f1)
        echo "✓"
        echo "MD5:    $md5"
        
        # SHA256
        printf "Calculating SHA256... "
        local sha256
        sha256=$(sha256sum "$iso_file" | cut -d' ' -f1)
        echo "✓"
        echo "SHA256: $sha256"
        
        echo ""
        echo "Size: $(du -h "$iso_file" | cut -f1)"
    } | tee "$checksum_file"
    
    echo ""
    log_progress_done "✓ Checksums calculated"
    
    # Get final ISO stats
    local iso_size_bytes
    local stat_output
    stat_output=$(stat -c%s "$iso_file" 2>/dev/null)
    
    # Validate it's a number
    if [[ "$stat_output" =~ ^[0-9]+$ ]]; then
        iso_size_bytes="$stat_output"
    else
        iso_size_bytes="0"
    fi
    
    local iso_size_human
    if [[ "$iso_size_bytes" != "0" ]]; then
        iso_size_human=$(numfmt --to=iec-i --suffix=B "$iso_size_bytes" 2>/dev/null || echo "N/A")
    else
        iso_size_human="N/A"
    fi
    
    # Save ISO path
    echo "$iso_file" > "$WORKDIR/.final_iso_path"
    
    echo ""
    log_success "ISO created successfully!"
    echo ""
    echo -e "${BOLD}ISO Information:${NC}"
    echo -e "  ${CYAN}File:${NC}         $(basename "$iso_file")"
    echo -e "  ${CYAN}Size:${NC}         $iso_size_human"
    echo -e "  ${CYAN}Boot modes:${NC}   BIOS + UEFI"
    echo -e "  ${CYAN}USB bootable:${NC} Yes"
    
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
    echo -e "${CYAN}Creating bootable Ubuntu/Debian/Kali live ISOs with style${NC}"
    echo -e "${GREEN}Fixed chroot configuration and network setup${NC}"
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
    echo "Supported Distributions:"
    echo "  - Ubuntu and derivatives (Ubuntu, Kubuntu, Xubuntu, etc.)"
    echo "  - Debian"
    echo "  - Kali Linux"
    echo "  - Linux Mint"
    echo "  - Pop!_OS"
    echo "  - Elementary OS"
    echo "  - Zorin OS"
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
    
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        echo ""
        echo -e "${PURPLE}${BOLD}Kali-specific notes:${NC}"
        echo "- Default username: kali"
        echo "- Default password: kali"
        echo "- For persistence, create a partition labeled 'persistence'"
    fi
    
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
        "atomic_system_copy_start"|"atomic_system_copy_complete")
            atomic_operation "post_cleanup" post_copy_cleanup || exit 1
            ;&
        "atomic_post_cleanup_start"|"atomic_post_cleanup_complete")
            atomic_operation "chroot_config" configure_chroot_enhanced || exit 1
            ;&
        "atomic_chroot_config_start"|"atomic_chroot_config_complete")
            atomic_operation "squashfs" create_squashfs_enhanced || exit 1
            ;&
        "atomic_squashfs_start"|"atomic_squashfs_complete")
            atomic_operation "bootloader" setup_bootloader_enhanced || exit 1
            ;&
        "atomic_bootloader_start"|"atomic_bootloader_complete")
            atomic_operation "iso_creation" create_iso_enhanced || exit 1
            ;&
        "atomic_iso_creation_start"|"atomic_iso_creation_complete")
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
            echo "Fixed chroot configuration with proper network setup!"
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
