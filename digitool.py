#!/usr/bin/env python3
#   Copyright 2023-2026 Radoslaw Gorniak
#   Author  - Radoslaw Gorniak
#   License - MIT License
#   Website - https://github.com/gorniak/DigiTool
"""Digitize curves from a raster chart image into CSV data points.

Command line port of digitool.html (DigiTool web app): the same digitizing
engine, axis / label OCR, CSV, JSON and plot outputs, in a single file.

For an image "bjt_chart.png" the configuration is read from "bjt_chart.json"
(if it exists) and the outputs are written next to the image:

  bjt_chart.csv / bjt_chart_<trace>.csv   digitized points, "x;y" per line
  bjt_chart_plot.png                      plot of the digitized curves
  bjt_chart.json                          configuration (only if missing, or
                                          with --save-config)
  bjt_chart.zip                           all of the above and the image (--zip)

Axes missing in the configuration (min_x, max_x, min_y, max_y) are read
from the tick labels with Tesseract OCR, as are the title and axis labels
(--ocr reads them even when set). Trace colors come from the configuration
("color" / "traces") or are picked from image pixels with --pick.

Requires numpy and Pillow; matplotlib for the plot; pytesseract or the
tesseract command line tool for OCR; scipy (optional) for speed.

Examples:
  python digitool.py bjt_chart.png
  python digitool.py bjt_chart.png --pick 400 492 cold --pick 400 668 room \
                               --pick 400 964 hot
  python digitool.py bjt_chart.png --ocr --save-config --zip
"""

import argparse
import io
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from decimal import Decimal
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# ============================================================================
# Configuration defaults & constants (as in digitool.html)
# ============================================================================

DEFAULTS = {
    # Crop the image to the chart grid (false if the image is the chart area,
    # or [left, top, right, bottom] pixel bounds of the chart area)
    "crop": True,
    # Max per-channel difference to treat a pixel as the curve color
    "color_tolerance": 10,
    # Max variance of RGB channels to treat a pixel as gray
    "gray_variance": 10,
    # Min thickness in pixels of a black trace (thinner grid lines/text removed)
    "trace_min_width": 7,
    # Min horizontal extent of a trace as a fraction of chart width
    "trace_min_span": 0.1,
    # Min gap in pixels between separate traces (closer runs are merged)
    "trace_min_gap": 7,
    # Span in pixels of trace points used to estimate its slope when
    # tracking overlapping traces
    "trace_slope_span": 20,
    # Max deviation of trace derivative from its slope around a crossing
    "trace_slope_tolerance": 0.5,
    # Max deviation in pixels of a trace point from the curve fitted around
    # a crossing of traces or grid lines
    "trace_value_tolerance": 1.0,
    # Min fraction of chart width (height) covered by a grid line
    "grid_min_fill": 0.6,
    # Trace names ordered top to bottom (left to right with swap_x_y), or
    # {"name": ..., "color": [r, g, b]} entries; empty means a single trace
    "traces": [],
}

KEY_ORDER = ["title", "x_label", "y_label", "crop", "color",
             "min_x", "max_x", "log_x", "grid_x",
             "min_y", "max_y", "min_curve_y", "max_curve_y", "log_y", "grid_y",
             "swap_x_y", *DEFAULTS]

AXES_KEYS = ("min_x", "max_x", "min_y", "max_y")

# Plot colors (matplotlib tab10)
COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
          "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf"]

PICK_RADIUS = 3
PICK_TOLERANCE = 30


# ============================================================================
# Core digitizing engine
# ============================================================================

# Round half to even (Python round, as pyRound in digitool.html)
def py_round(x):
    return int(round(x))


# 1-based centers of groups of values above threshold * max (average
# position of the maximum values of each group)
def peakseek(values, threshold):
    values = np.asarray(values, dtype=float)
    if not values.size or not values.max() > 0:
        return []
    above = np.flatnonzero(values > values.max() * threshold)
    peaks = []
    for group in np.split(above, np.flatnonzero(np.diff(above) > 1) + 1):
        if group.size:
            vals = values[group]
            peaks.append(group[vals == vals.max()].mean() + 1)
    return peaks


# Bounds [left, top, right, bottom] of the chart grid (darkest rows/columns)
def chart_box(image):
    height, width = image.shape[:2]
    stat = 255.0 - image[:, :, :3].min(axis=2).astype(float)
    peaks_x = peakseek(stat.sum(axis=0), 0.9)
    peaks_y = peakseek(stat.sum(axis=1), 0.9)
    if len(peaks_x) < 2 or len(peaks_y) < 2:
        return [0, 0, width, height]
    left = max(0, min(width - 1, py_round(peaks_x[0]) - 1))
    top = max(0, min(height - 1, py_round(peaks_y[0]) - 1))
    right = max(left + 1, min(width, py_round(peaks_x[-1])))
    bottom = max(top + 1, min(height, py_round(peaks_y[-1])))
    return [left, top, right, bottom]


# Chart area box as set by the "crop" config
def crop_box(image, config):
    height, width = image.shape[:2]
    crop = config.get("crop", True)
    if crop is True or crop is None:
        return chart_box(image)
    if isinstance(crop, (list, tuple)) and len(crop) == 4:
        left = max(0, min(width - 1, int(crop[0])))
        top = max(0, min(height - 1, int(crop[1])))
        right = max(left + 1, min(width, int(crop[2])))
        bottom = max(top + 1, min(height, int(crop[3])))
        return [left, top, right, bottom]
    return [0, 0, width, height]


def gray_mask(im, gray_variance):
    im = im.astype(float)
    mean = im.mean(axis=2, keepdims=True)
    return ((im - mean) ** 2).sum(axis=2) / 2 < gray_variance


# Pixels of the given trace color (black means any dark gray)
def color_mask(im, color, config):
    if list(color) == [0, 0, 0]:
        return (im.min(axis=2) < 128) & gray_mask(im, config["gray_variance"])
    diff = np.abs(im.astype(int) - np.asarray(color, dtype=int))
    return (diff < config["color_tolerance"]).all(axis=2)


# Binary erosion (dilation) with a size x size square, outside is empty
def imerode(mask, size, dilate=False):
    size = max(1, py_round(size))
    if size <= 1:
        return mask.copy()
    pad0 = size // 2
    out = mask
    for axis in (0, 1):
        n = out.shape[axis]
        csum = np.cumsum(out, axis=axis, dtype=np.int32)
        csum = np.concatenate([np.zeros_like(np.take(csum, [0], axis=axis)),
                               csum], axis=axis)
        idx = np.arange(n)
        a = idx - pad0
        b = a + size - 1
        if dilate:
            a = np.clip(a, 0, n - 1)
            b = np.clip(b, 0, n - 1)
            count = np.take(csum, b + 1, axis=axis) - np.take(csum, a, axis=axis)
            out = count > 0
        else:
            valid = (a >= 0) & (b < n)
            ac = np.clip(a, 0, n)
            bc = np.clip(b + 1, 0, n)
            count = np.take(csum, bc, axis=axis) - np.take(csum, ac, axis=axis)
            shape = [1, 1]
            shape[axis] = n
            out = (count == size) & valid.reshape(shape)
    return out


def imopen(mask, size):
    return imerode(imerode(mask, size), size, dilate=True)


