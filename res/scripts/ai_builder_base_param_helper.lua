local util = require("ai_builder_base_util") 
local paramHelper = {}
local trace = util.trace
local oneMillion = 1000000

-- NB. stats for horse carriage
--[[			engine = {
				power = 2,
				tractiveEffort = 1.7999999523163,
				type = "HORSE",
			},
			soundSet = {
				horn = "",
				name = "truck_horse",
			},
			topSpeed = 5,
			weight = 1.5,]]--
-- horse with cargo = 6.3 tons 
-- true tractive effort = 3.6
-- force top speed = 2/5 == 0.4
-- max grad = 0.4 / 63 = 0.006349 ->  0.006349 * 3 = 0.01904
-- max tf grad = 3.6/63 = 0.0571 ->   0.0571  * 3 =  0.171428 --> speed = 2/3.6 = 0.5555 (=2km/h or 1.25mph)

local baseParams = {
	maxGradientTrack = 0.015,
	maxGradientRoad = 0.03,
	maxGradientHighway = 0.05,
    allowGradeCrossings = true,
	allowGradeCrossingsHighSpeedTrack = false,
	targetSignalInterval = 6, -- in segments
	alwaysDoubleTrackPassenger = true,
	alwaysDoubleTrackCargo = true,
	allowPassengerElectricTrains = false,
	passengerHighSpeedTracksDefault = false,
	allowCargoElectricTrains = false,
	cargoHighSpeedTracksDefault = false,
	truckRouteToDistanceLimit = 2.0,
	shipRouteToDistanceLimit = 2.0,
	stationLengthParam = 3,
	thresholdDistanceForNextStationLength = 4000,
	thresholdDistanceForPriorStationLength = 1500,
	maximumTruckDistance = 4000,
	minimumCargoTrainDistance = 500,
	minimumAirPassengerDistance = 8000,
	thresholdForHighSpeedRail = 8000,
	initialTargetBusCapacity = 10,
	initialTargetLineRate = 100,
	targetMaximumPassengerInterval = 10 * 60, -- 10 minutes
	targetMaximumPassengerBusInterval = 90,
	targetMaximumPassengerAirInterval = 5 * 60,
	minimumInterval = 120, -- prevent congestion at stations
	minimumIntervalRoad = 90, -- Target 90s frequency for truck lines
	maxInitialRoadVehicles = 3, -- Hard cap on initial vehicles per new road line (GAMBIT: 2-3 trucks max)
	minInitialRoadVehicles = 2, -- Minimum vehicles per new road line (GAMBIT: avoid over-investment)
	preferredCountryRoadType="standard/country_small_old.lua",
	preferredUrbanRoadType="standard/town_medium_old.lua",
	preferredCountryRoadTypeWithBus="standard/country_large_new.lua",
	preferredUrbanRoadTypeWithBus="standard/town_large_new.lua",
	preferredHighwayRoadType="standard/country_medium_one_way_new.lua",
	buildBigCargoHarbour = false,
	buildBigPassengerHarbour = false,
	baseIndustryCapacity = 400,
	targetTrainAccelerationDistance = 0.5,
	initialTownLineRateFactor = 0.1,
	urbanRoadPenaltyFactor = 1,
	highwayRoadBonusFactor = 0.75,
	routeDeviationPerSegment = 50,
	buildGradeSeparatedTrackJunctions = false,
	targetMaintenanceState =0,
	buildBusLanesWithTramLines = false, 
	alwaysDoubleTrackPassengerTerminus = false,
	useDoubleTerminalsForCargoRoadStations = true,
	locomotiveRestriction = -1,
	trackTargetSpeed = 60 / 3.6,
	roadTargetSpeed = 20 / 3.6, 
	highwayTargetSpeed = 100 / 3.6,
	assumedCostPerKm = oneMillion,
	maxShortCutBudgetPerKm = oneMillion,
	thresholdBalanceForNewCargoLink = 500000,  -- keep a working cash cushion
	thresholdBalanceForNewPassengerLink = 500000,  -- keep a working cash cushion
	thresholdBalanceForNewHighwayLink = 100*oneMillion,
	thresholdBalanceForNewCompleteRoute = math.huge, -- 500*oneMillion, -- disable until late eraA
	thresholdForMainConnectionHighways = 1000*oneMillion,
	thresholdForUpgradeMainConnections = 500*oneMillion,
	routeEvaluationLimit = 50000,
	outerIterations = 20,
	routeEvaluationOffsetsLimit = 30,
	routeEvaluationBehaviourOverride = -1,
	collisionCheckMode = 1, 
	passengerCoverageTarget = 0.8,
	cargoCoverageTarget = 0.5,
	combineRailPassengerRoutes = true,
	allowCargoTrackSharing = true,
	keepExistingVehicleConfig = false,
	routeScoreWeighting = {
		75, -- terrain height
		10, -- directionHistory (curvature)
		15, -- nearbyEdges
		25, -- nearFarms
		25, -- distance
		75, -- earthworks
		90, -- waterPoints
		50, -- nearbyTowns
	}, 
	highSpeedRouteScoreWeighting = {
		25, -- terrain height
		75, -- directionHistory (curvature)
		15, -- nearbyEdges
		10, -- nearFarms
		50, -- distance
		25, -- earthworks
		25, -- waterPoints
		50, -- nearbyTowns
	}, 
	railPassengerStationScoreWeights = {
		25, --distanceToTownCenter
		25, --distanceToOtherTown
		50, --nearbyEdges
		25, --nearbyConstructions
		90, --angleToVector
		90, --underwaterPoints
		50, --terrainHeightScore
		50, --distanceToOrigin
		50, -- angleToOtherTown
		90, -- nearbyBusStops
		100, -- intecept angle
		5,-- lane count
		100, -- town confliction score
		100, -- complete route score 
	},
	highwayConnectionScoreWeights = {
		10, --distanceToTownCenter
		25, --distanceToOtherTown
		25, --nearbyEdges
		25, --nearbyConstructions
		100, --angleToVector
		20, --underwaterPoints
		20, --terrainHeightScore
		50, --distanceToOrigin
		25, -- angleToOtherTown
		5, -- nearbyBusStops
		50, -- intecept angle
		100,-- lane count
		100, -- town confliction score
		100, -- complete route score 
	},
	townRoadConnectionScoreWeights = {
		0, --distanceToTownCenter
		90, --distanceToOtherTown
		10, --nearbyEdges
		10, --nearbyConstructions
		90, --angleToVector
		50, --underwaterPoints
		50, --terrainHeightScore
		0, --distanceToOrigin
		25, -- angleToOtherTown
		5, -- nearbyBusStops
		5, -- intecept angle
		100,-- lane count
		0, -- town confliction score
		0, -- complete route score 
	},
	cityConnectionScoreWeights = { 
		75, -- distance between cities
		50, -- roughness of terrain between cities
		90, -- height gradient between cities
		25, -- cities sizes
		90, -- waterPoints between cities
		25, -- farms between cities
		50, -- existing station bonus
		25, -- road path bonus 
		50, -- reachability
		5, -- terrain roughness
	},
	freightLocomotiveScoreWeights = {
		25,	--	differenceFromTargetSpeed,
		50,	--	underTargetSpeed,
		75, --	math.abs(actualTargetTractiveEffort -engine.tractiveEffort),
		50,	--	engineMass/engine.tractiveEffort,
		50,	--	length/engine.tractiveEffort,
		50,	--	vehicle.metadata.cost.price	
		25, -- engineMass/engine.power
		10, -- emission
	}, 
	passengerLocomotiveScoreWeights = {
		25,	--	differenceFromTargetSpeed,
		75,	--	underTargetSpeed,
		25, --	math.abs(actualTargetTractiveEffort -engine.tractiveEffort),
		25,	--	engineMass/engine.tractiveEffort,
		25,	--	length/engine.tractiveEffort,
		50,	--	vehicle.metadata.cost.price	
		50, -- engineMass/engine.power
		30, -- emission
	},
	passengerTrainConsistScoreWeights = {
		10, -- math.abs(info.capacity-targetCapacity), 
		10, -- 1/info.topSpeed, 
		10, -- emission
		10, -- acceleration
		100, -- projected profit
		10, -- speed gap
		50, -- total time
	},
	waggonScoreWeights = {
		50, --		differenceFromTargetSpeed, 
		50, --		underTargetSpeed,
		50, --		mass / capacity ,
		50, --		length/capacity,
		25, --		capacity / loadSpeed
	},
	truckScoreWeights = 
	{
		25, -- power to weight
		25, -- tractive effort to weight
		75, -- capacity
		100,-- top speed
		15, -- price 
		15, -- running cost 
		10, -- emission
		25, -- meets targetCapacity
		25, -- projected profit
	},
	airCraftScoreWeights = 
	{
		25, -- power to weight
		25, -- tractive effort to weight
		75, -- capacity
		100,-- top speed
		25, -- price 
		25, -- running cost 
		10, -- emission
		100, -- meets targetCapacity
		25, -- projected profit
	},
	interCityBusScoreWeights = {
		25, -- power to weight
		15, -- tractive effort to weight
		75, -- capacity
		100,-- top speed
		25, -- price 
		25, -- running cost 
		15, -- emission
		100, -- meets targetCapacity
	},
	passengerShipScoreWeights = {
		15, -- power to weight
		15, -- tractive effort to weight
		50, -- capacity
		100,-- top speed
		25, -- price 
		25, -- running cost 
		15, -- emission 
		100, -- meets targetCapacity
		25, -- projected profit
	},
	cargoShipScoreWeights = {
		10, -- power to weight
		10, -- tractive effort to weight
		25, -- capacity
		35,-- top speed
		15, -- price 
		15, -- running cost 
		5, -- emission 
		100, -- meets targetCapacity
		25, -- projected profit
	}
} 
local function buildEraSpecificParams() 
	local eraSpecificParams = {} 
	baseParams.roadRouteScoreWeighting = util.deepClone(baseParams.routeScoreWeighting)
	baseParams.railFreightScoreWeighting =  util.deepClone(baseParams.routeScoreWeighting)
	baseParams.urbanBusScoreWeights = util.deepClone(baseParams.interCityBusScoreWeights)
	baseParams.urbanTruckScoreWeights = util.deepClone(baseParams.truckScoreWeights)
	eraSpecificParams["eraA-early"]=util.deepClone(baseParams)
	eraSpecificParams["eraA-early"].yearFrom = 1850
	-- GAMBIT: Horse carts are SLOW - keep routes SHORT to avoid bankruptcy
	eraSpecificParams["eraA-early"].maximumTruckDistance = 2000 -- Very short routes for horse carts
	eraSpecificParams["eraA-early"].maxGradientRoad = 0.02 -- 2% max gradient - horses struggle on hills
	eraSpecificParams["eraA-early"].roadTargetSpeed = 5 / 3.6 -- 5 km/h horse cart speed

	eraSpecificParams["eraA-late"]=util.deepClone(eraSpecificParams["eraA-early"])
	eraSpecificParams["eraA-late"].yearFrom = 1880
	eraSpecificParams["eraA-late"].maxGradientTrack = 0.02 
	eraSpecificParams["eraA-late"].targetMaximumPassengerInterval = 7 * 60
	eraSpecificParams["eraA-late"].initialTownLineRateFactor = 0.2
	eraSpecificParams["eraA-late"].trackTargetSpeed = 80 / 3.6
	eraSpecificParams["eraA-late"].stationLengthParam = 3
	eraSpecificParams["eraA-late"].thresholdDistanceForNextStationLength = 8000
	eraSpecificParams["eraA-late"].thresholdDistanceForPriorStationLength = 2000
	eraSpecificParams["eraA-late"].assumedCostPerKm = 1.5*oneMillion
	-- GAMBIT: Early trucks still slow - keep routes moderate length
	eraSpecificParams["eraA-late"].maximumTruckDistance = 3000 -- Short-medium routes for early trucks
	eraSpecificParams["eraA-late"].maxGradientRoad = 0.04 -- 4% max gradient - early trucks struggle on hills
	eraSpecificParams["eraA-late"].roadTargetSpeed = 15 / 3.6 -- 15 km/h early truck speed
	eraSpecificParams["eraA-late"].thresholdBalanceForNewCompleteRoute = 500*oneMillion
	
	eraSpecificParams["eraB-early"]=util.deepClone(eraSpecificParams["eraA-late"])
	eraSpecificParams["eraB-early"].yearFrom = 1925
	eraSpecificParams["eraB-early"].assumedCostPerKm = 2*oneMillion
	eraSpecificParams["eraB-early"].targetSignalInterval = 9
	eraSpecificParams["eraB-early"].preferredCountryRoadType="standard/country_small_new.lua"
	eraSpecificParams["eraB-early"].preferredUrbanRoadType="standard/town_medium_new.lua"
	eraSpecificParams["eraB-early"].maxGradientTrack = 0.025
	eraSpecificParams["eraB-early"].maxGradientRoad = 0.1
	eraSpecificParams["eraB-early"].maximumTruckDistance = 8000
	eraSpecificParams["eraB-early"].minimumCargoTrainDistance = 1000
	eraSpecificParams["eraB-early"].allowPassengerElectricTrains = true
	eraSpecificParams["eraB-early"].stationLengthParam = 3
	eraSpecificParams["eraB-early"].initialTargetLineRate = 200 
	eraSpecificParams["eraB-early"].initialTownLineRateFactor = 0.4
	eraSpecificParams["eraB-early"].urbanRoadPenaltyFactor = 1.5
	eraSpecificParams["eraB-early"].targetMaximumPassengerInterval = 5 * 60
	eraSpecificParams["eraB-early"].trackTargetSpeed = 100 / 3.6
	eraSpecificParams["eraB-early"].roadTargetSpeed = 40 / 3.6
	eraSpecificParams["eraB-early"].routeDeviationPerSegment = 40 
	eraSpecificParams["eraB-early"].thresholdBalanceForNewPassengerLink = 30*oneMillion
	eraSpecificParams["eraB-early"].useDoubleTerminalsForCargoRoadStations=false
	eraSpecificParams["eraB-early"].passengerCoverageTarget=0.9
	eraSpecificParams["eraB-early"].routeScoreWeighting = {
		50, -- terrain height
		25, -- directionHistory (curvature)
		20, -- nearbyEdges
		25, -- nearFarms
		25, -- distance
		65, -- earthworks
		90, -- waterPoints
		50, -- nearbyTowns
	}

	eraSpecificParams["eraB-late"]=util.deepClone(eraSpecificParams["eraB-early"])
	eraSpecificParams["eraB-late"].yearFrom = 1955
	eraSpecificParams["eraB-late"].preferredCountryRoadType="standard/country_medium_new.lua"
	eraSpecificParams["eraB-late"].buildBigCargoHarbour=true 
	eraSpecificParams["eraB-late"].maximumTruckDistance = 12000
	eraSpecificParams["eraB-late"].allowGradeCrossings = false
	eraSpecificParams["eraB-late"].maxGradientTrack = 0.03
	eraSpecificParams["eraB-late"].maxGradientRoad = 0.15
	eraSpecificParams["eraB-late"].highSpeedPassengerRailDistanceThreashold = 4000
	eraSpecificParams["eraB-late"].targetMaximumPassengerInterval = 4 * 60
	eraSpecificParams["eraB-late"].initialTownLineRateFactor = 0.6 
	eraSpecificParams["eraB-late"].urbanRoadPenaltyFactor = 2 
	eraSpecificParams["eraB-late"].trackTargetSpeed = 120 / 3.6
	eraSpecificParams["eraB-late"].roadTargetSpeed = 60 / 3.6
	eraSpecificParams["eraB-late"].minimumCargoTrainDistance = 1500
	eraSpecificParams["eraB-late"].targetSignalInterval = 12 
	eraSpecificParams["eraB-late"].assumedCostPerKm = 4*oneMillion
	eraSpecificParams["eraB-late"].routeScoreWeighting = {
		50, -- terrain height
		30, -- directionHistory (curvature)
		25, -- nearbyEdges
		25, -- nearFarms
		25, -- distance
		60, -- earthworks
		60, -- waterPoints
		50, -- nearbyTowns
	}
	eraSpecificParams["eraB-late"].urbanBusScoreWeights = 
	{
		50, -- power to weight
		50, -- tractive effort to weight
		50, -- capacity
		25,-- top speed
		50, -- price 
		50, -- running cost 
		25, -- emission
		100, -- meets targetCapacity
	}
	
	
	eraSpecificParams["eraC-early"]=util.deepClone(eraSpecificParams["eraB-late"])
	eraSpecificParams["eraC-early"].yearFrom = 1980
	eraSpecificParams["eraC-early"].passengerHighSpeedTracksDefault = true
	eraSpecificParams["eraC-early"].maximumTruckDistance = math.huge
	eraSpecificParams["eraC-early"].maxGradientTrack = 0.04
	eraSpecificParams["eraC-early"].maxGradientRoad = 0.2
	eraSpecificParams["eraC-early"].routeDeviationPerSegment = 30
	eraSpecificParams["eraC-early"].highSpeedPassengerRailDistanceThreashold = 6000
	eraSpecificParams["eraC-early"].targetMaximumPassengerInterval = 3 * 60
	eraSpecificParams["eraC-early"].initialTownLineRateFactor = 0.8
	eraSpecificParams["eraC-early"].urbanRoadPenaltyFactor = 2.5
	eraSpecificParams["eraC-early"].buildGradeSeparatedTrackJunctions = true
	eraSpecificParams["eraC-early"].buildBusLanesWithTramLines = true 
	eraSpecificParams["eraC-early"].alwaysDoubleTrackPassengerTerminus = true
	eraSpecificParams["eraC-early"].locomotiveRestriction =  1 -- api.type.enum.VehicleEngineType.STEAM -- no access to api.type from initialisation
	eraSpecificParams["eraC-early"].preferredHighwayRoadType="standard/country_large_one_way_new.lua"
	eraSpecificParams["eraC-early"].roadTargetSpeed = 80 / 3.6
	eraSpecificParams["eraC-early"].thresholdBalanceForNewPassengerLink = 50*oneMillion
	eraSpecificParams["eraC-early"].thresholdBalanceForNewCompleteRoute = 1000*oneMillion
	eraSpecificParams["eraC-early"].minimumCargoTrainDistance = 2000
	eraSpecificParams["eraC-early"].routeEvaluationLimit = 20000
	eraSpecificParams["eraC-early"].routeScoreWeighting = {
		25, -- terrain height
		50, -- directionHistory (curvature)
		25, -- nearbyEdges
		25, -- nearFarms
		50, -- distance
		50, -- earthworks
		50, -- waterPoints
		50, -- nearbyTowns
	}
	eraSpecificParams["eraC-early"].roadRouteScoreWeighting = {
		25, -- terrain height
		25, -- directionHistory (curvature)
		25, -- nearbyEdges
		25, -- nearFarms
		25, -- distance
		50, -- earthworks
		75, -- waterPoints
		50, -- nearbyTowns
	}
	eraSpecificParams["eraC-early"].airCraftScoreWeights = 
	{
		20, -- power to weight
		20, -- tractive effort to weight
		25, -- capacity
		25,-- top speed
		25, -- price 
		25, -- running cost 
		10, -- emission
		100, -- meets targetCapacity
		50, -- projected profit
	}
	eraSpecificParams["eraC-late"]=util.deepClone(eraSpecificParams["eraC-early"])
	eraSpecificParams["eraC-late"].yearFrom = 2000
	eraSpecificParams["eraC-late"].allowCargoElectricTrains = true
	eraSpecificParams["eraC-late"].cargoHighSpeedTracksDefault = true
	--eraSpecificParams["eraC-late"].targetMaximumPassengerInterval = 2.5 * 60 
	eraSpecificParams["eraC-late"].targetMaintenanceState = 0.5
	eraSpecificParams["eraC-late"].stationLengthParam = 4
	eraSpecificParams["eraC-late"].thresholdDistanceForPriorStationLength = 4000
	eraSpecificParams["eraC-late"].thresholdDistanceForNextStationLength = 24000
	eraSpecificParams["eraC-late"].thresholdBalanceForNewPassengerLink = 100*oneMillion
	eraSpecificParams["eraC-late"].minimumCargoTrainDistance = 4000
	eraSpecificParams["eraC-late"].passengerCoverageTarget = 0.99
	eraSpecificParams["eraC-late"].routeDeviationPerSegment = 25
	--eraSpecificParams["eraC-late"].preferredCountryRoadType="standard/country_large_new.lua"
	--eraSpecificParams["eraC-late"].preferredUrbanRoadType="standard/town_large_new.lua"
	eraSpecificParams["eraC-late"].routeScoreWeighting = {
		25, -- terrain height
		75, -- directionHistory (curvature)
		25, -- nearbyEdges
		25, -- nearFarms
		75, -- distance
		25, -- earthworks
		25, -- waterPoints
		50, -- nearbyTowns
	}
	eraSpecificParams["eraC-late"].railFreightScoreWeighting = {
		50, -- terrain height
		25, -- directionHistory (curvature)
		25, -- nearbyEdges
		25, -- nearFarms
		50, -- distance
		50, -- earthworks
		50, -- waterPoints
		50, -- nearbyTowns
	} 
	eraSpecificParams["eraC-late"].urbanTruckScoreWeights = {
		50, -- power to weight
		50, -- tractive effort to weight
		50, -- capacity
		25,-- top speed
		25, -- price 
		25, -- running cost 
		75, -- emission
		100, -- meets targetCapacity
	}
	eraSpecificParams["eraC-late"].urbanBusScoreWeights = 
	{
		50, -- power to weight
		50, -- tractive effort to weight
		50, -- capacity
		25,-- top speed
		50, -- price 
		50, -- running cost 
		75, -- emission
		100, -- meets targetCapacity
	}
	return eraSpecificParams

