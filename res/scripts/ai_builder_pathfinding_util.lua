local util = require("ai_builder_base_util")
local transf = require("transf")
local vec3 = require("vec3")
local vec2 = require("vec2")
local paramHelper = require("ai_builder_base_param_helper") 
local waterMeshUtil = require "ai_builder_water_mesh_util"
local pathFindingUtil = {}

local trace=util.trace

local getLine = util.getLine
local stationFromStop = util.stationFromStop
local function isLineType(line, enum)
	return line.vehicleInfo.transportModes[enum+1]==1 
end

local function isElectricRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.ELECTRIC_TRAIN)
end

local function isRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.TRAIN) or isElectricRailLine(line)
end
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


pathFindingUtil.getWaterMeshGroups = waterMeshUtil.getWaterMeshGroups
local function getStation(stationId) 
	local station = util.getStation(stationId)
	if not station then -- tolerate being given a constuction id instead, this is what we are given after a result 
		local construction = util.getConstruction(stationId)
		if construction and construction.stations[1] then 
			return util.getStation(construction.stations[1])
		end 	
		trace("WARNING! No station found for ",stationId)
	end 
	 
	return station
end 

function pathFindingUtil.getStartingEdgesForEdge(edgeId, transportMode) 
	local startingEdges = {}
	if transportMode == api.type.enum.TransportMode.TRAIN then -- performance shortcut , train edges only have one tn edge
		local fullEdgeId = api.type.EdgeId.new(edgeId, 0)
		table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, true, 0))
		table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, false, 0))
		return startingEdges
	end 
	
	local tn = util.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
	if not tn then 
		error("No transport network provided for "..tostring(edgeId))
	end 
	local tnEdges = tn.edges -- trying to prevent premature gc
	for i, tn in pairs(tnEdges) do
		if tn.transportModes[transportMode+1]==1 then
			local fullEdgeId = api.type.EdgeId.new(edgeId, i-1)
			table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, true, 0))
			table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, false, 0))
			 
			--break -- hmm do we need this
		end
	end
	return startingEdges
end

local function getStartingEdgesForStation(stationId, terminal)
	if terminal then 
		return pathFindingUtil.getStartingEdgesForStationAndTerminal(stationId, terminal)
	end

	local startingEdges = {} 
	local found = false
	local station = getStation(stationId)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then
		constructionId = stationId
	end
	trace("About to get frozenEdges for construction ",constructionId)
	local construction = util.getConstruction(constructionId)
	if not construction and game.interface.getEntity(constructionId).type == "BASE_NODE" then 
		return pathFindingUtil.getStartingEdgesForEdge(util.getTrackSegmentsForNode(constructionId)[1], api.type.enum.TransportMode.TRAIN)
	end 
	
	for ___, edgeId in pairs(construction.frozenEdges) do  
		for i, startingEdge in pairs(pathFindingUtil.getStartingEdgesForEdge(edgeId, api.type.enum.TransportMode.TRAIN)) do
			table.insert(startingEdges, startingEdge)
			found = true
		end
		--if found then break end
	end
	return startingEdges 
end
pathFindingUtil.getStartingEdgesForStation = getStartingEdgesForStation

function pathFindingUtil.getDestinationNodesForNode(node, transportMode)
	local edge = node -- works for road nodes as they have a transport network comp. EDIT: actually only true for an intersection or mismatched tangent on two segments
	if transportMode == api.type.enum.TransportMode.TRAIN then 
		edge = util.getTrackSegmentsForNode(node)[1]
	end 
	return pathFindingUtil.getDestinationNodesForEdge(edge, transportMode, node)
end

function pathFindingUtil.getDestinationNodesForEdge(edge, transportMode, targetNode)
	local destNodes = {}
	if not targetNode then 
		targetNode = util.getEdge(edge).node0 
	end
	local tn = util.getComponent(edge, api.type.ComponentType.TRANSPORT_NETWORK)
	local tnEdges = tn.edges -- trying to encourage this not to be gc'd half way through
	local found = false
	for i, tn in pairs(tnEdges) do
		if tn.transportModes[transportMode+1]==1 then
			if targetNode == tn.conns[1].entity then
				found = true
				table.insert(destNodes, api.type.NodeId.new(tn.conns[1].entity, tn.conns[1].index))
			end
			if targetNode == tn.conns[2].entity then
				found = true
				table.insert(destNodes, api.type.NodeId.new(tn.conns[2].entity, tn.conns[2].index))
			end
			
			--if found then break end
		end
	end
	if not found and edge==targetNode then 
		trace("No destination nodes found, attempting using edge")
		return pathFindingUtil.getDestinationNodesForEdge(util.getSegmentsForNode(edge)[1], transportMode, targetNode)
	end 
	return destNodes
end

local function copyNode(terminal) -- this is required to prevent the object being garbage collected , we have to own it explicitly
	return  api.type.NodeId.new(terminal.vehicleNodeId.entity, terminal.vehicleNodeId.index)
end 


function pathFindingUtil.getDestinationNodesForStationAndTerminal(stationId, terminal)

	local station = getStation(stationId)
	local terminalComp = station.terminals[terminal+1]
	if not terminalComp then 
		debugPrint({station=station,stationId=stationId,terminal=terminal})
	end 
	local res = { copyNode(terminalComp)} -- slight superstition about falling out of scope too early
	return res
end

 
function pathFindingUtil.getDestinationNodesForStation(stationId, terminal)
	if terminal then 
		return pathFindingUtil.getDestinationNodesForStationAndTerminal(stationId, terminal)
	end
	local destNodes = {}
	local station = getStation(stationId)
	for i, terminal in pairs(station.terminals) do 
		--table.insert(destNodes, terminal.vehicleNodeId) -- NB can't do this it gets gc'd
		table.insert(destNodes, copyNode(terminal))
	end
	
	return destNodes
	--[[local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then
		constructionId = stationId
	end
	for ___, edge in pairs(util.getConstruction(constructionId).frozenEdges) do  
		for i, destNode in pairs(getDestinationNodesForEdge(edge, api.type.enum.TransportMode.TRAIN)) do
			table.insert(destNodes, destNode)
		end
		--if found then break end
	end
	return destNodes]]--
end

function pathFindingUtil.findRailPathBetweenStationTerminalAndEdge(station, terminal, edge)
	local startingEdges =    getStartingEdgesForStation(station, terminal)
	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	local destNodes = pathFindingUtil.getDestinationNodesForEdge(edge,  api.type.enum.TransportMode.TRAIN)
	local maxDistance = 3 * util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	return pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
end

function pathFindingUtil.findRailPathBetweenEdgeAndStationTerminal(edge,station, terminal )
	local startingEdges =   pathFindingUtil.getStartingEdgesForEdge(edge,  api.type.enum.TransportMode.TRAIN)
	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	local destNodes = pathFindingUtil.getDestinationNodesForStationAndTerminal(station, terminal )
	local maxDistance = 3 * util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	return pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
end

function pathFindingUtil.findRailPathBetweenStations(station1, station2,   terminal1, terminal2,maxDistance)
	--collectgarbage()
	if not maxDistance then
		maxDistance = 3* util.distBetweenStations(station1, station2) 
	end
	
	local startingEdges
	if not pcall(function() startingEdges =  getStartingEdgesForStation(station1, terminal1) end) then 
		trace("getStartingEdgesForStation: Initial call failed, attempting with clearing cached")
		util.clearCacheNode2SegMaps()
		startingEdges =  getStartingEdgesForStation(station1, terminal1)
	end 
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2, terminal2)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	trace("Attempting to find rail path between stations ", station1, station2)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	--debugPrint(answer)
	return answer
end

function pathFindingUtil.checkForRailPathBetweenStationFreeTerminals(station1, station2) 
	trace("checkForRailPathBetweenStationFreeTerminals begin:",station1, station2)
	for i, t in pairs(util.getFreeTerminals(station1)) do 
		for j, t2 in pairs(util.getFreeTerminals(station2)) do 
			local terminal1 = t -1 
			local terminal2 = t2 - 1
			local foundPath =#pathFindingUtil.findRailPathBetweenStations(station1, station2, t-1, t2-1) > 0
			trace("checkForRailPathBetweenStationFreeTerminals:",station1, station2, terminal1, terminal2, "foundPath?",foundPath)
			if foundPath then 
				return true 
			end 
		end 
	end 
	trace("checkForRailPathBetweenStationFreeTerminals no path found:",station1, station2)
	return false
