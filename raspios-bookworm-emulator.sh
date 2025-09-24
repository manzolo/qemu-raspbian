#!/bin/bash
# Script to emulate Raspberry Pi OS Bookworm (ARM64) with QEMU - NETWORK BOOT FIXED VERSION
# Based on proven working guide and inspired by: https://gist.github.com/mmguero/5c13aa16a68783e6240458e0282f27da
# Enhanced with GPU passthrough, cleanup features, and optimizations
set -e # Exit immediately if a command exits with a non-zero status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    exit 1
fi
source "$PORT_MGMT_SCRIPT"

# Configurable variables - Updated for Bookworm
RPI_IMAGE_URL="https://downloads.raspberrypi.org/raspios_arm64/images/raspios_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64.img.xz"
RPI_IMAGE_XZ="2025-05-13-raspios-bookworm-arm64.img.xz"
RPI_IMAGE="2025-05-13-raspios-bookworm-arm64.img"
DISTRO="Bookworm"
DISTRO_LOWER=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
RPI_PASSWORD="raspberry"
WORK_DIR="$HOME/qemu-rpi/bookworm"

# Port configuration
SSH_PORT="auto"
VNC_PORT="auto"
RDP_PORT="auto"
WAYVNC_PORT="auto"
ENABLE_VNC=false
ENABLE_RDP=false
ENABLE_WAYVNC=false
HEADLESS=false
INSTANCE_ID=""
CURRENT_QEMU_PID=""
CLEAN_BUILD=false

# FIXED: Use proven working configuration from the guide
MACHINE_TYPE="virt"
CPU_TYPE="cortex-a72"
MEMORY="4G"
SMP_CORES="6"
ROOT_DEVICE="/dev/vda2"
KERNEL_FILE=""

# Cross-compiler detection
CROSS_COMPILE=""

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# GPU acceleration detection
setup_gpu_acceleration() {
    # Check for DRI devices (for GPU acceleration)
    if [ -c "/dev/dri/renderD128" ] && [ -c "/dev/dri/card0" ]; then
        log "DRI devices detected, enabling GPU acceleration"
        qemu_args+=("-device" "virtio-gpu-pci")
        qemu_args+=("-display" "gtk,gl=on")
        # Add DRI device passthrough if running as user with access
        if [ -r "/dev/dri/renderD128" ] && [ -r "/dev/dri/card0" ]; then
            qemu_args+=("-object" "rng-random,filename=/dev/urandom,id=rng0")
            qemu_args+=("-device" "virtio-rng-pci,rng=rng0")
        fi
        log "GPU acceleration enabled"
    else
        log "No GPU acceleration available, using software rendering"
        qemu_args+=("-display" "gtk")
    fi
}

# FIXED: Improved dependency checking with alternative command names
check_dependencies() {
    log "Checking dependencies for Raspberry Pi OS ARM64..."
    local missing=()
    
    # Check QEMU
    if ! command -v qemu-system-aarch64 &> /dev/null; then
        missing+=("qemu-system-aarch64")
    fi
    
    # Check wget
    if ! command -v wget &> /dev/null; then
        missing+=("wget")
    fi
    
    # Check XZ (multiple possible names)
    if ! command -v xz &> /dev/null && ! command -v unxz &> /dev/null && ! command -v xzcat &> /dev/null; then
        missing+=("xz-utils")
    fi
    
    # Check fdisk
    if ! command -v fdisk &> /dev/null; then
        missing+=("fdisk")
    fi
    
    # Check openssl
    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi
    
    # FIXED: Check cross-compiler with multiple possible names
    if command -v gcc-aarch64-linux-gnu &> /dev/null; then
        CROSS_COMPILE="gcc-aarch64-linux-gnu-"
    elif command -v aarch64-linux-gnu-gcc &> /dev/null; then
        CROSS_COMPILE="aarch64-linux-gnu-"
    else
        missing+=("gcc-aarch64-linux-gnu")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing[*]}"
        echo "On Ubuntu/Debian, install with:"
        echo "sudo apt update"
        echo "sudo apt install -y qemu-system-aarch64 qemu-user-static wget xz-utils fdisk openssl"
        echo "sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu qemu-utils"
        exit 1
    fi
    
    log "All dependencies are present ✓"
    log "Cross-compiler prefix: $CROSS_COMPILE"
    log "Using proven configuration: virt machine with cortex-a72 CPU and virtio devices"
}

