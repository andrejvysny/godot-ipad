#!/bin/bash
# usage gitrepo.sh SRC DST : tracked-only copy (no library/.godot) as git repo
mkdir -p $2; cd $1; cp -R addons assets assetstudio.lock.json assetstudio.project.json project.godot $2/ 2>/dev/null; rm -rf $2/assets/library $2/addons/e2e_plugin
printf '/assets/library/\n/.assetstudio/\n/.godot/\n' > $2/.gitignore
cd $2; git init -q; git -c user.email=a@b -c user.name=acc add -A; git -c user.email=a@b -c user.name=acc commit -qm x
