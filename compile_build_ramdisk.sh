#!/bin/bash
# file: build_initramfs.sh

set -euo pipefail # -e: exit immediately if failed；-u: fail if undefined；-o pipefail: any command in a pipeline fails, the whole pipeline fails.

REPO_URL="git://git.busybox.net/busybox" # BusyBox
REPO_DIR="busybox_src"                   # local directory
BUSYBOX_VERSION="master"                 # git tag
INSTALL_DIR="$(pwd)/${REPO_DIR}/_install" # This is the final rootfs staging dir

EBPFTOOLS_REPO_URL="https://github.com/Sutter099/ebpf-tools.git"
EBPFTOOLS_REPO_DIR="ebpf_tools_src"                   # local directory
EBPFTOOLS_VERSION="example/trace_slab_alloc"                 # git tag
EBPFTOOLS_INSTALL_DIR="$(pwd)/${REPO_DIR}/_install" # Adjusted for clarity

log_info() {
    echo_color green "[INFO] $*"
}

log_warn() {
    echo_color yellow "[WARN] $*"
}

log_error() {
    echo_color red "[ERROR] $*" >&2
    exit 1
}

echo_color() {
    local color_code
    case "$1" in
        red)    color_code="\033[0;31m";;
        green)  color_code="\033[0;32m";;
        yellow) color_code="\033[0;33m";;
        blue)   color_code="\033[0;34m";;
        *)      color_code="\033[0m";; # Default to no color
    esac
    echo -e "${color_code}${*:2}\033[0m"
}

# --- Repository Operations ---
clone_or_update_repo_x() {
    local repo_url="$1"
    local repo_dir="$2"
    local repo_tag="$3"
    local desc="$4" # New argument for description

    log_info "Processing $desc repo..."
    if [ -d "$repo_dir" ]; then
        log_info "'$desc' repo already exists at '$repo_dir'"
        log_info "Attempting to reset '$repo_dir' to '${repo_tag}'..."
        if ! (cd "$repo_dir" && git reset --hard "${repo_tag}" && git clean -fxd 2>&1); then
            log_warn "Git reset --hard and clean failed for '$desc', deleting and re-cloning..."
            rm -rf "$repo_dir" || log_error "Failed to remove existing '$repo_dir'"
            log_info "Cloning '$repo_url' into '$repo_dir'..."
            git clone "$repo_url" "$repo_dir" || log_error "Git clone failed for '$desc'"
            (cd "$repo_dir" && git submodule update --init --recursive) || log_error "Git submodule update failed for '$desc'"
        fi
        log_info "'$desc' repo now set to '$repo_tag'"
    else
        log_info "cloning '$repo_url' into '$repo_dir'..."
        git clone "$repo_url" "$repo_dir" || log_error "Git clone failed for '$desc'"
        (cd "$repo_dir" && git submodule update --init --recursive) || log_error "Git submodule update failed for '$desc'"
        log_info "'$desc' repo cloned."
    fi

    # Final checkout to ensure the correct tag/branch
    (cd "$repo_dir" && git checkout "$repo_tag") || log_error "Git checkout $repo_tag failed for '$desc'"
    log_info "'$desc' repo is ready at '$repo_tag'."
}

clone_all_repos() {
    log_info "Starting repository cloning/updating..."
    clone_or_update_repo_x "$REPO_URL" "$REPO_DIR" "$BUSYBOX_VERSION" "BusyBox"
    clone_or_update_repo_x "$EBPFTOOLS_REPO_URL" "$EBPFTOOLS_REPO_DIR" "$EBPFTOOLS_VERSION" "ebpf-tools"
    log_info "All repositories are cloned/updated."
}

# --- Configuration Helpers ---
# function: set BusyBox config
# arg 1: config_name
# arg 2: action (enable or disable)
set_busybox_config_option() {
    local config_name="$1"
    local action="$2"
    local new_line
    local config_name_escaped

    case "$action" in
        enable)
            new_line="${config_name}=y"
            ;;
        disable)
            new_line="# ${config_name} is not set"
            ;;
        *)
            log_error "invalid action: '$action'. only 'enable' or 'disable'"
            ;;
    esac

    config_name_escaped=$(echo "$config_name" | sed 's/\./\\./g')

    if grep -qE "^$(echo "$new_line" | sed 's/\./\\./g')$" .config; then
        log_info "$config_name already desired: ('$action')"
        return 0
    fi

    sed -i -E "/^(${config_name_escaped}=y|${config_name_escaped}=n|# ${config_name_escaped} is not set)$/d" .config

    echo "$new_line" >> .config
}

