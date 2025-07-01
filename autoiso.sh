#!/bin/bash
# Enhanced AutoISO v3.1.3 - Professional Live ISO Creator with Kali Linux Support
# Fixed rsync hanging and improved reliability

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
readonly RSYNC_TIMEOUT=3600  # 1 hour timeout for rsync

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
    
    # Kill any background processes we might have started
    local autoiso_pids=$(pgrep -f "autoiso.sh" | grep -v $$ || true)
    if [[ -n "$autoiso_pids" ]]; then
        log_debug "Cleaning up background processes: $autoiso_pids"
        kill -TERM $autoiso_pids 2>/dev/null || true
        sleep 2
        kill -9 $autoiso_pids 2>/dev/null || true
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

safe_calculate_size() {
    local path="$1"
    local result=0
    
    # Use timeout to prevent hanging
    if command -v timeout >/dev/null 2>&1; then
        result=$(timeout 30 du -sk "$path" 2>/dev/null | cut -f1 || echo "0")
    else
        result=$(du -sk "$path" 2>/dev/null | cut -f1 || echo "0")
    fi
    
    # Ensure result is a valid number
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
        result="0"
    fi
    
    echo "$result"
}

validate_space_detailed() {
    log_info "Analyzing disk space requirements..."
    
    # Calculate system size using a safer method
    local system_size_kb
    system_size_kb=$(calculate_system_size_smart)
    
    # Validate the size is a number
    if [[ ! "$system_size_kb" =~ ^[0-9]+$ ]] || [[ "$system_size_kb" -eq 0 ]]; then
        log_warning "Could not accurately calculate system size, using conservative estimate"
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
    
    # Check available space with safer method
    local available_space_gb=0
    local df_output
    df_output=$(df "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    
    if [[ "$df_output" =~ ^[0-9]+$ ]] && [[ "$df_output" -gt 0 ]]; then
        available_space_gb=$((df_output / 1024 / 1024))
    else
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
    # Method 1: Precise calculation with timeout
    local size_kb
    size_kb=$(safe_calculate_size "/")
    
    if [[ "$size_kb" -gt 0 ]]; then
        # Subtract estimated cache/temp size
        local cache_size_kb=$((2 * 1024 * 1024))  # 2GB estimate
        local result=$((size_kb - cache_size_kb))
        
        # Ensure result is not negative or too small
        if [[ $result -lt $((5 * 1024 * 1024)) ]]; then
            result=$((10 * 1024 * 1024))  # 10GB minimum
        fi
        
        echo "$result"
    else
        # Conservative fallback
        if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
            echo $((20 * 1024 * 1024))  # 20GB default for Kali
        else
            echo $((15 * 1024 * 1024))  # 15GB default for others
        fi
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
    
    # Check system load (if bc is available)
    if command -v bc >/dev/null 2>&1; then
        local load_avg
        load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
        
        if (( $(echo "$load_avg > 10" | bc -l 2>/dev/null || echo 0) )); then
            log_warning "High system load: $load_avg"
        fi
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
#    CORE BUILD FUNCTIONS (FIXED RSYNC)
# ========================================

enhanced_rsync() {
    show_header "System Copy"
    
    local rsync_log="$WORKDIR/logs/rsync.log"
    local rsync_stats="$WORKDIR/logs/rsync-stats.log"
    
    # Estimate the total size to copy - using safer method
    log_info "Calculating system size for progress estimation..."
    local total_size_gb
    local estimated_size_kb
    estimated_size_kb=$(safe_calculate_size "/")
    
    if [[ "$estimated_size_kb" -gt 0 ]]; then
        total_size_gb=$((estimated_size_kb / 1024 / 1024))
    else
        total_size_gb=10  # Conservative estimate
    fi
    
    log_info "Estimated data to copy: ~${total_size_gb}GB"
    echo ""
    
    # Optimized exclusion list with Kali-specific additions
    local exclude_patterns=(
        "/dev/*" "/proc/*" "/sys/*" "/tmp/*" "/run/*" "/mnt/*" "/media/*"
        "/lost+found" "/.cache" "/var/cache/*" "/var/log/*.log"
        "/var/lib/docker/*" "/snap/*" "/swapfile" "$WORKDIR"
        "/home/*/.cache" "/root/.cache"
    )
    
    # Add Kali-specific exclusions if needed
    if [[ "${SCRIPT_STATE[distribution]}" == "kali" ]]; then
        exclude_patterns+=(
            "/root/.local/share/Trash"
            "/opt/metasploit-framework/embedded/framework/.git"
            "/var/lib/postgresql/*/main/pg_log/*"
        )
    fi
    
    # Simplified rsync options - removed complex progress monitoring
    local rsync_opts=(
        -aAXHx
        --numeric-ids
        --one-file-system
        --stats
        --human-readable
        --log-file="$rsync_log"
    )
    
    for pattern in "${exclude_patterns[@]}"; do
        rsync_opts+=(--exclude="$pattern")
    done
    
    log_info "Starting system copy..."
    log_info "This may take 10-45 minutes depending on system size and disk speed."
    log_info "Monitor progress in: tail -f $rsync_log"
    echo ""
    
    SCRIPT_STATE[cleanup_required]="true"
    save_state "rsync_active"
    
    local start_time=$(date +%s)
    
    # Run rsync with timeout and simplified monitoring
    local rsync_pid
    (
        # Run rsync in background and capture its PID
        timeout $RSYNC_TIMEOUT $SUDO rsync "${rsync_opts[@]}" / "$EXTRACT_DIR/" 2>&1 | \
            tee "$rsync_stats" &
        rsync_pid=$!
        
        # Simple progress indicator
        while kill -0 $rsync_pid 2>/dev/null; do
            local elapsed=$(($(date +%s) - start_time))
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))
            
            # Show current extraction size
            local current_size="0"
            if [[ -d "$EXTRACT_DIR" ]]; then
                current_size=$(du -sh "$EXTRACT_DIR" 2>/dev/null | cut -f1 || echo "0")
            fi
            
            printf "\r${CYAN}Copying system files...${NC} [%02d:%02d] Size: %s     " \
                "$minutes" "$seconds" "$current_size"
            
            sleep 5
        done
        
        wait $rsync_pid
        echo $? > "$WORKDIR/.rsync_exit_code"
    ) &
    
    local monitor_pid=$!
    
    # Wait for the monitor process to complete
    wait $monitor_pid
    local overall_status=$?
    
    # Get the actual rsync exit code
    local rsync_status=0
    if [[ -f "$WORKDIR/.rsync_exit_code" ]]; then
        rsync_status=$(cat "$WORKDIR/.rsync_exit_code")
    else
        rsync_status=$overall_status
    fi
    
    echo "" # New line after progress
    
    if [[ $rsync_status -eq 0 ]]; then
        local elapsed=$(($(date +%s) - start_time))
        local minutes=$((elapsed / 60))
        local seconds=$((elapsed % 60))
        
        # Parse final statistics
        if [[ -f "$rsync_stats" ]]; then
            local files_transferred=$(grep -E "Number of.*files transferred:" "$rsync_stats" | tail -1 | awk '{print $NF}' || echo "N/A")
            local total_size=$(grep -E "Total file size:" "$rsync_stats" | tail -1 | awk '{print $4,$5}' || echo "N/A")
            local transferred_size=$(grep -E "Total transferred file size:" "$rsync_stats" | tail -1 | awk '{print $5,$6}' || echo "N/A")
            
            echo ""
            log_success "System copy completed successfully!"
            echo ""
            echo -e "${BOLD}Copy Statistics:${NC}"
            echo -e "  ${CYAN}Time taken:${NC}        ${minutes}m ${seconds}s"
            echo -e "  ${CYAN}Files copied:${NC}       $files_transferred"
            echo -e "  ${CYAN}Total size:${NC}         $total_size"
            echo -e "  ${CYAN}Transferred:${NC}        $transferred_size"
            
            # Show actual copied size
            local copied_size
            copied_size=$(du -sh "$EXTRACT_DIR" 2>/dev/null | cut -f1 || echo "N/A")
            echo -e "  ${CYAN}Size on disk:${NC}       $copied_size"
        fi
        
        save_state "rsync_complete"
        return 0
    else
        log_error "System copy failed (exit code: $rsync_status)"
        echo ""
        log_info "Check the log files for details:"
        log_info "  Main log: $rsync_log"
        log_info "  Stats: $rsync_stats"
        
        if [[ $rsync_status -eq 124 ]]; then
            log_error "Rsync timed out after $RSYNC_TIMEOUT seconds"
        fi
        
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
    $SUDO rm -rf "$EXTRACT_DIR/var/cache/apt/archives/"*.deb 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/var/lib/apt/lists/"* 2>/dev/null || true
}

