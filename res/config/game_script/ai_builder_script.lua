local gui = require("gui")
local vec2 = require("vec2")
local vec3 = require("vec3")
local transf  = require("transf")
local helper = require("ai_builder_station_template_helper")
local util = require("ai_builder_base_util")
local connectEval = require("ai_builder_new_connections_evaluation")
local profiler = require("ai_builder_profiler")

local paramHelper = require("ai_builder_base_param_helper")
local routeEvaluation = require("ai_builder_route_evaluation")
local lineManager = require("ai_builder_line_manager")
local routeBuilder = require("ai_builder_route_builder")
local constructionUtil = require("ai_builder_construction_util")
local vehicleUtil = require("ai_builder_vehicle_util")
local townPanel = require("ai_builder_town_panel")
local upgradesPanel = require("ai_builder_upgrades_panel")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local straightenPanel = require("ai_builder_straighten_panel")
local minimap = require("ai_builder_minimap")
local waterMeshUtil = require "ai_builder_water_mesh_util"
local proposalUtil = require "ai_builder_proposal_util"
local socket_manager = require "socket_manager"
local function tryLoadUndo() 

	local res 
	pcall(function() res = require "undo_base_util" end)
	return res 
end 
local undo_script = tryLoadUndo()

-- ============== AI BRIDGE (daemon communication) ==============
local bridge_lastPoll = 0
local BRIDGE_POLL_INTERVAL = 0.5

local function bridge_log(msg)
    local f = io.open("/tmp/ai_bridge_debug.log", "a")
    if f then f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n") f:close() end
end

local function bridge_sendCommand(cmd)
    if cmd == "POLL" then
        local command = socket_manager.poll()
        if command then
            return '{"status": "ok", "command": "' .. command:gsub('"', '\\"'):gsub('\n', '\\n') .. '"}'
        else
            return '{"status": "ok", "command": null}'
        end
    elseif cmd:sub(1, 7) == "RESULT:" then
        local result_json = cmd:sub(8)
        local success = socket_manager.send_result(result_json) 
        return success and '{"status": "ok"}' or nil
    end
    return nil
end


local function bridge_toJson(o)
    if type(o) == 'table' then
        local s, first = '{', true
        local isArr = (#o > 0)
        if isArr then s = '[' end
        for k,v in pairs(o) do
            if not first then s = s .. ',' end
            if isArr then s = s .. bridge_toJson(v)
            else s = s .. '"' .. tostring(k) .. '":' .. bridge_toJson(v) end
            first = false
        end
        return s .. (isArr and ']' or '}')
    elseif type(o) == 'string' then
        return '"' .. o:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"'
    elseif type(o) == 'boolean' or type(o) == 'number' then
        return tostring(o)
    else
        return 'null'
    end
end

local function bridge_evalCode(code)
    local env = setmetatable({api = api, game = game, require = require, print = print}, {__index = _G})
    local func, err = load(code, "eval", "t", env)
    if not func then return {status = "error", message = "Compile: " .. tostring(err)} end
    local ok, result = pcall(func)
    if ok then return {status = "ok", data = result}
    else return {status = "error", message = "Runtime: " .. tostring(result)} end
end

local bridge_initialized = false
local function bridge_poll()
    if not bridge_initialized then
        bridge_log("=== BRIDGE POLL INITIALIZED ===")
        bridge_initialized = true
    end

    local now = os.clock()
    if now - bridge_lastPoll < BRIDGE_POLL_INTERVAL then return end
    bridge_lastPoll = now

    bridge_log("Polling daemon...")
    local response = bridge_sendCommand("POLL")
    if not response then
        bridge_log("No response from daemon")
        return
    end
    bridge_log("Got response: " .. response:sub(1, 80))

    -- Extract JSON string value handling escaped quotes
    local function extractJsonString(json, key)
        local pattern = '"' .. key .. '"%s*:%s*"'
        local start = json:find(pattern)
        if not start then return nil end
        local valueStart = json:find('"', start + #key + 3) + 1
        local i = valueStart
        while i <= #json do
            local c = json:sub(i, i)
            if c == '\\' then
                i = i + 2  -- Skip escaped char
            elseif c == '"' then
                return json:sub(valueStart, i - 1)
            else
                i = i + 1
            end
        end
        return nil
    end

    local command = extractJsonString(response, "command")
    if command then
        command = command:gsub('\\n', '\n'):gsub('\\"', '"'):gsub('\\\\', '\\')
        bridge_log("Executing: " .. command:sub(1, 50) .. "...")
        local result = bridge_evalCode(command)
        bridge_log("Result: " .. bridge_toJson(result):sub(1, 100))
        bridge_sendCommand("RESULT:" .. bridge_toJson(result))
    else
        bridge_log("No command in response")
    end
end
-- ============== END AI BRIDGE ==============

local pos = nil
local steps = 0
local start = os.clock()
local lastUpdate = start
local workTimeout = 60
local workSubmit
local lastUpdateGameTime
local lastCheckedLines = 0
local lastStatusUpdate
local minimumTickInterval = 30 -- 60
local gameTicks = 0
local gui = require "gui"
local zoneutil = require "mission.zone"
local tracelog = true
local isdebuglog = true
local isAdvancedMode = true
local isShowGuiEvents = false
local isAutoAiEnabled = false
local isTurboChargeMode = false
local targetGameSpeed
local isShowEvents = false
local isGuiInitThread = false 
local isEngineThread = false 
local isGuiThread = false
local isForceImmediateDepartures = false
local activityLog = {}
local aiEnableOptions = {
	autoEnablePassengerTrains = false,
	autoEnableFreightTrains = false, 
	autoEnableTruckFreight = false,
	autoEnableIntercityBus = false,
	autoEnableShipFreight = false,
	autoEnableShipPassengers = false ,
	autoEnableAirPassengers = false,
	autoEnableLineManager = false,
	autoEnableHighwayBuilder = false,
	autoEnableAirFreight = false,
	pauseOnError = false,
	autoEnableFullManagement = false,
	autoEnableExpandingBusCoverage = false,
	autoEnableExpandingCargoCoverage = false,
}

local guiState = {}

local function countAutoEnabled() 
	local count = 0
	for k, v in pairs(aiEnableOptions) do 
		if v then 
			count = count + 1
		end
	end 
	return count 
end
local function oneAiOptionActive() 
 
	return countAutoEnabled()  == 1
end 
local hermiteSmooth = true
local trackWidth = 5
local trace = util.trace 
local initContext = util.initContext
local errorPanel
local clearErrorButton
local statusPanel
local statusPanel2
local statusPanel3
local commandSentTime
local currentBuildParams 
local errorMessage
local errorPayload
local guiEventListener 
local function setGuiEventListener(_guiEventListener)
	guiEventListener = _guiEventListener
	trace("Set guiEventListener to ",_guiEventListener)
end
local function text(str) 
	return api.gui.comp.TextView.new(_(tostring(str)))
end
local function err(x)
	print("An error was caught",x)
	local traceback = debug.traceback()	
	print(traceback)
	--errorMessage = _('An error occurred, see logs')
	errorMessage = 'An error occurred, see logs'
	local baseError = ""
	if currentBuildParams and currentBuildParams.status then 
		baseError = "An error occurred while executing: "..currentBuildParams.status.."\n" 
		currentBuildParams.status2 = _("Failed")
		if not pcall(function() 
			if currentBuildParams.carrier then 
				connectEval.markConnectionAsFailed(currentBuildParams.carrier, currentBuildParams.location1, currentBuildParams.location2)
			end 
		end) then 
			trace("WARNING! Unable to mark connection as failed")
		end 
	end 
	
	errorPayload = baseError..x..traceback
	--currentBuildParams = nil
	util.clearCacheNode2SegMaps() 
	if errorPanel then 
		errorPanel:setText(errorMessage) 
		clearErrorButton:setVisible(true,false)
	end 
	if util.tracelog and aiEnableOptions.pauseOnError then 
		pcall(function() game.interface.setGameSpeed(0) end)
	end
end
util.err = err
local function debuglog(...) 
	if isdebuglog then 
		print(...)
	end
end
local function year() 
	return game.interface.getGameTime().date.year
end
local function v3abs(v)
	return math.abs(v.x)+math.abs(v.y)+math.abs(v.z)
end
local circle = {
 radius = math.huge,
 pos = {0,0}
}

local function markComplete() 
	xpcall(function()
		if currentBuildParams then 
			currentBuildParams.status2 = _("Completed")
			if not currentBuildParams.isCompleteRoute then 
				if currentBuildParams.location1 and not connectEval.checkIfCompleted(currentBuildParams.carrier, currentBuildParams.location1, currentBuildParams.location2) then
					table.insert(activityLog, {
						activityType = "New Connection",
						location1 = currentBuildParams.location1 ,
						location2 = currentBuildParams.location2 , 
						carrier = currentBuildParams.carrier
					})
					connectEval.markConnectionAsComplete(currentBuildParams.carrier, currentBuildParams.location1, currentBuildParams.location2)
				end
			end
		end
	end, err)
end  
local function markFailed() 
	trace("A build failed")
	trace(debug.traceback())
	if currentBuildParams then 
		currentBuildParams.status2 = _("Failed")
		connectEval.markConnectionAsComplete(currentBuildParams.carrier, currentBuildParams.location1, currentBuildParams.location2)
	end
end 

local needsupdate = false -- for performance 
local hascircle = false
local workComplete = true
local workItems = {}
local workItems2 ={}

local backgroundWorkItems = {}


local function getBackgoundWorkQueue() 
	return #backgroundWorkItems
end 
lineManager.getBackgoundWorkQueue = getBackgoundWorkQueue
connectEval.getBackgoundWorkQueue = getBackgoundWorkQueue
local relativeScoreWeighting = 10

local function addWork(work)
	table.insert(workItems, work)
end
local function addWorkWhenAllIsFinished(work) 
	table.insert(workItems2, work) 
end 
local function addBackgroundWork(work) 
	table.insert(backgroundWorkItems, work)
end 

local function addDelayedWork(work)
	table.insert(workItems,1, work)
end

local function executeImmediateWork(work) 
	xpcall(work, err)
end 

local function addPause() 
	addWork(function() end)
end

local function standardCallback(res, success) 
	util.clearCacheNode2SegMaps() 
	if not success then 
		trace("command was completed, success= ",success)
		if res and res.resultProposalData then
			debugPrint(res.resultProposalData.errorState)
			debugPrint(res.resultProposalData.collisionInfo)
		else 
			debugPrint(res)
		end
	elseif isEngineThread then 
		addWork(lineManager.checkNoPathVehicles)
	end 
	
end
lineManager.standardCallback = standardCallback
constructionUtil.standardCallback = standardCallback
routeBuilder.standardCallback = standardCallback
lineManager.addWork = addWork
lineManager.addDelayedWork = addDelayedWork
lineManager.addBackgroundWork = addBackgroundWork
lineManager.executeImmediateWork = executeImmediateWork
function lineManager.getActivityLog()
	return activityLog
end 
proposalUtil.addWork = addWork
proposalUtil.addDelayedWork=addDelayedWork
proposalUtil.err = err
proposalUtil.executeImmediateWork = executeImmediateWork
constructionUtil.addWork = addWork
constructionUtil.addDelayedWork=addDelayedWork
constructionUtil.err = err
constructionUtil.executeImmediateWork = executeImmediateWork
constructionUtil.addWorkWhenAllIsFinished = addWorkWhenAllIsFinished
routeBuilder.addWork = addWork
routeBuilder.addDelayedWork = addDelayedWork
routeBuilder.lineManager = lineManager
routeBuilder.constructionUtil=constructionUtil
routeBuilder.executeImmediateWork = executeImmediateWork
routeBuilder.err = err 
vehicleUtil.addWork = addWork
connectEval.addWork = addWork
connectEval.setGuiEventListener = setGuiEventListener
townPanel.addWork = addWork
townPanel.addDelayedWork = addDelayedWork
upgradesPanel.addWork = addWork
upgradesPanel.addDelayedWork = addDelayedWork
upgradesPanel.standardCallback = standardCallback
connectEval.lineManager = lineManager
minimap.addWork = addWork

local changeDirectionInterval = 3
local targetSegmentLength = 90
local maxGradient = 5
local cleanupStreetGraph = true
local checkTerrainAlignment = false
local gatherBuildings = true
local ignoreErrors = false 
local nextBusLine = 1
local userSelectedListener

local tryToCorrectTangents=false
local useHermiteSolution = false
local preSmoothDirectionChanges = false
local preSmoothFull = true
local preCorrectTangents = true
local gameState = {
	industriesWithStations = {}
 }



local function th(p, useCurrentHeight) 
	return useCurrentHeight and api.engine.terrain.getHeightAt(api.type.Vec2f.new(p.x,p.y)) or
	api.engine.terrain.getBaseHeightAt(api.type.Vec2f.new(p.x,p.y))
end


local function subArr(arr, from, to) 
	local result = {}
	for i = from ,to  do
		table.insert(result, arr[i])
	end
	return result
end


local function xyGrad(p1, p2)
	local diff = p2 - p1
	return diff.y / diff.x
end

local function nilSafeItr(tab)
	return tab and tab or {}
end

local function indexOf(tab, v)
	for i,v2 in pairs(tab) do
		if v2 == v then
			return i
		end
	end
	return -1
end


local function v3(p)
return vec3.new(p.x, p.y, p.z)
end


local function keys(tab) 
	local result = {}
	for k,v in pairs(tab) do
		table.insert(result,k)
	end
	return result
end

local function setTangent(tangent, t) -- because tangent is mysterious "userdata", can't give it a vec3
	tangent.x = t.x
	tangent.y = t.y
	tangent.z = t.z
end
local function setTangent2d(tangent, t)  
	tangent.x = t.x
	tangent.y = t.y 
end
local function hypot(x,y)
	return math.sqrt(x*x+y*y)
end
-- takes points
local function hypotlen(p1, p2) 
	return hypot(p2.x-p1.x, p2.y-p1.y)
end
-- takes arrays
local function hypotlen2(p1, p2) 
	return hypot(p2[1]-p1[1], p2[2]-p1[2])
end


local function deepClone(tab, transform)
    local results = {}
    if type(tab) ~= 'table' and type(tab) ~= 'userdata' then return results end

    for key, value in pairs(tab) do
		if type(value) == 'table' or type(value) == 'userdata'  then
			results[key] = deepClone(value, transform)
		else
			results[key] = transform and transform(value) or value
		end
    end
    return results
end
 


local function scoreRouteHeights(points)
	local score = 0
	for i, point in pairs(points) do
		score = score + math.abs(th(point )-point.z)
	end
	return score
end
local function scoreRouteHeights2(points)
	local score = 0
	for i, point in pairs(points) do
		score = score + math.abs(th(point.p )-point.p.z)
	end
	return score
end


local function calculateProjectedSpeedLimit(radius, trackData)
	if not trackData then trackData = api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua")) end
	return trackData.speedCoeffs.x * (radius + trackData.speedCoeffs.y) ^ trackData.speedCoeffs.z
end

local function calculateProjectedTime(radius, trackData)
	local projectedSpeedLimit = calculateProjectedSpeedLimit(radius, trackData)
	local projectedTravelTime = 2*math.pi*radius / projectedSpeedLimit
	trace("At radius=",radius," projectedSpeedLimit=",projectedSpeedLimit," (",api.util.formatSpeed(projectedSpeedLimit),"), projectedTravelTime=",projectedTravelTime)
	return projectedTravelTime
end

local circleScale = 0.5
 
local function updateCircle() 
	hascircle = true
	local view = game.gui.getCamera()
	circle.pos = {view[1], view[2]} 
	circle.radius = view[3]*circleScale
	game.interface.setZone("ai_builder", {
		polygon=zoneutil.makeCircleZone(circle.pos, circle.radius, 64),
		draw=true,
		drawColor = {0,128,0,1},
	})
end

 
local function remZone(id)
	game.interface.setZone(id)
	hascircle = false
end

local function newButton(text) 
	return util.newButton(text)
end
 

local abortButton
local function toggleAbort() 
	abortButton:setEnabled(#workItems >0)
end



local function firstNonNil(...)
	local args = table.pack(...)
    for i=1,args.n do
		if args[i] then
			return args[i]
		end
    end
end

local function checkLines(param) 
	local reportFn 
	
	if param then -- only when user called
		reportFn = function(status1, status2) 
			local buildParams = currentBuildParams
			if not buildParams then 
				buildParams = {}
			end
			buildParams.status1 = status1 
			buildParams.status2 = status2 
			currentBuildParams = buildParams
		end 
		
		reportFn("Checking all lines", "Checking.")
	end
	
	
	
	table.insert(workItems, function()
		lineManager.checkLinesAndUpdate(param, reportFn)
	end)
	needsupdate = true
end

local function budgetCheck(params) 
	local initialConsistCost = params.initialConsistCost
	local routeBudget = paramHelper.getParams().assumedCostPerKm * (params.distance / 1000)
	local totalBudget = routeBudget + initialConsistCost
	if params.isTrack then 
		totalBudget = totalBudget + 500000 -- stations / depots
	end
	
	--local balance = api.engine.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT).balance 
	--local balance = game.interface.getEntity(game.interface.getPlayer()).balance  -- this call has far less data in it 
	local balance = util.getAvailableBudget()
	trace("calculated a budget of ",totalBudget, "routeBudget=",routeBudget, "initialConsistCost=",initialConsistCost," compared against the current balance",balance,"above balance?",(totalBudget > balance))
	if totalBudget > balance and currentBuildParams then 
		currentBuildParams.status2 = _("Failed. Not enough money")
	end 
	params.estimatedCosts = totalBudget
	return totalBudget <= balance 
end  



local function completeBusNetwork(depotConstr, busStationConstr, town, stationPosAndRot) 
	addDelayedWork(function()
		local newProposal = api.type.SimpleProposal.new()	
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps() 
		newProposal = constructionUtil.completeBusNetwork(newProposal, depotConstr, busStationConstr, town, stationPosAndRot)
		
		local build = api.cmd.make.buildProposal(newProposal, initContext() , true)
		trace("About to sent command to completeBusNetwork for",town.name)
		api.cmd.sendCommand(build, function(res, success) 
			trace("depot connect result was ",success)
			if success then
				addWork(function() lineManager.setupTownBusNetwork( busStationConstr, town) end)
			else
				if util.tracelog then 
					debugPrint(res)
					executeImmediateWork(function() error("Unable to build bus network for town "..town.name)end) -- to pop up
				end
			end
			workComplete=true
		end)					
	end) 
end
 




local function connectDepotAndSetupTrainLineBetweenStations(station1, station2, depot, params)
	addWork(function()
		local function callback(res, success)
			trace("Result to build depot connection for ",depot," was ",success)

			local function callback2(res, success)
				trace("result of callback to setup train line was",success)
				if success then
					trace("About to mark as completed, currentBuildParams=",currentBuildParams)
					if currentBuildParams then
						markComplete()
					end
					-- Schedule multi-stop line extension if this was the first leg
					if params and params.isMultiStopFirstLeg and params.multiStopNextIndustry then
						trace("Multi-stop first leg complete, scheduling extension to third industry: ", params.multiStopNextIndustry.name)
						addDelayedWork(function()
							-- Guard against nil currentBuildParams
							if not currentBuildParams or not currentBuildParams.location2 then
								trace("ERROR: currentBuildParams not set for multi-stop extension")
								return
							end
							-- Build the second leg as a separate connection
							local extResult = {
								industry1 = game.interface.getEntity(currentBuildParams.location2), -- station2's industry
								industry2 = params.multiStopNextIndustry,
								station1 = station2,
								station2 = params.multiStopNextStation,
								p0 = util.getStationPosition(station2),
								p1 = params.multiStopNextPos,
								cargoType = params.multiStopNextCargo,
								distance = util.distance(util.getStationPosition(station2), params.multiStopNextPos),
								isCargo = true,
								carrier = api.type.enum.Carrier.RAIL,
								isAutoBuildMode = true,
								isMultiStopSecondLeg = true, -- Mark as second leg to avoid recursion
							}
							trace("Queuing second leg of multi-stop route")
							addWork(function() buildIndustryRailConnection(extResult) end)
						end)
					end
				else
					if res.reason ~=  "Not enough money" then
						if currentBuildParams then
							markFailed()
						end
					else

					end
				end
			end
				
				
			if not success then 
				if currentBuildParams then 
					currentBuildParams.status2 = _("Failed to connect depot")
				end
			end
			addWork(function()lineManager.setupTrainLineBetweenStations(station1, station2,  params, callback2) end)
		end
		local transportModes =  {api.type.enum.TransportMode.TRAIN}
		if depot and api.engine.entityExists(depot) and util.getConstruction(depot) and #pathFindingUtil.findPathFromDepotToStation(util.getConstruction(depot).depots[1], transportModes, station1)==0
			and #pathFindingUtil.findPathFromDepotToStation(util.getConstruction(depot).depots[1], transportModes, station2)==0 then
			routeBuilder.buildDepotConnection(callback, depot, params)
		else 
			trace("Skipping depot connection as a path was already found")
			callback({}, true)
		end 
	end) 

end

local function buildIndustryRailConnection(result, evalParam)
	-- Debug logging
	local function debugLog(msg)
		local f = io.open("/tmp/tf2_build_debug.log", "a")
		if f then f:write(os.date("%H:%M:%S") .. " RAIL: " .. msg .. "\n") f:close() end
	end
	debugLog("buildIndustryRailConnection called")
	debugLog("  result=" .. tostring(result))
	debugLog("  evalParam=" .. tostring(evalParam))
	if evalParam and evalParam.preSelectedPair then
		debugLog("  preSelectedPair[1]=" .. tostring(evalParam.preSelectedPair[1]))
		debugLog("  preSelectedPair[2]=" .. tostring(evalParam.preSelectedPair[2]))
	end

	if not result then
		addWork(function()
			debugLog("In addWork callback, evaluating...")
			-- Support preSelectedPair to force specific industry pair
			local param = evalParam or {}

			-- Try multi-stop routes first for higher utilization (unless preSelectedPair specified)
			if not param.preSelectedPair then
				local multiStopResult = connectEval.evaluateMultiStopCargoRoutes(circle)
				if multiStopResult and multiStopResult.isMultiStop then
					trace("Found multi-stop route candidate with estimated utilization: ", multiStopResult.estimatedUtilization)
					-- Convert multi-stop to staged P2P builds:
					-- First leg: industry[1] -> industry[2]
					result = {
						industry1 = multiStopResult.industries[1],
						industry2 = multiStopResult.industries[2],
						station1 = multiStopResult.stations[1],
						station2 = multiStopResult.stations[2],
						p0 = multiStopResult.positions[1],
						p1 = multiStopResult.positions[2],
						cargoType = multiStopResult.cargoTypes[1],
						distance = util.distance(multiStopResult.positions[1], multiStopResult.positions[2]),
						isCargo = true,
						carrier = api.type.enum.Carrier.RAIL,
						isMultiStopFirstLeg = true,
						multiStopNextIndustry = multiStopResult.industries[3],
						multiStopNextStation = multiStopResult.stations[3],
						multiStopNextPos = multiStopResult.positions[3],
						multiStopNextCargo = multiStopResult.cargoTypes[2],
					}
				end
			end

			if not result then
				debugLog("Calling evaluateNewIndustryConnectionForTrains with param.preSelectedPair=" .. tostring(param.preSelectedPair and param.preSelectedPair[1] or "nil"))
				result = connectEval.evaluateNewIndustryConnectionForTrains(circle, param)
			end
			if not result then
				local msg = _("No matching industries were found for ").._("rail")
				debugLog("ERROR: " .. msg)
				trace(msg)
				currentBuildParams = { status  = msg}
				return
			end
			debugLog("Got result: industry1=" .. tostring(result.industry1 and result.industry1.name or "nil") .. ", industry2=" .. tostring(result.industry2 and result.industry2.name or "nil"))
			result.isAutoBuildMode = true
			-- CLAUDE CONTROL: Bypass budget check for preSelectedPair routes
			if param and param.preSelectedPair then
				result.alreadyBudgetChecked = true
				debugLog("FORCE: Bypassing budget check for preSelectedPair")
			end
			addWork(function() buildIndustryRailConnection(result) end)
		end)
		return
	end

	local msgFn = function(result)
		if result.isMultiStopFirstLeg then
			return  _("Connecting").." ".._("industry").." ".._(result.industry1.name).." "..("to").." ".._(result.industry2.name).." ".._("(multi-stop route)")
		end
		return  _("Connecting").." ".._("industry").." ".._(result.industry1.name).." "..("with").." ".._(result.industry2.name).." ".._("using").." ".._("rail")
	end
	currentBuildParams = { status =  msgFn(result), status2 =  _("Initialising")..".",  carrier = api.type.enum.Carrier.RAIL, location1= result.industry1.id,location2= result.industry2.id } 
 
	addPause()
	addDelayedWork(function() 
		local originalResult = result
		util.lazyCacheNode2SegMaps() 
		if not result then  
			result = connectEval.evaluateNewIndustryConnectionForTrains(circle) 
		else 
			
		end

		connectEval.recheckResultForStations(result, true, api.type.enum.Carrier.RAIL)
		local msg =msgFn(result)
		trace("******************************************************************************")
		trace(msg)
		trace("******************************************************************************")
		local newProposal = api.type.SimpleProposal.new()
		local station1Idx = -1
		local station2Idx = -1
		local depotIdx = -1 
		local stationPosAndRot
		local cargoType =  result.cargoType
		local params = paramHelper.getDefaultRouteBuildingParams(cargoType, true, ignoreErrors, result.distance) 
		params.initialTargetLineRate = result.initialTargetLineRate
		if result.customRouteScoring then 
			params.routeScoreWeighting = result.customRouteScoring
		end 
		if result.paramOverrides then 
			for k, v in pairs(result.paramOverrides) do 
				trace("Overriding",k," to ",v)
				params[k]=v
				if k =="stationLengthParam" then 
					params.stationLengthOverriden = true
					trace("Station length was overriden")
				end 
			end 
		end 
		currentBuildParams = params
		currentBuildParams.status = msg
		currentBuildParams.carrier = api.type.enum.Carrier.RAIL
		currentBuildParams.location1 = result.industry1.id
		currentBuildParams.location2 = result.industry2.id
		-- Store multi-stop info for later line extension
		if result.isMultiStopFirstLeg then
			params.isMultiStopFirstLeg = true
			params.multiStopNextIndustry = result.multiStopNextIndustry
			params.multiStopNextStation = result.multiStopNextStation
			params.multiStopNextPos = result.multiStopNextPos
			params.multiStopNextCargo = result.multiStopNextCargo
			trace("Multi-stop route: will extend to third industry after first leg")
		end
		connectEval.coolDownLocation(result.industry1.id)
		connectEval.coolDownLocation(result.industry2.id) 
		lineManager.setupTrainLineParams(params, result.distance)
		if not budgetCheck(params) and not result.alreadyBudgetChecked then
			if result.isAutoBuildMode then 
				connectEval.enqueueResult(result, params.estimatedCosts)
			end 
			return
		end 
		result.alreadyBudgetChecked=true
		params.isElevated=result.isElevated
		params.isUnderground=result.isUnderground
		params.isAutoBuildMode = result.isAutoBuildMode
		if result.isAutoBuildMode and result.distance > 4000 then 
			trace("Overriding doubletrack to true for autobuild")
			params.isDoubleTrack = true 
		end 
		if result.industry2.type == "TOWN" then 
			params.isForTownTranshipment = true
			params.isForTranshipment = true
			if not params.stationLengthOverriden and params.stationLengthParam > 2 then -- large stations are counterproductive as they overload the truck station
				params.stationLengthParam = 2 
				params.stationLength = 160 
				trace("Reducing the station size to 160 for town delivery")
			end 
		end 
		local existingPath = result.station1 and result.station2 and pathFindingUtil.checkForRailPathBetweenStationFreeTerminals(result.station1 , result.station2 ) 
		if result.station1 then 
			if constructionUtil.getStationLength(result.station1) < params.stationLength and not result.station1AlreadyLengthened then 
				trace("Attempting station length upgrade for",result.station1)
				result.station1AlreadyLengthened=true 
				constructionUtil.upgradeStationLength(result.station1, params, function() buildIndustryRailConnection(result) end) 
				return
			end 
			if util.countFreeUnconnectedTerminalsForStation(result.station1)==0 and not existingPath then
				constructionUtil.upgradeStationAddTerminal(result.station1,result.industry2, function() buildIndustryRailConnection(result) end, params)
				return
			end
			if not result.station2 then 
				if result.industry2.type == "TOWN" then 
					params.buildTerminus[result.industry2.id]=true
				
					local nodes = connectEval.evaluateBestIndustryStationLocations(result.industry1, result.industry2, params)
					params.ignoreErrors = false
					stationPosAndRot = constructionUtil.buildTrainStationConstructionForTown(newProposal,result.industry2, nodes, false, result.industry1,params)
					if not stationPosAndRot then 
						trace("Failed to build station")
						if currentBuildParams then 
							markFailed()
						end
						connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, result.industry1.id, result.industry2.id)
						return 
					end 
					station2Idx = stationPosAndRot.stationIdx
				else 
					constructionUtil.buildTrainStationConstructionAtEndOfEdge(newProposal, result.industry2, result.edge2, result.industry1, params, true)
					depotIdx=2 
					station2Idx=1
				end
				
				
			else 
				if util.countFreeUnconnectedTerminalsForStation(result.station2)==0  and not existingPath then
					constructionUtil.upgradeStationAddTerminal(result.station2,result.industry1, function() buildIndustryRailConnection(result) end, params)
					return
				end
			end
		else 
			constructionUtil.buildTrainStationConstructionAtEndOfEdge(newProposal, result.industry1, result.edge1, result.industry2, params,true)
			station1Idx=1
			if #newProposal.constructionsToAdd > 1 then 
				depotIdx=2
			end
			if not result.station2 then 
				if result.industry2.type == "TOWN" then 
					local nodes = connectEval.evaluateBestIndustryStationLocations(result.industry1, result.industry2, params)
					params.ignoreErrors = false
					stationPosAndRot = constructionUtil.buildTrainStationConstructionForTown(newProposal,result.industry2, nodes, false, result.industry1,params)
					--stationDepot1Idx = station1PosAndRot.depotIdx
					if not stationPosAndRot then 
						trace("Failed to build station")
						if currentBuildParams then 
							markFailed()
						end
						connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, result.industry1.id, result.industry2.id)
						return 
					end 
					station2Idx = stationPosAndRot.stationIdx
				else
					constructionUtil.buildTrainStationConstructionAtEndOfEdge(newProposal, result.industry2, result.edge2, result.industry1, params, false)
					station2Idx=#newProposal.constructionsToAdd
				end
				
			else 
				if constructionUtil.getStationLength(result.station2) < params.stationLength and not result.station2AlreadyLengthened then 
					trace("Attempting station length upgrade for",result.station2)
					result.station2AlreadyLengthened=true 
					constructionUtil.upgradeStationLength(result.station2, params, function() buildIndustryRailConnection(result) end) 
					return
				end 
				if util.countFreeUnconnectedTerminalsForStation(result.station2)==0 then
					constructionUtil.upgradeStationAddTerminal(result.station2,result.industry1, function() buildIndustryRailConnection(result) end, params)
					return
				end
			end
		end
		if result.isTown then
			xpcall(function() constructionUtil.buildTruckStopOnProposal(result.edge2.id, result.stopName) end, err) -- this may succeed but throw an error, so hived off to allow this to continue
		end
		 
	
		local build = api.cmd.make.buildProposal(newProposal, initContext() , true)
		trace("About to sent command")
		api.cmd.sendCommand(build, function(res, success) 
			trace("build stations result was ",success)
			util.clearCacheNode2SegMaps()
			if success then
				currentBuildParams.status2 = _("Building route").."."
				local station1Constr = result.station1 and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(result.station1) or res.resultEntities[station1Idx]
				local station2Constr =  result.station2 and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(result.station2)  or res.resultEntities[station2Idx]
				local depotConstr =  res.resultEntities[depotIdx] 
				if not depotConstr then 
					depotConstr = constructionUtil.searchForRailDepot(result.industry1.position, result.industry2.position)
				end
				addWork(function() 
					util.cacheNode2SegMaps()
					local station1 = api.engine.getComponent(station1Constr, api.type.ComponentType.CONSTRUCTION).stations[1]
					local station2 = api.engine.getComponent(station2Constr, api.type.ComponentType.CONSTRUCTION).stations[1]
					
					
					
					local  callback = function(res2, success)
						trace("Result of route build callback to connect ",station1," and ",station2," was ",success)
						if success then
							markComplete()
							currentBuildParams.status2 = _("Route build complete, setting up line and vehicles").."."
							connectDepotAndSetupTrainLineBetweenStations(station1, station2, depotConstr, params)
							local busStationConstr
							if stationPosAndRot then 
								busStationConstr = res.resultEntities[stationPosAndRot.roadStationIdx]
								local depotConstr = stationPosAndRot.roadDepotIdx and res.resultEntities[stationPosAndRot.roadDepotIdx]
								addWork(function() 
									local newProposal = api.type.SimpleProposal.new()	
									constructionUtil.completeBusNetwork(newProposal, depotConstr, busStationConstr, result.industry2, stationPosAndRot, true)
									local build = api.cmd.make.buildProposal(newProposal, initContext() , true)
									api.cmd.sendCommand(build, function(res, success)
										trace("Attempt to build completeBusNetwork for ",result.industry2.name,"was",success)
										standardCallback(res, success)
									end)
								end)
								
							end
							if result.isTown then 
								addDelayedWork(function() 
										local stations = {}
										if busStationConstr then 
											stations[1]=util.getConstruction(busStationConstr).stations[1]
										else 
											stations[1]=constructionUtil.searchForNearestCargoRoadStation(util.getStationPosition(result.station2), 300)
										end
										stations[2]=util.findStopBetweenNodes(result.edge2.node0, result.edge2.node1)
										lineManager.setupTrucks(result, stations, params)
									end)
							end
							 
						else 
							if currentBuildParams then 
								currentBuildParams.status2 = _("Building failed")
							else 
								currentBuildParams = { status2 = _("Building failed") }
							end
							--debugPrint(res2.resultProposalData)
							if res2.reason == "Not enough money" then 
								trace("Suppressed marking connection as failed for not enough money")
								currentBuildParams.status2 = currentBuildParams.status2.." ".._("Not enough money")
								connectEval.enqueueResult(result, res2.costs)
							else 
								
								connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, result.industry1.id, result.industry2.id)
							end 
						end
						standardCallback(res2, success)
					end 
					params.allEdgesUsedByLines = util.memoize(pathFindingUtil.getAllEdgesUsedByLines)
					routeBuilder.buildRouteBetweenStations(station1, station2, params, callback)
				end)
			else 
				debugPrint(res.resultProposalData.errorState)
				connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, result.industry1.id, result.industry2.id)
				if not originalResult then 
					--buildIndustryRailConnection()
				end
			end
			workComplete=true
		end)	
	end)
