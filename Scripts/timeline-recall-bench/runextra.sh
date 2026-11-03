#!/bin/zsh
cd "$(dirname "$0")"
for spec in "A r3" "B r3" "C r2" "D r2" "E r2"; do
  arm=${spec%% *}; label=${spec##* }
  python3 -I bench.py field $arm $label > runs/log-field-$arm-$label.txt 2>&1 &
  python3 -I bench.py everyday $arm $label > runs/log-everyday-$arm-$label.txt 2>&1 &
  wait
  echo "done $arm $label $(date +%T)"
done