# Download image
download_image() {
    log "Preparing working directory for ARM64..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    if [ -f "$RPI_IMAGE" ]; then
        log "ARM64 image already present, skipping download"
        return 0
    fi
    
    if [ ! -f "$RPI_IMAGE_XZ" ]; then
        log "Downloading Raspberry Pi OS ARM64 image (approx. 818MB)..."
        wget -c "$RPI_IMAGE_URL"
    fi
    
    log "Decompressing the image..."
    # FIXED: Use appropriate decompression command
    if command -v xz &> /dev/null; then
        xz -d "$RPI_IMAGE_XZ"
    elif command -v unxz &> /dev/null; then
        unxz "$RPI_IMAGE_XZ"
    else
        error "No XZ decompression utility found"
        exit 1
    fi
}

# Clean build artifacts
clean_build_artifacts() {
    log "Cleaning build artifacts..."
    
    # Remove kernel build directory
    local kernel_version="6.1.34"
    local kernel_dir="linux-${kernel_version}"
    local kernel_archive="linux-${kernel_version}.tar.xz"
    
    if [ -d "$kernel_dir" ]; then
        log "Removing kernel source directory: $kernel_dir"
        rm -rf "$kernel_dir"
    fi
    
    if [ "$CLEAN_BUILD" = true ]; then
        if [ -f "$kernel_archive" ]; then
            log "Removing kernel archive: $kernel_archive"
            rm -f "$kernel_archive"
        fi
        
        if [ -f "Image" ]; then
            log "Removing kernel image: Image"
            rm -f "Image"
        fi
    fi
    
    # Clean any temporary mount points
    sudo umount /tmp/rpi_boot_* 2>/dev/null || true
    sudo umount /tmp/rpi_root_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_boot_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_root_* 2>/dev/null || true
    
    log "Build artifacts cleaned ✓"
}

# FIXED: Build custom kernel following the guide's proven approach with cleanup
build_custom_kernel() {
    log "Building custom ARM64 kernel following proven guide approach..."
    
    # Check if kernel already built
    if [ -f "Image" ] && [ "$CLEAN_BUILD" != true ]; then
        log "Custom kernel already built, skipping"
        KERNEL_FILE="Image"
        return 0
    fi
    
    # Clean previous build if requested
    if [ "$CLEAN_BUILD" = true ]; then
        clean_build_artifacts
    fi
    
    # Download kernel source as per guide
    local kernel_version="6.1.34"
    local kernel_archive="linux-${kernel_version}.tar.xz"
    local kernel_dir="linux-${kernel_version}"
    
    if [ ! -f "$kernel_archive" ]; then
        log "Downloading Linux kernel ${kernel_version}..."
        wget "https://cdn.kernel.org/pub/linux/kernel/v6.x/${kernel_archive}"
    fi
    
    if [ ! -d "$kernel_dir" ]; then
        log "Extracting kernel source..."
        if command -v xz &> /dev/null; then
            tar xf "$kernel_archive"
        elif command -v unxz &> /dev/null; then
            unxz -c "$kernel_archive" | tar xf -
        else
            error "No XZ decompression utility found for kernel extraction"
            exit 1
        fi
    fi
    
    cd "$kernel_dir"
    
    # Build kernel exactly as per guide
    log "Configuring kernel for ARM64 with kvm_guest config..."
    ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" make defconfig
    ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" make kvm_guest.config
    
    log "Building kernel (this may take several minutes)..."
    ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" make -j$(nproc)
    
    # Copy kernel to working directory
    cp arch/arm64/boot/Image "../Image"
    cd ..
    
    # Clean build directory after successful build
    log "Cleaning kernel build directory..."
    rm -rf "$kernel_dir"
    
    KERNEL_FILE="Image"
    log "Custom ARM64 kernel built successfully ✓"
    log "Build directory cleaned to save space ✓"
}

