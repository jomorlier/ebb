-- This is a Lua config file for the Soleil code.

-- This case defines the 64x64 lid-driven cavity problem
return {
  
  -- Flow Initialization  Options --
  initCase     = 'Uniform', -- Uniform, Restart, TaylorGreen2DVortex, TaylorGreen3DVortex
  initParams = {0.000525805,43.4923,0.0,0.0,0.0}, -- necessary input conditions
  bodyForce = {10.0,0.0,0}, -- body force in x, y, z
  restartIter = 20000,
  
  -- Grid Options --
  xnum = 32, -- number of cells in the x-direction
  ynum = 64, -- number of cells in the y-direction
  znum = 1,  -- number of cells in the z-direction
  origin = {0.0, 0.0, 0.0}, -- spatial origin of the computational domain
  xWidth = 1.0,
  yWidth = 0.2,
  zWidth = 0.1,
  -- BCs on each boundary: 'periodic,' 'symmetry,' or 'wall'
  xBCLeft  = 'periodic',
  xBCLeftVel = {0.0, 0.0, 0.0},
  xBCRight = 'periodic',
  xBCRightVel = {0.0, 0.0, 0.0},
  yBCLeft  = 'wall',
  yBCLeftVel = {0.0, 0.0, 0.0},
  yBCRight = 'wall',
  yBCRightVel = {0.0, 0.0, 0.0},
  zBCLeft  = 'symmetry',
  zBCLeftVel = {0.0, 0.0, 0.0},
  zBCRight = 'symmetry',
  zBCRightVel = {0.0, 0.0, 0.0},
  
  -- Spatial Integration Options --
  spatialOrder = 2, -- 2 or 6
  
  --Time Integration Options --
  final_time            = 2000.00001,
  max_iter              = 100000,
  cfl                   = 2.5, -- Negative CFL implies that we will used fixed delta T
  delta_time            = 1e-3,
  
  --- File Output Options --
  wrtRestart = 'ON',
  wrtVolumeSolution = 'ON',
  wrt1DSlice = 'ON',
  outputEveryTimeSteps  = 500,
  restartEveryTimeSteps = 500,
  headerFrequency       = 20,
  outputFormat = 'Tecplot', --Tecplot or Python
  outputDirectory = '../soleilOutput/', -- relative to the liszt-in-terra home directory
  
  -- Fluid Options --
  gasConstant = 287.058,
  gamma = 1.4,
  viscosity_model = 'Sutherland', -- Constant, PowerLaw, Sutherland
  dynamic_viscosity_ref = 1.716E-5, --Sutherland's
  dynamic_viscosity_temp_ref = 273.15, --Sutherland's
  prandtl = 0.72,

  -- Particle Options --
  initParticles = 'Random', -- 'Random' or 'Restart'
  restartParticleIter = 0,
  particleType = 'Free', -- Fixed or Free
  twoWayCoupling = 'OFF',
  num = 1000.0,
  restitutionCoefficient = 1.0,
  convectiveCoefficient = 0.7, -- W m^-2 K^-1
  heatCapacity = 0.7, -- J Kg^-1 K^-1
  initialTemperature = 250, -- K
  density = 8900, --1000, --8900,
  diameter_mean = 1e-5, -- 1.2e-5, --0.03,
  diameter_maxDeviation = 0.0, --0.02,
  bodyForceParticles = {0,-0.0,0}, -- {0,-1.1,0}
  emissivity = 0.5, --0.4
  absorptivity = 0.5, -- Equal to emissivity in thermal equilibrium
  -- (Kirchhoff law of thermal radiation)

  -- Radiation Options --
  radiationType = 'ON',
  radiationIntensity = 10.0,

  -- vdb visualization --
  visualize = 'OFF', -- ON or OFF
}
