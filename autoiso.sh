#!/bin/bash
# Enhanced AutoISO v3.2.0 - Professional Live ISO Creator with Mount Point Protection
# Fixed to prevent copying mounted drives during system replication

set -euo pipefail

# ========================================
#    ENHANCED AUTOISO - ENTERPRISE GRADE
# ========================================

# Global configuration
readonly SCRIPT_VERSION="3.2.0"
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
#    MOUNT POINT DETECTION AND PROTECTION
# ========================================

# Get all mount points except special filesystems
get_all_mount_points() {
    # Get mount points, excluding special filesystems
    mount | grep -E '^/dev/' | awk '{print $3}' | sort -r
}

# Get mount points that are subdirectories of a given path
get_submounts() {
    local base_path="$1"
    local mount_point
    
    while IFS= read -r mount_point; do
        # Skip the base path itself
        if [[ "$mount_point" == "$base_path" ]]; then
            continue
        fi
        
        # Check if this mount point is under our base path
        if [[ "$mount_point" == "$base_path"/* ]]; then
            echo "$mount_point"
        fi
    done < <(get_all_mount_points)
}

# Build comprehensive exclusion list including all mount points
build_exclude_list() {
    local exclude_patterns=(
        # Standard system exclusions
        "/dev" "/proc" "/sys" "/tmp" "/run" "/mnt" "/media"
        "/lost+found" "/.cache" "/var/cache/apt" "/var/log"
        "/var/lib/docker" "/snap" "/swapfile" "$WORKDIR"
        
        # Additional safety exclusions
        "/var/tmp" "/var/crash" "/var/backups"
    )
    
    # Add all mount points that aren't the root filesystem
    local mount_point
    while IFS= read -r mount_point; do
        if [[ "$mount_point" != "/" ]]; then
            exclude_patterns+=("$mount_point")
            log_debug "Excluding mount point: $mount_point"
        fi
    done < <(get_all_mount_points)
    
    # Add Kali-specific exclusions if needed
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        exclude_patterns+=(
            "/root/.cache"
            "/root/.local/share/Trash"
            "/opt/metasploit-framework/embedded/framework/.git"
        )
    fi
    
    # Remove duplicates and sort
    local unique_excludes=($(printf '%s\n' "${exclude_patterns[@]}" | sort -u))
    
    echo "${unique_excludes[@]}"
}

# Check if extract directory has any mounted filesystems
check_extract_dir_mounts() {
    local extract_dir="$1"
    local has_mounts=false
    local mount_point
    
    # Check if extract_dir itself is a mount point
    if mountpoint -q "$extract_dir" 2>/dev/null; then
        log_warning "$extract_dir is a mount point itself"
    fi
    
    # Check for any mounts under extract_dir
    local submounts=$(get_submounts "$extract_dir")
    if [[ -n "$submounts" ]]; then
        log_error "Found mounted filesystems under $extract_dir:"
        echo "$submounts" | while read -r mount_point; do
            log_error "  - $mount_point"
        done
        has_mounts=true
    fi
    
    if [[ "$has_mounts" == "true" ]]; then
        log_error "Cannot proceed with mounted filesystems in extract directory"
        log_info "Please unmount them first or they will be included in the ISO"
        return 1
    fi
    
    return 0
}

# Validate extracted size is reasonable
validate_extracted_size() {
    local extract_dir="$1"
    local max_reasonable_size_gb=100  # Adjust based on your needs
    
    local size_gb=$(du -sx "$extract_dir" 2>/dev/null | awk '{print int($1/1024/1024)}')
    
    if [[ $size_gb -gt $max_reasonable_size_gb ]]; then
        log_warning "Extracted filesystem is ${size_gb}GB - larger than expected"
        log_warning "This might indicate mounted filesystems were copied"
        
        # Show largest directories
        log_info "Largest directories in extract:"
        du -sh "$extract_dir"/* 2>/dev/null | sort -rh | head -10
        
        read -p "Continue anyway? (y/N): " -r continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# ========================================
#    CLEANUP AND ERROR HANDLING
# ========================================

cleanup_all() {
    log_info "Starting cleanup process..."
    
    # Kill any background processes we might have started
    local autoiso_pids=$(pgrep -f "autoiso.sh" | grep -v $$ || true)
    if [[ -n "$autoiso_pids" ]]; then
        log_debug "Cleaning up background processes: $autoiso_pids"
        kill -TERM $autoiso_pids 2>/dev/null || true
        sleep 2
        kill -9 $autoiso_pids 2>/dev/null || true
    fi
    
    # Kill any mksquashfs processes that might be hanging
    local squashfs_pids=$(pgrep -f "mksquashfs" || true)
    if [[ -n "$squashfs_pids" ]]; then
        log_debug "Cleaning up squashfs processes: $squashfs_pids"
        $SUDO kill -TERM $squashfs_pids 2>/dev/null || true
        sleep 2
        $SUDO kill -9 $squashfs_pids 2>/dev/null || true
    fi
    
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
        "Mount points:validate_mount_points"
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

validate_mount_points() {
    log_info "Detecting mounted filesystems..."
    
    # Show all mount points that will be excluded
    local mount_points=($(get_all_mount_points))
    local excluded_count=0
    
    echo ""
    echo "Mounted filesystems detected:"
    for mount_point in "${mount_points[@]}"; do
        if [[ "$mount_point" == "/" ]]; then
            echo "  $mount_point (root - will be copied)"
        else
            echo "  $mount_point (will be excluded)"
            ((excluded_count++))
        fi
    done
    
    if [[ $excluded_count -gt 0 ]]; then
        echo ""
        log_info "Found $excluded_count mounted filesystem(s) that will be excluded from the ISO"
        
        # Check for large mounted drives
        local large_mounts=()
        for mount_point in "${mount_points[@]}"; do
            if [[ "$mount_point" != "/" ]]; then
                local size_gb=$(df "$mount_point" 2>/dev/null | awk 'NR==2 {print int($2/1024/1024)}' || echo "0")
                if [[ $size_gb -gt 100 ]]; then
                    large_mounts+=("$mount_point (${size_gb}GB)")
                fi
            fi
        done
        
        if [[ ${#large_mounts[@]} -gt 0 ]]; then
            log_warning "Large mounted drives detected that will be excluded:"
            for mount in "${large_mounts[@]}"; do
                echo "  - $mount"
            done
        fi
    fi
    
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
        "mountpoint:util-linux"
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
    
    # Method 1: Precise du calculation with mount exclusions
    if size_kb=$(calculate_size_du_safe); then
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

calculate_size_du_safe() {
    # Build exclude arguments from our comprehensive exclude list
    local exclude_args=()
    local excludes=($(build_exclude_list))
    
    for pattern in "${excludes[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done
    
    local size_output
    # Add timeout to prevent hanging
    if command -v timeout >/dev/null 2>&1; then
        size_output=$(timeout 60 du -sx "${exclude_args[@]}" / 2>/dev/null | cut -f1 || echo "0")
    else
        size_output=$(du -sx "${exclude_args[@]}" / 2>/dev/null | cut -f1 || echo "0")
    fi
    
    # Ensure we have a valid number
    if [[ ! "$size_output" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 1
    else
        echo "$size_output"
        return 0
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
#    CORE BUILD FUNCTIONS (MOUNT-SAFE)
# ========================================

show_disk_activity() {
    # Show disk I/O stats if available
    if command -v iostat >/dev/null 2>&1; then
        echo -n "  Disk activity: "
        iostat -d 1 2 | tail -n 2 | head -n 1 | awk '{print "Read: " $3 " KB/s, Write: " $4 " KB/s"}' || echo "monitoring..."
    fi
}

enhanced_rsync() {
    show_header "System Copy (Mount-Safe)"
    
    local rsync_log="$WORKDIR/logs/rsync.log"
    
    # Build comprehensive exclusion list
    log_info "Building exclusion list for mounted filesystems..."
    local exclude_list=($(build_exclude_list))
    
    echo ""
    log_info "Excluding ${#exclude_list[@]} paths from copy (including all mounted filesystems)"
    
    # First, estimate the total size to copy
    log_info "Calculating system size for accurate progress..."
    local total_size_bytes
    local total_size_human
    
    # Get estimated size using our safe calculation
    local system_size_kb=$(calculate_size_du_safe)
    
    # Validate it's a number
    if [[ "$system_size_kb" =~ ^[0-9]+$ ]] && [[ $system_size_kb -gt 0 ]]; then
        total_size_bytes=$((system_size_kb * 1024))
    else
        # Fallback to a reasonable estimate
        total_size_bytes=$((10 * 1024 * 1024 * 1024))  # 10GB in bytes
    fi
    
    total_size_human=$(numfmt --to=si --suffix=B "$total_size_bytes" 2>/dev/null || echo "~10GB")
    
    log_info "Estimated data to copy: $total_size_human"
    
    # Check if this seems reasonable
    local size_gb=$((total_size_bytes / 1024 / 1024 / 1024))
    if [[ $size_gb -gt 50 ]]; then
        log_warning "System size appears large (${size_gb}GB)"
        log_warning "This might indicate mounted filesystems are being included"
        read -p "Continue with copy? (y/N): " -r continue_copy
        if [[ ! "$continue_copy" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    echo ""
    
    # Build rsync options with all exclusions
    local rsync_opts=(
        -aHx
        --numeric-ids
        --one-file-system
        --log-file="$rsync_log"
        --stats
        --human-readable
        --info=progress2
    )
    
    # Add all exclusions
    for pattern in "${exclude_list[@]}"; do
        rsync_opts+=(--exclude="$pattern")
    done
    
    log_info "Starting system copy... This may take 10-30 minutes depending on system size and disk speed."
    log_info "Only copying the root filesystem - all other mounts are excluded"
    SCRIPT_STATE[cleanup_required]="true"
    save_state "rsync_active"
    
    # Create exclude list file for debugging
    printf '%s\n' "${exclude_list[@]}" > "$WORKDIR/exclude-list.txt"
    log_debug "Exclude list saved to: $WORKDIR/exclude-list.txt"
    
    # MOUNT-SAFE: Use simpler progress monitoring
    local stats_file="$WORKDIR/.rsync_stats"
    local start_time=$(date +%s)
    
    # Start rsync with performance optimizations
    log_info "Running rsync (mount-safe mode)..."
    echo ""
    
    # Create a more robust rsync execution
    local rsync_pid
    local monitor_pid
    
    # Start rsync in background
    $SUDO rsync "${rsync_opts[@]}" / "$EXTRACT_DIR/" > "$stats_file" 2>&1 &
    rsync_pid=$!
    
    # Start a separate progress monitor
    (
        while kill -0 $rsync_pid 2>/dev/null; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))
            
            # Check current size of extract dir
            local current_size=$(du -sh "$EXTRACT_DIR" 2>/dev/null | cut -f1 || echo "calculating...")
            
            printf "\r${CYAN}Copying system files...${NC} Time: %02d:%02d Size: %s     " \
                "$minutes" "$seconds" "$current_size"
            
            sleep 5
        done
    ) &
    monitor_pid=$!
    
    # Wait for rsync to complete
    wait $rsync_pid
    local rsync_status=$?
    
    # Clean up monitor process
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true
    
    echo "" # New line after progress
    
    if [[ $rsync_status -eq 0 ]]; then
        local elapsed=$(($(date +%s) - start_time))
        local minutes=$((elapsed / 60))
        local seconds=$((elapsed % 60))
        
        # Validate the extracted size
        log_info "Validating extracted filesystem size..."
        if ! validate_extracted_size "$EXTRACT_DIR"; then
            log_error "Extracted size validation failed"
            return 1
        fi
        
        # Check for any mounted filesystems in extract
        log_info "Checking for mounted filesystems in extract directory..."
        if ! check_extract_dir_mounts "$EXTRACT_DIR"; then
            log_error "Found mounted filesystems in extract directory"
            return 1
        fi
        
        # Parse final statistics
        if [[ -f "$stats_file" ]]; then
            local files_transferred=$(grep -E "Number of.*files transferred:" "$stats_file" | awk '{print $NF}' || echo "N/A")
            local total_size=$(grep -E "Total file size:" "$stats_file" | awk '{print $4,$5}' || echo "N/A")
            local transferred_size=$(grep -E "Total transferred file size:" "$stats_file" | awk '{print $5,$6}' || echo "N/A")
            
            echo ""
            log_success "System copy completed successfully!"
            echo ""
            echo -e "${BOLD}Copy Statistics:${NC}"
            echo -e "  ${CYAN}Time taken:${NC}        ${minutes}m ${seconds}s"
            echo -e "  ${CYAN}Files copied:${NC}      $files_transferred"
            echo -e "  ${CYAN}Total size:${NC}        $total_size"
            echo -e "  ${CYAN}Transferred:${NC}       $transferred_size"
            
            # Show final copied size
            local copied_size
            copied_size=$(du -sh "$EXTRACT_DIR" 2>/dev/null | cut -f1 || echo "N/A")
            echo -e "  ${CYAN}Final size on disk:${NC} $copied_size"
            echo -e "  ${CYAN}Excluded mounts:${NC}    ${#exclude_list[@]} paths"
        fi
        
        save_state "rsync_complete"
        return 0
    else
        log_error "System copy failed (exit code: $rsync_status)"
        echo ""
        echo "Check the log file for details: $rsync_log"
        echo "Check the stats file for details: $stats_file"
        echo "Check excluded paths: $WORKDIR/exclude-list.txt"
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
    
    # Extra safety check - ensure no mounts in extract
    log_info "Final mount point check before cleanup..."
    if ! check_extract_dir_mounts "$EXTRACT_DIR"; then
        log_error "Cannot proceed - mounted filesystems detected"
        return 1
    fi
    
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
    
    local task_count=0
    local total_tasks=${#cleanup_tasks[@]}
    
    for task in "${cleanup_tasks[@]}"; do
        local desc="${task%:*}"
        local func="${task#*:}"
        ((task_count++))
        
        log_progress "Cleaning $desc... ($task_count/$total_tasks)"
        
        # Run cleanup with progress monitoring
        local cleanup_start=$(date +%s)
        
        # Call the function directly with monitoring
        if $func; then
            local cleanup_duration=$(($(date +%s) - cleanup_start))
            log_progress_done "Cleaned $desc (${cleanup_duration}s)"
        else
            log_warning "Error cleaning $desc"
        fi
    done
    
    log_success "Post-copy cleanup completed"
    return 0
}

clean_package_caches() {
    # Use faster, safer cleanup methods
    $SUDO rm -rf "$EXTRACT_DIR/var/cache/apt/archives/"*.deb 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/var/lib/apt/lists/"* 2>/dev/null || true
    return 0
}

clean_logs() {
    # Simple, fast log cleanup
    $SUDO find "$EXTRACT_DIR/var/log" -type f \( -name "*.log" -o -name "*.gz" \) -delete 2>/dev/null || true
    return 0
}

clean_temp() {
    # Fast temp cleanup
    $SUDO rm -rf "$EXTRACT_DIR/tmp/"* 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/var/tmp/"* 2>/dev/null || true
    return 0
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

create_chroot_script_kali() {
    local script_path="$1"
    
    $SUDO tee "$script_path" > /dev/null << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

echo "[CHROOT] Kali Linux specific configuration..."

# Update package database
echo "[CHROOT] Updating package database..."
apt-get update || true

# Kali-specific packages for live system
PACKAGES=(
    live-boot
    live-boot-initramfs-tools
    live-config
    live-config-systemd
    linux-image-amd64
    systemd-sysv
    network-manager
    wpasupplicant
    firmware-linux
    firmware-linux-nonfree
    firmware-misc-nonfree
)

echo "[CHROOT] Installing Kali live system packages..."
for pkg in "${PACKAGES[@]}"; do
    echo "[CHROOT] Installing: $pkg"
    apt-get install -y "$pkg" || echo "[CHROOT] Warning: Failed to install $pkg"
done

# Configure locales
echo "[CHROOT] Configuring locales..."
locale-gen en_US.UTF-8 || true
update-locale LANG=en_US.UTF-8 || true

# Update initramfs for live boot
echo "[CHROOT] Updating initramfs for live boot..."
update-initramfs -u || update-initramfs -c -k all || true

# Configure live-boot
echo "[CHROOT] Configuring live-boot..."
cat > /etc/live/config.conf << EOF
LIVE_HOSTNAME="kali"
LIVE_USERNAME="kali"
LIVE_USER_FULLNAME="Kali Live User"
LIVE_USER_DEFAULT_GROUPS="audio cdrom dialout floppy video plugdev netdev sudo"
EOF

# Clean up
apt-get autoremove -y || true
apt-get autoclean || true

echo "[CHROOT] Kali configuration complete"
CHROOT_SCRIPT

    $SUDO chmod +x "$script_path"
}

# ========================================
#    MOUNT-SAFE SQUASHFS FUNCTION
# ========================================

create_squashfs_enhanced() {
    show_header "Creating SquashFS (Mount-Safe)"
    
    # Final safety check before squashfs
    log_info "Final safety check for mounted filesystems..."
    if ! check_extract_dir_mounts "$EXTRACT_DIR"; then
        log_error "Cannot create squashfs - mounted filesystems detected in extract"
        return 1
    fi
    
    local squashfs_file="$CDROOT_DIR/live/filesystem.squashfs"
    
    # Calculate optimal parameters with memory safety
    local processors=$(nproc)
    local available_mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
    local mem_limit=$((available_mem_mb / 4))  # Use only 25% of RAM for safety
    
    # Minimum 512MB, maximum 4GB for mksquashfs
    if [[ $mem_limit -lt 512 ]]; then
        mem_limit=512
    elif [[ $mem_limit -gt 4096 ]]; then
        mem_limit=4096
    fi
    
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
    
    # Final size check - if it's huge, something went wrong
    local size_gb=$((source_size_bytes / 1024 / 1024 / 1024))
    if [[ $size_gb -gt 50 ]]; then
        log_error "Extract directory is ${size_gb}GB - this is unexpectedly large!"
        log_error "This usually means mounted filesystems were included in the copy"
        
        # Show what's taking up space
        log_info "Largest directories in extract:"
        du -sh "$EXTRACT_DIR"/* 2>/dev/null | sort -rh | head -10
        
        return 1
    fi
    
    # Check if this is a large filesystem (>10GB)
    local is_large_fs=false
    if [[ "$source_size_bytes" =~ ^[0-9]+$ ]] && [[ "$source_size_bytes" -gt $((10 * 1024 * 1024 * 1024)) ]]; then
        is_large_fs=true
        log_warning "Large filesystem detected (>10GB). Using optimized settings."
    fi
    
    # Estimate compressed size (typically 40-50% of original)
    local estimated_compressed=0
    if [[ "$source_size_bytes" =~ ^[0-9]+$ ]] && [[ "$source_size_bytes" -gt 0 ]]; then
        estimated_compressed=$((source_size_bytes / 1024 / 1024 / 2))
    fi
    
    log_info "Source size: $source_size_human"
    log_info "Estimated compressed size: ~${estimated_compressed}MB"
    log_info "Using $processors CPU cores and ${mem_limit}MB memory limit"
    
    # Check available memory before starting
    local free_mem_mb=$(free -m | awk '/^Mem:/ {print $4}')
    if [[ $free_mem_mb -lt 1024 ]]; then
        log_warning "Low memory available: ${free_mem_mb}MB free"
        log_info "Consider closing other applications or using a system with more RAM"
    fi
    
    echo ""
    
    # Choose compression based on filesystem size
    local compression_method="xz"
    local compression_opts=()
    
    if [[ "$is_large_fs" == "true" ]]; then
        # For large filesystems, use gzip for better stability
        compression_method="gzip"
        compression_opts=(-comp gzip -Xcompression-level 6)
        log_info "Using gzip compression for stability on large filesystem"
    else
        # For smaller filesystems, use XZ with careful settings
        compression_opts=(-comp xz -Xbcj x86 -Xdict-size 100%)
        log_info "Using XZ compression for better ratio on smaller filesystem"
    fi
    
    local squashfs_opts=(
        -no-exports
        -noappend
        "${compression_opts[@]}"
        -b 1M
        -processors "$processors"
        -mem "${mem_limit}M"
    )
    
    log_info "Creating compressed filesystem... This may take 5-30 minutes depending on size."
    echo ""
    
    # Create a status file for monitoring
    local status_file="$WORKDIR/.squashfs_status"
    local progress_file="$WORKDIR/.squashfs_progress"
    echo "0" > "$progress_file"
    
    # Save diagnostic info
    cat > "$WORKDIR/.squashfs_diagnostic" << EOF
SOURCE_SIZE: $source_size_human
SOURCE_PATH: $EXTRACT_DIR
DESTINATION: $squashfs_file
COMPRESSION: $compression_method
PROCESSORS: $processors
MEMORY_LIMIT: ${mem_limit}MB
AVAILABLE_MEM: ${free_mem_mb}MB
STARTED: $(date)
OPTIONS: ${squashfs_opts[@]}
EOF
    
    # Start mksquashfs with better error handling
    local start_time=$(date +%s)
    local squashfs_log="$WORKDIR/logs/squashfs.log"
    local squashfs_pid
    local monitor_pid
    
    # Run mksquashfs in background with full logging
    (
        $SUDO mksquashfs "$EXTRACT_DIR" "$squashfs_file" "${squashfs_opts[@]}" 2>&1 | \
        tee "$squashfs_log" | \
        grep -E "[0-9]+%" | \
        while IFS= read -r line; do
            if [[ "$line" =~ ([0-9]+)% ]]; then
                echo "${BASH_REMATCH[1]}" > "$progress_file"
            fi
        done
        echo $? > "$status_file"
    ) &
    squashfs_pid=$!
    
    # Monitor progress with timeout protection
    local timeout_minutes=120  # 2 hour timeout for very large filesystems
    local timeout_seconds=$((timeout_minutes * 60))
    local last_progress=0
    local stall_count=0
    local max_stalls=20  # Allow up to 20 checks without progress (5 minutes)
    
    (
        while kill -0 $squashfs_pid 2>/dev/null; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            # Check for timeout
            if [[ $elapsed -gt $timeout_seconds ]]; then
                log_error "SquashFS creation timed out after ${timeout_minutes} minutes"
                $SUDO kill -TERM $squashfs_pid 2>/dev/null || true
                sleep 5
                $SUDO kill -9 $squashfs_pid 2>/dev/null || true
                break
            fi
            
            # Read current progress
            local current_progress=$(cat "$progress_file" 2>/dev/null || echo "0")
            
            # Check for stalls
            if [[ "$current_progress" == "$last_progress" ]]; then
                ((stall_count++))
                if [[ $stall_count -gt $max_stalls ]]; then
                    log_error "SquashFS appears to be stalled (no progress for 5 minutes)"
                    # Save diagnostic info
                    echo "STALLED at ${current_progress}% after ${elapsed}s" >> "$WORKDIR/.squashfs_diagnostic"
                    ps aux | grep -E "(mksquashfs|xz)" >> "$WORKDIR/.squashfs_diagnostic"
                    free -m >> "$WORKDIR/.squashfs_diagnostic"
                    
                    $SUDO kill -TERM $squashfs_pid 2>/dev/null || true
                    sleep 5
                    $SUDO kill -9 $squashfs_pid 2>/dev/null || true
                    break
                fi
            else
                stall_count=0
                last_progress=$current_progress
            fi
            
            # Calculate ETA
            if [[ $current_progress -gt 0 ]]; then
                local total_time=$((elapsed * 100 / current_progress))
                local remaining=$((total_time - elapsed))
                local eta_min=$((remaining / 60))
                local eta_sec=$((remaining % 60))
                
                # Show progress
                printf "\r${CYAN}Compression:${NC} ["
                printf "%-50s" "$(printf '█%.0s' $(seq 1 $((current_progress / 2))))"
                printf "] %3d%% " "$current_progress"
                
                if [[ $eta_min -gt 0 ]]; then
                    printf "${CYAN}ETA:${NC} %dm %ds " "$eta_min" "$eta_sec"
                else
                    printf "${CYAN}ETA:${NC} %ds " "$eta_sec"
                fi
                
                # Show memory usage
                local mem_used=$(ps aux | grep -E "mksquashfs.*$squashfs_file" | awk '{sum+=$6} END {print int(sum/1024)}' || echo "0")
                if [[ $mem_used -gt 0 ]]; then
                    printf "${CYAN}Mem:${NC} %dMB     " "$mem_used"
                fi
            else
                local minutes=$((elapsed / 60))
                local seconds=$((elapsed % 60))
                printf "\r${CYAN}Initializing compression...${NC} Time: %02d:%02d     " "$minutes" "$seconds"
            fi
            
            sleep 15
        done
    ) &
    monitor_pid=$!
    
    # Wait for squashfs to complete
    wait $squashfs_pid
    local wait_status=$?
    
    # Kill monitor
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true
    
    echo "" # New line after progress
    
    # Get actual exit status
    local squashfs_status=$wait_status
    if [[ -f "$status_file" ]]; then
        squashfs_status=$(cat "$status_file")
    fi
    
    # Update diagnostic file
    echo "ENDED: $(date)" >> "$WORKDIR/.squashfs_diagnostic"
    echo "EXIT_CODE: $squashfs_status" >> "$WORKDIR/.squashfs_diagnostic"
    
    if [[ $squashfs_status -eq 0 ]] && [[ -f "$squashfs_file" ]]; then
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
        
        local elapsed=$(($(date +%s) - start_time))
        local minutes=$((elapsed / 60))
        local seconds=$((elapsed % 60))
        
        echo ""
        log_success "SquashFS created successfully!"
        echo ""
        echo -e "${BOLD}Compression Statistics:${NC}"
        echo -e "  ${CYAN}Time taken:${NC}         ${minutes}m ${seconds}s"
        echo -e "  ${CYAN}Original size:${NC}      $source_size_human"
        echo -e "  ${CYAN}Compressed size:${NC}    $final_size_human"
        echo -e "  ${CYAN}Compression ratio:${NC}  $compression_ratio"
        echo -e "  ${CYAN}Compression type:${NC}   $compression_method"
        
        if [[ "$source_size_bytes" =~ ^[0-9]+$ ]] && [[ "$final_size_bytes" =~ ^[0-9]+$ ]] && 
           [[ "$source_size_bytes" -gt "$final_size_bytes" ]]; then
            echo -e "  ${CYAN}Space saved:${NC}        $(numfmt --to=iec-i --suffix=B $((source_size_bytes - final_size_bytes)) 2>/dev/null || echo 'N/A')"
        fi
        
        # Verify the squashfs file
        log_progress "Verifying squashfs integrity..."
        if $SUDO unsquashfs -stat "$squashfs_file" >/dev/null 2>&1; then
            log_progress_done "SquashFS integrity verified"
        else
            log_warning "Could not verify squashfs integrity"
        fi
        
        return 0
    else
        log_error "SquashFS creation failed"
        echo ""
        echo "Diagnostic information saved to: $WORKDIR/.squashfs_diagnostic"
        echo "Log file: $squashfs_log"
        
        # Show last few lines of log
        if [[ -f "$squashfs_log" ]]; then
            echo ""
            echo "Last 10 lines of squashfs log:"
            tail -10 "$squashfs_log"
        fi
        
        # Suggest solutions
        echo ""
        echo -e "${YELLOW}Possible solutions:${NC}"
        echo "1. Free up more memory and try again"
        echo "2. Use a smaller block size: add '-b 256K' to squashfs options"
        echo "3. Use gzip compression instead of XZ for large filesystems"
        echo "4. Check disk space: df -h $WORKDIR"
        echo "5. Check system resources: free -h"
        
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
DEFAULT live
TIMEOUT 300

LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper quiet splash ---

LABEL check
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper integrity-check quiet splash ---
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
  APPEND initrd=/live/initrd boot=live components quiet splash

LABEL live-forensic
  MENU LABEL Live (^forensic mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components noswap noautomount

LABEL live-persistence
  MENU LABEL ^Live USB Persistence
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistence persistence-encryption=luks quiet splash

LABEL live-encrypted-persistence
  MENU LABEL ^Live USB Encrypted Persistence
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistent=cryptsetup persistence-encryption=luks quiet splash
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
    $SUDO tee "$CDROOT_DIR/EFI/boot/grub.cfg" > /dev/null << 'EOF'
set timeout=30
set default=0

menuentry "Live System" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd
}
EOF
}

setup_grub_kali() {
    $SUDO tee "$CDROOT_DIR/EFI/boot/grub.cfg" > /dev/null << 'EOF'
set timeout=30
set default=0

menuentry "Kali Live" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}

menuentry "Kali Live (forensic mode)" {
    linux /live/vmlinuz boot=live components noswap noautomount
    initrd /live/initrd
}

menuentry "Kali Live (persistence)" {
    linux /live/vmlinuz boot=live components persistence persistence-encryption=luks quiet splash
    initrd /live/initrd
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
    
    # Create manifest
    $SUDO chroot "$EXTRACT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' | \
        $SUDO tee "$CDROOT_DIR/live/filesystem.manifest" >/dev/null || true
    
    # Create .disk info
    $SUDO mkdir -p "$CDROOT_DIR/.disk"
    
    local distro_name="Ubuntu"
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        distro_name="Kali Linux"
    elif [[ "${SCRIPT_STATE[distribution]}" == "debian" ]]; then
        distro_name="Debian"
    fi
    
    echo "$distro_name Live CD - Built $(date '+%Y-%m-%d')" | $SUDO tee "$CDROOT_DIR/.disk/info" >/dev/null
    
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
        return 1
    fi
    
    # Make hybrid
    if command -v isohybrid >/dev/null 2>&1; then
        log_progress "Making ISO USB-bootable..."
        if $SUDO isohybrid "$iso_file" 2>/dev/null; then
            log_progress_done "✓ ISO is now USB-bootable"
        else
            log_warning "⚠ Could not make ISO hybrid (not critical)"
        fi
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
    
    # Show transition message
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Stage: ${BOLD}$operation_name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local start_time=$(date +%s)
    
    # Add disk activity monitoring for operations that do heavy I/O
    if [[ "$operation_name" =~ (system_copy|post_cleanup|squashfs) ]]; then
        show_disk_activity
    fi
    
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
    echo -e "${GREEN}Mount-safe: Protects against copying mounted drives${NC}"
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
            echo "Mount-safe version that prevents copying mounted drives!"
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
