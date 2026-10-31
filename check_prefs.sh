#!/bin/bash
set -e
DEB=/mnt/i/OpenCode/temp1/pdstm/_out/com.mikey820.pleasedontstopthemusic_2.6.2-ios13_iphoneos-arm.deb
cd /tmp
rm -rf pchk
mkdir pchk
dpkg-deb -x "$DEB" pchk
B=pchk/Library/PreferenceBundles/PDSTMPrefs.bundle/PDSTMPrefs
OT=/opt/theos/toolchain/linux/iphone/bin/llvm-objdump
echo "codesig: $($OT --macho --private-headers "$B" | grep -c LC_CODE_SIGNATURE)"
echo "principal: $(grep -a -c PDSTMRootListController "$B")"
echo "dylibs:"
$OT --macho --dylibs-used "$B"