end 

function pathFindingUtil.findRailPathBetweenEdgeAndStationFreeTerminal(edge, station, tryDoubleTrackEdge) 
	local maxDistance = 3* util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	local startingEdges =  pathFindingUtil.getStartingEdgesForEdge(edge, api.type.enum.TransportMode.TRAIN)
	
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	trace("Attempting to find rail path between edge and station", edge, station)
	local answer = {}
	for i, t in pairs(util.getFreeTerminals(station)) do 
		local destNodes = pathFindingUtil.getDestinationNodesForStationAndTerminal(station, t-1)
		if #destNodes>0 and #startingEdges>0 then 
			--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
			answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
		end
		if #answer > 0 then 
			return answer 
		end
		if tryDoubleTrackEdge then 
			local doubleTrackEdge = util.findDoubleTrackEdge(edge)
			if doubleTrackEdge then 
				local startingEdges =  pathFindingUtil.getStartingEdgesForEdge(doubleTrackEdge, api.type.enum.TransportMode.TRAIN)
				answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
				if #answer > 0 then 
					return answer 
				end
			end 
		
		end 
	end
	--[[
	if #answer == 0 then 
		local constructionId  = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) 
		local edgeFull = util.getEdge(edge)
		for i, node in pairs(util.getFreeNodesForConstruction(constructionId)) do
			if node == edgeFull.node0 or node == edgeFull.node1 then 
				trace("Original path answer was empty, but edge is connected directly to station, returning edge")
				return {{entity=edge, index = 0}}
			end
		end 
	end ]]--
	
	--debugPrint(answer)
	return answer
	
end
function pathFindingUtil.findRailPathBetweenNodeAndStation(node, station, maxDistance, tryDoubleTrackEdge)
	return pathFindingUtil.findRailPathBetweenEdgeAndStation(util.getTrackSegmentsForNode(node)[1], station, maxDistance, tryDoubleTrackEdge)
end

function pathFindingUtil.findRailPathBetweenStationAndEdge(edge, station, maxDistance )
	if not maxDistance then
		maxDistance = 3* util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	end
	
	local startingEdges = pathFindingUtil.getStartingEdgesForStation(station)
	local destNodes = pathFindingUtil.getDestinationNodesForEdge(edge, api.type.enum.TransportMode.TRAIN)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	--trace("Attempting to find rail path between station and station", station1, station2)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	return answer
	
end 

function pathFindingUtil.findRailPathBetweenEdgeAndStation(edge, station, maxDistance, tryDoubleTrackEdge)
	--collectgarbage()
		if not maxDistance then
		maxDistance = 3* util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	end
	
	local startingEdges =  pathFindingUtil.getStartingEdgesForEdge(edge, api.type.enum.TransportMode.TRAIN)
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	trace("Attempting to find rail path between edge and station", edge, station)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
		if #answer == 0 and tryDoubleTrackEdge then 
			local doubleTrackEdge = util.findDoubleTrackEdge(edge) 
			if doubleTrackEdge then 
				answer = pathFindingUtil.findPath( pathFindingUtil.getStartingEdgesForEdge(doubleTrackEdge, api.type.enum.TransportMode.TRAIN) , destNodes, transportModes, maxDistance)
			end 
		end 
	end
	--[[
	if #answer == 0 then 
		local constructionId  = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) 
		local edgeFull = util.getEdge(edge)
		for i, node in pairs(util.getFreeNodesForConstruction(constructionId)) do
			if node == edgeFull.node0 or node == edgeFull.node1 then 
				trace("Original path answer was empty, but edge is connected directly to station, returning edge")
				return {{entity=edge, index = 0}}
			end
		end 
	end ]]--
	
	--debugPrint(answer)
	return answer
	
end
 

local function getClosestEdge(node1, node2, isTrack)
	local segmentFn = isTrack and util.getTrackSegmentsForNode or util.getStreetSegmentsForNode
	local options = {}
	local isValid1 = api.engine.entityExists(node1)
	local isValid2 = api.engine.entityExists(node2)
	if not isValid1 or not isValid2 then 
		error("Invalid entity found, node1="..tostring(node1).." node2="..tostring(node2).." isValid1? "..tostring(isValid1).." isValid2? "..tostring(isValid2))
	end 
	if not segmentFn(node1) and util.getEdge(node1) then -- tolerate being passed a node instead of edge, this can happen because the transport network links can have both	 
		return node1 
	end
	
	local otherNodePos = segmentFn(node2) and util.nodePos(node2) or util.getEdgeMidPoint(node2)
	for __, seg in pairs(segmentFn(node1)) do 
		table.insert(options, { 
			seg = seg, 
			scores = { util.distance(otherNodePos, util.getEdgeMidPoint(seg)) } 				
		})
	end 
	if #options == 0 then 
		trace("WARNING! no options found at ",node1,"the size of segmentFn was",#segmentFn(node1))
	end 	
	return util.evaluateWinnerFromScores(options).seg
end 

function pathFindingUtil.findRailPathBetweenNodes(node1, node2, maxDistance)
	if not node1 or not node2 then 
		return {}
	end

	return pathFindingUtil.findRailPathBetweenEdges(getClosestEdge(node1, node2, true) , getClosestEdge(node2, node1, true) , maxDistance, node2)
end 

function pathFindingUtil.getRailRouteInfoBetweenNodesIncludingReversed(node1, node2, maxDistance)
	local answer =pathFindingUtil.findRailPathBetweenNodes(node1, node2, maxDistance)
	if #answer == 0 then 
		answer = pathFindingUtil.findRailPathBetweenNodes(node2, node1, maxDistance)
	end 
	return pathFindingUtil.getRouteInfoFromEdges(answer)
end
	
function pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node1, node2, maxDistance, forbidRecurse)
	if not node1 or not node2 then 
		return {}
	end
	local answer =  pathFindingUtil.findRailPathBetweenNodes(node1, node2)
	if #answer > 0 then 
		return answer 
	end
	answer =  pathFindingUtil.findRailPathBetweenNodes(util.findDoubleTrackNode(node1), node2)
	if #answer > 0 then 
		return answer 
	end
	answer =  pathFindingUtil.findRailPathBetweenNodes(node1, util.findDoubleTrackNode(node2))
	if #answer > 0 then 
		return answer 
	end
	
	answer =  pathFindingUtil.findRailPathBetweenNodes(util.findDoubleTrackNode(node1), util.findDoubleTrackNode(node2))
	if #answer > 0 then 
		return answer 
	end
	if not forbidRecurse then 
		pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node2, node1, maxDistance, true)
	end
	return answer
end 

function pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge1, edge2, maxDistance, forbidRecurse) 
	if not edge1 or not edge2 then 
		return {}
	end
	local answer =  pathFindingUtil.findRailPathBetweenEdges(edge1, edge2, maxDistance)
	if #answer > 0 then 
		return answer 
	end
	local doubleTrackEdge1 = util.findDoubleTrackEdge(edge1)
	local doubleTrackEdge2 = util.findDoubleTrackEdge(edge2)
	if doubleTrackEdge1 then 
		answer =  pathFindingUtil.findRailPathBetweenEdges(doubleTrackEdge1, edge2, maxDistance)
	end 
	if #answer > 0 then 
		return answer 
	end
	if doubleTrackEdge2 then 
		answer =  pathFindingUtil.findRailPathBetweenEdges(edge1, doubleTrackEdge2, maxDistance)
	end
	if #answer > 0 then 
		return answer 
	end
	if doubleTrackEdge1 and doubleTrackEdge2 then 
		answer =  pathFindingUtil.findRailPathBetweenEdges(doubleTrackEdge1, doubleTrackEdge2, maxDistance)
	end
	if #answer > 0 then 
		return answer 
	end
	if not forbidRecurse then 
		--trace("Dropping into finding path between ",edge2,edge1, " maxDistance=",maxDistance)
		return pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge2, edge1, maxDistance, true) 
	end
	return answer

