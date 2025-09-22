#!/bin/bash

# Port Management System for Raspberry Pi QEMU Emulator - FIXED VERSION
# Questa versione risolve i problemi di cleanup multipli e concorrenza

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function for colored logs
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Port configuration
DEFAULT_SSH_BASE=2222
DEFAULT_VNC_BASE=5900
DEFAULT_RDP_BASE=3389
DEFAULT_WAYVNC_BASE=5901

# Port range configuration
MAX_INSTANCES=50
PORT_LOCK_DIR="/tmp/rpi-qemu-ports"
INSTANCE_STATE_DIR="/tmp/rpi-qemu-instances"

# Create directories for port management
mkdir -p "$PORT_LOCK_DIR"
mkdir -p "$INSTANCE_STATE_DIR"

# FIXED: Function to check if a port is in use with better detection
is_port_in_use() {
    local port=$1
    
    # Method 1: Check with ss (most reliable)
    if command -v ss &>/dev/null; then
        if ss -tuln | grep -q ":$port "; then
            return 0
        fi
    fi
    
    # Method 2: Check with netstat
    if command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            return 0
        fi
    fi
    
    # Method 3: Try to bind to the port
    if timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        return 0
    fi
    
    # Method 4: Check if QEMU is using the port
    if pgrep -f "hostfwd=tcp::$port" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# FIXED: Better lock file management with PID checking
acquire_port_lock() {
    local port=$1
    local instance_id=$2
    local lock_file="$PORT_LOCK_DIR/port_${port}.lock"
    
    # Check if lock exists and if the process is still running
    if [ -f "$lock_file" ]; then
        local lock_content=$(cat "$lock_file")
        local lock_pid=$(echo "$lock_content" | cut -d':' -f3)
        
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            # Process still running, cannot acquire lock
            return 1
        else
            # Process dead, remove stale lock
            rm -f "$lock_file"
        fi
    fi
    
    # Use flock for atomic port locking
    (
        flock -n 200 || return 1
        echo "$instance_id:$(date +%s):$$" > "$lock_file"
        return 0
    ) 200>"$lock_file"
}

# Function to release a port lock
release_port_lock() {
    local port=$1
    local lock_file="$PORT_LOCK_DIR/port_${port}.lock"
    
    # Only remove lock if it belongs to current process/instance
    if [ -f "$lock_file" ]; then
        local lock_content=$(cat "$lock_file")
        local lock_pid=$(echo "$lock_content" | cut -d':' -f3)
        local lock_instance=$(echo "$lock_content" | cut -d':' -f1)
        
        # Remove lock only if it's ours or the process is dead
        if [ "$lock_pid" = "$$" ] || [ "$lock_instance" = "$INSTANCE_ID" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$lock_file"
        fi
    fi
}

# FIXED: Find available port with better checking
find_available_port() {
    local base_port=$1
    local instance_id=$2
    local service_type=$3
    
    for ((offset=0; offset<MAX_INSTANCES; offset++)); do
        local test_port=$((base_port + offset))
        
        # Check if port is in use by system or QEMU
        if is_port_in_use $test_port; then
            continue
        fi
        
        # Try to acquire lock
        if acquire_port_lock $test_port $instance_id; then
            echo $test_port
            return 0
        fi
    done
    
    return 1
}

# Function to generate unique instance ID
generate_instance_id() {
    local distro=$1
    local timestamp=$(date +%s%N)  # Nanoseconds for better uniqueness
    local random=$(shuf -i 1000-9999 -n 1)
    echo "${distro}_${timestamp}_${random}"
}

# FIXED: Allocate ports only if not already allocated
allocate_ports() {
    local instance_id=$1
    local enable_vnc=$2
    local enable_rdp=$3
    local enable_wayvnc=$4
    local requested_ssh_port=$5
    local requested_vnc_port=$6
    local requested_rdp_port=$7
    local requested_wayvnc_port=$8
    
    # Check if ports are already allocated for this instance
    local state_file="$INSTANCE_STATE_DIR/$instance_id.state"
    if [ -f "$state_file" ]; then
        log "Ports already allocated for instance $instance_id, using existing allocation"
        source "$state_file"
        export ALLOCATED_SSH_PORT=$SSH_PORT
        export ALLOCATED_VNC_PORT=$VNC_PORT
        export ALLOCATED_RDP_PORT=$RDP_PORT
        export ALLOCATED_WAYVNC_PORT=$WAYVNC_PORT
        return 0
    fi
    
    local allocated_ports=()
    local ssh_port vnc_port rdp_port wayvnc_port
    
    # Allocate SSH port
    if [ -n "$requested_ssh_port" ] && [ "$requested_ssh_port" != "auto" ]; then
        if ! is_port_in_use $requested_ssh_port && acquire_port_lock $requested_ssh_port $instance_id; then
            ssh_port=$requested_ssh_port
        else
            echo "Requested SSH port $requested_ssh_port is already in use" >&2
            cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
            return 1
        fi
    else
        ssh_port=$(find_available_port $DEFAULT_SSH_BASE $instance_id "ssh")
        if [ $? -ne 0 ]; then
            echo "Could not find available SSH port" >&2
            return 1
        fi
    fi
    allocated_ports+=($ssh_port)
    
    # Allocate VNC port if enabled
    if [ "$enable_vnc" = true ]; then
        if [ -n "$requested_vnc_port" ] && [ "$requested_vnc_port" != "auto" ]; then
            if ! is_port_in_use $requested_vnc_port && acquire_port_lock $requested_vnc_port $instance_id; then
                vnc_port=$requested_vnc_port
            else
                echo "Requested VNC port $requested_vnc_port is already in use" >&2
                cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
                return 1
            fi
        else
            vnc_port=$(find_available_port $DEFAULT_VNC_BASE $instance_id "vnc")
            if [ $? -ne 0 ]; then
                echo "Could not find available VNC port" >&2
                cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
                return 1
            fi
        fi
        allocated_ports+=($vnc_port)
    fi
    
    # Allocate RDP port if enabled
    if [ "$enable_rdp" = true ]; then
        if [ -n "$requested_rdp_port" ] && [ "$requested_rdp_port" != "auto" ]; then
            if ! is_port_in_use $requested_rdp_port && acquire_port_lock $requested_rdp_port $instance_id; then
                rdp_port=$requested_rdp_port
            else
                echo "Requested RDP port $requested_rdp_port is already in use" >&2
                cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
                return 1
            fi
        else
            rdp_port=$(find_available_port $DEFAULT_RDP_BASE $instance_id "rdp")
            if [ $? -ne 0 ]; then
                echo "Could not find available RDP port" >&2
                cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
                return 1
            fi
        fi
        allocated_ports+=($rdp_port)
    fi
    
    # Allocate WayVNC port if enabled
    if [ "$enable_wayvnc" = true ]; then
        if [ -n "$requested_wayvnc_port" ] && [ "$requested_wayvnc_port" != "auto" ]; then
            if ! is_port_in_use $requested_wayvnc_port && acquire_port_lock $requested_wayvnc_port $instance_id; then
                wayvnc_port=$requested_wayvnc_port
            else
                echo "Requested WayVNC port $requested_wayvnc_port is already in use" >&2
                cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
                return 1
            fi
        else
            wayvnc_port=$(find_available_port $DEFAULT_WAYVNC_BASE $instance_id "wayvnc")
            if [ $? -ne 0 ]; then
                echo "Could not find available WayVNC port" >&2
                cleanup_allocated_ports "$instance_id" "${allocated_ports[@]}"
                return 1
            fi
        fi
        allocated_ports+=($wayvnc_port)
    fi
    
    # Save instance state - will be updated with actual PID later
    cat > "$state_file" << EOF
INSTANCE_ID=$instance_id
SSH_PORT=$ssh_port
VNC_PORT=${vnc_port:-""}
RDP_PORT=${rdp_port:-""}
WAYVNC_PORT=${wayvnc_port:-""}
ALLOCATED_PORTS=(${allocated_ports[@]})
CREATED=$(date +%s)
PID=PENDING
OWNER_PID=$$
EOF
    
    # Export ports for use in the script
    export ALLOCATED_SSH_PORT=$ssh_port
    export ALLOCATED_VNC_PORT=$vnc_port
    export ALLOCATED_RDP_PORT=$rdp_port
    export ALLOCATED_WAYVNC_PORT=$wayvnc_port
    export INSTANCE_ID=$instance_id
    
    log "Port allocation successful for instance $instance_id:"
    log "  SSH: $ssh_port"
    [ -n "$vnc_port" ] && log "  VNC: $vnc_port"
    [ -n "$rdp_port" ] && log "  RDP: $rdp_port" 
    [ -n "$wayvnc_port" ] && log "  WayVNC: $wayvnc_port"
    
    return 0
}

# Function to cleanup allocated ports
cleanup_allocated_ports() {
    local instance_id=$1
    shift
    local ports=("$@")
    
    log "Cleaning up ports for instance $instance_id..."
    
    for port in "${ports[@]}"; do
        if [ -n "$port" ]; then
            release_port_lock $port
            log "Released port $port"
        fi
    done
    
    # Remove instance state file
    rm -f "$INSTANCE_STATE_DIR/$instance_id.state"
}

# FIXED: Only cleanup ports if we own the instance
cleanup_instance_ports() {
    local instance_id=$1
    local state_file="$INSTANCE_STATE_DIR/$instance_id.state"
    
    if [ -f "$state_file" ]; then
        source "$state_file"
        
        # Only cleanup if we're the owner or the owner process is dead
        if [ "$OWNER_PID" = "$$" ] || ! kill -0 "$OWNER_PID" 2>/dev/null; then
            log "Cleaning up ports for instance $instance_id..."
            
            # Release all port locks
            [ -n "$SSH_PORT" ] && release_port_lock "$SSH_PORT"
            [ -n "$VNC_PORT" ] && release_port_lock "$VNC_PORT"
            [ -n "$RDP_PORT" ] && release_port_lock "$RDP_PORT"
            [ -n "$WAYVNC_PORT" ] && release_port_lock "$WAYVNC_PORT"
            
            # Remove instance state file
            rm -f "$state_file"
            
            log "Cleaned up instance $instance_id"
        else
            log "Instance $instance_id owned by process $OWNER_PID, not cleaning up"
        fi
    fi
}

# Function to list active instances
list_active_instances() {
    echo "Active QEMU instances:"
    echo "======================"
    
    local found_any=false
    
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            found_any=true
            source "$state_file"
            
            # Check if process is still running
            local status="UNKNOWN"
            if [ "$PID" = "PENDING" ]; then
                status="STARTING"
            elif kill -0 "$PID" 2>/dev/null; then
                status="RUNNING"
            else
                status="STOPPED"
            fi
            
            local created_date=$(date -d "@$CREATED" 2>/dev/null || echo "Unknown")
            
            echo "Instance: $INSTANCE_ID"
            echo "  Status: $status (PID: $PID)"
            echo "  Owner: $OWNER_PID"
            echo "  Created: $created_date"
            echo "  SSH: localhost:$SSH_PORT"
            [ -n "$VNC_PORT" ] && echo "  VNC: localhost:$VNC_PORT"
            [ -n "$RDP_PORT" ] && echo "  RDP: localhost:$RDP_PORT"
            [ -n "$WAYVNC_PORT" ] && echo "  WayVNC: localhost:$WAYVNC_PORT"
            echo ""
        fi
    done
    
    if [ "$found_any" = false ]; then
        echo "No active instances found."
    fi
}

# Function to cleanup stale locks and instances
cleanup_stale_instances() {
    log "Cleaning up stale instances and port locks..."
    
    local cleaned=0
    
    # Check state files for dead processes
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            source "$state_file"
            
            # Check if both owner and QEMU processes are dead
            local owner_dead=false
            local qemu_dead=false
            
            if [ -n "$OWNER_PID" ] && ! kill -0 "$OWNER_PID" 2>/dev/null; then
                owner_dead=true
            fi
            
            if [ "$PID" != "PENDING" ] && [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
                qemu_dead=true
            fi
            
            # Clean up if both processes are dead or if it's been more than 1 hour
            local age=$(($(date +%s) - $CREATED))
            if ([ "$owner_dead" = true ] && [ "$qemu_dead" = true ]) || [ $age -gt 3600 ]; then
                log "Found stale instance $INSTANCE_ID (owner: $OWNER_PID, qemu: $PID)"
                cleanup_allocated_ports "$INSTANCE_ID" "${ALLOCATED_PORTS[@]}"
                ((cleaned++))
            fi
        fi
    done
    
    # Check for orphaned lock files (older than 1 hour)
    find "$PORT_LOCK_DIR" -name "*.lock" -type f -mmin +60 2>/dev/null | while read lock_file; do
        log "Removing stale lock file: $lock_file"
        rm -f "$lock_file"
        ((cleaned++))
    done
    
    if [ $cleaned -gt 0 ]; then
        log "Cleaned up $cleaned stale instances/locks"
    else
        log "No stale instances found"
    fi
}

# Function to show port usage statistics
show_port_usage() {
    echo "Port Usage Statistics:"
    echo "====================="
    
    local ssh_count=0
    local vnc_count=0
    local rdp_count=0
    local wayvnc_count=0
    
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            source "$state_file"
            
            # Count active instances by service type
            local is_active=false
            if [ "$PID" = "PENDING" ] || ([ -n "$PID" ] && kill -0 "$PID" 2>/dev/null); then
                is_active=true
            fi
            
            if [ "$is_active" = true ]; then
                ((ssh_count++))
                [ -n "$VNC_PORT" ] && ((vnc_count++))
                [ -n "$RDP_PORT" ] && ((rdp_count++))
                [ -n "$WAYVNC_PORT" ] && ((wayvnc_count++))
            fi
        fi
    done
    
    echo "Active instances: $ssh_count"
    echo "SSH ports in use: $ssh_count"
    echo "VNC ports in use: $vnc_count"
    echo "RDP ports in use: $rdp_count"
    echo "WayVNC ports in use: $wayvnc_count"
    echo ""
    echo "Available port ranges:"
    echo "  SSH: $DEFAULT_SSH_BASE-$((DEFAULT_SSH_BASE + MAX_INSTANCES - 1))"
    echo "  VNC: $DEFAULT_VNC_BASE-$((DEFAULT_VNC_BASE + MAX_INSTANCES - 1))"
    echo "  RDP: $DEFAULT_RDP_BASE-$((DEFAULT_RDP_BASE + MAX_INSTANCES - 1))"
    echo "  WayVNC: $DEFAULT_WAYVNC_BASE-$((DEFAULT_WAYVNC_BASE + MAX_INSTANCES - 1))"
}

# FIXED: More selective cleanup function that doesn't interfere with other instances
cleanup_on_exit() {
    # Only cleanup if we have an instance ID and we're the owner
    if [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            source "$state_file"
            # Only cleanup if we're the owner process
            if [ "$OWNER_PID" = "$$" ]; then
                log "Cleaning up instance $INSTANCE_ID on exit (owner process $$)..."
                cleanup_instance_ports "$INSTANCE_ID"
            fi
        fi
    fi
}

# FIXED: Only set trap if we're not being sourced by another script that manages instances
if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ -z "$LAUNCHING_EMULATOR" ]; then
    trap cleanup_on_exit EXIT INT TERM
fi

# Export functions for use in other scripts
export -f is_port_in_use
export -f acquire_port_lock
export -f release_port_lock
export -f find_available_port
export -f generate_instance_id
export -f allocate_ports
export -f cleanup_allocated_ports
export -f cleanup_instance_ports
export -f list_active_instances
export -f cleanup_stale_instances
export -f show_port_usage
export -f cleanup_on_exit

# Command line interface
case "${1:-}" in
    "list")
        list_active_instances
        ;;
    "cleanup")
        cleanup_stale_instances
        ;;
    "usage")
        show_port_usage
        ;;
    "help")
        echo "Port Management System for Raspberry Pi QEMU Emulator"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  list     - List all active instances"
        echo "  cleanup  - Clean up stale instances and port locks"
        echo "  usage    - Show port usage statistics"
        echo "  help     - Show this help message"
        echo ""
        echo "This script is meant to be sourced by emulator scripts:"
        echo "  source port_management.sh"
        echo ""
        ;;
    *)
        if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
            # Script is being sourced
            log "Port management system loaded"
        else
            # Script is being executed directly
            echo "Use '$0 help' for usage information"
        fi
        ;;
esac

true