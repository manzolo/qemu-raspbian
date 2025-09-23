#!/bin/bash

# Raspberry Pi QEMU Menu Launcher with Enhanced Port Management - FIXED VERSION
# Risolve i problemi di cleanup multipli tra istanze

#set -e

# Load port management system
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_MGMT_SCRIPT="$SCRIPT_DIR/port_management.sh"

if [ ! -f "$PORT_MGMT_SCRIPT" ]; then
    error "Port management script not found: $PORT_MGMT_SCRIPT"
    error "Please ensure port_management.sh is in the same directory as this script"
    exit 1
fi

# Source the port management system
source "$PORT_MGMT_SCRIPT"

# FIXED: Track if we're launching an emulator to prevent cleanup conflicts
export LAUNCHING_EMULATOR=0
export MENU_PID=$$

# Check if dialog is installed
check_dialog() {
    if ! command -v dialog &> /dev/null; then
        error "Dialog not found. Installing..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y dialog
        elif command -v yum &> /dev/null; then
            sudo yum install -y dialog
        elif command -v pacman &> /dev/null; then
            sudo pacman -S dialog
        else
            error "Cannot install dialog automatically. Please install it manually."
            exit 1
        fi
    fi
}

# Script paths (adjust these based on your file names)
declare -A SCRIPTS=(
    ["jessie"]="./raspios-jessie-emulator.sh"
    ["stretch"]="./raspios-stretch-emulator.sh"
    ["buster"]="./raspios-buster-emulator.sh"
    ["bullseye"]="./raspios-bullseye-emulator.sh"
    ["bookworm"]="./raspios-bookworm-emulator.sh"
)

# Distribution information
declare -A DISTRO_INFO=(
    ["jessie"]="Raspbian Jessie 2017|ARM1176 CPU, 256MB RAM|Lightweight, SSH enabled|~1.4GB download"
    ["stretch"]="Raspbian Stretch 2018|ARM1176 CPU, 512MB RAM|Built-in VNC server|~1.7GB download"
    ["buster"]="Raspbian Buster 2020|ARM1176 CPU, 1GB RAM|RealVNC, Python 3.7|~1.1GB download"
    ["bullseye"]="Pi OS Bullseye 2022 ARMhf|Cortex-A53, 1GB RAM|Wayland support, 32-bit|~1.1GB download"
    ["bookworm"]="Pi OS Bookworm 2025 Full|Cortex-A53, 2GB RAM|Complete suite, Wayland+X11|~2.4GB download"
)

# Check if scripts exist
check_scripts() {
    local missing_scripts=()
    
    for distro in "${!SCRIPTS[@]}"; do
        if [ ! -f "${SCRIPTS[$distro]}" ]; then
            missing_scripts+=("$distro: ${SCRIPTS[$distro]}")
        fi
    done
    
    if [ ${#missing_scripts[@]} -ne 0 ]; then
        dialog --title "Missing Scripts" --msgbox "The following scripts are missing:\n\n$(printf '%s\n' "${missing_scripts[@]}")\n\nPlease ensure all scripts are in the same directory as this menu." 15 70
        return 1
    fi
    return 0
}

# Make scripts executable
make_executable() {
    for script in "${SCRIPTS[@]}"; do
        if [ -f "$script" ]; then
            chmod +x "$script"
        fi
    done
}

# Show instance management menu
show_instance_menu() {
    local temp_file=$(mktemp)
    
    dialog --title "🖥️ Instance Management" \
           --menu "Manage running QEMU instances:" 15 70 8 \
           "list" "📋 List Active Instances" \
           "ports" "📊 Show Port Usage" \
           "cleanup" "🧹 Cleanup Stale Instances" \
           "kill" "⛔ Kill Instance by Port" \
           "killall" "🚫 Kill All Instances" \
           "back" "← Back to Main Menu" 2> "$temp_file"
    
    local choice=$(cat "$temp_file")
    rm -f "$temp_file"
    
    case $choice in
        "list")
            local output=$(list_active_instances)
            dialog --title "Active Instances" --msgbox "$output" 20 80
            show_instance_menu
            ;;
        "ports")
            local output=$(show_port_usage)
            dialog --title "Port Usage Statistics" --msgbox "$output" 15 60
            show_instance_menu
            ;;
        "cleanup")
            cleanup_stale_instances
            dialog --title "Cleanup Complete" --msgbox "Stale instances and port locks have been cleaned up." 8 50
            show_instance_menu
            ;;
        "kill")
            show_kill_instance_menu
            ;;
        "killall")
            if dialog --title "Confirm Kill All" --yesno "Are you sure you want to kill ALL running QEMU instances?\n\nThis will terminate all emulated Raspberry Pi systems." 10 60; then
                kill_all_instances
                dialog --title "Kill All Complete" --msgbox "All QEMU instances have been terminated." 8 50
            fi
            show_instance_menu
            ;;
        "back"|"")
            show_main_menu
            ;;
    esac
}

