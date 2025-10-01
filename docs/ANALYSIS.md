# DepthRunner-CLI: End-to-End Analyse

**Datum:** 2025-10-01  
**Version:** 1.0  
**Status:** Komplett

---

## 1. Überblick

DepthRunner ist ein kommandozeilenbasiertes Swift-Tool für macOS, das CoreML-Modelle zur Tiefenschätzung (Depth Prediction) nutzt. Es verarbeitet Eingabebilder und erzeugt:
- Normalisierte Tiefenkarten (PNG)
- 3D-Punktwolken (PLY/XYZ)
- Volumenberechnungen mit Plausibilitätsprüfungen

Das Tool basiert auf Apple-Frameworks (CoreML, CoreImage, CoreGraphics, CoreVideo) und ist **ausschließlich für macOS** konzipiert.

---

## 2. Package-Struktur

### 2.1 Targets & Abhängigkeiten

**Package.swift:**
```swift
- Name: DepthPrediction
- Plattform: macOS 12.0+
- Swift: 5.7+
- Produkte:
  - executable: DepthRunner
- Targets:
  - DepthRunner (Sources/DepthRunner/)
- Externe Abhängigkeiten: Keine (nur System-Frameworks)
```

**System-Frameworks:**
- `CoreML` - ML-Modell-Inferenz
- `CoreImage` - Bildverarbeitung
- `CoreGraphics` - Grafik-Operationen
- `CoreVideo` - Pixel-Buffer-Handling
- `Foundation` - Basis-Funktionalität
- `simd` - SIMD-Vektoroperationen

### 2.2 Source-Dateien

```
Sources/DepthRunner/
├── DepthRunner.swift          (~1716 Zeilen) - Haupteinstieg, CLI-Parser, Pipeline-Orchestrierung
├── PointCloudExporter.swift   (~114 Zeilen)  - Point-Cloud-Konvertierung (depthToPointSamples)
└── VolumeCalculator.swift     (~66 Zeilen)   - AABB-Volumenberechnung
```

---

## 3. Haupteinstieg: DepthRunner

### 3.1 Entry Point

**`@main struct DepthRunner`** in `DepthRunner.swift:20`

**Ablauf:**
1. Kommandozeilen-Argumente parsen (`CommandLineOptions.parse()`)
2. CoreML-Modell lokalisieren (`ModelLocator().locateModel()`)
3. Tiefenkarte generieren (`DepthMapGenerator.generateDepthMap()`)
4. Optional: Punktwolke erstellen, filtern, exportieren
5. Optional: Volumen berechnen mit Plausibilitätschecks
6. Warnungen zusammenfassen (bei `--strict-warn`)

### 3.2 Verfügbare CLI-Flags

#### **Eingabe/Ausgabe:**
| Flag | Typ | Beschreibung |
|------|-----|--------------|
| `<eingabe_bildpfad>` | Positional | **Erforderlich.** Pfad zum Eingabebild |
| `--out <pfad>` | Optional | Ausgabepfad für Tiefenkarte (Standard: `output/depth_map.png`) |
| `--ply <pfad>` | Optional | PLY-Punktwolke exportieren |
| `--xyz <pfad>` | Optional | XYZ-Punktwolke exportieren |

#### **Kamera-Intrinsik:**
| Flag | Standard | Beschreibung |
|------|----------|--------------|
| `--fov <grad>` | 60° | Field-of-View in Grad (0–180) |
| `--fx <wert>` | - | Focal length X (erfordert fy, cx, cy) |
| `--fy <wert>` | - | Focal length Y |
| `--cx <wert>` | - | Principal point X |
| `--cy <wert>` | - | Principal point Y |

**Hinweis:** Explizite Intrinsik (`fx/fy/cx/cy`) überschreibt `--fov`.

#### **Region-of-Interest (ROI):**
| Flag | Standard | Beschreibung |
|------|----------|--------------|
| `--roi center=<fraction>` | - | Zentrierter ROI (0–1, z.B. `0.6` = 60% des Bildes) |
| `--roi-auto` | - | Automatischer ROI basierend auf nächster Tiefe |
| `--roi-near-percentile <p>` | 0.30 | Perzentil für "nah"-Tiefen (0.10–0.50) |
| `--roi-margin <m>` | 0.05 | Zusätzlicher Rand um Auto-ROI (0.00–0.20) |
| `--roi-min-size <s>` | 0.35 | Minimale ROI-Größe als Bruchteil (0.20–0.70) |

