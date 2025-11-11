#!/bin/bash
#
# osc-kata-addons-install.sh
# Install addon artifacts (kernel/initrd) from container images
# Reuses functions from lib.sh
#

set -e

# Source the shared library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

#######################################
# Update provider-specific configuration file
# Arguments:
#   $1: provider name (se, tdx, snp, etc.)
#   $2: kernel path (empty if not installed)
#   $3: initrd path (empty if not installed)
# Returns:
#   0 on success
#######################################
update_provider_config() {
    local provider="$1"
    local kernel_path="$2"
    local initrd_path="$3"
    
    if [ -z "$provider" ]; then
        echo "No provider specified, skipping config update"
        return 0
    fi
    
    # Construct provider-specific config filename
    local config_file="/etc/kata-containers/kata-${provider}/configuration.toml"
    
    if [ ! -f "$config_file" ]; then
        echo "Warning: Configuration file not found: $config_file"
        return 1
    fi
    
    echo "Updating configuration: $config_file"
    
    # Backup config
    cp "$config_file" "${config_file}.backup-$(date +%s)"
    
    # Update kernel if provided
    if [ -n "$kernel_path" ]; then
        sed -i "s|^\(kernel[[:space:]]*=[[:space:]]*\)\".*\"|\1\"$kernel_path\"|g" "$config_file"
        echo "  Updated kernel: $kernel_path"
    fi
    
    # Update initrd if provided
    if [ -n "$initrd_path" ]; then
        # Comment out image line (mutually exclusive with initrd)
        sed -i 's|^\(image[[:space:]]*=\)|# \1|g' "$config_file"
        
        # Update or add initrd line
        if grep -q "^initrd[[:space:]]*=" "$config_file"; then
            sed -i "s|^\(initrd[[:space:]]*=[[:space:]]*\)\".*\"|\1\"$initrd_path\"|g" "$config_file"
        else
            # Add after commented image line or kernel line
            sed -i "/^# image[[:space:]]*=/a initrd = \"$initrd_path\"" "$config_file"
            if ! grep -q "^initrd[[:space:]]*=" "$config_file"; then
                sed -i "/^kernel[[:space:]]*=/a initrd = \"$initrd_path\"" "$config_file"
            fi
        fi
        echo "  Updated initrd: $initrd_path"
    fi

    return 0
}

#######################################
# Install addon artifacts
# Reads from environment variables
# Returns:
#   0 on success
#######################################
install_addons() {
    local addon_image="${ADDON_IMAGE:-}"
    
    if [ -z "$addon_image" ]; then
        echo "No addon image configured"
        return 0
    fi
    
    echo "Installing addon artifacts from: $addon_image"
    
    local kernel_src="${ADDON_KERNEL_PATH:-}"
    local initrd_src="${ADDON_INITRD_PATH:-}"
    local provider="${ADDON_PROVIDER:-}"
    local version="${ADDON_VERSION:-unknown}"
    
    # Standard installation directory
    local install_dir="/etc/kata-containers"
    local temp_dir="/tmp/kata-addons-$$"
    local auth_file="/tmp/regauth/auth.json"
    
    mkdir -p "$install_dir"
    mkdir -p "$temp_dir"
    
    local kernel_installed=""
    local initrd_installed=""
    
    # Extract and install kernel
    if [ -n "$kernel_src" ]; then
        echo "Extracting kernel from: $kernel_src"
        
        # Reuse extract_container_image from lib.sh
        if extract_container_image "$addon_image" "$kernel_src" "$temp_dir" "$auth_file"; then
            local kernel_file=$(basename "$kernel_src")
            if [ -f "$temp_dir/$kernel_file" ]; then
                kernel_installed="$install_dir/$kernel_file"
                cp "$temp_dir/$kernel_file" "$kernel_installed"
                chmod 644 "$kernel_installed"
                echo "Kernel installed: $kernel_installed"
            fi
        fi
    fi
    
    # Extract and install initrd
    if [ -n "$initrd_src" ]; then
        echo "Extracting initrd from: $initrd_src"
        
        # Reuse extract_container_image from lib.sh
        if extract_container_image "$addon_image" "$initrd_src" "$temp_dir" "$auth_file"; then
            local initrd_file=$(basename "$initrd_src")
            if [ -f "$temp_dir/$initrd_file" ]; then
                initrd_installed="$install_dir/$initrd_file"
                cp "$temp_dir/$initrd_file" "$initrd_installed"
                chmod 644 "$initrd_installed"
                echo "Initrd installed: $initrd_installed"
            fi
        fi
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Update configuration
    if [ -n "$kernel_installed" ] || [ -n "$initrd_installed" ]; then
        update_provider_config "$provider" "$kernel_installed" "$initrd_installed"
    fi
    
    # Store version
    echo "$version" > "$install_dir/.addon-version"
    
    echo "Addon installation completed"
    return 0
}

#######################################
# Upgrade addon artifacts
# Returns:
#   0 on success
#######################################
upgrade_addons() {
    local version_file="/usr/share/kata-containers/.addon-version"
    local current_version="none"
    local new_version="${ADDON_VERSION:-}"
    
    [ -f "$version_file" ] && current_version=$(cat "$version_file")
    
    if [ "$current_version" != "$new_version" ]; then
        echo "Upgrading addons: $current_version -> $new_version"
        install_addons
    else
        echo "Addons already at version: $current_version"
    fi
    
    return 0
}

#######################################
# Uninstall addon artifacts
# Returns:
#   0 on success
#######################################
uninstall_addons() {
    local install_dir="/etc/kata-containers"
    local version_file="$install_dir/.addon-version"
    
    if [ ! -f "$version_file" ]; then
        echo "No addons to uninstall"
        return 0
    fi
    
    echo "Uninstalling addon artifacts"
    
    local kernel_src="${ADDON_KERNEL_PATH:-}"
    local initrd_src="${ADDON_INITRD_PATH:-}"
    local provider="${ADDON_PROVIDER:-}"
    
    # Remove installed artifacts
    [ -n "$kernel_src" ] && rm -f "$install_dir/$(basename "$kernel_src")"
    [ -n "$initrd_src" ] && rm -f "$install_dir/$(basename "$initrd_src")"
    rm -f "$version_file"
    
    # Restore config backup
    if [ -n "$provider" ]; then
        local config_file="/etc/kata-containers/kata-${provider}/configuration.toml"
        local backup=$(ls -t "${config_file}.backup-"* 2>/dev/null | head -1)
        [ -n "$backup" ] && [ -f "$backup" ] && cp "$backup" "$config_file"
    fi
    
    echo "Addon artifacts uninstalled"
    return 0
}

# Main execution
action=${1:-install}

case "$action" in
    install)
        install_addons
        ;;
    upgrade)
        upgrade_addons
        ;;
    uninstall)
        uninstall_addons
        ;;
    *)
        echo "Usage: $0 {install|upgrade|uninstall}"
        exit 1
        ;;
esac
