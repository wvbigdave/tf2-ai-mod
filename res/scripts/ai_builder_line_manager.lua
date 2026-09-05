local vec3 = require("vec3")
local vec2 = require("vec2")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local routeBuilder = require("ai_builder_route_builder")
local constructionUtil = require("ai_builder_construction_util")
local paramHelper = require("ai_builder_base_param_helper")
local util = require("ai_builder_base_util")
local vehicleUtil = require("ai_builder_vehicle_util")
local profiler = require("ai_builder_profiler")
local lineManager = {}
constructionUtil.lineManager = lineManager
lineManager.nextTrainLine = 0
lineManager.nextLineColor = 1
lineManager.lineLastUpdateTime = {}
lineManager.lineLastCheckedTime = {}
lineManager.lineLastReversedTime = {}
lineManager.highwayRequests = {}
lineManager.railLineUpgradeRequests = {}
lineManager.stationLengthUpgrades = {}
local trace = util.trace
local stationFromStop = util.stationFromStop
local formatTime = util.formatTime
local noPathVehicles = {}

local multiplyTargetByLineStops = false

local function nextTrainLineFn() 
	lineManager.nextTrainLine = lineManager.nextTrainLine + 1
	return lineManager.nextTrainLine
end
local function nextLineColorFn() 
	local color = game.config.gui.lineColors[lineManager.nextLineColor]
	color = api.type.Vec3f.new(color[1],color[2],color[3])
	lineManager.nextLineColor = lineManager.nextLineColor+1
	if lineManager.nextLineColor > #game.config.gui.lineColors then
		lineManager.nextLineColor = 1
	end
	return color
end
local function getLine(lineId)
	return util.getComponent(lineId, api.type.ComponentType.LINE)
end
function lineManager.getLine(lineId)
	return getLine(lineId) 
end
local function isProblemLine(lineId) 
	if not lineId or not api.engine.entityExists(lineId) or not getLine(lineId) then 
		return true 
	end
	local problemLines = api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer())
	return util.contains(problemLines, lineId)
end
local function copyStop(stop) 
	local newStop = api.type.Line.Stop.new()
	newStop.stationGroup = stop.stationGroup 
	newStop.station = stop.station 
	newStop.terminal = stop.terminal
	newStop.loadMode = stop.loadMode
	newStop.minWaitingTime = stop.minWaitingTime
	newStop.maxWaitingTime = stop.maxWaitingTime
	newStop.waypoints = stop.waypoints
	newStop.stopConfig = stop.stopConfig
	--newStop.alternativeTerminals = util.shallowClone(stop.alternativeTerminals)
	newStop.alternativeTerminals = stop.alternativeTerminals -- above clone does not appear to work
	return newStop
end 

local function buildNote(items)
	local text = ""
	for k,v in pairs(items) do 
		text = text.._(tostring(k))
		if type(v)~="boolean" then 
			text=text..": ".._(tostring(v))
		end
		text = text.."\n"
	end
		
	text = string.sub(text,1, -2)
	return text
end


local function lineCheck(name) 
	if not util.tracelog or true then -- need to rethink doesnt work
		return 
	end
	if string.find(name, _("Express")) or string.find(name,_("Stopping")) then 
		return 
	end 
	local allLines = api.engine.system.lineSystem.getLines()
	for i, line in pairs(allLines) do 
		local name2 = util.getName(line)
		if name2 == name then 
			error("Attempt to create duplicate line: "..name)
		end 
	end 
end 

local function buildNoteFromLineReport(report) 
	return _("Problems")..": "..buildNote(report.problems).."\n".._("Recommendations")..": "..buildNote(report.recommendations)
end 
local function isRailStation(stationId) 
	return util.getEntity(stationId).carriers.RAIL
end 
local function isRoadStation(stationId) 
	return util.getEntity(stationId).carriers.ROAD
end 
local function isLineType(line, enum)
	if line.vehicleInfo.transportModes[enum+1]==1 then 
		return true 
	end 
	for i, k in pairs(line.vehicleInfo.transportModes) do 
		if k == 1 then 
			return false 
		end 
	end 
	-- ambiguous, fallback 
	if enum == api.type.enum.TransportMode.TRAIN then 
		if #line.stops>0 then 
			return isRailStation(stationFromStop(line.stops[1]))
		end 
	end 
	return false
end

local function isElectricRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.ELECTRIC_TRAIN)
end

local function isRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.TRAIN) or isElectricRailLine(line)
end

lineManager.isRailLine= isRailLine -- TEMP for testing
local function isBusLine(line) 
	return isLineType(line, api.type.enum.TransportMode.BUS)
end 
local function isElectricTramLine(line) 
	return isLineType(line, api.type.enum.TransportMode.ELECTRIC_TRAM)
end

local function isTramLine(line) 
	return isLineType(line, api.type.enum.TransportMode.TRAM)
	or isElectricTramLine(line)
end 
local function isTruckLine(line)
	return isLineType(line, api.type.enum.TransportMode.TRUCK)
end 	
local function isRoadLine(line)
	return isBusLine(line) 
	or isTruckLine(line)
	or isTramLine(line) 
end
local function isShipLine(line)
	return isLineType(line, api.type.enum.TransportMode.SMALL_SHIP) or isLineType(line, api.type.enum.TransportMode.SHIP)
end

local function isAirLine(line)
	return isLineType(line, api.type.enum.TransportMode.SMALL_AIRCRAFT) or isLineType(line, api.type.enum.TransportMode.AIRCRAFT)
end

local function lineName(lineId) 
	return util.getComponent(lineId, api.type.ComponentType.NAME).name
end

local function stationFromGroup(group) 
	return util.getComponent(group, api.type.ComponentType.STATION_GROUP).stations[1]
end
local function stationFromConstruction(constructionId) 
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if not construction then 
		return constructionId
	end
	return construction.stations[1]
end

local function constructionFromStation(stationId) 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then 
		constructionId = stationId
	end
	return  util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
end
local function depotFromConstruction(constructionId) 
	return util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION).depots[1]
end
local function groupFromStation(station)
	return api.engine.system.stationGroupSystem.getStationGroup(station)
end



function lineManager.stationFromStop(stop) 
	return stationFromStop(stop) 
end
local function discoverLineCarrier(line) 
	if isTramLine(line) then 
		return api.type.enum.Carrier.TRAM 
	elseif isRailLine(line) then 
		return api.type.enum.Carrier.RAIL
	elseif isShipLine(line) then 
		return api.type.enum.Carrier.WATER 
	elseif isAirLine(line) then 
		return api.type.enum.Carrier.AIR 
	elseif isRoadLine(line) then 
		return api.type.enum.Carrier.ROAD 
	end 
	trace("Having trouble determinging carrier, falling back to stations") 
	local foundTram = false
	for i, stop in pairs(line.stops) do
		local stationId = stationFromStop(stop)
		local station = util.getEntity(stationId) 
		if station.carriers.TRAM then -- continue looping if it is a tram to verify all stops
			 foundTram = true 
		elseif station.carriers.ROAD then 
			return api.type.enum.Carrier.ROAD 
		elseif station.carriers.RAIL then 
			return api.type.enum.Carrier.RAIL
		elseif station.carriers.WATER then 
			return api.type.enum.Carrier.WATER 
		elseif station.carriers.AIR then 
			return api.type.enum.Carrier.AIR  
		end
	end 
	if foundTram then 
		return api.type.enum.Carrier.TRAM 
	end 
	trace("Line has no stops, unknown carrier")
end 
function lineManager.checkNoPathVehicles() 
	local currentNoPathVehicles = {}
	local problemVehicles = util.combine(api.engine.system.trainMoveSystem.getBlockedTrains(), api.engine.system.transportVehicleSystem.getNoPathVehicles())
	for i, vehicleId in pairs(problemVehicles) do 
		currentNoPathVehicles[vehicleId]=true
	end
	for noPathVehicle, attemptCount in pairs(noPathVehicles) do 
		if not currentNoPathVehicles[noPathVehicle] then
			noPathVehicles[noPathVehicles]=nil
		else 
			if attemptCount <= 2 then 
				lineManager.addBackgroundWork(function()api.cmd.sendCommand(api.cmd.make.reverseVehicle(noPathVehicle) , function(res, success)
					if success then 
						noPathVehicles[noPathVehicle]=attemptCount+1
					end
				end)end)
			else
				lineManager.addBackgroundWork(function()lineManager.replaceVehicle(noPathVehicle)end)
			end
			currentNoPathVehicles[noPathVehicle] = nil
		end 
	end
	for noPathVehicle, __ in pairs(currentNoPathVehicles) do
		noPathVehicles[noPathVehicle]=0
		lineManager.addBackgroundWork(function()api.cmd.sendCommand(api.cmd.make.reverseVehicle(noPathVehicle) , function(res, success)
			if success then 
				noPathVehicles[noPathVehicle]=1
			end
		end)end)
	end
end

local function reverseAllLineVehicles(lineId)
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	for i, vehicle in pairs(vehicles) do 
		api.cmd.sendCommand(api.cmd.make.reverseVehicle(vehicle) , function(res, success)
			if success then 
				 api.cmd.sendCommand(api.cmd.make.reverseVehicle(vehicle))
			end
		end)
	end 
	
end 

local function setAppropriateStationIdx(stop, station)
	local stationGroup = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
	stop.station = util.indexOf(stationGroup.stations, station) - 1
end

function lineManager.getStopIndexForStation(lineId, stationId) 
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
	local stationGroupComp = util.getComponent(stationGroup, api.type.ComponentType.STATION_GROUP)
	local stationIdx =  util.indexOf(stationGroupComp.stations, stationId) - 1
	local line = getLine(lineId)
	for i, stop in pairs(line.stops) do 
		if stop.stationGroup == stationGroup and stop.station == stationIdx then 
			return i 
		end
	end 
	trace("WARNING! Unable to find station",stationId, " on line",lineId)
end 

local function validateLine(line) 
	for i, stop in pairs(line.stops) do 
		local stationId = stationFromStop(stop)
		local station = util.getStation(stationId)
		assert(stop.terminal >=0, "terminal was "..tostring(stop.terminal))
		local numTerminals = #station.terminals
		
		assert(stop.terminal < numTerminals, "terminal was "..tostring(stop.terminal).." needs to be< "..tostring(numTerminals).." at station "..tostring(stationId))
		for i, alternative in pairs(stop.alternativeTerminals) do 
			assert(alternative.terminal >=0, "terminal was "..tostring(alternative.terminal))
			assert(alternative.terminal < numTerminals, "terminal was "..tostring(alternative.terminal).." needs to be< "..tostring(numTerminals).." at station "..tostring(stationId))
		end 
	end 
end

function lineManager.updateLineSetNewStation(lineId, stopIndex, stationId) 
	trace("lineManager.updateLineSetNewStation:" ,lineId, stopIndex, stationId)
	local lineDetails = getLine(lineId) 
	local line = api.type.Line.new()
	line.vehicleInfo = lineDetails.vehicleInfo
	for i, stopDetail in pairs(lineDetails.stops) do 	
		local stop = copyStop(stopDetail)
		
--		if stationGroup == stopDetail.stationGroup and oldTerminal-1 == stopDetail.terminal then
		if i == stopIndex then 
			stop.stationGroup =  groupFromStation(stationId)
			setAppropriateStationIdx(stop, stationId)
			stop.terminal = 0
			trace("Changed the stop at ",i)
		end
		line.stops[i]=stop  
	end
	validateLine(line)
	local updateLine = api.cmd.make.updateLine(lineId, line)
	api.cmd.sendCommand(updateLine, lineManager.standardCallback)
end 
local function checkForPath(stationId, nextStop ,priorStop, terminal)
	local nextStationId 
	local nextTerminalId 
	if nextStop then 
		if type(nextStop) == "number" then 
			nextStationId = nextStop
		else
			nextStationId = stationFromStop(nextStop)
			nextTerminalId = nextStop.terminal
		end 
	end 
	if isRailStation(stationId) then  
		if priorStop then 
			if #pathFindingUtil.findRailPathBetweenStations(stationFromStop(priorStop), stationId, priorStop.terminal, terminal) == 0 then
				return false
			end
		end
		if nextStationId then  
			if nextTerminalId then 
				if #pathFindingUtil.findRailPathBetweenStations(stationId, nextStationId, terminal, nextTerminalId) == 0 then
					return false
				end
			elseif not pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, terminal, nextStationId) then 
				return false 
			end
		end
	elseif isRoadStation(stationId) then 
		if priorStop then 
			if #pathFindingUtil.findRoadPathStations(stationFromStop(priorStop), stationId) == 0 then
				return false
			end
		end
		if nextStationId then  
			if #pathFindingUtil.findRoadPathStations(stationId, nextStationId) == 0 then 
				return false 
			end
		end
	end 
	return true
end 

local function getFreeTerminalsForStation(stationId, nextStationId, priorStop) 
	local result = {}
	for i = 1, #util.getComponent(stationId, api.type.ComponentType.STATION).terminals do
		local terminal = i-1
		local numstops =  #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal)
		trace("Inspecting station ",stationId," the numstops at terminal ", terminal , " was ",numstops)
		if 0 == numstops then 
			if checkForPath(stationId, nextStationId ,priorStop, terminal) then 
				table.insert(result, terminal)
			else 
				trace("Rejecting terminal",terminal," as no path was found to ",nextStationId," from ",stationId)
			end 
		end
	end 

	return result
end
local function validateRailPaths(line)
		for i, stop in pairs(line.stops) do 
			if #stop.alternativeTerminals > 0 then 
				--goto continue 
			end
			local station = stationFromStop(stop)
			local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
			local nextStop  = i == #line.stops and line.stops[1] or line.stops[i+1]
			local nextStation = stationFromStop(nextStop)
			local priorStation = stationFromStop(priorStop)
			local isTerminus = priorStation == nextStation
			if isTerminus then 
				if #pathFindingUtil.findRailPathBetweenStations(station, nextStation, stop.terminal, nextStop.terminal) == 0  or 
				#pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, stop.terminal) == 0 then 
					trace("No path found for terminal, attempting to correct. Terminal was ",stop.terminal)
					for j, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
						if #pathFindingUtil.findRailPathBetweenStations(station, nextStation, terminal, nextStop.terminal) > 0
							and #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, terminal) > 0 then
							stop.terminal = terminal 
							trace("Found a terminal with a path",terminal)
							line.stops[i]=stop 
							break 
						end 
					end
				end
				if stop.alternativeTerminals[1] and ( #pathFindingUtil.findRailPathBetweenStations(station, nextStation, stop.alternativeTerminals[1].terminal, nextStop.terminal) == 0 
				or #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, stop.alternativeTerminals[1].terminal) ==0)
				then 
					trace("Alternative terminal was not good, trying another")
					for j, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
						if terminal~= stop.terminal and #pathFindingUtil.findRailPathBetweenStations(station, nextStation, terminal, nextStop.terminal) > 0
							and #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, terminal) > 0						then 
							trace("Found a terminal with a path",terminal)
							local alternative = api.type.StationTerminal.new()
							alternative.station = stop.station 
							alternative.terminal = terminal
							stop.alternativeTerminals[1]=alternative
							break 
						end 
					end
				end 
			end 
			::continue::
		end  
end	
lineManager.changeTerminal = function(stationId, oldTerminal, newTerminal, callback, stopAndLine)
	local stopIndex = stopAndLine.stopIndex
	local lineId = stopAndLine.lineId
	local alternativeIdx = stopAndLine.alternativeIdx
	
	trace("request to change terminal, stationId=",stationId, " oldTerminal=",oldTerminal, " newTerminal=",newTerminal)
	--local lineId  = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, oldTerminal-1)[1]
	--if not lineId then
	--	callback({}, true)
	--	return
	--end
	local lineDetails = util.getComponent(lineId, api.type.ComponentType.LINE)
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)

	local line = api.type.Line.new()
	line.vehicleInfo = lineDetails.vehicleInfo
	for i, stopDetail in pairs(lineDetails.stops) do 	
		local stop = api.type.Line.Stop.new()
		stop.stationGroup = stopDetail.stationGroup 
		stop.station = stopDetail.station 
		stop.terminal = stopDetail.terminal
		stop.loadMode = stopDetail.loadMode
		stop.minWaitingTime = stopDetail.minWaitingTime
		stop.maxWaitingTime = stopDetail.maxWaitingTime
		stop.waypoints = stopDetail.waypoints
		stop.stopConfig = stopDetail.stopConfig
		stop.alternativeTerminals = stopDetail.alternativeTerminals
--		if stationGroup == stopDetail.stationGroup and oldTerminal-1 == stopDetail.terminal then
		if i == stopIndex then 
		--	if stop.terminal == newTerminal then 
		--		trace("WARNING! Already have the terminal set the same aborting")
		--		callback({}, true)
		--		return
		--	end
			if alternativeIdx then 
				local alternative = api.type.StationTerminal.new()
				alternative.station = stop.station 
				alternative.terminal = newTerminal-1
				
				if #stop.alternativeTerminals <= alternativeIdx then 
					stop.alternativeTerminals[alternativeIdx]=alternative
				else 
					trace("WARNING! alternativeIdx",alternativeIdx," was out of bounds ",#stop.alternativeTerminals," at ",stationId)
					stop.alternativeTerminals[1+#stop.alternativeTerminals]=alternative
				end
			else 
				stop.terminal = newTerminal-1
			end
		end
		line.stops[i]=stop  
	end
	validateLine(line)
	validateRailPaths(line)
	local updateLine = api.cmd.make.updateLine(lineId, line)
	api.cmd.sendCommand(updateLine, callback)
end 
function lineManager.fixProblemLines()
	local problemLines = api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer())
	for i , lineId in pairs(problemLines) do 
		local lineDetails = getLine(lineId)
		if lineDetails.stops[1] then 
			local stationId = stationFromStop(lineDetails.stops[1])
			local stationFull = game.interface.getEntity(stationId)
			if stationFull.carriers.RAIL then 
				local line = api.type.Line.new()
				line.vehicleInfo = lineDetails.vehicleInfo
				for i, stopDetail in pairs(lineDetails.stops) do 	
					local stop = api.type.Line.Stop.new()
					stop.stationGroup = stopDetail.stationGroup 
					stop.station = stopDetail.station 
					stop.terminal = stopDetail.terminal
					stop.loadMode = stopDetail.loadMode
					stop.minWaitingTime = stopDetail.minWaitingTime
					stop.maxWaitingTime = stopDetail.maxWaitingTime
					stop.waypoints = stopDetail.waypoints
					stop.stopConfig = stopDetail.stopConfig
					stop.alternativeTerminals = stopDetail.alternativeTerminals
					line.stops[i]=stop  
				end 
				validateRailPaths(line)
				local updateLine = api.cmd.make.updateLine(lineId, line)
				local function callback(res, success)
					trace("Result of call to update line was",success,"for",lineId)
				end 
				api.cmd.sendCommand(updateLine, callback)
			end 
			
		end 
	end 
end 

function lineManager.stopIndex(stationId, terminal)
	local lineId  = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal-1)[1]
	
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
	local stationGroupComp = util.getComponent(stationGroup, api.type.ComponentType.STATION_GROUP)
	local stationIdx = util.indexOf(stationGroupComp.stations, stationId) - 1
	if not lineId then 
		 
		local lineStops = api.engine.system.lineSystem.getLineStopsForStation(stationId)
		for i , lineId2 in pairs(lineStops) do 
			 
			local line = util.getLine(lineId2)
			for j, stop in pairs(line.stops) do 
				if stop.stationGroup == stationGroup and stop.station == stationIdx then 
					trace("lineManager.stopIndex: Checking the alternativeTerminal at ",stop.stationGroup," for stationIdx",stationIdx)
					for k, alternativeTerminal in pairs(stop.alternativeTerminals) do 
						if alternativeTerminal.station == stationIdx and alternativeTerminal.terminal == terminal-1 then  
							return { stopIndex = j , lineId = lineId2, alternativeIdx=k} 
						end 
					end 
				end 
 
			end 
 
		end
	
	end 
	local lineDetails = util.getComponent(lineId, api.type.ComponentType.LINE)
	for i, stopDetail in pairs(lineDetails.stops) do 
		if stationGroup == stopDetail.stationGroup and terminal-1 == stopDetail.terminal and   stopDetail.station == stationIdx then
			return { stopIndex = i , lineId = lineId}
		end 
	end 
end 