# Show kill instance by port menu
show_kill_instance_menu() {
    local temp_file=$(mktemp)
    local instances_info=""
    local menu_items=()
    
    # Build list of active instances
    local found_any=false
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            source "$state_file"
            if [ "$PID" != "PENDING" ] && kill -0 "$PID" 2>/dev/null; then
                found_any=true
                menu_items+=("$SSH_PORT" "Instance: $INSTANCE_ID (SSH: $SSH_PORT)")
            fi
        fi
    done
    
    if [ "$found_any" = false ]; then
        dialog --title "No Active Instances" --msgbox "No active instances found to terminate." 8 50
        show_instance_menu
        return
    fi
    
    # Add back option
    menu_items+=("back" "← Back to Instance Management")
    
    dialog --title "⛔ Kill Instance" \
           --menu "Select instance to kill (by SSH port):" 15 60 8 \
           "${menu_items[@]}" 2> "$temp_file"
    
    local choice=$(cat "$temp_file")
    rm -f "$temp_file"
    
    if [ "$choice" = "back" ] || [ -z "$choice" ]; then
        show_instance_menu
        return
    fi
    
    # Find and kill the instance
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            source "$state_file"
            if [ "$SSH_PORT" = "$choice" ] && [ "$PID" != "PENDING" ] && kill -0 "$PID" 2>/dev/null; then
                if dialog --title "Confirm Kill" --yesno "Kill instance $INSTANCE_ID?\nSSH Port: $SSH_PORT\nPID: $PID" 10 50; then
                    kill "$PID" 2>/dev/null || true
                    sleep 2
                    # Force kill if still running
                    kill -9 "$PID" 2>/dev/null || true
                    cleanup_instance_ports "$INSTANCE_ID"
                    dialog --title "Instance Killed" --msgbox "Instance $INSTANCE_ID has been terminated." 8 50
                fi
                break
            fi
        fi
    done
    
    show_instance_menu
}

