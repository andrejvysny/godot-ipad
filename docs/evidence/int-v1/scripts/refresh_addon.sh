#!/bin/bash
set -e
cd /Users/andrejvysny/workspace/godot/asset-studio
rm -f $A/dist/*; python3 scripts/package_addon.py --out-dir $A/dist >/dev/null
for p in "$@"; do rm -rf $p/addons/assetstudio; unzip -qo $A/dist/assetstudio-addon-0.2.1.zip -d $p; done
cat $A/dist/*.sha256