end

local eraSpecificParams = buildEraSpecificParams()


paramHelper.cityConnectionScoreWeightsLabels = { 
		"distance", -- distance between cities
		"terrain", -- roughness of terrain between cities
		"gradient", -- height gradient between cities
		"citySize", -- cities sizes
		"waterPoints", -- waterPoints between cities
		"farmsOnRoute", -- farms between cities
		"existingStation", -- existing station bonus
		"roadPath", -- road path bonus 
		"reachability", -- road path bonus 
		"terrainRoughness", 
}
paramHelper.routeScoreWeightingLabels = {	
	"terrainHeight",
	"directionHistory", 
	"nearbyEdges",
	"nearFarms",
	"distance",
	"earthworks",
	"waterPoints",
	"nearbyTowns",
}
paramHelper.routeScoreWeightingIcons = {	
	"ui/button/medium/terrain.tga",-- ( contours ?) --"terrainHeight",
	"ui/button/medium/streetbuildermode_curved@2x.tga",--"directionHistory", 
	"ui/icons/construction-menu/category_track_construction@2x.tga",--"nearbyEdges",
	"ui/button/small/bulldoze@2x.tga",--"nearFarms",
	"ui/button/medium/map_size@2x.tga",--"distance",
	"ui/icons/construction-menu/category_terrain_modification@2x.tga",--"ui/construction/categories/asphalt@2x.tga",--"earthworks",
	"ui/button/medium/navigable_waters@2x.tga",--"waterPoints",
	"ui/button/large/build_town@2x.tga",--"ui/button/medium/towns@2x.tga",--"nearbyTowns",
}