lineManager.getNeighbouringStationStops = function(stationId, terminalId)
	local result = {}
	local lineId  = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminalId-1)[1]
	local stopIndex
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
	local stationGroupComp = util.getComponent(stationGroup, api.type.ComponentType.STATION_GROUP)
	local stationIdx = util.indexOf(stationGroupComp.stations, stationId) - 1
	if not lineId then 
		local lineStops = api.engine.system.lineSystem.getLineStopsForStation(stationId)
		for i , lineId2 in pairs(lineStops) do 
			 
			local line = util.getLine(lineId2)
			for j, stop in pairs(line.stops) do 
				if stop.stationGroup == stationGroup and stop.station == stationIdx then 
					trace("getNeighbouringStationStops: Checking the alternativeTerminal at ",stop.stationGroup," for stationIdx",stationIdx)
					for __, alternativeTerminal in pairs(stop.alternativeTerminals) do 
						if alternativeTerminal.station == stationIdx and alternativeTerminal.terminal == terminalId-1 then 
							lineId = lineId2 
							stopIndex = j
							break 
						end 
					end 
				end 
				if lineId then 
					break 
				end
			end 
			if lineId then 
				break 
			end
		end
	
	end 
	if not lineId then 
		return result 
	end
	local lineDetails = util.getComponent(lineId, api.type.ComponentType.LINE)
	 
	for i, stopDetail in pairs(lineDetails.stops) do 	
		if stationGroup == stopDetail.stationGroup and terminalId-1 == stopDetail.terminal and stopDetail.station == stationIdx or i == stopIndex then
			if i > 1 then
				table.insert(result, { terminal= lineDetails.stops[i-1].terminal, station = stationFromStop(lineDetails.stops[i-1]), isPriorStop=true})
			elseif #lineDetails.stops > 2 then 
				table.insert(result,{ terminal= lineDetails.stops[#lineDetails.stops].terminal, station = stationFromStop(lineDetails.stops[#lineDetails.stops]), isPriorStop=true})
			end
			if i < #lineDetails.stops then
				table.insert(result, {terminal= lineDetails.stops[i+1].terminal, station = stationFromStop(lineDetails.stops[i+1])})
			elseif #lineDetails.stops > 2 then 
				table.insert(result,{ terminal= lineDetails.stops[1].terminal, station = stationFromStop(lineDetails.stops[1])})
			end
		end
	end
	return result
end
local function isAboveMaximumInterval(lineId, line, params)

	params.targetMaximumPassengerInterval = paramHelper.getParams().targetMaximumPassengerInterval
	if isRoadLine(line) then 
		params.targetMaximumPassengerInterval =  paramHelper.getParams().targetMaximumPassengerBusInterval 
	elseif isAirLine(line) then 
		params.targetMaximumPassengerInterval =  paramHelper.getParams().targetMaximumPassengerAirInterval 
	end 
	local frequency = util.getEntity(lineId).frequency
	if frequency == 0 then 
		return true
	end
	local interval = 1 / frequency
	trace("interval for line ",lineId," was ",interval)
	return interval >  params.targetMaximumPassengerInterval
end	
function lineManager.assignVehicleToLine(vehicle, line, callback,stopIndex, buyCommand, buyRes)			
	if not callback then callback = lineManager.standardCallback end
	if not stopIndex then stopIndex = 0 end
	local setLine = api.cmd.make.setLine(vehicle, line, stopIndex)
	api.cmd.sendCommand(setLine, function(res, success)
		if success then 
			lineManager.lineLastUpdateTime[line]=game.interface.getGameTime().time 
		end
		if not success and buyCommand then 
			debugPrint({buyCommand = buyCommand, buyRes= buyRes, vehicleDetail = util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)})
		end
		if not success and stopIndex >0 then
			lineManager.addBackgroundWork(function() lineManager.assignVehicleToLine(vehicle, line, callback, 0)end)	
		end
		callback(res, success)
	end)
end

function lineManager.buildVehicleAndAssignToLine(vehicleConfig, depotEntity, lineId, callback, stopIndex)
	if not stopIndex then
		local line = util.getComponent(lineId, api.type.ComponentType.LINE)
		stopIndex = pathFindingUtil.findClosestStopIndexForDepot(depotEntity, line) 
	end
	if not stopIndex then
		trace("WARNING! Could not find path from depot ",depotEntity," to any stop on line",lineId)
	end
	local wrappedCallback = function(res, success)
		if success then 
			local resultVehicle = res.resultVehicleEntity 
			lineManager.addBackgroundWork(function() lineManager.assignVehicleToLine(resultVehicle, lineId, callback, stopIndex) end)
		end			
		callback(res, success)
	end
	trace("===== BUYING VEHICLE =====")
	trace("  depotEntity=", depotEntity)
	trace("  lineId=", lineId)
	trace("  player=", game.interface.getPlayer())
	trace("  vehicleConfig vehicles=", vehicleConfig and vehicleConfig.vehicles and #vehicleConfig.vehicles or "nil")
	local apiVehicle = vehicleUtil.copyConfigToApi(vehicleConfig)
	trace("  apiVehicle created, vehicles=", apiVehicle and apiVehicle.vehicles and #apiVehicle.vehicles or "nil")
	local buyVehicle = api.cmd.make.buyVehicle( game.interface.getPlayer(),depotEntity, apiVehicle)
	trace("  buyVehicle command created")
	api.cmd.sendCommand(buyVehicle, function(res, success)
		trace("===== BUY VEHICLE RESULT =====")
		trace("  success=", success)
		if res then
			trace("  resultVehicleEntity=", res.resultVehicleEntity)
			trace("  errorStr=", res.errorStr)
		else
			trace("  res is nil")
		end
		wrappedCallback(res, success)
	end)
end




local function getFreeTerminalForStation(stationId, nextStationId, priorStop, alreadyUsed )
	if not alreadyUsed then alreadyUsed = {} end
	local freeTerminals = getFreeTerminalsForStation(stationId, nextStationId, priorStop)
	trace("getFreeTerminalForStation: got",#freeTerminals,"for",stationId)
	local isRail = util.getEntity(stationId).carriers.RAIL 
	if #freeTerminals > 1 and nextStationId and isRail then 
		local stationVector = util.vectorBetweenStations(stationId, nextStationId)
		return lineManager.chooseRightHandTerminal(stationVector, stationId,  freeTerminals[1], freeTerminals[2], nextStationId)
	end
	if #freeTerminals > 1 and util.getEntity(stationId).carriers.ROAD then 
		local nearbyDepot =  constructionUtil.searchForRoadDepot(util.getStationPosition(stationId), 100)
		if nearbyDepot then 
			trace("getFreeTerminalForStation Attempting to select shortest") 
			return util.evaluateWinnerFromSingleScore(freeTerminals, function(terminal) 
				local roadPath = pathFindingUtil.findRoadPathFromDepotToStationAndTerminal(nearbyDepot, stationId, terminal)
				trace("Inspecting path from ",nearbyDepot," to station",stationId, " at terminal",terminal," found ",#roadPath," results")
				if util.tracelog then 
					--debugPrint(roadPath)
				end
				return -#roadPath -- not sure why but the larger one seems correct
			end)
		end 
	end 
	
	if #freeTerminals > 0 then 
		return freeTerminals[1]
	end 
	local options = {} 
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	for i = 1, #station.terminals do
		local terminal = i-1
		local numstops =  #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal)
		trace("Inspecting station ",stationId," the numstops at terminal ", terminal , " was ",numstops) 
		if not alreadyUsed[terminal] and checkForPath(stationId, nextStationId ,priorStop, terminal) then 
			table.insert(options, {terminal = terminal, scores={numstops}})
		end
	end 
	if #options == 0 then 
		return 0 
	end
	return util.evaluateWinnerFromScores(options).terminal
end
local function indexOfStop(line, station, fromLast)
	local startAt = fromLast and #line.stops or 1 
	local endAt = fromLast and 1 or #line.stops 
	local increment = fromLast  and -1 or 1
	for i = startAt, endAt, increment do 
		if station == stationFromGroup(line.stops[i].stationGroup) then
			return i 
		end
	end
end

local function getNextStationStop(line, station)
	local stopIndex = indexOfStop(line, station)
	return stopIndex < #line.stops and line.stops[stopIndex+1] or line.stops[1]
end

local function getTerminalGap(line, station, freeTerminal)
	for  i, stop  in pairs(line.stops) do 	
		if station == stationFromStop(stop) then
			return math.abs(stop.terminal - freeTerminal)
		end 
	end 
end
local function stationAppearsOnceOnLineAndAdjacentToFreeTerminal(line, station, freeTerminal)
	local count = 0
 
	for  i, stop  in pairs(line.stops) do 	
		if station == stationFromStop(stop) then
			local terminalGap = math.abs(stop.terminal-freeTerminal)
			trace("stationAppearsOnceOnLineAndAdjacentToFreeTerminal: The terminal gap was ",terminalGap,"station=",station)
			if terminalGap > 3 then 
				return false
			end
			if #stop.alternativeTerminals > 0 then 
				trace("stationAppearsOnceOnLineAndAdjacentToFreeTerminal: Aborting for",station,"due to alternative terminals")
				return false
			end 
			if terminalGap == 3 then 
				local stationComp = util.getStation(station)
				local numTerminals = #stationComp.terminals
				if numTerminals ~= 4 then -- limiting here to special case where we connect the outer edges
					return false 
				end 
			end 
			if terminalGap == 2 then 
				return false -- TODO: dont think this will work
			end 
			count = count + 1
		end
	end
	trace("stationAppearsOnceOnLineAndAdjacentToFreeTerminal:",count==1,"station=",station)
	return count == 1
end



local function chooseRightHandTerminal(stationVector, stationId,  terminal1, terminal2, otherStation, otherLineId) 
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	local vehicleNodeId1 = station.terminals[terminal1+1].vehicleNodeId.entity
	local vehicleNodeId2 = station.terminals[terminal2+1].vehicleNodeId.entity
	local nodeVector = util.vecBetweenNodes(vehicleNodeId1, vehicleNodeId2)
	local angle = util.signedAngle(stationVector, nodeVector)
	local routeInfo = pathFindingUtil.getRouteInfo(stationId, otherStation) 
	if routeInfo and routeInfo.firstFreeEdge then
		local exitVector = util.getEdgeMidPoint(routeInfo.edges[routeInfo.firstFreeEdge].id) -  util.getStationPosition(stationId)
		local oldAngle = angle 
		angle = util.signedAngle(exitVector, nodeVector)
		trace("The angle using basic station vector was",math.deg(oldAngle)," the angle using exitVector was ",math.deg(angle))
	else 
		trace("WARNING! No route info found between stations",stationId, otherStation)
	end 
	local chosenTerminal = angle < 0 and terminal1 or terminal2
	trace("angle to the station and node vector was", math.deg(angle), "chosenTerminal=",chosenTerminal, " terminal choices were ",terminal1, terminal2, " of a total of ", #station.terminals, " for station",stationId, " otherStation=",otherStation)
	if not otherLineId and  not pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, chosenTerminal, otherStation) then 
		local otherTerminal = chosenTerminal == terminal1 and terminal2 or terminal1 
		if pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, otherTerminal, otherStation) then 
			chosenTerminal = otherTerminal
			trace("Path finding could not find a path using proposed terminal, using ",chosenTerminal," instead")
		else 
			trace("WARNING! No path could be found from either terminal")
		end
	end
	return chosenTerminal
end	
lineManager.chooseRightHandTerminal = chooseRightHandTerminal

local function isPassengerLine(line)
	local stationId = stationFromStop(line.stops[1])
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	return not station.cargo
end
local function discoverLineCargoType2(lineId, forbidRecurse)
	
	for i, simCargoId in pairs( util.deepClone(api.engine.system.simCargoSystem.getSimCargosForLine(lineId))) do
		local simCargo = util.getComponent(simCargoId, api.type.ComponentType.SIM_CARGO)
		if simCargo then -- this is subject to a race condition if the cargo dissapears
			return  simCargo.cargoType 
		end 
	end 
	if #api.engine.system.simPersonSystem.getSimPersonsForLine(lineId) > 0 then 
		return api.res.cargoTypeRep.find("PASSENGERS")
	end
	if #getLine(lineId).stops < 2 then 
		trace("line has insufficient stops to discoverCargoType")
		return 
	end
	local firstStation = stationFromStop(getLine(lineId).stops[1])
	if not firstStation then 
		trace("No first station for line?")
		debugPrint(getLine(lineId))
		return
	end 
	if not util.getStation(firstStation).cargo then 
		return api.res.cargoTypeRep.find("PASSENGERS")
	end
	trace("Having difficulty finding cargo type for line",lineId)
	local vehicle = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)[1]
	if vehicle then 
		local vehicleConfig = util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE).transportVehicleConfig
		if vehicleConfig.vehicles[1].autoLoadConfig[1] == 0 then 
			trace("Attempting to find cargoType from vehicleConfig")
			return vehicleUtil.getCurrentCargoConfig(vehicleConfig.vehicles[1])
		end 
	end
	
	local allCargos = util.getMapOfUserToSystemNames() 
	local lineName = util.getName(lineId)
	local lastWord = lineName:gsub(".*% ","")
	local cargoFromName = allCargos[lastWord]
	trace("Attempting to infer cargo type from name ",lineName," lastWord=",lastWord,"cargoFromName?",cargoFromName)
	if cargoFromName then 
		local res=  api.res.cargoTypeRep.find(cargoFromName)
		assert(res~=-1)
		return res
	end
	
	local industry = util.searchForFirstEntity(util.getStationPosition(firstStation), 300, "SIM_BUILDING")
	
	local cargoType = industry and  util.discoverCargoType(industry) 
	local station2 = stationFromStop(getLine(lineId).stops[2])
	if not cargoType then 
		trace("Attempting to find from industry2")
		local industry2 = util.searchForFirstEntity(util.getStationPosition(station2), 300, "SIM_BUILDING")
		if industry2 then 
			return util.discoverCargoType(industry2)
		end 
	else 
		return cargoType
	end
	-- look for transhipment 
	trace("Still unable to determine cargo type for line",lineId,"looking for transhipment")
	if forbidRecurse then 
		trace("discoverCargoType: exiting as forbidRecurse was true")
		return 
	end
	local weAreShip = util.getEntity(firstStation).carriers.WATER or false 
	local filterFn = function(otherStation) 
		local theyAreShip = otherStation.carriers.WATER or false 
		trace("Inspecting otherStation",otherStation.id," weAreShip=",weAreShip,"theyAreShip=",theyAreShip)
		return weAreShip~=theyAreShip
	end 
	
	for i, station in pairs({ firstStation, station2}) do 
		local otherStation = util.searchForFirstEntity(util.getStationPosition(station), 200, "STATION", filterFn)
		if otherStation then 
			local otherLines = api.engine.system.lineSystem.getLineStopsForStation(otherStation.id)
			trace("Found potential transhipment station near",station," found ",#otherLines,"otherLines")
			if #otherLines == 1 then 
				local otherCargoType = discoverLineCargoType2(otherLines[1], true)
				if otherCargoType then 
					trace("Found cargotype",otherCargoType)
					return otherCargoType
				end
			else 
				trace("No lines found or ambiguous")
			end 
		else 
			trace("Did not find potential transhipment station near",station)
		end 
	end  
	
	trace("WARNING! Unable to determine cargo type for line",lineId)
end 
lineManager.discoveredCargoTypes = {}
local function discoverLineCargoType(lineId) 
	if not lineManager.discoveredCargoTypes[lineId] then 
		lineManager.discoveredCargoTypes[lineId]=discoverLineCargoType2(lineId)
	end 
	return lineManager.discoveredCargoTypes[lineId]
end 


lineManager.discoverLineCargoType = discoverLineCargoType

local function getMinStationLength(line)
	local minStationLength = math.huge 
	for i , stop in pairs(line.stops) do 
		minStationLength = math.min(constructionUtil.getStationLength(stationFromStop(stop)), minStationLength)
	end
	
	trace("MinStationLength was ",minStationLength)
	return minStationLength
end 
local function getMinStationLengthParam(line)
	local minStationLength = math.huge 
	for i , stop in pairs(line.stops) do 
		minStationLength = math.min(constructionUtil.getStationLengthParam(stationFromStop(stop)), minStationLength)
	end
	
	trace("MinStationLengthParam was ",minStationLength)
	return minStationLength
end 
local function isLargeHarbour(construction) 
	for k, v in pairs(construction.params) do -- cannot index size directly as it calls a different method 
		if k == "size" then 
			return v == 1
		end 
	end 

end 
local function isAirfield(construction) 
	return string.find(construction.fileName, "airfield")
end 
local function hasSecondRunway(construction) 
	if not construction.params or not construction.params.modules then 
		return false 
	end
	for moduleId, moduleDetails in pairs(construction.params.modules) do 
		if moduleDetails.name == "station/air/airport_2nd_runway.module" then 
			return true
		end 
	end 
	return false 
end 

local function tryToRealignRoutesForBalancing(res, details)
	util.lazyCacheNode2SegMaps()
	local nodeLookupMap = {}
	for i, node in pairs(res.proposal.proposal.addedNodes) do 
	
		nodeLookupMap[node.entity]=util.v3(node.comp.position)
	end 
	local function nodePos(node) 
		if node > 0 then 
			return util.nodePos(node)
		else 
			return nodeLookupMap[node]
		end 
	end 
	local newSegments = {}
	for i, seg in pairs(res.proposal.proposal.addedSegments) do
		local p0 = nodePos(seg.comp.node0)
		local p1 = nodePos(seg.comp.node1)
		if not p0 or not p1 then 
			debugPrint({node0=seg.comp.node0, node1=seg.comp.node1, nodeLookupMap=nodeLookupMap})
		end 
		local newEdge = util.findEdgeConnectingPoints(p0, p1)
		newSegments[newEdge]=true
	end
	local linesSet =  util.getValueSet(details.lineIds)
	local filterFn = function(line, lineId) return linesSet[lineId] end  
	
	local allEdges = util.combineSets(newSegments,details.edges)
	
	local filterEdges = function(edgeId) 
		return allEdges[edgeId]
	end
	local matchedEdges = {}
	for edgeId, bool in pairs(newSegments) do 
		local edgeFull = util.getEdge(edgeId)
		if #edgeFull.objects > 0 then 
			local doubleTrackEdge = util.findDoubleTrackEdge(edgeId)
			if doubleTrackEdge and #util.getEdge(doubleTrackEdge).objects > 0 and details.edges[doubleTrackEdge] then 
				matchedEdges[edgeId]=doubleTrackEdge
				matchedEdges[doubleTrackEdge]=edgeId
			end 
			
		end 
	end 
	
	
	
	local newEdges = pathFindingUtil.getEdgesUsedByLinesGrouped(filterFn,filterEdges)
	
	local numLines = #details.lineIds
	local ideal = math.ceil(numLines/2)
	trace("tryToRealignRoutesForBalancing: the numLines was", numLines,"ideal=",ideal, "newEdges size=",util.size(newEdges))
	if util.tracelog then 
		debugPrint({newEdges = newEdges})
		debugPrint({matchedEdges=matchedEdges})
	end
	local unSeenEdges = util.shallowClone(allEdges)
	local detailsToFix = {}
	for key, newDetails in pairs(newEdges) do
		for edgeId, bool in pairs(newDetails.edges) do 
			unSeenEdges[edgeId] = nil 
			if newSegments[edgeId] then 
				newDetails.isNewSegment = true
			end 
			if matchedEdges[edgeId] and not newDetails.matchedEdge then 
				newDetails.matchedEdge = matchedEdges[edgeId] 
			end 
		end
		if #newDetails.lineIds > ideal  then 
			table.insert(detailsToFix, newDetails)
		end 
	end 
	if util.tracelog then 
		debugPrint({detailsToFix=detailsToFix})
	end
	for i , newDetails in pairs(detailsToFix) do 
		local target = #newDetails.lineIds - ideal 
		local matchedEdge = newDetails.matchedEdge
		local numFixed =  0
		for j, lineId in pairs(newDetails.lineIds) do 
			trace("Inspecting line",lineId,"of",j,"numFixed=",numFixed,"of target=",target)
			if numFixed >= target then 
				trace("Exiting loop as reached target")
				break 
			end 
			local line = getLine(lineId)
			if #line.stops == 2 then 
				local station1 = stationFromStop(line.stops[1])
				local station2 = stationFromStop(line.stops[2])
				local terminal1 = line.stops[1].terminal
				local terminal2 = line.stops[2].terminal
				trace("looking for a path between ",station1,station2,terminal1,terminal2,"with edge",matchedEdge)
				local path1 =  pathFindingUtil.findRailPathBetweenStationTerminalAndEdge(station1, terminal1 ,matchedEdge )
				local path2 = pathFindingUtil.findRailPathBetweenEdgeAndStationTerminal(matchedEdge,station2, terminal2 )
				trace("looking for a path between ",station1,station2,terminal1,terminal2,"with edge",matchedEdge,"found 1?",#path1>0," found2?",#path2>0)
				local index 
				if #path1 > 0 and #path2 > 0 then 
					trace("Found path")
					index = 1 
				else 
					path1 =  pathFindingUtil.findRailPathBetweenStationTerminalAndEdge(station2, terminal2 ,matchedEdge )
					path2 = pathFindingUtil.findRailPathBetweenEdgeAndStationTerminal(matchedEdge,station1, terminal1 )
					trace("Second attempt in other directionfound 1?",#path1>0," found2?",#path2>0)
					index = 2
				end 
				if #path1 > 0 and #path2 > 0 and #line.stops[index].waypoints == 0 then  -- cant yet handle multiple waypoints
					local edgeFull = util.getEdge(matchedEdge)
					local signalId = edgeFull.objects[1][1] -- should be present as we filtered for it previously
					local signal = api.type.SignalId.new()
					signal.entity = signalId 
					signal.index = 0 -- not sure how to  get this, seem to work for now
					local newLine = api.type.Line.new()
					newLine.waitingTime= line.waitingTime
					for k, stop in pairs(line.stops) do 
						local newStop = copyStop(stop)
						if k == index then 
							trace("Setting the way point on the line")
							newStop.waypoints[1]=signal
						end 
						newLine.stops[k]=newStop
					end 
					trace("About to send command to update line",lineId)
					api.cmd.sendCommand(api.cmd.make.updateLine(lineId, newLine), lineManager.standardCallback)
					numFixed = numFixed + 1
				end 
				
			end 
			
			
		end 
		
	end 
end
lineManager.alreadyUgradedRoutes = {}



function lineManager.upgradeBusiestLines() 
	trace("lineManager.upgradeBusiestLines begin")
	util.lazyCacheNode2SegMaps()
	local filterFn = function(line) 
		return isRailLine(line)
	end 
	--[[local edgeFilter = function(edgeId) 
		if util.getEdge(edgeId)  then 
			return util.edgeHasSpaceForDoubleTrack(edgeId)
		end
	end ]]--
	lineManager.railLineUpgradeRequests = {} -- reset for now, perhaps this can be smarter
	local mappedResults = pathFindingUtil.getEdgesUsedByLinesGrouped(filterFn, edgeFilter)
	
	local options = {}
	for key, details in pairs(mappedResults) do 
		if not lineManager.alreadyUgradedRoutes[key] then 
			local canAccept = #details.lineIds > 1 
			for edgeId, bool in pairs(details.edges) do 
				if not util.edgeHasSpaceForDoubleTrack(edgeId) then 
					canAccept = false 
					break
				end 
			end 
			if canAccept then 
				table.insert(options, {
					details = details,
					scores ={ 
						-#details.lineIds
					}
				})
			end
		end
	end 
	if #options == 0 then 
		trace("lineManager.upgradeBusiestLines() found no options to upgrade")
		return
	end 
	local bestOption = util.evaluateWinnerFromScores(options)
	if util.tracelog then 
		debugPrint({upgradeBusiestLines=bestOption.details})
	end 
	lineManager.alreadyUgradedRoutes[bestOption.details.key] = true -- regardless of actual success
	local function callback(res,success) 
		trace("result of calling buildParralelRoute:",success) 
		if success then 
			util.clearCacheNode2SegMaps()
			lineManager.addWork(function() tryToRealignRoutesForBalancing(res, bestOption.details) end)
		end 
		--debugPrint(res)
	end 
	
	routeBuilder.buildParralelRoute(bestOption.details.edges, callback)
end 

local function countStoppedVehiclesForLine(lineId)
	 
	local total = 0 
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	
	for i, vehicle in pairs(vehicles) do 
		local vehicleInfo = util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		if vehicleInfo.state == api.type.enum.TransportVehicleState.EN_ROUTE then 
			local movePath = util.getComponent(vehicle, api.type.ComponentType.MOVE_PATH)
			 
			if movePath.dyn.speed == 0 then 
				total = total + 1
			end 
		end 
	end 
	
 
	return total 
end 

function lineManager.upgradeBusiestRoadLines() 
	util.lazyCacheNode2SegMaps()
	local lineSeen = {}
	local filterFn = function(line, lineId) 
		if isRoadLine(line) then 
			if not lineSeen[lineId] then 
				lineSeen[lineId] = {}
			end 
			return true 
		end 
		return false 
	end 
	--[[local edgeFilter = function(edgeId) 
		if util.getEdge(edgeId)  then 
			return util.edgeHasSpaceForDoubleTrack(edgeId)
		end
	end ]]--
	lineManager.railLineUpgradeRequests = {} -- reset for now, perhaps this can be smarter
	local mappedResults = pathFindingUtil.getEdgesUsedByLinesGrouped(filterFn, edgeFilter)
	
	local options = {}
	local maxLines = 0
	local maxScore2 = 0
	for key, details in pairs(mappedResults) do 
		if not lineManager.alreadyUgradedRoutes[key] then 
			local canAccept = #details.lineIds > 1  
			for edgeId, bool in pairs(details.edges) do 
				if util.getStreetTypeCategory(edgeId) == "highway" then
					if util.getNumberOfStreetLanes(edgeId) == 4 then 
						canAccept = true  
						break
					end 
				end 
			end 
			maxLines = math.max(maxLines, #details.lineIds)
			local score = -#details.lineIds
			local score2 = 0
			if canAccept then 
				for i, lineId in pairs(details.lineIds) do 
					local lineInfo = lineSeen[lineId]
					if  not lineInfo.stoppedVehicles then 
					
					
						lineInfo.stoppedVehicles = countStoppedVehiclesForLine(lineId) 
					end 
					score2 = score2 + lineInfo.stoppedVehicles
					details.score2 = score2
					maxScore2 = math.max(maxScore2, score2)
				end 
				table.insert(options, {
					details = details,
					scores ={ 
						score,
						-score2
					}
				})
			end
		end
	end 
	if #options == 0 then 
		trace("lineManager.upgradeBusiestRoadLines() found no options to upgrade")
		return
	end 
	maxLines = math.min(maxLines, 12)
	for i , bestOption in pairs(util.evaluateAndSortFromScores(options)) do 
		trace("Inspecting option at",i,"maxLines=",maxLines,"had",#bestOption.details.lineIds,"  score2=",bestOption.details.score2, "maxScore2=",maxScore2)
		if #bestOption.details.lineIds < maxLines and bestOption.details.score2 < maxScore2 then 
			trace("Exiting loop at ",i)
			break
		end 
		if util.tracelog then 
			debugPrint({upgradeBusiestLines=bestOption.details, i=i})
		end 
		if routeBuilder.upgradeRoadRoadAddLane(bestOption.details.edges, lineManager.standardCallback) then 
			lineManager.alreadyUgradedRoutes[bestOption.details.key] = true -- regardless of actual success
		end
	
		
	end
end 
local function isValid(line) 
	if #line.stops <= 1 then 
		return false 
	end 
	for i, stop in pairs(line.stops) do 
		if stop.stationGroup == -1 or stop.station == -1 then -- station was bulldozed
			return false 
		end
	end 
	return true
end 

local function getLineParams(lineId)
	local line = util.getComponent(lineId, api.type.ComponentType.LINE)
	if not isValid(line) then
		trace("Line",lineId," failed validation")
		return {}
	end
	
	local cargoType =  discoverLineCargoType(lineId)
	local distance = util.distBetweenStations(stationFromGroup(line.stops[1].stationGroup),stationFromGroup(line.stops[2].stationGroup))
	if cargoType and type(cargoType)=="number" then 
		cargoType = api.res.cargoTypeRep.getName(cargoType)
	end
	
	local params = paramHelper.getDefaultRouteBuildingParams(cargoType , isRailLine(line), false, distance)
	if cargoType == "MAIL" or cargoType == "UNSORTED_MAIL" then 
		params.useAutoLoadConfig = true 
		trace("Setting useAutoLoadConfig to true for ",lineId)
	end 
	params.lineId = lineId
	params.lineName = util.getComponent(lineId, api.type.ComponentType.NAME).name
	params.isElectricTrack = isElectricRailLine(line)
	params.line = line
	if isRailLine(line) then 
		params.stationLength = getMinStationLength (line)
		params.stationLengthParam = getMinStationLengthParam(line)
		trace("about to get vehicle")
		local vehicle = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)[1]
		trace("Got vehicle, was null?",vehicle)
		if vehicle then 
			trace("Now about to copy conifg")
			local transportVehicle = util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
			local vehicleConfig = transportVehicle.transportVehicleConfig
			trace("Got vehicleConfig, about to get consist info, vehicleConfig=",vehicleConfig)
			local info = vehicleUtil.getConsistInfo(vehicleConfig, cargoType)
			params.isHighSpeedTrack = info.isHighSpeed -- TODO: could actually look at routeinfo 
			params.isVeryHighSpeedTrain = info.isVeryHighSpeedTrain
		end 
	end
	if isShipLine(line) then 	
		params.allowLargeShips = true 
		params.allowLargeHarbourUpgrade = true
		for i , stop in pairs(line.stops) do
			local station = stationFromStop(stop)
			local construction = constructionFromStation(station)
			if not isLargeHarbour(construction) then 
				params.allowLargeShips = false 
				if not util.isSafeToUpgradeToLargeHarbour(station) then 
					params.allowLargeHarbourUpgrade = false 
				end
			end
		end 
	end 
	if isAirLine(line) then 
		params.allowLargePlanes = true 
		params.hasSecondRunway = true
		params.maxLineStops = 0
		for i , stop in pairs(line.stops) do
			local station = stationFromStop(stop)
			local construction = constructionFromStation(station)
			local lineStops = api.engine.system.lineSystem.getLineStopsForStation(station)
			params.maxLineStops = math.max(params.maxLineStops, #lineStops)
			if isAirfield(construction) then 
				params.allowLargePlanes = false 
			end
			if not hasSecondRunway(construction) then 
				params.hasSecondRunway = false
			end 
		end  
	end 
	if isBusLine(line) and #line.stops > 0 then 
		local isUrbanLine = true 
		local town = api.engine.system.stationSystem.getTown(stationFromStop(line.stops[1]))
		for i = 2, #line.stops do 
			if town ~= api.engine.system.stationSystem.getTown(stationFromStop(line.stops[i])) then 
				isUrbanLine = false 
				break 
			end 
		end 
		trace("Setup line",line,"isUrbanLine=",isUrbanLine)
		params.isUrbanLine = isUrbanLine
		
	end 
	return params
end
lineManager.getLineParams = getLineParams 

function lineManager.checkIfProblemLine(lineId) 
	local problemLines = api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer())
	for i, problemLineId in pairs(problemLines) do 
		if lineId == problemLineId then 	
			return true 
		end
	end
	if not api.engine.entityExists(lineId) then 
		return true 
	end
	return false 
end 

local function buyAndAssignVechicles(vehicleConfig, depotOptions, lineId, numberOfVehicles, callback, params)
	if not vehicleConfig then 
		trace("WARNING! No vehicleConfig provided!")
		return 
	end
	trace("createLineAndAssignVechicles: buying vehicles for ",(params and params.lineName) or lineId," numberOfVehicles=",numberOfVehicles)
	if not callback then callback = lineManager.standardCallback end
	local cost = vehicleUtil.getVehichleCost(vehicleConfig)
	local budget = numberOfVehicles * cost 
	trace("Determined budget as",budget)
	util.scheduledBudget = util.scheduledBudget + budget
	trace("Updated scheduledBudget")
	lineManager.addDelayedWork(function() lineManager.addDelayedWork(function()-- double delay just to ensure all other work gets completed
	
		trace("buyAndAssignVechicles: begin interior")
		util.ensureBudget(budget)
		
		local addDelay = 0
		if params and params.projectedIntervalPerVehicle and numberOfVehicles > 1 then 
			addDelay = math.floor((params.projectedIntervalPerVehicle*5)/#depotOptions) -- it seems there are 5 ticks per second 
		end
		if addDelay > 0 and lineManager.getBackgoundWorkQueue() > addDelay then 
			trace("Work queue already has significant delay, suppresing delay")
			addDelay =0 
		end
		lineManager.lineLastUpdateTime[lineId] = game.interface.getGameTime().time + addDelay/5
		trace("Adding background work, and adding delay?",addDelay, " set time since last updated=",lineManager.lineLastUpdateTime[lineId],"for ",(params and params.lineName),"lineId=",lineId)
		local activityLogEntry = {
			activityType = "lineManager",
			lineManagerType = "Buy",
			lineManagerReason = "New line",
			attemptedCount = numberOfVehicles,
			attemptedCost = cost * numberOfVehicles ,
			actualCount = 0,
			actualCost = 0,
			lineId = lineId,
			notes = "",
		}
		table.insert(lineManager.getActivityLog(), activityLogEntry)
		local existingVehicleCount = #api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
		local totalVehicles = existingVehicleCount + numberOfVehicles
		local line = getLine(lineId)
		if totalVehicles > 1 and isRailLine(line) then 
			local routeInfo = pathFindingUtil.getRouteInfo(stationFromStop(line.stops[1]), stationFromStop(line.stops[2]))
			if not routeInfo.isDoubleTrack then 
				trace("WARNING! buyAndAssignVechicles trying to buy more vehicles for non double track route ,attempting to correct")
				lineManager.upgradeToDoubleTrack(lineId)
			end 
		end 
		for i = 1, numberOfVehicles do 
			
			
			for i = 1, addDelay do 
				lineManager.addBackgroundWork(function() end) -- use this to schedule the purchase for later
			end 
		
			lineManager.addBackgroundWork(function() 
				trace("Buying vehicle. Scheduled budget was",util.scheduledBudget)
				util.ensureBudget(util.scheduledBudget)
				util.scheduledBudget = util.scheduledBudget - cost -- do this upfront, if anything else fails we don't withold the budget
				
				local idx = (i-1)%#depotOptions+1
				trace("about to fetch ", idx, " of ",#depotOptions, " depot for line",lineId)
				local depotOption = depotOptions[idx]
				if lineManager.checkIfProblemLine(lineId) or not api.engine.entityExists(depotOption.depotEntity) or not getLine(lineId)  then 
					trace("Aborting as a problem was found with the line") -- try to avoid crash to desktop 
					return
				end 
				
				trace("About to buy using config ", vehicleConfig, " and depot ", depotOption.depotEntity, " stopIndex was",depotOption.stopIndex)
				local apiVehicle = vehicleUtil.copyConfigToApi(vehicleConfig)
				trace("Created apiVehicle, about to create buy command")
				--if util.tracelog then 
					--debugPrint(apiVehicle)
				--end
				local buyCommand = api.cmd.make.buyVehicle( api.engine.util.getPlayer(),depotOption.depotEntity, apiVehicle )
				trace("Created buy command about to send")
				api.cmd.sendCommand(buyCommand, function(res, success) 
					trace("Send buy command success was",success)
					lineManager.executeImmediateWork(function() 
						if success then 
							activityLogEntry.actualCount = activityLogEntry.actualCount + 1 
							activityLogEntry.actualCost = activityLogEntry.actualCost + cost
							if lineManager.checkIfProblemLine(lineId)  then 
								trace("Aborting assingment as problem was found with the line") -- try to avoid crash to desktop 
								return
							end 
							lineManager.executeImmediateWork(function()
								if lineManager.checkIfProblemLine(lineId)  or not api.engine.entityExists(depotOption.depotEntity)  then 
									trace("Aborting assingment as problem was found with the line") -- try to avoid crash to desktop 
									return
								end 
								local line = getLine(lineId)
								if not line then 	
									error("No line got for "..tostring(lineId))
								end 
								depotOption.stopIndex = math.min(depotOption.stopIndex, #line.stops-1) -- this may happen if stops have been repositioned
								local station =  stationFromStop(line.stops[depotOption.stopIndex+1])
								local count = 0
								while station == -1 and count <= #line.stops  do 
									count = count+1
									trace("WARNING!, line had invalid station, attempting to correct using  depot option at",count)
									depotOption = depotOptions[count%#depotOptions+1]
									station =  stationFromStop(line.stops[depotOption.stopIndex+1])
								end 
								lineManager.assignVehicleToLine(res.resultVehicleEntity, lineId, callback, depotOption.stopIndex, buyCommand, res)
							end)		
						else 
							lineManager.lineLastUpdateTime[lineId]=nil -- allow this to be reexamined next cycle
						end 
						lineManager.standardCallback(res, success)
					end)
				end)
			end)

		end
	end) end)
end

local function  getStopPosition(line, stopIndex)
	local stop = line.stops[1+stopIndex]
	local stationId = stationFromGroup(stop.stationGroup)
	return util.getStationPosition(stationId)
end

function lineManager.findDepotsForLine(lineId, carrier, nonStrict, isElectric)
	trace("Finding depots for line",lineId,"isElectric?",isElectric)
	local line = util.getComponent(lineId, api.type.ComponentType.LINE)
	if not carrier then 
		carrier = discoverLineCarrier(line)
	end
	if carrier == api.type.enum.Carrier.WATER and false then
		local result = {} 
		for i, stop in pairs(line.stops) do
			local stopIndex = i-1
			local stopPos = getStopPosition(line, stopIndex)
			local constructionId = constructionUtil.searchForShipDepot(stopPos, 1500)
			if constructionId then 
				table.insert(result, {
					stopIndex = stopIndex,
					depotEntity = depotFromConstruction(constructionId) 
				})
			end
		end
		return result
	end
	if carrier == api.type.enum.Carrier.AIR then 
		local result = {} 
		for i, stop in pairs(line.stops) do
			local station = stationFromGroup(stop.stationGroup)
			local depotEntity = util.getConstructionForStation(station).depots[1]
			if depotEntity then 
				table.insert(result, {
					stopIndex = i-1,
					depotEntity = depotEntity
				})
			end 
		end
		return result
	end

	local matchingTypes = {}
	trace("About to get line for lineId ",lineId)
	--collectgarbage() -- try to prevent random crashing in the next part
	trace("Got line, about to loop over depots")
	local allDepots = {} 
	api.engine.system.vehicleDepotSystem.forEach(function(depotEntity) 
		table.insert(allDepots, depotEntity)
		
	end)
	-- broken into two seperate loops to try to avoid random crashing
	for i , depotEntity in pairs(allDepots) do 
		local depot = util.getComponent(depotEntity, api.type.ComponentType.VEHICLE_DEPOT)
		if depot.carrier == carrier then
			table.insert(matchingTypes, depotEntity)
		end
	end 
	
	trace("There were ",#matchingTypes," for carrier ",carrier)
	trace("===== DEPOT DETAILS =====")
	for _, depotEntity in pairs(matchingTypes) do
		trace("  depot entity=", depotEntity)
	end

	local optionsByStopIndex = {} 
	local isRoadOrTramLine = carrier == api.type.enum.Carrier.ROAD or carrier == api.type.enum.Carrier.TRAM
	local range = isRoadOrTramLine and 1500 or math.huge
	local function getDepots()
		for i, depotEntity in pairs(matchingTypes) do
			--trace("Looking for closest to depot for depot ", depotEntity)

			for i, stopIndexDetail in pairs(pathFindingUtil.findStopIndexesForDepot(depotEntity, line, nonStrict, isElectric, range )) do 
				--trace("Found stopIndex=",stopIndex)
				local stopIndex = stopIndexDetail.stopIndex
				local depotPos = util.getDepotPosition(depotEntity)
				--trace("Getting stop pos")
				local stopPos = getStopPosition(line, stopIndex)
				if  util.distance(depotPos, stopPos) > range then
					--trace("Skipping check as the gap is too big")
					goto continue 
				end
				if not optionsByStopIndex[stopIndex] then
					optionsByStopIndex[stopIndex]={}
				end
				table.insert(optionsByStopIndex[stopIndex], {
					stopIndex = stopIndex,
					depotEntity = depotEntity,
					distance = stopIndexDetail.distance,
					scores = { stopIndexDetail.distance } 
				
				}) 	
				::continue::
			end
		end
	end 
	getDepots()
	if util.size(optionsByStopIndex) == 0 then 
		trace("WARNING! Initially no depots were found at range",range)
		trace(debug.traceback())
		if range~=math.huge then 
			range = range*2 
			getDepots()
			trace("Attempting with a larger range, found:",util.size(optionsByStopIndex))
		end 
	end
	local result = {}
	for stopIndex, options in pairs(optionsByStopIndex) do 
		table.insert(result, util.evaluateWinnerFromScores(options))
	end
 	return util.evaluateAndSortFromSingleScore(result, function(option) return option.distance end) -- order the closest one first in case we just buy one vehicle
	--return result
end

local function estimateTotalTimeForLine(lineId, transportVehicleConfig, params )
	local line = util.getComponent(lineId, api.type.ComponentType.LINE)
	local totalTime = 0 
	if not params then 
		params = getLineParams(lineId)
		params.line = line
	end
	local transportVehicleConfig
	local transportVehicle -- prevent gc
	if vehicle then 
		transportVehicle = util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		transportVehicleConfig =  transportVehicle.transportVehicleConfig
	else 
		transportVehicleConfig = lineManager.estimateInitialConsist(params, params.distance).vehicleConfig 
	end
 --[[
	for i =2 , #line.stops do 
		local station1 = stationFromGroup(line.stops[i-1].stationGroup)
		local station2 = stationFromGroup(line.stops[i].stationGroup)
		local distance = util.distBetweenStations(station1, station2)
		params.distance = distance
		totalTime = totalTime + 0.5*vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params).totalTime
		if i == #line.stops then
			station1 = stationFromGroup(line.stops[1].stationGroup)
			distance = util.distBetweenStations(station1, station2)
			params.distance = distance
			totalTime = totalTime + 0.5*vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params).totalTime
		end
	end]]--
	totalTime = vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params).totalTime
	trace("Estimated total time for line ",lineId," as ",totalTime)
	return totalTime
end


function lineManager.buildTrain(depot, line, cargoType, targetCapacity, params)

		
		--debugPrint({buyVehicle=buyVehicle})
		api.cmd.sendCommand(buyVehicle, function(res, success) 
			trace("buyVehicle result was ",success)
			if success then 
				lineManager.assignVehicleToLine(res.resultVehicleEntity, line, standardCallback )
				
			end
			--debugPrint({buyVehicleres=res})
			workComplete=true
		end)
	
end

function lineManager.removeLine(lineId) 
	trace("lineManager.removeLine for",lineId)
	api.cmd.sendCommand(api.cmd.make.deleteLine(lineId), function(res, success) 
		trace("lineManager.removeLine: callback result was",success)
	end)
end 


function lineManager.estimateInitialConsist(params, distance, stations) 
	local begin = os.clock()
	local targetLineRate = params.rateOverride or params.initialTargetLineRate or params.targetThroughput
	local numberOfVehicles = 1
	if not targetLineRate then 
		trace("WARNING! no target line rate set, defaulting")
		targetLineRate = 100
	end
	params.targetThroughput=targetLineRate
	params.initialTargetLineRate=targetLineRate
	local isCircleLine = false

	if stations then 
		local minLength = math.huge
		local alreadySeen = {}
		isCircleLine = #stations > 2
		params.routeInfos = {}
		distance = 0
		for i = 1 , #stations do 
			
			local station = stations[i]
			local nextStation = i == #stations and stations[1] or stations[i+1]
			if alreadySeen[station] then 
				isCircleLine = false 
			else 
				alreadySeen[station]=true
			end 
			params.routeInfos[i]= pathFindingUtil.getRouteInfoAutoTerminals(station,nextStation )
			local distToNext = util.distBetweenStations(station, nextStation)
			distance = distance + distToNext
			minLength = math.min(minLength, constructionUtil.getStationLength(station))
		end 
		if #stations>0 then 
			params.stationLength = minLength
		end 
	end 
	
	if params.cargoType == "PASSENGERS"   then 
	
		 
		local initialEstimate = vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
		if initialEstimate.isEmptyConsist then 
			trace("WARNING! Initial consist was empty, trying again without cost constraints")
			params.constrainVehicleBudget = false
			initialEstimate = vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
		end
		params.constrainVehicleBudget = true
		local twentyMinutes = 20*60 -- I think this is the reachability threshold 
		local fractionOfTotal = math.min(1,twentyMinutes / initialEstimate.totalTime) -- simple heuristic to try to adjust for reachability
		params.fractionBasedReachability = {
			totalTime = initialEstimate.totalTime, 
			fractionOfTotal = fractionOfTotal,
		}
		local adjustedTargetLineRate = math.max(25, fractionOfTotal*targetLineRate) 
		trace("Adjusting the target down from", targetLineRate,"to ",adjustedTargetLineRate,"based on fractionOfTotal=",fractionOfTotal)
		targetLineRate = adjustedTargetLineRate
	end
	if isCircleLine then 
		trace("reducing target linerate for due to circle, was",targetLineRate)
		targetLineRate = targetLineRate / 2
	end 
	
	if params.cargoType == "PASSENGERS"   then 
		
		 
		
		if  targetLineRate> 1500 then 
			trace("Setting upper limit for passenger rate",targetLineRate)
			targetLineRate = 1500
			if params.targetThroughput and not params.rateOverride then 
				params.targetThroughput = math.min(params.targetThroughput, 1500)
			end
			if params.initialTargetLineRate and not params.rateOverride then 
				params.initialTargetLineRate = math.min(params.initialTargetLineRate, 1500)
			end
		end
	end
	trace("estimateInitialConsist: got target line rate of ",targetLineRate)
	if params.cargoType == "PASSENGERS" and stations and #stations>2 then 
		targetLineRate = targetLineRate / math.log(#stations, 2)
		trace("Reduced targetLineRate to ",targetLineRate, " for multi station route")
	end 
	
	
	
	params.targetThroughput = targetLineRate
	params.totalTargetThroughput = targetLineRate
	local estimate = vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
	if estimate.isEmptyConsist then 
		trace("WARNING! Initial consist was empty, trying again without cost constraints")
		params.constrainVehicleBudget = false
		estimate = vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
	end
	-- Fix (community-reported): even without budget constraints the consist can
	-- stay empty (e.g. no wagon matches the cargo in this climate/era). Guard
	-- against arithmetic on nil totalCapacity and division by zero.
	if not estimate.totalCapacity or not estimate.throughput or estimate.throughput == 0 then
		estimate.totalCapacity = estimate.totalCapacity or 100
		estimate.throughput = estimate.throughput or 1
	end
	local targetCapacity = estimate.totalCapacity * (targetLineRate/estimate.throughput)
	trace("Estimated throuput per consist, time taken was ",os.clock()-begin, " targetLineRate was ",targetLineRate, " throughput =",estimate.throughput)
	if estimate.isMaxLength and params.isDoubleTrack or estimate.throughput < 0.75*targetLineRate then 
		numberOfVehicles = math.ceil(targetLineRate/estimate.throughput)
		targetCapacity = estimate.totalCapacity * (targetLineRate/(numberOfVehicles*estimate.throughput))
		trace("recaulculated numberofVehicles to ",numberOfVehicles, " and targetCapacity=", targetCapacity)
		if numberOfVehicles > 1 and not params.isDoubleTrack then 
			trace("Setting double tracking to true")
			params.isDoubleTrack = true
		end 
	end
	if params.cargoType == "PASSENGERS"     then 
		if (estimate.totalTime/numberOfVehicles) > paramHelper.getParams().targetMaximumPassengerInterval then 
			local previousNumberOfVehicles = numberOfVehicles
			numberOfVehicles = math.ceil(estimate.totalTime/paramHelper.getParams().targetMaximumPassengerInterval)
			targetCapacity = (previousNumberOfVehicles/numberOfVehicles)*targetCapacity
			trace("To satisfy passenger intervals recaulculated numberofVehicles to ",numberOfVehicles, " and targetCapacity=", targetCapacity, " previousNumberOfVehicles=",previousNumberOfVehicles)
		elseif (estimate.totalTime/numberOfVehicles) < paramHelper.getParams().minimumInterval then 
			local previousNumberOfVehicles = numberOfVehicles
			numberOfVehicles = math.max(1,math.floor(estimate.totalTime/paramHelper.getParams().minimumInterval))
			targetCapacity = (previousNumberOfVehicles/numberOfVehicles)*targetCapacity
			trace("Initial calculation put number of vehicles too high, reduced numberofVehicles to ",numberOfVehicles, " and targetCapacity=", targetCapacity, " previousNumberOfVehicles=",previousNumberOfVehicles)
		end
		if stations and #stations > 4 then 
			local maxVehicles = math.max(2*#stations, math.ceil(distance/4000))
			numberOfVehicles = math.min(maxVehicles, numberOfVehicles)
			trace("Clamped numberOfVehicles to ",numberOfVehicles,"against maxVehicles",maxVehicles,"distance=",distance,"numStations=",#stations)-- avoid excessive vehicle assignments
		end
	end	
	
	trace("Calculated a targetCapacity of ", targetCapacity, " based on targetLineRate of",targetLineRate, "numberOfVehicles=",numberOfVehicles) 
	params.totalTargetThroughput = targetLineRate
	params.targetThroughput = targetLineRate / numberOfVehicles
	local vehicleConfig = vehicleUtil.buildTrain(targetCapacity, params)	
	local info = vehicleUtil.getConsistInfo(vehicleConfig, params.cargoType)
	trace("Estimated initial consist,total time taken was ",os.clock()-begin)
	local balance = util.getAvailableBudget()
	local routeCost = (distance/1000) * paramHelper.getParams().assumedCostPerKm
	local availableBalance = math.max(0, balance - routeCost)
	local stationName = stations and stations[1] and util.getName(stations[1])
	if isCircleLine then 
		trace("Reducing the available budget by half for circle line for line starting at",stationName)
		availableBalance = availableBalance / 2
	end
	if (info.cost*numberOfVehicles) > availableBalance then 
		local oldNumber = numberOfVehicles 
		
		numberOfVehicles = math.max(1, math.floor(availableBalance/info.cost))
		--[[params.targetThroughput = targetLineRate
		vehicleConfig = vehicleUtil.buildTrain(targetCapacity*(oldNumber/numberOfVehicles), params)	
		info = vehicleUtil.getConsistInfo(vehicleConfig, params.cargoType)]]--
		trace("Clamping the number of vehicles due to current balance to",numberOfVehicles," from ",oldNumber," for line starting at",stationName)
	end 
	return {
		vehicleConfig = vehicleConfig,
		info = info,
		numberOfVehicles = numberOfVehicles,
		projectedTime = estimate.totalTime
	}
	
end
function lineManager.setupTrainLineParams(params, distance)
	local initialConsist = lineManager.estimateInitialConsist(params, distance)
	params.isElectricTrack = initialConsist.info.isElectric
	params.isHighSpeedTrack = initialConsist.info.isHighSpeed
	params.isDoubleTrack  = initialConsist.numberOfVehicles > 1 
	params.isVeryHighSpeedTrain = initialConsist.info.isVeryHighSpeedTrain
	if not params.isCargo then 
	
	end
	params.initialConsistCost = initialConsist.info.cost
	if params.isHighSpeedTrack and not params.isCargo then 
		params.smoothingPasses = params.smoothingPasses*2
	end 
	if params.isCargo and not params.stationLengthOverriden then 
		if initialConsist.info.length < 120 and initialConsist.numberOfVehicles == 1 and distance < paramHelper.getParams().thresholdDistanceForPriorStationLength and params.stationLengthParam > 2   then 
			params.stationLengthParam = 2
			params.stationLength = 160
		elseif distance > paramHelper.getParams().thresholdDistanceForNextStationLength and params.stationLength < paramHelper.getMaxStationLength()  then 
			params.stationLengthParam = params.stationLengthParam + 1
			params.stationLength = paramHelper.getStationLength(params.stationLengthParam)
		end
	end 
end

function lineManager.checkForExtensionPosibilities(params, station)
	if util.isStationTerminus(station) then 
		trace("Station terminus detected, extension not possible from",station)
		return 
	end 
	local freeTerminal = util.getFreeTerminals(station)[1]
	if not freeTerminal then 
		trace("WARNING! No free terminal found for ",station, "aborting")
		return
	end		
	for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station))) do
		local line = getLine(lineId)
		if stationAppearsOnceOnLineAndAdjacentToFreeTerminal(line, station,freeTerminal) then 
			trace("Discovered an extension possibility from line") 
			local theirLineParams = getLineParams(lineId)
			params.isHighSpeedTrack = params.isHighSpeedTrack or theirLineParams.isHighSpeedTrack
			params.isVeryHighSpeedTrain = params.isVeryHighSpeedTrain or theirLineParams.isVeryHighSpeedTrain
			params.stationLengthParam = math.max(params.stationLengthParam, theirLineParams.stationLengthParam)
			params.stationLength = math.max(params.stationLength, theirLineParams.stationLength)
			trace("Overriding isHighSpeedTrack to",params.isHighSpeedTrack," isVeryHighSpeedTrain=",params.isVeryHighSpeedTrain)
		end 
	end
end

function lineManager.createNewTrainLineBetweenStations(stations, params, callback, suffix) 
	local station1 = stations[1]
	
	params.routeInfos = {}
	params.stationLength = math.huge 
	params.distance =0 
	for i = 1, #stations do 
		local station = stations[i]
		local nextStation = i == #stations and stations[1] or stations[#stations] 
		params.routeInfos[i] =  pathFindingUtil.getRouteInfo(station, nextStation) 
		params.stationLength = math.min(params.stationLength, constructionUtil.getStationLength(station))
		params.distance = params.distance + util.distBetweenStations(station, nextStation)
	end 
	
 
	local lineName 
	if params.cargoType == "PASSENGERS" then
		local townName = util.getComponent(station1, api.type.ComponentType.NAME).name
		if not suffix then suffix = _("Express") end
		lineName = townName.." "..suffix
	else 
		local stationName = util.getComponent(station1, api.type.ComponentType.NAME).name
		lineName = stationName.." "..util.getUserCargoName(params.cargoType)
	end
	params.lineName = lineName
	params.constrainVehicleBudget = true
	trace("The target throughput was ",params.targetThroughput," the initialTargetLineRate was ",params.initialTargetLineRate, " for ",lineName,"params.stationLength=",params.stationLength)
	params.targetThroughput = params.initialTargetLineRate
	local vehicleInfo = lineManager.estimateInitialConsist(params, distance, stations) 
	local vehicleConfig = vehicleInfo.vehicleConfig
	local numberOfVehicles = vehicleInfo.numberOfVehicles
	trace("Got vehicle config=",vehicleConfig)
	
	
	
	if not params.isDoubleTrack then 
		numberOfVehicles = 1
		trace("For  ",lineName, " setting numberofVehicles to 1 due to lack of double track")
	end 
	
	params.projectedIntervalPerVehicle = vehicleInfo.projectedTime / numberOfVehicles
	
	if params.isCargo then 
		--params.isWaitForFullLoad = true
		if params.isAutoBuildMode and false then --TODO need to evaluate this function some more
			--lineManager.addWork(lineManager.upgradeBusiestLines)
		end 
	end 
	lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfVehicles, api.type.enum.Carrier.RAIL, params, callback )
end

function lineManager.setupTrainLineBetweenStations(station1, station2, params, callback) 
	util.lazyCacheNode2SegMaps()
	if not lineManager.checkIfLineCanBeExtended(station1, station2, callback) then
		lineManager.createNewTrainLineBetweenStations({station1, station2}, params, callback) 
	end
end

function lineManager.getBusAndTramLinesForTown(town) 
	local result = {}
	local alreadySeen = {} 
	for i , stationId in pairs(api.engine.system.stationSystem.getStations(town)) do
		for j, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(stationId)) do 
			if not alreadySeen[lineId] then  
				alreadySeen[lineId] = true 
				local line = getLine(lineId)
				if isBusLine(line) or isTramLine(line) then 
					local allWithinThisTown = true 
					for k, stop in pairs(line.stops) do 
						local station2 = stationFromStop(stop)
						if api.engine.system.stationSystem.getTown(station2)~=town then 
							allWithinThisTown = false 
							break 
						end
					end 
					if allWithinThisTown then 
						table.insert(result, lineId) 
					end
				end
			end 
		end 
	end
	
	return result
end 
local function checkForLineUpgrades(lineId, line, report, newVehicleConfig, params, oldVehicleConfig)
	if isRailLine(line)  then 
		local info = vehicleUtil.getConsistInfo(newVehicleConfig, params.cargoType)
		if info.isElectric and not params.isElectricTrack then 
			report.upgrades.needsElectricUpgrade = true	
		else 
			local oldInfo =  vehicleUtil.getConsistInfo(oldVehicleConfig, params.cargoType)
			if info.isElectric and not oldInfo.isElectric then 
				report.upgrades.needsElectricUpgrade = true 
				trace("Inspecting the old info and found needs electric upgrade")
			end 
		end 
		if info.isHighSpeed and not params.isHighSpeedTrack then
			report.upgrades.needsHighSpeedUpgrade = true
		end
		trace("Checking line",lineId,report.lineName," if it needs upgrades, info.isElectric?",info.isElectric,"params.isElectricTrack?",params.isElectricTrack, "report.upgrades.needsElectricUpgrade?",report.upgrades.needsElectricUpgrade)
		params.isElectricTrack = params.isElectricTrack or info.isElectric
		params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
		params.isVeryHighSpeedTrain = info.isVeryHighSpeedTrain
		if report.upgrades.needsElectricUpgrade  or report.upgrades.needsHighSpeedUpgrade then 
			trace("Trace adding the execution function to check for upgrades for line",lineId,report.lineName)
			table.insert(report.executionFns,1, function() -- set this first to prioritise
				trace("Checking track for upgrades for line",lineId,report.lineName)
				routeBuilder.checkForTrackupgrades(line, lineManager.standardCallback, params, lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL, true))
			end)
			if report.complementaryLine then 
				table.insert(report.executionFns,1, function() 
					trace("Checking track for upgrades for complementaryLine line",report.complementaryLine)
					routeBuilder.checkForTrackupgrades(getLine(report.complementaryLine), lineManager.standardCallback, params, lineManager.findDepotsForLine(report.complementaryLine, api.type.enum.Carrier.RAIL, true))
				end)
			end 
		end 
		
	end 
	if isShipLine(line)   then 
		if vehicleUtil.isLargeShip(newVehicleConfig) and not params.allowLargeShips then 
			report.upgrades.needsHarbourUpgrade=true 
			for i , stop in pairs(line.stops) do 
				local station = stationFromStop(stop)
				table.insert(report.executionFns, function() 
					trace("upgrading to large harbour")
					constructionUtil.upgradeToLargeHarbor(station)
				end)
			end 
		end 
	end 
	if isTramLine(line) and not isElectricTramLine(line) then 
		if vehicleUtil.isElectricTram(newVehicleConfig) then 
			report.upgrades.electricTramTrack=true 
			table.insert(report.executionFns, function() 
				
				params.tramTrackType = 2
				params.tramOnlyUpgrade = true
				trace("upgrading to electricTramTrack")
				for i =1 ,#line.stops do 
					local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
					util.cacheNode2SegMaps()
					local routeInfo = function() return  pathFindingUtil.getRoadRouteInfoBetweenStations(stationFromStop(priorStop), stationFromStop(line.stops[i]),true) end
					
					routeBuilder.checkRoadForUpgradeOnly(routeInfo, lineManager.standardCallback, params)  
				end  
				for i =1 ,#line.stops do 
					local station = stationFromStop(line.stops[i])
					if not util.isBusStop(station) then 
						constructionUtil.checkBusStationForUpgrade(station, true)
					end
				end 
				for i , depotOption in pairs(lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.TRAM, false)) do 
					local depotEntity = depotOption.depotEntity 
					local stop = line.stops[depotOption.stopIndex+1]
					util.cacheNode2SegMaps()
					trace("Finding route info for depot",depotEntity)
					local routeInfo = function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findPathFromDepotToStop(depotEntity, stop, true, line)) end
					routeBuilder.checkRoadForUpgradeOnly(routeInfo, lineManager.standardCallback, params)  
					constructionUtil.upgradeToElectricTramDepot(depotOption.depotEntity)
					 
				end
				
			end)
		end
	end 
	if isRoadLine(line) and not isTramLine(line) and not params.isUrbanLine  then 
		local topSpeedNew = vehicleUtil.getTopSpeed(newVehicleConfig) 
		local topSpeedOld = vehicleUtil.getTopSpeed(oldVehicleConfig) 
		trace("The old topSpeed was",api.util.formatSpeed(topSpeedOld)," the new top speed was",api.util.formatSpeed(topSpeedNew))
		if topSpeedNew > topSpeedOld or report.problems.hasOldStreetSections then
			table.insert(report.executionFns, function()  
				trace("Checking road route for possible upgrades")
				for i =1 ,#line.stops do 
					util.lazyCacheNode2SegMaps()
					local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
					local routeInfo = function() return pathFindingUtil.getRoadRouteInfoBetweenStations(stationFromStop(priorStop), stationFromStop(line.stops[i])) end
					
					routeBuilder.checkRoadForUpgradeOnly(routeInfo, lineManager.standardCallback, params)  
				end  
			end)
		end
	end
end

function lineManager.getDemandRate(lineId,line, report, params )
	if params.isCargo then 
		local sourceEntity
		local targetEntity
		local targetAlreadySeen = {} 
		local production = 0 
		local cargoSourceMap 
		if lineManager.cargoSourceMap then 
			cargoSourceMap = lineManager.cargoSourceMap 
		else 
			cargoSourceMap = util.deepClone(api.engine.system.stockListSystem.getCargoType2stockList2sourceAndCount())
		end
		local cargoTypeName 
		local cargoType = params.cargoType 
		if type(cargoType)=="string" then 
			cargoTypeName = cargoType
			cargoType = api.res.cargoTypeRep.find(cargoType) 
		else 
			cargoTypeName = api.res.cargoTypeRep.getName(cargoType)
		end 
		 
		
		for i, simCargoId in pairs(util.deepClone( api.engine.system.simCargoSystem.getSimCargosForLine(lineId))) do
			local simCargo = util.getComponent(simCargoId, api.type.ComponentType.SIM_CARGO)
			if simCargo and simCargo.sourceEntity >0 and simCargo.targetEntity > 0 then -- this is subject to a race condition if the cargo dissapears
				sourceEntity = simCargo.sourceEntity
				targetEntity = simCargo.targetEntity
				if not targetAlreadySeen[targetEntity] then 
					targetAlreadySeen[targetEntity]={}
				end 
				if not targetAlreadySeen[targetEntity][sourceEntity] and cargoSourceMap[cargoType+1][targetEntity] then 
					local thisProduction = cargoSourceMap[cargoType+1][targetEntity][sourceEntity]
					if thisProduction then 
						production = production + thisProduction
						targetAlreadySeen[targetEntity][sourceEntity] = true
					end
				end
			end 
		
		end
		if targetEntity and sourceEntity then 
			trace("ABout to get construction for ",targetEntity)
			local townBuilding = util.getConstruction(targetEntity).townBuildings[1]
			if townBuilding then -- the above approach does not quite capture all the demand, attempt to correct
				local townBuildingComp = util.getComponent(townBuilding, api.type.ComponentType.TOWN_BUILDING)
				local town = townBuildingComp.town
				local townSupply = game.interface.getTownCargoSupplyAndLimit(town)
				trace("Looking up town supply for ",cargoTypeName)
				if townSupply[cargoTypeName] then 
					local townLimit = townSupply[cargoTypeName][2]
					local industryShipping = game.interface.getIndustryShipping(sourceEntity)
					trace("Found a town shipment, town limit",townLimit, " industryShipping=",industryShipping," initial production calculated as",production)
					production = math.max(production, math.min(townLimit, industryShipping))
					trace("Production recaulculated to ",production)
				else 
					trace("WARNING! No townSupply found for ",cargoTypeName)
				end 
			end 
		end
		
		return production
	else 
		-- not sure this is technically correct but it seems close most of the time
		local currentSimsForLine = #api.engine.system.simPersonSystem.getSimPersonsForLine(lineId)
		local lineEntity = util.getEntity(lineId) 
		if lineEntity.itemsTransported._lastYear.PASSENGERS then -- actually transported amount must place a lower bound on the rate
			currentSimsForLine = math.max(currentSimsForLine, lineEntity.itemsTransported._lastYear.PASSENGERS)
		end 
		if report.isCircleLine and report.complementaryLine then 
			local currentSimsForLine2 = #api.engine.system.simPersonSystem.getSimPersonsForLine(report.complementaryLine)
			local lineEntity2 = util.getEntity(report.complementaryLine) 
			if lineEntity2.itemsTransported._lastYear.PASSENGERS then 
				currentSimsForLine2 = math.max(currentSimsForLine2, lineEntity2.itemsTransported._lastYear.PASSENGERS)
			end 
			trace("Estimating demand rate, got complementaryLine",report.complementaryLine,"for",lineId,"the currentSimsForLine was",currentSimsForLine,"and currentSimsForLine2 was",currentSimsForLine2,"combining")
			currentSimsForLine = (currentSimsForLine+currentSimsForLine2) / 2 -- try to keep circle lines in sync 
		end 
		
		return  currentSimsForLine / math.log(#line.stops, 2) -- approximate demand across multiple stops
	end 

end

local function sellUnmatchedConfig(lineId, report, params) 
	 
	local vehiclesByType = {}
	trace("Selling unmatched config")
	local gameTime = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	local vehicles = util.deepClone(api.engine.system.transportVehicleSystem.getLineVehicles(lineId))
	for i, vehicle in pairs(vehicles) do 
		local tnVehicle =util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		local config=  tnVehicle.transportVehicleConfig
		local leadVehicle = config.vehicles[1]
		local modelHash = leadVehicle.part.modelId + 100000 * #config.vehicles + (100000*100000 *  config.vehicles[#config.vehicles].part.modelId) -- hash of start and end vehicle and the length
		if not vehiclesByType[modelHash] then 
			vehiclesByType[modelHash] = {}
		end 
		local purchaseTime = leadVehicle.purchaseTime 
		local age = (gameTime-purchaseTime)
		table.insert(vehiclesByType[modelHash], { idx = i, age = age })
		
	end 
	local function getMaxAgeOfModelHash(modelHash)
		local maxAge = 0
		for i, vehicle in pairs(vehiclesByType[modelHash]) do
			maxAge = math.max(vehicle.age, maxAge)
		end 
		trace("The maxAge of modelHash",modelHash,"was",maxAge)
		return maxAge
	end 
	
	local options = util.getKeysAsTable(vehiclesByType)
	
	
	local toKeep = util.evaluateWinnerFromSingleScore(options, getMaxAgeOfModelHash)
	trace("The hashToKeep was",toKeep)
	report.recommendations.vehiclesToSell =0 
	for modelHash, vehicleType in pairs(vehiclesByType) do 
		if modelHash ~= toKeep then 
			trace("Selling ",modelHash) 
			for i, vehicle in pairs(vehiclesByType[modelHash]) do
				report.recommendations.vehiclesToSell = report.recommendations.vehiclesToSell + 1
				local vehicleToSell = vehicles [vehicle.idx]
				table.insert(report.executionFns, function() api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell), lineManager.standardCallback) end)
			 
			end  
		else 
			trace("Keeping ",modelHash)
		end 
	end 
	
	
end 

local function sellStuckVehicles(lineId, report, params) 
	trace("Found stuck vehicles to sell")
	local scoreFns = { 
		function(vehicle) return vehicle.approachingStation and 0 or 1 end ,
		function(vehicle) return vehicle.timeStanding end 
	}
	
	local orderedResult = util.evaluateAndSortFromScores(report.stoppedEnRoute, {75, 25}, scoreFns)
	local toSell = math.floor(report.vehicleCount/2)
	report.recommendations.vehiclesToSell = toSell
	for i = 1, toSell do 
		local vehicleToSell = orderedResult[i].vehicleId
		trace("Selling stuck vehicle", vehicleToSell)
		table.insert(report.executionFns, function() api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell), lineManager.standardCallback) end)
	end 
end 


function lineManager.buildDepotForLine(lineId, callback)
	local params = lineManager.getLineParams(lineId) 
	local line = getLine(lineId)

	if #line.stops < 2 then 
		trace("WARNING! Unable to buildDepotForLine",lineId,"not enough stops",#line.stops)
		if callback then 
			callback({}, false)
		end 
		return 
	end 
	local carrier = discoverLineCarrier(line)
	constructionUtil.buildDepotAlongRoute(stationFromStop(line.stops[1]),stationFromStop(line.stops[2]), params, carrier, callback, line)		
end

local function addMoreVehicles(lineId,line, report, params ) 
	if report.problems.mixedTransportVehicles and not report.isForVehicleReport then 
		sellUnmatchedConfig(lineId, report, params) 
		return -- rest of the logic assumes all vehicles are the same 
	end 
	if report.problems.stuckVehicles and not report.isForVehicleReport  then 
		sellStuckVehicles(lineId, report, params) 
		return -- rest of the logic assumes all vehicles are the same 
	end 
	local rateBelowEstimate = report.problems.rateBelowProduction
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	local vehiclesToBuy = 0 
	local vehiclesToReplace = 0
	local vehiclesToSell = 0
	local newVehicleConfig
	local carrier = report.carrier--vehicles[1] and util.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE).carrier
	local isRail = isRailLine(line) or carrier == api.type.enum.Carrier.RAIL
	params.routeLength = report.routeLength
	params.routeInfos = report.routeInfos
	params.allowPassengerElectricTrains= paramHelper.getParams().allowPassengerElectricTrains
	params.allowCargoElectricTrains= paramHelper.getParams().allowCargoElectricTrains
	local cargoType = params.cargoType 
	local isCargo = cargoType ~= api.res.cargoTypeRep.find("PASSENGERS") and cargoType ~= "PASSENGERS"
	trace("Recieved instruction to add more vehicles. Checking line",lineId, " cargoType was",cargoType)
	if #vehicles == 0 then 
		trace("Unable to proceed with no vehicles")
		return 
	end
	
	local maxVehicles = math.huge
	if report.isAirLine then 
		maxVehicles = 10*#line.stops / (params.maxLineStops)
		if not params.allowLargePlanes then 
			maxVehicles = maxVehicles / 2
		end 
		if params.hasSecondRunway then 
			maxVehicles = maxVehicles * 2
		end 
		maxVehicles = math.ceil(maxVehicles)
		trace("addMoreVehicles, set the vehicle limit to ",maxVehicles,"for airline",lineId, report.lineName)
	elseif report.isRoadLine then
		local minInterval = paramHelper.getParams().minimumIntervalRoad
		if report.estimatedCurrentThroughput then
			local totalTime = report.estimatedCurrentThroughput.totalTime
			maxVehicles = math.ceil(totalTime/minInterval)
			trace("addMoreVehicles: , set the vehicle limit to ",maxVehicles,"for road line",lineId, report.lineName," based on totalTime=",totalTime,"minInterval=",minInterval)
		else
			-- CLAUDE FIX: Fallback for new lines - estimate from route length
			-- Assume ~20 km/h average speed for early trucks
			local estimatedSpeed = 20 / 3.6 -- m/s
			local routeLen = report.routeLength or 2000
			local estimatedTotalTime = routeLen * 2 / estimatedSpeed -- round trip
			maxVehicles = math.ceil(estimatedTotalTime/minInterval)
			trace("addMoreVehicles: FALLBACK vehicle limit to ",maxVehicles," for road line",lineId, report.lineName," based on estimated routeLength=",routeLen)
		end
		-- CLAUDE FIX: Apply hard cap to road lines
		local hardCap = paramHelper.getParams().maxInitialRoadVehicles or 3
		if maxVehicles > hardCap then
			trace("addMoreVehicles: HARD CAP from",maxVehicles,"to",hardCap)
			maxVehicles = hardCap
		end

	elseif report.isRailLine then 
	
		if isCargo then 
			local minInterval = paramHelper.getParams().minimumInterval
			if report.currentInterval > minInterval then 
				maxVehicles = math.floor((report.currentInterval/minInterval)*#vehicles)
				trace("Setting the maxVehicles to ",maxVehicles,"for",report.lineName,"based on interval")
			end 
		else  
			local distPerVehicle = 2000
			if params.isHighSpeed then 
				distPerVehicle = 2*distPerVehicle
			end 
			
			maxVehicles = math.max(#line.stops, math.floor(report.routeLength/distPerVehicle))
			trace("Setting the maxVehicles to ",maxVehicles,"for",report.lineName,"based on routeLength",report.routeLength,"using distPerVehicle",distPerVehicle,"and numstops=",#line.stops)
			if report.hasDoubleTerminals then 
				maxVehicles = maxVehicles * 2
				trace("Increasing maxVehicles to",maxVehicles,"for doubleTerminals")
			end
			if report.possibleCongestion then 
				maxVehicles = #vehicles
				trace("Clamped maxVehicles to",maxVehicles,"for doubleTerminals")
			end 
		end

	end 
	
	
	params.carrier = report.carrier
	params.totalTargetThroughput = report.targetLineRate 
	params.targetThroughput=report.targetLineRate/#vehicles
	--params.isForVehicleReport = report.isForVehicleReport
	
	local rate = util.getEntity(lineId).rate
	if rate == 0 then -- save from divide by zero --> inf vehicles to buy
		if report.currentVehicleConfig then 
			trace("No line rate available, attempting to estimate")
			local throughput = vehicleUtil.estimateThroughputBasedOnConsist(report.currentVehicleConfig, params)
			rate = throughput.throughput * #vehicles 
			trace("Set the rate to ",rate,"based on estimate")
		else  
			trace("unable to determine rate, aborting") 
			return
		end			
	end 
	if report.rateCorrectionFactor then 
		rate = rate * report.rateCorrectionFactor
	end 
	local demandRate = math.max(1, report.targetLineRate)
	trace("addMoreVehicles: rate=",rate,"demandRate=",report.targetLineRate)
	if rate < demandRate then 
		report.problems.rateBelowProduction = tostring(rate).." < "..tostring(demandRate) 
		report.isOk = false
	end
	local upperthreshold = game.interface.getGameDifficulty() >=2 and 1.25 or 1.5
	if rate > upperthreshold*demandRate and not report.problems.hasOvercrowdedStops then 
		report.problems.rateAboveProduction = tostring(rate).." > "..tostring(demandRate) 
		report.isOk = false
	end
	local ratePerVehicle = rate / #vehicles 
	
	local vehicleDetail =  util.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
	local oldVehicleConfig = vehicleUtil.copyConfig(vehicleDetail.transportVehicleConfig)
	local currentCapacity = vehicleUtil.calculateCapacity(oldVehicleConfig, cargoType)
	local targetCapacity = (demandRate/rate)*currentCapacity
 
	
	params.currentCapacity = currentCapacity
	local totalTargetCapacity = targetCapacity * #vehicles
	trace("Setting initial targetCapacity to ",targetCapacity, " totalTargetCapacity=",totalTargetCapacity)
	if report.problems.possibleCongestion then 
		trace("Attempting to minimise required vehicles")
		params.minimiseRequiredVehicles = true
	end 
	if isCargo then 
		trace("Getting demandRate information and comparing rate to vehicles")  
		 
		local newRatePerVechicle
		local correctionFactor
		local newCapacity
		local totalVehiclesNeeded 
		trace("Setting the targetCapacity to ",targetCapacity," from the currentCapacity",currentCapacity)
		--local throughputCorrectionFactor = 1
		if isRail then
			--if report.useRouteInfo or not report.isForVehicleReport then 
			--	params.routeInfo = pathFindingUtil.getRouteInfo(stationFromGroup(line.stops[1].stationGroup),stationFromGroup(line.stops[2].stationGroup))
			--end
		
			--newVehicleConfig = vehicleUtil.buildTrain(targetCapacity, params)
		--[[	if report.isForVehicleReport then 
				report.newVehicleConfig = newVehicleConfig
				report.vehicleCount = #vehicles
				report.lineRate = demandRate 
				report.distance = params.distance
				return 
			end]]--
			
			local estimatedCurrentThroughput =vehicleUtil.estimateThroughputBasedOnConsist(oldVehicleConfig, params) 
			local estimatedCurrentRatePerVehicle = estimatedCurrentThroughput.throughput
			local correction = ratePerVehicle/estimatedCurrentRatePerVehicle
			if report.sectionTimesMissing or report.isWaitForFullLoad then 
				trace("not making correction for full load, originaly",correction) 
				correction  = 1
			end 
			params.totalTargetThroughput = (1/correction)*params.totalTargetThroughput
			trace("Correcting for target capacity set to",params.totalTargetThroughput)
			
			--if report.problems.profit or report.problems.possibleCongestion then 
				trace("Setting the targetThroughput to the total targetThroughput to build a bigger capacity train, was,",params.targetThroughput,params.totalTargetThroughput)
				params.targetThroughput = params.totalTargetThroughput
			--end 
			
			if not report.sectionTimesMissing and not report.isWaitForFullLoad then 
				params.sectionTimeCorrection = report.totalSectionTime / estimatedCurrentThroughput.totalSectionTime
				trace("The sectionTimeCorrection was ", params.sectionTimeCorrection ," based on ",formatTime(report.totalSectionTime)," vs ",formatTime(estimatedCurrentThroughput.totalSectionTime))
			end
			if params.keepExistingVehicleConfig and not report.isForVehicleReport then
				newVehicleConfig = oldVehicleConfig
			else 
				trace("calling onto buildTrain")
				params.isForVehicleReport = report.isForVehicleReport
				newVehicleConfig = vehicleUtil.buildTrain(targetCapacity, params)
			end 
			if report.isForVehicleReport then -- N.B. newVehicleConfig is an array of options here, does not work with logic that follows
				
				report.newVehicleConfig = newVehicleConfig
				report.vehicleCount = #vehicles
				report.lineRate = demandRate 
				report.distance = params.distance
				return 
			end
			local estimatedNewRatePerVechicle = vehicleUtil.estimateThroughputBasedOnConsist(newVehicleConfig, params).throughput
			newRatePerVechicle = correction * estimatedNewRatePerVechicle
			trace("The new ratePerVehicle was estimated as ",estimatedNewRatePerVechicle, " the actual current rate was ", ratePerVehicle," and the estimate was ", estimatedCurrentRatePerVehicle, " giving a correction factor of ", correction," the corrected new rate was",newRatePerVechicle)
			
		
	
		elseif isRoadLine(line) then
			params.isForVehicleReport = report.isForVehicleReport
			if params.keepExistingVehicleConfig and not report.isForVehicleReport then
				newVehicleConfig = oldVehicleConfig
			else 
				newVehicleConfig = vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
			end
		
			if not newVehicleConfig then 
				report.problems.noMatchingVehicles = true 
				return
			end
			if report.isForVehicleReport then 
				report.newVehicleConfig = newVehicleConfig
				report.vehicleCount = #vehicles
				report.lineRate = demandRate 
				report.distance = params.distance
				return 
			end
			newCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
			local newThroughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(newVehicleConfig, params.stations, params)
			local newThroughputInfo2 =  vehicleUtil.estimateThroughputBasedOnConsist(newVehicleConfig, params)
			trace("addMoreVehicles, comparing the througput total times were",newThroughputInfo.totalTime,"vs",newThroughputInfo2.totalTime)
			newRatePerVechicle = newThroughputInfo.throughput
			maxVehicles = math.min(maxVehicles,math.ceil(newThroughputInfo.totalTime/paramHelper.getParams().minimumIntervalRoad))
			trace("Clamped maxVehicles to ",maxVehicles,"based on new rate")
			
			if not report.problems.possibleCongestion then 
				local oldRatePerVehicle = rate / #vehicles 
				local calculatedRate = vehicleUtil.getThroughputInfoForRoadVehicle(oldVehicleConfig, params.stations, params).throughput
				correctionFactor = oldRatePerVehicle / calculatedRate
				trace("The oldRatePerVehicle was actually",oldRatePerVehicle," it was calculated as",calculatedRate," therefore correction factor was",correctionFactor)
				newRatePerVechicle = newRatePerVechicle * correctionFactor
			end 
			--newRatePerVechicle = ratePerVehicle*(newCapacity/currentCapacity) -- this is approximate, not accounting for speed differences
			totalVehiclesNeeded = math.min(maxVehicles, math.ceil(demandRate / newRatePerVechicle))
			
		else 
			params.targetCapacity = targetCapacity
			local options = {} 
			local priorConfig
			totalTargetCapacity = math.max(1, totalTargetCapacity)
			for i = 1, 5 do 
				if params.keepExistingVehicleConfig and not report.isForVehicleReport then 
					newVehicleConfig = oldVehicleConfig 
					break
				end 
				if i == 1 then 
					params.targetCapacity = totalTargetCapacity
				end
				newVehicleConfig = vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
				if params.isForVehicleReport then 
					report.newVehicleConfig = newVehicleConfig
					report.vehicleCount = #vehicles
					report.lineRate = demandRate 
					report.distance = params.distance
					return 
				end 
				newCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
				newRatePerVechicle = ratePerVehicle*(newCapacity/currentCapacity) -- this is approximate, not accounting for speed differences
				totalVehiclesNeeded = math.min(maxVehicles, math.ceil(demandRate / newRatePerVechicle))
				local idealCapacity = totalTargetCapacity / totalVehiclesNeeded
				local score = math.abs(idealCapacity-newCapacity)
				trace("At i=",i," idealCapacity=",idealCapacity," the target was ",params.targetCapacity," totalTargetCapacity=",totalTargetCapacity," score=",score, " newCapacity=",newCapacity)
				params.targetCapacity = idealCapacity
				table.insert(options, {
					i = i,
					newVehicleConfig = newVehicleConfig,
					newCapacity = newCapacity, 
					newRatePerVechicle = newRatePerVechicle,
					scores = { score} 
				})
				if priorConfig and vehicleUtil.checkIfVehicleConfigMatches(newVehicleConfig, priorConfig) then
					trace("Exiting iterations at ",i," as the config was not updated")
					break 
				end
				priorConfig = newVehicleConfig
			end
			if #options > 0 then 
				local best = util.evaluateWinnerFromScores(options)
				newVehicleConfig = best.newVehicleConfig
				newRatePerVechicle = best.newRatePerVechicle
				newCapacity = best.newCapacity
				trace("The best option was found at ",best.i," score was",best.scores[1])
			end
		end
		
		totalVehiclesNeeded = math.min(maxVehicles, math.ceil(demandRate / newRatePerVechicle))
		  
		if isRail then
			
			trace("Setting maxVehicles to ",maxVehicles," compared with initial totalVehiclesNeeded:",totalVehiclesNeeded," for line",report.lineName)
			if totalVehiclesNeeded > maxVehicles then 
				trace("Clamped totalVehiclesNeeded to ",maxVehicles)
				totalVehiclesNeeded = maxVehicles
			end 
			if not params.minimiseRequiredVehicles then 
				params.targetThroughput= demandRate/totalVehiclesNeeded
			else 
				params.targetThroughput = params.totalTargetThroughput
			end
			if report.isForVehicleReport then 
				
				params.isForVehicleReport = true
			end
			targetCapacity = targetCapacity * (totalVehiclesNeeded/#vehicles)
			
			if params.keepExistingVehicleConfig and not report.isForVehicleReport then
				newVehicleConfig = oldVehicleConfig
			else 
				newVehicleConfig = vehicleUtil.buildTrain(targetCapacity, params)-- second build because we may want to revise down the throughput
			
			end 
		 
			if report.isForVehicleReport then 
				report.newVehicleConfig = newVehicleConfig
				report.vehicleCount = totalVehiclesNeeded
				report.lineRate = demandRate 
				report.distance = params.distance
				return 
			end
			local estimatedNewRatePerVechicle = vehicleUtil.estimateThroughputBasedOnConsist(newVehicleConfig, params)
			local estimatedCurrentThroughput =vehicleUtil.estimateThroughputBasedOnConsist(oldVehicleConfig, params) 
			local estimatedCurrentRatePerVehicle = estimatedCurrentThroughput.throughput
			local correction = ratePerVehicle/estimatedCurrentRatePerVehicle
			if report.sectionTimesMissing or report.isWaitForFullLoad then 
				trace("not making correction for full load, originaly",correction) 
				correction  = 1
			end 
			newRatePerVechicle = correction * estimatedNewRatePerVechicle.throughput
			local targetVehiclesNeeded = math.ceil(demandRate / newRatePerVechicle)
			maxVehicles = math.min(maxVehicles,math.ceil(estimatedNewRatePerVechicle.totalTime/paramHelper.getParams().minimumInterval))
			trace("Clamped maxVehicles to ",maxVehicles,"based on new rate")
			totalVehiclesNeeded = math.min(maxVehicles,targetVehiclesNeeded )
			if targetVehiclesNeeded > maxVehicles and vehicleUtil.getConsistInfo(newVehicleConfig).isMaxLength then 
				trace("Detected targetVehiclesNeeded",targetVehiclesNeeded,"higher than allowed",maxVehicles,"recommending stationLength upgrade")
				report.recommendations.stationLengthUpgrade = true
			end 
		end 
		trace("The final calculated number of vehicles was",totalVehiclesNeeded," vs currently",#vehicles, "and maxVehicles=",maxVehicles)
		totalVehiclesNeeded = math.max(totalVehiclesNeeded, 1)
		if totalVehiclesNeeded >= #vehicles then
			vehiclesToBuy = totalVehiclesNeeded- #vehicles 
			vehiclesToReplace = #vehicles
		else 
			vehiclesToSell = #vehicles - totalVehiclesNeeded 
			vehiclesToReplace = totalVehiclesNeeded
		end  
	else  -- PASSENGERS
		if report.problems.hasOvercrowdedStops and rate >= demandRate and not params.rateOverride then 
			trace("Detected line with overcrowding and rate above demand rate, correcting") 
			demandRate = 1.1*rate -- essentially a fudge, but the demand rate for passengers is not concrete anyway
			report.targetLineRate = demandRate
		end
		local rateCorrection 
 
		if report.impliedLoadTime > 0 and isRail then 
			local info = vehicleUtil.getConsistInfo(oldVehicleConfig, cargoType)
			if not report.sectionTimesMissing and not report.isWaitForFullLoad then 
				params.loadStationFactor = (info.loadSpeed/info.capacity) *(report.impliedLoadTime / #line.stops)
			end
		
			trace("Calculated the loadStationFactor as",params.loadStationFactor, " loadSpeed=",info.loadSpeed, " capacity=",info.capacity," number of stops =",#line.stops," impliedLoadTime=",impliedLoadTime)
			params.line = line
			local estimatedCurrentThroughput =vehicleUtil.estimateThroughputBasedOnConsist(oldVehicleConfig, params) 
			if not report.sectionTimesMissing and not report.isWaitForFullLoad then 
				params.sectionTimeCorrection = report.totalSectionTime / estimatedCurrentThroughput.totalSectionTime
				trace("The sectionTimeCorrection was ",params.sectionTimeCorrection," based on ",report.totalSectionTime," vs ",estimatedCurrentThroughput.totalSectionTime)
			end
			local estimatedCurrentRatePerVehicle = estimatedCurrentThroughput.throughput
			rateCorrection = estimatedCurrentRatePerVehicle/ratePerVehicle
			trace("Calculated rateCorrection as ",rateCorrection, "estimatedCurrentRatePerVehicle=",estimatedCurrentRatePerVehicle," actual rate=",ratePerVehicle, " totalTime=",estimatedCurrentThroughput.totalTime,"totalCapacity=",estimatedCurrentThroughput.totalCapacity)
		end
		local targetCapacity = (demandRate/rate)*currentCapacity
		trace("For line ",lineId," the estimated rate was ", demandRate," actual rate was", rate, " rateBelowEstimate?",rateBelowEstimate)
		 
		if rateBelowEstimate and isRail then
			
			
			params.targetThroughput= #vehicles > 0 and demandRate/#vehicles or demandRate
			params.line = line
			if params.keepExistingVehicleConfig and not report.isForVehicleReport then
				newVehicleConfig = oldVehicleConfig
			else 
				newVehicleConfig = vehicleUtil.buildTrain(targetCapacity, params) 
			end 
			 
		end
		local totalVehiclesNeeded = math.max(1, #vehicles) 
		if report.problems.isAboveMaximumInterval or rateBelowEstimate or report.isForVehicleReport or demandRate > rate or report.problems.hasOvercrowdedStops or report.problems.oldVehicles then
			local frequency = util.getEntity(lineId).frequency
			
			local intervalPerVehicle
			if frequency == 0 then
				if not newVehicleConfig then -- use existing config
					local vehicleDetail =  util.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
					newVehicleConfig = vehicleUtil.copyConfig(vehicleDetail.transportVehicleConfig)
				end
				intervalPerVehicle = estimateTotalTimeForLine(lineId, newVehicleConfig, params) 
			else 
				intervalPerVehicle = #vehicles/frequency
			end
			local targetMaximumPassengerInterval = params.targetMaximumPassengerInterval
		
			local minVehiclesNeeded = math.ceil(intervalPerVehicle / targetMaximumPassengerInterval)
			trace("calculated minVehiclesNeeded as ",minVehiclesNeeded," based on intervalPerVehicle=",intervalPerVehicle," current number of vechicles = ",#vehicles, " initial targetCapacity=",targetCapacity)
			targetCapacity = targetCapacity * ( minVehiclesNeeded / #vehicles)
			--end
			params.targetCapacity = targetCapacity
			if report.problems.possibleCongestion  then 
				params.targetCapacity = 2^16
				if report.isRoadLine then 
					if params.keepExistingVehicleConfig and not report.isForVehicleReport then
						newVehicleConfig = oldVehicleConfig
					else 
						newVehicleConfig = report.isTramLine and vehicleUtil.buildTram() or params.isUrbanLine and vehicleUtil.buildUrbanBus() or vehicleUtil.buildIntercityBus()
					end 
					
					local recaulculatedInterval = vehicleUtil.getThroughputInfoForRoadVehicle(newVehicleConfig, params.stations, params).estimatedTripTime
					minVehiclesNeeded = math.ceil(recaulculatedInterval / targetMaximumPassengerInterval)
					trace("recaulculated minVehiclesNeeded as ",minVehiclesNeeded," based on recaulculatedInterval=",recaulculatedInterval)
				elseif report.isAirLine then 
					minVehiclesNeeded = report.estimatedAirVehicles
				end 
			end 
			--if not report.isForVehicleReport then 
			
			trace("Updated targetCapacity = ",params.targetCapacity)
			  totalVehiclesNeeded = math.min(maxVehicles, minVehiclesNeeded)
			local priorConfig
			for i = 1, 2 do 
				
				if isRail  then 
					params.line = line
					params.targetThroughput =  demandRate / totalVehiclesNeeded
					if multiplyTargetByLineStops then 
						params.targetThroughput = #line.stops * params.targetThroughput -- not sure if this is correct
					end
					if newVehicleConfig then 
						local currentCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
						targetCapacity = (demandRate/rate)*currentCapacity
						if params.keepExistingVehicleConfig and not report.isForVehicleReport then
							newVehicleConfig = oldVehicleConfig
						else 
							newVehicleConfig = vehicleUtil.buildTrain(targetCapacity, params) 
						end 
						if params.isForVehicleReport then 
							report.newVehicleConfig = newVehicleConfig
							return 
						end
					else 
						newVehicleConfig = oldVehicleConfig or lineManager.estimateInitialConsist(params, params.distance).vehicleConfig 
					end
					
				
					
					local estimatedNewRatePerVechicle = vehicleUtil.estimateThroughputBasedOnConsist(newVehicleConfig, params).throughput
					if rateCorrection then 
						estimatedNewRatePerVechicle = rateCorrection*estimatedNewRatePerVechicle
					end
					totalVehiclesNeeded = math.min(maxVehicles, math.max(minVehiclesNeeded, math.ceil(demandRate / estimatedNewRatePerVechicle)))
					--local maximumVehicles = math.ceil(math.max(#line.stops*1.5, params.routeLength/2000))
					--if totalVehiclesNeeded > maximumVehicles then 
					--	trace("Clamping the totalVehiclesNeeded from ",totalVehiclesNeeded," to ", maximumVehicles)
					--	totalVehiclesNeeded = maximumVehicles
					--end 
					params.targetThroughput =  demandRate / totalVehiclesNeeded
					if multiplyTargetByLineStops then 
						params.targetThroughput = #line.stops * params.targetThroughput -- not sure if this is correct
					end
					trace("At i=",i,"updated the targetThroughput to",params.targetThroughput,"totalVehiclesNeeded=",totalVehiclesNeeded, "estimatedNewRatePerVechicle=",estimatedNewRatePerVechicle, "rateCorrection=",rateCorrection )

				else 
					if params.keepExistingVehicleConfig and not report.isForVehicleReport then
						newVehicleConfig = oldVehicleConfig
					else 
						params.isForVehicleReport = report.isForVehicleReport
						newVehicleConfig =  vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
					end  
					if params.isForVehicleReport then 
						report.newVehicleConfig = newVehicleConfig
						report.vehicleCount = #vehicles
						report.lineRate = demandRate 
						report.distance = params.distance
						return 
					end 
					local capacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
					totalVehiclesNeeded = math.min(maxVehicles, math.max(minVehiclesNeeded, math.ceil(totalTargetCapacity / capacity)))
					if report.problems.possibleCongestion and totalVehiclesNeeded> minVehiclesNeeded then
						totalVehiclesNeeded = minVehiclesNeeded
						break -- use the minimum
					end
					local idealCapacity = totalTargetCapacity / totalVehiclesNeeded
					params.targetCapacity = idealCapacity
					trace("At i=",i,"updated the totalVehiclesNeeded to",totalVehiclesNeeded,"idealCapacity=",idealCapacity, "capacity=",capacity, "totalTargetCapacity=",totalTargetCapacity )
					
					 
				end
				if priorConfig and newVehicleConfig and vehicleUtil.checkIfVehicleConfigMatches(newVehicleConfig, priorConfig) then
					trace("Exiting iterations at ",i," as the config was not updated")
					break 
				end
				priorConfig = newVehicleConfig
			end 
			vehiclesToBuy = math.max(totalVehiclesNeeded- #vehicles ,0)
			vehiclesToSell =  math.max(#vehicles - totalVehiclesNeeded,0)
			vehiclesToReplace = totalVehiclesNeeded - vehiclesToBuy
			trace("For line",report.lineName,"set the vehiclesToBuy=",vehiclesToBuy,"vehiclesToReplace=",vehiclesToReplace,"vehiclesToSell=",vehiclesToSell,"based on needed vehicles",totalVehiclesNeeded,"and current vehicles",#vehicles)
		end 
		if (report.problems.profit or report.rate > 2*report.targetLineRate ) and vehiclesToBuy == 0 and vehiclesToSell ==0 and vehiclesToReplace == 0 then 
			local currentInterval = report.currentInterval
			local maxInterval = params.targetMaximumPassengerInterval
			local newProjection = ((#vehicles-1)/#vehicles)*currentInterval
			local isAboveTarget = newProjection <= maxInterval
			trace("Inspecting possible profit problem, currentInterval=",currentInterval,"maxInterval=",maxInterval,"newProjection is",newProjection,"still above target?",isAboveTarget)
			if isAboveTarget then 
				trace("Setting vehicle to sell")
				vehiclesToSell = 1 
			end 
			
		end 
		if  report.isForVehicleReport then 
			params.isForVehicleReport = true 
			report.vehicleCount = totalVehiclesNeeded
			report.lineRate = estimatedLineRate
		 	report.newVehicleConfig = isRail and vehicleUtil.buildTrain(targetCapacity, params) or vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
			return
		end
		
	end
	if report.isForVehicleReport then 
		trace("WARNING! fallen through with vehicle report, attempting to fix")
		params.isForVehicleReport = report.isForVehicleReport
		newVehicleConfig =  vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
	 
		report.newVehicleConfig = newVehicleConfig
		report.vehicleCount = #vehicles
		report.lineRate = demandRate 
		report.distance = params.distance
		return 
					  
	end 
	assert(not report.isForVehicleReport)
	trace("hasOvercrowdedStops? ",report.problems.hasOvercrowdedStops)
	if report.problems.hasOvercrowdedStops and  not isRail and not report.problems.possibleCongestion then  
		if vehiclesToSell > 0 then 
			vehiclesToSell=0 
		end  
		vehiclesToBuy = math.max(vehiclesToBuy, 1)
		
	end 
 
	if report.problems.possibleCongestion and not report.problems.hasOvercrowdedStops or report.problems.vehiclesQueing then 
		vehiclesToBuy = 0 
		if #vehicles > 2 and vehiclesToSell == 0  then -- todo possibly recalculate 
			vehiclesToSell = 1 
			trace("Selling vehicle due to congestion")
			if vehiclesToReplace > 0 then 
				vehiclesToReplace = vehiclesToReplace - 1
			end
		end
	end 
	
	if report.problems.profit and util.getAvailableBudget() < 0 then 
		trace("Discovered no budget available")
		vehiclesToBuy= 0
		vehiclesToReplace = 0
		vehiclesToSell = math.min(math.floor(report.incomeToMaintenance*#vehicles), #vehicles-1)
		trace("Setting the vehicles to sell to ",vehiclesToSell,"based on incomeToMaintenance of ",report.incomeToMaintenance)
	end 
	
	if not newVehicleConfig then -- use existing config 
		newVehicleConfig = oldVehicleConfig
	end
	if report.problems.oldVehicles then 
		vehiclesToReplace = math.max(vehiclesToReplace, #vehicles-vehiclesToSell)
		trace("Setting the vehiclesToReplace to ",vehiclesToReplace, " for old vehicles")
	end 
	
	
	
	if vehiclesToReplace > 0 and vehicleUtil.checkIfVehicleConfigMatches(newVehicleConfig, oldVehicleConfig) and (not report.problems.oldVehicles or game.interface.getGameDifficulty() >= 2) then -- on hard mode do not replace old vehicles with the same config
		trace("Setting vehicles to replace to zero as the config matches on line ",lineId, " from ",vehiclesToReplace)
		vehiclesToReplace = 0
	end  
	if vehiclesToReplace > 0 or report.problems.hasOldStreetSections then 
		checkForLineUpgrades(lineId, line, report, newVehicleConfig, params, oldVehicleConfig)
	end 
	
	if report.recommendations.addSecondRunway then 
		table.insert(report.executionFns, function() api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","doUpgrade", "", {lineId=lineId, upgrade="addSecondRunway"})) end)
	end 
	
	if isRail and (report.problems.possibleCongestion and isCargo or report.recommendations.stationLengthUpgrade) then 
		local nextStationLengthParam = paramHelper.getParams().stationLengthParam +1
		local nextStationLength = paramHelper.getNextStationLengthForUpgrade(params.stationLength)
		trace("Inspecting the possibility for a station length upgrade, nextStationLengthParam=",nextStationLengthParam,"current stationLengthParam=", params.stationLengthParam,"nextStationLength=",nextStationLength,"currentStationLength=",params.stationLength)
		if  nextStationLength > params.stationLength and nextStationLengthParam > params.stationLengthParam and not report.isTownDelivery and not lineManager.stationLengthUpgrades[lineId] then 
			report.recommendations.stationLengthUpgrade = true 
			trace("Linemanager recommending station length upgrade for ",lineId)
			local callback = function(res, success) 
				trace("result of station length upgrade was",success," for line",lineId)
				if success then 
					lineManager.addDelayedWork(function() lineManager.checkAndUpdateLine(lineId) end)
				end 
			end 
			table.insert(report.executionFns, function() lineManager.upgradeStationLength(lineId, callback) end)
			return -- do no execute any more recomendations until the callback
		else 
			report.recommendations.stationLengthUpgrade = nil
		end 
	end 

		
	if not newVehicleConfig then 
		trace("WARNING! No vechicle config set")
		return 
	end
	if vehiclesToBuy > 0 and report.profit < 0 and not report.isShipLine and not report.isRoadLine and not report.problems.isAboveMaximumInterval   then -- ship lines may have long gaps between revenue 
		trace("Aborting the purchase of more vehicles while the line is unprofitable")
		vehiclesToBuy = 0 
	end
	local cost = vehicleUtil.getVehichleCost(newVehicleConfig)

	if vehiclesToBuy > 0 or vehiclesToReplace > 0 then 
		local vehiclesToBuyOrReplace = vehiclesToBuy +vehiclesToReplace
		local totalVehicleCost = cost * vehiclesToBuyOrReplace
		local doubleTrackUpgradeBudget = 0 
		if isRail and #vehicles == 1 and not params.isDoubleTrack then 
			doubleTrackUpgradeBudget = (paramHelper.getParams().assumedCostPerKm/2)*(report.routeLength/1000)
		end 
			
		local availableBudget = util.getAvailableBudget() - doubleTrackUpgradeBudget
		trace("Checking the cost of vehicle",cost, " for vehiclesToBuy",vehiclesToBuy," the total cost was ",totalVehicleCost," and the availableBudget was",availableBudget)
		if totalVehicleCost > availableBudget then 
			local originalVehiclesToBuy = vehiclesToBuy
			local vehiclesToBuyOrReplace = math.max(0, math.floor(availableBudget / cost))
			trace("WARNING! Cost exceeds available budget, ",availableBudget," doubleTrackUpgradeBudget=",doubleTrackUpgradeBudget," reducing vehiclesToBuy to ",vehiclesToBuy)
			if vehiclesToBuyOrReplace == 0 then 
				trace("cancelling replacement vehicles, was",vehiclesToReplace)
				vehiclesToReplace = 0
				vehiclesToBuy = 0 
			end
		end 
		report.upgradeBudget = vehiclesToBuy*cost+doubleTrackUpgradeBudget + vehiclesToReplace*cost
		 
		--util.ensureBudget(report.upgradeBudget)
		  	
	end
	
	local depotOptionsFn = function(nonStrict) return lineManager.findDepotsForLine(lineId, report.carrier, nonStrict)end
	if isRail and #vehicles == 1 and vehiclesToBuy > 0 then
		trace("about to upgrade to  double track") 
		report.upgrades.needsDoubleTrackUpgrade = true 
		table.insert(report.executionFns,1, function()
			trace("Check for upgrade to double track")
			routeBuilder.checkAndUpgradeToDoubleTrack( line, lineManager.standardCallback, params ) 
		end)
	end

	if not newVehicleConfig.vehicles then 
		debugPrint({newVehicleConfig=newVehicleConfig, report=report, params=params})
	end 
	
	for i, v in pairs(newVehicleConfig.vehicles) do 
		v.purchaseTime = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
		v.maintenanceState = 1
	end
	if vehiclesToBuy > 100 then 
		trace("WARNING! A large number of vehiclesToBuy was detected, clamping ",vehiclesToBuy)
		vehiclesToBuy =100
	end
	if vehiclesToReplace > 0 then 
		report.recommendations.vehiclesToReplace = vehiclesToReplace
	end
	if vehiclesToSell > 0 then 
		report.recommendations.vehiclesToSell = vehiclesToSell
	end
 	if vehiclesToBuy > 0 then 
		report.recommendations.vehiclesToBuy = vehiclesToBuy
	end
	report.vehicleCount = #vehicles + vehiclesToBuy - vehiclesToSell
	trace("attempting to buy ", vehiclesToBuy, " for line ",lineId, " demandRate=",demandRate," rate=",rate, " sourceEntity=",sourceEntity,"targetEntity=",targetEntity, " vehiclesToReplace=", vehiclesToReplace, " vehiclesToSell=",vehiclesToSell)
	report.newVehicleConfig = vehicleUtil.copyConfig(newVehicleConfig)
	
	if vehiclesToBuy > 0 then 
		table.insert(report.executionFns, function()
			local depotOptions = depotOptionsFn()  
			if #depotOptions == 0 then 
				trace("No depot options found attempting to build new depot")
				lineManager.addWork(function() 
					if #depotOptionsFn()==0 then --recheck
						constructionUtil.buildDepotAlongRoute(stationFromStop(line.stops[1]),stationFromStop(line.stops[2]), params, report.carrier, lineManager.standardCallback, line) 
					end
				end)		
			end
			local budget = cost * vehiclesToBuy
			local activityLogEntry = {
				activityType = "lineManager",
				lineManagerType = "Buy",
				lineManagerReason = "update line",
				attemptedCount = vehiclesToBuy,
				attemptedCost = budget,
				actualCount = 0,
				actualCost = 0,
				lineId = lineId,
				notes = buildNoteFromLineReport(report) ,
			}
			table.insert(lineManager.getActivityLog(), activityLogEntry)
			local function callback(res, success) 
				util.scheduledBudget = util.scheduledBudget - cost -- decrement from the budget either way as it is no longer spent
				if success then 
					activityLogEntry.actualCount = activityLogEntry.actualCount+1 
					activityLogEntry.actualCost = activityLogEntry.actualCost+cost
				end					
			end 
			util.ensureBudget(budget)
			util.scheduledBudget = util.scheduledBudget + budget
			-- External Agent Control: Commented out automatic vehicle buying
			-- for i = 1, vehiclesToBuy do				
			-- 	trace("Inserting instruction to buy vehicle at i=",i)
			-- 	lineManager.addBackgroundWork(function()
			-- 		if not depotOptions or #depotOptions == 0 then 
			-- 			depotOptions = depotOptionsFn()
			-- 		end  
			-- 		lineManager.buyVehicleForLine(lineId,i, depotOptions, newVehicleConfig, callback)
			-- 	end)
			-- end
		end)
	end
	if vehiclesToReplace > 0 then 
		table.insert(report.executionFns, function() 
			local budget  = cost * vehiclesToReplace
			local activityLogEntry = {
				activityType = "lineManager",
				lineManagerType = "Replace",
				lineManagerReason = "update line",
				attemptedCount = vehiclesToReplace,
				attemptedCost =  budget,
				actualCount = 0,
				actualCost = 0,
				lineId = lineId,
				notes =buildNoteFromLineReport(report),
			}
			table.insert(lineManager.getActivityLog(), activityLogEntry)
			local atLeastOneSuccess = false
			util.ensureBudget(budget) 
			util.scheduledBudget = util.scheduledBudget + budget
			for i = 1, vehiclesToReplace do
				local vehicleToReplace = vehicles[i]
			
				local replaceCommand = api.cmd.make.replaceVehicle(vehicleToReplace, vehicleUtil.copyConfigToApi(newVehicleConfig))
				api.cmd.sendCommand(replaceCommand, function(res, success) 
					util.scheduledBudget = util.scheduledBudget - cost
					--debugPrint({replaceVehicleres=res})
					if success then 
						activityLogEntry.actualCount = activityLogEntry.actualCount+1 
						activityLogEntry.actualCost = activityLogEntry.actualCost+cost
					end				 
					if not success and atLeastOneSuccess then
					-- trace("Failed to replace vehicle, selling instead")
					--	lineManager.addWork( function() api.cmd.sendCommand(vehicleToSell, lineManager.standardCallback)end) -- this can't work, vehicleToSell is nil
					end 
					atLeastOneSuccess = atLeastOneSuccess or success
					lineManager.standardCallback(res,success)
				end)
			end
		end)
	end 
	if vehiclesToSell > 0 then 
		table.insert(report.executionFns, function()
			local activityLogEntry = {
				activityType = "lineManager",
				lineManagerType = "Sell",
				lineManagerReason = "update line",
				attemptedCount = vehiclesToSell,
				attemptedCost = 0,
				actualCount = 0,
				actualCost = 0,
				lineId = lineId,
				notes = buildNoteFromLineReport(report),
			}
			table.insert(lineManager.getActivityLog(), activityLogEntry)
			for i = 1, vehiclesToSell do 
				local vehicleToSell = vehicles [i+vehiclesToReplace]
				api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell),function(res, success)
					 
					if success then 
						activityLogEntry.actualCount = activityLogEntry.actualCount+1 
						--activityLogEntry.actualCost = activityLogEntry.actualCost+cost
					end		
				end)
			end
		end)
	end 	
	
	if report.isRoadLine and report.problems.possibleCongestion and not report.isMultiLaneRoute then  
		report.recommendations.upgradeToMultiLaneRoad = true 
		table.insert(report.executionFns, function()
			trace("Checking roadLineForupgrade")
			paramHelper.setParamsForMultiLaneRoad(params)
			params.addBusLanes = not params.isCargo and util.year() >= api.res.getBaseConfig().busLaneYearFrom
			routeBuilder.checkRoadLineForUpgrade(callback, params, lineId)
		end)
	end 
	if report.isRoadLine and report.problems.possibleCongestion and params.routeInfo and not params.routeInfo.isHighwayRoute and params.routeInfo.averageRouteLanes > 1 then 
		table.insert(lineManager.highwayRequests, line)	
	end
	
	if report.isRailLine and report.isCargo and report.problems.possibleCongestion then 
		table.insert(lineManager.railLineUpgradeRequests, lineId)
	end 
end

function lineManager.upgradeToDoubleTrack(lineId)
	local line = getLine(lineId)
	local params = getLineParams(lineId)
	routeBuilder.checkAndUpgradeToDoubleTrack( line, lineManager.standardCallback, params ) 
end
function lineManager.upgradeToElectricTrack(lineId)
	local line = getLine(lineId)
	local params = getLineParams(lineId)
	params.isElectricTrack = true
	routeBuilder.checkForTrackupgrades(line, lineManager.standardCallback,params, lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL))
  
end

function lineManager.upgradeToHighSpeedTrack(lineId)
	local line = getLine(lineId)
	local params = getLineParams(lineId)
	params.isHighSpeedTrack = true
	routeBuilder.checkForTrackupgrades(line, lineManager.standardCallback,params, lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL))
end

function lineManager.upgradeStationLength(lineId, callback)
	local line = getLine(lineId)
	local params = getLineParams(lineId)
	params.stationLengthUpgrade = true
	params.targetStationLength = paramHelper.getNextStationLengthForUpgrade(params.stationLength)
	local lineDepots = {} -- for this no upgrade required
	lineManager.stationLengthUpgrades[lineId]=true 
	routeBuilder.checkForTrackupgrades(line, callback or lineManager.standardCallback,params, lineDepots)
end


function lineManager.addDoubleTerminalsToLine(lineId)
	trace("Begin lineManager.addDoubleTerminalsToLine")
	local line = getLine(lineId)
	local newLine = api.type.Line.new()
	
	for i, stop in pairs(line.stops) do 
		if #stop.alternativeTerminals == 0 then 
			local newStop = copyStop(stop)
			local terminalToUse
			if isRailLine(line) then 
				local station = stationFromStop(stop)
				local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
				local nextStop  = i == #line.stops and line.stops[1] or line.stops[i+1]
				local nextStation = stationFromStop(nextStop)
				local priorStation = stationFromStop(priorStop)
				for j, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
					if terminal~= stop.terminal and #pathFindingUtil.findRailPathBetweenStations(station, nextStation, terminal, nextStop.terminal) > 0
						and #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, terminal) > 0						then 
						trace("Found a terminal with a path",terminal)
						terminalToUse = terminal 
						break 
					end 
				end
			else 
				-- Fix (community-reported): 'station' was only declared inside
				-- the rail branch, so road lines crashed with nil station.
				local station = stationFromStop(stop)
				terminalToUse  = getFreeTerminalsForStation(station)[1]
			end 			
			if terminalToUse then 
				local alternative = api.type.StationTerminal.new()
				alternative.station = stop.station 
				alternative.terminal = terminalToUse
				newStop.alternativeTerminals[1]=alternative
			else 
				trace("WARNING! Could not find a terminal to use while upgrading to double terminals")
			end 
			newLine.stops[i]=newStop 
		else 
			newLine.stops[i]=stop
		end		
	end 
	validateLine(newLine)
	api.cmd.sendCommand(api.cmd.make.updateLine(lineId, newLine), lineManager.standardCallback)
end 

function lineManager.upgradeToDoubleTerminals(lineId)
	
	local function callback(res, success)
		util.clearCacheNode2SegMaps()
		if success then 
			lineManager.addDelayedWork(function() 
				lineManager.addDelayedWork(function() lineManager.addDoubleTerminalsToLine(lineId)	end) -- double delay		
			end)
		end 
	end 
	local line = getLine(lineId)
	local params = getLineParams(lineId)
	params.doubleTerminalUpgrade = true 
	
	local lineDepots = {} -- for this no upgrade required
	routeBuilder.checkForTrackupgrades(line, callback,params, lineDepots)
end 

function lineManager.buyVehicleForLine(lineId, i, depotOptions, newVehicleConfig, callback, alreadyAttempted)
	if not depotOptions or #depotOptions == 0 then 
		trace("buyVehicleForLine: Unable to find depot for replacement")
		local callbackThis = function(res, success) 
			trace("lineManager.buyVehicleForLine callback, success?",success)
			if success then 
				lineManager.addWork(function()  lineManager.buyVehicleForLine(lineId, i, depotOptions, newVehicleConfig, callback, true) end)
			end 
		end 
		if not alreadyAttempted then 
			lineManager.buildDepotForLine(lineId, callbackThis)
		else 
			trace("WARNING! Unable to build depot")
		end 		
		return  
	end 
	local depotOption = depotOptions[i%#depotOptions+1]
	trace("===== buyVehicleForLine =====")
	trace("  lineId=", lineId)
	trace("  depotEntity=", depotOption.depotEntity)
	trace("  stopIndex=", depotOption.stopIndex)
	trace("  player=", api.engine.util.getPlayer())
	trace("  newVehicleConfig vehicles=", newVehicleConfig and newVehicleConfig.vehicles and #newVehicleConfig.vehicles or "nil")

	-- Debug vehicle config
	if newVehicleConfig and newVehicleConfig.vehicles then
		for vi, veh in ipairs(newVehicleConfig.vehicles) do
			local modelId = veh.part and veh.part.modelId or "nil"
			local modelName = modelId and modelId ~= "nil" and api.res.modelRep.getName(modelId) or "unknown"
			trace("  vehicle[", vi, "]: modelId=", modelId, " name=", modelName)
		end
	end

	local apiVehicle = vehicleUtil.copyConfigToApi(newVehicleConfig)
	trace("  apiVehicle created")
	local buyVehicle = api.cmd.make.buyVehicle(api.engine.util.getPlayer(), depotOption.depotEntity, apiVehicle)
	trace("  buyVehicle command created")
	local buyVehicleCallback = function(res, success)
		trace("===== buyVehicleForLine RESULT =====")
		trace("  success=", success)
		if res then
			trace("  resultVehicleEntity=", res.resultVehicleEntity)
			trace("  errorStr=", res.errorStr)
		end
		if callback then 
			callback(res, success)
		end 
		if success then 
			local resultVehicle = res.resultVehicleEntity 
			lineManager.addBackgroundWork(function() lineManager.assignVehicleToLine(resultVehicle, lineId, lineManager.standardCallback, depotOption.stopIndex, buyVehicle, res) end)	
		end
	end 
	api.cmd.sendCommand(buyVehicle, buyVehicleCallback) 
end 

local function text(str) 
	return api.gui.comp.TextView.new(_(str))
end 

local function money(val) 
	return api.gui.comp.TextView.new(api.util.formatMoney(val))
end 
local function number(val)
	return api.gui.comp.TextView.new(api.util.formatNumber(math.floor(val)))
end 

local function makeLineDisplay(lineId)
	local boxLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL"); 
	local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate.tga")
	local button = api.gui.comp.Button.new(imageView, true)
	button:onClick(function() 
		api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(lineId, false)
	end)
	boxLayout:addItem(button)
	local lineName = util.getName(lineId)
	if not lineName then 
		lineName = "<unknown>"
	end 
	boxLayout:addItem(api.gui.comp.TextView.new(_(lineName) or lineName))
	local comp= api.gui.comp.Component.new("")
	comp:setLayout(boxLayout)
	return comp
end
function lineManager.buildActivityLogTable() 
	local lineHeader = text("line")
	local totalCostHeader = text("actualCost")
	local colHeaders = {
		lineHeader,
		text("lineManagerType"),
		text("lineManagerReason"),
		text("attemptedCount"),
		text("attemptedCost"),
		text("actualCount"),
		totalCostHeader,
		text("notes")
	}
	 
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local function refreshTable(activityLog)
		trace("Being refresh line manager table, got " ,#activityLog," to report")
		displayTable:deleteAll()
		local allButtons = {}
		local count = 0
		local totalCost =0 
		for i = #activityLog,1, -1  do
			local activityLogEntry = activityLog[i] 
			if activityLogEntry.activityType == "lineManager" then
				count = count + 1
				totalCost = totalCost + activityLogEntry.actualCost
				displayTable:addRow({
					makeLineDisplay(activityLogEntry.lineId),
					text(activityLogEntry.lineManagerType),
					text(activityLogEntry.lineManagerReason),
					number(activityLogEntry.attemptedCount),
					money(activityLogEntry.attemptedCost),
					number(activityLogEntry.actualCount),
					money(activityLogEntry.actualCost),
					text(activityLogEntry.notes)
				})
			end
		end 
		lineHeader:setTooltip(_("Total").." :"..api.util.formatNumber(count))
		totalCostHeader:setTooltip(_("Total Cost").." :"..api.util.formatMoney(totalCost))
		local maxSize = api.gui.util.getGameUI():getMainRendererComponent():getContentRect()
		local minSize = displayTable:calcMinimumSize()
		--minSize.h = math.min(minSize.h, math.floor( maxSize.h/5))
		minSize.h = math.floor( maxSize.h/5)
		displayTable:setMaximumSize(minSize)
	end
	return displayTable, refreshTable
end

local function updateLineAndAddVehicles(lineId, newLine, callback)
	-- RE-ENABLED: Auto-vehicle adding restored
	local function wrappedCallback(res, success)
		if success then
			-- Auto-vehicle logic - analyze line and add appropriate vehicles
			lineManager.addDelayedWork(function()
				if api.engine.entityExists(lineId) and getLine(lineId) then
					lineManager.getLineReport(lineId, newLine).executeUpdate()
				end
			end)

			-- Track upgrade checks
			lineManager.addDelayedWork(function()
				if not (api.engine.entityExists(lineId) and getLine(lineId)) then
					return
				end
				local params = getLineParams(lineId)
				local depots = {}
				local vehicleId = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)[1]
				if vehicleId then
					local vehicle = util.getComponent(vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE)
					local vehicleConfig = vehicleUtil.copyConfig(vehicle.transportVehicleConfig)
					local info = vehicleUtil.getConsistInfo(vehicleConfig, params.cargoType)
					depots = lineManager.findDepotsForLine(lineId, vehicle.carrier, true)
					params.isElectricTrack = params.isElectricTrack or info.isElectric
					params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
				elseif discoverLineCarrier(getLine(lineId)) then
					depots = lineManager.findDepotsForLine(lineId, discoverLineCarrier(getLine(lineId)), true)
				end
				routeBuilder.checkForTrackupgrades(getLine(lineId), lineManager.standardCallback, params, depots)
			end)
		end
		callback(res, success)
	end
	validateLine(newLine)
	api.cmd.sendCommand(api.cmd.make.updateLine(lineId, newLine), wrappedCallback)
	
	
end

function lineManager.sellAllVehicles(lineId) 
	local lineVehicles = util.deepClone(api.engine.system.transportVehicleSystem.getLineVehicles(lineId))
	for i, vehicleId in pairs(lineVehicles) do 
		api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleId), lineManager.standardCallback)
	end
	return #lineVehicles
end


local function extendLineFromStation(lineId, line, station, newStation, nextStation, callback, otherLineId)
	trace("extendLineFromStation: begin:",lineId, station, newStation, nextStation,  otherLineId)
	local stopOffset = 2
	local lineToRemove 
	local lineToRemoveId
	local otherLine
	local setupLineDetails
	local newLine
	setupLineDetails = function() 
		--if newLine then 
		--	trace("Already been called to setup line details") 
		--	print(debug.traceback())
		--	return newLine 
		--end
		trace("Extending line ",lineId," from station ",station)
		local stopIndex = indexOfStop(line, station)
		local existingStops = #line.stops
		local stationVector = util.vectorBetweenStations(station, newStation) 
		newLine = api.type.Line.new()
		local existingStopOffset = 0
		local freeTerminal = getFreeTerminalForStation(station) 
		for i = 1, #line.stops + stopOffset do 
			local stop = api.type.Line.Stop.new()
			local existingStop = line.stops[i-existingStopOffset]
			
			
			trace("extendLineFromStation: At i=",i," examining stop, stopIndex=",stopIndex, " existingStop was ",existingStop, " lookup index was",i-existingStopOffset)
			if i == stopIndex then
				stop.stationGroup = existingStop.stationGroup
				stop.station = existingStop.station
				stop.terminal = chooseRightHandTerminal(stationVector,station,  freeTerminal,  existingStop.terminal, newStation, otherLineId)
				local originalFreeTerminal = freeTerminal
				if stop.terminal == freeTerminal then 
					freeTerminal = existingStop.terminal -- used coming back
				end
				trace("At i =",i," set the terminal to ",stop.terminal, " freeTerminal=",freeTerminal," originalFreeTerminal=",originalFreeTerminal )
			elseif i == 1+stopIndex then 
				stop.stationGroup = groupFromStation(newStation)
			--stop.station = 0
				setAppropriateStationIdx(stop, newStation)
				stop.terminal = getFreeTerminalForStation(newStation) 
				if  util.isStationTerminus(newStation) and util.countFreeTerminalsForStation(newStation) ==2  then 
					--local otherTerminal = getFreeTerminalsForStation(newStation)[2]
					local otherTerminal  -- getFreeTerminalForStation(station, nextStation, priorStop, {[stop.terminal] = true}) 
					for i, terminal in pairs(getFreeTerminalsForStation(newStation)) do 
						if terminal ~= stop.terminal then 
							otherTerminal = terminal 
							break
						end 
					end
					trace("Setting up alternative terminal at",otherTerminal)
					if otherTerminal then 
						local alternative = api.type.StationTerminal.new()
						alternative.station = stop.station 
						alternative.terminal = otherTerminal
						stop.alternativeTerminals[1]=alternative
					end
				end 
			elseif i == stopOffset+stopIndex then 
				stop.stationGroup = groupFromStation(station)
				stop.station = 0
				stop.terminal = freeTerminal
				trace("At i =",i," set the return terminal to ",stop.terminal)
				existingStopOffset = stopOffset  
			else  
				--stop.stationGroup = existingStop.stationGroup
				--stop.station = existingStop.station
				--stop.terminal =  existingStop.terminal
				stop = existingStop
			end
			newLine.stops[i]=stop  
		end
			  
		validateRailPaths(newLine)
	
		return newLine
	end
	if otherLineId then 
		trace("Setting up otherLineId=",otherLineId)
		otherLine = getLine(otherLineId)
		local lineToKeep = #otherLine.stops > #line.stops and otherLineId or lineId
		lineToKeep = lineId -- doesn't work with the other line as the input stations are not correct for it
		lineToRemoveId = lineToKeep == otherLineId and lineId or otherLineId
		lineToRemove = getLine(lineToRemoveId)
		
		--[[if lineId ~= lineToKeep then 
			trace("SWapping station")
			local temp = station
			station = newStation 
			newStation = temp
		end ]]--
		lineId = lineToKeep
		line = getLine(lineToKeep)
		line = setupLineDetails()
	
		stopOffset = #otherLine.stops
		setupLineDetails = function() 
			trace("Merging line ",lineId," from station ",newStation)
			newLine = api.type.Line.new()
			newLine.vehicleInfo = line.vehicleInfo
			local stopIndex = indexOfStop(line, newStation)
			local terminal1 = line.stops[stopIndex].terminal
			local otherStopIndex = indexOfStop(otherLine, newStation)
			
			local terminal2 = otherLine.stops[otherStopIndex].terminal
			local vehicleNodeId1 = util.getStation(newStation).terminals[terminal1+1].vehicleNodeId.entity
			local vehicleNodeId2 = util.getStation(newStation).terminals[terminal2+1].vehicleNodeId.entity
			local nodeVector = util.vecBetweenNodes( vehicleNodeId2,vehicleNodeId1)
			local nextStopIndex = 1+((otherStopIndex)%#otherLine.stops)
			local nextStop = otherLine.stops[nextStopIndex]
			local nextStation = stationFromStop(nextStop)
			trace("The nextStopIndex was ",nextStopIndex," of ",#otherLine.stops," the otherStopIndex was",otherStopIndex,"nextStation=",nextStation, "newStation=",newStation)
			local routeInfo = pathFindingUtil.getRouteInfo(newStation, nextStation)
			local exitVec = util.getEdgeMidPoint(routeInfo.edges[routeInfo.firstFreeEdge].id)-util.nodePos(vehicleNodeId2)
			local angle = util.signedAngle(nodeVector, exitVec)
			local isRightHanded = angle < 0 
			trace("The signedAngle was ",math.deg(angle), " isRightHanded=",isRightHanded, " the length of the exit vec was",vec3.length(exitVec)," the next station was",nextStation, " terminal1=",terminal1," terminal2=",terminal2)
			local endAt = isRightHanded and stopIndex or stopIndex-1
			for i = 1, endAt   do 
				local stop = line.stops[i]
				newLine.stops[i]=stop  
				trace("Copying existing stop at ",i,"station was",stationFromStop(stop), " terminal was ",stop.terminal)
			end 
			
			local stopOffset = isRightHanded and 0 or -1
			
			local theirStartFrom= 1--isRightHanded and 1 or #otherLine.stops 
			local theirEndAt = #otherLine.stops-- isRightHanded and #otherLine.stops or 1 
			local theirIncrement = 1--isRightHanded and 1 or -1 
			
			for i = theirStartFrom, theirEndAt, theirIncrement do 
				local stopIndexToCopy = 1+((otherStopIndex+(i-1)+stopOffset)% #otherLine.stops) 
				newLine.stops[1+#newLine.stops]=otherLine.stops[stopIndexToCopy]
				trace("Looking up their stop", otherStopIndex, " stopIndexToCopy",stopIndexToCopy," at i=",i, " their total stops=",#otherLine.stops, "new stop index=",#newLine.stops," station was",stationFromStop(otherLine.stops[stopIndexToCopy]), " terminal was",otherLine.stops[stopIndexToCopy].terminal)
			end 
			local startFrom = isRightHanded and stopIndex+1 or stopIndex
			for i = startFrom, #line.stops do 
				local stop = line.stops[i]
				newLine.stops[1+#newLine.stops]=stop  
				trace("Copying existing stop at ",i,"station was",stationFromStop(stop), " terminal was ",stop.terminal)
			end 
			trace("Setup new line with ",#newLine.stops," stops")
			return newLine
		end  
		
	end
	 
	
	if lineToRemoveId then 
		lineManager.addDelayedWork(function() 
			trace("Setting up to remove line",lineToRemoveId)
			lineManager.sellAllVehicles(lineToRemoveId)
			lineManager.addDelayedWork(function() 
				trace("Executing command to delete line",lineToRemoveId)
				api.cmd.sendCommand(api.cmd.make.deleteLine(lineToRemoveId), lineManager.standardCallback)
			end)
		end)
	end 
	
	local alreadyUpdated = false	
	--debugPrint({line=line, newLine=newLine })
	local function wrappedCallback(res, success) 
		if success then
			if not alreadyUpdated then 
				lineManager.addWork(function() 	
				updateLineAndAddVehicles(lineId, setupLineDetails() , callback)
				alreadyUpdated = true
				end)
			end
		else 
			callback(res, success)
		end
	end
	local params = getLineParams(lineId)
	local dummyLineDetails  = {} -- turns out that setting real details even before setting line will change the response of a query over line stops , need to wait for the track upgrade to confirm rail paths
	dummyLineDetails.stops = {}
	--for i = 1, #line.stops do 
	--	table.insert(dummyLineDetails.stops, { line.stops[i].stationGroup}) 
	--	dummyLineDetails.stops[i].stationGroup = line.stops[i].stationGroup
	--end
	--table.insert(dummyLineDetails.stops, { stationGroup = groupFromStation(newStation)}) 
	--table.insert(dummyLineDetails.stops, { stationGroup = groupFromStation(newStation)})
	
	if not routeBuilder.checkAndUpgradeToDoubleTrack(setupLineDetails() , wrappedCallback, params, station) then
		if not alreadyUpdated then 
			updateLineAndAddVehicles(lineId, setupLineDetails() , callback)
			alreadyUpdated = true 
		else 
			trace("Already called to update line")
			trace(debug.traceback())
		end
	end
	
end

function lineManager.isCircleLine(line) 
	if #line.stops <= 2 then 
		return false 
	end 
	local alreadySeen = {}
	for i, stop in pairs(line.stops) do 
		local station = stationFromStop(stop)
		if alreadySeen[station] then 
			return false
		end 
		alreadySeen[station]=true
	end 
	return true
end

function lineManager.checkAndExtendFrom(station, otherStation, vectorToOtherStation, callback, extendedLine)
	trace("lineManager.checkAndExtendFrom",station, otherStation,"begin")
	local freeTerminal 
	for i , terminal in pairs(util.getStation(station).terminals) do
		if #api.engine.system.lineSystem.getLineStopsForTerminal(station, i-1) == 0 then 
			freeTerminal = i-1
			break
		end
	end
	local options = {}
	for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station))) do
		trace("About to get line for ",lineId)
		local line = util.getComponent(lineId, api.type.ComponentType.LINE)
		if isPassengerLine(line) and not lineManager.isCircleLine(line) and stationAppearsOnceOnLineAndAdjacentToFreeTerminal(line, station,freeTerminal) and isRailLine(line) and not util.isStationTerminus(station) then
			local nextStation = stationFromGroup(getNextStationStop(line, station).stationGroup)
			local stationVector = util.getStationPosition(nextStation) - util.getStationPosition(station)
			local angle = util.signedAngle(vectorToOtherStation, stationVector)
			
			local freeNodes = util.getFreeNodesForConstruction(api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)) 
			local routeInfo = pathFindingUtil.getRouteInfo(station, nextStation) or pathFindingUtil.getRouteInfo(nextStation, station)
			local routeInfo2 = pathFindingUtil.getRouteInfo(station, otherStation) or pathFindingUtil.getRouteInfo(otherStation, station)
			
			local freeNode1 --= util.getNodeClosestToPosition(util.getStationPosition(nextStation), freeNodes) 
			for i, node in pairs(freeNodes) do 
				if routeInfo and routeInfo.containsNode(node) then 
					freeNode1 = node 
					break 
				end
			end 
			
			local freeNode2 --= util.getNodeClosestToPosition(util.getStationPosition(otherStation), freeNodes)
			
			for i, node in pairs(freeNodes) do 
				if routeInfo2 and routeInfo2.containsNode(node) then 
					freeNode2 = node 
					break 
				end
			end 
			trace("lineManager.checkAndExtendFrom: inspecting",lineId,"found routeInfo?",routeInfo~=nil,"found routeInfo2?",routeInfo2~=nil,"freeNode1?",freeNode1,"freeNode2?",freeNode2)
			if freeNode1 and freeNode2 then 
				local nodeGap = util.distBetweenNodes(freeNode1, freeNode2)
				trace("signed angle was ",math.deg(angle), " nodeGap was ",nodeGap)
				--math.abs(angle) < math.rad(90) or
				if  nodeGap >= 80 then -- minimum staiton length
					table.insert(options, {
						nextStation = nextStation,
						lineId = lineId,
						line = line,
						scores = { getTerminalGap(line, station,freeTerminal) } 
					})
					--extendLineFromStation(lineId, line, station, otherStation, nextStation,callback, extendedLine)
					--return lineId
				end
			end
		else 
			if util.tracelog then 
				trace("lineManager.checkAndExtendFrom failed a check:",isPassengerLine(line) ,not lineManager.isCircleLine(line) , stationAppearsOnceOnLineAndAdjacentToFreeTerminal(line, station,freeTerminal) , isRailLine(line), not util.isStationTerminus(station))
			end 
		end 		
	end
	if #options > 0 then 
		local best = util.evaluateWinnerFromScores(options)
		extendLineFromStation(best.lineId, best.line, station, otherStation, best.nextStation,callback, extendedLine)
		trace("lineManager.checkAndExtendFrom",station, otherStation,"found",best.lineId)
		return best.lineId
	end 
	trace("lineManager.checkAndExtendFrom",station, otherStation,"no options found")
end

function lineManager.checkIfLineCanBeExtended(station1, station2, callback)
	trace("Checking if line can be extended from ",station1, " to ", station2)
	local stationPos1 = util.getStationPosition(station1)
	local stationPos2 = util.getStationPosition(station2)
	local canExtend = lineManager.checkAndExtendFrom(station1, station2, stationPos1 - stationPos2, callback)
	canExtend = lineManager.checkAndExtendFrom(station2, station1, stationPos2 - stationPos1, callback, canExtend) or canExtend
	return canExtend
		
end


	

function lineManager.createNewLine(stations, callback, name, params)
	if #stations == 2 and  util.areStationsConnectedWithLine(stations[1], stations[2]) then 
		local otherLineId = util.areStationsConnectedWithLine(stations[1], stations[2]) 
		local vehicleCount = #api.engine.system.transportVehicleSystem.getLineVehicles(otherLineId)
		local lastUpdateTime = lineManager.lineLastUpdateTime[otherLineId]
		local otherLineStopCount = #getLine(otherLineId).stops
		local canAccept= vehicleCount == 0 and (not lastUpdateTime or (game.interface.getGameTime().time - lastUpdateTime > 600)) and otherLineStopCount ==2 
		
		trace("Discovered a line that already connects ",stations[1], stations[2], " otherLineId=",otherLineId,"vehicleCount=",vehicleCount,"lastUpdateTime=",lastUpdateTime,"otherLineStopCount=",otherLineStopCount, " canAccept?",canAccept)
		if canAccept then 
			trace("Substituting in this line instead")
			callback({resultEntity = otherLineId},true)
			return
		end 	
	end 
		
	local line = api.type.Line.new()
	
	if not params then params = {} end
	local isRailLine = isRailStation(stations[1])
	trace("Begin creating new line for ",#stations," stations. IsRailLine?",isRailLine," name=",name)
	for i, station in pairs(stations) do 	
		local stop = api.type.Line.Stop.new()
		stop.stationGroup =api.engine.system.stationGroupSystem.getStationGroup(station)
		setAppropriateStationIdx(stop, station)
		local nextStation =  stations[i+1] or stations[1]
		local priorStop = i>1 and line.stops[i-1]
		stop.terminal =  getFreeTerminalForStation(station, nextStation, priorStop, params)  
		local priorStation = i == 1 and stations[#stations] or stations[i-1]
		local isTerminus = nextStation == priorStation
		-- params.alwaysDoubleTrackPassengerTerminus and util.isStationTerminus(station)
		if i == 1 and params and params.isWaitForFullLoad then 
			trace("Setting load mode to full at ", name)
			stop.loadMode = api.type.enum.LineLoadMode.FULL_LOAD_ALL
			if params.projectedIntervalPerVehicle then 
				stop.maxWaitingTime = params.projectedIntervalPerVehicle
			end
		end 
		
		if isTerminus and util.countFreeTerminalsForStation(station) >=2 and (isRailLine or i ==1 and params.isCargo)then 
			trace("Lookging for alternative terminals")
			local otherTerminal 
			for i, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
				trace("Checking the otherTerminal", terminal," against the used terminal",stop.terminal)
				if terminal ~= stop.terminal then 
					otherTerminal = terminal 
					break
				end 
			end 
			if otherTerminal then 
				trace("Setting up alternative terminal at",otherTerminal)
				local alternative = api.type.StationTerminal.new()
				alternative.station = stop.station 
				alternative.terminal = otherTerminal
				stop.alternativeTerminals[1]=alternative
			else 
				trace("No alternative terminal found")
			end 
		end 
		if params and params.useDoubleTerminals  and not util.isStationTerminus(station) and util.countFreeTerminalsForStation(station) >=2 then 
			trace("Looking for free terminal for station")
			local otherTerminal  -- getFreeTerminalForStation(station, nextStation, priorStop, {[stop.terminal] = true}) 
			for i, terminal in pairs(getFreeTerminalsForStation(station, nextStation, priorStop)) do 
				if terminal ~= stop.terminal then 
					otherTerminal = terminal 
					break
				end 
			end
			if otherTerminal then 
				trace("Setting up alternative terminal at",otherTerminal)
				local alternative = api.type.StationTerminal.new()
				alternative.station = stop.station 
				alternative.terminal = otherTerminal
				stop.alternativeTerminals[1]=alternative
			end			
		end 
		
		--[[if i == 1 and params and params.cargoType then 
			trace("Setting up line for cargo ",params.cargoType)
			local stopConfig = stop.stopConfig
			local loadConfig = stop.stopConfig.load
			local unloadConfig = stop.stopConfig.load
			for cargoTypeIdx, cargoTypeName in pairs(util.deepClone(api.res.cargoTypeRep.getAll())) do 
				local config = (cargoTypeName == params.cargoType or cargoTypeIdx == params.cargoType) and 1 or 0
				trace("For cargoTypeIdx",cargoTypeIdx," the config is ",config)
				loadConfig:add(config)
				unloadConfig:add(config)
				--stop.stopConfig.load[config ]=cargoTypeIdx+1
				 --stop.stopConfig.unload[config ]=cargoTypeIdx+1
				--stop.stopConfig.load[cargoTypeIdx ]=config
				--stop.stopConfig.unload[cargoTypeIdx ]=config
				--stop.stopConfig.maxLoad[cargoTypeIdx+1]=config
			end 
			stopConfig.load = loadConfig
			stopConfig.unload = unloadConfig 
			stop.stopConfig=stopConfig
			if util.tracelog then debugPrint({stop=stop,stopConfig=stopConfig, loadConfig=loadConfig, unloadConfig=unloadConfig}) end
		end]]--
		line.stops[i]=stop  
	end
	if isRailLine then 
		validateRailPaths(line)
	end
	if not name then 
		name = _("Line").." "..nextTrainLineFn()
	end
	trace("About to create line with name ",name)
	lineCheck(name)
	local create = api.cmd.make.createLine(name, nextLineColorFn() , game.interface.getPlayer(), line)
	trace("Created the command to createLine, now about to send command ",name)
	api.cmd.sendCommand(create, callback)
	trace("The command was sent")
end



function lineManager.setupRoadLine(stations, transportMode, lineName, callback)	
local line = api.type.Line.new()
	for i, station in pairs(stations) do 
		local stop = api.type.Line.Stop.new()
		stop.stationGroup =api.engine.system.stationGroupSystem.getStationGroup(station) 
		stop.station = 0
		stop.terminal = 0
		line.stops[#line.stops+1]=stop
	end
	local transportModes = line.vehicleInfo.transportModes
	transportModes[transportMode]=1
	line.vehicleInfo.transportModes = transportModes -- seems to be necessary for some reason, hidden pass by value not reference? 
	--if tracelog then debugPrint({line=line})  end
	lineCheck(name)
	local create = api.cmd.make.createLine(lineName, nextLineColorFn() , game.interface.getPlayer(), line)
	api.cmd.sendCommand(create, callback)
end

 
function lineManager.replaceVehicle(vehicleId, alreadyAttempted)
	trace("Replacing stuck vehicle ",vehicleId)
	if not api.engine.entityExists(vehicleId) then 
		trace("WARNING! No vechile found for ",vehicleId," aborting")
		return
	end 

	
	local vehicle = util.getComponent(vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE)
	if not vehicle then 
		trace("WARNING! No vechile found for ",vehicleId," aborting")
		return
	end 

	local lineId = vehicle.line
	if isProblemLine(lineId) then 
		trace("Line is problem line",lineId,"aborting replacement") 
		return
	end 
	local transportVehicleConfig = vehicleUtil.copyConfig(vehicle.transportVehicleConfig)
	local depotOptions = lineManager.findDepotsForLine(lineId, vehicle.carrier)
	if #depotOptions == 0 then 
		trace("Unable to find depot for replacement")
		local callbackThis = function(res, success) 
			trace("lineManager.replaceVehicle callback")
			if success then 
				lineManager.addWork(function()  lineManager.replaceVehicle(vehicleId, true ) end)
			end 
		end 
		if not alreadyAttempted then 
			lineManager.buildDepotForLine(lineId, callbackThis)
		else 
			trace("WARNING! Unable to build depot")
		end 		
		return 
	end
	trace("About to sell vechicle",vehicleId)
	if api.engine.entityExists(vehicleId) and util.getComponent(vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE) then -- double check it still exists and is a vehicle or might crash
		api.cmd.sendCommand( api.cmd.make.sellVehicle(vehicleId), function(res, success) 
			if success then 
				lineManager.addWork(function() buyAndAssignVechicles(transportVehicleConfig, depotOptions, lineId, 1)end)
			end
		end)
	end
end

function lineManager.upgradeToTramLines(townLines) 
	local linesToUpgrade = {} 
	for i , line in pairs(townLines) do 
		if not isTramLine(getLine(line)) then 
			table.insert(linesToUpgrade, line)
		end 
	end 
	for i, lineId in pairs(linesToUpgrade) do 
		lineManager.addWork(function() 
			lineManager.upgradeBusToTramLine(lineId) 
		end)
	end
end 

function lineManager.upgradeBusToTramLine(lineId) 
	local vehicleCount = lineManager.sellAllVehicles(lineId)
	local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.TRAM)
	local params = getLineParams(lineId)
	params.tramTrackType = util.getCurrentTramTrackType()
	params.tramOnlyUpgrade = true
	if #depotOptions==0 then 
		trace("No tram depot options found, attempting to rectify")
		local line = getLine(lineId)
		local firstStation = stationFromStop(line.stops[1])
		local tramDepot = constructionUtil.searchForTramDepot(util.getStationPosition(firstStation), 500)
		if tramDepot then 
			routeBuilder.checkRoadRouteForUpgrade(lineManager.standardCallback, params, function() 
				local depotEntity = util.getConstruction(tramDepot).depots[1]
				return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findPathFromDepotToStop(depotEntity, line.stops[1], true))
			end)
		else 
			constructionUtil.buildTramDepotAlongRoute(firstStation, stationFromStop(line.stops[2]),params)
		end
	end 
	local newVehicleCount = math.ceil((2/3)*vehicleCount)
	lineManager.addDelayedWork(function() 
		local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.TRAM)
		local newVehicleConfig = vehicleUtil.buildTram()
		for i = 1, newVehicleCount do 
			lineManager.buyVehicleForLine(lineId,i, depotOptions, newVehicleConfig)
		end
	end)
	
end
function lineManager.convertTramToBusLine(lineId) 
	local vehicleCount = lineManager.sellAllVehicles(lineId)
	local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.ROAD)
	local params = getLineParams(lineId)
	if #depotOptions==0 then 
		trace("No   depot options found, attempting to rectify")
		 
		constructionUtil.buildRoadDepotAlongRoute(firstStation, stationFromStop(line.stops[2]),params)
		 
	end 
	 
	lineManager.addDelayedWork(function() 
	 
		local newLine =  api.type.Line.new()
		local line = getLine(lineId)
		for i, stop in pairs(line.stops) do 	
			newLine.stops[i]=stop
		end 
		newLine.vehicleInfo.transportModes[api.type.enum.TransportMode.BUS+1]=1
		--assert(isBusLine(newLine)) -- does not work
		if util.tracelog then debugPrint(newLine) end
		validateLine(newLine)
		local updateLine = api.cmd.make.updateLine(lineId, newLine)
		api.cmd.sendCommand(updateLine, function(res, success) 
			trace("Attempt to update line was",success)
			if success then 
				lineManager.addWork(function() 
					local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.ROAD)
					local newVehicleConfig = vehicleUtil.buildUrbanBus()
		
					for i = 1, vehicleCount do 
						lineManager.buyVehicleForLine(lineId,i, depotOptions, newVehicleConfig)
					end
				end)
			end 
		end)
	end)
	
end
function lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfVehicles, carrier, params, callback)
	trace("createLineAndAssignVechicles: Setting up for ",lineName," numberOfVehicles=",numberOfVehicles)
	if params then 
		params.lineName = lineName
	end
	local wrappedCallback = function(res, success)  
		if success then
			trace("createLineAndAssignVechicles: was success, adding work to buy vehicles for ",lineName," numberOfVehicles=",numberOfVehicles)
			if isProblemLine(res.resultEntity) then 
				trace("Detected that new line",res.resultEntity,"has a problem")
				if carrier == api.type.enum.Carrier.ROAD then 
					local callback = function(res, success) 
						trace("Result of attempting to build route to fix problem line was",success)
					end 
					if not params then 
						params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false)
					end 
					lineManager.executeImmediateWork(function() routeBuilder.buildRoadRouteBetweenStations(stations, lineManager.standardCallback, params,params, hasEntranceB, index) end)
				end 
			end 
			
			lineManager.addDelayedWork(function() 
				local lineId = res.resultEntity
				util.lazyCacheNode2SegMaps()
				local depotOptions
				if carrier == api.type.enum.Carrier.RAIL then
					local minStationLength = math.huge 
					for i , station in pairs(stations) do 
						minStationLength = math.min(constructionUtil.getStationLength(station), minStationLength)
					end
					trace("Now creating line and assigning vehicles  params.isElectricTrack?", params.isElectricTrack)
					trace("MinStationLength was ",minStationLength," for ",lineName)
					params.stationLength = minStationLength
				
					local info = vehicleUtil.getConsistInfo(vehicleConfig, params.cargoType)
--					local needsUpgrade = info.isElectric and not params.isElectricTrack or info.isHighSpeed and not params.isHighSpeedTrack
	--				params.isElectricTrack = params.isElectricTrack or info.isElectric
		--			params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
					
					local needsUpgrade = info.isElectric ~= params.isElectricTrack or info.isHighSpeed ~= params.isHighSpeedTrack
					params.isElectricTrack =  info.isElectric
					params.isHighSpeedTrack =  info.isHighSpeed
					params.allowDowngrades = not params.isCargo
					local line = util.getComponent(lineId, api.type.ComponentType.LINE)
					routeBuilder.checkForTrackupgrades(line, callback, params, lineManager.findDepotsForLine(lineId, carrier, true))
					if numberOfVehicles > 1 then 
						trace("createLineAndAssignVechicles: Checking and upgrading to double track")
						local callBackThis = function(res, success) 
							if success then 
								lineManager.addWork(function ()lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfVehicles, carrier, params, callback)end)
							else 
								trace("WARNING - failed to upgrade, setting vehiclesTo 1")
								numberOfVehicles =1 
								lineManager.addWork(function ()lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfVehicles, carrier, params, callback)end)
							end 
						end 
						if routeBuilder.checkAndUpgradeToDoubleTrack(line , callBackThis, params, nil) then 
							trace("createLineAndAssignVechicles: waiting for next callback while line is upgraded")
							return 
						end
					end 
					depotOptions = lineManager.findDepotsForLine(lineId, carrier, false, params.isElectricTrack)
				else 
					depotOptions = lineManager.findDepotsForLine(lineId, carrier, false, params and params.tramTrackType==2)
				end
				if #depotOptions == 0 then
					trace("createLineAndAssignVechicles: No depot options found, attempting to rectify")
					local newCallback = function(res, success)
						if success then
							lineManager.addWork(function()
								depotOptions = lineManager.findDepotsForLine(lineId, carrier)
								assert(#depotOptions>0,"no depots found for line!")
								-- RE-ENABLED for train purchase debugging
								buyAndAssignVechicles(vehicleConfig, depotOptions , lineId, numberOfVehicles, callback, params)
							end)
						else
							callback(res, success)
						end
					end
					constructionUtil.buildDepotAlongRoute(stations[1], stations[2], params, carrier, newCallback)
				else
					-- RE-ENABLED for train purchase debugging
					buyAndAssignVechicles(vehicleConfig, depotOptions , lineId, numberOfVehicles, callback, params)
				end 
			end)
		end
		if callback then 
			callback(res, success)
		end
	end		
	lineManager.createNewLine(stations, wrappedCallback, lineName, params)
end

function lineManager.setupBusLine(vehicleConfig, mainStation, station, numberOfBusses, prefix)
	local lineName = util.getComponent(station, api.type.ComponentType.NAME).name
	if prefix then 
		lineName = _(prefix).." "..lineName 
	end 
	lineName = lineName:gsub(_("Bus Stop"), _("Bus Line")) -- trying to preserve translations 
	lineManager.createLineAndAssignVechicles(vehicleConfig, {mainStation, station}, lineName, numberOfBusses, api.type.enum.Carrier.ROAD )
end
function lineManager.createIntercityBusLine(station1, station2, town1, town2, params, callback)
 
	local modelDetail = vehicleUtil.getBestMatchForIntercityBus()
	local targetCapacity = paramHelper.getParams().initialTargetBusCapacity
	
	local numberOfBusses = math.ceil(targetCapacity / vehicleUtil.getCargoCapacityFromId(modelDetail.modelId, "PASSENGERS"))
	trace("Initial numberOfBusses based on capacity was",numberOfBusses)
	local vehicleConfig = vehicleUtil.createVehicleConfig(modelDetail.modelId)
	
	local speed = (2/3)* modelDetail.model.metadata.roadVehicle.topSpeed -- estimate 
	local routeLength = util.distBetweenStations(station1, station2) -- likely underestimate
	local oldEstimatedTripTime = routeLength/speed
	
	
	local namePrefix=town1.name.." ".._("Intercity")
	local alreadyCalledBack = false
	local function wrappedCallback(res, success)
		util.clearCacheNode2SegMaps()
		if success then 
			if not alreadyCalledBack then 
				alreadyCalledBack = true 
				lineManager.addWork(function()
					util.lazyCacheNode2SegMaps()
					local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(vehicleConfig, {station1, station2}, params)
					local estimatedTripTime = throughputInfo.estimatedTripTime
					numberOfBusses = math.max(numberOfBusses, math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval))
					trace("estimated trip time was " , estimatedTripTime, " calculated number of busses required=",numberOfBusses, " oldEstimatedTripTime=",oldEstimatedTripTime)
					lineManager.setupFullStationBusLine(station1, station2, numberOfBusses, namePrefix, callback)	
				end)
			else 
				trace("WARNING!, Called back to create full station bus line multiple times")
			end
		else
			callback(res, success)
		end
	end
	routeBuilder.buildOrUpgradeForBusRoute(station1, station2, wrappedCallback, params)
end

function lineManager.setupBusLineBetweenStations(station1, station2, params)
	params = params or  paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
	local vehicleConfig = vehicleUtil.buildUrbanBus()
	local numberOfBusses = 2
	local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(vehicleConfig, {station1, station2}, params)
	local estimatedTripTime = throughputInfo.estimatedTripTime
	 
	local minBussesForInterval = math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval)
	trace("Calculated min trams for interval as",minBussesForInterval,"based on estimatedTripTime of ",estimatedTripTime)
	numberOfBusses = math.max(numberOfBusses, minBussesForInterval)
	local prefix = nil
	lineManager.setupBusLine(vehicleConfig, station1, station2, numberOfBusses, prefix)
end 

function lineManager.setupBusOrTramLine(vehicleConfig, station1, station2, lineName, numberOfBusses, isTram, callback, params)
	util.lazyCacheNode2SegMaps()
	params = params or  paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
	local stations = {station1}
	local stationGroupsToIgnore = {}
	stationGroupsToIgnore[api.engine.system.stationGroupSystem.getStationGroup(station1)]=true
	stationGroupsToIgnore[api.engine.system.stationGroupSystem.getStationGroup(station2)]=true
	if not params.expressBusRoute and pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2, isTram) then  
		local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2, isTram)
		local returnStations = {}
		for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
			local edge = routeInfo.edges[i].edge
			local isLeft 
			if i > 1 then 
				isLeft = edge.node1 == routeInfo.edges[i-1].edge.node0 or edge.node1 == routeInfo.edges[i-1].edge.node1
			else 
				isLeft = edge.node0 == routeInfo.edges[i+1].edge.node0 or edge.node1 == routeInfo.edges[i+1].edge.node1
			end
			if #edge.objects == 2 then 
				for i , edgeObjs in pairs(edge.objects) do
					local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(edgeObjs[1])
					if stationGroupsToIgnore[stationGroup] then 
						trace("Station group for ", edgeObjs[1], " was ",stationGroup," which is already start or end")
						break 
					end
					local objIsLeft = edgeObjs[2] == api.type.enum.EdgeObjectType.STOP_LEFT  
					trace("Idx=",i,"At edge ",routeInfo.edges[i].id," detemined ",edgeObjs[1]," is left? ",objIsLeft," we are left?",isLeft)
					if isLeft == objIsLeft  then 
						table.insert(stations, edgeObjs[1])
					else 
						table.insert(returnStations, edgeObjs[1])
					end
				end
			end
		end
		table.insert(stations, station2)
		for i = #returnStations, 1, -1 do
			table.insert(stations, returnStations[i])
		end
	else
		table.insert(stations, station2)
	end 
	local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(vehicleConfig, stations, params)
	local estimatedTripTime = throughputInfo.estimatedTripTime
	 
	local minBussesForInterval = math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval)
	trace("Calculated min trams for interval as",minBussesForInterval,"based on estimatedTripTime of ",estimatedTripTime)
	numberOfBusses = math.max(numberOfBusses, minBussesForInterval)
	local carrier = isTram and api.type.enum.Carrier.TRAM or api.type.enum.Carrier.ROAD
	for i, station in pairs({station1, station2}) do 
		if util.isBusStop(station) then 
			local lineStopCount = #api.engine.system.lineSystem.getLineStopsForStation(station)
			if lineStopCount > 0 then 
				local stationGroupId = api.engine.system.stationGroupSystem.getStationGroup(station )
				for j, otherStation in pairs(util.getComponent(stationGroupId, api.type.ComponentType.STATION_GROUP).stations) do 
					if otherStation ~= station and #api.engine.system.lineSystem.getLineStopsForStation(otherStation) < lineStopCount then
						trace("Swapping station",station," with ",otherStation)
						local stationIdx = util.indexOf(stations, station)
						stations[stationIdx]=otherStation
						break
					end 
				end 
			end 
		end 
	end 
	
	lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfBusses,carrier , params, callback)
end
function lineManager.getCallbackAfterBusChanged(town) 
	return function(res, success) 
		trace("Callback after bus changed for town",town," success=",success)
		if success then 
			lineManager.addDelayedWork(function() end) -- allow at least one tick
			lineManager.addDelayedWork(function() 
				
				local function expiringStation(stop) 
					return stop.station == -1
--										return #util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations == 0 
				end 
				local function lineIsForThisTown(line) 
					for i , stop in pairs(line.stops) do 
						if not expiringStation(stop) then 
							local station = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations[stop.station+1]
							local townForStation = api.engine.system.stationSystem.getTown(station)
							if townForStation ~= town then 
								return false 
							end 
						end 
					end 
					return true
				end 
				local function foundExpiringStation(line)
					for i , stop in pairs(line.stops) do
						if expiringStation(stop) then 
							return true 
						end 
					end 
					return false
				end
				local alreadyAssigned = {}
				local function findNewStopForLine() 
					for i, stationId in pairs(api.engine.system.stationSystem.getStations(town)) do 
						if #api.engine.system.lineSystem.getLineStopsForStation(stationId) == 0 
						and util.isBusStop(stationId, true) 
						and not alreadyAssigned[stationId] then 
							alreadyAssigned[stationId]=true
							return stationId 
						end 
					end 
				end 
				
				for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer()))) do 
					local line = getLine(lineId) 
					if isBusLine(line) and lineIsForThisTown(line) and (#line.stops == 1 or foundExpiringStation(line)) then 
						local newLine =  api.type.Line.new()
						for i, stopDetail in pairs(line.stops) do 	
							local stop = api.type.Line.Stop.new()
							stop.stationGroup = stopDetail.stationGroup 
							stop.station = stopDetail.station 
							stop.terminal = stopDetail.terminal
							if stop.station == -1 then 
								local newStation = findNewStopForLine() 
								stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(newStation)
								stop.station = util.indexOf(util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations, newStation) - 1
								stop.terminal = 0
							end 
							
							stop.loadMode = stopDetail.loadMode
							stop.minWaitingTime = stopDetail.minWaitingTime
							stop.maxWaitingTime = stopDetail.maxWaitingTime
							stop.waypoints = stopDetail.waypoints
							stop.stopConfig = stopDetail.stopConfig
							
							
							newLine.stops[i]=stop  
						end
						if #line.stops == 1 then 
							local stop = api.type.Line.Stop.new()
							local newStation = findNewStopForLine() 
							stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(newStation)
							stop.station = util.indexOf(util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations, newStation) - 1
							stop.terminal = 0
							newLine.stops[2]=stop
						end 
						validateLine(newLine) 
						local updateLine = api.cmd.make.updateLine(lineId, newLine)
						api.cmd.sendCommand(updateLine, lineManager.standardCallback)
					end
					
				end
			end)
			lineManager.addWork(function() end) -- to skip a cycle
		else 
			trace("WARNING!, was not success in repositionBusStops")
		end		
	end
end

function lineManager.setupFullStationBusLine(station1, station2, numberOfBusses, namePrefix, callback, params)
	local town =api.engine.system.stationSystem.getTown(station1)
	local useTrams = town==api.engine.system.stationSystem.getTown(station2)
	local lineName = namePrefix.." ".._(useTrams and "Tram Line" or "Bus Line")
	params = util.deepClone(params) or paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, false, util.distBetweenStations(station1, station2))
	params.targetThroughput = 25
	if useTrams then 
		params.tramTrackType = util.getCurrentTramTrackType()
		
	end
	params.distance = util.distBetweenStations(station1, station2)
	local vehicleConfig = useTrams and vehicleUtil.buildTram(params) or vehicleUtil.buildIntercityBus(params)
	
	
	constructionUtil.checkBusStationForUpgrade(station1, useTrams) 
	constructionUtil.checkBusStationForUpgrade(station2, useTrams) 
	local alreadyInvoked = false
	local wrappedCallback = function(res, success)
		trace("Result of attempt to add bus terminals was", success, " alreadyInvoked?",alreadyInvoked)
		if alreadyInvoked then return end 
		alreadyInvoked = true
		if success then 
			local wrappedCallback2 = function(res, success) 
				util.clearCacheNode2SegMaps()
				if success then 
					--if useTrams then 
						lineManager.addWork(function() lineManager.setupBusOrTramLine(vehicleConfig, station1, station2, lineName, numberOfBusses, useTrams, callback, params) end)
						
					if not params.expressBusRoute then 
						lineManager.addDelayedWork(function()  constructionUtil.repositionBusStops(town, lineManager.getCallbackAfterBusChanged(town) ) end)
					end
					--else 
						--lineManager.addWork(function() lineManager.createLineAndAssignVechicles(vehicleConfig, {station1, station2}, lineName, numberOfBusses, useTrams and api.type.enum.Carrier.TRAM or api.type.enum.Carrier.ROAD, params, callback)end)
				--end
				else 
					callback(res, success)
				end
			end
			
			lineManager.addWork(function()
				local wrappedCallBack3 = function(res, success) 
					util.clearCacheNode2SegMaps()
					if success and not params.expressBusRoute then 
						lineManager.addWork(function() constructionUtil.buildTramOrBusStopsAlongRoute(station1, station2, params, wrappedCallback2, useTrams)end)
					else 
						wrappedCallback2(res, success)
					end
				end
				if useTrams then 
					if constructionUtil.searchForTramDepot(util.getStationPosition(station1),500) then
						wrappedCallBack3(res, true)
					else 
						constructionUtil.buildTramDepotAlongRoute(station1, station2, params, wrappedCallBack3)
					end
				else 
					wrappedCallBack3(res, true)
				end 
				
			end)
			
		else
			debugPrint(res)
			callback(res, success)
		end
	end
	
	
	routeBuilder.buildOrUpgradeForBusRoute(station1, station2, wrappedCallback,params)	
 
end
 


function lineManager.findLineConnectingStations(station1, station2)
	for i, line in pairs(api.engine.system.lineSystem.getLineStopsForStation(station1)) do 
		for j, line2 in pairs(api.engine.system.lineSystem.getLineStopsForStation(station2)) do
			if line == line2 then
				return line
			end
		end
	end
end
function lineManager.getSourceStationForTruckStop(truckStop)
	for i, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(truckStop)) do 
		for j, stop in pairs(getLine(lineId).stops) do 
			local station = stationFromStop(stop) 
			if api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) ~= -1 then 
				return station 
			end
		end 
	end 
end
function lineManager.setupTownBusNetwork(   stationConstr, town, prefix )
	local townId = type(town)=="number" and town or town.id
	if  type(town)=="number" then 
		town = util.getEntity(townId)
	end
	local stations = util.deepClone(api.engine.system.stationSystem.getStations(townId))
	local busStops =  {}
	if not stationConstr then 
		trace("no stationConstr provided, attempting to find for",town.name)
		for i, station in pairs(stations) do 
			local stationEntity = util.getEntity(station)
			if stationEntity.carriers.ROAD and not stationEntity.cargo and not util.isBusStop(station) and util.countFreeTerminalsForStation(station)>0 then 
				stationConstr = util.getConstructionForStation(station)
				trace("Found station at ",station)
				break 
			end 
		end 
	end 
	--local depotEntity = util.getComponent(depotConstr ,api.type.ComponentType.CONSTRUCTION).depots[1]
	--trace("got depotEntity=",depotEntity)
 
	local mainStation
	if util.getEntity(stationConstr).type=="STATION" then 
		mainStation = stationConstr
	else 
		mainStation =  util.getComponent(stationConstr ,api.type.ComponentType.CONSTRUCTION).stations[1]
	end

	
	local modelDetail = vehicleUtil.getBestMatchForUrbanBus()
	local targetCapacity = paramHelper.getParams().initialTargetBusCapacity
	
	local numberOfBusses = math.ceil(targetCapacity / vehicleUtil.getCargoCapacityFromId(modelDetail.modelId, "PASSENGERS"))
	local config = vehicleUtil.createVehicleConfig(modelDetail.modelId)
	local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
	
	local function getMinNumberOfBusses(station1, station2)
		util.lazyCacheNode2SegMaps()
		local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(config, {station1, station2}, params)
		local estimatedTripTime = throughputInfo.estimatedTripTime
	 
		local minBussesForInterval = math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval)
		trace("Based on the estimatedTripTime of",estimatedTripTime," the numberOfBusses needs to be at least",minBussesForInterval)
		return math.max(numberOfBusses, minBussesForInterval) 
	end  
	local shouldBuildFullBusNetwork = util.countRoadStationsForTown(townId) <= 2 
	local alreadySeen = {}
	for i, s in pairs(stations) do 
		local station = s -- avoid capturing in closures
		local details = util.getStation(station)
		if not util.getEntity(station) or not util.getEntity(station).carriers then 
			util.clearCacheNode2SegMaps() 
			util.lazyCacheNode2SegMaps() 
		end
		if not details.cargo and util.getEntity(station).carriers.ROAD then 
			if api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) == -1 then -- bus stops do not have a construction
				if shouldBuildFullBusNetwork then 
					local edgeId = util.getEdgeForBusStop(station)
					local streetEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
					if #api.engine.system.lineSystem.getLineStopsForStation(station) == 0 and streetEdge.tramTrackType ==0 then  	
						lineManager.addWork(function() lineManager.setupBusLine(config, mainStation, station, getMinNumberOfBusses(station, mainStation), prefix) end)
					end 
				end
			elseif station ~= mainStation and not lineManager.findLineConnectingStations(station, mainStation) and not alreadySeen[lineManager.stationHash(station, mainStation)] then 
				alreadySeen[lineManager.stationHash(station, mainStation)] =true
				lineManager.addWork(function() lineManager.setupFullStationBusLine( mainStation, station, getMinNumberOfBusses(station, mainStation), town.name, lineManager.standardCallback ) end)
			end
		end
	end
	lineManager.standardCallback(nil, true)
end


function lineManager.stationHash(station1, station2) 
	if station1 > station2 then 
		return station1*100000+station2
	else 
		return station2*100000+station1
	end 
end 

 

local function isStopOverCrowded(lineId, stop) 
	local stationId = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations[1]
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	local cargoType = discoverLineCargoType(lineId)
	-- e.g.
	-- api.engine.system.simPersonAtTerminalSystem.getNumFreePlaces(util.getComponent(51567, api.type.ComponentType.STATION).terminals[1].personEdges[1])
	local busStop = false
	local cargoTypeIdx = type(cargoType)=="number" and cargoType or api.res.cargoTypeRep.find(cargoType)
	for t, terminal in pairs(station.terminals) do 
		if stop.terminal == t-1 then -- agr 
			if #terminal.personEdges == 0 then
				-- bus stops have no personEdges, count the people, it probably starts becoming overcrowded around 40
				if #api.engine.system.simPersonSystem.getSimPersonsAtTerminalForTransportNetwork(terminal.personNodes[1].entity) > 40 then
					trace("Found overcrowded bus stop on line=",lineId)
					return true
				else 
					return false 
				end
			end
			for i, edge in pairs(terminal.personEdges) do 
				if station.cargo then
					
					if api.engine.system.simCargoAtTerminalSystem.hasFreePlaces(edge,cargoTypeIdx) then 
						return false
					end
				else 
					local numFreePlaces = api.engine.system.simPersonAtTerminalSystem.getNumFreePlaces(edge)
					trace("NumfreePlaces on line",lineId," was ",numFreePlaces)
					if  numFreePlaces > 0 then
						return false
					end
				end
				
			end
		end
	end
	trace("No free capacity on line=",lineId)
	return true
end 

local function checkForOldVehicles(lineId, line, report, params)

	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	local cargoType = params.cargoType--discoverLineCargoType(lineId)
	local maxAge = 0
	local minAge = math.huge
	local totalCapacity = 0
	local ageFormatted 
	local currentCapacity = 0
	local gameTime = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	local transportVehicleConfig
	for i = 1, #vehicles do
		local vehicleDetail =  util.getComponent(vehicles[i], api.type.ComponentType.TRANSPORT_VEHICLE)
		transportVehicleConfig = vehicleUtil.copyConfig(vehicleDetail.transportVehicleConfig)
		for j = 1, #transportVehicleConfig.vehicles do
			local vehicle = transportVehicleConfig.vehicles[j]
			local maintenanceState = vehicle.maintenanceState 
			local purchaseTime = vehicle.purchaseTime
			local modelId = vehicle.part.modelId 
			local age = (gameTime-purchaseTime)/1000
			local model = vehicleUtil.getModel(modelId) 
			local capacity = vehicleUtil.getCargoCapacityFromId(modelId, cargoType)
			local lifespan = model.metadata.maintenance.lifespan
			--trace("Comparing the age",age," to the lifespan",lifespan)
			local ageRatio = age/lifespan
			maxAge = math.max(maxAge, ageRatio)
			minAge = math.min(minAge, ageRatio)
			totalCapacity = totalCapacity + capacity
			if ageRatio > 1 then 
				ageFormatted = api.engine.util.formatAge(purchaseTime, gameTime)
			end 
		end
		if i == 1 then 
			currentCapacity = totalCapacity
		end
		if maxAge > 1 then 
			--break
		end
	end
	report.maxAge = maxAge 
	report.minAge = minAge
	if maxAge < 1 then 
		return false 
	end
	if game.interface.getGameDifficulty() >= 2 and report.isShipLine and report.isCargo then -- on hard there is no point replacing old ships
		trace("Skipping old vehicle replacement for cargo route based on game difficulty")
		return false
	end 
	--report.targetLineRate = lineManager.getDemandRate(lineId,line, report, params )
	--if params.rateOverride then 
	--	report.targetLineRate = params.rateOverride
	--end
	--params.targetThroughput = report.targetLineRate
	--params.totalTargetThroughput = report.targetLineRate 
	report.isOk = false
	report.problems.oldVehicles = ageFormatted
	return true
	--[[
	trace("found old vehicles to replace maxAge=",maxAge) 
	local newVehicleConfig
	local vehiclesToSell 
	local vehiclesToReplace --  = 
	if params.isCargo then 
		local demandRate = report.targetLineRate
		local currentRate = util.getEntity(lineId).rate 
		--if currentRate == 0 then 
		--	currentRate = demandRate 
		--end
		local capacityNeeded = totalCapacity
		if currentRate > 0 then 
			capacityNeeded =   (demandRate / currentRate)*totalCapacity
			trace("Set the capacityNeeded as ",capacityNeeded," based on demandRate",demandRate,"currentRate=",currentRate,"totalCapacity=",totalCapacity)
		end
		params.initialTargetLineRate = demandRate
		if isRailLine(line) then
			--local params = setupParamsForRailLine(cargoType, line)
			params.routeInfo = pathFindingUtil.getRouteInfo(stationFromGroup(line.stops[1].stationGroup),stationFromGroup(line.stops[2].stationGroup))
			
			local estimatedCurrentThroughput = vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params)
			local estimatedCurrentLineRate = #vehicles*estimatedCurrentThroughput.throughput
			local correctionFactor = 1 
			
			if currentRate > 0 then 
				correctionFactor = currentRate / estimatedCurrentLineRate
			end
			params.targetThroughput = demandRate  * correctionFactor
			trace("The estimatedCurrentLineRate was ",estimatedCurrentLineRate," the actual line rate was" ,currentRate, " giving a correctionFactor of",correctionFactor," targetThroughput=",params.targetThroughput)
			newVehicleConfig = vehicleUtil.buildMaximumCapacityTrain(params)
			local newThroughput = vehicleUtil.estimateThroughputBasedOnConsist(newVehicleConfig, params).throughput
			trace("The newThroughput was ",newThroughput," the currentCapacity=",currentCapacity)
			if newThroughput >= params.targetThroughput then 
				--newVehicleConfig = vehicleUtil.buildTrain(currentCapacity, params)
				vehiclesToReplace = 1
				vehiclesToSell = #vehicles-1
			else 
				local vehiclesNeeded = math.ceil(params.targetThroughput/newThroughput) 
				params.targetThroughput = params.targetThroughput / vehiclesNeeded
				newVehicleConfig = vehicleUtil.buildTrain(currentCapacity, params)
				trace("Setting vehicles needed to ",vehiclesNeeded, " reset targetThroughput to",params.targetThroughput)
				vehiclesToReplace = vehiclesNeeded
				vehiclesToSell = #vehicles-vehiclesNeeded
			end
		elseif isRoadLine(line) then 
			newVehicleConfig = vehicleUtil.buildTruck(params)
			local stations = {} 
			for i = 1, #line.stops do 
				table.insert(stations, stationFromStop(line.stops[i]))
			end 
			
			local vehiclesNeeded = lineManager.estimateRoadVehiclesRquired(newVehicleConfig, stations, params) 
			local correctionFactor = 1
			if currentRate > 0 then 
				params.initialTargetLineRate = currentRate 
				local currentEstimate =  lineManager.estimateRoadVehiclesRquired(transportVehicleConfig, stations, params)
				correctionFactor = #vehicles / currentEstimate
				trace("THe currentEstimate was",currentEstimate,"the actual number was ",#vehicles," the correctionFactor was",correctionFactor," initial estimate was",vehiclesNeeded, " new estimate=",math.ceil(vehiclesNeeded*correctionFactor))				
			end 
		
			vehiclesNeeded = math.ceil(vehiclesNeeded*correctionFactor)
			vehiclesToReplace = vehiclesNeeded
			vehiclesToSell = #vehicles-vehiclesNeeded
		else
			newVehicleConfig = vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
			local newCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
			local vehiclesNeeded =  math.max(1, math.floor(capacityNeeded/newCapacity))
			vehiclesToReplace = vehiclesNeeded
			vehiclesToSell = #vehicles-vehiclesNeeded
		end
		
	else -- passengers
		if isRailLine(line) then
			
			newVehicleConfig = vehicleUtil.buildTrain(currentCapacity, params)
			vehiclesToReplace = #vehicles
			vehiclesToSell = 0
		else 
			newVehicleConfig = vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
			local newCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
			local vehiclesNeeded = math.max(1, math.floor(totalCapacity/newCapacity))
			vehiclesToReplace = vehiclesNeeded
			vehiclesToSell = #vehicles-vehiclesNeeded
		end
	end
	
	-- validation
	if vehiclesToReplace+vehiclesToSell ~= #vehicles or vehiclesToReplace < 1 or vehiclesToSell<0 then
		trace("Found invalid condition with vehiclesToReplace=",vehiclesToReplace," vehiclesToSell=",vehiclesToSell," #vehicles=",#vehicles, " on line ",lineId)
		vehiclesToReplace = math.max(vehiclesToReplace,1)
		vehiclesToReplace = math.min(vehiclesToReplace, #vehicles)
		vehiclesToSell = math.max(vehiclesToSell, 0)
		vehiclesToSell = #vehicles-vehiclesToReplace
	end
	
	report.newVehicleConfig = vehicleUtil.copyConfig(newVehicleConfig)
	checkForLineUpgrades(lineId, line, report, newVehicleConfig, params, transportVehicleConfig)
	report.vehicleCount = vehiclesToReplace - vehiclesToSell
	if not params.isCargo and report.vehicleCount < 2 and vehiclesToSell > 0 then 
		trace("Keeping minimum of 2 passenger vehicles")
		vehiclesToSell = vehiclesToSell - 1
		report.vehicleCount = report.vehicleCount + 1
		vehiclesToReplace = vehiclesToReplace + 1
	end 
	if vehiclesToReplace > 0 then 
		report.recommendations.vehiclesToReplace = vehiclesToReplace
	end
	if vehiclesToSell > 0 then 
		report.recommendations.vehiclesToSell = vehiclesToSell
	end	
	trace("Line report for life expired vehicles found",vehiclesToReplace,"vehiclesToReplace and",vehiclesToSell,"vehiclesToSell")
	table.insert(report.executionFns, function()
		for i = 1, vehiclesToReplace do
			local vehicleToReplace = vehicles[i]
			local replaceCommand = api.cmd.make.replaceVehicle(vehicleToReplace, vehicleUtil.copyConfigToApi(newVehicleConfig))
			api.cmd.sendCommand(replaceCommand, lineManager.standardCallback) 
		end	
	end) 
	 
	for i = 1, vehiclesToSell do 
		local vehicleToSell = vehicles [i+vehiclesToReplace]
		table.insert(report.executionFns, function()
			lineManager.addDelayedWork(function() api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell), lineManager.standardCallback) end)end)
	end
		
	return true	--]]
end
local function calculateRouteLength( line, params, report)
	if #line.stops < 2 then 
		return 0 
	end 
	local routeLength = 0 
	report.hasDoubleTerminals = true
	params.stations = {} 
	report.sections = {}
	for i = 1, #line.stops do 
		local priorStop = i==1 and line.stops[#line.stops] or line.stops[i-1]
		local station1 = stationFromStop(priorStop)
		local station2 = stationFromStop(line.stops[i])
		if #line.stops[i].alternativeTerminals == 0 then 
			report.hasDoubleTerminals = false
		end 
		report.distance = util.distBetweenStations(station1, station2)
		table.insert(params.stations, station2)
		
		-- setup section details NB annoyingly this is one offset 
		local stop1 = line.stops[i]
		local stop2 = i==#line.stops and line.stops[1] or line.stops[i+1]
		local section = {}
		report.sections[i] = section
		section.startStation = stationFromStop(stop1) 
		section.endStation = stationFromStop(stop2) 
		section.startTerminal = stop1.terminal 
		section.endTerminal = stop2.terminal
		section.straightDistance = util.distBetweenStations(station1, station2)
		section.routeLength = section.straightDistance
		
		
		table.insert(params.stations, station2)
		if isRailLine(line) then 
			local routeInfo =  pathFindingUtil.getRouteInfo(section.startStation, section.endStation,section.startTerminal, section.endTerminal)
			if routeInfo then 
				section.routeLength = routeInfo.routeLength
				routeLength = routeLength +routeInfo.routeLength
				if not report.routeInfos then 
					report.routeInfos = {} 
				end 
				report.routeInfos[i]=routeInfo
				if routeInfo.isDoubleTrack then 
					params.isDoubleTrack = true
				end 
			else 
				params.routeInfoMissing = true 
			end 
		elseif isRoadLine(line) then 
			if util.isTruckStop(station1) or util.isTruckStop(station2) then 
				params.hasTruckStop = true
			end
			local roadRoute =  pathFindingUtil.getRoadRouteInfoBetweenStations(section.startStation, section.endStation)
			if not roadRoute then 
				local maxDist = 3*util.distBetweenStations(section.startStation, section.endStation)
				roadRoute =  pathFindingUtil.getRoadRouteInfoBetweenStations(section.startStation, section.endStation, isTram, maxDist)
				trace("could not find road route between ",section.startStation, section.endStation, " attempted again at large dist",maxDist," was found?",roadRoute~=nil)
			end 
			--params.routeInfo=roadRoute
			if not report.routeInfos then 
				report.routeInfos = {} 
			end 
			
			
			if not roadRoute then
				trace("Unexpectedly could not find road route between ",station1, station2)
				routeLength = routeLength +util.distBetweenStations(station1, station2)
				params.routeInfoMissing = true 
			else 
				report.routeInfos[i]=roadRoute
				routeLength = routeLength +roadRoute.actualRouteLength
				if report.isMultiLaneRoute == nil then 
					report.isMultiLaneRoute = roadRoute.isMultiLaneRoute
				else 
					report.isMultiLaneRoute = report.isMultiLaneRoute and roadRoute.isMultiLaneRoute
				end 
				trace("roadRoute between",station1,station2,"Has hasOldStreetSections?",roadRoute.hasOldStreetSections)
				if roadRoute.hasOldStreetSections then 
					trace("Setting problems as having oldStreeSections")
					report.problems.hasOldStreetSections = true 
					report.isOk = false
				end 
			end
		else 
			routeLength = routeLength + util.distBetweenStations(station1, station2)
		end
		if line.stops[i].loadMode == api.type.enum.LineLoadMode.FULL_LOAD_ALL or line.stops[i].loadMode == api.type.enum.LineLoadMode.FULL_LOAD_ANY then 
			report.isWaitForFullLoad = true
		end 
	end 
	params.routeLength=routeLength
	params.routeInfos = report.routeInfos
	return routeLength
	
	
end


local function setupLineVehicles(report, params, alreadyAttempted)
	trace("Setting up line vehicles for",report.lineId)
	if isProblemLine(report.lineId) then 
		trace("Aborting setupLineVehicles as ",report.lineId,"is a problem line")
		return
	end 
	local newVehicleConfig
	if not report.targetThroughput then 
		report.targetThroughput = report.targetLineRate 
	end
	if not report.targetThroughput then 
		trace("WARNING! No throughput provided, guessing")
		report.targetThroughput = 100 
	end 
	report.totalTargetThroughput = report.targetThroughput
	if report.carrier == api.type.enum.Carrier.TRAM then 
	
	end 
	
	if report.carrier == api.type.enum.Carrier.RAIL then 
		newVehicleConfig = lineManager.estimateInitialConsist(params, report.routeLength).vehicleConfig 
	else 
		newVehicleConfig = vehicleUtil.buildVehicleFromCarrier(report.carrier, report) 
	end
	local depotOptions = lineManager.findDepotsForLine(report.lineId, report.carrier)
	local numberOfVehicles = 1	
    debugPrint({depotOptions = depotOptions } )
	if #depotOptions > 0 then 
		buyAndAssignVechicles(newVehicleConfig, depotOptions , report.lineId, numberOfVehicles, lineManager.standardCallback, report)
	elseif not alreadyAttempted then 
		alreadyAttempted= true 
		local newCallback = function(res, success) 
			if success then 
				lineManager.addWork(function() setupLineVehicles(report, params, alreadyAttempted) end)
			end 
		end 
		local line = getLine(report.lineId)
		params.line = line 
		local carrier = report.carrier
		if #line.stops < 2 then 
			trace("Unable to continue ,too few stops")
			return
		end 
		local station1 = stationFromStop(line.stops[1])
		local station2 = stationFromStop(line.stops[2])
		constructionUtil.buildDepotAlongRoute(station1, station2, params, carrier, newCallback, line)
		trace("WARNING! Unable to find depots attempting to buy again")
	end 
end 

local function isTownDelivery(cargoType) 
	if cargoType == "PASSENGERS" or cargoType == 0 then 	
		return false 
	end 
	local cargoRepIdx = type(cargoType)=="number" and cargoType or api.res.cargoTypeRep.find(cargoType)
	local cargoRep =  api.res.cargoTypeRep.get(cargoRepIdx) 
	return cargoRep.townInput and #cargoRep.townInput > 0 	
end 

local function hashTnEdge(tnEdge ) 
	return tnEdge.entity + 1000000*tnEdge.index
end 

local function findComplementaryLine(line, lineId)
	if #line.stops < 2 then 
		return 
	end
	local firstStation = stationFromStop(line.stops[1])
	local stationSet = {}
	for i, stop in pairs(line.stops) do 
		stationSet[stationFromStop(stop)]=true 
	end 
	
	local linesPassing = api.engine.system.lineSystem.getLineStopsForStation(firstStation)
	 
	for i, otherLine in pairs(linesPassing) do 
		if otherLine ~= lineId then 
			local line2 = getLine(otherLine)
			if #line2.stops == #line.stops and  lineManager.isCircleLine(line2) then 
				local countMatched = 0
				for i, stop in pairs(line2.stops) do 
					local theirStation = stationFromStop(stop)
					if stationSet[theirStation] then 
						countMatched = countMatched + 1
					else
						trace("Comparing line",lineId,"with",otherLine,"did not find",theirStation)
						break 
					end 
				end 
				if countMatched == #line.stops then 
					trace("Found line",otherLine,"as the complement of",lineId)
					return otherLine
				end 
			end 
		end 
	end 
end

function lineManager.getLineReport(lineId, line, isForVehicleReport, useRouteInfo, displayOnly, paramOverrides )
	util.lazyCacheNode2SegMaps() 
	if not line then 
		line = util.getComponent(lineId, api.type.ComponentType.LINE)
	end
	local oneMinute = 60875
	local report = {} 
	local params = getLineParams(lineId)
	if paramOverrides then 
		for k, v in pairs(paramOverrides) do 
			trace("getLineReport override: Setting params[",k,"] to",v)
			params[k]=v
		end 
	end 
	local gameTime = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	report.isOk = true 
	report.minAge = 0
	report.problems = {} 
	report.recommendations = {}
	report.upgrades = {}
	report.executionFns = {}
	report.upgradeBudget =0 
	report.stationLengthParam = params.stationLengthParam
	report.stationLength = params.stationLength

	function report.executeUpdate() 
		for i, execution in pairs(report.executionFns) do 
			--trace("at i=",i," adding work to execute from line report")
			lineManager.executeImmediateWork(execution)
			lineManager.lineLastUpdateTime[lineId]=game.interface.getGameTime().time
		end
	end
	if not params.cargoType then 
		trace("WARNING! Unable to find cargoTYpe")
		return report
	end 
	if not line then 
		trace("no line for ", lineId)
		return report
	end
	report.isCircleLine = lineManager.isCircleLine(line)
	if report.isCircleLine then 
		report.complementaryLine = findComplementaryLine(line, lineId)
	end 
	report.targetLineRate =  params.rateOverride or  lineManager.getDemandRate(lineId,line, report, params )
	
	report.isBusLine = isBusLine(line)
	report.isRoadLine = isRoadLine(line)
	report.isTruckLine = isRoadLine(line)
	report.isTramLine = isTramLine(line)
	report.isElectricTramLine = isElectricTramLine(line)
	report.isElectricRailLine = isElectricRailLine(line)
	report.isRailLine = isRailLine(line)
	report.isShipLine = isShipLine(line)
	report.isAirLine = isAirLine(line)
	report.rate = util.getEntity(lineId).rate
	if params.rateOverride and report.rate < params.rateOverride then 
		report.isOk = false 
	end
	report.lineId = lineId
	report.transportModes =  line.vehicleInfo.transportModes 
	report.stopCount = #line.stops
	local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
	report.lineName = naming.name
	report.useRouteInfo = true 
	report.routeLength = calculateRouteLength(line, params, report)
	report.existingTicketPrice = line.vehicleInfo and line.vehicleInfo.defaultPrice or 0
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	report.existingVehicleCount = #vehicles
	if report.isRailLine and (report.existingVehicleCount > 1 and not params.isDoubleTrack or params.routeInfoMissing) then 
		trace("Found a line with more than one vehicle not double track")
		report.problems.needsDoubleTrackUpgrade=true 
		table.insert(report.executionFns,1, function()
			trace("Check for upgrade to double track")
			routeBuilder.checkAndUpgradeToDoubleTrack( line, lineManager.standardCallback, params ) 
		end)
		
	end
	report.vehicleCount = #vehicles -- defaulted initially
	report.totalExistingTime = 0 
	report.currentInterval = 0
	report.impliedLoadTime = 0
	report.totalSectionTime = 0
	report.existingTimings = {}
	report.sectionTimesMissing = false
	report.topSpeed = 0
	report.cargoType = params.cargoType
	report.isTownDelivery = isTownDelivery(report.cargoType)
	report.isCargo = report.cargoType ~= "PASSENGERS"
	params.isCargo = report.isCargo 
	
	if report.isCircleLine and report.isRailLine then 
		if params.routeInfos then 
			params.allEdgeSections = {}
			for i, routeInfo in pairs(params.routeInfos) do 
				for j, tnEdge in pairs(routeInfo.tnEdges) do 
					params.allEdgeSections[hashTnEdge(tnEdge ) ]=true
				end 
			end 
		end
	end
	local transportVehicles = {}
	for i, vehicle in pairs(vehicles) do 
		table.insert(transportVehicles, util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE))
	end 
	
	if #vehicles > 0 then 
		local transportVehicle = transportVehicles[1]
		report.currentVehicleConfig = vehicleUtil.copyConfig(transportVehicle.transportVehicleConfig)
		
		
		
		report.carrier = transportVehicle.carrier
		if report.carrier == api.type.enum.Carrier.RAIL then 
			report.topSpeed = vehicleUtil.getConsistInfo(report.currentVehicleConfig, params.cargoType, params).topSpeed
		else 
			report.topSpeed = vehicleUtil.getTopSpeed(report.currentVehicleConfig) 
		end 
		if #vehicles > 1 then 
			for i = 2, #vehicles do 
				local thisVehicleConfig = transportVehicles[i]
				local vehicleConfig = thisVehicleConfig.transportVehicleConfig
				if not vehicleUtil.checkIfVehicleConfigMatches(report.currentVehicleConfig, vehicleConfig) then 
					report.problems.mixedTransportVehicles = true
					report.isOk = false
					break
				end 
			end 
		end 
		if report.isRailLine or report.isRoadLine then 
			report.estimatedCurrentThroughput =vehicleUtil.estimateThroughputBasedOnConsist(report.currentVehicleConfig, params) 
			report.expectedAverageSpeed = report.estimatedCurrentThroughput.averageSpeed
			
			if not params.isCargo then 
				local twentyMinutes = 20*60 -- I think this is the reachability threshold 
				local totalTime = report.estimatedCurrentThroughput.totalTime
				local fractionOfTotal = math.min(1,twentyMinutes / totalTime) -- simple heuristic to try to adjust for reachability
				trace("Setting up report, set fractionOfTotal=",fractionOfTotal,"totalTime=",totalTime)
				params.fractionBasedReachability = {
					totalTime = totalTime, 
					fractionOfTotal = fractionOfTotal,
				}
			end 
		end
	
	 
		local timingSamples = {}
		for i, transportVehicle in pairs(transportVehicles) do 
			 
			for j, t in pairs(transportVehicle.sectionTimes) do 
				if i == 1 then 
					table.insert(timingSamples, { total = 0, samples = 0})
				end 
				if t > 0 then 
					timingSamples[j].total = timingSamples[j].total + t 
					timingSamples[j].samples = timingSamples[j].samples + 1
				end 
			end 
			
		end 
		
		for i, timing in pairs(timingSamples) do 
			local t = 0
			if timing.samples > 0 then 
				t = timing.total / timing.samples
			end 
			report.totalSectionTime = report.totalSectionTime + t
			if t == 0 then 
				report.sectionTimesMissing=true
			end
			if report.sections and report.sections[i] then 
				report.sections[i].timing = t
			end 
			table.insert(report.existingTimings, t)
		end 
		local frequency = util.getEntity(lineId).frequency
		
		if frequency > 0 then 
			report.currentInterval = 1 / frequency
			report.totalExistingTime = report.currentInterval * #vehicles
			report.impliedLoadTime = report.totalExistingTime - report.totalSectionTime
		else
			report.totalExistingTime = report.totalSectionTime
			report.sectionTimesMissing=true
		end

	else 
		report.carrier = discoverLineCarrier(line)
	end 
	if not report.carrier then 
		trace("Unable to determine carrier, aborting") 
		return report 
	end
	if report.vehicleCount == 0 then
		report.problems.noVehicles = true
		report.isOk = false
		-- RE-ENABLED: Auto-vehicle setup for new lines
		table.insert(report.executionFns, function()
			setupLineVehicles(report, params)
		end)
		trace("[RESTORED] Line has no vehicles - auto-setup ENABLED")
	end
	report.averageSpeed = report.totalExistingTime ==0 and 0 or report.routeLength/report.totalExistingTime
	report.stoppedVehiclesEnRoute = 0
	report.movingVehiclesEnRoute = 0
	report.maxTimeStanding = 0 
	if not report.sectionTimesMissing and report.isShipLine then 
		local averageSectionSpeed = report.routeLength/report.totalSectionTime 
	 
	
		
		if #line.stops == 2 then
			report.estimatedDistance = pathFindingUtil.estimateShipDistanceForStations(stationFromStop(line.stops[1]), stationFromStop(line.stops[2])) 
			local unexpectedDifference =  math.abs(report.sections[1].timing - report.sections[2].timing)/(report.sections[1].timing + report.sections[2].timing)
			trace("Checking the difference for the ship line",report.lineName,"the unexpectedDifference factor was",unexpectedDifference,"initial averageSectionSpeed was ",api.util.formatSpeed(averageSectionSpeed))
			report.rateCorrectionFactor = (1+unexpectedDifference)
			if unexpectedDifference > 0.1 or report.isWaitForFullLoad then 
			
				local smallestTiming = math.min(report.sections[1].timing , report.sections[2].timing)
				averageSectionSpeed = report.routeLength/(2*smallestTiming)
				trace("Recalculated the averageSectionSpeed to",api.util.formatSpeed(averageSectionSpeed))
				if 	unexpectedDifference > 0.1 then 
					report.problems.vehiclesQueing = true 
					report.isOk = false
				end 
			end 
			
			
		end 
		report.impliedShipDistance = ((report.topSpeed / averageSectionSpeed)*report.routeLength)/#line.stops
	
		trace("For ship line setting the impliedShipDistance to ",report.impliedShipDistance," from an averageSectionSpeed",averageSectionSpeed,"over ",report.routeLength,"estimate was",report.estimatedDistance)
		if report.estimatedDistance then 
			report.impliedShipDistance = math.min(report.impliedShipDistance,report.estimatedDistance)
		end 		
		params.impliedShipDistance = report.impliedShipDistance
	
	end 
	
	for i , vehicle in pairs(vehicles) do 
		local transportVehicle = transportVehicles[i]
		if transportVehicle.state == api.type.enum.TransportVehicleState.EN_ROUTE then 
			local movePath = util.getComponent(vehicle, api.type.ComponentType.MOVE_PATH)
			local speed 
			if movePath then 
				if report.isCircleLine and report.isRailLine then 
					local edgeIdx = movePath.dyn.pathPos.edgeIndex+1
					if not movePath.path.edges[edgeIdx] then 
						trace("WARNING! No edge path for ",edgeId)
					else	 
						if params.allEdgeSections and not params.allEdgeSections[hashTnEdge(movePath.path.edges[edgeIdx].edgeId)] then 
							local age = gameTime - transportVehicle.transportVehicleConfig.vehicles[1].purchaseTime
							local ageInMinutes = math.floor(age/oneMinute)
							trace("Potentially off path vechicle found at ",vehicle, "age was",age,"estimatedMinutes=",ageInMinutes)
							if ageInMinutes > 10 then 
								report.problems.offPathVehicles = true 
								trace("Reporting ",vehicle,"as off path")
								table.insert(report.executionFns, function() 
									lineManager.replaceVehicle(vehicle)
								end)
							end 
							
						end 
					end 
				end 
				speed =  movePath.dyn.speed 
				if speed == 0 then 
					report.maxTimeStanding = math.max(report.maxTimeStanding , movePath.dyn.timeStanding)
					if not report.stoppedEnRoute then 
						report.stoppedEnRoute = {} 
					end 
					table.insert(report.stoppedEnRoute, {
						timeStanding =  movePath.dyn.timeStanding,
						isApproachinStation = movePath.dyn.approachingStation,
						vehicleId = vehicle,					
					})
				end 
			else 
				local movePathAircraft = util.getComponent(vehicle, api.type.ComponentType.MOVE_PATH_AIRCRAFT) -- NB this is for ships too
				if movePathAircraft then 
					speed = movePathAircraft.speed
				end 
			end
			if not speed then goto continue end
			if speed  == 0 then 
				report.stoppedVehiclesEnRoute = 1 + report.stoppedVehiclesEnRoute
			else 
				report.movingVehiclesEnRoute = 1 + report.movingVehiclesEnRoute
			end 
		
		end 
		::continue::
	end
	local minimumInterval = isRoadLine(line) and paramHelper.getParams().minimumIntervalRoad or paramHelper.getParams().minimumInterval
	local totalVehiclesEnRoute = report.stoppedVehiclesEnRoute + report.movingVehiclesEnRoute
	local congestionTest1 = report.stoppedVehiclesEnRoute  > #line.stops and ((report.stoppedVehiclesEnRoute-#line.stops) / totalVehiclesEnRoute) > 0.5 -- NB for a moment they are stopped at the station while enroute - so do not count these 
	local congestionTest2 = report.averageSpeed > 0 and report.topSpeed > 0 and report.averageSpeed < 0.1*report.topSpeed
	local congestionTest3 = #vehicles > 1 and report.currentInterval > 0 and report.currentInterval < minimumInterval*0.8 and util.year() > 1900 -- horse lines have a very low interval
	local congestionTest4 = report.stoppedVehiclesEnRoute > 10*#line.stops
	trace("getLineReport:",lineId,report.lineName," the congestion tests were",congestionTest1,congestionTest2,congestionTest3,congestionTest4,"report.stoppedVehiclesEnRoute=",report.stoppedVehiclesEnRoute)
	if congestionTest1
		or congestionTest2
		or congestionTest3
		or congestionTest4
	then 
		trace("Setting the possibleCongestion flag to true",lineId,report.lineName," the congestion tests were",congestionTest1,congestionTest2,congestionTest3)
		report.problems.possibleCongestion = true
		report.isOk = false
	end 	
	if not report.problems.possibleCongestion and (report.isRailLine and report.vehicleCount>0 or report.isRoadLine and report.vehicleCount > 10*#line.stops) then 
		local thresholdFactor = report.isRailLine and 0.75 or 0.4
		local belowThreshold = report.averageSpeed <  thresholdFactor * report.estimatedCurrentThroughput.averageSpeed
		trace("For line",lineId,report.lineName," comparing the projected averageSpeed:",report.estimatedCurrentThroughput.averageSpeed , " to the actual ",report.averageSpeed," belowThreshold?",belowThreshold)
		if belowThreshold then 
			trace("Setting the possibleCongestion flag to true",lineId,report.lineName," due to line speed")
			report.problems.possibleCongestion = true
			report.isOk = false
		end 
	end 
	if report.isRailLine and report.isCargo then 
		local averageRouteLength = report.routeLength/#line.stops 
		local baseParams = paramHelper.getParams()
		local currentStationLength = paramHelper.getStationLength()  
		trace("Inspecting",report.lineName,"station length was",report.stationLength,"currentStationLength=",currentStationLength,"averageRouteLength=",averageRouteLength)
		if report.stationLength < currentStationLength and averageRouteLength > baseParams.thresholdDistanceForPriorStationLength then 
			trace("Recommending the line",report.lineName,"is upgraded in length")
			report.recommendations.stationLengthUpgrade = true 
		end 
	end 
	
	if report.isAirLine then 
		if report.currentVehicleConfig then 
			local projectedInterval, numberOfVehicles=  lineManager.estimateAirLineTripTime(report.currentVehicleConfig , params.stations )
			trace("For the airline the projectedInterval was",util.formatTime(projectedInterval)," the actual interval was",util.formatTime(report.totalExistingTime))
			report.estimatedAirVehicles = numberOfVehicles
			if report.totalExistingTime > 1.5*projectedInterval then 
				report.problems.possibleCongestion = true
				report.isOk = false
			end
		end 
		if params.allowLargePlanes and not params.hasSecondRunway and util.isSecondRunwayAvailable() then 
			report.recommendations.addSecondRunway = true
			trace("Adding second runway recommendation")
		end 
		
	end 
	if report.maxTimeStanding > 30 and #vehicles > 2 then -- does not appear to work for ships
		trace("The maxTimeStanding was ", report.maxTimeStanding," the number stoppedEnRoute was",#report.stoppedEnRoute, " of ",#vehicles)
		if #report.stoppedEnRoute == #vehicles then 
			report.problems.stuckVehicles = true
			report.isOk = false
		end 
	end
	
	
	local account = util.getComponent(lineId, api.type.ComponentType.ACCOUNT)
	
	-- util.getComponent(151074, api.type.ComponentType.LOG_BOOK) TODO what can this tell us name2log.itemsTransported.
	
	local now  = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	local total = 0
	report.income = 0 
	report.maintenance = 0
	local totalOneYear = 0
	for i = #account.journal, 1, -1 do 
		local journal = account.journal[i]
		if now-journal.time <= 12*oneMinute then 
			if journal.category.type ==  api.type.enum.JournalEntryType.INCOME or   journal.category.type ==  api.type.enum.JournalEntryType.MAINTENANCE then 
				totalOneYear = totalOneYear + journal.amount
			end
		end 
		if now-journal.time > 12*oneMinute*5 then -- trying to get profitability over 5 year
			break 
		end 
		total = total + journal.amount 
		if journal.category.type ==  api.type.enum.JournalEntryType.INCOME then 
			report.income = report.income + journal.amount 
		elseif journal.category.type ==   api.type.enum.JournalEntryType.MAINTENANCE then
			report.maintenance = report.maintenance + journal.amount 
		end 
	end
	trace("Total amount for line", lineId," was calculated as",total)
	report.profit = total
	report.incomeToMaintenance = report.income/-report.maintenance
	if total < -100000 and totalOneYear < 0 then 
		-- commenting out isOk, need to find something else to actually be able to resolve poor profit e.g. too high throughput
		--report.isOk = false 
		report.problems.profit = api.util.formatMoney(math.floor(total))
		if report.isRailLine then 
			if report.stoppedVehiclesEnRoute > 0  then 
				--trace("Adding possible congestion flag to rail line with stopped vehicles") 
				--report.problems.possibleCongestion = true 
				--report.isOk = false
			else 
				
			end 			
		end
	end
	if isPassengerLine(line) and isAboveMaximumInterval(lineId, line, params) then
		report.isOk = false
		report.problems.isAboveMaximumInterval = _("Target")..": "..formatTime(params.targetMaximumPassengerInterval)
	end
	for i, stop in pairs(line.stops) do
		if isStopOverCrowded(lineId, stop) then 
			report.isOk = false
			report.problems.hasOvercrowdedStops = true
			break
		end
	end  
	
	local rate = util.getEntity(lineId).rate
	if rate > 0 then 
		if report.rateCorrectionFactor then 
			rate = rate * report.rateCorrectionFactor
		end 
		local demandRate = math.max(1, report.targetLineRate)
		trace("getLineReport: rate=",rate,"demandRate=",report.targetLineRate)
		if rate < 0.9*demandRate then 
			report.problems.rateBelowProduction = tostring(rate).." < "..tostring(demandRate) 
			report.isOk = false 
		end
		local threshold = game.interface.getGameDifficulty()>=2 and 1.25 or 1.5
		if report.problems.profit then 
			threshold = 1 
		end
		if rate > threshold*demandRate and not report.problems.hasOvercrowdedStops then 
			report.problems.rateAboveProduction = tostring(rate).." > "..tostring(demandRate) 
			report.isOk = false
		end
	end
	
	if report.isRailLine and report.problems.possibleCongestion and not isForVehicleReport  then 
		
		if not lineManager.lineLastReversedTime[lineId] then 
			lineManager.lineLastReversedTime[lineId] = 0
		end 
		local lastReversedTime = lineManager.lineLastReversedTime[lineId]
		local oneYear = 60*12 -- one minute is one in-game month
		
		
		local currentTime = game.interface.getGameTime().time
		trace("Found circle line with possible problems, lastReversedTime?",lastReversedTime,"currentTime=",currentTime)
		if lastReversedTime + oneYear < currentTime then 
			trace("Executing reversal")
			report.recommendations.resetVehicles = true
			lineManager.lineLastReversedTime[lineId] = game.interface.getGameTime().time -- do this here for ui thread 
			table.insert(report.executionFns, function() 
				reverseAllLineVehicles(lineId)
				
			end)
			--return report -- abort further work
		end 
	end
	
	if isForVehicleReport then
		report.isForVehicleReport = true
		-- DISABLED BY CLAUDE: Auto-vehicle adding for reports
		-- addMoreVehicles(lineId, line, report, params)
		trace("[CLAUDE-MODIFIED] Vehicle report generated - auto-add DISABLED")
		return report
	end
	
	
	
	 

	
	

	if checkForOldVehicles(lineId, line, report, params) then 
		--return report
	end
	
	if not report.isOk and not displayOnly then
		if report.minAge > 0.005 then -- bought vehicles recently needs time to have an effect
			-- DISABLED BY CLAUDE: Auto-vehicle adding when line has problems
			-- addMoreVehicles(lineId, line, report,params )
			trace("[CLAUDE-MODIFIED] Line has problems but auto-add vehicles DISABLED")
		else
			trace("Suppressing the update as the minAge of the vehicles was", report.minAge)
		end
	else
		trace("no problems detected on line ",lineId)
	end
	return report
end

function lineManager.createShipLine(result, stationConstr1, depotConst1, stationConstr2, depotConst2, callback, cargoType, initialTargetRate)
	if not initialTargetRate then
		initialTargetRate = 100
	end
	local station1 = stationFromConstruction(stationConstr1)
	local station2 = stationFromConstruction(stationConstr2)
	trace("Setting up a ship line between stations",station1,station2)
	local construction1  = constructionFromStation(station1) 
	local construction2  = constructionFromStation(station2) 
	local isCargo = util.getStation(station1).cargo
	--local allowLargeShips = construction1.params.size == 1 and construction2.params.size == 1
	--local allowLargeShips = construction1.params:at(5) == 1 and construction2.params:at(5) == 1
	local allowLargeShips =  isLargeHarbour(construction1)  and isLargeHarbour(construction2)
	
	trace("Getting ship vehicle config, allowLargeShips=",allowLargeShips, " construction1.params.size=",construction1.params.size, "construction2.params.size= ",construction2.params.size )
	local params = { cargoType = cargoType} 
	local carrier = api.type.enum.Carrier.WATER
	params.carrier = api.type.enum.Carrier.WATER 
	params.distance = util.distBetweenStations(station1, station2)
	params.targetThroughput = initialTargetRate
	local vehicleConfig = vehicleUtil.buildShip(params, allowLargeShips)
	local maxSpeed = vehicleUtil.getTopSpeed(vehicleConfig) 
	local loadTime = vehicleUtil.getLoadTime(vehicleConfig, cargoType) 
	local capacity = vehicleUtil.calculateCapacity(vehicleConfig, cargoType)
	local distance = util.distBetweenStations(station1, station2)
	local projectedInterval = 2*(loadTime + distance / (0.8*maxSpeed))
	trace("Projecting an interval of ",projectedInterval)
	params.projectedInterval = projectedInterval
	
	local depotOptions = {}
	if depotConst1 then 
		table.insert(depotOptions, { depotEntity=  depotFromConstruction(depotConst1), stopIndex = 0})
	end 
	if depotConst2 then 
		if not isCargo or not depotConst1 then 
			table.insert(depotOptions, { depotEntity=  depotFromConstruction(depotConst2), stopIndex = 1})
		end
	end 
	local numberOfVehicles = 1
	
	if isCargo then 
		local targetThroughput=  initialTargetRate/ (12 * 60)
		local projectedThroughput = capacity / projectedInterval 
		numberOfVehicles = math.ceil(targetThroughput/projectedThroughput)
		trace("Calculated numberOfVehicles=",numberOfVehicles," based on projectedThroughput",projectedThroughput," and targetThroughput=",targetThroughput)
		params.isWaitForFullLoad = true
	else 
		local targetInterval = paramHelper.getParams().targetMaximumPassengerInterval
		numberOfVehicles = math.ceil(projectedInterval / targetInterval)
		trace("Calculated numberOfVehicles=",numberOfVehicles," based on projectedInterval",projectedInterval," and targetInterval=",targetInterval)
	end 
	params.projectedIntervalPerVehicle = projectedInterval / numberOfVehicles
	trace("Got ship vehicle config cargoType=",cargoType, " set numberofVehicles to ",numberOfVehicles)
	local wrappedCallback = function(res, success) 
		trace("Result of creating ship line was ",success)
		if success then
			lineManager.addWork(function() 
				local line = res.resultEntity
				for i, lineId in pairs(api.engine.system.lineSystem.getProblemLines(game.interface.getPlayer())) do 
					if lineId == line then 
						trace("Line has not connected")
						callback(res, false)
						return
					end
				end
				 
				trace("Created ship line successfully, now building and assigning vehicles")
				if #depotOptions == 0 then 
					trace("No depot options initially found, attempting to compensate, carrier was",carrier)
					depotOptions = lineManager.findDepotsForLine(line, carrier)
					if #depotOptions == 0 then 
						trace("Still no depot options found, attempting to rectify ")
						local newCallback = function(res, success) 
							trace("result of callback to build depot along route was",success)
							if success then 
								lineManager.addWork(function() 
									depotOptions = lineManager.findDepotsForLine(line, carrier)
									assert(#depotOptions>0)
									buyAndAssignVechicles(vehicleConfig, depotOptions , line, numberOfVehicles, callback, params)
								end)
							else 
								callback(res, success)
							end 
						end 
						constructionUtil.buildDepotAlongRoute(station1, station2, params, carrier, newCallback, line)
						return
					end
				end 
				buyAndAssignVechicles(vehicleConfig, depotOptions, line, numberOfVehicles, callback, params)
				 
			end)
 
		else 
			callback(res, success)
		end 
	end
	local cargoRepIdx = type(params.cargoType)=="number" and params.cargoType or api.res.cargoTypeRep.find(params.cargoType)
	local cargoSuffix = _(api.res.cargoTypeRep.get(cargoRepIdx).name).." "
	--end 
	local lineName= result.location1.name.."-"..result.location2.name.." "..cargoSuffix 
	lineManager.createNewLine({station1, station2}, wrappedCallback, lineName, params)	 
end

local function findAirportForTown(townId, isCargo)
	for i, station in pairs(api.engine.system.stationSystem.getStations(townId)) do
		local construction = util.getConstructionForStation(station)
		if construction and string.find(construction.fileName, "air") and util.getStation(station).cargo == isCargo then
			return station
		end
	end
	
	local townName = util.getComponent(townId, api.type.ComponentType.NAME).name 
	local expectedName = townName.." ".._("Airport")
	trace("WARNING! No airport found, looking for airport with name",expectedName)
	local found 
	api.engine.forEachComponentWithEntity(function(entity) 
		local name = util.getComponent(entity, api.type.ComponentType.NAME).name 
		if name == expectedName then 
			found = entity
			trace("Found airport",entity)
		end 
	end)
	if found then 
		return found 
	end 
	
	assert(false)
end
function lineManager.extendLine(lineId, newStation)
	local lineDetails = util.getComponent(lineId, api.type.ComponentType.LINE)
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(newStation)
	trace("Exetending line",lineId," to ",newStation)
	local line = api.type.Line.new()
	local endWayPoints = {}
	for i, stopDetail in pairs(lineDetails.stops) do 	
		--[[local stop = api.type.Line.Stop.new()
		stop.stationGroup = stopDetail.stationGroup 
		stop.station = stopDetail.station 
		stop.terminal = stopDetail.terminal
		stop.loadMode = stopDetail.loadMode
		stop.minWaitingTime = stopDetail.minWaitingTime
		stop.maxWaitingTime = stopDetail.maxWaitingTime
		stop.waypoints = stopDetail.waypoints
		stop.stopConfig = stopDetail.stopConfig--]]
		
		if i == #lineDetails.stops then 
			endWayPoints = stopDetail.waypoints
			stopDetail.waypoints = {}
		end 
		line.stops[i]=stopDetail  
	end
	local newStop = api.type.Line.Stop.new()
	line.vehicleInfo = lineDetails.vehicleInfo
	newStop.stationGroup = stationGroup
	setAppropriateStationIdx(newStop, newStation)
	newStop.terminal =  getFreeTerminalForStation(newStation) 
	newStop.waypoints = endWayPoints
	line.stops[1+#line.stops]=newStop
	validateLine(line)
	local updateLine = api.cmd.make.updateLine(lineId, line)
	api.cmd.sendCommand(updateLine, function(res, success) 
		if success then 
			lineManager.addDelayedWork(function() 
				lineManager.checkAndUpdateLine(lineId)
			end)
		end
	end)

end
function lineManager.setupTrucks(result, stations, params, isForTranshipment) 
	--local cargoType = util.discoverCargoType(result.industry1)
	trace("Setting up trucks for cargo type =",params.cargoType)
	--params.cargoType = cargoType
	-- cargoPrefix = ""
--	if  result.industry1.type == "TOWN" or true then 
		local cargoRepIdx = type(params.cargoType)=="number" and params.cargoType or api.res.cargoTypeRep.find(params.cargoType)
	local cargoSuffix = _(api.res.cargoTypeRep.get(cargoRepIdx).name).." "
	--end 
	params = util.shallowClone(params)
	params.isDoubleTrack = false 
	params.isTrack = false 
	params.lineName= result.industry1.name.."-"..result.industry2.name.." "..cargoSuffix 

	if isForTranshipment then 
		params.lineName = _("Transhipment")..": "..params.lineName
	end 
	params.initialTargetLineRate = result.initialTargetLineRate
	lineManager.setupTruckLine(stations, params, result)
end 

function lineManager.estimateRoadVehiclesRquired(truckConfig, stations, params) 
	local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(truckConfig, stations, params)
	local estimatedTripTime = throughputInfo.estimatedTripTime
	local capacity = throughputInfo.capacity
	local routeLength = throughputInfo.routeLength
	local throughput = capacity / estimatedTripTime
	local initialTargetRate = params.rateOverride or params.initialTargetLineRate
	if not initialTargetRate then initialTargetRate = paramHelper.getParams().initialTargetLineRate end
	local targetThroughput = initialTargetRate/ (12 * 60) -- 12 minutes is one "year", 100 is minimum industry production
	local numberOfVehicles = math.max(1, math.ceil(targetThroughput/throughput))
	-- CLAUDE FIX: Cap initial vehicle count based on minimumIntervalRoad AND hard cap
	local minInterval = paramHelper.getParams().minimumIntervalRoad
	local maxVehicles = math.ceil(estimatedTripTime / minInterval)
	-- Hard cap to prevent too many vehicles on new lines
	local hardCap = paramHelper.getParams().maxInitialRoadVehicles or 5
	local minVehicles = paramHelper.getParams().minInitialRoadVehicles or 5
	maxVehicles = math.min(maxVehicles, hardCap)
	trace("CLAUDE: Initial numberOfVehicles=",numberOfVehicles," maxVehicles=",maxVehicles," minVehicles=",minVehicles," hardCap=",hardCap," (tripTime=",estimatedTripTime,", minInterval=",minInterval,")")
	if numberOfVehicles > maxVehicles then
		trace("CLAUDE: CAPPING numberOfVehicles from",numberOfVehicles,"to",maxVehicles)
		numberOfVehicles = maxVehicles
	end
	-- Ensure minimum vehicles
	if numberOfVehicles < minVehicles then
		trace("CLAUDE: RAISING numberOfVehicles from",numberOfVehicles,"to",minVehicles)
		numberOfVehicles = minVehicles
	end
	params.projectedIntervalPerVehicle = estimatedTripTime / numberOfVehicles
	if params.isPrimaryIndustry then
		params.isWaitForFullLoad = true
	end
	trace("caluclated numberOfVehicles=",numberOfVehicles," based on throughput=",throughput, " targetThroughput=",targetThroughput, " and estimatedTripTime=",estimatedTripTime, " routeLength=",routeLength)
	return numberOfVehicles
end

function lineManager.setupTruckLine(stations, params, result, alreadyCalled) 
	if not params.distance then 
		trace("Setting up params.distance")
		params.distance = util.distBetweenStations(stations[1], stations[2])
	end
	params.targetThroughput = params.initialTargetLineRate
	params.totalTargetThroughput = params.initialTargetLineRate
	if not params.targetThroughput then 
		trace("Defaulting the targetThroughput")
		params.targetThroughput = 50 
		params.totalTargetThroughput = 50
	end 
	params.routeInfos= {}
	for i, station in pairs(stations) do
		local nextStation = i == #stations and stations[1] or stations[i+1]
		local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station, nextStation)
		if not routeInfo then
			if not alreadyCalled then 
				alreadyCalled = true 
				trace("WARNING! lineManager.setupTruckLine no route info found between",station,nextStation,"attempting to correct")
				local callbackThis = function(res, success) 
					trace("Attempt to build route was",success)
					if success then 
						lineManager.addWork(function() lineManager.setupTruckLine(stations, params, result, alreadyCalled) end)
					end 
				
				end 
				local hasEntranceB = { false, false} -- TODO could fix this
				routeBuilder.buildRoadRouteBetweenStations(stations, callbackThis, params,result, hasEntranceB, index)
				return
			else 
				
				local maxDist = 5*util.distBetweenStations(station, nextStation)
				routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station, nextStation, false, maxDist)
				trace("Attempting at a larger distance success?",routeInfo~=nil)
			end 
		end 
		params.routeInfos[i]=routeInfo
	end 
	if params.cargoType == "MAIL" or params.cargoType == "UNSORTED_MAIL" then 
		params.useAutoLoadConfig = true 
		trace("Setting useAutoLoadConfig to true for new line")
	end 
	local truckConfig = vehicleUtil.buildTruck(params)
	local numberOfVehicles = lineManager.estimateRoadVehiclesRquired(truckConfig, stations, params)  
	local lineName = params.lineName
	lineManager.createLineAndAssignVechicles(truckConfig, stations, lineName, numberOfVehicles, api.type.enum.Carrier.ROAD, params )
end

function lineManager.estimateAirLineTripTime(vehicleConfig, stations)
	
	local maxSpeed = vehicleUtil.getTopSpeed(vehicleConfig) 
	local loadTime = vehicleUtil.getLoadTime(vehicleConfig, "PASSENGERS") 
	
	local taxiAndApproachTime = 286 -- measured time of Airbus A320 travelling between airports next to each other 
	local projectedInterval = 0 
	for i = 1, #stations do 
		local priorStation = i==1 and stations[#stations] or stations[i-1]
		local station = stations[i]
		local dist = util.distBetweenStations(priorStation, station)
		local tripTime = dist / maxSpeed -- probably not worth trying to optimise, some time for accel /decel but approach may also reduce distance
		projectedInterval = projectedInterval +  tripTime + loadTime+taxiAndApproachTime
	end 
	

	local targetInterval = paramHelper.getParams().targetMaximumPassengerAirInterval

	local numberOfVehicles = math.ceil(projectedInterval / targetInterval)
	
	trace("estimateAirLineTripTime: Projecting an interval of ",projectedInterval, " based on tripTime=",tripTime,"taxiAndApproachTime=",taxiAndApproachTime,"loadTime=",loadTime, " numberOfVehicles set to ",numberOfVehicles)
	return projectedInterval, numberOfVehicles
end

function lineManager.createAirLine(town1, town2, result) 
	trace("Creating air line between ", town1.name, " and ",town2.name)
	local station1 = findAirportForTown(town1.id, false)
	local station2 = findAirportForTown(town2.id, false)
	local depot1 = util.getConstructionForStation(station1).depots[1]
	local depot2 = util.getConstructionForStation(station2).depots[1]
	local lineName = town1.name.."-"..town2.name.." ".._("Airline")
	local smallOnly = string.find(util.getConstructionForStation(station1).fileName, "airfield") or string.find(util.getConstructionForStation(station2).fileName, "airfield")
	local params = result
	params.totalTargetThroughput = result.initialTargetLineRate
	params.targetThroughput = params.totalTargetThroughput
	local vehicleConfig =  vehicleUtil.buildPlane(params, smallOnly)
	local projectedInterval, numberOfVehicles=  lineManager.estimateAirLineTripTime(vehicleConfig, {station1, station2} )
	params.targetThroughput = params.totalTargetThroughput / numberOfVehicles 
	params.vehicleCount = numberOfVehicles
	trace("createAirLine: Initial vehicle config was",api.res.modelRep.getName(vehicleConfig.vehicles[1].part.modelId)," for ",lineName)
	vehicleConfig = vehicleUtil.buildPlane(params,smallOnly)
	trace("createAirLine: Updated vehicle config was",api.res.modelRep.getName(vehicleConfig.vehicles[1].part.modelId)," params.targetThroughput=",params.targetThroughput," for ",lineName)	

	trace("createAirLine: Projecting an interval of ",projectedInterval, " based on tripTime=",tripTime,"taxiAndApproachTime=",taxiAndApproachTime,"loadTime=",loadTime, " numberOfVehicles set to ",numberOfVehicles)
	
	local depotOptions = {}
	table.insert(depotOptions, { depotEntity= depot1, stopIndex = 0})
	table.insert(depotOptions, { depotEntity=  depot2, stopIndex = 1})
	

	local wrappedCallback = function(res, success) 
		if success then
			local line = res.resultEntity
			trace("Created air line successfully, now building and assigning vehicles")
			lineManager.addWork(function() buyAndAssignVechicles(vehicleConfig, depotOptions, line, numberOfVehicles, lineManager.standardCallback)end) 
		end
		lineManager.standardCallback(res, success)
	end
	lineManager.createNewLine({station1, station2}, wrappedCallback, lineName, params)	
end

function lineManager.revalidateRailLine(lineId, stationId)
	trace("lineManager.revalidateRailLine: begin for ",lineId, stationId)
	local line = getLine(lineId)
	
	local newLine = api.type.Line.new()
	newLine.vehicleInfo = line.vehicleInfo
	for i, stop in pairs(line.stops) do 	
		
		if stationFromStop(stop) == stationId then 
			trace("lineManager.revalidateRailLine: found stop, checking") 
			local newStop = copyStop(stop)
			local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
			local nextStop  = i == #line.stops and line.stops[1] or line.stops[i+1]
			local nextStationId = stationFromStop(nextStop)
			local priorStation = stationFromStop(priorStop)
			if not checkForPath(stationId, nextStop ,priorStop, stop.terminal) then 
				local found = false
				trace("no path found for line",lineId, "at station",stationId, " old terminal was",stop.terminal)
				local station = util.getStation(stationId)
				for j = 1, #station.terminals do 
					local terminal = j-1 
					if checkForPath(stationId, nextStop ,priorStop, terminal) then 
						trace("Found path at terminal",terminal)
						newStop.terminal = terminal
						found = true
						break
					end 
					
				end 
				if not found then 
					trace("WARNING! No path found at ",stationId," for terminal",stop.terminal)
				end
			end 
			newLine.stops[i]=newStop
		else 
			newLine.stops[i]=stop  
		end 		
	end
	validateLine(newLine)
	local updateLine = api.cmd.make.updateLine(lineId, newLine)
	api.cmd.sendCommand(updateLine, lineManager.standardCallback)
	trace("lineManager.revalidateRailLine: complete for ",lineId, stationId)
end

function lineManager.revalidateRailLines(stationId) 
	trace("lineManager.revalidateRailLines begin")
	local lineStops = api.engine.system.lineSystem.getLineStopsForStation(stationId)
	local problemLines = api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer())
	
	for i, lineId in pairs(problemLines) do 
		if util.contains(lineStops, lineId) then 
			trace("Discovered problem line for LineId, attempting to fix",lineId)
			lineManager.addWork(function() lineManager.revalidateRailLine(lineId, stationId) end)
		end 
	end 
end

function lineManager.setupCargoAirline(result, callback)
	local constr1 = util.getConstructionForStation(result.airport1)
	local constr2 = util.getConstructionForStation(result.airport2)
	local station1 
	local station2 
	for i , station in pairs(constr1.stations) do 
		if util.getStation(station).cargo then 
			station1 = station 
			break
		end 
	end 
	for i , station in pairs(constr2.stations) do 
		if util.getStation(station).cargo then 
			station2 = station 
			break
		end 
	end 
	
	local depot1 = constr1.depots[1]
	local depot2 = constr2.depots[1]
	
	local smallOnly = string.find(util.getConstructionForStation(station1).fileName, "airfield") or string.find(util.getConstructionForStation(station2).fileName, "airfield")
	local params = { cargoType = result.cargoType}
	local dist = util.distBetweenStations(station1, station2)
	params.distance = dist
	
	local vehicleConfig =  vehicleUtil.buildPlane(params, smallOnly)
	
	local maxSpeed = vehicleUtil.getTopSpeed(vehicleConfig) 
	local loadTime = vehicleUtil.getLoadTime(vehicleConfig, result.cargoType) 
	local tripTime = dist / maxSpeed -- probably not worth trying to optimise
	local taxiAndApproachTime = 286 -- measured time of Airbus A320 travelling between airports next to each other 
	local projectedInterval = 2*(tripTime + loadTime+taxiAndApproachTime)
	local targetThroughput=  result.initialTargetLineRate/ (12 * 60)
	local capacity = vehicleUtil.calculateCapacity(vehicleConfig, result.cargoType)
	local projectedThroughput = capacity / projectedInterval 
	local numberOfVehicles = math.ceil(targetThroughput/projectedThroughput)
	trace("Calculated numberOfVehicles=",numberOfVehicles," based on projectedThroughput",projectedThroughput," and targetThroughput=",targetThroughput)
	
	
	local depotOptions = {}
	table.insert(depotOptions, { depotEntity= depot1, stopIndex = 0})
	table.insert(depotOptions, { depotEntity=  depot2, stopIndex = 1})
	
	local wrappedCallback = function(res, success) 
		if success then
			local line = res.resultEntity
			trace("Created air line successfully, now building and assigning vehicles")
			lineManager.addWork(function() buyAndAssignVechicles(vehicleConfig, depotOptions, line, numberOfVehicles, callback)end)
		end
		lineManager.standardCallback(res, success)
	end
	lineManager.createNewLine({station1, station2}, wrappedCallback, name, params)	
	
end

local function getLines(circle, filterFn, maxToReturn)
	local allLines
	if not maxToReturn then maxToReturn = math.huge end
	if circle and circle.radius ~= math.huge then 
		allLines = {} 
		local alreadySeen = {} 
		for i, stationId in pairs(game.interface.getEntities(circle, {type="STATION"})) do 
			for j, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(stationId)) do 
				if not alreadySeen[lineId] then
					alreadySeen[lineId] = true 
					table.insert(allLines, lineId)
					if #allLines >= maxToReturn then 
						return allLines
					end
				end
			end 
		end		
	else 
		allLines = util.deepClone(api.engine.system.lineSystem.getLines()) -- seems to be necessary to assign this a local variable
	end
	if filterFn then 
		local filterResult = {} 
		for i, lineId in pairs(allLines) do 
			if filterFn(lineId, getLine(lineId)) then 
				table.insert(filterResult, lineId) 
				if #filterResult >= maxToReturn then 
					return allLines
				end
			end 
		end 
		return filterResult
	end 
	
	return allLines
end
lineManager.getLines = getLines
function lineManager.getLinesReport(limit, circle, filterFn, paramOverrides)
	local begin = os.clock()
	profiler.beginFunction("lineManager.getLinesReport")
	if not filterFn then filterFn = function() return true end end
	util.lazyCacheNode2SegMaps() 
	local allLines = getLines(circle)
	lineManager.cargoSourceMap = util.deepClone(api.engine.system.stockListSystem.getCargoType2stockList2sourceAndCount())
	trace("Cloned cargoSourceMap, time taken was ",(os.clock()-begin))
	local reports = {}
	if not limit then limit = math.huge end
	local count =0 
	for i, lineId in pairs(allLines) do 
		
	 
			
		if filterFn(lineId ) and api.engine.entityExists(lineId)  then 
			--trace("about to get line for ",lineId, " count = ",count)
			local line = util.getComponent(lineId, api.type.ComponentType.LINE)
			local beginLineReport = os.clock()
			profiler.beginFunction("lineManager.getLineReport")
			local lineReport = lineManager.getLineReport(lineId, line, false, false, false, paramOverrides)
			profiler.endFunction("lineManager.getLineReport")
			trace("Got reports, time taken was ",(os.clock()-beginLineReport), " for ",lineId, " ", lineReport.lineName, " reportsCollected=",#reports)
			if not lineReport.isOk and util.size(lineReport.recommendations) > 0 then 
				count = count + 1
			end
			table.insert(reports, lineReport)
			if count >= limit then 
				break 
			end
		end
		 
	end
	lineManager.cargoSourceMap = nil
	trace("Got reports, time taken was ",(os.clock()-begin))
	profiler.endFunction("lineManager.getLinesReport")
	profiler.printResults()
	return reports
end

local function isCargoLine(line) 
	if #line.stops > 0 then 
		return util.getStation(stationFromStop(line.stops[1])).cargo
	end 
	
	return false 
end 

function lineManager.checkLinesAndUpdate(param, reportFn)
	local filterFn
	if param and (param.carrier ~= -1 or param.cargoFilter ~= 0) then 
		filterFn = function(lineId )  
			return api.engine.entityExists(lineId) 
			and (param.cargoFilter == 0 or (param.cargoFilter == 1) == isCargoLine(getLine(lineId))) 
			and (param.carrier == -1 or param.carrier == discoverLineCarrier(getLine(lineId)))
		end
	end
	local currentTime = game.interface.getGameTime().time
	local oneYear = 60*12 -- one minute is one in-game month
	local nineMonths = 60*9
	if not param then  
		
		
		
		
		filterFn = function(lineId ) 
		
			if not lineManager.lineLastCheckedTime[lineId] then 
				lineManager.lineLastCheckedTime[lineId] = currentTime
				return true 
			end 
			if lineManager.lineLastUpdateTime[lineId] then 
				local timeSinceUpdate = currentTime - lineManager.lineLastUpdateTime[lineId]
				if timeSinceUpdate < 5*oneYear then 
					return false 
				end 
			end 
			local timeSinceChecked = currentTime - lineManager.lineLastCheckedTime[lineId]
			if timeSinceChecked > oneYear then 
				lineManager.lineLastCheckedTime[lineId] = currentTime
				return true 
			end 
			return false
		end 
	end 

	if not reportFn then reportFn = function() end end
	reportFn("Checking lines", "Analysing.")
	local reports = lineManager.getLinesReport(nil, nil, filterFn, param and param.paramOverrides)
	local count = 0 
	local completionCount = 0
	local originalCallback = lineManager.standardCallback
	lineManager.standardCallback = function(res, success) 
		completionCount = completionCount + 1 
		reportFn("Updating line "..completionCount.." of "..count, "Updating.")
		if completionCount >= count then 
			lineManager.standardCallback = originalCallback
			reportFn("Updating line "..completionCount.." of "..count, "Complete")
		end 
	end 
	local remainingReports = {}
	for i, report in pairs(reports) do 
		if not report.isOk then 
			if report.upgradeBudget <=0 then 
				report.executeUpdate() 
			else 
				table.insert(remainingReports, report)
			end 
		end
	end
	remainingReports = util.evaluateAndSortFromSingleScore(remainingReports, function(report) return report.upgradeBudget end)
	local cumulativeBudget = 0 
	local availableBudget = util.getAvailableBudget()
	util.overdueBudget = 0
	for i, report in pairs(remainingReports) do 
		if not report.isOk then 
			count = count + 1
			cumulativeBudget = report.upgradeBudget + cumulativeBudget
			if availableBudget < cumulativeBudget then 
				trace("aborting at ",i," because the cumulativeBudget exceeds availalbe",cumulativeBudget," vs ",availableBudget, " upgrades performed was",count)
				lineManager.lineLastCheckedTime[report.lineId]=currentTime-nineMonths -- recheck soon
				--break 
				util.overdueBudget = util.overdueBudget + report.upgradeBudget
			else
				util.ensureBudget(cumulativeBudget)
				report.executeUpdate() 
			end 
		end
	end	

	-- ROI-driven corridor upgrades: once per game year, when cash is healthy,
	-- add double-track/parallel capacity to the busiest shared corridors and
	-- upgrade the busiest lines automatically (best ROI first).
	if not lineManager.lastCorridorUpgradeTime or (currentTime - lineManager.lastCorridorUpgradeTime) > oneYear then
		if util.getAvailableBudget() > 1000000 then
			lineManager.lastCorridorUpgradeTime = currentTime
			trace("checkLinesAndUpdate: running corridor upgrade sweep (best-ROI)")
			xpcall(lineManager.upgradeBusiestLines, function(e) trace("upgradeBusiestLines error:", e) end)
			xpcall(lineManager.upgradeBusiestRoadLines, function(e) trace("upgradeBusiestRoadLines error:", e) end)
		end
	end
end
function lineManager.checkAndUpdateLine(lineId, paramOverrides)
	lineManager.getLineReport(lineId, nil, false, false, false, paramOverrides).executeUpdate()
end

function lineManager.buildVehicleFilterPanel() 
	 
	local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local all = util.newToggleButton("", "ui/construction/categories/all@2x.tga") 
	local road = util.newToggleButton("", "ui/hud/vehicle_bus@2x.tga") 
	local tram = util.newToggleButton("", "ui/hud/vehicle_tram@2x.tga") 
	local rail = util.newToggleButton("", "ui/hud/vehicle_train_electric@2x.tga") 
	local ship = util.newToggleButton("", "ui/hud/vehicle_ship@2x.tga") 
	local air = util.newToggleButton("", "ui/hud/vehicle_aircraft@2x.tga") 
	
	all:setTooltip(_("Show all"))
	road:setTooltip(_("Road vehicles only"))
	tram:setTooltip(_("Trams only"))
	rail:setTooltip(_("Trains only"))
	ship:setTooltip(_("Ships only"))
	air:setTooltip(_("Aircraft only"))
	 
	all:setSelected(true, false)
	buttonGroup:add(all)
	buttonGroup:add(road)
	buttonGroup:add(tram)
	buttonGroup:add(rail)
	buttonGroup:add(ship)
	buttonGroup:add(air)
	buttonGroup:setOneButtonMustAlwaysBeSelected(true)
	
	local buttonGroupCargo = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local allCargos = util.newToggleButton("", "ui/construction/categories/all@2x.tga") 
	local cargo = util.newToggleButton("", "ui/construction/categories/cargo@2x.tga") 
	local passenger = util.newToggleButton("", "ui/construction/categories/passenger buildings@2x.tga") 
	buttonGroupCargo:add(allCargos)
	buttonGroupCargo:add(cargo)
	buttonGroupCargo:add(passenger)
	allCargos:setSelected(true, false)
	buttonGroupCargo:setOneButtonMustAlwaysBeSelected(true)
	
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	boxLayout:addItem(buttonGroup)
	boxLayout:addItem(api.gui.comp.Component.new("VerticalLine"))
	boxLayout:addItem(buttonGroupCargo)
	return {
		panel = boxLayout,
		filterFn = function(lineId) 
			
			local line = getLine(lineId)
			
			if not allCargos:isSelected() and #line.stops > 0  then 
				local firstStation = stationFromStop(line.stops[1])
				if util.getStation(firstStation).cargo ~= cargo:isSelected() then 
					return false
				end 
				
			end
			if road:isSelected() then 
				return isRoadLine(line) and not isTramLine(line) 
			end 
			if tram:isSelected() then 
				return isTramLine(line)  
			end 
			if rail:isSelected() then 
				return isRailLine(line) 
			end 
			if ship:isSelected() then 
				return isShipLine(line) 
			end 
			if air:isSelected() then 
				return isAirLine(line) 
			end 
			return true 
		end,
		getCarrier = function() 
			if road:isSelected() then 
				return api.type.enum.Carrier.ROAD
			end 
			if tram:isSelected() then 
				return api.type.enum.Carrier.TRAM
			end 
			if rail:isSelected() then 
				return api.type.enum.Carrier.RAIL
			end 
			if ship:isSelected() then 
				return api.type.enum.Carrier.WATER
			end 
			if air:isSelected() then 
				return api.type.enum.Carrier.AIR
			end 
			return -1
		end,
		getCargoFilter = function()
			return buttonGroupCargo:getSelectedIndex()
		end,
		setCallback = function(callback) 
			buttonGroup:onCurrentIndexChanged(callback)
		end 
	}
end 

local function makelocateRow(report)
	local boxLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL"); 
	local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate.tga")
	local button = api.gui.comp.Button.new(imageView, true)
	button:onClick(function() 
		api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(report.lineId, false)
	end)
	boxLayout:addItem(button)
	boxLayout:addItem(api.gui.comp.TextView.new(_(report.lineName) or report.lineName))
	local comp= api.gui.comp.Component.new("")
	comp:setLayout(boxLayout)
	return comp
end

lineManager.makelocateRow = makelocateRow


local function makeTimingsPanel(timings, rawTimings, loadTime, isProjected)
	local totalTime = 0
	local tooltip 
	if rawTimings then 
		if isProjected then 
			tooltip ="Timings: (projected)\n"
		else 
			tooltip ="Timings: (uncorrected)\n"
		end 
	else 
		tooltip ="Timings:\n"
	end
	if loadTime then 
		tooltip = tooltip.."Load time: "..formatTime(loadTime).."\n"
		totalTime= totalTime+loadTime 
	end
	for i , timing in pairs(timings) do 
		totalTime = totalTime + timing
		tooltip = tooltip..formatTime(timing)
		if rawTimings then 
			tooltip = tooltip.." ("..formatTime(rawTimings[i])..")"
		end 
		tooltip = tooltip.."\n"
	end
	tooltip = string.sub(tooltip,1, -2)
	local panel = api.gui.comp.TextView.new(formatTime(totalTime))
	panel:setTooltip(tooltip)
	return panel
end
local function makeProjectedProfitPanel(report)
	local panel = api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.p.projectedProfit)))
	panel:setTooltip(_("Profit before depreciation: ")..api.util.formatMoney(math.floor(report.p.profitBeforeDepreciation)))
	return panel
end
 
local function makeProjectedCostsPanel(report)
	local panel = api.gui.comp.TextView.new(api.util.formatMoney(math.floor(-report.p.runningCost)))
	local toolTip = _("Vehicle maintenance")..": "..api.util.formatMoney(math.floor(report.p.costBeforeDepreciation)).." + "..api.util.formatMoney(math.floor(report.p.depreciation)).." ".._("depreciation")
	panel:setTooltip(toolTip)
	return panel
end
local function makeProjectedRevenuePanel(report)
	local panel = api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.p.projectedRevenue)))
	local toolTip = _("Projected payment per load")..": "..api.util.formatMoney(math.floor(report.p.projectedPaymentPerLoad)) 
	panel:setTooltip(toolTip)
	return panel
