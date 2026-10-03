#!/bin/bash
# builds the publisher scratch project with 3 authored static assets
. $A/env.sh
$A/mkproject.sh $A/pub pub; mkdir -p $A/pub/author; cp $A/author/*.gd $A/pub/author/
cd $A/pub
godot --headless --path . --import >/dev/null 2>&1
godot --headless --path . --script res://author/stage1_png.gd >/dev/null 2>&1
godot --headless --path . --import >/dev/null 2>&1
godot --headless --path . --script res://author/stage2_scenes.gd 2>&1 | grep -E "^res|append|write"
godot --headless --path . --import >/dev/null 2>&1
