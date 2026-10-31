#!/bin/bash
DEB=/mnt/i/OpenCode/temp1/pdstm/_out/com.mikey820.pleasedontstopthemusic_2.6.4-ios13_iphoneos-arm.deb
cd /tmp
rm -rf pchk3
mkdir pchk3
dpkg-deb -x "$DEB" pchk3
B=pchk3/Library/PreferenceBundles/PDSTMPrefs.bundle/PDSTMPrefs
OT=/opt/theos/toolchain/linux/iphone/bin/llvm-objdump
NM=/opt/theos/toolchain/linux/iphone/bin/llvm-nm
echo "== dylibs =="
$OT --macho --dylibs-used "$B" | tail -n +2
echo "== undefined PS symbols =="
$NM -u "$B" | grep -E 'PSList|PSSpec' | head -10
echo "== codesig =="
$OT --macho --private-headers "$B" | grep -c LC_CODE_SIGNATURE
