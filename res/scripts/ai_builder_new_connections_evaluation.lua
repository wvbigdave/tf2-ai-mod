local util = require("ai_builder_base_util")
local paramHelper = require("ai_builder_base_param_helper")
local vec3 = require("vec3")
local vec2 = require("vec2")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local helper = require("ai_builder_station_template_helper")
local minimap = require("ai_builder_minimap")
local vehicleUtil = require("ai_builder_vehicle_util")
local waterMeshUtil = require "ai_builder_water_mesh_util"
local profiler = require "ai_builder_profiler"
local isdebuglog = false 
local trackWidth = 5
local trace = 	util.trace

local AUTOCARRIER = 999

local function err(x) 
	print(x)
	print(debug.traceback())
end
   

local function debuglog(...) 
	if isdebuglog then 
		print(...)
	end
end
local findEdgeForIndustry = util.findEdgeForIndustry
local evaluation = {}
evaluation.failedConnections = {}

-- Stub for function normally injected by game script
function evaluation.getBackgoundWorkQueue()
    return 0
end
evaluation.completedConnections = {}
evaluation.locationsInCoolDown = {}
evaluation.waterCheckedLocations = {}
evaluation.waterCheckedPairs = {}
function evaluation.checkIfFailed(transportType, locationId1, locationId2)
	local result = evaluation.failedConnections[transportType]
	and evaluation.failedConnections[transportType][locationId1]
	and evaluation.failedConnections[transportType][locationId1][locationId2]
	if result then 
		local clearStatusAfter = 1200
		trace("The route for ",transportType," between ",locationId1," and ",locationId2, " has been marked as failed at",result )
		if transportType~=api.type.enum.Carrier.WATER then 
			local timeSinceFailed = game.interface.getGameTime().time - result 
			if timeSinceFailed > clearStatusAfter then 
				trace("Clearing result as the time has elapsed, timeSinceFailed=",timeSinceFailed)
				evaluation.failedConnections[transportType][locationId1][locationId2] = false
				return false
			else 
				trace("Not clearing as the timeSinceFailed=",timeSinceFailed)
			end 			
		end 
	end
	return result
end



function evaluation.markConnectionAsFailed(transportType, locationId1, locationId2)
	if not evaluation.failedConnections[transportType] then
		evaluation.failedConnections[transportType]={}
	end
	if not evaluation.failedConnections[transportType][locationId1] then
		evaluation.failedConnections[transportType][locationId1]={}
	end
	evaluation.failedConnections[transportType][locationId1][locationId2]=game.interface.getGameTime().time
end

function evaluation.clearFailuredStatus(transportType, locationId1, locationId2) 
	if evaluation.checkIfFailed(transportType, locationId1, locationId2) then 
		evaluation.failedConnections[transportType][locationId1][locationId2]=false
	end 
end 
function evaluation.checkIfCompleted(transportType, locationId1, locationId2)
	local result = evaluation.completedConnections[transportType]
	and evaluation.completedConnections[transportType][locationId1]
	and evaluation.completedConnections[transportType][locationId1][locationId2]
	if result then 
		trace("The route for ",transportType," between ",locationId1," and ",locationId2, " has been marked as failed")
	end
	return result
end

local function coolDownLocation(location) 
	local gameTime = game.interface.getGameTime().time 
	trace("Cooling down location",location," at ",gameTime)
	evaluation.locationsInCoolDown[location] = gameTime
end 
evaluation.coolDownLocation = coolDownLocation
local function isLocationInCooldown(location) 
	trace("Begin check for location in cooldown",location)
	if not evaluation.isAutoBuildMode then 
		trace("returning false, not autobuild")
		return false 
	end
	if not evaluation.locationsInCoolDown[location] then
		trace("returning false, not in map")
		return false 
	end
	local minInterval = 600
	if util.year() < 1900 then  -- due to slow vehicles need longer to esablish shipping
		minInterval = minInterval * 2
	end 
	local gameTime = game.interface.getGameTime().time 
	local res = gameTime - evaluation.locationsInCoolDown[location] < minInterval
	trace("Checking for location is in cooldown",location," result?",res)
	return res 
end 

function evaluation.markConnectionAsComplete(transportType, locationId1, locationId2)
	if not transportType or not locationId1 or not locationId2 then 
		trace("WARNING! call to markConnectionAsComplete with nil value",transportType, locationId1, locationId2)
		trace(debug.traceback())
		return
	end 
	if not evaluation.completedConnections[transportType] then
		evaluation.completedConnections[transportType]={}
	end
	if not evaluation.completedConnections[transportType][locationId1] then
		evaluation.completedConnections[transportType][locationId1]={}
	end
	coolDownLocation(locationId1) 
	coolDownLocation(locationId2) 
	evaluation.completedConnections[transportType][locationId1][locationId2]=true
end
local function getTotalTownDests()
	local totalDests = 0 
	api.engine.forEachEntityWithComponent(function(town) 
		local capacities =   game.interface.getTownCapacities(town)
		totalDests = totalDests + capacities[2] + capacities[3]
	end, api.type.ComponentType.TOWN)
	return totalDests
end
local function getAllIndustries() 
	return util.deepClone(game.interface.getEntities({radius=math.huge, pos={0,0,0}}, {type="SIM_BUILDING", includeData=false}))
end
local function getAllTowns() 
	return util.deepClone(game.interface.getEntities({radius=math.huge, pos={0,0,0}}, {type="TOWN", includeData=false}))
end

local function distBetweenTowns(town1, town2) 
	return util.distance(util.v3fromArr(town1.position), util.v3fromArr(town2.position))
end 

local function getFileNameOfIndustry(industry)
	local function populateCache() 
		local fileNameCache = {} -- use local variable for thread safety
		local allIndustries = getAllIndustries()
		for i, industryId in pairs(allIndustries) do 
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industryId)
			fileNameCache[industryId]=util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION).fileName
		end
		for i, townId in pairs(getAllTowns()) do 
			fileNameCache[townId]="TOWN"
		end 
		evaluation.fileNameCache= fileNameCache
	end
	if not evaluation.fileNameCache then 
		populateCache() 
	end
	local industryId 
	if type(industry) == "number" then 
		industryId = industry
	else 
		industryId = industry.id
	end
	if not evaluation.fileNameCache[industryId] then 
		populateCache() 
	end
	return evaluation.fileNameCache[industryId]
end
local function getProductionLevelsForIndustry(industry) 
	local function populateCache() 
		local productionLevelCache = {} 
		local allIndustries = getAllIndustries()
		for i, industryId in pairs(allIndustries) do 
			 
			local fileName = getFileNameOfIndustry(industryId)
			local constructionRep = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
			local productionLevels  = 1
			for k, v in pairs(constructionRep.params) do 
				if v.key == "productionLevel" then 
					productionLevels = #v.values
					break
				end
			end
			productionLevelCache[industryId]=productionLevels
		end
		evaluation.productionLevelCache = productionLevelCache 
	end
	if not evaluation.productionLevelCache then 
		populateCache()
	end
	local industryId 
	if type(industry) == "number" then 
		industryId = industry
	else 
		industryId = industry.id
	end
	if not evaluation.productionLevelCache[industryId] then 
		populateCache()
	end 
	return evaluation.productionLevelCache[industryId]
end
local function getBackupSourcesMap()
	-- Return tables with cargo types as keys (matching the structure expected by the main code)
	local result = {}
	result["industry/chemical_plant.con"]={["PLASTIC"]=1}
	result["industry/construction_material.con"]={["STONE"]=1, ["STEEL"]=1}
	result["industry/food_processing_plant.con"]={["GRAIN"]=4}
	result["industry/fuel_refinery.con"]={["CRUDE"]=1}
	result["industry/goods_factory.con"]={["STEEL"]=1, ["PLASTIC"]=1}
	result["industry/machines_factory.con"]={["STEEL"]=1, ["PLASTIC"]=1}
	result["industry/oil_refinery.con"]={["CRUDE"]=2}
	result["industry/saw_mill.con"]={["LOGS"]=2}
	result["industry/steel_mill.con"]={["IRON_ORE"]=1, ["COAL"]=1}
	result["industry/tools_factory.con"]={["STEEL"]=1, ["PLANKS"]=1}
	return result
end

-- Backup map of what cargo types each industry PRODUCES
local function getBackupIndustriesToOutput()
	local result = {}
	-- Raw material producers
	result["industry/iron_ore_mine.con"] = {"IRON_ORE"}
	result["industry/coal_mine.con"] = {"COAL"}
	result["industry/forest.con"] = {"LOGS"}
	result["industry/oil_well.con"] = {"CRUDE"}
	result["industry/quarry.con"] = {"STONE"}
	result["industry/farm.con"] = {"GRAIN"}
	-- Processing industries
	result["industry/steel_mill.con"] = {"STEEL"}
	result["industry/saw_mill.con"] = {"PLANKS"}
	result["industry/oil_refinery.con"] = {"FUEL", "PLASTIC"}
	result["industry/chemical_plant.con"] = {"PLASTIC"}
	result["industry/fuel_refinery.con"] = {"FUEL"}
	result["industry/food_processing_plant.con"] = {"FOOD"}
	-- Final goods producers
	result["industry/tools_factory.con"] = {"TOOLS"}
	result["industry/machines_factory.con"] = {"MACHINES"}
	result["industry/goods_factory.con"] = {"GOODS"}
	result["industry/construction_material.con"] = {"CONSTRUCTION_MATERIALS"}
	return result
end

-- Backup map of which industries CONSUME which cargo types
local function getBackupInputsToIndustries()
	local result = {}
	result["IRON_ORE"] = {"industry/steel_mill.con"}
	result["COAL"] = {"industry/steel_mill.con"}
	result["LOGS"] = {"industry/saw_mill.con"}
	result["CRUDE"] = {"industry/oil_refinery.con"}
	result["STONE"] = {"industry/construction_material.con"}
	result["GRAIN"] = {"industry/food_processing_plant.con"}
	result["STEEL"] = {"industry/goods_factory.con", "industry/machines_factory.con", "industry/tools_factory.con", "industry/construction_material.con"}
	result["PLANKS"] = {"industry/tools_factory.con", "industry/machines_factory.con"}
	result["PLASTIC"] = {"industry/goods_factory.con", "industry/machines_factory.con"}
	result["FUEL"] = {"TOWN"}
	result["FOOD"] = {"TOWN"}
	result["TOOLS"] = {"TOWN"}
	result["MACHINES"] = {"TOWN"}
	result["GOODS"] = {"TOWN"}
	result["CONSTRUCTION_MATERIALS"] = {"TOWN"}
	return result
end

-- Backup capacity data for vanilla industries
-- Format: capacities[industry][cargoType] = output amount per cycle
local function getBackupCapacities()
	local result = {}
	-- Raw material producers (default 100 capacity each)
	result["industry/iron_ore_mine.con"] = {["IRON_ORE"]=100}
	result["industry/coal_mine.con"] = {["COAL"]=100}
	result["industry/forest.con"] = {["LOGS"]=100}
	result["industry/oil_well.con"] = {["CRUDE"]=100}
	result["industry/quarry.con"] = {["STONE"]=100}
	result["industry/farm.con"] = {["GRAIN"]=100}
	-- Processing industries
	result["industry/steel_mill.con"] = {["STEEL"]=100}
	result["industry/saw_mill.con"] = {["PLANKS"]=100}
	result["industry/oil_refinery.con"] = {["FUEL"]=50, ["PLASTIC"]=50}
	result["industry/chemical_plant.con"] = {["PLASTIC"]=100}
	result["industry/fuel_refinery.con"] = {["FUEL"]=100}
	result["industry/food_processing_plant.con"] = {["FOOD"]=100}
	-- Final goods producers
	result["industry/tools_factory.con"] = {["TOOLS"]=100}
	result["industry/machines_factory.con"] = {["MACHINES"]=100}
	result["industry/goods_factory.con"] = {["GOODS"]=100}
	result["industry/construction_material.con"] = {["CONSTRUCTION_MATERIALS"]=100}
	return result
end

-- Backup production levels (all industries start at level 1)
local function getBackupProductionLevels()
	local result = {}
	result["industry/iron_ore_mine.con"] = 1
	result["industry/coal_mine.con"] = 1
	result["industry/forest.con"] = 1
	result["industry/oil_well.con"] = 1
	result["industry/quarry.con"] = 1
	result["industry/farm.con"] = 1
	result["industry/steel_mill.con"] = 1
	result["industry/saw_mill.con"] = 1
	result["industry/oil_refinery.con"] = 1
	result["industry/chemical_plant.con"] = 1
	result["industry/fuel_refinery.con"] = 1
	result["industry/food_processing_plant.con"] = 1
	result["industry/tools_factory.con"] = 1
	result["industry/machines_factory.con"] = 1
	result["industry/goods_factory.con"] = 1
	result["industry/construction_material.con"] = 1
	return result
end

-- Backup base capacities
local function getBackupBaseCapacities()
	local result = {}
	result["industry/iron_ore_mine.con"] = 100
	result["industry/coal_mine.con"] = 100
	result["industry/forest.con"] = 100
	result["industry/oil_well.con"] = 100
	result["industry/quarry.con"] = 100
	result["industry/farm.con"] = 100
	result["industry/steel_mill.con"] = 100
	result["industry/saw_mill.con"] = 100
	result["industry/oil_refinery.con"] = 100
	result["industry/chemical_plant.con"] = 100
	result["industry/fuel_refinery.con"] = 100
	result["industry/food_processing_plant.con"] = 100
	result["industry/tools_factory.con"] = 100
	result["industry/machines_factory.con"] = 100
	result["industry/goods_factory.con"] = 100
	result["industry/construction_material.con"] = 100
	return result
end

-- Backup rule sources (how many sources needed for each input)
-- Format: ruleSources[industry][cargoType] = number of sources
local function getBackupRuleSources()
	local result = {}
	-- Raw material producers have no inputs
	result["industry/iron_ore_mine.con"] = {}
	result["industry/coal_mine.con"] = {}
	result["industry/forest.con"] = {}
	result["industry/oil_well.con"] = {}
	result["industry/quarry.con"] = {}
	result["industry/farm.con"] = {}
	-- Processing industries
	result["industry/steel_mill.con"] = {["IRON_ORE"]=1, ["COAL"]=1}
	result["industry/saw_mill.con"] = {["LOGS"]=1}
	result["industry/oil_refinery.con"] = {["CRUDE"]=1}
	result["industry/chemical_plant.con"] = {["CRUDE"]=1}
	result["industry/fuel_refinery.con"] = {["CRUDE"]=1}
	result["industry/food_processing_plant.con"] = {["GRAIN"]=1}
	-- Final goods producers
	result["industry/tools_factory.con"] = {["STEEL"]=1, ["PLANKS"]=1}
	result["industry/machines_factory.con"] = {["STEEL"]=1, ["PLASTIC"]=1}
	result["industry/goods_factory.con"] = {["STEEL"]=1, ["PLASTIC"]=1}
	result["industry/construction_material.con"] = {["STONE"]=1, ["STEEL"]=1}
	return result
end

local function getBackupConsumerToProducerMap()
	local backupResult = {}
	backupResult["industry/chemical_plant.con"]={ "industry/goods_factory.con"}
	backupResult["industry/coal_mine.con"]={ "industry/steel_mill.con"}
	backupResult["industry/construction_material.con"]={ "TOWN", "CONSTRUCTION_MATERIALS" }
	backupResult["industry/farm.con"]={"industry/food_processing_plant.con" }
	backupResult["industry/food_processing_plant.con"]={ "TOWN", "FOOD" }
	backupResult["industry/forest.con"]={"industry/saw_mill.con" }
	backupResult["industry/fuel_refinery.con"]={"TOWN", "FUEL" }
	backupResult["industry/goods_factory.con"]={"TOWN", "GOODS" }
	backupResult["industry/iron_ore_mine.con"]={ "industry/steel_mill.con"}
	backupResult["industry/machines_factory.con"]={ "TOWN", "MACHINES"}
	backupResult["industry/oil_refinery.con"]={ "industry/fuel_refinery.con", "industry/chemical_plant.con"}
	backupResult["industry/oil_well.con"]={ "industry/oil_refinery.con"}
	backupResult["industry/quarry.con"]={ "industry/construction_material.con"}
	backupResult["industry/saw_mill.con"]={ "industry/machines_factory.con", "industry/tools_factory.con" }
	backupResult["industry/steel_mill.con"]={ "industry/goods_factory.con", "industry/machines_factory.con"}
	backupResult["industry/tools_factory.con"]= {"TOWN", "TOOLS"} 
	return backupResult
end

local possibleTownOutputs = {
	["WASTE"]=true, 
	["UNSORTED_MAIL"]=true

}

local function getVectorBetweenTowns(town1, town2)
	if type(town1)=="number" then 
		town1 = util.getEntity(town1)
	end
	if type(town2)=="number" then 
		town2 = util.getEntity(town2)
	end
	local town1xypos = vec2.new(town1.position[1],town1.position[2])
	local town2xypos = vec2.new(town2.position[1],town2.position[2])
	return util.v2ToV3(vec2.normalize(vec2.sub(town1xypos,town2xypos)))
end
local function discoverIndustryData()
	local begin = os.clock()
	trace("Discovering industry data")
-- quite a lot of hacking to get this from the api, the rules are only revealed during load, so "hide" them in the construction params
	local industriesToOutput = {}
	local inputsToIndustries = {}
	local allIndustryTypes = {}
	local productionLevels = {} 
	local capacities = {}
	local baseCapacities = {}
	local ruleSources = {}
	local totalSourcesCount = {}
	local sourcesCountMap = {} 
	local hasOrCondition = {}
	local cargoTypeSet = {}
	local multiSupplyIndustry = {}
	local placementWeights = {}
	local ruleCapacities = {}
	local isRecyclingPlant = {}
	local maxConsumption = {}
	local allCargoTypes = util.deepClone(api.res.cargoTypeRep.getAll())
	for __ , fileName in pairs(util.deepClone(api.res.constructionRep.getAll())) do 
		if string.find(fileName, "industry") and not string.find(fileName,"industry/extension/") then 
			trace("Inspecting industry ",fileName)
			table.insert(allIndustryTypes, fileName)
			local productionLevel  = 1
			local industryRep = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
			local thisRuleSources = {}
			local thisInputCargos={}
			
			local thisOutputCapacities = {}
			industriesToOutput[fileName] = {}
			for i, param in pairs(industryRep.params) do 
				if param.key == "inputCargoTypeForAiBuilder" then 
					for j, cargoType in pairs(param.values) do 
						if cargoType == "NONE" then break end -- required dummy entry for ui validation
						if not inputsToIndustries[cargoType] then 
							inputsToIndustries[cargoType] = {}
						end
						table.insert(inputsToIndustries[cargoType], fileName)							
					end 
					thisInputCargos = param.values
				end 
				if param.key == "outputCargoTypeForAiBuilder" then 
					for j, cargoType in pairs(param.values) do 
						if cargoType == "NONE" then
							break 
						end
						table.insert(industriesToOutput[fileName], cargoType)
					end
				end
				if param.key == "capacityForAiBuilder" then 
					thisOutputCapacities = param.values
					
				end
				if param.key == "productionLevel" then 
					productionLevel = #param.values 
				end 
				if param.key == "sourcesCountForAiBuilder" then 
					thisRuleSources=param.values
				end 
				if param.key == "townBuilderWeights"  then 
			
					local buildOrder = param.values[1]
					local initWeight = param.values[2]
					trace("Found townBuilderWeights with params",#param.values,"buildOrder=",buildOrder,"initWeight=",initWeight)
					placementWeights[fileName]=tonumber(initWeight)
				end 
			end
			ruleSources[fileName]={}
			capacities[fileName]={}
			ruleCapacities[fileName]={}
			maxConsumption[fileName]={}
			totalSourcesCount[fileName]=0
			productionLevels[fileName]=productionLevel
			local baseCapacity = tonumber(thisOutputCapacities[#thisOutputCapacities])
			baseCapacities[fileName]=baseCapacity
			for i =1, #thisInputCargos do 
				local cargoType = thisInputCargos[i]
				local sourcesCount = tonumber(thisRuleSources[i])
				if sourcesCount < 1 and not hasOrCondition[fileName] and cargoType ~= "NONE" then 
					hasOrCondition[fileName] = true 
				end
				sourcesCount = math.max(sourcesCount,1)
				--ruleSources[fileName][cargoType]=math.max(sourcesCount,1) -- TODO need to think about how to handle "OR" logic
				ruleSources[fileName][cargoType]=sourcesCount 
				totalSourcesCount[fileName] = totalSourcesCount[fileName]+sourcesCount
				
				if cargoType == "WASTE" then 
					trace("Marking file",fileName,"as recycling plant")
					isRecyclingPlant[fileName]=true
				end 
				maxConsumption[fileName][cargoType] = productionLevel*baseCapacity*sourcesCount
			end 
			
			for i , cargoType in pairs(industriesToOutput[fileName]) do
				local capacity = thisOutputCapacities[i]
				if not capacity then
					trace("WARNING, having to default capcities by default")
					capacity = paramHelper.getParams().baseIndustryCapacity / productionLevels[fileName]
					if fileName == "industry/farm.con" then
						capacity = capacity / 2
					end
				end 
				capacities[fileName][cargoType]=tonumber(capacity)
				ruleCapacities[fileName][cargoType]=tonumber(capacity)/baseCapacity
			end
		
		end 
	end
	local townInputs = {} 
	for i, cargoTypeName in pairs(allCargoTypes) do 
		local cargoIdx = api.res.cargoTypeRep.find(cargoTypeName)
		cargoTypeSet[cargoTypeName]=cargoIdx
		cargoTypeSet[cargoIdx]=cargoIdx
		local cargoTypeRep = api.res.cargoTypeRep.get(cargoIdx) -- using i directly seems to be unreliable
		if #cargoTypeRep.townInput > 0 then 
			if not inputsToIndustries[cargoTypeName] then 
				inputsToIndustries[cargoTypeName] = {"TOWN" } 
				townInputs[cargoTypeName]=true
			else 
				trace("Problem, inputToIndustries already defined for ",cargoTypeName)
			end 
		end 
			
	end 
	 
	local backupResult = getBackupConsumerToProducerMap()
	local backupOutputs = getBackupIndustriesToOutput()
	local backupInputs = getBackupInputsToIndustries()
	local backupCapacities = getBackupCapacities()
	local backupProductionLevels = getBackupProductionLevels()
	local backupBaseCapacities = getBackupBaseCapacities()
	local backupRuleSources = getBackupRuleSources()

	-- Populate inputsToIndustries with backup data for any cargo types not already mapped
	for cargoType, industries in pairs(backupInputs) do
		if not inputsToIndustries[cargoType] then
			inputsToIndustries[cargoType] = industries
			trace("Using backup inputsToIndustries for cargo type: ", cargoType)
		end
	end

	local result = {}
	for i = 1, #allIndustryTypes do
		local industryName = allIndustryTypes[i]
		-- Check for nil OR empty table (vanilla industries without AI Builder params)
		if not industriesToOutput[industryName] or #industriesToOutput[industryName] == 0 then
			trace("WARNING! No output info found for ",industryName," attempting to use backup instead")
			result[industryName]=backupResult[industryName]
			sourcesCountMap[industryName] = getBackupSourcesMap()[industryName]
			-- Also populate industriesToOutput with backup data
			if backupOutputs[industryName] then
				industriesToOutput[industryName] = backupOutputs[industryName]
			end
			-- Populate capacities with backup data
			if backupCapacities[industryName] and not capacities[industryName] then
				capacities[industryName] = backupCapacities[industryName]
				trace("Using backup capacities for: ", industryName)
			end
			-- Populate productionLevels with backup data
			if backupProductionLevels[industryName] and not productionLevels[industryName] then
				productionLevels[industryName] = backupProductionLevels[industryName]
				trace("Using backup productionLevels for: ", industryName)
			end
			-- Populate baseCapacities with backup data
			if backupBaseCapacities[industryName] and not baseCapacities[industryName] then
				baseCapacities[industryName] = backupBaseCapacities[industryName]
				trace("Using backup baseCapacities for: ", industryName)
			end
			-- Populate ruleSources with backup data
			if backupRuleSources[industryName] and not ruleSources[industryName] then
				ruleSources[industryName] = backupRuleSources[industryName]
				trace("Using backup ruleSources for: ", industryName)
			end
		else 
			result[industryName]={}
			for j, output in pairs(industriesToOutput[industryName]) do 
				local input = inputsToIndustries[output] 
				if not input then 
					trace("WARNING! no input found for ",output," for ",industryName)
					if backupResult[industryName] then 
						result[industryName]=backupResult[industryName]
						sourcesCountMap[industryName] = getBackupSourcesMap()[industryName]
						break 
					end 
				else 
					for k, industry2 in pairs(input) do 
						table.insert(result[industryName], industry2)
					end 
				end 
			end 
		end 
	end
	local outputsToIndustries = {} 
	for fileName, outputs in pairs(industriesToOutput) do 
		for i, output in pairs(outputs) do 
			if not outputsToIndustries[output] then 
				outputsToIndustries[output]={}
			end
			table.insert(outputsToIndustries[output], fileName)
		end
	end 
	
	for cargoType, industries in pairs(inputsToIndustries) do 
		for __, fileName in pairs(industries) do
			if not sourcesCountMap[fileName] then 
				sourcesCountMap[fileName]={}
			end
			if fileName ~= "TOWN" and outputsToIndustries[cargoType] then
				for __ , supplyIndustry in pairs(outputsToIndustries[cargoType]) do
					-- Ensure backup data exists for supply industry
					if not capacities[supplyIndustry] then
						capacities[supplyIndustry] = backupCapacities[supplyIndustry] or {}
					end
					if not productionLevels[supplyIndustry] then
						productionLevels[supplyIndustry] = backupProductionLevels[supplyIndustry] or 1
					end
					-- Get capacity with fallback to 100
					local supplyCapacity = (capacities[supplyIndustry] and capacities[supplyIndustry][cargoType]) or 100
					local supplyProdLevel = productionLevels[supplyIndustry] or 1

					trace("for ",fileName," and cargo ",cargoType," inspecting the supplyIndustry",supplyIndustry," its capacity was ",supplyCapacity)
					local maxSupplyCapacity = supplyCapacity * supplyProdLevel
					-- Ensure backup data exists for consuming industry
					if not ruleSources[fileName] then
						ruleSources[fileName] = backupRuleSources[fileName] or {}
					end
					if not baseCapacities[fileName] then
						baseCapacities[fileName] = backupBaseCapacities[fileName] or 100
					end
					if not productionLevels[fileName] then
						productionLevels[fileName] = backupProductionLevels[fileName] or 1
					end
					local ruleSource = (ruleSources[fileName] and ruleSources[fileName][cargoType]) or 1
					local maxDemand = ruleSource * (baseCapacities[fileName] or 100) * (productionLevels[fileName] or 1)
					local maxSources = math.ceil(maxDemand/maxSupplyCapacity)
					local existingMaxSources = sourcesCountMap[fileName][cargoType]
					trace("The maxSupplyCapacity was",maxSupplyCapacity,"the maxDemand was",maxDemand,"for",supplyIndustry,"cargoType=",cargoType,"maxSources=",maxSources,"existingMaxSources=",existingMaxSources,"for target=",fileName)
					if existingMaxSources and existingMaxSources ~= maxSources then 
						maxSources = math.min(maxSources, existingMaxSources)
						trace("WARNING! existingMaxSources in disagreement with maxSources, taking the min as",maxSources)
					end 
					sourcesCountMap[fileName][cargoType]=maxSources
					sourcesCountMap[fileName][supplyIndustry]=math.ceil(maxDemand/maxSupplyCapacity)
					if maxSupplyCapacity > maxDemand then 
						if not multiSupplyIndustry[supplyIndustry] then 
							multiSupplyIndustry[supplyIndustry] = {}
						end 
						multiSupplyIndustry[supplyIndustry][cargoType]=math.ceil(maxSupplyCapacity/maxDemand)
						trace("Setting ",supplyIndustry, " as a multi supply industry count was ",multiSupplyIndustry[supplyIndustry][cargoType])
					end
				end
			end
		end 
	end 
	local townOutputs = { } 
	for __, cargoTypeName in pairs(allCargoTypes) do 
		trace("checking ",cargoTypeName," was outputToIndustry?",outputsToIndustries[cargoTypeName], " possible town output?",possibleTownOutputs[cargoTypeName] )
		if not outputsToIndustries[cargoTypeName] and possibleTownOutputs[cargoTypeName] or cargoTypeName == "UNSORTED_MAIL" then 
			trace("Setting ",cargoTypeName," as a town output")
			townOutputs[cargoTypeName]=true
			if not result["TOWN"] then 
				result["TOWN"] = {} 
				industriesToOutput["TOWN"]={}
			end
			table.insert(industriesToOutput["TOWN"], cargoTypeName)
			if inputsToIndustries[cargoTypeName] then 
				for i, industry in pairs(inputsToIndustries[cargoTypeName] ) do 
					table.insert(result["TOWN"], industry)
				end 				
			end 
		end 
	end 
	
	if util.tracelog then debugPrint({outputsToIndustries=outputsToIndustries, inputsToIndustries=inputsToIndustries,industriesToOutput=industriesToOutput, ruleSources=ruleSources, capacities=capacities, productionLevels=productionLevels, producerToConsumerMap= result, townOutputs=townOutputs, ruleCapacities=ruleCapacities, hasOrCondition=hasOrCondition}) end
	--for fileName, count in pairs(getBackupSourcesMap()) do 
	--	assert(count==sourcesCountMap[fileName]," expected "..count.." but was "..sourcesCountMap[fileName].." for "..fileName)
	--end
	
	-- leave the assignment to the end, if anything fails it won't leave a half built map, and also thread saftey (maybe?) 
	evaluation.sourcesCountMap = sourcesCountMap
	evaluation.producerToConsumerMap = result
	evaluation.capacities = capacities
	evaluation.productionLevels = productionLevels
	evaluation.industriesToOutput = industriesToOutput
	evaluation.outputsToIndustries = outputsToIndustries
	evaluation.inputsToIndustries = inputsToIndustries
	evaluation.hasOrCondition = hasOrCondition
	evaluation.maxSourcesCount = maxSourcesCount
	evaluation.cargoTypeSet = cargoTypeSet
	evaluation.totalSourcesCount = totalSourcesCount
	evaluation.baseCapacities = baseCapacities
	evaluation.townOutputs = townOutputs
	evaluation.townInputs = townInputs
	evaluation.multiSupplyIndustry = multiSupplyIndustry
	evaluation.ruleSources = ruleSources
	evaluation.placementWeights = placementWeights
	evaluation.ruleCapacities = ruleCapacities 
	evaluation.isRecyclingPlant = isRecyclingPlant
	evaluation.maxConsumption = maxConsumption
	trace("Time taken to discover industry data was",(os.clock()-begin))
end
local function isRecyclingPlant(industry) 
	if not evaluation.isRecyclingPlant then 
		discoverIndustryData()
	end 
	local fileName = getFileNameOfIndustry(industry)
	return evaluation.isRecyclingPlant[fileName]
end 

function evaluation.debugIndustryDataProtected() 
	xpcall(evaluation.debugIndustryData, function(e) 
		print(e) 
		print(debug.traceback) 
	end )
end 
function evaluation.debugTownInputs()
	if not evaluation.townInputs then 
		discoverIndustryData()
	end 
	for output, bool in pairs(evaluation.townInputs) do 
		trace("Output=",output,"isTownInput?",bool)
	end 
	trace("End internal loop")
	local cargoes = api.res.cargoTypeRep.getAll()
	for i, cargoName in pairs(cargoes) do 
		local cargoRep = api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(cargoName))
		debugPrint({cargoName=cargoName, cargoRep=cargoRep})
	end 
end 

function evaluation.debugIndustryData() 
	if not evaluation.capacities then 
		discoverIndustryData()
	end 
	local fileNamesOfTownSuppliers = {}
	for fileName, outputs in pairs(evaluation.capacities) do 
		for output, capacity in pairs(outputs) do
			trace("for filename=",fileName,"got output",output,"capacity=",capacity,"isTownInput?",evaluation.townInputs[output])
			if evaluation.townInputs[output] then 
				table.insert(fileNamesOfTownSuppliers, fileName)
			end 
		end 
	end 
	trace("debugIndustryData: Got ",#fileNamesOfTownSuppliers,"industries")
	
	local requiredInputs = {}
	
	local function filter(fileName)
		local construction = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
		return util.filterYearFromAndTo(construction.availability)
	end 
	
	local function appendRequiredInputs(fileName, outCount)
		local outputCapacity = outCount * evaluation.baseCapacities[fileName] * evaluation.productionLevels[fileName]
		for cargoType, count in pairs(evaluation.ruleSources[fileName]) do 
			trace("Determined that",fileName,"requires",cargoType,"in count",count,"with outputCapacity=",outputCapacity)
			local suppliers = evaluation.outputsToIndustries[cargoType]
			if suppliers then 
				for i, inputFileName in pairs(suppliers) do 
					if filter(inputFileName) then 
						local inputCapacity = outputCapacity * count 
						local maxCapacity = evaluation.baseCapacities[inputFileName] * evaluation.productionLevels[inputFileName]
						local requiredInputCount = inputCapacity / maxCapacity
						trace("For input",inputFileName,"determined the inputCapacity=",inputCapacity,"the maxCapacity=",maxCapacity,"the requiredInputCount=",requiredInputCount)
						
						if not requiredInputs[inputFileName] then 
							requiredInputs[inputFileName]=requiredInputCount
						else 
							requiredInputs[inputFileName]=requiredInputs[inputFileName]+requiredInputCount
						end 
						appendRequiredInputs(inputFileName, requiredInputCount)
					end
				end 
			end
		end 
	end 
	local totalIndustries = 0
	for i, fileName in pairs(fileNamesOfTownSuppliers) do 
		local count = evaluation.placementWeights[fileName] or 1
		totalIndustries = totalIndustries + count
		appendRequiredInputs(fileName, count)
	end 
	debugPrint({requiredInputs=requiredInputs})
	
	for inputFileName, requiredInputCount in pairs(requiredInputs) do 
		totalIndustries = totalIndustries + requiredInputCount
		local suggestedInputCount =  evaluation.placementWeights[inputFileName]
		trace("For",inputFileName,"comparing the requiredInputCount",requiredInputCount,"against the suggestedInputCount",suggestedInputCount,"isMatch?",suggestedInputCount==requiredInputCount)
		
	end 
	trace("Determined total chain requires",totalIndustries)
end
function evaluation.debugIndustryDataProtected2() 
	xpcall(evaluation.debugIndustryData2, function(e) 
		print(e) 
		print(debug.traceback) 
	end )
end 
function evaluation.debugIndustryData2() 
	if not evaluation.capacities then 
		discoverIndustryData()
	end 
	
	 evaluation.townInputs["COMMERCIAL_GOODS"]=true
	  evaluation.townInputs["INDUSTRIAL_GOODS"]=true
	   evaluation.townInputs["MECHANIZED_GOODS"]=true
	    evaluation.townInputs["CARS"]=true
		 evaluation.townInputs["GOODS"]=true
		  evaluation.townInputs["IT_GOODS"]=true
		   evaluation.townInputs["DEVICES"]=true
	 
	 
	
	local fileNamesOfTownSuppliers = {}
	local function filter(fileName)
		if fileName == "industry/recycling_center.con" or fileName == "industry/bioremediation_center.con" then 
			return false
		end 
		local construction = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
		return util.filterYearFromAndTo(construction.availability)
	end 
	for fileName, outputs in pairs(evaluation.capacities) do 
		if filter(fileName) then 
			for output, capacity in pairs(outputs) do
				trace("for filename=",fileName,"got output",output,"capacity=",capacity,"isTownInput?",evaluation.townInputs[output])
				if evaluation.townInputs[output] then 
					table.insert(fileNamesOfTownSuppliers, fileName)
				end 
			end 
		end
	end 
	trace("debugIndustryData2: Got ",#fileNamesOfTownSuppliers,"industries")
	
	local requiredInputs = {}
	local requiredInputCargo = {}

	local byProductCapacity = {}
	
	local function appendRequiredInputs(fileName,   requiredCapacity, outputCargoType )
		--local outputCapacity = outCount * evaluation.capacities[fileName] * evaluation.productionLevels[fileName]
		requiredCapacity = requiredCapacity / evaluation.ruleCapacities[fileName][outputCargoType]
		trace("Adjusted the requiredCapacity to",requiredCapacity)
		for cargoType, count in pairs(evaluation.ruleSources[fileName]) do 
			trace("Determined that",fileName,"requires",cargoType,"in count",count,"with outputCapacity=",requiredCapacity)
			local suppliers = evaluation.outputsToIndustries[cargoType]
			if suppliers then 
				for i, inputFileName in pairs(suppliers) do 
					if filter(inputFileName) then 
					--	local inputCapacity = outputCapacity * count 
						--local maxCapacity = evaluation.capacities[inputFileName][cargoType] * evaluation.productionLevels[inputFileName]
						local requiredInputCount = requiredCapacity * count
						trace("For input",inputFileName,"determined the inputCapacity=",inputCapacity,"the maxCapacity=",maxCapacity,"the requiredInputCount=",requiredInputCount,"for",cargoType)
						
						if byProductCapacity[cargoType] then 
							trace("Reducing the required capacity of",cargoType,"by using byProductCapacity",byProductCapacity[cargoType],"of originally",requiredInputCount)
							if byProductCapacity[cargoType] > requiredInputCount then 
								byProductCapacity[cargoType] = byProductCapacity[cargoType]  - requiredInputCount
								requiredInputCount = 0 
							else 
								requiredInputCount = requiredInputCount - byProductCapacity[cargoType] 
								byProductCapacity[cargoType]=0
							end 
							trace("The new Required inputCount was",requiredInputCount)
						end  
						if requiredInputCount > 0 then 
							local ourRuleCapacity = evaluation.ruleCapacities[inputFileName][cargoType]
							for otherCargo, capacity in pairs(evaluation.ruleCapacities[inputFileName]) do
								if otherCargo~=cargoType then 
									local factor = capacity / ourRuleCapacity
									local byProduct = factor *requiredInputCount
									trace("Adding the otherCargo",otherCargo,"at a ratio",factor,"giving",byProduct)
									if not byProductCapacity[otherCargo] then 
										byProductCapacity[otherCargo]=byProduct
									else 
										byProductCapacity[otherCargo]=byProductCapacity[otherCargo]+byProduct
									end 
								end 
							end 
						end 
						
						
						if not requiredInputCargo[cargoType] then 
							requiredInputCargo[cargoType]= requiredInputCount
						else 
							requiredInputCargo[cargoType]=requiredInputCargo[cargoType]+requiredInputCount
						end 						
						
					--[[	if not requiredInputs[inputFileName] then 
							requiredInputs[inputFileName]=requiredInputCount
						else 
							requiredInputs[inputFileName]=requiredInputs[inputFileName]+requiredInputCount
						end ]]--
						appendRequiredInputs(inputFileName, requiredInputCount, cargoType)
					end
				end 
			end
		end 
	end 

	local totalIndustries = 0
	for i, fileName in pairs(fileNamesOfTownSuppliers) do 
		local count = evaluation.placementWeights[fileName] or 1
		totalIndustries = totalIndustries + count
--		local outputCapacity = count * evaluation.baseCapacities[fileName] * evaluation.productionLevels[fileName]
		for cargoType, capacity in pairs(evaluation.capacities[fileName]) do
			local outputCapacity = count * capacity * evaluation.productionLevels[fileName]
			trace("Outerloop, appending the outputCapacity for ",fileName,"at",outputCapacity,"based on count of ",count)
			appendRequiredInputs(fileName, outputCapacity, cargoType)
		end
	end 
	--[[for cargoType, amount in pairs(byProductCapacity) do
		trace("Adding the byProductCapacity of ",cargoType,amount)
		if not requiredInputCargo[cargoType] then 
			requiredInputCargo[cargoType]= amount
		else 
			requiredInputCargo[cargoType]=requiredInputCargo[cargoType]+amount
		end 
	end ]]--
	
	for cargoType, requiredCapacity in pairs(requiredInputCargo) do 
		for i, fileName in pairs(evaluation.outputsToIndustries[cargoType]) do 
			if filter(fileName) then 
				local maxProduction = evaluation.capacities[fileName][cargoType]*evaluation.productionLevels[fileName]
				local requiredCount = math.ceil(requiredCapacity/maxProduction)
				trace("The maxProduction of ",cargoType,"was",maxProduction,"for",fileName,"compared to",requiredCapacity,"giving a required count of",requiredCount)
				if not requiredInputs[fileName] then 
					requiredInputs[fileName] = requiredCount
				else 
					requiredInputs[fileName] = math.max(requiredInputs[fileName] ,requiredCount)
				end 
			
			end 
		end 
	end 
	
	debugPrint({requiredInputs=requiredInputs, requiredInputCargo=requiredInputCargo})
	for inputFileName, requiredInputCount in pairs(requiredInputs) do 
		local constructionRep = api.res.constructionRep.get(api.res.constructionRep.find(inputFileName))
		local readableName = _(constructionRep.description.name)
		trace(readableName,"=",requiredInputCount)
	end 
	for inputFileName, requiredInputCount in pairs(requiredInputs) do 
		totalIndustries = totalIndustries + requiredInputCount
		local suggestedInputCount =  evaluation.placementWeights[inputFileName]
		local isMatch = suggestedInputCount==requiredInputCount
		if not isMatch then 
			trace("For",inputFileName,"comparing the requiredInputCount",requiredInputCount,"against the suggestedInputCount",suggestedInputCount,"isMatch?",isMatch)
		end
	end 
	--package.loaded["ai_builder_new_connections_evaluation"]=nil
	--eval = require "ai_builder_new_connections_evaluation"
	--eval.debugIndustryDataProtected2()
	trace("Determined total chain requires",totalIndustries)
end
	 
local function getProducerToConsumerMap() 
	if not  evaluation.producerToConsumerMap then
		trace("No producerToConsumerMap, discovering industry data")
		discoverIndustryData()
	end
	return evaluation.producerToConsumerMap
end
local function getSourcesCountMap() 
	if not evaluation.sourcesCountMap then
		trace("No sourcesCountMap, discovering industry data")
		discoverIndustryData()
	end
	return  evaluation.sourcesCountMap 
end
local function getTown2BuildingMap() 
	if  evaluation.town2BuildingMap then 
		return evaluation.town2BuildingMap 
	end 
	trace("Caching the raw town2BuildingMap")
	evaluation.town2BuildingMap =  util.deepClone(api.engine.system.townBuildingSystem.getTown2BuildingMap()) 
	
	return 	evaluation.town2BuildingMap
end
local function setupCaches() 
	evaluation.town2BuildingMap =  util.deepClone(api.engine.system.townBuildingSystem.getTown2BuildingMap()) -- this map seems to cause trouble, caching a copy to try and help
	util.lazyCacheNode2SegMaps()
end 
local function clearCaches() 
	evaluation.town2BuildingMap =  nil
	util.clearCacheNode2SegMaps()
end 
local function scoreTownSizes(town1, town2) 
	local score = 0 
	for __ , townId in pairs({town1, town2}) do 
		local town = util.getComponent(townId, api.type.ComponentType.TOWN )
		if town then -- in case we pick industry
			for ___, capacity in pairs(town.initialLandUseCapacities) do
				score = score + town.sizeFactor * capacity
			end
		end 
	end
	return score
end
 
local function isFarm(industry) 
	return getFileNameOfIndustry(industry) == "industry/farm.con"
end

local function getConstructionId(industryId) 
	if not evaluation.industry2ConstructionIdMap or not evaluation.industry2ConstructionIdMap[industryId] then
		local industry2ConstructionIdMap = {} 
		for i, industryId in pairs(getAllIndustries()) do 
			industry2ConstructionIdMap[industryId]=api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industryId) 
		end
		evaluation.industry2ConstructionIdMap = industry2ConstructionIdMap -- rudimentry attempt at thread safety
	end
	return evaluation.industry2ConstructionIdMap[industryId] or api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industryId) 
end

local function getTownCargoTypes() 
	if not evaluation.townCargoTypes then 
		local townCargoTypes = {} 
		for __ , cargoTypeName in pairs(util.deepClone(api.res.cargoTypeRep.getAll())) do 
			local i =api.res.cargoTypeRep.find(cargoTypeName)
			local cargoTypeRep = api.res.cargoTypeRep.get(i)
			if #cargoTypeRep.townInput > 0 then 
				table.insert(townCargoTypes, i)
			end 
		end 	
		evaluation.townCargoTypes = townCargoTypes
	end 
	return evaluation.townCargoTypes 
end 

local function getOutboundCargoTypeIdx(industry) 
	if not evaluation.discoveredCargoTypes then 
		evaluation.discoveredCargoTypes = {}
	end
	local cargoType = evaluation.discoveredCargoTypes[industry.id]
	if cargoType then
		return cargoType
	end
	local cargoTypName = util.discoverCargoType(industry)
	if cargoTypName then -- only discovered once production begins
		cargoType = api.res.cargoTypeRep.find(cargoTypName)
		evaluation.discoveredCargoTypes[industry.id]=cargoType
	end
	return cargoType
end

local function getSources(industryId, cargoType)
	local constructionId = getConstructionId(industryId)
	if evaluation.cargoSourceMap then
		trace("using cached sourceCargo map")
		local sourcesForCargo = evaluation.cargoSourceMap[cargoType+1]
		if not sourcesForCargo then
			trace("No sourcesForCargo for cargoType", cargoType)
			return {}
		end
		if sourcesForCargo[constructionId] then	
			local result = {}
			for source, amount in pairs (sourcesForCargo[constructionId]) do
				table.insert(result,  source)
			end
			return result
		else
			trace("No soources for ", constructionId)
			return {}
		end
	
	end
	return api.engine.system.stockListSystem.getSources(constructionId)
end

local function countSourcesOfSameType(industry1, industry2, cargo)
	local cargoType = api.res.cargoTypeRep.find(cargo)
	local existingSources  = getSources(industry2.id, cargoType) 
	local fileName = getFileNameOfIndustry(industry1)
	local countExistingSourcesOfSameType = 0
	for i, source in pairs(existingSources) do 
		local theirFileName = util.getConstruction(source).fileName
		trace("Their filename for source was ",theirFileName)
		--if fileName == theirFileName then
			countExistingSourcesOfSameType = countExistingSourcesOfSameType + 1
		--end
	end
	trace("found ",countExistingSourcesOfSameType, " existing sources for ",fileName, " of a total of ",util.size(existingSources), " for cargotype",cargoType)
	return countExistingSourcesOfSameType
end

local function isTownSupplier(industry)
	local fileName = getFileNameOfIndustry(industry)
	local matchingTargets = getProducerToConsumerMap()[fileName]
	return util.contains(matchingTargets, "TOWN") 
end 


local function estimateInitialTargetLineRateCargo(industry1, industry2, cargo)
	if industry1.type == "TOWN" then 
		return 25 -- not possible to determine without the stocklist
	end 
	if industry2.type == "TOWN" then 
		if evaluation.townRateEstimateCache and evaluation.townRateEstimateCache[industry2.id] and evaluation.townRateEstimateCache[industry2.id][cargo] then 
			trace("Using cached result")
			return evaluation.townRateEstimateCache[industry2.id][cargo]
		end		
		local begin = os.clock()
		local townComp = util.getComponent(industry2.id, api.type.ComponentType.TOWN)
		--local cargo = util.discoverCargoType(industry1)
		--local cargoType = api.res.cargoTypeRep.find(cargo)
		--local landType = landType
		local capacity = 0
		local cargoSupplyAndLimit = game.interface.getTownCargoSupplyAndLimit(industry2.id) 
		
		local existingSources  =0 
		if cargoSupplyAndLimit[cargo] then 
			capacity = math.max(cargoSupplyAndLimit[cargo][2]-cargoSupplyAndLimit[cargo][1],0)
			existingSources = cargoSupplyAndLimit[cargo][1]
		else 
			for i, townBuildingId in pairs(getTown2BuildingMap()[industry2.id]) do
				local townBuilding = util.getComponent(townBuildingId, api.type.ComponentType.TOWN_BUILDING)
				if townBuilding.stockList ~= -1 then 
					local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(townBuildingId) 
					local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
					if util.contains(construction.params.cargoTypes, cargo) then 
						--capacity = capacity + construction.params.capacity
						capacity = capacity + 1
					end
				end
			end
		end
		if not evaluation.capacities then
			trace("No capacities, discovering industry data")
			discoverIndustryData()
		end
		local industryFileName = getFileNameOfIndustry(industry1)
		local industryCapacity = evaluation.capacities[industryFileName]
		if industryCapacity and industryCapacity[cargo] then
			capacity = math.min(capacity, industryCapacity[cargo])
		end
		if evaluation.townRateEstimateCache then 
			if not evaluation.townRateEstimateCache[industry2.id] then 
				evaluation.townRateEstimateCache[industry2.id] = {}
			end
			evaluation.townRateEstimateCache[industry2.id][cargo]=capacity
		end 
		trace("Estimated town capacity for ", industry2.name," ",cargo," to be", capacity," for ", industry1.name," time taken:",(os.clock()-begin))
		return capacity, capacity, existingSources
	else 
	 
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry2.id) 
		 
		if not evaluation.capacities then 
			trace("No capacities, discovering industry data")
			discoverIndustryData()
		end
		local fileName1 = getFileNameOfIndustry(industry1)
		local fileName2 = getFileNameOfIndustry(industry2)
		local initialCapacity = evaluation.baseCapacities[fileName2]
	--	local sourcesCount = getSourcesCountMap()[fileName2][cargo]
		local sourcesCount = getSourcesCountMap()[fileName2][fileName1]
		local existingSources = countSourcesOfSameType(industry1, industry2, cargo)
		local sourceDifference = sourcesCount - existingSources
		local result = initialCapacity * sourceDifference
		local cap1 = (evaluation.capacities[fileName1] and evaluation.capacities[fileName1][cargo]) or 100
		result = math.min(result, cap1)
		local maxLineRate = cap1 * (evaluation.productionLevels[fileName1] or 1)
		trace("Calculated initial capcity for ",industry1.name, " as ",result," maxLineRate=",maxLineRate)
		return result , maxLineRate, existingSources
	end

end

local function createCargoDestsMap()
	local begin = os.clock()
	local cargoDestsMap = {}
	for k, v in pairs(evaluation.cargoSourceMap) do 
		cargoDestsMap[k]={}
		for dest, sourceAndCount in pairs(v) do 
			for source, count in pairs(sourceAndCount) do 
				if not cargoDestsMap[k][source] then
					cargoDestsMap[k][source]={}
				end 
				if not cargoDestsMap[k][source][dest] then 
					cargoDestsMap[k][source][dest] = count
				else 
					cargoDestsMap[k][source][dest]= count + cargoDestsMap[k][source][dest]
				end
			end
		end
	end 
	trace("Cargo dests map created in ",(os.clock()-begin))
	evaluation.cargoDestsMap = cargoDestsMap
end 

local function createTownSupplySourceMap() 
	local begin = os.clock()
	 
	local result = {}
	--local townCargoTypes = getTownCargoTypes()
	local cargoByTown = {} 
	local cargoCount = {}
	api.engine.forEachEntityWithComponent(function(townId)
		cargoByTown[townId]={}
		local townsByCargoAndLimit = game.interface.getTownCargoSupplyAndLimit(townId)
		for cargo, supplyAndLimit in pairs(townsByCargoAndLimit) do 
			local cargoIdx = api.res.cargoTypeRep.find(cargo)
			table.insert(cargoByTown[townId], cargoIdx)
			if not cargoCount[cargoIdx] then 
				cargoCount[cargoIdx]=1
			else 
				cargoCount[cargoIdx]=1+cargoCount[cargoIdx]
			end 
		end 
	end, api.type.ComponentType.TOWN)
	--if util.tracelog then debugPrint({cargoByTown=cargoByTown}) end
	local countExistingSupply = {}
	for townId, buildings in pairs(getTown2BuildingMap()) do 
		local alreadySeen = {}
		result[townId]={}
		for __, buildingId in pairs(buildings) do 
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(buildingId)
			for __ , cargoType in pairs(cargoByTown[townId]) do
				local sources = evaluation.cargoSourceMap[cargoType+1][constructionId]
				if sources then   
					result[townId][cargoType]=true
					for sourceId, amount in pairs(sources) do 
						if not alreadySeen[sourceId] then 
							alreadySeen[sourceId]=true 
							result[townId][sourceId]=true
							
							if not countExistingSupply[sourceId] then 
								countExistingSupply[sourceId]=1 
							else 
								countExistingSupply[sourceId]=1 + countExistingSupply[sourceId]
							end 
						end 
					end
				end
			end
		end 
		--if util.tracelog then debugPrint({townId=townId, townResult=result[townId]}) end
	end 
	local countOfIndustriesByCargo = {}
	for i, industry in pairs(getAllIndustries()) do 
		for j , cargo in pairs(evaluation.industriesToOutput[getFileNameOfIndustry(industry)]) do 
			local cargoIdx = api.res.cargoTypeRep.find(cargo)
			if not countOfIndustriesByCargo[cargoIdx] then 
				countOfIndustriesByCargo[cargoIdx]=1
			else 	
				countOfIndustriesByCargo[cargoIdx]=countOfIndustriesByCargo[cargoIdx]+1
			end 
		end 
	end 
	
	local cargoCountRatios = {}
	for cargoIdx, count in pairs(cargoCount) do 
		local industryCount = countOfIndustriesByCargo[cargoIdx] or 1 
		cargoCountRatios[cargoIdx] = math.ceil(count / industryCount)
	end 
	
	--if util.tracelog then debugPrint({townSupplySourceMap=result, cargoCountRatios=cargoCountRatios, countExistingSupply=countExistingSupply}) end
	evaluation.townSupplySourceMap = result
	evaluation.cargoCount = cargoCount 
	evaluation.cargoCountRatios = cargoCountRatios 
	evaluation.countExistingSupply = countExistingSupply
	trace("Cargo town supply map created in ",(os.clock()-begin))
end

local function townIsShippingProduct(town, cargo) 
	local cargoDetail = api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(cargo))
	local cargoTypeName = _(cargoDetail.name)
	local nearbyStations = util.searchForEntities(town.position, 350, "STATION" )
	for i , station in pairs(nearbyStations) do 
		trace("townIsShippingProduct: Inspecting station ",station.id)
		for j, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station.id))) do 
			local cargoType = evaluation.lineManager.discoverLineCargoType(lineId)
			local lineName = util.getName(lineId)
			local foundCargo = string.find(lineName, cargoTypeName)
			trace("For line ",lineId,"lineName=",lineName," comparing the discovered cargoType",cargoType," to the test cargo type",cargo, "foundCargo?",foundCargo)
			if cargoType == cargo or api.res.cargoTypeRep.find(cargo) == cargoType or foundCargo then 
				trace("townIsShippingProduct: Discovered a line already with that cargo, aborting")
				return true
			end 
		end 
	end 
	trace("townIsShippingProduct Town",town.name,"is NOT shipping",cargo)
	return false 
end 


local function industryIsShippingAllProducts(industry)
	local dbg2 = io.open('/tmp/tf2_isap.txt', 'a')
	dbg2:write('ISAP start for ' .. tostring(industry.id) .. '\n')
	local fileName = getFileNameOfIndustry(industry)
	dbg2:write('ISAP fileName=' .. tostring(fileName) .. '\n')
	local multiSupplyIndustry = evaluation.multiSupplyIndustry[fileName]
	local constructionId = getConstructionId(industry.id)
	dbg2:write('ISAP constructionId=' .. tostring(constructionId) .. '\n')

	-- Check if industriesToOutput has data for this fileName
	if not evaluation.industriesToOutput[fileName] then
		dbg2:write('ISAP no industriesToOutput for fileName, returning false\n')
		dbg2:close()
		return false
	end

	if util.size(evaluation.industriesToOutput[fileName]) == 1 then
		dbg2:write('ISAP single output case\n')
		local maxLevel = evaluation.productionLevels[fileName] or 1
		local simBuilding = util.getComponent(industry.id, api.type.ComponentType.SIM_BUILDING)
		if not simBuilding then
			dbg2:write('ISAP no simBuilding, returning false\n')
			dbg2:close()
			return false
		end
		local currentLevel = (simBuilding.level or 0) + 1 -- zero based 
		trace("industryIsShippingAllProducts? inspecting single cargo industry for",fileName,"comparing maxLevel",maxLevel,"to",currentLevel,"for",industry.name,industry.id)
		local itemsShipped = game.interface.getIndustryShipping(constructionId)
		if maxLevel == currentLevel then 
			local productionLimit = game.interface.getIndustryProductionLimit(constructionId)
		
			trace("Inspecting industry",industry.name,"productionLimit=",productionLimit,"itemsShipped=",itemsShipped)
			if itemsShipped == productionLimit then 
				trace("industryIsShippingAllProducts?", industry.name,"determined true")
				return true 
			end 
		end 
		local cargoType = nil
		if evaluation.capacities[fileName] then
			cargoType = util.getFirstKey(evaluation.capacities[fileName])
		end
		if not cargoType and evaluation.industriesToOutput[fileName] then
			cargoType = evaluation.industriesToOutput[fileName][1]
		end
		if not cargoType then
			trace("industryIsShippingAllProducts: No cargo type found for", fileName, "- skipping")
			return false
		end
		dbg2:write('ISAP itemsShipped=' .. tostring(itemsShipped) .. '\n')
		if itemsShipped > 0 then
			dbg2:write('ISAP itemsShipped > 0 branch\n')
			local capacity = (evaluation.capacities[fileName] and evaluation.capacities[fileName][cargoType]) or 100
			local baseCapacity = evaluation.baseCapacities[fileName] or 100
			local industryMaxProduction = capacity * baseCapacity * maxLevel
			trace("Calculated industryMaxProduction for",fileName,"as",industryMaxProduction)
			dbg2:write('ISAP creating cargoDestsMap\n')
			if not evaluation.cargoDestsMap then
				createCargoDestsMap()
			end
			dbg2:write('ISAP cargoDestsMap created\n')
			local cargoIdx = api.res.cargoTypeRep.find(cargoType)
			dbg2:write('ISAP cargoIdx=' .. tostring(cargoIdx) .. '\n')
			-- Add nil check for cargoDestsMap access
			if not evaluation.cargoDestsMap[cargoIdx+1] then
				dbg2:write('ISAP no cargoDestsMap for cargoIdx, returning false\n')
				dbg2:close()
				return false
			end
			local destinations = evaluation.cargoDestsMap[cargoIdx+1][constructionId] or {}
			local totalDests = util.size(destinations)
			trace("Found totalDests=",totalDests,"for",industry.name,industry.id)
			local maxTotalConsumption = 0 
			for dest, count in pairs(destinations) do 
				--trace("Found industry supplying to",dest,"with count",count)
				local construction = util.getConstruction(dest)
				if construction.simBuildings[1] then
					local fileName2 = getFileNameOfIndustry(construction.simBuildings[1])
					local consumption = 0
					if evaluation.maxConsumption[fileName2] and evaluation.maxConsumption[fileName2][cargoType] then
						consumption = evaluation.maxConsumption[fileName2][cargoType]
					else
						consumption = 100 -- default fallback
					end
					maxTotalConsumption = maxTotalConsumption + consumption
				else
					--trace("No simBuilding attached to construction")
				end				
			end 
			local isAtMaxPossibleConsumption = maxTotalConsumption >= industryMaxProduction 
			trace("Comparing the maxTotalConsumption:",maxTotalConsumption,"for",industry.name,"against its max production of",industryMaxProduction,"isAtMaxPossibleConsumption?",isAtMaxPossibleConsumption)
			if isAtMaxPossibleConsumption then 
				return true 
			end 
		else
			dbg2:write('ISAP else branch - no shipment\n')
			-- no shipment but a line is present, in this case hold off from creating another
			local function filterToCatchmentArea(station)
				return util.checkIfStationInCatchmentArea(station.id, getConstructionId(industry.id))
			end
			dbg2:write('ISAP getting cargoDetail for cargoType=' .. tostring(cargoType) .. '\n')
			local cargoIdx = api.res.cargoTypeRep.find(cargoType)
			dbg2:write('ISAP cargoIdx=' .. tostring(cargoIdx) .. '\n')
			if cargoIdx < 0 then
				dbg2:write('ISAP invalid cargoIdx, returning false\n')
				dbg2:close()
				return false
			end
			local cargoDetail = api.res.cargoTypeRep.get(cargoIdx)
			local cargoTypeName = _(cargoDetail.name)
			local nearbyStations = util.searchForEntitiesWithFilter(industry.position, 350, "STATION", filterToCatchmentArea)
			for i , station in pairs(nearbyStations) do 
				trace("industryIsShippingAllProducts: Inspecting station ",station.id)
				for j, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station.id))) do 
					local cargo = evaluation.lineManager.discoverLineCargoType(lineId)
					local lineName = util.getName(lineId)
					--local foundCargo = string.find(lineName, cargoTypeName)
					trace("For line ",lineId,"lineName=",lineName," comparing the discovered cargoType",cargoType," to the test cargo type",cargo)
					if cargoType == cargo or api.res.cargoTypeRep.find(cargoType) == cargo  then 
						trace("industryIsShippingAllProducts: Discovered a line already with that cargo, aborting")
						return true
					end 
				end 
			end 
		end 		
	end 
	
	
		--if true then return false end
	for cargo, production in pairs(industry.itemsProduced) do
		if string.sub(cargo,1,1) == "_" then -- we have _sum, _lastMonth, _lastYear
			goto continue
		end 	
		if not evaluation.cargoDestsMap then 
			createCargoDestsMap() 
		end 
		local cargoIdx = evaluation.cargoTypeSet[cargo]
		local destsByCargo = evaluation.cargoDestsMap[1+cargoIdx]
		if not destsByCargo then 
			--debugPrint({cargo=cargo,cargoIdx=cargoIdx,cargoDestsMap=evaluation.cargoDestsMap})
		end
		local dests = destsByCargo[constructionId]
		if not industry.itemsShipped[cargo] or not dests then 
			trace("Industry is not shipping",cargo," industry.id=",industry.id,industry.name,"dests=",dests)
			local nearbyStations = util.searchForEntities(industry.position, 350, "STATION" )
			for i , station in pairs(nearbyStations) do 
				trace("industryIsShippingAllProducts: Inspecting station ",station.id)
				for j, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station.id))) do 
					local cargoType = evaluation.lineManager.discoverLineCargoType(lineId)
					trace("For line ",lineId," comparing the discovered cargoType",cargoType," to the test cargo type",cargo)
					if cargoType == cargo or api.res.cargoTypeRep.find(cargo) == cargoType then 
						trace("industryIsShippingAllProducts: Discovered a line already with that cargo, aborting")
						return true
					end 
				end 
			end 
			
			return false 
		elseif multiSupplyIndustry and evaluation.cargoTypeSet[cargo] and multiSupplyIndustry[cargo] then  

			if dests then 
				local destsCount = util.size(dests) 
				local maxCount = multiSupplyIndustry[cargo]
				trace("Comparing the destsCount", destsCount, " to the max count",maxCount)
				if destsCount < maxCount then 
					return false 
				end 
			else 
				--debugPrint({destsByCargo=destsByCargo, constructionId=constructionId})
			end
			
		end
		::continue::
	end 
	
	  
	return true

end

local function findMatchingIndustries(circle,includeTowns, filterFn, maxDist, circle2, includeSourceTowns, param)
	local dbg = io.open('/tmp/tf2_find_match.txt', 'w')
	dbg:write('START findMatchingIndustries\n')
	local begin = os.clock()
	profiler.beginFunction("findMatchingIndustries")
	dbg:write('FMI-1: checking townOutputs\n')
	if not evaluation.townOutputs then
		dbg:write('FMI-1a: calling discoverIndustryData\n')
		discoverIndustryData()
		dbg:write('FMI-1a: done\n')
	end
	if not filterFn then filterFn = function() return true end end
	local alreadySeen ={}
	local industryPairs = {}
	dbg:write('FMI-2: getCargoType2stockList2sourceAndCount\n')
	evaluation.cargoSourceMap = util.deepClone(api.engine.system.stockListSystem.getCargoType2stockList2sourceAndCount())
	dbg:write('FMI-2: done\n')
	dbg:write('FMI-3: getGameTime\n')
	local gameTime = game.interface.getGameTime().time
	dbg:write('FMI-3: done, gameTime=' .. tostring(gameTime) .. '\n')
	local minInterval = 1200
	local allIndustries
	local allIndustries2
	dbg:write('FMI-4: checking preSelectedPair\n')
	if param and param.preSelectedPair then
		dbg:write('FMI-4a: using preSelectedPair\n')
		allIndustries = {
			[param.preSelectedPair[1]] = util.getEntity(param.preSelectedPair[1])
		}
		local entity2 = util.getEntity(param.preSelectedPair[2])
		if entity2.type == "TOWN" then
			allIndustries2 = {} -- handled by the allTowns loop below
		else
			allIndustries2 = {
				[param.preSelectedPair[2]] = entity2
			}
		end
		dbg:write('FMI-4a: done\n')
	else
		dbg:write('FMI-4b: calling getEntities\n')
		allIndustries = util.deepClone(game.interface.getEntities(circle, {type="SIM_BUILDING", includeData=true}))
		dbg:write('FMI-4b: done, #allIndustries=' .. tostring(util.size(allIndustries)) .. '\n')
		
		if evaluation.isAutoBuildMode then 
			
			
			local allIndustriesOld = allIndustries 
			allIndustries = {}
			for industryId, industry in pairs(allIndustriesOld) do 
				if not evaluation.locationsInCoolDown[industryId] or gameTime-evaluation.locationsInCoolDown[industryId] > minInterval then 
					allIndustries[industryId] = industry
				else 
					trace("Excluding industry",industry.name, " as it is within the cooldown period")
				end
			end 
		end 
		dbg:write('FMI-5: setting allIndustries2\n')
		allIndustries2 = allIndustries
		if circle2 and circle2.radius~= circle.radius then
			dbg:write('FMI-5a: circle2 case\n')
			allIndustries2= util.deepClone(game.interface.getEntities(circle2, {type="SIM_BUILDING", includeData=true}))
		elseif includeSourceTowns and util.size(evaluation.townOutputs)>0 then
			dbg:write('FMI-5b: includeSourceTowns case\n')
			allIndustries2 = util.deepClone(allIndustries)

		end
		dbg:write('FMI-6: checking includeSourceTowns for towns\n')
		if includeSourceTowns and util.size(evaluation.townOutputs)>0 then
			dbg:write('FMI-6a: iterating towns\n')
			for townId, town in pairs(util.deepClone(game.interface.getEntities(circle, {type="TOWN", includeData=true}))) do 
				if evaluation.isAutoBuildMode then 
					if not evaluation.locationsInCoolDown[townId] or gameTime-evaluation.locationsInCoolDown[townId] > minInterval then 
						allIndustries[townId]=town
					else 
						trace("Excluding town",town.name, " as it is within the cooldown period")
					end
				else 
					allIndustries[townId]=town
				end
			end
		end
	end
	dbg:write('FMI-7: outside else block\n')

	local allTowns
	local townCargoLookup
	dbg:write('FMI-8: checking includeTowns\n')
	if includeTowns then
		dbg:write('FMI-8a: setting up townCargoLookup\n')
		townCargoLookup = {}
		evaluation.townRateEstimateCache = {}
		dbg:write('FMI-8b: getting towns\n')
		allTowns = util.deepClone(game.interface.getEntities(circle2 and circle2 or circle, {type="TOWN", includeData=true}))
		dbg:write('FMI-8b: done, #allTowns=' .. tostring(util.size(allTowns)) .. '\n')
		for townId, town in pairs(allTowns) do
			dbg:write('FMI-9: processing town ' .. tostring(townId) .. '\n')
			townCargoLookup[townId]={}
			dbg:write('FMI-9a: getComponent\n')
			local townComp = util.getComponent(townId, api.type.ComponentType.TOWN)
			dbg:write('FMI-9b: getTownCargoSupplyAndLimit\n')
			local cargoSupplyAndLimit = game.interface.getTownCargoSupplyAndLimit(townId)
			dbg:write('FMI-9c: iterating cargo\n')
			for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do 
				if  cargoSupplyAndLimit[cargoName][2]-cargoSupplyAndLimit[cargoName][1] > 0 then 
					townCargoLookup[townId][cargoName] = true
					if not evaluation.townInputs[cargoName] then 
						trace("The cargo type was",cargoName," was not found in the town inputs, attempting to correct")
						evaluation.townInputs[cargoName] = true 
						if evaluation.outputsToIndustries[cargoName] then
							for __ , industry in pairs(evaluation.outputsToIndustries[cargoName]) do
								trace("Adding the industry",industry," as a town supplier")
								table.insert(evaluation.producerToConsumerMap[industry],"TOWN")
							end 
						end
					end
				end
			end 
			-- TODO needs to figure out how the new town demand system works, it seems to be always available on the town comp
			--[[for __, landUseType in pairs({api.type.enum.LandUseType.COMMERCIAL, api.type.enum.LandUseType.INDUSTRIAL}) do
				local allCargoNeeds = townComp.cargoNeeds[landUseType+1]
				if allCargoNeeds then 
					for i = 1, #allCargoNeeds do 
						local cargoNeeds = allCargoNeeds[i]
						local cargoName = api.res.cargoTypeRep.getName(cargoNeeds)
						if cargoSupplyAndLimit[cargoName] and cargoSupplyAndLimit[cargoName][2]-cargoSupplyAndLimit[cargoName][1] > 0 then 
							townCargoLookup[townId][cargoName]=cargoNeeds						
						end
					end
				elseif util.tracelog then 
							trace("Cargo needs not found")
							debugPrint(townComp)
				end
			end ]]-- 
			
		end
	end
	dbg:write('FMI-10: starting industry loop\n')

	for industryId, industry in pairs(allIndustries) do
		dbg:write('FMI-11: industry ' .. tostring(industryId) .. ' type=' .. tostring(industry.type) .. '\n')
		local fileName = industry.type=="TOWN" and "TOWN" or getFileNameOfIndustry(industryId)
		dbg:write('FMI-11a: fileName=' .. tostring(fileName) .. '\n')
		dbg:write('FMI-11b: getProducerToConsumerMap\n')
		trace("Outer industry loop inspecting",industryId," with name ",industry.name, " filename=",fileName)
		local matchingTargets =  getProducerToConsumerMap()[fileName]
		dbg:write('FMI-11c: matchingTargets=' .. tostring(matchingTargets) .. '\n')
		if not matchingTargets then
			trace("The type ",fileName," is not recognised, skipping")
			goto continue2
		end
		dbg:write('FMI-11d: checking production\n')
		local itemsProd = industry.itemsProduced and industry.itemsProduced._sum or 0
		dbg:write('FMI-11e: itemsProduced._sum=' .. tostring(itemsProd) .. '\n')
		-- CLAUDE CONTROL: Skip production check if preSelectedPair is set (explicit route selection)
		local bypassProductionCheck = param and param.preSelectedPair
		local skipProduction = not bypassProductionCheck and fileName~="TOWN" and itemsProd == 0
		dbg:write('FMI-11f: skipProduction=' .. tostring(skipProduction) .. ' bypassProductionCheck=' .. tostring(bypassProductionCheck) .. '\n')
		local isShippingAll = false
		if not skipProduction and fileName~="TOWN" then
			dbg:write('FMI-11g: calling industryIsShippingAllProducts\n')
			isShippingAll = not bypassProductionCheck and industryIsShippingAllProducts(industry) and not util.contains(matchingTargets, "TOWN")
			dbg:write('FMI-11h: isShippingAll=' .. tostring(isShippingAll) .. '\n')
		end
		if skipProduction or isShippingAll   -- already connected
		then
			trace("Skipping ",industry.name," as is shipping already or no production",industry.itemsProduced._sum)
			 goto continue2
		end
		--trace("inspecting ",industry.name) 
		
		if util.contains(matchingTargets, "TOWN") then
			local begin = os.clock()
			if includeTowns then
				local constructionId = getConstructionId(industryId)
				for townId, town in pairs(allTowns) do
		
					local cargo = evaluation.industriesToOutput[fileName] and evaluation.industriesToOutput[fileName][1] or getBackupConsumerToProducerMap()[fileName][2]
					local cargoIdx = evaluation.cargoTypeSet[cargo]
					 
					local isMatch = townCargoLookup[townId][cargo]
					-- CLAUDE CONTROL: Force match when preSelectedPair is set and this is the target town
					if param and param.preSelectedPair and townId == param.preSelectedPair[2] then
						if not isMatch then
							-- WARNING: Forcing delivery to town that doesn't have natural demand
							-- Claude should use query_town_demands to select correct targets!
							print("[FMI_WARN] Town " .. tostring(townId) .. " has NO natural demand for " .. tostring(cargo) .. " but forcing match (preSelectedPair)")
							print("[FMI_WARN] Consider using query_town_demands to find towns with actual demand!")
						else
							print("[FMI_TRACE] Town " .. tostring(townId) .. " cargo=" .. tostring(cargo) .. " has demand, match confirmed (preSelectedPair)")
						end
						isMatch = true
					else
						print("[FMI_TRACE] Town " .. tostring(townId) .. " cargo=" .. tostring(cargo) .. " isMatch=" .. tostring(isMatch))
					end
					-- CLAUDE CONTROL: Skip autoBuildMode checks when preSelectedPair is set for this town
					local bypassAutoChecks = param and param.preSelectedPair and townId == param.preSelectedPair[2]
					if evaluation.isAutoBuildMode and not bypassAutoChecks then
						if not evaluation.townSupplySourceMap then
							createTownSupplySourceMap()
						end

						--trace("Checking town",townId," if already supplied for the cargo", cargo, " idx=",cargoIdx)
						--debugPrint({Sources=evaluation.townSupplySourceMap[townId]})
						if not evaluation.townSupplySourceMap[townId] then
							trace("ERROR! no town supply source found for ",townId)
							debugPrint({townSupplySourceMap=evaluation.townSupplySourceMap})
							isMatch = false
						elseif evaluation.townSupplySourceMap[townId][cargoIdx] then
							--trace("Skipping town as it is already supplied for the cargo")
							isMatch = false
						end
						if cargo=="MAIL" then
							trace("Suppressing mail for town",townId)
							isMatch = false
						end
					end
					if isMatch and industry.itemsShipped._sum > 0   then 
						--trace("Industry ",industry.name, " is already shipping, checkgin cargodests for cargo=",cargo, " constructionId=",constructionId, " against town ",townId)
					--	if not evaluation.cargoDestsMap then 
					--		createCargoDestsMap() 
					--	end 
						if not evaluation.townSupplySourceMap then 
							createTownSupplySourceMap() 
						end
						if evaluation.townSupplySourceMap[townId][constructionId] then 
							isMatch = false 
						end
						
						if evaluation.isAutoBuildMode then 
							local maxSupply = evaluation.cargoCountRatios[cargoIdx]
							local constructionId =  api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
							local currentSupply = evaluation.countExistingSupply[constructionId] or 0 
							trace("Comparing the maxSupply", maxSupply," of currentSupply",currentSupply)
							if currentSupply >= maxSupply then 
								trace("aborting match") 
								isMatch = false
							end 
						end 
						
						
						
					--[[	local cargoDests = evaluation.cargoDestsMap[cargoType+1][getConstructionId(industryId)]
						if cargoDests then 
							trace("Checking cargodests for ",industry.name)
							for dest, rate in pairs(cargoDests) do 
								local construction = util.getConstruction(dest) 
								if construction.townBuildings[1] then 
									local townBuilding = util.getComponent(construction.townBuildings[1], api.type.ComponentType.TOWN_BUILDING)
									if townBuilding.town == townId then 
										isMatch = false 
										break 
									end
								end
							end 
						else 
							if util.tracelog then debugPrint({cargoSourceMap=evaluation.cargoSourceMap, cargoDestsMap=evaluation.cargoDestsMap}) end
						end]]--
					end
					if evaluation.isAutoBuildMode then 
						if not evaluation.locationsInCoolDown[townId] or gameTime-evaluation.locationsInCoolDown[townId] > minInterval then 
							trace("Allowing match based on cooldown for townId",townId)
						else 
							isMatch = false
							trace("Excluding town",town.name, " as it is within the cooldown period")
						end
						
						
						
					end 
					if isMatch then
						local p0 = util.v3fromArr(industry.position)
						local p1 = util.v3fromArr(town.position)
						local distance = util.distance(p0, p1) -- straight line distance
						local initialTargetLineRate, maxLineRate, existingSources = estimateInitialTargetLineRateCargo(industry, town, cargo)
						local isPrimaryIndustry = not getSourcesCountMap()[fileName] or util.size(getSourcesCountMap()[fileName]) == 0
						if isRecyclingPlant(industry) then 
							trace("Overriding is primary industry to false for recyling plant")
							isPrimaryIndustry = false -- because waste is not produced by any other industry
						end 
						local industryPair = { industry, town , p0, p1, distance, cargo, initialTargetLineRate, maxLineRate, isPrimaryIndustry, existingSources  }
						if filterFn(industryPair) then
							table.insert(industryPairs, industryPair)
						end
					end
				end
			else
				--goto continue2
			end
			trace("Checked town time taken ",(os.clock()-begin))
		end
		
		local function isMatch(fileName2) 
			for i, name in pairs(matchingTargets) do
				--trace("Checking ",name," against ",fileName2)
				if name == fileName2 then -- not worth optimising because its only 1 or 2
					return true
				end
			end
			return false
		end
		alreadySeen[industryId]=true
		local p0 = util.v3fromArr(industry.position)
		 
		for industryId2, industry2  in pairs(allIndustries2) do
			if industryId2==industryId then 
				goto continue
			end
			local p1 = util.v3fromArr(industry2.position)
			local distance = util.distance(p0, p1) -- straight line distance
			if maxDist and distance > maxDist then 
				goto continue 
			end
--			 trace("inspecting for a possible match ",industry2.name)
			
			local fileName2 = getFileNameOfIndustry(industryId2)
			local function canAcceptMoreSources(cargo)
				if industry.type == "TOWN" then 
					trace("canAcceptMoreSources: inspecting town",industry.name)
					if townIsShippingProduct(industry, cargo) then 
						trace("Rejecting town based on already shipping")
						return false 
					end 

				end 
				
				local maxSourcesCount = getSourcesCountMap()[fileName2][cargo]
				trace("maxSourcesCount for",fileName2,"and",cargo,"was",maxSourcesCount)
				local industryProduction = game.interface.getIndustryProduction(industry2.stockList)
				local maxProduction = 0--evaluation.baseCapacities[fileName2]*evaluation.productionLevels[fileName2]
				for cargoType, capacity in pairs(evaluation.capacities[fileName2]) do
					maxProduction = maxProduction + capacity*evaluation.productionLevels[fileName2]
				end 
				
				local isBelowMaxProduction = industryProduction < maxProduction
				if maxProduction == 0 then 
					isBelowMaxProduction = true -- pure consumer 
				end 
				trace("Comparing current industryProduction ",industryProduction," against maxProduction",maxProduction, "isBelowMaxProduction?",isBelowMaxProduction)
				if evaluation.hasOrCondition[fileName2] then
					local foundOurCargo = false 
					if not evaluation.totalSourcesCount then 
						discoverIndustryData() 
					end
					local totalSourcesCount = evaluation.totalSourcesCount[fileName2]
					local countByCargoType = 0
					for k, v in pairs(industry2.itemsConsumed) do 
						if evaluation.cargoTypeSet[k] then 
							countByCargoType = countByCargoType + 1
							if k == cargo then 
								foundOurCargo = true 
							end 
						end 
					end 
					trace("Industry ",fileName2," of ",industry2.name," had ",countByCargoType," sources, max sources ",totalSourcesCount)
					if not foundOurCargo and countByCargoType == totalSourcesCount and not industry2.itemsConsumed[cargo] and totalSourcesCount > 1  and industryProduction > 0.5*maxProduction and industryProduction > 0 then 
						trace(industry2.name," could not accept more sources")
						return false 
					end
				end
				
				
				
				if not maxSourcesCount then 
					return isBelowMaxProduction
				end 
				local sourcesOfSameType = countSourcesOfSameType(industry, industry2, cargo)
				trace("maxSourcesCount for ",fileName2," was ",maxSourcesCount,"sourcesOfSameType=",sourcesOfSameType,"at",industry2.name)
				return isBelowMaxProduction and sourcesOfSameType < maxSourcesCount
			end
			
			 
			-- CLAUDE CONTROL: For preSelectedPair, bypass cargo matching
			if param and param.preSelectedPair and
			   industryId == param.preSelectedPair[1] and
			   industryId2 == param.preSelectedPair[2] then
				trace("FORCE: Creating arbitrary rail connection via preSelectedPair from ", industry.name, " to ", industry2.name)
				local cargo = "COAL"
				local initialTargetLineRate, maxLineRate, existingSources = 100, 200, {}
				local isPrimaryIndustry = true
				local industryPair = { industry, industry2, p0, p1, distance, cargo, initialTargetLineRate, maxLineRate, isPrimaryIndustry, existingSources }
				if filterFn(industryPair) then
					table.insert(industryPairs, industryPair)
					trace("FORCE: Added preSelectedPair to industryPairs")
				end
			elseif isMatch(fileName2)  then
				trace("Initial match result industry",fileName," to ",fileName2)
				local cargos = {}
				local foundShipping = false 
				for __, cargoType in pairs(evaluation.industriesToOutput[fileName]) do 
					if evaluation.inputsToIndustries[cargoType]  then 
						for __, test in pairs(evaluation.inputsToIndustries[cargoType]) do --TODO optimise 
							if test == fileName2 then 
								trace("Found the cargoType was ",cargoType)
								
								if industry.itemsShipped and industry.itemsShipped[cargoType] and not evaluation.multiSupplyIndustry[fileName]  then 
									foundShipping = true 
								else 
									table.insert(cargos, cargoType) 
									
								end
							end
						end
					end
					--if cargo then break end
				end 
				if #cargos==0 and not foundShipping then 
					trace("WARNING! Unable to determine cargoType between",fileName," and ",fileName2)
					if util.tracelog then 
					--	debugPrint({industriesToOutput=evaluation.industriesToOutput, inputsToIndustries=evaluation.inputsToIndustries})
					end 
				end
				--if not cargo then goto continue end
				for __, cargo in pairs(cargos) do 
					if  canAcceptMoreSources(cargo) and not evaluation.checkIfIndustriesAlreadyConnected(industry, industry2, cargo)  then 
						local initialTargetLineRate , maxLineRate, existingSources= estimateInitialTargetLineRateCargo(industry, industry2, cargo)
						local isPrimaryIndustry = not getSourcesCountMap()[fileName] or util.size(getSourcesCountMap()[fileName]) == 0
						if possibleTownOutputs[cargo] then
							trace("Overriding isPrimaryIndustry to false for town output for ",cargo)
							isPrimaryIndustry = false 
						end
						if isRecyclingPlant(industry) then 
							trace("Overriding isPrimaryIndustry to false for recycling plant")
							isPrimaryIndustry = false 
						end 
						local industryPair =  { industry, industry2 , p0, p1, distance, cargo, initialTargetLineRate,maxLineRate, isPrimaryIndustry, existingSources}
						if filterFn(industryPair) then
							trace("MATCHED industries output ",industry.name," to ",industry2.name, " isPrimaryIndustry?",isPrimaryIndustry)
							table.insert(industryPairs, industryPair)
						end
					else 
						trace("The industry couldnt accept more sources for cargo",cargo)
					end 
				end
			end
			
			::continue:: 
		end
		
		::continue2:: 
	end
	evaluation.cargoSourceMap = nil
	evaluation.cargoDestsMap = nil
	evaluation.townSupplySourceMap = nil
	evaluation.townRateEstimateCache = nil
	evaluation.countExistingSupply = nil
	local endTime = os.clock()
	debuglog("Found ",#industryPairs," matching industry pairs of a total of ",util.size(allIndustries), " time taken=",(endTime-begin))
	profiler.endFunction("findMatchingIndustries")
	return industryPairs
end

local function atLimitForTruckStation(stationId) 
	local station = util.getStation(stationId)
	if util.countFreeTerminalsForStation(stationId) == 0 and #station.terminals >= 20 then 
		return true 
	end 
	return false
end 

local function checkIfIndustryHasTruckStation(industry, range)
	if not industry.id then 
		debugPrint({industry=industry})
		trace(debug.traceback())
	end 
	local constructionId = industry.type == "STATION" and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(industry.id) or api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
	if not range then range = 250 end
	for i, station in pairs(game.interface.getEntities({radius=range, pos=industry.position}, {type="STATION" , includeData=true})) do
		if station.cargo and station.carriers.ROAD and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station.id)~=-1 and (industry.type=="TOWN" or util.checkIfStationInCatchmentArea(station.id,constructionId)) and not atLimitForTruckStation(station.id) then
			return station.id
		end
	end
end
local function checkIfEdgeHasNearbyTruckStop(edge, range)
	if not range then range = 150 end
	local p = util.getEdgeMidPoint(edge)
	for i, station in pairs(game.interface.getEntities({radius=range, pos=util.v3ToArr(p)}, {type="STATION" , includeData=true})) do
		if station.cargo and station.carriers.ROAD and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station.id)==-1  then
			return station.id
		end
	end
end
local function checkIfIndustryHasRailStation(industry)
	local radius = industry.type=="TOWN" and 650 or 350
	for i, station in pairs(game.interface.getEntities({radius=radius, pos=industry.position}, {type="STATION" , includeData=true})) do
		if station.cargo and station.carriers.RAIL then
			if industry.type=="TOWN" then 
				if checkIfIndustryHasTruckStation({id = station.id, type="STATION", position = util.v3ToArr(util.getStationPosition(station.id))}, 300) and util.isStationTerminus(station.id) then 
					return station.id
				end
			elseif util.checkIfStationInCatchmentArea(station.id, getConstructionId(industry.id)) then
				return station.id
			end 
		end
	end
end

function evaluation.findAirportWithinRange(p, range)
	trace("Searching for airport withing range of ",range)
	if util.tracelog then debugPrint(p) end
	local options = {}
	for __, station in pairs(util.searchForEntities(p, range, "STATION")) do 
		if station.carriers.AIR and util.getConstructionForStation(station.id).fileName == "station/air/airport.con" then 
			table.insert(options, { stationId= station.id, scores = { util.distance(util.v3fromArr(p), util.getStationPosition(station.id))}}) 
		end
	end 
	if #options == 0 then 
		return
	end 
	return util.evaluateWinnerFromScores(options).stationId
end 

local function searchForHarbourWithRoadStation(position) 
	for i, station in pairs(game.interface.getEntities({radius=range, pos=util.v3ToArr(position)}, {type="STATION" , includeData=true})) do
		if station.cargo and station.carriers.WATER then 
			trace("searchForHarbourWithRoadStationP Looking if harbour",station.name," has a road station",station.id)
			if checkIfIndustryHasTruckStation({id = station.id,type="STATION", position = util.v3ToArr(util.getStationPosition(station.id))}) then 
				trace("Nearby road station WAS found")
				return station.id 
			end  
		end
	end
end

local function checkIfIndustryHasHarbour(industry, verticies, needsTranshipment)
	local position = industry.position
	
	for i, station in pairs(game.interface.getEntities({radius=350, pos=position}, {type="STATION" , includeData=true})) do
		if station.cargo and station.carriers.WATER and #api.engine.system.lineSystem.getLineStopsForStation(station.id) < 4 then
			return station.id
		end
	end
	if verticies then 
		local backupOption	
		for i = 1, #verticies do 
			position = util.v3ToArr(verticies[i].p)
			local range = 350	
			if needsTranshipment then 
				range = 750 
			end
			trace("Looking for a harbour near",position[1], position[2]," at range",range," attempt",i," of ",#verticies)
			for j, station in pairs(game.interface.getEntities({radius=range, pos=position}, {type="STATION" , includeData=true})) do
				if station.cargo and station.carriers.WATER and #api.engine.system.lineSystem.getLineStopsForStation(station.id) < 4 then
					local stationVertex = pathFindingUtil.getVertexForStation(station.id) 
					local sameGroup = waterMeshUtil.areVerticiesInSameGroup(verticies[i],stationVertex)
					local sameCoast = waterMeshUtil.isWaterContourMeshOnSameCoast(stationVertex, util.v3fromArr(industry.position) )
					trace("Considering the harbor station",station.name,"sameGroup?",sameGroup,"sameCoast?",sameCoast)
					if sameGroup and  sameCoast then  
						trace("considering station",station.id,station.name,"as it WAS on the right mesh for",industry.name)
					  
						if needsTranshipment then 
							trace("Looking if harbour",station.name," has a road station",station.id)
							if checkIfIndustryHasTruckStation({ id = station.id, type="STATION", position = util.v3ToArr(util.getStationPosition(station.id))}) then 
								trace("Nearby road station WAS found")
								return station.id
							elseif not backupOption then 
								trace("No nearby station found, setting as backup")
								backupOption = station.id 
							else 
								trace("No nearby station found and already a backup option")
							end 						
						else  
							return station.id
						end
					else 
						trace("Rejecting station",station.id,station.name,"as it was not on the right mesh for",industry.name)
					end 
				end
			end
		end
		trace("Returning backupOption")
		return backupOption
	end

end



	local function typeIsTown(edgeType) 
	return edgeType.categories ~= nil and #edgeType.categories > 0 and edgeType.categories[1] == "urban" 
		
	end
	local function isTown(edgeId) 
		local streetTypeCategory = util.getStreetTypeCategory(edgeId)
		if streetTypeCategory == "urban" then 
			return true 
		end 
		if streetTypeCategory == "country" then 
			return util.hasOnDeadEndNode(edgeId) and not util.isIndustryEdge(edgeId)
		end  
		return false 
	end
	
	
local function findUrbanStreetsForTown(town,radius, nonStrict) 
	local result = {} 
	if type(town) =="number" then
		town = util.getEntity(town)		
	end
	if town.type~="TOWN" then 	
		trace("Setting non strict to true")
		nonStrict = true 
	end
	local edges = game.interface.getEntities({ radius=radius, pos=town.position}, {type="BASE_EDGE", includeData=true})
	for i, edge in pairs(edges) do 
		if not edge.track and (isTown(edge.id) or nonStrict) and not util.isFrozenEdge(edge.id) then 
			table.insert(result,edge)
		end
	end
	if #result == 0 and not nonStrict then 
		return findUrbanStreetsForTown(town,radius, true) 
	end 
	return result
end



local function findMostCentralEdgeForTown(buildingFilterFn,town, isCargo, scoreFn, returnAllResults, fallback, edgeFilterFn, isRelocation )
	local start = os.clock()
	local matchingPositions = {}
	util.lazyCacheNode2SegMaps()
	if not edgeFilterFn then edgeFilterFn = function() return true end end
	local function populateMatchingPositions()
		local begin = os.clock()
		--collectgarbage()
		trace("About to get town to building map")
		local townBuildings  = getTown2BuildingMap()[town.id]
		trace("got town to building map")
		for i, buildingId in pairs(townBuildings) do
			--trace("Inspecting building ",buildingId," to see if it exists")
			if api.engine.entityExists(buildingId) then -- partial guard against race condition
				--trace("It DOES exist, attempting to get constructionId")
				local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(buildingId)
				--trace("Got constructionId attempting to get construction")
				if api.engine.entityExists(constructionId) then 
					local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
					--trace("Got construction, now running filter")
					if buildingFilterFn(construction) then
						--trace("Filter ran, passed, inserting to table")
						table.insert(matchingPositions, util.v3(construction.transf:cols(3)))
					else 
						--trace("Filter did not pass")
					end
				else 
					trace("No construction found with id",constructionId)
				end 
			else 
				trace("The building did not exist ", buildingId)
			end
		end
		trace("Completed populate matching positions, in ",(os.clock()-begin))
	end
	for i = 1, 5 do 
		trace("About to populate matching positions")
		if xpcall(populateMatchingPositions, err) then -- the town buildings can change during the call so need to be resiliant 
			break
		else 
			matchingPositions = {}
			evaluation.town2BuildingMap = nil -- force re cache
			trace("error detected on attempt ", i," to obtain town buildings")
		end
	end
	
	
	trace("checking town ",town.name," there were ",#matchingPositions," matching positions")
	local edgeResults = {}
	local distanceSumCount = 0
	for i, edge  in pairs(findUrbanStreetsForTown(town, 750)) do 
		local edgeComp =  util.getComponent(edge.id, api.type.ComponentType.BASE_EDGE)
		local edgeHasBusStop = false
		for i, obj in pairs(edgeComp.objects) do
			local station = util.getComponent(obj[1], api.type.ComponentType.STATION)
			--[[if not station then 
				trace("WARNING! no station found on edge",edge.id)
				goto continue 
			end]]--
			if station and station.cargo ~= isCargo then
				edgeHasBusStop = true
			end
		end
		if not edgeFilterFn(edge) then 	
			goto continue 
		end
		
		
		if edgeHasBusStop and not isRelocation then goto continue end
		if util.getEdge(edge.id).type ~= 0 then 
			goto continue 
		end
		if util.isDeadEndNode(edge.node0) or util.isDeadEndNode(edge.node1) then goto continue end -- building a stop on a dead end crashes the game(!)
		local streetEdge = util.getComponent(edge.id, api.type.ComponentType.BASE_EDGE_STREET)
		if string.find(api.res.streetTypeRep.getName(streetEdge.streetType), "old") and util.year() >= 1925 then 
			goto continue -- also appears to cause a game crash building on an old street after 1925 (concurrency issue with town street upgrade?)
		end
		if util.calculateSegmentLengthFromEdge(util.getEdge(edge.id)) < 50 then 
			goto continue -- another possible crash condition 			
		end
		if streetEdge.tramTrackType > 0 then 
			goto continue 
		end
		
		local midPoint = util.getEdgeMidPoint(edge.id)
		--trace("Got midpoint at ",midPoint.x,midPoint.y) --" from ",node0Pos.x,node0Pos.y, " and " ,node1Pos.x,node1Pos.y)
		local distSum = 0 
		for i, position in pairs(matchingPositions) do
			distSum = distSum + util.distance(position,midPoint)
			distanceSumCount = distanceSumCount + 1
		end
		if not scoreFn then 
			scoreFn = function(distSum, midPoint)
				return { distSum, distSum }
			end
		end
		
		table.insert(edgeResults, { edge=edge, scores = scoreFn(distSum, midPoint)})
		::continue::
	end
	trace("Finding most cental edge for town ",town.name, " there were ",#edgeResults," options time taken:",(os.clock()-start)," distanceSumCount=",distanceSumCount)
	if #edgeResults == 0 then 
		trace("WARNING! No edges found for ",town.name)
		return 
	end
	local result = util.evaluateWinnerFromScores(edgeResults, {75, 25}, nil,returnAllResults)
	if not returnAllResults then 
		return result.edge
	end
	return result
end
local function findCargoEdgeForTown(town, cargoType) 
	if not evaluation.townOutputs then 
		discoverIndustryData()
	end
	local allowAll = evaluation.townOutputs[cargoType]
	trace("For town ",town.name," and cargo",cargoType," allowAll was ",allowAll)
	local function filter(construction) 
		if allowAll then 
			return true 
		end
		return  construction.params.capacity > 0 and construction.params.cargoTypes and construction.params.cargoTypes[1] and util.contains(construction.params.cargoTypes, cargoType) 
	end
	return findMostCentralEdgeForTown(filter,town, true)
end
function evaluation.findCentralCargoEdges(town) 
	if type(town) == "number" then 
		town = util.getEntity(town) 
	end 
	local function buildingFilterFn() return true end 
	local isCargo = true
	local returnAllResults = true
	local result  = {} 
	for i, edge in pairs(findMostCentralEdgeForTown(buildingFilterFn,town, isCargo, scoreFn, returnAllResults )) do 
		table.insert(result, edge.edge.id)	
	end 
	return result 
end 
function evaluation.getLandUseTypeForConstruction(construction) 
	local fileName = construction.fileName
	if not evaluation.landUseTypeForConstructionCache then 
		evaluation.landUseTypeForConstructionCache = {}
	end
	if not evaluation.landUseTypeForConstructionCache[fileName] then 
		local buildingRepId =  api.res.buildingTypeRep.find(fileName)
		local buildingRep = api.res.buildingTypeRep.get(buildingRepId)
		evaluation.landUseTypeForConstructionCache[fileName] = buildingRep.params.landUseType
	end 
	return evaluation.landUseTypeForConstructionCache[fileName]
end 
function evaluation.findCentralEdgeByLandUseType(town, landUseType, scoreFn, isRelocation, extraFilterFn)
	local existingStation = util.findBusStationForTown(town.id)
	local existingStationPos = existingStation and util.getStationPosition(existingStation)
	local minDist = isRelocation and 200 or 100
	local filterFn = function(construction) 
	
		local p = util.v3(construction.transf:cols(3))
		local distanceToCenter = util.distance(util.v3fromArr(town.position), p )
		--trace("insepcting ",buildingRep.params.landUseType,"comparing with ",landUseType)
		if evaluation.getLandUseTypeForConstruction(construction)  ~= landUseType then 
			return false 
		end 
		if existingStationPos then 
			return util.distance(existingStationPos, p) > minDist--and distanceToCenter > 100 and  -- avoid clustering everything in the center
		end 
		return true
	end 
	local returnAllResults = false 
	local fallback = nil 
	local edgeFilterFn = extraFilterFn
	if existingStationPos then 
		edgeFilterFn = function(edge)
			if extraFilterFn and not extraFilterFn(edge) then 
				return false 
			end
			return util.distance(existingStationPos, util.getEdgeMidPoint(edge.id)) > minDist 
		end
	end
	local edge = findMostCentralEdgeForTown(filterFn,town, false, scoreFn, returnAllResults, fallback,edgeFilterFn)
	return edge and edge.id
end 
local landUseTypeLookup = { _("Residential"), _("Commercial"), _("Industrial") } 

local function getExistingBusStopsForTown(town)
	local existingStops =  util.getBusStopsForTown(town.id, true) 
 
		local result = {} 
		for i = 1, #existingStops do 
			local name = util.getComponent(existingStops[i], api.type.ComponentType.NAME).name 
			for j, landUseType in pairs(landUseTypeLookup) do 
				if string.find(name, landUseType) then 
					result[landUseType]=util.getEdgeForBusStop(existingStops[i])
					break					
				end 
			end 
		end 
		return result
	
	  
end

local function findBestLocationsForTown(town, excludeStations, isRelocation)
	local begin = os.clock()
	local createdMap = evaluation.town2BuildingMap == nil
	--[[local createdMap = false
	if not evaluation.town2BuildingMap then 
		evaluation.town2BuildingMap =  {}
		
		evaluation.town2BuildingMap[town.id]=util.deepClone(api.engine.system.townBuildingSystem.getTown2BuildingMap()[town.id])
		createdMap = true
	end]]--
	util.cacheNode2SegMapsIfNecessary()
	if not excludeStations then excludeStations = {} end
	local result = {} 
	for landUseType = 0, 2 do 
		result[landUseTypeLookup[landUseType+1]] = evaluation.findCentralEdgeByLandUseType(town, landUseType)
	end
	local otherStations = api.engine.system.stationSystem.getStations(town.id)
	local otherStationPositions = {} 
	for i, otherStation in pairs(otherStations) do 
		if 
		--api.engine.system.streetConnectorSystem.getConstructionEntityForStation(otherStation) ~= -1 and
		 not util.getComponent(otherStation, api.type.ComponentType.STATION).cargo
			and not excludeStations[otherStation] then 
			table.insert(otherStationPositions, util.getStationPosition(otherStation))
		end
	end
	
	for i = 1, 5 do 
		for landUseType = 0, 2 do 
			local otherStations = util.deepClone(otherStationPositions)
			for j, edgeId in pairs(result) do 
				if j~=landUseTypeLookup[1+landUseType] then 
					table.insert(otherStations, util.getEdgeMidPoint(edgeId))
					trace("Inserting other station position at",j, " for edgeid=",edgeId)
				else 
					trace("Ignoring other station position at",j, " for edgeid=",edgeId)
				end 
			end
			local scoreFn = function(distSum, midPoint)
				
				local distSum2 = 0
				for __, otherStationPos in pairs(otherStations) do 
					local distToOther = util.distance(midPoint, otherStationPos)
					if distToOther < 300 then 
						distSum2 = distSum2 + (300-distToOther) 
					end 
				end
				--trace("DistSum was",distSum,"distSum2 was",distSum2)
				return {
					distSum,
					distSum2 -- try to separate the stops by the largest distance
				}
			end
			local additionalFilterFn = function(edge) 
				for k, otherStationPos in pairs(otherStations) do 
					local dist = util.distance(util.getEdgeMidPoint(edge.id), otherStationPos)
					--trace("The distance from the ",k,"th station to the edge",edge.id," was ",dist)
					local minDist = isRelocation and 200 or 100
					if dist < minDist then
						return false 
					end 
				end
				return true
			end 
			
			result[landUseTypeLookup[1+landUseType]] = evaluation.findCentralEdgeByLandUseType(town, landUseType, scoreFn, isRelocation, additionalFilterFn)
		end
	end
	
	if createdMap then 
		evaluation.town2BuildingMap = nil
	end 
	trace("Completed in ",(os.clock()-begin))
	return result
end  
function evaluation.findBusStopEdgesForTown(town)
	if type(town) =="number" then
		town = util.getEntity(town)		
	end
	local existingStops = getExistingBusStopsForTown(town)
	if util.size(existingStops) >=3 then 
		return existingStops
	end
	return findBestLocationsForTown(town)
end
function evaluation.repositionBusStopEdgesForTown(town)
	if type(town)=="number" then 
		town = util.getEntity(town)
	end
	local existingStops =  getExistingBusStopsForTown(town)
	local result = {}
	local excludeStations = {}
	for landUseType, stationEdgeId in pairs(existingStops) do 
		local stationEdge = util.getEdge(stationEdgeId) 
		for i, station in pairs(stationEdge.objects) do 
			excludeStations[station[1]]=true
		end
	end 
	local newStations = findBestLocationsForTown(town, excludeStations, true)
	for landUseType, stationEdge in pairs(newStations) do 
		result[landUseType] = {}
		result[landUseType].new=stationEdge 
		result[landUseType].old=existingStops[landUseType]
	end
	return result
end

evaluation.findCargoEdgeForTown = findCargoEdgeForTown

local function findEdgeForIndustryOrTown(industry, cargoType)
	if industry.type=="TOWN" then
		return findCargoEdgeForTown(industry, cargoType)
	else 
		return findEdgeForIndustry(industry)
	end
end
function evaluation.isVirtualDeadEndForTerminus(node) 
	for i, seg in pairs(util.getStreetSegmentsForNode(node)) do 
		if util.getStreetTypeCategory(seg)=="entrance" then 
			return false 
		end
	end 
	local result = false 
	if #util.getStreetSegmentsForNode(node)==3 	then 
		for i, seg in pairs(util.getStreetSegmentsForNode(node)) do 
			if util.getStreetTypeCategory(seg)=="highway" then 
				trace("Rejecting node ",node, " as found highway segment", seg)
				return false 
			end 
		end 
		result = util.getOutboundNodeDetailsForTJunction(node).edgeId 
	elseif util.isCornerNode(node) then 
		result = util.getStreetSegmentsForNode(node)[1]
	end 
	local nearbyNodes =  util.countNearbyEntities(util.nodePos(node), 30, "BASE_NODE")
	if nearbyNodes > 1 then 
		result = false 
	end
  
	trace("Checking if ",node,"is virtualDeadEndForTerminus result=",result," nearbyNodes=",nearbyNodes)
	return result
end


local function isVirtualDeadEnd(node,isTerminus, params, town) 
	if #util.getTrackSegmentsForNode(node) > 0 then 
		trace("Rejecting node",node,"as it has track segments")
		return false 
	end 
	

	local edges = util.getStreetSegmentsForNode(node)
	--if #edges ~= 2 then 
	--	return false 
--	end
	if #edges == 3 and town then 
		local outBoundDetails = util.getOutboundNodeDetailsForTJunction(node)
		local vecFromTown = util.nodePos(node) - util.v3fromArr(town.position)
		local angle = math.abs(util.signedAngle(vecFromTown, outBoundDetails.tangent))
		trace("The angle of the node ",node," was ",math.deg(angle)," to ",town.name)
		if angle > math.rad(90) then 
			trace("Rejecting node ",node, " as facing the wrong way")
			return false 
		end
	end 
	
	local isHighway = params and params.isHighway
	if isTerminus or isHighway then 
		return evaluation.isVirtualDeadEndForTerminus(node) 
	end 
	if evaluation.isVirtualDeadEndForTerminus(node) and not util.isCornerNode(node) then 
		return util.getOutboundNodeDetailsForTJunction(node).edgeId 
	end
	local foundCountry = false
	local foundUrban = false
	local edgeId  
	local deadEndEdgesCount = 0
	local maxGrad = params and params.buildCompleteRoute and 0.15 or 0.075
	if params and params.extendedNodeSearch then 
		maxGrad = 0.2
	end 
	for i, seg in pairs(edges) do 
		trace("Inspecting ",seg, " to see if its a virtual dead end")
		local edge = util.getEdge(seg)
		if not edge then 
			util.clearCacheNode2SegMaps()
			util.lazyCacheNode2SegMaps()
			return false
		end 
		local grad = util.calculateEdgeGradient(edge)
		if grad > maxGrad then 
			trace("isVirtualDeadEnd: node",node,"being rejected for too high gradient at ",seg," grad=",grad,"maxGrad=",maxGrad)
			return false 
		end
		if util.getStreetTypeCategory(seg) == "urban" and not  util.isDeadEndEdgeNotIndustry(seg) then 
			foundUrban = true 
		 
			edgeId = seg 
		elseif util.getStreetTypeCategory(seg) == "country" then
			foundCountry = true
		end
		if util.isDeadEndEdgeNotIndustry(seg) then 
			deadEndEdgesCount = deadEndEdgesCount + 1
		end
		if util.isEdgeConnectedToTrackSegments(seg) then 
			return false 
		end 
	end
	local deadEndEdgesRequired = #edges - 2
	trace("isVirtualDeadEnd: Inspecting the node",node,"found edgeId?",edgeId,"foundUrban?",foundUrban,"foundCountry?",foundCountry,"deadEndEdgesCount=",deadEndEdgesCount,"deadEndEdgesRequired=",deadEndEdgesRequired)
	if foundCountry and foundUrban and deadEndEdgesCount >= deadEndEdgesRequired then 
		return edgeId 
	end
	if foundUrban and not foundCountry then 
		if #edges==2 and util.getStreetTypeCategory(edges[1]) == "urban" and util.getStreetTypeCategory(edges[2])=="urban" then 
			trace("Allowing the edge to be used as a double connected edge",edgeId)
			return edgeId
		end 
	end 
	
	return false
end

local function isDeadEnd(node, allowVirtualDeadends, alreadySeen, town, params)
		--trace("Inspecting node",node," for dead end")
		if alreadySeen then 
			if alreadySeen[node] then 
				trace("Already seen node ",node)
				return false
			end 
			alreadySeen[node]=true
		end
		if #util.getTrackSegmentsForNode(node) > 0 then 
			return false 
		end
		if not params then params = {}  end
		local isTerminus = town and params and params.buildTerminus and params.buildTerminus[town.id]
		
		if isTerminus and town and evaluation.shouldBuildTerminus(town) then -- do not build a terminus facing away from the map origin
			trace("Inspecting the direction of the node", node, " for town ",town.name)
			local vec1 = util.v3fromArr(town.position) -- minus vec3.new(0,0,0) -- origin 
			local vec2 = util.v3fromArr(town.position) - util.nodePos(node)
			local angle = math.abs(util.signedAngle(vec1, vec2))
			local shouldReject = angle > math.rad(90) 
			trace("Inspecting the direction of the node", node, " for town ",town.name, " the angle was ",math.deg(angle), " shouldReject=",shouldReject)
			if shouldReject and not params.extendedNodeSearch then 
				return false 
			end
		end 	
		
		local edges = util.getStreetSegmentsForNode(node)
		for i, seg in pairs(edges) do 
			if #util.getEdge(seg).objects > 0 and params.buildInitialBusNetwork then 
				trace("Rejecting seg",seg," for node",node," as it has edge objects")
				return false 
			end 
		end 
		local isVirtual = false
		local edgeId
		if #edges> 1 then 
			for __, edge in pairs(edges) do 
				local frozenEdge = util.isFrozenEdge(edge)
				if frozenEdge then 
					trace("Found a frozen edge",frozenEdge, "for edge",edge," on node",node)
					if util.getConstruction(frozenEdge).stations[1] and not util.getStation(util.getConstruction(frozenEdge).stations[1]).cargo then 
						local cornerNode = util.isCornerNode(node)   
						trace("Frozen edge was a station, allowing based on is cornerNode?",cornerNode)
						if cornerNode then 
							return true 
						end
					else 
						trace("Frozen edge was not a station, disallowing")
						return false
					end
				end 
			end
			
			if allowVirtualDeadends or isTerminus or params and params.isHighway or params.extendedNodeSearch then 
				edgeId = isVirtualDeadEnd(node, isTerminus, params, town) 
				if edgeId and isTerminus then 
					return true 
				end
				isVirtual = true
			else 
			--	if params.extendedNodeSearch and util.getSegmentsForNode(node)==2 then 
				--	trace("Permitting node",node,"for extended search")
			--		return true
			--	else 
					trace("Rejecting node",node," as not allowVirtualDeadends")
					return false
			--	end 
			end
		else 
			edgeId = edges[1]
		end 
		if not edgeId then 
			trace("Rejecting node",node,"as no edge was found")
			return false 
		end
		local edge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE )
		if   util.calculateSegmentLengthFromEdge(edge)<70 and not params.extendedNodeSearch then 
			trace("Rejecting node",node," because the edge is too short")
			return false
		end

		--[[if isVirtual then 
			local otherEdge = edgeId == edges[1] and edges[2] or edges[1] 
			if util.calculateSegmentLengthFromEdge(util.getEdge(otherEdge)) <70 then 
				trace("Rejecting virtual node",node," because the edge is too short")
				return false 
			end
		end]]--
		--debugPrint({edge = edge})
		local tangent = edge.node0 == node and edge.tangent0 or edge.tangent1
		-- walk in the direction to see if we hit the sea
		local clearLength = edge.node0 == node and -50 or 50
		local location = vec2.add(util.nodePos(node), vec2.mul(clearLength, vec2.normalize(vec2.new(tangent.x, tangent.y))))
		--local result =  api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(location.x,location.y)) >=0
		local result =  util.th(location) >=0
		if not result then 
			trace("rejected node ", node, " because it is too close to the sea ", location.x, ", ", location.y)
		else 
			--local location2 = vec2.add(util.nodePos(node), vec2.mul(0.5*clearLength, vec2.normalize(vec2.new(tangent.x, tangent.y))))
		--	result = #game.interface.getEntities({radius=15, pos={location2.x, location2.y}}, {type="BASE_NODE"}) == 0;
		--	if not result then
		--		debuglog("rejected node ", node, " because it is too close to another node ", location2.x, ", ", location2.y)
		---	end
		end
		local gradient = util.calculateEdgeGradient(edge) 
		if math.abs(gradient) > 0.075 and not params.extendedNodeSearch then 
			trace("rejected node ",node," because the gradient is too high",gradient)
		end
		trace("Node",node,"result=",result)
		return result
		
	end
evaluation.getNearestCorner = function(p) 
	local mapBoundary = util.getMapBoundary()
	local signx = p.x <0 and -1 or 1
	local signy = p.y <0 and -1 or 1
	return vec3.new(signx * mapBoundary.x, signy * mapBoundary.y, 0)
end

evaluation.getDistanceToNearestCorner = function(p)
	return util.distance(evaluation.getNearestCorner(p), p)
end	

local function getAllTowns() 
	return util.searchForEntities(vec3.new(0,0,0), math.huge, "TOWN")
end

function evaluation.getAllTownPositions() 
	if not evaluation.townPositions then 
		evaluation.townPositions = {}
		local allTowns = getAllTowns()
		for townId, town in pairs(allTowns) do 
			local p = util.v3fromArr(town.position)
			p.name = town.name -- for debug
			evaluation.townPositions[townId]=p
		end 
	end 
	return evaluation.townPositions
end


function evaluation.getTownPosition(townId)  
	if not evaluation.getAllTownPositions() [townId] then 
		evaluation.townPositions = nil -- refresh
	end 
	
	return evaluation.getAllTownPositions() [townId]
end 

local function townHash(town1, town2)
	if town1 > town2 then 
		return town1*1000000+town2
	else 
		return town2*1000000+town1 
	end
end

function evaluation.getCornerTowns()
	if not evaluation.edgeTowns then 
		local mapBoundary = util.getMapBoundary()
		local edgeTowns = {}
		local allTowns =  getAllTowns() 
		local xs = { 1, 1, -1, -1}
		local ys = { 1, -1, 1, -1}
		for i = 1, 4 do 
			local towns = {}
			local corner = vec2.new(xs[i]*mapBoundary.x, ys[i]*mapBoundary.y) 
			local closest = util.evaluateWinnerFromSingleScore(allTowns, function(town) return vec2.distance(util.v3fromArr(town.position), corner) end)
			edgeTowns[closest.id]=true
		end
		if util.tracelog then -- test
			local alreadySeen = {}
			local alreadySeenHash = {}
			local count =0 
			for townId, town in pairs(allTowns) do 
				alreadySeen[townId] = true 
				for town2Id, town in pairs(allTowns) do 
					if not alreadySeen[town2Id]  then 
						count = count +1
						local townHash = townHash(townId, town2Id)
						assert(not alreadySeenHash[townHash], "Should not have seen "..townHash.." but did for "..tostring(alreadySeenHash[townHash]))
						alreadySeenHash[townHash]= tostring(townId).."/"..tostring(town2Id)
					end 
				end 	
			end 
			trace("Finished checking town hashing, checked",count,"results")
			local n = util.size(allTowns)
			local expected = n*(n-1)/2
			assert(count==expected,"expected "..expected.." but was "..count)
		end 	
		evaluation.edgeTowns=edgeTowns
	end
	return evaluation.edgeTowns
end

function evaluation.isCornerTown(townId)
	return evaluation.getCornerTowns()[townId]
end 

local terminusCache = {}
evaluation.shouldBuildTerminus = function(town, town2)
	local function townHash(town1, town2) -- need to override this because we care about order
		return town1*1000000+town2
	end 
	if town2 and terminusCache[townHash(town.id, town2.id)] ~= nil then 
		trace("For the town pair",town.id,town2.id,"towns",town.name,town2.name,"using the cached value of",terminusCache[townHash(town.id, town2.id)],"based on townHash",townHash(town.id, town2.id))
		return terminusCache[townHash(town.id, town2.id)]
	end 
	
	local allPositions = evaluation.getAllTownPositions()
	
	if not town2 or util.size(allPositions) <= 12 then 
		return  evaluation.isCornerTown(town.id)
	end 
	
	local p1 = evaluation.getTownPosition(town.id)
	local p2 = evaluation.getTownPosition(town2.id)
	if not p1 or not p2 then 
		
		debugPrint({town=town,town2=town2, getAllTownPositions= evaluation.getAllTownPositions()})
	end 
	
	local townVector = p1 - p2
	local distance = vec3.length(townVector)
--	local townVector = getVectorBetweenTowns(town2, town)
	--for townId, otherTown in pairs(getAllTowns()) do -- do not biuld terminus if there is at least one town within a 120 degree cone based on the vector from the prior town
	--	local otherVector = getVectorBetweenTowns(town, otherTown)
	for townId, otherTown in pairs(allPositions) do 
		if townId ~= town.id and townId ~= town2.id then 
			local otherVector = otherTown - p1
			local waterFraction, waterDistance = util.getWaterRouteDetailBetweenPoints(otherTown, p1) 
			local shouldBuildWaterOrAirRoute = waterDistance > 500 and waterFraction > 0.75 or waterDistance > 1000 and waterFraction > 0.5
			if shouldBuildWaterOrAirRoute then 
				trace("shouldBuildTerminus: ignoring link between ",town.name," based on connection from",town2.name,"to",util.getEntity(townId).name, " as it is water route: waterFraction=",waterFraction, " waterDistance=",waterDistance)
				goto continue 
			end
			local angle = math.abs(util.signedAngle(townVector, otherVector))
			--trace("shouldBuildTerminus: Comparing ",town.name,town2.name, " with ",otherTown.name,"vector angle was",math.deg(angle))
			if angle < math.rad(60) and vec3.length(otherVector) < 5*distance or angle < math.rad(30) then 
				trace("shouldBuildTerminus: Determined that should NOT build a terminus for ",town.name," based on connection from",town2.name, " due to angle ",math.deg(angle)," from other town",otherTown.name)
				terminusCache[townHash(town.id, town2.id)] = false
				return false 
			end
		end
		::continue::
	end 
	trace("shouldBuildTerminus: Determined that SHOULD build a terminus for ",town.name," based on connection from",town2.name)
	terminusCache[townHash(town.id, town2.id)]=true
	return true
end

function evaluation.getStationPositionAndRotation(town, nodeInfo, otherTown, params, extraOffset, thirdTown)
	local removeOriginalNode = true
	nodeInfo = util.deepClone(nodeInfo)
	nodeInfo.tangent.z = 0
	local tangent = vec3.normalize(nodeInfo.tangent)
	local otherNode = nodeInfo.otherNode
	local otherNodePos = nodeInfo.otherNodePos
	trace("getStationPositionAndRotation got otherNode=",otherNode,"otherNodePos=",otherNodePos)
	if extraOffset then 
		nodeInfo.nodePos = nodeInfo.nodePos + extraOffset * vec3.normalize(nodeInfo.tangent)
		trace("getStationPositionAndRotation, increasing offset for ",town.name,"by",extraOffset)
	end 
	local isCargo = params and params.isCargo
	local isHighway = params and params.isHighway
	local isTerminus = not isCargo and not isHighway and params and params.buildTerminus and params.buildTerminus[town.id]
	if isCargo and town.type == "TOWN" then 
		isTerminus = true 
	end
	local townPos = util.v3fromArr(town.position)
	local edgeToRemove
	if nodeInfo.isVirtualDeadEnd and not isTerminus and #util.getSegmentsForNode(nodeInfo.node) == 2 then 
		local segs = util.getSegmentsForNode(nodeInfo.node)
		local cat1 = util.getStreetTypeCategory(segs[1])
		local cat2 = util.getStreetTypeCategory(segs[2])
		local useUnderPass = cat1~=cat2
		trace("getStationPositionAndRotation: evaluated useUnderPass to",useUnderPass,"based on categories",cat1,cat2,"at",nodeInfo.node)
		if useUnderPass then 
			edgeToRemove = nodeInfo.edgeId == segs[1] and segs[2] or segs[1]
			local edge = util.getEdge(nodeInfo.edgeId) 
			local curveAngle = util.signedAngle(util.v3(edge.tangent0), util.v3(edge.tangent1))
			if math.abs(curveAngle) > math.rad(1) then 
				trace("Detected curved section for virtual dead end, attempting to correct ", math.deg(curveAngle))
				local tangentToUse = nodeInfo.node == edge.node0 and -1*util.v3(edge.tangent1) or util.v3(edge.tangent0)
				tangent = vec3.normalize(tangentToUse)
				nodeInfo.nodePos = nodeInfo.otherNodePos+tangentToUse
			end
		else 
			local tangentTable = util.getPerpendicularTangentAndDetailsForEdge(nodeInfo.edgeId, nodeInfo.node)
			tangent = vec3.normalize(tangentTable.tangent)
			local testP = nodeInfo.nodePos + 10*tangent 
			local testP2 = nodeInfo.nodePos - 10*tangent 
			if util.distance(testP, townPos) < util.distance(testP2, townPos) then 
				tangent = -1*tangent 
			end 
			nodeInfo.nodePos  = nodeInfo.nodePos + 90 *tangent 
			removeOriginalNode = false 
			trace("Double ended node setting position to ",nodeInfo.nodePos.x,nodeInfo.nodePos.y,"around node",nodeInfo.node)
		end 
	end
	if nodeInfo.isVirtualDeadEnd and not isTerminus and #util.getSegmentsForNode(nodeInfo.node) == 3 then 
		nodeInfo.nodePos = nodeInfo.nodePos + 90 * vec3.normalize(nodeInfo.tangent)
		removeOriginalNode = false 
		trace("getStationPositionAndRotation: increasing the nodePos offset for 3 segment node at",town.name,"nodeInfo.nodePos=",nodeInfo.nodePos.x,nodeInfo.nodePos.y)
	end 
	local stationPos  
	local stationTangent = vec3.new(0,1,0)
		--local leftangel = vec2.angle(nrmllefttrangent, stationTangent)
	local signedAngle = util.signedAngle(tangent, stationTangent)
	local otherTownPos = util.v3fromArr(otherTown.position)
	
	local vectorToOtherTown = otherTownPos-townPos
	local signedAngleToTown = util.signedAngle(tangent, vectorToOtherTown)
	local rotation = math.rad(90)-signedAngle
	local stationParallelTangent = util.rotateXY(tangent,math.rad(90))
	if (params.isQuadrupleTrack or params.isHighway or params.buildCompleteRoute )
		--and not town.isExpressStop
		and not isTerminus
		and (params.isHighway or params.buildInitialBusNetwork)
		and thirdTown
		and thirdTown.id ~= otherTown.id then
		local vec1 = util.vecBetweenTowns(town , otherTown )
		local vec2 = util.vecBetweenTowns(thirdTown , town )
		if params.expectedPositions then 
			trace("Adjusting for expected positions")
			local townPos = params.expectedPositions[town.id] or util.v3fromArr(town.position)
			local otherTownPos = params.expectedPositions[otherTown.id] or util.v3fromArr(otherTown.position)
			local thirdTownPos = params.expectedPositions[thirdTown.id] or util.v3fromArr(thirdTown.position)
			if util.tracelog then 
				debugPrint({town=town, otherTown=otherTown, thirdTown=thirdTown, townPos=townPos, otherTownPos=otherTownPos, thirdTownPos=thirdTownPos})
			
			end 
			
			
			vec1 = otherTownPos - townPos 
			vec2 = townPos - thirdTownPos
		end 
		
		local weightedAverage = (1/vec3.length(vec1))*vec1 + (1/vec3.length(vec2))*vec2 
		local originalRotation = rotation
		stationParallelTangent = vec3.normalize(weightedAverage)
		local stationPerpTangent =  util.rotateXY(stationParallelTangent ,math.rad(90))
		rotation = -util.signedAngle(weightedAverage, stationTangent)
		if math.abs(util.signedAngle(stationPerpTangent, tangent)) > math.rad(90) then 
			stationPerpTangent = -1*stationPerpTangent
			trace("Inverting station perpTangent",town.name)
			rotation = rotation + (rotation > 0 and -math.rad(180) or math.rad(180))
		end 
		if originalRotation - rotation > math.rad(90) then 
			trace("Increasing the rotation from",rotation,"by adding 180 for town",town.name)
			rotation = rotation + math.rad(180)
		end 
		if rotation - originalRotation  > math.rad(90) then 
			trace("Decreasing the rotation from",rotation,"by subtract 180 for town",town.name)
			rotation = rotation - math.rad(180)
		end 
		local delta = math.abs(rotation - originalRotation)
		
		nodeInfo.nodePos = nodeInfo.nodePos + 90*math.sin(delta) * vec3.normalize(nodeInfo.tangent)
		trace("The originalRotation was",math.deg(originalRotation)," the new rotation was",math.deg(rotation), " delta=",math.deg(delta),"set the nodePos to",nodeInfo.nodePos.x,nodeInfo.nodePos.y)
		tangent = stationPerpTangent
	end 
	
	local stationAngleToTown = util.signedAngle(stationParallelTangent, vectorToOtherTown)
	if util.distance( nodeInfo.nodePos + 100*stationParallelTangent, otherTownPos)>util.distance(nodeInfo.nodePos, otherTownPos) then
		stationParallelTangent = -1*stationParallelTangent -- always have the parallel pointing to the other town
		trace("Inverting the station parallel tangent for station at",town.name)
		stationAngleToTown = util.signedAngle(stationParallelTangent, vectorToOtherTown)
	end	
	if stationAngleToTown ~= stationAngleToTown then 
		debugPrint({stationAngleToTown=stationAngleToTown, stationParallelTangent=stationParallelTangent, vectorToOtherTown=vectorToOtherTown})
	end
	local stationPerpTangent = tangent
	local busStationParallelTangent = stationParallelTangent
	local busStationPerpTangent = stationPerpTangent
	local busStationRotation = rotation
	local perpTangent = util.rotateXY(tangent,math.rad(90))
	if params.tryOtherRotation and isTerminus then 
		trace("Setting up with the other rotation")
		rotation = -signedAngle 
		stationParallelTangent = tangent
		stationPerpTangent = perpTangent
	end
	

	local stationLength = params.stationLength
	local segsForNode = #util.getSegmentsForNode(nodeInfo.node)
	util.trace("Node",nodeInfo.node," Station for ",town.name," Signed angle was ", math.deg(signedAngle), " signedAngleToTown=",math.deg(signedAngleToTown) , " isTerminus=",isTerminus,"isHighway=",isHighway," stationAngleToTown=",math.deg(stationAngleToTown), " stationLength=",stationLength," params.tryOtherRotation?",params.tryOtherRotation, " segsForNode=",segsForNode)
	local removeOriginalNode = true 
	local stationConnectPos
	local connectionOffset = 35
	local isVirtualDeadEndForTerminus = false
	local offsetx = 0
	local offsety = 0
	local extraOffset = 0 
	local segs = util.getStreetSegmentsForNode(nodeInfo.node)
	if #segs > 1 then 
		local baseWidth = 16 -- 4 * 4 lanes 
		for i, seg in pairs(segs) do 
			local edgeWidth = util.getEdgeWidth(seg)
			if edgeWidth > baseWidth then 
				extraOffset = math.max(extraOffset, (edgeWidth-baseWidth)/4)-- NB i think this should be a factor of 2 but it results in too much offset
			end 
		end 
		trace("Adjusted extraOffset to ",extraOffset)
	end 
	
	
	if isTerminus    then
		offsetx = 0
		offsety = (stationLength/2) + (isCargo and 40 or 38) + extraOffset
		if params.tryOtherRotation then 
			offsetx = offsety
			offsety = 0
		elseif evaluation.isVirtualDeadEndForTerminus(nodeInfo.node) then 
			--[[local adjustment =   signedAngleToTown < 0 and  math.rad(90) or -math.rad(90) 
			if math.abs(signedAngleToTown) > math.rad(45) then 
				rotation = rotation +adjustment
			end]]--
			--[[
			if math.abs(stationAngleToTown) > math.rad(135) then 
				local adjustment = rotation > 0 and -math.rad(180) or math.rad(180)
				rotation = rotation +adjustment
				offsety = -offsety
				stationPerpTangent =  util.rotateXY(stationPerpTangent,adjustment)
				stationParallelTangent = util.rotateXY(stationParallelTangent, adjustment)
				trace("Adjusting virtualDeadEndForTerminus by ",math.deg(adjustment), " end rotation was ",math.deg(rotation))
			elseif math.abs(stationAngleToTown) > math.rad(45) or params.tryOtherRotation then 
				--local adjustment=   stationAngleToTown < 0 and  math.rad(90) or -math.rad(90) 
				local adjustment = -math.rad(90)
				--local adjustment = signedAngleToTown > 0 and -math.rad(90) or math.rad(90)
				rotation = rotation +adjustment
				trace("Adjusting virtualDeadEndForTerminus by ",math.deg(adjustment), " end rotation was ",math.deg(rotation))
				stationParallelTangent = util.rotateXY(stationParallelTangent, adjustment)
				stationPerpTangent =  util.rotateXY(stationPerpTangent,adjustment)
				offsetx= adjustment >0 and -offsety or offsety
				offsety=0
				
			end--]]
			local segs = util.getStreetSegmentsForNode(nodeInfo.node)
			if #segs==3 then 
				tangent = vec3.normalize(util.getOutboundNodeDetailsForTJunction(nodeInfo.node).tangent)
				
			else 	
				local options = {} 
				for i, seg in pairs(segs) do 
					local edge = util.getEdge(seg) 
					local tangent = edge.node0 == nodeInfo.node and -1*util.v3(edge.tangent0) or util.v3(edge.tangent1)
					table.insert(options, { tangent = tangent, scores = { math.abs(util.signedAngle(tangent, vectorToOtherTown)) } })
					
				end 
				tangent = vec3.normalize(util.evaluateWinnerFromScores(options).tangent)
			end 
			stationParallelTangent = tangent 
			stationPerpTangent = util.rotateXY(stationParallelTangent,  math.rad(90))
			
			rotation = -util.signedAngle(tangent, stationTangent)
			offsetx=offsety
			offsety=0
			isVirtualDeadEndForTerminus = true
			otherNode = nodeInfo.node
			otherNodePos = nodeInfo.nodePos
		else  
			if math.abs(signedAngleToTown) < math.rad(45) or math.abs(signedAngleToTown) > math.rad(180)-math.rad(45)  then -- gives better rotation
			--if math.abs(stationAngleToTown) < math.rad(45) or math.abs(stationAngleToTown) > math.rad(180)-math.rad(45) then -- gives better rotation
				--local adjustment = (math.abs(signedAngleToTown) > math.rad(90) and -math.rad(90) or math.rad(90))
				if #util.getSegmentsForNode(nodeInfo.node)==1 then 
					trace("The terminus is on a dead end node",nodeInfo.node," rotating and positioning to extend from node")
					stationParallelTangent = tangent 
					stationPerpTangent = util.rotateXY(stationParallelTangent,  math.rad(90))
					rotation = -util.signedAngle(tangent, stationTangent)
					offsetx=offsety
					offsety=0
				else 
					local adjustment = signedAngleToTown > 0 and -math.rad(90) or math.rad(90)
					trace("adjusting the rotation by ",math.deg(adjustment))
					rotation = rotation + adjustment
					stationParallelTangent = util.rotateXY(stationParallelTangent, -adjustment)
					stationPerpTangent =  util.rotateXY(stationPerpTangent,-adjustment)
					offsetx=offsety
					offsety=0
					if util.distance( nodeInfo.nodePos + 100*stationParallelTangent, townPos)<util.distance(nodeInfo.nodePos, townPos)  then 
						trace("WARNING! Detected terminus facing into town, flipping")
						rotation = rotation + (rotation<0 and math.rad(180) or -math.rad(180))
						stationPerpTangent = -1*stationPerpTangent
						stationParallelTangent = -1*stationParallelTangent
					end 
				end
			else 
				local trialPos =  nodeInfo.nodePos + offsetx * tangent + offsety * perpTangent
				local trialPos2 = nodeInfo.nodePos + offsetx * tangent - offsety * perpTangent
				local trialPosDist = util.distance(trialPos, otherTownPos)
				local trialPos2Dist =  util.distance(trialPos2, otherTownPos)
				trace("The trialPostDist=",trialPosDist," the trialPos2Dist=",trialPos2Dist)
				if trialPosDist > trialPos2Dist then 
					offsety = -offsety
					rotation = rotation+math.rad(180)
					stationPerpTangent =  -1*stationPerpTangent
					--stationParallelTangent = -1*stationParallelTangent
					trace("flipping the station for offsety")
				end
			end
			
		end
		if math.abs(offsetx) > 0 then 
			local trialPos =  nodeInfo.nodePos + offsetx * tangent + offsety * perpTangent
			local trialPos2 = nodeInfo.nodePos - offsetx * tangent + offsety * perpTangent
			local trialPosDist = util.distance(trialPos, otherTownPos)
			local trialPos2Dist =  util.distance(trialPos2, otherTownPos)
			trace("The trialPostDist=",trialPosDist," the trialPos2Dist=",trialPos2Dist)
			if trialPosDist > trialPos2Dist then 
				--offsety = -offsety
				offsetx = -offsetx
				rotation = rotation+math.rad(180)
				--stationPerpTangent =  -1*stationPerpTangent
				
				--TODO is this correct why needed ? 
				stationParallelTangent = -1*stationParallelTangent
				trace("flipping the station for offsetx at",town.name)
			end
		end
		stationPos = nodeInfo.nodePos + offsetx * tangent + offsety * perpTangent
		trace("Setting up terminus stationPos for",town.name, " offsetx was",offsetx, " offsety was ",offsety, " at ",stationPos.x, stationPos.y)
	elseif isCargo and (math.abs(signedAngleToTown) < math.rad(45) or math.abs(signedAngleToTown) > math.rad(180)-math.rad(45)) then
		local offset =    40  + extraOffset
		rotation = rotation + math.rad(90)
		stationPerpTangent =  util.rotateXY(stationPerpTangent,math.rad(90))
		stationParallelTangent = util.rotateXY(stationParallelTangent, math.rad(90))
		stationPos = offset * perpTangent + nodeInfo.nodePos
		stationConnectPos = (offset-connectionOffset)*perpTangent+nodeInfo.nodePos
		local industryPos = util.v3fromArr(town.position)
		if util.distance(industryPos, stationPos) < util.distance(industryPos, nodeInfo.nodePos) then 
			trace("after rotation the station was close to the industry, adjusting the other way")
			rotation = rotation + math.rad(180)
			stationPerpTangent =  util.rotateXY(stationPerpTangent,math.rad(180))
			stationParallelTangent = util.rotateXY(stationParallelTangent, math.rad(180))
			stationPos = -offset*perpTangent+nodeInfo.nodePos
			stationConnectPos = (-offset+connectionOffset)*perpTangent+nodeInfo.nodePos
		end
	else
		local offset =  36 + extraOffset
		stationPos = offset * tangent + nodeInfo.nodePos
		stationConnectPos = (offset-connectionOffset)*tangent+nodeInfo.nodePos
	end
	if   util.distance( nodeInfo.nodePos + 100*stationParallelTangent, otherTownPos)>util.distance(nodeInfo.nodePos, otherTownPos) and not params.buildCompleteRoute then
		trace("stationParallelTangent needed correcting")
		stationParallelTangent = -1*stationParallelTangent -- always have the parallel pointing to the other town
	end	
	if isCargo and not isTerminus then
		local testPos = stationPos + ((stationLength/2) + 40)* stationParallelTangent
		for __, edge in pairs(util.searchForEntities(testPos, 40, "BASE_EDGE")) do
			if edge.track then 
				stationPos = stationPos - 80 * stationParallelTangent
				break
			end
		end
	end
	
	
	stationPos.z =  nodeInfo.nodePos.z -- clamp the height
	

	local angleToVector = math.abs(util.signedAngle(stationParallelTangent, vectorToOtherTown))
	if params.buildCompleteRoute and thirdTown and not isTerminus then 
		
		--local vec1 = util.vecBetweenTowns(town , otherTown )
		--local vec2 = util.vecBetweenTowns(thirdTown , town )
		local vec1 = util.vecBetweenTowns(otherTown, town  )
		local vec2 = util.vecBetweenTowns(town, thirdTown   )
		if params.expectedPositions then 
			trace("Adjusting for expected positions")
			local townPos = params.expectedPositions[town.id] or util.v3fromArr(town.position)
			local otherTownPos = params.expectedPositions[otherTown.id] or util.v3fromArr(otherTown.position)
			local thirdTownPos = params.expectedPositions[thirdTown.id] or util.v3fromArr(thirdTown.position)
			vec1 = otherTownPos - townPos 
			vec2 = townPos - thirdTownPos
		end 
		local weightedAverage = (1/vec3.length(vec1))*vec1 + (1/vec3.length(vec2))*vec2 
		local original = angleToVector
		angleToVector = math.abs(util.signedAngle(stationParallelTangent, weightedAverage))
		if angleToVector > math.rad(90) then 
			angleToVector = math.rad(180) - angleToVector -- because the station is symmetric (excluding terminus)
		end
		trace("Computing the angleToVector for ",town.name," otherTown=",otherTown.name," thirdTown=",thirdTown.name, " was ",math.deg(angleToVector), " original was",math.deg(original), " for node ",nodeInfo.node,"stationPos=",stationPos.x,stationPos.y)
	end
	
	
	if params.buildCompleteRoute and not isTerminus then 
		if util.signedAngle(stationParallelTangent, stationPerpTangent) < 0 then 
			trace("Inverting the stationParallelTangent for right handed depot at ",town.name)
			stationParallelTangent = -1*stationParallelTangent -- keeps the depot on the right hand side (avoiding crossover)
			busStationParallelTangent = -1*busStationParallelTangent  -- keep the bus station opposite side of the depot
		end 
	end 
	
	stationPos.z = math.max(stationPos.z, 5+util.getWaterLevel())
	otherNodePos.z = math.max(otherNodePos.z, 5+util.getWaterLevel())
	return { 
		position = stationPos, 
		rotation = rotation,
		stationConnectPos = stationConnectPos, 
		stationPerpTangent= stationPerpTangent,
		tangent = tangent, 
		isVirtualDeadEndForTerminus = isVirtualDeadEndForTerminus,
		stationParallelTangent = stationParallelTangent,
		originalNodePos = nodeInfo.nodePos,
		originalEdgeId = nodeInfo.edgeId,
		originalNode = nodeInfo.node,
		otherNode = otherNode,
		otherNodePos = otherNodePos,
		stationRelativeAngle = util.signedAngle(stationParallelTangent, stationPerpTangent),
		busStationParallelTangent = busStationParallelTangent,
		busStationPerpTangent = busStationPerpTangent,
		busStationRotation = busStationRotation,
		busStationRelativeAngle = util.signedAngle(busStationParallelTangent, busStationPerpTangent),
		edgeToRemove = edgeToRemove,
		isVirtualDeadEnd = nodeInfo.isVirtualDeadEnd,
		offsetx = offsetx,
		offsety = offsety,
		isTerminus = isTerminus, 
		angleToVector= angleToVector,
		existingBusStation = nodeInfo.existingBusStation,
		buildCompleteRoute = params.buildCompleteRoute,
		removeOriginalNode = removeOriginalNode,
	}
end

evaluation.findDeadEndNodes = function(town, radius) 
	util.cacheNode2SegMapsIfNecessary()
	local result = {}
	for edgeId, edge in pairs(findUrbanStreetsForTown(town,radius)) do 
		if isDeadEnd(edge.node0) then
			result[edge.node0]=edge.node0pos
		elseif isDeadEnd(edge.node1) then
			result[edge.node1]=edge.node1pos
		end
	end
	return result
end
	
local function buildNodeInfo(edgeId, vector, node, nodePosArr, tangent, sign,town, town2, closestOtherTown, params)
	local nodePos = util.v3fromArr(nodePosArr)
	local townPos = util.v3fromArr(town.position)
	local v3tangent = vec3.normalize(sign*util.v3fromArr(tangent))
	if #util.getSegmentsForNode(node) == 3 then 
		local nodeInfo = util.getOutboundNodeDetailsForTJunction(node)
		v3tangent = nodeInfo.tangent 
		edgeId = nodeInfo.edgeId
	end 
	local v2tangent = vec2.normalize(v3tangent)
	
	local angleToVector = vec2.angle(v2tangent,vector)
	local stationParallelTangent =  v3tangent
	if params and (params.isTrack or params.isHighway) then 
		stationParallelTangent = util.rotateXY(v3tangent,math.rad(90))
		local angleToVector2 = math.abs(util.signedAngle(stationParallelTangent, util.v2ToV3(vector)))
		trace("Initial angleToVector calculation: vector=",vector.x,vector.y,  " stationParallelTangent=",stationParallelTangent.x,stationParallelTangent.y, " angle was ",math.deg(angleToVector), " alternate gave ",math.deg(angleToVector2))
	end
	if angleToVector ~= angleToVector then 
		angleToVector = math.rad(90)
	end
	if angleToVector > math.rad(90) then 
		trace("correcting angleToVector, was ",math.deg(angleToVector), " will be ",math.deg(math.rad(180)-angleToVector))
		angleToVector = math.rad(180)-angleToVector
	end
	local vectorToOtherTown =util.vecBetweenTowns(town , closestOtherTown )
	local angleToOtherTown = vec2.angle(v2tangent,  vec2.rotate90( vectorToOtherTown))
	if angleToOtherTown > math.rad(90) then
		angleToOtherTown = math.rad(180) - angleToOtherTown
	end
	local isTerminus = params and params.buildTerminus and params.buildTerminus[town.id]  
	if isTerminus then 
		local actualVector = util.v3fromArr(town2.position)-util.v3fromArr(town.position)
		if #util.getSegmentsForNode(node) == 3 then 
			v3tangent = util.getOutboundNodeDetailsForTJunction(node).tangent 
			nodePos = nodePos + 90 * vec3.normalize(v3tangent)
			angleToVector = math.abs(util.signedAngle(v3tangent,actualVector))
			trace("Angle to vector for virtual terminus ",node," was ",math.deg(angleToVector))
		else  
			---local townVector = util.vecBetweenTowns(town, town2) 
			local angle = math.abs( util.signedAngle(v3tangent, actualVector))
			trace("signed angle to vector was", math.deg(angle), " at position ", nodePos.x,nodePos.y)
			if angle < math.rad(90) then
				angleToVector = math.min(angleToVector,angle)
			else 
				angleToVector = angle -- discourage offside terminus
			end 
			
			local angle2 = util.signedAngle(v3tangent, vec3.normalize(vectorToOtherTown)) 
	--		if angle2 > 0 then 
				angleToOtherTown = math.min(math.abs(angleToOtherTown), math.abs(angle2))
			if params and params.isCargo then 
				angleToOtherTown = angleToVector -- won't build a connect station
			end 
--			end
		end
	end
	trace("Angle to main town was ",math.deg(angleToVector), " angle to other town was ",math.deg(angleToOtherTown),"raw angle=",angleToOtherTown)
	if angleToOtherTown~=angleToOtherTown then 
		--trace("Nan angle")
		--debugPrint({vectorToOtherTown=vectorToOtherTown, v2tangent=v2tangent})
		--trace(debug.traceback())
		angleToOtherTown=0
	end 
	local perpTangent = vec2.rotate90(v2tangent)
	perpTangent = vec3.new(perpTangent.x, perpTangent.y, 0) -- because v3 supports overloaded math operators
	local v3tangentForTh = sign*vec3.new(v2tangent.x, v2tangent.y ,0) -- want zero z because looking for terrain flatness
	
	local terrainHeightScore = 0
	local nearbyEdges = 0
	local nearbyConstructions = 0 
	local underwaterPoints = 0
	local offset = 40
	local distanceToTownCenter = util.distance(townPos, nodePos)
	local distanceToOtherTown = util.distance(util.v3fromArr(town2.position), nodePos)
	local testPos = nodePos 
	if params.isHighway then 
		testPos = 80*v3tangentForTh+nodePos
		trace("Setting the testPos to",testPos.x,testPos.y,"at",node)
	end 
	for i = -6, 6 do -- walk around the vicinity of the node to discover some properties
		for j = -2, 2 do
			
			local testPos = i*offset * perpTangent + testPos + j*offset*v3tangentForTh
			local terrainHeight = util.th(testPos)
			underwaterPoints = underwaterPoints + util.scoreWaterPoint(testPos) 
			local offsetHeight = math.abs(terrainHeight-nodePos.z)+math.abs(terrainHeight-town.position[3])
			if offsetHeight > 10 then -- only score significant variation
				terrainHeightScore = terrainHeightScore + offsetHeight
			end
			nearbyEdges = nearbyEdges + util.countNearbyEntities(testPos, offset, "BASE_EDGE")
			if town.type == "TOWN" then -- we may use this for industry
				nearbyConstructions = nearbyConstructions + util.countNearbyEntities(testPos, offset, "CONSTRUCTION")
			end 
		end
	end
	if isTerminus and not params.isCargo then -- override some factors
		distanceToOtherTown = vec3.length(nodePos) -- distance to origin
	end
	local interceptAngle = 1
	local completeRouteScore = 0
	if params and params.buildCompleteRoute and not isTerminus then 
		local vec1 = util.vecBetweenTowns(town2, town  )
		local vec2 = util.vecBetweenTowns(town, closestOtherTown   )
		local dist1 = vec3.length(vec1)
		local dist2 = vec3.length(vec2)
		local weightedAverage = (1/dist1)*vec1 + (1/dist2)*vec2 
		local original = angleToVector
		angleToVector = math.abs(util.signedAngle(stationParallelTangent, weightedAverage))
		if angleToVector > math.rad(90) then 
			angleToVector = math.rad(180) - angleToVector -- because the station is symmetric (excluding terminus)
		end
		trace("buildNodeInfo: Computing the angleToVector for ",town.name," otherTown=",town2.name," thirdTown=",closestOtherTown.name, " was ",math.deg(angleToVector), " original was",math.deg(original), " for node ",node)
		trace("vec1=",vec1.x,vec1.y, "vec2=",vec2.x,vec2.y," weightedAverage=",weightedAverage.x, weightedAverage.y," stationParallelTangent=",stationParallelTangent.x,stationParallelTangent.y)
		--distanceToOtherTown = dist1 + dist2
		distanceToOtherTown = util.distance(util.v3fromArr(town2.position), nodePos)+util.distance(util.v3fromArr(closestOtherTown.position), nodePos)
		angleToOtherTown = angleToVector -- to keep the result symmetric
		local v1 = util.v3fromArr(town2.position)-nodePos
		local v2 = nodePos -util.v3fromArr(closestOtherTown.position)
		interceptAngle = math.abs(util.signedAngle(v1,  v2))
		trace("The interceptAngle was",math.deg(interceptAngle), " for ",nodePos.x,nodePos.y)
		completeRouteScore = vec3.length(v1)+vec3.length(v2)
	end
	
	local nearbyBusStops = 0
	if params and params.isTrack then 
		for stationId , station in pairs(util.searchForEntities(nodePos, 100, "STATION")) do
			if util.isBusStop(stationId) then 
				nearbyBusStops = nearbyBusStops + 1
			end
		end
	elseif params and params.isHighway then 
		nearbyBusStops = -util.countNearbyEntities(nodePos, 500, "TOWN_BUILDING") -- abuse this to score away from town building
	end	
	local existingBusStation
	if not params.isCargo then 
		for i, seg in pairs(util.getSegmentsForNode(node)) do 
			local frozenEdge =  util.isFrozenEdge(seg)
			trace("Inspecting frozen edge for node",node," edge",seg," frozen?",frozenEdge)
			if frozenEdge and util.getConstruction(frozenEdge).stations[1] then 
				existingBusStation =  util.getConstruction(frozenEdge).stations[1]
				if not util.getEntity(existingBusStation).cargo then 
					trace("Found existing bus station")
					if not params.isHighway then 
						nearbyBusStops =  1000
						trace("Setting the score high for existing bust station")
					end
				else 
					existingBusStation = nil
				end 
			end 
			
		end 
	end
--[[	if params.isHighway then 
		local streetLanes = util.getNumberOfStreetLanes(edgeId)
		if streetLanes > 4 then 
			trace("Decreasing score for the edge count near edge",edgeId,"for node",node,"streetLanes=",streetLanes,"originalScore=",nearbyEdges)
			nearbyEdges = nearbyEdges / streetLanes
		end 
	end]]-- 
	local streetLaneScore = 4
	local streetLanes = util.getNumberOfStreetLanes(edgeId)
	if streetLanes > 4 then 
		local offset= math.min(4, streetLanes-4)
		streetLaneScore = streetLaneScore - offset 
		trace("Adjusting the streetLaneScore for ",edgeId,"to ",streetLaneScore,"based on streetLanes",streetLanes)
	end 
	local townCenterScore = distanceToTownCenter
	
	
	local otherNode =   util.getOtherNodeForEdge(edgeId, node)
	local otherNodePos = util.nodePos(otherNode)
	local initialNodeInfo = {
		node = node,
		nodePos = nodePos ,
		tangent = v3tangent,
		edgeId = edgeId,
		otherNode= otherNode,
		otherNodePos = otherNodePos,
		isVirtualDeadEnd = isVirtualDeadEnd(node), 
	}
	
	-- score according to whether the station points iinto the town 
	local actualPositionAndRotation = evaluation.getStationPositionAndRotation(town, initialNodeInfo, town2, params, 0, closestOtherTown)
	local testP = actualPositionAndRotation.position + 100*actualPositionAndRotation.stationParallelTangent
	local testP2 = actualPositionAndRotation.position - 100*actualPositionAndRotation.stationParallelTangent
	local v1 = townPos - testP 
	local v2 = townPos - testP2 
	
	local angle1 = math.abs(util.signedAngle(v1, actualPositionAndRotation.stationParallelTangent))
	local angle2 = math.abs(util.signedAngle(v2, -1*actualPositionAndRotation.stationParallelTangent))
	if isTerminus then 
		trace("Not scoring second angle for terminus, was ",math.deg(angle2))
		angle2 = math.rad(90)
	end 
	local angleToUse =  math.min(angle1, angle2)

	local positionToUse = angle1 == angleToUse and testP or testP2 
	local rawDistance = vec2.distance(positionToUse, townPos)
	local closestApproach = rawDistance*math.sin(angleToUse)
	
	local townConflictionScore = math.max(0, rawDistance-closestApproach)
	
	if angleToUse >= math.rad(90) then 
		townConflictionScore = 0 
	end 
	local distanceToOrigin = vec3.length(nodePos)
	if params and params.carrier == api.type.enum.Carrier.AIR then 
		trace("buildNodeInfo inverting scores for airline")
		distanceToOtherTown = -distanceToOtherTown
		distanceToOrigin = -distanceToOrigin
		angleToVector = 0 
		angleToOtherTown =0 
	end 
	trace("buildNodeInfo: inspecting positions",testP.x,testP.y,"and",testP2.x,testP2.y,"the angles were",math.deg(angle1),math.deg(angle2)," the chosen postion was",positionToUse.x,positionToUse.y,"the rawDistance=",rawDistance,"closestApproach=",closestApproach,"townConflictionScore=",townConflictionScore)
	
	return {
		node = node,
		nodePos = nodePos ,
		otherNode = otherNode,
		otherNodePos = otherNodePos,
		tangent = v3tangent,
		edgeId = edgeId,
		isVirtualDeadEnd = isVirtualDeadEnd(node),
		angleToVectorDeg = math.deg(angleToVector),
		angleToOtherTownDeg = math.deg(angleToOtherTown),
		existingBusStation = existingBusStation,
		scores = {
			townCenterScore,
			distanceToOtherTown,
			nearbyEdges,
			nearbyConstructions,
			angleToVector,
			underwaterPoints,
			terrainHeightScore,
			distanceToOrigin,
			angleToOtherTown,
			-nearbyBusStops,
			interceptAngle,
			streetLaneScore,
			townConflictionScore,
			completeRouteScore
		}
	}
	
	
end
	 
local function valid(edge, town, params)
	if not params.checkedEdgesForTown then 
		params.checkedEdgesForTown = {}
	end
	if not params.checkedEdgesForTown[town.id] then 
		params.checkedEdgesForTown[town.id] = {}
	end
	if not  params.checkedEdgesForTown[town.id][edge] then 
		local townCentralEdge =  findUrbanStreetsForTown(town, 100)[1]
		local answer = pathFindingUtil.findRoadPathBetweenEdges(townCentralEdge.id, edge)
		trace("Checking if edge ",edge," is valid for town", town)
		if #answer > 0 then 
			params.checkedEdgesForTown[town.id][edge] = true 
			for i, otherEdge in pairs(answer) do 
				params.checkedEdgesForTown[town.id][otherEdge.entity] = true 
			end 
		end 
	end
	  
	return  params.checkedEdgesForTown[town.id][edge] 

end
local function findDeadEndNodesWithInfo(town, radius, vector, town2, otherTowns, allowVirtualDeadends, params )
	util.cacheNode2SegMapsIfNecessary()
	if params and params.isCompleteRoute then 
		allowVirtualDeadends = true 
	end 
 
	local closestOtherTown = #otherTowns > 0 and util.evaluateWinnerFromSingleScore(otherTowns, function(t) return util.distance(util.v3fromArr(t.position), util.v3fromArr(town.position)) end) or town2
	  
	trace("The cloestOtherTown to ",town.name," was ", closestOtherTown.name)
	if not params then 
		params = {} 
	end
	local result = {}
	local urbanStreets = findUrbanStreetsForTown(town,radius)
	trace("there were ",util.size(urbanStreets), " urban streets for town ",town.name)
	local alreadySeen = {}
	for edgeId, edge in pairs(urbanStreets) do 
		trace("Inspecting edge",edgeId,"for town ",town.name," for possible dead end nodes")
		if isDeadEnd(edge.node0, allowVirtualDeadends, alreadySeen, town, params) and valid(edge.id, town, params) then
			result[edge.node0]=buildNodeInfo(edge.id, vector, edge.node0, edge.node0pos, edge.node0tangent, -1, town, town2,closestOtherTown, params)
		end 
		if isDeadEnd(edge.node1, allowVirtualDeadends, alreadySeen, town, params) and valid(edge.id, town,  params) then
			result[edge.node1]=buildNodeInfo(edge.id, vector, edge.node1, edge.node1pos, edge.node1tangent, 1, town,town2, closestOtherTown, params)
		end
	end
	local resultCount = util.size(result) 
	if params.includeCountryNodes then 
		for i, node in pairs(util.searchForUncongestedDeadEndOrCountryNodes(util.v3fromArr(town.position), radius)) do 
			local edge = util.getEntity(util.getStreetSegmentsForNode(node)[1])
			if edge.node0 == node then  
				result[edge.node0]=buildNodeInfo(edge.id, vector, edge.node0, edge.node0pos, edge.node0tangent, -1, town, town2,closestOtherTown, params)
 			else 
				result[edge.node1]=buildNodeInfo(edge.id, vector, edge.node1, edge.node1pos, edge.node1tangent, 1, town,town2, closestOtherTown, params)
			end 
		end 
	end 
	
	trace("The result count was ",resultCount," for town",town.name, " allowVirtualDeadends?",allowVirtualDeadends)
	if resultCount == 0 and not allowVirtualDeadends then 
		trace("No results found, trying with allowVirtualDeadends")
		return findDeadEndNodesWithInfo(town, radius, vector, town2, otherTowns, true, params, closestOtherTown)
	end
	return result
end

function evaluation.evaluateBestIndustryStationLocations(town1, town2, params)

	util.lazyCacheNode2SegMaps()
	local searchRadius = math.min(500, math.floor(util.distanceArr(town1.position, town2.position)/2.1))
	trace("Getting best locations, searchRadius was ", searchRadius)
	local straightlinevec = getVectorBetweenTowns(town1, town2)
	local perpvector = vec2.rotate90(straightlinevec) 
	local otherTowns = {} 
	for i, otherTown in pairs(getAllTowns() ) do 
		if otherTown.id ~= town1.id and otherTown.id ~= town2.id then 
			table.insert(otherTowns, otherTown)
		end
	end
--	local town1Vector = evaluation.shouldBuildTerminus(town1) and straightlinevec or perpvector
	--local town2Vector = evaluation.shouldBuildTerminus(town2) and straightlinevec or perpvector
	if not params.buildTerminus then 
		params.buildTerminus = { [town1.id]=true, [town2.id]=true} 
	end 
	local town2Nodes = findDeadEndNodesWithInfo(town2,searchRadius,perpvector, town1, otherTowns, true, params)  
	local scoreWeights = params and params.stationLocationScoreWeights or paramHelper.getParams().railPassengerStationScoreWeights
  
   
 	return util.evaluateWinnerFromScores(town2Nodes, scoreWeights, nil, true)
end 
function evaluation.evaluateBestPassengerStationLocation(town, otherTown, otherTown2, params, thirdTown)
	local searchRadius = math.min(750, math.floor(util.distanceArr(town.position, otherTown.position)/2.1))
	if otherTown2 then 
		searchRadius = math.min(searchRadius, math.floor(util.distanceArr(town.position, otherTown2.position)/2.1))
	end
	trace("Getting best locations, searchRadius was ", searchRadius)
	local straightlinevec = getVectorBetweenTowns(town, otherTown)
	local perpvector = vec2.rotate90(straightlinevec) 
	local otherTowns = {otherTown2} 
 
	if not params.buildTerminus then params.buildTerminus = {} end
--	local town1Vector = evaluation.shouldBuildTerminus(town1) and straightlinevec or perpvector
	--local town2Vector = evaluation.shouldBuildTerminus(town2) and straightlinevec or perpvector
	local town1Nodes = findDeadEndNodesWithInfo(town,searchRadius,perpvector, otherTown, otherTowns, not (params.buildTerminus and params.buildTerminus[town.id]) or params and params.isHighway, params) 
	local count = util.size(town1Nodes)
	trace("Count of matching nodes was ", count)
	if count == 0 then 
		town1Nodes = findDeadEndNodesWithInfo(town,searchRadius,perpvector, otherTown, otherTowns, true, params) 
	end
	local count = util.size(town1Nodes)
	if count == 0 then 
		trace("WARNING! No nodes found, attempting again")
		params = util.deepClone(params)
		params.extendedNodeSearch = true
		town1Nodes = findDeadEndNodesWithInfo(town,searchRadius,perpvector, otherTown, otherTowns, true, params) 
		if count == 0 then 
			params.includeCountryNodes = true 
			town1Nodes = findDeadEndNodesWithInfo(town,searchRadius,perpvector, otherTown, otherTowns, true, params) 
			
		end 
	end 

	local scoreWeights = params and params.stationLocationScoreWeights or paramHelper.getParams().railPassengerStationScoreWeights
	return util.evaluateAndSortFromScores(town1Nodes, scoreWeights)
end
function evaluation.evaluateBestPassengerStationLocations(town1, town2, params)
	util.lazyCacheNode2SegMaps()
	local searchRadius = math.min(750, math.floor(util.distanceArr(town1.position, town2.position)/2.1))
	trace("Getting best locations, searchRadius was ", searchRadius, " for towns ",town1.name, town2.name)
	local straightlinevec = getVectorBetweenTowns(town1, town2)
	local perpvector = vec2.rotate90(straightlinevec) 
	local otherTowns1 = {} 
	local otherTowns2 = {} 
	if not params.buildTerminus then params.buildTerminus = {} end
	local allowVirtualDeadends1 = not (params.buildTerminus and params.buildTerminus[town1.id]) or params and params.isHighway
	local allowVirtualDeadends2 = not (params.buildTerminus and params.buildTerminus[town2.id]) or params and params.isHighway
	if params.connectionLookup then 
		for otherTownId, bool in pairs(params.connectionLookup[town1.id]) do 
			if otherTownId ~= town2.id then 
				local otherTown = util.getEntity(otherTownId)
				local vec = getVectorBetweenTowns(otherTown, town1)
				local angle = math.abs(util.signedAngle(straightlinevec, vec))
				trace("insepcting angle to ",otherTown.name, " the angles were ", math.deg(angle))
				if angle < math.rad(90) then 
					table.insert(otherTowns1, otherTown)
				end 
			end			
		end 
		for otherTownId, bool in pairs(params.connectionLookup[town2.id]) do 
			if otherTownId ~= town1.id then 
				local otherTown = util.getEntity(otherTownId)
				local vec = getVectorBetweenTowns(town2, otherTown)
				local angle = math.abs(util.signedAngle(straightlinevec, vec))
				trace("insepcting angle to ",otherTown.name, " the angles were ", math.deg(angle))
				if angle < math.rad(90) then 
					table.insert(otherTowns2, otherTown)
				end 
			end			
		end 
	else 
		for i, otherTown in pairs(getAllTowns() ) do 
			if otherTown.id ~= town1.id and otherTown.id ~= town2.id then 
				local vec1 = getVectorBetweenTowns(otherTown, town1)
				local vec2 = getVectorBetweenTowns(town2, otherTown)
				local angle1 = math.abs(util.signedAngle(straightlinevec, vec1))
				local angle2 = math.abs(util.signedAngle(straightlinevec, vec2))
				trace("insepcting angle to ",otherTown.name, " the angles were ", math.deg(angle1), " and ",math.deg(angle2))
				if angle1 < math.rad(90) then 
					table.insert(otherTowns1, otherTown)
				else 
					trace("Rejecting ",otherTown.name, " for ", town1.name, " as the angle was too high at ",math.deg(angle1))
				end 
				if angle2 < math.rad(90) then 
					table.insert(otherTowns2, otherTown)
				else 
					trace("Rejecting ",otherTown.name, " for ", town2.name, " as the angle was too high at ",math.deg(angle2))
				end  
			end
		end
	end

--	local town1Vector = evaluation.shouldBuildTerminus(town1) and straightlinevec or perpvector
	--local town2Vector = evaluation.shouldBuildTerminus(town2) and straightlinevec or perpvector
	local town1Nodes = findDeadEndNodesWithInfo(town1,searchRadius,perpvector, town2, otherTowns1, allowVirtualDeadends1, params) 
	local town2Nodes = findDeadEndNodesWithInfo(town2,searchRadius,perpvector, town1, otherTowns2, allowVirtualDeadends2, params)  
	local scoreWeights = params and params.stationLocationScoreWeights or paramHelper.getParams().railPassengerStationScoreWeights
	local node1 = util.evaluateWinnerFromScores(town1Nodes, scoreWeights, nil, true)
	local node2 = util.evaluateWinnerFromScores(town2Nodes, scoreWeights, nil, true)
	local result = 	 { node1, node2 }
	if util.tracelog then debugPrint({bestNodes=result}) end
 
 	return result
end

local function checkForPersonsInTown1WithDestsInTown2(townId1, townId2) 
	trace("Begin checkForPersonsInTown1WithDestsInTown2",townId1, townId2)
	local buildings1 =  getTown2BuildingMap()[townId1]
	local persons1 = {}
	for i, building in pairs(buildings1) do 
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(building)
		local simPersons = api.engine.system.simPersonSystem.getSimPersonsForTarget(constructionId) -- assignment to avoid gc
		for j, personId in pairs(simPersons) do 
			persons1[personId]= true	
		end
	end
	
	local otherTownDests = {}
	for i, building in pairs(getTown2BuildingMap()[townId2]) do
		otherTownDests[ api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(building)]=true
	end
	
	trace("checkForPersonsInTown1WithDestsInTown2: setup dets now checking persons")
	for personId, bool in pairs(persons1) do
		local person = util.getComponent(personId, api.type.ComponentType.SIM_PERSON)
		for i, destination in pairs(person.destinations) do 
			if otherTownDests[destination] and person.moveModes[i]==2 then -- 0 == WALK, 1 == CAR, 2 == PUBLIC TRANSPORT
				 trace("found a person connecting ",townId1," and ", townId2, "personId=",personId,"person.moveModes[i]=",person.moveModes[i],"destination was",destination)
				return true
			end
		end
	end
	 trace("No overlap found between ",townId1," and ", townId2)
	return false
end

local function checkForOverlappingDestinations(townId1, townId2)
	if game.interface.getTownReachability(townId1)[2]==0
	or game.interface.getTownReachability(townId2)[2]==0 then -- performance shortcut
		return false
	end
	 trace("Both towns had reachability, about to check dests")
	return  checkForPersonsInTown1WithDestsInTown2(townId1, townId2) 
	or  checkForPersonsInTown1WithDestsInTown2(townId2, townId1) 
end
local function getResidentialCapacityOfTown(townId)
	local town = util.getComponent(townId, api.type.ComponentType.TOWN)
	return town.initialLandUseCapacities[1]*town.sizeFactor
end

function evaluation.getTruckStationsToBuild(result)
	local truckStationsToBuild = {}
	 
	evaluation.recheckResultForStations(result, true, api.type.enum.Carrier.ROAD)
	if not result.station1 then 
		table.insert(truckStationsToBuild, evaluation.getTruckStationToBuild(result.industry1, result.cargoType, 1, result.p0, result.p1))
	end
	if not result.station2 and not result.isTown then
		table.insert(truckStationsToBuild, evaluation.getTruckStationToBuild(result.industry2, result.cargoType, 2, result.p1, result.p0))
	end
	
	return truckStationsToBuild
end

function evaluation.getTruckStationToBuild(industry, cargoType, index, p0, p1)
	p0 = util.v3(p0, true) -- may have been serialized and lost the metatable
	p1 = util.v3(p1, true)
	return {
		edge = findEdgeForIndustryOrTown(industry, cargoType),
		name= industry.name, 
		position=p0, 
		index=index, 
		routeVector = p1-p0, 
		otherPosition = p1 ,
		
	}
end 

function evaluation.evaluateNewIndustryConnectionWithRoads(circle, param ) 
	local options = {}
	local begin = os.clock()
	util.lazyCacheNode2SegMaps()
	
	print("[EVAL_TRACE] === evaluateNewIndustryConnectionWithRoads START ===")
	print("[EVAL_TRACE] param.cargoFilter=" .. tostring(param.cargoFilter))
	print("[EVAL_TRACE] param.maxDist=" .. tostring(param.maxDist))
	
	local finishedTown2Build = os.clock()
	if not param.maxDist then param.maxDist = paramHelper.getParams().maximumTruckDistance end
	trace("Copies town2BuildingMap in ",(finishedTown2Build-begin))
	local filterFn = function(industryPair)
		local pairCargo = industryPair[6]
		if param.cargoFilter and param.cargoFilter ~= "" then
			if pairCargo ~= param.cargoFilter then
				print("[EVAL_TRACE] REJECT: wanted " .. tostring(param.cargoFilter) .. " got " .. tostring(pairCargo))
				return false
			else
				print("[EVAL_TRACE] ACCEPT: cargo matches " .. tostring(pairCargo))
			end
		end

		local distance = industryPair[5]
		if evaluation.isAutoBuildMode and industryPair[2].type == "TOWN" then
			distance = distance / 2
		end
		local maxLineRate = industryPair[8] or industryPair[7]
		if maxLineRate and evaluation.isAutoBuildMode then
			if util.year() < 1900 and maxLineRate > 200 then
				-- CLAUDE CONTROL: Skip rate check when preSelectedPair is set
				if not (param and param.preSelectedPair) then
					print("[EVAL_TRACE] REJECT: rate too high " .. tostring(maxLineRate))
					trace("Rejecting ",industryPair[1].id," for road route as rate is too high", maxLineRate, "rates were", industryPair[8] , industryPair[7])
					return false
				else
					print("[EVAL_TRACE] BYPASS: rate check (preSelectedPair set)")
				end
			end
		end
		local distCheck = evaluation.getDistFilter(param)(distance,industryPair[1], industryPair[2])
		local failedCheck = evaluation.checkIfFailed(api.type.enum.Carrier.ROAD, industryPair[1].id, industryPair[2].id)
		local completedCheck = evaluation.checkIfCompleted(api.type.enum.Carrier.ROAD, industryPair[1].id, industryPair[2].id)
		print("[EVAL_TRACE] filterFn checks: distCheck=" .. tostring(distCheck) .. " failedCheck=" .. tostring(failedCheck) .. " completedCheck=" .. tostring(completedCheck))
		return distCheck and not failedCheck and not completedCheck
	end
	local industryToEdgeCache = {}
	local function findEdgeForIndustryCached(industry, cargoType) 
		if industry.type == "TOWN" then 
			return findEdgeForIndustryOrTown(industry, cargoType)
		end
		if not industryToEdgeCache[industry.id] then 
			industryToEdgeCache[industry.id]=findEdgeForIndustry(industry)
		end
		return industryToEdgeCache[industry.id] 
	end
	local mode = api.type.enum.TransportMode.TRUCK
	local industryToDestNodesCache = {}
	local function findDestNodesCached(edgeId)
		if not industryToDestNodesCache[edgeId] then 
			local destNodes = {}
			local tnEdge = util.getComponent(edgeId,api.type.ComponentType.TRANSPORT_NETWORK)
			for i, tn in pairs(tnEdge.edges) do
					--debugPrint(tn)
				if tn.transportModes[1+mode]==1 then
					trace("transport node dest found inserting for i",i)
					table.insert(destNodes, api.type.NodeId.new(tn.conns[1].entity, tn.conns[1].index))
					table.insert(destNodes, api.type.NodeId.new(tn.conns[2].entity, tn.conns[2].index))
					break
				else
					--trace("transport mode not applicable",i)
				end
			end
			industryToDestNodesCache[edgeId]=destNodes
		end
		return industryToDestNodesCache[edgeId]
	end
	
	local startingEdgesCached = {} 
	local function getStartingEdgesCached(edgeId) 
		if not startingEdgesCached[edgeId] then 
			local startingEdges = {}
			for i, tn in pairs(util.getComponent(edgeId,api.type.ComponentType.TRANSPORT_NETWORK).edges) do
				--debugPrint(tn)
				
				if tn.transportModes[1+mode]==1 then
					local edgeIdFull = api.type.EdgeId.new(edgeId, i)
					table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(edgeIdFull, true, 0))
					table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(edgeIdFull, false, 0))
					break
				end
			end
			startingEdgesCached[edgeId]=startingEdges
		end
		return startingEdgesCached[edgeId]
	end
	
	local industryPairs = findMatchingIndustries(circle,true, filterFn, param.maxDist, nil, true, param)
	if #industryPairs == 0 and circle.radius ~= math.huge then 
		local circle2= {radius=math.huge} 
		industryPairs = findMatchingIndustries(circle,true, filterFn, param.maxDist, circle2, true, param)
		if #industryPairs == 0 then
			industryPairs = findMatchingIndustries(circle2,true, filterFn, param.maxDist, circle, true, param)
		end
	end

	print("[EVAL_TRACE] industryPairs count = " .. tostring(#industryPairs))
	for i, industryPair in pairs(industryPairs) do
		print("[EVAL_TRACE] Processing pair " .. tostring(i) .. ": " .. tostring(industryPair[1] and industryPair[1].name or "nil") .. " -> " .. tostring(industryPair[2] and industryPair[2].name or "nil"))
		local industry = industryPair[1]
		local industry2 = industryPair[2]
		local p0 = industryPair[3]
		local p1 = industryPair[4]
		local distance = industryPair[5]  
		local station1 = checkIfIndustryHasTruckStation(industry)
		local station2 = checkIfIndustryHasTruckStation(industry2)
		local cargoType = industryPair[6] 
		local edge2 = findEdgeForIndustryCached(industry2, cargoType)
		if industry2.type == "TOWN" and not station2 and edge2 then 
			station2 = checkIfEdgeHasNearbyTruckStop(edge2.id)
			trace("Trying to find a truck stop near edge",edge2.id," found?",station2)
		end 
	
		local initialTargetLineRate = industryPair[7]
		local isPrimaryIndustry = industryPair[9]
		if  evaluation.checkIfLineIsAlreadyCarryingCargo({ station1 = station1, station2=station2,cargoType=cargoType} ) then
			trace("industry already has a connection between ", industry.name, " and ", industry2.name, " skipping.")
			goto continue 
		end
		
		
		local edge   = findEdgeForIndustryCached(industry, cargoType)
		
		trace("straight line distance between ", industry.name, " and ", industry2.name, " was ", distance)
	
		
		
		 
		local transportModes = {   api.type.enum.TransportMode.TRUCK} 
		trace("Attempting to find path")
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		local answer = edge and edge2  and distance < 8000 and pathFindingUtil.findPath(  getStartingEdgesCached(edge.id)  , findDestNodesCached(edge2.id), transportModes, 4*distance) or {}
		local roadDistance = 2^31 -- can't use math.huge as it results in a NaN in scoring
		local needsNewRoute = #answer==0
		if #answer == 0 then
			debuglog("NO path was found between ", industry.name, " and ", industry2.name)
		else
			roadDistance = util.estimateRouteLength(answer);
			debuglog("a path WAS found between ", industry.name, " and ", industry2.name, " with ", #answer, " answers. Distance estimate: ",roadDistance," compare to straight line distance of ", distance)
			
		end 
		-- CLAUDE CONTROL: Allow zero initialTargetLineRate when preSelectedPair is set
		local bypassRateCheck = param and param.preSelectedPair
		if not bypassRateCheck and initialTargetLineRate == 0 then
			--trace("Skipping   ", industry.name, " and ", industry2.name " as initialTargetLineRate was zero")
			goto continue
		end
		if bypassRateCheck and initialTargetLineRate == 0 then
			initialTargetLineRate = 50 -- Default rate when Claude is forcing the connection
		end
		local isTown = industry2.type=="TOWN"
		local townScore = isTown and 0 or 1 -- prefer Town delivery, suited to trucks
		if industry.type == "TOWN" then 
			trace("Overriding the town score to 2")
			townScore = 2 -- town source is less good 
			
		end 
		local scores = {}
		scores[1] = distance 
		scores[2] = util.scoreTerrainBetweenPoints(p0, p1)
		local gradient = math.abs(util.gradientBetweenPoints(p0, p1))
		scores[3] = gradient > 0.01 and gradient or 0
		scores[4] = roadDistance / distance -- very rough road length to distance 
		scores[5] = util.scoreWaterBetweenPoints(p0, p1)
		scores[6] = isFarm(industry) and 0 or 1 -- prefer farms for trucks, less capacity and fields that get in the way
		scores[7] = townScore
		scores[8] = initialTargetLineRate -- lower is better (more suited to trucks)
		if roadDistance / distance > paramHelper.getParams().truckRouteToDistanceLimit then
			needsNewRoute = true
		end

		local stopName 
		if isTown then 
			stopName = _(industry2.name).." ".._(api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(cargoType)).name).." ".._("Delivery")
		end 
		
		
		table.insert(options, {
			industry1=industry,
			industry2=industry2, 
			edge1=edge,
			edge2=edge2,
			scores=scores,
			routeLength=roadDistance,
			needsNewRoute=needsNewRoute, 
			routeVector = p1-p0,
			p0=p0,
			p1=p1, 
			station1 = station1,
			station2 = station2,
			isTown = isTown,
			route = answer,
			initialTargetLineRate = initialTargetLineRate,
			distance = distance,
			stopName = stopName,
			cargoType= cargoType,
			isPrimaryIndustry =isPrimaryIndustry,
			})
		debuglog("end of loop iteration, lua used memory=",api.util.getLuaUsedMemory())
		::continue::
	end	 
	local weights = 
	{
		25, -- distance
		25, -- roughness of terrain 
		50, -- height gradient 
		50, -- road distance
		50, -- waterPoints 
		15, -- farm penalty 
		50, -- is town 
		100, -- line rate
	}
	if evaluation.isAutoBuildMode then 
		weights[1]=100 
	end 
	 
	if #options == 0 then 
		print("[EVAL_TRACE] === NO OPTIONS FOUND - returning nil ===")
		print("[EVAL_TRACE] cargoFilter was: " .. tostring(param.cargoFilter))
		return 
	end
	print("[EVAL_TRACE] Found " .. #options .. " valid options for cargoFilter=" .. tostring(param.cargoFilter))
	trace("[LLM_DEBUG] evaluateNewIndustryConnectionWithRoads: options=" .. #options .. " resultsToReturn=" .. tostring(param.resultsToReturn))
	if not param.resultsToReturn then
		clearCaches()
		trace("[LLM_DEBUG] Calling evaluateWinnerWithLLM with " .. #options .. " options")
		-- Use LLM-powered selection when daemon available, falls back to heuristic
		return util.evaluateWinnerWithLLM(options, weights, nil, {type = "truck_route"})
	end
	local allResults = util.evaluateAndSortFromScores(options, weights)
	evaluation.setupDisplayScores(allResults)
	local results = {}
	for i = 1, math.min(param.resultsToReturn, #allResults) do
		table.insert(results, allResults[i])
	end
	return results
end

function evaluation.findBestConnectionNodeForTown(town, connectTown)
	if type(town) == "number" then 
		town = util.getEntity(town)
	end
	if type(connectTown)=="number" then 
		connectTown = util.getEntity(connectTown)
	end
	--assert(town.id~=connectTown.id)
	local vector = getVectorBetweenTowns(town, connectTown) -- N.B. this is normalized
 
	if distBetweenTowns(town, connectTown) < 500 then 
		
		local p = util.v3fromArr(connectTown.position)
		trace("findBestConnectionNodeForTown: Short connect distance discovered, examining position at",p.x,p.y,"dist was",distBetweenTowns(town, connectTown))
		if util.tracelog then 
			debugPrint({town=town, connectTown=connectTown})
		end 
		local centralNode =  util.findMostCentralTownNode(town)
		local result = util.searchForNearestNode(p, 250, function(node) 
			if #util.getTrackSegmentsForNode(node.id) > 0 then 
				return false 
			end 
			if util.isFrozenNode(node.id) then 
				return false 
			end
			local streetSegs =util.getStreetSegmentsForNode(node.id) 
			if #streetSegs > 3 then 	
				return false 
			end
			local deltaZ = math.abs(node.position[3]-p.z)
			local distance = vec2.distance(p, util.v3fromArr(node.position))
			local grad = deltaZ / distance
			if grad  > 0.2 then 
				trace("Rejecting node",node.id," as the grad is ",grad,"based on deltaz",deltaz," at distance",distance)
				return false 
			end
			if #pathFindingUtil.findRoadPathBetweenNodes(node.id, centralNode.id) == 0 then 
				return false 
			end
			if #streetSegs == 3 or #streetSegs == 1 then 
				local tangent = #streetSegs == 3 and util.getOutboundNodeDetailsForTJunction(node.id).tangent or util.getDeadEndNodeDetails(node.id).tangent
				local angleToVector = math.abs(util.signedAngle(-1*tangent, vector))
				if angleToVector > math.rad(90) then 
					trace("Rejecting t-junction node",node.id,"as the angleToVector is too high",math.deg(angleToVector),"#streetSegs=",#streetSegs)
					return false
				end
			end 
			if #streetSegs == 2 and not util.isCornerNode(node.id) then 
				local edge = util.getEdge(streetSegs[1])
				local tangent = edge.node0 == node.id and edge.tangent0 or edge.tangent1
				local angleToVector = math.abs(util.signedAngle(tangent, vector))
				if angleToVector < math.rad(90) then 
					trace("Rejecting the node",node.id," as the angle is too shallow",math.deg(angleToVector))
					return false
				end 
 			end 
			return true
		end)
		if result then 
			return result.id  
		end
		
	end 
	
	
	local nodes = findDeadEndNodesWithInfo(town,500,vector, connectTown, {connectTown}, true) 
	trace("The number of nodes was ",#nodes)
	if #nodes == 0 then 
		nodes = findDeadEndNodesWithInfo(town,750,vector, connectTown, {connectTown}, true)
		trace("Attempting again with larger radius, nodes found=",#nodes)
	end 
	return util.evaluateWinnerFromScores(nodes, paramHelper.getParams().townRoadConnectionScoreWeights).node
end


local function getBestNodeForIndusty(industry, otherIndustry, hasStationB, station) 
	if industry.type=="TOWN" then 
		return evaluation.findBestConnectionNodeForTown(industry, otherIndustry)
	end
	if hasStationB then 
		local edge = findEdgeForIndustry(industry, 250, hasStationB, station)
		if edge and not util.edgeHasTpLinksToStation(edge.id) then 
			return util.getDeadEndTangentAndDetailsForEdge(edge.id).node
		end
	end
	local options =  {}
	local connectionEdge = findEdgeForIndustry(industry, 250, hasStationB, station)
	for i, node in pairs(util.searchForDeadEndNodes(industry.position, 250, true))do 
		local edge = util.getSegmentsForNode(node)[1]
		if util.getStreetTypeCategory(edge) == "highway" then 
			goto continue
		end
		local isEntrance =  util.getStreetTypeCategory(edge) == "entrance"
		if isEntrance then 
			if not connectionEdge then 
				local constructionId = util.isNodeConnectedToFrozenEdge(node)
				if constructionId then 
					local construction = util.getConstruction(constructionId)
					if construction.stations[1] then  
						if util.checkIfStationInCatchmentArea(construction.stations[1], getConstructionId(industry.id)) then 
							trace("getBestNodeForIndusty: Returning node",node,"for direct connection as no connectionEdge was found")
							return node 
						end 
					end 
					 
				end 
				
 
			end  
			goto continue 
			 
		end 
		if not connectionEdge then 
			goto continue 
		end
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
		if constructionId ~= -1 then 
			local construction = util.getConstruction(constructionId) 
			if construction.depots[1] then 
				goto continue 
			end
		end 
		--for i, seg in pairs do 
		
		--end 
		
		if #pathFindingUtil.findRoadPathBetweenNodes(node, connectionEdge.node0)>0 then 
			trace("Checking node",node," as a path was found with",connectionEdge.node0)
			table.insert(options, {
				node=node,
				scores = { 
					util.distance(util.nodePos(node), util.v3fromArr(otherIndustry.position))
				}
			})
		else 
			trace("Ignoring node",node," as no path was found to",connectionEdge.node0)
		end 
		::continue::
	end	
	if #options == 0 then
		local edge = findEdgeForIndustry(industry, 250, hasStationB)
		if edge then 
			for i, node in pairs({edge.node0, edge.node1}) do
			table.insert(options, {
				node=node,
				scores = { 
					util.distance(util.nodePos(node), util.v3fromArr(otherIndustry.position))
				}
			})
			end
		end 
	end
	return util.evaluateWinnerFromScores(options).node
end

evaluation.getBestNodeForIndusty = getBestNodeForIndusty

function evaluation.findNodePairForResult(result, hasStationB, stations)
	trace("findNodePairForResult: begin")
	if not result or not result.industry1 or not result.industry2 then
		trace("findNodePairForResult: result or industries are nil, aborting")
		return nil
	end
	local node1
	if result.industry1.type=="TOWN" then 
		node1 = evaluation.findBestConnectionNodeForTown(result.industry1, result.industry2)
	else 
		node1 = getBestNodeForIndusty(result.industry1, result.industry2, hasStationB[1], stations[1]) 
	end 
	
	local node2
	
	if result.industry2.type=="TOWN" then 
		node2 = evaluation.findBestConnectionNodeForTown(result.industry2, result.industry1)
	else 
		node2 = getBestNodeForIndusty(result.industry2, result.industry1, hasStationB[2], stations[2]) 
	end
	trace("findNodePairForResult: found nodes",node1,node2)
	return { node1,node2 }
end
function evaluation.checkIfLineIsAlreadyCarryingCargo(result) 
	local lineId = util.areStationsConnectedWithLine(result.station1, result.station2) 
	local existingCargoType
	if lineId then 
		--[[
		for i, simCargoId in pairs(util.deepClone(api.engine.system.simCargoSystem.getSimCargosForLine(lineId)))do 
			local simCargo = util.getComponent(simCargoId, api.type.ComponentType.SIM_CARGO)
			if simCargo then 
				existingCargoType = api.res.cargoTypeRep.getName(simCargo.cargoType)
				break 
			end 
		end ]]--
		existingCargoType = evaluation.lineManager.discoverLineCargoType(lineId)	
	end 
	trace("Comparing the line ",lineId,"existingCargoType=",existingCargoType," result cargo =", result.cargoType)
	if existingCargoType then 
		if not evaluation.cargoTypeSet then 
			discoverIndustryData()
		end 
		return evaluation.cargoTypeSet[result.cargoType]==evaluation.cargoTypeSet[existingCargoType]
	end 
	return result.cargoType == existingCargoType 
	
end
function evaluation.checkIfIndustriesAlreadyConnected(industry1, industry2, cargoType)
	local function filterToCatchmentArea1(station)
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry1.id) 
		if constructionId == -1 then 
			trace("WARNING! No construction found for ",industry1.name,industry1.id)
			return false 
		end 
		local res = util.checkIfStationInCatchmentArea(station.id, constructionId)
		trace("Result of checking if station",station.id,station.name,"within catchmentarea of ",industry1.name,"was",res)
		return res 
	end 
	trace("checkIfIndustriesAlreadyConnected: begin check:",industry1.name,industry2.name)
	local stations1 =  util.searchForEntitiesWithFilter(industry1.position, 500, "STATION", filterToCatchmentArea1)

	local function filterToCatchmentArea2(station)
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry2.id) 
		if constructionId == -1 then 
			trace("WARNING! No construction found for ",industry2.name,industry2.id)
			return false 
		end 
		return util.checkIfStationInCatchmentArea(station.id, constructionId) 
	end 	 
	local stations2 =  util.searchForEntitiesWithFilter(industry2.position, 500, "STATION", filterToCatchmentArea2)
	local cargoDetail = api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(cargoType))
	local cargoTypeName = _(cargoDetail.name)
	trace("checkIfIndustriesAlreadyConnected: ",industry1.name,industry2.name,"got stations",#stations1,#stations2)
	if util.tracelog then 
		debugPrint({stations1=stations1,stations2=stations2})
	end 
	for i, station1 in pairs(stations1) do 
		for j, station2 in pairs(stations2) do 
			local lineId = util.areStationsConnectedWithLine(station1.id, station2.id) 
			trace("checkIfIndustriesAlreadyConnected: inspecting station pair",station1.name,station2.name)
			if lineId then 
				local existingCargoType = evaluation.lineManager.discoverLineCargoType(lineId)	
				if type(existingCargoType) == "number" then 
					existingCargoType = api.res.cargoTypeRep.getName(existingCargoType)
				end 
				trace("checkIfIndustriesAlreadyConnected: Discovered line with existing cargoType",existingCargoType,"comparing to carrier cargoType",cargoType)
				if existingCargoType == cargoType then 
					return true
				end 
			end 
		end 
	end 
end  

function evaluation.evaluateNewIndustryConnectionForTrains(circle, param )
	local dbg = io.open('/tmp/tf2_eval_trace.txt', 'w')
	dbg:write('START evaluateNewIndustryConnectionForTrains\n')
	--collectgarbage()
	dbg:write('STEP 1: lazyCacheNode2SegMaps\n')
	util.lazyCacheNode2SegMaps()
	dbg:write('STEP 1 done\n')
	local options = {}
	if not param then param = {} end
	dbg:write('STEP 2: getParams\n')
	if not param.minDist then param.minDist = paramHelper.getParams().minimumCargoTrainDistance end
	dbg:write('STEP 2 done\n')

	local filterFn = function(industryPair)
		local distance = industryPair[5]
		return  evaluation.getDistFilter(param)(distance,industryPair[1], industryPair[2])
		and not evaluation.checkIfFailed(api.type.enum.Carrier.RAIL, industryPair[1].id, industryPair[2].id)
		and not evaluation.checkIfCompleted(api.type.enum.Carrier.RAIL, industryPair[1].id, industryPair[2].id)
		and (not evaluation.isAutoBuildMode or industryPair[7] >= 50)
	end
	local includeTowns = true
	dbg:write('STEP 3: findMatchingIndustries\n')
	local industryPairs = findMatchingIndustries(circle,includeTowns, filterFn, param.maxDist, nil, false, param)
	dbg:write('STEP 3 done, #industryPairs=' .. tostring(#industryPairs) .. '\n')

	if #industryPairs == 0 and circle.radius ~= math.huge then 
		local circle2= {radius=math.huge} 
		industryPairs = findMatchingIndustries(circle,includeTowns, filterFn, param.maxDist, circle2, false, param)
		if #industryPairs == 0 then 
			industryPairs = findMatchingIndustries(circle2,includeTowns, filterFn, param.maxDist, circle, false, param)
		end
	end  
	local isMaxDistanceMode = evaluation.isAutoBuildMode and false
	for i, industryPair in pairs(industryPairs) do
		local industry = industryPair[1]
		local industry2 = industryPair[2]
		local p0 = industryPair[3]
		local p1 = industryPair[4]
		local distance = industryPair[5] 
		local cargoType = industryPair[6]
		if not p0 or not p1 then 
			debugPrint({industryPair=industryPair})
		end
		 
		local station1 = evaluation.checkForAppropriateCargoStation(industry, api.type.enum.Carrier.RAIL ) 
		local station2 = evaluation.checkForAppropriateCargoStation(industry2, api.type.enum.Carrier.RAIL ) 
		local initialTargetLineRate = industryPair[7]
		local isTown = industry2.type=="TOWN"
		local scores = {}
	 	scores[1] = isMaxDistanceMode and -distance or distance
		--scores[1] = distance
		scores[2] = util.scoreTerrainBetweenPoints(p0, p1)
		local gradient = math.abs(util.gradientBetweenPoints(p0, p1))
		scores[3] = gradient > 0.01 and gradient or 0 -- don't score trivial gradients  
		scores[4] = util.scoreWaterBetweenPoints(p0,p1)
		scores[5] = isFarm(industry) and 1 or 0 -- tend to avoid farms for trains because of low production and costly field removal
		scores[6] = util.scoreEdgeCountBetweenPoints(p0,p1)
		scores[7] = -initialTargetLineRate -- prefer higher initial rates
		scores[8] = isTown and 1 or 0 -- prefer not Town delivery as more complicated for trains
		table.insert(options,
			{
				industry1=industry, 
				industry2=industry2,
				edge1=edge, 
				edge2=edge2,
				scores=scores, 
				straightlinevec=p0-p1,
				station1=station1, 
				station2=station2, 
				initialTargetLineRate = initialTargetLineRate,
				distance=distance ,
				cargoType=cargoType, 
				isCargo=true,
				carrier = api.type.enum.Carrier.RAIL,
				p0 = p0, 
				p1 = p1,
			})
	end
	if #options == 0 then 
		
		return 
	end
	local weights =  
	{
		25, -- distance
		25, -- roughness of terrain 
		75, -- height gradient 
		50, -- waterPoints 
		15, -- farm penalty
		15, -- edges
		100, -- line rate
		50, -- is town
	}
	if isMaxDistanceMode then 
		 weights[1]=100 
	end
	local resultsTo = param.resultsToReturn and math.min(#options, param.resultsToReturn) or 1

	local results = {} 
	local rawresults = util.evaluateAndSortFromScores(options, weights)
	if param.resultsToReturn then 
		evaluation.setupDisplayScores(rawresults) 
	end
	for i = 1, math.min(resultsTo, #rawresults) do 
		local result = rawresults[i]
		result.isTown = result.industry2.type == "TOWN"
		--result.cargoType = util.discoverCargoType(result.industry1)
		--result.edge1   = findEdgeForIndustry(result.industry1)
		--result.edge2   = findEdgeForIndustryOrTown(result.industry2, result.cargoType) 
		result.station1 = checkIfIndustryHasRailStation(result.industry1)
		result.station2 = checkIfIndustryHasRailStation(result.industry2)
		
		 
		if result.isTown then 
			result.stopName = _(result.industry2.name).." ".._(api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(result.cargoType)).name).." ".._("Delivery")
		end 
		
		if not evaluation.checkIfLineIsAlreadyCarryingCargo(result)  then
			table.insert(results, result)
		else
			resultsTo = resultsTo + 1
		end

	end

	if not param.resultsToReturn then
		-- Use LLM-powered selection when daemon available, falls back to heuristic
		return util.evaluateWinnerWithLLM(results, nil, nil, {type = "train_route"}) or results[1]
	end
	--debugPrint({options=options, rawresults=rawresults, options=options})


	return results
end

-- Multi-stop cargo route evaluation for higher utilization
-- Routes that pick up multiple cargo types before reaching a processor achieve >50% utilization
function evaluation.evaluateMultiStopCargoRoutes(circle, param)
	local dbg = io.open('/tmp/tf2_multistop_trace.txt', 'w')
	dbg:write('START evaluateMultiStopCargoRoutes\n')

	if not param then param = {} end
	util.lazyCacheNode2SegMaps()

	-- Industries that need multiple inputs (key candidates for multi-stop routes)
	local multiInputIndustries = {
		["industry/steel_mill.con"] = { "COAL", "IRON_ORE" },
		["industry/goods_factory.con"] = { "STEEL", "PLASTIC" },
		["industry/machines_factory.con"] = { "STEEL", "PLANKS" },
		["industry/tools_factory.con"] = { "STEEL", "PLANKS" },
	}

	-- Map cargo to producer industry type
	local cargoToProducer = {
		["COAL"] = "industry/coal_mine.con",
		["IRON_ORE"] = "industry/iron_ore_mine.con",
		["STEEL"] = "industry/steel_mill.con",
		["PLASTIC"] = "industry/chemical_plant.con",
		["PLANKS"] = "industry/saw_mill.con",
		["LOGS"] = "industry/forest.con",
		["OIL"] = "industry/oil_well.con",
		["CRUDE"] = "industry/oil_refinery.con",
	}

	local options = {}
	local gameTime = game.interface.getGameTime().time
	local minInterval = 1200

	-- Get all industries
	local allIndustries = util.deepClone(game.interface.getEntities(circle, {type="SIM_BUILDING", includeData=true}))
	dbg:write('Found ' .. tostring(util.size(allIndustries)) .. ' industries\n')

	-- Find multi-input processing industries
	for industryId, industry in pairs(allIndustries) do
		local fileName = getFileNameOfIndustry(industryId)
		local requiredInputs = multiInputIndustries[fileName]

		if requiredInputs then
			dbg:write('Found multi-input industry: ' .. tostring(industry.name) .. ' needs: ' .. table.concat(requiredInputs, ', ') .. '\n')

			-- Check if already in cooldown
			if evaluation.isAutoBuildMode and evaluation.locationsInCoolDown[industryId] and
			   gameTime - evaluation.locationsInCoolDown[industryId] <= minInterval then
				dbg:write('  Skipping - in cooldown\n')
				goto continueProcessor
			end

			local processorPos = util.v3fromArr(industry.position)
			local sourcesByCargoType = {}

			-- Find source industries for each required input
			for _, cargoType in pairs(requiredInputs) do
				local producerType = cargoToProducer[cargoType]
				sourcesByCargoType[cargoType] = {}

				if producerType then
					for sourceId, sourceIndustry in pairs(allIndustries) do
						local sourceFileName = getFileNameOfIndustry(sourceId)
						if sourceFileName == producerType then
							-- Check production
							local itemsProd = sourceIndustry.itemsProduced and sourceIndustry.itemsProduced._sum or 0
							if itemsProd > 0 then
								local sourcePos = util.v3fromArr(sourceIndustry.position)
								local distance = util.distance(sourcePos, processorPos)

								-- Check if within reasonable distance (not too close, not too far)
								if distance >= (param.minDist or 1000) and distance <= (param.maxDist or 50000) then
									table.insert(sourcesByCargoType[cargoType], {
										industry = sourceIndustry,
										id = sourceId,
										pos = sourcePos,
										distance = distance,
										cargoType = cargoType
									})
								end
							end
						end
					end
				end
				dbg:write('  Found ' .. tostring(#sourcesByCargoType[cargoType]) .. ' sources for ' .. cargoType .. '\n')
			end

			-- Create multi-stop candidates by combining sources of different cargo types
			-- For Steel Mill: combine one Coal Mine + one Iron Ore Mine
			local cargo1 = requiredInputs[1]
			local cargo2 = requiredInputs[2]
			local sources1 = sourcesByCargoType[cargo1] or {}
			local sources2 = sourcesByCargoType[cargo2] or {}

			for _, source1 in pairs(sources1) do
				for _, source2 in pairs(sources2) do
					-- Calculate total route distance and check geometry
					local dist1to2 = util.distance(source1.pos, source2.pos)
					local dist2toDest = source2.distance
					local totalDist = source1.distance + dist1to2 + dist2toDest

					-- Route should not be too circuitous (max 1.5x direct distance sum)
					local directSum = source1.distance + source2.distance
					if totalDist <= directSum * 1.5 then
						-- Check for existing stations
						local station1 = evaluation.checkForAppropriateCargoStation(source1.industry, api.type.enum.Carrier.RAIL)
						local station2 = evaluation.checkForAppropriateCargoStation(source2.industry, api.type.enum.Carrier.RAIL)
						local stationDest = evaluation.checkForAppropriateCargoStation(industry, api.type.enum.Carrier.RAIL)

						local scores = {}
						scores[1] = totalDist  -- prefer shorter routes
						scores[2] = util.scoreTerrainBetweenPoints(source1.pos, processorPos)
						scores[3] = math.abs(util.gradientBetweenPoints(source1.pos, processorPos))
						scores[4] = util.scoreWaterBetweenPoints(source1.pos, processorPos)
						scores[5] = -100  -- bonus for multi-stop (utilization bonus)
						scores[6] = (station1 and station2 and stationDest) and -50 or 0  -- bonus if stations exist

						dbg:write('  Created candidate: ' .. source1.industry.name .. ' -> ' .. source2.industry.name .. ' -> ' .. industry.name .. '\n')

						table.insert(options, {
							isMultiStop = true,
							industries = { source1.industry, source2.industry, industry },
							cargoTypes = { cargo1, cargo2 },
							stations = { station1, station2, stationDest },
							positions = { source1.pos, source2.pos, processorPos },
							scores = scores,
							totalDistance = totalDist,
							estimatedUtilization = 0.67,  -- 2 legs with cargo, 1 empty return
							carrier = api.type.enum.Carrier.RAIL,
							isCargo = true,
						})
					end
				end
			end
		end
		::continueProcessor::
	end

	dbg:write('Total multi-stop candidates: ' .. tostring(#options) .. '\n')
	dbg:close()

	if #options == 0 then
		return nil
	end

	-- Score and sort options
	local weights = {
		25,   -- distance
		25,   -- terrain roughness
		75,   -- gradient
		50,   -- water
		100,  -- multi-stop bonus
		50,   -- existing stations bonus
	}

	local results = util.evaluateAndSortFromScores(options, weights)

	-- Return best result(s)
	if param.resultsToReturn then
		local returnCount = math.min(#results, param.resultsToReturn)
		local output = {}
		for i = 1, returnCount do
			table.insert(output, results[i])
		end
		return output
	end

	-- Use LLM-powered selection when daemon available
	return util.evaluateWinnerWithLLM(results, nil, nil, {type = "multi_stop_cargo_route"}) or results[1]
end

function evaluation.evaluateNewAirIndustryConnections(circle, param )
	if not param then param = {} end
	local options = {}
	util.lazyCacheNode2SegMaps()
	if not param.minDist then param.minDist = paramHelper.getParams().minimumCargoTrainDistance end
	if not param.transhipmentRange then param.transhipmentRange = 4000 end
	local filterFn = function(industryPair)
		local airport1 = evaluation.findAirportWithinRange(industryPair[1].position, param.transhipmentRange) 
		local airport2 = evaluation.findAirportWithinRange(industryPair[2].position, param.transhipmentRange) 
		local distance = industryPair[5]
		return  evaluation.getDistFilter(param)(distance)
		and not evaluation.checkIfFailed(api.type.enum.Carrier.AIR, industryPair[1].id, industryPair[2].id)
		and airport1 and airport2 and airport1 ~= airport2
	
	end
	local includeTowns = true
	local industryPairs = findMatchingIndustries(circle,includeTowns, filterFn, param.maxDist)
 
	if #industryPairs == 0 and circle.radius ~= math.huge then 
		local circle2= {radius=math.huge} 
		industryPairs = findMatchingIndustries(circle,includeTowns, filterFn, param.maxDist, circle2)
		if #industryPairs == 0 then 
			industryPairs = findMatchingIndustries(circle2,includeTowns, filterFn, param.maxDist, circle)
		end
	end  
	for i, industryPair in pairs(industryPairs) do
		local industry = industryPair[1]
		local industry2 = industryPair[2]
		local p0 = industryPair[3]
		local p1 = industryPair[4]
		local distance = industryPair[5] 
		local cargoType = industryPair[6]
		if not p0 or not p1 then 
			debugPrint({industryPair=industryPair})
		end
		local initialTargetLineRate = industryPair[7]
		local scores = {}
		scores[1] = 1/distance 
		scores[2] = 1/util.scoreTerrainBetweenPoints(p0, p1)
		local gradient = math.abs(util.gradientBetweenPoints(p0, p1))
		scores[3] = gradient > 0.01 and 1/gradient or 0 -- don't score trivial gradients  
		scores[4] = 1/util.scoreWaterBetweenPoints(p0,p1)
		scores[5] =0
		scores[6] = 0
		local airport1 = evaluation.findAirportWithinRange(industry.position, param.transhipmentRange) 
		local airport2 = evaluation.findAirportWithinRange(industry2.position, param.transhipmentRange) 
		if airport1 and airport2 and airport1 ~= airport2 then 
			table.insert(options, {industry1=industry, industry2=industry2, edge1=edge, edge2=edge2, scores=scores, straightlinevec=p0-p1, station1=station1, station2=station2, initialTargetLineRate = initialTargetLineRate, distance=distance ,cargoType=cargoType,
				airport1 = airport1,
				airport2 = airport2
			
			})
		else 
			trace("WARNING, airports not found ",airport1,airport2, " for ",industry.name," and ",industry2.name)
		end 
	end
	if #options == 0 then 
		
		return 
	end
	
	local resultsTo = param.resultsToReturn and math.min(#options, param.resultsToReturn) or 1

	local results = {} 
	local rawresults = util.evaluateAndSortFromScores(options)
	if param.resultsToReturn then 
		evaluation.setupDisplayScores(rawresults) 
	end
	for i = 1, math.min(resultsTo, #rawresults) do 
		local result = rawresults[i]
		result.isTown = result.industry2.type == "TOWN"
		--result.cargoType = util.discoverCargoType(result.industry1)
		result.edge1   = findEdgeForIndustry(result.industry1)
		result.edge2   = findEdgeForIndustryOrTown(result.industry2, result.cargoType) 
		
		result.needsTranshipment1 = true
		result.needsTranshipment2 = true
		if result.isTown then 
			result.stopName = _(result.industry2.name).." ".._(api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(result.cargoType)).name).." ".._("Delivery")
		end 
		
		if not evaluation.checkIfLineIsAlreadyCarryingCargo(result)  then
			table.insert(results, result)
		else 
			resultsTo = resultsTo + 1
		end
	
	end
	 
	if not param.resultsToReturn then 
		return results[1]
	end 
	--debugPrint({options=options, rawresults=rawresults, options=options})

	
	return results
end
function evaluation.estimateInitialTargetLineRateBetweenTowns(town, town2, totalDests)
	--local result = paramHelper.getParams().initialTownLineRateFactor*(getResidentialCapacityOfTown(town.id)+getResidentialCapacityOfTown(town2.id))
	--trace("Estimated initial target line beween towns=",result)
	local town1Cap = game.interface.getTownCapacities(town.id)
	local town2Cap = game.interface.getTownCapacities(town2.id)
	
	-- dests that will become availble to town1 from town2 and vice versa
	local availableDests1 = town2Cap[2]+town2Cap[3] +  game.interface.getTownReachability(town2.id)[2] -- assume if we make a connection we will get their dests 
 	local availableDests2 = town1Cap[2]+town1Cap[3] +  game.interface.getTownReachability(town.id)[2] 
	
	if not totalDests then 
		totalDests = getTotalTownDests()
	end
	
	-- not 100% sure on this, seems like the residents only have a fractional chance based on how many dests are covered
	local fractionalDests1 = availableDests1/totalDests 
	local fractionalDests2 = availableDests2/totalDests 
	
	local demand1 = town1Cap[1]*fractionalDests1 
	local demand2 = town1Cap[2]*fractionalDests2 
	local result = demand1 + demand2
	trace("Esimated initial rate between",town.name,town2.name," as ",result," based on available dests=",availableDests1,availableDests2," totalDests=",totalDests," demand1=",demand1,"demand2=",demand2)
	return result
end
function evaluation.getAppropriateWaterVerticiesForResult(town, otherTown, result,  range)
	 
	if not range then range = result.transhipmentRange end
	if not evaluation.waterCheckedLocations[range] then 
		evaluation.waterCheckedLocations[range] = {}
	end
	if   evaluation.waterCheckedLocations[range][town.id] then 
		trace("aborting as no water verticies found for ",town.name," already checked previously")
		return {}
	end
	local p0 = util.v3fromArr(town.position)
	local p1 = util.v3fromArr(otherTown.position)
	local distBetweenTowns = vec2.distance(p0, p1)
	trace("The transhipmentRange was",range, " distBetweenTowns=",distBetweenTowns," insepcting",town.name, "othertown was ",otherTown.name," the id was",town.id)
	local searchMinDist = 0
	local minDist = math.huge
	--local backupOptions = {}
	

	--local verticiesFound = false 
	--local countTotalVerticies = 0 
	--local countValidMeshVerticies = 0
	--[[local verticies  =  util.getClosestWaterVerticies(town.position, range, searchMinDist, function(vertex) 
		trace("Inspecting vertex with mesh",vertex.mesh)
		verticiesFound = true
		countTotalVerticies = countTotalVerticies + 1 
		if not validMeshes[vertex.mesh] then 
			trace("rejecting mesh",vertex.mesh,"as it was not in a valid group")
			return false 
		end
		if not util.isIndustryOnSameCoast(vertex.mesh, town.id) then 
			trace("rejecting mesh",vertex.mesh,"as it was not on the same coast")
			return false 
		end 
		if result.selectedGroup and validMeshes[vertex.mesh]~=result.selectedGroup then 
			trace("rejecting mesh",vertex.mesh,"as it was not in a selected group")
			return false 
		end 
		countValidMeshVerticies = countValidMeshVerticies + 1
		local distBetwenVerticies = util.distance(vertex.p, p1)
		local withinRange = distBetwenVerticies < distBetweenTowns + 200
		--trace("The distBetwenVerticies was",distBetwenVerticies," withinRange?",withinRange)
		minDist = math.min(minDist, distBetwenVerticies)
		if town.type == "TOWN" then -- using this code for industries too
			local nearestBuilding = util.searchForNearestEntity(vertex.p, 300, "TOWN_BUILDING", nil)
			if nearestBuilding then 
				local townBuildingComp =util.getComponent(nearestBuilding.id, api.type.ComponentType.TOWN_BUILDING)
				if townBuildingComp.town ~= town.id then 
					return false -- do not place in the wrong town
				end 
			end 
		end
		
		
		local normal = vertex.t
	--	local vectorToTown = vertex.p - util.v3fromArr(town.position)
		local vectorToTown = util.v3fromArr(town.position) - vertex.p 
		local angle = math.abs(util.signedAngle(normal, vectorToTown))
		--trace("The angle to the vector was ",math.deg(angle), " at p=",vertex.p.x,vertex.p.y)
		if angle > math.rad(120) then -- try to prevent placement on the wrong side of a river bank 
			if withinRange then 
				table.insert(backupOptions, vertex)
			end 
			trace("rejecting mesh",vertex.mesh,"due to angle to vector",math.deg(angle))
			return false
		end 
		
		
		return withinRange
	end) --]]
	local verticies = waterMeshUtil.getClosestWaterContours(town.id, range)
	
	--trace("getAppropriateWaterVerticiesForResult: After insepcting",town.name, town.id,"countTotalVerticies=",countTotalVerticies,"countValidMeshVerticies=",countValidMeshVerticies,"verticiesFound=",(verticies and #verticies or 0),"backupOptions=",#backupOptions)
	
	if #verticies ==0 then 
		trace("No verticies found for ",town.name, "id=",town.id)
		evaluation.waterCheckedLocations[range][town.id]=true 
		return {} 
	end
	if #verticies < 10 and town.type=="TOWN" then 
		trace("A low number of verticies were found trying again at a higher range") 
		verticies = waterMeshUtil.getClosestWaterContours(town.id, range*2)
		trace("A second pass gave",#verticies)
	end 
	local oldVerticies = verticies
	local filterFn = function(vertex) 
		if vec2.distance(vertex.p, p1) < vec2.distance(vertex.p, p0) then --closer to the other town
			return false
		end 	
		if vec2.distance(vertex.p, p0) > distBetweenTowns then -- further from the town than the connect istance
			return false 
		end
		if town.type == "TOWN" then -- using this code for industries too
			local nearestBuilding = util.searchForNearestEntity(vertex.p, 300, "TOWN_BUILDING", nil)
			if nearestBuilding then 
				local townBuildingComp =util.getComponent(nearestBuilding.id, api.type.ComponentType.TOWN_BUILDING)
				if townBuildingComp.town ~= town.id then 
					return false -- do not place in the wrong town
				end 
			end 
		end
		return true
	end
	verticies = util.copyTableWithFilter(verticies, filterFn)
	trace("getAppropriateWaterVerticiesForResult: After insepcting",town.name, town.id,"countTotalVerticies=",#oldVerticies,"countValidMeshVerticies=",#verticies)
--[[	
	if not verticies or #verticies == 0 and #backupOptions > 0 then 
		vertices = backupOptions
	end
	
	if not verticies then 
		trace("No suitable verticies found for ",town.name, "id=",town.id)
		return {} 
		
	end
	if minDist and minDist < distBetweenTowns then 
		trace("Filtering verticies beyond the dist between towns for ",town.name)
		local oldVerticies = verticies
		verticies = {} 
		for i, vertex in pairs(oldVerticies) do 
			if util.distance(p1, vertex.p) < distBetweenTowns+100 then 
				table.insert(verticies, vertex)
			end
		end 
		trace("After filtering, there were",#verticies," compared with ",#oldVerticies)
	end 
	 ]]--
	local scoreFns = {
		function(vertex) return util.distance(vertex.p, p0) end,
		function(vertex) return util.distance(vertex.p, p1) end,
	}
	local weights = { 75, 25}
	local isCargo = town.type~="TOWN" or otherTown.type~="TOWN"
	if isCargo then 
		trace("Scoring verticies to include station")
		table.insert(scoreFns, function(vertex) 
			if searchForHarbourWithRoadStation(vertex.p) then 
				return 0
			else  
				return 1
			end 
		end )
		table.insert(weights, 100)
	end 
	
	local res=  util.evaluateAndSortFromScores(verticies, weights , scoreFns)
	if util.tracelog then 
		--debugPrint({verticies=verticies, townName=town.name, res=res})
	end
	return res
end	


local function getVertexForStation(stationId) 
	local p = util.getStationPosition(stationId)
	return util.getClosestWaterVerticies(p)[1]
end 

local function checkForAppropriatePassengerHarbour(town, result) 
	if not result then 
		return util.findPassengerHarboursForTown(town.id)[1]
	end
	local otherTown = town.id == result.town1.id and result.town2 or  result.town1
	assert(otherTown.id ~= town.id, "town.id=",town.id,"result.town1.id=",result.town1.id,"result.town2.id=",result.town2.id)
	--local verticies = evaluation.getAppropriateWaterVerticiesForResult(town, otherTown, result)
	local verticies = town.id == result.town1.id and result.verticies1 or result.verticies2 
	local acceptableMeshes = {}
	for i, vertex in pairs(verticies) do 
		acceptableMeshes[vertex.mesh]=true 
	end 
	
	trace("result of verticies check? ",verticies)
	local alreadyChecked= {}
	--if verticies and #verticies> 0 then 
	for i =1, #verticies do 
		if alreadyChecked[verticies[i].mesh] then 
			goto continue 
		end 
		alreadyChecked[verticies[i].mesh]=true
		local p = verticies[i].p
		trace("Looking for a station near",p.x, p.y, " for town ",town.name)
		for __, station in pairs(util.searchForEntities(p, 500, "STATION")) do 
			if station.carriers.WATER and not station.cargo then 
				local stationMesh = getVertexForStation(station.id).mesh
				local canReturn = acceptableMeshes[stationMesh] 
				local theirTown = api.engine.system.stationSystem.getTown(station.id)
				trace("Inspecting station",station.id,station.name,"their town was",theirTown,"our town was",town.id)
				if town.id ~= theirTown then 
					canReturn = false -- wrong town
				end 
				
			--	if result.validMeshes then 
					
				---	canreturn = result.validMeshes[stationMesh]
				---	trace("Checking station ", station.id,station.name, " with mesh ",stationMesh," canreturn?",canreturn)
			--	else 
				--	trace("WARNING! Ambiguous result may not be corect")
				--end 
				if canReturn then 
					return station.id 
				end
			end 
		end
		::continue::
	end
	--[[else 
		error("Unexpected code path")
		for __, station in pairs(util.searchForEntities(town.position, 500, "STATION")) do 
			if station.carriers.WATER and not station.cargo then 
				local canreturn = true 
				if result.validMeshes then 
					local stationMesh = getVertexForStation(station.id).mesh
					canreturn = result.validMeshes[stationMesh]
					trace("Checking station ", station.id,station.name, " with mesh ",stationMesh," canreturn?",canreturn)
				else 
					trace("WARNING! Ambiguous result may not be corect")
				end 
				if canreturn then 
					return station.id 
				end
			end 
		end
	end ]]--
end 

local function getStationForTown2(transportType, town, result) 
	if transportType == api.type.enum.Carrier.RAIL then 
		for i, station in pairs(util.findPassengerTrainStationsForTown(town.id)) do
			local stationFull = util.getStation(station)
			if #stationFull.terminals <=9 then 
				return station
			end 			
		end 
	elseif transportType == api.type.enum.Carrier.ROAD  then 
		return  util.findBusStationOrBusStopForTown(town.id)
	elseif transportType == api.type.enum.Carrier.WATER then 
		return  checkForAppropriatePassengerHarbour(town, result) 
	elseif transportType == api.type.enum.Carrier.AIR then 
		for i, airport in pairs(util.findAirportsForTown(town.id)) do 
			if not util.getStation(airport).cargo then 
				return airport 
			end
		end 
	end
end
local function getStationForTown(transportType, town, result) 
	if transportType == AUTOCARRIER then 
		return getStationForTown2( api.type.enum.Carrier.RAIL, town, result) or 
			getStationForTown2( api.type.enum.Carrier.AIR, town, result) or 
			getStationForTown2( api.type.enum.Carrier.WATER, town, result) or 
			getStationForTown2( api.type.enum.Carrier.ROAD, town, result)
	else 
		return getStationForTown2(transportType, town, result)
	end 
end
local function getCityPairs(circle,transportType, filterFn, includeConnected, param)
	local begin = os.clock()
	profiler.beginFunction("getCityPairs")
	--collectgarbage()
	if not param then param = {} end
	debuglog("Begin searching for city pairs")
	local allTowns  
	local allTowns2  
	if  param.preSelectedPair then 
		allTowns = { [param.preSelectedPair[1]]=util.getEntity(param.preSelectedPair[1]) } 
		allTowns2 = { [param.preSelectedPair[2]]=util.getEntity(param.preSelectedPair[2]) } 
	else 
		allTowns = util.deepClone(game.interface.getEntities(circle, {type="TOWN", includeData=true}))
		allTowns2 = allTowns
	end	
	local townDetails = {} 
	local beforeSetupTownDetail = os.clock()
	
	local totalDests = getTotalTownDests()
	local function setupTownDetails(town) 
		local station = not param.isHighway and getStationForTown(transportType, town) 
		local lineStopsForStation
		local freeTerminals
		local hasSecondTaxiway
		if station then
			lineStopsForStation = #api.engine.system.lineSystem.getLineStopsForStation(station)
			if transportType == api.type.enum.Carrier.AIR  then 
				freeTerminals = util.countFreeTerminalsForStation(station)
				if freeTerminals == 0 then 
					local construction = util.getConstructionForStation(station)
					hasSecondTaxiway = helper.hasSecondTaxiway(construction)
				end 
			end
		end
		--local edge = findMostCentralEdgeForTown(function() return true end,town, false)
		local edge = util.searchForNearestEntity(util.v3fromArr(town.position), 100, "BASE_EDGE", function(edge) return not edge.track end)
		trace("The chosen edge for town",town.name," was ",edge and edge.id)
		local startingEdges = edge and pathFindingUtil.getStartingEdgesForEdge(edge.id,  api.type.enum.TransportMode.CAR) or {}
		--assert(#startingEdges>0)
		local destNodes = edge and pathFindingUtil.getDestinationNodesForEdge(edge.id,  api.type.enum.TransportMode.CAR) or {}
		--assert(#destNodes>0)
		local townNodes = {} 
		local isRailStation = station and util.getEntity(station).carriers.RAIL
		local p =  util.v3fromArr(town.position)
		if station and (carrier == api.type.enum.Carrier.RAIL or carrier == AUTOCARRIER and isRailStation) then 
			local isTerminus = util.isStationTerminus(station)
			for i, node in pairs(util.getAllFreeNodesForStation(station)) do 
				if #util.getSegmentsForNode(node) == 1 then 
					table.insert(townNodes, util.getDeadEndNodeDetails(node).tangent)
				end 
				
			end 
			if isTerminus and #result == 0 then 
				local tangent = util.v3(util.getConstructionForStation(station).transf:cols(1))
				trace("The tangent for station",station," was ",tangent.x, tangent.y)
				table.insert(townNodes, tangent)
			end
		end
		if carrier == api.type.enum.Carrier.ROAD and param.isHighway or carrier == AUTOCARRIER and #townNodes == 0 and not isRailStation then 
			townNodes = util.searchForDeadEndHighwayNodes(p, 1000)  
		end 
		local terrainRoughnessScore = 0
		local maxOffset = 512
		local interval = 32
		local testP = {} 
		local baseZ = util.th(p)
		for x = -maxOffset, maxOffset, interval  do 
			for y = -maxOffset, maxOffset, interval  do
				testP.x = p.x + x 
				testP.y = p.y + y 
				terrainRoughnessScore = terrainRoughnessScore + math.abs(baseZ-util.th(testP))
			end 
		end 
		
		townDetails[town.id]={
			station = station,
			edge = edge,
			lineStopsForStation=lineStopsForStation	,
			freeTerminals = freeTerminals,
			hasSecondTaxiway = hasSecondTaxiway,
			startingEdges = startingEdges, 
			destNodes = destNodes,
			p =p,
			reachability = game.interface.getTownReachability(town.id)[2],
			townNodes = townNodes,
			terrainRoughnessScore = terrainRoughnessScore,
			isRailStation = isRailStation,
		}
	end
	
	for i, town in pairs(allTowns) do
		setupTownDetails(town) 
	end
	
	if util.size(allTowns) == 1 and not param.preSelectedPair then 
		allTowns2 = util.deepClone(game.interface.getEntities({radius=math.huge, pos={0,0}}, {type="TOWN", includeData=true}))
	 
	end 
	for i, town in pairs(allTowns2) do
		if not townDetails[town.id] then 
			setupTownDetails(town) 
		end
	end
	local endSetupTownDetail = os.clock()
	trace("Time taken to setup town detail was ",(endSetupTownDetail-beforeSetupTownDetail))
	if not filterFn then
		trace("no filter function set, defaulting always true")
		filterFn = function(x) return true end 
	end
	local alreadySeen ={} 
	local cityPairs = {}
	local count = 0
	for townId, town in pairs(allTowns) do
		
		local position = town.position
		alreadySeen[townId]=true

		trace("Inspecting town ", town.name)
		--debugPrint({baseEdges = game.interface.getEntities({ radius=100, pos=position}, {type="BASE_EDGE", includeData=true})})
		--local baseEdge  = findUrbanStreetsForTown(town, 100)[1]
		--for edgeId 
		-- { 2088, 1708, 2.0999984741211, }
		-- game.interface.getEntities({ radius=10, pos= { 2088, 1708, 2.0999984741211, }}, {type="BASE_EDGE", includeData=true})[1]
		--game.interface.getEntities({ radius=10, pos=position}, {type="BASE_EDGE", includeData=true}) 
		-- api.type.EdgeIdDirAndLength.new(api.type.EdgeId.new(),true,100)
		
		-- 93073
--				edgeId.entity = baseEdge
		local townDetail = townDetails[townId]
		local station1 = townDetail.station
	 
		 
		local edge1 = townDetail.edge
			 
			
		
		for town2Id, town2  in pairs(allTowns2) do
			if alreadySeen[town2Id] or evaluation.checkIfFailed(transportType, town.id, town2.id) or evaluation.checkIfCompleted(transportType, town.id, town2.id) then
				--trace("skipping ", town2.name, " as it was already seen or failed")
				goto continue
			end
			if param.isHighway and evaluation.alreadyCheckedForHighways then 
				if evaluation.alreadyCheckedForHighways[townId] and evaluation.alreadyCheckedForHighways[townId][town2Id] then 
					goto continue
				end 
				if evaluation.alreadyCheckedForHighways[town2Id] and evaluation.alreadyCheckedForHighways[town2Id][townId] then 
					goto continue
				end
			end 
			
			--debuglog("start of loop iteration, lua used memory=",api.util.getLuaUsedMemory())
			local p0 = townDetails[townId].p
			local p1 = townDetails[town2Id].p
			local distance = util.distance(p0, p1) -- straight line distance
			if not filterFn(distance, town, town2) then
				goto continue 
			end
			if not param.ignoreCoolDown and isLocationInCooldown(townId) and isLocationInCooldown(town2Id) and not param.isHighway then -- may not have established a link
				trace("Both towns in cooldown, skipping ", town.name,town2.name)
				goto continue 
			end 
			local station2 = townDetails[town2Id].station
			trace("Looking for stations between", town.name, "and", town2.name, "found",station1,station2)
			
			--trace("straight line distance between ", town.name, " and ", town2.name, " was ", distance)
			
			
			
			
			--trace("About to check for overlapping destinations")
			local connectionExists  = false 
			if not includeConnected and not param.isHighway then 
				--local start = os.clock()
				connectionExists = checkForOverlappingDestinations(town.id, town2.id)
				--local endTime = os.clock()
				--trace("Check for overlapping destinations time taken was ",(endTime-start))
			end
		--[[	if transportType == api.type.enum.Carrier.RAIL  and station1 and station2 then
				--trace("checking for rail path between ",station1, " and ",station2)
				connectionExists = connectionExists
			    or #pathFindingUtil.findRailPathBetweenStations(station1, station2) > 0
			end]]--
		 
			
			--[[
			if transportType == api.type.enum.Carrier.AIR then -- not trying to upgrade airport terminals as it frequently collides
				 
				if station1 then 
					if townDetails[townId].freeTerminals <= 0 and not townDetail[townId].hasSecondTaxiway then 
						trace("station1 in town ", town.name, " had no free terminals, skipping")
						goto continue
					end
				elseif station2 then 
					if townDetails[town2Id].freeTerminals <= 0 and not townDetail[town2Id].hasSecondTaxiway then 
						trace("station2 in town ", town2.name, " had no free terminals, skipping")
						goto continue
					end
				end
			end--]]
			 
			if station1 and station2 then 
				
				local lineId = util.areStationsConnectedWithLine(station1, station2) 
				trace("Checking of the stations",station1,station2,"are connected with a line, found?",lineId)
				if lineId then 
					local line = util.getComponent(lineId, api.type.ComponentType.LINE)
					local minDist = math.huge 
					local station1Idxs = {}
					local station2Idxs = {}
					for i, stop in pairs(line.stops) do 
						local stationGroup = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
						local thisStation =  stationGroup.stations[stop.station+1]
						if thisStation == station1 then 
							table.insert(station1Idxs, i)
						elseif thisStation == station2 then 
							table.insert(station2Idxs,i)
						end 
					end 
					for __, i in pairs(station1Idxs)  do 
						for __, j in pairs(station2Idxs) do 
							local stops = math.abs(i-j)
							if stops == #line.stops then 
								minDist = 1 
								break 
							end 
							minDist = math.min(minDist, stops)
						end 
					end 
					trace("Inspecting ",station1, " and ", station2," the minDist was ",minDist)
					connectionExists = connectionExists or minDist == 1 or param.validateNoRailLine
				end
			end
			if not connectionExists and transportType == api.type.enum.Carrier.RAIL and param.validateNoRailLine then 
				for i, station1 in pairs(util.findPassengerTrainStationsForTown(town.id)) do 
					for j, station2 in pairs(util.findPassengerTrainStationsForTown(town2.id)) do 
						trace("Looking for stations between", town.name, "and", town2.name, "found",station1,station2)
						if util.areStationsConnectedWithLine(station1, station2) then 
							connectionExists = true 
							break 
						end 
					end 
				end 
			end 
			
			if not connectionExists or transportType == AUTOCARRIER then
				local edge2 = townDetails[town2Id].edge
--				local transportModes = {   api.type.enum.TransportMode.CAR} 
				local transportModes = {   api.type.enum.TransportMode.CAR, api.type.enum.TransportMode.TRUCK ,api.type.enum.TransportMode.BUS} 
				local distanceThreashold = math.max(1.5, math.min(2, 2-(distance-2000)/12000))
			
				local maxDistance = distanceThreashold*distance
				trace("at a distance of ",distance," the distanceThreashold was ",distanceThreashold, " giving maxDistance of ",maxDistance)
				local roadPath = {} 
				if transportType ~= api.type.enum.Carrier.AIR and distance < 8000 and transportType ~= AUTOCARRIER or param.isHighway then -- performance optimisation
					roadPath = pathFindingUtil.findPath( townDetails[townId].startingEdges ,townDetails[town2Id].destNodes, transportModes, maxDistance)
					--trace("Checking road path between ", town.name, town2.name, " found ",#roadPath, " at a distance of ",maxDistance) 
					if #roadPath > 0 then 
						--trace("A road path WAS found!!!")
					else 
						--roadPath = pathFindingUtil.findRoadPathBetweenEdges(townDetails[townId].edge.id , townDetails[town2Id].edge.id , preferredNode, maxDistance)
						--trace("Attempting again found ",#roadPath)
					end 
				end
	  
				local hasRoadPath =  #roadPath > 0
				local initialTargetLineRate = evaluation.estimateInitialTargetLineRateBetweenTowns(town, town2, totalDests)
				local scores = {}
				local hasRailStation1 = townDetails[townId].isRailStation 
				local hasRailStation2 = townDetails[town2Id].isRailStation
				local eitherHasRailStation =hasRailStation1 or hasRailStation2
				local bothHasRailStation = hasRailStation1 and hasRailStation2
				if hasRoadPath and param.isHighway then 
					trace("Checking road path for highway between", town.name, town2.name)
					local routeInfo =  pathFindingUtil.getRouteInfoFromEdges(roadPath) 
					if not routeInfo.isHighwayRoute then 
						local searchRadius = 1000
						local filterFn1 = function(node) 
							return util.distance(util.nodePos(node), p0) < util.distance(util.nodePos(node), p1)
						end
						local filterFn2 = function(node) 
							return util.distance(util.nodePos(node), p0) > util.distance(util.nodePos(node), p1)
						end
						local nodes1 = util.searchForJunctionHighwayNodes(p0, searchRadius, filterFn1)
						local nodes2 = util.searchForJunctionHighwayNodes(p1, searchRadius, filterFn2)
						trace("After search for junction nodes, there were",#nodes1,#nodes2, " for ",  town.name, town2.name)
						if #nodes1 > 0 and #nodes2 > 0 then 
						
							for i, node1 in pairs(nodes1) do 
								for j, node2 in pairs(nodes2) do 
									local dist = distanceThreashold*util.distBetweenNodes(node1,node2)
									local path = pathFindingUtil.findRoadPathBetweenNodes(node1, node2, dist)
									if #path == 0 then 
										path = pathFindingUtil.findRoadPathBetweenNodes(node2, node1, dist)
									end 
									trace("Checking path between nodes",node1,node2,"found?",#path>0)
									if #path>0 then 
										routeInfo = pathFindingUtil.getRouteInfoFromEdges(path) 
										trace("Found routeInfo between nodes",node1,node2," isHighwayRoute?",routeInfo.isHighwayRoute)
										if routeInfo.isHighwayRoute then 
											break 
										end
									end 
								end 
								if routeInfo.isHighwayRoute then 
									break 
								end
							end 
						end 
						if routeInfo.isHighwayRoute then 
							trace("A highway WAS Found routeinfo from nearbyedges highway between", town.name, town2.name)
						else 
							trace("A highway WAS NOT Found routeinfo from nearbyedges highway between", town.name, town2.name)
						end 
					end
					if routeInfo.isHighwayRoute then 
						if not evaluation.alreadyCheckedForHighways then 
							evaluation.alreadyCheckedForHighways = {}
						end 
						if not evaluation.alreadyCheckedForHighways[townId] then 
							evaluation.alreadyCheckedForHighways[townId] = {}
						end 
						evaluation.alreadyCheckedForHighways[townId][town2Id]=true
						trace("Aborting as alreay has highway for ", town.name, town2.name) 
						goto continue
					end 
				
				end 
				local existingStationBonus  = 1 
				if station1 and not station2 then 
					existingStationBonus = townDetails[townId].lineStopsForStation - 1 -- bonus for connecting to a station with only one stop
				elseif station2 and not station1 then 
					existingStationBonus = townDetails[town2Id].lineStopsForStation - 1
				end
				if transportType == api.type.enum.Carrier.AIR then
					-- treat air different, avoiding building a new airport is the bonus
					if  station1 and station2 then 
						existingStationBonus = 0 
					elseif  station1 or station2 then 
						existingStationBonus = 1
					else 
						existingStationBonus = 2
					end
				end
				local isForBusLine = transportType == api.type.enum.Carrier.ROAD  and not param.isHighway
				if param.isHighway or transportType == AUTOCARRIER and (not eitherHasRailStation or bothHasRailStation) then 
					local town1Nodes =  townDetails[townId].townNodes--util.searchForDeadEndHighwayNodes(p0, 1000)  
					local town2Nodes =  townDetails[town2Id].townNodes--util.searchForDeadEndHighwayNodes(p1, 1000)   
					existingStationBonus = math.rad(360)
					if #town1Nodes > 0 and not hasRailStation1 then 
						local angleBonus = math.abs(util.signedAngle(p0-p1, util.getDeadEndNodeDetails(town1Nodes[1]).tangent)) -- NB the angle is (deliberately) the "wrong" way round
						trace("The angle bonus from ",town.name," to ",town2.name,"was",math.deg(angleBonus))
						existingStationBonus = existingStationBonus-angleBonus
					end
					if #town2Nodes > 0 and not hasRailStation2 then 
						local angleBonus = math.abs(util.signedAngle(p1-p0, util.getDeadEndNodeDetails(town2Nodes[1]).tangent)) 
						trace("The town2 angle bonus from ",town.name," to ",town2.name,"was",math.deg(angleBonus))
						existingStationBonus = existingStationBonus-angleBonus
					end
					trace("Established existingStationBonus of ",existingStationBonus," for highway from",town.name,"to",town2.name)
				end 
				if transportType == api.type.enum.Carrier.RAIL or transportType == AUTOCARRIER and eitherHasRailStation and not connectionExists then
					existingStationBonus = math.rad(360) + 2
					if station1   then 
						existingStationBonus = existingStationBonus -1
					end 
					if station2 then 
						existingStationBonus = existingStationBonus -1
					end
					if station1 and station2 then 
						existingStationBonus = existingStationBonus + 2 -- reset - want to try to connect unconnected
					end 
					local function getDeadEndNodesForStation(station)
						if not station then 
							return {} 
						end 
						local result = {} 
						local isTerminus = util.isStationTerminus(station)
						for i, node in pairs(util.getAllFreeNodesForStation(station)) do 
							if #util.getSegmentsForNode(node) == 1 then 
								table.insert(result, util.getDeadEndNodeDetails(node).tangent)
							end 
							
						end 
						if isTerminus and #result == 0 then 
							local tangent = util.v3(util.getConstructionForStation(station).transf:cols(1))
							trace("The tangent for station",station," was ",tangent.x, tangent.y)
							table.insert(result, tangent)
						end
						return result
					end 
					local town1Nodes = townDetails[townId].townNodes --getDeadEndNodesForStation(station1)
					local town2Nodes = townDetails[town2Id].townNodes --getDeadEndNodesForStation(station2)
					if #town1Nodes > 0 then 
						local angleBonus = math.abs(util.signedAngle(p0-p1, town1Nodes[1]))-- NB the angle is (deliberately) the "wrong" way round
						trace("The angle bonus from ",town.name," to ",town2.name,"was",math.deg(angleBonus))
						existingStationBonus = existingStationBonus-angleBonus
					end
					if #town2Nodes > 0 then 
						local angleBonus = math.abs(util.signedAngle(p1-p0, town2Nodes[1]))
						trace("The town2 angle bonus from ",town.name," to ",town2.name,"was",math.deg(angleBonus))
						existingStationBonus = existingStationBonus-angleBonus
					end
					trace("Established existingStationBonus of ",existingStationBonus," for railway from",town.name,"to",town2.name)
				
				end 
				if not evaluation.cachedTerrainScores then 
					evaluation.cachedTerrainScores = {}
					evaluation.cachedWaterScores = {}
					evaluation.cachedFarmScores = {}
				end
				local hash = townHash(townId, town2Id)
			
				if not evaluation.cachedTerrainScores[hash] then 
					evaluation.cachedTerrainScores[hash]  = util.scoreTerrainBetweenPoints(p0, p1)
					evaluation.cachedWaterScores[hash] = util.scoreWaterBetweenPoints(p0, p1) 
					evaluation.cachedFarmScores[hash] = util.scoreFarmsBetweenPoints(p0, p1)
				end 
				scores[1] = distance 
				scores[2] =  evaluation.cachedTerrainScores[hash] 
				local gradient = math.abs(util.gradientBetweenPoints(p0, p1))
				scores[3] = gradient > 0.01 and gradient or 0 -- don't score trivial gradients 
				scores[4] = 2^16/scoreTownSizes(town.id, town2.id) 
				scores[5] = evaluation.cachedWaterScores[hash]
				scores[6] = evaluation.cachedFarmScores[hash]
				scores[7] = existingStationBonus
				scores[8] = hasRoadPath and (isForBusLine  and 0 or 1) or (isForBusLine and 1 or 0)
				scores[9] = townDetails[townId].reachability + townDetails[town2Id].reachability
				scores[10] = townDetails[townId].terrainRoughnessScore +  townDetails[town2Id].terrainRoughnessScore
				--debuglog("NO connection was found between ", town.name, " and ", town2.name, " scores were ", scores[1],scores[2],scores[3],scores[4],scores[5], scores[6])
				local buildTerminus 
				if api.type.enum.Carrier.RAIL == transportType then 
					buildTerminus = {} 
					buildTerminus[town.id]=evaluation.shouldBuildTerminus(town, town2)
					buildTerminus[town2.id]=evaluation.shouldBuildTerminus(town2, town)
				end 
				table.insert(cityPairs, 
					{town1=town,
					town2=town2,
					scores=scores, 
					route=answer,
					station1= station1, 
					station2 = station2, 
					edge1=edge1, edge2=edge2,
					roadPath=roadPath,
					initialTargetLineRate =initialTargetLineRate,
					distance=distance,
					buildTerminus = buildTerminus, 
					cargoType="PASSENGERS",
					p0 = p0,
					p1 = p1,					
				})
				
			else
				trace("Ignoring as connection WAS found between ", town.name, " and ", town2.name)
			end
			--debuglog("end of loop iteration, lua used memory=",api.util.getLuaUsedMemory())
			 
			count = count + 1
			::continue::
		end
		--debuglog("end of outer  loop iteration, lua used memory=",api.util.getLuaUsedMemory())
		----collectgarbage()
		--debuglog("after --collectgarbage, lua used memory=",api.util.getLuaUsedMemory())
	end
	local endTime = os.clock()
	trace(" A total of ",count," city pairs were considered, of ", util.size(allTowns)," in total. Time taken: ",(endTime-begin))
	--debugPrint(cityPairs) 
	profiler.endFunction("getCityPairs")
	return cityPairs
end

function evaluation.getDistFilter(param)
	if not param.minDist then param.minDist = 0 end
	if not param.maxDist then param.maxDist = math.huge end
	return function(distance, town1, town2)
		local preselectedCheck = evaluation.checkForPeselected(param, town1, town2)
		print("[EVAL_TRACE] getDistFilter: distance=" .. tostring(distance) .. " town1.id=" .. tostring(town1 and town1.id) .. " town2.id=" .. tostring(town2 and town2.id) .. " preselectedCheck=" .. tostring(preselectedCheck) .. " minDist=" .. tostring(param.minDist) .. " maxDist=" .. tostring(param.maxDist))
		if preselectedCheck then
			return false
		end
		return distance >= param.minDist and distance <= param.maxDist
	end
end

function evaluation.evaluateNewPassengerTrainTownConnection(circle, param ) 
	local wasCached =util.lazyCacheNode2SegMaps()
	local wasCached2 = false 
	if not evaluation.town2BuildingMap then 
		setupCaches()	
		wasCached2 = true 
		
	end
	local cityPairs = getCityPairs(circle, api.type.enum.Carrier.RAIL, evaluation.getDistFilter(param) , param.includeConnected, param)
	if wasCached then 
		--util.clearCacheNode2SegMaps()
	end
	local weights = util.deepClone(paramHelper.getParams().cityConnectionScoreWeights)
	if evaluation.isAutoBuildMode then 
		weights = { 
			100, -- distance between cities
			20, -- roughness of terrain between cities
			30, -- height gradient between cities
			20, -- cities sizes
			40, -- waterPoints between cities
			10, -- farms between cities
			60, -- existing station bonus
			5, -- road path bonus 
			50, -- reachability bonus
			5, -- terrainRoughnessScore
		}	 
	end 
	
	if not  param.resultsToReturn then 
		return util.evaluateWinnerFromScores(cityPairs,weights)
	end
	if #cityPairs==0 then
		return 
	end
	local allResults = util.evaluateAndSortFromScores(cityPairs, weights)
	evaluation.setupDisplayScores(allResults)
	local results = {} 
	for i = 1, math.min( param.resultsToReturn, #allResults) do 
		table.insert(results, allResults[i])
	end
	if wasCached2 then 
		clearCaches()
	end
	return results
end

function evaluation.evaluateNewPassengerRoadTownConnection(circle, param)
	if not param then param = {} end
	setupCaches()
	local cityPairs = getCityPairs(circle, api.type.enum.Carrier.ROAD,evaluation.getDistFilter(param) , param.includeConnected, param)
	local weights = {
		100, -- distance between cities
		25, -- roughness of terrain between cities 
		25, -- height gradient between cities
		25, -- cities sizes
		50, -- waterPoints between cities
		15, -- farms between cities
		25, -- existing station bonus
		100, -- existing road path
	}
	if param.isHighway then 
		weights[5]=25 -- water points 
		weights[7]=100 -- existing station bonus
		weights[8]=50 -- existing road path
	end 
	 
	if not param.resultsToReturn then
		clearCaches()
		return util.evaluateWinnerFromScores(cityPairs, weights)
	end
	if #cityPairs == 0 then
		return 
	end
	
	local allResults = util.evaluateAndSortFromScores(cityPairs, weights)
	evaluation.setupDisplayScores(allResults)
	local results = {}
	for i = 1, math.min(param.resultsToReturn, #allResults) do 
		table.insert(results, allResults[i])
	end
	return results
end

function evaluation.evaluateNewPassengerAirTownConnection(circle, param ) 
	if util.year() < 1920 then 
		return {}
	end
	if not param then param = {} end
	if not param.minDist then param.minDist = paramHelper.getParams().minimumAirPassengerDistance end
	local mapBoundary = util.getMapBoundary()
	--util.cacheNode2SegMaps()
	if mapBoundary.x < 5000 and mapBoundary.y < 5000 then 
		param.minDist = math.min(param.minDist, 6000) -- try to support small maps
	end
	
	local cityPairs = getCityPairs(circle,api.type.enum.Carrier.AIR, evaluation.getDistFilter(param) , param.includeConnected, param)
	for i, cityPair in pairs(cityPairs) do 
		cityPair.scores[1] = 2^16/cityPair.scores[1] -- invert the distance  
		-- zero out some irrelevant scores for air routes
		cityPair.scores[2] = 0 -- terrain between points
		cityPair.scores[3] = 0 -- gradient
		-- cityPair.scores[4] = 2^16/scoreTownSizes(town.id, town2.id) 
		cityPair.scores[5] = 0 -- water between points
		cityPair.scores[6] = 0 -- farms between points
	end
	if #cityPairs == 0 then	
		return 
	end
	
	local weights = util.deepClone(paramHelper.getParams().cityConnectionScoreWeights)
	weights[10]=100 -- terrainRoughnessScore
	if not param.resultsToReturn then 
		local result = util.evaluateWinnerFromScores(cityPairs, weights)
		result.carrier = api.type.enum.Carrier.AIR
		--util.clearCacheNode2SegMaps()
		return result
	end
	local allResults = util.evaluateAndSortFromScores(cityPairs, weights)
	evaluation.setupDisplayScores(allResults)
	local results = {}
	for i = 1, math.min(param.resultsToReturn, #allResults) do 
		local result = allResults[i]
		 
		table.insert(results, result)
	end
	util.clearCacheNode2SegMaps()
	return results
end






function evaluation.getMidPointVerticies(town1, town2, range) 

	local position = 0.5*util.v3fromArr(town1.position)+util.v3fromArr(town2.position)
	local distance = distBetweenTowns(town1, town2)
	local meshes =util.getRiverMeshEntitiesInRange(position,distance +range)
	
	local meshGroups =  pathFindingUtil.getWaterMeshGroups() 
	
	local town1Meshes =util.getRiverMeshEntitiesInRange(town1.position, range)
	local town1Groups = {}
	for i, meshId in pairs(town1Meshes) do 
		
		local group = meshGroups[meshId] 
		trace("Inspecting mesh",meshId,"for",town1.name," group was",group)
		if group and not town1Groups[group] then 
			town1Groups[group] = true
		end  
	end 	
	
	
	local town2Meshes =util.getRiverMeshEntitiesInRange(town2.position, range)
	local overLappingGroups = {}
	for i, meshId in pairs(town2Meshes) do 
		local group = meshGroups[meshId] 
		trace("Inspecting mesh",meshId,"for",town2.name," group was",group)
		if group and town1Groups[group] and not overLappingGroups[group] then 
			overLappingGroups[group] = true
		end  
	end 
	trace("Inspecting pair",town1.name, town2.name,"they had",#town1Meshes,#town2Meshes,"with size of overlapping groups",util.size(overLappingGroups))
	if util.tracelog then debugPrint({town1Groups=town1Groups, overLappingGroups = overLappingGroups}) end 
	
	local result = {}
	for i, meshId in pairs(util.combine(meshes, town1Meshes, town2Meshes)) do 
		local group = meshGroups[meshId] 
		if overLappingGroups[group] then 
			result[meshId]=group 
		end 
	end 
	if util.size(overLappingGroups) > 1 then 
		trace("Possible ambiguity")
	end 
	if util.size(result) > 0 then 
		for i, mesh1 in pairs(town1Meshes) do 
			for j, mesh2 in pairs(town2Meshes) do 
				if result[mesh1] and result[mesh2] then 
					local group = meshGroups[meshId] 
					local meshDistance = pathFindingUtil.findWaterPathDistanceBetweenMeshes(mesh1,mesh2)
					local canAccept = meshDistance < 3*distance
					trace("Comparing the meshDistance",meshDistance,"to the townDistance",distance,"canAccept?",canAccept)
					if canAccept then 
						return result 
					elseif meshDistance > 5*distance and util.size(overLappingGroups) == 1 then 
						trace("Exiting early due to large mesh distance")
						return {}
					end 
				end
			end 
		end 
	end 
	trace("Rejecting as no mesh found or too long")
	
	return {} 
end 

function evaluation.checkForPeselected(param, town1, town2)
	if param.preSelectedPair then
		local result = town1.id ~= param.preSelectedPair[1] or town2.id ~= param.preSelectedPair[2]
		print("[EVAL_TRACE] checkForPeselected: town1.id=" .. tostring(town1 and town1.id) .. " preSelectedPair[1]=" .. tostring(param.preSelectedPair[1]) .. " town2.id=" .. tostring(town2 and town2.id) .. " preSelectedPair[2]=" .. tostring(param.preSelectedPair[2]) .. " result=" .. tostring(result))
		return result
	end
	return false
end

function evaluation.evaluateNewWaterTownConnections(circle, param )
	local begin = os.clock()
	if not param then param = {} end
	if not param.transhipmentRange then param.transhipmentRange = 1000 end 
	local range = param.transhipmentRange
	trace("Evaluating new water town connections the range was ", param.transhipmentRange)
	if not evaluation.waterCheckedPairs[range] then 
		evaluation.waterCheckedPairs[range]={}
	end
	local function getActualRange(town1, town2) 
		return  math.floor(math.min(param.transhipmentRange, distBetweenTowns(town1, town2)/3 ))
	end
	local filterFn = function(distance, town1, town2) 
		if evaluation.checkForPeselected(param, town1, town2) then 
			return false
		end 
		local range = getActualRange(town1, town2) 
	--[[	if not evaluation.waterCheckedPairs[range] then 
			evaluation.waterCheckedPairs[range]={}
		end
		if not evaluation.waterCheckedPairs[range][town1.id] then 
			evaluation.waterCheckedPairs[range][town1.id] = {}
		end 
		
		local result =  evaluation.waterCheckedPairs[range][town1.id][town2.id]
		if result == nil then 
			local validMeshes = evaluation.getMidPointVerticies(town1, town2, range) 
			result = #evaluation.getAppropriateWaterVerticiesForResult(town1, town2, param,validMeshes, range) > 0
				and #evaluation.getAppropriateWaterVerticiesForResult(town2, town1, param,validMeshes, range) > 0
			evaluation.waterCheckedPairs[range][town1.id][town2.id] = result and validMeshes
			if not 	evaluation.waterCheckedPairs[range][town2.id] then 
				evaluation.waterCheckedPairs[range][town2.id] = {}
			end 
			evaluation.waterCheckedPairs[range][town2.id][town1.id] = result and validMeshes 
		end ]]--
		local result = evaluation.getAppropriateVerticiesForPair(town1, town2, param, range)
		return 
			--#util.getRiverMeshInRange(town1.position, range)>0
		  -- and #util.getRiverMeshInRange(town2.position, range)>0  
		result 
		   and not evaluation.checkIfFailed(api.type.enum.Carrier.WATER, town1.id, town2.id)
		   and not evaluation.checkIfCompleted(api.type.enum.Carrier.WATER, town1.id, town2.id)
	end
	local cityPairs = getCityPairs(circle,api.type.enum.Carrier.WATER, filterFn,  param.includeConnected, param)
	local weights = 
	{
		90, -- distance between cities
		0, -- roughness of terrain between cities (irrelevant)
		0, -- height gradient between cities
		25, -- cities sizes
		0, -- waterPoints between cities
		0, -- farms between cities
		50, -- existing station bonus
		50, -- existing road path
	}
	trace("evaluateNewWaterTownConnections: completed evaluation in ",(os.clock()-begin)) 
	if #cityPairs == 0 then
		return
	end
	--[[if not param.resultsToReturn then 
		local result = util.evaluateWinnerFromScores(cityPairs, weights)
		result.transhipmentRange =  getActualRange(result.town1, result.town2)   
		--result.validMeshes = evaluation.waterCheckedPairs[result.transhipmentRange ][result.town1.id][result.town2.id]
		local verticies = evaluation.getAppropriateVerticiesForPair(industryPair[1], industryPair[2], param, range)
		if  verticies then 
			
	
		local result.verticies1 = verticies.v1 
		local result.verticies2 = verticies.v2 
		return result
	end]]--
	local allResults = util.evaluateAndSortFromScores(cityPairs, weights)
	if not param.resultsToReturn then
		for i = 1, #allResults do 
			local result = allResults[i]
			result.transhipmentRange =  getActualRange(result.town1, result.town2)   
		--result.validMeshes = evaluation.waterCheckedPairs[result.transhipmentRange ][result.town1.id][result.town2.id]
			local verticies = evaluation.getAppropriateVerticiesForPair(result.town1, result.town2, param, range)
			if  verticies then 
			 
				result.verticies1 = verticies.v1 
				result.verticies2 = verticies.v2 
				return result
			else 
				trace("WARNING! No result found")-- should not be possible because of prior filetering
			end 
		end 
		 
	end
	if not param.resultsToReturn then 
		return 
	end 
	
	evaluation.setupDisplayScores(allResults)
	local results = {}
	for i = 1, math.min(param.resultsToReturn, #allResults) do 
		local result = allResults[i]
		result.transhipmentRange =  getActualRange(result.town1, result.town2)   
		
		local verticies = evaluation.getAppropriateVerticiesForPair(result.town1, result.town2, param, range)
		if  verticies then 
			
			result.verticies1 = verticies.v1 
			result.verticies2 = verticies.v2 
			
			--result.validMeshes = evaluation.waterCheckedPairs[result.transhipmentRange ][result.town1.id][result.town2.id]
			table.insert(results, allResults[i])
		end
	end
	return results
end
function evaluation.validateVerticies(verticies1, verticies2, industry1, industry2) 
	if not verticies1 or not verticies2 then 
		return 
	end
	profiler.beginFunction("validateVerticies")
	local begin = os.clock()
	local valid1 = {}
	local valid2 = {}
	local alreadyAdded1 = {}
	local alreadyAdded2 = {}
	for i = 1, math.min(#verticies1, 500) do 
		verticies1[i] = waterMeshUtil.safeCloneContour(verticies1[i])
		verticies1[i].minDist = math.huge
	end 
	for i = 1, math.min(#verticies2, 500) do 
		verticies2[i] = waterMeshUtil.safeCloneContour(verticies2[i])
		verticies2[i].minDist = math.huge
	end 
	local minDistToIndustry1 = math.huge 
	local minDistToIndustry2 = math.huge 
	local p0 = util.v3fromArr(industry1.position)
	local p1 = util.v3fromArr(industry2.position)
	for i = 1, math.min(#verticies1, 500) do 
		local vertex = verticies1[i]
		minDistToIndustry1 = math.min(minDistToIndustry1, vec2.distance(vertex.p, p0))
		for j = 1, math.min(#verticies2, 500) do
			local vertex2 = verticies2[j]
			if not alreadyAdded1[vertex] or not alreadyAdded2[vertex2] then 
				minDistToIndustry2 = math.min(minDistToIndustry2, vec2.distance(vertex2.p, p1))
				local dist = vec2.distance(vertex.p, vertex2.p)
				local testDist = waterMeshUtil.findWaterPathDistanceBetweenContours(vertex, vertex2) 
				vertex.minDist = math.min(vertex.minDist, testDist)
				vertex2.minDist = math.min(vertex2.minDist, testDist)
				if testDist < 2*dist then 
					if not alreadyAdded1[vertex] then 
						table.insert(valid1, vertex)
						alreadyAdded1[vertex]=true
					end 
					if not alreadyAdded2[vertex2] then 
						table.insert(valid2, vertex2)
						alreadyAdded2[vertex2]=true
					end 
				else 
					--trace("rejecting mesh pair",vertex.mesh,vertex.mesh2,"based on dist=",dist,"testDist=",testDist)
				end			
			end
		end 
	
	end 
	trace("evaluation.validateVerticies: original size was",#verticies1,#verticies2,"after validation",#valid1,#valid2," timetaken=",(os.clock()-begin),"minDistToIndustry1=",minDistToIndustry1,"minDistToIndustry2=",minDistToIndustry2)
	local scoreFns1 = {
		function(vertex) 
			local dist =  vec2.distance(vertex.p, p0) 
			 
			return dist
		end,
		function(vertex) 
			return vertex.minDist
		end
	}
	local scoreFns2 = {
		function(vertex) 
			local dist = vec2.distance(vertex.p, p1) 
		 
			return dist 
		end,
		function(vertex) 
			return vertex.minDist
		end
	}
	
	  
	local weights1 = { 50,50} 
	local weights2 = { 50,50}
	-- Try to give an extra bonus for being within the catchment area if we have verticies that are close enough, to avoid transhipping
	if minDistToIndustry1 < 450 then
		trace("adding threshold score for industry1")
		table.insert(scoreFns1, function(vertex) 
			return vec2.distance(vertex.p, p0) < 450 and 0 or 1
		end)
		table.insert(weights1, 100)
	end 
	if minDistToIndustry2 < 450 then 
		trace("adding threshold score for industry2")
		table.insert(scoreFns2, function(vertex) 
			return vec2.distance(vertex.p, p1) < 450 and 0 or 1
		end)
		table.insert(weights2, 100)
	end 	
	valid1 =  util.evaluateAndSortFromScores(valid1, weights1 , scoreFns1)
	valid2 =  util.evaluateAndSortFromScores(valid2, weights2 , scoreFns2)
	profiler.endFunction("validateVerticies")
	if util.tracelog then 
		debugPrint({valid1=valid1})
	end
	--valid1 =  util.evaluateAndSortFromScores(valid1, {2,1} , { function(vertex) return vec2.distance(vertex.p, p0) end, scoreMinDist})
	--debugPrint({valid1after=valid1})
	return valid1, valid2
end 
function evaluation.getAppropriateVerticiesForPair(industry1, industry2, param, range)
	if not evaluation.waterCheckedPairs[range] then 
		evaluation.waterCheckedPairs[range] = {}
	end 
	if not evaluation.waterCheckedPairs[range][industry1.id] then 
		evaluation.waterCheckedPairs[range][industry1.id] = {}
	end 
	if evaluation.waterCheckedPairs[range][industry1.id][industry2.id] ~= nil then 
		return evaluation.waterCheckedPairs[range][industry1.id][industry2.id]
	end 
	profiler.beginFunction("getAppropriateVerticiesForPair")
	local verticies1 = evaluation.getAppropriateWaterVerticiesForResult(industry1, industry2, param, range)
	local verticies2 = evaluation.getAppropriateWaterVerticiesForResult(industry2, industry1, param, range)
	local v1, v2 =  evaluation.validateVerticies(verticies1, verticies2, industry1, industry2) 
	
	
	local result = false 
	if #v1 >0 and #v2>0 then 
		result = { v1 = waterMeshUtil.safeCloneContours(v1), v2 = waterMeshUtil.safeCloneContours(v2) }
	end 
	profiler.endFunction("getAppropriateVerticiesForPair")
	evaluation.waterCheckedPairs[range][industry1.id][industry2.id]=result 
	return result
end
function evaluation.evaluateNewWaterIndustryConnections(circle, param)
	local options = {}
	local minDist =  0
	if not param then param = {} end
	local range = param.transhipmentRange
	if not range then range = 400 end
	if not param.transhipmentRange then param.transhipmentRange =range end
	local transhipmentThreashold = 450
	if not param.maxHeight then param.maxHeight = math.huge end 
	if not evaluation.waterCheckedPairs[range] then 
		evaluation.waterCheckedPairs[range]={}
	end 

	local function getActualRange(industryPair) 
		return  math.floor( math.min(param.transhipmentRange, distBetweenTowns(industryPair[1], industryPair[2])/3 ))
	end 

	local function filterFn(industryPair) 
		if param.preSelectedPair then 
			if param.preSelectedPair[1] ~= industryPair[1].id or param.preSelectedPair[2] ~= industryPair[2].id then 
				return false 
			end
		end 
		local range = getActualRange(industryPair) 
		if not evaluation.waterCheckedPairs[range] then 
			evaluation.waterCheckedPairs[range]={}
		end 
		if not evaluation.waterCheckedPairs[range][industryPair[1].id] then 
			evaluation.waterCheckedPairs[range][industryPair[1].id] = {}
		end 
		local result =   evaluation.getAppropriateVerticiesForPair(industryPair[1], industryPair[2], param, range)
			 
			
			--industryPair[1].position[3] <= 50
			--   and industryPair[2].position[3] <= 50
			--	#util.getRiverMeshInRange(industryPair[1].position,range, minDist)>0
			--   and #util.getRiverMeshInRange(industryPair[2].position,range, minDist)>0 
			 
		  
		return result 
		   and not evaluation.checkIfFailed(api.type.enum.Carrier.WATER, industryPair[1].id, industryPair[2].id)
		   and not evaluation.checkIfCompleted(api.type.enum.Carrier.WATER, industryPair[1].id, industryPair[2].id)
		   and industryPair[1].position[3] <= param.maxHeight
		   and industryPair[2].position[3] <= param.maxHeight
	end
	 
	local count = 0
	local industryToEdgeCache = {}
	local function findEdgeForIndustryCached(industry) 
		if not industryToEdgeCache[industry.id] then 
			industryToEdgeCache[industry.id]=findEdgeForIndustryOrTown(industry)
		end
		return industryToEdgeCache[industry.id]
	end
	local industryPairs = findMatchingIndustries(circle,true, filterFn, param.maxDist,nil, false, param )
	if #industryPairs == 0 and circle.radius ~= math.huge then 
		local circle2= {radius=math.huge} 
		industryPairs = findMatchingIndustries(circle,true, filterFn, param.maxDist, circle2 , false, param)
		if #industryPairs == 0 then
			industryPairs = findMatchingIndustries(circle2,true, filterFn, param.maxDist, circle , false, param)
		end
	end
	local function newBox() 
		local box= {
			xmin = math.huge ,
			xmax = -math.huge ,
			ymin = math.huge ,
			ymax = -math.huge,
			
		}
		box.addPoint = function(p) 
			box.xmin = math.min(box.xmin, math.floor(p.x))
			box.xmax = math.max(box.xmax, math.ceil(p.x))
			box.ymin = math.min(box.ymin, math.floor(p.y))
			box.ymax = math.max(box.ymax, math.ceil(p.y))	
		end
		box.boxOverlap = function(otherBox) 
			return box.xmin <= otherBox.xmax 
			and box.xmax >= otherBox.xmin 
			and box.ymin <= otherBox.ymax 
			and box.ymax >= otherBox.ymin
		
		end 
		return box
	end
	local boxCache = {} 
	local function getBox(mesh) 
		if not boxCache[mesh] then 
			local box =  newBox()  
			
			for j, vertex in pairs(util.getComponent(mesh, api.type.ComponentType.WATER_MESH).vertices) do
				box.addPoint(vertex)
			end
			boxCache[mesh]=box
		end 
		return boxCache[mesh]
	end 
	
	for i, industryPair in pairs(industryPairs) do
		
		count = count+1
				local industry = industryPair[1]
		local industry2 = industryPair[2]
		local p0 = industryPair[3]
		local p1 = industryPair[4]
		local distance = industryPair[5] 
		local cargoType = industryPair[6]
		
		trace("about to get verticies. Luausedmemory= ",api.util.getLuaUsedMemory())
		--collectgarbage()
		local actualRange =   getActualRange(industryPair) 
		--local validMeshes =  evaluation.waterCheckedPairs[actualRange][industryPair[1].id][industryPair[2].id]
		--local verticies1 =  util.getClosestWaterVerticies(industry.position,range, minDist)
	--	local verticies2 =  util.getClosestWaterVerticies(industry2.position,range, minDist)
	--	local verticies1 = evaluation.getAppropriateWaterVerticiesForResult(industryPair[1], industryPair[2], param, actualRange)
		--local verticies2 = evaluation.getAppropriateWaterVerticiesForResult(industryPair[2], industryPair[1], param, actualRange)
		
		--verticies1, verticies2 = evaluation.validateVerticies(verticies1, verticies2) 
		local verticies = evaluation.getAppropriateVerticiesForPair(industryPair[1], industryPair[2], param, range)
		if not verticies then 
			goto continue 
		end 
		local verticies1 = verticies.v1 
		local verticies2 = verticies.v2 
		--if not verticies2 or not verticies1 or #verticies1 == 0 or verticies2 == 0 then goto continue end 
		
		
		--[[
		-- logic here is intended to avoid placing the harbour on the "wrong side" 
		local minAngle1 = math.rad(360)
		local minIdx1
		local mesh1 = verticies1[1].mesh
		local angles1 = {}
		local allMesh1 = {}
		
		local scoreFns = {
			function(vertex) return util.distance(vertex.p, p0) end,
			function(vertex) return util.distance(vertex.p, p1) end,
		}
		-- if the distance is significant then include the relative position of the destination
		if util.distance(p0, verticies1[1].p) > 750 then 
			trace("Large distance found, resorting verticies1")
			verticies1 = util.evaluateAndSortFromScores(verticies1, {75, 25}, scoreFns)
		end 
		if util.distance(p1, verticies2[1].p) > 750 or industry2.type == "TOWN" then 
			trace("Large distance found, resorting verticies2")
			local weights = {25, 75} 
			if industry2.type == "TOWN" then -- because we need transhipment anyway no need to get within any catchment area
				wieghts = {50, 50} 
			end
			verticies2 = util.evaluateAndSortFromScores(verticies2, weights, scoreFns)
		end 
		local distBetweenIndustries = util.distance(p0,p1)
		for i = 1, #verticies1 do 
			local adverseDistance = util.distance(verticies1[i].p,p1) > distBetweenIndustries
			local angle = math.abs(util.signedAngle(verticies1[i].p-p1, verticies1[i].t))
			table.insert(angles1, angle)
			if not adverseDistance then 
				if angle < minAngle1 then 
					minIdx = i 
					mesh1 = verticies1[i].mesh
				end 
				
				minAngle1 = math.min(minAngle1, angle)
			end
			--if not allMesh1[verticies1[i].mesh] then  
		--		allMesh1[verticies1[i].mesh]=getBox(verticies1[i].mesh) 
			--end
			
			
		end 
		--assert(angles1[minIdx]==minAngle1)
		--[[
		local minAngle2 = math.rad(360)
		local mesh2 = verticies2[1].mesh
		local angles2 = {}
		local allMesh2 = {}
		for i = 1, #verticies2 do 
			local angle = math.abs( util.signedAngle(verticies2[i].p-p0, verticies2[i].t))
			local adverseDistance = util.distance(verticies2[i].p,p0) > distBetweenIndustries
			table.insert(angles2, angle)
			if not adverseDistance then 
				if angle < minAngle2 then  
					mesh2 = verticies2[i].mesh
				end 
				minAngle2 = math.min(minAngle2, angle)
			end
			
			if not allMesh2[verticies2[i].mesh] then 
				allMesh2[verticies2[i].mesh]=getBox(verticies2[i].mesh)
			end
			
		end 
		trace("MinAngle1 was ",math.deg(minAngle1), " minAngle2 was ",math.deg(minAngle2), "mesh1=",mesh1,"mesh2=",mesh2)
		if util.tracelog then 
			debugPrint({allMesh1=allMesh1, allMesh2=allMesh2})
		end
		local connectedToMesh1 = {[mesh1]=true} 
		
		local connectedToMesh2 = {[mesh2]=true}
		local foundConnections = false 
		repeat 
			foundConnections = false 
			for mesh, box in pairs(allMesh1) do 
				if not connectedToMesh1[mesh] then 
					for otherMesh, bool in pairs(connectedToMesh1) do 
						trace("The otherMesh was ",otherMesh," the lookup result was",allMesh1[otherMesh])
						if box.boxOverlap(allMesh1[otherMesh]) then 
							connectedToMesh1[mesh]=true 
							foundConnections = true
						end
					end 
				end 
			end
		until not foundConnections
		repeat 
			foundConnections = false 
			for mesh, box in pairs(allMesh2) do 
				if not connectedToMesh2[mesh] then 
					for otherMesh, bool in pairs(connectedToMesh2) do 
						if box.boxOverlap(allMesh2[otherMesh]) then 
							connectedToMesh2[mesh]=true 
							foundConnections = true
						end
					end 
				end 
			end
		until not foundConnections
		if util.tracelog then 
			debugPrint({connectedToMesh1=connectedToMesh1, connectedToMesh2=connectedToMesh2})
		end
		
		local oldVerticies1= verticies1 
		local oldVerticies2 = verticies2
		verticies1 = {}
		verticies2 = {}
		
		
		
		for i = 1, #oldVerticies1 do 
			if angles1[i]-minAngle1 > math.rad(60) and not connectedToMesh1[oldVerticies1[i].mesh] then 
				trace("Rejecting vertex at ",i," as the angle is too large",math.deg(angles1[i]), " mesh was ",oldVerticies1[i].mesh)
			else 
				trace("Accepting vertex at ",i," as the angle is",math.deg(angles1[i]), " mesh was ",oldVerticies1[i].mesh)
				table.insert(verticies1, oldVerticies1[i])
			end 
		end 
		for i = 1, #oldVerticies2 do 
			if angles2[i]-minAngle2 > math.rad(60) and not connectedToMesh2[oldVerticies2[i].mesh] then 
				trace("Rejecting vertex at ",i," as the angle is too large",math.deg(angles2[i]), " mesh was ",oldVerticies2[i].mesh)
			else 
				trace("Accepting vertex at ",i," as the angle is",math.deg(angles2[i]), " mesh was ",oldVerticies2[i].mesh)
				table.insert(verticies2, oldVerticies2[i])
			end 
		end--]]
		trace("The best mesh points were",verticies1[1].mesh, verticies2[1].mesh,"for industries",industry.name, industry2.name)
		local edge   = findEdgeForIndustryCached(industry,cargoType)
		local edge2   = findEdgeForIndustryCached(industry2,cargoType)
		trace("about to check if industry has harbour")
		local station1 = checkIfIndustryHasHarbour(industry, verticies1)
		if station1 then 
			local stationVertex = pathFindingUtil.getVertexForStation(station1 )  	 
			verticies2 = util.copyTableWithFilter(verticies2, function(vertex) return waterMeshUtil.areVerticiesInSameGroup(vertex,stationVertex)end)
		end 
		
		local station2 = checkIfIndustryHasHarbour(industry2, verticies2)
		if station2 then 
			local stationVertex = pathFindingUtil.getVertexForStation(station2 )  	 
			verticies1 = util.copyTableWithFilter(verticies1, function(vertex) return waterMeshUtil.areVerticiesInSameGroup(vertex,stationVertex)end)
		end 
		if #verticies1 == 0 or #verticies2 == 0 then 
			trace("WARNING! No verticies found for ",industryPair[1].name, industryPair[2].name)
			goto continue
		end 
		local initialTargetLineRate = industryPair[7]
		local scores = {}
		scores[1] = distance 
		scores[2] = 2^16/math.max(1, util.scoreWaterBetweenPoints(p0,p1)) -- inverted
		local hasRoadPath = distance < 8000 and edge and edge2 and 0 ~= #pathFindingUtil.findRoadPathBetweenEdges(edge.id, edge2.id)
		scores[3] = hasRoadPath and 1 or 0 -- has a road path decreases usefulness for water connection
		
		
		local dist1 =  vec2.distance(verticies1[1].p, util.v3fromArr(industry.position))
		local dist2 = vec2.distance(verticies2[1].p, util.v3fromArr(industry2.position))
		
		local needsTranshipment1 = dist1> transhipmentThreashold or p0.z >= 50
		local needsTranshipment2 =  dist2 > transhipmentThreashold or p1.z >= 50 or industry2.type == "TOWN"
		trace("The distance from the water to the industries was",dist1,dist2, "needsTranshipment?",needsTranshipment1, needsTranshipment2, " heights:",p0.z,p1.z)
		if station1 then 
			needsTranshipment1 = not util.checkIfStationInCatchmentArea(station1, getConstructionId(industry.id)) 
			trace("Recalculated needsTranshipment1 as ",needsTranshipment1)
		end 
		if station2 and industry2.type ~= "TOWN" then 
			needsTranshipment2 = not util.checkIfStationInCatchmentArea(station2, getConstructionId(industry2.id)) 
			trace("Recalculated needsTranshipment2 as ",needsTranshipment2)
		end
		
		trace("Water mesh1:",verticies1[1].mesh, " water mesh2:",verticies2[1].mesh)
		--scores[5] = isFarm(industry) and 1 or 0 -- tend to avoid farms for trains because of low production and costly field removal
		
 
		table.insert(options, {
			industry1=industry,
			industry2=industry2, 
			edge1=edge, 
			edge2=edge2, 
			scores=scores, 
			straightlinevec=p0-p1,
			station1=station1, 
			station2=station2,
			verticies1=verticies1, 
			verticies2=verticies2,
			initialTargetLineRate = initialTargetLineRate,
			distance=distance,
			cargoType=cargoType,
			needsTranshipment1=needsTranshipment1,
			needsTranshipment2=needsTranshipment2,
			needsNewRoute = needsTranshipment1 or needsTranshipment2,
			validMeshes = validMeshes,
			maxLineRate = industryPair[8],
			})
		
		::continue::
	end
	trace("There were ", count," matching industries for the water connection")
	if #options == 0 then 
		return 
	end
	
	if not param.resultsToReturn then
		-- Use LLM-powered selection when daemon available, falls back to heuristic
		return util.evaluateWinnerWithLLM(options, nil, nil, {type = "water_route"})
	end
	local allResults = util.evaluateAndSortFromScores(options)
	evaluation.setupDisplayScores(allResults)
	local results = {}
	for i = 1, math.min(param.resultsToReturn, #allResults) do
		table.insert(results, allResults[i])
	end
	return results
end

local function checkOk(result) 
	if not result then 	
		return false 
	end 
	--evaluation.recheckResultForStations(result)
	if result.station1 and result.station2 then
		trace("Checking result if already carrying the cargo",result.station2,result.station1)
		if evaluation.checkIfLineIsAlreadyCarryingCargo(result) then 
			return false 
		end 
	end  
	return true 
end 

local function repayLoan(account) 
	trace("repayLoan, loan was",account.loan," balance=",account.balance)
	if evaluation.getBackgoundWorkQueue() > 0 then -- should no be handled by the scedhuled bugget
		--trace("Aborting repay load as there are outstanding items")
		--return 
	end
	-- Only repay with cash above the reserve, so we never drain working capital.
	local effectiveBalance = account.balance - util.scheduledBudget - util.cashReserve
	if account.loan > 0 and effectiveBalance > 0 then 
		local amountToRepay = math.min(account.loan, effectiveBalance)
		trace("Attempting to pay off",amountToRepay)
		amountToRepay = math.floor(amountToRepay/500000)*500000
		if amountToRepay>0 then 
			local journalEntry = api.type.JournalEntry.new() 
			journalEntry.time = -1 -- otherwise crash to desktop !!! 
			journalEntry.amount =  -amountToRepay 	 
			journalEntry.category.type = api.type.enum.JournalEntryType.LOAN 
			api.cmd.sendCommand(api.cmd.make.bookJournalEntry(api.engine.util.getPlayer(), journalEntry), function(res, success) 
				trace("Result of call was to bookJournalEntry to repay",success)
				if success then 
					--evaluation.addWork(evaluateBestNewConnection)
				end
			end) 
		end
	else 
		trace("Unable to repay loan")
	end 
end 
local function findStationsWithFreeTerminals(industry)
	local position = industry.position
	local result = {}
	for i, station in pairs(game.interface.getEntities({radius=350, pos=position}, {type="STATION" , includeData=false})) do
		if util.countFreeTerminalsForStation(station) > 0 then 
			table.insert(result, station) 
		end
	end
	return result 
end 
local function checkForUnfinished(industryPair) 
	trace("checkForUnfinished:  ",industryPair[1].name, industryPair[2].name)
	for i, station1 in pairs(findStationsWithFreeTerminals(industryPair[1])) do
		local carrier1 = util.getCarrierForStation(station1) 
		for i, station2 in pairs(findStationsWithFreeTerminals(industryPair[2])) do
			local carrier2 = util.getCarrierForStation(station2) 
			if carrier1 == carrier2 then 
				trace("Found matched pair of stations",station1,station2," carrier=",carrier1)
				if carrier1 == api.type.enum.Carrier.RAIL then 
					if pathFindingUtil.checkForRailPathBetweenStationFreeTerminals(station1, station2) then 
						evaluation.clearFailuredStatus(carrier1, industryPair[1].id , industryPair[2].id) 
						local param = {}
						param.preSelectedPair  = { industryPair[1].id , industryPair[2].id }
						local result = evaluation.evaluateNewIndustryConnectionForTrains(util.hugeCircle(), param)
						trace("checkForUnfinished: Found unconnected beween",industryPair[1].name,industryPair[2].name," attempting to find result, was found?",(result~=nil))
						if result then 
							return result
						end 
					end 
				end 
			end 
		end 
	end 
	return false 
end 
 
local function getCentralTown()
	local allTowns = getAllTowns() 
	return util.evaluateWinnerFromSingleScore(allTowns, function(town) return math.abs(town.position[1])+math.abs(town.position[2]) end)
end  
local function townToRegion(town) 
	return { 
		towns = {town},
		center = util.v3fromArr(town.position)
	}
end 
local function getCornerToCorner(index) 
	local cornerTowns = evaluation.getCornerTowns()
	local result = {}

	local sameSign = index == 2
	for townId, bool in pairs(cornerTowns) do 
		local town = game.interface.getEntity(townId)
		local condition = util.sign(town.position[1]) == util.sign(town.position[2])
		local shouldAdd = condition == sameSign
		if shouldAdd then 
			table.insert(result, townToRegion(town))
		end 
		if #result == 1 then 
			table.insert(result, townToRegion(getCentralTown()))
		end 
	end 
	return result
end 
 
local function createRegions(isForHighway, index)
	if index > 1 then 
		return getCornerToCorner(index)
	end 
	local allTowns = getAllTowns() 
	-- Note: "large" map is (256 * 28)^2 * 4
	local mapArea = util.getMapAreaKm2()
	local mapBoundary = util.getMapBoundary()
	local result = {}
	
	local numRegions = math.max(4, math.floor(math.sqrt(mapArea/25))^2)
	numRegions = math.min(numRegions,9) -- temp TODO fix for higher region count
	local lengthRatio = math.max(mapBoundary.x, mapBoundary.y)/math.min(mapBoundary.x,mapBoundary.y)
	local squareRoot = math.sqrt(numRegions)
	local isLongThin = lengthRatio > 2.5
	local xIncrement = 2*mapBoundary.x / squareRoot  
	local yIncrement = 2*mapBoundary.y / squareRoot  
	if isLongThin then 
		numRegions = 8
		xIncrement = mapBoundary.x 
		yIncrement = mapBoundary.y/2
	end 
	
	trace("MapArea=",mapArea, "numRegions=",numRegions," squareRoot=",squareRoot, " xIncrement=",xIncrement,"yIncrement=",yIncrement,"lengthRatio=",lengthRatio)
	for x = -mapBoundary.x, mapBoundary.x-1, xIncrement do 
		local startAt = -mapBoundary.y 
		local endAt = mapBoundary.y -1
		local increment = yIncrement
		trace("is x > -mapBoundary.x?",x > -mapBoundary.x,"x=",x,"-mapBoundary.x=",-mapBoundary.x)
		if x-1 >  -mapBoundary.x then -- N.B. annoyingly there seems to be some floating point rounding that makes this comparison incorrect, need to subtract 1 from x to compensate
			startAt = -startAt 
			endAt = -endAt 
			increment = -increment 
		end
		trace("For x=",x,"startAt=",startAt,"endAt=",endAt,"increment=",increment)
		for y = startAt, endAt, increment do 
			local xMin = x
			local xMax = x+xIncrement
			local yMin = y
			local yMax = y+increment
			if increment < 0 then 
				yMin = y+increment
				yMax = y
			end
			local towns = {}
			for townId, town in pairs(allTowns) do 
				if town.position[1] >= xMin and town.position[1] < xMax and town.position[2] >= yMin and town.position[2]< yMax then 
					table.insert(towns,town)
				end 				
			end			
			local center = vec2.new((xMin+xMax)/2, (yMin+yMax)/2)
			trace("createRegions: Setting up region with boundaries at",xMin,xMax,yMin,yMax,"#towns=",#towns, " center at ",center.x, center.y,"for x,y=",x,y)
			if #towns == 1 then 
				trace("Town was",towns[1].id,towns[1].name)
			end 
			if math.abs(center.x) < 1 and math.abs(center.y) < 1 then 
				trace("Skipping this region as the central region")
			else 
				table.insert(result, {
					xMin = xMin,
					xMax = xMax,
					yMin = yMin,
					yMax = yMax,
					towns = towns,
					center = center,
				})
			end
		end 
	end 
	
	if #result == 8 and not isLongThin then 	
		local temp = result[5]
		for i = 5, #result-1 do 
			result[i]=result[i+1]
		end 
		result[8]=temp
		trace("Swapping regions")
	end
	trace("Built result with",#result)
	--assert(#result == numRegions, "expected "..numRegions.." but was "..#result)
	
	return result 
end 

local function setupCompleteRoute(isForHighway, index) 
	trace("setupCompleteRoute: begin, isForHighway?",isForHighway,"index=",index)
	local isTrack = not isForHighway
	local maxGrad = paramHelper.getAbsoluteMaxGradient(isTrack)
	local regions = createRegions(isForHighway, index)
	local largestRegionalTowns = {}
	local isCircularRoute = index == 1
	local function getTownSizeScore(town) 
		return 1/game.interface.getTownCapacities(town.id)[1]
	end 
	local function scoreCornerTown(town)
		if evaluation.isCornerTown(town.id) then 
			if isForHighway then 
				return 0 
			else 
				return 1 
			end 
		else 
			if isForHighway then 
				return 1
			else 
				return 0 
			end 
		end 		
	 
	end 
	for i , region in pairs(regions) do 
		local function distFromCenter(town) 
			return vec2.distance(region.center, util.v3fromArr(town.position))
		end 
		if #region.towns > 0 then 
			table.insert(largestRegionalTowns, util.evaluateWinnerFromScores(region.towns, {50,50, 75}, {getTownSizeScore, distFromCenter, scoreCornerTown}))
		end 
	end 
	if util.tracelog then 
		debugPrint({largestRegionalTowns=largestRegionalTowns}) 
	end
	local alreadySeen = {}
	
	local validationFn = isForHighway and evaluation.evaluateNewPassengerRoadTownConnection or  evaluation.evaluateNewPassengerTrainTownConnection
	local startAt = isCircularRoute and 1 or 2
	local abortOnFirstMisMatch = false 
	for i = startAt, #largestRegionalTowns do 
		local priorTown = i == 1 and largestRegionalTowns[#largestRegionalTowns] or largestRegionalTowns[i-1]
		local town = largestRegionalTowns[i]
		local params = { includeConnected = true, validateNoRailLine = not isForHighway,   ignoreCoolDown = true}
		params.preSelectedPair = { priorTown.id, town.id } 
		params.isHighway = isForHighway 
		--params.validateNoRailLine = true
		local validation = validationFn(util.hugeCircle(), params)
	 
		
		trace("Attempting to validate connection ",priorTown.name, town.name," is valid?",validation ~= nil)
		if not validation then 
			if not isForHighway or abortOnFirstMisMatch then 
				trace("setupCompleteRoute: Aborting due to lack of validation at isForHighway, index=",isForHighway, index)
				return 
			else 
				trace("setupCompleteRoute: Setting abort on first mismatch to true")
				abortOnFirstMisMatch = true 
			end 
		end
		alreadySeen[town.id]=true
	end 
	trace("setupCompleteRoute: validation passed, now building for isForHighway, index=",isForHighway, index)
	local towns = {}
	
	for i = startAt, #largestRegionalTowns do 
		local priorTown = i == 1 and largestRegionalTowns[#largestRegionalTowns] or largestRegionalTowns[i-1]
		
		local town = largestRegionalTowns[i]
		table.insert(towns, priorTown)
		town.isExpressStop = true
		local p0 = util.v3fromArr(priorTown.position)
		local p1 = util.v3fromArr(town.position)
		
		local dist = util.distance(p0, p1)
		local vector = vec3.normalize(p1-p0)
		local searchRadius = 1000
		local townsAdded = 0
		trace("Inspecting for intermediate towns between ",priorTown.name, town.name," dist was",dist)
		if dist > 3000 then 
			for i = 1000, dist-1000, 100 do 
				
				local p = p0+i*vector
				local priorP = util.v3fromArr(priorTown.position)
				local nextP =  util.v3fromArr(town.position)
				local distanceFromPrior = util.distance(priorP, p)
				local distanceToNext = util.distance(p,nextP)
				local minDist = math.min(distanceFromPrior, distanceToNext)
				local searchRadius = minDist*math.sin(math.rad(35))
				local function filterFn(otherTown)
					if  not alreadySeen[otherTown.id] and (otherTown.type == "TOWN" or isTownSupplier(otherTown)) then 
						local p = util.v3fromArr(otherTown.position)
						local distanceFromPrior = vec2.distance(priorP, p)
						local grad1 = math.abs(p.z-priorP.z)/distanceFromPrior

						local distanceToNext = vec2.distance(p,nextP)
						local grad2 = math.abs(nextP.z-p.z)/distanceToNext
						
						if distanceFromPrior < 1000 or distanceToNext < 1000 then 
							return false
						end 
						
						return grad1 <= maxGrad and grad2 <= maxGrad
					end 
					return false 
				end
				local options = util.searchForEntitiesWithFilter(p, searchRadius, "TOWN", filterFn)
				if isForHighway then 
					options = util.combine(options,  util.searchForEntitiesWithFilter(p, searchRadius, "SIM_BUILDING", filterFn))
				end 
				trace("Searching for intermediate town near ",p.x,p.y," at a distance of ",searchRadius, " #options=",#options)
				 
				if #options > 0 then 
					local thirdTown = util.evaluateWinnerFromScores(options, {75,25}, 
						{
							function(otherTown) return util.distanceArr(otherTown.position, priorTown.position)+util.distanceArr(otherTown.position, town.position) end, --distance 
							function(otherTown) return math.abs(otherTown.position[3]-priorTown.position[3])+math.abs(otherTown.position[3]-town.position[3]) end -- height offset
						}
					)
					alreadySeen[thirdTown.id]=true 
					local params = { includeConnected = true, ignoreCoolDown = true }
					params.isHighway = isForHighway
					params.preSelectedPair = { priorTown.id, thirdTown.id } 
					local validation1 = validationFn(util.hugeCircle(), params)
					params.preSelectedPair = { thirdTown.id, town.id } 
					local validation2 = validationFn(util.hugeCircle(), params)
					trace("Found third town from search point at ",p.x,p.y," name=",thirdTown.name, " validation results?",validation1~=nil,validation2~=nil)
					if validation1 and validation2 then 
						townsAdded=townsAdded+1
						thirdTown.isExpressStop = #util.findPassengerTrainStationsForTown(thirdTown.id) > 0
						trace("Inserting the intermediate town, townsAdded=",townsAdded)
						table.insert(towns, thirdTown)
						
						priorTown = thirdTown
					 	
					end 					
				end
			end			
			
		end 
		if abortOnFirstMisMatch and townsAdded == 0 then 
			trace("setupCompleteRoute: Aborting due to lack of validation at isForHighway, index=",isForHighway, index,"townsAdded=",townsAdded)
			return
		end 
		if not isCircularRoute and i == #largestRegionalTowns then -- avoid coming back
			table.insert(towns, town)
		end 
	end 
	local townToRegionRatio = #towns / #largestRegionalTowns
	trace("setup complete route, num towns was",#towns,"townToRegionRatio=",townToRegionRatio)
	local isExpress = false 
		if not isCircularRoute and #towns>0 then 
		towns[1].isExpressStop = true 
		towns[#towns].isExpressStop = true
	end 
	if isTrack and townToRegionRatio > 2 then 
		local countNonExpress = 0
		local centralTown = getCentralTown()
		for i, town in pairs(towns) do 
			if town.id == centralTown.id then 
				town.isExpressStop = true
			end 
			if not town.isExpressStop then 
				countNonExpress = countNonExpress + 1
			end 
		end 
		trace("countNonExpress=",countNonExpress)
		if countNonExpress > 1 then -- TODO could be a ratio ? 
			trace("Setting up express route")
			isExpress = true
		end 
	end 

	if util.tracelog then debugPrint({routeTowns=towns}) end
	return {
		isCompleteRoute = true,
		towns = towns,
		isCircularRoute = isCircularRoute,
		isTrack = isTrack,
		isHighway = isForHighway,
		isExpress = isExpress,
		paramOverrides = {},
	}
end 
 
local function checkForUnfinishedBusRoutes() 
	trace("Begin check for checkForUnfinishedBusRoutes")
	api.engine.system.stationSystem.forEach(function(stationId) 
		xpcall(function() 
			if util.countFreeTerminalsForStation(stationId) > 0 and util.getEntity(stationId).carriers.ROAD and not util.isBusStop(stationId) and not util.getEntity(stationId).cargo then 
				trace("Found unfinished station, attempting to correct ",stationId)
				evaluation.lineManager.setupTownBusNetwork(   stationId, api.engine.system.stationSystem.getTown(stationId), "" )
			end
		end, err)
	end) 
	trace("End check for checkForUnfinishedBusRoutes")
end 

evaluation.queuedResults = {}
function evaluation.enqueueResult(result, costs) 
	result.knownCosts = costs
	table.insert(evaluation.queuedResults, result)
end 
evaluation.alreadyProcessed = {}
evaluation.highwayRequests = {}
evaluation.evaluateBestNewConnectionLastCheckedTimePassengers = -math.huge
evaluation.evaluateBestNewConnectionLastCheckedTimeCargo = -math.huge
evaluation.evaluateBestNewConnectionLastCheckedTime = -math.huge
local function allTownsConnected() 
	for i, town in pairs( getAllTowns()) do 
		if game.interface.getTownReachability(town.id)[2] == 0 then 
			return false 
		end 
	end 
	return true 
end 

function evaluation.evaluateBestNewConnection()
	trace("Begin evaluateBestNewConnection")
	local gameTime= game.interface.getGameTime().time
	evaluation.town2BuildingMap = nil
	evaluation.isAutoBuildMode = true
	local account =  util.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT)
	local balance = account.balance - util.scheduledBudget
	local baseParams = paramHelper.getParams()
	local thresholdBalanceForNewPassengerLink = baseParams.thresholdBalanceForNewPassengerLink
	local thresholdBalanceForNewCargoLink = baseParams.thresholdBalanceForNewCargoLink
	local minBalance = math.min(thresholdBalanceForNewCargoLink, thresholdBalanceForNewPassengerLink)
	local amountToBorrow = math.min(account.maximumLoan - account.loan, 2*minBalance)
	-- Cash-only budget: never count loan headroom as spendable, never borrow.
	local maximumAvailableBalance = balance - util.overdueBudget
	trace("evaluateBestNewConnection: got minBalance, maximumAvailableBalance=",maximumAvailableBalance, " balance was",account.balance," scheduledBudget was",util.scheduledBudget,"overdueBudget=",util.overdueBudget)
	local function budgetCheck(result, distance)
		result.targetThroughput = result.initialTargetLineRate
		result.totalTargetThroughput = result.initialTargetLineRate
		result.stationLength = paramHelper.getStationLength()
		local consistInfo = evaluation.lineManager.estimateInitialConsist(result, distance)
		local consistCost = consistInfo.info.cost
		local numberOfVehicles = consistInfo.numberOfVehicles
		local routeBudget = (distance/1000) * baseParams.assumedCostPerKm
		local waterFraction, waterDistance = util.getWaterRouteDetailBetweenPoints(result.p0, result.p1)
		local bridgeCost = (waterDistance/1000) * 10 * baseParams.assumedCostPerKm -- approximation bridges cost 10 times more
		trace("Assuming bridgeCost of ",bridgeCost,"added to route cost",routeBudget)
		routeBudget = routeBudget + bridgeCost
		
		local totalBudget = routeBudget + consistCost*numberOfVehicles
		local p = vehicleUtil.calculateProjectedProfit(consistInfo.vehicleConfig, consistInfo.info,result )
		if p.projectedProfit < 0 then 
			trace("WARNING! negative projected profit for result, adjusting budget, was ",totalBudget)
			totalBudget = totalBudget - 10*p.projectedProfit -- we allow if plenty of cash, need to be able to allow a link in the chain even if unprofitable
		end 
		local withinBudget = totalBudget < maximumAvailableBalance 
		trace("Checking the budget, the consistInfoCost was ",consistCost,"numberOfVehicles=",numberOfVehicles," distance=",distance, "routeBudget=",routeBudget," giving totalBudget=",totalBudget," projectedProfit=",p.projectedProfit," withinBudget=",withinBudget)
		return withinBudget
	end
	
	local function borrow() 	
		-- DISABLED (Dave 2026-09-05): never pull loans. Only build with cash.
		trace("borrow: loan requests disabled - only spending cash (amountToBorrow was",amountToBorrow,")")
		return
	end 
	
	if balance < minBalance then 
		if account.loan < account.maximumLoan then 
			
			trace("The newProposedBalance is",newProposedBalance, "based on amount to borrow",amountToBorrow,"loan=",loan)
			if maximumAvailableBalance > minBalance then 
				borrow()
				--return
			end 
		end
		repayLoan(account) 
		return "sleeping"
	end 
	local pauseTime = 100
	local lastTime = math.min(evaluation.evaluateBestNewConnectionLastCheckedTimePassengers, evaluation.evaluateBestNewConnectionLastCheckedTimeCargo)
	local shouldSleep =  gameTime < lastTime + pauseTime 
	if  gameTime < evaluation.evaluateBestNewConnectionLastCheckedTime + 60 then 
		shouldSleep = true 
	end 
	local shouldSleepForPassengers = gameTime < 	evaluation.evaluateBestNewConnectionLastCheckedTimePassengers + pauseTime
	local shouldSleepForCargo = gameTime < evaluation.evaluateBestNewConnectionLastCheckedTimeCargo + pauseTime
	trace("evaluateBestNewConnection: shouldSleep?",shouldSleep,"shouldSleepForPassengers?",shouldSleepForPassengers,"shouldSleepForCargo?",shouldSleepForCargo,"gameTime=",gameTime,"evaluation.evaluateBestNewConnectionLastCheckedTimePassengers=",evaluation.evaluateBestNewConnectionLastCheckedTimePassengers)
	if shouldSleep then 
		trace("evaluateBestNewConnection: sleeping for a bit")
		repayLoan(account) 
		return "sleeping"
	end
	evaluation.evaluateBestNewConnectionLastCheckedTime=gameTime
	if #evaluation.queuedResults > 0 then 
		local result = evaluation.queuedResults[1]
		trace("evaluateBestNewConnection: found enqueueResult, checking costs",result.knownCosts,"against balance",maximumAvailableBalance)
		if 1.5*result.knownCosts < maximumAvailableBalance then 
			table.remove(evaluation.queuedResults, 1)
			return result 
		end 
		trace("Insufficient, balance aborting")
		return "sleeping"
	end 
	
	
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local param = {}
	checkForUnfinishedBusRoutes() 
	param.isHighwayAvailable = util.year() >= 1925
	param.isAirFieldAvailable = util.year() >= 1920
	param.isAirportAvailable = util.year()>= 1950
	--local thresholdForAirPort = 
	
	if param.isAirportAvailable and maximumAvailableBalance > 2*baseParams.thresholdBalanceForNewPassengerLink and not evaluation.airCornerTownsComplete and util.year() >= 1952 and not shouldSleepForPassengers then 
		local options = {} 
		for cornerTown, bool in pairs(evaluation.getCornerTowns()) do 
			for cornerTown2, bool in pairs(evaluation.getCornerTowns()) do 
				if cornerTown ~= cornerTown2 then 
					local param = {}
					param.preSelectedPair  = { cornerTown , cornerTown2 }
					param.minDist = baseParams.minimumAirPassengerDistance
					param.maxDist = math.huge
					param.includeConnected = true
					local result = evaluation.evaluateNewPassengerAirTownConnection(util.hugeCircle(), param ) 
					
					trace("Found result for connection between",cornerTown ," and ",cornerTown2,"?",result~=nil)
					if result then 
						result.isAutoBuildMode = true
						table.insert(options, { result = result, scores = { result.initialTargetLineRate}})
					end
				end
			end 
		end 
		
		if #options > 0 then 
		 
			evaluation.evaluateBestNewConnectionLastCheckedTimePassengers  = gameTime + 600
			return util.evaluateWinnerFromScores(options).result
		end 
		trace("No new result found, marking airCornerTownsComplete")
		evaluation.airCornerTownsComplete = true -- this is only a performance optimisation , does not need serialization
	end 
	
	param.minDist = 0 
	local maxDist = 1000*(maximumAvailableBalance / baseParams.assumedCostPerKm)
	if util.year()<1900 then 
		param.maxHeight = 50 
	else 
		param.maxHeight = 75
	end 
	local maxDistOnCurrentBalance = 1000*(balance / baseParams.assumedCostPerKm)
	trace("Calculated maxDist based on ",maximumAvailableBalance," as ",maxDist, " maxDistOnCurrentBalance=",maxDistOnCurrentBalance)
	local circle = util.hugeCircle()
	if not evaluation.checkedAllWaterRoutes or evaluation.lastCheckedWaterRoutesDate ~= util.year() then 
		param.transhipmentRange = 500
		evaluation.checkedAllWaterRoutes = false 
		profiler.beginFunction("evaluateNewWaterIndustryConnections")
		local result = evaluation.evaluateNewWaterIndustryConnections(circle, param)
		profiler.endFunction("evaluateNewWaterIndustryConnections")
		if result then 
			evaluation.evaluateBestNewConnectionLastCheckedTimeCargo=gameTime
			result.carrier = api.type.enum.Carrier.WATER 
			result.isCargo = true
			result.isAutoBuildMode = true
			return result 
		end 
		trace("No new water route was found")
		evaluation.checkedAllWaterRoutes = true
		evaluation.lastCheckedWaterRoutesDate = util.year()
	end 
	param.maxDist = maxDist 
	--param.maxDist = math.huge
	param.transhipmentRange = math.huge
	
	if maximumAvailableBalance > baseParams.thresholdBalanceForNewCompleteRoute and not evaluation.alreadyCreatedCompleteRoute and not shouldSleepForPassengers then 
		for i = 1, 3 do 
			local result = setupCompleteRoute(false, i) 
			trace("CompleteRouteForTrains at i=",i,"found result?",result~=nil)
			if result then 
				evaluation.evaluateBestNewConnectionLastCheckedTimePassengers  = gameTime + 600 
				if i == 3 then 
					evaluation.alreadyCreatedCompleteRoute = true 
					trace("Marking alreadyCreatedCompleteRoute as true for i=",i)
				end
				return result 
			end
		end 
		trace("Marking alreadyCreatedCompleteRoute as true from fallthrough")
		evaluation.alreadyCreatedCompleteRoute = true			
	end
	if maximumAvailableBalance > baseParams.thresholdBalanceForNewCompleteRoute*2 and util.year() > 1925 and not evaluation.alreadyCreatedCompleteHighwayRoute and (allTownsConnected() or evaluation.alreadyCreatedCompleteRoute) and not shouldSleepForPassengers then 
		for i = 1, 3 do 
			local result = setupCompleteRoute(true, i) 
			trace("CompleteRouteForHighway at i=",i,"found result?",result~=nil)
			if result then 
				return result 
			end
		end 
		trace("Marking alreadyCreatedCompleteHighwayRoute as true")
		evaluation.alreadyCreatedCompleteHighwayRoute = true
	end
	if #evaluation.lineManager.railLineUpgradeRequests > 10 then 
		trace("Detected large number of upgrade requests")
		--evaluation.lineManager.upgradeBusiestLines() -- TODO this needs to work better
	end 
 
	if evaluation.alreadyCreatedCompleteRoute and not evaluation.alreadyDevelopedStationOffside and allTownsConnected() then 
		trace("Making call to developStationOffside")
		api.engine.forEachEntityWithComponent(function(town) 
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","developStationOffside", "", {
				town=town}))
		end, api.type.ComponentType.TOWN)
		evaluation.alreadyDevelopedStationOffside  = true 
	end 
 
	local cityPairs = {} 
	math.randomseed(os.clock())
	local processHighway = math.random() > 0.5 and evaluation.alreadyCreatedCompleteHighwayRoute 
	if maximumAvailableBalance > baseParams.thresholdBalanceForNewHighwayLink and #evaluation.lineManager.highwayRequests > 0 and util.year() >= 1925 and processHighway and false then -- temp disabled
		trace("evaluateBestNewConnection: checking requests for highway there were",#evaluation.lineManager.highwayRequests)
		local line = table.remove(evaluation.lineManager.highwayRequests)
		if #line.stops > 1 then 
			local station1 = util.stationFromStop(line.stops[1])
			local station2 = util.stationFromStop(line.stops[2])
			local town1 = api.engine.system.stationSystem.getTown(station1)
			local town2= api.engine.system.stationSystem.getTown(station2)
		 
			
			if town1~=town2 and not evaluation.alreadyProcessed[townHash(town1,town2)] then 
				trace("Processing request for highway between",town1, town2)
				evaluation.alreadyProcessed[townHash(town1,town2)]=true
			
				if not pathFindingUtil.areTownsConnectedWithHighway(town1, town2) then
					--param.preSelectedPair = nil
					param.preSelectedPair = { town1, town2 } 
					param.isHighway = true 
					local result = evaluation.evaluateNewPassengerRoadTownConnection(util.hugeCircle(), param ) 
					trace("Result was found for highway between towns?",result~=nil)
					if result then 
						result.carrier  = api.type.enum.Carrier.ROAD
						result.isHighway = true
						result.buildHighway = true
						result.isAutoBuildMode = true
						return result 
					end
					param.isHighway = false
					param.preSelectedPair= nil
				end
			end
			
		end
	end 
	local includeTowns = true 
	local includeSourceTowns = true 
	local industryPairs = {} 
	

	if maximumAvailableBalance > thresholdBalanceForNewCargoLink and not shouldSleepForCargo  then 
		local filterFn = function(industryPair)
			local sourceCount = industryPair[10] or 0
			if industryPair[2].type~="TOWN" and sourceCount > 0 then -- do not ship more cargo to the industry until its output is shipping
				local itemsShipped = industryPair[2].itemsShipped._sum
				local canAccept =  itemsShipped > 0 
				trace("Found industry with existing sources",industryPair[2].name,"sourceCount =",sourceCount,"itemsShipped=",itemsShipped, "canAccept?",canAccept)
				return canAccept
			end
			return true
		end
		trace("evaluateBestNewConnection: getting industry pairs")
		if util.year() >= 1980 and false then 
			local result = evaluation.evaluateNewAirIndustryConnections(circle, param ) 
			if result then 
				trace("evaluateBestNewConnection: Found air industry connection result=",result)
				result.isCargo = true 
				result.carrier = api.type.enum.Carrier.AIR 
				result.isAutoBuildMode = true
				return result
			end 
		--[[	if util.tracelog then 
				debugPrint(results)
			end
			for i, result in pairs(results) do 
				trace("evaluateBestNewConnection: Found air industry connection result=",result)
				
				return result
			end ]]--
		end 
		industryPairs = findMatchingIndustries(circle,includeTowns, filterFn, param.maxDist, circle , includeSourceTowns)
	end
	
	if maximumAvailableBalance > thresholdBalanceForNewPassengerLink and (evaluation.airCornerTownsComplete or util.year() < 1952) and not shouldSleepForPassengers and evaluation.alreadyCreatedCompleteRoute then 
		trace("evaluateBestNewConnection: getting city pairs")
		local cityParam = util.shallowClone(param)
		if not  vehicleUtil.isHighSpeedTrainsAvailable() then 
			cityParam.maxDist = math.min(cityParam.maxDist, baseParams.thresholdForHighSpeedRail)
			trace("set the maxDist to",cityParam.maxDist)
		end
		
		cityPairs = getCityPairs(circle, AUTOCARRIER, evaluation.getDistFilter(cityParam) , param.includeConnected, cityParam)
		trace("evaluateBestNewConnection: getting cityParis, maxDist was",cityParam.maxDist,"num results:",#cityPairs)
	else 
		trace("evaluateBestNewConnection: Supppressed getting city pairs")
	end 	
 
	if util.year() >= 1925 and not evaluation.upgradeMainConnectionsCalled and maximumAvailableBalance > baseParams.thresholdForUpgradeMainConnections then 
		evaluation.upgradeMainConnectionsCalled = true
		local params = {}
		trace("Sending command for upgradeMainConnectionsCalled")
		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","upgradeMainConnections", "", params), evaluation.standardCallback)
		return "sleeping"
	end 
	if util.year() >= 1925 and not evaluation.buildMainConnectionHighwaysCalled and maximumAvailableBalance > baseParams.thresholdForMainConnectionHighways and false then -- temp disabled
		evaluation.buildMainConnectionHighwaysCalled = true
		local params = {}
		trace("Sending command for mainConnectionHighways")
		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildMainConnectionHighways", "", params), evaluation.standardCallback)
		return "sleeping"
	end 
	


	local options = {} 
	local maxExistingStationBonus = 0
	for i, cityPair in pairs(cityPairs) do 
		local p0 = util.v3fromArr(cityPair.town1.position)
		local p1 = util.v3fromArr(cityPair.town2.position)
		local distance = util.distance(p0,p1)
		local grad = math.abs(p0.z-p1.z)/distance
		local existingStationBonus =  cityPair.scores[7]
		maxExistingStationBonus = math.max(existingStationBonus, maxExistingStationBonus)
		cityPair.initialTargetLineRate = math.max(cityPair.initialTargetLineRate, 1) -- avoid divide by zero this will screw up the ranking
		table.insert(options,{ 
			result = cityPair,
			p0=p0,
			p1=p1, 
			initialTargetLineRate = cityPair.initialTargetLineRate,
		
			scores = {
				distance , 
				grad , 
				util.scoreTerrainBetweenPoints(p0,p1),
				existingStationBonus,
				1/cityPair.initialTargetLineRate,
				1
			}, 
			isCargo = false })
				
	end 
	for i, industryPair in pairs(industryPairs) do 
		local p0 = industryPair[3]
		local p1 = industryPair[4]
		local distance =util.distance(p0,p1)
		local grad = math.abs(p0.z-p1.z)/distance
		local existingSources = industryPair[10]
		local unfinishedConnection = checkForUnfinished(industryPair)
		if unfinishedConnection then 
			trace("Found unfinishedConnection, attempting to fix",industryPair[1].name, industryPair[2].name)
			return unfinishedConnection 
		end 
		local initialTargetLineRate = math.max(industryPair[7],1)
		trace("evaluateBestNewConnection: inserting", industryPair[1].name, industryPair[2].name,"for consideration")
		table.insert(options,{ 
			result = industryPair,
			p0=p0,
			p1=p1, 
			initialTargetLineRate = initialTargetLineRate,
			cargoType = industryPair[6],
			scores = {
				distance ,
				grad,
				util.scoreTerrainBetweenPoints(p0,p1), 
				0,
				1/initialTargetLineRate,
				0,
			},
			isCargo = true })
	end 
	if #options == 0 then 
		trace("No options found in evaluateBestNewConnection, repaying loan")
		repayLoan(account)
		return 
	end 
	local weights = {
		75, -- distance 
		25, -- grad 
		25, -- terrain roughness 
		50, -- existing station bonus
		100, -- initial target line rate
		50, -- cargo bonus
	}
	local sortedResults = util.evaluateAndSortFromScores(options, weights)
	trace("evaluateBestNewConnection: after sorting the result count was",#sortedResults,"of",#options)
	for i,  best in pairs(sortedResults) do 
		trace("evaluateBestNewConnection: evaluting option at",i)
		local distance = best.scores[1]
		
		if distance > maxDistOnCurrentBalance then 
			trace("Detected distance > maxDistOnCurrentBalance:",distance,maxDistOnCurrentBalance, "borrowing")
			borrow() 
			   
		end 
		
		
		if best.isCargo then 
			param.preSelectedPair  = { best.result[1].id , best.result[2].id }
			trace("evaluateBestNewConnection: inspecting industry pair ",best.result[1].name, best.result[2].name)
		else 
			param.preSelectedPair = { best.result.town1.id, best.result.town2.id }
			trace("evaluateBestNewConnection: inspecting town pair ",best.result.town1.name, best.result.town2.name)
		end
		local waterFraction, waterDistance = util.getWaterRouteDetailBetweenPoints(best.p0, best.p1) 
		local shouldBuildWaterOrAirRoute = waterFraction > 0.5 or waterDistance > 1000
		trace("evaluateBestNewConnection: Evaluating the result, waterFraction=",waterFraction, " waterDistance=",waterDistance, "determined shouldBuildWaterOrAirRoute=",shouldBuildWaterOrAirRoute, " totalDistance=",distance, "for",param.preSelectedPair[1],param.preSelectedPair[2])
		
		 
		 
		if shouldBuildWaterOrAirRoute then 
			if best.isCargo then 
				profiler.beginFunction("evaluateNewWaterIndustryConnections2")
				local result = evaluation.evaluateNewWaterIndustryConnections(circle, param)
				profiler.beginFunction("evaluateNewWaterIndustryConnections2")
				if result and (result.needsTranshipment1 or result.needsTranshipment2) then 
					if util.year() < 1900 and result.maxLineRate > 200 then 
						trace("aborting as requires too much transhipment")
						result = nil 
					end
				end 
				if checkOk(result) then 
					result.isCargo = true 
					result.carrier = api.type.enum.Carrier.WATER 
					result.isAutoBuildMode = true
					evaluation.evaluateBestNewConnectionLastCheckedTimeCargo=gameTime
					return result 
				else
					trace("WARNING! Unable to build water option, falling through")
				end 
			else 
				if distance < 4000 then 
					profiler.beginFunction("evaluateNewWaterTownConnections")
					local result = evaluation.evaluateNewWaterTownConnections(circle, param)
					profiler.endFunction("evaluateNewWaterTownConnections")
					if checkOk(result) then 
						result.isCargo = false 
						result.carrier = api.type.enum.Carrier.WATER 
						result.isAutoBuildMode = true
						evaluation.evaluateBestNewConnectionLastCheckedTimePassengers=gameTime
						return result 
					else
						trace("WARNING! Unable to build water option, falling through")
					end 
				elseif param.isAirFieldAvailable   then 
					local cornerTowns = evaluation.getCornerTowns()
					local hasCornerTowns = cornerTowns[best.result.town1.id] or cornerTowns[best.result.town2.id]
					local result = evaluation.evaluateNewPassengerAirTownConnection(circle, param)
					local canAccept = evaluation.airCornerTownsComplete or not hasCornerTowns
					trace("Airfield is availble airCornerTownsComplete?",airCornerTownsComplete," hasCornerTowns?",hasCornerTowns)
					if result and canAccept then 
						result.isCargo = false 
						result.carrier = api.type.enum.Carrier.AIR 
						result.isAutoBuildMode = true
						evaluation.evaluateBestNewConnectionLastCheckedTimePassengers=gameTime
						return result 
					else
						trace("WARNING! Unable to build air option, falling through")
					end 
				else 
					trace("Aborting the option as it is too far")
				end 
			end 
		end  
		if best.isCargo then 
			local minDist = math.max(2000, paramHelper.getParams().minimumCargoTrainDistance)
			local shouldBuildRail = distance > minDist and best.result[1].type~="TOWN" and best.result[2].type~="TOWN"
			if best.result[2].type=="TOWN" and distance > paramHelper.getParams().maximumTruckDistance then 
				shouldBuildRail = true 
			end 
			if shouldBuildRail and isRecyclingPlant(best.result[1].id) and util.year() >= 1900 then 
				trace("Overriding shouldBuildRail for recycling plant")
				shouldBuildRail = false 
			end 
			local maxLineRate = best.result[8] or best.result[7]
			if shouldBuildRail and util.year() > 2000 then 
				if maxLineRate <= 200 then 
					trace("Overriding shouldbuildRail to false based on maxLineRate",maxLineRate)
					shouldBuildRail = false
				end 
			end 
			if shouldBuildRail and util.year() > 2020 then 
				local mapBoundary = util.getMapBoundary()
				local mapSize = math.max(mapBoundary.x,mapBoundary.y)*2
				shouldBuildRail = distance > mapSize / 2 and maxLineRate <= 400
				trace("inspecting shouldBuildRail again for distance",distance,"compared to mapSize=",mapSize,"new ShouldBuildRail=",shouldBuildRail,"and lineRate=",maxLineRate)
			end 
			trace("Inspecting, shouldBuildRail=",shouldBuildRail,"distance=",distance,"cargoType=",best.cargoType,"maximumTruckDistance=",paramHelper.getParams().maximumTruckDistance)
			if shouldBuildRail and distance < paramHelper.getParams().maximumTruckDistance and best.cargoType == "GRAIN" then 
				shouldBuildRail = false 
				trace("Overriding target shouldBuildRail to false for grain a distance of ",distance)
			elseif not shouldBuildRail then 
				
				trace("Inspecting the maxLineRate of",maxLineRate, " rates were ", best.result[8] , best.result[7])
				if util.year() < 1900 and maxLineRate > 200 then 
					trace("Overriding target shouldBuildRail to true ")
					shouldBuildRail = true
				end 
			end 
			if not shouldBuildRail and 
				evaluation.checkIfFailed(api.type.enum.Carrier.ROAD, best.result[1].id, best.result[2].id) then 
				trace("Previous attempt to build road failed, trying rail")
				shouldBuildRail = true
			end 
			if shouldBuildRail then 
				local result = evaluation.evaluateNewIndustryConnectionForTrains(circle, param ) 
				if checkOk(result) and budgetCheck(result, distance, balance) then 
					
					result.carrier  = api.type.enum.Carrier.RAIL
					result.isCargo = true
					result.isAutoBuildMode = true
					
					evaluation.evaluateBestNewConnectionLastCheckedTimeCargo=gameTime
					return result 
				else 
					trace("aborting evaluateNewIndustryConnectionForTrains as failed checks",best.result[1].name, best.result[2].name)
				end 
			else 
				local result = evaluation.evaluateNewIndustryConnectionWithRoads(circle, param ) 
				if checkOk(result) then 
					result.carrier  = api.type.enum.Carrier.ROAD 
					result.isCargo = true
					result.isAutoBuildMode = true
					evaluation.evaluateBestNewConnectionLastCheckedTimeCargo=gameTime
					return result 
				else 
					trace("aborting evaluateNewIndustryConnectionWithRoads as failed checks",best.result[1].name, best.result[2].name)
				end  
			end 
		else 
			if param.isAirFieldAvailable and distance > util.getMaxMapHalfDistance() then 
			
			end
			if not param.isAirportAvailable and   waterDistance > 2000  then 
				trace("Suppressing build due to long distance over water")
				goto continue
			end 
			local result = evaluation.evaluateNewPassengerTrainTownConnection(circle, param ) 
			if result and budgetCheck(result, distance, balance) then 
				result.carrier  = api.type.enum.Carrier.RAIL 
				result.isAutoBuildMode = true
				evaluation.evaluateBestNewConnectionLastCheckedTimePassengers=gameTime
				return result 
			else 
				trace("Passenger train failed validation for ", best.result.town1.name, best.result.town2.name)
			end	
			-- temp disabled
			--[[trace("Not able to connect cities with rail, trying highway")
			param.isHighway = true 
			--param.preSelectedPair = nil
			local result = evaluation.evaluateNewPassengerRoadTownConnection(circle, param ) 
			if result and balance > baseParams.thresholdBalanceForNewHighwayLink and false then 
				result.carrier  = api.type.enum.Carrier.ROAD
				result.isHighway = true
				result.buildHighway = true
				result.isAutoBuildMode = true
				return result 
			end 
			trace("No highway, continuing")
			param.isHighway = false]]--
		end  
		trace("evaluateBestNewConnection: Unable to find option, continueing...")
		::continue::
	end

	trace("Fallen through evaluateBestNewConnection, defaulting to repay loan")
	repayLoan(account)
	if not shouldSleepForPassengers then 
		trace("evaluateBestNewConnection: Pausing for passengers")
		evaluation.evaluateBestNewConnectionLastCheckedTimePassengers = gameTime + 600 
	end 
end

function evaluation.setupDisplayScores(results) 
	if #results == 1 then -- prevent NaN below
		results[1].displayScore = 100
		results[1].displayScores = {}
		for j = 1, #results[1].scoreNormalised do
			results[1].displayScores[j]=math.round(100-results[1].scoreNormalised[j])
		end
		return
	end

	local largest = results[#results].score 
	local smallest = results[1].score
	local normalisation = 1/(largest-smallest) 

	trace("Setting up scores, largest=",largest," smallest=",smallest," normalisation=",normalisation)
	for i = 1, #results do
		-- invert the sign as typically people associate higher with better
		results[i].displayScore = math.round(100 - 100*((results[i].score-smallest)*normalisation))
		if largest == smallest then 
			results[i].displayScore = 50
		end
		results[i].displayScores = {}
		for j = 1, #results[i].scoreNormalised do
			results[i].displayScores[j]=math.round(100-results[i].scoreNormalised[j])
		end
	end
end

function evaluation.evaluateNewIndustryConnectionRoadOrRail()
	trace("Begin evaluateNewIndustryConnectionRoadOrRail")
		local function budgetCheck() return true end-- TODO
		
		local industryPairs = {} 
		local param = {}
		param.maxDist = math.huge
		local circle = {radius=math.huge, pos={0,0,0}}
	--if balance > thresholdBalanceForNewCargoLink then 
		local filterFn = function(industryPair)
			local sourceCount = industryPair[10]
			if industryPair[2].type~="TOWN" and sourceCount > 0 then -- do not ship more cargo to the industry until its output is shipping
				local itemsShipped = industryPair[2].itemsShipped._sum
				local canAccept =  itemsShipped > 0 
				trace("Found industry with existing sources",industryPair[2].name,"sourceCount =",sourceCount,"itemsShipped=",itemsShipped, "canAccept?",canAccept)
				return canAccept
			end
			return true
		end
		local includeTowns = true
		industryPairs = findMatchingIndustries(circle,includeTowns, filterFn, param.maxDist, circle , includeSourceTowns)
	--end
	local options = {} 
	local maxExistingStationBonus = 0
	
	for i, industryPair in pairs(industryPairs) do 
		local p0 = industryPair[3]
		local p1 = industryPair[4]
		local distance =util.distance(p0,p1)
		local grad = math.abs(p0.z-p1.z)/distance
		local existingSources = industryPair[10]
		local unfinishedConnection = checkForUnfinished(industryPair)
		if unfinishedConnection then 
			trace("Found unfinishedConnection, attempting to fix",industryPair[1].name, industryPair[2].name)
			return unfinishedConnection 
		end 
		local initialTargetLineRate = industryPair[7]
		table.insert(options,{ 
			result = industryPair,
			p0=p0,
			p1=p1, 
			initialTargetLineRate = initialTargetLineRate,
			cargoType = industryPair[6],
			scores = {
				distance ,
				grad,
				util.scoreTerrainBetweenPoints(p0,p1), 
				maxExistingStationBonus,
				1/initialTargetLineRate
			},
			isCargo = true })
	end 
	if #options == 0 then 
		trace("No options found in evaluateBestNewConnection, repaying loan")
		--repayLoan(account)
		return 
	end 
	local weights = {
		75, -- distance 
		25, -- grad 
		25, -- terrain roughness 
		50, -- existing station bonus
		100 -- initial target line rate
	}
	--local best = util.evaluateWinnerFromScores(options, weights)
	
	local isSpreadIndustriesInstalled = false 
	local appConfig = api.util.getAppConfig()
	for i , mod in pairs(appConfig.activeMods) do 
		if string.find(mod.name,"SpreadIndustries") then 
			trace("Found spreadIndustries")
			isSpreadIndustriesInstalled = true
			break
		end 
	end 
	local minDist = math.max(2000, paramHelper.getParams().minimumCargoTrainDistance)
	if isSpreadIndustriesInstalled then 
		local boundary = util.getMapBoundary()
		minDist = math.max(minDist, math.max(boundary.x,boundary.y))
		trace("Found spreadIndustries, setting minDist to ",minDist)
	end
	for i,  best in pairs(util.evaluateAndSortFromScores(options, weights)) do 
		param.preSelectedPair  = { best.result[1].id , best.result[2].id }
		
		local distance = best.scores[1]
		local shouldBuildRail = distance > minDist and best.result[1].type~="TOWN" and best.result[2].type~="TOWN"
		trace("Got cargo type ",best.cargoType," shouldBuildRail?",shouldBuildRail)
		if best.cargoType == "GRAIN" and util.year() > 1900 then 
			shouldBuildRail = false 
		elseif best.cargoType == "IRON_ORE" or best.cargoType == "COAL" then 
			shouldBuildRail = true
		end
		if not shouldBuildRail then 
			local maxLineRate = best.result[8] or best.result[7]
			trace("Inspecting the maxLineRate of",maxLineRate, " rates were ", best.result[8] , best.result[7])
			if util.year() < 1900 and maxLineRate > 200 then 
				trace("Overriding target shouldBuildRail to true ")
				shouldBuildRail = true
			end 
		end 
		if not shouldBuildRail and 
			evaluation.checkIfFailed(api.type.enum.Carrier.ROAD, best.result[1].id, best.result[2].id) then 
			trace("Previous attempt to build road failed, trying rail")
			shouldBuildRail = true
		end 
		if shouldBuildRail and best.result[1].type=="TOWN" then -- there is no code for this
			shouldBuildRail = false 
		end 
		if shouldBuildRail then 
			local result = evaluation.evaluateNewIndustryConnectionForTrains(circle, param ) 
			if checkOk(result) and budgetCheck(result, distance, balance) then 
				
				result.carrier  = api.type.enum.Carrier.RAIL
				result.isCargo = true
				return result 
			else 
				if util.tracelog then debugPrint({param=param, result = result}) end
				trace("WARNING! shouldBuildRail: The result was invalid")
			end   
		else 
			local result = evaluation.evaluateNewIndustryConnectionWithRoads(circle, param ) 
			if checkOk(result) then 
				result.carrier  = api.type.enum.Carrier.ROAD 
				result.isCargo = true 
				return result 
			else 
				if util.tracelog then debugPrint({param=param, result = result}) end
				trace("WARNING! The result was invalid")
			end 		
		end 
	end
end 

function evaluation.checkForAppropriateCargoStation(industry, carrier, verticies, needsTranshipment)
	if carrier == api.type.enum.Carrier.RAIL then 
		return checkIfIndustryHasRailStation(industry)
	elseif carrier ==  api.type.enum.Carrier.ROAD then 
		return  checkIfIndustryHasTruckStation(industry)
	elseif carrier == api.type.enum.Carrier.WATER then
		return checkIfIndustryHasHarbour(industry, verticies, needsTranshipment) 
	end	
end

function evaluation.recheckResultForStations(result, isCargo, carrier)
	if  isCargo then  
		result.station1 = evaluation.checkForAppropriateCargoStation(result.industry1, carrier, result.verticies1, result.needsTranshipment1) 
		result.station2 = evaluation.checkForAppropriateCargoStation(result.industry2, carrier, result.verticies2, result.needsTranshipment2) 
		result.edge1 = findEdgeForIndustryOrTown(result.industry1,result.cargoType)
		result.edge2 = findEdgeForIndustryOrTown(result.industry2,result.cargoType)
		if result.carrier ==  api.type.enum.Carrier.ROAD and result.station2   then 
			if result.isTown and not util.isTruckStop(result.station2) then 
				trace("recheckResultForStations: Overriding the result2 to nil as ",result.station2,"is not a truck stop")
				result.station2 = nil
			end 
		end 
		
	else  
		result.station1 = getStationForTown(carrier, result.town1, result)  
		result.station2 = getStationForTown(carrier, result.town2, result) 
	end
end
local function scoreDisplay(result)
	local view = api.gui.comp.TextView.new(tostring(result.displayScore))
	local tooltipText = ""
	for i = 1, #result.displayScores do 
		tooltipText = tooltipText.._(paramHelper.cityConnectionScoreWeightsLabels[i])..": "..tostring(result.displayScores[i]).."\n"
	end
	tooltipText = string.sub(tooltipText,1, -2)
	trace("setting tooltipText to ",tooltipText)
	view:setTooltip(tooltipText)
	return view
end

local function buildDistSlider(param)
	local lookupTable = {0, 250}
	local lookupTableInv = {}
	for i = 3, 10 do 
		lookupTable[i]=lookupTable[i-1]*2
		
	end
	--debugPrint(lookupTable)
	for i = 1, #lookupTable do 
		lookupTableInv[lookupTable[i]]=i
	end
	local boxLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	local function newSlider(isMin, otherSlider)
		boxLayout:addItem(api.gui.comp.TextView.new(_(isMin and "Min:" or "Max:")))
		local valueDisplay = api.gui.comp.TextView.new(api.util.formatLength(isMin and param.minDist or param.maxDist))
		local slider = api.gui.comp.Slider.new(true) 
		slider:setMinimum(1)
		slider:setMaximum(#lookupTable)
		slider:setStep(1)
		slider:setPageStep(1)
		local size = slider:calcMinimumSize()
		size.w = size.w+120
		slider:setMinimumSize(size)
		slider:onValueChanged(function(x) 
			local dist =  lookupTable[x]
			valueDisplay:setText(api.util.formatLength(dist))
			if isMin then 
				param.minDist = dist
				if x > otherSlider[1]:getValue() then
					otherSlider[1]:setValue(x, true)
				end
			else 
				param.maxDist = dist
				if x < otherSlider[1]:getValue() then
					otherSlider[1]:setValue(x, true)
				end
			end
			trace("Set minDist to ",param.minDist, " x was ",x)
		end)
		boxLayout:addItem(slider)
		boxLayout:addItem(valueDisplay)
		return slider
	end 
	
	local function indexForValue(value) 
		trace("getting index for value",value)
		for i =1 , #lookupTable do
			if lookupTable[i] >= value   then 
				trace("returning ",i)
				return i 
			end
		end 
		trace("returning ",#lookupTable)
		return #lookupTable
	end
	local slider2Holder = {}
	local slider = newSlider(true, slider2Holder)
	local slider2 = newSlider(false, {slider})
	slider2Holder[1]=slider2
	slider:setValue(indexForValue(param.minDist),false)
	slider2:setValue(indexForValue(param.maxDist),false)
	return boxLayout
end

function evaluation.buildTownChoicesPanel(circle, carrier, buildResultFn, optionsComp)
	local results = {} 
	local param = {}
	param.resultsToReturn = 5
	local fn 
	local baseParams = paramHelper.getParams()
	param.minDist = 0
	param.maxDist = 8000
		
	local boxLayout =  api.gui.layout.BoxLayout.new("VERTICAL");
	
	if carrier == api.type.enum.Carrier.RAIL then 
		fn = evaluation.evaluateNewPassengerTrainTownConnection
		param.maxDist = 16000
	elseif carrier ==  api.type.enum.Carrier.ROAD then 
		fn = evaluation.evaluateNewPassengerRoadTownConnection 
		param.maxDist = math.min(param.maxDist, baseParams.maximumTruckDistance)
	elseif carrier == api.type.enum.Carrier.WATER then
		fn = evaluation.evaluateNewWaterTownConnections
		param.transhipmentRange = 1500
	elseif carrier == api.type.enum.Carrier.AIR then 
		param.minDist = baseParams.minimumAirPassengerDistance
		param.maxDist = 64000
		fn = evaluation.evaluateNewPassengerAirTownConnection
	end	
	local resultFn = function(circle, param)
		local begin = os.clock()
		profiler.beginFunction("refresh town connections for carrier "..tostring(carrier))
		setupCaches()
		local result = fn(circle,param)
		clearCaches()
		trace("Time taken to populate town connections was ",(os.clock()-begin))
		profiler.endFunction("refresh town connections for carrier "..tostring(carrier))
		profiler.printResults()
		return result 
	end
	local topLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL")
	topLayout:addItem(util.createIconBar("ui/button/large/town.tga","ui/icons/game-menu/returnway@2x.tga","ui/button/large/town.tga"))
	
	topLayout:addItem(api.gui.comp.TextView.new(_("Distance filter:")))
	topLayout:addItem(buildDistSlider(param)) 
	if carrier == api.type.enum.Carrier.WATER then 
		 evaluation.createTranshipmentSlider(param, topLayout) 
	end 
	boxLayout:addItem(topLayout)
	
	trace("Added the top layout")
	if optionsComp then 
		trace("About to add options Comp ")
		boxLayout:addItem(optionsComp.comp)
		trace("Added the options  Comp ")
	end
	if carrier == api.type.enum.Carrier.RAIL or carrier == api.type.enum.Carrier.ROAD then
		local icon = carrier == api.type.enum.Carrier.ROAD and "ui/construction/categories/highway@2x.tga" or "ui/icons/construction-menu/category_tracks@2x.tga" 
		local configButton  =util.newButton("Open route planner",icon)
		local buttonLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL")		 
		local window = evaluation.routeBuilderPanel(  carrier == api.type.enum.Carrier.RAIL, optionsComp) 
		trace("Got window")
		configButton:onClick(function() 
	
			window.setActive()
			local mousePos = api.gui.util.getMouseScreenPos()
			window.window:setPosition(mousePos.x,mousePos.y)
			window.window:setVisible(true, true)
		end)
		buttonLayout:addItem(configButton)
		trace("Added config button to boxlayout")
		if carrier == api.type.enum.Carrier.ROAD and util.tracelog then 
			local buildMainConnectionHighways = util.newButton("Build highways along main connections", icon)
			buildMainConnectionHighways:onClick(function() 
				evaluation.addWork(function()  
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildMainConnectionHighways", "", optionsComp.getChoices()), evaluation.standardCallback)
				end)
				evaluation.buildMainConnectionHighwaysCalled = true
				buildMainConnectionHighways:setEnabled(false, false)
			end)
			if evaluation.buildMainConnectionHighwaysCalled == nil then 
				evaluation.buildMainConnectionHighwaysCalled = false 
			end 
			buildMainConnectionHighways:setEnabled(not evaluation.buildMainConnectionHighwaysCalled, false)
			
			buttonLayout:addItem(buildMainConnectionHighways)
			
		 
			local upgradeMainConnections = util.newButton("Upgrade main connections" )
			upgradeMainConnections:onClick(function() 
				evaluation.addWork(function()  
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","upgradeMainConnections", "", optionsComp.getChoices()), evaluation.standardCallback)
				end)
				evaluation.upgradeMainConnections = true
				upgradeMainConnections:setEnabled(false, false)
			end)
			if evaluation.upgradeMainConnections == nil then 
				evaluation.upgradeMainConnections = false 
			end 
			upgradeMainConnections:setEnabled(not evaluation.upgradeMainConnections, false)
			
			buttonLayout:addItem(upgradeMainConnections) 
			
		end 
		boxLayout:addItem(buttonLayout)
	end
	
	--local includeConnected  = api.gui.comp.CheckBox.new(_("Include cities with indirect or other transport mode connections"))
	local begin = os.clock()
	local global = circle.radius == math.huge
	param.includeConnected = global or carrier ~=  api.type.enum.Carrier.RAIL 
	results = {}
	xpcall(function()
		if game.interface.getGameSpeed() ==0 then 
			api.cmd.sendCommand(api.cmd.make.setGameSpeed(1), function(res, success) 
				if success then 
					api.cmd.sendCommand(api.cmd.make.setGameSpeed(0), function(res, success) 
						if success and not global then
							pcall(function() -- un handled error causes a game crash invoked from the callback
								results = resultFn(circle, param )
							end)
						end 
					end)
				end 
			end) 
		elseif not global then
			results = resultFn(circle, param )
		end 
	end,
	function(x) 
		print(x)
		print(debug.traceback())
	end)
	
	local endTime = os.clock()
	trace("Time taken to collect passenger results for carrier ",carrier, " was ", (begin-endTime))

	
  
	local noMatchDisplay = api.gui.comp.TextView.new(_("No matches found"))
	local suppressed = api.gui.comp.TextView.new(_("Press refresh to run scan"))
	noMatchDisplay:setVisible(false, false)
	suppressed:setVisible(global, false)
	boxLayout:addItem(noMatchDisplay)
	boxLayout:addItem(suppressed)
	local colHeaders = {
		api.gui.comp.TextView.new(_("Score")),
		api.gui.comp.TextView.new(_("Town").." 1"),
		api.gui.comp.TextView.new(_("Population")),
		api.gui.comp.TextView.new(_("Town").." 2"),
		api.gui.comp.TextView.new(_("Population")),
		api.gui.comp.TextView.new(_("Distance")), 
		api.gui.comp.TextView.new(_("Build"))
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	displayTable:setHeader(colHeaders)
	--api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(27561)
	trace("Util was ",util)
	local moreButton = util.newButton(_("Show more"), "ui/button/xxsmall/down_thin@2x.tga" )
	local function refresh(results)
		local begin = os.clock()
		
		displayTable:deleteAll()
		suppressed:setVisible(false, false)
		if not results or #results == 0 then 
			moreButton:setVisible(false, false)
			displayTable:setVisible(false, false)
			noMatchDisplay:setVisible(true, false)
			return
		end
		noMatchDisplay:setVisible(false, false)
		moreButton:setVisible(true, false)
		displayTable:setVisible(true, false)
		for i = 1, #results do
			local result = results[i]
			local buildButton = util.newButton("Build", "ui/icons/build-control/accept@2x.tga")
			buildButton:onClick(function()
				--evaluation.recheckResultForStations(result, false, carrier)
				result.transhipmentRange = param.transhipmentRange
				evaluation.addWork(function()
					buildResultFn(util.deepClone(result)) 
				end)
				buildButton:setEnabled(false)
			end)
			if carrier == api.type.enum.Carrier.RAIL then  
				local configButton  =util.newButton("","ui/button/small/line_tasks@2x.tga")
				local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
				boxLayout:addItem(configButton)
				boxLayout:addItem(buildButton)
				buildButton = api.gui.comp.Component.new("")
				buildButton:setLayout(boxLayout)
				local window = evaluation.terminusChooserPanel(result) 
				configButton:onClick(function() 
					window:setVisible(true, false)
					local mousePos = api.gui.util.getMouseScreenPos()
					window:setPosition(mousePos.x,mousePos.y)
				end)
			end 
			trace("Result.score was ", result.score, " displayScore=",result.displayScore)
			displayTable:addRow({
				scoreDisplay(result),
				util.makelocateRow(result.town1),
				api.gui.comp.TextView.new(tostring(math.floor(getResidentialCapacityOfTown(result.town1.id)))),
				util.makelocateRow(result.town2),
				api.gui.comp.TextView.new(tostring(math.floor(getResidentialCapacityOfTown(result.town2.id)))),
				api.gui.comp.TextView.new(api.util.formatLength(result.distance)),  
				buildButton
			})
		end
		local endTime = os.clock()
		trace("Time taken to setup town display was ",(endTime-begin))
	end
	
	if circle.radius ~= math.huge then 
		refresh(results)
	end 
 
 
	boxLayout:addItem(displayTable)
	local bottomLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	local refreshButton = util.newButton("Refresh","ui/button/xxsmall/replace@2x.tga")
	bottomLayout:addItem(refreshButton)
	bottomLayout:addItem(moreButton)
	
	boxLayout:addItem(bottomLayout)
	moreButton:onClick(function()  
		evaluation.addWork(function()
			param.resultsToReturn = param.resultsToReturn *2
			param.includeConnected = circle.radius~=math.huge or carrier ==  api.type.enum.Carrier.ROAD 
			refresh(resultFn(circle, param ))
		end)
	end)
	refreshButton:onClick(function() 
		evaluation.addWork(function()
			param.includeConnected = circle.radius~=math.huge or carrier ==  api.type.enum.Carrier.ROAD 
			refresh(resultFn(circle, param))
		end)
	end)
	local comp= api.gui.comp.Component.new("")
	comp:setLayout(boxLayout)
	local function mapListener(isMap, mapState) 
		comp:setVisible(not isMap, true)
	end
	

	return comp, mapListener

end

local function cargoDisplay(result)
	local cargoType =	api.res.cargoTypeRep.find(result.cargoType)
	local cargoTypeDetail = api.res.cargoTypeRep.get(cargoType)
	local icon = cargoTypeDetail.icon
	local iconView =  api.gui.comp.ImageView.new(icon)
	iconView:setTooltip(_(cargoTypeDetail.name))
	return iconView
end

function evaluation.terminusChooserPanel(result) 
	local boxLayout =  api.gui.layout.BoxLayout.new("VERTICAL"); 
	local window = api.gui.comp.Window.new( _('Options'), boxLayout)
	window:addHideOnCloseHandler()
	window:setVisible(false, false)
	local acceptButton = util.newButton("Accept","ui/button/small/accept@2x.tga")
	local resetButton = util.newButton("Reset","ui/button/xxsmall/replace@2x.tga")
	local cancelButton = util.newButton("Cancel","ui/button/small/cancel@2x.tga")
	
	local function getTowns() 
		return { result.town1, result.town2 } 
	end 
	local checkboxes = {}
	for i, town in pairs(getTowns()) do 
		local desc = town.name.." ".._("Terminus?")
		local checkBox = api.gui.comp.CheckBox.new(desc) 
		checkboxes[town.id]=checkBox
		boxLayout:addItem(checkBox)
	end 
	
	local function reset() 
		for i, town in pairs(getTowns()) do 
			local otherTown = i ==1 and result.town2 or result.town1
			result.buildTerminus[town.id] = evaluation.shouldBuildTerminus(town, otherTown)
			checkboxes[town.id]:setSelected(result.buildTerminus[town.id] and true or false,false)
		end
	end 
	resetButton:onClick(reset)
	
	reset()
	cancelButton:onClick(function() 
		window:close() 
	end)
	acceptButton:onClick(function() 
		for townId, checkBox in pairs(checkboxes) do 
			result.buildTerminus[townId]=checkBox:isSelected()
 		end 
		window:close()
	end)
	local bottomLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	bottomLayout:addItem(acceptButton)
	bottomLayout:addItem(resetButton)
	bottomLayout:addItem(cancelButton)
	boxLayout:addItem(bottomLayout)
	
	return window
end 

function evaluation.createTranshipmentSlider(param, topLayout) 
	topLayout:addItem(api.gui.comp.TextView.new(_("Max transhipment range:")))
	local valueDisplay = api.gui.comp.TextView.new(" ")
	local slider = api.gui.comp.Slider.new(true) 
	slider:setMinimum(1)
	slider:setMaximum(10)
	slider:setStep(1)
	slider:setPageStep(1)
	local size = slider:calcMinimumSize()
	size.w = size.w+120
	slider:setMinimumSize(size)
	
	slider:onValueChanged(function(x) 
		local dist =  x*500
		param.transhipmentRange = dist
		valueDisplay:setText(api.util.formatLength(dist))
	end)
	slider:setValue(param.transhipmentRange/500, true)
	topLayout:addItem(slider)
	topLayout:addItem(valueDisplay)
end

function evaluation.buildIndustryChoicesPanel(circle, carrier, buildResultFn, optionsComp)
	local results = {} 
	local param = {}
	param.resultsToReturn = 5
	
	local baseParams = paramHelper.getParams()
	param.minDist = 0
	param.maxDist = 64000
	 
	local boxLayout =  api.gui.layout.BoxLayout.new("VERTICAL"); 
	local fn 
	if carrier == api.type.enum.Carrier.RAIL then 
		fn = evaluation.evaluateNewIndustryConnectionForTrains 
		--param.minDist = baseParams.minimumCargoTrainDistance
	--	param.maxDist = math.max(16000, baseParams.maximumTruckDistance)
	elseif carrier ==  api.type.enum.Carrier.ROAD then 
		fn = evaluation.evaluateNewIndustryConnectionWithRoads 
		--param.maxDist = baseParams.maximumTruckDistance
	elseif carrier == api.type.enum.Carrier.WATER then
		fn = evaluation.evaluateNewWaterIndustryConnections
		param.transhipmentRange = 1500
	elseif carrier == api.type.enum.Carrier.AIR then
		--param.minDist = baseParams.minimumAirPassengerDistance
		--param.maxDist = 64000
		param.transhipmentRange = 4000
		fn = evaluation.evaluateNewAirIndustryConnections
	end 
	local function resultFn(circle, param) 
		local begin = os.clock()
		profiler.beginFunction("refresh connections for carrier "..tostring(carrier))
		setupCaches()
		local result = fn(circle, param)
		clearCaches()
		trace("Time taken to populate industry results was",(os.clock()-begin), " raw result:",result)
		profiler.endFunction("refresh connections for carrier "..tostring(carrier))
		profiler.printResults()
		return result
	end
	
	--debugPrint({paramBefore=param})
	local topLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL")
	topLayout:addItem(util.createIconBar("ui/button/medium/industries@2x.tga","ui/design/window-content/arrow_style1_20px_right@2x.tga","ui/button/medium/industries@2x.tga"))
	
	topLayout:addItem(api.gui.comp.TextView.new(_("Distance filter:")))
	topLayout:addItem(buildDistSlider(param))
	if carrier == api.type.enum.Carrier.AIR or carrier == api.type.enum.Carrier.WATER then 
		 evaluation.createTranshipmentSlider(param, topLayout) 
	end 
	boxLayout:addItem(topLayout)
	trace("Added the topLayout, about to check the optionsComp")
	if optionsComp then 
		trace("Adding optionsComp")
		boxLayout:addItem(optionsComp)
		trace("OptionsComp added")
	end
	local global = circle.radius == math.huge
	--debugPrint({paramAfter=param})
	local begin = os.clock()
	xpcall(function()
		if not global then 
			results = resultFn(circle, param )
		end
	end,
	function(x) 
		print(x)
		print(debug.traceback())
	end)
	local endTime = os.clock()
	trace("Time taken to collect industry results for carrier ",carrier, " was ", (endTime-begin))
 
	local colHeaders = {
		api.gui.comp.TextView.new(_("Score")),
		api.gui.comp.TextView.new(_("Source")),
		api.gui.comp.TextView.new(_("Destination")),
		api.gui.comp.TextView.new(_("Cargo")),
		api.gui.comp.TextView.new(_("Initial rate")),
		api.gui.comp.TextView.new(_("Distance")),
		api.gui.comp.TextView.new(_("Build"))
	
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local moreButton = util.newButton(_("Show more"), "ui/button/xxsmall/down_thin@2x.tga" ) --"ui/button/xsmall/down@2x.tga"
	local noMatchDisplay = api.gui.comp.TextView.new(_("No matches found"))
	noMatchDisplay:setVisible(false, false)
	boxLayout:addItem(noMatchDisplay)
	local pressRefresh = _("Press refresh to run scan")
	local suppressed = api.gui.comp.TextView.new(pressRefresh)
	boxLayout:addItem(suppressed)
	suppressed:setVisible(global, false)
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	displayTable:setHeader(colHeaders)
 	local lastSelectedEntity
	local function refresh(results)
		local begin = os.clock()
		suppressed:setVisible(false, false)
		displayTable:deleteAll()
		if not results or #results == 0 then 
			moreButton:setVisible(false, false)
			displayTable:setVisible(false, false)
			noMatchDisplay:setVisible(true, false)
			return
		end
		noMatchDisplay:setVisible(false, false)
		moreButton:setVisible(true, false)
		displayTable:setVisible(true, false)
		for i = 1, #results do
			local result = results[i]
			local buildButton = util.newButton("Build", "ui/icons/build-control/accept@2x.tga")
			buildButton:onClick(function()
				--evaluation.recheckResultForStations(result, true, carrier)
				evaluation.addWork(function() 
					buildResultFn(util.deepClone(result)) 
					lastSelectedEntity = nil
				end)
				buildButton:setEnabled(false)
			end)
			
			
			trace("Result.score was ", result.score, " displayScore=",result.displayScore)
			displayTable:addRow({
				scoreDisplay(result),
				util.makelocateRow(result.industry1),
				util.makelocateRow(result.industry2),
				cargoDisplay(result),
				api.gui.comp.TextView.new(tostring(result.initialTargetLineRate)),
				api.gui.comp.TextView.new(api.util.formatLength(result.distance)),
				buildButton
			})
		end
		 
		local endTime = os.clock()
		trace("Time taken to setup town display was ",(endTime-begin))
	end
	if not global then 
		refresh(results)
	end
	
	 
	boxLayout:addItem(displayTable)
	local bottomLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	local refreshButton = util.newButton(_("Refresh"),"ui/button/xxsmall/replace@2x.tga")
	bottomLayout:addItem(refreshButton)
	bottomLayout:addItem(moreButton)
	local hideInactiveChbox = api.gui.comp.CheckBox.new(_("Hide industries already shipping or with no production"))
	bottomLayout:addItem(hideInactiveChbox)
	hideInactiveChbox:setVisible(false, false)
	boxLayout:addItem(bottomLayout)
	moreButton:onClick(function()  
		evaluation.addWork(function() 
			param.resultsToReturn = param.resultsToReturn*2
			refresh(resultFn(circle, param))
		end)
	end)
	local refreshButtonFunction = function() 
		refresh(resultFn(circle, param))
	end 
	
	refreshButton:onClick(function()
		evaluation.addWork(refreshButtonFunction)
	end)
	hideInactiveChbox:onToggle(function(b) 
		evaluation.addWork(refreshButtonFunction)
	end)

	local mapResults
	local function mapListener(isMap, mapState) 
		moreButton:setVisible(not isMap, true)
		hideInactiveChbox:setVisible(isMap or false, true)
		if isMap then 
			local function hideInactiveEntities()
				local circle = util.hugeCircle()
				local thisParam = util.deepClone(param)
				thisParam.resultsToReturn = math.huge
				local results  = resultFn(circle, thisParam ) or {}
				local allowedEntities = {} 
				for i , result in pairs(results) do 
					for j, id in pairs({result.industry1.id, result.industry2.id}) do 
						if not allowedEntities[id] then 
							allowedEntities[id] = true 
						end 
					end
				end 
				mapState.allowedEntities = allowedEntities
				mapState.toggleAllVisibility()
			end
			suppressed:setText("Select industry in the map")
			mapState.entitySelectedListener=function(entity)
				if entity == lastSelectedEntity then 	
					return 
				end
				evaluation.addWork(function()
				
					if not lastSelectedEntity then 
						local circle = { pos = util.getEntity(entity).position, radius = 100} 
						mapResults  = resultFn(circle, param )
						if not mapResults then 
							trace("WARNING!, no results were found") 
							suppressed:setText(_("No matching industry or town was found"))
							return
						end
						mapState.clearLines()
						local allowedEntities = {} 
						for i , result in pairs(mapResults) do 
							for j, id in pairs({result.industry1.id, result.industry2.id}) do 
								if not allowedEntities[id] then 
									allowedEntities[id] = true 
								end 
							end
						end 
						mapState.allowedEntities = allowedEntities
						mapState.toggleAllVisibility()
						refresh(mapResults)
						lastSelectedEntity = entity
					else 
						local allowedEntities = { [lastSelectedEntity]=true, [entity]=true }
						local found = false
						for i, result in pairs(mapResults) do 
							if allowedEntities[result.industry1.id] and allowedEntities[result.industry2.id] then 
								refresh({result})
								mapState.clearLines()
								mapState.addLine(lastSelectedEntity, entity)
								mapState.allowedEntities = nil 
								mapState.toggleAllVisibility()
								lastSelectedEntity = nil
								mapResults = nil
								if hideInactiveChbox:isSelected() then 
									hideInactiveEntities()
								end 
								found = true 
								break
							end 
						end 
						assert(found)
					end 		
				end)
			end
			refreshButtonFunction = function() 
				refresh({ })
				mapState.clearLines() 
				mapState.allowedEntities = nil 
				mapState.toggleAllVisibility()
				lastSelectedEntity = nil
				mapResults = nil
				evaluation.addWork(mapState.refreshEdgesAndStations)
				if hideInactiveChbox:isSelected() then 
					hideInactiveEntities()
				end 
			end 
		else 
			refreshButtonFunction = function() 
				refresh(resultFn(circle, param))
			end 
			suppressed:setText(pressRefresh)
		end		
	end
	
	local comp= api.gui.comp.Component.new("")
	comp:setLayout(boxLayout)
	return comp, mapListener
end
function evaluation.routeBuilderPanel(isTrack, optionsComp) 
	trace("Setting up routeBuilderPanel")
	local outerLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local mapLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	
	local boxLayout =  api.gui.layout.BoxLayout.new("VERTICAL"); 
	outerLayout:addItem(mapLayout)
	--minimap.refreshMap(mapLayout)
	outerLayout:addItem(boxLayout)
	local buttonGroup, standard, elevated, underground = util.createElevationButtonGroup(true) 
	local topLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local isCargo = false 
	local routeScoringChooser = paramHelper.buildRouteScoringChooser(true, isCargo)
	topLayout:addItem(routeScoringChooser.button)
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, isCargo)
	topLayout:addItem(paramOverridesChooser.button)
	topLayout:addItem(api.gui.comp.Component.new("VerticalLine"))
	topLayout:addItem(api.gui.comp.TextView.new(_("Elevation:")))
	topLayout:addItem(buttonGroup)
	
	boxLayout:addItem(topLayout)
	local window = api.gui.comp.Window.new( _('Route Planner'), outerLayout)

	window:addHideOnCloseHandler()
	window:setVisible(false, false)
	local circularLine =  api.gui.comp.CheckBox.new(_("Circular line?"))
	local towns = {}
	local townPops = {}
	local expressChkboxes = {}
	local expressLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL"); 
	local targetIntervalDisp = api.gui.comp.TextView.new(_("Target interval"))
	local valueDisplay = api.gui.comp.TextView.new("3")
	local slider = api.gui.comp.Slider.new(true) 
	slider:setMinimum(2)
	slider:setMaximum(12)
	slider:setStep(1)
	slider:setPageStep(1)
	slider:setValue(3, false)
	local size = slider:calcMinimumSize()
	size.w = size.w+120
	slider:setMinimumSize(size)
	local disableExpressRecalc = false 
	local function recalculateExpressStops() 
		if disableExpressRecalc then 
			trace("Suppressing recalculateExpressStops")
			return
		end 
		local targetInterval = slider:getValue()
		local isCircularRoute = circularLine:isSelected()
		local shouldSelectSet ={} 
		for j = 1, #towns do 
			local options = {}
			local startFrom = isCircularRoute and 1 or 2 
			local endAt = isCircularRoute and #towns or #towns-1
			debugPrint({shouldSelectSet=shouldSelectSet})
			local function getDistanceOfLastExpressStop(i) 
				local count = 0 
				local endAt = isCircularRoute and i-#towns+1 or 1
				for k = i-1, endAt, -1 do
					count = count + 1
					local m = k < 1 and #towns+k or k
					trace("Checking distance of prior express stop for i=",i," k=",k,"m=",m,"shouldSelectSet[m]?",shouldSelectSet[m],"count=",count)
					if shouldSelectSet[m] then
						return count 
					end 
				end 
				return count
			end 
			local function getDistanceOfNextExpressStop(i) 
				local count = 0 
				local endAt = isCircularRoute and i+#towns-1 or #towns
				for k = i+1, endAt do
					count = count + 1
					local m = k > #towns and k-#towns or k
					trace("Checking distance of next express stop for i=",i," k=",k,"m=",m,"shouldSelectSet[m]?",shouldSelectSet[m],"count=",count)
					if shouldSelectSet[m] then
						return count 
					end 
				end 
				return count
			end			
			for i = startFrom, endAt do 
				local townPop = townPops[i]
				local priorStopGap 
				local nextStopGap 
				if j == 1 then 
					priorStopGap = i == #towns and townPops[1] or townPops[i+1]
					nextStopGap = i == 1 and townPops[#towns] or townPops[i-1]
				else 
					priorStopGap = math.abs((targetInterval-1)-getDistanceOfLastExpressStop(i))
					nextStopGap = math.abs((targetInterval-1)-getDistanceOfNextExpressStop(i))
				end 
				table.insert(options, {
					idx=i ,
					scores = {
						-townPop,
						priorStopGap, 
						nextStopGap,
					}
				})
			end 
			if util.tracelog then 
				debugPrint({j=j, options=options, shouldSelectSet=shouldSelectSet})
			end 
			shouldSelectSet ={} 
			
			local target = math.ceil(#towns / targetInterval)
			local weights = { 100, 100, 100 }
			local sortedOptions = util.evaluateAndSortFromScores(options, weights)
			for i, option in pairs(sortedOptions) do 
				shouldSelectSet[option.idx] = true 
				if i == target then 
					break 
				end
			end 		
			if util.tracelog then 
				debugPrint({j=j, sortedOptions=sortedOptions, shouldSelectSet=shouldSelectSet})
			end 
		end
		
		for i = 1, #expressChkboxes do 
			local isEnabled = i > 1 and i < #expressChkboxes or isCircularRoute 
			local shouldSelect =   not isEnabled
			local halfway = math.floor(#expressChkboxes/2)
			if not shouldSelect then 
				 --shouldSelect =i % targetInterval == #towns % targetInterval
				shouldSelect = math.abs(i-halfway) % targetInterval == 0
				if #expressChkboxes == 5 then 
					shouldSelect = i == 3
				end 
				shouldSelect = shouldSelectSet[i] or false 
				--if type(shouldSelect) == "table" then 
				--	debugPrint({shouldSelect=shouldSelect, shouldSelectSet=shouldSelectSet})
			--	end 
			end
			expressChkboxes[i]:setSelected(shouldSelect, false)
			expressChkboxes[i]:setEnabled(isEnabled, false)
		end 
					
	end
	
	slider:onValueChanged(function(x) 
		 evaluation.addWork(function() 
			valueDisplay:setText(tostring(x))
			recalculateExpressStops() 
		 end)
	end)
	local includeExpressChkbx =  api.gui.comp.CheckBox.new(_("Include express line?"))
	includeExpressChkbx:onToggle(function(b) 
		evaluation.addWork(function() 
			slider:setVisible(b, false)
			valueDisplay:setVisible(b, false)
			targetIntervalDisp:setVisible(b, false)
			for i, chkbx in pairs(expressChkboxes) do 
				chkbx:setVisible(b, false)
			end 
		end)
	
	end)
	includeExpressChkbx:setSelected(isTrack, true)
	expressLayout:addItem(includeExpressChkbx)
	expressLayout:addItem(targetIntervalDisp)
	expressLayout:addItem(slider)
	expressLayout:addItem(valueDisplay)
	if isTrack then 
		boxLayout:addItem(expressLayout)
	end

	boxLayout:addItem(circularLine)

	boxLayout:addItem(api.gui.comp.TextView.new(_("Click on a town to add")))
	
	
	
	local townIds = {}
	
	local colHeaders = {
		api.gui.comp.TextView.new(_("Town")),
		api.gui.comp.TextView.new(_("Population")),
		api.gui.comp.TextView.new(_("Distance")),
		api.gui.comp.TextView.new(_("Options")),
		api.gui.comp.TextView.new(" "),
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	trace("Set up displayTable")
	boxLayout:addItem(displayTable)
	local acceptButton = util.newButton("Accept","ui/button/small/accept@2x.tga")
	local resetButton = util.newButton("Reset","ui/button/xxsmall/replace@2x.tga")
	local cancelButton = util.newButton("Cancel","ui/button/small/cancel@2x.tga")
	
	local suggestButton = util.newButton("Suggest?")
	local mainConnectionsToggle = api.gui.comp.CheckBox.new(_("Display main connections"))

	local mapState = util.deepClone(minimap.guiState)
	local function reset() 
		displayTable:deleteAll()
		towns = {}
		townIds = {} 
		townPops = {}
		expressChkboxes = {}
		mapState.clearLines()
		disableExpressRecalc = false 
	end 
	resetButton:onClick(reset)
	
	--reset()
	cancelButton:onClick(function() 
		window:close() 
	end)
	acceptButton:onClick(function() 
		evaluation.addWork(function() 
			for i = 1, #towns do 
				towns[i].isExpressStop = expressChkboxes[i]:isSelected()
			end 
			
			local paramOverrides = paramOverridesChooser.customOptions
			if not paramOverrides then 
				paramOverrides = {}
			end
			for k , v in pairs(optionsComp.getChoices()) do 
				paramOverrides[k]=v
			end 
			paramOverrides.isElevated = elevated:isSelected()
			paramOverrides.isUnderground = underground:isSelected()
			paramOverrides.routeScoreWeights = routeScoringChooser.customRouteScoring
	
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildCompleteRoute", "", 
				{
					towns=towns,
					isCircularRoute = circularLine:isSelected(),
					isExpress = includeExpressChkbx:isSelected(),
					paramOverrides = paramOverrides,
					isTrack = isTrack,
				}), 
				evaluation.standardCallback)
			evaluation.addWork(reset) 
		end)			
		window:close()
	end)
	local bottomLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	bottomLayout:addItem(acceptButton)
	bottomLayout:addItem(resetButton)
	bottomLayout:addItem(cancelButton)
	bottomLayout:addItem(suggestButton)
	bottomLayout:addItem(mainConnectionsToggle)
	boxLayout:addItem(bottomLayout)
	--local function guiEventListener(id, name, param)
		--trace("Got gui event",id,name,param, " param type was",type(param))
	--	if id == "mainView" and name == "select" and type(param) == "number" and not townIds[param] then 
		
	--			local entity =  util.getEntity(param)
	
	mapState.displayIndustries = not isTrack
	local function drawLines() 
		mapState.clearLines()
		if mainConnectionsToggle:isSelected() then 
			api.engine.forEachEntityWithComponent(function(entity) 
				local comp = util.getComponent(entity, api.type.ComponentType.TOWN_CONNECTION)
				mapState.addLine(comp.entity0, comp.entity1)
			end, api.type.ComponentType.TOWN_CONNECTION)
		end 
		if #towns >= 2 then 
			local startAt = circularLine:isSelected() and 1 or 2 
			
			for i = startAt, #towns do 
				local priorTown = i == 1 and towns[#towns] or towns[i-1]
				local town = towns[i]
				mapState.addLine(priorTown.id, town.id)
			end 
			
		end 
	end 
	circularLine:onToggle(function() 
		evaluation.addWork(recalculateExpressStops) 
		evaluation.addWork(drawLines)
	end)
	mainConnectionsToggle:onToggle(function() 
		evaluation.addWork(drawLines)
	end)
	
	local function addTownToSelection(entity)
		trace("Entity was a town adding")
		townIds[entity.id]=true
		entity = util.deepClone(entity)
		table.insert(towns, entity)
		local index = #towns
		local isExpressStop =  api.gui.comp.CheckBox.new(_("Express Stop?"))
		
		table.insert(expressChkboxes, isExpressStop)
		local isExpress = entity.isExpressStop or false 
		isExpressStop:setVisible(includeExpressChkbx:isSelected(), false)
		if includeExpressChkbx:isSelected() then 
			isExpressStop:setSelected(isExpress, false)
		end 
		local distanceDisplay = api.gui.comp.TextView.new(" ")
		if #towns > 1 then 
			local priorTown = towns[#towns-1]
			distanceDisplay:setText(api.util.formatLength(util.distance(util.v3fromArr(entity.position),util.v3fromArr(priorTown.position))))
		end 
		local optionsLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
		optionsLayout:addItem(isExpressStop)
		local comp = api.gui.comp.Component.new(" ")
		comp:setLayout(optionsLayout)
		local cancelButton = util.newButton("","ui/button/small/cancel@2x.tga")
		cancelButton:onClick(function() 
			evaluation.addWork(function() 
				local index = util.indexOf(towns, entity)
				displayTable:deleteRows(index-1, index)
				table.remove(towns, index)
				townIds[entity.id]=nil
				table.remove(expressChkboxes, index)
				table.remove(townPops, index)
				recalculateExpressStops()
				drawLines()
			end)
		end)
		local townPop = 0 
		if entity.type == "TOWN" then 
			townPop = game.interface.getTownCapacities(entity.id)[1]
		end
		table.insert(townPops, townPop)
		recalculateExpressStops()
		drawLines()
		displayTable:addRow({
			util.makelocateRow(entity),
			api.gui.comp.TextView.new(api.util.formatNumber(townPop)),
			distanceDisplay,
			comp,
			cancelButton
		})
	end
	
	local function entitySelectedListener(entity)	
		trace("Checking entity",entity)
			if entity and type(entity) == "number" then 
				entity = util.getEntity(entity)
			end
			if entity and (entity.type == "TOWN" or not isTrack and entity.type=="SIM_BUILDING") and not townIds[entity.id] then 

				
				evaluation.addWork(function()
					addTownToSelection(entity)
				end)
		--	end 
		end 
	end
	local suggestCount = 1
	local maxSuggestableRoutes = 3
	suggestButton:onClick(function() 
		evaluation.addWork(function() 
			local result = setupCompleteRoute(not isTrack, suggestCount)
			local attemptCount = 1 
			while not result and attemptCount <= maxSuggestableRoutes do 
				result = setupCompleteRoute(not isTrack, suggestCount)
				attemptCount = attemptCount + 1 
				suggestCount = suggestCount + 1 
				if suggestCount > maxSuggestableRoutes then 
					suggestCount = 1 
				end 
				
			end 
			if result then 
				reset() 
				circularLine:setSelected(result.isCircularRoute, true)
				includeExpressChkbx:setSelected(result.isExpress, true)
				disableExpressRecalc = true 
				for i, town in pairs(result.towns) do 
					addTownToSelection(town)
				end
				--disableExpressRecalc = false 
			end 
			local textField = suggestButton:getLayout():getItem(0)
			textField:setText(_("Suggest").." ("..tostring(suggestCount)..")")
			suggestCount = suggestCount + 1 
			if suggestCount > 3 then 
				suggestCount = 1
			end 
		--	local textField = suggestButton:getLayout():removeItem(1)
			
		--	suggestButton:getLayout():insertItem(  textField,1)
		end)
	end)
	
	trace("About to add close listener")
	--[[ 
	window:onVisibilityChange(function(b) 
		trace("Got on visibility change",b)
		if b then 
			evaluation.setGuiEventListener(guiEventListener)
		else 
			evaluation.setGuiEventListener(nil)
		end
	end)]]--
	window:setPosition(0,0)
	mapState.entitySelectedListener = entitySelectedListener
	minimap.setVisibilityListener(window, mapLayout, mapState)
	
	return {
		window = window, 
		setActive = function() 
			if isTrack then 
				mapState.filter.industry = true 
			else 
				mapState.filter.industry = false  
			end 
			--mapState.toggleAllVisibility()
			--evaluation.setGuiEventListener(guiEventListener)
		end 
	}
end
return evaluation