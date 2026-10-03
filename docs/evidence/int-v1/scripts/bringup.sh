#!/bin/bash
# Creates two libraries + tokens in the isolated instance dir and appends ids to env.sh
. $A/env.sh; cd /Users/andrejvysny/workspace/godot/asset-studio
S=$(uv run assetstudio project create shared --root $A/projects/shared | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
G=$(uv run assetstudio project create game --root $A/projects/game | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
uv run assetstudio integration token create desktop --library $S --library $G --scope assets:read --scope assets:publish --token-file $A/tok/desktop.token >/dev/null
uv run assetstudio integration token create ipad --library $S --library $G --scope assets:read --token-file $A/tok/ipad.token >/dev/null
uv run assetstudio integration token create revokeme --library $S --scope assets:read --token-file $A/tok/revoked.token >/dev/null
SID=$(uv run assetstudio integration identity show | python3 -c "import json,sys;print(json.load(sys.stdin)['server_id'])")
printf 'export S=%s G=%s SID=%s\n' $S $G $SID >> $A/env.sh
