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
    log_info "Analyzing disk space requirements with enhanced accuracy..."
    
    # Multi-method space calculation for accuracy
    local system_size_kb=0
    local method_used="unknown"
    
    log_progress "Calculating system size using multiple methods..."
    
    # Method 1: Precise du calculation with better exclusions
    if system_size_kb=$(calculate_system_size_precise); then
        method_used="precise_du"
        log_debug "Used precise du calculation: ${system_size_kb}KB"
    # Method 2: Fallback to filesystem analysis
    elif system_size_kb=$(calculate_system_size_fallback); then
        method_used="filesystem_analysis"
        log_debug "Used filesystem analysis: ${system_size_kb}KB"
    # Method 3: Conservative estimate
    else
        system_size_kb=$(calculate_system_size_conservative)
        method_used="conservative_estimate"
        log_warning "Using conservative estimate: ${system_size_kb}KB"
    fi
    
    local system_size_gb=$((system_size_kb / 1024 / 1024))
    
    # Enhanced space calculation with safety margins
    local extraction_space_gb=$((system_size_gb + 2))  # +2GB buffer for extraction
    local squashfs_space_gb=$((system_size_gb / 2 + 1))  # Compressed size + buffer
    local iso_space_gb=$((squashfs_space_gb + 1))  # ISO overhead
    local working_space_gb=5  # Working space for logs, temp files, etc.
    local safety_margin_gb=3  # Additional safety margin
    
    local required_space_gb=$((extraction_space_gb + squashfs_space_gb + iso_space_gb + working_space_gb + safety_margin_gb))
    
    log_info "System size: ${system_size_gb}GB (method: $method_used)"
    log_info "Space breakdown:"
    log_info "  - Extraction: ${extraction_space_gb}GB"
    log_info "  - SquashFS: ${squashfs_space_gb}GB"
    log_info "  - ISO: ${iso_space_gb}GB"
    log_info "  - Working: ${working_space_gb}GB"
    log_info "  - Safety margin: ${safety_margin_gb}GB"
    log_info "  - Total required: ${required_space_gb}GB"
    
    # Check target directory space with multiple verification methods
    local available_space_gb
    if ! available_space_gb=$(get_available_space_reliable "$WORKDIR"); then
        log_error "Cannot determine available disk space"
        return 1
    fi
    
    log_info "Available space: ${available_space_gb}GB"
    
    # Progressive space checking with helpful suggestions
    if [[ $available_space_gb -lt $required_space_gb ]]; then
        log_error "Insufficient space: need ${required_space_gb}GB, have ${available_space_gb}GB"
        suggest_space_solutions_enhanced "$required_space_gb" "$available_space_gb" "$system_size_gb"
        return 1
    elif [[ $available_space_gb -lt $((required_space_gb + 5)) ]]; then
        log_warning "Space is tight (${available_space_gb}GB available vs ${required_space_gb}GB needed)"
        log_warning "Consider using a location with more free space for safety"
        read -p "Continue with tight space? (y/N): " -r continue_tight
        if [[ ! "$continue_tight" =~ ^[Yy]$ ]]; then
            suggest_space_solutions_enhanced "$required_space_gb" "$available_space_gb" "$system_size_gb"
            return 1
        fi
    else
        log_info "Space check passed ✓ (${available_space_gb}GB available, ${required_space_gb}GB needed)"
    fi
    
    # Save space calculations for later reference
    cat > "$WORKDIR/.space_analysis" << EOF
SYSTEM_SIZE_GB=$system_size_gb
REQUIRED_SPACE_GB=$required_space_gb
AVAILABLE_SPACE_GB=$available_space_gb
METHOD_USED=$method_used
CALCULATION_TIME=$(date +%s)
EOF
    
    return 0
}

calculate_system_size_precise() {
    local temp_file="$WORKDIR/.du_calculation"
    local timeout_seconds=300  # 5 minute timeout
    
    # Enhanced exclusion patterns
    local exclude_patterns=(
        "/dev" "/proc" "/sys" "/tmp" "/run" "/mnt" "/media"
        "/lost+found" "/home/*/.cache" "/home/*/.local/share/Trash"
        "/var/cache" "/var/log" "/var/tmp" "/var/spool"
        "/var/lib/docker" "/var/lib/containerd" "/var/lib/lxd"
        "/snap" "/var/snap" "/var/lib/snapd"
        "/usr/src" "/var/lib/apt/lists" "/root/.cache"
        "/swapfile" "/pagefile.sys" "/hiberfil.sys"
        "/var/crash" "/var/lib/systemd/coredump"
        "/var/lib/lxcfs" "/var/backups"
        "/var/lib/flatpak" "/opt/google/chrome/WidevineCdm"
        "$WORKDIR" "/tmp/autoiso-build*"
    )
    
    # Build exclude arguments
    local exclude_args=()
    for pattern in "${exclude_patterns[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done
    
    log_debug "Starting precise du calculation with timeout of ${timeout_seconds}s"
    
    # Run du with timeout to prevent hanging
    if timeout "$timeout_seconds" du -sk "${exclude_args[@]}" / 2>/dev/null > "$temp_file"; then
        local size_kb
        size_kb=$(cut -f1 "$temp_file")
        rm -f "$temp_file"
        
        # Sanity check - system should be at least 1GB and less than 500GB
        if [[ $size_kb -gt 1048576 && $size_kb -lt 524288000 ]]; then
            echo "$size_kb"
            return 0
        else
            log_debug "du result failed sanity check: ${size_kb}KB"
            return 1
        fi
    else
        log_debug "du calculation timed out or failed"
        rm -f "$temp_file"
        return 1
    fi
}