end
lineManager.makeTimingsPanel = makeTimingsPanel

local function textAndTooltipSpeed(text, toolTip) 
	local textView = api.gui.comp.TextView.new(api.util.formatSpeed(text))
	if toolTip then 
		textView:setTooltip(api.util.formatSpeed(toolTip))
	end 
	return textView
end 

function lineManager.buildLineDisplayTable(callbackFn) 
	local colHeaders = {
		api.gui.comp.TextView.new(_("Line")),
		api.gui.comp.TextView.new(_("Current\n rate")),
		api.gui.comp.TextView.new(_("Recommended\nrate")),
		api.gui.comp.TextView.new(_("#vehicles")),
		api.gui.comp.TextView.new(_("#stops")),
		api.gui.comp.TextView.new(_("Ticket\nprice")),
		api.gui.comp.TextView.new(_("Route\nlength")),
		api.gui.comp.TextView.new(_("Interval")),
		api.gui.comp.TextView.new(_("Totaltime")),
		api.gui.comp.TextView.new(_("topSpeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
	
		api.gui.comp.TextView.new(_("Profit")),
		api.gui.comp.TextView.new(_("Vehicle config")), 	
		api.gui.comp.TextView.new(_("Analyze")), 
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local function refreshTable(linesToReport, currentLineId)
		trace("Being refresh line manager table, got " ,#linesToReport," to report")
		displayTable:deleteAll()
		local allButtons = {}
		local count = 0
		for i = 1, #linesToReport do
			trace("Building line row for ",lineId)
			local lineId = linesToReport[i]
			local line = util.getComponent(lineId, api.type.ComponentType.LINE)
			local isForVehicleReport = false
			local report = lineManager.getLineReport(lineId, line, isForVehicleReport, false, true)
			local button = util.newButton("Analyze","ui/icons/game-menu/help@2x.tga")
			table.insert(allButtons, button)
			if lineId  == currentLineId then 
				button:setEnabled(false)
			end
			button:onClick(function() 
				lineManager.addWork(function() 
					for j = 1, #allButtons do 
						allButtons[j]:setEnabled(i~=j)
					end 
					callbackFn(lineId)
				end )			
			end)
			local projectedTImings = report.estimatedCurrentThroughput and report.estimatedCurrentThroughput.uncorrectedTimings
			displayTable:addRow({
				makelocateRow(report),
				api.gui.comp.TextView.new(tostring(math.ceil(report.rate))),				
				api.gui.comp.TextView.new(tostring(math.ceil(report.targetLineRate))),
				api.gui.comp.TextView.new(tostring(report.existingVehicleCount)),
				api.gui.comp.TextView.new(tostring(report.stopCount)),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.existingTicketPrice))),
				api.gui.comp.TextView.new(api.util.formatLength(math.floor(report.routeLength))),
				api.gui.comp.TextView.new(formatTime(report.totalExistingTime/report.existingVehicleCount)),
				makeTimingsPanel(report.existingTimings, projectedTImings, report.impliedLoadTime, true),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.topSpeed)),
				textAndTooltipSpeed(report.averageSpeed ),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.profit))),
				vehicleUtil.displayVehicleConfig(report.currentVehicleConfig),
				button,
			})
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( #linesToReport > 0, false)
		 
	end
	return {
		displayTable = displayTable,
		refresh = refreshTable
	}
	
end

function lineManager.replaceLineVehicles(lineId, params)
	local config= params.config
	local vehicleCount = math.max(params.vehicleCount,1)
	local existingVehicles = util.deepClone(api.engine.system.transportVehicleSystem.getLineVehicles(lineId))
	local line = getLine(lineId)
	if isRailLine(line) then 
		local params = getLineParams(lineId)
		local info = vehicleUtil.getConsistInfo(config, params.cargoType)
		
		if info.isElectric and not params.isElectricTrack or info.isHighSpeed and not params.isHighSpeedTrack  then
			trace("Vehicle replace may require upgrade, calling routeBuilder")
			params.isElectricTrack = params.isElectricTrack or info.isElectric 
			params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
			params.isVeryHighSpeedTrain = info.isVeryHighSpeedTrain
			lineManager.addWork(function() routeBuilder.checkForTrackupgrades(line, lineManager.standardCallback, params, lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL, true)) end)
		end
		if #existingVehicles == 1 and vehicleCount > 1 then 
			lineManager.addWork(function() routeBuilder.checkAndUpgradeToDoubleTrack( line, lineManager.standardCallback, params ) end)
		end		
		
	end
	
	local vehiclesToBuy = math.max(vehicleCount-#existingVehicles,0)
	local vehiclesToSell = math.max(#existingVehicles-vehicleCount, 0)
	local vehiclesToReplace = #existingVehicles-vehiclesToSell
	trace("Replacing line vehicles, vehiclesToBuy=",vehiclesToBuy,"vehiclesToSell=",vehiclesToSell,"vehiclesToReplace=",vehiclesToReplace)
	
	lineManager.addDelayedWork(function()
		for i = 1, vehiclesToReplace do 
			local replaceCommand = api.cmd.make.replaceVehicle(existingVehicles[i], vehicleUtil.copyConfigToApi(config))
			api.cmd.sendCommand(replaceCommand, function(res, success) 
				
				lineManager.standardCallback(res,success)
			end)
		end
	end)
	if vehiclesToSell > 0 then 
		lineManager.addDelayedWork(function()
			for i = 1, vehiclesToSell do  
				local vehicleToSell = existingVehicles[i+vehiclesToReplace]
				api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell), function(res, success) 
					 
					lineManager.standardCallback(res, success)
				end)  
			end
		end) 
	end
	if vehiclesToBuy > 0 then 
		lineManager.addDelayedWork(function()
			local depotOptions = lineManager.findDepotsForLine( lineId)
			for i = 1, vehiclesToBuy do 
				lineManager.buyVehicleForLine(lineId,i, depotOptions, config)
			end
		end)
	end 