end

function pathFindingUtil.cacheDestinationEdgesAndNodes() 
	pathFindingUtil.destNodesByEdge = {} 
	pathFindingUtil.startingEdgesByEdge = {}
end 
function pathFindingUtil.clearCaches() 
	pathFindingUtil.destNodesByEdge = nil
	pathFindingUtil.startingEdgesByEdge = nil
end 
function pathFindingUtil.findRailPathBetweenEdges(edge1, edge2, maxDistance, useNode)
	----collectgarbage()
	if not maxDistance then
		maxDistance = 3* util.distance(util.getEdgeMidPoint(edge1), util.getEdgeMidPoint(edge2))
	end
	
	local startingEdges
	if startingEdgesByEdge and startingEdgesByEdge[edge1] then  
		startingEdges  =  startingEdgesByEdge[edge1] 
	else 
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(edge1, api.type.enum.TransportMode.TRAIN)
		if startingEdgesByEdge then 
			startingEdgesByEdge[edge1]=startingEdges
		end
	end 
	local destNodes 
	if destNodesByEdge and destNodesByEdge[edge2] then  
		destNodes  =  destNodesByEdge[edge2] 
	else 
		if not useNode then useNode = util.getEdge(edge2).node0 end
		destNodes =  {api.type.NodeId.new(useNode, 0 )}
		if destNodesByEdge then 
			destNodesByEdge[edge2]=destNodes
		end
	end

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	 
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	--trace("Attempting to find rail path between edge and edge", edge1, edge2, " answer found? ",#answer)
	if #answer > 0 then 
		if  answer[#answer].entity ~= edge2 then 
			trace("Inserting edge2 into the answer")
			table.insert(answer, { entity = edge2, index = 0 })
		else 
			trace("Edge 2 was found")
		end 		
	end 
	--debugPrint(answer)
	return answer
	
end
function pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(station1, station1Terminal, station2)
	local answer = pathFindingUtil.findRailPathBetweenTerminalAndStation(station1, station1Terminal, station2)
	if #answer > 0 then 
		return pathFindingUtil.getRouteInfoFromEdges(answer)
	end
end
function pathFindingUtil.getStartingEdgesForStationAndTerminal(station, terminal)
	local stationFull = getStation(station)
	local vehicleNodeId = stationFull.terminals[terminal+1].vehicleNodeId
	local edgeId = util.getTrackSegmentsForNode(vehicleNodeId.entity)[1]
	return {
		-- NB tracks only have one transport network for the rail path, the edge index is always zero
		api.type.EdgeIdDirAndLength.new(api.type.EdgeId.new(edgeId, 0), true, 0),
		api.type.EdgeIdDirAndLength.new(api.type.EdgeId.new(edgeId, 0), false, 0)
		} 
end
function pathFindingUtil.findRailPathBetweenTerminalAndStation(station1, station1Terminal, station2)
	--collectgarbage()
	local maxDistance = 3* util.distBetweenStations(station1, station2)
	
	local startingEdges = pathFindingUtil.getStartingEdgesForStationAndTerminal(station1, station1Terminal)
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	--trace("Attempting to find rail path between station and station", station1, station2)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	return answer
end

function pathFindingUtil.checkForRailPathBetweenTerminalAndStation(station1, station1Terminal, station2)

	return #pathFindingUtil.findRailPathBetweenTerminalAndStation(station1, station1Terminal, station2) >0
end


function pathFindingUtil.getRoadRouteInfoBetweenTowns(town1, town2)
	local node1 = util.findMostCentralTownNode(town1).id
	local node2 = util.findMostCentralTownNode(town2).id
	local maxDist = 2000+3*util.distBetweenNodes(node1,node2)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node1, node2, maxDist ))
end 
 
pathFindingUtil.findWaterPathDistanceBetweenMeshes = waterMeshUtil.findWaterPathDistanceBetweenMeshes
 

local function getVertexForStation(stationId) 
	local p = util.getStationPosition(stationId)
	return util.getClosestWaterVerticies(p)[1]
end 

pathFindingUtil.getVertexForStation = getVertexForStation

local function getVertexForConstruction(constructionId) 
	local p = util.getConstructionPosition(constructionId)
	return util.getClosestWaterVerticies(p)[1]
end 


function pathFindingUtil.checkConstructionsShareWaterMesh(construction1, construction2) 
	local v1 = getVertexForConstruction(construction1)
	local v2 = getVertexForConstruction(construction2)
	local meshGroups = pathFindingUtil.getWaterMeshGroups()
	local group1 = meshGroups[v1.mesh]
	local group2 = meshGroups[v2.mesh]
	local result = group1 == group2
	trace("Checking if constructions are on same water mesh",construction1, construction2, "meshes were",v1.mesh, v2.mesh," groups were",group1,group2," are connected?",result)
	return result and { construction1, construction2 } or {} -- can't directly return boolean as callers are expecting table
end 

function pathFindingUtil.estimateShipDistanceForStations(station1, station2) 
	local v1 = getVertexForStation(station1)
	local v2 = getVertexForStation(station2)
 
	return pathFindingUtil.findWaterPathDistanceBetweenMeshes(v1.mesh, v2.mesh) 
end 


