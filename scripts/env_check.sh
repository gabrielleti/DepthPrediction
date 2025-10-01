#!/usr/bin/env bash
# env_check.sh - Prüft die Entwicklungsumgebung für DepthRunner
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

echo "================================================"
echo "DepthRunner Umgebungs-Check"
echo "================================================"
echo ""

# 1. Betriebssystem prüfen
echo -n "🔍 Betriebssystem... "
if [[ "$(uname -s)" == "Darwin" ]]; then
  OS_VERSION=$(sw_vers -productVersion)
  echo -e "${GREEN}✅ macOS ${OS_VERSION}${NC}"
else
  echo -e "${RED}❌ Nicht macOS ($(uname -s))${NC}"
  echo "   → DepthRunner benötigt macOS (CoreML/CoreImage nicht verfügbar auf anderen Plattformen)"
  ERRORS=$((ERRORS + 1))
fi

# 2. Xcode / Command Line Tools prüfen
echo -n "🔍 Xcode / Command Line Tools... "
if xcode-select -p &> /dev/null; then
  XCODE_PATH=$(xcode-select -p)
  
  # Prüfe ob volle Xcode-Installation oder nur CLT
  if [[ "$XCODE_PATH" == *"CommandLineTools"* ]]; then
    echo -e "${GREEN}✅ Command Line Tools${NC}"
    echo "   → ${XCODE_PATH}"
    echo -e "${YELLOW}   ℹ️  Für volle Xcode-Features installiere Xcode.app aus dem App Store${NC}"
  else
    # Versuche Xcode-Version zu bekommen
    if command -v xcodebuild &> /dev/null; then
      XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -n 1 || echo "Xcode")
      echo -e "${GREEN}✅ ${XCODE_VERSION}${NC}"
      echo "   → ${XCODE_PATH}"
    else
      echo -e "${GREEN}✅ Entwickler-Tools gefunden${NC}"
      echo "   → ${XCODE_PATH}"
    fi
  fi
else
  echo -e "${RED}❌ Xcode/Command Line Tools nicht gefunden${NC}"
  echo "   → Installiere Command Line Tools: xcode-select --install"
  echo "   → Oder installiere Xcode aus dem App Store"
  ERRORS=$((ERRORS + 1))
fi

# 3. Swift-Version prüfen
echo -n "🔍 Swift... "
if command -v swift &> /dev/null; then
  SWIFT_VERSION=$(swift --version | head -n 1)
  echo -e "${GREEN}✅ ${SWIFT_VERSION}${NC}"
  
  # Mindestversion prüfen (5.7)
  SWIFT_MAJOR=$(swift --version | grep -oE 'version [0-9]+' | awk '{print $2}')
  if [[ "$SWIFT_MAJOR" -lt 5 ]]; then
    echo -e "${RED}❌ Swift 5.7+ erforderlich (gefunden: ${SWIFT_MAJOR})${NC}"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo -e "${RED}❌ Swift nicht gefunden${NC}"
  echo "   → Installiere Xcode oder Command Line Tools"
  ERRORS=$((ERRORS + 1))
fi

# 4. Swift Package Manager prüfen
echo -n "🔍 Swift Package Manager... "
if swift package --version &> /dev/null 2>&1; then
  SPM_VERSION=$(swift package --version 2>&1 | head -n 1 || echo "verfügbar")
  echo -e "${GREEN}✅ ${SPM_VERSION}${NC}"
else
  echo -e "${RED}❌ Swift Package Manager nicht verfügbar${NC}"
  ERRORS=$((ERRORS + 1))
fi

# 5. CoreML Framework prüfen (indirekt über xcrun)
echo -n "🔍 Apple Frameworks (CoreML, CoreImage)... "
if command -v xcrun &> /dev/null; then
  # Prüfe ob wir ein Swift-Skript kompilieren können, das CoreML importiert
  TEMP_CHECK=$(mktemp /tmp/coreml_check_XXXXXX.swift)
  cat > "$TEMP_CHECK" <<'EOF'