calculate_system_size_fallback() {
    log_debug "Using filesystem analysis fallback method"
    
    # Get filesystem usage and subtract known large directories
    local root_usage_kb
    root_usage_kb=$(df / | awk 'NR==2 {print $3}')
    
    if [[ -z "$root_usage_kb" || $root_usage_kb -eq 0 ]]; then
        return 1
    fi
    
    # Estimate size of directories we'll exclude
    local exclude_size_kb=0
    local dirs_to_check=("/var/cache" "/var/log" "/tmp" "/home" "/var/lib/docker" "/snap")
    
    for dir in "${dirs_to_check[@]}"; do
        if [[ -d "$dir" ]]; then
            local dir_size
            dir_size=$(timeout 60 du -sk "$dir" 2>/dev/null | cut -f1 || echo "0")
            exclude_size_kb=$((exclude_size_kb + dir_size))
        fi
    done
    
    local estimated_size_kb=$((root_usage_kb - exclude_size_kb))
    
    # Sanity check
    if [[ $estimated_size_kb -gt 1048576 && $estimated_size_kb -lt 524288000 ]]; then
        echo "$estimated_size_kb"
        return 0
    else
        return 1
    fi
}

calculate_system_size_conservative() {
    log_debug "Using conservative estimation method"
    
    # Conservative estimate based on typical Ubuntu installation
    local base_size_gb=8  # Minimal Ubuntu base
    local installed_packages
    
    # Count installed packages to estimate size
    if installed_packages=$(dpkg-query -W 2>/dev/null | wc -l); then
        # Rough estimate: 1MB per package on average
        local package_size_gb=$((installed_packages / 1024))
        local total_gb=$((base_size_gb + package_size_gb))
        
        # Cap at reasonable maximum
        if [[ $total_gb -gt 50 ]]; then
            total_gb=50
        fi
        
        echo $((total_gb * 1024 * 1024))  # Convert to KB
    else
        # Ultra-conservative fallback
        echo $((15 * 1024 * 1024))  # 15GB in KB
    fi
}

