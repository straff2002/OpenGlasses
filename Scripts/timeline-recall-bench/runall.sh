#!/bin/zsh
cd "$(dirname "$0")"
for spec in "A r1" "B r1" "C r1" "A r2" "B r2" "D r1" "E r1"; do
  arm=${spec%% *}; label=${spec##* }
  python3 -I bench.py field $arm $label > runs/log-field-$arm-$label.txt 2>&1 &
  python3 -I bench.py everyday $arm $label > runs/log-everyday-$arm-$label.txt 2>&1 &
  wait
  echo "done $arm $label $(date +%T)"
done