import CoreML
import CoreImage
import CoreGraphics
import CoreVideo
import Foundation

print("OK")
EOF
  
  if xcrun swift "$TEMP_CHECK" &> /dev/null; then
    echo -e "${GREEN}✅ Verfügbar${NC}"
  else
    echo -e "${RED}❌ CoreML/CoreImage nicht verfügbar${NC}"
    echo "   → Stelle sicher, dass du auf macOS läufst und Xcode installiert ist"
    ERRORS=$((ERRORS + 1))
  fi
  rm -f "$TEMP_CHECK"
else
  echo -e "${YELLOW}⚠️  xcrun nicht gefunden - kann Frameworks nicht prüfen${NC}"
  WARNINGS=$((WARNINGS + 1))
fi

# 6. Prüfe Package.swift
echo -n "🔍 Package.swift... "
if [[ -f "Package.swift" ]]; then
  echo -e "${GREEN}✅ Gefunden${NC}"
  
  # Versuche Package zu beschreiben
  if swift package describe &> /dev/null; then
    echo "   → Package ist gültig"
  else
    echo -e "${YELLOW}⚠️  Package-Beschreibung fehlgeschlagen${NC}"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo -e "${RED}❌ Package.swift nicht gefunden${NC}"
  echo "   → Führe dieses Skript im Repository-Root aus"
  ERRORS=$((ERRORS + 1))
fi

# 7. Prüfe CoreML-Modell
echo -n "🔍 CoreML-Modell (.mlmodel/.mlmodelc)... "
MODEL_COUNT=$(find . -name "*.mlmodel" -o -name "*.mlmodelc" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MODEL_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✅ ${MODEL_COUNT} Modell(e) gefunden${NC}"
  find . -name "*.mlmodel" -o -name "*.mlmodelc" 2>/dev/null | head -n 3 | while read -r model; do
    echo "   → ${model}"
  done
else
  echo -e "${YELLOW}⚠️  Kein Modell gefunden${NC}"
  echo "   → Lade ein Depth-Modell herunter (z.B. MiDaS, FCRN)"
  echo "   → Siehe: https://developer.apple.com/machine-learning/models/"
  WARNINGS=$((WARNINGS + 1))
fi

# 8. Prüfe Testbilder
echo -n "🔍 Testbilder (resource/*.PNG)... "
if [[ -d "resource" ]]; then
  IMAGE_COUNT=$(find resource -name "*.PNG" -o -name "*.jpg" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$IMAGE_COUNT" -gt 0 ]]; then
    echo -e "${GREEN}✅ ${IMAGE_COUNT} Bild(er) gefunden${NC}"
  else
    echo -e "${YELLOW}⚠️  Keine Testbilder gefunden${NC}"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo -e "${YELLOW}⚠️  resource/-Verzeichnis fehlt${NC}"
  WARNINGS=$((WARNINGS + 1))
fi

# Zusammenfassung
echo ""
echo "================================================"
echo "Zusammenfassung"
echo "================================================"

if [[ "$ERRORS" -eq 0 ]] && [[ "$WARNINGS" -eq 0 ]]; then
  echo -e "${GREEN}✅ Alle Checks erfolgreich!${NC}"
  echo ""
  echo "Nächste Schritte:"
  echo "  1. Bauen: ./scripts/build.sh"
  echo "  2. Testen: ./scripts/run_sample.sh"
  exit 0
elif [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${YELLOW}⚠️  ${WARNINGS} Warnung(en) - Build sollte funktionieren${NC}"
  exit 0
else
  echo -e "${RED}❌ ${ERRORS} Fehler, ${WARNINGS} Warnung(en)${NC}"
  echo ""
  echo "Behebe die Fehler oben, bevor du fortfährst."
  exit 1
fi

