#!/bin/bash -e
################################################################################
##  File:  install-pspi6.sh
##  Desc: Installs RetroPie on PiOS Aarch64 for PSPi 6 with CM5 support.
##  Notes: Requires WiFi pre-configured in Raspberry Pi Imager. DPI overlay in config.txt.
##  Fixes: System date, DPKG conflicts, WiFi module, RetroPie cores, /boot/firmware mount.
##  Updated: Auto-resolve initramfs.conf conflict, fallback to kernel 6.6.51, prevent reboot loop.
################################################################################
set -x

# Generate log file
LOG_FILE="/var/log/install-pspi6-$(date +%Y%m%d%H%M%S).log" || LOG_FILE="/var/log/install-pspi6-fallback.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Progress file
PROGRESS_FILE="/opt/pspi6_installation_progress"
touch "$PROGRESS_FILE"
chmod 666 "$PROGRESS_FILE"

# Track changes
CHANGES_MADE=false

# Function to check step completion
is_step_complete() {
    grep -q "$1" "$PROGRESS_FILE" 2>/dev/null
}

# Function to mark step completion
mark_step_complete() {
    echo "$1" >> "$PROGRESS_FILE"
}

# Function to handle failure
handle_failure() {
    echo "Step failed: $1. Attempting recovery..." >> "$LOG_FILE"
    pkill -f dpkg 2>>"$LOG_FILE" || echo "No dpkg processes to kill." >> "$LOG_FILE"
    pkill -f apt 2>>"$LOG_FILE" || echo "No apt processes to kill." >> "$LOG_FILE"
    rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>>"$LOG_FILE"
    dpkg --configure -a --force-confnew 2>>"$LOG_FILE" || echo "dpkg recovery failed." >> "$LOG_FILE"
    apt install -f -y 2>>"$LOG_FILE" || echo "apt fix failed." >> "$LOG_FILE"
    df -h /boot/firmware >> "$LOG_FILE" 2>/dev/null || echo "No /boot/firmware mounted." >> "$LOG_FILE"
    echo "Run 'sudo apt install --reinstall raspi-firmware raspberrypi-kernel=1:6.6.51+rpt-rpi-2712 firmware-brcm80211' if issues persist." >> "$LOG_FILE"
    sleep 30
    reboot
}

# Verify aarch64 for CM5
ARCH=$(uname -m)
[ "$ARCH" != "aarch64" ] && echo "Warning: Non-aarch64 ($ARCH). CM5 requires aarch64." >> "$LOG_FILE"

# Fix system date
if ! is_step_complete "fix_system_date"; then
    date -s "20250831 12:00:00" 2>>"$LOG_FILE" || echo "Date set failed. Current: $(date)" >> "$LOG_FILE"
    mark_step_complete "fix_system_date"
    CHANGES_MADE=true
fi

# Check and uncompress WiFi module
BRCMFMAC_PATH="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac"
if [ -f "$BRCMFMAC_PATH/brcmfmac.ko.xz" ] && [ ! -f "$BRCMFMAC_PATH/brcmfmac.ko" ]; then
    unxz "$BRCMFMAC_PATH/brcmfmac.ko.xz" 2>>"$LOG_FILE" || echo "Failed to uncompress brcmfmac.ko.xz." >> "$LOG_FILE"
    depmod -a 2>>"$LOG_FILE" || echo "depmod failed." >> "$LOG_FILE"
fi
if [ ! -f "$BRCMFMAC_PATH/brcmfmac.ko" ]; then
    apt update 2>>"$LOG_FILE" && apt install --reinstall raspberrypi-kernel=1:6.6.51+rpt-rpi-2712 firmware-brcm80211 2>>"$LOG_FILE" || echo "Kernel/firmware reinstall failed." >> "$LOG_FILE"
    depmod -a 2>>"$LOG_FILE" || echo "depmod failed." >> "$LOG_FILE"
fi
modprobe brcmfmac 2>>"$LOG_FILE" || echo "Failed to load brcmfmac." >> "$LOG_FILE"

# Check WiFi connectivity
WIFI_RETRIES=3
WIFI_SUCCESS=false
for ((i=1; i<=WIFI_RETRIES; i++)); do
    echo "Checking WiFi (Attempt $i/$WIFI_RETRIES)..." >> "$LOG_FILE"
    if ping -c 1 8.8.8.8 > /dev/null 2>&1; then
        WIFI_SUCCESS=true
        break
    fi
    sleep 10
done
[ "$WIFI_SUCCESS" != "true" ] && handle_failure "wifi_check"

