local vec2 = require "vec2"
local vec3 = require "vec3"
local helper = require("ai_builder_station_template_helper")
local util = require("ai_builder_base_util")
local connectEval = require("ai_builder_new_connections_evaluation") 
local paramHelper = require("ai_builder_base_param_helper")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local profiler = require("ai_builder_profiler")
local waterMeshUtil = require "ai_builder_water_mesh_util"
local proposalUtil = require "ai_builder_proposal_util"
local correctBaseRouteTangent = true
local simplifiedEdgeScoring = true

local testTerrainScoring = false

local scoreRouteHeightsIdx = 1
local scoreDirectionHistoryIdx = 2
local scoreRouteNearbyEdgesIdx = 3
local scoreRouteFarmsIdx = 4
local scoreDistanceIdx = 5
local scoreEarthWorksIdx = 6
local scoreWaterPointsIdx = 7
local scoreRouteNearbyTownsIdx = 8
 
local alwaysSuppressSmoothing = true

local routeEvaluation = {} 
local trace = util.trace
	
local function calculateProjectedSpeedLimit(radius, trackData)
	if not trackData then trackData = api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua")) end
	return trackData.speedCoeffs.x * (radius + trackData.speedCoeffs.y) ^ trackData.speedCoeffs.z
end	

local routesDrawn = {}
local function sleep (a) 
    local sec = tonumber(os.clock() + a); 
    while (os.clock() < sec) do 
    end 
end
local function clearRoutes(onlyRouteOptions) 
	trace("about to clear routes")
	for i, name in pairs(routesDrawn) do 
		if onlyRouteOptions then 
			if string.find(name, "ai_builder_route_option") then 
				game.interface.setZone(name)
				--routesDrawn[name]=nil
			end 
		else 
			game.interface.setZone(name)
		end 
	end 
	if not onlyRouteOptions then 
		routesDrawn = {}
	end 
	trace("routes cleared")
end 
routeEvaluation.clearRoutes = clearRoutes
local function drawRoutes(routeOptions, baseRoute, numberOfNodes) 
	clearRoutes(true) 
	sleep(1)
	trace("drawRoutes begin")
	for i, route in pairs(routeOptions) do 
		if route.failed then 
			trace("Skipping failed route")
		--	goto continue
		end 
		local polygon
		if not route.failed then 
			polygon = {{ baseRoute[0].p.x, baseRoute[0].p.y }}
		else 
			polygon = {}
		end 
		for j = 1, numberOfNodes do 
			local point = route.points[j]
			if point then 
				table.insert(polygon, { point.x, point.y})
			end	    
		end
		if not route.failed then 
			table.insert(polygon, { baseRoute[numberOfNodes+1].p.x,baseRoute[numberOfNodes+1].p.y})
		end
		for j = numberOfNodes, 1, -1 do 
			local point = route.points[j]
			if point then 
				table.insert(polygon, { point.x, point.y})
			end
		end 
		--debugPrint({polygon=polygon})
		
		local name = "ai_builder_route_option"..tostring(i)
	 
		table.insert(routesDrawn, name)
		local colourIdx = 1 + i % #game.config.gui.lineColors
		--trace("Colouridx=",colourIdx)
		local colour = game.config.gui.lineColors[colourIdx]
		--local drawColour = { colour[1]*255, colour[2]*255, colour[3]*255, 1} 
		local drawColour = { colour[1], colour[2], colour[3], 0.5} 
		game.interface.setZone(name, {
			polygon=polygon,
			draw=true,
			drawColor = drawColour,
		})  
		if i > 50 then 
			break 
		end
		::continue::
	end 
	trace("drawRoutes end")
end 

local function drawRoute(baseRoute, numberOfNodes, index, offsetIndex)
	--[[if offsetIndex ~= -1000 then 
		return
	end ]]--
	local polygon = {{ baseRoute[0].p.x, baseRoute[0].p.y }}
	for j = 1, numberOfNodes do 
		local point = baseRoute[j].p
		table.insert(polygon, { point.x, point.y})
				
	end
	table.insert(polygon, { baseRoute[numberOfNodes+1].p.x,baseRoute[numberOfNodes+1].p.y})
	for j = numberOfNodes, 1, -1 do 
		local point = baseRoute[j].p
		table.insert(polygon, { point.x, point.y})
	end 
	local name = "ai_base_route"..tostring(index) 
	if offsetIndex then 
		name = name..tostring(offsetIndex)
	end 
	table.insert(routesDrawn, name)
	local colours = {
		{1, 1, 1},
		{1, 0 ,0} ,
		{0, 1, 0},
		{0, 0, 1},
		{1, 1, 0}
	}
	
	local colourIdx = 1 + index % #colours
	--trace("Colouridx=",colourIdx)
	local colour = colours[colourIdx]
	--local drawColour = { colour[1]*255, colour[2]*255, colour[3]*255, 1} 
	local drawColour = { colour[1], colour[2], colour[3], 1} 
	game.interface.setZone(name, {
		polygon=polygon,
		draw=true,
		drawColor = drawColour,
	})  
	trace("End drawBaseRoute at ",index, offsetIndex)
end 
local function drawBaseRoute(baseRouteInfo, numberOfNodes, index)
	trace("Begin drawBaseRoute at ",index)
	--clearRoutes()
	local baseRoute = baseRouteInfo.baseRoute
	drawRoute(baseRoute, numberOfNodes, index)
end 
local function checkForLooping(result,numberOfNodes, callPoint) 
	if not util.tracelog then 
		--return 
	end
	local totalAngle = 0
	local totalAngle2 = 0
	local maxAngle = -math.huge 
	local minAngle = math.huge
	local alreadyWarned = false
	for i = 1, numberOfNodes do 
		local priorP = result[i-1].p
		local p = result[i].p
		local nextP = result[i+1].p
		local t0 = p-priorP 
		local t1 = nextP -p 
		local angle = util.signedAngle(t0, t1) 
		maxAngle = math.max(maxAngle, angle)
		minAngle = math.min(minAngle, angle)
		totalAngle = totalAngle + angle
		local angle2 = util.signedAngle(result[i-1].t, result[i].t)
		totalAngle2 = totalAngle2 + angle2
		
		
		if math.abs(totalAngle) > math.rad(360) and not alreadyWarned then 
			trace("WARNING! checkForLooping found total angle=",math.deg(totalAngle),"at callPoint:",callPoint,"i=",i,"of",numberOfNodes,"p=",p.x,p.y,"priorP=",priorP.x,priorP.y,"nextP=",nextP.x,nextP.y)
			alreadyWarned = true 
		end 
		
	end 
	trace("checkForLooping at",callPoint,"the totalAngle was",math.deg(totalAngle),"totalAngle2 was",math.deg(totalAngle2),"minAngle=",math.deg(minAngle),"maxAngle=",math.deg(maxAngle))
	return alreadyWarned or math.abs(totalAngle) > math.rad(360) or math.max(math.abs(minAngle), maxAngle) > math.rad(90) -- TODO need to refine this
end 

local function shallowCloneRoute(route)
	local newRoute = {}
	newRoute.points = {}
	newRoute.routeCharacteristics = {}
	--newRoute.directionHistory = {}
	for i, p in pairs(route.points) do 
		newRoute.points[i]= p
		newRoute.routeCharacteristics[i]= route.routeCharacteristics[i]
		--table.insert(newRoute.directionHistory, route.directionHistory[i])
	end
	return newRoute
end
local function computeTangent(before, this, after, i, numberOfNodes, edge)
	local t1 = this-before
	local t2 = after-this
	if not (vec3.length(t1)> 0) or not (vec3.length(t2)>0) then -- NB cannot assume "==0" in case of NaN
		debugPrint({before=before, this=this, after=after, i=i, numberOfNodes=numberOfNodes, edge=edge})
	end 
	assert(vec3.length(t1)>0)
	assert(vec3.length(t2)>0)
	local t =  0.5 * (t1+t2)
	if i == 1 or i == numberOfNodes then 
		local originalTz = t.z
		if i == 1 then 
			local deflectionAngle = util.signedAngle(this-before, edge.t0)
			
			t = util.rotateXY( util.distance(before, this)*vec3.normalize(edge.t0), -2*deflectionAngle)
			
		end 
		if i == numberOfNodes then 
			local deflectionAngle = util.signedAngle(after-this, edge.t1)
			
			t = util.rotateXY( util.distance(this, after)*vec3.normalize(edge.t1),  -2*deflectionAngle)
			
		end 
		t.z = originalTz
	end
	assert(t.x == t.x)
	assert(t.y == t.y)
	assert(t.z == t.z)
	return t
end
local function hashIndustryLocation(p)
	return math.floor((p.x+100)/200) +10000*math.floor((p.y+100)/200) 
end 
local function hashLocation16(p)
	return math.floor((p.x+8)/16) +10000*math.floor((p.y+8)/16) 
end 
local mapBoundary 
local function hashLocation64(p)
	if not mapBoundary then 
		mapBoundary = util.getMapBoundary()
	end 
	return math.floor((p.x+mapBoundary.x+32)/64) +10000*math.floor((p.y+mapBoundary.y+32)/64) 
end 
local function invertHash64(hash) 
	return { x = 64*(hash%10000) -mapBoundary.x, y= 64*math.floor(hash/10000) -mapBoundary.y }
end 

local function hashLocation1024(p)
	return math.floor((p.x+512)/1024) +10000*math.floor((p.y+512)/1024) 
end 
local function countNearbyConstructions(p) 
	local hash = hashLocation64(p)
	local result = 0
	if routeEvaluation.constructionsBy64TileHash[hash] then 
		result = result+ #routeEvaluation.constructionsBy64TileHash[hash]
	end 
	local hash16 = hashLocation16(p)
	if routeEvaluation.constructionsBy16TileHash[hash16] then 
		result = result+ #routeEvaluation.constructionsBy16TileHash[hash16]
	end 
	return result 
end 
local function countNearbyEdges(p) 
	local hash = hashLocation64(p)
	local result = 0 
	if routeEvaluation.edgesBy64TileHash[hash] then 
		result = result + #routeEvaluation.edgesBy64TileHash[hash]
	end 
	local hash16 = hashLocation16(p)
	if routeEvaluation.edgesBy16TileHash[hash16] then 
		result = result + #routeEvaluation.edgesBy16TileHash[hash16]
	end 
	if routeEvaluation.junctionNodesBy16TileHash[hash16] then -- extra penalty for junction nodes
		result = result + #routeEvaluation.junctionNodesBy16TileHash[hash16]
	end 
	
	return result
end 
local function checkForSoftCollision(p)
	local hash = hashLocation64(p)
	return routeEvaluation.frozenEdgesBy64TileHash and routeEvaluation.frozenEdgesBy64TileHash[hash] ~= nil
end  
	
function routeEvaluation.applySmoothing(result, numberOfNodes, thisSmoothingPasses, params, edge)
	local begin = os.clock()
	profiler.beginFunction("routeEvaluation.applySmoothing")
	trace("Smoothing route for ", thisSmoothingPasses, " useHermiteSmoothing=",params.useHermiteSmoothing, " params.smoothFrom=",params.smoothFrom,"params.smoothTo=",params.smoothTo)
	--checkForLooping(result,numberOfNodes, "begin applySmoothing") 
	if not edge then 
		edge = {
			p0 = result[0].p,
			t0 = result[0].t,
			p1 = result[numberOfNodes+1].p,
			t1 = result[numberOfNodes+1].t,
		}
	end 
	if not params.upperAdjustments then params.upperAdjustments =0 end
	if not params.lowerAdjustments then params.lowerAdjustments =0 end
	if util.tracelog and params.isTrack then 
		local originalNode =  util.searchForNearestNode(edge.p1)
		if originalNode then 
			local tangent = -1*vec3.normalize(util.getDeadEndNodeDetails(originalNode.id).tangent)
			local expected = vec3.normalize(result[numberOfNodes+1].t)
			local msg = "expected "..tostring(tangent.x).." "..tostring(tangent.y).." but was "..tostring(expected.x).." "..tostring(expected.y)
		--	assert(math.abs(tangent.x - expected.x)<0.01,msg) 
		--	assert(math.abs(tangent.y - expected.y)<0.01,msg) 
		end
		local originalNode =  util.searchForNearestNode(edge.p0)
		if originalNode then 
			local tangent =  vec3.normalize(util.getDeadEndNodeDetails(originalNode.id).tangent)
			local expected = vec3.normalize(result[0].t)
			local msg = "expected "..tostring(tangent.x).." "..tostring(tangent.y).." but was "..tostring(expected.x).." "..tostring(expected.y)
			--assert(math.abs(tangent.x - expected.x)<0.01,msg) 
			--assert(math.abs(tangent.y - expected.y)<0.01,msg) 
		end
	end
	
	if params.isTrack then 
		local originalNode =  util.searchForNearestNode(edge.p1)
		if originalNode and util.positionsEqual(util.v3fromArr(originalNode.position), edge.p1, 1)  then 
			local tangent = -1*vec3.normalize(util.getDeadEndNodeDetails(originalNode.id).tangent)
			local originalTangent = result[numberOfNodes+1].t
			if math.abs(util.signedAngle(tangent, originalTangent)) > math.rad(1) then 
				local t0 = vec3.normalize(originalTangent)
				local t1 = vec3.normalize(tangent)
				
				trace("WARNING!, tangent change detected",t0.x, t0.y, " vs ",t1.x,t1.y)
			end 
			local originalTangent = result[numberOfNodes+1].t2
			if math.abs(util.signedAngle(tangent, originalTangent)) > math.rad(1) then 
				local t0 = vec3.normalize(originalTangent)
				local t1 = vec3.normalize(tangent)
				
				trace("WARNING!, tangent change t2 detected",t0.x, t0.y, " vs ",t1.x,t1.y)
			end 
			local length = util.calculateTangentLength(result[numberOfNodes].p, result[numberOfNodes+1].p, result[numberOfNodes].t, tangent)
			result[numberOfNodes+1].t = length* tangent
			result[numberOfNodes+1].t2 = length*tangent
			edge.t1 = tangent
		end
		local originalNode =  util.searchForNearestNode(edge.p0)
		if originalNode and util.positionsEqual(util.v3fromArr(originalNode.position), edge.p0, 1)  then 
		 
			local tangent = vec3.normalize(util.getDeadEndNodeDetails(originalNode.id).tangent)
			local originalTangent = result[0].t
			if math.abs(util.signedAngle(tangent, originalTangent)) > math.rad(1) then 
				local t0 = vec3.normalize(originalTangent)
				local t1 = vec3.normalize(tangent)
				
				trace("WARNING!, tangent change detected",t0.x, t0.y, " vs ",t1.x,t1.y)
			end 
			local originalTangent = result[0].t2
			if math.abs(util.signedAngle(tangent, originalTangent)) > math.rad(1) then 
				local t0 = vec3.normalize(originalTangent)
				local t1 = vec3.normalize(tangent)
				
				trace("WARNING!, tangent change t2 detected",t0.x, t0.y, " vs ",t1.x,t1.y)
			end 
			local length = util.calculateTangentLength(result[0].p, result[1].p, result[numberOfNodes].t, result[1].t)
			result[0].t = length* tangent
			result[0].t2 = length*tangent
			edge.t1 = tangent
		end
	end 
	
	local speedCoeffs = api.res.trackTypeRep.get(api.res.trackTypeRep.find(params.isHighSpeedTrack and "high_speed.lua" or "standard.lua")).speedCoeffs
	if numberOfNodes < 2 then 
		return 
	end
	local targetSpeedLimit = params.targetSpeedLimit or 100/3.6 -- 100km/h in m/s
	local lowSpeedThreashold = (2/3)*targetSpeedLimit
	if params.isVeryHighSpeedTrain then 
		lowSpeedThreashold = (4/5)*targetSpeedLimit
	end
	local smoothFrom = params.smoothFrom and params.smoothFrom or 1 
	local smoothTo = params.smoothTo and math.min(params.smoothTo, numberOfNodes) or numberOfNodes
	if result[0] and result[0].t then 
		result[0].t2 = vec3.length(result[1].t2)*vec3.normalize(result[0].t)
	end
	local j = 1
	local lastSpeedLimit
	local maxSmoothingPasses = math.max(thisSmoothingPasses, params.isVeryHighSpeedTrain and 10 or 5)
	while j <= thisSmoothingPasses do
		j = j + 1
		if (params.isTrack or params.isHighway) and numberOfNodes > 3 and j < 3 then 
			local segLength = math.max(params.targetSeglenth, util.distance(result[0].p, result[numberOfNodes+1].p) / numberOfNodes)
			local maxAngle = math.rad(params.maxInitialTrackAngleStart) 
			local startAngle = util.signedAngle(result[1].p-result[0].p, result[0].t2)
			if math.abs(startAngle) > 0.5*maxAngle then 
				--trace("Detected sharp start angle", math.deg(startAngle)," reducing smoothing scope near",params.station1)
				--smoothFrom = math.max(smoothFrom, 2)
			end 
			local startPointCorrected = false 
			local maxCorrectionIdx = -1
			local extremeAngle = math.abs(startAngle) > math.rad(60)
			if math.abs(startAngle) > maxAngle and not result[1].followRoute then 
				trace("Attempting to correct sharp angle at ",result[1].p.x,result[1].p.y, " angle was",math.deg(startAngle))
			 
				local newAngle = startAngle > 0 and -maxAngle or maxAngle
				local t = vec3.normalize(util.rotateXY(result[0].t2, newAngle))
				result[1].p = segLength * t + result[0].p
				result[1].t = segLength * util.rotateXY(t, newAngle)
				result[1].t2 = segLength * util.rotateXY(t, newAngle)
				local recalculatedAngle = util.signedAngle(result[1].p-result[0].p, result[0].t2)
				if util.tracelog then 
					local angle = util.signedAngle(result[0].t, result[0].t2)
					trace("The internal angle was",math.deg(angle))
					if math.abs(angle) >= math.rad(1) then 
						debugPrint(result[0])
					end
					assert(math.abs(angle)<math.rad(1))
				end 
				trace("Detected sharp start angle", math.deg(startAngle), " attempting to correct, recalculated angle is ",math.deg(recalculatedAngle), " new point is at ",result[1].p.x,result[1].p.y)
				if extremeAngle then 
					smoothFrom = 2
				end
				maxCorrectionIdx = 1
				startPointCorrected = true 
			end 
			local startAngle2 = util.signedAngle(result[2].p-result[0].p, result[0].t2)
			if not startPointCorrected and math.abs(startAngle2) >  maxAngle then 
			--	trace("Detected sharp start angle", math.deg(startAngle2)," reducing smoothing scope")
				--smoothFrom = math.max(smoothFrom, 3)
			end 
			if math.abs(startAngle2) > 1.5*maxAngle and not result[2].followRoute then 
				trace("Attempting to correct sharp angle 2 at ",result[2].p.x,result[2].p.y, " angle was",math.deg(startAngle2))
				local newAngle = startAngle > 0 and -1.5*maxAngle or 1.5*maxAngle
				local t = vec3.normalize(util.rotateXY(result[0].t2, newAngle))
				result[2].p = 2*segLength * t + result[0].p
				result[2].t = segLength * util.rotateXY(t, newAngle)
				result[2].t2 = segLength * util.rotateXY(t, newAngle)
				local recalculatedAngle = util.signedAngle(result[2].p-result[0].p, result[0].t2)
				trace("Detected sharp start angle2", math.deg(startAngle), " attempting to correct, recalculated angle is ",math.deg(recalculatedAngle), " new point is at ",result[2].p.x,result[2].p.y)
				maxCorrectionIdx = 2
			end 
			 
			for i = 1, maxCorrectionIdx +1 do 
				
				local before = result[i-1].p
				local this = result[i].p
				local after = result[i+1].p
				local t = computeTangent(before, this,after, i, numberOfNodes, edge)
				result[i].t = util.calculateTangentLength(before, this, result[i-1].t2, t)* vec3.normalize(t)
				result[i].t2 = util.calculateTangentLength(this, after,t, result[i+1].t )* vec3.normalize(t)
				trace("Recalculated t at ",i," to ",t.x,t.y)				
			end 
			local endConsistencyCheck = math.abs(util.signedAngle(result[numberOfNodes+1].t,result[numberOfNodes+1].t2))
			if endConsistencyCheck > math.rad(1) then 
				trace("WARNING! inconsistent angles detected at the end, was ",math.deg(endConsistencyCheck), " attempting to correct")
				result[numberOfNodes+1].t = vec3.length(result[numberOfNodes].t)*vec3.normalize(result[numberOfNodes+1].t2)
			end
			local maxAngle = math.rad(params.maxInitialTrackAngleEnd) 
			local endAngle = util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
			local endAngleAlternative = util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t2)
			if math.abs(endAngle) > 0.5*maxAngle then 
		--		trace("Detected sharp end angle", math.deg(endAngle)," reducing smoothing scope endAngleAlternative=",math.deg(endAngleAlternative))
--smoothTo = math.min(smoothTo, numberOfNodes-1)
			end
			local minCorrectionIdx = -1
			local endAngleCorrected = false
			local extremeAngle = math.abs(endAngle) > math.rad(60)
			if math.abs(endAngle) > maxAngle and not result[numberOfNodes].followRoute then  
				local newAngle = endAngle > 0 and -maxAngle or maxAngle
				local t = vec3.normalize(util.rotateXY(result[numberOfNodes+1].t, newAngle))
				result[numberOfNodes].p = result[numberOfNodes+1].p -segLength * t
				result[numberOfNodes].t = segLength* util.rotateXY(t, newAngle)
				result[numberOfNodes].t2 = segLength* util.rotateXY(t, newAngle)
				local recalculatedAngle =util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
				trace("Detected sharp end angle", math.deg(endAngle), " attempting to correct, recalculated angle is ",math.deg(recalculatedAngle))
				if extremeAngle then 
					smoothTo = math.min(smoothTo, numberOfNodes-1)
				end
				minCorrectionIdx =numberOfNodes
			end
			local endAngle2 = util.signedAngle(result[numberOfNodes-1].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
			if not endAngleCorrected and math.abs(endAngle2) >  maxAngle  then 
				trace("Detected sharp end angle2", math.deg(endAngle2)," reducing smoothing scope near",params.station2 )
				if extremeAngle then 
					smoothTo = math.min(smoothTo, numberOfNodes-2)
				end
			end
			if math.abs(endAngle2) > 1.5*maxAngle and not result[numberOfNodes-1].followRoute then  
				local newAngle = endAngle2 > 0 and -1.5*maxAngle or 1.5*maxAngle
				local t = vec3.normalize(util.rotateXY(result[numberOfNodes+1].t, newAngle))
				result[numberOfNodes-1].p = result[numberOfNodes+1].p -2*segLength * t
				result[numberOfNodes-1].t = segLength* util.rotateXY(t, newAngle)
				result[numberOfNodes-1].t2 = segLength* util.rotateXY(t, newAngle)
				local recalculatedAngle =util.signedAngle(result[numberOfNodes-1].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
				trace("Detected sharp end angle2", math.deg(endAngle2), " attempting to correct, recalculated angle is ",math.deg(recalculatedAngle))
				minCorrectionIdx =numberOfNodes-1
			end
			if minCorrectionIdx > 1 then 
				for i = minCorrectionIdx-1, numberOfNodes do 
					local before = result[i-1].p
					local this = result[i].p
					local after = result[i+1].p
					local t = computeTangent(before, this,after, i, numberOfNodes, edge)
					result[i].t = util.calculateTangentLength(before, this, result[i-1].t2, t)* vec3.normalize(t)
					result[i].t2 = util.calculateTangentLength(this, after,t, result[i+1].t )* vec3.normalize(t)
					trace("Recalculated t at ",i," to ",t.x,t.y)
				end 
			end
			
		end
		if params.isHighSpeedTrack and params.startConnectingRoute then 
			smoothFrom = 1
		end
		if params.isHighSpeedTrack and params.endConnectingRoute then 
			smoothTo = numberOfNodes
		end		
		if params.startAngleCorrections then 
			smoothFrom = math.max(smoothFrom, params.startAngleCorrections-1)
		end 
		if params.endAngleCorrected then 
			smoothTo = math.min(smoothTo, 1+numberOfNodes-params.endAngleCorrections)
		end 
		trace("smoothing route from",smoothFrom,"to",smoothTo,"of",numberOfNodes)
		for i =smoothFrom , smoothTo  do
			local this = result[i]
			if this.realigned or this.followRoute then 
				goto continue 
			end
			local before = result[i-1]
			
			local after = result[i+1]
			--local edge = { p0 = before.p, t0=2*before.t2, p1=after.p, t1 = 2*after.t }
			local edge = util.createCombinedEdge(before, this, after)
			local p = this.p
			local solution 
			if params.useHermiteSmoothing  then
				solution = util.solveForPositionHermiteFraction(0.5, edge) 
			else 
				solution = util.solveForPosition(p, edge, util.distance)
			end
			if util.checkForCollisionWithConstructionsPoint(solution.p) then 
				trace("Detected collision with construction at",solution.p.x,solution.p.y,"aborting smoothing at",i)
				goto continue 
			end 
			if util.tracelog then 
				assert(math.abs(util.signedAngle(before.t2, solution.t0))<math.rad(1))
			end 
			before.t2 = solution.t0
			result[i]={ p = solution.p1, t = solution.t1, t2 = solution.t2, edgeId = this.edgeId, minHeight= this.minHeight, maxHeight=this.maxHeight}
			if i == 1 then 
				trace("Set result to ",result[i].p.x,result[i].p.y)
			end 
			after.t = solution.t3
			::continue::
		end
		if result[0] and result[0].t then 
			result[0].t2 = vec3.length(result[1].t2)*vec3.normalize(result[0].t)
		end
		result[numberOfNodes+1].t = vec3.length(result[numberOfNodes].t)*vec3.normalize(result[numberOfNodes+1].t2)
		local minSpeedLimit = 300/3.6
		local speedLimits = {}
		local indexesUnderThreashold = {}
		local indexesUnderThreasholdSet = {}
		local lowerSpeedBoundary = math.max(smoothFrom, params.startConnectingRoute and 1 or 3)
		local upperSpeedBoundary = math.min(smoothTo+1, params.endConnectingRoute and numberOfNodes+1 or numberOfNodes-2)
		for i = lowerSpeedBoundary, upperSpeedBoundary do
			local t0 = result[i-1].t2 
			local t1 = result[i].t 
			local p0 = result[i-1].p 
			local p1 = result[i].p
			local angle = math.abs(util.signedAngle(t0,t1))
			local projectedSpeedLimit = targetSpeedLimit
			if angle > math.rad(1) then 
				local dist = util.distance(p1, p0) 
				local r = dist/(2*math.sin( angle/2))
				projectedSpeedLimit = speedCoeffs.x * (r + speedCoeffs.y) ^ speedCoeffs.z
				--trace("The projected speed limit at i ",i, " was ", api.util.formatSpeed(projectedSpeedLimit))
				minSpeedLimit = math.min(minSpeedLimit, projectedSpeedLimit)
			end 
			speedLimits[i]=projectedSpeedLimit
			if projectedSpeedLimit < lowSpeedThreashold  then 
				trace("Low speed limit detected at ",i," was ",api.util.formatSpeed(projectedSpeedLimit))
				local midPointScore = math.abs(i-(numberOfNodes/2))
				if params.startConnectingRoute and params.endConnectingRoute then 
					midPointScore = 0 
				elseif params.startConnectingRoute then 
					midPointScore = i
				elseif params.endConnectingRoute then 
					midPointScore = numberOfNodes-i 
				end 
				
				table.insert(indexesUnderThreashold, {idx=i, scores={
				projectedSpeedLimit,midPointScore}}) 
				indexesUnderThreasholdSet[i]=true
			end
		end
		--trace("The minSpeedLimit ",api.util.formatSpeed(minSpeedLimit)," was achieved at the ",j,"th smoothing taget speed was",api.util.formatSpeed(targetSpeedLimit))
		
		if minSpeedLimit >= targetSpeedLimit and j > 1 then 
			trace("exiting smoothing as the target speed was achieved",api.util.formatSpeed(minSpeedLimit))
			break
		elseif j == thisSmoothingPasses and minSpeedLimit < targetSpeedLimit and thisSmoothingPasses < maxSmoothingPasses then 
			thisSmoothingPasses = thisSmoothingPasses + 1
			trace("increasing smoothing passes to ",thisSmoothingPasses, " speed=",api.util.formatSpeed(minSpeedLimit))
		end
		if lastSpeedLimit and minSpeedLimit < lastSpeedLimit then 
			break 
		end 
		
		--if minSpeedLimit < lowSpeedThreashold and numberOfNodes > 10 and (params.isTrack or params.isHighway) and upperSpeedBoundary-lowerSpeedBoundary > 10 then 
		if minSpeedLimit < lowSpeedThreashold and (params.isTrack or params.isHighway) then 
			local upperSpeedBoundary = numberOfNodes + 1-params.upperAdjustments
			local lowerSpeedBoundary = params.lowerAdjustments
			for __, lowestSpeedlimit in pairs( util.evaluateAndSortFromScores(indexesUnderThreashold)) do 
		 
				trace("Low speed limit detected, attempting to correct, lowest of ", lowestSpeedlimit.idx)
				local upperSpeedLimitIdx
				local lowerSpeedLimitIdx
				for i = lowestSpeedlimit.idx, upperSpeedBoundary do
					if not indexesUnderThreasholdSet[i] then 
						upperSpeedLimitIdx = i 
						break
					end
				end 
				for i = lowestSpeedlimit.idx, lowerSpeedBoundary, -1 do
					if not indexesUnderThreasholdSet[i] then 
						lowerSpeedLimitIdx = i 
						break
					end
				end 
				if not upperSpeedLimitIdx then upperSpeedLimitIdx = upperSpeedBoundary end 
				
				if not lowerSpeedLimitIdx then lowerSpeedLimitIdx = lowerSpeedBoundary end 
				
				local gap = upperSpeedLimitIdx - lowerSpeedLimitIdx 
				
				local minIntervals = math.min(upperSpeedBoundary-lowerSpeedBoundary,params.isVeryHighSpeedTrain and 6 or params.isHighSpeedTrack and 4 or 2)
				trace("The upperSpeedLimitIdx=",upperSpeedLimitIdx, " the lowerSpeedLimitIdx=",lowerSpeedLimitIdx," the gap was",gap," the minIntervals was",minIntervals)
				while upperSpeedLimitIdx - lowerSpeedLimitIdx < minIntervals do 
					upperSpeedLimitIdx = math.min(upperSpeedLimitIdx+1, upperSpeedBoundary)
					lowerSpeedLimitIdx = math.max(lowerSpeedLimitIdx-1, lowerSpeedBoundary)
				end 
				gap = upperSpeedLimitIdx - lowerSpeedLimitIdx 
				trace("After correction the upperSpeedLimitIdx=",upperSpeedLimitIdx, " the lowerSpeedLimitIdx=",lowerSpeedLimitIdx," the gap was",gap)
				local pUp = result[upperSpeedLimitIdx]
				local pDown = result[lowerSpeedLimitIdx]
				local tangentLength = util.calculateTangentLength(pDown.p, pUp.p, pDown.t2, pUp.t)
				local edge = {
					p0 = pDown.p,
					p1 = pUp.p,
					t0 = tangentLength*vec3.normalize(pDown.t2),
					t1 = tangentLength*vec3.normalize(pUp.t)			
				}
				for i = lowerSpeedLimitIdx+1, upperSpeedLimitIdx-1 do 
					if result[i].followRoute then 
						goto continue
					end 
					local hermiteFrac = (i-lowerSpeedLimitIdx)/(gap)
					trace("At i=",i,"solving with hermiteFrac=",hermiteFrac)
					local solution = util.solveForPositionHermiteFraction(hermiteFrac, edge) 
					if util.checkForCollisionWithConstructionsPoint(solution.p) then 
						trace("Detected collision with construction at",solution.p.x,solution.p.y,"aborting smoothing at",i)
						goto continue 
					end 					
				 
					result[i].p=solution.p
					result[i].t=solution.t1
					result[i].t2=solution.t2
					local tangentLength = util.calculateTangentLength(result[i-1].p, result[i].p, result[i-1].t2, result[i].t)
					
					result[i].t = tangentLength*vec3.normalize(result[i].t)
					result[i-1].t2 = tangentLength*vec3.normalize(result[i-1].t2)
					local angle = math.abs(util.signedAngle(result[i-1].t2,result[i].t))
					local dist = util.distance(result[i].p, result[i-1].p)
					local r = dist/(2*math.sin( angle/2))
					local projectedSpeedLimit = speedCoeffs.x * (r + speedCoeffs.y) ^ speedCoeffs.z
					trace("At i = ",i," the new projected speed limit is",api.util.formatSpeed(projectedSpeedLimit), " at ",result[i].p.x,result[i].p.y)
					indexesUnderThreasholdSet[i] = projectedSpeedLimit < lowSpeedThreashold 
					assert(i ~=0)
					assert(i ~= numberOfNodes+1)
					::continue::
				end 
			end
			
		end 
		
		lastSpeedLimit = minSpeedLimit
	end
	
	for i = 1 , numberOfNodes  do
		local p = result[i].p 
		if p.x ~= p.x or p.y ~= p.y then 
			trace("WARNING! NaN found at ",i)
		end
	end 
	--checkForLooping(result,numberOfNodes, "end applySmoothing") 
	trace("End smoothing route, time taken:",(os.clock()-begin))
	profiler.endFunction("routeEvaluation.applySmoothing")
end


local function scoreRouteHeights2(points)
	local score = 0
	for i, point in pairs(points) do
		score = score + math.abs(util.th(point )-point.z)
	end
	return score
end	

local function scoreNearbyTown(routePoint, params) 
	local result = 0
	if routeEvaluation.industryLocationsByHash[hashIndustryLocation(routePoint)] then 
		result = result + 1
	end 
	local hash = hashLocation1024(routePoint)
	if not routeEvaluation.townsBy1024Hash[hash] then 
		return result 
	end 
	
	
	 
	local searchDist = 1000
	local minDist = searchDist
	for i, p in pairs(routeEvaluation.townsBy1024Hash[hash]) do 
		if util.distance(p, routePoint) < searchDist then 
			minDist = math.min(minDist, util.distance(routePoint, p )) 
		end 
	end 
	result = result + math.max(1000-minDist, 0)/100
	--trace("town score at at point",routePoint.x,routePoint.y,"positionHash=",positionHash,"was",result)
	--result = result + #game.interface.getEntities({radius=500, pos={routePoint.x, routePoint.y}}, {type="SIM_BUILDING"})

	 
	return result
end 
local function getFullRouteScoreFns(maxGradFrac, numberOfNodes, params)
--[[
	
		local directionHistory = route.directionHistory
	 
	
	
	local function scoreDirectionHistory(points)
		 
		
		--[[
		local xyPlane = vec3.new(0,0,1)
	return math.atan2(vec3.dot(vec3.cross(v1, v2), xyPlane), vec3.dot(v1, v2))
		function vec3.dot(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z;
end

function vec3.cross(a, b)
	return vec3.new(
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x)
end`
		]]--
	local exponent = 1 / api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua")).speedCoeffs.z	
	local function scoreDirectionHistory(route)
		local points = route.points or route
		local score = 0
		for i = 1, numberOfNodes  do
			local angle2 = math.abs(util.signedAngle(points[i-1].t, points[i].t))
			if angle2 < params.targetMaxDeflectionAngle then 
				angle2 = 0 
			end
			 
			score = score + angle2^exponent
			 
		end
		 
		return score
	end
	local function scoreRouteHeights(route)
		--if not route.routeCharacteristics then debugPrint(route) end
		local points = route.points or route
		local score = 0
		for i = 1, numberOfNodes do
			local diff =  math.abs(points[i].p.z -util.th(points[i].p))
			if diff > 2 then -- avoid scoring trival height variations
				score = score + diff 
			end
		end
		
		return score
	end
	
	
	local function scoreRouteNearbyEdges(route)
		local points = route.points or route
		--if not route.routeCharacteristics then debugPrint(route) end
		local score = 0
	 
		for i = 1, numberOfNodes do 
			score = score + util.countNearbyEntitiesCached(points[i].p, params.targetSeglenth/2, "BASE_EDGE")
		end
		
		return score
	end
	
	local function scoreRouteFarms(route)
	 local points = route.points or route
		local score = 0
		 
		for i = 1, numberOfNodes do 
			score = score + (util.isPointNearFarm(points[i].p) and 1 or 0)
		end
		
		return score
	end
	
	local function scoreDistance(route)
		 local points = route.points or route
		local score = 0
		for i = 1, numberOfNodes+1 do
			--util.trace("about to compute len for i=",i)
			--score = score + util.distance(points[i],points[i-1])
			-- unbundeled for performance
			local p0 = points[i-1].p
			local p1 = points[i].p
			local t0 = points[i-1].t2
			local t1 = points[i].t
			local thisSegLength = util.calcEdgeLength(p0, p1, t0, t1)
			--assert(util.distance(points[i],points[i-1])==dist, " expected "..util.distance(points[i],points[i-1]).." but was "..dist)
			score = score + thisSegLength
		end
 
		return score
	end
	local function scoreEarthWorks(route)
		local points = route.points or route
		local lastHeight = points[0].p.z
		local lastPoint = points[0]  
		local score = 0
		 
		local startAt = 1
		local endAt = numberOfNodes
		local threashold = 0 
		if params.isElevated or params.isUnderground then 
			startAt = 2
			endAt = endAt - 1
			threashold = 15
		end
		
		for i =startAt,  endAt do
			local point = points[i] 
			 
			local dx = point.p.x-lastPoint.p.x 
			local dy = point.p.y-lastPoint.p.y
			local dz = point.p.z-lastPoint.p.z 
			-- util.trace(" at i=",i," scoring ", point, " against ", lastPoint, "maxGradFrac=",maxGradFrac)
			local maxDeltaZ = maxGradFrac *  math.sqrt(dx*dx + dy*dy + dz*dz)+threashold
			local terrainHeight = util.th(point.p)
			local terrainDeltaZ = terrainHeight - lastHeight
			if math.abs(terrainDeltaZ) > maxDeltaZ then
				score = score + (math.abs(terrainDeltaZ)-maxDeltaZ)
				if terrainDeltaZ < 0 then
					lastHeight = lastHeight - maxDeltaZ
				else 
					lastHeight = lastHeight + maxDeltaZ
				end
			else 
				lastHeight = terrainHeight
			end
			lastPoint = point
		end
		
		return score
	end
	
	local function scoreWaterPoints(route)
		local points = route.points or route
		
		local score = 0
		--[[for i = 2, #route.points-1 do
			local priorPoint = route.points[i-1]
			local point = route.points[i]
			if route.routeCharacteristics[i].terrainHeight < 0 then 
				score = score + math.abs(route.routeCharacteristics[i].terrainHeight)
			end
			local vectorFromLast = point - priorPoint
			for i = 2, 11 do -- get a bit more granular detail 
				local testPoint = priorPoint + (i/12)*vectorFromLast
				local th = util.th(testPoint) 
				if th < 0 then 
					score = score + math.abs(th) 
				end
			end
			  
		end--]]
		local waterLevel = util.getWaterLevel()
		for i = 1, numberOfNodes do
			local th = util.th(points[i].p)
			if th < waterLevel then 
				score = score + math.min(waterLevel-th, 20)
			end 
		
		end
		
		return score
	end
	
	local function scoreRouteNearbyTowns(route)
		local points = route.points or route 
		 
		local score = 0
		for i = 1, numberOfNodes do
			score = score + scoreNearbyTown(points[i].p, params)  
		end
		return score
	end
	
	return { 
			 scoreRouteHeights , 
			 scoreDirectionHistory ,
			 scoreRouteNearbyEdges ,
			 scoreRouteFarms ,
			 scoreDistance,
			 scoreEarthWorks, 
			 scoreWaterPoints,
			 scoreRouteNearbyTowns
			}
end
local function getScoreFns(maxGradFrac, baseRoute, params)
--[[
	local function scoreDirectionHistory(route)
		local directionHistory = route.directionHistory
		local score = directionHistory[1]==2 and 0 or 1 -- bonus for taking the central path
		for i = 2, #directionHistory do 
			score = score + math.abs(directionHistory[i]-directionHistory[i-1])
		end
		
		return score
	end--]]
	
	--[[
	Time taken to score at 	1	 was 	0.067000000000007
Time taken to score at 	2	 was 	0.88999999999987
Time taken to score at 	3	 was 	0.020999999999958
Time taken to score at 	4	 was 	0.019999999999982
Time taken to score at 	5	 was 	0.45000000000005
Time taken to score at 	6	 was 	0.53899999999999
Time taken to score at 	7	 was 	0.017000000000053
Time taken to score at 	8	 was 	0.019000000000005


Time taken to score at 	1	 was 	0.041999999999916
Time taken to score at 	2	 was 	0.61900000000014
Time taken to score at 	3	 was 	0.010999999999967
Time taken to score at 	4	 was 	0.010999999999967
Time taken to score at 	5	 was 	0.30199999999968
Time taken to score at 	6	 was 	0.33000000000038
Time taken to score at 	7	 was 	0.011999999999716
Time taken to score at 	8	 was 	0.010000000000218

Time taken to score at 	1	 was 	0.042000000000371
Time taken to score at 	2	 was 	0.65399999999954
Time taken to score at 	3	 was 	0.010000000000218
Time taken to score at 	4	 was 	0.011999999999716
Time taken to score at 	5	 was 	0.16800000000057
Time taken to score at 	6	 was 	0.22599999999966
Time taken to score at 	7	 was 	0.011999999999716
Time taken to score at 	8	 was 	0.010000000000218

Time taken to score at 	1	 was 	0.033000000000015
Time taken to score at 	2	 was 	0.41399999999999
Time taken to score at 	3	 was 	0.0079999999999814
Time taken to score at 	4	 was 	0.010000000000048
Time taken to score at 	5	 was 	0.036999999999978
Time taken to score at 	6	 was 	0.17199999999997
Time taken to score at 	7	 was 	0.0090000000000146
Time taken to score at 	8	 was 	0.0080000000000382


scoreRouteHeights , 
			 scoreDirectionHistory ,
			 scoreRouteNearbyEdges ,
			 scoreRouteFarms ,
			 scoreDistance,
			 scoreEarthWorks, 
			 scoreWaterPoints,
			 scoreRouteNearbyTowns

--]]	
	
	local exponent = 1 / api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua")).speedCoeffs.z	
	local function scoreDirectionHistory(route)
		local points = route.points
		
		--[[
		local xyPlane = vec3.new(0,0,1)
	return math.atan2(vec3.dot(vec3.cross(v1, v2), xyPlane), vec3.dot(v1, v2))
		function vec3.dot(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z;
end

function vec3.cross(a, b)
	return vec3.new(
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x)
end`
		]]--
		
		local firstAngle =  math.abs(util.signedAngle(baseRoute[0].t,points[1]-baseRoute[0].p))
		local score = firstAngle^exponent
		--local maxAngle = firstAngle
		for i = 2, #points-1 do
			local p0 = points[i-1]
			local p1 = points[i]
			local p2 = points[i+1]
			--[[
			local before = points[i]-points[i-1]
			local after = points[i+1]-points[i]
			local angle =  math.abs(util.signedAngle(before, after))]]--
			
			local d0x = p1.x - p0.x
			local d0y = p1.y - p0.y 
			
			local d1x = p2.x - p1.x
			local d1y = p2.y - p1.y 
			
			local dot =  d0x * d1x + d0y * d1y  
			local cross = d0x * d1y - d0y * d1x -- z component only for xy plane
			
			local angle2 = math.abs(math.atan2(cross, dot))
			if angle2 < params.targetMaxDeflectionAngle then 
				angle2 = 0 
			end
			--assert(angle2 == angle, " expected "..angle.." but was "..angle2)
			score = score + angle2^exponent
			--maxAngle = math.max(maxAngle, angle)
		end
		local lastAngle =  math.abs(util.signedAngle(baseRoute[#points+1].t,baseRoute[#points+1].p-points[#points]))
		score = score + lastAngle^exponent
		--maxAngle = math.max(maxAngle, lastAngle)
		--if maxAngle > math.rad(60) then 
		--	trace("The max angle was ", math.deg(maxAngle), " total score was",score," trial maxAngle^10=",maxAngle^10)
		--end
		return score
	end
	local function scoreRouteHeights(route)
		--if not route.routeCharacteristics then debugPrint(route) end
		local score = 0
		local routeCharacteristics = route.routeCharacteristics
		local points = route.points
		for i = 1, #routeCharacteristics do
			local diff =  math.abs(routeCharacteristics[i].terrainHeight-points[i].z)
			if diff > 2 then -- avoid scoring trival height variations
				score = score + diff 
			end
		end
		
		return score
	end
	
	
	local function scoreRouteNearbyEdges(route)
		--if not route.routeCharacteristics then debugPrint(route) end
		local score = 0
		local routeCharacteristics = route.routeCharacteristics
		for i = 1, #routeCharacteristics do 
			score = score + routeCharacteristics[i].nearbyEdgeScore
		end
		
		return score
	end
	
	local function scoreRouteFarms(route)
		if not route.routeCharacteristics then debugPrint(route) end
		local score = 0
		local routeCharacteristics = route.routeCharacteristics
		for i = 1, #routeCharacteristics do 
			score = score + (routeCharacteristics[i].isNearFarm and 1 or 0)
		end
		
		return score
	end
	
	local function scoreDistance(route)
		local points = route.points
		local score = 0
		for i = 2, #points do
			--util.trace("about to compute len for i=",i)
			--score = score + util.distance(points[i],points[i-1])
			-- unbundeled for performance
			local p0 = points[i-1]
			local p1 = points[i]
			local dx = p1.x-p0.x 
			local dy = p1.y-p0.y
			local dz = p1.z-p0.z 
			local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
			--assert(util.distance(points[i],points[i-1])==dist, " expected "..util.distance(points[i],points[i-1]).." but was "..dist)
			score = score + dist
		end
 
		return score
	end
	local function scoreEarthWorks(route)
		local lastHeight = baseRoute[0].p.z
		local lastPoint = baseRoute[0].p 
		local score = 0
		local routeCharacteristics = route.routeCharacteristics
		local points =  route.points
		local startAt = 1
		local endAt = #routeCharacteristics
		local threashold = 0 
		if params.isElevated or params.isUnderground then 
			startAt = 2
			endAt = endAt - 1
			threashold = 15
		end
		
		for i =startAt,  endAt do
			local point = points[i]
			 
			local dx = point.x-lastPoint.x 
			local dy = point.y-lastPoint.y
			local dz = point.z-lastPoint.z 
			-- util.trace(" at i=",i," scoring ", point, " against ", lastPoint, "maxGradFrac=",maxGradFrac)
			local maxDeltaZ = maxGradFrac *  math.sqrt(dx*dx + dy*dy + dz*dz)+threashold
			local terrainDeltaZ = routeCharacteristics[i].terrainHeight - lastHeight
			if math.abs(terrainDeltaZ) > maxDeltaZ then
				score = score + (math.abs(terrainDeltaZ)-maxDeltaZ)
				if terrainDeltaZ < 0 then
					lastHeight = lastHeight - maxDeltaZ
				else 
					lastHeight = lastHeight + maxDeltaZ
				end
			else 
				lastHeight = routeCharacteristics[i].terrainHeight
			end
			score = score + routeCharacteristics[i].extraEarthWorks
			lastPoint = point
		end
		
		return score
	end
	
	local function scoreWaterPoints(route)
		if not route.routeCharacteristics then debugPrint(route) end
		
		local score = 0
		--[[for i = 2, #route.points-1 do
			local priorPoint = route.points[i-1]
			local point = route.points[i]
			if route.routeCharacteristics[i].terrainHeight < 0 then 
				score = score + math.abs(route.routeCharacteristics[i].terrainHeight)
			end
			local vectorFromLast = point - priorPoint
			for i = 2, 11 do -- get a bit more granular detail 
				local testPoint = priorPoint + (i/12)*vectorFromLast
				local th = util.th(testPoint) 
				if th < 0 then 
					score = score + math.abs(th) 
				end
			end
			  
		end--]]
		local routeCharacteristics = route.routeCharacteristics
		for i = 1, #routeCharacteristics do 
			score = score + routeCharacteristics[i].waterScore
		end
		
		return score
	end
	
	local function scoreRouteNearbyTowns(route)
		if not route.routeCharacteristics then debugPrint(route) end
		local routeCharacteristics = route.routeCharacteristics
		local score = 0
		for i =1, #routeCharacteristics do
			score = score + routeCharacteristics[i].nearbyTownCount
		end
		
		return score
	end
	
	return { 
			 scoreRouteHeights , 
			 scoreDirectionHistory ,
			 scoreRouteNearbyEdges ,
			 scoreRouteFarms ,
			 scoreDistance,
			 scoreEarthWorks, 
			 scoreWaterPoints,
			 scoreRouteNearbyTowns
			}
end
local function getMinMaxScores(numberOfNodes)
	--if true then return nil end
	
	return  { -- influence the normalisation factors to avoid trivial scoring
		25*numberOfNodes, -- terrain height
		0, -- directionHistory (curvature)
		0, -- nearbyEdges
		0, -- nearFarms
		0, -- distance
		10*numberOfNodes, -- earthworks
		5*numberOfNodes, -- waterPoints
		0, -- nearbyTowns
	}
end

local function checkRouteForAlignmentToExistingTrack(route, numberOfNodes, params, boundingRoutes)
	if not (params.isTrack or params.isHighway) then 
		return 
	end
	local followRoutePoints = {}
	local startAt = 1 
	local finishAt = numberOfNodes
	local halfway = math.floor(numberOfNodes / 2)
	if #boundingRoutes[1].points > 0 then startAt = halfway end 
	if #boundingRoutes[2].points > 0 then finishAt = halfway end
	for i = startAt, finishAt do
		local p = route[i].p
		local t = route[i].t
		if p.x~=p.x or p.y~=p.y then 
			trace("WARNING! A NaN value was found at ",i," aborting")
			return 
		end
		--trace("Looking for a node near ",p.x, p.y)
		local nodeDetails  = util.searchForNearestNode(p, 25, 
			function(node) 
				local nodeId = node.id -- unbundeled for debug purposes
				local segs = util.getTrackSegmentsForNode(nodeId)
				return #segs>0
			end )
		if nodeDetails then
			for k, trackEdgeId in pairs(util.getTrackSegmentsForNode(nodeDetails.id)) do
				local edge = util.getEdge(trackEdgeId)
				local edgeTangent = util.v3(nodeDetails.id == edge.node0 and edge.tangent0 or edge.tangent1)
				local comparativeTangent = util.signedAngle(t, edgeTangent)
				local correctedComparativeTangent = math.abs(comparativeTangent)
				if correctedComparativeTangent > math.rad(90) then 
					correctedComparativeTangent = math.abs(math.rad(180-correctedComparativeTangent))
				end 
				trace("Inspecting edge, ",trackEdgeId," the comparativeTangent angle was ",math.deg(comparativeTangent), " the correctedComparativeTangent was ",math.deg(correctedComparativeTangent))
				local offset = params.edgeWidth
				if params.isHighway then 
					offset = 2*offset
				end
				if correctedComparativeTangent < math.rad(15) then
					local node0Pos = util.nodePos(nodeDetails.id)
					local positionVector = p - node0Pos
					local perpAngle = util.signedAngle(vec3.normalize(positionVector), vec3.normalize(edgeTangent))
					trace("The perpAngle was ",math.deg(perpAngle), " length of positionVector was ",vec3.length(positionVector))
					if math.abs(math.abs(perpAngle)-math.rad(90))<math.rad(15) or vec3.length(positionVector)<10  then 
						table.insert(followRoutePoints, { originalP = {p=route[i].p, t=route[i].t, t2=route[i].t2}, idx = i})
						local sign = perpAngle < 0 and  1 or -1
						route[i].p = util.nodePointPerpendicularOffset(node0Pos, sign*vec3.normalize(edgeTangent),offset)
						local tangentSign = math.abs(comparativeTangent)>math.rad(90) and -1 or 1
						local distToPrevious = util.distance(route[i].p, route[i-1].p)
						route[i].t=distToPrevious * tangentSign*vec3.normalize(edgeTangent)
						
						if params.isDoubleTrack then 
							local testP = util.nodePointPerpendicularOffset(route[i].p, route[i].t,offset )
							local dist = util.distance(node0Pos, testP)
							trace("Checking for double track clearance, dist was ",dist)
							if dist < 4 then 
								route[i].p = util.nodePointPerpendicularOffset(route[i].p , sign*vec3.normalize(edgeTangent),offset) -- double offset to allow space for double track
							end
						end 
						
						
						
						local distToNext = util.distance(route[i].p, route[i+1].p)
						route[i].t2 = distToNext * tangentSign * vec3.normalize(edgeTangent)
						
						trace("Found a point near track edge, ",node0Pos.x, node0Pos.y, " edge was ",trackEdgeId, " new pos is ",route[i].p.x, route[i].p.y," at ",i)
						route[i].frozen=true-- to freeze it
						route[i].followRoute = true
						break
					end
				end
			end
		end
		
	end
	local lastIdx = -1
	local consecutiveCount = 0
	local lastFollowRoutePoint
	local followRoutePointsIdxLookup = {}
	for i=1, #followRoutePoints    do 
		followRoutePointsIdxLookup[followRoutePoints[i].idx]=i
	end 
	for i=1, #followRoutePoints    do 
		if lastFollowRoutePoint then 
			if followRoutePoints[i].idx - lastIdx == 1 then 
				consecutiveCount = consecutiveCount + 1 
			else 
				if consecutiveCount < 2 then 
					trace("Cancelling follow route due to short length")
					for j = lastFollowRoutePoint.idx, lastFollowRoutePoint.idx-consecutiveCount, -1 do 
						trace("Resetting to original at ",j)
						route[j] = followRoutePoints[followRoutePointsIdxLookup[j]].originalP
						
					end
				end 
				consecutiveCount = 0
			end 
		end 
		lastIdx = followRoutePoints[i].idx 
		lastFollowRoutePoint = followRoutePoints[i]
	end 
	if lastFollowRoutePoint and  consecutiveCount < 2 then 
		trace("Cancelling follow route due to short length")
		for j = lastFollowRoutePoint.idx, lastFollowRoutePoint.idx-consecutiveCount, -1 do 
			trace("Resetting to original at ",j)
			route[j] = followRoutePoints[followRoutePointsIdxLookup[j]].originalP
			
		end
	end 
end
local function checkIfPointCollidesWithRoute(p0, p1, otherRoute, ignoreHeight, collectAllResults) 
	profiler.beginFunction("checkIfPointCollidesWithRoute")
	if not otherRoute.isInBox(p0) and not otherRoute.isInBox(p1) and not otherRoute.isInBox(0.5*(p0+p1)) then 
		if ignoreHeight then 
			trace("No collision possible, not in box")
		end 
		profiler.endFunction("checkIfPointCollidesWithRoute")
		return false 
	end
	local allResults 
	local minZoffset = 10
	--trace("Checking for collision with bounding route")
	for i =2, #otherRoute.points do
		local p2 = otherRoute.points[i-1].p
		local p3 = otherRoute.points[i].p
		local collision =util.checkFor2dCollisionBetweenPoints(p0, p1, p2, p3)
		if ignoreHeight then 
	--		trace("Checking for collision at i=",i,"found?",collision)
		end 
		if collision then 
			if otherRoute.isCollisionInevitable and not ignoreHeight then 
				local minZ = math.min(p0.z, p1.z)
				local minZ2 = math.min(p2.z, p3.z)
				local maxZ = math.max(p0.z, p1.z)
				local maxZ2 = math.max(p2.z, p3.z)
				if minZ > maxZ2 and minZ-maxZ2 >= minZoffset then 
					trace("checkIfPointCollidesWithRoute: collision initially found but z offset sufficient condition (1)")
					goto continue 
				end 
				if minZ2 < maxZ and maxZ-minZ2 >= minZoffset then 
					trace("checkIfPointCollidesWithRoute: collision initially found but z offset sufficient condition (2)")
					goto continue 
				end
			end
			collision.p0 = p2 
			collision.p1 = p3
			if collectAllResults then 
				if not allResults then 
					allResults = {}
				end 
				table.insert(allResults, collision)
			else 
				profiler.endFunction("checkIfPointCollidesWithRoute")
				return collision
			end 
		end
		::continue::
	end
	profiler.endFunction("checkIfPointCollidesWithRoute")
	if allResults then 
		return allResults
	end 
	return false
end
local function checkIfRouteCollides(baseRoute, boundingRoute, numberOfNodes, goingUp)
	local startAt = goingUp and 1 or numberOfNodes
	local endAt = numberOfNodes / 2
	local increment = goingUp and 1 or -1
	local priorP = goingUp and baseRoute[0].p or baseRoute[numberOfNodes+1].p 
	for i = startAt, endAt, increment do 
		local p = baseRoute[i].p 
		if  checkIfPointCollidesWithRoute(priorP, p, boundingRoute) then 	
			return true 
		end 
		priorP = p
	end 
	return false 
end 

local function newBox(p0, p1, margin)
	if not margin then margin = 0 end
	local margin = 0.5*vec2.distance(p0,p1)*(math.sqrt(2)-1)--TODO this could be more accurate, based on diagonal line at max offset
	local zMargin = 10
	local box = {
		xmin=math.min(p0.x, p1.x)-margin, 
		xmax=math.max(p0.x, p1.x)+margin, 
		ymin=math.min(p0.y, p1.y)-margin, 
		ymax=math.max(p0.y, p1.y)+margin
	}
	function box.toApiBox() 
		return {
			min = {
				x = box.xmin,
				y = box.ymin,
				z = math.min(p0.z-zMargin, p1.z-zMargin)
			},
			max = { 
				x = box.xmax,
				y = box.ymax,
				z = math.max(p0.z+zMargin, p1.z+zMargin)
			}	
		}
	end
	function box.isInBox(p)   
		return p.x >= box.xmin and p.x <= box.xmax and p.y >= box.ymin and p.y <= box.ymax
	end
	function box.setMinSize(size) 
		if box.xmax-box.xmin < size then 
			local offsetNeeded = (size-(box.xmax-box.xmin))/2
			box.xmax = box.xmax + offsetNeeded
			box.xmin = box.xmin - offsetNeeded
		end 
		if box.ymax-box.ymin < size then 
			local offsetNeeded = (size-(box.ymax-box.ymin))/2
			box.ymax = box.ymax + offsetNeeded
			box.ymin = box.ymin - offsetNeeded
		end 
		
	end 
	function box.drawBox() 	
		local name = "routeBox"
		table.insert(routesDrawn,name)
		local polygon = { 
			{ box.xmin, box.ymin},
			{ box.xmin, box.ymax},		
			{ box.xmax, box.ymax},
			{ box.xmax, box.ymin},
		
		}
		
		local drawColour = { 1, 1, 1, 1} 
		game.interface.setZone(name, {
			polygon=polygon,
			draw=true,
			drawColor = drawColour,
		})  
	end 
	
	return box
end 
local function emptyBoundingRoute()
	return {
			{	
				isInBox = function(p) return false end,
				points = {}
			},
			{	
				isInBox = function(p) return false end,
				points = {}
			},
		}
end 

local function checkForNearByRoutes(edge, params, numberOfNodes, ourBox)
	if not params.isTrack then 
		trace("Skipping bounding route check for non track route")
		return emptyBoundingRoute()
	end 
	profiler.beginFunction("checkForNearByRoutes")
	local p0 = edge.p0
	local p1 = edge.p1
	local t0 = edge.t0
	local t1 = edge.t1
	local boundingRoutes = {{points={}},{points={}}}
	--local ourBox = newBox(p0, p1, 200)
	for i, point in pairs({{p=p0, t=t0}, {p=p1,t=t1}}) do
		local edges = {}
		local p = point.p
		local t = vec3.normalize(point.t)
		boundingRoutes[i].isInBox = function(p) return false end
		local spurConnectStation = i==1 and params.station1SpurConnect or i==2 and params.station2SpurConnect 
		local trackNode = util.searchForNearestNode(p, 60, function(otherNode) 
			--trace("Inspecting node",otherNode.id,"for trackNode, tracksegments=",#util.getTrackSegmentsForNode(otherNode.id))
			return #util.getTrackSegmentsForNode(otherNode.id) > 1 end)
		local deadEndNode = util.searchForNearestNode(p, 10, function(otherNode) return #util.getTrackSegmentsForNode(otherNode.id) == 1 and not util.isFrozenNode(otherNode.id) end)
		local expandSearch = false
		local isRunningIntoStation = deadEndNode and util.isNodeConnectedToFrozenEdge(deadEndNode.id)
		if deadEndNode and not isRunningIntoStation then 
			trace("Discovered dead end node not attached to a frozen edge (station), assuming it is a junction node, found trackNode?",trackNode)
			expandSearch = true
			boundingRoutes[i].spurRoute=true
		end
		
		boundingRoutes[i].spurConnectStation = spurConnectStation
		--local nearbyNode = util.searchForNearestNode(p, 15)
		boundingRoutes[i].minOffset = params.trackWidth
		if spurConnectStation then 
			boundingRoutes[i].minOffset = 2*params.trackWidth
		end 
		local lastPoint
		local endPoints = {}
		local function addRoutePointsForStation(stationNode, isUpper)
			trace("addRoundPointsForStation: stationNode=",stationNode,"isUpper?",isUpper)
			local otherNode = util.getComplementaryStationNode(stationNode)
			if otherNode then  
				local stationNodePos = util.nodePos(stationNode)
				lastPoint = stationNodePos
				local stationTangent = util.nodePos(otherNode)-stationNodePos
				local length = vec3.length(stationTangent)
				local correctedLength = math.floor(length/40+0.5)*40
				local numSections = math.floor(correctedLength / 80)
				trace("Got other station length was",length,"correctedLength=",correctedLength,"numSections=",numSections)
				local stationNrml = vec3.normalize(stationTangent)
				for i = 80, numSections*80, 80 do 
					local p = i*stationNrml + stationNodePos 
					local node = util.searchForNearestNode(p)
					trace("collecting bounding routes, looking for a node near",p.x,p.y,"found?",node)
					if node then 
						local edge = util.getTrackSegmentsForNode(node.id)[1]
						trace("Adding the edge",edge,"as a virtual bounding route point")
						local p = util.nodePos(node.id)
						table.insert(endPoints, { p = p, t = p-lastPoint})
						lastPoint = p
					end 
				end 
				return true
			else 
				trace("WARNING! No other node found")
				return false
			end 
		end
		
		local function tryFindStationPath(stationId)
			trace("Trying to find spur route from trackNode",trackNode," and station",spurConnectStation)
			local answer = pathFindingUtil.findRailPathBetweenEdgeAndStation(util.getTrackSegmentsForNode(trackNode.id)[1], stationId)
			local isUpper = true 
			if #answer == 0 then 
				trace("Initially could not find path, trying inverted")
				answer = pathFindingUtil.findRailPathBetweenStationAndEdge(util.getTrackSegmentsForNode(trackNode.id)[1],stationId)
				if #answer == 0 then 
					trace("Still Could not find path, attempting from double track node")
					local trackNode2 = util.findDoubleTrackNode(trackNode.id)
					if trackNode2 then 
						answer = pathFindingUtil.findRailPathBetweenEdgeAndStation(util.getTrackSegmentsForNode(trackNode2)[1], stationId)
					end
				else 
					isUpper = false 
				end 				
			end
			local routeInfo = pathFindingUtil.getRouteInfoFromEdges(answer)
			if routeInfo and not routeInfo.firstFreeEdge then 
				trace("WARNING! no first free edge contained, station was",stationId,"trackNode was", trackNode.id)
				--routeInfo.firstFreeEdge = 1
			end 
			if routeInfo and routeInfo.firstFreeEdge and routeInfo.lastFreeEdge  then 	
				edges = {}
				for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
					table.insert(edges, routeInfo.edgesOnly[i])
				end 
				if #edges < 2 then 
					return false 
				end 
				local stationNode
				local lastNode 
				local lastEdge
				local lastEdgeId = isUpper and routeInfo.edges[routeInfo.firstFreeEdge].id or routeInfo.edges[routeInfo.lastFreeEdge].id
				if isUpper then 
					stationNode = util.isNodeConnectedToFrozenEdge(edges[#edges].node0) and edges[#edges].node0 or edges[#edges].node1 
					lastEdge = edges[1]
				 
					if lastEdge.node0 == edges[2].node1 or lastEdge.node0 == edges[2].node0 then 
						lastNode = lastEdge.node1 
					else 
						lastNode = lastEdge.node0
					end 
				else 
					stationNode = util.isNodeConnectedToFrozenEdge(edges[1].node0) and edges[1].node0 or edges[1].node1 
					lastEdge = edges[#edges] 
					if lastEdge.node0 == edges[#edges-1].node1 or lastEdge.node0 == edges[#edges-1].node0 then 
						lastNode = lastEdge.node1 
					else 
						lastNode = lastEdge.node0
					end 
				end 
				assert(util.isNodeConnectedToFrozenEdge(stationNode))
				for k = 1, 3 do -- need to add in a few more points to make sure we get to our start
					trace("Trying to find nextEdge in same direction using",lastEdgeId, lastNode)
					local nextEdgeId = util.findNextEdgeInSameDirection(lastEdgeId, lastNode)
					if not nextEdgeId then 
						trace("No nextEdgeId found")
						break
					end 	
					local nextEdge = util.getEdge(nextEdgeId)
					lastNode = nextEdge.node0 == lastNode and nextEdge.node1 or nextEdge.node0 
					lastEdgeId = nextEdgeId 
					trace("Adding to the end of the route edge",nextEdgeId)
					if isUpper then 
						table.insert(edges, 1, nextEdge)
					else 
						table.insert(edges, nextEdge)
					end 
					if #util.getTrackSegmentsForNode(lastNode)~=2 then 
						trace("Breaking at",lastNode)
						break
					end 	
				end 
				
				
				addRoutePointsForStation(stationNode, isUpper)
				boundingRoutes[i].isBoundingStationUpper = isUpper
				--edges = routeInfo.edgesOnly 
				boundingRoutes[i].minOffset = 6*params.trackWidth
				return true 
			else 
				trace("WARNING! Unable to find any nearby route")
				return false
			end 
		end
		if spurConnectStation  and trackNode then 
			--local otherNode =  util.findDoubleTrackNode(p, t) 
			tryFindStationPath(spurConnectStation)
			
		end 
		
		local connectedTrackAndStation
		if #edges==0 then
			local nearbyNode
			
			local tolerance = expandSearch and 3 or 1
			
			local startFrom = 1 
			local station = util.searchForFirstEntity(p, 250, "STATION", function(station) return station.carriers.RAIL end)
			trace("Found station ?",station," was cargo?",(station and station.cargo))
			if station and not station.cargo then 
				local terminalCount = #util.getStation(station.id).terminals
				trace("The terminal count was",terminalCount," for station",station.id)
				if terminalCount > 4 then 
					expandSearch = true 
					trace("Discovered a nearby station with high terminal count",terminalCount, " station was",station.id)
					local node = util.getNodeClosestToPosition(p)
					local nodeToTerminalMap = util.getFreeNodesToTerminalMapForStation(station.id)
					if node   then
						local terminalId  = nodeToTerminalMap[node]
						trace("Found terminalId",terminalId," for node",node)
						if terminalId == 1 or terminalId == terminalCount then 
							trace("Setting the startFrom to 3")
							startFrom = 3
							boundingRoutes[i].minOffset = 2*params.trackWidth
						end 
					end 
					
				end 
			end 
			local endAt = expandSearch and 6 or 3
			local searchPos = p 
			if params.isDoubleTrack and deadEndNode then 
				searchPos = util.v3fromArr(deadEndNode.position)
			end 
			for i = startFrom, endAt do 
				nearbyNode = util.findDoubleTrackNode(searchPos, t, i,tolerance)
				if nearbyNode and #util.getTrackSegmentsForNode(nearbyNode) > 1 then 
					break 
				end 
			end
			if not nearbyNode and startFrom > 1 then 
				trace("Did not found a neearbyNode, trying again")
				for i = 1, startFrom do 
					nearbyNode = util.findDoubleTrackNode(searchPos, t, i,tolerance)
					if nearbyNode and #util.getTrackSegmentsForNode(nearbyNode) > 1 then 
						break 
					end 
				end
			
			end 
			 
			if nearbyNode and #util.getTrackSegmentsForNode(nearbyNode) > 1 then	
				local vectorToNode = util.nodePos(nearbyNode)-p
				local angleToNode = util.signedAngle(vec3.normalize(vectorToNode), vec3.normalize(t))
				trace("Signed angle to other node was ",math.deg(angleToNode))
				if math.abs(math.abs(angleToNode)-math.rad(90)) < math.rad(20) then -- likely a parallel route 
					local excludeStartingJunctionEdges = not isRunningIntoStation
					connectedTrackAndStation = util.findAllConnectedFreeTrackEdgesAndStations(nearbyNode, true, vectorToNode,excludeStartingJunctionEdges) 	
					edges = connectedTrackAndStation.edges
					for j, station in pairs(connectedTrackAndStation.stations) do 
						local stationPosition = util.getStationPosition(station)
						trace("Inspecting station",station,"is in our box?",ourBox.isInBox(stationPosition))
						if ourBox.isInBox(stationPosition) then 
							if tryFindStationPath(station) then 	
								trace("Exiting as path found")
								break 
							end 
						end 
					end 
				end
				
			end
		end
		trace("checkForNearByRoutes: edges found",#edges,"trackNode?",trackNode,"isRunningIntoStation?",isRunningIntoStation,"deadEndNode?",deadEndNode)
		if #edges== 0 and trackNode and not isRunningIntoStation and deadEndNode then 
			trace("Still no edges found but did find a trackNode so attempting now")
			local vectorToNode = util.v3fromArr(trackNode.position)-p
			local oneLineOnly = true 
			local excludeStartingJunctionEdges = not isRunningIntoStation 
			connectedTrackAndStation = util.findAllConnectedFreeTrackEdgesAndStations(trackNode.id, oneLineOnly, vectorToNode,  excludeStartingJunctionEdges) 	
			edges = connectedTrackAndStation.edges
			for j, station in pairs(util.findAllConnectedFreeTrackEdgesAndStations(trackNode.id, false) .stations) do 
				local stationPosition = util.getStationPosition(station)
				trace("Inspecting station",station,"is in our box?",ourBox.isInBox(stationPosition))
				if ourBox.isInBox(stationPosition) then 
					if tryFindStationPath(station) then 	
						trace("Exiting as path found")
						break 
					end 
				end 
			end 
		end 
		if #edges > 1 then 
			local startNode = connectedTrackAndStation and connectedTrackAndStation.startNode or edges[1].node0 
			local endNode =  connectedTrackAndStation and connectedTrackAndStation.endNode or edges[#edges].node0 
			
			local p2 = util.nodePos(startNode)
			local p3 = util.nodePos(endNode)
			local collision =util.checkFor2dCollisionBetweenPoints(p0, p1, p2, p3,true)
			trace("For collision test the start and end node were ",startNode,endNode,"foundCollision?",collision,"had lastPoint?",lastPoint)
			
			trace("Checked for collision with other route, result was ", collision)
			--if spurConnectStation or not collision then -- collision not inevitable
				local alreadySeen = {}
				local box ={xmin=math.huge, xmax=-math.huge, ymin=math.huge, ymax=-math.huge}
				local firstEdge = edges[1]
				local firstNode = (firstEdge.node0 == edges[2].node1 or firstEdge.node0 ==edges[2].node0) and firstEdge.node1 or firstEdge.node0
				trace("The firstEdge was frozen?",util.isFrozenEdge(util.getEdgeIdFromEdge(firstEdge))," the startNode isNode0?",(firstNode == firstEdge.node0))
				local priorNode = firstNode 
				local minDistanceToNode = math.huge 
				for j, edge in pairs(edges) do 
					--if collision and j > 3 then -- obtain enough distance for a reasonable gradient to allow conflict resolution
					--	trace("Exiting bounding route early as collision is inevitable")	
					--	break 
				--	end
					local startAt = 1
					local endAt = 2 
					local increment = 1
					if edge.node1 == priorNode then 
						trace("Node collection Iterating backwards, edgeId=",util.getEdgeIdFromEdge(edge)) 
						startAt = 2
						endAt = 1
						increment = -1
					else 
						trace("Node collection Iterating forwards, edgeId=",util.getEdgeIdFromEdge(edge))
					end 
					local nodeAndTangentTable = util.getNodeAndTangentTable(edge)
					for k = startAt, endAt, increment do
						local nt = nodeAndTangentTable[k]
						if not alreadySeen[nt.node] and (not util.isFrozenNode(nt.node) or not isRunningIntoStation) and #util.getTrackSegmentsForNode(nt.node)<4 then 
							alreadySeen[nt.node]=true
							local p = util.nodePos(nt.node)
							minDistanceToNode = math.min(minDistanceToNode, vec2.distance(p, point.p))
							trace("Inserting point for node at ",#boundingRoutes[i].points," node was",nt.node)
							table.insert(boundingRoutes[i].points, { p = p, t=nt.tangent})
							box.xmin = math.min(box.xmin, p.x)
							box.xmax = math.max(box.xmax, p.x)
							box.ymin = math.min(box.ymin, p.y)
							box.ymax = math.max(box.ymax, p.y)
						end
						priorNode = nt.node
					end
					
				end
				for j, extraPoint in pairs(endPoints) do 
					local p = extraPoint.p 
					trace("Adding the extra point",p.x,p.y,"to the bounding route")
					if boundingRoutes[i].isBoundingStationUpper then 
						table.insert(boundingRoutes[i].points, extraPoint)
					else 
						table.insert(boundingRoutes[i].points, 1, extraPoint)
					end 
					box.xmin = math.min(box.xmin, p.x)
					box.xmax = math.max(box.xmax, p.x)
					box.ymin = math.min(box.ymin, p.y)
					box.ymax = math.max(box.ymax, p.y)
				end 
				if util.tracelog then debugPrint({boundingRouteBox=box}) end 
				local boxMargin = 100
				boundingRoutes[i].isInBox = function(p)   
					local res= p.x >= box.xmin-boxMargin 
					   and p.x <= box.xmax+boxMargin 
					   and p.y >= box.ymin-boxMargin 
					   and p.y <= box.ymax+boxMargin
					--trace("Checking if point",p.x,p.y,"lies inside box, result?",res)
					return res
				end				
			--end
			local originalMinOffset = boundingRoutes[i].minOffset 
			boundingRoutes[i].minOffset = math.max(originalMinOffset, minDistanceToNode-params.trackWidth)
			if isRunningIntoStation then 
				local station = util.getConstruction(isRunningIntoStation).stations[1]-- also doubles as teh constructionId 
				if util.isStationTerminus(station) and #util.getStation(station).terminals >= 4 then 
					trace("Discovered multiplatform station terminus, increasing minoffset")
					boundingRoutes[i].minOffset = math.max(originalMinOffset, minDistanceToNode) -- do not subtrack trackWidth, needed because our xpress crossover can put the outer route inside
				end 
			else 
				boundingRoutes[i].minOffset = math.max(originalMinOffset, minDistanceToNode*2)
			end			
			
			trace("The minDistanceToNode was",minDistanceToNode,"originalMinOffset was",originalMinOffset,"setting minOffset to",boundingRoutes[i].minOffset)
			boundingRoutes[i].ourBox = ourBox
			local testP = p + (i == 2 and -5 or 5)*t
			local perpT = util.rotateXY(t, math.rad(90))
			local testP1 = testP + 150*perpT 
			local testP2 = testP - 150*perpT 
			local leftHandCollision = checkIfPointCollidesWithRoute(testP, testP1, boundingRoutes[i], true)~=false
			local rightHandCollision = checkIfPointCollidesWithRoute(testP, testP2, boundingRoutes[i], true)~=false
			trace("Determining leftHandedness of bounding route, testP was at ",testP.x, testP.y," leftHandCollision=",leftHandCollision,"rightHandCollision=",rightHandCollision)
			--if collision then 
				local basicRoute =  routeEvaluation.buildBasicHermiteRoute(edge, numberOfNodes)
				local collisionCount = 0
				local priorP = edge.p0 
				for j = 1, numberOfNodes +1 do 
					
					local p = basicRoute[j].p
					if checkIfPointCollidesWithRoute(priorP, p, boundingRoutes[i]) then 
						collisionCount = collisionCount + 1
					end 
					priorP = p
				end 
				boundingRoutes[i].isCollisionInevitable = collisionCount%2==1
				trace("Set the flag for isCollisionInevitable to ",boundingRoutes[i].isCollisionInevitable,"based on the sampled route collisions of",collisionCount)
			--end 
			if boundingRoutes[i].isCollisionInevitable and lastPoint then 
				local distToTheir = util.distance(lastPoint, p )
				local ourTotalDist = util.distance(p0, p1)
				trace("Found collision but also with end point,checking if valid compring their end point dist",distToTheir,"with our distance",ourTotalDist)
				if distToTheir < ourTotalDist / 3 then -- heuristic, should be able to go around without much detour
					trace("Setting collision to false")
					boundingRoutes[i].isCollisionInevitable = false 
				end 
			end 
			if leftHandCollision == rightHandCollision then 
				trace("WARNING! Unable to determine whether the bound route is left or right handed at ",i, " aborting, testP1:",testP1.x,testP1.y,"testP2:",testP2.x,testP2.y)
			--assert(c )
				boundingRoutes[i].isInBox = function(p) return false end
				boundingRoutes[i].points = {}
			else 
				boundingRoutes[i].leftHanded = leftHandCollision
				trace("Bounding route for ",i," was leftHanded?",boundingRoutes[i].leftHanded)
			end
		end
		
	end
	if util.tracelog and params.isDebugResults then 
		debugPrint({boundingRoutes=boundingRoutes}) 
	end
	trace("Finished collecting boundingRoutes, number of points lower bounding route=",#boundingRoutes[1].points, " upper=",#boundingRoutes[2].points)
	profiler.endFunction("checkForNearByRoutes")
	return boundingRoutes
end


local function checkForCollisionWithBoundingRoutes(p0, p1, p, boundingRoutes) 
	return checkIfPointCollidesWithRoute(p0, p, boundingRoutes[1]) 
	or checkIfPointCollidesWithRoute(p1, p, boundingRoutes[2]) 
end

local function indexOfClosestPoint(p, boundingRoute) 
	local results = {}
	local lookup = {}
	for i, p2 in pairs(boundingRoute.points) do 
		local dist = vec2.distance(p, p2.p) 
		table.insert(results, dist)
		lookup[dist]=i
	end
	if #results == 0 then return end
	table.sort(results)
	return lookup[results[1]]
end

local function deconflictRouteWithIndustry(route, params, numberOfNodes)
	--checkForLooping(route,numberOfNodes, "begin deconflictRouteWithIndustry") 
	for i = 2,  numberOfNodes+1  do 
		local p0 = route[i-1].p 
		if i == 2 then 
			p0 = p0 + 4*vec3.normalize(route[i-1].t)
		end
		local p1 = route[i].p
		if i == numberOfNodes+1  then 
			p1 = p1 - 4*vec3.normalize(route[i].t)
		end
		local correction = util.checkProposedTrackSegmentForCollisionsAndAdjust(p0, p1, params.edgeWidth)
		local length = vec3.length(correction)
		if length > 0 and not route[i-1].followRoute and not route[i].followRoute then 
			trace("The correction length was ",length)
			if length < 0.5*params.targetSeglenth then 
				route[i-1].p=p0+correction
				if i<= numberOfNodes then 
					route[i].p=p1+correction
				end
				trace("The new points after deconfliction were ",route[i-1].p.x,route[i-1].p.y,"and",route[i].p.x,route[i].p.y)
			else 
				trace("Suppressing too much correction")
			end 
		end
	end
	--checkForLooping(route,numberOfNodes, "end deconflictRouteWithIndustry") 
end

local function checkIfRouteCanBeRealignedToWater(route, numberOfNodes, params)
	local isOverWater = false

	local bridgeSections = {} 
	for i = 1, numberOfNodes do 
		if util.isUnderwater(route[i].p)  then 
			if not isOverWater then 
				table.insert(bridgeSections, { 
					startIndex = i
				})
			
				isOverWater = true 
			end 
		else 
			if isOverWater then 
				bridgeSections[#bridgeSections].endIndex = i-1
				isOverWater = false
			end
		end		
	end 
	if #bridgeSections > 0 and not bridgeSections[#bridgeSections].endIndex then 
		bridgeSections[#bridgeSections].endIndex = numberOfNodes-1
	end
	
	local maxRealignmentOffset = 30
	for __, bridgeSection in pairs(bridgeSections) do
		local canBeRealignedLeft = false
		local canBeRealignedRight = false
		local offsetNeeded = 0
		for i = bridgeSection.startIndex, bridgeSection.endIndex do 
			local before = route[i-1]
			local this = route[i]
			local after = route[i+1]
			local t = vec3.normalize(route[i].t)
			local perpT = util.rotateXY(t, math.rad(90))
			local p = route[i].p
			for j = 5, maxRealignmentOffset, 5 do 
				local leftP = p + j * perpT
				local rightP = p - j * perpT
				if util.th(leftP) > 0 and util.th(leftP+30*t) > 0 and util.th(leftP-30*t) > 0 then
					local testPafter = after.p+j*perpT
					local testBefore = before.p+j*perpT
					local thisCanBeRealignedLeft = true
					for k = 1, 15 do 
						local midP1 = util.hermite(k/16, testBefore, before.t2, leftP, this.t).p
						local midP2 = util.hermite(k/16, leftP, this.t2, testPafter, after.t).p
						if util.th(midP1)<0 or util.th(midP2)<0 then 
							thisCanBeRealignedLeft = false 
							break
						end
					end
					if thisCanBeRealignedLeft then 
						offsetNeeded = math.max(offsetNeeded, j)
						canBeRealignedLeft = true 
						break
					end
				end
				if util.th(rightP) > 0  and util.th(rightP+30*t) > 0 and util.th(rightP-30*t) > 0 then
					local testPafter = after.p-j*perpT
					local testBefore = before.p-j*perpT
					local thisCanBeRealignedRight = true
					for k = 1, 15 do 
						local midP1 = util.hermite(k/16, testBefore, before.t2, leftP, this.t).p
						local midP2 = util.hermite(k/16, leftP, this.t2, testPafter, after.t).p
						if util.th(midP1)<0 or util.th(midP2)<0 then 
							thisCanBeRealignedRight = false 
							break
						end
					end
					if thisCanBeRealignedRight then 
						offsetNeeded = math.max(offsetNeeded, j)
						canBeRealignedRight = true 
						break
					end
				end
			end
		end
		trace("after checking bridgeSection for possible realignment , possible on left? ",canBeRealignedLeft, " possible  on right? ",canBeRealignedRight)
		if canBeRealignedLeft ~= canBeRealignedRight then
			for i = bridgeSection.startIndex, bridgeSection.endIndex do 
				local perpT = util.rotateXY(vec3.normalize(route[i].t), math.rad(90))
				local sign = canBeRealignedLeft and 1 or -1
				local pbefore = util.v3(route[i].p)
				route[i].p = route[i].p + sign * (offsetNeeded + params.edgeWidth) * perpT
				route[i].realigned = true
				trace("After realignment at i=",i," j=",j," pbefore=",pbefore.x,pbefore.y," after=",route[i].p.x, route[i].p.y)
			end
		end
	end

end

local function deconflictRouteWithBoundingRoutes(baseRoute, boundingRoutes, params, numberOfNodes, isBaseRoute,originalNumberOfNodes)
	
	profiler.beginFunction("deconflictRouteWithBoundingRoutes")
	local startP = baseRoute[0].p
	local endP = baseRoute[numberOfNodes+1].p
	local startT = baseRoute[0].t 
	local endT = baseRoute[numberOfNodes+1].t
	local theirLowerIndex = indexOfClosestPoint(startP, boundingRoutes[1])
	local theirUpperIndex = indexOfClosestPoint(endP, boundingRoutes[2])
	local lowerAdjustments = 0
	local upperAdjustments = 0
	local halfway = math.floor(numberOfNodes/2)
	local theirIndexOffSet = 0
	local maxCollisionIdx
	local ourPoints = { startP, endP}
	local ourPointsInv = {endP, startP }
	for i = 1, 2 do 
		local boundingRoute = boundingRoutes[1]
		if not boundingRoute.scoring then 
			boundingRoute.scoring = {} 
			--boundingRoute.terrainScores = {} 
			for j = 1, #boundingRoute.points do 
				local p = boundingRoute.points[j].p
				table.insert(boundingRoute.scoring, {
					idx = j ,
					scores = {
						util.scoreTerrainBetweenPoints(p, ourPointsInv[i]),
						util.distance(p, ourPointsInv[i]),
						util.distance(p, ourPoints[i]),
					}
				})
			end 
			if #boundingRoute.scoring > 0 then 
				boundingRoute.bestIdx = util.evaluateWinnerFromScores(boundingRoute.scoring).idx
				trace("The bounding route at ",i," had the bestIdx of ",boundingRoute.bestIdx)
			end 
		end 
	end 
	local minDistForZOffset = params.minZoffset / params.maxSafeTrackGradient
	
	local function validateNoCollision(p)
		local otherNode = util.getNodeClosestToPosition(p)
		if otherNode then 
			return not util.positionsEqual(p, util.nodePos(otherNode))
			--assert(not util.positionsEqual(p, util.nodePos(otherNode)),"position: "..p.x..","..p.y.." at otherNode"..otherNode)
		end
		return true 
	end 
	local function validateAdjustment(p, t) 
		if not validateNoCollision(p) then
			 return false 
		end
		if params.isDoubleTrack and vec3.length(t)>0 then 
			return validateNoCollision(util.doubleTrackNodePoint(p, t))
		end 
		return true 
	end 
	local theirIndexStart = indexOfClosestPoint(baseRoute[0].p,  boundingRoutes[1] )
	local theirStartHeight  = startP.z
	if theirIndexStart then 
		theirStartHeight = boundingRoutes[1].points[theirIndexStart].p.z
	end 
	local theirIndexEnd = indexOfClosestPoint(baseRoute[numberOfNodes+1].p,  boundingRoutes[2] )
	local theirEndHeight  = endP.z
	if theirIndexEnd then 
		theirEndHeight = boundingRoutes[2].points[theirIndexEnd].p.z
	end 
	local crossoverRotation = math.rad(15)
	local offsetChangeIdxs = {}
	
	--BEGIN LOWER
	
	for i = 1, numberOfNodes do 
		local lowerHalf = i < halfway
		local boundingRoute = boundingRoutes[1] 
		local before = baseRoute[i-1]
		local this = baseRoute[i]
		local after = baseRoute[i+1] 
		local p = this.p
		if boundingRoute.isCollisionInevitable   then
			local distance = vec2.distance(startP, p)
			local aboveThreshold = distance > minDistForZOffset
			
			local foundCollision = checkIfPointCollidesWithRoute(before.p, p, boundingRoute, true) or checkIfPointCollidesWithRoute(baseRoute[0].p, p, boundingRoute, true) 
			
			local theirIndex = indexOfClosestPoint(p, boundingRoute)
			if not theirIndex then 
				trace("No index found for bounding route, aborting") 
				break
			end
			 
			local pTheirs = boundingRoute.points[theirIndex].p
			local theirNode = util.getNodeClosestToPosition(pTheirs)
			local foundStationNode = boundingRoute.spurRoute and util.isNodeConnectedToFrozenEdge(theirNode)
			
			--trace("Checking distance",distance, " against", minDistForZOffset," at ",i," aboveThreshold?",aboveThreshold,"foundCollision?",foundCollision)
			if aboveThreshold and foundCollision or foundStationNode then
				trace("Inspecting the lower bounding route at ",i,"aboveThreshold?",aboveThreshold,"foundCollision?",foundCollision,"foundStationNode?",foundStationNode,"theirNode=",theirNode)
				maxCollisionIdx = i
				local goUnder = pTheirs.z > endP.z or foundStationNode
				if goUnder and startP.z - params.minZoffset < util.getWaterLevel() and (util.distanceToNearestWaterVertex(p) < 100 or util.isUnderwater(p)) then 
					goUnder = false
					trace("Altering go go over to avoid potential water")
				end 
				
				 local theirZ = goUnder and math.min(theirStartHeight, pTheirs.z) or math.max(theirStartHeight, pTheirs.z)
				 local count =0 
				for j = i+2, 1, -1 do 
					local fracOffset = math.min(j/ i,1)*(params.minZoffset +1)-- add one so that later checks can pass after rounding errors
					count = count + 1 
					if not baseRoute[j] then 
						break 
					end 
					local p = baseRoute[j].p
					local originalZ = p.z
					if goUnder then 
						local maxHeight = theirZ - fracOffset
						p.z = math.min(p.z, maxHeight)
						baseRoute[j].maxHeight = maxHeight
					else 
						local minHeight = theirZ + fracOffset
						p.z = math.max(p.z, minHeight)
						baseRoute[j].minHeight = minHeight
					end  
					baseRoute[j].overiddenHeight = p.z
					trace("Setting the height at ",j," to ",p.z,"based on fracOffset",fracOffset,"originalZ=",originalZ,"goUnder?",goUnder,"theirZ?",theirZ)
					if count > 5 then 
						trace("Exiting setting height")
						break
					end 
				end 
				--after.p.z =  p.z
				if foundStationNode then 
					maxCollisionIdx = i-1
				else 
					maxCollisionIdx = i+1
				end
				boundingRoute.crossoverPoint = maxCollisionIdx
				local offsetFromStart = i
				trace("Exiting deconfliction as collision inevitable at ",i,"for the lower route, set maxCollisionIdx=",maxCollisionIdx)
				
				 
		 
				if theirLowerIndex then 
					local theirOffset = math.abs(theirLowerIndex-theirIndex)
					local difference = math.abs(theirOffset-offsetFromStart)
					trace("Got difference of",difference,"theirOffset=",theirOffset,"theirLowerIndex=",theirLowerIndex)
					if difference > 2 then 
						trace("Cancelling collision avoidance")
						maxCollisionIdx = nil
					end 
				
				end 
				break
			end
		end
		if i > 5 and not boundingRoute.isInBox(p) and not boundingRoute.isInBox(before.p) and not boundingRoute.isInBox(after.p) and not boundingRoute.isCollisionInevitable then 
			trace("Exiting lower bounding route check at i=",i, " not in box")
			break 
		end
		local collision = checkIfPointCollidesWithRoute(before.p, p, boundingRoute)
		if debugResults then 
			trace("Check if point collides with route, at i=",i,"found",collision)
		end
		if collision or checkIfPointCollidesWithRoute(baseRoute[0].p, p, boundingRoute) then
			maxCollisionIdx = i
			trace("setting the maxCollisionIdx to",i)
		end
	end 
	if maxCollisionIdx and theirLowerIndex then
		local lastOffset 
		local boundingRoute = boundingRoutes[1] 
		local theirMaxIndex
		local goingUp = theirLowerIndex < #boundingRoute.points/2
		local lastPoint = baseRoute[numberOfNodes+1].p
		if goingUp then 
			for i = theirLowerIndex+1, #boundingRoute.points do 
				local angle = util.signedAngle(boundingRoute.points[i].p-boundingRoute.points[i-1].p, lastPoint-boundingRoute.points[i].p)
				trace("At i=",i," the angle was ",math.deg(angle), " goingUp=",goingUp, "theirLowerIndex=",theirLowerIndex)
				if math.abs(angle)> math.rad(60) then 
					theirMaxIndex = i -1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on angle condition on lower route. goingup?",goingUp)
					break 
				end 
				
				if util.distance(boundingRoute.points[i-1].p, lastPoint) < util.distance(boundingRoute.points[i].p, lastPoint) then	
					theirMaxIndex = i -1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on distance condition on lower route. goingup?",goingUp)
					break 
				end
			end
			if not theirMaxIndex then theirMaxIndex = #boundingRoute.points end 			
		else 
			for i = theirLowerIndex-1, 1, -1 do 
				local angle = util.signedAngle(boundingRoute.points[i].p-boundingRoute.points[i+1].p, lastPoint-boundingRoute.points[i].p)
				trace("At i=",i," the angle was ",math.deg(angle), " goingUp=",goingUp, "theirLowerIndex=",theirLowerIndex)
				if math.abs(angle)> math.rad(60) then 
					theirMaxIndex = i +1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on angle condition on lower route. goingup?",goingUp)
					break 
				end 
			
			
				if util.distance(boundingRoute.points[i+1].p, lastPoint) < util.distance(boundingRoute.points[i].p, lastPoint) then	
					theirMaxIndex = i +1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on distance condition on lower route. goingup?",goingUp)
					break 
				end
			end 
			if not theirMaxIndex then theirMaxIndex = 1 end 
		end
		local alreadySeenIndexes = {}
		theirMaxIndex = math.max(theirMaxIndex, 6)
		local seenBestIdx = false
		if theirLowerIndex == boundingRoute.bestIdx then 
			trace("theirLowerIndex was seen as the bestIdx therefore setting to true")
			seenBestIdx = true
		end 
		trace("Their max index was", theirMaxIndex)
		maxCollisionIdx = math.min(maxCollisionIdx, numberOfNodes)
		local startAt = 1 
		local isJunctionSpur = boundingRoute.minOffset > 20
		if isJunctionSpur then 
			startAt = 2
		end 
		for i = startAt, maxCollisionIdx do 
			trace("Deconflicting bounding route from base route")
			local theirIndex 
			local before = baseRoute[i-1]
			local this = baseRoute[i]
			local after = baseRoute[i+1]
			local p = this.p
			if goingUp then 
				theirIndex = theirLowerIndex + i
			else 
				theirIndex = theirLowerIndex - i  -- theirIndex == theirLowerIndex at i== 0
			end
			theirIndex = theirIndexOffSet + theirIndex
		

			trace("at i = ",i," initial lookup of their bounding route point at ", theirIndex, " theirLowerIndex=",theirLowerIndex) 
			if not boundingRoute.points[theirIndex] then 
				trace("WARNING! a confliction was detected by no point was found!")
				break 
			end
			local theirNode = util.getNodeClosestToPosition(boundingRoute.points[theirIndex].p)
			if #util.getTrackSegmentsForNode(theirNode)==4 then 
				trace("Discovered crossover node at theirIndex=",theirIndex," shifting to next instead")
				local indexOffset =  theirLowerIndex == 1 and 1 or -1
				theirIndexOffSet = theirIndexOffSet + indexOffset
				theirIndex = theirIndex + indexOffset
			end
			 
			trace("at i = ",i," looking up their bounding route point at ", theirIndex, " theirLowerIndex=",theirLowerIndex)
			if theirIndex <=0 or theirIndex > #boundingRoute.points then 
				trace("No more bounding route points available")
				break 
			end
			local pTheirs = boundingRoute.points[theirIndex].p 
			if theirIndex == boundingRoute.bestIdx then 
				seenBestIdx = true
			end 
			--[[if util.distance(before.p + tTheirs, pTheirs) < util.distance(before.p - tTheirs, pTheirs) then 
				trace("Inverting tTheirs based on distance")
				tTheirs = -1*tTheirs
			end]]--
			local dist = util.distance(pTheirs, before.p)
			trace("Distance between pTheirs and before was ",dist)
			if dist > 2*params.targetSeglenth or dist < 0.5*params.minSeglength then 
				theirIndex = indexOfClosestPoint(p, boundingRoute)
				pTheirs = boundingRoute.points[theirIndex].p 
				dist = util.distance(pTheirs, before.p)	
				if util.distance(pTheirs, baseRoute[0].p)<15 then 
					trace("WARNING! new pTheirs is too close to the start")
					dist = 0 --force abort
				end 
				trace("Unexpected high distance looking up dist to next closest =",dist, " theirIndex=",theirIndex)
				if dist > 3*params.targetSeglenth or dist < 0.5*params.minSeglength or alreadySeenIndexes[theirIndex] then
					trace("Aborting")
					break 
				end
			end
			local tTheirs = boundingRoute.points[theirIndex].t
			--local relativeTangentAngle = util.signedAngle(this.t, tTheirs)
			local relativeTangentAngle = util.signedAngle(pTheirs-before.p, tTheirs)
			alreadySeenIndexes[theirIndex]= true
			local perpSign = 1
			if math.abs(relativeTangentAngle) > math.rad(90) then
				trace("Inverting tTheirs based on relativeTangentAngle")
				tTheirs = -1*tTheirs
				--perpSign = -1
			end
			local negative = false
			local offset = boundingRoute.minOffset
			if params.isDoubleTrack then 
				offset = offset + 0.5*params.trackWidth
			elseif params.isQuadrupleTrack then 
				trace("Increasing offset for quadruple track")
				offset = offset + 1.5*params.trackWidth
			end
			if boundingRoute.leftHanded then 
				offset = -offset 
			end
			local isFrozenNode = util.isFrozenNode(util.getNodeClosestToPosition(pTheirs))
			if boundingRoute.spurConnectStation or isFrozenNode then 
				offset = 4*offset 
			end
			if lastOffset then 
				offset = lastOffset 
			end
			if boundingRoute.isCollisionInevitable then 
				local increment = offset>0 and 5 or -5
				if math.abs(i-maxCollisionIdx) <=3 then 
					offset = offset + increment
					offsetChangeIdxs[i]=true
					trace("Incrementing the offset by",increment,"to get",offset,"lower route")
				end
			end 

			--[[if #util.getStreetSegmentsForNode(util.searchForNearestNode(pTheirs, 20).id) > 0 then 
				trace("Detected grade crossing, shifting offset")
				offset = offset<0 and math.min(offset, -20) or math.max(offset, 20)
			end --]]
			local p = util.nodePointPerpendicularOffset(pTheirs, perpSign* tTheirs, offset)
			if i==1 and checkIfPointCollidesWithRoute(baseRoute[i-1].p, p, boundingRoute) then 
				trace("Collision detected adjusting offset")
				local testP = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, -offset)
				if not checkIfPointCollidesWithRoute(baseRoute[i-1].p, testP, boundingRoute)  then 
					--trace("Inverting tTheirs based on collision")
					--tTheirs = -1*tTheirs
					--p = testP
				else 
					trace("WARNING! Collision was not resolved")
				end 
			end 
		--[[	if checkIfPointCollidesWithRoute(baseRoute[i-1].p, testP, boundingRoute)
				and checkIfPointCollidesWithRoute(baseRoute[i-1].p, util.nodePointPerpendicularOffset(pTheirs, tTheirs, 2*offset), boundingRoute) then -- check at twice the offset not to get a false result from the straight line approximation then 
				p = util.nodePointPerpendicularOffset(pTheirs, tTheirs, -offset)
				negative = true
			else 
				p = testP
			end]]--
			local theirDoubleTrackNode = util.findClosestDoubleTrackNode(p, pTheirs, tTheirs)
			local distToTheirDoubleTrackNode =  theirDoubleTrackNode and util.distance(p, util.nodePos(theirDoubleTrackNode))
			trace("Found theirDoubleTrackNode?",theirDoubleTrackNode, "distToTheirDoubleTrackNode=",distToTheirDoubleTrackNode)
			if theirDoubleTrackNode and   distToTheirDoubleTrackNode < 1  then 
				
				offset = offset <0 and math.min(offset,-2*params.trackWidth) or math.max(offset, 2*params.trackWidth)
				trace("Discovered collision with double track node increasing distance, distToTheirDoubleTrackNode=",distToTheirDoubleTrackNode, " newOffset=",offset)
				p = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, offset)
			end
			local doubleTrackOffset = 0 
--			if params.isDoubleTrack and boundingRoute.leftHanded then 
			--[[if params.isDoubleTrack  then 
				trace("Applying additional shift to allow for double track node")
				doubleTrackOffset = -0.5*params.trackWidth
				p = util.nodePointPerpendicularOffset(pTheirs,perpSign* tTheirs, offset+doubleTrackOffset)
			end]]--
			
			local angleToLast = math.abs(util.signedAngle(p-before.p, before.t2))
			trace("Angle to last was ",math.deg(angleToLast),"relativeTangentAngle=",math.deg(relativeTangentAngle))
			if angleToLast > math.rad(60) and not boundingRoute.isCollisionInevitable then 
				trace("Detected sharp angle change, aborting")
				 break;
			end 
			
			local followRoute = math.abs(offset) < 25
			if  
				  (goingUp and theirMaxIndex-theirIndex <= 3 or not goingUp and theirIndex-theirMaxIndex <=3) and not boundingRoute.isCollisionInevitable
			then 
				trace("Detected moving away from destination, attempting to correct (2), theirIndex=", theirIndex, " theirMaxIndex=",theirMaxIndex)
				local oldOffset = offset 
				local pOld = p
				if math.abs(offset) < 100 then 
					offset = offset + (offset<0 and -5 or 5) 
					offsetChangeIdxs[i]=true
				end
				p = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, offset)
				--tTheirs = p-before.p  
				local angleToLastNew = math.abs(util.signedAngle(before.p-p, before.t2))
				if angleToLastNew > math.rad(30) and angleToLastNew > angleToLast then
					trace("Reverting changes as it too sharp angl",math.deg(angleToLastNew),math.deg(angleToLast))
					p = pOld
					offset = oldOffset
				end 
				
				--followRoute = math.abs(offset) < 50
				local priorValue = params.smoothFrom
				params.smoothFrom = followRoute and  math.max(params.smoothFrom, i-1) or math.min(params.smoothFrom, i-1)
				trace("Set smoothFrom = ",params.smoothFrom," at ",i," priorValue=",priorValue) 
			else 
				params.smoothFrom = math.max(params.smoothFrom, i)
				trace("Set smoothFrom = ",params.smoothFrom," at ",i) 
			end
			local dist1 = util.distance(p, before.p)
			local dist2 = util.distance(p, after.p)
			
			trace("deconflicting base route with bounding route at ",i, " collision at ", this.p.x, this.p.y," new point ",p.x,p.y, " theirs=",tTheirs.x,tTheirs.y, " this.t=",this.t.x,this.t.y, " relativeTangentAngle=",math.deg(relativeTangentAngle)," offset=",offset, " dist1=",dist1,"dist2=",dist2,"isFrozenNode?",isFrozenNode)
			local t = dist1*vec3.normalize(tTheirs)
			local t2 = dist2 * vec3.normalize(tTheirs)
			before.t2 = dist1*vec3.normalize(before.t2)
			after.t = dist2*vec3.normalize(after.t)
			assert(t.x==t.x)
			assert(t2.x==t2.x)
			if not validateAdjustment(p, t) then 
				p.z = p.z -10 
			end
			if baseRoute[i].overiddenHeight then 
				baseRoute[i].theirHeight = p.z
				p.z = baseRoute[i].overiddenHeight
			end 
			local frozen = followRoute and not boundingRoute.isCollisionInevitable
			if followRoute then 
				lowerAdjustments = lowerAdjustments + 1
			end
		--	if boundingRoute.isCollisionInevitable and  (math.abs(baseRoute[i].p.z-pTheirs.z) >= params.minZoffset and i==maxCollisionIdx-1 or i == maxCollisionIdx) then 
			if boundingRoute.isCollisionInevitable and  i == maxCollisionIdx then 
				trace("Breaking the bounding route at",i)
				local goUnder = pTheirs.z > baseRoute[i].p.z
				if math.abs(baseRoute[i].p.z-pTheirs.z) < params.minZoffset and i == maxCollisionIdx then
					trace("WARNING! Detected insufficint clearance")
					if goUnder then 
						baseRoute[i].p.z = pTheirs.z - params.minZoffset
						baseRoute[i].maxHeight=baseRoute[i].p.z
						baseRoute[i+1].p.z=math.min(baseRoute[i+1].p.z,baseRoute[i].p.z)
						baseRoute[i].minHeight=nil
					else 
						baseRoute[i].p.z = pTheirs.z + params.minZoffset
						baseRoute[i].minHeight=baseRoute[i].p.z
						baseRoute[i+1].p.z=math.max(baseRoute[i+1].p.z,baseRoute[i].p.z)
						baseRoute[i].maxHeight=nil
					end 
					baseRoute[i].overiddenHeight =baseRoute[i].p.z 
					trace("Attempted to compensate using new height",baseRoute[i].p.z)
					local count = 0
					for j = i-1, 1,-1 do 
					
						count = count+1
					 
						if count > 4 then 
							if baseRoute[j].theirHeight then 
								baseRoute[j].p.z =baseRoute[j].theirHeigh
							end 
							baseRoute[j].overiddenHeight=nil
							baseRoute[j].maxHeight = nil
							baseRoute[j].minHeight = nil
						else 
							local dist = vec2.distance(baseRoute[i].p,baseRoute[j].p)
							local maxDeltaZ=  dist*params.maxGradient
							if goUnder then 
								local maxHeight = baseRoute[i].maxHeight+maxDeltaZ
								baseRoute[j].maxHeight = maxHeight --math.min(baseRoute[j].maxHeight, maxHeight)
								baseRoute[j].minHeight = nil 
								baseRoute[j].p.z = math.min(baseRoute[j].p.z , baseRoute[j].maxHeight)
								baseRoute[j].overiddenHeight = baseRoute[j].p.z
							else 
								local minHeight = baseRoute[i].minHeight-maxDeltaZ
								baseRoute[j].minHeight = minHeight--math.max(baseRoute[j].minHeight, minHeight)
								baseRoute[j].maxHeight = nil 
								baseRoute[j].p.z = math.max(baseRoute[j].p.z , baseRoute[j].minHeight)
								baseRoute[j].overiddenHeight = baseRoute[j].p.z
							end 
						end 
					end 
				end 
				
				local subNodeCount = 1+numberOfNodes-i
				local sign = boundingRoute.leftHanded and 1 or -1
				before.t2 = util.rotateXY(before.t2, sign*crossoverRotation)
				before.t = util.rotateXY(before.t, sign*crossoverRotation)
				
				local inputEdge = { p0=before.p, t0=before.t2, p1=endP, t1=endT}
				util.applyEdgeAutoTangents(inputEdge)
				local f=1/subNodeCount
				local s = util.solveForPositionHermiteFraction(f, inputEdge)
				trace("Set the position from hermite solve to",s.p.x,s.p.y,"was",p.x,p.y,"dist=",util.distance(p,s.p),"fraction was",f,"p0=",inputEdge.p0.x,inputEdge.p0.y,"p1=",inputEdge.p1.x,inputEdge.p1.y)
				if util.distance(p,s.p) > 100 then 
					trace("WARNING! Large distance detected")				
				end 
				--local subRoute = routeEvaluation.buildBasicHermiteRoute(inputEdge,1+numberOfNodes-i)
				local height = baseRoute[i].overiddenHeight or baseRoute[i].p.z 
				p = s.p 
				t = dist1*vec3.normalize(s.t1) 
				t2 = dist1*vec3.normalize(s.t2) --NB use dist1 here to avoid large excusions
				t.z =0 
				t2.z = 0
				baseRoute[i].p = p -- assignment here necessary to get the route solve below to work
				baseRoute[i].t = t 
				frozen = true 
				if i == maxCollisionIdx then 
				
					for smoothing = 1, 2 do 
						local count = 0
						for j = i-1, 1,-1 do 

							if count > 4 then 
								if baseRoute[j].theirHeight then 
									baseRoute[j].p.z =baseRoute[j].theirHeigh
								end 
								baseRoute[j].overiddenHeight=nil
								baseRoute[j].maxHeight = nil
								baseRoute[j].minHeight = nil 
							else 
								local inputEdge =  { p1 = baseRoute[j+1].p, p0 = baseRoute[j-1].p, t1=baseRoute[j+1].t , t0 = baseRoute[j-1].t, } 
								util.applyEdgeAutoTangents(inputEdge)
								local p = baseRoute[j].p
								local s = util.solveForPositionHermiteFraction(0.5, inputEdge)
								if not baseRoute[j].frozen then 
									count = count + 1
									baseRoute[j].p=s.p 
									baseRoute[j].t=s.t1 
									baseRoute[j].t2=s.t2
									trace("Resolving position at ",j,"for the hermite curve at",p.x,p.y,"adjusted to ",s.p.x,s.p.y,s.p.z,"tangent=",s.t1.x,s.t1.y,s.t1.z)
								end
							end 
						end 
					end 
					boundingRoute.crossoverPoint = maxCollisionIdx
					lowerAdjustments = i
				end 

				trace("Breaking the bounding route at",i,"using subNodeCount=",subNodeCount,"at p=",p.x,p.y,p.z,"at lower, t=",t.x,t.y,t.z)
			end  
			assert(t.x==t.x)
			baseRoute[i] = {p=p, t=t,  t2=t2, frozen=frozen ,followRoute =followRoute or boundingRoute.isCollisionInevitable, minHeight=baseRoute[i].minHeight, maxHeight=baseRoute[i].maxHeight, overiddenHeight=baseRoute[i].overiddenHeight}
			if i == 1 then 
				local maxAngle = math.rad(params.maxInitialTrackAngleStart) 
				local startAngle = math.abs(util.signedAngle(baseRoute[1].p-baseRoute[0].p, baseRoute[0].t2))
				if startAngle > maxAngle then 
					trace("WARNING! After doing deconfliction the angle of",math.deg(startAngle),"exceeded",params.maxInitialTrackAngleStart,"correcting")
					params.maxInitialTrackAngleStart = math.deg(startAngle) -- prevents the route smoothing conflicting with us
				end 
			end
			if isJunctionSpur and i == 2 then 
				local inputEdge =  { p1 = baseRoute[i].p, p0 = baseRoute[i-2].p, t1=baseRoute[i].t , t0 = baseRoute[i-2].t, } 
				util.applyEdgeAutoTangents(inputEdge)
				local s = util.solveForPositionHermiteFraction(0.5, inputEdge)
				baseRoute[i-1].p=s.p
				baseRoute[i-1].t=s.t1
				baseRoute[i-1].t2=s.t2
			end 

			trace("At i=",i,"lowerAdjustments=",lowerAdjustments," for boundingRoute, p=",baseRoute[i].p.x,baseRoute[i].p.y)
			lastOffset = offset
			if math.abs(offset) >= 50 and not boundingRoute.isCollisionInevitable then
				break 
			end
			if i >3 and seenBestIdx and not boundingRoute.isCollisionInevitable then 
				trace("Exiting bounding route check as already seen bestIdx at ",i, " last point was ",baseRoute[i].p.x, baseRoute[i].p.y, " followRoute?",followRoute)
				break 
			end
			if not boundingRoute.isCollisionInevitable and not isFrozenNode then 
				trace("Checking if deconfliction still required")
				if isBaseRoute then 
					local subRoute = routeEvaluation.buildBasicHermiteRoute({ p0=p, t0=t, p1=endP, t1=endT},numberOfNodes-i)
					local goingUp = true 
					if not checkIfRouteCollides(subRoute, boundingRoute, numberOfNodes-i, goingUp) then 
						trace("Exiting at i=",i,"as a collision should no longer occur from the base route, goingUp=",goingUp)
						break
					end 
				else 
					local hasCollision = false 
					local priorP=baseRoute[i].p 
					for j = i+1, numberOfNodes do 
						local p = baseRoute[j].p 
						if  checkIfPointCollidesWithRoute(priorP, p, boundingRoute) then 	
							hasCollision = true 
							break 
						end 
						priorP = p
					end 
					if not hasCollision then 
						trace("Exiting at i=",i,"as a collision should no longer occur from the calculated route, goingUp=",true) 
						break
					end 
					
				end 
			end 
		end
	end
	--END LOWER
	--BEGIN UPPER
	
	local theirIndexOffSet = 0
	local minCollisionIdx
	local maxIdx
	local seenBestIdx = false 
	for i = numberOfNodes, 1, -1 do  
		local boundingRoute =     boundingRoutes[2]
		local before = baseRoute[i+1]
		local this = baseRoute[i]
		local after = baseRoute[i-1]
		local p = this.p
	--[[	if i < numberOfNodes- 3 and boundingRoute.isCollisionInevitable then
			trace("Exiting deconfliction as collision inevitable")
			break 
		end--]]
		if boundingRoute.isCollisionInevitable   then
			local distance = vec2.distance(endP, p)
			local aboveThreshold = distance > minDistForZOffset
			local foundCollision = checkIfPointCollidesWithRoute(before.p, p, boundingRoute, true) or checkIfPointCollidesWithRoute(baseRoute[numberOfNodes+1].p, p, boundingRoute, true)
			--trace("Checking distance",distance, " against", minDistForZOffset," at ",i," aboveThreshold?",aboveThreshold,"found collision?",foundCollision)
			local theirIndex = indexOfClosestPoint(p, boundingRoute)
			if not theirIndex then 
				trace("No index found for bounding route, aborting") 
				break
			end
			 
			local pTheirs = boundingRoute.points[theirIndex].p
			local theirNode = util.getNodeClosestToPosition(pTheirs)
			local foundStationNode = boundingRoute.spurRoute and util.isNodeConnectedToFrozenEdge(theirNode)
			if aboveThreshold and foundCollision or foundStationNode then
				trace("Inspecting the upper bounding route at ",i,"aboveThreshold?",aboveThreshold,"foundCollision?",foundCollision,"foundStationNode?",foundStationNode,"theirNode=",theirNode)
				minCollisionIdx = i
			
			
				local goUnder = pTheirs.z > endP.z or foundStationNode
				if goUnder and endP.z - params.minZoffset < util.getWaterLevel() and (util.distanceToNearestWaterVertex(p) < 100 or util.isUnderwater(p)) then 
					goUnder = false
					trace("Altering go go over to avoid potential water")
				end 
				local theirZ = goUnder and math.min(theirEndHeight, pTheirs.z) or math.max(theirEndHeight, pTheirs.z)
				local count = 0
				for j = i-2, numberOfNodes do 
					local fracOffset = math.min((numberOfNodes+1-j) / (numberOfNodes+1-i), 1)*(params.minZoffset +1)
					count = count + 1
					if not baseRoute[j] then 
						break 
					end
					local p = baseRoute[j].p
					local originalZ = p.z
					if goUnder then 
						local maxHeight = theirZ - fracOffset
						p.z = math.min(p.z, maxHeight)
						baseRoute[j].maxHeight = maxHeight
					else 
						local minHeight = theirZ + fracOffset
						p.z = math.max(p.z, minHeight)
						baseRoute[j].minHeight = minHeight
					end 
					baseRoute[j].overiddenHeight = p.z
					trace("Setting the height at ",j," to ",p.z,"based on fracOffset",fracOffset,"originalZ=",originalZ,"goUnder?",goUnder)
					if count > 5 then 
						trace("Exiting setting height")
						break
					end 
				end
				--if checkIfPointCollidesWithRoute(before.p, p, boundingRoute, true) or checkIfPointCollidesWithRoute(baseRoute[numberOfNodes+1].p, p, boundingRoute, true)  then 
					if foundStationNode then 
						minCollisionIdx = i+1
					else 
						minCollisionIdx = i-1
					end 
					boundingRoute.crossoverPoint = maxCollisionIdx
					local offsetFromEnd = numberOfNodes-minCollisionIdx
					trace("Exiting deconfliction as collision inevitable at ",i, "on the upper route, setting minCollisionIdx=",minCollisionIdx,"offset from end=",offsetFromEnd)
					 
					if theirUpperIndex then 
						local theirOffset = math.abs(theirUpperIndex-theirIndex)
						local difference = math.abs(theirOffset-offsetFromEnd)
						trace("Got difference of",difference,"theirOffset=",theirOffset,"theirUpperIndex=",theirUpperIndex)
						if difference > 2 then 
							trace("Cancelling collision avoidance")
							minCollisionIdx = nil
						end 
					
					end 
					break 
				--end				
				 
			end
		end
		
		
		if i< numberOfNodes -5 and not boundingRoute.isInBox(p) and not boundingRoute.isInBox(before.p) and not boundingRoute.isInBox(after.p) and not boundingRoute.isCollisionInevitable then 
			trace("Exiting check for upper bounding route at ",i," was not in box")
			break 
		end
	
		local collision = checkIfPointCollidesWithRoute(before.p, p, boundingRoute)
		if debugResults then 
			trace("Check if point collides with route, at i=",i,"found",collision)
		end 
		if collision or checkIfPointCollidesWithRoute(baseRoute[numberOfNodes+1].p, p, boundingRoute) then
			trace("Setting the minCollisionIdx to",i )
			minCollisionIdx = i
		end
		
	end 
 	trace("Collision with bounding route? minCollisionIdx=",minCollisionIdx,"maxCollisionIdx=",maxCollisionIdx)
	if minCollisionIdx and theirUpperIndex and minCollisionIdx > 0 then 
		local theirMaxIndex
		local boundingRoute =     boundingRoutes[2]
		local goingUp = theirUpperIndex < #boundingRoute.points/2
		if goingUp then 
			for i = theirUpperIndex+1, #boundingRoute.points do 
			
				local angle = util.signedAngle(boundingRoute.points[i].p-boundingRoute.points[i-1].p, baseRoute[0].p-boundingRoute.points[i].p)
				trace("At i=",i," the angle was ",math.deg(angle), " goingUp=",goingUp, "theirUpperIndex=",theirUpperIndex)
				if math.abs(angle)> math.rad(60) then 
					theirMaxIndex = i -1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on angle condition on upper route. goingup?",goingUp)
					break 
				end 
			
				if util.distance(boundingRoute.points[i-1].p, baseRoute[0].p) < util.distance(boundingRoute.points[i].p, baseRoute[0].p) then	
					theirMaxIndex = i -1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on distance condition on upper route. goingup?",goingUp)
					break 
				end
			end
			if not theirMaxIndex then theirMaxIndex = #boundingRoute.points end 			
		else 
			for i = theirUpperIndex-1, 1, -1 do 
				local priorP = boundingRoute.points[i+1].p
				local p = boundingRoute.points[i].p
				local angle = util.signedAngle(p-priorP, baseRoute[0].p-p)
				local angle2 = util.signedAngle(priorP-p, baseRoute[0].p-p)
				local angle3 = util.signedAngle(p-priorP, p-baseRoute[0].p)
				trace("At i=",i," the angle was ",math.deg(angle), " goingUp=",goingUp, "theirUpperIndex=",theirUpperIndex," alternative angle =",math.deg(angle2)," angle3=",math.deg(angle3))
				if math.abs(angle)> math.rad(60) then 
					theirMaxIndex = i +1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on angle condition on upper route. goingup?",goingUp)
					break 
				end 
				local priorPDistance = util.distance(priorP, baseRoute[0].p)
				local pDistance =  util.distance(p, baseRoute[0].p)
				trace("The priorDistance was ",priorPDistance," the pDistance was ",pDistance)
				if priorPDistance < pDistance 	then
					theirMaxIndex = i +1
					trace("Setting theirMaxIndex to",theirMaxIndex,"based on distance condition on upper route. goingup?",goingUp)
					break 
				end
			end 
			if not theirMaxIndex then theirMaxIndex = 1 end 
		end
		trace("Their max index was", theirMaxIndex)
		theirMaxIndex = math.max(theirMaxIndex, 6)
		if theirUpperIndex == boundingRoute.bestIdx then 
			trace("theirUpperIndex was seen as the bestIdx therefore setting to true")
			seenBestIdx = true
		end 
	
		local lastOffset 
		local alreadySeenIndexes = {}
		local priorPTheirs = boundingRoute.points[theirUpperIndex].p
		local count = 0
		local startAt = numberOfNodes
		local isJunctionSpur = boundingRoute.minOffset > 20	-- TODO this could be more refined	
		if isJunctionSpur then 
			startAt = numberOfNodes -1
		end 
		for i = startAt, minCollisionIdx, -1 do
			trace("Deconflicting bounding route from base route at ",i)
			count = count + 1
			local before = baseRoute[i+1]
			local this = baseRoute[i]
			local after = baseRoute[i-1]
			if not after then 
				trace("Reached end of route, aborting at",i)
				break 
			end
			local p = this.p
			local originalP = p
			local theirIndex 
		
			if goingUp then 
				theirIndex = theirUpperIndex + numberOfNodes+1 -i -- theirIndex == 1 at i== numberOfNodes+1
			else 
				theirIndex = theirUpperIndex - (numberOfNodes-i+1)-- theirIndex == theirUpperIndex at i== numberOfNodes+1 
			end
			theirIndex = theirIndex + theirIndexOffSet
			
			 
			trace("at i = ",i," initial lookup of their bounding route point at ", theirIndex, " theirUpperIndex=",theirUpperIndex)
			if not boundingRoute.points[theirIndex] then 
				trace("WARNING! a confliction was detected by no point was found!")
				break 
			end
			local theirNode = util.getNodeClosestToPosition(boundingRoute.points[theirIndex].p)
			if #util.getTrackSegmentsForNode(theirNode)==4 then 
				trace("Discovered crossover node at theirIndex=",theirIndex," shifting to next instead")
				local indexOffset =  theirUpperIndex == 1 and 1 or -1
				theirIndexOffSet = theirIndexOffSet + indexOffset
				theirIndex = theirIndex + indexOffset
			end
			
			 
			trace("at i = ",i," looking up their bounding route point at ", theirIndex, " theirUpperIndex=",theirUpperIndex, " expr(numberOfNodes-i+1)=",(numberOfNodes-i+1), " theirIndexOffSet=",theirIndexOffSet)
			
			if theirIndex <=0 or theirIndex > #boundingRoute.points then 
				trace("No more bounding route points available")
				break 
			end
			
			if not boundingRoute.points[theirIndex] then
				theirIndex = indexOfClosestPoint(p, boundingRoute) 
			end
			
			local pTheirs = boundingRoute.points[theirIndex].p 
			if theirIndex == boundingRoute.bestIdx then 
				seenBestIdx = true
			end 
			--[[if util.distance(before.p + tTheirs, pTheirs) < util.distance(before.p - tTheirs, pTheirs) then 
				trace("Inverting tTheirs based on distance")
				tTheirs = -1*tTheirs
			end]]--
			--local dist = util.distance(pTheirs, before.p)
			local dist = util.distance(pTheirs, priorPTheirs)
			trace("Distance between pTheirs and before was ",dist, "pTheirs at ",pTheirs.x,pTheirs.y," priorPTheirs at",priorPTheirs.x, priorPTheirs.y,"offset=",offset,"theirIndex=",theirIndex)
			if dist > 2*params.targetSeglenth or dist < 0.5*params.minSeglength then 
				
				theirIndex = indexOfClosestPoint(p, boundingRoute)
				pTheirs = boundingRoute.points[theirIndex].p 
				dist = util.distance(pTheirs, before.p)	
				if util.distance(pTheirs, baseRoute[numberOfNodes+1].p)<15 then 
					trace("WARNING! new pTheirs is too close to the end")
					dist = 0 --force abort
				end 
				trace("Unexpected high distance looking up dist to next closest =",dist, " theirIndex=",theirIndex,"alreadySeen?",alreadySeenIndexes[theirIndex])
				if dist > 3*params.targetSeglenth or dist < 0.5*params.minSeglength or alreadySeenIndexes[theirIndex] then
					trace("Aborting")
					break 
				end
			end
			priorPTheirs = pTheirs
			local tTheirs = boundingRoute.points[theirIndex].t
--			local relativeTangentAngle = util.signedAngle(this.t, tTheirs)
			local relativeTangentAngle = util.signedAngle(before.p-pTheirs, tTheirs)
			alreadySeenIndexes[theirIndex] = true
			local perpSign = 1
			if math.abs(relativeTangentAngle) > math.rad(90) then
				trace("Inverting tTheirs based on relativeTangentAngle")
				tTheirs = -1*tTheirs
				--perpSign = -1
			end
			
			local offset = boundingRoute.minOffset
			if params.isDoubleTrack then 
				offset = offset + 0.5*params.trackWidth
			elseif params.isQuadrupleTrack then 
				trace("Increasing offset for quadruple track")
				offset = offset + 1.5*params.trackWidth
			end
			if  boundingRoute.leftHanded  then 
				offset = -offset 
			end
			local isFrozenNode = util.isFrozenNode(util.getNodeClosestToPosition(pTheirs))
			if boundingRoute.spurConnectStation or isFrozenNode then 
				offset = 4*offset 
			end
			if lastOffset then 
				offset = lastOffset
			end
			if boundingRoute.isCollisionInevitable then 
				local increment = offset>0 and 5 or -5
				if math.abs(i-minCollisionIdx) <=3 then 
					offset = offset + increment
					offsetChangeIdxs[i]=true
					trace("Incrementing the offset by",increment,"to get",offset,"upper route")
				end 
			end 
			--[[if #util.getStreetSegmentsForNode(util.searchForNearestNode(pTheirs, 20).id) > 0 then 
				trace("Detected grade crossing, shifting offset")
				offset = offset<0 and math.min(offset, -20) or math.max(offset, 20)
			end  ]]--
			
			local p = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, offset)
			local negative = false
			--[[
			if checkIfPointCollidesWithRoute(baseRoute[i+1].p, testP, boundingRoute)
				and checkIfPointCollidesWithRoute(baseRoute[i+1].p, util.nodePointPerpendicularOffset(pTheirs, tTheirs, 2*offset), boundingRoute) -- check at twice the offset not to get a false result from the straight line approximation
				then 
				p = util.nodePointPerpendicularOffset(pTheirs, tTheirs, -offset)
				negative = true
				trace("Making the offset negative")
			else 
				p = testP
			end]]--		
			if i==numberOfNodes and checkIfPointCollidesWithRoute(baseRoute[i+1].p, p, boundingRoute) then 
				trace("Collision detected adjusting offset")
				local testP = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, -offset)
				if not checkIfPointCollidesWithRoute(baseRoute[i+1].p, testP, boundingRoute)  then 
					--trace("Inverting tTheirs based on collision")
					--tTheirs = -1*tTheirs
					--p = testP
				else 
					trace("WARNING! Collision was not resolved")
				end 
			end 
			local theirDoubleTrackNode = util.findClosestDoubleTrackNode(p, pTheirs, tTheirs,1 , 2.5)
			local distToTheirDoubleTrackNode = theirDoubleTrackNode and util.distance(p, util.nodePos(theirDoubleTrackNode))
			trace("They had a doubletrackNode?",theirDoubleTrackNode," dist was", distToTheirDoubleTrackNode)
			
			if theirDoubleTrackNode -- and util.distance(originalP, util.nodePos(theirDoubleTrackNode)) <  1
				and distToTheirDoubleTrackNode < 1 then 
			 
				offset = offset <0 and math.min(offset,-2*params.trackWidth) or math.max(offset, 2*params.trackWidth)
				trace("Discovered collision with double track node increasing distance, distToTheirDoubleTrackNode=",distToTheirDoubleTrackNode, " newOffset=",offset)
				p = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, offset)
			end
			--local doubleTrackOffset = 0 
		--[[	if params.isDoubleTrack  then 
				trace("Applying additional shift to allow for double track node")
				doubleTrackOffset = -0.5*params.trackWidth
				p = util.nodePointPerpendicularOffset(pTheirs, perpSign*tTheirs, offset+doubleTrackOffset)
			end]]--
			local angleToLast =math.abs( util.signedAngle(before.p-p, before.t2))
			trace("Angle to last was ",math.deg(angleToLast),"relativeTangentAngle=",math.deg(relativeTangentAngle))
			if angleToLast > math.rad(60) and not boundingRoute.isCollisionInevitable then 
				trace("Detected sharp angle change, aborting")
				break;
			end
			
			
			local followRoute = math.abs(offset)<25
			--local movingAway = i<numberOfNodes-3 and util.distance(p, baseRoute[0].p) > util.distance(before.p, baseRoute[0].p) 
			if 
				 (goingUp and theirMaxIndex-theirIndex <= 3 or not goingUp and theirIndex-theirMaxIndex <=3) and not boundingRoute.isCollisionInevitable
			then 
				trace("Detected moving away from destination, attempting to correct (1), theirIndex=", theirIndex, " theirMaxIndex=",theirMaxIndex, " offset =", offset)
				local pOld = p
				local oldOffset = offset
				if math.abs(offset) < 100 then 
					offset = offset + (offset<0 and -5 or 5) 
					offsetChangeIdxs[i]=true
				end
				
				p = util.nodePointPerpendicularOffset(pTheirs,perpSign* tTheirs, offset )
				local angleToLastNew = math.abs(util.signedAngle(before.p-p, before.t2))
				if angleToLastNew > math.rad(30) and angleToLastNew > angleToLast then 
					trace("Reverting changes as it too sharp angl",math.deg(angleToLastNew),math.deg(angleToLast))
					p = pOld
					offset = oldOffset
				end 
				--tTheirs = before.p -p 
				--followRoute = math.abs(offset) < 50
				params.smoothTo = followRoute and  math.min(params.smoothTo, i) or math.max(params.smoothTo, i)
				trace("Set smoothTo to ",params.smoothTo," at ",i)
			else 
				params.smoothTo = math.min(params.smoothTo, i)
				--[[if i == minCollisionIdx then 
					trace("Setting up to depart the follow offset=",offset)
					if math.abs(offset) < 10 then 
						offset = offset*2
						offsetChangeIdxs[i]=true
					end
					p = util.nodePointPerpendicularOffset(pTheirs,perpSign* tTheirs, offset)
					--tTheirs = before.p - p
				end ]]--
			end
			local dist1 = util.distance(p, before.p)
			local dist2 = util.distance(p, after.p)
			
			trace("deconflicting base route with bounding route at ",i, " collision at ", this.p.x, this.p.y," new point ",p.x,p.y, " theirs=",tTheirs.x,tTheirs.y, " this.t=",this.t.x,this.t.y, " relativeTangentAngle=",math.deg(relativeTangentAngle)," offset=",offset," dist1=",dist1,"dist2=",dist2)
			
			local t2 = dist1*vec3.normalize(tTheirs)
			local t = dist2* vec3.normalize(tTheirs)
			before.t = dist1*vec3.normalize(before.t2)
			after.t2 = dist2*vec3.normalize(after.t)
			assert(t.x==t.x)
			assert(t2.x==t2.x)
			assert(p.x==p.x)
			if not validateAdjustment(p, t) then 
				p.z = p.z -10 
			end
			if baseRoute[i].overiddenHeight then 
				baseRoute[i].theirHeight = p.z
				p.z = baseRoute[i].overiddenHeight
			end
			local frozen = followRoute and not boundingRoute.isCollisionInevitable
			if followRoute then 
				upperAdjustments = upperAdjustments + 1
			end
		--	if boundingRoute.isCollisionInevitable and  (math.abs(baseRoute[i].p.z-pTheirs.z) >= params.minZoffset and i == minCollisionIdx+1 or i == minCollisionIdx) then 
			if boundingRoute.isCollisionInevitable and i == minCollisionIdx then 
				trace("Breaking the bounding route at",i)
				if math.abs(baseRoute[i].p.z-pTheirs.z) < params.minZoffset then
					trace("WARNING! Detected insufficint clearance")
					local goUnder = pTheirs.z > baseRoute[i].p.z
					if goUnder then 
						baseRoute[i].p.z = pTheirs.z - params.minZoffset
						baseRoute[i].maxHeight=baseRoute[i].p.z
						baseRoute[i-1].p.z=math.min(baseRoute[i-1].p.z,baseRoute[i].p.z)
						baseRoute[i].minHeight=nil
					else 
						baseRoute[i].p.z = pTheirs.z - params.minZoffset
						baseRoute[i].minHeight=baseRoute[i].p.z
						baseRoute[i-1].p.z=math.max(baseRoute[i-1].p.z,baseRoute[i].p.z)
						baseRoute[i].maxHeight=nil
					end 
					baseRoute[i].overiddenHeight =baseRoute[i].p.z 
					trace("Attempted to compensate using new height",baseRoute[i].p.z)
					
					local count = 0
					for j = i+1, numberOfNodes do 
					
						count = count+1 
						if count > 4 then 
							if baseRoute[j].theirHeight then 
								baseRoute[j].p.z =baseRoute[j].theirHeigh
							end 
							baseRoute[j].overiddenHeight=nil
							baseRoute[j].maxHeight = nil
							baseRoute[j].minHeight = nil
						else 
							local dist = vec2.distance(baseRoute[i].p,baseRoute[j].p)
							local maxDeltaZ=  dist*params.maxGradient
							if goUnder then 
								local maxHeight = baseRoute[i].maxHeight+maxDeltaZ
								baseRoute[j].maxHeight = maxHeight --math.min(baseRoute[j].maxHeight, maxHeight)
								baseRoute[j].minHeight = nil 
								baseRoute[j].p.z = math.min(baseRoute[j].p.z , baseRoute[j].maxHeight)
								baseRoute[j].overiddenHeight = baseRoute[j].p.z
							else 
								local minHeight = baseRoute[i].minHeight-maxDeltaZ
								baseRoute[j].minHeight = minHeight--math.max(baseRoute[j].minHeight, minHeight)
								baseRoute[j].maxHeight = nil 
								baseRoute[j].p.z = math.max(baseRoute[j].p.z , baseRoute[j].minHeight)
								baseRoute[j].overiddenHeight = baseRoute[j].p.z
							end 
						end						
					end 
					 
				end 
				local subNodeCount = i
				local sign = boundingRoute.leftHanded and 1 or -1
				sign = -sign -- N.B. flip the rotation for going down
				before.t2 = util.rotateXY(before.t2, sign*crossoverRotation)
				before.t = util.rotateXY(before.t, sign*crossoverRotation)
				local inputEdge = { p0=startP, t0=startT, p1=before.p, t1=before.t}
				util.applyEdgeAutoTangents(inputEdge)
				local f=i/(i+1)
				local s = util.solveForPositionHermiteFraction(f, inputEdge)
				trace("Set the position from hermite solve to",s.p.x,s.p.y,"was",p.x,p.y,"dist=",util.distance(p,s.p),"fraction was",f,"p0=",inputEdge.p0.x,inputEdge.p0.y,"p1=",inputEdge.p1.x,inputEdge.p1.y)
				--[[if util.distance(p,s.p) > 100 then 
					trace("WARNING! Large distance detected, before.p=",before.p.x,before.p.y)	
					debugPrint({inputEdge=inputEdge})
					local points = {}
					for k = 0, 100 do 
						local frac = k/100 
						local s = util.solveForPositionHermiteFraction(frac, inputEdge) 
						points[k]=s
						trace("Point at",frac,"=",s.p.x,s.p.y)
					end 
					clearRoutes()
					drawBaseRoute({baseRoute=points}, 99, 2)
					 error("Large distance")
				end ]]--
				trace("The preexisting lengths were",vec3.length(t),vec3.length(t2))
				p = s.p 
				t = dist1*vec3.normalize(s.t1) 
				t2 = dist1*vec3.normalize(s.t2) --NB use dist1 here to avoid large excusions
				t.z = 0 
				t2.z= 0
				baseRoute[i].p = p -- assignment here necessary to get the route solve below to work
				baseRoute[i].t = t 
				frozen = true 
				if i == minCollisionIdx then 
					for smoothing =1,2 do 
						local count = 0
						for j = i+1, numberOfNodes do 
							
							if count > 4 then 
								 
								if baseRoute[j].theirHeight then 
									baseRoute[j].p.z =baseRoute[j].theirHeigh
								end 
								baseRoute[j].overiddenHeight=nil
								baseRoute[j].maxHeight = nil
								baseRoute[j].minHeight = nil 
							else 
								local p = baseRoute[j].p
								local inputEdge =  { p1 = baseRoute[j+1].p, p0 = baseRoute[j-1].p, t1=baseRoute[j+1].t , t0 = baseRoute[j-1].t, } 
								util.applyEdgeAutoTangents(inputEdge)
								local s = util.solveForPositionHermiteFraction(0.5, inputEdge)
								if not baseRoute[j].frozen then 
									baseRoute[j].p=s.p 
									baseRoute[j].t=s.t1 
									baseRoute[j].t2=s.t2
									trace("Resolving position at ",j,"for the hermite curve at",p.x,p.y,"adjusted to ",s.p.x,s.p.y,s.p.z,"tangent=",s.t1.x,s.t1.y,s.t1.z)
									count = count + 1
								end
							end						
						end 
					end
					boundingRoute.crossoverPoint = minCollisionIdx
					upperAdjustments = 1+numberOfNodes-i
				end 

				trace("Breaking the bounding route at",i,"using subNodeCount=",subNodeCount,"p=",p.x,p.y,p.z,"at upper, t=",t.x,t.y,t.z)
			end 
			assert(t.x==t.x)
			baseRoute[i] = {p=p, t=t,  t2=t2, frozen=frozen,followRoute =followRoute or boundingRoute.isCollisionInevitable, minHeight=baseRoute[i].minHeight, maxHeight=baseRoute[i].maxHeight, overiddenHeight=baseRoute[i].overiddenHeight}
			if i == numberOfNodes then 
				local maxAngle = math.rad(params.maxInitialTrackAngleEnd) 
				local endAngle = math.abs(util.signedAngle(baseRoute[numberOfNodes].p-baseRoute[numberOfNodes+1].p, -1*baseRoute[numberOfNodes+1].t))
				if endAngle > maxAngle then 
					trace("WARNING! After doing deconfliction the angle of",math.deg(endAngle),"exceeded end angle",params.maxInitialTrackAngleEnd,"correcting")
					params.maxInitialTrackAngleEnd = math.deg(endAngle) -- prevents the route smoothing conflicting with us
				end 
			end
			
			if isJunctionSpur and i == numberOfNodes-1 then 
				local inputEdge =  { p1 = baseRoute[i+2].p, p0 = baseRoute[i].p, t1=baseRoute[i+2].t , t0 = baseRoute[i].t, } 
				util.applyEdgeAutoTangents(inputEdge)
				local s = util.solveForPositionHermiteFraction(0.5, inputEdge)
				baseRoute[i+1].p=s.p
				baseRoute[i+1].t=s.t1
				baseRoute[i+1].t2=s.t2
			end 

			trace("At i = ",i,"set the upperAdjustments to ",upperAdjustments)
			lastOffset = offset
			if math.abs(offset) >= 50 and not boundingRoute.isCollisionInevitable then
				break 
			end
			if i < numberOfNodes-2 and seenBestIdx and not boundingRoute.isCollisionInevitable then 
				trace("Exiting bounding route check as already seen bestIdx at",i)
				break 
			end
			if not boundingRoute.isCollisionInevitable then 
				trace("Checking if deconfliction still required")
				if isBaseRoute then 
					local subRoute = routeEvaluation.buildBasicHermiteRoute({ p0=startP, t0=startT, p1=p, t1=t},numberOfNodes-count)
					local goingUp = false 
					if not checkIfRouteCollides(subRoute, boundingRoute, numberOfNodes-count, goingUp) then 
						trace("Exiting at i=",i,"as a collision should no longer occur from the base route, goingUp=",goingUp)
						break
					end 
				else
					local hasCollision = false 
					local priorP=baseRoute[i].p 
					for j = i-1, 1, -1 do 
						local p = baseRoute[j].p 
						if  checkIfPointCollidesWithRoute(priorP, p, boundingRoute) then 	
							hasCollision = true 
							break 
						end 
						priorP = p
					end 
					if not hasCollision then 
						trace("Exiting at i=",i,"as a collision should no longer occur from the calculated route, goingUp=",false)
						break
					end 
				--[[	local goingUp = false 
					if not checkIfRouteCollides(baseRoute, boundingRoute, numberOfNodes, goingUp) then 
					
						break
					end]]--
				end					
			end 
		end
	
		--[[
		params.smoothTo = numberOfNodes
		for i = numberOfNodes, halfway, -1 do
			if baseRoute[i].followRoute then 
				params.smoothTo = math.min(params.smoothTo, i)
			end
		end]]--
		if not baseRoute[minCollisionIdx] or not baseRoute[minCollisionIdx-1] then 
			error("Unable to find routeInfo at "..minCollisionIdx.." of total "..#baseRoute)
		end 
		--[[local vectorFromLast = baseRoute[minCollisionIdx].p- baseRoute[minCollisionIdx-1].p 
		local angleFromLast = util.signedAngle(vectorFromLast, baseRoute[minCollisionIdx].t)
		if math.abs(angleFromLast) > math.rad(30) then 
			trace("Detected sharp angle from last, attempting to correct angle was ",math.deg(angleFromLast))
			local startFrom = math.max(minCollisionIdx-3, halfway)
			if startFrom < minCollisionIdx then 
				local dist = util.distance(baseRoute[startFrom].p, baseRoute[minCollisionIdx].p)
				local edge = {
					p0 = baseRoute[startFrom].p,
					p1 = baseRoute[minCollisionIdx].p,
					t0 = dist*vec3.normalize(baseRoute[startFrom].t), 
					t1 = dist*vec3.normalize(baseRoute[minCollisionIdx].t)
				}
				for i = startFrom+1, minCollisionIdx-1 do 
					local frac = (i-startFrom)/(minCollisionIdx-startFrom)
					trace("Solving for position at ",i," with frac",frac)
					local before = baseRoute[i+1]
					local this = baseRoute[i]
					local after = baseRoute[i-1]
					local solution = util.solveForPositionHermiteFraction(frac, edge)
					this.p=solution.p 
					before.t2 =  solution.t0 
					this.t = solution.t1 
					this.t2 = solution.t2 
					after.t = solution.t3
				end
			end 
		end]]--
	end
	--END UPPER
	local totalAdjustments = upperAdjustments + lowerAdjustments
	if totalAdjustments > 0  and isBaseRoute and totalAdjustments < numberOfNodes-1 then 
		trace("Resolving for the base route from",lowerAdjustments,"to",(numberOfNodes+1-upperAdjustments))
		local edge = {
			p0 = baseRoute[lowerAdjustments].p,
			t0 = baseRoute[lowerAdjustments].t ,
			p1 = baseRoute[numberOfNodes+1-upperAdjustments].p,
			t1 = baseRoute[numberOfNodes+1-upperAdjustments].t,
		
		}
		if util.tracelog then 
			debugPrint({edgeForSubRouteResolve=edge})
		end
		local subBaseRoute = routeEvaluation.buildBaseRouteFromEdge(edge, numberOfNodes-totalAdjustments, boundingRoutes, params, numberOfNodes)
		local subroute = subBaseRoute.baseRoute
		if util.tracelog then 
			debugPrint({baseRoute=baseRoute, subroute=subroute})
		end
		for i = lowerAdjustments+1, numberOfNodes-upperAdjustments  do 
			trace("Copying subroute at i=",i,"from ",i-lowerAdjustments,"of",#subroute,"originally",baseRoute[i].p.x,baseRoute[i].p.y,"now",subroute[i-lowerAdjustments].p.x,subroute[i-lowerAdjustments].y)
			baseRoute[i]=subroute[i-lowerAdjustments]
		end 
		if util.tracelog then 
			--debugPrint({inputEdge = edge, baseRoute=baseRoute, subrouteAdjustMents= subBaseRoute.adjustments})
		end 
		upperAdjustments = upperAdjustments + subBaseRoute.adjustments.upperAdjustments
		lowerAdjustments = lowerAdjustments + subBaseRoute.adjustments.lowerAdjustments
	end 
	--[[
	if upperAdjustments <= 3 or alwaysSuppressSmoothing then 
		params.smoothTo = math.min(params.smoothTo, numberOfNodes-upperAdjustments)
	end 
	if lowerAdjustments <= 3 or alwaysSuppressSmoothing  then 
		params.smoothFrom = math.max(params.smoothFrom, 1+lowerAdjustments)
	end]]--
	params.smoothTo = numberOfNodes-upperAdjustments
	params.smoothFrom = 1+lowerAdjustments
	
	params.upperAdjustments = upperAdjustments
	params.lowerAdjustments = lowerAdjustments
	profiler.endFunction("deconflictRouteWithBoundingRoutes")
	trace("End of deconfliction, smoothFrom=",params.smoothFrom," smoothTo=",params.smoothTo, " lowerAdjustments=",lowerAdjustments,"upperAdjustments=",upperAdjustments,"numberOfNodes=",numberOfNodes)
	local isCollisionInevitable = boundingRoutes[1].isCollisionInevitable or boundingRoutes[2].isCollisionInevitable
	return { lowerAdjustments = lowerAdjustments, upperAdjustments=upperAdjustments , isCollisionInevitable = isCollisionInevitable, totalAdjustments=lowerAdjustments+upperAdjustments }
end

local function deconflictRouteWithBoundingRoutesWithCheck(baseRoute, boundingRoutes, params, numberOfNodes, isBaseRoute,originalNumberOfNodes)
	local baseRouteCopy = {}
	for i = 0, numberOfNodes+1 do -- not using deepClone because want vec3 objects
		baseRouteCopy[i] = {}
		baseRouteCopy[i].p = util.v3(baseRoute[i].p)
		baseRouteCopy[i].t = util.v3(baseRoute[i].t)
		baseRouteCopy[i].t2 = util.v3(baseRoute[i].t2)
	end
	
	 
	 
	local adjustments = deconflictRouteWithBoundingRoutes(baseRoute, boundingRoutes, params, numberOfNodes, isBaseRoute, originalNumberOfNodes)
	if not adjustments or  adjustments.totalAdjustments == 0 then 
		return adjustments 
	end 
	
	  
	local function rollbackDeconfliction()
	 
		params.smoothFrom = 1
		params.smoothTo = numberOfNodes
		for i = 1, numberOfNodes do
			baseRoute[i].p = baseRouteCopy[i].p
			baseRoute[i].t = baseRouteCopy[i].t
			baseRoute[i].t2 = baseRouteCopy[i].t2
		end 
	end 
	
	for i = 1, numberOfNodes do  -- geometry check
		local before = baseRoute[i-1].p 
		local this = baseRoute[i].p 
		local after = baseRoute[i+1].p
		local angle = util.signedAngle(after-this, this-before)
		trace("Checking geometry at i=",i,"angle was",math.deg(angle))
		if math.abs(angle) > math.rad(90) then 
			trace("WARNING! large angle detected following deconfliction, aborting")
			rollbackDeconfliction()
			break 
		end 
	end 
	return adjustments
end 

function routeEvaluation.buildBasicHermiteRoute(edge, numberOfNodes)
	local totalsegs= numberOfNodes+1
	
	util.applyEdgeAutoTangents(edge)
	local edgeLength = util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1)
	local segLength = edgeLength / totalsegs
	local baseRoute = {}
	baseRoute[0]= { p=edge.p0, t= segLength*vec3.normalize(edge.t0),  t2= segLength*vec3.normalize(edge.t0)}
	if numberOfNodes == 0 then 
		baseRoute[numberOfNodes+1]=  { p=edge.p1, t= segLength*vec3.normalize(edge.t1),  t2= segLength*vec3.normalize(edge.t1)} 
		return baseRoute
	end 
	
	for i = 1, numberOfNodes do
		local t=i/totalsegs
		local s = util.solveForPositionHermiteFraction(t, edge)
		local p = s.p
		if not util.isValidCoordinate(p) then  
			p = util.bringCoordinateInsideMap(p)
		end  
		baseRoute[i] = {p=p, t=s.t, t2=s.t}
	end 
	--debugPrint({edge=edge, baseRoute=baseRoute, numberOfNodes=numberOfNodes})


	baseRoute[0].t2 = util.distance(baseRoute[0].p, baseRoute[1].p)* vec3.normalize(baseRoute[0].t2)
	baseRoute[numberOfNodes+1]= { p=edge.p1, t= util.distance(baseRoute[numberOfNodes].p, edge.p1)*vec3.normalize(edge.t1), t2= util.distance(baseRoute[numberOfNodes].p, edge.p1)*vec3.normalize(edge.t1)}
	return baseRoute
end 

local nextIndex = 1
local function buildBaseRouteFromEdge(edge, numberOfNodes, boundingRoutes, params, originalNumberOfNodes)
local baseRoute = {}
	trace("buildBaseRouteFromEdge: numberOfNodes was",numberOfNodes,"originalNumberOfNodes=",originalNumberOfNodes)
	profiler.beginFunction("buildBaseRouteFromEdge")
	local totalsegs= numberOfNodes+1
	local totalDist = util.distance(edge.p0, edge.p1) -- straight line distance but its reasonable enough
 
	local initialTangentLength = vec3.length(edge.t0 )
	if correctBaseRouteTangent and initialTangentLength > 1.1*totalDist then  -- this has the effect of straighening out a potentially large circle
		local newLength = 0.5*(initialTangentLength+totalDist) -- take the average 
		trace("Reducing the initial tangent length which was ",initialTangentLength, " vs ",totalDist,"  newLength=",newLength)
		edge.t0 = newLength*vec3.normalize(edge.t0 )
		edge.t1 = newLength*vec3.normalize(edge.t1)
	end 
	if params.baseRouteEdgeTangentFactor then 
		local idealLength = util.calculateTangentLength(edge.p0, edge.p1, edge.t0,edge.t1) -- N.B this is actually only ideal assuming the points are on a circle
		local baseDist = util.distance(edge.p0, edge.p1)
		local additionalLength = idealLength - baseDist
	--	local calculatedLength = params.baseRouteEdgeTangentFactor * additionalLength + idealLength
		local calculatedLength = params.baseRouteEdgeTangentFactor * idealLength
		edge.t0 = calculatedLength*vec3.normalize(edge.t0 )
		edge.t1 = calculatedLength*vec3.normalize(edge.t1)
		trace("Renormalising the tangent length to ",calculatedLength,"params.baseRouteEdgeTangentFactor=",params.baseRouteEdgeTangentFactor,"idealLength=",idealLength,"base dist=",baseDist)
	end 
	local naturalT = edge.p1-edge.p0
	local angle1 = util.signedAngle(edge.t0, edge.t1)
	local angle2 = util.signedAngle(edge.t0, naturalT)
	local angle3 = util.signedAngle(naturalT, edge.t1) 
	trace("buildBaseRouteFromEdge: the initial angles were",math.deg(angle1),math.deg(angle2),math.deg(angle3))
	local startAngleNeedsCorrection = false 
	local endAngleNeedsCorrection = false 
	if numberOfNodes < 20 then
		startAngleNeedsCorrection = math.abs(angle2) > math.rad(90)
		endAngleNeedsCorrection = math.abs(angle3) > math.rad(90)
	end 
	--local edgeLength = util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1)
	--[[local tangentLength = math.min(vec3.length(edge.t0), vec3.length(edge.t1))
	local count = 0
	trace("The tangent length was calculated as ",tangentLength, " the edgeLength was ", edgeLength," totalDist=",totalDist)
	while count < 20 and tangentLength <edgeLength do 
		edge.t0 = edgeLength*vec3.normalize(edge.t0)
		edge.t1 = edgeLength*vec3.normalize(edge.t1)
		tangentLength = edgeLength
		edgeLength = util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1)
	end
	trace("After ",count," iterations, the tangent length was calculated as ",tangentLength, " the edgeLength was ", edgeLength," totalDist=",totalDist)
	]]--
	local edgeLength = util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1)
	local segLength = edgeLength / totalsegs
	trace("the calculated edgeLength was ",edgeLength,"with expected segLength=",segLength)
	local fracspace = 1/ (totalsegs )  
	baseRoute[0]= { p=edge.p0, t= segLength*vec3.normalize(edge.t0),  t2= segLength*vec3.normalize(edge.t0)}
	local lastP = edge.p0
	local valid = true 
	local weightedFraction = 0.5
	local count = 0
	local keepOriginalLength = true 
	repeat
		count = count + 1
		valid = true 
		for i = 1, numberOfNodes do
			--local p = util.hermite2(i/totalsegs, edge).p
			local t=i/totalsegs
			local s = util.solveForPositionHermiteFraction(t, edge, keepOriginalLength)
			local p = s.p
			if not s.solutionConverged and util.tracelog then 
				error("Solution not converged")
			end
			if not util.isValidCoordinate(p) then 
				trace("Discovered point outside map boundary, attempting to compensate at i=",i)
				if weightedFraction > 0 then -- try to pull in the hermite curve by reducing the tangent 
					weightedFraction = math.max(0,weightedFraction - 0.1)
					local newLength = weightedFraction*initialTangentLength+(1-weightedFraction)*totalDist -- take the average 
					trace("Reducing the initial tangent length which was ",initialTangentLength, " vs ",totalDist,"  newLength=",newLength, " weightedFraction=",weightedFraction)
					edge.t0 = newLength*vec3.normalize(edge.t0 )
					edge.t1 = newLength*vec3.normalize(edge.t1)
					valid = false 
					--break
				else 
					trace("WARNING! Point still outside map, forcing compensation was",p.x,p.y)
					p = util.bringCoordinateInsideMap(p)
					trace("corrected point = ",p.x,p.y)
				end
			end 
				local t0 = baseRoute[i-1].t 
				local p0 = baseRoute[i-1].p
				local t1 = segLength*vec3.normalize(s.t)
				local p1 = p
				local angle = math.abs(util.signedAngle(t0, t1))
				local length = util.calcEdgeLength(p0, p1, t0, t1)
				trace("The angle to the prior was",math.deg(angle),"at i=",i,"length=",length,"dist=",util.distance(p0,p1),"t=",t,"s.solutionConverged=",s.solutionConverged)
			--trace("Solving hermite position at ",i," frac=",t, " the hermite interval was ",s.f, " converged?",s.solutionConverged,"dist=",util.distance(p,lastP))
			 
			if i == 1 then 
				local maxAngle = math.rad(params.maxInitialTrackAngleStart) 
				local startAngle = util.signedAngle(p-edge.p0, edge.t0)
				trace("The start angle was",math.deg(startAngle),"at p=",p.x,p.y)
				if math.abs(startAngle) > maxAngle then 
					trace("Discovered large initial angle in base route build, at start attempting to compenssate, angle was",math.deg(startAngle), "max angle was",params.maxInitialTrackAngleStart)
					startAngleNeedsCorrection = true
					  
				end 
			elseif i == numberOfNodes then 
				local maxAngle = math.rad(params.maxInitialTrackAngleEnd) 
				local endAngle = util.signedAngle(p-edge.p1, -1*edge.t1)
				trace("The end angle was",math.deg(endAngle),"at p=",p.x,p.y)
				if math.abs(endAngle) > maxAngle then 
					trace("Discovered large initial angle in base route build, at end attempting to compenssate, angle was",math.deg(endAngle), "max angle was",params.maxInitialTrackAngleEnd)
					endAngleNeedsCorrection = true
					 
				end
			else 
				
				if angle > params.minimumAngle then 
					trace("The angle exceeds minimum")
					if i < numberOfNodes / 2 then 
						startAngleNeedsCorrection = true 
					else 
						endAngleNeedsCorrection = true
					end
				end 
			end
			
			baseRoute[i] = {p=p, t=segLength*vec3.normalize(s.t)}
			lastP = p
		end
	until valid or count > 10
	baseRoute[0].t2 = util.distance(baseRoute[0].p, baseRoute[1].p)* vec3.normalize(baseRoute[0].t2)
	baseRoute[numberOfNodes+1]= { p=edge.p1, t= util.distance(baseRoute[numberOfNodes].p, edge.p1)*vec3.normalize(edge.t1), t2= util.distance(baseRoute[numberOfNodes].p, edge.p1)*vec3.normalize(edge.t1)}
	if params.drawBaseRouteOnly then 
		--drawBaseRoute({baseRoute=baseRoute},numberOfNodes, nextIndex)
		--nextIndex = nextIndex+1
	end
	local edgeLength = util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1)
	local segLength = edgeLength / totalsegs
	
	local firstPos = baseRoute[1].p 
	local lastPos = baseRoute[numberOfNodes].p
	local maxAngleStart = math.rad(params.maxInitialTrackAngleStart)   
	local maxAngleEnd = math.rad(params.maxInitialTrackAngleEnd)  
	
	if numberOfNodes == originalNumberOfNodes then 
		--TODO the following could be refinedd
		if proposalUtil.trialBuildBetweenPoints(baseRoute[0].p, baseRoute[1].p, baseRoute[0].t2, baseRoute[1].t).hasConstructionCollision then 	
			local isResolved = not proposalUtil.trialBuildStraightLine(baseRoute[0].p, baseRoute[0].t, segLength).hasConstructionCollision
			trace("Detected construciton collision at start, was resolved?",isResolved)
			if isResolved  then 
				startAngleNeedsCorrection = true 
				maxAngleStart = 0
			end 
		elseif proposalUtil.trialBuildBetweenPoints(baseRoute[0].p, baseRoute[2].p, baseRoute[0].t2, baseRoute[2].t).hasConstructionCollision then
			local isResolved = not proposalUtil.trialBuildStraightLine(baseRoute[0].p, baseRoute[0].t, segLength*2).hasConstructionCollision
			trace("Detected construciton collision at start, was resolved?",isResolved)
			if isResolved  then 
				startAngleNeedsCorrection = true 
				maxAngleStart = 0
			end 
		end 	
		if proposalUtil.trialBuildBetweenPoints(baseRoute[numberOfNodes].p, baseRoute[numberOfNodes+1].p, baseRoute[numberOfNodes].t2, baseRoute[numberOfNodes+1].t).hasConstructionCollision then 
			local isResolved = not proposalUtil.trialBuildStraightLine(baseRoute[numberOfNodes+1].p, -1*baseRoute[numberOfNodes+1].t, segLength).hasConstructionCollision
			trace("Detected construciton collision at end, was resolved?",isResolved)
			if isResolved  then 
				endAngleNeedsCorrection = true 
				maxAngleEnd = 0
			end 
		elseif proposalUtil.trialBuildBetweenPoints(baseRoute[numberOfNodes].p, baseRoute[numberOfNodes+1].p, baseRoute[numberOfNodes].t2, baseRoute[numberOfNodes+1].t).hasConstructionCollision then 
			local isResolved = not proposalUtil.trialBuildStraightLine(baseRoute[numberOfNodes+1].p, -1*baseRoute[numberOfNodes+1].t, segLength*2).hasConstructionCollision
			trace("Detected construciton collision at end, was resolved?",isResolved)
			if isResolved  then 
				endAngleNeedsCorrection = true 
				maxAngleEnd = 0
			end
		end	
	end
	local depth = originalNumberOfNodes-numberOfNodes
	local startAngleLeftHanded 
	local endAngleLeftHanded 
	if startAngleNeedsCorrection or endAngleNeedsCorrection then 
		local result = baseRoute
		local newEdge = util.shallowClone(edge)
		trace("WARNING! Unable to find valid solution for base route")
		local startAngle = util.signedAngle(result[1].p-result[0].p, result[0].t2)
		
		local decrement = 0
		local indexFrom = 0
		local indexTo = numberOfNodes + 1 
		
		if math.abs(startAngle) > maxAngleStart or startAngleNeedsCorrection   then 
			trace("buildBaseRouteFromEdge: Attempting to correct sharp angle at ",result[1].p.x,result[1].p.y, " angle was",math.deg(startAngle))
		 
			local newAngle = startAngle > 0 and -maxAngleStart or maxAngleStart
			local t = vec3.normalize(util.rotateXY(result[0].t2, newAngle))
			--result[1].p = segLength * t + result[0].p
			local thisSegLength = segLength
			newEdge.p0 = thisSegLength * t + result[0].p
			newEdge.t0 = util.rotateXY(t, newAngle)
			result[1].p = newEdge.p0
			result[1].t = newEdge.t0 
			result[1].t2 = newEdge.t0
			local recalculatedAngle = util.signedAngle(result[1].p-result[0].p, result[0].t2)
			trace("repositioned the start point at ",newEdge.p0.x,newEdge.p0.y,"segLength=",segLength,"recalculatedAngle=",math.deg(recalculatedAngle))
			params.startAngleCorrections = params.startAngleCorrections+1
			startAngleLeftHanded = startAngle < 0
			--trace("Detected sharp start angle", math.deg(startAngle), " attempting to correct, recalculated angle is ",math.deg(recalculatedAngle), " new point is at ",result[1].p.x,result[1].p.y)
			 decrement = 1
			 indexFrom = 1
		end 
		local endAngle = util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
		local endAngleAlternative = util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t2)
	 
		if math.abs(endAngle) > maxAngleEnd or endAngleNeedsCorrection  then  
			trace("buildBaseRouteFromEdge: Attempting to correct sharp angle at ",result[numberOfNodes].p.x,result[numberOfNodes].p.y, " angle was",math.deg(endAngle))
			local newAngle = endAngle > 0 and -maxAngleEnd or maxAngleEnd
			local t = vec3.normalize(util.rotateXY(result[numberOfNodes+1].t, newAngle))
			newEdge.p1 = result[numberOfNodes+1].p -segLength * t
			newEdge.t1 = util.rotateXY(t, newAngle)
			result[numberOfNodes].p = newEdge.p1 
			result[numberOfNodes].t = newEdge.t1 
			result[numberOfNodes].t2 = newEdge.t1
			local recalculatedAngle = util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
			trace("repositioned the end point at ",newEdge.p1.x,newEdge.p1.y,"tangent=",newEdge.t1.x,newEdge.t1.y,"recalculatedAngle=",math.deg(recalculatedAngle))
			--local recalculatedAngle =util.signedAngle(result[numberOfNodes].p-result[numberOfNodes+1].p, -1*result[numberOfNodes+1].t)
			--trace("Detected sharp end angle", math.deg(endAngle), " attempting to correct, recalculated angle is ",math.deg(recalculatedAngle))
			decrement = decrement +1
			indexTo = indexTo - 1
			params.endAngleCorrections = params.endAngleCorrections+1
			endAngleLeftHanded = endAngle < 0 
		end
--		assert(decrement > 0)  	
		
		if decrement > 0 and numberOfNodes > decrement+2 and depth < 16 then 
			trace("Building subroute, the decrement was",decrement,"indexFrom=",indexFrom,"indexTo=",indexTo,"numberOfNodes=",numberOfNodes,"originalNumberOfNodes=",originalNumberOfNodes, "depth=",depth)
			local newRoute=   buildBaseRouteFromEdge(newEdge, numberOfNodes-decrement, boundingRoutes, params, originalNumberOfNodes).baseRoute
			for i = indexFrom, indexTo do 
				
				trace("Copying newRoute from sub solve at i=",i,"from",i-indexFrom, "numberOfNodes=",numberOfNodes,"decrement=",decrement, "originally",baseRoute[i].p.x,baseRoute[i].p.y,"now",newRoute[i-indexFrom].p.x,newRoute[i-indexFrom].p.y)
				baseRoute[i]=newRoute[i-indexFrom]	
			end 
			if util.tracelog then 
				--debugPrint({baseRoute=baseRoute})
			end 
			trace("Base route reconstructed, start angle corrections=",params.startAngleCorrections,"endAngleCorrections=",params.endAngleCorrections)
		else 
			trace("WARNING!, buildBaseRouteFromEdge: unable to solve")
		end 
	end
	for i = 1, numberOfNodes do 
		local before = baseRoute[i-1].p
		local this = baseRoute[i].p
		local after = baseRoute[i+1].p
		local t =  computeTangent(before, this , after, i, numberOfNodes, edge)
		baseRoute[i].t = util.calculateTangentLength(before, this, baseRoute[i-1].t2, t)* vec3.normalize(t)
		baseRoute[i].t2 = util.calculateTangentLength(this, after,t, baseRoute[i+1].t )* vec3.normalize(t)	 
	end
	--[[trace("Begin initial renormaliseSpacing")
	
	routeEvaluation.renormaliseSpacing(baseRoute, numberOfNodes, params) 
	--checkForLooping(baseRoute,numberOfNodes, "end renormaliseSpacing") 
	trace("End initial renormaliseSpacing")--]]
	local baseRouteCopy = {} 
	for i = 0, numberOfNodes+1 do -- not using deepClone because want vec3 objects
		baseRouteCopy[i] = {}
		baseRouteCopy[i].p = util.v3(baseRoute[i].p)
		baseRouteCopy[i].t = util.v3(baseRoute[i].t)
		baseRouteCopy[i].t2 = util.v3(baseRoute[i].t2)
	end
	
	local adjustments = { upperAdjustments = 0, lowerAdjustments = 0 }
	if depth == 0 then 
		adjustments = deconflictRouteWithBoundingRoutes(baseRoute, boundingRoutes, params, numberOfNodes, true, originalNumberOfNodes)
	end 
	local function rollbackDeconfliction()
		adjustments = { upperAdjustments = 0, lowerAdjustments = 0 }
		params.smoothFrom = 1
		params.smoothTo = numberOfNodes
		baseRoute = baseRouteCopy 
	end 
	
	for i = 1, numberOfNodes do  -- geometry check
		local before = baseRoute[i-1].p 
		local this = baseRoute[i].p 
		local after = baseRoute[i+1].p
		local angle = util.signedAngle(after-this, this-before)
		trace("Checking geometry at i=",i,"angle was",math.deg(angle))
		if math.abs(angle) > math.rad(90) then 
			trace("WARNING! large angle detected following deconfliction, aborting")
			rollbackDeconfliction()
			break 
		end 
	end 
	
	if adjustments.upperAdjustments + adjustments.lowerAdjustments >= numberOfNodes then 
		trace("WARNING! The total number of adjustments",adjustments.upperAdjustments + adjustments.lowerAdjustments,">=",numberOfNodes,"(numberOfNodes), rolling back")
		rollbackDeconfliction()
	end 
	
	local deduplicatedRoute = {} 
	deduplicatedRoute[0]=baseRoute[0]
	for i = 1, numberOfNodes+1 do 
		local before = baseRoute[i-1].p
		local this = baseRoute[i].p
		if not util.positionsEqual (before, this, 1) then
			table.insert(deduplicatedRoute, baseRoute[i])
		end
	end
	--deduplicatedRoute[numberOfNodes+1]=baseRoute[numberOfNodes+1]
	local countBeforeDeduplication = util.size(baseRoute)
	local countAfterDeduplicaiton = util.size(deduplicatedRoute)
	if countAfterDeduplicaiton < countBeforeDeduplication then 
		trace("Number of nodes has been reduced, after deduplication, there are ",countAfterDeduplicaiton," vs", countBeforeDeduplication)
		baseRoute = baseRouteCopy
		--[[
		if originalNumberOfNodes and originalNumberOfNodes == countAfterDeduplicaiton then
			trace("corrected number of nodes is correct, using deduplicatedRoute")
			baseRoute = deduplicatedRoute
			numberOfNodes = originalNumberOfNodes
		else 
			local difference = countBeforeDeduplication-countAfterDeduplicaiton
			local newNodeCount = numberOfNodes+difference
			trace("attempting to correct by adding required number of nodes and recalculating, difference=",difference, " newNodeCount=",newNodeCount," original node count=",numberOfNodes)
			return buildBaseRouteFromEdge(edge, newNodeCount, boundingRoutes, params, numberOfNodes)			
		end]]--
	end
	
	
 	--[[if pcall(function() routeEvaluation.applySmoothing(baseRoute, numberOfNodes, 2, params, edge)end) then
		--deconflictRouteWithBoundingRoutes(baseRoute, boundingRoutes, params, numberOfNodes)
	else 
		trace("Unable to smooth route, falling back")
		baseRoute = baseRouteCopy
	end]]--
	profiler.endFunction("buildBaseRouteFromEdge")

	return { baseRoute=baseRoute, adjustments = adjustments, baseRouteCopy=baseRouteCopy, startAngleLeftHanded = startAngleLeftHanded, endAngleLeftHanded = endAngleLeftHanded}
end

routeEvaluation.buildBaseRouteFromEdge = buildBaseRouteFromEdge -- global functions not allowed

local function validateRouteTangents(route) 
	for i = 1, #route do 
		if (route[i].p.x~=route[i].p.x) or (route[i].p.y~=route[i].p.y) then
			trace("NaN point found at ",i)
			return false 
		end
		local angle = util.signedAngle(route[i].t, route[i].t2)
		if math.abs(angle) > 5 then 
			trace("WARNING! Found problem with route, angle was ",math.deg(angle), " at i=",i)
			return false 
		end 
	end 
	return true
end 


local function smoothToTerrain(baseRoute, numberOfNodes, params)
	local startP = baseRoute[0].p 
	local endP = baseRoute[numberOfNodes+1].p 
	local startZ = startP.z
	local endZ = endP.z
	local baseGrad = math.abs(startZ-endZ)/vec2.distance(startP, endP)
	local maxHeightEnds = math.max(startZ, endZ) 
	local minHeightEnds = math.min(startZ, endZ)
	local maxGrad = math.max(baseGrad, params.maxGradient/2)-- divide by 2 to keep scoring for flatter routes
	trace("Smoothing to terrain in routeEvaluation, maxGrad set to",maxGrad," baseGrad was",baseGrad)
	for __, forwards in pairs({true, false}) do 
		local startAt = forwards and 1 or numberOfNodes 
		local endAt = forwards and numberOfNodes or 1 
		local increment = forwards and 1 or -1 
		for i = startAt, endAt, increment do
			local p = baseRoute[i].p 
			local maxH = math.min(endZ + maxGrad*vec2.distance(p, endP), startZ+maxGrad*vec2.distance(p,startP))
			local minH = math.max(endZ - maxGrad*vec2.distance(p, endP), startZ-maxGrad*vec2.distance(p,startP))
			local priorP = forwards and baseRoute[i-1].p or baseRoute[i+1].p
			minH = math.max(minH, priorP.z - maxGrad*vec2.distance(p, priorP))
			maxH = math.min(maxH, priorP.z + maxGrad*vec2.distance(p, priorP))
			local th = util.th(p)
			local originalZ = p.z
			if th > p.z then 
				
				if th < minH then 
					p.z = minH
				else 
					p.z = th
				end 
			elseif th < 0 then  -- water
				if p.z < 15 then 
					if maxH < 15 then 
						p.z = maxH 
					else 
						p.z = 15
					end 
				end 
			elseif th < p.z then 
				if th > maxH then 
					p.z = maxH
				else 
					p.z = th
				end
			end 
			trace("At ",i,"Set p.z=",p.z," based on maxH=",maxH," minH=",minH,"th=",th, "maxGrad=",maxGrad)
		end 
	end
	 
end 
function routeEvaluation.renormaliseSpacing(baseRoute, numberOfNodes, params)
	local begin = os.clock()
	profiler.beginFunction("renormaliseSpacing")
	--checkForLooping(baseRoute,numberOfNodes, "begin renormaliseSpacing") 
	local tolerance = 2
	local maxTolerance = 8
	
	local newRoute= {}
	
	local maxCorrectionFactor = math.min(0.5, 1/(numberOfNodes+1)) -- need to make sure we don't shift out by more than one point in an iteration
	--newRoute[0] = baseRoute[0]
	local maxDivergence = 0 
	local count = 0
	--trace("The totalLength= ",totalLength, " the targetSeglenth=",targetSeglenth," the maxCorrectionFactor=",maxCorrectionFactor, " numberOfNodes=",numberOfNodes)
	local halfway = numberOfNodes /2
	local abort = false
	local finalEdgeCorrected = false
	local previousEdgeTooLarge = false 
	local previousEdgeTooSmall = false
	local startPoint = util.v3(baseRoute[0].p)
	local endPoint = util.v3(baseRoute[numberOfNodes+1].p)
	repeat
		local totalLength = 0
		if not validateRouteTangents(baseRoute) then 
			trace("WARNING! renormaliseSpacing Failed validation after ",count)
			break 
		end
		for i = 1, numberOfNodes+1 do
			local before = baseRoute[i-1]
			local this = baseRoute[i]
			if not this then 
				print("WARNING, no data found at ",i," numberOfNodes is ",numberOfNodes)
			end
			local thisEdgeLength = util.calcEdgeLengthHighAccuracy({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t})
			totalLength = totalLength + thisEdgeLength 
			--trace("At i =",i,"thisEdgeLength was ",thisEdgeLength, " the dist was ",util.distance(before.p, this.p))
		end
		local targetSeglenth = totalLength / (numberOfNodes+1)
		 trace("The totalLength= ",totalLength, " the targetSeglenth=",targetSeglenth," the maxCorrectionFactor=",maxCorrectionFactor, " numberOfNodes=",numberOfNodes)
		count = count + 1
		--trace("Begin renormalising space, iteration ", count)
		maxDivergence = 0
		totalLength = 0
		local priorEdgeCorrected = false
		local nextEdgeCorrected = false
		local from =1
		local to = numberOfNodes+1
		local increment = 1
		local backwards = false 
		if count % 2 == 0 then 
			backwards = true
			from = to 
			to = 1
			increment = -1
		end
		--trace("Begin iteration from",from," to ",to, " increment",increment, " backwards=",backwards)
		for i = from, to, increment do 
			if finalEdgeCorrected then 
				if i == 2 then 	
					priorEdgeCorrected = true 
					finalEdgeCorrected = false
				end 
				if i == numberOfNodes then 
					nextEdgeCorrected = true 
					finalEdgeCorrected = false
				end 
				
			end 
			local before = baseRoute[i-1]
			local this = baseRoute[i]
			local after = baseRoute[i+1]
		--	local thisSegLength = util.calcEdgeLengthHighAccuracyWithTangentCorrection({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t})
			local thisSegLength = util.calcEdgeLengthHighAccuracy({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t})
			local straightDist = util.distance(this.p, before.p)
			if thisSegLength > 1.5* straightDist or thisSegLength < straightDist*0.99 then
				trace("WARNING, unexpected seg length, ", thisSegLength, " vs ",straightDist,"tangent angle",math.deg(util.signedAngle(before.t2,this.t)))
				if util.tracelog then 
					debugPrint({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t})
				end
			end
			--trace("Inspecting seglength at i=",i,"The segLength=",thisSegLength)
			maxDivergence = math.max(maxDivergence, math.abs(thisSegLength-targetSeglenth))
			if thisSegLength >  targetSeglenth +tolerance then
				local correctionFactor = math.max(targetSeglenth / thisSegLength, 1-maxCorrectionFactor)
				local nextSegLength =  after and util.calcEdgeLengthHighAccuracy({ p0=this.p, t0=this.t2, p1=after.p, t1=after.t}) or 0 
				if params.isDebugResults then 
					trace("i=",i,"This too large segLength=",thisSegLength," targetSeglenth=",targetSeglenth," correctionFactor=",correctionFactor, " nextSegLength=",nextSegLength, " priorEdgeCorrected?",priorEdgeCorrected, "nextEdgeCorrected=",nextEdgeCorrected)
				end
				local edge = { p0=before.p, t0=before.t2, p1=this.p, t1=this.t}
				local isBefore = false 
				if  i > 1 then  
					local beforeBefore = baseRoute[i-2]
					if i == numberOfNodes+1  or (nextEdgeCorrected and previousEdgeTooLarge) or (util.calcEdgeLengthHighAccuracy({ p0 = beforeBefore.p, p1= before.p, t0=beforeBefore.t2, t1=before.t}) < nextSegLength and (previousEdgeTooSmall or not priorEdgeCorrected)) then 
					 
						after = this
						this = before
						before = beforeBefore
						correctionFactor = 1 -correctionFactor
						if i == numberOfNodes+1 then 
							correctionFactor = targetSeglenth/thisSegLength
						end 
						
						
						edge = { p0=before.p, t0=before.t2, p1=this.p, t1=this.t}
						isBefore = true 
						--trace("moving behind , new correctionFactor=",correctionFactor," segLength of edge=",util.calculateSegmentLengthFromNewEdge(edge))
					end
				end
				
				
--				local newP = util.solveForPositionHermiteFraction(correctionFactor, edge).p
				
				local edge =util.createCombinedEdge(before, this ,after)
				--local edgeLength = util.calcEdgeLengthHighAccuracyWithTangentCorrection(edge)
				local edgeLength = util.calcEdgeLengthHighAccuracy({ p0=this.p, t0=this.t2, p1=after.p, t1=after.t}) + util.calcEdgeLengthHighAccuracy({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t})
				local thisTarget = (0.1*thisSegLength+0.9*targetSeglenth)
				local target = isBefore and edgeLength-thisTarget  or  thisTarget
				target = math.min(edgeLength-16, math.max(16, target))
				--if i == 1 then 
				if not isBefore then 
					target = targetSeglenth 
					edge =  { p0=before.p, t0=before.t2, p1=this.p, t1=this.t}
					edgeLength = util.calcEdgeLengthHighAccuracy(edge)
				end
				--if i == numberOfNodes + 1 then 
				if isBefore then 	
					edge =  { p0=this.p, t0=this.t2, p1=after.p, t1=after.t}
					edgeLength = util.calcEdgeLengthHighAccuracy(edge)
					target = edgeLength - targetSeglenth 
				end
				
				target = math.min(edgeLength-16, math.max(16, target)) 
				-- trace("Setting a target length of ",target, " over the combined edge of length",util.calculateSegmentLengthFromNewEdge(edge), " isBefore=",isBefore)
				local solution = util.solveForPositionHermiteLength(math.max(target,0),edge ,1, true)
				if not solution.solutionConverged then 
					trace("WARNING! Solution failed to converge, aborting at i=",i," of iteration",count)
					abort = true
					break 
				end
			--	trace("For a given hermite fraction",correctionFactor," the actual solution was ",solution.f)
				local oldP = this.p
				before.t2=solution.t0
				this.p=solution.p1
				this.t=solution.t1
				this.t2=solution.t2
				 
				after.t=solution.t3
				
				
				if params.isDebugResults then 
					trace("RenormalisSpacing: Moving",oldP.x,oldP.y,"to",solution.p1.x,solution.p1.y,"target=",target,"for long edge. New length: ",util.calcEdgeLengthHighAccuracy({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t}))
				end 
				
				--if i == 1 or i == numberOfNodes then 
					--before.t2 = util.distance(before.p, this.p)*vec3.normalize(before.t2)
					--this.t = util.distance(before.p, this.p)*vec3.normalize(this.t)
					--this.t2 = util.distance(after.p, this.p)*vec3.normalize(this.t2)
					--after.t = util.distance(after.p, this.p)*vec3.normalize(after.t)
					
				--[[local len1 = util.calculateTangentLength(before.p, this.p, before.t2, this.t)
				before.t2 = len1*vec3.normalize(before.t2)
				this.t = len1*vec3.normalize(this.t)
				local len2 = util.calculateTangentLength(this.p, after.p, this.t2, after.t)
				this.t2 = len2*vec3.normalize(this.t2)
				after.t = len2*vec3.normalize(after.t)]]--
				--end 
				
				priorEdgeCorrected = not backwards
				nextEdgeCorrected = backwards
			 -- trace("new edge length =", util.calcEdgeLength(before.p, this.p, before.t2, this.t))
				--  trace("new nexte edge length =",(after and util.calcEdgeLength(this.p, after.p, this.t2, after.t) or 0))
				  previousEdgeTooSmall = false 
				  previousEdgeTooLarge = true 
			elseif thisSegLength < targetSeglenth -tolerance then
				local correctionFactor = math.min(targetSeglenth / thisSegLength, 1+maxCorrectionFactor)-1
				local nextSegLength =  after and util.calcEdgeLength(this.p, after.p, this.t2, after.t) or 0
				--correctionFactor = correctionFactor * (nextSegLength/thisSegLength)
				if params.isDebugResults then 
					trace("i=",i,"This too small segLength=",thisSegLength," targetSeglenth=",targetSeglenth," correctionFactor=",correctionFactor, " nextSegLength=",nextSegLength, " priorEdgeCorrected?",priorEdgeCorrected, "nextEdgeCorrected=",nextEdgeCorrected)
				end
				local edge = after and { p0=this.p, t0=this.t2, p1=after.p, t1=after.t} or nil
				local isBefore = false 
				if  i >1 then  
					local beforeBefore = baseRoute[i-2]
					if i== numberOfNodes+1 or (nextEdgeCorrected and previousEdgeTooSmall) or (util.calcEdgeLengthHighAccuracy({ p0 = beforeBefore.p, p1= before.p, t0=beforeBefore.t2, t1=before.t}) > nextSegLength and (previousEdgeTooLarge or not priorEdgeCorrected)) 
						--or i > numberOfNodes/2 and nextSegLength > targetSeglenth
					then
						
						after = this
						this = before
						before = beforeBefore
						edge = { p0=before.p, t0=before.t2, p1=this.p, t1=this.t}
						correctionFactor = 1 -correctionFactor
						if i == numberOfNodes+1 then 
							correctionFactor = 1-(thisSegLength/targetSeglenth)
						end 
						isBefore = true
					--	trace("detected short length ahead, moving behind, new correctionFactor=",correctionFactor)
					end
				end 
			
				local edge =util.createCombinedEdge(before, this ,after)
				--local edgeLength = util.calcEdgeLengthHighAccuracy(edge)
				local edgeLength = util.calcEdgeLengthHighAccuracy({ p0=this.p, t0=this.t2, p1=after.p, t1=after.t}) + util.calcEdgeLengthHighAccuracy({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t})
				
				local thisTarget = (0.1*thisSegLength+0.9*targetSeglenth)
				local target = isBefore and edgeLength-thisTarget or thisTarget
				target = math.min(edgeLength-16, math.max(16, target))
				local gap = targetSeglenth - thisSegLength 
				--if i == 1 then 
				if not isBefore then	
					edge = { p0=this.p, t0=this.t2, p1=after.p, t1=after.t}
					edgeLength = util.calcEdgeLengthHighAccuracy(edge)
					target = math.min(edgeLength-4, math.max(4,  gap))
				end
				--if i == numberOfNodes + 1 then 
				if isBefore then	
					edge =  { p0=before.p, t0=before.t2, p1=this.p, t1=this.t}
					edgeLength = util.calcEdgeLengthHighAccuracy(edge)
					target = math.min(edgeLength-4, math.max(4, edgeLength-gap))
				end
				
				
				-- trace("Setting a target length of ",target, " over the combined edge of length",util.calculateSegmentLengthFromNewEdge(edge)," gap was ",gap, " isBefore=",isBefore)
				local solution = util.solveForPositionHermiteLength(math.max(target,0), edge, 1, true)
				if not solution.solutionConverged then 
					trace("WARNING! Solution failed to converge, aborting at i=",i," of iteration",count)
					abort = true 
					break 
				end
				local oldP = this.p
				this.p=solution.p1
				this.t=solution.t1
				this.t2=solution.t2
				--if isBefore then 
					before.t2=solution.t0
				--else 
					after.t=solution.t3
				--end 
				if params.isDebugResults then 
					trace("RenormalisSpacing: Moving",oldP.x,oldP.y,"to",solution.p1.x,solution.p1.y,"target=",target,"for short edge. New length: ",util.calcEdgeLengthHighAccuracy({ p0=before.p, t0=before.t2, p1=this.p, t1=this.t}))
				end 

			
				--if i == 1 or i == numberOfNodes then 
				--[[local len1 = util.calculateTangentLength(before.p, this.p, before.t2, this.t)
				before.t2 = len1*vec3.normalize(before.t2)
				this.t = len1*vec3.normalize(this.t)
				local len2 = util.calculateTangentLength(this.p, after.p, this.t2, after.t)
				this.t2 = len2*vec3.normalize(this.t2)
				after.t = len2*vec3.normalize(after.t)]]--
				--end 
				
				priorEdgeCorrected = not backwards
				nextEdgeCorrected = backwards
				--trace("new edge length =", util.calcEdgeLength(before.p, this.p, before.t2, this.t))
				--trace("new nexte edge length =",(after and util.calcEdgeLength(this.p, after.p, this.t2, after.t) or 0))
				previousEdgeTooSmall = true  
				previousEdgeTooLarge = false 
			else 
				priorEdgeCorrected = false
				nextEdgeCorrected = false
				previousEdgeTooSmall = false  
				previousEdgeTooLarge = false 
			end
			local before = baseRoute[i-1]
			local this = baseRoute[i]
			if not this then 
				print("WARNING, no data found at ",i," numberOfNodes is ",numberOfNodes)
			end
			
			if (i == 1 or i == numberOfNodes+1) and (priorEdgeCorrected or nextEdgeCorrected) then 
				--trace("The last edge WAS corrected")
				finalEdgeCorrected = true
			end 
		end
		
		 trace("After applying corrections the maxDivergence was ",maxDivergence)
	until maxDivergence < maxTolerance or count > 10 or abort
	trace("Renormalisation complete after ", count, " iterations time taken: ",(os.clock()-begin))
	assert(util.positionsEqual(endPoint,baseRoute[numberOfNodes+1].p))
	assert(util.positionsEqual(startPoint,baseRoute[0].p))
	--checkForLooping(baseRoute,numberOfNodes, "end renormaliseSpacing") 
	--newRoute[numberOfNodes+1] = baseRoute[numberOfNodes+1]
	profiler.endFunction("renormaliseSpacing")
	return baseRoute
end

local function buildBasicRoute(baseRoute, bestRoute, numberOfNodes, edge)
	local result = {}
	result[0]= { p=baseRoute[0].p, t=baseRoute[0].t, t2=baseRoute[0].t2}
	local previousDirection = 2
	local previousWasDirectionChange = false

	if not edge then 
		edge = {
			p0 = baseRoute[0].p,
			t0 = baseRoute[0].t,
			p1 = baseRoute[numberOfNodes+1].p,
			t1 = baseRoute[numberOfNodes+1].t,
		}
	end 
	for i =1 , numberOfNodes do
		local spiralPoint = false
		local before = i==1 and baseRoute[0].p or util.v3(bestRoute.points[i-1])
		local this = util.v3(bestRoute.points[i], true)
		local after = i == numberOfNodes and baseRoute[numberOfNodes+1].p or util.v3(bestRoute.points[i+1])
		--local direction = bestRoute.directionHistory[i]
		local tangent =computeTangent(before, this, after, i, numberOfNodes, edge)
		local p0 = before
		local p1 = this 
		local t0 = result[i-1].t2 
		local t1 = tangent
		local tangentLength =  util.calculateTangentLength(p0, p1, t0, t1)
		tangent = tangentLength * vec3.normalize(tangent)
		result[i-1].t2 = tangentLength * vec3.normalize(result[i-1].t2)
		local directionChange = false
		--[[if direction ~= previousDirection and direction and previousDirection and not this.realigned then
			directionChange = true
			local change = math.abs(direction-previousDirection)*params.routeDeviationPerSegment
			local baseLen = util.distance(baseRoute[i-1].p, baseRoute[i].p)
			local phi = math.atan2(change, 2*baseLen)
			local angle = math.abs(util.signedAngle(after-this, this-before))
			local r = baseLen / math.tan(phi)
			local r2 = baseLen/math.tan(angle)
			
			local arcLength = (phi/math.rad(90)) * r * 4 * (math.sqrt(2)-1)
			arcLength = math.min(arcLength, 1.1*vec3.length(tangent))
			util.trace("Due to change in direction, ",direction," (was ",previousDirection,") correcting magnitude from ",vec3.length(tangent)," to ", arcLength, " baseLen=",baseLen," change=",change, "phi=",math.deg(phi)," r=",r, " projectedSpeedLimit=",api.util.formatSpeed(calculateProjectedSpeedLimit(r2)), " alternative computation gives r2=",r2," from angle",math.deg(angle))
			
			local edge = {
				p0 = before,
				p1 = after,
				t0 = 2*arcLength * vec3.normalize(this-before),
				t1 = 2*arcLength * vec3.normalize(after-this)
			}
			util.trace("x,y before hermite", this.x, this.y)
			
			if not util.searchForNearestNode(this, 25) then
				this = util.hermite2(0.5, edge).p 
				tangent = arcLength * vec3.normalize(edge.t0+edge.t1)
			end
			util.trace("x,y after hermite", this.x, this.y)
			
			--spiralPoint = true
			if r2 < 200 then 
				thisSmoothingPasses = thisSmoothingPasses + 1
				trace("Increasing smoothing passes to, ",thisSmoothingPasses)
			end
			
			
			--if preCorrectTangents then
				--tangent = arcLength * vec3.normalize(tangent)
				--spiralPoint = true
				 --result[i-1].t = arcLength * vec3.normalize(result[i-1].t)
				-- result[i-1].spiralPoint = true
			--end
			previousWasDirectionChange = true
		elseif previousWasDirectionChange then
			-- tangent = vec3.length(result[i-1].t) * vec3.normalize(tangent)
			 --spiralPoint = true
		else 
			previousWasDirectionChange = false
		end
		previousDirection = direction
		if vec3.length(tangent) < 1 or vec3.length(tangent)~=vec3.length(tangent) then
			debugPrint(result)
			trace("Problem detected with tangent at i=",i)
			
		end]]--
		if tangentLength ~= tangentLength then 
			trace("WARNING! invalid tangent at ",i)
		end
		if baseRoute[i].overiddenHeight then 
			this.z = baseRoute[i].overiddenHeight
		end 
		result[i]={ p = this, t=tangent, t2=tangent , directionChange = directionChange, minHeight=baseRoute[i].minHeight, maxHeight=baseRoute[i].maxHeight, overiddenHeight=baseRoute[i].overiddenHeight}
		if   not util.isValidCoordinate(result[i].p) then
			local pold = result[i].p
			result[i].p = util.bringCoordinateInsideMap(pold)
			trace("WARNING! Had to move point",pold.x,pold.y," to ",result[i].p.x,result[i].p.y)
		end 
	end
	result[numberOfNodes+1]={ p=baseRoute[numberOfNodes+1].p, t=baseRoute[numberOfNodes+1].t, t2=baseRoute[numberOfNodes+1].t2}
	result[0].t2 = vec3.length(result[1].t)*vec3.normalize(result[0].t2)
	result[numberOfNodes+1].t = vec3.length(result[numberOfNodes].t2)*vec3.normalize(result[numberOfNodes+1].t)
	return result 
end

local function buildRouteAndApplySmoothing(baseRoute, bestRoute, numberOfNodes, maxGradFrac, params, boundingRoutes, finalRoute, edge)
	local begin = os.clock()
	profiler.beginFunction("buildRouteAndApplySmoothing")
	local result = buildBasicRoute(baseRoute, bestRoute, numberOfNodes, edge)
	local thisSmoothingPasses = params.smoothingPasses
	trace("Begin smoothing and deconfliction")
	
	--if not finalRoute then 
	routeEvaluation.renormaliseSpacing(result, numberOfNodes, params)
		--checkIfRouteCanBeRealignedToWater(result, numberOfNodes, params)
	--end
	--if not finalRoute then 
	deconflictRouteWithIndustry(result, params,  numberOfNodes)
	local adjustments = deconflictRouteWithBoundingRoutesWithCheck(result, boundingRoutes, params, numberOfNodes)
	local smoothFrom = params.smoothFrom
	local smoothTo = params.smoothTo
	--checkForLooping(result,numberOfNodes, "after deconflictRouteWithBoundingRoutes, before checkRouteForAlignmentToExistingTrack" ) 
	--checkRouteForAlignmentToExistingTrack(result,numberOfNodes, params, boundingRoutes)
	
	if numberOfNodes<=10 then 
		thisSmoothingPasses = 2
	end
	routeEvaluation.applySmoothing(result, numberOfNodes, thisSmoothingPasses, params, edge)
	--end

	if not finalRoute then 
		--checkRouteForAlignmentToExistingTrack(result,numberOfNodes, params, boundingRoutes)
		deconflictRouteWithBoundingRoutesWithCheck(result, boundingRoutes, params, numberOfNodes)
		deconflictRouteWithIndustry(result, params,  numberOfNodes)
	--	checkIfRouteCanBeRealignedToWater(result, numberOfNodes, params)
	else 
		local adjustments2 = deconflictRouteWithBoundingRoutesWithCheck(result, boundingRoutes, params, numberOfNodes)
		if adjustments2.upperAdjustments > adjustments.upperAdjustments or adjustments2.lowerAdjustments > adjustments.lowerAdjustments then
			trace("Detected secondary additional deconfliction, running smoothing, smoothTo was",smoothTo,params.smoothTo,"smoothFrom=",smoothFrom,params.smoothFrom)
			params.smoothTo = math.min(params.smoothTo, smoothTo)
			params.smoothFrom = math.max(params.smoothFrom, smoothFrom)
			
			
			routeEvaluation.applySmoothing(result, numberOfNodes, thisSmoothingPasses, params, edge)
			
		end 
		
		--debugPrint({finalRoute=result})
	end
	trace("End smoothing and deconfliction Time taken:",(os.clock()-begin))
	profiler.endFunction("buildRouteAndApplySmoothing")
	return result
end

	
local function evaluateRouteFromBaseRoute(baseRoute, numberOfNodes, params, maxGradFrac, maxRoutes, behaviour, boundingRoutes ,routeDeviationPerSegment, reverseSearch)
	--if params.isTrack then 
	profiler.beginFunction("evaluateRouteFromBaseRoute")
	profiler.beginFunction("evaluateRouteFromBaseRoute for behaviour "..tostring(behaviour))
	local beginEvaluateRouteFromBaseRoute = os.clock()
	if not testTerrainScoring then 
		--routeEvaluation.renormaliseSpacing(baseRoute, numberOfNodes, params) -- more important for track because of curvature limits
	end
--	local debugResults = util.tracelog and params.drawRoutes
	local debugResults = params.isDebugResults
	local endPoint = baseRoute[numberOfNodes+1].p
	local startPoint = baseRoute[0].p
	local randomCount = 0
	local minDirectionChangeInterval = (params.isTrack or params.isHighway) and 3 or 1 
	local changeDirectionInterval = math.min(9, math.max(minDirectionChangeInterval , math.ceil(numberOfNodes / math.log(maxRoutes,2))))
	local routesToExamine = 0.9
	if changeDirectionInterval > 3 then 
		routesToExamine = 3 / changeDirectionInterval
		changeDirectionInterval = 3
	end 
	local offsetLimit = params.routeEvaluationOffsetsLimit
	
	offsetLimit = math.min(math.max(15, offsetLimit - math.floor(numberOfNodes/10)), offsetLimit)
	if behaviour == 2 then 
		offsetLimit = 2*offsetLimit
	end 
	util.trace("begin evaluate route for ", numberOfNodes," nodes, changeDirectionInterval set to ", changeDirectionInterval, "math.log(routeEvaluationLimit,2)=",math.log(maxRoutes,2)," offsetlimit set to ",offsetLimit, " routesToExamine=",routesToExamine, " behaviour=",behaviour," time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))

	local halfway = math.ceil(numberOfNodes/2)
	local offset = routeDeviationPerSegment
	if behaviour >= 3 then 
		offset = offset / 2
	end 
	if params.currentIterationCount == 0 and behaviour == 2 then 
		offset = 1.5*offset 
	end 
	local function offsetNode(i, offset, validate)
		local p = offset == 0 and baseRoute[i].p or util.nodePointPerpendicularOffset(baseRoute[i].p, baseRoute[i].t,offset)
		if validate and not util.isValidCoordinate(p) then
			local pold = p
			p = util.bringCoordinateInsideMap(p)
			trace("WARNING! Had to move point",pold.x,pold.y," to ",p.x,p.y)
		end 
		return p
	end
	local maxLhsOffsets = {}
	local maxRhsOffsets = {}
	for i = 1, numberOfNodes do 
		local maxOffset =  math.min(offsetLimit, i)*offset
		--local boundingRoute = boundingRoutes[1]
		if i > halfway then 
			maxOffset = math.min(1+numberOfNodes- i, offsetLimit)*offset
	--		boundingRoute = boundingRoutes[2]
		end 
	 	maxLhsOffsets[i]=maxOffset
		maxRhsOffsets[i]=maxOffset
	end 
	  
	for __, i in pairs({1,2,numberOfNodes-1,numberOfNodes}) do
		local maxOffset =  math.min(offsetLimit, i)*offset
		local priorP = baseRoute[i-1].p
		if i > halfway then 
			maxOffset = math.min(1+numberOfNodes- i, offsetLimit)*offset
			priorP = baseRoute[i+1].p
		end 
		local p0 = baseRoute[i].p
		local testWidth = math.max(params.edgeWidth, 2*params.trackWidth)
		for j, proposedOffset in pairs({-maxOffset, maxOffset}) do 
			local testOffset = proposedOffset < 0 and -testWidth or testWidth
			local p1 = offsetNode(i, proposedOffset+ testOffset)
			local hash64 = hashLocation64(p1)
			local constructionsByHash = util.combine(
				routeEvaluation.constructionsBy64TileHash[hashLocation64(p1)], 
				routeEvaluation.constructionsBy64TileHash[hashLocation64(p0)], 
				routeEvaluation.constructionsBy64TileHash[hashLocation64(priorP)]
			)
			
			if constructionsByHash then 
				trace("Checking for collisions At",p1.x,p1.y,"found",#constructionsByHash,"maxOffset=",maxOffset)
				for k, construction in pairs(constructionsByHash) do 
					local lotList = util.getComponent(construction, api.type.ComponentType.LOT_LIST)
					if lotList then 
						for m, lot in pairs(lotList.lots) do 
							local vertices = lot.vertices
							local isCollision = util.checkForCollisionWithPolygon(p0, p1, vertices) or util.checkForCollisionWithPolygon(priorP, p1, vertices)
							if isCollision then 
								trace("Collision found at i=",i,"j=",j)
								if j == 1 then -- TODO: this is overly simplistic, could try to calculate the distance to the obstacle
									maxLhsOffsets[i]=0
								else 
									maxRhsOffsets[i]=0
								end
								break
							end 
						end 
					end 
				
				end 
				
			else 
				trace("No structures found at",p1.x,p1.y)
			end 			
				
			 	
		end 	
	end 	
	for k, boundingRoute in pairs(boundingRoutes) do 
		for i = 1, numberOfNodes do 
			local maxOffset =  math.min(offsetLimit, i)*offset
			--local boundingRoute = boundingRoutes[1]
			if i > halfway then 
				maxOffset = math.min(1+numberOfNodes- i, offsetLimit)*offset
		--		boundingRoute = boundingRoutes[2]
			end 
			
			local p0 = baseRoute[i].p
		 
			local testWidth = math.max(params.edgeWidth, 2*params.trackWidth)
			for j, proposedOffset in pairs({-maxOffset, maxOffset}) do 
				local testOffset = proposedOffset < 0 and -testWidth or testWidth
				local p1 = offsetNode(i, proposedOffset+ testOffset)
				if not util.isValidCoordinate(p1) then 
					trace("Discovered invalid coordinate at ",p1.x,p1.y,"at offset",proposedOffset)
					local distFromMapBoundary, coord  = util.getDistFromMapBoundary(p1)
					local vector = coord == "x" and vec3.new(1,0,0) or vec3.new(0,1,0)
					local angle = math.abs(util.signedAngle(p1-p0,vector))
					if angle > math.rad(90) then 
						angle = math.rad(180) - angle 
					end 
					local cosf = math.cos(angle)
					local correction = (distFromMapBoundary+testWidth) / cosf 
					if proposedOffset < 0 then 
						proposedOffset = proposedOffset + correction 
					else 
						proposedOffset = proposedOffset - correction 
					end 
					trace("Discovered out of bounds point, distFromMapBoundary=",distFromMapBoundary, " attempting to correct at",coord,"angle was",math.deg(angle),"cosf=",cosf,"correction=",correction,"new proposedOffset=",proposedOffset)
					local p1 = offsetNode(i, proposedOffset+ testOffset)
					
					--[[local offset = params.edgeWidth
					local trialDist= util.getDistFromMapBoundary(offsetNode(i, proposedOffset+offset))
					trace("The trailDist was ",trialDist)
					if distFromMapBoundary < trialDist then 
						offset = -offset 
					end 
					local requiredOffset = (trialDist / distFromMapBoundary )*offset 
					trace("Calculated the required offset as ",requiredOffset)
					proposedOffset = proposedOffset + requiredOffset
					p1 = offsetNode(i, proposedOffset)
					local count = 0
					while not util.isValidCoordinate(p1, params.edgeWidth) and count < 200 do 
						local trialDist = util.getDistFromMapBoundary(offsetNode(i, proposedOffset+offset))
						if distFromMapBoundary < trialDist then 
							offset = -offset 
						end 
						proposedOffset = proposedOffset + offset 
						p1 = offsetNode(i, proposedOffset)
						count = count+1
					end ]]--
					if j == 1 then  
						maxLhsOffsets[i]=math.min(maxLhsOffsets[i], math.abs(proposedOffset))
					else  
						maxRhsOffsets[i]=math.min(maxRhsOffsets[i], math.abs(proposedOffset))
					end 
					trace("Moved the node inside the boundary after ",count," iterations is now valid?",util.isValidCoordinate(p1, params.edgeWidth),"newP=",p1.x,p1.y)  
				end  
				local returnAllResults = true
				local ignoreHeight = false 
				if boundingRoute.crossoverPoint and math.abs(i-boundingRoute.crossoverPoint)<5 then 
					ignoreHeight = true
				end 
				
				local collisionPoints = checkIfPointCollidesWithRoute(p0, p1, boundingRoute, ignoreHeight, returnAllResults)
				if debugResults then 
					trace("checking for collision point between",p1.x,p1.y, " baseRoute point was ",p0.x,p0.y,"at i=",i,"found?",collisionPoints,"proposedOffset=",proposedOffset,"ignoreHeight=",ignoreHeight)
				end 
				if collisionPoints  then
					local angledOffSetRequired = 0 
					local collisionPoint = util.evaluateWinnerFromSingleScore(collisionPoints, function(c) return vec2.distance(c, p0) end)
					trace("Got",#collisionPoints,"evaluatated closest as ",collisionPoint.x,collisionPoint.y)
					local theirEdge = util.findEdgeConnectingPoints(collisionPoint.p0, collisionPoint.p1)
					if theirEdge then 
						local tangent = p1-p0
						local ourEdge = { p0 = p0, p1=p1, t0=tangent, t1=tangent}
						local refinedCollisionPoint = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(theirEdge, ourEdge)
						if refinedCollisionPoint then 
							local theirTangent = refinedCollisionPoint.existingEdgeSolution.t1 
							local angle = vec3.angleUnit(util.rotateXY(tangent, math.rad(90)), theirTangent)
							local atanFactor = math.atan(angle)
							angledOffSetRequired = math.min(4*params.trackWidth, params.trackWidth*atanFactor)
							trace("Found refinedCollisionPoint, changing the collision point coordinates from",collisionPoint.x,collisionPoint.y,"to",refinedCollisionPoint.c.x,refinedCollisionPoint.c.y,"theirEdge=",theirEdge,"angle was",math.deg(angle),"atanFactor=",atanFactor,"angledOffSetRequired=",angledOffSetRequired)
							collisionPoint = refinedCollisionPoint.c
						else 
							trace("WARNING! Unable to refine collision point")
						end 
						
					else 
						trace("WARNING! Unable to find their edge")
					end 
					
					local distToCollisonPoint =  vec2.distance(collisionPoint, p0)
					local maxDist =   distToCollisonPoint -testWidth - angledOffSetRequired
					--local newOffset =  proposedOffset <0 and -maxDist or maxDist
					local newOffset = j==2 and maxDist or -maxDist -- hmm need to think about this 
					if maxDist < 0 then 
						trace("WARNING! Maxdist was negative clamping newOffset to zero")
						newOffset = 0
					end 
					local p1 = offsetNode(i, newOffset)
					while(util.checkForCollisionWithConstructionsPoint(p1)) do 
						if j == 2 then 
							newOffset = math.max(newOffset - 5,0)
						else 
							newOffset = math.min(newOffset + 5,0)
						end 
						trace("Found a collision point at the offset point, adjusting to ",p1.x,p1.y)
						if newOffset == 0 then 
							trace("Set back offset to zero")
							break 
						end 
						p1 = offsetNode(i, newOffset)
					end 
					trace("Reducing the offset from ",proposedOffset ,"at i=",i," to ", newOffset," to avoid collison. Newoffset point was ",p1.x,p1.y, " baseRoute point was ",p0.x,p0.y,"dist to collision point was",distToCollisonPoint,"collisionPoint at",collisionPoint.x,collisionPoint.y)
					local invertCondition = false 
					if boundingRoute.crossoverPoint then 
						invertCondition = k == 1 and i > boundingRoute.crossoverPoint or k == 2 and i < boundingRoute.crossoverPoint
					
					end 
					
					if j == 1 then 
						local condition = not boundingRoute.leftHanded
						if invertCondition then 
							condition = not condition 
						end 
						if condition then 
							 maxLhsOffsets[i]=math.min(maxLhsOffsets[i], math.abs(newOffset))
					 	end 
						-- maxLhsOffsets[i]=math.abs(newOffset)
					else 
						local condition = boundingRoute.leftHanded
						if invertCondition then 
							condition = not condition 
						end
						if condition then  
 							maxRhsOffsets[i]=math.min(maxRhsOffsets[i], math.abs(newOffset))
						end
					end 
				end
			end 
			if i == boundingRoute.crossoverPoint then 
				 if boundingRoute.leftHanded then 
					maxRhsOffsets[i]=0
					trace("Clamped maxRhsOffset to zero at crossover point at ",i)
				 else 
					maxLhsOffsets[i]=0
					trace("Clamped maxLhsOffset to zero at crossover point at ",i)
				 end 
			end 
			if i <= params.startAngleCorrections then 
				trace("Detected i<=startAngleCorrections at ",i,"params.startAngleLeftHanded?",params.startAngleLeftHanded)
				if not params.startAngleLeftHanded then 
					maxLhsOffsets[i]=0
					maxLhsOffsets[i+1]=math.min(maxLhsOffsets[i+1] or offset, offset)
				else 
					maxRhsOffsets[i]=0
					maxRhsOffsets[i+1]=math.min(maxRhsOffsets[i+1] or offset, offset) 
				end 
			end 
			if i > numberOfNodes - params.endAngleCorrections then 
				trace("Detected i > numberOfNodes - params.endAngleCorrections at ",i,"numberOfNodes=",numberOfNodes,"endAngleCorrections=",params.endAngleCorrections,"params.endAngleLeftHanded?",params.endAngleLeftHanded)
				if  params.endAngleLeftHanded then -- N.B. inverted compared to the start
					maxLhsOffsets[i]=0
					maxLhsOffsets[i-1]=math.min(maxLhsOffsets[i-1] or offset, offset)
				else 
					maxRhsOffsets[i]=0
					maxRhsOffsets[i-1]=math.min(maxRhsOffsets[i-1] or offset, offset) 
				end 
			end 
		end 
	end 
	
	if params.isWaterFreeRoute then 
		--local maxRange = offset*offsetLimit + 50
		profiler.beginFunction("evaluateOffsetLimits for waterFree route")
		for i = 1, numberOfNodes do 
			local maxOffset =  math.min(offsetLimit, i)
			if i > halfway then 
				maxOffset = math.min(1+numberOfNodes- i, offsetLimit)
			end 
			local maxRange = offset*maxOffset + 50
			local t = vec3.normalize(vec3.new(baseRoute[i].t.x, baseRoute[i].t.y,0))
			local p = baseRoute[i].p
			local t1 = util.rotateXY(t, -math.rad(90))
			local t2 = util.rotateXY(t, math.rad(90))
			local lhs = util.getNearestVirtualRiverMeshContour(p, t1, maxRange)
			if lhs then 
				maxLhsOffsets[i]=lhs.distance - params.edgeWidth-10
			end 
			local rhs = util.getNearestVirtualRiverMeshContour(p, t2, maxRange)
			if rhs then 
				maxRhsOffsets[i]=rhs.distance - params.edgeWidth-10
			end 
		end 
		profiler.endFunction("evaluateOffsetLimits for waterFree route")
	end 
	if debugResults  then 
		debugPrint({maxLhsOffsets=maxLhsOffsets, maxRhsOffsets = maxRhsOffsets})
	end 
	
	
	local offsets = { -offset , 0 , offset}
	--[[local offsetsShuffle= { offsets}
	table.insert(offsetsShuffle,  { offset , 0 , -offset})
	table.insert(offsetsShuffle,  { 0 , -offset , offset})
	table.insert(offsetsShuffle,  { 0 , offset , -offset})
	table.insert(offsetsShuffle,  { -offset ,  offset, 0})
	table.insert(offsetsShuffle,  { offset , -offset , 0})]]--
	local offsetOptions = {}
	local routeCharacteristics = {}
	
	local function checkForCollision(p, t, params) 
		if not util.isValidCoordinate(p) then 
			--return true 
		end
		profiler.beginFunction("checkForCollision")
		local earthWorksRequired = 0
		local p0 = baseRoute[0].p
		local p1 = baseRoute[numberOfNodes+1].p
		local maxHeight = math.min(maxGradFrac*vec2.distance(p, p0)+p0.z,maxGradFrac*vec2.distance(p, p1)+p1.z)
		local minHeight = math.max(-maxGradFrac*vec2.distance(p, p0)+p0.z,-maxGradFrac*vec2.distance(p, p1)+p1.z)		
		local offset = math.max(params.edgeWidth, 5)
		local zOffset = params.minZoffset
		local entities = {}
		if params.collisionCheckMode == 1 then 
			entities = util.findIntersectingEntities(p, offset, zOffset)
		elseif params.collisionCheckMode == 2 then  
			local excludeData = true
			entities =  util.searchForEntities(p, offset, "CONSTRUCTION", excludeData)
		elseif  params.collisionCheckMode == 3 then 
			local excludeData = true
			entities =  util.combine(util.searchForEntities(p, offset, "CONSTRUCTION", excludeData), util.searchForEntities(p, offset, "BASE_EDGE", excludeData))
		elseif  params.collisionCheckMode ==4 then 
			local excludeData = true
			entities =  util.combine(util.searchForEntities(p, offset, "CONSTRUCTION", excludeData), util.searchForEntities(p, offset, "BASE_EDGE", excludeData),  util.searchForEntities(p, offset, "BASE_NODE", excludeData))
		end
		for i, entity in pairs(entities) do 
			local construction = util.getConstruction(entity)
			if construction and #construction.townBuildings == 0  then
				local h = construction.transf:cols(3).z
				local isAirport = string.find(construction.fileName, "airport") or string.find(construction.fileName, "airfield")
				if (h + params.minZoffset < maxHeight or isAirport)  and h-params.minZoffset > minHeight then 
						profiler.endFunction("checkForCollision")
						return true 
				else 
					earthWorksRequired = math.max(earthWorksRequired, params.minZoffset)
				end 
				--return true
			end 
			local streetEdge = util.getStreetEdge(entity)
			if streetEdge and not util.isDeadEndEdgeNotIndustry(entity) then 
				if util.checkCollisionBetweenExistingEdgeAndProposedEdge(entity, p, t, params.targetSeglenth, params.edgeWidth) then 
					local edge = util.getEdge(entity)
					local avgT = util.v3(edge.tangent0)+util.v3(edge.tangent1)
					local angle = util.signedAngle(avgT, t)
					local isCollision = math.abs(angle) < math.rad(15) or math.abs(angle) > math.rad(165)
					--trace("Found potential collision with edge ",entity, " the angle was ",math.deg(angle), " isCollision? ",isCollision)
					if not isCollision and #util.getEdge(entity).objects > 0 then 
						--trace("Found edge objects on edge")
						isCollision = true 
					end
					if isCollision then 
						local h = util.getEdgeMidPoint(entity).z 
						--trace("Inspecting edge for collision, height was ",h," maxHeight=",maxHeight,"minHeight=",minHeight)
						if h + params.minZoffset < maxHeight and h-params.minZoffset > minHeight then 	
							profiler.endFunction("checkForCollision")
							return true 
						else 
							--trace("There is enough space to clear the obstacle")
						end 
					end
					
				end
			end
			local node = util.getComponent(entity, api.type.ComponentType.BASE_NODE) 
			if node then 
				if #util.getSegmentsForNode(entity) > 2 then 
					--trace("Checking collision for multi segment node",entity)
					if util.checkCollisionBetweenExistingNodeAndProposedEdge(entity, p, t, params.targetSeglenth, params.edgeWidth) then 
						local edgeId = util.getSegmentsForNode(entity)[1]
						local h = util.getEdgeMidPoint(edgeId).z 
						--trace("Inspecting node for collision, height was ",h," maxHeight=",maxHeight,"minHeight=",minHeight)
						if h + params.minZoffset < maxHeight and h-params.minZoffset > minHeight then 
							--trace("Determined there is not enough space to pass node ",entity)
							profiler.endFunction("checkForCollision")
							return true 
						else 
							earthWorksRequired = math.max(earthWorksRequired, params.minZoffset)
							--trace("There is enough space to clear the obstacle")
						end 
					end	
				end 
				 
			end 
		end
		if params.isHighway and util.searchForFirstEntity(p, 150, "SIM_BUILDING") then 	
			return true 
		end
		 
		if params.collisionEntities then 
			for entity , bool in pairs(params.collisionEntities) do 
				if entity > 0 then 
					local entityDetails = util.getEntity(entity)
					if entityDetails and entityDetails.type=="CONSTRUCTION" then 
						if #entityDetails.simBuildings > 0 and not params.isCargo then 
							if vec2.distance(p, util.v3fromArr(entityDetails.position)) < 200 then 
								profiler.endFunction("checkForCollision")
								return true 
							end
						end 
					end
				end
			end 
		end
		profiler.endFunction("checkForCollision")
		return false, earthWorksRequired
	end
	local maxAdjustmentOffset = offset / 3
	local function checkAndAdjustAgainstBoundingRoute(i, proposedOffset, boundingRoute)
		profiler.beginFunction("checkAndAdjustAgainstBoundingRoute")
		local p0 = baseRoute[i].p 
		local p1 = offsetNode(i, proposedOffset)
		local t = baseRoute[i].t
		if debugResults then 
			trace("Initial proposedOffset at i=",i,"proposedOffset=",proposedOffset,"p0=",p0.x,p0.y,"p1=",p1.x,p1.y)
		end 
		
		if  i > 2 and i < numberOfNodes-1 then 
		 
			if checkForSoftCollision(p1) then 
				if not checkForSoftCollision(offsetNode(i, proposedOffset+ maxAdjustmentOffset) ) then
					proposedOffset = proposedOffset+maxAdjustmentOffset
					trace("Adjusted  proposed offset at ",i,"by adding",maxAdjustmentOffset)
				elseif not checkForSoftCollision(offsetNode(i, proposedOffset-maxAdjustmentOffset) ) then
					proposedOffset = proposedOffset-maxAdjustmentOffset
					trace("Adjusted  proposed offset at ",i,"by subtracting",maxAdjustmentOffset)
				end
			elseif behaviour >= 3 then 
				local options = {}
				local maxScore =0 
				local minScore = math.huge
				local baseScore
				for j = -1, 1 do 
					local offsetFactor = proposedOffset + j*maxAdjustmentOffset
					local p =  offsetNode(i, offsetFactor)
					local zOffset = math.abs(p.z-util.th(p))
					if zOffset < 5 then 
						zOffset = 0
					end 
					local s1 = scoreNearbyTown(p)
					local s2 = countNearbyEdges(p)
					local s3 = zOffset
					local total = s1+s2+s3 
					maxScore = math.max(maxScore, total)
					minScore = math.min(minScore, total)
					table.insert(options, {
						offsetFactor = offsetFactor,
						p = p,
						scores ={ 
							s1,
							s2,
							s3
						}
					})
				end 
				if maxScore > 0 and minScore~= maxScore then -- only change the offset if we have some scores 
					local newP = util.evaluateWinnerFromScores(options)
					proposedOffset = newP.offsetFactor
					p1 = newP.p
				end
			end 
		end
		if proposedOffset < 0 then 
			--trace("Checking for lhsOffset, found?",maxLhsOffsets[i])
			if maxLhsOffsets[i] then 
				--trace("Found lhsOffset")
				if proposedOffset < -maxLhsOffsets[i] then 
					if debugResults then 
						trace("Constrainging proposedOffset at i=",i,"proposedOffset=",proposedOffset,"to",-maxLhsOffsets[i],"maxLhsOffset")
					end
					proposedOffset= -maxLhsOffsets[i] 
				end 
			end 
		elseif proposedOffset > 0 then 
			-- trace("Checking for rhsOffset, found?",maxRhsOffsets[i])
			if maxRhsOffsets[i] then 
				if proposedOffset > maxRhsOffsets[i] then 
					if debugResults then 
						trace("Constraining proposedOffset at i=",i,"proposedOffset=",proposedOffset,"to",maxRhsOffsets[i],"maxRhsOffset")
					end
					proposedOffset= maxRhsOffsets[i] 
				end 
			end
		end 
		--[[local testWidth = math.max(params.edgeWidth, 2*params.trackWidth)
		local testOffset = proposedOffset < 0 and -testWidth or testWidth
		local collisionPoint = checkIfPointCollidesWithRoute(p0, p1, boundingRoute) or  checkIfPointCollidesWithRoute(p0, offsetNode(i, proposedOffset + testOffset), boundingRoute)
		 trace("checking for collision point between",p1.x,p1.y, " baseRoute point was ",p0.x,p0.y,"at i=",i,"found?",collisionPoint,"proposedOffset=",proposedOffset)
		if collisionPoint and offset ~= 0 then
			local distToCollisonPoint =  vec2.distance(collisionPoint, p0)
			local maxDist =   distToCollisonPoint -testWidth
			--local newOffset =  proposedOffset <0 and -maxDist or maxDist
			local newOffset = boundingRoute.leftHanded and maxDist or -maxDist
			p1 = offsetNode(i, newOffset)
			trace("Reducing the offset from ",proposedOffset ,"at i=",i," to ", newOffset," to avoid collison. Newoffset point was ",p1.x,p1.y, " baseRoute point was ",p0.x,p0.y,"dist to collision point was",distToCollisonPoint)
			if math.abs(newOffset) < 1 then 
				return 0 -- prevent numerical instability
			end
			return newOffset
		end]]--
		if i<=2 or i >= numberOfNodes-1 then  
			local pInd 
			if i <=2 then 
				pInd = params.industryNearStart
			else 
				pInd = params.industryNearEnd
			end 
			if pInd then 
				profiler.beginFunction("Check min dist to industry")
				local testPoint = i<=2 and baseRoute[0].p or baseRoute[numberOfNodes+1].p
				local tangent = i<=2 and baseRoute[0].t or -1*baseRoute[numberOfNodes+1].t
				local function minDistToIndustry(proposedOffset) 
					local offsetPoint = offsetNode(i, proposedOffset ) 
					local edge = { 
						p0 = testPoint ,
						p1 = offsetPoint, 
						t0 = tangent,
						t1 = offsetPoint-testPoint
					}
					local minDist = math.huge 
					for i =  0, 8 do  
						local p = util.hermite2(i/8, edge).p
						local dist = util.distance(p, pInd)
						minDist = math.min(minDist, dist)
					end 
				--	trace("Inspecting min dist to industry at ",i," proposedOffset=",proposedOffset,"minDist=",minDist)
					return minDist 
				end  
--				local offsetPoint = offsetNode(i, proposedOffset ) 
--				local distance = util.distance(pInd, offsetPoint)
				local count = 0  
				local originalOffset = proposedOffset
				local minDist = minDistToIndustry(proposedOffset)
				 
				while minDist < params.minDistToIndustryThreshold and count < 20 do 
					if minDistToIndustry(proposedOffset+5) < minDistToIndustry(proposedOffset-5) then 
						proposedOffset = proposedOffset - 5
					else 
						proposedOffset = proposedOffset + 5
					end 
					minDist = minDistToIndustry(proposedOffset)
					count = count + 1
				end 
				trace("After check for collision min dist was",minDist,", was resolved? after",count,"proposedOffset=",proposedOffset)
				profiler.endFunction("Check min dist to industry")
			end 
			
			
		end
		--[[
		if i<=2 or i >= numberOfNodes-1 then 
			local testPoint = i<=2 and baseRoute[0].p or baseRoute[numberOfNodes+1].p
			local testOffset = (boundingRoute.leftHanded and -params.edgeWidth or params.edgeWidth)
			local collisionPoint = checkIfPointCollidesWithRoute(testPoint, offsetNode(i, proposedOffset + testOffset) , boundingRoute)
			local count = 0
			local adjustedOffset = proposedOffset
			local hadCollisionPoint = collisionPoint
			while collisionPoint and count < 20 do
				count = count + 1
				local delta = boundingRoute.leftHanded and 5*count or -5*count 
				
				--local delta = 5*math.ceil(count / 2)
				--if count % 2 == 0 then delta = -delta end 
				adjustedOffset = proposedOffset + delta 
				local p1 = offsetNode(i, adjustedOffset +testOffset)
				collisionPoint = checkIfPointCollidesWithRoute(testPoint, p1, boundingRoute)
				trace("Adjusting offsetpoint by ",delta," did it collide?",collisionPoint," count = ",count)	
				if not collisionPoint then 
					trace("Collision was resolved at offset = ",proposedOffset, " at count = ",count)
				end
			end 
			if collisionPoint then 
				trace("WARNING! Collision was still not resolved at i",i)
			elseif hadCollisionPoint then 
				trace("At i = ",i,"adjusted the offset to ",adjustedOffset,"from",proposedOffset)
				return adjustedOffset
			end
		end ]]--
		
		if i <= 3 and (params.isTrack or params.isHighway) and proposedOffset~=0 then 
			local vectorToOffsetNode = p1-baseRoute[0].p 
			local angle = util.signedAngle(vectorToOffsetNode, baseRoute[0].t)
			--trace("Start angle of offset, " ,proposedOffset, " was ",math.deg(angle))
			local lastOffset = proposedOffset
			local sign =proposedOffset > 0  
			local count = 0
			local maxAngle = params.minimumAngle
			if i ==2 then	
				maxAngle = maxAngle * 1.5
			elseif i == 3 then 
				maxAngle = maxAngle * 2
			end
			local maxOffsetHere = (i)*paramHelper.getParams().routeDeviationPerSegment
			if debugResults then 
				trace("At i =",i,"with proposed offset",proposedOffset,"the angle was",math.deg(angle),"exceeds limit?",math.deg(maxAngle),"?",(math.abs(angle)>maxAngle))
			end
			if math.abs(angle) > maxAngle then 	
				local dist =  vec3.length(vectorToOffsetNode)
				local a = math.asin(math.abs(proposedOffset) /dist) -- relative angle to the base route
				local delta =math.abs(angle) - maxAngle   -- change required to get to the max angle 
				local epsilon = math.max(a - delta,0) -- the max allowable angle against the base route at zero offset
				trace("calculated the angle a as",math.deg(a),"delta=",math.deg(delta),"epsilon as",math.deg(epsilon),"dist=",dist)
				if epsilon == 0 or a~=a then -- the base route should already have been controlled for this so not expected
					trace("WARNING! The zero offset solution already exceeds the max angle")
					return 0 
				end 
				local newOffset = math.sin(epsilon)*dist 
				if proposedOffset < 0 then 
					newOffset = -newOffset 
				end
				p1 = offsetNode(i, newOffset)
				vectorToOffsetNode = p1-baseRoute[0].p
				local newAngle = util.signedAngle(vectorToOffsetNode, baseRoute[0].t)
				trace("recalculated the new offset as",newOffset,"from original", proposedOffset,"after treatment the new recalculated angle was",math.deg(newAngle),"vs",math.deg(angle),"at i=",i)
				proposedOffset= newOffset
			end 
		end
			--[[while math.abs(angle) > maxAngle and count < 100 and math.abs(proposedOffset)<=maxOffsetHere do
				count = count + 1
				if sign then
					proposedOffset = proposedOffset -1
				else 
					proposedOffset = proposedOffset + 1
				end
				p1 = offsetNode(i, proposedOffset)
				vectorToOffsetNode = p1-baseRoute[0].p 
				local angleBefore = angle
				trace("With angle of offset, " ,proposedOffset, " was ",math.deg(angle),"at i=",i,"p1=",p1.x,p1.y)
				angle = util.signedAngle(vectorToOffsetNode, baseRoute[0].t)
				if math.abs(angle) > math.abs(angleBefore) then 
					trace("Offset got worse, inverting sign")
					sign = not sign
				end
				-- trace("Start offset was adjusted, new offset, " ,proposedOffset, " new angle ",math.deg(angle))
				if checkIfPointCollidesWithRoute(p0, p1, boundingRoute) then
					trace("Offset adjustment cancelled due to collision with bounding route at ",i)
					proposedOffset = lastOffset
					break 
				end
				lastOffset = proposedOffset
			end]]--
		
			
		
		if  i > 2 and i < numberOfNodes-1 then 
			local t = baseRoute[i].t 
			local maxOffsetFactor = params.isTrack and 0.2 or 0.5
			if checkForCollision(p1,t, params) then 
				if not checkForCollision(offsetNode(i, proposedOffset+maxOffsetFactor*offset), t, params) then
					proposedOffset = proposedOffset+0.5*offset
					trace("Adjusted  proposed offset at ",i,"by adding",0.5*offset)
				elseif not checkForCollision(offsetNode(i, proposedOffset-maxOffsetFactor*offset), t,params) then
					proposedOffset = proposedOffset-0.5*offset
					trace("Adjusted  proposed offset at ",i,"by subtracting",0.5*offset)
				end
			end
		end
		
		if i >= numberOfNodes-2 and (params.isTrack or params.isHighway) and proposedOffset~=0  then
			local vectorToOffsetNode = baseRoute[numberOfNodes+1].p -p1
			local angle = util.signedAngle(vectorToOffsetNode, baseRoute[numberOfNodes+1].t)
			--trace("End angle of offset, " ,proposedOffset, " was ",math.deg(angle))
			local lastOffset = proposedOffset
			local sign = proposedOffset > 0 
			local count = 0
			local maxAngle = params.minimumAngle
			if i == numberOfNodes -1 then 
				maxAngle = 1.5*maxAngle
			elseif i == numberOfNodes -2 then 
				maxAngle = 2*maxAngle
			end
			
			if math.abs(angle) > maxAngle then 	
				local dist =  vec3.length(vectorToOffsetNode)
				local a = math.asin(math.abs(proposedOffset) /dist) -- relative angle to the base route
				local delta =math.abs(angle) - maxAngle   -- change required to get to the max angle 
				local epsilon = math.max(a - delta,0) -- the max allowable angle against the base route at zero offset
				trace("calculated the angle a as",math.deg(a),"delta=",math.deg(delta),"epsilon as",math.deg(epsilon))
				if epsilon == 0 or a ~= a then -- the base route should already have been controlled for this so not expected
					trace("WARNING! The zero offset solution already exceeds the max angle")
					return 0 
				end 
				local newOffset = math.sin(epsilon)*dist 
				if proposedOffset < 0 then 
					newOffset = -newOffset 
				end
				p1 = offsetNode(i, newOffset)
				vectorToOffsetNode = baseRoute[numberOfNodes+1].p -p1
				local newAngle = util.signedAngle(vectorToOffsetNode, baseRoute[numberOfNodes+1].t)
				trace("recalculated the new offset as",newOffset,"from original", proposedOffset,"after treatment the new recalculated angle was",math.deg(newAngle),"vs",math.deg(angle),"at i=",i)
				proposedOffset = newOffset
			end 
			
			--[[local maxOffsetHere = (i-numberOfNodes)*paramHelper.getParams().routeDeviationPerSegment
			while math.abs(angle) > maxAngle and count < 100 and math.abs(proposedOffset) <= maxOffsetHere do
				count = count + 1
				if sign then
					proposedOffset = proposedOffset -1
				else 
					proposedOffset = proposedOffset + 1
				end
				p1 = offsetNode(i, proposedOffset)
				vectorToOffsetNode = baseRoute[numberOfNodes+1].p -p1
				local angleBefore = angle
				
				angle = util.signedAngle(vectorToOffsetNode, baseRoute[numberOfNodes+1].t)
				if math.abs(angle) > math.abs(angleBefore) then 
					trace("Offset got worse, inverting sign , maxAngle=",math.deg(maxAngle)," angle was ",math.deg(angle))
					sign = not sign
				end
				trace("End offset was adjusted, new offset, " ,proposedOffset, " end angle new angle ",math.deg(angle))
				if checkIfPointCollidesWithRoute(p0, p1, boundingRoute) then
					trace("Offset adjustment cancelled due to collision with bounding route at ",i)
					proposedOffset= lastOffset
					break
				end
				lastOffset = proposedOffset
			end]]--
		end
		if i == 1 or i == numberOfNodes
		or (params.isTrack and (i == 2 and util.th(baseRoute[0].p)< 15+util.getWaterLevel() or i == numberOfNodes-1 and util.th(baseRoute[numberOfNodes+1].p)<15+util.getWaterLevel())) 
		then 
			while util.th(offsetNode(i, proposedOffset)) < util.getWaterLevel() do  -- avoid having first or last offset in water
				if debugResults then 
					trace("Modifying proposed offset to avoid water:",proposedOffset)
				end 
				if proposedOffset > 5 then
					proposedOffset = proposedOffset -5
				elseif proposedOffset < -5 then
					proposedOffset = proposedOffset + 5
				else 
					break
				end
			end
		end
		-- once discovered a route that does not cross water, restrict the route to avoid it
		---if params.isWaterFreeRoute then 
			if debugResults then 
				--trace("WaterFree route, checking proposedOffset=",proposedOffset)
			end 
		
			
			--[[while util.th(offsetNode(i, proposedOffset)) < 0 and proposedOffset ~=0 do
				if proposedOffset > 5 then
					proposedOffset = proposedOffset -5
				elseif proposedOffset < -5 then
					proposedOffset = proposedOffset + 5
				else 
					if debugResults then 
						trace("WaterFree route, adjusted proposedOffset to ",proposedOffset)
					end 
					return proposedOffset
				end
			end]]--
		--[[else 
			if i < numberOfNodes and i >1 and false then -- temporarily disabled
				local testp = offsetNode(i,proposedOffset+ params.edgeWidth)
				local testp2 = offsetNode(i,proposedOffset- params.edgeWidth)
				if util.isUnderwater(p1) then 
					if util.th(testp) > 0 then 
						for j = 1, math.ceil(params.edgeWidth*1.5) do
							 
							if util.th(offsetNode(i, proposedOffset+j - 0.5*params.edgeWidth)) > 0 then 
								trace("Adjusted offset to decollide with water",j, " proposedOffset=",proposedOffset," newoffset=",proposedOffset+j)
								return proposedOffset+j
							end
						end
					elseif util.th(testp2) > 0 then 
						for j = -1, -math.ceil(params.edgeWidth*1.5),-1 do
							 
							if util.th(offsetNode(i, proposedOffset+j + 0.5*params.edgeWidth)) > 0 then 
								trace("Adjusted offset to decollide with water by ",j, " proposedOffset=",proposedOffset," newoffset=",proposedOffset+j)
								return proposedOffset+j
							end
						end
					end 
				else 
					if util.isUnderwater(testp) then 
						for j = math.ceil(params.edgeWidth*1.5), 1,-1 do
							if util.th(offsetNode(i, proposedOffset+j - 0.5*params.edgeWidth)) > 0 then 
								trace("Adjusted offset to ensure no collision with water",j, " proposedOffset=",proposedOffset," newoffset=",proposedOffset+j)
								return proposedOffset+j
							end
						end
					elseif util.isUnderwater(testp2) then 
						for j =  -math.ceil(params.edgeWidth*1.5),-1  do
							if util.th(offsetNode(i, proposedOffset+j + 0.5*params.edgeWidth)) > 0 then 
								trace("Adjusted offset to ensure no collision with water by ",j, " proposedOffset=",proposedOffset," newoffset=",proposedOffset+j)
								return proposedOffset+j
							end
						end
					end 
				end 
			end
			
		end]]--
		p1 = offsetNode(i, proposedOffset) -- recompute just in case
		local hash =hashIndustryLocation(p1)
		if routeEvaluation.industryLocationsByHash[hash] and i > 1 and i < numberOfNodes then 
			local pInd = routeEvaluation.industryLocationsByHash[hash]
			local deltaZ = math.abs(pInd.z-p1.z)
			local distToIndustry = vec2.distance(pInd, p1)
			local industryOffsetRequired = 180
			if deltaZ < 25 and distToIndustry < industryOffsetRequired then -- TODO: there must be a mistake in the maths here because it is not ending up with the exact offset required
				trace("Found a potential industry collision at i=",i,"position=",p1.x,p1.y,"pInd at ",pInd.x,pInd.y,"deltaZ=",deltaZ,"distToIndustry=",distToIndustry,"at proposedOffset=",proposedOffset)
				local industryVector = pInd - p1
				
				local perpVector = vec3.normalize(util.rotateXY(vec3.new(t.x, t.y, 0), math.rad(90)))
				local angle = util.signedAngle(industryVector, t)
				local sign = angle < 0 and  -1 or 1 
				
				local requiredOffset = industryOffsetRequired-distToIndustry
				
				-- cosine rule a^2 = b^2 + c^2 - 2bc*cos(A)
				local A = math.rad(270)-math.abs(angle)
				local a = distToIndustry
				local b = industryOffsetRequired 
				-- =   [c^2] - [2bc*cos(A)] + [b^2-a^2] = 0
				-- aQuad = 1
				-- bQuad = -2b*cos(A)
				-- cQuad = b^2-a^2 
				local aQuad = 1
				local bQuad = -2*b*math.cos(A)
				local cQuad = b^2-a^2 
				local quadradticFactor = bQuad^2 - 4*cQuad
				if quadradticFactor > 0 then 
					local result = (-bQuad + math.sqrt(quadradticFactor))/2
					local result2 = (-bQuad - math.sqrt(quadradticFactor))/2
					trace("After inspecting the cosine rule results were",result,result2,"original offset required =",requiredOffset)
					if math.abs(result) < requiredOffset then 
						trace("Unexpected result",result,"should be at least",requiredOffset," quadradticFactor was  ",quadradticFactor," the bQuad was",bQuad," the angle A was",math.deg(A),"the cQuad was ",cQuad)
					end 
					requiredOffset = math.max(requiredOffset, math.abs(result))
				else 
					trace("WARNING! quadradticFactor was negative",quadradticFactor," the bQuad was",bQuad," the angle A was",math.deg(A),"the cQuad was ",cQuad)
				end 
				local oldProposedOffset = proposedOffset
				proposedOffset = sign*requiredOffset + proposedOffset
				p1 = offsetNode(i, proposedOffset)
				local newDistToIndustry = vec2.distance(pInd, p1)
			
				trace("After analsying new position",p1.x,p1.y," the angle was",math.deg(angle),"the sign",sign,"the requiredOffset",requiredOffset,"proposedOffset=",proposedOffset,"newDistToIndustry=",newDistToIndustry,"offsetChange was",math.abs(proposedOffset-oldProposedOffset),"oldProposedOffset=",oldProposedOffset,"p1=",p1.x,p1.y)
				if newDistToIndustry < distToIndustry then
					trace("WARNING!, failed to correct, new dist was",newDistToIndustry,"compared to ",distToIndustry,"reverting")
					proposedOffset = oldProposedOffset
				end 
			end
		end 
		if proposedOffset < 0 then 
			--trace("Checking for lhsOffset, found?",maxLhsOffsets[i])
			if maxLhsOffsets[i] then 
				--trace("Found lhsOffset")
				if proposedOffset < -maxLhsOffsets[i] then 
					if debugResults then 
						trace("Constrainging proposedOffset at i=",i,"proposedOffset=",proposedOffset,"to",-maxLhsOffsets[i],"maxLhsOffset")
					end
					proposedOffset= -maxLhsOffsets[i] 
					
				end 
			end 
		elseif proposedOffset > 0 then 
			-- trace("Checking for rhsOffset, found?",maxRhsOffsets[i])
			if maxRhsOffsets[i] then 
				if proposedOffset > maxRhsOffsets[i] then 
					if debugResults then 
						trace("Constrainging proposedOffset at i=",i,"proposedOffset=",proposedOffset,"to",maxRhsOffsets[i],"maxRhsOffset")
					end
					proposedOffset= maxRhsOffsets[i] 
				end 
			end
		end 
		if debugResults then 
			trace("Final proposedOffset at i=",i,"proposedOffset=",proposedOffset,"p0=",p0.x,p0.y,"p1=",p1.x,p1.y)
		end 
		profiler.endFunction("checkAndAdjustAgainstBoundingRoute")
		return proposedOffset
	end
	
	
	local function scoreNearbyEdges(p, t, n )
		if n == 1 or n == numberOfNodes then 
			return 0 -- avoid scoring connecting edges
		end
		local score =0 
		if simplifiedEdgeScoring then 
			return countNearbyEdges(p)
			--return util.countNearbyEntitiesCached(p, params.targetSeglenth/2, "BASE_EDGE")
		--	return #game.interface.getEntities({radius=params.targetSeglenth/2, pos={p.x, p.y}}, {type="BASE_EDGE", includeData=false})
		end
		for i, edgeId  in pairs(game.interface.getEntities({radius=params.targetSeglenth/2, pos={p.x, p.y}}, {type="BASE_EDGE", includeData=false})) do
			--local edge = util.getEdge(edgeId)
			local naturalTangent = util.getNaturalTangent(edgeId) --util.nodePos(edge.node1) - util.nodePos(edge.node0)
			local angle = math.abs(util.signedAngle(t, naturalTangent))
			if angle > math.rad(90) then 
				angle = math.abs(math.rad(180)-angle)
			end 
			local comparativeAngle =  math.abs(math.rad(90)-angle) -- preference for perpendicular edges
			if params.isHighway and util.getStreetTypeCategory(edgeId) == "highway" then 
				comparativeAngle = (1+comparativeAngle)^2
			end 
			score = score + 1 + comparativeAngle
		end
		if not params.isElevated and not params.isUnderground then 
			return score*score -- square the result to keep away from congested areas
		end
		return score
	end
	

	
	local function scoreWater(thisPoint, i, terrainHeight,offset)
		local waterLevel = util.getWaterLevel()
		if waterMeshUtil.isPointOnWaterMeshTile(thisPoint)  then -- for performance not doing a complete scan of every point
			local score = math.min(math.abs(terrainHeight), 20)-- need to cap the score to avoid peculiar routes over water
			local priorPoint = util.nodePointPerpendicularOffset(baseRoute[i-1].p, baseRoute[i-1].t,offset )
			local nextPoint = util.nodePointPerpendicularOffset(baseRoute[i+1].p, baseRoute[i+1].t,offset )
		
			if util.isUnderwater(priorPoint) then -- avoid double scoring
				priorPoint = priorPoint +  0.5*(thisPoint-priorPoint)
			end 
			if util.isUnderwater(nextPoint) then 
				nextPoint =thisPoint +0.5*(nextPoint-thisPoint)
			end
			local vecToThis = thisPoint-priorPoint
			local dist = vec3.length(vecToThis)
			local numSamples = math.floor(dist/4) 
			--trace("Sampling water points before at ",numSamples)
			for j = 4, numSamples, 4 do 
				local p = (j/dist)*vecToThis + priorPoint
				for sign = -2, 2  do 
					local offsetPoint = util.nodePointPerpendicularOffset(p, baseRoute[i].t, 2*sign*params.edgeWidth)
					local th = util.th(offsetPoint)
					if th < waterLevel then 
						score = score +  math.min(math.abs(waterLevel-th) ,20)
					end 
				end
			end 
			local vecFromThis = nextPoint-thisPoint
			local dist = vec3.length(vecFromThis)
			local numSamples = math.floor(dist/4) 
			--trace("Sampling water points after at ",numSamples)
			for j = 4, numSamples, 4 do 
				local p = (j/dist)*vecFromThis + thisPoint
				
				for sign = -1, 1  do 
					local offsetPoint = util.nodePointPerpendicularOffset(p, baseRoute[i].t, 2*sign*params.edgeWidth)
					local th = util.th(offsetPoint)
					if th < waterLevel then 
						score = score +  math.min(math.abs(th) ,20)
					end 
				end
			end 
		 
			return score
		else 
			return 0
		end 
	end
	
	trace("Building offsets and route characteristics")
	local beginOffsets = os.clock()
	profiler.beginFunction("Build offsets")
	
	local maxOffsets = {}
	for i = 1, numberOfNodes do 
		local maxOffset =  math.min(offsetLimit, i)
		if i > halfway then 
			maxOffset = math.min(1+numberOfNodes- i, offsetLimit)
		end  
		if i <= params.startAngleCorrections or i > numberOfNodes-params.endAngleCorrections then 
			trace("Reducing maxOffset at ",i,"for start or end corrections")
			maxOffset = maxOffset / 2
		end 
		-- NB on a tight corner offset points may intersect from front and/or rear, need to adjust to avoid
		local factor = 2
		local maxLhsOffset = -maxOffset *offset
		local p1 = baseRoute[i-1].p
		local p2 = util.nodePointPerpendicularOffset(p1, baseRoute[i-1].t, maxLhsOffset*factor )
		local p3 = baseRoute[i].p 
		local p4 = util.nodePointPerpendicularOffset(p3, baseRoute[i].t, maxLhsOffset*factor )
		local p5 = baseRoute[i+1].p
		local p6 = util.nodePointPerpendicularOffset(p5, baseRoute[i+1].t, maxLhsOffset*factor )
		
		local c1 = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
		local c2 = util.checkFor2dCollisionBetweenPoints(p3, p4, p5, p6)
		local lhsCollision = c1 or c2 
		local function adjust(distance) 
			return math.max(0, distance*0.5 - params.edgeWidth)
		end
		if lhsCollision    then 
			trace("Found LHS collision at ",i," c1=",c1,"c2=",c2," maxLhsOffset=",maxLhsOffset )
			if c1 then 
				maxLhsOffset = -math.min(-maxLhsOffset, adjust(vec2.distance(c1, p3)))
				trace("Adjusted maxLhsOffset to ",maxLhsOffset, " for c1",c1.x,c1.y)
				if util.tracelog then 
					p2 = util.nodePointPerpendicularOffset(p1, baseRoute[i-1].t, maxLhsOffset )
					p4 = util.nodePointPerpendicularOffset(p3, baseRoute[i].t, maxLhsOffset )
					assert(not  util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4))
				end 
			end 
			if c2 then 
				maxLhsOffset = -math.min(-maxLhsOffset, adjust(vec2.distance(c2, p3)))
				trace("Adjusted maxLhsOffset to ",maxLhsOffset, " for c2",c2.x,c2.y)
			end 
		end 
		local maxRhsOffset = maxOffset *offset
		 
		p2 = util.nodePointPerpendicularOffset(p1, baseRoute[i-1].t,  maxRhsOffset*factor )
		p4 = util.nodePointPerpendicularOffset(p3, baseRoute[i].t, maxRhsOffset *factor)
		p6 = util.nodePointPerpendicularOffset(p5, baseRoute[i+1].t, maxRhsOffset *factor)
		
		c1 = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
		c2 = util.checkFor2dCollisionBetweenPoints(p3, p4, p5, p6)
		local rhsCollision = c1 or c2 
		if rhsCollision   then 
			trace("Found RHS collision at ",i," c1=",c1,"c2=",c2," maxRhsOffset=",maxRhsOffset )
			if c1 then 
				maxRhsOffset = math.min(maxRhsOffset, adjust(vec2.distance(c1, p3)))
				trace("Adjusted maxRhsOffset to ",maxRhsOffset, " for c1",c1.x,c1.y)
			end 
			if c2 then 
				maxRhsOffset = math.min(maxRhsOffset, adjust(vec2.distance(c2, p3)))
				trace("Adjusted maxRhsOffset to ",maxRhsOffset, " for c2",c2.x,c2.y)
			end 
		end 
		table.insert(maxOffsets, { maxRhsOffset = maxRhsOffset, maxLhsOffset = maxLhsOffset})
		maxLhsOffsets[i] = math.min(maxLhsOffsets[i], math.abs(maxLhsOffset))
		maxRhsOffsets[i] = math.min(maxRhsOffsets[i], math.abs(maxRhsOffset))
		if rhsCollision then 
			if i>1 then 
				maxRhsOffsets[i-1] = math.min(maxRhsOffsets[i-1], math.abs(maxRhsOffset)+offset)
			end 
			if i<numberOfNodes then 
				maxRhsOffsets[i+1] = math.min(maxRhsOffsets[i+1], math.abs(maxRhsOffset)+offset)
			end 
		end 
		if lhsCollision then 
			if i>1 then 
				maxLhsOffsets[i-1] = math.min(maxLhsOffsets[i-1], math.abs(maxLhsOffset)+offset)
			end 
			if i<numberOfNodes then 
				maxLhsOffsets[i+1] = math.min(maxLhsOffsets[i+1], math.abs(maxLhsOffset)+offset)
			end 
		end 
		local oldOffsetLimit = offsetLimit
		if math.abs(maxLhsOffset) < maxOffset *offset then 
			offsetLimit = math.min(offsetLimit, 2+math.ceil(math.abs(maxLhsOffset)/offset))
			trace("adjusting the offset limit down to ",offsetLimit,"was",oldOffsetLimit,"for lhs collision")
		end 
		if  maxRhsOffset  < maxOffset*offset then 
			offsetLimit = math.min(offsetLimit, 2*math.ceil(maxRhsOffset/offset))
			trace("adjusting the offset limit down to ",offsetLimit,"was",oldOffsetLimit,"for rhs collision")
		end 
		offsetLimit = math.max(offsetLimit, 5)
	end 
	for i = 2, numberOfNodes-1 do
		local pad = 1.5*offset
	  	maxLhsOffsets[i] = math.min(maxLhsOffsets[i], math.min( maxLhsOffsets[i-1]+pad,  maxLhsOffsets[i+1]+pad))
	 	maxRhsOffsets[i] = math.min(maxRhsOffsets[i], math.min( maxRhsOffsets[i-1]+pad,  maxRhsOffsets[i+1]+pad))
		 
	end
	for i = 1, numberOfNodes do 
		local bIdx = i <= halfway and 1 or 2
		--trace("At i=",i,"the bounding route index bIdx=",bIdx)
		local options = {  0 }
		
		local maxOffset =  math.min(offsetLimit, i)
		if i > halfway then 
			maxOffset = math.min(1+numberOfNodes- i, offsetLimit)
		end  
		local maxLhsOffset = maxOffsets[i].maxLhsOffset
		local maxRhsOffset = maxOffsets[i].maxRhsOffset
		for j = 1, maxOffset do
			--[[local lhsOffset = (j/maxOffset)*maxLhsOffset
			if not lhsCollision then 
				assert(math.abs(lhsOffset +j*offset)<0.1, "expected "..tostring(-j*offset).." but was "..lhsOffset)
			end 
			local rhsOffset = (j/maxOffset)*maxRhsOffset
			if not rhsCollision then 
				assert(math.abs(rhsOffset -j*offset)<0.1, "expected "..tostring(j*offset).." but was "..rhsOffset)
			end]]--
			
			
			local lhsOffset = math.max(-j*offset, maxLhsOffset)
			local rhsOffset = math.min(j*offset, maxRhsOffset)
			--local lhsOffset =  -j*offset  
			--local rhsOffset =  j*offset 
			table.insert(options, 1, math.max(checkAndAdjustAgainstBoundingRoute(i,lhsOffset, boundingRoutes[bIdx]), maxLhsOffset))
			table.insert(options, math.min(checkAndAdjustAgainstBoundingRoute(i,rhsOffset, boundingRoutes[bIdx]), maxRhsOffset))
		end
		offsetOptions[i]=options 
	
	end 
	profiler.endFunction("Build offsets")
	trace("Offsets built. Time taken:",(os.clock()-beginOffsets)," time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))
	--if util.tracelog then debugPrint({offsetOptions=offsetOptions}) end
	profiler.beginFunction("Build route characteristics")
	local beginRoutCharacteristics = os.clock()
	local count = 0
	local startP = baseRoute[0].p
	local endP = baseRoute[numberOfNodes+1].p
	local maxGradient = params.maxGradient
	local cacheHits = 0
	if not params.routeCharactericsCache then 
		params.routeCharactericsCache = {}
	end 
	local lowerOffsetBoundary = math.min( math.floor(halfway), offsetLimit)
	local upperOffsetBoundary = 1+numberOfNodes-math.min(math.floor(halfway), offsetLimit)
	local function computeOffsetIdxChange(i, j)
		if reverseSearch then 
			return (i>=upperOffsetBoundary and (j-2)+1 or i<lowerOffsetBoundary and (j-2) -1 or j-2)
		else 
			return (i<=lowerOffsetBoundary and (j-2)+1 or i>upperOffsetBoundary and (j-2) -1 or j-2)
		end
	end
	local preliminaryScoreIdxs = { -- not included the curvature at this stage
		scoreEarthWorksIdx,
		scoreRouteHeightsIdx,
		scoreRouteNearbyEdgesIdx,
		scoreRouteFarmsIdx,
		scoreDistanceIdx,
		scoreWaterPointsIdx,
		scoreRouteNearbyTownsIdx
	}
	local shouldScoreWater = params.routeScoreWeighting[scoreWaterPointsIdx]>0
	
	
	local shouldScoreNearbyEdges = params.routeScoreWeighting[scoreRouteNearbyEdgesIdx]>0
	local shouldScoreNearbyTowns = params.routeScoreWeighting[scoreRouteNearbyTownsIdx]>0
	trace("shouldScoreWater?",shouldScoreWater," shouldScoreNearbyEdges?",shouldScoreNearbyEdges, "shouldScoreNearbyTowns?",shouldScoreNearbyTowns)
	local maxScores = {
		5, -- earthworks 
		10, -- terrain height 
		0, -- nearbyEdges
		0, -- nearFarms
		0, -- distance 
		5 , -- waterPoints
		0, -- nearbyTowns
	}
	local minScores = {math.huge,math.huge,math.huge,math.huge,math.huge, math.huge, math.huge}
	local waterLevel = util.getWaterLevel()

	for i = 1, numberOfNodes do 
		local p = baseRoute[i].p
		local maxHeight = math.min(startP.z + vec2.distance(p,startP)*maxGradient, endP.z + vec2.distance(p,endP)*maxGradient)
		local minHeight = math.max(startP.z - vec2.distance(p,startP)*maxGradient, endP.z - vec2.distance(p,endP)*maxGradient)
		--trace("At i=",i," maxHeight=",maxHeight," minHeight=",minHeight)
		local routeCharactericsHere = {} 
		local suppressScoring = false 
		local deflectionAngle = math.abs(util.signedAngle(p-baseRoute[i-1].p, baseRoute[i+1].p-p))
		if deflectionAngle >  params.minimumAngle then -- needed to prevent sharp kinks in the route
		--	 trace("Suppressing scoring due to high deflectionAngle of ",math.deg(deflectionAngle), " at i=",i)
			--suppressScoring = 0
		end
		local shouldScoreNearbyTownsHere = shouldScoreNearbyTowns
		if not params.isCargo then 
			if i == 1 or i ==numberOfNodes then 
				shouldScoreNearbyTownsHere = false
			end 
		end 
		for j = 1 , #offsetOptions[i] do
			count = count + 1
			local offset = offsetOptions[i][j]
			local routePoint = util.nodePointPerpendicularOffset(p, baseRoute[i].t,offset )
			local pointHash = util.pointHash2d(routePoint) 
			if params.routeCharactericsCache[pointHash] then 
				local cacheResult = params.routeCharactericsCache[pointHash]
				assert(util.positionsEqual2d(cacheResult.routePoint, routePoint,2)," expected "..routePoint.x..","..routePoint.y.." but was "..cacheResult.routePoint.x..","..cacheResult.routePoint.y)
				cacheResult.routePoint = routePoint -- there is slight rounding in the hash
				table.insert(routeCharactericsHere, cacheResult)
				cacheHits = cacheHits + 1
				for k, score in pairs(cacheResult.scores) do 
					minScores[k] = math.min(minScores[k], score)
					maxScores[k] = math.max(maxScores[k], score)
				end 
				goto continue
			end 
			local distanceScore = util.distance(startP, routePoint) + util.distance(endP, routePoint)
		 	local nearbyTownCount=  shouldScoreNearbyTownsHere and scoreNearbyTown(routePoint, params) or 0
			--local nearbyBuildingCount =  shouldScoreNearbyTownsHere and util.countNearbyEntitiesCached(routePoint, 50, "TOWN_BUILDING") or 0
			
			local nearbyBuildingCount = countNearbyConstructions(routePoint)
			nearbyBuildingCount = nearbyBuildingCount*nearbyBuildingCount -- squared to discourage congested areas
			nearbyTownCount = nearbyTownCount + nearbyBuildingCount 
			local terrainHeight =util.th(routePoint)
		
			local waterScore = shouldScoreWater and scoreWater(routePoint, i, terrainHeight,offset) or 0
			terrainHeight = math.max(terrainHeight, waterLevel-10) -- do not double score water
			local offsetHeight = math.abs(terrainHeight  -routePoint.z)
			local earthWorksOffset = 0 
			if terrainHeight > maxHeight then 
				earthWorksOffset = terrainHeight - maxHeight
			elseif terrainHeight < minHeight   then 
				if terrainHeight > waterLevel then 
					earthWorksOffset = minHeight - terrainHeight
				else 
					earthWorksOffset = math.max(0, minHeight - waterLevel)
				end 
			end 
			assert(earthWorksOffset>=0)
			local extraEarthWorks  =0
			if nearbyBuildingCount > 0 then 
				earthWorksOffset = earthWorksOffset + 10
				extraEarthWorks = 10
			end 
			local priorPoint = i==1 and baseRoute[0].p or routeCharacteristics[i-1][ math.max(1, math.min(computeOffsetIdxChange(i-1,0), #routeCharacteristics[i-1]))].routePoint
			local dist = vec2.distance(routePoint, priorPoint)
			local maxDeltaZ = dist*maxGradient
			local deltaZ = math.abs(priorPoint.z - routePoint.z)
			if deltaZ > maxDeltaZ then 
				earthWorksOffset = earthWorksOffset + deltaZ - maxDeltaZ
			end 
			
			--assert(earthWorksOffset>=0)
			local nearbyEdgeScore = shouldScoreNearbyEdges and scoreNearbyEdges(routePoint, baseRoute[i].t, i) or 0
			
			local collision = false 
			
			if i > 1 and i< numberOfNodes then 
				local extraEarthWorks2
				collision, extraEarthWorks2 = checkForCollision(routePoint, baseRoute[i].t, params) -- temp disabled for performance
				if extraEarthWorks2 then 
					earthWorksOffset = earthWorksOffset + extraEarthWorks2
					extraEarthWorks = extraEarthWorks + extraEarthWorks2
				end 
			end 
			if earthWorksOffset < 5 then 
				earthWorksOffset = 0 -- do not score small undulations
			end 
			local isNearFarm = util.isPointNearFarm(routePoint)
			local scores = {
						earthWorksOffset,
						offsetHeight,
						nearbyEdgeScore,
						isNearFarm and 1 or 0, 
						distanceScore,
						waterScore,--params.isWaterFreeRoute and waterScore or 0,
						nearbyTownCount,
					}
					
			for k, score in pairs(scores) do 
				--trace("k=",j,"score=",score)
				minScores[k] = math.min(minScores[k], score)
				maxScores[k] = math.max(maxScores[k], score)
				assert(score >= 0, "score at k="..tostring(k).." was "..tostring(score))
			end 
					
			--[[local preliminaryScore = -- NB this is not normalized 
				suppressScoring and 0 or (
				params.thisRouteScoreWeighting[scoreEarthWorksIdx]*earthWorksOffset
				+ params.thisRouteScoreWeighting[scoreRouteHeightsIdx]*offsetHeight
				+ params.thisRouteScoreWeighting[scoreRouteNearbyEdgesIdx]*math.min(10, nearbyEdgeScore)
				+ params.thisRouteScoreWeighting[scoreWaterPointsIdx]*waterScore
				+ params.thisRouteScoreWeighting[scoreRouteNearbyTownsIdx]*nearbyBuildingCount)]]--
			
	 
			
			local routeCharacterics = {
					collision = collision,
					terrainHeight = terrainHeight,
					nearbyEdgeScore = nearbyEdgeScore,
					isNearFarm = isNearFarm,
					nearbyTownCount = nearbyTownCount,
					waterScore =  waterScore,
					routePoint = routePoint,
					offsetHeight = offsetHeight,
					suppressScoring = suppressScoring,
					scores = scores,
					extraEarthWorks = extraEarthWorks,
					--preliminaryScore = preliminaryScore,
			}
			--[[
			local routeCharacterics = {
					collision = false,
					terrainHeight = 0,
					nearbyEdgeScore = 0,
					isNearFarm = 0,
					nearbyTownCount = 0,
					waterScore =  0,
					routePoint = routePoint,
					offsetHeight = 0,
					
					preliminaryScore = 0,
			}]]--
			
			params.routeCharactericsCache[pointHash]=routeCharacterics
			table.insert(routeCharactericsHere,routeCharacterics)
			::continue::
		end
		table.insert(routeCharacteristics, routeCharactericsHere)
	end
		local function getOffsetsShuffle() 
		math.randomseed(os.time()+randomCount)	
		local rand = math.random(1, 6)
		--util.trace("math.random(1, 6) =",rand)
		randomCount  = 	randomCount  +1
		return offsetsShuffle[rand]
	end
	local timeTakenForRouteCharacteristics = os.clock()-beginRoutCharacteristics
	local beginScoreNormalisation = os.clock() 
	profiler.beginFunction("Normalize route characteristics scores")
	for i, routeCharactericsHere in pairs(routeCharacteristics) do 
		for j, routeCharacterics in pairs(routeCharactericsHere) do 
			local score = 0
			if not routeCharacterics.suppressScoring then 
				
				local scores = routeCharacterics.scores
				for k, preliminaryScoreIdx in pairs(preliminaryScoreIdxs) do 
					if maxScores[k]~=minScores[k] then 
						local normalizedScore = (scores[k]- minScores[k])/(maxScores[k]-minScores[k])
						assert(normalizedScore >= 0)
						assert(normalizedScore <= 1, "<=1 but was "..normalizedScore.." at k="..k.." j="..j.." i="..i)
						score = score + normalizedScore * params.thisRouteScoreWeighting[preliminaryScoreIdx]
					end
				end 
			end
			routeCharacterics.preliminaryScore = score
		end 
	end  
	
	
	local timePerPoint = timeTakenForRouteCharacteristics/count
	profiler.endFunction("Normalize route characteristics scores")
	profiler.endFunction("Build route characteristics")
	trace("Offset and route characteristics built. Time taken:",(os.clock()-beginOffsets), " time taken for routeCharacterics=",timeTakenForRouteCharacteristics, " total route characteristics:",count, " time per point",timePerPoint," cacheHits=",cacheHits," time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))
	profiler.beginFunction("Build routes")
	
	local newRouteCount = 0
	local upperMid = math.ceil(numberOfNodes/2)
	local lowerMid = math.floor(numberOfNodes/2)
	local offsetBoundary = math.min(halfway, offsetLimit)

	if behaviour == 4 then 
		maxRoutes = maxRoutes / 4 
	end
	local function allowNewRouteRandomly(i)
		if i % changeDirectionInterval ~= 0   then
			return false
		end
		math.randomseed(os.time()+randomCount)	
		local rand = math.random()
		--util.trace("math.random =",rand)
		randomCount  = 	randomCount  +1
		if rand <= routesToExamine -( routesToExamine *(newRouteCount/maxRoutes)) then -- gets less likely as we approach limit
			newRouteCount = newRouteCount + 1
			return true
		end
		return false
	end 
	
	local function allowNewRouteCheckStandard(i,actualOffset, route) 
		if i % changeDirectionInterval ~= 0 or route.failed then
			return false
		end
		if i <= lowerOffsetBoundary or i >= upperOffsetBoundary then  
			if offset==offsetOptions[i][1] or offset==offsetOptions[i][#offsetOptions[i]] then --always allow outermost routes
				newRouteCount = newRouteCount + 1
				return true
			end
		end

		return allowNewRouteRandomly(i)
	end
	
	
	--offsetOptions[numberOfNodes] = offsets
	local routeOptions = {}

	local function getRoutePointCharacteristics(i, currentOffsetIdx)
		return routeCharacteristics[i][currentOffsetIdx]
	end
	

	
	if debugResults then 
		debugPrint(offsetOptions)
	end 
	
	local function offsetWithinRange(i, j)
		if j<1 or j>#offsetOptions[i] then
			if debugResults then 
				trace("offsetAllowedStandard: disallowing because j=",j,"i=",i,"#offsetOptions[i]=",#offsetOptions[i])
			end 
			return false			
		end
		return true 
	end 
	
	
	local function offsetAllowedStandard(i, proposedOffset,proposedDirection,currentDirection, route, j) 
		if not offsetWithinRange(i, j) then
			return false			
		end
		--local j = math.round(proposedOffset / offset)+math.ceil(#offsetOptions[i]/2)
		--assert(offsetOptions[i][j]==proposedOffset, "offsetOptions[i][j]="..(offsetOptions[i][j] and offsetOptions[i][j] or "nil").." expected "..proposedOffset.." with i="..i.." j="..j.." offset="..offset.." #offsetOptions[i]="..#offsetOptions[i])
		--assert(offsetIdx == j, " Expected "..j.." but was "..offsetIdx.." at i="..i.." proposedOffset=="..proposedOffset.."offsetOptions[i][offsetIdx]="..(offsetOptions[i][offsetIdx] and offsetOptions[i][offsetIdx] or "nil"))
		if routeCharacteristics[i][j].collision and not params.disableCollisionEvaluation then 
			if debugResults then 
				trace("offsetAllowedStandard: Dissallowing at ",i,j," due to collision")
			end
			return false
		end
		if (params.isTrack or params.isHighway) and math.abs(proposedDirection-currentDirection) > 1 and behaviour<3 then -- sharp direction change, only allowed at the outer diamond
			--return (i==lowerMid or i==upperMid) and  (proposedOffset==offsetOptions[i][1] or proposedOffset==offsetOptions[i][#offsetOptions[i]])
			if debugResults then 
				trace("offsetAllowedStandard: Dissallowing at ",i,j," due to sharp turn criteria for proposedDirection=",proposedDirection," and currentDirection=",currentDirection)
			end
			return false
		end
		--[[
		if i>1 then 
			local p1 = i==2 and baseRoute[0].p or util.v3(route.points[i-2])
			local p2 = util.v3(route.points[i-1])
			local p3 = offsetNode(i, proposedOffset)
			local angle = math.abs(util.signedAngle(p3-p2, p2-p1))
			if angle > math.rad(100) then 
				trace("offset was disallowed due to high angle change, ",math.deg(angle))
				return false
			end
		end]]--
		return true
	end
	local routesAddedThis = {}
	local function onlyAllowStraightAheadOrSide(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx, currentOffset) 
		if not offsetWithinRange(i, offsetIdx) then
			return false			
		end
		if debugResults then 
			trace("Only straight ahead or side,   routeOptions so far:",#routeOptions ," at i=",i, " routesAddedThis=",#routesAddedThis, "currentOffset=",currentOffset,"proposedOffset=",proposedOffset,"offsetchange=",math.abs(currentOffset -proposedOffset))
		end
		 if not offsetAllowedStandard(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx)  then 
			return false 
		end
		
		if i <= lowerOffsetBoundary or i >= upperOffsetBoundary then 
			local isOnBoundary = offsetIdx == 1 or offsetIdx == #offsetOptions[i]

			if isOnBoundary then
			
				if proposedDirection == currentDirection then 
					return true -- allow traversal along the edge 
				end 
				if i == lowerOffsetBoundary or i == upperOffsetBoundary then 
					--return true -- allow turning at the edge
				end
				local allowTurnHome = reverseSearch and i<= lowerOffsetBoundary or  i > upperOffsetBoundary
				if allowTurnHome then -- need to allow the turn to head home
					if offsetIdx == 1 and proposedDirection == 3 then 	
						return true 
					end 
					if offsetIdx == #offsetOptions[i] and proposedDirection == 1 then 
						return true
					end 
				end
			end 
		end 
		
		if not reverseSearch and  routeCharacteristics[i][1+offsetIdx - (proposedDirection-1)].collision then --TODO fix reverseSearch qualification
			return proposedDirection~=2
		end 
	
		return proposedDirection == 2
	end
	local countAllowed = 0 
	local countDisallowed = 0
	local countDuplicated = 0
	local countEdgeAllowed = 0 
	local countOtherDisallowed = 0
	local newRouteBudget = 0
	local anglesForScore = {}
	local function onlyAllowLowestScore(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx, currentOffset) 
		if currentOffset == 0 and proposedOffset == 0 and proposedDirection == 2 and currentDirection == 2 and offsetIdx == math.ceil(#offsetOptions[i] / 2) and route.isCentralRoute then -- always allow base route
			return true 
		end
		local offsetChange = math.abs((proposedOffset or 0)-(currentOffset or 0))
		if proposedOffset and offsetChange > 100 then 
		--	trace("WARNING! large offset change found at ",i,offsetChange)
		end
		if debugResults then 
			trace("onlyAllowLowestScore: Inspecting option at i=",i, "proposedOffset=", proposedOffset, " proposedDirection=",proposedDirection,"currentDirection=",currentDirection, "route=",route, "offsetIdx=",offsetIdx," currentOffset=", currentOffset,"offsetChange=",offsetChange)
		end
		if not offsetAllowedStandard(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx)  then 
			countOtherDisallowed = countOtherDisallowed + 1
			if debugResults then 
				trace("offsetAllowedStandard: Rejecting option at i=",i, "proposedOffset=", proposedOffset, " proposedDirection=",proposedDirection,"currentDirection=",currentDirection, "route=",route, "offsetIdx=",offsetIdx)
			end
			return false 
		end
		if i <= lowerOffsetBoundary or i >= upperOffsetBoundary then 
			local isOnBoundary = offsetIdx == 1 or offsetIdx == #offsetOptions[i]
			if i < lowerOffsetBoundary then 
				isOnBoundary = isOnBoundary or offsetIdx-proposedDirection==0 or (3-proposedDirection)+offsetIdx == #offsetOptions[i]
			end 
			
			if debugResults then 
				trace("Between the offsets limits, is isOnBoundary?", isOnBoundary)
			end
			if isOnBoundary then 
				if debugResults then 
					trace("Testing the proposed offset based on currentDirection=",currentDirection,"proposedDirection=",proposedDirection,"at i=",i)
				end 
				if proposedDirection == currentDirection then 
					countEdgeAllowed = countEdgeAllowed + 1
					return true -- allow traversal along the edge 
				end 
				if i == lowerOffsetBoundary or i == upperOffsetBoundary then 
					countEdgeAllowed = countEdgeAllowed + 1
					return true -- allow turning at the edge
				end
				if i > upperOffsetBoundary then -- need to allow the turn to head home
					if offsetIdx == 1 and proposedDirection == 3 then 	
						countEdgeAllowed = countEdgeAllowed + 1
						return true 
					end 
					if offsetIdx == #offsetOptions[i] and proposedDirection == 1 then 
						countEdgeAllowed = countEdgeAllowed + 1
						return true
					end 
				end
				if i < lowerOffsetBoundary and proposedDirection == 2 then 
					countEdgeAllowed = countEdgeAllowed + 1
					return true -- allow a new route in the expansion zone
				end 
				if debugResults then 
					trace("Falling through at the offsets boundary") 
				end
			end 
		end 
		local startAt = offsetIdx - (proposedDirection-1)
		local lowestOffsetIdx 
		local lowestScore = math.huge
		local loopCount = 0
		local proposedScore = math.huge
		local minAngle = math.rad(180) 
		local maxAngle = 0
		
		for j = startAt, startAt+2 do
			if routeCharacteristics[i][j] then 
				local p = routeCharacteristics[i][j].routePoint
				local priorP = route.points[i-1]
				local priorPriorP = route.points[i-2] or baseRoute[0].p
				local endP = endPoint 
				if reverseSearch then 
					priorP = route.points[i+1]
					priorPriorP = route.points[i+2] or baseRoute[numberOfNodes+1].p
					endP = startPoint
				end 
				local angleToDest = math.abs(util.signedAngleBetweenPoints(priorP, p,endP))
				local deflectionAngle = math.abs(util.signedAngleBetweenPoints(p ,priorP,priorPriorP))
			--	til.signedAngleBetweenPoints(p0, p1, p2) 
				local includeDestAngle = reverseSearch and i < halfway or i > halfway
				if includeDestAngle then -- start to include weighted score of the angle to the end
					deflectionAngle = deflectionAngle + (util.distance(p,priorP)/util.distance(p,endP))*angleToDest
				end
				if deflectionAngle < params.targetMaxDeflectionAngle then 
					deflectionAngle = 0 -- don't score if under target 
				end
				anglesForScore[j]=deflectionAngle
				minAngle = math.min(minAngle, deflectionAngle)
				maxAngle = math.max(maxAngle, deflectionAngle)
			end
		end
		
		for j = startAt, startAt+2 do
			if j == offsetIdx then
				assert(proposedOffset == offsetOptions[i][j])--sanity check
			end
			loopCount = loopCount + 1
			if not routeCharacteristics[i][j] then 
				if debugResults then 
					trace("No route characteristics found at i=",i,"j=",j, " input offsetIdx=",offsetIdx," proposedDirection=",proposedDirection, "startAt=",startAt)
					trace("Num of j = ",#routeCharacteristics[i])
				end
			else 
				local thisScore = routeCharacteristics[i][j].preliminaryScore--routeCharacteristics[i][j].offsetHeight + routeCharacteristics[i][j].nearbyEdgeScore + routeCharacteristics[i][j].waterScore
				--trace("The score i=",i,"j=",j, " was ",thisScore)
			--[[	local p = routeCharacteristics[i][j].routePoint
				local priorP = route.points[i-1]
				local priorPriorP = route.points[i-2] or baseRoute[0].p
				local endP = endPoint 
				if reverseSearch then 
					 priorP = route.points[i+1]
					 priorPriorP = route.points[i+2] or baseRoute[numberOfNodes+1].p
					 endP = startPoint
				end 
				--local angleToDest = math.abs(util.signedAngle(p-priorP,endPoint-p))
				--local deflectionAngle = math.abs(util.signedAngle(p-priorP,priorP-priorPriorP))
				
				local angleToDest = math.abs(util.signedAngleBetweenPoints(priorP, p,endP))
				local deflectionAngle = math.abs(util.signedAngleBetweenPoints(p ,priorP,endP))
			--	til.signedAngleBetweenPoints(p0, p1, p2) 
				if i > halfway then -- start to include weighted score of the angle to the end
					deflectionAngle = deflectionAngle + (util.distance(p,priorP)/util.distance(p,endP))*angleToDest
				end
				if deflectionAngle < params.targetMaxDeflectionAngle then 
					deflectionAngle = 0 -- don't score if under target 
				end ]]--
				local deflectionAngle = anglesForScore[j]
			 
				local deflectionAngleNormalised  = (deflectionAngle - minAngle )/(maxAngle-minAngle)
				if maxAngle == minAngle then -- prevent NaN if all zero
					deflectionAngleNormalised = 0 
				end 
				if deflectionAngleNormalised> 1 then 
					trace("Deflection angle was",deflectionAngle,"minAngle=",minAngle,"maxAngle=",maxAngle)
				end 
				--assert(deflectionAngleNormalised<=1,tostring(deflectionAngleNormalised))
				--assert(deflectionAngleNormalised>=0,tostring(deflectionAngleNormalised))
			 
				 
				thisScore = thisScore + params.thisRouteScoreWeighting[scoreDirectionHistoryIdx]*deflectionAngleNormalised
				--[[if params.currentIterationCount % 6 ~= 0 and testTerrainScoring then 
					thisScore = routeCharacteristics[i][j].offsetHeight
				end]]--
				if routeCharacteristics[i][j].collision and not params.disableCollisionEvaluation then 
					thisScore = math.huge 
				end
				
				--if angleToDest >= math.rad(180) then 
				---	trace("AngleToDest was",math.deg(angleToDest),"suppressing score")
				--	thisScore = math.huge -- prevent looping 
				--else 
					--thisScore = thisScore + params.thisRouteScoreWeighting[scoreDistanceIdx]*math.tan(angleToDest/2) -- use tan as it asymptotes to infinity if we start going in the wrong direction
			--	end
				if debugResults then 					
					trace("The score i=",i,"j=",j, " was ", routeCharacteristics[i][j].preliminaryScore, " deflectionAngle was ",deflectionAngle, " after adjustment the score was ", thisScore )
				end 
				if thisScore < lowestScore then 
					lowestScore = thisScore 
					lowestOffsetIdx = j
				elseif thisScore == lowestScore then 
					
					
					local thisDirection = 1 + j -startAt 
					if debugResults then 
						--local p0 = routeCharacteristics[i][j-1].routePoint
					--	trace("Found duplicated score at ",i,j, " routePoint ",p.x, p.y, " priorP=",p0.x,p0.y, " thisDirection=",thisDirection)
					end
					countDuplicated = countDuplicated+1
					if thisDirection == currentDirection then 
						if debugResults then 
							trace("Setting the lowestOffsetIdx to the current as the lowest")
						end
						lowestOffsetIdx = j 
					end
					
				end	
				if j == offsetIdx then 
					proposedScore = thisScore 
				end
			end
		end 
		assert(loopCount==3)
		if util.tracelog then 
			if offsetIdx == lowestOffsetIdx then 
				countAllowed = countAllowed +1
			else 
				countDisallowed = countDisallowed + 1
			end
		end
		if util.tracelog and debugResults then 

			trace("The proposed is allowed? ",offsetIdx == lowestOffsetIdx, " at i=",i,"proposedOffset=",proposedOffset, "offsetIdx=",offsetIdx, "lowestOffsetIdx",lowestOffsetIdx, "routeOptions so far:",#routeOptions)
			trace("startAt=",startAt," allowed:",countAllowed,"disallowed=",countDisallowed, " routes added this cycle:",#routesAddedThis, "currentDirection=",currentDirection,"proposedDirection=",proposedDirection, " countDuplicated=",countDuplicated)
			local countAllowedTotal = countEdgeAllowed+countAllowed
			local countDisallowedTotal = countDisallowed+countOtherDisallowed
			trace("countEdgeAllowed=",countEdgeAllowed," countOtherDisallowed=",countDisallowed,"countAllowedTotal=",countAllowedTotal,"countDisallowedTotal=",countDisallowedTotal)
		end
		if lowestScore == math.huge  then 
			countDisallowed = countDisallowed + 1
			if offsetIdx == lowestOffsetIdx  then 
				newRouteBudget = newRouteBudget + 1
			end
			if debugResults then 
				trace("WARNING! No proposition succeeeds at this point due to a large score at i=",i,"offsetIdx=",offsetIdx," adding to the newRouteBudget now",newRouteBudget)
			end 
			
			return false
		end 
		if offsetIdx == lowestOffsetIdx then 
			return true 
		end 
		if newRouteBudget > 0 and proposedScore < math.huge then 
			if debugResults then 
				trace("Allowing a new route to be made at i=",i,"for budget",newRouteBudget)
			end 
			newRouteBudget = newRouteBudget - 1 
			return true 
		end 
		
		return false --or allowNewRouteRandomly(i)
	end
	local function allowLowestScoreOrRandom(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx) 
		if not offsetAllowedStandard(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx)  then  
			return false 
		end
		return onlyAllowLowestScore(i, proposedOffset,proposedDirection,currentDirection, route, offsetIdx)  or allowNewRouteRandomly(i)
	end 
	
	local function alwaysAllow() return #routeOptions < maxRoutes end -- adjusted to have safety factor to avoid runaways 
	
	  
	local offsetAllowedBehaviour = { offsetAllowedStandard, onlyAllowStraightAheadOrSide, onlyAllowLowestScore, allowLowestScoreOrRandom }
	local allowNewRouteCheckBehaviour = { allowNewRouteCheckStandard, alwaysAllow, alwaysAllow ,alwaysAllow}
	
	local offsetAllowed = offsetAllowedBehaviour[behaviour]
	local allowNewRouteCheck = allowNewRouteCheckBehaviour[behaviour]
	local beginRouteBuild = os.clock()
	--debugPrint({offsetOptions=offsetOptions})
	local offsets = reverseSearch and offsetOptions[numberOfNodes] or offsetOptions[1]
	for i, offset in pairs(offsets) do
		local isCentralRoute = i == 2
		if reverseSearch then 
				table.insert(routeOptions, {
				currentOffset=offset,
				currentDirection=i, 
				isCentralRoute = isCentralRoute,
				points ={ [numberOfNodes]=offsetNode(numberOfNodes, offset, true)}, 
				--directionHistory = {i},
				currentOffsetIdx = i,
				routeCharacteristics = { [numberOfNodes]=getRoutePointCharacteristics(numberOfNodes, i)}
			})
		else 
			table.insert(routeOptions, {
				currentOffset=offset,
				currentDirection=i, 
				isCentralRoute = isCentralRoute,
				points ={ offsetNode(1, offset, true)}, 
				--directionHistory = {i},
				currentOffsetIdx = i,
				routeCharacteristics = { getRoutePointCharacteristics(1, i)}
				})
		end
		
		
	end


	util.trace("Begin building route options for numberOfNodes=",numberOfNodes," halfway=",halfway, " lowerOffsetBoundary=",lowerOffsetBoundary,"upperOffsetBoundary=",upperOffsetBoundary ,"behaviour=",behaviour," time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))
	--if util.tracelog then debugPrint(offsetOptions) end
	local startAt = 2
	local endAt = numberOfNodes 
	local increment = 1 
	if reverseSearch then 
		startAt = numberOfNodes -1
		endAt = 1
		increment = -1
	end 
	local atLeastOneFailed = false
	for i = startAt, endAt, increment do
		local routesAdded = {}
		if util.tracelog then 
			routesAddedThis= routesAdded 
		end 
		for ___, route in pairs(routeOptions) do
			if route.failed then goto continue2 end
			-- save these off at the begining to fix them if we create a new route
			local currentOffsetIdx = route.currentOffsetIdx
			local currentRouteOffset = route.currentOffset
			local currentDirection = route.currentDirection
			 
			local newRouteRequired = false
			-- try to continue in the current direction
			local offsetIdxChange = computeOffsetIdxChange(i, currentDirection)
			local offsetIdx =  currentOffsetIdx+offsetIdxChange
			local actualOffset = offsetOptions[i][offsetIdx]
			--trace("i=",i," actualOffset=",actualOffset," offsetIdx=",offsetIdx, " offsetIdxChange=",offsetIdxChange)
			if offsetAllowed(i, actualOffset, currentDirection, currentDirection, route, offsetIdx, currentRouteOffset) then
				local routeCharacterics = getRoutePointCharacteristics(i, offsetIdx)
				route.points[i]=routeCharacterics.routePoint --offsetNode(i, actualOffset)
				route.currentOffset = actualOffset
				--route.directionHistory[i]=currentDirection
				route.currentOffsetIdx =offsetIdx
				route.routeCharacteristics[i]=routeCharacterics
				
				newRouteRequired = true
				
				--[[if (params.isTrack or params.isHighway) and currentDirection==2 then 
					local offsetDelta = math.abs(currentRouteOffset-actualOffset)
					assert(math.abs(offsetDelta)<offset, " max expected zero  but was "..offsetDelta.." at "..i.."  currentDirection="..currentDirection.." currentRouteOffset="..currentRouteOffset.." offsetIdx="..offsetIdx.." offsetIdxChange="..offsetIdxChange)
				end ]]--
			else
				--util.trace("could not continue on ",currentDirection," actualOffset=",actualOffset," i=",i, "currentRouteOffset=",currentRouteOffset)
			end			
			for j = 1, #offsets do
				if j == currentDirection then goto continue	end
				
				local offsetIdxChange = computeOffsetIdxChange(i, j)
				local offsetIdx = currentOffsetIdx+offsetIdxChange
				local actualOffset = offsetOptions[i][offsetIdx]
				--trace("i=",i," actualOffset=",actualOffset," offsetIdx=",offsetIdx, " offsetIdxChange=",offsetIdxChange, "j=",j," currentDirection=",currentDirection, " currentOffsetIdx=",currentOffsetIdx, " offset=",offset, " currentRouteOffset=",currentRouteOffset)
				if offsetAllowed(i,actualOffset,j,currentDirection, route, offsetIdx, currentRouteOffset) then
					--local currentRoute = route
				--[[	if params.isTrack or params.isHighway then 
						local offsetDelta = math.abs(currentRouteOffset-actualOffset)
						assert(offsetDelta <=offset, " max expected was "..offset.." but was "..offsetDelta.." at "..i.." j="..j.." currentDirection="..currentDirection)
					end ]]--
					
					if newRouteRequired then
						if allowNewRouteCheck(i,actualOffset, route) then
						--debugPrint({currentRouteBeforeClone=currentRoute})
							route = shallowCloneRoute(route)
							local routeCharacterics = getRoutePointCharacteristics(i, offsetIdx)
							route.points[i]=routeCharacterics.routePoint --offsetNode(i, actualOffset)
							route.currentOffset = actualOffset
							route.currentDirection = j
							--route.directionHistory[i]=j
							route.currentOffsetIdx = offsetIdx
							route.routeCharacteristics[i]=routeCharacterics
							--debugPrint({currentRouteAfterClone=currentRoute})
						--	table.remove(currentRoute.points) -- undo work in current iteration
							table.insert(routesAdded, route)
						end
					else 
						local routeCharacterics = getRoutePointCharacteristics(i, offsetIdx)
						route.points[i]=routeCharacterics.routePoint --offsetNode(i, actualOffset)
						route.currentOffset = actualOffset
						route.currentDirection = j
						--route.directionHistory[i]=j
						route.currentOffsetIdx = offsetIdx
						route.routeCharacteristics[i]=routeCharacterics
						newRouteRequired = true
					end
				--table.insert(currentRoute.points, offsetNode(i, actualOffset))
				
				end	
				::continue::
			end
			if not newRouteRequired then 
				route.failed = i
				atLeastOneFailed = true
				if behaviour == 2 and util.tracelog  and true then 
					debugResults = true 
					trace("Route was failed, checking for each of the offsets")
					for j = 1, #offsets do
						local offsetIdxChange = computeOffsetIdxChange(i, j)
						local offsetIdx = currentOffsetIdx+offsetIdxChange
						local actualOffset = offsetOptions[i][offsetIdx]
						trace("At i=",i,"j=",j,"offsetAllowed?",offsetAllowed(i,actualOffset,j,currentDirection, route, offsetIdx, currentRouteOffset))
					end 
					--[[trace("No checking the currentDirection result")
					local offsetIdxChange = computeOffsetIdxChange(i, currentDirection)
					local offsetIdx =  currentOffsetIdx+offsetIdxChange
					local actualOffset = offsetOptions[i][offsetIdx]
					trace("At i=",i,"j=",j,"offsetAllowed?",offsetAllowed(i,actualOffset,j,currentDirection, route, offsetIdx, currentRouteOffset) ]]--
					trace("Marking route as failed at i=",i, " behaviour=",behaviour," route.currentOffsetIdx =",route.currentOffsetIdx ,"route.currentDirection=",route.currentDirection,"route.currentOffset=",route.currentOffset)
					debugResults = false
				end 
			 --
			end
			
			--assert(newRouteRequired, "at least one direction should have been valid at i="..i.." currentRouteOffset="..currentRouteOffset)
			::continue2::
		end
		for j, route in pairs(routesAdded) do -- do this at the end to avoid unpredictable iteration
			table.insert(routeOptions, route)
		end
		if debugResults then 
			util.trace("at root iteration ",i,"number of routes was",#routeOptions,"behaviour=",behaviour)
		end
	end
	
	util.trace("Completed building route options. Number of route options was", #routeOptions," time taken:",(os.clock()-beginRouteBuild)," time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))
	-- debugPrint({routeOptions=routeOptions})
	local function createBaseRoute() 
		local result = {points={},directionHistory={}}
		for i =1 , numberOfNodes do
			result.points[i]=baseRoute[i].p
			result.directionHistory[i]=2
		end
		return result
	end
	if behaviour == 3 then 
		local countAllowedTotal = countEdgeAllowed+countAllowed
		local countDisallowedTotal = countDisallowed+countOtherDisallowed
		trace("countEdgeAllowed=",countEdgeAllowed," countOtherDisallowed=",countOtherDisallowed,"countAllowed=",countAllowed,"countAllowedTotal=",countAllowedTotal,"countDisallowedTotal=",countDisallowedTotal)
	end
	--table.insert(routeOptions, createBaseRoute());-- always ensure the base route is an option
	
	--NB looping check here doesn't work, needs to be done after recomputation of tangents and smoothing
	--[[local checkForLoopingBegin = os.clock()
	local loopedCount = 0
	for i, route in pairs(routeOptions) do 
		if not route.failed then 
			local totalAngle = 0
			for j = 2, #route.points-1 do
				local pBefore = route.points[j-1]
				local p = route.points[j]
				local pNext = route.points[j+1]
				local t0 = p - pBefore 
				local t1 = pNext - p
				local angle = util.signedAngle(t0, t1)
				totalAngle = totalAngle + angle 
				if math.abs(totalAngle) > math.rad(360) then -- avoid looping 
					trace("WARNING! the total angle exceeds 360, was ",math.deg(totalAngle),"at j=",j,"failing route")
					route.failed = j 
					loopedCount = loopedCount + 1
					break
				end 
			end 
		end 
	end 
	trace("Completed checkForLooping in ",(os.clock()-checkForLoopingBegin),"considerd",#routeOptions," number looping?",loopedCount,"behaviour=",behaviour)]]--

	-- cleanup, removed failed routes 
	local highestFailureIndex = 0
	if params.drawRoutes then 
		drawRoutes(routeOptions, baseRoute, numberOfNodes)  
	end 
	if atLeastOneFailed then 
		local routeOptionsOld = routeOptions
		routeOptions = {}

		for i, route in pairs(routeOptionsOld) do 
			if not route.failed then 
				for j, p in pairs (route.points) do
					route.points[j] = util.v3(route.points[j])
				end
				--route.scores = { 0, 0, 0, 0, 0, 0, 0, 0} -- performance optimisation
				table.insert(routeOptions, route)
			else
				highestFailureIndex = math.max(highestFailureIndex, route.failed)
			end
		end
	end
	profiler.endFunction("Build routes")
	util.trace("after removing failed routes, number of route options was", #routeOptions,"offsetLimit=",offsetLimit," behaviour=",behaviour,"time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute),"reverseSearch=",reverseSearch,"atLeastOneFailed?",atLeastOneFailed)
	if #routeOptions == 0 then
		local followRoute = {}
		local i = highestFailureIndex
		trace("attempting new route at ",i," to resolve collisions")
		if i>numberOfNodes/2 and #boundingRoutes[2] > 0 then
			i = math.min(numberOfNodes-2,i)
			i=i-1
			local pointsNeeded = numberOfNodes-i 
			local endPoint = indexOfClosestPoint(baseRoute[numberOfNodes+1].p, boundingRoutes[2])
			local reverseOrder = endPoint < #boundingRoutes[2]/2
			if reverseOrder then
				for j = endPoint+pointsNeeded, endPoint , -1 do
					table.insert(followRoute, boundingRoutes[2][j])
				end
			else 
				for j = endPoint-pointsNeeded, endPoint  do
					table.insert(followRoute, boundingRoutes[2][j])
				end
			end
			local tangentSign = math.abs(util.signedAngle(followRoute[2].p-followRoute[1].p, followRoute[1].t)) < math.rad(90) and  1 or -1
			local sizeAdj = math.ceil(i/numberOfNodes+1)*vec3.length(baseRoute[0].t)
			local sizeAdj2 = i*params.targetSeglenth
			trace("sizeAdj =",sizeAdj, " sizeAdj2=",sizeAdj2)
			local newEdge = {
				t0 = sizeAdj2*vec3.normalize(baseRoute[0].t),
				p0 = baseRoute[0].p,
				t1 = sizeAdj2*tangentSign*vec3.normalize(followRoute[1].t),
				p1 = followRoute[1].p
			}
			--debugPrint({newEdge = newEdge, followRoute=followRoute, endPoint=endPoint, pointsNeeded = pointsNeeded, reverseOrder= reverseOrder})
			local subBaseRoute = buildBaseRouteFromEdge(newEdge, i, boundingRoutes, params, numberOfNodes).baseRoute
			local subResult = evaluateRouteFromBaseRoute(subBaseRoute, i, params, maxGradFrac, maxRoutes*2, behaviour, {{},{}}, routeDeviationPerSegment)
			if not subResult then return end
			local rightHandedAngle = util.signedAngle(followRoute[1].p-baseRoute[0].p, tangentSign*followRoute[1].t)
			trace("rightHandedAngle was ",math.deg(rightHandedAngle), " attempting to follow route from subroute")
			local perpSign =  rightHandedAngle > 0 and 1 or -1
			for j = 1, #followRoute do
				local t = tangentSign*followRoute[j].t
				local p = util.doubleTrackNodePoint(followRoute[j].p, perpSign*t)
				assert(util.distance(p, followRoute[j].p)>1)
				local routePoint = { p=p, t=t, t2=t}
				subResult.newRoute[i+j]=routePoint
				for k =1, #subResult.routeOptions do
					--if not subResult.routeOptions[i+j] then
						--subResult.routeOptions[i+j]={}
					--end
					if i+j <= numberOfNodes then
						subResult.routeOptions[k].points[i+j]=p
					end
				end
			end
			subResult.newRoute[numberOfNodes+1]=baseRoute[numberOfNodes+1]
			--debugPrint(subResult)
			return subResult
		elseif i<numberOfNodes/2 and #boundingRoutes[1] > 0 then
		
		end
	end
	if #routeOptions == 0 then
		return 
	end

	--[[
	for i, route in pairs(routeOptions) do
		--util.trace("scouring route at i=",i)
		if route.failed then goto continue end
		route.scores = {}
		local scoreFns = { 
			 scoreRouteHeights , 
			 scoreDirectionHistory ,
			 scoreRouteNearbyEdges ,
			 scoreRouteFarms ,
			 scoreDistance,
			 scoreEarthWorks,
			 scoreWaterPoints
			}
		for j, fn in pairs(scoreFns) do 
			--local rawScore = 
			--util.trace("inspecting score ", rawScore," at j=",j)
			--maxScores[j] = math.max(maxScores[j], rawScore)
			--minScores[j] = math.min(minScores[j], rawScore)
			route.scores[j]=fn(route)
		end
		::continue::
	end]]--

	
	
--	debuglog("total routes evaluated=",#routeOptions, "bestRoute.score=",bestRoute.score," bestRoute.scorehNormalised=",bestRoute.scoreNormalised[1]," bestRoute.scorelNormalised=",bestRoute.scoreNormalised[2], " bestRoute.scoreh=",bestRoute.scores[1]," bestRoute.scorel=", bestRoute.scores[2], " bestRoute.i=",bestRoute.i, "maxScoreH=",maxScores[1], "minScoreH=",minScores[1]," maxScoreL=",maxScores[2]," minScoreL=",minScores[2], " size of scoremap=",size(scoresMap))
	--if tracelog then debugPrint({bestRouteDirections=bestRoute.directionHistory}) end
	trace("About to sort route options, time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))
	local beginSort = os.clock()
	profiler.beginFunction("Score and sort routes")
	local sortedRouteOptions = util.evaluateAndSortFromScores(routeOptions, params.thisRouteScoreWeighting, getScoreFns(maxGradFrac, baseRoute, params), getMinMaxScores(numberOfNodes))
	trace("Evaluation and sort complete, time taken: ",(os.clock()-beginSort)," time taken since beginEvaluateRouteFromBaseRoute:",(os.clock()-beginEvaluateRouteFromBaseRoute))
	profiler.endFunction("Score and sort routes")
	--local bestOption = sortedRouteOptions[1]
	--local newRoute = buildRouteAndApplySmoothing(baseRoute, bestOption, numberOfNodes, maxGradFrac, params, boundingRoutes)
	profiler.endFunction("evaluateRouteFromBaseRoute")
	profiler.endFunction("evaluateRouteFromBaseRoute for behaviour "..tostring(behaviour))
	return { newRoute=newRoute, routeOptions=sortedRouteOptions}
	
end	
	
	
local function connectedToThroughStation(node)
	local segs = util.getSegmentsForNode(node)
	local constructionId  = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(segs[1])
	if constructionId ~= -1 then 
		local construction = util.getConstruction(constructionId)
		if construction.params.buildThroughTracks then 
			trace("Found a through track station for node",node)
			return true
		end
	end 
	return false 
end 

routeEvaluation.needsSpiral = function(p0, p1, maxGradFrac)
	local deltaz = p1.z - p0.z
	local totalDist = vec2.distance(p0, p1)
	local maxDeltaz = maxGradFrac * totalDist
	local diff = math.abs(deltaz) - maxDeltaz
	trace("Deltaz was ",deltaz," maxDeltaZ=",maxDeltaz, " diff=",diff, " distance was",totalDist)
	return  math.abs(deltaz)/totalDist > maxGradFrac and math.abs(diff) > 15
end

local function toApiBox(p0, p1, margin)
	local zMargin = 10
	return {
			min = {
				x = math.min(p0.x-margin, p1.x-margin),
				y = math.min(p0.y-margin, p1.y-margin),
				z = math.min(p0.z-zMargin, p1.z-zMargin)
			},
			max = { 
				x = math.max(p0.x+margin, p1.x+margin),
				y = math.max(p0.y+margin, p1.y+margin),
				z = math.max(p0.z+zMargin, p1.z+zMargin)
			}	
		}
end 

function routeEvaluation.setupRouteData(params, edge, ourBox)
	profiler.beginFunction("routeEvaluation.setupRouteData")
	routeEvaluation.industryLocations = {}
	routeEvaluation.industryLocationsByHash = {}
	local padding = params.routeEvaluationOffsetsLimit*params.routeDeviationPerSegment
	
	local ourBoxApi = ourBox.toApiBox()--toApiBox(edge.p0, edge.p1, 200)
	debugPrint({ourBox=ourBox, ourBoxApi=ourBoxApi})
	api.engine.forEachEntityWithComponent(function(entity)
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(entity)
		local construction = util.getConstruction(constructionId)
		local p = util.v3(construction.transf:cols(3))
		table.insert(routeEvaluation.industryLocations, p)
		local hash =hashIndustryLocation(p)
		trace("Setting industry location at ",p.x,p.y,"to hash",hash)
		routeEvaluation.industryLocationsByHash[hash]=p	
	end, api.type.ComponentType.SIM_BUILDING)
	
	routeEvaluation.constructionsBy64TileHash = {}
	routeEvaluation.constructionsBy16TileHash = {}
	api.engine.forEachEntityWithComponent(function(constructionId) 
		local construction = util.getConstruction(constructionId)
		local p =  construction.transf:cols(3) 
		 
		local hash = hashLocation64(p)
		if not routeEvaluation.constructionsBy64TileHash[hash] then 
			routeEvaluation.constructionsBy64TileHash[hash] = {}
		end 
		table.insert(routeEvaluation.constructionsBy64TileHash[hash], constructionId)
		local alreadySeen = {}
		local alreadySeen64 = { [hash]=true }
		local boundingVolume = util.getComponent(constructionId, api.type.ComponentType.BOUNDING_VOLUME)
		local bbox = boundingVolume and boundingVolume.bbox
		if bbox and util.boxesIntersect(bbox, ourBoxApi) then 
			local points = {p}
			for i, p1 in pairs({bbox.min, bbox.max}) do 
				for j, p2 in pairs({bbox.min, bbox.max}) do 
					table.insert(points, {x=p1.x,y=p2.y})
				end 
			end 
			
			local lotList = util.getComponent(constructionId, api.type.ComponentType.LOT_LIST)
			if lotList then 
				local lots = lotList.lots -- verbose local assignment to avoid unexpected gc issues
				for k, lot in pairs(lots) do 
					local vertices = lot.vertices
					for m, p in pairs(vertices) do 
						local x = p.x 
						local y = p.y 
						if x == x and y == y then -- some wierd memory corruption? 
							table.insert(points, {x=x,y=y})--appears that we need to make a copy here otherwise they get corrupted
						end 
					end 
				end 
			end
			  
 			--trace("Got ",#points)
			for i, p in pairs(points) do
				local hash = hashLocation16(p)
				if hash~=hash then 
					debugPrint({p=p,hash=hash, i =i})
					debugPrint({lotList=lotList})
				end 
				if not alreadySeen[hash] then 
					if not routeEvaluation.constructionsBy16TileHash[hash] then 
						routeEvaluation.constructionsBy16TileHash[hash] = {}
					end
					table.insert(routeEvaluation.constructionsBy16TileHash[hash], constructionId)
					alreadySeen[hash]=true 
				end 
				
			end 
			
			for i, p in pairs(points) do
				local hash = hashLocation64(p)
				if not alreadySeen64[hash] then 
					if not routeEvaluation.constructionsBy64TileHash[hash] then 
						routeEvaluation.constructionsBy64TileHash[hash] = {}
					end
					table.insert(routeEvaluation.constructionsBy64TileHash[hash], constructionId)
					alreadySeen64[hash]=true 
				end 
				
			end 
		end 
		
		
	end, api.type.ComponentType.CONSTRUCTION)
	
	routeEvaluation.frozenEdgesBy64TileHash = {}
	routeEvaluation.edgesBy16TileHash = {}
	routeEvaluation.edgesBy64TileHash = {}
	routeEvaluation.junctionNodesBy16TileHash = {}
	api.engine.forEachEntityWithComponent(function(entity) 
		if #util.getSegmentsForNode(entity) > 2 then 
			local hash16 = hashLocation16(util.nodePos(entity))
			
			 
			if not routeEvaluation.junctionNodesBy16TileHash[hash16] then 
				routeEvaluation.junctionNodesBy16TileHash[hash16]={}
			end 
			table.insert(routeEvaluation.junctionNodesBy16TileHash[hash16], entity)
			  
		end 
	end, api.type.ComponentType.BASE_NODE)
	
	api.engine.forEachEntityWithComponent(function(entity)
		 
		local edge = util.getEdge(entity)
		local p0 = util.nodePos(edge.node0)
		local p1 = util.nodePos(edge.node1)
		local t0 = util.v3(edge.tangent0)
		local t1 = util.v3(edge.tangent1)
		local points = { p0 ,  p1 }
		if util.distBetweenNodes(edge.node0,edge.node1) > 64 then 
			for i = 1, 3 do 
				local p = util.hermite(i/4, p0, t0, p1, t1).p 
				table.insert(points, p)
			end
		end 
		local alreadySeen = {}
		local alreadySeen64 = {}
		for i, point in pairs(points) do 
			local hash16 = hashLocation16(point)
			
			if not alreadySeen[hash16] then 
				alreadySeen[hash16]=true 
				if not routeEvaluation.edgesBy16TileHash[hash16] then 
					routeEvaluation.edgesBy16TileHash[hash16]={}
				end 
				table.insert(routeEvaluation.edgesBy16TileHash[hash16], entity)
			end 
			
			local hash64 = hashLocation64(point)
			--[[local invP = invertHash64(hash64)
			local dist = vec2.distance(invP, point)
			trace("Setting up location for point",point.x,point.y,"hash64=",hash64,"invP=",invP.x,invP.y,"dist=",dist,"for edge",entity)]]--
			if not alreadySeen64[hash64] then 
				alreadySeen64[hash64]=true 
				if not routeEvaluation.edgesBy64TileHash[hash64] then 
					routeEvaluation.edgesBy64TileHash[hash64]={}
				end 
				table.insert(routeEvaluation.edgesBy64TileHash[hash64], entity)
				 
				if util.isFrozenEdge(entity) then 
					if not routeEvaluation.frozenEdgesBy64TileHash[hash64] then 
						routeEvaluation.frozenEdgesBy64TileHash[hash64]={}
					end 
					table.insert(routeEvaluation.frozenEdgesBy64TileHash[hash64], entity)
				end 
			end   
		end 
		  
	end, api.type.ComponentType.BASE_EDGE)
	routeEvaluation.townsBy1024Hash = {}
	api.engine.forEachEntityWithComponent(function(townId) 
		if townId ~= params.startTown and townId ~= params.endTown then 
			local town = game.interface.getEntity(townId)
			local p = util.v3fromArr(town.position) 
			local alreadySeen = {}
			for x = -1024, 1024, 1024 do 
				for y = -1024, 1024, 1024 do 
					local p0 = vec3.new(p.x+x,p.y+y,p.z)
					local hash = hashLocation1024(p0)
					if not alreadySeen[hash] then 
						alreadySeen[hash] = true 
						if not routeEvaluation.townsBy1024Hash[hash] then 
							routeEvaluation.townsBy1024Hash[hash] = {}
						end 
						table.insert(routeEvaluation.townsBy1024Hash[hash], p)--original P 
					end 
				end 
			end 
			trace("Added for town ",townId,"locations was",util.size(alreadySeen))
			assert(util.size(alreadySeen)==9)
		end 
		
	end, api.type.ComponentType.TOWN)
	profiler.endFunction("routeEvaluation.setupRouteData")
	
	if params.drawRoutes and false then  -- disabled for now
		for hash, edges in pairs(routeEvaluation.edgesBy64TileHash) do 
			local p = invertHash64(hash) 
			trace("Got p=",p.x,p.y,"from hash=",hash,"calling hash again:",hashLocation64(p))
			assert(hash == hashLocation64(p))
				 
			local polygon = {
				{ p.x - 31, p.y -31 },
				{ p.x - 31, p.y +31 },
				{ p.x + 31, p.y +31},
				{ p.x + 31, p.y -31 }
			
			}
			for i , p in pairs(polygon) do 
				local thisHash = hashLocation64({x=p[1],y=p[2]})
				trace("Inspecting location ",p[1],p[2],"hash was",thisHash,"originalHash=",hash)
				assert(thisHash == hash)
			end 
			local name = "ai_edges"..tostring(hash) 
			table.insert(routesDrawn, name)
			local drawColour = { 1, 0, 0, 1} 
			game.interface.setZone(name, {
				polygon=polygon,
				draw=true,
				drawColor = drawColour,
			})  
			
		end 
		local mapBoundary = util.getMapBoundary()
		local polygon = {}
		for x = -mapBoundary.x, mapBoundary.x, 64 do 
			for y = -mapBoundary.y, mapBoundary.y, 64 do 
				local score = scoreNearbyTown({x=x,y=y, z=5})
				if score > 0 and score < 100 then 
					table.insert(polygon, {x,y})
				end 
			end 
		
		end 
		local name = "ai_town_outline"
		table.insert(routesDrawn, name)
		local drawColour = { 0, 1, 0, 1} 
		game.interface.setZone(name, {
			polygon=polygon,
			draw=true,
			drawColor = drawColour,
		})  
	end 
end 

local function clearCachedData()
	routeEvaluation.industryLocations = nil
	routeEvaluation.industryLocationsByHash =nil
	routeEvaluation.townsBy1024Hash = nil
	routeEvaluation.frozenEdgesBy64TileHash = nil
	routeEvaluation.edgesBy16TileHash = nil
	routeEvaluation.edgesBy64TileHash = nil
	routeEvaluation.constructionsBy64TileHash = nil
end 

local function setupBox(p0, p1,numberOfNodes, params)
	local box = newBox(p0, p1, 200)
	local maxOffset = params.routeDeviationPerSegment*math.min(numberOfNodes/2, params.routeEvaluationOffsetsLimit)
	trace("Got maxOffset as",maxOffset)
	box.setMinSize(500+maxOffset*2)
	
	return box
end 

function routeEvaluation.evaluateRoute(numberOfNodes, edge, params, recursiveCall, boundingRoutes)
	local startTime = os.clock()
	params.smoothFrom = nil 
	params.smoothTo = nil  
	if params.drawRoutes then
	
		clearRoutes()
		nextIndex = 1
	end
	--params.maxInitialTrackAngle = 1
	params.maxInitialTrackAngleStart = params.maxInitialTrackAngle
	params.maxInitialTrackAngleEnd = params.maxInitialTrackAngle
	params.startAngleCorrections = 0
	params.endAngleCorrections = 0
	local ourBox = setupBox(edge.p0,edge.p1,numberOfNodes, params)
	if not params.isCargo then 
		params.startTown = util.searchForNearestEntity(edge.p0, 1500, "TOWN")
		params.endTown = util.searchForNearestEntity(edge.p1, 1500, "TOWN")
		if params.startTown and params.startTown.id  then 
			params.startTown = params.startTown.id 
		end 
		if params.endTown and params.endTown.id  then 
			params.endTown = params.endTown.id 
		end		
		trace("Setup start and end towns as",params.startTown, params.endTown)
	end 
	if not recursiveCall then 
		routeEvaluation.setupRouteData(params, edge, ourBox)
	end
	
	local startNode = util.getNodeClosestToPosition(edge.p0)
	params.startConnectingRoute =  false 
	params.endConnectingRoute = false
	local industryNearStart =  util.searchForFirstEntity(edge.p0, 350, "SIM_BUILDING")
	local industryNearEnd = util.searchForFirstEntity(edge.p1, 350, "SIM_BUILDING")
	params.industryNearStart = industryNearStart and util.v3fromArr(industryNearStart.position)
	params.industryNearEnd = industryNearEnd and util.v3fromArr(industryNearEnd.position)
	if params.industryNearStart or params.industryNearEnd then 
		local d1 = params.industryNearStart and util.distance(params.industryNearStart, edge.p0) or math.huge 
		local d2 = params.industryNearEnd and util.distance(params.industryNearEnd, edge.p1) or math.huge 
		params.minDistToIndustryThreshold = math.min(200, math.min(d1, d2))-10
		trace("Setting the minDistToIndustryThreshold at ",params.minDistToIndustryThreshold, " d1,d2=",d1,d2)
	end 
	local targetSpeedLimit = params.targetSpeed  
	--if util.year() >= 1925 and params.isTrack or params.isHighway then 
		--targetSpeedLimit = 120 / 3.6 
	--end 
	local trackRepName = params.isHighSpeedTrack and "high_speed.lua" or "standard.lua"
	local trackRep = api.res.trackTypeRep.get(api.res.trackTypeRep.find(trackRepName)) -- NB there is no equivalent data for roads, so falling back to using standard track parameters
	if params.isHighway then 
		targetSpeedLimit = params.highwayTargetSpeed 
	end 
	if params.isHighSpeedTrack then 
		targetSpeedLimit = math.max(targetSpeedLimit,  params.isCargo and 160 / 3.6 or 200 /3.6)
	end 
	if params.isVeryHighSpeedTrain then 
		targetSpeedLimit = math.max(targetSpeedLimit, trackRep.speedLimit  ) 
	end
	params.targetSpeedLimit = targetSpeedLimit

	local speedCoeffs = trackRep.speedCoeffs
	local a = speedCoeffs.x 
	local b = speedCoeffs.y 
	local c = speedCoeffs.z 
	local s = targetSpeedLimit
	local r = math.max(trackRep.minCurveRadiusBuild, (s/a)^(1/c) - b) -- N.B. expect about 1300m at 300km/h
	params.targetMaxDeflectionAngle =  params.targetSeglenth / (2*r)
	params.minimumAngle =  params.targetSeglenth / (2*trackRep.minCurveRadiusBuild)
	params.minCurveRadiusBuild = trackRep.minCurveRadiusBuild
	trace("Calculated the full speed curve radius as",r," giving targetMaxDeflectionAngle as",math.deg(params.targetMaxDeflectionAngle), " minimumAngle=",math.deg(params.minimumAngle),"targetSpeedLimit=",targetSpeedLimit)
  
	if not startNode or not util.isNodeConnectedToFrozenEdge(startNode) or connectedToThroughStation(startNode) then  
		
		--params.maxInitialTrackAngleStart = 0.5*params.maxInitialTrackAngleStart
		params.startConnectingRoute = true
	 
		params.maxInitialTrackAngleStart = math.deg(params.targetMaxDeflectionAngle)
		if params.isCargo then -- junction unlikely to join at full speed
			params.maxInitialTrackAngleStart = 2*params.maxInitialTrackAngleStart
		end 	  
		trace("Rediucing initial track angle at the start to ",params.maxInitialTrackAngleStart,"startNode=",startNode)
	end 
	
	local endNode = util.getNodeClosestToPosition(edge.p1)
	if not endNode or not util.isNodeConnectedToFrozenEdge(endNode) or connectedToThroughStation(endNode)  then  

	--	params.maxInitialTrackAngleEnd = 0.5*params.maxInitialTrackAngleEnd
		params.endConnectingRoute = true
	 
		params.maxInitialTrackAngleEnd = math.deg(params.targetMaxDeflectionAngle)
 		if params.isCargo then -- junction unlikely to join at full speed
			params.maxInitialTrackAngleEnd = 2*params.maxInitialTrackAngleEnd
		end 		
		trace("Rediucing initial track angle at the end to",params.maxInitialTrackAngleEnd,"endNode=",endNode)
	end 
	
	--TEMP
	 --params.maxInitialTrackAngleStart = 2
	
	trace("Begin evaluate route, numberOfNodes",numberOfNodes)
	local wasCached=  util.cacheNode2SegMapsIfNecessary() 
	if numberOfNodes <=0 then
		util.trace("invalid numer of nodes asked for ",numberOfNodes)
		return {}
	end
	params.thisRouteScoreWeighting = util.deepClone(params.routeScoreWeighting)
	trace("EvaluateRoute, thisRouteScoreWeighting at 1 was",params.thisRouteScoreWeighting[1])
	if numberOfNodes <= 10 and math.abs(util.signedAngle(edge.t0, edge.t1)) < math.rad(90) then 
		trace("Setting curvature distance score weight to 100")
		params.thisRouteScoreWeighting[scoreDirectionHistoryIdx]=100
		params.thisRouteScoreWeighting[scoreDistanceIdx]=100
	end 
	if testTerrainScoring then 
		for i = 1, #params.thisRouteScoreWeighting do 
			params.thisRouteScoreWeighting[i] = i == scoreRouteHeightsIdx and 100 or 0
		end 
		params.smoothingPasses = 0
		params.routeEvaluationOffsetsLimit = 4
		params.outerIterations = 50
		--params.routeDeviationPerSegment = 100
		trace("Setting up for testTerrainScoring")
	end 
	local deltaz = edge.p1.z - edge.p0.z
	local maxGradFrac = params.maxGradient 
	
	if not boundingRoutes then 
		boundingRoutes = checkForNearByRoutes(edge, params, numberOfNodes, ourBox)
	end
	for i, boundingRoute in pairs(boundingRoutes) do 
		if boundingRoute.isCollisionInevitable and not recursiveCall then 
			trace("Incrementing the numberOfNodes from",numberOfNodes,"to",numberOfNodes+6,"for collision avoidance with bounding route")
			numberOfNodes = numberOfNodes + 6
			params.newNodeCount = numberOfNodes
		end 
	end
	local originalNumberOfNodes = numberOfNodes
	local needsSpiral = false
	local calculatedNeedsSpiral = routeEvaluation.needsSpiral(edge.p0, edge.p1, maxGradFrac)
	if  calculatedNeedsSpiral and not params.suppressSpiral then
		--numberOfNodes = numberOfNodes - params.spiralNodeCount
		--util.trace("need for spiral detected, reducing node count to",numberOfNodes)
		if params.maxGradient < params.absoluteMaxGradient then 
			trace("Changing max gradient from ",params.maxGradient," to ",params.absoluteMaxGradient)
			params.maxGradient = params.absoluteMaxGradient
			maxGradFrac = params.maxGradient 
			if routeEvaluation.needsSpiral(edge.p0, edge.p1, maxGradFrac) then 
				needsSpiral = true 
			else 
				trace("For the increased max gradient spiral is no longer required")
			end
		else 
			needsSpiral = true
		end 
	end
	trace("NeedsSpiral? ",needsSpiral," suppressSpiral?",params.suppressSpiral,"params.maxInitialTrackAngleEnd=",params.maxInitialTrackAngleEnd,"params.maxInitialTrackAngleStart=",params.maxInitialTrackAngleStart)
	
	local trackWidth = params.trackWidth
	 
	
	params.smoothFrom = 1
	params.smoothTo = numberOfNodes
	local baseRouteOptions = {}
	local startAt = 1
	if params.endConnectingRoute or params.startConnectingRoute then 
		trace("Starting at 10 for start or end connecting route")
		startAt = 10
	end 
	for i = startAt, 12 do 
		params.baseRouteEdgeTangentFactor=i/10
		trace("Setting up baseRoute using tangentFactor of",params.baseRouteEdgeTangentFactor)
		local baseRouteInfo = buildBaseRouteFromEdge(edge, numberOfNodes, boundingRoutes, params, originalNumberOfNodes)
		baseRouteInfo.points = baseRouteInfo.baseRoute
		baseRouteInfo.baseRouteEdgeTangentFactor = params.baseRouteEdgeTangentFactor
		baseRouteInfo.startAngleCorrections = params.startAngleCorrections
		baseRouteInfo.endAngleCorrections = params.endAngleCorrections
		
		params.startAngleCorrections = 0
		params.endAngleCorrections = 0
		table.insert(baseRouteOptions, baseRouteInfo)
		if params.drawBaseRouteOnly then 
			--drawBaseRoute(baseRouteInfo,numberOfNodes, nextIndex)
			--nextIndex = nextIndex+1
		end
		 
		profiler.printResults()
	end 
	local baseRouteInfo = util.evaluateWinnerFromScores(baseRouteOptions, params.thisRouteScoreWeighting, getFullRouteScoreFns(maxGradFrac, numberOfNodes, params),false, getMinMaxScores(numberOfNodes))
	params.startAngleCorrections = baseRouteInfo.startAngleCorrections
	params.endAngleCorrections = baseRouteInfo.endAngleCorrections
	params.startAngleLeftHanded = baseRouteInfo.startAngleLeftHanded
	params.endAngleLeftHanded = baseRouteInfo.endAngleLeftHanded
	trace("The winning tangent factor was",baseRouteInfo.baseRouteEdgeTangentFactor,"with startAngleCorrections=",params.startAngleCorrections,"endAngleCorrections=",params.endAngleCorrections,"startAngleLeftHanded=",params.startAngleLeftHanded,"endAngleLeftHanded=",params.endAngleLeftHanded)
	if params.drawBaseRouteOnly then 
		drawBaseRoute(baseRouteInfo, numberOfNodes,0 )
		ourBox.drawBox()
		return 
	end 
	
	local baseRoute = baseRouteInfo.baseRoute
	
	if numberOfNodes<=10 then 
		--return baseRoute 
	end
	local adjustments = baseRouteInfo.adjustments
	local naturalTangent = edge.p1 - edge.p0
	local routeAngle = util.signedAngle(naturalTangent, edge.t0)
	local routeAngle2 = util.signedAngle(naturalTangent, edge.t1)
	trace("The routeAngle was ", math.deg(routeAngle), math.deg(routeAngle2))
	if (adjustments.lowerAdjustments >=5 and math.abs(routeAngle) < math.rad(90)
	or adjustments.upperAdjustments >=5 and math.abs(routeAngle2) < math.rad(90) )
	and not recursiveCall
--	or adjustments.isCollisionInevitable and adjustments.totalAdjustments > 0
	then 
		trace("discovered a number of adjustments from base route, solving subroute, lowerAdjustments=",adjustments.lowerAdjustments, " upperAdjustments=",adjustments.upperAdjustments)
		local startFrom = adjustments.lowerAdjustments 
		local endAt = adjustments.upperAdjustments 
		if boundingRoutes[1].isCollisionInevitable and startFrom >0  then 
			startFrom = startFrom + 1
		end 
		if boundingRoutes[2].isCollisionInevitable and endAt >0  then 
			endAt = endAt + 1
		end 		
		local newNumberOfNodes = numberOfNodes - startFrom - endAt
		
		local startPoint = baseRoute[startFrom]  
		local endIndex = (numberOfNodes+1)-endAt
		local endPoint = baseRoute[endIndex] --baseRoute[endIndex+1]
		if not endPoint then endPoint = baseRoute[numberOfNodes+1] end
		trace("new number of nodes was, ",newNumberOfNodes, " original was ",numberOfNodes, "startFrom=",startFrom, " endAt=",endAt, " endIndex=",endIndex, " endPoint was ",endPoint.p.x,endPoint.p.y)
		
		local dummyEdge = {
			p0 = startPoint.p,
			p1 = endPoint.p, 
			t0 = util.distance(startPoint.p, endPoint.p)*vec3.normalize(startPoint.t),
			t1 = util.distance(startPoint.p, endPoint.p)*vec3.normalize(endPoint.t),
		}
		if util.tracelog then 
			debugPrint({dummyEdgeForSubRoute=dummyEdge})
		end
		if newNumberOfNodes > 2 then 
			local originalNewNodeCount = params.newNodeCount 
			params.newNodeCount = nil 
			--local subRoute = routeEvaluation.evaluateRoute(newNumberOfNodes, dummyEdge, params, true, boundingRoutes)
			local subRoute = routeEvaluation.evaluateRoute(newNumberOfNodes, dummyEdge, params, true, emptyBoundingRoute())
			if util.tracelog then 
				debugPrint({baseRoute=baseRoute,subRoute=subRoute})
			end 
			if params.newNodeCount then 
				local diff = params.newNodeCount -newNumberOfNodes 
				local oldNumberOfNodes = numberOfNodes
				numberOfNodes = numberOfNodes + diff 
				for i = numberOfNodes+1, endIndex, -1 do 
					local j = i-diff
					trace("Transferring point from ",j," to ",i)
					baseRoute[i] = baseRoute[j]
				end 
				trace("A new node count detected, the original newNumberOfNodes=",newNumberOfNodes, " the diff=",diff," recalculated=",numberOfNodes) 
				params.newNodeCount = numberOfNodes
				endIndex = (numberOfNodes+1)-endAt
			else 
				params.newNodeCount = originalNewNodeCount
			end 
			trace("combinging subroute result with base route, startFrom=",startFrom,"endIndex=",endIndex,"size of baseRoute=",util.size(baseRoute),"#baseRoute=",#baseRoute) 
			for i = 1, startFrom do 
				baseRoute[i].followRoute = true 
			end
			for i = endIndex, numberOfNodes do 
				baseRoute[i].followRoute = true 
			end			
			for i = startFrom, endIndex do
				if not baseRoute[i] then 
					trace("Error, i out of bounds, i=",i,"startFrom=",startFrom,"endIndex=",endIndex,"#baseRoute=",#baseRoute)
				end
				local originalP = baseRoute[i].p
				baseRoute[i]=subRoute[i-startFrom]
				trace("baseRoute[i]==nil?",baseRoute[i]==nil,"originalP==nil?",originalP==nil,"at i =",i)
				trace("Setting route at ",i, "p=",baseRoute[i].p.x,baseRoute[i].p.y,baseRoute[i].p.z, " from subroute, originally",originalP.x,originalP.y,originalP.z)
				if i == startFrom or i == endIndex then 
					baseRoute[i].followRoute=true
				end
			end
			return baseRoute
		end
	end  
	
	local totalDist = util.distance(edge.p0, edge.p1) 
	
	local segLength = totalDist/(numberOfNodes+1)
	if needsSpiral then
		util.trace("Begin calculating spiral")
		-- needs spiral 
		params.suppressSpiral = true 
		baseRoute = routeEvaluation.evaluateRoute(numberOfNodes, edge, params,true)
		params.suppressSpiral = false
		local totalDist = 0 
		local distSum = {}
		for i = 1, numberOfNodes+1 do 
			local p0 = baseRoute[i-1].p
			local p1 = baseRoute[i].p
			local t0 = baseRoute[i-1].t2
			local t1 = baseRoute[i].t
			totalDist = totalDist + util.calcEdgeLength2d(p0, p1, t0, t1)
			distSum[i]=totalDist
		end
		local maxDeltaZ = maxGradFrac*totalDist 
		trace("The totalDist was recalculated to ", totalDist," from ",util.distance(edge.p0, edge.p1))
		if math.abs(deltaz) <=maxDeltaZ  then 
			trace("After solving for route the spiral is no longer required maxDeltaZ=",maxDeltaZ," deltaz was ",deltaz) 
			params.newNodeCount = numberOfNodes
			return baseRoute
		end
		
		
		local difference = math.max(params.minZoffset, math.abs(deltaz)- maxDeltaZ)
		local requiredLength = difference / maxGradFrac 
		local initialRadius = requiredLength / (2 * math.pi)
		local trackData = api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua"))
		
		local edgeWidthForSpiral = params.isTrack and 2*trackWidth or 0.75*params.edgeWidth
		
		local minRadius = edgeWidthForSpiral + trackData.minCurveRadiusBuild
		if not params.isTrack and not params.isHighway then 
			minRadius = 50 
		end
		local radius = math.max(initialRadius, minRadius)
		local newGrad = deltaz / (totalDist + 2*math.pi*radius)
		trace("the new calculated grad was ",newGrad)
		local expectedDeltaz = maxGradFrac*2*math.pi*radius
		local expectedNewDeltaz = math.abs(deltaz)-expectedDeltaz
		local expectedNewDeltazPerSeg = expectedDeltaz / (numberOfNodes-4)
		
		local spiralCount = 1
		local maxRadius = math.max(minRadius, math.min(params.maxSpiralRadius, totalDist / 6))
		trace("Max radius was ",maxRadius, " compared with calculated radius =",radius)
		if radius > maxRadius then 
			spiralCount = math.ceil(radius/maxRadius)
			radius = radius / spiralCount
			local function calculateNewGrad() 
				local endRadius = radius + spiralCount*2*edgeWidthForSpiral
				local avgRadius = (radius + endRadius) / 2
				return deltaz / (totalDist + 2*math.pi*avgRadius*spiralCount)
			end
			
			newGrad = calculateNewGrad() 
			local newGradFactor  = math.floor(spiralCount*(maxGradFrac/newGrad ))
			trace("Too big radius resetting to ",radius, " calculated end radius as ",endRadius, " recalculated new Grad to",newGrad, "new gradFactor was",newGradFactor)
			if  newGradFactor > 1 then 
				spiralCount = spiralCount - 1
				newGrad = calculateNewGrad() 
				trace("After reducing the spiral count",spiralCount,"end radius calculated end radius as ",endRadius, " recalculated new Grad to",newGrad)
				if newGrad > maxGradFrac then 
					trace("The new grad was higher than allowed, resetting at ",spiralCount)
					spiralCount = spiralCount + 1 
					newGrad = calculateNewGrad()
				end 
			end 
		end			
		local offsetNeeded = math.min(math.floor(numberOfNodes/2), 1+math.max(math.ceil(radius/segLength),2)) 
		local maxOffset = numberOfNodes - math.max(offsetNeeded,params.spiralNodeCount)
		util.trace("calculated radius as ", initialRadius, " set to ",radius, " based on required deltaz of ", difference, " total deltaz was ",deltaz," maxDeltaZ=",maxDeltaZ, "expectedDeltaz=",expectedDeltaz, " expectedNewDeltaz=",expectedNewDeltaz,  " expectedNewDeltazPerSeg=",expectedNewDeltazPerSeg, " offsetNeeded=",offsetNeeded, "maxOffset=",maxOffset)
		if maxOffset < offsetNeeded then 
			local halfway = numberOfNodes / 2
			offsetNeeded = math.floor(halfway)
			maxOffset = math.ceil(halfway)
			
			trace("WARNING! the maxOffset was lower than offsetNeeded, attempting to correct set to",offsetNeeded,maxOffset) 
			
		end 
		
		local goingUp = deltaz > 0 
		
		local scores = {}
		local scoreMap = {}
		local spiralChoices = {}
		local endSpiral = 8*spiralCount
		for __, sign in pairs({-1, 1}) do
			
			for i = offsetNeeded, maxOffset do
				local totalSpiralDist = 0
				local lastPoint = util.v3(baseRoute[i].p) 
				--lastPoint.z = baseRoute[0].p.z + (goingUp and -i*expectedNewDeltazPerSeg or i*expectedNewDeltazPerSeg)
			
				local nextRadius = radius
				local tangentLength =  0.5*nextRadius * 4 * (math.sqrt(2) - 1)
				local curveSegLength = nextRadius*math.rad(45)
				--local deltazPerSeg = maxGradFrac*curveSegLength
				local deltazPerSeg = newGrad * curveSegLength
				lastPoint.z = baseRoute[0].p.z + newGrad * distSum[i] - deltazPerSeg
				trace("Caluclated lastPoint.z=",lastPoint.z," at i=",i," over a distance ",distSum[i])
				local lastTangent = tangentLength * vec3.normalize(baseRoute[i].t)
				--lastTangent.z = goingUp and deltazPerSeg or -deltazPerSeg
				lastTangent.z = deltazPerSeg
				local spiralPoints = {}
				--lastPoint = lastPoint+lastTangent
				--spiralPoints[1]={p=lastPoint, t = lastTangent, t2 = lastTangent} 
				
				local cos45 = math.cos(math.rad(45))
				
				for j = 1, endSpiral do 
					curveSegLength = nextRadius*math.rad(45)
					tangentLength =  0.5*nextRadius * 4 * (math.sqrt(2) - 1)
					totalSpiralDist = totalSpiralDist + tangentLength
					deltazPerSeg = newGrad*curveSegLength
					lastTangent = vec3.normalize(lastTangent)
					local tangent = util.rotateXYkeepingZ(lastTangent, sign* math.rad(45))
					local tangentPerp = util.rotateXYkeepingZ(lastTangent, sign*math.rad(90))
					local point = lastPoint + (1-cos45)*nextRadius*tangentPerp + cos45*nextRadius* lastTangent
					util.trace("deltaz at j",j," = ",(point.z-lastPoint.z), "tangent.z=",tangent.z,"lastTangent.z=",lastTangent.z, " deltazPerSeg=",deltazPerSeg)
					tangent = tangentLength * tangent
					tangent.z = deltazPerSeg
					point.z = lastPoint.z + tangent.z
					spiralPoints[j]={p=point, t=tangent, t2=tangent}
					lastTangent= tangent
					lastPoint = point
					nextRadius = nextRadius + edgeWidthForSpiral / 4
				end
				--spiralPoints[10]={p=lastPoint+lastTangent, t = lastTangent, t2 = lastTangent}
				
				-- have to score the whole route, will assume that there is a smooth continuous gradient either side of the spiral
				local pointsForScore = {}
				for j = 1, i do
					local p = util.v3(baseRoute[j].p)
					p.z = baseRoute[0].p.z + newGrad*distSum[j]
					table.insert(pointsForScore, p)
				end
				for j = 1, #spiralPoints do
					table.insert(pointsForScore, spiralPoints[j].point)
				end
				
				for j = i+#spiralPoints, numberOfNodes do
					local p = util.v3(baseRoute[j].p)
					local lastPoint = pointsForScore[#pointsForScore]
					p.z = baseRoute[numberOfNodes+1].p.z - newGrad * distSum[j]
					--p.z = lastPoint.z + (goingUp and -expectedNewDeltazPerSeg or expectedNewDeltazPerSeg)
					table.insert(pointsForScore, p)
				end
				
				local score =  scoreRouteHeights2(pointsForScore)
				
				
				table.insert(scores, score)
				local result = { startIndex = i, endIndex = i+#spiralPoints, points = spiralPoints, score = score, totalSpiralDist=totalSpiralDist}
				scoreMap[score]=result
			end
		end
		table.sort(scores)
		local best = scores[1]
		local bestResult = scoreMap[best]
		util.trace("spiral deltaz was", bestResult.points[#bestResult.points].p.z-bestResult.points[1].p.z)
		local pointsBefore = bestResult.startIndex    
		local pointsAfter = numberOfNodes - pointsBefore 
		local nonSpiralPoints = pointsBefore+pointsAfter
		local spiralStart = bestResult.points[1].p
		local spiralEnd = bestResult.points[#bestResult.points].p
		
		local spiralSegLength = (radius*2*math.pi)/8 
		if spiralSegLength > 2*params.targetSeglenth then 
			trace("Splitting spiral segments, segLength was ",spiralSegLength," vs target",params.targetSeglenth," totalSpiralDist=",bestResult.totalSpiralDist)
			local newResult = {} 
			newResult.points = {bestResult.points[1]} 
			for i = 2, #bestResult.points do 
				local before = bestResult.points[i-1]
				local this = bestResult.points[i]
				local edge = { p0 = before.p, p1 = this.p, t0 = before.t2, t1 = this.t }
				local solution = util.solveForPositionHermiteFraction(0.5, edge)
				before.t2 = solution.t0 
				table.insert(newResult.points, { p=solution.p, t = solution.t1, t2=solution.t2})
				this.t = solution.t3 
				table.insert(newResult.points, this)
				
			end 
			newResult.startIndex = bestResult.startIndex
			newResult.endIndex = bestResult.startIndex+#newResult.points
			bestResult = newResult
		end
		
		
		local useAlternativeResult = true 
		trace("Checking if should directly connect original route based on the number of points",#bestResult.points," and the numberOfNodes=",numberOfNodes," totalSpiralDist=",bestResult.totalSpiralDist)
		if #bestResult.points > numberOfNodes then 
			trace("not using alterntiveresult")
		end 
		if useAlternativeResult then 
			local result = {}
			local startHeight = baseRoute[0].p.z
			local endHeight = bestResult.points[1].p.z
			local grad = (endHeight-startHeight)/distSum[bestResult.startIndex]
			trace("The start section grad was ",grad, "startHeight=",startHeight,"endHeight=",endHeight, " over ",distSum[bestResult.startIndex], " startIndex was ",bestResult.startIndex)
			local priorPoint = baseRoute[0]
			for i=0, bestResult.startIndex do
				local point = baseRoute[i] -- turns out iteration with zero based index screws up the ordering
				local length = util.calcEdgeLength2d(priorPoint.p, point.p, priorPoint.t2, point.t)
				if i > 0 then 
					point.p.z = priorPoint.p.z+(grad*length)
					point.t.z = point.p.z-priorPoint.p.z
					if i > 1 then 
						priorPoint.t2.z = point.p.z-priorPoint.p.z
					end
				end
				util.trace("route before point at ",i, " point=",point.p.x,point.p.y,point.p.z," tangent ",point.t.x,point.t.y,point.t.z)
				table.insert(result, point)
				priorPoint = point
			end
			result[#result].spiralPoint = true
			for i, point in pairs(bestResult.points) do
				util.trace("spiral point at ",#result, " point=",point.p.x,point.p.y,point.p.z," spiral tangent ",point.t.x,point.t.y,point.t.z, " tangent size=",vec3.length(point.t))
				point.spiralPoint = true
				table.insert(result, point)
			end
			--local routeAfter = routeEvaluation.evaluateRoute(pointsAfter, edgeAfter, params,true)
			local startHeight = result[#result].p.z
			local endHeight = baseRoute[numberOfNodes+1].p.z
			local grad = (endHeight-startHeight)/(totalDist-distSum[bestResult.startIndex])
			local priorPoint = result[#result]
			local nextPoint = baseRoute[bestResult.startIndex+1]
			local nextNextPoint = baseRoute[bestResult.startIndex+2]
			local shiftOffset = bestResult.points[#bestResult.points].p-baseRoute[bestResult.startIndex].p
			trace("The length of the shift offset was ",vec3.length(shiftOffset)," 2d length",vec2.length(shiftOffset))
			local dist = util.distance(priorPoint.p, nextNextPoint.p)
			local edge = {
				p0 = priorPoint.p ,
				p1 = nextNextPoint.p, 
				t0 = dist*vec3.normalize(priorPoint.t2),
				t1 = dist*vec3.normalize(nextNextPoint.t)
			}
			util.correctTangentLengthsProposedEdge(edge)
			local solution = util.solveForPositionHermiteFraction(0.5, edge) -- try to smooth out the  transition
			nextPoint.p = solution.p
			priorPoint.t2 = solution.t0 
			nextPoint.t = solution.t1 
			nextPoint.t2 = solution.t2 
			nextNextPoint.t = solution.t3
			nextPoint.p.z = grad*vec2.distance(priorPoint.p,nextPoint.p)+priorPoint.p.z
			nextPoint.spiralPoint=true
			priorPoint.t2 = util.distance(priorPoint.p,nextPoint.p )*vec3.normalize(priorPoint.t2)
			trace("The end section grad was ",grad, "startHeight=",startHeight,"endHeight=",endHeight)
			for i=bestResult.startIndex+1, numberOfNodes+1  do -- omit the zeroth
				local point = baseRoute[i]
				local length = util.calcEdgeLength2d(priorPoint.p, point.p, priorPoint.t2, point.t)
				if i <= numberOfNodes then 
					point.p.z = priorPoint.p.z+(grad*length)
					point.t.z = point.p.z-priorPoint.p.z
				end
				priorPoint.t2.z = point.p.z-priorPoint.p.z
				util.trace("route after point at ",i, " point=",point.p.x,point.p.y,point.p.z," tangent ",point.t.x,point.t.y,point.t.z)
				table.insert(result, point)
				priorPoint = point
			end
			
			params.newNodeCount=#result-2
			trace("New node count set to ",params.newNodeCount)
			local result2 = {}
			for i =1 , #result  do -- needs to be zero based
				result2[i-1]=result[i]
			end
			--if tracelog then debugPrint(result2) end
			assert(util.size(result2)==util.size(result))
			return result2
		end
		
		
		
		trace("The spiralStart was at ",spiralStart.x, spiralStart.y, " the spiralEnd was at ",spiralEnd.x, spiralEnd.y)
		local fraction = util.solveForPositionHermite(spiralStart, edge)
		fraction = util.distance(edge.p0, spiralStart)/totalDist
		local expectedBefore = math.round(fraction*nonSpiralPoints)
		util.trace("pointsBefore=",pointsBefore," pointsAfter=",pointsAfter,"fraction=",fraction," expectedBefore=",expectedBefore)
		while expectedBefore ~= pointsBefore and pointsAfter>2 and pointsBefore>2 do 
			util.trace("Before shifting points before, ", pointsBefore, " points after",pointsAfter," fraction=",fraction," expectedBefore=",expectedBefore)
			if expectedBefore > pointsBefore then
				pointsBefore = pointsBefore + 1
				pointsAfter = pointsAfter - 1
			else 
				pointsBefore = pointsBefore - 1
				pointsAfter = pointsAfter + 1
			end
			util.trace("After shifting points before, ", pointsBefore, " points after",pointsAfter," fraction=",fraction," expectedBefore=",expectedBefore)
		end
		local edgeBefore  = { 
			p0=edge.p0, 
			t0=pointsBefore*segLength*vec3.normalize(edge.t0),
			p1=spiralStart,
			t1=pointsBefore*segLength*vec3.normalize(bestResult.points[1].t)
			}
		
		util.correctTangentLengthsProposedEdge(edgeBefore)
		--assert(pointsBefore+pointsAfter+5==numberOfNodes, "should be "..numberOfNodes.." but was "..pointsBefore+pointsAfter+5)
		local edgeAfter  = { 
			p0=spiralEnd,  
			t0=pointsAfter*segLength*vec3.normalize(bestResult.points[#bestResult.points].t), 
			p1=edge.p1,
			t1=pointsAfter*segLength*vec3.normalize(edge.t1)
			}
		util.correctTangentLengthsProposedEdge(edgeAfter)
		util.trace("begin subdivision solve")
		-- combine before, spiral, after
		local result = {}
		local routeBefore = routeEvaluation.evaluateRoute(pointsBefore, edgeBefore, params,true)
		--table.remove(routeBefore) -- replace with spiral node
		for i=0, pointsBefore do
			local point = routeBefore[i] -- turns out iteration with zero based index screws up the ordering
			util.trace("route before point at ",i, " point=",point.p.x,point.p.y,point.p.z," tangent ",point.t.x,point.t.y,point.t.z)
			table.insert(result, point)
		end
		for i, point in pairs(bestResult.points) do
			util.trace("spiral point at ",#result, " point=",point.p.x,point.p.y,point.p.z," spiral tangent ",point.t.x,point.t.y,point.t.z, " tangent size=",vec3.length(point.t))
			point.spiralPoint = true
			table.insert(result, point)
		end
		local routeAfter = routeEvaluation.evaluateRoute(pointsAfter, edgeAfter, params,true)
		for i=1, pointsAfter+1 do -- omit the zeroth
			local point = routeAfter[i]
			util.trace("route after point at ",i, " point=",point.p.x,point.p.y,point.p.z," tangent ",point.t.x,point.t.y,point.t.z)
			table.insert(result, point)
		end
		trace("pointsBefore=",pointsBefore, " pointsAfter=",pointsAfter)
		--assert(#result==originalNumberOfNodes+2, "should be "..(originalNumberOfNodes+2).." but was "..#result)
		params.newNodeCount=#result-2
		local result2 = {}
		for i, point in pairs(result) do -- needs to be zero based
			result2[i-1]=point
		end
		--if tracelog then debugPrint(result2) end
		return result2
		
	end
	
	
	 
	local nextBaseRoute = baseRoute 
	local iterationCount = 0
	local routeOptions = {}
	
	local deviationPerSegment = params.routeDeviationPerSegment
	trace("Begin iteration, deviationPerSegment=",deviationPerSegment)
	local function isWaterFreeRoute(baseRoute) 
		for i =1 , #baseRoute do 
			if util.th(baseRoute[i].p)<util.getWaterLevel() then 
				return false
			end
		end
		return true
	end
	params.isWaterFreeRoute = isWaterFreeRoute(baseRoute)
	local longRoute = numberOfNodes > 200
	local outerIterations = params.outerIterations
	if longRoute then 
		 --outerIterations = outerIterations*2
	end
	local halfItrs = math.floor(outerIterations/2)
	local decrement = math.floor(deviationPerSegment/outerIterations)
	params.disableCollisionEvaluation  =false
	local maxRoutesPerIteration = 2*math.ceil(params.routeEvaluationLimit/outerIterations)
	if longRoute then 
		-- maxRoutesPerIteration = 2*maxRoutesPerIteration
	end
	assert(util.positionsEqual(baseRoute[numberOfNodes+1].p, edge.p1), " end point has cahnged")
	local nonZeroWeightForTerrain = (params.thisRouteScoreWeighting[scoreRouteHeightsIdx] > 0 or params.thisRouteScoreWeighting[scoreEarthWorksIdx] > 0) and params.thisRouteScoreWeighting[scoreDistanceIdx] < 100 and params.thisRouteScoreWeighting[scoreDirectionHistoryIdx] < 100 
	local priorIterationTime = os.clock()
	local behavioursByCount = {}
	local function buildBestRoute(finalRoute)
		local sortedRouteOptions = util.evaluateAndSortFromScores(routeOptions,  params.thisRouteScoreWeighting, nil, getMinMaxScores(numberOfNodes))
		--[[if params.isDebugResults then 
			trace("Showing shorted options")
			for i = 1, math.min(#sortedRouteOptions, 25) do
				debugPrint(sortedRouteOptions[i])
			end 
		end ]]--
		for i, bestOption in pairs(sortedRouteOptions) do 
			--local bestOption = util.evaluateWinnerFromScores(routeOptions, params.thisRouteScoreWeighting)
			if params.drawRoutes then
				local unsmoothed = { [0]={ p = baseRoute[0].p}}
				for i =1 , numberOfNodes do 
					unsmoothed[i]={p=bestOption.points[i]}
				end 
				unsmoothed[numberOfNodes+1]= {p=baseRoute[numberOfNodes+1].p}
				debugPrint({unsmoothed=unsmoothed})
				drawRoute(unsmoothed, numberOfNodes, 0, -1000)
				sleep(1)
			end 
			local nextBaseRoute = buildRouteAndApplySmoothing(baseRoute, bestOption, numberOfNodes, maxGradFrac, params, boundingRoutes, finalRoute)
			if params.isDebugResults then 
				trace("Set nextBaseRoute at i=",i,"iterationCount=",iterationCount)
				debugPrint(bestOption)
			end 
			if i > 25 or not checkForLooping(nextBaseRoute,numberOfNodes, "buildBestRoute at "..tostring(i)) then 
				--[[if finalRoute then 
					local result = buildBasicRoute(baseRoute, bestOption, numberOfNodes)
					for i, p in pairs(result) do  
						p.frozen = true
						p.followRoute = true
					end 
				end ]]--
				
				return nextBaseRoute
			end 	
			trace("WARNING! Looping detected")
		end
	end 
	repeat
		local behaviour = iterationCount % 2 == 0 and 2 or 1
		--if longRoute then behaviour = 1 end 
		if nonZeroWeightForTerrain and iterationCount  % 3 == 1 or testTerrainScoring then 
			behaviour = 3
		end
		if iterationCount  % 6 == 1 then 
			behaviour = 4
		end 
		if params.routeEvaluationBehaviourOverride > 0 then 
			behaviour = params.routeEvaluationBehaviourOverride
			trace("Overriding behaviour from params", behaviour)
		end 
		--behaviour =  2
		if iterationCount == halfItrs  and outerIterations > 5 then 
			if #routeOptions == 0 then -- unlikely to resolve by halfway point, default to base route, perhaps logic in route preperation can deconflict
				trace("WARNING! Unable to find any route")
				params.disableCollisionEvaluation  =true
			else 
				trace("Performing midway full solve, numroute options was ",#routeOptions)
				--local bestOption = util.evaluateWinnerFromScores(routeOptions, params.thisRouteScoreWeighting)
				--nextBaseRoute = buildRouteAndApplySmoothing(baseRoute, bestOption, numberOfNodes, maxGradFrac, params, boundingRoutes)
				deviationPerSegment = params.routeDeviationPerSegment
			end
		end
		params.currentIterationCount = iterationCount
		params.isWaterFreeRoute = params.isWaterFreeRoute or isWaterFreeRoute(nextBaseRoute)
		local iterationTime = os.clock()
		
		 --behaviour = iterationCount%2 == 0 and 2 or 3
		if not behavioursByCount[behaviour] then 
			behavioursByCount[behaviour] = 0
		end 
		behavioursByCount[behaviour]=1+behavioursByCount[behaviour]
		
		local reverseSearch = behavioursByCount[behaviour]%2 == 0  
		--reverseSearch = true
		trace("Begin major iteration ", iterationCount, " of ",params.outerIterations," behaviour =",behaviour, "deviationPerSegment=",deviationPerSegment," time taken so far:",(iterationTime-startTime), "time since last",(iterationTime-priorIterationTime),"reverseSearch=",reverseSearch)
		--params.status2 = _("Iterating route").." "..iterationCount.." ".._("of").." "..params.outerIterations

		if params.drawRoutes then 
			drawRoute(nextBaseRoute, numberOfNodes, 0, -1-iterationCount)
		end 
		local nextResult = evaluateRouteFromBaseRoute(nextBaseRoute, numberOfNodes, params, maxGradFrac, maxRoutesPerIteration, behaviour, boundingRoutes, deviationPerSegment, reverseSearch)
		if nextResult then 
			for i, route in pairs(nextResult.routeOptions) do
				table.insert(routeOptions, route)
			end
		end 
		nextBaseRoute =  buildBestRoute()
		if params.drawRoutes and nextBaseRoute then 
			drawRoute(nextBaseRoute, numberOfNodes, 0, iterationCount)
			sleep(1)
		end 
			--if validateRouteTangents(nextResult.newRoute) then 
			--	nextBaseRoute = nextResult.newRoute
				
		
				 
				
		--	end
			deviationPerSegment = deviationPerSegment - decrement
			if deviationPerSegment <= 5 then 
				deviationPerSegment = params.routeDeviationPerSegment
			end
		if not nextBaseRoute then  
			trace("No result was found, reverting to base route and reducing the deviationPerSegment to ",deviationPerSegment)
			deviationPerSegment = deviationPerSegment - 5
			if deviationPerSegment <= 5 then 
				deviationPerSegment = 50
				edge.t0 = 1.1*edge.t0
				edge.t1 = 1.1*edge.t1 
			end
		
			nextBaseRoute = buildBaseRouteFromEdge(edge, numberOfNodes, boundingRoutes, params, originalNumberOfNodes).baseRoute
			assert(util.positionsEqual(nextBaseRoute[numberOfNodes+1].p, edge.p1))
		end
		if iterationCount == math.floor(params.outerIterations/2) then 
			--smoothToTerrain(nextBaseRoute, numberOfNodes, params)
		end 
		priorIterationTime = iterationTime
		iterationCount = iterationCount + 1
		--pcall(coroutine.yield)
	until iterationCount >= params.outerIterations
	local beginSort = os.clock() 
	--local bestOption = util.evaluateWinnerFromScores(routeOptions, params.thisRouteScoreWeighting)
	local result =  buildBestRoute(true)
	if params.drawRoutes then 
		drawRoute(nextBaseRoute, numberOfNodes, 0, iterationCount)
	end 
	if not result then 
		trace("WARNING! Unable to get result, falling back to baseRoute")
		result = baseRoute 
	end 
	for i = 1, numberOfNodes do 
		result[i].followRoute = result[i].followRoute or baseRoute[i].followRoute
	end 
	
	
	trace("Sorted ",#routeOptions," time taken",(os.clock()-beginSort))
	--local result = buildRouteAndApplySmoothing(baseRoute, bestOption, numberOfNodes, maxGradFrac, params, boundingRoutes, true)
	

	
	local endTime = os.clock()

	if util.tracelog and false  then 
		--
		for i, bestOption in pairs(util.evaluateAndSortFromScores(routeOptions,  params.thisRouteScoreWeighting)) do 
		
			if i <= 50 then 
				debugPrint({i=i,scores=bestOption.scores, score=bestOption.score,scoreNormalised=bestOption.scoreNormalised})
			else 
				break 
			end 
		end 
	
	end 
	params.smoothFrom = nil 
	params.smoothTo = nil
	 
	if params.drawRoutes then 
		ourBox.drawBox()
	end 
	util.trace("end evaluate route. Total number of routes considered =",#routeOptions, " time taken was ", (endTime-startTime), " time since final sort",(endTime-beginSort))
	assert(util.size(result)==numberOfNodes+2, "should be "..(numberOfNodes+2).." but was "..util.size(result))
	 
	if not recursiveCall then 
		clearCachedData()
		params.routeCharactericsCache = nil
	end 
	return result
end


function routeEvaluation.scoreDeadEndNode(node, stationPos)
	
		-- prefer highway connections
		if util.isAdjacentToHighwayJunction(node) then 
			return 0 
		end
	
		if util.isTunnelPortal(node) then 
			return 10 -- difficult to build from portal nodes
		end
		local segs = util.getStreetSegmentsForNode(node)
		for i, seg in pairs(segs) do 
			if util.edgeHasTpLinksToStation(seg) then 
				return 10 -- not a good prospect likely hemmed in
			end 
		end 
		if #segs == 1 or util.isCornerNode(node) then  
			local nodeDetails = util.getDeadEndNodeDetails(node) 
			for i, station in pairs(util.searchForEntities(nodeDetails.nodePos, 20, "STATION")) do 
				if station.carriers.RAIL then 
					local p = nodeDetails.nodePos + 30 * vec3.normalize(nodeDetails.tangent)
					local offset = 10 
					local zOffset = 10
					for i, entity in pairs(util.findIntersectingEntities(p, offset, zOffset)) do 
						if entity == station.id then 
							return 10 -- station collision
						end
					end 					
				end
			end
			local vectorToStation = stationPos - nodeDetails.nodePos 
			local angle = util.signedAngle(nodeDetails.tangent, vectorToStation)
			--trace("Angle of node tangent ",nodeDetails.node, " to station ", stationPos.x, stationPos.y, " was ",math.deg(angle))
			if math.abs(angle)<math.rad(45) then 
				return 0 
			end
			if math.abs(angle)<math.rad(60) then 
				return 1 
			end
			if math.abs(angle) > math.rad(90) then 
				return 4 -- in the wrong direction, discourage
			end
		elseif #segs == 2 then -- necessitates a 90 degree turn, have a lower prefrence
			local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(segs[1]) 
			local vectorToStation = stationPos - nodeDetails.nodePos 
			local angle = util.signedAngle(nodeDetails.tangent, vectorToStation)
			local angle2 = angle < 0 and angle+math.rad(180) or angle-math.rad(180)
			--trace("Angle of node perp junction tangent ",nodeDetails.node, " to station ", stationPos.x, stationPos.y, " was ",math.deg(angle), " or ",math.deg(angle2))
			local minAngle = math.min(math.abs(angle), math.abs(angle2))
			if minAngle <math.rad(18) then 
				return 3 
			end
			if minAngle <math.rad(36) then 
				return 4 
			end 
			if minAngle <math.rad(54) then 
				return 5
			end
			if minAngle < math.rad(72) then 
				return 6
			end  
			return 8
		elseif #segs == 3 then -- T-junction can be good for avoiding a 90 degree turn, but must face the right direction
			local nodeDetails = util.getOutboundNodeDetailsForTJunction(node) 
			local vectorToStation = stationPos - nodeDetails.nodePos 
			local angle = util.signedAngle(nodeDetails.tangent, vectorToStation)
			--trace("Angle of node T-junction tangent ",nodeDetails.node, " to station ", station, " was ",math.deg(angle))
			if math.abs(angle)<math.rad(30) then 
				return 0 
			end
			if math.abs(angle)<math.rad(60) then 
				return 1 
			end
			if math.abs(angle)>math.rad(90) then 
				return 10 -- facing wrong way 
			end
		end 
		return 10
	end
local function shouldRejectNode(node) 
		--trace("evaluateRoadRouteOptions: considering node",node)
		if type(node)=="table" then 
			node = node.id or node.node
		end 
		local nodePos = util.nodePos(node)
		for i, edge in pairs(util.searchForEntities(nodePos, 15, "BASE_EDGE")) do 
			if edge.track then  
				if math.abs(edge.node0pos[3]-nodePos.z) < 10 or  math.abs(edge.node1pos[3]-nodePos.z)< 10 then 
					--trace("rejecting node due to nearby track")
					 return true 
				end 
			end 
		end 
		if util.isNodeConnectedToFrozenEdge(node) then 
			return true 
		end
		--[[if util.isDeadEndNode(node, true) then 
			return false
		end]]-- 
		if #util.getTrackSegmentsForNode(node) > 0 then
			return true
		end
		if #util.getSegmentsForNode(node) > 3 then
			return true
		end
		if util.isTunnelPortal(node) then 
			return true 
		end
		
		for __, seg in pairs(util.getSegmentsForNode(node)) do 
			if util.isIndustryEdge(seg) then 
				return true
			end
			if util.edgeHasTpLinksToStation(seg) then -- can get hemmed in or worse break connection
				return true 
			end 
			local edge = util.getEdge(seg)
			if #util.getTrackSegmentsForNode(edge.node0) > 0 or #util.getTrackSegmentsForNode(edge.node1) > 0 then 
				 return true 
			end 
			if util.getStreetTypeCategory(seg) =="highway" then 
				return true 
			end 
			if util.getStreetTypeCategory(seg) == "entrance" and not util.isCornerNode(node) then 
				return true 
			end 
			if math.abs(util.signedAngle(edge.tangent0, edge.tangent1)) > math.rad(60) then -- sharp curves 
				return true 
			end 
		end
		return false
	end
function routeEvaluation.evaluateRoadRouteOptions(nodePair, stations, params)
	trace("Begin evaluate road route options")
	profiler.beginFunction("evaluateRoadRouteOptions")
	local begin = os.clock()

	-- Guard against nil nodePair
	if not nodePair or not nodePair[1] or not nodePair[2] then
		trace("ERROR: evaluateRoadRouteOptions called with nil or incomplete nodePair")
		profiler.endFunction("evaluateRoadRouteOptions")
		return nil
	end

	util.lazyCacheNode2SegMaps()


	local leftStation = stations and  stations[1]
	local rightStation = stations and stations[2]
	local isUrbanStop1 = leftStation and ( -1 == api.engine.system.streetConnectorSystem.getConstructionEntityForStation(leftStation) or not util.getStation(leftStation).cargo)
	local isUrbanStop2 = rightStation and (-1 == api.engine.system.streetConnectorSystem.getConstructionEntityForStation(rightStation) or not util.getStation(rightStation).cargo)
	local leftNode = nodePair[1]
	local rightNode = nodePair[2]
	local leftNodePos = util.nodePos(leftNode)
	local rightNodePos = util.nodePos(rightNode)
	local middlePos = 0.5*(rightNodePos-leftNodePos)+leftNodePos
	local searchRadius = 0.5*util.distance(rightNodePos, leftNodePos)
	

	
	local nodes = util.combine(
		util.searchForUncongestedDeadEndOrCountryNodes(middlePos, searchRadius)
		, util.searchForUncongestedDeadEndOrCountryNodes(leftNodePos, 200), 
			util.searchForUncongestedDeadEndOrCountryNodes(rightNodePos, 200))
	local nodesCount =  util.size(nodes)
	if nodesCount > 100 then 
		trace("A large number of nodes was found, filtering")
		local options = {} 
		for i, node in pairs(nodes) do  
			if not shouldRejectNode(node) then 
				local nodePos = util.nodePos(node)
				table.insert(options, {
					node = node, 
					scores = { util.distance(nodePos, leftNodePos)+util.distance(nodePos, rightNodePos) }
				})
			end 
		end 
		local sortedOptions = util.evaluateAndSortFromScores(options) 
		nodes = {} 
		for i = 1, math.min(100, #sortedOptions) do 
			table.insert(nodes, sortedOptions[i].node)
		end 
		nodesCount = #nodes
	end 
	local leftStationPos = leftStation and util.getStationPosition(leftStation) or leftNodePos
	local rightStationPos = rigthStation and util.getStationPosition(rightStation) or rightNodePos
	trace("After searching from ",middlePos.x, middlePos.y, " at a radius ",searchRadius, " there were ",nodesCount)
	local leftConnectedNodes = {{node=leftNode, routeInfo = leftStation and pathFindingUtil.getRouteInfoForRoadPathBetweenStationAndNode(leftStation, leftNode)}}
	local rightConnectedNodes = {{node=rightNode, routeInfo = rightStation and pathFindingUtil.getRouteInfoForRoadPathBetweenStationAndNode(rightStation, rightNode)}} 
	local nodeScores = {}
	nodeScores[leftNode] = {}
	nodeScores[leftNode].deadEndScoreL = routeEvaluation.scoreDeadEndNode(leftNode, rightStationPos)
	nodeScores[leftNode].nearbyConstructions = util.countNearbyEntities(util.nodePos(leftNode), 100, "CONSTRUCTION")
	nodeScores[rightNode] = {}
	nodeScores[rightNode].deadEndScoreR = routeEvaluation.scoreDeadEndNode(rightNode, leftStationPos)
	nodeScores[rightNode].nearbyConstructions = util.countNearbyEntities(util.nodePos(rightNode), 100, "CONSTRUCTION")
	
	for i, node in pairs(nodes) do
		if shouldRejectNode(node) then
			trace("Rejecting ",node," as it is too close to industry and non a dead end")
			goto continue
		end
	
		local leftRoute = leftStation and pathFindingUtil.getRouteInfoForRoadPathBetweenStationAndNode(leftStation, node) or pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(leftNode, node)
		if leftRoute and (not leftRoute.exceedsRouteToDistLimitForTrucks or  isUrbanStop1) and 
			(util.distBetweenNodes(node,leftNode) > 150 or util.isDeadEndNode(node)) then 
			table.insert(leftConnectedNodes, {node = node, routeInfo = leftRoute})
			nodeScores[node] = {}
			nodeScores[node].deadEndScoreL = routeEvaluation.scoreDeadEndNode(node, rightStationPos)
			nodeScores[node].nearbyConstructions = util.countNearbyEntities(util.nodePos(node), 100, "CONSTRUCTION")
		end
		local rightRoute = rightStation and  pathFindingUtil.getRouteInfoForRoadPathBetweenStationAndNode(rightStation, node)or pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(rightNode, node)
		if rightRoute and (not rightRoute.exceedsRouteToDistLimitForTrucks or isUrbanStop2) and (util.distBetweenNodes(node,rightNode) > 150 or util.isDeadEndNode(node)) then 
			table.insert(rightConnectedNodes, {node = node, routeInfo = rightRoute})
			if not nodeScores[node] then 
				nodeScores[node]= {}
			end
			nodeScores[node].deadEndScoreR = routeEvaluation.scoreDeadEndNode(node, leftStationPos)
			nodeScores[node].nearbyConstructions = util.countNearbyEntities(util.nodePos(node), 100, "CONSTRUCTION")
		end
		::continue::
	end
	trace(#nodes, " searched, found ",#leftConnectedNodes," leftConnectedNodes and ",#rightConnectedNodes," from original nodes ", leftNode, rightNode)
	local distBetweenStations = util.distance(leftStationPos, rightStationPos)
	local truckRouteToDistanceLimit = paramHelper.getParams().truckRouteToDistanceLimit
	local options = {}
	for i, leftSection in pairs(leftConnectedNodes) do 
		for j, rightSection in pairs(rightConnectedNodes) do
			local node0 = leftSection.node
			local node1 = rightSection.node
			trace("Inspecting node pair ", node0, node1)
			local distBetweenNodes=  util.distBetweenNodes(node0, node1)
			local distToBuild = distBetweenNodes*params.assumedRouteLengthToDist
			local existingRouteLength = 0 
			if leftSection.routeInfo then 
				existingRouteLength = existingRouteLength+leftSection.routeInfo.routeLength
			end
			if rightSection.routeInfo then 
				existingRouteLength = existingRouteLength+rightSection.routeInfo.routeLength
			end
			local totalDist = distToBuild + existingRouteLength
			local deadEndScore0 = nodeScores[node0].deadEndScoreL or 0
			local deadEndScore1 = nodeScores[node1].deadEndScoreR or 0
			local reject = node0 == node1 or util.findEdgeConnectingNodes(node0, node1)
			reject = reject or (not isUrbanStop1 and not isUrbanStop2 and totalDist > truckRouteToDistanceLimit*distBetweenStations)
			if not reject then 
				trace("Checking route info between nodes")
				local routeInfo = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(node0, node1)
				reject = routeInfo and not routeInfo.exceedsRouteToDistLimitForTrucks
			end
			local grad = math.abs(util.nodePos(node0).z-util.nodePos(node1).z) / distBetweenNodes
			
			if distBetweenNodes < 150 then  -- too short to put in a spiral
				 
				if grad > 0.2 then 
					trace("Rejecting ",node0,node1," as the gradient is too high",grad," over a distance",distBetweenNodes)
					reject = true 
				end
			end 
			local gradScore =0 
			if grad > params.maxGradient then 
				gradScore = grad 
			end 
			if grad > params.absoluteMaxGradient then 
				gradScore = grad*grad 
			end
			
			local vector = util.vecBetweenNodes(node1, node0)
			for k, node in pairs({node0, node1}) do 
				if #util.getSegmentsForNode(node) == 3 then 
					local outBountTangent = util.getOutboundNodeDetailsForTJunction(node).tangent
					if k == 2 then 
						outBountTangent = -1*outBountTangent
					end 
					local angleToVector = math.abs(util.signedAngle(outBountTangent, vector))
					trace("Inpecting triple tangent for the node",node," angle was",math.deg(angleToVector))
					if angleToVector > math.rad(100) then 
						trace("Rejecting node",node," based on angle to vector")
						reject = true 
					end 
				end 
			end
			if #pathFindingUtil.findRoadPathBetweenNodes(node0,node1) > 0 then 
				reject = true 
				trace("Rejecting already had a path between",node0,node1)
			end 
			trace("Calculated total dist as ",totalDist, " distToBuild=",distToBuild, " deadEndScore0=",deadEndScore0, " deadEndScore1=",deadEndScore1, " for node pair ", node0, node1 , " reject=",reject)
			if not reject then 
				table.insert(options, {
					nodePair = { node0, node1 } ,
					scores = {
						distToBuild,
						totalDist, 
						deadEndScore0,
						deadEndScore1,
						nodeScores[node0].nearbyConstructions,
						nodeScores[node1].nearbyConstructions,
						gradScore
					}
				
				})
			end
		end
	end
	local scoreWeights = {
		100, -- distToBuild
		75, -- totalDist
		25, -- leftNode dead end 
		25,  -- rightNode dead end
		15, -- nearbyConstructions L 
		15, -- nearbyConstructions R
		100, -- grad score
	}	
	--if util.tracelog then debugPrint(options) end
 
	trace("Evaluated ",#options," evaluateRoadRouteOptions time taken was",(begin-os.clock()))
	profiler.endFunction("evaluateRoadRouteOptions")
	if #options == 0 then 
		return nodePair
	end
	return util.evaluateWinnerFromScores(options, scoreWeights).nodePair
end
 
function routeEvaluation.checkForIntermediateStationTrackRoute(station1, station2, params)
	local begin = os.clock()
	profiler.beginFunction("checkForIntermediateStationTrackRoute")
	
	local leftNodePos = util.getStationPosition(station1)
	local rightNodePos = util.getStationPosition(station2)
	local vectorBetweenStations = rightNodePos-leftNodePos
	local middlePos = 0.5*vectorBetweenStations+leftNodePos
	local distance = util.distance(rightNodePos, leftNodePos)
	local searchRadius = 0.75*distance
	local stations = util.searchForEntities(middlePos, searchRadius, "STATION")
	local leftConnectedStations = {station1}
	local rightConnectedStations = {station2} 
	for i, station in pairs(stations) do
		if station.carriers.RAIL and ( station.cargo or params.allowPassengerCargoTrackSharing) then
			local stationPos = util.getStationPosition(station.id)
			 
			local angle = util.signedAngle(vectorBetweenStations, stationPos - leftNodePos) 
			local leftDist = util.distance(stationPos, leftNodePos)
			local relativeLeftDist = leftDist / distance
			local testAngle = math.abs(angle) > math.rad(90) and math.abs(math.rad(180)-math.abs(angle)) or math.abs(angle)
			trace("Angle between station ", station.id, " and ",station1," was ",math.deg(angle), " testAngle=",math.deg(testAngle)," relativeLeftDist was ",relativeLeftDist)
			if math.abs(angle) < math.rad(30) and relativeLeftDist > 0.2 and #pathFindingUtil.findRailPathBetweenStations(station.id, station1) > 0  then
				trace("adding station to test ",station.id)
				table.insert(leftConnectedStations, station.id)
			end
			 
			local angle = util.signedAngle(vectorBetweenStations, rightNodePos-stationPos  )
			local rightDist = util.distance(stationPos, rightNodePos)
			local relativeRightDist = rightDist / distance
			local testAngle = math.abs(angle) > math.rad(90) and math.abs(math.rad(180)-math.abs(angle)) or math.abs(angle)				
			trace("Angle between station ", station.id, " and ",station2," was ",math.deg(angle), " testAngle=",math.deg(testAngle), "relativeRightDist was",relativeRightDist)
			if math.abs(angle) < math.rad(30) and relativeRightDist > 0.2 and #pathFindingUtil.findRailPathBetweenStations(station.id, station2) > 0 then
				
			
					trace("adding station to test ",station.id)
					table.insert(rightConnectedStations, station.id)
				
			end
		end
	end
	trace("checkForIntermediateStationTrackRoute for ",#leftConnectedStations, " and ",#rightConnectedStations, " time taken:",(os.clock()-begin))
	profiler.endFunction("checkForIntermediateStationTrackRoute")
	return util.findShortestDistanceStationPair(leftConnectedStations, rightConnectedStations)
end

local function isLineType(line, enum)
	return line.vehicleInfo.transportModes[enum+1]==1 
end

local function isElectricRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.ELECTRIC_TRAIN)
end

local function isRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.TRAIN) or isElectricRailLine(line)
end

function routeEvaluation.checkForIntermediateTrackRoute(stationOrNodes1, stationOrNodes2, params, intermediateOnly)
	local beginCheckForIntermediateTrackRoute = os.clock()
	profiler.beginFunction("checkForIntermediateTrackRoute")
	util.cacheNode2SegMapsIfNecessary() 
	if not params.thresholdLineCount then 
		params.thresholdLineCount = 12
	end 
--	local isRailLine= true 
	--local allEdges = params.getAllEdgesUsedByLines and params.getAllEdgesUsedByLines() or pathFindingUtil.getAllEdgesUsedByLines(isRailLine)
	

	local destNodes = {}
	local station1 
	local station1Pos
	local station1HasConnectedTrack = true
	local station2 
	local station2Pos
	local station2HasConnectedTrack = true
	trace("Checking for intermediate track route, stationOrNodes type was",type(stationOrNodes))
	local node1 
	local node2
	if type(stationOrNodes1)=="number" then 
		station1 = stationOrNodes1
		station1Pos = util.getStationPosition(station1)
		destNodes[station1] = pathFindingUtil.getDestinationNodesForStation(station1)
		station1HasConnectedTrack = util.stationHasConnectedTrack(station1)
	else 
		station1 = stationOrNodes1[1]
		node1 = station1
		station1Pos = util.nodePos(station1)
		destNodes[station1] = {api.type.NodeId.new(station1,0)}
	end 
	if type(stationOrNodes2)=="number" then 
		station2 = stationOrNodes2
		station2Pos = util.getStationPosition(station2)
		destNodes[station2] = pathFindingUtil.getDestinationNodesForStation(station2)
		station2HasConnectedTrack = util.stationHasConnectedTrack(station2)
	else 
		station2 = stationOrNodes2[1]
		node2 = station2
		station2Pos = util.nodePos(station2)
		destNodes[station2] = {api.type.NodeId.new(station2,0)}
	end  
	local function stationHasConnectedTrack(station) 
		if station == station1 then 
			return station1HasConnectedTrack
		elseif station == station2 then 
			return station2HasConnectedTrack
		else 
			trace("WARNING! Unexpected station",station)
			return true -- assume true 
		end 
	end 
	
	local leftConnectedEdges = {}
	local rightConnectedEdges = {} 
	local matchedPairs = {}
	local isIntermediateRoute = false
	trace("Checking for a existing rail path betwen ",node1,node2)
	if #pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node1, node2)>0 then 
		trace("Found a path between ",node1,node2, " exiting early")
		return { leftConnectedEdges= leftConnectedEdges, rightConnectedEdges = rightConnectedEdges, isIntermediateRoute = isIntermediateRoute }
	end	
	local congestedLines = {}
	local function filterFn(line) 
		if not isRailLine(line) then 
			return false 
		end 
		if not params.allowPassengerCargoTrackSharing then 
			return line.stops[1] and util.getStation(util.stationFromStop(line.stops[1])).cargo
		end 
		return true 
	end 
	
	local allEdges = pathFindingUtil.getAllEdgesUsedByLines(filterFn ) -- always recompute
	trace("checkForIntermediateTrackRoute found all edges size",util.size(allEdges))
	
	local distBetweenStations = util.distance(station1Pos, station2Pos)
	local searchRadius = 0.5*distBetweenStations-200

	
	local midPos = 0.5*(station1Pos+station2Pos)
	local vectorBetweenStations = station2Pos-station1Pos 
	local stationVector = station2Pos - station1Pos
--		local searchRadius = vec3.length(stationVector)/4
	local posOffset = vec3.length(stationVector)/3
	local searchRadius2 = posOffset - 200
	local station1SearchPoint = station1Pos + posOffset*vec3.normalize(stationVector)
	local station2SearchPoint = station2Pos - posOffset*vec3.normalize(stationVector)
	--[[if not station1HasConnectedTrack then 
		station2SearchPoint = midPos 
		trace("setting the station2SearchPoint to the midPos")		
	end 
	if not station2HasConnectedTrack then 
		station1SearchPoint = midPos
		trace("setting the station1SearchPoint to the midPos")		
	end ]]--
	
	local function isEdgeOk(edgeId) 
		if not allEdges[edgeId] then 
			return false 
		end 
		if util.isJunctionEdge(edgeId) then 
			return false 
		end 
		local doubleTrackEdge = util.findDoubleTrackEdge(edgeId)
		if not doubleTrackEdge then 
			return false
		end 
		if util.isJunctionEdge(doubleTrackEdge) then 
			return false 
		end
		if allEdges[edgeId] and #allEdges[edgeId] > params.thresholdLineCount then 
			trace("Edge",edgeId,"rejected as it exceeds the thresoldLineCount")
			return false 
		end
		for i , line in pairs(allEdges[edgeId]) do 
			if congestedLines[line] then -- N.B. this is slightly suboptimal but done for performance
				trace("Edge",edgeId,"rejected as it belongs to a congested line")
				return false 
			end 
		end 
		local edge = util.getEdge(edgeId)
		if util.calculateSegmentLengthFromEdge(edge)<70 then 
			return false 
		end
		for i, node in pairs({edge.node0, edge.node1}) do 
			if #util.getTrackSegmentsForNode(node)> 2 then 
				return false 
			end
			if #util.getStreetSegmentsForNode(node)> 0 then 
				return false 
			end
			local nextEdgeId = edgeId 
			local nextNode = node
			for i = 1, 3 do -- avoid first three segments from construction
				local nextSegs = util.getTrackSegmentsForNode(nextNode)
				nextEdgeId = nextEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
				if not nextEdgeId or util.isFrozenEdge(nextEdgeId) then 
					return false 
				end
				local nextEdge = util.getEdge(nextEdgeId)
				if params.buildGradeSeparatedTrackJunctions and i == 1 then 
					if util.isJunctionEdge(nextEdgeId) then 
						trace("Rejecting for buildGradeSeparatedTrackJunctions ",edgeId," because the connected edge",nextEdgeId," is a junctionEdge")
						return false 
					end 
					if util.calculateSegmentLengthFromEdge(nextEdge) <70 then 
						trace("Rejecting for buildGradeSeparatedTrackJunctions ",edgeId," because the connected edge",nextEdgeId," is too short")
						return false 
					end 
				end 
				
				nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
			end 
		end
		return true
	end
	local minDist = 500 
	-- for performance reasons not using pathFindingUtil
	local linesToEdgesMap = {}
	local edgesToLinesMap = {}
	local virtualLinesByHash = {}
	local linesOverlap = {}
	local virtualLinesChecked = {}
	local function lineHash(line1, line2)
		if line1> line2 then 
			return line1 + 10000000*line2
		else 
			return line2 + 10000000*line1
		end 
	end 
	
	for edge, lineList in pairs(allEdges) do 
		edgesToLinesMap[edge]={}
		local isCongested = #lineList > params.thresholdLineCount
		for j, line in pairs(lineList) do 
			if isCongested then 
				congestedLines[line]=true
			end 
			if not linesToEdgesMap[line] then 
				linesToEdgesMap[line]= {}
			end 
			linesToEdgesMap[line][edge]=true 
			edgesToLinesMap[edge][line]=true
			for k, line2 in pairs(lineList) do 
				if line~=line2 then 
					local hash = lineHash(line, line2)
					if not virtualLinesByHash[hash] then 
						virtualLinesByHash[hash]=true 
						--[[if not linesOverlap[line1] then 
							linesOverlap[line1]={}
						end 
						if not linesOverlap[line2] then 
							linesOverlap[line2]={}
						end 
						linesOverlap[line1][line2]=true 
						linesOverlap[line2][line1]=true ]]--
					end 
					
					
				end 
			end 
		end 
	end 
	if util.tracelog then 
		trace("checkForIntermediateTrackRoute: Found",util.size(virtualLinesByHash),"virtual lines, congestedLines size was",util.size(congestedLines))
	end
	local discoveredTrackEdgesToStations = {}
	local useLegacyMethod = {}
	local function discoverTrackEdgesToStations(station) 
		discoveredTrackEdgesToStations[station]={}
		local lineStops = util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station))
		for i, line in pairs(lineStops) do 
			for edge, bool in pairs(linesToEdgesMap[line] or {}) do 
				discoveredTrackEdgesToStations[station][line]=true
			end 
		end 
		if stationHasConnectedTrack(station) and (#lineStops == 0 or util.size(discoveredTrackEdgesToStations[station])==0)  then 
		
			trace("Using legacy method for station with connected track",station)
			useLegacyMethod[station]=true 
		end 
	
	end 
	local function checkIfEdgesShareLine(edgeId1, edgeId2)
		if not allEdges[edgeId1] or not allEdges[edgeId2] then -- may happen with "inactive" edges like depot connections
			trace("WARNING! areEdgesConnectedWithPath, missing edge infor for",edgeId1,edgeId2)
			return false
		end 
		for i, line in pairs(allEdges[edgeId1]) do 
			if edgesToLinesMap[edgeId2][line] then 
				return line 
			end 
		end 
	end 
	
--	discoveredTrackEdgesToStations[station1] = {}
	--discoveredTrackEdgesToStations[station2] = {}
	 discoverTrackEdgesToStations(station1)
	 discoverTrackEdgesToStations(station2)

	local function isStationConnectedToTrack(edgeId, station) 
		if not useLegacyMethod[station] then 
			return discoveredTrackEdgesToStations[station][edgeId] 
		end 
		if not discoveredTrackEdgesToStations[station][edgeId] then 
			--[[local stationsAndEdges = util.findAllConnectedFreeTrackEdgesAndStations(util.getEdge(edgeId).node0)
			for __, edgeId in pairs(stationsAndEdges.edges) do
				discoveredTrackEdgesToStations[edgeId] = {}
				for __, station in pairs(stationsAndEdges.stations) do 
					discoveredTrackEdgesToStations[edgeId][station]=true
				end
			end--]]
			trace("Inspecting for path between",station,edgeId)
			local startingEdges = pathFindingUtil.getStartingEdgesForEdge(edgeId, api.type.enum.TransportMode.TRAIN) 
			local thisDestNodes = destNodes[station]
			local answer = pathFindingUtil.findPath(startingEdges, thisDestNodes, { api.type.enum.TransportMode.TRAIN}, 2*distBetweenStations)
			if #answer == 0 then 
				answer = pathFindingUtil.findPath( pathFindingUtil.getStartingEdgesForStation(station), pathFindingUtil.getDestinationNodesForEdge(edgeId, api.type.enum.TransportMode.TRAIN),  { api.type.enum.TransportMode.TRAIN}, 2*distBetweenStations)
				trace("Initial attempt found no path, second attempt found",#answer)
			else 
				trace("path was found between",edgeId, station)
				if util.tracelog then 
					debugPrint({startingEdges=startingEdges, thisDestNodes = thisDestNodes })
				end 
			end 			
			for i , seg in pairs(answer) do 
				discoveredTrackEdgesToStations[station][seg.entity]=true
				trace("Marking link between",station,seg.entity, " as discovered")
			end 
			if #answer > 0 and not discoveredTrackEdgesToStations[station][edgeId] then 
				discoveredTrackEdgesToStations[station][edgeId] = true 
			end
			if #answer == 0 then 
				trace("NO path was found between ",edgeId, " and ",station)
			end
		end
		return discoveredTrackEdgesToStations[station][edgeId]
	end
	local leftEdges
	if station2HasConnectedTrack and not intermediateOnly  then -- performance optimisation
	
		local start = os.clock()
		leftEdges = util.combine(util.searchForFreeTrackEdges(midPos, searchRadius, isEdgeOk),
								 util.searchForFreeTrackEdges(station1SearchPoint, searchRadius2, isEdgeOk) ,
								 util.searchForFreeTrackEdges(station2SearchPoint, searchRadius2, isEdgeOk)) 
		local endTime = os.clock()
		trace("checkForIntermediateTrackRoute Found ",#leftEdges, " leftEdges time taken:",(endTime-start))
		for i, edgeId in pairs(leftEdges) do 
			local edgePos =util.getEdgeMidPoint(edgeId)
			if util.distance(edgePos, station2Pos) > minDist then 
				local angle = util.signedAngle(vectorBetweenStations, station2Pos - edgePos) 
				local testAngle = math.abs(angle) > math.rad(90) and math.abs(math.rad(180)-math.abs(angle)) or math.abs(angle)
				trace("Angle between edge ", edgeId, " and station",station2," was ",math.deg(angle), " testAngle=",math.deg(testAngle))
				
				if testAngle < math.rad(45) and isStationConnectedToTrack(edgeId, station2)  then 
				--if #pathFindingUtil.findRailPathBetweenEdgeAndStation(edgeId, station2) > 0 then
				--if  then
					trace("Adding the edge",edgeId,"for consideration on leftConnectedEdges")
					table.insert(leftConnectedEdges, edgeId)
					
				end
			end
		end
		local endTime2 = os.clock()
		trace("Time taken to insert leftConnectedEdges = ",(endTime2-endTime))
	end
	trace("Added ",#leftConnectedEdges," now checking on the right, leftEdges was ",leftEdges)
	if station1HasConnectedTrack and not intermediateOnly  then 
		local start = os.clock()
		local rightEdges = leftEdges 
		if not rightEdges then
			trace("Finding right edges", rightEdges)
			rightEdges = util.combine(util.searchForFreeTrackEdges(midPos, searchRadius, isEdgeOk),
								 util.searchForFreeTrackEdges(station1SearchPoint, searchRadius2, isEdgeOk) ,
								 util.searchForFreeTrackEdges(station2SearchPoint, searchRadius2, isEdgeOk)) 
		end
		local endTime = os.clock()
		trace("checkForIntermediateTrackRoute Found ",#rightEdges, " rightEdges  time taken:",(endTime-start))
		local destNodes = pathFindingUtil.getDestinationNodesForStation(station1)
		for i, edgeId in pairs(rightEdges) do 
			local edgePos =util.getEdgeMidPoint(edgeId)
			if util.distance(edgePos, station1Pos) > minDist then
				local angle = util.signedAngle(vectorBetweenStations, edgePos - station1Pos)
				local testAngle = math.abs(angle) > math.rad(90) and math.abs(math.rad(180)-math.abs(angle)) or math.abs(angle)				
				trace("Angle between edge ", edgeId, " and  station",station1," was ",math.deg(angle), " testAngle=",math.deg(testAngle))
			--if  #pathFindingUtil.findRailPathBetweenEdgeAndStation(edgeId, station2) > 0 then
				
				if testAngle < math.rad(45) and   isStationConnectedToTrack(edgeId, station1 )then
					trace("Adding the edge",edgeId,"for consideration on rightConnectedEdges")
					table.insert(rightConnectedEdges, edgeId)
				end
			end
		end
	end
	trace("CheckForIntermediateTrackRoute initial check complete, time taken:",(os.clock()-beginCheckForIntermediateTrackRoute))
	local minSharedDist = math.max(1000, 0.3*distBetweenStations) -- avoid track sharing small distances
	local checkForPath = checkIfEdgesShareLine
	if #leftConnectedEdges == 0 and #rightConnectedEdges == 0  then 
		pathFindingUtil.cacheDestinationEdgesAndNodes() 
		trace("There were zero of both left and right, trying to find non station route")
		local nextRouteLine = 0
		local pathEdges = {}
		local nextPath = 0
		local uniquenessCheck = {}  

		trace("The station1SearchPoint was",station1SearchPoint.x, station1SearchPoint.y," the station2SearchPoint was ",station2SearchPoint.x,station2SearchPoint.y, " the search radius was",searchRadius, " station1Pos was",station1Pos.x, station1Pos.y, " station2Pos was",station2Pos.x, station2Pos.y)
		local discoveredEdges = {}
		local passengerEdges = {}
		local routeLineToEdges = {}
		local rightHandRouteLines = {}
		local filterToDiscoveredEdges = false
		--[[local function isEdgeOkAndDoubleTrack(edgeId) 
			if not isEdgeOk(edgeId) then
				trace("Rejecting edge",edgeId," as it did not meet initial conditions")
				return false  
			end 
			if filterToDiscoveredEdges and not discoveredEdges[edgeId] then 
				return false
			end 
			if filterToDiscoveredEdges and not rightHandRouteLines[discoveredEdges[edgeId] then 
				rightHandRouteLines[discoveredEdges[edgeId]=true
			end 
			if not discoveredEdges[edgeId] then 
				nextRouteLine = nextRouteLine + 1
				routeLineToEdges[nextRouteLine]={}
				trace("not discoverd edge", edgeId, " searching")
				local edges = util.findAllConnectedFreeTrackEdgesFollowingJunctions(util.getEdge(edgeId).node1)
			 
				local isPassenger = false
				 
				local allEdgesSet = {}
				for i, edge in pairs(edges) do 
					for __ , node in pairs({edge.node0, edge.node1} ) do 
						for i , seg in pairs(util.getTrackSegmentsForNode(node)) do 
							if not allEdgesSet[seg] then 
								allEdgesSet[seg]=true 
							end
						end
					end 
				end 
				local stations = {}
				--if not params.allowPassengerCargoTrackSharing then 
					for edgeId, bool in pairs(allEdgesSet) do 
						local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId) 
						if constructionId ~= -1 then 
							local stationId = util.getConstruction(constructionId).stations[1]
							if stationId then 
								if not util.contains(stations, stationId) then 
									table.insert(stations, stationId)
								end
								local station = util.getComponent(stationId, api.type.ComponentType.STATION)
								if not station.cargo then 
									isPassenger = true
									
								end 
								trace("Discovered station " ,stationId, " isCargo=",station.cargo)
							end
						end 
					end
				--end
				for i, edge in pairs(edges) do 
					local edgeId = util.getEdgeIdFromEdge(edge)
					discoveredEdges[edgeId] = nextRouteLine
					routeLineToEdges[nextRouteLine][edgeId]=true
					if isPassenger then 
						passengerEdges[edgeId]=true 
					end
				end 
				if #stations >= 2 and (params.allowPassengerCargoTrackSharing or not isPassenger) then 
					nextPath = nextPath + 1 
					local path = pathFindingUtil.findRailPathBetweenStations(stations[1], stations[2])
					local path2 = pathFindingUtil.findRailPathBetweenStations(stations[2], stations[1])
					for i, entity in pairs(path) do 
						if not pathEdges[entity.entity] then 
							pathEdges[entity.entity]={}
						end 
						table.insert(pathEdges[entity.entity], nextPath)
					end 
					for i, entity in pairs(path2) do 
						if not pathEdges[entity.entity] then 
							pathEdges[entity.entity]={}
						end 
						table.insert(pathEdges[entity.entity], nextPath)
					end 
					trace("Setup stations path, pathing answers count were",#path,#path2)
				end 
				if #stations == 0 then 
					trace("WARNING! No stations found for edge ",edgeId)
				end
			end
			if passengerEdges[edgeId] and not params.allowPassengerCargoTrackSharing then 
				trace("Rejecting edge",edgeId," as it is a passenger edge")
				return false
			end
			
			
			local edge = util.getEdge(edgeId)
			return util.findDoubleTrackNode(edge.node0) and util.findDoubleTrackNode(edge.node1)			
		end]]--
		local maxGradForStation = (params.absoluteMaxGradient+params.maxGradient)/2
		local function edgeIsOkForStation1(edgeId)
			local edgePos = util.getEdgeMidPoint(edgeId)
			local edgeToStationDist = util.distance(edgePos, station1Pos)
			if edgeToStationDist > distBetweenStations or util.distance(edgePos, station2Pos) > distBetweenStations then 
				trace("Rejecting the edge",edgeId," because of distance",edgeToStationDist)
				return false
			end
			local maxDeltaZ = maxGradForStation*edgeToStationDist
			local deltaZ = math.abs(edgePos.z-station1Pos.z)
			if deltaZ > maxDeltaZ then
				trace("Rejecting the edge",edgeId," because of deltaz ",deltaZ," exceeds  ",maxDeltaZ, " based on edgeToStationDist=",edgeToStationDist,"maxGrad =",maxGradForStation)
				return false 
			end 
			return isEdgeOk(edgeId) 
		end
		local function edgeIsOkForStation2(edgeId)
			local edgePos = util.getEdgeMidPoint(edgeId)
			local edgeToStationDist = util.distance(edgePos, station2Pos)
			if util.distance(edgePos, station1Pos) > distBetweenStations or edgeToStationDist  > distBetweenStations then 
				trace("Rejecting the edge",edgeId," because of distance",edgeToStationDist)
				return false
			end
			local maxDeltaZ = maxGradForStation*edgeToStationDist
			local deltaZ = math.abs(edgePos.z-station2Pos.z)
			if deltaZ > maxDeltaZ   then
				trace("Rejecting the edge",edgeId," because of deltaz ",deltaZ," exceeds  ",maxDeltaZ, " based on edgeToStationDist=",edgeToStationDist,"maxGrad =",maxGradForStation)
				return false 
			end 
			return isEdgeOk(edgeId) 
		end
		local begin = os.clock()
		local leftEdges = util.searchForFreeTrackEdges(station1SearchPoint, searchRadius2, edgeIsOkForStation1) 
		--local leftRouteLines = routeLineToEdges
	--	routeLineToEdges = {}
		--filterToDiscoveredEdges = true
		local rightEdges = util.searchForFreeTrackEdges(station2SearchPoint, searchRadius2, edgeIsOkForStation2)
		--local rightRouteLines = {}
		--[[local filteredLeftEdges = {} 
		for i, leftEdge in pairs(leftEdges) do 
			local routeLine = discoveredEdges[leftEdge]
			if rightHandRouteLines[routeLine] then 
				table.insert(filteredLeftEdges, leftEdge)
			end 
		end 
		
		trace("Found ",#leftEdges," and ",#rightEdges," filteredLeftEdges=",#filteredLeftEdges," time taken:",(os.clock()-begin))
		leftEdges = filteredLeftEdges]]--
		local edgePosLookup = {}
		local function getEdgeMidPoint(edgeId)
			if not edgePosLookup[edgeId] then 
				edgePosLookup[edgeId]= util.getEdgeMidPoint(edgeId)
			end
			return edgePosLookup[edgeId]
		end		
		local threasholdMaxEdges = 500  
		if #leftEdges > threasholdMaxEdges then 
			trace("A large number of left edges was found, reducing")
			leftEdges = util.evaluateAndSortFromSingleScore(leftEdges, function(edgeId) return util.distance(getEdgeMidPoint(edgeId), station1Pos) end,threasholdMaxEdges) 
		end  
		if #rightEdges > threasholdMaxEdges then 
			trace("A large number of right edges was found, reducing")
			rightEdges = util.evaluateAndSortFromSingleScore(rightEdges, function(edgeId) return util.distance(getEdgeMidPoint(edgeId), station2Pos) end,threasholdMaxEdges)  
		end  
		local begin = os.clock()
		local edgePairs = {} 
		
		
		local function checkVirtualLine(line1, line2)
			local line1Full = util.getLine(line1)
			local line2Full = util.getLine(line2)
			local hash = lineHash(line1, line2)
			if not virtualLinesByHash[hash] then -- performance optimisation, already worked out there is no overlap
				return 
			end 
			trace("Checking for virtual line with hash",hash,"lineIds",line1,line2)
			for i, stop in pairs(line1Full.stops) do 
				local station1 = util.stationFromStop(stop)
				for j, stop2 in pairs(line2Full.stops) do 
					local station2 = util.stationFromStop(stop2)
					local path1 = pathFindingUtil.findRailPathBetweenStations(station1, station2)
					local path2 = pathFindingUtil.findRailPathBetweenStations(station2, station1)
					for k, path in pairs({path1,path2}) do 
						for m, entity in pairs(path) do 
							if util.getEdge(entity.entity) then 
								if not allEdges[entity.entity] then 
									allEdges[entity.entity] = { hash} 
								else 
									table.insert(allEdges[entity.entity], hash) 
								end 
								if not edgesToLinesMap[entity.entity] then 
									edgesToLinesMap[entity.entity]={}
								end 
								edgesToLinesMap[entity.entity][hash]=true
								--trace("Found",entity.entity,"on virtual line with hash",hash,"lineIds",line1,line2)
							end 
						end  
					end 
					
				end 
			end 
			virtualLinesChecked[hash] = true 
		end 
		

		
		
		local function areEdgesConnectedWithPath(edgeId1, edgeId2) 
			if not allEdges[edgeId1] or not allEdges[edgeId2] then -- may happen with "inactive" edges like depot connections
				trace("WARNING! areEdgesConnectedWithPath, missing edge infor for",edgeId1,edgeId2)
				return false
			end 
			if checkIfEdgesShareLine(edgeId1, edgeId2) then 
				return true 
			end 
			for i, line in pairs(allEdges[edgeId1]) do 
				for j, line2 in pairs(allEdges[edgeId2]) do 
					local hash = lineHash(line, line2)
					if virtualLinesByHash[hash] then 
						 
						if not virtualLinesChecked[hash] then 
							checkVirtualLine(line, line2)
							if checkIfEdgesShareLine(edgeId1, edgeId2) then 
								trace("Initial check of whether edges was made true",edgeId1,edgeId2,"due to virtual line")
								return true 
							end 
						end 
					end 
	--				if linesOverlap[line] and linesOverlap[line][line2] then 
		--				if not 
			--		end 
				end 
			end 
			--trace("The edges",edgeId1,edgeId2,"were NOT connected with a line")
			return false 
		
			--[[if not pathEdges[edgeId1] or not pathEdges[edgeId2] then 
				return checkAndAddToRailPath(edgeId1, edgeId2) 
			end 
			for i, pathId1 in pairs(pathEdges[edgeId1])  do 
				for j, pathId2 in pairs(pathEdges[edgeId2]) do 
					if pathId1 == pathId2 then 
						cacheHits = cacheHits + 1
						return true 
					end
				end 
			end 
			return checkAndAddToRailPath(edgeId1, edgeId2) ]]--
		end 
		checkForPath = areEdgesConnectedWithPath
		for i, edgeId in pairs(leftEdges) do  
			local edgePos = getEdgeMidPoint(edgeId)
			for j, edgeId2 in pairs(rightEdges) do 
				
				local edge2Pos = getEdgeMidPoint(edgeId2)
				
				local edgeToEdgedDist = util.distance(edgePos, edge2Pos)
				local score2 = allEdges[edgeId] and #allEdges[edgeId] or 0 
				if allEdges[edgeId2] then 
					score2 = score2 + #allEdges[edgeId2]
				end 
				if edgeToEdgedDist > minSharedDist  -- avoid trivial distances
					and edgeToEdgedDist  < distBetweenStations and areEdgesConnectedWithPath(edgeId, edgeId2) then 
					table.insert(edgePairs, { 
						edgeId1 = edgeId, 
						edgeId2 = edgeId2 ,
						scores = { 1/edgeToEdgedDist, score2 } 
					})
				end
			end 
				
		end 
		edgePairs = util.evaluateAndSortFromScores(edgePairs)
		trace("CheckForIntermediateTrackRoute: Sorted into ",#edgePairs," edgePairs, time taken:",(os.clock()-begin))
		local begin = os.clock()
		-- performance optimisation, try to fast track to find connected edges by mapping them to computed paths 
		
		local cacheMisses = 0 
		local cacheHits = 0
		local checks = 0
		local noPathCacheHits = 0
		local function checkAndAddToRailPath(edgeId1, edgeId2) 
			if discoveredEdges[edgeId1] ~= discoveredEdges[edgeId2] then 
				noPathCacheHits = noPathCacheHits + 1
				return false
			end 
			local maxDistance = 3* util.distance(getEdgeMidPoint(edgeId1), getEdgeMidPoint(edgeId2))
			-- n.b. even if the edges are physically connected there may not be a path e.g. if connected by a junction the "wrong" way
			local path = pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edgeId1, edgeId2, maxDistance)
			if #path >0 then 
				nextPath = nextPath + 1 
				local foundEdgeId1 = false 
				local foundEdgeId2 = false 
				for i, entity in pairs(path) do 
					if not pathEdges[entity.entity] then 
						pathEdges[entity.entity]={}
					end 
					if entity.entity == edgeId1 then 
						foundEdgeId1 = true 
					end 
					if entity.entity == edgeId2 then 
						foundEdgeId2 = true 
					end
					table.insert(pathEdges[entity.entity], nextPath)
				end 
				if not foundEdgeId1 then 
					if not pathEdges[edgeId1] then 
						 pathEdges[edgeId1] = {}
					end 
					table.insert(pathEdges[edgeId1], nextPath)
				end
				if not foundEdgeId2 then 
					if not pathEdges[edgeId2] then 
						 pathEdges[edgeId2] = {}
					end 
					table.insert(pathEdges[edgeId2], nextPath)
				end
				cacheMisses = cacheMisses + 1
				return true
			else
				trace("NO path found between edges",edgeId1, edgeId2, " at distance",maxDistance)
				checks = checks + 1
				return false
			end
		end 

		
		local function isHelpfulTrackShare(edgeId1, edgeId2)
			local p1 = util.getEdgeMidPoint(edgeId1)
			local p2 = util.getEdgeMidPoint(edgeId2)
			local sharedVector = p2-p1
			local angle = math.abs(util.signedAngle(sharedVector ,vectorBetweenStations))
			if angle > math.rad(90) then 
				angle = math.rad(180) - angle
			end 
			if angle > math.rad(60) then 
				trace("isHelpfulTrackShare: Rejecting the option",edgeId1,edgeId2," based on the high intercept angle of ",math.deg(angle))
				return false 
			end 
			local totalBasicDist =  vec3.length(sharedVector) + util.distance(p1, station1Pos) + util.distance(p2, station2Pos)
			if totalBasicDist > 2*distBetweenStations then 
				trace("isHelpfulTrackShare: Rejecting the option",edgeId1,edgeId2," because the totalBasicDist",totalBasicDist," exceeds twice the distance between stations",distBetweenStations)
				return false 
			end 
			return true
		end 
		for i = 1, math.min(#edgePairs, 10000) do 
			local edgePair = edgePairs[i]
			local edgeId1 = edgePair.edgeId1 
			local edgeId2 = edgePair.edgeId2
			if not(uniquenessCheck[edgeId1] and uniquenessCheck[edgeId2]) and  areEdgesConnectedWithPath(edgeId1, edgeId2) and isHelpfulTrackShare(edgeId1, edgeId2) then
				if not uniquenessCheck[edgeId2] then 
					table.insert(rightConnectedEdges, edgeId2) 
					--table.insert(leftConnectedEdges, edgeId2) 						
					uniquenessCheck[edgeId2]=true 
				end
				if not uniquenessCheck[edgeId1] then 
					table.insert(leftConnectedEdges, edgeId1)
					--table.insert(rightConnectedEdges, edgeId) 						
					uniquenessCheck[edgeId1] =true
				end
				if not matchedPairs[edgeId1] then 
					matchedPairs[edgeId1]={}
				end 
				matchedPairs[edgeId1][edgeId2]=true
				if not matchedPairs[edgeId2] then 
					matchedPairs[edgeId2]={}
				end 
				matchedPairs[edgeId2][edgeId1]=true
			end
		end 
		
		
		pathFindingUtil.clearCaches() 
		trace("CheckForIntermediateTrackRoute: For the intermediate non station route there were ",#leftEdges," leftEdges and ",#rightEdges," rightEdges cacheHits:", cacheHits," cacheMisses:",cacheMisses," total checks:",checks," time taken:",(os.clock()-begin),"noPathCacheHits=",noPathCacheHits)
		local size = 0
		local totalSize = 0
		for edgeId, paths in pairs(pathEdges) do 
			size = size + 1 
			for i, path in pairs(paths) do 
				totalSize = totalSize + 1
			end 
		end 
		
		trace("The size of pathEdges was ",size," the total size",totalSize," an average of ",(totalSize/size))
		isIntermediateRoute = #leftConnectedEdges >0  and #rightConnectedEdges>0
		local alternativeLeftEdges = {}
		local alternativeRightEdges = {}
		for i , edge in pairs(util.combine(leftConnectedEdges, rightConnectedEdges)) do 
			if isStationConnectedToTrack(edge, station1) then 
				trace("WARNING! Found left connected edge",edge)
				table.insert(alternativeLeftEdges, edge)
			end 
			if isStationConnectedToTrack(edge, station2) then 
				trace("WARNING Found right connected edge",edge)
				table.insert(alternativeRightEdges, edge)
			end 
		end 
		if #alternativeLeftEdges > 0 or #alternativeRightEdges > 0 then 
			trace("Replacing the initial result")
			leftConnectedEdges = alternativeLeftEdges 
			rightConnectedEdges = alternativeRightEdges
			isIntermediateRoute = false
		end 
	end 
	profiler.endFunction("checkForIntermediateTrackRoute")
	trace("CheckForIntermediateTrackRoute: End of finding intermediate options, #leftConnectedEdges=",#leftConnectedEdges," #rightConnectedEdges=",#rightConnectedEdges, " total time taken=",(os.clock()-beginCheckForIntermediateTrackRoute))
	return { leftConnectedEdges= leftConnectedEdges, rightConnectedEdges = rightConnectedEdges, isIntermediateRoute = isIntermediateRoute, matchedPairs=matchedPairs, checkIfEdgesShareLine = checkForPath }
end

local function atLeastNoneOneHighwayEdge(node)
	 
	for i, seg in pairs(util.getStreetSegmentsForNode(node)) do 
		if util.getStreetTypeCategory(seg)~= "highway" then 
			return true  
		end 
	end 
	return false
end 

local function checkAndValidateRoadNode(node, vector) 
	local hasEntrance = false 
	for i, seg in pairs(util.getSegmentsForNode(node)) do 
		if util.getStreetTypeCategory(seg) == "entrance" then 
			hasEntrance = true 
		end 
	end 
	if hasEntrance and #util.getSegmentsForNode(node) > 1 then 
		local options = {}
		for i, otherNode in pairs(util.searchForDeadEndNodes(util.nodePos(node), 200)) do
			local roadPath = pathFindingUtil.findRoadPathBetweenNodes(node, otherNode)
			local hasPath = #roadPath > 0
			local deadEndDetails = util.getDeadEndNodeDetails(otherNode)
			local isOneWay = util.isOneWayStreet(deadEndDetails.edgeId)
			local angleToVector = math.abs(util.signedAngle(deadEndDetails.tangent, vector))
			trace("checkAndValidateRoadNode: inspecting",otherNode," as an alternative for ",node,"has path?",hasPath,"angleToVector=",math.deg(angleToVector),"isOneWay=",isOneWay)
			if hasPath and angleToVector < math.rad(90) and not isOneWay then 
				trace("Considering node",otherNode,"as an alternative to ",node)
				table.insert(options, {
					node = otherNode, 
					scores = {
						pathFindingUtil.getRouteInfoFromEdges(roadPath).routeLength, 
						angleToVector,
					}					
				})
			else 
				trace("NOT considering node",otherNode)
			end 
		end 
		trace("checkAndValidateRoadNode: got",#options,"options")
		if #options > 0 then 
			return util.evaluateWinnerFromScores(options).node
		end 
	end 
	

	return node
end 

local function validateRoadPair(nodePair)
	local leftNode = nodePair[1]
	local rightNode = nodePair[2]
	local vector = util.vecBetweenNodes(rightNode, leftNode )
	nodePair[1] = checkAndValidateRoadNode(leftNode, vector) 
	nodePair[2] = checkAndValidateRoadNode(rightNode, -1*vector)
	
	return nodePair 
end 

local function getAdjustedDistance(leftNodePos, rightNodePos, params)
	local distance = util.distance(leftNodePos, rightNodePos)
	local deltaz = math.abs(leftNodePos.z - rightNodePos.z)
	local adjustedDistance = math.max(distance, deltaz / params.absoluteMaxGradient)
	--trace("The adjustedDistance was",adjustedDistance,"distance was",distance)
	return adjustedDistance	
end 


function routeEvaluation.checkRoadRouteForShortCuts(routeInfo, params, stations)
	trace("checkRoadRouteForShortCuts: Begin evaluate road route for short cuts from",routeInfo.edges[routeInfo.firstFreeEdge].id,"to",routeInfo.edges[routeInfo.lastFreeEdge].id)
	local begin = os.clock()
	
	local urbanRoadPenaltyFactor = paramHelper.getParams().urbanRoadPenaltyFactor
	if not params.isCargo or stations and util.isTruckStop(stations[2]) then 
		urbanRoadPenaltyFactor = 1
	end
	local highwayRoadBonusFactor = paramHelper.getParams().highwayRoadBonusFactor
	local truckRouteToDistanceLimit = paramHelper.getParams().truckRouteToDistanceLimit
	local startPos = util.getEdgeMidPoint(routeInfo.edges[routeInfo.firstFreeEdge].id)
	local endPos = util.getEdgeMidPoint(routeInfo.edges[routeInfo.lastFreeEdge].id)
	local straightDist = getAdjustedDistance(startPos, endPos, params)
	if not params.isCargo or stations and util.isTruckStop(stations[2]) then 
		routeInfo.routeLength = routeInfo.actualRouteLength 
	end
	local shortCutThreashold =  math.min(truckRouteToDistanceLimit, params.roadRouteShortCutThreashold)
		trace("Checking road route for short cuts, iteration ",params.shortCutIterations," the base route length was ", routeInfo.routeLength, " the straight distance was ",straightDist )
	if  routeInfo.routeLength / straightDist <= params.assumedRouteLengthToDist then 
		trace("Skipping short cut checks as the route appears to be short")
		return 
	end
	if params.shortCutIterations > 5 then 
		trace("Short cut iteration limit reached, aborting")
		return 
	end 
	util.lazyCacheNode2SegMaps()
	params.shortCutIterations = params.shortCutIterations+1
	local routeAndDirectionData = routeInfo.getDirectionAndRouteData() 
	local maxAngleCategory = routeAndDirectionData.maxAngleCategory
	local minAngleCategory = routeAndDirectionData.minAngleCategory
	trace("checkRoadRouteForShortCuts: got routeAndDirectionData, maxAngleCategory=",maxAngleCategory,"minAngleCategory=",minAngleCategory)
	if maxAngleCategory > 0 and minAngleCategory < 0 then 
		local beginAngleBasedShortCuts= os.clock()
		local routeNodes = routeAndDirectionData.routeNodes
		local nodesByAngleCategory = routeAndDirectionData.nodesByAngleCategory

		local maxAbsAngleCategory = routeAndDirectionData.maxAbsAngleCategory
		local mapByNode = {}
		for i, routeNode in pairs(routeNodes) do 
			mapByNode[routeNode.node]=routeNode
		end 
		trace("Found a route with opposing angle categories, inspecting, maxAngleCategory=",maxAngleCategory, " minAngleCategory=",minAngleCategory,"maxAbsAngleCategory=",maxAbsAngleCategory)
		local leftNodes = nodesByAngleCategory[maxAngleCategory]  -- NB. "left" and "right" are just convenient labels here, don't actually refer to handedness
		local rightNodes = nodesByAngleCategory[minAngleCategory]
		trace("Initial Count leftnodes was ",#leftNodes, " count rightnodes was ",#rightNodes)
		if maxAngleCategory > 1 then 
			leftNodes = util.combine(leftNodes, nodesByAngleCategory[maxAngleCategory-1] )
		end 
		if minAngleCategory < -1 then 
			rightNodes = util.combine(rightNodes, nodesByAngleCategory[minAngleCategory+1] )
		end 
		trace("Count leftnodes was ",#leftNodes, " count rightnodes was ",#rightNodes," after combination")
		local alreadySeen = {}
		local minLeftIdx =math.huge
		local maxLeftIdx = 0
		for i =1 , #leftNodes do 
			local leftNodeDetails = leftNodes[i]
			minLeftIdx = math.min(minLeftIdx, leftNodeDetails.edgeIdx)
			maxLeftIdx = math.max(maxLeftIdx, leftNodeDetails.edgeIdx)
			alreadySeen[leftNodeDetails.node]=true 
			local edge =leftNodeDetails.edge 
			for j, otherNode in pairs({edge.node0, edge.node1}) do 
				if not alreadySeen[otherNode] then 
					trace("inserting ",otherNode,"for consideration on leftnodess")
					table.insert(leftNodes, mapByNode[otherNode])
					alreadySeen[otherNode]=true
				end 
			end 
		end
		
		
		local alreadySeen = {}
		local maxRightIdx =0
		local minRightIdx = math.huge
		for i =1 , #rightNodes do 
			local rightNodeDetails = rightNodes[i]
			alreadySeen[rightNodeDetails.node]=true 
			local edge =rightNodeDetails.edge 
			maxRightIdx = math.max(maxRightIdx, rightNodeDetails.edgeIdx)
			minRightIdx = math.min(minRightIdx, rightNodeDetails.edgeIdx)
			for j, otherNode in pairs({edge.node0, edge.node1}) do 
				if not alreadySeen[otherNode] then 
					trace("inserting ",otherNode,"for consideration on leftnodess")
					table.insert(rightNodes, mapByNode[otherNode])
					alreadySeen[otherNode]=true
				end 
			end 
		end
			trace("Count leftnodes was ",#leftNodes, " count rightnodes was ",#rightNodes,"after consideration1")		
		if #leftNodes > 0 then 
		
			local startAt = minLeftIdx < minRightIdx and 1 or maxLeftIdx 
			local endAt = minLeftIdx < minRightIdx and minLeftIdx or #routeNodes  
			trace("Considering also for the minLeftIdx=",minLeftIdx," startAt=",startAt,"endAt=",endAt)
			for i=startAt, endAt do
				local routeNode = routeNodes[i]
				if routeNode.sharpAngleChange and #util.getSegmentsForNode(routeNode.node) == 3 then 
					trace("Adding node",routeNode.node," on the left for consideration due to sharp angle")
					table.insert(leftNodes, routeNode)
				end 
			end			
		end 
		
		if #rightNodes > 0 then 
			trace("Considering also for the right=",maxRightIdx)
			local startAt = minLeftIdx > minRightIdx and 1 or maxRightIdx 
			local endAt = minLeftIdx > minRightIdx and minRightIdx or #routeNodes  
			trace("Considering also for the minLeftIdx=",minLeftIdx," startAt=",startAt,"endAt=",endAt)
			for i=startAt, endAt do
				local routeNode = routeNodes[i]
				if routeNode.sharpAngleChange and #util.getSegmentsForNode(routeNode.node) == 3 then 
					trace("Adding node",routeNode.node," on the right for consideration due to sharp angle")
					table.insert(rightNodes, routeNode)
				end 
			end			
		end
		trace("Count leftnodes was ",#leftNodes, " count rightnodes was ",#rightNodes,"after consideration2")		
	    --[[local nodeDetails = {
					tangent = directionalTangent,
					node = currentNode,
					nodePos = nodePos,
					angleToPrior = angleToPrior,
					angleToRouteVector = angleToRouteVector,
					distanceToEnd = distanceToEnd,
					distanceToStart = distanceToStart,
					routeLengthFromStart = routeLengthFromStart,
					routeLengthFromEnd = routeLengthFromEnd
				}]]--
		local options = {}
		
		leftNodes = util.copyTableWithFilter(leftNodes, util.notFn(shouldRejectNode))
		rightNodes = util.copyTableWithFilter(rightNodes, util.notFn(shouldRejectNode))
		trace("Count leftnodes was ",#leftNodes, " count rightnodes was ",#rightNodes,"after filtering")		
		for i, leftNodeDetails in pairs(leftNodes) do 
			for j, rightNodeDetails in pairs(rightNodes) do 
				local leftNode = leftNodeDetails.node 
				local rightNode = rightNodeDetails.node 
				--assert(leftNode~=rightNode, " identical nodes "..leftNode.." and "..rightNode.." maxAngleCategory="..maxAngleCategory.." minAngleCategory="..minAngleCategory)
				local leftNodePos = leftNodeDetails.nodePos 
				local rightNodePos = rightNodeDetails.nodePos 
				local shortCutVector = rightNodePos - leftNodePos 
				local distance = getAdjustedDistance(leftNodePos, rightNodePos, params)
				local routeDistance = math.abs(leftNodeDetails.routeLengthFromStart-rightNodeDetails.routeLengthFromStart)
				local routeDistanceReduction = routeDistance - distance 
				local routeDistanceFactor = distance / routeDistanceReduction
				local combinedAngle = leftNodeDetails.angleToRouteVector + rightNodeDetails.angleToRouteVector -- one is positive, other negative, should cancel 
				local canAccept = true --not shouldRejectNode(leftNode) and not shouldRejectNode(rightNode)
				if leftNode == rightNode then -- can happen at a junction turn 
					canAccept = false 
				end 
				if #util.getSegmentsForNode(leftNode) == 3 then 
					local tangent = util.getOutboundNodeDetailsForTJunction(leftNode).tangent
					local angle = math.abs(util.signedAngle(tangent, shortCutVector))
					trace("Inspecting ",leftNode," which is a T-junction, for joining with",rightNode, " angle was",math.deg(angle))
					if angle > math.rad(90) then 
						trace("Rejecting the node",leftNode," based on angle")
						canAccept = false 
					end 
				end 
				if #util.getSegmentsForNode(rightNode) == 3 then 
					local tangent = util.getOutboundNodeDetailsForTJunction(rightNode).tangent
					local angle = math.abs(util.signedAngle(tangent, -1* shortCutVector)) -- note we need to invert the shortCutVector here
					trace("Inspecting ",rightNode," which is a T-junction, for joining with",leftNode, " angle was",math.deg(angle))
					if angle > math.rad(90) then 
						trace("Rejecting the node",rightNode," based on angle")
						canAccept = false 
					end 
				end 
				if math.abs(util.calculateGradient(leftNodePos, rightNodePos)) > params.maxGradient then 
					trace("rejecting the node pair", leftNode,rightNode," as the gradient",util.calculateGradient(leftNodePos, rightNodePos), "exceeds max gradient",params.maxGradient)
					canAccept = false 
				end 
				if routeDistanceReduction < 0 then -- shouldnt really be possible, means something went wrong in calculations
					trace("WARNING! routeDistanceReduction was negative, rejecting")
					canAccept = false -- reject as cannot be valid result
				end
				local routeLengthToDist = routeDistance / distance 
				if routeLengthToDist < 1.5 then 	
					trace("Rejecting based on short potential saving", routeLengthToDist)
					canAccept = false 
				end
				local nearbyRailStation1 =  util.searchForFirstEntity(leftNodePos, 100, "STATION", function(entity) return entity.carriers.RAIL end)
				local nearbyRailStation2 =  util.searchForFirstEntity(rightNodePos, 100, "STATION", function(entity) return entity.carriers.RAIL end)
				if nearbyRailStation1 and nearbyRailStation2 and nearbyRailStation1.id == nearbyRailStation2.id then 
					trace("Dicovered attempting to shortcut underpass, aborting")
					canAccept = false 
				end 
				if not (atLeastNoneOneHighwayEdge(leftNode) and atLeastNoneOneHighwayEdge(rightNode)) then 
					canAccept = false 
				end
				trace("Considering node pair", leftNode,rightNode," canAccept?",canAccept," routeDistance=",routeDistance," distance=",distance,"routeDistanceReduction=",routeDistanceReduction,"combinedAngle=",math.deg(combinedAngle), "routeDistanceFactor=",routeDistanceFactor )
				if canAccept then 
					table.insert(options, { 
						nodePair = { leftNode, rightNode}, 
						routeDistanceFactor = routeDistanceFactor,
						scores = { 
							1/routeDistanceReduction, 
							combinedAngle,
							routeDistanceFactor,
							math.abs(leftNodeDetails.angleToPrior),
							math.abs(rightNodeDetails.angleToPrior),
							routeEvaluation.scoreDeadEndNode(leftNode, rightNodePos),
							routeEvaluation.scoreDeadEndNode(rightNode, leftNodePos),
							util.scoreTerrainBetweenPoints(leftNodePos, rightNodePos),
							util.scoreWaterBetweenPoints(leftNodePos, rightNodePos),
						}
					})
				end
			end 
		end 
		trace("AngleBasedShortCuts: got ",#options," time taken",(os.clock()-beginAngleBasedShortCuts))
		if #options > 0 then 
			local weights = {
				100, -- routeDistanceReduction, 
				25, --combinedAngle,
				25, -- routeDistanceFactor,
				25, --math.abs(leftNodeDetails.angleToPrior),
				25, --math.abs(rightNodeDetails.angleToPrior),
				25, -- 	routeEvaluation.scoreDeadEndNode(leftNode, rightNodePos),
				25, --	routeEvaluation.scoreDeadEndNode(rightNode, leftNodePos),
				10, --	util.scoreTerrainBetweenPoints(leftNodePos, rightNodePos),
				10, --	util.scoreWaterBetweenPoints(leftNodePos, rightNodePos) 
			}
			local best = util.evaluateWinnerFromScores(options,weights)
			if not best then 
				trace("WARNING! NAN was likely found")
				debugPrint(options)
				return
			end 
			if util.tracelog and #options < 20 then 
				debugPrint({angleBasedShortCutOptions=options})
			end 
			trace("AngleBasedShortCuts, the best option was", best.nodePair[1],best.nodePair[2])
			return validateRoadPair(best.nodePair)
		end 
	end 

	if routeInfo.routeLength > 10000 then  -- takes excessive amount of time.
		trace("Skipping shortcut checks as route length is too high")
		return
	end 
	
	local alreadyChecked = {}
	local function calculateRouteLength(from, to, startNode, endNode) 
		local routeLength = 0
		-- do not include first / last edges if the node actually lies on the intermediate edge
		local edgeAfterFirst = routeInfo.edges[from+1] and routeInfo.edges[from+1].edge  
		if edgeAfterFirst and (edgeAfterFirst.node0 == startNode or edgeAfterFirst.node1 == startNode) then 
			from = from + 1 
		end
		
		local edgeBeforeLast = routeInfo.edges[to-1] and routeInfo.edges[to-1].edge  
		if edgeBeforeLast and (edgeBeforeLast.node0 == endNode or edgeBeforeLast.node1 == endNode) then 
			to = to - 1 
		end
		local trueRouteLength = 0
		for i = from , to do 
			local  edge = routeInfo.edges[i].edge
			local edgeLength = util.calculateSegmentLengthFromEdge(edge)
			trueRouteLength = trueRouteLength + edgeLength
			local streetCategory = util.getStreetTypeCategory(routeInfo.edges[i].id)
			if streetCategory == "urban" and routeInfo.edges[i].edge.type == 0 then 
				edgeLength = edgeLength * urbanRoadPenaltyFactor
			elseif streetCategory == "highway" then 
				edgeLength = edgeLength * highwayRoadBonusFactor
			end	
			routeLength = routeLength + edgeLength
		end
		if trueRouteLength < 300 then -- need to avoid nonsensicle short cuts to avoid urban areas
			trace("Using the trueRouteLength ",trueRouteLength,"rather than the applied bonuses",routeLength)
			return trueRouteLength
		end 
		return routeLength
	end
	local function isEdgeOk(i)
		if not i then return true end
		return util.getStreetTypeCategory(routeInfo.edges[i].id)=="country" 
		and (not util.isIndustryEdge(routeInfo.edges[i].id)
		or util.isDeadEndNode(routeInfo.edges[i].edge.node0) 
		or util.isDeadEndNode(routeInfo.edges[i].edge.node1))
	end
	local isNodeOkCache = {}
	local isNodeOkChecked = {}
	local function isNodeOk(node)  
		if isNodeOkChecked[node] then -- performance optimisation
			return isNodeOkCache[node]
		end
		isNodeOkChecked[node] = true
		if #util.getSegmentsForNode(node) > 3 then 
			return false
		end 
		if #util.getTrackSegmentsForNode(node) > 0 then 
			return false
		end
		local atLeastOneCountry = false 
		for i , seg in pairs(util.getStreetSegmentsForNode(node)) do 
			if util.isIndustryEdge(seg) then 
				if not util.isDeadEndNode(node) then 
					return false 
				end
			end
			if util.isFrozenEdge(seg) then 
				return false 
			end
			if util.getStreetTypeCategory(seg) == "country" then 
				atLeastOneCountry = true 
			end
		end
		if not atLeastOneCountry  then 
			if util.isDeadEndNode(node) then 
				if util.searchForNearestNode(util.nodePos(node), 50, function(otherNode) return otherNode.id ~= node end) then 
					return false 
				end
				if util.searchForFirstEntity(util.nodePos(node), 200, "TOWN") then 
					return false 
				end
			else 
				return false 
			end
		end
		isNodeOkCache[node]=true
		return true
	end
	local connectedNodes = {}
	local allRouteEdges = {}
	for i =1, #routeInfo.edges do 	
		allRouteEdges[routeInfo.edges[i].id]=i
	end
	local nodeLookupIndex = {}
	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 	
		for j, node in pairs( { routeInfo.edges[i].edge.node0, routeInfo.edges[i].edge.node1}) do 
			if not nodeLookupIndex[node] then 
				nodeLookupIndex[node]=i  
			end 
			local segs = util.getStreetSegmentsForNode(node)
			for	k, seg in pairs(segs) do 
				if not allRouteEdges[seg] then 
					local edge = util.getEdge(seg)
					if not edge then 
						trace("WARNING! No edge found for ",seg,"from node",node)
					else
						connectedNodes[edge.node0]=true
						connectedNodes[edge.node1]=true
					end
				end
			end 
		end
	end 
	if util.tracelog then debugPrint(connectedNodes) end
		
	local startEdge = routeInfo.edges[1].edge
	local startNode = util.isStationNode(startEdge.node0) and startEdge.node0 or startEdge.node1
	local startNodePos = util.nodePos(startNode)
	local endEdge = routeInfo.edges[#routeInfo.edges].edge
	local endNode = util.isStationNode(endEdge.node0) and endEdge.node0 or endEdge.node1
	local endNodePos = util.nodePos(endNode)
	local leftConnectedNodes = {} 
	local rightConnectedNodes = {}
	local matchedPairs = {}
	local stationVector = endNodePos - startNodePos
	local searchRadius = vec3.length(stationVector)/4
	local posOffset = vec3.length(stationVector)/3
	local station1SearchPoint = startNodePos + posOffset*vec3.normalize(stationVector)
	local station2SearchPoint = endNodePos - posOffset*vec3.normalize(stationVector)
	local station1DeadEndNode = util.searchForClosestDeadEndNode(startNodePos, 150)
	local recalculatedRouteLength = calculateRouteLength(1, #routeInfo.edges, startNode, endNode) 
	trace("The recalculatedRouteLength was ",recalculatedRouteLength," compared to ", routeInfo.routeLength)
	if not station1DeadEndNode then 
		station1DeadEndNode = util.searchForClosestDeadEndNode(startNodePos, 150,  true)
	end 
	local station2DeadEndNode = util.searchForClosestDeadEndNode(endNodePos, 150)
	if not station2DeadEndNode then 
		station2DeadEndNode = util.searchForClosestDeadEndNode(endNodePos, 150,  true)
	end
	if station1DeadEndNode and util.getStreetTypeCategory(util.getDeadEndNodeDetails(station1DeadEndNode).edgeId) == "urban" and connectedNodes[station1DeadEndNode] then 
		station1DeadEndNode = nil 
	end
	if station2DeadEndNode and util.getStreetTypeCategory(util.getDeadEndNodeDetails(station2DeadEndNode).edgeId) == "urban" and connectedNodes[station2DeadEndNode] then 
		station2DeadEndNode = nil 
	end
	
	trace("Found station1DeadEndNode? ",station1DeadEndNode, " station2DeadEndNode= ",station2DeadEndNode)
	local nodeInfo = {}
	for i, node in pairs(util.searchForDeadEndOrCountryNodes(station1SearchPoint, searchRadius)) do
		if nodeLookupIndex[node] or not isNodeOk(node) or connectedNodes[node] then
			goto continue
		end
		local leftRoute = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(startNode, node) 
		if leftRoute and not leftRoute.exceedsRouteToDistLimitForTrucks and 
			(util.distBetweenNodes(node,startNode) > 200 or util.isDeadEndNode(node)) then 
			table.insert(leftConnectedNodes, node)
			nodeInfo[node] = {}
			nodeInfo[node].leftRoute = leftRoute
			nodeInfo[node].deadEndScoreL = routeEvaluation.scoreDeadEndNode(node, startNodePos)
			nodeInfo[node].nearbyConstructions = util.countNearbyEntities(util.nodePos(node), 100, "CONSTRUCTION")
		end
		::continue::
	end
	for i, node in pairs(util.searchForDeadEndOrCountryNodes(station2SearchPoint, searchRadius)) do
		if nodeLookupIndex[node] or not isNodeOk(node) or connectedNodes[node] then
			goto continue
		end 
		local rightRoute = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(node, endNode)
		if rightRoute and not rightRoute.exceedsRouteToDistLimitForTrucks and (util.distBetweenNodes(node,endNode) > 200 or util.isDeadEndNode(node)) then 
			table.insert(rightConnectedNodes, node)
			if not nodeInfo[node] then 
				nodeInfo[node] = {}
			end
			nodeInfo[node].rightRoute = rightRoute
			nodeInfo[node].deadEndScoreR = routeEvaluation.scoreDeadEndNode(node, endNodePos)
			nodeInfo[node].nearbyConstructions = util.countNearbyEntities(util.nodePos(node), 100, "CONSTRUCTION")
		end
		::continue::
	end
	local options = {}
	
	
	local shortCutIndexes = {} 
	shortCutIndexes[routeInfo.firstFreeEdge] = true 
	shortCutIndexes[routeInfo.lastFreeEdge]=true
	local lastShortCutIdx = routeInfo.lastFreeEdge
	for i = routeInfo.firstFreeEdge+1, routeInfo.lastFreeEdge-1 do 
		local node0 = routeInfo.edges[i].edge.node0
		local node1 = routeInfo.edges[i].edge.node1
		local t0 = routeInfo.edges[i].edge.tangent0 
		local t1 = routeInfo.edges[i].edge.tangent1
		if (#util.getStreetSegmentsForNode(node0) == 3
			or util.isDeadEndNode(node0, true)
			or #util.getStreetSegmentsForNode(node1) == 3
			or util.isDeadEndNode(node1, true)
			or util.isCornerNode(node0)
			or util.isCornerNode(node1)
			or routeInfo.edges[i-2] and util.getStreetTypeCategory(routeInfo.edges[i-2].id) == "urban"
			or routeInfo.edges[i-1] and util.getStreetTypeCategory(routeInfo.edges[i-1].id) == "urban"
			or routeInfo.edges[i+1] and util.getStreetTypeCategory(routeInfo.edges[i+1].id) == "urban"
			or routeInfo.edges[i+2] and util.getStreetTypeCategory(routeInfo.edges[i+2].id) == "urban"
			or math.abs(util.signedAngle(t0, t1)) > math.rad(30))
			and isEdgeOk(i)
		then 
			shortCutIndexes[i] = true 
			local edgesSincePrior = i - lastShortCutIdx
			trace("Adding short cut  index at i=",i, " edgeid = ",routeInfo.edges[i].id, "edges from prior shortcut=",edgesSincePrior)
			-- balance between having more edges to inspect giving better shortcuts and performance
			if edgesSincePrior > 12 then 
				for j = lastShortCutIdx+ 6, i-6, 6 do 
					if isEdgeOk(j) then 
						trace("Adding extra short cut index at i = ",j, " edgeId=",routeInfo.edges[j].id)
						shortCutIndexes[j] = true
					end
				end
				 
			elseif edgesSincePrior > 6 then 
				local additionalIdx = math.floor((i+lastShortCutIdx)/2)
				if isEdgeOk(additionalIdx) then 
					trace("Adding extra short cut index at i = ",additionalIdx, " edgeId=",routeInfo.edges[additionalIdx].id)
					shortCutIndexes[additionalIdx] = true
				end
			end
			lastShortCutIdx = i
		end 
	end
	local countShortCutsConsidered = 0
	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		if countShortCutsConsidered > 1000 then 
			break 
		end 
		if not shortCutIndexes[i] then 
			goto continue 
		end
		local nodesToInspect = {routeInfo.edges[i].edge.node0,routeInfo.edges[i].edge.node1}
		if i == routeInfo.firstFreeEdge then 
			table.insert(nodesToInspect, station1DeadEndNode)
		end
		if i == routeInfo.lastFreeEdge then 
			table.insert(nodesToInspect, station2DeadEndNode)
		end
		
		for __, node in pairs(nodesToInspect) do 
			if not alreadyChecked[node] and isNodeOk(node) then 
				trace("Inspecting node ", node, " for possible shortcut")
				alreadyChecked[node] = true
				
				for i, seg in pairs(util.getStreetSegmentsForNode(node)) do 
					if util.isIndustryEdge(seg) then 
						goto continue 
					end
				end
				
				local nodePos = util.nodePos(node)
				local routeLengthFromStart = calculateRouteLength(routeInfo.firstFreeEdge, i, startNode, node)
				local routeLengthFromEnd = calculateRouteLength(i,routeInfo.lastFreeEdge, node, endNode)
				local distFromStart = getAdjustedDistance(startPos, nodePos, params) 
				local nodesFromStart = {}
				
				if i > routeInfo.firstFreeEdge+6 and (routeLengthFromStart/distFromStart) > shortCutThreashold then 
					for j = i-5, routeInfo.firstFreeEdge+1, -1 do
						if shortCutIndexes[j] then 
							for __, otherNode in pairs({ routeInfo.edges[j].edge.node0 , routeInfo.edges[j].edge.node1}) do 
								if isNodeOk(otherNode) then 
									table.insert(nodesFromStart, otherNode)
								end
							end
						end
					end
				
				
					for __, otherNode in pairs(util.combine(nodesFromStart, leftConnectedNodes)) do  
						 
						local distToBuild = getAdjustedDistance(util.nodePos(otherNode), nodePos, params) *params.assumedRouteLengthToDist
						local totalRouteLength = distToBuild + routeLengthFromEnd
						local idx = nodeLookupIndex[otherNode]
						local routeLengthSkipped
						local existingOtherRouteLength
						local routeLengthToAdd
						local isOk = distToBuild > 0 and not util.findEdgeConnectingNodes(node, otherNode)
						if isOk and idx then  
							routeLengthToAdd = calculateRouteLength(routeInfo.firstFreeEdge, idx, startNode, otherNode)
							routeLengthSkipped = calculateRouteLength(idx, i, otherNode, node) 
							isOk = isEdgeOk(idx) and routeLengthSkipped/distToBuild > shortCutThreashold
							
						elseif isOk then 
							routeLengthToAdd =  nodeInfo[otherNode].leftRoute.routeLength
							local routeInfo = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(node, otherNode)
							if routeInfo then 
								existingOtherRouteLength = routeInfo.routeLength
								isOk = existingOtherRouteLength / distToBuild > shortCutThreashold
							end
						end
						
						if isOk  then 
							totalRouteLength = totalRouteLength + routeLengthToAdd
							if  totalRouteLength > recalculatedRouteLength then
								trace("Rejected option ",node, otherNode," because it would increase the length", totalRouteLength, recalculatedRouteLength)
								isOk = false
							end
						else 
							trace("Rejected option ",node, otherNode," routeLengthSkipped = ",routeLengthSkipped, " distToBuild=",distToBuild,"existingOtherRouteLength=",existingOtherRouteLength,"distToBuild=",distToBuild,"shortCutThreashold=",shortCutThreashold)
						end 
						if isOk and math.abs(util.calculateGradient(util.nodePos(otherNode), nodePos)) > params.maxGradient then 
							trace("rejecting the node pair", node, otherNode," as the gradient exceeds max gradient",params.maxGradient)
							isOk = false 
						end 
						countShortCutsConsidered = countShortCutsConsidered + 1
						local routeLengthReduction = recalculatedRouteLength-totalRouteLength
						if isOk then 
							local p0 = util.nodePos(node) 
							local p1 = util.nodePos(otherNode)
							table.insert(options, {
								nodePair = { node, otherNode },
								priorRouteNode = true, 
								routeLengthSkipped =routeLengthSkipped,
								distToBuild = distToBuild,
								routeLengthReduction=routeLengthReduction,
								totalRouteLength = totalRouteLength,
								existingOtherRouteLength= existingOtherRouteLength,
								distanceReduction = distanceReduction,
								routeLengthFromStart= routeLengthFromStart,
								routeLengthFromEnd = routeLengthFromEnd,
								routeLengthToAdd = routeLengthToAdd,
								scores = { 
									totalRouteLength,
									distToBuild,
									routeEvaluation.scoreDeadEndNode(node, util.nodePos(otherNode)),
									routeEvaluation.scoreDeadEndNode(otherNode, util.nodePos(node)),
									util.scoreTerrainBetweenPoints(p0, p1),
									util.scoreWaterBetweenPoints(p0, p1),
								}
							})
						end 
						if countShortCutsConsidered > 1000 then 
							break 
						end
					end
				end
				local nodesFromEnd = {}
				
				
				local distToEnd = getAdjustedDistance(endPos, nodePos, params)
				if i <  routeInfo.lastFreeEdge -6 and (routeLengthFromEnd/distToEnd) > shortCutThreashold then 
					for j = i+5, routeInfo.lastFreeEdge-1 do
						if shortCutIndexes[j] then 
							for __, otherNode in pairs({ routeInfo.edges[j].edge.node0 , routeInfo.edges[j].edge.node1}) do 
								if isNodeOk(otherNode) then 
									table.insert(nodesFromEnd, otherNode)
								end
							end
						end
					end
				
					for __, otherNode in pairs(util.combine(nodesFromEnd, rightConnectedNodes)) do 
						local distToBuild = getAdjustedDistance(util.nodePos(otherNode), nodePos,params)*params.assumedRouteLengthToDist
						local totalRouteLength = routeLengthFromStart + distToBuild
						local idx = nodeLookupIndex[otherNode]
						local routeLengthSkipped
						local existingOtherRouteLength
						local routeLengthToAdd
						local isOk = distToBuild > 0 and not util.findEdgeConnectingNodes(node, otherNode)
						if isOk and idx then 
							routeLengthToAdd =  calculateRouteLength(idx, routeInfo.lastFreeEdge, otherNode, endNode) 
							routeLengthSkipped = calculateRouteLength(i, idx, node, otherNode)  
							isOk = isEdgeOk(idx) and routeLengthSkipped/distToBuild > shortCutThreashold
						elseif isOk then 
							routeLengthToAdd = nodeInfo[otherNode].rightRoute.routeLength
							local routeInfo = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(node, otherNode)
							if routeInfo then 
								existingOtherRouteLength = routeInfo.routeLength
								isOk = existingOtherRouteLength / distToBuild > shortCutThreashold
							end
						end
						
						if isOk then
							totalRouteLength = totalRouteLength+routeLengthToAdd
							if  totalRouteLength > recalculatedRouteLength then 
								trace("Rejected option ",node, otherNode," because it would increase the length", totalRouteLength, recalculatedRouteLength)
								isOk = false
							end
						else 
							trace("Rejected option ",node, otherNode," routeLengthSkipped = ",routeLengthSkipped, " distToBuild=",distToBuild)
						end
						if isOk and math.abs(util.calculateGradient(util.nodePos(otherNode), nodePos)) > params.maxGradient then 
							trace("rejecting the node pair", node, otherNode," as the gradient exceeds max gradient",params.maxGradient)
							isOk = false 
						end 
						countShortCutsConsidered = countShortCutsConsidered + 1
						local routeLengthReduction = recalculatedRouteLength-totalRouteLength
						if isOk then 
							local p0 = util.nodePos(node) 
							local p1 = util.nodePos(otherNode)
							table.insert(options, {
								nodePair = { node, otherNode },
								priorRouteNode = false,
								routeLengthReduction = routeLengthReduction,
								routeLengthSkipped =routeLengthSkipped,
								routeLengthFromEnd = routeLengthFromEnd,
								routeLengthFromStart = routeLengthFromStart,
								totalRouteLength = totalRouteLength,
								distToBuild = distToBuild,
								existingOtherRouteLength = existingOtherRouteLength,
								distanceReduction = distanceReduction,
								routeLengthToAdd= routeLengthToAdd,
								scores = { 
									totalRouteLength,
									distToBuild,
									routeEvaluation.scoreDeadEndNode(node, util.nodePos(otherNode)),
									routeEvaluation.scoreDeadEndNode(otherNode, util.nodePos(node)),
									util.scoreTerrainBetweenPoints(p0, p1),
									util.scoreWaterBetweenPoints(p0, p1),
								}
							})
						end
						if countShortCutsConsidered > 1000 then 
							break 
						end 
					end
					trace("DistTostart=",distFromStart," routeLengthFromStart=",routeLengthFromStart," distToEnd=",distToEnd,"routeLengthFromEnd=",routeLengthFromEnd,"i=",i," of ",routeInfo.lastFreeEdge-routeInfo.firstFreeEdge)
					
				end
			end
			
		end
		if (os.clock()-begin) > 30 then 
			trace("Aborting short cut check after taking more than 30 seconds")
			break
		end 
		::continue::
		
	end
	trace("After checking route for shortcuts there were ",#options," options. Time taken:",(os.clock()-begin), " original route length was ",routeInfo.routeLength,"countShortCutsConsidered =", countShortCutsConsidered)
	if #options == 0 then 
		return 
	end 
	if #options <20 and util.tracelog then 
		debugPrint(options) 
	end 
--	debugPrint(options) 
	local begin = os.clock()
	local result =  util.evaluateWinnerFromScores(options, {
		75, -- totalRouteLength
		25, -- distToBuild
		25, -- deadEndScore0
		25, -- deadEndScore1
		50,-- terrain score 
		100, -- water score
	}).nodePair
	trace("Evaluated short cuts winner after ",(os.clock()-begin),"result was",result[1],result[2])
	return result
	
end 
return routeEvaluation