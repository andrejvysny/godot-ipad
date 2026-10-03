#!/bin/bash
. $A/env.sh
cd /Users/andrejvysny/workspace/godot/asset-studio
case $1 in
 stop) pkill -f "assetstudio serve" ; sleep 2;;
 start) (nohup uv run assetstudio serve >> $A/logs/server.log 2>&1 &); for i in $(seq 40); do curl -sf http://127.0.0.1:18192/api/integration/v1/health >/dev/null && break; sleep 0.5; done; echo up;;
esac