# Update and upgrade system
if ! is_step_complete "update_upgrade"; then
    # Fix /boot/firmware mount
    if ! mountpoint /boot/firmware >/dev/null 2>&1; then
        echo "No /boot/firmware mounted. Reinstalling raspi-firmware..." >> "$LOG_FILE"
        apt update 2>>"$LOG_FILE" && apt install --reinstall raspi-firmware 2>>"$LOG_FILE" || handle_failure "install_raspi_firmware"
        mount /boot/firmware 2>>"$LOG_FILE" || echo "/boot/firmware mount failed." >> "$LOG_FILE"
    fi
    # Resolve dpkg conflicts and fix dependencies
    pkill -f dpkg 2>>"$LOG_FILE" || echo "No dpkg processes to kill." >> "$LOG_FILE"
    pkill -f apt 2>>"$LOG_FILE" || echo "No apt processes to kill." >> "$LOG_FILE"
    rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>>"$LOG_FILE"
    dpkg --configure -a --force-confnew 2>>"$LOG_FILE" || echo "dpkg configure failed." >> "$LOG_FILE"
    apt install -f -y 2>>"$LOG_FILE" || handle_failure "fix_broken"
    df -h /boot/firmware >> "$LOG_FILE" 2>/dev/null || echo "No /boot/firmware mounted." >> "$LOG_FILE"
    if [ "$(df -h /boot/firmware 2>/dev/null | awk 'NR==2 {print $4}' | grep -o '[0-9]\+')" -lt 50 ]; then
        apt purge -y linux-image-[0-5].* linux-headers-[0-5].* 2>>"$LOG_FILE" || echo "No old kernels." >> "$LOG_FILE"
        apt autoremove --purge -y 2>>"$LOG_FILE" || echo "Autoremove failed." >> "$LOG_FILE"
        apt clean 2>>"$LOG_FILE" || echo "APT clean failed." >> "$LOG_FILE"
    fi
    apt update 2>>"$LOG_FILE" || handle_failure "update"
    apt upgrade -y 2>>"$LOG_FILE" || handle_failure "upgrade"
    apt install -y raspberrypi-kernel=1:6.6.51+rpt-rpi-2712 raspberrypi-bootloader 2>>"$LOG_FILE" || echo "Kernel/bootloader install failed." >> "$LOG_FILE"
    update-initramfs -u -k all 2>>"$LOG_FILE" || update-initramfs -c -k $(uname -r) 2>>"$LOG_FILE" || echo "Initramfs update failed." >> "$LOG_FILE"
    mark_step_complete "update_upgrade"
    CHANGES_MADE=true
fi

# Install dependencies
if ! is_step_complete "install_dependencies"; then
    apt install -y git lsb-release i2c-tools 2>>"$LOG_FILE"
    mark_step_complete "install_dependencies"
    CHANGES_MADE=true
fi

# Install RetroPie
if ! is_step_complete "clone_retropie"; then
    cd /opt || handle_failure "change_directory"
    if [ ! -d "/opt/RetroPie-Setup" ]; then
        git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git || handle_failure "clone_retropie"
    fi
    mark_step_complete "clone_retropie"
    CHANGES_MADE=true
fi

if ! is_step_complete "setup_retropie"; then
    cd /opt/RetroPie-Setup || handle_failure "change_directory_retropie"
    chmod +x /opt/RetroPie-Setup/retropie_packages.sh || handle_failure "chmod_retropie_packages"

    # Break down each retropie_packages.sh command into its own step
    if ! is_step_complete "install_retroarch"; then
        /opt/RetroPie-Setup/retropie_packages.sh retroarch || handle_failure "install_retroarch"
        mark_step_complete "install_retroarch"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_emulationstation"; then
        /opt/RetroPie-Setup/retropie_packages.sh emulationstation || handle_failure "install_emulationstation"
        mark_step_complete "install_emulationstation"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_retropiemenu"; then
        /opt/RetroPie-Setup/retropie_packages.sh retropiemenu || handle_failure "install_retropiemenu"
        mark_step_complete "install_retropiemenu"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_runcommand"; then
        /opt/RetroPie-Setup/retropie_packages.sh runcommand || handle_failure "install_runcommand"
        mark_step_complete "install_runcommand"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_samba_depends"; then
        /opt/RetroPie-Setup/retropie_packages.sh samba depends || handle_failure "install_samba_depends"
        mark_step_complete "install_samba_depends"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_samba_shares"; then
        /opt/RetroPie-Setup/retropie_packages.sh samba install_shares || handle_failure "install_samba_shares"
        mark_step_complete "install_samba_shares"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_splashscreen_default"; then
        /opt/RetroPie-Setup/retropie_packages.sh splashscreen default || handle_failure "install_splashscreen_default"
        mark_step_complete "install_splashscreen_default"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "enable_splashscreen"; then
        /opt/RetroPie-Setup/retropie_packages.sh splashscreen enable || handle_failure "enable_splashscreen"
        mark_step_complete "enable_splashscreen"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_bashwelcometweak"; then
        /opt/RetroPie-Setup/retropie_packages.sh bashwelcometweak || handle_failure "install_bashwelcometweak"
        mark_step_complete "install_bashwelcometweak"
        CHANGES_MADE=true
    fi

    if ! is_step_complete "install_joy2key"; then
        /opt/RetroPie-Setup/retropie_packages.sh joy2key || handle_failure "install_joy2key"
        mark_step_complete "install_joy2key"
        CHANGES_MADE=true
    fi

    # Enable autostart for EmulationStation
    if ! is_step_complete "enable_autostart"; then
        /opt/RetroPie-Setup/retropie_packages.sh autostart enable || handle_failure "enable_autostart"

        # Update the autostart.sh script to wait for all processes running /usr/local/bin/install-retropie.sh to end
        sed -i '3i\    sleep 3\n    while pgrep -f "/usr/local/bin/install-retropie.sh" > /dev/null; do\n      sleep 5\n    done' /etc/profile.d/10-retropie.sh

        mark_step_complete "enable_autostart"
        reboot
    fi

    mark_step_complete "setup_retropie"
    CHANGES_MADE=true
fi

# Install RetroPie cores
# Load cores from configuration file
CORES=$(grep -oP '^\s*"[^"]+"(?=\s*#|$)' /boot/firmware/retropie.conf | tr -d '"')

for CORE in $CORES; do
    if ! is_step_complete "install_$CORE"; then
        /opt/RetroPie-Setup/retropie_packages.sh "$CORE" || handle_failure "install_$CORE"
        mark_step_complete "install_$CORE"
        CHANGES_MADE=true
    fi
done

# Reboot if changes made
if [ "$CHANGES_MADE" = true ]; then
    echo "Installation complete. Rebooting..." >> "$LOG_FILE"
    reboot
fi