**Hinweis:** `--roi center=...` und `--roi-auto` schließen sich gegenseitig aus.

#### **Tiefenfilterung:**
| Flag | Standard | Beschreibung |
|------|----------|--------------|
| `--z-band <min,max>` | 0.10,0.80 | Zulässiger Tiefenbereich in Metern |
| `--trim-percentile <p>` | 0.98 | Outlier-Trimming (0.90–0.999) |

#### **Bodenebenen-Entfernung:**
| Flag | Standard | Beschreibung |
|------|----------|--------------|
| `--clip-ground` | - | Aktiviert Ground-Plane-Fitting |
| `--ground-percentile <p>` | 0.10 | Perzentil für Bodenebenen-Fitting (0–1] |
| `--ground-eps <ε>` | 0.008 | Epsilon-Band für Boden-Clipping in Metern |

#### **Volumenberechnung:**
| Flag | Standard | Beschreibung |
|------|----------|--------------|
| `--volume` | - | Aktiviert Volumenberechnung |
| `--unit <einheit>` | ml | Einheit: `ml`, `cm3`, `m3` |
| `--no-auto-scale` | - | Deaktiviert Auto-Skalierung (Standard: 0.25m Teller-Durchmesser) |

#### **Debugging:**
| Flag | Beschreibung |
|------|--------------|
| `--strict-warn` | Gibt Warnungs-Zusammenfassung am Ende aus (z.B. `WARN: volume_out_of_range`) |

---

## 4. Pipeline-Flow

```
┌─────────────────┐
│  Eingabebild    │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  CoreML-Modell-Inferenz             │
│  (MiDaS Small oder ähnlich)         │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Normalisierung → [0, 255]          │
│  Tiefenkarte als PNG speichern      │
└────────┬────────────────────────────┘
         │
         ▼ (falls --ply/--xyz/--volume)
┌─────────────────────────────────────┐
│  Rück-Projektion → 3D-Punktwolke    │
│  (mit Kamera-Intrinsik)             │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Filter: Z-Band [zMin, zMax]        │
│  + ROI (manuell/auto)               │
└────────┬────────────────────────────┘
         │
         ▼ (falls --clip-ground)
┌─────────────────────────────────────┐
│  Ground-Plane Fitting (LSQ)         │
│  → Entfernt Boden-Punkte (ε-Band)   │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Trim: Outlier-Removal              │
│  (Perzentil-basiert, XYZ)           │
└────────┬────────────────────────────┘
         │
         ▼ (falls --roi-auto)
┌─────────────────────────────────────┐
│  Auto-ROI: Bounding-Box um          │
│  nächste Tiefen-Perzentil           │
└────────┬────────────────────────────┘
         │
         ▼ (falls --volume)
┌─────────────────────────────────────┐
│  Auto-Scale (optional):             │
│  Skaliert auf 0.25m Durchmesser     │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  AABB-Volumen berechnen             │
│  + Plausibilitätschecks             │
│  + Warnings (low_points, tiny_roi,  │
│    odd_zspan, volume_out_of_range)  │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Export: PLY/XYZ (falls gewünscht)  │
│  Logs: Points, BBox, Scale, Volume  │
└─────────────────────────────────────┘
```

### 4.1 Wichtige Algorithmen

**Ground-Plane Fitting** (`fitGroundPlaneLSQ`, Zeile 411):
- Least-Squares-Fit: `z = ax + by + c`
- Nutzt unterste Perzentil-Tiefen (Standard: 10%)
- Minimum 100 Kandidaten-Punkte erforderlich

**Auto-ROI** (`autoROI`, Zeile 453):
- Findet Bounding-Box um nächste `nearPercentile` (Standard: 30%)
- Erweitert Box um `margin` (Standard: 5%)
- Garantiert Mindestgröße `minSize` (Standard: 35%)
- Fallback: Zentraler Crop (60%) bei Fehlern

