#!/bin/bash
cd /Users/andrejvysny/workspace/godot/asset-studio
L=$A/logs/as_suites; mkdir -p $L
godot --headless --path integrations/godot --import > $L/import.log 2>&1
godot --headless --path integrations/godot --script res://tests/run_tests.gd < /dev/null > $L/run_tests_gd.log 2>&1; echo "run_tests.gd exit $?" >> $L/summary.txt
for r in client consumer source publish export plugin; do
  python3 integrations/godot/tests/run_${r}_tests.py < /dev/null > $L/run_${r}.log 2>&1; echo "run_${r}_tests.py exit $?" >> $L/summary.txt
done
uv run pytest tests/unit tests/contract tests/regression -q -p no:cacheprovider > $L/pytest.log 2>&1; echo "pytest exit $?" >> $L/summary.txt
echo DONE >> $L/summary.txt