clean_logs() {
    $SUDO find "$EXTRACT_DIR/var/log" -type f \( -name "*.log" -o -name "*.gz" \) -delete 2>/dev/null || true
}

clean_temp() {
    $SUDO rm -rf "$EXTRACT_DIR/tmp/"* "$EXTRACT_DIR/var/tmp/"* 2>/dev/null || true
}

clean_ssh_keys() {
    $SUDO rm -rf "$EXTRACT_DIR/etc/ssh/ssh_host_"* 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/root/.ssh/" 2>/dev/null || true
}

clean_machine_ids() {
    $SUDO rm -f "$EXTRACT_DIR/etc/machine-id" 2>/dev/null || true
    $SUDO rm -f "$EXTRACT_DIR/var/lib/dbus/machine-id" 2>/dev/null || true
}

clean_kali_specific() {
    # Clean Kali-specific histories and caches
    $SUDO rm -f "$EXTRACT_DIR/root/.zsh_history" 2>/dev/null || true
    $SUDO rm -f "$EXTRACT_DIR/root/.bash_history" 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/root/.cache/mozilla" 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/root/.cache/chromium" 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/root/.msf4/logs" 2>/dev/null || true
    $SUDO rm -rf "$EXTRACT_DIR/var/lib/postgresql/*/main/pg_log/"* 2>/dev/null || true
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
    if ! timeout 1800 $SUDO chroot "$EXTRACT_DIR" /bin/bash /tmp/configure_system.sh; then
        log_error "Chroot configuration failed or timed out"
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

# Essential packages for live system
PACKAGES=(
    casper
    lupin-casper
    discover
    laptop-detect
    os-prober
    linux-generic
    net-tools
    network-manager
    live-boot
    live-boot-initramfs-tools
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
mkdir -p /etc/live
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

create_squashfs_enhanced() {
    show_header "Creating SquashFS"
    
    local squashfs_file="$CDROOT_DIR/live/filesystem.squashfs"
    
    # Calculate optimal parameters
    local processors=$(nproc)
    local available_mem=$(free -m | awk '/^Mem:/ {print $2}')
    local mem_limit=$((available_mem / 2))
    
    # Ensure memory limit is reasonable
    if [[ $mem_limit -lt 512 ]]; then
        mem_limit=512
    elif [[ $mem_limit -gt 4096 ]]; then
        mem_limit=4096
    fi
    
    # Get source size for estimation
    log_info "Analyzing source data..."
    local source_size_kb
    source_size_kb=$(safe_calculate_size "$EXTRACT_DIR")
    
    local source_size_human="N/A"
    if [[ "$source_size_kb" -gt 0 ]]; then
        source_size_human=$(numfmt --to=iec-i --suffix=B $((source_size_kb * 1024)) 2>/dev/null || echo "N/A")
    fi
    
    # Estimate compressed size (typically 40-50% of original)
    local estimated_compressed_mb=0
    if [[ "$source_size_kb" -gt 0 ]]; then
        estimated_compressed_mb=$((source_size_kb / 1024 / 2))
    fi
    
    log_info "Source size: $source_size_human"
    log_info "Estimated compressed size: ~${estimated_compressed_mb}MB"
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
    
    log_info "Creating compressed filesystem..."
    log_info "This typically takes 5-20 minutes depending on system size and CPU."
    echo ""
    
    # Run mksquashfs with timeout and simpler progress monitoring
    local start_time=$(date +%s)
    
    (
        timeout 3600 $SUDO mksquashfs "$EXTRACT_DIR" "$squashfs_file" "${squashfs_opts[@]}" 2>&1 &
        local mksquashfs_pid=$!
        
        # Simple progress monitor
        while kill -0 $mksquashfs_pid 2>/dev/null; do
            local elapsed=$(($(date +%s) - start_time))
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))
            
            # Show current file size
            local current_size="0"
            if [[ -f "$squashfs_file" ]]; then
                current_size=$(du -sh "$squashfs_file" 2>/dev/null | cut -f1 || echo "0")
            fi
            
            printf "\r${CYAN}Compressing filesystem...${NC} [%02d:%02d] Size: %s     " \
                "$minutes" "$seconds" "$current_size"
            
            sleep 10
        done
        
        wait $mksquashfs_pid
        echo $? > "$WORKDIR/.squashfs_exit_code"
    ) &
    
    wait
    
    # Get exit code
    local squashfs_status=0
    if [[ -f "$WORKDIR/.squashfs_exit_code" ]]; then
        squashfs_status=$(cat "$WORKDIR/.squashfs_exit_code")
    fi
    
    echo "" # New line after progress
    
    if [[ $squashfs_status -eq 0 ]] && [[ -f "$squashfs_file" ]]; then
        # Get final size and compression ratio
        local final_size_bytes
        final_size_bytes=$(stat -c%s "$squashfs_file" 2>/dev/null || echo "0")
        
        local final_size_human="N/A"
        if [[ "$final_size_bytes" -gt 0 ]]; then
            final_size_human=$(numfmt --to=iec-i --suffix=B "$final_size_bytes" 2>/dev/null || echo "N/A")
        fi
        
        local compression_ratio="N/A"
        if [[ "$source_size_kb" -gt 0 ]] && [[ "$final_size_bytes" -gt 0 ]]; then
            local source_size_bytes=$((source_size_kb * 1024))
            if command -v bc >/dev/null 2>&1; then
                compression_ratio=$(echo "scale=1; $source_size_bytes / $final_size_bytes" | bc)":1"
            fi
        fi
        
        echo ""
        log_success "SquashFS created successfully!"
        echo ""
        echo -e "${BOLD}Compression Statistics:${NC}"
        echo -e "  ${CYAN}Original size:${NC}      $source_size_human"
        echo -e "  ${CYAN}Compressed size:${NC}    $final_size_human"
        echo -e "  ${CYAN}Compression ratio:${NC}  $compression_ratio"
        
        return 0
    else
        log_error "SquashFS creation failed"
        if [[ $squashfs_status -eq 124 ]]; then
            log_error "SquashFS creation timed out after 1 hour"
        fi
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
MENU TITLE AutoISO Live Boot Menu
TIMEOUT 300

LABEL live
  MENU LABEL ^AutoISO Persistent Mode
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper persistent quiet splash ---

LABEL live-safe
  MENU LABEL AutoISO ^Safe Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper persistent acpi=off noapic nomodeset quiet splash ---

LABEL live-ram
  MENU LABEL AutoISO to ^RAM
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper persistent toram quiet splash ---

LABEL live-nopersist
  MENU LABEL AutoISO ^Live Mode (no persistence)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=casper quiet splash ---
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
  APPEND initrd=/live/initrd boot=live components persistence quiet splash

LABEL live-encrypted-persistence
  MENU LABEL ^Live USB Encrypted Persistence
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components persistence persistence-encryption=luks quiet splash
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

menuentry "AutoISO Persistent Mode" {
    linux /live/vmlinuz boot=casper persistent quiet splash ---
    initrd /live/initrd
}

menuentry "AutoISO Live Mode (no persistence)" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd
}

