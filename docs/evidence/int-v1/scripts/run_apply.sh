#!/bin/bash
# E2E-13/14/15 composition: consumer editor process (preview child + Apply) + iPad sender test process
. $A/env.sh
cd /Users/andrejvysny/workspace/godot/godot-ipad
P=$A/mc/project
rm -rf $P/addons/apply_driver; cp -R $A/author/apply_driver $P/addons/apply_driver
rm -rf $P/game $P/.world_painter $P/assetstudio.lock.json
pkill -f "mc/project" 2>/dev/null; sleep 1
rm -rf $P/assets/library $P/assets/prefabs $P/.assetstudio
python3 - <<'PY' > $A/apply_items.txt
import os,sys
sys.path.insert(0,os.environ["A"]); from api import req
S=os.environ["S"]; st,i=req("GET",f"/libraries/{S}/assets","ipad")
for x in i["items"]:
    if x["display_name"] in ("Neutral PBR Crate","Textured Tree","Vertex Color Foliage"): print(x["asset_id"],x["current_version_id"])
PY
while read a v; do $A/asgd $P add --library $S --asset $a --version $v --preserve 2>&1 | tail -1; done < $A/apply_items.txt
godot --headless --editor --path $P --import > /dev/null 2>&1
$A/asgd $P finalize 2>&1 | tail -2
rm -rf $A/ctl; mkdir -p $A/ctl
(cd $P; APPLY_CTL=$A/ctl nohup godot --headless --editor --path $P < /dev/null > $A/logs/e2e131415_consumer_editor.log 2>&1 &)
export WP_ACC_URL=$URL WP_ACC_SERVER_ID=$SID WP_ACC_TOKEN_FILE=$A/tok/ipad.token WP_ACC_LIBRARY=$S WP_ACC_DIR=$A/ipad_state WP_ACC_PHASE=apply WP_ACC_CTL=$A/ctl
rm -rf $A/ipad_state/live_* 2>/dev/null
python3 scripts/godot_test.py --sandbox acc-apply --suite integration --filter test_real_server_live < /dev/null > $A/logs/e2e131415_ipad_sender.log 2>&1; echo "sender exit $?"
grep -E "^LIVE|FAIL|tests," $A/logs/e2e131415_ipad_sender.log | cut -c1-300
grep -E "^DRV|DRV_INFO|SCRIPT ERROR|Parse Error" $A/logs/e2e131415_consumer_editor.log | cut -c1-500