function pathFindingUtil.validateShipPath(station1, station2)
	if util.getConstruction(station1) then 
		station1 =  util.getConstruction(station1).stations[1]
	end 
	if util.getConstruction(station2) then 
		station2 =  util.getConstruction(station2).stations[1]
	end 
	local meshGroups = pathFindingUtil.getWaterMeshGroups() 
	
	return meshGroups[getVertexForStation(station1)] == meshGroups[getVertexForStation(station2)]
	
	-- NB the api call seems to be unreliable
	--[[local distance = util.distBetweenStations(station1, station2)
	local maxDist = distance*paramHelper.getParams().shipRouteToDistanceLimit
	local station1Full = util.getComponent(station1, api.type.ComponentType.STATION)
	local station1Node = station1Full.terminals[1].vehicleNodeId
	local startingEdge = api.type.EdgeId.new(station1Node.entity, station1Node.index)
	local statingEdgesAndId = { api.type.EdgeIdDirAndLength.new(startingEdge, true, 0)} 
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2)
	local transportModes = { api.type.enum.TransportMode.SMALL_SHIP }
	local answer = pathFindingUtil.findPath( statingEdgesAndId , destNodes, transportModes, maxDist)
	trace("The ship path between ", station1, " and ", station2, " had ",#answer," results")
	return #answer > 0]]--
end
function pathFindingUtil.findRoadPathBetweenEdges(edge1, edge2, preferredNode, maxDistance)
	--trace("Getting startingEdges  for ",edge1)
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(edge1,  api.type.enum.TransportMode.BUS)
	--trace("Getting destination nodes for",edge2)
	local fullEdge2 = util.getEdge(edge2) 
	local targetNode = preferredNode 
	if not targetNode then 
		local startEdgePos = util.getEdgeMidPoint(edge1)
		if vec2.distance(util.nodePos(fullEdge2.node0), startEdgePos) > vec2.distance(util.nodePos(fullEdge2.node1), startEdgePos) and not util.isOneWayStreet(edge2) then 
			targetNode = fullEdge2.node0
		else 
			targetNode = fullEdge2.node1
		end
	end
	local destNodes 
	if preferredNode then 
		destNodes = pathFindingUtil.getDestinationNodesForNode(preferredNode, api.type.enum.TransportMode.BUS) -- always use bus not car because it can accept bus lanes
	else 
		destNodes = pathFindingUtil.getDestinationNodesForEdge(edge2,  api.type.enum.TransportMode.BUS, targetNode)
	end 
	maxDistance = maxDistance or pathFindingUtil.calculateMaxRoadDistance(util.getEdgeMidPoint(edge1), util.getEdgeMidPoint(edge2))
	local transportModes = {   api.type.enum.TransportMode.BUS} 
	--trace("Attempting to find path between edges ", edge1," and ",edge2)
	
	return pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
end

function pathFindingUtil.findRoadPathBetweenNodes(node1, node2, maxDistance)
	local edge1 = getClosestEdge(node1, node2, false)  
	local edge2 = getClosestEdge(node2, node1, false)
	trace("findRoadPathBetweenNodes: falling to findRoadPathBetweenEdges",edge1,edge2)
	local answer =  pathFindingUtil.findRoadPathBetweenEdges(edge1, edge2, node2, maxDistance)
	if #answer > 0 then 
		local edge
		for i = #answer, 1 , -1 do 
			local lastEdge = answer[i] 
			edge = util.getEdge(lastEdge.entity)
			if edge then 
				break
			else
				trace("No edge found for ",lastEdge.entity," index=",lastEdge.index," at ",i, " of ",#answer)
			end
		end
		if not edge then 
			trace("Route appears to ccontain no edges!") 
			return answer
		end
		if edge.node0 ~= node2 and edge.node1 ~= node2 then 
			trace("attempting to find last edge for path")
			local newAnswer = {} -- need to copy it out into a lua table 
			for i , entity in pairs(answer) do 
				table.insert(newAnswer, entity)
			end
			local found = false
			for i, nextSeg in pairs(util.getStreetSegmentsForNode(edge.node0)) do 
				local nextEdge = util.getEdge(nextSeg)
				if nextEdge.node0 == node2 or nextEdge.node1 == node2 then 
					table.insert(newAnswer, {entity=nextSeg} ) 
					found = true 
					break
				end
			end
			if not found then 
				for i, nextSeg in pairs(util.getStreetSegmentsForNode(edge.node1)) do 
					local nextEdge = util.getEdge(nextSeg)
					if nextEdge.node0 == node2 or nextEdge.node1 == node2 then 
						table.insert(newAnswer, {entity=nextSeg} ) 
						found = true 
						break
					end
				end
			end
			if not found then 
				trace("Failed to find the last edge for node ",node2)
			else 
				trace("Found and added the last edge for node ",node2)
			end
			return newAnswer
		end
	end
	
	return answer
end

local function findStreetEdgeForStation(station)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	if constructionId ~= -1 then 
		return util.getConstruction(constructionId).frozenEdges[1]
	end
	local stationFull =  getStation(station) 
	local entity = stationFull.terminals[1].vehicleNodeId.entity
	if not util.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK) then 
		trace("WARNING! No streetnetwork found at ",entity,"for station",station,"attempting cache refresh")
		util.clearCacheNode2SegMaps() -- the game can change the street edges under us while changing era
		stationFull =  getStation(station) 
		entity = stationFull.terminals[1].vehicleNodeId.entity
	end 
	return  entity
end
function pathFindingUtil.findRoadPathBetweenStationAndNode(station, node, nodePos )
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station)
	if (not api.engine.entityExists(node) or not util.getComponent(node, api.type.ComponentType.BASE_NODE)) and nodePos then 
		trace("Node",node," no longer existists attempting to use position")
		node = util.searchForNearestNode(nodePos, 50) 
		if not node then return {} end 
		node = node.id
		trace("Using node ",node)
		debugPrint({segmentsForNode=util.getSegmentsForNode(node)})
	end
	
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(util.getSegmentsForNode(node)[1],  api.type.enum.TransportMode.CAR)
	--local destNodes = getDestinationNodesForEdge(edge2)
	local maxDistance = pathFindingUtil.calculateMaxRoadDistance(util.nodePos(node), util.getStationPosition(station))
	local transportModes = {   api.type.enum.TransportMode.TRUCK ,api.type.enum.TransportMode.BUS} 
	--trace("Attempting to find path between edges ", edge1," and ",edge2)
	local answer=  pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	--trace("There were ",#answer," edges")
	return answer
end

function pathFindingUtil.calculateMaxRoadDistance(p0, p1) 
	local initialDist = 500 + paramHelper.getParams().truckRouteToDistanceLimit*util.distance(p0, p1)
	local minGradientDist = 500+math.abs(p0.z-p1.z)/math.min(0.1, paramHelper.getParams().maxGradientRoad)
	local res= math.max(initialDist, minGradientDist)
	trace("Calculated maximum road distance as ",res, "between",p0.x,p0.y," and ",p1.x,p1.y, " minGradientDist=",minGradientDist, " initialDist=",initialDist)
	return res
end 

function pathFindingUtil.findRoadPathStations(station1, station2, isTram, maxDist)
	assert(station1~=nil)
	assert(station2~=nil)
	local edge1 = findStreetEdgeForStation(station1)
	local edge2 = findStreetEdgeForStation(station2)
	trace("Getting starting edges and destination nodes for",edge1,edge2, " from stations",station1, station2," maxDist=",maxDist)
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(edge1,  api.type.enum.TransportMode.BUS)

	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2)
	--local destNodes = getDestinationNodesForEdge(edge2)
	local maxDistance = maxDist or pathFindingUtil.calculateMaxRoadDistance(util.getStationPosition(station1), util.getStationPosition(station2)) 
	local transportModes = {   api.type.enum.TransportMode.CAR, api.type.enum.TransportMode.TRUCK ,api.type.enum.TransportMode.BUS} 
	if isTram then 
		transportModes = { api.type.enum.TransportMode.TRAM} 
	end
	
	--trace("Attempting to find path between edges ", edge1," and ",edge2)
	local answer=  pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	--trace("There were ",#answer," edges")
	return answer
end
function pathFindingUtil.findRoadPathFromDepotToStationAndTerminal(nearbyDepot, stationId, terminal)
	local depotEntity = util.getConstruction(nearbyDepot).depots[1]
	local transportModes = {  api.type.enum.TransportMode.TRUCK ,api.type.enum.TransportMode.BUS} 
	return pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, stationId, terminal)
end
function pathFindingUtil.getRouteInfoForRoadPathBetweenStationAndNode(station, node)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenStationAndNode(station, node))
end 
function pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(node1, node2)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node1, node2))
end
function pathFindingUtil.getRouteInfoForRailPathBetweenEdges(edge1, edge2)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdges(edge1, edge2))
end

function pathFindingUtil.validateHighwayPathFromNodes(node1, node2) 
	local node1other = util.findParallelHighwayNode(node1)
	local node2other = util.findParallelHighwayNode(node2)
	if not node1other or not node2other then 
		trace("Could not find parallel node",node1other, node2other)
		return false 
	end 
	
	local fromNode1 = util.getDeadEndNodeDetails(node1).isNode0 and node1 or node1other
	local toNode2 = util.getDeadEndNodeDetails(node2).isNode0 and node2other or node2 
	
	local toNode1 = fromNode1 == node1 and node1other or node1
	local fromNode2 = toNode2 == node2 and node2other or node2 
	
	trace("Checking for path between",fromNode1," to ",toNode2," and ",fromNode2," to ",toNode1)
	return #pathFindingUtil.findRoadPathBetweenNodes(fromNode1, toNode2) > 0 and #pathFindingUtil.findRoadPathBetweenNodes(fromNode2, toNode1) > 0
end 

function pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2, isTram, maxDist)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathStations(station1, station2, isTram, maxDist))
end

local function trytoFindUnconnectedTerminalNode(edgeId)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
	if constructionId == -1 then
		trace("Warning, the construcitonId was unexpectedly -1 for edge ",edgeId)
		return
	end
	local edge = util.getEdge(edgeId)
	local searchNode = util.isFrozenNode(edge.node0) and edge.node1 or edge.node0
	
	local result =  util.findNearestAdjacentUnconnectedFreeNode(constructionId, searchNode)
	trace("Search node for unconnectedTerminalNode was ",searchNode, " constructionId=",constructionId, " result=",result)
	if result and util.distBetweenNodes(searchNode, result) > 16 then 
		trace("Ignoring the result as the distance is too high",util.distBetweenNodes(searchNode, result))
		return
	end 
	return result
end

