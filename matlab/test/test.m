clear;
slicSeg=SlicSegAlgorithm;
slicSeg.lambda = 5.0;
slicSeg.sigma = 3.5;
slicSeg.innerDis = 6;
slicSeg.outerDis = 6;
imageFilepath = mfilename('fullpath');
[imageFilepath, ~, ~] = fileparts(imageFilepath);
slicSeg.volumeImage = OpenPNGImage(fullfile(imageFilepath, 'a23_05', 'img'));
slicSeg.seedImage = OpenScribbleImage(fullfile(imageFilepath, 'a23_05', '22_seedsrgb.png'));
slicSeg.startIndex = 22;
slicSeg.sliceRange = [5,38];
slicSeg.RunSegmention();
tempDir = fullfile(tempdir(), 'a23_05');
if ~exist(tempDir, 'dir')
    mkdir(tempDir);
end
SavePNGSegmentation(slicSeg.segImage, fullfile(tempDir, 'seg'), 3);