# Kill all instances function
kill_all_instances() {
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            source "$state_file"
            if [ "$PID" != "PENDING" ] && kill -0 "$PID" 2>/dev/null; then
                kill "$PID" 2>/dev/null || true
            fi
            cleanup_instance_ports "$INSTANCE_ID"
        fi
    done
    
    # Also kill any remaining qemu processes
    pkill -f "qemu-system-arm" 2>/dev/null || true
    pkill -f "qemu-system-aarch64" 2>/dev/null || true
    
    # Clean up any remaining locks
    rm -rf "$PORT_LOCK_DIR"/*
    rm -rf "$INSTANCE_STATE_DIR"/*
}

# Enhanced port configuration menu
show_port_config_menu() {
    local distro=$1
    local temp_file=$(mktemp)
    
    dialog --title "⚙️ Port Configuration for $distro" \
           --form "Configure port settings (leave empty for auto-allocation):" 15 70 6 \
           "SSH Port:" 1 1 "" 1 15 10 0 \
           "VNC Port:" 2 1 "" 2 15 10 0 \
           "RDP Port:" 3 1 "" 3 15 10 0 \
           "WayVNC Port:" 4 1 "" 4 15 10 0 2> "$temp_file"
    
    if [ $? -ne 0 ]; then
        rm -f "$temp_file"
        show_options_menu "$distro"
        return
    fi
    
    local form_data=($(cat "$temp_file"))
    rm -f "$temp_file"
    
    # Extract port values (empty means auto)
    local ssh_port="${form_data[0]:-auto}"
    local vnc_port="${form_data[1]:-auto}"
    local rdp_port="${form_data[2]:-auto}"
    local wayvnc_port="${form_data[3]:-auto}"
    
    # Store the port preferences
    export REQUESTED_SSH_PORT="$ssh_port"
    export REQUESTED_VNC_PORT="$vnc_port"
    export REQUESTED_RDP_PORT="$rdp_port"
    export REQUESTED_WAYVNC_PORT="$wayvnc_port"
    
    show_options_menu "$distro"
}

# Main menu
show_main_menu() {
    local temp_file=$(mktemp)
    
    # Get instance count for display
    local instance_count=0
    for state_file in "$INSTANCE_STATE_DIR"/*.state; do
        if [ -f "$state_file" ]; then
            source "$state_file"
            if [ "$PID" = "PENDING" ] || ([ "$PID" != "PENDING" ] && kill -0 "$PID" 2>/dev/null); then
                ((instance_count++))
            fi
        fi
    done
    
    local instance_display=""
    if [ $instance_count -gt 0 ]; then
        instance_display=" ($instance_count running)"
    fi
    
    dialog --title "🍓 Raspberry Pi QEMU Emulator with Port Management" \
           --menu "Choose a Raspberry Pi OS version to emulate:" 18 85 10 \
           "jessie" "Raspbian Jessie 2017 (Lightweight, Classic)" \
           "stretch" "Raspbian Stretch 2018 (VNC Built-in)" \
           "buster" "Raspbian Buster 2020 (Stable, RealVNC)" \
           "bullseye" "Pi OS Bullseye 2022 (Modern, ARMhf)" \
           "bookworm" "Pi OS Bookworm 2025 (Latest, Full Suite)" \
           "instances" "🖥️ Instance Management$instance_display" \
           "info" "📋 View Detailed Information" \
           "deps" "🔧 Check Dependencies" \
           "help" "❓ Help & Troubleshooting" \
           "quit" "❌ Exit" 2> "$temp_file"
    
    local choice=$(cat "$temp_file")
    rm -f "$temp_file"
    
    case $choice in
        "jessie"|"stretch"|"buster"|"bullseye"|"bookworm")
            show_options_menu "$choice"
            ;;
        "instances")
            show_instance_menu
            ;;
        "info")
            show_info_menu
            ;;
        "deps")
            check_dependencies_menu
            ;;
        "help")
            show_help_menu
            ;;
        "quit"|"")
            clear
            echo -e "${CYAN}Thanks for using Raspberry Pi QEMU Emulator!${NC}"
            exit 0
            ;;
    esac
}

# Show detailed information
show_info_menu() {
    local temp_file=$(mktemp)
    
    dialog --title "📋 Distribution Information" \
           --menu "Select a distribution for detailed info:" 15 70 8 \
           "jessie" "Raspbian Jessie 2017" \
           "stretch" "Raspbian Stretch 2018" \
           "buster" "Raspbian Buster 2020" \
           "bullseye" "Pi OS Bullseye 2022" \
           "bookworm" "Pi OS Bookworm 2025" \
           "back" "← Back to Main Menu" 2> "$temp_file"
    
    local choice=$(cat "$temp_file")
    rm -f "$temp_file"
    
    if [[ "$choice" != "back" && "$choice" != "" ]]; then
        IFS='|' read -ra INFO <<< "${DISTRO_INFO[$choice]}"
        dialog --title "📋 ${INFO[0]}" --msgbox "\
Hardware: ${INFO[1]}
Features: ${INFO[2]}
Download: ${INFO[3]}

Key Characteristics:
$(case $choice in
    jessie) echo "• Classic Raspbian experience
• SSH enabled by default  
• Minimal resource usage
• ARM1176 CPU emulation
• Perfect for learning basics" ;;
    stretch) echo "• Introduction of built-in VNC
• Better hardware support
• SSH requires explicit enabling
• Improved performance
• Good balance of features/resources" ;;
    buster) echo "• RealVNC server integrated
• Python 3.7 as default
• Enhanced stability
• Better multimedia support
• Last version before major changes" ;;
    bullseye) echo "• First with Wayland support
• 32-bit ARM for compatibility
• Modern kernel and drivers
• Better security features
• Transition to newer technologies" ;;
    bookworm) echo "• Complete software suite included
• LibreOffice, Chromium, dev tools
• Dual Wayland + X11 support
• Python 3.11, latest packages
• Full desktop experience" ;;
esac)" 20 70
    fi
    
    show_info_menu
}

# Options menu for selected distribution with enhanced port management
show_options_menu() {
    local distro=$1
    local temp_file=$(mktemp)
    
    # Verifica che la distribuzione sia valida
    if [[ ! "$distro" =~ ^(jessie|stretch|buster|bullseye|bookworm)$ ]]; then
        echo "ERROR: Distribuzione non valida: $distro" >&2
        show_main_menu
        return
    fi
    
    # Costruisci il comando dialog step by step per evitare errori di sintassi
    local dialog_cmd="dialog --title \"🔧 ${distro^} Options with Port Management\" \
        --checklist \"Select options for $distro emulation:\" 18 75 10 \
        \"ssh\" \"Enable SSH (auto-allocated port)\" on \
        \"vnc\" \"Enable VNC server (auto-allocated port)\" off \
        \"rdp\" \"Enable RDP server (auto-allocated port)\" off \
        \"headless\" \"Run headless (no GUI)\" off"
    
    # Aggiungi WayVNC solo per bookworm
    if [ "$distro" == "bookworm" ]; then
        dialog_cmd="$dialog_cmd \"wayvnc\" \"Enable WayVNC for Wayland (auto-allocated port)\" off"
    fi
    
    # Esegui il comando dialog
    eval "$dialog_cmd" 2> "$temp_file"
    local dialog_result=$?
    
    local selections=$(cat "$temp_file")
    rm -f "$temp_file"
    
    # Gestisci il risultato
    case $dialog_result in
        0)  # OK premuto
            if [ -n "$selections" ]; then
                show_launch_options_menu "$distro" "$selections"
            else
                # Nessuna opzione selezionata, chiedi conferma
                dialog --title "No Options Selected" \
                       --yesno "No options were selected. Do you want to launch with default settings (SSH only)?" 8 60
                if [ $? -eq 0 ]; then
                    show_launch_options_menu "$distro" "ssh"
                else
                    show_main_menu
                fi
            fi
            ;;
        1)  # Cancel premuto
            show_main_menu
            ;;
        255)  # ESC premuto
            show_main_menu
            ;;
        *)  # Errore imprevisto
            dialog --title "Dialog Error" --msgbox "An error occurred with the dialog. Returning to main menu." 8 60
            show_main_menu
            ;;
    esac
}

# Launch options menu with port configuration
show_launch_options_menu() {
    local distro=$1
    local options=$2
    local temp_file=$(mktemp)
    
    dialog --title "🚀 Launch Options for ${distro^}" \
           --menu "Choose launch configuration:" 15 70 8 \
           "auto" "🎯 Auto-allocate all ports (recommended)" \
           "custom" "⚙️ Configure custom ports" \
           "preview" "👀 Preview port allocation" \
           "back" "← Back to Options" 2> "$temp_file"
    
    local choice=$(cat "$temp_file")
    rm -f "$temp_file"
    
    case $choice in
        "auto")
            confirm_and_launch "$distro" "$options" "auto"
            ;;
        "custom")
            show_port_config_menu "$distro"
            confirm_and_launch "$distro" "$options" "custom"
            ;;
        "preview")
            show_port_preview "$distro" "$options"
            ;;
        "back"|"")
            show_options_menu "$distro"
            ;;
    esac
}

# Show port allocation preview
show_port_preview() {
    local distro=$1
    local options=$2
    
    # Generate a preview instance ID
    local preview_id=$(generate_instance_id "$distro")
    
    # Determine what services will be enabled
    local enable_vnc=false
    local enable_rdp=false
    local enable_wayvnc=false
    
    [[ $options == *"vnc"* ]] && enable_vnc=true
    [[ $options == *"rdp"* ]] && enable_rdp=true
    [[ $options == *"wayvnc"* ]] && enable_wayvnc=true
    
    # Find what ports would be allocated
    local preview_ssh=$(find_available_port $DEFAULT_SSH_BASE "$preview_id" "ssh" 2>/dev/null || echo "N/A")
    local preview_vnc=""
    local preview_rdp=""
    local preview_wayvnc=""
    
    if [ "$enable_vnc" = true ]; then
        preview_vnc=$(find_available_port $DEFAULT_VNC_BASE "$preview_id" "vnc" 2>/dev/null || echo "N/A")
    fi
    
    if [ "$enable_rdp" = true ]; then
        preview_rdp=$(find_available_port $DEFAULT_RDP_BASE "$preview_id" "rdp" 2>/dev/null || echo "N/A")
    fi
    
    if [ "$enable_wayvnc" = true ]; then
        preview_wayvnc=$(find_available_port $DEFAULT_WAYVNC_BASE "$preview_id" "wayvnc" 2>/dev/null || echo "N/A")
    fi
    
    # Build preview message
    local preview_msg="Port allocation preview for $distro:

SSH Port: $preview_ssh"
    
    if [ -n "$preview_vnc" ]; then
        preview_msg="$preview_msg
VNC Port: $preview_vnc"
    fi
    
    if [ -n "$preview_rdp" ]; then
        preview_msg="$preview_msg
RDP Port: $preview_rdp"
    fi
    
    if [ -n "$preview_wayvnc" ]; then
        preview_msg="$preview_msg
WayVNC Port: $preview_wayvnc"
    fi
    
    preview_msg="$preview_msg

Note: Actual ports may differ if these become unavailable before launch."
    
    dialog --title "👀 Port Allocation Preview" --msgbox "$preview_msg" 15 60
    show_launch_options_menu "$distro" "$options"
}

# FIXED: Confirm and launch with better instance management
confirm_and_launch() {
    local distro=$1
    local options=$2
    local port_mode=$3
    
    # Determine enabled services
    local enable_vnc=false
    local enable_rdp=false
    local enable_wayvnc=false
    local enable_headless=false
    
    [[ $options == *"vnc"* ]] && enable_vnc=true
    [[ $options == *"rdp"* ]] && enable_rdp=true
    [[ $options == *"wayvnc"* ]] && enable_wayvnc=true
    [[ $options == *"headless"* ]] && enable_headless=true
    
    # Generate instance ID
    local instance_id=$(generate_instance_id "$distro")
    
    # Set up port preferences
    local req_ssh="${REQUESTED_SSH_PORT:-auto}"
    local req_vnc="${REQUESTED_VNC_PORT:-auto}"
    local req_rdp="${REQUESTED_RDP_PORT:-auto}"
    local req_wayvnc="${REQUESTED_WAYVNC_PORT:-auto}"
    
    # Allocate ports
    if ! allocate_ports "$instance_id" "$enable_vnc" "$enable_rdp" "$enable_wayvnc" \
                        "$req_ssh" "$req_vnc" "$req_rdp" "$req_wayvnc"; then
        dialog --title "❌ Port Allocation Failed" --msgbox "\
Failed to allocate required ports. This may happen if:

• Requested specific ports are already in use
• Too many instances are running (max: $MAX_INSTANCES)
• System has insufficient available ports

Try:
• Using auto-allocation instead of custom ports
• Closing some running instances
• Cleaning up stale instances" 15 70
        show_launch_options_menu "$distro" "$options"
        return
    fi
    
    # Build confirmation message
    local info_text="Distribution: ${distro^}
Instance ID: $instance_id
Script: ${SCRIPTS[$distro]}

Allocated Ports:
• SSH: $ALLOCATED_SSH_PORT"
    
    if [ "$enable_vnc" = true ]; then
        info_text="$info_text
• VNC: $ALLOCATED_VNC_PORT"
    fi
    
    if [ "$enable_rdp" = true ]; then
        info_text="$info_text
• RDP: $ALLOCATED_RDP_PORT"
    fi
    
    if [ "$enable_wayvnc" = true ]; then
        info_text="$info_text
• WayVNC: $ALLOCATED_WAYVNC_PORT"
    fi
    
    info_text="$info_text

The emulator will:
1. Download the OS image if needed
2. Extract kernel and boot files
3. Configure remote access
4. Start QEMU emulation with allocated ports

Connection Info:
• SSH: ssh -p $ALLOCATED_SSH_PORT pi@localhost"
    
    if [ "$enable_vnc" = true ]; then
        info_text="$info_text
• VNC: localhost:$ALLOCATED_VNC_PORT (password: raspberry)"
    fi
    
    if [ "$enable_rdp" = true ]; then
        info_text="$info_text  
• RDP: localhost:$ALLOCATED_RDP_PORT (user: pi, pass: raspberry)"
    fi
    
    if [ "$enable_wayvnc" = true ]; then
        info_text="$info_text
• WayVNC: localhost:$ALLOCATED_WAYVNC_PORT"
    fi
    
    dialog --title "🚀 Launch Confirmation" --yesno "$info_text

Do you want to proceed?" 25 80
    
    if [ $? -eq 0 ]; then
        clear
        echo -e "${GREEN}Launching $distro emulation with instance ID: $instance_id${NC}"
        echo -e "${YELLOW}Allocated ports: SSH=$ALLOCATED_SSH_PORT"
        [ "$enable_vnc" = true ] && echo -e "VNC=$ALLOCATED_VNC_PORT"
        [ "$enable_rdp" = true ] && echo -e "RDP=$ALLOCATED_RDP_PORT"
        [ "$enable_wayvnc" = true ] && echo -e "WayVNC=$ALLOCATED_WAYVNC_PORT"
        echo -e "${NC}"
        
        # Build command line arguments
        local cmd_args="-p $ALLOCATED_SSH_PORT"
        
        if [ "$enable_vnc" = true ]; then
            cmd_args="$cmd_args --vnc $ALLOCATED_VNC_PORT"
        fi
        
        if [ "$enable_rdp" = true ]; then
            cmd_args="$cmd_args --rdp $ALLOCATED_RDP_PORT"
        fi
        
        if [ "$enable_wayvnc" = true ]; then
            cmd_args="$cmd_args --wayvnc $ALLOCATED_WAYVNC_PORT"
        fi
        
        if [ "$enable_headless" = true ]; then
            cmd_args="$cmd_args --headless"
        fi
        
        echo -e "${YELLOW}Command: ${SCRIPTS[$distro]} $cmd_args${NC}"
        echo
        
        # Special handling for different distributions
        case "$distro" in
            jessie)
                echo -e "${YELLOW}Note: Applying Jessie kernel panic fixes...${NC}"
                ;;
            bookworm)
                echo -e "${YELLOW}Note: Bookworm full desktop - first boot may take 10-15 minutes${NC}"
                ;;
        esac
        
        # FIXED: Set flag to indicate we're launching an emulator
        export LAUNCHING_EMULATOR=1
        export INSTANCE_ID="$instance_id"
        
        # Launch the script with allocated ports
        if [ -f "${SCRIPTS[$distro]}" ]; then
            "${SCRIPTS[$distro]}" $cmd_args
        else
            error "Script not found: ${SCRIPTS[$distro]}"
            cleanup_instance_ports "$instance_id"
            read -p "Press Enter to return to menu..."
            show_main_menu
        fi
    else
        # User cancelled, cleanup allocated ports
        cleanup_instance_ports "$instance_id"
        show_launch_options_menu "$distro" "$options"
    fi
}

# Check dependencies menu
check_dependencies_menu() {
    local deps_check=""
    
    # Check common dependencies
    local deps=("qemu-system-arm" "qemu-system-aarch64" "wget" "unzip" "xz" "fdisk" "dialog")
    local missing_deps=()
    local found_deps=()
    
    for dep in "${deps[@]}"; do
        if command -v "$dep" &> /dev/null; then
            found_deps+=("$dep")
        else
            missing_deps+=("$dep")
        fi
    done
    
    deps_check="✅ FOUND DEPENDENCIES:
$(printf '• %s\n' "${found_deps[@]}")

❌ MISSING DEPENDENCIES:
$(printf '• %s\n' "${missing_deps[@]}")

INSTALLATION COMMANDS:
Ubuntu/Debian: sudo apt-get install -y qemu-system-arm qemu-system-aarch64 wget unzip xz-utils fdisk dialog
Fedora/RHEL: sudo dnf install -y qemu-system-arm qemu-system-aarch64 wget unzip xz fdisk dialog
Arch Linux: sudo pacman -S qemu-arch-extra wget unzip xz fdisk dialog

PORT MANAGEMENT STATUS:
Port lock directory: $PORT_LOCK_DIR
Instance state directory: $INSTANCE_STATE_DIR
Maximum concurrent instances: $MAX_INSTANCES"
    
    dialog --title "🔧 Dependencies Check" --msgbox "$deps_check" 25 85
    show_main_menu
}

# Help menu (simplified for brevity)
show_help_menu() {
    local temp_file=$(mktemp)
    
    dialog --title "❓ Help & Troubleshooting" \
           --menu "Select a help topic:" 18 70 10 \
           "getting_started" "Getting Started Guide" \
           "port_management" "Port Management System" \
           "multiple_instances" "Running Multiple Instances" \
           "troubleshooting" "Common Issues" \
           "back" "← Back to Main Menu" 2> "$temp_file"
    
    local choice=$(cat "$temp_file")
    rm -f "$temp_file"
    
    case $choice in
        "port_management")
            dialog --title "🔧 Port Management System" --msgbox "\
AUTOMATIC PORT ALLOCATION:

The system automatically allocates unique ports for each instance:
• SSH: Starting from 2222, increments for each instance
• VNC: Starting from 5900, increments for each instance  
• RDP: Starting from 3389, increments for each instance
• WayVNC: Starting from 5901, increments for each instance

BENEFITS:
• No port conflicts when running multiple instances
• Automatic cleanup when instances terminate
• Port locks prevent race conditions
• Support for up to $MAX_INSTANCES concurrent instances

INSTANCE MANAGEMENT:
• View all running instances with their ports
• Kill specific instances by port number
• Clean up stale instances and locks
• Monitor port usage statistics" 20 75 
            show_help_menu
            ;;
        "multiple_instances")
            dialog --title "🖥️ Running Multiple Instances" --msgbox "\
RUNNING MULTIPLE RASPBERRY PI INSTANCES:

1. AUTOMATIC PORT ALLOCATION:
   • Each new instance gets unique ports automatically
   • No need to manually specify different ports
   • System prevents conflicts automatically

2. RESOURCE CONSIDERATIONS:
   • Each instance uses ~1-4GB RAM depending on Pi OS version
   • Jessie: ~512MB, Stretch: ~1GB, Buster: ~2GB, etc.
   • Monitor system resources when running many instances

3. INSTANCE MANAGEMENT:
   • Use 'Instance Management' menu to monitor all instances
   • View which ports are allocated to which instances
   • Kill specific instances when no longer needed

4. BEST PRACTICES:
   • Start with lighter distributions (Jessie/Stretch) for multiple instances
   • Use headless mode for better performance
   • Close unused instances to free up resources
   • Use the cleanup function to remove stale instances" 22 75 
            show_help_menu
            ;;
        "getting_started")
            dialog --title "🚀 Getting Started" --msgbox "\
1. Choose a Raspberry Pi OS version from the main menu
2. Select desired options (VNC, RDP, headless mode)
3. Choose auto port allocation (recommended) or custom ports
4. Wait for the image to download (first time only)
5. The emulator will start with unique allocated ports

FIRST BOOT:
• Wait 2-3 minutes for the system to fully boot
• SSH is available immediately: ssh -p <allocated_port> pi@localhost
• Default password: raspberry
• Check the launch output for your specific port numbers

MULTIPLE INSTANCES:
• You can launch multiple instances simultaneously
• Each gets unique ports automatically
• Use Instance Management to monitor them all" 20 70 
            show_help_menu
            ;;
        "troubleshooting")
            dialog --title "🔧 Troubleshooting" --msgbox "\
COMMON ISSUES:

1. PORT CONFLICTS:
   • Use auto-allocation instead of custom ports
   • Check Instance Management for active instances
   • Run cleanup to remove stale instances

2. EMULATOR WON'T START:
   • Check dependencies in main menu
   • Ensure scripts are executable
   • Verify sufficient disk space

3. MULTIPLE MENU SESSIONS:
   • Each menu session can launch one emulator
   • Open new terminal for additional instances
   • Use Instance Management to monitor all VMs

4. CLEANUP ISSUES:
   • Stale instances cleaned automatically on startup
   • Manual cleanup available in Instance Management
   • Port locks prevent conflicts between sessions" 20 70 
            show_help_menu
            ;;
        "back"|"")
            show_main_menu
            return
            ;;
    esac
}

# Welcome screen with port management info
show_welcome() {
    dialog --title "🍓 Welcome to Raspberry Pi QEMU Emulator" --msgbox "\
This interactive menu helps you emulate different versions of Raspberry Pi OS using QEMU with automatic port management.

FEATURES:
✅ Multiple Pi OS versions (Jessie 2017 → Bookworm 2025)
✅ Automatic image download and setup
✅ SSH, VNC, and RDP remote access with auto port allocation
✅ Headless and GUI modes
✅ Multiple concurrent instances support
✅ Instance management and monitoring

FIRST TIME USERS:
• Images will be downloaded automatically (1-2.4GB each)
• Ports are allocated automatically - no conflicts!
• Allow 5-10 minutes for first setup per instance
• Default login: pi / raspberry

Press OK to continue to the main menu..." 25 75
}

# FIXED: More selective cleanup that doesn't interfere with other menu sessions
cleanup_menu() {
    #clear
    echo -e "${CYAN}Raspberry Pi QEMU Emulator with Port Management - Goodbye!${NC}"
    
    # Only cleanup if:
    # 1. We're not launching an emulator
    # 2. We have an instance ID that belongs to us
    if [ "$LAUNCHING_EMULATOR" != "1" ] && [ -n "$INSTANCE_ID" ]; then
        local state_file="$INSTANCE_STATE_DIR/$INSTANCE_ID.state"
        if [ -f "$state_file" ]; then
            source "$state_file"
            # Only cleanup if we're the owner and no QEMU process is running
            if [ "$OWNER_PID" = "$$" ] && ([ "$PID" = "PENDING" ] || ! kill -0 "$PID" 2>/dev/null); then
                log "Menu session $ cleaning up instance $INSTANCE_ID"
                cleanup_instance_ports "$INSTANCE_ID"
            fi
        fi
    fi
}

# Main execution
main() {
    # Check for dialog
    check_dialog
    
    # Check if scripts exist
    if ! check_scripts; then
        exit 1
    fi
    
    # Initialize port management system
    log "Initializing port management system..."
    cleanup_stale_instances
    
    # Make scripts executable
    make_executable
    
    # Show welcome screen
    show_welcome
    
    # Main menu loop
    while true; do
        show_main_menu
    done
}

# FIXED: Set trap only for menu cleanup
trap cleanup_menu EXIT

# Run main function
main "$@"