function pathFindingUtil.getGradientRouteSectionsFromEdges(edges, edgesAndIds, firstFreeEdge, lastFreeEdge)
	local routeSections = {} 
	local currentRouteSection
	local currentRouteSectionDist = 0
	local previousGradientCategory 
	local maxGradient = paramHelper.getParams().maxGradientTrack
	local gradientCategoryFn = function(gradient) -- group the sections by rising, falling or roughly flat
		if gradient > maxGradient/2 then 
			return 1 
		end
		if gradient < -maxGradient/2 then
			return -1
		end
		return 0
	end
	if not firstFreeEdge then 	
		firstFreeEdge = 1 
	end 
	if not lastFreeEdge then 
		lastFreeEdge = #edges 
	end 
	for i =1, #edges do
		local edge = edges[i]
		local gradient = util.calculateEdgeGradient(edge)
		local shouldReverse = false 
		if i > 1 then 
			local priorEdge = edges[i-1]
			shouldReverse = edge.node1 == priorEdge.node0 or edge.node1 == priorEdge.node1
		elseif i < #edges then 
			local nextEdge = edges[i+1]
			shouldReverse = edge.node0 == nextEdge.node0 or edge.node0 == nextEdge.node1
		end 
		if shouldReverse then 
			gradient = -gradient
		end 
		local gradientCategory = gradientCategoryFn(gradient)
		local length = util.calculateSegmentLengthFromEdge(edge)
		--if i == 1 or gradientCategory ~= previousGradientCategory or true then 
		local addNewRouteSection = i%3 ==0 or i == firstFreeEdge or i == lastFreeEdge
		if i == 1 then 
			addNewRouteSection = true 
		elseif i < firstFreeEdge then 
			addNewRouteSection = false 
		elseif i > lastFreeEdge then 
			addNewRouteSection = false 
		end 	
		if not addNewRouteSection and math.abs(routeSections[currentRouteSection].speedLimit-edgesAndIds[i].speedLimit)>1 then 
			addNewRouteSection = true 
		end 
		if addNewRouteSection then 
			table.insert(routeSections, {
				startIndex = i,
				length = length,
				gradients = { gradient },
				speedLimit = edgesAndIds[i].speedLimit
			})
			currentRouteSection = #routeSections
		else 
			local rs = routeSections[currentRouteSection]
			table.insert(rs.gradients, gradient)
			rs.length = rs.length + length
		end
		previousGradientCategory = gradientCategory
	end
	for i, routeSection in pairs(routeSections) do 
		routeSection.avgGradient = util.average(routeSection.gradients)
	end
	--debugPrint({routeSections=routeSections})
	trace("There were ",#routeSections," from ",#edges," edges")
	
	return routeSections
end

function pathFindingUtil.areTownsConnectedWithHighway(town1, town2) 
	if type(town1) == "number" then 
		town1 = game.interface.getEntity(town1)
	end 
	if type(town2) == "number" then 
		town2 = game.interface.getEntity(town2)
	end 
	local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenTowns(town1, town2)
	trace("pathFindingUtil.areTownsConnectedWithHighway",town1.name,town2.name,"foundRouteInfo?",routeInfo~=nil)
	if routeInfo then 
		trace("pathFindingUtil.areTownsConnectedWithHighway",town1.name,town2.name,"found route with with highwayFraction",routeInfo.highwayFraction,"routeTODist=",routeInfo.actualRouteToDist)
		if routeInfo.highwayFraction > 0.7 and routeInfo.actualRouteToDist < 1.5 then 
			trace("pathFindingUtil.areTownsConnectedWithHighway",town1.name,town2.name,"ARE connected with highway")
			return true
		end 
		local town1Node = util.findMostCentralTownNode(town1).id
		local highwayNodes1 = util.searchForJunctionHighwayNodes(town1.position, 750, function(node)
			return #pathFindingUtil.findRoadPathBetweenNodes(town1Node, node) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(node, town1Node) > 0
		end)
		
		
		local town2Node = util.findMostCentralTownNode(town2).id
		local highwayNodes2 = util.searchForJunctionHighwayNodes(town2.position, 750, function(node)
			return #pathFindingUtil.findRoadPathBetweenNodes(town1Node, node) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(node, town2Node) > 0
		end)
		for i, node1 in pairs(highwayNodes1) do 
			for j, node2 in pairs(highwayNodes2) do 
				local routeInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node1,node2))  or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node2,node1)) 
				if routeInfo  then 
					trace("pathFindingUtil.areTownsConnectedWithHighway",town1.name,town2.name,"found route subsequently with highwayFraction",routeInfo.highwayFraction,"routeTODist=",routeInfo.actualRouteToDist)
					if routeInfo.highwayFraction > 0.7 and routeInfo.actualRouteToDist < 1.5 then 
						trace("pathFindingUtil.areTownsConnectedWithHighway",town1.name,town2.name,"ARE connected with highway")
						return true
					end 
				
				end 
			  
			end
		end 
	end 
	trace("pathFindingUtil.areTownsConnectedWithHighway",town1.name,town2.name,"are NOT connected with highway")
	return false
end 

