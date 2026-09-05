local util = require("ai_builder_base_util") 
local routePreparation = require("ai_builder_route_preparation")
local routeEvaluation = require("ai_builder_route_evaluation")
local paramHelper = require("ai_builder_base_param_helper")
local vehicleUtil = require("ai_builder_vehicle_util")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local connectEval = require("ai_builder_new_connections_evaluation")
local profiler = require("ai_builder_profiler")
local proposalUtil = require "ai_builder_proposal_util"
local vec3 = require("vec3")
local vec2 = require("vec2")
local function tryLoadUndo() 
	local res 
	pcall(function() res = require "undo_base_util" end)
	return res 
end 
local trialBuildBetweenPoints = proposalUtil.trialBuildBetweenPoints
local undo_script = tryLoadUndo() 
local newSignalType = "railroad/signal_path_c_one_way.mdl"
local oldSignalType = "railroad/signal_path_a_one_way.mdl"
local newEdgeToString = util.newEdgeToString
local tryToFixTunnelPortals = true
local allowTwoWaySignals = false
local allowDiagnose = proposalUtil.allowDiagnose
local routeBuilder = {}
routeBuilder.setupProposal = proposalUtil.setupProposal
routeBuilder.setupProposalAndDeconflict = proposalUtil.setupProposalAndDeconflict
local function hypot(x,y)
	return math.sqrt(x*x+y*y)
end
function routeBuilder.setTunnel(entity)
	entity.comp.type = 2 -- tunnel
	entity.comp.typeIndex = entity.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
end
local attemptPartialBuild = util.tracelog and true
local newNodeWithPosition = util.newNodeWithPosition
local copySegmentAndEntity = util.copySegmentAndEntity
-- takes points
local function hypotlen(p1, p2) 
	return hypot(p2.x-p1.x, p2.y-p1.y)
end
-- takes arrays
local function hypotlen2(p1, p2) 
	return hypot(p2[1]-p1[1], p2[2]-p1[2])
end
local trace = util.trace
local function addPause() 
	routeBuilder.addWork(function() end)
end 
 local function saveForUndo(res)
	routeBuilder.addWork(function() 
--		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("move_it_script.lua","saveForUndo", "", res), standardCallback)
		if undo_script then
			trace("Found undo script, attempting to save")
			undo_script.lastResult = res 
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_lite_script.lua","saveForUndo", "", {}), standardCallback)
			addPause()
		end
		
	end)
end 
local function err(e)
	print(e)
	print(debug.traceback())				
end
local function replaceNode(entity, oldNode, newNode ) 
	if entity.comp.node0 == oldNode then 
		entity.comp.node0 = newNode
	elseif entity.comp.node1 == oldNode then
		entity.comp.node1 = newNode 
	else 
		trace("WARNING! node ",oldNode," not found on ",entity.entity)
	end 
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

local function setTangents(entity, t)
	setTangent(entity.comp.tangent0, t)
	setTangent(entity.comp.tangent1, t)
end 

local function renormalizeTangents(entity, v)
	setTangent(entity.comp.tangent0, v*vec3.normalize(util.v3(entity.comp.tangent0)))
	setTangent(entity.comp.tangent1, v*vec3.normalize(util.v3(entity.comp.tangent1)))
end 

local function posToString(p)
	if not p then return "nil" end
	return "("..p.x..","..p.y..","..p.z..")"
end
local function isDepotEdge(edgeId, maxRecursions) 
	if not edgeId then 
		return false 
	end 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
	if constructionId ~= -1 then 
		local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
		if construction.depots[1] then 
			return true 
		end 
	elseif maxRecursions > 0 then 
		local edge = util.getEdge(edgeId) 
		for __, node in pairs({edge.node0, edge.node1}) do 
			for __, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if isDepotEdge(seg, maxRecursions-1) then
					return true
				end
			end
		end
	end	
	return false
end
local function isStationEdge(edgeId, forbidRecurse) 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
	if constructionId ~= -1 then 
		local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
		if construction.stations[1] then 
			return true 
		end 
	elseif not forbidRecurse then 
		local edge = util.getEdge(edgeId) 
		for __, node in pairs({edge.node0, edge.node1}) do 
			for __, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if isStationEdge(seg, true) then
					return true
				end
			end
		end
	end	 
	return false
end
local function findDepotEdge(edges, routeInfo, index, node,routeEdges)
	local edgeBefore 
	local thisEdge 
	local edgeAfter 
	local otherEdge 
	for i, edge in pairs(edges) do 
		if edge == routeInfo.edges[i].id then 
			thisEdge = edge 
		elseif routeInfo.edges[i+1] and edge == routeInfo.edges[i+1].id then 
			edgeAfter = edge
		elseif  routeInfo.edges[i-1] and edge == routeInfo.edges[i-1].id then 
			edgeBefore = edge
		elseif not routeEdges[edge] then 
			otherEdge = edge
		end  
	end
	if isDepotEdge(otherEdge, 5) then 
		return otherEdge 
	end 
	if otherEdge then 
		trace("findDepotEdge: Inspecting other edge", otherEdge)
		local otherEdgeFull = util.getEdge(otherEdge)
		local otherNode = otherEdgeFull.node1 == node and otherEdgeFull.node0 or otherEdgeFull.node1 
		local nextSegs = util.getSegmentsForNode(otherNode)
		local nextEdgeId = otherEdge == nextSegs[1] and nextSegs[2] or nextSegs[1]
		local alreadySeen = {}
		while nextEdgeId do 
			trace("Inspecting nextEdgeId ",nextEdgeId)
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(nextEdgeId)
			if constructionId ~= -1 then 
				local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
				if construction.stations[1] then 
					local i = routeInfo.indexOf(nextEdgeId)
					trace("WARNING! Found a station link masquerading as a depot link, attempting to correct at i=",i) 
					if i then 
						if edgeAfter then 
							routeInfo.edges[i+1].id = otherEdge 
							routeInfo.edges[i+1].edge = otherEdgeFull
							return edgeAfter
						elseif edgeBefore then 
							routeInfo.edges[i-1].id = otherEdge 
							routeInfo.edges[i-1].edge = otherEdgeFull
							return edgeBefore
						end 
					end
				end 
				if construction.depots[1] then 
					return otherEdge
				end
			end 
			local otherEdgeFull = util.getEdge(nextEdgeId)
			otherNode = otherEdgeFull.node1 == otherNode and otherEdgeFull.node0 or otherEdgeFull.node1 
			local nextSegs = util.getSegmentsForNode(otherNode)
			nextEdgeId = nextEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
			if alreadySeen[nextEdgeId] then 
				break 
			end 
			alreadySeen[nextEdgeId] = true
		end
		
	end 
	
	
	return nil --otherEdge -- most likely option 
end

local function setTangentLengths(entity, length) 
	setTangent(entity.comp.tangent0, length*vec3.normalize(util.v3(entity.comp.tangent0)))
	setTangent(entity.comp.tangent1, length*vec3.normalize(util.v3(entity.comp.tangent1)))
end

function routeBuilder.setupProposalFromLuaProposal(luaProposal)
	local result=  routeBuilder.setupProposalAndDeconflict(
		luaProposal.streetProposal.nodesToAdd, 
		luaProposal.streetProposal.edgesToAdd, 
		luaProposal.streetProposal.edgeObjectsToAdd, 
		luaProposal.streetProposal.edgesToRemove, 
		luaProposal.streetProposal.edgeObjectsToRemove)
	for i, construction in pairs(luaProposal.constructionsToAdd) do 
		result.constructionsToAdd[i]=construction
	end 
	result.constructionsToRemove = util.deepClone(luaProposal.constructionsToRemove)
	return result
end


local function checkForDepotProximity(nodes, params, station, otherStation)
	if not params.isTrack or params.disableDepotProximityCheck or params.allStations then 
		return nodes
	end
	if  #nodes == 1 then 
		trace("Only one node provided",nodes[1]," cannot do any depot checking")
		return nodes 
	end
	if  not station or #api.engine.system.lineSystem.getLineStopsForStation(station) > 0 then 
		trace("Skipping check for depot proximity for station ",station)
		return nodes 
	end
	if params.isCargo then 
		local result = {}
		for i, node in pairs(nodes) do
			local nodeDetails = util.getDeadEndNodeDetails(node)
			local testPos = nodeDetails.nodePos + 40*vec3.normalize(nodeDetails.tangent)
			local skip = false 
			for j, construction in pairs(util.searchForEntities(testPos, 50 , "CONSTRUCTION")) do
				if #nodes>1 and string.find(construction.fileName, "depot/train") then 
					local depotEdgeId = util.getComponent(construction.id, api.type.ComponentType.CONSTRUCTION).frozenEdges[1]
					local depotEdge = util.getEdge(depotEdgeId)
					local angle = util.signedAngle(depotEdge.tangent1, nodeDetails.tangent)
					trace("A depot was found, the angle was ",math.deg(angle))
					if math.abs(math.rad(180)-math.abs(angle))<math.rad(1) then 
						trace("Skipping node ",node," as it appears to face directly into a depot")
						skip = true 
					end
				end
			end
			if #nodes>1 and #util.getSegmentsForNode(node) == 1 then
				if proposalUtil.trialBuildFromDeadEndNode(node).isError then 
					skip = true
				end 
			end 
			if not skip then 
				table.insert(result, node)
			end 
		end
		if #result == 0 then 
			trace("WARNING! No result found, aborting filter")
			return nodes
		end 
		return result
	end
	trace("Checking for depot proximity for station ",station)
	local result = {}
	
	for i, node in pairs(nodes) do
		for j, construction in pairs(util.searchForEntities(util.nodePos(node), 85 , "CONSTRUCTION")) do
			if string.find(construction.fileName, "depot/train") then 
				local freeNodes = util.getFreeNodesForConstruction(construction.id)
				if #util.getTrackSegmentsForNode(freeNodes[1])==1 then 
					local tangent = util.getDeadEndNodeDetails(freeNodes[1]).tangent 
					local routeVector = util.vectorBetweenStations(station, otherStation)
					local angle = math.abs(util.signedAngle(tangent, routeVector))
					trace("Checking depot angle, was ",math.deg(angle)," to stations ",station, otherStation)
					if angle > math.rad(90) then 
						trace("Ignoring depot proximity as it is facing the wrong way")
						return nodes
					end 
					table.insert(result, node)
				end
			end
		end 
	end
	if #result == 0 then 
		trace("Warning, no depot proximity nodes were found!")
		return nodes
	end
	
	return result
end

local function isIronBridgeAvailable() 
	return util.year() >= api.res.bridgeTypeRep.get(api.res.bridgeTypeRep.find("iron.lua")).yearFrom

end 
local function isCementBridgeAvailable() 
	return util.year() >= api.res.bridgeTypeRep.get(api.res.bridgeTypeRep.find("cement.lua")).yearFrom

end 
local function evaluateBestJoinNodePair(leftNodes, edges, params,   otherStationPos, intermediateRoute, recursionDepth)
	trace("evaluateBestJoinNodePair: begin")
	if not recursionDepth then recursionDepth = 0 end
	local options = {}
	local routeInfoFromEdges = {}
	local edgeIdxLookup = {}
	local isIntermediateRoute = intermediateRoute ~= nil
	
	local isStationTerminus = #leftNodes == 1 and util.isNodeConnectedToFrozenEdge(leftNodes[1]) 
	if #leftNodes > 1 and util.isNodeConnectedToFrozenEdge(leftNodes[1]) then 
		leftNodes = { util.evaluateWinnerFromSingleScore(leftNodes, function(node) return util.distance(util.nodePos(node), otherStationPos) end) } 
		trace("Evaluate bestJoinNodePair - selecting upfront the closest left hand node, set to ",leftNodes[1])
	end 
	local useSortedEdges = true 
	for i, leftNode in pairs(leftNodes) do 
		local leftNodePos = util.nodePos(leftNode)
		for j, rightEdgeId in pairs(edges) do 
			if not api.engine.entityExists(rightEdgeId) or not util.getEdge(rightEdgeId) then 
				trace("Unable to find ",rightEdgeId," skipping") 
				goto continue 
			end
			if not routeInfoFromEdges[rightEdgeId]  then 
				local routeInfo 
				if isIntermediateRoute then 
					local rightEdgePos = util.getEdgeMidPoint(rightEdgeId)
					local sortedIntermediateRoute = util.evaluateAndSortFromSingleScore(intermediateRoute, function(edge) return -util.distance(util.getEdgeMidPoint(edge),rightEdgePos ) end)
				
					local otherEdges = useSortedEdges and sortedIntermediateRoute or intermediateRoute
					if util.tracelog then 
						debugPrint({intermediateRoute=intermediateRoute, sortedIntermediateRoute=sortedIntermediateRoute,rightEdgeId=rightEdgeId,rightEdgePos=rightEdgePos})
					end 	
					for k, otherEdge in pairs(otherEdges) do 
						routeInfo = pathFindingUtil.getRouteInfoForRailPathBetweenEdges(rightEdgeId, otherEdge) or  pathFindingUtil.getRouteInfoForRailPathBetweenEdges(otherEdge, rightEdgeId)
						if routeInfo then 
							routeInfo.otherEdgeIdx = routeInfo.indexOf(otherEdge)
							if not routeInfo.otherEdgeIdx or not routeInfo.indexOf(rightEdgeId) then 
								debugPrint({rightEdgeId=rightEdgeId, otherEdge=otherEdge, routInfo=routeInfo})
							end 
							local indexOfRight = routeInfo.indexOf(rightEdgeId) 
							trace("IndexOfRight was",indexOfRight, "otherEdgeIdx was",routeInfo.otherEdgeIdx,"at",rightEdgePos.x,rightEdgePos.y)
							routeInfo.goingUp  = indexOfRight > routeInfo.otherEdgeIdx
							trace("The sizes of the routeInfo was",#routeInfo.edges)
							break 
						end
					end 
					
				else
					local station = util.searchForFirstEntity(otherStationPos, 100, "STATION", function(station) return station.carriers.RAIL end) 
--					local edges = util.findAllConnectedFreeTrackEdges(util.getEdge(rightEdgeId).node0)
	--				routeInfo = pathFindingUtil.getRouteInfoFromEdges(edges) 
					if station then
						station = station.id
						routeInfo  = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgeAndStation(rightEdgeId, station))
						trace("evaluateBestJoinNodePair: attempting to find rail path between ",station,"and",rightEdgeId,"found?",routeInfo~=nil)
						if not routeInfo then 
							routeInfo =  pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenStationAndEdge(rightEdgeId, station))
							trace("evaluateBestJoinNodePair: second attempt attempting to find rail path between ",station,"and",rightEdgeId,"found?",routeInfo~=nil)
							if routeInfo then 
								routeInfo.goingUp = true -- start at station ends at edge
							end 
						end 
					else 
						local edges = util.findAllConnectedFreeTrackEdges(util.getEdge(rightEdgeId).node0)
						routeInfo = pathFindingUtil.getRouteInfoFromEdges(edges) 
					end 
				end 
				local dists = {}
				if not routeInfo then 
					trace("WARNING! No routeInfo found trying to inspect",leftNode, rightEdgeId)
					goto continue 
				end
				for i = 1, #routeInfo.edges do
					local edgeId = routeInfo.edges[i].id 
					routeInfoFromEdges[edgeId]=routeInfo 
					edgeIdxLookup[edgeId]=i
					local distToOtherStation = util.distance(otherStationPos, util.getEdgeMidPoint(edgeId))
					if not util.isFrozenEdge(edgeId) then 
						table.insert(dists, { idx = i, scores = { distToOtherStation}})
					end 
				end 
				local stationIdx = util.evaluateWinnerFromScores(dists).idx 
				local halfway = 0.5*#routeInfo.edges
				local nextIdx = stationIdx < halfway and stationIdx+1 or stationIdx-1 
				local routeDistances = {} 
				 
				local dist = 0 
				for i = stationIdx, #routeInfo.edges do 
					routeDistances[i] = dist 
					dist = dist + util.calculateSegmentLengthFromEdge(routeInfo.edges[i].edge)
				end 
				local dist = 0 
				for i = stationIdx, 1, -1 do 
					routeDistances[i] = dist 
					dist = dist + util.calculateSegmentLengthFromEdge(routeInfo.edges[i].edge)
				end 
				routeInfo.routeDistances=routeDistances
				routeInfo.stationIdx = stationIdx
				if not routeInfo.edges[nextIdx] then 
					trace("WARNING! No edge at ",nextIdx," falling back to ",stationIdx)
					nextIdx = stationIdx 
				end
				local dist1 =  util.distance(util.nodePos(routeInfo.edges[nextIdx].edge.node0), otherStationPos)
				local dist2 = util.distance(util.nodePos(routeInfo.edges[nextIdx].edge.node1), otherStationPos)
				routeInfo.isNode0 = dist1 < dist2
			end
			local routeInfo = routeInfoFromEdges[rightEdgeId]
			if not routeInfo then 
				trace("WARNING! No routeInfo found trying to inspect",leftNode, rightEdgeId)
				goto continue 
			end
			local joinIdx = edgeIdxLookup[rightEdgeId]
			local rightEdge = util.getEdge(rightEdgeId)
			local isRightNode0 = routeInfo.isNode0 
			if routeInfo.goingUp then 
				if routeInfo.edges[joinIdx-1] then 
					local priorEdge = routeInfo.edges[joinIdx-1].edge
					isRightNode0 = priorEdge.node1 == rightEdge.node0 
					trace("comparing joinIdx-1 edge, was node1?",isRightNode0)
					
				else
					trace("WARNING! No joinIndex-1 found")
				end 
			else 	
				if routeInfo.edges[joinIdx+1] then 
					local priorEdge = routeInfo.edges[joinIdx+1].edge 
					isRightNode0 = priorEdge.node0 == rightEdge.node1 
					trace("comparing joinIdx+1 edge, was node1?",isRightNode0)
				else 
					trace("WARNING! Not joinIdex+1 found")
				end 
			end 			
				
				
				
			local rightNode = isRightNode0 and rightEdge.node0 or rightEdge.node1
			local otherNode = isRightNode0 and rightEdge.node1 or rightEdge.node0
			local otherNodePos = util.nodePos(otherNode)
			local leftEdgeId = util.getTrackSegmentsForNode(leftNode)[1]
		
		--	local rightEdgeId = edge
			local distance = util.distance(leftNodePos, otherNodePos)
			local leftEdge = util.getEdge(leftEdgeId)
			
			-- NB The leftNode is the station node, need the outbound tangent for correct angle calculation
			--local leftTangent =leftEdge.node0 == leftNode and  -1*util.v3(leftEdge.tangent0) or util.v3(leftEdge.tangent1) 
			--local rightTangent = util.v3(rightEdge.node0 == rightNode and rightEdge.tangent0 or rightEdge.tangent1)
			local isLeftNode0 = leftEdge.node0 == leftNode
			local leftTangent = leftEdge.node0 == leftNode and  -1*util.v3(leftEdge.tangent0) or util.v3(leftEdge.tangent1) 
			--local isRightNode0 = rightEdge.node0 == rightNode
			local rightTangent = isRightNode0 and util.v3(rightEdge.tangent0) or -1*util.v3(rightEdge.tangent1)
			 
			local otherStationTangent = otherStationPos -  otherNodePos
	
			local naturalTangent = otherNodePos - leftNodePos
			local condition
			--if isIntermediateRoute or true then -- TODO: consider want to always use this approach to get the correct angle
			--[[	if routeInfo.goingUp and routeInfo.edges[joinIdx-1] then 
					local priorEdge = routeInfo.edges[joinIdx-1].edge 
					if priorEdge.node0 == rightEdge.node1 then 
						trace("intermediateRoute: inverting tangent condition1 for", rightEdgeId)
						rightTangent = -1*rightTangent 
						condition = 1
					else 
						trace("intermediateRoute: NOT inverting tangent condition2 for", rightEdgeId)
						condition =2 
					end 
				elseif routeInfo.edges[joinIdx+1] then 
					local priorEdge = routeInfo.edges[joinIdx+1].edge 
					if priorEdge.node0 == rightEdge.node1 then 
						trace("intermediateRoute: inverting tangent condition3 for", rightEdgeId)
						rightTangent = -1*rightTangent 
						condition = 3
					else 
						trace("intermediateRoute: NOT inverting tangent condition4 for", rightEdgeId)
						condition = 4
					end 
				else 
					trace("WARNING! Unable to determine correct tangent")
					condition = 5
				end ]]--
			--else 
			--	if math.abs(util.signedAngle(naturalTangent, rightTangent)) > math.rad(90)  then -- assume we build the exit in the direction
			--		rightTangent = -1*rightTangent 
			--	end
			--end				
			local relativeAngle = math.abs(util.signedAngle(leftTangent, rightTangent))
			
			local stationVector = leftNodePos-otherNodePos
			local mainLineVector = otherNodePos -otherStationPos 
			local interceptAngle = math.abs(util.signedAngle(mainLineVector, stationVector))
			
			local relativeAngle2 =  math.abs(util.signedAngle(naturalTangent, rightTangent))
			local relativeAngle3 =  math.abs(util.signedAngle(naturalTangent, leftTangent))
			local correctedAngle = relativeAngle > math.rad(90) and math.rad(180) - relativeAngle or relativeAngle
			local correctedAngle2 = relativeAngle2 > math.rad(90) and math.rad(180) - relativeAngle2 or relativeAngle2
			local correctedAngle3 = relativeAngle3 > math.rad(90) and math.rad(180) - relativeAngle3 or relativeAngle3
			
			local doNotCorrectAngle = not isStationTerminus 
			if not doNotCorrectAngle or true then -- need to think about, want to avoid making a 180 degree turn
				correctedAngle = relativeAngle
				correctedAngle2 = relativeAngle2
				correctedAngle3 = relativeAngle3
				trace("Reverting the corrected angles")
			end 
			if isStationTerminus then 
				trace("Setting the correctedAngle3 to zero for station terminus")
				correctedAngle3 = 0
			end
			
			local routeDistance = routeInfo.routeDistances[joinIdx]
			local distToOtherStation = vec3.length(mainLineVector)
			if isIntermediateRoute then 
				routeDistance = distToOtherStation
			end
			local verticalDiff = math.abs(util.nodePos(leftNode).z-util.nodePos(rightNode).z)
			local grad = verticalDiff / distance 
			if grad < 0.01 then 
				grad = 0 -- don't score trivial gradients
			end
			trace("Inspecting nodes ",leftNode, rightNode, "othernode=",otherNode," distance=",distance,"relativeAngle=",math.deg(relativeAngle), " correctedAngle=",math.deg(correctedAngle), " correctedAngle2=",math.deg(correctedAngle2),"condition=",condition,"isRightNode0?",isRightNode0," correctedAngle3=",math.deg(correctedAngle3), " interceptAngle=",math.deg(interceptAngle),"routeDistance=",routeDistance, "distToOtherStation=",distToOtherStation,"verticalDiff=",verticalDiff,"relativeAngle2=",math.deg(relativeAngle2))
			if routeDistance > 1.5*distToOtherStation then 
				trace("WARNING! unexpected routeDistance attempting to correct") 
				routeDistance = 1.5*distToOtherStation
			end
			if routeDistance < distToOtherStation then 
				trace("WARNING! unexpected routeDistance attempting to correct") 
				routeDistance = distToOtherStation
			end
			
			local isJunctionEdge = false 
			for __ , node in pairs({rightNode, otherNode}) do 
				for __, seg in pairs(util.getTrackSegmentsForNode(node)) do 
					if util.isJunctionEdge(seg) then 
						isJunctionEdge = true
						break
					end 
					
				end 
			end 
			local minEdgeLength = math.huge
			for __, seg in pairs(util.getTrackSegmentsForNode(rightNode)) do 
				minEdgeLength = math.min(minEdgeLength, util.getEdgeLength(seg))
			end
			local nearbyEdgeCount = util.countNearbyEntities(otherNodePos, 30, "BASE_EDGE")
			local function scoredAngle(angle)
				if angle < 0 then 
					angle = math.abs(angle) 
				end 
				if angle < math.rad(15) then -- do not score small angles
					return 0 
				end 
				return angle 
			end 
			local distToOtherStation = util.distance(otherStationPos, leftNodePos)
			local rightNodePos = util.nodePos(rightNode)
			local distToOtherStation2 = util.distance(otherStationPos, rightNodePos)
			local canAccept = not isJunctionEdge and minEdgeLength > 70 and grad <=  params.absoluteMaxGradient
			local reveralIndexes =  routeInfo.getReversalIndexes()
			if reveralIndexes[joinIdx] or reveralIndexes[joinIdx+1] or reveralIndexes[joinIdx-1] then -- creates ambiguous results about tangent direction and offset
				trace("Rejecting nodePair",leftNode,rightNode,"for being too close to reveralIndex")
				canAccept = false
			end 
			if distance < 300 and math.abs(correctedAngle2) > math.rad(90) then -- to guard against going past the position and creating a junction the wrong way
				trace("Rejecting",leftNode,rightNode,"based on short distance corrected angle 2")
				canAccept = false
			end 
			local terrainOffset = math.abs(rightNodePos.z-util.th(rightNodePos))
			if terrainOffset < 5 then 
				terrainOffset = 0 -- do not score small offsets
			end 
			if canAccept  then 
				table.insert(options, {
						nodePair = { leftNode, rightNode},
						correctedAngle2 = correctedAngle2,
						correctedAngle3 = correctedAngle3,
						scores = {
							distance,
							routeDistance,
							scoredAngle(correctedAngle),
							scoredAngle(interceptAngle),
							scoredAngle(correctedAngle2),
							scoredAngle(correctedAngle3),
							util.countNearbyEntities(otherNodePos, params.targetSeglenth, "BASE_EDGE"),
							util.countNearbyEntities(otherNodePos,250, "CONSTRUCTION"),
							util.isUnderwater(otherNodePos) and 1 or 0,
							grad,
							distToOtherStation,
							distToOtherStation2,
							terrainOffset
						},
						
						-- the following is for debug purposes
						correctedAngleDeg = math.deg(correctedAngle), 
						correctedAngle2Deg = math.deg(correctedAngle2),
						isRightNode0 = isRightNode0,
						isLeftNode0 = isLeftNode0,
						correctedAngle3Deg = math.deg(correctedAngle3), 
						interceptAngleDeg = math.deg(interceptAngle),
						distance= distance,
					})
				trace("accepting nodes",rightNode," and ",leftNode, " for consideration")
			else 
				trace("rejecting node",rightNode," as it is too close to a junction edge?",isJunctionEdge,"   minEdgeLength=",minEdgeLength, " nearbyEdgeCount=",nearbyEdgeCount, " grad=",grad)
			end 
			::continue::
		end
	end
	local maxAngle = isIntermediateRoute and math.rad(65) or math.rad(75)
	if #options == 0 then 
		trace("WARNING! evaluateBestJoinNodePair: no options were found, aborting")
		return 
	end
	if isStationTerminus then 
		maxAngle = math.huge 
	end
	local minAngle = math.rad(360)
	for i = 1 ,#options do  
		minAngle = math.min(minAngle, options[i].correctedAngle3)
	end 
	if minAngle > maxAngle then 
		trace("WARNING! The min angle ",math.deg(minAngle), "was greater than the max permitted angle",math.deg(maxAngle), " attempting to correct")
		if recursionDepth == 0 then -- prevent a route re-joining back onto itself
			maxAngle = math.min(minAngle, math.rad(90))
			--maxAngle = minAngle
		end
	end 
	local oldOptions = options 
	local options = {}
	for i = 1, #oldOptions do 
		local option = oldOptions[i]
		if option.correctedAngle3 <= maxAngle then 
			table.insert(options, option)
		else 
			trace("Rejecting option with nodes",option.nodePair[1],option.nodePair[2]," as the angle was too high",option.correctedAngle2Deg)
		end 
	end 
	
	
	trace("About to choose best node pair from ",#options," options of original ",#leftNodes," and ",#edges, "isStationTerminus?",isStationTerminus)
	
	local weights = {
		100 , -- distance 
		15,  -- routeDistance (n.b. unreliable)
		10, -- correctedAngle
		10, -- interceptAngle 
		15, -- correctedAngle2 
		15, -- correctedAngle3 
		15, -- nearbyEdges 
		15, -- nearbyConstructions
		15, -- water point
		15,  -- grad
		25, -- dist to other pos
		25, -- dist to other pos2
		25, -- terrainHeight
	}
	if util.tracelog and #options < 100 then 
		debugPrint({nodeOptions = util.evaluateAndSortFromScores(options,weights )})
	end
	if #options == 0 then 
		trace("WARNING! evaluateBestJoinNodePair: no options were after filteing, aborting")
		return 
	end
	local nodePair= util.evaluateWinnerFromScores(options,weights ).nodePair
	if util.tracelog then 
		trace("evaluateBestJoinNodePair: The chosen nodePair was",nodePair[1],nodePair[2], " distBetweenNodes=",util.distBetweenNodes(nodePair[1],nodePair[2]))
		debugPrint({evaluateBestJoinNodePair={ 
			node1 = util.getEntity(nodePair[1]),
			node2 = util.getEntity(nodePair[2])
		}, useSortedEdges=useSortedEdges})
	end 
	return nodePair
end
local function findShortestDistanceNodePair(leftNodes, rightNodes, params) 
	if not leftNodes or not rightNodes then
		print("ERROR: No left or right nodes")
		return
	end 
	local doubleTrackLookup = {}
	
	local result
	local minDist = 5
	if params and params.isDoubleTrack then 
		local expectedDistance = params.isTrack and params.trackWidth or util.getStreetWidth(params.preferredHighwayRoadType)+params.highwayMedianSize
		local tolerance = params.isTrack and 1 or 5
		for leftOrRight, nodes in pairs({leftNodes, rightNodes}) do	
			local station = leftOrRight == 1 and params.station1 or params.station2 
			local isTerminus = station and params.terminusIdxs and params.allStations and params.terminusIdxs[util.indexOf(params.allStations, station)]
			trace("Inspecting nodes near station", station, " isTerminus?",isTerminus, " stationIndex?",station and params.allStations and util.indexOf(params.allStations, station), " terminusIdxs?",params.terminusIdxs)
			if util.tracelog then debugPrint({allStations = params.allStations, terminusIdxs=params.terminusIdxs}) end
			for ___,  node1 in pairs(nodes) do 
				for ___, node2 in pairs(nodes) do 
					if node1~=node2 then
						local dist = util.distBetweenNodes(node1, node2)
						local condition = math.abs(dist-expectedDistance) < tolerance  
						if params.isTrack and util.isNodeConnectedToFrozenEdge(node1) then -- two tracks either side of a 5m platform
							condition = condition or  math.abs(dist-2*expectedDistance)< tolerance
						end 
						if params.useDoubleTerminals and not isTerminus then 
							condition = condition and dist > params.trackWidth + tolerance
						end 
						if condition then
							doubleTrackLookup[node1]=node2
							doubleTrackLookup[node2]=node1
						end
					end
				end
			end
		end
		minDist = expectedDistance+10
	end
	leftNodes = checkForDepotProximity(leftNodes, params, params.station1,  params.station2)
	rightNodes = checkForDepotProximity(rightNodes, params, params.station2, params.station1)
	if params.allStations then 
		local index1 = util.indexOf(params.allStations,params.station1)
		local index2 = util.indexOf(params.allStations,params.station2)
		local isGoingUp = index2 == index1+1 or index1 == #params.allStations and index2 == 1
		local priorStation = isGoingUp and index1 - 1 or index1 + 1
		local nextStation = isGoingUp and index2 + 1 or index2 - 1
		if priorStation < 1 or priorStation > #params.allStations then 
			if params.isCircularRoute then 
				priorStation = priorStation < 1 and #params.allStations or 1
				trace("PriorStation was out of bounds, set to",priorStation)
			else 
				priorStation = nil
			end 
		end 
		if nextStation < 1 or nextStation > #params.allStations then 
			if params.isCircularRoute then 
				nextStation = nextStation < 1 and #params.allStations or 1
				trace("nextStation was out of bounds, set to",nextStation)
			else 
				nextStation = nil
			end 
		end 
		trace("Inspecting prior and next station, priorStation=",priorStation,"index1=",index1,"index2=",index2,"nextStation=",nextStation, "isGoingUp=",isGoingUp, " there were ",#params.allStations," stations in total")
		if priorStation and params.allStations[priorStation] then 
			--local priorNodes = routeBuilder.getDeadEndNodesForStation(priorStation) 
			local filteredNodes = {}
			local priorStationPos = util.getStationPosition(params.allStations[priorStation])
			local station1Pos = util.getStationPosition(params.station1)
			local station2Pos = util.getStationPosition(params.station2)
			for terminal, nodes in pairs(util.getTerminalToFreeNodesMapForStation(params.station1)) do 
				trace("At station1 ",params.station1, "there were ",#nodes," for terminal ",terminal)
				if #nodes > 1 then 
					local node1 = util.nodePos(nodes[1])
					local node2 = util.nodePos(nodes[2])
					--local relativeDistance1 = math.abs(util.distance(node1, station1Pos)-util.distance(node2, station1Pos))
					local relativeDistance1 = math.abs(util.distance(node1, station2Pos)-util.distance(node2, station2Pos))
					local relativeDistance2 = math.abs(util.distance(node1, priorStationPos)-util.distance(node2, priorStationPos))
					trace("Inspecing nodes, relativeDistance1 was ",relativeDistance1," relativeDistance2 was ",relativeDistance2)
					if math.abs(relativeDistance1-relativeDistance2) < 80 then 
						--relativeDistance1 = relativeDistance1 / util.distance(station1Pos, 
						trace("Short relative distance detected switching to use percent difference")
					end 
					if relativeDistance2 > relativeDistance1 then 
						
						if util.distance(node1, priorStationPos) > util.distance(node2, priorStationPos) then 
							trace("Filtering nodes, adding ", nodes[2])
							filteredNodes[nodes[2]]=true
						else 
							trace("Filtering nodes, adding ", nodes[1])
							filteredNodes[nodes[1]]=true
						end 
					end
				end 
			end 
			if util.size(filteredNodes) > 0 then 
				local oldLeftNodes = leftNodes 
				leftNodes = {}
				for i , node in pairs(oldLeftNodes) do 
					if not filteredNodes[node] then 
						table.insert(leftNodes, node)
					end
				end
				if #leftNodes == 0 then 
					trace("WARNING! Left nodes was zero after filtering")
					if util.tracelog then debugPrint({oldLeftNodes=oldLeftNodes, filteredNodes=filteredNodes}) end 
					leftNodes = oldLeftNodes
				end 
			end
		end 
		
		if nextStation then 
			--local nextNodes = routeBuilder.getDeadEndNodesForStation() 
				--local priorNodes = routeBuilder.getDeadEndNodesForStation(priorStation) 
			local filteredNodes = {}
			local nextStationPos = util.getStationPosition(params.allStations[nextStation])
			local station1Pos = util.getStationPosition(params.station1)
			local station2Pos = util.getStationPosition(params.station2)
			for terminal, nodes in pairs(util.getTerminalToFreeNodesMapForStation(params.station2)) do 
				trace("At station2 ",params.station2, "there were ",#nodes," for terminal ",terminal)
				if #nodes > 1 then 
					local node1 = util.nodePos(nodes[1])
					local node2 = util.nodePos(nodes[2])
					local relativeDistance1 = math.abs(util.distance(node1, station1Pos)-util.distance(node2, station1Pos))
					local relativeDistance2 = math.abs(util.distance(node1, nextStationPos)-util.distance(node2, nextStationPos))
					trace("Inspecing nodes, relativeDistance1 was ",relativeDistance1," relativeDistance2 was ",relativeDistance2)
					if relativeDistance2 > relativeDistance1 then 
						trace("Filtering nodes")
						if util.distance(node1, nextStationPos) > util.distance(node2, nextStationPos) then 
							trace("Filtering nodes, adding ", nodes[2])
							filteredNodes[nodes[2]]=true
						else 
							trace("Filtering nodes, adding ", nodes[1])
							filteredNodes[nodes[1]]=true
						end 
					end
				end 
			end  
			if util.size(filteredNodes) > 0 then 
				local oldRightNodes = rightNodes 
				rightNodes = {}
				for i , node in pairs(oldRightNodes) do 
					if not filteredNodes[node] then 
						table.insert(rightNodes, node)
					end
				end
				if #rightNodes == 0 then 
					trace("WARNING! Left nodes was zero after filtering")
					if util.tracelog then debugPrint({oldRightNodes=oldRightNodes, filteredNodes=filteredNodes}) end 
					rightNodes = oldRightNodes
				end 				
			end 
		end 
	end 
	
	result = util.findShortestDistanceNodePair(leftNodes, rightNodes, minDist, params)
	if util.tracelog then 
		if not result then 
			trace("ERROR! No result found")
		end
		debugPrint({leftNodes=leftNodes, rightNodes=rightNodes, result =result})
	end
	if not result then 
		return 
	end 
	if params and params.isDoubleTrack then
		local secondLeftNode = doubleTrackLookup[result[1]]
		if not secondLeftNode then secondLeftNode = result[1] end
		table.insert(result, secondLeftNode)
		local secondRightNode = doubleTrackLookup[result[2]]
		if not secondRightNode then secondRightNode = result[2] end
		table.insert(result, secondRightNode)
		if util.tracelog then debugPrint({result=result, doubleTrackLookup=doubleTrackLookup}) end
		return result 
	else
		return result
	end
			
end

local function getDeadEndNodesForStation(stationId, spurConnect, range, params) 
	local result = {}
	trace("Getting nodes for station",stationId)
	local freeTerminals = util.countFreeTerminalsForStation(stationId)
	
	if params and params.connectNodes and params.connectNodes[stationId] then 
		for i, nodePos in pairs(params.connectNodes[stationId]) do 
			table.insert(result, util.searchForNearestNode(nodePos).id)
		end 
		return result
	end 
	
	
	if params and params.isQuadrupleTrack and (util.getConstructionForStation(stationId).params.buildThroughTracks or util.getConstructionForStation(stationId).params.throughtracks == 1 ) and freeTerminals==2 then 
		local freeNodesForFreeTerminals = util.getFreeNodesForFreeTerminalsForStation(stationId)
		local allNodes = util.getAllFreeNodesForStation(stationId)
		trace("Filtering to central nodes") 
		for i, node in pairs(allNodes) do
			if #util.getTrackSegmentsForNode(node)==1 and not util.contains(freeNodesForFreeTerminals, node) then 
				trace("Adding node",node," for consideration as a free node free terminal for stationId",stationId)
				table.insert(result, node) 
			end 
		end
		
	elseif freeTerminals > 3 then 
		local terminalToFreeNodes  = util.getTerminalToFreeNodesMapForStation(stationId)
		local highestTerminal = 0
		local lowestTerminal = math.huge 
		for terminal, nodes in pairs(terminalToFreeNodes) do 
			if #nodes > 0 and util.isFreeTerminalOneBased(stationId, terminal)  then 
				highestTerminal = math.max(highestTerminal, terminal)
				lowestTerminal = math.min(lowestTerminal, terminal)
			end
		end 
		
		trace("Filtering for nodes between",highestTerminal ," and ",lowestTerminal)
		for terminal, nodes in pairs(terminalToFreeNodes) do 
			if terminal < highestTerminal and terminal > lowestTerminal then 
				for i, node in pairs(nodes) do 
					if #util.getTrackSegmentsForNode(node)==1 then 
						local canAccept = true
						local useDoubleTerminals = params and params.useDoubleTerminals
						local halfway = (highestTerminal-lowestTerminal)/2
						if useDoubleTerminals  and false then 
							canAccept = math.abs(terminal - halfway)<=1 or terminal%2==1  
							trace("useDoubleTerminals check at ",halfway, "terminal=",terminal, "canAccept =",canAccept)
						end 
						if canAccept then 
							trace("Adding node",node," for consideration as a free node free terminal for stationId",stationId)
							table.insert(result, node) 
						end
					end 
				end 
			end
		end 
	else 
		for i , node in pairs(util.getFreeNodesForFreeTerminalsForStation(stationId)) do 
			if #util.getTrackSegmentsForNode(node)==1 then 
				trace("Adding node",node," for consideration as a free node free terminal for stationId",stationId)
				table.insert(result, node) 
			end 
		end
	end
	local allStationNodes ={} 
	for i, node in pairs(util.getAllFreeNodesForStation(stationId)) do 
		allStationNodes[node]=true 
	end 
	
	--if #result == 0 then  
	local function searchForOtherTrackNodes(p, range) 
		for i, node in pairs(util.searchForDeadTrackNodes(p, 750)) do 
			local isOk = not allStationNodes[node] and not util.isFrozenNode(node) and not util.isFrozenEdge(util.getTrackSegmentsForNode(node)[1]) -- just one edge as it is dead end
			trace("getDeadEndNodesForStation.searchForOtherTrackNodes: Insepcting node ",node, " isOk?",isOk)
			if isOk and #pathFindingUtil.findRailPathBetweenEdgeAndStationFreeTerminal(util.getTrackSegmentsForNode(node)[1], stationId, true) > 0 then 
				trace("getDeadEndNodesForStation.searchForOtherTrackNodes: adding node",node,"for consideration as a station connect node")
				table.insert(result, node)
			end
		end 
	end
	searchForOtherTrackNodes(util.getStationPosition(stationId), 750) 
	--end 
	trace("Completed check for nearby dead end nodes, results so far",#result)
	if spurConnect then 
		local spurResult = {} 
		local exlcudeNodes = {}
		for i, node in pairs(result) do 
			exlcudeNodes[node]=true
		end
		for i, node in pairs(util.getAllFreeNodesForStation(spurConnect)) do 
			exlcudeNodes[node]=true 
		end 
		if not range then range = 350 end
		local searchPos = util.getStationPosition(stationId)
		trace("About to check joinNodePos for ",stationId)
		if params and params.joinNodePos then 
			if params.joinNodePos[stationId] then 
				trace("Found joinNodePos for ",stationId,"Searching for nodes near node ",params.joinNodePos[stationId].x, params.joinNodePos[stationId].y)
				searchPos =  params.joinNodePos[stationId]
			elseif params.joinNodePos[spurConnect] then 
		
				searchPos =   params.joinNodePos[spurConnect]
				trace("Found joinNodePos for spurConnect ",spurConnect,"Searching for nodes near node ",searchPos.x, searchPos.y)
			else 
				trace("Did not find a joinNodePos for either",stationId,"or",spurConnect)
			end			
		end
		for i ,node in pairs(util.searchForEntities(searchPos, range, "BASE_NODE")) do
			local trackEdges = util.getTrackSegmentsForNode(node.id)
			if #trackEdges==1 then -- filters for dead end track nodes
				if not exlcudeNodes[node.id] and not util.isFrozenNode(node.id) and not util.isFrozenEdge(trackEdges[1]) and util.getEdgeLength(trackEdges[1])>4  then
					trace("Adding node",node.id," for consideration as a dead end track node")
					table.insert(spurResult, node.id)
				end
			end
		end
		return spurResult
	end
	if #result == 0 then 
		
		if params and params.station1 and params.station2 then 
			local p0 = util.getStationPosition(params.station1)
			local p1 = util.getStationPosition(params.station2)
			local range = util.distance(p0, p1)
			local midPoint = 0.5*(p0+p1)
			trace("No results found, attempting to expand search at ", midPoint.x,midPoint.y," at a range of ",range)
			searchForOtherTrackNodes(midPoint, range)
		end 
	end
	
	trace("Finished getting dead end nodes for station",stationId," num nodes was",#result)
	return result 
end
routeBuilder.getDeadEndNodesForStation = getDeadEndNodesForStation

local function applyHeightOffset(splits, offset, i, maxGradient)
	if offset == 0 then 
		return 
	end
	local p = splits[i].p1
	p.z = p.z+offset
	local distFromStart = vec2.distance(splits[i].p1, splits[1].p1)
	local distFromEnd = vec2.distance(splits[#splits].p1, splits[i].p1)
	local maxHeight = math.min(splits[1].newNode.comp.position.z+maxGradient*distFromStart, splits[#splits].newNode.comp.position.z+maxGradient*distFromEnd) 
	
	local minHeight = math.min(splits[1].newNode.comp.position.z-maxGradient*distFromStart, splits[#splits].newNode.comp.position.z-maxGradient*distFromEnd) 
	trace("apply height offset at ",i," offset=",offset, " old height=",splits[i].newNode.comp.position.z," new height=",p.z,"constrainting to ",maxHeight,minHeight)
	p.z = math.min(maxHeight, math.max(minHeight, p.z))
	trace("After constraints height was",p.z)
	splits[i].newNode.comp.position.z = p.z
	if splits[i].doubleTrackNode then 
		trace("applying height offset to double track node")
		splits[i].doubleTrackNode.comp.position.z = p.z
		if splits[i].tripleTrackNode then 
			trace("applying height offset to triple track node")
			splits[i].tripleTrackNode.comp.position.z = p.z
		end 
		if splits[i].quadroupleTrackNode then 
			trace("applying height offset to quadruple track node")
			splits[i].quadroupleTrackNode.comp.position.z = p.z
		end 
		
	end
	if splits[i-1] then
		local p2 = splits[i-1].p1
		local deltaz = p.z - p2.z
		local dist = vec2.distance(p, p2)
		local grad =  (deltaz/dist)
		if math.abs(grad) > maxGradient +0.01 then
			local maxDeltaZ = dist * (maxGradient)
			local correction = math.abs(deltaz)-maxDeltaZ
			trace("needing to apply correction",correction, " dist=",dist," deltaz=",deltaz," maxDeltaZ=",maxDeltaZ,"grad=",grad)
			applyHeightOffset(splits, deltaz < 0 and -correction or correction, i-1, maxGradient)
		end
	end
	if splits[i+1] then
		local p2 = splits[i+1].p1
		local deltaz = p.z - p2.z
		local dist = vec2.distance(p, p2)
		local grad =  (deltaz/dist)
		if math.abs(grad) > maxGradient +0.01 then
			local maxDeltaZ = dist * (maxGradient)
			local correction = math.abs(deltaz)-maxDeltaZ
			trace("needing to apply correction",correction, " dist=",dist," deltaz=",deltaz," maxDeltaZ=",maxDeltaZ,"grad=",grad)
			applyHeightOffset(splits, deltaz < 0 and -correction or correction, i+1, maxGradient)
		end
	end
end

local function setPositionOnNode(newNode, p)
	newNode.comp.position.x = p.x
	newNode.comp.position.y = p.y
	newNode.comp.position.z = p.z
end

local function newNodeWithPosition(p, entityId)
	local newNode =  api.type.NodeAndEntity.new()
	setPositionOnNode(newNode, p)
	if entityId then 
		newNode.entity = entityId
	end
	
	return newNode
end
local function copyNodeWithZoffset(node, zoffset, entityId) 
	local newNode = newNodeWithPosition(util.nodePos(node), entityId)
	newNode.comp.position.z = newNode.comp.position.z + zoffset 
	return newNode
end 
local function newDoubleTrackNode(p, t, entityId) 
	return newNodeWithPosition(util.doubleTrackNodePoint(p, t), entityId)
end





local function setTangentPreservingMagnitude(tangent, t, reduction)
	local existingLength = vec3.length(tangent)
	local angle = util.signedAngle(tangent, t)
	if reduction then 
		existingLength = existingLength - reduction
	end
	trace("Setting tangent, existing length=",existingLength," angle change=",math.deg(angle))
	setTangent(tangent, existingLength*vec3.normalize(t))
end

function routeBuilder.getBridgeType()
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	if  util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom  then
		return cement
	elseif  util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom  then
		return iron
	else 
		return api.res.bridgeTypeRep.find("stone.lua")
	end
end


 local function findBridgeType(entity, split, params)
	trace("Finding bridgeType, split was ",split," needsSuspensionBridge?", (split and split.needsSuspensionBridge or false))
	if split and util.isSuspensionBridgeAvailable() and 
		(--split.bridgeLength and split.bridgeLength > 5 or
		 split.bridgeHeight and split.bridgeHeight > 50
		or split.needsSuspensionBridge)
		and not (params and params.isHighway and params.isElevated)
		and not split.segmentsPassingAbove 
		and not split.forbidSuspension
	then
		if util.isCableBridgeAvailable() and params and params.isHighSpeedTrack then 
			return api.res.bridgeTypeRep.find("cable.lua")
		else 
			return api.res.bridgeTypeRep.find("suspension.lua")
		end 
	end
 
 -- see if "cement" is available, fall back to stone 
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	if  util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom 
		and (entity.type==0 or entity.trackEdge.trackType==api.res.trackTypeRep.find("high_speed.lua")) or params and params.isHighway then
		return cement
	elseif  util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom  then
		return iron
	else 
		return api.res.bridgeTypeRep.find("stone.lua")
	end
end

 local function setCrossingBridge(entity, params, span, prevEntity, removeSuspension, actualDeltaz)
	-- need to avoid using stone because it very frequently has a pillar bridge collision
	local stone = api.res.bridgeTypeRep.find("stone.lua")
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	local cable =  api.res.bridgeTypeRep.find("cable.lua")
	local suspension = api.res.bridgeTypeRep.find("suspension.lua")
	local cementAvailable = util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom 
	local cableAvailable = util.year() >= api.res.bridgeTypeRep.get(cable).yearFrom
	local bridgeTypeToUse =  iron
	-- personal choice, the iron bridge is asthetically pleasing for crossings, use unless it would slow our trains significantly
	if cementAvailable and entity.type == 0 or 
		entity.type == 1   and (params.isHighSpeedTrack or not prevEntity and entity.trackEdge.trackType == api.res.trackTypeRep.find("high_speed.lua")) or params.isHighway then 
		bridgeTypeToUse = cement
	end
	if (not span or span > params.maxCrossingBridgeSpan) and util.isSuspensionBridgeAvailable() then 
		if not removeSuspension and actualDeltaz and math.abs(actualDeltaz) >= params.minZoffsetSuspension then 
			bridgeTypeToUse = suspension
		end
		if cableAvailable then 
			bridgeTypeToUse = cable
		end
	end 
	removeSuspension = removeSuspension or actualDeltaz and params and math.abs(actualDeltaz)<params.minZoffsetSuspension
	trace("Setting bridgetype, bridgeTypeToUse=",bridgeTypeToUse," cement=",cement," iron=",iron," removeSuspension=",removeSuspension)
	-- if it has a bridge type already do not override unless it is stone 
	if entity.comp.type ~= 1 or entity.comp.typeIndex==stone or removeSuspension and (entity.comp.typeIndex == suspension or entity.comp.typeIndex==cable) then
		entity.comp.type = 1
		entity.comp.typeIndex = bridgeTypeToUse
	else 
		trace("Not setting bridge, already had with type",entity.comp.typeIndex, " which is ",api.res.bridgeTypeRep.getName(entity.comp.typeIndex))
	end 
	if entity.type == 0 and string.find(api.res.streetTypeRep.getName(entity.streetEdge.streetType), "old")  then 
		entity.streetEdge.streetType = api.res.streetTypeRep.find(string.gsub(api.res.streetTypeRep.getName(entity.streetEdge.streetType), "old", "new")) -- dirt road textures don't look good on modern bridges
	end
	
	if prevEntity and prevEntity.comp.type == 1 then 
		if prevEntity.comp.typeIndex ~= stone and (prevEntity.comp.typeIndex~=suspension or actualDeltaz and  actualDeltaz  >= params.minZoffsetSuspension) then 
			trace("Using the existing type ",api.res.bridgeTypeRep.getName(prevEntity.comp.typeIndex)," actualDeltaz was ",actualDeltaz)
			entity.comp.typeIndex = prevEntity.comp.typeIndex -- keep the bridge type consistent if already in a bridge span
		end
	end
 
 end
local newSignalYearFrom 
local function buildSignal(edgeObjectsToAdd, entity, left, signalParam, bothWays)
	if not newSignalYearFrom then 
		newSignalYearFrom =  api.res.modelRep.get(api.res.modelRep.find(newSignalType)).metadata.availability.yearFrom
	end 
	local signalType = util.year() >= newSignalYearFrom and newSignalType or oldSignalType
	if not routeBuilder.signalCount then 
		routeBuilder.signalCount = 0 
	end
	if not signalParam then 
		signalParam = 0.5
	end
	if #entity.comp.objects > 0 then 
		trace("WARNING! Attempting to place more than on edge object on entity",entity.entity," aborting") 
		return 
	end
	routeBuilder.signalCount = routeBuilder.signalCount+1
	local newSig = api.type.SimpleStreetProposal.EdgeObject.new()
	newSig.left = left
	newSig.oneWay = true 

	newSig.playerEntity = api.engine.util.getPlayer()
	newSig.edgeEntity = entity.entity
	newSig.name = _("AI").." ".._("Signal").." "..tostring(routeBuilder.signalCount)
	newSig.model = signalType
	if bothWays and allowTwoWaySignals then -- while debugging issues with "wrong way" signals 
		newSig.oneWay = false 
		newSig.model =string.gsub(signalType, "_one_way", "")
	end
	newSig.param = signalParam
	entity.comp.objects = { {-(1+#edgeObjectsToAdd), api.type.enum.EdgeObjectType.SIGNAL}}
	trace("Built signal with name",newSig.name)
	table.insert(edgeObjectsToAdd,newSig)
end

routeBuilder.buildSignal = buildSignal

local function buildSignals(edgeObjectsToAdd, i, nodecount, entity, entity2, backwards, simplifiedSignalling)
	
	local signalParam =  i<=2 and 0.1 or i>= nodecount-1 and 0.9 or 0.5
	if backwards then
		signalParam = 1-signalParam
	end
	if simplifiedSignalling then 
		signalParam = 0.5 
	end
	buildSignal(edgeObjectsToAdd, entity, backwards, signalParam)
	buildSignal(edgeObjectsToAdd, entity2,not backwards, signalParam)
	
end

local function canUseBridgeForCrossing(requiredSpan, params) 
	local result = requiredSpan <= params.maxCrossingBridgeSpan or util.isSuspensionBridgeAvailable() and requiredSpan <= params.maxCrossingBridgeSpanSuspension
	trace("Checking if bridge can be used to span ", requiredSpan, " result was ", result)
	return result
end

function routeBuilder.applyTangentCorrection(edgesToAdd, nodesToAdd) 
	local newNodeToSegmentMap = {}
	
	for i, edge in pairs(edgesToAdd) do 
		for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
			if not newNodeToSegmentMap[node] then 
				newNodeToSegmentMap[node]={}
			end 
			table.insert(newNodeToSegmentMap[node], -edge.entity)
		end 
--		assert(edgesToAdd[edge
	end 
	
	local newNodeToPositionMap = {}
	local newNodeMap = {}
	for i, newNode in pairs(nodesToAdd) do 
		newNodeToPositionMap[newNode.entity]=util.v3(newNode.comp.position)
		newNodeMap[newNode.entity]=newNode
	end
	 
	local function getNodePosition(node) 
		if node < 0 then 
			return newNodeToPositionMap[node]
		else 
			return util.nodePos(node)
		end
	end
	for i, edge in pairs(edgesToAdd) do
		local t0 = util.v3(edge.comp.tangent0)
		local t1 = util.v3(edge.comp.tangent1)
		assert(edge.comp.node0~=edge.comp.node1, "Edge had same nodes"..edge.comp.node0.." "..edge.comp.node1.." entity="..edge.entity)
		local p0 = getNodePosition(edge.comp.node0)
		local p1 = getNodePosition(edge.comp.node1)
		if not p0 or not p1 then 
			debugPrint(nodesToAdd)
			debugPrint(edge)
			trace("WARNING! Could not find position, p0=",p0,"p1=",p1)
			local lastNode = allNodesToAdd[#allNodesToAdd] 
			if lastNode.entity == edge.comp.node1 then 
				trace("But I found it in the last node in allNodesToAdd!!") 
				p1 = util.v3(lastNode.comp.position)
			end
			local lastNode = nodesToAdd[#nodesToAdd] 
			if lastNode.entity == edge.comp.node1 then 
				trace("But I found it in the last node in nodesToAdd!!") 
				p1 = util.v3(lastNode.comp.position)
			end
		end
		local lt0 = vec3.length(t0)
		local lt1 = vec3.length(t1)
		local dist2d = vec2.distance(p0, p1)
		local ourGrad = (p1.z - p0.z)/dist2d
		for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
			local isNode0 = j == 1
			if node < 0 then 
				local segs =newNodeToSegmentMap[node]
				if #segs == 2 then 
					local otherSegId = segs[1]==-edge.entity and segs[2] or segs[1]
					local otherSeg = edgesToAdd[otherSegId]
					local theirP0 = getNodePosition(otherSeg.comp.node0)
					local theirP1 = getNodePosition(otherSeg.comp.node1)
					local otherNode = otherSeg.comp.node0 == node and otherSeg.comp.node1 or otherSeg.comp.node0 
					local theirNode0 =  node == otherSeg.comp.node0 
					local theirGrad = (theirP1.z-theirP0.z)/vec2.distance(theirP1, theirP0)
					if theirNode0 == isNode0 then -- direction reversal
						theirGrad = -theirGrad
					end
					local avgGrad = (ourGrad+theirGrad)/2
					trace("at i=",i,"avgGrad was",avgGrad," ourGrad=",ourGrad,"theirGrad=",theirGrad,"isNode0?",isNode0,"theirNode0?",theirNode0,"node=",node," entity=",edge.entity," theirEntity=",otherSeg.entity," at i=",i," otherSegId=",otherSegId)
					if isNode0 then 
						--edge.comp.tangent0.z = dist2d*avgGrad
					else 
						--edge.comp.tangent1.z = dist2d*avgGrad
					end 
					if theirNode0 then --  their tangent fixed in their pass
						--otherSeg.comp.tangent0.z = vec3.length(otherSeg.comp.tangent0)*avgGrad
					else 
						--otherSeg.comp.tangent1.z = vec3.length(otherSeg.comp.tangent1)*avgGrad
					end 
					--if params.isAutoCorrectTangents then 
					local ourTangent = p1 - p0 
					local theirTangent = theirP1 - theirP0 
					if theirNode0 == isNode0 then 
						theirTangent = -1*theirTangent
					end 
					local newTangent = vec3.length(ourTangent)*vec3.normalize(ourTangent+theirTangent)
					if isNode0 then 
						util.setTangent2d(edge.comp.tangent0, newTangent)  
					else 
						util.setTangent2d(edge.comp.tangent1, newTangent)
					end 
					--end 
				end 
			end
		end 
	end
end


local function tryBuildDepotConnection(callback, depot, params, offsetplus, useDoubleTrackNode)
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local oldToNewEdgeMap = {}
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	local function nextNodeId()
		return -1000-#nodesToAdd
	end
	local function getOrMakeReplacedEdge(edgeId) 
		if not oldToNewEdgeMap[edgeId] then 
			oldToNewEdgeMap[edgeId] = util.copyExistingEdge(edgeId, nextEdgeId())
			table.insert(edgesToAdd, oldToNewEdgeMap[edgeId])
			table.insert(edgesToRemove, edgeId)
		end 
		return oldToNewEdgeMap[edgeId]
	end 
	
	local trackWidth = params.trackWidth
	if not depot or not api.engine.entityExists(depot) or not util.getComponent(depot, api.type.ComponentType.CONSTRUCTION) then
		callback({},true)
		return true
	end
	if params.connectedDepots and params.connectedDepots[depot] then 
		callback({},true)
		return true
	end 
	
	if params.isElevated or params.isUnderground then 
		useDoubleTrackNode = true 
	end
	local depotConstruction = util.getComponent(depot, api.type.ComponentType.CONSTRUCTION)
	if not depotConstruction.depots[1] then 
		trace("WARNING! Given a depot ",depot,"but it does not have any depots")
		callback({},true)
		return true
	end 
	local depotEdgeId = depotConstruction.frozenEdges[1]
	local depotEdge = util.getEdge(depotEdgeId)
	local t1 = util.v3(depotEdge.tangent1)
	local depotNode = depotEdge.node1
	local existingDepotSegs = util.getTrackSegmentsForNode(depotNode) 
	local depotPos = util.nodePos(depotNode)
	local excludeNodes = {}
	excludeNodes[depotEdge.node0]=true 
	excludeNodes[depotEdge.node1]=true
	local town = util.searchForFirstEntity(depotPos, 500, "TOWN")
	if town then 
		trace("Building depot connection at ",town.name)
	end
	local station
	for __ , s in pairs(game.interface.getEntities({radius = 200, pos={depotPos.x, depotPos.y}}, {type="STATION", includeData=true})) do
		if s.carriers.RAIL then 
			station =s 	
			break
		end
	end
	local isTerminus = town and params.buildTerminus and params.buildTerminus[town.id] and station and not station.cargo	
	if #existingDepotSegs > 1 and not isTerminus then 
		local otherEdge = existingDepotSegs[1] == depotEdgeId and existingDepotSegs[2] or existingDepotSegs[1]
		table.insert(edgesToRemove, otherEdge)
		local otherEdgeFull = util.getEdge(otherEdge)
		excludeNodes[otherEdgeFull.node0]=true 
		excludeNodes[otherEdgeFull.node1]=true
	end
	
	
	trace("depot node was",depotNode)
	
	--local searchRadius = 200+offsetplus
	

	
	
	local stationPos 
	if station then 
		stationPos = util.v3fromArr(station.position)
	else 
		local nearestNode = util.searchForNearestNode(depotPos, 100, function(node) return node.id ~= depotEdge.node0 and node.id ~= depotEdge.node1 and #util.getTrackSegmentsForNode(node.id)>0  and not util.isFrozenNode(node.id) end)
		stationPos = util.nodePos(nearestNode.id)
	end
	local stationLength = params.stationLength
	if station then 
		isTerminus = util.isStationTerminus(station.id)
		stationLength = routeBuilder.constructionUtil.getStationLength(station.id)	
	end

	
	if isTerminus then
		local depotSegs = util.getTrackSegmentsForNode(depotNode)
		if  #depotSegs== 1 then 
			trace("Building intro track for terminus")
			local length = (stationLength - 60)
			if params and params.crossoversBuilt and params.crossoversBuilt[station.id] or params.alwaysDoubleTrackPassengerTerminus then 
				trace("Increasing depot offset by" , params.crossoversBuilt[station.id]) 
				length = length + params.crossoversBuilt[station.id] 
			end 
			local p = depotPos + length*vec3.normalize(t1)
			if params.extraOffsetFactor ~= 0 then 
				p = util.nodePointPerpendicularOffset(p, t1, params.extraOffsetFactor*params.trackWidth) 
			end
			local newNode = newNodeWithPosition(p, nextNodeId())
			local entity = api.type.SegmentAndEntity.new()
			entity.entity = nextEdgeId()
			entity.type=1
			entity.trackEdge.trackType = params.isHighSpeedTrack and api.res.trackTypeRep.find("high_speed.lua") or api.res.trackTypeRep.find("standard.lua")
			entity.trackEdge.catenary = params.isElectricTrack
			entity.comp.node0 = depotNode 
			entity.comp.node1 = newNode.entity
			setTangent(entity.comp.tangent0, p - depotPos)
			setTangent(entity.comp.tangent1, p - depotPos)
			depotNode = newNode.entity
			depotPos = p
			table.insert(nodesToAdd, newNode)
			table.insert(edgesToAdd, entity)
		else 
			local otherEdgeId = depotSegs[1]==depotEdgeId and depotSegs[2] or depotSegs[1]
			local otherEdge = util.getEdge(otherEdgeId)
			depotNode = depotNode == otherEdge.node0 and otherEdge.node1 or otherEdge.node0 
			depotPos = util.nodePos(depotNode)
			trace("New depot node was ",depotNode," from otherEdgeId", otherEdgeId)
			excludeNodes[depotNode]=true
		end
	end
	if not stationLength or type(stationLength) == "boolean" then 
		stationLength = paramHelper.getStationLength()
	end 
	local stationTestPos =  depotPos + (30+stationLength/2)*vec3.normalize(t1)
	local depotBehindStation = station and util.distance(stationPos, stationTestPos) < util.distance(stationPos, depotPos)
	local idealDistance = depotBehindStation and 0 or params.targetSeglenth+offsetplus
	--local searchPos =  depotBehindStation and depotPos or searchRadius * vec3.normalize(t1) + depotPos
	local townName = town and town.name or "NO TOWN"
	trace("town was, ",townName, "depotBehindStation=",depotBehindStation, " stationTestPos=",stationTestPos.x, stationTestPos.y, " depotPos=",depotPos.x,depotPos.y, " util.distance(stationPos, stationTestPos)=",util.distance(stationPos, stationTestPos), "util.distance(stationPos, depotPos)=",util.distance(stationPos, depotPos), " paramHelper.getStationLength()=",stationLength, " (30+paramHelper.getStationLength()/2)=",(30+stationLength/2)," isTerminus=",isTerminus)
	--[[
	local dists = {}
	local distsToEdge = {}
	for __ , edge in pairs(game.interface.getEntities({radius = searchRadius, pos={searchPos.x, searchPos.y}}, {type="BASE_EDGE", includeData=true})) do 
		if edge.track then 
			local nodePos 
			if not util.isFrozenNode(edge.node0) and edge.node0 ~= depotNode then 
				nodePos = util.v3fromArr(edge.node0pos)
			elseif not util.isFrozenNode(edge.node1) and edge.node1 ~= depotNode then
				nodePos = util.v3fromArr(edge.node1pos)
			end
			if nodePos then 
				local dist  = math.abs(idealDistance-util.distance(depotPos, nodePos))
				table.insert(dists, dist)
				distsToEdge[dist]=edge
			end			
		end
	end
	table.sort(dists)   
	assert(#dists>0)]]--
	local searchPos = depotPos 
	if station and not isTerminus and stationLength <= 160 and not depotBehindStation then 
		trace("adjusting the search position back")
		searchPos = util.nodePos(depotEdge.node0)
	end
	local startNode = util.searchForNearestNode(searchPos, 100,
		function(node)
		return not excludeNodes[node.id]
			and not util.isFrozenNode(node.id) 
			and #util.getTrackSegmentsForNode(node.id)>0 
			and util.distance(util.nodePos(node.id), depotPos) > 0
			and math.abs(util.signedAngle(util.nodePos(node.id)-depotPos, t1)) < math.rad(120)
		end)
	if startNode then 
		startNode = startNode.id 
	else 
		trace("WARNING! No start node found near",searchPos.x, searchPos.y)
		return true
	end 
	
	if depotBehindStation  then 
		trace("Building depot behind station, connecting ",depotNode, " to ", startNode)
		local entity = util.copyExistingEdge(depotEdgeId, nextEdgeId())
		entity.comp.node0 = depotNode
		entity.comp.node1 = startNode 
		local dist = util.distBetweenNodes(depotNode, startNode)
		local stationTangent = util.getDeadEndNodeDetails(startNode).tangent 
		setTangent(entity.comp.tangent0, dist*vec3.normalize(t1))
		setTangent(entity.comp.tangent1, -dist*vec3.normalize(stationTangent))
		
		local newProposal = api.type.SimpleProposal.new() 
		newProposal.streetProposal.edgesToAdd[1] = entity
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), params.ignoreErrors or false)
		api.cmd.sendCommand(build, callback)
		util.clearCacheNode2SegMaps()
		return true
	end 
	local otherPossibleStartNode = util.findDoubleTrackNode(startNode)
	trace("Start node was ", startNode, " nextEdge was ",edgeId, " otherPossibleStartNode was ",otherPossibleStartNode) 
	if # util.getTrackSegmentsForNode(startNode) == 1  and  otherPossibleStartNode and # util.getTrackSegmentsForNode(otherPossibleStartNode)==2 then 
		startNode = otherPossibleStartNode
	end
	local startNodePos = util.nodePos(startNode)
	local nextSegs = util.getTrackSegmentsForNode(startNode)
	local edgeId  = util.isFrozenEdge(nextSegs[1]) and nextSegs[2] or nextSegs[1]
	if not station and not  util.isFrozenEdge(nextSegs[1]) and not  util.isFrozenEdge(nextSegs[2]) then 
		local testP = depotPos + (2*params.targetSeglenth)*vec3.normalize(t1)
		if util.distance(util.getEdgeMidPoint(nextSegs[1]), testP) < util.distance(util.getEdgeMidPoint(nextSegs[2]), testP) then 
			edgeId = nextSegs[1]
		else 
			edgeId = nextSegs[2]
		end 
	end 
	local initialEdge = edgeId
	local nextEdge = util.getEdge(edgeId)
	local startTangent = startNode == nextEdge.node0 and util.v3(nextEdge.tangent0) or util.v3(nextEdge.tangent1)
	local nextNode = startNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
	local priorEdge
	
	if params.isElevated then 
		offsetplus = math.max(offsetplus,2)
	end
	
 	for i = 1, offsetplus do 
		priorEdge = edgeId
		edgeId = util.findNextEdgeInSameDirection(edgeId, nextNode)
		trace("nextNode node was ", nextNode, " nextEdge was ",edgeId) 
		if not edgeId or util.isFrozenEdge(edgeId) then
			nextSegs = util.getTrackSegmentsForNode(startNode)
			trace("Detected problem num original segs was", #nextSegs)
			if #nextSegs == 3 and initialEdge ~= nextSegs[3] then 
				trace("Trying to start over, using ", nextSegs[3], " instead of ", initialEdge)
				initialEdge = nextSegs[3]
				edgeId = initialEdge 
				i=1
			else
				return false
			end
		end
		nextEdge = util.getEdge(edgeId)
		nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
	end
	local joinEdgeId = edgeId
	local joinEdge = nextEdge
	local proposedJoinNode
	local segTangent0 = util.v3(joinEdge.tangent0)
	local segTangent1 = util.v3(joinEdge.tangent1)
	local joinTangent
	local otherTangent
	if util.distance(depotPos, util.nodePos(joinEdge.node0)) > util.distance(depotPos, util.nodePos(joinEdge.node1)) then 
		proposedJoinNode = joinEdge.node0 
		joinTangent = -1*segTangent0
		otherTangent = -1*segTangent1
	else 
		proposedJoinNode = joinEdge.node1
		joinTangent = segTangent1
		otherTangent = segTangent0
	end
	local joinNode = proposedJoinNode
	
	local node1pos = util.nodePos(joinEdge.node1)
	local node0pos = util.nodePos(joinEdge.node0)
	local nodePos = util.isFrozenNode(joinEdge.node0) and node1pos or node0pos
	
	local backwards = util.distance(depotPos, node0pos) > util.distance(depotPos, node1pos)
					
	
	--local proposedJoinNode = util.isFrozenNode(joinEdge.node0) and joinEdge.node1 or joinEdge.node0
	 --= proposedJoinNode
	local otherNode = joinNode == joinEdge.node1 and joinEdge.node0 or joinEdge.node1
	trace("The otherNode was ", otherNode, " the joinNode was ", joinNode,"joinEdge was",joinEdgeId)
	
	local otherNode2 = util.findDoubleTrackNode(util.nodePos(otherNode),otherTangent)
	if otherNode2 and #util.getTrackSegmentsForNode(otherNode2) == 1 then 
		otherNode2 = util.findDoubleTrackNode(util.nodePos(otherNode),otherTangent, 2)
		trace("The otherNode2 loooks like a dead end node, trying another: ", otherNode2)
	end
	
	local angle = util.signedAngle(segTangent0, t1)
	trace("Depot angle was ",math.deg(angle), " depot connection backwards=",backwards)
	if math.abs(angle) > math.rad(90) then 
		--joinNode = joinEdge.node1
		joinTangent = -1*segTangent0
		startTangent = -1*startTangent
	end
	local nextSegs = util.getTrackSegmentsForNode(joinNode)
	--local priorEdge = joinEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
 
	local effectiveDepotNodePos = depotPos
	
	if useDoubleTrackNode then 
		local rightHanded = 1
		local testNodePos = util.nodePointPerpendicularOffset(depotPos, rightHanded * startTangent, trackWidth)
		local testNodePos2 = util.nodePointPerpendicularOffset(depotPos, -rightHanded * startTangent, trackWidth)
		local testDistance1 = util.distance(testNodePos, startNodePos)
		local testDistance2 = util.distance(testNodePos2, startNodePos)
		local checkDistance = util.distance(depotPos, startNodePos)
		if  testDistance1 < testDistance2 then 
			rightHanded =-1
		end
		 
		local extraOffSet = params.extraOffsetFactor*trackWidth
		local newNodePos = util.nodePointPerpendicularOffset(util.nodePos(otherNode), rightHanded * otherTangent, 2.5*trackWidth+extraOffSet)
		if otherNode2 and util.distance(newNodePos, util.nodePos(otherNode2)) < util.distance(newNodePos, util.nodePos(otherNode)) then 
			trace("increasing offset as we were closer to double track node")
			newNodePos = util.nodePointPerpendicularOffset(newNodePos, rightHanded * otherTangent, trackWidth)
		end 
		
		--[[if trialBuildBetweenPoints(depotPos, newNodePos) then
			trace("incorrect angle detected")
			rightHanded = -rightHanded
			newNodePos = util.nodePointPerpendicularOffset(nodePos, rightHanded * joinTangent, 2.5*trackWidth)
			if  trialBuildBetweenPoints(depotPos, newNodePos) then 
				trace("WARNING! SHOULD BE POSSIBLE")
			end
		end]]--
		trace("Using double track node for the depot, rightHanded=",rightHanded, " testDistance1=",testDistance1," testDistance2=",testDistance2, " checkDistance =",checkDistance, " newNodePos at ",newNodePos.x,newNodePos.y)
		
		effectiveDepotNodePos = newNodePos
		local nextSegs = util.getTrackSegmentsForNode(joinNode)
		local nextEdge  = joinEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
		local nextEdgeDetail = util.getEdge(nextEdge)
		local newJoinNode = joinNode == nextEdgeDetail.node0 and nextEdgeDetail.node1 or nextEdgeDetail.node0
		--joinTangent = util.v3(newJoinNode == nextEdgeDetail.node0 and nextEdgeDetail.tangent0 or nextEdgeDetail.tangent1)
		--otherTangent = util.v3(newJoinNode == nextEdgeDetail.node0 and nextEdgeDetail.tangent1 or nextEdgeDetail.tangent0)
		local newNode = newNodeWithPosition(newNodePos, nextNodeId()) 
		local entity = util.copyExistingEdge(joinEdgeId, nextEdgeId() )
		entity.comp.objects = {}
		local tangentLength = params.tangentBoost+ util.distance(newNodePos,depotPos)
		
		trace("new double track node, setting node1 to the newNode")
		entity.comp.node0=depotNode
		setTangent(entity.comp.tangent0,tangentLength*vec3.normalize(t1))
		entity.comp.node1=newNode.entity 
		
		setTangent(entity.comp.tangent1,tangentLength*vec3.normalize(otherTangent))
		t1 = util.v3(entity.comp.tangent1)
		--joinNode = newJoinNode
		--otherNode = joinNode == nextEdgeDetail.node1 and nextEdgeDetail.node0 or nextEdgeDetail.node1
		depotNode = newNode.entity
		--priorEdge = joinEdgeId
		--otherNode2 = util.findDoubleTrackNode(util.nodePos(otherNode),otherTangent)
		--entity.comp.objects = {}
		table.insert(nodesToAdd, newNode)
		table.insert(edgesToAdd, entity)
	end
	
	local entity = util.copyExistingEdge(joinEdgeId,nextEdgeId()) -- want to get any special properties like tunnel etc.
	 table.insert(edgesToAdd, entity)
	entity.comp.node0 = depotNode
	entity.comp.node1 = joinNode
	entity.comp.objects = {}
	--entity.comp.node1 = newNode.entity
	local distance = util.distance(effectiveDepotNodePos, util.nodePos(joinNode))
	local tangentBoost = depotBehindStation and 0 or params.tangentBoost
	local naturalTangent = util.nodePos(joinNode) - effectiveDepotNodePos
	local angelToNaturalTangent0 = util.signedAngle(t1, naturalTangent)
	local angelToNaturalTangent1 = util.signedAngle(joinTangent, naturalTangent)
	trace("Setting up depot tangents, the angelToNaturalTangent0 was ",math.deg(angelToNaturalTangent0)," angelToNaturalTangent1 was ",math.deg(angelToNaturalTangent1))
	if math.abs(angelToNaturalTangent0) > math.rad(90) then 
		trace("angelToNaturalTangent0 appears inverted, attempting to correct t1") 
		t1 = -1*t1
	end
	if math.abs(angelToNaturalTangent1) > math.rad(90) then 
		trace("angelToNaturalTangent1 appears inverted, attempting to correct joinTangent") 
		joinTangent = -1*joinTangent
	end

	setTangent(entity.comp.tangent0, (tangentBoost+distance) *  vec3.normalize(t1))
	setTangent(entity.comp.tangent1, (tangentBoost+distance) * vec3.normalize(joinTangent))
 
 
	if #util.getStreetSegmentsForNode(proposedJoinNode) > 0 then
		local edgeId = util.getStreetSegmentsForNode(proposedJoinNode)[1]
		local edge = util.getEdge(edgeId)
		local streetTangent = edge.node0==proposedJoinNode and util.v3(edge.tangent0) or util.v3(edge.tangent1)
		local signedAngle = util.signedAngle(joinTangent, streetTangent)
		local streetWidth = util.getEdgeWidth(edgeId)
		local crossingWidth = streetWidth / math.sin(math.abs(signedAngle))
		local requiredOffset = 5 + crossingWidth/2
		trace("found street connection, attempting split. crossingWidth=",crossingWidth, " requiredOffset=",requiredOffset)
		joinTangent.z = 0 
		local proposedNewNodePos = util.nodePos(proposedJoinNode) - requiredOffset*vec3.normalize(joinTangent)
		local linkedEdges  = util.getTrackSegmentsForNode(proposedJoinNode)
		local priorEdge = linkedEdges[1] == joinEdgeId and linkedEdges[2] or linkedEdges[1]
		local solution =util.solveForPositionOnExistingEdge(proposedNewNodePos, priorEdge)
		solution.p1.z = util.nodePos(proposedJoinNode).z -- keep the height the same to avoid strange effects
		local newNode = newNodeWithPosition(solution.p1, nextNodeId()) 
		entity.comp.node1 = newNode.entity
		local entity2 = util.copyExistingEdge(priorEdge,nextEdgeId())
		entity2.comp.objects = {}
		table.insert(edgesToAdd, entity2)
		setTangent(entity2.comp.tangent0, solution.t0)
		setTangent(entity2.comp.tangent1, solution.t1)
		entity2.comp.node1 = newNode.entity
		local entity3 = util.copyExistingEdge(priorEdge,nextEdgeId())
		entity3.comp.objects = {}
		table.insert(edgesToAdd, entity3)
		setTangent(entity3.comp.tangent0, solution.t2)
		setTangent(entity3.comp.tangent1, solution.t3)
		entity3.comp.node0 = newNode.entity
		
		setTangent(entity.comp.tangent0, (distance) *  vec3.normalize(t1))
		setTangent(entity.comp.tangent1, (distance) * vec3.normalize(solution.t2))
		
		table.insert(nodesToAdd, newNode) 
	
	
		table.insert(edgesToRemove, priorEdge)
  
	end
	local doubleSlipSwitchExpected =false
	local doubleTrackJoinNode = util.findDoubleTrackNode(util.nodePos(joinNode), joinTangent) 
	if doubleTrackJoinNode and not depotBehindStation then 
		trace("double track join found", doubleTrackJoinNode)
		--[[
		local priorEdgeDetail = util.getComponent(priorEdge, api.type.ComponentType.BASE_EDGE)
		if not backwards then
			otherNode = joinNode == priorEdgeDetail.node0 and priorEdgeDetail.node1 or priorEdgeDetail.node0
			otherNode2 = util.findDoubleTrackNode(util.nodePos(otherNode), util.v3(joinNode == priorEdgeDetail.node0 and priorEdgeDetail.tangent1 or priorEdgeDetail.tangent0))
		end]]--
		if not otherNode2 then 
			trace("OtherNode2 not found, using otherNode instead:" ,otherNode)
			otherNode2 = otherNode
		elseif not util.findEdgeConnectingNodes(otherNode2, doubleTrackJoinNode) and util.findEdgeConnectingNodes(otherNode, doubleTrackJoinNode) then 
			trace("Using the original node as the second other node, appears to be a join")
			otherNode2 = otherNode
		end 
		
		
		trace("OtherNode2 was ",otherNode2, " otherNode was ",otherNode," joinNode was ",joinNode," doubleTrackJoinNode was ",doubleTrackJoinNode)
	 
		local p1 = util.nodePos(otherNode2)
		local p2 = util.nodePos(doubleTrackJoinNode)
		local p3 = effectiveDepotNodePos
		local p4 = util.nodePos(joinNode)
		local collisionEdge
		local nonCollisionEdge
		local actualJoinNode
		local actualAdjacentNode
		local c = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4, true)
		if not c then -- basically force a collision so we end up connecting to both tracks
			p1 = util.nodePos(otherNode)
			p2 = util.nodePos(joinNode)
			p4 = util.nodePos(doubleTrackJoinNode)
			entity.comp.node1 = doubleTrackJoinNode
			collisionEdge =  util.findEdgeConnectingNodes(otherNode, joinNode)
			nonCollisionEdge = util.findEdgeConnectingNodes(otherNode2, doubleTrackJoinNode)
			if not collisionEdge or util.isFrozenEdge(collisionEdge) then 
				trace("unable to find edge connecting otherNode, joinNode ",otherNode, joinNode,collisionEdge)
				return false
			end
			c = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4, true)
			if not c then 
				trace("unable to find collision point")
				return false
			end
			assert(c)
			actualJoinNode = doubleTrackJoinNode
			actualAdjacentNode = joinNode
		else
			collisionEdge = util.findEdgeConnectingNodes(otherNode2, doubleTrackJoinNode)
			nonCollisionEdge =  util.findEdgeConnectingNodes(otherNode, joinNode)
			if not collisionEdge or util.isFrozenEdge(collisionEdge) then 
				trace("unable to find edge connecting otherNode2, doubleTrackJoinNode ",otherNode2, doubleTrackJoinNode,collisionEdge)
				return false
			end
			actualJoinNode = joinNode
			actualAdjacentNode = doubleTrackJoinNode
		end
		table.insert(edgesToRemove, collisionEdge)
		local isJunctionEdge = util.isJunctionEdge(collisionEdge)
		local collisionEdgeFull = util.getEdge(collisionEdge)
		if #collisionEdgeFull.objects > 0 and isJunctionEdge then 
			trace("Detected signals, removing for depot crossing") 
			for i, edgeObj in pairs(collisionEdgeFull.objects) do 
				table.insert(edgeObjectsToRemove, edgeObj[1])
			end
			if nonCollisionEdge and nonCollisionEdge ~=collisionEdge then 
				local nonCollisionEdgeFull = util.getEdge(nonCollisionEdge)
				for i, edgeObj in pairs(nonCollisionEdgeFull.objects) do 
					table.insert(edgeObjectsToRemove, edgeObj[1])
				end
				 
				local replacement = getOrMakeReplacedEdge(nonCollisionEdge, nextEdgeId())
				replacement.comp.objects = {}  
			end
		end
		
		
		local newEdge = {
			p0= p3,
			p1= p4,
			t0= util.v3(entity.comp.tangent0),
			t1= util.v3(entity.comp.tangent1)
		} 
		local zavg = (p1.z+p2.z+p3.z+p4.z)/4
		c = util.v2ToV3(c, zavg)
		local fullSolution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c, collisionEdge, newEdge, util.distance)
		local collisionNode = newNodeWithPosition(fullSolution.existingEdgeSolution.p1, nextNodeId()) -- note use the mainline solution to avoid distorting the track
		collisionNode.comp.doubleSlipSwitch=true
		--table.remove(edgesToAdd)
		table.insert(nodesToAdd, collisionNode)
		local depotLink1 = util.copyExistingEdge(collisionEdge, nextEdgeId()) 
		depotLink1.comp.node1 = collisionNode.entity 
		depotLink1.comp.objects = {}
		setTangent(depotLink1.comp.tangent0, fullSolution.existingEdgeSolution.t0)
		setTangent(depotLink1.comp.tangent1, fullSolution.existingEdgeSolution.t1) 
		table.insert(edgesToAdd, depotLink1)
	
		local depotLink2 = util.copyExistingEdge(collisionEdge, nextEdgeId()) 
		depotLink2.comp.node0 = collisionNode.entity
		depotLink2.comp.objects = {}
	 
		
		setTangent(depotLink2.comp.tangent0, fullSolution.existingEdgeSolution.t2)
		setTangent(depotLink2.comp.tangent1, fullSolution.existingEdgeSolution.t3)
		table.insert(edgesToAdd, depotLink2)
		
		local ourLink = copySegmentAndEntity(entity, nextEdgeId())
		entity.comp.node1 = collisionNode.entity 
		ourLink.comp.node0 = collisionNode.entity
		
		local depotCrossingTangent =fullSolution.newEdgeSolution.t1
		local rawAngle = util.signedAngle(fullSolution.existingEdgeSolution.t1, depotCrossingTangent)
		local angel = rawAngle
		if math.abs(rawAngle) > math.rad(90) then 
			if rawAngle > 0 then 
				angle = math.rad(180) - rawAngle
			else
				angle = math.rad(180) + rawAngle
			end
		end
		--[[
		trace("angle to the depot tangent was ", math.deg(angle), " the raw angle was ", math.deg(rawAngle), " expr math.rad(180)-math.abs(rawAngle)=",math.deg(math.rad(180)-math.abs(rawAngle)), " expr 180-math.deg(rawAngle)=",180-math.deg(rawAngle) )
		if math.abs(angle) < math.rad(params.minimumCrossingAngle) then
			local absCorrection = math.rad(params.minimumCrossingAngle)-math.abs(angle)
			local correction = angle > 0 and absCorrection or -absCorrection
			depotCrossingTangent = util.rotateXY(depotCrossingTangent, correction)
			local angle = util.signedAngle(fullSolution.existingEdgeSolution.t1, depotCrossingTangent)
			trace("after correction the angle to the depot tangent was ", math.deg(angle))
		elseif math.abs(angle) > math.rad(params.maximumSlipSwitchAngle) then
			local absCorrection = math.abs(angle) - math.rad(params.maximumSlipSwitchAngle)
			local correction = angle > 0 and -absCorrection or absCorrection
			depotCrossingTangent = util.rotateXY(depotCrossingTangent, correction)
			local angle = util.signedAngle(fullSolution.existingEdgeSolution.t1, depotCrossingTangent)
			trace("after correction the angle to the depot tangent was ", math.deg(angle))
		end--]]
		
		depotCrossingTangent = vec3.length( fullSolution.newEdgeSolution.t1)* vec3.normalize(depotCrossingTangent)
		local depotCrossingTangent2 = vec3.length(fullSolution.newEdgeSolution.t2)*vec3.normalize(depotCrossingTangent)
		
		
		setTangent(entity.comp.tangent0, fullSolution.newEdgeSolution.t0)
		setTangent(entity.comp.tangent1, depotCrossingTangent)
		setTangent(ourLink.comp.tangent0, depotCrossingTangent2)
		setTangent(ourLink.comp.tangent1, fullSolution.newEdgeSolution.t3)
		ourLink.comp.objects = {}
		trace("Setting up tangents for depot crossing,newEdgeSolution  lengths were ", vec3.length(fullSolution.newEdgeSolution.t0), vec3.length( fullSolution.newEdgeSolution.t1),vec3.length( fullSolution.newEdgeSolution.t2), vec3.length(fullSolution.newEdgeSolution.t3), " backwards = ",backwards)
		trace("Setting up tangents for depot crossing, existing edge solution lengths were ", vec3.length(fullSolution.existingEdgeSolution.t0), vec3.length( fullSolution.existingEdgeSolution.t1),vec3.length( fullSolution.existingEdgeSolution.t2), vec3.length(fullSolution.existingEdgeSolution.t3), " backwards = ",backwards)
		
		 table.insert(edgesToAdd, ourLink)
		 
		local edge1  = util.findEdgeConnectingNodes(otherNode2, doubleTrackJoinNode)
		local edge2 =  util.findEdgeConnectingNodes(otherNode, joinNode)
		 
		if params.isQuadrupleTrack and false then --TEMP disable
			local replacedJoinNode = newNodeWithPosition(util.nodePos(actualJoinNode), nextNodeId())
			replacedJoinNode.comp.doubleSlipSwitch = true 
			table.insert(nodesToAdd, replacedJoinNode)
			for __, seg in pairs(util.getSegmentsForNode(actualJoinNode)) do 
				local replacement = getOrMakeReplacedEdge(seg)
				if replacement.comp.node0 == actualJoinNode then 
					replacement.comp.node0 = replacedJoinNode.entity
				else 
					replacement.comp.node1 = replacedJoinNode.entity
				end 
			end 
			assert(ourLink.comp.node1 == actualJoinNode)
			ourLink.comp.node1 = replacedJoinNode.entity
			local nextNode1 =  util.findDoubleTrackNode(util.nodePos(actualJoinNode),  fullSolution.newEdgeSolution.t3, 1, 1, true, { [actualAdjacentNode]=true  })
			local nextNode2 =  util.findDoubleTrackNode(util.nodePos(nextNode1),  fullSolution.newEdgeSolution.t3, 1, 1, true, { [actualJoinNode]=true  })
			
			local nextEdge1 = util.getEdge(util.findNextEdgeInSameDirection(nonCollisionEdge, actualJoinNode))
			local nextEdge2 = util.getEdge(util.findNextEdgeInSameDirection(collisionEdge, actualAdjacentNode))
			local exitNode1 =  actualJoinNode == nextEdge1.node0 and nextEdge1.node1 or nextEdge1.node0
			local exitNode2 =  actualAdjacentNode == nextEdge2.node0 and nextEdge2.node1 or nextEdge2.node0
			 
			local nextNode3 =  util.findDoubleTrackNode(exitNode1, nil, 1, 1, true, { [exitNode2]=true  })
			local nextNode4 =  util.findDoubleTrackNode(nextNode3, nil, 1, 1, true, { [exitNode1]=true  })
			local outerEdgeId1 = util.findEdgeConnectingNodes(nextNode1, nextNode3)
			local outerEdgeId2 = util.findEdgeConnectingNodes(nextNode2, nextNode4)
			local outerEdge2 = util.getEdge(outerEdgeId2) 
			local tangent = outerEdge2.node0 == nextNode4 and -1*util.v3(outerEdge2.tangent0) or util.v3(outerEdge2.tangent1)
			local inputEdge = {
				p0 = util.nodePos(actualJoinNode),
				p1 = util.nodePos(nextNode4),
				t0 = depotCrossingTangent2,
				t1 = tangent
			}
			local length  = util.calculateTangentLength(inputEdge.p0, inputEdge.p1, inputEdge.t0, inputEdge.t1)
			inputEdge.t0 = length*vec3.normalize(inputEdge.t0)
			inputEdge.t1 = length*vec3.normalize(inputEdge.t1)
			local c = util.solveForPositionHermiteFraction(0.5, inputEdge).p
			local fullSolution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c, outerEdgeId1, inputEdge, util.distance)
			local collisionNode = newNodeWithPosition(fullSolution.existingEdgeSolution.p1, nextNodeId())  
			collisionNode.comp.doubleSlipSwitch=true 
			table.insert(nodesToAdd, collisionNode)
			table.insert(edgesToRemove, outerEdgeId1)
			local replacedEdge1 = util.copyExistingEdge(outerEdgeId1, nextEdgeId())
			table.insert(edgesToAdd, replacedEdge1)
			for i , edgeObj in pairs(replacedEdge1.comp.objects) do 
				table.insert(edgeObjectsToRemove, edgeObj[1])
			end 
			replacedEdge1.comp.objects = {}
			local replacedEdge2 = copySegmentAndEntity(replacedEdge1, nextEdgeId()) 
			table.insert(edgesToAdd, replacedEdge2)
			replacedEdge1.comp.node1 = collisionNode.entity 
			replacedEdge2.comp.node0 = collisionNode.entity 
			setTangent(replacedEdge1.comp.tangent0, fullSolution.existingEdgeSolution.t0)
			setTangent(replacedEdge1.comp.tangent1, fullSolution.existingEdgeSolution.t1)
			setTangent(replacedEdge2.comp.tangent0, fullSolution.existingEdgeSolution.t2)
			setTangent(replacedEdge2.comp.tangent1, fullSolution.existingEdgeSolution.t3)
			
			setTangent(ourLink.comp.tangent1, fullSolution.newEdgeSolution.t3)
			local ourOuterLink1 = copySegmentAndEntity(ourLink, nextEdgeId())
			table.insert(edgesToAdd, ourOuterLink1)
			local ourOuterLink2 = copySegmentAndEntity(ourLink, nextEdgeId())
			table.insert(edgesToAdd, ourOuterLink2)
			ourOuterLink1.comp.node0 = replacedJoinNode.entity
			ourOuterLink1.comp.node1 = collisionNode.entity 
			ourOuterLink2.comp.node0 = collisionNode.entity 
			ourOuterLink2.comp.node1 = nextNode4
			setTangent(ourOuterLink1.comp.tangent0, fullSolution.newEdgeSolution.t0)
			setTangent(ourOuterLink1.comp.tangent1, fullSolution.newEdgeSolution.t1)
			setTangent(ourOuterLink2.comp.tangent0, fullSolution.newEdgeSolution.t2)
			setTangent(ourOuterLink2.comp.tangent1, fullSolution.newEdgeSolution.t3)
			setTangent(ourLink.comp.tangent1, vec3.length(ourLink.comp.tangent1)*vec3.normalize(fullSolution.newEdgeSolution.t0))
			
		else 	
			-- need to be careful here not to build on the wrong side
		--	routeBuilder.buildJunctionSignals(edge1, doubleTrackJoinNode, edge2, joinNode, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId)
		end
		
		doubleSlipSwitchExpected = true
	end
	
	
	local newProposal
	--local errToUse = util.tracelog and routeBuilder.err or err 
	if not xpcall(function() newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) end ,errToUse) then
		trace("Error calling setupProposal")
		return false 
	end
	 --newProposal = routeBuilder.attemptDeconfliction(newProposal)
	--debugPrint(newProposal)
	local testResult = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if #testResult.errorState.messages > 0 and not params.ignoreErrors or testResult.errorState.critical then
		print("depot command failed", testResult.errorState.messages[1], " was critical? ",testResult.errorState.critical, " joining to node ", joinNode)
		debugPrint(testResult.errorState)
		--debugPrint(newProposal)
		return false 
	end	
	if doubleSlipSwitchExpected then 
		for i, node in pairs(nodesToAdd) do 
			if node.comp.doubleSlipSwitch then 
				local ourTnEntity =  testResult.entity2tn[node.entity]
				assert(#ourTnEntity.nodes==5) -- sanity check
				if #ourTnEntity.edges == 4 then --crossover has 4, doubleSlipSwitch has 6
					trace("tryBuildDepotConnection: rejecting solution as no double slipswitch was formed")
					return false
				end 
			end 
		end 
		--debugPrint(testResult) 
	end 
	

	trace("About to build command to build depot, joining to node ", joinNode, "distance was",distance)
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), params.ignoreErrors)
	--debugPrint(build)
	trace("About to sent command to build depot")
	--if tracelog then debugPrint(build) end
	api.cmd.sendCommand(build, callback)
	util.clearCacheNode2SegMaps()
	trace("Command to build depot sent")
	return true
end


function routeBuilder.buildDepotConnection(callback, depot, params)
	trace("begin build depot connection for depot ", depot)
 
	util.clearCacheNode2SegMaps()
	util.cacheNode2SegMaps() 
	local success = false
	params.tangentBoost = 0 
	for k = -1, 2 do
		params.extraOffsetFactor = k
		for j =0, 4 do 
			xpcall(function() 
				success = tryBuildDepotConnection(callback, depot, params, j , false) 
			end, err)
			if success then 
				break
			end
			if j > 0 then 
				xpcall(function() 
					success = tryBuildDepotConnection(callback, depot, params, j , true)  
				end, err)
			end
			params.tangentBoost = j*5
			if success then
				break
			end 
		end
		if success then
			break
		end
	end
	
	 
	if not success and not params.ignoreErrors then
		params.ignoreErrors = true  
		routeBuilder.buildDepotConnection(callback, depot, params) 
		return 
	end
	if not success then 
		callback({}, false) 
	end
	util.clearCacheNode2SegMaps()
end

local function getAdjustedDistance(leftNodePos, rightNodePos, params)
	local distance = util.distance(leftNodePos, rightNodePos)
	local deltaz = math.abs(leftNodePos.z - rightNodePos.z)
	local adjustedDistance = math.max(distance, deltaz / params.absoluteMaxGradient)
	trace("The adjustedDistance was",adjustedDistance,"distance was",distance)
	return adjustedDistance	
end 

function routeBuilder.tryBuildRoute(nodepair, params, callback)
	  
	params.tryBuildRouteStartTime = os.clock()
	--collectgarbage()
	if params.addBusLanes then 
		params.preferredCountryRoadType = params.preferredCountryRoadTypeWithBus
	end
	local streetType = not params.isTrack and type(params.preferredCountryRoadType)=="string" and api.res.streetTypeRep.find(params.preferredCountryRoadType) or params.preferredCountryRoadType
	local leftNode = nodepair[1] 
	local rightNode = nodepair[2]
	local distance = util.distBetweenNodes(leftNode, rightNode)
	if not params.isTrack and not params.isHighway  then 
		trace("Checking nodes ",leftNode, rightNode)
		if #util.getSegmentsForNode(leftNode) > 1 or #util.getSegmentsForNode(rightNode) > 1  then 
			if leftNode == rightNode or (not params.isShortCut and not params.isHighwayConnect and (#pathFindingUtil.findRoadPathBetweenNodes(leftNode, rightNode  ) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(rightNode, leftNode ) > 0)) or util.findEdgeConnectingNodes(leftNode, rightNode) then 
				trace("WARNING! attempted to build road between existing nodes",rightNode, leftNode, " aborting")
				trace(debug.traceback())
				callback({}, true)
				return true
			end
		end
	end
	trace("Begin building route between ",leftNode," and ",rightNode)
	local leftSegmentCount = #util.getSegmentsForNode(leftNode)
	local rightSegmentCount = #util.getSegmentsForNode(rightNode)
	assert(leftSegmentCount < 4, "Left segment count must be <4 for "..tostring(leftNode).." but was "..tostring(leftSegmentCount))
	assert(rightSegmentCount < 4, "Right segment count must be <4 for "..tostring(rightNode).." but was "..tostring(rightSegmentCount))
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	local stone = api.res.bridgeTypeRep.find("stone.lua")
	local cable = api.res.bridgeTypeRep.find("cable.lua")
	local ironIsAvailable = util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom
	local cementIsAvailable = util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom
	local suspension = api.res.bridgeTypeRep.find("suspension.lua")
	 
	local isDoubleTrack = params.isDoubleTrack 
 	--doubleTrack = false
	trace("Begin route building isTrack=",params.isTrack, " isCargo=",params.isCargo," isDoubleTrack=",isDoubleTrack," isElectricTrack=",params.isElectricTrack," isHighSpeedTrack=",params.isHighSpeedTrack, " streetType=",streetType, " isQuadrupleTrack=",params.isQuadrupleTrack)
	--local targetSeglenth = 90
	if isDoubleTrack and not params.isTrack and not params.isHighway then 
		trace("WARNING! Attempted to build a double track road")
		isDoubleTrack = false 
		trace(debug.traceback())
	end 

	local nodecount = math.ceil(getAdjustedDistance(util.nodePos(leftNode), util.nodePos(rightNode),params)/params.targetSeglenth)
	--while nodecount % (changeDirectionInterval*2) ~=0 do
	--	nodecount = nodecount + 1
	--	trace("increased nodecount by 1, new nodecount=",nodecount)
	--end
	if nodecount % 2 == 1 then
		nodecount = nodecount + 1 -- better to be even 
	end
	
	local nextNodeId = -nodecount * 100
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local newNodeMap = {}
	local replacedEdgesMap = {}
	local splitEdgesMap = {}
	local oldToNewNodeMap = {}
	local newToOldNodeMap = {}
	local removedOnlyEdges = {}
	local edgePositionsToCheck = {}
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local function nodePos(node, copy) 
		if node > 0 then 
			return util.nodePos(node, copy)
		else 
			return util.v3(newNodeMap[node].comp.position)
		end 
	end 
	local function addNode(newNode) 
		if params.isHighway then 
			newNode.comp.trafficLightPreference = 1
		end 
		table.insert(nodesToAdd, newNode)
		newNodeMap[newNode.entity]=newNode
		trace("tryBuildRoute: added new node with entity",newNode.entity," at position:" ,posToString(newNode.comp.position))
	end 
	
	local function initSegmentAndEntity() 
		local entity = api.type.SegmentAndEntity.new()
		entity.entity = nextEdgeId()
		entity.type= params.isTrack and 1 or 0
		if params.isTrack then
			entity.trackEdge.trackType = params.isHighSpeedTrack and api.res.trackTypeRep.find("high_speed.lua") or api.res.trackTypeRep.find("standard.lua")
			entity.trackEdge.catenary = params.isElectricTrack 
		else 
			entity.streetEdge.streetType = streetType 
			entity.streetEdge.hasBus = params.addBusLanes
			entity.streetEdge.tramTrackType = params.tramTrackType
		end
		
		local playerOwned = api.type.PlayerOwned.new()
		playerOwned.player = api.engine.util.getPlayer()
		entity.playerOwned = playerOwned
		return entity
	end
	
	

 
	local signalInterval = nodecount > 2*paramHelper.getParams().targetSignalInterval and paramHelper.getParams().targetSignalInterval or math.floor(nodecount/2)
	
	if tracelog then debugPrint({nodepair=nodepair}) end

	local otherLeftNode = nodepair[3]
	local otherRightNode = nodepair[4]
	
	
	local depot1Connect = leftNode
	--local leftEdgeId = node2SegMap[leftNode]
	--local rightEdgeId = node2SegMap[rightNode]
	local leftSegs = util.getSegmentsForNode(leftNode)
	local leftEdgeId = leftSegs[1] -- note second table is C Vector
	if not params.isTrack  then 
		if util.isCornerNode(leftNode) and  util.getStreetTypeCategory(leftEdgeId) ~= "country" and util.getStreetTypeCategory(leftSegs[2]) == "country" then 
			trace("Swapping left edge for node",leftNode, " as ",leftEdgeId," was not country")
			leftEdgeId = leftSegs[2]
		end
		if #leftSegs == 3 then 
			leftEdgeId = util.getOutboundNodeDetailsForTJunction(leftNode).edgeId 
		end
	end
	local rightSegs =  util.getSegmentsForNode(rightNode)
	local rightEdgeId =rightSegs[1]
	if not params.isTrack then 
		if util.isCornerNode(rightNode) and util.getStreetTypeCategory(rightEdgeId) ~= "country" and util.getStreetTypeCategory(rightSegs[2]) == "country" then 
			trace("Swapping right edge for node",rightNode, " as ",rightEdgeId," was not country")
			rightEdgeId = rightSegs[2]
		end
		if #rightSegs == 3 then 
			rightEdgeId = util.getOutboundNodeDetailsForTJunction(rightNode).edgeId
		end
	end
	
	local segLength = distance / (1 + nodecount)
		
	local leftEdge = util.getEdge(leftEdgeId)
	local lf = leftNode == leftEdge.node1 and segLength or -segLength
	local leftTangent = leftNode == leftEdge.node0 and leftEdge.tangent0 or leftEdge.tangent1
	leftTangent = lf*vec3.normalize(util.v3(leftTangent))
	local leftNodePos = nodePos(leftNode)
	
	local rightEdge = util.getEdge(rightEdgeId)
	local rf = rightNode == rightEdge.node0 and segLength or -segLength
	local rightTangent = rightNode == rightEdge.node1 and rightEdge.tangent1 or rightEdge.tangent0
	rightTangent = rf*vec3.normalize(util.v3(rightTangent))
	local rightNodePos = nodePos(rightNode, true)
	
	if isDoubleTrack then 	
		local direction = util.normalVecBetweenNodes(leftNode, rightNode)
		if otherLeftNode == nil then 
			otherLeftNode = leftNode
		end 
		trace("leftNode=",leftNode,"OtherLeftNode was ",otherLeftNode,"rightNode=",rightNode," OtherRightNode was ",otherRightNode,"rightNodePos.z=",rightNodePos.z)
		if otherLeftNode ~= leftNode then
		--[[
			local leftGap = util.normalVecBetweenNodes(leftNode,otherLeftNode)
			local leftAngle = util.signedAngle(leftGap, direction)
			if leftAngle > 0 then
				trace("swapping nodes for left hand side")
				leftNode = nodepair[3]
				otherLeftNode = nodepair[1]
			end]]--
			local testP = util.doubleTrackNodePoint(leftNodePos, leftTangent)
			local testP2 = util.doubleTrackNodePoint(leftNodePos, -1*leftTangent)
			local otherNodePos = nodePos(otherLeftNode)
			if util.distance(testP2, otherNodePos) < util.distance(testP, otherNodePos) then
				trace("swapping nodes for left hand side")
				leftNode = nodepair[3]
				otherLeftNode = nodepair[1]
				nodepair[1] = leftNode 
				nodepair[3] = otherLeftNode
				leftNodePos = nodePos(leftNode)
				leftEdgeId = util.getSegmentsForNode(leftNode)[1]
			end
			
		end
		if otherRightNode == nil then 
			otherRightNode = rightNode 
		end
		if otherRightNode ~= rightNode   then
			--[[local rightGap = util.normalVecBetweenNodes(rightNode,otherRightNode) 
			local rightAngle = util.signedAngle(rightGap, direction)
			
			if rightAngle > 0 then
				trace("swapping nodes for right side")
				rightNode = nodepair[4]
				otherRightNode = nodepair[2]
			end]]--
			local testP = util.doubleTrackNodePoint(rightNodePos, rightTangent)
			local testP2 = util.doubleTrackNodePoint(rightNodePos, -1*rightTangent)
			local otherNodePos = nodePos(otherRightNode)
			if util.distance(testP2, otherNodePos) < util.distance(testP, otherNodePos) then
				trace("swapping nodes for right side, was",rightNode,otherRightNode)
				rightNode = nodepair[4]
				otherRightNode = nodepair[2]
				nodepair[2]=rightNode 
				nodepair[4]=otherRightNode
				rightNodePos = nodePos(rightNode, true)
				trace("rightNodePos.z=",rightNodePos.z)
				rightEdgeId = util.getSegmentsForNode(rightNode)[1]
			end
		end 
	end
	if otherLeftNode then 
		params.otherLeftNodePos = nodePos(otherLeftNode)
	end
	if otherRightNode then
		params.otherRightNodePos = nodePos(otherRightNode)
	end
	local newDoubleTrackNode = function (p, t, entityId) 
		return newNodeWithPosition(util.doubleTrackNodePoint(p, t), entityId)
	end
	if params.isHighway then 
		isDoubleTrack = true
		streetType = type(params.preferredHighwayRoadType)=="string" and api.res.streetTypeRep.find(params.preferredHighwayRoadType) or params.preferredHighwayRoadType
		local offset = util.getStreetWidth(streetType)+params.highwayMedianSize
		newDoubleTrackNode = function (p, t, entityId) 
			return newNodeWithPosition(util.nodePointPerpendicularOffset(p, t, offset), entityId)
		end
	end
	
	local function trialBuild(nodeDetails) 
		local entity = initSegmentAndEntity()
		local testProposal = api.type.SimpleProposal.new()
		entity.comp.node0 = nodeDetails.node 
		local newNodePos = nodeDetails.nodePos + 90 * vec3.normalize(nodeDetails.tangent)
		local newNode = newNodeWithPosition(newNodePos, -2) 
		entity.comp.node1 = newNode.entity 
		setTangents(entity, newNodePos - nodeDetails.nodePos) 
		local edge = util.getEdge(nodeDetails.edgeId)
		entity.comp.type = edge.type 
		entity.comp.typeIndex = edge.typeIndex
		
		testProposal.streetProposal.edgesToAdd[1]=entity
		testProposal.streetProposal.nodesToAdd[1]=newNode 
		local testData =  api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
		if not testData.errorState.critical and #testData.errorState.messages == 1 and testData.errorState.messages[1]=="Collision"
			and #testData.collisionInfo.collisionEntities > 0 then 
			-- allow a road to road collision if this can likely be resolved in the build
			for i, e in pairs(testData.collisionInfo.collisionEntities) do 
				local entity = util.getEntity(e.entity)
				if entity and entity.type == "BASE_EDGE" and not entity.track then 
					local minDist = math.min(util.distance(nodeDetails.nodePos, util.getEdgeMidPoint(entity.id)),
						math.min(util.distance(nodeDetails.nodePos, util.v3fromArr(entity.node0pos)), 
								 util.distance(nodeDetails.nodePos, util.v3fromArr(entity.node1pos))))
					trace("Inspecting collision with edge, minDist was ",minDist) 
					if minDist < 30 then
						return false 
					end
				else 
					return false 
				end
			end 
			return true 
		end
		
		return #testData.errorState.messages == 0 and not testData.errorState.critical 
	 
	end 


	local alreadySeenCollissionEdges = {}
	
	if not params.isTrack and not params.isHighway then

		local replacedLeftNode = false 
		local replacedRightNode = false 
		local adjustedLeftTangent = false 
		local adjustedRightTangent = false 
		local tryRemoveEdge = false 
		if getAdjustedDistance(leftNodePos, rightNodePos, params) < 2*params.targetSeglenth and getAdjustedDistance(leftNodePos, rightNodePos, params) > util.distance(leftNodePos, rightNodePos) then 
			trace("Trying to remove an edge. The #leftSegs was",#leftSegs,"#rightSegs was",#rightSegs)
			tryRemoveEdge = true 
		end 
		if util.distance(leftNodePos, rightNodePos) < 2*params.targetSeglenth and math.abs(util.signedAngle(leftTangent, rightTangent)) > math.rad(90) then 
			trace("Large angle at short distance detected, trying to remove, angle was",math.deg(util.signedAngle(leftTangent, rightTangent)))
			tryRemoveEdge = true 
		end 
		local function edgeIsRemovable(edgeId) 
			return util.isDeadEndEdgeNotIndustry(edgeId) 
			and not util.isLinkEntitiesPresentOnStreet(edgeId) 
			and (not util.isJunctionEdge(edgeId) or tryRemoveEdge)
			and not util.isFrozenEdge(edgeId)
		end 
		if #leftSegs <= 2 then 
			local leftNodeDetails = util.getDeadEndNodeDetails(leftNode) 
			local failedBuild = not trialBuild(leftNodeDetails) and util.distance(leftNodePos, rightNodePos) > params.targetSeglenth 
			local naturalTangent = rightNodePos - leftNodePos 
			local signedAngleToTangent = util.signedAngle(leftNodeDetails.tangent, naturalTangent)
			trace("Inspecting the signedAngle to natural tangent on left, was ",math.deg(signedAngleToTangent), " failedBuild?",failedBuild)
			if tryRemoveEdge and edgeIsRemovable(leftEdgeId) then 
				failedBuild = true 
				trace("Overriding failedBuild to true on the left")
			end 
			local facingWrongWay = false--math.abs(signedAngleToTangent) > math.rad(120)
			if failedBuild or facingWrongWay then 
				trace("Detected problem at leftNode ",leftNode," for left edge", leftEdgeId," attempting to correct, failedBuild?",failedBuild, " facingWrongWay?",facingWrongWay)
				if failedBuild and edgeIsRemovable(leftEdgeId) then 
					trace("Removing left edge")
					table.insert(edgesToRemove, leftEdgeId)
					alreadySeenCollissionEdges[leftEdgeId]=true
					removedOnlyEdges[leftEdgeId]=true
					
					leftTangent = leftNode == leftEdge.node1 and leftEdge.tangent0 or leftEdge.tangent1
					local lf = leftNode == leftEdge.node1 and segLength or -segLength
					leftNode = leftNode == leftEdge.node0 and leftEdge.node1 or leftEdge.node0 
					local nextSegs = util.getStreetSegmentsForNode(leftNode)
					leftEdgeId = leftEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
					leftEdge = util.getEdge(leftEdgeId)
					
					
					leftTangent = lf*vec3.normalize(util.v3(leftTangent)) 
					leftNodePos = nodePos(leftNode)
					replacedLeftNode = true
				else 
					trace("attempting 90 degree rotation")
					local trialTangent1 = util.rotateXY(leftTangent, math.rad(90))
					local trialTangent2 = util.rotateXY(leftTangent, -math.rad(90))
					local isIndustryEdge = util.isIndustryEdge(leftEdgeId)
					local dist = isIndustryEdge and 180 or segLength
					local trialPos1 = leftNodePos + dist*vec3.normalize(trialTangent1) 
					local trialPos2 = leftNodePos + dist*vec3.normalize(trialTangent2)
					local tangentToUse
					local otherTangent
					
					if util.distance(trialPos1, rightNodePos) < util.distance(trialPos2, rightNodePos) then 
						tangentToUse = trialTangent1
						otherTangent = trialTangent2
					else 
						tangentToUse = trialTangent2
						otherTangent = trialTangent1
					end  
					leftNodeDetails.tangent = tangentToUse 
					local isOk = trialBuild(leftNodeDetails) 
					if not isOk then 
						local options = {}
						for rot = -160, 160, 10 do
							trace("Unable to build with preferred tangent, checking other",rot) 
							local otherTangent = util.rotateXY(leftTangent, math.rad(rot))
							leftNodeDetails.tangent = otherTangent 
							if trialBuild(leftNodeDetails) then 
								table.insert(options, {
									tangent = otherTangent, 
									scores = {
										math.abs(util.signedAngle(rightNodePos-leftNodePos, otherTangent))
									}
								})
							end
						end
						if #options > 0 then 
							local best = util.evaluateWinnerFromScores(options)
							trace("Using the option with the tangent",best.tangent.x,best.tangent.y,"angle was",math.deg(best.scores[1]))
							tangentToUse = best.tangent 
							isOk = true 
						else 
							trace("WARNING, still unable to build!!!")
						end 
					end 
					if isOk then 
						leftTangent = segLength*vec3.normalize(tangentToUse)
						adjustedLeftTangent = true 
						if isIndustryEdge then 
							trace("Building offset for industry edge at left edge")
							local entity = initSegmentAndEntity() 
							entity.comp.node0 = leftNode 
							leftNodePos = leftNodePos + leftTangent
							--leftNodePos.z = leftNodePos.z-15
							local newNode = newNodeWithPosition(leftNodePos, getNextNodeId())
							entity.comp.node1 = newNode.entity
							setTangents(entity, leftTangent)
							addNode(newNode)
							table.insert(edgesToAdd, entity)
							leftTangent = segLength * vec3.normalize(leftTangent)
							leftNode = newNode.entity
							replacedLeftNode = true
						end 
					end
				end 
				
			end
		end 
		
		if #rightSegs <= 2 then 
			local rightNodeDetails = util.getDeadEndNodeDetails(rightNode)  
			local failedBuild = not trialBuild(rightNodeDetails) and util.distance(leftNodePos, rightNodePos) > params.targetSeglenth 
			local naturalTangent = leftNodePos-rightNodePos 
			local signedAngleToTangent = util.signedAngle( rightNodeDetails.tangent, naturalTangent)
			trace("Inspecting the signedAngle to natural tangent on right, was ",math.deg(signedAngleToTangent))
			local facingWrongWay = false-- math.abs(signedAngleToTangent) > math.rad(120)
			if tryRemoveEdge and edgeIsRemovable(rightEdgeId) then 
				failedBuild = true 
				trace("Overriding failedBuild to true on the right")
			end 
			if failedBuild or facingWrongWay then 
				trace("Detected problem at rightNode ",rightNode," for right edge", rightEdgeId," attempting to correct, failedBuild?",failedBuild, " facingWrongWay?",facingWrongWay)
				if failedBuild and edgeIsRemovable(rightEdgeId) then 
					trace("Removing right edge")
					table.insert(edgesToRemove, rightEdgeId)
					alreadySeenCollissionEdges[rightEdgeId]=true
					removedOnlyEdges[rightEdgeId]=true
					
					rightTangent = rightNode == rightEdge.node0 and rightEdge.tangent1 or rightEdge.tangent0
					rf = rightNode == rightEdge.node0 and segLength or -segLength
					rightNode = rightNode == rightEdge.node0 and rightEdge.node1 or rightEdge.node0 
					local nextSegs = util.getStreetSegmentsForNode(rightNode)
					rightEdgeId = rightEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
					rightEdge = util.getEdge(rightEdgeId)
					
				
					rightTangent = rf*vec3.normalize(util.v3(rightTangent))
					rightNodePos = nodePos(rightNode)
					replacedRightNode = true
				else 
					trace("attempting 90 degree rotation") 
					local trialTangent1 = util.rotateXY(rightTangent, math.rad(90))
					local trialTangent2 = util.rotateXY(rightTangent, -math.rad(90))
					local isIndustryEdge = util.isIndustryEdge(rightEdgeId)
					local dist = isIndustryEdge and 180 or segLength
					local trialPos1 = rightNodePos + dist*vec3.normalize(trialTangent1) 
					local trialPos2 = rightNodePos + dist*vec3.normalize(trialTangent2)
					local tangentToUse
					local otherTangent
					
					if util.distance(trialPos1, leftNodePos) < util.distance(trialPos2, leftNodePos) then 
						tangentToUse = trialTangent1
						otherTangent = trialTangent2
					else 
						tangentToUse = trialTangent2
						otherTangent = trialTangent1
					end 
					 
					rightNodeDetails.tangent = tangentToUse 
					local isOk = trialBuild(rightNodeDetails) 
					if not isOk then 
						local options = {}
						for rot = -160, 160, 10 do
							trace("Unable to build with preferred tangent, checking other",rot) 
							local otherTangent = util.rotateXY(rightTangent, math.rad(rot))
							rightNodeDetails.tangent = otherTangent 
							if trialBuild(rightNodeDetails) then 
								 
								 
								table.insert(options, {
									tangent = otherTangent, 
									scores = {
										math.abs(util.signedAngle(leftNodePos-rightNodePos, otherTangent))
									}
								})
								--break
							else	 
								
							end 
						end
						if #options > 0 then 
							local best = util.evaluateWinnerFromScores(options)
							trace("Using the option with the tangent",best.tangent.x,best.tangent.y,"angle was",math.deg(best.scores[1]))
							tangentToUse = best.tangent 
							isOk = true 
						else 
							trace("WARNING, still unable to build!!!")
						end 
					end 
					if isOk then 
						adjustedRightTangent = true
						rightTangent = -dist*vec3.normalize(tangentToUse)
						if isIndustryEdge then 
							trace("Building offset for industry edge at right edge")
							local entity = initSegmentAndEntity() 
							entity.comp.node1 = rightNode 
							rightNodePos = rightNodePos - rightTangent
							local newNode = newNodeWithPosition(rightNodePos, getNextNodeId())
							entity.comp.node0 = newNode.entity
							setTangents(entity, rightTangent)
							addNode(newNode)
							table.insert(edgesToAdd, entity)
							rightTangent = segLength * vec3.normalize(rightTangent)
							rightNode = newNode.entity
							replacedRightNode = true
						end 
					end	
					
				end 
			end
		end 
		
		
		
		if #leftSegs == 2 and not util.isCornerNode(leftNode) and not adjustedLeftTangent then 
			trace("Not connecting to dead end node on left, creating junction instead")
			leftTangent = util.rotateXY(leftTangent, math.rad(90))
			local testPos = leftNodePos + 80*vec3.normalize(leftTangent)
			if util.distance(testPos, rightNodePos) > util.distance(rightNodePos, leftNodePos) then
				leftTangent = util.rotateXY(leftTangent, math.rad(180))
				trace("Correcting left tangent by 180")
			end
		elseif not replacedLeftNode and not util.isCornerNode(leftNode) then  
			if util.getStreetTypeCategory(leftSegs[1]) == "country" and not util.isIndustryEdge(leftSegs[1]) then 
				local leftSegCopy = util.copyExistingEdge(leftSegs[1], nextEdgeId())
				local testEntity = initSegmentAndEntity()
				if leftSegCopy.streetEdge.streetType ~= testEntity.streetEdge.streetType or leftSegCopy.streetEdge.hasBus ~= testEntity.streetEdge.hasBus or testEntity.streetEdge.tramTrackType < params.tramTrackType then 
					trace("Removing leftSegs[1]",leftSegs[1])
					removedOnlyEdges[leftSegs[1]]=true
					table.insert(edgesToRemove, leftSegs[1])
					alreadySeenCollissionEdges[leftSegs[1]]=true
					
					leftSegCopy.streetEdge.streetType = testEntity.streetEdge.streetType
					leftSegCopy.streetEdge.hasBus = leftSegCopy.streetEdge.hasBus or testEntity.streetEdge.hasBus 
					leftSegCopy.streetEdge.tramTrackType = math.max(leftSegCopy.streetEdge.tramTrackType, params.tramTrackType)
					table.insert(edgesToAdd, leftSegCopy)
				end
			end
		end
		

		if #rightSegs == 2 and not util.isCornerNode(rightNode) and not adjustedRightTangent then 
			rightTangent = util.rotateXY(rightTangent, math.rad(90))
			trace("Not connecting to dead end node on right, creating junction instead")
			local testPos = rightNodePos - 80*vec3.normalize(rightTangent)
			if util.distance(testPos, leftNodePos) > util.distance(rightNodePos, leftNodePos) then
				rightTangent = util.rotateXY(rightTangent, math.rad(180))
				trace("Correcting rightTangent tangent by 180")
			end
		elseif not replacedRightNode and not util.isCornerNode(rightNode) then 
			if util.getStreetTypeCategory(rightSegs[1]) == "country" and not util.isIndustryEdge(rightSegs[1]) then 
				local rightSegCopy = util.copyExistingEdge(rightSegs[1], nextEdgeId())
				local testEntity = initSegmentAndEntity()
				if rightSegCopy.streetEdge.streetType ~= testEntity.streetEdge.streetType or rightSegCopy.streetEdge.hasBus ~= testEntity.streetEdge.hasBus or testEntity.streetEdge.tramTrackType < params.tramTrackType then 
					trace("Removing rightSegs[1]",rightSegs[1])
					table.insert(edgesToRemove, rightSegs[1])
					removedOnlyEdges[rightSegs[1]]=true
					rightSegCopy.streetEdge.streetType = testEntity.streetEdge.streetType
					rightSegCopy.streetEdge.hasBus = rightSegCopy.streetEdge.hasBus or testEntity.streetEdge.hasBus 
					rightSegCopy.streetEdge.tramTrackType = math.max(rightSegCopy.streetEdge.tramTrackType, params.tramTrackType)
					table.insert(edgesToAdd, rightSegCopy)
				end
			end
		end
	end
	local straightvec = rightNodePos-leftNodePos
	trace("leftEdgeId=",leftEdgeId,"rightEdgeId=",rightEdgeId,"lf=",lf,"rf=",rf, " leftNode=",leftNode," rightNode=",rightNode )
	local station1tangent = leftTangent -- need to save this off here for use by depot (in case we add an extra curve section)
	
	

	--if routeEvaluation.needsSpiral(leftNodePos, rightNodePos, maxGradient) then
	--	nodecount = nodecount + params.spiralNodeCount
	--end
	local requiresLeftCrossover=true
	local requiresRightCrossover=true
	
	
	local leftangle = math.deg(vec2.angle(straightvec, leftTangent))
	local rightangle = math.deg(vec2.angle(straightvec, rightTangent))
	trace("leftangle=", leftangle, " rightangle=", rightangle, " while inspecting ", straightvec.x, ",", straightvec.y, " against rightTangent ", rightTangent.x, ",", rightTangent.y, " xyAngle=", vec3.xyAngle(straightvec), " rightTangentXyangel=", vec3.xyAngle(rightTangent), " right rot angle = ",  math.deg(vec2.angle(vec2.rotate90(straightvec),rightTangent)), " rightrot angel other=",  math.deg(vec2.angle(straightvec,vec2.rotate90(rightTangent))))
	
	
	local function setBridge(entity, split, prevEntity, params) 
		trace("Setting bridge at ",entity.entity)
		if entity.comp.type ~= 1 then -- check first not to override custom bridge types
			entity.comp.type = 1 -- brdige
			entity.comp.typeIndex = findBridgeType(entity, split, params)
		end
		if prevEntity and prevEntity.comp.type == 1 and params and not params.isElevated then 
			trace("Setting bridge to previous bridge type",prevEntity.comp.typeIndex)
			entity.comp.typeIndex = prevEntity.comp.typeIndex -- make sure the bridge type is consistent
		end
		
		if prevEntity and params.isTrack then -- i.e. a mainline edge
			local splitPoint = util.v3(split.newNode.comp.position)
			local tangent = util.v3(entity.comp.tangent1)
			local node = util.findDoubleTrackNode(splitPoint, tangent)
			trace("Looking  for a double track node near",splitPoint.x,splitPoint.y,"found?",node)
			if node then 
				for i, seg in pairs(util.getTrackSegmentsForNode(node)) do 
					local theirEdge = util.getEdge(seg)
					if theirEdge.type == 1 then 
						trace("Using their type for the bridge",theirEdge.typeIndex)
						entity.comp.typeIndex = theirEdge.typeIndex -- keeps it looking nice
					end 
				end 
			end 
		end
	end
	
	local function setTunnel(entity)
		entity.comp.type = 2 -- tunnel
		entity.comp.typeIndex = entity.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
	end
	
	local dummyEdge = {
			t0 = util.distance(leftNodePos,rightNodePos)*vec3.normalize(leftTangent),
			t1 = util.distance(leftNodePos,rightNodePos)*vec3.normalize(rightTangent),
			p0 = util.v3(leftNodePos, true),
			p1 = util.v3(rightNodePos, true),
	}
	if params.isDoubleTrack then -- solve the route down the median, highways are wide enough this starts to matter
		dummyEdge.p0 = 0.5*(leftNodePos + util.nodePos(otherLeftNode))
		dummyEdge.p1 = 0.5*(rightNodePos + util.nodePos(otherRightNode))
	end 
	
	if util.tracelog then debugPrint({dummyEdge=dummyEdge}) end
	
	if not params.isTrack and not params.isHighway  or params.isForceSingleSegment  then 
		trace("Checking nodes ",leftNode, rightNode)

		if getAdjustedDistance(leftNodePos, rightNodePos, params) < 2*params.targetSeglenth or params.isForceSingleSegment then 
			trace("Building single segment connection")
			local entity = initSegmentAndEntity()
			if entity.type == 0 then 
				entity.streetEdge.streetType = util.getStreetEdge(leftEdgeId).streetType -- copy the street type from existing
			end 
			entity.comp.node0 = leftNode 
			entity.comp.node1 = rightNode 
			local length = util.calculateTangentLength(dummyEdge.p0, dummyEdge.p1, dummyEdge.t0, dummyEdge.t1)
			setTangent(entity.comp.tangent0, length*vec3.normalize(dummyEdge.t0))
			setTangent(entity.comp.tangent1, length*vec3.normalize(dummyEdge.t1))
			table.insert(edgesToAdd, entity)
			local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
			local testResult = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
			if util.tracelog and #testResult.errorState.messages > 0 then 
				debugPrint(testResult.errorState.messages) 
			end
			if testResult.errorState.critical then 
				trace("Discovered critical error attempting to fix with tangnets")
			 
				setTangent(entity.comp.tangent0, nodePos(rightNode)-nodePos(leftNode))
				setTangent(entity.comp.tangent1, nodePos(rightNode)-nodePos(leftNode))
				newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
				testResult = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
				trace("Still critical?",testResult.errorState.critical)
				if testResult.errorState.critical then 
					return false
				end
			end 
			local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
			trace("About to sent command")
				--if tracelog then debugPrint(build) end
			util.clearCacheNode2SegMaps() 
			api.cmd.sendCommand(build, callback)
			return true
		end
	end
	
	local prevnode = leftNode
	local prevNode2 = otherLeftNode
	local prevNode3  
	local prevNode4
	if params.isQuadrupleTrack then 
		prevNode3 = util.findDoubleTrackNode(leftNodePos, -1*leftTangent, 1, 1, true, { [leftNode]=true, [otherLeftNode]=true })
		if not prevNode3 then 
		
			prevNode3 = util.findDoubleTrackNode(leftNodePos, -1*leftTangent, 2, 1, true, { [leftNode]=true, [otherLeftNode]=true })
				trace("WARNING! No prevNode3 found, attempting to compansate found?",prevNode3~=nil)
		end 
		prevNode4 = util.findDoubleTrackNode(nodePos(otherLeftNode), leftTangent, 1, 1, true, { [leftNode]=true, [otherLeftNode]=true })
		if not prevNode4 then  
			prevNode4 = util.findDoubleTrackNode(nodePos(otherLeftNode), leftTangent, 2, 1, true, { [leftNode]=true, [otherLeftNode]=true })
			trace("WARNING! No prevNode3 found, attempting to compansate found?",prevNode4~=nil)
		end 
	
	end
	trace("Found the prevNodes as ", prevnode, prevNode2, prevNode3, prevnode4)
	local prevtangent = leftTangent
	params.leftEdgeId = leftEdgeId 
	params.rightEdgeId = rightEdgeId
	if isDoubleTrack then 
		params.otherLeftEdge = util.getSegmentsForNode(otherLeftNode)[1]
		params.otherRightEdge = util.getSegmentsForNode(otherRightNode)[1]
	end 	
	params.suppressSpiral = false
	profiler.beginFunction("evaluateRoute")
	local routePoints= routeEvaluation.evaluateRoute(nodecount, dummyEdge, params)
	profiler.endFunction("evaluateRoute")
	if params.drawRoutes then 
		callback({resultProposalData = { costs = 0}},true)
		return true 
	end 
	if params.newNodeCount then 
		trace("Node count was changed, previously",nodecount, " now ",params.newNodeCount)
		nodecount = params.newNodeCount
		params.newNodeCount = nil
	end
	if not params.isDoubleTrack then -- this is here purely for debug
		assert(util.positionsEqual(routePoints[0].p, leftNodePos), "Left position changed "..posToString(routePoints[0].p).." vs "..posToString(leftNodePos))
		if not routePoints[nodecount+1] then	
			debugPrint({routePoints=routePoints})
		end
		if not routePoints[nodecount+1].p.z == rightNodePos.z then 
			trace("WARNING! Height change in right node detected:",routePoints[nodecount+1].p.z,"vs",rightNodePos.z)
			routePoints[nodecount+1].p.z = rightNodePos.z
		end 
		assert(util.positionsEqual(routePoints[nodecount+1].p, rightNodePos), "Right position changed "..posToString(routePoints[nodecount+1].p).." vs "..posToString(rightNodePos))	
	end
	if params.maxBuildDist then 
		local dist  = 0 
		for i = 1, nodecount+1 do 
			local before = routePoints[i-1]
			local this = routePoints[i]
			 
			dist = dist + util.calculateSegmentLengthFromNewEdge({p0=before.p, p1=this.p, t0=before.t2, t1=before.t})
		end 
		if dist > params.maxBuildDist then 
			trace("Aborting route build because the dist", dist," was greater than the max build dist",params.maxBuildDist)
			params.failedMaxBuildDist = true 
			return false 
		end
	end 
	local isTerminus1 = params.station1 and util.isStationTerminus(params.station1) or  params.station1 and params.terminusIdxs and params.terminusIdxs[util.indexOf(params.allStations,params.station1)]
	local isTerminus2 = params.station2 and util.isStationTerminus(params.station2) or params.station2 and params.terminusIdxs and params.terminusIdxs[util.indexOf(params.allStations,params.station2)]
	local splitResult = routePreparation.prepareRoute(dummyEdge, routePoints, nodecount, params)
	local splits = splitResult.splits
	local allCollisionEdges = splitResult.allCollisionEdges	
	nodecount = #splits
	if params.isHighway then -- offset the first edge by half the distance between roads
		local offset = ( util.getStreetWidth(streetType)+params.highwayMedianSize ) / 2
		for i=1, nodecount do
			local splitPoint = util.v3(splits[i].newNode.comp.position)
			local offsetPoint = util.nodePointPerpendicularOffset(splitPoint, splits[i].t1, -offset)
			util.setPositionOnNode(splits[i].newNode, offsetPoint)
			splits[i].p1 = offsetPoint 
		end 
	
	elseif params.isDoubleTrack then 
		local offset = params.trackWidth/2
		for i=1, nodecount do
			local splitPoint = util.v3(splits[i].newNode.comp.position)
			local offsetPoint = util.nodePointPerpendicularOffset(splitPoint, splits[i].t1, -offset)
			util.setPositionOnNode(splits[i].newNode, offsetPoint)
			splits[i].p1 = offsetPoint 
		end 
	end 	
	
	local halfway = math.floor(nodecount/2)
	local function isAddSignals(i)
		if not params.isTrack then return false end
		if params.useDoubleTerminals then 
			if i==1 and not isTerminus1 then 
				return false 
			end
			if i == nodecount or i == 2 then 
				return true 
			end
		end 
		if i == 2 then 
			return otherLeftNode == leftNode
		end 
		if i == 1 then 
			return otherLeftNode ~= leftNode and  #leftEdge.objects == 0
		end 
		if i == nodecount then  -- N.B. the last actual edge occurs at nodecount+1
			return  otherRightNode == rightNode 
		end 
		if i == nodecount-1 then 
			--return otherRightNode == rightNode
		end 
		
		
	--	local firstSignal = requiresLeftCrossover and 2 or 1
		return math.abs(i-halfway) % signalInterval == 0  
	end
	
	local prevNodeEntity2
--[[	local depot1ConnectIdx = 3
	if not isDoubleTrack then
		depot1ConnectIdx = depot1ConnectIdx - 1
	end]]--
	
	
	alreadySeenCollissionEdges[leftEdgeId]=true
	alreadySeenCollissionEdges[rightEdgeId]=true
	local prevEntity
	local prevEntity2
	local highwayCrossings = {}

	
	local mainLineEdges ={}
	local mainLineEdges2 ={}
	local mainLineEdges3 ={}
	local mainLineEdges4 ={}
	
	local function correctPriorBridgeTypes(typeIndex)
		for i = #mainLineEdges, 1, -1 do 
			if mainLineEdges[i].comp.type ~= 1 then 
				break 
			end 
			mainLineEdges[i].comp.typeIndex = typeIndex
			if mainLineEdges2[i] and  mainLineEdges2[i].comp.type ==1 then 
				mainLineEdges2[i].comp.typeIndex = typeIndex
			end 
			if mainLineEdges3[i] and  mainLineEdges3[i].comp.type ==1 then 
				mainLineEdges3[i].comp.typeIndex = typeIndex
			end 
			if mainLineEdges4[i] and  mainLineEdges4[i].comp.type ==1 then 
				mainLineEdges4[i].comp.typeIndex = typeIndex
			end 
		end 
	end
	local function getOrMakeReplacedEdge(edgeId, node)
		if node then 
			local possibleEdge = splitEdgesMap[edgeId] and splitEdgesMap[edgeId][node]
			if possibleEdge then 
				trace("getOrMakeReplacedEdge: Found possible split edge for edgeId",edgeId,"node=",node,"possibleEdge",possibleEdge.entity)
				return possibleEdge
			end 
		end 
		if not replacedEdgesMap[edgeId] then 
			local entity = util.copyExistingEdge(edgeId, nextEdgeId())
			trace("Created entity",entity.entity," to replace edge",edgeId)
			table.insert(edgesToAdd, entity)
			if not removedOnlyEdges[edgeId] then 
				trace("Removing seg",edgeId)
				table.insert(edgesToRemove, edgeId)
			end
			replacedEdgesMap[edgeId] =entity
		end 
		return replacedEdgesMap[edgeId]
	end 
	local function nodeIsOverWater(node)
		local p= nodePos(node)	
		return  p.z >0 and util.isUnderwater(p)
	end
	local function nodeIsBridgeCandidate(node)
		local p= nodePos(node)
		return p.z - math.min(util.th(p), util.th(p,true)) > 10
			or nodeIsOverWater(node)
	end 
	
	local function nodeIsTunnelCandidate(node) 
		local p= nodePos(node)
		return  math.max(util.th(p), util.th(p,true)) - p.z > 10
		 
	end 
	
	
	local function applyHeightOffsetsToNode(node, offset, alreadySeen) 
		--local newNodeMap = {}
		--local replacedEdgesMap = {}
		--local oldToNewNodeMap = {}
		trace("applyHeightOffsetsToNode, recieved request to offset ",node," by ",offset)
		if not alreadySeen then 
			alreadySeen = {}
		end 
		if alreadySeen[node] then 
			trace("Skipping ",node," as alreadSeen")
			return 
		end 
		if splitResult.reRouteNodes[node] then 
			trace("Skipping",node,"as it was a reroute node")
			return 
		end 
		if math.abs(offset) < 1 then 
			trace("Skipping",node,"as offset was under threshold",offset)
			return
		end 
		if node > 0 then 
			if util.isNodeConnectedToFrozenEdge(node) then 
				trace("Skipping",node,"as connected to frozen edge")
				return
			end 
			if util.contains(nodepair, node) then 
				trace("Attempting change original node",node, "aborting")
				return 
			end
			for i, seg in pairs(util.getSegmentsForNode(node)) do 
				if   removedOnlyEdges[seg] or seg == leftEdgeId or seg == rightEdgeId then 
					trace("Got instruction to offset node",node, " by ",offset," but this is already removed aborting at seg",seg)
					return 
				end
				if not oldToNewNodeMap[node] and util.contains(edgesToRemove, seg) then -- avoid condition where we already replaced an edge to make a grade crossing then try to apply height offset later
					trace("Aborting applying height offset to node as it was already in edges to remove without a new node created")
					return 
				end 
			end 
			for trackOffset=1, 4 do 
				local strict = true 
				local tolerance = 1
				local otherNode = util.findDoubleTrackNode(node, nil, trackOffset, tolerance, strict, alreadySeen)
				trace("Checking for other nodes at ",trackOffset," found otherNode?",otherNode)
				if otherNode then 
					applyHeightOffsetsToNode(otherNode, offset, alreadySeen) 
				end 
			end 
		end


		alreadySeen[node] = true
		if node < 0 then 
			local newNode = newNodeMap[node]
			local oldNode = newToOldNodeMap[node] 
			if oldNode then 
				local oldNodePos = nodePos(oldNode)
				local originalZ = util.getNode(oldNode).position.z
				local z = originalZ + offset 
				local zExisting = newNode.comp.position.z 
				if offset < 0 then 
					if util.isUnderwater(oldNodePos) and z < 15 then 
						trace("Suppressing the change that would push it too close to water")
					else 
						newNode.comp.position.z = math.min(zExisting, z)
					end
				else 
					newNode.comp.position.z = math.max(zExisting, z)
				end 
			else
				trace("WARNING! No old node found, may have excessive offset")
				newNode.comp.position.z = newNode.comp.position.z + offset
			end 
			trace("Applying offset",offset," to newNode, new height is ",newNode.comp.position.z)			
			return
		end 
		if math.abs(offset)<1 then -- do not make trivial corrections
			if offset> 0 then 
				return 
			end
			local foundCableOrSuspension = false 
			for i , seg in pairs(util.getSegmentsForNode(node)) do 
				local edge = util.getEdge(seg) 
				if edge.type == 1 and (edge.typeIndex == cable or edge.typeIndex==suspension) then 
					foundCableOrSuspension = true 
					break 
				end 
			end 
			if not foundCableOrSuspension then 
				return 
			end
				
		end
		
		 
		
		if util.isNodeConnectedToFrozenEdge(node) then 
			trace("WARNING! Cannot apply offset due to frozen edge",seg)
			return false 
		end 
		
		local function checkMaxGradient(testNode, recusionLimit)
			if recusionLimit == 0 then 
				return 
			end
			recusionLimit = recusionLimit - 1
			for i, seg in pairs(util.getSegmentsForNode(testNode)) do 
				if util.isFrozenEdge(seg) then 
					return
				end
				local edge = util.getEdge(seg) 
				local otherNode = node == edge.node0 and edge.node1 or edge.node0 
				if util.isNodeConnectedToFrozenEdge(otherNode) then 
					local maxGrad = util.getMaxBuildGradient(seg)
					local nodeP = nodePos(node)
					local otherNodePos =  nodePos(otherNode)
					local dist = vec2.distance(nodeP,otherNodePos)
					local maxDeltaZ = dist*maxGrad
					local proposedZ = nodeP.z + offset 
					local proposedDeltaz = proposedZ-otherNodePos.z 
					if math.abs(proposedDeltaz) > maxDeltaZ then 
						trace("WARNING! The offset",offset," gives proposedDeltaz",proposedDeltaz," for seg",seg," is too high compared to the max",maxDeltaZ,"maxGrad=",maxGrad)
						if offset < 0 then 
							offset = math.min((otherNodePos.z - maxDeltaZ) -nodeP.z , 0)
						else 
							offset = math.max(nodeP.z - (otherNodePos.z + maxDeltaZ), 0)
						end
						trace("After correction the new offset is",offset, "otherNodePos.z=",otherNodePos.z," nodePos.z=",nodeP.z)
					end  
				else 
					checkMaxGradient(otherNode, recusionLimit)
				end
			end
		end
		checkMaxGradient(node, 3)
		trace("Applying node offset",offset," to node",node)
		for i, otherNode in pairs(util.findAllDoubleTrackNodes(node)) do 
			applyHeightOffsetsToNode(otherNode, offset, alreadySeen) 
		end 
		if util.findParallelHighwayNode(node) then 
			applyHeightOffsetsToNode(util.findParallelHighwayNode(node), offset, alreadySeen) 
		end 
		local newNode = oldToNewNodeMap[node]
		local p
		if not newNode then 
 
			p = nodePos(node, true)
			trace("For node ",node," original height was ",p.z, " new height ",p.z+offset)
			p.z=p.z+offset
			newNode = newNodeWithPosition(p, getNextNodeId())
			addNode(newNode)
			oldToNewNodeMap[node]=newNode
			newToOldNodeMap[newNode.entity]=node
		
		else 
			local originalZ = util.getNode(node).position.z
			local z = originalZ + offset 
			local newNode = oldToNewNodeMap[node]
			local zExisting = newNode.comp.position.z 
			if offset < 0 then 
				if util.th(nodePos(node)) < 0 and z < 15 then 
					trace("Suppressing the change that would push it too close to water")
				else 
					newNode.comp.position.z = math.min(zExisting, z)
				end 
			else 
				newNode.comp.position.z = math.max(zExisting, z)
			end 
			p = util.v3(newNode.comp.position)
			trace("Node already present, z",z, " zExisting=",zExisting, " end height=",newNode.comp.position.z," originalZ=",originalZ)
		end 
		for i, seg in pairs(util.getSegmentsForNode(node)) do 
			trace("replacing seg",seg," attached to node ",node)
			local entity = getOrMakeReplacedEdge(seg, node)
			local otherNode
			if entity.comp.node0 == node or entity.comp.node0 == newNode.entity then 
				 entity.comp.node0=newNode.entity
				 otherNode = entity.comp.node1
			else 
				entity.comp.node1=newNode.entity
				otherNode = entity.comp.node0
			end 
			local node0 = entity.comp.node0
			local node1 = entity.comp.node1
			if offset < 0 and entity.comp.type == 1 then 
				if entity.comp.typeIndex == cable then 
					trace("Replacing cable with cement")
					entity.comp.typeIndex = cement
				end 
				if entity.comp.typeIndex == suspension then 
					trace("Replacing suspension with iron")
					entity.comp.typeIndex = iron
				end 
			end 
			 
			local otherNodePos =nodePos(otherNode)
			local grad = util.calculateGradient(otherNodePos, p)
			local maxGrad = entity.type == 0 and 0.15 or 0.06 
			if math.abs(grad) > maxGrad + 0.01  then 
			
				local dist = vec2.distance(otherNodePos, p)
				local maxDeltaZ = dist*maxGrad 
				local deltaz = otherNodePos.z - p.z 
				local correction = math.abs(deltaz)-maxDeltaZ 
				correction = math.min(correction, 0.5*math.abs(offset))
				if deltaz > 0 then 
					correction = -correction 
					
				end 
				trace("The gradient exceeds max gradient attempting to correct, deltaz=",deltaz," maxDeltaZ=",maxDeltaZ, " correction=",correction)
				applyHeightOffsetsToNode(otherNode, correction, alreadySeen)
			end 
			
			
			local needsBridge = nodeIsBridgeCandidate(node0) and nodeIsBridgeCandidate(node1) or nodeIsOverWater(node0) or nodeIsOverWater(node1) 
			local needsTunnel = nodeIsTunnelCandidate(node0) and nodeIsTunnelCandidate(node1)
			if needsBridge ~= (entity.comp.type == 1) then
				if needsBridge then 
					trace("Setting bridge on new entity for replcing seg",seg)
					entity.comp.type = 1 
					entity.comp.typeIndex = cementIsAvailable and cement or ironIsAvailable and iron or stone
				else 
					trace("Removing needs bridge on seg ", seg)
					entity.comp.type = 0
					entity.comp.typeIndex = -1
				end 
			end
			if needsTunnel ~= (entity.comp.type == 2) then 
				if needsTunnel then 
					trace("Setting tunnel on new entity for replcing seg",seg)
					entity.comp.type = 2 
					entity.comp.typeIndex = entity.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
				else 
					trace("Removing needs tunnel on seg ", seg)
					entity.comp.type = 0
					entity.comp.typeIndex = -1
				end 
			end
		end 	
	end
	local priorPointHadCollision = false
	for i=1, nodecount do
		priorPointHadCollision = false
		local split = splits[i]
		if split.newNode.entity < 0 then 
			split.newNode.entity = getNextNodeId() -- reset the id to avoid possibly colliding
		end
		local prevSplit = i > 1 and splits[i-1] or nil
		--if tracelog then debugPrint({i=i, prevnode=prevnode, leftNode=leftNode, split=split}) end
		local entity = initSegmentAndEntity() 
		local lefttunnel = prevSplit and prevSplit.tunnelCandidate or i==1 and (leftEdge.type == 2 or util.th(leftNodePos)-leftNodePos.z > 10)
		if lefttunnel and split.tunnelCandidate then 
			setTunnel(entity)
			trace("Setting tunnel at ",i)
		elseif prevSplit and split.tunnelCandidate then
			trace("Tunnel candidate at ",i," but not previous so expected to be added next split")
			--local oldPosz = prevSplit.newNode.comp.position.z 
			--prevSplit.newNode.comp.position.z = math.min(split.newNode.comp.position.z, oldPosz)
		end
		if  prevSplit and prevSplit.needsBridge and split.needsBridge
			or prevSplit and prevSplit.terrainHeight < 0 or split.terrainHeight<0	
			or i == 1 and split.needsBridge  and (leftEdge.type == 1 or leftNodePos.z-util.th(leftNodePos) > 10) then
			setBridge(entity, split, prevEntity, params)
		end
		if i == 1 and leftEdge.type == 1 and entity.comp.type == 1 then 
			entity.comp.typeIndex = leftEdge.typeIndex -- preserve the type of the connecting bridge
		end 
		
		if prevSplit and prevSplit.continueCrossingNextSeg then
			trace("Continuing crossing next seg, type was ",prevEntity.comp.type)
			entity.comp.type = prevEntity.comp.type
			entity.comp.typeIndex = prevEntity.comp.typeIndex
		end	
		
		entity.entity = nextEdgeId() 
		entity.comp.node0 = prevnode
		
		entity.comp.node1 = split.newNode.entity
		if i == 1 then 
			prevtangent = vec3.length(split.t1)*vec3.normalize(prevtangent)
		end
		setTangent(entity.comp.tangent0, prevtangent)
		setTangent(entity.comp.tangent1, split.t1)
		table.insert(edgesToAdd, entity)
		trace("Created new edge ",entity.entity," at nodeOrder=",i,"t0.z=",entity.comp.tangent0.z,"t1.z=",entity.comp.tangent1.z)
		if split.newNode.entity < 0 then
			addNode(split.newNode)
		end
		if params.isTrack and i==1 and params.useDoubleTerminals and not isTerminus1 then 
			local otherLeftLeftNode = util.findDoubleTrackNode(leftNode)
			if otherLeftLeftNode then 
				local entity2 = util.copySegmentAndEntity(entity, nextEdgeId())
				entity2.comp.node0 = otherLeftLeftNode
				trace("useDoubleTerminals: connecting segment for left node at ",entity2.entity, " otherLeftLeftNode=",otherLeftLeftNode, newEdgeToString(entity2), " copied edge:", newEdgeToString(entity), " tangentLength=",vec3.length(entity2.comp.tangent0))
				table.insert(edgesToAdd, entity2)
			else 
				trace("useDoubleTerminals: WARNING! Request to use double terminals but no other rightnode found")
			end 
		end 
		--[[local leftCollisionNode
		local leftCollisionNodePos
		local rightCollisionNode
		local rightCollisionNodePos
		local leftCollisionTangent
		local rightCollisionTangent]]--
		
		local roadCollisions = {}
		if split.collisionSegments and not params.ignoreAllOtherSegments then
			local lastMidPos
			local lastT
			local lastMidEdge
			local lastFullRightSolution
			local lastFullLeftSolution
			for __, seg in pairs(split.collisionSegments) do 
				local edgeId = seg.edge.id
				trace("Processing edge ",edgeId, " at nodeOrder=",i," original nodeOrder=",split.nodeOrder)
				if alreadySeenCollissionEdges[edgeId] then 
					trace("already seen ", edgeId, " skipping!")
					goto continue
				else 
					alreadySeenCollissionEdges[edgeId] = true
				end
				
				if params.isTrack and seg.canCrossAtGrade and split.tunnelCandidate and (prevSplit and prevSplit.tunnelCandidate or splits[i+1] and splits[i+1].tunnelCandidate) and util.getEdge(edgeId).type~=2 then 
					trace("Discovered a tunnel crossing, removing") 
					seg.canCrossAtGrade = false
					seg.applyNodeOffsetsOnly =true	
					seg.ourZCorrection = 0					
				end
				
				if params.isTrack and seg.canCrossAtGrade and split.newNode.entity < 0 then 
					local ourZ = split.newNode.comp.position.z
					local theirZ = util.getEdgeMidPoint(edgeId).z 
					local recalculatedDeltaZ = ourZ - theirZ 
					if math.abs(recalculatedDeltaZ) > 6 then 
						trace("Preventing grade crossing due to high deltaz:", recalculatedDeltaZ) 
						seg.canCrossAtGrade = false
						seg.applyNodeOffsetsOnly =true	
						seg.ourZCorrection = 0		
					end
				end 
				
				if seg.removeEdge then  
					alreadySeenCollissionEdges[edgeId] = true
					if not replacedEdgesMap[edgeId] then 
						removedOnlyEdges[edgeId]=true 
						table.insert(edgesToRemove, edgeId)  
						trace("Removing edge only",edgeId)
					end
				elseif seg.rebuildOnly then 
					alreadySeenCollissionEdges[edgeId] = true 
					local rebuilt =  getOrMakeReplacedEdge(edgeId)
					trace("Created simple rebuilt edge for",edgeId," the new id: ",rebuilt.entity)
					 
				elseif seg.reRoute then 
					for j, edgeId in pairs(seg.reRoute.edgeIds) do 
						if not removedOnlyEdges[edgeId] and (edgeId == seg.edge.id or not alreadySeenCollissionEdges[edgeId]) and not replacedEdgesMap[edgeId] then 
							removedOnlyEdges[edgeId] = true
							alreadySeenCollissionEdges[edgeId] = true 
							if edgeId == seg.edge.id and util.contains(edgesToRemove, edgeId) then 
								trace("WARNING! Attempting to remove edge already in the removal list",edgeId)
							else 
								trace("removing edge",edgeId," for reroute")
								table.insert(edgesToRemove, edgeId) 
							end
						end
					end
					local lastNode = seg.reRoute.startNode 
					local lastNodePos = nodePos(lastNode)
					local startTerrainHeight = util.th(lastNodePos)
					local lastTangent = seg.reRoute.startTangent
					local needsBridge = lastNodePos.z < 0 or lastNodePos.z - startTerrainHeight > 10 or seg.reRoute.needsBridgeStart
					local tunnelCandidate = startTerrainHeight - lastNodePos.z > 10 or seg.reRoute.tunnelCandidateStart
					for j =1 , 1+#seg.reRoute.replacementPoints do 
						local edgeToCopy = seg.reRoute.edgeIds[math.min(j, #seg.reRoute.edgeIds)]
						trace("replacing edge, ",edgeToCopy, " for reroute")
						local replacementEdge = util.copyExistingEdge(edgeToCopy, nextEdgeId())
						replacementEdge.comp.node0 = lastNode 
						setTangent(replacementEdge.comp.tangent0, lastTangent)
						if j > #seg.reRoute.replacementPoints then 
							replacementEdge.comp.node1 = seg.reRoute.endNode 
							setTangent(replacementEdge.comp.tangent1, seg.reRoute.endTangent)
							local endPos = nodePos(seg.reRoute.endNode) 
							local endTerrainHeight = util.th(endPos)
							if needsBridge and endPos.z < 0 or endPos.z - endTerrainHeight > 10  or seg.reRoute.needsBridgeEnd then 
								setBridge(replacementEdge)
							elseif tunnelCandidate and (endTerrainHeight - endPos.z > 10 or seg.reRoute.tunnelCandidateEnd) then 
								setTunnel(replacementEdge)
							else 
								replacementEdge.comp.type = 0 
								replacementEdge.comp.typeIndex = -1
							end
							table.insert(edgePositionsToCheck, {p0 = lastNodePos, p1 = endPos})
						else 
							local replacement = seg.reRoute.replacementPoints[j]
							if util.isUnderwater(replacement.p) then 
								trace("Reroute point over water, setting to min height from",replacement.p.z)
								replacement.p.z = math.max(replacement.p.z, util.getWaterLevel()+12)
							end 
							local newNode = newNodeWithPosition(replacement.p, getNextNodeId())
							addNode(newNode)
							replacementEdge.comp.node1 = newNode.entity
							setTangent(replacementEdge.comp.tangent1, replacement.t)
							lastTangent = replacement.t2
							lastNode = newNode.entity
							if needsBridge and replacement.needsBridge then 
								setBridge(replacementEdge)
							elseif tunnelCandidate and replacement.tunnelCandidate then 
								setTunnel(replacementEdge)
							else 
								replacementEdge.comp.type = 0 
								replacementEdge.comp.typeIndex = -1
							end 
							needsBridge = replacement.needsBridge
							tunnelCandidate = replacement.tunnelCandidate
							table.insert(edgePositionsToCheck, {p0 = lastNodePos, p1 = replacement.p})
							lastNodePos = replacement.p
						end
						trace("Creating reroute edge, replacementEdge had id ",replacementEdge.entity)
						table.insert(edgesToAdd, replacementEdge)
					end
				elseif not seg.canCrossAtGrade then
					local edge = seg.edge
					local edgeId = edge.id
					local deltaz = seg.deltaz
					local theirPos = seg.theirPos 
					-- get neighbouring segments (note left or right is just for convention, may not actually be on left or right)
					local leftNode = edge.node0
					local rightNode = edge.node1
					local leftNodePos = nodePos(leftNode)
					local rightNodePos = nodePos(rightNode)
					
					local leftTangent = util.v3fromArr(edge.node0tangent) 
					local rightTangent = util.v3fromArr(edge.node1tangent)
					local nextSegsLeft = util.getSegmentsForNode(leftNode)
					local leftEdgeId = nextSegsLeft[1]==edgeId and nextSegsLeft[2] or nextSegsLeft[1]			
					local nextSegsRight = util.getSegmentsForNode(rightNode) 
					local rightEdgeId = nextSegsRight[1]==edgeId and nextSegsRight[2] or nextSegsRight[1]
					local collisionEdge = util.getEdge(edgeId)
					local collisionEdgeLength = util.calculateSegmentLengthFromEdge(collisionEdge)
					--assert(split.p1.z == split.newNode.comp.position.z)
					local ourZ = split.newNode.comp.position.z
					local priorP =  prevSplit and prevSplit.newNode.comp.position or leftNodePos
					local nextP = 	i<nodecount and splits[i+1].newNode.comp.position or rightNodePos
					local ourPriorZ = util.distance(split.newNode.comp.position, priorP) < 40 and priorP.z or ourZ -- only make corrections if the other node is nearby
					local ourNextZ =  util.distance(split.newNode.comp.position, nextP) < 40 and nextP.z or ourZ
					local alreadySeenNodesForHeightOffset = {}
					if not seg.doNotCorrectOtherSeg and (replacedEdgesMap[edgeId] or leftEdgeId and replacedEdgesMap[leftEdgeId] or rightEdgeId and replacedEdgesMap[rightEdgeId]) then 
						trace("Detected already replaced an edge, setting to applyHeightOffsetsToNode")
						seg.applyNodeOffsetsOnly=true 
					end 
					if  util.getStreetTypeCategory(edgeId)=="highway" and not seg.doNotCorrectOtherSeg then 
						seg.applyNodeOffsetsOnly = true 
					end
					if not seg.doNotCorrectOtherSeg and params.applyNodeOffsetsOnly then 
						seg.applyNodeOffsetsOnly = true 
					end
					if  seg.doNotCorrectOtherSeg or seg.applyNodeOffsetsOnly  or #nextSegsLeft > 2 and #nextSegsRight > 2 or params.isHighway and util.getStreetTypeCategory(edgeId)=="highway"  then 
						priorPointHadCollision = true 
						--local offsetNeeded  = math.max(params.minZoffset-math.abs(deltaz),0) 
						local recalculatedDeltaZ =  ourZ - 0.5*(leftNodePos.z+rightNodePos.z)  
						trace("Checking offsets at ", i," original deltaz=",deltaz," recalculatedDeltaZ=",recalculatedDeltaZ," remainingDeltaz=",seg.remainingDeltaz)
						
						if not seg.remainingDeltaz then 	
							seg.remainingDeltaz = -recalculatedDeltaZ
							trace("remainingDeltaz not populated, defaulting to",seg.remainingDeltaz)
						end
						
						
						
						
						local remainingDeltaz = seg.remainingDeltaz
					-- -8.4088090054826	 recalculatedDeltaZ=	1.0893397672051	 remainingDeltaz=	1.2955954972587	 recalculated remainingDeltaz=	-6.0238737410188
						if not seg.ourZCorrection then seg.ourZCorrection = 0 end
						local expectedDeltaz = deltaz+seg.ourZCorrection
						if expectedDeltaz ~= recalculatedDeltaZ then 
							local diff = expectedDeltaz - recalculatedDeltaZ  	
							
							remainingDeltaz = remainingDeltaz - diff
							trace("Expected expectedDeltaz=",expectedDeltaz," ourZCorrection=",seg.ourZCorrection,"The diff was ",diff, " initial recaclulation gives ",remainingDeltaz," from ",seg.remainingDeltaz)
							if seg.remainingDeltaz > 0 then 
								remainingDeltaz = math.max(remainingDeltaz,0)	
							elseif seg.remainingDeltaz < 0 then  
								remainingDeltaz = math.min(remainingDeltaz,0)
							end
						end
						local offsetNeeded = remainingDeltaz
						
						if expectedDeltaz > 0 and recalculatedDeltaZ > 0 and recalculatedDeltaZ>= expectedDeltaz then 
							--trace("Setting offsetNeeded to zero as expected, recalculated were positive and recalculatedDeltaZ >= expectedDeltaz")
							--offsetNeeded =0 
						end 
						if expectedDeltaz < 0 and recalculatedDeltaZ < 0  and recalculatedDeltaZ <= expectedDeltaz then 
							--trace("Setting offsetNeeded to zero as expected, recalculated were negative and recalculatedDeltaZ <= expectedDeltaz")
							--offsetNeeded =0 
						end
						
						
						--local weAreHigher = recalculatedDeltaZ > 0
						local theirZ = 0.5*(leftNodePos.z + rightNodePos.z )
						local weAreHigher = ourZ > theirZ
						trace("Not correcting other seg. weAreHigher?",weAreHigher," offsetNeeded=",offsetNeeded," seg.applyNodeOffsetsOnly=",seg.applyNodeOffsetsOnly)
						local overWater = util.isUnderwater(leftNodePos) or util.isUnderwater(rightNodePos) or util.isUnderwater(split.newNode.comp.position)
						
						-- height adjustments to allow clearance
						if weAreHigher then -- we are higher
							local theirZ = math.max(leftNodePos.z, rightNodePos.z)
							local ourZMin = ourZ--math.min(ourZ, math.min(ourPriorZ, ourNextZ))  
							recalculatedDeltaZ = ourZMin - theirZ 
							trace("Recalcualted deltaz for the worst case, theirZ=",theirZ," ourZ=",ourZMin, " recalculatedDeltaZ=",recalculatedDeltaZ)
							offsetNeeded = math.min(math.max(params.minZoffset, math.abs(offsetNeeded)), math.max(0, params.minZoffset-recalculatedDeltaZ))
							trace("we are higher: recalculated offsetNeeded=",offsetNeeded)
						 
							if seg.applyNodeOffsetsOnly and not overWater then 
								local leftOffsetNeeded = offsetNeeded
								local rightOffsetNeeded = offsetNeeded 
								local leftNodeHeight = nodePos(leftNode).z 
								if oldToNewNodeMap[leftNode] then 
									leftNodeHeight = oldToNewNodeMap[leftNode].comp.position.z
								end 
								local leftGap = leftNodeHeight -theirPos.p1.z
								if leftGap > 0 then 
									trace("Increasing left node offset by ",leftGap)
									leftOffsetNeeded = leftOffsetNeeded + leftGap
								end 
								local rightNodeHeight = nodePos(rightNode).z 
								if oldToNewNodeMap[rightNode] then 
									rightNodeHeight = oldToNewNodeMap[rightNode].comp.position.z
								end 
								local rightGap = rightNodeHeight -theirPos.p1.z
								if rightGap > 0 then 
									trace("Increasing right node offset by ",rightGap)
									rightOffsetNeeded = rightOffsetNeeded + rightGap
								end 
								applyHeightOffsetsToNode(leftNode, -leftOffsetNeeded, alreadySeenNodesForHeightOffset)
								applyHeightOffsetsToNode(rightNode, -rightOffsetNeeded, alreadySeenNodesForHeightOffset)
							elseif math.abs(offsetNeeded) > 0.1 then
								if i <= 2 or i >= nodecount-1 then 
									local testP = i<=2 and leftNodePos or rightNodePos
									local dist = vec2.distance(testP, split.p1) 
									local maxUpperHeight = dist*params.absoluteMaxGradient + testP.z 
									if split.p1.z + offsetNeeded > maxUpperHeight then 
										trace("The height offset is too much correcting",offsetNeeded," minLowerHeight=",maxUpperHeight)
										offsetNeeded = math.max(maxUpperHeight - split.p1.z ,0)
										if entity.comp.type == 1 and entity.comp.typeIndex == suspension then 
											for i = #mainLineEdges, 1, -1 do 
												if mainLineEdges[i].comp.type ~= 1 then 
													break 
												end 
												mainLineEdges[i].comp.typeIndex = cement 
												if mainLineEdges2[i] and mainLineEdges2[i].comp.type==2 then 
													 mainLineEdges2[i].comp.typeIndex = cement
												end 
											end 
										end 
									end 
								end 
								trace("increasing height by applying height offset at ",i," by ",offsetNeeded," to pass colliding segment, deltaz=",deltaz)
								applyHeightOffset(splits, offsetNeeded, i,  params.absoluteMaxGradient) 
							end
							
							--applyHeightOffset(splits, offsetNeeded, i-1, maxGradient) 
							local theirEdgeType
							if replacedEdgesMap[edgeId] then 
								theirEdgeType = replacedEdgesMap[edgeId].comp.type
							else 
								theirEdgeType = util.getEdge(edgeId).type
							end 
							trace("TheirEdgetype was",theirEdgeType,"for edgeId=",edgeId,"was replaced?",replacedEdgesMap[edgeId]," we are higher")
							if theirEdgeType ~= 2 then -- they are not tunnel
								trace("setting crossing bridge on ",entity.entity," as their type was ",theirEdgeType," original edgeid=",edgeId)
								setCrossingBridge(entity, params, seg.ourRequiredSpan, prevEntity, false, recalculatedDeltaZ)
								if prevEntity and prevEntity.comp.type == 1 and prevEntity.comp.typeIndex ~= entity.comp.typeIndex then 
									correctPriorBridgeTypes(entity.comp.typeIndex)
								end
							end
							--[[if prevEntity then
								setBridge(prevEntity)
							end
							if prevEntity2 then
								setBridge(prevEntity2)
							end--]]
								
						else -- they are higher
							local theirZ = math.min(leftNodePos.z, rightNodePos.z)
							local ourZMax = ourZ -- math.max(ourZ, math.max(ourPriorZ, ourNextZ))
							recalculatedDeltaZ = ourZMax - theirZ 
							trace("Recalcualted deltaz for the worst case, theirZ=",theirZ," ourZ=",ourZ,"ourPriorZ=",ourPriorZ,"ourNextZ=",ourNextZ," ourZMax=",ourZMax, " recalculatedDeltaZ=",recalculatedDeltaZ)
							
							offsetNeeded = math.max(-math.max(params.minZoffset,math.abs(offsetNeeded)), math.min(0, -params.minZoffset-recalculatedDeltaZ))
							trace("they are higher: recalculated offsetNeeded=",offsetNeeded)
							 
							if seg.applyNodeOffsetsOnly then 
								local leftOffsetNeeded = offsetNeeded
								local rightOffsetNeeded = offsetNeeded 
								local leftNodeHeight = nodePos(leftNode).z 
								if oldToNewNodeMap[leftNode] then 
									leftNodeHeight = oldToNewNodeMap[leftNode].comp.position.z
								end 
								local leftGap = theirPos.p1.z-leftNodeHeight
								if leftGap > 0 then 
									trace("Increasing left node offset by ",leftGap)
									leftOffsetNeeded = leftOffsetNeeded - leftGap
								end 
								local rightNodeHeight = nodePos(rightNode).z 
								if oldToNewNodeMap[rightNode] then 
									rightNodeHeight = oldToNewNodeMap[rightNode].comp.position.z
								end 
								local rightGap = theirPos.p1.z-rightNodeHeight 
								if rightGap > 0 then 
									trace("Increasing right node offset by ",rightGap)
									rightOffsetNeeded = rightOffsetNeeded - rightGap
								end 
								applyHeightOffsetsToNode(leftNode, -leftOffsetNeeded, alreadySeenNodesForHeightOffset)
								applyHeightOffsetsToNode(rightNode, -rightOffsetNeeded, alreadySeenNodesForHeightOffset)
							elseif math.abs(offsetNeeded) > 0.1 then 
								if i <= 2 or i >= nodecount-1 then 
									local testP = i<=2 and leftNodePos or rightNodePos
									local dist = vec2.distance(testP, split.p1) 
									local minLowerHeight = -dist*params.absoluteMaxGradient + testP.z 
									if split.p1.z + offsetNeeded < minLowerHeight then 
										trace("The height offset is too much correcting ",offsetNeeded," minLowerHeight=",minLowerHeight)
										offsetNeeded = math.min(minLowerHeight - split.p1.z ,0)
									end 
								end 
								trace("reducing height by applying height offset at ",i," by  ",offsetNeeded," to pass colliding segment, deltaz=",deltaz)
								applyHeightOffset(splits, offsetNeeded, i, params.absoluteMaxGradient)
							end 
							--applyHeightOffset(splits, -offsetNeeded, i-1, maxGradient) 
							
							local theirEdgeType
							if replacedEdgesMap[edgeId] then 
								theirEdgeType = replacedEdgesMap[edgeId].comp.type
							else 
								theirEdgeType = util.getEdge(edgeId).type
							end 
							trace("TheirEdgetype was",theirEdgeType,"for edgeId=",edgeId,"was replaced?",replacedEdgesMap[edgeId]," they are higher")
							
							if theirEdgeType ~= 1 then -- they are not bridge
								setTunnel(entity)
							else 
								trace("Rebuilding edge ",edgeId)
--								table.insert(edgesToRemove, edgeId) 
								if not util.isFrozenEdge(edgeId) then 
									local replacement = getOrMakeReplacedEdge(edgeId)
									if replacement.comp.type ==1 then 
										trace("Their edge type was ",api.res.bridgeTypeRep.getName(replacement.comp.typeIndex))
										if replacement.comp.typeIndex == cable or replacement.comp.typeIndex == suspension then 
											setCrossingBridge(entity, params, seg.theirRequiredSpan, nil, true, recalculatedDeltaZ) 
										end 
									end
									
									trace("Rebuilt edge has id ",replacement.entity)
								else	 
									trace("Edge was frozen, cannot replace")
								end 
	--							table.insert(edgesToAdd, replacement)
							end 
							--[[
							if prevEntity then
								setTunnel(prevEntity)
							end
							if prevEntity2 then
								setTunnel(prevEntity2)
							end--]]
						end
						goto continue
					end
					
					if replacedEdgesMap[edgeId] or removedOnlyEdges[edgeId] then 
						trace("Unable to replace ",edgeId , " already removed")
						goto continue 
					end
					
					--local leftEdgeId = nextSegsLeft[1]==edgeId and nextSegsLeft[2] or nextSegsLeft[1]
					
					
					local trackWidth = params.trackWidth
					theirPos.t1.z = 0 -- keep the two nodes at the same height
					theirPos.t2.z = 0 
					local trackCrossWidth = trackWidth
					local bridgeMidPos = theirPos.p1
					trace("Initial bridgeMidPos was ",bridgeMidPos.x, bridgeMidPos.y)
					local tnrml = vec3.normalize(theirPos.t1)
					local crossingAngle = util.signedAngle(tnrml, split.t1)
					if isDoubleTrack then
						trackCrossWidth = 2*trackWidth
						trace("adjusting bridge postiion, angel was ",math.deg(crossingAngle))
						if crossingAngle > 0 then
							--bridgeMidPos = bridgeMidPos - (trackWidth/2)*tnrml
						else 
							--bridgeMidPos = bridgeMidPos + (trackWidth/2)*tnrml
						end
					end
					local function checkIfShouldRemove(otherEdgeId)
						if not otherEdgeId or util.isFrozenEdge(otherEdgeId) or alreadySeenCollissionEdges[otherEdgeId] or replacedEdgesMap[otherEdgeId] then 
							return false 
						end 
						if util.edgeHasTpLinks(otherEdgeId) then 
							trace("Suppressing removal of ",otherEdgeId," as it has tp links")
							return false
						end 
						--if not params.isTrack then 
							local otherEdge = util.getEdge(otherEdgeId)
							if #util.getTrackSegmentsForNode(otherEdge.node0) > 2 or #util.getTrackSegmentsForNode(otherEdge.node1) > 2    then 
								trace("Suppressing removal of ",otherEdgeId," as it contains a track junction edge")
								return false 
							end
						--end 
						return true
					end
					local function checkIfCanReposition(otherEdgeId)
						if alreadySeenCollissionEdges[otherEdgeId] then 
							return false 
						end
						if util.edgeHasTpLinks(otherEdgeId) then 
							trace("Suppressing reposition of ",otherEdgeId," as it has tp links")
							return false
						end 
						local otherEdge = util.getEdge(otherEdgeId)
						
						return not (  -- check for another crossing edge 
							util.calculateSegmentLengthFromEdge(otherEdge) <= params.maxCrossingBridgeSpanSuspension 
							and collisionEdgeLength > seg.theirRequiredSpan
							and otherEdge.type ~= 0 
							and collisionEdge.type == 0)
					end
					
					-- left edge 
					
					local outerLeftTangent
					local outerLeftNode 
					local leftEdge  
					local shouldRemoveLeftEdge  = checkIfShouldRemove(leftEdgeId)
					local leftLength 
					if shouldRemoveLeftEdge then
						leftEdge  = util.getEdge(leftEdgeId)
						outerLeftNode = leftEdge.node0 == leftNode and leftEdge.node1 or leftEdge.node0
						outerLeftTangent =  leftEdge.node0 == leftNode and -1*util.v3(leftEdge.tangent1) or util.v3(leftEdge.tangent0)
						leftLength = collisionEdgeLength + util.calculateSegmentLengthFromEdge(leftEdge)
					else 
						trace("NOT removing left")
						outerLeftNode = leftNode 
						outerLeftTangent = leftTangent
						leftEdgeId = edge.id
						leftEdge = util.getEdge(leftEdgeId)
						leftLength = collisionEdgeLength
					end
					trace("caluclated requiredSpan as ",seg.theirRequiredSpan,"for angle",math.deg(crossingAngle))
					local foundDoubleTrackNode = false
					if lastMidPos and vec2.distance(lastMidPos, bridgeMidPos) < 10 then -- dealing with another double track node
						local angle = util.signedAngle(tnrml,bridgeMidPos - lastMidPos)
						local tangentAngle = util.signedAngle(tnrml, lastT)
						tnrml = lastT
						if math.abs(math.deg(tangentAngle))>90 then -- actually closer to 180, means its inverted, need to swap
							tnrml = -1*tnrml
						end
						local testNode = util.findDoubleTrackNode(outerLeftNode)
						if testNode then 
							local doubleTrackVector = nodePos(testNode)- nodePos(outerLeftNode)
							
							bridgeMidPos =util.doubleTrackNodePoint(lastMidPos, tnrml)
							local ourDoubleTrackVector = bridgeMidPos - lastMidPos
							local testAngle = util.signedAngle(doubleTrackVector, ourDoubleTrackVector)
							if util.checkFor2dCollisionBetweenPoints(nodePos(outerLeftNode), bridgeMidPos, nodePos(testNode), lastMidPos) then
							
	--						if math.abs(testAngle) > math.rad(90) then 
							
								bridgeMidPos = util.doubleTrackNodePoint(lastMidPos, -1*tnrml)
								ourDoubleTrackVector = bridgeMidPos - lastMidPos
								trace("Swapping position of double track node on their line as the angle was ",math.deg(testAngle), "new angle was ",math.deg(util.signedAngle(doubleTrackVector, ourDoubleTrackVector)))
							end
							
							trace("found a double track node at angle ",math.deg(angle)," last z=",lastMidPos.z, " this z =", bridgeMidPos.z, "tangentAngle=",tangentAngle," test angle was ",math.deg(testAngle))
							foundDoubleTrackNode = true
						end
					end
					lastT = tnrml
					lastMidPos = bridgeMidPos
					local tmid = (seg.theirRequiredSpan/2)*tnrml -- tangent from the mid point on the bridge to the end
										
			
					local outerLeftNodePos = nodePos(outerLeftNode)
					
					--right edge 
					
					local shouldRemoveRightEdge  = checkIfShouldRemove(rightEdgeId)
					local rightEdge
					local outerRightNode
					local outerRightTangent
					local rightLength
					if shouldRemoveRightEdge then
						rightEdge  = util.getEdge(rightEdgeId)
						outerRightNode = rightEdge.node1 == rightNode and rightEdge.node0 or rightEdge.node1
						outerRightTangent = rightEdge.node1 == rightNode and -1*util.v3(rightEdge.tangent0) or util.v3(rightEdge.tangent1)
						rightLength =  util.calculateSegmentLengthFromEdge(rightEdge)
					else 
						trace("NOT removing rightedge")
						outerRightNode = rightNode 
						rightEdgeId = edgeId
						rightEdge = util.getEdge(rightEdgeId)
						outerRightTangent = rightTangent
						rightLength = collisionEdgeLength
					end
					local length = collisionEdgeLength
					if shouldRemoveLeftEdge then 
						length = length + util.calculateSegmentLengthFromEdge(leftEdge)
					end 
					if shouldRemoveRightEdge then 
						length = length + util.calculateSegmentLengthFromEdge(rightEdge)
					end
					
					local outerRightNodePos = nodePos(outerRightNode) 
					local outerEdge = {
						p0 = outerLeftNodePos,
						p1 = outerRightNodePos,
						t0 = length * vec3.normalize(outerLeftTangent),
						t1 = length * vec3.normalize(outerRightTangent)
					}
					local leftOuterEdge = {
						p0 = outerLeftNodePos,
						p1 = rightNodePos,
						t0 = outerLeftTangent,
						t1 = rightTangent
					}
					local rightOuterEdge = {
						p0 = leftNodePos,
						p1 = outerRightNodePos,
						t0 = leftTangent,
						t1 = outerRightTangent
					}
					util.applyEdgeAutoTangents(leftOuterEdge)  
					util.applyEdgeAutoTangents(outerEdge)  
					local edgeForPosition =  edge.track  and outerEdge or leftOuterEdge
					if not edge.track and vec2.distance(leftNodePos, bridgeMidPos) > seg.theirRequiredSpan/2 then -- allows more accurate positioning at the expense of possibly increased curvature
						 trace("Solving for new left pos against their original edge") -- TODO: Why had i commented this out
						edgeForPosition = {
							p0 = leftNodePos,
							p1 = rightNodePos,
							t0 = leftTangent,
							t1 = rightTangent
						} 
					end
					--local newLeftNodePos = util.solveForNearestHermitePosition(-1 * tmid + bridgeMidPos, outerEdge)
					local canRepositionLeftNode = checkIfCanReposition(leftEdgeId)
					trace("The distance between outerLeftNodePos and bridgeMidPos was",vec2.distance(outerLeftNodePos, bridgeMidPos),"required offset=",seg.theirRequiredSpan)
					if vec2.distance(outerLeftNodePos, bridgeMidPos) < seg.theirRequiredSpan/2 then 
						trace("WARNING! Too much distance required to reposition, aborting")
						canRepositionLeftNode = false 
					end 
					local newLeftNodePos = canRepositionLeftNode and util.solveForPositionHermitePositionAtRelativeOffset(bridgeMidPos, -seg.theirRequiredSpan/2, edgeForPosition).p or nodePos(edge.node0)
					local fullLeftSolution
					if foundDoubleTrackNode and newNodeMap[lastMidEdge.comp.node0] then 
						local lastNodePos =util.v3(newNodeMap[lastMidEdge.comp.node0].comp.position)
						local lastTangent = util.v3(lastMidEdge.comp.tangent0)
						local testPos  = util.doubleTrackNodePoint(lastNodePos, lastTangent)
						local testPos2 = util.doubleTrackNodePoint(lastNodePos, -1*lastTangent)
						local d1 = util.distance(testPos, newLeftNodePos)
						local d2 = util.distance(testPos2, newLeftNodePos)
						local originalLeftNodePos = newLeftNodePos
						if d1 < d2 then 
							newLeftNodePos = testPos
						else 
							newLeftNodePos = testPos2
						end
						fullLeftSolution = lastFullLeftSolution
						local originalOuterLeftNode=outerLeftNode
						outerLeftNode = util.findDoubleTrackNode(fullLeftSolution.p0, fullLeftSolution.t0)
						trace("The original outer left node was ", originalOuterLeftNode," the corrected outerLeftNode was ", outerLeftNode, "newLeftNodePos=",newLeftNodePos.x,newLeftNodePos.y,"d1,d2=",d1,d2)
						--[[if not outerLeftNode then 
							local node = util.searchForNearestNode(nodePos(originalOuterLeftNode), 20, function(node) return node.id~=originalOuterLeftNode end)
							if node then 
								outerLeftNode=node.id 
							end 
						end]]--
						if not outerLeftNode then 
							trace("No outerleftNode found ,falling back")
							newLeftNodePos = originalLeftNodePos
							fullLeftSolution = util.solveForPosition(newLeftNodePos, edgeForPosition, vec2.distance)
							outerLeftNode = originalOuterLeftNode
							newLeftNodePos = fullLeftSolution.p1
							if not fullLeftSolution.solutionConverged then 
								trace("WARNING! Detected the fullLeftSolution did not converge")
								newLeftNodePos = nodePos(edge.node0)
							end
						end
	
						
						if originalOuterLeftNode ~= outerLeftNode then 
							trace("The outer left node WAS changed")
						end
					else 
						fullLeftSolution = util.solveForPosition(newLeftNodePos, edgeForPosition, vec2.distance)
						newLeftNodePos = fullLeftSolution.p1
						if not fullLeftSolution.solutionConverged then 
							trace("WARNING! Detected the fullLeftSolution did not converge")
							newLeftNodePos = nodePos(edge.node0)
						end
						
					end
					lastFullLeftSolution = fullLeftSolution
					
					 
					fullLeftSolution.p1.z = bridgeMidPos.z	
					fullLeftSolution.t1.z = 0 -- flatten the bridge top to avoid strange looking results	
					fullLeftSolution.t2.z = 0						
					local newLeftNode 
					local newLeftEdge 
					if not alreadySeenCollissionEdges[leftEdgeId] and not replacedEdgesMap[leftEdgeId] then 
						newLeftNode =   newNodeWithPosition(newLeftNodePos, getNextNodeId())
						addNode(newLeftNode)
						if shouldRemoveLeftEdge then 
							alreadySeenCollissionEdges[leftEdgeId] = true
							newLeftEdge = getOrMakeReplacedEdge(leftEdgeId)
						else 	
							newLeftEdge= util.copyExistingEdge(leftEdgeId, nextEdgeId()) 
							table.insert(edgesToAdd, newLeftEdge)
						end
						if newLeftEdge.comp.node0 > 0 then 
							newLeftEdge.comp.node0 = outerLeftNode
						end
						newLeftEdge.comp.node1 = newLeftNode.entity
						if fullLeftSolution.solutionConverged and vec3.length(fullLeftSolution.t0) > 0 then 
							setTangent(newLeftEdge.comp.tangent0, fullLeftSolution.t0)
							setTangent(newLeftEdge.comp.tangent1, fullLeftSolution.t1)
							leftNodePos = fullLeftSolution.p1
							leftTangent = fullLeftSolution.t2 
							trace("Setting the left tangent as the converged solution")
						end
						
						
						leftNode = newLeftNode.entity
						trace("Created leftEdge: ",newLeftEdge.entity," to replace ",leftEdgeId," the outerLeftNode was",outerLeftNode, " newNode ", newLeftNode.entity, " dist from leftOuter to midRight was ", dist)
					end
					
					
			 
					
				 
					util.applyEdgeAutoTangents(rightOuterEdge)  
					local edgeForPosition =  edge.track  and outerEdge or rightOuterEdge 
			
				 
					
					
					if not edge.track and vec2.distance(rightNodePos, bridgeMidPos) > seg.theirRequiredSpan/2 then -- allows more accurate positioning at the expense of possibly increased curvature
						trace("Solving against for right node their original edge")
						edgeForPosition = {
							p0 = nodePos(edge.node0),
							p1 = rightNodePos,
							t0 = util.v3fromArr(edge.node0tangent),
							t1 = rightTangent
						} 
					end
					--local newRightNodePos = util.solveForNearestHermitePosition(tmid + bridgeMidPos, outerEdge)
					local canRepositionRightNode = checkIfCanReposition(rightEdgeId)
					if vec2.distance(outerRightNodePos, bridgeMidPos) < seg.theirRequiredSpan/2 then 
						trace("WARNING! Too much distance required to reposition, aborting")
						canRepositionRightNode = false 
					end 
					local newRightNodePos = canRepositionRightNode and util.solveForPositionHermitePositionAtRelativeOffset(bridgeMidPos, seg.theirRequiredSpan/2, edgeForPosition).p or nodePos(edge.node1)
					local fullRightSolution
					if foundDoubleTrackNode and newNodeMap[lastMidEdge.comp.node1] then 
						local lastNodePos =util.v3(newNodeMap[lastMidEdge.comp.node1].comp.position)
						local lastTangent = util.v3(lastMidEdge.comp.tangent1)
						local testPos  = util.doubleTrackNodePoint(lastNodePos, lastTangent)
						local testPos2 = util.doubleTrackNodePoint(lastNodePos, -1*lastTangent)
						local originalNewRightNodePos = newRightNodePos
						local d1 = util.distance(testPos, newRightNodePos)
						local d2 =  util.distance(testPos2, newRightNodePos)
						if d1  < d2 then 
							newRightNodePos = testPos
						else 
							newRightNodePos = testPos2
						end
						fullRightSolution = lastFullRightSolution
						local originalOuterRightNode=outerRightNode
						outerRightNode = util.findDoubleTrackNode(fullRightSolution.p3, fullRightSolution.t3)
						trace("The original outer right node was ", originalOuterRightNode," the corrected outerRightNode was ", outerRightNode)
						--[[if not outerRightNode then 
							local node = util.searchForNearestNode(nodePos(originalOuterRightNode), 20, function(node) return node.id~=originalOuterRightNode end)
							if node then 
								outerRightNode=node.id 
							end 
						end]]--
						if not outerRightNode then 
							trace("No new outerRIghtNode found ,falling back")
							newRightNodePos = originalNewRightNodePos
							outerRightNode = originalOuterRightNode
							fullRightSolution = util.solveForPosition(newRightNodePos, edgeForPosition, vec2.distance)
							newRightNodePos = fullRightSolution.p1
							if not fullRightSolution.solutionConverged then 
								trace("WARNING! Detected the fullRightSolution did not converge")
								newRightNodePos = nodePos(edge.node1)
							end
						end
						
						if originalOuterRightNode ~= outerRightNode then 
							trace("The outer right node WAS changed")
						end
					else 
						fullRightSolution = util.solveForPosition(newRightNodePos, edgeForPosition, vec2.distance)
						newRightNodePos = fullRightSolution.p1
						if not fullRightSolution.solutionConverged then 
							trace("WARNING! Detected the fullRightSolution did not converge")
							newRightNodePos = nodePos(edge.node1)
						end
						
						if edge.track then 
							assert(util.positionsEqual2d (outerRightNodePos, fullRightSolution.p3, 1))
						end
					end
					lastFullRightSolution = fullRightSolution
					
					fullRightSolution.p1.z = bridgeMidPos.z	
					fullRightSolution.t1.z = 0
					fullRightSolution.t2.z = 0						
					local newRightNode 
					local newRightEdge
					if not alreadySeenCollissionEdges[rightEdgeId] then 
						newRightNode =  newNodeWithPosition(newRightNodePos, getNextNodeId())
						addNode(newRightNode)
						if shouldRemoveRightEdge then 
							alreadySeenCollissionEdges[rightEdgeId] = true
							newRightEdge = getOrMakeReplacedEdge(rightEdgeId)
						else 
							newRightEdge = util.copyExistingEdge(rightEdgeId, nextEdgeId()) 
							table.insert(edgesToAdd, newRightEdge)
						end
						newRightEdge.comp.node0 = newRightNode.entity
						if newRightEdge.comp.node1 > 0 then 
							newRightEdge.comp.node1 = outerRightNode
						end
						if fullRightSolution.solutionConverged and vec3.length(fullRightSolution.t2) > 0 then 
							setTangent(newRightEdge.comp.tangent0, fullRightSolution.t2)
							setTangent(newRightEdge.comp.tangent1, fullRightSolution.t3) 
						end
						
						
						trace("Created rightEdge: ",newRightEdge.entity," to replace ",rightEdgeId, " the outerRightNode was",outerRightNode, " newNode ", newRightNode.entity, " dist from midleft to outerRight was ",dist)
						rightNode = newRightNode.entity
						if fullRightSolution.solutionConverged then 
							rightNodePos = fullRightSolution.p1
							rightTangent = fullRightSolution.t1
							trace("Setting the right tangent from the fullRightSolution")
						end
					end
				
					
					
					-- mid edge
					local midEdge = getOrMakeReplacedEdge(edgeId)
					midEdge.comp.node0 = leftNode
					midEdge.comp.node1 = rightNode
					setTangent(midEdge.comp.tangent0, util.distance(leftNodePos, rightNodePos)*vec3.normalize(leftTangent))
					setTangent(midEdge.comp.tangent1, util.distance(leftNodePos, rightNodePos)*vec3.normalize(rightTangent))
					--setTangent(midEdge.comp.tangent0, leftTangent)
					--setTangent(midEdge.comp.tangent1, rightTangent)
					 
					trace(" Edge: ",midEdge.entity," to replace ",edgeId)
					local recalculatedDeltaZ = newLeftNode and split.p1.z - leftNodePos.z or deltaz
					local remainingDeltaz = seg.remainingDeltaz
					-- -8.4088090054826	 recalculatedDeltaZ=	1.0893397672051	 remainingDeltaz=	1.2955954972587	 recalculated remainingDeltaz=	-6.0238737410188
					local expectedDeltaz = deltaz+seg.ourZCorrection
					if expectedDeltaz ~= recalculatedDeltaZ then 
						local diff = expectedDeltaz - recalculatedDeltaZ 
						if (expectedDeltaz > 0) ~= (recalculatedDeltaZ > 0) then 
							trace("Detected sign change")
							if recalculatedDeltaZ > 0 then 
								remainingDeltaz = math.min(params.minZoffset-recalculatedDeltaZ,0)
							else 
								remainingDeltaz = math.max(-params.minZoffset-recalculatedDeltaZ,0)
							end 
							
						else 
						
							remainingDeltaz = remainingDeltaz - diff
							trace("Expected expectedDeltaz=",expectedDeltaz," ourZCorrection=",seg.ourZCorrection,"The diff was ",diff, " initial recaclulation gives ",remainingDeltaz," from ",seg.remainingDeltaz)
							if seg.remainingDeltaz > 0 then 
								remainingDeltaz = math.max(remainingDeltaz,0)	
							elseif seg.remainingDeltaz < 0 then  
								remainingDeltaz = math.min(remainingDeltaz,0)
							end 
						end
					end 
					
					trace("Checking offsets at ", i," original deltaz=",deltaz," recalculatedDeltaZ=",recalculatedDeltaZ," remainingDeltaz=",seg.remainingDeltaz, " recalculated remainingDeltaz=",remainingDeltaz,"ourZ=",split.p1.z,"theirZ=",leftNodePos.z)
					
					--local offsetNeeded  = math.max(params.minZoffset-math.abs(deltaz),0)
					local offsetNeeded = foundDoubleTrackNode and 0 or remainingDeltaz
					--local weAreHigher = split.p1.z >= (leftNodePos.z+rightNodePos.z)/2 and offsetNeeded >= 0
					local weAreHigher = recalculatedDeltaZ >= 0
					if (offsetNeeded > 0) == (recalculatedDeltaZ > 0) then 
						trace("Detected incorrect sign on offsetNeeded attempting to correct")
						offsetNeeded = -offsetNeeded
					end
					
					if math.abs(recalculatedDeltaZ) > params.minZoffsetSuspension then 
						trace("Setting offsetNeeded to zero")
						offsetNeeded = 0
					elseif math.abs(offsetNeeded) + math.abs(recalculatedDeltaZ) > params.minZoffsetSuspension then 
						trace("The combined height is more than requried", math.abs(offsetNeeded) + math.abs(recalculatedDeltaZ))
						if recalculatedDeltaZ > 0 then 
							offsetNeeded = -(params.minZoffsetSuspension-recalculatedDeltaZ)
						else 
							offsetNeeded = -(-params.minZoffsetSuspension-recalculatedDeltaZ)
						end 
						trace("Recalcualted offsetNeeded=",offsetNeeded)
					end 
					
					
					
					 
					
					deltaz=recalculatedDeltaZ
					local finalDeltaz  = math.abs(deltaz) + math.abs(offsetNeeded)
					
					if foundDoubleTrackNode and entity.comp.type == 1 then
						--weAreHigher = true
					end
					if lastMidEdge and foundDoubleTrackNode then 
						trace("Copying edge type details from lastMidEdge:",lastMidEdge.comp.type)
						midEdge.comp.type = lastMidEdge.comp.type 
						midEdge.comp.typeIndex = lastMidEdge.comp.typeIndex
					end
					-- height adjustments to allow clearance
					if weAreHigher then -- we are higher
						trace("increasing height at ",i," by ",offsetNeeded," to pass colliding segment, deltaz=",deltaz, " finalDeltaz=",finalDeltaz)
						local canDecreaseTheirHeight = newLeftNode and newRightNode 
						if canDecreaseTheirHeight then 
							if util.th(newLeftNode.comp.position) < util.getWaterLevel() and newLeftNode.comp.position.z + offsetNeeded < util.getWaterLevel()+15 then 
								canDecreaseTheirHeight = false 
								trace("Overriding decreasing their height due to water level")
							end 
							if util.th(newRightNode.comp.position) < util.getWaterLevel() and newRightNode.comp.position.z + offsetNeeded < util.getWaterLevel()+15 then 
								canDecreaseTheirHeight = false 
								trace("Overriding decreasing their height due to water level")
							end 
						end 
						if canDecreaseTheirHeight then 
							newLeftNode.comp.position.z = newLeftNode.comp.position.z + offsetNeeded
							newRightNode.comp.position.z = newRightNode.comp.position.z + offsetNeeded
							trace("Set their height to ",newRightNode.comp.position.z," by adding ",offsetNeeded)
						else 
							applyHeightOffset(splits, -offsetNeeded, i,  params.absoluteMaxGradient)
						end
						if entity.comp.type ~= 1 and midEdge.comp.type ~= 2 then -- we are not bridge, they are not tunnel
							if canUseBridgeForCrossing(seg.ourRequiredSpan, params) and not seg.forceTunnelTheirs and split.p1.z-split.terrainHeight > 0   then 
								trace("Setting crossing bridge on entity",entity.entity," following apply height offset")
								setCrossingBridge(entity, params, seg.ourRequiredSpan, prevEntity, false, finalDeltaz)
								if prevEntity and prevEntity.comp.type == 1 and prevEntity.comp.typeIndex ~= entity.comp.typeIndex then 
									correctPriorBridgeTypes(entity.comp.typeIndex)
								end
							else 
								trace("Setting tunnel on theirs, seg.forceTunnelTheirs was ",seg.forceTunnelTheirs)
								setTunnel(midEdge)
							end
						elseif midEdge.comp.type == 1 and (midEdge.comp.typeIndex==cable or midEdge.comp.typeIndex==suspension) then 
							trace("Setting crossing bridge on entity",midEdge.entity," following apply height offset for the midEdge")
							setCrossingBridge(midEdge, params, seg.ourRequiredSpan, nil, true, finalDeltaz)
						end
					else -- they are higher
						trace("reducing height at ",i," by ",offsetNeeded," to pass colliding segment, deltaz=",deltaz)
						local theirHeight = bridgeMidPos.z 
						if newLeftNode and newRightNode then 
							newLeftNode.comp.position.z = newLeftNode.comp.position.z + offsetNeeded
							newRightNode.comp.position.z = newRightNode.comp.position.z + offsetNeeded
							theirHeight = newRightNode.comp.position.z
							trace("Set their height to ",newRightNode.comp.position.z," by adding ",offsetNeeded)
						else 
							applyHeightOffset(splits, -offsetNeeded, i, params.absoluteMaxGradient)
						end
						if entity.comp.type ~= 2  and midEdge.comp.type ~= 1  then -- we are not tunnel  they are not bridge
							if canUseBridgeForCrossing(seg.theirRequiredSpan, params) and theirHeight-split.terrainHeight > 0 then
								trace("Setting bridge on theirs")
								setCrossingBridge(midEdge, params, seg.theirRequiredSpan, nil, false,finalDeltaz)
							else 
								trace("Setting tunnel on ours")
								setTunnel(entity)
							end
						else 
							trace("We are already tunnel")
						end 
					end
					
					lastMidPos.z= newLeftNode and newLeftNode.comp.position.z or leftNodePos.z
					if prevNodeEntity2 then
						prevNodeEntity2.comp.position.z=splits[i-1].newNode.comp.position.z -- reverse apply z smoothing
					end
					if edge.track and shouldRemoveLeftEdge and shouldRemoveRightEdge and newLeftNode and newRightNode  then 
						 
						for i, nodeDetails in pairs( { 
							{
								newNodePos = util.v3(newLeftNode.comp.position),
								existingNode = outerLeftNode,
								edgeId = leftEdgeId,
								newEdge = newLeftEdge
							} ,
							{
								newNodePos = util.v3(newRightNode.comp.position),
								existingNode = outerRightNode,
								edgeId = rightEdgeId,
								newEdge = newRightEdge
							}
						})do  
					
							local existingNodePos = nodePos(nodeDetails.existingNode)
							local dist = vec2.distance(existingNodePos, nodeDetails.newNodePos)
							local maxDeltaZ = params.maxSafeTrackGradient*dist 
							local deltaz = nodeDetails.newNodePos.z - existingNodePos.z 
							if math.abs(deltaz) > maxDeltaZ then 
								trace("WARNING!, deltaz exceeds limits") 
								local nextSegs = util.getSegmentsForNode(nodeDetails.existingNode)
								 
								if #nextSegs == 2 then 
									local nextEdge = nextSegs[1] == nodeDetails.edgeId and nextSegs[2] or nextSegs[1]
									if not util.isFrozenEdge(nextEdge) and not alreadySeenCollissionEdges[nextEdge] and not replacedEdgesMap[nextEdge] then 
										alreadySeenCollissionEdges[nextEdge] = true 
										local newEdge = getOrMakeReplacedEdge(nextEdge) 
										local newNode = newNodeWithPosition(existingNodePos, getNextNodeId())
										newNode.comp.position.z = deltaz < 0 and nodeDetails.newNodePos.z + maxDeltaZ or nodeDetails.newNodePos.z - maxDeltaZ
										addNode(newNode)
										local wasNode0 = false 
										if nodeDetails.newEdge.comp.node0 == nodeDetails.existingNode then 
											wasNode0 = true
											nodeDetails.newEdge.comp.node0 = newNode.entity
										else 
											assert(nodeDetails.newEdge.comp.node1 == nodeDetails.existingNode)
											nodeDetails.newEdge.comp.node1 = newNode.entity
										end 
										local newEdgeLenght = vec2.distance(nodePos(newEdge.comp.node0), nodePos(newEdge.comp.node1))
										 
										if newEdge.comp.node0 == nodeDetails.existingNode then 
											newEdge.comp.node0 = newNode.entity
											local tz = ((newNode.comp.position.z-nodeDetails.newNodePos.z)*dist + (nodePos(newEdge.comp.node1).z - newNode.comp.position.z)*newEdgeLenght)/(dist+newEdgeLenght)
											tz = 2*tz / (dist+newEdgeLenght)
											newEdge.comp.tangent0.z = newEdgeLenght*tz 
											if wasNode0 then 
												nodeDetails.newEdge.comp.tangent0.z = -tz*dist
											else 
												nodeDetails.newEdge.comp.tangent1.z = tz*dist
											end 
										else 
											assert(newEdge.comp.node1 == nodeDetails.existingNode)
											newEdge.comp.node1 = newNode.entity
											local tz = ((nodeDetails.newNodePos.z-newNode.comp.position.z)*dist + (newNode.comp.position.z-nodePos(newEdge.comp.node0).z)*newEdgeLenght)/(dist+newEdgeLenght)
											tz = 2*tz / (dist+newEdgeLenght)
											newEdge.comp.tangent1.z = newEdgeLenght*tz 
											if wasNode0 then 
												nodeDetails.newEdge.comp.tangent0.z = tz*dist
											else 
												nodeDetails.newEdge.comp.tangent1.z = -tz*dist
											end 
										end 
										--table.insert(edgesToAdd, newEdge)
										--table.insert(edgesToRemove, nextEdge)
										trace("Setup changed height and added entity ",newEdge.entity, " removed edge",nextEdge)
									end 
								
								end 
							
							end 
						end
					end 
					lastMidEdge = midEdge
				else 
					local recalculatedDeltaZ = split.newNode.comp.position.z-util.getEdgeMidPoint(seg.edge.id).z 
					if recalculatedDeltaZ <= -params.minZoffsetRoad and entity.comp.type==2 then 
						trace("Suppressing road collision with ",seg.edge.id," as we are lower")
					elseif recalculatedDeltaZ>= params.minZoffsetRoad and entity.comp.type==1 then 
						trace("Suppressing road collision with ",seg.edge.id," as we are higher")
					else 
						table.insert(roadCollisions, seg)
					end
				end
				::continue::
			end
		end
		
		
		for __, seg in pairs(roadCollisions)  do
			 
			if seg.doNotCorrectOtherSeg then 
				trace("Skipping ",seg," as it was not to be corrected")
				if split.newNode.entity > 0 then 
					local segmentsForRebuild = params.isTrack and util.getStreetSegmentsForNode(split.newNode.entity) or  util.getTrackSegmentsForNode(split.newNode.entity)
					for i, seg in pairs(segmentsForRebuild) do 
						if not alreadySeenCollissionEdges[seg] and not util.isFrozenEdge(seg) then 
							alreadySeenCollissionEdges[seg]= true
							 
							local replacement = getOrMakeReplacedEdge(seg)
							trace("Rebuilding seg ",seg," with no alteration to ",replacement.entity)-- seems to be necessary to get crossing barriers etc. to build properly 
						end
					end
				end 
				goto continue 
			end
			if seg.replaceNodeOnly then 
				local recalculatedDeltaZ = split.newNode.comp.position.z - nodePos(seg.replaceNodeOnly).z 
				trace("Replacing node only",seg.replaceNodeOnly," recalculatedDeltaZ=",recalculatedDeltaZ)
				if recalculatedDeltaZ < params.minZoffset and entity.comp.type == 2 then 
					trace("Skipping as we are now at clearance to pass under")
					goto continue 
				end 
				if recalculatedDeltaZ > params.minZoffset and entity.comp.type == 1 then 
					trace("Skipping as we are now at clearance to pass over") 
					goto continue 
				end
				for i, edge in pairs(util.getSegmentsForNode(seg.replaceNodeOnly)) do 
					if (not alreadySeenCollissionEdges[edge] or edge == seg.edge.id) and not util.isFrozenEdge(edge) then 
						alreadySeenCollissionEdges[edge]= true
						
						local replacement = getOrMakeReplacedEdge(edge)
						
						local otherPos 
						if replacement.comp.node0 == seg.replaceNodeOnly then 
							replacement.comp.node0 = split.newNode.entity
							otherPos = nodePos(replacement.comp.node1)
						else 
							replacement.comp.node1 = split.newNode.entity
							otherPos = nodePos(replacement.comp.node0)
						end 
						local newDist = util.distance(otherPos, split.p1)
						local oldDist = newDist 
						if replacement.comp.node0 > 0 and replacement.comp.node1 > 0 then 
							oldDist = util.distBetweenNodes(replacement.comp.node0, replacement.comp.node1)
						end
						setTangent(replacement.comp.tangent0, (newDist/oldDist)*util.v3(replacement.comp.tangent0))
						setTangent(replacement.comp.tangent1, (newDist/oldDist)*util.v3(replacement.comp.tangent1))
						trace("Rebuilding to replace node ",edge," with  alteration to ",replacement.entity, " newDist/oldDist=",(newDist/oldDist))
						 
					end
				end
				goto continue 
			end 
			local edge = seg.edge
			local edgeId = edge.id
			if replacedEdgesMap[edgeId] then 
				trace("WARNING! unable to make grade crossing for ",edgeId, " as it was already replaced")
				goto continue 
			end
			local theirPos = seg.theirPos 
	
			if not isDoubleTrack then
				-- simpler on single track, we don't care what way round it is, just split it in half
				
				local collisionLeft = getOrMakeReplacedEdge(edgeId)
				local collisionRight = util.copyExistingEdge(edgeId, nextEdgeId())
				table.insert(edgesToAdd, collisionRight)  
				local leftCollisionNode = collisionLeft.comp.node0
				local rightCollisionNode = collisionLeft.comp.node1
				local leftCollisionTangent = theirPos.t0
				local leftRoadTrackTagent = theirPos.t1
				local rightRoadTrackTagent = theirPos.t2
				local rightCollisionTangent = theirPos.t3
				
				local roadLeftNodePos = nodePos(leftCollisionNode)
				local roadRightNodePos = nodePos(rightCollisionNode)
				local leftDistance = util.distance(roadLeftNodePos, split.p1)
				local rightDistance = util.distance(roadRightNodePos, split.p1)
				local intersectionAngle = util.signedAngle(vec3.normalize(theirPos.t1), vec3.normalize(split.t1))
				if intersectionAngle ~= intersectionAngle then 
					debugPrint(theirPos)
				end
				--local intersectionAngle = util.signedAngle(collisionLeft.tangent1, split.t1)
				local minDistance = 30 
				local rotateCorrection = 0
				local rotate = false
				
			
				trace("Road crossing: leftDistance=",leftDistance, "rightDistance=",rightDistance, " angle=",math.deg(intersectionAngle)," skip=",skip, " i=",i)
				local bisectLimit = math.rad(45)
				local angleOffsetFromPerp = math.abs(math.abs(intersectionAngle)-math.rad(90))
				if  angleOffsetFromPerp > bisectLimit then
					
					rotate = true
					minDistance = 60
					rotateCorrection = bisectLimit-angleOffsetFromPerp
				--	if intersectionAngle < 0 then
						rotateCorrection = -rotateCorrection
					--end
					trace("Road crossing: leftDistance=",leftDistance, "rightDistance=",rightDistance, " angle=",math.deg(intersectionAngle), " rotateCorrection=",rotateCorrection)
				end
				
				 
				if leftDistance < minDistance and util.findNextEdgeInSameDirection(edgeId, leftCollisionNode) 
					and not alreadySeenCollissionEdges[util.findNextEdgeInSameDirection(edgeId, leftCollisionNode)]
					and #util.getTrackSegmentsForNode(leftCollisionNode) == 0 
					and #util.getStreetSegmentsForNode(leftCollisionNode) < 4 then  
					local secondEdgeId =  util.findNextEdgeInSameDirection(edgeId, leftCollisionNode)  
					local secondEdge = util.getEdge(secondEdgeId)
					local newCollisionNode = secondEdge.node0 == leftCollisionNode and secondEdge.node1 or secondEdge.node0
					local newCollisionTangent = secondEdge.node0 == leftCollisionNode and -1*util.v3(secondEdge.tangent1) or util.v3(secondEdge.tangent0)
					local otherNode =  secondEdge.node0 == leftCollisionNode and secondEdge.node1 or secondEdge.node0
					if #util.getSegmentsForNode(otherNode) <= 2 and #secondEdge.objects == 0 then 
						local canReplace = true 
						for __, otherSeg in pairs(util.findOtherSegmentsForNode(leftCollisionNode, { secondEdgeId, edgeId} )) do
							if allCollisionEdges[otherSeg] then
								canReplace = false 
								break 
							end
						end 
						if util.edgeHasTpLinks(secondEdgeId) then 
							canReplace = false
						end 
						if canReplace then 
							for __, otherSeg in pairs(util.findOtherSegmentsForNode(leftCollisionNode, { secondEdgeId, edgeId} )) do
								util.copyExistingEdgeReplacingNodeForCrossing(otherSeg, leftCollisionNode, otherNode, getOrMakeReplacedEdge)  
							end
							 
							local oldLeftDistance = leftDistance
							leftDistance = util.distance(nodePos(newCollisionNode), split.p1)
							leftCollisionNode = newCollisionNode
							leftCollisionTangent = leftDistance*vec3.normalize(newCollisionTangent)
							leftRoadTrackTagent =  leftDistance*vec3.normalize(leftRoadTrackTagent)
							trace("buildRoute: secondEdge left at i=",i," removing ",secondEdgeId," leftLength=",leftDistance, " oldLeftDistance=",oldLeftDistance)
							table.insert(edgesToRemove, secondEdgeId) 
							alreadySeenCollissionEdges[secondEdgeId]=true
						end
					else 
						trace("Skipping replacement of ",otherNode," as there were more than 2 segments attached",#util.getSegmentsForNode(otherNode))
					end 
				end
				trace("Checking right distance edgeId=",edgeId, "rightCollisionNode=",rightCollisionNode)
				if rightDistance < minDistance and util.findNextEdgeInSameDirection(edgeId, rightCollisionNode)    
					and not alreadySeenCollissionEdges[util.findNextEdgeInSameDirection(edgeId, rightCollisionNode)] 
					and #util.getTrackSegmentsForNode(rightCollisionNode) == 0 
					and #util.getStreetSegmentsForNode(rightCollisionNode) < 4 then
					local secondEdgeId = util.findNextEdgeInSameDirection(edgeId, rightCollisionNode)  
					local secondEdge = util.getEdge(secondEdgeId)
					local newCollisionNode = secondEdge.node0 == rightCollisionNode and secondEdge.node1 or secondEdge.node0
					local otherNode =  secondEdge.node0 == rightCollisionNode and secondEdge.node1 or secondEdge.node0
					local newCollisionTangent = secondEdge.node0 == rightCollisionNode and util.v3(secondEdge.tangent1) or -1*util.v3(secondEdge.tangent0)
					if #util.getSegmentsForNode(otherNode) <= 2 and #secondEdge.objects == 0  then
						local canReplace = true 
						for __, otherSeg in pairs(util.findOtherSegmentsForNode(rightCollisionNode, { secondEdgeId, edgeId} )) do
							if allCollisionEdges[otherSeg] then
								canReplace = false 
								break 
							end
						end 
						if util.edgeHasTpLinks(secondEdgeId) then 
							canReplace = false
						end 
						if canReplace then 
							for __, otherSeg in pairs(util.findOtherSegmentsForNode(rightCollisionNode, { secondEdgeId, edgeId} )) do
							 
								trace("Removing edge for seg", otherSeg)
								local otherEntity = util.copyExistingEdgeReplacingNodeForCrossing(otherSeg, rightCollisionNode, otherNode,getOrMakeReplacedEdge) 
								 
							end
							
							rightCollisionNode = newCollisionNode
							local oldRightDistance = rightDistance
							rightDistance = util.distance(nodePos(newCollisionNode), split.p1)
							rightCollisionTangent = rightDistance * vec3.normalize(newCollisionTangent)
							rightRoadTrackTagent = rightDistance * vec3.normalize(rightRoadTrackTagent)
							trace("buildRoute: secondEdge right at i=",i," removing ",secondEdgeId," rightLength=",rightDistance, " oldRightDistance=",oldRightDistance)
							table.insert(edgesToRemove, secondEdgeId)
							alreadySeenCollissionEdges[secondEdgeId]=true
						end
					else 
						trace("Skipping as node ",otherNode, " had more than 2 segments",#util.getSegmentsForNode(otherNode),"edgeObjects?",#secondEdge.objects)
					end 
				end
				 
				
				local maxRoadGradient = collisionLeft.streetEdge.streetType > -1 and api.res.streetTypeRep.get(collisionLeft.streetEdge.streetType).maxSlopeBuild or 0.05
				local leftRoadDeltaz = split.p1.z -roadLeftNodePos.z 
				local maxLeftDeltaz = leftDistance * maxRoadGradient
				local rightRoadDeltaz = split.p1.z -roadRightNodePos.z 
				local maxRightDeltaz = rightDistance * maxRoadGradient
				local zcorrectionNeeded = 0
				if math.abs(leftRoadDeltaz) >= maxLeftDeltaz   then
					trace("leftRoadDeltaz was",leftRoadDeltaz," maxLeftDeltaz=",maxLeftDeltaz, " distance=", util.distance(roadLeftNodePos, split.p1) )
					local correction = maxLeftDeltaz - math.abs(leftRoadDeltaz)
					zcorrectionNeeded = leftRoadDeltaz > 0 and correction or -correction
				elseif math.abs(rightRoadDeltaz) > maxRightDeltaz then
					trace("rightRoadDeltaz was",rightRoadDeltaz," maxRightDeltaz=",maxRightDeltaz)
					local correction = maxRightDeltaz - math.abs(rightRoadDeltaz)
					zcorrectionNeeded = rightRoadDeltaz > 0 and correction or -correction
				end
				if zcorrectionNeeded ~= 0 then
					trace("having to apply zcorrectionNeeded",zcorrectionNeeded," at i ",i," to height")
					applyHeightOffset(splits, zcorrectionNeeded, i,   params.absoluteMaxGradient)
				end
				
				if rotate then
					local initialLeftAngle = util.signedAngle(leftRoadTrackTagent, split.t1)
					local trialleftRoadTrackTagent = util.rotateXY(leftRoadTrackTagent, rotateCorrection)
					local newLeftAngle =  util.signedAngle(trialleftRoadTrackTagent, split.t1)
					if math.abs(math.abs(newLeftAngle)-math.rad(90)) > math.abs(math.abs(initialLeftAngle)-math.rad(90)) then
						trialleftRoadTrackTagent = util.rotateXY(leftRoadTrackTagent, -rotateCorrection)
						local newLeftAngle2 =  util.signedAngle(trialleftRoadTrackTagent, split.t1)
						trace("attempting left correction of angle",math.deg(initialLeftAngle),"initial attempt gave ", math.deg(newLeftAngle)," after rotating ",math.deg(rotateCorrection)," after trying the other way it was ", math.deg(newLeftAngle2))
						leftRoadTrackTagent= trialleftRoadTrackTagent
						newLeftAngle = newLeftAngle2
					else 
						trace("attempting left correction of angle",math.deg(initialLeftAngle),"initial attempt gave ", math.deg(newLeftAngle)," which is better")
						leftRoadTrackTagent= trialleftRoadTrackTagent
					end
					
					local leftCorrectionAngle = math.abs(util.signedAngle(leftRoadTrackTagent, nodePos(leftCollisionNode)- split.p1))
					local leftCorrectionFactor = 1+(1/3)*math.sin(leftCorrectionAngle)
					leftRoadTrackTagent = leftCorrectionFactor*leftDistance * vec3.normalize(leftRoadTrackTagent)
					leftCollisionTangent = leftCorrectionFactor*leftDistance * vec3.normalize(leftCollisionTangent)
					
					local initialRightAngle = util.signedAngle(rightRoadTrackTagent, split.t1)
					local trialRightRoadTrackTagent = util.rotateXY(rightRoadTrackTagent, rotateCorrection)
					local newRightAngle =  util.signedAngle(trialRightRoadTrackTagent, split.t1)
					if math.abs(math.abs(newRightAngle)-math.rad(90)) > math.abs(math.abs(initialRightAngle)-math.rad(90))  then
						trialRightRoadTrackTagent = util.rotateXY(rightRoadTrackTagent, -rotateCorrection)
						local newRightAngle2 =  util.signedAngle(trialRightRoadTrackTagent, split.t1)
						trace("attempting right correction of angle",math.deg(initialRightAngle),"initial attempt gave ", math.deg(newRightAngle)," after rotating ",math.deg(rotateCorrection)," after trying the other way it was ", math.deg(newRightAngle2))
						rightRoadTrackTagent= trialRightRoadTrackTagent
					else 
						trace("attempting right correction of angle",math.deg(initialRightAngle),"initial attempt gave ", math.deg(newRightAngle)," which is better")
						rightRoadTrackTagent= trialRightRoadTrackTagent
					end
					local rightCorrectionAngle = math.abs(util.signedAngle(rightRoadTrackTagent, nodePos(rightCollisionNode)- split.p1))
					local rightCorrectionFactor = 1+(1/3)*math.sin(rightCorrectionAngle)
					rightRoadTrackTagent = rightCorrectionFactor*rightDistance * vec3.normalize(rightRoadTrackTagent)
					rightCollisionTangent = rightCorrectionFactor*rightDistance * vec3.normalize(rightCollisionTangent)
					
					trace(" leftCorrectionAngle=",math.deg(leftCorrectionAngle)," leftCorrectionFactor=",leftCorrectionFactor," rightCorrectionAngle=",math.deg(rightCorrectionAngle)," rightCorrectionFactor=",rightCorrectionFactor)
				end
				local nodeVector = util.v3(split.newNode.comp.position)-nodePos(leftCollisionNode)
				local nodeVectorLength = vec3.length(nodeVector)
				 trace("angle of the vector to the leftCollisionTangent was ",
					math.deg(util.signedAngle(nodeVector, leftCollisionTangent)),
					"angle to the vector of the leftRoadTrackTagent was ",math.deg(util.signedAngle(nodeVector, leftRoadTrackTagent))
					," straightDistance=",nodeVectorLength," collisionTangentMagnitude=",vec3.length(leftCollisionTangent),"roadTrackMagnute=",vec3.length(leftRoadTrackTagent))
					
				if nodeVectorLength < 1.5*vec3.length(leftCollisionTangent) 
				or nodeVectorLength < 1.5*vec3.length(leftRoadTrackTagent) 
				or nodeVectorLength > vec3.length(leftCollisionTangent) 
				or nodeVectorLength > vec3.length(leftRoadTrackTagent)  then 
					trace("Detected possible invalid left tangent length at ",i," attempting to correct")
					local originalLeftRoadTrackTagent = leftRoadTrackTagent
					local originalLeftCollisionTangent = leftCollisionTangent
					leftCollisionTangent = nodeVectorLength * vec3.normalize(leftCollisionTangent)
					leftRoadTrackTagent = nodeVectorLength * vec3.normalize(leftRoadTrackTagent)
					leftCollisionTangent = util.rotateXY(leftCollisionTangent, util.signedAngle(leftCollisionTangent, originalLeftCollisionTangent))
					leftRoadTrackTagent = util.rotateXY(leftRoadTrackTagent, util.signedAngle(leftRoadTrackTagent, originalLeftRoadTrackTagent))
				end
					
			
				 
		
				 
				 
				--[[
				local nodeVector = nodePos(rightCollisionNode)-util.v3(split.newNode.comp.position) 
				 trace("angle of the vector to the rightCollisionTangent was ",
					math.deg(util.signedAngle(nodeVector, rightCollisionTangent)),
					"angle to the vector of the rightRoadTrackTagent was ",math.deg(util.signedAngle(nodeVector, rightRoadTrackTagent))					," straightDistance=",vec3.length(nodeVector)," collisionTangentMagnitude=",vec3.length(rightCollisionTangent),"roadTrackMagnute=",vec3.length(rightRoadTrackTagent), " collisionLeft.entity=",collisionLeft.entity)
				
				if vec3.length(nodeVector) < 1.5*vec3.length(rightRoadTrackTagent) 
				or vec3.length(nodeVector) < 1.5*vec3.length(rightCollisionTangent) 
				or vec3.length(nodeVector) > vec3.length(rightRoadTrackTagent) 
				or vec3.length(nodeVector) > vec3.length(rightCollisionTangent)  then 
					trace("Detected possible invalid right tangent length at ",i," attempting to correct")
					local originalRightRoadTrackTagent = rightRoadTrackTagent
					local originalRightCollisionTangent = rightCollisionTangent
					rightRoadTrackTagent = vec3.length(nodeVector) * vec3.normalize(rightRoadTrackTagent)
					rightCollisionTangent = vec3.length(nodeVector) * vec3.normalize(rightCollisionTangent)
					rightRoadTrackTagent = util.rotateXY(rightRoadTrackTagent, util.signedAngle(rightRoadTrackTagent, originalRightRoadTrackTagent))
					rightCollisionTangent = util.rotateXY(rightCollisionTangent, util.signedAngle(rightCollisionTangent, originalRightCollisionTangent))
				end--]]
				local dist = util.distBetweenNodes(leftCollisionNode, rightCollisionNode)
				assert(dist>0)
				local inputEdge = { 
					p0 = nodePos(leftCollisionNode),
					p1 = nodePos(rightCollisionNode),
					t0 = dist*vec3.normalize(leftCollisionTangent),
					t1 = dist*vec3.normalize(rightCollisionTangent)					
				}
				local solution = util.solveForPosition(util.v3(split.newNode.comp.position), inputEdge)
				
				
				collisionLeft.comp.node0 = leftCollisionNode
				collisionLeft.comp.node1 = split.newNode.entity
				setTangent(collisionLeft.comp.tangent0, solution.t0)
				setTangent(collisionLeft.comp.tangent1, solution.t1)	
		 
				collisionRight.comp.node0 = split.newNode.entity
				collisionRight.comp.node1 = rightCollisionNode
				setTangent(collisionRight.comp.tangent0, solution.t2)
				setTangent(collisionRight.comp.tangent1, solution.t3)
				
				trace("Collisiuon right.entity=", collisionRight.entity)
				
				--[[local angle = util.signedAngle(leftRoadTrackTagent, rightRoadTrackTagent)
				trace("angle between rightRoadTrackTagent and leftRoadTrackTagent was",math.deg(angle))
				if math.abs(angle) > math.rad(1) then 
					trace("WARNING! High angle unexpected") 
					local correction = angle / 2
					leftRoadTrackTagent = util.rotateXY(leftRoadTrackTagent, -correction)
					rightRoadTrackTagent = util.rotateXY(rightRoadTrackTagent, -correction)
					local newAngle = util.signedAngle(leftRoadTrackTagent, rightRoadTrackTagent)
					trace("after correction, angle between rightRoadTrackTagent and leftRoadTrackTagent was",math.deg(newAngle))
					if math.abs(newAngle) < math.abs(angle) then 
						setTangent(collisionLeft.comp.tangent1, leftRoadTrackTagent)
						setTangent(collisionRight.comp.tangent0, rightRoadTrackTagent)
					end 
				end --]]
			end
		 
			::continue::
		end
		
		if isDoubleTrack  then
			local entity2 = copySegmentAndEntity(entity)
			entity2.entity = nextEdgeId() 
			trace("Created double track edge at ",i," entity was",entity2.entity)
			local newNode2 = newDoubleTrackNode(split.p1, split.t1)
			newNode2.entity= getNextNodeId()
			split.doubleTrackNode = newNode2
			addNode(newNode2)
			entity2.comp.node0 = prevNode2
			entity2.comp.node1 = newNode2.entity
			local tangent2 = util.v3(split.t1)
			local lastLength = vec3.length(tangent2)
			--for i = 1, 10 do 
				 
				local p0 = prevNodeEntity2 and util.v3(prevNodeEntity2.comp.position) or nodePos(otherLeftNode)
				local p1 = util.v3(newNode2.comp.position)
				local t0 = vec3.length(tangent2)*vec3.normalize(prevtangent)
				if prevEntity2 and params.isTrack then --required for grade crossings
					t0 = util.v3(prevEntity2.comp.tangent1)
				end 
				local t1 = tangent2 
				local edgeLength = util.calculateTangentLength(p0, p1, t0, t1)
				local tangentLength= vec3.length(tangent2)
				trace("The edge length at i was ", edgeLength, " the tangentLength was ",tangentLength, " the dist was ",util.distance(p0,p1))
				util.setTangent(entity2.comp.tangent0, edgeLength*vec3.normalize(t0))
				util.setTangent(entity2.comp.tangent1, edgeLength*vec3.normalize(t1))
				--tangent2 = edgeLength * vec3.normalize(tangent2)
		--		if tangentLength == lastLength then 
			--		break 
			--	end
			--end 
			
			table.insert(edgesToAdd, entity2) 
			if params.isQuadrupleTrack then 
				local entity3 = copySegmentAndEntity(entity, nextEdgeId()) 
				trace("Created triple track edge at ",i," entity was",entity3.entity)
				local newNode3 = newDoubleTrackNode(split.p1, -1*split.t1, getNextNodeId())
			 
				split.tripleTrackNode = newNode3
				addNode(newNode3)
				entity3.comp.node0 = prevNode3
				entity3.comp.node1 = newNode3.entity
				local p0 = nodePos(prevNode3)
				local p1 = nodePos(newNode3.entity)
				local edgeLength = util.calculateTangentLength(p0, p1, t0, t1)
				util.setTangent(entity3.comp.tangent0, edgeLength*vec3.normalize(t0))
				util.setTangent(entity3.comp.tangent1, edgeLength*vec3.normalize(t1))
				table.insert(edgesToAdd, entity3)
				table.insert(mainLineEdges3, entity3)
				prevNode3 = newNode3.entity
				
				local entity4 = copySegmentAndEntity(entity, nextEdgeId()) 
				trace("Created quad track edge at ",i," entity was",entity3.entity)
				local newNode4 = newNodeWithPosition(util.nodePointPerpendicularOffset(split.p1,  split.t1, 2*params.trackWidth), getNextNodeId())
				
				split.quadroupleTrackNode = newNode4
				addNode(newNode4)
				entity4.comp.node0 = prevNode4
				entity4.comp.node1 = newNode4.entity
				local p0 = nodePos(prevNode4)
				local p1 = nodePos(newNode4.entity)
				local edgeLength = util.calculateTangentLength(p0, p1, t0, t1)
				util.setTangent(entity4.comp.tangent0, edgeLength*vec3.normalize(t0))
				util.setTangent(entity4.comp.tangent1, edgeLength*vec3.normalize(t1))
				table.insert(edgesToAdd, entity4)
				table.insert(mainLineEdges4, entity4)
				prevNode4 = newNode4.entity
				
				if isAddSignals(i) then
					buildSignals(edgeObjectsToAdd, i, nodecount, entity3, entity4, false)
				end
			end
			
			if params.isHighway then 
				if entity2.comp.type == 1 and (newNode2.comp.position.z - util.th(newNode2.comp.position) < 5 and util.th(newNode2.comp.position)>0 or prevNodeEntity2 and prevNodeEntity2.comp.position.z - util.th(prevNodeEntity2.comp.position) < 5 and util.th(prevNodeEntity2.comp.position)>0)
				and prevNodeEntity2 and util.th(prevNodeEntity2.comp.position) >= 0 and util.th(newNode2.comp.position) >= 0 
				then 
					trace("Bridge cancelled on second highway edge due to terrain proximity") 
					entity2.comp.type =0
					entity2.comp.typeIndex = -1
				elseif entity2.comp.type==0 and (util.th(newNode2.comp.position) < 0 or 
					newNode2.comp.position.z - math.min(util.th(newNode2.comp.position),util.th(newNode2.comp.position,true)) > 10
					and prevNodeEntity2 and prevNodeEntity2.comp.position.z -  math.min(util.th(prevNodeEntity2.comp.position),util.th(prevNodeEntity2.comp.position,true)) > 10)
				then 
					trace("adding bridge due to low height on second highway edge")
					entity2.comp.type = 1
					entity2.comp.typeIndex = cement 
				end
				trace("Reversing entity ",entity2.entity," for highway")
				util.reverseNewEntity(entity2)	
				if split.junction and not params.disableJunctions then 
					trace("Discovered junction at ",i," originalNodeOrder=",split.nodeOrder)
					--debugPrint(split.junction)
					local function check(node) 
						return oldToNewNodeMap[node] and oldToNewNodeMap[node].entity or node
					end 
					local leftNodePos = util.v3(newNode2.comp.position)
					if split.junction.leftEntryNode then 
						
						routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, newNode2.entity, leftNodePos,-1*split.t1, entity2.comp.type, check(split.junction.leftEntryNode) , nodePos(split.junction.leftEntryNode), params, nextEdgeId, getNextNodeId, true, -1*split.junction.tangent)
						trace("Built left entry at ",#edgesToAdd," i=",i," originalNodeOrder=",split.nodeOrder, true)
					end
					if split.junction.rightEntryNode then 
					 	routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, split.newNode.entity, split.p1,-1*split.t1, entity2.comp.type, check(split.junction.rightEntryNode), nodePos(split.junction.rightEntryNode), params, nextEdgeId, getNextNodeId, false,-1*split.junction.tangent) 
						trace("Built right entry at ",#edgesToAdd," i=",i," originalNodeOrder=",split.nodeOrder, true)
					end					
					if split.junction.leftHandExitNode and prevNodeEntity2 then 
						routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, prevNode2, util.v3(prevNodeEntity2.comp.position),prevtangent, entity2.comp.type, check(split.junction.leftHandExitNode) , nodePos(split.junction.leftHandExitNode), params, nextEdgeId, getNextNodeId, false, split.junction.tangent) 
						trace("Built left exit at ",#edgesToAdd," i=",i," originalNodeOrder=",split.nodeOrder, true)
					end
					if split.junction.rightHandExitNode and i > 1 then
						routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, splits[i-1].newNode.entity, splits[i-1].p1,prevtangent, entity2.comp.type, check(split.junction.rightHandExitNode) , nodePos(split.junction.rightHandExitNode ), params, nextEdgeId, getNextNodeId, true,split.junction.tangent) 
						trace("Built right exit at ",#edgesToAdd," i=",i," originalNodeOrder=",split.nodeOrder, true)
					end
					
				end
			end
			
			--[[
			for __, seg in pairs(roadCollisions) do 
				local edge = seg.edge
				local edgeId = edge.id
				local existingEdgeSolution=seg.doubleTrackSolution.existingEdgeSolution
				local newEdgeSolution=seg.doubleTrackSolution.newEdgeSolution
				setPositionOnNode(newNode2, newEdgeSolution.p1)
				--setTangent(entity2.comp.tangent0, newEdgeSolution.t1)
				--setTangent(entity2.comp.tangent1, newEdgeSolution.t2)
				if prevEntity2 then
					--setTangent(prevEntity2.comp.tangent1, newEdgeSolution.t0)
				end
				local theirPos = seg.theirPos
				
				local collisionLeft = util.copyExistingEdge(edgeId)
				collisionLeft.entity = nextEdgeId() 
				--collisionLeft.comp.node0 = leftCollisionNode
				collisionLeft.comp.node1 = split.newNode.entity
				setTangent(collisionLeft.comp.tangent0, theirPos.t0)
				setTangent(collisionLeft.comp.tangent1, theirPos.t1)
				--table.insert(edgesToAdd, collisionLeft)
				
				local gapDist = util.distance(newEdgeSolution.p1, split.p1)
				local collisionMid = util.copyExistingEdge(edgeId)
				collisionMid.entity = nextEdgeId() 
				collisionMid.comp.node0 = split.newNode.entity
				collisionMid.comp.node1 = newNode2.entity
		
				--setTangent(collisionMid.comp.tangent0,  gapDist*vec3.normalize(theirPos.t2))
				--setTangent(collisionMid.comp.tangent1,  gapDist*vec3.normalize(existingEdgeSolution.t1))
				setTangent(collisionMid.comp.tangent0,  newEdgeSolution.p1-split.p1)
				setTangent(collisionMid.comp.tangent1,  newEdgeSolution.p1-split.p1)
				table.insert(edgesToAdd, collisionMid)
				
				local collisionRight = util.copyExistingEdge(edgeId)
				collisionRight.entity = nextEdgeId() 
				collisionRight.comp.node0 = newNode2.entity
				--collisionRight.comp.node1 = rightCollisionNode
				setTangent(collisionRight.comp.tangent0, existingEdgeSolution.t2)
				setTangent(collisionRight.comp.tangent1, existingEdgeSolution.t3)
				--table.insert(edgesToAdd, collisionRight)
			end
			roadCollisions={}
			]]---
			
			
			for cIdx, seg in pairs(roadCollisions)  do
				if cIdx > 1 then 
					trace("WARNING! More than one found, aborting")
					break 
				end 
				local edge = seg.edge
				-- the double track road replacement is considarably more complicated by the need for a small segment between the tracks
				--local signedAngle = 0.5*(util.signedAngle(split.t1, util.v3fromArr(edge.node0tangent))+util.signedAngle(split.t1, util.v3fromArr(edge.node0tangent)))
				local signedAngle = util.signedAngle(split.t1, seg.theirPos.t1)
				local leftCollisionNode
				local leftCollisionNodePos 
				local rightCollisionNode
				local rightCollisionNodePos 
				local leftCollisionTangent
				local rightCollisionTangent
				local invertTheirs = signedAngle < 0
				trace("signedAngleWas to collision edge was ", math.deg(signedAngle), " at i=",i,"invertTheirs?",invertTheirs)
				if invertTheirs then
					-- swap the direction
					leftCollisionNode = edge.node1
					leftCollisionNodePos = util.v3fromArr(edge.node1pos)
					rightCollisionNode = edge.node0
					rightCollisionNodePos = util.v3fromArr(edge.node0pos)
					leftCollisionTangent = -1*util.v3fromArr(edge.node1tangent)
					rightCollisionTangent = -1*util.v3fromArr(edge.node0tangent)
				else 
					leftCollisionNode = edge.node0
					leftCollisionNodePos =  util.v3fromArr(edge.node0pos)
					rightCollisionNode = edge.node1
					rightCollisionNodePos =  util.v3fromArr(edge.node1pos)
					leftCollisionTangent =  util.v3fromArr(edge.node0tangent)
					rightCollisionTangent =  util.v3fromArr(edge.node1tangent)
				end
				
				local edgeId = edge.id
				local position = split.collisionSegments.position
				
				local perpVector = util.rotateXY( vec3.normalize(split.t1), math.rad(90))
				local leftLength = util.distance(leftCollisionNodePos, split.p1)
				local collisionLeft
				trace("The left length was",leftLength,"#util.getSegmentsForNode(leftCollisionNode)=",#util.getSegmentsForNode(leftCollisionNode))
				if leftLength < 20 and #util.getSegmentsForNode(leftCollisionNode)==2  then
					--local nextSegs = util.getSegmentsForNode(leftCollisionNode)
					--local secondEdgeId = nextSegs[1]==edgeId and nextSegs[2] or nextSegs[1]
					local secondEdgeId = util.findNextEdgeInSameDirection(edgeId, leftCollisionNode)
					if secondEdgeId then 
						local secondEdge = util.getEdge(secondEdgeId)
						local newCollisionNode = secondEdge.node0 == leftCollisionNode and secondEdge.node1 or secondEdge.node0
						local newCollisionTangent = secondEdge.node0 == leftCollisionNode and -1*util.v3(secondEdge.tangent1) or util.v3(secondEdge.tangent0)
						trace("Inspecting secondEdgeId",secondEdgeId," for left collision was in allCollisionEdges?",allCollisionEdges[secondEdgeId]," was in alreadySeenCollissionEdges?",alreadySeenCollissionEdges[secondEdgeId])
						if     not alreadySeenCollissionEdges[secondEdgeId] and not util.isFrozenEdge(secondEdgeId) then
							leftCollisionNode = newCollisionNode
							local angle = util.signedAngle(leftCollisionTangent, newCollisionTangent)
							trace("The secondEdge leftCollisionTangent angle was",math.deg(angle))
							if math.abs(angle) > math.rad(90) then 
								trace("Inverting the leftCollisionTangent")
								leftCollisionTangent = -1*leftCollisionTangent
							end
							leftCollisionTangent = newCollisionTangent
							leftLength = util.distance(nodePos(newCollisionNode), split.p1)
							trace("at i=",i," removing ",secondEdgeId," leftLength=",leftLength)
							collisionLeft = getOrMakeReplacedEdge(secondEdgeId)
						end
					end
				end
					
				if not collisionLeft then 
					collisionLeft = util.copyExistingEdge(edgeId, nextEdgeId() )
					table.insert(edgesToAdd, collisionLeft)
				end 
				collisionLeft.comp.node0 = leftCollisionNode
				collisionLeft.comp.node1 = split.newNode.entity
				setTangent(collisionLeft.comp.tangent0, leftLength*vec3.normalize(leftCollisionTangent))
				setTangent(collisionLeft.comp.tangent1, leftLength*perpVector)
				if util.tracelog then trace("Created collisionLeft",newEdgeToString(collisionLeft)) end
				if collisionLeft.comp.node0 == collisionLeft.comp.node1 then 
					trace("Removing collisionLeft as it is double connected") 
					table.remove(edgesToAdd, -collisionLeft.entity )
				else 
					splitEdgesMap[edge.id]={}
					splitEdgesMap[edge.id][leftCollisionNode] = collisionLeft
				end 
				
			
				
				local collisionMid = getOrMakeReplacedEdge(edgeId)
				collisionMid.comp.node0 = split.newNode.entity
				collisionMid.comp.node1 = newNode2.entity
				if util.tracelog then trace("Created collisionMid",newEdgeToString(collisionMid)) end
				local trackWidth = params.trackWidth
				setTangent(collisionMid.comp.tangent0,  trackWidth*perpVector)
				setTangent(collisionMid.comp.tangent1,  trackWidth*perpVector)
		 
				
				
				local rightLength = util.distance(rightCollisionNodePos, split.p1)-trackWidth
				trace("at i=",i," collision leftLength=",leftLength," rightLength=",rightLength, " #util.getSegmentsForNode(rightCollisionNode)=",#util.getSegmentsForNode(rightCollisionNode))
				local collisionRight
				if rightLength < 20 and #util.getSegmentsForNode(rightCollisionNode) == 2 then
					--local nextSegs = util.getSegmentsForNode(rightCollisionNode)
--					local secondEdgeId = nextSegs[1]==edgeId and nextSegs[2] or nextSegs[1]
					local secondEdgeId = util.findNextEdgeInSameDirection(edgeId, rightCollisionNode)
					if secondEdgeId then 
						local secondEdge = util.getEdge(secondEdgeId)
						local newCollisionNode = secondEdge.node0 == rightCollisionNode and secondEdge.node1 or secondEdge.node0
						local newCollisionTangent = secondEdge.node0 == rightCollisionNode and util.v3(secondEdge.tangent1) or -1*util.v3(secondEdge.tangent0)
						trace("Inspecting secondEdgeId",secondEdgeId," for rigthtCollision was in allCollisionEdges?",allCollisionEdges[secondEdgeId]," was in alreadySeenCollissionEdges?",alreadySeenCollissionEdges[secondEdgeId])
						if   not alreadySeenCollissionEdges[secondEdgeId] and not util.isFrozenEdge(secondEdgeId) then
							rightCollisionNode = newCollisionNode
							local angle = util.signedAngle(rightCollisionTangent, newCollisionTangent)
							trace("The secondEdge rightCollisionTangent angle was",math.deg(angle))
							if math.abs(angle) > math.rad(90) then 
								trace("Inverting the leftCollisionTangent")
								rightCollisionTangent = -1*rightCollisionTangent
							end
							rightCollisionTangent = newCollisionTangent
							rightLength = util.distance(util.nodePos(newCollisionNode), split.p1)-trackWidth
							trace("at i=",i," removing ",secondEdgeId," rightLength=",rightLength)
							collisionRight = getOrMakeReplacedEdge(secondEdgeId)
						end
					end
				end
				
				if not collisionRight then -- and rightLength >= 20  -- removed this condition otherwise we break routes
					collisionRight = util.copyExistingEdge(edgeId,  nextEdgeId())
					table.insert(edgesToAdd, collisionRight)
				end 
				if collisionRight then 
					collisionRight.comp.node0 = newNode2.entity
					collisionRight.comp.node1 = rightCollisionNode
					if util.tracelog then  trace("Created collisionRight",newEdgeToString(collisionRight)) end
					
					setTangent(collisionRight.comp.tangent0, rightLength*perpVector)
					setTangent(collisionRight.comp.tangent1, rightLength*vec3.normalize(rightCollisionTangent))
					if collisionRight.comp.node0 == collisionRight.comp.node1 then 
						trace("WARNING! Removing collisionRight as it is double connected") 
						table.remove(edgesToAdd, -collisionRight.entity )
					else 
						splitEdgesMap[edge.id][rightCollisionNode] = collisionRight
					end
				else 
					trace("WARNING! No replacement for collisionRight was made")
				end 
				
				--alternate code begin 
				if prevEntity and prevEntity2 and i < #splits and math.abs(signedAngle) < math.rad(160) and math.abs(signedAngle) > math.rad(20) then 
					local ourEdge2 = {
						p0 = util.v3(prevNodeEntity2.comp.position),
						p1 = util.doubleTrackNodePoint(splits[i+1].p1, splits[i+1].t1),
						t0 = util.v3(prevEntity2.comp.tangent1),
						t1 = splits[i+1].t1,					
					}
					local c2 = newNode2.comp.position
					local doubleTrackSolution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c2, edge.id, ourEdge2,vec2.distance, checkForDoubleTrack, allowEdgeExpansion, solveTheirOuterEdge, invertTheirs)
					local newEdgeSolution=doubleTrackSolution.newEdgeSolution
					newEdgeSolution.p1.z = split.newNode.comp.position.z
					local ourEdge1 = {
						p0 = util.v3(splits[i-1].newNode.comp.position),
						p1 = splits[i+1].p1,
						t0 = util.v3(prevEntity.comp.tangent1),
						t1 = splits[i+1].t1,					
					}
					
					local solution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c2, edge.id, ourEdge1,vec2.distance, checkForDoubleTrack, allowEdgeExpansion, solveTheirOuterEdge, invertTheirs)
					if solution.solutionConverged and doubleTrackSolution.solutionConverged then 
						setPositionOnNode(newNode2, newEdgeSolution.p1)
						--util.setTangent(prevEntity2.comp.tangent1, newEdgeSolution.t1)
						util.setTangent(entity2.comp.tangent1, newEdgeSolution.t1)
						util.setTangent(collisionLeft.comp.tangent1, doubleTrackSolution.existingEdgeSolution.t1)
						util.setTangent(collisionMid.comp.tangent0, doubleTrackSolution.existingEdgeSolution.t2)
						
						
						newEdgeSolution = solution.newEdgeSolution
						newEdgeSolution.p1.z = split.newNode.comp.position.z
						setPositionOnNode(split.newNode, newEdgeSolution.p1)
						--util.setTangent(prevEntity2.comp.tangent1, newEdgeSolution.t1)
						util.setTangent(entity.comp.tangent1, newEdgeSolution.t1)
						split.t2 = newEdgeSolution.t2
						util.setTangent(collisionMid.comp.tangent1, solution.existingEdgeSolution.t1)
						util.setTangent(collisionRight.comp.tangent0, solution.existingEdgeSolution.t2)
						
					 
						util.correctTangentLengths(collisionLeft, nodePos)
						util.correctTangentLengths(collisionMid, nodePos)
						util.correctTangentLengths(collisionRight, nodePos)
						util.correctTangentLengths(entity, nodePos)
						util.correctTangentLengths(entity2, nodePos)
						util.correctTangentLengths(prevEntity, nodePos)
						util.correctTangentLengths(prevEntity2, nodePos) 
						if util.tracelog then 
							trace("Setup new edge solution")
							debugPrint({collisionLeft=collisionLeft, collisionMid=collisionMid,collisionRight=collisionRight})
						end 
					else 
						trace("WARNING! Solution not converged for grade crossing at",i)
					end 
				end
				--alternate code end
				
				
				
			end
			if isAddSignals(i) then
				 buildSignals(edgeObjectsToAdd, i, nodecount, entity, entity2, false)
				 trace("Adding signals at ",i)
			end
			--[[if i == 1 and requiresLeftCrossover then 
				local entity3 = copySegmentAndEntity(entity)
				entity3.entity = nextEdgeId() 
				entity3.comp.node0 = otherLeftNode 
				
				table.insert(edgesToAdd, entity3)
			
			end
			if i==depot1ConnectIdx+2 and depot1Node and not isAddSignals(i) then
				-- depot crossover
				local entity4 = copySegmentAndEntity(entity)
				entity4.entity = nextEdgeId()
				entity4.comp.node1 = newNode.entity
				 --table.insert(edgesToAdd, entity4)
			end--]]
		
			prevEntity2 = entity2
			prevNode2 = newNode2.entity
			prevNodeEntity2 = newNode2
			table.insert(mainLineEdges2, entity2)
			if params.isTrack and i==1 and params.useDoubleTerminals and not isTerminus1 then 
				local otherLeftLeftNode = util.findDoubleTrackNode(otherLeftNode)
				if otherLeftLeftNode then 
					local entity3 = util.copySegmentAndEntity(entity2, nextEdgeId())
					entity3.comp.node0 = otherLeftLeftNode
					trace("useDoubleTerminals: in double track connecting segment for left node at ",entity3.entity, " otherLeftLeftNode=",otherLeftLeftNode, newEdgeToString(entity3), " copied edge:", newEdgeToString(entity2), " tangentLength=",vec3.length(entity2.comp.tangent0))
					table.insert(edgesToAdd, entity3)
				else 
					trace("useDoubleTerminals: WARNING! Request to use double terminals but no other rightnode found")
				end 
			end 
		end -- isDoubleTrack
		if split.junction and split.junction.highwayCrossing then 
			trace("Inserting callback for highway crossing at ",i)
			table.insert(highwayCrossings, { crossingNodePos = split.p1, crossingNode2Pos = split.junction.highwayCrossing, crossingPoint = split.junction.crossingPoint, crossingAngle=split.junction.crossingAngle, crossingNodePosPrior=prevSplit.p1 })
		end 
		if i==depot1ConnectIdx and depot1Node then
			local entity4 = copySegmentAndEntity(entity)
			entity4.entity = nextEdgeId()
			--entity4.comp.node0 = depot1Node
		
			trace("building depot conenct, station node=",depot1Connect," depot node=",depot1Node)
			local t1 = util.v3(util.getEdge(node2SegMap[depot1Node]).tangent1)
			--if doubleTrack then
			
				local straightDistance = util.distance(util.nodePos(depot1Node), split.p1)
				local phi = math.abs(util.signedAngle(vec3.normalize(station1tangent), vec3.normalize(split.t1)))
				local arcLength = straightDistance
				if phi > math.rad(5) then
					local r = straightDistance / math.tan(phi) 
					arcLength = 2*(phi/math.rad(90)) * r * 4 * (math.sqrt(2)-1)
					arcLength = math.min(arcLength, 1.3*straightDistance) -- seems to give too large result for big angles
				end
				trace("connecting depot, straightDistance was",straightDistance, " phi = ", math.deg(phi), " arcLength = ",arcLength)
				entity4.comp.node0 = depot1Node
				--entity4.comp.node1 = entity
				setTangent(entity4.comp.tangent0,arcLength*vec3.normalize(station1tangent))
				setTangent(entity4.comp.tangent1,arcLength*vec3.normalize(split.t1))
			--[[else 
				entity4.comp.node0 = depot1Connect
				entity4.comp.node1 = depot1Node
				-- give this plenty of distance to avoid "too much curvature"
				local distance = v3abs(util.nodePos(depot1Node)-nodePos(depot1Connect))
				local t0 = distance * vec3.normalize(station1tangent)
				
				t1 = -distance*vec3.normalize(t1)
				setTangent(entity4.comp.tangent0,t0)
				setTangent(entity4.comp.tangent1,t1)
			end]]--
			--setTangent(entity4.comp.tangent1,distance*vec3.normalize(split.t1))
			--if tracelog then debugPrint({depotEntity=entity4}) end
			 --table.insert(edgesToAdd, entity4)
		end
		
		if not params.isHighway and not params.isTrack and entity.comp.type ==0 then 
			entity.playerOwned = nil -- needed to allow towns to expand
		end 
		
		prevnode = split.newNode.entity
		prevtangent = split.t2
		prevEntity= entity
		table.insert(mainLineEdges, entity)
	end -- end split loop 
	
	 
	-- need to add final segment
	local entity = initSegmentAndEntity()  
	entity.entity = nextEdgeId() 
	trace("final entity=",entity.entity,"length of tangent for final segment = ",vec3.length(prevtangent), " and ", vec3.length(rightTangent))
	setTangent(entity.comp.tangent0, prevtangent)
	setTangent(entity.comp.tangent1, vec3.length(prevtangent)*vec3.normalize(rightTangent))
	entity.comp.node0 = prevnode
	entity.comp.node1 = rightNode
	if not params.isTrack and not params.isHighway then 
		local naturalTangent = rightNodePos -splits[#splits].p1
		local angleToNaturalTangent = math.abs(util.signedAngle(naturalTangent, rightTangent))
		local canAdjust = true 
		if rightNode > 0 and #util.getSegmentsForNode(rightNode) > 1 then 
			canAdjust = false
		end 
		trace("Inspecting final angle to natural tangent, was",math.deg(angleToNaturalTangent)," canAdjust?",canAdjust)
		if angleToNaturalTangent > math.rad(45) and canAdjust then 
			trace("Adjusting to use the natural tangent instead")
			setTangent(entity.comp.tangent1, naturalTangent) -- we can do this because road nodes to not to have their tangents lined up exactly
		end 
	end 
	local prevSplit = splits[nodecount]
	local lastPointNeedsBridge = util.isUnderwater(rightNodePos) or rightNodePos.z - util.th(rightNodePos) > 10 or prevSplit and prevSplit.p1.z- prevSplit.terrainHeight > 50
	local lastPointNeedsTunnel = util.th(rightNodePos) - rightNodePos.z > 10 
	if prevSplit and (prevSplit.needsBridge and lastPointNeedsBridge or prevSplit.terrainHeight <0) then
		 setBridge(entity, prevSplit, prevEntity, params)  
	end
	local needsBridgeTypeCorrection = rightEdge.type == 1 and entity.comp.type == 1 and rightEdge.typeIndex ~= entity.comp.typeIndex  
	if needsBridgeTypeCorrection then 
		entity.comp.typeIndex = rightEdge.typeIndex
		correctPriorBridgeTypes(rightEdge.typeIndex)
	end 
	if prevSplit and prevSplit.tunnelCandidate and lastPointNeedsTunnel then 
		setTunnel(entity)
	end
	if  priorPointHadCollision and entity.comp.type == 0 and mainLineEdges[#mainLineEdges] then 
		trace("Copying the last edge type as it had a collision")
		entity.comp.type= mainLineEdges[#mainLineEdges].comp.type
		entity.comp.typeIndex= mainLineEdges[#mainLineEdges].comp.typeIndex
	end
	
	table.insert(edgesToAdd, entity)
	if params.isTrack and params.useDoubleTerminals and not isTerminus2 then 
		local otherRightRightNode = util.findDoubleTrackNode(rightNode)
		if otherRightRightNode then 
			local entity2 = util.copySegmentAndEntity(entity, nextEdgeId())
			entity2.comp.node1 = otherRightRightNode
			trace("useDoubleTerminals: connecting segment for right node at ",entity2.entity, " otherRightRightNode=",otherRightRightNode, newEdgeToString(entity2), " copied edge:", newEdgeToString(entity), " tangentLength=",vec3.length(entity.comp.tangent0))
			table.insert(edgesToAdd, entity2)
		else 
			trace("useDoubleTerminals: WARNING! Request to use double terminals but no other rightnode found")
		end 
		local otherRightRightNode = util.findDoubleTrackNode(rightNode)
	end 
	
	if isDoubleTrack then
		local t0 = util.v3(entity.comp.tangent0)
		local t1 = util.v3(entity.comp.tangent1)
		local entity2 = copySegmentAndEntity(entity)
		entity2.entity = nextEdgeId() 
		entity2.comp.node0 = prevNode2
		entity2.comp.node1 = otherRightNode
		trace("created double track node ",entity2.entity)
		table.insert(edgesToAdd, entity2)
		if params.useDoubleTerminals and not isTerminus2  then 
			local otherRightRightNode = util.findDoubleTrackNode(otherRightNode)
			if otherRightRightNode then 
				local entity3 = util.copySegmentAndEntity(entity2, nextEdgeId())
				entity3.comp.node1 = otherRightRightNode
				trace("useDoubleTerminals: connecting double track segment for right node at ",entity3.entity, " otherRightRightNode=",otherRightRightNode, newEdgeToString(entity3), " copied edge:", newEdgeToString(entity2)," tangentLength=",vec3.length(entity3.comp.tangent0))
				table.insert(edgesToAdd, entity3)
			else 
				trace("useDoubleTerminals: WARNING! Request to use double terminals but no other rightnode found")
			end 
		end 
		 if params.isQuadrupleTrack then 
				local entity3 = copySegmentAndEntity(entity, nextEdgeId()) 
				trace("Created triple track edge at ",i," entity was",entity3.entity, "looking for double track node at ",rightNodePos.x,rightNodePos.y,rightNodePos.z)
				local filterFn = function(node) return #util.getTrackSegmentsForNode(node) == 1 end
				local node3 = util.findDoubleTrackNode(rightNodePos, -1*rightTangent, 1, 1, true, { [rightNode]=true, [otherRightNode]=true },filterFn)
				if not node3 then 
					node3= util.findDoubleTrackNode(rightNodePos, -1*rightTangent, 2, 1, true, { [rightNode]=true, [otherRightNode]=true }, filterFn)
					trace("Trying to find node3 at 2x track offsets, found?",node3, " The right handed nodes were",rightNode, otherRightNode)
					if not node3 then 
						error("No node found")
					end
				end 
				local node4 = util.findDoubleTrackNode(util.nodePos(otherRightNode), rightTangent, 1, 1, true, { [rightNode]=true, [otherRightNode]=true, [node3]=true  },filterFn)
				if not node4 then 
					node4= util.findDoubleTrackNode(util.nodePos(otherRightNode), rightTangent, 2, 1, true, { [rightNode]=true, [otherRightNode]=true, [node3]=true }, filterFn)
					trace("Trying to find node4 at 2x track offsets, found?",node4, " The right handed nodes were",rightNode, otherRightNode)
					if not node4 then 
						error("No node found")
					end
				end 
				trace("The right handed nodes were",rightNode, otherRightNode,node3, node4)
			 
				entity3.comp.node0 = prevNode3
				entity3.comp.node1 = node3
				local p0 = nodePos(prevNode3)
				local p1 = nodePos(node3)
				local edgeLength = util.calculateTangentLength(p0, p1, t0, t1)
				util.setTangent(entity3.comp.tangent0, edgeLength*vec3.normalize(t0))
				util.setTangent(entity3.comp.tangent1, edgeLength*vec3.normalize(t1))
				table.insert(edgesToAdd, entity3)
				 
				
				local entity4 = copySegmentAndEntity(entity, nextEdgeId()) 
				trace("Created quad track edge at ",i," entity was",entity4.entity)
		 
				entity4.comp.node0 = prevNode4
				entity4.comp.node1 = node4
				local p0 = nodePos(prevNode4)
				local p1 = nodePos(node4)
				local edgeLength = util.calculateTangentLength(p0, p1, t0, t1)
				util.setTangent(entity4.comp.tangent0, edgeLength*vec3.normalize(t0))
				util.setTangent(entity4.comp.tangent1, edgeLength*vec3.normalize(t1))
				table.insert(edgesToAdd, entity4)
				if not params.useDoubleTerminals then
					buildSignals(edgeObjectsToAdd, nodecount, nodecount, entity3, entity4, false)
				end
			end
			if params.isHighway then 
				util.reverseNewEntity(entity2)
			elseif otherRightNode~=rightNode and #rightEdge.objects == 0 and not params.useDoubleTerminals then
				buildSignals(edgeObjectsToAdd, nodecount, nodecount, entity, entity2, false)
			end
		-- crossover
		--[[if requiresRightCrossover then
			local entity3 = copySegmentAndEntity(entity)
			entity3.entity = nextEdgeId() 
			entity3.comp.node0 = prevNode2 
			entity3.comp.node1 = rightNode
			table.insert(edgesToAdd, entity3)
		end--]]
	end
	local ignoreErrors = params.ignoreErrors
	if nodecount > 100 then 
		ignoreErrors = true 
	end
	
	for i, edge in pairs(edgesToAdd) do 
		if edge.comp.node0 > 0 and oldToNewNodeMap[edge.comp.node0] then 
			trace("At edge",edge.entity," replacing node0",edge.comp.node0, "with",oldToNewNodeMap[edge.comp.node0].entity)
			edge.comp.node0 = oldToNewNodeMap[edge.comp.node0].entity
		end 
		if edge.comp.node1 > 0 and oldToNewNodeMap[edge.comp.node1] then 
			trace("At edge",edge.entity," replacing node1",edge.comp.node1, "with",oldToNewNodeMap[edge.comp.node1].entity)
			edge.comp.node1 = oldToNewNodeMap[edge.comp.node1].entity
		end 
	end 
	
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	--newProposal = routeBuilder.attemptDeconfliction(newProposal)	
	trace("About to create test data, added ",#edgesToAdd," for nodecount=",nodecount)
	local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	local debugFile = io.open("/tmp/tf2_build_debug.log", "a")
	if debugFile then
		debugFile:write(os.date("%H:%M:%S") .. " ROUTE_COSTS: costs=" .. tostring(testData.costs) .. " availableBalance=" .. tostring(util.getAvailableBalance()) .. " isForTranshipment=" .. tostring(params.isForTranshipment) .. "\n")
		debugFile:close()
	end
	if testData.costs > util.getAvailableBalance() and not params.isForTranshipment then
		trace("Aborting build for route as costs ",testData.costs," exceeds available budget",util.getAvailableBalance())
		return false, "Not enough money", testData.costs
	end
	if params.isShortCut then 
		local maximumShortCutBudget = params.maxShortCutBudgetPerKm * (util.distance(leftNodePos,rightNodePos)/1000)
		trace("For shortcut comparing the maximumShortCutBudget",maximumShortCutBudget,"to the costs",testData.costs," can build?",(testData.costs > maximumShortCutBudget))
		if testData.costs > maximumShortCutBudget then 
			return false, "Not enough money", testData.costs
		end 
	end
	
	if testData.errorState.critical then
		trace("Critical error seen in the test data between",leftNode,rightNode)
		if util.tracelog and params.lastRouteBuildAttempt then 
			--debugPrint(newProposal)
			debugPrint(testData.collisionInfo.collisionEntities)
			debugPrint(testData.errorState)
			-- DIAGNOSE
			--if not isDoubleTrack and nodecount < 50 then -- NB the diagnosis can crash the game "heap corruption"
			--if allowDiagnose then 
				debugPrint(newProposal)
				local diagnose= true 
				proposalUtil.allowDiagnose = true 
			 	routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
			--end
			--end
			if not isDoubleTrack then
			--routeBuilder.setupProposalAndDeconflict(cloneNodesToLua(nodesToAdd), cloneEdgesToLua(edgesToAdd), edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, true)
			end
		end 
		
		params.applyNodeOffsetsOnly = true
		if paramHelper.getParams().allowGradeCrossings and params.isTrack and params.isDoubleTrack and not params.isQuadrupleTrack then 
			trace("Suppressing double track for callback after between",leftNode,rightNode)
			params.isDoubleTrack = false 
			params.tryRouteBuildCallback = function(res, success)
				trace("Inside tryRouteBuildCallback: was success?",success)
				params.isDoubleTrack= true 
				if success then
					util.clearCacheNode2SegMaps()
					routeBuilder.executeImmediateWork(
						function() 
							util.lazyCacheNode2SegMaps()
							local routeInfo = pathFindingUtil.getRouteInfoForRailPathBetweenEdges(leftEdgeId, rightEdgeId)
							if not routeInfo then 	
								trace("ERROR! No route info found between",leftEdgeId, rightEdgeId)
								if params.station1 and params.station2 then 
									routeInfo = pathFindingUtil.getRouteInfo(params.station1, params.station2)
									trace("Attempting to get routeinfo from stations",params.station1, params.station2," success?",routeInfo ~=nil)
								end 
							end 
							if otherLeftNode and otherLeftNode ~= leftNode then 
								if otherLeftNode ~= util.getEdge(leftEdgeId).node0  and otherLeftNode ~= util.getEdge(leftEdgeId).node1 then 
									routeInfo.firstUnconnectedTerminalNode = otherLeftNode
								else 
									routeInfo.firstUnconnectedTerminalNode = leftNode
								end 
							else 
								routeInfo.firstUnconnectedTerminalNode = nil
							end 							
							if otherRightNode and otherRightNode ~= rightNode then 
								if otherRightNode ~= util.getEdge(rightEdgeId).node0  and otherRightNode ~= util.getEdge(rightEdgeId).node1 then 
									routeInfo.lastUnconnectedTerminalNode = otherRightNode
								else 
									routeInfo.lastUnconnectedTerminalNode = rightNode
								end 
							else 
								routeInfo.lastUnconnectedTerminalNode = nil -- prevent accidental connection
							end 
							trace("setting the otherLeftNode",otherLeftNode," and otherRightNode",otherRightNode,"as ",routeInfo.firstUnconnectedTerminalNode,routeInfo.lastUnconnectedTerminalNode)
							for i = 1, #routeInfo.edges do 
								if routeInfo.edges[i].id ==leftEdgeId then 
									routeInfo.firstFreeEdge = i+1
								end 
								if routeInfo.edges[i].id ==rightEdgeId then 
									routeInfo.lastFreeEdge = i-1
								end 
							end 
							params.keepUnconnectedTerminalNodes=true
							params.isTerminus1 = isTerminus1
							params.isTerminus2 = isTerminus2
							params.ignoreCosts = true
							routeBuilder.upgradeToDoubleTrack(routeInfo, callback, params, true)
							params.keepUnconnectedTerminalNodes=false
						end
					)
				else 
					callback(res, success)
				end
			end 
		end 
		return false 
	elseif #testData.errorState.messages > 0 then
		if util.tracelog then 
			debugPrint(testData.collisionInfo.collisionEntities)
			debugPrint(testData.errorState)
		end
		trace("Ignorable error seen in the test data while building between",leftNode,rightNode)
		if testData.errorState.messages[1]=="Too much curvature" then
			params.smoothingPasses = 2*params.smoothingPasses		
			trace("too much curvature detected, attempting to increase smoothing passes to ",params.smoothingPasses)
			
		end
		local canRemove = {}
		local alreadySeen = {}
		for i , e in pairs(testData.collisionInfo.collisionEntities) do
			if not params.collisionEntities then 
				params.collisionEntities = {}
			end
			params.collisionEntities[e.entity]=true
			if not alreadySeen[e.entity] and e.entity > 0 then 
				alreadySeen[e.entity]=true 
				local entityDetails = util.getEntity(e.entity) 
				if entityDetails and entityDetails.type == "CONSTRUCTION" and string.find(entityDetails.fileName, "depot") then 
					trace("Found removable entity", e.entity)
					table.insert(canRemove, e.entity)
				end 
			end 
		end
		local errorResolved = false 
		if #canRemove > 0 then 
			newProposal.constructionsToRemove = canRemove
			testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
			errorResolved = #testData.errorState.messages == 0 and not testData.errorState.critical
			trace("After removing the entity, the errorResolved?",errorResolved)
		end 
		local totalTimeTaken = os.clock()-params.tryBuildRouteStartTime
		trace("On attempt ",params.buildRouteAttempt," the total time taken was ",totalTimeTaken)
		if totalTimeTaken > 60 then 
			ignoreErrors = true 
		end
		
		if params.buildRouteAttempt >= 2 and params.isHighway then 
			ignoreErrors = true

		end
		if #testData.errorState.messages == 1 and testData.errorState.messages[1]=="Bridge pillar collision" then 
			trace("Seen only Bridge pillar collision on the scond attempt, ignoring")
			ignoreErrors = true
		end 
		
		if not ignoreErrors and not errorResolved then
			return false
		end
	else 
		trace("Completed validation of route with no errors")
		--debugPrint(newProposal)
	end
	if undo_script then 
		pcall(function() undo_script.saveBuildDetailsForUndo(newProposal) end)
	end 
	trace("tryBuildRoute: About to build command")
	
	--debugPrint(newProposal)
	--debugPrint(newProposal)
	--debugPrint(api.engine.util.proposal.makeProposalData(newProposal, util.initContext()))
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors)
	trace("tryBuildRoute: About to sent command to build route between",leftNode,rightNode)
	
	--if tracelog then debugPrint(build) end
	util.clearCacheNode2SegMaps() 
	if params.tryRouteBuildCallback then 
		callback = params.tryRouteBuildCallback
	end
	profiler.beginFunction("tryBuildRoute: sendCommand")
	api.cmd.sendCommand(build, function(res, success)
		profiler.endFunction("tryBuildRoute: sendCommand")
		if success then 
			--saveForUndo(res)
			routeBuilder.addWork(function() routeBuilder.postBuildCleanup(res, params)end)
			if #edgePositionsToCheck > 0 then 
				routeBuilder.addWork(function() proposalUtil.checkEdgeTypes(edgePositionsToCheck, nil, true) end)
			end 
		end 
		if callback then 
			callback(res, success)
		end 
	end)
	util.clearCacheNode2SegMaps()
	params.tryRouteBuildCallback= nil
	
	trace("End of route building between",leftNode,rightNode," time taken=",(os.clock()-params.tryBuildRouteStartTime))
	
	for i, crossing in pairs(highwayCrossings) do 
		routeBuilder.addWork(function() routeBuilder.buildHighwayCrossing(crossing, params) end)
	end
	
	return true
end -- END tryBuildRoute


function routeBuilder.checkAndRemoveDepot(node) 
	trace("routeBuilder.checkAndRemoveDepot: checking",node) 
	util.lazyCacheNode2SegMaps()
	if not util.isNodeConnectedToFrozenEdge(node) then 
		trace("routeBuilder.checkAndRemoveDepot: node was not part of a station") 
		return  
	end 
	for i, otherNode in pairs(util.findDoubleTrackNodes(node)) do 
		local segs = util.getSegmentsForNode(otherNode) 
		trace("Getting segments for otherNode",otherNode,"got",segs)
		if #segs == 2 then 
			local seg = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
			local edge = util.getEdge(seg)
			local nextNode = otherNode == edge.node0 and edge.node1 or edge.node0 
			local constructionId = util.isNodeConnectedToFrozenEdge(nextNode)
			if constructionId then 
				local construction = util.getConstruction(constructionId) 
				trace("Found edge connected to frozen node",nextNode,"with ",constructionId,"fileName=",construction.fileName)
				if construction.depots[1] then 
					local newProposal = api.type.SimpleProposal.new()
					newProposal.streetProposal.edgesToRemove[1]=seg 
					newProposal.streetProposal.nodesToRemove[1]=nextNode
					newProposal.constructionsToRemove = { constructionId } 
					local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
					trace("routeBuilder.checkAndRemoveDepot: About to sent removing",constructionId)
					api.cmd.sendCommand(build, function(res, success) 
						trace("outeBuilder.checkAndRemoveDepot: attempt command result was", tostring(success))
						util.clearCacheNode2SegMaps()
						if not success and util.tracelog then 
							debugPrint(res) 
						end 
					end)
					util.clearCacheNode2SegMaps()
					return -- exit as we only expect one and this may invalidate a lot of the nodes/segments anyway
				end
			end 
			
		end 
		
	end 
	
end 

function routeBuilder.buildRoute(nodepair, params, callback)
	trace("begin build route between nodes ",  nodepair[1], nodepair[2])
	profiler.beginFunction("routeBuilder.buildRoute")
	local startTime = os.clock()
	-- Guard: nodes may have been removed by a previous build/deconflict
	-- (e.g. double-track or straighten replaced an edge). Bail gracefully
	-- instead of hard-erroring in distBetweenNodes.
	if not nodepair or not nodepair[1] or not nodepair[2] then
		trace("buildRoute: nil nodepair, aborting")
		if callback then callback(nil, false) end
		return
	end
	if not api.engine.entityExists(nodepair[1]) or not api.engine.entityExists(nodepair[2]) then
		trace("buildRoute: node no longer exists (", nodepair[1], nodepair[2], ") aborting gracefully")
		if callback then callback(nil, false) end
		return
	end
	if params.isTrack then 	
		routeBuilder.checkAndRemoveDepot(nodepair[1]) 
		routeBuilder.checkAndRemoveDepot(nodepair[2])  
	end 
	
	local maxTries = 7
	local success = false
	local reason
	local costs
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps() 
	params  = util.shallowClone(params)
	params.ignoreErrors =false
	if params.ignoreErrorsOverridden  then 
		params.ignorableErrors = true 
	end 
	if util.distBetweenNodes( nodepair[1], nodepair[2]) > 10000  then -- performance optimisation
		trace("Long distance detected, setting ignoreErrors to true")
		params.ignoreErrors = true
	end 
	if params.useDoubleTerminals then 
		params.ignoreErrors = true 
	end
	tryToFixTunnelPortals = true
	for i = 1, maxTries do 
		trace("attempting route build, attempt number ",i) 
		params.buildRouteAttempt = i
		if i > 0.5*maxTries then 
			trace("At attempt ",i, " of ",maxTries," setting ignoreErrors to true") 
			params.ignoreErrors = true 
		end
		success , reason , costs = routeBuilder.tryBuildRoute(nodepair, params, callback)
		if not success and util.tracelog then 
			-- error("Not success")
		end
		local timeSinceStart = os.clock() - startTime
		trace("At iteration",i,"was success?",success,"timeSinceStart=",timeSinceStart)
		if success then 
			trace("route build successful at attempt number ",i) 
			break
		elseif params.isShortCut then 
			trace("Giving up route build after first attempt for short cut")
			break 
		end 
		if timeSinceStart > 30 then 
			params.ignoreErrors = true 
			trace("Setting ignoreErrors to true due to long wait time at iteration",i)
		end 
		if params.failedMaxBuildDist then 
			trace("Exiting build attempt as it would be too long")
			params.failedMaxBuildDist = false
			params.maxBuildDist = nil
			break 
		end
		if reason == "Not enough money"  then 
			trace("Failing route due to not Not enough money")
			callback({reason = "Not enough money", costs=costs}, false)
			return
		end 
		local targetSeglenthOffset = 2
		if params.useDoubleTerminals then 
			targetSeglenthOffset = 5 -- sometimes have a problem using long segments for connect
		end 
		params.targetSeglenth= params.targetSeglenth-targetSeglenthOffset
		params.routeDeviationPerSegment = params.routeDeviationPerSegment+1
		if i < 4 then 
			params.routeScoreWeighting[3]=params.routeScoreWeighting[3]+10 -- nearbyEdges
			params.routeScoreWeighting[5]=params.routeScoreWeighting[5]+5 -- distance
		end 
		if i == maxTries-3 then 
			params.allowGradeCrossings = false 
			params.disableJunctions = true
		end
		if i == maxTries-2 then 
			tryToFixTunnelPortals = false 
		end
		if i == maxTries-1  then -- last ditch attempt
			trace("Attempting route build  ignoreAllOtherSegments")
			params.useDoubleTerminals = false 
			params.ignoreAllOtherSegments = true
			params.lastRouteBuildAttempt = true 
		end
	end
	if not success then 
		trace("Failed building route!",nodepair[1], nodepair[2])
		--if util.tracelog then debugPrint({nodepair=nodepair, params=params}) end
		callback({}, false)
		
		if util.tracelog then 
			--error("Failed building route!",nodepair[1], nodepair[2])
		end 
	end
	tryToFixTunnelPortals = true
	util.clearCacheNode2SegMaps() 
	profiler.endFunction("routeBuilder.buildRoute")
	profiler.printResults()
end
function routeBuilder.getOnRampType()
	local compact = api.res.streetTypeRep.find("country_small_one_way_compact.lua")
	if compact ~= -1 and false then	
		return compact 
	end
	return api.res.streetTypeRep.find("standard/country_small_one_way_new.lua")
end  



function routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, highwayNode, highwayNodePos,highwayTangent, highwayEdgeType, connectNode, connectNodePos, params, nextEdgeId, nextNodeId, isExit, junctionTangent, validate) 
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local onRampType = routeBuilder.getOnRampType()
	local exitAngle = util.getNumberOfStreetLanes(params.preferredHighwayRoadType) >= 5 and math.rad(60) or math.rad(45)
	local exitTangent = util.rotateXY(highwayTangent, isExit and -exitAngle or exitAngle)
	
	
	
	local dist = util.distance(highwayNodePos, connectNodePos)
	trace("Building highway onramp from ",highwayNode," to ",connectNode," isExit=",isExit,"junctionTangent=",junctionTangent.x,junctionTangent.y,"highwayTangent=",highwayTangent.x,highwayTangent.y)
	trace(debug.traceback())
	if connectNode > 0 then 
		local connectEdge = util.getEdge(util.getStreetSegmentsForNode(connectNode)[1])
		local tangentToCheck = connectEdge.node0 == connectNode and connectEdge.tangent0 or connectEdge.tangent1 
		local connectAngle = math.abs(util.signedAngle(junctionTangent, tangentToCheck))
		if connectAngle > math.rad(90) then 
			connectAngle = math.rad(180) - connectAngle
		end 
		trace("For the connectNode",connectNode,"the connectAngle was",math.deg(connectAngle),"the raw connect angle is",math.deg(util.signedAngle(junctionTangent, tangentToCheck)))
		if connectAngle < math.rad(10) then 
			trace("Aborting build due to shallow angle")
			return
		end 
	end 
	local edge = {
		p0 = highwayNodePos ,
		p1 = connectNodePos,
		t0 = dist*vec3.normalize(exitTangent),
		t1 = dist*vec3.normalize(junctionTangent)	,
	}
	dist = math.max(dist, util.calculateSegmentLengthFromNewEdge(edge))
	local connectTh = util.th(connectNodePos)
	local connectNodeNeedsBridge = connectNodePos.z - connectTh > 5 or connectTh < 0 
	local connectNodeNeedsTunnel = connectNodePos.z - connectTh < -8
	trace("Determined that connectNode needs bridge?",connectNodeNeedsBridge," needs tunnel?", connectNodeNeedsTunnel," based on connectNode height=",connectNodePos.z," and terrainHeight=",connectTh)
	local splitPoint 
	local t
	for i = 3, 9 do 
		t = i/12
		local nextSplitPoint = util.solveForPositionHermiteFraction(t, edge)
		local p = nextSplitPoint.p
		if highwayEdgeType == 1 ~= connectNodeNeedsBridge then 
			if p.z - util.th(p) <= 5 and splitPoint then 
				break 
			end
		elseif highwayEdgeType == 2 ~= connectNodeNeedsTunnel then 
			if p.z - util.th(p)  > -8 and splitPoint then 
				break 
			end
		elseif i >= 6 then 
			break 
		end
		splitPoint = nextSplitPoint
	end
	trace("Setting up onRamp, split at t=",t, "dist was ",dist)
	 
	local splitNode = util.newNodeWithPosition(splitPoint.p, nextNodeId())
	
	local entity = api.type.SegmentAndEntity.new()
	entity.entity = nextEdgeId()
	entity.type = 0 
	entity.streetEdge.streetType = onRampType
	entity.comp.type = highwayEdgeType
	if highwayEdgeType == 2 then 
		entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	elseif highwayEdgeType == 1 then 
		entity.comp.typeIndex = cement
	end 
	entity.comp.node0 = highwayNode
	entity.comp.node1 = splitNode.entity 
	util.setTangent(entity.comp.tangent0,t*dist*vec3.normalize(exitTangent)) 
	util.setTangent(entity.comp.tangent1,t*dist*vec3.normalize(splitPoint.t))
	table.insert(edgesToAdd, entity)
	local entity2 = api.type.SegmentAndEntity.new()
	entity2.entity = nextEdgeId()
	entity2.type = 0 
	entity2.comp.node0 = splitNode.entity 
	entity2.comp.node1 = connectNode
	entity2.streetEdge.streetType = onRampType
	if connectNodeNeedsTunnel then 
		entity2.comp.type = 2
		entity2.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	elseif connectNodeNeedsBridge then 
		entity2.comp.type = 1
		entity2.comp.typeIndex = cement
	end 
	util.setTangent(entity2.comp.tangent0,(1-t)*dist*vec3.normalize(splitPoint.t)) 
	--util.setTangent(entity2.comp.tangent1,(1-t)*dist*vec3.normalize(highwayTangent))
	util.setTangent(entity2.comp.tangent1,(1-t)*dist*vec3.normalize(junctionTangent))
	
	if not isExit then
		util.reverseNewEntity(entity)
		util.reverseNewEntity(entity2)
	end
	if validate then 
		local testProposal = api.type.SimpleProposal.new() 
		local connectNodeFull 
		local highwayNodeFull 
		if connectNode < 0 then 
			for i = #nodesToAdd, 1, -1 do  -- should have been added recently
				local newNode = nodesToAdd[i]
				if newNode.entity == connectNode then 
					connectNodeFull = newNode 
					break
				end 
			end 
		end
		
		if highwayNode < 0 then 
			for i = #nodesToAdd, 1, -1 do  -- should have been added recently
				local newNode = nodesToAdd[i]
				if newNode.entity == highwayNode then 
					highwayNodeFull = newNode 
					break
				end 
			end 
		end
		--assert(highwayNodeFull~=nil)
		testProposal.streetProposal.nodesToAdd[1]=splitNode 
		testProposal.streetProposal.edgesToAdd[1]=entity2 
		testProposal.streetProposal.edgesToAdd[2]=entity 
		if connectNodeFull then 
			testProposal.streetProposal.nodesToAdd[2]=connectNodeFull
		end 
		if highwayNodeFull then 
			testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=highwayNodeFull
		end
		if not xpcall(function() util.validateProposal(testProposal) end, err) then 
			trace("buildHighwayOnRamp: failed to validate proposal")
			table.remove(edgesToAdd)
			return 
		end 
		local result =  api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
		local canIgnore = #result.errorState.messages==1 and result.errorState.messages[1]=="Bridge pillar collision"
		--if not canIgnore and #result.errorState.messages > 0 or result.errorState.critical then 
		if result.errorState.critical then 
			if util.tracelog then debugPrint({ errorState = result.errorState, testProposal=testProposal}) end
			trace("buildHighwayOnRamp: Validation failed for building on ramp, rolling back") 
			table.remove(edgesToAdd)
			return 
		end
	end 

	table.insert(nodesToAdd, splitNode)
	table.insert(edgesToAdd, entity2)
	if util.tracelog then 
		debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
	end 
end

local function buildStartingSignals(routeInfo) 

	for i = routeInfo.firstFreeEdge+1, routeInfo.lastFreeEdge do 
		local doubleTrackEdge = util.findDoubleTrackEdge(routeInfo.edges[i].id)
		if doubleTrackEdge and #routeInfo.edges[i].edge.objects == 0 and #util.getEdge(doubleTrackEdge).objects ==0 then 
			local nodesToAdd = {}
			local edgesToAdd = {}
			local edgeObjectsToAdd = {}
			local edgesToRemove = {}
			local function nextEdgeId() 
				return -1-#edgesToAdd
			end
			local entity = util.copyExistingEdge(routeInfo.edges[i].id,nextEdgeId())
			table.insert(edgesToAdd, entity)
			table.insert(edgesToRemove, routeInfo.edges[i].id)
			local entity2 = util.copyExistingEdge(doubleTrackEdge,nextEdgeId())
			table.insert(edgesToAdd, entity2)
			table.insert(edgesToRemove, doubleTrackEdge)
			local backwards = routeInfo.edges[i].edge.node1 == routeInfo.edges[i-1].edge.node0 or routeInfo.edges[i].edge.node1 == routeInfo.edges[i-1].edge.node1 
			local simplifiedSignalling = false
			buildSignals(edgeObjectsToAdd, -1, math.huge, entity, entity2, backwards, simplifiedSignalling)
			local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
			local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
			local isError = testData.errorState.critical or #testData.errorState.messages > 0
			trace("buildStartingSignals: Attempting to build signals at i",i," had critical error? ", testData.errorState.critical," has messages?",#testData.errorState.messages )
			if not isError then 
				local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
				api.cmd.sendCommand(build, function(res, success) 
					trace("Result of build buildStartingSignals edges command was",success)
					util.clearCacheNode2SegMaps()
				end)
				return
			end
		end
	end 
	trace("WARNING! Unable to build any signals")
end

local function tryUpgradeToDoubleTrack(routeInfo, callback, params)
	if not params then 
		params = paramHelper.getDefaultRouteBuildingParams()
	end
	local startTime = os.clock()

	trace("begin upgrade to double track")
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local nodesToRemove = {}
	
	local alreadySeenCollissionEdges = {}
	local replacedEdgesMap = {}
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local function getOrMakeReplacedEdge(edgeId) 
		local replacement 
		if replacedEdgesMap[edgeId] then 
			trace("Reusing existing edge ", edgeId)
			replacement = replacedEdgesMap[edgeId]
		else 
			replacement = util.copyExistingEdge(edgeId, nextEdgeId())
			trace("tryUpgradeToDoubleTrack: replacing edge",edgeId,"new edge=",replacement.entity)
			table.insert(edgesToAdd, replacement)
			table.insert(edgesToRemove, edgeId)
			replacedEdgesMap[edgeId]=replacement
		end
		return replacement
	end
	
	local nodecount = routeInfo.lastFreeEdge - routeInfo.firstFreeEdge
	local routeEdges = {} 
	local routeNodes =  {}
	for i = 1, #routeInfo.edges do 
		routeEdges[routeInfo.edges[i].id]=true
		for __, node in pairs({routeInfo.edges[i].edge.node0, routeInfo.edges[i].edge.node1}) do
			if not routeNodes[node] then 
				routeNodes[node]=true 
			end
		end 
		if isDepotEdge(routeInfo.edges[i].id, 0) then 
			routeEdges[routeInfo.edges[i].id]=false
			trace("Discovered depot edge masquerading in routeInfo")
			for __, node in pairs(routeInfo.edges[i].edge.node0, routeInfo.edges[i].edge.node1) do
				if #util.getTrackSegmentsForNode(node) == 3 then 
					for __, seg in pairs(#util.getTrackSegmentsForNode(node)) do 
						if isStationEdge(seg) then 
							trace("Replacing with station edge at i=",i, " edge =", seg)
							routeInfo.edges[i].id=seg
							routeInfo.edges[i].edge=util.getEdge(seg)
							routeEdges[routeInfo.edges[i].id]=true
							break
						end
					end
				end
			end
		end
	end 
	 
	
	local nextNodeId = -nodecount * 100
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	local newNodeMap = {}
	local function addNode(newNode) 
		table.insert(nodesToAdd, newNode)
		newNodeMap[newNode.entity]=newNode
	end 
	
	local halfway = math.floor(nodecount/2)
	local targetSignalInterval = paramHelper.getParams().targetSignalInterval
	local targetSignals = math.ceil((nodecount+1) / targetSignalInterval) 
	local signalInterval = math.floor((nodecount+1) / targetSignals)
	local requiresLeftCrossover = false
	local addSignalNextSegment = false
	local crossoverIdx = -1
	local lastSignalIndex = -1
	local reconnectDepotAfter = false
	local function isAddSignals(i)
		if i < crossoverIdx and i>crossoverIdx-2 then 
			return false 
		end
		if params.useDoubleTerminals then 
			if i == 1 then 	
				--return false 
			end 
			if i == 2 or i == routeInfo.lastFreeEdge-1-routeInfo.firstFreeEdge then 	
				--return true 
			end
		end 
		--if true then return i == halfway end
		local result = addSignalNextSegment or math.abs(i-halfway) % signalInterval == 0 or i == 2 or i==nodecount-1 
		if result and i-lastSignalIndex == 1 then
			trace("suppressing signals at ",i," as ones were built in the last segment")
			return false
		end
		--return i==2
		--local firstSignal = requiresLeftCrossover and 2 or 1
		return result
	end
 
	trace("Route info, firstUnconnectedTerminalNode=",routeInfo.firstUnconnectedTerminalNode , " lastUnconnectedTerminalNode=",routeInfo.lastUnconnectedTerminalNode)
	local firstEdge = routeInfo.edges[routeInfo.firstFreeEdge].edge
	local lastNode =   firstEdge.node0
	local backwards = false
	local sign = 1
	if lastNode == routeInfo.edges[routeInfo.firstFreeEdge+1].edge.node1 then 
		backwards = true
		lastNode = firstEdge.node1
	end
	trace("isbackwards=",backwards)
	if params.forceRightHanded then 
		sign = -1
	elseif params.forceLeftHanded then 
		sign = 1
	end
	
	if routeInfo.firstUnconnectedTerminalNode then
		local nodePos = util.nodePos(lastNode)
		local trialNodePos = util.doubleTrackNodePoint(nodePos, sign*util.v3(firstEdge.tangent1))
		local distance = util.distance(util.nodePos(routeInfo.firstUnconnectedTerminalNode), trialNodePos)
		trace("dist between trial nodePos and firstUnconnectedTerminalNode=",distance)
		if distance > 7.5 then
			if not params.forceLeftHanded and not params.forceRightHanded then 
				sign = -1
				lastNode = routeInfo.firstUnconnectedTerminalNode
			else 
				local firstEdgeId = routeInfo.edges[routeInfo.firstFreeEdge].id
				local entity = getOrMakeReplacedEdge(firstEdgeId) 
				if entity.comp.node0 == lastNode then 
					entity.comp.node0 = routeInfo.firstUnconnectedTerminalNode
				else 
					assert(entity.comp.node1 == lastNode)
					entity.comp.node1 = routeInfo.firstUnconnectedTerminalNode
				end 
			end
		else
			lastNode = routeInfo.firstUnconnectedTerminalNode
		end
	end
	local firstNode = lastNode
	local needsEndSwap = false
	if not routeInfo.lastUnconnectedTerminalNode then 
		local endEdge = routeInfo.edges[routeInfo.lastFreeEdge].edge
		local endNode =  backwards and endEdge.node0 or endEdge.node1
		local otherNode = util.findDoubleTrackNode(endNode)
		if otherNode then 
			local otherNodePos = util.nodePos(otherNode)
			
			local tangent = util.v3(backwards and endEdge.tangent0 or endEdge.tangent1)
			local endNodePos = util.nodePos(endNode)
			local trialPos = util.doubleTrackNodePoint(endNodePos, sign*tangent)
			if util.positionsEqual(endNodePos, trialPos) and #util.getTrackSegmentsForNode(otherNode) > 1 then -- not dead end
				trace("Detected proximity to other node at end of route, swapping, nodes were,", endNode, otherNode)	
				needsEndSwap = true				
			end
		end
	end
	local latestSignalIdx
	local depotPos
	local lastLastNode
	local lastNewNode 
	local crossOverThisSeg = false
	local movedNodes = {}
	local removedEdges = {}
	local lastOriginalNode = firstNode
	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge-1 do
		local indexFromStart = i - routeInfo.firstFreeEdge + 1
		local suppressSignals = false
		local edgeAndId = routeInfo.edges[i]
		local edge = edgeAndId.edge
		if not api.engine.entityExists(edgeAndId.id) or not util.getEdge(edgeAndId.id) then 
			return true -- may occur if called twice
		end
		local entity = util.copyExistingEdge(edgeAndId.id, nextEdgeId())
		local needSwap = false
		trace("tryUpgradeToDoubleTrack: At i=",i,"created edge",entity.entity)
		table.insert(edgesToAdd, entity)
		
		if i > routeInfo.firstFreeEdge then 
			local priorEdge = routeInfo.edges[i-1].edge 
			if priorEdge.node0 == edge.node0 or priorEdge.node1 == edge.node1 then 	
				trace("Detected backwards inversion! backwards=",backwards)
				backwards = not backwards
				needSwap = true
			end 
		end 
		
		local node = backwards and edge.node0 or edge.node1
		trace("Got node",node)
		if not node then 
			debugPrint({routeInfo=routeInfo})
		end 
		local nodePos = util.nodePos(node)
		local otherNode = node == edge.node0 and edge.node1 or edge.node0 
		local otherNodePos = util.nodePos(otherNode)
		local tangent = util.v3(backwards and edge.tangent0 or edge.tangent1)
		
		local testNode = util.findDoubleTrackNode(node, tangent)
		
		if testNode then 
			if util.positionsEqual(util.nodePos(testNode), util.doubleTrackNodePoint(nodePos,  sign * tangent),1) then 
				trace("discovered colliding double track node at i=",i," sawpping..")
				needSwap = true
			end
		end
		
		
		if needSwap then 
			suppressSignals = true
			trace("Swapping double track sign at i = ",i)
			sign = -sign
			local entity2 = getOrMakeReplacedEdge(edgeAndId.id)
			local temp = entity 
			
			if backwards then
				entity.comp.node1 = lastNode 
				lastNode = entity2.comp.node1 
			else 
				entity.comp.node0 = lastNode 
				lastNode = entity2.comp.node0 
			end
			entity = entity2 
		end

		
		local newNode = newDoubleTrackNode(nodePos, sign * tangent) 
		--local theirDist = util.distBetweenNodes(edge.node0, edge.node1)
		--local theirSegmentLength = util.calculateSegmentLengthFromEdge(edge)
		--local theirLenght = vec3.length(util.v3(edge.tangent0))
		--local ourDist =util.distance(util.v3(newNode.comp.position), lastNode > 0 and util.nodePos(lastNode) or util.v3(lastNewNode.comp.position))
		--local correctionFactor = ourDist / theirDist
		--trace("Their dist was ",theirDist, " our dist was ", ourDist," theirSegmentLength=",theirSegmentLength," theirTangentlength=",theirLenght, " correctionFactor=",correctionFactor)
		newNode.entity = getNextNodeId()
		if backwards then
			entity.comp.node1 = lastNode 
			entity.comp.node0 = newNode.entity
		else 
			entity.comp.node0 = lastNode 
			entity.comp.node1 = newNode.entity
		end
		local p0 = lastNode > 0 and util.nodePos(lastNode) or util.v3(lastNewNode.comp.position)
		local p1 = util.v3(newNode.comp.position)
		local t0 = util.v3(entity.comp.tangent0)
		local t1 = util.v3(entity.comp.tangent1)
		if util.distance(p1, p0) < 60 and isAddSignals(indexFromStart)  then 
			trace("Suppressing signals due to short seglength at ",i)
			suppressSignals = true
		end
		trace("Created double track node at ",p0.x,p0.y,p0.z," original nodePos was ",nodePos.x,nodePos.y,nodePos.z)
		local length = util.calculateTangentLength(p0, p1, t0, t1,true)
		local originalTangentLength = util.calculateTangentLength(otherNodePos, nodePos, t0, t1)
		local newLength = (length / originalTangentLength) * vec3.length(t0)
		trace("Calculated tangent length as ",length," originally",vec3.length(t0)," for entity ",entity.entity," recomputed it was ",originalTangentLength," setting length to ",newLength)
		util.setTangent(entity.comp.tangent0, newLength*vec3.normalize(t0))
		util.setTangent(entity.comp.tangent1, newLength*vec3.normalize(t1))
		
		addNode( newNode)
		if params and params.useDoubleTerminals and i == routeInfo.firstFreeEdge and not params.isTerminus1 then 
			local otherNode = util.findDoubleTrackNode(firstNode)
			if otherNode then 
				local entity2 = util.copySegmentAndEntity(entity, nextEdgeId())
				if backwards then 
					entity2.comp.node1 = otherNode 
				else
					entity2.comp.node0 = otherNode 
				end
				local dist = util.distance(util.nodePos(otherNode),newNode.comp.position)
				table.insert(edgesToAdd, entity2)
				if util.tracelog then trace("tryUpgradeToDoubleTrack: Created edge  at start for useDoubleTerminals:",newEdgeToString(entity2)," at a distance of ",dist, "created entity",entity2.entity) end
			else 
				trace("WARNING! Unable to find double track node for",firstNode)
			end 
			suppressSignals = true
		end 
		if crossoverIdx == i then 
			trace("Adding crossover at ",i)
			local entity2 = copySegmentAndEntity(entity)
		--	if backwards ~= (sign<0) then 
			if backwards then
				--entity2.comp.node0= node
				entity2.comp.node1 = lastOriginalNode
			else   
				--entity2.comp.node1=node
				entity2.comp.node0 = lastOriginalNode
			end
			entity2.entity = nextEdgeId()
			trace("added crossover entity with entity",entity2.entity)
			table.insert(edgesToAdd, entity2)
			 
			crossOverThisSeg=true
		else 
			crossOverThisSeg=false
		end
		
		local connectedEdges = util.getTrackSegmentsForNode(node)
		if #connectedEdges == 4 and util.getNode(node).doubleSlipSwitch then 
			suppressSignals = true
			local edgesToKeep = {} 
			edgesToKeep[edgeAndId.id] = true 
			if routeInfo.edges[i-1] then 
				edgesToKeep[routeInfo.edges[i-1].id]=true
			end
			if routeInfo.edges[i+1] then 
				edgesToKeep[routeInfo.edges[i+1].id]=true 
			end
			for i, edge in pairs(connectedEdges) do 
				if not edgesToKeep[edge] and not removedEdges[edge] then 
					removedEdges[edge]=true
					trace("Removing edge",edge," that was connected to a track junction")
					table.insert(edgesToRemove, edge) 
				end
			end 
			reconnectDepotAfter = true
			depotPos = util.nodePos(node)
		end 
		if #util.getSegmentsForNode(node) > 2 or #util.getSegmentsForNode(otherNode)> 2  then 
			suppressSignals = true
		end
		local depotEdgeId = findDepotEdge(connectedEdges, routeInfo, i, node, routeEdges)
		if #connectedEdges == 3 and not params.useDoubleTerminals and depotEdgeId then
			
			 
			trace("found three connected edges at node ",node," index ", indexFromStart)
			local depotEdge = util.getEdge(depotEdgeId)
			local p1 = util.nodePos(depotEdge.node0)
			local p2 = util.nodePos(depotEdge.node1)
			local p3 = lastNewNode and util.v3(lastNewNode.comp.position) or util.nodePos(lastNode)
			local p4 = util.v3(newNode.comp.position)
			depotPos = p1
			local c = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
			if c and not params.forceRemoveDepotTrack then
				local zavg = (p1.z+p2.z+p3.z+p4.z)/4
				c = util.v2ToV3(c, zavg)
				trace("found depotEdge, was ",depotEdgeId," WAS a collision")
				table.insert(edgesToRemove, depotEdgeId)
				removedEdges[depotEdgeId]=true
				local newEdge = {
					p0= backwards and p4 or p3,
					p1= backwards and p3 or p4,
					t0= util.v3(entity.comp.tangent0),
					t1= util.v3(entity.comp.tangent1)
				} 
				
				local fullSolution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c, depotEdgeId, newEdge, util.distance)
				local collisionNode = newNodeWithPosition(fullSolution.c)
				collisionNode.entity = getNextNodeId()
				collisionNode.comp.doubleSlipSwitch=true
				--table.remove(edgesToAdd)
				addNode( collisionNode)
				local depotLink1 = util.copyExistingEdge(depotEdgeId)
				depotLink1.entity = nextEdgeId()
				depotLink1.comp.node1 = collisionNode.entity 
				setTangent(depotLink1.comp.tangent0, fullSolution.existingEdgeSolution.t0)
				
				local depotCrossingTangent =fullSolution.existingEdgeSolution.t1
				local rawAngle = util.signedAngle(fullSolution.newEdgeSolution.t1, depotCrossingTangent)
				local angle = math.abs(rawAngle) > math.rad(90) and math.rad(180)-math.abs(rawAngle) or rawAngle
				trace("angle to the depot tangent was ", math.deg(angle), " rawAngle was ",math.deg(rawAngle))
				if math.abs(angle) < math.rad(20) then
					local absCorrection = math.rad(20)-math.abs(angle)
					local correction = angle > 0 and absCorrection or -absCorrection
					depotCrossingTangent = util.rotateXY(depotCrossingTangent, correction)
					local angle = util.signedAngle(fullSolution.newEdgeSolution.t1, depotCrossingTangent)
					trace("after correction the angle to the depot tangent was ", math.deg(angle))
				end
				
				local joinTangent = vec3.length( fullSolution.existingEdgeSolution.t1)* vec3.normalize( fullSolution.newEdgeSolution.t1)
				setTangent(depotLink1.comp.tangent1, depotCrossingTangent)
				--setTangent(depotLink1.comp.tangent1, fullSolution.existingEdgeSolution.t1)
				trace("tryUpgradeToDoubleTrack: added depotLink1 with entity",depotLink1.entity)
				table.insert(edgesToAdd, depotLink1)
				--buildCrossoverNextSeg = true
			
				local depotLink2 = util.copyExistingEdge(depotEdgeId)
				depotLink2.entity = nextEdgeId()
				depotLink2.comp.node0 = collisionNode.entity
				if util.tracelog then debugPrint(fullSolution) end
				local depotCrossingTangent2 = vec3.length(fullSolution.existingEdgeSolution.t2)*vec3.normalize(depotCrossingTangent)
				setTangent(depotLink2.comp.tangent0, depotCrossingTangent2)
				setTangent(depotLink2.comp.tangent1, fullSolution.existingEdgeSolution.t3)
				trace("tryUpgradeToDoubleTrack: added depotLink2 with entity",depotLink2.entity) 
				table.insert(edgesToAdd, depotLink2)
				
				local ourLink = copySegmentAndEntity(entity, nextEdgeId())
				if backwards then 
					entity.comp.node1 = collisionNode.entity 
					ourLink.comp.node0 = collisionNode.entity
					setTangent(entity.comp.tangent0, fullSolution.newEdgeSolution.t0)
					setTangent(entity.comp.tangent1, fullSolution.newEdgeSolution.t1)
					setTangent(ourLink.comp.tangent0, fullSolution.newEdgeSolution.t2)
					setTangent(ourLink.comp.tangent1, fullSolution.newEdgeSolution.t3)
				else 
					ourLink.comp.node1 = collisionNode.entity 
					entity.comp.node0 = collisionNode.entity
					
					
					setTangent(ourLink.comp.tangent0, fullSolution.newEdgeSolution.t0)
					setTangent(ourLink.comp.tangent1, fullSolution.newEdgeSolution.t1)
					setTangent(entity.comp.tangent0, fullSolution.newEdgeSolution.t2)
					setTangent(entity.comp.tangent1, fullSolution.newEdgeSolution.t3)
				end
					
					
				trace("Setting up tangents for depot crossing, lengths were ", vec3.length(fullSolution.newEdgeSolution.t0), vec3.length( fullSolution.newEdgeSolution.t1),vec3.length( fullSolution.newEdgeSolution.t2), vec3.length(fullSolution.newEdgeSolution.t3), " backwards = ",backwards)
	
				trace("tryUpgradeToDoubleTrack: added ourLink with entity",ourLink.entity,"updated tangents on",entity.entity)
				table.insert(edgesToAdd, ourLink)
				
			elseif indexFromStart == 1 and not routeInfo.firstUnconnectedTerminalNode then
				trace("found depotEdge, was on route that needs removing")
				table.insert(edgesToRemove, depotEdgeId)
				removedEdges[depotEdgeId]=true
				reconnectDepotAfter = true
			else 
				trace("found depotEdge, was ",depotEdgeId," was NOT a collision")
				if params.forceRemoveDepotTrack then 
					trace("force removing  depotEdge,  ",depotEdgeId)
					table.insert(edgesToRemove, depotEdgeId)
					removedEdges[depotEdgeId]=true
					reconnectDepotAfter = true
				else
					if i < halfway then 
						crossoverIdx = i+2
					else
						if lastSignalIndex < indexFromStart-1 then 
							trace("attempting to build crossover to connect to depot")
							local entity2 = util.copyExistingEdge( routeInfo.edges[i].id, nextEdgeId())
							if backwards ~= (sign<0) then 
								entity2.comp.node0=lastLastNode
							else 
								entity2.comp.node1=lastLastNode
							end
							trace("tryUpgradeToDoubleTrack: added drossover to connect to depot with",entity2.entity)
							table.insert(edgesToAdd, entity2)
						else
							trace("depot link will need rebuilding", depotEdgeId)
							table.insert(edgesToRemove, depotEdgeId)
							removedEdges[depotEdgeId]=true
							reconnectDepotAfter = true
						end
					end
				end
			end
		elseif  #util.getTrackSegmentsForNode(backwards and edge.node1 or edge.node0) == 3 then
			suppressSignals = true -- for some reason the game gets very upset and crashes if we try to add a signal on a junction
		end
		
		
		
		local streetEdges =  util.getStreetSegmentsForNode(node)
		if #streetEdges > 0  then 
			if params.ignoreGradeCrossings then 
				goto continue 
			end
			local nextRoutePoint = routeInfo.edges[i+1]
			--debugPrint({nextRoutePoint=nextRoutePoint}) 
			
			local tBefore = util.v3(backwards and edge.tangent1 or edge.tangent0)
			local t = util.v3(tangent)
			local tAfter = util.v3(backwards and nextRoutePoint.edge.tangent0 or nextRoutePoint.edge.tangent1)
			
			local pBefore =  lastNewNode and util.v3(lastNewNode.comp.position) or util.nodePos(lastNode)
			local p  = util.v3(newNode.comp.position) 
			local pAfter = util.doubleTrackNodePoint(util.nodePos(backwards and nextRoutePoint.edge.node0 or nextRoutePoint.edge.node1), sign* tAfter) 
			local edgeToReplace = streetEdges[1]
			local otherEdge = streetEdges[2]
			local c = util.checkCollisionBetweenExistingEdgeAndProposedNode(edgeToReplace, p, t, pBefore, pAfter, tBefore, tAfter)
			if not c and otherEdge then
				edgeToReplace = streetEdges[2]
				otherEdge = streetEdges[1]
				c = util.checkCollisionBetweenExistingEdgeAndProposedNode(edgeToReplace, p, t, pBefore, pAfter, tBefore, tAfter)
			end
			if not c then 
				trace("WARNING! COULD NOT FIND COLLISION")
				goto continue
			end 
			newNode.comp.position.x = c.x
			newNode.comp.position.y = c.y
			local newNodePos = util.v3(newNode.comp.position)
			
			trace("upgrade to double track, found road, replacing ", edgeToReplace)
			local newRoad = util.copyExistingEdge(edgeToReplace)
			newRoad.entity = nextEdgeId()
			if newRoad.comp.node0 == node then 
				newRoad.comp.node0 = newNode.entity
				--setTangentPreservingMagnitude(newRoad.comp.tangent0, nodePos-newNodePos)
				setTangentPreservingMagnitude(newRoad.comp.tangent1, util.v3(newRoad.comp.tangent1), vec3.length(nodePos-newNodePos))	
				 setTangentPreservingMagnitude(newRoad.comp.tangent0, newNodePos-nodePos, vec3.length(nodePos-newNodePos))
				--setTangent(newRoad.comp.tangent1, nodePos-newNodePos)
			else 
				assert(newRoad.comp.node1==node)
				newRoad.comp.node1=newNode.entity 
				--setTangent(newRoad.comp.tangent0, newNodePos-nodePos)
--				 setTangentPreservingMagnitude(newRoad.comp.tangent1, newNodePos-nodePos)
				setTangentPreservingMagnitude(newRoad.comp.tangent0, util.v3(newRoad.comp.tangent0), vec3.length(nodePos-newNodePos))	
				 setTangentPreservingMagnitude(newRoad.comp.tangent1, nodePos-newNodePos, vec3.length(nodePos-newNodePos))
			end
			
			
			table.insert(edgesToAdd, newRoad)
			trace("Removing road edge",edgeToReplace,"replaced with",newRoad.entity)
			table.insert(edgesToRemove, edgeToReplace)
			replacedEdgesMap[edgeToReplace]=newRoad
			if otherEdge then 
			
				table.insert(edgesToRemove, otherEdge)
				alreadySeenCollissionEdges[edgeToReplace]=true
				alreadySeenCollissionEdges[otherEdge]=true
				
				local otherNewRoad = util.copyExistingEdge(otherEdge)
				otherNewRoad.entity = nextEdgeId()
				if otherNewRoad.comp.node0 == node then   
	--				 setTangentPreservingMagnitude(otherNewRoad.comp.tangent0, newNodePos-nodePos)
					setTangentPreservingMagnitude(otherNewRoad.comp.tangent0, nodePos-newNodePos) 				 
				else 
					assert(otherNewRoad.comp.node1==node) 
					--setTangentPreservingMagnitude(otherNewRoad.comp.tangent1, nodePos-newNodePos)
					setTangentPreservingMagnitude(otherNewRoad.comp.tangent1, newNodePos-nodePos)
				end
				trace("Removing road edge",otherEdge, "replaced with",otherNewRoad.entity)
				table.insert(edgesToAdd, otherNewRoad)
				replacedEdgesMap[otherEdge]=otherNewRoad
			end
			
			local crossingGap  = util.copyExistingEdge(edgeToReplace)
			crossingGap.entity = nextEdgeId()
			crossingGap.comp.node0 = newNode.entity
			crossingGap.comp.node1 = node
			setTangent(crossingGap.comp.tangent0, nodePos-newNodePos)
			setTangent(crossingGap.comp.tangent1, nodePos-newNodePos)
			trace("Added edge for crossing gap with entity",crossingGap.entity)
			table.insert(edgesToAdd, crossingGap)
			if  isAddSignals(indexFromStart) then
				 suppressSignals = true -- need to offset the signals to avoid colliding with the crossing
			end			
		else 
			if params.ignoreAllOtherSegments then 
				goto continue 
			end
			local newNodePos = util.v3(newNode.comp.position)
			local otherNode = util.searchForNearestNode(newNodePos, 30,
					function(n) 
						return n.id ~=node and vec2.distance(newNodePos, util.v3fromArr(n.position))<vec2.distance(nodePos, util.v3fromArr(n.position))
				end) -- closer to us 
			
			local collisionEdge 
			local nearbyEdges = util.searchForEntities(newNodePos, 50, "BASE_EDGE")
			if params.collisionEntities then 
			
				for __ , edge in pairs(nearbyEdges) do
					if params.collisionEntities[edge.id] then 
						collisionEdge = edge 
						break
					end
				end
			end
			if otherNode or collisionEdge then 
				local prevNodePos = lastNewNode and util.v3(lastNewNode.comp.position) or util.nodePos(lastNode)
				local needsResolution = false
				if otherNode then 
					local testBuild =  trialBuildBetweenPoints(newNodePos, prevNodePos)
					if testBuild.isError and not movedNodes[otherNode.id] then
						local possibleEdges = {} 
						for i , edge in pairs(nearbyEdges) do 
							if not edge.track then 
								possibleEdges[edge.id]=true 
							end
						end
						local foundEdge = false 
						for i, entity in pairs(testBuild.collisionEntities) do 
							trace("Found a collision with entity ",entity.entity, " was edge?",possibleEdges[entity.entity])
							if possibleEdges[entity.entity] then 
								foundEdge = true 
								break 
							end 
						end 
						needsResolution = collisionEdge or foundEdge
					end
				else 
					if vec2.distance(newNodePos, util.v3fromArr(collisionEdge.node0pos)) < vec2.distance(newNodePos, util.v3fromArr(collisionEdge.node1pos)) then 
						otherNode = util.getEntity(collisionEdge.node0)
					else 
						otherNode = util.getEntity(collisionEdge.node1)
					end
					needsResolution = true
				end
				if needsResolution and not movedNodes[otherNode.id] then
					movedNodes[otherNode.id]=true
					trace("detected possible problem on edge near ",newNodePos.x, newNodePos.y)
					local segs = util.getSegmentsForNode(otherNode.id)
					local edgeId = segs[1]
					local edge = util.getEdge(edgeId) 
					local theirTangent = edge.node0 == otherNode.id and util.v3(edge.tangent0) or util.v3(edge.tangent1)
					local otherNodePos = util.v3fromArr(otherNode.position)
					local tangentSign = 1
					local testNodePos = otherNodePos +tangentSign* params.trackWidth*vec3.normalize(theirTangent)
					if vec2.distance(newNodePos, testNodePos) < vec2.distance(otherNodePos, newNodePos) or 
					vec2.distance(nodePos, testNodePos) < vec2.distance(nodePos, otherNodePos) then 
						trace("Changing the tangent sign to negative")
						tangentSign = -1
					end
					local crossingAngle = math.abs(util.signedAngle(theirTangent, tangent))
					if crossingAngle > math.rad(90) then 
						crossingAngle = math.rad(180)-crossingAngle
					end
					local clearanceNeeded = params.trackWidth + params.trackWidth / math.tan(crossingAngle)
					clearanceNeeded = math.min(clearanceNeeded, 2*params.trackWidth + 2*util.getEdgeWidth(edgeId)) -- prevent this blowing up for small angles
					assert(clearanceNeeded>0)
					trace("calculated clearanceNeeded as ",clearanceNeeded, " crossing angle was ", math.deg(crossingAngle), " edge=",edgeId)
					local theirNodeOffset = tangentSign*clearanceNeeded*vec3.normalize(theirTangent)
					local theirNewNodePos = otherNodePos + theirNodeOffset
					local theirNewNode = newNodeWithPosition(theirNewNodePos, getNextNodeId())
					local canReplace = math.abs(crossingAngle) < math.rad(160) and math.abs(crossingAngle) > math.rad(20)-- gives odd results for shallow angles
					if #util.getSegmentsForNode(otherNode.id) > 3 then 
						canReplace = false 
					end
					if #util.getTrackSegmentsForNode(otherNode.id) > 2 then 
						canReplace = false 
					end
					if math.abs(util.nodePos(otherNode.id).z-newNodePos.z) < 6 then 
						canReplace = false 
					end
					for i , seg in pairs(segs) do
						if alreadySeenCollissionEdges[seg] then
							canReplace =false
							break
						end
						if routeEdges[seg] then 
							canReplace = false 
							break 
						end
						if removedEdges[seg] then 
							canReplace = false 
							break 
						end
						if util.isFrozenEdge(seg) then 
							canReplace = false 
							break 
						end
						if util.getEdgeLength(seg) < (clearanceNeeded + 4) then 
							trace("Calculated seg is too short to move")
							canReplace = false 
							break 
						end
						local edge = util.getEdge(seg) 
						if #util.getStreetSegmentsForNode(edge.node0) > 0 
							and  #util.getTrackSegmentsForNode(edge.node0) > 0
							or 
							#util.getStreetSegmentsForNode(edge.node1) > 0 
							and  #util.getTrackSegmentsForNode(edge.node1) > 0
							then 
								trace("found an edge with both track and road connections at ",seg," unable to replace")
								canReplace = false
								break
						end
						local doubleTrackEdge = util.findDoubleTrackEdge(seg)
						if doubleTrackEdge and routeEdges[doubleTrackEdge] then 
							canReplace = false 
							break 
						end 
						for __, node in pairs({edge.node0, edge.node1}) do 
							local doubleTrackNode = util.findDoubleTrackNode(node) 
							if doubleTrackNode and routeNodes[doubleTrackNode] then 
								canReplace = false 
								break 
							end
							local nextEdge = util.findNextEdgeInSameDirection(seg, node)
							if nextEdge then 
								 doubleTrackEdge = util.findDoubleTrackEdge(nextEdge)
								 if doubleTrackEdge and routeEdges[doubleTrackEdge] then 
									canReplace = false 
									break 
								end
								for __, node in pairs({util.getEdge(nextEdge).node0, util.getEdge(nextEdge).node1}) do 
									local doubleTrackNode = util.findDoubleTrackNode(node) 
									if doubleTrackNode and routeNodes[doubleTrackNode] then 
										canReplace = false 
										break 
									end
								end
							end 
						end 
							
					end
					if canReplace then 
						addNode( theirNewNode)
						for i, seg in pairs(segs) do 
							if not removedEdges[seg] then 
								trace("Relacing node on ",seg," with position ",theirNewNodePos.x, theirNewNodePos.y)
								local replacement = getOrMakeReplacedEdge(seg)
								local edge = util.getEdge(seg)
								 
								local newLength
								if replacement.comp.node0 == otherNode.id then 
									replacement.comp.node0 = theirNewNode.entity 
									
									newLength = util.distance(theirNewNodePos ,util.nodePos(edge.node1))
								else 
									replacement.comp.node1 = theirNewNode.entity 
									newLength = util.distance(theirNewNodePos ,util.nodePos(edge.node0))
								end
								setTangent(replacement.comp.tangent0, newLength * vec3.normalize(util.v3(replacement.comp.tangent0)))
								setTangent(replacement.comp.tangent1, newLength * vec3.normalize(util.v3(replacement.comp.tangent1)))
							end
						end
						local doubleTrackNode = util.findDoubleTrackNode(otherNode.id) 
						if doubleTrackNode then 
							trace("Found double track node",doubleTrackNode)
							if not movedNodes[doubleTrackNode] then
								movedNodes[doubleTrackNode]=true
								local theirNewNodePos = util.nodePos(doubleTrackNode)+theirNodeOffset
								local theirNewNode = newNodeWithPosition(theirNewNodePos, getNextNodeId())
								addNode( theirNewNode)
								local segs = util.deepClone(util.getSegmentsForNode(doubleTrackNode))
								local canReplace = true 
								for i, seg in pairs(segs) do 
									if removedEdges[seg] then 
										canReplace = false 
										break 
									end 
								end 
								if canReplace then 
									for i, seg in pairs(segs) do 
										if not removedEdges[seg] then 
										trace("Relacing node ",doubleTrackNode," on ",seg," with position ",theirNewNodePos.x, theirNewNodePos.y)
											local replacement = getOrMakeReplacedEdge(seg)
											local edge = util.getEdge(seg)
											 
											local newLength
											if replacement.comp.node0 == doubleTrackNode then 
												replacement.comp.node0 = theirNewNode.entity 
												
												newLength = util.distance(theirNewNodePos ,util.nodePos(edge.node1))
											else 
												replacement.comp.node1 = theirNewNode.entity 
												newLength = util.distance(theirNewNodePos ,util.nodePos(edge.node0))
											end
											setTangent(replacement.comp.tangent0, newLength * vec3.normalize(util.v3(replacement.comp.tangent0)))
											setTangent(replacement.comp.tangent1, newLength * vec3.normalize(util.v3(replacement.comp.tangent1)))
										end
									end
								end
							end
						end
					else 
						trace("Suppressing replacement as the edge was already seen")
					end
				end
			end
		end
		::continue::
		
		if isAddSignals(indexFromStart) then
			if suppressSignals or crossOverThisSeg then
				addSignalNextSegment=true
			else
				trace("adding signals at i=",i,"indexFromStart=",indexFromStart)
				
				local entity2 =  getOrMakeReplacedEdge(edgeAndId.id)  
				local leftEntity = backwards and entity or entity2
				local rightEntity = backwards and entity2 or entity
				--local invertSignals = backwards ~= (sign<0)
--				local invertSignals = backwards
				--local invertSignals = backwards == (sign>0)
				local invertSignals = (sign>0)
				trace("setting signals, invertSignals=",invertSignals," backwards=",backwards," sign=",sign)
				buildSignals(edgeObjectsToAdd, indexFromStart, nodecount, entity, entity2,invertSignals, params.simplifiedSignalling)
				addSignalNextSegment = false
				lastSignalIndex = indexFromStart
			end
		end
		lastLastNode = lastNode
		lastNode = newNode.entity
		lastNewNode = newNode
		lastOriginalNode = node
		  --if i > routeInfo.firstFreeEdge+5 then break end
		
	end
	local lastEntity = util.copyExistingEdge(routeInfo.edges[routeInfo.lastFreeEdge].id)
	lastEntity.entity = nextEdgeId()
	local penultimateNode
	local finalNode
	local finalTangent
	if backwards then
		penultimateNode = lastEntity.comp.node1
		lastEntity.comp.node1=lastNode
		finalNode = lastEntity.comp.node0
		finalTangent = util.v3(lastEntity.comp.tangent0)
	else 
		penultimateNode = lastEntity.comp.node0
		lastEntity.comp.node0=lastNode
		finalNode = lastEntity.comp.node1
		finalTangent = util.v3(lastEntity.comp.tangent1)
	end
	trace("tryUpgradeToDoubleTrack: Created last entity with",lastEntity.entity)
	table.insert(edgesToAdd, lastEntity)
	 
	if routeInfo.lastUnconnectedTerminalNode then
		if not api.engine.entityExists(routeInfo.lastUnconnectedTerminalNode) or not util.getNode(routeInfo.lastUnconnectedTerminalNode) then 
			local alternative = util.findDoubleTrackNode(finalNode)
			trace("WARNING!, unable to find",routeInfo.lastUnconnectedTerminalNode," attempting to correct with ",alternative)
			routeInfo.lastUnconnectedTerminalNode= alternative
		end 
	end
	if routeInfo.lastUnconnectedTerminalNode then
		local nodePos = util.nodePos(finalNode)
		local trialNodePos = util.doubleTrackNodePoint(nodePos, sign*finalTangent)
		local distance = util.distance(util.nodePos(routeInfo.lastUnconnectedTerminalNode), trialNodePos)
		trace("dist between trial nodePos and lastUnconnectedTerminalNode=",distance)
		local threshold = params.useDoubleTerminals and not params.isTerminus2 and 2.5*params.trackWidth or 1.5*params.trackWidth
		if distance > threshold then
			local lastEdgeId = routeInfo.edges[routeInfo.lastFreeEdge].id
			local entity = util.copyExistingEdge(lastEdgeId, nextEdgeId())
			if entity.comp.node0 == finalNode then 
				entity.comp.node0 = routeInfo.lastUnconnectedTerminalNode
			else 
				assert(entity.comp.node1 == finalNode)
				entity.comp.node1 = routeInfo.lastUnconnectedTerminalNode
			end
			table.insert(edgesToAdd, entity)
			trace("Removing last edgeId",lastEdgeId,"replaced with",entity.entity)
			removedEdges[lastEdgeId]=true
			table.insert(edgesToRemove, lastEdgeId)
		else 
			if backwards then
				lastEntity.comp.node0=routeInfo.lastUnconnectedTerminalNode
			else 
				lastEntity.comp.node1=routeInfo.lastUnconnectedTerminalNode
			end
		
		end
	end
	if params and params.useDoubleTerminals and not params.isTerminus2 then 
		local finalNode = backwards and lastEntity.comp.node0 or lastEntity.comp.node1
		local otherNode = util.findDoubleTrackNode(finalNode)
		if otherNode then 
			local entity2 = util.copySegmentAndEntity(lastEntity, nextEdgeId())
			if backwards then 
				entity2.comp.node0 = otherNode 
			else
				entity2.comp.node1 = otherNode 
			end
			table.insert(edgesToAdd, entity2)
		--	local dist = util.distance(util.nodePos(otherNode),newNode.comp.position)
			if util.tracelog then trace("tryUpgradeToDoubleTrack: Created edge  at end for useDoubleTerminals:",newEdgeToString(entity2),"entity2.entity=",entity2) end

		else 
			trace("WARNING! Unable to find double track node for",finalNode)
		end 
	end
	
	trace("penultimateNode was",penultimateNode)
 
	local connectedEdges = util.deepClone(util.getTrackSegmentsForNode(penultimateNode))
	if #connectedEdges == 3  and not reconnectDepotAfter and not params.useDoubleTerminals then
		local depotEdgeId = findDepotEdge(connectedEdges, routeInfo, routeInfo.lastFreeEdge, penultimateNode, routeEdges)
		trace("found a depot at the end, ",depotEdgeId)
		local depotEdge = util.getEdge(depotEdgeId)
		local depotNode = depotEdge.node0 == penultimateNode and depotEdge.node1 or depotEdge.node0
		local distanceToExistingNode = util.distBetweenNodes(depotNode, penultimateNode)
		local distanceToOurNode = util.distance(util.nodePos(depotNode), util.v3(lastNewNode.comp.position))
		trace("distanceToOurNode=",distanceToOurNode," distanceToExistingNode=",distanceToExistingNode)
		if distanceToOurNode < distanceToExistingNode then -- may need to revist, difference only in tangential angle
			
			removedEdges[depotEdgeId]=true
			table.insert(edgesToRemove, depotEdgeId)
			local depotEntity = util.copyExistingEdge(depotEdgeId)
			depotEntity.entity = nextEdgeId()
			if depotEntity.comp.node1 == penultimateNode then 
				depotEntity.comp.node1 = lastNode
			else 
				depotEntity.comp.node0 = lastNode
			end
			trace("replacing depot connection as it was close, ",distanceToOurNode," vs ",distanceToExistingNode,"depotEntity=",depotEntity.entity)
			table.insert(edgesToAdd, depotEntity)
			
		end
	end
	local newNodeToSegmentMap = {}
	for i, newEdge in pairs(edgesToAdd) do 
		for j, node in pairs({newEdge.comp.node0, newEdge.comp.node1}) do 
			if not newNodeToSegmentMap[node] then 
				newNodeToSegmentMap[node] = {}
			end 
			table.insert(newNodeToSegmentMap[node], newEdge.entity)
		end 
	end
	
	for node, segs in pairs(newNodeToSegmentMap) do 
		if node > 0 then 
			for i, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if not removedEdges[seg] then 
					table.insert(segs, seg) 
				end
			end 
		end 
		if #segs == 1 then 
			trace("WARNING! Discovered dead end seg for node",node, " attempting to correct") 
		end
	end 
	
	
	local newProposal 
	if not xpcall(function() newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)end, err) then 
		trace("There was an error, aborting")
		params.ignoreGradeCrossings=true
		return false
	end 
	
	--debugPrint(newProposal)
	trace("About to build command  to upgrade track, callback")
	local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	--[[if testData.costs > util.getAvailableBalance() and not params.ignoreCosts then 
		trace("Aborting build for upgrade track as costs ",testData.costs," exceeds available budget",util.getAvailableBalance())
		callback({reason = "Not enough money" , costs= testData.costs}, false)
		return true -- need to return true here to cause the caller to abort
	end]]--
	if testData.errorState.critical then
		if util.tracelog then 
			--debugPrint(newProposal)
			--debugPrint(testData)
			local diagnose = true 
			routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
		end
		trace("Critical error seen in the test data")
		if not params.forceRemoveDepotTrack then 
			params.forceRemoveDepotTrack = true 
			return false 
		end
		if params.ignoreErrors then 
			if not params.simplifiedSignalling then 
				trace("setting ignore grade crossings")
				params.simplifiedSignalling=true
				return false 
			end 
			if not params.ignoreGradeCrossings then 
				trace("setting ignore grade crossings")
				params.ignoreGradeCrossings=true
				return false 
			end 
			if not params.ignoreAllOtherSegments then 
				trace("setting ignoreAllOtherSegments")
				params.ignoreAllOtherSegments = true
			elseif util.tracelog then 
				debugPrint({newProposal=newProposal})
			end
		end 
		if util.tracelog then
			--routeBuilder.setupProposalAndDeconflict(cloneNodesToLua(nodesToAdd),cloneEdgesToLua(edgesToAdd), edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, true)
		end
		return false 
	elseif #testData.errorState.messages > 0 then
		if util.tracelog and #edgesToAdd < 200 then 
			--debugPrint(testData.collisionInfo.collisionEntities)
			--debugPrint(testData.errorState)
		end
		for i , e in pairs(testData.collisionInfo.collisionEntities) do
			if not params.collisionEntities then 
				params.collisionEntities = {}
			end
			if not params.collisionEntities[e.entity] then 
				params.collisionEntities[e.entity]=true
			end
		end
			
		trace("Ignorable error seen in the test data")
		if not params.ignoreErrors then
			return false
		end
	else 
		trace("Test data was created without error")
	end 
	
	--local debugInfo =
	if params.reconnectDepotAfter then 
		depotPos = params.depotPos
		reconnectDepotAfter = true 
	end
--	 debugPrint({ collisionInfo = debugInfo.collisionInfo , errorState = debugInfo.errorState})
	if util.tracelog then 
		debugPrint(newProposal)
	end 
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), params.ignoreErrors)
	trace("About to sent command to upgrade track, callback was ",callback)
	--if tracelog then debugPrint(build) end
	
	local wrappedCallback = function(res, success) 
		if success then
			util.clearCacheNode2SegMaps()
			if addSignalNextSegment and routeInfo.station2 and routeInfo.station1 then 
				trace("Discovered requirement to add signals, attempting")
				routeBuilder.addWork(function() 
					util.lazyCacheNode2SegMaps()
					local oppositeDirectionRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station2, routeInfo.station1)
					buildStartingSignals(oppositeDirectionRouteInfo)
				end)
			end
			routeBuilder.addWork(function()
				for _, vehicleId in pairs(api.engine.system.transportVehicleSystem.getNoPathVehicles()) do
					api.cmd.sendCommand(api.cmd.make.reverseVehicle(vehicleId))
				end
				routeBuilder.standardCallback(nil, true)
			end)
			if reconnectDepotAfter then 
				routeBuilder.addWork(function()
					routeBuilder.reconnectDepotAfter(depotPos, params)
				end)
			end
		end
		if util.tracelog then 
			--game.interface.setGameSpeed(0)
		end 
		callback(res, success)
	end
	util.clearCacheNode2SegMaps() 
	api.cmd.sendCommand(build, wrappedCallback)
	local endTime = os.clock()
	trace("End of route upgrade, time taken=",(endTime-startTime))
	return true
end

function routeBuilder.reconnectDepotAfter(depotPos, params)
	local depot
	for i, construction in pairs(util.searchForEntities(depotPos, 400 , "CONSTRUCTION")) do
		if string.find(construction.fileName, "depot/train") then 
			depot = construction.id
			break
		end
	end
	trace("Attempting to reconnect depot for ", depot)
	routeBuilder.buildDepotConnection(function(res, success)
		if util.tacelog then 
			--game.interface.setGameSpeed(0) 
		end 
		routeBuilder.standardCallback(res, success)
	end, depot, params)
end 
function routeBuilder.fixReversals(routeInfo, callback, params)
	local edgesToAdd = {}
	local edgesToRemove = {}
	
	local isPredominantlyBackwards = routeInfo.isPredominantlyBackwards()
	local isBackwardsEdgeData = routeInfo.getBackwardsEdgeData()
	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		if isBackwardsEdgeData[i]~=isPredominantlyBackwards then 
			local edgeId = routeInfo.edges[i].id 
			table.insert(edgesToRemove, edgeId)
			local newEntity = util.copyExistingEdge(edgeId, -1-#edgesToAdd)
			util.reverseNewEntity(newEntity)
			table.insert(edgesToAdd, newEntity)
		end
	end 
	
	local newProposal = api.type.SimpleProposal.new()
	for i, edge in pairs(edgesToAdd) do 	
		newProposal.streetProposal.edgesToAdd[i]=edge
	end 
	for i, edge in pairs(edgesToRemove) do 	
		newProposal.streetProposal.edgesToRemove[i]=edge
	end 
	local context = util.initContext()
	context.player = -1 -- do not charge the player
	local build = api.cmd.make.buildProposal(newProposal, context, true)
	api.cmd.sendCommand(build, callback)
end
function routeBuilder.upgradeToDoubleTrack(routeInfo, callback, params, alreadyCalled)
	util.lazyCacheNode2SegMaps()
	trace("routeBuilder.upgradeToDoubleTrack:begin")
	if routeInfo.isMainLineHasReversals() and not alreadyCalled and routeInfo.station1 and routeInfo.station2 then -- NB this does not work properly without station
		trace("Discovered that mainline has reversals, fixing first")
		assert(not alreadyCalled) -- just to prevent infinite recursion
		local function callbackThis(res, success)
			trace("result of fix reversals was",success)
			if success then 
				util.clearCacheNode2SegMaps()
				routeBuilder.addWork(function()
					local newRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station1, routeInfo.station2)
				--[[	if routeInfo.station1 and routeInfo.station2 then 
						newRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station1, routeInfo.station2)
					else 
					--	newRouteInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdges(routeInfo.edges[1].id, routeInfo.edges[#routeInfo.edges].id ))
					end ]]--
					
					routeBuilder.upgradeToDoubleTrack(newRouteInfo, callback, params, true)
				end)
			end
		end
		routeBuilder.fixReversals(routeInfo, callbackThis, params)
		return 
	end
	
	if not params then 
		params = paramHelper.getDefaultRouteBuildingParams()
	end
	if params.isCargo and not params.keepUnconnectedTerminalNodes then 
		routeInfo.lastUnconnectedTerminalNode = nil 
		routeInfo.firstUnconnectedTerminalNode = nil
	end 
	params.forceRightHanded = false
	params.forceLeftHanded = false
	
	if not routeInfo.firstFreeEdge then 
		trace("Unable to upgrade no firstFreeEdge")
		if util.tracelog then debugPrint({routeInfo=routeInfo}) end 
		callback({}, true)
		return 
	end
	local success =  tryUpgradeToDoubleTrack(routeInfo, callback, params) 
	local attemptCount = 0
	params.forceLeftHanded =true 
	while not success and attemptCount < 10 do 
		trace("Attempting to upgrade to double track for the ",attemptCount," time")
		params.forceRightHanded = not params.forceRightHanded
		params.forceLeftHanded = not params.forceLeftHanded
		if attemptCount == 5 or attemptCount >= 6 then 
			params.forceRightHanded = false
			params.forceLeftHanded = false
		end 
		if attemptCount == 6 and not params.ignoreErrors then 
			trace("Setting ignoreErrors to true")
			params.ignoreErrors = true
		end
		if attemptCount > 2 then 
			params.forceRemoveDepotTrack = true
		end 
		success =  tryUpgradeToDoubleTrack(routeInfo, callback, params)
		if attemptCount == 6 then 
			params.forceLeftHanded = true
		end
		attemptCount = attemptCount + 1 
	end 
	if not success then 	
		callback({}, false)
		if util.tracelog then 
			error("Unable to upgrade to double track")
		end
	end
	util.clearCacheNode2SegMaps() 
end
local function connectTerminalNode(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo, index, unconnectedTerminalNode, params, terminalGap, nextNodeId, edgeObjectsToAdd, constructionsToRemove)
	local maxTrackOffsets = 2
	local otherTerminalNode = util.findDoubleTrackNode(unconnectedTerminalNode)
	if not otherTerminalNode then 
		otherTerminalNode = util.findDoubleTrackNode(unconnectedTerminalNode, nil, maxTrackOffsets)
		trace("Could not find otherTerminal node attempting at next trackOffset",maxTrackOffsets)
	end
	local halfway = (routeInfo.lastFreeEdge+routeInfo.firstFreeEdge) / 2
	local isHigh = index > halfway
	local boundryIndex = isHigh and routeInfo.lastFreeEdge or routeInfo.firstFreeEdge
	trace("The otherTerminalNode was",otherTerminalNode, " the terminalGap was ",terminalGap)
	if otherTerminalNode then 
		local edge = routeInfo.edges[boundryIndex].edge
		local distBetweenNodes = math.min( util.distBetweenNodes(edge.node0, unconnectedTerminalNode), util.distBetweenNodes(edge.node1, unconnectedTerminalNode))
		trace("The distBetweenNodes was ",distBetweenNodes)
		if distBetweenNodes < 11 then 
			terminalGap = 1
			index  = boundryIndex
			 
		end
		if #util.getSegmentsForNode(edge.node0) < 3 and #util.getSegmentsForNode(edge.node1) < 3 then 
			trace("WARNING!, edge only has one connection, aborting ",routeInfo.edges[boundryIndex].id," nodes were",edge.node0,edge.node1) 
			return
		end
	end
	local edgeAndId = routeInfo.edges[index]
	if terminalGap <= 1 then 
			
		if edgeAndId.edge.node0 ~= otherTerminalNode and edgeAndId.edge.node1~=otherTerminalNode and terminalGap <=0 then
			otherTerminalNode = util.findDoubleTrackNode(unconnectedTerminalNode, nil, maxTrackOffsets)
		end 
		if not (edgeAndId.edge.node0 == otherTerminalNode or edgeAndId.edge.node1==otherTerminalNode) then 
			trace("The selected double track node otherTerminalNode="..otherTerminalNode.." not in "..edgeAndId.edge.node0.." or "..edgeAndId.edge.node1)
			local nodes = { [edgeAndId.edge.node0]=true, [edgeAndId.edge.node1]=true }
			otherTerminalNode = util.findDoubleTrackNodeWithinSet(unconnectedTerminalNode, nodes, maxTrackOffsets)
			if not otherTerminalNode then 
				trace("WARNING! Unable to find the otherTerminalNode within the routeInfo, aborting")
				return
			end
		end
		assert(edgeAndId.edge.node0 == otherTerminalNode or edgeAndId.edge.node1==otherTerminalNode, "otherTerminalNode="..otherTerminalNode.." not in "..edgeAndId.edge.node0.." or "..edgeAndId.edge.node1)
		local nextNode = edgeAndId.edge.node0 == otherTerminalNode and  edgeAndId.edge.node1 or edgeAndId.edge.node0 
		local foundDoubleSlipSwitch = false 
		if util.getComponent(nextNode, api.type.ComponentType.BASE_NODE).doubleSlipSwitch or not util.findDoubleTrackNode(nextNode) then 
			local nextEdgeId = util.findNextEdgeInSameDirection(edgeAndId.id, nextNode)
		
			local nextEdge = util.getEdge(nextEdgeId)
			trace("Found doubleSlipSwitch, at ",nextNode," attempting to find node from edge",nextEdgeId)
			nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
			foundDoubleSlipSwitch = true
		end
		trace("Attempting to find next node from ",nextNode)
		local oppositeDirectionRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station2, routeInfo.station1)
		local nextNode2 = oppositeDirectionRouteInfo and oppositeDirectionRouteInfo.closestFreeNode(util.nodePos(nextNode)) or util.findDoubleTrackNode(nextNode)
		if foundDoubleSlipSwitch then -- can't use route info because it sometimes paths through the slipswitch 
			nextNode2 = util.findDoubleTrackNode(nextNode) or nextNode2
		end 

		if nextNode2 == nextNode then
			nextNode2 = util.findDoubleTrackNode(nextNode) -- can happen when pathfinding goes through the double slipswitch 
			trace("nextNode2 was the same as nextNode", nextNode, "attempting to correct to",nextNode2)
		end 

		if not nextNode2 then
			trace("WARNING! nextNode2 not found",nextNode2)
			if util.tracelog then 
				error("nextNode2 not found")
			end
			return 
		end	
		

		trace("Connect terminal nodes: inspecting the four nodes",otherTerminalNode, unconnectedTerminalNode, nextNode,nextNode2)
		local terminalVec = util.vecBetweenNodes(otherTerminalNode, unconnectedTerminalNode)
		local exitVec = util.vecBetweenNodes(nextNode, nextNode2)
		local connectEdgeId = util.findEdgeConnectingNodes(nextNode, otherTerminalNode)
		local angle = math.abs(util.signedAngle(terminalVec, exitVec))
		local useNextNode1 = angle > math.rad(90)
		trace("the angle between the terminalVec and exitVec was ",math.deg(angle),"useNextNode1?",useNextNode1,"found connectEdgeId?",connectEdgeId)
	
		if connectEdgeId then 
			local connectEdge = util.getEdge(connectEdgeId)
			local isNode0 = connectEdge.node0 == otherTerminalNode
			local angle1 = util.signedAngle(terminalVec, isNode0 and connectEdge.tangent0 or connectEdge.tangent1)
			local angle2 = util.signedAngle(exitVec, isNode0 and connectEdge.tangent1 or connectEdge.tangent0)
			local angle1Negative = angle1 < 0 -- expect +/- 90 degrees 
			local angle2Negative = angle2 < 0		
			useNextNode1 = angle1Negative ~= angle2Negative
			trace("ConnectterminalNodes the two angles were",math.deg(angle1),math.deg(angle2),"useNextNode1?",useNextNode1)
		end
		local connectNode 
		
		if useNextNode1 then
			connectNode = nextNode
		else 
			connectNode = nextNode2
		end
		local edgesToReplace = {}
		local edgeToRemove = util.findEdgeConnectingNodes(connectNode, otherTerminalNode) 
		
		if not edgeToRemove then 
			local function getMidNode() 
				for i, seg in pairs(util.getTrackSegmentsForNode(connectNode)) do 
					local edge = util.getEdge(seg) 
					for j, node in pairs({ edge.node0, edge.node1 }) do 
						for k, seg2 in pairs(util.getTrackSegmentsForNode(otherTerminalNode)) do 
							local edge2 = util.getEdge(seg2) 
							for m, node2 in pairs({edge2.node0, edge2.node1}) do 
								if node == node2 then 
									trace("Found midnode between ", connectNode, otherTerminalNode, " was ",node)
									return node 
								end
							end 
						end 
					end 
				end 
				trace("WARNING!, unable to find midnode between ", connectNode, otherTerminalNode)
			end
			local midNode = getMidNode() 
			if midNode then 
				local edgeToRemove = util.findEdgeConnectingNodes(midNode, otherTerminalNode) 
				trace("relacing edge ",edgeToRemove," swapping ",otherTerminalNode, " with ", unconnectedTerminalNode)
				table.insert(edgesToRemove, edgeToRemove)
				local newEdge = util.copyExistingEdgeReplacingNode(edgeToRemove, otherTerminalNode, unconnectedTerminalNode, -1-#edgesToAdd) 
				table.insert(edgesToAdd, newEdge)
			end 

		else 
			trace("relacing edge ",edgeToRemove," swapping ",otherTerminalNode, " with ", unconnectedTerminalNode)
			trace("found edgeToRemove = ", edgeToRemove, " connecting ",connectNode," with ",otherTerminalNode)
			table.insert(edgesToRemove, edgeToRemove)
			local newEdge = util.copyExistingEdgeReplacingNode(edgeToRemove, otherTerminalNode, unconnectedTerminalNode, -1-#edgesToAdd) 
			table.insert(edgesToAdd, newEdge)
		end
		return 
	end 
	if not api.engine.entityExists(edgeAndId.id) or not util.getEdge(edgeAndId.id) then
		trace("WARNING! Edge",edgeAndId.id," was not a valid edge")
		if util.tracelog then 
			error("invalid entity provided")
		end 
		return 
	end
	local newEdgeTemplate = util.copyExistingEdge(edgeAndId.id, -1-#edgesToAdd)
	local segs = util.getTrackSegmentsForNode(otherTerminalNode)
	local edgeToFollow = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
	trace("Got edgeToFollow",edgeToFollow,"copied newEdgeTemplate",newEdgeTemplate.entity,"from",edgeAndId.id)
	if edgeToFollow then
		local railDepotId =  routeBuilder.constructionUtil.searchForRailDepot(util.nodePos(unconnectedTerminalNode), 100)
		if railDepotId then -- too difficult to keep a rail depot connected with this setup 
			trace("Found railDepot with id",railDepotId)
			table.insert(constructionsToRemove, railDepotId)
			local railDepot = util.getConstruction(railDepotId)
			local limit =5 
			local count = 0
			local nextEdgeId = railDepot.frozenEdges[1]
			local nextNode = util.getEdge(nextEdgeId).node1
			local nextSegs = util.getTrackSegmentsForNode(nextNode)
			
			repeat
				nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
				if not nextEdgeId then 
					break 
				end
				if nextEdgeId == edgeToFollow then 
					trace("WARNING! Found edge to follow in the ndoes")
					break
				end 
				table.insert(edgesToRemove, nextEdgeId) 
				local nextEdge = util.getEdge(nextEdgeId)
				nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node1 
				nextSegs = util.getTrackSegmentsForNode(nextNode)
			
				count = count+1 
			until #nextSegs == 3 or count == limit 
			
		end 
	
		local edgeToFollowFull= util.getEdge(edgeToFollow)
		util.setTangent(newEdgeTemplate.comp.tangent0, edgeToFollowFull.tangent0)
		util.setTangent(newEdgeTemplate.comp.tangent1, edgeToFollowFull.tangent1)
	
		
		newEdgeTemplate.comp.type=edgeToFollowFull.type
		newEdgeTemplate.comp.typeIndex = edgeToFollowFull.typeIndex
		newEdgeTemplate.comp.objects = {}
		local isNode0 = edgeToFollowFull.node0 == otherTerminalNode
		local perpSign = 1
		local tangent = isNode0 and util.v3(edgeToFollowFull.tangent0) or  util.v3(edgeToFollowFull.tangent1)
		local testP = util.doubleTrackNodePoint(util.nodePos(otherTerminalNode), tangent) 
		if util.distance(testP, util.nodePos(unconnectedTerminalNode)) > util.distance(util.nodePos(otherTerminalNode), util.nodePos(unconnectedTerminalNode)) then 
			perpSign = -1
		end
		local edgeToFollowNodePos = isNode0 and util.nodePos(edgeToFollowFull.node1) or util.nodePos(edgeToFollowFull.node0)
		local newNode
		local entryTangent 
		local startZ = util.th(util.nodePos(unconnectedTerminalNode))
		local endZ = edgeToFollowNodePos.z 
		
		local canGoUnder = startZ - endZ < 5 and (util.th(edgeToFollowNodePos) > 0 or endZ > 15)
		trace("Can go under=",canGoUnder)
		local zoffset = canGoUnder and -10 or 10
		local newNodePos
		local uncorrectedEntryTangent
		if isNode0 then 
			newEdgeTemplate.comp.node0 = unconnectedTerminalNode 
			newNodePos = util.nodePointPerpendicularOffset(edgeToFollowNodePos,perpSign* util.v3(edgeToFollowFull.tangent1), 1.5*params.trackWidth) 
			newEdgeTemplate.comp.tangent1.z = zoffset/2
			entryTangent = -1*util.v3(edgeToFollowFull.tangent1)
			uncorrectedEntryTangent = util.v3(edgeToFollowFull.tangent1)
		else 
			newEdgeTemplate.comp.node1 = unconnectedTerminalNode 
			newNodePos = util.nodePointPerpendicularOffset(edgeToFollowNodePos,perpSign* util.v3(edgeToFollowFull.tangent0), 1.5*params.trackWidth)
			newEdgeTemplate.comp.tangent0.z = -zoffset/2
			entryTangent =  util.v3(edgeToFollowFull.tangent0)
			uncorrectedEntryTangent = entryTangent
		end 
		local theirOtherNode = isNode0 and edgeToFollowFull.node1 or edgeToFollowFull.node0 
		local theirNextEdgeId = util.findNextEdgeInSameDirection(edgeToFollow, theirOtherNode)
		if #util.getTrackSegmentsForNode(theirOtherNode)==4 then 
			-- TODO: problem here ?
			trace("connectTerminalNode: found 4 segments at",theirOtherNode)
			for i, seg  in pairs(util.getTrackSegmentsForNode(theirOtherNode)) do 
				if seg ~= theirNextEdgeId and seg ~= edgeToFollow and not util.contains(edgesToRemove, seg) then 
					trace("connectTerminalNode: removing seg",seg,"edgeToFollow was",edgeToFollow)
					table.insert(edgesToRemove, seg)
				end
			end 
		end 
		 
		newNodePos.z = newNodePos.z + zoffset
		newNode = newNodeWithPosition(newNodePos, nextNodeId())
		table.insert(nodesToAdd, newNode)
		if isNode0 then 
			newEdgeTemplate.comp.node1 = newNode.entity
		else 
			newEdgeTemplate.comp.node0 = newNode.entity
		end
		
		table.insert(edgesToAdd, newEdgeTemplate)
		
		local startAt 
		local endAt 
		local keepNode
	
		local increment = isHigh and -1 or 1 
		local function edgeIsSuitable(edgeAndId) 
			local distToNode = util.distance(util.getEdgeMidPoint(routeInfo.edges[index].id), newNodePos)
			if distToNode < 90 then 
				return false 
			end 
			if util.calculateSegmentLengthFromEdge(edgeAndId.edge) < 70 then 
				return false 
			end
			if #util.getSegmentsForNode(edgeAndId.edge.node1) > 2 or  #util.getSegmentsForNode(edgeAndId.edge.node0) > 2 then 
				return false 
			end 
			return true
		end 
		
		while not edgeIsSuitable(routeInfo.edges[index] ) do
			index = index + increment
			trace("Edge was not suitable, trying next",index)
		end 
		
		
		
		if isHigh  then 
			 
			startAt = index 
			endAt = routeInfo.lastFreeEdge
			keepNode = routeInfo.edges[index].edge.node1 == routeInfo.edges[index-1].edge.node0 and routeInfo.edges[index].edge.node1 or routeInfo.edges[index].edge.node0
		else  
			startAt = routeInfo.firstFreeEdge
			endAt = index 
			keepNode = routeInfo.edges[index].edge.node1 == routeInfo.edges[index+1].edge.node0 and routeInfo.edges[index].edge.node1 or routeInfo.edges[index].edge.node0
		end
		local edgeToReplace = routeInfo.edges[index].id 
		local oppositeDirectionRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station2, routeInfo.station1)
		local doubleTrackNode = oppositeDirectionRouteInfo.closestFreeNode(util.nodePos(keepNode))
		
		local perpVec = util.vecBetweenNodes(doubleTrackNode, keepNode)
		local otherVec = util.vecBetweenNodes(unconnectedTerminalNode, otherTerminalNode)
		local isRightHanded = util.signedAngle(otherVec, util.getDeadEndNodeDetails(unconnectedTerminalNode).tangent) < 0
		local angle = util.signedAngle(perpVec, otherVec)
		local useDoubleTrackNode = math.abs(angle) < math.rad(90) 
		local intoStationRouteInfo = isHigh and routeInfo or oppositeDirectionRouteInfo
		local alternativeUseDoubleTrackNodeOld = isRightHanded ~=  intoStationRouteInfo.containsNode(keepNode)
		local alternativeUseDoubleTrackNode = isRightHanded ~=  isHigh
		trace("The angle between the perpVec and other vec was",math.deg(angle), " useDoubleTrackNode=",useDoubleTrackNode, " alternativeUseDoubleTrackNode=",alternativeUseDoubleTrackNode,"isRightHanded =",isRightHanded, " alternativeUseDoubleTrackNodeOld=",alternativeUseDoubleTrackNodeOld, " index=",index)
		if useDoubleTrackNode ~= alternativeUseDoubleTrackNode then 
			trace("WARNING! useDoubleTrackNode and alternativeUseDoubleTrackNode are in conflict")
		end
		--if math.abs(angle) > math.rad(135) or math.abs(angle)< math.rad(45) then 
			trace("Using alternativeUseDoubleTrackNode")
			useDoubleTrackNode = alternativeUseDoubleTrackNode
		--end
		
		-- TODO: Fix this ambiguous  
		local connectEdgeId = util.getTrackSegmentsForNode(keepNode)[1]
	
		local connectEdge = util.getEdge(connectEdgeId)
		local isNode0 = connectEdge.node0 == keepNode
		local comparisonTangent = isNode0 and connectEdge.tangent0 or connectEdge.tangent1 
		local isBackwards = routeInfo.getBackwardsEdgeData()[index]
		
		-- need to be in the same direction as the outbound route 
		-- isHigh - and not isBackwards > no 
		-- isBackwards and not isigh -- > yes 
		-- not isHigh and not isBackwards --> yes  
		-- not isHigh and isBackwards --> no 
		local shouldReverse = isBackwards == isHigh
	
		if shouldReverse then 
			comparisonTangent = -1*util.v3(comparisonTangent)
		end 
		
		local isRightHanded2 = util.signedAngle(perpVec, comparisonTangent) < 0
			
		-- this approach should always be unambiguous
		useDoubleTrackNode = isRightHanded ~= isRightHanded2
		trace("ConnectterminalNodes setting useDoubleTrackNode to",useDoubleTrackNode,"isRightHanded?",isRightHanded,"isRightHanded2",isRightHanded2,"isBackwards?",isBackwards,"isHigh",isHigh, "shouldReverse=",shouldReverse)
	
		
		local alreadySeenNodes = {}
		for i = startAt, endAt do 
			local edgeId = routeInfo.edges[i].id
			if useDoubleTrackNode then 
				local theirIndex = oppositeDirectionRouteInfo.getIndexOfClosestApproach(util.getEdgeMidPoint(edgeId))
				edgeId = oppositeDirectionRouteInfo.edges[theirIndex].id
				trace("TheirIndex was ",theirIndex," at ",i," for closet approach of edge",edgeId, "they had a total of ",#oppositeDirectionRouteInfo.edges,"edges")
			end
			trace("Removing edge",edgeId, " at i=",i )
			if not util.contains(edgesToRemove, edgeId) then 
				table.insert(edgesToRemove, edgeId)
			end
			local edge = util.getEdge(edgeId)
			for __, node in pairs({edge.node0, edge.node1}) do 
				if not alreadySeenNodes[node] then 
					alreadySeenNodes[node]=true 
					local edgeToKeep 
					local edgeToRemove 
					local replacementNode 
					local otherTangent 
					local isNode0 
					-- we are not allowed to leave a street segment in place for the gap between double track edges
					for __, seg in pairs(util.getStreetSegmentsForNode(node)) do 
						local edge = util.getEdge(seg) 
						isNode0 = node == edge.node0
						local otherNode =  isNode0 and edge.node1 or edge.node0 
						if #util.getTrackSegmentsForNode(otherNode) > 0 then 
							trace("Found another grade crossing")
							edgeToRemove = seg
							replacementNode = otherNode
							otherTangent = util.v3(otherNode == edge.node0 and edge.tangent0 or edge.tangent1)
						else 
							edgeToKeep = seg 
						end 
					end 
					if edgeToRemove then 
						table.insert(edgesToRemove, edgeToRemove)
						if edgeToKeep then 
							local replacementEdge = util.copyExistingEdge(edgeToKeep, -1-#edgesToAdd)
							if replacementEdge.comp.node0 == node then 
								replacementEdge.comp.node0 = replacementNode
								--util.setTangent(replacementEdge.comp.tangent0, isNode0 and -1*otherTangent or otherTangent)
							else 
								assert(replacementEdge.comp.node1 == node)
								replacementEdge.comp.node1 = replacementNode
								--util.setTangent(replacementEdge.comp.tangent1, isNode0 and otherTangent or -1*otherTangent)
							end 
						
							util.correctTangentLengths(replacementEdge)
							trace("Replacing edge for ",edgeToKeep," the node was",node," the replacementNode was",replacementNode)
							table.insert(edgesToRemove, edgeToKeep)
							table.insert(edgesToAdd, replacementEdge)
						end 
					end 
				end 
			end 
			-- Problem scenario - path through a double slip switch 
			if util.isSlipSwitchJoinEdge(edgeId) then --TODO possibly need to think about what happens when going out of the station
				trace("connectTerminalNode: discovered slipswitch join edge at ",edgeId,"attempting to compensate")
				local nodeToUse = #util.getTrackSegmentsForNode(edge.node0) == 3 and edge.node0 or edge.node1
				local segs = util.getTrackSegmentsForNode(nodeToUse)
				assert(#segs==3)
				local nextSeg 
				for j, seg in pairs(segs) do
					if seg ~= edgeId and not util.contains(edgesToRemove, seg) then 
						nextSeg = seg 
						break 
					end 
				end 
			
				repeat 
					trace("connectTerminalNode: removing nextSeg:",nextSeg,"after finding slipswitch join edge")
					assert(not util.isFrozenEdge(nextSeg))
					table.insert(edgesToRemove, nextSeg)
					local edge = util.getEdge(nextSeg)
					nodeToUse = nodeToUse == edge.node0 and edge.node1 or edge.node0 
					
					nextSeg = util.findNextEdgeInSameDirection(nextSeg, nodeToUse)
					
				until #util.getSegmentsForNode(nodeToUse) == 3 or util.isNodeConnectedToFrozenEdge(nodeToUse) or util.isFrozenEdge(nextSeg)
				break -- need to abort following routeinfo 				
			end 			
		end 
	
		if useDoubleTrackNode then 
			edgeToReplace = oppositeDirectionRouteInfo.edges[oppositeDirectionRouteInfo.getIndexOfClosestApproach(util.getEdgeMidPoint(edgeToReplace))].id
			keepNode = doubleTrackNode 
		end 
		local replacementEdge = util.copyExistingEdge(edgeToReplace, -1-#edgesToAdd)
		replacementEdge.comp.objects = {}
		table.insert(edgesToAdd, replacementEdge)
		local nodeToReplace = keepNode == replacementEdge.comp.node0 and replacementEdge.comp.node1 or replacementEdge.comp.node0 
		local nodePos = util.nodePos(nodeToReplace)
		nodePos.z = nodePos.z+ zoffset
		local newNode2 = newNodeWithPosition(nodePos, nextNodeId())
		table.insert(nodesToAdd, newNode2)
		local exitTangent 
		local actualExitTangent
		if keepNode == replacementEdge.comp.node0 then 
			replacementEdge.comp.node1 = newNode2.entity 
			replacementEdge.comp.tangent1.z = zoffset/2
			exitTangent = util.v3(replacementEdge.comp.tangent1)
			actualExitTangent = exitTangent
		else 
			replacementEdge.comp.node0 = newNode2.entity 
			replacementEdge.comp.tangent0.z = -zoffset/2
			exitTangent =  -1*util.v3(replacementEdge.comp.tangent0)
			actualExitTangent = util.v3(replacementEdge.comp.tangent0)
		end
--		local leftHandAngle = util.signedAngle(perpVec, actualExitTangent) 
		local leftHandAngle = util.signedAngle(otherVec, util.getDeadEndNodeDetails(unconnectedTerminalNode).tangent)
		local isLeft = leftHandAngle < 0
		trace("The leftHandAngle was ",math.deg(leftHandAngle)," isLeft=",isLeft, "isNode0=",isNode0, "unconnectedTerminalNode=",unconnectedTerminalNode )
		local relativeAngleChange = math.abs(util.signedAngle(entryTangent ,exitTangent))
		local naturalTangent = nodePos - newNodePos  
		local relativeAngleChange2 = math.abs(util.signedAngle(entryTangent ,naturalTangent))
		local relativeAngleChange3 = math.abs(util.signedAngle(exitTangent ,naturalTangent))
		local maxAngleChange = math.max(relativeAngleChange,math.max(relativeAngleChange2, relativeAngleChange3))
		local isAdverseAngle =  maxAngleChange > math.rad(60)
		trace("The relativeAngleChange was ",math.deg(relativeAngleChange),math.deg(relativeAngleChange2),math.deg(relativeAngleChange3)," isAdverseAngle?",isAdverseAngle," maxAngleChange=",math.deg(maxAngleChange))
		local isNode0 = newEdgeTemplate.comp.node0 == unconnectedTerminalNode-- agr overwritten the original variable
		if isAdverseAngle then 
			local rotation = -util.signedAngle(entryTangent ,naturalTangent)
			local maxRotation = math.rad(15)
			rotation = math.min(maxRotation, math.max(rotation, -maxRotation))
			entryTangent = util.rotateXYkeepingZ(entryTangent, rotation)
		 
			trace("Attempting to correct with rotation",math.deg(rotation), " isNode0=",isNode0,"unconnectedTerminalNode=",unconnectedTerminalNode)
			if isNode0 then 	
				util.setTangent(newEdgeTemplate.comp.tangent1, util.rotateXYkeepingZ(newEdgeTemplate.comp.tangent1, rotation))  
			else 
				util.setTangent(newEdgeTemplate.comp.tangent0, util.rotateXYkeepingZ(newEdgeTemplate.comp.tangent0, rotation))  
			end 

		end 
		
		buildSignal(edgeObjectsToAdd, newEdgeTemplate, isLeft ==  isNode0, 0.5)	
		local length = util.calculateTangentLength(newNodePos, nodePos, exitTangent, entryTangent)
		local connectEdge = copySegmentAndEntity(replacementEdge, -1-#edgesToAdd)
		connectEdge.comp.objects = {}
		connectEdge.comp.node0 = newNode2.entity 
		connectEdge.comp.node1 = newNode.entity 
		setTangent(connectEdge.comp.tangent0, length*vec3.normalize(exitTangent))
		setTangent(connectEdge.comp.tangent1, length*vec3.normalize(entryTangent))
		local theirNextEdge = util.getEdge(theirNextEdgeId)
	
		trace("Added the connect edge with entity", connectEdge.entity)
		table.insert(edgesToAdd, connectEdge)
		
		--if length > 2*params.targetSeglenth then 
		trace("Splitting the edge") 
		local solution =  util.solveForPositionHermiteFraction2(0.5, nodePos, util.v3(connectEdge.comp.tangent0), newNodePos, util.v3(connectEdge.comp.tangent1))
		local startingBridge = util.isUnderwater(nodePos)
		local endingBridge = util.isUnderwater(newNodePos)
		if startingBridge ~= endingBridge then 
			trace("Searching for bridge portal, startingBridge=",startingBridge," endingBridge=",endingBridge)
			local nextSolution  
			for i = 6, 26 do 
				nextSolution = util.solveForPositionHermiteFraction2(i/32, nodePos, util.v3(connectEdge.comp.tangent0), newNodePos, util.v3(connectEdge.comp.tangent1))
				local needsBridge = util.th(nextSolution.p) < 0
				trace("Inspecting point at ",nextSolution.p.x, nextSolution.p.y, "needsBridge?",needsBridge)
				if not startingBridge then 
					if needsBridge then 
						trace("Found the bridge portal at i=",i)
						break 
					else 
						solution = nextSolution
					end 
				else 
					if not needsBridge then 
						solution = nextSolution
						trace("Found the bridge portal at i=",i)
						break 
					else 
					
					end 
				end 
			
			end 
		end 
		
		local midPoint = newNodeWithPosition(solution.p, nextNodeId())
		table.insert(nodesToAdd, midPoint)
		local secondEdge = copySegmentAndEntity(connectEdge, -1-#edgesToAdd)
		
		connectEdge.comp.node1 = midPoint.entity 
		secondEdge.comp.node0 = midPoint.entity
		setTangent(connectEdge.comp.tangent0, solution.t0)
		setTangent(connectEdge.comp.tangent1, solution.t1)	
		setTangent(secondEdge.comp.tangent0, solution.t2)
		setTangent(secondEdge.comp.tangent1, solution.t3)
		table.insert(edgesToAdd, secondEdge)
		--end
		
		if theirNextEdge.type == 1 or util.th(nodePos)<0 or util.th(solution.p)<0 or not canGoUnder then 
			if solution.p.z-util.th(solution.p)> 10 and nodePos.z-util.th(nodePos) > 10 or util.th(nodePos)<0 or util.th(solution.p)<0 or not canGoUnder then 
				connectEdge.comp.type = 1 
				connectEdge.comp.typeIndex = theirNextEdge.type == 1  and theirNextEdge.typeIndex or isIronBridgeAvailable() and api.res.bridgeTypeRep.find("iron.lua") or api.res.bridgeTypeRep.find("stone.lua")
			end 
		else 
			connectEdge.comp.type = 2 
			connectEdge.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
		end
		
		if solution.p.z-util.th(solution.p)> 10 and newNodePos.z-util.th(newNodePos) > 10 or util.th(newNodePos)<0 or util.th(solution.p)<0 or not canGoUnder then 
			secondEdge.comp.type = 1 
			secondEdge.comp.typeIndex = theirNextEdge.type == 1 and theirNextEdge.typeIndex or isIronBridgeAvailable() and api.res.bridgeTypeRep.find("iron.lua") or api.res.bridgeTypeRep.find("stone.lua")
		elseif theirNextEdge.type ~= 1 then 
			secondEdge.comp.type = 2 
			secondEdge.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
		else 
			secondEdge.comp.type = 0
			secondEdge.comp.typeIndex = -1	
		end		
		
	end	
		
end


local function tryConnectTerminalNodes(routeInfo, callback, params, terminalGap, attemptNumber)
	
	if not params then params = paramHelper.getDefaultRouteBuildingParams() end
	trace("connecting terminal nodes")
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local constructionsToRemove = {}
	local nextId = -1000
	local function nextNodeId() 
		nextId = nextId - 1
		return nextId
	end 
	local atLeastonOneConnection = false
	local offset = terminalGap > 1 and 2+attemptNumber or 0
	trace("connectTerminalNodes: routeInfo.firstUnconnectedTerminalNode=",routeInfo.firstUnconnectedTerminalNode,"routeInfo.lastUnconnectedTerminalNode=",routeInfo.lastUnconnectedTerminalNode)
	if routeInfo.firstUnconnectedTerminalNode and #util.getSegmentsForNode(routeInfo.firstUnconnectedTerminalNode)==1 then 
		atLeastonOneConnection = true 
		trace("connecting firstUnconnectedTerminalNode ",routeInfo.firstUnconnectedTerminalNode , " segmentsForNode?", #util.getSegmentsForNode(routeInfo.firstUnconnectedTerminalNode))
		connectTerminalNode(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo,routeInfo.firstFreeEdge+offset, routeInfo.firstUnconnectedTerminalNode, params, terminalGap, nextNodeId, edgeObjectsToAdd, constructionsToRemove)
	end
	if routeInfo.lastUnconnectedTerminalNode and #util.getSegmentsForNode(routeInfo.lastUnconnectedTerminalNode)==1 then
		atLeastonOneConnection = true
		trace("connecting lastUnconnectedTerminalNode",routeInfo.lastUnconnectedTerminalNode , "segments for node", #util.getSegmentsForNode(routeInfo.lastUnconnectedTerminalNode))
		connectTerminalNode(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo, routeInfo.lastFreeEdge-offset, routeInfo.lastUnconnectedTerminalNode, params, terminalGap,nextNodeId, edgeObjectsToAdd, constructionsToRemove)
	end
	trace("tryConnectTerminalNodes: atLeastonOneConnection?",atLeastonOneConnection)
	if not atLeastonOneConnection then 
		callback({}, true) 
		return true
	end 
	
	local newProposal = proposalUtil.setupProposalAndDeconflictAndSplit(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	--newProposal.constructionsToRemove = constructionsToRemove
	local proposalData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if proposalData.errorState.critical and util.tracelog then
		trace("Critical error seen in connectTerminalNodes")
		debugPrint(proposalData.errorState)
		debugPrint(newProposal)
		local diagnose = true 
		proposalUtil.allowDiagnose = true
		proposalUtil.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	 
		--routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove , true)
	end 
	if proposalData.errorState.critical then 
		return false 
	end 
	if util.tracelog then debugPrint(newProposal) end
	util.clearCacheNode2SegMaps()
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	api.cmd.sendCommand(build, callback)
	if #constructionsToRemove > 0 then -- turns out removing constructions with edges causes issues when mixed in with other edge add/remove
		routeBuilder.addWork(function() 
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToRemove = constructionsToRemove
			local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
			api.cmd.sendCommand(build, routeBuilder.standardCallback)
		end)
	end 
	trace("Connection complete")
	return true
end

local function connectTerminalNodes(routeInfo, callback, params, terminalGap)
	trace("connectTerminalNodes: begin")
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local success
	for i = 1, 6 do 
		success = tryConnectTerminalNodes(routeInfo, callback, params, terminalGap, i)
		if success then 
			break 
		end
	end 
	if not success then 
		trace("Could not connect terminal nodes")
		if util.tracelog then 
			error("Could not connect terminal nodes")
		end 
		callback({}, false)
	end
end 

function routeBuilder.checkAndUpgradeToDoubleTrack(line, callback, params, extensionStation)
	util.lazyCacheNode2SegMaps()
	trace("checkAndUpgradeToDoubleTrack: begin for",extensionStation)
	if not params then params = paramHelper.getDefaultRouteBuildingParams() end
	local upgrades = {}
	local terminalConnection = false
	local workNeeded = 0
	local workCompleted = 0
	local wrappedCallback = function(res, success)
		trace("Wrapped callback checkAndUpgradeToDoubleTrack, success=",success)
		if success then 
			workCompleted = workCompleted + 1
			trace("Recieved callback, workCompleted=",workCompleted," workNeeded=",workNeeded)
			if workCompleted == workNeeded then 
				xpcall(function() callback(res, success)end, err)
			end
		else 
			if util.tracelog then debugPrint(res) end
			callback(res, success)
		end
	end
	local terminalConnectNodes = {}
	local terminalGap = 0
	if extensionStation then 
		local terminalToNodes =  util.getTerminalToFreeNodesMapForStation(extensionStation)
		if util.tracelog then debugPrint({terminalToNodes=terminalToNodes}) end
		local terminal1	
		for i = 1, #line.stops do
			local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
			local stop = line.stops[i]
			local nextStop = i==#line.stops and line.stops[1] or line.stops[i+1]
			local station = util.stationFromStop(stop)
			if station == extensionStation then 
				if terminal1 then 
					terminalGap = math.abs(stop.terminal-terminal1) 
				else 
					terminal1 = stop.terminal
				end 
				trace("Found extensionStation at terminal",stop.terminal)
				local terminalNodes = terminalToNodes[stop.terminal+1]
				for __, node in pairs(terminalNodes) do 
					local segCount = #util.getTrackSegmentsForNode(node)
					if segCount == 1 then 
						terminalConnection = true
						local routeInfoFn 
						local priorStation = util.stationFromStop(priorStop)
						local nextStation = util.stationFromStop(nextStop)
						workNeeded = workNeeded + 1
						if #pathFindingUtil.findRailPathBetweenNodeAndStation(node, priorStation)>0 then 
							trace("The node",node," had a connection to ",priorStation, " using" ,nextStation)
							routeBuilder.addDelayedWork(function() 
								local routeInfo = pathFindingUtil.getRouteInfo(station, nextStation) -- recompute 
								
								routeInfo.lastUnconnectedTerminalNode = nil
								routeInfo.firstUnconnectedTerminalNode = node
								trace("Setting station1 firstUnconnectedTerminalNode to",routeInfo.firstUnconnectedTerminalNode, " stations were ",station, nextStation)
								connectTerminalNodes(routeInfo, wrappedCallback, params, terminalGap)
							end)
							
						else 
							trace("The node",node," had NOT connection to ",priorStation)
							routeBuilder.addDelayedWork(function() 
								local routeInfo = pathFindingUtil.getRouteInfo(priorStation, station) -- recompute 
								if not routeInfo then 
									routeInfo = pathFindingUtil.getRouteInfo(station,priorStation)
									routeInfo.lastUnconnectedTerminalNode =  nil
									routeInfo.firstUnconnectedTerminalNode = node
								else 
									routeInfo.lastUnconnectedTerminalNode = node
									routeInfo.firstUnconnectedTerminalNode = nil
								end
								trace("Setting station2 lastUnconnectedTerminalNode to",routeInfo.lastUnconnectedTerminalNode, " stations were ",priorStation, station)
								connectTerminalNodes(routeInfo, wrappedCallback, params, terminalGap)
							
							end)
						end 
						
					end 
				end
			end 
		end 
	end 
	trace("The terminal gap was ",terminalGap)
	if util.tracelog then debugPrint({terminalConnectNodes=terminalConnectNodes}) end
	local alreadySeen = {}
	for i = 2, #line.stops do
		local station1 = util.stationFromStop(line.stops[i-1])
		local station2 = util.stationFromStop(line.stops[i])
		
		local stationHash = station1>station2 and station1*1000000+station2 or station2*1000000+station1 
		--[[if alreadySeen[stationHash] then 
			trace("skipping ",station1, " and ", station2, " as they were already seen")
		 	goto continue
		end]]--
		trace("inspecting link between ",station1, " and ", station2)
		local function routeInfoFn()
			local routeInfo = pathFindingUtil.getRouteInfo(station1, station2)
			
			if params.isCargo or not extensionStation then -- do not want to create a "through" station for cargo routes
				trace("removing unconnected terminal nodes")
				routeInfo.lastUnconnectedTerminalNode = nil
				routeInfo.firstUnconnectedTerminalNode = nil
			end
			if terminalGap > 1 and (station1 == extensionStation or station2 == extensionStation) then 
				
				trace("Removing connected terminal node for upgrade ", station1, station2)
				if station1 == extensionStation then
					routeInfo.firstUnconnectedTerminalNode =nil
				elseif station2 == extensionStation then 
					routeInfo.lastUnconnectedTerminalNode = nil
				 
				end 
			end
			if extensionStation  and station1 ~= extensionStation then 
				trace("removing unconnected terminal nodes lastUnconnectedTerminalNode")
				routeInfo.lastUnconnectedTerminalNode = nil
				
			end 
			if extensionStation and station2 ~= extensionStation then 
				trace("removing unconnected terminal nodes firstUnconnectedTerminalNode")
				routeInfo.firstUnconnectedTerminalNode = nil
			end
			return routeInfo
		end
		local routeInfo = routeInfoFn()
		if not routeInfo then 
			trace("WARNING! no route info found between ",station1, " and ", station2)
			goto continue 
		end
		
		local hasExtensionStation = station1 == extensionStation or station2==extensionStation

		--debugPrint(routeInfo)
		if routeInfo.numSignals == 0 then
			if not alreadySeen[stationHash] then 
				alreadySeen[stationHash]=true
				table.insert(upgrades, routeInfo)
			end
			
			
				--[[
				local idx = i
				routeBuilder.addWork(function() 
					local routeInfo = pathFindingUtil.getRouteInfo(station1, station2) -- recompute 
					if station1 == extensionStation then 
						routeInfo.lastUnconnectedTerminalNode = nil
						routeInfo.firstUnconnectedTerminalNode = terminalConnectNodes[idx-1]
						trace("Setting station1 firstUnconnectedTerminalNode to",routeInfo.firstUnconnectedTerminalNode, " stations were ",station1, station2)
					elseif station2 == extensionStation then 
						routeInfo.lastUnconnectedTerminalNode = terminalConnectNodes[idx]
						routeInfo.firstUnconnectedTerminalNode = nil
						trace("Setting station2 lastUnconnectedTerminalNode to",routeInfo.lastUnconnectedTerminalNode, " stations were ",station1, station2)
					end 
					connectTerminalNodes(routeInfo, wrappedCallback, params, terminalGap) 
				end)
			end]]--
		elseif (routeInfo.firstUnconnectedTerminalNode or routeInfo.lastUnconnectedTerminalNode )
		--or  terminalGap > 1 and hasExtensionStation 
		and terminalGap <= 1 and hasExtensionStation
		then
			workNeeded = workNeeded + 1
			
			routeBuilder.addWork(function()
				connectTerminalNodes(routeInfoFn(), wrappedCallback, params, terminalGap) 
			end)
			terminalConnection = true
		end
		::continue::
	end
	if #upgrades == 0  and not terminalConnection then
		trace("no upgrades were found")
		return false
	end
	for i, upgrade in pairs(upgrades) do 
		workNeeded = workNeeded + 1
		routeBuilder.addWork(function() routeBuilder.upgradeToDoubleTrack(upgrade, wrappedCallback, params)end)
	end
	
	return true
end

local function getTerminalsForStop(stop) 
	local result = { stop.terminal } 
	for i, alternativeTerminal in pairs(stop.alternativeTerminals) do 
		table.insert(result, alternativeTerminal.terminal)
	end 
	return result
end 

function routeBuilder.checkForTrackupgrades(line, callback, params, lineDepots)
	trace("Begin routeBuilder.checkForTrackupgrades, the params were params.isElectricTrack?", params.isElectricTrack,"params.isHighSpeedTrack?",params.isHighSpeedTrack)
	util.clearCacheNode2SegMaps()
	util.cacheNode2SegMaps()
	local alreadySeen = {}
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local nodesToRemove = {}
	
	local function nextEdgeId() 
		return -1 -#edgesToAdd
	end
	
	local edgeUniquenessCheck = {}
	local standardTrack = api.res.trackTypeRep.find("standard.lua")
	local highSpeedTrack = api.res.trackTypeRep.find("high_speed.lua")
	local stone = api.res.bridgeTypeRep.find("stone.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local cable = api.res.bridgeTypeRep.find("cable.lua")
	local supension = api.res.bridgeTypeRep.find("suspension.lua")
	local ironIsAvailable = util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom
	local cementIsAvailable = util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom
	local cableIsAvailable = util.year() >= api.res.bridgeTypeRep.get(cable).yearFrom
	local bridgeReplacement 
	if params.isHighSpeedTrack and ironIsAvailable then 
		bridgeReplacement = cementIsAvailable and cement or iron 
	end
	
	local function checkAndApplyUpgrades(edgeId)
		if not edgeUniquenessCheck[edgeId] and not util.isFrozenEdge(edgeId) then 
			edgeUniquenessCheck[edgeId] = true
			local newEntity = util.copyExistingEdge(edgeId, nextEdgeId())
			local needsUpgrade = false 
			if params.isElectricTrack ~= newEntity.trackEdge.catenary and (params.allowDowngrades or params.isElectricTrack) then 
				needsUpgrade = true 
				newEntity.trackEdge.catenary = params.isElectricTrack
			end 
			if  params.isHighSpeedTrack ~= (newEntity.trackEdge.trackType == highSpeedTrack)  and (params.allowDowngrades or params.isHighSpeedTrack) then -- this way around to allow mod tracks
				needsUpgrade = true 
				newEntity.trackEdge.trackType= params.isHighSpeedTrack and highSpeedTrack or standardTrack
			end
			if bridgeReplacement and newEntity.comp.type == 1 then 
				if newEntity.comp.typeIndex == stone then 
					newEntity.comp.typeIndex = bridgeReplacement
				elseif params.isVeryHighSpeedTrain then
					if newEntity.comp.typeIndex == iron then 
						newEntity.comp.typeIndex = bridgeReplacement
					elseif newEntity.comp.typeIndex == suspension and cableIsAvailable then 
						newEntity.comp.typeIndex = cable 
					end
				end
			end 
			if needsUpgrade then 
				table.insert(edgesToAdd, newEntity)
				table.insert(edgesToRemove, edgeId)
			end
		end
	end
	local depotUpgrades = {}
	local alreadySeenStations = {}
	local function checkAndApplyStationUpgrade(station)
		if station and not alreadySeenStations[station] then 
			alreadySeenStations[station] = true 
			
		end 
	end 
	local function upgradeFromRouteInfo(routeInfo) 
		if not routeInfo or not routeInfo.firstFreeEdge then 
			trace("WARNING! No routeinfo to upgrade")
			return 
		end
		for i = 1, #routeInfo.edges do  
			local edgeId = routeInfo.edges[i].id
			local frozenEdge = util.isFrozenEdge(edgeId) 
			if frozenEdge then 
				checkAndApplyStationUpgrade(util.getConstruction(frozenEdge).stations[1])
			else 
				checkAndApplyUpgrades(edgeId)
			end 
		end
		 
	end
	

	for i, depot in pairs(lineDepots) do
		local depotConstr = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(depot.depotEntity)
		local freeNode = util.getFreeNodesForConstruction(depotConstr)[1]
		for i, edge in pairs(util.findAllConnectedFreeTrackEdges(freeNode)) do 
			checkAndApplyUpgrades(util.getEdgeIdFromEdge(edge) )
		end
		if not depotUpgrades[depot] then 
			depotUpgrades[depot]=depotConstr
		end 
		
		if params.isElectricTrack then 
			 
			local path = pathFindingUtil.findPathFromDepotToStop(depot.depotEntity, line.stops[depot.stopIndex+1], true, line)
			if #path > 0   then 
				trace("Upgrading depot path")
				upgradeFromRouteInfo(pathFindingUtil.getRouteInfoFromEdges(path))
			end 
			  
		end 
	end
	
	for i = 1, #line.stops do
		local priorStop = i == 1 and #line.stops or i-1
		local station1 = util.getComponent(line.stops[priorStop].stationGroup, api.type.ComponentType.STATION_GROUP).stations[1+line.stops[priorStop].station]
		local station2 = util.getComponent(line.stops[i].stationGroup, api.type.ComponentType.STATION_GROUP).stations[1+line.stops[i].station]
		

		trace("inspecting link between ",station1, " and ", station2)
		checkAndApplyStationUpgrade(station1)
		checkAndApplyStationUpgrade(station2)
		if not params.stationLengthUpgrade and not params.doubleTerminalUpgrade then 
			local station1Terminals = getTerminalsForStop(line.stops[priorStop]) 
			local station2Terminals =  getTerminalsForStop(line.stops[i])
			for j, terminal1 in pairs(station1Terminals) do 
				for k, terminal2 in pairs(station2Terminals) do 
					local routeInfo = pathFindingUtil.getRouteInfo(station1, station2,terminal1,terminal2)
					trace("Upgrade from routeInfo: getting routeInfo between",station1, station2,terminal1,terminal2,"found?",routeInfo)
					if not routeInfo then 
						trace("Warning could not find routeInfo trying without terminal conditioning")
						routeInfo = pathFindingUtil.getRouteInfo(station1, station2)
						trace("On second attempt routeInfo was",routeInfo)
					end
					upgradeFromRouteInfo(routeInfo)
				end 
				
			end 
		end
		--if routeInfo and routeInfo.numSignals > 0 then 
		--	upgradeFromRouteInfo(pathFindingUtil.getRouteInfo(station2, station1,line.stops[i].terminal,line.stops[priorStop].terminal))
		--end
		 
		
	end
	local expectedCallbacks = util.size(alreadySeenStations)+util.size(depotUpgrades)
	
	if not callback then callback = routeBuilder.standardCallback end
	
	local callbackCount = 0
	local wrappedCallback = function(res, success) 
		trace("checkForTrackupgrades: Received wrappedCallback, success?",success,"callbackCount",callbackCount,"expectedCallbacks=",expectedCallbacks)
		if success then 
			callbackCount = callbackCount + 1
			if callbackCount == expectedCallbacks then 
				callback(res, success)
			end
		else 
			callback(res, success)
		end 
	end 

	if #edgesToAdd > 0 then 
		tryToFixTunnelPortals = false
		local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
		trace("routeBuilder.checkForTrackupgrades:  about to send command")
		util.clearCacheNode2SegMaps()
		api.cmd.sendCommand(build, function(res, success)	
			trace("routeBuilder.checkForTrackupgrades, callback result, success?",success)
			wrappedCallback(res, success)
		end)
		trace("Sent command to apply track upgrades")

	else 
		if callback then 
			callback({}, true)
		end
	end
	for stationId, bool in pairs(alreadySeenStations) do 
		routeBuilder.constructionUtil.checkStationForUpgrades(stationId, params, wrappedCallback)
	end 
	for depotId, depotConstr in pairs(depotUpgrades) do 
		routeBuilder.constructionUtil.checkRailDepotForUpgrades(depotConstr, params, wrappedCallback)
	end 
end

local function tryBuildTJunction(town, otherTown, callback, params,junctionNodes)
	local hadRoadPath = params.roadPath and #params.roadPath>0
	trace("tryBuildTJunction begin: between ",town.name, otherTown.name, "had roadpath?",hadRoadPath)
	local zoff = params.zoff 
	if not zoff then zoff = 10 end
	trace("Begin building T Junction, zoff=",zoff)
	if util.tracelog then
		debugPrint({junctionNodes = junctionNodes})
	end

	local onRampType = routeBuilder.getOnRampType()
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local otherPos = util.v3fromArr(otherTown.position)
	local otherTangent
	if  params.searchMap and params.searchMap[otherTown.id] then 
		otherPos =  params.searchMap[otherTown.id]
		for i , node in pairs(util.searchForDeadEndHighwayNodes(otherPos, 300)) do 
			otherTangent = util.getDeadEndNodeDetails(node).tangent 
			break
		end 
	end
	local townPos = util.v3fromArr(town.position)
	local weights = { 50, 50}
	if hadRoadPath then 
		weights = { 25, 75 } -- bias in favor of our town
	end 
	local options = {} 
	for i, node in pairs(junctionNodes) do 
		table.insert(options, {node=node})
	end 
	local closestJunctionNode = util.evaluateWinnerFromScores(options, weights,
		{ 
			function(node) return util.distance(util.nodePos(node.node), otherPos)end,
			function(node) return util.distance(util.nodePos(node.node), townPos)end 
		}
	).node
	local function closestEdge(edge) 
		local streetType = util.getStreetEdge(edge).streetType 
		if streetType == onRampType or util.getStreetTypeCategory(edge) ~= "highway" or not util.findParallelHighwayEdge(edge) or  util.getNumberOfStreetLanes(edge) == 3  then
			return 2^24 -- want to exclude, cannot use math.huge as this creates NANs
		end 
		return util.distance(util.getEdgeMidPoint(edge), otherPos)
	end
	local nextSegs = util.getStreetSegmentsForNode(closestJunctionNode)
	local startingEdgeId = util.evaluateWinnerFromSingleScore(nextSegs,closestEdge )
	trace("tryBuildTJunction: closestJunctionNode:",closestJunctionNode,"startingEdgeId=",startingEdgeId)
	local startingEdge = util.getEdge(startingEdgeId)
	local nextNode = startingEdge.node0 == closestJunctionNode and startingEdge.node1 or startingEdge.node0 
	local nextEdgeId = startingEdgeId 
	local function needsBridge(p) 
		return p.z-math.min(util.th(p), util.th(p, true)) > 5 or util.isUnderwater(p)
	end 
	
	local function needsTunnel(p)
		return p.z-math.max(util.th(p), util.th(p,true)) < -6
	end
	local isOutBound
	local edges = {} 
	local reversedSearch = false
	local options = {}
	
	local function validate(nextEdgeId) 
		local neighBouringEdges = {}
		local edge = util.getEdge(nextEdgeId)
		for i , node in pairs({edge.node0, edge.node1}) do 
			local segs = util.getSegmentsForNode(node)
			if #segs ~=2 then 
				return false 
			end 
			for j, seg in pairs(segs) do 
				if not util.contains(neighBouringEdges, seg) then 
					table.insert(neighBouringEdges, seg)
				end 
			end 
		end 
		assert(#neighBouringEdges==3)-- including ours
		for i, seg in pairs(neighBouringEdges) do 
			if not util.findParallelHighwayEdge(seg) then 
				return false 
			end 
			if util.isJunctionEdge(seg) then 
				return false 
			end
			if util.getEdgeLength(seg) < 50 then 
				return false
			end 
		end 
		
		return true 
	end 
	
	repeat 
		local priorEdgeId = nextEdgeId
		if #util.getSegmentsForNode(nextNode) == 1 then
			trace("node ",nextNode," was detected as a dead end")
			if reversedSearch then 
				trace("Exiting at ",#edges," as the nextNode",nextNode," is a dead end")		
				break
			else 
				reversedSearch = true
				nextNode = closestJunctionNode
				for i, seg in pairs(nextSegs) do 
					trace("Checking if can use ",seg," for reversal")
					if seg ~= startingEdgeId and util.getStreetTypeCategory(seg) == "highway"  and util.getStreetEdge(seg).streetType ~= onRampType and util.getNumberOfStreetLanes(seg) > 3 then
						priorEdgeId = seg 
						break
					end 
				end 
				local edgeFull = util.getEdge(priorEdgeId)
				nextNode = nextNode == edgeFull.node0 and edgeFull.node1 or edgeFull.node0
				--isOutBound = nextNode == edgeFull.node0
				trace("reversing search, starting with",priorEdgeId)
			end 
		end 
		
		nextEdgeId = util.findNextEdgeInSameDirection(priorEdgeId, nextNode)
		if not nextEdgeId then 
			trace("No nextEdge was found from ",priorEdgeId,  " and node ",nextNode, " aborting")
			break 
		end
			
		trace("The distance of the priorEdgeId was ",util.distance(util.getEdgeMidPoint(priorEdgeId), otherPos), " the distanceOf the next was",util.distance(util.getEdgeMidPoint(nextEdgeId), otherPos))
		if util.getStreetTypeCategory(nextEdgeId) ~= "highway" then 
			trace("Exiting at ",#edges," as the edge",nextEdgeId,"  is no longer highway")
			break 
		end
		if util.getNumberOfStreetLanes(nextEdgeId) == 3  then 
			trace("Exiting at ",#edges," as the edge ",nextEdgeId,"is an onramp ")
			break 
		end
		
		local nextEdge = util.getEdge(nextEdgeId)
		nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0 
		 
		--if #nextSegs ==2 then 
		if isOutBound == nil then 
			if reversedSearch then 
				isOutBound = nextNode == nextEdge.node1
			else 
				isOutBound = nextNode == nextEdge.node0
			end 
		end
		--end 
		trace("Adding edge ",nextEdgeId," for consideration in T junction")
		if reversedSearch then 
			table.insert(edges, 1, nextEdgeId) 
		else 
			table.insert(edges, nextEdgeId) 
		end 
		local p = util.getEdgeMidPoint(nextEdgeId)
		local nearbyIndustryScore = 0
		local testOffset = 180
		local testP1 =  util.nodePointPerpendicularOffset(p, util.v3(nextEdge.tangent1)+util.v3(nextEdge.tangent0), testOffset)
		local testP2 =  util.nodePointPerpendicularOffset(p, util.v3(nextEdge.tangent1)+util.v3(nextEdge.tangent0), -testOffset)
		local testP = util.distance(testP1,otherPos) < util.distance(testP2, otherPos) and testP1 or testP2 -- choose the closest
	
		local maxIndustryRange = 500
		local nearbyIndustry = util.searchForFirstEntity(p, maxIndustryRange, "SIM_BUILDING") or util.searchForFirstEntity(testP, maxIndustryRange, "SIM_BUILDING")
		trace("Inspecting point near", testP.x,testP.y," for edge",nextEdgeId, " nearbyIndustry?",nearbyIndustry)
		if nearbyIndustry then 
			local distToIndustry = util.distance(testP, util.v3fromArr(nearbyIndustry.position))
			trace("Found nearbyIndustry at ",distToIndustry)
			nearbyIndustryScore = math.max(maxIndustryRange-distToIndustry,0)-- closer to zero is better
			if params.collisionEntities[nearbyIndustry.id] or params.collisionEntities[nearbyIndustry.stockList] then -- NB stockList is actually constructionId
				trace("Boosting score for known nearbyIndustry ",nearbyIndustry.id)
				nearbyIndustryScore = 1000
			end 
		end 
		local maxTownRange = 750
		local nearbyTownScore =0 
		local nearbyTown = util.searchForFirstEntity(p, maxTownRange, "TOWN") or util.searchForFirstEntity(testP, maxTownRange, "TOWN")
		if nearbyTown then 
			local distToTown = util.distance(p, util.v3fromArr(nearbyTown.position))
			local distToTown2 =  util.distance(testP2, util.v3fromArr(nearbyTown.position))
			trace("Found nearbyTown at ",distToTown, " distToTown2",distToTown2)
			if distToTown2 < distToTown then -- only score if pointing into the town
				nearbyTownScore = math.max(maxTownRange-distToTown2,0)
				trace("set the nearbyTownScore to ",nearbyTownScore," at ", testP.x,testP.y)
			end 
		end 
		
		
		local nearbyEdgeScore = 0 
		for edgeId, edge in pairs(util.searchForEntities(p, 250, "BASE_EDGE")) do 
			local edgeP = util.getEdgeMidPoint(edgeId)
			local score = math.max(250-util.distance(p, edgeP),0)
			if params.collisionEntities[edgeId] or params.collisionEntities[edge.node0] or params.collisionEntities[edge.node1] then 
				trace("Boosting score for known collisionEntity edge ",edgeId)
				score = 1000
			end 
			if edge.track then 
				nearbyEdgeScore = nearbyEdgeScore + 2*score -- double penalty for track 
			elseif util.getStreetTypeCategory(edgeId)~="highway" then 
				nearbyEdgeScore = nearbyEdgeScore + score
			end 
		end
		for edgeId, edge in pairs(util.searchForEntities(testP, 250, "BASE_EDGE")) do 
			local edgeP = util.getEdgeMidPoint(edgeId)
			local score = math.max(250-util.distance(testP, edgeP),0)
			if params.collisionEntities[edgeId] or params.collisionEntities[edge.node0] or params.collisionEntities[edge.node1] then 
				trace("Boosting score for known collisionEntity edge ",edgeId)
				score = 1000
			end 
			if edge.track then 
				nearbyEdgeScore = nearbyEdgeScore + 2*score -- double penalty for track 
			elseif util.getStreetTypeCategory(edgeId)~="highway" then 
				nearbyEdgeScore = nearbyEdgeScore + score
			end 
		end
		local angleScore = math.abs(util.signedAngle(testP-p, otherPos-p))
		local angleScore2 = 0 
		if otherTangent then 
			angleScore2 = math.abs(util.signedAngle(otherPos-testP, otherTangent))
		end 
		local terrainScore = math.abs(p.z-util.th(p))+math.abs(testP.z-util.th(testP))
		if validate(nextEdgeId)  then 
			table.insert(options ,
			{
				edgeId = nextEdgeId,
				angle = math.deg(angleScore),
				testP = testP,
				scores  = { 	
					util.distance(p, otherPos),
					util.distance(p, townPos),  
					util.distance(p, otherPos) + util.distance(p, townPos),
					nearbyIndustryScore,
					nearbyEdgeScore,
					angleScore,
					terrainScore,
					angleScore2,
					util.scoreTerrainBetweenPoints(p, otherPos),
					nearbyTownScore
					}
			})
		end
	until  #edges >100
	if #options==0 then 
		trace("WARNING! No edges found for Tjunction, junctionNodes remaining:",#junctionNodes)
		if #junctionNodes > 1 then 
			local newJunctionNodes = {}
			for i, node in pairs(junctionNodes) do 
				if node ~= closestJunctionNode then 
					table.insert(newJunctionNodes, node) 
				end 
			end 
			trace("tryBuildTJunction: attempting recursive call")
			return tryBuildTJunction(town, otherTown, callback, params,newJunctionNodes)
		else 
			return false
		end 
	end 
	local weights = {
		25,  -- dist to other pos 
		25, -- dist to town pos
		100, -- total dist
		50, -- nearbyIndustryScore
		50, -- nearbyEdgeScore
		50, -- angleScore 
		50, -- terrainScore
		50, -- angleScore2
		25, -- routeScore ,
		50, -- nearbyTownScore
	}
	if hadRoadPath then 
		trace("tryBuildTJunction: Existing road path detected, altering weights")
		weights[1]=25
		weights[2]=100
		weights[3]=25
	end
	
	local winningEdgeId = util.evaluateWinnerFromScores(options, weights).edgeId
	local edgeIdx = util.indexOf(edges, winningEdgeId ) 
	if util.tracelog then debugPrint(options) end
	trace("Found ",#edges," for T junction, initial optimal edgeIdx was ",edgeIdx," isOutBound?",isOutBound, " from starting edge",startingEdgeId, " otherPos at ",otherPos.x,otherPos.y,"winningEdgeId=",winningEdgeId)
	assert(winningEdgeId == edges[edgeIdx])
	local offsetEdgeIdx = params.offsetEdgeIdx and params.offsetEdgeIdx or 0
	local maxEdgeIdx = (#edges-math.abs(offsetEdgeIdx)) - (params.tJuncSize +  params.minJunctionGap)
	local minEdgeIdx = params.minJunctionGap

	if not edgeIdx then 
		trace("Setting edgeIdx to maxEdgeIdx", maxEdgeIdx)
		edgeIdx = maxEdgeIdx 
	end
	 
	edgeIdx = edgeIdx + offsetEdgeIdx
	if edgeIdx > maxEdgeIdx then  
		trace("Setting edgeIdx to maxEdgeIdx", maxEdgeIdx)
		edgeIdx = maxEdgeIdx 
	end
	 
	if edgeIdx < minEdgeIdx then 
		trace("Setting edgeIdx to minEdgeIdx", minEdgeIdx)
		edgeIdx = minEdgeIdx 
	end 

	local innerInboundEdge
	local innerOutboundEdge 
	local outerInboundEdge 
	local outerOutboundEdge 
	
	if isOutBound then 
		innerOutboundEdge = edges[edgeIdx]
		while edgeIdx < #edges-1-params.tJuncSize and util.getEdgeLength(innerOutboundEdge) < 50 do 
			edgeIdx = edgeIdx + 1 
			trace("The innerOutboundEdge",innerOutboundEdge," was too short, trying next at ",edgeIdx)
			innerOutboundEdge = edges[edgeIdx]
		end 
		innerInboundEdge = util.findParallelHighwayEdge(innerOutboundEdge)
		trace("Using edgeIdx",edgeIdx," for the innerOutboundEdge")
		
		outerOutboundEdge = edges[edgeIdx+params.tJuncSize]
		while edgeIdx < #edges-1-params.tJuncSize and util.getEdgeLength(outerOutboundEdge) < 50 do 
			edgeIdx = edgeIdx + 1
			trace("The outerOutboundEdge",outerOutboundEdge," was too short, trying next at ",edgeIdx)			
			outerOutboundEdge = edges[edgeIdx+params.tJuncSize]
		end
		outerInboundEdge = util.findParallelHighwayEdge(outerOutboundEdge)
		trace("Using edgeIdx",edgeIdx+params.tJuncSize," for the outerOutboundEdge")
	else 
		innerInboundEdge = edges[edgeIdx]
		while edgeIdx < #edges-1-params.tJuncSize and util.getEdgeLength(innerInboundEdge) < 50 do 
			edgeIdx = edgeIdx + 1 
			trace("The innerInboundEdge",innerInboundEdge," was too short, trying next at ",edgeIdx)
			innerInboundEdge = edges[edgeIdx]
		end 
		trace("Using edgeIdx",edgeIdx," for the innerInboundEdge")
		innerOutboundEdge = util.findParallelHighwayEdge(innerInboundEdge)
		outerInboundEdge = edges[edgeIdx+params.tJuncSize]
		while edgeIdx < #edges-1-params.tJuncSize and util.getEdgeLength(outerInboundEdge) < 50 do 
			edgeIdx = edgeIdx + 1 
			trace("The outerInboundEdge",outerInboundEdge," was too short, trying next at ",edgeIdx)
			outerInboundEdge = edges[edgeIdx+params.tJuncSize]
		end		
		outerOutboundEdge = util.findParallelHighwayEdge(outerInboundEdge)
		trace("Using edgeIdx",edgeIdx+params.tJuncSize," for the outerInboundEdge")
	end 
	local edgesToRebuild = {} 
	for i = edgeIdx, edgeIdx+params.tJuncSize do 
		trace("Attempting to access edge",i," of ",#edges)
		if util.getEdge(edges[i]).type==1 then
			if not edgesToRebuild[edges[i]] then 
				edgesToRebuild[edges[i]]=true 
			end 
		end
		local parallelEdge = util.findParallelHighwayEdge(edges[i])
		if parallelEdge and util.getEdge(parallelEdge).type==1 then
			if parallelEdge and not edgesToRebuild[parallelEdge] then 
				edgesToRebuild[parallelEdge]=true 
			end
		end
	end
	
	trace("innerInboundEdge=",innerInboundEdge,"innerOutboundEdge=",innerOutboundEdge,"outerInboundEdge=",outerInboundEdge,"outerOutboundEdge=",outerOutboundEdge) 
	local highwayType = api.res.streetTypeRep.find(params.preferredHighwayRoadType)
	if params.preferredHighwayRoadType == "standard/country_large_one_way_new.lua" then 
		onRampType = api.res.streetTypeRep.find("standard/country_medium_one_way_new.lua")
	end
	local highwayWidth = util.getStreetWidth(highwayType)
	local rampWidth = util.getStreetWidth(onRampType)
	local highwayGap = highwayWidth + params.highwayMedianSize
	
	local minEdgeIdx = edgeIdx+math.ceil((params.tJuncSize)/2)
	local midEdgeId = edges[minEdgeIdx]
	trace("the midEdgeId was",midEdgeId,"the minEdgeIdx was",minEdgeIdx,"of",#edges)
	if not isOutBound then 
		local originalMidEdgeId = midEdgeId
		midEdgeId = util.findParallelHighwayEdge(midEdgeId) 
		trace("Replacing the originalMidEdgeId",originalMidEdgeId,"with",midEdgeId)
	end
	if not midEdgeId then 
		trace("WARNING! No midEdgeId was found, aborting")
		return false
	end 
	local minZ, maxZ = util.getMinMaxEdgeHeights(midEdgeId)
	local junctionOffset = 0 
	for i = edgeIdx, edgeIdx+params.tJuncSize-1 do 
		junctionOffset = junctionOffset + math.max(60, util.calculateSegmentLengthFromEdge(util.getEdge(edges[i])))
	end 
	local midEdgePoint = util.solveForPositionHermiteFractionExistingEdge(0.5, midEdgeId)
	midEdgePoint.t.z=0
	local testP = util.nodePointPerpendicularOffset(midEdgePoint.p, midEdgePoint.t, junctionOffset)
	local testP2 = util.nodePointPerpendicularOffset(midEdgePoint.p, midEdgePoint.t, -junctionOffset)
	local perpSign = vec2.distance(testP, util.v3fromArr(otherTown.position)) < vec2.distance(testP2, util.v3fromArr(otherTown.position)) and 1 or -1
	
	trace("The junctionOffset length was ",junctionOffset," the perpSign was ",perpSign)
	local tPoint = util.nodePointPerpendicularOffset(midEdgePoint.p, midEdgePoint.t, perpSign*junctionOffset)
	local tTangent = util.rotateXY(vec3.normalize(midEdgePoint.t), perpSign * math.rad(90))
	
	local tPointLeft = util.nodePointPerpendicularOffset(tPoint,tTangent, highwayGap/2)
	local tPointRight = util.nodePointPerpendicularOffset(tPoint,tTangent, -highwayGap/2)
	
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	local function nextNodeId()
		return -1000-#nodesToAdd
	end
	
	--local highwayType = util.getStreetEdge(innerOutboundEdge).streetType 
	
	local newNodeToPositionMap = {} 
	local newNodeToSegmentMap = {}
	local function nodePos(node) 
		if node < 0 then 
			return util.v3(newNodeToPositionMap[node])
		else 
			return util.nodePos(node)
		end
	end 
	
	local function newNode(p, zoffset)
		if zoffset then 
			--p.z = p.z+zoffset
			if zoffset < 0 then 
				p.z = minZ + zoffset
			else 
				p.z = maxZ + zoffset 
			end
		end
	
		local node = newNodeWithPosition(p, nextNodeId())
		newNodeToPositionMap[node.entity]=p	
		trace("added newNode",node.entity,"at",p.x,p.y,p.z)
		table.insert(nodesToAdd, node) 
		return node.entity 
	end
	local function addToMap(node, entity) 
		if not newNodeToSegmentMap[node] then 
			newNodeToSegmentMap[node] = {}
		end 
		table.insert(newNodeToSegmentMap[node], entity)
	end
	
	local function newEdge(node0, node1, streetType) 
		if not streetType then streetType = onRampType end
		local entity = api.type.SegmentAndEntity.new() 
		entity.entity = nextEdgeId() 
		entity.type = 0 
		entity.streetEdge.streetType = streetType 
		entity.comp.node0 = node0 
		entity.comp.node1 = node1 
		addToMap(node0, entity)
		addToMap(node1, entity)
		local nodePos0 = nodePos(node0)
		local nodePos1 = nodePos(node1)
		util.setTangents(entity, nodePos1-nodePos0)
		if needsBridge(nodePos0) and needsBridge(nodePos1) then 
			entity.comp.type = 1
			entity.comp.typeIndex = cement
		end
		if needsTunnel(nodePos0) and needsTunnel(nodePos0) then 
			entity.comp.type = 2
			entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
		end
		local playerOwned = api.type.PlayerOwned.new()
		playerOwned.player = api.engine.util.getPlayer()
		entity.playerOwned = playerOwned
		table.insert(edgesToAdd, entity)
		return entity
	end 
	
	local function getEdge(edgeId) 
		if edgeId < 0 then 
			return edgesToAdd[-edgeId].comp 
		end 
		return util.getEdge(edgeId)
	end 
	local function checkForSubSplits(entity) 
		local p0 = nodePos(entity.comp.node0)
		local p1 =nodePos(entity.comp.node1) 
		if util.distance(p0, p1) <= 2*params.minSeglength then 
			return 
		end
		local t0 = util.v3(entity.comp.tangent0)
		local t1 = util.v3(entity.comp.tangent1)
		local priorPointNeedsBridge = entity.comp.type == 1
		local priorPointNeedsTunnel = entity.comp.type == 2
		for i = 2, 10 do 
			local t = i /12 
			local checkPoint = util.solveForPositionHermiteFraction(t, { p0=p0, p1=p1, t0=t0, t1=t1 })
			local thisNeedsBridge = needsBridge(checkPoint.p)  
			local underwater= checkPoint.p.z <0 and util.th(checkPoint.p) < 0 
			if underwater or util.th(checkPoint.p) < 0  then 
				thisNeedsBridge = true 
			end
			local thisNeedsTunnel = needsTunnel(checkPoint.p)  
			if priorPointNeedsBridge ~= thisNeedsBridge or priorPointNeedsTunnel ~= thisNeedsTunnel or underwater
			and util.distance(p0,checkPoint.p) >params.minSeglength 
			and util.distance(p1,checkPoint.p) > params.minSeglength then 
				trace("Sub split discovered at t=",t, "p=",checkPoint.p.x,checkPoint.p.y,checkPoint.p.z," p0=",p0.x,p0.y,p0.z,"p1=",p1.x,p1.y,p1.z) 
				if checkPoint.p.z <0 and util.th(checkPoint.p) < 0 then 
					trace("Attempting to correct height")
					checkPoint.p.z = 2
				end 
				local splitNode = newNode(checkPoint.p)
				
				local entity2 = newEdge(splitNode, entity.comp.node1)
				local length = vec3.length(t0)
				util.setTangent(entity2.comp.tangent0, (1-t)*length*vec3.normalize(checkPoint.t)) 
				util.setTangent(entity2.comp.tangent1, (1-t)*length*vec3.normalize(t1))
				entity.comp.node1 = splitNode 
				util.setTangent(entity.comp.tangent0, t*t0)
				util.setTangent(entity.comp.tangent1, t*length*vec3.normalize(checkPoint.t))
				if thisNeedsBridge and needsBridge(p0) then 
					entity.comp.type = 1
					entity.comp.typeIndex = cement 
				elseif thisNeedsTunnel and needsTunnel(p0) then 
					entity.comp.type = 2 
					entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
				end
				checkForSubSplits(entity)
				checkForSubSplits(entity2)
				break 
			end 
			priorPointNeedsBridge = thisNeedsBridge
			priorPointNeedsTunnel = thisNeedsTunnel
		end
	end
	local function reverseEntity(entity) 
		util.reverseNewEntity(entity)
	end
	local function buildEntryExit(edgeId, isExit, zoffset) 
		local edge = getEdge(edgeId)
		local node = isExit and edge.node0 or edge.node1 
		local otherNode = isExit and edge.node1 or edge.node0
		local tangent = isExit and util.v3(edge.tangent0) or -1*util.v3(edge.tangent1)
		local otherTangent =  isExit and util.v3(edge.tangent1) or -1*util.v3(edge.tangent0)
		
		local exitTangent = util.rotateXY(vec3.normalize(tangent), isExit and -math.rad(45) or math.rad(45))
		local otherPerpTangent = util.rotateXY(vec3.normalize(otherTangent), isExit and -math.rad(90) or math.rad(90))
		local inputEdge = {
			p0 = nodePos(node),
			p1 = nodePos(otherNode), 
			t0 = tangent,
			t1 = otherTangent
		}
		if edgeId < 0 and (not zoffset or zoffset == 0) then 
			inputEdge.p1.z = inputEdge.p0.z 
			inputEdge.t0.z = 0 
			inputEdge.t1.z = 0
		end
		if zoffset and zoffset ~= 0 then 
			inputEdge.p1.z = inputEdge.p1.z + zoffset 
			if inputEdge.p1.z < 0 and util.th(inputEdge.p1) < 0 then 
				trace("Clamping negative offset to avoid water collision")
				inputEdge.t0.z = 0 
				inputEdge.p1.z = 1
			end 
			inputEdge.t1.z = inputEdge.p1.z - inputEdge.p0.z 
		end
		local minClearanceWidth = edgeId > 0 and 0.5*util.getEdgeWidth(edgeId)+0.5*rampWidth or rampWidth
		local rampOffset = math.max(minClearanceWidth+params.highwayMedianSize, params.minExitOffset)
		local splitPoint = util.solveForPositionHermiteLength(2*rampOffset,inputEdge)
		local perpTangent = util.rotateXY(vec3.normalize(splitPoint.t), isExit and -math.rad(90) or math.rad(90))
		 
		local exitNode = newNode(splitPoint.p +  rampOffset*perpTangent)
		local entity = newEdge(node, exitNode)
		setTangent(entity.comp.tangent0, vec3.length(util.v3(entity.comp.tangent0))*exitTangent)
		setTangent(entity.comp.tangent1, vec3.length(util.v3(entity.comp.tangent1))*vec3.normalize(splitPoint.t))
		if not isExit then 
			reverseEntity(entity)
		end
		
		if not zoffset or zoffset == 0 then 
			return exitNode
		end 
		
		local nextNode = newNode(nodePos(otherNode) + rampOffset*otherPerpTangent, zoffset)
		local entity2 = newEdge(exitNode, nextNode)
		setTangent(entity2.comp.tangent0, vec3.length(util.v3(entity2.comp.tangent0))*vec3.normalize(splitPoint.t))
		setTangent(entity2.comp.tangent1, vec3.length(util.v3(entity2.comp.tangent1))*vec3.normalize(inputEdge.t1))
		
		
		if not isExit then 
			reverseEntity(entity2)
		end
		return nextNode
	end
	
	local function buildConnectingCurve(node0, node1)
		local edge1 = newNodeToSegmentMap[node0][1]
		local edge2 = newNodeToSegmentMap[node1][1]
		trace("Building connecting curve between edges ",edge1.entity," and ",edge2.entity,"nodes were",node0,node1)
		local p0 = nodePos(node0)
		local p1 =nodePos(node1)
		local dist = util.distance(p0,p1 )
		local r = dist / math.sqrt(2)
		local length = r * 4 * (math.sqrt(2)-1)
		local t0 = length*vec3.normalize(util.v3(edge1.comp.tangent1))
		local t1 = length*vec3.normalize(util.v3(edge2.comp.tangent0))
		local entity = newEdge(node0, node1)
--[[		local entity2 
		if t0.z < 0 ~= t1.z < 0 then 
			trace("Creating split point in connecting curve")
			local splitPoint = util.solveForPositionHermiteFraction(0.5, {p0=p0, p1=p1, t0=t0, t1=t1})
			local splitNode = newNode(splitPoint.p)
		else 
			entity =  newEdge(node0, node1)
		end 
	]]--	
			
		setTangent(entity.comp.tangent0, t0)
		setTangent(entity.comp.tangent1, t1)
		checkForSubSplits(entity)
		trace("Building connecting curve, r was",r, " the length was ",length," the calculated segLength was",segLength)
	end 
	if not innerInboundEdge or not innerOutboundEdge or not outerInboundEdge or not outerOutboundEdge then 
		trace("WARNING! Edge not found aborting")
		return false
	end
	
	local n1 = buildEntryExit(innerInboundEdge, true, perpSign < 0 and zoff or 0) 
	local n2 = buildEntryExit(innerOutboundEdge, false, perpSign > 0 and zoff or 0 ) 
	local n3 = buildEntryExit(outerInboundEdge, false, perpSign < 0 and  -zoff or 0 ) 
	local n4 = buildEntryExit(outerOutboundEdge, true,  perpSign > 0 and -zoff or 0 ) 
	 
	local tNodeLeft = newNode(tPointLeft)
	local tNodeRight = newNode(tPointRight)
	local tExitLeft = newNode(tPointLeft + 40*tTangent)
	local tExitRight = newNode(tPointRight + 40*tTangent)
	local connectLeft = newNode(tPointLeft - 90*tTangent, perpSign*zoff)
	local connectRight = newNode(tPointRight - 90*tTangent, -perpSign*zoff)
	
	newEdge(tExitLeft, tNodeLeft, highwayType)
	newEdge(tNodeRight,tExitRight, highwayType)
	local tEdgeLeft = newEdge(tNodeLeft, connectLeft)
	local tEdgeRight = newEdge(connectRight,tNodeRight)
	local n5 = buildEntryExit(tEdgeLeft.entity, true, 0) 
	local n6 = buildEntryExit(tEdgeRight.entity, false, 0 ) 
	if perpSign > 0 then 
		buildConnectingCurve(n5, n3)
		buildConnectingCurve(n1, n6)
		buildConnectingCurve(n4, connectRight)
		buildConnectingCurve(connectLeft, n2)
	else 
		buildConnectingCurve(n5, n2)
		buildConnectingCurve(n1, connectRight)
		buildConnectingCurve(n4, n6)
		buildConnectingCurve(connectLeft, n3)
	end
	
	for edgeId, bool in pairs(edgesToRebuild) do -- do this to reposition the pillars 
		table.insert(edgesToAdd, util.copyExistingEdge(edgeId, nextEdgeId())) 
		table.insert(edgesToRemove, edgeId)
	end 
	
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	-- debugPrint(newProposal)
	local debugInfo = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	local ignoreErrors = params.ignoreErrors
	for __, entity in pairs(debugInfo.collisionInfo.collisionEntities) do 
		if not params.collisionEntities[entity.entity] then 
			 params.collisionEntities[entity.entity]=true
		end 
	end 
	if util.tracelog then debugPrint ({ collisionInfo = debugInfo.collisionInfo , errorState = debugInfo.errorState}) end
	if debugInfo.errorState.critical then 
		return false 
	end
	if #debugInfo.errorState.messages > 0 and not ignoreErrors then 
		if #debugInfo.errorState.messages==1 and debugInfo.errorState.messages[1]=="Bridge pillar collision" then
			ignoreErrors = true
		else 
			return false
		end
	end
	trace("About to build command to T junction")
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors)
	trace("About to send command to build  T junction")
	util.clearCacheNode2SegMaps()
	if not params.searchMap then 
		params.searchMap = {}
	end 
	params.searchMap[town.id]=tPointRight
	
	api.cmd.sendCommand(build, function(res, success) 
		util.clearCacheNode2SegMaps()
		trace("Result of building  T junction ",success)
		callback(res, success)
	end)
	return true
	
end

function routeBuilder.buildTJunction(town, otherTown, callback, params,junctionNodes)
	util.cacheNode2SegMaps()
	local maxTries = 8 
	params.zoff = 8 
	params.tJuncSize = 2
	params.minJunctionGap =2
	params.minExitOffset = 5
	params.offsetEdgeIdx = 0
	params.collisionEntities = {}
	local success
	for i = 1 ,maxTries do 
		success = tryBuildTJunction(town, otherTown, callback, params,junctionNodes)
		if success then 
			break 
		end
		params.zoff = -params.zoff 
		if params.zoff > 0 and params.zoff < 12 then 
			params.zoff = params.zoff + 1
		end
		if params.offsetEdgeIdx < 0 then 
			params.offsetEdgeIdx = 1+math.abs(params.offsetEdgeIdx)
		else 
			params.offsetEdgeIdx = math.min(-1, -params.offsetEdgeIdx)
		end 
		if i > 4 then 
			params.tJuncSize=4
		end
	end 
	if not success and not params.ignoreErrors then 
		params.ignoreErrors = true
		routeBuilder.buildTJunction(town, otherTown, callback, params,junctionNodes)
		return 
	end
	if not success then 
		callback({}, false) 
	end

end


local function tryBuildHighwayJunction(startingEdgeId, params, callback, existingRoadId, crossingPoint, extraOffSet, fullValidate) 
util.cacheNode2SegMapsIfNecessary()
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	local function nextNodeId()
		return -1000-#nodesToAdd
	end
	local newNodePosMap = {}
	local function newNode(p, zoffset)
		if zoffset then 
			p.z = p.z + zoffset 
		end
		local node = newNodeWithPosition(p, nextNodeId())
		table.insert(nodesToAdd, node) 
		newNodePosMap[node.entity]=p
		return node.entity
	end
	local countryType = api.res.streetTypeRep.find(params.preferredCountryRoadType)

	local function newEdge(node0, node1, typeToCopy)
		local entity = api.type.SegmentAndEntity.new()
		entity.entity = nextEdgeId()
		entity.type = 0
		entity.streetEdge.streetType = countryType
		entity.comp.node0=node0
		entity.comp.node1=node1 
		util.setTangents(entity, newNodePosMap[node1]-newNodePosMap[node0])
		if typeToCopy then 
			entity.comp.type = typeToCopy.comp.type 
			entity.comp.typeIndex = typeToCopy.comp.typeIndex
		end 
		table.insert(edgesToAdd, entity) 
		return entity
	end
	trace("tryBuildHighwayJunction: attempting to find parallel edge from",startingEdgeId)
	local parallelEdgeId = util.findParallelHighwayEdge(startingEdgeId, 30)
	if not parallelEdgeId then 
		trace("tryBuildHighwayJunction: Unable to continue, unable to find parallelEdgeId from ",startingEdgeId)
		return false 
	end
	local mp1 = util.getEdgeMidPoint(parallelEdgeId)
	local mp2 = util.getEdgeMidPoint(startingEdgeId)
	local parallelEdge = util.getEdge(parallelEdgeId)
	local startingEdge = util.getEdge(startingEdgeId)
	local theyAreTunnel = startingEdge.type ==2 and parallelEdge.type==2
	local theyAreBridge = startingEdge.type ==1 and parallelEdge.type==1
	local midPoint = 0.5*(mp1+mp2)
	local aboveGround = midPoint.z >= util.th(midPoint) and util.th(midPoint) > 0
	local zoffset = aboveGround and -params.minZoffsetRoad or params.minZoffsetRoad
	if aboveGround and midPoint.z+zoffset > util.th(midPoint) +2 then 
		zoffset = math.max(-15, util.th(midPoint)-midPoint.z+2)
	end 
	local perpVector = mp2 - mp1 
	trace("The length of the perpvector was ",vec3.length(perpVector))
	if vec3.length(perpVector) > 180 then 
		trace("Aborting due to excessive perpVector")
		return false 
	end
	local node0 
	local node0Pos 
	local node1 
	local node1Pos 
	local junctionTangent = util.rotateXY(perpVector, math.rad(90))
	if existingRoadId then 
		local existingRoad = util.getEdge(existingRoadId) 
		node0 = existingRoad.node0 
		node0Pos = util.nodePos(node0)
		if util.distance(node0Pos, crossingPoint) < 50 then
			trace("Finding next node for node0 in highway junction")
			local nextEdgeId = util.findNextEdgeInSameDirection(existingRoadId, node0)
			local nextEdge = util.getEdge(nextEdgeId)
			node0 = nextEdge.node0 == node0 and nextEdge.node1 or nextEdge.node0 
			node0Pos = util.nodePos(node0)
		end 
		
		node1 = existingRoad.node1 
		node1Pos = util.nodePos(node1)
		if util.distance(node1Pos, crossingPoint) < 50 then 
			trace("Finding next node for node1 in highway junction")
			local nextEdgeId = util.findNextEdgeInSameDirection(existingRoadId, node1)
			local nextEdge = util.getEdge(nextEdgeId)
			node1 = nextEdge.node0 == node1 and nextEdge.node1 or nextEdge.node0 
			node1Pos = util.nodePos(node1)
		end 
		local angle = util.signedAngle(node1Pos-node0Pos, perpVector)
		trace("The angle to the perp vector was ",math.deg(angle))
		if math.abs(angle) > math.rad(90) then 
			trace("SWapping nodes")
			local temp1 = node0 
			local temp2 = node0Pos
			node0 = node1 
			node0Pos = node1Pos 
			node1 = temp1 
			node1Pos = temp2 
		
		end 
		
	else 
		 node0Pos = midPoint-3*perpVector
		 node0 = newNode(node0Pos, zoffset)
		 node1Pos = midPoint+3*perpVector
		 node1 = newNode(node1Pos, zoffset)
		local road = newEdge(node0, node1)
		if aboveGround and not theyAreBridge or util.th(node0Pos)-node0Pos.z > 10 and  util.th(node1Pos)-node1Pos.z > 10 then 
			road.comp.type=2
			road.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
		elseif not aboveGround and not theyAreTunnel then 
			road.comp.type=1
			road.comp.typeIndex = api.res.bridgeTypeRep.find("cement.lua")
		end
		
		newEdge(newNode(node0Pos-perpVector), node0, road)
		newEdge(node1, newNode(node1Pos+perpVector), road)
	end
	
	local hiwayEdgeId1 =  util.findOtherSegmentsForNode(startingEdge.node0, {   startingEdgeId} )[1]
	local hiwayEdgeId2 =  util.findOtherSegmentsForNode(startingEdge.node1, {   startingEdgeId} )[1]
	local hiwayEdgeId3 =  util.findOtherSegmentsForNode(parallelEdge.node0, {   parallelEdgeId} )[1]
	local hiwayEdgeId4 =  util.findOtherSegmentsForNode(parallelEdge.node1, {   parallelEdgeId} )[1]
	
	local hiwayEdge1 = util.getEdge(hiwayEdgeId1)
	local hiwayEdge2 = util.getEdge(hiwayEdgeId2)
	local hiwayEdge3 = util.getEdge(hiwayEdgeId3)
	local hiwayEdge4 = util.getEdge(hiwayEdgeId4)
	
	local nextNode1 = startingEdge.node0
	local nextNode2 = startingEdge.node1
	local nextNode3 = parallelEdge.node0
	local nextNode4 = parallelEdge.node1
 
	for i = 1, extraOffSet do 
		trace("Finding the next highway edges at offset ",i)
		nextNode1 = nextNode1 == hiwayEdge1.node0 and hiwayEdge1.node1 or hiwayEdge1.node0
		nextNode2 = nextNode2 == hiwayEdge2.node0 and hiwayEdge2.node1 or hiwayEdge2.node0
		nextNode3 = nextNode3 == hiwayEdge3.node0 and hiwayEdge3.node1 or hiwayEdge3.node0
		nextNode4 = nextNode4 == hiwayEdge4.node0 and hiwayEdge4.node1 or hiwayEdge4.node0
		hiwayEdgeId1 =  util.findOtherSegmentsForNode(nextNode1, {   hiwayEdgeId1} )[1]
		hiwayEdgeId2 =  util.findOtherSegmentsForNode(nextNode2, {   hiwayEdgeId2} )[1]
		hiwayEdgeId3 =  util.findOtherSegmentsForNode(nextNode3, {   hiwayEdgeId3} )[1]
		hiwayEdgeId4 =  util.findOtherSegmentsForNode(nextNode4, {   hiwayEdgeId4} )[1]
		hiwayEdge1 = util.getEdge(hiwayEdgeId1)
		hiwayEdge2 = util.getEdge(hiwayEdgeId2)
		hiwayEdge3 = util.getEdge(hiwayEdgeId3)
		hiwayEdge4 = util.getEdge(hiwayEdgeId4)
	end 
	
	
	--params.preferredHighwayRoadType = "standard/country_large_one_way_new.lua"
	
	local junctionTangent = util.v3(startingEdge.tangent0)+util.v3(startingEdge.tangent1)
	local validate = fullValidate
	routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, hiwayEdge1.node0, util.nodePos(hiwayEdge1.node0),util.v3(hiwayEdge1.tangent0), hiwayEdge1.type, node1, node1Pos, params, nextEdgeId, nextNodeId, true,   junctionTangent, validate) 
	--junctionTangent= util.v3(hiwayEdge2.tangent1)
	routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, hiwayEdge2.node1, util.nodePos(hiwayEdge2.node1),-1*util.v3(hiwayEdge2.tangent1), hiwayEdge2.type, node1, node1Pos, params, nextEdgeId, nextNodeId, false, -1*junctionTangent, validate) 
	--table.remove(edgesToAdd)
	local junctionTangent = util.v3(parallelEdge.tangent0)+util.v3(parallelEdge.tangent1)
	routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, hiwayEdge3.node0, util.nodePos(hiwayEdge3.node0),util.v3(hiwayEdge3.tangent0), hiwayEdge3.type, node0, node0Pos, params, nextEdgeId, nextNodeId, true, junctionTangent, validate) 
	routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, hiwayEdge4.node1, util.nodePos(hiwayEdge4.node1),-1*util.v3(hiwayEdge4.tangent1), hiwayEdge4.type, node0, node0Pos, params, nextEdgeId, nextNodeId, false, -1*junctionTangent, validate) 
	
	table.insert(edgesToAdd, util.copyExistingEdge(startingEdgeId, nextEdgeId()))
	table.insert(edgesToRemove, startingEdgeId)
	table.insert(edgesToAdd, util.copyExistingEdge(parallelEdgeId, nextEdgeId()))
	table.insert(edgesToRemove, parallelEdgeId)
	local diagnose =false 
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	--debugPrint(newProposal)
	local debugInfo = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	local ignoreErrors = params.ignoreErrors
	--ignoreErrors = true
		debugPrint({ collisionInfo = debugInfo.collisionInfo , errorState = debugInfo.errorState})
	if debugInfo.errorState.critical then 
		callback(debugInfo, false)
		return false 
	end
	if #debugInfo.errorState.messages > 0 and not ignoreErrors then 
		if #debugInfo.errorState.messages==1 and debugInfo.errorState.messages[1]=="Bridge pillar collision" then
			ignoreErrors = true
		else 
			
			return false
		end
	end
	trace("About to build command to   junction")
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors)
	trace("About to send command to build     junction")
	util.clearCacheNode2SegMaps()
	
	api.cmd.sendCommand(build, function(res, success) 
		trace("Result of building  T junction ",success)
		callback(res, success)
	end)
	return true
end

function routeBuilder.buildHighwayJunction(startingEdgeId, params, callback, existingRoadId, crossingPoint, sortedOptions)
	trace("Begin building highway junction for edge",startingEdgeId)
	local success 
	for i, fullValidate in pairs({false, true}) do 
		for extraOffSet = 0, 3 do 
			 success = tryBuildHighwayJunction(startingEdgeId, params, callback, existingRoadId, crossingPoint,extraOffSet, fullValidate) 
			 if success then 
				break 
			end 
		end
		if success then 
			break 
		end 
	end 
	if not success then 
		if sortedOptions and #sortedOptions > 1 then 
			table.remove(sortedOptions, 1)
			startingEdgeId = sortedOptions[1].edgeId
			trace("buildHighwayJunction: reattempting at",startingEdgeId)
			routeBuilder.buildHighwayJunction(startingEdgeId, params, callback, existingRoadId, crossingPoint, sortedOptions)
		else  
			callback({}, false)
		end 
	end
end 

function routeBuilder.buildHighwayCrossing(crossing,params)
	util.lazyCacheNode2SegMaps()
	trace("Received callback to build highway crossing")
	if not params.isHighway then 
	 
		
		local startingEdgeId = util.searchForNearestEdge(crossing.crossingPoint, 100, function(edge) return util.getStreetTypeCategory(edge)=="highway" end )
		local existingRoadId = util.searchForNearestEdge(crossing.crossingPoint, 100, function(edge) return util.getStreetEdge(edge) and util.getStreetTypeCategory(edge)~="highway" end )
		trace("The startingEdgeId was ",startingEdgeId," the existingRoadId was ",existingRoadId)
		routeBuilder.buildHighwayJunction(startingEdgeId, params, routeBuilder.standardCallback, existingRoadId, crossing.crossingPoint)
		return
	end 
	--collectgarbage()

	local maxTries = 6
	params.zoff = 8 
	params.zoffHigh = 12
	params.zoffLow = -12
	params.tJuncSize = 4
	params.minJunctionGap =3
	params.minExitOffset = 5
	params.targetMinLength = 60
	params.minJunctionDistance = 150 / math.sin(crossing.crossingAngle)
	trace("Begin building highway crossing, min distance caluclated to be ",params.minJunctionDistance)
	local success
	for i = 1 ,maxTries do 
		success = routeBuilder.tryBuildHighwayCrossing(crossing, params)
		if success then 
			break 
		end
		params.minJunctionDistance = params.minJunctionDistance+40
		params.targetMinLength = params.targetMinLength - 5   
		 
		if i >  2 then 
			params.ignoreErrors = true 
		end
		if i > 4 and params.disableRerouting then
			params.disableSubsplits = true 
		end
	end 
	if not success and not params.disableRerouting then 
		params.disableRerouting = true
		routeBuilder.buildHighwayCrossing(crossing,params)
		params.disableRerouting = false
		--callback({}, false) 
	end

end

function routeBuilder.tryBuildHighwayCrossing(crossing, params)
	local node1 = util.searchForNearestNode(crossing.crossingNodePos,10).id  
	local node2 = util.searchForNearestNode(crossing.crossingNode2Pos ,10).id
		trace("Begin building Highways Junction, the nodes provided were",node1,node2)
	local zoffHigh = params.zoffHigh
	local zoffLow = params.zoffLow
	local minHeight = math.huge 
	local maxHeight = -math.huge
	local onRampType = routeBuilder.getOnRampType()
	local maxRampSlope = api.res.streetTypeRep.get(onRampType).maxSlopeBuild
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local baseZ = 0.5*(util.nodePos(node1).z+util.nodePos(node2).z)
	local crossingPoint = crossing.crossingPoint
	
	local function gatherEdgesToNextJunction(startingNode, startingEdge) 
		local edges = {}
		local nextEdgeId = startingEdge
		local nextNode = startingNode 
		local alreadySeen = {} 
		local nextSegs
		repeat 
			alreadySeen[nextEdgeId]=true
			table.insert(edges, nextEdgeId) 
			nextSegs = util.getStreetSegmentsForNode(nextNode) 
			nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
			--nextEdgeId = nextEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
			if not nextEdgeId or alreadySeen[nextEdgeId] then break end
			local nextEdge = util.getEdge(nextEdgeId)
			if #edges < 5 then 
				minHeight = math.min(minHeight, util.nodePos(nextNode).z)
				maxHeight = math.max(maxHeight, util.nodePos(nextNode).z)
			end
			nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0 			
		until #nextSegs < 2 or util.getStreetTypeCategory(nextEdgeId) ~= "highway" or #edges > 20
		return edges 
	end
	local startingEdges = util.getStreetSegmentsForNode(node1)
	local startingEdges2 = util.getStreetSegmentsForNode(node2)
	if #startingEdges ~= 2 or #startingEdges2 ~= 2 then 	
		trace("Unable to build at this location") 
		return false 
	end
	local function gatherInBoundAndOutboundEdgesFromNode(startingNode) 
		local segs = util.getStreetSegmentsForNode(startingNode)
		local edge1 = util.getEdge(segs[1])
		local edge2 = util.getEdge(segs[2])
		local outboundEdge = edge1.node0 == startingNode and segs[1] or segs[2]
		local inboundEdge = outboundEdge == segs[1] and segs[2] or segs[1]
		local outboundEdges = gatherEdgesToNextJunction(startingNode, outboundEdge)
		local inboundEdges = gatherEdgesToNextJunction(startingNode, inboundEdge)
		return { 
			outboundEdges =outboundEdges,
			inboundEdges = inboundEdges ,
			valid = #outboundEdges > 5 and #inboundEdges > 5
		}
	end 
	
	local rightMainLineEdges = gatherInBoundAndOutboundEdgesFromNode(node1)
	local otherMainlineNode = util.findParallelHighwayNode(node1)
	local leftMainLineEdges= gatherInBoundAndOutboundEdgesFromNode(otherMainlineNode)
	
	local otherPerpNode = util.findParallelHighwayNode(node2)
	if not otherPerpNode then 
		trace("Unable to build highway crossing, cannot find otherPerpNode from",node2)
		return false 
	end 
	local perpMainVector = util.nodePos(otherMainlineNode)-util.nodePos(node1)
	local perpPerpVector = util.nodePos(otherPerpNode)-util.nodePos(node2)
	local angle = util.signedAngle(perpMainVector, perpPerpVector)
	trace("The angle between the perp vectors was ",math.deg(angle))
	
	local leftPerpLineEdges =  gatherInBoundAndOutboundEdgesFromNode(node2)
	local rightPerpLineEdges = gatherInBoundAndOutboundEdgesFromNode(otherPerpNode)
	
	if angle < 0 then 
		trace("Swapping leftPerpLineEdges and rightPerpLineEdges")
		local temp = leftPerpLineEdges 
		leftPerpLineEdges = rightPerpLineEdges
		rightPerpLineEdges = temp 
	end

	
	if not (leftMainLineEdges.valid and rightMainLineEdges.valid and leftPerpLineEdges.valid and rightPerpLineEdges.valid) then 
		trace("Unable to build, insufficient clearance")
		return false 
	end
	

	local highwayWidth = math.max(util.getEdgeWidth(startingEdges[1]), util.getEdgeWidth(startingEdges2[1]))
	local rampWidth = util.getStreetWidth(onRampType)
	local highwayGap = highwayWidth + params.highwayMedianSize
	local exitAngle =  math.rad(45)
	if util.getStreetTypeName(startingEdges[1]) == "standard/country_large_one_way_new.lua" or util.getStreetTypeName(startingEdges2[1]) =="standard/country_large_one_way_new.lua" then 
		exitAngle = math.rad(60)
	end
	local maxTrackHeight = -math.huge 
	local minTrackHeight = math.huge
	for edgeId, edge in pairs(util.searchForEntities(crossingPoint, 300, "BASE_EDGE")) do 
		if edge.track then 
			local maxZ = math.max(edge.node0pos[3],edge.node1pos[3])
			local minZ = math.min(edge.node0pos[3],edge.node1pos[3])
			maxTrackHeight = math.max(maxZ, maxTrackHeight)
			minTrackHeight = math.min(minZ, minTrackHeight)
		end 	
	end
	if maxTrackHeight < minHeight and minHeight - maxTrackHeight < 2*params.minZoffset then 
		trace("Setting the min height to ",minTrackHeight)
		minHeight = math.min(minHeight, minTrackHeight)
	end 
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	local function nextNodeId()
		return -1000-#nodesToAdd
	end
	
	local newNodeMap = {}
	local newNodeToPositionMap = {} 
	local newNodeToSegmentMap = {}
	local function nodePos(node) 
		if node < 0 then 
			return util.v3(newNodeToPositionMap[node], true)
		else 
			return util.v3(util.nodePos(node), true) -- NB make a copy to avoid manipulating the original
		end
	end 
	
	local function needsBridge(p) 
		return p.z-math.min(util.th(p), util.th(p, true)) > 6 or util.isUnderwater(p)
	end 
	
	local function needsTunnel(p)
		return p.z-math.max(util.th(p), util.th(p,true)) < -6
	end
	local minNodeHeight = minHeight
	local function newNode(p, zoffset)
		if zoffset then 
			p.z = p.z+zoffset
			if p.z < 0 and util.isUnderwater(p) then 
				trace("Clamping offset to avoid collision with water")
				p.z = 1
			end
		end
		minNodeHeight = math.min(minNodeHeight, p.z)
		local node = newNodeWithPosition(p, nextNodeId())
		newNodeToPositionMap[node.entity]=util.v3(p)	
		newNodeMap[node.entity]=node
		trace("tryBuildHighwayCrossing: added newNode",node.entity,"at",p.x,p.y,p.z)
		table.insert(nodesToAdd, node) 
		return node.entity 
	end
	local function addToMap(node, entity) 
		if not newNodeToSegmentMap[node] then 
			newNodeToSegmentMap[node] = {}
		end 
		table.insert(newNodeToSegmentMap[node], entity)
	end
	
	local function newEdge(node0, node1, streetType ) 
		local entity = api.type.SegmentAndEntity.new() 
		entity.entity = nextEdgeId() 
		entity.type = 0 
		if not streetType then streetType = onRampType end
		entity.streetEdge.streetType = streetType 
		entity.comp.node0 = node0 
		entity.comp.node1 = node1 
		addToMap(node0, entity)
		addToMap(node1, entity)
		local nodePos0 = nodePos(node0)
		local nodePos1 = nodePos(node1)
		util.setTangents(entity, nodePos1-nodePos0)
		if needsBridge(nodePos0) and needsBridge(nodePos1)
			or util.isUnderwater(nodePos0) and nodePos0.z > 0 
			or util.isUnderwater(nodePos1) and nodePos1.z > 0 then 
			entity.comp.type = 1
			entity.comp.typeIndex = cement
		end
		if needsTunnel(nodePos0) and  needsTunnel(nodePos1)then 
			entity.comp.type = 2
			entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
		end
		trace("tryBuildHighwayCrossing: added edge",entity.entity,"connecting",node0,node1)
		table.insert(edgesToAdd, entity)
		return entity
	end 
	
	local function getEdge(edgeId) 
		if edgeId < 0 then 
			return edgesToAdd[-edgeId].comp 
		end 
		return util.getEdge(edgeId)
	end 
	
	local function buildEntryExit(edgeId, isExit, zoffset) 
		trace("buildEntryExit: edgeId=",edgeId,"isExit=",isExit,"zoffset=",zoffset)
		if not zoffset then 
			zoffset = 0 
		end
		local edge = getEdge(edgeId)
		local node = isExit and edge.node0 or edge.node1 
		local otherNode = isExit and edge.node1 or edge.node0
		local tangent = isExit and util.v3(edge.tangent0) or -1*util.v3(edge.tangent1)
		local otherTangent =  isExit and util.v3(edge.tangent1) or -1*util.v3(edge.tangent0)
		
		local exitTangent = util.rotateXY(vec3.normalize(tangent), isExit and -exitAngle or exitAngle)
		local otherPerpTangent = util.rotateXY(vec3.normalize(otherTangent), isExit and -math.rad(90) or math.rad(90))
		local inputEdge = {
			p0 = nodePos(node),
			p1 = nodePos(otherNode), 
			t0 = tangent,
			t1 = otherTangent
		}
		if edgeId < 0 and zoffset == 0 then 
			inputEdge.p1.z = inputEdge.p0.z 
			inputEdge.t0.z = 0 
			inputEdge.t1.z = 0
		end
		if zoffset ~= 0 then 
			local maxOffset = vec2.distance(inputEdge.p0, inputEdge.p1)*maxRampSlope*0.5
			if maxOffset < math.abs(zoffset) then 
				trace("Too much offset, ",maxOffset," cannot use ",zoffset)
				zoffset = zoffset < 0 and -maxOffset or maxOffset
			end
			trace("Changing the input edge z from ",inputEdge.p1.z," to ", inputEdge.p1.z + zoffset)
			inputEdge.p1.z = inputEdge.p1.z + zoffset 
			inputEdge.t1.z = inputEdge.p1.z - inputEdge.p0.z 
		end
		local minClearanceWidth = edgeId > 0 and 0.5*util.getEdgeWidth(edgeId)+0.5*rampWidth or rampWidth
		if zoffset == 0 then 
			minClearanceWidth = minClearanceWidth + rampWidth + params.highwayMedianSize
		end
		local rampOffset = math.max(minClearanceWidth+params.highwayMedianSize, params.minExitOffset)
		local splitLength = 2*rampOffset
		local edgeLength = util.calculateSegmentLengthFromNewEdge(inputEdge)
		if 1.1*splitLength >=  edgeLength then 
			trace("WARNING! Too much splitLength setting to halfway, was",splitLength,"edgeLength=",edgeLength)
			splitLength = 0.5*edgeLength
		end 	
		
		local splitPoint = util.solveForPositionHermiteLength(splitLength,inputEdge)
		local perpTangent = util.rotateXY(vec3.normalize(splitPoint.t), isExit and -math.rad(90) or math.rad(90))
		if splitPoint.p.z < 0 and util.th(splitPoint.p) < 0 then 
			trace("Proposed split point would be underwater, attempting to correct")
			splitPoint.p.z = 2
		end
		local exitNode = newNode(splitPoint.p +  rampOffset*perpTangent)
		--local exitNode = newNode(nodePos(node) + math.sqrt(minClearanceWidth^2)*exitTangent)
		local entity = newEdge(node, exitNode)
		
		--local exitNode2 = newNode(splitPoint.p +  2*rampOffset*perpTangent )
		--local entity2 = newEdge(exitNode, exitNode2)
		
		
		
		setTangent(entity.comp.tangent0, vec3.length(util.v3(entity.comp.tangent0))*exitTangent)
		setTangent(entity.comp.tangent1, vec3.length(util.v3(entity.comp.tangent1))*vec3.normalize(splitPoint.t))
		
		--local exitNode2 = newNode(splitPoint.p +  rampOffset*perpTangent + 20*exitTangent)
		--local entity2 = newEdge(exitNode, exitNode2)
		
		if not isExit then 
			util.reverseNewEntity(entity)
			--util.reverseNewEntity(entity2)
		end
		
		if zoffset == 0 then 
			trace("The exitnode was created at a height of ",splitPoint.p.z,newNodeMap[exitNode].comp.position.z, " the exitNode created was ",exitNode, " z tangents:",entity.comp.tangent0.z,entity.comp.tangent1.z,"isExit?",isExit," from edge",edgeId)
			return exitNode
		end 
		
		local nextNode = newNode(nodePos(otherNode) + rampOffset*otherPerpTangent, zoffset)
		local entity3 = newEdge(exitNode, nextNode)
		setTangent(entity3.comp.tangent0, vec3.length(util.v3(entity3.comp.tangent0))*vec3.normalize(splitPoint.t))
		setTangent(entity3.comp.tangent1, vec3.length(util.v3(entity3.comp.tangent1))*vec3.normalize(inputEdge.t1))
		
		
		if not isExit then 
		 
			util.reverseNewEntity(entity3)
		end
		return nextNode
	end
	
	local function checkAndAdjustTangentsForUnderwater(entity, joinEdge) 
		local p0 = nodePos(entity.comp.node0)
		local p1 =nodePos(entity.comp.node1)
		
		 
		local isNode0 = entity.comp.node0 == joinEdge.comp.node1
		local foundUnderwaterPoints
		local count = 0
		repeat
			count = count + 1
			foundUnderwaterPoints = false 	
			local t0 = util.v3(entity.comp.tangent1)
			local t1 = util.v3(entity.comp.tangent0)
			for i = 1, 11 do
				local t= i/12 
				local testP = util.hermite(t,p0, t0, p1, t1).p 
				if testP.z <0 and util.isUnderwater(testP) then 
					foundUnderwaterPoints = true 
					break 
				end
			end 
			if foundUnderwaterPoints then 
				trace("Found underwater points, attempting to correct")
				if isNode0 then 
					t0.z = 0.9*t0.z 
					setTangent(entity.comp.tangent0, vec3.length(util.v3(entity.comp.tangent0))*vec3.normalize(t0))
					setTangent(joinEdge.comp.tangent1, vec3.length(util.v3(joinEdge.comp.tangent1))*vec3.normalize(t0))
				else 
					t1.z = 0.9*t1.z 
					setTangent(joinEdge.comp.tangent1, vec3.length(util.v3(joinEdge.comp.tangent1))*vec3.normalize(t1))
					setTangent(entity.comp.tangent0, vec3.length(util.v3(entity.comp.tangent0))*vec3.normalize(t1))
				end
			end
			
		until not foundUnderwaterPoints or count > 10
				
	end
	 
	local function checkForSubSplits(entity, isSecondOrder, isNode0, maxrecurse)
		if not maxrecurse then maxrecurse = 5 end
		if maxrecurse == 0 or params.disableSubsplits then	
			return 
		end
		local p0 = nodePos(entity.comp.node0)
		local p1 =nodePos(entity.comp.node1) 
		if util.distance(p0, p1) <= 2*params.minSeglength then 
			return 
		end
		local t0 = util.v3(entity.comp.tangent0)
		local t1 = util.v3(entity.comp.tangent1)
		local from = 2
		local to = 10 
		local increment = 1
		local isTunnel = entity.comp.type == 2
		local isBridge = entity.comp.type == 1
		if isSecondOrder then 
			if isNode0 then 
				isTunnel = needsTunnel(p1)
				isBridge = needsBridge(p1)
				from = 10
				to = 2 
				increment = -1
			else 
				isTunnel = needsTunnel(p0)
				isBridge = needsBridge(p0)
			end
		end
		local isLeft = false
		if isLeft then 
		
		end 
		
		for i = from, to, increment do 
			local t = i /12 
			local checkPoint = util.solveForPositionHermiteFraction(t, { p0=p0, p1=p1, t0=t0, t1=t1 })
			local thisNeedsBridge = needsBridge(checkPoint.p)
			local underwater= checkPoint.p.z <0 and util.th(checkPoint.p) < 0 
			if underwater or util.th(checkPoint.p) < 0  then 
				thisNeedsBridge = true 
			end
			local thisNeedsTunnel = needsTunnel(checkPoint.p) 
			if  isBridge ~= thisNeedsBridge or isTunnel ~= thisNeedsTunnel or underwater
			and util.distance(p0,checkPoint.p) >params.minSeglength 
			and util.distance(p1,checkPoint.p) > params.minSeglength then 
				
				if checkPoint.p.z <0 and util.th(checkPoint.p) < 0 then 
					trace("Attempting to correct height")
					checkPoint.p.z = 2
				end 
				local splitNode = newNode(checkPoint.p)
				
				local entity2 = newEdge(splitNode, entity.comp.node1)
				trace("Sub split discovered at t=",t, " created new entity",entity2.entity," from splitting ",entity.entity, " isSecondOrder=",isSecondOrder, "isNode0=",isNode0) 
				local length = vec3.length(t0)
				util.setTangent(entity2.comp.tangent0, (1-t)*length*vec3.normalize(checkPoint.t)) 
				util.setTangent(entity2.comp.tangent1, (1-t)*length*vec3.normalize(t1))
				entity.comp.node1 = splitNode 
				util.setTangent(entity.comp.tangent0, t*t0)
				util.setTangent(entity.comp.tangent1, t*length*vec3.normalize(checkPoint.t))
				if thisNeedsBridge and needsBridge(p0) then 
					entity.comp.type = 1
					entity.comp.typeIndex = cement 
				elseif thisNeedsTunnel and needsTunnel(p0) then 
					entity.comp.type = 2 
					entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
				end
				checkForSubSplits(entity, true, true, maxrecurse-1)
				checkForSubSplits(entity2, true, false, maxrecurse-1)
				break 
			end 
		end
	end
	
	local function buildConnectingCurve(node0, node1, split)
		local edge1 = newNodeToSegmentMap[node0][1]
		local edge2 = newNodeToSegmentMap[node1][1]
		local p0 = nodePos(node0)
		local p1 =nodePos(node1)
		local dist = util.distance(p0,p1 )
		--local r = dist / math.sqrt(2)
		--local deltax = p2.x-p1.x
		local angle = util.signedAngle(util.v3(edge1.comp.tangent1),util.v3(edge2.comp.tangent0))
		local r = dist/(2*math.sin(math.abs(angle/2)))
	
		local length = math.abs(angle)/math.rad(90) * r * 4 * (math.sqrt(2)-1)
		local t0 = length*vec3.normalize(util.v3(edge1.comp.tangent1))
		local t1 = length*vec3.normalize(util.v3(edge2.comp.tangent0))
		local entity
		if split then 
			local isHigh = t0.z > 0 
			trace("Creating split point in connecting curve, isHigh=",isHigh)
			local splitPoint = util.solveForPositionHermiteFraction(0.5, {p0=p0, p1=p1, t0=t0, t1=t1})
			local originalZ = splitPoint.p.z
			if isHigh then 
				splitPoint.p.z = math.min(math.max(splitPoint.p.z, maxHeight+9), maxHeight+15)
			else 
				splitPoint.p.z = math.max(math.min(splitPoint.p.z, minHeight-9), minHeight-15)
				if splitPoint.p.z < 5 and util.th(splitPoint.p) < 0 then 
					splitPoint.p.z = 5
					splitPoint.t.z = 0 
					trace("correcting point potentially underwater") 
					local isNode0 = p0.z < p1.z
					if isNode0 then 
						t0.z = 0 
						edge1.comp.tangent1.z = 0
					else 
						edge2.comp.tangent0.z = 0
						t1.z = 0
					end 
				end 
			end
			if originalZ ~= splitPoint.p.z and false then 
				-- this means we have overshot, try to constrain the gradients of the approaching ramps
				local h = 0.5*(p0.z+p1.z)
				local hAboveZ =  h - baseZ 
				local originalH = originalZ - baseZ 
				local newH = splitPoint.p.z - baseZ 
				local fraction = newH / originalH 
				trace("OriginalZ was ",originalZ," the new z is ",splitPoint.p.z, " fractional change was",fraction, " input heights were",p0.z,p1.z)
				
				local p0h = p0.z - baseZ 
				local p1h = p1.z - baseZ 
				p0.z = baseZ + fraction*p0h
				p1.z = baseZ + fraction*p1h
				newNodeMap[node0].comp.position.z = p0.z 
				newNodeMap[node1].comp.position.z = p1.z
				trace("After correction, the new heights were",p0.z, p1.z)
				edge1.comp.tangent1.z = splitPoint.p.z - p0.z 
				edge2.comp.tangent0.z = p1.z - splitPoint.p.z
			end 
			local splitNode = newNode(splitPoint.p)
			entity = newEdge(node0, splitNode) 
			local entity2 = newEdge(splitNode, node1)
			setTangent(entity.comp.tangent0, 0.5*t0)
			setTangent(entity.comp.tangent1, 0.5*length*vec3.normalize(splitPoint.t))
			setTangent(entity2.comp.tangent0, 0.5*length*vec3.normalize(splitPoint.t))
			setTangent(entity2.comp.tangent1, 0.5*t1)
			if not isHigh then 
				checkAndAdjustTangentsForUnderwater(entity, edge1)
				checkAndAdjustTangentsForUnderwater(entity2, edge2)
			end
			if isHigh then 
				if entity.comp.type == 1 then 
					--entity.comp.typeIndex = api.res.bridgeTypeRep.find("cable.lua")
				end 
				if entity2.comp.type == 1 then 
					--entity2.comp.typeIndex = api.res.bridgeTypeRep.find("cable.lua")
				end 
			end
			checkForSubSplits(entity)
			checkForSubSplits(entity2)
		else 
			entity =  newEdge(node0, node1) 			 
			setTangent(entity.comp.tangent0, t0)
			setTangent(entity.comp.tangent1, t1)
			if entity.comp.type == 1 then 
				local testP = util.hermite(0.5,p0, t0, p1, t1).p 
				if testP.z - util.th(testP) < 5 then 
					trace("Removing bridge due to low height, testP.z=",testP.z, " th=",util.th(testP), " p0.z=",p0.z," p1.z=",p1.z, " testP=",testP.x, testP.y)
					entity.comp.type = 0 
					entity.comp.typeIndex = -1
				end
			end
			checkForSubSplits(entity)
		end
		
	
		local segLength = util.calcEdgeLength(p0, p1, t0, t1) 
		
		trace("Building connecting curve, r was",r, " the length was ",length," the calculated segLength was",segLength, " entity ",entity.entity, " split?",split," connecting ",node0, node1)
	end 
	local offsetIdx = 3 
	
	local function getCrossingEdgeIdx(edges) 
		for i = 2, #edges-1 do 
			if vec2.distance(util.getEdgeMidPoint(edges[i]), crossingPoint) > params.minJunctionDistance and 
				util.calculateSegmentLengthFromEdge(util.getEdge(edges[i])) > params.targetMinLength 
				and not util.isJunctionEdge(edges[i-1])
				and not util.isJunctionEdge(edges[i])
				and not util.isJunctionEdge(edges[i+1]) then 
				trace("returning the edge at ",i)
				return i
			end
		end 
		return #edges
	end
	
	local edgesToRebuild = {}
	
	local function getCrossingEdge(edges, offset)
		if not offset then offset = 0 end
		local idx = getCrossingEdgeIdx(edges)+offset
		idx = math.min(idx, #edges)
		while idx < #edges and (idx < 1 or util.calculateSegmentLengthFromEdge(util.getEdge(edges[idx]))) < params.targetMinLength do 
			idx = idx + 1
		end
		for i = 1, idx do 
			trace("About to get edge at ",i, " of ",#edges)
			if util.getEdge(edges[i]).type==1 then 
				if not edgesToRebuild[edges[i]] then 
					edgesToRebuild[edges[i]]=true 
				end
			end
		end 
		return edges[idx]
	end 
	
	local n1 = buildEntryExit(getCrossingEdge(leftMainLineEdges.outboundEdges), true, zoffHigh ) 
	local n2 = buildEntryExit(getCrossingEdge(leftMainLineEdges.inboundEdges), false,zoffLow ) 
	local n3 = buildEntryExit(getCrossingEdge(rightMainLineEdges.outboundEdges), true, zoffHigh ) 
	local n4 = buildEntryExit(getCrossingEdge(rightMainLineEdges.inboundEdges), false,zoffLow ) 
	
	local n5 = buildEntryExit(getCrossingEdge(leftPerpLineEdges.outboundEdges), true, zoffLow ) 
	local n6 = buildEntryExit(getCrossingEdge(leftPerpLineEdges.inboundEdges), false,zoffHigh ) 
	local n7 = buildEntryExit(getCrossingEdge(rightPerpLineEdges.outboundEdges), true, zoffLow ) 
	local n8 = buildEntryExit(getCrossingEdge(rightPerpLineEdges.inboundEdges), false,zoffHigh ) 
	
	buildConnectingCurve(n1, n8, true)
	buildConnectingCurve(n5, n2, true)
	buildConnectingCurve(n3, n6, true)
	buildConnectingCurve(n7, n4, true)
	
	local n9 = buildEntryExit(getCrossingEdge(leftMainLineEdges.outboundEdges,1), true ) 
	local n10 = buildEntryExit(getCrossingEdge(leftMainLineEdges.inboundEdges,1), false) 
	local n11 = buildEntryExit(getCrossingEdge(rightMainLineEdges.outboundEdges,1), true ) 
	local n12 = buildEntryExit(getCrossingEdge(rightMainLineEdges.inboundEdges,1), false ) 
	
	local n13 = buildEntryExit(getCrossingEdge(leftPerpLineEdges.outboundEdges,1), true) 
	local n14 = buildEntryExit(getCrossingEdge(leftPerpLineEdges.inboundEdges,1), false) 
	local n15 = buildEntryExit(getCrossingEdge(rightPerpLineEdges.outboundEdges,1), true) 
	local n16 = buildEntryExit(getCrossingEdge(rightPerpLineEdges.inboundEdges,1), false) 
	
	
	buildConnectingCurve(n9, n14)
	buildConnectingCurve(n15, n10)
	buildConnectingCurve(n11, n16)
	buildConnectingCurve(n13, n12)
	
	for edgeId, bool in pairs(edgesToRebuild) do -- needed to reposition bridge pillars 
		table.insert(edgesToAdd, util.copyExistingEdge(edgeId, nextEdgeId()))
		table.insert(edgesToRemove, edgeId)
	end
	
	local countryEdges ={}
	local alreadySeen = {}
	local reroutes = {} 
	local removedNodeToSegmentMap = {}
	local function addToRemovedMap(edgeId) 
		local edge = util.getEdge(edgeId)
		for __, node in pairs({edge.node0, edge.node1}) do 
			if not removedNodeToSegmentMap[node] then 
				removedNodeToSegmentMap[node] = {}
			end 
			table.insert(removedNodeToSegmentMap[node], edgeId)
		end
	end
	
	local function findConnectedEdges(nextEdgeId, nextNode) 
		local result = {}
		repeat 
			if not alreadySeen[nextEdgeId] then 
				table.insert(result, nextEdgeId)
				table.insert(edgesToRemove, nextEdgeId)
				alreadySeen[nextEdgeId] = true
				addToRemovedMap(nextEdgeId)
			end 
			local segs = util.getStreetSegmentsForNode(nextNode)
			if #segs ~= 2 then break end 
			nextEdgeId = nextEdgeId == segs[1] and segs[2] or segs[1] 
			local nextEdge = util.getEdge(nextEdgeId) 
			nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
		until util.distance(util.getEdgeMidPoint(nextEdgeId), crossingPoint) > 350 
		return result
	end
	if not params.disableRerouting then 
		for edgeId, edge in pairs(util.searchForEntities(crossingPoint, 200, "BASE_EDGE")) do 
			if not alreadySeen[edgeId] and not edge.track and util.getStreetTypeCategory(edgeId) ~= "highway" then 
				trace("Creating reroute starting from ",edgeId)
				local newReroute = {}
				newReroute.leftEdges = findConnectedEdges(edgeId, edge.node0) 
				newReroute.rightEdges = findConnectedEdges(edgeId, edge.node1) 
				table.insert(reroutes, newReroute)
			end 
		end
	end
	
	for __, reroute in pairs(reroutes) do 
		trace("Begin setting up reroute, there were ",#reroute.leftEdges," left edges and ",#reroute.rightEdges," right edges")
		local startEdgeId = reroute.leftEdges[#reroute.leftEdges]
		if not startEdgeId then 
			startEdgeId = reroute.rightEdges[1]
		end
		local startEdge = util.getEdge(startEdgeId) 
		--local secondEdgeId = #reroute.leftEdges > 1 and reroute.leftEdges[1-#reroute.leftEdges] or reroute.rightEdges[1]
		--if not secondEdgeId then 
			
		--	local idx = util.indexOf(edgesToRemove, startEdgeId) 
		--	trace("could not find a second edge for a route with ",startEdgeId, " removing from table at idx",idx) 
		--	if idx ~= -1 then 
		--		table.remove(edgesToRemove, idx)
		--	end
		--	break 
		--end
		--local nextEdge = util.getEdge(secondEdgeId) 
		--local startNode = (startEdge.node0 == nextEdge.node0 or startEdge.node0 == nextEdge.node1) and startEdge.node1 or startEdge.node0 
		local startNode = #removedNodeToSegmentMap[startEdge.node0] == 1 and startEdge.node0 or startEdge.node1
		local startTangent = startNode == startEdge.node0 and util.v3(startEdge.tangent0) or -1*util.v3(startEdge.tangent1)
		local endEdgeId = reroute.rightEdges[#reroute.rightEdges]
		if not endEdgeId then 
			endEdgeId = reroute.leftEdges[1]
		end
		local endEdge = util.getEdge(endEdgeId) 
		--local penultimateEdgeId = #reroute.rightEdges > 1 and reroute.rightEdges[1-#reroute.rightEdges] or reroute.leftEdges[1]
		--local penultimateEdge = util.getEdge(penultimateEdgeId)
		--local endNode = (endEdge.node0 == penultimateEdge.node0 or startEdge.node0 == penultimateEdge.node1) and endEdge.node1 or endEdge.node0 
		local endNode = #removedNodeToSegmentMap[endEdge.node0] == 1 and endEdge.node0 or endEdge.node1
		if startNode == endNode then 
			trace("WARNING! startNode and endNode were equal, aborting ",startNode)
			goto continue 
		end
		local endTangent = endNode == endEdge.node0 and -1*util.v3(endEdge.tangent0) or util.v3(endEdge.tangent1)
		trace("The startEdgeId was ",startEdgeId, " the end edgeId was ",endEdgeId)
		local entityTemplate = util.copyExistingEdge(startEdgeId, nextEdgeId())
		local targetHeight = minNodeHeight - params.minZoffsetRoad
		local dist = util.distBetweenNodes(startNode, endNode)
		local dummyEdge = {
			p0 = util.nodePos(startNode),
			p1 = util.nodePos(endNode),
			t0 = dist*vec3.normalize(startTangent),
			t1 = dist*vec3.normalize(endTangent)
		}
		local splits = math.ceil(dist / params.targetSeglenth)
		local segLength  = dist / splits
		local lastNode = startNode
		local lastP = util.nodePos(startNode)
		local lastT = startTangent
		local endNodePos = util.nodePos(endNode)
		for i = 1, splits do 
			local frac = i/(splits+1)
			local splitPoint = util.solveForPositionHermiteFraction(frac, dummyEdge)
			
			local p = splitPoint.p 
			p.z = math.max(math.min(p.z, targetHeight), lastP.z - 8)
			p.z = math.max(p.z, endNodePos.z-0.1*util.distance(p, endNodePos ))
			trace("Setting the p.z to ",p.z)
			local node =  newNode(p) 
			local entity = newEdge(lastNode, node, entityTemplate.streetEdge.streetType)
			trace("Setting up new split point at ",frac," actual hermiteFraction was ",splitPoint.f, " created new entity",entity.entity)
			util.setTangent(entity.comp.tangent0, segLength*vec3.normalize(lastT))
			util.setTangent(entity.comp.tangent1, segLength*vec3.normalize(splitPoint.t))
			lastNode = node 
			lastT = splitPoint.t
			lastP = p
		end 
		local entity = newEdge(lastNode, endNode, entityTemplate.streetEdge.streetType)
		util.setTangent(entity.comp.tangent0, segLength*vec3.normalize(lastT))
		util.setTangent(entity.comp.tangent1, segLength*vec3.normalize(endTangent))
		trace("Setup reroute for crossing junction, the startNode was", startNode," the endNode was ",endNode, " last entity was ",entity.entity)
		::continue::
	end
	
	
	--local n3 = buildEntryExit(rightMainLineEdges.outboundEdges[2], false,  -zoff  ) 
	--local n4 = buildEntryExit(rightMainLineEdges.inboundEdges[2], true,  -zoff  ) 
	 
	
	
	--[[
	local n5 = buildEntryExit(tEdgeLeft.entity, true, 0) 
	local n6 = buildEntryExit(tEdgeRight.entity, false, 0 ) 
	
	buildConnectingCurve(n5, n3)
	buildConnectingCurve(n1, n6)
	buildConnectingCurve(n4, connectRight)
	buildConnectingCurve(connectLeft, n2)
	]]--
	
	local errFn = util.tracelog and routeBuilder.err or err -- the former provides a ui throwup
	local newProposal 
	xpcall(function() newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) end, errFn)
	if not newProposal then 
		return false 
	end
	
	--debugPrint(newProposal)
	local debugInfo = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	local ignoreErrors = params.ignoreErrors
	if util.tracelog  then debugPrint({ collisionInfo = debugInfo.collisionInfo , errorState = debugInfo.errorState}) end
	if debugInfo.errorState.critical   then 
		if util.tracelog and params.disableRerouting and false then 
			routeBuilder.setupProposalAndDeconflict(cloneNodesToLua(nodesToAdd), cloneEdgesToLua(edgesToAdd), edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, true)
		end
		return false 
	end
	if #debugInfo.errorState.messages > 0 and not ignoreErrors then 
		if #debugInfo.errorState.messages==1 and debugInfo.errorState.messages[1]=="Bridge pillar collision" then
			ignoreErrors = true
		else 
			return false
		end
	end
	trace("About to build command to 4 way highway junction")
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors)
	trace("About to send command to build  4 way highway junction")
	util.clearCacheNode2SegMaps()
	api.cmd.sendCommand(build, function(res, success) 
		trace("Result of building  4 way highway junction ",success)
		if success then 
			routeBuilder.addWork(function() routeBuilder.postBuildCheckEdgeTypes(res ) end)
		end 
		--callback(res, success)
	end)
	return true
end
function routeBuilder.tryBuildCrossoverConnect( station, otherStation, params, callback, stationTangent, xoverExitTangent, hasCollision, maxAngle)
	trace("buildCrossoverConnect: begin")
	util.lazyCacheNode2SegMaps()
	local midPos = vec3.new(0,0,0)
	for i, nodePos in pairs(params.crossoverNodes[station]) do 
		midPos = midPos + nodePos 
	end 
	midPos = (1/#params.crossoverNodes[station])* midPos 
	
	 
	local angleToVector = util.signedAngle(xoverExitTangent, util.vecBetweenStations(otherStation, station))
	
	
	local correctionAngle = 0 
	if math.abs(angleToVector) > math.rad(10) then 
		if angleToVector > 0 then 	
			correctionAngle = math.min(angleToVector- math.rad(10), maxAngle)
		else 
			correctionAngle = math.max(angleToVector+ math.rad(10), -maxAngle)
		end 
	end
	if hasCollision then 
		local originalCorrectionAngle = correctionAngle
		correctionAngle = 0
		for i = 10, 180, 10 do 
			local testP = i*vec3.normalize(xoverExitTangent)+midPos 
			if util.searchForFirstEntity(testP, 10, "BASE_EDGE", function(edge) return edge.track end) then 
				trace("Found collision, adjusting")
				if originalCorrectionAngle > 0 then 
					correctionAngle = -maxAngle 
				else 
					correctionAngle = maxAngle 
				end
				break
			end 
		end 
	end
		
	
	trace("buildCrossoverConnect: The angleToVector was ",math.deg(angleToVector), " the correctionAngle was",math.deg(correctionAngle))
	local positionTangent = util.rotateXY(xoverExitTangent, correctionAngle/2)
	local exitTangent = util.rotateXY(xoverExitTangent, correctionAngle)
	local overallLength = 180*(1+math.sin(math.abs(correctionAngle/2)))
	exitTangent = overallLength*vec3.normalize(exitTangent) 
	xoverExitTangent  = overallLength*vec3.normalize(xoverExitTangent) 
	local exitPos = midPos - overallLength*vec3.normalize(positionTangent) 
	
	if hasCollision then 
		local zavg = 0
		local zmin = math.huge
		local zmax = 0
		local hasWaterPoints = util.isUnderwater(exitPos)
		local nodes = util.searchForEntities(exitPos, 150, "BASE_NODE")
		for i, node in pairs(nodes) do 
			zavg = zavg + node.position[3]
			if util.th(util.v3fromArr(node.position)) < 0 then 	
				hasWaterPoints = true 
			end 
			zmin = math.min(zmin,node.position[3])
			zmax = math.max(zmax,node.position[3])
		end
		local size = util.size(nodes)
		if size >0 then 
			zavg = zavg / size 
			local weAreHigher = exitPos.z > zavg
			local canGoUnder = true 
			if hasWaterPoints and zmin < 15 then 
				trace("buildCrossoverConnect: determined cannot go under because had water points and zmin was",zmin)
				canGoUnder = false
			end 
			local maxCorrection = 15
			local correction 
			if weAreHigher or not canGoUnder then 
				local minHeight = zmax + 10
				correction = math.min(math.max(minHeight-midPos.z, 0), maxCorrection)
			else 
				local maxHeight = zmin - 10
				correction = math.max(math.min(maxHeight-midPos.z,0), -maxCorrection)
			end 
			trace("buildCrossoverConnect: To resolve collision conflict correction of",correction," is being applied. weAreHigher?",weAreHigher," canGoUnder?",canGoUnder)
			exitPos.z = exitPos.z + correction
		end
		
	end 
	
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local newNodeMap = {}
	
	local function addNode(newNode) 
		table.insert(nodesToAdd, newNode)
		newNodeMap[newNode.entity]=newNode
	end
	local function nodePos(node) 
		if node > 0 then 
			return util.nodePos(node) 
		else 
			return util.v3(newNodeMap[node].comp.position)
		end 
	end 
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local nodeId = -10000
	
	local function nextNodeId() 
		nodeId = nodeId - 1
		return nodeId
	end
	local trackWidth = params.trackWidth
	local exitNode1 = newNodeWithPosition(util.nodePointPerpendicularOffset(exitPos, exitTangent, 1.5*trackWidth), nextNodeId())
	local exitNode2 = newNodeWithPosition(util.nodePointPerpendicularOffset(exitPos, exitTangent, 0.5*trackWidth), nextNodeId())
	local exitNode3 = newNodeWithPosition(util.nodePointPerpendicularOffset(exitPos, exitTangent, -0.5*trackWidth), nextNodeId())
	local exitNode4 = newNodeWithPosition(util.nodePointPerpendicularOffset(exitPos, exitTangent, -1.5*trackWidth), nextNodeId())
	addNode(exitNode1)
	addNode(exitNode2)
	addNode(exitNode3)
	addNode(exitNode4)
	
	local function setEdgeTypes(excludeEdges) 
		if not excludeEdges then excludeEdges = {} end
		for i , newEdge in pairs(edgesToAdd) do 
			if excludeEdges[newEdge.entity] then goto continue end
			local p0 = nodePos(newEdge.comp.node0)
			local p1 = nodePos(newEdge.comp.node1)	
			local maxP0Height = math.max(util.th(p0), util.th(p0, true))
			local maxP1Height = math.max(util.th(p1), util.th(p1, true))
			local minP0Height = math.min(util.th(p0), util.th(p0, true))
			local minP1Height = math.min(util.th(p1), util.th(p1, true))
			local needsBridge = minP0Height <0 or minP1Height < 0 or p0.z - minP0Height > 10 and p1.z - minP1Height > 10
			local needsTunnel = maxP0Height - p0.z > 10 and maxP1Height - p1.z > 10
			if needsBridge then 
				newEdge.comp.type = 1
				newEdge.comp.typeIndex = routeBuilder.getBridgeType()
			elseif needsTunnel then 
				newEdge.comp.type = 2
				newEdge.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
			else 
				newEdge.comp.type = 0
				newEdge.comp.typeIndex = -1
			end			
			::continue::
		end 
	end 
	
	local node1 =  util.searchForNearestNode(util.nodePointPerpendicularOffset(midPos, xoverExitTangent, 2*trackWidth)).id
	local node2 =  util.searchForNearestNode(util.nodePointPerpendicularOffset(midPos, xoverExitTangent,  trackWidth)).id
	local node3 =  util.searchForNearestNode(util.nodePointPerpendicularOffset(midPos, xoverExitTangent, -trackWidth)).id
	local node4 =  util.searchForNearestNode(util.nodePointPerpendicularOffset(midPos, xoverExitTangent, -2*trackWidth)).id
	--[[if correctionAngle < 0 then 
		trace("Swapping nodes")
		local temp = node1 
		node1 = node3 
		node3 = temp 
		temp = node2 
		node2 = node4 
		node4 = temp 
		temp = exitNode1 
		exitNode1 = exitNode3 
		exitNode3 = temp 
		temp = exitNode2 
		exitNode2 = exitNode4 
		exitNode4 = temp 
	end]]--
	

	
	trace("The nodes were",node1,node2,node3,node4," midPos was at ",midPos.x, midPos.y, " exit nodes:",exitNode1,exitNode2,exitNode3,exitNode4)
	local edge4 = {
		p0 = util.v3(exitNode4.comp.position),
		p1 = util.nodePos(node4),
		t0 = exitTangent, 
		t1 = xoverExitTangent
		
	}
	local s = util.solveForPositionHermiteFraction(0.3, edge4)
	local linkNode =  newNodeWithPosition(s.p, nextNodeId())
	addNode(linkNode)
	local newEdge1 = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	newEdge1.comp.node0 = exitNode4.entity 
	newEdge1.comp.node1 = linkNode.entity 
	newEdge1.comp.objects = {}
	util.setTangent(newEdge1.comp.tangent0, s.t0)
	util.setTangent(newEdge1.comp.tangent1, s.t1)
	table.insert(edgesToAdd, newEdge1)
	local ss = util.solveForPositionHermiteFraction(0.7, edge4)
 
	local linkNode2 =  newNodeWithPosition(ss.p, nextNodeId())
	addNode(linkNode2)
	local newEdge2 = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	newEdge2.comp.node0 = linkNode2.entity 
	newEdge2.comp.node1 = node4
	newEdge2.comp.objects = {}
	util.setTangent(newEdge2.comp.tangent0, ss.t2)
	util.setTangent(newEdge2.comp.tangent1, ss.t3)
	table.insert(edgesToAdd, newEdge2)
	local outerEdge = copySegmentAndEntity(newEdge1, nextEdgeId())
	outerEdge.comp.node0 = linkNode.entity 
	outerEdge.comp.node1 = linkNode2.entity 
	local midLength = util.calculateTangentLength(s.p, ss.p, s.t1, ss.t2)
	util.setTangent(outerEdge.comp.tangent0, midLength*vec3.normalize(s.t1))
	util.setTangent(outerEdge.comp.tangent1, midLength*vec3.normalize( ss.t2))
	table.insert(edgesToAdd, outerEdge)
	
	
	local edge1 = {
		p0 = util.v3(exitNode1.comp.position),
		p1 = util.nodePos(node1),
		t0 = exitTangent, 
		t1 = xoverExitTangent
		
	}
	
	local xoverEdge1 = {
		p0 = util.v3(exitNode2.comp.position),
		p1 = util.nodePos(node3),
		t0 = exitTangent, 
		t1 = xoverExitTangent
		
	}
	
	local xoverEdge2 = {
		p0 = util.v3(exitNode3.comp.position),
		p1 = util.nodePos(node2),
		t0 = exitTangent, 
		t1 = xoverExitTangent
		
	}
	local zoff = 4
	local s1 = util.solveForPositionHermiteFraction(0.3, edge1)
	s1.p.z = s1.p.z+zoff
	s1.p = util.nodePointPerpendicularOffset(s1.p, s1.t1,  0.75*params.trackWidth)
	s1.t1.z = s1.t1.z+zoff
	--s1.t1 = util.rotateXYkeepingZ(s1.t1, -math.rad(5))
	 
	local xoverNode1 = newNodeWithPosition(s1.p, nextNodeId())
	
	addNode(xoverNode1)
	local newEdge3 = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	newEdge3.comp.node0 = exitNode1.entity 
	newEdge3.comp.node1 = xoverNode1.entity
	newEdge3.comp.objects = {}
	util.setTangent(newEdge3.comp.tangent0, s1.t0)
	util.setTangent(newEdge3.comp.tangent1, s1.t1)
	table.insert(edgesToAdd, newEdge3)
	local s2 = util.solveForPositionHermiteFraction(0.7, xoverEdge1)
	s2.p.z = s2.p.z+zoff
	s2.t2.z = s2.t2.z-zoff
	--s2.p = util.nodePointPerpendicularOffset(s2.p, s2.t1,  -0.15*params.trackWidth)
	local newEdge4 = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	
	local xoverNode2 = newNodeWithPosition(s2.p, nextNodeId())
	addNode(xoverNode2)
	newEdge4.comp.node0 = xoverNode2.entity 
	newEdge4.comp.node1 = node3
	newEdge4.comp.objects = {}
	util.setTangent(newEdge4.comp.tangent0, s2.t2)
	util.setTangent(newEdge4.comp.tangent1, s2.t3)
	table.insert(edgesToAdd, newEdge4)
	
	local edgeOver = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	edgeOver.comp.node0 = xoverNode1.entity 
	edgeOver.comp.node1 = xoverNode2.entity
	edgeOver.comp.objects = {}
	util.setTangent(edgeOver.comp.tangent0, 0.5*overallLength*vec3.normalize(s1.t1))
	util.setTangent(edgeOver.comp.tangent1, 0.5*overallLength*vec3.normalize(s2.t2))
	table.insert(edgesToAdd, edgeOver)
	
	local s3 = util.solveForPositionHermiteFraction(0.3, xoverEdge2)
	s3.p.z = s3.p.z-zoff
	--s3.p = util.nodePointPerpendicularOffset(s3.p, s3.t1, -params.trackWidth/2)
	s3.t1.z = s3.t1.z-zoff
	local xoverNode3 = newNodeWithPosition(s3.p, nextNodeId())
	addNode(xoverNode3)
	local newEdge5 = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	newEdge5.comp.node0 = exitNode3.entity 
	newEdge5.comp.node1 = xoverNode3.entity
	newEdge5.comp.objects = {}
	util.setTangent(newEdge5.comp.tangent0, s3.t0)
	util.setTangent(newEdge5.comp.tangent1, s3.t1)
	table.insert(edgesToAdd, newEdge5)
	local s4 = util.solveForPositionHermiteFraction(0.7, xoverEdge2)
	s4.p.z = s4.p.z-zoff
	s4.t2.z = s4.t2.z+zoff
	local xoverNode4 = newNodeWithPosition(s4.p, nextNodeId())
	addNode(xoverNode4)
	local newEdge6 = util.copyExistingEdge(util.getTrackSegmentsForNode(node1)[1], nextEdgeId())
	newEdge6.comp.node0 = xoverNode4.entity 
	newEdge6.comp.node1 = node2
	newEdge6.comp.objects = {}
	util.setTangent(newEdge6.comp.tangent0, s4.t2)
	util.setTangent(newEdge6.comp.tangent1, s4.t3)
	table.insert(edgesToAdd, newEdge6)
	
	setEdgeTypes()
	local excludeEdges = {}
	
	local edgeUnder = copySegmentAndEntity(edgeOver, nextEdgeId())
	edgeUnder.comp.node0 = xoverNode3.entity 
	edgeUnder.comp.node1 = xoverNode4.entity 
	util.setTangent(edgeUnder.comp.tangent0, 0.5*overallLength*vec3.normalize(s3.t1))
	util.setTangent(edgeUnder.comp.tangent1, 0.5*overallLength*vec3.normalize(s4.t2))
	if edgeOver.comp.type == 0 then 
		edgeUnder.comp.type = 2 
		edgeUnder.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
		excludeEdges[edgeUnder.entity]=true
	end 
	table.insert(edgesToAdd, edgeUnder)
	
	local newEdge7 = copySegmentAndEntity(newEdge5, nextEdgeId())
	local xoverNode5 = newDoubleTrackNode(s3.p, s3.t, nextNodeId())
	addNode(xoverNode5)
	newEdge7.comp.node0 = exitNode2.entity 
	newEdge7.comp.node1 = xoverNode5.entity 
	 table.insert(edgesToAdd, newEdge7)
	local newEdge8 = copySegmentAndEntity(newEdge6, nextEdgeId())
	local xoverNode6 = newDoubleTrackNode(s4.p, s4.t, nextNodeId())
	addNode(xoverNode6)
	newEdge8.comp.node0 = xoverNode6.entity 
	newEdge8.comp.node1 = node1
	 table.insert(edgesToAdd, newEdge8)
	
	local edgeUnder2 = copySegmentAndEntity(edgeUnder, nextEdgeId())
	edgeUnder2.comp.node0 = xoverNode5.entity 
	edgeUnder2.comp.node1 = xoverNode6.entity
	table.insert(edgesToAdd, edgeUnder2)
	if excludeEdges[edgeUnder.entity] then 
		excludeEdges[edgeUnder2.entity]=true
	end
	
	local depotConstr = routeBuilder.constructionUtil.searchForRailDepot(util.nodePos(node1), params.stationLength+100)
	local depotNode 
	if depotConstr then 
		depotNode = util.getFreeNodesForConstruction(depotConstr)[1]
	end
	trace("buildCrossoverConnect: Depot construction was ",depotConstr, " depotNode=",depotNode)
	setEdgeTypes(excludeEdges)
	if depotConstr and #util.getTrackSegmentsForNode(depotNode)==1 and util.isStationTerminus(station) and #util.getStation(station).terminals==4  and math.abs(correctionAngle) < math.rad(5) then 
		
		local terminalNodeMap = util.getTerminalToFreeNodesMapForStation(station)
		local highestTerminal = 0
		for terminalId, nodes in pairs(terminalNodeMap) do 
			highestTerminal = math.max(highestTerminal, terminalId)		
		end 
		local stationExitNode = terminalNodeMap[highestTerminal][1]
		local depotLinkNode = newNodeWithPosition(util.nodePointPerpendicularOffset(util.nodePos(stationExitNode), stationTangent, 4*params.trackWidth), nextNodeId())
		addNode(depotLinkNode)
		local expressDepotLink = copySegmentAndEntity(newEdge8, nextEdgeId())
		expressDepotLink.comp.node0 = xoverNode6.entity 
		expressDepotLink.comp.node1 = depotLinkNode.entity 
		local length = util.calculateTangentLength(util.v3(xoverNode6.comp.position),util.v3(depotLinkNode.comp.position), s4.t3, stationTangent)
		util.setTangent(expressDepotLink.comp.tangent0, length*vec3.normalize(s4.t2))
		util.setTangent(expressDepotLink.comp.tangent1, length*vec3.normalize(stationTangent))
		table.insert(edgesToAdd, expressDepotLink)
		local slowDepotLink = copySegmentAndEntity(edgeOver, nextEdgeId())
		slowDepotLink.comp.node0 = xoverNode1.entity
		slowDepotLink.comp.node1 = depotLinkNode.entity 
		local length = util.calculateTangentLength(util.v3(xoverNode1.comp.position),util.v3(depotLinkNode.comp.position), s1.t1, stationTangent)
		util.setTangent(slowDepotLink.comp.tangent0, length*vec3.normalize(s1.t1))
		util.setTangent(slowDepotLink.comp.tangent1, length*vec3.normalize(stationTangent))
		table.insert(edgesToAdd, slowDepotLink)
		local depotLink = copySegmentAndEntity(expressDepotLink, nextEdgeId())
		depotLink.comp.node0 = depotLinkNode.entity 
		depotLink.comp.node1 = depotNode
		local length = util.distance(util.nodePos(depotNode),util.v3(depotLinkNode.comp.position))
		util.setTangent(depotLink.comp.tangent0, length*vec3.normalize(stationTangent))
		util.setTangent(depotLink.comp.tangent1, length*vec3.normalize(stationTangent))
		table.insert(edgesToAdd, depotLink)
		if not params.connectedDepots then 
			params.connectedDepots = {}
		end
		params.connectedDepots[depotConstr]=true
	end 
	local left = true
	buildSignal(edgeObjectsToAdd, newEdge2, not left, 0.9)
	buildSignal(edgeObjectsToAdd, newEdge4, left, 0.9)
	buildSignal(edgeObjectsToAdd, newEdge6, not left, 0.9)
	buildSignal(edgeObjectsToAdd, newEdge8, left, 0.9)
	
	
	
	if newEdge7.comp.type == 2 then 
		local s1 = util.solveForPositionHermiteFractionProposalEdge(0.1, newEdge7, nodePos )
		local newP = util.nodePointPerpendicularOffset(s1.p, s1.t, params.trackWidth)
		local newNode = newNodeWithPosition(newP, nextNodeId())
		addNode(newNode)
		local introEdge = copySegmentAndEntity(newEdge3, nextEdgeId())
		table.insert(edgesToAdd, introEdge)
		introEdge.comp.node1 = newNode.entity 
		newEdge3.comp.node0 = newNode.entity 
		setTangent(introEdge.comp.tangent1, s1.t)
		setTangent(newEdge3.comp.tangent0, s1.t)
		
		local s2 = util.solveForPositionHermiteFractionProposalEdge(0.1, newEdge5, nodePos )
		local newP = util.nodePointPerpendicularOffset(s2.p, s2.t, -params.trackWidth)
		local newNode = newNodeWithPosition(newP, nextNodeId())
		addNode(newNode)
		local introEdge = copySegmentAndEntity(newEdge1, nextEdgeId())
		table.insert(edgesToAdd, introEdge)
		introEdge.comp.node1 = newNode.entity 
		newEdge1.comp.node0 = newNode.entity 
		setTangent(introEdge.comp.tangent1, s2.t)
		setTangent(newEdge1.comp.tangent0, s2.t)
		
		
	end
	
	
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	
	if not params.connectNodes then 
		params.connectNodes = {} 
	end 
 
	params.connectNodes[station] = {}
	table.insert(params.connectNodes[station], util.v3(exitNode2.comp.position))
	table.insert(params.connectNodes[station], util.v3(exitNode3.comp.position))
	
	if util.tracelog then 
		debugPrint(newProposal)
	end
	local testData = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if testData.errorState.critical then 
		trace("Critical error found in test data, aborting")
		return false 
	end 
	
	trace("About to build command to crossover connect")
	
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(),true)
	trace("About to send command to build     crossover connect")
	util.clearCacheNode2SegMaps()
	
	api.cmd.sendCommand(build, function(res, success) 
		trace("Result of building crossover connect",success)
		callback(res, success)
	end)
	return true 
end

function routeBuilder.buildCrossoverConnect( station, otherStation, params, callback, stationTangent, xoverExitTangent, hasCollision) 
	local maxAngle = math.rad(20)
	local success
	for maxAngle = 20, 0, -1 do 
		success = routeBuilder.tryBuildCrossoverConnect( station, otherStation, params, callback, stationTangent, xoverExitTangent, hasCollision, math.rad(maxAngle))
		trace("Attempt to buildCrossoverConnect at maxAngle=",maxAngle,"success?",success)
		if success then 
			break 
		end 
	end 
	if not success then 
		callback(false, {})
	end 
end 

function routeBuilder.buildCrossover( station, otherStation, params, callback, stationFreeNodes, rightHanded ) 
	if not routeBuilder.tryBuildCrossover2( station, otherStation, params, callback, stationFreeNodes, rightHanded ) then 
		if not routeBuilder.tryBuildCrossover2( station, otherStation, params, callback, stationFreeNodes, rightHanded, true ) then 
			routeBuilder.tryBuildCrossover2( station, otherStation, params, callback, stationFreeNodes, rightHanded, true, true ) 
		end 
	end 
end
function routeBuilder.tryBuildCrossover2( station, otherStation, params, callback, stationFreeNodes, rightHanded, suppressDepot, safeMode ) 
	local maxAngleDeg = 30
	if params.isQuadrupleTrack then -- N.B. both crossovers need to have the same angle 
		maxAngleDeg = 20
	end 
	for i = maxAngleDeg, 0, -1 do 
		local maxAngle = math.rad(i)
		if routeBuilder.tryBuildCrossover3( station, otherStation, params, callback, stationFreeNodes, rightHanded, suppressDepot, safeMode, maxAngle ) then 
			return true
		end 
	end 
	return false 
end 

function routeBuilder.tryBuildCrossover3( station, otherStation, params, callback, stationFreeNodes, rightHanded, suppressDepot, safeMode, maxAngle ) 
	trace("tryBuildCrossover3: begin for station",station,"maxAngle=",math.deg(maxAngle))
	util.lazyCacheNode2SegMaps()
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	if not params.crossoverNodes then 
		params.crossoverNodes = {} 
	end
	if not params.crossoverNodes[station] then 
		params.crossoverNodes[station] = {}
	end
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local nodeId = -10000
	
	local function nextNodeId() 
		nodeId = nodeId - 1
		return nodeId
	end
		
	local function addNode(newNode)
		table.insert(nodesToAdd, newNode)
	end 	
	local requiresDoubleXover = false
	if not stationFreeNodes then 
		stationFreeNodes = util.getFreeNodesForFreeTerminalsForStation(station)
		
		if not util.isStationTerminus(station) then 
			local oldStationNodes=  stationFreeNodes
			stationFreeNodes = {} 
			-- get the closest nodes to the other station
			--[[local distToStation = function(node) return util.distance(util.nodePos(node), util.getStationPosition(otherStation)) end
			local closestHalf = util.evaluateAndSortFromSingleScore(util.deepClone(oldStationNodes), distToStation  , #stationFreeNodes/2)
			-- need to preserve original ordering (by terminal)
		 
			
			for i =1 , #oldStationNodes do 
				local node = oldStationNodes[i]
				if util.contains(closestHalf, node) then 
					table.insert(stationFreeNodes, node)
				end 
			end ]]--
			local p = util.getStationPosition(otherStation)
			--local occupiedTerminals = util.
			local terminalToFreeNodesMap = util.getTerminalToFreeNodesMapForStation(station)
			for terminal, nodes in pairs(terminalToFreeNodesMap) do 
				--if #api.engine.system.lineSystem.getLineStopsForTerminal(station, terminal-1)==0 then
				if util.isFreeTerminalOneBased(station, terminal)  then 
					local nodeToUse = util.distance(util.nodePos(nodes[1]),p) < util.distance(util.nodePos(nodes[2]),p) and nodes[1] or nodes[2]
				
					table.insert(stationFreeNodes, nodeToUse)
					p = util.nodePos(nodeToUse) -- need to lock down the side to pick
					 
				end 
			end 
			if util.tracelog then debugPrint({oldStationNodes=oldStationNodes, stationFreeNodes=stationFreeNodes}) end
		end
		local unfilteredStationFreeNodes = stationFreeNodes
		stationFreeNodes = {}
		local nodeToTerminalMap = util.getFreeNodesToTerminalMapForStation(station)
		local sortedResults = util.evaluateAndSortFromSingleScore(unfilteredStationFreeNodes, function(node) return nodeToTerminalMap[node] end )
		for i, node in pairs(sortedResults) do 
			if #util.getSegmentsForNode(node) == 1 then
				table.insert(stationFreeNodes, node) 
			end
		end 
		
		requiresDoubleXover = #stationFreeNodes > 2
	else 
		requiresDoubleXover = true
	end
	trace("For station",station,"there were",#stationFreeNodes)
	local stationTangent = vec3.normalize(-1*util.getDeadEndNodeDetails(stationFreeNodes[1]).tangent)
	local angleToVector = util.signedAngle(stationTangent, util.vecBetweenStations(otherStation, station))
	local depotConstr = routeBuilder.constructionUtil.searchForRailDepot(util.nodePos(stationFreeNodes[1]), params.stationLength+100)
	local depotNode 
	if depotConstr then 
		depotNode = util.getFreeNodesForConstruction(depotConstr)[1]
		if #util.getTrackSegmentsForNode(depotNode)==1 then 
			local tangentDetails = util.getDeadEndNodeDetails(depotNode)
			local angle = math.abs(util.signedAngle(tangentDetails.tangent, -1*stationTangent))
			trace("tryBuildCrossover2: The angle of the depot to the station tangent was ",math.deg(angle))
			if angle > math.rad(90) then 
				trace("The depot is the wrong way, adding another task to connect later")
				depotNode = nil
				routeBuilder.addWork(function() routeBuilder.buildDepotConnection(routeBuilder.standardCallback, depotConstr, params) end)
			else 
				trace("The depot node passed validation")
			end 
		else 
			depotNode = nil
		end 
	end
	local buildDepotConnection = depotNode and not params.isQuadrupleTrack 
	--local maxAngle = buildDepotConnection and math.rad(5) or math.rad(15)
	if safeMode then 
		maxAngle = 0-- math.rad(5)
	end 
	 
	local correctionAngle = 0 
	if math.abs(angleToVector) > math.rad(10) then -- do not want to actually get this to zero as it has to curve into the station at the other end
		if angleToVector > 0 then 	
			correctionAngle = math.min(angleToVector- math.rad(10), maxAngle)
		else 
			correctionAngle = math.max(angleToVector+ math.rad(10), -maxAngle)
		end 
		trace("Set the correctionAngle to",math.deg(correctionAngle),"based on angleToVector=",math.deg(angleToVector))
	end
	local hasCollision = false 
	local ourTerminal = util.getFreeNodesToTerminalMapForStation(station)[stationFreeNodes[1]]
	
	
	if #api.engine.system.lineSystem.getLineStopsForStation(station) > 0 then 
		local terminalToFreeNodes  = util.getTerminalToFreeNodesMapForStation(station) 
		local numTerminals = util.size(terminalToFreeNodes)
		local highestOccupiedTerminal = 1
		local lowestOccupiedTerminal = numTerminals
		local ourNodePos  = util.nodePos(stationFreeNodes[1])
		local otherStationPos = util.getStationPosition(otherStation)
		for terminal, nodes in pairs(terminalToFreeNodes) do 
			if  not util.isFreeTerminalOneBased(station, terminal)  then 
				lowestOccupiedTerminal = math.min(lowestOccupiedTerminal, terminal)
				highestOccupiedTerminal = math.max(highestOccupiedTerminal, terminal)
				for __, node in pairs(nodes) do 
					local outboundTangent 
					for i, seg in pairs(util.getTrackSegmentsForNode(node)) do 
						if util.isFrozenEdge(seg) then 
							local edge = util.getEdge(seg)
							outboundTangent = edge.node0 == node and -1*util.v3(edge.tangent0) or util.v3(edge.tangent1)
							break
						end 
					end 
					local nodePos = util.nodePos(node)
					local testP = 1000*vec3.normalize(outboundTangent)+nodePos -- somewhat simplistic
					if util.checkFor2dCollisionBetweenPoints(ourNodePos, otherStationPos, nodePos, testP) then 
						trace("buildCrossover: Collision found for station",station," to ",otherStation)
						hasCollision = true 
						 break
					end 
					
				end 
			end
		end 
		trace("buildCrossover: ourTerminal=",ourTerminal,"highestOccupiedTerminal=",highestOccupiedTerminal,"lowestOccupiedTerminal=",lowestOccupiedTerminal)
		if ourTerminal < highestOccupiedTerminal and ourTerminal > lowestOccupiedTerminal then 
			trace("forcing hasCollision to false as we are surrounded on both sides")
			hasCollision = false 
		end
		trace("buildCrossover: Completed collision check of ",station," hasCollision?",hasCollision)
	end 
	if hasCollision and not safeMode then 
		-- "correct" in the opposite direction 
		if angleToVector > 0 then		
			correctionAngle = -math.rad(10)
		else 
			correctionAngle = math.rad(10)
		end
	
	end 
	
	trace("buildCrossover: The angleToVector was ",math.deg(angleToVector), " the correctionAngle was",math.deg(correctionAngle))
	local exitTangent = util.rotateXY(stationTangent, correctionAngle)

	--[[if #stationFreeNodes == 3 then 
		trace("3 stationFreeNodes found, attempting to find closest pair")
		if util.tracelog then debugPrint({stationFreeNodesBefore=stationFreeNodes}) end
		local possiblePairs = {}
		for i = 1, #stationFreeNodes do
			for j = 1 , #stationFreeNodes do 
				if i ~= j then 
					table.insert(possiblePairs, {stationFreeNodes[i], stationFreeNodes[j]})
				end
			end
		end
		stationFreeNodes = util.evaluateWinnerFromSingleScore(possiblePairs, function(pair) return util.distBetweenNodes(pair[1], pair[2]) end)
		if util.tracelog then debugPrint({stationFreeNodesAfter=stationFreeNodes}) end
	end ]]

	if #stationFreeNodes > 2 and params.isQuadrupleTrack then
		trace("More than 2 stationFreeNodes detected", #stationFreeNodes)
		if util.tracelog then debugPrint(stationFreeNodes) end
		requiresDoubleXover = true
		local originalStationFreeNodes = stationFreeNodes
		local isQuad = #stationFreeNodes > 3
		stationFreeNodes = {} 
		local nextStationFreeNodes = {} 
		for i = 1, #originalStationFreeNodes do 
			if i <= 2 then 
				table.insert(stationFreeNodes, originalStationFreeNodes[i])
			else 
				table.insert(nextStationFreeNodes, originalStationFreeNodes[i])
			end
		end 
		local originalCallback = callback 
		local count = 0
		 
		callback = function(res, success) 
			if success then 
				count = count + 1
				if count == 2 and isQuad then 
					util.clearCacheNode2SegMaps()
					routeBuilder.addWork(function() routeBuilder.buildCrossoverConnect( station,otherStation, params, originalCallback, stationTangent, exitTangent, hasCollision) end)
				else 
					--originalCallback(res,success) -- don't want to call back here -- too early
				end
			else 
				originalCallback(res, success)
			end 
		end
		local angleToStationFreeNodes = util.signedAngle(stationTangent, util.vecBetweenNodes(stationFreeNodes[1], nextStationFreeNodes[1]))
		rightHanded = angleToStationFreeNodes > 0
		trace("The angle to the stationFreeNodes was",math.deg(angleToStationFreeNodes))
		routeBuilder.addWork(function() routeBuilder.buildCrossover( station, otherStation, params, callback, nextStationFreeNodes, not rightHanded ) end)
		if #stationFreeNodes == 3 then 
			return 
		end
	end 
	if #stationFreeNodes == 1 then 
		trace("WARNING! Only 1 free node found attempting to correct")
		table.insert(stationFreeNodes, util.findDoubleTrackNode(stationFreeNodes[1])) -- belt and braces approach hope it picks the right one otherwise its a hard fail
	end
	
	if #stationFreeNodes == 3 then 
		trace("Three stationFreeNodes found ,attempting to disambiguate")
		local nodePairs = {}
		for i = 1, #stationFreeNodes do 
			for j = 2, #stationFreeNodes do 
				if i~=j then 	
					local node1 = stationFreeNodes[i]
					local node2 = stationFreeNodes[j]
					table.insert(nodePairs, { nodePair = { node1, node2 }, scores = {util.distBetweenNodes(node1, node2)} })
				end 
			end 
		end 
		stationFreeNodes = util.evaluateWinnerFromScores(nodePairs).nodePair
	end 
	
	--assert(#stationFreeNodes==2, " size was"..tostring(#stationFreeNodes).." node="..tostring(stationFreeNodes[1]))
	local stationNode1 = stationFreeNodes[1]
	local stationNode2 = stationFreeNodes[2]
	local exitNode1
	local exitNode2
	
	


	trace("stationNode1=",stationNode1,"stationNode2=",stationNode2, " exitNode1=",exitNode1," exitNode2=", exitNode2)
	local stationNode1Pos = util.nodePos(stationNode1)
	local stationNode2Pos = util.nodePos(stationNode2)
	local perpSign = 1 
	local testP = util.doubleTrackNodePoint(stationNode1Pos, stationTangent)
	local testP2 = util.doubleTrackNodePoint(stationNode1Pos, -1*stationTangent)
	if util.distance(testP, stationNode2Pos) > util.distance(testP2, stationNode2Pos) then 
		perpSign = -1
	end
	local targetLength = 50
	if needsTunnel then targetLength = targetLength - 4 end
	local crossoverLength = targetLength *(1+math.sin(math.abs(correctionAngle)))
	if rightHanded ~= nil then 
		local needsBoost = rightHanded == (correctionAngle > 0)
		local boost = 0 
		if needsBoost then 
			boost = 3*params.trackWidth * math.sin(math.abs(correctionAngle))
		end 
		crossoverLength = crossoverLength + boost
		trace("rightHanded was",rightHanded," correctionAngle=",math.deg(correctionAngle)," needsBoost=",needsBoost, "boost=",boost,"station=",station)
		
	end 
	local positionTangent = util.rotateXY(stationTangent, correctionAngle/2)
	 
	local startPos = stationNode1Pos 
	if util.distance(stationNode1Pos, stationNode2Pos) > 7.5 then 
		startPos = (1/3)*(2*stationNode1Pos+stationNode2Pos)
		trace("High gap detected between station nodes, attempting to compensate, setting to",startPos.x,startPos.y,"from",stationNode1Pos.x,stationNode1Pos.y)
		crossoverLength = 70
	end 
	local crossTangent = crossoverLength*positionTangent 
	local endCrossingNodePos1 = startPos - crossTangent

	local endCrossingNodePos2 = util.doubleTrackNodePoint(endCrossingNodePos1, perpSign*exitTangent) --stationNode2Pos - crossTangent --util.doubleTrackNodePoint(endCrossingNodePos1, -1*exitTangent)
	
	local endCrossingNode1 = newNodeWithPosition(endCrossingNodePos1, nextNodeId())
	table.insert(nodesToAdd, endCrossingNode1)
	local endCrossingNode2 = newNodeWithPosition(endCrossingNodePos2, nextNodeId())
	table.insert(nodesToAdd, endCrossingNode2)
	
	local exitLength = 4
	

	local endTangent = exitLength*exitTangent
	local naturalTangent = endTangent
	if buildDepotConnection then 
		exitLength = 60 
		endTangent = util.rotateXY(exitLength*exitTangent, correctionAngle)
		naturalTangent = util.rotateXY(exitLength*exitTangent, correctionAngle/2)
	end 
	local exitPos1 = endCrossingNodePos1 - naturalTangent
	local exitPos2 = endCrossingNodePos2 - naturalTangent
	
	if params.isQuadrupleTrack then -- don't need the dead end but may create unpleasant tunnel portal without a run-in
		---endTangent = 0.5*endTangent
	end
	
	
	table.insert(params.crossoverNodes[station],exitPos1)
	table.insert(params.crossoverNodes[station],exitPos2)
	if not requiresDoubleXover then 
		if not params.connectNodes then 
			params.connectNodes ={}
		end
		params.connectNodes[station] = {}
		table.insert(params.connectNodes[station], exitPos1)
		table.insert(params.connectNodes[station], exitPos2)
	end
	local needsBridge = util.isUnderwater(endCrossingNodePos1) or util.isUnderwater(endCrossingNodePos2) or endCrossingNodePos1.z - util.minTh(endCrossingNodePos1) > 10 and stationNode1Pos.z - util.minTh(stationNode1Pos) > 0
	
	local needsTunnel = util.maxTh(endCrossingNodePos1) - endCrossingNodePos1.z > 10 
	and util.maxTh(stationNode1Pos) - stationNode1Pos.z > 10
	
	
	
	local function initSegmentAndEntity() 
		local entity = api.type.SegmentAndEntity.new()
		entity.entity = nextEdgeId()
		entity.type= params.isTrack and 1 or 0
		if params.isTrack then
			entity.trackEdge.trackType = params.isHighSpeedTrack and api.res.trackTypeRep.find("high_speed.lua") or api.res.trackTypeRep.find("standard.lua")
			entity.trackEdge.catenary = params.isElectricTrack 
		else 
			entity.streetEdge.streetType = streetType 
			entity.streetEdge.hasBus = params.addBusLanes
			entity.streetEdge.tramTrackType = params.tramTrackType
		end
		local playerOwned = api.type.PlayerOwned.new()
		playerOwned.player = api.engine.util.getPlayer()
		entity.playerOwned = playerOwned
		if needsBridge then 
			entity.comp.type = 1
			entity.comp.typeIndex = routeBuilder.getBridgeType()
		elseif needsTunnel then 
			entity.comp.type = 2
			entity.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
		end 
		
		
		return entity
	end	
	
	if needsTunnel then 
		local introOffset =  -4*stationTangent
		stationNode1Pos = stationNode1Pos + introOffset
		stationNode2Pos = stationNode2Pos + introOffset 
	 
		local replacedStationNode1 = newNodeWithPosition(stationNode1Pos, nextNodeId())
		local replacedStationNode2 = newNodeWithPosition(stationNode2Pos, nextNodeId())
		table.insert(nodesToAdd, replacedStationNode1)
		table.insert(nodesToAdd, replacedStationNode2)
		local shortEdge1 = initSegmentAndEntity()
		table.insert(edgesToAdd, shortEdge1)
		shortEdge1.comp.node0 = replacedStationNode1.entity 
		shortEdge1.comp.node1 = stationNode1
		util.setTangents(shortEdge1, -1*introOffset)
		local shortEdge2 = copySegmentAndEntity(shortEdge1, nextEdgeId())
		table.insert(edgesToAdd, shortEdge2)
		shortEdge2.comp.node0 = replacedStationNode2.entity 
		shortEdge2.comp.node1 = stationNode2
		stationNode1 = replacedStationNode1.entity 
		stationNode2 = replacedStationNode2.entity 
		util.setTangents(shortEdge2, -1*introOffset)
	end
	
	local length = util.calculateTangentLength(stationNode1Pos, endCrossingNodePos1, stationTangent, exitTangent)
	local correctedStationTangent = length * vec3.normalize(stationTangent)
	local correctedExitTangent = length * vec3.normalize(exitTangent)
	local length2 = util.calculateTangentLength(stationNode2Pos, endCrossingNodePos2, stationTangent, exitTangent)
	local correctedStationTangent2 = length2 * vec3.normalize(stationTangent)
	local correctedExitTangent2 = length2 * vec3.normalize(exitTangent)
	
	local straightConnect1 = initSegmentAndEntity() 
	straightConnect1.comp.node0 = endCrossingNode1.entity
	straightConnect1.comp.node1 = stationNode1
	setTangent(straightConnect1.comp.tangent0,correctedExitTangent )
	setTangent(straightConnect1.comp.tangent1,correctedStationTangent)
	table.insert(edgesToAdd, straightConnect1)
	local straightConnect2 = initSegmentAndEntity() 
	straightConnect2.comp.node0 =  endCrossingNode2.entity
	straightConnect2.comp.node1 = stationNode2
	setTangent(straightConnect2.comp.tangent0,correctedExitTangent2 )
	setTangent(straightConnect2.comp.tangent1,correctedStationTangent2)
	table.insert(edgesToAdd, straightConnect2)  
	
	
	 
	 
	
	local maxLength= math.max(length, length2)
	correctedStationTangent = maxLength * vec3.normalize(correctedStationTangent)
	correctedExitTangent = maxLength * vec3.normalize(correctedExitTangent)
	trace("The length used for the crossing was",maxLength)
	local crossingEdge1 = {
		p0=endCrossingNodePos1, 
		p1=stationNode2Pos,
		t0= correctedExitTangent,
		t1=	correctedStationTangent
	}
	local crossingEdge2 = {
		p0=endCrossingNodePos2, 
		p1=stationNode1Pos,
		t0=correctedExitTangent,
		t1=correctedStationTangent	
	}
	util.correctTangentLengthsProposedEdge(crossingEdge1)
	util.correctTangentLengthsProposedEdge(crossingEdge2)
	--local xoverPos = 0.25*(stationNode1Pos+stationNode2Pos+endCrossingNodePos1+endCrossingNodePos2) -- can average positions. Note vec3 does not support division but fractional multiplication is the same thing
	local c  =util.fullSolveForCollisionBetweenProposedEdges(crossingEdge1, crossingEdge2) 
	if util.tracelog then 
		debugPrint({crossingEdge1=crossingEdge1, crossingEdge2=crossingEdge2,c=c})
	end 
	local s1 = c.edge1Solution
	local s2 = c.edge2Solution
	
	local xoverNode = newNodeWithPosition(c.c, nextNodeId())
	table.insert(nodesToAdd, xoverNode)
	--local tcross1 = util.rotateXY(tmid, -rotate)
	--local tcross2 = util.rotateXY(tmid, rotate)
	--local s1 = util.solveForPosition(xoverPos, crossingEdge1) 
	--local s2 = util.solveForPosition(xoverPos, crossingEdge2) 
	local crossOver1 = initSegmentAndEntity() 
	crossOver1.comp.node0 = endCrossingNode1.entity
	crossOver1.comp.node1 = xoverNode.entity
	setTangent(crossOver1.comp.tangent0, s1.t0)
	setTangent(crossOver1.comp.tangent1, s1.t1)
	table.insert(edgesToAdd, crossOver1)
	
	local crossOver2 = initSegmentAndEntity() 
	crossOver2.comp.node0 = xoverNode.entity
	crossOver2.comp.node1 = stationNode2
	setTangent(crossOver2.comp.tangent0, s1.t2)
	setTangent(crossOver2.comp.tangent1, s1.t3)
	table.insert(edgesToAdd, crossOver2)
	
	local crossOver3 = initSegmentAndEntity() 
	crossOver3.comp.node0 = endCrossingNode2.entity
	crossOver3.comp.node1 = xoverNode.entity
	setTangent(crossOver3.comp.tangent0, s2.t0)
	setTangent(crossOver3.comp.tangent1, s2.t1)
	 table.insert(edgesToAdd, crossOver3)
	
	local crossOver4 = initSegmentAndEntity() 
	crossOver4.comp.node0 = xoverNode.entity
	crossOver4.comp.node1 = stationNode1
	setTangent(crossOver4.comp.tangent0, s2.t2)
	setTangent(crossOver4.comp.tangent1, s2.t3)
	table.insert(edgesToAdd, crossOver4)
	
	--if not params.isQuadrupleTrack or needsTunnel or true then 
		-- need some dead ends for the logic to find later 
		local exitNode1 = newNodeWithPosition(exitPos1, nextNodeId())
		table.insert(nodesToAdd, exitNode1)
		local exitNode2 = newNodeWithPosition(exitPos2, nextNodeId())
		table.insert(nodesToAdd, exitNode2)
		local exitEdge1 = initSegmentAndEntity() 
		exitEdge1.comp.node0 = exitNode1.entity 
		exitEdge1.comp.node1 = endCrossingNode1.entity 
		setTangent(exitEdge1.comp.tangent0, endTangent)
		setTangent(exitEdge1.comp.tangent1, exitTangent)
		table.insert(edgesToAdd, exitEdge1)
		local exitEdge2 = initSegmentAndEntity() 
		exitEdge2.comp.node0 = exitNode2.entity 
		exitEdge2.comp.node1 = endCrossingNode2.entity 
		setTangent(exitEdge2.comp.tangent0, endTangent)
		setTangent(exitEdge2.comp.tangent1, exitTangent)
		table.insert(edgesToAdd, exitEdge2)
		
	
		if buildDepotConnection and not suppressDepot and not util.searchForNearestNode(util.nodePointPerpendicularOffset(stationNode2Pos, stationTangent, 4*params.trackWidth), 5) then 
			 
			local depotLinkNode = newNodeWithPosition(util.nodePointPerpendicularOffset(stationNode2Pos, stationTangent, 4*params.trackWidth), nextNodeId())
			 addNode(depotLinkNode)
			local depotLink = initSegmentAndEntity()  
			 table.insert(edgesToAdd, depotLink)
			depotLink.comp.node0 = depotLinkNode.entity 
			depotLink.comp.node1 = depotNode 
			trace("Added the depot linkNode at ",depotLinkNode.comp.position.x, depotLinkNode.comp.position.y, " depotNode was ",depotNode, " depotLink entity was",depotLink.entity)
			util.setTangents(depotLink, util.nodePos(depotNode)- util.v3(depotLinkNode.comp.position))
			local depotTangent = util.getDeadEndNodeDetails(depotNode).tangent 
			util.setTangent(depotLink.comp.tangent1, -vec3.length(depotLink.comp.tangent1)*vec3.normalize(depotTangent))
			
			local s = util.solveForPositionHermiteFraction(0.1, { p0 = exitPos2, p1=endCrossingNodePos2, t0 = endTangent, t1 = exitTangent})
			--[[local depotLinkNode2 = newNodeWithPosition(util.nodePointPerpendicularOffset(util.v3(endCrossingNode2.comp.position) ,exitTangent, 3*params.trackWidth), nextNodeId())
			 addNode(depotLinkNode2)]]--
			local depotLinkNode2 = newNodeWithPosition(s.p, nextNodeId())
			 addNode(depotLinkNode2)
			local newEnd = util.copySegmentAndEntity(exitEdge2, nextEdgeId())
			newEnd.comp.node1 = depotLinkNode2.entity 
			exitEdge2.comp.node0 = depotLinkNode2.entity 
			setTangent(newEnd.comp.tangent0, s.t0)
			setTangent(newEnd.comp.tangent1, s.t1)
			setTangent(exitEdge2.comp.tangent0, s.t2)
			setTangent(exitEdge2.comp.tangent1, s.t3)
			table.insert(edgesToAdd, newEnd)
			
			--[[local midLink = util.copySegmentAndEntity(straightConnect2, nextEdgeId())
			midLink.comp.node0 = depotLinkNode2.entity 
			midLink.comp.node1 = depotLinkNode.entity 
			 table.insert(edgesToAdd, midLink)]]--
			local connectionLink = util.copySegmentAndEntity(exitEdge2, nextEdgeId())
			connectionLink.comp.node0 = depotLinkNode2.entity
			connectionLink.comp.node1 = depotLinkNode.entity
			util.setTangent(connectionLink.comp.tangent0, s.t2)
			util.setTangent(connectionLink.comp.tangent1, depotLink.comp.tangent0)
			table.insert(edgesToAdd, connectionLink)
			if not params.connectedDepots then 
				params.connectedDepots = {}
			end
			params.connectedDepots[depotConstr]=true
		end
		if not params.isQuadrupleTrack and not safeMode then 
			local left = util.signedAngle(endCrossingNodePos1-endCrossingNodePos2, endTangent) < 0 
			local param = buildDepotConnection and 0.9 or 0.5
			buildSignal(edgeObjectsToAdd, exitEdge1, left, param)
			buildSignal(edgeObjectsToAdd, exitEdge2, not left, param)
		end
	--end
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	local testData  =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if buildDepotConnection and not suppressDepot then 
		
		local isError = #testData.errorState.messages > 0 or testData.errorState.critical
		if isError then 
			return false 
		end
	end 
	if testData.errorState.critical then 
		trace("Unable to build crossover due to critical error")
		if util.tracelog and  safeMode then 
			debugPrint(newProposal)
			print(debug.traceback())
		 --	local diagnose = true
 		--	routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
		end 
		return false
	end 
	params.crossoversBuilt[station]=true
	
 
	trace("About to build command to crossover for station=",station,"maxAngle=",math.deg(maxAngle))
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace("About to send command to build crossover")
	util.clearCacheNode2SegMaps()
	
	api.cmd.sendCommand(build, function(res, success) 
		trace("Result of building crossover ",success)
		if not success and util.tracelog then 
			debugPrint(res) 
		end
		callback(res, success)
	end)
	return true
end

local function buildExtensionToTerminal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  nextNodeId, nextEdgeId, station,edgesToRemove, rotate, connectNode, edgeIdx, params, otherStationNode, joinIndex , perpSign)
	--local joinIndex 
	if not joinIndex then 
		if edgeIdx == routeInfo.lastFreeEdge then 
			joinIndex = edgeIdx - 1 - params.offsetIndex
		else 
			joinIndex = edgeIdx + 1 + params.offsetIndex
		end
	end
	if not nextNodeId then 
		nextNodeId = function()
			return -1000-#nodesToAdd
		end
	end 
	if not nextEdgeId then 
		nextEdgeId = function() 
			return -1-#edgesToAdd
		end
	end
	trace("buildExtensionToTerminal: Building extension to terminal, connectNode was ",connectNode, " joinIndex=",joinIndex," edgeIdx=",edgeIdx)
	if #util.getTrackSegmentsForNode(connectNode) > 1 then 
		trace("The extension appears to be already connected") 
		return true 
	end
	local connectNodePos = util.nodePos(connectNode)
	local node
	local node0 = routeInfo.edges[joinIndex].edge.node0
	local node1 = routeInfo.edges[joinIndex].edge.node1
	if util.distance(util.nodePos(node1), connectNodePos) < util.distance(util.nodePos(node0), connectNodePos) then  -- may need to revisit, doesn't work if angle is sharp
		node = node0
	else 
		node = node1
	end
		
	local routeTangent = util.v3(routeInfo.edges[joinIndex].edge.tangent0)
	local trialPos = util.doubleTrackNodePoint(util.nodePos(node), routeTangent)
	local trackVector = trialPos - util.nodePos(node)
	if not otherStationNode then 
		otherStationNode = connectNode
	end 
	local trackVector2 = util.nodePos(connectNode) - util.nodePos(otherStationNode)
	local exitTangent = util.getDeadEndNodeDetails(connectNode).tangent 
	local angle = util.signedAngle(trackVector, trackVector2)
	local angle2 = util.signedAngle(trackVector2, exitTangent)
	local angle3 = util.signedAngle(routeTangent, exitTangent)
	trace("buildExtensionToTerminal: Trial pos was ",trialPos.x, trialPos.y, " the angle was ",math.deg(angle), " alternative angle calculation gave",math.deg(angle2), "angle3=",math.deg(angle3))
--	local perpSign = util.distance(connectNodePos, trialPos) > util.distance(connectNodePos, util.nodePos(node)) and -1 or 1 -- move towards the station
--[[	angle2 = math.abs(angle2) 
	if angle2 > math.rad(90) then 
		angle2 = math.rad(180) - angle2
	end]] 
	if not perpSign then 
		perpSign = math.abs(angle) < math.rad(90) and 1 or -1
	end
	trace("buildExtensionToTerminal: initial perpsign was",perpSign, " the corrected angle2 was ",math.deg(angle2))
	if math.abs(angle3) < math.rad(90) then 
		perpSign = -perpSign
		trace("Inverting perpsign")
	end 
	trace("buildExtensionToTerminal: the perpSign was ",perpSign)
	local newEdges = routeBuilder.buildJunctionSpur(nodesToAdd, edgesToAdd, edgesToRemove, edgeObjectsToAdd, edgeObjectsToRemove, routeInfo, joinIndex, directionSign, perpSign, node, nextEdgeId, nextNodeId, params, connectNodePos, true, connectNode, otherStationNode)
	if not newEdges then return false end
	local connectEdge1 = copySegmentAndEntity(newEdges.edge1, nextEdgeId())
	local nodeDetails = util.getDeadEndNodeDetails(connectNode)
	local dist = math.max(util.distance(connectNodePos, newEdges.newNode1Pos), util.distance(connectNodePos, newEdges.newNode2Pos))
	connectEdge1.comp.node0 = newEdges.edge1.comp.node1 
	connectEdge1.comp.node1 = connectNode 
	setTangent(connectEdge1.comp.tangent0, dist*vec3.normalize(util.v3(newEdges.edge1.comp.tangent1)))
	setTangent(connectEdge1.comp.tangent1, -dist*vec3.normalize(nodeDetails.tangent))
	table.insert(edgesToAdd, connectEdge1)
	
	local connectEdge2 = copySegmentAndEntity(connectEdge1, nextEdgeId())
	connectEdge2.comp.node0 = newEdges.edge2.comp.node1 
	connectEdge2.comp.node1 = connectNode 
	setTangent(connectEdge2.comp.tangent0, dist*vec3.normalize(util.v3(newEdges.edge2.comp.tangent1)))
	setTangent(connectEdge2.comp.tangent1, -dist*vec3.normalize(nodeDetails.tangent))
	table.insert(edgesToAdd, connectEdge2)

	if dist > 1.5 * params.targetSeglenth then 
		trace("buildExtensionToTerminal: Detected large distance", dist," attempting to correct")
		local edge = { 
			p0 = newEdges.newNode2Pos, -- edge2 is NOT the collision edge, use this to ensure clearance from divering track
			p1 = connectNodePos, 
			t0 = util.v3(connectEdge2.comp.tangent0),
			t1 = util.v3(connectEdge2.comp.tangent1)		
		}
		local midSolution = util.solveForPositionHermiteFraction(0.5, edge)
		local newNode = newNodeWithPosition(midSolution.p, nextNodeId())
		table.insert(nodesToAdd, newNode)
		local connectEdge3 = copySegmentAndEntity(connectEdge1, nextEdgeId())
		table.insert(edgesToAdd, connectEdge3) 
		connectEdge1.comp.node1 = newNode.entity
		setTangent(connectEdge1.comp.tangent1, midSolution.t)
		connectEdge3.comp.node0 = newNode.entity 
		setTangent(connectEdge3.comp.tangent0, midSolution.t)
	
		local perpSign = 1 
		local exitTangent = util.v3(newEdges.edge1.comp.tangent1)
		local doubleTrackVector = newEdges.newNode2Pos - newEdges.newNode1Pos 
		local relativeAngle = util.signedAngle(doubleTrackVector, edge.t0)
		trace("buildExtensionToTerminal: the relativeAngle was ",math.deg(relativeAngle))
		if relativeAngle > 0 then -- expect either + or - 90 
			perpSign = -1 
		end
		--[[local testP = util.doubleTrackNodePoint(newEdges.newNode1Pos, exitTangent)
		local testP2 = util.doubleTrackNodePoint(newEdges.newNode1Pos, -1*exitTangent)
		if util.distance(testP2, newEdges.newNode2Pos) < util.distance(testP, newEdges.newNode2Pos) then 
			perpSign = -1
		end]]--
		local newNode2 = newNodeWithPosition(util.doubleTrackNodePoint(midSolution.p, perpSign*midSolution.t),nextNodeId())
		table.insert(nodesToAdd, newNode2)
		trace("buildExtensionToTerminal: created intermediate nodes",newNode.entity, newNode2.entity)
		local connectEdge4 = copySegmentAndEntity(connectEdge2, nextEdgeId())
		table.insert(edgesToAdd, connectEdge4) 
		connectEdge2.comp.node1 = newNode2.entity
		setTangent(connectEdge2.comp.tangent1, midSolution.t)
		connectEdge4.comp.node0 = newNode2.entity 
		setTangent(connectEdge4.comp.tangent0, midSolution.t)
		
		local newDist = dist/2
		setTangentLengths(connectEdge1, newDist) 
		setTangentLengths(connectEdge2, newDist)
		setTangentLengths(connectEdge3, newDist)
		setTangentLengths(connectEdge4, newDist)
		if util.th(midSolution.p) > 0 then 
			if util.th(midSolution.p)-midSolution.p.z > 10 and util.th(connectNodePos)-connectNodePos.z > 10 then
				connectEdge2.comp.type = 2
				connectEdge1.comp.type = 2
				connectEdge2.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
				connectEdge1.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
			end
			connectEdge3.comp.type = 0
			connectEdge4.comp.type = 0
			connectEdge3.comp.typeIndex = -1
			connectEdge4.comp.typeIndex = -1
			
		end 
		if not params.disableSignalBuild then 
			
	--		local left = isNode0 == negPerp 
			local left = perpSign < 0 
			 
			local param = 0.5
		 
			buildSignal(edgeObjectsToAdd, connectEdge1, left, param, true)
			buildSignal(edgeObjectsToAdd, connectEdge2, not left, param, true)
			 
		end 
		trace("buildExtensionToTerminal: Created connection edges:",newEdgeToString(connectEdge1),newEdgeToString(connectEdge2),newEdgeToString(connectEdge3),newEdgeToString(connectEdge4))
	end 
	return {}
end 


local function buildCrossoverExistingEdges(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  nextNodeId, nextEdgeId, station,edgesToRemove, rotate, edgeIdx, params ) 
	
	if not edgeIdx then edgeIdx = routeInfo.lastFreeEdge end
	local allStationFreeNodes = util.getAllFreeNodesForStation(station )
	local edgeAndId = routeInfo.edges[edgeIdx]
	if not util.contains(allStationFreeNodes,  edgeAndId.edge.node0) and not util.contains(allStationFreeNodes,  edgeAndId.edge.node1) then 
		trace("WARNING! buildCrossoverExistingEdges: given edgeIdx",edgeIdx, "does not contain the stationFreeNodes")
		if edgeIdx == routeInfo.lastFreeEdge then
			edgeIdx = routeInfo.firstFreeEdge
		elseif edgeIdx == routeInfo.firstFreeEdge then	
			edgeIdx = routeInfo.lastFreeEdge
		else 
			trace("Route info was not given at either the first or last free edge")
		end 
		edgeAndId = routeInfo.edges[edgeIdx]
		if not util.contains(allStationFreeNodes,  edgeAndId.edge.node0) and not util.contains(allStationFreeNodes,  edgeAndId.edge.node1) then 
			trace("WARNING: buildCrossoverExistingEdges still unable to find node")
		end 
	end 
	local function nodePos(node)
		if node > 0 then 
			return util.nodePos(node)
		else 
			for i, node in pairs(nodesToAdd) do --   not worth mapping
				if node.entity == node then 
					return util.v3(node.comp.position)
				end 
			end 
			trace("WARNING! No node found for ",node)
		end 
	end 
	
	local otherStationFreeNodes = util.getFreeNodesForFreeTerminalsForStation(station)
	local stationNode1
	local stationNode2
	local exitNode1
	local exitNode2
	local stationTangent
	local exitTangent
	
	local backwards = util.contains(allStationFreeNodes,  edgeAndId.edge.node0)
	
	if backwards then 
		stationNode1 = edgeAndId.edge.node0
		local index = util.indexOf(otherStationFreeNodes, stationNode1)
		if index ~= -1 then 
			table.remove(otherStationFreeNodes, index)
		end
		
		stationNode2 = util.findClosestNode(otherStationFreeNodes, stationNode1)
		stationTangent = -1*(util.v3(edgeAndId.edge.tangent0))
		exitTangent =  -1*(util.v3(edgeAndId.edge.tangent1))
		exitNode2 = edgeAndId.edge.node1
		exitNode1 = util.findDoubleTrackNode(util.nodePos(exitNode2), exitTangent) 
		if not exitNode1 then 
			for tolerance = 2, 20 do 
				exitNode1 = util.findDoubleTrackNode(util.nodePos(exitNode2), exitTangent, 1, tolerance)
				trace("Attempting to find exitNode1 at tolerance",tolerance," success?",exitNode1~=nil)
				if exitNode1 then 
					break 
				end
			end 
		end
	else
		stationNode1 = edgeAndId.edge.node1
		local index = util.indexOf(otherStationFreeNodes, stationNode1)
		if index ~= -1 then 
			table.remove(otherStationFreeNodes, index)
		end
		stationNode2 = util.findClosestNode(otherStationFreeNodes, stationNode1)	
		stationTangent = util.v3(edgeAndId.edge.tangent1)
		exitTangent =  util.v3(edgeAndId.edge.tangent0)	
		exitNode2 = edgeAndId.edge.node0
		exitNode1 = util.findDoubleTrackNode(util.nodePos(exitNode2), exitTangent)
		if not exitNode1 then 
			for tolerance = 2, 20 do 
				exitNode1 = util.findDoubleTrackNode(util.nodePos(exitNode2), exitTangent, 1, tolerance)
				trace("Attempting to find exitNode1 at tolerance",tolerance," success?",exitNode1~=nil)
				if exitNode1 then 
					break 
				end
			end 
		end
	end
	local stationNode1Pos = util.nodePos(stationNode1)
	local stationNode2Pos = util.nodePos(stationNode2)
	local distanceBetweenNodes = util.distance(stationNode1Pos, stationNode2Pos)
	if distanceBetweenNodes > 80 then 
		trace("detected large distance between station nodes",distanceBetweenNodes," attempting to correct")
		stationNode2 = util.findDoubleTrackNode(stationNode1Pos, stationTangent)
		stationNode2Pos = util.nodePos(stationNode2)
	end
	trace("buildCrossoverExistingEdges: stationNode1=",stationNode1," stationNode2=",stationNode2, "exitNode1=",exitNode1,"exitNode2=",exitNode2)
	if #util.getSegmentsForNode(exitNode2) == 4 then 
		trace("Discovered preexisting crossover, forcing extension to terminal")
		params.forceExtensionToTerminal = true 
	end 
	
	
	if not exitNode1 and not params.forceExtensionToTerminal then 
		error("Unable to find exitNode1")
	end
	local segs = util.getTrackSegmentsForNode(stationNode1)
	local foundDepotEdge = false
	local depotConnectNode
	for i, seg in pairs(segs) do 
		trace("Inspecting seg, ",seg, " attached to ",stationNode1," for possible crossover")
		local edge = util.getEdge(seg) 
		local foundDepotEdgeHere = false 
		for j, node in pairs({edge.node1, edge.node0}) do
			local segs2 = util.getTrackSegmentsForNode(node)
			local segCount = #segs2
			if segCount == 4 then 
				for k, seg2 in pairs(segs2) do 
					if isDepotEdge(seg2, 2) then 
						foundDepotEdge = seg2 
						depotConnectNode = node
						foundDepotEdgeHere = true
						trace("Found depot edge",seg2)
						break
					end 
				end 
			end
			
			
			trace("The seg count at node ",node," was ",segCount)
			if segCount==4 and not foundDepotEdgeHere
				--and not util.getComponent(node, api.type.ComponentType.BASE_NODE).doubleSlipSwitch 
				then 
				if params.offsetIndex == 0 and util.getComponent(node, api.type.ComponentType.BASE_NODE).doubleSlipSwitch  then 
					params.offsetIndex = 1 
				end
				trace("Discovered crossover already exists, building spur instead")
				return buildExtensionToTerminal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  nextNodeId, nextEdgeId, station,edgesToRemove, rotate, stationNode2, edgeIdx, params, stationNode1 ) 
				 
			end 
		end
	end
	if util.distance(stationNode1Pos, stationNode2Pos) > 4*params.trackWidth or params.forceExtensionToTerminal then 
		trace("Large distance between terminal nodes, building spur instead",util.distance(stationNode1Pos, stationNode2Pos), " forceExtensionToTerminal?",params.forceExtensionToTerminal)
		return buildExtensionToTerminal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  nextNodeId, nextEdgeId, station,edgesToRemove, rotate, stationNode2, edgeIdx, params, stationNode1 ) 
		
	end
	local removedEdges = {}
	
	
	local deflectionAngle = util.signedAngle(stationTangent, exitTangent)
	local exitNode1Pos = util.nodePos(exitNode1)
	local exitNode2Pos = util.nodePos(exitNode2)
	local deltaz = exitNode1Pos.z - stationNode1Pos.z
	local swapped = false
	if math.abs(util.signedAngle(exitNode1Pos-exitNode2Pos, stationNode1Pos-stationNode2Pos))>math.rad(90) then -- angle of vectors between double track nodes expect to be almost the same, unless wrong way round
		local temp = exitNode1 -- swap
		exitNode1 = exitNode2
		exitNode2 = temp
		exitNode1Pos = util.nodePos(exitNode1)
		exitNode2Pos = util.nodePos(exitNode2)
		swapped = true
	end
	trace("stationNode1=",stationNode1,"stationNode2=",stationNode2, " exitNode1=",exitNode1," exitNode2=", exitNode2, " backwards=",backwards, " deflectionAngle=",math.deg(deflectionAngle), "deltaz=",deltaz, " edgeAndId=",edgeAndId.id)
	if foundDepotEdge then 
		trace("The depotConnectNode was ",depotConnectNode)
		for i, seg in pairs(util.getTrackSegmentsForNode(depotConnectNode)) do 
			if seg~= edgeAndId.id or depotConnectNode ~= exitNode2 then 
				trace("removing seg",seg," as part of depot link")
				removedEdges[seg]=true
				table.insert(edgesToRemove, seg)
			else 
				trace("Skipping removal of ",edgeAndId.id)
			end 
		end 
		if depotConnectNode == exitNode1 then 
			exitNode1 = util.findDoubleTrackNode(exitNode2)
			trace("Attempting to replace exitNode1 with",exitNode1)
		elseif depotConnectNode == exitNode2 then 
			exitNode2 = util.findDoubleTrackNode(exitNode1)
			trace("Attempting to replace exitNode1 with",exitNode2)
		end 
 	end
	

	local edgeLength = util.calculateSegmentLengthFromEdge(util.getEdge(edgeAndId.id))
	local exitTangentDelta = 0
	local shortened = false
	if edgeLength > params.maxCrossoverEdgeLength then -- by trial and error about the max length a crossover can be built
		local hermiteFrac = (edgeLength-params.maxCrossoverEdgeLength)/edgeLength
		trace("Long edge detected, attempting to correct ", edgeLength, "hermiteFrac = ",hermiteFrac, " exitNode1Pos=",exitNode1Pos.x, exitNode1Pos.y)
		local edge1 = { -- need to hand craft because we can't be sure the existing edges are the right way around
			p0 = exitNode1Pos,
			t0 = exitTangent,
			p1 = stationNode1Pos,
			t1 = stationTangent		
		}
		local edge2 = {
			p0 = exitNode2Pos,
			t0 = exitTangent,
			p1 = stationNode2Pos,
			t1 = stationTangent		
		}
		exitNode1Pos = util.solveForPositionHermiteFraction(hermiteFrac, edge1).p
		
		exitNode2Pos =  util.solveForPositionHermiteFraction(hermiteFrac, edge2).p
		local solution = util.solveForPosition(exitNode1Pos, edge1)
		stationTangent = solution.t3 
		exitTangent = solution.t2
		exitTangentDelta = vec3.length(solution.t0)
		local trialPos = util.doubleTrackNodePoint(exitNode1Pos, exitTangent)
		local trialPos2 = util.doubleTrackNodePoint(exitNode1Pos, -1*exitTangent)
		if util.distance(trialPos, exitNode2Pos) < util.distance(trialPos2, exitNode2Pos) then -- want to clamp the position to a double track node point otherwise you get strange effects with tunnel portals etc.
			exitNode2Pos = trialPos
		else 
			exitNode2Pos = trialPos2
		end 
		shortened = true
		trace("new  exitNode1Pos=",exitNode1Pos.x, exitNode1Pos.y, " exitTangentDelta=",exitTangentDelta)
	end

	-- crossover is very sensitive to height changes, so level out the track
	exitNode1Pos.z=stationNode1Pos.z
	exitNode2Pos.z=stationNode1Pos.z
	stationTangent.z=0
	exitTangent.z=0
	local removeSignals = false 
	if params.tryToCorrectDeflectionAngle and math.abs(deflectionAngle) > math.rad(30) then 
		local nodePosBefore = exitNode1Pos
		local trackOffset = 5 
		local perpSign = deflectionAngle < 0 and -1 or 1
		exitNode1Pos = util.nodePointPerpendicularOffset(exitNode1Pos ,perpSign*exitTangent, trackOffset)
		exitNode2Pos = util.nodePointPerpendicularOffset(exitNode2Pos ,perpSign*exitTangent, trackOffset)
		trace("Attempting to correct deflectionAngle, perpSign=",perpSign," trackOffset=",trackOffset," before:",nodePosBefore.x, nodePosBefore.y, " after ",exitNode1Pos.x, exitNode1Pos.y)
		removeSignals= true
	end
	
	removeSignals= true
	
	local oldExitNode1 = exitNode1
	local oldExitNode2 = exitNode2
	
	local otherStationNode 
	for i = 1 , 5 do 
		local node = util.findDoubleTrackNode(stationNode1Pos, stationTangent, i) 
		if node and node ~= stationNode2  then 
			otherStationNode = node 
			trace("Found otherStationNode",node)
			break
		end 
	
	end 
	
	
	local replacementExitNode1 = newNodeWithPosition(exitNode1Pos, nextNodeId())
	exitNode1 = replacementExitNode1.entity
	table.insert(nodesToAdd, replacementExitNode1)
	local replacementExitNode2 = newNodeWithPosition(exitNode2Pos, nextNodeId())
	exitNode2 = replacementExitNode2.entity
	table.insert(nodesToAdd, replacementExitNode2)
	local replacedNodesMap = {}
	replacedNodesMap[oldExitNode1] = {node=exitNode1, nodePos = exitNode1Pos}
	replacedNodesMap[oldExitNode2] = {node=exitNode2, nodePos = exitNode2Pos}	
	local replacedEdgesMap = {}
	local newToOldEdgeMap = {}
	local foundOtherNodeEdge
	local function copyEdgeReplacingNode(edgeId ) 
		local entity = util.copyExistingEdge(edgeId, nextEdgeId())
		local dist 
		local isNode0 = false 
		local isJunctionEdge
		local otherNodeEdge = entity.comp.node0 == otherStationNode or entity.comp.node1 == otherStationNode 
		if otherNodeEdge then 
			foundOtherNodeEdge = entity
		end 
		--then 
		--	trace("Skipping replacing node on ",edgeId, " as it is connected to the otherStationNode", otherStationNode)
		--	return 
		--end
		if replacedNodesMap[entity.comp.node0] then
			isNode0 = true
			isJunctionEdge = entity.comp.node1 == stationNode1 or entity.comp.node1 == stationNode2
			local replacement = replacedNodesMap[entity.comp.node0]
			entity.comp.node0 = replacement.node
			
			dist = util.distance(replacement.nodePos, nodePos(entity.comp.node1))
			--setTangent(entity.comp.tangent0, (vec3.length(util.v3(entity.comp.tangent0))+exitTangentDelta)*vec3.normalize(exitTangent))
			--setTangent(entity.comp.tangent0,dist *vec3.normalize(util.v3(entity.comp.tangent0)))
			--setTangent(entity.comp.tangent1,dist *vec3.normalize(util.v3(entity.comp.tangent1)))
			entity.comp.tangent0.z =0 
		else 
			isJunctionEdge = entity.comp.node0 == stationNode1 or entity.comp.node0 == stationNode2
			if not replacedNodesMap[entity.comp.node1]  then 
				debugPrint({edgeId=edgeId, entity=entity, replacedNodesMap=replacedNodesMap})
			end
			assert(replacedNodesMap[entity.comp.node1] )
			--assert(entity.comp.node1==oldNode, "edgeId="..edgeId.." oldNode="..oldNode.." newNode="..newNode.." node0="..entity.comp.node0.." node1="..entity.comp.node1)
			local replacement = replacedNodesMap[entity.comp.node1]
			entity.comp.node1 = replacement.node
			
--			setTangent(entity.comp.tangent1, (vec3.length(util.v3(entity.comp.tangent1))+exitTangentDelta)*vec3.normalize(exitTangent))
			local newNodePos = replacement.nodePos
			local otherNodePos = nodePos(entity.comp.node0)
			dist = util.distance(newNodePos,otherNodePos )
			--setTangent(entity.comp.tangent0,dist *vec3.normalize(util.v3(entity.comp.tangent0)))
			--setTangent(entity.comp.tangent1,dist *vec3.normalize(util.v3(entity.comp.tangent1)))
			entity.comp.tangent1.z =0
		end	
		if exitTangentDelta > 0 or true then 
			if isJunctionEdge then 
				if isNode0 then 
					setTangent(entity.comp.tangent0, exitTangent)
					setTangent(entity.comp.tangent1, stationTangent)
				else 
					setTangent(entity.comp.tangent0, -1*stationTangent)
					setTangent(entity.comp.tangent1, -1*exitTangent)
				end 
			elseif not otherNodeEdge then 
				local oldLength = vec3.length(util.v3(entity.comp.tangent0))
				local newLength = oldLength + exitTangentDelta
				if isNode0 then  
					setTangent(entity.comp.tangent0, -newLength*vec3.normalize(exitTangent))
					setTangent(entity.comp.tangent1,  newLength*vec3.normalize(util.v3(entity.comp.tangent1)))
				else 
					setTangent(entity.comp.tangent0,newLength*vec3.normalize(util.v3(entity.comp.tangent0)))
					setTangent(entity.comp.tangent1, newLength*vec3.normalize(exitTangent)) 
				
				end 
			end
		
		end


		
		table.insert(edgesToRemove, edgeId)
		--if otherNodeEdge then 
		--	foundOtherNodeEdge = true 
			--return 
		--end
		table.insert(edgesToAdd, entity)
		replacedEdgesMap[edgeId]=entity
		newToOldEdgeMap[entity.entity]=edgeId
		local newEdgeObjs = {}
		for i, edgeObj in pairs(entity.comp.objects) do 
			table.insert(edgeObjectsToRemove, edgeObj[1])
			--table.insert(edgeObjectsToAdd, util.copyEdgeObject(edgeObj, entity.entity))
			--table.insert(newEdgeObjs, {-#edgeObjectsToAdd , edgeObj[2]})
		end 
		entity.comp.objects = newEdgeObjs 
	end
	local edgeToRemove = util.findEdgeConnectingNodes(oldExitNode1, stationNode2) 
	
	if edgeToRemove and not removedEdges[edgeToRemove] then 
		trace("Removing edge",edgeToRemove)
		removedEdges[edgeToRemove] = true 
		table.insert(edgesToRemove, edgeToRemove)
	end
	edgeToRemove = util.findEdgeConnectingNodes(oldExitNode2, stationNode1) 
	if edgeToRemove and not removedEdges[edgeToRemove] then 
		trace("Removing edge",edgeToRemove)
		removedEdges[edgeToRemove] = true 
		table.insert(edgesToRemove, edgeToRemove)
	end
	

	
	if params.buildCrossoverSlipSwitchOnly then 
		local edgeToRemove = util.findEdgeConnectingNodes(oldExitNode1, stationNode1) 
		if edgeToRemove then 
			trace("Removing edge",edgeToRemove)
			removedEdges[edgeToRemove] = true 
			table.insert(edgesToRemove, edgeToRemove)
			for i, edgeObj in pairs(util.getEdge(edgeToRemove).objects) do 
				table.insert(edgeObjectsToRemove, edgeObj[1])
			end
		end
		 
		local edgeToRemove = util.findEdgeConnectingNodes(oldExitNode2, stationNode2) 
		if edgeToRemove then 
			trace("Removing edge",edgeToRemove)
			removedEdges[edgeToRemove] = true 
			table.insert(edgesToRemove, edgeToRemove)
			for i, edgeObj in pairs(util.getEdge(edgeToRemove).objects) do 
				table.insert(edgeObjectsToRemove, edgeObj[1])
			end
		end
	else
		if not util.findEdgeConnectingNodes(oldExitNode2, stationNode2)  then 
			trace("No edge found connecting exit2 and station node2, inserting")
			local newEntity = util.copyExistingEdge(edgeAndId.id, nextEdgeId())
			newEntity.comp.objects = {}
			if newEntity.comp.node0 == oldExitNode1 then 
				newEntity.comp.node0 = exitNode2
				newEntity.comp.node1 = stationNode2
				setTangent(newEntity.comp.tangent0, exitTangent)
				setTangent(newEntity.comp.tangent1, stationTangent)
			else 
				newEntity.comp.node0 = stationNode2
				newEntity.comp.node1 = exitNode2
				setTangent(newEntity.comp.tangent0, -1*stationTangent)
				setTangent(newEntity.comp.tangent1, -1*exitTangent)
			end
			table.insert(edgesToAdd, newEntity)
		end
		if not util.findEdgeConnectingNodes(oldExitNode1, stationNode1)  then 
			trace("No edge found connecting exit1 and station node1, inserting")
			local newEntity = util.copyExistingEdge(edgeAndId.id, nextEdgeId())
			newEntity.comp.objects = {}
			if newEntity.comp.node0 == oldExitNode1 then 
				newEntity.comp.node0 = exitNode1
				newEntity.comp.node1 = stationNode1
				setTangent(newEntity.comp.tangent0, exitTangent)
				setTangent(newEntity.comp.tangent1, stationTangent)
			else 
				newEntity.comp.node0 = stationNode1
				newEntity.comp.node1 = exitNode1
				setTangent(newEntity.comp.tangent0, -1*stationTangent)
				setTangent(newEntity.comp.tangent1, -1*exitTangent)
			end
			table.insert(edgesToAdd, newEntity)
		end
	end
	
	local nextEdge1 
	local connectedSegs = util.getTrackSegmentsForNode(oldExitNode1)
	for i, edge in pairs(connectedSegs) do 
		if not removedEdges[edge] then
			copyEdgeReplacingNode(edge)
			if edge ~= edgeAndId.id and edge ~= util.findEdgeConnectingNodes(oldExitNode1, stationNode1)  then 
				nextEdge1 = replacedEdgesMap[edge]
			end
		end
	end
	local nextEdge2 
	local connectedSegs = util.getTrackSegmentsForNode(oldExitNode2)
	for i, edge in pairs(connectedSegs) do 
		if not removedEdges[edge] then
			copyEdgeReplacingNode(edge)
			if edge ~= edgeAndId.id and edge ~= util.findEdgeConnectingNodes(oldExitNode2, stationNode2)  then 
				nextEdge2 = replacedEdgesMap[edge]
			end
		end
	end
	if foundOtherNodeEdge then
		local entity = copySegmentAndEntity(foundOtherNodeEdge, nextEdgeId())
		if entity.comp.node1 == otherStationNode then 
			if entity.comp.node0 == exitNode1 then 
				entity.comp.node0 = exitNode2
			else 
				entity.comp.node0 = exitNode1
			end 
		else 
			if entity.comp.node1 == exitNode1 then 
				entity.comp.node1 = exitNode2
			else 
				entity.comp.node1 = exitNode1
			end 
		end
		table.insert(edgesToAdd, entity)
	 --[[	local offsetIndex = params.offsetIndex
		params.offsetIndex = offsetIndex + 1
		buildExtensionToTerminal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  nextNodeId, nextEdgeId, station,edgesToRemove, rotate, otherStationNode, edgeIdx, params, stationNode1 ) 
		params.offsetIndex = offsetIndex]]--
		
		
	end 
	if not params.disableSignalBuild then 
		trace("buildCrossoverExistingEdges: calling buildJunctionSignalsOnNewEdges")
		routeBuilder.buildJunctionSignalsOnNewEdges(nextEdge1, oldExitNode1, nextEdge2, oldExitNode2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, true)
	end
	if shortened and nextEdge1 and nextEdge2 then 
		local otherNode = nextEdge1.comp.node0 == exitNode1 and nextEdge1.comp.node1 or nextEdge1.comp.node0 
		local length = util.distance(nodePos(otherNode), exitNode1Pos)
		
		local needsBridgePortal = nextEdge1.comp.type == 1 and util.th(nodePos(otherNode)) <0 and util.th(exitNode1Pos) >0 
		trace("The new length of the exit edge was",length, " needsBridgePortal=",needsBridgePortal)
		if length > 1.6*params.targetSeglenth or needsBridgePortal then 
		
			local useNode0 = nextEdge1.comp.node0 == otherNode
			trace("Splitting the edges useNode0?",useNode0) 
			local edge = {
				p0 = useNode0 and nodePos(otherNode) or exitNode1Pos,
				p1 = useNode0 and exitNode1Pos or nodePos(otherNode),
				t0 = util.v3(nextEdge1.comp.tangent0),
				t1 = util.v3(nextEdge1.comp.tangent1)
			}
			local frac = 0.5
			if needsBridgePortal then 
				local startAt = useNode0 and 2 or 7 
				local endAt = useNode0 and 7 or 2
				local increment = useNode0 and 1 or -1
				
				for i = startAt, endAt, increment do 
					frac = i/8 
					if util.th(util.solveForPositionHermiteFraction(frac, edge).p) > 0 then 
						break 
					end 
				end
			end 
			
			local solution = util.solveForPositionHermiteFraction(frac, edge)
			
			local replacementNode1 = newNodeWithPosition(solution.p, nextNodeId()) 
			table.insert(nodesToAdd, replacementNode1)
			
			local perpSign = 1 
			local testTangent = useNode0 and util.v3(nextEdge1.comp.tangent1) or util.v3(nextEdge1.comp.tangent0)
			local testP = util.doubleTrackNodePoint(exitNode1Pos, perpSign*testTangent)
			local testP2= util.doubleTrackNodePoint(exitNode1Pos, -1*perpSign*testTangent)
			if util.distance(testP, exitNode2Pos) > util.distance(testP2, exitNode2Pos) then 
				perpSign = -perpSign
			end 
			local newNodePos2 = util.doubleTrackNodePoint(solution.p, perpSign*solution.t)
		 
			local replacementNode2 = newNodeWithPosition(newNodePos2, nextNodeId()) 
			table.insert(nodesToAdd, replacementNode2)
			
			local newNextNextEdge1 = copySegmentAndEntity(nextEdge1, nextEdgeId())
			table.insert(edgesToAdd, newNextNextEdge1)
			local newNextNextEdge2 = copySegmentAndEntity(nextEdge2, nextEdgeId()) 
			table.insert(edgesToAdd, newNextNextEdge2) 	
			
			nextEdge1.comp.node1 = replacementNode1.entity
			newNextNextEdge1.comp.node0 = replacementNode1.entity
			nextEdge2.comp.node1 = replacementNode2.entity
			newNextNextEdge2.comp.node0 = replacementNode2.entity
			
			if needsBridgePortal then 
				if useNode0 then 
					newNextNextEdge1.comp.type = 0
					newNextNextEdge1.comp.typeIndex = -1
					newNextNextEdge2.comp.type = 0
					newNextNextEdge2.comp.typeIndex = -1
				else 
					nextEdge1.comp.type = 0
					nextEdge1.comp.typeIndex = -1
					nextEdge2.comp.type = 0
					nextEdge2.comp.typeIndex = -1
					
				end
			end 
			
			util.setTangent(nextEdge1.comp.tangent0, solution.t0)
			util.setTangent(nextEdge1.comp.tangent1, solution.t1)
			util.setTangent(newNextNextEdge1.comp.tangent0, solution.t2)
			util.setTangent(newNextNextEdge1.comp.tangent1, solution.t3)
			
			util.setTangent(nextEdge2.comp.tangent0, solution.t0)
			util.setTangent(nextEdge2.comp.tangent1, solution.t1)
			util.setTangent(newNextNextEdge2.comp.tangent0, solution.t2)
			util.setTangent(newNextNextEdge2.comp.tangent1, solution.t3)
			--if useNode0 then 
				
		--	else 
				newNextNextEdge1.comp.objects ={}
				newNextNextEdge2.comp.objects ={}
			--end 
		end
	end 

	
	if math.abs(deltaz) > 2 and shortened and false then 
		local nextNextEdge1Id = util.findNextEdgeInSameDirection(newToOldEdgeMap[nextEdge1.entity], oldExitNode1)
		local nextNextEdge2Id = util.findNextEdgeInSameDirection(newToOldEdgeMap[nextEdge2.entity], oldExitNode2)
		
		local nextNextEdge1 = util.getEdge(nextNextEdge1Id)
		local nextNextEdge2 = util.getEdge(nextNextEdge2Id)
		
		local nextExitNode1 = nextNextEdge1.node0 == oldExitNode1 and nextNextEdge1.node1 or nextNextEdge1.node0 
		local nextExitNode2 = nextNextEdge2.node0 == oldExitNode2 and nextNextEdge2.node1 or nextNextEdge2.node0 
		local deltaz2 = nodePos(nextExitNode1).z - nodePos(oldExitNode1).z
		local dist1 = vec2.distance(util.nodePos(oldExitNode1), exitNode1Pos)
		local dist2 = vec2.distance(util.nodePos(oldExitNode1), util.nodePos(nextExitNode1))
		local interpolateHeight = (dist1 / (dist1+dist2)) * (deltaz+deltaz2) + exitNode1Pos.z 
		local grad = (deltaz+deltaz2) / (dist1+dist2)  
		
		 
	

 
		trace("Large potential height gradient detected, attempting to correct deltaz=",deltaz, " deltaz2=",deltaz2, "dist1=",dist1, " dist2=",dist2, " calculated interpolateHeight as ",interpolateHeight," previously ",util.nodePos(oldExitNode1).z)
		local newNodePos1 = nodePos(oldExitNode1)
		newNodePos1.z = interpolateHeight
		local replacementNode1 = newNodeWithPosition(newNodePos1, nextNodeId()) 
		table.insert(nodesToAdd, replacementNode1)
		local newNodePos2 = nodePos(oldExitNode2)
		newNodePos2.z = interpolateHeight
		local replacementNode2 = newNodeWithPosition(newNodePos2, nextNodeId()) 
		table.insert(nodesToAdd, replacementNode2)
		
		local newNextNextEdge1 = util.copyExistingEdge(nextNextEdge1Id, nextEdgeId())
		table.insert(edgesToAdd, newNextNextEdge1)
		table.insert(edgesToRemove, nextNextEdge1Id)
		
		local newNextNextEdge2 = util.copyExistingEdge(nextNextEdge2Id, nextEdgeId())
		table.insert(edgesToAdd, newNextNextEdge2)
		table.insert(edgesToRemove, nextNextEdge2Id)
		
		replaceNode(nextEdge1, oldExitNode1, replacementNode1.entity, dist1)
		replaceNode(nextEdge2, oldExitNode2, replacementNode2.entity, dist1)
		replaceNode(newNextNextEdge1, oldExitNode1, replacementNode1.entity, dist2)
		replaceNode(newNextNextEdge2, oldExitNode2, replacementNode2.entity, dist2)
	end 
	 

	
	local xoverPosz = 0.25*(stationNode1Pos+stationNode2Pos+exitNode1Pos+exitNode2Pos).z -- can average positions. Note vec3 does not support division but fractional multiplication is the same thing
	local leftEdge = {
		p0 = exitNode1Pos, 
		t0 = exitTangent,
		p1 = stationNode1Pos, 
		t1 = stationTangent
	}
	local rightEdge = {
		p0 = exitNode2Pos, 
		t0 = exitTangent,
		p1 = stationNode2Pos, 
		t1 = stationTangent
	}
	
	local leftXOverEdge = {
		p0 = exitNode1Pos, 
		t0 = exitTangent,
		p1 = stationNode2Pos, 
		t1 = stationTangent
	}
	local rightXOverEdge = {
		p0 = exitNode2Pos, 
		t0 = exitTangent,
		p1 = stationNode1Pos, 
		t1 = stationTangent
	}

	local xoverPos = 0.5*(util.solveForPositionHermiteFraction(0.5, leftEdge).p
				   +util.solveForPositionHermiteFraction(0.5, rightEdge).p)
	if params.useBasicHermite then 
		xoverPos = 0.5*(util.hermite2(0.5, leftEdge).p
				   +util.hermite2(0.5, rightEdge).p)
	end
	
	local fullCollisionSolution = util.fullSolveForCollisionBetweenProposedEdges(leftXOverEdge, rightXOverEdge) 
	if params.useFullCollisionSolution then 
		xoverPos = fullCollisionSolution.c 
	end 
	
	trace("original xoverPos.z=",xoverPos.z, " average is",xoverPosz)
	xoverPos.z = stationNode1Pos.z
	
	local dummyPosFraction = 0.25+rotate*(0.6-0.25)
	if params.buildCrossoverSlipSwitchOnly then 
		dummyPosFraction = 0.5
	end
	trace("Using dummyPosFraction=", dummyPosFraction)
	local dummyPos = 0.5*(util.solveForPositionHermiteFraction(dummyPosFraction, leftEdge).p
				   +util.solveForPositionHermiteFraction(dummyPosFraction, rightEdge).p)
	if params.useBasicHermite then 
		dummyPos = 0.5*(util.hermite2(dummyPosFraction, leftEdge).p
				   +util.hermite2(dummyPosFraction, rightEdge).p)

	end
	local edgeLength = (util.calculateSegmentLengthFromNewEdge(leftEdge)+util.calculateSegmentLengthFromNewEdge(rightEdge))/2
	
	local xoverNode = newNodeWithPosition(xoverPos, nextNodeId())
	if params.buildCrossoverSlipSwitchOnly then 
		xoverNode.comp.doubleSlipSwitch = true
		trace("Set doubleSlipSwitch for xoverNode",xoverNode.entity)
	end
	table.insert(nodesToAdd, xoverNode)
	
	 
	if not rotate then 
		rotate = 0
	end
	
	local crossLength = edgeLength/2 + 2.5
	local crossExitTangent = crossLength * vec3.normalize(exitTangent)
	local crossStationTangent = crossLength * vec3.normalize(stationTangent)
	local midTangent = crossLength*vec3.normalize(stationTangent+exitTangent)
	local cross1Angle = util.signedAngle(xoverPos-exitNode1Pos,midTangent)
	local cross2Angle = util.signedAngle(xoverPos-exitNode2Pos,midTangent)
	trace("Angle xoverPos-exitNode1Pos to tmid was", math.deg(cross1Angle))
	trace("Angle xoverPos-exitNode2Pos to tmid was", math.deg(cross2Angle))
	trace("Angle stationNode1Pos-xoverPos to tmid was", math.deg(util.signedAngle(stationNode1Pos-xoverPos,midTangent)))
	trace("Angle stationNode2Pos-xoverPos to tmid was", math.deg(util.signedAngle(stationNode2Pos-xoverPos,midTangent)))

	

	local angleRatio1 = math.abs(cross1Angle) / math.abs(cross2Angle)

	local angleRatio2 = math.abs(util.signedAngle(stationNode1Pos-xoverPos,midTangent)) / math.abs(util.signedAngle(stationNode2Pos-xoverPos,midTangent))
	
	local averageRatio = (angleRatio1+angleRatio2)/2
	trace("The angle ratio was ", angleRatio1, angleRatio2, " average= ",averageRatio)
	
	if cross1Angle < 0 then
		trace("Inverting rotation")
		--rotate = -rotate
	end
	--local tcross1 = util.rotateXY(midTangent, -rotate+cross1Angle)
	--local tcross2 = util.rotateXY(midTangent, rotate+cross2Angle)
	--local tcross1 = util.rotateXY(midTangent, -cross1Angle)
	--local tcross2 = util.rotateXY(midTangent, -cross2Angle)
	--local tcross1 = util.rotateXY(midTangent, -rotate)
	--local tcross2 = util.rotateXY(midTangent, rotate)
	local tcross1 = crossLength * vec3.normalize(dummyPos -exitNode1Pos)
	local tcross2 = crossLength * vec3.normalize(dummyPos -exitNode2Pos)
	
	trace("Angle tcross1 to tmid was", math.deg(util.signedAngle(tcross1,midTangent)))
	trace("Angle tcross2 to tmid was", math.deg(util.signedAngle(tcross2,midTangent)))
	trace("Angle stationNode2Pos-xoverPos to tcross1 was", math.deg(util.signedAngle(stationNode2Pos-xoverPos,tcross1)))
	trace("Angle stationNode1Pos-xoverPos to tcross2 was", math.deg(util.signedAngle(stationNode1Pos-xoverPos,tcross2)))
	trace("Angle xoverPos-exitNode1Pos to tcross1 was", math.deg(util.signedAngle(xoverPos-exitNode1Pos,tcross1)))
	trace("Angle xoverPos-exitNode2Pos to tcross2 was", math.deg(util.signedAngle(xoverPos-exitNode2Pos,tcross2)))
	local crossOver1 = util.copyExistingEdge(edgeAndId.id, nextEdgeId())
	crossOver1.comp.node0 = exitNode1
	crossOver1.comp.node1 = xoverNode.entity
	crossOver1.comp.objects = {}
	setTangent(crossOver1.comp.tangent0, crossExitTangent)
	setTangent(crossOver1.comp.tangent1,tcross1)
	table.insert(edgesToAdd, crossOver1)
	
	local crossOver2 = copySegmentAndEntity(crossOver1, nextEdgeId())
	crossOver2.comp.node0 = xoverNode.entity
	crossOver2.comp.node1 = stationNode2
	crossOver2.comp.objects = {}
	setTangent(crossOver2.comp.tangent0, tcross1)
	setTangent(crossOver2.comp.tangent1, crossStationTangent)
	table.insert(edgesToAdd, crossOver2)
	
	local crossOver3 = copySegmentAndEntity(crossOver1, nextEdgeId())
	crossOver3.comp.node0 = exitNode2
	crossOver3.comp.node1 = xoverNode.entity
	crossOver3.comp.objects = {}
	setTangent(crossOver3.comp.tangent0, crossExitTangent)
	setTangent(crossOver3.comp.tangent1, tcross2)
	table.insert(edgesToAdd, crossOver3)
	
	local crossOver4 = copySegmentAndEntity(crossOver1, nextEdgeId())
	crossOver4.comp.node0 = xoverNode.entity
	crossOver4.comp.node1 = stationNode1
	crossOver4.comp.objects = {}
	setTangent(crossOver4.comp.tangent0, tcross2)
	setTangent(crossOver4.comp.tangent1, crossStationTangent)
	table.insert(edgesToAdd, crossOver4)
	if params.useFullCollisionSolution then 
		local s1 = fullCollisionSolution.edge1Solution
		local s2 = fullCollisionSolution.edge2Solution
		s1.t1 = util.rotateXY(s1.t1, rotate)
		s1.t2 = util.rotateXY(s1.t2, rotate)
		s2.t1 = util.rotateXY(s2.t1, -rotate)
		s2.t2 = util.rotateXY(s2.t2, -rotate)
	
		setTangent(crossOver1.comp.tangent0, s1.t0)
		setTangent(crossOver1.comp.tangent1, s1.t1)
		setTangent(crossOver2.comp.tangent0, s1.t2)
		setTangent(crossOver2.comp.tangent1, s1.t3)
		
		setTangent(crossOver3.comp.tangent0, s2.t0)
		setTangent(crossOver3.comp.tangent1, s2.t1)
		setTangent(crossOver4.comp.tangent0, s2.t2)
		setTangent(crossOver4.comp.tangent1, s2.t3)
	end 
	trace("Finished setting up crossover")
	return {foundDepotEdge = foundDepotEdge}
end

local function tryBuildCrossover(routeInfo, station, rotate, ignoreErrors, params, edgeIdx, callback)
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgeObjectsToRemove = {}
	local edgesToRemove = {} 
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local nextNodeId = -10000
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	local result = buildCrossoverExistingEdges(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove, routeInfo,  getNextNodeId, nextEdgeId, station,edgesToRemove, rotate, edgeIdx, params ) 
	if not result then 
		trace("No result from data")
		return false 
	end 
	if #nodesToAdd == 0 and #edgesToAdd==0 and #edgesToRemove == 0 then 
		trace("Detected empty proposal, aborting")
		callback({}, true)
		return true 
	end
	
	local foundDepotEdge = result.foundDepotEdge
	trace("tryBuildCrossover: setting up proposal")
	local newProposal = routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	if util.tracelog then 	
		--debugPrint(newProposal)
	end
	local debugInfo = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if util.tracelog then 	
		debugPrint({ collisionInfo = debugInfo.collisionInfo , errorState = debugInfo.errorState})
		if params.buildCrossoverSlipSwitchOnly then 
			--debugPrint({buildCrossoverSlipSwitchOnly=debugInfo})
		end
		
	end
	if debugInfo.errorState.critical then 
		return false 
	end
	if params.buildCrossoverSlipSwitchOnly then -- the game sometimes silently turns our doubleSlipSwitch into a crossover, this is how to work out if this happened
		local ourTnEntity = debugInfo.entity2tn[-10003] --TODO un-hardcode
		if not ourTnEntity and util.tracelog then 
			debugPrint(debugInfo)
		end
		trace("buildCrossoverSlipSwitchOnly, resultant nodes was",#ourTnEntity.nodes, "edges was",#ourTnEntity.edges)
		--assert(#ourTnEntity.nodes == 5)
		if #ourTnEntity.edges == 4 then 
			trace("Rejecting solution as doubleslipswitch was removed")
			return false
		end 
	end 
	

	if #debugInfo.errorState.messages > 0 and not ignoreErrors then 
		return false
	end
	trace("About to build command to build crossover spur from node")

	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace("About to send command to build crossover spur from node")
	local wrappedCallback = callback
	if foundDepotEdge then 
		local depotPos = util.getEdgeMidPoint(foundDepotEdge)
		wrappedCallback = function(res, success) 
			callback(res,success)
			if success then 
				util.clearCacheNode2SegMaps()
				routeBuilder.addDelayedWork(function() 
					routeBuilder.reconnectDepotAfter(depotPos, params)				
				end) 
			end 
		end 
	end 
	
	api.cmd.sendCommand(build,  wrappedCallback)
	return true
end

local function buildCrossoverRepeat(routeInfo, station, params, edgeIdx, callback)
	trace("Begin buildCrossoverRepeat for",station)
	util.cacheNode2SegMaps()
	local success = false
 	params.maxCrossoverEdgeLength = 50
	params.offsetIndex = 0
	params.useBasicHermite= false
	params.forceExtensionToTerminal = false
	params.useFullCollisionSolution =true
	local originalTrackOffset = params.junctionTrackOffset
	local function err(e) 
		print("An error occured trying to build crossover",e)
		print(debug.traceback()) 
	end
	params.junctionTrackOffset = 10
	xpcall(function() success = tryBuildCrossover(routeInfo, station, 0, false, params, edgeIdx, callback) end, err)
	if success then 
		trace("Success build crossover on first attempt")
		return
	end 
 
	for i = -3, 3 do 
		params.useBasicHermite= (i%2)==1
		params.tryToCorrectDeflectionAngle = (i%2)==0
		params.offsetIndex = i>0 and i or 0
		params.junctionTrackOffset = 10+i*2 
		for maxCrossoverLength = 90, 30, -5 do 
			params.maxCrossoverEdgeLength = maxCrossoverLength
			--if params.junctionTrackOffset < 20 then 
			--	params.junctionTrackOffset = params.junctionTrackOffset+1
			--end
			trace("Attempting crossover build at i=",i, " params.offsetIndex=",params.offsetIndex,"for",station,"params.junctionTrackOffset=",params.junctionTrackOffset)
			xpcall(function() success = tryBuildCrossover(routeInfo, station, math.rad(i), false, params, edgeIdx, callback) end, err)
			if success then 
				break 			
			end
		end
		if success then 
			break 			
		end
	end

	if not success then 
		for i = -5, 5 do 
			params.tryToCorrectDeflectionAngle = (i%2)==0
			params.useBasicHermite= (i%2)==0
			params.offsetIndex = i>0 and i or 0
			params.junctionTrackOffset = originalTrackOffset+i*2 -- 14 -> 26
			for maxCrossoverLength = 70, 40, -5 do 
					params.maxCrossoverEdgeLength = maxCrossoverLength
					if params.junctionTrackOffset < 20 then 
						params.junctionTrackOffset = params.junctionTrackOffset+1
					end
				trace("Attempting crossover build at i=",i, " params.offsetIndex=",params.offsetIndex)
				xpcall(function() success = tryBuildCrossover(routeInfo, station, math.rad(i), true, params, edgeIdx, callback)end, err)
				if success then 
					break 			
				end
			end
			if success then 
				break 			
			end
		end
	
	end
	if not success and params.buildCrossoverSlipSwitchOnly then 
		for i = 0, 5 do
			params.offsetIndex = i>0 and i or 0
			params.forceExtensionToTerminal = true
			xpcall(function() success = tryBuildCrossover(routeInfo, station, math.rad(i), true, params, edgeIdx, callback)end, err)
			if success then 
				break 			
			end
		end
	end
	params.junctionTrackOffset = originalTrackOffset
	params.forceExtensionToTerminal = false	
	if not success and not params.buildCrossoverSlipSwitchOnly then 
		params.buildCrossoverSlipSwitchOnly = true 
		buildCrossoverRepeat(routeInfo, station, params, edgeIdx, callback)
		params.buildCrossoverSlipSwitchOnly = false
		return
	end
	if not success then 
		trace("WARNING! buildCrossoverRepeat failed!")
		callback({}, success)
	end
	util.clearCacheNode2SegMaps()
end


function routeBuilder.buildCrossoverForDoubleTerminals(params, station, callback)
	trace("Begin buildCrossoverForDoubleTerminals")
	local line = util.getLine(params.lineId)
	local routeInfo
	for i = 1, #line.stops do 
		local priorStop = i ==1 and line.stops[#line.stops] or line.stops[i-1]
		local thisStation = util.stationFromStop(line.stops[i])
		if thisStation == station then 
			routeInfo = pathFindingUtil.getRouteInfo(util.stationFromStop(priorStop), thisStation)
			trace("Found our station at i=",i, "Got routeinfo?",routeInfo)
			break
		end 
	end 
	local edgeIdx = routeInfo.lastFreeEdge
	buildCrossoverRepeat(routeInfo, station, params, edgeIdx, callback)
	
end 
function routeBuilder.buildJunctionSignals(edge1, node1, edge2, node2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, removedEdgeSet)
	if not edge1 or not edge2 then 
		trace("Cannot find edge")
		return 
	end
	local nextEdgeId1 = util.findNextEdgeInSameDirection(edge1, node1 )
	local nextEdgeId2 = util.findNextEdgeInSameDirection(edge2, node2 )
	if not nextEdgeId1 or not nextEdgeId2 then 
		trace("Cannot find another edge")
		return 
	end
	if util.isJunctionEdge(nextEdgeId1) or util.isJunctionEdge(nextEdgeId2) then 
		trace("Aborting signal build on ",nextEdgeId1, nextEdgeId2," as junction was discovered")
		return 
	end
	
	if #util.getEdge(nextEdgeId1).objects == 0 and #util.getEdge(nextEdgeId2).objects == 0 then 
		local newNextEdge = util.copyExistingEdge(nextEdgeId1, nextEdgeId())
		if removedEdgeSet and (removedEdgeSet[nextEdgeId1] or removedEdgeSet[nextEdgeId2]) then 
			trace("Aborting as this was already removed")
			return
		end
		table.insert(edgesToAdd, newNextEdge)
		table.insert(edgesToRemove, nextEdgeId1) 
		local newNextEdge2 = util.copyExistingEdge(nextEdgeId2, nextEdgeId())
		table.insert(edgesToAdd, newNextEdge2)
		table.insert(edgesToRemove, nextEdgeId2)
		trace("Junction signals removed ",nextEdgeId1, nextEdgeId2)
		routeBuilder.buildJunctionSignalsOnNewEdges(newNextEdge, node1, newNextEdge2, node2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId)
		if removedEdgeSet then 
			removedEdgeSet[nextEdgeId1]=true 
			removedEdgeSet[nextEdgeId2]=true 
		end
	end
end
function routeBuilder.buildJunctionSignalsOnNewEdges(newNextEdge, node1, newNextEdge2, node2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, forCrossover)
		--local perpAngle2 = util.signedAngle(vec3.normalize(util.nodePos(node1)-util.nodePos(node2)), vec3.normalize(util.nodePos(newNextEdge.comp.node1), util.nodePos(newNextEdge.comp.node0)))
		local isNode0 = newNextEdge.comp.node0==node1 
		local perpAngle = util.signedAngle(util.nodePos(node1)-util.nodePos(node2), isNode0 and util.v3(newNextEdge.comp.tangent0) or util.v3(newNextEdge.comp.tangent1))
		local negPerp =  perpAngle < 0 
--		local left = isNode0 == negPerp 
		local left = negPerp
		local paramDir = newNextEdge.comp.node1==node1
		if forCrossover then 
			paramDir = not paramDir 
		end
		local param = paramDir and 0.9 or 0.1
		trace("Junction signal 1: The perp angle was ",math.deg(perpAngle), " was node0 =",newNextEdge.comp.node0==node1, " dist between nodes was ",util.distBetweenNodes(node1, node2), "left=",left, " param was ",param)
		if #newNextEdge.comp.objects == 0 then 
			buildSignal(edgeObjectsToAdd, newNextEdge, left, param, true)
		end
		
		local isNode0 = newNextEdge2.comp.node0==node2
		local perpAngle = util.signedAngle(util.nodePos(node1)-util.nodePos(node2), isNode0 and util.v3(newNextEdge2.comp.tangent0) or util.v3(newNextEdge2.comp.tangent1)) 
		local posPerp =  perpAngle > 0 
		--local left = isNode0 == posPerp 
		local left = posPerp
		local paramDir = newNextEdge2.comp.node1==node2
		if forCrossover then 
			paramDir = not paramDir 
		end
		local param = paramDir and 0.9 or 0.1
		trace("Junction signal 2: The perp angle was ",math.deg(perpAngle), " was node0 =",newNextEdge2.comp.node0==node2,"left=",left, " param was ",param)
		if #newNextEdge2.comp.objects == 0 then 
			buildSignal(edgeObjectsToAdd, newNextEdge2, left, param, true)
		end
end


function routeBuilder.buildJunctionSpur(nodesToAdd, edgesToAdd, edgesToRemove, edgeObjectsToAdd, edgeObjectsToRemove, routeInfo, junctionIdx, directionSign, perpSign, joinNode, nextEdgeId, getNextNodeId, params, destinationPos, isStationJunction, connectNode, otherStationNode)
	trace("Building juntion spur, junctionTrackOffset=",params.junctionTrackOffset,"junctionIdx=",junctionIdx,"joinNode=",joinNode,"isStationJunction?",isStationJunction)
	local buildGradeSeparatedTrackJunctions = params.buildGradeSeparatedTrackJunctions and not isStationJunction
	if buildGradeSeparatedTrackJunctions then 
		params.junctionTrackOffset  =  math.max(params.junctionTrackOffset, 15) 
	end 
	local suppressSignals = false
	local removedEdgeSet = {}
	local replacedEdgesMap = {} 
	local newNodePosMap = {}
	local newNodeMap = {}
	local function getOrMakeReplacedEdge(edgeId) 
		if not replacedEdgesMap[edgeId] then 
			local entity = util.copyExistingEdge(edgeId, nextEdgeId())
			trace("buildJunctionSpur - getOrMakeReplacedEdge: Created entity",newEdgeToString(entity))
			table.insert(edgesToAdd, entity)
			if not removedEdgeSet[edgeId] then 
				trace("buildJunctionSpur - getOrMakeReplacedEdge removing edge",edgeId, " replacement",newEdgeToString(entity))
				table.insert(edgesToRemove, edgeId)
				removedEdgeSet[edgeId]=true
			else 
				trace("WARNING! Edge",edgeId," was already removed in buildJunctionSpur - getOrMakeReplacedEdge")
			end 
			if #entity.comp.objects > 0 then 
				trace("Edge objects found on ",entity.entity," removing")
				for i, edgeObj in pairs(entity.comp.objects) do 
					table.insert(edgeObjectsToRemove, edgeObj[1])
				end 
				entity.comp.objects = {}
			end 
			replacedEdgesMap[edgeId] = entity 
			return entity
		else 
			return replacedEdgesMap[edgeId]
		end 
	end 
	
	local function checkEdge(idx, forbidRecurse) 
		if not routeInfo.edges[idx] then 
			return false 
		end 
		local edgeId = routeInfo.edges[idx].id
		if not api.engine.entityExists(edgeId) or not util.getEdge(edgeId) then 
			return false
		end 
		if util.isJunctionEdge(edgeId) then 
			return false 
		end 
		if util.getEdgeLength(edgeId) < 70 then 
			return false 
		end
		if routeInfo.changeIndexes and  routeInfo.changeIndexes[idx] then 
			return false
		end
		if params.buildGradeSeparatedTrackJunctions then 
			return checkEdge(idx-1, true) and checkEdge(idx+1, true) and checkEdge(idx-2, true) and checkEdge(idx+2, true)
		end 
		return true 
	end 
	
	local edgeAndId = routeInfo.edges[junctionIdx]
	local isUseNode0 = edgeAndId.edge.node0 == joinNode
	if not checkEdge(junctionIdx) then 
		trace("WARNING! too short edge detected: ",util.getEdgeLength(edgeAndId.id))
		--local nextEdgeId = routeInfo.edges[junctionIdx+1] and  routeInfo.edges[junctionIdx+1].id
		--local priorEdgeId = routeInfo.edges[junctionIdx-1] and  routeInfo.edges[junctionIdx-1].id
		if checkEdge(junctionIdx+1) then 
			junctionIdx = junctionIdx+1 
			edgeAndId = routeInfo.edges[junctionIdx]
			trace("Solved with next")
		elseif checkEdge(junctionIdx-1) then
			junctionIdx = junctionIdx-1 
			edgeAndId = routeInfo.edges[junctionIdx]
			trace("Solved with prior")
		else 
			trace("WARNING! unable to find any attempting anyway")
--			return false 
		end 
	end
	trace("Using junctionIdx=",junctionIdx,"isUseNode0?",isUseNode0)
	local edge = edgeAndId.edge
	local entity = util.copyExistingEdge(edgeAndId.id, nextEdgeId())
	entity.comp.objects = {}
	table.insert(edgesToAdd, entity)
	local entity2 = util.copyExistingEdge(edgeAndId.id, nextEdgeId())
	entity2.comp.objects = {}
	table.insert(edgesToAdd, entity2)
	local trackOffset = params.junctionTrackOffset
	if buildGradeSeparatedTrackJunctions and not params.isHighSpeedTrack then 
		trackOffset = math.max(20, trackOffset)
		trace("Set trackoffset to ",trackOffset)
	end 
	local node = isUseNode0 and edge.node1 or edge.node0
	local nodePos = util.nodePos(node)
	local tangent = util.v3(node == edge.node0 and edge.tangent0 or edge.tangent1)
	 
	local node2 = util.findDoubleTrackNode(nodePos, tangent)
	if not node2 then 
		return false 
	end
	local nodePos2 = util.nodePos(node2)
	local zoffset = 5 --params.minZoffset / 2
	
	joinNode = isUseNode0 and edge.node0 or edge.node1
	local joinNodePos = util.nodePos(joinNode)
	local joinTangent = isUseNode0 and util.v3(edge.tangent0) or -1*util.v3(edge.tangent1)
	local joinNode2 = util.findDoubleTrackNode(joinNodePos, joinTangent)
	if not joinNode2 then 
		return false 
	end
	local joinNode2Pos = util.nodePos(joinNode2)

	local useInitialEdge = util.distance(nodePos, destinationPos)<util.distance(nodePos2, destinationPos)
	local closestExitNodePos =  useInitialEdge and nodePos or nodePos2
	if not useInitialEdge then 
		joinNodePos = joinNode2Pos
	end 
	
	if connectNode and otherStationNode then  
		local trialPos = 	 util.nodePointPerpendicularOffset(closestExitNodePos,perpSign*tangent, trackOffset)	

		local trackVector = trialPos - closestExitNodePos
		local trackVector2 = util.nodePos(connectNode) - util.nodePos(otherStationNode)
		local exitTangent = util.getDeadEndNodeDetails(connectNode).tangent 
		if isUseNode0 then 
			trace("buildJunctionSpur: inverting exit tangent for angle check")
			exitTangent = -1*exitTangent
		end 
		local angle = util.signedAngle(trackVector, trackVector2)
		local angle2 = util.signedAngle(trackVector2, exitTangent)
		local angle3 = util.signedAngle(tangent, exitTangent)
		local angle4 = util.signedAngle(trackVector2, tangent)
		local angle5 = util.signedAngle(trackVector, exitTangent)
		trace("buildJunctionSpur: inspecting connectNode and otherStationNode angles were",math.deg(angle),math.deg(angle2),math.deg(angle3), math.deg(angle4),"isUseNode0?",isUseNode0)
		-- want to build the extension on the same side, expect the relative angle to be +/- 90 degrees, check they line up 
		--local correctedAngle1 = math.abs(angle) --- math.rad(90)
		--local correctedAngle2 = math.abs(angle4) -- - math.rad(90)
		local sign1 = angle5 < 0 and -1 or 1 
		local sign2 = angle4 < 0 and -1 or 1
		local invertPerpSign = sign1 ~= sign2
		
		if invertPerpSign then 
			perpSign = -perpSign
		end 
		trace("buildJunctionSpur: the correctedAngles were",math.deg(angle5),math.deg(angle4)," signs were",sign1,sign2,"invertPerpSign?",invertPerpSign, " perpSign was",perpSign)
	end
	
	local newNodePos = util.nodePointPerpendicularOffset(closestExitNodePos,perpSign*tangent, trackOffset)	
	local naturalTangent = newNodePos - joinNodePos
	local shouldLimitTrackOffset = params.isHighSpeedTrack and  util.distance(nodePos, destinationPos) > 1000
	local maxTrackOffset = shouldLimitTrackOffset and 2*params.junctionTrackOffset or 3*params.junctionTrackOffset
	maxTrackOffset = math.min(maxTrackOffset, 0.5*util.calculateSegmentLengthFromEdge(edge))
	trace("Setting the maxTrackOffset to ",maxTrackOffset)
	if destinationPos and not isStationJunction then 
		local angle = util.signedAngle(naturalTangent, destinationPos-newNodePos)
		trace("Angle to the destination was ",math.deg(angle))
		local prevAngle = angle
		while math.abs(angle) > math.rad(30) and trackOffset <= maxTrackOffset do 
			trackOffset = trackOffset + 1
			newNodePos = util.nodePointPerpendicularOffset(closestExitNodePos,perpSign*tangent, trackOffset)	
			naturalTangent = newNodePos - joinNodePos
			angle = util.signedAngle(naturalTangent, destinationPos-newNodePos)
			trace("At track offset = ", trackOffset, " angle to the destination was ",math.deg(angle))
			if math.abs(angle) > math.abs(prevAngle) then 
				trace("Angle was worse, aborting")
				trackOffset = trackOffset - 1
				newNodePos = util.nodePointPerpendicularOffset(closestExitNodePos,perpSign*tangent, trackOffset)	
				naturalTangent = newNodePos - joinNodePos
				break
			end
			prevAngle = angle
		end
	end
	local tangentDeflectionAngle = util.signedAngle(naturalTangent, joinTangent)
	local exitTangent = util.rotateXYkeepingZ(joinTangent, -2*tangentDeflectionAngle)
	local testP = newNodePos + 90 * vec3.normalize(exitTangent) 
	trace("The testP for extra track offset was at ",testP.x, testP.y)
	if not isStationJunction then 
		for i, edge in pairs(util.searchForEntities(testP, 10, "BASE_EDGE")) do 
			if edge.track then 
				trace("Discovered a track edge, increasing offset")
				trackOffset = math.min(trackOffset + 10,maxTrackOffset)
				newNodePos = util.nodePointPerpendicularOffset(closestExitNodePos,perpSign*tangent, trackOffset)	
			
				break 
			end
		end 
	end
	if buildGradeSeparatedTrackJunctions then 
		newNodePos.z = newNodePos.z + 0.75*zoffset
	end 
	naturalTangent = newNodePos - joinNodePos
	
	local newNode = newNodeWithPosition(newNodePos, getNextNodeId())
	table.insert(nodesToAdd, newNode)
	newNodePosMap[newNode.entity]=newNodePos
	newNodeMap[newNode.entity]=newNode 
	
	
	
	assert(joinNode2~=node2)
	local edgeId2 = util.findEdgeConnectingNodes(joinNode2, node2)
	local relativeNodeTangent = util.nodePos(joinNode2)-util.nodePos(joinNode)
	local perpSign2 = perpSign
	if math.abs(tangentDeflectionAngle) < math.rad(45) then 
		if util.distance(joinNodePos+joinTangent, newNodePos) > util.distance(joinNodePos-joinTangent, newNodePos) then
			trace("buildJunctionSpur: inverting the joinTangent and perpSign")
			joinTangent = -1*joinTangent
			perpSign = -perpSign
		end	
	else 
		if util.distance(joinNodePos+joinTangent, newNodePos) < util.distance(joinNodePos-joinTangent, newNodePos) then
			trace("buildJunctionSpur: inverting the joinTangent and perpSign")
			joinTangent = -1*joinTangent
			perpSign = -perpSign
		end	
	end 
	--[[
	--local length = vec3.length(naturalTangent)
	local dummyPos = joinNodePos+trackOffset*vec3.normalize(joinTangent)
	local offsetTangent = newNodePos - dummyPos 
	local length = vec3.length(offsetTangent) + trackOffset
	trace("naturalTangent was ",naturalTangent.x, naturalTangent.y, " length was",vec3.length(naturalTangent)," new length =",length)
	--local exitTangent = util.rotateXY(joinTangent, perpSign*math.rad(10))
	local exitTangent = length*vec3.normalize(offsetTangent)
	]]--
	tangentDeflectionAngle = util.signedAngle(naturalTangent, joinTangent)
	local rotateFactor = -2 --buildGradeSeparatedTrackJunctions and -1.5 or -2
	exitTangent = util.rotateXYkeepingZ(joinTangent, rotateFactor*tangentDeflectionAngle)
	local length = vec3.length(naturalTangent)
	local newNode2Pos = util.doubleTrackNodePoint(newNodePos, perpSign*exitTangent)
	local ourRelativeTangent = newNode2Pos-newNodePos
	local entity1JoinNode
	local entity2JoinNode
	local relativeTangentAngle = util.signedAngle(relativeNodeTangent, ourRelativeTangent)
	trace("The relativeTangentAngle was ", math.deg(relativeTangentAngle))
	if math.abs(relativeTangentAngle) > math.rad(90) then 
		entity1JoinNode = joinNode2
		entity2JoinNode = joinNode
		naturalTangent = newNodePos - joinNode2Pos 
		tangentDeflectionAngle = util.signedAngle(naturalTangent, joinTangent)
		exitTangent = util.rotateXYkeepingZ(joinTangent, -2*tangentDeflectionAngle)
		length = vec3.length(naturalTangent)
		 
	else 
		entity1JoinNode = joinNode
		entity2JoinNode = joinNode2
	end 
	
	
	local correctionFactor = 1 + math.sin(math.abs(tangentDeflectionAngle))*(4 * (math.sqrt(2) - 1)-1)
	--local correctedLength = correctionFactor*length
	local correctedLength =  util.calculateTangentLength(util.nodePos(entity1JoinNode), newNodePos, joinTangent, exitTangent)
	trace("The tangentDeflectionAngle was ",math.deg(tangentDeflectionAngle)," with a correctionFactor=",correctionFactor," correctedLength=",correctedLength," original length=",length, " the trackOffset was",trackOffset)
	
	local newNode2 = newNodeWithPosition(newNode2Pos, getNextNodeId())
	table.insert(nodesToAdd, newNode2)
	newNodePosMap[newNode2.entity]=newNode2Pos
	newNodeMap[newNode2.entity]=newNode2
	entity.comp.node0 = entity1JoinNode
	entity.comp.node1 = newNode.entity
	entity2.comp.node0 = entity2JoinNode
	entity2.comp.node1 = newNode2.entity
	entity.comp.objects = {} 
	entity2.comp.objects = {}
	trace("the join node was ",entity1JoinNode," join node2 ",entity2JoinNode, " edgeId=",edgeAndId.id,"edgeId2=",edgeId2, " node was",node," node2 was",node2, " newNode.entity=",newNode.entity,"  newNode2.entity=", newNode2.entity, " trackOffset=",trackOffset)
	if not edgeId2 then	
		trace("WARNING! No edgeId2 was found") 
		return 
	end

	local correctedJoinTangent = correctedLength*vec3.normalize(joinTangent)
	local correctedExitTangent = correctedLength*vec3.normalize(exitTangent)
	setTangent(entity.comp.tangent0, correctedJoinTangent)
	setTangent(entity.comp.tangent1, correctedExitTangent)	
	--setTangent(entity.comp.tangent0, joinTangent)
	--setTangent(entity.comp.tangent1, exitTangent)	
	setTangent(entity2.comp.tangent0, correctedJoinTangent)
	setTangent(entity2.comp.tangent1, correctedExitTangent)	

	trace("buildJunctionSpur - created diverging edges: ",newEdgeToString(entity), newEdgeToString(entity2))
	local newEdge1 = {
		p0 = util.nodePos(entity1JoinNode),
		p1 = newNodePos,
		t0 = util.v3(entity.comp.tangent0),
		t1 = util.v3(entity.comp.tangent1),
	}
	local newEdge2 = {
		p0 = util.nodePos(entity2JoinNode),
		p1 = newNode2Pos,
		t0 = util.v3(entity2.comp.tangent0),
		t1 = util.v3(entity2.comp.tangent1),
	}
	local ourCollisionEdge
	local ourOtherEdge
	local theirCollisionEdge
	local edge1CollideCandidate = entity1JoinNode == joinNode2 and edgeAndId.id or edgeId2
	local collisionJoinNode
	local nonCollisionJoinNode
	local s = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(edge1CollideCandidate, newEdge1)
	local ourOtherInputEdge 
	local exitNodePerpSign
	if not s then 
		local edge2CollideCandidate = entity2JoinNode == joinNode and  edgeId2 or edgeAndId.id
		s = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(edge2CollideCandidate, newEdge2)
		if not s then 
			if util.tracelog then debugPrint({newEdge1=newEdge1, newEdge2=newEdge2}) end
			return false
		end
		assert(s)
		ourCollisionEdge = entity2
		ourOtherEdge = entity
		exitNodePerpSign = -perpSign
		ourOtherInputEdge = newEdge1
		theirCollisionEdge = edge2CollideCandidate
		collisionJoinNode = entity1JoinNode
		nonCollisionJoinNode = entity2JoinNode
		trace("The collision was with edge2")
	else 
		ourCollisionEdge = entity
		ourOtherEdge = entity2
		ourOtherInputEdge = newEdge2
		theirCollisionEdge = edge1CollideCandidate
		exitNodePerpSign = perpSign
		collisionJoinNode = entity2JoinNode
		nonCollisionJoinNode = entity1JoinNode
		trace("The collision was with edge1")
		 
	end
	trace("Colllision point was ",s.c.x,s.c.y)

	local function replaceNode(entity, oldNode, newNode, tangentCorrection ) 
		trace("buildJunctionSpur - replacing node on entity, swapping ",oldNode," with ",newNode, " for ",newEdgeToString(entity))
		if entity.comp.node0 == oldNode then 
			entity.comp.node0 = newNode
			if tangentCorrection then 
				entity.comp.tangent0.z = entity.comp.tangent0.z+tangentCorrection
			end
			
		elseif entity.comp.node1 == oldNode then
			entity.comp.node1 = newNode 
			if tangentCorrection then 
				entity.comp.tangent1.z = entity.comp.tangent1.z-tangentCorrection
			end
		else 
			trace("WARNING! node ",oldNode," not found on ",entity.entity)
		end 
	end
	local ourCollisionEdge2 = ourCollisionEdge
	local otherEdge2 = ourOtherEdge
	local theirNonCollisionEdge = theirCollisionEdge == edgeAndId.id and edgeId2 or edgeAndId.id
	if #util.getEdge(theirNonCollisionEdge).objects > 0 then 
		trace("Removing edge objects from",theirNonCollisionEdge)
		local theirOtherEdge = getOrMakeReplacedEdge(theirNonCollisionEdge, nextEdgeId())
		for i , edgeObj in pairs(theirOtherEdge.comp.objects) do
			if not util.contains(edgeObjectsToRemove, edgeObj[1]) then 
				table.insert(edgeObjectsToRemove, edgeObj[1])
			end
		end
		theirOtherEdge.comp.objects = {} 
	end
	
	
	if buildGradeSeparatedTrackJunctions then 
		trace("buildJunctionSpur - begin buildGradeSeparatedTrackJunctions")
		local isEdge1 = theirCollisionEdge == edgeAndId.id
		local newNonCollisionJoinNode = copyNodeWithZoffset(nonCollisionJoinNode, zoffset, getNextNodeId())
		table.insert(nodesToAdd, newNonCollisionJoinNode)
		local offset = 0.5*params.trackWidth
		local offsetPos = util.nodePointPerpendicularOffset(util.nodePos(nonCollisionJoinNode), perpSign*util.v3(ourOtherEdge.comp.tangent0),offset)
		if util.distance(offsetPos, util.nodePos(collisionJoinNode))<5 then 
			offsetPos = util.nodePointPerpendicularOffset(util.nodePos(nonCollisionJoinNode), perpSign*util.v3(ourOtherEdge.comp.tangent0),-offset)
		end
		newNonCollisionJoinNode.comp.position.x = offsetPos.x
		newNonCollisionJoinNode.comp.position.y = offsetPos.y
		local newCollisionJoinNode = copyNodeWithZoffset(collisionJoinNode, -zoffset, getNextNodeId()) 
		table.insert(nodesToAdd, newCollisionJoinNode)
		newNodePosMap[newCollisionJoinNode.entity]=util.v3(newCollisionJoinNode.comp.position)
		newNodeMap[newCollisionJoinNode.entity]=newCollisionJoinNode
		
		replaceNode(ourCollisionEdge, nonCollisionJoinNode, newNonCollisionJoinNode.entity)
		for i, seg in pairs(util.getSegmentsForNode(nonCollisionJoinNode)) do 
			replaceNode(getOrMakeReplacedEdge(seg), nonCollisionJoinNode, newNonCollisionJoinNode.entity)
		end 
		local inputCollisionEdge = {
			p0 = util.v3(newNonCollisionJoinNode.comp.position),
			p1 = newNodePosMap[ourCollisionEdge.comp.node1],
			t0 = util.v3(ourCollisionEdge.comp.tangent0),
			t1 = util.v3(ourCollisionEdge.comp.tangent1)
		}
		inputCollisionEdge.p1.z = inputCollisionEdge.p0.z
		local exitFactor = 0.6
		local split = util.solveForPositionHermiteFraction(exitFactor, inputCollisionEdge )
		split.p.z = newNonCollisionJoinNode.comp.position.z
		local collisionSplitNode = newNodeWithPosition(split.p, getNextNodeId())
		table.insert(nodesToAdd, collisionSplitNode)
		--local 
		ourCollisionEdge2 = copySegmentAndEntity(ourCollisionEdge, nextEdgeId())
		table.insert(edgesToAdd, ourCollisionEdge2)
		ourCollisionEdge.comp.node1 = collisionSplitNode.entity 
		setTangent(ourCollisionEdge.comp.tangent0, split.t0)
		setTangent(ourCollisionEdge.comp.tangent1, split.t1) 
		ourCollisionEdge2.comp.node0 = collisionSplitNode.entity 
		setTangent(ourCollisionEdge2.comp.tangent0, split.t1)
		setTangent(ourCollisionEdge2.comp.tangent1, split.t1)
		local updatedExitNodePos = split.p + split.t1
		setPositionOnNode(newNodeMap[ourCollisionEdge2.comp.node1], updatedExitNodePos)
		newNodePosMap[ourCollisionEdge2.comp.node1]=updatedExitNodePos
		trace("Set newNodePosMap[ourCollisionEdge2.comp.node1] = ",updatedExitNodePos, "ourCollisionEdge2.comp.node1=",ourCollisionEdge2.comp.node1, "ourCollisionEdge2.entity=",ourCollisionEdge2.entity)
		local updatedExitNodePos2 = util.doubleTrackNodePoint(updatedExitNodePos, exitNodePerpSign*split.t1)
		setPositionOnNode(newNodeMap[ourOtherEdge.comp.node1], updatedExitNodePos2)
		newNodePosMap[ourOtherEdge.comp.node1]=updatedExitNodePos2
		setTangent(ourOtherEdge.comp.tangent1, split.t1)
		
		local zcorrection1 = isEdge1 and -zoffset or 0.5*zoffset
		local nodeReplacement1 = copyNodeWithZoffset(node, zcorrection1, getNextNodeId())
		table.insert(nodesToAdd, nodeReplacement1)
		newNodePosMap[nodeReplacement1.entity]=util.v3(nodeReplacement1.comp.position)
		local zcorrection2 = isEdge1 and 0.5*zoffset or -zoffset
		local nodeReplacement2 = copyNodeWithZoffset(node2,zcorrection2 , getNextNodeId())
		table.insert(nodesToAdd, nodeReplacement2)
		newNodePosMap[nodeReplacement2.entity]=util.v3(nodeReplacement2.comp.position)
		for i, seg in pairs(util.getSegmentsForNode(node)) do 
			local tangentCorrection = seg == edgeAndId.id and zcorrection1 or -zcorrection1
			replaceNode(getOrMakeReplacedEdge(seg), node, nodeReplacement1.entity, tangentCorrection)
		end 
		for i, seg in pairs(util.getSegmentsForNode(node2)) do 
			local tangentCorrection = seg == edgeId2 and zcorrection2 or -zcorrection2
			replaceNode(getOrMakeReplacedEdge(seg), node2, nodeReplacement2.entity, tangentCorrection)
		end 
		trace("Building grade separated crossover, isEdge1?",isEdge1," zcorrection1=",zcorrection1,"zcorrection2=",zcorrection2)
		local newNodeToOffset 
		local otherNode
		local exitHeight 
		if isEdge1 then 
			newNodeToOffset = nodeReplacement2 
			otherNode = node 
			exitHeight = nodeReplacement1.comp.position.z
		else 
			newNodeToOffset = nodeReplacement1 
			otherNode = node2
			exitHeight = nodeReplacement2.comp.position.z
		end 
		local offset = 0.5*params.trackWidth
		local pos = util.v3(newNodeToOffset.comp.position)
		local offsetPos = util.nodePointPerpendicularOffset(pos, perpSign*tangent,offset)
		if util.distance(offsetPos, util.nodePos(otherNode))<5 then 
			offsetPos = util.nodePointPerpendicularOffset(pos, perpSign*tangent,-offset)
		end
		newNodeToOffset.comp.position.x = offsetPos.x
		newNodeToOffset.comp.position.y = offsetPos.y
		
		--[[
		local outerEdge1 = util.getEdge( util.findNextEdgeInSameDirection(edgeAndId.id, joinNode))
		local outerEdge2 = util.getEdge(util.findNextEdgeInSameDirection(edgeId2, joinNode2))
		local otherOuterNode1 = outerEdge1.node0 == joinNode and outerEdge1.node1 or outerEdge1.node0 
		local otherOuterNode2 = outerEdge1.node0 == joinNode and outerEdge1.node1 or outerEdge1.node0 
		]]--
		local theirNextEdge = util.findNextEdgeInSameDirection(theirCollisionEdge, collisionJoinNode)
		if util.isJunctionEdge(theirNextEdge) then 
			trace("buildJunctionSpur: aborting as found junction edge at",theirNextEdge)
			return false
		end 
		local theirNextEdgeFull = util.getEdge(theirNextEdge) 
		local theirCollisionEdgeFull = util.getEdge(theirCollisionEdge)
		local solutionPoint  = theirCollisionEdgeFull.node0 == collisionJoinNode and 0.75 or 0.25
		local s1 = util.solveForPositionHermiteFractionExistingEdge(solutionPoint, theirCollisionEdge)
		--[[local s1 = util.solveForPositionHermiteFraction(solutionPoint2, {
			p0 = isNode0 and util.nodePos(theirNextEdgeFull.node0) or outerJoinNodePos,
			p1 = isNode0 and outerJoinNodePos or util.nodePos(theirNextEdgeFull.node0),
			t0 = util.v3(theirNextEdgeFull.tangent0),
			t1 = util.v3(theirNextEdgeFull.tangent1)
		})]]--
		--[[
		local solutionPoint  = theirCollisionEdgeFull.node0 == collisionJoinNode and 0.75 or 0.25
		local s1 = util.solveForPositionHermiteFractionExistingEdge(solutionPoint, theirCollisionEdge)
		s1.p.z = s1.p.z-zoffset
		
		local solutionPoint2  = theirNextEdgeFull.node0 == collisionJoinNode and 0.6 or 0.4
		local s2 = util.solveForPositionHermiteFractionExistingEdge(solutionPoint2, theirNextEdge)
		]]--
		
		s1.p.z = s1.p.z-zoffset
		local isNode0 = collisionJoinNode == theirNextEdgeFull.node0
		local outerJoinNode = isNode0 and theirNextEdgeFull.node1 or theirNextEdgeFull.node0 
		local outerJoinNodePos = util.v3(util.nodePos(outerJoinNode),true)
		local dist = util.distance(offsetPos, outerJoinNodePos)
		local theirNextEdge2 = util.findNextEdgeInSameDirection(theirNextEdge, outerJoinNode)
		if util.isJunctionEdge(theirNextEdge2) then 
			trace("buildJunctionSpur: aborting as found junction edge at",theirNextEdge2)
			return false
		end 
		local theirNextEdgeFull2 = util.getEdge(theirNextEdge2) 
		local outerJoinNode2 = theirNextEdgeFull2.node0 == outerJoinNode and theirNextEdgeFull2.node1 or theirNextEdgeFull2.node0
		
		local offset = 0.5*params.trackWidth
		local tangent = isNode0 and util.v3(theirNextEdgeFull.tangent1) or util.v3(theirNextEdgeFull.tangent0)
		local offsetPos = util.nodePointPerpendicularOffset(outerJoinNodePos,tangent,offset)
		local outerDoubleTrackNode = util.findDoubleTrackNode(outerJoinNode)
		if not outerDoubleTrackNode then
			trace("Initial attempt to find outerDoubleTrackNode for ",outerJoinNode," failed, attempting refresh caches")
			util.clearCacheNode2SegMaps()
			util.cacheNode2SegMaps()
			outerDoubleTrackNode = util.findDoubleTrackNode(outerJoinNode)
			if not outerDoubleTrackNode then
				trace("WARNING! Failed to find outerDoubleTrackNode for ",outerJoinNode)
				return false 
			end
		end 
		local distToOtherDoubleTrackNode =  util.distance(offsetPos, util.nodePos(outerDoubleTrackNode))
		trace("The distToOtherDoubleTrackNode was",distToOtherDoubleTrackNode)
		if distToOtherDoubleTrackNode <5 then 
			offsetPos = util.nodePointPerpendicularOffset(outerJoinNodePos,tangent,-offset)
			trace("After correction the dist was", util.distance(offsetPos, util.nodePos(outerDoubleTrackNode)))
		end
		outerJoinNodePos.x = offsetPos.x
		outerJoinNodePos.y = offsetPos.y
		outerJoinNodePos.z = outerJoinNodePos.z - 0.25*zoffset
		--[[local replacedOuterJoinNode = newNodeWithPosition(outerJoinNodePos, getNextNodeId())
		table.insert(nodesToAdd, replacedOuterJoinNode)
		
		local solutionPoint2  = isNode0 and 0.6 or 0.4
		local modifiedEdge =  {
			p0 = isNode0 and util.nodePos(theirNextEdgeFull.node0) or outerJoinNodePos,
			p1 = isNode0 and outerJoinNodePos or util.nodePos(theirNextEdgeFull.node1),
			t0 = util.v3(theirNextEdgeFull.tangent0),
			t1 = util.v3(theirNextEdgeFull.tangent1)
		}
		local s2 = util.solveForPositionHermiteFraction(solutionPoint2, modifiedEdge)
		trace("The distance for the modifiedEdge was",util.distance(modifiedEdge.p0, modifiedEdge.p1))
		]]--
		
		local newDist = util.distance(util.nodePos(outerJoinNode), updatedExitNodePos2)
		
		trace("The newDist was ",newDist," ourOtherEdge was ",ourOtherEdge.entity," isNode0?",isNode0)
		assert(ourOtherEdge.comp.node0==collisionJoinNode)
		local offset = 1.5*params.trackWidth
		local offsetPos = util.nodePointPerpendicularOffset(util.nodePos(collisionJoinNode), perpSign*util.v3(ourOtherEdge.comp.tangent0),offset)
		if util.distance(offsetPos, util.nodePos(nonCollisionJoinNode))<5 then 
			offsetPos = util.nodePointPerpendicularOffset(util.nodePos(collisionJoinNode), -perpSign*util.v3(ourOtherEdge.comp.tangent0),offset)
		end 
		
		
		--[[
		for i, seg in pairs(util.getSegmentsForNode(outerJoinNode)) do  
			replaceNode(getOrMakeReplacedEdge(seg), outerJoinNode, replacedOuterJoinNode.entity, 0)
		end ]]--
		local replacedCollisionJoinNode = newNodeWithPosition(offsetPos, getNextNodeId())
		table.insert(nodesToAdd, replacedCollisionJoinNode)
		ourOtherEdge.comp.node0 = replacedCollisionJoinNode.entity 
		newNodePosMap[replacedCollisionJoinNode.entity]=offsetPos
		--local joinTangent = isNode0 and -1*util.v3(theirNextEdgeFull.tangent1) or util.v3(theirNextEdgeFull.tangent0)
		local joinTangent = outerJoinNode2==theirNextEdgeFull2.node1 and -1*util.v3(theirNextEdgeFull2.tangent1) or util.v3(theirNextEdgeFull2.tangent0)
		local tangentDeflectionAngle = util.signedAngle(offsetPos-outerJoinNodePos, joinTangent)
		--util.setTangent(ourOtherEdge.comp.tangent0, util.rotateXYkeepingZ(util.v3(ourOtherEdge.comp.tangent0), rotateFactor*tangentDeflectionAngle))
		local tangentLength = util.calculateTangentLength(offsetPos, newNodePosMap[ourOtherEdge.comp.node1], util.v3(ourOtherEdge.comp.tangent0), util.v3(ourOtherEdge.comp.tangent1))
		util.setTangent(ourOtherEdge.comp.tangent0, tangentLength * vec3.normalize(util.v3(ourOtherEdge.comp.tangent0)))
		util.setTangent(ourOtherEdge.comp.tangent1, tangentLength * vec3.normalize(util.v3(ourOtherEdge.comp.tangent1)))
		local connectEdge = copySegmentAndEntity(ourOtherEdge, nextEdgeId()) 
		connectEdge.comp.objects = {}
		table.insert(edgesToAdd, connectEdge)
		dist= util.distance(offsetPos, util.nodePos(outerJoinNode2))
		trace("Added connectEdge with id ",connectEdge.entity," dist was",dist)
		connectEdge.comp.node1 = replacedCollisionJoinNode.entity
	--	connectEdge.comp.node0 = replacedOuterJoinNode.entity
		connectEdge.comp.node0 = outerJoinNode2
		dist = dist +5 
		util.setTangent(connectEdge.comp.tangent1, dist*vec3.normalize(util.v3(ourOtherEdge.comp.tangent0)))
		
		--util.setTangent(ourOtherEdge.comp.tangent1, newDist*vec3.normalize(util.v3(ourOtherEdge.comp.tangent1)))
	
		util.setTangent(connectEdge.comp.tangent0, dist*vec3.normalize(joinTangent))
		local doubleTrackVector = util.nodePos(collisionJoinNode)-util.nodePos(nonCollisionJoinNode)
		local left = util.signedAngle(doubleTrackVector, connectEdge.comp.tangent1)<0
		if not params.disableSignalBuild  then 
			buildSignal(edgeObjectsToAdd, connectEdge, left, 0.5, true)
		end
		for i, seg in pairs(util.getSegmentsForNode(collisionJoinNode)) do  
			replaceNode(getOrMakeReplacedEdge(seg), collisionJoinNode, newCollisionJoinNode.entity, -zoffset)
		end
		
		local parallelNextEdge = util.findDoubleTrackEdge(theirNextEdge)
		if parallelNextEdge then 
			local parallelNextEdgeFull = util.getEdge(parallelNextEdge)
			assert(parallelNextEdgeFull.node0==nonCollisionJoinNode or parallelNextEdgeFull.node1==nonCollisionJoinNode)
			local isNode0 = parallelNextEdgeFull.node0 == nonCollisionJoinNode
			local param = isNode0 and 0.1 or 0.9 
			local tangent = isNode0 and parallelNextEdgeFull.tangent0 or parallelNextEdgeFull.tangent1 
			local left = util.signedAngle(doubleTrackVector,tangent)>0
			if #util.getEdge(parallelNextEdge).objects == 0 and not params.disableSignalBuild then 
				buildSignal(edgeObjectsToAdd, getOrMakeReplacedEdge(parallelNextEdge), left, param, true)
			end
		else 
			trace("WARNING! Could not find parallelNextEdge for",theirNextEdge)
		end
		local collisionEdge1 = getOrMakeReplacedEdge(theirCollisionEdge)
		assert(theirNextEdgeFull.node0==collisionJoinNode or theirNextEdgeFull.node1==collisionJoinNode)
		local isNode0 = theirNextEdgeFull.node0 == collisionJoinNode
		local param = isNode0 and 0.9 or 0.1 
		local tangent = isNode0 and theirNextEdgeFull.tangent0 or theirNextEdgeFull.tangent1 
		local left = util.signedAngle(doubleTrackVector,tangent)<0
		local theirNewNextEdge = getOrMakeReplacedEdge(theirNextEdge)
		if #theirNewNextEdge.comp.objects == 0 and not params.disableSignalBuild then 
			buildSignal(edgeObjectsToAdd, theirNewNextEdge , left, param, true)
		end
		local collissionEdgeLength = vec3.length(collisionEdge1.comp.tangent1)
		if isNode0 then 
			theirNewNextEdge.comp.tangent0.z = util.nodePos(outerJoinNode).z - newNodePosMap[theirNewNextEdge.comp.node0].z
		
			if collisionEdge1.comp.node1 == theirNewNextEdge.comp.node0 then 
				util.setTangent(collisionEdge1.comp.tangent1, collissionEdgeLength*vec3.normalize(util.v3(theirNewNextEdge.comp.tangent0)))
			else 
				util.setTangent(collisionEdge1.comp.tangent0, -collissionEdgeLength*vec3.normalize(util.v3(theirNewNextEdge.comp.tangent0)))
			end
		else 
			theirNewNextEdge.comp.tangent1.z = newNodePosMap[theirNewNextEdge.comp.node1].z - util.nodePos(outerJoinNode).z 
			
			if collisionEdge1.comp.node1 == theirNewNextEdge.comp.node1 then 
				util.setTangent(collisionEdge1.comp.tangent1, -collissionEdgeLength*vec3.normalize(util.v3(theirNewNextEdge.comp.tangent1)))
			else 
				util.setTangent(collisionEdge1.comp.tangent0, collissionEdgeLength*vec3.normalize(util.v3(theirNewNextEdge.comp.tangent1)))
			end
		end 
		--local otherEdge1 = getOrMakeReplacedEdge(theirNextEdge)
		
		--[[
		local collisionEdge2 = copySegmentAndEntity(collisionEdge1, nextEdgeId())
		table.insert(edgesToAdd, collisionEdge2)
		
		local splitNode1 = newNodeWithPosition(s1.p, getNextNodeId()) 
		table.insert(nodesToAdd, splitNode1)
		if collisionEdge1.comp.node0 == collisionJoinNode then 
			collisionEdge1.comp.node0 = newCollisionJoinNode.entity
			collisionEdge1.comp.node1 = splitNode1.entity 
			collisionEdge2.comp.node0 = splitNode1.entity 
			
			s1.t3.z = exitHeight-s1.p.z  
			util.setTangent(collisionEdge1.comp.tangent0, s1.t0)
			util.setTangent(collisionEdge1.comp.tangent1, s1.t1)
			util.setTangent(collisionEdge2.comp.tangent0, s1.t2)
			util.setTangent(collisionEdge2.comp.tangent1, s1.t3)
		else 
			collisionEdge1.comp.node1 = newCollisionJoinNode.entity
			collisionEdge1.comp.node0 = splitNode1.entity 
			collisionEdge2.comp.node1 = splitNode1.entity 
			
			s1.t0.z = s1.p.z  - exitHeight
			util.setTangent(collisionEdge2.comp.tangent0, s1.t0)
			util.setTangent(collisionEdge2.comp.tangent1, s1.t1)
			util.setTangent(collisionEdge1.comp.tangent0, s1.t2)
			util.setTangent(collisionEdge1.comp.tangent1, s1.t3)
		end --]]
	
		if collisionEdge1.comp.type == 0 then 
			collisionEdge1.comp.type = 2 
			collisionEdge1.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
			--[[if trackOffset < 20 then 
				trace("Setting tunnel on the second edge")
				collisionEdge2.comp.type = 2 
				collisionEdge2.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
			end--]]
		end 
		
		
		--[[local otherEdge2 = copySegmentAndEntity(otherEdge1, nextEdgeId())
		table.insert(edgesToAdd, otherEdge2)
		local splitNode2 = newNodeWithPosition(s2.p, getNextNodeId()) 
		table.insert(nodesToAdd, splitNode2)
		if isNode0 then 
			otherEdge1.comp.node0 = newCollisionJoinNode.entity
			otherEdge1.comp.node1 = splitNode2.entity 
			otherEdge2.comp.node0 = splitNode2.entity 
			otherEdge2.comp.node1 = replacedOuterJoinNode.entity
			util.setTangent(otherEdge1.comp.tangent0, s2.t0)
			util.setTangent(otherEdge1.comp.tangent1, s2.t1)
			util.setTangent(otherEdge2.comp.tangent0, s2.t2)
			util.setTangent(otherEdge2.comp.tangent1, s2.t3)
		else 
			otherEdge1.comp.node1 = newCollisionJoinNode.entity
			otherEdge1.comp.node0 = splitNode2.entity 
			otherEdge2.comp.node1 = splitNode2.entity 
			otherEdge2.comp.node0 = replacedOuterJoinNode.entity
			util.setTangent(otherEdge2.comp.tangent0, s2.t0)
			util.setTangent(otherEdge2.comp.tangent1, s2.t1)
			util.setTangent(otherEdge1.comp.tangent0, s2.t2)
			util.setTangent(otherEdge1.comp.tangent1, s2.t3)
		end 
		trace("Created collisionEdge1",collisionEdge1.entity," collisionEdge2",collisionEdge2.entity," otherEdge1",otherEdge1.entity,"otherEdge2",otherEdge2.entity)
		trace("splitNode1.entity=",splitNode1.entity,"splitNode2.entity=",splitNode2.entity,"newCollisionJoinNode.entity=",newCollisionJoinNode.entity,"replacedCollisionJoinNode.entity=",replacedCollisionJoinNode.entity, "replacedOuterJoinNode.entity=replacedOuterJoinNode.entity",replacedOuterJoinNode.entity)
		--]]
		
		
		local newNextEdge = getOrMakeReplacedEdge(util.findNextEdgeInSameDirection(edgeAndId.id, node))
		local newNextEdge2 = getOrMakeReplacedEdge(util.findNextEdgeInSameDirection(edgeId2, node2))
		--[[
		local testData =  api.engine.util.proposal.makeProposalData(routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove), util.initContext())
			if testData.errorState.critical then
			debugPrint(testData.errorState)
			trace("Critical error seen in the test data for buildJunctionSpur prior to signal build1")
			if util.tracelog then 
				debugPrint(newProposal)
				local diagnose = true
				routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
			end
			return false
		end ]]--
		
		if not params.disableSignalBuild then 
			trace("buildJunctionSpur - building signals on edges",newEdgeToString(newNextEdge),newEdgeToString(newNextEdge2))
			routeBuilder.buildJunctionSignalsOnNewEdges(newNextEdge, node , newNextEdge2, node2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, true)
		end
		--[[local nextEdge = util.findNextEdgeInSameDirection(edgeAndId.id, joinNode)
		local nextEdge2 = util.findNextEdgeInSameDirection(edgeId2, joinNode2)
		local nextEdgeFull = util.getEdge(nextEdge) 
		local nextEdgeFull2 = util.getEdge(nextEdge2)
		local nextNode1 = nextEdgeFull.node0 == joinNode and nextEdgeFull.node1 or nextEdgeFull.node1 
		local nextNode2 = nextEdgeFull2.node0 == joinNode2 and nextEdgeFull2.node1 or nextEdgeFull2.node1 
		--routeBuilder.buildJunctionSignals(nextEdge, nextNode1, nextEdge2, nextNode2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, removedEdgeSet)]]--
		
		local theirNextEdge3 = util.findNextEdgeInSameDirection(theirNextEdge2, outerJoinNode2)
		local theirNextEdge2DoubleTrack = util.findDoubleTrackEdge(theirNextEdge2)
		local doubleTrackOuterJoinNode2 = util.findDoubleTrackNode(outerJoinNode2)
		local doubleTrackTheirNextEdge3 = util.findDoubleTrackEdge(theirNextEdge3)
		
		--[[
		if util.tracelog then debugPrint({build2="build2", edgesToAdd=edgesToAdd, nodesToAdd=nodesToAdd}) end
		local testData =  api.engine.util.proposal.makeProposalData(routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove), util.initContext())
			if testData.errorState.critical then
			debugPrint(testData.errorState)
			trace("Critical error seen in the test data for buildJunctionSpur prior to signal build2")
			if util.tracelog then 
				debugPrint(newProposal)
				local diagnose = true
				routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
			end
			return false
		end ]]--
		
		
		if doubleTrackOuterJoinNode2 and doubleTrackTheirNextEdge3 and not params.disableSignalBuild then 
			routeBuilder.buildJunctionSignals(theirNextEdge2, outerJoinNode2, theirNextEdge2DoubleTrack, doubleTrackOuterJoinNode2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, removedEdgeSet)
		else 
			util.trace("WARNING! Could not find the doubleTrackOuterJoinNode2?",doubleTrackOuterJoinNode2,"doubleTrackTheirNextEdge3?",doubleTrackTheirNextEdge3)
		end 
		
		if util.tracelog then debugPrint({edgesToAdd=edgesToAdd, nodesToAdd=nodesToAdd}) end
	else 
		local collisionNode = newNodeWithPosition(s.existingEdgeSolution.p1, getNextNodeId())
		--table.insert(edgesToRemove, theirCollisionEdge)
		table.insert(nodesToAdd, collisionNode)
		trace("buildJunctionSpur: created collisionNode with entity",collisionNode.entity," at ",collisionNode.comp.x, collisionNode.comp.y)
		
		local theirEdge1 = getOrMakeReplacedEdge(theirCollisionEdge, nextEdgeId())
		--table.insert(edgesToAdd, theirEdge1)
		if #theirEdge1.comp.objects > 0 then 
			trace("discovered some edge objects, attempting to remove...")
			for i , edgeObj in pairs(theirEdge1.comp.objects) do
				if not util.contains(edgeObjectsToRemove, edgeObj[1]) then 
					table.insert(edgeObjectsToRemove, edgeObj[1])
				end
			end
			theirEdge1.comp.objects = {}
			
			--table.insert(edgesToAdd, theirOtherEdge)
			--table.insert(edgesToRemove, otherEdgeId)
			--removedEdgeSet[otherEdgeId]=true
		end
		local theirEdge2 = copySegmentAndEntity(theirEdge1, nextEdgeId())
		table.insert(edgesToAdd, theirEdge2)
		
		 ourCollisionEdge2 = copySegmentAndEntity(ourCollisionEdge, nextEdgeId())
		table.insert(edgesToAdd, ourCollisionEdge2)
			
		theirEdge1.comp.node1 = collisionNode.entity
		setTangent(theirEdge1.comp.tangent0, s.existingEdgeSolution.t0)
		setTangent(theirEdge1.comp.tangent1, s.existingEdgeSolution.t1)			
		
		theirEdge2.comp.node0 = collisionNode.entity
		setTangent(theirEdge2.comp.tangent0, s.existingEdgeSolution.t2)
		setTangent(theirEdge2.comp.tangent1, s.existingEdgeSolution.t3)
		
		ourCollisionEdge.comp.node1 = collisionNode.entity
		setTangent(ourCollisionEdge.comp.tangent0, s.newEdgeSolution.t0)
		setTangent(ourCollisionEdge.comp.tangent1, s.newEdgeSolution.t1)	
			
		ourCollisionEdge2.comp.node0 = collisionNode.entity
		setTangent(ourCollisionEdge2.comp.tangent0, s.newEdgeSolution.t2)
		setTangent(ourCollisionEdge2.comp.tangent1, s.newEdgeSolution.t3)	
		trace(" ourCollisionEdge.node0=",ourCollisionEdge.comp.node0," ourCollisionEdge2.node1=",ourCollisionEdge2.comp.node1)
		
		-- put a node next to the collision node as this helps to anchor the track
		
		--if ourOtherEdge == entity then 
		--	trace("Inverting perpSign")
		--	perpSign = -perpSign
		--end
		local expectedOtherNodePos = util.solveForPositionHermiteFraction(s.newEdgeSolution.frac, ourOtherInputEdge).p
		
		local otherNodePos = util.doubleTrackNodePoint(s.existingEdgeSolution.p1, perpSign*s.newEdgeSolution.t1)
		local otherNodePos2 =  util.doubleTrackNodePoint(s.existingEdgeSolution.p1, -perpSign*s.newEdgeSolution.t1)
		if util.distance(otherNodePos, expectedOtherNodePos) > util.distance(otherNodePos2, expectedOtherNodePos) then 
			trace("Using inverted perp sign for anchoring point") 
			otherNodePos = otherNodePos2 
		end
		
		
		 otherEdge2 = copySegmentAndEntity(ourOtherEdge, nextEdgeId())
		local otherNode = newNodeWithPosition(otherNodePos, getNextNodeId())
		table.insert(nodesToAdd, otherNode)
		ourOtherEdge.comp.node1 = otherNode.entity
		setTangent(ourOtherEdge.comp.tangent0, s.newEdgeSolution.t0)
		setTangent(ourOtherEdge.comp.tangent1, s.newEdgeSolution.t1)	
		
		otherEdge2.comp.node0 = otherNode.entity
		trace("The otherNodePos was ",otherNodePos.x,otherNodePos.y," ourOtherEdge.node0=",ourOtherEdge.comp.node0," otherEdge2.node1=",otherEdge2.comp.node1)
		setTangent(otherEdge2.comp.tangent0, s.newEdgeSolution.t2)
		setTangent(otherEdge2.comp.tangent1, s.newEdgeSolution.t3)	
		table.insert(edgesToAdd, otherEdge2)
		trace("the angle between collisionEdges was ",math.deg(util.signedAngle(s.newEdgeSolution.t2, s.existingEdgeSolution.t2)))
		if not params.disableSignalBuild then 	
			trace("buildJunctionSpur: calling to buildJunctionSignals")
			routeBuilder.buildJunctionSignals(edgeAndId.id, joinNode, edgeId2, joinNode2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, removedEdgeSet)
			routeBuilder.buildJunctionSignals(edgeAndId.id, node, edgeId2, node2, edgesToAdd, edgesToRemove, edgeObjectsToAdd, nextEdgeId, removedEdgeSet)
		end
		trace("buildJunctionSpur: theirEdge1=",newEdgeToString(theirEdge1),"theirEdge2=",newEdgeToString(theirEdge2), " ourCollisionEdge=",newEdgeToString(ourCollisionEdge), "ourCollisionEdge2=", newEdgeToString(ourCollisionEdge2))
		trace("buildJunctionSpur: ourOtherEdge=",newEdgeToString(ourOtherEdge),"otherEdge2=",newEdgeToString(otherEdge2))
	end -- end if buildGradeSeparatedTrackJunctions
	-- end buildGradeSeparatedTrackJunctions
	trace("End of junction spur build, begin signal build. ourCollisionEdge2.comp.node1=",ourCollisionEdge2.comp.node1, "ourCollisionEdge2.entity=",ourCollisionEdge2.entity)
	
	local newProposal 
	if not xpcall(function() newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) end, err) then 
		trace("ERROR setting up proposal, aborting in buildJunctionSpur")
		if util.tracelog then 
			debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
		end
		return false
	end 
--	debugPrint(newProposal)
	
	local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if testData.errorState.critical then
		debugPrint(testData.errorState)
		trace("Critical error seen in the test data for buildJunctionSpur prior to signal build3")
		if util.tracelog then 
			debugPrint({buildJunctionSpurProposal = newProposal})
		end 	
		--[[if util.tracelog then 
			debugPrint(newProposal)
			local diagnose = true
			routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
		end]]--
		return false
	end 
		
	if params.edgeIdx and not params.disableSignalBuild then 
--		local targetSignalInterval = params.targetSignalInterval
		local newTargetSigInteval = params.sharedTrackTargetSignalInterval
		local negative = params.edgeIdx < junctionIdx
		local function getNextSignalIndex(i) 
			if negative then 
				for j = #routeInfo.signalIndexes, 1, -1 do 
					local idx = routeInfo.signalIndexes[j]
					if idx < i then 
						return idx 
					end
				end 
			else 
				for j, idx in pairs(routeInfo.signalIndexes) do 
					if idx > i then 
						return idx
					end 
				end 
			end 
		end 
		local newSignalsToBuild = {}
		if negative then 
			local i = junctionIdx
			while i > routeInfo.firstFreeEdge  do 
				local nextSignalIdx =  getNextSignalIndex(i) 
				trace("At i = ",i," nextSignalIdx=",nextSignalIdx, " negative=true")
				if nextSignalIdx and  i-nextSignalIdx> newTargetSigInteval then
					local newSignalIdx = math.floor((nextSignalIdx+i)/2)
					trace("At i = ",i," setting newSignalIdx to ",newSignalIdx)
					table.insert(newSignalsToBuild, newSignalIdx)
					i = nextSignalIdx
				else 
					i = i -1 
				end
			end 
		else 
			local lastSignalIndex = junctionIdx
			local i = junctionIdx
			while i < routeInfo.lastFreeEdge do 
				local nextSignalIdx =  getNextSignalIndex(i)
				trace("At i = ",i," nextSignalIdx=",nextSignalIdx, " negative=false")				
				if nextSignalIdx and nextSignalIdx-i > newTargetSigInteval then
					local newSignalIdx = math.floor((nextSignalIdx+i)/2)
					trace("At i = ",i," setting newSignalIdx to ",newSignalIdx)
					table.insert(newSignalsToBuild, newSignalIdx)
					i = nextSignalIdx
				else 
					i = i + 1
				end
			end 
		end 
		trace("discovered ",#newSignalsToBuild,"newSignalsToBuild")
		local alreadySeen = {}
		local signalsBuilt = {}
		for __, i in pairs(newSignalsToBuild) do 
			if i == junctionIdx or i == junctionIdx-1 or i == junctionIdx+1 or alreadySeen[i] or signalsBuilt[i+1] or signalsBuilt[i-1] then 
				goto continue 
			end 
			alreadySeen[i]=true
			local edgeId = routeInfo.edges[i].id
			if alreadySeen[edgeId] then 
				goto continue
			end
			if not api.engine.entityExists(edgeId) or not util.getEdge(edgeId) then break end 
			if util.getEdgeLength(edgeId) < 20 or removedEdgeSet[edgeId] then 
				if not alreadySeen[i-1] and routeInfo.edges[i-1] and false then 
					edgeId = routeInfo.edges[i-1].id
					trace("Moving to prior edgeid")
					if util.getEdgeLength(edgeId) < 20 or removedEdgeSet[edgeId] then 
						trace("Short segment detected, skipping")
						goto continue 
					end
				else 
					trace("Short segment detected, skipping")
					goto continue 
				end
			end 
			local doubleTrackEdge = util.findDoubleTrackEdge(edgeId)
			if not doubleTrackEdge or util.isJunctionEdge(edgeId) or removedEdgeSet[doubleTrackEdge] then 
				trace("Unable to build signals at ",i, " for edge", edgeId," because ",(doubleTrackEdge and "was a junction edge" or "could not find double track edge"))
				goto continue 
			end 
			local edge = util.getEdge(edgeId)
			if #edge.objects > 0 then goto continue end
			for __, node in pairs({edge.node0, edge.node1}) do 
				local segs = util.getTrackSegmentsForNode(node)
				if #segs ~= 2 then 
					trace("Segments for node",node," not 2",#segs," skipping")
					goto continue 
				end
				for __, seg in pairs(segs) do 
					local hasSignals = #util.getEdge(seg).objects > 0 
					
					alreadySeen[seg]=true
					local seg2 = util.findDoubleTrackEdge(seg)
					trace("Checking segment ",seg," hasSignals?",hasSignals, " seg2?",seg2)
					if seg2 then 
						alreadySeen[seg2]=true 
					end
					if hasSignals then
						trace("Skipping placing signals on adjacent edge")
						goto continue 
					end 
				end 
			end 
			if #util.getEdge(doubleTrackEdge).objects > 0 then goto continue end
			local entity = getOrMakeReplacedEdge(edgeId, nextEdgeId()) 
			--table.insert(edgesToAdd, entity)
			--table.insert(edgesToRemove, edgeId)
			
			
			local entity2 = getOrMakeReplacedEdge(doubleTrackEdge, nextEdgeId())
			--table.insert(edgesToAdd, entity2)
			--table.insert(edgesToRemove, doubleTrackEdge)
			
			if #entity.comp.objects>0 or #entity2.comp.objects>0 then 
				trace("Skipping signal build at ",i," as objects were discovered on the edge")
				goto continue 
			end
			
			local function isLeft(entity, otherEntity) 
				local nodePos0 = util.nodePos(entity.comp.node0)
				local otherNodePos0 = util.nodePos(otherEntity.comp.node0)
				local otherNodePos1 = util.nodePos(otherEntity.comp.node1)
				local otherNodePos = util.distance(otherNodePos0, nodePos0) < util.distance(otherNodePos1, nodePos0) and otherNodePos0 or otherNodePos1
				return util.signedAngle(nodePos0-otherNodePos, util.v3(entity.comp.tangent0)) < 0
			end
			trace("Attempting to build signals at index ",i)
			if util.findDoubleTrackNode(entity.comp.node0) and util.findDoubleTrackNode(entity2.comp.node0) then 
				trace("Building signals, routeBuilder.signalCount=",routeBuilder.signalCount)
				buildSignal(edgeObjectsToAdd, entity,  isLeft(entity, entity2))
			
				buildSignal(edgeObjectsToAdd, entity2,  isLeft(entity2, entity))
				signalsBuilt[i]=true
			end
			::continue::
		end 
		
	end
	trace("ourCollisionEdge2.comp.node1=",ourCollisionEdge2.comp.node1,"newNodePosMap[ourCollisionEdge2.comp.node1]=",newNodePosMap[ourCollisionEdge2.comp.node1], " ourCollisionEdge2.entity",ourCollisionEdge2.entity)
	return { 
		edge1=ourCollisionEdge2, 
		edge2=otherEdge2,
		--newNode1Pos=newNodePos,
		--newNode2Pos=newNode2Pos
		newNode1Pos = newNodePosMap[ourCollisionEdge2.comp.node1],
		newNode2Pos = newNodePosMap[otherEdge2.comp.node1],
	}
end 
function routeBuilder.buildConnectingRouteSpurFromNode(node, station, otherStation, routeInfo, callback, params, routeInfoFn, isIntermediateRoute,otherNode) 
	local connectedEdges = util.getTrackSegmentsForNode(node)
	if #connectedEdges==3 or #connectedEdges==1 then 
		trace("Route spur already built")
		return false
	end
	trace("Building connecting spur from node",node,"otherNode=",otherNode)
	if not isIntermediateRoute then 
	
		params.isIntermediateRoute = false
		params.buildCrossover =true
		params.disableSignalBuild = false
	else 
		trace("Intermediate route detected")
		params.buildCrossover = false
		--params.disableSignalBuild = true
		params.isIntermediateRoute = true		
	end 
	local otherStationPos =  util.getStationPosition(otherStation)
	local function indexOfNode(node)
		for i = 1, #routeInfo.edges do
			local node0 = routeInfo.edges[i].edge.node0 
			local node1 = routeInfo.edges[i].edge.node1
		
			if node0 == node or  node1 == node 	then
				local isLikelyUseNode0 =  util.distance(util.nodePos(node1), otherStationPos) > util.distance(util.nodePos(node0), otherStationPos)
				if isLikelyUseNode0 then 
					if node0 == node then 
						return i 
					end
				else 
					if node1 == node then 
						return i
					end 
				end
			end
		end
	end
	local junctionIdx = indexOfNode(node)
	if not junctionIdx then 
		trace("WARNING! Could not find node",node," in routeInfo, attempting to find doubletracknode")
		local originalNode = node
		node = util.findDoubleTrackNode(node)
		junctionIdx = indexOfNode(node)		 
		trace("Second attempt using! ",node," junctionIdx",junctionIdx)
		if not junctionIdx then 
			node = originalNode
			junctionIdx = routeInfo.getIndexOfClosestApproach(util.nodePos(node))
				trace("WARNING!  stil not found, using closes approach got ",junctionIdx)
		end
	end
	local firstFreeEdge = routeInfo.edges[routeInfo.firstFreeEdge].edge
	local backwards = firstFreeEdge.node0 == routeInfo.edges[routeInfo.firstFreeEdge+1].edge.node1 
	local edgeCloseToOtherStation = routeInfo.edges[routeInfo.lastFreeEdge]
	local edgeIdx = routeInfo.lastFreeEdge
	local wasLastEdge = true 
	
	local dist1 = util.distance(util.getEdgeMidPoint(edgeCloseToOtherStation.id),otherStationPos)
	local dist2 = util.distance(util.getEdgeMidPoint(routeInfo.edges[routeInfo.firstFreeEdge].id), otherStationPos)
	if  dist1> dist2 then 
		edgeCloseToOtherStation = routeInfo.edges[routeInfo.firstFreeEdge]
		edgeIdx = routeInfo.firstFreeEdge
		wasLastEdge = false 
	end
	if dist1 > 500 and dist2 > 500 then 
		trace("WARNING! Unexpected high distance, attempting to fix")
		edgeIdx = routeInfo.getIndexOfClosestApproach(otherStationPos)
	end 
		
	trace("Using edgeIdx=",edgeIdx, " wasLastEdge=",wasLastEdge," lastFreeEdgeId was ",routeInfo.edges[routeInfo.lastFreeEdge].id, " firstFreeEdgeId was ",routeInfo.edges[routeInfo.firstFreeEdge].id )
	params.edgeIdx = edgeIdx 
	if params.buildCrossover then 
		
		local expectedStationEdge = edgeCloseToOtherStation.id 
		local foundPath = #pathFindingUtil.findRailPathBetweenEdgeAndStation(expectedStationEdge, otherStation)>0 
		local routeInfoForCrossover = routeInfo
		if not foundPath then 
			local doubleTrackEdge = util.findDoubleTrackEdge(expectedStationEdge) 
			trace("Initial attempt to find path  between ",node," and station",otherStation," was false, attempting again with", doubleTrackEdge)
			if doubleTrackEdge then 
				foundPath = #pathFindingUtil.findRailPathBetweenEdgeAndStation(doubleTrackEdge, otherStation)>0 
			end
		end
		if not foundPath then 
			local junctionEdgeId = routeInfo.edges[junctionIdx].id
			local answer = pathFindingUtil.findRailPathBetweenEdgeAndStation(junctionEdgeId, otherStation)
			if #answer == 0 then 
				local doubleTrackEdge = util.findDoubleTrackEdge(junctionEdgeId) 
				trace("Initial attempt to find path  junctionEdgeId ",junctionEdgeId," and station",otherStation," was false, attempting again with", doubleTrackEdge)
				if doubleTrackEdge then 
					answer = pathFindingUtil.findRailPathBetweenEdgeAndStation(doubleTrackEdge, otherStation)
				end 
			end
			if #answer > 0 then 
				trace("A path WAS found but requires new routeinfo for crossover") 
				foundPath = true 
				routeInfoForCrossover = pathFindingUtil.getRouteInfoFromEdges(answer)
				edgeIdx = routeInfoForCrossover.lastFreeEdge
			else 
				trace("Answer was still zero")
			end 
		end 
	
		if wasLastEdge then 
			params.nextEdgeIdx = edgeIdx - 2
		else 
			params.nextEdgeIdx = edgeIdx+ 2
		end
		params.edgeIdx = edgeIdx 
		if foundPath then 
			trace("A path WAS found between ",node," using edge ",expectedStationEdge," and station",otherStation," building crossover")
			buildCrossoverRepeat(routeInfoForCrossover, otherStation, params, edgeIdx, function(res, success) 
				util.clearCacheNode2SegMaps()
				routeBuilder.addWork(function()
					util.cacheNode2SegMaps()
					local updatedRouteInfo  = routeInfoFn() 
					if not updatedRouteInfo then 
						trace("WARNING!, no route info returned from original function, attempting to fall back")
						updatedRouteInfo = routeInfo
					end
					routeInfo= updatedRouteInfo
					if not junctionIdx then 
						junctionIdx = indexOfNode(node) 
						if not juncitonIdx then 
							local doubleTrackNode = util.findDoubleTrackNode(node)
							juncitonIdx = indexOfNode(doubleTrackNode) 
							if not junctionIdx then 
								routeInfo = pathFindingUtil.getRouteInfoFromTrackNode(node)
								routeInfo.routeInfoFromNode = true
								junctionIdx = indexOfNode(node)
								updatedRouteInfo = routeInfo
								trace("WARNING! Having to recompute from node")
							end 
						end
					end 
					if not routeBuilder.buildSpurConnectRepeat(node, station, otherStation, updatedRouteInfo, callback, params, junctionIdx, otherNode)  then
						callback({}, false)
					end 
				end) 
			end)
			params.buildCrossover=false
			return true
		else 
			trace("No path was found between ",node," using edge ",expectedStationEdge," and station",otherStation," skipping crossover")
			 
		end
		
		
	end
	trace("Calling command to built spurConnect directly")
	return routeBuilder.buildSpurConnectRepeat(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
end 
function routeBuilder.buildSpurConnectRepeat(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
	trace("Begin buildSpurConnectRepeat",node, station, otherStation,"otherNode=",otherNode)
	params.tryNextIndex = false 
	local success = routeBuilder.buildSpurConnect(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
	if not success then 
		
		while not success and params.junctionTrackOffset < 30 do
			params.junctionTrackOffset = params.junctionTrackOffset + 1
			trace("Attempt to build route spur failed, attempting next index ",params.junctionTrackOffset)
			xpcall(function() 
				success = routeBuilder.buildSpurConnect(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
			end, err)
		end 
		if not success then 
			local tryIndexes = true 
			if otherNode and util.distBetweenNodes(otherNode, node) < 300 then 
				tryIndexes = false 
				trace("Suppressing try other indexes for short distance")
			end 
			if tryIndexes then 
				for tryNextIndex = -3, 3 do 
					params.tryNextIndex = tryNextIndex
					trace("Attempt to build route spur failed, attempting next index ",tryNextIndex)
					xpcall(function() 
						success = routeBuilder.buildSpurConnect(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
					end, err)
					if success then 
						break 
					end
				end  
			end
		end
		params.tryNextIndex = false 
		if not success then  

			if not params.ignoreErrors then 
				trace("Third attempt to build route spur failed, attempting with ignoreErrors")
				params.ignoreErrors = true
				return routeBuilder.buildSpurConnectRepeat(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
			end
			if params.buildGradeSeparatedTrackJunctions then 
				trace("Fourth attempt to build route spur failed, attempting with disabled grade seperation")
				params.buildGradeSeparatedTrackJunctions = false
				return routeBuilder.buildSpurConnectRepeat(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
			end
			if not params.disableSignalBuild then 
				params.disableSignalBuild = true
				trace("Second attempt to build route spur failed, attempting without signals index")
				return routeBuilder.buildSpurConnectRepeat(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode) 
			end
		end
	end
	if not success then 
		callback({}, false) 
	end
	return success
end
function routeBuilder.getIndexOfClosestApproach(routeInfo, p)
	local options = {} 
	for i =1, #routeInfo.edges do 
		table.insert(options, 
			{
				idx =i ,
				scores = { util.distance(p, util.getEdgeMidPoint(routeInfo.edges[i].id))}
			})
	end 
	return util.evaluateWinnerFromScores(options).idx
end 

function routeBuilder.buildSpurConnect(node, station, otherStation, routeInfo, callback, params, junctionIdx, otherNode, forbidRecurse) 
	util.cacheNode2SegMapsIfNecessary()
	local targetNode = node
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgeObjectsToRemove = {}
	local edgesToRemove = {} 
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local nextNodeId = -10000
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	
	
	local edgeIdx = params.edgeIdx
	trace("Attempting to build spur, junctionIdx =",junctionIdx,"edgeIdx=",edgeIdx)
	if not edgeIdx then 
		trace("WARNING! No edgeIdx specified, attempting to compensate")
		edgeIdx = 0
	end 
	if params.tryNextIndex then 
		if junctionIdx > edgeIdx then 
			junctionIdx = junctionIdx -params.tryNextIndex
		else 
			junctionIdx = junctionIdx + params.tryNextIndex
		end 
	end
	if not routeInfo.edges[junctionIdx] then 
		return false 
	end

	local testEdge 
	if not pcall(function() testEdge = util.findDoubleTrackEdge(routeInfo.edges[junctionIdx].id) end) then 
		trace("WARNING! No double track edge found at", routeInfo.edges[junctionIdx].id, " aborting")
		return false
	end 
	local attemptCount = 0 
	local goingDown = junctionIdx > edgeIdx
	while not testEdge  and attemptCount < 10 do 
		trace("A double track edge could not be found for this edge, trying another at ",junctionIdx, " attempt ",attemptCount)
		if goingDown then 
			junctionIdx = junctionIdx -1
		else 
			junctionIdx = junctionIdx + 1
		end 
		if not pcall(function() testEdge = util.findDoubleTrackEdge(routeInfo.edges[junctionIdx].id) end) then 
			trace("WARNING! No double track edge found at", routeInfo.edges[junctionIdx] , " aborting junctionIdx=",junctionIdx)
			return false
		end 
	end
	if util.calculateSegmentLengthFromEdge(routeInfo.edges[junctionIdx].edge)<70 then 
		return false 
	end	
	
	
	
	local useNode0

	--buildCrossoverExistingEdges(nodesToAdd, edgesToAdd, edgeObjectsToAdd,  routeInfo,  getNextNodeId, nextEdgeId, otherStation,edgesToRemove , edgeIdx) 
	local otherStationPos = type(otherStation) == "table" and otherStation or util.getStationPosition(otherStation)
	local stationPos = type(station)=="table" and station or util.getStationPosition(station)
	local node0 = routeInfo.edges[junctionIdx].edge.node0 
	local node1 = routeInfo.edges[junctionIdx].edge.node1 
	 
	local dist1 = util.distance(util.nodePos(node1), otherStationPos)
	local dist2 = util.distance(util.nodePos(node0), otherStationPos)  
	useNode0 = dist1 > dist2
	trace("UseNode0 was ",useNode0," isIntermediateRoute?",params.isIntermediateRoute," routeInfoFromNode?",routeInfo.routeInfoFromNode, "dist1=",dist1,"dist2=",dist2)
	--if math.abs(dist1-dist2) < 40 then 
		--trace("WARNING Low difference in distance may give ambiguous result")
 
	local alternativeNode0 =  util.distance(util.nodePos(node1), otherStationPos) > util.distance(util.nodePos(node0), otherStationPos)  
	local isHigh = junctionIdx > edgeIdx
	local nextIdx = isHigh and junctionIdx - 1 or junctionIdx + 1
	if routeInfo.edges[nextIdx] then
		local nextNode0 = routeInfo.edges[nextIdx].edge.node0 
		local nextNode1 = routeInfo.edges[nextIdx].edge.node1 
	--local 
		useNode0 = nextNode1 == node0
	else 
		useNode0 =alternativeNode0
	end
	-- can't just rely on the distance test as a winding route may fool the logic
	
	trace("UseNode0 was ",useNode0," alternativeNode0 was ",alternativeNode0, "junctionIdx=",junctionIdx,"nextIdx=",nextIdx,"isHigh=",isHigh)
	if alternativeNode0 ~= useNode0 or  params.isIntermediateRoute or routeInfo.routeInfoFromNode then 
		trace("WARNING! alternativeNode0 and useNode0 are in disagreement, attempting to resolve")
		local edgeId = routeInfo.edges[junctionIdx].id
		local edgeForNode0Test = edgeId
		local newRouteInfo
		if type(otherStation)=="table" or  params.isIntermediateRoute or routeInfo.routeInfoFromNode then 
			local edge1 = util.getTrackSegmentsForNode(util.getNodeClosestToPosition(otherStationPos))[1]
			if not edge1 then 
				edge1 =	util.getTrackSegmentsForNode(routeInfo.closestFreeNode(otherStationPos))[1]
			end 
			local edge2 = edgeId
			trace("Found edge1",edge1, " from position",otherStationPos.x,otherStationPos.y, "edge1, edge2 were",edge1,edge2)
			newRouteInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge1, edge2 )) or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge2, edge1 ))
			if not newRouteInfo then 
				trace("No route info found between",edge1,edge2)
				edge1 =	util.getTrackSegmentsForNode(routeInfo.closestFreeNode(otherStationPos))[1]
				newRouteInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge1, edge2 )) or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge2, edge1 ))
				trace("Tried to find from edge1",edge1, " found?" , newRouteInfo)
			end 
		else 
			newRouteInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgeAndStation(edgeId, otherStation))
			if not newRouteInfo then 
				local otherEdge = util.findDoubleTrackEdge(edgeId)
				newRouteInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgeAndStation(otherEdge, otherStation))
				trace("newRouteInfo not found, attempting from other edge", otherEdge, " foundRouteInfo?", newRouteInfo) 
				edgeForNode0Test = otherEdge
			end 
		end
		if newRouteInfo then 
			local edgeIdx = newRouteInfo.getIndexOfClosestApproach(otherStationPos)
			local junctionIdx = newRouteInfo.indexOf(edgeForNode0Test)
			if not junctionIdx then 	
				trace("No junctionIdx initially found from routinfo, attempting again")
				if util.findDoubleTrackEdge(edgeForNode0Test) then 
					junctionIdx = newRouteInfo.indexOf(util.findDoubleTrackEdge(edgeForNode0Test))
					trace("Attempting to find from double track edge, was found?",junctionIdx )
				end 
				if not junctionIdx then
					trace("WARNING! No junctionIdx found for ",edgeForNode0Test," edgeId = ",edgeIdx)
					return false
				end
			end 
			local isHigh = junctionIdx > edgeIdx
			local nextIdx = isHigh and junctionIdx - 1 or junctionIdx + 1
			local node0 = newRouteInfo.edges[junctionIdx].edge.node0 
			local node1 = newRouteInfo.edges[junctionIdx].edge.node1 
			if newRouteInfo.edges[nextIdx] then 
				local nextNode0 = newRouteInfo.edges[nextIdx].edge.node0 
				local nextNode1 = newRouteInfo.edges[nextIdx].edge.node1 
				useNode0 = nextNode1 == node0
				trace("Recalcualted useNode0 was ",useNode0, " edgeIdx=",edgeIdx,"junctionIdx=",junctionIdx,"isHigh=",isHigh)
			else 
				trace("WARNING! No routeInfo.edges[nextIdx]")
			end 
		else 
			trace("WARNING! No newRouteInfo was found, useNode0 is ambiguous")
			
			--useNode0 = alternativeNode0
			-- attempt to "walk" down the track to see where we end, this is not 100% robust but works most of the time
			
			local node0 = routeInfo.edges[junctionIdx].edge.node0 
			local node1 = routeInfo.edges[junctionIdx].edge.node1 
			local edgeId = routeInfo.edges[junctionIdx].id 
			local edgePos = util.getEdgeMidPoint(edgeId)
			-- outbound from node1
			local nextNode = node1
			local nextSegs = util.getTrackSegmentsForNode(nextNode)
			local foundNode0Station = false
			local foundNode1Station = false
			local outerDistance2 = math.huge
			repeat 
				edgeId = edgeId == nextSegs[1] and nextSegs[2] or nextSegs[1] 
				local edge = util.getEdge(edgeId)
				nextNode = nextNode == edge.node0 and edge.node1 or edge.node0
				outerDistance2 = math.min(util.distance(util.nodePos(nextNode) , otherStationPos),outerDistance2)
				nextSegs = util.getTrackSegmentsForNode(nextNode)
				if #nextSegs == 3 and util.distance(util.nodePos(nextNode), edgePos) < 1000 then 
					trace("Looking for a frozen edge at node ",nextNode)
					for __, seg in pairs(nextSegs) do 
						local constructionId = util.isFrozenEdge(seg)
						trace("isFrozenEdge for seg",seg, " = ",constructionId)
						if constructionId then 
							foundNode1Station = util.getConstruction(constructionId).stations[1]
						end 
					end 
				end 
			until #nextSegs ~= 2 or util.isFrozenEdge(edgeId)
			local node1ConnectPos = util.nodePos(nextNode) 
			trace("The outer node from following node1 was ",nextNode)
			
			-- outbound from node0
			local nextNode = node0
			local nextSegs = util.getTrackSegmentsForNode(nextNode)
			local edgeId = routeInfo.edges[junctionIdx].id 
			local outerDistance1 = math.huge
			repeat 
				edgeId = edgeId == nextSegs[1] and nextSegs[2] or nextSegs[1] 
				local edge = util.getEdge(edgeId)
				nextNode = nextNode == edge.node0 and edge.node1 or edge.node0
				outerDistance1 = math.min(util.distance(util.nodePos(nextNode) , otherStationPos),outerDistance1)
				nextSegs = util.getTrackSegmentsForNode(nextNode)
				if #nextSegs == 3 and util.distance(util.nodePos(nextNode), edgePos) < 1000  then 
					trace("Looking for a frozen edge at node ",nextNode)
					for __, seg in pairs(nextSegs) do 
						local constructionId = util.isFrozenEdge(seg)
						trace("isFrozenEdge for seg",seg, " = ",constructionId)
						if constructionId then 
							foundNode0Station = util.getConstruction(constructionId).stations[1]
						end 
					end 
				end 
			until #nextSegs ~= 2 or util.isFrozenEdge(edgeId)
			local node0ConnectPos = util.nodePos(nextNode) 
			trace("The outer node from following node0 was ",nextNode)
			
			--local outerDistance1 = util.distance(node0ConnectPos, otherStationPos)
			--local outerDistance2 = util.distance(node1ConnectPos, otherStationPos)
			local outerDistance3 = util.distance(node0ConnectPos, stationPos)
			local outerDistance4 = util.distance(node1ConnectPos, stationPos)
			
			useNode0 = outerDistance2 > outerDistance1
			trace("The outerDistance1 was ",outerDistance1," the outerDistance2 was ",outerDistance2, " set useNode0 to",useNode0,"foundNode0Station?",foundNode0Station,"foundNode1Station?",foundNode1Station, " otherStationPos=",otherStationPos.x,otherStationPos.y, " outerDistance3=",outerDistance3, " outerDistance4=",outerDistance4)
			if useNode0 and foundNode0Station then 
				trace("WARNING! disagreement between useNode0 and foundNode0Station, stting to false")
				useNode0 = false 
			end 
			if not useNode0 and foundNode1Station then 
				trace("WARNING! disagreement between useNode1 and foundNode1Station, stting to true")
				useNode0 = true 
			end 
		end 
		   
		
		
	--[[	local endAt = isHigh and 1 or #routeInfo.edges
		local increment = isHigh and -1 or 1
		 
		local priorEdge = routeInfo.edges[edgeIdx].edge
		local count = 0 
		for i = nextIdx, endAt, increment do 
			count = count + 1
			local edge = routeInfo.edges[i].edge 
			local nodeChange = priorEdge.node0 == edge.node0 or priorEdge.node1 == edge.node1
			routeInfo.changeIndexes[i] = nodeChange
			if nodeChange then 
				trace("Found node change at i=",i," nextEdgeId=",nextEdgeId,"endAt=",endAt,"increment=",increment)
				useNode0 = not useNode0
			else 
				local alternativeNode0 = util.distance(stationPos, util.nodePos(edge.node1)) > util.distance(stationPos, util.nodePos(edge.node0))
				if alternativeNode0~=useNode0 then 
					trace("WARNING! alternativeNode0",alternativeNode0,"useNode0=",useNode0)
					if count < 4 then 
						trace("Swapping")
						useNode0 = alternativeNode0
					end 
				end
			end 
			routeInfo.useNode0[i]=useNode0
			priorEdge = edge
		end ]]--
		
		trace("UseNode0 was ",useNode0, " the junctionIdx was ",junctionIdx," the edgeIdx was ",edgeIdx, " nextNode1=",nextNode1, " node0=",node0)
	end
	
	local joinNode
	local node 
	if useNode0 then 
		joinNode = node0
		node = node1 
	else 
		joinNode = node1
		node = node0
	end
	if targetNode ~= joinNode and util.findDoubleTrackNode(targetNode)~=joinNode then 
		trace("Target node not join node, attempting to correct")
		if targetNode ~= node then 
			targetNode = util.findDoubleTrackNode(targetNode)
		end 
		if targetNode == node then 
			trace("Found the target node in the other node")
		end 
		local newJunctionIdx
		trace("Attempting to find a new junctionIdx from targetNode",targetNode)
		for i, seg in pairs(util.getTrackSegmentsForNode(targetNode)) do 
			if routeInfo.edges[junctionIdx+1] and routeInfo.edges[junctionIdx+1].id==seg then 
				trace("Found edge at nextIndex")
				newJunctionIdx = junctionIdx+1
				break
			end 
			if routeInfo.edges[junctionIdx-1] and routeInfo.edges[junctionIdx-1].id==seg then 
				trace("Found edge at priorIndex")
				newJunctionIdx = junctionIdx-1 
				break
			end 
		end 
		trace("Discovered the newJunctionIdx as ",newJunctionIdx)
		if not newJunctionIdx then 
			trace("WARNING! No newJunctionIdx found")
		end 
		
		if not forbidRecurse and newJunctionIdx  then 
			forbidRecurse = true 
			return routeBuilder.buildSpurConnect(targetNode, station, otherStation, routeInfo, callback, params, newJunctionIdx, otherNode, forbidRecurse) 
		else 
			trace("WARNING! Unexpected condition, in recursive call but still not corrected target node")
		end 
	end 
	trace("Using the joinNode",joinNode,"as the targetNode?",targetNode,"was",targetNode==joinNode,"otherNode=",node)
	-- using the closest edge to their station because we want to exit the mainline and avoid a collision with that route 
	local closestIdx = routeInfo.getIndexOfClosestApproach(stationPos)--routeBuilder.getIndexOfClosestApproach(routeInfo, stationPos)
	local closestEdge = routeInfo.edges[closestIdx].edge
	trace("Choosing between nodes ",node0, node1," joinNode set",joinNode)
	local trialPos = util.doubleTrackNodePoint(util.nodePos(closestEdge.node0), util.v3(closestEdge.tangent0))
	local trialPos2 = util.doubleTrackNodePoint(util.nodePos(closestEdge.node0), -1*util.v3(closestEdge.tangent0))
	local dist1 =  util.distance(stationPos, trialPos)
	local dist2 = util.distance(stationPos, trialPos2)
	
	if math.abs(dist1-dist2) < 2  --> shallow angle, could go either side, more accurate to look at the junction edge instead
		--or util.distance(util.getEdgeMidPoint(routeInfo.edges[closestIdx].id)) > util.distance(util.getEdgeMidPoint(routeInfo.edges[closestIdx].id))
		then
		trace("Dist1 and dist2 were close",dist1,dist2," using the join edge instead")
		local joinEdge = routeInfo.edges[junctionIdx].edge
		trialPos = util.doubleTrackNodePoint(util.nodePos(joinEdge.node0), util.v3(joinEdge.tangent0))
		trialPos2 = util.doubleTrackNodePoint(util.nodePos(joinEdge.node0), -1*util.v3(joinEdge.tangent0))
		dist1 =  util.distance(stationPos, trialPos)
		dist2 = util.distance(stationPos, trialPos2)
	end 
	
	local perpSign = dist1 > dist2 and -1 or 1 -- move towards the station 
	local reversals = routeInfo.countReversalsBetweenIndexes(closestIdx, junctionIdx)
	local shouldInvertPerpsign = reversals%2==1
	local nodePos =util.nodePos(node)
	local routeVector = stationPos - nodePos
	local industry
	if math.min(dist1,dist2)> 500 then 
		local searchPos = util.nodePos(node)+250*vec3.normalize(routeVector)
		industry = util.searchForFirstEntity(searchPos, 250, "SIM_BUILDING")
		trace("Looking for industry around",searchPos.x,searchPos.y,"Found?",industry)
	end 
	
	if industry then 
		
		local industryPos = util.v3fromArr(industry.position)
		
		trace("buildSpurConnect: found industry nearby at",nodePos.x,nodePos.y)
		local distToIndustry = util.distance(nodePos,industryPos)
		if distToIndustry < math.min(dist1,dist2) then 
			trace("Found nearby industry close")
			local vectorToIndustry1 = industryPos - trialPos 
			local vectorToIndustry2 = industryPos - trialPos2
			local vectorToIndustry = industryPos - nodePos
--			local routeVector = otherStationPos - nodePos
			
			local angleToRouteVector = util.signedAngle(routeVector, vectorToIndustry)
			
			local angle1 = util.signedAngle(vectorToIndustry1, vectorToIndustry)
			local angle2 = util.signedAngle(vectorToIndustry2, vectorToIndustry)
			trace("Near to an industry, angle1 was ",math.deg(angle1), "angle2 was ",math.deg(angle2), " perpSign originally",perpSign,"routeVector Angle=",math.deg(angleToRouteVector))
			if math.abs(angleToRouteVector) < math.rad(90) then 
				--perpSign = math.abs(angle1) < math.abs(angle2) and 1 or -1 
				local pMin1 = util.getClosestPoint2dLine(trialPos, stationPos, industryPos)
				local pMin2 = util.getClosestPoint2dLine(trialPos2, stationPos, industryPos)
				local distToIndustry1 = vec2.distance(industryPos, pMin1)
				local distToIndustry2 = vec2.distance(industryPos, pMin2)
				trace("After inspecting the collision points distToIndustry1=",distToIndustry1,"distToIndustry2=",distToIndustry2, "compared to original distToIndustry",distToIndustry)
				if math.min(distToIndustry1, distToIndustry2) < distToIndustry then --i.e. we get closer to it
					perpSign = distToIndustry1 < distToIndustry2 and -1 or 1 -- N.B. inverted condition compared to original, i.e. we want to get away from the industry	
				end 
			
				trace("After correcting to pass industry perpSign is now ",perpSign,"at ",nodePos.x,nodePos.y)
			else 

			end 			
		else 
			trace("Ignoring industry as it is less than the distance to the destination")
		end 
		
	end 
	if shouldInvertPerpsign then 
		perpSign  = -perpSign
	end
	local isBuildExtensionToTerminal = math.min(dist1,dist2) < 500 and otherNode and util.isNodeConnectedToFrozenEdge(otherNode)
	trace("Trial pos was ",trialPos.x, trialPos.y," dist1 of the offsetnode was ",dist1, " dist2 was ",dist2,"therefore the perpSign was",perpSign,"shouldInvertPerpsign?",shouldInvertPerpsign,"reversals=",reversals,"isBuildExtensionToTerminal=",isBuildExtensionToTerminal)
	local success 
	if isBuildExtensionToTerminal then 
		--local connectNode = util.getNodeClosestToPosition(otherStationPos)
		local connectNode = otherNode
		trace("BuildExtensionToTerminal, connectNode was",connectNode)
		success = buildExtensionToTerminal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  getNextNodeId, nextEdgeId, station,edgesToRemove, rotate, connectNode, edgeIdx, params, otherStationNode, junctionIdx, perpSign )

	else 
	
		success =  routeBuilder.buildJunctionSpur(nodesToAdd, edgesToAdd, edgesToRemove, edgeObjectsToAdd, edgeObjectsToRemove, routeInfo, junctionIdx, directionSign, perpSign, joinNode, nextEdgeId, getNextNodeId, params, stationPos)   
	end 
		 
	if not success then 
		return false
	end 

	local newProposal 
	if not xpcall(function() newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) end, err) then 
		trace("ERROR setting up proposal, aborting in buildSpurConnect")
		if util.tracelog then 
			debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
		end
		return false
	end 
--	debugPrint(newProposal)
	
	local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if testData.errorState.critical then
		debugPrint(testData.errorState)
		trace("Critical error seen in the test data for buildJunctionSpur")
		if util.tracelog then 
			debugPrint(newProposal) 
			local diagnose = true
			--routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
			 
		end
		if params.junctionTrackOffset < 30  and not params.buildGradeSeparatedTrackJunctions  then -- maybe caused by too shallow crossing angle
			params.junctionTrackOffset = params.junctionTrackOffset+5
			trace("Attempting to increase junctionTrackOffset to",params.junctionTrackOffset)
		end
		return false 
	elseif #testData.errorState.messages > 0 and not params.ignoreErrors then
		debugPrint(testData.collisionInfo.collisionEntities)
		debugPrint(testData.errorState)
		trace("Ignorable error seen in the test data for buildJunctionSpur")		
		return false
	end 
		 
	 
	trace("About to build command to build connecting spur from node")
	--debugPrint(newProposal)
	util.clearCacheNode2SegMaps()
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), params.ignoreErrors)
	trace("About to send command to build connecting spur from node")
	if isBuildExtensionToTerminal then 
		if not params.extensionsToTerminal then 
			params.extensionsToTerminal = {}
		end 
		params.extensionsToTerminal[otherNode]=true
	end 
	api.cmd.sendCommand(build, callback)
	return true
end


function routeBuilder.buildConnectingRouteSpur(connectStation, station, routeInfo, callback, params, destinationPos, index)
	if util.size(getDeadEndNodesForStation(connectStation, station, 350, params)) > 1 then 
		trace("Station ",connectStation, " already has a spur")
		params.isDoubleTrack = true 
		if index == 1 then 
			params.station1SpurConnect = connectStation 
		elseif index == 2 then 
			params.station2SpurConnect = connectStation
		end 
		return false -- already has a spur
	end 
	

--	buildCrossover(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo.edges[routeInfo.lastFreeEdge], backwards, getNextNodeId, nextEdgeId, station ) 
	-- buildCrossoverExistingEdges(nodesToAdd, edgesToAdd,  routeInfo.edges[routeInfo.lastFreeEdge],  getNextNodeId, nextEdgeId, station,edgesToRemove ) 
	--local firstFreeEdge = routeInfo.edges[routeInfo.firstFreeEdge].edge
	--local edgeIdx = routeInfo.lastFreeEdge
	--local nextEdgeIdx = edgeIdx-1
	local stationConstructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	local node0 = routeInfo.edges[routeInfo.lastFreeEdge].edge.node0 
	local node1 = routeInfo.edges[routeInfo.lastFreeEdge].edge.node1
	local upperConstruction = util.isNodeConnectedToFrozenEdge(node0) or util.isNodeConnectedToFrozenEdge(node1)
	local isHigh =  upperConstruction == stationConstructionId  
	--[[local stationPos =  util.getStationPosition(station)
	if util.distance(util.getEdgeMidPoint(routeInfo.edges[routeInfo.lastFreeEdge].id),stationPos) > util.distance(util.getEdgeMidPoint(routeInfo.edges[routeInfo.firstFreeEdge].id), stationPos) then 
		edgeIdx = routeInfo.firstFreeEdge
		nextEdgeIdx = edgeIdx +1
		isHigh = false
	end]]--
	
	local edgeIdx
	local nextEdgeIdx
	--local edge = routeInfo.edges[nextEdgeIdx].edge 
	local useNode0 --= util.distance(util.nodePos(edge.node0), destinationPos) > util.distance(util.nodePos(edge.node1), destinationPos)
	if isHigh then 
		edgeIdx = routeInfo.lastFreeEdge-1
		nextEdgeIdx = routeInfo.lastFreeEdge
		local edge = routeInfo.edges[routeInfo.lastFreeEdge].edge 
		local nextEdge = routeInfo.edges[routeInfo.lastFreeEdge-1].edge 
		useNode0 = nextEdge.node0 == edge.node0 or nextEdge.node0 == edge.node1
	else 
		edgeIdx = routeInfo.firstFreeEdge
		nextEdgeIdx = routeInfo.firstFreeEdge+1
		local edge = routeInfo.edges[edgeIdx].edge 
		if util.isNodeConnectedToFrozenEdge(edge.node0) then 
			useNode0 = true 
		else 
			useNode0 = false
		end 
		 
	end 
	trace("Building connecting spur. The connectStation was ",connectStation, " station ",station, " otherStation",otherStation,"isHigh?",isHigh,"useNode0?",useNode0,"upperConstruction=",upperConstruction)
	local endAt = isHigh and 1 or #routeInfo.edges
	local increment = isHigh and -1 or 1
	routeInfo.changeIndexes = {}
	routeInfo.useNode0 = {}
	local priorEdge = routeInfo.edges[edgeIdx].edge
	local count = 0 
	for i = nextEdgeIdx, endAt, increment do 
		count = count + 1
		local edge = routeInfo.edges[i].edge 
		local nodeChange = priorEdge.node0 == edge.node0 or priorEdge.node1 == edge.node1
		routeInfo.changeIndexes[i] = nodeChange
		local nextEdgeId = routeInfo.edges[i].id
		if nodeChange then 
			useNode0 = not useNode0
			trace("Found node change at i=",i," nextEdgeId=",nextEdgeId,"endAt=",endAt,"increment=",increment,"useNode0",useNode0)
			
		else 
			--[[local alternativeNode0 = util.distance(stationPos, util.nodePos(edge.node1)) > util.distance(stationPos, util.nodePos(edge.node0))
			if alternativeNode0~=useNode0 then 
				trace("WARNING! alternativeNode0",alternativeNode0,"useNode0=",useNode0)
				if count < 4 then 
					trace("Swapping")
					useNode0 = alternativeNode0
				end 
			end]]--
		end 
		routeInfo.useNode0[i]=useNode0
		trace("at i=",i,"set routeinfo.useNode0 to ",routeInfo.useNode0[i],"nextEdgeId=",nextEdgeId)
		priorEdge = edge
	end 
	
	local function callback2(res, success)
		util.clearCacheNode2SegMaps()
		routeBuilder.addWork(function() 
			trace("Begin callback work to built route connecting spur following crossover")
			params.edgeIdx = edgeIdx
			local maxTries = 8
			util.cacheNode2SegMaps()
			local success = false 
			local wasBuildGradeSeparatedTrackJunctions = params.buildGradeSeparatedTrackJunctions
			for i = 1, maxTries do 
				xpcall(function() 
					success = routeBuilder.tryBuildConnectingRouteSpur(connectStation, station, routeInfo, callback, params, destinationPos, useNode0)
				end , err) 
				if success then 
					break 
				end
				if params.junctionTrackOffset < 30 then 
					params.junctionTrackOffset = 5+params.junctionTrackOffset
					trace("Increasing junction track offset to",params.junctionTrackOffset)
				end 
				if i>2 then 
					local nextBest = i-(i>4 and 2 or 1)
					trace("Changing best index offset to ",nextBest)
					params.joinIndexWinner = nextBest
				end 
				
				if i > 4 then 
					params.ignoreErrors = true 
				 
				end
				if i > 5 then 
					params.disableSignalBuild = true 
				end
				if i > 6 then 
					params.buildGradeSeparatedTrackJunctions = false 
					trace("Falling back to non grade seperated track junction")
				end
			end 
			params.buildGradeSeparatedTrackJunctions = wasBuildGradeSeparatedTrackJunctions
			params.disableSignalBuild = false
			if not success then 
				callback({}, false) 
			end 
		end)
	
	end
	buildCrossoverRepeat(routeInfo, station, params, edgeIdx, callback2)
	return true
end 
function routeBuilder.tryBuildConnectingRouteSpur(connectStation, station, routeInfo, callback, params, destinationPos, useNode0)
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local nextNodeId = -10000
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	
	local trackOffset = params.junctionTrackOffset
 
	
 
	 
	local connectStationPos = util.getStationPosition(connectStation)
	local industry = util.searchForNearestIndustry(connectStationPos, 300)
	local industryPos = industry and util.v3fromArr(industry.position) or connectStationPos
	local vectorToIndustry = industryPos - connectStationPos
	
	local options = {}
	 
	local alreadyValidated = {}  
	local function validateEdge(edgeId, edge)
		if not alreadyValidated[edgeId] then 
			if api.engine.entityExists(edgeId) and util.getEdge(edgeId) 
			and api.engine.entityExists(edge.node0) 
			and api.engine.entityExists(edge.node1) 
			and util.getNode(edge.node0) 
			and util.getNode(edge.node1) then 
				alreadyValidated[edgeId] = 1
			else 
				alreadyValidated[edgeId] = 0
			end 
		end 
		return alreadyValidated[edgeId] == 1
 	end
	for i = routeInfo.firstFreeEdge+1, routeInfo.lastFreeEdge-1 do
		if routeInfo.changeIndexes[i] then 
			trace("Detected change in node, swapping useNode0 at ",i, " useNode0=",useNode0," change to ",not useNode0)
			useNode0 = not useNode0
		end
		local edgeId = routeInfo.edges[i].id
		local edge = routeInfo.edges[i].edge
	 
		local priorEdgeId = routeInfo.edges[i-1].id 
		local priorEdge = routeInfo.edges[i-1].edge 
		local nextEdge = routeInfo.edges[i+1].edge 
		local nextEdgeId = routeInfo.edges[i+1].id 
		if not validateEdge(edgeId, edge) or not validateEdge(priorEdgeId, priorEdge) or not validateEdge(nextEdgeId, nextEdge)then 
			goto continue
		end
		
		if priorEdge.node0 == edge.node0 or priorEdge.node1 == edge.node1 then 
			trace("Detected change in node, swapping useNode0 (LOGIC DISABLED) at ",i)
			--useNode0 = not useNode0
		end
		trace("Overriding original useNode0",useNode0," with ",routeInfo.useNode0[i])
		useNode0 = routeInfo.useNode0[i]
		local joinNode 
		if useNode0 then 
			joinNode = edge.node0
		else 
			joinNode = edge.node1
		end
		local node = joinNode == edge.node0 and edge.node1 or edge.node0
		local nodePos = util.nodePos(node)
		local tangent = util.v3(node == edge.node0 and edge.tangent0 or edge.tangent1)
		
		local trialPos = util.nodePointPerpendicularOffset(nodePos,tangent, trackOffset)	
		local trialPos2 =  util.nodePointPerpendicularOffset(nodePos, -1*tangent, trackOffset)	
		local leftHandDistance =util.distance(destinationPos, trialPos)
		local rightHandDistance = util.distance(destinationPos, trialPos2)
		local perpSign = leftHandDistance <  rightHandDistance and 1 or -1 
		
		trace("tryBuildConnectingRouteSpur: The leftHandDistance was ", leftHandDistance," the rightHandDistance was ",rightHandDistance," therefore the perpSign was ",perpSign)
		if industry and util.distance(nodePos, industryPos) < 500 then 
			--[[
			local angle1 = util.signedAngle(trialPos-nodePos, vectorToIndustry)
			local angle2 = util.signedAngle(trialPos2-nodePos, vectorToIndustry)
			trace("Near to an industry, angle1 was ",math.deg(angle1), "angle2 was ",math.deg(angle2), " perpSign originally",perpSign)
			perpSign = math.abs(angle1) > math.abs(angle2) and 1 or -1 
			trace("After correcting to pass industry perpSign is now ",perpSign)
			]]--
			local vectorToIndustry1 = industryPos - trialPos 
			local vectorToIndustry2 = industryPos - trialPos2
			local vectorToIndustry = industryPos - nodePos
			local angle1 = util.signedAngle(vectorToIndustry1, vectorToIndustry)
			local angle2 = util.signedAngle(vectorToIndustry2, vectorToIndustry)
			trace("Near to an industry, angle1 was ",math.deg(angle1), "angle2 was ",math.deg(angle2), " perpSign originally",perpSign)
			perpSign = math.abs(angle1) < math.abs(angle2) and 1 or -1 
			trace("After correcting to pass industry perpSign is now ",perpSign,"at ",nodePos.x,nodePos.y)
			
		end 
		
		
		local newNodePos = util.nodePointPerpendicularOffset(nodePos,perpSign*tangent, trackOffset)	
		
		local newNodePos = util.nodePointPerpendicularOffset(util.nodePos(node),perpSign*tangent, params.junctionTrackOffset)
		local exitTangent = newNodePos - util.nodePos(joinNode)
		local stationVector = destinationPos-newNodePos
		local mainLineVector = newNodePos -util.getStationPosition(station)
		local interceptAngle = math.abs(util.signedAngle(mainLineVector, stationVector))
		local distance = vec3.length(stationVector)
		local angleToVector = util.signedAngle(stationVector, exitTangent)
		local angleToIntercept = util.signedAngle(mainLineVector, exitTangent)
		local angleForTest = math.abs(angleToVector) > math.rad(90) and math.abs(angleToVector-math.rad(180)) or math.abs(angleToVector)
	
		local canAccept =  util.calculateSegmentLengthFromEdge(edge) >= 70 
			and not util.isJunctionEdge(edge) 
		if params.buildGradeSeparatedTrackJunctions then 
			canAccept = canAccept  
			and	util.calculateSegmentLengthFromEdge(nextEdge) >= 70 
			and not util.isJunctionEdge(nextEdge) 
			and util.calculateSegmentLengthFromEdge(priorEdge) >= 70 
			and not util.isJunctionEdge(priorEdge)
		end 
		
		local nearbyEdgeCount = util.countNearbyEntities(newNodePos, params.targetSeglenth, "BASE_EDGE")
		if canAccept then 
			if routeInfo.changeIndexes[i-1]
			or routeInfo.changeIndexes[i]
			or routeInfo.changeIndexes[i+1] then 
				trace("Setting canAccept to false at",i,"due to proximity of change indexes")
				canAccept = false 
			end 
		end 
		
		trace("tryBuildConnectingRouteSpur: At i=",i," checking option, distance was ", distance, " angleToVector=",math.deg(angleToVector)," angleForTest=",math.deg(angleForTest), " interceptAngle=",math.deg(interceptAngle)," angleToIntercept=",math.deg(angleToIntercept)," canAccept=",canAccept, " nearbyEdgeCount=",nearbyEdgeCount)
		
		
		if  canAccept then 
			table.insert(options, {
				joinIndex = i,
				perpSign = perpSign,
				joinNode = joinNode,
				useNode0 = useNode0,
				industry = industry,
				scores = { 
					distance,
					angleForTest,
					interceptAngle,
					nearbyEdgeCount
				}
			})
		end
		priorEdge = edge
		::continue::
	end
	local weights = {
		100 , -- distance 
		15, -- angleForTest
		5, -- interceptAngle  
		10  -- nearbyEdges
	}
	local results = util.evaluateAndSortFromScores(options, weights)
	local best = results[1] 
	if params.joinIndexWinner then 
		best = results[params.joinIndexWinner] 
	end
	local joinIndex = best.joinIndex 
	trace("tryBuildConnectingRouteSpur: Evaluating options from ",#options," options the joinIndex was ",joinIndex, " params.joinIndexWinner=",params.joinIndexWinner)
	if util.tracelog then debugPrint(results) end

	local edge = routeInfo.edges[joinIndex].edge
	local joinNode = best.joinNode
	  
	 
	local perpSign = best.perpSign
	 
--	local nodePos = util.nodePos(node)
--	local tangent = util.v3(backwards and edge.tangent0 or edge.tangent1)
--	local newNodePos = util.nodePointPerpendicularOffset(nodePos,perpSign*tangent, trackOffset)
	  

	
	

	local distToStation =  util.distance(util.nodePos(joinNode), connectStationPos)
	trace("tryBuildConnectingRouteSpur: the distToStation was",distToStation)
	if distToStation < 500 then 
		trace("tryBuildConnectingRouteSpur: calling onto buildExtensionToTerminal directly")
		local success = buildExtensionToTerminal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgeObjectsToRemove,  routeInfo,  nextNodeId, nextEdgeId, station,edgesToRemove, rotate, connectNode, edgeIdx, params, otherStationNode )
		if not success then 
			return false 
		end 
	
	else 
		local newEdges =  routeBuilder.buildJunctionSpur(nodesToAdd, edgesToAdd, edgesToRemove, edgeObjectsToAdd, edgeObjectsToRemove, routeInfo, joinIndex, directionSign, perpSign, joinNode, nextEdgeId, getNextNodeId, params, destinationPos)
		if not newEdges then return false end
		if not params.joinNodePos then 
			params.joinNodePos = {} 
		end 
		params.joinNodePos[connectStation] = newEdges.newNode1Pos
		trace("tryBuildConnectingRouteSpur: The newEdges.newNode1Pos=",newEdges.newNode1Pos, " connectStation =",connectStation)
		trace("tryBuildConnectingRouteSpur: Set the joinNodePos for",connectStation," to ",params.joinNodePos[connectStation].x,params.joinNodePos[connectStation].y)
	end 	
	
	
	if util.tracelog then 
		debugPrint({edgesToAdd=edgesToAdd, nodesToAdd=nodesToAdd})
	end 
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	local debugInfo = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
 
 
	if debugInfo.errorState.critical then 
		debugPrint({ collisionInfo = debugInfo.collisionInfo , errorState = debugInfo.errorState})
		debugPrint(newProposal) 
		return false
	end
	trace("About to build command to build connecting spur")
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace("About to send command to build connecting spur")
	util.clearCacheNode2SegMaps()
	api.cmd.sendCommand(build, callback)
	return true
end

function routeBuilder.checkAndPrepareForRouteCombination(connectStation,station , callback, params, otherStation, index)
	trace("checking and preparing for route combination with stations ",connectStation," and ",station)
	util.cacheNode2SegMapsIfNecessary()
	--local routeInfo = pathFindingUtil.getRouteInfo(connectStation, station)
	local freeTerminal = util.getFreeTerminal(station)
	local preferredTerminal = util.getTerminalClosestToFreeTerminal(station)
	
	local routeInfo = pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(station,preferredTerminal-1 , connectStation)
	trace("Trying to find a path using terminal ",preferredTerminal,"found?",routeInfo~=nil)
	local routeInfoFn = function() return pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(station,preferredTerminal-1 , connectStation) end 
	if not routeInfo then 
		if freeTerminal < preferredTerminal then 	
			preferredTerminal = freeTerminal + 1 
		else 
			preferredTerminal = freeTerminal - 1 
		end
		if preferredTerminal >= 1 and preferredTerminal <= #util.getStation(station).terminals then 
			trace("Trying to find a path using other nearby terminal ",preferredTerminal)
			routeInfo = pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(station,preferredTerminal-1 , connectStation)
			routeInfoFn = function() return pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(station,preferredTerminal-1 , connectStation) end
		end 	
		if not routeInfo then 
			trace("No route from preferredTerminal, falling back",connectStation, station)
			routeInfo = pathFindingUtil.getRouteInfo(station, connectStation)
			routeInfoFn = function() return pathFindingUtil.getRouteInfo(station, connectStation) end 
		end
	end 
	
	
	
	if routeInfo.numSignals == 0 then
		local callbackThis = function(res, success)
			if success then
				trace("upgrade to double track was successful, adding work for next stage")
				routeBuilder.addWork(function() routeBuilder.checkAndPrepareForRouteCombination(connectStation, station, callback, params, otherStation,   index) end)
			else 	
				debugPrint(res.errorState)
			end
			routeBuilder.standardCallback(res, success)
		end
		routeBuilder.upgradeToDoubleTrack(routeInfo, callbackThis, params)
		return true
	else 
		local destinationPos = util.getStationPosition(otherStation)
		trace("Checking for joinNodePos for station",connectStation)
		if params.joinNodePos and params.joinNodePos[connectStation] then 
			destinationPos = params.joinNodePos[connectStation]
			trace("Found join node pos")
		end
		return routeBuilder.buildConnectingRouteSpur(connectStation, station, routeInfo,callback, params, destinationPos, index)
	end
end

local function getDeadEndNodesInVicinity(nodePos, range) 
	local result = {}
	if not range then range =350 end
	for i, node in pairs(util.searchForEntities(nodePos, range, "BASE_NODE")) do
		local edges = util.getTrackSegmentsForNode(node.id)
		if #edges == 1 and -1 == api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edges[1]) then
			table.insert(result, node.id)
		end
	end
	trace("found ",#result," dead end nodes near ", nodePos.x,nodePos.y)
	if #result == 0 and range < 1000 then 
		return getDeadEndNodesInVicinity(nodePos, 100+range)
	end 
	return result
end

function routeBuilder.checkAndPrepareForRouteCombinationWithNode(station, node, otherStation, callback, params, isIntermediateRoute, otherNode)
	trace("checking and preparing for route combination with node ",node," and ",station, " otherStation was ",otherStation,"otherNode was",otherNode)
	util.cacheNode2SegMaps()
	local routeInfo
	local routeInfoFn
	
	if not isIntermediateRoute then 
		local edgeId = util.getTrackSegmentsForNode(node)[1]
		local lineStops = api.engine.system.lineSystem.getLineStopsForStation(otherStation)
		-- trying to find an existing line route into the station to validate the connection at the terminal, and the crossover is built at the correct track
		for i, lineId in pairs(lineStops) do 
			local line = util.getComponent(lineId, api.type.ComponentType.LINE)
			for __, stop in pairs(line.stops) do 
				local stationId = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations[stop.station+1]
				if otherStation~=stationId then 
				
					local foundPath =  #pathFindingUtil.findRailPathBetweenEdgeAndStation(edgeId, stationId)>0 
					if not foundPath then 
						local doubleTrackEdge = util.findDoubleTrackEdge(edgeId)
						trace("initial attempt failed, trying with double track edge", doubleTrackEdge )
						if doubleTrackEdge then 
							foundPath =  #pathFindingUtil.findRailPathBetweenEdgeAndStation(doubleTrackEdge, stationId)>0 
						end
					end 
					if foundPath then 
						local preferredTerminal = util.getTerminalClosestToFreeTerminal(otherStation)
						trace("Did find a apath, trying to use terminal ",preferredTerminal)
						routeInfo = pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(otherStation,preferredTerminal-1 , stationId)
						routeInfoFn = function() return pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(otherStation,preferredTerminal-1 , stationId) end
						if not routeInfo then 
							trace("No route from preferredTerminal, falling back")
							routeInfo = pathFindingUtil.getRouteInfo(otherStation, stationId)
							routeInfoFn = function() return pathFindingUtil.getRouteInfo(otherStation, stationId)end
						end 
						if routeInfo and routeInfo.containsNode(node) then 
							break 
						end
					else 
						trace("Did NOT find a path")
					end
				end
			end
			if routeInfo  and routeInfo.containsNode(node)  then 
				break 
			end
		end
		trace("Found route info from stations? ",routeInfo)
		if not routeInfo then 
			local edge = util.getEdge(edgeId) 
			local node0Pos = util.nodePos(edge.node0)
			local node1Pos = util.nodePos(edge.node1)
			local function getEdgeId() -- because we may replace the edge
				return util.findEdgeConnectingNodes(util.getNodeClosestToPosition(node0Pos),util.getNodeClosestToPosition(node1Pos))
			end 
			
			trace("Route not found from intermediate line, attempting to find direct line route")
			local answer = pathFindingUtil.findRailPathBetweenEdgeAndStationFreeTerminal(edgeId, otherStation, true) 
			if #answer > 0 then 
				trace("Route not found to preferred terminal")
				routeInfo = pathFindingUtil.getRouteInfoFromEdges(answer)
				routeInfoFn = function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgeAndStationFreeTerminal(getEdgeId(), otherStation, true) )end
			else 
				answer = pathFindingUtil.findRailPathBetweenEdgeAndStation(edgeId, otherStation, nil, true) 
				if #answer > 0 then 
					trace("Route not found to other terminal")
					routeInfo =  pathFindingUtil.getRouteInfoFromEdges(answer)
					routeInfoFn = function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdgeAndStation(getEdgeId(), otherStation, nil, true) )end
				end 
			end			
		end 
	else 
		routeInfoFn = function()
			local node1 = util.getNodeClosestToPosition(params.intermediateRouteNodePos1)
			local node2 = util.getNodeClosestToPosition(params.intermediateRouteNodePos2)
			trace("attempting to find routeinfo between",node1,node2)
			return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node1, node2))
		end 
		routeInfo = routeInfoFn()
	end 
	
	if not routeInfo then 
		trace("WARNING! Having to find route info directly from node",node)
		routeInfo = pathFindingUtil.getRouteInfoFromTrackNode(node)
		routeInfo.routeInfoFromNode = true
		local p = util.nodePos(node)
		routeInfoFn = function() return pathFindingUtil.getRouteInfoFromTrackNode(util.getNodeClosestToPosition(p)) end
	end
	if routeInfo.numSignals == 0 then
		trace("No signals found ,upgrading to double track")
		local callbackThis = function(res, success)
			if success then
				trace("upgrade to double track was successful, adding work for next stage")
				routeBuilder.addWork(function() routeBuilder.checkAndPrepareForRouteCombinationWithNode(station, node, otherStation, callback, params, isIntermediateRoute, otherNode) end)
			else 	
				debugPrint(res.errorState)
			end
			routeBuilder.standardCallback(res, success)
		end
		routeBuilder.upgradeToDoubleTrack(routeInfo, callbackThis, params)
		return true
	else 
		trace("Proceeding with buildConnectingRouteSpurFromNode")
		return routeBuilder.buildConnectingRouteSpurFromNode(node, station, otherStation, routeInfo, callback, params, routeInfoFn, isIntermediateRoute, otherNode) 
	end
end

local function getClosestAppropriateTrackNode(station, edges, otherStationPos, params, edges2, nodes) 
	util.lazyCacheNode2SegMaps()
	local stationNodes = getDeadEndNodesForStation(station)
	local connectNodes = util.getNodesFromEdges(edges)
	if edges2 then 
		stationNodes = util.getNodesFromEdges(edges2) 
	end
	if nodes then 
		stationNodes = nodes 
	end
	trace("About to find shortest distance node pair from ",#stationNodes," and ",#connectNodes)
	local nodePair = evaluateBestJoinNodePair(stationNodes, edges, params, otherStationPos)
	if not nodePair then 
		return 
	end
	local stationNode = nodePair[1]
	local connectNode = nodePair[2]
	if util.tracelog then debugPrint({initialNodePair=nodePair})end
	if edges2 then 
		local nodePair2 =  evaluateBestJoinNodePair({connectNode}, edges2, params,  util.nodePos(stationNode))
		if not nodePair2 then 
			return 
		end
		trace("Setting the second connect node to ",nodePair2[2], " from ",nodePair[1])
		--nodePair = evaluateBestJoinNodePair(stationNodes, edges, params, util.nodePos(nodePair2[1]))
		--if util.tracelog then debugPrint({recaclulatedNodePair=nodePair, nodePair2=nodePair2}) end
		nodePair[1]=nodePair2[2]
	end 
	stationNode = nodePair[1]
	connectNode = nodePair[2]
	 
	local distToOtherStation = util.distance(util.nodePos(connectNode),otherStationPos )
	local distBetweenNodes = util.distBetweenNodes(stationNode, connectNode)
	trace("there were ",#connectNodes," available, chosen ",connectNode,"  dist was ", distToOtherStation, " distBetweenNodes=",distBetweenNodes)
	if distBetweenNodes  < 200 then  -- too close. Not immediately filtering on distance as want to get the actual closest station node 
		local candidateNodes = {}
		for __, node in pairs(connectNodes) do -- filter to all nodes above the distance and in the direction of the other station
			if util.distBetweenNodes(stationNode, node) > 200 and util.distance(util.nodePos(node), otherStationPos) < distToOtherStation then
				table.insert(candidateNodes, node)
			end
		end
		trace("there were ",#candidateNodes," available of ",#connectNodes)
		if #candidateNodes > 0 then
			nodePair = evaluateBestJoinNodePair({stationNode}, edges, params, otherStationPos)
		end
	end
	  
	return nodePair
end

function routeBuilder.buildCombiningTrackRoute(nodePair, params, callback, intermediateEdges, recursionDepth)
	if not recursionDepth then recursionDepth = 0 end
	local leftNode = nodePair[1]
	local rightNode = nodePair[2]
	trace("Called to buildCombiningTrackRoute with node pair",leftNode,rightNode," recursionDepth=",recursionDepth)
	if #pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(leftNode, rightNode)> 0 then 
		trace("Nodes were already connected, aborting") 
		return 
	end
	if not intermediateEdges then 
		intermediateEdges = routeEvaluation.checkForIntermediateTrackRoute({leftNode}, {rightNode}, params, true)
	end
	if intermediateEdges.isIntermediateRoute then 
		local nodePair1 = evaluateBestJoinNodePair({leftNode},  intermediateEdges.leftConnectedEdges, params, util.nodePos(rightNode),intermediateEdges.leftConnectedEdges, recursionDepth) 
		local nodePair2 = evaluateBestJoinNodePair({rightNode},  routeBuilder.getFilteredRightConnectedEdges(nodePair1, intermediateEdges), params,  util.nodePos(leftNode),intermediateEdges.rightConnectedEdges,recursionDepth)
		local routeInfo = routeBuilder.validateIntermediateRoute(nodePair1, nodePair2)
		if routeInfo then 
			if params.isAutoBuildMode then 
				params.buildGradeSeparatedTrackJunctions = true 
				trace("Setting buildGradeSeparatedTrackJunctions to true")
			end
			trace("Begin building combining track route from original node pair",leftNode,rightNode)
			local intermediateCallbackCount = 0
			local intermediateRouteCallback = function(res, success) 
				if success then 
					intermediateCallbackCount = intermediateCallbackCount + 1
					if intermediateCallbackCount == 2 then 
						callback(res, success)
					end
				else 
					callback(res, success)
				end 
			end 
			local leftNodePos = util.nodePos(leftNode)
			local rightNodePos = util.nodePos(rightNode)
			local leftConnectNode = nodePair1[2]
			local rightConnectNode = nodePair2[2]
			local leftConnectNodePos = util.nodePos(leftConnectNode)
			local rightConnectNodePos = util.nodePos(rightConnectNode)
			local function callback1(res, success) 
				util.clearCacheNode2SegMaps()
				if success then 
					routeBuilder.addWork(function() 
						util.cacheNode2SegMaps()
						local leftNodes = {leftNode, nodePair[3] }
						if leftNode and params.extensionsToTerminal and params.extensionsToTerminal[leftNode] then 
							trace("Detected leftNode",leftNode,"connected directly, calling back")
							intermediateRouteCallback({}, true )
							return 
						end 
						local rightNodes =  getDeadEndNodesInVicinity(leftConnectNodePos, 350)
						if #rightNodes == 0 then 
							trace("WARNING , no right nodes found, attempting at learger range")
							 rightNodes =  getDeadEndNodesInVicinity(leftConnectNodePos, 2*350)
						end
						params.isDoubleTrack = true 
						local newNodePair = findShortestDistanceNodePair(leftNodes, rightNodes, params)	
						trace("Building combining track route on the left hand side between", newNodePair[1], newNodePair[2],"original node pair",leftNode,rightNode)
						routeBuilder.buildCombiningTrackRoute(newNodePair, params, intermediateRouteCallback, nil, recursionDepth+1)
					end)
				else 
					callback(res, success)
				end 
			end
			local function callback2(res, success) 
				util.clearCacheNode2SegMaps()
				if success then 
					routeBuilder.addWork(function()
						util.cacheNode2SegMaps()
						local leftNodes = {rightNode, nodePair[4] }
						if rightNode and params.extensionsToTerminal and params.extensionsToTerminal[rightNode] then 
							trace("Detected rightNode",rightNode,"connected directly, calling back")
							intermediateRouteCallback({}, true )
							return 
						end 
						local rightNodes =  getDeadEndNodesInVicinity(rightConnectNodePos, 350)
						if #rightNodes == 0 then 
							trace("WARNING , no right nodes found, attempting at learger range")
							 rightNodes =  getDeadEndNodesInVicinity(rightConnectNodePos, 2*350)
						end
						params.isDoubleTrack = true 
						local newNodePair = findShortestDistanceNodePair(leftNodes, rightNodes, params)	
						trace("Building combining track route on the right hand side between", newNodePair[1], newNodePair[2],"original node pair",leftNode,rightNode)
					
						routeBuilder.buildCombiningTrackRoute(newNodePair, params, intermediateRouteCallback, nil, recursionDepth+1)
					end)
				else 
					callback(res, success)
				end 
			end
			local idx1 = routeInfo.getIndexOfClosestApproach(leftConnectNodePos)
			local idx2 = routeInfo.getIndexOfClosestApproach(rightConnectNodePos)
			trace("Buildingspur connect, connectNodes were",leftConnectNode,rightConnectNode," idx1=",idx1,"idx2=",idx2)
			params.disableSignalBuild = true 
			routeBuilder.buildSpurConnectRepeat(leftConnectNode, leftNodePos, rightNodePos, routeInfo, callback1, params,idx1, nodePair1[1]) 
			util.clearCacheNode2SegMaps()
		--	routeInfo = routeBuilder.validateIntermediateRoute(nodePair1, nodePair2)
		--idx2 = routeInfo.getIndexOfClosestApproach(rightConnectNodePos)
			params.disableSignalBuild = false 
			trace("Buildingspur connect 2, connectNodes were",leftConnectNode,rightConnectNode," idx1=",idx1,"idx2=",idx2)
			routeBuilder.buildSpurConnectRepeat(util.getNodeClosestToPosition(rightConnectNodePos), rightNodePos, leftNodePos, routeInfo, callback2, params, idx2, nodePair2[1]) 
		else
			trace("Validation failed, falling back to build route")
			routeBuilder.buildRoute(nodePair, params, callback)
		end 
	else 
		trace("No intermediate route, building directly")
		routeBuilder.buildRoute(nodePair, params, callback)
	end 
end
function routeBuilder.validateIntermediateRoute(nodePair1, nodePair2)


	if nodePair1 and nodePair2  then 
		local node1 = nodePair1[2]
		local node2 = nodePair2[2]
		local dist = util.distBetweenNodes(node1, node2) 
		trace("The distance between the nodes",node1,node2," was ",dist)
		if dist< 900 then
			trace("The distance was too short")
			return false 
		end 
		local node0 = nodePair1[1]
		local node3 = nodePair2[1]
		local dist1 = util.distBetweenNodes(node0, node1) 
		local dist2 = util.distBetweenNodes(node0, node2) 
		local dist3 = util.distBetweenNodes(node3, node1) 
		local dist4 = util.distBetweenNodes(node3, node2) 
		trace("The nodes chosen for intermediate route were", node1, node2," dist1=",dist1,"dist2=",dist2,"dist3=",dist3," dist4=",dist4)
		if dist2 < dist1 then 
			trace("Rejecting as dist2 < dist1")
			return false 
		end 
		if dist3 < dist4 then 
			trace("Rejecting as dist3 < dist4")
			return false 
		end
		
	--[[	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenNodes(node1, node2)) 
			or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenNodes(util.findDoubleTrackNode(node1), node2))
			or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenNodes(util.findDoubleTrackNode(node1), util.findDoubleTrackNode(node2)))
			or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenNodes(node1, util.findDoubleTrackNode(node2))) ]]--
		return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node1, node2))
	
	else 
		trace("Missing a nodePair, nodePair1=",nodePair1,"nodePair2=",nodePair2)
	end 
	return false 
end

function routeBuilder.getFilteredRightConnectedEdges(nodePair, intermediateEdges)
	local result = {} 
	if not nodePair then 
		return result 
	end
	local node = nodePair[2] 
	local segs = util.getSegmentsForNode(node)
	if #segs == 1 and util.isFrozenEdge(segs[1]) then 
		
		node = nodePair[1]
		segs = util.getSegmentsForNode(node)
		trace("WARNING! Got segs as the frozen edge, attempting to compensate, got",#segs)
		debugPrint({nodePair=nodePair})
	end 
	for i, edgeId in pairs(intermediateEdges.rightConnectedEdges) do 
		if not api.engine.entityExists(edgeId) then 
			goto continue 
		end 
		if intermediateEdges.matchedPairs[segs[1]] and intermediateEdges.matchedPairs[segs[1]][edgeId] then 
			table.insert(result, edgeId)
		elseif segs[2] and intermediateEdges.matchedPairs[segs[2]] and intermediateEdges.matchedPairs[segs[2]][edgeId] then
			table.insert(result, edgeId)
		elseif intermediateEdges.checkIfEdgesShareLine(segs[1], edgeId) or segs[2] and  intermediateEdges.checkIfEdgesShareLine(segs[2], edgeId) then 
			table.insert(result, edgeId)
		else 
			if not pcall(function() 
				local edge = util.getEdge(edgeId)
				if #pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(edge.node0, node) > 0 then 
					table.insert(result, edgeId)
				else 
					trace("Rejecting edge",edgeId, " as it was not matched")
				end
			end) then 
				trace("ERROR detected while inspecting edge ",edgeId)
			end 
		end 
		::continue::
	end 
	trace("getFilteredRightConnectedEdges gave ",#result," of ",#intermediateEdges.rightConnectedEdges)
	if #result == 0 and util.tracelog  then 
	
		trace("WARNING! No right edges found")
		debugPrint({node=node,segs=segs,intermediateEdges=intermediateEdges})
	end 
	return result
end

function routeBuilder.buildRouteBetweenStations(station1, station2, params, callback)
	trace("Begin building route between stations",station1, station2)
	if pathFindingUtil.checkForRailPathBetweenStationFreeTerminals(station1, station2) and not params.isCircularRoute then 
		trace("Aborting as there is already a path")
		trace(debug.traceback())
		callback({}, true)
		return
	end 
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	params.station1 = station1
	params.station2 = station2
	
	if params.isTrack and not params.isCargo and params.alwaysDoubleTrackPassengerTerminus then 
		if not params.crossoversBuilt then 
			params.crossoversBuilt = {}
		end
		local callbackCount =0 
		local callbackThis = function(res, success) 
			callbackCount = callbackCount + 1
			trace("callBackThis: callbackCount=",callbackCount)
			--trace(debug.traceback())
			if callbackCount > 1 then 
				trace("WARNING! Callback count > 1, aborting")
				trace(debug.traceback())
				return 
			end 
			if success then 
				util.clearCacheNode2SegMaps()
				params.isDoubleTrack = true
				routeBuilder.addWork(function() routeBuilder.buildRouteBetweenStations(station1, station2, params, callback) end)
			else 
				callback(res, success)
			end
		end 
		local isStation1Terminus = util.isStationTerminus(station1) or params.buildTerminus[api.engine.system.stationSystem.getTown(station1)]
		if isStation1Terminus and util.countFreeTerminalsForStation(station1)>=2 and not params.crossoversBuilt[station1] then 
			params.crossoversBuilt[station1] = true 
			trace("buildRouteBetweenStations: building crossover at", station1)
			routeBuilder.buildCrossover( station1, station2, params, callbackThis ) 
			return
		end 
		local isStation2Terminus = util.isStationTerminus(station2) or params.buildTerminus[api.engine.system.stationSystem.getTown(station2)]
		if isStation2Terminus  and util.countFreeTerminalsForStation(station2)>=2 and not params.crossoversBuilt[station2] then 
			params.crossoversBuilt[station2] = true 
			trace("buildRouteBetweenStations: building crossover at", station2)
			routeBuilder.buildCrossover( station2, station1, params, callbackThis ) 
			return
		end 
	end 
	
	local trackSharingAllowed = params.isTrack and (params.isCargo or params.allowPassengerCargoTrackSharing)
	if not params.allowCargoTrackSharing then 
		trackSharingAllowed = false
	end 
	if trackSharingAllowed then
		local existingRoute = pathFindingUtil.getRouteInfo(station1, station2) 
		if existingRoute then 
			trace("Found existing route, checking and upgrading to the new thing")
			local wrappedCallback = function(res, success)
				trace("Result of callback for existing route upgrade to double track",success)
				util.clearCacheNode2SegMaps()
				if success then 
					routeBuilder.addWork(function() 
						local invCount = 0 
						local callback2 = function(res, success) 
							trace("buildRouteBetweenStations: callback for buildCrossoverRepeat on existingRoute, success=",success,"invCount=",invCount)
							util.clearCacheNode2SegMaps()
							if success then 
								invCount = invCount+1
								trace("callback from crossover build invCount was ",invCount)
								if invCount == 2 then 
									callback(res, success)
								end 
							else 
								callback(res, success)
							end 
						end 
						local routeInfo =  pathFindingUtil.getRouteInfo(station1, station2) 
						buildCrossoverRepeat(routeInfo, station1, params, routeInfo.firstFreeEdge, callback2)
						buildCrossoverRepeat(routeInfo, station2, params, routeInfo.lastFreeEdge, callback2)
					end) 
				else 
					callback(res, success)
				end 
			end 
			if not existingRoute.isDoubleTrack then 
				routeBuilder.upgradeToDoubleTrack(existingRoute, wrappedCallback, params)
			else 
				wrappedCallback({}, true)
			end
				
			return 
		end 
		local stationPair = routeEvaluation.checkForIntermediateStationTrackRoute(station1, station2, params)
		trace("Completed chack for intermediate station pair")
		local callbackThis = function(res, success)
			util.clearCacheNode2SegMaps()
			if success then
				params.isDoubleTrack = true
				routeBuilder.addWork(function() routeBuilder.buildRouteBetweenStations(station1, station2, params, callback) end)
			else 
				debugPrint(res.collisionInfo)
				debugPrint(res.errorState)
				
			end
			routeBuilder.standardCallback(res, success)
		end
		local foundIntermidiateStation = false
		if stationPair[1]~=station1 and stationPair[1]~= stationPair[2] then
			trace("found an intermediate station for station1")
			if not params.station1SpurConnect and routeBuilder.checkAndPrepareForRouteCombination(stationPair[1], station1, callbackThis, params, station2, 1) then 
				params.station1SpurConnect = stationPair[1]
				params.isDoubleTrack = true
				return
			end
			station1 = stationPair[1]
			
			foundIntermidiateStation = true
		end
		if stationPair[2]~=station2 and stationPair[1]~= stationPair[2] then
			trace("found an intermediate station for station2")
			if not params.station2SpurConnect and routeBuilder.checkAndPrepareForRouteCombination(stationPair[2], station2, callbackThis, params, station1,2) then 
				params.station2SpurConnect = stationPair[2]
				params.isDoubleTrack = true
				return
			end
			station2 = stationPair[2] 
			foundIntermidiateStation = true
		end
		local foundIntermidiateStation =  params.station1SpurConnect   or params.station2SpurConnect 
		
		local intermediateCallbackCount = 0
		local intermediateRouteCallback = function(res, success) 
			util.clearCacheNode2SegMaps()
			if success then 
				intermediateCallbackCount = intermediateCallbackCount + 1
				if intermediateCallbackCount == 2 then 
					callback(res, success)
				end
			else 
				callback(res, success)
			end 
		end 
		
		
		if   params.station1SpurConnect == nil or params.station2SpurConnect==nil then 
			--local station1 = params.station1 
			--local station2 = params.station2
			local intermediateEdges ={}
			intermediateEdges.leftConnectedEdges={}
			intermediateEdges.rightConnectedEdges={}
			if not foundIntermidiateStation then 
				intermediateEdges = routeEvaluation.checkForIntermediateTrackRoute(station1, station2, params)
			else 
				trace("Setting up intermediate route to intercept station node connect, spur1Connect?",params.station1SpurConnect," spur2Connect?",params.station2SpurConnect)
				local stationToUse
				local otherStation
				local nodes 
				if params.station1SpurConnect then 
					stationToUse = station2 
					otherStation = station1
					nodes =  getDeadEndNodesForStation(station1, params.station1SpurConnect, 350, params) 
				else 
					stationToUse = station1
					otherStation = station2
					nodes =  getDeadEndNodesForStation(station2, params.station2SpurConnect, 350, params) 
				end 
				trace("checkingForIntermediateTrackRoute, station was ",stationToUse," there were ",#nodes)
				local intermediateEdges = routeEvaluation.checkForIntermediateTrackRoute(stationToUse, nodes, params)
				trace("There were ",#intermediateEdges.rightConnectedEdges, " rightConnectedEdges and ",#intermediateEdges.leftConnectedEdges,"leftConnectedEdges")
				--local nextCallback = intermediateEdges.isIntermediateRoute and intermediateRouteCallback or callback
				if intermediateEdges.isIntermediateRoute then 
					trace("the intermediate route was detected building the route stationToUse=",stationToUse,"otherStation=",otherStation) 
					local deadEndNodesLeft = getDeadEndNodesForStation(stationToUse)
					local deadEndNodesRight = nodes
					
					--[[if stationToUse == station2 then 
						trace("Swapping the indermediate edges")
						local temp = intermediateEdges.leftConnectedEdges
						intermediateEdges.leftConnectedEdges = intermediateEdges.rightConnectedEdges
						intermediateEdges.rightConnectedEdges = temp
					end ]]--
					params.isDoubleTrack = true 
					local nodepair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
					routeBuilder.buildCombiningTrackRoute(nodepair, params, callback, intermediateEdges)
					return
				elseif #intermediateEdges.rightConnectedEdges > 0 then 
					local otherPos = util.nodePos(nodes[1])
					local nodePair =  getClosestAppropriateTrackNode(stationToUse, intermediateEdges.rightConnectedEdges, otherPos, params, nil, nodes) 
					if nodePair then 
						local node = nodePair[2]
						local nodePos = util.nodePos(node)
						trace("node was ",node)
						local function callbackThis(res, success)
							trace("calling back for intermediate intercept route preparation, success was",success)
							util.clearCacheNode2SegMaps()
							if success then 
								routeBuilder.addWork(function()
									params.isDoubleTrack = true
									local deadEndNodesLeft = nodes
									local deadEndNodesRight = getDeadEndNodesInVicinity(nodePos)
									local nodepair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
									routeBuilder.buildCombiningTrackRoute(nodepair, params, callback)
								end)
							end
							routeBuilder.standardCallback(res, success)
						end
						if routeBuilder.checkAndPrepareForRouteCombinationWithNode(otherPos, node, stationToUse, callbackThis, params) then
							return
						end
					end
				end

			end
			local station1Pos = util.getStationPosition(station1)
			local station2Pos = util.getStationPosition(station2)
			trace("The leftConnectedEdges were ",#intermediateEdges.leftConnectedEdges," rightConnectedEdges",#intermediateEdges.rightConnectedEdges,"  intermediateEdges.isIntermediateRoute?", intermediateEdges.isIntermediateRoute)
			if #intermediateEdges.leftConnectedEdges>0 and #intermediateEdges.rightConnectedEdges > 0 and not intermediateEdges.isIntermediateRoute then 
				local nodePair =  getClosestAppropriateTrackNode(station1, intermediateEdges.leftConnectedEdges, station2Pos, params, intermediateEdges.rightConnectedEdges) 
				if nodePair then 
					local node1 = nodePair[1]
					local node2 = nodePair[2]
					local nodePos1 = util.nodePos(node1)
					local nodePos2 = util.nodePos(node2)
					trace("node was ",node)
					local callbackCount = 0 
					local function callbackThis(res, success)	
						trace("calling back for station 1 and 2 preparation, success was",success)
						util.clearCacheNode2SegMaps()
						if success then 
							callbackCount = callbackCount + 1
							trace("callbackCount was",callbackCount)
							if callbackCount >= 2 then 
								routeBuilder.addWork(function()
									params.isDoubleTrack = true
									local deadEndNodesLeft = getDeadEndNodesInVicinity(nodePos1)
									local deadEndNodesRight = getDeadEndNodesInVicinity(nodePos2)
									local nodepair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
									routeBuilder.buildCombiningTrackRoute(nodepair, params, callback)
								end)
							end
						end
						routeBuilder.standardCallback(res, success)
					end
					trace("Doing double check of intermediate route between stations",station1, station2)
					params.intermediateRouteNodePos1 = nodePos1
					params.intermediateRouteNodePos2 = nodePos2 
					if routeBuilder.checkAndPrepareForRouteCombinationWithNode(station1, node2, station2, callbackThis, params) and 
						routeBuilder.checkAndPrepareForRouteCombinationWithNode(station2, node1, station1, callbackThis, params) then 
						return
					end 
				end
			end
			--[[if not intermediateEdges.isIntermediateRoute then
				-- could be optimised , e.g. choose best route option
				if #intermediateEdges.leftConnectedEdges>#intermediateEdges.rightConnectedEdges then 
					intermediateEdges.rightConnectedEdges = {}
				else 
					intermediateEdges.leftConnectedEdges = {}
				end
			end]]--
			local nodePair1
			local nodePair2
			local nodePos1 
			local nodePos2
			if intermediateEdges.isIntermediateRoute then 
				--local station1Pos = util.getStationPosition(station1)
				--local station2Pos = util.getStationPosition(station2)
				nodePair1 = evaluateBestJoinNodePair(getDeadEndNodesForStation(station1),  intermediateEdges.leftConnectedEdges, params, station2Pos,intermediateEdges.rightConnectedEdges) 
				nodePair2 = evaluateBestJoinNodePair(getDeadEndNodesForStation(station2),  routeBuilder.getFilteredRightConnectedEdges(nodePair1, intermediateEdges), params, station1Pos,intermediateEdges.leftConnectedEdges)
				trace("Intermediate route evaluation, nodePair1",nodePair1, " nodePair2",nodePair2)
				nodePos1 = nodePair1 and util.nodePos(nodePair1[2])
				nodePos2 = nodePair2 and util.nodePos(nodePair2[2])
				if not routeBuilder.validateIntermediateRoute(nodePair1, nodePair2) then  
					trace("intermediate route failed validation - cancelling")
					intermediateEdges.leftConnectedEdges = {}
					intermediateEdges.rightConnectedEdges = {}
					nodePair1 = nil 
					nodePair2 = nil
					nodePos1 = nil 
					nodePos2 = nil
				end
				if params.isAutoBuildMode then 
					params.buildGradeSeparatedTrackJunctions = true 
					trace("Setting buildGradeSeparatedTrackJunctions to true for intermedateRouteBuild")
				end		
				params.intermediateRouteNodePos1 = nodePos1
				params.intermediateRouteNodePos2 = nodePos2 				
			end
			trace("nodePair1 was ",nodePair1," nodePair2 was ",nodePair2)
			
			
			if #intermediateEdges.leftConnectedEdges>0 and (not params.station1SpurConnect or intermediateEdges.isIntermediateRoute) then
				trace("Found leftConnectedEdges, nodePair1 nil?",nodePair1==nil)
				local nodePair = nodePair1 and nodePair1 or getClosestAppropriateTrackNode(station1, intermediateEdges.leftConnectedEdges, station2Pos, params) 
				if nodePair then 
					local node = nodePair[2]
					local nodePos = nodePos1 or util.nodePos(node)
					station1Pos = nodePos
					--local nodePos1 = util.nodePos(nodePair[1])
					trace("node was ",node)

					local function callbackThis(res, success)	
						trace("calling back for station1 preparation, success was",success)
						util.clearCacheNode2SegMaps()
						if success then 
							routeBuilder.addWork(function()
								params.isDoubleTrack = true
								local leftNode = nodePair[1]
							
								local callBackToUse = intermediateEdges.isIntermediateRoute and intermediateRouteCallback or callback
								if leftNode and params.extensionsToTerminal and params.extensionsToTerminal[leftNode] then 
									trace("Detected leftNode",leftNode,"connected directly, calling back")
									callBackToUse({}, true )
									return 
								end 
								
								if not nodePair[1] then 
									trace("WARNING! tehre was no node in the nodePair attempting to get from dead end nodes in vicinity")
									leftNode = getDeadEndNodesInVicinity(nodePos1)									
								end
								local deadEndNodesLeft = { leftNode }--getDeadEndNodesInVicinity(nodePos1)--{ nodePair[1] } 
								local deadEndNodesRight = getDeadEndNodesInVicinity(nodePos)
								local nodepair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
								routeBuilder.buildCombiningTrackRoute(nodepair, params, callBackToUse )
								--routeBuilder.buildRoute(nodepair, params, intermediateEdges.isIntermediateRoute and intermediateRouteCallback or callback)
							end)
						end
						routeBuilder.standardCallback(res, success)
					end
					trace("About to check and prepare for route combination with node, station1=",station1,"station2=",station2)
					if routeBuilder.checkAndPrepareForRouteCombinationWithNode(station1, node, station2, callbackThis, params, intermediateEdges.isIntermediateRoute, nodePair[1]) and #intermediateEdges.rightConnectedEdges ==0 then
						return
					end
				end
			end
			
			if #intermediateEdges.rightConnectedEdges  > 0 and (not params.station2SpurConnect or intermediateEdges.isIntermediateRoute) then
				trace("Found rightConnectedEdges, nodePair2 nil?",nodePair2==nil)
				local nodePair = nodePair2 and nodePair2 or getClosestAppropriateTrackNode(station2, intermediateEdges.rightConnectedEdges, station1Pos, params) 
				if nodePair then 
					local node = nodePair[2]
					trace("node was ",node)
					local nodePos = nodePos2 or util.nodePos(node)
					--local nodePos1 = util.nodePos(nodePair[1])
					local function callbackThis(res, success)
						trace("calling back for station2 preparation, success was",success)
						util.clearCacheNode2SegMaps()
						if success then 
							routeBuilder.addWork(function()
								params.isDoubleTrack = true
								local leftNode = nodePair[1]
							
								local callBackToUse = intermediateEdges.isIntermediateRoute and intermediateRouteCallback or callback
								if leftNode and params.extensionsToTerminal and params.extensionsToTerminal[leftNode] then 
									trace("Detected leftNode",leftNode,"connected directly, calling back")
									callBackToUse({}, true )
									return 
								end 
								local deadEndNodesLeft = { nodePair[1] } -- getDeadEndNodesInVicinity(nodePos1)--{ nodePair[1] } 
								local deadEndNodesRight = getDeadEndNodesInVicinity(nodePos)
								local nodepair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
								routeBuilder.buildCombiningTrackRoute(nodepair, params, callBackToUse)
								--routeBuilder.buildRoute(nodepair, params, intermediateEdges.isIntermediateRoute and intermediateRouteCallback or callback)
							end)
						end
						routeBuilder.standardCallback(res, success)
					end
					if nodePos2 then 
						node = util.searchForNearestNode(nodePos2).id -- need to refresh in case this was replaced
					end 
					trace("About to check and prepare for route combination with node, station2=",station2,"station1=",station1)
					if routeBuilder.checkAndPrepareForRouteCombinationWithNode(station2, node, station1, callbackThis, params, intermediateEdges.isIntermediateRoute, nodePair[1]) then
						return
					end
				end
			end		
		end
		
	end -- end track sharing search
	
	
	local deadEndNodesLeft = getDeadEndNodesForStation(station1, params.station1SpurConnect, 350, params) 
	local deadEndNodesRight = getDeadEndNodesForStation(station2, params.station2SpurConnect, 350, params) 
	params.station1 =station1
	params.station2 = station2
	if pathFindingUtil.checkForRailPathBetweenStationFreeTerminals(station1, station2) and not params.isCircularRoute  then 
		trace("Ending early as the path was already available",station1, station2)
		callback({}, true)
		return
	end 
	local nodepair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight,params)
	trace("Falling through to building route between",nodepair[1],nodepair[2]," spur1 connect?",params.station1SpurConnect,"spur2 connect?",params.station2SpurConnect)
	 if trackSharingAllowed then 
 		routeBuilder.buildCombiningTrackRoute(nodepair, params, callback)
 	else 
		routeBuilder.buildRoute(nodepair, params, callback)
 	end
end

function routeBuilder.upgradeIndustryEdge(edgeId, targetType, targetTypeWidth, callback)
	trace("upgradeIndustryEdge: begin for ",edgeId,"targetType=",targetType)
	local entity = util.copyExistingEdge(edgeId, -1) 
	local testProposal = api.type.SimpleProposal.new()
	entity.streetEdge.streetType = targetType
	testProposal.streetProposal.edgesToAdd[1]=entity 
	testProposal.streetProposal.edgesToRemove[1]=edgeId
	local testData =  api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
	if #testData.errorState.messages==0 and not testData.errorState.critical then -- shortcut if can be built with no errors
		trace("Short cutting to direct upgrade of industry edge",edgeId)
		api.cmd.sendCommand(api.cmd.make.buildProposal(testProposal, util.initContext(), false),callback)
		return
	end 	

	local offsetRequired = (targetTypeWidth - util.getEdgeWidth(edgeId))/2
	local pMid = util.getEdgeMidPoint(edgeId)
	local industry = util.searchForFirstEntity(pMid, 200, "SIM_BUILDING")
	if not industry then 
		trace("WARNING! Unable to find industry")
		callback({},false) 
		return 
	end 
	trace("upgradeIndustryEdge: the industry was",industry.name,"near",pMid.x, pMid.y)
	local industryVector = util.v3fromArr(industry.position) - pMid 
	local edge = util.getEdge(edgeId)
	local angle = util.signedAngle(edge.tangent0, industryVector) -- to determine left or right handed ness
	local sign = angle < 0 and 1 or -1
	trace("upgradeIndustryEdge the angle was",math.deg(angle),"sign was",sign,"offsetRequired was",offsetRequired)
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent1)
	t0.z = 0
	t1.z = 0
	local t0perp = vec3.normalize(util.rotateXY(t0, sign*math.rad(90)))
	local t1perp = vec3.normalize(util.rotateXY(t1, sign*math.rad(90)))
	
	local p0 = offsetRequired*t0perp + util.nodePos(edge.node0)
	local p1 = offsetRequired*t1perp + util.nodePos(edge.node1)
	
	trace("upgradeIndustryEdge: determined new positions at ",p0.x,p0.y," and ",p1.x,p1.y)
	local newNode0 = util.newNodeWithPosition(p0, -1000)
	local newNode1 = util.newNodeWithPosition(p1, -1001)
	local nodesToAdd = { newNode0, newNode1 }
	local nodesToRemove = { edge.node0, edge.node1 }
	local edgesToAdd = {}
	local edgesToRemove = {}
	local replacedEdgesMap = {}
	local function getOrMakeReplacedEdge(otherEdgeId) 
		trace("Upgrade industry edge, otherEdgeId=",otherEdgeId,"edgeId=",edgeId)
		if not replacedEdgesMap[otherEdgeId] then 
			local newEntity = util.copyExistingEdge(otherEdgeId, -1-#edgesToAdd)
			if otherEdgeId == edgeId then 
				trace("setting the industry edge target type to ",targetType)
				newEntity.streetEdge.streetType = targetType
			elseif util.isIndustryEdge(otherEdgeId) then 
				trace("WARNING! Got otherEdgeId as industry edge but not the input edge:",otherEdgeId,edgeId)
			end 			
			table.insert(edgesToAdd, newEntity) 
			table.insert(edgesToRemove, otherEdgeId)
			replacedEdgesMap[otherEdgeId]  = newEntity
		end 
		return replacedEdgesMap[otherEdgeId]
	end 
	
	for i, node in pairs(nodesToRemove) do 
		local newNode = nodesToAdd[i]
		local segs = util.getSegmentsForNode(node)
		for	j, seg in pairs(segs) do
			local newEdge = getOrMakeReplacedEdge(seg)
			if newEdge.comp.node0 == node then 
				newEdge.comp.node0 = newNode.entity
			elseif newEdge.comp.node1 == node then 
				newEdge.comp.node1 = newNode.entity
			end 
		end  
	end 
	local function nodePos(node) 
		if node < 0 then 
			return util.v3(nodesToAdd[node+1002].comp.position)
		else 
			return util.nodePos(node)
		end 
	end 
	
	for i, edge in pairs(edgesToAdd) do 	
		local p0 = nodePos(edge.comp.node0)
		local p1 = nodePos(edge.comp.node1)
		local t0 = util.v3(edge.comp.tangent0)
		local t1 = util.v3(edge.comp.tangent1)
		local newLength = util.calculateTangentLength(p0, p1, t0, t1)
		util.setTangent(edge.comp.tangent0, newLength*vec3.normalize(t0))
		util.setTangent(edge.comp.tangent1, newLength*vec3.normalize(t1))
	end
	
	-- N.B. defer to proposalUtil as this will do extra checking, dead end nodes require replacement etc.
	--[[
	local newProposal = api.type.SimpleProposal.new()
	for i, edge in pairs(edgesToAdd) do 	
		newProposal.streetProposal.edgesToAdd[i]=edge
	end 
	for i, edge in pairs(edgesToRemove) do 	
		newProposal.streetProposal.edgesToRemove[i]=edge
	end 
	for i, node in pairs(nodesToAdd) do 	
		newProposal.streetProposal.nodesToAdd[i]=node
	end 
	for i, node in pairs(nodesToRemove) do 	
		newProposal.streetProposal.nodesToRemove[i]=node
	end --]]
 
	local newProposal =   proposalUtil.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	if util.tracelog then 
		debugPrint({industryEdgeUpgradeProposal=newProposal})
	end 
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),callback)
	trace("upgradeIndustryEdge: complete for ",edgeId)
end

function routeBuilder.tryRoadRouteForUpgrade(routeInfoFn, callback, params)  
	local routeInfo = routeInfoFn()
	trace("Begin road route upgrade, the street type was ",params.preferredCountryRoadType, " smoothingPasses was ",params.smoothingPasses," ignoreErrors?",params.ignoreErrors)
	local routeSections = {}
	local allEdgeIds = {}

	local currentSectionStreetCategory
	local currentRouteSection
	local currentSectionBackwards
	local currentSectionIsBridge = false
	local currentSectionIsTunnel = false
	local smoothingPasses = params.smoothingPasses
	local skipValidation = params.tramTrackType > 0 -- requires all sections to upgrade
	local ignoreIgnorableErrors = params.ignoreErrors 
	if not routeInfo then 
		trace("WARNING! no routeInfo found") 
		return false 
	end
	if routeInfo.hasOldStreetSections then 
		--smoothingPasses = 0 
		ignoreIgnorableErrors = true
		trace("tryRoadRouteForUpgrade: Setting skipValidation to true and no smoothing for removing old sections")
	end 
	if params.addBusLanes then 
		params.preferredCountryRoadType=params.preferredCountryRoadTypeWithBus
		params.preferredUrbanRoadType = params.preferredUrbanRoadTypeWithBus
	end 
	if not routeInfo.edges[routeInfo.firstFreeEdge] then 
		trace("Couoldnt access first free tech")
		return false 
	end
	local firstEdge = routeInfo.edges[routeInfo.firstFreeEdge].edge
	local preferredCountryStreetType = api.res.streetTypeRep.find(params.preferredCountryRoadType)
	local preferredCountryStreetWidth = util.getStreetWidth(preferredCountryStreetType)
	local preferredUrbanRoadType = api.res.streetTypeRep.find(params.preferredUrbanRoadType)
	local preferredUrbanStreetWidth = util.getStreetWidth(preferredUrbanRoadType)
	local lastEdgeType = 0 -- this type refers to bridge / tunnel
	local currentSectionIndustryEdge
	local previousEdge
	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do  
		local edgeId = routeInfo.edges[i].id
		
		local edge = routeInfo.edges[i].edge
		local streetCategory = util.getStreetTypeCategory(edgeId)
		if streetCategory == "urban" or streetCategory == "country" then 
			allEdgeIds[edgeId]=true
		end
		
		local backwards
		local needsNewRouteSection 
		if previousEdge then 
			needsNewRouteSection = previousEdge.node0 == edge.node0 or previousEdge.node1 == edge.node1
		else 
			needsNewRouteSection = true 
		end
		
		if needsNewRouteSection then 
			if i < routeInfo.lastFreeEdge then 
				--backwards = edge.node0 == routeInfo.edges[i+1].edge.node1 
				backwards = edge.node1~= routeInfo.edges[i+1].edge.node0 and edge.node1~= routeInfo.edges[i+1].edge.node1
			else 
				backwards = not currentSectionBackwards
			end
		else 
			backwards = previousEdge.node0 == edge.node1
		end
		local currentNode = backwards and edge.node0 or edge.node1
		local previousNode = backwards and edge.node1 or edge.node0
		
		local isBridgeSection = edge.type==1 or 
			previousEdge and previousEdge.type == 1 or
			i <  routeInfo.lastFreeEdge and routeInfo.edges[i+1].edge.type == 1 
		local isIndustryEdge = util.isIndustryEdge(edgeId)
		if isIndustryEdge then 
			if not params.alreadyAttemptedIndustryEdges then 
				params.alreadyAttemptedIndustryEdges = {}
			end 
			local edgeTypeTargetWidth = util.getStreetTypeCategory(edgeId) == "urban" and preferredUrbanStreetWidth or preferredCountryStreetWidth
			if edgeTypeTargetWidth > util.getEdgeWidth(edgeId) and not params.alreadyAttemptedIndustryEdges[edgeId] then 
				params.alreadyAttemptedIndustryEdges[edgeId]  = true
				local edgeTypeTarget = util.getStreetTypeCategory(edgeId) == "urban" and preferredUrbanStreetType or preferredCountryStreetType
				local function callbackThis(res, success) 
					trace("Attempt to upgrade the industry edge was",success)
					util.clearCacheNode2SegMaps()
					routeBuilder.addWork(function() routeBuilder.tryRoadRouteForUpgrade(routeInfoFn, callback, params)  end)
				end 
				trace("Attempting to preemptively upgrade industry edge",edgeId,"edgeTypeTarget=",edgeTypeTarget)
				routeBuilder.upgradeIndustryEdge(edgeId, edgeTypeTarget, edgeTypeTargetWidth, callbackThis)
				return 
			end
		end 
		local isTunnelSection = edge.type == 2
		
		if not (isBridgeSection and currentSectionIsBridge) -- keep bridge section together 
			and (
			currentSectionStreetCategory ~= streetCategory 
			or #util.getSegmentsForNode(previousNode) > 2
			or currentSectionBackwards ~= backwards
			or currentSectionIsBridge ~= isBridgeSection -- want to leave bridges frozen in place
			or currentSectionIndustryEdge ~= isIndustryEdge
			or currentSectionIsTunnel ~= isTunnelSection
			or needsNewRouteSection
			or util.searchForNearestNode(util.nodePos(previousNode), 20, util.isTrackNode)
			or util.searchForNearestNode(util.nodePos(currentNode), 20, util.isTrackNode)
			)
		then
			local startEndNode
			if previousEdge then 
				startEndNode = 
					edge.node0 == previousEdge.node0 and edge.node0 
				or  edge.node0 == previousEdge.node1 and edge.node0
				or	edge.node1 
			else 
				startEndNode = previousNode
			end
			
			table.insert(routeSections, { 
				edges={routeInfo.edges[i]} , 
				startNode = startEndNode,
				startNodePos = util.nodePos(startEndNode),
				streetCategory=streetCategory,
				backwards =backwards,
				isIndustryEdge = isIndustryEdge,
				isBridgeSection = isBridgeSection,
				bridgeSections = edge.type == 1 and 1 or 0
				} 
			)
			if currentRouteSection then 
				routeSections[currentRouteSection].endNode =   startEndNode
			end
			currentRouteSection = #routeSections
			trace("Inserting new route section, routeSecitions=",currentRouteSection, " start/end node is ", startEndNode)
		else 
			table.insert(routeSections[currentRouteSection].edges, routeInfo.edges[i])
			if edge.type == 1 then 
				routeSections[currentRouteSection].bridgeSections = routeSections[currentRouteSection].bridgeSections + 1
			end
			--routeSections[currentRouteSection].backwards = edge.node1 == previousNode
		end
		trace("backwards = ",backwards, " currentNode=",currentNode," previousNode=",previousNode, " isBridgeSection=",isBridgeSection, " isIndustryEdge=",isIndustryEdge, " edgeId=",edgeId)
		if streetCategory == "country" and (params.tramOnlyUpgrade or not isIndustryEdge) then 
			local theirStreetType = util.getStreetEdge(edgeId).streetType
			if preferredCountryStreetType ~= theirStreetType  and util.getEdgeWidth(edgeId) < preferredCountryStreetWidth or util.isOldEdge(edgeId) then
				if isTunnelSection or isBridgeSection or smoothingPasses <= 1 then 
					routeSections[currentRouteSection].needsUpgrade=true
				else 
					routeSections[currentRouteSection].needsSmoothing=true
				end
			end
		end
		if streetCategory == "urban" and (params.tramOnlyUpgrade or  not isIndustryEdge and not isBridgeSection) then 
			local preferredStreetType = preferredUrbanRoadType
			if preferredStreetType ~= util.getStreetEdge(edgeId).streetType
				and util.getEdgeWidth(edgeId) < preferredUrbanStreetWidth or util.isOldEdge(edgeId) then
				routeSections[currentRouteSection].needsUpgrade=true
			end
		end
		if params.tramTrackType > 0 then 
			routeSections[currentRouteSection].needsUpgrade=true
		end
		currentSectionStreetCategory  = streetCategory 
	 
		currentSectionBackwards = backwards
		currentSectionIndustryEdge = isIndustryEdge
		currentSectionIsBridge = isBridgeSection
		currentSectionIsTunnel = isTunnelSection
		 
		previousEdge = edge
		if i == routeInfo.lastFreeEdge then 
			routeSections[currentRouteSection].endNode = currentNode
		end
	end
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local replacedEdgesMap = {}
	local edgesNeedingReplacing = {}
	local oldToNewNodeMap = {}
	local replacedNodesMap = {}
	local newNodePosMap = {}
	
	local function newNodeWithPosition(p, entity) 
		newNodePosMap[entity]=p
		if entity < -1050 then 
			trace("Adding new nodeWithPosition at",entity)
			trace(debug.traceback())
		end 
		return util.newNodeWithPosition(p,entity)
	end 
	
	local function nodePos(node) 
		if node < 0 then 
			--[[if not newNodePosMap[node] then 
				--error("node "..tostring(node).." not in map!")
				return {
					x="unknown",
					y="unknown",
					z="unknown",
				
				}
			end ]]--
			return newNodePosMap[node]
		else 
			return util.nodePos(node)
		end 
	end 
	
	local ignorableErrors = { "Narrow angle", "Too much slope", "Bridge pillar collision"  }
	
	local function allIgnorableErrors(messages) 
		local countIgnorable = 0 
		for i, message in pairs(messages) do 
			if util.contains(ignorableErrors, message) then 
				countIgnorable = countIgnorable + 1
			end 
		end 
		
		return countIgnorable == #messages 
	end 

	local function isValid()
		local edgesToAddCopy = {} -- copy in case we rollback
		for i, edge in pairs(edgesToAdd) do 	
			table.insert(edgesToAddCopy, copySegmentAndEntity(edge, edge.entity)) -- cant use deepClone because of userdata 
		end 
		local newProposal = false 
		
		local errToUse = util.tracelog and routeBuilder.err or err
		xpcall(function() newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAddCopy, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) end, errToUse)
		if not newProposal then 
			trace("tryRoadRouteForUpgrade.isValid: no proposal build, aborting") 
			if util.tracelog then 
				debugPrint({newProposal=newProposal})
				local errorMsg = "Critical error upgrading road\n"
				local function nodePosFn(node) 
					local res = nodePos(node)
					if not res then 
						trace("No result found for",node,"atttempting to find")
						for i, nodeEntity in pairs( nodesToAdd) do 
							if nodeEntity.entity == node then 
								return nodeEntity.comp.position
							end 
						end 
					end 
					
					return res 
					
				end 
				local errorMsg = "Error upgrading road\n"
				for i , edge in pairs(edgesToAddCopy) do 
					local debugInfo = util.newEdgeToString(edge, nodePosFn)
					trace(debugInfo)
					errorMsg = errorMsg..debugInfo.."\n"
				end 
				--routeBuilder.addWork(function() error(errorMsg) end) -- to highlight in the uI 
			end 
			return false 
		end
		local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
		if testData.errorState.critical then
			if util.tracelog then 
				debugPrint(testData.collisionInfo)
				debugPrint(testData.errorState)
				debugPrint(newProposal)
			end
			trace("tryRoadRouteForUpgrade.isValid: Critical error seen in the test data")
			local shouldLog = util.tracelog and #newProposal.streetProposal.edgesToAdd > 1 
			if shouldLog then 
				for i, edge in pairs(newProposal.streetProposal.edgesToAdd) do 
					trace("Checking if should log single edge proposal")
					if edge.comp.node0 > 0 and #util.getTrackSegmentsForNode(edge.comp.node0)> 0 or edge.comp.node1 > 0 and  #util.getTrackSegmentsForNode(edge.comp.node1) > 0 then
						shouldLog = false
						trace("Suppressing logging due to track nodes")
						break
					end 
					if edge.comp.node0 > 0 and #util.getSegmentsForNode(edge.comp.node0)> 2 or edge.comp.node1 > 0 and  #util.getSegmentsForNode(edge.comp.node1) > 2 then
						shouldLog = false
						trace("Suppressing logging due to multiple nodes")
						break
					end
				end 
				
			end 
			
			if util.tracelog and shouldLog then 
				local errorMsg = "Critical error upgrading road\n"
				local function nodePosFn(node) 
					local res = nodePos(node)
					if not res then 
						trace("No result found for",node,"atttempting to find")
						for i, nodeEntity in pairs(newProposal.streetProposal.nodesToAdd) do 
							if nodeEntity.entity == node then 
								return nodeEntity.comp.position
							end 
						end 
					end 
					
					return res 
					
				end 
				
				for i , edge in pairs(newProposal.streetProposal.edgesToAdd) do 
					local debugInfo = util.newEdgeToString(edge, nodePosFn)
					trace(debugInfo)
					errorMsg = errorMsg..debugInfo.."\n"
				end 
				--routeBuilder.addWork(function() error(errorMsg) end) -- to highlight in the uI 
			end 
			return false 
		elseif #testData.errorState.messages > 0 and not (ignoreIgnorableErrors or params.tramOnlyUpgrade) and not allIgnorableErrors(testData.errorState.messages) then
			if util.tracelog then 
				debugPrint(testData.collisionInfo)
				debugPrint(testData.errorState)
			end
			trace("tryRoadRouteForUpgrade.isValid: Ignorable error seen in the test data")		
			return false
		end 
		return true
	end
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	

	
	local function getOrMakeReplacedEdge(edgeId)  
		if replacedEdgesMap[edgeId] then 
			local entity = replacedEdgesMap[edgeId]
			if oldToNewNodeMap[entity.comp.node0] then 
				entity.comp.node0 = oldToNewNodeMap[entity.comp.node0] 
			end
			if oldToNewNodeMap[entity.comp.node1] then 
				entity.comp.node1 = oldToNewNodeMap[entity.comp.node1]
			end
			return replacedEdgesMap[edgeId]
		else 
			local entity = util.copyExistingEdge(edgeId, nextEdgeId())
			table.insert(edgesToRemove, edgeId)
			table.insert(edgesToAdd, entity)
			trace("tryRoadRouteForUpgrade.getOrMakeReplacedEdge: replacing",edgeId," with ",entity.entity)
			replacedEdgesMap[edgeId]=entity
			if oldToNewNodeMap[entity.comp.node0] then 
				entity.comp.node0 = oldToNewNodeMap[entity.comp.node0] 
			end
			if oldToNewNodeMap[entity.comp.node1] then 
				entity.comp.node1 = oldToNewNodeMap[entity.comp.node1]
			end
			if entity.comp.type == 1  then 
				if string.find(api.res.bridgeTypeRep.getName(entity.comp.typeIndex),"stone") then 
					if isCementBridgeAvailable() then 
						entity.comp.typeIndex = api.res.bridgeTypeRep.find("cement.lua")
					elseif isIronBridgeAvailable() then 
						entity.comp.typeIndex = api.res.bridgeTypeRep.find("iron.lua")
					end 
				end 
			end 
			if entity.streetEdge.tramTrackType == 0 and  params.tramTrackType > 0 and #entity.comp.objects > 0  and not params.forTramConversion  then 
				trace("Moving bus stop for street")
				local otherEdge = util.searchForNearestEdge(util.getEdgeMidPoint(edgeId), 200, function(edgeId)
					if replacedEdgesMap[edgeId] or allEdgeIds[edgeId] then 
						return false 
					end
					local edge = util.getEdge(edgeId)
					return 
						#util.getStreetSegmentsForNode(edge.node0) >= 2
						and #util.getStreetSegmentsForNode(edge.node1) >= 2
						and #util.getTrackSegmentsForNode(edge.node0) == 0
						and #util.getTrackSegmentsForNode(edge.node1) == 0
						and #edge.objects == 0
				end)
				local entity2 = util.copyExistingEdge(otherEdge, nextEdgeId()) 
				replacedEdgesMap[otherEdge] = entity2
				local newEdgeObjs = {}
				for i, edgeObj in pairs(entity.comp.objects) do  
					trace("Removing and replacing ",edgeObj[1]," for entity ",entity.entity, " edge type was ",edgeObj[2], " original edge was ",otherEdge)
					table.insert(edgeObjectsToRemove, edgeObj[1])
					table.insert(edgeObjectsToAdd, util.copyEdgeObject(edgeObj, entity2.entity))
					table.insert(newEdgeObjs, {-#edgeObjectsToAdd , edgeObj[2]})
				end
				entity2.comp.objects = newEdgeObjs
				if util.tracelog then 
					debugPrint({entity2edgeObjects=entity2.comp.objects, edgeObjectsToAdd=edgeObjectsToAdd, edgeObjectsToRemove=edgeObjectsToRemove})
				end 
				table.insert(edgesToRemove, otherEdge)
				table.insert(edgesToAdd, entity2)
				entity.comp.objects = {}
			end  
			return entity
		end
	end
		local nextNodeId = -1000
	local function getNextNodeId() 
		nextNodeId = nextNodeId-1
		return nextNodeId
	end
	local function getOrMakeNewNode(n,p )	 
		if not oldToNewNodeMap[n] then 
			local newNode = util.copyExistingNode(n, getNextNodeId())
			table.insert(nodesToAdd, newNode)
			trace("tryRoadRouteForUpgrade.getOrMakeNewNode, added node",newNode.entity,"to replace",n)
			replacedNodesMap[n]=newNode 
			oldToNewNodeMap[n]=newNode.entity
			for i , seg in pairs(util.getSegmentsForNode(n)) do 
				local newEdge = getOrMakeReplacedEdge(seg)
				if newEdge.comp.node0 == n then 
					newEdge.comp.node0 = newNode.entity 
				elseif newEdge.comp.node1 == n then -- double check required as may have already replaced 
 					newEdge.comp.node1 = newNode.entity
				end  
			end 
		end 
		local newNode= replacedNodesMap[n]
		if p then 
			util.setPositionOnNode(newNode, p)
		end 
		newNodePosMap[newNode.entity]=util.v3(newNode.comp.position)
		return newNode
	end 
	local function initEntity(edgeId, makeCopy)
		local entity = getOrMakeReplacedEdge(edgeId)
		if makeCopy then 
			entity = util.copySegmentAndEntity(entity, nextEdgeId())
			entity.comp.objects = {}
			table.insert(edgesToAdd, entity) 
		end
		trace("Replacing ",edgeId," with",entity.entity)
		local streetCategory = util.getStreetTypeCategory(edgeId)
		local preferredStreetType
		if (streetCategory == "urban" or streetCategory == "country") and not params.tramOnlyUpgrade then 
			if streetCategory == "urban" then 
				preferredStreetType = preferredUrbanRoadType
			else 
				preferredStreetType = preferredCountryStreetType
			end 
			if util.getStreetWidth(preferredStreetType) < util.getStreetWidth(entity.streetEdge.streetType) then 
				preferredStreetType = entity.streetEdge.streetType -- don't downgrade
			end
		else 
			preferredStreetType = entity.streetEdge.streetType 
		end
		if util.isOldEdge(edgeId) and preferredStreetType == entity.streetEdge.streetType  then 
			preferredStreetType = util.getNewFromOldStreetType(preferredStreetType)
		end 
		entity.streetEdge.streetType = preferredStreetType
		if not params.tramOnlyUpgrade then 
			entity.streetEdge.hasBus = entity.streetEdge.hasBus or params.addBusLanes or false
		end
		entity.streetEdge.tramTrackType = math.max(entity.streetEdge.tramTrackType, params.tramTrackType)
		return entity
	end
	

	
	local alreadySeen = {}
	for i, routeSection in pairs(routeSections) do 
		if  routeSection.backwards then 
			trace("Attempting to correct  backwards routeSection at ", i,"startNode=",routeSection.startNode,"endNode=",routeSection.endNode)
			local reversed ={}
			for j = #routeSection.edges, 1, -1 do
				table.insert(reversed, routeSection.edges[j])
			end
			routeSection.edges = reversed
			local temp = routeSection.startNode
			routeSection.startNode = routeSection.endNode
			routeSection.startNodePos = util.nodePos(routeSection.startNode)
			routeSection.endNode = temp
			trace("After correction  startNode=",routeSection.startNode,"endNode=",routeSection.endNode)
		end
		if routeSection.needsSmoothing and #routeSection.edges==1 then 
			routeSection.needsSmoothing = false
			routeSection.needsUpgrade = true
		end
	end
	
	for i, routeSection in pairs(routeSections) do 
		if routeSection.isIndustryEdge and not params.tramOnlyUpgrade   then 
			trace("Inspecting industry edge at ",i)
			local preferredStreetType =  routeSection.streetCategory == "urban" and preferredUrbanRoadType or preferredCountryStreetType
			local streetWidth = util.getStreetWidth(preferredStreetType) 
			local needsUpgrade = false 
			if streetWidth > 16 and not params.skipIndustryRoadUpgrade  then 
				for j = 1, #routeSection.edges do  
					local edgeWidth = util.getEdgeWidth(routeSection.edges[j].id)
					trace("Upgrade industry edge, comparing existing width",edgeWidth,"to target",streetWidth)
					if edgeWidth < streetWidth then 
						needsUpgrade = true 
						trace("Determined needs upgrade")
						break
					end 
				end 
			end 
			
			if needsUpgrade then
				trace("Found large street near industry edge, upgrading at ",i)
				for j = 1, #routeSection.edges do  
					
					--preferredStreetType = util.smallCountryStreetType()
					local edgeId = routeSection.edges[j].id 
					local edge = routeSection.edges[j].edge
					local existingStreetType = util.getStreetEdge(edgeId).streetType
					local existingStreetWidth = util.getStreetWidth(existingStreetType)
					local perpTangent = util.getPerpendicularTangentAwayFromIndustry(edgeId)
					local offset = streetWidth  
					local perpOffset = (streetWidth - existingStreetWidth)/2
					trace("Setting up for edgeiD = ",edgeId, " offset= ",offset)
					local node0Pos = util.nodePos(edge.node0)
					local node1Pos = util.nodePos(edge.node1)
					local entity = initEntity(edgeId)
					if streetType ~= preferredStreetType then 
						if not oldToNewNodeMap[edge.node0] then 
							local newNodePos0 = node0Pos + perpOffset*vec3.normalize(perpTangent)
							--[[local newNode0 = newNodeWithPosition(newNodePos0, getNextNodeId()) 
								table.insert(nodesToAdd, newNode0)
							oldToNewNodeMap[edge.node0]=newNode0.entity 
							newNodePosMap[newNode0.entity]=newNodePos0--]]
							local newNode0 = getOrMakeNewNode(edge.node0, newNodePos0) 
						
							trace("industryEdge replacement: Replacing",edge.node0,"with",newNode0.entity)
						end
						if not oldToNewNodeMap[edge.node1] then 
							local newNodePos1 = node1Pos + perpOffset*vec3.normalize(perpTangent)
						--[[	local newNode1 = newNodeWithPosition(newNodePos1, getNextNodeId())  
							table.insert(nodesToAdd, newNode1)
							oldToNewNodeMap[edge.node1]=newNode1.entity
							newNodePosMap[newNode1.entity]=newNodePos1]]--
							local newNode1 = getOrMakeNewNode(edge.node1, newNodePos1) 
							trace("industryEdge replacement: Replacing",edge.node1,"with",newNode1.entity)
						end 
						
						
						entity.comp.node0 = oldToNewNodeMap[edge.node0]
						entity.comp.node1 = oldToNewNodeMap[edge.node1]
						--util.setTangentsForStraightEdgeBetweenPositions(entity, node0Pos, newNodePos1)
						if routeSections[i-1] then 
							if oldToNewNodeMap[routeSections[i-1].endNode]then
								routeSections[i-1].endNode=oldToNewNodeMap[routeSections[i-1].endNode]
								trace("industryEdge replacement: Set the end node at i-1",i-1,"to", routeSections[i-1].endNode)
							end
							if oldToNewNodeMap[routeSections[i-1].startNode]  then
								routeSections[i-1].startNode=oldToNewNodeMap[routeSections[i-1].startNode] 
								routeSections[i-1].startNodePos=newNodePosMap[routeSections[i-1].startNode]
								trace("industryEdge replacement: Set the start node at i-1",i-1,"to", routeSections[i-1].startNode)
							end
							 
						end
						if routeSections[i+1] then 
							if oldToNewNodeMap[routeSections[i+1].endNode] then
								routeSections[i+1].endNode=oldToNewNodeMap[routeSections[i+1].endNode]
								trace("industryEdge replacement: Set the end node at i+1",i+1,"to", routeSections[i+1].endNode)
							end
							if oldToNewNodeMap[routeSections[i+1].startNode]then
								routeSections[i+1].startNode=oldToNewNodeMap[routeSections[i+1].startNode]
								routeSections[i+1].startNodePos=newNodePosMap[routeSections[i+1].startNode]
								trace("industryEdge replacement: Set the start node at i+1",i+1,"to", routeSections[i+1].startNode)
							end
						 
						end
						for k, otherEdge in pairs(util.getSegmentsForNode(edge.node0)) do 
							if not allEdgeIds[otherEdge] then 
								getOrMakeReplacedEdge(otherEdge)  
								--util.setTangentsForStraightEdgeBetweenPositions(entity, node0Pos, newNodePos1) 
							end
						end
						for k, otherEdge in pairs(util.getSegmentsForNode(edge.node1)) do 
							if not allEdgeIds[otherEdge] then 
								getOrMakeReplacedEdge(otherEdge)  
								
								--util.setTangentsForStraightEdgeBetweenPositions(entity, node0Pos, newNodePos1)
							else 
								edgesNeedingReplacing[otherEdge]=true 
							end
						end
						skipValidation = true -- must now replace the other nodes 
						
					end
					--[[if util.distance(node0Pos, node1Pos) > 3*offset and streetType ~= preferredStreetType then
						local count = 0
						local valid
						repeat
							local newNodePos1 = node0Pos + offset* vec3.normalize(util.v3(edge.tangent0)) + perpOffset*vec3.normalize(perpTangent)
							local newNodePos2 = node1Pos - offset* vec3.normalize(util.v3(edge.tangent1)) + perpOffset*vec3.normalize(perpTangent)
							local newNode1 = newNodeWithPosition(newNodePos1, getNextNodeId()) 
							local newNode2 = newNodeWithPosition(newNodePos2, getNextNodeId()) 
							table.insert(nodesToAdd, newNode1)
							table.insert(nodesToAdd, newNode2)
							
							local entity = util.copyExistingEdge(edgeId, nextEdgeId())
							entity.streetEdge.streetType = preferredStreetType
							entity.streetEdge.hasBus = params.addBusLanes
							entity.comp.node1 = newNode1.entity
							util.setTangentsForStraightEdgeBetweenPositions(entity, node0Pos, newNodePos1)
							table.insert(edgesToAdd, entity)
							
							local entity2 = util.copyExistingEdge(edgeId, nextEdgeId())
							entity2.streetEdge.streetType = preferredStreetType
							entity2.streetEdge.hasBus = params.addBusLanes
							entity2.comp.node0 = newNode1.entity
							entity2.comp.node1 = newNode2.entity
							util.setTangentsForStraightEdgeBetweenPositions(entity2, newNodePos1, newNodePos2)
							table.insert(edgesToAdd, entity2)
							
							setTangent(entity.comp.tangent1, vec3.length(util.v3(entity.comp.tangent1))*vec3.normalize(util.v3(entity2.comp.tangent0)))
							
							local entity3 = util.copyExistingEdge(edgeId, nextEdgeId())
							entity3.streetEdge.streetType = preferredStreetType
							entity3.streetEdge.hasBus = params.addBusLanes
							entity3.comp.node0 = newNode2.entity 
							util.setTangentsForStraightEdgeBetweenPositions(entity3, newNodePos2, node1Pos )
							setTangent(entity3.comp.tangent0, vec3.length(util.v3(entity3.comp.tangent0))*vec3.normalize(util.v3(entity2.comp.tangent1)))
							table.insert(edgesToAdd, entity3)
							
							table.insert(edgesToRemove, edgeId)
							
							valid = isValid()
							if not valid then 
								table.remove(nodesToAdd)
								table.remove(nodesToAdd)
								table.remove(edgesToAdd)
								table.remove(edgesToAdd)
								table.remove(edgesToAdd)
								table.remove(edgesToRemove)
								perpOffset = perpOffset + 4
							end
							
						until valid or count > 10]]--
					end
					routeSection.alreadyUpgraded = true
				else 
					routeSection.needsUpgrade= not params.skipIndustryRoadUpgrade
				end 
				
			end
		
	end
	for i, routeSection in pairs(routeSections) do 
		if routeSection.isBridgeSection and not params.tramOnlyUpgrade then 
			
			local preferredStreetType =   routeSection.streetCategory == "urban" and preferredUrbanRoadType or preferredCountryStreetType
			--assert(#routeSection.edges==2+routeSection.bridgeSections, " #routeSection.edges="..#routeSection.edges.." routeSection.bridgeSections="..routeSection.bridgeSections)
			trace("Found bridge section, bridgeSections=",routeSection.bridgeSections," edges=",#routeSection.edges," is original bridge?",util.isOriginalBridge(routeSection.edges[2].id))
			if routeSection.bridgeSections == 1  and #routeSection.edges==3 and util.isOriginalBridge(routeSection.edges[2].id) and not params.disableBridgeRebuild then 
				local rampLeftId = routeSection.edges[1].id
				local rampLeft = routeSection.edges[1].edge
				local bridgeEdgeId = routeSection.edges[2].id
				local rampRightId = routeSection.edges[3].id
				local rampRight = routeSection.edges[3].edge
				local bridgeMidPos = util.getEdgeMidPoint(bridgeEdgeId)
				local bridgeOverWater = false
				if util.isUnderwater(bridgeMidPos) then 
					bridgeMidPos.z = math.max(bridgeMidPos.z, params.minimumWaterMeshClearance)
					bridgeOverWater = true
				end
				local existingStreetType = util.getStreetEdge(bridgeEdgeId).streetType
				local existingStreetWidth = util.getStreetWidth(existingStreetType)
				local newStreetWidth = util.getStreetWidth(preferredStreetType)
				local isWidening = newStreetWidth > existingStreetWidth
				local bridgeEdge = util.getEdge(bridgeEdgeId)
				local isLowBridge = util.nodePos(bridgeEdge.node0).z < 5 or util.nodePos(bridgeEdge.node1).z < 5
				trace("is bridgeOverWater?",bridgeOverWater,"isLowBridge?",isLowBridge," isWidening?",isWidening)
				if bridgeOverWater and isLowBridge and isWidening and not params.disableBridgeRebuild then 
					local newBridge1 = util.copyExistingEdge(bridgeEdgeId, nextEdgeId())
					table.insert(edgesToAdd, newBridge1)
					local newBridge2 = util.copyExistingEdge(bridgeEdgeId, nextEdgeId())
					table.insert(edgesToAdd, newBridge2)
					local newNode = newNodeWithPosition(bridgeMidPos, getNextNodeId())
					table.insert(nodesToAdd, newNode)
					newBridge1.comp.node1 = newNode.entity
					newBridge2.comp.node0 = newNode.entity
					
					
					trace("Upgrading bridge over water at section ",i, "added new node",newNode.entity)
					local newLeftNodePos = util.v3(util.nodePos(rampLeft.node0), true)
					newLeftNodePos.z = math.max(newLeftNodePos.z, 5+util.th(newLeftNodePos))
					local newLeftNode = newNodeWithPosition(newLeftNodePos, getNextNodeId())
					table.insert(nodesToAdd, newLeftNode)
					local newLeftNode = getOrMakeNewNode(rampLeft.node0, newLeftNodePos)
					
					local newRightNodePos = util.v3(util.nodePos(rampRight.node1), true)
					newRightNodePos.z = math.max(newRightNodePos.z, 5+util.th(newLeftNodePos))
					local newRightNode = newNodeWithPosition(newRightNodePos, getNextNodeId())
					table.insert(nodesToAdd, newRightNode)
					--local newRightNode = getOrMakeNewNode(rampRight.node1, newRightNodePos)
					
					
					newBridge1.comp.node0 = newLeftNode.entity
					
					 
					local bridge1tangent = bridgeMidPos  - util.nodePos(rampLeft.node0)
					setTangent(newBridge1.comp.tangent0, bridge1tangent)
					setTangent(newBridge1.comp.tangent1, bridge1tangent)
					newBridge1.comp.tangent1.z = 0 -- flatten the top
				 
					
					
					
					newBridge2.comp.node1 = newRightNode.entity 
					local bridge2tangent = util.nodePos(rampRight.node1) - bridgeMidPos  
					setTangent(newBridge2.comp.tangent0, bridge2tangent)
					setTangent(newBridge2.comp.tangent1, bridge2tangent)
					newBridge2.comp.tangent0.z = 0 
					
					table.insert(edgesToRemove, rampLeftId) 
					table.insert(edgesToRemove, rampRightId)
					for i, seg in pairs(util.getSegmentsForNode(rampLeft.node0)) do 
						if seg ~= rampLeftId then 
							local otherEntity = initEntity(seg)
							if otherEntity.comp.node0 == rampLeft.node0 then 
								otherEntity.comp.node0 = newLeftNode.entity
							elseif  otherEntity.comp.node1 == rampLeft.node0 then 
								otherEntity.comp.node1 = newLeftNode.entity
							else 
								trace("WARNING: No node found for entity",rampLeft.node0, seg)
							end 
						end
					end 
					for i, seg in pairs(util.getSegmentsForNode(rampRight.node1)) do 
						if seg ~= rampRightId then 
							local otherEntity = initEntity(seg)
							if otherEntity.comp.node0 == rampRight.node1 then 
								otherEntity.comp.node0 = newRightNode.entity
							elseif  otherEntity.comp.node1 == rampRight.node1 then 
								otherEntity.comp.node1 = newRightNode.entity
							else 
								trace("WARNING: No node found for entity",rampLeft.node0, seg)
							end 
						end
					end 
					if util.tracelog then 	
						debugPrint({rampRight = rampRight, rampLeft = rampLeft})
					end
					if routeSections[i-1] then 
						if routeSections[i-1].startNode == rampLeft.node0 then 
							routeSections[i-1].startNode=newLeftNode.entity
							routeSections[i-1].startNodePos = newLeftNodePos
							routeSections[i-1].startTangent = vec3.normalize(bridge1tangent)
							trace("Start node for section ",i-1," set to ",routeSections[i-1].startNode)
						elseif routeSections[i-1].endNode == rampLeft.node0 then
							routeSections[i-1].endNode=newLeftNode.entity
							routeSections[i-1].endTangent = vec3.normalize(bridge1tangent)
							trace("End node for section ",i-1," set to ",routeSections[i-1].endNode)
						end
						if routeSections[i-1].startNode == rampRight.node1  then 
							routeSections[i-1].startNode=newRightNode.entity
							routeSections[i-1].startNodePos = newRightNodePos
							routeSections[i-1].startTangent = vec3.normalize(bridge2tangent)
							trace("Start node for section ",i-1," set to ",routeSections[i-1].startNode)
						elseif routeSections[i-1].endNode == rampRight.node1 then
							routeSections[i-1].endNode=newRightNode.entity
							routeSections[i-1].endTangent = vec3.normalize(bridge2tangent)
							trace("End node for section ",i-1," set to ",routeSections[i-1].endNode)
						end
					end 
					if routeSections[i+1] then 
						if routeSections[i+1].endNode == rampRight.node1 then 
							routeSections[i+1].endNode=newRightNode.entity 
							routeSections[i+1].startTangent = vec3.normalize(bridge2tangent)
							trace("End node for section ",i+1," set to ",routeSections[i+1].endNode)
						elseif routeSections[i+1].startNode == rampRight.node1 then 
							routeSections[i+1].startNode=newRightNode.entity
							routeSections[i+1].startNodePos=newRightNodePos
							routeSections[i+1].startTangent = vec3.normalize(bridge2tangent)
							trace("Start node for section ",i+1," set to ",routeSections[i+1].startNode)
						end
						if routeSections[i+1].startNode == rampLeft.node0 then 
							routeSections[i+1].startNode=newLeftNode.entity
							routeSections[i+1].startNodePos = newLeftNodePos
							routeSections[i+1].startTangent = vec3.normalize(bridge1tangent)
							trace("Start node for section ",i-1," set to ",routeSections[i-1].startNode)
						elseif routeSections[i+1].endNode == rampLeft.node0 then
							routeSections[i+1].endNode=newLeftNode.entity
							routeSections[i+1].endTangent = vec3.normalize(bridge1tangent)
							trace("End node for section ",i-1," set to ",routeSections[i-1].endNode)
						end
					end
					
					routeSection.alreadyUpgraded = true
				else 
					--routeSection.needsUpgrade = true
				end
			else 
			--	routeSection.needsUpgrade = true
			end
			
			
		end
	end
	
	if util.tracelog then 
		debugPrint({routeSections=routeSections})
	end 

	
	for i, routeSection in pairs(routeSections) do 
		if routeSection.needsSmoothing and smoothingPasses >1 then 
			trace("Upgrading and smoothing route section ",i, " with ",smoothingPasses," smoothing passes for ",#routeSection.edges," edges")
			local streetCategory= routeSection.streetCategory
			local preferredStreetType=  routeSection.streetCategory == "urban" and preferredUrbanRoadType or preferredCountryStreetType
			local lastNode = routeSection.startNode
			--local lastNode = routeSection.edges[1].edge.node0
			if routeSection.startNode > 0 then 
				assert(routeSection.startNode == routeSection.edges[1].edge.node0)
			end
			local result = {}
			result[0]={p=routeSection.startNodePos  }
			local k = 0
			for j = 1, #routeSection.edges do   
				local edgeAndId = routeSection.edges[j]
				if not alreadySeen[edgeAndId.id] then
					k = k+1
					alreadySeen[edgeAndId.id]=true
					local edge = edgeAndId.edge
					--local node = edge.node0 == lastNode and edge.node1 or edge.node0
					--local isNode0 = edge.node0 == lastNode
					local node = edge.node1
					local t = util.v3(edge.tangent0)
					local t2 = util.v3(edge.tangent1)
					
					--local t = util.v3(edge.node0 == lastNode and edge.tangent1 or edge.tangent0)
					--local t2 = util.v3(edge.node0 ~= lastNode and edge.tangent1 or edge.tangent0)
				--	if   isNode0 then 
					--	t = -1*t
					--	t2 = -1*t2
					--end
					result[k] = { p = util.nodePos(node), t = t2,t2 = t2, edgeId=edgeAndId.id, node=node }
					--trace("j =",j)
					if k == 1 then 
						result[k-1].t2=t
					end
					lastNode = node
					
				end
			end
			if k > 2 then
				local errToUse = util.tracelog and routeBuilder.err or err
				if not xpcall(function() routeEvaluation.applySmoothing(result, k-1, smoothingPasses, params)end, errToUse) then 
					trace("Error detected attempting to smooth route at ",i)
					debugPrint({result=result, routeSection=routeSection})
					return false
				end
			end
			local lastNode = routeSection.startNode
			--local lastNode = routeSection.edges[1].edge.node0
			local nextT = result[0].t2
			if routeSection.startTangent then 
				nextT = vec3.length(nextT)*routeSection.startTangent
			end
			for j=1, k  do  
				local entity = initEntity(result[j].edgeId)  
				local node 
				if j < k then 
					local newNode = newNodeWithPosition(result[j].p, getNextNodeId())
					trace("tryRoadRouteForUpgrade: added new node",newNode.entity,"at",newNode.comp.position.x,newNode.comp.position.y,newNode.comp.position.z)
					table.insert(nodesToAdd, newNode)
					node = newNode.entity
				else
					if routeSection.endNode > 0 then 
						assert(routeSection.endNode == entity.comp.node1, " expected "..entity.comp.node1.." but was "..routeSection.endNode)
					end
					 node = routeSection.endNode
				end
					
					
					
 				 -- node = result[j].node
				--entity.comp.node0 = lastNode 
				--assert(entity.comp.node0==lastNode)
				--assert(entity.comp.node1==node)
				entity.comp.node0 = lastNode
				if node then 
					entity.comp.node1 = node
				end
			---	if j == k  then 
				--	assert(entity.comp.node1==routeSection.endNode, " end node1 was "..entity.comp.node1.." --routeSection.endNode="..---routeSection.endNode.." entity.comp.node0="..entity.comp.node0)
			--	end
					
				setTangent(entity.comp.tangent0,nextT)
				setTangent(entity.comp.tangent1, result[j].t)
				if j == k and routeSection.endTangent then
					setTangent(entity.comp.tangent1, vec3.length(result[j].t)*routeSection.endTangent)
				end
				nextT = result[j].t2
				 
				lastNode = node	
			end
			if not skipValidation and not isValid() then 
				for j=1, k  do
					trace("Rolling back route smoothing at ",i) 
					table.remove(edgesToAdd)
					table.remove(edgesToRemove)
					if j < k then 
						table.remove(nodesToAdd)
					end
				end
			end
			
		elseif not routeSection.alreadyUpgraded and routeSection.needsUpgrade then 
			trace("Upgrading route section at ",i)
			local upgraded = 0
			for j = 1, #routeSection.edges do   
				local edgeAndId = routeSection.edges[j] 
				if params.upgradeRoadsOnly or params.firstPass then 
					if #edgeAndId.edge.objects > 0 then 
						--trace("Skipping edge for ",j, " due to edge objects")
						--goto continue
					end 
				end 
				upgraded = upgraded +1
				local entity = initEntity(edgeAndId.id)
				 
					--[[ 
				if j == 1 then 
					if routeSection.startNode > 0 then
						if entity.comp.node0 ~= routeSection.startNode and entity.comp.node1 ~= routeSection.startNode and not util.tracelog then 
							return false 
						end
						assert(entity.comp.node0 == routeSection.startNode or entity.comp.node1 == routeSection.startNode, " expected "..entity.comp.node0.." but was "..routeSection.startNode)
					end
					if entity.comp.node1 == routeSection.startNode then 
						trace("WARNING! end node was already node1, attempting to correct")
						entity.comp.node1 = entity.comp.node0
					end 
					trace("Setting startNode in section ", i," to ",routeSection.startNode)
					entity.comp.node0 = routeSection.startNode
					if routeSection.startTangent then 
						setTangent(entity.comp.tangent0, vec3.length(util.v3(entity.comp.tangent0))*routeSection.startTangent)
						trace("Set tangent on ",entity.entity," to ",entity.comp.tangent0.x,entity.comp.tangent0.y,entity.comp.tangent0.z)
					end
				end 
				if j ==#routeSection.edges then 
					
					if routeSection.endNode  > 0 then
						if entity.comp.node0 ~= routeSection.endNode and entity.comp.node1 ~= routeSection.endNode and not util.tracelog then 
							return false 
						end
						assert(entity.comp.node1 == routeSection.endNode or entity.comp.node0 == routeSection.endNode, " expected "..entity.comp.node1.." but was "..routeSection.endNode)
					end
					if entity.comp.node0 == routeSection.endNode then 
						trace("WARNING! end node was already node0, attempting to correct")
						entity.comp.node0 = entity.comp.node1
					end 
					trace("Setting endNode in section ", i," to ",routeSection.endNode, "was",entity.comp.node1)
					entity.comp.node1 = routeSection.endNode
					if routeSection.endTangent then 
						setTangent(entity.comp.tangent1, vec3.length(util.v3(entity.comp.tangent1))*routeSection.endTangent)
						trace("Set tangent on ",entity.entity," to ",entity.comp.tangent1.x,entity.comp.tangent1.y,entity.comp.tangent1.z)
					end
				end				]]--
				
				  
					
					 
				::continue:: 
			end
			if not skipValidation and not isValid() then 
				trace("Rolling back route section upgrade at ",i)
				local failedEdges = {}
				for j = 1, upgraded do
					table.insert(failedEdges, { 
						edgeToAdd = table.remove(edgesToAdd),
						edgeToRemove = table.remove(edgesToRemove)
					})
				end
				if not routeSection.isBridgeSection then -- bridge sections need to be all or nothing to avoid funky effects where nodes widen/narrow 
					routeBuilder.addWork(function() 
						for __, failedEdge in pairs(failedEdges) do 
							if failedEdge.edgeToAdd.comp.node0 > 0 and failedEdge.edgeToAdd.comp.node1 > 0 and api.engine.entityExists(failedEdge.edgeToRemove) and util.getEdge(failedEdge.edgeToRemove) then 
								trace("Attempting individual upgrade for ",failedEdge.edgeToRemove)
								local proposal = api.type.SimpleProposal.new() 
								proposal.streetProposal.edgesToAdd[1] = failedEdge.edgeToAdd
								proposal.streetProposal.edgesToRemove[1] = failedEdge.edgeToRemove
								local build = api.cmd.make.buildProposal(proposal, util.initContext(), true)
								api.cmd.sendCommand(build, function(res, success)
									util.clearCacheNode2SegMaps()
									trace("Attempt of individula upgrade to edge",failedEdge.edgeToRemove," was ",success)
								end)
							end 
						end 
						util.clearCacheNode2SegMaps()
					end)
				end
			end
			
		end
	end
	if not isValid() then 
		debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
		return false
	end
	for edgeId, bool in pairs(edgesNeedingReplacing) do 
		if not replacedEdgesMap[edgeId] then 
			trace("Detected edge", edgeId , " was not replaced, attempting to correct")
			getOrMakeReplacedEdge(edgeId)  
		end
	end 
	if params.tramTrackType > 0 then 
		local oneWayStartNode
		for i = 1, #routeInfo.edges do 
			local edgeId = routeInfo.edges[i].id
			local isOneWayStreet = util.isOneWayStreet(edgeId)
			if isOneWayStreet then 
				trace("Found a one way street at ",i, " oneWayStartNode?",oneWayStartNode)
				if not oneWayStartNode then 
					local edge = routeInfo.edges[i].edge
					if i==#routeInfo.edges and util.getStreetTypeCategory(edgeId)=="entrance" then 
						local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
						local construction = util.getConstruction(constructionId)
						local nodes = {}
						for __, constructionEdgeId in pairs(construction.frozenEdges) do 
							if constructionEdgeId ~= edgeId then 
								local constructionEdge =  util.getEdge(constructionEdgeId)
								if not util.contains(construction.frozenNodes, constructionEdge.node1) then -- 2 way streets have node1 as the outer node
									local connectEdge = util.findEdgeConnectingNodes(constructionEdge.node1, edge.node0)
									trace("Looking for connectEdge was",connectEdge)
									if connectEdge and not util.isFrozenEdge(connectEdge) then 
										getOrMakeReplacedEdge(connectEdge).streetEdge.tramTrackType = params.tramTrackType 
									end
								end 
							end 
						end 
					else 
						oneWayStartNode = edge.node0
					end
				end 
			end 
			if oneWayStartNode and (not isOneWayStreet or i == #routeInfo.edges) then 
				local endNode = routeInfo.edges[i].edge.node1 
				trace("Attempting to find reverse route from ",oneWayStartNode," to ",endNode)
				local reverseRouteInfo = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(endNode, oneWayStartNode)
				trace("Adding the reverseRouteInfo for upgrade")
				for j = reverseRouteInfo.firstFreeEdge, reverseRouteInfo.lastFreeEdge do 
					local edgeId = reverseRouteInfo.edges[j].id
					trace("Upgrading edge",edgeId)
					getOrMakeReplacedEdge(edgeId).streetEdge.tramTrackType = params.tramTrackType 
				end 
				oneWayStartNode = nil
			end
		end 
	end 
	--[[if #edgesToAdd == 0 then 
		callback({}, true) 
		return true 
	end]]--
	
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) 
	--if util.tracelog then debugPrint(newProposal) end
	
	local testData =  api.engine.util.proposal.makeProposalData(newProposal , util.initContext())
	if testData.errorState.critical then 
		trace("WARNING! streetupgrade unable to build proposal")
		if util.tracelog then 
			debugPrint(newProposal) 
		end 
		return false 
	end
	
	trace("About to build command to build street upgrade")
	
	--local ignoreErrors = (params.ignoreErrors or params.tramOnlyUpgrade) and true or false -- need explicit boolean type
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace("Built proposal now to send command to build street upgrade")
	api.cmd.sendCommand(build, function(res, success) 
		trace("Attempt to build streetUpgrade was",success)
		if callback then 
			callback(res, success)
		end
	
	end)
	util.clearCacheNode2SegMaps()
	trace("Send command to build street upgrade")
	return true
end
local function checkForHighwayJunction(edge)
	 
	for i, node in pairs({edge.node0, edge.node1}) do
		local segs = util.getStreetSegmentsForNode(node)
		if #segs >= 3 then 
			for j, seg in pairs(segs) do 
				if util.getStreetTypeCategory(seg)~="highway" then 
					return true 
				end
 			end 
		end
	end
	return false 
end

function routeBuilder.checkForNearbyHighwayAtPosition(callback, params, p, p2)
	trace("begin checkForNearbyHighwayAtPosition")
	util.cacheNode2SegMapsIfNecessary() 
	local options = {}
	for edgeId, edge in pairs(util.searchForEntities(p, 750, "BASE_EDGE")) do 
		if not edge.track and util.getStreetTypeCategory(edgeId)=="highway" then 
			local edgeP = util.getEdgeMidPoint(edgeId)
			if checkForHighwayJunction(edge)  then 
				trace("checkForNearbyHighwayAtPosition: Found junction edge - aborting")
				 return
			elseif #util.getStreetSegmentsForNode(edge.node0)==2 and #util.getStreetSegmentsForNode(edge.node1)==2 and util.findParallelHighwayEdge(edgeId) and util.distance(p, util.getEdgeMidPoint(edgeId)) > 100 and not util.searchForFirstEntity(edgeP, 200, "SIM_BUILDING") then
				local terrainHeight = util.th(edgeP)
				local waterScore = terrainHeight < util.getWaterLevel() and 1 or 0 
				table.insert(options, {
					edgeId=edgeId, 
						scores={
							util.distance(p, edgeP),
							util.distance(p2, edgeP),
							waterScore
					}
				})
			end
		end
	end 
	if #options == 0 then 
		trace("checkForNearbyHighwayAtPosition: Found no options - aborting")
		return false
	end 
	if util.tracelog then debugPrint({highwayJunctionOptions=options}) end
	local sortedOptions = util.evaluateAndSortFromScores(options,{60,40,100})
	local edgeId = sortedOptions[1].edgeId
	
	local midPoint = util.getEdgeMidPoint(edgeId)
	local wrappedCallback = function(res, success)
		if success then
			routeBuilder.addWork(function()
				
				local function isHighwayDeadEndNode(node) 
					if type(node) == "number" then 
						node = { id = node }
					end 
					if #util.getStreetSegmentsForNode(node.id) == 1 and #util.getTrackSegmentsForNode(node.id) == 0 and not util.isFrozenNode(node.id) then 
						local edge = util.getEdge(util.getSegmentsForNode(node.id)[1])
						local otherNode = node.id == edge.node0 and edge.node1 or edge.node0 
						if #util.getStreetSegmentsForNode(otherNode) == 4 then 
							local highwayCount = 0
							for i, seg in pairs(util.getStreetSegmentsForNode(otherNode)) do 
								if util.getStreetTypeCategory(seg) == "highway" then 
									highwayCount = highwayCount + 1
								end 
							end 
							return highwayCount == 2
						end 
					end 
					return false 
				end 
				
				local roadNode = util.searchForNearestNode(p, 100, function(node) return #util.getStreetSegmentsForNode(node.id) == 1 and #util.getTrackSegmentsForNode(node.id) == 0 and not util.isFrozenNode(node.id) and not isHighwayDeadEndNode(node)  end)
				if not roadNode then 
					roadNode = util.searchForNearestNode(p, 200, function(node) return #util.getStreetSegmentsForNode(node.id) > 0 and  #util.getStreetSegmentsForNode(node.id) < 4 and #util.getTrackSegmentsForNode(node.id) == 0 and not util.isFrozenNode(node.id)  and not isHighwayDeadEndNode(node) end)
				end
				if not roadNode then 
					trace("checkForNearbyHighwayAtPosition as could not find roadNode") 
					callback(res, true)
					return		
				end
				local otherNodes = util.searchForDeadEndNodes(midPoint, 250, false, isHighwayDeadEndNode)
				if #otherNodes == 0 or not roadNode then
					trace("checkForNearbyHighwayAtPosition as could not find roadNode or other node") 
					callback(res, true)
					return					
				end
				local params = util.shallowClone(params)
				params.isHighway = false
				params.isDoubleTrack = false
				params.isHighwayConnect = true
				local nodePair = findShortestDistanceNodePair({roadNode.id}, otherNodes, params)
				trace("The roadNode was ",roadNode," the number of other nodes was ",#otherNodes," nodePair was ",nodePair)
				routeBuilder.buildRoute(routeEvaluation.evaluateRoadRouteOptions(nodePair, nil, params), params, callback)
			end)
		else 
			callback(res, true)-- pass back true because this should not block the building of the next stage
		end
	end 
	params = util.shallowClone(params)
	params.ignoreErrors = false 
	routeBuilder.buildHighwayJunction(edgeId, params, wrappedCallback, existingRoadId, crossingPoint, sortedOptions)
	return true
end

function routeBuilder.checkForNearbyHighway(callback, params, routeFn, stations) 
	local p1
	local p2
	if stations then 
		p1 = util.getStationPosition(stations[1])
		p2 = util.getStationPosition(stations[2])
	else 
		local routeInfo = routeFn()
		if not routeInfo then 
			trace("WARNING! No routeInfo found in checkForNearbyHighway")
			return
		end 
		p1 = util.getEdgeMidPoint(routeInfo.edges[1].id)
		p2 =  util.getEdgeMidPoint(routeInfo.edges[#routeInfo.edges].id) 
	end 
	local found = routeBuilder.checkForNearbyHighwayAtPosition(callback, params, p1, p2)
	found = routeBuilder.checkForNearbyHighwayAtPosition(callback, params, p2, p1) or found 
	return found
end 
function routeBuilder.checkRoadLineForUpgrade(callback, params, lineId)
	local line = util.getLine(lineId)
	for i = 1, #line.stops do
		local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
		local stop = line.stops[i]
		local priorStation = util.stationFromStop(priorStop)
		local station = util.stationFromStop(stop)
		routeBuilder.constructionUtil.checkStationForUpgrades(priorStation, params)
		routeBuilder.constructionUtil.checkStationForUpgrades(station, params)
		routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgrade(callback, params, 
			function() 
				return pathFindingUtil.getRoadRouteInfoBetweenStations(priorStation, station) 
			end,
			{priorStation, station})
		end) 
		
		if #line.stops ==2 then 
			break
		end 
			
	end
end 
function routeBuilder.checkRoadRouteForUpgrade(callback, params, routeFn, stations) 
	trace("checkRoadRouteForUpgrade: Begin checking route for upgrade, tramTrackType?",params.tramTrackType)
	util.lazyCacheNode2SegMaps()
	local callbackHway = function(res, success) 
		routeBuilder.addDelayedWork(function()
				params.alreadyCheckedForHighway = true
				routeBuilder.checkRoadRouteForUpgrade(callback, params, routeFn, stations)
			end)
		 
	end 
	if not params.alreadyCheckedForHighway and params.isCargo and util.year() > 1925 and routeBuilder.checkForNearbyHighway(callbackHway, params, routeFn, stations)  then 
		return 
	end
	local route = routeFn() 
	if route and route.routeLength > 1000 and not params.disableShortcuts then 
		local nodePair = routeEvaluation.checkRoadRouteForShortCuts(route, params, stations)
		if nodePair then
			local wrappedCallback = function(res, success) 
				trace("Attempt to build route was ",success)
				if not success then 
					params.disableShortcuts = true 
				end
				-- actually doesn't matter if it fails, proceed anyway
				routeBuilder.addWork(function()  routeBuilder.checkRoadRouteForUpgrade(callback, params, routeFn, stations) end)
			end
			params = util.shallowClone(params)
			params.maxBuildDist = 1.5*util.distBetweenNodes(nodePair[1],nodePair[2])
			params.isShortCut = true 
			params.isDoubleTrack = false 
			routeBuilder.buildRoute(nodePair, params, wrappedCallback)
			params.isShortCut = false
			return
		end
	end
	
	routeBuilder.checkRoadForUpgradeOnly(routeFn, callback,  params  ) 
	
end 

function routeBuilder.checkRoadForUpgradeOnly(routeFn, callback,  params ) 
	trace("Begin checkRoadForUpgradeOnly")
	local success = false
	if params.tramTrackType > 0 and params.buildBusLanesWithTramLines then 
		params.setAddBusLanes(true)
		--[[params.addBusLanes = true 
		
		if util.getNumberOfStreetLanes(params.preferredUrbanRoadType) < 6 then 
			params.preferredUrbanRoadType =  "standard/town_large_new.lua" 
			trace("Set the preferredUrbanRoadType to ",params.preferredUrbanRoadType)
		end ]]
	end 
	local originalPreferredCountryRoadType = params.preferredCountryRoadType
	if util.getStreetWidth(params.preferredCountryRoadType) > 16 then 
		params.preferredCountryRoadType = util.year() >= 1925 and "standard/country_medium_new.lua" or "standard/country_medium_old.lua"
		trace("Doing initial upgrade with ",params.preferredCountryRoadType, " then ",originalPreferredCountryRoadType)
		params.firstPass = true
	end 
	util.cacheNode2SegMaps()
	if not routeFn() then 
		trace("WARNING! no route info found, aborting")
		if callback then 
			callback({}, false)
		end
		return 
	end 
	if params.tramTrackType > 0 then 
		trace("Attempting tram only upgrade") 
		local wasTramOnlyUpgrade = params.tramOnlyUpgrade
		params.tramOnlyUpgrade = true 
		success= routeBuilder.tryRoadRouteForUpgrade(routeFn, callback, params) 
		if success and wasTramOnlyUpgrade then 
			return 
		end 
		params.tramOnlyUpgrade = false 
	end 
	--params.ignoreErrors = true
	for i = 10, 0, -1 do 
		params.smoothingPasses = i 
		trace("Begin tryRoadRouteForUpgrade loop:",i,"params.ignoreErrors=",params.ignoreErrors)
		success = routeBuilder.tryRoadRouteForUpgrade(routeFn , callback, params)   
		if success then 
			if originalPreferredCountryRoadType ~= params.preferredCountryRoadType then 
				util.cacheNode2SegMaps()
				params.firstPass =  false
				params.preferredCountryRoadType = originalPreferredCountryRoadType
				success = routeBuilder.tryRoadRouteForUpgrade(routeFn , callback, params)   
			end 
		end
		if success then 
			break 
		end
		params.skipIndustryRoadUpgrade = true
		params.disableBridgeRebuild=true
		if i < 5 then 
			params.useHermiteSmoothing=false
		end
	end
	if not success and params.tramTrackType > 0 then 
		trace("Attempting tram only upgrade") 
		params.tramOnlyUpgrade = true 
		success= routeBuilder.tryRoadRouteForUpgrade(routeFn , callback, params)  
		if success then 
			local newParams = util.deepClone(params) 
			newParams.tramTrackType = 0
			newParams.tramOnlyUpgrade = false 
			routeBuilder.addWork(function() routeBuilder.checkRoadForUpgradeOnly(routeFn, routeBuilder.standardCallback, newParams )end ) -- try to upgrade the remianing route
		end
		
	end
	
	if not success then 
		if callback then 
			callback({}, false)
		end
	end
	util.clearCacheNode2SegMaps()
end

function routeBuilder.checkRoadRouteForUpgradeBetweenNodes(node1, node2, params) 
	trace("Checking for upgrades between nodes ",station, node)
	
	 
	routeBuilder.checkRoadRouteForUpgrade(routeBuilder.standardCallback, params, function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node1, node2)) end) 
end

function routeBuilder.checkRoadRouteForUpgradeBetweenStationAndNode(station, node, params, nodePos)
	trace("Checking for upgrades between nodes ",station, node)
	
	 
	routeBuilder.checkRoadRouteForUpgrade(routeBuilder.standardCallback, params, function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenStationAndNode(station, node, nodePos)) end) 
end

function routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callback, params) 
	for i = 2, #stations do
		routeBuilder.checkRoadRouteForUpgrade(callback, params, function() return pathFindingUtil.getRoadRouteInfoBetweenStations(stations[i-1], stations[i]) end, stations) 
	end
end

local function checkForShortRoadRoute(station, callback, params, leftNodes, rightNodes,nodePair)
	local distance = util.distBetweenNodes(nodePair[1],nodePair[2]) 
	trace("Checking for short road road, distance was",distance)
	
	if distance < 20 then 
		local nodePos1 = util.nodePos(nodePair[1])
		local nodePos2 = util.nodePos(nodePair[2])
		trace("Very short route detected, attempting dummyUpgrade")
		if util.doDummyUpgrade(station) then 
			util.clearCacheNode2SegMaps()
			local node1 = util.getNodeClosestToPosition(nodePos1)
			local node2 = util.getNodeClosestToPosition(nodePos2)
			local connected = #pathFindingUtil.findRoadPathBetweenNodes(node1, node2) > 0
			trace("Dummy upgrade succeeded, is connected?",connected)
			if connected then
				callback({}, true)
				return true 
			end
			leftNodes = util.getAllFreeNodesForStation(station) -- reset the station nodes
		else 
			trace("attempt at dummy upgrade failed")
		end		
	end 
	if distance < 100 then 
		if routeBuilder.tryBuildRoute(nodePair, params, callback) then 
			return true 
		end 
		trace("Failed to build short route, attempting with alternative node pairs")
		for i, leftNode in pairs(leftNodes) do 
			for j, rightNode in pairs(rightNodes) do 
				trace("short route attempt at i,j=",i,j,"connecting",leftNode,rightNode)
				if routeBuilder.tryBuildRoute({leftNode, rightNode}, params, callback) then 
					return true 
				end
			end 
		end  
	end 
	return false
end

function routeBuilder.buildRoadRouteBetweenStations(stations, callback, params,result, hasEntranceB, index)
	trace("Begin buildRoadRouteBetweenStations: stations:",stations[1],stations[2])
	util.lazyCacheNode2SegMaps()
	local nodePair
	if params.isCargo then 
		if result.needsTranshipment1 and index ==1  then
			local leftNodes = util.getAllFreeNodesForStation(stations[1])
			local otherPos = { position = util.v3ToArr(util.nodePos(leftNodes[1])) }
			local rightNodes = { connectEval.getBestNodeForIndusty(result.industry1, otherPos, hasEntranceB[1]) }
			if leftNodes[2] then 
				table.insert(rightNodes, connectEval.getBestNodeForIndusty(result.industry2, { position = util.v3ToArr(util.nodePos(leftNodes[2])) }, hasEntranceB[2]))
			end 
			nodePair = util.findShortestDistanceNodePair(leftNodes, rightNodes)
			debugPrint({index=index, leftNodes=leftNodes, rightNodes=rightNodes, nodePair=nodePair})
			params.alreadyCheckedForHighway = true -- disable creating highway connections
			if checkForShortRoadRoute(stations[1], callback, params, leftNodes, rightNodes,nodePair) then 
				return
			end 
		elseif result.needsTranshipment2 and index ==2  then
			--local leftNodes = util.getAllFreeNodesForStation(result.industry2.type=="TOWN" and stations[1] or stations[2])
			--local otherPos = { position = util.v3ToArr(util.getStationPosition(stations[1])) }
			--local rightNodes = { connectEval.getBestNodeForIndusty(result.industry2, otherPos, hasEntranceB[2]) }
			local leftNodes = util.getAllFreeNodesForStation(stations[1])
			local otherPos = { position = util.v3ToArr(util.nodePos(leftNodes[1])) }
			local rightNodes = { connectEval.getBestNodeForIndusty(result.industry2, otherPos, hasEntranceB[2]) }
			if leftNodes[2] then 
				table.insert(rightNodes, connectEval.getBestNodeForIndusty(result.industry2, { position = util.v3ToArr(util.nodePos(leftNodes[2])) }, hasEntranceB[2]))
			end 
			nodePair = util.findShortestDistanceNodePair(leftNodes, rightNodes)
			if util.tracelog then 
				debugPrint({index=index, leftNodes=leftNodes, rightNodes=rightNodes, nodePair=nodePair})
			end 
			params.alreadyCheckedForHighway = true 
			if checkForShortRoadRoute(stations[1], callback, params, leftNodes, rightNodes, nodePair) then 
				return
			end 
		else  
			nodePair = connectEval.findNodePairForResult(result, hasEntranceB, stations)
		end
	else 
		local town1 =  api.engine.system.stationSystem.getStation2TownMap()[stations[1]]
		local town2 =  api.engine.system.stationSystem.getStation2TownMap()[stations[2]]
		nodePair = { connectEval.findBestConnectionNodeForTown(town1, town2), connectEval.findBestConnectionNodeForTown(town2, town1)}
	end
	local routeFn = function() return pathFindingUtil.getRoadRouteInfoBetweenStations(stations[1], stations[2]) end
	local function wrappedCallback(res, success) 
		params.alreadyCheckedForHighway = true
		if success then
			routeBuilder.addDelayedWork(function() 
				local routeInfo = routeFn()
				trace("after construction of the highway the routeInfo was ",routeInfo)
				if routeInfo then 
					routeBuilder.checkRoadRouteForUpgrade(callback, params, routeFn, stations) 
				else
					routeBuilder.buildRoadRouteBetweenStations(stations, callback, params,result, hasEntranceB)
				end
				
			end)
		else
			callback(res, success)
		end
	end
	if not params.alreadyCheckedForHighway and routeBuilder.checkForNearbyHighway(wrappedCallback, params, routeFn, stations) then
		return 
	end

	local newNodePair = routeEvaluation.evaluateRoadRouteOptions(nodePair, stations, params)
	local nodePos1 = util.nodePos(newNodePair[1])
	local nodePos2 = util.nodePos(newNodePair[2])
	local function wrappedCallback(res, success) 
		if success then 
			local usedNewPair = false 
			if nodePair[1]~=newNodePair[1] then 
				usedNewPair =  true 
				routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenStationAndNode(stations[1], newNodePair[1], params, nodePos1) end)
			end
			if nodePair[2]~=newNodePair[2] then 
				usedNewPair = true 
				routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenStationAndNode(stations[2], newNodePair[2], params, nodePos2) end)
			end
			if usedNewPair then 
				routeBuilder.addDelayedWork(function() routeBuilder.checkRoadRouteForUpgrade(routeBuilder.standardCallback, params, routeFn, stations) end)
			end 
		end
		callback(res, success)
	end
	if newNodePair[1] == newNodePair[2] then 
		trace("new node pair had the same node, skipping routebuild")
		wrappedCallback({}, true)
	else 	
		if params.isDoubleTrack and not params.isHighway then 
			params = util.shallowClone(params) 
			params.isDoubleTrack = false 
		end 
		routeBuilder.buildRoute(newNodePair, params, wrappedCallback)
	end
end

function routeBuilder.buildHighway(town1, town2, callback, params)
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	  
	if pathFindingUtil.areTownsConnectedWithHighway(town1, town2)  then 
		trace("Aborting build highway between ",town1.name,town2.name,"as route was already found")
		if callback then 
			callback({}, true)
		end 
		return
	end 	
	
	
	local town1SearchPos = util.v3fromArr(town1.position)
	local town2SearchPos = util.v3fromArr(town2.position)
	if params.searchMap then 
		if params.searchMap[town1.id] then 
			town1SearchPos = params.searchMap[town1.id]
			trace("Overriding the town1 search map to ",town1SearchPos.x, town1SearchPos.y)
		end
		if params.searchMap[town2.id] then 
			town2SearchPos = params.searchMap[town2.id]
			trace("Overriding the town2 search map to ",town2SearchPos.x, town2SearchPos.y)
		end
	end
	local vecBetweenTowns = town2SearchPos-town1SearchPos
	local distBetweenTowns = vec3.length(vecBetweenTowns)
    local searchRadius = math.min(750, distBetweenTowns/2.1)
	params.setForHighway()
	params.isDoubleTrack = true
	params.routeDeviationPerSegment = 30
	params.edgeWidth = 2*util.getStreetWidth(params.preferredHighwayRoadType)+params.highwayMedianSize
	params.maxGradient = paramHelper.getParams().maxGradientHighway
	params.routeScoreWeighting = util.deepClone(paramHelper.getParams().routeScoreWeighting) -- reset to standard track route scores
	local function getFilterFn(town)
		return function(node) 
			local townNode = util.searchForNearestNode(town.position, 150, function(node) return #util.getTrackSegmentsForNode(node.id)==0 end).id
			local maxDist = 3 * util.distBetweenNodes(node, townNode)+1000
			local canAccept=  #pathFindingUtil.findRoadPathBetweenNodes(townNode, node, maxDist) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(node, townNode, maxDist) > 0
			trace("buildHighway: Inspecting node",node," canAccept?",canAccept)
			return canAccept
		end
	end
	local deadEndNodesLeft = util.searchForDeadEndHighwayNodes(town1SearchPos, searchRadius, getFilterFn(town1)) 
	local deadEndNodesRight = util.searchForDeadEndHighwayNodes(town2SearchPos, searchRadius,getFilterFn(town2)) 
	if #deadEndNodesLeft == 0 then 
		
		deadEndNodesLeft = util.searchForDeadEndHighwayNodes(town1SearchPos, 1.5*searchRadius) 
		trace("WARNING! No dead end left nodes found for",town1.name, " after expanding search raduis have ",#deadEndNodesLeft)
	end 
	if #deadEndNodesRight == 0 then  
		deadEndNodesRight = util.searchForDeadEndHighwayNodes(town2SearchPos, 1.5*searchRadius ) 
		trace("WARNING! No dead end right nodes found for",town2.name, " after expanding search raduis have ",#deadEndNodesRight)
		if #deadEndNodesRight == 0 then 
			trace("Attempting to reset")
			town2SearchPos = util.v3fromArr(town2.position)
			deadEndNodesRight = util.searchForDeadEndHighwayNodes(town2SearchPos, 1.5*searchRadius ) 
		end 
	end 
	
	local midPoint = town1SearchPos+0.5*vecBetweenTowns
	local midSearchRadius = math.max(1000,  distBetweenTowns/2.1)
	
	local function notInLeftOrRight(node) 
		return not util.contains(deadEndNodesLeft, node) and not util.contains(deadEndNodesRight, node)
	end
	local deadEndNodesMid = util.searchForDeadEndHighwayNodes(midPoint, midSearchRadius, notInLeftOrRight) 
	if #deadEndNodesMid >=4 then 
		local trialLeftNodePair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesMid, params)	
		local trialRightNodePair = findShortestDistanceNodePair(deadEndNodesMid, deadEndNodesRight, params)	
		trace("Inspecting possible mid point node route")
		if util.tracelog then debugPrint({trialLeftNodePair=trialLeftNodePair, trialRightNodePair=trialRightNodePair, deadEndNodesLeft=deadEndNodesLeft, deadEndNodesRight=deadEndNodesRight}) end
		if pathFindingUtil.validateHighwayPathFromNodes(trialLeftNodePair[2], trialRightNodePair[1]) then 
			trace("DID Find path using mid point nodes")
			local count =0 
			local wrappedCallback = function(res, success)
				if success then 
					count = count+1 
					if count == 2 then 	
						callback(res, success)
					end
				else 
					callback(res, success)
				end 
			end 
			routeBuilder.addWork(function() routeBuilder.buildRoute(trialLeftNodePair, params, wrappedCallback) end)
			routeBuilder.addWork(function() routeBuilder.buildRoute(trialRightNodePair, params, wrappedCallback) end)
			return
		else	 
			trace("Unable to find path using mid point nodes")
		end 
	end 
	
	
	trace("Building highway, found ",#deadEndNodesLeft, " and ", #deadEndNodesRight)
	if #deadEndNodesLeft == 0 or #deadEndNodesRight == 0 then 
		trace("WARNING! Unable to build no nodes found")
		callback({},false)
		return
	end 
	local nodePair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
	
	routeBuilder.buildRoute(nodePair, params, function(res, success) 
		callback(res, success)
		if success then 
			xpcall(function()
				--debugPrint({res=res})
				local towns = {}
				for i, node in pairs(res.proposal.proposal.addedNodes) do 
					local p = util.v3(node.comp.position)
					local town = util.searchForFirstEntity(p, 750, "TOWN")
					if town and town.id~=town1.id and town.id~=town2.id then 
						local townP = util.v3fromArr(town.position)
						if towns[town.id] then 
							if util.distance(p,townP)<util.distance(towns[town.id].p, townP) then --take closest approach
								towns[town.id].p = p
							end 
						else 
							towns[town.id]={town = town, p=p, townP=townP}
						end 
					end 
				end 
				--if util.tracelog then debugPrint({connectTowns=towns}) end 
				for townId, detail in pairs(towns) do
					local p = detail.p 
					local town = detail.town
					trace("Adding work to check for town checkForNearbyHighwayAtPosition",town.name," original towns were",town1.name,town2.name)
					routeBuilder.addWork(function() routeBuilder.checkForNearbyHighwayAtPosition(routeBuilder.standardCallback, params, detail.townP, p ) end)
				end 
			end,err)
		end 
	
	end)
end
routeBuilder.findShortestDistanceNodePair = findShortestDistanceNodePair

function routeBuilder.buildOrUpgradeRoadRouteBetweenTowns(town1, town2, callback, params)
	local nodePair = { connectEval.findBestConnectionNodeForTown(town1, town2), connectEval.findBestConnectionNodeForTown(town2, town1)}
	local newNodePair = routeEvaluation.evaluateRoadRouteOptions(nodePair, nil, params)
	local function wrappedCallback(res, success) 
	if success then 
		if nodePair[1]~=newNodePair[1] then 
			routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenNodes(nodePair[1], newNodePair[1], params) end)
		end
		if nodePair[2]~=newNodePair[2] then 
			routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenNodes(nodePair[2], newNodePair[2], params) end)
		end
	
	end
	callback(res, success)
	end
	if newNodePair[1] == newNodePair[2] then 
		trace("new node pair had the same node, skipping routebuild")
		wrappedCallback({}, true)
	else 	
		routeBuilder.buildRoute(newNodePair, params, wrappedCallback)
	end
end
function routeBuilder.buildOrUpgradeForBusRoute(station1, station2, callback,params)
	--local params = paramHelper.getDefaultRouteBuildingParams(false, false)
	local result = pathFindingUtil.findRoadPathStations(station1, station2)
	trace("routeBuilder.buildOrUpgradeForBusRoute, got ",#result," for path between",station1,station2)
	if #result > 0 then
		local count = 0 
		local success = false
		repeat
			count = count + 1
			success = xpcall(function()  routeBuilder.checkRoadRouteForUpgradeBetweenStations({station1, station2}, callback, params) end, err)
			if not success then 
				trace("Error found upgrading route, attmpt ",count," trying again")
				
			end
		until success or count > 10
	else 
		routeBuilder.buildRoadRouteBetweenStations({station1, station2}, callback, params, hasEntranceB)
	end
end


function routeBuilder.buildParralelRoute(edges, callback)
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local positionToNodeMap = {}
	local function getOrMakeNewNode(p)	 
		local hash = util.pointHash3d(p)
		if not positionToNodeMap[hash] then 
			local newNode =  util.newNodeWithPosition(p, -1000-#nodesToAdd)
			positionToNodeMap[hash] = newNode 
			local nearestNode = util.searchForNearestNode(p)
			if nearestNode and util.positionsEqual(p, util.v3fromArr(nearestNode.position)) then 
				trace("found a node already near ",p.x,p.y,p.z)
				newNode.entity = nearestNode.id
			else 
				table.insert(nodesToAdd, newNode)
				trace("routeBuilder.buildParralelRoute: added node",newNode.entity," at ",p.x,p.y,p.z)
			end 
		end 
		return positionToNodeMap[hash]
	end 
	
	local function newDoubleTrackNode(n, t) 
		local p = util.nodePos(n)
		local invert = false 
		local testP = util.doubleTrackNodePoint(p, t, invert)
		
		local nearestNode = util.searchForNearestNode(testP)
		if util.positionsEqual(testP, util.v3fromArr(nearestNode.position)) then 
			invert = true
			testP = util.doubleTrackNodePoint(p, t, invert)
		end 
		return getOrMakeNewNode(testP), invert
	end 
	
	local nextRouteId = 1
	local routeEdges ={}
	local alreadySeen = {}
	local endEdges = {}
	
	local function gatherRouteEdges(edgeId, routeId)
		if alreadySeen[edgeId] or not edges[edgeId] then 
			return 
		end 
		alreadySeen[edgeId] = true 
		if not routeId then 
			routeId = nextRouteId 
			nextRouteId = nextRouteId + 1
			routeEdges[routeId]={}
		end 
		table.insert(routeEdges[routeId], edgeId)
		local edge = util.getEdge(edgeId)
		for j, node in pairs({edge.node0, edge.node1}) do 
			for k, seg in pairs(util.getSegmentsForNode(node)) do 
				gatherRouteEdges(seg, routeId )
				if not edges[seg] then 
					endEdges[edgeId]=node
				end 
			end 
		end 
	end 
	
	
	for edgeId, bool in pairs(edges) do 
		gatherRouteEdges(edgeId)
	 
	end 
	if util.tracelog then 
		debugPrint({routeEdges=routeEdges, endEdges})
	end 
	local endNodesReplaced = {}
	
	for edgeId, bool in pairs(edges) do 
		trace("Building parallelEdge for ",edgeId)
		local edge = util.getEdge(edgeId)
		
		local newEntity = util.copyExistingEdge(edgeId, -1-#edgesToAdd, edgeObjectsToAdd)
		--newEntity.comp.objects = {}
		if endEdges[edgeId] then  
			local newNode2
			if endEdges[edgeId] == edge.node0 then 
				local newNode, invert = newDoubleTrackNode(edge.node1, edge.tangent1)
				 newNode2 = getOrMakeNewNode(util.doubleTrackNodePoint(util.nodePos(edge.node0), edge.tangent0, invert))
				newEntity.comp.node0 = newNode2.entity
				newEntity.comp.node1 = newNode.entity
			else 
				local newNode, invert = newDoubleTrackNode(edge.node0, edge.tangent0)
				newEntity.comp.node0 = newNode.entity
				newNode2= getOrMakeNewNode(util.doubleTrackNodePoint(util.nodePos(edge.node1), edge.tangent1, invert))
				newEntity.comp.node1 =  newNode2.entity
			end 
			endNodesReplaced[endEdges[edgeId]]=newNode2
		else 
			newEntity.comp.node0 = newDoubleTrackNode(edge.node0, edge.tangent0).entity
			newEntity.comp.node1 = newDoubleTrackNode(edge.node1, edge.tangent1).entity
		end
		
		table.insert(edgesToAdd, newEntity)
		
	end 
	for edge, node in pairs(endEdges) do 
		local segs = util.getSegmentsForNode(node)
		local otherNodes = {}
		for i, seg in pairs(segs) do 
			if seg~=edge then 
				local edge2 = util.getEdge(seg)
				local nextNode = edge2.node0 == node and edge2.node1 or edge2.node0
				trace("Inspecting nextNode ",nextNode," for seg")
				table.insert(otherNodes, nextNode)
			end 
		end 
		local replacementNode = endNodesReplaced[node]
		local p1 = util.v3(replacementNode.comp.position)
		
		local p2 = util.nodePos(otherNodes[1])
		
		local p3 = util.nodePos(node)
		
		local p4 = util.nodePos(otherNodes[2])
		 
		local c = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
		
		if util.tracelog then debugPrint({otherNodes = otherNodes}) end 
		
		
		local nodeToUse = otherNodes[1]
		if c then 
			nodeToUse = otherNodes[2]		
		end 
		trace("Checking for collision, found",c~=nil,"node=",node,"using node",node)
		
		local edgeToCopy = util.findEdgeConnectingNodes(node, nodeToUse)
		
		local newEntity = util.copyExistingEdge(edgeToCopy, -1-#edgesToAdd)
		newEntity.comp.objects = {}
		if newEntity.comp.node0 == node then 
			newEntity.comp.node0 = replacementNode.entity
		else 
			newEntity.comp.node1 = replacementNode.entity
		end 
		
		local testProposal = api.type.SimpleProposal.new()
		testProposal.streetProposal.edgesToAdd[1]=newEntity 
		testProposal.streetProposal.nodesToAdd[1] = replacementNode
		
		local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
		trace("Building test proposal is critical?",testData.errorState.critical)
		if util.tracelog then debugPrint(testData) end
		if not testData.errorState.critical then 
			table.insert(edgesToAdd, newEntity)
		end 
		
		
		
	end
	if util.tracelog then 
	
		debugPrint({endNodesReplaced=endNodesReplaced})
	end
 
	local newProposal =  routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	local thisCallback = function(res, success)
		trace("Attempt to build parallel route was ",success)
		if callback then 
			callback(res, success)
		end 
		if not success and util.tracelog then 
			routeBuilder.addWork(function() 
				local str = ""
				for edge, node in pairs(endEdges) do 
					str = str..tostring(node)..", "
				end 
				error("failed to build between: "..str)
			end)
		end 
	end
	
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), thisCallback)
	
end


function routeBuilder.upgradeRoadRoadAddLane( edges, callback, disableShift)

	local referencedNodeToSegmentMap = {}

	

	for edgeId, bool in pairs(util.shallowClone(edges)) do 
		if not api.engine.entityExists(edgeId) or not util.getEdge(edgeId) then 
			trace("routeBuilder.upgradeRoadRoadAddLane: Aborting, edge no longer exists",edgeId)
			return false
		end 
		if util.getStreetTypeCategory(edgeId) == "highway" then 
			local parallelEdge = util.findParallelHighwayEdge(edgeId)
			if parallelEdge and not edges[parallelEdge] then 
				edges[parallelEdge]=true
			end 
		end 
	end 
	for edgeId, bool in pairs(edges) do 
		local edgeFull = util.getEdge(edgeId)
		for i, node in pairs({edgeFull.node0, edgeFull.node1}) do 
			if not referencedNodeToSegmentMap[node] then 
				referencedNodeToSegmentMap[node] = {}
			end 
			table.insert(referencedNodeToSegmentMap[node], edgeId)
		end 
	end 
	
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	
	local replacedNodesMap = {}
	local replacedEdgesMap = {}
	local function getOrMakeReplacedEdge(edgeId) 
		if not replacedEdgesMap[edgeId] then 
			local newEdge = util.copyExistingEdge(edgeId, -1-#edgesToAdd)
			table.insert(edgesToAdd, newEdge)
			replacedEdgesMap[edgeId]=newEdge
			table.insert(edgesToRemove, edgeId)
		end 
		return replacedEdgesMap[edgeId] 	
	end 
	local function getOrMakeNewNode(n )	 
		if not replacedNodesMap[n] then 
			local newNode = util.copyExistingNode(n, -1000-#nodesToAdd)
			table.insert(nodesToAdd, newNode)
			replacedNodesMap[n]=newNode
			for i , seg in pairs(util.getSegmentsForNode(n)) do 
				local newEdge = getOrMakeReplacedEdge(seg)
				if newEdge.comp.node0 == n then 
					newEdge.comp.node0 = newNode.entity 
				elseif newEdge.comp.node1 == n then -- double check required as may have already replaced 
 					newEdge.comp.node1 = newNode.entity
				end  
			end 
		end 
		return replacedNodesMap[n]
	end 

	for edgeId, bool in pairs(edges) do 
		local nextStreetType = util.getNextStreetTypeForEdge(edgeId)
		trace("routeBuilder.upgradeRoadRoadAddLane: inspecting ",edgeId)
		if util.getStreetEdge(edgeId).streetType ~= nextStreetType then 
			local newEdge = getOrMakeReplacedEdge(edgeId)
			newEdge.streetEdge.streetType = nextStreetType
			if util.getStreetTypeCategory(edgeId) == "highway" and not disableShift then 
				for i, nodeAndTangent in pairs(util.getNodeAndTangentTable(edgeId)) do 
					local node = nodeAndTangent.node
					trace("Insepcting node",node,"referenced count was",#referencedNodeToSegmentMap[node])
					if #referencedNodeToSegmentMap[node] == 2 then 
						local newNode = getOrMakeNewNode(node)
						local offset = 2 -- TODO could calculate this, based on lanewidth = 4 divided by 2
						local p = util.nodePos(node)
						local pNew = util.nodePointPerpendicularOffset(p, nodeAndTangent.tangent, -offset)
						trace("Shifting position of node for upgrade at node",node,"was",p.x,p.y," now ",pNew.x,pNew.y)
						util.setPositionOnNode(newNode, pNew)
					end 
				end 
			end 
		else 
			trace("Did not upgrade",edgeId," already at max size")
		end 
	end
	
	local newProposal =  routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), function(res, success )
		trace("routeBuilder.upgradeRoadRoadAddLane Result of attempt to upgrade was",success)
		if not success  then 
			if not disableShift then
				disableShift = true 
				routeBuilder.addWork(function() routeBuilder.upgradeRoadRoadAddLane( edges, callback, disableShift) end)
				return
			else	 
				routeBuilder.addWork(function() 
					local edgesToIgnore = {}
					for edgeId, newEdge in pairs(replacedEdgesMap) do 
						 if api.engine.entityExists(edgeId) and util.getEdge(edgeId) then 
							local newProposal = api.type.SimpleProposal.new() 
							newProposal.streetProposal.edgesToAdd[1]=newEdge 
							newProposal.streetProposal.edgesToRemove[1]=edgeId 
							local testData = api.engine.util.proposal.makeProposalData(newProposal , util.initContext())
							edgesToIgnore[edgeId]=testData.errorState.critical
						 else 
							edgesToIgnore[edgeId]=true
						 end 
					end 
					local newProposal = api.type.SimpleProposal.new() 
					for edgeId, newEdge in pairs(replacedEdgesMap) do 
						if not edgesToIgnore[edgeId] then 
							newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=newEdge 
							newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId 
						end 
					end 
					 
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), function(res, success )
						trace("routeBuilder.upgradeRoadRoadAddLane: attempt to individual upgrade success was",success)
						util.clearCacheNode2SegMaps()
					end)
				end)
				return 
			end 
		else 
			util.clearCacheNode2SegMaps()
		end 		
		if callback then 
			callback(res, success)
		end 
	end)
	return true
end 


function routeBuilder.buildIndustryConnectRoad(edgeId, callback)
	util.lazyCacheNode2SegMaps()
	local searchPoint = util.getEdgeMidPoint(edgeId)
	local params = paramHelper.getDefaultRouteBuildingParams()
	if routeBuilder.checkForNearbyHighwayAtPosition(callback, params, searchPoint, searchPoint) then 
		return
	end 
	local range = 500
	local edge = util.getEdge(edgeId)
	local filterFn = function(node) 
		if #util.getTrackSegmentsForNode(node.id) > 0 then 
			return false 
		end 
		if #util.getStreetSegmentsForNode(node.id) > 3 then 
			return false
		end 
		if util.isFrozenNode(node.id) then
			return false 
		end
		if util.isOneWayStreet(util.getStreetSegmentsForNode(node.id)[1]) then 
			return false 
		end
		return node.id ~= edge.node0 and node.id~=edge.node1 and not util.isDoubleDeadEndEdge(util.getSegmentsForNode(node.id)[1])
	end 
	local nodes = util.searchForEntitiesWithFilter(searchPoint, range, "BASE_NODE", filterFn)
	local options = {}
	for i, node in pairs(nodes) do 
		for j, node2 in pairs({edge.node0, edge.node1}) do 
			local p0 = util.v3fromArr(node.position)
			local p1 = util.nodePos(node2)
			local grad = math.abs(p0.z-p1.z)/vec2.distance(p0,p1)
			if grad < 0.2 then 
				table.insert(options, {
					nodePair = {node.id, node2},
					scores = {
						util.distance(p0,p1),
						#util.getSegmentsForNode(node.id),
						util.scoreTerrainBetweenPoints(p0,p1),
						util.scoreWaterBetweenPoints(p0,p1)
					}
				
				})
			else 
				trace("buildIndustryConnectRoad: rejecting nodes",node,node2,"as the grad exceeds max",grad)
			end 
		end 
	end 
	if #options == 0 then 
		callback({}, true)
		return 
	end 
	local best = util.evaluateWinnerFromScores(options)
	--trace("got best result",best)
	--trace("nodepair",best.nodePair)
	
	routeBuilder.buildRoute(best.nodePair, params, callback)
end

local function applyDummyChange(entity) 
	if entity.trackEdge.trackType ~= -1 then 
		local highSpeed = api.res.trackTypeRep.find("high_speed.lua")
		local standard =  api.res.trackTypeRep.find("standard.lua")
		if entity.trackEdge.trackType == highSpeed then 
			entity.trackEdge.trackType = standard
		else 
			entity.trackEdge.trackType = highSpeed
		end 
		entity.trackEdge.catenary = not entity.trackEdge.catenary
	else 
		local streetEdge = entity.streetEdge.streetType 
		local streetName = api.res.streetTypeRep.getName(streetEdge)
		local newStreetType = -1
		if string.find(streetName, "small") then 
			newStreetType = api.res.streetTypeRep.find(string.gsub(streetName,"small","medium" ))
		elseif string.find(streetName, "medium")  then 
			newStreetType = api.res.streetTypeRep.find(string.gsub(streetName,"medium","large" ))
		end 
		--if string.find(streetName, "old") then 
			--newStreetType = api.res.streetTypeRep.find(string.gsub(streetName,"old","new" ))
		--else 
			--newStreetType = api.res.streetTypeRep.find(string.gsub(streetName,"old","new" ))
		--end  
		if newStreetType ~= -1 then 
			entity.streetEdge.streetType = newStreetType
		end 
		
		if entity.playerOwned then 
			entity.playerOwned = nil
		else 
			local playerOwned = api.type.PlayerOwned.new()
			playerOwned.player =  api.engine.util.getPlayer()
			entity.playerOwned = playerOwned
		end 
	end 
end 

local function getCollisionEntitiesForEdge(edges, objectHolder) 
	local testProposal = api.type.SimpleProposal.new() 
	for i, edgeId in pairs(edges) do 
		local entity = util.copyExistingEdge(edgeId, -i)
		testProposal.streetProposal.edgesToAdd[i]=entity 
		testProposal.streetProposal.edgesToRemove[i]=edgeId
	end
	local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
	table.insert(objectHolder, testData) -- prevent child being gc'd
	return testData.collisionInfo.collisionEntities
end 


function routeBuilder.postBuildCleanup(res, params)
	if not util.tracelog or true then 
		return 
	end
	
	trace("routeBuilder.postBuildCleanup begin")
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local objectHolder = {} -- just to keep hold of a strong refence to parent objects
	if util.tracelog then 
		debugPrint({collisionInfo=res.resultProposalData.collisionInfo, errorState=res.resultProposalData.errorState}) 
	end
		
	local nodeLookup = {}	
	
	for i, node in pairs(res.proposal.proposal.addedNodes) do 
		local newNode = util.getNodeClosestToPosition(node.comp.position)
		nodeLookup[node.entity]=newNode
	end 
	
	
	local function getNewNode(node)  
		if node < 0 then 
			return nodeLookup[node]
		else
			return node
		end 
	end 
	
	local edgesAdded = {}
	local edgeLookup = {}
	
	for i, edge in pairs(res.proposal.proposal.addedSegments) do 
		local node0 = edge.comp.node0 
		local node1 = edge.comp.node1 
		local edgeId =  util.findEdgeConnectingNodes(getNewNode(node0),getNewNode(node1))
		if  edgeId then 
			
			edgesAdded[edgeId]=true
			edgeLookup[edge.entity]=edgeId
		else 
			trace("WARNING! Could not find the edge relating to ",node0,node1,getNewNode(node0),getNewNode(node1))
		end 
	end
	
	
	for i, entity in pairs(res.resultProposalData.collisionInfo.collisionEntities) do 
		if entity.entity > 0 and util.getEdge(entity.entity) then 
			local edges = util.gatherDoubleTrackEdges(entity.entity) 
			local collisionEntities = getCollisionEntitiesForEdge(edges, objectHolder) 
			trace("For entity",entity.entity," found collisionEntities",#collisionEntities)
		elseif edgeLookup[entity.entity] then 
			local edges = util.gatherDoubleTrackEdges(edgeLookup[entity.entity]) 
			local collisionEntities = getCollisionEntitiesForEdge(edges, objectHolder) 
			trace("For entity",entity.entity," found collisionEntities",#collisionEntities)
		end 		
	end 


	trace("routeBuilder.postBuildCleanup end")
end

function routeBuilder.runCleanUpTest(circle)
	local edges = game.interface.getEntities(circle, {type="BASE_EDGE", includeData=true })
	local positionsToCheck = {}
	for edgeId, edge in pairs(edges) do 
		table.insert(positionsToCheck, {
			p0 = util.v3fromArr(edge.node0pos),
			p1 = util.v3fromArr(edge.node1pos)
		})
	end 
	
	proposalUtil.checkEdgeTypes(positionsToCheck)
end

function routeBuilder.runCleanUpTest2(circle) 
	trace("runCleanUpTest: begin")
	util.lazyCacheNode2SegMaps()
	local edges = game.interface.getEntities(circle, {type="BASE_EDGE"})
	local edgesToAdd = {}
	local edgesToRemove = {}
	for i, edge in pairs(edges) do 
		if not util.isOneWayStreet(edge) then 
			 table.insert(edgesToRemove, edge )
			local copiedEdge = util.copyExistingEdge(edge, -1-#edgesToAdd) 
			trace("Copying edge at ",i)
			--applyDummyChange(copiedEdge) 
			 table.insert(edgesToAdd,copiedEdge)
		end
	end 
	
	local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	local edgesToAdd = util.shallowClone(newProposal.streetProposal.edgesToAdd)
	local nodesToAdd = util.shallowClone(newProposal.streetProposal.nodesToAdd)
	for i, node in pairs(nodesToAdd) do 
		node.comp.position.z = node.comp.position.z - 1
	end 
	newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	local testData =  api.engine.util.proposal.makeProposalData(newProposal  , util.initContext())
	
	debugPrint({testDataErrorState=testData.errorState, collisionInfo=testData.collisionInfo})
	
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(),true)
	 
	trace("About to sent command to runCleanUpTest")
	 
	api.cmd.sendCommand(build, function(res, success)
		trace("runCleanUpTest: result was",success)
		if success then 
			routeBuilder.addWork(function() routeBuilder.postBuildCleanup(res) end)
		end 
	end)
end 





function routeBuilder.postBuildCheckEdgeTypes(res, params) 
	trace("routeBuilder.postBuildCleanup begin")
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	
	local nodeLookup = {}	
	
	for i, node in pairs(res.proposal.proposal.addedNodes) do 
		 
		nodeLookup[node.entity]=util.v3(node.comp.position)
	end 
	
	
	local function nodePos(node)  
		if node < 0 then 
			return nodeLookup[node]
		else
			return util.nodePos(node)
		end 
	end 
	 
	local edgePositionsToCheck = {}
	for i, edge in pairs(res.proposal.proposal.addedSegments) do 
		local node0 = edge.comp.node0 
		local node1 = edge.comp.node1 
		table.insert(edgePositionsToCheck, { p0 = nodePos(node0), p1 = nodePos(node1) })
	end
	
	proposalUtil.checkEdgeTypes(edgePositionsToCheck, params)
end 




function routeBuilder.upgradeRouteBetweenTowns(town1, town2)
	local params = paramHelper.getDefaultRouteBuildingParams()
	local routeFn = function() 
		return pathFindingUtil.getRoadRouteInfoBetweenTowns(town1, town2)
	end 
	local callback = routeBuilder.standardCallback
	paramHelper.setParamsForMultiLaneRoad(params)
	routeBuilder.checkRoadForUpgradeOnly(routeFn, callback,  params  )  
end 
 
function routeBuilder.upgradeMainConnections()
	api.engine.forEachEntityWithComponent(function(entity) 
		local connection = util.getComponent(entity,api.type.ComponentType.TOWN_CONNECTION) 
		routeBuilder.addWork(function() routeBuilder.upgradeRouteBetweenTowns(connection.entity0, connection.entity1) end)
	end, api.type.ComponentType.TOWN_CONNECTION)
end 
return routeBuilder