**Auto-Scale** (`applyAutoScaleIfNeeded`, Zeile 628):
- Misst XY-Durchmesser der Punktwolke
- Skaliert auf angenommenen Teller-Durchmesser (0.25m)
- Gültigkeitsbereich: 0.05–1.0m
- Kann mit `--no-auto-scale` deaktiviert werden

---

## 5. Plausibilitäts-Logging

### 5.1 Ausgabeformat

```
Points: total=18234, used=17998, roi_pixels=92160, roi_cov=36.0%
BBox[m]: pre x:[-0.059, 0.064] y:[-0.061, 0.058] z:[0.129, 0.182] | post x:[-0.064, 0.069] y:[-0.066, 0.063] z:[0.140, 0.198]
Scale: assumed=0.25 m, measured=0.2360 m, factor=1.059
Volume: 510.4 ml (0.000510 m3)
⚠️ Volume out of nominal range (510.4 ml)
WARN: volume_out_of_range
```

### 5.2 Warnungs-Typen

| Warning Code | Trigger | Beschreibung |
|--------------|---------|--------------|
| `low_points` | `used < 1000` | Zu wenige Punkte für stabile Berechnung |
| `tiny_roi` | `roi_cov < 10%` | ROI zu klein |
| `odd_zspan` | `dz < 0.01 \|\| dz > 0.20` | Verdächtige Tiefen-Spanne |
| `volume_out_of_range` | `V < 10ml \|\| V > 10000ml` | Volumen außerhalb nomineller Grenzen |

**Hinweis:** Warnungen führen **nicht** zu Exit-Code ≠ 0, es sei denn, `--strict-warn` wird verwendet.

---

## 6. Bekannte Grenzen & Einschränkungen

### 6.1 Plattform
- ✅ **Nur macOS** (ab 12.0)
- ❌ **Kein Linux/Windows** (CoreML/CoreImage nicht verfügbar)
- ❌ **Keine iOS-Integration** im CLI-Tool (separates Xcode-Projekt vorhanden)

### 6.2 CoreML-Modell
- Tool sucht automatisch nach `.mlmodel`/`.mlmodelc` in:
  - Bundle-Ressourcen
  - `Models/`
  - `DepthPrediction-CoreML/mlmodel/`
  - Arbeitsverzeichnis (rekursiv)
- **Erforderlich:** Mindestens ein Depth-Modell (z.B. MiDaS, FCRN)
- **Nicht im Repository enthalten** (muss separat heruntergeladen werden)

### 6.3 Genauigkeit
- Volumenberechnungen sind **relativ** zur Modell-Genauigkeit
- Auto-Scale nimmt 0.25m-Teller an → für andere Objekte ungenau
- Ground-Plane-Fitting funktioniert nur bei flachen Oberflächen

### 6.4 Skalierung
- Keine GPU-Optimierung dokumentiert (CoreML nutzt intern ANE/GPU)
- Sequenzielle Verarbeitung (kein Batch-Mode)

---

## 7. Exit-Codes

| Code | Bedeutung |
|------|-----------|
| `0` | Erfolg (inkl. Warnungen) |
| `1` | Allgemeiner Fehler |
| `2` | Ungültige Argumente, Eingabe/Modell nicht gefunden |

---

## 8. Vergleich: qa_smoke.sh vs. run_sample.sh

### 8.1 Existierendes Skript: `scripts/qa_smoke.sh`

**Funktionen:**
- ✅ Führt DepthRunner mit sinnvollen Parametern aus
- ✅ Prüft Existenz von PNG, PLY, Log
- ✅ Verifiziert `Volume:`-Zeile in Log
- ✅ Unterstützt Umgebungsvariablen (`FOV`, `ZBAND`, `TRIM`)
- ✅ Ausgabeverzeichnis: `output/qa/`

**Parameter (Standard):**
```bash
--fov 60
--z-band 0.10,0.80
--trim-percentile 0.98
--clip-ground
--roi-auto
--volume --unit ml
```

### 8.2 Geplantes Skript: `scripts/run_sample.sh`

