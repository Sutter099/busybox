#!/bin/bash
# file: build_initramfs.sh

set -euo pipefail # -e: exit immediately if failed；-u: fail if undefined；-o pipefail: any command in a pipeline fails, the whole pipeline fails.

REPO_URL="git://git.busybox.net/busybox" # BusyBox
REPO_DIR="busybox_src"                   # local directory
BUSYBOX_VERSION="1_37_0"                 # git tag
INSTALL_DIR="${REPO_DIR}/_install"

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

clone_or_update_repo() {
    log_info "checkout BusyBox repo..."
    if [ -d "$REPO_DIR" ]; then
        log_info "repo already exists"
        log_info "try reset '$REPO_DIR' to '${BUSYBOX_VERSION}'..."
        if ! (cd "$REPO_DIR" && git reset --hard "${BUSYBOX_VERSION}" 2>&1); then
            log_warn "git reset --hard failed, delete and re-clone" && \
            rm -rf "$REPO_DIR" && \
            git clone "$REPO_URL" "$REPO_DIR" && \
            (cd "$REPO_DIR" && git checkout "$BUSYBOX_VERSION") || \
            log_error "re-clone and checkout failed!"
        fi
        log_info "repo already checkout"
    else
        log_info "clone to $REPO_DIR..."
        git clone "$REPO_URL" "$REPO_DIR" || log_error "Git clone failed"
    fi

    # final check
    (cd "$REPO_DIR" && git checkout "$BUSYBOX_VERSION") || log_error "Git checkout $BUSYBOX_VERSION failed"
    log_info "repo ready"
}

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


build_busybox() {
    log_info "start building BusyBox..."
    
    (
        cd "$REPO_DIR" || log_error "cannot cd $REPO_DIR"

        log_info "generate default config..."
        make -j "$(nproc)" defconfig || log_error "make defconfig failed"

        set_busybox_config_option "CONFIG_STATIC" "enable"
        # set_busybox_config_option "CONFIG_SHARED" "disable"
        set_busybox_config_option "CONFIG_TC" "disable"

        log_info "running make oldconfig..."
        make oldconfig || log_error "make oldconfig failed!"

        log_info "building BusyBox..."
        make -j "$(nproc)" || log_error "BusyBox build failed"

        log_info "install to: ($INSTALL_DIR)..."
        rm -rf "$INSTALL_DIR"
        make install || log_error "BusyBox install failed!"
    ) || log_error "BusyBox build failed!"
    log_info "BusyBox build complete"
}

generate_initramfs() {
    log_info "start building initramfs..."
    log_info "creating root directories..."
    for dir in dev proc sys tmp etc/init.d var usr/bin usr/sbin; do
        mkdir -p "$INSTALL_DIR/$dir" || log_error "mkdir $INSTALL_DIR/$dir failed"
    done

    log_info "create /init..."
    cat >"${INSTALL_DIR}/init" <<'EOF'
#!/bin/sh
# Mount essential filesystems
/bin/mount -t devtmpfs devtmpfs /dev
/bin/mount -t proc proc /proc
/bin/mount -t sysfs sysfs /sys
/bin/mount -t debugfs none /sys/kernel/debug
# Redirect console I/O
exec 0</dev/console 1>/dev/console 2>/dev/console
# Execute BusyBox's init
# BusyBox's init will then start other services or drop to a shell
exec /sbin/init "$@"
EOF
    chmod +x "${INSTALL_DIR}/init" || log_error "chmod /init failed"

    log_info "create /etc/init.d/rcS..."
    cat >"${INSTALL_DIR}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
# Mount all filesystems listed in /etc/fstab
/bin/mount -a
# Example: Drop to a shell if something goes wrong
# run_busybox_command sh
EOF
    chmod +x "${INSTALL_DIR}/etc/init.d/rcS" || log_error "chmod /etc/init.d/rcS failed"

    log_info "create /etc/fstab..."
    cat >"${INSTALL_DIR}/etc/fstab" <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
# Example:
# /dev/sda1       /               ext4    defaults        0 1
EOF

    log_info "create rootfs.cpio..."
    cd "${INSTALL_DIR}" || log_error "cannot cd ${INSTALL_DIR}"
    find . -print0 | cpio --null -ov --format=newc > "../rootfs.cpio" || log_error "create rootfs.cpio failed"
    cd ..
    log_info "Initramfs build finished, file name: rootfs.cpio"
    log_info "size: $(du -h "rootfs.cpio" | cut -f1)"
}

main() {
    log_info "start Initramfs building..."

    clone_or_update_repo

    build_busybox

    generate_initramfs

    log_info "all steps finished!"
}

main
