function result = digi(image_name, varargin)
%DIGI Digitize curves from a raster chart image into CSV data points.
%   DIGI(IMAGE) digitizes the chart image IMAGE (PNG, JPG, ...) with the
%   configuration <image stem>.json next to it (if it exists) and writes
%   next to the image:
%     <stem>.csv / <stem>_<trace>.csv   digitized points, "x;y" per line
%     <stem>_plot.png                   plot of the digitized curves
%     <stem>.json                       configuration (only if missing,
%                                       or with 'save_config', true)
%     <stem>.zip                        all of the above and the image
%                                       (with 'zip', true)
%
%   MATLAB / GNU Octave port of digi.html (DigiTool web app): the same
%   digitizing engine, axis / label OCR, CSV, JSON and plot outputs.
%
%   Axes missing in the configuration (min_x, max_x, min_y, max_y) are
%   read from the tick labels with OCR (needs the tesseract command line
%   tool on the PATH), as are the title and axis labels. Trace colors come
%   from the configuration ("color" / "traces") or are picked from image
%   pixels with 'pick'.
%
%   RESULT = DIGI(IMAGE, Name, Value, ...) returns a struct with the chart
%   area box ([left top right bottom], left/top 0-based, right/bottom
%   exclusive), the configuration used and the traces (name, color and
%   scaled x, y). Options:
%     'config'      JSON configuration file (default <stem>.json)
%     'pick'        traces picked at image pixels (0-based x, y as in the
%                   web app), N x 2 matrix [x y] or N x 3 cell {x, y, name};
%                   replaces the traces of the configuration
%     'crop'        chart area [left top right bottom] in image pixels
%                   (default: found automatically from the grid)
%     'ocr'         'auto' (default: only if axes are not set), true or false
%     'out'         output directory (default: the image's directory)
%     'save_config' write <stem>.json even if it exists (default false)
%     'zip'         also write <stem>.zip (default false)
%     'save_steps'  also write <stem>_crop.png and <stem>_nogrid.png
%     'plot'        write <stem>_plot.png (default true)
%     'show'        show the plot in a window (default false)
%
%   Examples:
%     digi('bjt_chart.png')
%     digi('bjt_chart.png', 'pick', {400, 492, '-55oC'; 400, 668, '25oC'; 400, 964, '150oC'})
%     digi('bjt_chart.png', 'ocr', true, 'save_config', true, 'zip', true)
%
%   Copyright 2023-2026 Radoslaw Gorniak
%   Author  - Radoslaw Gorniak
%   License - MIT License
%   Website - https://github.com/gorniak/DigiTool

  if nargin < 1 || isempty(image_name)
    error('digi:usage', 'Usage: digi(''bjt_chart.png'', Name, Value, ...), see help digi');
  end
  if exist('OCTAVE_VERSION', 'builtin')
    try
      pkg load image;  % optional, bwconncomp makes it faster
    catch
    end
  end

  opt = struct('config', '', 'pick', [], 'crop', [], 'ocr', 'auto', 'out', '', ...
               'save_config', false, 'zip', false, 'save_steps', false, ...
               'plot', true, 'show', false);
  for k = 1:2:numel(varargin)
    name = lower(varargin{k});
    if ~isfield(opt, name)
      error('digi:option', 'Unknown option ''%s''', varargin{k});
    end
    opt.(name) = varargin{k + 1};
  end

  if ~exist(image_name, 'file')
    error('digi:image', 'Image ''%s'' not found', image_name);
  end
  [img_dir, stem, ext] = fileparts(image_name);
  out_dir = opt.out;
  if isempty(out_dir)
    out_dir = img_dir;
  end
  if isempty(out_dir)
    out_dir = '.';
  end
  if ~exist(out_dir, 'dir')
    mkdir(out_dir);
  end
  config_path = opt.config;
  if isempty(config_path)
    config_path = fullfile(img_dir, [stem '.json']);
  end

  % Configuration
  config_exists = exist(config_path, 'file') == 2;
  if config_exists
    cfg = jsondecode(fileread(config_path));
    file_keys = fieldnames(cfg)';
    fprintf('Configuration %s\n', config_path);
  else
    cfg = struct('log_x', false, 'log_y', false);
    file_keys = {};
    fprintf('Configuration %s not found, using defaults\n', config_path);
  end
  if ~isempty(opt.crop)
    cfg.crop = double(opt.crop(:)');
  end

  image = to_uint8_rgb(imread(image_name));
  box = crop_box(image, merge_struct(defaults(), cfg));
  fprintf('Chart area [left, top, right, bottom]: [%d, %d, %d, %d]\n', box);

  % Axes and labels with OCR (as digi.html: when the axes are not set)
  axes_keys = {'min_x', 'max_x', 'min_y', 'max_y'};
  axes_set = true;
  for k = 1:numel(axes_keys)
    axes_set = axes_set && isfield(cfg, axes_keys{k}) && isnumeric(cfg.(axes_keys{k})) ...
               && isscalar(cfg.(axes_keys{k}));
  end
  if ischar(opt.ocr)
    run_ocr = ~axes_set;
  else
    run_ocr = logical(opt.ocr);
  end
  if run_ocr
    try
      [found, report] = detect_axes(image, box);
    catch err
      found = struct();
      report = {['failed: ' err.message]};
    end
    fprintf('OCR %s\n', report{:});
    keys = fieldnames(found);
    for k = 1:numel(keys)
      cfg.(keys{k}) = found.(keys{k});
    end
  end

  % Traces: picked colors or from the configuration
  if ~isempty(opt.pick)
    traces = cell(0, 2);
    pick = opt.pick;
    for k = 1:size(pick, 1)
      if iscell(pick)
        x = pick{k, 1};
        y = pick{k, 2};
        if size(pick, 2) >= 3
          name = pick{k, 3};
        else
          name = [];
        end
      else
        x = pick(k, 1);
        y = pick(k, 2);
        name = [];
      end
      if isempty(name) && ~isempty(traces)
        name = sprintf('trace%d', size(traces, 1) + 1);
      end
      if ~isempty(traces) && isempty(traces{1, 1})
        traces{1, 1} = 'trace1';
      end
      color = pick_color(image, round(x), round(y));
      traces(end + 1, :) = {name, color}; %#ok<AGROW>
      fprintf('Picked color [%d, %d, %d] at (%d, %d)\n', color, round(x), round(y));
    end
  else
    traces = config_traces(cfg);
  end
  if isempty(traces)
    traces = {[], [0 0 0]};
    fprintf(['No traces configured, digitizing a single black trace ' ...
             '(set color/traces in the JSON or use ''pick'')\n']);
  end

  tic;
  res = digitize(image, cfg, traces);
  [crop_h, crop_w, ~] = size(res.crop);
  msg = {};
  for k = 1:size(traces, 1)
    msg{end + 1} = sprintf('%s: %d', name_or(traces{k, 1}, stem), numel(res.raw{k, 1})); %#ok<AGROW>
  end
  fprintf('Points %s  (%.2f s)\n', strjoin(msg, ', '), toc);

  if opt.save_steps
    imwrite(res.crop, fullfile(out_dir, [stem '_crop.png']));
    imwrite(res.nogrid, fullfile(out_dir, [stem '_nogrid.png']));
  end

  [saved_keys, saved_vals] = build_saved_config(cfg, traces, file_keys);
  json_text = serialize_config(saved_keys, saved_vals);
  files = {};
  json_path = fullfile(out_dir, [stem '.json']);
  if opt.save_config || ~config_exists
    write_text(json_path, json_text);
    fprintf('Saved %s\n', json_path);
    files{end + 1} = json_path;
  end

  full = merge_struct(defaults(), cfg);
  problem = axes_problem(full);
  if ~isempty(problem)
    error('digi:axes', '%s', problem);
  end
  result = struct('box', box, 'config', full, 'traces', ...
                  struct('name', {}, 'color', {}, 'x', {}, 'y', {}));
  labels = {};
  curves = {};
  for k = 1:size(traces, 1)
    [xs, ys] = scale_points(res.raw{k, 1}, res.raw{k, 2}, crop_w, crop_h, full);
    name = traces{k, 1};
    if isempty(name)
      csv_path = fullfile(out_dir, [stem '.csv']);
    else
      csv_path = fullfile(out_dir, [stem '_' name '.csv']);
    end
    write_csv(csv_path, xs, ys);
    files{end + 1} = csv_path; %#ok<AGROW>
    fprintf('Saved %d points to %s\n', numel(xs), csv_path);
    labels{end + 1} = name_or(name, stem); %#ok<AGROW>
    curves{end + 1} = {xs, ys}; %#ok<AGROW>
    result.traces(end + 1) = struct('name', name, 'color', traces{k, 2}, 'x', xs, 'y', ys);
  end

  if opt.plot || opt.zip || opt.show
    png_path = fullfile(out_dir, [stem '_plot.png']);
    plot_curves(curves, labels, full, png_path, opt.show);
    files{end + 1} = png_path;
    fprintf('Saved %s\n', png_path);
  end

  if opt.zip
    % Stage the files (image, JSON, CSVs, plot) and pack them
    tmp = tempname();
    mkdir(tmp);
    copyfile(image_name, fullfile(tmp, [stem ext]));
    write_text(fullfile(tmp, [stem '.json']), json_text);
    for k = 1:numel(files)
      [~, n, e] = fileparts(files{k});
      if ~strcmp(e, '.json')
        copyfile(files{k}, fullfile(tmp, [n e]));
      end
    end
    zip_path = fullfile(out_dir, [stem '.zip']);
    zip(zip_path, '*', tmp);
    rmdir(tmp, 's');
    fprintf('Saved %s\n', zip_path);
  end
  if nargout == 0
    clear result;
  end
end

% ============================================================================
% Configuration defaults (as in digi.html)
% ============================================================================

function d = defaults()
  d = struct();
  % Crop the image to the chart grid (false if the image is the chart area,
  % or [left, top, right, bottom] pixel bounds of the chart area)
  d.crop = true;
  % Max per-channel difference to treat a pixel as the curve color
  d.color_tolerance = 10;
  % Max variance of RGB channels to treat a pixel as gray
  d.gray_variance = 10;
  % Min thickness in pixels of a black trace (thinner grid lines/text removed)
  d.trace_min_width = 7;
  % Min horizontal extent of a trace as a fraction of chart width
  d.trace_min_span = 0.1;
  % Min gap in pixels between separate traces (closer runs are merged)
  d.trace_min_gap = 7;
  % Span in pixels of trace points used to estimate its slope
  d.trace_slope_span = 20;
  % Max deviation of trace derivative from its slope around a crossing
  d.trace_slope_tolerance = 0.5;
  % Max deviation in pixels of a trace point from the curve fitted around
  % a crossing of traces or grid lines
  d.trace_value_tolerance = 1.0;
  % Min fraction of chart width (height) covered by a grid line
  d.grid_min_fill = 0.6;
  % Trace names top to bottom, or {"name": ..., "color": [r, g, b]} entries
  d.traces = {};
end

function k = key_order()
  k = [{'title', 'x_label', 'y_label', 'crop', 'color', ...
        'min_x', 'max_x', 'log_x', 'grid_x', ...
        'min_y', 'max_y', 'min_curve_y', 'max_curve_y', 'log_y', 'grid_y', ...
        'swap_x_y'}, fieldnames(defaults())'];
end

function s = merge_struct(a, b)
  s = a;
  keys = fieldnames(b);
  for k = 1:numel(keys)
    s.(keys{k}) = b.(keys{k});
  end
end

function s = name_or(name, other)
  if isempty(name)
    s = other;
  else
    s = name;
  end
end

function im = to_uint8_rgb(im)
  if isa(im, 'uint16')
    im = uint8(double(im) / 257);
  elseif isfloat(im) || islogical(im)
    im = uint8(255 * double(im));
  end
  if size(im, 3) == 1
    im = repmat(im, [1 1 3]);
  end
  im = im(:, :, 1:3);
end

% ============================================================================
% Core digitizing engine
% ============================================================================

% Round half to even (as Python round / pyRound in digi.html)
function r = py_round(x)
  f = floor(x);
  d = x - f;
  if d < 0.5
    r = f;
  elseif d > 0.5
    r = f + 1;
  elseif mod(f, 2) == 0
    r = f;
  else
    r = f + 1;
  end
end

% 1-based centers of groups of values above threshold * max (average
% position of the maximum values of each group)
function peaks = peakseek(values, threshold)
  values = double(values(:))';
  peaks = [];
  if isempty(values) || ~(max(values) > 0)
    return;
  end
  above = find(values > max(values) * threshold);
  starts = [1, find(diff(above) > 1) + 1];
  ends = [starts(2:end) - 1, numel(above)];
  for g = 1:numel(starts)
    grp = above(starts(g):ends(g));
    v = values(grp);
    peaks(end + 1) = mean(grp(v == max(v))); %#ok<AGROW>
  end
end

% Bounds [left top right bottom] of the chart grid (darkest rows/columns),
% left/top 0-based, right/bottom exclusive
function box = chart_box(im)
  [h, w, ~] = size(im);
  stat = 255 - double(min(im, [], 3));
  px = peakseek(sum(stat, 1), 0.9);
  py = peakseek(sum(stat, 2), 0.9);
  if numel(px) < 2 || numel(py) < 2
    box = [0, 0, w, h];
    return;
  end
  left = max(0, min(w - 1, py_round(px(1)) - 1));
  top = max(0, min(h - 1, py_round(py(1)) - 1));
  right = max(left + 1, min(w, py_round(px(end))));
  bottom = max(top + 1, min(h, py_round(py(end))));
  box = [left, top, right, bottom];
end

% Chart area box as set by the "crop" config
function box = crop_box(im, cfg)
  [h, w, ~] = size(im);
  crop = cfg.crop;
  if islogical(crop) && isscalar(crop) && crop
    box = chart_box(im);
  elseif isnumeric(crop) && numel(crop) == 4
    c = fix(double(crop(:)'));
    l = max(0, min(w - 1, c(1)));
    t = max(0, min(h - 1, c(2)));
    r = max(l + 1, min(w, c(3)));
    b = max(t + 1, min(h, c(4)));
    box = [l, t, r, b];
  else
    box = [0, 0, w, h];
  end
end

function m = gray_mask(im, gray_variance)
  d = double(im);
  dev = bsxfun(@minus, d, mean(d, 3));
  m = sum(dev .^ 2, 3) / 2 < gray_variance;
end

% Pixels of the given trace color (black means any dark gray)
function m = color_mask(im, color, cfg)
  if all(color == 0)
    m = min(im, [], 3) < 128 & gray_mask(im, cfg.gray_variance);
  else
    diffs = abs(bsxfun(@minus, double(im), reshape(double(color), 1, 1, 3)));
    m = all(diffs < cfg.color_tolerance, 3);
  end
end

% Binary erosion (dilation) with a size x size square, outside is empty
function out = imerode_sq(mask, sz, dilate)
  sz = max(1, py_round(sz));
  out = mask;
  if sz <= 1
    return;
  end
  pad0 = floor(sz / 2);
  for axis = 1:2
    n = size(out, axis);
    c = cumsum(double(out), axis);
    if axis == 1
      c = [zeros(1, size(c, 2)); c];
    else
      c = [zeros(size(c, 1), 1), c];
    end
    a = (0:n - 1) - pad0;
    b = a + sz - 1;
    if dilate
      a = max(a, 0);
      b = min(b, n - 1);
      lo = a + 1;
      hi = b + 2;
    else
      valid = a >= 0 & b < n;
      lo = min(max(a, 0), n) + 1;
      hi = min(max(b + 1, 0), n) + 1;
    end
    if axis == 1
      cnt = c(hi, :) - c(lo, :);
    else
      cnt = c(:, hi) - c(:, lo);
    end
    if dilate
      out = cnt > 0;
    elseif axis == 1
      out = bsxfun(@and, cnt == sz, valid(:));
    else
      out = bsxfun(@and, cnt == sz, valid);
    end
  end
end

function out = imopen_sq(mask, sz)
  out = imerode_sq(imerode_sq(mask, sz, false), sz, true);
end

% 8-connected components: cell of linear pixel indices (into mask) and
% their min / max columns, in order of their first pixel in raster order
function [pix, minc, maxc] = components(mask)
  [h, w] = size(mask);
  t = mask.';  % column-major order of t is raster order of mask
  if exist('bwconncomp', 'file') || exist('bwconncomp', 'builtin')
    cc = bwconncomp(t, 8);
    lists = cc.PixelIdxList;
  else
    lists = flood_components(t);
  end
  n = numel(lists);
  pix = cell(1, n);
  minc = zeros(1, n);
  maxc = zeros(1, n);
  for k = 1:n
    L = lists{k}(:);
    col = mod(L - 1, w) + 1;          % row in t = column in mask
    row = floor((L - 1) / w) + 1;     % column in t = row in mask
    pix{k} = row + (col - 1) * h;
    minc(k) = min(col);
    maxc(k) = max(col);
  end
end

% 8-connected components of mask without the image toolbox
function lists = flood_components(mask)
  [h, w] = size(mask);
  seen = false(h, w);
  lists = {};
  stack = zeros(nnz(mask), 1);
  for p0 = find(mask)'
    if seen(p0)
      continue;
    end
    seen(p0) = true;
    sp = 1;
    stack(1) = p0;
    comp = zeros(0, 1);
    while sp > 0
      p = stack(sp);
      sp = sp - 1;
      comp(end + 1, 1) = p; %#ok<AGROW>
      x = floor((p - 1) / h) + 1;
      y = p - (x - 1) * h;
      for nx = max(1, x - 1):min(w, x + 1)
        for ny = max(1, y - 1):min(h, y + 1)
          q = ny + (nx - 1) * h;
          if mask(q) && ~seen(q)
            seen(q) = true;
            sp = sp + 1;
            stack(sp) = q;
          end
        end
      end
    end
    lists{end + 1} = sort(comp); %#ok<AGROW>
  end
end

% Remove components spanning fewer than min_span columns
function out = remove_short(mask, min_span)
  out = false(size(mask));
  [pix, minc, maxc] = components(mask);
  for k = 1:numel(pix)
    if maxc(k) - minc(k) + 1 >= min_span
      out(pix{k}) = true;
    end
  end
end

% Keep components forming at most count traces: from the widest one, a
% component is dropped where it overlaps more than max_overlap columns
% already holding count wider components
function out = keep_traces(mask, count, max_overlap)
  [h, w] = size(mask);
  out = false(h, w);
  coverage = zeros(1, w);
  [pix, minc, maxc] = components(mask);
  [~, order] = sort(maxc - minc, 'descend');
  for k = order
    cols = unique(floor((pix{k} - 1) / h) + 1);
    if sum(coverage(cols) >= count) > max_overlap
      continue;
    end
    coverage(cols) = coverage(cols) + 1;
    out(pix{k}) = true;
  end
end

% Remove grid and text - keep only thick strokes of trace colors
function out = imremove_grid(crop, colors, counts, cfg)
  [h, w, ~] = size(crop);
  nc = size(colors, 1);
  opened = cell(1, nc);
  union_mask = false(h, w);
  for c = 1:nc
    opened{c} = imopen_sq(color_mask(crop, colors(c, :), cfg), cfg.trace_min_width);
    union_mask = union_mask | opened{c};
  end
  wide = remove_short(union_mask, cfg.trace_min_span * w);
  final = false(h, w);
  for c = 1:nc
    final = final | keep_traces(opened{c} & wide, counts(c), cfg.trace_min_gap);
  end
  out = crop;
  for ch = 1:3
    plane = out(:, :, ch);
    plane(~final) = 255;
    out(:, :, ch) = plane;
  end
end

function out = imremove_gray(crop, gray_variance)
  out = crop;
  m = gray_mask(crop, gray_variance);
  for ch = 1:3
    plane = out(:, :, ch);
    plane(m) = 255;
    out(:, :, ch) = plane;
  end
end

function centers = group_centers(fill, min_fill)
  centers = [];
  above = find(fill >= min_fill);
  if isempty(above)
    return;
  end
  starts = [1, find(diff(above) > 1) + 1];
  ends = [starts(2:end) - 1, numel(above)];
  centers = (above(starts) + above(ends)) / 2;
end

% Removed grid lines: 1-based centers of columns and rows (from the bottom)
% whose dark pixels outside the traces fill at least grid_min_fill
function [gx, gy] = find_grid(crop, nogrid, cfg)
  grid = color_mask(crop, [0 0 0], cfg) & min(nogrid, [], 3) == 255;
  gx = group_centers(mean(grid, 1), cfg.grid_min_fill);
  gy = group_centers(mean(flipud(grid), 2)', cfg.grid_min_fill);
end

% Median of sorted 0-based positions + 1
function m = median_plus1(run)
  n = numel(run);
  m = (run(floor((n - 1) / 2) + 1) + run(floor(n / 2) + 1)) / 2 + 1;
end

% Split sorted 0-based pixel positions into runs, runs closer than min_gap
% are merged unless both are at least min_len thick
function out = split_runs(hits, min_gap, min_len)
  starts = [1, find(diff(hits) > 1) + 1];
  ends = [starts(2:end) - 1, numel(hits)];
  out = {hits(starts(1):ends(1))};
  for r = 2:numel(starts)
    run = hits(starts(r):ends(r));
    prev = out{end};
    if run(1) - prev(end) > min_gap || (numel(run) >= min_len && numel(prev) >= min_len)
      out{end + 1} = run; %#ok<AGROW>
    else
      out{end} = [prev, run];
    end
  end
end

% Median thickness of runs in columns where all traces are separate
function width = trace_width(col_hits, trace_count, min_gap)
  lengths = [];
  for j = 1:numel(col_hits)
    hits = col_hits{j};
    if isempty(hits)
      continue;
    end
    cuts = find(diff(hits) > min_gap);
    if numel(cuts) + 1 == trace_count
      lengths = [lengths, diff([0, cuts, numel(hits)])]; %#ok<AGROW>
    end
  end
  if isempty(lengths)
    width = 1.0;
    return;
  end
  lengths = sort(lengths);
  n = numel(lengths);
  width = (lengths(floor((n - 1) / 2) + 1) + lengths(floor(n / 2) + 1)) / 2;
end

% Extrapolate trace to pos from a line fitted to its last points within
% span, NaN if the trace has not been seen yet
function p = predict(hist, n, pos, span)
  if n == 0
    p = NaN;
    return;
  end
  last_x = hist(n, 1);
  sel = hist(max(1, n - span + 1):n, :);
  sel = sel(sel(:, 1) > last_x - span, :);
  if size(sel, 1) < 2
    p = hist(n, 2);
    return;
  end
  mx = mean(sel(:, 1));
  my = mean(sel(:, 2));
  den = sum((sel(:, 1) - mx) .^ 2);
  if den == 0
    p = my;
    return;
  end
  p = sum((sel(:, 1) - mx) .* (sel(:, 2) - my)) / den * (pos - mx) + my;
end

% Order-preserving selection of numel(order) runs nearest to predictions
function kept = select_runs(runs, preds, order)
  R = numel(runs);
  K = numel(order);
  med = cellfun(@median_plus1, runs);
  dp = inf(K + 1, R + 1);
  pick = false(K, R);
  dp(K + 1, :) = 0;
  for m = K - 1:-1:0
    target = preds(order(m + 1));
    for r = R - (K - m):-1:m
      take = abs(med(r + 1) - target) + dp(m + 2, r + 2);
      if r + 1 <= R - (K - m)
        skip = dp(m + 1, r + 2);
      else
        skip = inf;
      end
      if take <= skip
        dp(m + 1, r + 1) = take;
        pick(m + 1, r + 1) = true;
      else
        dp(m + 1, r + 1) = skip;
      end
    end
  end
  kept = cell(1, K);
  r = 0;
  for m = 0:K - 1
    while ~pick(m + 1, r + 1)
      r = r + 1;
    end
    kept{m + 1} = runs{r + 1};
    r = r + 1;
  end
end

% Permutation of order minimizing sum |centers(r) - preds(perm(r))|
function perm = best_permutation(order, centers, preds)
  K = numel(order);
  if K <= 7
    P = sortrows(perms(1:K));  % lexicographic, as the depth-first search
    cand = order(P);
    if K == 1
      cand = cand(:)';
    end
    cost = zeros(size(P, 1), 1);
    for d = 1:K
      cost = cost + abs(centers(d) - reshape(preds(cand(:, d)), [], 1));
    end
    [~, i] = min(cost);
    perm = cand(i, :);
  else
    if centers(1) > centers(K)
      [~, i] = sort(preds(order), 'descend');
    else
      [~, i] = sort(preds(order), 'ascend');
    end
    perm = order(i);
  end
end

% Partition of order into G non-empty contiguous groups of minimal cost.
% cost(r, s, e) with 0-based run r and order slice s:e (end exclusive)
function groups = best_groups(order, G, cost)
  K = numel(order);
  if G == 1
    groups = {order};
    return;
  end
  dp = inf(G + 1, K + 1);
  next_cut = zeros(G, K);
  dp(G + 1, K + 1) = 0;
  for r = G - 1:-1:0
    for s = r:K - (G - r)
      best = inf;
      best_end = s + 1;
      for e = s + 1:K - (G - 1 - r)
        c = cost(r, s, e) + dp(r + 2, e + 1);
        if c < best
          best = c;
          best_end = e;
        end
      end
      dp(r + 1, s + 1) = best;
      next_cut(r + 1, s + 1) = best_end;
    end
  end
  groups = cell(1, G);
  s = 0;
  for r = 0:G - 1
    e = next_cut(r + 1, s + 1);
    groups{r + 1} = order(s + 1:e);
    s = e;
  end
end

% Centered and scaled quadratic least squares fit, p = [a b c mx scale]
function p = polyfit2(x, y)
  x = x(:);
  y = y(:);
  mx = mean(x);
  scale = max(abs(x - mx));
  if scale == 0
    scale = 1;
  end
  u = (x - mx) / scale;
  A = [sum(u .^ 4), sum(u .^ 3), sum(u .^ 2), sum(u .^ 2 .* y);
       sum(u .^ 3), sum(u .^ 2), sum(u), sum(u .* y);
       sum(u .^ 2), sum(u), numel(x), sum(y)];
  for col = 1:3
    [~, piv] = max(abs(A(col:3, col)));
    piv = piv + col - 1;
    A([col piv], :) = A([piv col], :);
    diag_val = A(col, col);
    if abs(diag_val) < 1e-14
      continue;
    end
    for row = col + 1:3
      A(row, col:4) = A(row, col:4) - A(row, col) / diag_val * A(col, col:4);
    end
  end
  c = 0; b = 0; a = 0;
  if abs(A(3, 3)) > 1e-14, c = A(3, 4) / A(3, 3); end
  if abs(A(2, 2)) > 1e-14, b = (A(2, 4) - A(2, 3) * c) / A(2, 2); end
  if abs(A(1, 1)) > 1e-14, a = (A(1, 4) - A(1, 2) * b - A(1, 3) * c) / A(1, 1); end
  p = [a, b, c, mx, scale];
end

function v = poly_value(p, x)
  u = (x - p(4)) / p(5);
  v = (p(1) * u + p(2)) .* u + p(3);
end

function d = poly_deriv(p, x)
  u = (x - p(4)) / p(5);
  d = (2 * p(1) * u + p(2)) / p(5);
end

% Crossings [first overlapped, first separated column] as areas, long
% overlaps split into their edges
function areas = crossing_areas(crossings, span)
  areas = zeros(0, 2);
  for k = 1:size(crossings, 1)
    first = crossings(k, 1);
    last = crossings(k, 2);
    if last - first > 2 * span
      areas = [areas; first, first; last, last]; %#ok<AGROW>
    else
      areas = [areas; first, last]; %#ok<AGROW>
    end
  end
end

% Areas where trace xs, ys crosses grid lines, widened by the trace width
function areas = grid_areas(xs, ys, gx, gy, width, span)
  areas = [gx(:) - width, gx(:) + width];
  for g = gy(:)'
    near = xs(abs(ys - g) <= width);
    if isempty(near)
      continue;
    end
    starts = [1, find(diff(near) > 1) + 1];
    ends = [starts(2:end) - 1, numel(near)];
    for k = 1:numel(starts)
      if near(ends(k)) - near(starts(k)) <= span
        areas(end + 1, :) = [near(starts(k)), near(ends(k))]; %#ok<AGROW>
      end
    end
  end
end

% Remove points of trace in disturbed areas (crossings of traces or grid
% lines) deviating from a quadratic fitted around the area
function [xs, ys] = remove_disturbed(xs, ys, areas, span, slope_tol, value_tol)
  n = numel(xs);
  if n == 0
    return;
  end
  keep = true(1, n);
  half = floor(span / 2);
  for k = 1:size(areas, 1)
    lo = areas(k, 1) - half;
    hi = areas(k, 2) + half;
    win = xs >= lo - span & xs <= hi + span;
    area = xs >= lo & xs <= hi;
    around = win & ~area & keep;
    if sum(around) > 3
      p = polyfit2(xs(around), ys(around));
      if max(abs(ys(around) - poly_value(p, xs(around)))) > 2 * value_tol
        continue;
      end
    end
    while true
      fit = win & keep;
      idx = find(area & keep);
      if sum(fit) < half || isempty(idx)
        break;
      end
      p = polyfit2(xs(fit), ys(fit));
      kept = find(keep);
      [~, pos] = ismember(idx, kept);
      lo_idx = kept(max(pos - 2, 1));
      hi_idx = kept(min(pos + 2, numel(kept)));
      dx = xs(hi_idx) - xs(lo_idx);
      d = zeros(size(dx));
      nz = dx ~= 0;
      d(nz) = (ys(hi_idx(nz)) - ys(lo_idx(nz))) ./ dx(nz);
      score = max(abs(d - poly_deriv(p, xs(idx))) / slope_tol, ...
                  abs(ys(idx) - poly_value(p, xs(idx))) / value_tol);
      [worst_score, worst] = max(score);
      if worst_score <= 1
        break;
      end
      keep(idx(worst)) = false;
    end
  end
  xs = xs(keep);
  ys = ys(keep);
end

% Pixel points of trace_count traces of color, 1-based in the cropped image,
% y counted from the bottom; cell {x, y} per trace. Traces are ordered top
% to bottom (left to right with swap_x_y); crossing traces are tracked by
% their slope.
function traces = digitalize(nogrid, color, tol, trace_count, min_gap, swap_xy, ...
                             slope_span, slope_tol, value_tol, gx, gy)
  diffs = abs(bsxfun(@minus, double(nogrid), reshape(double(color), 1, 1, 3)));
  match = flipud(all(diffs < tol, 3));
  if swap_xy
    match = match.';
    tmp = gx; gx = gy; gy = tmp;
  end
  n_cols = size(match, 2);
  col_hits = cell(1, n_cols);
  for j = 1:n_cols
    col_hits{j} = find(match(:, j))' - 1;
  end
  width = trace_width(col_hits, trace_count, min_gap);
  top_down = trace_count > 1 && ~swap_xy;
  points = repmat({zeros(n_cols, 2)}, 1, trace_count);
  npts = zeros(1, trace_count);
  history = repmat({zeros(n_cols, 2)}, 1, trace_count);
  nhist = zeros(1, trace_count);
  order = 1:trace_count;
  overlap_len = 0;
  merged_since = nan(1, trace_count);
  crossings = repmat({zeros(0, 2)}, 1, trace_count);

  for j = 1:n_cols
    hits = col_hits{j};
    if isempty(hits)
      continue;
    end
    if trace_count == 1
      npts(1) = npts(1) + 1;
      points{1}(npts(1), :) = [j, median_plus1(hits)];
      continue;
    end
    runs = split_runs(hits, min_gap, 0.6 * width);
    if top_down
      runs = runs(end:-1:1);
    end
    preds = zeros(1, trace_count);
    for k = 1:trace_count
      preds(k) = predict(history{k}, nhist(k), j, slope_span);
    end
    known = ~any(isnan(preds));
    if numel(runs) > trace_count
      if known
        runs = select_runs(runs, preds, order);
      else
        [~, idx] = sort(-cellfun(@numel, runs));  % stable: thickest first
        runs = runs(sort(idx(1:trace_count)));
      end
    end
    centers = cellfun(@median_plus1, runs);
    if numel(runs) == trace_count
      if overlap_len && known
        order = best_permutation(order, centers, preds);
      end
      overlap_len = 0;
      groups = num2cell(order);
    else
      overlap_len = overlap_len + 1;
      if known
        groups = best_groups(order, numel(runs), ...
          @(r, s, e) sum(abs(centers(r + 1) - preds(order(s + 1:e)))));
      else
        lens = cellfun(@numel, runs);
        groups = best_groups(order, numel(runs), ...
          @(r, s, e) abs(lens(r + 1) / width - (e - s)));
      end
    end
    weight = max(0, 1 - overlap_len / (2 * slope_span));
    for r = 1:numel(runs)
      run = runs{r};
      center = centers(r);
      group = groups{r};
      for k = group
        if numel(group) == 1
          nhist(k) = nhist(k) + 1;
          history{k}(nhist(k), :) = [j, center];
          npts(k) = npts(k) + 1;
          points{k}(npts(k), :) = [j, center];
          if ~isnan(merged_since(k))
            crossings{k}(end + 1, :) = [merged_since(k), j];
            merged_since(k) = NaN;
          end
        else
          if isnan(merged_since(k))
            merged_since(k) = j;
          end
          npts(k) = npts(k) + 1;
          if isnan(preds(k))
            points{k}(npts(k), :) = [j, center];
            continue;
          end
          pred = min(max(preds(k), run(1) + 1), run(end) + 1);
          points{k}(npts(k), :) = [j, weight * pred + (1 - weight) * center];
        end
      end
    end
  end

  traces = cell(trace_count, 2);
  for k = 1:trace_count
    xs = points{k}(1:npts(k), 1)';
    ys = points{k}(1:npts(k), 2)';
    areas = [crossing_areas(crossings{k}, slope_span); ...
             grid_areas(xs, ys, gx, gy, width, slope_span)];
    [xs, ys] = remove_disturbed(xs, ys, areas, slope_span, slope_tol, value_tol);
    if swap_xy
      traces(k, :) = {ys, xs};
    else
      traces(k, :) = {xs, ys};
    end
  end
end

% Digitize traces (cell N x 2 {name, color}) of chart image. Returns a
% struct with box, crop and nogrid images and raw pixel traces (N x 2 cell
% {x, y}) in trace order.
function res = digitize(image, cfg, traces)
  cfg = merge_struct(defaults(), cfg);
  box = crop_box(image, cfg);
  crop = image(box(2) + 1:box(4), box(1) + 1:box(3), :);
  % Unique colors in trace order with their trace indices
  colors = zeros(0, 3);
  members = {};
  for k = 1:size(traces, 1)
    c = double(traces{k, 2}(:)');
    i = find(all(bsxfun(@eq, colors, c), 2), 1);
    if isempty(i)
      colors(end + 1, :) = c; %#ok<AGROW>
      members{end + 1} = k; %#ok<AGROW>
    else
      members{i}(end + 1) = k;
    end
  end
  counts = cellfun(@numel, members);
  if any(all(colors == 0, 2)) || size(colors, 1) > 1
    nogrid = imremove_grid(crop, colors, counts, cfg);
  else
    nogrid = imremove_gray(crop, cfg.gray_variance);
  end
  [gx, gy] = find_grid(crop, nogrid, cfg);
  swap_xy = isfield(cfg, 'swap_x_y') && logical(cfg.swap_x_y);
  raw = cell(size(traces, 1), 2);
  for c = 1:size(colors, 1)
    pts = digitalize(nogrid, colors(c, :), cfg.color_tolerance, counts(c), ...
                     cfg.trace_min_gap, swap_xy, cfg.trace_slope_span, ...
                     cfg.trace_slope_tolerance, cfg.trace_value_tolerance, gx, gy);
    raw(members{c}, :) = pts;
  end
  res = struct('box', box, 'crop', crop, 'nogrid', nogrid);
  res.raw = raw;
end

% ============================================================================
% Color picking, scaling, configuration, CSV
% ============================================================================

% Trace color at image pixel (x, y) (0-based): the most common strong
% color nearby, black for dark gray
function color = pick_color(image, x, y)
  r = 3;            % pick radius
  tol = 30;         % pick tolerance
  [h, w, ~] = size(image);
  patch = image(max(0, y - r) + 1:min(h - 1, y + r) + 1, ...
                max(0, x - r) + 1:min(w - 1, x + r) + 1, :);
  px = double(reshape(permute(patch, [2 1 3]), [], 3));  % raster order
  mn = min(px, [], 2);
  mx = max(px, [], 2);
  strength = 255 - mn + (mx - mn);
  sel = strength >= 0.8 * max(strength);
  strong = px(sel, :);
  sstr = strength(sel);
  n = size(strong, 1);
  counts = zeros(n, 1);
  for i = 1:n
    counts(i) = sum(all(abs(bsxfun(@minus, strong, strong(i, :))) < tol, 2));
  end
  cand = find(counts == max(counts));
  [~, b] = max(sstr(cand));
  color = strong(cand(b), :);
  m = mean(color);
  v = sum((color - m) .^ 2) / 2;
  if max(color) < 128 && v < 10
    color = [0 0 0];
  end
end

function out = scale_linear(pts, min_p, max_p, min_v, max_v)
  if min_p == max_p
    out = min_v * ones(size(pts));
    return;
  end
  a = (min_v - max_v) / (min_p - max_p);
  out = a * pts + (min_v - a * min_p);
end

function out = scale_log(pts, min_p, max_p, min_v, max_v)
  out = 10 .^ scale_linear(pts, min_p, max_p, log10(min_v), log10(max_v));
end

% Chart values of raw pixel points of the cropped image
function [sx, sy] = scale_points(px, py, crop_w, crop_h, cfg)
  if is_true(cfg, 'log_x')
    sx = scale_log(px, 1, crop_w, cfg.min_x, cfg.max_x);
  else
    sx = scale_linear(px, 1, crop_w, cfg.min_x, cfg.max_x);
  end
  if is_true(cfg, 'log_y')
    sy = scale_log(py, 1, crop_h, cfg.min_y, cfg.max_y);
  else
    sy = scale_linear(py, 1, crop_h, cfg.min_y, cfg.max_y);
    if isfield(cfg, 'min_curve_y') && isfield(cfg, 'max_curve_y') && ...
        isnumeric(cfg.min_curve_y) && isnumeric(cfg.max_curve_y) && ~isempty(sy) && ...
        max(sy) > min(sy)
      sy = scale_linear(sy, min(sy), max(sy), cfg.min_curve_y, cfg.max_curve_y);
    end
  end
end

function t = is_true(cfg, key)
  t = isfield(cfg, key) && ~isempty(cfg.(key)) && logical(cfg.(key));
end

% Error message if the axes cannot scale the points, '' if they can
function msg = axes_problem(cfg)
  msg = '';
  keys = {'min_x', 'max_x', 'min_y', 'max_y'};
  missing = {};
  for k = 1:numel(keys)
    v = [];
    if isfield(cfg, keys{k})
      v = cfg.(keys{k});
    end
    if ~(isnumeric(v) && isscalar(v) && isfinite(v))
      missing{end + 1} = keys{k}; %#ok<AGROW>
    end
  end
  if ~isempty(missing)
    msg = sprintf('Set %s in the JSON configuration (axes not recognized by OCR)', ...
                  strjoin(missing, ', '));
  elseif cfg.min_x == cfg.max_x
    msg = 'min_x and max_x must differ';
  elseif cfg.min_y == cfg.max_y
    msg = 'min_y and max_y must differ';
  elseif is_true(cfg, 'log_x') && ~(cfg.min_x > 0 && cfg.max_x > 0)
    msg = 'log_x requires min_x > 0 and max_x > 0';
  elseif is_true(cfg, 'log_y') && ~(cfg.min_y > 0 && cfg.max_y > 0)
    msg = 'log_y requires min_y > 0 and max_y > 0';
  end
end

% Shortest decimal digits p that read back as x, and the decimal exponent
function [p, e] = shortest_digits(x)
  for p = 1:17
    t = sprintf(['%.' num2str(p - 1) 'e'], x);
    if str2double(t) == x
      break;
    end
  end
  e = str2double(t(strfind(t, 'e') + 1:end));
end

% Number as %.16g, written as digi.html (JavaScript) writes it
function s = fmt_g16(v)
  if isnan(v)
    s = 'NaN';
  elseif isinf(v)
    if v > 0, s = 'Infinity'; else, s = '-Infinity'; end
  elseif v == 0
    s = '0';
  else
    ex = floor(log10(abs(v)));
    if ex < -4 || ex >= 16
      t = sprintf('%.15e', v);
      k = strfind(t, 'e');
      mant = regexprep(t(1:k - 1), '\.?0+$', '');
      ev = str2double(t(k + 1:end));
      if ev >= 0, sg = '+'; else, sg = '-'; end
      s = sprintf('%se%s%02d', mant, sg, abs(ev));
    else
      x = str2double(sprintf('%.16g', v));
      [p, e] = shortest_digits(x);
      s = sprintf(['%.' num2str(max(0, p - 1 - e)) 'f'], x);
    end
  end
end

function write_csv(path, xs, ys)
  fid = fopen(path, 'w');
  for i = 1:numel(xs)
    fprintf(fid, '%s;%s\n', fmt_g16(xs(i)), fmt_g16(ys(i)));
  end
  fclose(fid);
end

function write_text(path, text)
  fid = fopen(path, 'w', 'n', 'UTF-8');
  fwrite(fid, unicode2native(text, 'UTF-8'));
  fclose(fid);
end

% Traces as cell N x 2 {name, color} from config ({} without color and
% traces), name [] for a single unnamed trace
function traces = config_traces(cfg)
  traces = cell(0, 2);
  list = {};
  if isfield(cfg, 'traces')
    list = cfg.traces;
  end
  if ~isfield(cfg, 'color') && isempty(list)
    return;
  end
  base = [0 0 0];
  if isfield(cfg, 'color') && isnumeric(cfg.color) && numel(cfg.color) >= 3
    base = double(cfg.color(1:3));
    base = base(:)';
  end
  if isempty(list)
    traces = {[], base};
    return;
  end
  if isstruct(list)
    list = num2cell(list);
  elseif ischar(list)
    list = {list};
  end
  for k = 1:numel(list)
    t = list{k};
    if isstruct(t)
      c = base;
      if isfield(t, 'color')
        c = double(t.color(1:3));
        c = c(:)';
      end
      nm = [];
      if isfield(t, 'name')
        nm = t.name;
      end
      traces(end + 1, :) = {nm, c}; %#ok<AGROW>
    else
      if isnumeric(t)
        t = num2str(t);
      end
      traces(end + 1, :) = {t, base}; %#ok<AGROW>
    end
  end
end

function d = is_default(key, value)
  if strcmp(key, 'swap_x_y')
    d = isempty(value) || ~logical(value);
    return;
  end
  defs = defaults();
  if ~isfield(defs, key)
    d = false;
  elseif strcmp(key, 'traces')
    d = isempty(value);
  else
    dv = defs.(key);
    d = (isnumeric(value) || islogical(value)) && isscalar(value) && ...
        isscalar(dv) && double(value) == double(dv) && islogical(value) == islogical(dv);
  end
end

% Configuration to save (keys and values): traces folded into color /
% traces, defaults dropped unless in the file, keys in file order then
% key_order()
function [keys, vals] = build_saved_config(cfg, traces, file_keys)
  out = cfg;
  if isfield(out, 'traces')
    out = rmfield(out, 'traces');
  end
  colors = unique(cell2mat(traces(:, 2)), 'rows');
  if size(colors, 1) == 1
    out.color = traces{1, 2};
    names = {};
    for k = 1:size(traces, 1)
      if ~isempty(traces{k, 1})
        names{end + 1} = traces{k, 1}; %#ok<AGROW>
      end
    end
    out.traces = names;
  else
    if isfield(out, 'color')
      out = rmfield(out, 'color');
    end
    items = cell(1, size(traces, 1));
    for k = 1:size(traces, 1)
      items{k} = struct('name', name_or(traces{k, 1}, sprintf('trace%d', k)), ...
                        'color', traces{k, 2});
    end
    out.traces = items;
  end
  order = [file_keys, setdiff(key_order(), file_keys, 'stable')];
  all_keys = fieldnames(out)';
  keys = {};
  rank = [];
  for k = 1:numel(all_keys)
    key = all_keys{k};
    if any(strcmp(file_keys, key)) || ~is_default(key, out.(key))
      keys{end + 1} = key; %#ok<AGROW>
      i = find(strcmp(order, key), 1);
      if isempty(i)
        i = 999;
      end
      rank(end + 1) = i; %#ok<AGROW>
    end
  end
  [~, i] = sort(rank);
  keys = keys(i);
  vals = cell(size(keys));
  for k = 1:numel(keys)
    vals{k} = out.(keys{k});
  end
end

% JSON number as JavaScript JSON.stringify writes it
function s = js_num(v)
  v = double(v);
  if ~isfinite(v)
    s = 'null';
  elseif v == fix(v) && abs(v) < 1e21
    s = sprintf('%.0f', v);
  else
    [p, e] = shortest_digits(v);
    if abs(v) >= 1e-6 && abs(v) < 1e21
      s = sprintf(['%.' num2str(max(0, p - 1 - e)) 'f'], v);
    else
      t = sprintf(['%.' num2str(p - 1) 'e'], v);
      k = strfind(t, 'e');
      if e >= 0, sg = '+'; else, sg = '-'; end
      s = sprintf('%se%s%d', t(1:k - 1), sg, abs(e));
    end
  end
end

function s = js_value(v)
  if ischar(v)
    s = jsonencode(v);
  elseif islogical(v) && isscalar(v)
    if v, s = 'true'; else, s = 'false'; end
  elseif isnumeric(v) && isscalar(v)
    s = js_num(v);
  elseif isempty(v)
    s = '[]';
  elseif isnumeric(v) || islogical(v)
    parts = arrayfun(@(x) js_num(double(x)), v(:)', 'UniformOutput', false);
    s = ['[' strjoin(parts, ',') ']'];
  elseif iscell(v)
    parts = cellfun(@js_value, v(:)', 'UniformOutput', false);
    s = ['[' strjoin(parts, ',') ']'];
  else
    s = jsonencode(v);
  end
end

% JSON text formatted as digi.html (one key per line, one colored trace
% per line)
function text = serialize_config(keys, vals)
  array_keys = {'crop', 'color', 'grid_x', 'grid_y'};
  lines = cell(1, numel(keys));
  for k = 1:numel(keys)
    key = keys{k};
    v = vals{k};
    if strcmp(key, 'traces') && iscell(v) && any(cellfun(@isstruct, v))
      items = cellfun(@(t) sprintf('    {"name" : %s, "color" : [%s]}', ...
        jsonencode(t.name), strjoin(arrayfun(@js_num, double(t.color(:)'), ...
        'UniformOutput', false), ', ')), v, 'UniformOutput', false);
      lines{k} = sprintf('  "%s" : [\n%s\n  ]', key, strjoin(items, sprintf(',\n')));
    elseif iscell(v) || (isnumeric(v) && (~isscalar(v) || any(strcmp(array_keys, key))))
      if iscell(v)
        parts = cellfun(@js_value, v(:)', 'UniformOutput', false);
      else
        parts = arrayfun(@js_num, double(v(:)'), 'UniformOutput', false);
      end
      lines{k} = sprintf('  "%s" : [%s]', key, strjoin(parts, ', '));
    else
      lines{k} = sprintf('  "%s" : %s', key, js_value(v));
    end
  end
  text = sprintf('{\n%s\n}\n', strjoin(lines, sprintf(',\n')));
end

% ============================================================================
% Plot (PNG) of the digitized curves
% ============================================================================

function plot_curves(curves, labels, cfg, png_path, show)
  colors = [31 119 180; 255 127 14; 44 160 44; 214 39 40; 148 103 189; ...
            140 86 75; 227 119 194; 127 127 127; 188 189 34; 23 190 207] / 255;
  if show
    fig = figure();
  else
    fig = figure('visible', 'off');
  end
  hold on;
  for k = 1:numel(curves)
    plot(curves{k}{1}, curves{k}{2}, 'Color', colors(mod(k - 1, 10) + 1, :), ...
         'LineWidth', 1.5);
  end
  if is_true(cfg, 'log_x')
    set(gca, 'XScale', 'log');
  end
  if is_true(cfg, 'log_y')
    set(gca, 'YScale', 'log');
  end
  axis([sort([cfg.min_x cfg.max_x]) sort([cfg.min_y cfg.max_y])]);
  grid on;
  box on;
  if isfield(cfg, 'title') && ~isempty(cfg.title)
    title(cfg.title, 'Interpreter', 'none');
  end
  if isfield(cfg, 'x_label') && ~isempty(cfg.x_label)
    xlabel(cfg.x_label, 'Interpreter', 'none');
  end
  if isfield(cfg, 'y_label') && ~isempty(cfg.y_label)
    ylabel(cfg.y_label, 'Interpreter', 'none');
  end
  if numel(curves) > 1
    legend(labels, 'Interpreter', 'none');
  end
  print(fig, png_path, '-dpng', '-r150');
  if ~show
    close(fig);
  end
end

% ============================================================================
% Axis & label recognition (tesseract OCR)
% ============================================================================

% Recognize axes and labels of chart image with chart area box. Returns
% the values found (min_x, max_x, log_x, grid_x and y, title, x_label,
% y_label) and report lines.
function [res, report] = detect_axes(im, box)
  [img_h, img_w, ~] = size(im);
  left = box(1); top = box(2); right = box(3); bottom = box(4);
  res = struct();
  report = {};
  if left <= 1 && top <= 1 && right >= img_w - 1 && bottom >= img_h - 1
    error('digi:ocr', 'chart area covers the whole image, no axis labels outside it to read');
  end

  % Chart area (grid, curves, annotations) painted white
  masked = im;
  masked(max(1, top - 1):min(img_h, bottom + 2), max(1, left - 1):min(img_w, right + 2), :) = 255;
  scale = min(3, max(1, floor(1600 / img_w + 0.5)));
  raw = ocr_words(masked, scale, 0);

  words = struct('text', {}, 'conf', {}, 'x0', {}, 'y0', {}, 'x1', {}, 'y1', {}, ...
                 'h', {}, 'cx', {}, 'cy', {}, 'isnum', {}, 'val', {}, 'alts', {}, 'pow', {});
  for k = 1:numel(raw)
    w = raw(k);
    x0 = w.x0 / scale; y0 = w.y0 / scale; x1 = w.x1 / scale; y1 = w.y1 / scale;
    [isnum, val, alts, is_pow] = parse_tick_number(w.text);
    words(end + 1) = struct('text', w.text, 'conf', w.conf, ...
      'x0', x0, 'y0', y0, 'x1', x1, 'y1', y1, 'h', y1 - y0, ...
      'cx', (x0 + x1) / 2, 'cy', (y0 + y1) / 2, ...
      'isnum', isnum, 'val', val, 'alts', alts, 'pow', is_pow); %#ok<AGROW>
  end
  W = right - left;
  H = bottom - top;
  if isempty(words)
    numeric = [];
  else
    numeric = find([words.isnum] & [words.conf] >= 35);
  end

  % X tick labels: the fullest row of numbers below the chart area
  x_cands = [];
  for k = numeric
    w = words(k);
    if w.y0 >= bottom - 0.5 * w.h && w.y0 <= bottom + max(4 * w.h, 0.15 * H) && ...
       w.cx >= left - 0.06 * W && w.cx <= right + 0.06 * W && w.x1 > left + 0.3 * w.h
      x_cands(end + 1) = k; %#ok<AGROW>
    end
  end
  if ~isempty(x_cands)
    [~, order] = sort([words(x_cands).y0]);
    x_cands = x_cands(order);
  end
  x_row = [];
  for seed = x_cands
    row = x_cands(abs([words(x_cands).cy] - words(seed).cy) < 0.7 * words(seed).h);
    if numel(row) > numel(x_row)
      x_row = row;
    end
  end

  % Y tick labels: nearest column of numbers left of the chart area
  y_cands = [];
  for k = numeric
    w = words(k);
    if w.x1 >= left - 0.35 * W && w.x1 <= left + 0.5 * w.h && ...
       w.cy >= top - 1.5 * w.h && w.cy <= bottom + 1.5 * w.h && ~any(x_row == k)
      y_cands(end + 1) = k; %#ok<AGROW>
    end
  end
  y_row = [];
  if ~isempty(y_cands)
    [~, order] = sort(-[words(y_cands).x1]);
    y_cands = y_cands(order);
    near = words(y_cands(1));
    for k = y_cands
      if words(k).x1 >= near.x1 - max(1.5 * words(k).h, near.x1 - near.x0)
        y_row(end + 1) = k; %#ok<AGROW>
      end
    end
  end

  % Label positions: center, or the chart edge for end labels aligned to it
  x_labels = struct('poss', {}, 'val', {}, 'alts', {}, 'pow', {}, 'conf', {});
  for k = x_row
    w = words(k);
    poss = w.cx;
    if abs(w.x0 - left) < 0.8 * w.h, poss(end + 1) = left + 0.5; end %#ok<AGROW>
    if abs(w.x1 - right) < 0.8 * w.h, poss(end + 1) = right - 0.5; end %#ok<AGROW>
    x_labels(end + 1) = struct('poss', poss, 'val', w.val, 'alts', w.alts, 'pow', w.pow, 'conf', w.conf); %#ok<AGROW>
  end
  y_labels = struct('poss', {}, 'val', {}, 'alts', {}, 'pow', {}, 'conf', {});
  for k = y_row
    w = words(k);
    poss = w.cy;
    if abs(w.y0 - top) < 0.5 * w.h, poss(end + 1) = top + 0.5; end %#ok<AGROW>
    if abs(w.y1 - bottom) < 0.5 * w.h, poss(end + 1) = bottom - 0.5; end %#ok<AGROW>
    y_labels(end + 1) = struct('poss', poss, 'val', w.val, 'alts', w.alts, 'pow', w.pow, 'conf', w.conf); %#ok<AGROW>
  end
  fits = {fit_axis(x_labels, W), fit_axis(y_labels, H)};
  rows = {x_row, y_row};
  names = {'x', 'y'};
  edges = [left + 0.5, right - 0.5; bottom - 0.5, top + 0.5];
  for a = 1:2
    name = names{a};
    fit = fits{a};
    if isempty(fit)
      report{end + 1} = sprintf('%s: not found (%d numeric labels)', name, numel(rows{a})); %#ok<AGROW>
      continue;
    end
    res.(['min_' name]) = g_digits(edge_value(fit, edges(a, 1)), 6);
    res.(['max_' name]) = g_digits(edge_value(fit, edges(a, 2)), 6);
    res.(['log_' name]) = fit.log;
    res.(['grid_' name]) = unique(fit.inl_v);
    if fit.log, scale_name = 'log'; else, scale_name = 'linear'; end
    report{end + 1} = sprintf('%s: %g ... %g %s (%d/%d labels)', name, ...
      res.(['min_' name]), res.(['max_' name]), scale_name, ...
      numel(fit.inl_v), numel(rows{a})); %#ok<AGROW>
  end

  % Text lines outside the tick labels: title, x label
  rest = true(1, numel(words));
  rest([x_row, y_row]) = false;
  lines = group_lines(words(rest));
  if ~isempty(lines)
    lines = lines([lines.conf] >= 50);
  end
  if isempty(x_row)
    x_tick_bottom = bottom;
  else
    x_tick_bottom = max([words(x_row).y1]);
  end
  in_span = @(ln) ln.cx >= left - 0.15 * W && ln.cx <= right + 0.15 * W;
  is_caption = @(ln) ~isempty(regexpi(ln.text, '^fig(ure|\.)?\s*\d', 'once'));

  x_label = [];
  for L = 1:numel(lines)
    ln = lines(L);
    if ~is_caption(ln) && in_span(ln) && ln.y0 >= x_tick_bottom - 2 && ...
       ln.y0 - x_tick_bottom < 6 * ln.h && (isempty(x_label) || ln.y0 < x_label.y0)
      x_label = ln;
    end
  end

  title_text = '';
  caption = [];
  for L = 1:numel(lines)
    if is_caption(lines(L)) && (isempty(caption) || lines(L).y0 < caption.y0)
      caption = lines(L);
    end
  end
  if ~isempty(caption)
    % Caption with its continuation lines
    parts = {caption.text};
    prev = caption;
    [~, order] = sort([lines.y0]);
    for L = order
      ln = lines(L);
      if ln.y0 > caption.y0 && ln.y0 - prev.y1 < 0.8 * prev.h && ...
         abs(ln.h - prev.h) < 0.35 * prev.h
        parts{end + 1} = ln.text; %#ok<AGROW>
        prev = ln;
      end
    end
    title_text = strjoin(parts, ' ');
  else
    best = [];
    for L = 1:numel(lines)
      ln = lines(L);
      if ln.y1 <= top + 2 && in_span(ln) && (isempty(best) || ln.h > best.h || ...
          (ln.h == best.h && ln.y0 < best.y0))
        best = ln;
      end
    end
    if ~isempty(best)
      title_text = best.text;
    end
  end
  if ~isempty(title_text)
    res.title = title_text;
  end
  if ~isempty(x_label)
    res.x_label = x_label.text;
  end

  % Y label: usually rotated, OCR the strip left of the y tick labels
  if isempty(y_row)
    strip_right = left - 2;
  else
    strip_right = min([words(y_row).x0]) - 2;
  end
  if strip_right >= 8
    region = [0, max(0, round(top - 0.05 * H)), round(strip_right), ...
              min(img_h, round(bottom + 0.05 * H))];
    y_label = recognize_rotated_label(im, region, scale);
    if ~isempty(y_label)
      res.y_label = y_label;
    end
  end
  report{end + 1} = ['title: ' field_or_dash(res, 'title')];
  report{end + 1} = ['x label: ' field_or_dash(res, 'x_label')];
  report{end + 1} = ['y label: ' field_or_dash(res, 'y_label')];
end

function s = field_or_dash(res, name)
  if isfield(res, name)
    s = res.(name);
  else
    s = '-';
  end
end

function v = g_digits(x, digits)
  v = arrayfun(@(y) str2double(sprintf(['%.' num2str(digits) 'g'], y)), x);
end

% Image upscaled by scale (linear interpolation, separable)
function out = upscale(img, scale)
  [h, w, c] = size(img);
  nw = max(1, round(w * scale));
  nh = max(1, round(h * scale));
  xs = min(max(((1:nw) - 0.5) / scale + 0.5, 1), w);
  ys = min(max(((1:nh) - 0.5) / scale + 0.5, 1), h);
  out = zeros(nh, nw, c, 'uint8');
  for k = 1:c
    plane = double(img(:, :, k));
    if h > 1
      plane = interp1((1:h)', plane, ys(:), 'linear');
    end
    if w > 1
      plane = interp1((1:w)', plane', xs(:), 'linear')';
    end
    out(:, :, k) = uint8(plane);
  end
end

% Words recognized by tesseract (psm 11, sparse text) in image img
% upscaled by scale and rotated (1: text reading bottom-to-top made
% horizontal, -1: top-to-bottom): struct array with text, conf, x0, y0,
% x1, y1 in the processed image
function words = ocr_words(img, scale, rotate)
  if scale ~= 1
    img = upscale(img, scale);
  end
  if rotate == 1
    img = rot90(img, -1);
  elseif rotate == -1
    img = rot90(img, 1);
  end
  file = [tempname() '.png'];
  imwrite(img, file);
  if ispc
    nul = 'NUL';
  else
    nul = '/dev/null';
  end
  [status, out] = system(sprintf( ...
    'tesseract "%s" stdout --psm 11 -c preserve_interword_spaces=1 tsv 2>%s', file, nul));
  delete(file);
  if status ~= 0
    error('digi:tesseract', 'tesseract failed (is it installed and on the PATH?)');
  end
  words = struct('text', {}, 'conf', {}, 'x0', {}, 'y0', {}, 'x1', {}, 'y1', {});
  rows = regexp(out, '\r?\n', 'split');
  for r = 2:numel(rows)
    cols = regexp(rows{r}, '\t', 'split');
    if numel(cols) < 12
      continue;
    end
    text = strtrim(strjoin(cols(12:end), ' '));
    conf = str2double(cols{11});
    if isempty(text) || ~(conf >= 20)
      continue;
    end
    l = str2double(cols{7}); t = str2double(cols{8});
    w = str2double(cols{9}); h = str2double(cols{10});
    words(end + 1) = struct('text', text, 'conf', conf, 'x0', l, 'y0', t, ...
                            'x1', l + w, 'y1', t + h); %#ok<AGROW>
  end
end

% Number of a tick label: isnum, value, alts and is_pow (label written as a
% power of ten: 10^3, 10⁻³, 10-3). alts are the powers of ten
% the label may be when read without its superscript: "103" for 10^3,
% "1073" for 10^-3 (superscript minus misread as 7), "10°" for 10^0.
% Handles unicode minus, superscripts, 1e-3, 2x10^3, SI prefixes (10m,
% 1k), thousands separators, decimal commas, units (5V, 20%) and O/l
% misreads.
function [isnum, val, alts, is_pow] = parse_tick_number(raw)
  isnum = false;
  val = NaN;
  alts = [];
  is_pow = false;
  s = raw;
  sup = {'⁻', '-'; '⁰', '0'; '¹', '1'; '²', '2'; '³', '3'; '⁴', '4'; ...
         '⁵', '5'; '⁶', '6'; '⁷', '7'; '⁸', '8'; '⁹', '9'};
  for k = 1:size(sup, 1)
    s = strrep(s, sup{k, 1}, ['^' sup{k, 2}]);
  end
  prev = '';
  while ~strcmp(prev, s)
    prev = s;
    s = regexprep(s, '\^([-0-9]+)\^', '^$1');
  end
  dashes = {'−', '–', '—', '‐', '‑'};
  for k = 1:numel(dashes)
    s = strrep(s, dashes{k}, '-');
  end
  s = regexprep(s, '\s+', '');
  s = regexprep(s, '^[(\[{''"`|:;]+', '');
  s = regexprep(s, '[)\]}''"`|:;,]+$', '');
  s = regexprep(s, '\.$', '');
  if strcmp(s, 'O') || strcmp(s, 'o')
    s = '0';
  end
  if isempty(s) || isempty(regexp(s, '\d', 'once'))
    return;
  end

  tok = regexp(s, '^([-+]?\d*\.?\d*)(?:x|×|\*|·)?10\^([-+]?\d{1,3})$', 'tokens', 'once');
  if ~isempty(tok)
    switch tok{1}
      case {'', '+'}
        mant = 1;
      case '-'
        mant = -1;
      otherwise
        mant = str2double(tok{1});
    end
    val = g_digits(mant * 10 ^ str2double(tok{2}), 12);
    isnum = isfinite(val);
    is_pow = true;
    return;
  end
  tok = regexp(s, '^10[-~](\d{1,2})$', 'tokens', 'once');
  if ~isempty(tok)
    val = 10 ^ (-str2double(tok{1}));
    isnum = true;
    is_pow = true;
    return;
  end

  tok = regexp(s, ['^([-+]?[\dOoIl]*[.,]?[\dOoIl]*\d[\dOoIl]*)([eE][-+]?\d{1,3})?' ...
                   '(p|n|u|µ|μ|m|k|K|M|G)?(A|V|W|Hz|s|Ω|F|H|°C|°|%|dB)?$'], 'tokens', 'once');
  if isempty(tok)
    return;
  end
  tok(end + 1:4) = {''};
  num = tok{1};
  num(num == 'O' | num == 'o') = '0';
  num(num == 'I' | num == 'l') = '1';
  if ~isempty(regexp(num, '^[-+]?\d{1,3},\d{3}$', 'once'))
    num = strrep(num, ',', '');
  else
    num = strrep(num, ',', '.');
  end
  val = str2double([num tok{2}]);
  if ~isfinite(val)
    val = NaN;
    return;
  end
  if ~isempty(tok{3})
    val = g_digits(val * si_prefix(tok{3}), 12);
  end
  if isempty(tok{2}) && isempty(tok{3})
    if strcmp(num, '10') && strcmp(tok{4}, '°')
      alts(end + 1) = 1;
    end
    e = regexp(num, '^10(\d{1,3})$', 'tokens', 'once');
    if ~isempty(e)
      d = e{1};
      if numel(d) <= 2 && str2double(d) <= 15
        alts(end + 1) = 10 ^ str2double(d);
      end
      if numel(d) >= 2 && d(1) == '7'
        alts(end + 1) = 10 ^ (-str2double(d(2:end)));
      end
    end
  end
  isnum = true;
end

function f = si_prefix(p)
  switch p
    case 'p', f = 1e-12;
    case 'n', f = 1e-9;
    case {'u', 'µ', 'μ'}, f = 1e-6;
    case 'm', f = 1e-3;
    case {'k', 'K'}, f = 1e3;
    case 'M', f = 1e6;
    case 'G', f = 1e9;
    otherwise, f = 1;
  end
end

function t = is_pow10(v)
  t = v > 0 & abs(log10(v) - round(log10(v))) < 1e-9;
end

% Robust (all pairs, inlier count) fit of tick labels to pixel positions:
% linear value = a * pos + b, or log10(value) = a * pos + b. A label may
% have alternative positions (poss: centered, or aligned to the chart edge
% as end labels often are), the one fitting best is used. Returns the
% better model (struct with mode, log, a, b, tol, inl_v, inl_pos, all_v)
% or [].
function fit = fit_axis(labels, axis_len)
  fit = [];
  tol = max(3, axis_len * 0.012);
  n_lab = numel(labels);
  with_alt = 0;
  pow_axis = false;  % labels written as powers of ten: log axis of powers of ten only
  for k = 1:n_lab
    with_alt = with_alt + ~isempty(labels(k).alts);
    pow_axis = pow_axis || labels(k).pow;
  end
  modes = {'plain', 'plain', 'alt'};
  logs = [false, true, true];
  fits = {};
  for m = 1:3
    mode = modes{m};
    is_log = logs(m);
    if (strcmp(mode, 'alt') && with_alt == 0) || (pow_axis && ~is_log)
      continue;
    end
    dl = [];
    dv = [];
    for k = 1:n_lab
      if strcmp(mode, 'alt') && ~isempty(labels(k).alts)
        vals = labels(k).alts;
      else
        vals = labels(k).val;
      end
      for v = vals(:)'
        if (is_log && v <= 0) || (pow_axis && ~is_pow10(v))
          continue;
        end
        dl(end + 1) = k; %#ok<AGROW>
        dv(end + 1) = v; %#ok<AGROW>
      end
    end
    if is_log
      dt = log10(dv);
    else
      dt = dv;
    end
    nd = numel(dl);
    best = [];
    best_key = [];
    for i = 1:nd
      for j = i + 1:nd
        if dt(i) == dt(j) || dl(i) == dl(j)
          continue;
        end
        for p_i = labels(dl(i)).poss
          for p_j = labels(dl(j)).poss
            if abs(p_i - p_j) < 2
              continue;
            end
            a = (dt(j) - dt(i)) / (p_j - p_i);
            if is_log && abs(a) * axis_len > 20
              continue;  % over 20 decades: misread labels
            end
            b = dt(i) - a * p_i;
            resid = 0;
            inl_d = [];
            inl_pos = [];
            for d = 1:nd
              p = (dt(d) - b) / a;
              poss = labels(dl(d)).poss;
              [r, q] = min(abs(p - poss));
              if r <= tol && ~any(dl(inl_d) == dl(d))
                resid = resid + r;
                inl_d(end + 1) = d; %#ok<AGROW>
                inl_pos(end + 1) = poss(q); %#ok<AGROW>
              end
            end
            % More inliers, then smaller residual (in steps of tol / 4),
            % then wider span (in steps of tol), then higher OCR confidence
            if isempty(inl_d)
              span = 0;
            else
              span = max(inl_pos) - min(inl_pos);
            end
            key = [numel(inl_d), -floor(resid / (tol / 4)), floor(span / tol), ...
                   sum([labels(dl(inl_d)).conf])];
            if isempty(best_key) || key_greater(key, best_key)
              best_key = key;
              best = struct('d', inl_d, 'pos', inl_pos, 'resid', resid);
            end
          end
        end
      end
    end
    if isempty(best) || numel(best.d) < 2
      continue;
    end
    tt = dt(best.d);
    pp = best.pos;
    mp = mean(pp);
    mt = mean(tt);
    den = sum((pp - mp) .^ 2);
    if den == 0
      continue;
    end
    a = sum((pp - mp) .* (tt - mt)) / den;
    b = mt - a * mp;
    if ~isfinite(a) || a == 0
      continue;
    end
    fits{end + 1} = struct('mode', mode, 'log', is_log, 'a', a, 'b', b, ...
      'tol', tol, 'inl_v', dv(best.d), 'inl_pos', pp, 'all_v', dv, ...
      'resid', best.resid / numel(tt)); %#ok<AGROW>
  end
  if isempty(fits)
    return;
  end
  counts = cellfun(@(f) numel(f.inl_v), fits);
  resids = cellfun(@(f) f.resid, fits);
  [~, order] = sortrows([-counts(:), resids(:)]);
  fits = fits(order);
  top = fits{1};
  tied = fits(cellfun(@(f) numel(f.inl_v), fits) == numel(top.inl_v));
  % Labels like "103" (10^3 without superscript) on most ticks
  alt = find(cellfun(@(f) strcmp(f.mode, 'alt'), tied), 1);
  if ~isempty(alt) && with_alt >= 0.75 * n_lab
    fit = tied{alt};
    return;
  end
  lin = find(cellfun(@(f) strcmp(f.mode, 'plain') && ~f.log, tied), 1);
  lg = find(cellfun(@(f) strcmp(f.mode, 'plain') && f.log, tied), 1);
  if ~isempty(lin) && ~isempty(lg)
    % Tie (typically 2 labels): log if all labels are powers of ten
    if all(is_pow10(tied{lg}.inl_v))
      fit = tied{lg};
    else
      fit = tied{lin};
    end
    return;
  end
  fit = top;
end

function g = key_greater(key, other)
  k = find(key ~= other, 1);
  g = ~isempty(k) && key(k) > other(k);
end

function v = fit_value(fit, pos)
  t = fit.a * pos + fit.b;
  if fit.log
    v = 10 .^ t;
  else
    v = t;
  end
end

function p = fit_pos(fit, v)
  if fit.log
    if v <= 0
      p = NaN;
      return;
    end
    t = log10(v);
  else
    t = v;
  end
  p = (t - fit.b) / fit.a;
end

% Axis value at pixel position pos, snapped to a label value or a round
% number whose position is within the fit tolerance
function v = edge_value(fit, pos)
  best_v = [];
  best_d = Inf;
  for k = 1:numel(fit.all_v)
    p = fit_pos(fit, fit.all_v(k));
    d = abs(p - pos);
    if isfinite(p) && d <= fit.tol && d < best_d
      best_v = fit.all_v(k);
      best_d = d;
    end
  end
  if ~isempty(best_v)
    v = best_v;
    return;
  end
  raw = fit_value(fit, pos);
  cands = [];
  if fit.log
    e = floor(log10(raw));
    for k = e - 1:e + 1
      cands = [cands, g_digits((1:9) * 10 ^ k, 12)]; %#ok<AGROW>
    end
  else
    diffs = sort(diff(sort(fit.inl_v)));
    diffs = diffs(diffs > 0);
    if isempty(diffs)
      step = abs(raw);
      if step == 0
        step = 1;
      end
    else
      step = diffs(floor(numel(diffs) / 2) + 1);
    end
    for div = [1 2 4 5 10]
      q = step / div;
      cands(end + 1) = g_digits(round(raw / q) * q, 12); %#ok<AGROW>
    end
  end
  for c = cands
    p = fit_pos(fit, c);
    d = abs(p - pos);
    if isfinite(p) && d <= fit.tol / 2 && d < best_d
      best_v = c;
      best_d = d;
    end
  end
  if isempty(best_v)
    v = g_digits(raw, 4);
  else
    v = best_v;
  end
end

% Group words into text lines (vertical overlap, small horizontal gaps)
function lines = group_lines(words)
  lines = struct('idx', {}, 'x0', {}, 'y0', {}, 'x1', {}, 'y1', {}, 'h', {}, ...
                 'text', {}, 'conf', {}, 'cx', {}, 'letters', {});
  if isempty(words)
    return;
  end
  [~, order] = sort([words.x0]);
  for k = order
    w = words(k);
    h = w.y1 - w.y0;
    joined = false;
    for L = 1:numel(lines)
      ln = lines(L);
      overlap = min(ln.y1, w.y1) - max(ln.y0, w.y0);
      gap = w.x0 - ln.x1;
      if overlap > 0.5 * min(h, ln.h) && gap > -h && gap < 2.5 * max(h, ln.h)
        ln.idx(end + 1) = k;
        ln.x1 = max(ln.x1, w.x1);
        ln.y0 = min(ln.y0, w.y0);
        ln.y1 = max(ln.y1, w.y1);
        ln.h = max(ln.h, h);
        lines(L) = ln;
        joined = true;
        break;
      end
    end
    if ~joined
      lines(end + 1) = struct('idx', k, 'x0', w.x0, 'y0', w.y0, 'x1', w.x1, ...
        'y1', w.y1, 'h', h, 'text', '', 'conf', 0, 'cx', 0, 'letters', 0); %#ok<AGROW>
    end
  end
  keep = true(1, numel(lines));
  for L = 1:numel(lines)
    txt = strjoin({words(lines(L).idx).text}, ' ');
    txt = strtrim(regexprep(regexprep(txt, '[|_]+', ' '), '\s+', ' '));
    lines(L).text = txt;
    lines(L).conf = mean([words(lines(L).idx).conf]);
    lines(L).cx = (lines(L).x0 + lines(L).x1) / 2;
    lines(L).letters = numel(regexp(txt, '[A-Za-z]'));
    keep(L) = lines(L).letters >= 2;
  end
  lines = lines(keep);
end

% Best text line of OCR passes over a rotated strip [x0 y0 x1 y1] of the
% image (vertical axis label)
function txt = recognize_rotated_label(im, region, scale)
  strip = im(region(2) + 1:region(4), region(1) + 1:region(3), :);
  txt = '';
  best_score = -Inf;
  best_conf = 0;
  for rotate = [1 -1]
    w = ocr_words(strip, scale, rotate);
    if ~isempty(w)
      w = w([w.conf] >= 40);
    end
    lines = group_lines(w);
    for L = 1:numel(lines)
      score = lines(L).letters * lines(L).conf;
      if score > best_score
        best_score = score;
        txt = lines(L).text;
        best_conf = lines(L).conf;
      end
    end
    if ~isempty(txt) && best_conf >= 75
      break;
    end
  end
end
