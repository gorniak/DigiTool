%   Copyright 2023 Radoslaw Gorniak
%   Author  - Radoslaw Gorniak
%   License - MIT License
%   Website - https://github.com/gorniak/DigiTool

clc;
close all;
clear all;
pkg load image;

%%% Config section
image_name = "chart1.png";
image_crop_sufix = "_crop";
image_nogrid_sufix = "_nogrid";
% Optional sufix to name particular curve
image_name_sufix = "";
% Crop original file to chart area
% 1 to crop original chart for image_name file or
% 0 use file fir _crop sufix (previously cropped)
crop = 0;
no_grid = 0;
swap_x_y = 0;

% Make flatten image (black and white)
function stat = imstat(im)
  im_size = size(im);
  stat = zeros(im_size(1),im_size(2));
  for i=1:im_size(1)
    for j=1:im_size(2)
      % Enhance black color
%      stat(i,j) = 255 - max([double(im(i,j,1)) double(im(i,j,2)) double(im(i,j,3))]);
      % Enhance other than white
      stat(i,j) = 255 - min([im(i,j,1), im(i,j,2), im(i,j,3)]);
      end
  end
end

% Make the flatten view from Y-axis
function staty = imstaty(im)
  stat = imstat(im);
  im_size = size(im);
  staty = zeros(im_size(1),1);
  for i=1:im_size(1)
    for j=1:im_size(2)
      staty(i) = staty(i) + stat(i,j);
    end
  end
end

% Make the flatten view from X-axis
function statx = imstatx(im)
  stat = imstat(im);
  im_size = size(im);
  statx = zeros(im_size(2),1);
  for j=1:im_size(2)
    for i=1:im_size(1)
      statx(j) = statx(j) + stat(i,j);
    endfor
  endfor
endfunction

% Find peaks
function peaks = peakseek(in, treshold)
  peaks = [];
  peaks_wide = [];
  peaks_group = [];
  in_size = size(in);
  if (in_size(1) == 1) || (in_size(2) == 1)
    if (in_size(1) == 1)
      in = flip(in);
      length_in = in_size(2);
    else
      length_in = in_size(1);
    endif
    treshold_in = max(in) * treshold;
    for i=1:length_in
      if in(i) > treshold_in
        peaks_wide = [peaks_wide i];
      endif
    endfor
    peaks_group(1) = peaks_wide(1);
    for i=2:length(peaks_wide)
      peaks_group(i) = peaks_wide(i) - peaks_wide(i-1);
    endfor

    ptr=1;
    peaks_val = [];
    peaks_pos = [];
    do
      peak_val = [];
      peak_pos = [];
      do
        peak_val = [peak_val in(peaks_wide(ptr))];
        peak_pos = [peak_pos peaks_wide(ptr)];
        ptr++;
        if (ptr>length(peaks_group))
          break;
        endif
      until (peaks_group(ptr)>1)
      x=0;
      d=0;
      for i=1:length(peak_pos)
        if peak_val(i) == max(peak_val)
          x = x + peak_pos(i);
          d = d + 1;
        endif
      endfor
      if (d > 0)
        peaks_pos=[peaks_pos x/d];
        peaks_val=[peaks_val max(peak_val)];
      endif
    until (ptr>length(peaks_group))
    peaks(1:length(peaks_val),1) = peaks_pos;
    %peaks(1:length(peaks_val),2) = peaks_val;
  endif
endfunction

% Crop image to chart grid
function im_out = imcrop_chart(im)
  % Make the histograms of flatten view
  im_statx = imstatx(im);
  im_staty = imstaty(im);
  % Find border (and grid) of chart
  peaks_x = peakseek(im_statx, 0.9);
  peaks_y = peakseek(im_staty, 0.9);

  % DEBUG - Plot histogram views
  %figure();
  %plot(im_staty);
  %figure();
  %plot(im_statx);

  % Crop image
  im_out = im(min(peaks_y):max(peaks_y),min(peaks_x):max(peaks_x),1:3);
