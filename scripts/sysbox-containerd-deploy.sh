#!/bin/bash

#
# Sysbox deployment script for containerd (RKE2/K3s)
# Based on sysbox-deploy-k8s.sh but for containerd instead of CRI-O
#

set -o errexit
set -o pipefail
set -o nounset

# Sysbox edition
sysbox_edition="Sysbox"

# Artifact locations (inside container)
sysbox_artifacts="/opt/sysbox"

# Host mount points
host_systemd="/mnt/host/lib/systemd/system"
host_sysctl="/mnt/host/lib/sysctl.d"
host_bin="/mnt/host/usr/bin"
host_lib_mod="/mnt/host/usr/lib/modules-load.d"
host_local_bin="/mnt/host/usr/local/bin"
host_etc="/mnt/host/etc"
host_os_release="/mnt/host/os-release"
host_run="/mnt/host/run"
host_var_lib="/mnt/host/var/lib"
host_var_lib_sysbox_deploy="${host_var_lib}/sysbox-deploy-k8s"

# Subid configuration
subid_user="containers"
subid_alloc_min_start=100000
subid_alloc_min_range=268435456
subuid_file="${host_etc}/subuid"
subgid_file="${host_etc}/subgid"

function die() {
    msg="$*"
    echo "ERROR: $msg" >&2
    exit 1
}

function get_host_distro() {
    local distro_name=$(grep -w "^ID" "$host_os_release" | cut -d "=" -f2)
    local version_id=$(grep -w "^VERSION_ID" "$host_os_release" | cut -d "=" -f2 | tr -d '"')
    echo "${distro_name}-${version_id}"
}

function get_host_kernel() {
    uname -r
}

