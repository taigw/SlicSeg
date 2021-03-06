classdef SlicSegAlgorithm < CoreBaseClass
    % SlicSegAlgorithm: implementation of the Slic-Seg interactive segmentation algorithm
    %
    % For a description of Slic-Seg see Wang et al 2006: Slic-Seg: A Minimally Interactive Segmentation
    % of the Placenta from Sparse and Motion-Corrupted Fetal MRI in Multiple Views
    %
    % To run the algorithm:
    %   - create a SlicSegAlgorithm object
    %   - set the volumeImage property to a raw 3D dataset
    %   - set the startIndex property to select a start slice
    %   - set the seedImage property to user-generated scribbles for the start slice
    %   - call StartSliceSegmentation() to segement the initial slice
    %   - set the sliceRange property to the minimum and maximum slice numbers for the propagation
    %   - call SegmentationPropagate() to propagate the start slice segmentation to neighbouring slices in the range set by sliceRange
    %
    %
    % Author: Guotai Wang
    % Copyright (c) 2014-2016 University College London, United Kingdom. All rights reserved.
    % http://cmictig.cs.ucl.ac.uk
    %
    % Distributed under the BSD-3 licence. Please see the file licence.txt 
    % This software is not certified for clinical use.
    %
    
    properties (SetObservable)
        volumeImage = ImageWrapper()      % 3D input volume image
        seedImage         % 3D seed image containing user-provided scribbles in each slice
        
        orientation = 3   % The index of the dimension perpendicular to the seedImage slice
        startIndex        % start slice index
        sliceRange        % 2x1 matrix to store the minimum and maximum slice index. Leave empty to use first and last slices
        
        lambda   = 10.0   % parameter for max-flow; controls the weight of unary term and binary term
        sigma    = 5      % parameter for max-flow; controls the sensitivity of intensity difference
        innerDis = 5      % radius of erosion when generating new training data
        outerDis = 6      % radius of dilation when generating new training data  
    end
    
    properties (SetAccess = private)
        segImage          % 3D image for segmentation result
        probabilityImage  % 3D image of probability of being foreground
        

    end
    
    events
        SegmentationProgress % Event fired after each image slice has been segmented
    end
    
    properties (Access = private)
        randomForest_foreward       % Using two Random Forests for propagating towards two directions
        randomForest_backward       % This makes segmentation faster than using a single Random Forest
        propagate_direction
    end
    
    methods
        function obj = SlicSegAlgorithm()
            if gpuDeviceCount < 1
                error('SlicSegAlgorithm:NoGpuFound', 'No suitable GPU card was found.');
            end
            
            % Compiles the necessary mex and cuda files
            CompileSlicSeg;
            
            % When these properties are changed, we invalidate the seed image and the segmentation results
            obj.AddPostSetListener(obj, 'volumeImage', @obj.ResetSeedAndSegmentationResultCallback);
            obj.AddPostSetListener(obj, 'orientation', @obj.ResetSeedAndSegmentationResultCallback);

            % When these properties are changed, we invalidate just the segmentation results
            obj.AddPostSetListener(obj, 'lambda', @obj.ResetSegmentationResultCallback);
            obj.AddPostSetListener(obj, 'sigma', @obj.ResetSegmentationResultCallback);
            obj.AddPostSetListener(obj, 'innerDis', @obj.ResetSegmentationResultCallback);
            obj.AddPostSetListener(obj, 'outerDis', @obj.ResetSegmentationResultCallback);
        end
        
        function RunSegmention(obj)
            % Runs the full segmentation. The seed image and start index must be set before calling this method.
            obj.StartSliceSegmentation();
            obj.SegmentationPropagate();
        end
        
        function StartSliceSegmentation(obj)
            % Creates a segmentation for the image slice specified in
            % startIndex. The seed image and start index must be set before calling this method.
            if(isempty(obj.startIndex) || isempty(obj.seedImage))
                error('startIndex and seedImage must be set before calling StartSliceSegmentation()');
            end
           
            imageSize = obj.volumeImage.getImageSize;
            if((obj.startIndex < 1) || (obj.startIndex > imageSize(obj.orientation)))
                 error('startIndex is not set to a valid value in the range for this image size and orientation');
            end
            seedLabels = obj.GetSeedLabelImage();
            currentSegIndex = obj.startIndex;
            volumeSlice = obj.volumeImage.get2DSlice(currentSegIndex, obj.orientation);
            obj.propagate_direction = 1;
            trained = obj.Train(seedLabels, volumeSlice);
            obj.propagate_direction = 2;
            trained = obj.Train(seedLabels, volumeSlice);
            if(~trained)
                error('Please add more scribbles to create an appropriate training set');
            end
            P0 = obj.Predict(volumeSlice);
            probabilitySlice = SlicSegAlgorithm.ProbabilityProcessUsingConnectivity(seedLabels, P0, volumeSlice);
            segmentationSlice = SlicSegAlgorithm.GetSingleSliceSegmentation(seedLabels, volumeSlice, probabilitySlice, obj.lambda, obj.sigma);            
            obj.UpdateResults(currentSegIndex, segmentationSlice, probabilitySlice);
        end
        
        function SegmentationPropagate(obj)
            % Propagates the segmentation obtained from StartSliceSegmentation() to the remaining slices
            
            maxSliceIndex = obj.volumeImage.getMaxSliceNumber(obj.orientation);
            
            % If no slice range has been specified we use the image limits
            if isempty(obj.sliceRange)
                minSlice = 1;
                maxSlice = maxSliceIndex;
            else
                minSlice = obj.sliceRange(1);
                maxSlice = obj.sliceRange(2);
                if (minSlice < 1) || (maxSlice > maxSliceIndex)
                    error('Slice index is out of range for the current image orientation');
                end
            end
            
            % Propagate backwards from the initial slice
            priorSegIndex = obj.startIndex;
            obj.propagate_direction = 1;
            for currentSegIndex = obj.startIndex-1 : -1 : minSlice
                obj.PropagateAndTrain(currentSegIndex, priorSegIndex);
                priorSegIndex=currentSegIndex;
            end
            
            % Propagate forwards from the initial slice
            priorSegIndex = obj.startIndex;
            obj.propagate_direction = 2;
            for currentSegIndex = obj.startIndex+1 : maxSlice
                obj.PropagateAndTrain(currentSegIndex, priorSegIndex);
                priorSegIndex=currentSegIndex;
            end
        end
        
        function Refine(obj, currentSliceIdx)
            imgSlice  = obj.volumeImage.get2DSlice(currentSliceIdx, obj.orientation);
            seedSlice = obj.seedImage.get2DSlice(currentSliceIdx, obj.orientation);
            probSlice = obj.probabilityImage.get2DSlice(currentSliceIdx, obj.orientation);
            initSegSlice = obj.segImage.get2DSlice(currentSliceIdx, obj.orientation);
            initSegSlice = (1-initSegSlice)*128 + 127;
            seedDistance = bwdist(seedSlice);
            seedSlice(seedDistance > 15) = initSegSlice(seedDistance > 15);
            [flow, currentSegLabel] = interactive_maxflowmex(imgSlice, seedSlice, probSlice, obj.lambda, obj.sigma);
            currentSegLabel = 1-currentSegLabel;
            se = strel('disk', 2);
            currentSegLabel = imclose(currentSegLabel, se);
            currentSegLabel = imopen(currentSegLabel, se);
            obj.segImage.replaceImageSlice(currentSegLabel, currentSliceIdx, obj.orientation);
        end
        function Reset(obj)
            % Resets the random forest and results
            obj.randomForest_foreward = [];
            obj.randomForest_backward = [];
            obj.propagate_direction = [];
            obj.volumeImage = [];
            obj.ResetSegmentationResult();
            obj.ResetSegmentationResult();
        end
        
        function ResetSegmentationResult(obj)
            % Deletes the current segmentation results
            fullImageSize = obj.volumeImage.getImageSize;
            obj.segImage = ImageWrapper(zeros(fullImageSize, 'uint8'));
            obj.probabilityImage = ImageWrapper(zeros(fullImageSize));
            obj.seedImage = ImageWrapper(zeros(fullImageSize, 'uint8'));
        end
        
        function ResetSeedPoints(obj)
            % Deletes the current seed points
            fullImageSize = obj.volumeImage.getImageSize;
            obj.seedImage = ImageWrapper(zeros(fullImageSize, 'uint8'));
        end
        
        function set.volumeImage(obj, volumeImage)
            % Custom setter method to ensure existing results are invalidated by a change of image
            obj.volumeImage = ImageWrapper(volumeImage);
            obj.ResetSegmentationResult();
            obj.ResetSeedPoints();
        end
        
        function slice = GetSeedSlice(obj, idx)
            slice = obj.seedImage.get2DSlice(idx, obj.orientation);
        end
        
        function AddSeeds(obj, seeds, foreground)
            radius=2;
            if(foreground)
                labelIndex = 127;
            else
                labelIndex = 255;
            end
            sliceSize = obj.seedImage.get2DSliceSize(obj.orientation);
            seeds_number = length(seeds);
            for id = 1:seeds_number/3
                x = seeds((id-1)*3 + 1);
                y = seeds((id-1)*3 + 2);
                z = seeds((id-1)*3 + 3);
                imin = max(1, x-radius);
                imax = min(sliceSize(1), x+radius);
                jmin = max(1, y-radius);
                jmax = min(sliceSize(2), y+radius);
                for i = imin : imax
                    for j = jmin : jmax
                        obj.seedImage.setPixelValue(i, j, z, labelIndex);
                    end
                end
            end
        end
    end
    
    methods (Access=private)
        function trained = Train(obj, currentTrainLabel, volumeSlice)
            % train the random forest using scribbles in on slice
            featureMatrix = image2FeatureMatrix(volumeSlice);
            if(isempty(currentTrainLabel) || ~any(currentTrainLabel(:)>0))
                trained = false;
                return
            end
            foreground=find(currentTrainLabel==127);
            background=find(currentTrainLabel==255);
            totalseeds=length(foreground)+length(background);
            if(totalseeds==0)
                trained = false;
                return
            end
            TrainingSet=zeros(totalseeds,size(featureMatrix,2));
            TrainingLabel=zeros(totalseeds,1);
            TrainingSet(1:length(foreground),:)=featureMatrix(foreground,:);
            TrainingLabel(1:length(foreground))=1;
            TrainingSet(length(foreground)+1:length(foreground)+length(background),:)=featureMatrix(background,:);
            TrainingLabel(length(foreground)+1:length(foreground)+length(background))=0;
            TrainingDataWithLabel=[TrainingSet,TrainingLabel];
            obj.getRandomForest.Train(TrainingDataWithLabel');
            trained = true;
        end
        
        function randomForest = getRandomForest(obj)
            if isempty(obj.randomForest_foreward)
                obj.randomForest_foreward = ForestWrapper();
                obj.randomForest_foreward.Init(20,8,20);        
            end
            if isempty(obj.randomForest_backward)
                obj.randomForest_backward = ForestWrapper();
                obj.randomForest_backward.Init(20,8,20);        
            end
            if (obj.propagate_direction == 1)
                randomForest = obj.randomForest_foreward;
            else
                randomForest = obj.randomForest_backward;
            end
        end
        
        function PropagateAndTrain(obj, currentSegIndex, priorSegIndex)
            % Get prediction for current slice using previous slice segmentation as a prior
            currentVolumeSlice = obj.volumeImage.get2DSlice(currentSegIndex, obj.orientation);
            priorSegmentedSlice = obj.segImage.get2DSlice(priorSegIndex, obj.orientation);
            segmentationSlice = zeros(size(priorSegmentedSlice));
            probabilitySlice = zeros(size(priorSegmentedSlice));
            if(sum(priorSegmentedSlice(:)) > 10)
                % use roi to crop the image to save runtime
                roi = SlicSegAlgorithm.GetSegmentationROI(priorSegmentedSlice);
                roiCurrentSlice = currentVolumeSlice(roi(1):roi(2),roi(3):roi(4));
                roiP0 = obj.Predict(roiCurrentSlice);
                roiPriorSegSlice = priorSegmentedSlice(roi(1):roi(2),roi(3):roi(4));
                roiProbSlice = SlicSegAlgorithm.ProbabilityProcessUsingShapePrior(roiP0, roiPriorSegSlice);

                % Compute seed labels based on previous slices
                [priorSeedLabel, ~] = SlicSegAlgorithm.getSeedLabels(roiPriorSegSlice, obj.innerDis, obj.outerDis);
                roiSegSlice = SlicSegAlgorithm.GetSingleSliceSegmentation(priorSeedLabel, roiCurrentSlice, roiProbSlice, obj.lambda, obj.sigma);

                % Further train the algorithm based on the newly segmented slice
                [~, currentTrainLabel] = SlicSegAlgorithm.getSeedLabels(roiSegSlice, obj.innerDis, obj.outerDis);                
                obj.Train(currentTrainLabel, roiCurrentSlice);

                % Update the output images
                segmentationSlice(roi(1):roi(2),roi(3):roi(4)) = roiSegSlice;
                probabilitySlice(roi(1):roi(2),roi(3):roi(4)) = roiProbSlice;
            end
            obj.UpdateResults(currentSegIndex, segmentationSlice, probabilitySlice);
        end
        
        function UpdateResults(obj, currentSegIndex, segmentationSlice, probabilitySlice)
            obj.segImage.replaceImageSlice(segmentationSlice, currentSegIndex, obj.orientation);
            obj.probabilityImage.replaceImageSlice(probabilitySlice, currentSegIndex, obj.orientation);
            notify(obj,'SegmentationProgress', SegmentationProgressEventDataClass(currentSegIndex));
        end
        
        function label = GetSeedLabelImage(obj)
            label = obj.seedImage.get2DSlice(obj.startIndex, obj.orientation);
            foreground_empty = isempty(find(label == 127, 1));
            if(foreground_empty)
                error('scribbles for foreground should be provided');
            end
            [H,W] = size(label);
            for i = 5:5:H-5
                label(i,5)=255;
                label(i,W-5)=255;
            end
            for j = 5:5:W-5
                label(5,j)=255;
                label(H-5,j)=255;
            end
        end
        
        function ResetSeedAndSegmentationResultCallback(obj, ~, ~, ~)
            obj.ResetSeedPoints();
            obj.ResetSegmentationResult();
        end
        
        function ResetSegmentationResultCallback(obj, ~, ~, ~)
            obj.ResetSegmentationResult();
        end
        
        function P0 = Predict(obj, volumeSlice)
            featureMatrix = image2FeatureMatrix(volumeSlice);
            Prob = obj.getRandomForest.Predict(featureMatrix');
            P0 = reshape(Prob, size(volumeSlice,1), size(volumeSlice,2));
        end
    end
    
    methods (Static, Access = private) 
        function P = ProbabilityProcessUsingShapePrior(P0,lastSeg)
            Isize=size(lastSeg);
            dis=zeros(Isize);
            se= strel('disk',1);
            temp0=lastSeg;
            temp1=imerode(temp0,se);
            currentdis=0;
            while(~isempty(find(temp1 > 0, 1)))
                dis0=temp0-temp1;
                currentdis=currentdis+1;
                dis(dis0>0)=currentdis;
                temp0=temp1;
                temp1=imerode(temp0,se);
            end
            maxdis=currentdis;
            
            P=P0;
            outsideIndex=intersect(find(dis==0),find(P>0.5));
            P(outsideIndex)=0.4*P(outsideIndex);
            insideIndex=intersect(find(dis>0) , find(P<0.8));
            P(insideIndex)=P(insideIndex)+0.2*dis(insideIndex)/maxdis;
        end
        
        function P = ProbabilityProcessUsingConnectivity(currentSeedLabel,P0,I)
            PL=P0>=0.5;
            pSe= strel('disk',3);
            pMask=imclose(PL,pSe);
            [H,W]=size(P0);
            HW=H*W;
            indexHW=uint32(zeros(HW,1));
            seedsIndex=find(currentSeedLabel==127);
            seeds=length(seedsIndex);
            indexHW(1:seeds)=seedsIndex(1:seeds);
            L=uint8(zeros(H,W));
            P=P0;
            L(seedsIndex)=1;
            P(seedsIndex)=1.0;
            
            fg=I(seedsIndex);
            fg_mean=mean(fg);
            fg_std=sqrt(var(double(fg)));
            fg_min=fg_mean-fg_std*3;
            fg_max=fg_mean+fg_std*2;
            
            current=1;
            while(current<=seeds)
                currentIndex=indexHW(current);
                NeighbourIndex=[currentIndex-1,currentIndex+1,...
                    currentIndex+H,currentIndex+H-1,currentIndex+H+1,...
                    currentIndex-H,currentIndex-H-1,currentIndex-H+1];
                for i=1:8
                    tempIndex=NeighbourIndex(i);
                    if(tempIndex>0 && tempIndex<HW && L(tempIndex)==0 && pMask(tempIndex)>0 && I(tempIndex)>fg_min && I(tempIndex)<fg_max)
                        L(tempIndex)=1;
                        seeds=seeds+1;
                        indexHW(seeds,1)=tempIndex;
                    end
                end
                current=current+1;
            end
            
            Lindex=find(L==0);
            P(Lindex)=P(Lindex)*0.4;
        end
        
        function seg = GetSingleSliceSegmentation(currentSeedLabel, currentI, currentP, lambda, sigma)
            % use max flow to get the segmentation in one slice
            currentSeed = currentSeedLabel;
            [flow, currentSegLabel] = interactive_maxflowmex(currentI, currentSeed, currentP, lambda, sigma);
            currentSegLabel = 1-currentSegLabel;
            se = strel('disk', 2);
            currentSegLabel = imclose(currentSegLabel, se);
            currentSegLabel = imopen(currentSegLabel, se);
            seg = currentSegLabel(:,:);
        end
        
        function [currentSeedLabel, currentTrainLabel] = getSeedLabels(currentSegImage, fgr, bgr)
            % generate new training data (for random forest) and new seeds
            % (hard constraint for max-flow) based on segmentation in the last slice
            
            tempSegLabel=currentSegImage;
            fgSe1=strel('disk',fgr);
            fgMask=imerode(tempSegLabel,fgSe1);
            if(length(find(fgMask>0))<100)
                fgMask=bwmorph(tempSegLabel,'skel',Inf);
            else
                fgMask=bwmorph(fgMask,'skel',Inf);
            end
            bgSe1=strel('disk',bgr);
            bgSe2=strel('disk',bgr+1);
            fgDilate1=imdilate(tempSegLabel,bgSe1);
            fgDilate2=imdilate(tempSegLabel,bgSe2);
            bgMask=fgDilate2-fgDilate1;
            currentTrainLabel=uint8(zeros(size(tempSegLabel)));
            currentTrainLabel(fgMask>0)=127;
            currentTrainLabel(bgMask>0)=255;
            
            bgMask=1-fgDilate1;
            currentSeedLabel=uint8(zeros(size(tempSegLabel)));
            currentSeedLabel(fgMask>0)=127;
            currentSeedLabel(bgMask>0)=255;
        end
        
        function ROI = GetSegmentationROI(segLabel)
            [row, col] = find(segLabel > 0);
            h0 = min(row);
            h1 = max(row);
            w0 = min(col);
            w1 = max(col);
            [H, W] = size(segLabel);
            M = 25;
            h0 = max(1, h0 - M);
            h1 = min(H, h1 + M);
            w0 = max(1, w0 - M);
            w1 = min(W, w1 + M);
            ROI = [h0, h1, w0, w1];
        end
    end    
end