# 8-connected components as (flat pixel indices, min column, max column), in
# order of their first pixel in raster order
def components(mask):
    height, width = mask.shape
    try:
        from scipy import ndimage
        labels, count = ndimage.label(mask, structure=np.ones((3, 3), int))
        flat = labels.ravel()
        order = np.argsort(flat, kind="stable")
        bounds = np.searchsorted(flat[order], np.arange(1, count + 2))
        comps = []
        for k in range(count):
            px = order[bounds[k]:bounds[k + 1]]
            cols = px % width
            comps.append((px, int(cols.min()), int(cols.max())))
        return comps
    except ImportError:
        pass
    flat = mask.ravel()
    seen = np.zeros(flat.size, dtype=bool)
    comps = []
    for p0 in np.flatnonzero(flat):
        if seen[p0]:
            continue
        seen[p0] = True
        stack = [int(p0)]
        pixels = []
        while stack:
            p = stack.pop()
            pixels.append(p)
            y, x = divmod(p, width)
            for ny in range(max(0, y - 1), min(height, y + 2)):
                for nx in range(max(0, x - 1), min(width, x + 2)):
                    q = ny * width + nx
                    if flat[q] and not seen[q]:
                        seen[q] = True
                        stack.append(q)
        px = np.array(pixels)
        cols = px % width
        comps.append((px, int(cols.min()), int(cols.max())))
    return comps


# Remove components spanning fewer than min_span columns
def remove_short(mask, min_span):
    out = np.zeros(mask.size, dtype=bool)
    for px, lo, hi in components(mask):
        if hi - lo + 1 >= min_span:
            out[px] = True
    return out.reshape(mask.shape)


# Keep components forming at most count traces: from the widest one, a
# component is dropped where it overlaps more than max_overlap columns
# already holding count wider components
def keep_traces(mask, count, max_overlap):
    width = mask.shape[1]
    out = np.zeros(mask.size, dtype=bool)
    coverage = np.zeros(width, dtype=int)
    comps = sorted(components(mask), key=lambda c: -(c[2] - c[1]))
    for px, _, _ in comps:
        cols = np.unique(px % width)
        if (coverage[cols] >= count).sum() > max_overlap:
            continue
        coverage[cols] += 1
        out[px] = True
    return out.reshape(mask.shape)


# Remove grid and text - keep only thick strokes of trace colors.
# color_entries: list of (color, trace count)
def imremove_grid(crop, color_entries, config):
    opened = [imopen(color_mask(crop, color, config), config["trace_min_width"])
              for color, _ in color_entries]
    wide = remove_short(np.logical_or.reduce(opened),
                        config["trace_min_span"] * crop.shape[1])
    final = np.zeros(crop.shape[:2], dtype=bool)
    for op, (_, count) in zip(opened, color_entries):
        final |= keep_traces(op & wide, count, config["trace_min_gap"])
    out = np.full_like(crop, 255)
    out[final] = crop[final]
    return out


def imremove_gray(crop, gray_variance):
    out = crop.copy()
    out[gray_mask(crop, gray_variance)] = 255
    return out


def group_centers(fill, min_fill):
    above = np.flatnonzero(np.asarray(fill) >= min_fill)
    return [float(g[0] + g[-1]) / 2 + 1
            for g in np.split(above, np.flatnonzero(np.diff(above) > 1) + 1)
            if g.size]


# Removed grid lines: 1-based centers of columns and rows (from the bottom)
# whose dark pixels outside the traces fill at least grid_min_fill
def find_grid(crop, nogrid, config):
    grid = color_mask(crop, [0, 0, 0], config) & (nogrid.min(axis=2) == 255)
    return (group_centers(grid.mean(axis=0), config["grid_min_fill"]),
            group_centers(grid[::-1, :].mean(axis=1), config["grid_min_fill"]))