menuentry "AutoISO Safe Mode" {
    linux /live/vmlinuz boot=casper persistent acpi=off noapic nomodeset quiet splash ---
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
    linux /live/vmlinuz boot=live components persistence quiet splash
    initrd /live/initrd
}
EOF
}

create_iso_metadata() {
    # Create filesystem.size
    local fs_size
    fs_size=$(safe_calculate_size "$EXTRACT_DIR")
    
    if [[ "$fs_size" -gt 0 ]]; then
        echo "$((fs_size * 1024))" | $SUDO tee "$CDROOT_DIR/live/filesystem.size" >/dev/null
    else
        echo "0" | $SUDO tee "$CDROOT_DIR/live/filesystem.size" >/dev/null
    fi
    
    # Create manifest
    $SUDO chroot "$EXTRACT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' 2>/dev/null | \
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
    local cdroot_size_kb
    cdroot_size_kb=$(safe_calculate_size "$CDROOT_DIR")
    
    local cdroot_size_human="N/A"
    if [[ "$cdroot_size_kb" -gt 0 ]]; then
        cdroot_size_human=$(numfmt --to=iec-i --suffix=B $((cdroot_size_kb * 1024)) 2>/dev/null || echo "N/A")
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
    
    log_info "Building ISO image..."
    log_info "This usually takes 1-5 minutes."
    echo ""
    
    # Execute with timeout and simple progress monitoring
    local start_time=$(date +%s)
    local xorriso_output="$WORKDIR/logs/xorriso-output.log"
    
    # Run xorriso with timeout
    (
        timeout 1800 $SUDO "${xorriso_cmd[@]}" > "$xorriso_output" 2>&1 &
        local xorriso_pid=$!
        
        # Simple progress monitor
        while kill -0 $xorriso_pid 2>/dev/null; do
            local elapsed=$(($(date +%s) - start_time))
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))
            
            printf "\r${CYAN}Building ISO...${NC} [%02d:%02d]     " "$minutes" "$seconds"
            sleep 2
        done
        
        wait $xorriso_pid
        echo $? > "$WORKDIR/.xorriso_exit_code"
    ) &
    
    wait
    
    # Get exit code
    local iso_status=0
    if [[ -f "$WORKDIR/.xorriso_exit_code" ]]; then
        iso_status=$(cat "$WORKDIR/.xorriso_exit_code")
    fi
    
    echo "" # New line after progress
    
    if [[ $iso_status -ne 0 ]]; then
        log_error "ISO creation failed"
        log_info "Check output: $xorriso_output"
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
    
    # Calculate checksums
    log_progress "Calculating checksums..."
    local checksum_file="$WORKDIR/checksums.txt"
    {
        echo "# Checksums for $(basename "$iso_file")"
        echo "# Generated on $(date)"
        echo ""
        
        # MD5
        local md5
        md5=$(md5sum "$iso_file" | cut -d' ' -f1)
        echo "MD5:    $md5"
        
        # SHA256
        local sha256
        sha256=$(sha256sum "$iso_file" | cut -d' ' -f1)
        echo "SHA256: $sha256"
        
        echo ""
        echo "Size: $(du -h "$iso_file" | cut -f1)"
    } > "$checksum_file"
    
    log_progress_done "✓ Checksums calculated"
    
    # Get final ISO stats
    local iso_size_bytes
    iso_size_bytes=$(stat -c%s "$iso_file" 2>/dev/null || echo "0")
    
    local iso_size_human="N/A"
    if [[ "$iso_size_bytes" -gt 0 ]]; then
        iso_size_human=$(numfmt --to=iec-i --suffix=B "$iso_size_bytes" 2>/dev/null || echo "N/A")
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
    echo -e "${CYAN}Creating bootable Ubuntu/Debian/Kali live ISOs with enhanced reliability${NC}"
    echo -e "${GREEN}Fixed rsync hanging and improved error handling${NC}"
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
            echo "Fixed rsync hanging and improved reliability!"
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