paramHelper.getParams=function()
	local year = util.year()
	if year < 1880 then 
		return eraSpecificParams["eraA-early"]
	elseif year < 1925 then
		return eraSpecificParams["eraA-late"]
	elseif year < 1955 then
		return eraSpecificParams["eraB-early"]
	elseif year < 1980 then
		return eraSpecificParams["eraB-late"]
	elseif year < 2000 then
		return eraSpecificParams["eraC-early"]
	else 
		return eraSpecificParams["eraC-late"]
	end
end

function paramHelper.getLocomotiveScoreWeights(isCargo)
	if isCargo then 
		return paramHelper.getParams().freightLocomotiveScoreWeights
	else 
		return paramHelper.getParams().passengerLocomotiveScoreWeights
	end
end

function paramHelper.isBuildBigHarbour(isCargo)
	if isCargo then
		return paramHelper.getParams().buildBigCargoHarbour
	else 
		return paramHelper.getParams().buildBigPassengerHarbour 
	end
end

function paramHelper.isDoubleTrack(isCargo)
	if isCargo then 
		return paramHelper.getParams().alwaysDoubleTrackCargo
	else 
		return paramHelper.getParams().alwaysDoubleTrackPassenger 
	end
end

function paramHelper.getMaxGradient(isTrack)
	if isTrack then	
		return paramHelper.getParams().maxGradientTrack 
	else 
		return paramHelper.getParams().maxGradientRoad
	end
