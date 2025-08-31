#!/bin/bash -e
################################################################################
##  File:  install-retropie.sh
##  Desc:  Installs RetroPie on PiOS Aarch64 for PSPi 6 with CM5 support.
##  Notes: Requires WiFi pre-configured in Raspberry Pi Imager and DPI overlay in /boot/firmware/config.txt.
##  Usage: ./install-retropie.sh [--help] [--dry-run] [--config <config_file>]
##  Updated: Dynamic kernel version detection, robust error handling, user feedback, and log cleanup.
################################################################################

# Display help message
if [ "$1" = "--help" ]; then
    echo "Usage: $0 [--help] [--dry-run] [--config <config_file>]"
    echo "Installs RetroPie on Raspberry Pi OS Aarch64 for PSPi 6 with CM5 support."
    echo "Prerequisites:"
    echo "  - WiFi must be pre-configured in Raspberry Pi Imager."
    echo "  - DPI overlay must be enabled in /boot/firmware/config.txt."
    echo "Options:"
    echo "  --help        Display this help message."
    echo "  --dry-run     Simulate installation without making changes."
    echo "  --config      Specify custom RetroPie configuration file (default: /boot/firmware/retropie.conf)."
    exit 0
fi

# Dry-run mode
DRY_RUN=false
if [ "$1" = "--dry-run" ]; then
    DRY_RUN=true
    echo "Running in dry-run mode. No changes will be made."
fi

# Configuration file
CONFIG_FILE=${2:-/boot/firmware/retropie.conf}
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found."
    exit 1
fi

# Generate log file
LOG_FILE="/var/log/install-pspi6-$(date +%Y%m%d%H%M%S).log" || LOG_FILE="/var/log/install-pspi6-fallback.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Clean up old log files (older than 7 days)
LOG_RETENTION_DAYS=7
find /var/log -name "install-pspi6-*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null

# Progress file
PROGRESS_FILE="/opt/pspi6_installation_progress"
touch "$PROGRESS_FILE" 2>/dev/null || PROGRESS_FILE="/tmp/pspi6_installation_progress"
chmod 666 "$PROGRESS_FILE" 2>/dev/null

# Track changes
CHANGES_MADE=false

# Function to check step completion
is_step_complete() {
    grep -q "$1" "$PROGRESS_FILE" 2>/dev/null
}

# Function to mark step completion
mark_step_complete() {
    if [ "$DRY_RUN" = false ]; then
        echo "$1" >> "$PROGRESS_FILE"
    else
        echo "[Dry-run] Would mark step $1 as complete."
    fi
}

# Function to handle failure
handle_failure() {
    local step=$1
    echo "Step failed: $step. Attempting recovery..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        pkill -f dpkg 2>>"$LOG_FILE" || echo "No dpkg processes to kill." >> "$LOG_FILE"
        pkill -f apt 2>>"$LOG_FILE" || echo "No apt processes to kill." >> "$LOG_FILE"
        rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>>"$LOG_FILE"
        dpkg --configure -a --force-confnew 2>>"$LOG_FILE" || echo "dpkg recovery failed." >> "$LOG_FILE"
        apt install -f -y < /dev/null 2>>"$LOG_FILE" || echo "apt fix failed." >> "$LOG_FILE"
        df -h /boot/firmware >> "$LOG_FILE" 2>/dev/null || echo "No /boot/firmware mounted." >> "$LOG_FILE"
        echo "Run 'sudo apt install --reinstall raspi-firmware raspberrypi-kernel=1:$(uname -r) firmware-brcm80211' if issues persist." | tee -a "$LOG_FILE"
    fi
    echo "Installation failed at step: $step. Please check $LOG_FILE for details." | tee -a "$LOG_FILE"
    echo "Press Enter to reboot or Ctrl+C to exit:" | tee -a "$LOG_FILE"
    read -r
    if [ "$DRY_RUN" = false ]; then
        reboot
    else
        echo "[Dry-run] Would reboot now."
    fi
    exit 1
}

# Verify disk space
REQUIRED_SPACE=1000  # MB
AVAILABLE_SPACE=$(df -m / | awk 'NR==2 {print $4}')
if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    echo "Insufficient disk space on /. Need ${REQUIRED_SPACE}MB, but only ${AVAILABLE_SPACE}MB available." | tee -a "$LOG_FILE"
    exit 1
fi

# Verify aarch64 for CM5
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "Warning: Non-aarch64 ($ARCH). CM5 requires aarch64." | tee -a "$LOG_FILE"
fi