function version_compare() {
    if [[ $1 == $2 ]]; then
        return 0
    fi

    local IFS='.|-'
    local i ver1=($1) ver2=($2)

    for ((i = ${#ver1[@]}; i < ${#ver2[@]}; i++)); do
        ver1[i]=0
    done

    for ((i = 0; i < ${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done

    return 0
}

function semver_ge() {
    version_compare $1 $2
    if [ "$?" -ne "2" ]; then
        return 0
    else
        return 1
    fi
}

function semver_lt() {
    version_compare $1 $2
    if [ "$?" -eq "2" ]; then
        return 0
    else
        return 1
    fi
}

function add_label_to_node() {
    local label=$1
    echo "Adding K8s label \"$label\" to node ..."
    kubectl label node "$NODE_NAME" --overwrite "${label}"
}

function rm_label_from_node() {
    local label=$1
    echo "Removing K8s label \"$label\" from node ..."
    kubectl label node "$NODE_NAME" "${label}-" || true
}

function add_taint_to_node() {
    local taint=$1
    echo "Adding K8s taint \"$taint\" to node ..."
    kubectl taint nodes "$NODE_NAME" "$taint" --overwrite=true
}

function rm_taint_from_node() {
    taint=$1
    echo "Removing K8s taint \"$taint\" from node ..."
    kubectl taint nodes "$NODE_NAME" "$taint"- || true
}

function check_procfs_mount_userns() {
    # Attempt to mount procfs from a user-namespace
    if unshare -U -p -f --mount-proc -r cat /dev/null 2>/dev/null; then
        return 0
    fi

    # Try unmounting cmdline if it's blocking
    if mount | grep -q "cmdline" && umount /proc/cmdline 2>/dev/null; then
        if unshare -U -p -f --mount-proc -r cat /dev/null 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

function install_package_deps() {
    echo "Installing package dependencies on host..."

    # Use nsenter to run apt on the host
    nsenter -t 1 -m -u -i -n -p -- bash -c '
        dpkg --configure -a 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq rsync fuse3 iptables
    '
}

function config_subid_range() {
    local subid_file=$1
    local subid_size=$2

    # If file doesn't exist or is empty, create it
    if [ ! -f "$subid_file" ] || [ ! -s "$subid_file" ]; then
        echo "${subid_user}:${subid_alloc_min_start}:${subid_size}" > "${subid_file}"
        return
    fi

    # Check if containers user already has a large enough range
    if grep -q "^${subid_user}:" "$subid_file"; then
        local existing_size=$(grep "^${subid_user}:" "$subid_file" | cut -d: -f3)
        if [ "$existing_size" -ge "$subid_size" ]; then
            echo "Subid range for ${subid_user} already configured."
            return
        fi
    fi

    # Add the subid range
    echo "${subid_user}:${subid_alloc_min_start}:${subid_size}" >> "${subid_file}"
}

function config_subids() {
    echo "Configuring subuid/subgid..."
    config_subid_range "$subuid_file" "$subid_alloc_min_range"
    config_subid_range "$subgid_file" "$subid_alloc_min_range"
}

function copy_sysbox_to_host() {
    echo "Copying sysbox binaries to host..."
    cp "${sysbox_artifacts}/bin/generic/sysbox-mgr" "${host_bin}/sysbox-mgr"
    cp "${sysbox_artifacts}/bin/generic/sysbox-fs" "${host_bin}/sysbox-fs"
    cp "${sysbox_artifacts}/bin/generic/sysbox-runc" "${host_bin}/sysbox-runc"
    chmod +x "${host_bin}/sysbox-mgr" "${host_bin}/sysbox-fs" "${host_bin}/sysbox-runc"
}

function copy_sysbox_env_config_to_host() {
    echo "Copying sysbox sysctl and module configs to host..."
    mkdir -p "${host_sysctl}"
    mkdir -p "${host_lib_mod}"
    cp "${sysbox_artifacts}/systemd/99-sysbox-sysctl.conf" "${host_sysctl}/99-sysbox-sysctl.conf"
    cp "${sysbox_artifacts}/systemd/50-sysbox-mod.conf" "${host_lib_mod}/50-sysbox-mod.conf"
}

function apply_sysbox_env_config() {
    echo "Applying sysbox sysctl settings..."
    # Run sysctl on the host
    nsenter -t 1 -m -u -i -n -p -- sysctl -p /lib/sysctl.d/99-sysbox-sysctl.conf

    echo "Loading kernel modules..."
    nsenter -t 1 -m -u -i -n -p -- modprobe configfs || true
}

function host_systemctl() {
    # Run systemctl on the host via nsenter
    nsenter -t 1 -m -u -i -n -p -- systemctl "$@"
}

function copy_sysbox_systemd_to_host() {
    echo "Copying sysbox systemd units to host..."
    cp "${sysbox_artifacts}/systemd/sysbox.service" "${host_systemd}/sysbox.service"
    cp "${sysbox_artifacts}/systemd/sysbox-mgr.service" "${host_systemd}/sysbox-mgr.service"
    cp "${sysbox_artifacts}/systemd/sysbox-fs.service" "${host_systemd}/sysbox-fs.service"
    host_systemctl daemon-reload
    host_systemctl enable sysbox.service sysbox-mgr.service sysbox-fs.service
}

function start_sysbox() {
    echo "Starting sysbox services..."
    host_systemctl restart sysbox
    sleep 2
    if ! host_systemctl is-active --quiet sysbox; then
        echo "Warning: sysbox.service not active, trying individual services..."
        host_systemctl restart sysbox-mgr
        sleep 2
        host_systemctl restart sysbox-fs
    fi

    # Verify services are running
    echo "Verifying sysbox services..."
    host_systemctl status sysbox-mgr --no-pager | head -5
    host_systemctl status sysbox-fs --no-pager | head -5
}

function stop_sysbox() {
    echo "Stopping sysbox services..."
    host_systemctl stop sysbox || true
    host_systemctl stop sysbox-fs || true
    host_systemctl stop sysbox-mgr || true
}

function verify_sysbox_runc() {
    echo "Verifying sysbox-runc features command (required for containerd)..."
    if ! nsenter -t 1 -m -u -i -n -p -- /usr/bin/sysbox-runc features > /dev/null 2>&1; then
        die "sysbox-runc features command failed! This binary may not be compatible with containerd."
    fi
    echo "sysbox-runc features command works!"

    # Log sysbox-mgr capabilities
    sleep 2
    echo "Sysbox-mgr capabilities:"
    nsenter -t 1 -m -u -i -n -p -- journalctl -u sysbox-mgr --no-pager -n 20 | grep -E "(Shiftfs|ID-mapped|Operating)" | tail -5 || true
}

function install_sysbox() {
    echo "Installing $sysbox_edition for containerd..."

    # Stop existing sysbox if running
    stop_sysbox

    # Copy configs and binaries
    copy_sysbox_env_config_to_host
    apply_sysbox_env_config
    copy_sysbox_systemd_to_host
    copy_sysbox_to_host

    # Start sysbox
    start_sysbox

    # Verify
    verify_sysbox_runc
}

function install() {
    local k8s_taints="sysbox-runtime=not-running:NoSchedule"

    mkdir -p "${host_var_lib_sysbox_deploy}"

    echo "=== Sysbox Containerd Deploy ==="
    echo "Node: $NODE_NAME"
    echo "Distro: $(get_host_distro)"
    echo "Kernel: $(get_host_kernel)"
    echo ""

    # Add taint to prevent scheduling during install
    add_taint_to_node "${k8s_taints}"
    add_label_to_node "sysbox-runtime=installing"

    # Check if node supports user namespace procfs mount
    if ! check_procfs_mount_userns; then
        die "Sysbox unmet requirement: node is unable to mount procfs from within unprivileged user-namespaces."
    fi
    echo "User namespace procfs mount check passed."

    # Install dependencies
    install_package_deps

    # Configure subuid/subgid
    config_subids

    # Install sysbox
    install_sysbox

    # Mark installation complete
    echo "yes" > "${host_var_lib_sysbox_deploy}/sysbox_installed"
    echo "${SYSBOX_VERSION:-0.6.7}" > "${host_var_lib_sysbox_deploy}/sysbox_installed_version"
    uname -r > "${host_var_lib_sysbox_deploy}/os_kernel_release"

    # Update node labels
    add_label_to_node "sysbox-runtime=running"
    rm_taint_from_node "${k8s_taints}"

    echo ""
    echo "=== $sysbox_edition installation complete! ==="
    echo "RuntimeClass 'sysbox-runc' is now available for pods."
    echo ""
    echo "To use sysbox, add to your pod spec:"
    echo "  runtimeClassName: sysbox-runc"
    echo "  hostUsers: false"
    echo ""

    # Keep the pod running
    echo "Sleeping indefinitely..."
    sleep infinity
}

function cleanup() {
    local k8s_taints="sysbox-runtime=not-running:NoSchedule"

    add_taint_to_node "${k8s_taints}"
    add_label_to_node "sysbox-runtime=removing"

    if [ -f "${host_var_lib_sysbox_deploy}/sysbox_installed" ]; then
        echo "Removing sysbox..."
        stop_sysbox

        # Remove binaries
        rm -f "${host_bin}/sysbox-mgr"
        rm -f "${host_bin}/sysbox-fs"
        rm -f "${host_bin}/sysbox-runc"

        # Remove systemd units
        host_systemctl disable sysbox.service sysbox-mgr.service sysbox-fs.service || true
        rm -f "${host_systemd}/sysbox.service"
        rm -f "${host_systemd}/sysbox-mgr.service"
        rm -f "${host_systemd}/sysbox-fs.service"
        host_systemctl daemon-reload

        # Remove configs
        rm -f "${host_sysctl}/99-sysbox-sysctl.conf"
        rm -f "${host_lib_mod}/50-sysbox-mod.conf"

        rm -rf "${host_var_lib_sysbox_deploy}"
    fi

    rm_label_from_node "sysbox-runtime"
    rm_taint_from_node "${k8s_taints}"

    echo "Sysbox removal complete."
}

function main() {
    euid=$(id -u)
    if [[ $euid -ne 0 ]]; then
        die "This script must be run as root"
    fi

    local action=${1:-install}

    case "$action" in
        install)
            install
            ;;
        cleanup)
            cleanup
            ;;
        *)
            echo "Usage: $0 [install|cleanup]"
            exit 1
            ;;
    esac
}

main "$@"
