#!/bin/bash -e
################################################################################
##  File:  install-retropie.sh
##  Desc: Installs RetroPie on a PiOS AArch64 image for CM5.
##        Follows steps from https://retropie.org.uk/docs/Manual-Installation/
##        and https://www.youtube.com/watch?v=PAePvz6YSWo
################################################################################
set -x

# Initialize logging
LOG_FILE="/var/log/install-retropie-$(date +%Y%m%d%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Progress tracking file
PROGRESS_FILE="/opt/retropie_installation_progress"
touch "$PROGRESS_FILE" 2>/dev/null || { echo "Failed to create progress file"; exit 1; }
chmod 666 "$PROGRESS_FILE"

# Flag to track changes requiring reboot
CHANGES_MADE=false

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Function to check if a step is complete
is_step_complete() {
    grep -Fx "$1" "$PROGRESS_FILE" >/dev/null 2>&1
}

# Function to mark a step as complete
mark_step_complete() {
    echo "$1" >> "$PROGRESS_FILE"
    CHANGES_MADE=true
}

# Function to handle failures
handle_failure() {
    log_message "Error: $1"
    sleep 5
    [ "$2" = "reboot" ] && { log_message "Rebooting due to failure..."; reboot; }
    exit 1
}

# Verify architecture (CM5 requires aarch64)
ARCH=$(uname -m)
[ "$ARCH" != "aarch64" ] && log_message "Warning: Non-aarch64 ($ARCH). CM5 requires aarch64."

# Function to fix system date
fix_system_date() {
    if ! is_step_complete "fix_system_date"; then
        log_message "Fixing system date..."
        DATE_STR=$(curl -s -I www.example.com | grep -i '^date:' | cut -d' ' -f2-)
        if [ -n "$DATE_STR" ]; then
            date -s "$DATE_STR" >/dev/null 2>>"$LOG_FILE" || log_message "Failed to set date. Current: $(date)"
        else
            log_message "Failed to fetch date. Current: $(date)"
        fi
        mark_step_complete "fix_system_date"
    fi
}

# Reboot the system to apply date changes
if [ "$CHANGES_MADE" = true ]; then
    echo "Rebooting system to apply date changes..." >> "$LOG_FILE"
    /sbin/reboot
fi

# Function to handle WiFi module
handle_wifi_module() {
    local BRCMFMAC_PATH="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac"
    if [ -f "$BRCMFMAC_PATH/brcmfmac.ko.xz" ] && [ ! -f "$BRCMFMAC_PATH/brcmfmac.ko" ]; then
        log_message "Uncompressing WiFi module..."
        unxz "$BRCMFMAC_PATH/brcmfmac.ko.xz" || handle_failure "Failed to uncompress brcmfmac.ko.xz"
        depmod -a || handle_failure "depmod failed"
    fi
    if [ ! -f "$BRCMFMAC_PATH/brcmfmac.ko" ]; then
        log_message "Installing kernel and firmware..."
        apt update && apt install --reinstall -y raspberrypi-kernel=1:6.6.51+rpt-rpi-2712 firmware-brcm80211 || handle_failure "Kernel/firmware reinstall failed"
        depmod -a || handle_failure "depmod failed"
    fi
    modprobe brcmfmac || log_message "Failed to load brcmfmac"
}

# Function to check WiFi connectivity
check_wifi() {
    log_message "Checking WiFi connectivity..."
    for ((i=1; i<=3; i++)); do
        log_message "WiFi check (Attempt $i/3)..."
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log_message "WiFi connected"
            return 0
        fi
        sleep 10
    done
    handle_failure "WiFi connectivity check failed" reboot
}