endfunction

% Remove grid - all gray (including black) pixels in range of grid
function im_out = imremove_grid(im)
  im_size = size(im);
  im_out = im;
  im_staty = imstaty(im);
  tresholdy = max(im_staty)*0.15;
  for i=1:im_size(1)
    if (im_staty(i) > tresholdy)
      for j=1:im_size(2)
        if (var([im(i,j,1) im(i,j,2) im(i,j,3)]) < 10)
            im_out(i,j,1) = 255;
            im_out(i,j,2) = 255;
            im_out(i,j,3) = 255;
        endif
      endfor
    endif
  endfor

  im_statx = imstatx(im);
  tresholdx = max(im_statx)*0.15;
  for j=1:im_size(2)
    if (im_statx(j) > tresholdx)
      for i=1:im_size(1)
        if (var([im(i,j,1) im(i,j,2) im(i,j,3)]) < 10)
            im_out(i,j,1) = 255;
            im_out(i,j,2) = 255;
            im_out(i,j,3) = 255;
        endif
      endfor
    endif
  endfor
  % DEBUG - Plot histogram views
  figure();
  plot(im_staty);
  figure();
  plot(im_statx);
endfunction

% Remove all gray (including black) pixels
function im_out = imremove_gray(im)
  im_size = size(im);
  im_out = im;
  for i=1:im_size(1)
    for j=1:im_size(2)
      if (var([im(i,j,1) im(i,j,2) im(i,j,3)]) < 10)
          im_out(i,j,1) = 255;
          im_out(i,j,2) = 255;
          im_out(i,j,3) = 255;
      endif
    endfor
  endfor
endfunction

%%% Main program
% Start timer
tic;

[file_path file_name file_ext] = fileparts(image_name);

% Open JSON file with configuration
fileID = fopen(strjoin({file_name, ".json"}, ""), "r");
json=fscanf(fileID, "%s");
fclose(fileID);
% Decode JSON to structure
config = jsondecode(json);

% Crop initial picture
if (crop == 1)
  image = imread(image_name);
  image_crop = imcrop_chart(image);
  imwrite(image_crop, strjoin ({file_name, image_crop_sufix, file_ext}, ""));
  toc
  display("Chart cropped.");
% or use previously cropped
else
  image_crop = imread(strjoin ({file_name, image_crop_sufix, file_ext}, ""));
endif

im_stat = imstat(image_crop);
im_statx = imstatx(image_crop);
im_staty = imstaty(image_crop);

peaks_x = peakseek(im_statx, 0.15);
peaks_y = peakseek(im_staty, 0.15);


% DEBUG - Plot histogram views
%figure();
%plot(im_staty);
%figure();
%plot(im_statx);

% Remove grid from picture
if (no_grid == 1)
  if ((config.color(1) == 0)
    && (config.color(2) == 0)
    && (config.color(3) == 0))
    image_nogrid = imremove_grid(image_crop);
  else
    image_nogrid = imremove_gray(image_crop);
  end
  imwrite(image_nogrid, strjoin({file_name, image_nogrid_sufix, file_ext}, ""));
  toc
  display("Grid removed.");
% or use previously nogrid image
else
  image_nogrid = imread(strjoin({file_name, image_nogrid_sufix, file_ext}, ""));
endif

% Add linear interpolation to points matrix
function interpoints = linear_interpolation(points)
  points_size = size(points);
  len = points_size(2);
  a = zeros(1,len);
  b = zeros(1,len);
  for i=1:(len-1)
    x1 = points(1,i);
    y1 = points(2,i);
    x2 = points(1,i+1);
    y2 = points(2,i+1);
    a(i) = (y1-y2)/(x1-x2);
    b(i) = y1-a(i)*x1;
  endfor
  a(len) = a(len-1);
  b(len) = b(len-1);
  interpoints = [points(1,:); points(2,:); a; b];