def median_plus1(run):
    n = len(run)
    return (run[(n - 1) // 2] + run[n // 2]) / 2 + 1


# Split pixel positions into runs, runs closer than min_gap are merged
# unless both are at least min_len thick
def split_runs(hits, min_gap, min_len):
    raw = np.split(hits, np.flatnonzero(np.diff(hits) > 1) + 1)
    out = [list(raw[0])]
    for run in raw[1:]:
        prev = out[-1]
        if run[0] - prev[-1] > min_gap or (len(run) >= min_len
                                           and len(prev) >= min_len):
            out.append(list(run))
        else:
            prev.extend(run)
    return out


# Median thickness of runs in columns where all traces are separate
def trace_width(col_hits, trace_count, min_gap):
    lengths = []
    for hits in col_hits:
        if not hits.size:
            continue
        runs = np.split(hits, np.flatnonzero(np.diff(hits) > min_gap) + 1)
        if len(runs) == trace_count:
            lengths += [len(r) for r in runs]
    if not lengths:
        return 1.0
    lengths.sort()
    n = len(lengths)
    return (lengths[(n - 1) // 2] + lengths[n // 2]) / 2


# Extrapolate trace to pos from a line fitted to its last points within span
def predict(history, pos, span):
    if not history:
        return None
    min_x = history[-1][0] - span
    recent = [p for p in history[-span:] if p[0] > min_x]
    if len(recent) < 2:
        return history[-1][1]
    xs = np.array([p[0] for p in recent], dtype=float)
    ys = np.array([p[1] for p in recent], dtype=float)
    mx, my = xs.mean(), ys.mean()
    den = ((xs - mx) ** 2).sum()
    if den == 0:
        return my
    return ((xs - mx) * (ys - my)).sum() / den * (pos - mx) + my


# Order-preserving selection of len(order) runs nearest to the predictions
def select_runs(runs, preds, order):
    R, K = len(runs), len(order)
    medians = [median_plus1(r) for r in runs]
    inf = math.inf
    dp = [[inf] * (R + 1) for _ in range(K + 1)]
    pick = [[False] * R for _ in range(K)]
    dp[K] = [0.0] * (R + 1)
    for m in range(K - 1, -1, -1):
        target = preds[order[m]]
        for r in range(R - (K - m), m - 1, -1):
            take = abs(medians[r] - target) + dp[m + 1][r + 1]
            skip = dp[m][r + 1] if r + 1 <= R - (K - m) else inf
            if take <= skip:
                dp[m][r] = take
                pick[m][r] = True
            else:
                dp[m][r] = skip
    kept, r = [], 0
    for m in range(K):
        while not pick[m][r]:
            r += 1
        kept.append(runs[r])
        r += 1
    return kept


# Permutation of order minimizing sum |centers[r] - preds[perm[r]]|
def best_permutation(order, centers, preds):
    K = len(order)
    if K <= 7:
        best = [math.inf, list(order)]
        used = [False] * K
        cur = [0] * K

        def dfs(depth, cost):
            if cost >= best[0]:
                return
            if depth == K:
                best[0], best[1] = cost, list(cur)
                return
            for i in range(K):
                if used[i]:
                    continue
                used[i] = True
                cur[depth] = order[i]
                dfs(depth + 1, cost + abs(centers[depth] - preds[order[i]]))
                used[i] = False

        dfs(0, 0.0)
        return best[1]
    desc = centers[0] > centers[K - 1]
    return sorted(order, key=lambda k: -preds[k] if desc else preds[k])


# Partition of order into G non-empty contiguous groups of minimal cost
def best_groups(order, G, group_cost):
    K = len(order)
    if G == 1:
        return [list(order)]
    inf = math.inf
    dp = [[inf] * (K + 1) for _ in range(G + 1)]
    next_cut = [[0] * K for _ in range(G)]
    dp[G][K] = 0.0
    for r in range(G - 1, -1, -1):
        for s in range(r, K - (G - r) + 1):
            best, best_end = inf, s + 1
            for e in range(s + 1, K - (G - 1 - r) + 1):
                c = group_cost(r, s, e) + dp[r + 1][e]
                if c < best:
                    best, best_end = c, e
            dp[r][s] = best
            next_cut[r][s] = best_end
    groups, s = [], 0
    for r in range(G):
        e = next_cut[r][s]
        groups.append(list(order[s:e]))
        s = e
    return groups


# Centered and scaled quadratic least squares fit: (value, derivative)
# functions
def polyfit2(x, y):
    mx = x.mean()
    scale = np.abs(x - mx).max() or 1.0
    u = (x - mx) / scale
    s1, s2, s3, s4 = u.sum(), (u ** 2).sum(), (u ** 3).sum(), (u ** 4).sum()
    t0, t1, t2 = y.sum(), (u * y).sum(), (u ** 2 * y).sum()
    A = [[s4, s3, s2, t2], [s3, s2, s1, t1], [s2, s1, float(len(x)), t0]]
    for col in range(3):
        piv = max(range(col, 3), key=lambda r: abs(A[r][col]))
        A[col], A[piv] = A[piv], A[col]
        diag = A[col][col]
        if abs(diag) < 1e-14:
            continue
        for row in range(col + 1, 3):
            f = A[row][col] / diag
            for k in range(col, 4):
                A[row][k] -= f * A[col][k]
    c = A[2][3] / A[2][2] if abs(A[2][2]) > 1e-14 else 0.0
    b = (A[1][3] - A[1][2] * c) / A[1][1] if abs(A[1][1]) > 1e-14 else 0.0
    a = (A[0][3] - A[0][1] * b - A[0][2] * c) / A[0][0] \
        if abs(A[0][0]) > 1e-14 else 0.0

    def value(v):
        w = (v - mx) / scale
        return (a * w + b) * w + c

    def deriv(v):
        return (2 * a * (v - mx) / scale + b) / scale

    return value, deriv


# Crossings (first overlapped column, first separated column) as areas,
# long overlaps split into their edges
def crossing_areas(crossings, span):
    areas = []
    for first, last in crossings:
        if last - first > 2 * span:
            areas += [(first, first), (last, last)]
        else:
            areas.append((first, last))
    return areas


# Areas where trace x, y crosses grid lines, widened by the trace width
def grid_areas(x, y, grid_x, grid_y, width, span):
    areas = [(g - width, g + width) for g in grid_x]
    for g in grid_y:
        near = x[np.abs(y - g) <= width]
        for group in np.split(near, np.flatnonzero(np.diff(near) > 1) + 1):
            if group.size and group[-1] - group[0] <= span:
                areas.append((group[0], group[-1]))
    return areas


# Remove points of trace in disturbed areas (crossings of traces or grid
# lines) deviating from a quadratic fitted around the area
def remove_disturbed(x, y, areas, span, slope_tol, value_tol):
    n = len(x)
    if not n:
        return x, y
    keep = np.ones(n, dtype=bool)
    half = span // 2
    for first, last in areas:
        lo, hi = first - half, last + half
        win = (x >= lo - span) & (x <= hi + span)
        area = (x >= lo) & (x <= hi)
        around = win & ~area & keep
        if around.sum() > 3:
            value, _ = polyfit2(x[around], y[around])
            if np.abs(y[around] - value(x[around])).max() > 2 * value_tol:
                continue
        while True:
            fit = win & keep
            idx = np.flatnonzero(area & keep)
            if fit.sum() < half or not idx.size:
                break
            value, deriv = polyfit2(x[fit], y[fit])
            kept = np.flatnonzero(keep)
            pos = np.searchsorted(kept, idx)
            lo_idx = kept[np.maximum(pos - 2, 0)]
            hi_idx = kept[np.minimum(pos + 2, len(kept) - 1)]
            dx = x[hi_idx] - x[lo_idx]
            with np.errstate(divide="ignore", invalid="ignore"):
                d = np.where(dx != 0, (y[hi_idx] - y[lo_idx]) / dx, 0.0)
            score = np.maximum(np.abs(d - deriv(x[idx])) / slope_tol,
                               np.abs(y[idx] - value(x[idx])) / value_tol)
            worst = int(score.argmax())
            if score[worst] <= 1:
                break
            keep[idx[worst]] = False
    return x[keep], y[keep]


# Pixel points (x, y) of trace_count traces of color, 1-based in the
# cropped image, y counted from the bottom. Traces are ordered top to
# bottom (left to right with swap_x_y); crossing traces are tracked by
# their slope.
def digitalize(nogrid, color, tolerance, trace_count, min_gap, swap_x_y,
               slope_span, slope_tol, value_tol, grid_x, grid_y):
    diff = np.abs(nogrid.astype(int) - np.asarray(color, dtype=int))
    match = (diff < tolerance).all(axis=2)[::-1, :]
    if swap_x_y:
        match = match.T
        grid_x, grid_y = grid_y, grid_x
    col_hits = [np.flatnonzero(match[:, j]) for j in range(match.shape[1])]
    width = trace_width(col_hits, trace_count, min_gap)
    top_down = trace_count > 1 and not swap_x_y
    points = [[] for _ in range(trace_count)]
    history = [[] for _ in range(trace_count)]
    order = list(range(trace_count))
    overlap_len = 0
    merged_since = [None] * trace_count
    crossings = [[] for _ in range(trace_count)]

    for j, hits in enumerate(col_hits):
        if not hits.size:
            continue
        if trace_count == 1:
            points[0].append((j + 1, median_plus1(hits)))
            continue
        runs = split_runs(hits, min_gap, 0.6 * width)
        if top_down:
            runs.reverse()
        preds = [predict(history[k], j + 1, slope_span)
                 for k in range(trace_count)]
        known = all(p is not None for p in preds)
        if len(runs) > trace_count:
            if known:
                runs = select_runs(runs, preds, order)
            else:
                idx = sorted(range(len(runs)), key=lambda r: -len(runs[r]))
                runs = [runs[r] for r in sorted(idx[:trace_count])]
        centers = [median_plus1(r) for r in runs]
        if len(runs) == trace_count:
            if overlap_len and known:
                order = best_permutation(order, centers, preds)
            overlap_len = 0
            groups = [[k] for k in order]
        else:
            overlap_len += 1
            if known:
                groups = best_groups(order, len(runs), lambda r, s, e: sum(
                    abs(centers[r] - preds[order[m]]) for m in range(s, e)))
            else:
                groups = best_groups(order, len(runs), lambda r, s, e: abs(
                    len(runs[r]) / width - (e - s)))
        weight = max(0.0, 1 - overlap_len / (2 * slope_span))
        for run, center, group in zip(runs, centers, groups):
            for k in group:
                if len(group) == 1:
                    history[k].append((j + 1, center))
                    points[k].append((j + 1, center))
                    if merged_since[k] is not None:
                        crossings[k].append((merged_since[k], j + 1))
                        merged_since[k] = None
                else:
                    if merged_since[k] is None:
                        merged_since[k] = j + 1
                    if preds[k] is None:
                        points[k].append((j + 1, center))
                        continue
                    pred = min(max(preds[k], run[0] + 1), run[-1] + 1)
                    points[k].append((j + 1, weight * pred
                                      + (1 - weight) * center))

    traces = []
    for k in range(trace_count):
        pts = np.array(points[k], dtype=float).reshape(-1, 2)
        x, y = pts[:, 0], pts[:, 1]
        areas = crossing_areas(crossings[k], slope_span) + \
            grid_areas(x, y, grid_x, grid_y, width, slope_span)
        x, y = remove_disturbed(x, y, areas, slope_span, slope_tol, value_tol)
        traces.append((y, x) if swap_x_y else (x, y))
    return traces


# Digitize traces [(name, color)] of chart image (RGB array). Returns
# dict with box, crop and nogrid images and raw pixel traces (in order).
def digitize(image, config, traces):
    config = {**DEFAULTS, **config}
    box = crop_box(image, config)
    left, top, right, bottom = box
    crop = image[top:bottom, left:right, :3].copy()
    # Unique colors in trace order with their trace indices
    entries = {}
    for idx, (_, color) in enumerate(traces):
        entries.setdefault(tuple(int(c) for c in color[:3]), []).append(idx)
    color_entries = [(c, len(i)) for c, i in entries.items()]
    if (0, 0, 0) in entries or len(entries) > 1:
        nogrid = imremove_grid(crop, color_entries, config)
    else:
        nogrid = imremove_gray(crop, config["gray_variance"])
    grid_x, grid_y = find_grid(crop, nogrid, config)
    raw = [None] * len(traces)
    for color, indices in entries.items():
        pts = digitalize(nogrid, color, config["color_tolerance"],
                         len(indices), config["trace_min_gap"],
                         bool(config.get("swap_x_y")),
                         config["trace_slope_span"],
                         config["trace_slope_tolerance"],
                         config["trace_value_tolerance"], grid_x, grid_y)
        for idx, p in zip(indices, pts):
            raw[idx] = p
    return {"box": box, "crop": crop, "nogrid": nogrid, "raw": raw}


# ============================================================================
# Color picking, scaling, configuration, CSV
# ============================================================================

# Trace color at image pixel (x, y): the most common strong color nearby,
# black for dark gray
def pick_color(image, x, y):
    h, w = image.shape[:2]
    patch = image[max(0, y - PICK_RADIUS):min(h - 1, y + PICK_RADIUS) + 1,
                  max(0, x - PICK_RADIUS):min(w - 1, x + PICK_RADIUS) + 1, :3]
    px = patch.reshape(-1, 3).astype(int)
    strength = 255 - px.min(axis=1) + (px.max(axis=1) - px.min(axis=1))
    strong = px[strength >= 0.8 * strength.max()]
    sstr = strength[strength >= 0.8 * strength.max()]
    counts = (np.abs(strong[:, None, :] - strong[None, :, :])
              < PICK_TOLERANCE).all(axis=2).sum(axis=1)
    cand = np.flatnonzero(counts == counts.max())
    best = strong[cand[np.argmax(sstr[cand])]]
    r, g, b = (int(v) for v in best)
    mean = (r + g + b) / 3
    var = ((r - mean) ** 2 + (g - mean) ** 2 + (b - mean) ** 2) / 2
    if max(r, g, b) < 128 and var < DEFAULTS["gray_variance"]:
        return [0, 0, 0]
    return [r, g, b]


def scale_linear(pts, min_p, max_p, min_v, max_v):
    pts = np.asarray(pts, dtype=float)
    if min_p == max_p:
        return np.full_like(pts, float(min_v))
    a = (min_v - max_v) / (min_p - max_p)
    return a * pts + (min_v - a * min_p)


def scale_log(pts, min_p, max_p, min_v, max_v):
    return 10 ** scale_linear(pts, min_p, max_p, math.log10(min_v),
                              math.log10(max_v))


# Chart values of raw pixel points of the cropped image
def scale_points(raw, crop_w, crop_h, cfg):
    px, py = raw
    sx = (scale_log if cfg.get("log_x") else scale_linear)(
        px, 1, crop_w, cfg["min_x"], cfg["max_x"])
    if cfg.get("log_y"):
        sy = scale_log(py, 1, crop_h, cfg["min_y"], cfg["max_y"])
    else:
        sy = scale_linear(py, 1, crop_h, cfg["min_y"], cfg["max_y"])
        if isinstance(cfg.get("min_curve_y"), (int, float)) and \
                isinstance(cfg.get("max_curve_y"), (int, float)) and sy.size:
            if sy.max() > sy.min():
                sy = scale_linear(sy, sy.min(), sy.max(), cfg["min_curve_y"],
                                  cfg["max_curve_y"])
    return sx, sy


# Number as %.16g (CSV format of digitool.html)
def fmt_g16(v):
    v = float(v)
    if not math.isfinite(v):
        return str(v)
    if v == 0:
        return "0"
    exp = math.floor(math.log10(abs(v)))
    if exp < -4 or exp >= 16:
        mant, e = f"{v:.15e}".split("e")
        mant = re.sub(r"\.?0+$", "", mant)
        e = int(e)
        return f"{mant}e{'+' if e >= 0 else '-'}{abs(e):02d}"
    s = repr(float(f"{v:.16g}"))
    if "e" in s:
        s = format(Decimal(s), "f")
    return s[:-2] if s.endswith(".0") else s


def format_csv(xs, ys):
    return "".join(f"{fmt_g16(x)};{fmt_g16(y)}\n" for x, y in zip(xs, ys))


# Traces as [name, color] pairs from config ([] without color and traces)
def config_traces(cfg):
    if "color" not in cfg and not (isinstance(cfg.get("traces"), list)
                                   and cfg["traces"]):
        return []
    base = list(cfg["color"][:3]) if isinstance(cfg.get("color"), list) \
        else [0, 0, 0]
    traces = cfg.get("traces") or []
    if not traces:
        return [[None, base]]
    return [[t.get("name"), list(t.get("color", base))[:3]]
            if isinstance(t, dict) else [str(t), list(base)]
            for t in traces]


def is_default(key, value):
    if key == "swap_x_y":
        return not value
    return key in DEFAULTS and value == DEFAULTS[key]


# Configuration to save: traces folded into color/traces, defaults dropped
# unless in the file, keys in file order then KEY_ORDER
def build_saved_config(cfg, traces, file_keys):
    out = {k: v for k, v in cfg.items() if k != "traces"}
    out["traces"] = []
    colors = {tuple(c) for _, c in traces}
    if len(colors) == 1:
        out["color"] = traces[0][1]
        out["traces"] = [n for n, _ in traces if n is not None]
    elif traces:
        out.pop("color", None)
        out["traces"] = [{"name": n if n is not None else f"trace{i + 1}",
                          "color": c} for i, (n, c) in enumerate(traces)]
    order = list(file_keys) + [k for k in KEY_ORDER if k not in file_keys]
    keys = [k for k in out if k in file_keys or not is_default(k, out[k])]
    keys.sort(key=lambda k: order.index(k) if k in order else 999)
    return {k: out[k] for k in keys}


# JSON value as JavaScript JSON.stringify writes it
def js_json(value):
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        v = float(value)
        if not math.isfinite(v):
            return "null"
        if v.is_integer() and abs(v) < 1e21:
            return str(int(v))
        s = repr(v)
        if 1e-6 <= abs(v) < 1e21 and "e" in s:
            s = format(Decimal(s), "f")
        elif "e" in s:
            mant, e = s.split("e")
            s = f"{mant}e{'+' if int(e) >= 0 else '-'}{abs(int(e))}"
        return s
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(js_json(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(f"{json.dumps(k)}:{js_json(v)}"
                              for k, v in value.items()) + "}"
    return json.dumps(value)


# JSON text formatted as digitool.html (one key per line, one colored trace
# per line)
def serialize_config(cfg):
    lines = []
    for key, value in cfg.items():
        if key == "traces" and isinstance(value, list) and \
                any(isinstance(t, dict) for t in value):
            items = ",\n".join(
                f'    {{"name" : {js_json(t["name"])}, "color" : '
                f'[{", ".join(js_json(c) for c in t["color"])}]}}'
                for t in value)
            lines.append(f'  "{key}" : [\n{items}\n  ]')
        elif isinstance(value, list):
            lines.append(f'  "{key}" : [{", ".join(js_json(v) for v in value)}]')
        else:
            lines.append(f'  "{key}" : {js_json(value)}')
    return "{\n" + ",\n".join(lines) + "\n}\n"


# Error message if the axes cannot scale the points, None if they can
def axes_problem(cfg):
    missing = [k for k in AXES_KEYS if not isinstance(cfg.get(k), (int, float))
               or isinstance(cfg.get(k), bool)
               or not math.isfinite(cfg[k])]
    if missing:
        return f"set {', '.join(missing)} in the JSON configuration " \
               "(axes not recognized by OCR)"
    if cfg["min_x"] == cfg["max_x"]:
        return "min_x and max_x must differ"
    if cfg["min_y"] == cfg["max_y"]:
        return "min_y and max_y must differ"
    if cfg.get("log_x") and not (cfg["min_x"] > 0 and cfg["max_x"] > 0):
        return "log_x requires min_x > 0 and max_x > 0"
    if cfg.get("log_y") and not (cfg["min_y"] > 0 and cfg["max_y"] > 0):
        return "log_y requires min_y > 0 and max_y > 0"
    return None


def csv_name(stem, name):
    return f"{stem}_{name}.csv" if name else f"{stem}.csv"


# ============================================================================
# Plot (PNG) of the digitized curves
# ============================================================================

def plot_png(curves, cfg, stem, show=False):
    try:
        import matplotlib
        if not show:
            matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return None
    fig, ax = plt.subplots(figsize=(9, 6))
    for k, (label, (x, y)) in enumerate(curves):
        ax.plot(x, y, color=COLORS[k % len(COLORS)], linewidth=1.8,
                label=label)
    if len(curves) > 1:
        ax.legend()
    if cfg.get("log_x"):
        ax.set_xscale("log")
    if cfg.get("log_y"):
        ax.set_yscale("log")
    ax.set_xlim(cfg["min_x"], cfg["max_x"])
    ax.set_ylim(cfg["min_y"], cfg["max_y"])
    ax.grid(True, which="major", alpha=0.6)
    ax.grid(True, which="minor", alpha=0.25)
    if cfg.get("title"):
        ax.set_title(cfg["title"], fontweight="bold")
    if cfg.get("x_label"):
        ax.set_xlabel(cfg["x_label"])
    if cfg.get("y_label"):
        ax.set_ylabel(cfg["y_label"])
    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=150)
    if show:
        plt.show()
    plt.close(fig)
    return buf.getvalue()


# ============================================================================
# Axis & label recognition (Tesseract OCR)
# ============================================================================

SUPERSCRIPTS = {"⁻": "-", "⁰": "0", "¹": "1", "²": "2", "³": "3",
                "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9"}
SI_PREFIX = {"p": 1e-12, "n": 1e-9, "u": 1e-6, "µ": 1e-6, "μ": 1e-6,
             "m": 1e-3, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9}
_SUPER_RE = re.compile("[" + "".join(SUPERSCRIPTS) + "]+")
_POW_RE = re.compile(r"^([-+]?\d*\.?\d*)[x×*·]?10\^([-+]?\d{1,3})$")
_NEG_POW_RE = re.compile(r"^10[-~](\d{1,2})$")
_NUM_RE = re.compile(r"^([-+]?[\dOoIl]*[.,]?[\dOoIl]*\d[\dOoIl]*)"
                     r"([eE][-+]?\d{1,3})?([pnuµμmkKMG])?"
                     r"(A|V|W|Hz|s|Ω|F|H|°C|°|%|dB)?$")
_CAPTION_RE = re.compile(r"^fig(ure|\.)?\s*\d", re.IGNORECASE)


def _g(value, digits):
    return float(f"{value:.{digits}g}")


# Number of a tick label: (value, alts, pow) or None. pow is set for labels
# written as powers of ten (10^3, 10⁻³, 10-3). alts are powers of ten the
# label may be when read without its superscript: "103" for 10³, "1073" for
# 10⁻³ (superscript minus misread as 7), "10°" for 10⁰. Handles unicode
# minus, superscripts, 1e-3, 2x10^3, SI prefixes (10m, 1k), thousands
# separators, decimal commas, units (5V, 20%) and O/l misreads.
def parse_tick_number(raw):
    s = _SUPER_RE.sub(lambda m: "^" + "".join(SUPERSCRIPTS[c]
                                              for c in m.group()), str(raw))
    s = re.sub("[−–—‐‑]", "-", s)
    s = re.sub(r"\s+", "", s)
    s = re.sub(r"^[(\[{'\"`|:;]+", "", s)
    s = re.sub(r"[)\]}'\"`|:;,]+$", "", s)
    s = re.sub(r"\.$", "", s)
    if s in ("O", "o"):
        s = "0"
    if not s or not re.search(r"\d", s):
        return None
    m = _POW_RE.match(s)
    if m:
        try:
            mant = {"": 1.0, "+": 1.0, "-": -1.0}.get(m[1])
            mant = float(m[1]) if mant is None else mant
            value = mant * 10.0 ** int(m[2])
        except (ValueError, OverflowError):
            return None
        return (_g(value, 12), [], True) if math.isfinite(value) else None
    m = _NEG_POW_RE.match(s)
    if m:
        return 10.0 ** -int(m[1]), [], True
    m = _NUM_RE.match(s)
    if not m:
        return None
    num = m[1].translate(str.maketrans("OoIl", "0011"))
    num = num.replace(",", "") if re.fullmatch(r"[-+]?\d{1,3},\d{3}", num) \
        else num.replace(",", ".")
    try:
        value = float(num + (m[2] or ""))
    except ValueError:
        return None
    if not math.isfinite(value):
        return None
    if m[3]:
        value = _g(value * SI_PREFIX[m[3]], 12)
    alts = []
    if not m[2] and not m[3]:
        if num == "10" and m[4] == "°":
            alts.append(1.0)
        e = re.fullmatch(r"10(\d{1,3})", num)
        if e:
            if len(e[1]) <= 2 and int(e[1]) <= 15:
                alts.append(10.0 ** int(e[1]))
            if len(e[1]) >= 2 and e[1][0] == "7":
                alts.append(10.0 ** -int(e[1][1:]))
    return value, alts, False


def is_power_of_ten(v):
    return v > 0 and abs(math.log10(v) - round(math.log10(v))) < 1e-9


class AxisFit:
    def __init__(self, mode, log, a, b, tol, inliers, data, resid):
        self.mode, self.log, self.a, self.b = mode, log, a, b
        self.tol, self.inliers, self.all, self.resid = tol, inliers, data, resid

    def value_at(self, pos):
        t = self.a * pos + self.b
        return 10.0 ** t if self.log else t

    def pos_at(self, value):
        if self.log and value <= 0:
            return math.nan
        return ((math.log10(value) if self.log else value) - self.b) / self.a


# Robust (all pairs, inlier count) fit of tick values to pixel positions,
# linear or log10. labels: dicts with poss (alternative positions), val,
# alts, pow, conf. Returns the better model (AxisFit) or None.
def fit_axis(labels, axis_len):
    tol = max(3.0, axis_len * 0.012)
    with_alt = sum(1 for lab in labels if lab["alts"])
    # Labels written as powers of ten: log axis of powers of ten only
    pow_axis = any(lab["pow"] for lab in labels)
    fits = []
    for mode, log in (("plain", False), ("plain", True), ("alt", True)):
        if (mode == "alt" and not with_alt) or (pow_axis and not log):
            continue
        data = []
        for lab in labels:
            for v in (lab["alts"] if mode == "alt" and lab["alts"]
                      else [lab["val"]]):
                if (log and v <= 0) or (pow_axis and not is_power_of_ten(v)):
                    continue
                data.append({"poss": lab["poss"], "pos": lab["poss"][0],
                             "v": v, "label": lab,
                             "t": math.log10(v) if log else v})
        best = None
        for i, di in enumerate(data):
            for dj in data[i + 1:]:
                if di["t"] == dj["t"] or di["label"] is dj["label"]:
                    continue
                for pi in di["poss"]:
                    for pj in dj["poss"]:
                        if abs(pi - pj) < 2:
                            continue
                        a = (dj["t"] - di["t"]) / (pj - pi)
                        if log and abs(a) * axis_len > 20:
                            continue  # over 20 decades: misread labels
                        b = di["t"] - a * pi
                        resid, inl = 0.0, []
                        for d in data:
                            p = (d["t"] - b) / a
                            q = min(d["poss"], key=lambda q: abs(p - q))
                            r = abs(p - q)
                            if r <= tol and not any(x["label"] is d["label"]
                                                    for x in inl):
                                resid += r
                                inl.append({**d, "pos": q})
                        # More inliers, then smaller residual, then wider
                        # span, then higher OCR confidence
                        span = (max(d["pos"] for d in inl)
                                - min(d["pos"] for d in inl)) if inl else 0
                        key = (len(inl), -math.floor(resid / (tol / 4)),
                               math.floor(span / tol),
                               sum(d["label"]["conf"] for d in inl))
                        if best is None or key > best[2]:
                            best = (inl, resid, key)
        if best is None or len(best[0]) < 2:
            continue
        inl = best[0]
        n = len(inl)
        mp = sum(d["pos"] for d in inl) / n
        mt = sum(d["t"] for d in inl) / n
        den = sum((d["pos"] - mp) ** 2 for d in inl)
        if den == 0:
            continue
        a = sum((d["pos"] - mp) * (d["t"] - mt) for d in inl) / den
        if not math.isfinite(a) or a == 0:
            continue
        fits.append(AxisFit(mode, log, a, mt - a * mp, tol, inl, data,
                            best[1] / n))
    if not fits:
        return None
    fits.sort(key=lambda f: (-len(f.inliers), f.resid))
    tied = [f for f in fits if len(f.inliers) == len(fits[0].inliers)]
    # Labels like "103" (10³ without superscript) on most ticks
    alt = next((f for f in tied if f.mode == "alt"), None)
    if alt and with_alt >= 0.75 * len(labels):
        return alt
    lin = next((f for f in tied if f.mode == "plain" and not f.log), None)
    log_fit = next((f for f in tied if f.mode == "plain" and f.log), None)
    if lin and log_fit:
        # Tie (typically 2 labels): log if all labels are powers of ten
        return log_fit if all(is_power_of_ten(d["v"])
                              for d in log_fit.inliers) else lin
    return fits[0]


# Axis value at pixel position pos, snapped to a label value or a round
# number whose position is within the fit tolerance
def edge_value(fit, pos):
    best = None
    for d in fit.all:
        p = fit.pos_at(d["v"])
        if math.isfinite(p) and abs(p - pos) <= fit.tol and \
                (best is None or abs(p - pos) < best[1]):
            best = (d["v"], abs(p - pos))
    if best:
        return best[0]
    raw = fit.value_at(pos)
    candidates = []
    if fit.log:
        e = math.floor(math.log10(raw))
        for k in (e - 1, e, e + 1):
            candidates += [_g(m * 10.0 ** k, 12) for m in range(1, 10)]
    else:
        vals = sorted(d["v"] for d in fit.inliers)
        diffs = sorted(d for d in np.diff(vals) if d > 0)
        step = diffs[len(diffs) // 2] if diffs else (abs(raw) or 1.0)
        for div in (1, 2, 4, 5, 10):
            q = step / div
            candidates.append(_g(round(raw / q) * q, 12))
    for c in candidates:
        p = fit.pos_at(c)
        if math.isfinite(p) and abs(p - pos) <= fit.tol / 2 and \
                (best is None or abs(p - pos) < best[1]):
            best = (c, abs(p - pos))
    return best[0] if best else _g(raw, 4)


# Group words into text lines (vertical overlap, small horizontal gaps)
def group_lines(words):
    lines = []
    for w in sorted(words, key=lambda w: w["x0"]):
        h = w["y1"] - w["y0"]
        for ln in lines:
            overlap = min(ln["y1"], w["y1"]) - max(ln["y0"], w["y0"])
            gap = w["x0"] - ln["x1"]
            if overlap > 0.5 * min(h, ln["h"]) and \
                    -h < gap < 2.5 * max(h, ln["h"]):
                ln["words"].append(w)
                ln["x1"] = max(ln["x1"], w["x1"])
                ln["y0"] = min(ln["y0"], w["y0"])
                ln["y1"] = max(ln["y1"], w["y1"])
                ln["h"] = max(ln["h"], h)
                break
        else:
            lines.append({"words": [w], "x0": w["x0"], "y0": w["y0"],
                          "x1": w["x1"], "y1": w["y1"], "h": h})
    for ln in lines:
        text = " ".join(w["text"] for w in ln["words"])
        ln["text"] = re.sub(r"\s+", " ", re.sub(r"[|_]+", " ", text)).strip()
        ln["conf"] = sum(w["conf"] for w in ln["words"]) / len(ln["words"])
        ln["cx"] = (ln["x0"] + ln["x1"]) / 2
        ln["letters"] = len(re.findall(r"[A-Za-z]", ln["text"]))
    return [ln for ln in lines if ln["letters"] >= 2]


# Image region [x0, y0, x1, y1] upscaled by scale, mask_box painted white.
# rotate 1 turns text reading bottom-to-top horizontal, -1 top-to-bottom.
def ocr_image(image, region, scale, mask_box=None, rotate=0):
    im = Image.fromarray(np.ascontiguousarray(image[:, :, :3]))
    if mask_box is not None:
        left, top, right, bottom = mask_box
        ImageDraw.Draw(im).rectangle([left - 2, top - 2, right + 1,
                                      bottom + 1], fill=(255, 255, 255))
    im = im.crop(tuple(int(v) for v in region))
    if scale != 1:
        im = im.resize((max(1, round(im.width * scale)),
                        max(1, round(im.height * scale))), Image.LANCZOS)
    if rotate == 1:
        im = im.rotate(-90, expand=True)
    elif rotate == -1:
        im = im.rotate(90, expand=True)
    return im


# Words recognized by Tesseract (psm 11, sparse text): dicts with text,
# conf, x0, y0, x1, y1
def ocr_words(im, psm=11):
    try:
        import pytesseract
        data = pytesseract.image_to_data(
            im, config=f"--psm {psm} -c preserve_interword_spaces=1",
            output_type=pytesseract.Output.DICT)
        rows = zip(data["text"], data["conf"], data["left"], data["top"],
                   data["width"], data["height"])
    except ImportError:
        if not shutil.which("tesseract"):
            raise RuntimeError("OCR needs pytesseract or the tesseract "
                               "command line tool")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ocr.png"
            im.save(path)
            out = subprocess.run(
                ["tesseract", str(path), "stdout", "--psm", str(psm),
                 "-c", "preserve_interword_spaces=1", "tsv"],
                capture_output=True, text=True, encoding="utf-8",
                check=True).stdout
        rows = []
        for line in out.splitlines()[1:]:
            cols = line.split("\t")
            if len(cols) >= 12:
                rows.append((cols[11], cols[10], int(cols[6]), int(cols[7]),
                             int(cols[8]), int(cols[9])))
    words = []
    for text, conf, left, top, width, height in rows:
        text, conf = str(text).strip(), float(conf)
        if text and conf >= 20:
            words.append({"text": text, "conf": conf, "x0": left, "y0": top,
                          "x1": left + width, "y1": top + height})
    return words


# Best text line of OCR passes over a rotated strip (vertical axis label)
def recognize_rotated_label(image, region, scale):
    best = None
    for rotate in (1, -1):
        words = ocr_words(ocr_image(image, region, scale, rotate=rotate))
        for ln in group_lines([w for w in words if w["conf"] >= 40]):
            score = ln["letters"] * ln["conf"]
            if best is None or score > best[2]:
                best = (ln["text"], ln["conf"], score)
        if best and best[1] >= 75:
            break
    return best and best[0]


# Recognize axes and labels of chart image with chart area box. Returns
# (values, report lines): min_x, max_x, log_x, grid_x (and y) for the axes
# found, title, x_label, y_label for the labels found.
def detect_axes(image, box):
    img_h, img_w = image.shape[:2]
    left, top, right, bottom = (int(v) for v in box)
    if left <= 1 and top <= 1 and right >= img_w - 1 and bottom >= img_h - 1:
        raise ValueError("chart area covers the whole image, no axis labels "
                         "outside it to read")
    scale = min(3, max(1, math.floor(1600 / img_w + 0.5)))
    words = []
    for w in ocr_words(ocr_image(image, (0, 0, img_w, img_h), scale, box)):
        o = {"text": w["text"], "conf": w["conf"],
             "x0": w["x0"] / scale, "y0": w["y0"] / scale,
             "x1": w["x1"] / scale, "y1": w["y1"] / scale}
        o["h"] = o["y1"] - o["y0"]
        o["cx"] = (o["x0"] + o["x1"]) / 2
        o["cy"] = (o["y0"] + o["y1"]) / 2
        o["num"] = parse_tick_number(o["text"])
        words.append(o)
    W, H = right - left, bottom - top
    numeric = [w for w in words if w["num"] and w["conf"] >= 35]

    # X tick labels: the fullest row of numbers below the chart area
    x_cands = sorted((w for w in numeric
                      if bottom - 0.5 * w["h"] <= w["y0"]
                      <= bottom + max(4 * w["h"], 0.15 * H)
                      and left - 0.06 * W <= w["cx"] <= right + 0.06 * W
                      and w["x1"] > left + 0.3 * w["h"]),
                     key=lambda w: w["y0"])
    x_row = []
    for seed in x_cands:
        row = [w for w in x_cands
               if abs(w["cy"] - seed["cy"]) < 0.7 * seed["h"]]
        if len(row) > len(x_row):
            x_row = row

    # Y tick labels: nearest column of numbers left of the chart area
    y_cands = sorted((w for w in numeric
                      if left - 0.35 * W <= w["x1"] <= left + 0.5 * w["h"]
                      and top - 1.5 * w["h"] <= w["cy"]
                      <= bottom + 1.5 * w["h"]
                      and not any(w is x for x in x_row)),
                     key=lambda w: -w["x1"])
    y_row = []
    if y_cands:
        near = y_cands[0]
        y_row = [w for w in y_cands if w["x1"] >= near["x1"] - max(
            1.5 * w["h"], near["x1"] - near["x0"])]

    # Label positions: center, or the chart edge for end labels aligned to it
    def x_poss(w):
        p = [w["cx"]]
        if abs(w["x0"] - left) < 0.8 * w["h"]:
            p.append(left + 0.5)
        if abs(w["x1"] - right) < 0.8 * w["h"]:
            p.append(right - 0.5)
        return p

    def y_poss(w):
        p = [w["cy"]]
        if abs(w["y0"] - top) < 0.5 * w["h"]:
            p.append(top + 0.5)
        if abs(w["y1"] - bottom) < 0.5 * w["h"]:
            p.append(bottom - 0.5)
        return p

    def labels(row, poss):
        return [{"poss": poss(w), "val": w["num"][0], "alts": w["num"][1],
                 "pow": w["num"][2], "conf": w["conf"]} for w in row]

    x_fit = fit_axis(labels(x_row, x_poss), W)
    y_fit = fit_axis(labels(y_row, y_poss), H)

    result, report = {}, []
    for axis, fit, row, lo, hi in (("x", x_fit, x_row, left + 0.5,
                                    right - 0.5),
                                   ("y", y_fit, y_row, bottom - 0.5,
                                    top + 0.5)):
        if fit:
            result[f"min_{axis}"] = _g(edge_value(fit, lo), 6)
            result[f"max_{axis}"] = _g(edge_value(fit, hi), 6)
            result[f"log_{axis}"] = fit.log
            result[f"grid_{axis}"] = sorted({d["v"] for d in fit.inliers})
            report.append(f"{axis}: {result[f'min_{axis}']:g} ... "
                          f"{result[f'max_{axis}']:g} "
                          f"{'log' if fit.log else 'linear'} "
                          f"({len(fit.inliers)}/{len(row)} labels)")
        else:
            report.append(f"{axis}: not found ({len(row)} numeric labels)")

    # Text lines outside the tick labels: title, x label
    used = {id(w) for w in x_row + y_row}
    lines = [ln for ln in group_lines([w for w in words if id(w) not in used])
             if ln["conf"] >= 50]
    x_tick_bottom = max((w["y1"] for w in x_row), default=bottom)

    def in_span(ln):
        return left - 0.15 * W <= ln["cx"] <= right + 0.15 * W

    def is_caption(ln):
        return bool(_CAPTION_RE.match(ln["text"]))

    x_label = min((ln for ln in lines
                   if not is_caption(ln) and in_span(ln)
                   and ln["y0"] >= x_tick_bottom - 2
                   and ln["y0"] - x_tick_bottom < 6 * ln["h"]),
                  key=lambda ln: ln["y0"], default=None)
    title = None
    captions = sorted((ln for ln in lines if is_caption(ln)),
                      key=lambda ln: ln["y0"])
    if captions:
        # Caption with its continuation lines
        caption = prev = captions[0]
        parts = [caption["text"]]
        for ln in sorted((ln for ln in lines if ln["y0"] > caption["y0"]),
                         key=lambda ln: ln["y0"]):
            if ln["y0"] - prev["y1"] < 0.8 * prev["h"] and \
                    abs(ln["h"] - prev["h"]) < 0.35 * prev["h"]:
                parts.append(ln["text"])
                prev = ln
        title = " ".join(parts)
    else:
        above = [ln for ln in lines if ln["y1"] <= top + 2 and in_span(ln)]
        if above:
            title = min(above, key=lambda ln: (-ln["h"], ln["y0"]))["text"]
    if title:
        result["title"] = title
    if x_label:
        result["x_label"] = x_label["text"]

    # Y label: usually rotated, OCR the strip left of the y tick labels
    strip_right = min((w["x0"] for w in y_row), default=left) - 2
    if strip_right >= 8:
        region = (0, max(0, round(top - 0.05 * H)), round(strip_right),
                  min(img_h, round(bottom + 0.05 * H)))
        y_label = recognize_rotated_label(image, region, scale)
        if y_label:
            result["y_label"] = y_label
    report += [f"title: {result.get('title', '-')}",
               f"x label: {result.get('x_label', '-')}",
               f"y label: {result.get('y_label', '-')}"]
    return result, report


# ============================================================================
# Command line
# ============================================================================

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Digitize curves from a chart image into CSV data "
                    "(command line version of digitool.html).")
    parser.add_argument("image", help="chart image (PNG, JPG, ...)")
    parser.add_argument("--config", help="JSON configuration "
                                         "(default: <image stem>.json)")
    parser.add_argument("--pick", nargs="+", action="append",
                        metavar=("X Y", "NAME"),
                        help="add a trace whose color is picked at image "
                             "pixel X Y, optionally named NAME (repeat for "
                             "more traces, top to bottom); replaces the "
                             "traces of the configuration")
    parser.add_argument("--crop", type=int, nargs=4,
                        metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"),
                        help="chart area in image pixels (default: found "
                             "automatically from the grid)")
    parser.add_argument("--ocr", action="store_true",
                        help="read axes, title and axis labels with OCR even "
                             "when set in the configuration (axes missing in "
                             "it are read anyway)")
    parser.add_argument("--no-ocr", action="store_true",
                        help="never run OCR")
    parser.add_argument("--out", help="output directory (default: the "
                                      "image's directory)")
    parser.add_argument("--save-config", action="store_true",
                        help="write <stem>.json even if it exists")
    parser.add_argument("--zip", action="store_true",
                        help="also write <stem>.zip with the image, JSON, "
                             "CSVs and plot (as Save in digitool.html)")
    parser.add_argument("--save-steps", action="store_true",
                        help="also write <stem>_crop.png and "
                             "<stem>_nogrid.png")
    parser.add_argument("--no-plot", action="store_true",
                        help="do not write <stem>_plot.png")
    parser.add_argument("--show", action="store_true",
                        help="show the plot in a window")
    args = parser.parse_args(argv)

    image_path = Path(args.image)
    if not image_path.is_file():
        parser.error(f"image '{image_path}' not found")
    stem = image_path.stem
    out_dir = Path(args.out) if args.out else image_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    config_path = Path(args.config) if args.config else \
        image_path.with_suffix(".json")

    if config_path.is_file():
        file_cfg = json.loads(config_path.read_text(encoding="utf-8"))
        file_keys = list(file_cfg)
        print(f"Configuration {config_path}")
    else:
        file_cfg = {"log_x": False, "log_y": False}
        file_keys = []
        print(f"Configuration {config_path} not found, using defaults")
    cfg = dict(file_cfg)
    if args.crop:
        cfg["crop"] = list(args.crop)

    image = np.asarray(Image.open(image_path).convert("RGB"))
    full = {**DEFAULTS, **cfg}
    box = crop_box(image, full)
    print(f"Chart area [left, top, right, bottom]: {box}")

    # Axes and labels with OCR (as digitool.html: when axes are not set)
    axes_set = all(isinstance(cfg.get(k), (int, float)) for k in AXES_KEYS)
    if not args.no_ocr and (args.ocr or not axes_set):
        try:
            found, report = detect_axes(image, box)
        except Exception as error:  # OCR is optional
            found, report = {}, [f"failed: {error}"]
        for line in report:
            print(f"OCR {line}")
        cfg.update(found)

    # Traces: picked colors or from the configuration
    if args.pick:
        traces = []
        for pick in args.pick:
            if len(pick) not in (2, 3):
                parser.error("--pick takes X Y [NAME]")
            x, y = int(pick[0]), int(pick[1])
            name = pick[2] if len(pick) == 3 else None
            if name is None and traces:
                name = f"trace{len(traces) + 1}"
            if traces and traces[0][0] is None:
                traces[0][0] = "trace1"
            traces.append([name, pick_color(image, x, y)])
            print(f"Picked color {traces[-1][1]} at ({x}, {y})"
                  + (f" for {name}" if name else ""))
    else:
        traces = config_traces(cfg)
    if not traces:
        traces = [[None, [0, 0, 0]]]
        print("No traces configured, digitizing a single black trace "
              "(set color/traces in the JSON or use --pick X Y)")

    start = time.perf_counter()
    res = digitize(image, cfg, traces)
    crop_h, crop_w = res["crop"].shape[:2]
    counts = ", ".join(f"{n or stem}: {len(r[0])}"
                       for (n, _), r in zip(traces, res["raw"]))
    print(f"Points {counts}  ({time.perf_counter() - start:.2f} s)")

    if args.save_steps:
        Image.fromarray(res["crop"]).save(out_dir / f"{stem}_crop.png")
        Image.fromarray(res["nogrid"]).save(out_dir / f"{stem}_nogrid.png")

    saved_cfg = build_saved_config(cfg, traces, file_keys)
    json_text = serialize_config(saved_cfg)
    entries = []  # (name, bytes) for the ZIP archive
    json_path = out_dir / f"{stem}.json"
    if args.save_config or not config_path.is_file():
        json_path.write_text(json_text, encoding="utf-8")
        print(f"Saved {json_path}")
    entries.append((f"{stem}.json", json_text.encode("utf-8")))

    full = {**DEFAULTS, **cfg}
    problem = axes_problem(full)
    if problem:
        print(f"Error: {problem}", file=sys.stderr)
        return 1
    curves = []
    for (name, _), raw in zip(traces, res["raw"]):
        xs, ys = scale_points(raw, crop_w, crop_h, full)
        csv_path = out_dir / csv_name(stem, name)
        text = format_csv(xs, ys)
        csv_path.write_text(text, encoding="utf-8")
        entries.append((csv_path.name, text.encode("utf-8")))
        print(f"Saved {len(xs)} points to {csv_path}")
        curves.append((name if name is not None else stem, (xs, ys)))

    if not args.no_plot or args.zip:
        png = plot_png(curves, full, stem, show=args.show)
        if png is None:
            print("matplotlib not installed, no plot saved")
        else:
            entries.append((f"{stem}_plot.png", png))
            if not args.no_plot:
                (out_dir / f"{stem}_plot.png").write_bytes(png)
                print(f"Saved {out_dir / f'{stem}_plot.png'}")

    if args.zip:
        zip_path = out_dir / f"{stem}.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr(image_path.name, image_path.read_bytes())
            for name, data in entries:
                zf.writestr(name, data)
        print(f"Saved {zip_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
