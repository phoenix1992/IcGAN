require 'image'
require 'nn'
optnet = require 'optnet'
disp = require 'display'
torch.setdefaulttensortype('torch.FloatTensor')

local opt = {
    nImages = 13,         -- number of samples to produce (only valid if loadOption != 1)
    decNet = 'checkpoints/c_mnist_25_net_G.t7',--'checkpoints/experiment1_10_net_G.t7',-- path to the generator network
    encNet = 'checkpoints/encoder_c_mnist_6epochs.t7',--'checkpoints/encoder128Filters2FC_dataset2_2_6epochs.t7',
    gpu = 1,               -- gpu mode. 0 = CPU, 1 = GPU
    nz = 100,
    loadOption = 2,  -- 0 = only generated images used, 1 = load input image, 2 = load multiple input images
    loadPath = 'mnist/imagesTest', --'mnist/images', -- path used when load is 1 (path to single image) or 2 (path to folder with images)
    name = 'encoder_disentangle',
    -- Conditional GAN parameters
    dataset = 'mnist',
    threshold = true, -- (celebA only) true: threshold original encoded Y to binary 
}

local function applyThreshold(Y, th)
    -- Takes a matrix Y and thresholds, given th, to -1 and 1
    assert(th>=-1 and th<=1, "Error: threshold must be between -1 and 1")
    for i=1,Y:size(1) do
        for j=1,Y:size(2) do
            local val = Y[{{i},{j}}][1][1]
            if val > th then
                Y[{{i},{j}}] = 1
            else
                Y[{{i},{j}}] = -1
            end
        end
    end
    
    return Y
end

local function sampleY(outY, dataset, threshold, inY)
  local nSamples = outY:size(1)
  local ny = outY:size(2)
  if string.lower(dataset) == 'celeba' then
      if threshold then
          -- Convert Y to binary [-1, 1] vector
          inY = applyThreshold(inY, 0)
      end
      -- Special cases: 
      -- 1. Male (11 --> 1) or female (11 --> -1): a male will be converted to female and viceversa.
      -- 2. Bald (1), bangs (2) and receding_hairline (15): only one can be activated at the same time
      -- 3. Black (3), blonde (4), brown (5) and gray (9) hair: only one can be activated at the same time 
      -- We check if the input real image is male or female.
      -- If it's male (1), we activate the attribute male for all positions
      -- except for one position where we activate the female attribute.
      -- The same with female (0) (female always activated except for one case)
      local genderIdx = 11 -- This index is obtained from donkey_celebA.
      local genderAttr = torch.ge(inY[{{},{genderIdx}}], 0)
      print('Row\tPredicted gender')
      local k = 0 -- Indexs genderAttr, which has a different dimension than outY
      for i=1,nSamples do
          
          local j = ((i-1)%ny)+1  -- Indexs outY 2nd dimension
          if j==1 then
            k = k + 1
            if genderAttr[k][1] == 1 then print(('%d\tMale'):format(k)) else print(('%d\tFemale'):format(k)) end  
          end
          if j ~= genderIdx or genderAttr[k][1] == 0 then
              outY[{{i},{j}}] = 1
              -- By default outY gender attribute is female (0). 
              -- If we have a male, change attribute to male (except for k == genderIdx)
              if genderAttr[k][1] == 1 then outY[{{i},{genderIdx}}] = 1 end
          end
      end
  else
      -- Case of MNIST and other generic datasets
      for i=1,nSamples do
          outY[{{i},{((i-1)%ny)+1}}] = 1
      end 
  end
end 

local function obtainImageSet(X, path, option, extension)
    if option == 1 then
        -- Load input image X
        -- Check string is a path to an image
        assert(path:match(extension) ~= nil, "opt.loadPath '"..path.."' is not an image.")
        
        local tmp = image.load(path):float()
        tmp = image.scale(tmp, X:size(3), X:size(4))
        -- Image dimensions is 3. We need a 4th dimension indicating the number of images.
        tmp:resize(1, X:size(2), X:size(3), X:size(4))
        X = tmp
    elseif option == 2 then
        -- Load multiple images given a path
        assert(paths.dir(path)~=nil, "opt.loadPath '"..path.."' is not a directory.")
        local i = 1
        local fileIterator = paths.files(path, extension)
        while i <= opt.nImages do
            local imPath = path .. '/' .. fileIterator()
            local im = image.load(imPath)
            X[{{i},{},{},{}}] = image.scale(im, X:size(3), X:size(4))
            i = i + 1
        end
    else
        error('Option (customInputImage) not recognized.')
    end
    X:mul(2):add(-1) -- change [0, 1] to [-1, 1]
    return X