endfunction

% Make digital points matrix from chart picture
function chart_points = digitalize(im, color)
  im_size = size(im);
  chart_points_pos = [];
  chart_points_val = [];
  for (j = 1:im_size(2))
    point = [];
    for (i = im_size(1):-1:1)
      if ((abs(double(im(i,j,1)) - double(color(1))) < 10)
        && (abs(double(im(i,j,2)) - double(color(2))) < 10)
        && (abs(double(im(i,j,3)) - double(color(3))) < 10))
          point = [point im_size(1) - i + 1];
      endif
    endfor
    if (isempty(point) == 0)
      chart_points_pos = [chart_points_pos j];
      chart_points_val = [chart_points_val median(point)];
    endif
  endfor
  chart_points = [chart_points_pos; chart_points_val];
endfunction

function swap_im = swap_chart(im)
  swap_im = flip(rot90(rot90(rot90(im))));
end

if (isfield(config, "swap_x_y"))
  swap_x_y = config.swap_x_y;
end
if (swap_x_y == 1)
  image_nogrid = swap_chart(image_nogrid);
  points = digitalize(image_nogrid, config.color);
  image_nogrid = swap_chart(image_nogrid);
  points = [points(2,:); points(1,:)];
else
  points = digitalize(image_nogrid, config.color);
end
toc
display("Chart digitalized");

% DEBUG - Plot not-scaled data
%figure();
%plot(points(1,:), points(2,:));

% Scale linear values
function scaled_points = scale_linear(points, min_x, max_x, min_x_val, max_x_val)
  len = length(points);
  scaled_points = zeros(1,len);
  x1 = min_x;
  y1 = min_x_val;
  x2 = max_x;
  y2 = max_x_val;
  a = (y1-y2)/(x1-x2);
  b = y1-a*x1;
  for i=1:len
      scaled_points(i) = a*points(i)+b;
  end
end

% Scale logarithmic values
function scaled_points = scale_log(points, min_x, max_x, min_x_val, max_x_val)
  len = length(points);
  scaled_points = zeros(1,len);
  x1 = min_x;
  y1 = log10(min_x_val);
  x2 = max_x;
  y2 = log10(max_x_val);
  a = (y1-y2)/(x1-x2);
  b = y1-a*x1;
  for i=1:len
      scaled_points(i) = 10 ^ (a * points(i) + b);
  end
end

if(config.log_x == 0)
  scaled_x = scale_linear(points(1,:), 1, length(im_statx), config.min_x, config.max_x);
end
if(config.log_x == 1)
  scaled_x = scale_log(points(1,:), 1, length(im_statx), config.min_x, config.max_x);
end

if(config.log_y == 0)
  scaled_y = scale_linear(points(2,:), 1, length(im_staty), config.min_y, config.max_y);
  scaled_y = scale_linear(scaled_y, min(scaled_y), max(scaled_y), config.min_curve_y, config.max_curve_y);
end
if(config.log_y == 1)
  scaled_y = scale_log(points(2,:), 1, length(im_staty), config.min_y, config.max_y);
end

figure();
if ((config.log_x == 0) && (config.log_y == 0))
  plot(scaled_x, scaled_y);
end
if ((config.log_x == 1) && (config.log_y == 0))
  semilogx(scaled_x, scaled_y);
end
if ((config.log_x == 0) && (config.log_y == 1))
  semilogy(scaled_x, scaled_y);
end
if ((config.log_x == 1) && (config.log_y == 1))
  loglog(scaled_x, scaled_y);
end
axis([config.min_x config.max_x config.min_y config.max_y]);
grid on;

data_points = [flip(rotdim(scaled_x)) flip(rotdim(scaled_y))];

csvwrite(strjoin({file_name, image_name_sufix, ".csv"}, ""), data_points, "delimiter", ";", "newline", "\n");

% Revision history
%{
2023-09-02 Initial version
%}