# Fix system date
if ! is_step_complete "fix_system_date"; then
    echo "Setting system date..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        date -s "20250831 12:00:00" 2>>"$LOG_FILE" || echo "Date set failed. Current: $(date)" >> "$LOG_FILE"
        mark_step_complete "fix_system_date"
        CHANGES_MADE=true
    else
        echo "[Dry-run] Would set system date to 2025-08-31 12:00:00."
    fi
fi

# Check and uncompress WiFi module
BRCMFMAC_PATH="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac"
if [ -f "$BRCMFMAC_PATH/brcmfmac.ko.xz" ] && [ ! -f "$BRCMFMAC_PATH/brcmfmac.ko" ]; then
    echo "Uncompressing WiFi module..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        unxz "$BRCMFMAC_PATH/brcmfmac.ko.xz" 2>>"$LOG_FILE" || echo "Failed to uncompress brcmfmac.ko.xz." >> "$LOG_FILE"
        depmod -a 2>>"$LOG_FILE" || echo "depmod failed." >> "$LOG_FILE"
    else
        echo "[Dry-run] Would uncompress $BRCMFMAC_PATH/brcmfmac.ko.xz and run depmod."
    fi
fi
if [ ! -f "$BRCMFMAC_PATH/brcmfmac.ko" ]; then
    echo "Reinstalling WiFi firmware..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        apt update < /dev/null 2>>"$LOG_FILE" && apt install --reinstall firmware-brcm80211 < /dev/null 2>>"$LOG_FILE" || echo "Firmware reinstall failed." >> "$LOG_FILE"
        depmod -a 2>>"$LOG_FILE" || echo "depmod failed." >> "$LOG_FILE"
    else
        echo "[Dry-run] Would reinstall firmware-brcm80211 and run depmod."
    fi
fi
if [ "$DRY_RUN" = false ]; then
    modprobe brcmfmac 2>>"$LOG_FILE" || echo "Failed to load brcmfmac." >> "$LOG_FILE"
else
    echo "[Dry-run] Would load brcmfmac module."
fi

# Check WiFi connectivity
WIFI_RETRIES=3
WIFI_SUCCESS=false
for ((i=1; i<=WIFI_RETRIES; i++)); do
    echo "Checking WiFi (Attempt $i/$WIFI_RETRIES)..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        if ping -c 1 8.8.8.8 > /dev/null 2>&1; then
            WIFI_SUCCESS=true
            break
        fi
    else
        echo "[Dry-run] Would ping 8.8.8.8 to check WiFi."
        WIFI_SUCCESS=true
        break
    fi
    [ "$i" -lt "$WIFI_RETRIES" ] && sleep 10
done
if [ "$WIFI_SUCCESS" != "true" ]; then
    handle_failure "wifi_check"
fi

# Update and upgrade system
if ! is_step_complete "update_upgrade"; then
    echo "Updating and upgrading system..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        if ! mountpoint /boot/firmware >/dev/null 2>&1; then
            echo "No /boot/firmware mounted. Reinstalling raspi-firmware..." | tee -a "$LOG_FILE"
            apt update < /dev/null 2>>"$LOG_FILE" && apt install --reinstall raspi-firmware < /dev/null 2>>"$LOG_FILE" || handle_failure "install_raspi_firmware"
            mount /boot/firmware 2>>"$LOG_FILE" || echo "/boot/firmware mount failed." >> "$LOG_FILE"
        fi
        pkill -f dpkg 2>>"$LOG_FILE" || echo "No dpkg processes to kill." >> "$LOG_FILE"
        pkill -f apt 2>>"$LOG_FILE" || echo "No apt processes to kill." >> "$LOG_FILE"
        rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>>"$LOG_FILE"
        dpkg --configure -a --force-confnew 2>>"$LOG_FILE" || echo "dpkg configure failed." >> "$LOG_FILE"
        apt install -f -y < /dev/null 2>>"$LOG_FILE" || handle_failure "fix_broken"
        df -h /boot/firmware >> "$LOG_FILE" 2>/dev/null || echo "No /boot/firmware mounted." >> "$LOG_FILE"
        if [ "$(df -h /boot/firmware 2>/dev/null | awk 'NR==2 {print $4}' | grep -o '[0-9]\+')" -lt 50 ]; then
            apt purge -y linux-image-[0-5].* linux-headers-[0-5].* 2>>"$LOG_FILE" || echo "No old kernels to purge." >> "$LOG_FILE"
            apt autoremove --purge -y < /dev/null 2>>"$LOG_FILE" || echo "Autoremove failed." >> "$LOG_FILE"
            apt clean < /dev/null 2>>"$LOG_FILE" || echo "APT clean failed." >> "$LOG_FILE"
        fi
        apt update < /dev/null 2>>"$LOG_FILE" || handle_failure "update"
        apt upgrade -y < /dev/null 2>>"$LOG_FILE" || handle_failure "upgrade"
        KERNEL_VERSION=$(uname -r)
        apt install -y raspberrypi-kernel=1:${KERNEL_VERSION} raspberrypi-bootloader < /dev/null 2>>"$LOG_FILE" || {
            echo "Falling back to latest kernel version" >> "$LOG_FILE"
            apt install -y raspberrypi-kernel raspberrypi-bootloader < /dev/null 2>>"$LOG_FILE" || handle_failure "install_kernel"
        }
        update-initramfs -u -k all 2>>"$LOG_FILE" || update-initramfs -c -k $(uname -r) 2>>"$LOG_FILE" || echo "Initramfs update failed." >> "$LOG_FILE"
        mark_step_complete "update_upgrade"
        CHANGES_MADE=true
    else
        echo "[Dry-run] Would update and upgrade system, install kernel $(uname -r), and update initramfs."
    fi