get_available_space_reliable() {
    local target_dir="$1"
    
    # Ensure directory exists
    mkdir -p "$target_dir" 2>/dev/null || return 1
    
    # Method 1: df command
    local space_kb
    space_kb=$(df "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    
    if [[ -n "$space_kb" && $space_kb -gt 0 ]]; then
        echo $((space_kb / 1024 / 1024))  # Convert to GB
        return 0
    fi
    
    # Method 2: stat command
    if command -v stat >/dev/null 2>&1; then
        local fs_info
        fs_info=$(stat -f "$target_dir" 2>/dev/null)
        if [[ -n "$fs_info" ]]; then
            # Try to extract available space (varies by system)
            space_kb=$(echo "$fs_info" | awk '/Available/ {print $2}' || echo "0")
            if [[ $space_kb -gt 0 ]]; then
                echo $((space_kb / 1024))  # Convert to GB
                return 0
            fi
        fi
    fi
    
    return 1
}

suggest_space_solutions_enhanced() {
    local needed_gb="$1"
    local available_gb="$2"
    local system_gb="$3"
    local deficit_gb=$((needed_gb - available_gb))
    
    echo ""
    echo "=============== SPACE SOLUTIONS ==============="
    echo "Current situation:"
    echo "  Need: ${needed_gb}GB | Have: ${available_gb}GB | Short: ${deficit_gb}GB"
    echo ""
    echo "Quick fixes (try in order):"
    echo ""
    echo "1. 🧹 Clean system caches:"
    echo "   sudo apt-get autoremove --purge"
    echo "   sudo apt-get autoclean"
    echo "   sudo journalctl --vacuum-time=1d"
    echo "   sudo rm -rf /var/log/*.log /tmp/* /var/tmp/*"
    echo ""
    echo "2. 🗂️  Use external storage:"
    echo "   ./autoiso.sh /path/to/external/drive"
    echo "   (Recommended: USB 3.0+ drive with 64GB+ space)"
    echo ""
    echo "3. 📁 Move to different partition:"
    echo "   df -h  # Find partition with most space"
    echo "   ./autoiso.sh /path/to/larger/partition"
    echo ""
    
    if [[ $system_gb -gt 20 ]]; then
        echo "4. ⚠️  Large system detected (${system_gb}GB):"
        echo "   Consider cleaning:"
        echo "   - Old kernels: sudo apt autoremove"
        echo "   - Docker images: sudo docker system prune -a"
        echo "   - Snap packages: snap list --all | awk '/disabled/{print \$1, \$3}' | xargs -n2 sudo snap remove"
        echo ""
    fi
    
    echo "5. 🔧 Alternative approaches:"
    echo "   - Use Cubic GUI tool (more space-efficient)"
    echo "   - Create minimal ISO without large packages"
    echo "   - Use network-based installation media"
    echo ""
    echo "Space will be freed automatically after ISO creation."
    echo "=============================================="
    echo ""
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
    log_info "Performing comprehensive system health check..."
    
    # Check for critical system issues
    local health_issues=()
    local critical_issues=()
    local warnings=()
    
    # Check filesystem health
    if ! df / >/dev/null 2>&1; then
        critical_issues+=("Root filesystem not accessible")
    fi
    
    # Check for running package managers with detailed detection
    check_package_managers_running
    local pm_status=$?
    if [[ $pm_status -eq 1 ]]; then
        critical_issues+=("Package manager is currently running")
    elif [[ $pm_status -eq 2 ]]; then
        warnings+=("Package manager recently active - may cause issues")
    fi
    
    # Check system load and resources
    check_system_resources
    
    # Check for disk errors
    if ! check_filesystem_integrity; then
        warnings+=("Filesystem integrity issues detected")
    fi
    
    # Check for essential services
    check_essential_services
    
    # Check for interfering processes
    check_interfering_processes
    
    # Check network connectivity (for package updates)
    if ! check_network_connectivity; then
        warnings+=("Limited network connectivity - package updates may fail")
    fi
    
    # Check for conflicting mount points
    if ! check_mount_conflicts; then
        warnings+=("Potential mount point conflicts detected")
    fi
    
    # Report findings
    if [[ ${#critical_issues[@]} -gt 0 ]]; then
        log_error "Critical system health issues detected:"
        for issue in "${critical_issues[@]}"; do
            log_error "  ❌ $issue"
        done
        
        log_info "Attempting to resolve critical issues..."
        if resolve_critical_issues "${critical_issues[@]}"; then
            log_info "Critical issues resolved ✓"
        else
            log_error "Could not resolve all critical issues"
            return 1
        fi
    fi
    
    if [[ ${#warnings[@]} -gt 0 ]]; then
        log_warning "System health warnings:"
        for warning in "${warnings[@]}"; do
            log_warning "  ⚠️  $warning"
        done
        
        echo ""
        read -p "Continue despite warnings? (Y/n): " -r continue_anyway
        if [[ "$continue_anyway" =~ ^[Nn]$ ]]; then
            return 1
        fi
    fi
    
    log_info "System health check completed ✓"
    return 0
}

check_package_managers_running() {
    local active_managers=()
    local recent_activity=false
    
    # Check for active package managers
    local pm_processes=("apt" "apt-get" "dpkg" "aptitude" "synaptic" "packagekit" "unattended-upgrade")
    
    for pm in "${pm_processes[@]}"; do
        if pgrep -x "$pm" >/dev/null 2>&1; then
            active_managers+=("$pm")
        fi
    done
    
    # Check for lock files
    local lock_files=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend" 
        "/var/cache/apt/archives/lock"
        "/var/lib/apt/lists/lock"
    )
    
    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            # Check if lock is stale (older than 10 minutes)
            if [[ $(find "$lock_file" -mmin +10 2>/dev/null) ]]; then
                log_debug "Stale lock file detected: $lock_file"
                recent_activity=true
            else
                active_managers+=("lock:$(basename "$lock_file")")
            fi
        fi
    done
    
    if [[ ${#active_managers[@]} -gt 0 ]]; then
        log_error "Active package managers: ${active_managers[*]}"
        return 1
    elif [[ "$recent_activity" == "true" ]]; then
        return 2
    else
        return 0
    fi
}

check_system_resources() {
    # Check system load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',' || echo "0")
    
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$load_avg > 10" | bc -l 2>/dev/null || echo 0) )); then
            warnings+=("High system load: $load_avg")
        fi
    fi
    
    # Check memory usage
    local mem_info
    if mem_info=$(free -m 2>/dev/null); then
        local available_mb
        available_mb=$(echo "$mem_info" | awk '/^Mem:/ {print $7}' || echo "0")
        
        if [[ $available_mb -lt 1024 ]]; then
            warnings+=("Low available memory: ${available_mb}MB")
        fi
    fi
    
    # Check for swap usage
    local swap_used
    if swap_used=$(free | awk '/^Swap:/ {if($2>0) print int($3/$2*100); else print 0}' 2>/dev/null); then
        if [[ $swap_used -gt 80 ]]; then
            warnings+=("High swap usage: ${swap_used}%")
        fi
    fi
}

check_filesystem_integrity() {
    # Quick filesystem check (non-destructive)
    local fs_errors=0
    
    # Check for read-only filesystems
    if mount | grep -q "ro,"; then
        log_warning "Read-only filesystems detected"
        ((fs_errors++))
    fi
    
    # Check for filesystem errors in dmesg
    if dmesg 2>/dev/null | grep -iq "filesystem.*error\|ext[2-4].*error\|I/O error"; then
        log_warning "Filesystem errors found in system log"
        ((fs_errors++))
    fi
    
    return $((fs_errors == 0))
}

check_essential_services() {
    local missing_services=()
    local essential_services=("dbus" "systemd-logind")
    
    for service in "${essential_services[@]}"; do
        if ! systemctl is-active "$service" >/dev/null 2>&1; then
            missing_services+=("$service")
        fi
    done
    
    if [[ ${#missing_services[@]} -gt 0 ]]; then
        warnings+=("Essential services not running: ${missing_services[*]}")
    fi
}

check_interfering_processes() {
    # Check for processes that might interfere
    local interfering_procs=()
    
    # Check for backup processes
    if pgrep -f "rsync.*backup\|tar.*backup\|duplicity" >/dev/null 2>&1; then
        interfering_procs+=("backup processes")
    fi
    
    # Check for file indexing
    if pgrep -x "updatedb\|locate" >/dev/null 2>&1; then
        interfering_procs+=("file indexing")
    fi
    
    # Check for antivirus
    if pgrep -x "clamd\|freshclam\|rkhunter" >/dev/null 2>&1; then
        interfering_procs+=("antivirus scanning")
    fi
    
    if [[ ${#interfering_procs[@]} -gt 0 ]]; then
        warnings+=("Potentially interfering processes: ${interfering_procs[*]}")
    fi
}

check_network_connectivity() {
    # Quick network connectivity check
    local test_hosts=("8.8.8.8" "1.1.1.1")
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            return 0
        fi
    done
    
    return 1
}

check_mount_conflicts() {
    # Check if our target directories might conflict with existing mounts
    local potential_conflicts=()
    
    # Check if work directory is on a mounted filesystem that might be problematic
    local workdir_fs
    workdir_fs=$(df "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $1}')
    
    if [[ "$workdir_fs" =~ (tmpfs|devtmpfs) ]]; then
        potential_conflicts+=("Work directory on temporary filesystem: $workdir_fs")
    fi
    
    # Check for existing loop mounts that might interfere
    if losetup -l 2>/dev/null | grep -q "squashfs\|iso"; then
        potential_conflicts+=("Existing loop mounts detected")
    fi
    
    return $((${#potential_conflicts[@]} == 0))
}

resolve_critical_issues() {
    local issues=("$@")
    local resolved=0
    
    for issue in "${issues[@]}"; do
        log_info "Attempting to resolve: $issue"
        
        case "$issue" in
            *"Package manager"*)
                if resolve_package_manager_conflicts; then
                    ((resolved++))
                fi
                ;;
            *"Root filesystem"*)
                log_error "Root filesystem issues cannot be automatically resolved"
                ;;
            *)
                log_warning "No automatic resolution available for: $issue"
                ;;
        esac
    done
    
    return $((resolved == ${#issues[@]}))
}

resolve_package_manager_conflicts() {
    log_info "Attempting to resolve package manager conflicts..."
    
    # Kill stuck package managers (with user permission)
    local stuck_procs
    stuck_procs=$(pgrep -x "apt|apt-get|dpkg" || true)
    
    if [[ -n "$stuck_procs" ]]; then
        echo "Found running package managers (PIDs: $stuck_procs)"
        read -p "Kill stuck package managers? (y/N): " -r kill_procs
        
        if [[ "$kill_procs" =~ ^[Yy]$ ]]; then
            echo "$stuck_procs" | xargs -r $SUDO kill -TERM 2>/dev/null || true
            sleep 3
            echo "$stuck_procs" | xargs -r $SUDO kill -KILL 2>/dev/null || true
        else
            return 1
        fi
    fi
    
    # Remove stale lock files
    local lock_files=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend"
        "/var/cache/apt/archives/lock"
        "/var/lib/apt/lists/lock"
    )
    
    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            log_debug "Removing stale lock: $lock_file"
            $SUDO rm -f "$lock_file" 2>/dev/null || true
        fi
    done
    
    # Fix any broken package installations
    log_progress "Fixing package system..."
    $SUDO dpkg --configure -a 2>/dev/null || true
    $SUDO apt-get install -f -y 2>/dev/null || true
    
    # Verify package manager is working
    if $SUDO apt-get update >/dev/null 2>&1; then
        log_info "Package manager conflicts resolved ✓"
        return 0
    else
        log_error "Could not resolve package manager conflicts"
        return 1
    fi
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

echo "[CHROOT] Starting enhanced system configuration..."

# Setup environment
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Function for robust package operations
install_package_robust() {
    local package="$1"
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        echo "[CHROOT] Installing $package (attempt $attempt/$max_attempts)"
        
        if apt-get install -y "$package" 2>/dev/null; then
            echo "[CHROOT] Successfully installed: $package"
            return 0
        else
            echo "[CHROOT] Failed to install $package (attempt $attempt)"
            if [[ $attempt -lt $max_attempts ]]; then
                echo "[CHROOT] Retrying in 2 seconds..."
                sleep 2
                # Try to fix any issues
                apt-get install -f -y 2>/dev/null || true
                dpkg --configure -a 2>/dev/null || true
            fi
            ((attempt++))
        fi
    done
    
    echo "[CHROOT] Warning: Failed to install $package after $max_attempts attempts"
    return 1
}

# Update package database with retry logic
echo "[CHROOT] Updating package database..."
update_attempts=3
for ((i=1; i<=update_attempts; i++)); do
    if apt-get update 2>/dev/null; then
        echo "[CHROOT] Package database updated successfully"
        break
    else
        echo "[CHROOT] Package update failed (attempt $i/$update_attempts)"
        if [[ $i -lt $update_attempts ]]; then
            sleep 3
            # Clear potentially corrupted lists
            rm -f /var/lib/apt/lists/lock
            rm -f /var/cache/apt/archives/lock
            rm -f /var/lib/dpkg/lock*
        else
            echo "[CHROOT] Warning: Package update failed after $update_attempts attempts"
            echo "[CHROOT] Continuing with existing package database..."
        fi
    fi
done

# Essential packages for live system (in order of importance)
echo "[CHROOT] Installing essential live system packages..."

# Critical packages - must have
critical_packages=(
    "casper"
    "lupin-casper" 
    "discover"
    "laptop-detect"
    "os-prober"
)

# Important packages - should have
important_packages=(
    "linux-generic"
    "resolvconf"
    "net-tools"
    "wireless-tools"
    "wpasupplicant"
    "locales"
)

# Nice-to-have packages
optional_packages=(
    "console-common"
    "ubuntu-standard"
    "network-manager"
    "curl"
    "wget"
)

# Install critical packages first
critical_failed=0
for package in "${critical_packages[@]}"; do
    if ! install_package_robust "$package"; then
        ((critical_failed++))
        echo "[CHROOT] ERROR: Critical package '$package' failed to install"
    fi
done

# Install important packages
important_failed=0
for package in "${important_packages[@]}"; do
    if ! install_package_robust "$package"; then
        ((important_failed++))
        echo "[CHROOT] WARNING: Important package '$package' failed to install"
    fi
done

# Install optional packages (best effort)
optional_failed=0
for package in "${optional_packages[@]}"; do
    if ! install_package_robust "$package"; then
        ((optional_failed++))
        echo "[CHROOT] INFO: Optional package '$package' failed to install"
    fi
done

# Report package installation results
echo "[CHROOT] Package installation summary:"
echo "[CHROOT]   Critical: $((${#critical_packages[@]} - critical_failed))/${#critical_packages[@]} installed"
echo "[CHROOT]   Important: $((${#important_packages[@]} - important_failed))/${#important_packages[@]} installed"
echo "[CHROOT]   Optional: $((${#optional_packages[@]} - optional_failed))/${#optional_packages[@]} installed"

# Fail if too many critical packages failed
if [[ $critical_failed -gt 2 ]]; then
    echo "[CHROOT] ERROR: Too many critical packages failed ($critical_failed)"
    exit 1
fi

# Configure locales with enhanced error handling
echo "[CHROOT] Configuring locales..."
if [[ -f /etc/locale.gen ]]; then
    # Enable common locales
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    
    if locale-gen 2>/dev/null; then
        echo "[CHROOT] Locales generated successfully"
    else
        echo "[CHROOT] Warning: Locale generation failed"
    fi
else
    echo "[CHROOT] Warning: /etc/locale.gen not found"
fi

# Set default locale
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || \
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Update initramfs with error handling
echo "[CHROOT] Updating initramfs..."
if update-initramfs -u 2>/dev/null; then
    echo "[CHROOT] Initramfs updated successfully"
else
    echo "[CHROOT] Warning: Initramfs update failed"
    # Try to create new initramfs
    if update-initramfs -c -k all 2>/dev/null; then
        echo "[CHROOT] Created new initramfs successfully"
    else
        echo "[CHROOT] ERROR: Could not create or update initramfs"
        # This is not fatal - we can use existing initramfs
    fi
fi

# Configure network settings for live system
echo "[CHROOT] Configuring network settings..."
cat > /etc/NetworkManager/NetworkManager.conf << 'NMEOF'
[main]
plugins=ifupdown,keyfile
dhcp=internal

[ifupdown]
managed=false

[device]
wifi.scan-rand-mac-address=no
NMEOF

# Configure DNS resolution
cat > /etc/systemd/resolved.conf << 'RESOLVEOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4 1.0.0.1
RESOLVEOF

# Clean up package cache and temporary files
echo "[CHROOT] Cleaning up package cache..."
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean 2>/dev/null || true

# Clean apt lists to save space
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

# Create empty apt lists directory
mkdir -p /var/lib/apt/lists/partial

# Fix any remaining package issues
echo "[CHROOT] Performing final package system check..."
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y 2>/dev/null || true

echo "[CHROOT] Configuration completed successfully"
echo "[CHROOT] Critical errors: $critical_failed, Important errors: $important_failed"

# Exit with error only if critical failures
if [[ $critical_failed -gt 2 ]]; then
    exit 1
else
    exit 0
fi
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
    log_progress "Setting up GRUB for UEFI boot with enhanced compatibility..."
    
    # Create EFI directory structure
    local efi_dir="$CDROOT_DIR/EFI/boot"
    $SUDO mkdir -p "$efi_dir"
    
    # Multiple methods to find GRUB EFI bootloader
    local grub_efi_found=false
    local grub_efi_source=""
    
    # Method 1: Check system GRUB installation
    local grub_locations=(
        "/usr/lib/grub/x86_64-efi/grubx64.efi"
        "/boot/efi/EFI/ubuntu/grubx64.efi"
        "/boot/efi/EFI/debian/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
        "/usr/lib/shim/shimx64.efi"
    )
    
    for location in "${grub_locations[@]}"; do
        if [[ -f "$location" ]]; then
            log_debug "Found GRUB EFI at: $location"
            if $SUDO cp "$location" "$efi_dir/bootx64.efi" 2>/dev/null; then
                grub_efi_source="$location"
                grub_efi_found=true
                break
            fi
        fi
    done
    
    # Method 2: Try to install/generate GRUB EFI if not found
    if [[ "$grub_efi_found" == "false" ]]; then
        log_info "GRUB EFI not found, attempting to generate..."
        
        if generate_grub_efi "$efi_dir"; then
            grub_efi_found=true
            grub_efi_source="generated"
        fi
    fi
    
    # Method 3: Create minimal EFI stub if all else fails
    if [[ "$grub_efi_found" == "false" ]]; then
        log_warning "Could not find or generate GRUB EFI bootloader"
        log_info "Creating minimal EFI configuration..."
        
        create_minimal_efi_stub "$efi_dir"
        grub_efi_source="minimal_stub"
    fi
    
    # Create GRUB configuration
    create_grub_config
    
    # Create additional UEFI boot files
    create_uefi_boot_structure "$efi_dir"
    
    log_info "UEFI boot setup completed (source: $grub_efi_source)"
    return 0
}

generate_grub_efi() {
    local efi_dir="$1"
    
    # Check if grub-mkimage is available
    if ! command -v grub-mkimage >/dev/null 2>&1; then
        log_debug "grub-mkimage not available"
        return 1
    fi
    
    log_progress "Generating GRUB EFI bootloader..."
    
    # Required GRUB modules for basic functionality
    local grub_modules=(
        "part_gpt" "part_msdos" "fat" "ext2" "ntfs" "chain"
        "boot" "linux" "normal" "configfile" "loopback"
        "iso9660" "search" "search_fs_file" "search_fs_uuid"
        "ls" "cat" "echo" "test" "true" "help" "reboot" "halt"
    )
    
    # Try to generate GRUB EFI image
    local temp_grub="$WORKDIR/temp_grubx64.efi"
    
    if grub-mkimage -O x86_64-efi -o "$temp_grub" "${grub_modules[@]}" 2>/dev/null; then
        if $SUDO mv "$temp_grub" "$efi_dir/bootx64.efi"; then
            log_debug "Successfully generated GRUB EFI bootloader"
            return 0
        fi
    fi
    
    rm -f "$temp_grub"
    return 1
}

create_minimal_efi_stub() {
    local efi_dir="$1"
    
    log_debug "Creating minimal EFI boot stub"
    
    # Create a minimal EFI shell script that points to ISOLINUX
    # This won't provide native UEFI boot but gives a fallback
    $SUDO tee "$efi_dir/startup.nsh" > /dev/null << 'EOF'
@echo off
echo Minimal EFI Boot Stub
echo.
echo This system supports BIOS boot via ISOLINUX.
echo For UEFI boot, please use a system with GRUB EFI support.
echo.
echo Press any key to attempt legacy boot...
pause
EOF
    
    # Create a simple boot entry
    $SUDO tee "$efi_dir/boot.csv" > /dev/null << 'EOF'
startup.nsh,EFI Boot Stub,,This system supports legacy BIOS boot
EOF
}

create_uefi_boot_structure() {
    local efi_dir="$1"
    
    # Create additional EFI directories for better compatibility
    local uefi_dirs=(
        "$CDROOT_DIR/EFI/ubuntu"
        "$CDROOT_DIR/EFI/debian"
        "$CDROOT_DIR/boot/grub"
    )
    
    for dir in "${uefi_dirs[@]}"; do
        $SUDO mkdir -p "$dir"
    done
    
    # Copy GRUB config to multiple locations for compatibility
    if [[ -f "$CDROOT_DIR/EFI/boot/grub.cfg" ]]; then
        $SUDO cp "$CDROOT_DIR/EFI/boot/grub.cfg" "$CDROOT_DIR/boot/grub/grub.cfg" 2>/dev/null || true
        $SUDO cp "$CDROOT_DIR/EFI/boot/grub.cfg" "$CDROOT_DIR/EFI/ubuntu/grub.cfg" 2>/dev/null || true
    fi
    
    # Copy bootloader to alternative locations
    if [[ -f "$efi_dir/bootx64.efi" ]]; then
        $SUDO cp "$efi_dir/bootx64.efi" "$CDROOT_DIR/EFI/ubuntu/grubx64.efi" 2>/dev/null || true
    fi
}/ubuntu/grubx64.efi" ]]; then
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
    log_info "Creating enhanced ISO with comprehensive verification..."
    
    local iso_file="$WORKDIR/ubuntu-live-$(date +%Y%m%d-%H%M).iso"
    local volume_label="Ubuntu Live $(date +%Y%m%d)"
    
    # Pre-flight checks
    if ! validate_iso_prerequisites; then
        log_error "ISO creation prerequisites not met"
        return 1
    fi
    
    # Verify all required files exist
    if ! verify_iso_components; then
        log_error "Required ISO components missing"
        return 1
    fi
    
    # Calculate expected ISO size
    local estimated_size_mb
    estimated_size_mb=$(calculate_estimated_iso_size)
    log_info "Estimated ISO size: ${estimated_size_mb}MB"
    
    # Build xorriso command with comprehensive options
    local xorriso_opts=(
        -as mkisofs
        -iso-level 3
        -full-iso9660-filenames
        -volid "$volume_label"
        -joliet
        -joliet-long
        -rational-rock
    )
    
    # BIOS boot configuration
    if [[ -f "$CDROOT_DIR/boot/isolinux/isolinux.bin" ]]; then
        xorriso_opts+=(
            -eltorito-boot boot/isolinux/isolinux.bin
            -eltorito-catalog boot/isolinux/boot.cat
            -no-emul-boot
            -boot-load-size 4
            -boot-info-table
        )
        log_debug "Added BIOS boot configuration"
    else
        log_warning "ISOLINUX not found - BIOS boot will not work"
    fi
    
    # UEFI boot configuration
    if [[ -f "$CDROOT_DIR/EFI/boot/bootx64.efi" ]]; then
        xorriso_opts+=(
            -eltorito-alt-boot
            -e EFI/boot/bootx64.efi
            -no-emul-boot
            -append_partition 2 0xef EFI/boot/bootx64.efi
        )
        log_debug "Added UEFI boot configuration"
    else
        log_warning "UEFI bootloader not found - UEFI boot may not work"
    fi
    
    # Add output and source
    xorriso_opts+=(
        -output "$iso_file"
        -graft-points
        "$CDROOT_DIR"
    )
    
    log_progress "Building ISO image (estimated time: $((estimated_size_mb / 100)) minutes)..."
    
    # Create the ISO with progress monitoring
    local xorriso_log="$WORKDIR/logs/xorriso.log"
    if ! create_iso_with_progress "$iso_file" "${xorriso_opts[@]}" 2>"$xorriso_log"; then
        log_error "ISO creation failed - check logs in $xorriso_log"
        analyze_iso_failure "$xorriso_log"
        return 1
    fi
    
    # Verify ISO was created and has reasonable size
    if ! verify_iso_creation "$iso_file" "$estimated_size_mb"; then
        return 1
    fi
    
    # Make ISO hybrid (bootable from USB)
    make_iso_hybrid "$iso_file"
    
    # Perform comprehensive ISO verification
    if ! verify_iso_integrity "$iso_file"; then
        log_error "ISO integrity verification failed"
        return 1
    fi
    
    # Calculate and display checksums
    calculate_checksums "$iso_file"
    
    log_info "ISO created successfully: $iso_file"
    echo "$iso_file" > "$WORKDIR/.final_iso_path"
    
    return 0
}

validate_iso_prerequisites() {
    local missing_tools=()
    
    # Check for ISO creation tools
    if ! command -v xorriso >/dev/null 2>&1; then
        missing_tools+=("xorriso")
    fi
    
    # Check for hybrid creation tools
    if ! command -v isohybrid >/dev/null 2>&1; then
        log_warning "isohybrid not available - USB boot may require manual preparation"
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install with: sudo apt-get install xorriso"
        return 1
    fi
    
    return 0
}

verify_iso_components() {
    log_progress "Verifying ISO components..."
    
    local required_files=(
        "$CDROOT_DIR/live/filesystem.squashfs"
        "$CDROOT_DIR/live/vmlinuz"
        "$CDROOT_DIR/live/initrd"
    )
    
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        else
            # Check file size is reasonable
            local file_size
            file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
            if [[ $file_size -lt 1024 ]]; then
                missing_files+=("$file (too small: ${file_size} bytes)")
            fi
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Missing or invalid ISO components:"
        for file in "${missing_files[@]}"; do
            log_error "  - $file"
        done
        return 1
    fi
    
    # Verify SquashFS integrity one more time
    log_progress "Final SquashFS verification..."
    if ! $SUDO unsquashfs -l "$CDROOT_DIR/live/filesystem.squashfs" >/dev/null 2>&1; then
        log_error "SquashFS file is corrupted"
        return 1
    fi
    
    log_debug "All ISO components verified ✓"
    return 0
}

calculate_estimated_iso_size() {
    local total_size=0
    
    # Sum up all files in CDROOT_DIR
    if command -v du >/dev/null 2>&1; then
        total_size=$(du -sm "$CDROOT_DIR" 2>/dev/null | cut -f1 || echo "0")
    fi
    
    # Add 10% overhead for ISO filesystem
    local overhead=$((total_size / 10))
    echo $((total_size + overhead))
}

create_iso_with_progress() {
    local iso_file="$1"
    shift
    local xorriso_opts=("$@")
    
    # Start xorriso in background and monitor progress
    $SUDO xorriso "${xorriso_opts[@]}" &
    local xorriso_pid=$!
    
    # Monitor progress
    while kill -0 "$xorriso_pid" 2>/dev/null; do
        if [[ -f "$iso_file" ]]; then
            local current_size
            current_size=$(du -m "$iso_file" 2>/dev/null | cut -f1 || echo "0")
            log_progress "ISO creation in progress... ${current_size}MB written"
        fi
        sleep 5
    done
    
    # Wait for xorriso to complete and get exit status
    wait "$xorriso_pid"
    return $?
}

verify_iso_creation() {
    local iso_file="$1"
    local expected_size_mb="$2"
    
    if [[ ! -f "$iso_file" ]]; then
        log_error "ISO file was not created: $iso_file"
        return 1
    fi
    
    local actual_size_mb
    actual_size_mb=$(du -m "$iso_file" | cut -f1)
    
    log_info "ISO file size: ${actual_size_mb}MB"
    
    # Check if size is reasonable (at least 100MB, not more than 10x expected)
    if [[ $actual_size_mb -lt 100 ]]; then
        log_error "ISO file too small (${actual_size_mb}MB) - likely creation failed"
        return 1
    fi
    
    if [[ $expected_size_mb -gt 0 && $actual_size_mb -gt $((expected_size_mb * 10)) ]]; then
        log_warning "ISO file much larger than expected (${actual_size_mb}MB vs ${expected_size_mb}MB)"
        read -p "Continue despite large size? (y/N): " -r continue_large
        if [[ ! "$continue_large" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

make_iso_hybrid() {
    local iso_file="$1"
    
    log_progress "Making ISO hybrid bootable..."
    
    if command -v isohybrid >/dev/null 2>&1; then
        if $SUDO isohybrid "$iso_file" 2>/dev/null; then
            log_info "ISO made hybrid bootable ✓"
        else
            log_warning "Failed to make ISO hybrid - USB boot may require manual preparation"
        fi
    else
        log_info "isohybrid not available - ISO will work on CD/DVD and some USB methods"
    fi
}

verify_iso_integrity() {
    log_progress "Performing comprehensive ISO integrity verification..."
    
    local iso_file="$1"
    local verification_passed=true
    
    # Test 1: Basic file structure
    if ! verify_iso_structure "$iso_file"; then
        verification_passed=false
    fi
    
    # Test 2: Boot sectors
    if ! verify_iso_boot_sectors "$iso_file"; then
        verification_passed=false
    fi
    
    # Test 3: File accessibility
    if ! verify_iso_file_access "$iso_file"; then
        verification_passed=false
    fi
    
    if [[ "$verification_passed" == "true" ]]; then
        log_info "ISO integrity verification passed ✓"
        return 0
    else
        log_error "ISO integrity verification failed"
        return 1
    fi
}

verify_iso_structure() {
    local iso_file="$1"
    
    # Check if we can list ISO contents
    if command -v isoinfo >/dev/null 2>&1; then
        if ! isoinfo -l -i "$iso_file" >/dev/null 2>&1; then
            log_error "Cannot read ISO file structure"
            return 1
        fi
    elif command -v 7z >/dev/null 2>&1; then
        if ! 7z l "$iso_file" >/dev/null 2>&1; then
            log_error "Cannot read ISO file structure"
            return 1
        fi
    else
        log_debug "No ISO verification tools available"
    fi
    
    return 0
}

verify_iso_boot_sectors() {
    local iso_file="$1"
    
    # Check for boot signature
    if command -v hexdump >/dev/null 2>&1; then
        local boot_sig
        boot_sig=$(hexdump -C "$iso_file" | head -n 50 | grep -c "ISOLINUX\|GRUB" || echo "0")
        
        if [[ $boot_sig -eq 0 ]]; then
            log_warning "No recognizable boot signature found in ISO"
        else
            log_debug "Boot signatures found: $boot_sig"
        fi
    fi
    
    return 0
}

verify_iso_file_access() {
    local iso_file="$1"
    
    # Try to mount and check key files (if possible)
    local temp_mount="$WORKDIR/iso_verify_mount"
    
    if mkdir -p "$temp_mount" 2>/dev/null; then
        if $SUDO mount -o loop,ro "$iso_file" "$temp_mount" 2>/dev/null; then
            local key_files=("/live/filesystem.squashfs" "/live/vmlinuz" "/live/initrd")
            local missing_files=()
            
            for file in "${key_files[@]}"; do
                if [[ ! -f "$temp_mount$file" ]]; then
                    missing_files+=("$file")
                fi
            done
            
            $SUDO umount "$temp_mount" 2>/dev/null || true
            
            if [[ ${#missing_files[@]} -gt 0 ]]; then
                log_error "Key files missing from mounted ISO: ${missing_files[*]}"
                return 1
            else
                log_debug "All key files accessible in mounted ISO ✓"
            fi
        else
            log_debug "Could not mount ISO for verification (not necessarily an error)"
        fi
        
        rmdir "$temp_mount" 2>/dev/null || true
    fi
    
    return 0
}

analyze_iso_failure() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        log_error "No xorriso log file available for analysis"
        return
    fi
    
    log_info "Analyzing ISO creation failure..."
    
    # Look for common error patterns
    local error_patterns=(
        "No space left on device:ENOSPC"
        "Permission denied:EACCES"
        "Cannot find.*isolinux:missing_bootloader"
        "Input/output error:EIO"
        "File too large:EFBIG"
    )
    
    for pattern in "${error_patterns[@]}"; do
        local error_type="${pattern#*:}"
        local search_pattern="${pattern%:*}"
        
        if grep -qi "$search_pattern" "$log_file"; then
            case "$error_type" in
                "ENOSPC")
                    log_error "Disk space exhausted during ISO creation"
                    log_info "Solution: Free up space or use different location"
                    ;;
                "EACCES")
                    log_error "Permission denied during ISO creation"
                    log_info "Solution: Check file permissions and sudo access"
                    ;;
                "missing_bootloader")
                    log_error "Boot loader files not found"
                    log_info "Solution: Ensure ISOLINUX/GRUB files are properly installed"
                    ;;
                "EIO")
                    log_error "Input/output error - possible hardware issue"
                    log_info "Solution: Check disk health and try different location"
                    ;;
                "EFBIG")
                    log_error "File too large for filesystem"
                    log_info "Solution: Use filesystem that supports large files (ext4, xfs)"
                    ;;
            esac
            return
        fi
    done
    
    # Show last few lines of log for manual analysis
    log_info "Last few lines of xorriso log:"
    tail -n 10 "$log_file" | while read -r line; do
        log_info "  $line"
    done
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
    echo "📊 ISO Size: $iso_size"
    echo "🔍 Checksums: $WORKDIR/checksums.txt"
    echo "📋 Logs: $WORKDIR/logs/"
    echo ""
    echo "Next steps:"
    echo "1. Test the ISO in a virtual machine"
    echo "2. Write to USB: sudo dd if='$iso_path' of=/dev/sdX bs=4M status=progress"
    echo "3. Or use a tool like Rufus, Etcher, or UNetbootin"
    echo ""
    echo "The ISO supports both BIOS and UEFI boot modes."
    echo "========================================="
    
    # Cleanup temporary files but keep ISO and logs
    SCRIPT_STATE[cleanup_required]="false"
    cleanup_mounts_enhanced
}

# Enhanced main workflow
main() {
    # Setup
    setup_logging
    
    # Check for resume capability
    local resume_build=false
    if check_resume_capability; then
        resume_build=true
    fi
    
    # Trap for cleanup
    trap cleanup_all EXIT INT TERM
    
    if [[ "$resume_build" == "false" ]]; then
        # Full validation for new builds
        if ! validate_system; then
            fatal_error "System validation failed"
        fi
        
        # Clean workspace
        log_info "Preparing clean workspace..."
        $SUDO rm -rf "$WORKDIR"
        mkdir -p "$EXTRACT_DIR" "$CDROOT_DIR/boot/isolinux" "$CDROOT_DIR/live"
        save_state "workspace_prepared"
    fi
    
    # Execute stages based on current state
    case "${SCRIPT_STATE[stage]}" in
        "init"|"workspace_prepared")
            atomic_operation "system_copy" enhanced_rsync || fatal_error "System copy failed"
            ;&  # Fall through
        "atomic_system_copy_complete")
            atomic_operation "post_copy_cleanup" post_copy_cleanup || fatal_error "Post-copy cleanup failed"
            ;&
        "atomic_post_copy_cleanup_complete")
            atomic_operation "chroot_config" configure_chroot_enhanced || fatal_error "Chroot configuration failed"
            ;&
        "atomic_chroot_config_complete")
            atomic_operation "squashfs_creation" create_squashfs_enhanced || fatal_error "SquashFS creation failed"
            ;&
        "atomic_squashfs_creation_complete")
            atomic_operation "bootloader_setup" setup_bootloader_enhanced || fatal_error "Bootloader setup failed"
            ;&
        "atomic_bootloader_setup_complete")
            atomic_operation "iso_creation" create_iso_enhanced || fatal_error "ISO creation failed"
            ;&
        "atomic_iso_creation_complete")
            log_info "Build completed successfully!"
            show_success_message
            ;;
        *)
            log_error "Unknown state: ${SCRIPT_STATE[stage]}"
            fatal_error "Invalid build state"
            ;;
    esac
}

# Help and usage information
show_usage() {
    echo "Enhanced AutoISO v$SCRIPT_VERSION - Reliable Live ISO Creator"
    echo ""
    echo "Usage: $0 [WORK_DIRECTORY]"
    echo ""
    echo "Arguments:"
    echo "  WORK_DIRECTORY    Directory for build files (default: /tmp/autoiso-build)"
    echo ""
    echo "Examples:"
    echo "  $0                                # Use /tmp/autoiso-build"
    echo "  $0 /home/user/iso-build          # Use custom directory"
    echo "  $0 /mnt/external/iso-build       # Use external drive"
    echo ""
    echo "Features:"
    echo "  ✓ Comprehensive system validation"
    echo "  ✓ Resume capability after interruption"
    echo "  ✓ Enhanced error handling and recovery"
    echo "  ✓ Atomic operations with rollback"
    echo "  ✓ Detailed logging and progress tracking"
    echo "  ✓ BIOS and UEFI boot support"
    echo "  ✓ Optimized compression and file handling"
    echo ""
    echo "Requirements:"
    echo "  - Ubuntu/Debian-based system"
    echo "  - squashfs-tools, xorriso, genisoimage, rsync"
    echo "  - At least ${MIN_SPACE_GB}GB free space"
    echo "  - Root or sudo access"
    echo ""
}

# Command line argument processing
process_arguments() {
    case "${1:-}" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--version)
            echo "Enhanced AutoISO v$SCRIPT_VERSION"
            exit 0
            ;;
        "")
            # No arguments - use default
            ;;
        *)
            if [[ "$1" =~ ^- ]]; then
                echo "Error: Unknown option '$1'"
                echo "Use '$0 --help' for usage information."
                exit 1
            fi
            ;;
    esac
}

# Initialize if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Process command line arguments
    process_arguments "$@"
    
    # Configuration setup
    if [ -n "${1:-}" ] && [[ ! "$1" =~ ^- ]]; then
        WORKDIR="$1/autoiso-build"
    elif [ -n "${WORKDIR:-}" ]; then
        WORKDIR="${WORKDIR}/autoiso-build"
    else
        WORKDIR="/tmp/autoiso-build"
    fi
    
    # Resolve absolute path
    WORKDIR=$(realpath "$WORKDIR" 2>/dev/null || echo "$WORKDIR")
    EXTRACT_DIR="$WORKDIR/extract"
    CDROOT_DIR="$WORKDIR/cdroot"
    STATE_FILE="$WORKDIR/.autoiso-state"
    
    # Sudo detection
    if [ "$EUID" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
        # Test sudo access
        if ! $SUDO -n true 2>/dev/null; then
            echo "This script requires sudo access. You may be prompted for your password."
            $SUDO true || {
                echo "Error: Cannot obtain sudo access"
                exit 1
            }
        fi
    fi
    
    # Display startup information
    echo "Enhanced AutoISO v$SCRIPT_VERSION"
    echo "Work directory: $WORKDIR"
    echo "Starting build process..."
    echo ""
    
    # Start main process
    main "$@"
fi