# --- Build Functions ---
build_ebpf_tools() {
    log_info "start building ebpf-tools..."

    (
        cd "$EBPFTOOLS_REPO_DIR" || log_error "cannot cd $EBPFTOOLS_REPO_DIR"

        log_info "building ebpf-tools..."
        make -j "$(nproc)" || log_error "ebpf-tools build failed!"

        log_info "installing ebpf-tools to: ($INSTALL_DIR)/usr/local/bin..."
        mkdir -p "${INSTALL_DIR}/usr/local/bin" # Ensure target directory exists
        make install DESTDIR="${INSTALL_DIR}" || log_error "ebpf-tools install failed!"
    ) || log_error "ebpf-tools build process exited with error!"
    log_info "ebpf-tools build and install complete."
}


build_busybox() {
    log_info "start building BusyBox..."

    (
        cd "$REPO_DIR" || log_error "cannot cd $REPO_DIR"

        log_info "generating default config for BusyBox..."
        make defconfig || log_error "make defconfig failed for BusyBox"

        set_busybox_config_option "CONFIG_STATIC" "enable"
        # set_busybox_config_option "CONFIG_SHARED" "disable"
        set_busybox_config_option "CONFIG_TC" "disable"

        log_info "running make oldconfig for BusyBox..."
        make oldconfig || log_error "make oldconfig failed for BusyBox!"

        log_info "building BusyBox..."
        make -j "$(nproc)" || log_error "BusyBox build failed!"

        log_info "installing BusyBox to: ($INSTALL_DIR)..."
        # The BusyBox Makefile's install target is designed to populate a rootfs.
        # We ensure the INSTALL_DIR is clean before populating.
        rm -rf "$INSTALL_DIR" # Clear the previous install target
        make install || log_error "BusyBox install failed!"
    ) || log_error "BusyBox build process exited with error!"
    log_info "BusyBox build and install complete."
}

build_all() {
    log_info "Starting all build processes..."
    build_busybox
    build_ebpf_tools
    log_info "All required components built."
}

# --- Packaging Function ---
generate_initramfs() {
    log_info "start generating initramfs (rootfs.cpio)..."

    if [ ! -d "$INSTALL_DIR" ] || [ -z "$(ls -A "$INSTALL_DIR")" ]; then
        log_error "Install directory ($INSTALL_DIR) is empty or does not exist. Please run 'build' first."
    fi

    log_info "creating essential root directories inside staged rootfs..."
    # Ensure standard directories exist for a basic Linux rootfs
    for dir in dev proc sys tmp etc/init.d var usr/bin usr/sbin mnt lib lib64; do # Added lib and lib64
        mkdir -p "$INSTALL_DIR/$dir" || log_error "mkdir $INSTALL_DIR/$dir failed"
    done

    # BusyBox install should typically create /sbin, so checking for it
    if [ ! -f "${INSTALL_DIR}/sbin/init" ] && [ -f "${INSTALL_DIR}/bin/busybox" ]; then
        log_warn "BusyBox's /sbin/init not found, linking /bin/busybox to /sbin/init."
        ln -sf /bin/busybox "${INSTALL_DIR}/sbin/init"
    elif [ ! -f "${INSTALL_DIR}/sbin/init" ]; then
        log_error "BusyBox's /sbin/init not found and /bin/busybox is also missing. BusyBox build likely failed."
    fi

    log_info "creating /init script..."
    cat >"${INSTALL_DIR}/init" <<'EOF'
#!/bin/sh
# Early init script for minimal initramfs
echo "Starting initramfs..."

# Mount essential filesystems
/bin/mount -t devtmpfs devtmpfs /dev
/bin/mount -t proc proc /proc
/bin/mount -t sysfs sysfs /sys
/bin/mount -t debugfs none /sys/kernel/debug 2>/dev/null # debugfs might not be supported or available

# Redirect console I/O
exec 0</dev/console 1>/dev/console 2>/dev/console

echo "Initramfs setup complete. Starting BusyBox init..."
# Execute BusyBox's init
# BusyBox's init will then start other services or drop to a shell
exec /sbin/init "$@"
# If /sbin/init fails, drop to a shell
echo "Failed to execute /sbin/init. Dropping to a rescue shell."
exec /bin/sh
EOF
    chmod +x "${INSTALL_DIR}/init" || log_error "chmod /init failed"

    log_info "creating /etc/init.d/rcS script..."
    cat >"${INSTALL_DIR}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
echo "Running /etc/init.d/rcS..."
# Mount all filesystems listed in /etc/fstab (if it exists)
if [ -f /etc/fstab ]; then
    /bin/mount -a
fi
EOF
    chmod +x "${INSTALL_DIR}/etc/init.d/rcS" || log_error "chmod /etc/init.d/rcS failed"

    log_info "creating /etc/fstab..."
    cat >"${INSTALL_DIR}/etc/fstab" <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
# /dev/root       /               ext4    defaults        0 1
EOF

    log_info "creating /etc/profile..."
    cat >"${INSTALL_DIR}/etc/profile" <<'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
alias ll='ls -alF'
PS1='\u@initramfs:\w\$ '
EOF
    chmod +x "${INSTALL_DIR}/etc/profile" # Ensure it's executable for some shells/login behavior considerations

    log_info "creating rootfs.cpio from staged rootfs..."
    local cpio_output_file="rootfs.cpio"
    (
        cd "${INSTALL_DIR}" || log_error "cannot cd ${INSTALL_DIR}"
        # Use a temporary file to list files to avoid issues with newly created files during find execution
        find . -print0 > /tmp/rootfs_files.txt || log_error "Failed to list files for cpio"
        cpio --null -ov --format=newc < /tmp/rootfs_files.txt > "../$cpio_output_file" || log_error "create $cpio_output_file failed"
        rm /tmp/rootfs_files.txt # Clean up temporary file
    ) || log_error "Initramfs generation failed!"

    log_info "Initramfs build finished, file name: $cpio_output_file"
    log_info "size: $(du -h "$(pwd)/${REPO_DIR}/$cpio_output_file" | cut -f1)"
}

