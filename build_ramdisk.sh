#!/bin/sh

mkdir -p _install/{dev,mnt,proc,sys,tmp,root,var,etc/init.d,sys/kernel/debug}

# file /init
cat >_install/init <<'EOF'
#!/bin/sh

/bin/mount -t devtmpfs devtmpfs /dev
/bin/mount -t proc proc /proc
/bin/mount -t sysfs sysfs /sys
/bin/mount -t debugfs none /sys/kernel/debug
exec 0</dev/console 1>/dev/console 2>/dev/console
exec /sbin/init "$@"
EOF

chmod +x _install/init

# file /etc/init.d/rcS
cat >_install/etc/init.d/rcS <<'EOF'
#!/bin/sh

/bin/mount -a
EOF

chmod +x _install/etc/init.d/rcS

# file /etc/fstab
cat >_install/etc/fstab <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
EOF

# build initramfs
cd _install
find ./* | cpio -H newc -o >../rootfs.cpio
cd ..

echo "initramfs built, file name: rootfs.cpio"