end


if opt.gpu > 0 then
    require 'cunn'
    require 'cudnn'
end

if opt.loadOption == 1 then opt.nImages = 1 end

local imgExtension = '.png'
local ny -- Y label length. This depends on the dataset.
if string.lower(opt.dataset) == 'mnist' then ny = 10; imgExtension = '.png'
elseif string.lower(opt.dataset) == 'celeba' then ny = 19; imgExtension = '.jpg'; end

-- Load nets
local generator = torch.load(opt.decNet)
local encoder = torch.load(opt.encNet)

local imgSz = {generator.output:size()[2], generator.output:size()[3], generator.output:size()[4]}

local inputX = torch.Tensor(opt.nImages, imgSz[1], imgSz[2], imgSz[3])
local Z = torch.Tensor(opt.nImages, opt.nz, 1, 1)
local Y = torch.Tensor(opt.nImages, ny):fill(-1)

-- Load to GPU
if opt.gpu > 0 then
    Z = Z:cuda(); Y = Y:cuda()
    cudnn.convert(generator, cudnn)
    cudnn.convert(encoder, cudnn)
    generator:cuda(); encoder:cuda()
else
    generator:float(); encoder:float()
end

generator:evaluate()
encoder:evaluate()

-- Load / generate X
if opt.loadOption == 0 then
  -- Generate X randomly from random Z and Y and then encoded it
  Z:normal(0,1)
  sampleY(Y, opt.dataset, ny, opt.nImages)
  inputX = generator:forward{Z, Y}:clone()
else
  -- Encode Z and Y from a given set of images
  inputX = obtainImageSet(inputX, opt.loadPath, opt.loadOption, imgExtension)
  if opt.gpu > 0 then inputX = inputX:cuda() end
end

local encOutput = encoder:forward(inputX)
Z = encOutput[1]; Y = encOutput[2]
Z:resize(Z:size(1), Z:size(2), 1, 1)
inputX = inputX:float() -- No longer needed in GPU

-- a function to setup double-buffering across the network.
-- this drastically reduces the memory needed to generate samples
local sampleInput = {Z[{{1}}], Y[{{1}}]}
optnet.optimizeMemory(generator, sampleInput)

-- At this point, we have Z and Y and we need to expand them.
-- We just need to fix Z on rows and Y on columns
-- These ones are expanded version of Z and Y.
-- They just have more repetitions.
local nOutSamples = opt.nImages*ny
local outZ = torch.Tensor(nOutSamples, opt.nz, 1, 1)
local outY = torch.Tensor(nOutSamples, ny):fill(-1)

if opt.gpu > 0 then outZ = outZ:cuda(); outY = outY:cuda() end
-- Fix Z for every row in generated samples.
-- A row has ny samples. Every i to (i-1)+ny samples outZ will have the same Z.
local j = 1
for i=1,nOutSamples,ny do
    outZ[{{i,(i-1)+ny},{},{},{}}] = Z[{{j},{},{},{}}]:expand(ny,opt.nz,1,1)
    j = j + 1
end

-- Fix Y for every column in generated samples.
sampleY(outY, opt.dataset, Y)

-- Final image: 1st columns: original image (inputX)
--              2nd: reconstructed image (reconstX)
--              3rd-end: variations on Y (and same Z for each row) (outX)
local reconstX = generator:forward{Z, Y}:clone():float()
local outX = generator:forward{outZ, outY}:float()

local outputImage = torch.cat(inputX[{{1}}],reconstX[{{1}}], 1):cat(outX[{{1,ny}}],1)
for i=2,opt.nImages do
  local tmp = torch.cat(inputX[{{i}}],reconstX[{{i}}], 1):cat(outX[{{(i-1)*ny+1,i*ny}}],1)
  outputImage = outputImage:cat(tmp, 1)
end

disp.image(image.toDisplayTensor(outputImage,0,ny+2))
image.save(opt.name .. '.png', image.toDisplayTensor(outputImage,0,ny+2))


