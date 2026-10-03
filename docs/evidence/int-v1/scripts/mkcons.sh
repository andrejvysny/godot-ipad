#!/bin/bash
# blank consumer: addon only, e2e driver plugin, level scene. usage: mkcons.sh DIR NAME
. $A/env.sh
$A/mkproject.sh $1 $2
cat >> $1/project.godot <<P

[editor_plugins]

enabled=PackedStringArray("res://addons/assetstudio/plugin.cfg", "res://addons/e2e_plugin/plugin.cfg")
P
mkdir -p $1/addons; cp -R $A/author/e2e_plugin $1/addons/e2e_plugin
printf '[gd_scene format=3]\n\n[node name="Level" type="Node3D"]\n' > $1/level.tscn