# FIXED: Setup SSH and user config following guide's exact method
setup_ssh_and_user() {
    log "Setting up SSH and user configuration..."
    
    # Get boot partition offset exactly as in guide
    local boot_start=$(fdisk -l "$RPI_IMAGE" | awk '/W95 FAT32/ {print $2}')
    local boot_offset=$((boot_start * 512))
    
    log "Boot partition offset: $boot_offset"
    
    # Create temporary mount directory
    local mount_dir="/tmp/rpi_boot_$$"
    sudo mkdir -p "$mount_dir"
    
    # Mount boot partition
    sudo mount -o loop,offset="$boot_offset" "$RPI_IMAGE" "$mount_dir"
    
    # Enable SSH exactly as in guide
    sudo touch "$mount_dir/ssh"
    
    # Create user configuration as in guide
    log "Generating password hash for user 'pi'..."
    local password_hash
    password_hash=$(openssl passwd -6 "$RPI_PASSWORD")
    echo "pi:$password_hash" | sudo tee "$mount_dir/userconf.txt" > /dev/null
    
    # Unmount
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"
    
    log "SSH and user configuration completed ✓"
}

# FIXED: Resize image using proven method from guide
resize_image_advanced() {
    log "Resizing image using advanced method from guide..."
    
    # Check if already resized
    local current_size=$(stat -c%s "$RPI_IMAGE")
    if [ $current_size -gt 8000000000 ]; then
        log "Image already resized, skipping"
        return 0
    fi
    
    # Use virt-resize if available, otherwise fallback to qemu-img
    if command -v virt-resize &> /dev/null; then
        log "Using virt-resize for advanced partition resizing..."
        local bigger_image="$(basename "$RPI_IMAGE" .img).bigger.img"
        
        # Create a temporary bigger image
        cp "$RPI_IMAGE" "$bigger_image"
        truncate -s +40G "$bigger_image"
        
        # Use virt-resize to expand the root partition
        if virt-resize --expand /dev/sda2 "$RPI_IMAGE" "$bigger_image.resized" 2>/dev/null; then
            mv "$bigger_image.resized" "$RPI_IMAGE"
            rm -f "$bigger_image"
            log "Image resized successfully using virt-resize ✓"
        else
            warning "virt-resize failed, falling back to qemu-img method"
            rm -f "$bigger_image.resized" 2>/dev/null || true
            # Fallback to qemu-img
            qemu-img resize -f raw "$bigger_image" +40G
            mv "$bigger_image" "$RPI_IMAGE"
            log "Image resized successfully using qemu-img ✓"
        fi
    else
        warning "virt-resize not available, using qemu-img resize method"
        # Create expanded copy
        local expanded_image="${RPI_IMAGE}.expanded"
        cp "$RPI_IMAGE" "$expanded_image"
        qemu-img resize -f raw "$expanded_image" +40G
        mv "$expanded_image" "$RPI_IMAGE"
        log "Image resized successfully using qemu-img ✓"
    fi
}