function pathFindingUtil.getRouteInfoFromEdges(inputEdges) 
	if #inputEdges==0 then return end
	util.lazyCacheNode2SegMaps()
	local firstFreeEdge
	local lastFreeEdge
	local firstUnconnectedTerminalNode
	local lastUnconnectedTerminalNode
	local edges = {}
	local edgesAndIds = {}
	local alreadySeen = {}
	local speedLimits = {}
	local lengths = {}
	local grads = {}
	for i, segOrNode in pairs(inputEdges) do
		local edgeId
		local edge 
		if segOrNode.node0 then 
			edge = segOrNode
			edgeId = util.getEdgeIdFromEdge(edge) 
		else 
			edgeId = segOrNode.entity
			edge = util.getEdge(edgeId) 
		end
		local tn = util.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
		local tnEdge = tn.edges[segOrNode.index and segOrNode.index+1 or 1]
		local speedLimit = math.min(tnEdge.speedLimit, tnEdge.curveSpeedLimit)
		table.insert(speedLimits,speedLimit )
		local geometry = tnEdge.geometry
		table.insert(lengths,  geometry.length)
		table.insert(grads, (geometry.height.y - geometry.height.x)/ geometry.length)
		if edge and not alreadySeen[edgeId] then
			alreadySeen[edgeId]=true
			local constructionId =  api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
			if not firstFreeEdge then
				if constructionId == -1 then 
					firstFreeEdge = 1+#edges
					if #edges > 0 then
						firstUnconnectedTerminalNode = trytoFindUnconnectedTerminalNode(edgesAndIds[#edges].id)
					end
				end
			elseif not lastFreeEdge and constructionId ~= -1 then
				lastUnconnectedTerminalNode = trytoFindUnconnectedTerminalNode(edgeId)
				lastFreeEdge = #edges
			end
			table.insert(edges, edge)
			table.insert(edgesAndIds, {id=edgeId, edge=edge, speedLimit=speedLimit})
		end
	end
	if not lastFreeEdge  then
		lastFreeEdge = #edges
	end
	local startPoint = util.getEdgeMidPoint(edgesAndIds[1].id)
	local endPoint = util.getEdgeMidPoint(edgesAndIds[#edgesAndIds].id)
	local straightDistance = util.distance(startPoint, endPoint)
	local routeVector = endPoint - startPoint
	local routeLength = 0
	local actualRouteLength = 0
	local isHighSpeedTrack = false 
	local isElectricTrack = false
	local hasHighwayEdges = false
	local highwayEdgeCount =0 
	local isHighwayRoute = false
	local hasOldStreetSections = false
	local routeSections
	local averageRouteLanes = 1
	local averageRouteLanesUbran = 1
	if util.getComponent(edgesAndIds[1].id, api.type.ComponentType.BASE_EDGE_STREET) then 
		local urbanRoadPenaltyFactor = paramHelper.getParams().urbanRoadPenaltyFactor
		local highwayRoadBonusFactor = paramHelper.getParams().highwayRoadBonusFactor
		local totalLaneCount = 0
		local nonFrozenEdgeCount = 0
		local urbanRoadCount = 0
		
		local streetRep = util.getStreetTypeRep() 
		for i = 1, #edges do 
			local edgeId = edgesAndIds[i].id
			 
			
			if util.isOldEdge(edgeId) then 
				hasOldStreetSections = true 
			end 
			
			
			local edgeLength = util.calculateSegmentLengthFromEdge(edges[i])
			actualRouteLength = actualRouteLength + edgeLength
			assert(edgeId~=nil)
			local rawLaneCount = util.getNumberOfStreetLanes(edgeId)
			local isOneWayStreet = util.isOneWayStreet(edgeId) 
			local trafficLaneCount = rawLaneCount - 2 
			local laneCountPerDirection = isOneWayStreet and trafficLaneCount or trafficLaneCount / 2
			assert(laneCountPerDirection >=1)
			local streetCategory = util.getStreetTypeCategory(edgeId)
		--	trace("Inspecting edge at ",i," streetCategory was ",streetCategory," for edge",edgesAndIds[i].id)
			if streetCategory == "urban" and edgesAndIds[i].edge.type == 0 then 
				edgeLength = edgeLength * urbanRoadPenaltyFactor
				if not util.isFrozenEdge(edgeId) then 
					urbanRoadCount = urbanRoadCount + 1
					averageRouteLanesUbran = averageRouteLanesUbran + laneCountPerDirection 
				end 
			elseif streetCategory == "highway" then 
				edgeLength = edgeLength * highwayRoadBonusFactor
				hasHighwayEdges = true
				highwayEdgeCount= highwayEdgeCount+1
			end			
			
			if not util.isFrozenEdge(edgeId) then 
				totalLaneCount = totalLaneCount + laneCountPerDirection 
				nonFrozenEdgeCount = nonFrozenEdgeCount + 1
			end
			routeLength = routeLength + edgeLength
		end
		averageRouteLanes = totalLaneCount/nonFrozenEdgeCount 
		averageRouteLanesUbran = averageRouteLanesUbran / urbanRoadCount
		isHighwayRoute = highwayEdgeCount/#edges > 0.5
		routeSections = {}
		for i = 1, #speedLimits do 
			table.insert(routeSections, {
				startIndex = i,
				length = lengths[i],
				avgGradient = grads[i],
				speedLimit = speedLimits[i]
			})
		end
	else 
		routeLength = util.calculateRouteLength(edges)
		actualRouteLength = routeLength
		routeSections = pathFindingUtil.getGradientRouteSectionsFromEdges(edges, edgesAndIds, firstFreeEdge, lastFreeEdge)
		isHighSpeedTrack = #edges>0
		isElectricTrack = #edges>0
		local highSpeedTrackType = api.res.trackTypeRep.find("high_speed.lua")
		for i = 1, #edges do 
			local trackEdge = util.getComponent(edgesAndIds[i].id, api.type.ComponentType.BASE_EDGE_TRACK)
			if trackEdge.trackType ~= highSpeedTrackType then 
				isHighSpeedTrack = false 
			end 
			if not trackEdge.catenary then 
				isElectricTrack = false 
			end 
			if (not isElectricTrack) and (not isHighSpeedTrack) then 
				break 
			end
		end 
	end
	
	
	local stationToStationGradient = (endPoint.z - startPoint.z) /  util.calculateRouteLength2d(edges)
	local avgHeight = 0
	local maxHeight = -2^16
	local minHeight = 2^16
	local nodeCount = 0 
	local uniqueNodes = {}
	local indexLookup = {}	
	for i = 1, #edges do 
		for __, node in pairs({ edges[i].node0, edges[i].node1}) do 
			if not uniqueNodes[node] then	
				uniqueNodes[node] = true
				nodeCount = nodeCount + 1
				local nodePos = util.nodePos(node) 
				local height = nodePos.z
				avgHeight = avgHeight+height
				maxHeight = math.max(maxHeight, height)
				minHeight = math.min(minHeight, height)
			end
		end
		indexLookup[edgesAndIds[i].id]=i
	end
	avgHeight = avgHeight / nodeCount
	 
	local deltaZ  = maxHeight - minHeight
	local routeToDist = routeLength / straightDistance
	local actualRouteToDist = actualRouteLength / straightDistance
	local maxGradient = util.calculateMaxGradient(edges)
	local signalIndexes = util.getSignalIndexes(edges)
	local numSignals = #signalIndexes
	local exceedsRouteToDistLimitForTrucks = routeLength > 200 and routeToDist > paramHelper.getParams().truckRouteToDistanceLimit+200
	
	local grad = deltaZ / straightDistance
	if exceedsRouteToDistLimitForTrucks and grad > 0.5 * paramHelper.getParams().maxGradientRoad then 
		trace("Initial calculation suggested exceedsRouteToDistLimitForTrucks, however, based on grad=",grad," from deltaz=",deltaZ," and straightDistance=",straightDistance," resetting to false")
		exceedsRouteToDistLimitForTrucks = false
	end 	
	
	local isBackwardsEdgeData
	local function getBackwardsEdgeData()
		if not isBackwardsEdgeData then 
			isBackwardsEdgeData = {}
			for i =1, #edges do
				local edge = edges[i]
				local isBackWards = false
				if i > 1 then 
					local priorEdge = edges[i-1]
					isBackWards = edge.node1 == priorEdge.node0 or edge.node1 == priorEdge.node1
				elseif i < #edges then 
					local nextEdge = edges[i+1]
					isBackWards = edge.node0 == nextEdge.node0 or edge.node0 == nextEdge.node1
				end 
				table.insert(isBackwardsEdgeData, isBackWards)
			end 
		end 
		return isBackwardsEdgeData
	end
	local reversalIndexes
	local function getReversalIndexes()
		local isBackwardsEdgeData= getBackwardsEdgeData()
		if not reversalIndexes then 
			reversalIndexes = { false }
			for i =2, #edges do
				local isReversal =  isBackwardsEdgeData[i-1] ~= isBackwardsEdgeData[i]
				table.insert(reversalIndexes, isReversal)
			end 
			if util.tracelog then debugPrint({reversalIndexes=reversalIndexes, isBackwardsEdgeData=isBackwardsEdgeData})end
		end 
		return reversalIndexes
	end
	local function countReversalsBetweenIndexes(index1, index2) 
		if index2 < index1 then
			local temp = index1 
			index1 = index2 
			index2 = temp
		end 
		local count =0
		local reversalIndexes = getReversalIndexes()
		for i=index1, index2 do 
			if reversalIndexes[i] then 
				count = count +1
			end
		end
		trace("countReversalsBetweenIndexes between",index1,index2,"got",count,"edges were",edgesAndIds[index1].id,edgesAndIds[index2].id)
		return count
	end 
	
	
	return {
		edges=edgesAndIds,
		edgesOnly = edges,
		firstFreeEdge = firstFreeEdge,
		lastFreeEdge = lastFreeEdge,
		routeLength = routeLength,
		straightDistance = straightDistance,
		routeToDist = routeToDist,
		maxGradient = maxGradient,
		numSignals = numSignals,
		firstUnconnectedTerminalNode = firstUnconnectedTerminalNode,
		lastUnconnectedTerminalNode = lastUnconnectedTerminalNode,
		exceedsRouteToDistLimitForTrucks = exceedsRouteToDistLimitForTrucks,
		routeSections = routeSections,
		actualRouteToDist = actualRouteToDist,
		stationToStationGradient = stationToStationGradient,
		avgHeight = avgHeight,
		maxHeight = maxHeight,
		minHeight = minHeight,
		signalIndexes = signalIndexes,
		actualRouteLength = actualRouteLength,
		isHighSpeedTrack = isHighSpeedTrack,
		isElectricTrack = isElectricTrack,
		hasHighwayEdges = hasHighwayEdges,
		highwayEdgeCount = highwayEdgeCount,
		highwayFraction = highwayEdgeCount/#edges,
		isHighwayRoute = isHighwayRoute,
		speedLimits = speedLimits,
		hasOldStreetSections = hasOldStreetSections,
		lengths = lengths,
		grads = grads,
		averageRouteLanes = averageRouteLanes,
		isMultiLaneRoute = averageRouteLanes>=2,
		averageRouteLanesUbran = averageRouteLanesUbran,
		isDoubleTrack = numSignals > 0, -- simplistic 
		tnEdges = inputEdges,
		countReversalsBetweenIndexes=countReversalsBetweenIndexes,
		getBackwardsEdgeData = getBackwardsEdgeData,
		isMainLineHasReversals = function()
			local reversalIndexes = getReversalIndexes()
			for i = firstFreeEdge+1, lastFreeEdge do 
				if reversalIndexes[i] then 
					return true 
				end
			end 	
			return false 
		end,
		isPredominantlyBackwards = function()
			local isBackwardsEdgeData = getBackwardsEdgeData()
			local count = 0 
			for i = firstFreeEdge, lastFreeEdge do 
				if isBackwardsEdgeData[i] then 
					count = count + 1 
				end
			end 
			trace("isPredominantlyBackwards: got",count ,"of",lastFreeEdge-firstFreeEdge)
			return count > (lastFreeEdge-firstFreeEdge) / 2 
		end,
		getIndexOfClosestApproach = function(p)
			local options = {} 
			for i =firstFreeEdge, lastFreeEdge do 
				if api.engine.entityExists(edgesAndIds[i].id) and util.getEdge(edgesAndIds[i].id) then 
					local edge = util.getEdge(edgesAndIds[i].id)
					if api.engine.entityExists(edge.node0) and api.engine.entityExists(edge.node1) then 
						table.insert(options, 
							{
								idx =i ,
								scores = { util.distance(p, util.getEdgeMidPoint(edgesAndIds[i].id))}
							})
					end
				end
			end 
			return util.evaluateWinnerFromScores(options).idx
		end,
		indexOf = function(edgeId) 
			return indexLookup[edgeId]
		end ,
		getReversalIndexes = getReversalIndexes,
		containsNode = function(node)  
			for i = 1, #edges do
				local node0 =edges[i].node0 
				local node1 =edges[i].node1
			
				if node0 == node or  node1 == node 	then
					return true
				end
			end
			return false
		end ,
		closestFreeNode = function(p) 
			local nodes = {} 
			for i = firstFreeEdge, lastFreeEdge do
				local edge = edges[i]
				for __, node in pairs({edge.node0, edge.node1}) do 
					if api.engine.entityExists(node) and util.getNode(node) then 
						table.insert(nodes, node)
					end
				end 
			end 
			return util.evaluateWinnerFromSingleScore(nodes, function(node) return util.distance(util.nodePos(node),p) end)
		end ,
		getAllNodes = function() 
			local nodes = {} 
			for i = 1, #edges do
				local edge = edges[i]
				for __, node in pairs({edge.node0, edge.node1}) do 
					if not nodes[node] then 
						nodes[node]=true
					end
				end 
			end
			return nodes
		end,
		getAllEdges = function() 
			local edgesSet = {} 
			for i = 1, #edges do
				local edge = edgesAndIds[i].id
				edgesSet[edge]=true
			end
			return edgesSet
		end,
		getAllStations = function() 
			local stations = {}
			local alreadySeen = {}
			for i = 1, #edgesAndIds do 
				local edgeId = edgesAndIds[i].id
				local constructionId = util.isFrozenEdge(edgeId) 
				if constructionId and not alreadySeen[constructionId] then 
					alreadySeen[constructionId]=true
					local station = util.getConstruction(constructionId).stations[1]
					table.insert(stations, station)
				end 
			end 
			return stations
		end ,
		getDirectionAndRouteData = function() 
			local routeNodes = {}
			local nodesByAngleCategory = {}
			local maxAngleCategory = -math.huge 
			local minAngleCategory = math.huge
			local priorNodes  
			local priorTangent
			local routeLengthSummation = 0
			for i =1 , #edges do 
				local edge = edges[i]
				local isBackWards
				if i == 1 then 
					isBackWards = edge.node0 == edges[2].node1 or edge.node0 == edges[2].node1 
				else 
					isBackWards = priorNodes[edge.node1]
				end 
				local directionalTangent
				local currentNode
				if isBackWards then 
					currentNode = edge.node1 
					directionalTangent = -1*util.v3(edge.tangent1)
				else 
					currentNode = edge.node0 
					directionalTangent = util.v3(edge.tangent0)
				end 
				if i == 1 then 
					priorTangent = directionalTangent
				end 
				local angleToPrior = util.signedAngle(priorTangent, directionalTangent)
				local angleToRouteVector = util.signedAngle(routeVector, directionalTangent)
				local fn = angleToRouteVector < 0 and math.ceil or math.floor 
				local angleCategory = fn(angleToRouteVector/math.rad(22.5))
			 
				local nodePos = util.nodePos(currentNode)
				local distanceToStart = util.distance(nodePos, startPoint)
				local distanceToEnd = util.distance(nodePos, endPoint)
				local edgeLength = util.calculateSegmentLengthFromEdge(edges[i])
				routeLengthSummation = routeLengthSummation + edgeLength
				local routeLengthFromStart = routeLengthSummation
				local routeLengthFromEnd = routeLength - routeLengthFromStart
				trace("routeInfo.getDirectionAndRouteData: At i = ",i," node=",currentNode,"angleToPrior=",math.deg(angleToPrior)," angleToRouteVector=",math.deg(angleToRouteVector), " angleCategory=",angleCategory)
				trace("The distanceToStart was",distanceToStart," the routeLengthFromStart was",routeLengthFromStart," the distanceToEnd was ",distanceToEnd," the routeLengthFromEnd=",routeLengthFromEnd)
				local nodeDetails = {
					tangent = directionalTangent,
					node = currentNode,
					nodePos = nodePos,
					angleToPrior = angleToPrior,
					angleToRouteVector = angleToRouteVector,
					distanceToEnd = distanceToEnd,
					distanceToStart = distanceToStart,
					routeLengthFromStart = routeLengthFromStart,
					routeLengthFromEnd = routeLengthFromEnd,
					edge = edge,
					edgeIdx = i,
					sharpAngleChange = math.abs(angleToPrior) > math.rad(45),
				}
				table.insert(routeNodes, nodeDetails)
				if util.nodeHasAtLeastOneNonUrbanNode(currentNode) and not util.isFrozenNode(currentNode) then 
					maxAngleCategory = math.max(maxAngleCategory, angleCategory)
					minAngleCategory = math.min(minAngleCategory, angleCategory)
					if not nodesByAngleCategory[angleCategory] then 
						nodesByAngleCategory[angleCategory]={}
					end
					
					table.insert(nodesByAngleCategory[angleCategory], nodeDetails)
				end
				priorTangent = directionalTangent
				priorNodes = { [edge.node0] = true, [edge.node1] =   true  } 
			end 
			trace("routeInfo.getDirectionAndRouteData, number of angleCategory was",util.size(nodesByAngleCategory))
			return { 
				routeNodes = routeNodes, 
				nodesByAngleCategory = nodesByAngleCategory,
				maxAngleCategory = maxAngleCategory, 
				minAngleCategory = minAngleCategory,
				maxAbsAngleCategory = math.max(math.abs(minAngleCategory), math.abs(maxAngleCategory)),
			}
			
		end 
		
	}
end

function pathFindingUtil.findPathFromDepotToStop(depotEntity, stop, nonStrict, line, isElectric, range)
	local depotComp =  util.getComponent(depotEntity, api.type.ComponentType.VEHICLE_DEPOT)
	local carrier = depotComp.carrier
	--trace("Finding path from ",depotEntity," to stop isElectric?",isElectric, " carrier=",carrier, " nonStrict=",nonStrict)
	local transportModes = {}
	if carrier == api.type.enum.Carrier.RAIL then	
		if nonStrict or line.vehicleInfo.transportModes[api.type.enum.TransportMode.ELECTRIC_TRAIN+1]==0 and not isElectric then 
			transportModes =  {api.type.enum.TransportMode.TRAIN}
		else 
			trace("Using the ELECTRIC_TRAIN as the transport mode")
			transportModes = {api.type.enum.TransportMode.ELECTRIC_TRAIN} 
		end 
	elseif carrier == api.type.enum.Carrier.ROAD then 
		transportModes = {api.type.enum.TransportMode.BUS, api.type.enum.TransportMode.TRUCK}
	elseif carrier == api.type.enum.Carrier.AIR then 
		transportModes = {api.type.enum.TransportMode.SMALL_AIRCRAFT}
	elseif carrier == api.type.enum.Carrier.WATER  then 
		transportModes = {api.type.enum.TransportMode.SMALL_SHIP}
	elseif carrier == api.type.enum.Carrier.TRAM then  
		if nonStrict then 
			transportModes = {api.type.enum.TransportMode.TRAM, api.type.enum.TransportMode.BUS}
		else 
			transportModes = {api.type.enum.TransportMode.TRAM}
		end 
	else
		trace("warning unable to determine transport type from",carrier, " from depotEntity=",depotEntity)
		return {}
	end
	local stationGroupId = stop.stationGroup
	local stationGroup =  util.getComponent(stationGroupId, api.type.ComponentType.STATION_GROUP)
	local stationId = stationGroup.stations[stop.station+1]
	local terminal = stop.terminal
	return pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, stationId, terminal, carrier, range)
end 

function pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, stationId, terminal, carrier, range)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(depotEntity)
	if constructionId == -1 or not api.engine.entityExists(constructionId) then 
		trace("WARNING! No construction entity found for depot",depotEntity,"got",constructionId)
		return {} -- empty path
	end 
	local construction = util.getConstruction(constructionId)
	local edgeId = construction.frozenEdges[1]
	
	local depotPos = util.v3(construction.transf:cols(3))
	if carrier == api.type.enum.Carrier.WATER  then 
		return pathFindingUtil.checkConstructionsShareWaterMesh(constructionId, api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId))
	end 

	local stationPos = util.getStationPosition(stationId)
	local station =  util.getComponent(stationId, api.type.ComponentType.STATION)
	
	local dist = util.distance(depotPos, stationPos) 
	if range and dist > range then --performance optimisation
		return {} 
	end
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(edgeId, transportModes[1]) 
	local destNodes = pathFindingUtil.getDestinationNodesForStation(stationId, terminal)
	local maxDist = 3*dist
	--trace("About to find path from depot to stop")
	return  pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDist)  
