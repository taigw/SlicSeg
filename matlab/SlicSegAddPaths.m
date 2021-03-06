function SlicSegAddPaths(varargin)
    % SlicSegAddPaths Set up paths for executing Slic-Seg
    %
    % This script temporarily adds required paths to Matlab's path
    % To increase execution time, a persistent variable is used to record
    % if the paths have already been set
    %
    %
    % Author: Tom Doel
    % Distributed under the BSD-3 licence. Please see the file licence.txt 
    % This software is not certified for clinical use.
    %
    
    force = nargin > 0 && strcmp(varargin{1}, 'force');
    
    % This version number should be incremented whenever new paths are added to
    % the list
    SlicSegAddPaths_Version_Number = 2;
    
    % Persistent variable used to note that paths have already been set.
    % This stores the file versin number so that the paths will be re-added
    % if the code is updated and new paths are added
    persistent SlicSeg_PathsHaveBeenSet
    
    full_path = mfilename('fullpath');
    [path_root, ~, ~] = fileparts(full_path);
    
    if force || (isempty(SlicSeg_PathsHaveBeenSet) || SlicSeg_PathsHaveBeenSet ~= SlicSegAddPaths_Version_Number)
        
        path_folders = {};
        
        % List of folders to add to the path
        path_folders{end + 1} = '';
        path_folders{end + 1} = fullfile('gui');
        path_folders{end + 1} = fullfile('test');
        path_folders{end + 1} = fullfile('imageIO');
        path_folders{end + 1} = fullfile('imageIO', 'NIfTI_20140122');
        path_folders{end + 1} = fullfile('library', 'coremat');
        path_folders{end + 1} = fullfile('library', 'dicomat');
        path_folders{end + 1} = fullfile('library', 'dwt');
        path_folders{end + 1} = fullfile('library', 'FeatureExtract');
        path_folders{end + 1} = fullfile('library', 'maxflow');
        path_folders{end + 1} = fullfile('library', 'OnlineRandomForest');

        AddToPath(path_root, path_folders)
        
        CoreAddPaths(varargin{:});
        
        SlicSeg_PathsHaveBeenSet = SlicSegAddPaths_Version_Number;
    end
    
end

function AddToPath(path_root, path_folders)
    full_paths_to_add = {};
    
    % Get the full path for each folder but check it exists before adding to
    % the list of paths to add
    for i = 1 : length(path_folders)
        full_path_name = fullfile(path_root, path_folders{i});
        if exist(full_path_name, 'dir')
            full_paths_to_add{end + 1} = full_path_name;
        end
    end
    
    % Add all the paths together (much faster than adding them individually)
    if ~isempty(full_paths_to_add) 
        addpath(full_paths_to_add{:});
    end
    
end