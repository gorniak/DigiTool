---
name: digitize-chart
description: Extract numeric data (CSV x;y points) from a raster chart image such as a datasheet plot, scope capture or scanned graph, using DigiTool's digitool.py. Use when the user wants the values of curves in a PNG/JPG chart, a chart cropped from a PDF, or a JSON configuration for DigiTool.
---

# Digitize a chart image with DigiTool

`digitool.py` (in this directory) turns curves in a chart image into CSV files.
It detects the chart area, removes the grid, follows each trace and scales
pixels to values. Axes, log scales, title and axis labels come from OCR when
the configuration does not set them.

## Requirements

```sh
python3 -c "import numpy, PIL, matplotlib" || pip install numpy pillow matplotlib
tesseract --version || echo "OCR unavailable: set axes in the JSON by hand"
```

`scipy` and `pytesseract` are optional (speed, OCR wrapper).

## Procedure

1. **Look at the image first.** Open it with your image-reading tool and note:
   - the axis ranges and whether each axis is logarithmic,
   - how many curves there are, their colors, and their order from top to
     bottom (at the left edge of the chart, where they are separate),
   - the curve names from the legend or annotations (e.g. `25oC`, `VCC 5 V`).

2. **First run** (OCR fills the axes, a single black trace is assumed):

   ```sh
   python3 digitool.py chart.png
   ```

   Read the printed lines `Chart area ...`, `OCR x: ...`, `OCR y: ...` and
   `Points ...`. A `<stem>.json` is written when none existed.

3. **Fix the configuration** `<stem>.json` with what you saw in step 1:
   - Axes: correct `min_x`, `max_x`, `min_y`, `max_y`, `log_x`, `log_y` if OCR
     got them wrong or found none. These are the values at the **edges of
     the chart area** (the outer grid lines), not at the outermost labels if
     those differ.
   - Traces, all the same color: `"color": [r, g, b]` and
     `"traces": ["top name", "next", ...]` in top-to-bottom order.
     Black or gray curves: `"color": [0, 0, 0]`.
   - Traces in different colors:
     `"traces": [{"name": "D1", "color": [255, 0, 0]}, ...]`.
   - Unknown exact colors: pick them from pixels instead, with image
     coordinates (0-based x right, y down) of a point on each curve:
     `--pick X Y NAME` once per trace. Find such pixels with a short numpy
     script if needed (e.g. pixels where red > 200 and green, blue < 80).

4. **Re-run** and check:

   ```sh
   python3 digitool.py chart.png --save-config      # keep --pick options if used
   ```

   - Each trace should have points across most of its visible length
     (`Points name: N`; roughly the chart width in pixels for a full-width
     curve).
   - Open `<stem>_plot.png` and compare it with the original image: same
     shapes, same values at a few grid crossings, traces not swapped.
   - Spot-check a few CSV values against values you read off the image.

5. **Tune if needed** (edit the JSON, re-run):

   | Symptom                                   | Change                                      |
   |-------------------------------------------|---------------------------------------------|
   | Wrong chart area (`Chart area` box)       | `"crop": [left, top, right, bottom]` (pixels of the outer grid lines), or `--crop` |
   | Thin black curve missing / few points     | lower `trace_min_width` (e.g. 3, minimum 1) |
   | Grid lines or text digitized as a curve   | raise `trace_min_width`, raise `trace_min_span` |
   | Colored curve missing / patchy            | raise `color_tolerance` (30–100 for anti-aliased lines) |
   | Two curves merged into one                | lower `trace_min_gap`                       |
   | Short curve dropped                       | lower `trace_min_span` (e.g. 0.03)          |
   | Curve is a function of y (vertical)       | `"swap_x_y": true`, traces left to right    |
   | Image is only the plot area (no labels)   | `"crop": false` and set the axes manually   |

   Use `--save-steps` to write `<stem>_crop.png` and `<stem>_nogrid.png`:
   the second image shows exactly which pixels were kept as traces.

6. **Report** the CSV paths, point counts, axes used, and anything you are
   unsure about (e.g. a curve only partly recovered). Offer `--zip` for a
   single archive.

## Outputs

- `<stem>.csv` (one unnamed trace) or `<stem>_<name>.csv`: lines `x;y`,
  semicolon separated, no header, sorted by x (by y with `swap_x_y`).
- `<stem>_plot.png`: plot of the result, for checking.
- `<stem>.json`: configuration, reusable by `digitool.html` (web app) and
  `digitool.m` (MATLAB / Octave).

## Notes

- Points are not resampled: there is one point per pixel column of the
  chart. Resample or smooth afterwards if the user needs fixed x steps.
- Charts inside PDFs: render the page at 200–300 dpi first (e.g. with
  `pdftoppm -r 300 -png` or PyMuPDF) and crop the figure with its axis
  labels, so OCR can read them.
- Dashed curves give gaps in the CSV; that is expected.
- Do not overwrite a user's existing JSON without `--save-config` unless
  they agreed; without it the existing JSON is left as it is.