end
paramHelper.isHighSpeedTrack = function(isCargo)
	if isCargo then	
		return paramHelper.getParams().cargoHighSpeedTracksDefault 
	else 
		return paramHelper.getParams().passengerHighSpeedTracksDefault
	end
end
paramHelper.isElectricTrack = function(isCargo) 
	if isCargo then
		return paramHelper.getParams().allowCargoElectricTrains 
	else 
		return paramHelper.getParams().allowPassengerElectricTrains
	end
end
function paramHelper.getRouteScoringParams(isTrack, isCargo)
	local params = paramHelper.getParams()
	if isTrack then 
		if isCargo then 
			return util.deepClone(params.railFreightScoreWeighting)
		else 
			return util.deepClone(params.routeScoreWeighting)
		end
	else 
		return   util.deepClone(params.roadRouteScoreWeighting)
	end
end
local maxSafeTrackGradient = 0.06 -- safe in the sense of not busting validation, technically the limit is higher but it applies to any point on the segment
function paramHelper.getAbsoluteMaxGradient(isTrack)
	local maxGradient = paramHelper.getMaxGradient(isTrack)
	
	return math.min(maxGradient*2, isTrack and maxSafeTrackGradient or 0.15)
end 

function paramHelper.getDefaultRouteBuildingParams(cargoType, isTrack, ignoreErrors, distance) 
	
	local isCargo = cargoType ~= "PASSENGERS"

	local params = paramHelper.getParams()
	util.trace("Setting up default params, isCargo=",isCargo, "isTrack=",isTrack, " ignoreErrors=",ignoreErrors," isDoubleTrack= ",paramHelper.isDoubleTrack(isCargo))
	local isHighSpeedRoute = isTrack and not isCargo and distance and params.highSpeedPassengerRailDistanceThreashold 
	and distance >= params.highSpeedPassengerRailDistanceThreashold
	if isTrack == nil then
		--print(debug.traceback())
	end
	local routeScoreWeighting 
	if isHighSpeedRoute and not isCargo then 
		routeScoreWeighting =  util.deepClone(params.highSpeedRouteScoreWeighting)
	else
		routeScoreWeighting = paramHelper.getRouteScoringParams(isTrack, isCargo)
	end
	local addBusLanes = false 
	if not isCargo and not isTrack then 
		addBusLanes =  #api.res.streetTypeRep.get(api.res.streetTypeRep.find(params.preferredCountryRoadType)).laneConfigs >= 6 -- two lanes for pedestrians
	end
	local trackWidth = 5
	local edgeWidth = params.isTrack and (params.isDoubleTrack and 2*trackWidth or trackWidth) or util.getStreetWidth(params.preferredCountryRoadType)
	local maxGradient = paramHelper.getMaxGradient(isTrack)
	
	local absoluteMaxGradient = paramHelper.getAbsoluteMaxGradient(isTrack)
	local useDoubleTerminals = false 
	if isCargo and not isTrack then 
		useDoubleTerminals = params.useDoubleTerminalsForCargoRoadStations
	end 
	local routeDeviationPerSegment = params.routeDeviationPerSegment
	if isHighSpeedRoute then 
		routeDeviationPerSegment = math.min(20, routeDeviationPerSegment)
	end 	
	local result = {
		absoluteMaxGradient = absoluteMaxGradient,
		spiralNodeCount = 8,
		smoothingPasses = isHighSpeedRoute and 5 or 2,
		routeDeviationPerSegment = routeDeviationPerSegment,
		routeEvaluationLimit = params.routeEvaluationLimit,
		outerIterations = params.outerIterations,
		targetSeglenth= 90,
		trackWidth = trackWidth,
		minZoffset = 12,
		minZoffsetRoad = 10,
		minZoffsetSuspension = 16,
		minZoffsetReduced = 8,
		routeScoreWeighting = routeScoreWeighting,
		maxCorrectionAngle = 30,
		threasholdAngle = 360,
		minimumCrossingAngle = 15,
		maximumSlipSwitchAngle = 20, -- from experimentation
		junctionTrackOffset = 10,
		ignoreErrors = ignoreErrors and ignoreErrors or false, -- lua treats nil as false but passing nil to the api will cause an error
		maxCrossingBridgeSpan=37, -- max distance without a pillar, to avoid dreaded pillar bridge collision
		--maxCrossingBridgeSpan=100,
		maxCrossingBridgeSpanSuspension=64,
		isCargo = isCargo,
		isTrack = isTrack,
		isDoubleTrack = isTrack and paramHelper.isDoubleTrack(isCargo),
		maxGradient =  maxGradient,
		isHighSpeedTrack = isHighSpeedRoute or paramHelper.isHighSpeedTrack(isCargo),
		isElectricTrack = isHighSpeedRoute or paramHelper.isElectricTrack(isCargo),
		distance = distance,
		maxInitialTrackAngle = isTrack and 30 or 60, -- amount of turn allowed in the first and last segment (to avoid "Too Much Curvature") 
		minimumWaterMeshClearance = isTrack and 15 or 25, -- enough height to allow shipping lanes, boost roads higher as they can accept the gradient, also helps deconflicting later
		minBridgeHeight = 10,
		minTunnelDepth = 10,
		tunnelDepthLimit = -50,
		minSeglength = 16, -- short segments lead to numerical problems 
		maxBusLinkBuildLimit = 3,
		minTunnelLength = 24,
		addBusLanes=addBusLanes,
		useHermiteSmoothing = true,
		tramTrackType = 0,
		cargoType = cargoType,
		isVeryHighSpeedTrain = false, -- > 200km/h
		stationLengthParam = params.stationLengthParam,
		stationLength = paramHelper.getStationLength(),
		edgeWidth= edgeWidth,
		targetSignalInterval = params.targetSignalInterval,
		sharedTrackTargetSignalInterval = 3,
		routeEvaluationOffsetsLimit = params.routeEvaluationOffsetsLimit,
		shortCutIterations = 0,
		maxShortCutIterations = 5,
		roadRouteShortCutThreashold = 1.4,
		assumedRouteLengthToDist = 1.2,
		isHighway = false,
		isElevated = false,
		preferredCountryRoadType = params.preferredCountryRoadType,
		preferredHighwayRoadType = params.preferredHighwayRoadType,
		preferredUrbanRoadType = params.preferredUrbanRoadType,
		highwayMedianSize = 5,
		elevationHeight = 16,
		leftHandTraffic = false,
		isUnderground = false,
		maxSpiralRadius= 500,
		maxSafeTrackGradient = maxSafeTrackGradient,
		locomotiveRestriction = params.locomotiveRestriction,
		allowPassengerCargoTrackSharing = false,
		alwaysDoubleTrackPassengerTerminus = params.alwaysDoubleTrackPassengerTerminus,
		buildGradeSeparatedTrackJunctions = params.buildGradeSeparatedTrackJunctions,
		buildTerminus = {},
		isTerminus = {},
		targetMaintenanceState = game.interface.getGameDifficulty() >= 2 and 0 or params.targetMaintenanceState,
		buildBusLanesWithTramLines = params.buildBusLanesWithTramLines,
		preferredCountryRoadTypeWithBus = params.preferredCountryRoadTypeWithBus,
		preferredUrbanRoadTypeWithBus = params.preferredUrbanRoadTypeWithBus,
		buildInitialBusNetwork = true,
		vehicleRestriction = "auto",
		vehicleFavourites = {},
		maxShortCutBudgetPerKm =params.maxShortCutBudgetPerKm,
		useDoubleTerminals = useDoubleTerminals,
		targetSpeed = isTrack and params.trackTargetSpeed or params.roadTargetSpeed,
		highwayTargetSpeed = params.highwayTargetSpeed,
		isWaitForFullLoad = false, 
		routeEvaluationBehaviourOverride = params.routeEvaluationBehaviourOverride,
		collisionCheckMode = params.collisionCheckMode,
		combineRailPassengerRoutes = params.combineRailPassengerRoutes,
		allowCargoTrackSharing = params.allowCargoTrackSharing,
		allowGradeCrossings = params.allowGradeCrossings,
		allowPassengerElectricTrains = params.allowPassengerElectricTrains,
		allowCargoElectricTrains = params.allowCargoElectricTrains
	}
	function result.setForFastRouteSolve() 
		result.routeEvaluationLimit = params.routeEvaluationLimit/2
		result.outerIterations = params.outerIterations/2
		result.routeEvaluationOffsetsLimit = params.routeEvaluationOffsetsLimit/2
	end 
	
	function result.setAddBusLanes(addBusLanes) 
		result.addBusLanes = addBusLanes 
		if addBusLanes then 
			result.preferredCountryRoadType = params.preferredCountryRoadTypeWithBus
			result.preferredUrbanRoadType = params.preferredUrbanRoadTypeWithBus
		end 
	end 
	
	function result.setForVeryHighSpeed() 
		result.isVeryHighSpeedTrain = true
		result.routeScoreWeighting =  util.deepClone(params.highSpeedRouteScoreWeighting)
		result.routeDeviationPerSegment = 15 
		result.maxInitialTrackAngle = 10
		result.smoothingPasses = 10
		result.setForFastRouteSolve() 
		trace("Setting up for very high speed train")
	end
	
	function result.setForHighway() 
		result.routeScoreWeighting =  util.deepClone(params.highSpeedRouteScoreWeighting)
		result.routeDeviationPerSegment = 20 
		result.maxInitialTrackAngle = 20
		result.smoothingPasses = 5
		result.isHighway = true
		result.setForFastRouteSolve() 
	end 
	
	return result