end




local function filterRoadEntrances(filename) 
	if string.find(filename,"street_station/entrance") then
		return false 
	end
	if string.find(filename,"street_depot/entrance") then
		return false 
	end
	return true
end
local function getConnectTownDisplayMessage(citypair)
	local town1 = citypair[1] or citypair.town1
	local town2 = citypair[2] or citypair.town2
	return _("Connecting").." ".._("towns").." ".._(town1.name).." "..("with").." ".._(town2.name).." ".._("using").." ".._("rail")
end

local function buildCompleteRoute(param) 
	trace("Call to build completeRoute")
	currentBuildParams = {status=_("Building complete route")}
	currentBuildParams.status2 =  _("Building").."."
	currentBuildParams.isCompleteRoute = true 
	if util.tracelog then 
		debugPrint(param)
	end
	addWork(function() 
		util.lazyCacheNode2SegMaps() 
		local isTrack = param.isTrack
		local towns = param.towns
		local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS",isTrack, ignoreErrors)
		if param.isExpress then 
			params.isQuadrupleTrack = true 
			params.edgeWidth = 4*params.trackWidth
			params.maxInitialTrackAngle = 10 -- in degrees
			if util.year() >= 1980 then 
				params.setForVeryHighSpeed()
			end 
		end
		local terminusIdxs = {}
		for i = 1, #towns do 
			params.buildTerminus[towns[i].id]=false
		end 
		if not param.isCircularRoute then 
			params.buildTerminus[towns[1].id]=true
			params.buildTerminus[towns[#towns].id]=true
			terminusIdxs[1]=true 
			terminusIdxs[#towns]=true
			params.alwaysDoubleTrackPassengerTerminus = true
		end 

		for k, v in pairs(param.paramOverrides) do 
			trace("Overriding",k," to ",v)
			params[k]=v
			if k =="stationLengthParam" then 
				params.stationLengthOverriden = true
				trace("Station length was overriden")
			end 
		end 
		params.isDoubleTrack = true

		
		params.terminusIdxs = terminusIdxs
		params.buildCompleteRoute=true
		params.isHighway = not isTrack
		
		params.allEdgesUsedByLines = util.memoize(pathFindingUtil.getAllEdgesUsedByLines)
		params.disableDepotProximityCheck = true
		params.alwaysDoubleTrackStation = true
		local stations = {}
		local expressStations = {}
		local depots = {}
		params.initialTargetLineRate = 0
		local divisor = param.isExpress and 2 or 1
		local existingStationCount =0 
		local expressIdx = 0
		if params.isHighway then 
			params.stationLocationScoreWeights = paramHelper.getParams().highwayConnectionScoreWeights
		end 
		for i = 1, #towns do 
			local town = towns[i]
			if town.isExpressStop then 
				expressIdx = expressIdx + 1 
				town.expressIdx = expressIdx -- need to lock this down to preserve ordering
			end 
		end 
		params.expectedPositions = {}
		--local nodeInfos = {}
		for i = 1, #towns do  -- first iteration
			local town = towns[i]
			local otherTown = i == 1 and towns[#towns] or towns[i-1]
			local otherTown2 = i==#towns and towns[1] or towns[i+1]
			if not param.isCircularRoute and i == 1 then 
				trace("Setting the otherTown to othertown2")
				otherTown = otherTown2 
			end 
			local existingStation = isTrack and util.findBestPassengerTrainStationForTown(town.id)
			if existingStation then 
				params.expectedPositions[town.id]=util.getStationPosition(existingStation)
			else 
				trace("Inspecting for ",town.id," named",town.name)
				local nodeInfo = connectEval.evaluateBestPassengerStationLocation(town, otherTown, otherTown2, params)
					
				local expectedPosition = util.nodePos(nodeInfo[1].node)
				params.expectedPositions[town.id]=expectedPosition
				trace("Setting the expectedPosition for ",town.id," named",town.name,"to ",expectedPosition.x,expectedPosition.y)
			end
		end
		
		for i = 1, #towns do 
			local town = towns[i]
			connectEval.coolDownLocation(town.id)
			trace("buildCompleteRoute: Inspecting town ",town.name," at ",i," of ",#towns)
			local otherTown = i == 1 and towns[#towns] or towns[i-1]
			local otherTown2 = i==#towns and towns[1] or towns[i+1]
			if not param.isCircularRoute and i == 1 then 
				trace("Setting the otherTown to othertown2")
				otherTown = otherTown2 
			end 
			local realignPositions = true 
			if realignPositions then 
				otherTown = util.shallowClone(otherTown)
				otherTown2 = util.shallowClone(otherTown2)
				otherTown.position = util.v3ToArr(params.expectedPositions[otherTown.id])
				otherTown2.position = util.v3ToArr(params.expectedPositions[otherTown2.id])
			end 
			local nodeInfo = connectEval.evaluateBestPassengerStationLocation(town, otherTown, otherTown2, params)
			local expectedPosition = util.nodePos(nodeInfo[1].node)
			params.expectedPositions[town.id]=expectedPosition
			trace("Setting the expectedPosition for ",town.id," named",town.name,"to ",expectedPosition.x,expectedPosition.y)
			
			if isTrack then 
				params.initialTargetLineRate = params.initialTargetLineRate + game.interface.getTownCapacities(town.id)[1] /divisor
				
				if i % 2 == 0 then 
					trace("buildCompleteRoute: Swapping town order for depot")
					local temp = otherTown 
					otherTown = otherTown2 
					otherTown2 = temp
				end 
				local existingStation = util.findBestPassengerTrainStationForTown(town.id)
				if existingStation then 	
					params.expectedPositions[town.id]=util.getStationPosition(existingStation)
					existingStationCount = existingStationCount + 1
					stations[i]=existingStation
					if town.isExpressStop then 
						expressStations[town.expressIdx]=existingStation
					end 
					local numTerminals = params.isQuadrupleTrack and 4 or 2
					local minTerminals = params.isQuadrupleTrack and town.isExpressStop and 4 or 2
					local isTerminus = terminusIdxs[i]  
					if params.useDoubleTerminals and not isTerminus then 
						numTerminals = numTerminals*2
						minTerminals = minTerminals*2
					end
					local existingTerminals = util.countFreeUnconnectedTerminalsForStation(existingStation)
					local buildThroughTracks = false 
					if #api.engine.system.lineSystem.getLineStopsForStation(existingStation) == 0 then 
						numTerminals = minTerminals
						if params.isQuadrupleTrack and not town.isExpressStop then 
							if params.useDoubleTerminals then 
								numTerminals = numTerminals + 2
							else
								buildThroughTracks = true
							end 
						end
					end 
					trace("The existingTerminals for ",existingStation," was ",existingTerminals)
					if existingTerminals < minTerminals or buildThroughTracks then 
						local terminalsToAdd = numTerminals-existingTerminals 
						local nextTown
						if isTerminus then 
							 
							nextTown = i==1 and towns[2] or towns[#towns-1]
							 
						end  
						constructionUtil.upgradeStationAddTerminals(existingStation,terminalsToAdd , buildThroughTracks, params, nextTown)
						 
					end
				else
					
					local buildDepot = true
					--collectgarbage()
					local newProposal = api.type.SimpleProposal.new()
					params.ignoreErrors = false
					local stationPosAndRot = constructionUtil.buildTrainStationConstructionForTown(newProposal,town, nodeInfo, buildDepot, otherTown,util.deepClone(params), otherTown2)
					if not stationPosAndRot then 
						goto continue 
					end
					trace("Updating expected positions to ",stationPosAndRot.position.x, stationPosAndRot.position.y)
					params.expectedPositions[town.id] = stationPosAndRot.position
					trace("buildCompleteRoute:  Building construction station expected at ",stationPosAndRot.stationIdx)
					util.validateProposal(newProposal) 
					local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
					if util.tracelog then 	
						util.removeTrafficlights(build)
					end
					local idx = i 
					api.cmd.sendCommand(build, function(res, success) 
						trace(" buildCompleteRoute: callback: Built station for town",town.name," success was",success, "  stationPosAndRot.stationIdx =", stationPosAndRot.stationIdx )
						util.clearCacheNode2SegMaps()
						if success and  stationPosAndRot.stationIdx then 
							
							local station =  util.getConstruction(res.resultEntities[stationPosAndRot.stationIdx]).stations[1]
							trace("Got station ",station)
							stations[idx]=station
							if town.isExpressStop then 
								expressStations[town.expressIdx]=station
							end 
							if stationPosAndRot.depotIdx then 
								trace("buildCompleteRoute: callback: Adding depot at ", stationPosAndRot.depotIdx)
								table.insert(depots, res.resultEntities[stationPosAndRot.depotIdx])
								trace("buildCompleteRoute: callback: Added depot at ", res.resultEntities[stationPosAndRot.depotIdx])
							end
							if params.buildInitialBusNetwork then 
								addWork(function() 
									completeBusNetwork(stationPosAndRot.roadDepotIdx and res.resultEntities[stationPosAndRot.roadDepotIdx], stationPosAndRot.roadStationIdx and res.resultEntities[stationPosAndRot.roadStationIdx], town, stationPosAndRot) 
								end)
							end
						end
						trace("End callback: Built station for town",town.name," success was",success)
					end) 
				end
			else 
				addWork(function() constructionUtil.createHighwayJunction(town, nodeInfo,otherTown, standardCallback, params, otherTown2)end)
			end
			::continue::
		end
		trace("buildCompleteRoute: Completed station construction, moving to route build")
		addDelayedWork(function() 
			local startFrom = param.isCircularRoute and 1 or 2 
			local expectedResult = 1+#towns-startFrom
			local currentCount = 0
			local function callback(res, success)
				trace("buildCompleteRoute: Callback from building route success was",success)
				if success then 
					currentCount = currentCount + 1
					trace("BuildCompleteRoute: Got ",currentCount," of ",expectedResult,"expected")
					if currentBuildParams then 
						currentBuildParams.status = _("Building complete route").." "..tostring(currentCount).." ".._("of").." "..tostring(expectedResult).." ".._("Complete")
					end 
					local currentCountCopy = currentCount
					if not terminusIdxs[currentCount] then 
						addDelayedWork(function() routeBuilder.buildDepotConnection(standardCallback, depots[currentCountCopy], params) end)
					end
					if currentCount == expectedResult then 
						trace("Got the results")
						if not isTrack then 
							if currentBuildParams then 
								markComplete()
							end
						end
						local function callback2(res, success) 
							trace("BuildCompleteRoute: Result of callback2 was ",success)
							if success then 
								trace("About to mark as completed, currentBuildParams=",currentBuildParams)
								if currentBuildParams then 
									markComplete()
								end
							else 
								if currentBuildParams then 
									markFailed()
								end
							end
						end
						if not param.isCircularRoute then 
							local stationCount = #stations 
							for i = stationCount-1, 2, -1 do 
								trace("Reinserting ",stations[i]," at i=",i)
								table.insert(stations, stations[i])
							end 
							local stationCount = #expressStations 
							for i = stationCount-1, 2, -1 do 
								trace("Reinserting  expressStations",expressStations[i]," at i=",i)
								table.insert(expressStations, expressStations[i])
							end 
						end 
						if isTrack then 
							addWork(function()lineManager.createNewTrainLineBetweenStations(stations,  params, callback2, _("Stopping")) end)
							if param.isExpress then 
								addDelayedWork(function()lineManager.createNewTrainLineBetweenStations(expressStations,  params, callback2) end)
							end 
							if param.isCircularRoute then 
								local reversedStations = {}
								for i = #stations, 1, -1 do 
									table.insert(reversedStations, stations[i])
								end
								local reversedExpressStations = {}
								for i = #expressStations, 1, -1 do 
									table.insert(reversedExpressStations, expressStations[i])
								end
								local params2 = util.deepClone(params)
								params2.reduceBudgetForCircleRoute = true
								addWork(function()lineManager.createNewTrainLineBetweenStations(reversedStations,  params2, callback2, _("Stopping")) end)
								if param.isExpress  then 
									addDelayedWork(function()lineManager.createNewTrainLineBetweenStations(reversedExpressStations,  params2, callback2) end)
								end 
							end
						end
					end
				else
					trace("BuildCompleteRoute: Had a failure")
					if util.tracelog then debugPrint(res) end
					if currentBuildParams then 
						markFailed()
					end
				end
				addPause() -- need to give the engine thread a break to deliver back feedback to ui
			end
			if not isTrack then 
				local startFrom = param.isCircularRoute and 1 or 2 
				for i = startFrom , #towns do 
					local town1 = i ==1 and towns[#towns] or towns[i-1]
					local town2 = towns[i]
					addDelayedWork(function() routeBuilder.buildHighway(town1, town2, callback, params)end)
				end
			
				return
			end 
			params.allStations = stations
			params.isCircularRoute = param.isCircularRoute
			for i = startFrom, #stations do 
				local station1 = i==1 and stations[#stations] or stations[i-1]
				local station2 = stations[i]
				if i % 2 == 0 then 
					trace("buildCompleteRoute: Swapping station order")
					local temp = station1 
					station1 = station2 
					station2 = temp
				end 
				local params2 = util.deepClone(params)
				params2.ignoreErrors = true
				addWork(function() routeBuilder.buildRouteBetweenStations(station1, station2, params2, callback )end)
			end 	
			
		end)
	end)
end

local function connectTowns(orderedCityPairs, index)
	local targetSeglenth = 90
	if index > util.size(orderedCityPairs) then
		trace("exiting connectTowns early, requested index=",index, " orderedCityPairsCount=",orderedCityPairsCount)
		workComplete = true
		return
	end
	util.lazyCacheNode2SegMaps() 
	local citypair = orderedCityPairs[index]
	local result = citypair
	local town1 = citypair[1] or citypair.town1
	local town2 = citypair[2] or citypair.town2
	local msg = getConnectTownDisplayMessage(citypair)
	trace("******************************************************************************")
	trace(msg)
	trace("******************************************************************************") 
	local existingStations1 = util.findPassengerTrainStationsForTownWithCapacity(town1.id)
	local existingStations2 = util.findPassengerTrainStationsForTownWithCapacity(town2.id)
	local town1HasStation = #existingStations1>0
	local town2HasStation = #existingStations2>0
	local straightlinevec = util.v3fromArr(town1.position) - util.v3fromArr(town2.position)
	local distance = vec3.length(straightlinevec)
	local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", true, ignoreErrors, distance)
	params.isElevated=result.isElevated
	params.isUnderground=result.isUnderground
	params.initialTargetLineRate = connectEval.estimateInitialTargetLineRateBetweenTowns(town1, town2)
	if result.customRouteScoring then 
		trace("Setting the custom route scoring") 
		params.routeScoreWeighting = result.customRouteScoring
	end 
	if result.paramOverrides then 
		for k, v in pairs(result.paramOverrides) do 
			trace("Overriding",k," to ",v)
			params[k]=v
			if k =="stationLengthParam" then 
				params.stationLengthOverriden = true
			end 
		end 
	end 
	params.isAutoBuildMode = result.isAutoBuildMode
	params.buildTerminus = result.buildTerminus
	currentBuildParams = params
	currentBuildParams.status = msg
	currentBuildParams.status2 = _("Searching for station locations").."."
	currentBuildParams.carrier = api.type.enum.Carrier.RAIL
	currentBuildParams.location1 = town1.id
	currentBuildParams.location2 = town2.id
	lineManager.setupTrainLineParams(params, distance)
	if not budgetCheck(params) then 
		return
	end 
	if town1HasStation then
		local stationId = existingStations1[1]
		if util.countFreeUnconnectedTerminalsForStation(stationId)==0 then
			constructionUtil.upgradeStationAddTerminal(stationId,town2, function() connectTowns(orderedCityPairs, index) end,params)
			return
		end
	end

	if town2HasStation then
		local stationId = existingStations2[1]
		if util.countFreeUnconnectedTerminalsForStation(stationId)==0 then
			constructionUtil.upgradeStationAddTerminal(stationId,town1, function() connectTowns(orderedCityPairs, index) end,params)
			return
		end
	end
	

	if town1HasStation and town2HasStation then	
		--routeBuilder.buildRouteBetweenStations(existingStations1[1], existingStations2[1],params, standardCallback)
		--return
	end
	
	if town1HasStation and not town2HasStation then 
		local temp = result.town1 
		result.town1 = result.town2 
		result.town2 = temp
		connectTowns({result},1) -- connect the other way around to get a depot
		return
	end
	

	 

	 
	
	local leftNodeInfo 
	local rightNodeInfo
	
	if not town1HasStation or not town2HasStation then 
		local nodepair = connectEval.evaluateBestPassengerStationLocations(town1, town2, params)
		leftNodeInfo= nodepair[1]
		rightNodeInfo = nodepair[2]
	end
	if town1HasStation then 
		lineManager.checkForExtensionPosibilities(params, existingStations1[1])
	end
	if town2HasStation then 
		lineManager.checkForExtensionPosibilities(params, existingStations2[1])
	end
	local newProposal = api.type.SimpleProposal.new()

	
	local function buildTownBusStops(town, edgeId)
	
			constructionUtil.buildBusStopOnProposal(edgeId, newProposal)
		
		local centerEdgeId = game.interface.getEntities({radius=10, pos = town.position},{type="BASE_EDGE"})
		if centerEdgeId and #centerEdgeId > 0 then
			trace("Looking to build at central bus stop at ",centerEdgeId[1])
			
				constructionUtil.buildBusStopOnProposal(centerEdgeId[1], newProposal)
			
		end
	end


	local leftDepotTangent
	local leftDepotNode

	local roadDepotConstruction1 
	local roadDepotConstruction2
	
	local station1Idx = -1
	local station2Idx = -1
	local roadDepot1Idx = -1
	local roadDepot2Idx = -1
	local busStation1Idx = -1
	local busStation2Idx = -1
	local stationDepot1Idx = -1
	local station1PosAndRot 
	local station2PosAndRot
	local constructionsToAdd ={}
	if not town1HasStation then
		local buildDepot = true
		params.ignoreErrors = false
		station1PosAndRot = constructionUtil.buildTrainStationConstructionForTown(newProposal,town1, leftNodeInfo, buildDepot, town2,params)
		if not station1PosAndRot then 
			markFailed()
			connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, town1.id, town2.id)
			return
		end
		stationDepot1Idx = station1PosAndRot.depotIdx
		station1Idx = station1PosAndRot.stationIdx
		roadDepot1Idx = station1PosAndRot.roadDepotIdx or -1
		busStation1Idx = station1PosAndRot.roadStationIdx
	end	
	
	if not town2HasStation then
		params.ignoreErrors = false
		station2PosAndRot = constructionUtil.buildTrainStationConstructionForTown(newProposal,town2, rightNodeInfo, false, town1,params)
		if not station2PosAndRot then 
			markFailed()
			connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, town1.id, town2.id)
			return
		end
		station2Idx = station2PosAndRot.stationIdx
		
		roadDepot2Idx = station2PosAndRot.roadDepotIdx or -1
		busStation2Idx = station2PosAndRot.roadStationIdx
	end	
	local shouldIgnoreErrors = params.ignoreErrors
	local testData = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	debugPrint({testDataError=testData.errorState.messages, testDataCollision=testData.collisionInfo})
	if #testData.errorState.messages == 1 and testData.errorState.messages[1]=="Collision" and not testData.errorState.critical and not shouldIgnoreErrors then 
		local removedSet = {}
		for i, edgeId in pairs(newProposal.streetProposal.edgesToRemove) do 
			removedSet[edgeId] = true
		end
		shouldIgnoreErrors = true -- seems to be a bug where we collide with entities being removed 
		for i, entity in pairs(testData.collisionInfo.collisionEntities) do 
			if entity.entity > 0 and not removedSet[entity.entity] then 
				shouldIgnoreErrors = false 
				break
			end
		end
	end
	
	util.validateProposal(newProposal)
	trace("About to build command")
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), shouldIgnoreErrors)
	trace("About to sent command")
	 util.removeTrafficlights(build)
	-- if tracelog then debugPrint({build=build}) end
	api.cmd.sendCommand(build, function(res, success) 
		trace(" attempt command result was", tostring(success))
		if success then 
			currentBuildParams.status2 = _("Building route").."."
		--	failedCount = failedCount - 1
		 
			--debugPrint(res)
			local addedNodes = {}
			local addedSegments = {}
		
		 


			table.insert(workItems, function()
				trace("begin connecting stations")
				local deadEndNodesLeft = {}
				local deadEndNodesRight = {}
				local alreadySeen = {}
				local depotSegments = {}
				-- need to capture this information here because it seems the data is not available in the system.streetConnector etc. until some time later
				--[[for i, seg in pairs(res.resultProposalData.entity2tn) do
		
					for j, tn in pairs(seg.edges) do
						if tn.transportModes[8]==1 then -- train 
							local owner = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(i)
							local left = owner == res.resultEntities[station1Idx]
							local right = owner == res.resultEntities[station2Idx]
							local depot1 = owner == res.resultEntities[stationDepot1Idx]
							for k = 1, 2 do
								local node = tn.conns[k].entity
								if not alreadySeen[node] then 
									alreadySeen[node]= { owners = 1, left = left, right=right, depot1=depot1, segs={}, k=k}
								end 
								alreadySeen[node].segs[i]=true
								
							end
						elseif tn.transportModes[3]==1 then ]]--
							--[[local owner = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(i)
							local left = owner == res.resultEntities[roadDepot1Idx]
							local right = owner == res.resultEntities[roadDepot2Idx]
							if left or right then
								local nodes = {}
								local index = 0
								for k = 1, 2 do
									table.insert(nodes, tn.conns[k].entity)
									index = tn.conns[k].index
								end
								table.insert(depotSegments, { nodes=nodes, left = left, right=right, seg=i, tangent=tn.geometry.params.tangent, pos=tn.geometry.params.pos, index=index, owner=owner})
							end--]]
							
						--end
					--end 
				--end
				if not town1HasStation and params.buildInitialBusNetwork then
					completeBusNetwork(res.resultEntities[roadDepot1Idx], res.resultEntities[busStation1Idx], town1, station1PosAndRot) 
				end
				if not town2HasStation and params.buildInitialBusNetwork  then
					completeBusNetwork(res.resultEntities[roadDepot2Idx], res.resultEntities[busStation2Idx], town2, station2PosAndRot) 
				end
				needsupdate=true
				local depot1Node
				local node2SegMap = {}
				for node, info in pairs(alreadySeen) do
					if util.size(info.segs)==1 then
						node2SegMap[node]=keys(info.segs)[1]
						if info.left then
							deadEndNodesLeft[node]=util.nodePos2(node)

						elseif info.right then
							deadEndNodesRight[node]=util.nodePos2(node)
						elseif info.depot1 then
							trace("getting depot node ",node," at k=",info.k)
							depot1Node = node
						end
					end
				end
				local station1
				if town1HasStation then
					station1 = existingStations1[1]
					for i ,node in pairs(util.getFreeNodesForFreeTerminalsForStation(station1)) do
						deadEndNodesLeft[node]=util.nodePos2(node)
						 
					end
				else 
					station1 = api.engine.getComponent(res.resultEntities[station1Idx], api.type.ComponentType.CONSTRUCTION).stations[1]
				end
				local station2
				if town2HasStation then
					station2 = existingStations2[1]
					for i ,node in pairs(util.getFreeNodesForFreeTerminalsForStation(station2)) do
						deadEndNodesRight[node]= util.nodePos2(node)
					 
					end
				else 
					station2 = api.engine.getComponent(res.resultEntities[station2Idx], api.type.ComponentType.CONSTRUCTION).stations[1]
				end
				
				local railDepot
				if stationDepot1Idx ~= -1 and stationDepot1Idx then
					railDepot = res.resultEntities[stationDepot1Idx]
				end
				
				if util.tracelog then debugPrint({deadEndNodesLeft=deadEndNodesLeft, deadEndNodesRight=deadEndNodesRight}) end
				
				local  callback = function(res, success)
					trace("Result of route build callback to connect ",station1," and ",station2," was ",success)
					if success then
						currentBuildParams.status2 = _("Route build complete, setting up line and vehicles").."."
						connectDepotAndSetupTrainLineBetweenStations(station1, station2, railDepot, params) 
					else 
						currentBuildParams.status2 = _("Building failed")
						if res.resultProposalData then 
							debugPrint(res.resultProposalData.errorState)
						end
					end
					workComplete = true
				end
				params.allEdgesUsedByLines = util.memoize(pathFindingUtil.getAllEdgesUsedByLines)
				routeBuilder.buildRouteBetweenStations(station1, station2,params, callback )
		
			end)
			local function waitFunction()
				trace("in dummy function")
				if not waitTest() then 
					trace("wait test failed, adding another wait")
					table.insert(workItems, waitFunction)
				end
				needsupdate = true
				workComplete = true
			end
			
			--table.insert(workItems, waitFunction)
			needsupdate = true
			--res.resultProposalData.streetProposal.
		else	
		--[[	if #orderedCityPairs > index then
				debuglog("Could not connect ", town1.name, " with ", town2.name, " attempting next")
				table.insert(workItems, function() xpcall(function() connectTowns(orderedCityPairs, index+1) end, err) end)
				needsupdate=true
			 
			else]]--
		 
			--if debuglog then debugPrint(res) end
			--debugPrint(res)
				debugPrint(res.resultProposalData.errorState)
			--end
		 debugPrint(res.resultProposalData.collisionInfo)
			connectEval.markConnectionAsFailed(api.type.enum.Carrier.RAIL, town1.id,town2.id)
		end
		--updateView() 
		workComplete = true
	end )
end
local function buildNewPassengerTrainConnections(result)
	local minDist = 0 
	if highSpeed then 
		minDist = paramHelper.getParams().highSpeedPassengerRailDistanceThreashold
	end
	if result then 
		currentBuildParams = { status =  getConnectTownDisplayMessage(result) } 
		currentBuildParams.status2 =  _("Initialising").."."
		addPause() -- allow the engine thread to callback before starting
	end
	addDelayedWork(function() 
		if not result then 
			result = connectEval.evaluateNewPassengerTrainTownConnection(circle, {  cityScoreWeights = cityScoreWeights, townSearchDistance = townSearchDistance, minDist = minDist })
			if not result then 
				currentBuildParams = { status = _("No new passenger train connections were found") }
				if not aiEnableOptions.isDevelopOffsideComplete then 
					aiEnableOptions.isDevelopOffsideComplete = true 
					api.engine.forEachEntityWithComponent(function(town) addWork(function() constructionUtil.developStationOffside({town=town})end)end, api.type.ComponentType.TOWN)
				end 
				return				
			end 
			
			result.isAutoBuildMode = true
		end
		connectTowns( {result}, 1)
	end)
end



local function buildTrainPanel() 
	trace("in buildStraightenPanel")
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local resultView = api.gui.comp.TextView.new(" ")
	trace("built boxlayout, resultview")
	local lastResults = {}


local function addSlider(text, params, callback, textFormat) 
		local slider = api.gui.comp.Slider.new(true)
		local textview =  api.gui.comp.TextView.new(text)
		slider:setMinimum(params.minVal)
		slider:setMaximum(params.maxVal)
		slider:setStep(1)
		slider:setPageStep(1)
		slider:onValueChanged(function() 
			textview:setText(textFormat(slider:getValue()))
			callback(slider:getValue())
		end)
		slider:setValue(params.curVal and params.curVal or 5,true)
		local size = slider:calcMinimumSize()
		size.w = size.w+120
		slider:setMinimumSize(size)
		local sliderlayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
		sliderlayout:addItem(api.gui.comp.TextView.new(text))
		sliderlayout:addItem(slider)
		sliderlayout:addItem(textview)
		
		boxlayout:addItem(sliderlayout)
		return sliderlayout
	end

	local buttonGroup, standard, elevated, underground = util.createElevationButtonGroup(true) 
	local topLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	
	local routeScoringChooser = paramHelper.buildRouteScoringChooser(true, false)
	topLayout:addItem(routeScoringChooser.button)
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, false)
	topLayout:addItem(paramOverridesChooser.button)
	topLayout:addItem(api.gui.comp.Component.new("VerticalLine"))
	topLayout:addItem(api.gui.comp.TextView.new(_("Elevation:")))
	topLayout:addItem(buttonGroup)
	local choicesComp = {
		comp = topLayout,
		getChoices = function() 
			local choices = {}
			-- TODO 
			return choices 
		end 
	}
	--boxlayout:addItem(buttonGroup) 
	local townChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local function buildTownResultFn(result) 
		addWork(function()
			trace("About to send command to build town result")
			result.isElevated = elevated:isSelected()
			result.isUnderground = underground:isSelected()
			result.customRouteScoring = routeScoringChooser.customRouteScoring
			result.paramOverrides = paramOverridesChooser.customOptions
			if util.tracelog then debugPrint({result=result}) end
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewPassengerTrainConnections", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
		end)
	end
	local townChoicesPanel , townChoicesMapListener
	local function populateTownChoices() 
		if townChoicesPlaceHolder:getNumItems() > 0   then
			return 
--			townChoicesPlaceHolder:removeItem(townChoicesPanel)
		end
		townChoicesPanel, townChoicesMapListener = connectEval.buildTownChoicesPanel(circle, api.type.enum.Carrier.RAIL, buildTownResultFn, choicesComp)
		townChoicesPlaceHolder:addItem(townChoicesPanel)
	end
	boxlayout:addItem(townChoicesPlaceHolder) 
	
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	
	
	local buttonGroup, standard, elevated, underground = util.createElevationButtonGroup(false) 
	local topLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	
	local routeScoringChooser = paramHelper.buildRouteScoringChooser(true, true)
	topLayout:addItem(routeScoringChooser.button)
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, true)
	topLayout:addItem(paramOverridesChooser.button)
	topLayout:addItem(api.gui.comp.Component.new("VerticalLine"))
	topLayout:addItem(api.gui.comp.TextView.new(_("Elevation:")))
	topLayout:addItem(buttonGroup)
	--boxlayout:addItem(buttonGroup) 
	local function buildResultFn(result) 
		result.isElevated = elevated:isSelected()
		result.isUnderground = underground:isSelected()
		result.customRouteScoring = routeScoringChooser.customRouteScoring
		result.paramOverrides = paramOverridesChooser.customOptions
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildIndustryRailConnection", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
		end)
	end
	
	
	local industryChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local industryChoicesPanel, industryMapListener 
	local function populateIndustryChoices() 
		if industryChoicesPlaceHolder:getNumItems() > 0  then
			return
		--	industryChoicesPlaceHolder:removeItem(industryChoicesPanel)
		end
		industryChoicesPanel, industryMapListener  = connectEval.buildIndustryChoicesPanel(circle, api.type.enum.Carrier.RAIL, buildResultFn,topLayout)
		industryChoicesPlaceHolder:addItem(industryChoicesPanel)
	end
	boxlayout:addItem(industryChoicesPlaceHolder) 
 
	
	local comp= api.gui.comp.Component.new("AIBuildertrain")
	comp:setLayout(boxlayout)	
	local isInit = false
	local thisMapState  
	local thisIsMap
	return {
		comp = comp,
		title = util.textAndIcon("TRAIN", "ui/icons/construction-menu/category_tracks@2x.tga"),
		refresh = function()
			isInit = false
			 
		end,
		init = function() 
			if not isInit then 
				populateTownChoices() 
				populateIndustryChoices()
				townChoicesMapListener(thisIsMap, thisMapState)
				industryMapListener(thisIsMap, thisMapState)
				isInit = true
			end
		end,
		onToggleMap = function(isMap, mapState, isActivePanel) 
			if industryChoicesPanel and isActivePanel then 
				townChoicesMapListener(isMap, mapState)
				industryMapListener(isMap, mapState)
			end 
			thisMapState=mapState 
			thisIsMap = isMap
		end 
	}
end

local function doReload()
	trace("Do reload: begin. IsGuiThread?",isGuiThread)
	--for k, v in pairs(package.loaded) do 
	--	trace("Found k=",k,"v=",v)
	--end 
	local lineLastUpdateTime = lineManager.lineLastUpdateTime  
	local lineLastCheckedTime = lineManager.lineLastCheckedTime  
	package.loaded["ai_builder_base_util"]=nil
	package.loaded["ai_builder_new_connections_evaluation"]=nil
	package.loaded["ai_builder_base_param_helper"]=nil
	package.loaded["ai_builder_route_evaluation"]=nil
	package.loaded["ai_builder_line_manager"]=nil
	package.loaded["ai_builder_route_builder"]=nil
	package.loaded["ai_builder_construction_util"]=nil
	package.loaded["ai_builder_vehicle_util"]=nil
	package.loaded["ai_builder_town_panel"]=nil
	package.loaded["ai_builder_upgrades_panel"]=nil
	package.loaded["ai_builder_pathfinding_util"]=nil
	package.loaded["ai_builder_straighten_panel"]=nil
	package.loaded["ai_builder_minimap"]=nil
	package.loaded["ai_builder_station_template_helper"]=nil
	package.loaded["ai_builder_route_preparation"]=nil
	package.loaded["ai_builder_profiler"]=nil
	package.loaded["ai_builder_water_mesh_util"]=nil
	package.loaded["ai_builder_proposal_util"]=nil

	helper = require("ai_builder_station_template_helper")
	util = require("ai_builder_base_util")
	connectEval = require("ai_builder_new_connections_evaluation")
	paramHelper = require("ai_builder_base_param_helper")
	routeEvaluation = require("ai_builder_route_evaluation")
	lineManager = require("ai_builder_line_manager")
	routeBuilder = require("ai_builder_route_builder")
	constructionUtil = require("ai_builder_construction_util")
	vehicleUtil = require("ai_builder_vehicle_util")
	townPanel = require("ai_builder_town_panel")
	upgradesPanel = require("ai_builder_upgrades_panel")
	pathFindingUtil = require("ai_builder_pathfinding_util")
	straightenPanel = require("ai_builder_straighten_panel")
	minimap = require("ai_builder_minimap")
	profiler = require("ai_builder_profiler")
	waterMeshUtil = require "ai_builder_water_mesh_util"
	proposalUtil = require "ai_builder_proposal_util"
	
	initContext = util.initContext
	lineManager.standardCallback = standardCallback
	constructionUtil.standardCallback = standardCallback
	routeBuilder.standardCallback = standardCallback
	lineManager.addWork = addWork
	lineManager.addDelayedWork = addDelayedWork
	lineManager.addBackgroundWork = addBackgroundWork
	lineManager.executeImmediateWork = executeImmediateWork
	function lineManager.getActivityLog()
		return activityLog
	end 
	proposalUtil.addWork = addWork
	proposalUtil.addDelayedWork=addDelayedWork
	proposalUtil.err = err
	proposalUtil.executeImmediateWork = executeImmediateWork
	constructionUtil.addWork = addWork
	constructionUtil.addDelayedWork=addDelayedWork
	constructionUtil.err = err
	constructionUtil.executeImmediateWork = executeImmediateWork
	constructionUtil.addWorkWhenAllIsFinished = addWorkWhenAllIsFinished
	routeBuilder.addWork = addWork
	routeBuilder.addDelayedWork = addDelayedWork
	routeBuilder.lineManager = lineManager
	routeBuilder.constructionUtil=constructionUtil
	routeBuilder.err = err 
	routeBuilder.executeImmediateWork = executeImmediateWork
	vehicleUtil.addWork = addWork
	connectEval.addWork = addWork
	connectEval.setGuiEventListener = setGuiEventListener
	townPanel.addWork = addWork
	townPanel.addDelayedWork = addDelayedWork
	upgradesPanel.addWork = addWork
	upgradesPanel.addDelayedWork = addDelayedWork
	upgradesPanel.standardCallback = standardCallback
	connectEval.lineManager = lineManager
	minimap.addWork = addWork
	lineManager.getBackgoundWorkQueue = getBackgoundWorkQueue
	connectEval.getBackgoundWorkQueue = getBackgoundWorkQueue
	lineManager.lineLastUpdateTime = lineLastUpdateTime 
	lineManager.lineLastCheckedTime = lineLastCheckedTime
	if isGuiThread then 
		guiState.setupTabs()
	end 
	trace("Do reload: end")
end 

 
local function debugPanel() 
	local outerLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	outerLayout:addItem(boxlayout)
	local ignoreErrorsChbx =api.gui.comp.CheckBox.new(_("Ignore build validation"))
	

	ignoreErrorsChbx:onToggle(function(v)
		ignoreErrors = v
	end)
	boxlayout:addItem(ignoreErrorsChbx)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local jumplayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	local textInput = api.gui.comp.TextInputField.new( "Entity")
	local jumpButton  = newButton(_('Jump to entity'))
	jumplayout:addItem(textInput)
	jumplayout:addItem(jumpButton)
	boxlayout:addItem(jumplayout)
	jumpButton:onClick(function() 
		xpcall(function()
			local text = textInput:getText()
			--print("ABout to jump to entity ",text)
			api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(tonumber(text), false)
		end, err)
	end)
	
	
	
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local rightLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	outerLayout:addItem(rightLayout)
	local textInput = api.gui.comp.TextInputField.new( "ALL")
	-- textInput:setText()
	boxlayout:addItem(textInput)
	local checkIncludeData = api.gui.comp.CheckBox.new(_("Include data"))
	boxlayout:addItem(checkIncludeData)
	local button  = newButton(_('Dump entity data to console'))
	boxlayout:addItem(button)
	button:onClick(function() 
		xpcall(function()
		print("about to call getEntities for type=",textInput:getText()," includeData=",checkIncludeData:isSelected() ," radius = ", circle.radius, "position =", circle.pos[1], circle.pos[2])
		local filter = {includeData = checkIncludeData:isSelected()}
		local text = textInput:getText()
		if text and text~="" and text~="ALL" then
			filter.type = text
		end
		local entities = game.interface.getEntities(circle,filter)
		print("Number of entities found? ",util.size(entities))
		debugPrint(entities)
		end, err)
		
	end)
	local button2  = newButton(_('Dump BASE_EDGE data to console'))
	boxlayout:addItem(button2)
	button2:onClick(function() 
		xpcall(function()
		print("about to call getEntities for type=",textInput:getText()," includeData=",checkIncludeData:isSelected() ," radius = ", circle.radius, "position =", circle.pos[1], circle.pos[2])
		local filter = {type="BASE_EDGE" , includeData = true}
		 
		local entities = game.interface.getEntities(circle,filter)
		print("Number of entities found? ",util.size(entities))
		for edgeId, edge in pairs(entities) do 
			local tangent0 =util.v3fromArr(edge.node0tangent)
			local tangent1 =util.v3fromArr(edge.node1tangent)
			print("EdgeId=",edgeId, " isTrack?",edge.track," nodes:",edge.node0,edge.node1," tangentLengths=",vec3.length(tangent0),vec3.length(tangent1), "Angle between",math.deg(util.signedAngle(tangent0, tangent1))," dist between nodes = ",util.distBetweenNodes(edge.node0,edge.node1)," positions:", edge.node0pos[1],edge.node0pos[2], " - ",edge.node1pos[1],edge.node1pos[2]," type=",util.getEdge(edgeId).type, " grad=",(edge.node1pos[3]-edge.node0pos[3])/vec2.distance(util.nodePos(edge.node0), util.nodePos(edge.node1)))
		end 
		end, err)
	end)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local workItemsDisplay = api.gui.comp.TextView.new( "Work items= "..#workItems)
	
	local workCompleteDisplay = api.gui.comp.TextView.new( "Work complete flag= "..tostring(workComplete))
	local needsUpdateDisplay = api.gui.comp.TextView.new( "Needs update flag= "..tostring(needsupdate))
	local button2  = newButton(_('Refresh'))
	boxlayout:addItem(workItemsDisplay)
	boxlayout:addItem(workCompleteDisplay)
	boxlayout:addItem(needsUpdateDisplay)
	local function refreshDisplays()
		workItemsDisplay:setText("Work items= "..#workItems, false)
		workCompleteDisplay:setText( "Work complete flag= "..tostring(workComplete), false)
		needsUpdateDisplay:setText( "Needs update flag= "..tostring(needsupdate), false)
	end
	button2:onClick(refreshDisplays)
	boxlayout:addItem(button2)
	local button3  = newButton(_('Print mod params'))
	boxlayout:addItem(button3)
	button3:onClick(function()
		addWork(function()
			print(getCurrentModId())
			
		end)
		refreshDisplays()
	end)
	
	local buttonUpgradeBusiestLines = newButton(_('Upgrade busiest lines'))
	buttonUpgradeBusiestLines:onClick(function()
		addWork(function() api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","upgradeBusiestLines", "", { }), standardCallback) end)
	end)
	boxlayout:addItem(buttonUpgradeBusiestLines)
	
	local buttonUpgradeBusiestRoadLines = newButton(_('Upgrade busiest road lines'))
	buttonUpgradeBusiestRoadLines:onClick(function()
		addWork(function() api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","upgradeBusiestRoadLines", "", { }), standardCallback) end)
	end)
	boxlayout:addItem(buttonUpgradeBusiestRoadLines)
	
	local button4  = newButton(_('Clear errors'))
	boxlayout:addItem(button4)
	button4:onClick(function() 
		errorPanel:setText(" ", false)
	end)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local showGuiEventsChkBx = api.gui.comp.CheckBox.new(_("Show gui events"))
	boxlayout:addItem(showGuiEventsChkBx)
	showGuiEventsChkBx:onToggle(function(v)
		isShowGuiEvents = v
	end)
	
	local showEventsChkBx = api.gui.comp.CheckBox.new(_("Show   events"))
	boxlayout:addItem(showEventsChkBx)
	showEventsChkBx:onToggle(function(v)
		addWork(function() api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","showEvents", "", {isShowEvents=v }), standardCallback) end)
	end)
	local forceDeparturesChkBx = api.gui.comp.CheckBox.new(_("Force immediate departures?"))
	boxlayout:addItem(forceDeparturesChkBx)
	forceDeparturesChkBx:onToggle(function(v)
		addWork(function() api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","forceDepartures", "", {isForceImmediateDepartures=v }), standardCallback) end)
	end)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local textInput2 = api.gui.comp.TextInputField.new( "RESOLUTION")
	boxlayout:addItem(textInput2)
	local button5  = newButton(_('Print water mesh entities'))
	local function getRiverMeshes()
			local resolution = tonumber(textInput2:getText())
			if not resolution then
				print("resolution not specified")
				resolution = 256
			end
			local position = circle.pos
			local range = circle.radius == math.huge and util.getMapBoundary().x or circle.radius
			local xLow= math.floor((position[1]-range)/resolution)
			local xHigh = math.ceil((position[1]+range)/resolution)
			local yLow = math.floor((position[2]-range)/resolution)
			local yHigh = math.ceil((position[2]+range)/resolution)
			local tile0 = api.type.Vec2i.new(xLow, yLow)
			local tile1 = api.type.Vec2i.new(xHigh, yHigh)
			debugPrint({tile0=tile0, tile1=tile1})
			return api.engine.system.riverSystem.getWaterMeshEntities(tile0,tile1)
	end
	button5:onClick(function()
		addWork(function() 
	
			debugPrint({ riverMesh=getRiverMeshes()})
		end)
	end)
	boxlayout:addItem(button5)
	local runConstructionTest = newButton(_('Run construction test'))
	runConstructionTest:onClick(function() 
		addWork(constructionUtil.runConstructionTest)
	end )
	boxlayout:addItem(runConstructionTest)
	local createOutFile = newButton(_('Create out file'))
	createOutFile:onClick(function() 
		addWork(util.createOutFile)
	end )
	boxlayout:addItem(createOutFile)
	local displayWaterMeshGroups  = newButton(_('Display water mesh groups'))
	displayWaterMeshGroups:onClick(function() 
		addWork(waterMeshUtil.displayWaterMeshGroups)
	end)
	boxlayout:addItem(displayWaterMeshGroups)
	
	local displayContourGroups  = newButton(_('Display water contour groups'))
	displayContourGroups:onClick(function() 
		addWork(waterMeshUtil.displayWaterContourGroups)
	end)
	boxlayout:addItem(displayContourGroups)
	
	local buildConstructionButton =  newButton(_("Build Interchange"))
	buildConstructionButton:onClick(function() 
		addWork(function()
			local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
			newConstruction.fileName = "VanillaRoundaboutInterchange_TB.con"
			local p = vec3.new(0,0,10)
			local r = 0
			newConstruction.transf = util.transf2Mat4f(transf.rotZTransl(r, p))
			local streetutil2 = require "vanilla_road_interchange_util_TB"
			local params = 	streetutil2.defaultParams()
		
			params.seed = 0 
			params.juncount = 2
				params.useSmallHighways = true
			params.grad = 0.05
			newConstruction.params = params
			
			
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToAdd[1]= newConstruction
			local context = util.initContext()
			context.cleanupStreetGraph = false
			local build = api.cmd.make.buildProposal(newProposal, context , true)
			
			local nodesToAdd = build.proposal.proposal.addedNodes
			local edgesToAdd = build.proposal.proposal.addedSegments
			local edgeObjectsToAdd = {}
			local diagnose = true 
			--local newProposal =  routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
			api.cmd.sendCommand(build, function(res , success) 
				trace("Attempt to build construction was",success)
			end)
		end)
	end)
	
	boxlayout:addItem(buildConstructionButton)
	
	
	local setPositionLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local setPositionButton = newButton(_("Set position"))
	setPositionLayout:addItem(setPositionButton)
	local xInput = api.gui.comp.TextInputField.new("0")
	setPositionLayout:addItem(xInput)
	local yInput = api.gui.comp.TextInputField.new("0")
	setPositionLayout:addItem(yInput)
	boxlayout:addItem(setPositionLayout)
	setPositionButton:onClick(function() 
		addWork(function() 
			local x = tonumber(xInput:getText())
			local y = tonumber(yInput:getText())
			--TODO
			local height = 200
			local angle = 0 
			local pitch = math.pi/2
			api.gui.util.getGameUI():getMainRendererComponent():getCameraController():setCameraData(api.type.Vec2f.new(x,y), height, angle, pitch)
		end)
	end)
	local drawRiverLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local drawRiverButton = newButton(_("Draw water mesh"))
	drawRiverLayout:addItem(drawRiverButton)
	local entityInput = api.gui.comp.TextInputField.new("0")
	drawRiverLayout:addItem(entityInput)
	local drawRiverClearButton = newButton(_("Clear"))
	drawRiverLayout:addItem(drawRiverClearButton)
	local includeContoursChbox = api.gui.comp.CheckBox.new(_("Include contours?"))
	local includeverticiesChbox = api.gui.comp.CheckBox.new(_("Include verticies?"))
	includeContoursChbox:setSelected(true, true)
	includeverticiesChbox:setSelected(true, true)
	drawRiverLayout:addItem(includeContoursChbox)
	drawRiverLayout:addItem(includeverticiesChbox)
	local waterMeshDrawn = {}
	local function clearWaterMesh() 
		for i, waterMesh in pairs(waterMeshDrawn) do 
			game.interface.setZone(waterMesh)
		end
		waterMeshDrawn={}
		addWork(waterMeshUtil.clearDisplays)
	end 
	drawRiverClearButton:onClick(clearWaterMesh)
	rightLayout:addItem(drawRiverLayout)
	drawRiverButton:onClick(function() 
		addWork(function() 
			local x 
			local y 
			local meshesToDraw
			if entityInput:getText() ~= "" then 
				pcall(function() meshesToDraw = { tonumber(entityInput:getText()) }end)
			end 
			if not meshesToDraw then 
				meshesToDraw = getRiverMeshes()
				clearWaterMesh()
			end
			trace("There were ",#meshesToDraw,"meshes")
			for i, meshId in pairs(meshesToDraw) do 
				local waterMesh = api.engine.getComponent(meshId, api.type.ComponentType.WATER_MESH)
				
				local polygon2 = {}
				if includeContoursChbox:isSelected() then 
					for j, contour in pairs(waterMesh.contours) do
						local polygon = {}
						for k, point in pairs(contour.vertices) do 
							--local v2point = vec3.new(point.x, point.y,0)
							
								table.insert(polygon, { point.x, point.y})
							   
						end
						local name = "ai_builder_river_mesh"..tostring(#waterMeshDrawn)
						table.insert(waterMeshDrawn, name)
						local colourIdx = 1 + math.floor(#waterMeshDrawn/2) % #game.config.gui.lineColors
						--trace("Colouridx=",colourIdx)
						local colour = game.config.gui.lineColors[colourIdx]
						--local drawColour = { colour[1]*255, colour[2]*255, colour[3]*255, 1} 
						local drawColour = { colour[1], colour[2], colour[3], 1} 
						game.interface.setZone(name, {
							polygon=polygon,
							draw=true,
							drawColor = drawColour,
						})
					end
				end
				
				for j, point in pairs(waterMesh.vertices) do
				 
						--local v2point = vec3.new(point.x, point.y,0)
						if not x then 
							x = point.x 
							y = point.y
						end
						if includeverticiesChbox:isSelected() then 
							table.insert(polygon2, { point.x, point.y})
						end
					 
				end
			print("Water mesh at",waterMesh.pos.x,waterMesh.pos.y, " for mesh",meshId)
			local colourIdx = 1 + math.floor(#waterMeshDrawn/2) % #game.config.gui.lineColors
						--trace("Colouridx=",colourIdx)
			local colour = game.config.gui.lineColors[colourIdx]
						--local drawColour = { colour[1]*255, colour[2]*255, colour[3]*255, 1} 
			local drawColour = { colour[1], colour[2], colour[3], 1} 
			local name = "ai_builder_river_mesh"..tostring(#waterMeshDrawn)
			drawColour[4] = 0.5
			table.insert(waterMeshDrawn, name)
			game.interface.setZone(name, {
				polygon=polygon2,
				draw=true,
				drawColor = drawColour,
			})

		end
		if x then 
			local height = api.gui.util.getGameUI():getMainRendererComponent():getCameraController():getCameraData().z
			local angle = 0 
			local pitch = math.pi/2
			--api.gui.util.getGameUI():getMainRendererComponent():getCameraController():setCameraData(api.type.Vec2f.new(x,y), height, angle, pitch)
		end
		end)
	end)
	rightLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
		local button7 = newButton(_("Show vehicle lines to names"))
	button7:onClick(function() 
		for i, lineId in pairs( api.engine.system.lineSystem.getLines()) do 
			print(lineId, api.engine.getComponent(lineId, api.type.ComponentType.NAME).name)
		end
	
	end)
	
	
	rightLayout:addItem(button7)
	
	rightLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local button6 = newButton(_("Enable auto build"))
	button6:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","enableAutoBuild", "", {ignoreErrors=ignoreErrors, enableAutoBuild=true}), standardCallback)
		end)
	
	end)
	rightLayout:addItem(button6)
	local button7 = newButton(_("Disable auto build"))
	button7:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","enableAutoBuild", "", {ignoreErrors=ignoreErrors, enableAutoBuild=true}), standardCallback)
		end)
	
	end)
	
	
	rightLayout:addItem(button7)
 	local entitiesLayout  = api.gui.layout.BoxLayout.new("HORIZONTAL")
 	local printEntities = newButton(_("PrintEntities"))
	entitiesLayout:addItem(printEntities)
	local entityTextInput = api.gui.comp.TextInputField.new("") 
	entitiesLayout:addItem(entityTextInput)
	printEntities:onClick(function() 
		addWork(function() 
			local componentsLookup = getmetatable(api.type.ComponentType).__index
			local component = componentsLookup[entityTextInput:getText()]
			if not component then 
				print("Unrecongnised Entity")
			else 
				api.engine.forEachEntityWithComponent(function(entity) print(entity) end, component)
			end 
		end)
	end)
	
	rightLayout:addItem(entitiesLayout)

	
	local button8 = newButton(_("Check for invalid"))
	button8:onClick(function() 
		addWork(function()
			local begin = os.clock()
			local count = 0
			local smallStreetType = api.res.streetTypeRep.find("standard/town_small_new.lua")
			util.lazyCacheNode2SegMaps()
			api.engine.forEachEntityWithComponent(function(edgeId)
				count = count + 1
				local edge = util.getEdge(edgeId) 
				local naturalTangent = util.vecBetweenNodes(edge.node1, edge.node0)
				local angle1 = math.abs(util.signedAngle(naturalTangent, edge.tangent0))
				local angle2 = math.abs(util.signedAngle(naturalTangent, edge.tangent1))
				local angle3 = math.abs(util.signedAngle(edge.tangent0, edge.tangent1))
				local shouldSuppress = util.getTrackEdge(edgeId) 
				local streetEdge = util.getStreetEdge(edgeId) 
				if streetEdge and streetEdge.streetType == smallStreetType and edge.type == 2 then 
					shouldSuppress = true 
				end
				if not shouldSuppress then 
					if  angle1> math.rad(80) or angle2 > math.rad(80) or angle3 > math.rad(80) then 
						trace("Potentially invalid tangent at edge",edgeId," angle1=",math.deg(angle1), " angle2=",math.deg(angle2),"angle3=",math.deg(angle3))
					end
					local length  = util.calculateSegmentLengthFromEdge(edge)
					local dist = vec3.length(naturalTangent)
					if length > 1.2*dist or length < 0.9*dist or length < 1 or dist < 1 then 
						trace("Potentially invalid tangent at edge",edgeId," length=",length, " dist=",dist," angle1=",math.deg(angle1), " angle2=",math.deg(angle2))
					end 
				end
			end, api.type.ComponentType.BASE_EDGE) 
			api.engine.forEachEntityWithComponent(function(node)
				if #util.getSegmentsForNode(node) > 4 then 
					trace("Found a node",node," with more than 4 segments:",#util.getSegmentsForNode(node))
				end 
			end, api.type.ComponentType.BASE_NODE) 
			util.checkForInvalidNodes()
			util.clearCacheNode2SegMaps()
			trace("Checked ",count," edges, time taken:",(os.clock()-begin))
		end)
	
	end)
	rightLayout:addItem(button8)
	local printMemButton = util.newButton("Print luaUsedMemory")
	printMemButton:onClick(function() 
		print("luaUsedMemory (from immediate click):",math.floor(api.util.getLuaUsedMemory()/1024/1024).."MB")
		addWork(function() 
			print("luaUsedMemory (from ui callback):",math.floor(api.util.getLuaUsedMemory()/1024/1024).."MB")
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","printLuaUsedMemory", "", {}))
		end)
	end) 
	rightLayout:addItem(printMemButton)
	local testButton = util.newButton("Run th cache test")
	testButton:onClick(function() 
		print("Adding work for th test")
		addWork(function() 
			print("Begin th cache test")
			local mapBoundary = util.getMapBoundary()
			local count = 0
			local testCache = {}
			local increment = 8
			 for x = -mapBoundary.x, mapBoundary.x, increment do 
				--print("Caching values along x=",x)
				for y = -mapBoundary.y, mapBoundary.y, increment do 
					local p = vec3.new(x,y,0)
					testCache[util.pointHash2d(p)]=util.th(p)
				end 
			end 
			print("Setup cache, now test results")
			for x = -mapBoundary.x, mapBoundary.x, increment do 
				for y = -mapBoundary.y, mapBoundary.y, increment do 
					local p = vec3.new(x,y,0)
					local expected = util.th(p)
					local actual = testCache[util.pointHash2d(p)]
					assert(expected==actual, " at point "..x..","..y.." expected "..expected.." but was "..actual)
					count = count + 1
				end 
			end  
			print("tested ",count," points")
		end)
	end)
	
	
	rightLayout:addItem(testButton)
	local turboChargeChkbox = api.gui.comp.CheckBox.new("Turbocharge?")
	rightLayout:addItem(turboChargeChkbox)
	local targetSpeed = 16 
	local function checkAndUpdateGameSpeed() 
		if not turboChargeChkbox:isSelected() then 
			return 
		end
		local gameSpeed =  game.interface.getGameSpeed()
		if gameSpeed < targetSpeed then 
			--trace("Found gameSpeed < targetSpeed, sending command",gameSpeed)
			api.cmd.sendCommand(api.cmd.make.setGameSpeed(targetSpeed)) --, function (res, success) trace("Result of change game speed was",success)end)
		end 
	end 
	local textInput = api.gui.comp.TextInputField.new("4")
	rightLayout:addItem(textInput)
	local connection 
	turboChargeChkbox:onToggle(function(selected) 
		isTurboChargeMode = selected
		if not pcall(function() 
			targetGameSpeed = tonumber(textInput:getText())
		end)
		then 
			if game.interface.getGameSpeed() > 1 then 
				targetGameSpeed = game.interface.getGameSpeed()
			else 
				targetGameSpeed = nil 
			end 
		end
		trace("Set the targetGameSpeed to ",targetGameSpeed)
		--[[if selected then 
			 connection = turboChargeChkbox:onStep(checkAndUpdateGameSpeed)
		else 
			if connection then 
				connection:disconnect() 
				connection = nil 
			end
		end	]]--	
	end)
	local runCleanUpTest = util.newButton("Run cleanup test")
	rightLayout:addItem(runCleanUpTest)
	runCleanUpTest:onClick(function() 
		addWork(function()
			if circle.radius == math.huge then 
				trace("Suppressed cleanup test - need circle first") 
			else 
				api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","runCleanUpTest", "", circle), standardCallback)
			end
		end)
	end)
	local reload = util.newButton("Reload Engine Thread")
	rightLayout:addItem(reload)
	reload:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","reload", "", {}), standardCallback)
		end)
	end)
	local reloadGui = util.newButton("Reload Gui")
	rightLayout:addItem(reloadGui)
	reloadGui:onClick(function() 
		addWork(doReload)
	end)
	local clearWork = util.newButton("clearWork")
	rightLayout:addItem(clearWork)
	clearWork:onClick(function() 
		addWork(function()
			 
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","clearWork", "", {}), standardCallback)
		 
		end)
	end)
	local checkNoPath = util.newButton("Check no path vehicles")
	checkNoPath:onClick(function() 		addWork(lineManager.checkNoPathVehicles) end)
	
	rightLayout:addItem(checkNoPath)
	local testButton = util.newButton("Check map boundary")
	testButton:onClick(function() addWork(function() 
			local vec2f = api.type.Vec2f.new(0,0)
			for i = 0, 50000 do 
				vec2f.x = i
				if not api.engine.terrain.isValidCoordinate(vec2f) then 
					trace("Found x boundary at ",(i-1)) 
					break 
				end 	
			end
			vec2f.x =0 
			for i = 0, 50000 do 
				vec2f.y = i
				if not api.engine.terrain.isValidCoordinate(vec2f) then 
					trace("Found y boundary at ",(i-1))
					break					
				end 	
			end
			vec2f.y =0 
			for i = 0, 50000, 256 do 
				vec2f.x = i
				if not api.engine.terrain.isValidCoordinate(vec2f) then 
					trace("Alternative method: Found x boundary at ",(i-256)) 
					break 
				end 	
			end
		end)
	end)
	rightLayout:addItem(testButton)
	local existingVertexPoints = {}
	local drawVerticiesLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local vertexZone = "ai_builder_verticies_zone"
	local drawVerticiesButton = util.newButton("Draw vertex")
	drawVerticiesLayout:addItem(drawVerticiesButton)
	local xText = api.gui.comp.TextInputField.new("x")
	local yText = api.gui.comp.TextInputField.new("y")
	local clearVerticeisButton = util.newButton("Clear")
	
	drawVerticiesButton:onClick(function() 
		addWork(function() 
			local x = tonumber(xText:getText())
			local y = tonumber(yText:getText())
			table.insert(existingVertexPoints, { x, y })
			xText:setText("", false)
			yText:setText("", false)
			local drawColour = { 1, 1, 1, 1} 
			game.interface.setZone(vertexZone, {
				polygon=existingVertexPoints,
				draw=true,
				drawColor = drawColour,
			})
		end)	
	end)
	
	drawVerticiesLayout:addItem(xText)
	drawVerticiesLayout:addItem(yText)
	drawVerticiesLayout:addItem(clearVerticeisButton)
	clearVerticeisButton:onClick(function() 
		game.interface.setZone(vertexZone)
		existingVertexPoints = {}
	end)
	
	rightLayout:addItem(drawVerticiesLayout)
	
	local countComponentsButton = util.newButton("Count components")
	countComponentsButton:onClick(function() 
		addWork(function() 
			local function countComponents(item) 
				local total = 1
				local layout  = item
				local res = pcall( function()
					layout = item:getLayout()
				end)
				local res = pcall(function() 
					for i = 0, layout:getNumItems()- 1 do 
						total = total + countComponents(layout:getItem(i)) 
					end 
				end)
				
				if not res then 
					trace("Unable to determine for item:",item)
					debugPrint(item) 
				end
				return total 
			end 
			print("Component count:",countComponents(api.gui.util.getGameUI():getMainRendererComponent()))
		end)
	end)
	rightLayout:addItem(countComponentsButton)
	local guiState = { circles = {}}
	local function addCircle(name, circle, colour)
		game.interface.setZone(name, {
			polygon=zoneutil.makeCircleZone(circle.pos , circle.radius, 16),
			draw=true,
			drawColor = colour,
		})
		if not guiState.circles[name] then 
			guiState.circles[name]=circle 
		end
	end 
	local function updateCircle() 
		guiState.hasCircle = true
		local pos = game.gui.getTerrainPos()
		if not pos then 
			--trace("No position found")
			return  
		end
		local circles = guiState.circles
		if not circles["mouse"] then 
			circles["mouse"]={}
		end
		local view = game.gui.getTerrainPos()
		local circle = circles["mouse"]
		
		
		circle.pos = pos
		circle.radius = 10
		local colour = {128,128,128,0.5} -- transparent white
		local node =util.searchForClosestDeadEndStreetOrTrackNode( circle.pos , circle.radius )
		guiState.node = node
		if node then 
			local nodePos = util.nodePos(node)
			circle.pos[1]=nodePos.x
			circle.pos[2]=nodePos.y 
			colour = {0,128,0,0.5} 
			--debugPrint(circle) 
		end 
		addCircle("mouse", circle, colour)

	end

	local function removeCircle(name)
		game.interface.setZone(name, nil)
		guiState.circles[name]=nil
	end 
	local function showWindow()
		local mainView = game.gui.getContentRect("mainView")
		local window = guiState.window
		local y = math.floor(mainView[4]*(1/3)) 
		local x = math.floor(mainView[3]/2) 
		--window.window:setMaximumSize(api.gui.util.Size.new(math.floor(0.9*mainView[3]), math.floor(0.9*mainView[4])))
		window.window:setPosition(x,y)
		window.window:setVisible(true,false)
		window.refresh()

	end
	local mouseListener = function(MouseEvent) 
	xpcall(
		function() 
			if guiState.isActive and guiState.node and MouseEvent.type == 2 and MouseEvent.button == 0 then 
				trace("Processing mouseEvent")
				local colour = {0,255,0,1} 
				local circle = guiState.circles["mouse"]
				if guiState.node == guiState.node0 then 
					removeCircle("node0")
					guiState.node0 = nil
					return true
				elseif guiState.node == guiState.node1 then 
					removeCircle("node1")
					guiState.node1 = nil
					return true
				elseif not guiState.node0 then 
					addCircle("node0", circle, colour)
					guiState.node0 = guiState.node
					return true				
				elseif not guiState.node1 then 
					addCircle("node1", circle, colour)
					guiState.node1 = guiState.node 
					showWindow()
					return true
				end 
			end
		end,
		err)
		return false
	end
 
	local function removeCircles() 
		for k, v in pairs(guiState.circles) do 
			removeCircle(k)
		end 
		guiState.node1 = nil
		guiState.node0 = nil
		guiState.node = nil
	end
	local function buildWindow(button)
		
		trace("Building window")
		local toplayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	 
		

		local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
		
		
		boxlayout:addItem(toplayout)
	 
	 
		local buttonGroup, standard, elevated, underground = util.createElevationButtonGroup(true) 
		boxlayout:addItem(buttonGroup)
		local midlayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
		local routeScoringChooser = paramHelper.buildRouteScoringChooser(true, isCargo)
		midlayout:addItem(routeScoringChooser.button)
		local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, isCargo)
		midlayout:addItem(paramOverridesChooser.button)
		local drawRouteCheckbox = api.gui.comp.CheckBox.new(_("Draw routes?"))
		
		midlayout:addItem(drawRouteCheckbox)
		local drawBaseRouteOnly = api.gui.comp.CheckBox.new(_("Draw base route only?"))
		midlayout:addItem(drawBaseRouteOnly)
		local doubleTrack = api.gui.comp.CheckBox.new(_("Double Track?"))
		midlayout:addItem(doubleTrack)
		boxlayout:addItem(midlayout)
		
		--local highSpeedTrack =api.gui.comp.CheckBox.new(_("High speed track?"))
		--local highSpeedTrack =api.gui.comp.CheckBox.new(_("High speed track?"))
		
		local bottomPanel =  api.gui.layout.BoxLayout.new("VERTICAL");
		local cancelButton = util.newButton("","ui/button/small/cancel@2x.tga")
		local acceptButton = util.newButton("","ui/button/small/accept@2x.tga")
		local refreshButton = util.newButton("","ui/button/xxsmall/replace@2x.tga")
		acceptButton:onClick(function() addWork(function() 
				trace("ai_builder_script: adding work for build between nodes")
				local params = {}
				params.node0 = guiState.node0 
				params.node1 = guiState.node1
				local paramOverrides = paramOverridesChooser.customOptions
				if not paramOverrides then 
					paramOverrides = {}
				end
				paramOverrides.isElevated = elevated:isSelected()
				paramOverrides.isUnderground = underground:isSelected()
				paramOverrides.routeScoreWeighting = routeScoringChooser.customRouteScoring
				paramOverrides.isDoubleTrack = doubleTrack:isSelected()
				params.paramOverrides = paramOverrides
				params.ignoreErrors = true
				params.ignoreErrorsOverridden = true 
				params.drawRoutes = drawRouteCheckbox:isSelected() or drawBaseRouteOnly:isSelected()
				params.drawBaseRouteOnly = drawBaseRouteOnly:isSelected()
				api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","doBuild", "", params), standardCallback)
				acceptButton:setEnabled(false, false)
				removeCircles() 
				commandSentTime = os.clock()
				end)
			end)
			--local refreshButton = newButton(textAndIcon("Refresh","ui/button/xxsmall/replace@2x.tga"))
			--refreshButton:onClick(function() 
			--	addWork(refreshTable)
			--end)
			local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL");
			buttonPanel:addItem(acceptButton)
			buttonPanel:addItem(refreshButton)
			refreshButton:onClick(function() 
				guiState.node = nil 
				guiState.node0 = nil 
				guiState.node1 = nil
				acceptButton:setEnabled(true, false)
				util.clearCacheNode2SegMaps()
			end)
			 buttonPanel:addItem(cancelButton)
			 bottomPanel:addItem(buttonPanel)
			 statusPanel3 = api.gui.comp.TextView.new(" ")
			 buttonPanel:addItem(statusPanel3)
			--bottomPanel:addItem(statusPanel) 
			boxlayout:addItem(bottomPanel)
			
			local window = api.gui.comp.Window.new(_('AI Builder Lite Test'), boxlayout)
			cancelButton:onClick(function() window:close() end)
			 window:addHideOnCloseHandler()
			 window:onClose(function() 
				xpcall(function() 
					removeCircles()
					guiState.isActive = false
					 button:setSelected(false, false)
					end
				,err 
				)
			 end)
		 window:setResizable(true)
		return {
			window = window,
			refresh = function() 
				updateCircle() 
				acceptButton:setEnabled(true, false)
				 
			end
		}
	end
	
	local icon = api.gui.comp.ImageView.new("ui/ai_button.tga")
	 	-- local icon = api.gui.comp.ImageView.new("ui/button/small/bulldoze@2x.tga")
		 -- local icon = api.gui.comp.ImageView.new("ui/icons/game-menu/bulldozer@2x.tga")
		 trace("About to get layout")
    local layout = rightLayout
   --icon:setName("LayerToggleButton")
   --icon:addStyleClass("LayerToggleButton::Icon")
	trace("Got layout")
   icon:setMaximumSize(api.gui.util.Size.new(60,60))
    local button = api.gui.comp.ToggleButton.new(icon )
	button:setTooltip(_("AI Builder Lite"))
--	button:setId("BulldozerPlusPlusButton")
    button:setName("ConstructionMenuIndicator")
	--button:setMinimumSize(api.gui.util.Size.new(48,48))
--	 button:addStyleClass("BulldozerButton::Icon")
	-- button:addStyleClass( "LayerToggleButton::Icon")
    layout:addItem(button)
	  
    local window = buildWindow(button)
	window.window:setVisible(false,false)
	
	api.gui.util.getGameUI():getMainRendererComponent():insertMouseListener(mouseListener)
	trace("Added mouseListener")
	button:onToggle(function (b)
		guiState.isActive = b
		if b then 
			window.window:setVisible(true,false)
		else 
			window.window:close()
		end
    end)
	trace("Added onToggle")
    guiState.window = window
	window.window:onStep(function() 
		if guiState.isActive then 
			xpcall(updateCircle, err)
		end 
	end)
	trace("Added onstep")
	local comp= api.gui.comp.Component.new("AIBuilderdebug")
	comp:setLayout(outerLayout)
	trace("Set layout")
	return {
		comp = comp,
		title = api.gui.comp.TextView.new(_("Debug")),
		refresh = function()
 
		end,
		init = function() end
	}
end


local function doBuild(param)
	trace("ai_builder_script: received doBuild instruction, adding work")
	addWork(function() 
		trace("ai_builder_script: executing doBuild")
		profiler.reset()
		routeEvaluation.clearRoutes()
		util.clearCacheNode2SegMaps()
		local node0 = param.node0 
		local node1 = param.node1 
		util.lazyCacheNode2SegMaps() 
		local isTrack = #util.getTrackSegmentsForNode(node0) > 0
		local constructionId  = util.isNodeConnectedToFrozenEdge(node0) or util.isNodeConnectedToFrozenEdge(node1)
		local cargoType
		if constructionId then 
			local construction = util.getConstruction(constructionId)
			if construction.stations[1] then 
				if not util.getStation(construction.stations[1]).cargo then 
					cargoType = "PASSENGERS"
					trace("Marking the cargo type as passengers")
				end 
			end 
		end 
		local params = paramHelper.getDefaultRouteBuildingParams(cargoType, isTrack, param.ignoreErrors) 
		for k, v in pairs(param.paramOverrides) do 
			trace("Overriding",k," to ",v)
			params[k]=v
			if k =="stationLengthParam" then 
				params.stationLengthOverriden = true
				trace("Station length was overriden")
			end 
		end 
		if param.customRouteScoring then 
			params.routeScoreWeighting = param.customRouteScoring
		end
		params.drawRoutes = param.drawRoutes 
		params.drawBaseRouteOnly = param.drawBaseRouteOnly
		params.ignoreErrorsOverridden = param.ignoreErrorsOverridden
		local nodePair = { node0, node1 }
		if not params.isTrack  then 
			local edgeId = util.getStreetSegmentsForNode(node0)[1]
			trace("Getting the streetType category for ",edgeId)
			local category = util.getStreetTypeCategory(edgeId)
			local streetEdge = util.getStreetEdge(edgeId)
			local streetTypeName = api.res.streetTypeRep.getName(streetEdge.streetType)
			if category ~= "urban" then 
				params.preferredCountryRoadType = streetTypeName
			else 
				local testStreetType = string.gsub(streetTypeName,"town","country")
				if api.res.streetTypeRep.find(testStreetType) ~= -1 then 
					params.preferredCountryRoadType = testStreetType
				end 
			end 			
			local edgeId2 = util.getStreetSegmentsForNode(node1)[1]
			local streetEdge2 = util.getStreetEdge(edgeId2)
			if streetEdge.tramTrackType > 0 and streetEdge2.tramTrackType > 0 then 
				params.tramTrackType = math.max(streetEdge.tramTrackType, streetEdge2.tramTrackType)
			end 
			if category == "highway" then 
				local node0p = util.findParallelHighwayNode(node0, 50)
				local node1p = util.findParallelHighwayNode(node1, 50)
				 
				params.preferredHighwayRoadType = streetTypeName
				params.isHighway = node0p ~= nil and node1p ~= nil 
				if params.isHighway then 
					table.insert(nodePair, node0p)
					table.insert(nodePair, node1p)
				end 
			end 

			params.isDoubleTrack = params.isHighway
		end
		local function saveForUndo(res)
			addWork(function() 
		--		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("move_it_script.lua","saveForUndo", "", res), standardCallback)
				if undo_script then
					trace("Found undo script, attempting to save")
					undo_script.lastResult = res 
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_lite_script.lua","saveForUndo", "", {}), standardCallback)
					addPause()
				end
				
			end)
		end 
		currentBuildParams = { status2 = _("Building route").."." }
		local function callback(res, success) 
			profiler.printResults()
			if success then  
				--if undo_script then 
				--	pcall(function() undo_script.saveResultForUndo(res) end)
				--end 
				saveForUndo(res)
				--debugPrint(res)
				--trace("costs was",res.proposal.proposal.costs, " res.proposal.costs=",res.proposal.costs, " res.resultProposalData.costs=",res.resultProposalData.costs)
				--[[xpcall(function() 
					for k, v in pairs(res) do 
						trace("Res: k=",k," v=",v)
					end 
				end, err)
				xpcall(function() 
					for k, v in pairs(res.proposal) do 
						trace("Res.proposal: k=",k," v=",v)
					end
				end,err)
				debugPrint(res)--]]
				trace("About to mark as completed, currentBuildParams=",currentBuildParams)
				if currentBuildParams then 
					currentBuildParams.status2 = _("Completed")
					currentBuildParams.costs = res.resultProposalData.costs
				end
			else 
				if currentBuildParams then 
					currentBuildParams.status2 = _("Failed")
				end
			end
		end
		routeBuilder.buildRoute(nodePair, params, callback)
	
	end)

end

local function buildRoadCargoRoute(result, stations, hasEntranceB)
	local function debugLog(msg)
		local f = io.open("/tmp/tf2_build_debug.log", "a")
		if f then f:write(os.date("%H:%M:%S") .. " ROUTE: " .. msg .. "\n") f:close() end
	end
	debugLog("BEGIN - stations[1]=" .. tostring(stations[1]) .. " stations[2]=" .. tostring(stations[2]))
	table.insert(workItems,
		function()
			debugLog("Work function started")
			local ok, err = pcall(function()
			local cargoType = result.cargoType
			debugLog("cargoType=" .. tostring(cargoType))
			local isTrack = false
			local params = paramHelper.getDefaultRouteBuildingParams(cargoType, isTrack, ignoreErrors, result.distance)
			params.initialTargetLineRate = result.initialTargetLineRate
			if result.isAutoBuildMode and util.year() >= 1925 then
				params.preferredCountryRoadType="standard/country_medium_new.lua"
			end
			params.isPrimaryIndustry = result.isPrimaryIndustry
			trace("isPrimaryIndustry? ",params.isPrimaryIndustry)
			local alreadyCalled = false
			debugLog("Getting route info between stations...")
			local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(stations[1], stations[2])
			debugLog("routeInfo=" .. tostring(routeInfo ~= nil))
			if routeInfo then
				debugLog("routeInfo.exceedsRouteToDistLimitForTrucks=" .. tostring(routeInfo.exceedsRouteToDistLimitForTrucks))
				debugLog("routeInfo.routeLength=" .. tostring(routeInfo.routeLength))
			end
			trace("=== ROUTE INFO ===")
			trace("routeInfo exists: " .. tostring(routeInfo ~= nil))
			if routeInfo then
				trace("routeInfo.exceedsRouteToDistLimitForTrucks: " .. tostring(routeInfo.exceedsRouteToDistLimitForTrucks))
				trace("routeInfo.routeLength: " .. tostring(routeInfo.routeLength))
			end
			-- If caller pre-calculated route with needsNewRoute=false, trust it
			if result.needsNewRoute == false and result.route and #result.route > 0 then
				trace("Using pre-calculated route with " .. #result.route .. " edges, skipping new route")
				debugLog("Using pre-calculated route")
			else
				result.needsNewRoute = not routeInfo or routeInfo.exceedsRouteToDistLimitForTrucks
				trace("Recalculated needsNewRoute: " .. tostring(result.needsNewRoute))
				debugLog("needsNewRoute=" .. tostring(result.needsNewRoute))
			end
			local callBack = function(res, success)
					debugLog("Route callback: success=" .. tostring(success))
					if success or not result.needsNewRoute then
						pcall(function() markComplete()end)
						if not alreadyCalled then
							debugLog("Calling lineManager.setupTrucks")
							addWork(function() lineManager.setupTrucks(result, stations, params) end)
							alreadyCalled = true
						end
					else
						debugLog("Route FAILED - reason=" .. tostring(res and res.reason or "nil"))
						if res.reason == "Not enough money" then
								trace("Suppressed marking connection as failed for not enough money")
								if currentBuildParams and currentBuildParams.status2 then
									currentBuildParams.status2 = currentBuildParams.status2.." ".._("Not enough money")
								end
								if result.isAutoBuildMode then
									connectEval.enqueueResult(result, res.costs)
								end
						else
							markFailed()
						end
					end
					standardCallback(res, success)
			end
			if result.needsNewRoute then
				debugLog("Building new route...")
				trace("Needs new route - checking for the route options")


				routeBuilder.buildRoadRouteBetweenStations(stations, callBack, params, result, hasEntranceB)
			else
				debugLog("Checking existing route for upgrade...")
				trace("Existing route used, checking for upgrade")
				routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callBack, params)
			end
			end) -- close pcall function
			if not ok then debugLog("ERROR in work function: " .. tostring(err)) end

		end)
end

local function connectIndustryToStationsAndDepot(res, result, stationsBuilt, roadDepotConnectNodes)
	local function debugLog(msg)
		local f = io.open("/tmp/tf2_build_debug.log", "a")
		if f then f:write(os.date("%H:%M:%S") .. " CONNECT: " .. msg .. "\n") f:close() end
	end
	debugLog("BEGIN - stationsBuilt count=" .. tostring(#stationsBuilt))
	trace("connectIndustryToStationsAndDepot: begin")
--	if true then return end
	local streetType = paramHelper.getParams().preferredCountryRoadType
	local newProposal = api.type.SimpleProposal.new()
	local stations = {} 
	local entityId = 0
	local function nextEntityId()
		entityId = entityId -1
		return entityId
	end
	local hasEntranceB = {}
	for i, stationDetail in pairs(stationsBuilt) do 
		--`local stationNode = util.findClosestNode(util.getFreeNodesForConstruction(res.resultEntities[i]), stationDetail.connectNode)
		trace("Inspecting station detail of ",i)
		if stationDetail.connectNode then
			local entity = util.buildConnectingRoadToNearestNode(stationDetail.connectNode, nextEntityId(), true, newProposal)
			if entity then 
				trace("Connect node found, building link")
			
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
			end 
		end		
		if res.resultEntities[i] then 
			trace("Result entity found, setting on the index")
			local construction = util.getConstruction(res.resultEntities[i])
			stations[stationDetail.index] = construction.stations[1]
		end
		if stationDetail.hasEntranceB then
			hasEntranceB[stationDetail.index]=true
		end
		trace("End loop of detail of ",i)
	end 
	trace("connectIndustryToStationsAndDepot: loop over stationsBuilt complete, now looping roadDepotConnectNodes")
	for i, roadDepotConnectNode in pairs(roadDepotConnectNodes) do 
	--	if i == 2 then
		if roadDepotConnectNode then 
			addWork(function() -- hive this off, it fails then it is not critical
				trace("connectIndustryToStationsAndDepot: hived command for roadDepotConnectNodes at ",i)
				local entity = util.buildConnectingRoadToNearestNode(roadDepotConnectNode.node, nextEntityId(), true, newProposal)
				if not entity then 
					trace("WARNING! No entity found aborting")
					return 
				end
				
				local newProposal = api.type.SimpleProposal.new()
				
				
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
				local build = api.cmd.make.buildProposal(newProposal, initContext(), true)
				api.cmd.sendCommand(build, function(res2, success) 
					standardCallback(res2, success)
					if not success then 
						addWork(function() 
							local depotConstr = res.resultEntities[roadDepotConnectNode.constructionIdx] 
							if not depotConstr then 
								debugPrint({resultEntities=res.resultEntities, roadDepotConnectNodes=roadDepotConnectNodes})
							end
							trace("removing depot",depotConstr)
							local newProposal = api.type.SimpleProposal.new()
							newProposal.constructionsToRemove = { depotConstr }
							api.cmd.sendCommand( api.cmd.make.buildProposal(newProposal, initContext(), true), standardCallback)
						end)
					end 
				end)
			end)
		end	 
	end 
	if result.station1 then
		stations[1]=result.station1
		-- Check if existing station has second entrance
		local conId1 = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(result.station1)
		if conId1 and conId1 ~= -1 then
			local con1 = util.getConstruction(conId1)
			if con1 and con1.params and con1.params.entrance_exit_b == 1 then
				hasEntranceB[1] = true
				trace("Existing station1 has second entrance")
			end
		end
	end
	if result.station2 then
		stations[2]=result.station2
		-- Check if existing station has second entrance
		local conId2 = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(result.station2)
		if conId2 and conId2 ~= -1 then
			local con2 = util.getConstruction(conId2)
			if con2 and con2.params and con2.params.entrance_exit_b == 1 then
				hasEntranceB[2] = true
				trace("Existing station2 has second entrance")
			end
		end
	end
	
	if result.isTown then
		stations[2]=util.findStopBetweenNodes(result.edge2.node0, result.edge2.node1)-- nodes are the same, but the edge has changed
	end
	debugLog("Setup complete, stations[1]=" .. tostring(stations[1]) .. " stations[2]=" .. tostring(stations[2]))
	trace("connectIndustryToStationsAndDepot: setup complete, now to make proposal data")
	local proposalData =   api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	debugLog("ProposalData errors=" .. tostring(#proposalData.errorState.messages))
	trace("connectIndustryToStationsAndDepot: built proposal data, abbout to build command")
	local build = api.cmd.make.buildProposal(newProposal, initContext(), #proposalData.errorState.messages > 0)
	debugLog("Sending build command...")
	trace("About to send command to connectIndustryToStationsAndDepot")
	api.cmd.sendCommand(build, function(res, success)
		debugLog("Build callback: success=" .. tostring(success))
		debuglog("connectIndustryToStationsAndDepot: attempt command result was", tostring(success))
		if success then
			pcall(function() currentBuildParams.status2 = _("Building route").."."end)
			debugLog("Calling buildRoadCargoRoute with stations[1]=" .. tostring(stations[1]) .. " stations[2]=" .. tostring(stations[2]))
			addDelayedWork(function() buildRoadCargoRoute(result, stations,  hasEntranceB) end)
		else
			debugLog("Build FAILED")
			markFailed()
			debugPrint(newProposal)
			connectEval.markConnectionAsFailed(api.type.enum.Carrier.ROAD, result.industry1.id, result.industry2.id)
		end
		standardCallback(res, success)
		end)
 
end

local function buildNewTownRoadConnection(result) 
	addDelayedWork(function() 
		if not result then
			result = connectEval.evaluateNewPassengerRoadTownConnection(circle)
			if not result and countAutoEnabled() > 1 then 
				--lastUpdateGameTime = 0 -- reset to try again immediately
				return 
			end
			if result then 
				result.isAutoBuildMode = true
			end 
		end
		if not result then 
			currentBuildParams = { status = "No new connections were found" }
			return 
		end
		local msg = _("Connecting").." ".._("towns").." ".._(result.town1.name).." "..("with").." ".._(result.town2.name).." ".._("using").." ".._("road")
		trace("******************************************************************************")
		trace(msg)
		trace("******************************************************************************")
		currentBuildParams = {status=msg , carrier = api.type.enum.Carrier.ROAD, location1= result.town1.id,location2= result.town2.id }  
		local callbackCount =0 
		local function callback(res, success) 
			trace("buildNewTownRoadConnection: command success was?", success)
			util.clearCacheNode2SegMaps()
			if success then
				
				callbackCount = callbackCount + 1
				addWork(function() 
					util.lazyCacheNode2SegMaps()
					local station1
					local station2 
					if not result.buildHighway then 
						station1 = result.station1 and result.station1 or util.searchForFirstEntity(result.busStop1Pos, 50, "STATION").id
						station2 = result.station2 and result.station2 or util.searchForFirstEntity(result.busStop2Pos, 50, "STATION").id
					end 
					trace("bus stop construciton succes") 
					local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, ignoreErrors, result.distance)
					params.initialTargetLineRate = result.initialTargetLineRate
					params.setAddBusLanes(result.addBusLanes)
					params.expressBusRoute = result.expressBusRoute
					pcall(function() currentBuildParams.status2 = _("Building route").."."end)
					local function callback2(res2, success2) 
						util.clearCacheNode2SegMaps()
						if success2 then 
							pcall(function() markComplete() end)
							
						else 
							pcall(function() markFailed() end)
							connectEval.markConnectionAsFailed(api.type.enum.Carrier.ROAD, result.town1.id, result.town2.id)
						end
					end
					if result.upgradeRoadsOnly or result.buildHighway then
						params.addBusLanes = false 
						params.upgradeRoadsOnly = true
						if result.buildHighway then 
							params.setForHighway()
							params.isElevated = result.isElevated
							params.isUnderground = result.isUnderground 
							if result.preferredHighwayRoadType then 
								params.preferredHighwayRoadType = result.preferredHighwayRoadType
							end
							params.stationLocationScoreWeights = paramHelper.getParams().highwayConnectionScoreWeights
							params.buildTerminus = {}
							local  nodePair = connectEval.evaluateBestPassengerStationLocations(result.town1, result.town2, params)
							local callbackCount =0
							local hiwayBuildCallback = function(res, success) 
								util.clearCacheNode2SegMaps()
								trace("Buildhighway callback, success was ",success)
								if success then 
									callbackCount = callbackCount + 1
									trace("Callback count was ",callbackCount)
									if callbackCount == 2 then 
										addWork(function() routeBuilder.buildHighway(result.town1, result.town2, callback2, params)end)
									end 
								else 
									callback2(res, success)
								end
							end 
							params.buildTerminus[result.town1.id]=connectEval.shouldBuildTerminus(result.town1, result.town2)
							params.buildTerminus[result.town2.id]=connectEval.shouldBuildTerminus(result.town2, result.town1)
							params.roadPath = result.roadPath
							addWork(function() constructionUtil.createHighwayJunction(result.town1, nodePair[1],result.town2, hiwayBuildCallback, params)end)
							addWork(function() constructionUtil.createHighwayJunction(result.town2, nodePair[2],result.town1, hiwayBuildCallback, params)end)
						else 
							addWork(function() routeBuilder.buildOrUpgradeForBusRoute(station1, station2, callback2,params)end)
							if not result.station1 then
								addDelayedWork(function() constructionUtil.removeStation(station1) end)
							end 
							if not result.station2 then 
								addDelayedWork(function() constructionUtil.removeStation(station2) end)
							end
						end
					elseif callbackCount == 1 then 
						trace("adding work to createIntercityBusLine, callbackCount was",callbackCount)
						addWork(function()lineManager.createIntercityBusLine(station1, station2, result.town1, result.town2, params, callback2)end)
						addWork(function() constructionUtil.connectRoadDepotForTown(result.town1)end)
						addWork(function() constructionUtil.connectRoadDepotForTown(result.town2)end)
					end
				end)
			else
				pcall(function() markFailed() end)
				debugPrint(res.errorState)
				connectEval.markConnectionAsFailed(api.type.enum.Carrier.ROAD, result.town1.id, result.town2.id)
			end
		
		end
		--if upgradeRoadsOnly then 
			--callback({},true)
			--return
		--end
		local newProposal = api.type.SimpleProposal.new()
		if not  result.buildHighway then 
			if not result.station1 then 
				result.busStop1Pos = util.getEdgeMidPoint(result.edge1.id)
				constructionUtil.buildBusStopOnProposal(result.edge1.id, newProposal, result.town1.name)
				if not result.upgradeRoadsOnly then 
					constructionUtil.buildRoadDepotForTown(newProposal,result.town1)
				end
			end 
			if not result.station2 and not result.buildHighway then  
				result.busStop2Pos = util.getEdgeMidPoint(result.edge2.id)
				if not result.upgradeRoadsOnly then 
					constructionUtil.buildRoadDepotForTown(newProposal,result.town2)
				end
				constructionUtil.buildBusStopOnProposal(result.edge2.id, newProposal, result.town2.name)
			end
		end
		util.validateProposal(newProposal)
		if util.tracelog then 
			debugPrint(newProposal) 
		end
		trace("buildNewTownRoadConnection: about to build command")
		local build = api.cmd.make.buildProposal(newProposal, initContext(), true)
		trace("buildNewTownRoadConnection: about to send command")
		api.cmd.sendCommand(build, callback)
		trace("buildNewTownRoadConnection: about to command was sent")
	end)
end
local function buildHighway(town1, town2 , callback, paramOverrides)
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, true)
	params.setForHighway()
	--params.routeEvaluationLimit = 20000 -- default 50000,
	--params.outerIterations = 10 -- default 20,
	--params.routeEvaluationOffsetsLimit = 20 -- default 30
	params.stationLocationScoreWeights = paramHelper.getParams().highwayConnectionScoreWeights
	
	if type(town1)=="number" then 
		town1 = game.interface.getEntity(town1)
	end 
	if type(town2)=="number" then 
		town2 = game.interface.getEntity(town2)
	end
	if pathFindingUtil.areTownsConnectedWithHighway(town1, town2) then -- this can lead to some strange results otherwise
		trace("Towns are already connected with highway, aborting")
		return
	end 
	trace("Building highway between ",town1.name, " and ",town2.name)
	local function shouldBuildTerminus(town, otherTown) 
		if params.connectionLookup and params.connectionLookup[town.id] then 
			local otherConnections = params.connectionLookup[town.id] 
			local count = params.townsCount[town.id]
			if count == 1 then 
				return true 
			elseif count == 2 then
				local p0, p1 
				for otherTownId, bool in pairs(otherConnections) do 
					if not p0 then 
						p0 = params.positionLookup[otherTownId]
					else 
						p1 = params.positionLookup[otherTownId]
					end 
				end 		
				local pTown = params.positionLookup[town.id]
				local vec1 = pTown - p0 
				local vec2 = pTown - p1 
				local angle = math.abs(util.signedAngle(vec1, vec2))
				trace("The relative angle at town",town.name," was " ,math.deg(angle))
				return angle < math.rad(90)
			else 
				return false 
			end 
		else 
			return connectEval.shouldBuildTerminus(town, otherTown)
		end 
	end 
	
	params.buildTerminus[town1.id]=shouldBuildTerminus(town1, town2)
	params.buildTerminus[town2.id]=shouldBuildTerminus(town2, town1)
	for k, v in pairs(paramOverrides) do 
		trace("Overriding",k," to ",v)
		params[k]=v
	end 
	local  nodePair = connectEval.evaluateBestPassengerStationLocations(town1, town2, params)
	local callbackCount =0
	local hiwayBuildCallback = function(res, success) 
		trace("Buildhighway callback, success was ",success)
		if success then 
			callbackCount = callbackCount + 1
			trace("Callback count was ",callbackCount)
			if callbackCount == 2 then 
				addWork(function() routeBuilder.buildHighway(town1, town2, callback, params)end)
			end 
		else 
			callback(res, success)
		end
	end 
	addWork(function() constructionUtil.createHighwayJunction(town1, nodePair[1],town2, hiwayBuildCallback, params)end)
	addWork(function() constructionUtil.createHighwayJunction(town2, nodePair[2],town1, hiwayBuildCallback, params)end)
end

local function buildMainConnectionHighways(param) 
 
	local connections = {} 
	local townsCount = {}
	local connectionLookup = {}
	local positionLookup = {}
	local allTowns = {}
	local nameLookup = {}
	
	api.engine.forEachEntityWithComponent(function(entity) 
		townsCount[entity]=0
		connectionLookup[entity]={}
		local fullEntity = game.interface.getEntity(entity)
		positionLookup[entity]=util.v3fromArr(fullEntity.position)
		nameLookup[entity]=fullEntity.name
		table.insert(allTowns, entity)
	end, api.type.ComponentType.TOWN)
	
	local function registerConnection(town1, town2) 
		townsCount[town1] = townsCount[town1]+1
		townsCount[town2] = townsCount[town2]+1
		connectionLookup[town1][town2] = true 
		connectionLookup[town2][town1] = true 
	end 
	
	api.engine.forEachEntityWithComponent(function(entity) 
		local connection = api.engine.getComponent(entity,api.type.ComponentType.TOWN_CONNECTION)
		registerConnection(connection.entity0, connection.entity1) 
		table.insert(connections, { town1 = connection.entity0, town2 = connection.entity1})
		trace("Registering main connection between",connection.entity0, "and",connection.entity1,"towns were",nameLookup[connection.entity0],nameLookup[connection.entity1])
	end, api.type.ComponentType.TOWN_CONNECTION)
	trace("There were",#connections)
 
	local function addConnectionForTown(townId) 
		local scoreWeights = { 75 , 25 } 
		
		local options = {}
		for i, otherTownId in pairs(allTowns) do 
			if otherTownId ~= townId  and not connectionLookup[townId][otherTownId] and townsCount[otherTownId] > 0 then -- do not want to connect to another orphan town
				
				local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenTowns(townId, otherTownId)
				trace("Looking for routeInfo between towns, found?",routeInfo,"highwayFraction?",(routeInfo and routeInfo.highwayFraction))
				if not routeInfo or   routeInfo.highwayFraction < 0.75 then  
					table.insert(options, {
						townId = otherTownId, 
						scores = {
							util.distance(positionLookup[townId], positionLookup[otherTownId]),
							townsCount[otherTownId]
						}
					})
				else 
					trace("Rejecting the option between",townId,otherTownId,"as a highway already exists",nameLookup[townId],nameLookup[otherTownId])
					return -- already connected
				end 
			end 
		end 
		 
		  
		if #options > 1 then 
			local otherTownId = util.evaluateWinnerFromScores(options, scoreWeights).townId
			trace("Adding ",otherTownId," for connection with ",otherTownId)
			table.insert(connections, { town1 = townId, town2 = otherTownId})
			registerConnection(townId, otherTownId) 
		end 
	
	end
 
	for townId, count in pairs(townsCount) do 
		if count == 0 then 
			trace("Town ",townId,nameLookup[townId]," had no connections, attempting to correct")
			--local otherTown = util.searchForNearestEntity(game.interface.getEntity(townId).position, math.huge, "TOWN", function(otherTown) return otherTown.id ~= townId end)
			addConnectionForTown(townId)  
		end 
	end 
	for townId, count in pairs(townsCount) do 
		if count == 1 and not connectEval.shouldBuildTerminus(game.interface.getEntity(townId)) then 
			trace("Town ",townId,nameLookup[townId]," had only 1, attempting to correct")
			--local otherTown = util.searchForNearestEntity(game.interface.getEntity(townId).position, math.huge, "TOWN", function(otherTown) return otherTown.id ~= townId end)
			addConnectionForTown(townId)  
		end 
	end 
	for i, townId in pairs(allTowns) do 
		local p = positionLookup[townId]
		local radius = 5000 
		for i, otherTownId in pairs(util.searchForEntities(p, radius, "TOWN", true)) do
			if otherTownId ~= townId then 
				local found = false 
				for connectTown, bool in pairs(connectionLookup[townId]) do 
					if connectTown == otherTownId then 
						found = true 
						break 
					end 
					for connectTown2, bool in pairs(connectionLookup[connectTown]) do 
						if connectTown2 == otherTownId then 
							found = true 
							break 
						end 
						for connectTown3, bool in pairs(connectionLookup[connectTown2]) do 
						if connectTown3 == otherTownId or connectionLookup[connectTown3][otherTownId] then 
							found = true 
							break 
						end 
					end
					end 
					if found then 
						break 
					end 
				end 
				trace("Attempted to find a connection between ",townId, " and otherTownId, was found?", found)
				if not found then 
					trace("Addition connection between",townId, otherTownId,nameLookup[townId],nameLookup[otherTownId])
					table.insert(connections, { town1 = townId, town2 = otherTownId})
					registerConnection(townId, otherTownId) 
				end 
			end 
			
		end 
	end 

	
	local expectedResult = #connections
	local currentCount = 0
	local callback = function(res, success) 
		currentCount = currentCount + 1
		if currentBuildParams then 
			currentBuildParams.status = _("Building highways along main connections").." "..tostring(currentCount).." ".._("of").." "..tostring(expectedResult).." ".._("Complete")
		end 
		if currentCount == expectedResult then 
			if currentBuildParams then 
				markComplete()
			end 
		end 
		standardCallback(res, success)
	end 
	
	param.connectionLookup = connectionLookup
	param.positionLookup = positionLookup
	param.townsCount = townsCount
	param.buildCompleteRoute = true
	
	if util.tracelog then 
		debugPrint({connections = connections})
		debugPrint({townCount = townCount})
	end
	
	local function scoreConnections(connection) 
		return -townsCount[connection.town1]-townsCount[connection.town2]
	end 
	
	local function scoreConnectionAgainstTown(town, otherTown)
		local minAngle = math.rad(180)
		
		if townsCount[town] >= 3 then 
			local vec1 = positionLookup[town]-positionLookup[otherTown]
			for thirdTown, bool in pairs(connectionLookup[town]) do 
				if thirdTown ~= otherTown then 
					local vec2 = positionLookup[thirdTown]-positionLookup[town]
					minAngle = math.min(minAngle, math.abs(util.signedAngle(vec1, vec2)))
					trace("Inspecting min angle between ",town,otherTown," was ",minAngle)
				end 
			end 
		end
		return minAngle
	end 
	
	local function scoreMinorConnection(connection) 
		return scoreConnectionAgainstTown(connection.town1, connection.town2 )+scoreConnectionAgainstTown(connection.town2, connection.town1 )
	end 
	
	local connectionsCreated = {}
	local function townHash(town1, town2) 
		if town1> town2 then 
			return town1 + 1000000*town2
		else 
			return town2 + 1000000*town1
		end 
	end 	

	
	local function getBestAnglePair(townId)
		local towns = util.getKeysAsTable(connectionLookup[townId])
		local options = {}
		for i, otherTown in pairs(towns) do 
			for j, otherTown2 in pairs(towns) do 
				if i~=j then 
					local p0 = positionLookup[otherTown]
					local p1 = positionLookup[townId]
					local p2 = positionLookup[otherTown2]
					local angle = math.abs(util.signedAngleBetweenPoints(p0, p1, p2))
					trace("The angle between",otherTown, townId,otherTown2,"was",math.deg(angle))
					table.insert(options,{
						priorTown = otherTown, 
						startTown = townId,
						nextTown = otherTown2,
						angle = angle, 
						scores = { angle } 
					})
				end 
			end 
		end
		return util.evaluateWinnerFromScores(options)		
	end 
	local startOptions = {}
	for townId, count in pairs(townsCount) do 
		if count == 3 then 
			trace("Town ",townId," had no connections, attempting to correct") 
			table.insert(startOptions,  getBestAnglePair(townId))
		end 
	end 
	
	local function getNextTown(townId, alreadyConnected, alreadySeen) 
		local towns = util.getKeysAsTable(connectionLookup[townId])
		trace("getNextTown for",nameLookup[townId],nameLookup[alreadyConnected])
		local options = {}
		for i, otherTown in pairs(towns) do 
			if alreadySeen[otherTown] then 
				trace("WARNING! othertown already seen, only valid if circle line, was",otherTown,nameLookup[otherTown])
			end 
			if otherTown ~= alreadyConnected and not alreadySeen[otherTown] then 
				local p0 = positionLookup[alreadyConnected]
				local p1 = positionLookup[townId]
				local p2 = positionLookup[otherTown]
				local angle = math.abs(util.signedAngleBetweenPoints(p0, p1, p2))
				trace("getNextTown: The angle between",alreadyConnected, townId,otherTown,"was",math.deg(angle), "for towns",nameLookup[alreadyConnected],nameLookup[townId],nameLookup[otherTownId])
				table.insert(options,{ 
					town = otherTown,
					scores = { angle}
				
				})
			end 
		end 
		if #options > 0 then 
			return util.evaluateWinnerFromScores(options).town
		end
		trace("No options found for next town from",townId,alreadyConnected,nameLookup[townId],nameLookup[alreadyConnected],"out of a choice of",#towns)
		if #towns > 1 then 
			trace("No options found despite more than one town, should expect circle line?")
			if util.tracelog then	
				debugPrint({towns=towns, townId=townId,alreadyConnected=alreadyConnected,alreadySeen=alreadySeen})
			end
		end 
	end 
	
	local function markConnected(town1, town2)
		connectionsCreated[townHash(town1, town2)]= true
	end
	
	if #startOptions > 0 then 
		local startOption = util.evaluateWinnerFromScores(startOptions)
		local towns = {}
		table.insert(towns, startOption.startTown)
		local alreadyConnected = startOption.startTown
		local alreadySeen = {[startOption.startTown] = true } 
		local priorTown = startOption.priorTown
		repeat 
			trace("Inserting town",priorTown,"at the start of the table")
			table.insert(towns,1,priorTown)
			local thisTown = priorTown
			alreadySeen[thisTown]=true
			priorTown = getNextTown(thisTown, alreadyConnected,alreadySeen)
			alreadyConnected = thisTown
		until not priorTown
		
		local alreadyConnected = startOption.startTown
		local nextTown = startOption.nextTown
		repeat 
			trace("Inserting town",nextTown,"at the end of the table")
			table.insert(towns,nextTown)
			local thisTown = nextTown
			alreadySeen[thisTown]=true 
			nextTown = getNextTown(thisTown, alreadyConnected,alreadySeen)
			alreadyConnected = thisTown
		until not nextTown
		trace("After construction the num towns was",#towns)
		for i = 2, #towns do 
			markConnected(towns[i-1],towns[i])
		end 
		local isCircularRoute = false
		local buildTerminus
		if connectionLookup[towns[1]][towns[#towns]] then 
			trace("The first and last towns should be connected, making ciruclar for",towns[1],towns[#towns])
			isCircularRoute = true 
			markConnected(towns[1],towns[#towns])
		else 	
			buildTerminus = {}
			for i = 2, #towns-1 do 
				buildTerminus[towns[i]]=false 
			end 
			buildTerminus[towns[1]]=util.size(connectionLookup[towns[1]])==1
			buildTerminus[towns[#towns]]=util.size(connectionLookup[towns[#towns]])==1
			if util.tracelog then 
				debugPrint({buildTerminus=buildTerminus})
			end 
		end 		
		if util.tracelog then debugPrint({towns=towns}) end
		buildCompleteRoute({ 
			isCompleteRoute = true,
			towns = util.mapTable(towns, game.interface.getEntity),
			isCircularRoute = isCircularRoute,
			isTrack = false,
			isExpress = false,
			isHighway = true ,
			paramOverrides = { buildTerminus },  
		})
	end 
	addWorkWhenAllIsFinished(function() 
		local msg = _("Building highways along main connections")
		currentBuildParams = { status = msg} 
		currentBuildParams.status2 =  _("Building").."."
		local count = 0
		param.buildTerminus = {}
		for townId, connections in pairs(connectionLookup) do 
			param.buildTerminus[townId]=util.size(connections)==1
			trace("Set the buildTerminus for",townId,"to",param.buildTerminus[townId],"at",nameLookup[townId])
		end 
		for i, connection in pairs(util.evaluateAndSortFromScores(connections, {25,75}, {scoreConnections, scoreMinorConnection})) do 
			if not connectionsCreated[townHash(connection.town1, connection.town2)] then 
				trace("Adding work to connect",connection.town1, connection.town2,nameLookup[connection.town1], nameLookup[connection.town2])
				addDelayedWork(function() buildHighway(connection.town1, connection.town2 , callback, param) end)
				count = count + 1
				markConnected(connection.town1, connection.town2)
			else 
				trace("Suppressing work to connect",connection.town1, connection.town2,nameLookup[connection.town1], nameLookup[connection.town2])
			end 
		end
		trace("Connecting",count,"of",#connections)
		expectedResult = count
	end)
end 

local function buildNewHighway() 
	local result =  connectEval.evaluateNewPassengerRoadTownConnection(circle, {isHighway=true})
	if not result then 
		if countAutoEnabled() > 1 then 
			lastUpdateGameTime = 0 -- reset to try again immediately
		end 
		return 
	end 
	result.buildHighway = true 
	buildNewTownRoadConnection(result) 
end

local function buildNewIndustryRoadConnection(result, cargoFilter) 
	local function msgFn(result) 
		return  _("Connecting").." ".._("industry").." ".._(result.industry1.name).." "..("with").." ".._(result.industry2.name).." ".._("using").." ".._("road")
	end
	if result then
		currentBuildParams = {status=msgFn(result), carrier = api.type.enum.Carrier.ROAD,  location1= result.industry1.id,location2= result.industry2.id }
		pcall(function() currentBuildParams.status2 =  _("Initialising").."." end)
		addPause()
	end

addDelayedWork(function()
	-- Debug logging helper
	local function debugLog(msg)
		local f = io.open("/tmp/tf2_build_debug.log", "a")
		if f then f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n") f:close() end
		print("[BUILD_DEBUG] " .. msg)
	end

	debugLog("=== buildNewIndustryRoadConnection START ===")
	debugLog("cargoFilter param=" .. tostring(cargoFilter))
	debugLog("result param=" .. tostring(result))

	-- Debug the result object
	debugLog("result type=" .. type(result))
	if result then
		debugLog("result is truthy")
		debugLog("result.industry1=" .. tostring(result.industry1))
		debugLog("result.industry2=" .. tostring(result.industry2))
		if result.industry1 then
			debugLog("industry1.id=" .. tostring(result.industry1.id))
			debugLog("industry1.name=" .. tostring(result.industry1.name))
		end
		if result.industry2 then
			debugLog("industry2.id=" .. tostring(result.industry2.id))
			debugLog("industry2.name=" .. tostring(result.industry2.name))
		end
	else
		debugLog("result is falsy/nil")
	end

	local originalResult = result
	if not result then
		local maxDist
		if oneAiOptionActive() and util.year()>1900 then
			maxDist = math.huge
		end

	debugLog("circle=" .. tostring(circle) .. " townSearchDistance=" .. tostring(townSearchDistance) .. " maxDist=" .. tostring(maxDist) .. " cargoFilter=" .. tostring(cargoFilter))
	debugLog("Calling evaluateNewIndustryConnectionWithRoads...")

		local evalOk, evalResult = pcall(function()
			return connectEval.evaluateNewIndustryConnectionWithRoads(circle, { townSearchDistance = townSearchDistance, maxDist= maxDist, cargoFilter = cargoFilter })
		end)

		if not evalOk then
			debugLog("ERROR in evaluation: " .. tostring(evalResult))
			return
		end

		result = evalResult
		debugLog("evaluateNewIndustryConnectionWithRoads result=" .. tostring(result))

		if not result then
			debugLog("No result from evaluation, returning")
			if countAutoEnabled() > 1 then
				lastUpdateGameTime = 0 -- reset to try again immediately
			end
			return
		end
		debugLog("Got valid result, proceeding with build")
		result.isAutoBuildMode = true
	else
		debugLog("Using provided result, recheckResultForStations")
		local recheck_ok, recheck_err = pcall(function()
			connectEval.recheckResultForStations(result, true, api.type.enum.Carrier.ROAD)
		end)
		if not recheck_ok then
			debugLog("ERROR in recheckResultForStations: " .. tostring(recheck_err))
		end
	end
	debugLog("About to call lazyCacheNode2SegMaps")
	local cache_ok, cache_err = pcall(function()
		util.lazyCacheNode2SegMaps()
	end)
	if not cache_ok then
		debugLog("ERROR in lazyCacheNode2SegMaps: " .. tostring(cache_err))
		debugLog("Continuing anyway...")
	end
	debugLog("Building message from result...")
	local msg_ok, msg = pcall(msgFn, result)
	if not msg_ok then
		debugLog("ERROR in msgFn: " .. tostring(msg))
		return
	end
	debugLog("Message built: " .. tostring(msg))
	trace("******************************************************************************")
	trace(msg)
	trace("******************************************************************************")
	local routeLength = result.routeLength
	debugLog("routeLength=" .. tostring(routeLength))

	local callbackThis = function(res, success)
		trace("result of intermediate work was",success)
		addWork(function() buildNewIndustryRoadConnection(result) end)
	end

	debugLog("Checking edge1: " .. tostring(result.edge1))
	if result.edge1 and  util.isDoubleDeadEndEdge(result.edge1.id) and not result.alreadyAttemptedEdge1 then
		debugLog("Building edge1 connect road")
		result.alreadyAttemptedEdge1  = true
		routeBuilder.buildIndustryConnectRoad(result.edge1.id, callbackThis)
		return

	end
	debugLog("Checking edge2: " .. tostring(result.edge2))
	if result.edge2 and  util.isDoubleDeadEndEdge(result.edge2.id) and not result.alreadyAttemptedEdge2 then
		debugLog("Building edge2 connect road")
		result.alreadyAttemptedEdge2 = true
		routeBuilder.buildIndustryConnectRoad(result.edge2.id, callbackThis)
		return
	end

	debugLog("Creating newProposal...")
	local newProposal = api.type.SimpleProposal.new()
	currentBuildParams = {status=msg, carrier = api.type.enum.Carrier.ROAD,  location1= result.industry1.id, location2= result.industry2.id }

	debugLog("Getting industryPos from result.industry1.position: " .. tostring(result.industry1.position))

	-- Check position format
	local pos1 = result.industry1.position
	if type(pos1) == "table" then
		debugLog("position table keys: ")
		for k,v in pairs(pos1) do
			debugLog("  " .. tostring(k) .. " = " .. tostring(v))
		end
	end

	debugLog("Calling v3fromArr...")
	local pos_ok, industryPos = pcall(util.v3fromArr, result.industry1.position)
	debugLog("v3fromArr returned: ok=" .. tostring(pos_ok))
	if not pos_ok then
		debugLog("ERROR in v3fromArr for industry1: " .. tostring(industryPos))
		return
	end
	debugLog("industryPos created successfully")

	debugLog("Getting industry2Pos...")
	local pos2_ok, industry2Pos = pcall(util.v3fromArr, result.industry2.position)
	if not pos2_ok then
		debugLog("ERROR in v3fromArr for industry2: " .. tostring(industry2Pos))
		return
	end
	debugLog("industry2Pos created successfully")

	debugLog("Calling getDefaultRouteBuildingParams with cargoType=" .. tostring(result.cargoType))
	local params_ok, params = pcall(paramHelper.getDefaultRouteBuildingParams, result.cargoType, false, ignoreErrors, result.distance)
	if not params_ok then
		debugLog("ERROR in getDefaultRouteBuildingParams: " .. tostring(params))
		return
	end
	debugLog("params created successfully")

	params.isAutoBuildMode = result.isAutoBuildMode
	-- Allow custom routeScoreWeighting from script event params
	if result.routeScoreWeighting then
		params.routeScoreWeighting = result.routeScoreWeighting
		trace("Using custom routeScoreWeighting from params")
	end

	debugLog("About to call getTruckStationsToBuild...")
	-- TRACE: Log result and params for debugging
	print("=== buildNewIndustryRoadConnection TRACE ===")
	print("result.industry1: ", result.industry1 and result.industry1.name or "nil")
	print("result.industry2: ", result.industry2 and result.industry2.name or "nil")
	print("result.cargoType: ", result.cargoType or "nil")
	print("result.distance: ", result.distance or "nil")
	print("result.isAutoBuildMode: ", result.isAutoBuildMode or "nil")
	print("result.station1: ", result.station1 or "nil")
	print("result.station2: ", result.station2 or "nil")
	print("result.edge1: ", result.edge1 and result.edge1.id or "nil")
	print("result.edge2: ", result.edge2 and result.edge2.id or "nil")
	print("result.route: ", result.route and (#result.route.." edges") or "nil")
	print("result.needsNewRoute: ", result.needsNewRoute)
	print("result.routeLength: ", result.routeLength or "nil")
	print("result.routeScoreWeighting: ", result.routeScoreWeighting and table.concat(result.routeScoreWeighting, ",") or "nil (using defaults)")
	print("params.routeScoreWeighting: ", params.routeScoreWeighting and table.concat(params.routeScoreWeighting, ",") or "nil")
	print("=== END TRACE ===")

	debugLog("Calling getTruckStationsToBuild...")
	local stations_ok, stationsToBuild = pcall(connectEval.getTruckStationsToBuild, result)
	if not stations_ok then
		debugLog("ERROR in getTruckStationsToBuild: " .. tostring(stationsToBuild))
		return
	end
	debugLog("getTruckStationsToBuild returned, count=" .. tostring(#stationsToBuild or "unknown"))

	local stationsBuilt = {}
	for i, details in pairs(stationsToBuild) do
		debugLog("Building truck station " .. tostring(i) .. " for industry...")
		local build_ok, buildResult = pcall(constructionUtil.buildTruckStationForIndustry, newProposal, details, result, params)
		if not build_ok then
			debugLog("ERROR building truck station: " .. tostring(buildResult))
		else
			table.insert(stationsBuilt, buildResult)
			debugLog("Truck station built successfully")
		end
	end


	if result.station1 then
		debugLog("Checking station1 for upgrade...")
		local buildResult = constructionUtil.checkRoadStationForUpgrade(newProposal, result.station1, result.industry1, result, params)
		if buildResult then
			table.insert(stationsBuilt, {
				connectNode = buildResult.connectNode,
				hasEntranceB =buildResult.hasEntranceB ,
				index = 1,
				hasStubRoad=buildResult.hasStubRoad
				})

		end
	end
	if result.station2 then
		debugLog("Checking station2 for upgrade...")
		local buildResult = constructionUtil.checkRoadStationForUpgrade(newProposal, result.station2, result.industry2, result, params)
		if buildResult then
			table.insert(stationsBuilt, {
			connectNode = buildResult.connectNode,
			hasEntranceB =buildResult.hasEntranceB ,
			index = 2,
			hasStubRoad=buildResult.hasStubRoad
			})
		end
	end

	debugLog("Calling buildRoadDepotForIndustry...")
	local depot_ok, roadDepotConnectNodes = pcall(constructionUtil.buildRoadDepotForIndustry, newProposal, result, stationsBuilt)
	if not depot_ok then
		debugLog("ERROR in buildRoadDepotForIndustry: " .. tostring(roadDepotConnectNodes))
		return
	end
	debugLog("Depot built, stationsBuilt count=" .. tostring(#stationsBuilt))

	if result.isTown and not result.station2 then
		debugLog("Building truckStop for town...")
		trace("Adding work to build truckStop")
		addWork(function() constructionUtil.buildTruckStopOnProposal(result.edge2.id, result.stopName) end) -- this may succeed but throw an error, so hived off to allow this to continue
	end
	debugLog("Making proposal... isTown=" .. tostring(result.isTown) .. " station2=" .. tostring(result.station2))
	trace("About to build proposal, isTown?",result.isTown,"station2?",result.station2)
	local ignoreErrors = params.ignoreErrors or false
	ignoreErrors = true-- temp

	debugLog("Calling makeProposalData...")
	local testData_ok, testData = pcall(api.engine.util.proposal.makeProposalData, newProposal, initContext())
	if not testData_ok then
		debugLog("ERROR in makeProposalData: " .. tostring(testData))
		return
	end
	debugLog("testData errors=" .. tostring(#testData.errorState.messages) .. " critical=" .. tostring(testData.errorState.critical))
	trace("Test data had errors?",#testData.errorState.messages," critical?",testData.errorState.critical)

	debugLog("Creating buildProposal command...")
	local build = api.cmd.make.buildProposal(newProposal, initContext(), ignoreErrors)
	util.removeTrafficlights(build)
	util.validateProposal(newProposal)
	debugLog("Sending build command...")
	trace("Sending command to build road stations and depots")
	api.cmd.sendCommand(build, function(res, success)
		debugLog("Build command callback: success=" .. tostring(success))
		trace("Result command to build road stations and depots was",success)
		if success then
			util.clearCacheNode2SegMaps()
			debugLog("Build succeeded, calling connectIndustryToStationsAndDepot...")
			addDelayedWork(function() connectIndustryToStationsAndDepot(res, result, stationsBuilt, roadDepotConnectNodes )end)
		else
			debugLog("Build FAILED")
			connectEval.markConnectionAsFailed(api.type.enum.Carrier.ROAD, result.industry1.id, result.industry2.id)
			if not originalResult then
				buildNewIndustryRoadConnection()
			end
			markFailed()
			if util.tracelog then
				debugPrint(res)
			end
		end
		standardCallback(res, success)
		end)
		needsupdate = true
	end)
end

-- CLAUDE: Debug log helper
local function debugLog(msg)
	local f = io.open("/tmp/tf2_multistop_debug.log", "a")
	if f then
		f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
		f:close()
	end
	print("[MULTISTOP] " .. tostring(msg))
end

-- CLAUDE: Multi-stop cargo route builder
-- Takes an array of industries and creates a single line with all stops
-- Uses the same approach as buildNewIndustryRoadConnection but for N stops
local function buildMultiStopCargoRoute(param)
	debugLog("=== buildMultiStopCargoRoute CALLED ===")
	if not param or not param.industries or #param.industries < 2 then
		debugLog("ERROR: buildMultiStopCargoRoute requires at least 2 industries")
		return
	end

	local industries = param.industries
	local lineName = param.lineName or "Multi-stop route"
	local firstCargo = param.defaultCargoType or "COAL"
	local isRail = param.transportMode == "RAIL"

	debugLog("Building route with " .. #industries .. " stops, name: " .. lineName .. ", mode: " .. (isRail and "RAIL" or "ROAD"))
	for i, ind in ipairs(industries) do
		debugLog("  Stop " .. i .. ": " .. (ind.name or "?") .. " id=" .. tostring(ind.id) .. " type=" .. (ind.type or "INDUSTRY"))
	end

	currentBuildParams = {
		status = _("Building multi-stop route"),
		carrier = isRail and api.type.enum.Carrier.RAIL or api.type.enum.Carrier.ROAD
	}

	addDelayedWork(function()
		debugLog("addDelayedWork callback started")
		util.lazyCacheNode2SegMaps()

		-- Get default params
		debugLog("Getting default params for cargo: " .. firstCargo)
		local ok, params = pcall(function()
			return paramHelper.getDefaultRouteBuildingParams(firstCargo, false, ignoreErrors)
		end)
		if not ok then
			debugLog("ERROR getting params: " .. tostring(params))
			return
		end
		debugLog("Got params successfully")
		params.isAutoBuildMode = true

		local stations = {}
		local pendingBuilds = #industries
		local buildsFailed = 0

		-- Callback when all stations are ready
		local function onAllStationsReady()
			debugLog("onAllStationsReady called")
			-- Verify all stations exist and track matching industries
			local validStations = {}
			local validIndustries = {}  -- Track industries that have valid stations
			for i = 1, #industries do
				debugLog("Checking station " .. i .. ": " .. tostring(stations[i]))
				if stations[i] then
					table.insert(validStations, stations[i])
					table.insert(validIndustries, industries[i])  -- Keep industries in sync
					debugLog("Station " .. i .. " ready: " .. tostring(stations[i]))
				else
					debugLog("WARNING: Missing station for industry " .. i)
				end
			end

			if #validStations < 2 then
				debugLog("ERROR: Not enough stations built, need at least 2, got " .. #validStations)
				markFailed()
				return
			end

			debugLog("Creating multi-stop line with " .. #validStations .. " stations")

			-- Build the result object for setupTrucks (use validIndustries for correct mapping)
			local result = {
				industry1 = validIndustries[1],
				industry2 = validIndustries[#validIndustries],
				cargoType = firstCargo,
				initialTargetLineRate = tonumber(param.targetRate) or 100,
				isAutoBuildMode = true,
				needsNewRoute = true
			}

			-- Set params
			params.lineName = lineName
			params.cargoType = firstCargo
			params.isCargo = true
			params.isPrimaryIndustry = true
			params.initialTargetLineRate = result.initialTargetLineRate

			-- Calculate total distance
			local totalDist = 0
			for i = 1, #validStations - 1 do
				totalDist = totalDist + util.distBetweenStations(validStations[i], validStations[i+1])
			end
			params.distance = totalDist

			-- NOW BUILD ROADS between consecutive station pairs!
			-- Chain: build road 1-2, then 2-3, then 3-4, etc., then setup line
			local currentRoadPair = 1
			local totalPairs = #validStations - 1

			local function buildNextRoadSegment()
				if currentRoadPair > totalPairs then
					-- All roads built, now create the line
					debugLog("All " .. totalPairs .. " road segments built, creating line...")
					addWork(function()
						debugLog("Calling lineManager.setupTruckLine with " .. #validStations .. " stations")
						debugLog("Stations: " .. table.concat(validStations, ", "))
						debugLog("params.cargoType=" .. tostring(params.cargoType))
						debugLog("params.distance=" .. tostring(params.distance))
						debugLog("params.lineName=" .. tostring(params.lineName))
						debugLog("result.cargoType=" .. tostring(result.cargoType))
						local ok, err = pcall(function()
							lineManager.setupTruckLine(validStations, params, result)
						end)
						if ok then
							debugLog("setupTruckLine call completed - checking vehicles...")
							-- Check if line was created
							local lines = api.engine.system.lineSystem.getLines()
							debugLog("Total lines in game: " .. tostring(#lines))
						else
							debugLog("ERROR in setupTruckLine: " .. tostring(err))
						end
					end)
					markComplete()
					return
				end

				local station1 = validStations[currentRoadPair]
				local station2 = validStations[currentRoadPair + 1]
				debugLog("Building road segment " .. currentRoadPair .. "/" .. totalPairs .. ": station " .. tostring(station1) .. " -> " .. tostring(station2))

				-- Check if road already exists
				local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2)
				local needsNewRoad = not routeInfo or routeInfo.exceedsRouteToDistLimitForTrucks
				debugLog("Route info: exists=" .. tostring(routeInfo ~= nil) .. " needsNewRoad=" .. tostring(needsNewRoad))

				local roadCallback = function(res, success)
					debugLog("Road segment " .. currentRoadPair .. " callback: success=" .. tostring(success))
					if success or not needsNewRoad then
						currentRoadPair = currentRoadPair + 1
						addWork(buildNextRoadSegment)
					else
						debugLog("ERROR building road segment " .. currentRoadPair .. ": " .. tostring(res and res.reason))
						-- Try to continue anyway
						currentRoadPair = currentRoadPair + 1
						addWork(buildNextRoadSegment)
					end
				end

				if needsNewRoad then
					debugLog("Calling routeBuilder.buildRoadRouteBetweenStations for pair " .. currentRoadPair)
					local pairStations = {station1, station2}
					local pairResult = {
						industry1 = validIndustries[currentRoadPair],
						industry2 = validIndustries[currentRoadPair + 1],
						cargoType = firstCargo,
						needsNewRoute = true,
						isAutoBuildMode = true
					}
					routeBuilder.buildRoadRouteBetweenStations(pairStations, roadCallback, params, pairResult, {})
				else
					debugLog("Road already exists for pair " .. currentRoadPair .. ", skipping build")
					roadCallback(nil, true)
				end
			end

			-- Start building road segments
			debugLog("Starting to build " .. totalPairs .. " road segments...")
			addWork(buildNextRoadSegment)
		end

		-- SIMPLE APPROACH: Build stations one at a time, then roads, then line
		local currentIndustryIndex = 1

		local function buildNextStation()
			if currentIndustryIndex > #industries then
				debugLog("All " .. #industries .. " stations processed, moving to road building")
				addDelayedWork(onAllStationsReady)
				return
			end

			local ind = industries[currentIndustryIndex]
			local indIdx = currentIndustryIndex
			debugLog("Building station " .. indIdx .. "/" .. #industries .. " for: " .. (ind.name or "?") .. " type=" .. (ind.type or "INDUSTRY"))

			-- Skip if we already have a station for this industry
			if stations[indIdx] then
				debugLog("Already have station for index " .. indIdx .. ": " .. tostring(stations[indIdx]))
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end

			local isTown = ind.type == "TOWN"
			local indPos = util.v3fromArr(ind.position)

			if isTown then
				debugLog("Industry is a TOWN - searching for nearby cargo station or building one")
				local nearbyStation = constructionUtil.searchForNearestCargoRoadStation(indPos, 500)
				if nearbyStation then
					debugLog("Found existing station near town: " .. tostring(nearbyStation))
					stations[indIdx] = nearbyStation
				else
					debugLog("No station near town - building cargo road station at town edge")
					local buildTownStation = function()
						debugLog("buildTownStation() called for " .. (ind.name or "?"))
						local townData = {id = ind.id, name = ind.name, position = ind.position, type = "TOWN"}
						local townResult = {
							industry1 = townData,
							industry2 = townData,
							cargoType = firstCargo,
							p0 = {x = indPos.x, y = indPos.y, z = indPos.z},
							p1 = {x = indPos.x, y = indPos.y, z = indPos.z},
							isTown = true
						}
						local newProposal = api.type.SimpleProposal.new()
						local details = {
							index = 1,
							industry = townData,
							position = indPos,
							type = "TOWN"
						}
						debugLog("Calling buildCargoRoadStationNearestTownEdge...")
						local ok, stationResult = pcall(function()
							return constructionUtil.buildCargoRoadStationNearestTownEdge(newProposal, details, townResult, params)
						end)
						if not ok then
							debugLog("ERROR in buildCargoRoadStationNearestTownEdge: " .. tostring(stationResult))
							currentIndustryIndex = currentIndustryIndex + 1
							addWork(buildNextStation)
							return
						end
						debugLog("buildCargoRoadStationNearestTownEdge returned: " .. tostring(stationResult))
						if stationResult and stationResult.constructionIdx then
							debugLog("Town station build prepared, constructionIdx=" .. stationResult.constructionIdx)
							local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
							api.cmd.sendCommand(build, function(res, success)
								debugLog("Town station build callback: success=" .. tostring(success))
								if success and res.resultEntities[stationResult.constructionIdx] then
									local entityId = res.resultEntities[stationResult.constructionIdx]
									local construction = util.getConstruction(entityId)
									if construction and construction.stations and construction.stations[1] then
										stations[indIdx] = construction.stations[1]
										debugLog("Town station created: " .. tostring(stations[indIdx]))
									end
								end
								currentIndustryIndex = currentIndustryIndex + 1
								addWork(buildNextStation)
							end)
						else
							debugLog("Could not prepare town station, stationResult=" .. tostring(stationResult))
							currentIndustryIndex = currentIndustryIndex + 1
							addWork(buildNextStation)
						end
					end
					buildTownStation()
					return
				end
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end

			-- Regular industry - build station
			debugLog("Creating pairResult for industry...")
			local indData = {id = ind.id, name = ind.name, position = ind.position, type = "INDUSTRY"}
			local pairResult = {
				industry1 = indData,
				industry2 = indData,
				cargoType = firstCargo,
				p0 = {x = indPos.x, y = indPos.y, z = indPos.z},
				p1 = {x = indPos.x, y = indPos.y, z = indPos.z},
				isAutoBuildMode = true
			}

			-- Check for existing station
			debugLog("Checking for existing station...")
			local ok1, err1 = pcall(function()
				connectEval.recheckResultForStations(pairResult, true, api.type.enum.Carrier.ROAD)
			end)
			if not ok1 then
				debugLog("ERROR in recheckResultForStations: " .. tostring(err1))
			end
			debugLog("Existing station check done. station1=" .. tostring(pairResult.station1))
			if pairResult.station1 then
				debugLog("Found existing station: " .. tostring(pairResult.station1))
				stations[indIdx] = pairResult.station1
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end

			-- Need to build new station
			debugLog("Getting stations to build...")
			local ok2, stationsToBuild = pcall(function()
				return connectEval.getTruckStationsToBuild(pairResult)
			end)
			if not ok2 then
				debugLog("ERROR in getTruckStationsToBuild: " .. tostring(stationsToBuild))
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end
			debugLog("Stations to build: " .. (stationsToBuild and #stationsToBuild or "nil"))
			if not stationsToBuild or #stationsToBuild == 0 then
				debugLog("No stations to build for industry " .. indIdx)
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end

			local newProposal = api.type.SimpleProposal.new()
			local details = stationsToBuild[1]
			details.index = 1
			debugLog("Building station with constructionUtil...")
			local ok3, stationResult = pcall(function()
				return constructionUtil.buildTruckStationForIndustry(newProposal, details, pairResult, params)
			end)
			if not ok3 then
				debugLog("ERROR in buildTruckStationForIndustry: " .. tostring(stationResult))
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end

			if not stationResult then
				debugLog("buildTruckStationForIndustry returned nil")
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
				return
			end

			debugLog("Station build prepared, constructionIdx=" .. tostring(stationResult.constructionIdx))
			local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
			api.cmd.sendCommand(build, function(res, success)
				debugLog("Station " .. indIdx .. " build callback: success=" .. tostring(success))
				if success and stationResult.constructionIdx and res.resultEntities[stationResult.constructionIdx] then
					local entityId = res.resultEntities[stationResult.constructionIdx]
					local construction = util.getConstruction(entityId)
					if construction and construction.stations and construction.stations[1] then
						stations[indIdx] = construction.stations[1]
						debugLog("Station " .. indIdx .. " created: " .. tostring(stations[indIdx]))
					else
						debugLog("Could not extract station from construction")
					end
				else
					debugLog("Station build failed or no entity returned")
					buildsFailed = buildsFailed + 1
				end
				currentIndustryIndex = currentIndustryIndex + 1
				addWork(buildNextStation)
			end)
		end

		-- Start building stations one by one
		debugLog("Starting to build stations one by one...")
		buildNextStation()
	end)
end

local function buildIndustryConnection() 
	trace("buildIndustryConnection begin")
	local result = connectEval.evaluateNewIndustryConnectionRoadOrRail()
	if not result then 
		trace("buildIndustryConnection: No result found")
		return 
	end 
	trace("Result found for carrier", result.carrier)
	if result.carrier == api.type.enum.Carrier.WATER then 
		buildNewWaterConnections(result)
	elseif result.carrier == api.type.enum.Carrier.AIR then 
		buildNewIndustryAirConnection(result)
	elseif result.carrier == api.type.enum.Carrier.ROAD then 
		buildNewIndustryRoadConnection(result)
	elseif result.carrier == api.type.enum.Carrier.RAIL then 
		buildIndustryRailConnection(result)
	else 
		error("No carrier specified")
	end 

end 

local function welcomePanel() 
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local checkboxes = {}
	for k, v in pairs(aiEnableOptions) do 
		local checkbox =  api.gui.comp.CheckBox.new(_(k))
		checkboxes[k]=checkbox
		checkbox:setSelected(v, false)
		checkbox:onToggle(function(v)
			local optionsCopy = util.deepClone(aiEnableOptions)
			optionsCopy[k]=v 
			for k2, chkbx in pairs(checkboxes) do -- take the opportunity to sync with the rest of the checkboxes because otherwise a race may lose an update
				if k2 ~= k then 
					optionsCopy[k2]=chkbx:isSelected()
				end
			end
			addWork(function()
				api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","aiEnableOptions", "", {ignoreErrors=ignoreErrors, aiEnableOptions=optionsCopy}), standardCallback)
			end)
		end)
		boxlayout:addItem(checkbox)
	end 
	boxlayout:addItem(api.gui.comp.Component.new("VerticalLine"))
	boxlayout:addItem(text("Activity log:"))
	local colHeaders = { 
			text("New Connection"),
			text("Location1") ,
			text("Location2") ,
			text("Carrier") ,
	}
	 
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local function refreshTable(activityLog)
		trace("Being refresh activity table, got " ,#activityLog," to report")
		displayTable:deleteAll()
		local allButtons = {}
		local count = 0
		for i = #activityLog,1, -1  do
			local activityLogEntry = activityLog[i] 
			if activityLogEntry.activityType ~= "lineManager" then 
				displayTable:addRow({
					text(activityLogEntry.activityType),
					util.makelocateRow(activityLogEntry.location1),
					util.makelocateRow(activityLogEntry.location2),
					text(util.carrierNumberToString(activityLogEntry.carrier))
				})
			end
		end 
	end
	boxlayout:addItem(displayTable)

	local displayTable, refresh = lineManager.buildActivityLogTable() 
	boxlayout:addItem(api.gui.comp.Component.new("VerticalLine"))
	boxlayout:addItem(displayTable)
	
	local function doRefreshTables() 
		refresh(activityLog)
		refreshTable(activityLog)
	end 
	local refreshButton = util.newButton(_("Refresh"),"ui/button/xxsmall/replace@2x.tga")
	refreshButton:onClick(function() 
		addWork(doRefreshTables)
	end)
	local buttonLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	buttonLayout:addItem(refreshButton)
	local clearButton = util.newButton(_("Clear log"))
	clearButton:onClick(function() 
		addWork(function() 
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","clearActivityLog", "", {ignoreErrors=ignoreErrors}), standardCallback)
			addDelayedWork(doRefreshTables)
		end)
	end)
	buttonLayout:addItem(clearButton)
	boxlayout:addItem(buttonLayout) 
	-- textInput:setText()
	 
	local comp= api.gui.comp.Component.new("AIBuilderRoad")
	comp:setLayout(boxlayout)
	return {
		comp = comp,
		title = api.gui.comp.TextView.new(_("AutoManage")),
		refresh = function()
 
		end,
		init = function() end
	}
end

local function roadPanel() 
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	--[[local button = newButton(_('Create new industry connections'))
	boxlayout:addItem(button)
	button:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewIndustryRoadConnection", "", {ignoreErrors=ignoreErrors}), standardCallback)
		end)
	
	end)
	
	local button2 = newButton(_('Create new intercity bus connections'))
	boxlayout:addItem(button2)
	button2:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewTownRoadConnection", "", {ignoreErrors=ignoreErrors}), standardCallback)
		end)
	
	end)--]]
	local horizontalGroup = api.gui.layout.BoxLayout.new("HORIZONTAL");
	local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local busLaneChkBox = api.gui.comp.CheckBox.new(_("Add Bus Lanes"))
	local expressChkBox = api.gui.comp.CheckBox.new(_("Express?"))
	expressChkBox:setTooltip(_("Do not place intermediate stops on intercity bus line"))
	local busToggle = util.newToggleButton('Build Intercity Bus Route', "ui/button/medium/vehicle_bus.tga")
	local roadsOnly = util.newToggleButton('Upgrade roads only', "ui/button/medium/road.tga")
	local buildHiway = util.newToggleButton("Build highway", "ui/construction/categories/highway@2x.tga")
	local highwayChoices = api.gui.comp.ComboBox.new()
	highwayChoices:addItem(_("2 lane elevated"))
	highwayChoices:addItem(_("2 lane ground"))
	highwayChoices:addItem(_("2 lane underground"))
	highwayChoices:addItem(_("3 lane elevated"))
	highwayChoices:addItem(_("3 lane ground"))
	highwayChoices:addItem(_("3 lane underground"))
	highwayChoices:setSelected(0, false)
	highwayChoices:setEnabled(false, false)
	busToggle:setSelected(true, false)
	buttonGroup:add(busToggle)
	buttonGroup:add(roadsOnly)
	buttonGroup:add(buildHiway)

	buildHiway:onToggle(function(x) 
		highwayChoices:setEnabled(x, false)
	end)
	busToggle:onToggle(function(x) 
		busLaneChkBox:setEnabled(x and util.year()>= api.res.getBaseConfig().busLaneYearFrom, false)
		expressChkBox:setEnabled(x, false)
	end)
	local busLanesAvailable = util.year()>= api.res.getBaseConfig().busLaneYearFrom
	busLaneChkBox:setEnabled(busLanesAvailable,false)
	busLaneChkBox:setSelected(busLanesAvailable and util.year()>= 1980,false)
	buttonGroup:setOneButtonMustAlwaysBeSelected(true)
	horizontalGroup:addItem(busLaneChkBox)
	horizontalGroup:addItem(buttonGroup)
	horizontalGroup:addItem(highwayChoices)
	--boxlayout:addItem()
	--local upgradeRoadsOnlyChkbox = api.gui.comp.CheckBox.new(_("Upgrade roads only (for private transport)"))
	--boxlayout:addItem(upgradeRoadsOnlyChkbox)
	local townChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	
	local twoLane = "standard/country_medium_one_way_new.lua"
	local threeLane = "standard/country_large_one_way_new.lua"
	if api.res.streetTypeRep.find("country_medium_one_way_compact.lua")~=-1 and false then 
		twoLane ="country_medium_one_way_compact.lua"
	end 
	if api.res.streetTypeRep.find("country_large_one_way_new_compact.lua")~=-1 and false then 
		threeLane = "country_large_one_way_new_compact.lua"
	end 
	
	local optionsComp = {
		comp = horizontalGroup,
		getChoices = function()
			local choices = {}
			if buildHiway:isSelected() then 
				choices.buildHighway =  true
				local idx = highwayChoices:getCurrentIndex()
		 
				choices.preferredHighwayRoadType = idx >= 3 and    threeLane or twoLane
				choices.isUnderground = idx == 2 or idx == 5
				choices.isElevated = idx == 0 or idx == 3
			end
			return choices
			
		end
	
	}
	
	local function buildTownResultFn(result) 
		addWork(function()

		
			trace("The selected highway choices was ",idx)
			result.upgradeRoadsOnly=roadsOnly:isSelected()
			result.expressBusRoute = expressChkBox:isSelected()
			local choices = optionsComp.getChoices()
			for k, v in pairs(choices) do
				result[k]=v
			end 
			if busToggle:isSelected() then 
				result.addBusLanes = busLaneChkBox:isSelected()
			end 
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewTownRoadConnection", "", {ignoreErrors=ignoreErrors, result=result }), standardCallback)
		end)
	end
	
	local townChoicesPanel, townChoicesMapListener
	local function populateTownChoices() 
		if townChoicesPlaceHolder:getNumItems() > 0 then
			return
			--townChoicesPlaceHolder:removeItem(townChoicesPanel)
		end
		townChoicesPanel, townChoicesMapListener = connectEval.buildTownChoicesPanel(circle, api.type.enum.Carrier.ROAD, buildTownResultFn, optionsComp)
		townChoicesPlaceHolder:addItem(townChoicesPanel)
	end
	boxlayout:addItem(townChoicesPlaceHolder) 
	-- textInput:setText()
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local industryChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local function buildResultFn(result) 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewIndustryRoadConnection", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
		end)
	end
	local industryChoicesPanel, industryMapListener 
	local function populateIndustryChoices() 
		if industryChoicesPlaceHolder:getNumItems() > 0 then
			return
			--industryChoicesPlaceHolder:removeItem(industryChoicesPanel)
		end
		industryChoicesPanel, industryMapListener  = connectEval.buildIndustryChoicesPanel(circle, api.type.enum.Carrier.ROAD, buildResultFn)
		industryChoicesPlaceHolder:addItem(industryChoicesPanel)
	end
	boxlayout:addItem(industryChoicesPlaceHolder) 
	 
	 
	local comp= api.gui.comp.Component.new("AIBuilderRoad")
	comp:setLayout(boxlayout)
	local isInit = false
	local thisMapState  
	local thisIsMap
	return {
		comp = comp,
		title = util.textAndIcon("ROAD", "ui/icons/construction-menu/category_street@2x.tga"),
		refresh = function()
			isInit = false
			buildHiway:setEnabled(util.year()>=1925, false)
		end,
		init = function() 
			if not isInit then 
				populateTownChoices() 
				populateIndustryChoices()
				townChoicesMapListener(thisIsMap, thisMapState)
				industryMapListener(thisIsMap, thisMapState)
				isInit = true
			end
		end,
		onToggleMap = function(isMap, mapState, isActivePanel) 
			if industryChoicesPanel and isActivePanel then 
				townChoicesMapListener(isMap, mapState)
				industryMapListener(isMap, mapState)
			end 
			thisMapState=mapState 
			thisIsMap = isMap
		end 
	}
end

local function buildNewWaterConnections(result)
	-- Debug logging
	local f = io.open("/tmp/tf2_water_build.log", "a")
	if f then
		f:write(os.date("%H:%M:%S") .. " buildNewWaterConnections called\n")
		f:write("  result = " .. tostring(result) .. "\n")
		if result then
			f:write("  industry1 = " .. tostring(result.industry1) .. "\n")
			f:write("  industry2 = " .. tostring(result.industry2) .. "\n")
			if result.industry1 then
				f:write("  industry1.name = " .. tostring(result.industry1.name) .. "\n")
				f:write("  industry1.id = " .. tostring(result.industry1.id) .. "\n")
			end
			if result.industry2 then
				f:write("  industry2.name = " .. tostring(result.industry2.name) .. "\n")
				f:write("  industry2.id = " .. tostring(result.industry2.id) .. "\n")
			end
		end
		f:close()
	end

	if result then
		local msg = _("Connecting").." ".._("industry").." ".._(result.industry1.name).." "..("with").." ".._(result.industry2.name).." ".._("using").." ".._("ship")
		trace("******************************************************************************")
		trace(msg)
		trace("******************************************************************************")
		currentBuildParams = { status = msg,  carrier = api.type.enum.Carrier.WATER, location1= result.industry1.id,location2= result.industry2.id} 
		currentBuildParams.carrier = api.type.enum.Carrier.WATER
		currentBuildParams.location1 = result.industry1.id
		currentBuildParams.location2 = result.industry2.id
		result.location1 = result.industry1 
		result.location2 = result.industry2
	else 
		addWork(function() 
			result = connectEval.evaluateNewWaterIndustryConnections(circle)
			if not result then 
				trace("no new industry water connections were found")
				currentBuildParams = { status = _("no new industry water connections were found")} 
				return
			end
			buildNewWaterConnections(result) 
		end)
		return
	end
	addDelayedWork(function()
		-- Debug logging in addDelayedWork
		local f = io.open("/tmp/tf2_water_build.log", "a")
		if f then f:write(os.date("%H:%M:%S") .. " addDelayedWork callback executing\n") f:close() end

		local originalResult = result
		if not result then
			result = connectEval.evaluateNewWaterIndustryConnections(circle)
		else
			connectEval.recheckResultForStations(result, true, api.type.enum.Carrier.WATER)
			if not result.verticies1 or not result.verticies2 then
				local range = 400
				local verticies = connectEval.getAppropriateVerticiesForPair(result.industry1, result.industry2, {transhipmentRange = range}, range)
				if verticies then
					result.verticies1 = verticies.v1
					result.verticies2 = verticies.v2
				else
					f = io.open("/tmp/tf2_water_build.log", "a")
					if f then f:write(os.date("%H:%M:%S") .. " ERROR: Could not find water vertices\n") f:close() end
					trace("ERROR: Could not find water vertices for industries - no water nearby?")
					return
				end
			end
		end
		if not result then
			f = io.open("/tmp/tf2_water_build.log", "a")
			if f then f:write(os.date("%H:%M:%S") .. " No water connections found\n") f:close() end
			trace("no new industry water connections were found")
			return
		end

		f = io.open("/tmp/tf2_water_build.log", "a")
		if f then f:write(os.date("%H:%M:%S") .. " Creating proposal, verticies found\n") f:close() end

		local newProposal = api.type.SimpleProposal.new()
		trace("Needs transhipment?",result.needsTranshipment1,result.needsTranshipment2)
		if not result.station1 then 
			newProposal = constructionUtil.buildHarborForIndustry(newProposal,result.industry1, result.edge1, result.verticies1,result.needsTranshipment1, result, 1)
		else 
			constructionUtil.checkHarborForUpgrade(result.station1,result.needsTranshipment1, result, 1,newProposal)
		end		 
		if not result.station2 then 
			newProposal = constructionUtil.buildHarborForIndustry(newProposal,result.industry2, result.edge2, result.verticies2,result.needsTranshipment2,result, 2)
		else 
			constructionUtil.checkHarborForUpgrade(result.station2,result.needsTranshipment2,result, 2,newProposal)
		end
		if util.tracelog and false then 
			debugPrint(newProposal)
			trace("about to make testData")
			local testData = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
			debugPrint({testDataError=testData.errorState, testDataCollision=testData.collision})
		end 
		
		trace("About to build proposal creating harbours")
		local build = api.cmd.make.buildProposal(newProposal, initContext(), true)
		util.removeTrafficlights(build)
		if util.tracelog then 	
			--debugPrint(build)
		end
		trace("About to send command to build harbours")
		api.cmd.sendCommand(build, function(res, success) 
		trace("result of building harbours was ",success)
		addWork(function() 
			if success and constructionUtil.validateHarbourConnection(res, result)  then 
			
				local station1 
				local depot1 
				local station2  
				local depot2  
				if result.station1 then 
					station1 = result.station1
					depot1 =  constructionUtil.searchForShipDepot(result.industry1.position)
					if not depot1 then 
						depot1 =  constructionUtil.searchForShipDepot(util.getStationPosition(station1))
					end
				else 
					station1 = res.resultEntities[result.constructionIdxs[1].harbourIdx]
					if result.constructionIdxs[1].shipyardIdx then 
						depot1 = res.resultEntities[result.constructionIdxs[1].shipyardIdx]
					end
				end 
				if result.station2 then 
					station2 = result.station2
					depot2 =  constructionUtil.searchForShipDepot(result.industry2.position)
					if not depot2 then 
						depot2 =  constructionUtil.searchForShipDepot(util.getStationPosition(station2))
					end
				else 
					station2 = res.resultEntities[result.constructionIdxs[2].harbourIdx]
					if result.constructionIdxs[2].shipyardIdx then 
						depot2 = res.resultEntities[result.constructionIdxs[2].shipyardIdx]
					end
				end
				local function nextCallback(lineResult, success ) 
					if success then
						if currentBuildParams then
							markComplete()
						end 
					else 
						if currentBuildParams then 
							markFailed()
						end
						connectEval.markConnectionAsFailed(api.type.enum.Carrier.WATER, result.industry1.id, result.industry2.id)
						addWork(function() constructionUtil.rollbackHarbourConstruction(res) end)
					end
				end
				lineManager.createShipLine(result, station1, depot1, station2, depot2, nextCallback, result.cargoType, result.initialTargetLineRate)
			
			--connectIndustryToStationsAndDepot(res, result, stationsBuilt, roadDepotConnectNode, depotBuilt)
			else 
				if currentBuildParams then 
					markFailed()
				end
				connectEval.markConnectionAsFailed(api.type.enum.Carrier.WATER, result.industry1.id, result.industry2.id)
				if not originalResult then 
					--buildNewWaterConnections() 
				end 
				if util.tracelog then 
					debugPrint(res) 
				end
			end	
		end)
		standardCallback(res, success)
		end)
	end) 
		
end


local function buildNewPassengerWaterConnections(result)
	if result then 
		local msg = _("Connecting").." ".._("town").." ".._(result.town1.name).." "..("with").." ".._(result.town2.name).." ".._("using").." ".._("ship")
		trace("******************************************************************************")
		trace(msg)
		trace("******************************************************************************")
		currentBuildParams = { status = msg,carrier = api.type.enum.Carrier.AIR, location1= result.town1.id,location2= result.town2.id } 
		currentBuildParams.status2 = _("Searching for locations").."."
	else 
		currentBuildParams = { status = _("Evaluating passenger water connections"), status2 = _("Searching for locations").."."} 
	 
		addWork(function() 
			result = connectEval.evaluateNewWaterTownConnections(circle)
			if not result then 
				trace("No new passenger water connections were found")
				return 
			end
			buildNewPassengerWaterConnections(result) 
		end)
		return
	end 
	addDelayedWork(function() 
		local originalResult = result
		if result then 
			connectEval.recheckResultForStations(result, false, api.type.enum.Carrier.WATER)
		else 
			result = connectEval.evaluateNewWaterTownConnections(circle)
		end
		if not result then 
			trace("No new passenger water connections were found")
			return 
		end
	
		local newProposal = api.type.SimpleProposal.new()
		local station1Idx = -1000
		local station2Idx = -1000
		trace("The existing stations were",result.station1, result.station2)
		local success = true 
		if not result.station1 then 
			station1Idx = 1
			success = constructionUtil.buildHarborForTown(newProposal,result.town1, result.town2,result)
		else 
			constructionUtil.checkHarborForUpgrade(result.station1)
		end
		
		if not result.station2 then 
			station2Idx = 1+#newProposal.constructionsToAdd
			success = success and constructionUtil.buildHarborForTown(newProposal,result.town2, result.town1,result)
		else 
			constructionUtil.checkHarborForUpgrade(result.station2)
		end
		if not success then 
			trace("Unable to complete ")
			if currentBuildParams then 
				markFailed()
			end 
			connectEval.markConnectionAsFailed(api.type.enum.Carrier.WATER, result.town1.id, result.town2.id)
			return 
		end 
		
		trace("About to build proposal creating harbours")
		local build = api.cmd.make.buildProposal(newProposal, initContext(), true)
		util.removeTrafficlights(build)
		api.cmd.sendCommand(build, function(res, success) 
		trace("result of building harbours was ",success)
		addWork(function()
			if success then 

				local station1  
				local depot1 
				local busStation1  
				local roadDepot1   
				local station2 
				local depot2  
				local busStation2 
				local roadDepot2 
				if result.station1 then 
					station1 = result.station1
					depot1 =  constructionUtil.searchForShipDepot(result.town1.position)
					if not depot1 then 
						depot1 =  constructionUtil.searchForShipDepot(util.getStationPosition(station1))
					end
				else 
					station1 = res.resultEntities[result.constructionIdxs[1].harbourIdx]
					if result.constructionIdxs[1].shipyardIdx then 
						depot1 = res.resultEntities[result.constructionIdxs[1].shipyardIdx]
					end
					if result.constructionIdxs[1].harbourRoadStationIdx then
						busStation1 = res.resultEntities[result.constructionIdxs[1].harbourRoadStationIdx]
					end
					if result.constructionIdxs[1].harbourRoadDepotIdx then
						roadDepot1 = res.resultEntities[result.constructionIdxs[1].harbourRoadDepotIdx]
					end
				end
				if result.station2 then 
					station2 = result.station2
					depot2 =  constructionUtil.searchForShipDepot(result.town2.position)
					if not depot2 then 
						depot2 =  constructionUtil.searchForShipDepot(util.getStationPosition(station2))
					end
				else 
					station2 = res.resultEntities[result.constructionIdxs[2].harbourIdx]
					if result.constructionIdxs[2].shipyardIdx then 
						depot2 = res.resultEntities[result.constructionIdxs[2].shipyardIdx]
					end
					if result.constructionIdxs[2].harbourRoadStationIdx then
						busStation2 = res.resultEntities[result.constructionIdxs[2].harbourRoadStationIdx]
					end
					if result.constructionIdxs[2].harbourRoadDepotIdx then
						roadDepot2 = res.resultEntities[result.constructionIdxs[2].harbourRoadDepotIdx]
					end
				end 
				local validationResult = pathFindingUtil.validateShipPath(station1, station2)
				trace("ValidationResult of pathingFindingutil was ",validationResult)
				validationResult = true
				local alreadyCalledNetwork1 = false 
				local alreadyCalledNetwork2 = false 
				local function nextCallback(lineResult, success ) 
						trace("Received call from nextCallback:",alreadyCalledNetwork1,alreadyCalledNetwork2)
						util.clearCacheNode2SegMaps()
						if success then
							
							if not result.station1 then -- and not alreadyCalledNetwork1 then  
								alreadyCalledNetwork1 = true 
								addWork(function()constructionUtil.completeHarbourBusNetwork(result.town1, busStation1, roadDepot1, station1)end)
							end
							if not result.station2 then --  and not alreadyCalledNetwork2 then   
								alreadyCalledNetwork2 = true
								addWork(function()constructionUtil.completeHarbourBusNetwork(result.town2, busStation2,roadDepot2, station2)end)
							end
							 
							markComplete()
							 
							connectEval.markConnectionAsComplete(api.type.enum.Carrier.WATER, result.town1.id, result.town2.id)
						else 
							if currentBuildParams then 
								markFailed()
							end
							debugPrint({lineResult=lineResult})
							connectEval.markConnectionAsFailed(api.type.enum.Carrier.WATER, result.town1.id, result.town2.id)
							addWork(function() constructionUtil.rollbackHarbourConstruction(res) end)
							addWork(function() lineManager.removeLine(lineResult.resultEntity) end)
						end
					end
				if validationResult then 
					result.location1 = result.town1 
					result.location2 = result.town2
					
					addWork(function()lineManager.createShipLine(result, station1, depot1, station2, depot2, nextCallback,  "PASSENGERS",result.initialTargetLineRate)end)
				else 
					addWork(function() constructionUtil.rollbackHarbourConstruction(res) end)
				end 
				--connectIndustryToStationsAndDepot(res, result, stationsBuilt, roadDepotConnectNode, depotBuilt)
				
			else 
				markFailed()
				connectEval.markConnectionAsFailed(api.type.enum.Carrier.WATER, result.town1.id, result.town2.id)
				if not originalResult then 
				--	buildNewPassengerWaterConnections() 
				end
			end	
		end)
		standardCallback(res, success)
		end)
	end)

end 
local function waterPanel()
		local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
		--[[
	local button = newButton(_('Create new industry water connections'))
	boxlayout:addItem(button)
	button:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewWaterConnections", "", {ignoreErrors=ignoreErrors}), standardCallback)
		end)
	
	end) 
	
	local button2 = newButton(_('Create new passenger water connections'))
	boxlayout:addItem(button2)
	button2:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewPassengerWaterConnections", "", {ignoreErrors=ignoreErrors}), standardCallback)
		end)
	
	end) ]]--
	
	
	local function buildTownResultFn(result) 
	addWork(function()
		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewPassengerWaterConnections", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
	end)
	end
	local townChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local townChoicesPanel ,townChoicesMapListener
	local function populateTownChoices() 
		if townChoicesPlaceHolder:getNumItems() > 0 then
			return
			--townChoicesPlaceHolder:removeItem(townChoicesPanel)
		end
		townChoicesPanel, townChoicesMapListener = connectEval.buildTownChoicesPanel(circle, api.type.enum.Carrier.WATER, buildTownResultFn)
		townChoicesPlaceHolder:addItem(townChoicesPanel)
	end
	boxlayout:addItem(townChoicesPlaceHolder) 
	-- textInput:setText()
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine")) 
	local industryChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local function buildResultFn(result) 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewWaterConnections", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
		end)
	end
	local industryChoicesPanel, industryMapListener
	local function populateIndustryChoices() 
		if industryChoicesPlaceHolder:getNumItems() > 0 then
			return
		--	industryChoicesPlaceHolder:removeItem(industryChoicesPanel)
		end
		industryChoicesPanel, industryMapListener= connectEval.buildIndustryChoicesPanel(circle, api.type.enum.Carrier.WATER, buildResultFn)
		industryChoicesPlaceHolder:addItem(industryChoicesPanel)
	end
	boxlayout:addItem(industryChoicesPlaceHolder) 
	 
	local comp= api.gui.comp.Component.new("AIBuilderWater")
	comp:setLayout(boxlayout)
	local isInit = false
 
	local thisMapState  
	local thisIsMap
	return {
		comp = comp,
		title =  util.textAndIcon("WATER", "ui/icons/game-menu/ship@2x.tga"),
		refresh = function()
			isInit = false
			 
		end,
		init = function() 
			if not isInit then 
				populateTownChoices() 
				populateIndustryChoices()
				townChoicesMapListener(thisIsMap, thisMapState)
				industryMapListener(thisIsMap, thisMapState)
				isInit = true
			end
		end,
		onToggleMap = function(isMap, mapState, isActivePanel) 
			if industryChoicesPanel and isActivePanel then 
				townChoicesMapListener(isMap, mapState)
				industryMapListener(isMap, mapState)
			end 
			thisMapState=mapState 
			thisIsMap = isMap
		end 
	}
end

local function completeAirportBusNetwork(res, town, nodeDetail, callback)
	addWork(function() 
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps() 
		 
		local busStationConstr = res.resultEntities[2]
		local depotConstr = res.resultEntities[3]
		local newProposal = constructionUtil.completeAirportBusNetwork(depotConstr, busStationConstr, town, nodeDetail)
		if not newProposal then 
			trace("completeAirportBusNetwork: no action taken as no proposal was created")
			return 
		end
		local build = api.cmd.make.buildProposal(newProposal, initContext(), true)
		util.removeTrafficlights(build)
		api.cmd.sendCommand(build, function(res, success) 
			trace("result of completing airport bus network was ",success)
			if success then
				addDelayedWork(function() lineManager.setupTownBusNetwork( busStationConstr, town) end)
			end
			callback(res, success)
		end)
	end)
end

local function buildAirPortForTown(town, nodeDetails, callback, params)
	addWork(function() 
		local newProposal = api.type.SimpleProposal.new()
		util.lazyCacheNode2SegMaps() 
		local wrappedCallback = function(res, success, nodeDetail) 
			if success then
				completeAirportBusNetwork(res, town, nodeDetail, callback)
			else 
				callback(res,success)
			end
		end
		constructionUtil.buildAirPortForTown(town, nodeDetails,params,wrappedCallback)
	
	end)
end

local function buildNewIndustryAirConnection(result) 
	local msg = _("Connecting").." ".._("industry").." ".._(result.industry1.name).." "..("with").." ".._(result.industry2.name).." ".._("using").." ".._("airline")
	trace("******************************************************************************")
	trace(msg)
	trace("******************************************************************************")
	currentBuildParams = { status = msg, status2 =  _("Initialising")..".",  carrier = api.type.enum.Carrier.AIR, location1= result.industry1.id,location2= result.industry2.id } 
	currentBuildParams.status2 = _("Building").."."
	addWork(function() 
		addWork(function() constructionUtil.setupAirportForCargo(result.airport1,result.industry1, result) end)
		addWork(function() constructionUtil.setupAirportForCargo(result.airport2,result.industry2, result) end)
		addDelayedWork(function() 
			lineManager.setupCargoAirline(result, function(res, success) 
				if success then
					pcall(function() markComplete() end)
					connectEval.markConnectionAsComplete(api.type.enum.Carrier.AIR, result.industry1.id, result.industry2.id)
			
				else 
					markFailed()
				end 
			
			end)
		end)
	end)
end

local function evaluateAndBuildNewIndustryAirConnection() 
	addWork(function() 
		local param = {} 
		param.minDist =  util.getMaxMapHalfDistance()
		local result = connectEval.evaluateNewAirIndustryConnections(circle, param)
		if result then 
			buildNewIndustryAirConnection(result) 
		else 
			currentBuildParams = { status = _("No new industry air connections found")} 
		end 
	end)
end 

local function buildNewAirConnections(result) 
	if util.year() < api.res.constructionRep.get(api.res.constructionRep.find("station/air/airfield.con")).availability.yearFrom then 
		trace("aborting buildNewAirConnections as before availble")
		return
	end
	table.insert(workItems, function()
		if result then 
			connectEval.recheckResultForStations(result, false, api.type.enum.Carrier.AIR)
		else 
			local param = {}
			param.minDist =  util.getMaxMapHalfDistance()
			result = connectEval.evaluateNewPassengerAirTownConnection(circle, param)
			if not result then
				currentBuildParams = { status = _("No new passenger air connections found")} 
				return 
			end 
			result.isAutoBuildMode = true
		end
		 
		local msg = _("Connecting").." ".._("town").." ".._(result.town1.name).." "..("with").." ".._(result.town2.name).." ".._("using").." ".._("airline")
		trace("******************************************************************************")
		trace(msg)
		trace("******************************************************************************")
		currentBuildParams = { status = msg, carrier = api.type.enum.Carrier.AIR, location1= result.town1.id,location2= result.town2.id } 
		
		if result.station1 and result.station2 then 
			addWork(function()lineManager.createAirLine(result.town1, result.town2, result)end)
			markComplete()
			return
		end 
		currentBuildParams.status2 = _("Searching for locations").."."
		local expectedCallback = (result.station1 and 0 or 1) + (result.station2 and 0 or 1)
		local totalCallback = 0
		local function callback(res, success) 
			if success then
				totalCallback = totalCallback+1
				trace("airport construciton succes, ",totalCallback," of ", expectedCallback, " complete")
				if totalCallback == expectedCallback then
					markComplete()
					addWork(function()lineManager.createAirLine(result.town1, result.town2, result)end)
				end
			else
				markFailed()
				--debugPrint(res.errorState)
				connectEval.markConnectionAsFailed(api.type.enum.Carrier.AIR, result.town1.id, result.town2.id)
			end
		
		end
		local params = {} 
		params.isAutoBuildMode = result.isAutoBuildMode
		params.stationLocationScoreWeights = { 
			0, --distanceToTownCenter
			0, --distanceToOtherTown
			25, --nearbyEdges
			25, --nearbyConstructions
			0, --angleToVector
			100, --underwaterPoints
			50, --terrainHeightScore
			0, --distanceToOrigin
			0, -- angleToOtherTown
			100, -- nearbyBusStops
			0, -- intecept angle
		}
		local  nodepair = connectEval.evaluateBestPassengerStationLocations(result.town1, result.town2, params)
		 
		if not result.station1 then 
			buildAirPortForTown(result.town1, nodepair[1], callback, params)
		end 
		if not result.station2 then  
			buildAirPortForTown(result.town2, nodepair[2],callback, params)
		end
		 
	end) 
		
end

local function airPanel()
		local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	--[[local button = newButton(_('Create new air connections'))
	boxlayout:addItem(button)
	button:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewAirConnections", "", {ignoreErrors=ignoreErrors}), standardCallback)
		end)
	
	end) 
	-- textInput:setText()]]--
	 
	local function buildTownResultFn(result) 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewAirConnections", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
		end)
	end
	local townChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local townChoicesPanel 
	local townChoicesMapListener
	local function populateTownChoices() 
		if townChoicesPlaceHolder:getNumItems() > 0 then
			return 
--			townChoicesPlaceHolder:removeItem(townChoicesPanel)
		end
		townChoicesPanel, townChoicesMapListener = connectEval.buildTownChoicesPanel(circle, api.type.enum.Carrier.AIR, buildTownResultFn)
		townChoicesPlaceHolder:addItem(townChoicesPanel)
	end
	boxlayout:addItem(townChoicesPlaceHolder)  
	 
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxlayout:addItem(api.gui.comp.TextView.new(_("Air cargo routes require 2 or more existing airports")))
	local industryChoicesPlaceHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	local function buildResultFn(result) 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewIndustryAirConnection", "", {ignoreErrors=ignoreErrors, result=result}), standardCallback)
		end)
	end
	local industryChoicesPanel, industryMapListener
	local function populateIndustryChoices() 
		if industryChoicesPlaceHolder:getNumItems() > 0 then
			return
			--industryChoicesPlaceHolder:removeItem(industryChoicesPanel)
		end
		industryChoicesPanel, industryMapListener = connectEval.buildIndustryChoicesPanel(circle, api.type.enum.Carrier.AIR, buildResultFn)
		industryChoicesPlaceHolder:addItem(industryChoicesPanel)
	end
	boxlayout:addItem(industryChoicesPlaceHolder) 
	 
	local comp= api.gui.comp.Component.new("AIBuilderAir")
	comp:setLayout(boxlayout)
	local isInit = false
	
	local thisMapState  
	local thisIsMap
	return {
		comp = comp,
		title = util.textAndIcon("AIR", "ui/icons/game-menu/plane@2x.tga"),
		refresh = function()
			isInit = false
			 
		end,
		init = function() 
			if not isInit then 
				populateTownChoices() 
				populateIndustryChoices()
				townChoicesMapListener(thisIsMap, thisMapState)
				industryMapListener(thisIsMap, thisMapState)
				isInit = true
			end
		end,
		onToggleMap = function(isMap, mapState, isActivePanel) 
			if industryChoicesPanel and isActivePanel then 
				townChoicesMapListener(isMap, mapState)
				industryMapListener(isMap, mapState)
			end 
			thisMapState=mapState 
			thisIsMap = isMap
		end 
	}
end
local function setupTabs() 
	local layout = guiState.innerLayout
	for i = layout:getNumItems()-1, 0, -1 do 
		local item = layout:getItem(i)
		layout:removeItem(item)
		if i > 0 then 
			item:destroy()
		end
	end 
	local tab = api.gui.comp.TabWidget.new("NORTH")
	local function changeTabCallback(newIndex, emit) 
		trace("Call to changeTabCallback, ",newIndex,emit)
		tab:setCurrentTab(newIndex,emit)
	end
	guiState.panels = {
		
		buildTrainPanel(),
		roadPanel(),
		waterPanel(),
		airPanel(),
		lineManager.buildLinePanel(circle,changeTabCallback),
		lineManager.buildVehiclePanel(circle),
		townPanel.buildTownPanel(circle),
		upgradesPanel.buildUpgradesPanel(circle),
		straightenPanel.buildStraightenPanel(circle),
		--welcomePanel(),
		--paramHelper.buildParamPanel(),
		
	}
	local panels = guiState.panels 
	guiState.tab = tab
	
	if util.tracelog then 
		 table.insert(panels,  debugPanel()) 
		table.insert(panels,  welcomePanel()) 
	end
	
	for i, panel in pairs(panels) do 
		tab:addTab(panel.title, panel.comp)
	end
	tab:onCurrentChanged(function(x) 
		--statusPanel:setText(" ")
		--statusPanel2:setText(" ")
		--trace("Current panel was changed to ",x)
		if not x then return end
		local panel = guiState.panels[x+1]
		if not panel then return end
		xpcall(panel.init, err)
		if guiState.buttongroup:getSelectedIndex() == 2 then 
			if panel.onToggleMap then 
				addWork(function() panel.onToggleMap(true, guiState.mapState,true) end)
			end
		end 
		
	end)
	guiState.innerLayout:addItem(guiState.mapLayout)
	guiState.innerLayout:addItem(tab)
end 
local function buildWindow()
	
	local buttongroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	guiState.buttongroup = buttongroup
	local globalToggle = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Global')))
	local withinCircle =api.gui.comp.TextView.new(_('Within circle'))
	withinCircle:setTooltip(_("Find all entities to connect within the circle. \nIf only one entity is within the circle, it will find all the possible connection options for that entity"))
	local mapMode =api.gui.comp.TextView.new(_('Map mode'))
	mapMode:setTooltip(_("Select routes using map"))
	local radiusToggle = api.gui.comp.ToggleButton.new(withinCircle)
	local mapModeToggle = api.gui.comp.ToggleButton.new(mapMode)
	globalToggle:setSelected(true, false)
	buttongroup:add(globalToggle)
	buttongroup:add(radiusToggle)
	buttongroup:add(mapModeToggle)
	buttongroup:setOneButtonMustAlwaysBeSelected(true)
	local toplayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	toplayout:addItem(buttongroup)
	
	local slider = api.gui.comp.Slider.new(true) 
	slider:setMinimum(10)
	slider:setMaximum(120)
	slider:setStep(1)
	slider:setPageStep(1)
	slider:onValueChanged(function(x) 
		circleScale = x/100
	end)
	slider:setValue(50,false)
	local size = slider:calcMinimumSize()
	size.w = size.w+120
	slider:setMinimumSize(size)
	slider:setVisible(false, false)
	toplayout:addItem(slider)

	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	
	
	boxlayout:addItem(toplayout)
	statusPanel = {
		textDisplay =  api.gui.comp.TextView.new(" ")
	}
	statusPanel.location1Display = util.makeSimplifiedLocateRow(function() return statusPanel.location1 end)
	statusPanel.location2Display = util.makeSimplifiedLocateRow(function() return statusPanel.location2 end)
	statusPanel.location1Display:setVisible(false, false)
	statusPanel.location2Display:setVisible(false, false)
	statusPanel.workItemsDisplay = api.gui.comp.TextView.new(" ")
	function statusPanel.setDetail(status, location1, location2) 
		statusPanel.textDisplay:setText(status)
		 
		if statusPanel.location1 ~= location1 or statusPanel.location2 ~= location2 then 
			
			statusPanel.location1 = location1 
			statusPanel.location2 = location2 
			statusPanel.location1Display:setVisible(location1 ~= nil, false)
			statusPanel.location2Display:setVisible(location2 ~= nil, false)
		end
		  
	end 
	local statusLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	statusLayout:addItem(statusPanel.textDisplay)
	statusLayout:addItem(statusPanel.location1Display)
	statusLayout:addItem(statusPanel.location2Display)
	statusLayout:addItem(statusPanel.workItemsDisplay)
	statusPanel2 = api.gui.comp.TextView.new(" ")
	errorPanel = api.gui.comp.TextView.new(" ")
	toplayout:addItem(errorPanel)
	clearErrorButton = newButton(_("Clear"))
	toplayout:addItem(clearErrorButton)
	clearErrorButton:setVisible(false, false)
	clearErrorButton:onClick(function() 
		errorPanel:setText(" ")
		clearErrorButton:setVisible(false, false)
	end)
	
	guiState.innerLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	guiState.mapLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	 
	trace("Setting up tabs")
	setupTabs( ) 
	trace("Set up tabs complete")
	guiState.setupTabs = setupTabs
	--local streetUpgrade = buildStreetUpgradePanel()
	--local bridgeUpgrade =buildBridgeUpgradePanel()
	--local tramupgrade = buildTramUpgradePanel()
	--local trainUpgrade =buildTrainUpgradePanel()
	-- local straighten =

	 

	
	
	
	buttongroup:onCurrentIndexChanged(function(x)
		if x == 1 then 
			updateCircle()
			needsupdate = true
			slider:setValue(50,true)
			slider:setVisible(true, false)
		else 
			slider:setVisible(false, false)
			needsupdate = false
			remZone("ai_builder")
			circle.radius = math.huge
			
		end
		local isMapActive = x == 2
		addWork(function() 
			if isMapActive then 
				guiState.mapState = util.deepClone(minimap.guiState)
				minimap.buildMap(guiState.mapLayout, guiState.mapState)
			elseif guiState.mapState then 
				minimap.cleanup(guiState.mapLayout, guiState.mapState)
				guiState.mapState = nil
			end
			local selectedTab =  guiState.tab:getCurrentTabIndex()+1
			for i, panel in pairs(guiState.panels) do 
				if panel.onToggleMap then 
					xpcall(function() panel.onToggleMap(isMapActive, guiState.mapState, selectedTab==i) end, err)
				end
			end 
		end)
	end)
	 
 
	boxlayout:addItem(guiState.innerLayout)
	local bottomPanel =  api.gui.layout.BoxLayout.new("VERTICAL");
	abortButton = newButton(_('Abort'))
	
	--bottomPanel:addItem(abortButton)
	bottomPanel:addItem(statusLayout)
	bottomPanel:addItem(statusPanel2) 
	boxlayout:addItem(bottomPanel)
	abortButton:onClick(function() 
		workItems={} 
		abortButton:setEnabled(false)
		workComplete = true
	end)
	abortButton:setEnabled(false)
    local window = api.gui.comp.Window.new(_('AI Builder'), boxlayout)

	 window:addHideOnCloseHandler()
	 window:onClose(function() 
		globalToggle:setSelected(true,true)
	 end)
	 window:setResizable(true)
	return {
		window = window,
		refresh = function() 
			for i = 1, #guiState.panels do 
				guiState.panels[i].refresh()
			end
			--streetUpgrade.refresh()
			--bridgeUpgrade.refresh()
			--trainUpgrade.refresh()
			--tramupgrade.refresh()
			--xpcall(trainPanel.refresh, err)
			--tab:setCurrentTab(0,false) 
		end
	}
end
local init = false
local function createComponents()
	debuglog("createComponents start, lua used memory=",api.util.getLuaUsedMemory())
	local gameBar =  api.gui.util.getById("gameInfo.layout")
	if not gameBar then 
		print("COULD NOT FIND GAME BAR FOR SOME RAESON!")
		return
	end
   -- local label = gui.textView_create("gameInfo.AIBuilder.label", _('Global Upgrade'))
    --local button = gui.button_create("gameInfo.AIBuilder.button", label)
	local button = newButton(_('Ai builder'))
    local window = buildWindow()
	window.window:setVisible(false,false)
	button:onClick(function ()
		local mainView = game.gui.getContentRect("mainView")
		local y = math.floor(mainView[4]*(1/3)) 
		local x = math.floor(mainView[3]/2) 
		--window.window:setMaximumSize(api.gui.util.Size.new(math.floor(0.9*mainView[3]), math.floor(0.9*mainView[4])))
		window.window:setPosition(x,y)
		window.window:setVisible(true,false)
		xpcall(window.refresh,err)
    end)
    
    --game.gui.boxLayout_addItem("gameInfo.layout", gui.component_create("gameInfo.AIBuilder", "VerticalLine").id)
    --game.gui.boxLayout_addItem("gameInfo.layout", button.id)
	
	--while not gameBar do
	--	gameBar =  api.gui.util.getById("gameInfo.layout")
	--end
	if  gameBar then
		gameBar:addItem(api.gui.comp.Component.new("VerticalLine"))
		gameBar:addItem(button)
		init=true
	else 
		print("COULD NOT FIND GAME BAR FOR SOME RAESON!")
	end
	debuglog("createComponents end, lua used memory=",api.util.getLuaUsedMemory())
end

local function autoBuild()
	trace("Autobuild: lastUpdateGameTime=",lastUpdateGameTime," game ticks=",gameTicks)
	local hadWorkOutstanding = #workItems > 0
	xpcall(lineManager.checkNoPathVehicles,err)
	--if lastUpdateGameTime - lastCheckedLines >  300 then -- 5 mins (game time)
--		lastCheckedLines =lastUpdateGameTime
		trace("Autobuild triggering lines check")
		xpcall(lineManager.checkLinesAndUpdate, err)
	--else 
		--trace("Autobuild NOT doing check")
	--end 
	xpcall(townPanel.autoExpandAllCoverage,err)
	if hadWorkOutstanding then 
		trace("Exiting auto build while work outstanding") 
		return
	end 
	trace("About to evaluate bestNewConnection")
	local result = connectEval.evaluateBestNewConnection() 
	trace("Autobuild: found result?",result~=nil)
	if result == "sleeping" then -- skip the "No new connections" message
		return 
	end
	if not result then 
		currentBuildParams = { status = _("No new connections were found") }
		return 
	end 
	result.isAutoBuildMode = true 
	if result.isCompleteRoute then 
		buildCompleteRoute(result)
		return 
	end 
	
	if result.isCargo then 
		if result.carrier == api.type.enum.Carrier.WATER then 
			buildNewWaterConnections(result)
		elseif result.carrier == api.type.enum.Carrier.AIR then 
			buildNewIndustryAirConnection(result)
		elseif result.carrier == api.type.enum.Carrier.ROAD then 
			buildNewIndustryRoadConnection(result)
		elseif result.carrier == api.type.enum.Carrier.RAIL then 
			buildIndustryRailConnection(result)
		else 
			error("No carrier specified")
		end 
	else 
		if result.carrier == api.type.enum.Carrier.WATER then 
			buildNewPassengerWaterConnections(result)
		elseif result.carrier == api.type.enum.Carrier.AIR then 
			buildNewAirConnections(result)
		elseif result.carrier == api.type.enum.Carrier.ROAD then 
			buildNewTownRoadConnection(result)
		elseif result.carrier == api.type.enum.Carrier.RAIL then 
			buildNewPassengerTrainConnections(result)
		else 
			error("No carrier specified")
		end
	end 
end
local function doTriggerWork()
	if util.getAvailableBudget() <= 0 then 
		trace("Not doing any work due to lack of budget")
	end
	if aiEnableOptions.autoEnableFullManagement then 
		xpcall(autoBuild,err)
		return
	end 
	
	local works = {} 
	if aiEnableOptions.autoEnablePassengerTrains then 
		table.insert(works, buildNewPassengerTrainConnections)
	end
	if aiEnableOptions.autoEnableFreightTrains and aiEnableOptions.autoEnableTruckFreight then 
		table.insert(works, buildIndustryConnection)
	else 
		if aiEnableOptions.autoEnableFreightTrains then 
			table.insert(works, buildIndustryRailConnection)
		end
		if aiEnableOptions.autoEnableTruckFreight then 
			table.insert(works, buildNewIndustryRoadConnection)
		end
	end
	if aiEnableOptions.autoEnableIntercityBus then 
		table.insert(works, buildNewTownRoadConnection)
	end
	if aiEnableOptions.autoEnableShipFreight then 
		table.insert(works, buildNewWaterConnections)
	end
	if aiEnableOptions.autoEnableShipPassengers then 
		table.insert(works, buildNewPassengerWaterConnections)
	end
	if aiEnableOptions.autoEnableAirPassengers then 
		table.insert(works, buildNewAirConnections)
	end
	if aiEnableOptions.autoEnableLineManager then 
		table.insert(works, checkLines)
	end
	if aiEnableOptions.autoEnableHighwayBuilder then 
		table.insert(works, buildNewHighway)
	end
	if aiEnableOptions.autoEnableAirFreight then 
		table.insert(works, evaluateAndBuildNewIndustryAirConnection)
	end 
	if aiEnableOptions.autoExpandBusCoverage and aiEnableOptions.autoExpandCargoCoverage then 
		table.insert(works, townPanel.autoExpandAllCoverage) -- more optimal than doing indivudally
	else 
		if aiEnableOptions.autoEnableExpandingBusCoverage then 
			table.insert(works, townPanel.autoExpandBusCoverage)
		end 
		
		if aiEnableOptions.autoEnableExpandingCargoCoverage then 
			table.insert(works, townPanel.autoExpandCargoCoverage)
		end 
	end 
	if #works == 0 then return end
	connectEval.isAutoBuildMode = true
	math.randomseed(os.clock()+lastUpdateGameTime)
	xpcall(works[math.random(1,#works)],err)
end

local function forceImmedateDepartures() 
	local vehicles = api.engine.system.transportVehicleSystem.getVehiclesWithState(api.type.enum.TransportVehicleState.AT_TERMINAL)
	for i, vehicle in pairs(vehicles) do 
		local vehicleComp = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		if vehicleComp.timeUntilLoad <= 0 and vehicleComp.timeUntilDeparture > 0 then 
			local go = api.cmd.make.setVehicleShouldDepart(vehicle)
			api.cmd.sendCommand(go, function(res, success)
				--trace("Result of asking vehicle",vehicle,"to go was",success," at tick",gameTicks)
			end)
		end 
	end 
end

local isCalled = false
local currentExecution
local function tickUpdate()
	isEngineThread = true

	-- Simple file-based IPC polling (direct Python <-> Lua communication)
	local ipc_ok, simple_ipc = pcall(require, "simple_ipc")
	if ipc_ok and simple_ipc and simple_ipc.poll then
		pcall(simple_ipc.poll)
	end

	if #activityLog > 100 then -- prevent this becoming excessive it slows down saves
		table.remove(activityLog, 1)
	end
	gameTicks = gameTicks + 1
	if false and util.tracelog and game.interface.getGameSpeed() > 0 and (#workItems>0 or #backgroundWorkItems>0) then 
		trace("tickUpdate: there were",#workItems," workItems and ",#backgroundWorkItems," backgroundWorkItems at gameTicks=",gameTicks)
	end
	if not isCalled and util.tracelog then 
		 game.interface.setGameSpeed(0)
		isCalled = true
	end
	if util.tracelog and game.interface.getGameSpeed() == 0 then 
		return 
	end
	local gameTime = game.interface.getGameTime().time 
	if currentExecution and coroutine.status(currentExecution) == "suspended" then
		 coroutine.resume(currentExecution)
	elseif #workItems > 0 then
		--local oldSpeed = game.interface.getGameSpeed() -- trying to prevent the game auto-notching down the speed
		--game.interface.setGameSpeed(0)
		
		-- N.B. coroutines do not work with legacy functions and translation function 
		--currentExecution = coroutine.create(function() 
			xpcall(table.remove(workItems, #workItems), err)
		--end)
		--coroutine.resume(currentExecution)
		--game.interface.setGameSpeed(oldSpeed)
	elseif #workItems2 > 0 then  
		xpcall(table.remove(workItems2, #workItems2), err)
	elseif not lastUpdateGameTime or  gameTime - lastUpdateGameTime > minimumTickInterval then 
		if gameTime > 30 then -- allow short time to establish production 
			lastUpdateGameTime = gameTime
			doTriggerWork()
		end
	end
	
	if #backgroundWorkItems > 0 then 
		xpcall(table.remove(backgroundWorkItems, #backgroundWorkItems), err)
	end 
	if false and util.tracelog and #workItems == 0 and not errorMessage and #api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer()) > 0 then 
		errorMessage = "Problem lines found"
		errorPayload = errorMessage
	end 
	
	if errorMessage and aiEnableOptions.pauseOnError then 
		 game.interface.setGameSpeed(0)
	end
	
	if isForceImmediateDepartures and gameTicks%8 == 0 then 
		xpcall(forceImmedateDepartures, err)
	end 
end
local function checkAndUpdateStatus()
	if statusPanel2 and statusPanel2:getText() then 
		if not lastStatusUpdate then 
			lastStatusUpdate = os.clock()
		end
		if os.clock() - lastStatusUpdate > 2 then 
			local text = statusPanel2:getText()
			if string.sub(text,-1) == "." and string.len(text) < 250 then 
				statusPanel2:setText(text..".")
				lastStatusUpdate = os.clock()
			end
		end
	end
	if statusPanel then 
		if statusPanel.workItemsRemaining ~= statusPanel.workItemsRemainingDisplayed or statusPanel.backgroundWorkItemsRemaining ~= statusPanel.backgroundWorkItemsRemainingDisplayed then
			--trace("Updating workItemsDisplay")
			local text =  _("Work remaining:").." "..tostring(statusPanel.workItemsRemaining).." ".._("Vehicle orders remaining countdown:").." "..tostring(statusPanel.backgroundWorkItemsRemaining)
			if statusPanel.workItemsRemaining ==0  and statusPanel.backgroundWorkItemsRemaining == 0 then 
				text = " "
			end 
			
			statusPanel.workItemsDisplay:setText(text)
		
			statusPanel.workItemsRemainingDisplayed = statusPanel.workItemsRemaining
			statusPanel.backgroundWorkItemsRemainingDisplayed = statusPanel.backgroundWorkItemsRemaining 
			
		end 
	end 
end

local function displayErrorPayload(payload) 	
	local textView = api.gui.comp.TextView.new(payload)
	local window = api.gui.comp.Window.new(_('Error'), textView)
	window:setVisible(true,false)
	window:addHideOnCloseHandler()
end
local function checkAndUpdateGameSpeed() 
	if isTurboChargeMode then 
		local targetSpeed = targetGameSpeed or 16
		local gameSpeed =  game.interface.getGameSpeed()
		if gameSpeed < targetSpeed and gameSpeed > 0 then 
			--trace("Found gameSpeed < targetSpeed, sending command",gameSpeed)
			api.cmd.sendCommand(api.cmd.make.setGameSpeed(targetSpeed)) --, function (res, success) trace("Result of change game speed was",success)end)
		end 
	end
end 
function data()
    return {
		save = function()
			--trace("ai_builder_script: Begin save, isGuiThread?",isGuiThread," isEngineThread?",isEngineThread,"isGuiInitThread?",isGuiInitThread)
			if util.tracelog and currentBuildParams and currentBuildParams.status2 == _("Failed") and not errorPayload and not errorMessage then 
				
				errorPayload = currentBuildParams.status2
				if currentBuildParams.status then 
					errorPayload = errorPayload.." "..currentBuildParams.status 
				end 
				errorMessage = errorPayload
			end 
			local state = {
				nextTrainLine = lineManager.nextTrainLine,
				nextLineColor = lineManager.nextLineColor,
				errorMessage = errorMessage,
				errorPayload = errorPayload,
				signalCount = routeBuilder.signalCount,
				aiEnableOptions = aiEnableOptions,
				status = currentBuildParams and currentBuildParams.status or nil,
				location1 = currentBuildParams and currentBuildParams.location1 or nil,
				location2 = currentBuildParams and currentBuildParams.location2 or nil,
				status2 = currentBuildParams and currentBuildParams.status2 or nil,
				costs = currentBuildParams and currentBuildParams.costs or nil,
				activityLog = activityLog,
				workItemsRemaining = #workItems,
				backgroundWorkItemsRemaining = #backgroundWorkItems,
				lineLastUpdateTime=lineManager.lineLastUpdateTime ,
				lineLastCheckedTime=lineManager.lineLastCheckedTime  ,
				--failedConnections = connectEval.failedConnections
				--completedConnections = connectEval.completedConnections
			}
			if currentBuildParams and currentBuildParams.status2 == _("Completed") then 
				currentBuildParams = nil
			end
			if errorMessage then	
				errorMessage = nil
				errorPayload = nil
				if util.tracelog and currentBuildParams and currentBuildParams.status2 == _("Failed") then 
					currentBuildParams.status2 = nil
				end
			end
			--trace("ai_builder_script: End save, isGuiThread?",isGuiThread," isEngineThread?",isEngineThread,"isGuiInitThread?",isGuiInitThread)
			return state

		end,
		load = function(loadedState)
			--trace("ai_builder_script: Begin load, isGuiThread?",isGuiThread," isEngineThread?",isEngineThread,"isGuiInitThread?",isGuiInitThread)
			if loadedState then
				if loadedState.nextTrainLine and loadedState.nextTrainLine > lineManager.nextTrainLine then
					lineManager.nextTrainLine = loadedState.nextTrainLine
				end
				if loadedState.lineLastUpdateTime then 
					lineManager.lineLastUpdateTime = loadedState.lineLastUpdateTime
				end 
				if loadedState.lineLastCheckedTime then 
					lineManager.lineLastCheckedTime = loadedState.lineLastCheckedTime
				end 
				if loadedState.nextLineColor and loadedState.nextLineColor > lineManager.nextLineColor then
					lineManager.nextLineColor = loadedState.nextLineColor
				end
				if loadedState.errorMessage and errorPanel then
					errorPanel:setText(loadedState.errorMessage)
					if loadedState.errorPayload then 
						xpcall(function() displayErrorPayload(loadedState.errorPayload)end, err)
						if util.tracelog then 
							
						end
					end 
				end
				if loadedState.backgroundWorkItemsRemaining  and statusPanel then 
					statusPanel.backgroundWorkItemsRemaining = loadedState.backgroundWorkItemsRemaining
				end
				if loadedState.workItemsRemaining  and statusPanel then 
					statusPanel.workItemsRemaining = loadedState.workItemsRemaining
				end 
				if loadedState.status and statusPanel then
					statusPanel.setDetail(loadedState.status, loadedState.location1, loadedState.location2)
				end
				if loadedState.status2 and statusPanel2 then
					statusPanel2:setText(loadedState.status2)
					if statusPanel3 and commandSentTime then 
						local text = "Completed in "..tostring(os.clock()-commandSentTime)
						if loadedState.costs then 
							text = text.." with cost"..api.util.formatMoney(loadedState.costs)
						end 
						statusPanel3:setText(text)
						commandSentTime = nil
					end 
				end
				if loadedState.failedConnections then 
					connectEval.failedConnections = failedConnections
				end
				if loadedState.completedConnections then 
					connectEval.completedConnections = completedConnections
				end
				if loadedState.signalCount then
					routeBuilder.signalCount = loadedState.signalCount
				end
				if loadedState.aiEnableOptions then 
					for k, v in pairs( loadedState.aiEnableOptions)  do 
						aiEnableOptions[k]=v -- this allows for adding more options
					end
				end 
				if loadedState.activityLog then 
					activityLog = loadedState.activityLog
				end 
			end
			--trace("ai_builder_script: End load, isGuiThread?",isGuiThread," isEngineThread?",isEngineThread,"isGuiInitThread?",isGuiInitThread)
		end,
		guiInit = function()
			isGuiInitThread = true
			createComponents()
		end,
		update =  function() xpcall(tickUpdate,err) end ,
        guiUpdate = function()
			isGuiThread = true 
			if not init then xpcall(createComponents,err) end
            if #workItems > 0 then 
				xpcall(table.remove(workItems, #workItems), err)
				--collectgarbage() 
			end
			if hascircle then 
				xpcall(updateCircle,err)
			end 
			xpcall(checkAndUpdateStatus, err)
			if #backgroundWorkItems > 0 then 
				xpcall(table.remove(backgroundWorkItems, #backgroundWorkItems), err)
			end 
			if errorPayload then 
				pcall(function() displayErrorPayload(errorPayload) end)
				errorPayload = nil 
			end
			if isTurboChargeMode then 
				xpcall(checkAndUpdateGameSpeed, err)
			end
        end,
		guiHandleEvent = function(id, name, param)
			if name == "select" and userSelectedListener then 
				userSelectedListener(param)
			end
			if guiEventListener then 
				guiEventListener(id, name, param)
			end 
			if name == "builder.apply"  then
				util.clearCacheNode2SegMaps()
			end 
			if isShowGuiEvents then
				 trace("guiHandleEvent with ",id,name,param, " guiEventListener was ",guiEventListener)
				if type(param)=="table" then 
					--debugPrint(param)
				end
				if name == "builder.apply"  then
					--debugPrint({lastParam=lastParam, param=param})
				else 
					
				end
			end

			 
		end,
		handleEvent = function (src, id, name, param)
			-- Log received events for debugging
			local f = io.open("/tmp/tf2_events.log", "a")
			if f then
				f:write(os.date("%H:%M:%S") .. " EVENT src=" .. tostring(src) .. " id=" .. tostring(id) .. "\n")
				f:close()
			end

			-- Accept events from ai_builder_script OR from any source if id matches known commands
			if src == "ai_builder_script" or id == "buildNewIndustryRoadConnection" or id == "aiEnableOptions" or id == "buildIndustryRailConnection" or id == "buildIndustryRoadConnectionEval" or id == "buildNewWaterConnections" then

				ignoreErrors = param and param.ignoreErrors or false
				if id == "buildIndustryRailConnection" then
					buildIndustryRailConnection(param.result, param)
				elseif id == "buildNewPassengerTrainConnections" then
					buildNewPassengerTrainConnections(param.result)
				elseif id == "buildIndustryRoadConnectionEval" then
					-- New handler: Run evaluation with preSelectedPair, then build
					local function debugLog(msg)
						local f = io.open("/tmp/tf2_build_debug.log", "a")
						if f then f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n") f:close() end
					end

					-- Debug: show preSelectedPair contents
					debugLog("buildIndustryRoadConnectionEval received event")
					debugLog("  param type=" .. type(param))
					if param then
						debugLog("  param.preSelectedPair type=" .. type(param.preSelectedPair))
						if param.preSelectedPair then
							debugLog("  param.preSelectedPair[1]=" .. tostring(param.preSelectedPair[1]) .. " type=" .. type(param.preSelectedPair[1]))
							debugLog("  param.preSelectedPair[2]=" .. tostring(param.preSelectedPair[2]) .. " type=" .. type(param.preSelectedPair[2]))
						end
					end

					addDelayedWork(function()
						debugLog("buildIndustryRoadConnectionEval: Starting evaluation...")

						-- Verify we have the pair
						if not param or not param.preSelectedPair then
							debugLog("ERROR: No preSelectedPair in param")
							return
						end

						local id1 = param.preSelectedPair[1]
						local id2 = param.preSelectedPair[2]
						debugLog("  Using id1=" .. tostring(id1) .. " id2=" .. tostring(id2))

						local evalParams = {
							townSearchDistance = townSearchDistance,
							maxDist = math.huge,
							preSelectedPair = {id1, id2}
						}
						debugLog("  evalParams.preSelectedPair=" .. tostring(evalParams.preSelectedPair[1]) .. "," .. tostring(evalParams.preSelectedPair[2]))

						local evalOk, evalResult = pcall(function()
							return connectEval.evaluateNewIndustryConnectionWithRoads(circle, evalParams)
						end)
						if not evalOk then
							debugLog("buildIndustryRoadConnectionEval: ERROR in evaluation: " .. tostring(evalResult))
							return
						end
						if not evalResult then
							debugLog("buildIndustryRoadConnectionEval: No result from evaluation")
							return
						end
						debugLog("buildIndustryRoadConnectionEval: Got result, building...")
						debugLog("  result.industry1=" .. tostring(evalResult.industry1 and evalResult.industry1.name or "nil"))
						debugLog("  result.industry2=" .. tostring(evalResult.industry2 and evalResult.industry2.name or "nil"))
						evalResult.isAutoBuildMode = true
						buildNewIndustryRoadConnection(evalResult)
					end)
				elseif id == "buildNewIndustryRoadConnection" then
					print("[IPC_TRACE] EVENT RECEIVED: buildNewIndustryRoadConnection")
					print("[IPC_TRACE]   param.cargoFilter=" .. tostring(param.cargoFilter))
					print("[IPC_TRACE]   param.result=" .. tostring(param.result))
					if param then
						for k,v in pairs(param) do
							print("[IPC_TRACE]   param." .. tostring(k) .. "=" .. tostring(v))
						end
					end
					buildNewIndustryRoadConnection(param.result, param.cargoFilter)
				elseif id == "buildNewTownRoadConnection" then
					buildNewTownRoadConnection(param.result)
				elseif id == "buildCargoToTown" then
					-- Build cargo delivery from industry to town (completes supply chains)
					addDelayedWork(function()
						local function debugLog(msg)
							local f = io.open("/tmp/tf2_cargo_to_town_debug.log", "a")
							if f then f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n") f:close() end
						end

						debugLog("buildCargoToTown: Starting...")

						if not param or not param.preSelectedPair then
							debugLog("ERROR: No preSelectedPair in param")
							return
						end

						local ind_id = param.preSelectedPair[1]
						local town_id = param.preSelectedPair[2]
						debugLog("  Industry ID: " .. tostring(ind_id))
						debugLog("  Town ID: " .. tostring(town_id))

						-- Get entities
						local industry = util.getEntity(ind_id)
						local town = util.getEntity(town_id)

						if not industry then
							debugLog("ERROR: Industry not found: " .. tostring(ind_id))
							return
						end
						if not town then
							debugLog("ERROR: Town not found: " .. tostring(town_id))
							return
						end

						debugLog("  Industry: " .. tostring(industry.name))
						debugLog("  Town: " .. tostring(town.name))

						-- Convert positions to vec3 format {x=..., y=..., z=...}
						local function posToVec3(pos)
							if not pos then return {x=0, y=0, z=0} end
							return {
								x = pos[1] or pos.x or 0,
								y = pos[2] or pos.y or 0,
								z = pos[3] or pos.z or 0
							}
						end

						local p0 = posToVec3(industry.position)
						local p1 = posToVec3(town.position)

						debugLog("  p0 (industry): x=" .. tostring(p0.x) .. " y=" .. tostring(p0.y))
						debugLog("  p1 (town): x=" .. tostring(p1.x) .. " y=" .. tostring(p1.y))

						-- Use evaluateBestNewConnection approach for cargo->town delivery
						-- This handles finding suitable station locations in town
						local evalParams = {
							preSelectedPair = {ind_id, town_id},
							cargoFilter = param.cargoFilter,
							maxDist = 1e9,
							isTownDelivery = true,
							resultsToReturn = 1  -- Ensure we get an array back, not a single result
						}

						debugLog("  Calling evaluateNewIndustryConnectionWithRoads for cargo delivery to town")

						-- Use the proper evaluation function that takes parameters and returns a list
						local evalOk, evalResults = pcall(function()
							return connectEval.evaluateNewIndustryConnectionWithRoads(util.hugeCircle(), evalParams)
						end)

						if not evalOk then
							debugLog("ERROR in pcall: " .. tostring(evalResults))
						elseif evalResults and type(evalResults) == "table" and #evalResults > 0 then
							-- Get the best result (first one is typically sorted best)
							local bestResult = evalResults[1]
							debugLog("  Evaluation found " .. #evalResults .. " results, using best one")
							debugLog("  Best: " .. tostring(bestResult.industry1 and bestResult.industry1.name) .. " -> " .. tostring(bestResult.industry2 and bestResult.industry2.name))
							bestResult.isAutoBuildMode = true
							buildNewIndustryRoadConnection(bestResult)
						else
							debugLog("  No valid results from evaluation (got: " .. type(evalResults) .. ", len=" .. tostring(evalResults and #evalResults or "nil") .. ")")
							-- Fallback: try building a simple route to town
							debugLog("  Trying fallback: buildNewTownRoadConnection...")
							local townResult = {
								town1 = {id = ind_id, name = industry.name, position = p0},
								town2 = {id = town_id, name = town.name, position = p1},
								carrier = api.type.enum.Carrier.ROAD,
								isCargo = true,
								cargoType = param.cargoFilter
							}
							local fallbackOk, fallbackErr = pcall(function()
								buildNewTownRoadConnection(townResult)
							end)
							if not fallbackOk then
								debugLog("  Fallback also failed: " .. tostring(fallbackErr))
							end
						end
					end)
				elseif id == "buildNewWaterConnections" then
					-- Debug: write to file directly
					local f = io.open("/tmp/tf2_water_debug.log", "a")
					if f then
						f:write(os.date("%H:%M:%S") .. " WATER EVENT RECEIVED\n")
						f:write("  param.result = " .. tostring(param.result) .. "\n")
						if param.result then
							f:write("  industry1 = " .. tostring(param.result.industry1) .. "\n")
							f:write("  industry2 = " .. tostring(param.result.industry2) .. "\n")
						end
						f:close()
					end
					trace("=== WATER EVENT RECEIVED ===")
					buildNewWaterConnections(param.result)
				elseif id == "buildNewPassengerWaterConnections" then
					buildNewPassengerWaterConnections(param.result)
				elseif id == "buildNewAirConnections" then
					buildNewAirConnections(param.result)
				elseif id == "buildNewIndustryAirConnection" then 
					buildNewIndustryAirConnection(param.result)
				elseif id == "enableAutoBuild" then
					isAutoAiEnabled = param.isAutoAiEnabled  
				elseif id == "checkLines" then
					checkLines(param)
				elseif id == "aiEnableOptions" then 
					aiEnableOptions = param.aiEnableOptions
					connectEval.isAutoBuildMode = true
				elseif id == "connectTowns" then
					addWork(function() connectTowns({{param.town1, param.town2}}, 1) end)
				elseif id == "buildCompleteRoute" then
					addWork(function() buildCompleteRoute(param) end)
				elseif id == "buildMultiStopCargoRoute" then
					addWork(function() buildMultiStopCargoRoute(param) end)
				elseif id =="checkAndUpdateLine" then
					addWork(function() lineManager.checkAndUpdateLine(param.lineId, param.paramOverrides) end)
				elseif id =="replaceLineVehicles" then 
					addWork(function() lineManager.replaceLineVehicles(param.lineId, param)end)
				elseif id =="repositionBusStops" then 
					addWork(function() constructionUtil.repositionBusStops(param.town, lineManager.getCallbackAfterBusChanged(param.town) )end)
				elseif id =="buildNewTownBusStop" then 
					addWork(function() townPanel.buildNewTownBusStop(param) end)
				elseif id =="addBusLanes" then 
					addWork(function() townPanel.addBusLanes(param) end)
				elseif id =="developStationOffside" then 
					addWork(function() constructionUtil.developStationOffside(param) end)
				elseif id =="doUpgrade" then 
					addWork(function() upgradesPanel.doUpgrade(param) end)
				elseif id =="doStraighten" then 
					addWork(function() straightenPanel.doStraighten(param) end)
				elseif id == "buildMainConnectionHighways" then 
					addWork(function() buildMainConnectionHighways(param) end)
				elseif id =="printLuaUsedMemory" then
					print("luaUsedMemory (from handleEvent):",math.floor(api.util.getLuaUsedMemory()/1024/1024).."MB")
					addWork(function() print("luaUsedMemory (from callback):",math.floor(api.util.getLuaUsedMemory()/1024/1024).."MB")end)
				elseif id =="clearActivityLog" then 
					activityLog = {}
					addWork(function() activityLog = {} end) -- not sure why needed
				elseif id =="upgradeBusiestLines" then 
					addWork(function() lineManager.upgradeBusiestLines() end)
				elseif id =="upgradeBusiestRoadLines" then 
					addWork(function() lineManager.upgradeBusiestRoadLines() end)
				elseif id == "doBuild" then
					doBuild(param)
				elseif id == "showEvents" then
					isShowEvents = param.isShowEvents
				elseif id == "forceDepartures" then
					isForceImmediateDepartures = param.isForceImmediateDepartures
				elseif id == "runCleanUpTest" then 
					addWork(function() routeBuilder.runCleanUpTest(param) end)
				elseif id == "reload" then 
					addWork(doReload)
				elseif id == "clearWork" then 
					workItems = {}
					backgroundWorkItems = {}
				elseif id == "upgradeMainConnections" then 
					addWork(routeBuilder.upgradeMainConnections)
				end 				
			else 
			
				if isShowEvents then 
					local ignoredEvents = {
						["guidesystem.lua" ]=true,
						["SimPersonSystem"]=true,
						["SimCargoSystem"]=true
					
					}
					if not ignoredEvents[src or ""] and  name~="JOURNAL_ENTRY" and not ignoredEvents[id] then 
						trace("handle event for ",src, id, name, param)
						if util.tracelog then 
							debugPrint(param)
						end 
					end
				end 
				if src ~= "guidesystem.lua" then 
					--trace("Ignoring handle event for ",src, id, name, param)
				end
			end 
		

        end
    }
end 