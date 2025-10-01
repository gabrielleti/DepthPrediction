# DepthPrediction-CoreML

![platform-ios](https://img.shields.io/badge/platform-ios-lightgrey.svg)
![swift-version](https://img.shields.io/badge/swift-5.0-red.svg)
![lisence](https://img.shields.io/badge/license-MIT-black.svg)

This project is Depth Prediction on iOS with Core ML.<br>If you are interested in iOS + Machine Learning, visit [here](https://github.com/motlabs/iOS-Proejcts-with-ML-Models) you can see various DEMOs.<br>

| GIF demo 1 | Screenshot 1 | Screenshot 2 | Screenshot 3 | Screenshot 4 |
| ------------ | ------------ | ------------ | ------------ | ------------ |
| <img src="https://user-images.githubusercontent.com/37643248/99881941-428dbd80-2c60-11eb-9c24-fdab5b110279.gif" width=240px> | <img src="resource/IMG_3623.PNG" width=240px> | <img src="resource/IMG_3626.PNG" width=240px> | <img src="resource/IMG_3627.PNG" width=240px> | <img src="resource/IMG_3629.PNG" width=240px> |

## Command Line Depth Runner

This repository also includes a Swift Package executable that allows you to generate a depth map from any local image on macOS.

```bash
swift run DepthRunner path/to/input.jpg
swift run DepthRunner path/to/input.jpg --out output/my_depth.png
swift run DepthRunner path/to/input.jpg --out output/depth.png --ply output/points.ply --fov 60
swift run DepthRunner path/to/input.jpg --ply output/points.ply --fx 1450 --fy 1450 --cx 960 --cy 720
swift run DepthRunner path/to/input.jpg --fov 60 --volume --unit ml
swift run DepthRunner input.jpg --fx 1450 --fy 1450 --cx 960 --cy 720 --volume --ply output/points.ply
swift run DepthRunner input.jpg --fov 60 --volume --roi center=0.6
swift run DepthRunner input.jpg --fov 60 --volume --roi-auto --roi-margin 0.05 --roi-min-size 0.40
swift run DepthRunner input.jpg --fov 60 --volume --clip-ground --ground-percentile 0.12 --ground-eps 0.010
swift run DepthRunner input.jpg --fov 60 --clip-ground --trim-percentile 0.98 --z-band 0.10,0.80 --volume
swift run DepthRunner input.jpg --fov 60 --volume --no-auto-scale
```

The tool locates the bundled MiDaS Small Core ML model (or another depth model present in the repository), runs inference, normalizes the resulting depth values to the range `[0, 255]`, and saves a grayscale PNG where brighter pixels are closer to the camera. When `--ply` or `--xyz` outputs are requested, the normalized depth map is additionally back-projected into a filtered point cloud using either the supplied camera intrinsics (`--fx`, `--fy`, `--cx`, `--cy`) or a field-of-view estimate (`--fov`). If neither is provided, the runner warns and falls back to a 60° pinhole assumption using the depth map resolution.

Enabling `--volume` computes an axis-aligned bounding box over the filtered point cloud and logs the enclosed volume in milliliters (default), cubic centimeters, or cubic meters depending on `--unit`. You can limit the evaluation to a centered region of the depth map via `--roi center=<fraction>` or let the runner select a bounding box automatically with `--roi-auto`, which focuses on the closest percentile of valid depths and can be tuned through `--roi-near-percentile`, `--roi-margin`, and `--roi-min-size`. When table or floor pixels should be excluded from the measurement, add `--clip-ground` to fit a ground plane to the lowest depths and remove points within an epsilon band (default `ε=8 mm`, configurable through `--ground-eps`). The percentile used for plane fitting defaults to the lowest 10% of depth values and can be tuned with `--ground-percentile`. Additional trimming options clamp the point cloud to a configurable depth band via `--z-band min,max` (default `0.10,0.80`) and remove extreme x/y/z outliers with `--trim-percentile` (default `0.98`), helping stabilize the volume estimate in the presence of noisy pixels. By default the pipeline auto-scales the measured ROI to assume a 25 cm plate diameter before computing the bounding box volume; disable this developer aid with `--no-auto-scale` if you need the raw scale.

### Plausibility Logging

DepthRunner collects compact plausibility metrics once the point cloud has been filtered, clipped, and (optionally) auto-scaled so that obviously broken depth inputs do not silently produce fantasy numbers. The log block reports the number of usable points, ROI coverage, bounding boxes before/after scaling, the applied scaling factor, and the final volume in milliliters. Threshold-based warnings are emitted without aborting the run, and you can summarise them at the end by passing `--strict-warn` (useful for automated checks).

```
Points: total=18234, used=17998, roi_pixels=92160, roi_cov=36.0%
BBox[m]: pre x:[-0.059, 0.064] y:[-0.061, 0.058] z:[0.129, 0.182] | post x:[-0.064, 0.069] y:[-0.066, 0.063] z:[0.140, 0.198]
Scale: assumed=0.25 m, measured=0.2360 m, factor=1.059
Volume: 510.4 ml (0.000510 m3)
⚠️ Volume out of nominal range (510.4 ml)
WARN: volume_out_of_range
```

Warnings are normal when the underlying photo is poor or a fallback ROI had to be chosen—the runner still returns exit code `0` so downstream tooling can decide how to react.

## How it works

> When use Metal

![image](https://user-images.githubusercontent.com/37643248/100520171-bdfeea00-31df-11eb-92f5-15e17fa10962.png)

## Requirements

- Xcode 10.2+
- iOS 11.0+
- Swift 5

## Model

### Download

Download model from [apple's model page](https://developer.apple.com/machine-learning/models/).

### Matadata

|            | input node    | output node    |   size   |
| :--------: | :-----------: | :------------: | :----: |
| FCRN     | `[1, 304, 228, 3]`<br>name: `image` | `[1, 128, 160]`<br>name: `depthmap` | 254.7 MB |
| FCRNFP16 | `[1, 304, 228, 3]`<br>name: `image` | `[1, 128, 160]`<br>name: `depthmap` | 127.3 MB |

### Inference Time

| Device        | Inference Time | Total Time(GPU) | Total Time(CPU) |
| ------------- | :-----: | :-----: | :-----------: |
| iPhone 12 Pro Max | ⏲ | ⏲ | ⏲ |
| iPhone 12 Pro | ⏲ | ⏲ | ⏲ |
| iPhone 12     | ⏲ | ⏲ | ⏲ |
| iPhone 12 Mini | ⏲ | ⏲ | ⏲ |
| iPhone 11 Pro Max | ⏲ | ⏲ | ⏲ |
| iPhone 11 Pro | **134 ms**  | **134 ms** | **149 ms** |
| iPhone 11     | ⏲ | ⏲ | ⏲ |
| iPhone SE(2nd) | ⏲ | ⏲ | ⏲ |
| iPhone XS Max | 146 ms | ⏲ | 155 ms |
| iPhone XS     | 146 ms | ⏲ | 151 ms |
| iPhone XR     | 148 ms  | ⏲ | 154 ms |
| iPhone X      | 624 ms  | ⏲ | 640 ms |
| iPhone 8+     | 621 ms  | ⏲ | 634 ms |
| iPhone 8      | 626 ms  | ⏲ | 639 ms |
| iPhone 7+     | 595 ms  | ⏲ | 609 ms |
| iPhone 7      | 612 ms  | ⏲ | 624 ms |
| iPhone 6S+    | 1038 ms | ⏲ | 1051 ms |


## Local Test

### Quick Start

```bash
# 1. Umgebung prüfen
./scripts/env_check.sh

# 2. Projekt bauen
./scripts/build.sh

# 3. Beispiel ausführen (verwendet resource/IMG_3623.PNG)
./scripts/run_sample.sh

# 4. Mit eigenem Bild
INPUT=/pfad/zum/bild.jpg ./scripts/run_sample.sh

# 5. QA-Tests (mehrere Bilder)
./scripts/qa_smoke.sh
```

### Voraussetzungen

- **macOS 12.0+** (CoreML/CoreImage erforderlich)
- **Xcode 10.2+** mit Command Line Tools
- **Swift 5.7+**
- **CoreML-Modell** (z.B. MiDaS, FCRN) - [Download hier](https://developer.apple.com/machine-learning/models/)

### Skripte

| Skript | Beschreibung |
|--------|--------------|
| `scripts/env_check.sh` | Prüft Umgebung (macOS, Xcode, Swift, Frameworks) |
| `scripts/build.sh` | Baut DepthRunner im Release-Modus |
| `scripts/run_sample.sh` | Führt Single-Image-Test aus (parametrisierbar) |
| `scripts/qa_smoke.sh` | Multi-Image QA-Tests |

### Ausgabe

Alle Test-Outputs landen in `output/qa/`:
- `*_depth.png` - Normalisierte Tiefenkarte (Grayscale)
- `*.ply` - 3D-Punktwolke (PLY-Format)
- `*.log` - Volumen-Logs & Plausibilitätschecks

### Dokumentation

Siehe `docs/ANALYSIS.md` für:
- Vollständige CLI-Flag-Referenz
- Pipeline-Flow-Diagramm
- Troubleshooting-Guide
- Quick Reference (1 Seite)

## See also

- [motlabs/iOS-Proejcts-with-ML-Models](https://github.com/motlabs/iOS-Proejcts-with-ML-Models)<br>
  : The challenge using machine learning model created from tensorflow on iOS
- [iro-cp/FCRN-DepthPrediction](https://github.com/iro-cp/FCRN-DepthPrediction)<br>
  : The repository prividing FCRN-DepthPrediction model