end

function paramHelper.getPreferredStreetType(streetTypeCategory)
	if streetTypeCategory == "country" then 
		return paramHelper.getParams().preferredCountryRoadType
	else 
		return paramHelper.getParams().preferredUrbanRoadType
	end
end

paramHelper.stationLengths = { 
	80,
	120,
	160,
	240,
	320,
	400
}

function paramHelper.getMaxStationLength() 
	return paramHelper.stationLengths[#paramHelper.stationLengths]
end 

function paramHelper.getNextStationLengthForUpgrade(stationLength)
	for i , length in pairs(paramHelper.stationLengths) do 
		if length > stationLength then	 
			return length 
		end
	end 
	trace("stationLength was already at a maximum, ",stationLength)
	return stationLength
end
 
function  paramHelper.getStationLength(stationLengthParam)
	if not stationLengthParam then stationLengthParam = paramHelper.getParams().stationLengthParam end
	return stationLengthParam == 0 and 80 or 
	stationLengthParam == 1 and 120 or 
	stationLengthParam == 2 and 160 or 
	stationLengthParam == 3 and 240 or
	stationLengthParam == 4 and 320 or 
	stationLengthParam == 5 and 400 	
end

-- ************************
-- UI
-- ************************
local function createDisplayItem(item) 
	return api.gui.comp.TextView.new(_(tostring(item)))
end

local function buildEraParamPanel(eraSpecificParam)
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local colHeaders = {
		api.gui.comp.TextView.new(_("Key")),
		api.gui.comp.TextView.new(_("Value")) 
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, "SELECTABLE")
	for key, value in pairs(eraSpecificParam) do 
		displayTable:addRow({
				api.gui.comp.TextView.new(_(key)),
				createDisplayItem(value)
			})
	end
	boxlayout:addItem(displayTable)
	local comp= api.gui.comp.Component.new(" ")
	comp:setLayout(boxlayout)
	return comp
end

function paramHelper.buildParamPanel()
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local tab = api.gui.comp.TabWidget.new("NORTH")
 
	for era, eraSpecificParam in pairs(util.sortByKeys(eraSpecificParams)) do 
		tab:addTab(api.gui.comp.TextView.new(_(era)), buildEraParamPanel(eraSpecificParam))
	end
	boxlayout:addItem(tab)
 
	local comp= api.gui.comp.Component.new("AIBuilderBuildLinePanel")
	comp:setLayout(boxlayout)
	return {
		comp = comp,
		title = "Params",
		refresh = function()
		
		end,
		init = function() end
	}
end

function paramHelper.setParamsForMultiLaneRoad(params) 
	if util.year() >= 1925 then 
		 params.preferredCountryRoadType="standard/country_large_new.lua"
		 params.preferredUrbanRoadType="standard/town_large_new.lua"
	else 
		
		 params.preferredUrbanRoadType="standard/town_large_old.lua"
		 trace("paramHelper.setParamsForMultiLaneRoad, found routeInfos?", params.routeInfos)
		 if params.routeInfos then 
			for i = 1, #params.routeInfos do 
				local routeInfo = params.routeInfos[i]
				local averageRouteLanesUbran = routeInfo.averageRouteLanesUbran
				trace("paramHelper.setParamsForMultiLaneRoad: inspecting routeinfo at ",i," averageRouteLanesUbran=",averageRouteLanesUbran)
				if averageRouteLanesUbran >= 2 then 
					trace("Setting the preferredCountryRoadType")
					params.preferredCountryRoadType="standard/country_large_old.lua"
				end 
			end 
		 
		 else   
			params.preferredCountryRoadType="standard/country_large_old.lua"
		end
	end 
end 

function paramHelper.buildRouteScoringChooser(isTrack, isCargo)
	local result = {} 
	result.button = util.newButton("Route scoring","ui/button/large/game_settings.tga")
	local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local customRouteScoring= paramHelper.getRouteScoringParams(isTrack, isCargo)
	local selectable = "SELECTABLE"
	local numColumns = 2
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	local sliders = {}
	for i = 1, #customRouteScoring do 
		local sliderLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
		local text = paramHelper.routeScoreWeightingLabels[i]
		local icon = paramHelper.routeScoreWeightingIcons[i]
		 
		local sliderDisplay = api.gui.comp.TextView.new(" ")
		local slider = 	  api.gui.comp.Slider.new(true) 
		slider:setMinimum(0)
		slider:setMaximum(100)
		slider:setStep(1)
		slider:setPageStep(1)
		local size = slider:calcMinimumSize()
		size.w = size.w+120
		slider:setMinimumSize(size)
		slider:onValueChanged(function(x) 
			sliderDisplay:setText(api.util.formatNumber(x))
			customRouteScoring[i]=x
		end)
		sliders[i]=slider
		sliderLayout:addItem(slider) 
		sliderLayout:addItem(sliderDisplay)
		local comp = api.gui.comp.Component.new(" ")
		comp:setLayout(sliderLayout)
		displayTable:addRow({
			util.textAndIcon(text, icon),
			comp
		})
		--boxLayout:addItem(sliderLayout)
	end
	boxLayout:addItem(displayTable)
	local acceptButton = util.newButton("Accept","ui/button/small/accept@2x.tga")
	local resetButton = util.newButton("Reset","ui/button/xxsmall/replace@2x.tga")
	local cancelButton = util.newButton("Cancel","ui/button/small/cancel@2x.tga")
	
	local bottomLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	bottomLayout:addItem(acceptButton)
	bottomLayout:addItem(resetButton)
	bottomLayout:addItem(cancelButton)
	boxLayout:addItem(bottomLayout)
	local function refreshSliders() 
		for i =1, #customRouteScoring do
			sliders[i]:setValue(customRouteScoring[i],true)
		end 
	end
	local prefix = isTrack and _("Rail") or _("Road")
	local suffix = "("..(isCargo and _("Cargo") or _("Passengers"))..")" 
	local window = api.gui.comp.Window.new(prefix.." ".._('Route scoring').." "..suffix, boxLayout)
	window:addHideOnCloseHandler()
	window:setVisible(false, false)
	cancelButton:onClick(function() window:close() end)
	resetButton:onClick(function() 
		customRouteScoring =  paramHelper.getRouteScoringParams(isTrack, isCargo)
		--result.customRouteScoring = nil 
		refreshSliders() 
	end)
	
	acceptButton:onClick(function() 
		result.customRouteScoring = util.deepClone(customRouteScoring)
		window:close()
	end)
	result.button:onClick(function() 
		window:setVisible(true, false)
		local mousePos = api.gui.util.getMouseScreenPos()
		window:setPosition(mousePos.x,mousePos.y)
		customRouteScoring = result.customRouteScoring and util.deepClone(result.customRouteScoring) or paramHelper.getRouteScoringParams(isTrack, isCargo)
		refreshSliders() 
	end)
	
	
	return result
end 

local function buildVehicleChooser(vehicleType) 
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	boxLayout:addItem(api.gui.comp.TextView.new(_(vehicleType)))
	local refreshButton = util.newButton(" ", "ui/button/xxsmall/replace@2x.tga")
	boxLayout:addItem(refreshButton)
	local lookup = {}
	local combobox = api.gui.comp.ComboBox.new()
	boxLayout:addItem(combobox)
	local addButton = util.newButton("Add")
	boxLayout:addItem(addButton)
	local clearButton = util.newButton("Clear")
	local selectionLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	boxLayout:addItem(selectionLayout)
	local selected = {}
	local function refresh() 
		if not paramHelper.findVehiclesOfType then 
			trace("Skipping refresh as findVehiclesOfType function not available ")
			return 
		end
		local vehiclesByDesc = {}
		lookup = {}
		combobox:clear(false) 
		for i, vehicle in pairs(paramHelper.findVehiclesOfType(vehicleType)) do 
			local desc = paramHelper.getVehicleDescription(vehicle)
			if vehiclesByDesc[desc] then 
				desc = desc..tostring(vehicle.modelid) -- crude way to uniqueify
			end 
			vehiclesByDesc[desc]=vehicle
		end
		for __, desc in pairs(util.getKeysAsTable(vehiclesByDesc)) do 
			combobox:addItem(desc)
			table.insert(lookup, vehiclesByDesc[desc])
		end
	end 
	refreshButton:onClick(refresh)
	addButton:onClick(function() 
		local selectedItem = lookup[combobox:getCurrentIndex()+1]
		if not selectedItem then 
			trace("Unable to find selected item for ",combobox:getCurrentIndex())
			return
		end
		if not selected[selectedItem.modelId] then 
			local model = selectedItem.model
			local name = model.metadata.description.name
		 
			local icon = model.metadata.description.icon20
		 
			local imageView = api.gui.comp.ImageView.new(icon)
			imageView:setTooltip(_(name))
			selectionLayout:addItem(imageView)
			selected[selectedItem.modelId] = true
		end
	end)
	
	local function reset()
		for i =  selectionLayout:getNumItems(), 1, -1 do 
			trace("buildVehicleChooser: Removing item at ",i)
			selectionLayout:removeItem(selectionLayout:getItem(i-1))
			trace("buildVehicleChooser: Removed item at ",i)
		end
		for k, v in pairs(selected) do 
			selected[k]=nil
		end 
		refresh()
	end 
	boxLayout:addItem(clearButton)
	clearButton:onClick(reset)
	return {
		comp = boxLayout,
		refresh = refresh,
		reset = reset,
		vehicleType = vehicleType,
		setVehicleFavourites = function(params)
			if not params.vehicleFavourites then 
				params.vehicleFavourites = {}
			end
			if util.size(selected) == 0 then 
				params.vehicleFavourites[vehicleType]=nil 
			else 
				params.vehicleFavourites[vehicleType]=selected
			end
		end 
	}
	
end

function paramHelper.buildRouteOverridesChooser(isTrack, isCargo, vehicleOnly, allVehicles)
	local result = {} 
	result.button = util.newButton("","ui/button/small/line_tasks@2x.tga")
	trace("Created button for overrides chooser")
	local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local customOptions = {}
	boxLayout:addItem(api.gui.comp.TextView.new(_("Vehicle set")))
	
	local vehicleButtonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local autoDetect = util.newToggleButton("AUTO DETECT")
	local europe = util.newToggleButton("EUROPE")
	local usa = util.newToggleButton("USA")
	local asia = util.newToggleButton("ASIA")
	local all = util.newToggleButton("ALL")
	autoDetect:setSelected(true, false)
	vehicleButtonGroup:setOneButtonMustAlwaysBeSelected(true)
	vehicleButtonGroup:add(autoDetect)
	vehicleButtonGroup:add(europe)
	vehicleButtonGroup:add(usa)
	vehicleButtonGroup:add(asia)
	vehicleButtonGroup:add(all)
	local buttonLookup = { "auto", "europe", "usa", "asia", "all" }
	boxLayout:addItem(vehicleButtonGroup)
	
	
	local acceptButton = util.newButton("Accept","ui/button/small/accept@2x.tga")
	local resetButton = util.newButton("Reset","ui/button/xxsmall/replace@2x.tga")
	local cancelButton = util.newButton("Cancel","ui/button/small/cancel@2x.tga")
	local banElectric = api.gui.comp.CheckBox.new(_("Ban electric locomotives"))
	local banDiesel = api.gui.comp.CheckBox.new(_("Ban diesel locomotives"))
	local banSteam = api.gui.comp.CheckBox.new(_("Ban steam locomotives"))
	trace("Building route overrides chooser")
	banElectric:onToggle(function(b) 
		if b then 
			customOptions.locomotiveRestriction = api.type.enum.VehicleEngineType.ELECTRIC
			banDiesel:setSelected(false, false)
			banSteam:setSelected(false, false)
		else 
			customOptions.locomotiveRestriction = -1
		end 
	end)
	banDiesel:onToggle(function(b) 
		if b then 
			customOptions.locomotiveRestriction = api.type.enum.VehicleEngineType.DIESEL
			banElectric:setSelected(false, false)
			banSteam:setSelected(false, false)
		else 
			customOptions.locomotiveRestriction = -1
		end 
	end)
	banSteam:onToggle(function(b) 
		if b then 
			customOptions.locomotiveRestriction = api.type.enum.VehicleEngineType.STEAM
			banDiesel:setSelected(false, false)
			banElectric:setSelected(false, false)
		else 
			customOptions.locomotiveRestriction = -1
		end 
	end)
	local banMu = api.gui.comp.CheckBox.new(_("Ban multiple units"))
	boxLayout:addItem(api.gui.comp.TextView.new(_("Locomotive restrictions")))
	boxLayout:addItem(banElectric)
	boxLayout:addItem(banDiesel)
	boxLayout:addItem(banSteam)
	boxLayout:addItem(banMu)
	boxLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxLayout:addItem(api.gui.comp.TextView.new(_("Vehicle favourites")))
	local vehicleChoosers = {} 
	local vehicleTypes = {}
	if isTrack then 
		vehicleTypes = {"train", "waggon" }
	else 
		vehicleTypes = {"bus", "truck" }
	end	
	if allVehicles then 
		vehicleTypes = {"train", "waggon", "bus", "truck", "ship", "plane", "tram" }
	end
	for i, vehicleType in pairs(vehicleTypes) do
		local vehicleChooser = buildVehicleChooser(vehicleType)
		vehicleChoosers[i]=vehicleChooser
		boxLayout:addItem(vehicleChooser.comp)
	end
	boxLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	
	local function addSlider(description, maxValue, defaultValue, minValue, tooltip, step)
		trace("Adding slider for ",description," maxValue=",maxValue,"defaultValue=",defaultValue,"minValue=",minValue)
		local topLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
		topLayout:addItem(api.gui.comp.TextView.new(_(description)))
		
		local slider = api.gui.comp.Slider.new(true) 
		if not minValue then 
			minValue = math.min(defaultValue, 1)
		end 
		slider:setMinimum(minValue)
		slider:setMaximum(maxValue)
		if not step then step = 1 end
		slider:setStep(step)
		slider:setPageStep(step)

		slider:setValue(math.floor(defaultValue),false)
		local size = slider:calcMinimumSize()
		size.w = size.w+120
		slider:setMinimumSize(size)
		--slider:setVisible(false, false)
		topLayout:addItem(slider)
		local sliderDisplay = api.gui.comp.TextView.new(tostring(defaultValue))
		topLayout:addItem(sliderDisplay)
		slider:onValueChanged(function(x) 
			 sliderDisplay:setText(tostring(x).."‰")
		end)
		if tooltip then 
			slider:setTooltip(_(tooltip))
		end
		boxLayout:addItem(topLayout)
		return slider
	end
	
	local checkBoxes = {}
	local defaultParams = paramHelper.getDefaultRouteBuildingParams(isCargo and "GOODS" or "PASSENGERS", isTrack)
	
	local maxGrad = isTrack and 75 or 200
	local targetGradSlider = addSlider("Target gradient", maxGrad, defaultParams.maxGradient*1000, 1, "Attempts to follow the terrain subject to not exceeding the target gradient")
	local maxGradSlider = addSlider("Maximum gradient", maxGrad, defaultParams.absoluteMaxGradient*1000, 1, "Maximum gradient allowed when unable to achieve the target gradient, such as deconflicting with obstacles and/or building between stations with a large elevation change")
	
	boxLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local rateOverrideCkBx = api.gui.comp.CheckBox.new(_("Override rate?"))
	boxLayout:addItem(rateOverrideCkBx)

	local rateOverrideSlider = addSlider("Rate:", 4000, 100, 10, "Rate that will be targeted when choosing vehicles", 10)
	rateOverrideCkBx:onToggle(function(b)
		rateOverrideSlider:setEnabled(b, false)
	end)
	rateOverrideSlider:setEnabled(false,false)

	boxLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	
	local allowList = {
		alwaysDoubleTrackPassengerTerminus=true,
		buildGradeSeparatedTrackJunctions=true,
		allowPassengerCargoTrackSharing=true,
		buildInitialBusNetwork = true,
		useDoubleTerminals = true,
		combineRailPassengerRoutes = true,
		allowCargoTrackSharing = true,
		keepExistingVehicleConfig = true,
	}
	
	
	if isCargo then 
		allowList.isWaitForFullLoad = true 
	end
	
	for k, v in pairs(defaultParams) do 
		if type(v) == "boolean" and allowList[k] then 
			local checkBox = api.gui.comp.CheckBox.new(_(k))
			checkBoxes[k]=checkBox
			checkBox:onToggle(function(b) customOptions[k]=b end)
			boxLayout:addItem(checkBox)
		end 
	
	end
	
	
	local numericOptions = {}
	if util.tracelog and true then 
		local allowList = {
			routeEvaluationLimit = true,
			outerIterations = true,
			routeEvaluationOffsetsLimit = true,
			trackTargetSpeed = true,
			routeEvaluationBehaviourOverride = true,
			collisionCheckMode = true, 
		}
		for k, v in pairs(defaultParams) do 
			if allowList[k] then 
				local selectionLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
				local label = api.gui.comp.TextView.new(_(k))
				local input = api.gui.comp.TextInputField.new(tostring(v))
				input:setText(tostring(v), false)
				selectionLayout:addItem(label)
				selectionLayout:addItem(input)
				boxLayout:addItem(selectionLayout)
				table.insert(numericOptions, {
					input = input,
					originalValue = v,
					key = k,
				})
			end 
		end 
		
	end 
	--[[local allowPassengerCargoTrackSharing = api.gui.comp.CheckBox.new(_("Allow passenger-cargo track sharing"))
	allowPassengerCargoTrackSharing:onToggle(function(b)
		customOptions.allowPassengerCargoTrackSharing=b
	end)
	boxLayout:addItem(allowPassengerCargoTrackSharing)
	local buildGradeSeparatedTrackJunctions = api.gui.comp.CheckBox.new(_("Build grade separated track junctions"))
	boxLayout:addItem(buildGradeSeparatedTrackJunctions)
	buildGradeSeparatedTrackJunctions:onToggle(function(b)
		customOptions.buildGradeSeparatedTrackJunctions=b
	end)]]--
	
	boxLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxLayout:addItem(api.gui.comp.TextView.new(_("Station Length")))
	local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local autoToggle = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new("AUTO"))
	buttonGroup:add(autoToggle)
	local lengthToggles ={}
	for i = 0, 5 do 
		local toggle= api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(api.util.formatLength(paramHelper.getStationLength(i))))
		local stationLengthParam = i
		toggle:onToggle(function(b) 
			if b then 
				customOptions.stationLength = paramHelper.getStationLength(stationLengthParam)
				customOptions.stationLengthParam = stationLengthParam
			end
		end) 
		buttonGroup:add(toggle)
		lengthToggles[i]=toggle
	end 
	autoToggle:onToggle(function(b) 
		if b then 
			customOptions.stationLength = nil 
			customOptions.stationLengthParam = nil
		end
	end)
	
	autoToggle:setSelected(true, false)
	buttonGroup:setOneButtonMustAlwaysBeSelected(true)
	boxLayout:addItem(buttonGroup)
	
	local bottomLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	bottomLayout:addItem(acceptButton)
	bottomLayout:addItem(resetButton)
	bottomLayout:addItem(cancelButton)
	boxLayout:addItem(bottomLayout)
	
	local wrap = api.gui.comp.Component.new(" ")
	wrap:setLayout(boxLayout)
	local scrollArea = api.gui.comp.ScrollArea.new(wrap,"Route Options")
	local windowLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	windowLayout:addItem(scrollArea)
	
	local prefix = isTrack and _("Rail") or _("Road")
	local suffix = "("..(isCargo and _("Cargo") or _("Passengers"))..")" 
	local window = api.gui.comp.Window.new(prefix.." ".._('Route options').." "..suffix, windowLayout)
	window:addHideOnCloseHandler()
	window:setVisible(false, false)
	cancelButton:onClick(function() window:close() end)
	local function resetUnsafe() 
		local params = paramHelper.getParams()
		customOptions =  {}--paramHelper.getRouteScoringParams(isTrack, isCargo)
		result.customOptions = nil 
		banElectric:setSelected(false, true)
		banDiesel:setSelected(false, true)
		banSteam:setSelected(false, true)
		banMu:setSelected(false, false)
		rateOverrideCkBx:setSelected(false,true)
		--allowPassengerCargoTrackSharing:setSelected(false, true)
		---buildGradeSeparatedTrackJunctions:setSelected(params.buildGradeSeparatedTrackJunctions, true)
		local defaultParams = paramHelper.getDefaultRouteBuildingParams(isCargo and "GOODS" or "PASSENGERS", isTrack)
		for k, chkbox in pairs(checkBoxes) do 
			chkbox:setSelected(defaultParams[k], false)
		end 
		--lengthToggles[params.stationLengthParam]:setSelected(true, true)
		autoToggle:setSelected(true, true)
		targetGradSlider:setValue(math.floor(defaultParams.maxGradient*1000), true)
		maxGradSlider:setValue(math.floor(defaultParams.absoluteMaxGradient*1000), true)
		for i = 1, vehicleButtonGroup:getNumButtons() do 
			local button = vehicleButtonGroup:getButton(i-1)
			button:setSelected(i==1, false)
		end
		for i, vehicleChooser in pairs(vehicleChoosers) do 
			vehicleChooser.reset()	
		end 
	end 
	local reset = function() xpcall(resetUnsafe, util.err) end
	resetButton:onClick(reset)
	
	 
	
	acceptButton:onClick(function() 
		for i = 0, 4 do 
			if lengthToggles[i]:isSelected() then -- seems we can't always rely on the onToggle callback
				customOptions.stationLength = paramHelper.getStationLength(i)
				customOptions.stationLengthParam = i
				break
			end			
		end 
		for i = 1, vehicleButtonGroup:getNumButtons() do 
			local button = vehicleButtonGroup:getButton(i-1)
			trace("Checking climate button at ",i," isSelected=",button:isSelected())
			if button:isSelected() then 
				customOptions.vehicleRestriction = buttonLookup[i]
				if customOptions.locomotiveRestriction == api.type.enum.VehicleEngineType.ELECTRIC then 
					customOptions.isElectricTrack = false
				end
				trace("Set vehicle restriction to",customOptions.vehicleRestriction)
				break
			end 
		end 
		customOptions.banMu = banMu:isSelected()
		customOptions.maxGradient = targetGradSlider:getValue()/1000
		customOptions.absoluteMaxGradient = maxGradSlider:getValue()/1000
		if rateOverrideCkBx:isSelected() then
			customOptions.rateOverride = rateOverrideSlider:getValue()
		else 
			customOptions.rateOverride = nil
		end 
		
		for i, numericOption in pairs(numericOptions) do 
			local value = numericOption.originalValue
			local text = numericOption.input:getText()
			if not pcall(function() 
				value = tonumber(text)
			end) then 
				trace("WARNING! Could not parse",text, "defaulting to ",value,"for",numericOption.key)
			end 
			customOptions[numericOption.key]=value
		end 
		
		for i, vehicleChooser in pairs(vehicleChoosers) do 
			trace("About to set favourites for ",vehicleChooser.vehicleType)
			vehicleChooser.setVehicleFavourites(customOptions)
		end 
		result.customOptions = util.deepClone(customOptions)
		window:close()
	end)
	local isInit = false
	result.button:onClick(function() 
		window:setVisible(true, false)
		local mousePos = api.gui.util.getMouseScreenPos()
		window:setPosition(mousePos.x,mousePos.y)
		if not isInit then 
			reset() 
			isInit = true 
		end
		--refreshSliders() 
	end)
	
	
	return result
end 
return paramHelper