fi

# Install dependencies
if ! is_step_complete "install_dependencies"; then
    echo "Installing dependencies..." | tee -a "$LOG_FILE"
    DEPENDENCIES="git lsb-release i2c-tools dialog"
    for DEP in $DEPENDENCIES; do
        if ! dpkg -l | grep -qw "$DEP"; then
            if [ "$DRY_RUN" = false ]; then
                apt install -y "$DEP" < /dev/null 2>>"$LOG_FILE" || handle_failure "install_$DEP"
            else
                echo "[Dry-run] Would install $DEP."
            fi
        else
            echo "$DEP is already installed." >> "$LOG_FILE"
        fi
    done
    mark_step_complete "install_dependencies"
    CHANGES_MADE=true
fi

# Install RetroPie
if ! is_step_complete "clone_retropie"; then
    echo "Cloning RetroPie-Setup..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        cd /opt || handle_failure "change_directory"
        if [ ! -d "/opt/RetroPie-Setup" ]; then
            git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git || handle_failure "clone_retropie"
        fi
        mark_step_complete "clone_retropie"
        CHANGES_MADE=true
    else
        echo "[Dry-run] Would clone RetroPie-Setup to /opt/RetroPie-Setup."
    fi
fi

# Install RetroPie cores
CORES=$(grep -oP '^\s*"[^"]+"(?=\s*#|$)' "$CONFIG_FILE" | tr -d '"')
for CORE in $CORES; do
    if ! is_step_complete "install_$CORE"; then
        echo "Installing core $CORE..." | tee -a "$LOG_FILE"
        if [ "$CORE" = "gzdoom" ]; then
            if [ "$DRY_RUN" = false ]; then
                apt install -y libzmusic1 < /dev/null 2>>"$LOG_FILE" || echo "Failed to install libzmusic1." >> "$LOG_FILE"
            else
                echo "[Dry-run] Would install libzmusic1 for gzdoom."
            fi
        fi
        if [ "$DRY_RUN" = false ]; then
            /opt/RetroPie-Setup/retropie_packages.sh "$CORE" || handle_failure "install_$CORE"
            mark_step_complete "install_$CORE"
            CHANGES_MADE=true
        else
            echo "[Dry-run] Would install RetroPie core $CORE."
        fi
    fi
done

# Enable splashscreen
if ! is_step_complete "enable_splashscreen"; then
    echo "Enabling splashscreen..." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        if [ -f "/lib/systemd/system/asplashscreen.service" ]; then
            /opt/RetroPie-Setup/retropie_packages.sh splashscreen enable || handle_failure "enable_splashscreen"
            mark_step_complete "enable_splashscreen"
            CHANGES_MADE=true
        else
            echo "Splashscreen service (asplashscreen.service) not found. Skipping enable step." >> "$LOG_FILE"
            mark_step_complete "enable_splashscreen"
            CHANGES_MADE=true
        fi
    else
        echo "[Dry-run] Would enable splashscreen if asplashscreen.service exists."
    fi
fi

# Finalize installation
if [ "$CHANGES_MADE" = true ]; then
    echo "Installation complete. Reboot recommended." | tee -a "$LOG_FILE"
    if [ "$DRY_RUN" = false ]; then
        dialog --msgbox "Installation complete. Press Enter to reboot or Ctrl+C to exit." 10 50
        read -p "Press Enter to reboot or Ctrl+C to exit: "
        reboot
    else
        echo "[Dry-run] Would prompt for reboot."
    fi
else
    echo "No changes made. Installation already complete." | tee -a "$LOG_FILE"
fi
