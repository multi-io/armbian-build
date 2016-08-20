#!/bin/bash
#
# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# This file is a part of tool chain https://github.com/igorpecovnik/lib
#
#
# Create board support packages
#
# Functions:
# create_board_package

create_board_package()
{
	display_alert "Creating board support package" "$BOARD $BRANCH" "info"

	local destination=$DEST/debs/$RELEASE/${CHOSEN_ROOTFS}_${REVISION}_${ARCH}

	mkdir -p $destination/DEBIAN

	# Replaces: base-files is needed to replace /etc/update-motd.d/ files on Xenial
	# Replaces: unattended-upgrades may be needed to replace /etc/apt/apt.conf.d/50unattended-upgrades
	# (distributions provide good defaults, so this is not needed currently)
	cat <<-EOF > $destination/DEBIAN/control
	Package: linux-${RELEASE}-root-${DEB_BRANCH}${BOARD}
	Version: $REVISION
	Architecture: $ARCH
	Maintainer: $MAINTAINER <$MAINTAINERMAIL>
	Installed-Size: 1
	Section: kernel
	Priority: optional
	Depends: bash, python3-apt
	Provides: armbian-bsp
	Conflicts: armbian-bsp
	Replaces: base-files
	Recommends: fake-hwclock, initramfs-tools
	Description: Armbian tweaks for $RELEASE on $BOARD ($BRANCH branch)
	EOF

	# set up pre install script
	cat <<-EOF > $destination/DEBIAN/preinst
	#!/bin/sh
	[ "\$1" = "upgrade" ] && touch /var/run/.reboot_required
	[ -d "/boot/bin" ] && mv /boot/bin /boot/bin.old
	if [ -L "/etc/network/interfaces" ]; then
		cp /etc/network/interfaces /etc/network/interfaces.tmp
		rm /etc/network/interfaces
		mv /etc/network/interfaces.tmp /etc/network/interfaces
	fi
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/preinst

	# set up post install script
	cat <<-EOF > $destination/DEBIAN/postinst
	#!/bin/sh
	update-rc.d armhwinfo defaults >/dev/null 2>&1
	update-rc.d -f motd remove >/dev/null 2>&1
	[ ! -f "/etc/network/interfaces" ] && cp /etc/network/interfaces.default /etc/network/interfaces
	[ -f "/root/.nand1-allwinner.tgz" ] && rm /root/.nand1-allwinner.tgz
	[ -f "/root/nand-sata-install" ] && rm /root/nand-sata-install
	ln -sf /var/run/motd /etc/motd
	[ -f "/etc/bash.bashrc.custom" ] && mv /etc/bash.bashrc.custom /etc/bash.bashrc.custom.old
	[ -f "/etc/update-motd.d/00-header" ] && rm /etc/update-motd.d/00-header
	[ -f "/etc/update-motd.d/10-help-text" ] && rm /etc/update-motd.d/10-help-text
	if [ -f "/boot/bin/$BOARD.bin" ] && [ ! -f "/boot/script.bin" ]; then ln -sf bin/$BOARD.bin /boot/script.bin >/dev/null 2>&1 || cp /boot/bin/$BOARD.bin /boot/script.bin; fi
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/postinst

	# won't recreate files if they were removed by user
	# TODO: Add proper handling for updated conffiles
	#cat <<-EOF > $destination/DEBIAN/conffiles
	#/boot/.verbose
	#EOF

	# trigger uInitrd creation after installation, to apply
	# /etc/initramfs/post-update.d/99-uboot
	cat <<-EOF > $destination/DEBIAN/triggers
	activate update-initramfs
	EOF

	# scripts for autoresize at first boot
	mkdir -p $destination/etc/init.d
	mkdir -p $destination/etc/default

	install -m 755 $SRC/lib/scripts/resize2fs $destination/etc/init.d
	install -m 755 $SRC/lib/scripts/firstrun  $destination/etc/init.d
	install -m 755 $SRC/lib/scripts/armhwinfo $destination/etc/init.d

	# configure MIN / MAX speed for cpufrequtils
	mkdir -p $destination/etc/default
	cat <<-EOF > $destination/etc/default/cpufrequtils
	ENABLE=true
	MIN_SPEED=$CPUMIN
	MAX_SPEED=$CPUMAX
	GOVERNOR=$GOVERNOR
	EOF

	# armhwinfo, firstrun, armbianmonitor, etc. config file
	cat <<-EOF > $destination/etc/armbian-release
	# PLEASE DO NOT EDIT THIS FILE
	BOARD=$BOARD
	BOARD_NAME="$BOARD_NAME"
	VERSION=$REVISION
	LINUXFAMILY=$LINUXFAMILY
	BRANCH=$BRANCH
	ARCH=$ARCHITECTURE
	EOF

	# temper binary for USB temp meter
	mkdir -p $destination/usr/local/bin

	# add USB OTG port mode switcher
	install -m 755 $SRC/lib/scripts/sunxi-musb $destination/usr/local/bin

	# armbianmonitor (currently only to toggle boot verbosity and log upload)
	install -m 755 $SRC/lib/scripts/armbianmonitor/armbianmonitor $destination/usr/local/bin

	# updating uInitrd image in update-initramfs trigger
	mkdir -p $destination/etc/initramfs/post-update.d/
	cat <<-EOF > $destination/etc/initramfs/post-update.d/99-uboot
	#!/bin/sh
	mkimage -A $INITRD_ARCH -O linux -T ramdisk -C gzip -n uInitrd -d \$2 /boot/uInitrd > /dev/null
	exit 0
	EOF
	chmod +x $destination/etc/initramfs/post-update.d/99-uboot

	# removing old initrd.img on upgrade
	mkdir -p $destination/etc/kernel/preinst.d/
	cat <<-EOF > $destination/etc/kernel/preinst.d/initramfs-cleanup
	#!/bin/sh
	version="\$1"
	[ -x /usr/sbin/update-initramfs ] || exit 0
	# passing the kernel version is required
	if [ -z "\${version}" ]; then
		echo >&2 "W: initramfs-tools: \${DPKG_MAINTSCRIPT_PACKAGE:-kernel package} did not pass a version number"
		exit 0
	fi
	# avoid running multiple times
	if [ -n "\$DEB_MAINT_PARAMS" ]; then
		eval set -- "\$DEB_MAINT_PARAMS"
		if [ -z "\$1" ] || [ "\$1" != "upgrade" ]; then
			exit 0
		fi
	fi
	# delete old initrd images
	find /boot -name "initrd.img*" ! -name "*\$version" -printf "Removing obsolete file %f\n" -delete
	EOF
	chmod +x $destination/etc/kernel/preinst.d/initramfs-cleanup

	# network interfaces configuration
	mkdir -p $destination/etc/network/
	cp $SRC/lib/config/network/interfaces.* $destination/etc/network/
	[[ $RELEASE = wheezy ]] && sed -i 's/allow-hotplug/auto/g' $destination/etc/network/interfaces.default
	[[ $RELEASE = xenial ]] && sed -i 's/#no-auto-down/no-auto-down/g' $destination/etc/network/interfaces.default

	# apt configuration
	mkdir -p $destination/etc/apt/apt.conf.d/
	cat <<-EOF > $destination/etc/apt/apt.conf.d/71-no-recommends
	APT::Install-Recommends "0";
	APT::Install-Suggests "0";
	EOF

	# configure the system for unattended upgrades
	cp $SRC/lib/scripts/02periodic $destination/etc/apt/apt.conf.d/02periodic

	# pin priority for armbian repo
	# reference: man apt_preferences
	# this allows providing own versions of hostapd, libdri2 and sunxi-tools
	mkdir -p $destination/etc/apt/preferences.d/
	cat <<-EOF > $destination/etc/apt/preferences.d/50-armbian.pref
	Package: *
	Pin: origin "apt.armbian.com"
	Pin-Priority: 990
	EOF

	# script to install to SATA
	mkdir -p $destination/usr/sbin/
	cp -R $SRC/lib/scripts/nand-sata-install/usr $destination/
	chmod +x $destination/usr/lib/nand-sata-install/nand-sata-install.sh
	ln -s ../lib/nand-sata-install/nand-sata-install.sh $destination/usr/sbin/nand-sata-install

	# install custom motd with reboot and upgrade checking
	mkdir -p $destination/root $destination/tmp $destination/etc/update-motd.d/ $destination/etc/profile.d
	install -m 755 $SRC/lib/scripts/update-motd.d/* $destination/etc/update-motd.d/
	install -m 755 $SRC/lib/scripts/check_first_login_reboot.sh 	$destination/etc/profile.d
	install -m 755 $SRC/lib/scripts/check_first_login.sh 			$destination/etc/profile.d

	# setting window title for remote sessions
	install -m 755 $SRC/lib/scripts/ssh-title.sh $destination/etc/profile.d/ssh-title.sh

	if [[ $LINUXCONFIG == *sun* ]]; then
		if [[ $BRANCH != next ]]; then
			# add soc temperature app
			local codename=$(lsb_release -sc)
			if [[ -z $codename || "sid" == *"$codename"* ]]; then
				arm-linux-gnueabihf-gcc-5 $SRC/lib/scripts/sunxi-temp/sunxi_tp_temp.c -o $destination/usr/local/bin/sunxi_tp_temp
			else
				arm-linux-gnueabihf-gcc $SRC/lib/scripts/sunxi-temp/sunxi_tp_temp.c -o $destination/usr/local/bin/sunxi_tp_temp
			fi
		fi

		# convert and add fex files
		mkdir -p $destination/boot/bin
		for i in $(ls -w1 $SRC/lib/config/fex/*.fex | xargs -n1 basename); do
			fex2bin $SRC/lib/config/fex/${i%*.fex}.fex $destination/boot/bin/${i%*.fex}.bin
		done

		# bluetooth device enabler - for cubietruck
		# TODO: move to tools or sunxi-common.inc
		install		$SRC/lib/scripts/brcm40183		$destination/etc/default
		install -m 755	$SRC/lib/scripts/brcm40183-patch	$destination/etc/init.d

	fi

	# add some summary to the image
	fingerprint_image "$destination/etc/armbian.txt"

	# create board DEB file
	display_alert "Building package" "$CHOSEN_ROOTFS" "info"
	cd $DEST/debs/$RELEASE/
	dpkg -b ${CHOSEN_ROOTFS}_${REVISION}_${ARCH} >/dev/null

	# cleanup
	rm -rf ${CHOSEN_ROOTFS}_${REVISION}_${ARCH}
}