end
local function getRouteLengthOfPath(path)
	if type(path[1])=="number" then --water "path"
		return util.distBetweenConstructions(path[1], path[2])
	end 	
	return pathFindingUtil.getRouteInfoFromEdges(path).routeLength

end 
function pathFindingUtil.getAllEdgesUsedByLines(filterFn)
	local begin = os.clock()
	local result = {}
	if not filterFn then filterFn = function() return true end end
	for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLines())) do 
		local alreadySeen = {}
		local line = getLine(lineId)
		if not filterFn(line, lineId) then 
			goto continue 
		end 
		for j, stop in pairs(line.stops) do 
			local priorStop = j ==1 and line.stops[#line.stops] or line.stops[j-1]
			local station1 = stationFromStop(priorStop)
			local station2 = stationFromStop(stop)
			if isRailLine(line)  then 
				for k, edgeEntity in pairs(pathFindingUtil.findRailPathBetweenStations(station1, station2)) do 
					 
					local edgeId = edgeEntity.entity 
					if not result[edgeId] then 
						result[edgeId] = {} 
					end 
					if not alreadySeen[edgeId] then 
						table.insert(result[edgeId], lineId)
						alreadySeen[edgeId]=true
					end 
				end 
			elseif isRoadLine(line) then 
				for k, edgeEntity in pairs(pathFindingUtil.findRoadPathStations(station1, station2, isTramLine(line))) do 
					local edgeId = edgeEntity.entity 
					if not result[edgeId] then 
						result[edgeId] = {} 
					end 
					if not alreadySeen[edgeId] then 
						table.insert(result[edgeId], lineId)
						alreadySeen[edgeId]=true
					end 
				end   
			end
			
		end 

		
		::continue::	
	end 
	trace("Collected all line edges, time taken=",(os.clock()-begin))
	return result
end  

function pathFindingUtil.getEdgesUsedByLinesGrouped(filterFn, filterEdges)
	if not filterEdges then 
		filterEdges = function(edgeId) return util.getEdge(edgeId) end
	end 

	local edges = pathFindingUtil.getAllEdgesUsedByLines(filterFn)
	local function hashLines(lineIds)
		local result = 0
		table.sort(lineIds)
		for i, lineId in pairs(lineIds) do 
			result = 31*result + lineId -- very simplistic hash but it may do for now
		end
		return result
	end 
	local mappedResults=  {}
	
	for edgeId, lineIds in pairs(edges) do 
		if filterEdges(edgeId) then 
			local key = hashLines(lineIds)
			if not mappedResults[key] then 
				mappedResults[key]= {lineIds = lineIds, edges = {}, key = key}
			end 
			assert(game.interface.getEntity(edgeId).type=="BASE_EDGE")
			mappedResults[key].edges[edgeId]=true
		end
	end 
	return mappedResults
end

function pathFindingUtil.findStopIndexesForDepot(depotEntity, line, nonStrict, isElectric, range) 
	local result = {}
	for i = 1, #line.stops do 
		--trace("About to find path stop = ",i-1)
		local path = pathFindingUtil.findPathFromDepotToStop(depotEntity, line.stops[i], nonStrict, line, isElectric, range)
		--trace("result of depotEntity was ",#path)
		if #path > 0 then 
			table.insert(result, {stopIndex = i-1, distance = getRouteLengthOfPath(path)}) 
		
		end		
	end	
	return result
end 
function pathFindingUtil.findClosestStopIndexForDepot(depotEntity, line, nonStrict, isElectric) 
	local options ={} 
	for i = 1, #line.stops do 
		--trace("About to find path stop = ",i-1)
		local path = pathFindingUtil.findPathFromDepotToStop(depotEntity, line.stops[i], nonStrict, line, isElectric)
		--trace("result of depotEntity was ",#path)
		if #path > 0 then 
			table.insert(options,{ 
				stopIndex = i-1,
				scores = { #path } 
			})
		end		
	end	
	--trace("Closest stop index options were ",#options)
	if #options > 0 then 
		
		return util.evaluateWinnerFromScores(options).stopIndex
	end
end

function pathFindingUtil.getRouteInfo(station1, station2, terminal1, terminal2)
	
	local answer = pathFindingUtil.findRailPathBetweenStations(station1, station2, terminal1, terminal2)
	if #answer == 0 then
		trace("no route found between ", station1, " and ", station2)
		return 
	end
	local routeInfo =  pathFindingUtil.getRouteInfoFromEdges(answer) 
	routeInfo.station1 = station1 
	routeInfo.station2 = station2 
	return routeInfo
end


function pathFindingUtil.getRouteInfoAutoTerminals(station1, station2) 
	local station1Terminals = #getStation(station1).terminals
	local station2Terminals = #getStation(station2).terminals
	for i = 0, station1Terminals -1 do 
		for j = 0 , station2Terminals-1 do 
			local routeInfo = pathFindingUtil.getRouteInfo(station1, station2, i, j)
			trace("getRouteInfoAutoTerminals: attempting to get route info between stations and terminals",station1, station2, i, j,"found?",(routeInfo~=nil))
			if routeInfo then 
				return routeInfo
			end 
		end 
	end 
	trace("WARNING! getRouteInfoAutoTerminals: no route info found between",station1, station2)
end 
function pathFindingUtil.findPath( startingEdges , destNodes, transportModes, distance)
	local answer = api.engine.util.pathfinding.findPath( startingEdges , destNodes, transportModes, distance)
	local result = {} 
	for i = 1, #answer do 
		table.insert(result, { entity = answer[i].entity, index = answer[i].index })-- clone into lua objects to make it safe to serialize
	end
	
	return result
end

function pathFindingUtil.getRouteInfoFromTrackNode(node)
	local edges = util.findAllConnectedFreeTrackEdges(node)
	return pathFindingUtil.getRouteInfoFromEdges(edges) 
end
 
return pathFindingUtil