end

local function cargoTypeDisplay(cargoType) 
	if type(cargoType) == "string" then cargoType = api.res.cargoTypeRep.find(cargoType) end
	local cargoTypeDetail = api.res.cargoTypeRep.get(cargoType)
	local icon = cargoTypeDetail.icon
	local iconView =  api.gui.comp.ImageView.new(icon)
	iconView:setTooltip(_(cargoTypeDetail.name))
	return iconView
end


function lineManager.buildLinePanel(circle, changeTabCallback)
 
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local button  = util.newButton(_('Check and update all lines'))
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, true, true, true)
	--boxlayout:addItem(button)
	local vehicleFilter = lineManager.buildVehicleFilterPanel() 
	button:onClick(function() 
	lineManager.addWork(function()
		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","checkLines", "", {carrier=vehicleFilter.getCarrier(), cargoFilter=vehicleFilter.getCargoFilter(), paramOverrides=paramOverridesChooser.customOptions}), lineManager.standardCallback)
	end)

	end)
	local railLines = {}
	
	local colHeaders = {
		api.gui.comp.TextView.new(_("Line")),
		api.gui.comp.TextView.new(_("Current\nrate")),
		api.gui.comp.TextView.new(_("Demand\nrate")),
		api.gui.comp.TextView.new(_("Cargo")),
		api.gui.comp.TextView.new(_("Top\nspeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
		api.gui.comp.TextView.new(_("Vehicles")),
		api.gui.comp.TextView.new(_("Interval")),
		api.gui.comp.TextView.new(_("Problems")),
		api.gui.comp.TextView.new(_("Recommendations")),
		api.gui.comp.TextView.new(_("Route\nUpgrades")),
		api.gui.comp.TextView.new(_("New vehicle config")),
		api.gui.comp.TextView.new(_("Execute")) 	
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	displayTable:setHeader(colHeaders)
	
	local function displayItems(items) 
		--trace("About to debugprint items")
		--debugPrint(items) 
		if util.size(items) == 0 then 
			return api.gui.comp.TextView.new(_("None")) 	
		end
		
		--trace("Adding text for display:",text)
		return api.gui.comp.TextView.new(buildNote(items)) 	
	end
	
	local function displayOldAndNewVehcileConfig(report)
		trace("Begin displayOldAndNewVehcileConfig")
		local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
		
		if report.currentVehicleConfig then 
			local topLine = api.gui.layout.BoxLayout.new("HORIZONTAL");
			topLine:addItem(api.gui.comp.TextView.new(_("Old:")))
			topLine:addItem(vehicleUtil.displayVehicleConfig(report.currentVehicleConfig))
			boxlayout:addItem(topLine)
		end
		local bottomLine = api.gui.layout.BoxLayout.new("HORIZONTAL");
	 
		if report.carrier == api.type.enum.Carrier.RAIL then 
			local button = util.newButton(_("New:")) --,"ui/icons/game-menu/help@2x.tga")
			bottomLine:addItem(button)
			button:onClick(function() 
				lineManager.addWork(function() 
					changeTabCallback(5, true)
				end)
				lineManager.addDelayedWork(function() 
					lineManager.lineDisplayTable.refresh(railLines, report.lineId)
 					lineManager.refreshVehicleTable(report.lineId)
				end)
			end)
			table.insert(railLines, report.lineId)
		else 
			bottomLine:addItem(api.gui.comp.TextView.new(_("New:")))
		end
		if not report.newVehicleConfig then report.newVehicleConfig = report.currentVehicleConfig end
		if report.newVehicleConfig then 
			bottomLine:addItem(vehicleUtil.displayVehicleConfig(report.newVehicleConfig))
		end
		boxlayout:addItem(bottomLine)
		local comp= api.gui.comp.Component.new(" ")
		comp:setLayout(boxlayout)
		trace("End displayOldAndNewVehcileConfig")
		return comp
	end
	
	boxlayout:addItem(vehicleFilter.panel)
	local noProblemsDisplay =  api.gui.comp.TextView.new(_("No problems found")) 	
	local maxReports = 10
	local function refreshTable()
		trace("Being refresh line manager table")
		profiler.beginFunction("Refresh line manager table")
		displayTable:deleteAll()
		for i = 1, #railLines do 
			table.remove(railLines)
		end 
		local reports = lineManager.getLinesReport(maxReports, circle, vehicleFilter.filterFn, paramOverridesChooser.customOptions)
		reports = util.evaluateAndSortFromScores(reports, {100},{ function(report) return 10 - util.size(report.recommendations) end})
		trace("lineManager.refreshTable: Got ",#reports," reports")
		local count = 0
		for i = 1, #reports do
			local report = reports[i]
			trace("Setting up the ",i,"th report. Was ok?",report.isOk)
			if report.isOk then 
				goto continue 
			end
			count = count + 1
			local executeButton = util.newButton("Execute", "ui/icons/build-control/accept@2x.tga")
			executeButton:setEnabled(#report.executionFns > 0)
			executeButton:onClick(function() 
				lineManager.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","checkAndUpdateLine", "", {lineId=report.lineId, paramOverrides=paramOverridesChooser.customOptions}), lineManager.standardCallback)
				end)
				executeButton:setEnabled(false)
			end)
			 
			displayTable:addRow({
				makelocateRow(report),
				api.gui.comp.TextView.new(tostring(math.floor(report.rate))),				
				api.gui.comp.TextView.new(tostring(math.floor(report.targetLineRate))),
				cargoTypeDisplay(report.cargoType),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.topSpeed)),
				textAndTooltipSpeed(report.averageSpeed, report.expectedAverageSpeed),
				api.gui.comp.TextView.new(tostring(report.existingVehicleCount)),
				api.gui.comp.TextView.new(formatTime(report.totalExistingTime/report.existingVehicleCount)),
				displayItems(report.problems) ,
				displayItems(report.recommendations) ,
				displayItems(report.upgrades) ,
				displayOldAndNewVehcileConfig(report),
				executeButton
			})
			if count >= maxReports then 
				break 
			end
			::continue::
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( count > 0, false)
		noProblemsDisplay:setVisible( count == 0, false)
		profiler.endFunction("Refresh line manager table")
		profiler.printResults()
	end
	 
	 
	displayTable:setVisible(false, false)
	boxlayout:addItem(displayTable)
	noProblemsDisplay:setVisible(false, false)
	boxlayout:addItem(noProblemsDisplay)
	
	
	local buttonLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	local button2  = util.newButton(_('Report problem lines'),"ui/button/xxsmall/replace@2x.tga")
	buttonLayout:addItem(button2)
	buttonLayout:addItem(paramOverridesChooser.button)
	local button3  = util.newButton(_('Show More'), "ui/button/xxsmall/down_thin@2x.tga")
	button2:onClick(function() 
		button3:setVisible(true, false)
		button:setVisible(true,false)
		lineManager.addWork(refreshTable)	
	end)

	buttonLayout:addItem(button3)
	button3:onClick(function() 
		maxReports = 2*maxReports
		lineManager.addWork(refreshTable)	
	end)
	button3:setVisible(false, false)
	buttonLayout:addItem(button)
	button:setVisible(false,false)
	boxlayout:addItem(buttonLayout)
	
	
	
-- textInput:setText()
 
	local comp= api.gui.comp.Component.new("AIBuilderBuildLinePanel")
	comp:setLayout(boxlayout)
	return {
		comp = comp,
		title = util.textAndIcon("LINES", "ui/icons/game-menu/linemanager@2x.tga"),
		refresh = function()
		
		end,
		init = function() end
	}
end


local function makeThroughPutPanel(report)
	local primaryText = (api.util.formatNumber(math.floor(report.vehicleCount*report.p.maxThroughput))) 
	
	local textView = api.gui.comp.TextView.new(primaryText)
	local secondaryText = _("Max revenue throughput").." "..(api.util.formatNumber(math.floor(report.vehicleCount*report.p.throughput))) 
	textView:setTooltip(secondaryText)
	return textView
	
end 
 

function lineManager.buildVehiclePanel(circle)
 
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, true, true)
	
	local lineDisplayLimit = 5
	local linesLookup = {}
	
	local refreshButton = util.newButton(_("Refresh"),"ui/button/xxsmall/replace@2x.tga")
 
	
	
	
 
	local colHeaders = {
		api.gui.comp.TextView.new(_("Vehicle Config")),
		api.gui.comp.TextView.new(_("newVehicleCount")),
		api.gui.comp.TextView.new(_("projectedTime")),
		api.gui.comp.TextView.new(_("topSpeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
		api.gui.comp.TextView.new(_("throughput")),
		--api.gui.comp.TextView.new(_("projectedPayment")),
		api.gui.comp.TextView.new(_("projectedTicketPrice")),
		api.gui.comp.TextView.new(_("projectedRevenue")), 
		api.gui.comp.TextView.new(_("runningCost")), 
		--api.gui.comp.TextView.new(_("projectedPaymentPerLoad")) ,
		api.gui.comp.TextView.new(_("projectedProfit")),
		api.gui.comp.TextView.new(_("replace"))				
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	displayTable:setHeader(colHeaders)
	
	local function displayItems(items) 
		trace("About to debugprint items")
		--debugPrint(items) 
		if util.size(items) == 0 then 
			return api.gui.comp.TextView.new(_("None")) 	
		end
		local text = ""
		for k,v in pairs(items) do 
			text = text.._(tostring(k))
			if type(v)~="boolean" then 
				text=text..": ".._(tostring(v))
			end
			text = text.."\n"
		end
		
		text = string.sub(text,1, -2)
		trace("Adding text for display:",text)
		return api.gui.comp.TextView.new(text) 	
	end
	 
	local header =  api.gui.comp.TextView.new(" ") 
	--boxlayout:addItem(lineInfoDisplay)
	local maxToReturn = 10
	local currentLineId
	local function refreshTable(lineId)
		--local lineIdx = lineCombobox:getCurrentIndex()
		--local lineId = linesLookup[lineIdx+1]
		if not lineId then 
			lineId = currentLineId
		else	
			currentLineId = lineId
		end 
		trace("Refreshing table to inspect lineId=",lineId, " lineIdx=",lineIdx)
		if not lineIdx then 
			debugPrint(linesLookup) 
		end
		--lineDisplayTable.refresh({lineId})
		displayTable:setVisible(true, false)
		trace("Being refresh line manager table")
		displayTable:deleteAll()
		local isForVehicleReport = true 
		local useRouteInfo = false 
		local displayOnly = false 
		local paramOverrides = paramOverridesChooser.customOptions
		local lineReport = lineManager.getLineReport(lineId, nil, isForVehicleReport, useRouteInfo, displayOnly, paramOverrides )
		--local lineReport = lineManager.getLineReport(lineId, nil, true)
		header:setText(_("Vehicle options for").." "..lineReport.lineName)
		
		local options = lineReport.newVehicleConfig
		-- Guard: vehicle config can be nil after a line was rebuilt/removed
		if not options then
			trace("lineManager refresh: no vehicle options for line " .. tostring(lineId) .. ", skipping")
			return
		end
		trace("Got ",#options," reports")
		local count = 0
		for i = 1, #options do
			local report = options[i] 
			if i == 1 then 
				--lineInfoDisplay:setText(_("Route length:")..api.util.formatLength(report.p.routeLength).." ".._("Throughput demand:")..api.util.formatNumber(math.round(lineReport.lineRate)).." ".._("Vehicle count:")..api.util.formatNumber(lineReport.vehicleCount))
			end 			
			count = count + 1
			local replaceButton = util.newButton(_("Replace"), "ui/icons/build-control/accept@2x.tga") 
			replaceButton:onClick(function() 
				lineManager.addWork(function() 
					--lineManager.replaceLineVehicles(lineId, report.config) 
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","replaceLineVehicles", "", {lineId=lineId, config=report.config, vehicleCount=report.vehicleCount}), lineManager.standardCallback)
				end)
				replaceButton:setEnabled(false)
				--lineManager.addDelayedWork(refreshTable)
			end)
			if not report.vehicleCount then 
				report.vehicleCount = lineReport.vehicleCount or lineReport.existingVehicleCount
			end
			if vehicleUtil.checkIfVehicleConfigMatches(lineReport.currentVehicleConfig, report.config) and report.vehicleCount == lineReport.existingVehicleCount then 
				replaceButton:setEnabled(false)
				replaceButton:setTooltip(_("This is the current line config"))
			end				
			
			displayTable:addRow({
				vehicleUtil.displayVehicleConfig(report.config),
				api.gui.comp.TextView.new(api.util.formatNumber(report.vehicleCount)),
				makeTimingsPanel(report.p.projectedTimings, report.p.projectedTimingsRaw, report.p.projectedLoadTime),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.p.topSpeed)),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.p.averageSpeed)),
				--api.gui.comp.TextView.new(api.util.formatMoney(math.round(report.p.projectedPayment))),
				makeThroughPutPanel(report),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.p.projectedTicketPrice))),	
				makeProjectedRevenuePanel(report),				
		
				makeProjectedCostsPanel(report),
				
				--api.gui.comp.TextView.new(api.util.formatMoney(math.round(report.p.projectedPaymentPerLoad))) ,
				makeProjectedProfitPanel(report),
				replaceButton
			})
			if count > maxToReturn then 	
				break 
			end
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( count > 0, false)
		 
	end 
	local lineDisplayTable = lineManager.buildLineDisplayTable(refreshTable) 
	
	local function refreshCombobox() 
		local allLines =  getLines(circle) 
		for k,v in pairs(linesLookup) do linesLookup[k]=nil end
	 
		local count = 0
		for i, lineId in pairs(allLines) do 
			
			local line = util.getComponent(lineId, api.type.ComponentType.LINE)
			if isRailLine(line) or true then 
				count = count + 1
				local name = util.getComponent(lineId, api.type.ComponentType.NAME).name
			 
				table.insert(linesLookup, lineId)
				if count >= 5 then 
					break 
				end
			end
		end
		lineDisplayTable.refresh(linesLookup)
	end
	 

	refreshButton:onClick(function() lineManager.addWork(refreshCombobox)end)
	 
	 
	lineManager.refreshVehicleTable = refreshTable
	lineManager.lineDisplayTable = lineDisplayTable
	displayTable:setVisible(false, false)
	
	
	boxlayout:addItem(lineDisplayTable.displayTable)
	local buttonLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	buttonLayout:addItem(refreshButton)

	buttonLayout:addItem(paramOverridesChooser.button)
	boxlayout:addItem(buttonLayout)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxlayout:addItem(header)
	boxlayout:addItem(displayTable)
	 
	
	 
	local showMoreButton  = util.newButton(_('Show more'), "ui/button/xxsmall/down_thin@2x.tga")
	local clearButton  = util.newButton(_('Clear'), "ui/button/small/cancel@2x.tga")
	local buttonLayout2 = api.gui.layout.BoxLayout.new("HORIZONTAL");
	buttonLayout2:addItem(showMoreButton)
	buttonLayout2:addItem(clearButton)
	boxlayout:addItem(buttonLayout2)
	showMoreButton:onClick(function() 
		maxToReturn = maxToReturn * 2
		lineManager.addWork(refreshTable)	
	end)
	
	clearButton:onClick(function() 
		maxToReturn = 10
		lineManager.addWork(function() -- nested for error handling
			displayTable:setVisible(false, false) 
			displayTable:deleteAll()
		end)
	end)
	
	
	
-- textInput:setText()
 
	local comp= api.gui.comp.Component.new("AIBuilderBuildLinePanel")
	comp:setLayout(boxlayout)
	local isInit = false
	return {
		comp = comp,
		title = util.textAndIcon("VEHICLES", "ui/icons/game-menu/vehiclemanager@2x.tga"),
		refresh = function()
			isInit = false 
		end,
		init = function() 
			if not isInit then 
				refreshCombobox()
				isInit = true 
			end
		
		end
	}
end

return lineManager