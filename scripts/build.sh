#!/usr/bin/env bash
# build.sh - Baut DepthRunner im Release-Modus
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "================================================"
echo "DepthRunner Build"
echo "================================================"
echo ""

cd "$PROJECT_ROOT"

# 1. Umgebungs-Check
echo "📋 Schritt 1/3: Umgebung prüfen..."
if [[ -x "$SCRIPT_DIR/env_check.sh" ]]; then
  "$SCRIPT_DIR/env_check.sh"
else
  echo "⚠️  env_check.sh nicht gefunden - überspringe Umgebungsprüfung"
fi

echo ""
echo "================================================"
echo ""

# 2. Package beschreiben
echo "📋 Schritt 2/3: Package analysieren..."
swift package describe

echo ""
echo "================================================"
echo ""

# 3. Bauen (Release)
echo "📋 Schritt 3/3: Bauen (Release-Modus)..."
echo ""

xcrun swift build -c release

echo ""
echo "================================================"
echo "✅ Build erfolgreich!"
echo "================================================"
echo ""
echo "Binary-Pfad:"
BINARY_PATH=$(swift build -c release --show-bin-path)/DepthRunner
if [[ -f "$BINARY_PATH" ]]; then
  echo "  → ${BINARY_PATH}"
  echo ""
  echo "Ausführen:"
  echo "  swift run DepthRunner <bild>"
  echo "  # oder direkt:"
  echo "  ${BINARY_PATH} <bild>"
else
  echo "  ⚠️ Binary nicht gefunden (erwarteter Pfad: ${BINARY_PATH})"
  exit 1
fi

echo ""


