function showResult(handles)
global volumeImage;
global volumeSeg;
global sliceStatus;
global currentViewImageIndex;
global startSegIndex;
global ILabel;
I=volumeImage(:,:,currentViewImageIndex);
showI=repmat(I,1,1,3);
if(sliceStatus(currentViewImageIndex)==1)
    showI=addContourToImage(showI,volumeSeg(:,:,currentViewImageIndex));
end
if(currentViewImageIndex==startSegIndex)
    showI=addSeedsToImage(showI,ILabel);
end
imshow(showI);

function ISeg=addContourToImage(IRGB,Label)
Isize=size(IRGB);
ISeg=IRGB;
for i=1:Isize(1)
    for j=1:Isize(2)
        if(i==1 || i==Isize(1) || j==1 || j==Isize(2))
            continue;
        end
        if(Label(i,j)~=0 && ~(Label(i-1,j)~=0 && Label(i+1,j)~=0 && Label(i,j-1)~=0 && Label(i,j+1)~=0))
            for di=-1:0
                for dj=-1:0
                    idi=i+di;
                    jdj=j+dj;
                    if(idi>0 && idi<=Isize(1) && jdj>0 && jdj<=Isize(2))
                        ISeg(idi,jdj,1)=0;
                        ISeg(idi,jdj,2)=255;
                        ISeg(idi,jdj,3)=0;
                    end
                end
            end
        end
    end
end

function Iout=addSeedsToImage(IRGB,Label)
Isize=size(IRGB);
Iout=IRGB;
for i=1:Isize(1)
    for j=1:Isize(2)
        if(i==1 || i==Isize(1) || j==1 || j==Isize(2))
            continue;
        end
        if(Label(i,j)==127)
            Iout(i,j,1)=255;
            Iout(i,j,2)=0;
            Iout(i,j,3)=0;
        elseif(Label(i,j)==255)
            Iout(i,j,1)=0;
            Iout(i,j,2)=0;
            Iout(i,j,3)=255;
        end
    end
end