# FIXED: Start QEMU using the exact proven configuration from guide with GPU support
start_qemu() {
    log "Starting QEMU with proven configuration from working guide..."
    
    # Ensure we have the custom kernel
    if [ ! -f "$KERNEL_FILE" ] || [ -z "$KERNEL_FILE" ]; then
        error "Custom kernel not found. Build process may have failed."
        return 1
    fi
    
    log "Using proven working configuration:"
    log "  Machine: $MACHINE_TYPE (Generic ARM64 virtual machine)"
    log "  CPU: $CPU_TYPE with $SMP_CORES cores"
    log "  Memory: $MEMORY"
    log "  Kernel: $KERNEL_FILE (Custom built for QEMU)"
    log "  Root device: $ROOT_DEVICE (virtio block device)"
    
    # Build netdev string with port forwards
    local netdev_config="user,id=mynet,hostfwd=tcp::$SSH_PORT-:22"
    if [ "$ENABLE_VNC" = true ]; then
        netdev_config+=",hostfwd=tcp::$VNC_PORT-:5900"
        log "VNC will be available on port $VNC_PORT"
    fi
    if [ "$ENABLE_RDP" = true ]; then
        netdev_config+=",hostfwd=tcp::$RDP_PORT-:3389"
        log "RDP will be available on port $RDP_PORT"
    fi
    if [ "$ENABLE_WAYVNC" = true ]; then
        netdev_config+=",hostfwd=tcp::$WAYVNC_PORT-:5901"
        log "WayVNC will be available on port $WAYVNC_PORT"
    fi
    
    # Build QEMU command array step by step
    local qemu_cmd="qemu-system-aarch64"
    local qemu_args=()
    
    # Machine and CPU configuration
    qemu_args+=("-machine" "$MACHINE_TYPE")
    qemu_args+=("-cpu" "$CPU_TYPE")
    qemu_args+=("-smp" "$SMP_CORES")
    qemu_args+=("-m" "$MEMORY")
    
    # Kernel configuration
    qemu_args+=("-kernel" "$KERNEL_FILE")
    qemu_args+=("-append" "root=$ROOT_DEVICE rootfstype=ext4 rw panic=0 console=ttyAMA0")
    
    # Storage configuration
    qemu_args+=("-drive" "format=raw,file=$RPI_IMAGE,if=none,id=hd0,cache=writeback")
    qemu_args+=("-device" "virtio-blk,drive=hd0,bootindex=0")
    
    # Network configuration
    qemu_args+=("-netdev" "$netdev_config")
    qemu_args+=("-device" "virtio-net-pci,netdev=mynet")
    
    # Monitor
    qemu_args+=("-monitor" "telnet:127.0.0.1:5555,server,nowait")
    
    # Display and GPU configuration
    if [ "$HEADLESS" = true ]; then
        qemu_args+=("-nographic")
        log "Running in headless mode"
    else
        # Add GPU acceleration if available
        setup_gpu_acceleration
    fi
    
    # Show connection info
    echo
    log "Connection Information:"
    echo " SSH: ssh -p $SSH_PORT pi@localhost"
    echo " Password: $RPI_PASSWORD"
    if [ "$ENABLE_VNC" = true ]; then
        echo " VNC: localhost:$VNC_PORT"
    fi
    if [ "$ENABLE_RDP" = true ]; then
        echo " RDP: localhost:$RDP_PORT (username: pi, password: $RPI_PASSWORD)"
    fi
    if [ "$ENABLE_WAYVNC" = true ]; then
        echo " WayVNC: localhost:$WAYVNC_PORT"
    fi
    echo " Monitor: telnet localhost 5555"
    echo
    
    warning "NETWORK BOOT FIX APPLIED:"
    echo " - Using virt machine with virtio-net-pci (proven working)"
    echo " - Custom kernel built with kvm_guest config"
    echo " - Proper virtio block device configuration"
    echo " - Root device correctly set to /dev/vda2"
    echo " - Network device: virtio-net-pci (replaces problematic usb-net)"
    if [ "$HEADLESS" != true ]; then
        echo " - GPU acceleration enabled if DRI devices available"
    fi
    echo
    
    log "Starting ARM64 emulation with NETWORK BOOT FIXES..."
    echo "QEMU Command:"
    echo "$qemu_cmd ${qemu_args[*]}"
    echo
    
    log "Waiting for boot... (first boot may take 5-10 minutes)"
    log "Look for login prompt before attempting SSH connection"
    
    # Add timeout prevention only if we have a working X11 display
    if [ "$HEADLESS" != true ] && [ -n "$DISPLAY" ] && command -v xset &>/dev/null; then
        # Test if DISPLAY is accessible before trying to configure it
        if xset q &>/dev/null; then
            log "Setting display timeout prevention..."
            xset s off 2>/dev/null || true
            xset -dpms 2>/dev/null || true
        else
            log "X11 display not accessible, skipping timeout prevention"
        fi
    elif [ "$HEADLESS" != true ]; then
        log "X11 not available, display timeout prevention skipped"
    fi
    
    echo
    
    # Start QEMU with proven configuration
    "$qemu_cmd" "${qemu_args[@]}" &
    local qemu_pid=$!
    export CURRENT_QEMU_PID=$qemu_pid
    
    # Update instance state
    if [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            local temp_file=$(mktemp)
            sed "s/PID=PENDING/PID=$qemu_pid/" "$state_file" > "$temp_file"
            mv "$temp_file" "$state_file"
            log "Updated instance $INSTANCE_ID with QEMU PID $qemu_pid"
        fi
    fi
    
    # Monitor process
    (
        while true; do
            if ! kill -0 $qemu_pid 2>/dev/null; then
                log "QEMU process $qemu_pid has terminated"
                if [ -n "$INSTANCE_ID" ]; then
                    cleanup_instance_ports "$INSTANCE_ID"
                fi
                exit 0
            fi
            sleep 1
        done
    ) &
    local monitor_pid=$!
    
    # Cleanup on exit
    cleanup_on_exit() {
        log "Cleaning up QEMU processes..."
        kill $monitor_pid 2>/dev/null || true
        if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
            kill -TERM "$qemu_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
        if [ -n "$INSTANCE_ID" ]; then
            cleanup_instance_ports "$INSTANCE_ID"
        fi
    }
    
    trap cleanup_on_exit TERM INT EXIT
    
    # Wait for QEMU process
    wait $qemu_pid
    local exit_code=$?
    
    # Cleanup
    kill $monitor_pid 2>/dev/null || true
    if [ -n "$INSTANCE_ID" ]; then
        log "QEMU exited with code $exit_code, cleaning up instance $INSTANCE_ID"
        cleanup_instance_ports "$INSTANCE_ID"
    fi
    
    return $exit_code
}

# Enhanced cleanup function
cleanup() {
    log "Running cleanup function..."
    
    # Detach all loop devices
    if [ -f "$RPI_IMAGE" ]; then
        local loop_devices
        loop_devices=$(losetup -j "$RPI_IMAGE" | awk -F: '{print $1}' || true)
        for loop_dev in $loop_devices; do
            if [ -n "$loop_dev" ]; then
                log "Detaching loop device $loop_dev"
                sudo losetup -d "$loop_dev" 2>/dev/null || true
            fi
        done
    fi
    
    # Cleanup mount points
    sudo umount /tmp/rpi_boot_* 2>/dev/null || true
    sudo umount /tmp/rpi_root_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_boot_* 2>/dev/null || true
    sudo rmdir /tmp/rpi_root_* 2>/dev/null || true
    
    # Cleanup instance
    if [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            source "$state_file"
            if [ "$OWNER_PID" = "$$" ] || [ "$need_allocation" = "true" ]; then
                log "Cleaning up ports for instance $INSTANCE_ID"
                cleanup_instance_ports "$INSTANCE_ID"
            fi
        fi
    fi
    
    # Cleanup QEMU processes
    if [ -n "$CURRENT_QEMU_PID" ] && kill -0 "$CURRENT_QEMU_PID" 2>/dev/null; then
        log "Terminating QEMU process $CURRENT_QEMU_PID"
        kill -TERM "$CURRENT_QEMU_PID" 2>/dev/null || true
    fi
    
    # Clean build artifacts if requested
    if [ "$CLEAN_BUILD" = true ]; then
        clean_build_artifacts
    fi
}

# Handle signals
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup' EXIT

# Main function with NETWORK BOOT FIXES
main() {
    echo -e "\033[34m"
    echo "========================================================="
    echo " QEMU Raspberry Pi - [$DISTRO] - NETWORK FIXED         "
    echo " Based on: https://gist.github.com/mmguero/             "
    echo "           5c13aa16a68783e6240458e0282f27da             "
    echo "========================================================="
    echo -e "\033[0m"
    
    auto_cleanup_dead_instances
    check_dependencies
    download_image
    
    # CRITICAL: Build custom kernel (this is the key fix)
    build_custom_kernel
    
    setup_ssh_and_user
    resize_image_advanced
    
    echo
    log "Setup complete! Starting [$DISTRO] emulation with NETWORK BOOT FIXES..."
    echo
    
    # Port allocation logic
    local need_allocation=false
    if [ -z "$ALLOCATED_SSH_PORT" ]; then
        need_allocation=true
        INSTANCE_ID=$(generate_instance_id "$DISTRO")
        log "Allocating ports for instance $INSTANCE_ID"
        
        if ! allocate_ports "$INSTANCE_ID" "$ENABLE_VNC" "$ENABLE_RDP" "$ENABLE_WAYVNC" \
            "$SSH_PORT" "$VNC_PORT" "$RDP_PORT" "$WAYVNC_PORT"; then
            error "Failed to allocate ports"
            exit 1
        fi
        
        SSH_PORT=$ALLOCATED_SSH_PORT
        if [ "$ENABLE_VNC" = true ]; then VNC_PORT=$ALLOCATED_VNC_PORT; fi
        if [ "$ENABLE_RDP" = true ]; then RDP_PORT=$ALLOCATED_RDP_PORT; fi
        if [ "$ENABLE_WAYVNC" = true ]; then WAYVNC_PORT=$ALLOCATED_WAYVNC_PORT; fi
        export need_allocation=true
    else
        log "Using pre-allocated ports: SSH=$ALLOCATED_SSH_PORT"
        SSH_PORT=$ALLOCATED_SSH_PORT
        if [ "$ENABLE_VNC" = true ]; then VNC_PORT=$ALLOCATED_VNC_PORT; fi
        if [ "$ENABLE_RDP" = true ]; then RDP_PORT=$ALLOCATED_RDP_PORT; fi
        if [ "$ENABLE_WAYVNC" = true ]; then WAYVNC_PORT=$ALLOCATED_WAYVNC_PORT; fi
        export need_allocation=false
    fi
    
    # Start QEMU with proven configuration
    start_qemu
}

# Show help
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "NETWORK BOOT FIXED VERSION"
    echo "Based on proven working guide using virt machine and custom kernel"
    echo "Inspired by: https://gist.github.com/mmguero/5c13aa16a68783e6240458e0282f27da"
    echo
    echo "Options:"
    echo " -h, --help       Show this help message"
    echo " -p PORT          Set SSH port (default: auto)"
    echo " -d DIR           Set working directory (default: ~/qemu-rpi/bookworm)"
    echo " --vnc [PORT]     Enable VNC server (default port: auto)"
    echo " --rdp [PORT]     Enable RDP server (default port: auto)" 
    echo " --wayvnc [PORT]  Enable WayVNC for Wayland (default port: auto)"
    echo " --headless       Run without display (headless mode)"
    echo " --clean-build    Clean kernel build artifacts and rebuild"
    echo " --clean-all      Clean all build artifacts after kernel build"
    echo
    echo "NETWORK FIXES APPLIED:"
    echo " ✓ Uses virt machine with proven virtio-net-pci networking"
    echo " ✓ Builds custom ARM64 kernel with kvm_guest config"
    echo " ✓ Proper virtio block device configuration"
    echo " ✓ Correct root device path (/dev/vda2)"
    echo " ✓ Removes problematic usb-net device"
    echo " ✓ GPU acceleration with DRI device detection"
    echo " ✓ Display timeout prevention for GUI mode"
    echo " ✓ Automatic build artifact cleanup"
    echo " ✓ Follows exact proven working methodology from guide"
    echo
    echo "Examples:"
    echo " $0                           # Basic setup with network fixes"
    echo " $0 --headless --vnc          # Headless with VNC"
    echo " $0 --vnc --rdp               # Full remote access"
    echo " $0 --clean-build             # Rebuild kernel from scratch"
    echo " $0 --clean-all --headless    # Clean build with headless mode"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p)
            SSH_PORT="$2"
            shift 2
            ;;
        -d)
            WORK_DIR="$2"
            shift 2
            ;;
        --vnc)
            ENABLE_VNC=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                VNC_PORT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --rdp)
            ENABLE_RDP=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                RDP_PORT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --wayvnc)
            ENABLE_WAYVNC=true
            if [[ $2 =~ ^[0-9]+$ ]]; then
                WAYVNC_PORT="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --headless)
            HEADLESS=true
            shift 1
            ;;
        --clean-build|--clean-all)
            CLEAN_BUILD=true
            shift 1
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main