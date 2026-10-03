#!/bin/bash
# usage: mkproject.sh DIR NAME  -- creates empty godot project with addon installed from the packaged archive
set -e
D=$1; N=$2
mkdir -p $D
cat > $D/project.godot <<P
config_version=5

[application]

config/name="$N"
config/features=PackedStringArray("4.7")
config/use_custom_user_dir=true
config/custom_user_dir_name="as_accept_$N"
P
unzip -qo $A/dist/assetstudio-addon-0.2.1.zip -d $D