**Zusätzliche Funktionen:**
- ✅ Parametrisierter Input (Standard: `resource/IMG_3623.PNG`)
- ✅ Umgebungs-Check vor Ausführung
- ✅ Bessere Fehlerbehandlung
- ✅ Zusammenfassung am Ende

**Konsistenz:**
- ✅ Identische Parameter zu `qa_smoke.sh`
- ✅ Gleiches Ausgabeverzeichnis (`output/qa/`)

**Empfehlung:**
- `qa_smoke.sh` **beibehalten** für Multi-Image-Tests
- `run_sample.sh` **erstellen** für Single-Image-Tests mit flexibler Eingabe
- Beide Skripte können koexistieren

---

## 9. Quick Reference (1 Seite)

### 9.1 Minimal-Beispiele

```bash
# 1. Nur Tiefenkarte
swift run DepthRunner input.jpg

# 2. Tiefenkarte + PLY mit FOV
swift run DepthRunner input.jpg --out depth.png --ply points.ply --fov 60

# 3. Volumenberechnung (empfohlen für Food)
swift run DepthRunner input.jpg \
  --fov 60 \
  --z-band 0.10,0.80 \
  --trim-percentile 0.98 \
  --clip-ground \
  --roi-auto \
  --volume --unit ml

# 4. Maximale Kontrolle
swift run DepthRunner input.jpg \
  --fx 1450 --fy 1450 --cx 960 --cy 720 \
  --roi center=0.6 \
  --ground-percentile 0.12 \
  --ground-eps 0.010 \
  --volume --unit cm3 \
  --no-auto-scale \
  --strict-warn
```

### 9.2 Häufige Flags-Kombinationen

| Use Case | Flags |
|----------|-------|
| **Schnelltest** | `input.jpg` |
| **Point Cloud** | `--ply out.ply --fov 60` |
| **Volumen (Teller/Food)** | `--fov 60 --clip-ground --roi-auto --volume` |
| **Präzisions-Messung** | `--fx ... --fy ... --cx ... --cy ... --no-auto-scale --volume` |
| **Debugging** | `--strict-warn` (zeigt `WARN:` Codes) |

### 9.3 Typische Workflow

```bash
# 1. Umgebung prüfen
./scripts/env_check.sh

# 2. Bauen
./scripts/build.sh

# 3. Beispiel ausführen
./scripts/run_sample.sh

# 4. QA-Tests (mehrere Bilder)
./scripts/qa_smoke.sh
```

### 9.4 Troubleshooting

| Problem | Lösung |
|---------|--------|
| `modelNotFound` | CoreML-Modell (.mlmodelc) fehlt → herunterladen |
| `inputNotFound` | Pfad falsch → prüfen mit `ls -la` |
| `Volume: 0.0 ml` | Keine Punkte im ROI → `--roi center=1` testen |
| Viele Warnungen | Normal bei suboptimalen Bildern → Log prüfen |
| `unsupported pixel buffer format` | Modell-Output inkompatibel → anderes Modell testen |

### 9.5 Dateistruktur (typisch)

```
DepthPrediction/
├── Sources/DepthRunner/       # Source-Code
├── Models/                    # CoreML-Modelle (nicht im Repo)
├── resource/IMG_*.PNG         # Testbilder
├── output/
│   ├── depth_map.png          # Standard-Output
│   └── qa/                    # QA-Test-Outputs
├── scripts/
│   ├── env_check.sh           # Umgebungsprüfung
│   ├── build.sh               # Build-Skript
│   ├── run_sample.sh          # Single-Image-Test
│   └── qa_smoke.sh            # Multi-Image-Tests
└── docs/ANALYSIS.md           # Diese Datei
```

---

## 10. Weiterführende Informationen

**Siehe auch:**
- `README.md` – Projekt-Übersicht, iOS-App-Infos
- `Package.swift` – Swift Package Definition
- `scripts/qa_smoke.sh` – QA-Test-Skript (bereits vorhanden)

**Externe Ressourcen:**
- [Apple CoreML Models](https://developer.apple.com/machine-learning/models/)
- [MiDaS Depth Estimation](https://github.com/isl-org/MiDaS)
- [FCRN-DepthPrediction](https://github.com/iro-cp/FCRN-DepthPrediction)

---

**Ende der Analyse.**


