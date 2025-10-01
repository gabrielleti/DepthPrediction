#!/usr/bin/env bash
# run_sample.sh - Führt DepthRunner mit einem Beispielbild aus
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Konfiguration
DEFAULT_INPUT="${PROJECT_ROOT}/resource/IMG_3623.PNG"
INPUT="${INPUT:-$DEFAULT_INPUT}"
FOV="${FOV:-60}"
ZBAND="${ZBAND:-0.10,0.80}"
TRIM="${TRIM:-0.98}"
OUTDIR="${OUTDIR:-${PROJECT_ROOT}/output/qa}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================================"
echo "DepthRunner Sample Test"
echo "================================================"
echo ""

cd "$PROJECT_ROOT"

# 1. Umgebungs-Check (optional, schnell)
if [[ -x "$SCRIPT_DIR/env_check.sh" ]]; then
  echo "🔍 Umgebungs-Check..."
  "$SCRIPT_DIR/env_check.sh" || {
    echo -e "${RED}❌ Umgebungs-Check fehlgeschlagen${NC}"
    exit 1
  }
  echo ""
fi

# 2. Input validieren
if [[ ! -f "$INPUT" ]]; then
  echo -e "${RED}❌ Eingabebild nicht gefunden: ${INPUT}${NC}"
  echo ""
  echo "Verwendung:"
  echo "  INPUT=/pfad/zum/bild.jpg $0"
  echo "  # oder Standard-Bild (falls vorhanden):"
  echo "  $0"
  exit 1
fi

echo "📷 Eingabebild: ${INPUT}"
echo "🎯 Parameter:"
echo "   FOV:              ${FOV}°"
echo "   Z-Band:           ${ZBAND} m"
echo "   Trim-Percentile:  ${TRIM}"
echo "   Ausgabe:          ${OUTDIR}"
echo ""

# 3. Ausgabeverzeichnis erstellen
mkdir -p "$OUTDIR"

# 4. Dateinamen extrahieren
STEM=$(basename "$INPUT")
STEM="${STEM%.*}"

DEPTH_PNG="${OUTDIR}/${STEM}_depth.png"
PLY_FILE="${OUTDIR}/${STEM}.ply"
LOG_FILE="${OUTDIR}/${STEM}.log"

# 5. DepthRunner ausführen
echo "================================================"
echo "🚀 Führe DepthRunner aus..."
echo "================================================"
echo ""

set +e
swift run DepthRunner "$INPUT" \
  --out "$DEPTH_PNG" \
  --ply "$PLY_FILE" \
  --fov "$FOV" \
  --z-band "$ZBAND" \
  --trim-percentile "$TRIM" \
  --clip-ground \
  --roi-auto \
  --volume --unit ml 2>&1 | tee "$LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
echo "================================================"
echo "📊 Ergebnisse validieren..."
echo "================================================"
echo ""

VALIDATION_ERRORS=0

# 6. Outputs prüfen
echo -n "🔍 Tiefenkarte (PNG)... "
if [[ -s "$DEPTH_PNG" ]]; then
  FILE_SIZE=$(du -h "$DEPTH_PNG" | cut -f1)
  echo -e "${GREEN}✅ ${DEPTH_PNG} (${FILE_SIZE})${NC}"
else
  echo -e "${RED}❌ Nicht gefunden oder leer${NC}"
  VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

echo -n "🔍 Punktwolke (PLY)... "
if [[ -s "$PLY_FILE" ]]; then
  FILE_SIZE=$(du -h "$PLY_FILE" | cut -f1)
  POINT_COUNT=$(grep -c "^-\?[0-9]" "$PLY_FILE" || echo "0")
  echo -e "${GREEN}✅ ${PLY_FILE} (${FILE_SIZE}, ~${POINT_COUNT} Punkte)${NC}"
else
  echo -e "${RED}❌ Nicht gefunden oder leer${NC}"
  VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

echo -n "🔍 Log-Datei... "
if [[ -s "$LOG_FILE" ]]; then
  FILE_SIZE=$(du -h "$LOG_FILE" | cut -f1)
  echo -e "${GREEN}✅ ${LOG_FILE} (${FILE_SIZE})${NC}"
else
  echo -e "${YELLOW}⚠️  Log leer oder fehlt${NC}"
fi

echo -n "🔍 Volume-Zeile im Log... "
if grep -q "Volume:" "$LOG_FILE" 2>/dev/null; then
  VOLUME_LINE=$(grep "Volume:" "$LOG_FILE" | head -n 1)
  echo -e "${GREEN}✅${NC}"
  echo "   → ${VOLUME_LINE}"
else
  echo -e "${RED}❌ Keine 'Volume:'-Zeile gefunden${NC}"
  VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

# 7. Warnungen extrahieren
echo ""
echo -n "⚠️  Warnungen... "
WARNING_COUNT=$(grep -c "^⚠️" "$LOG_FILE" 2>/dev/null || echo "0")
if [[ "$WARNING_COUNT" -gt 0 ]]; then
  echo -e "${YELLOW}${WARNING_COUNT} gefunden${NC}"
  grep "^⚠️" "$LOG_FILE" | while IFS= read -r line; do
    echo "   ${line}"
  done
else
  echo -e "${GREEN}Keine${NC}"
fi

# 8. Zusammenfassung
echo ""
echo "================================================"
echo "Zusammenfassung"
echo "================================================"

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo -e "${RED}❌ DepthRunner fehlgeschlagen (Exit-Code: ${EXIT_CODE})${NC}"
  echo ""
  echo "Siehe Log: ${LOG_FILE}"
  exit 1
elif [[ "$VALIDATION_ERRORS" -gt 0 ]]; then
  echo -e "${RED}❌ Validierung fehlgeschlagen (${VALIDATION_ERRORS} Fehler)${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Smoke-Test bestanden!${NC}"
  echo ""
  echo "Outputs:"
  echo "  - Tiefenkarte: ${DEPTH_PNG}"
  echo "  - Punktwolke:  ${PLY_FILE}"
  echo "  - Log:         ${LOG_FILE}"
  exit 0
fi


