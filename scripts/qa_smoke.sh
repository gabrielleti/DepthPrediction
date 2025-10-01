#!/usr/bin/env bash
set -euo pipefail

# Konfiguration
FOV="${FOV:-60}"
ZBAND="${ZBAND:-0.10,0.80}"
TRIM="${TRIM:-0.98}"

OUTDIR="output/qa"
mkdir -p "$OUTDIR"

run_case () {
  local input="$1"
  local stem
  stem=$(basename "$input"); stem="${stem%.*}"

  echo "==> Running: $input"
  swift run DepthRunner "$input" \
    --out "$OUTDIR/${stem}_depth.png" \
    --ply "$OUTDIR/${stem}.ply" \
    --fov "$FOV" \
    --z-band "$ZBAND" \
    --trim-percentile "$TRIM" \
    --clip-ground \
    --roi-auto \
    --volume --unit ml | tee "$OUTDIR/${stem}.log"

  grep -E "Volume:" "$OUTDIR/${stem}.log" >/dev/null || { echo "No Volume line"; exit 1; }
  test -s "$OUTDIR/${stem}_depth.png" || { echo "No depth PNG"; exit 1; }
  test -s "$OUTDIR/${stem}.ply"       || { echo "No PLY"; exit 1; }
}

# Testfälle (anpassen!)
run_case "resource/IMG_3623.PNG"

echo "✅ QA smoke finished. See $OUTDIR/"