# --- Clean Function ---
clean_all() {
    log_info "Starting cleanup..."
    log_info "Removing repository directories..."
    (cd $REPO_DIR && make clean) && (cd $EBPFTOOLS_REPO_DIR && make clean) || log_error "Failed to remove repo directories"
    log_info "Removing install directory..."
    rm -rf "$INSTALL_DIR" || log_error "Failed to remove install directory"
    log_info "Removing generated initramfs file (rootfs.cpio)..."
    rm -f rootfs.cpio || log_error "Failed to remove rootfs.cpio"
    log_info "Cleanup complete."
}

# --- Remove Function ---
remove_all() {
    log_info "Removing repository directories..."
    rm -rf "$REPO_DIR" "$EBPFTOOLS_REPO_DIR" || log_error "Failed to remove repo directories"
    log_info "Removing install directory..."
    rm -rf "$INSTALL_DIR" || log_error "Failed to remove install directory"
    log_info "Removing generated initramfs file (rootfs.cpio)..."
    rm -f rootfs.cpio || log_error "Failed to remove rootfs.cpio"
    log_info "Remove complete."
}


# --- Main Logic with Subcommands ---

usage() {
    echo "Usage: $0 <command>"
    echo "Commands:"
    echo "  all                  Clone, build, and package everything (default)."
    echo "  clone                Clone/update all necessary repositories."
    echo "  build                Build BusyBox and ebpf-tools, then install them to the staging directory."
    echo "  gen                  Generate the final initramfs (rootfs.cpio) from the staged directory."
    echo "  clean                Clean built object files."
    echo "  remove               Remove all cloned repositories, build artifacts, and the generated initramfs."
    echo "  help                 Display this help message."
    exit 1
}

main() {
    if [ "$#" -eq 0 ]; then
        log_info "No command provided, running 'all' command by default."
        full_build
        exit 0
    fi

    local cmd="$1"
    shift # Remove the command from the arguments list

    case "$cmd" in
        all)
            full_build
            ;;
        clone)
            clone_all_repos
            ;;
        build)
            build_all
            ;;
        gen)
            generate_initramfs
            ;;
        clean)
            clean_all
            ;;
        remove)
            remove_all
            ;;
        help)
            usage
            ;;
        *)
            log_error "Unknown command: '$cmd'."
            usage
            ;;
    esac
    log_info "Command '$cmd' completed successfully."
}

full_build() {
    log_info "Starting full Initramfs building process (clone, build, package)..."
    clone_all_repos
    build_all
    generate_initramfs
    log_info "Full Initramfs building process finished successfully!"
}

main "$@"
