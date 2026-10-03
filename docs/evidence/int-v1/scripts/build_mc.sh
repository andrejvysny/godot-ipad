#!/bin/bash
. $A/env.sh
cd /Users/andrejvysny/workspace/godot/godot-ipad
rm -rf $A/mc; python3 scripts/make_minimal_consumer.py --work-dir $A/mc > $A/logs/minimal_consumer_build.log 2>&1 || { echo BUILD FAILED; tail $A/logs/minimal_consumer_build.log; exit 1; }
P=$A/mc/project
cp $A/cons/assetstudio.project.json $P/assetstudio.project.json
python3 - <<'PY'
import os
p=os.environ["A"]+"/mc/project/project.godot"; s=open(p).read()
s=s.replace('run/main_scene="res://scenes/main.tscn"','run/main_scene="res://scenes/main.tscn"\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="wp_accept_mc"')
s+='\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/apply_driver/plugin.cfg")\n'
open(p,"w").write(s)
PY
cp -R $A/author/apply_driver $P/addons/apply_driver
rm -rf ~/Library/Application\ Support/Godot/app_userdata/wp_accept_mc
$A/asgd $P connect --server-id $SID --url $URL --token-file $A/tok/ipad.token 2>&1 | tail -1