# Function to update system
update_system() {
    if ! is_step_complete "update_upgrade"; then
        log_message "Updating system..."
        if ! mountpoint /boot/firmware >/dev/null 2>&1; then
            log_message "Mounting /boot/firmware..."
            DEBIAN_FRONTEND=noninteractive apt update && apt install --reinstall -y raspi-firmware || handle_failure "install_raspi_firmware" reboot
            mount /boot/firmware || log_message "Failed to mount /boot/firmware"
        fi

        if ! is_step_complete "set_kernel"; then
            if ! grep -q "^kernel=kernel8.img" /boot/firmware/config.txt 2>/dev/null; then
                log_message "Setting kernel=kernel8.img in config.txt"
                echo "kernel=kernel8.img" >> /boot/firmware/config.txt || log_message "Failed to set kernel in config.txt"
                mark_step_complete "set_kernel"
            fi
        fi

        log_message "Cleaning up dpkg and apt..."
        pkill -f dpkg 2>/dev/null || log_message "No dpkg processes to kill"
        pkill -f apt 2>/dev/null || log_message "No apt processes to kill"
        rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null
        dpkg --configure -a --force-confnew || log_message "dpkg configure failed"
        DEBIAN_FRONTEND=noninteractive apt install -f -y || handle_failure "fix_broken" reboot

        AVAILABLE_SPACE=$(df -h /boot/firmware 2>/dev/null | awk 'NR==2 {print $4}' | grep -o '[0-9]\+')
        if [ -n "$AVAILABLE_SPACE" ] && [ "$AVAILABLE_SPACE" -lt 50 ]; then
            log_message "Cleaning up /boot/firmware..."
            apt purge -y linux-image-[0-5].* linux-headers-[0-5].* 2>>"$LOG_FILE" || log_message "No old kernels to purge"
            apt autoremove --purge -y || log_message "Autoremove failed"
            apt clean || log_message "APT clean failed"
        fi

        DEBIAN_FRONTEND=noninteractive apt update || handle_failure "update" reboot
        DEBIAN_FRONTEND=noninteractive apt upgrade -y -o Dpkg::Options::="--force-confnew" || handle_failure "upgrade" reboot
        LATEST_KERNEL=$(apt-cache show raspberrypi-kernel | grep Version | head -n1 | awk '{print $2}')
        apt install -y raspberrypi-kernel=$LATEST_KERNEL raspberrypi-bootloader || log_message "Kernel/bootloader install failed"
        update-initramfs -u -k all || update-initramfs -c -k $(uname -r) || log_message "Initramfs update failed"
        mark_step_complete "update_upgrade"
    fi
}

# Function to install dependencies
install_dependencies() {
    if ! is_step_complete "install_dependencies"; then
        log_message "Installing dependencies..."
        apt install -y git lsb-release i2c-tools mesa-vulkan-drivers mesa-utils vulkan-tools || handle_failure "install_dependencies" reboot
        mark_step_complete "install_dependencies"
    fi
}

# Function to install RetroPie
install_retropie() {
    if ! is_step_complete "clone_retropie"; then
        log_message "Cloning RetroPie-Setup..."
        cd /opt || handle_failure "change_directory" reboot
        [ -d "RetroPie-Setup" ] || git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git || handle_failure "clone_retropie" reboot
        mark_step_complete "clone_retropie"
    fi

    if ! is_step_complete "setup_retropie"; then
        log_message "Setting up RetroPie..."
        cd /opt/RetroPie-Setup || handle_failure "change_directory_retropie" reboot
        chmod +x retropie_packages.sh || handle_failure "chmod_retropie_packages" reboot

        # Install RetroPie components
        local components=(
            "retroarch:install_retroarch"
            "emulationstation:install_emulationstation"
            "retropiemenu:install_retropiemenu"
            "runcommand:install_runcommand"
            "samba depends:install_samba_depends"
            "samba install_shares:install_samba_shares"
            "splashscreen default:install_splashscreen_default"
            "splashscreen enable:install_splashscreen"
            "bashwelcometweak:install_bashwelcometweak"
            "joy2key:install_joy2key"
        )

        for comp in "${components[@]}"; do
            IFS=':' read -r cmd step <<< "$comp"
            if ! is_step_complete "$step"; then
                log_message "Installing $cmd..."
                ./retropie_packages.sh $cmd || handle_failure "$step" reboot
                mark_step_complete "$step"
            fi
        done

        # Enable autostart
        if ! is_step_complete "enable_autostart"; then
            log_message "Enabling autostart for EmulationStation..."
            ./retropie_packages.sh autostart enable || handle_failure "enable_autostart" reboot
            sed -i '3i\    sleep 3\n    while pgrep -f "/usr/local/bin/install-retropie.sh" > /dev/null; do\n      sleep 5\n    done' /etc/profile.d/10-retropie.sh 2>>"$LOG_FILE" || log_message "Failed to update autostart.sh"
            mark_step_complete "enable_autostart"
        fi

        mark_step_complete "setup_retropie"
    fi
}

# Function to install RetroPie cores
install_cores() {
    if [ ! -f "/boot/firmware/retropie.conf" ]; then
        log_message "Warning: /boot/firmware/retropie.conf not found, skipping core installation"
        return
    fi

    log_message "Installing RetroPie cores..."
    CORES=$(grep -oP '^\s*"[^"]+"(?=\s*#|$)' /boot/firmware/retropie.conf | tr -d '"' | sort -u)
    [ -z "$CORES" ] && log_message "No cores specified in retropie.conf"

    for CORE in $CORES; do
        if ! is_step_complete "install_$CORE"; then
            log_message "Installing core: $CORE..."
            /opt/RetroPie-Setup/retropie_packages.sh "$CORE" || handle_failure "install_$CORE" reboot
            mark_step_complete "install_$CORE"
        fi
    done
}

# Main execution
log_message "Starting RetroPie installation..."
fix_system_date
handle_wifi_module
check_wifi
update_system
install_dependencies
install_retropie
install_cores

# Final reboot if changes were made
if [ "$CHANGES_MADE" = true ]; then
    log_message "Installation complete. Rebooting..."
    sleep 5
    reboot
else
    log_message "No changes made. Installation already complete."
fi
