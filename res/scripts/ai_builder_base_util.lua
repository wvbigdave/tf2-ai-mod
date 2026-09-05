local vec3 = require("vec3")
local vec2 = require("vec2")
local waterMeshUtil = require "ai_builder_water_mesh_util"
local socket_manager = require "socket_manager"
local util = {}
util.socket = socket_manager

-- DISABLED: Auto-connect was causing tight loop
-- Auto-connect on load
--[[
if not _G.tf2_socket_connected then
    local debugFile = io.open("native_socket_debug.txt", "a")
    if debugFile then debugFile:write("Base util loaded (Bridge Mode)\n") debugFile:close() end

    print("[AUTO] Connecting via Pipe Bridge...")
    -- in bridge mode, connect is dummy but good for consistency
    local s = util.socket.connect("127.0.0.1", 12345)

    if s then
        util.socket.send(s, "[AUTO] Hello from Pipe Bridge!")
        if debugFile then
            debugFile = io.open("native_socket_debug.txt", "a")
            debugFile:write("Bridge Send Called\n") 
            debugFile:close() 
        end
        print("[AUTO] Sent greeting via bridge.")
        _G.tf2_socket_connected = true
    end
end
--]]

local trackWidth = 5
local targetSegmentLength = 90
local useHermiteSolution = true
local tracelog = false  -- DISABLED - was causing early return in tickUpdate
local useTPFTangentCalculation = true
local alwaysCorrectTangentLengths = true 
util.alwaysCorrectTangentLengths = alwaysCorrectTangentLengths
util.tracelog = tracelog

local lastLogTime 
local lastTimestamp
util.trace = function(...)
	if tracelog then 
	
		if lastLogTime ~= os.time() then 
			lastTimestamp = os.date("%H:%M:%S")
			lastLogTime = os.clock()
		end 
		local timestamp  = lastTimestamp
		
		print(timestamp,...)
	end
end
waterMeshUtil.tracelog = tracelog
local trace = util.trace
util.size = function(tab) -- because #tab gives "undefined" results for associative arrays !!!
	local s = 0
	for k,v in pairs(tab) do
		s = s+1
	end
	return s
end
function util.formatTime(t) 
	t = math.floor(t)
	if t < 60 then 
		return tostring(t).." s"
	end
	return math.floor(t / 60).." m "..(t % 60).." s"
end
function util.combine(...) 
	local result = {}
	local alreadySeen = {} 
	for i, tab in pairs({...}) do
		for j, v in pairs(tab) do 
			if not alreadySeen[v] then 
				table.insert(result, v)
				alreadySeen[v]=true
			end
		end
	end
	return result	
end
function util.sign(number)
	return number > 0 and 1 or number < 0 and -1 or 0
end 

function util.combineSets(...) 
  
	local alreadySeen = {} 
	for i, tab in pairs({...}) do
		for k, v in pairs(tab) do 
			if not alreadySeen[k] then 
				alreadySeen[k]=v
			end
		end
	end
	return alreadySeen	
end
function util.contains(tab, value)
	for k, v in pairs(tab) do 
		if v==value then
			return true
		end
	end
	return false
end

function util.notFn(fn) 
	return 
	function(v) 
		return not fn(v)
	end 
end 

function util.indexOf(tab, value)
	for i, v in ipairs(tab) do 
		if v==value then
			return i
		end
	end
	return -1
end

function util.insertAll(tab1, tab2) 
	for i, v in ipairs(tab2) do 
		table.insert(tab1, v)
	end 
end 

function util.average(tab) 
	local total = 0 
	for i, v in pairs(tab) do 
		total = total + v
	end
	return total / #tab
end

function util.getKeysAsTable(tab)
	local keys = {} 
	for k, v in pairs(tab) do 
		table.insert(keys,k)
	end
	table.sort(keys)
	return keys
end

function util.sortByKeys(tab) 
	local keys = util.getKeysAsTable(tab)
	
	local result = {}
	for i, key in pairs(keys) do 
		result[key] = tab[key]
	end
		
	return result
end

function util.getFirstKey(tab) 
	for key, value in pairs(tab) do 
		return key 
	end 
end 

function util.getValueSet(tab)
	local keys = {} 
	for k, v in pairs(tab) do 
		keys[v]=true
	end
 	return keys
end
util.shallowClone =  function(tab)
	local res = {}
	for key, value in pairs(tab) do
		res[key]=value
 	end	 
	return res
end 
util.copyTableWithFilter =  function(tab, filterFn)
	local res = {}
	for key, value in pairs(tab) do
		if filterFn(value) then 
			table.insert(res, value)
		end 
 	end	 
	return res
end 
util.deepClone =  function(tab, transform)
	if tab == nil then 
		return nil 
	end
    local isTable = type(tab) == "table"
	local isUserData = not isTable and type(tab)=="userdata"
	
    if not isTable and not isUserData then return tab end
	local results = {}
	--[[
	if isUserData and getmetatable(tab).__type and getmetatable(tab).__type.name == "transport::EdgeId" then 
		results.entity = tab.entity 
		results.index = tab.index 
		return results
	end 
	]]--
	
    for key, value in pairs(tab) do
		if type(value) == 'table' or type(value) == 'userdata'  then
			local transformed = value 
			if transform then 
				transformed = transform(value)
			end 
			results[ key ] = util.deepClone(transformed, transform)
		else
			if key == "x" and type(value)=="number" and (util.size(tab) == 3 or tab.isV3) and tab.x and tab.y then 
				return util.v3(tab, true) -- try to maintain the vec3 objects because of their useful math
			end
			
			results[ key ] = transform and transform(value) or value
		end
    end
    return results
end
util.year = function() 
	return game.interface.getGameTime().date.year
end
function util.setPositionOnNode(newNode, p)
	newNode.comp.position.x = p.x
	newNode.comp.position.y = p.y
	newNode.comp.position.z = p.z
end

function util.newNodeWithPosition(p, nodeId)
	local newNode =  api.type.NodeAndEntity.new()
	newNode.comp.trafficLightPreference=1
	util.setPositionOnNode(newNode, p)
	if nodeId then 
		newNode.entity=nodeId
	end
	return newNode
end

function util.copyExistingNode(node, nodeId) 
	local newNode =  api.type.NodeAndEntity.new()
	if nodeId then 
		newNode.entity=nodeId
	end
	newNode.comp = util.getNode(node)
	return newNode
end
local context  -- TEST do we need to retain a reference to prevent gc and crashing? 
util.initContext = function() 
	context = api.type.Context.new()
	context.cleanupStreetGraph = false
	context.checkTerrainAlignment = false
	context.gatherBuildings = true
	context.gatherFields = true
	context.player = api.engine.util.getPlayer()
	return context
end

local function markV3(p)
	p.isV3 = true 
	return p 
end

util.v3fromArr = function(p)
	return markV3(vec3.new(p[1], p[2], p[3]))
end
function util.v3fromLegacyTransf(transf) 
	return markV3(vec3.new(transf[13], transf[14], transf[15]))
end

util.v3ToArr = function(p)
	return { p.x, p.y, p.z }
end
util.v3 = function(p, forceNew)
	if not forceNew and type(p)=="table" and p.isV3 then -- NB inspecting metatable is slow
		return p 
	end 
	return markV3(vec3.new(p.x, p.y, p.z))
end 
util.v2ToV3 = function(p,z)
	if not z then z = 0 end
	return markV3(vec3.new(p.x, p.y, z))
end 
util.v2ToV3Th = function(p )
	return util.v2ToV3(p, util.th(p))
end 
util.distanceArr = function(p0, p1)
	return util.distance(util.v3fromArr(p0),util.v3fromArr(p1))
end
function util.vecBetweenTowns(town1, town2) 
	return util.v3fromArr(town2.position)-util.v3fromArr(town1.position)
end

util.nodeDistance = function(node1, node2)
	return util.distance(util.nodePos(node1), util.nodePos(node2))
end

function util.getMapBoundary() 
	local function discoverMapBoundary() 
		--[[local x
		local y
		for i = 0, 50000, 10 do
			if not api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(i, 0)) then
				x = i-10
				break
			end
		end
		for i = 0, 50000, 10 do
			if not api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(0, i)) then
				y = i-10
				break
			end
		end
		]]--
		local terrain = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.TERRAIN)
		local x = terrain.size.x*128
		local y = terrain.size.y*128
		local padding = 64
		trace("The map boundary was found at ",x,y)
		return vec3.new( x-padding, y-padding ,0)
	end
	if not util.mapBoundary then 
		util.mapBoundary = discoverMapBoundary()
	end 
	return util.mapBoundary
end 

function util.getMaxMapHalfDistance()
	local mapBoundary = util.getMapBoundary()
	return math.max(mapBoundary.x, mapBoundary.y)
end 

function  util.isTransfUnset(transf) 
	for i = 0, 3 do 
		local vec4f = transf:cols(i)
		if vec4f.x ~= 0 or vec4f.y ~= 0 or vec4f.z ~= 0 or vec4f.w ~=0 then 
			return false 
		end
	end 
	
	return true 
end 
function  util.isTransfContainsNaN(transf) 
	for i = 0, 3 do 
		local vec4f = transf:cols(i)
		if vec4f.x ~= vec4f.x  or vec4f.y ~= vec4f.y  or vec4f.z ~= vec4f.z  or vec4f.w ~=vec4f.w  then 
			return true 
		end
	end 
	
	return false 
end 
function util.isValidCoordinate(p, withinDistance) 
	if not withinDistance then 
		withinDistance = 0 
	end
	if p.x ~= p.x or p.y ~= p.y then 
		return false 
	end
	local mapBoundary = util.getMapBoundary()
	return math.abs(p.x) + withinDistance  <= mapBoundary.x and math.abs(p.y) + withinDistance <= mapBoundary.y
end 

function util.bringCoordinateInsideMap(p)
	local newP = util.v3(p)
	local mapBoundary = util.getMapBoundary()
	if math.abs(p.x) > mapBoundary.x then 
		newP.x  = p.x > 0 and mapBoundary.x or -mapBoundary.x
	end 
	
	if math.abs(p.y) > mapBoundary.y then
		newP.y  = p.y > 0 and mapBoundary.y or -mapBoundary.y
	end  
	return newP
end

function util.getDistFromMapBoundary(p)
	local mapBoundary = util.getMapBoundary()
	-- assume only out of bounds in one coordinate
	if math.abs(p.x) > mapBoundary.x then 
		return math.abs(p.x)-mapBoundary.x, "x"
	elseif math.abs(p.y) > mapBoundary.y then  
		return math.abs(p.y)-mapBoundary.y, "y"
	else 
		return 0
	end 
	
end
function util.getDistToMapBoundary(p)
	local mapBoundary = util.getMapBoundary()
	local xDist = math.max(mapBoundary.x-math.abs(p.x), 0)
	local yDist = math.max(mapBoundary.y-math.abs(p.y), 0)
	return math.min(xDist, yDist)
end
function util.getSegmentsForNode(node) 
	if util.node2SegMap then  
		if not util.node2SegMap[node] and api.engine.entityExists(node) then 
			util.clearCacheNode2SegMaps()
			util.cacheNode2SegMaps() 
		end 
		return util.node2SegMap[node]
	end
	if util.isLazyCacheNode2SegMaps then 
		util.node2SegMap = util.deepClone(api.engine.system.streetSystem.getNode2SegmentMap())
		return util.node2SegMap[node]
	end 
	trace("WARNING! Fetching the raw nodeToSegmap")
	trace(debug.traceback())
	return util.deepClone(api.engine.system.streetSystem.getNode2SegmentMap()[node])-- note the clone seems necessary to prevent premature garbage collection and associated errors 
end 

function util.getStreetSegmentsForNode(node)
	if util.node2StreetMap then 
		if not util.node2StreetMap[node] and api.engine.entityExists(node) then 
			trace("WARNING! getStreetSegmentsForNode: No segments found for node",node,"attempting to correct")
			util.clearCacheNode2SegMaps()
			util.cacheNode2SegMaps() 
		end 
		return util.node2StreetMap[node]
	end
	if util.isLazyCacheNode2SegMaps then 
		util.node2StreetMap = util.deepClone(api.engine.system.streetSystem.getNode2StreetEdgeMap())
		return util.node2StreetMap[node]
	end 
	trace("WARNING! Fetching the raw nodeToSegmap")
	trace(debug.traceback())
	return util.deepClone(api.engine.system.streetSystem.getNode2StreetEdgeMap()[node])
end

function util.getEntity(entity) 
	if not util.entityCache then 
		util.entityCache = {}
	end 
	if not util.entityCache[entity] then 
		util.entityCache[entity] = game.interface.getEntity(entity)
	end 
	return util.entityCache[entity]
end 


function util.getTrackSegmentsForNode(node)
	if util.node2TrackMap then 
		if not util.node2TrackMap[node] and api.engine.entityExists(node) then 
			util.clearCacheNode2SegMaps()
			util.cacheNode2SegMaps() 
		end 
		return util.node2TrackMap[node]
	end
	if util.isLazyCacheNode2SegMaps then 
		util.node2TrackMap = util.deepClone(api.engine.system.streetSystem.getNode2TrackEdgeMap())
		return util.node2TrackMap[node]
	end 
	trace("WARNING! Fetching the raw nodeToSegmap")
	trace(debug.traceback())
	return util.deepClone(api.engine.system.streetSystem.getNode2TrackEdgeMap()[node])
end 
function util.cacheNode2SegMapsIfNecessary() 
	if util.node2SegMap or util.isLazyCacheNode2SegMaps then 
		return false 
	end 
	util.cacheNode2SegMaps()
	return true
end

function util.cacheNode2SegMaps() 
	-- based on performance timings, it seems the node2seg maps are created fresh on every call, this can be a big performance hit 
	local start = os.clock()
	util.node2SegMap = util.deepClone(api.engine.system.streetSystem.getNode2SegmentMap())
	util.node2StreetMap = util.deepClone(api.engine.system.streetSystem.getNode2StreetEdgeMap())
	util.node2TrackMap = util.deepClone(api.engine.system.streetSystem.getNode2TrackEdgeMap())
	util.initCacheTables() 
	local endtime = os.clock() 
	trace("Collected all node 2 seg maps, time taken was ",(endtime-start), " util was ",util)
end
function util.lazyCacheNode2SegMaps() 
	if util.isLazyCacheNode2SegMaps or util.node2SegMap then 
		return 
	end
	util.isLazyCacheNode2SegMaps = true
	util.initCacheTables() 
end 
function util.initCacheTables() 
	util.freeNodesForFreeTerminalsForStationCache = {}
	util.freeNodesForConstructionCache = {}
	util.industryEdgeCache = {}
	util.farmCache = {}
	util.farmFieldCache = {}
	util.frozenNodeCache = {}
	util.edgeMidPointCache = {}
	util.edgeCache = {}
	util.nodePosCache = {}
	util.oneWayStreetCache = {}
	util.constructionCache = {}
end
function util.clearCacheNode2SegMaps() 
	--trace("Clearing node2Seg maps for util ",util)
	util.node2SegMap = nil
	util.node2StreetMap = nil
	util.node2TrackMap = nil
	util.freeNodesForFreeTerminalsForStationCache = nil
	util.freeNodesForConstructionCache = nil
	util.industryEdgeCache = nil
	util.waterMeshEntities = nil
	util.farmCache = nil
	util.farmFieldCache = nil
	util.frozenNodeCache = nil
	util.edgeMidPointCache = nil
	util.isLazyCacheNode2SegMaps = false
	util.edgeCache = nil
	util.nodePosCache = nil
	util.oneWayStreetCache = nil
	util.naturalTangentCache = nil
	util.industryEntityCache = nil
	util.streetTypeCategoryCache = nil
	util.constructionCache = nil
	util.entityCache = nil
	util.tpLinksCache = nil
	util.stationCache = nil
	util.countEntityCaches = nil
	util.isConstructionCache = nil
	util.parcelData = nil
	util.parcel2BuildingMap = nil
	util.componentCache = nil
	util.lazyCacheNode2SegMaps()
end

function util.getComponent(entity, componentType)
	-- Stale/nil entity guard: a caller can hand us a line/edge id that was
	-- deleted since it was cached (e.g. vehicle panel "Show more" after the
	-- autonomous loop rebuilt a line). api.engine.getComponent(nil, ...) raises
	-- a sol "expected number, received nil" that poisons the whole UI update.
	if entity == nil or not api.engine.entityExists(entity) then 
		return nil 
	end
	if util.componentCache == nil then 
		util.componentCache = {}
	end 
	if util.componentCache[componentType]==nil then 
		util.componentCache[componentType] = {}
	end 
	if util.componentCache[componentType][entity]==nil then 
		util.componentCache[componentType][entity] = api.engine.getComponent(entity, componentType)
	end 
	return util.componentCache[componentType][entity]
end  
waterMeshUtil.getComponent = util.getComponent
function util.isConstruction(entity) 
	if not util.isConstructionCache then 
		util.isConstructionCache = {}
		api.engine.forEachEntityWithComponent(function(entity)
			util.isConstructionCache[entity]=true 
		end, api.type.ComponentType.CONSTRUCTION)
		
	end 
	return util.isConstructionCache[entity]
end 


function util.getNode(node) 
	if not api.engine.entityExists(node) then 
		-- Defensive: return nil (callers use pcall/guard) instead of hard error
		return nil
	end 
	return util.getComponent(node, api.type.ComponentType.BASE_NODE)
end

util.nodePos2 = function(node)
	local nodeComp = util.getNode(node)
	local result =  nodeComp and nodeComp.position
	if not result then 
		print("ERROR! Could not find position for node",node)
	end
	return result
end
util.nodePos = function(node, makeCopy)
	if util.nodePosCache and util.nodePosCache[node] then 
		return makeCopy and util.v3(util.nodePosCache[node], true) or util.nodePosCache[node]
	end 
	local nodePos =  util.v3(util.nodePos2(node))
	if util.nodePosCache then
		util.nodePosCache[node]=nodePos
	end 
	return makeCopy and util.v3(nodePos, true) or nodePos
end

util.vecBetweenNodes = function(node1, node2)
	return util.nodePos(node1)-util.nodePos(node2)
end
util.vecBetweenStations = function(station1, station2)
	return util.getStationPosition(station2)-util.getStationPosition(station1)
end
util.distBetweenNodes = function(node1, node2)
	return vec3.length(util.vecBetweenNodes(node1, node2))
end
util.distBetweenConstructions = function(c1, c2)
	return util.distance(util.getConstructionPosition(c1), util.getConstructionPosition(c2))
end

util.straightSegLength = function(edge)
	return util.distBetweenNodes(edge.node0, edge.node1)
end

util.normalVecBetweenNodes = function(node1,node2)
	return vec3.normalize(util.vecBetweenNodes(node1,node2))
end

function util.getEdge(edgeId) 
	if util.edgeCache and util.edgeCache[edgeId] then 
		return util.edgeCache[edgeId]
	end
	local edge =  util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
	if util.edgeCache and edge then 
		local edgeCopy = {}
		edgeCopy.node0 = edge.node0
		edgeCopy.node1 = edge.node1
		edgeCopy.type = edge.type 
		edgeCopy.typeIndex = edge.typeIndex 
		-- the key benefit is avoiding repeated vec3 creation, expensive due to calls to setmetatable 
		edgeCopy.tangent0 = util.v3(edge.tangent0)
		edgeCopy.tangent1 = util.v3(edge.tangent1)
		edgeCopy.objects = util.deepClone(edge.objects)
		util.edgeCache[edgeId]=edgeCopy 
	end
	return edge
end

function util.getNaturalTangent(edgeId) 
	if not util.naturalTangentCache then 
		util.naturalTangentCache = {}
	end 
	if not util.naturalTangentCache[edgeId] then 
		local edge = util.getEdge(edgeId)
		util.naturalTangentCache[edgeId] = util.vecBetweenNodes(edge.node1, edge.node0)
	end 
	return util.naturalTangentCache[edgeId]
end 

function util.getLine(lineId) 
	return util.getComponent(lineId, api.type.ComponentType.LINE)
end
function util.getStation(stationId) 
	if not util.stationCache then 
		util.stationCache = {}
	end 
	if not util.stationCache[stationId] then 
		util.stationCache[stationId] =  util.getComponent(stationId, api.type.ComponentType.STATION)
	end 
	return util.stationCache[stationId]
end
function util.getConstructionForStation(stationId) -- tolerant to being passed the stationId or the constructionId
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	--trace("attempting to get construction for stationId=",stationId," constructionId=",constructionId)
	if constructionId == -1 then
		return util.getConstruction(stationId)
	end 
	return util.getConstruction(constructionId)
end
function util.mapTable(tab, fn) 
	local res = {}
	for i, v in pairs(tab) do 
		table.insert(res, fn(v))
	end 
	return res
end 
function util.signedAngleBetweenPoints(p0, p1, p2) 

	local dx1 = p1.x - p0.x 
	local dy1 = p1.y - p0.y 
	
	local dx2 = p2.x - p1.x 
	local dy2 = p2.y - p1.y 
	
	local dot =  dx1 * dx2 + dy1 * dy2  
	local cross = dx1 * dy2 - dy1 * dx2 
			
	return math.atan2(cross, dot) 

end 


util.signedAngle = function(a, b)
	--local xyPlane = vec3.new(0,0,1)
	--return math.atan2(vec3.dot(vec3.cross(v1, v2), xyPlane), vec3.dot(v1, v2))
	
	
	local dot =  a.x * b.x + a.y * b.y --+ a.z * b.z
	local cross = a.x * b.y - a.y * b.x -- z component only for xy plane
			
	return math.atan2(cross, dot)
end

function util.distance(p0, p1) 
	-- avoids the performance overhead of creating intermediate object in vec3.distance
	local dx = p1.x-p0.x 
	local dy = p1.y-p0.y
	local dz = p1.z-p0.z 
	return math.sqrt(dx*dx + dy*dy + dz*dz)
end


function util.getEdgeMidPoint(edgeId)
	if util.edgeMidPointCache and util.edgeMidPointCache[edgeId] then 
		return util.edgeMidPointCache[edgeId]
	end
	local edgeComp = util.getEdge(edgeId)
	if not api.engine.entityExists(edgeComp.node0) or not api.engine.entityExists(edgeComp.node1) then 
		trace("WARNING! getEdgeMidPoint for edge",edgeId,"found potentally invalid cache, attempting to correct")
		util.clearCacheNode2SegMaps()
		edgeComp = util.getEdge(edgeId)
	end 
	local node0Pos =  util.nodePos(edgeComp.node0)
	local node1Pos = util.nodePos(edgeComp.node1)
	local p = node0Pos + 0.5*(node1Pos-node0Pos)
	if util.edgeMidPointCache then 
		util.edgeMidPointCache[edgeId]=p 
	end 
	return p
end

function  util.getStreetTypeName(edgeId) 
	local streetEdge = util.getStreetEdge(edgeId) 
	if streetEdge then 
		return api.res.streetTypeRep.getName(streetEdge.streetType)
	end
end 

function util.getName(entityId)
	local nameComp = util.getComponent(entityId, api.type.ComponentType.NAME)
	if nameComp then 
		return nameComp.name 
	end
end 

function util.getNodesFromEdges(edges)
	local result = {}
	local alreadySeen = {}
	for i, edgeId in pairs(edges) do
		if api.engine.entityExists(edgeId) then 
			local edge = util.getEdge(edgeId)
			if edge and not alreadySeen[edge.node0] then 
				alreadySeen[edge.node0]=true
				table.insert(result, edge.node0)
			end
			if edge and not alreadySeen[edge.node1] then
				alreadySeen[edge.node1]=true
				table.insert(result, edge.node1)
			end
		end
	end
	return result
end

function util.isTunnelPortal(node)
	local segs = util.getSegmentsForNode(node)
	if #segs == 2 then 
		local leftEdge = util.getEdge(segs[1])
		local rightEdge = util.getEdge(segs[2])
		local leftIsTunnel = leftEdge.type == 2
		local rightIsTunel = rightEdge.type ==2 
		if leftIsTunnel ~= rightIsTunel then 
			return true -- reject tunnel portals as these often fail to build
		end
	end 
	return false 
end

function util.isWaterMeshEntity(entity) 
	if not util.waterMeshEntities then 
		util.waterMeshEntities = {}
		api.engine.forEachEntityWithComponent(function(e) 
			util.waterMeshEntities[e]=true 
		end, 
		api.type.ComponentType.WATER_MESH)
	end 
	return util.waterMeshEntities[entity]
end 

function util.distBetweenEdges(edge1, edge2)
	return util.distance(util.getEdgeMidPoint(edge1), util.getEdgeMidPoint(edge2))
end

function util.getEdgeForBusStop(stationId) 
	return util.getComponent(stationId, api.type.ComponentType.STATION).terminals[1].vehicleNodeId.entity
end

function util.getConstruction(constructionId) 
	if util.constructionCache  then 
		if util.constructionCache[constructionId] == nil then 
			util.constructionCache[constructionId] = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) or false
		end 
		return util.constructionCache[constructionId]
	end 
	return util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
end 
function util.getConstructionPosition(constructionId) 
	local construction=  util.getConstruction(constructionId)
	return util.v3(construction.transf:cols(3))
end 
function util.getStationPosition(stationId) 
	local construction = util.getConstructionForStation(stationId)
	if not construction then -- bus stop 
		return util.getEdgeMidPoint(util.getEdgeForBusStop(stationId))
	end
	return util.v3(construction.transf:cols(3))
end

local boxmin
local boxmax 
local box3 

function util.findIntersectingEntities(p, offset, zOffset)
	local result = {} 
	if not box3 then 
		boxmin = api.type.Vec3f.new(0,0,0)
		boxmax = api.type.Vec3f.new(0,0,0)
		box3 = api.type.Box3.new(boxmin, boxmax)
	end 
	-- recycling objects for performance 
	boxmin.x = p.x-offset
	boxmin.y = p.y-offset
	boxmin.z = p.z-zOffset
	
	boxmax.x = p.x+offset
	boxmax.y = p.y+offset
	boxmax.z = p.z+zOffset
	
	-- NB tested in console, reassignment required 
	box3.min = boxmin 
	box3.max = boxmax
	if util.tracelog then 
		assert(math.abs(box3.max.z - (p.z+zOffset))<0.1, "expected "..tostring(p.z+zOffset).." but was "..tostring(box3.max.z))
		assert(math.abs(box3.min.x - (p.x-offset))<0.1, "expected "..tostring(p.x-offset).." but was "..tostring(box3.min.x))
	end 
	local count = 0
	api.engine.system.octreeSystem.findIntersectingEntities(box3, function(entity, boundingVolume)
		table.insert(result, entity)
	end)
	return result 
end

function util.findIntersectingEntitiesAndVolume(p, offset, zOffset)
	local result = {} 
	local box =  api.type.Box3.new(api.type.Vec3f.new(p.x-offset,p.y-offset, p.z-zOffset),api.type.Vec3f.new(p.x+offset,p.y+offset, p.z+zOffset))
	local count = 0
	api.engine.system.octreeSystem.findIntersectingEntities(box, function(entity, boundingVolume)
		result[entity]=boundingVolume
	end)
	return result 
end
 
function util.getDepotPosition(depotEntity)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(depotEntity)
	return util.getConstructionPosition(constructionId)
end

function util.vectorBetweenStations(station1, station2) 
	return util.getStationPosition(station2) - util.getStationPosition(station1)
end
 
function util.smallestAngleBetweenTangents(tangent1, tangent2) 
	local angle = math.abs(util.signedAngle(tangent1, tangent2))
	if angle > math.rad(90) then 
		angle = math.rad(180) - angle
	end 
	return angle 
end 
function util.getTangentAtNode(edgeId, node)
	local edge = type(edgeId)=="number" and util.getEdge(edgeId) or edgeId 
	return edge.node0 == node and edge.tangent0 or edge.tangent1	
end 
function util.isTrackEdge(edgeId)
	return util.getTrackEdge(edgeId) ~= nil

end 
function util.isTrackJoinJunction(node, oldNodeToEdgeMap)
	local segs = util.getTrackSegmentsForNode(node)
	if oldNodeToEdgeMap and oldNodeToEdgeMap[node] then 
		segs = util.shallowClone(segs)
		trace("isTrackJoinJunction: combining",#segs,"currently with",#oldNodeToEdgeMap[node])
		for i , seg in pairs(oldNodeToEdgeMap[node]) do 
			local shouldAdd = true 
			local edgeId = util.findEdgeConnectingNodes(seg.node0, seg.node1)
			
			if edgeId then 
				shouldAdd = not util.contains(segs, edgeId)
			end 
			trace("Inspecting edge",edgeId,"has nodes",seg.node0,seg.node1,"at node",node,"shouldAdd=",shouldAdd)
			if shouldAdd then 
				table.insert(segs, seg)
			end 
		end 
	 
		trace("after combination the result had",#segs) 	
		if #segs > 5 then 
			trace("WARNING! Unlikely number of segs")
			debugPrint(segs)
		end
	end
	trace("isTrackJoinJunction #segs=",#segs)
	if #segs ~= 3 then 
		return false 
	end 
	local tolerance = math.rad(0.1) 
	for i, seg in pairs(segs) do -- check all the tangents line up at the node
		for j, seg2 in pairs(segs) do 
			if seg~=seg2 then 
				local tangent1 =util.getTangentAtNode(seg, node)
				local tangent2 =util.getTangentAtNode(seg2, node)
				local angle = util.smallestAngleBetweenTangents(tangent1, tangent2) 
				trace("isTrackJoinJunction: The angle between ",seg,seg2," was ",math.deg(angle)," is over tolerance?",angle>tolerance)
				if angle > tolerance then 
					return false 
				end
			end 
		end 
	end 
	trace("isTrackJoinJunction: Found trackJoinjunction at ",node)
	return true
end 

function util.isSlipSwitchJoinEdge(edgeId) 
	local edge = util.getEdge(edgeId) 
	local foundSlipSwitch = false 
	local foundTrackJunction = false 
	for i, node in pairs({edge.node0, edge.node1}) do
		if #util.getTrackSegmentsForNode(node)==4 and util.getNode(node).doubleSlipSwitch then 
			foundSlipSwitch = true 
		end 
		if #util.getTrackSegmentsForNode(node)==3 and not util.isNodeConnectedToFrozenEdge(node) then 
			foundTrackJunction = true
		end 
	end 
	trace("isSlipSwitchJoinEdge inspecting edge",edgeId,"foundSlipSwitch?",foundSlipSwitch,"foundTrackJunction?",foundTrackJunction)
	return foundSlipSwitch and foundTrackJunction
end 

function util.distBetweenStations(station1, station2) 
	return vec3.length(util.vectorBetweenStations(station1, station2))
end
util.hermite = function(t, p0, m0, p1, m1)
-- cubic hermite equation for 0<=t<=1, m means tangent. Source https://en.wikipedia.org/wiki/Cubic_Hermite_spline#Unit_interval_(0,_1)
-- p(t) = (2t^3-3t^2+1)p0 + (t^3-2t^2+t)m0 + (-2t^3 + 3t^2)p1 + (t^3-t^2)m1
	return {
		p = vec3.new
		(
		-- x =
			(2 * t^3 - 3 * t^2 + 1) * p0.x+
			(t^3 - 2 * t^2 + t) * m0.x + 
			(- 2 * t^3 + 3*t^2) * p1.x +
			( t^3 - t^2) * m1.x,
		-- y =
			(2 * t^3 - 3 * t^2 + 1) * p0.y+
			(t^3 - 2 * t^2 + t) * m0.y + 
			(- 2 * t^3 + 3*t^2) * p1.y +
			( t^3 - t^2) * m1.y,
		-- z =
			(2 * t^3 - 3 * t^2 + 1) * p0.z+
			(t^3 - 2 * t^2 + t) * m0.z + 
			(- 2 * t^3 + 3*t^2) * p1.z +
			( t^3 - t^2) * m1.z
		),
		-- thank you to wolframalpha https://www.wolframalpha.com/input?i=derivative+of+p%28t%29+%3D+%282t%5E3-3t%5E2%2B1%29p0+%2B+%28t%5E3-2t%5E2%2Bt%29m0+%2B+%28-2t%5E3+%2B+3t%5E2%29p1+%2B+%28t%5E3-t%5E2%29m1
		-- p'(t) = m0 (3 t^2 - 4 t + 1) + m1 (3 t - 2) t + 6 (t - 1) t (p0 - p1)
		t = vec3.new
		(
			m0.x * (3*t^2 - 4*t + 1) + m1.x * (3*t - 2) * t + 6 * (t - 1) * t * (p0.x - p1.x),
			m0.y * (3*t^2 - 4*t + 1) + m1.y * (3*t - 2) * t + 6 * (t - 1) * t * (p0.y - p1.y),
			m0.z * (3*t^2 - 4*t + 1) + m1.z * (3*t - 2) * t + 6 * (t - 1) * t * (p0.z - p1.z)
		),
		f = t			
	}
end
util.hermite2 = function(t, edge)
	return util.hermite(t, edge.p0,edge.t0,edge.p1,edge.t1)
end
function util.solveForPositionHermiteSlow(pPos, edge, distanceFn)
	local options = {}
	for i = 0, 200 do 
		local t = i/200
		table.insert(options, {t=t, scores = { distanceFn(pPos, util.hermite2(t, edge).p) }}) 
	end 
	local best = util.evaluateWinnerFromScores(options)
	trace("Slow hermite solve: The solution was ",best.t," best distance=",best.scores[1])
	return best.t
end

function util.solveForPositionHermiteFraction2(fraction, p0, t0, p1, t1)
	return util.solveForPositionHermiteFraction(fraction, { 
		p0 = p0,
		p1 = p1, 
		t0 = t0,
		t1 = t1	})
end 
function util.copySegmentAndEntity(copyFrom, entityId)
	local entity = api.type.SegmentAndEntity.new()
	-- the userdata appears to copy itself on assignment, no need for deep clone
	entity.playerOwned =copyFrom.playerOwned
	entity.comp = copyFrom.comp
	entity.trackEdge = copyFrom.trackEdge
	entity.type = copyFrom.type
	entity.streetEdge = copyFrom.streetEdge
	--entity.params = copyFrom.params	 
	if entityId then
		entity.entity = entityId
	end
	return entity

end
function util.solveForPositionHermiteFractionProposalEdge(fraction, edgeEntity, nodePosFn)
	return util.solveForPositionHermiteFraction(fraction, { 
		p0 = nodePosFn(edgeEntity.comp.node0),
		p1 = nodePosFn(edgeEntity.comp.node1), 
		t0 = util.v3(edgeEntity.comp.tangent0),
		t1 = util.v3(edgeEntity.comp.tangent1)
		})
end

function util.solveForPositionHermiteFractionExistingEdge(fraction, edgeId)
	local edge = util.getEdge(edgeId)
	return util.solveForPositionHermiteFraction(fraction, { 
		p0 = util.nodePos(edge.node0),
		p1 = util.nodePos(edge.node1), 
		t0 = util.v3(edge.tangent0),
		t1 = util.v3(edge.tangent1)
	})
end 
function util.solveForPositionHermiteFraction(fraction, edge, keepOriginalLength)
	--if tracelog then debugPrint({pPos=pPos, edge=edge}) end
	assert(fraction<=1 and fraction >=0, "fraction in range "..tostring(fraction))
	if not keepOriginalLength then 
		util.applyEdgeAutoTangents(edge)
	end
	local edgeLength =  util.calcEdgeLengthHighAccuracy(edge, 1)
	local desiredLength = fraction*edgeLength
	--trace("solveForPositionHermiteFraction: set the desired length=",desiredLength,"the edgeLength=",edgeLength,"based on fraction",fraction)
	return util.solveForPositionHermiteLength(desiredLength, edge,1,keepOriginalLength)
end


function util.solveForPositionHermitePositionAtRelativeOffset(position, offset, edge)
	util.applyEdgeAutoTangents(edge)
	local s = util.solveForPosition(position, edge, vec2.distance)
	local length = util.calcEdgeLengthHighAccuracy(s, 1)
	local totalEdgeLength = util.calcEdgeLengthHighAccuracy(edge,1)
	local target = length+offset 
	trace("solveForPositionHermitePositionAtRelativeOffset: the length was",length, "the offset was",offset,"the totalEdgeLength was",totalEdgeLength,"the target was",target,"input position=",position.x,position.y)
	if target < 0 then 
		if math.abs(target)< 1 then 
			trace("WARNING would evaluate a negative target",target,"attempting to correct")
			target =0 
		else 
			return { solutionConverged = false }
		--	error("target length negative, unable to solve")
		end 
	end 
	if target > totalEdgeLength then 
		return { solutionConverged = false }
	--	error("target length out of bounds")
	end
	local s = util.solveForPositionHermiteLength(target, edge)
	
	trace("solveForPositionHermitePositionAtRelativeOffset: the solution was",s.p.x,s.p.y,"the distance to position is",vec2.distance(s.p,position))
	return s
end
local function length(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function derivative_hermite(p0, p1, t0, t1, t)
    local h00 = 6 * t^2 - 6 * t
    local h10 = 3 * t^2 - 4 * t + 1
    local h01 = -6 * t^2 + 6 * t
    local h11 = 3 * t^2 - 2 * t

    return {
        x = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
        y = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
        z = h00 * p0.z + h10 * t0.z + h01 * p1.z + h11 * t1.z,
    }
end

-- Gaussian points and weights (5-point quadrature)
local gauss_points = {
    -0.9061798459,
    -0.5384693101,
    0.0,
    0.5384693101,
    0.9061798459,
}

local gauss_weights = {
    0.2369268850,
    0.4786286705,
    0.5688888889,
    0.4786286705,
    0.2369268850,
}
-- 9-point Gaussian quadrature points
local gauss_points = {
    -0.9681602395,
    -0.8360311073,
    -0.6133714327,
    -0.3242534234,
    0.0,
    0.3242534234,
    0.6133714327,
    0.8360311073,
    0.9681602395,
}

-- Corresponding weights
local gauss_weights = {
    0.0812743884,
    0.1806481607,
    0.2606106964,
    0.3123470770,
    0.3302393550,
    0.3123470770,
    0.2606106964,
    0.1806481607,
    0.0812743884,
}
-- Hermite length using 9-point Gaussian Quadrature
local function hermite_length_gauss(p0, p1, t0, t1)
    local length_sum = 0
    for i = 1, #gauss_points do
        local xi = gauss_points[i]
        local wi = gauss_weights[i]
        -- Map from [-1,1] to [0,1]
        local ti = 0.5 * (xi + 1)
        local dPdt = derivative_hermite(p0, p1, t0, t1, ti)
        local speed = length(dPdt)
        length_sum = length_sum + wi * speed
    end
    -- Adjust for interval length (0.5 because [0,1] interval vs [-1,1])
    return 0.5 * length_sum
end
function util.calcEdgeLengthHighAccuracyWithTangentCorrection(edge) 
	util.applyEdgeAutoTangents(edge) 
	return util.calcEdgeLengthHighAccuracy(edge)
end 

function util.calcEdgeLengthHighAccuracy(edge, t, debugResults)
	return hermite_length_gauss(edge.p0, edge.p1, edge.t0, edge.t1)
	--[[if not t then t = 1 end
	local angle = math.abs(util.signedAngle(edge.t0,edge.t1))
	local numSamples = 1+math.ceil(angle/math.rad(30)) -- somewhat by trial and error in terms of convergance
	local actualLength = 0 
	if debugResults then 
 		debugPrint({inputEdge=edge})
		trace("The angle was",math.deg(angle),"the numSamples was",numSamples)
	end 
	local priorP = edge.p0 
	local priorT = edge.t0 
	for i = 1, numSamples do 
		local frac = i/numSamples
		local s = util.hermite2(t*frac,edge)
		s.p0 = priorP
		s.p1 = s.p  
		s.t0 = priorT
		s.t1 = s.t
		priorT = s.t 
		priorP = s.p 
		util.applyEdgeAutoTangents(s)
		if debugResults then 
			trace("At i=",i,"frac=",frac,"t*frac=",t*frac,"mid point was",s.p.x,s.p.y,"tangents",s.t.x, s.t.y)
		end
		actualLength =  actualLength + util.calcEdgeLengthFull(s.p0, s.p1, s.t0, s.t1)
		if actualLength ~= actualLength then 
			if not debugResults then 
				debugResults = true 
				return util.calcEdgeLengthHighAccuracy(edge, t, debugResults)
			else 
				error("NaN length calculated") 
			end 
		end 
		if debugResults then 
			trace("At i=",i,"frac=",frac,"t*frac=",t*frac,"the actualLength was calculated as",actualLength)
		end 
	end 
	if debugResults then 
		if t == 1 then 
			local edgeLength = util.calcEdgeLengthFull(edge.p0, edge.p1, edge.t0, edge.t1)
			local dist = util.distance(edge.p0, edge.p1)
			trace("The final actualLength was",actualLength,"edgeLength=",edgeLength,"plain dist",dist)
		else 
			local s = util.hermite2(t,edge)
			s.p0 = priorP
			s.p1 = s.p  
			s.t0 = priorT
			s.t1 = s.t
			priorT = s.t 
			priorP = s.p 
			util.applyEdgeAutoTangents(s)
			local oldLength = util.calcEdgeLengthFull(s.p0, s.p1, s.t0, s.t1)
			local angle = math.abs(util.signedAngle(s.t0,s.t1))
			local dist=  util.distance(s.p0, s.p1)
			trace("The final actualLength was",actualLength,"parameter=",t,"oldLength=",oldLength,"dist=",dist,"angle=",math.deg(angle))
		end 
	 
		
	end 
	return actualLength ]]--
end 

function util.solveForPositionHermiteLength(desiredLength, edge, tolerance, keepOriginalLength, debugResults)
	local thisCorrectTangentLengths = alwaysCorrectTangentLengths and not keepOriginalLength 
	if thisCorrectTangentLengths then 
		local length = util.calculateTangentLength(edge.p0, edge.p1, edge.t0, edge.t1)
		--trace("Got length=",length,"input length=",vec3.length(edge.t0))
		edge.t0 = length*vec3.normalize(edge.t0)
		edge.t1 = length*vec3.normalize(edge.t1)
	end 

	local edgeLength =  util.calcEdgeLengthHighAccuracy(edge, 1, debugResults)--util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1)
	local fraction = desiredLength / edgeLength
	if debugResults then 
		trace("The initial desiredLength was",desiredLength,"the edgeLength=",edgeLength)
	end
	if desiredLength < 0 then 
		error("Negative desiredLength") 
	end 
	if desiredLength > 1.01*edgeLength then 
		error("Edge length out of bounds wanted "..tostring(desiredLength).." but max="..tostring(edgeLength))
	end 
	
	
	--local logOut = true
	if not tolerance then tolerance = 1 end
	local solutionFn = function(t)
		--local s = util.solveForPosition(util.hermite2(t,edge).p, edge)
		--local actualLength = util.calcEdgeLength(s.p0, s.p1, s.t0, s.t1)
		--if not s.solutionConverged then 
		--	local s = util.hermite2(t,edge)
		--	s.p0 = edge.p0
		--	s.p1 = s.p 
			--s.t0 = util.distance(s.p0, s.p1) * vec3.normalize(edge.t0)
			--s.t1 = util.distance(s.p0, s.p1) * vec3.normalize(s.t)
		--	s.t0 = t*edge.t0
		--	s.t1 = t*vec3.length(edge.t0)* vec3.normalize(s.t)
			--local actualLengthBefore = actualLength
		--	
		--	local actualLength = util.calcEdgeLengthFull(s.p0, s.p1, s.t0, s.t1)
			--trace("WARNING!!! Solution did not converge, calculation before was ",actualLengthBefore, " calculation after was ",actualLength) 
		--end
		local s = util.hermite2(t,edge)
		s.p0 = edge.p0
		s.p1 = s.p 
		s.t0 = edge.t0
		s.t1 = s.t
		--if thisCorrectTangentLengths then 
			--util.applyEdgeAutoTangents(s)
		--else 
			s.t0 = t * edge.t0 
			s.t1 = t * s.t
		--end 
		--trace("Using the oldActualLength we got",oldActualLength,"new way got",actualLength)
		local actualLength = util.calcEdgeLengthHighAccuracy(s, t,debugResults)
		if debugResults then 
			trace("At t=",t,"calculated length=",actualLength,"p0=",s.p0.x,s.p0.y,"p1=",s.p1.x,s.p1.y,"t0=",s.t0.x,s.t0.y,"t1=",s.t1.x,s.t1.y)
		end 
		
	--	if logOut then 
		--	trace("The actualLength solution was ",actualLength)
		--end 
		return actualLength-desiredLength
	end
	--trace("The edgeLength was ",edgeLength," the desiredLength was ", desiredLength, " the straight distance was ",util.distance(edge.p0, edge.p1))

	local initialDist = solutionFn(fraction)
	--trace("The initial dist was ",initialDist)
	--logOut = false
	local maxIteration = 64
		--local maxRecursions = precision
	local iteration = 1
	local vhigh = 1
	local vlow = 0
	local vmid = (vhigh+vlow)/2
	local solution
	repeat 
		 
		local temp = vmid
		solution = solutionFn(vmid)
		if math.abs(solution)<tolerance then 
			break 
		end
		if solution > 0 then
			vmid = (vlow+vmid)/2
			vhigh = temp
		elseif solution < 0 then
			vmid = (vhigh+vmid)/2
			vlow = temp
		end

		iteration = iteration + 1
		if debugResults then 
			trace("On iteration",iteration,"vlow=",vlow,"vhigh=",vhigh,"vmid=",vmid,"solution=",solution)
		end
	until iteration == maxIteration  or vlow == vhigh

	local t = vmid
	local solutionConverged = math.abs(solution)<tolerance
	--trace("The final hermite solution t=",vmid,"d=",solutionFn(vmid)," after ",iteration, " the original frac was ",fraction)
	if not solutionConverged then 
		if math.abs(solution) < 5 then 
			trace("Solution initially not converged but",solution,"accepting")
			solutionConverged = true 
		end 
	end 
	if not solutionConverged then 
		if util.tracelog then 
			debugPrint(edge)
			if not debugResults then 
				debugResults = true 
				util.solveForPositionHermiteLength(desiredLength, edge, tolerance, keepOriginalLength, debugResults)
			else 
				error("Solution not converged")
			end 
		end 
		t = fraction 
	end
	
	local result = util.hermite2(t, edge)
	result.solutionConverged =  solutionConverged
	--trace("For t=",t," the length of t0 was ",vec3.length(edge.t0 )," length of t was ",vec3.length(result.t))
	local len1 = t*edgeLength 
	local len2 = (1-t)*edgeLength 
--[[	if alwaysCorrectTangentLengths then 
		len1 = util.calculateTangentLength(edge.p0, result.p, edge.t0, result.t)
		len2 = util.calculateTangentLength(result.p, edge.p1 , result.t, edge.t1)
	end ]]--
	result.p0=edge.p0
	result.p1=result.p
	result.p2=result.p
	result.p3=edge.p1
	result.t0=len1*vec3.normalize(edge.t0)
	result.t1=len1*vec3.normalize(result.t)
	result.t2=len2*vec3.normalize(result.t)
	result.t3=len2*vec3.normalize(edge.t1)
	result.frac = t
	if len1~=len1 or len2~=len2 then 
		trace("WARNING! Found NaN during solve")
		result.solutionConverged = false 
		result.solutionIsNaN = true
	end
	return result
end

function util.textAndIcon(text, icon)

	local titleLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	
	local imageView= api.gui.comp.ImageView.new(icon)
	--imageView:setMaximumSize(api.gui.util.Size.new( 17, 17 ))
	imageView:setMaximumSize(api.gui.util.Size.new( 40, 40 ))
	titleLayout:addItem(imageView)
	titleLayout:addItem(api.gui.comp.TextView.new(_(text)))
	local titleComp =  api.gui.comp.Component.new("ConstructionMenu")
	titleComp:setLayout(titleLayout)
	return titleComp
end	

function util.solveForPositionHermite(pPos, edge, distanceFn)
	--if tracelog then debugPrint({pPos=pPos, edge=edge}) end
	if not distanceFn then
		distanceFn = util.distance
	end
	if alwaysCorrectTangentLengths then 
		local length = util.calculateTangentLength(edge.p0, edge.p1, edge.t0, edge.t1)
		edge.t0 = length*vec3.normalize(edge.t0)
		edge.t1 = length*vec3.normalize(edge.t1)
	end 
	local lowHalf = true
	local highHalf = true
	local p, p0, p1
	local t = 0.5
	local ta = 0
	local tb = 1
	local minDistance =  math.min(distanceFn(pPos , edge.p0), distanceFn(pPos , edge.p1)) / 10

	local maxRecursions = 200
	--local maxRecursions = precision
	local recursion = 1
	--trace("Begin iteration, maxRecursions=",maxRecursions)
	repeat -- we divide it again and again to find a split point near our  position
		if highHalf then
			p0 = util.hermite2(ta, edge).p
		end
		if lowHalf then
			p1 = util.hermite2(tb, edge).p
		end
		if distanceFn(pPos , p0) < distanceFn(pPos , p1) then
			tb = tb - .5 * (tb - ta)
			lowHalf = true
			highHalf = false
		else
			ta = ta + .5 * (tb - ta)
			lowHalf = false
			highHalf = true
		end
		recursion = recursion + 1
	until recursion == maxRecursions or distanceFn(pPos , p1) < 0.1 or distanceFn(pPos , p0) < 0.1 or ta==tb
	 
	local d = distanceFn(pPos , p0)
	--if  d < minDistance then
	local d2 = distanceFn(pPos , p1)
		if d < d2 then
			p=p0
			t=ta
		else
			p=p1
			t=tb
			d=d2
		end
	if  d > minDistance then 
       -- debugPrint({pPos=pPos, edge=edge, p0=p0,p1=p1,t=t, ta=ta, tb=tb})
		--print("WARNING!!! d>=mindistance ",d,minDistance, " maxRecursions=" , maxRecursions, " dist p0-p1 =",distanceFn(edge.p0, edge.p1), " --len(t0)=",vec3.length(edge.t0), " len(t1)=",vec3.length(edge.t1))
		--return util.solveForPositionHermiteSlow(pPos, edge, distanceFn) -- attempt a resolution
	end
	--trace("hermite solution t=",t,"d=",d," after ",recursion)
	return t
end

function util.solveForNearestHermitePosition(p, edge)
	local t = util.solveForPositionHermite(p, edge)
	return util.hermite2(t,edge).p
end

local function convertHermiteToBezier(edge) -- edge must contain vec3 objects
	local oneThird = 1 / 3

	local b0 = edge.p0 -- b instead of p/t for absolute Bezier points, like Wikipedia example
	local b1 = edge.p0 + oneThird * edge.t0
	local b2 = edge.p1 - oneThird * edge.t1
	local b3 = edge.p1

	return b0, b1, b2, b3
end

local function convertBezierToHermite(b0, b1, b2, b3) -- arguments must be vec3 objects
	local p0 = b0 
	local p1 = b3
	local t0 = 3 * (b1 - b0)
	local t1 = 3 * (b3 - b2)

	return p0, p1, t0, t1
end

local function deCasteljau(b0, b1, b2, b3, t)
	local b1n = b0 + t * (b1 - b0)
	local b1b2 = b1 + t * (b2 - b1)
	local b5n = b3 + (1 - t) * (b2 - b3)
	local b2n = b1n + t * (b1b2 - b1n)
	local b4n = b1b2 + t * (b5n - b1b2)
	local b3n = b2n + t * (b4n - b2n)

	return b1n, b2n, b3n, b4n, b5n
end

function util.calcScale(dist, angle)
	if (angle < .001) then
		return dist
	end

	local pi = 3.14159
	local pi2 = pi / 2
	local sqrt2 = 1.41421

	local scale = 1.0
	if (angle >= pi2) then
		scale = 1.0 + (sqrt2 - 1.0) * ((angle - pi2) / pi2)
		--trace("scale was", scale)
	end

	return .5 * dist / math.cos(.5 * pi - .5 * angle) * angle * scale
end 

function util.applyEdgeAutoTangents(edge)  
	local q0 = vec3.normalize(edge.t0)
	local q1 = vec3.normalize(edge.t1)

	local length = util.distance(edge.p0, edge.p1)
	local angle = vec3.angleUnit(q0, q1)

	local scale = util.calcScale(length, angle)

	edge.t0 = vec3.mul(scale, q0)
	edge.t1 = vec3.mul(scale, q1)
	return edge
end 

function util.rescaleTangents(newEdge, scale)
	util.setTangent(newEdge.comp.tangent0, scale*util.v3(newEdge.comp.tangent0))
	util.setTangent(newEdge.comp.tangent1, scale*util.v3(newEdge.comp.tangent1))
end 
function util.checkForInvalidNodes()
	-- package.loaded["ai_builder_base_util"]=nil
	-- util = require "ai_builder_base_util"
	-- util.checkForInvalidNodes()
	util.lazyCacheNode2SegMaps()
	api.engine.forEachEntityWithComponent(function(node) 
		for j, edgeId in pairs(util.getStreetSegmentsForNode(node)) do 
			local edge = util.getEdge(edgeId)
			local ourNode0 = node == edge.node0
			for k, seg in pairs(util.getStreetSegmentsForNode(node)) do 
				if seg ~= edgeId then 
					local otherSeg = util.getEdge(seg)
					
					local theirNode0 = otherSeg.node0 == node
					
					local theirTangent = util.v3(theirNode0 and otherSeg.tangent0 or otherSeg.tangent1)
					local ourTangent =   util.v3(ourNode0 and edge.tangent0 or edge.tangent1)
					if ourNode0 == theirNode0 then 
						theirTangent = -1*theirTangent
					end 
					local angle = math.abs(util.signedAngle(ourTangent, theirTangent))
					--trace("Inspecing angle between",edgeId, seg," angle was ",math.deg(angle))
					--maxAngles[j]=math.max(maxAngles[j], angle)
					if math.abs(math.rad(180)-angle) < math.rad(5) then 
						trace("WARNING! Shallow angle detected at node",node,"angle was",angle,"between",edgeId,seg)
					end 
				end 
			end
		end 
	end, api.type.ComponentType.BASE_NODE)

end 
function util.setTangentLengths(newEdge, dist)
	local t0 = util.v3(newEdge.comp.tangent0)
	local t1 = util.v3(newEdge.comp.tangent1)
	--local q0 = vec3.normalize(t0)
	--local q1 = vec3.normalize(t1)
	local angle = math.abs(util.signedAngle(t0,t1))
	--local angle = vec3.angleUnit(q0, q1)
	if not dist then 
		dist = util.distBetweenNodes(newEdge.comp.node0, newEdge.comp.node1) -- assumes both are existing
	end 
	local newLength =  util.calcScale(dist, angle)
	util.setTangent(newEdge.comp.tangent0, newLength*vec3.normalize(t0))
	util.setTangent(newEdge.comp.tangent1, newLength*vec3.normalize(t1))
end  

function util.solveForPosition(pPos, edge, distanceFn)
	--if tracelog then debugPrint({pPos=pPos, edge=edge}) end
	if not distanceFn then
		distanceFn = util.distance
	end
	
	local minDistance =  math.min(distanceFn(pPos, edge.p1), distanceFn(pPos,edge.p0)) / 2
	if useHermiteSolution then 
		local length = math.max(util.calcEdgeLength(edge.p0, edge.p1, edge.t0, edge.t1), math.max(vec3.length(edge.t0), vec3.length(edge.t1)))
		local t = util.solveForPositionHermite(pPos, edge, distanceFn)
		local len1 = t*length 
		local len2 = (1-t)*length
		local h = util.hermite2(t, edge)
		--[[if alwaysCorrectTangentLengths then 
			len1 = util.calculateTangentLength(edge.p0, h.p, edge.t0, h.t)
			len2 = util.calculateTangentLength(h.p, edge.p1 , h.t, edge.t1)
		end ]]--
		
		return {
			p=h.p,
			p0=edge.p0,
			p1=h.p, 
			p2=h.p, 
			p3=edge.p1,
			t0=len1*vec3.normalize(edge.t0),
			t1=len1*vec3.normalize(h.t), 
			t2=len2*vec3.normalize(h.t),
			t3=len2*vec3.normalize(edge.t1),
			frac = t,
			t= h.t,
			inputedge=edge,
			solutionConverged=distanceFn(pPos, h.p)<=minDistance 
		}
	end
	
	local b0, b1, b2, b3 = convertHermiteToBezier(edge)
	
	local b1a, b2a, b3a, b4a, b5a, b1b, b2b, b3b, b4b, b5b, p0, p1, p2, p3, t0, t1, t2, t3, t
	local lowHalf = true
	local highHalf = true
	local ta = 0
	local tb = 1
	

	local maxRecursions = 32 --round(math.log(targetSegmentLength, 2), 0) + precision
	--local maxRecursions = precision
	local recursion = 1
	--trace("Begin iteration, maxRecursions=",maxRecursions)
	repeat -- we divide it again and again to find a split point near our  position
		if highHalf then
			b1a, b2a, b3a, b4a, b5a = deCasteljau(b0, b1, b2, b3, ta)
		end
		if lowHalf then
			b1b, b2b, b3b, b4b, b5b = deCasteljau(b0, b1, b2, b3, tb)
		end
		if distanceFn(pPos , b3a) < distanceFn(pPos , b3b) then
			tb = tb - .5 * (tb - ta)
			lowHalf = true
			highHalf = false
		else
			ta = ta + .5 * (tb - ta)
			lowHalf = false
			highHalf = true
		end
		recursion = recursion + 1
	until recursion == maxRecursions or distanceFn(pPos , b3a) < 1 or distanceFn(pPos , b3b) < 1 or ta==tb
	
	local d = distanceFn(pPos , b3a)

		if d < distanceFn(pPos , b3b) then
			p0, p1, t0, t1 = convertBezierToHermite(b0, b1a, b2a, b3a)
			p2, p3, t2, t3 = convertBezierToHermite(b3a, b4a, b5a, b3)
			t = ta
		else
			p0, p1, t0, t1 = convertBezierToHermite(b0, b1b, b2b, b3b)
			p2, p3, t2, t3 = convertBezierToHermite(b3b, b4b, b5b, b3)
			t = tb
		end
	local resultValid = true
	local solutionConverged = d <= minDistance
	if  d > minDistance then 
		--debugPrint({pPos=pPos, edge=edge})
		--trace("WARNING!!! d>=mindistance ",d,minDistance, " maxRecursions=" , maxRecursions)
		resultValid = false
	elseif t1.x~=t1.x or p1.x~=p1.x then
		--debugPrint({pPos=pPos, edge=edge, t1=t1, t2=t2, p1=p1})
		resultValid = false
		trace("WARNING!!! NaN detected ",d,minDistance, " maxRecursions=" , maxRecursions)
		print(debug.traceback())
		error("NaN detected")
	end
	if not resultValid then 
		-- fall back to a naive solution 
		if not pPos.z then 
			pPos = util.v2ToV3(pPos, (edge.p0.z+edge.p1.z)/2)	
		elseif distanceFn(vec3.new(0,0,0), vec3.new(0,0,1)) == 0 then -- only using 2d distances 
			pPos = vec3.new(pPos.x, pPos.y, (edge.p0.z+edge.p1.z)/2)
		end
		local tmid = (edge.p1-pPos) + (pPos-edge.p0)
		local hermiteSolution = util.hermite2(util.solveForPositionHermite(pPos, edge, distanceFn), edge)
		if  distanceFn(pPos, hermiteSolution.p) <= minDistance then 
			--trace("The solution initially failed to converge but a hermite position was found!")
			solutionConverged= true 
			pPos = hermiteSolution.p 
			tmid = hermiteSolution.t
		 
			
		end
		
		
		t0 = distanceFn(edge.p0, pPos)*vec3.normalize(edge.t0)
		t1 = distanceFn(edge.p0, pPos)*vec3.normalize(tmid)
		t2 = distanceFn(edge.p1, pPos)*vec3.normalize(tmid)
		t3 = distanceFn(edge.p1, pPos)*vec3.normalize(edge.t1)
		p0 = edge.p0
		p1 = pPos 
		p2 = pPos
		p3 = edge.p1
	end
	
	return { p0=p0, p1=p1, p2=p2, p3=p3, t0=t0, t1=t1, t2=t2, t3=t3, inputedge=edge, solutionConverged=solutionConverged}
end

function util.solveForPositionOnExistingEdge(pPos, edgeId)
	local edge = util.getEdge(edgeId)
	local p0 = util.nodePos(edge.node0)
	local p1 = util.nodePos(edge.node1)
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent1)
	return util.solveForPosition(pPos, { p0=p0, p1=p1, t0=t0, t1=t1 })
end

util.setupModuleDetailsForTemplate = function(modulebasics)
	local modules = {}
		for i,name in pairs(modulebasics) do
			local moduleIdx = api.res.moduleRep.find(name)
			if moduleIdx == -1 then 
				error("Module not found for "..name) -- cleaner error than passing it into the rep
			end 
			local detail = api.res.moduleRep.get(moduleIdx)
			modules[i]={
				metadata=util.deepClone(detail.metadata),
				name=name,
				updateScript= {
					fileName=detail.updateScript.fileName,
					params = util.deepClone(detail.updateScript.params)
				},
				variant = 0,
			}
		end
	return modules
end

function util.isFrozenNode(node)
	if util.frozenNodeCache and util.frozenNodeCache[node] then 
		return util.frozenNodeCache[node] >= 0 and util.frozenNodeCache[node] or false
	end 
	for i, edge in pairs(util.getSegmentsForNode(node) ) do
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
		if constructionId ~= -1 then
			local found = false 
			local construction = util.getConstruction(constructionId)
			for i, frozenNode in pairs(construction.frozenNodes) do
				if util.frozenNodeCache then 
					util.frozenNodeCache[node]=constructionId
				end 
				if frozenNode == node then 
					if util.frozenNodeCache then  
						found = true 
					else 
						return constructionId
					end 
				end
			end
			if found then 
				return constructionId
			end 
		end
	end
	if util.frozenNodeCache then 
		util.frozenNodeCache[node]=-1
	end 
	return false
end

function util.getConstructionEntityForNode(node)
	return util.isFrozenNode(node) -- actually returns constructionId
end 

function util.isNodeConnectedToFrozenEdge(node)
	if node < 0 then -- proposal node
		return false 
	end
	for i, edge in pairs(util.getSegmentsForNode(node) ) do
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
		if constructionId ~= -1 then
			return constructionId
		end
	end
	return false
end
function util.isFrozenEdge(edge) 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
	if constructionId ~= -1 then
		return constructionId
	--[[	local construction = util.getConstruction(constructionId)
		for i, frozenEdge in pairs(construction.frozenEdges) do
			if frozenEdge == edge then 
				return true
			end
		end]]--
	end
	return false
end
local waterLevel 
function util.getWaterLevel() 
	if not waterLevel then 
		local world = api.engine.util.getWorld()
		local terrain = util.getComponent(world, api.type.ComponentType.TERRAIN)
		waterLevel = terrain.waterLevel
	end 
	return waterLevel
end 

function util.isUnderwater(p) 
	return util.th(p) < util.getWaterLevel()
end

local thVec2f 
function util.th(p, useCurrentHeight) 
	if not thVec2f then 
		thVec2f = api.type.Vec2f.new(0,0) -- turns out that creating a new object each time is expensive, just recycle this as not concerned with thread safety
	end
	thVec2f.x = p.x 
	thVec2f.y = p.y
	return (useCurrentHeight and api.engine.terrain.getHeightAt(thVec2f) or
	api.engine.terrain.getBaseHeightAt(thVec2f))
end 

function util.maxTh(p) 
	return math.max(util.th(p), util.th(p, true))
end 

function util.minTh(p) 
	return math.min(util.th(p), util.th(p, true))
end 

util.setTangent = function(tangent, t) -- because tangent is mysterious "userdata", can't give it a vec3
	tangent.x = t.x
	tangent.y = t.y
	tangent.z = t.z
end

util.setTangent2d = function(tangent, t)  
	tangent.x = t.x
	tangent.y = t.y 
end
function util.setTangents(entity, t)  
	util.setTangent(entity.comp.tangent0, t)
	util.setTangent(entity.comp.tangent1, t)
end
util.rotateXYkeepingZ = function(v, angle)
-- https://stackoverflow.com/questions/4780119/2d-euclidean-vector-rotations
	return vec3.new(
		v.x * math.cos(angle) - v.y * math.sin(angle),
		v.x * math.sin(angle) + v.y * math.cos(angle),
		v.z -- z
	)
end

util.rotateXY = function(v, angle)
	local result = util.rotateXYkeepingZ(v, angle)
	result.z=0
	return result
end

function util.nodePointPerpendicularOffset(p,t, offset)
	if offset == 0 then 
		return p 
	end
	local perp = vec3.normalize(util.rotateXY( t, math.rad(90)))
	return offset * perp + p
end
util.doubleTrackNodePoint = function(p, t, invert) 
	return util.nodePointPerpendicularOffset(p, t, invert and -trackWidth or trackWidth)
end

function util.calcEdgeLength(p0, p1, t0, t1) -- more exact than other methods
	return hermite_length_gauss(p0, p1, t0,t1)
--[[
	if math.abs(util.signedAngle(t0, t1)) < math.rad(1) then 
		return util.distance(p0, p1)
	end
	return util.calcEdgeLengthFull(p0, p1, t0, t1) ]]--
end
function util.calcEdgeLengthFull(p0, p1, t0, t1) 
	local function derivative(t)
		local c0 = t0
		local c1 = 6 * (p1 - p0) - 4 * t0 - 2 * t1 -- only pre-defined vec3 objects!
		local c2 = 6 * (p0 - p1) + 3 * (t0 + t1)
		return vec3.length(c0 + t * (c1 + t * c2))
	end

	local gaussLengendreCoeff = {
		{0, .5688889},
		{-.5384693, .47862867},
		{.5384693, .47862867},
		{-.90617985, .23692688},
		{.90617985, .23692688}
	}

	local lg = 0
	for _, v in pairs(gaussLengendreCoeff) do
		lg = lg + derivative(.5 * (1 + v[1])) * v[2]
	end
	return .5 * lg
end

function util.calcEdgeLength2d(p0, p1, t0, t1)
	return util.calcEdgeLength(util.v2ToV3(p0), util.v2ToV3(p1), util.v2ToV3(t0), util.v2ToV3(t1))
end
function util.calculateSegmentLengthFromNewEdge(newEdge)
	return util.calcEdgeLength(newEdge.p0, newEdge.p1, newEdge.t0, newEdge.t1)
end

function util.correctTangentLengthsProposedEdge(edge)
	local tangentLength = util.calculateTangentLength(
		edge.p0, 
		edge.p1, 
		edge.t0,
		edge.t1)
	edge.t0 = tangentLength*vec3.normalize(edge.t0)
	edge.t1 = tangentLength*vec3.normalize(edge.t1)

end  

function util.correctTangentLengths(newEntity, nodePosFn)
	if not nodePosFn then 
		nodePosFn = util.nodePos 
	end 
 
	local tangentLength = util.calculateTangentLength(
		nodePosFn(newEntity.comp.node0), 
		nodePosFn(newEntity.comp.node1), 
		newEntity.comp.tangent0,
		newEntity.comp.tangent1)
	util.setTangent(newEntity.comp.tangent0, tangentLength*vec3.normalize(util.v3(newEntity.comp.tangent0)))
	util.setTangent(newEntity.comp.tangent1, tangentLength*vec3.normalize(util.v3(newEntity.comp.tangent1)))
end 

function util.fastNormalize(a) -- no vec3 objects, faster but more limited use cases
	local hypot = math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z)
	return {
		x = a.x / hypot,
		y = a.y / hypot,
		z = a.z / hypot
	}
	
end 

function util.calculateTangentLength(p0, p1, t0, t1, debugOutput)
	local angle = vec3.angleUnit(util.fastNormalize(t0),util.fastNormalize(t1))--math.abs(util.signedAngle(t0,t1))
	local dist = util.distance(p1, p0)
	if useTPFTangentCalculation then 
		return util.calcScale(dist, angle)
	end 


	if debugOutput then 
		trace("The angle was ",math.deg(angle), " the dist was ",dist)
	end 
	if angle < math.rad(15) then 
		return dist 
	end
	local naturalTangent = p1 - p0 
	local angle1 = util.signedAngle(t0, naturalTangent) 
	local angle2 = util.signedAngle(t1, naturalTangent)
	local sameSign = (angle1 > 0) == (angle2 > 0)
	if debugOutput then 
		trace("The angle1 was ",math.deg(angle1)," the angle2 was ",math.deg(angle2), " sameSign?",sameSign)
	end 
	--if math.abs(angle1) < angle and math.abs(angle2) < angle and not sameSign then
	--if angle > math.rad(30) then 
		local r = dist/(2*math.sin(angle/2))
		local length = (angle/math.rad(90)) * r * 4 * (math.sqrt(2)-1)
		if debugOutput then 
			trace("Based on circle approximation, r=",r, "length=",length)
		end 
		return length
	--end 
	--[[t0 = dist * vec3.normalize(t0)
	t1 = dist * vec3.normalize(t1)
	local lastTangentLength = dist 
	local lastEdgeLength =  util.calcEdgeLength(p0, p1, t0, t1)
	for i = 1, 10 do 
		t0 = lastEdgeLength * vec3.normalize(t0)
		t1 = lastEdgeLength * vec3.normalize(t1)
		local l = lastEdgeLength
		lastEdgeLength =  util.calcEdgeLength(p0, p1, t0, t1)
		if debugOutput then 
			trace("Calculated lastEdgeLength= ",lastEdgeLength," the lastTangentLength was ",lastTangentLength)
		end
		if lastEdgeLength <= lastTangentLength then 
			return lastTangentLength
		end 
		lastTangentLength = l
	end 
	return lastEdgeLength--]]
end

function util.calculateSegmentLengthFromEdge(edge)
	if type(edge)=="number" then 
		edge = util.getEdge(edge)
	end
	local p0 = util.nodePos(edge.node0)
	local p1 = util.nodePos(edge.node1)
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent1)
	return util.calcEdgeLength(p0, p1, t0, t1)
end

function util.getEdgeLength(edgeId) 
	return util.calculateSegmentLengthFromEdge(util.getEdge(edgeId))
end

function util.calculate2dSegmentLengthFromEdge(edge)
	local p0 = util.nodePos(edge.node0)
	local p1 = util.nodePos(edge.node1)
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent0)
	return util.calcEdgeLength2d(p0, p1, t0, t1)
end

function util.getDepotTangent(depotConstr)
	local edgeId = util.getComponent(depotConstr, api.type.ComponentType.CONSTRUCTION).frozenEdges[1]
	local edge = util.getEdge(edgeId)
	return vec3.normalize(util.v3(edge.tangent1))
end

util.straightConnectTwoNodes = function(node0, node1, streetType, nextEntityId)
	local entity =  api.type.SegmentAndEntity.new()
	entity.entity = nextEntityId
	entity.type=0 -- road
	entity.comp.node0=node0
	entity.comp.node1=node1
	local tangent = util.nodePos(node1)-util.nodePos(node0)
	util.setTangent(entity.comp.tangent0, tangent)	
	util.setTangent(entity.comp.tangent1, tangent)
	if type(streetType) == "string" then
		streetType = api.res.streetTypeRep.find(streetType)
	end
	entity.streetEdge.streetType = streetType
	return entity
end

function util.defaultStreetType()
	local streetType = api.res.streetTypeRep.find("standard/country_medium_new.lua")
	if util.year() < util.streetTypeRepGet(streetType).yearFrom then
		streetType = api.res.streetTypeRep.find("standard/country_small_old.lua")
	end
	return streetType
end

function util.isOriginalBridge(edgeId) 
	local edge = util.getEdge(edgeId) 
	if edge.type ~= 1 then 
		return false 
	end
	if util.getComponent(edgeId, api.type.ComponentType.PLAYER_OWNED) then 
		return false 
	end
	local streetEdge = util.getStreetEdge(edgeId) 
	if not streetEdge then 
		return false 
	end 
	local streetTypeName = api.res.streetTypeRep.getName(streetEdge.streetType) 
	if streetTypeName ~= "standard/country_small_old.lua" and streetTypeName ~= "standard/country_small_new.lua"
		and streetTypeName ~= "standard/town_small_old.lua" and streetTypeName ~= "standard/town_small_new.lua" then 
		return false 
	end 
	
	if util.th(util.getEdgeMidPoint(edgeId)) > 0 then 
		return false 
	end 
	if streetTypeName == "standard/country_small_old.lua" and api.res.bridgeTypeRep.getName(edge.typeIndex) ~= "stone.lua" then 
		return false 
	end 
	return edge.tangent0.z > 0 and edge.tangent1.z < 0	
end

function util.smallCountryStreetType()
	local streetType = api.res.streetTypeRep.find("standard/country_small_new.lua")
	if util.year() < util.streetTypeRepGet(streetType).yearFrom then
		streetType = api.res.streetTypeRep.find("standard/country_small_old.lua")
	end
	return streetType
end
function util.mediumCountryStreetType()
	local streetType = api.res.streetTypeRep.find("standard/country_medium_new.lua")
	if util.year() < util.streetTypeRepGet(streetType).yearFrom then
		streetType = api.res.streetTypeRep.find("standard/country_medium_old.lua")
	end
	return streetType
end

function util.buildShortStubRoadWithPosition(newProposal, node, position,streetType, nextEntityId)
	trace("buildShortStubRoadWithPosition: begin. Got node=",node,"nextEntityId=",nextEntityId)
	--trace(debug.traceback())
	local newNode = util.newNodeWithPosition(position)
	if not nextEntityId then nextEntityId = -1-#newProposal.streetProposal.edgesToAdd end
	if not streetType then streetType = util.smallCountryStreetType() end
	if type(streetType)=="string" then 
		streetType = api.res.streetTypeRep.find(streetType)
	end
	local entity =  api.type.SegmentAndEntity.new()
	entity.entity = nextEntityId
	newNode.entity = 1000*nextEntityId
	entity.type=0 -- road
	local nodeId
	local tangent0
	local tangent1
	local function nodePos(node)
		if node > 0 then 
			return util.nodePos(node)
		else 
			for i, nodeEntity in pairs(newProposal.streetProposal.nodesToAdd) do 
				if nodeEntity.entity == node then 
					return util.v3(nodeEntity.comp.position)
				end 
			end 
		end 
	end 
	if type(node)=="table" then
		local newNode2 = util.newNodeWithPosition(node)
		newNode2.entity = newNode.entity-1
		newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode2
		trace("buildShortStubRoadWithPosition: added newNode2 with entity",newNode2.entity)
		nodeId = newNode2.entity
		tangent0 = position - node
		tangent1 = tangent0
	else 
		nodeId = node
		tangent0 = position-nodePos(node)
		tangent1 = tangent0
		if node > 0 and #util.getStreetSegmentsForNode(node) > 1 then 
			local maxAngle = 0
			local trialRotation1 = util.rotateXY(tangent0, math.rad(30))
			local trialRotation2 = util.rotateXY(tangent0, -math.rad(30))
			local maxAngle1 = 0 
			local maxAngle2 = 0
			local minAngle = math.rad(360)
			for k, seg in pairs(util.getSegmentsForNode(node)) do 
					 
				local otherSeg = util.getEdge(seg)
				local ourNode0 = true
				local theirNode0 = otherSeg.node0 == node
				
				local theirTangent = util.v3(theirNode0 and otherSeg.tangent0 or otherSeg.tangent1) 
				if ourNode0 == theirNode0 then 
					theirTangent = -1*theirTangent
				end 
				local angle = math.abs(util.signedAngle(tangent0, theirTangent))
				trace("Inspecing angle between",edgeId, seg," angle was ",math.deg(angle))
				maxAngle=math.max(maxAngle, angle)
				minAngle = math.min(minAngle, angle)
				maxAngle1 = math.max(maxAngle1, math.abs(util.signedAngle(trialRotation1, theirTangent)))
				maxAngle2 = math.max(maxAngle2, math.abs(util.signedAngle(trialRotation2, theirTangent)))
			end 
			trace("The max angle to another component was",math.deg(maxAngle)," other rotation trials were ",math.deg(maxAngle1) , math.deg(maxAngle2),"minAngle=",math.deg(minAngle))
			if maxAngle > math.rad(120) then 
				
				local correction = maxAngle - math.rad(120)
				if math.abs(correction-minAngle) < math.rad(10) then 
					trace("Limiting the correction from",math.deg(correction),"because of min angle",math.deg(minAngle))
					correction = correction / 2
				end 
				trace("Attempting  to correct, correction is ", math.deg(correction))
				if maxAngle1 < maxAngle and maxAngle1 < maxAngle2 then 
					tangent0 = util.rotateXY(tangent0, correction)
					trace("Applying positive correction")
				elseif maxAngle2 < maxAngle then 
					trace("Applying negative correction")
					tangent0 = util.rotateXY(tangent0, -correction)
				else 
					trace("Not applying correction")
				end
				for k, seg in pairs(util.getSegmentsForNode(node)) do 
					 
					local otherSeg = util.getEdge(seg)
					local ourNode0 = true
					local theirNode0 = otherSeg.node0 == node
					
					local theirTangent = util.v3(theirNode0 and otherSeg.tangent0 or otherSeg.tangent1) 
					if ourNode0 == theirNode0 then 
						theirTangent = -1*theirTangent
					end 
					local angle = math.abs(util.signedAngle(tangent0, theirTangent))
					trace("Inspecing angle between",edgeId, seg," angle was ",math.deg(angle))	
				end
			end 
		end 
		
	end
	
	entity.comp.node0=nodeId
	entity.comp.node1=newNode.entity
	
	util.setTangent(entity.comp.tangent0, tangent0)	
	util.setTangent(entity.comp.tangent1, tangent1)
	entity.streetEdge.streetType = streetType
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
	trace("buildShortStubRoadWithPosition: complete, created entity",entity.entity," linking",entity.comp.node0, entity.comp.node1,"streetType=",streetType)
end

function util.areStationsConnectedWithLine(station1, station2) 
	if station1 and station2 then 
		local group1 = api.engine.system.stationGroupSystem.getStationGroup(station1)
		local group2 = api.engine.system.stationGroupSystem.getStationGroup(station2)
		local lineStops2 = util.deepClone(api.engine.system.lineSystem.getLineStops(group2))
		for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStops(group1))) do 
			for j, lineId2 in pairs(lineStops2) do 
				if lineId == lineId2 then
					return lineId
				end
			end
		end
	end
	trace("station, ",station1, " and ", station2," were NOT connected with a line")
	return false
end

function util.buildShortStubRoad(newProposal, node, streetType, nextEntityId, offset)

	local edgeId = util.getStreetSegmentsForNode(node) [1]
	local edge = util.getEdge(edgeId)
	local tangent = node == edge.node1 and util.v3(edge.tangent1) or -1*util.v3(edge.tangent0)
	local startNodePos = util.nodePos(node)
	if not offset then offset = 40 end
	local newNodePos = startNodePos + offset*vec3.normalize(tangent)
	util.buildShortStubRoadWithPosition(newProposal, node, newNodePos, streetType,  nextEntityId)
end
local function basicSearchForPositionOnEdge(edge, position)
	local vector = util.vecBetweenNodes(edge.node1, edge.node0)
	for i = 0, 10 do
		local searchPos = 0.1*i*vector + util.nodePos(edge.node0)
		if util.distance(searchPos, position) <= 10 then
			return searchPos
		end
	end
	if not edge.tangent0 then 
		--debugPrint(edge)
		edge = util.getEdge(edge.id)
	end
	local existingEdge = { t0 = util.v3(edge.tangent0), t1=util.v3(edge.tangent1), p0=util.nodePos(edge.node0), p1=util.nodePos(edge.node1)}
	return util.solveForPosition(position, existingEdge).p
end

function util.splitRoadNearPointAndJoin(newProposal, edgeId, position, otherPosition)	
	--local p = util.solveForPositionOnExistingEdge(position, edgeId).p1
	trace("splitRoadNearPointAndJoin begin: got edgeId=",edgeId)
	if type(position) == "number" then 
		trace("Got position as number, assuming node")
		position = util.nodePos(position)
	end 
	local edge = util.getEdge(edgeId)
	local p = basicSearchForPositionOnEdge(edge, position)
	trace("For edgeId got",edgeId,"position=",position,"p=",p)
	if util.positionsEqual(p, util.nodePos(edge.node0)) or util.positionsEqual(p, util.nodePos(edge.node1)) then 
		
		local nodeToUse = util.positionsEqual(p, util.nodePos(edge.node0)) and edge.node0 or edge.node1
		trace("WARNING! Attempted to split road near point at the same points as the start or end, using",nodeToUse)
		local newNode2 = util.newNodeWithPosition(otherPosition, -1000-#newProposal.streetProposal.nodesToAdd  )
	 
		local entity3 =  util.copyExistingEdge(edgeId, -1-#newProposal.streetProposal.edgesToAdd  )
		 
		entity3.comp.node0 = newNode2.entity
		entity3.comp.node1 = nodeToUse
		local tangent = p-otherPosition
		local t0 = tangent 
		local t1 = tangent
		
		for i, seg in pairs(util.getSegmentsForNode(nodeToUse)) do 
			local otherEdge = util.getEdge(seg)
			local theyNode0 = otherEdge.node0 == nodeToUse
			local theirTangent = theyNode0 and util.v3(otherEdge.tangent0) or -1*util.v3(otherEdge.tangent1)
			local angle = util.signedAngle(theirTangent, tangent)
			trace("Build link road, inspecting angle to other edge",seg,"was",math.deg(angle))
			if math.abs(angle) < math.rad(10) then 
				trace("Shallow angle detected attempting to correct")
				local sign = angle > 0  and -1 or 1 
				t0 = util.rotateXYkeepingZ(t0, sign*math.rad(30))
				trace("After rotation the angle was",util.signedAngle(theirTangent, t0))
			end 
			
		
		end 
		util.setTangent(entity3.comp.tangent0, t0)	
		util.setTangent(entity3.comp.tangent1, t1)
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity3
		newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode2
		
		return
	end 
	
	local newNode = util.newNodeWithPosition(p)
	local nextEntityId = -1-#newProposal.streetProposal.edgesToAdd  
	
	local entity =  util.copyExistingEdge(edgeId)
	entity.entity = nextEntityId
	newNode.entity = -1000-#newProposal.streetProposal.nodesToAdd  
	entity.comp.node1 = newNode.entity
	util.setTangent(entity.comp.tangent0, p-util.nodePos(entity.comp.node0))	
	util.setTangent(entity.comp.tangent1, p-util.nodePos(entity.comp.node0))
	 
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
	trace("splitRoadNearPointAndJoin begin: added entity",entity.entity," connecting",entity.comp.node0, entity.comp.node1)
	local entity2 =  util.copyExistingEdge(edgeId)
	entity2.entity = nextEntityId-1
	entity2.comp.node0 = newNode.entity
	util.setTangent(entity2.comp.tangent0, util.nodePos(entity2.comp.node1)-p)	
	util.setTangent(entity2.comp.tangent1, util.nodePos(entity2.comp.node1)-p)
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity2
	newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
	trace("splitRoadNearPointAndJoin begin: added entity2",entity2.entity," connecting",entity2.comp.node0, entity2.comp.node1)
	local newNode2 = util.newNodeWithPosition(otherPosition)
	newNode2.entity = newNode.entity -1
	local entity3 =  util.copyExistingEdge(edgeId)
	entity3.entity = nextEntityId-2
	entity3.comp.node0 = newNode2.entity
	entity3.comp.node1 = newNode.entity
	util.setTangent(entity3.comp.tangent0, p-otherPosition)	
	util.setTangent(entity3.comp.tangent1, p-otherPosition)
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity3
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode2
	trace("splitRoadNearPointAndJoin begin: added entity3",entity2.entity," connecting",entity3.comp.node0, entity3.comp.node1)
	if util.tracelog then 
		debugPrint(newProposal) 
	end 
	return newNode.entity 
end

function util.isDepotContainingVehicles(depot) 
	local vehicles = api.engine.system.transportVehicleSystem.getVehiclesWithState(api.type.enum.TransportVehicleState.IN_DEPOT)
	local entityFull = util.getEntity(depot)
	if  entityFull and  entityFull.type == "CONSTRUCTION" then 
		depot = util.getConstruction(depot).depots[1]
	end 
	trace("Checking ",#vehicles," to see if they are in depot",depot)
	for j , vehicle in pairs(vehicles) do 
		local vehicleDetail = util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		if vehicleDetail.depot == depot then 
			return true 
		end 
	end 
	return false
end 

util.transf2Mat4f = function(trnsf)
	local vec4fs = {}
	for i = 1, 16, 4 do
		table.insert(vec4fs, api.type.Vec4f.new(trnsf[i], trnsf[i+1], trnsf[i+2], trnsf[i+3]))
	end
	
	return api.type.Mat4f.new(vec4fs[1], vec4fs[2],vec4fs[3],vec4fs[4]);
end

function util.getFreeNodesForConstruction(constructionId) 
	if util.freeNodesForConstructionCache and util.freeNodesForConstructionCache[constructionId] then 
		return util.freeNodesForConstructionCache[constructionId]
	end
	local construction = util.getConstruction(constructionId)
	local isTerminus=  false 

	if string.find(construction.fileName, "rail") then 
		isTerminus =    util.isStationTerminus(constructionId)
		
	end 
	local frozenNodeSet = {}
	for i, node in pairs(construction.frozenNodes) do
		frozenNodeSet[node]=true
		if util.frozenNodeCache and not util.frozenNodeCache[node] then 
			util.frozenNodeCache[node]=constructionId 
		end
	end
	local result = {}
	for i, edgeId in pairs(construction.frozenEdges) do
		local edge = util.getEdge(edgeId)
		if not frozenNodeSet[edge.node0] then
			table.insert(result, edge.node0)
		elseif not frozenNodeSet[edge.node1] then
			table.insert(result, edge.node1)
		end
	end
	if isTerminus then -- have to get the nodes at the correct end
		local bbox =  util.getComponent(constructionId, api.type.ComponentType.BOUNDING_VOLUME).bbox
		local mins = util.v3(bbox.min)
		local maxes = util.v3(bbox.max)
		local numTracks = 0 
		for __, stationId in pairs(util.getConstruction(constructionId).stations) do 
			numTracks = numTracks + #util.getStation(stationId).terminals
		end 
		local positionVector =  construction.transf:cols(3)
		local rotationVector = construction.transf:cols(1)
		
		local expectedPosition = util.v3(positionVector)+80* util.v3(rotationVector)
		local dists = {} 
		local distToNodeMap = {}
		for i, node in pairs(result) do
			local nodePos = util.nodePos(node)
			--local minDist = math.min(util.distance(nodePos, mins), util.distance(nodePos,maxes))
			local minDist =util.distance(nodePos, expectedPosition)
			while distToNodeMap[minDist] do
				minDist = minDist + 0.01
			end
			distToNodeMap[minDist] = node
			table.insert(dists, minDist)
		end
		table.sort(dists)
		
		local newResult = {}
		for i = 1, numTracks do
			table.insert(newResult, distToNodeMap[dists[i]])
		end
		trace("is a terminus #dists=",#dists," numTracks=",numTracks, " #newResult=",#newResult)
		if util.tracelog then 
			debugPrint({dists=dists, newResult=newResult, distToNodeMap=distToNodeMap, originalresult=result})
			--trace(debug.traceback())
		end
		if util.freeNodesForConstructionCache   then 
			util.freeNodesForConstructionCache[constructionId]=newResult
		end 
		return newResult
	end
	trace("Free nodes for constructionId=",constructionId," found ",#result)
	if util.freeNodesForConstructionCache   then 
		util.freeNodesForConstructionCache[constructionId]=result
	else 
		trace("Frozen node cache not active")
		trace(debug.traceback())
	end
	return result
end

function util.getStreetWidth(streetType)
	if type(streetType)=="string" then
		streetType = api.res.streetTypeRep.find(streetType)
	end
	local streetTypeDetail = util.streetTypeRepGet(streetType)
	return streetTypeDetail.streetWidth + 2*streetTypeDetail.sidewalkWidth
end

function util.getRoadSpeedLimit(edgeId) 
	local streetEdge = util.getStreetEdge(edgeId)
	return util.streetTypeRepGet(streetEdge.streetType).speed
end

function util.getPerpendicularTangentAwayFromIndustry(edgeId)
	local midPos = util.getEdgeMidPoint(edgeId)
	local industry = util.searchForFirstEntity(midPos, 200, "SIM_BUILDING")
	return midPos - util.v3fromArr(industry.position)
end

function util.getEdgeWidth(edgeId, assumeDoubleTrack)
	local trackEdge = util.getTrackEdge(edgeId)
	if trackEdge then 
		return assumeDoubleTrack and 2*trackWidth or trackWidth
	end
	local streetEdge = util.getStreetEdge(edgeId)
	return util.getStreetWidth(streetEdge.streetType)
end

function util.reverseNewEntity(entity )	
	local temp = entity.comp.node1
	entity.comp.node1 = entity.comp.node0
	entity.comp.node0 = temp 
	temp = util.v3(entity.comp.tangent1) 
	util.setTangent(entity.comp.tangent1, -1*util.v3(entity.comp.tangent0))
	util.setTangent(entity.comp.tangent0, -1*temp)
end

function util.isTrackNode(node) 
	if type(node)=="table" then 
		node = node.id
	end
	return #util.getTrackSegmentsForNode(node)> 0
end
function util.isStreetNode(node) 
	if type(node)=="table" then 
		node = node.id
	end
	return #util.getStreetSegmentsForNode(node)> 0
end

function util.createCombinedEdge(pLeft, pMid, pRight)
	--local leftLength = util.calcEdgeLength(pLeft.p, pMid.p, pLeft.t2, pMid.t)
	--local rightLength = util.calcEdgeLength(pMid.p, pRight.p, pMid.t2, pRight.t)
	--local newLength = util.calculateTangentLength(pLeft.p, pRight.p, pLeft.t2, pRight.t)
	local newLength = util.distance(pLeft.p, pMid.p)+util.distance(pMid.p, pRight.p)
	return util.applyEdgeAutoTangents({
		p0 = pLeft.p,
		p1 = pRight.p, 
		t0 = newLength*vec3.normalize(pLeft.t2),
		t1 = newLength*vec3.normalize(pRight.t)
	})
end
function util.createCombinedEdgeFromExistingEdges(leftEdgeId, rightEdgeId)
	local leftEdge = util.getEdge(leftEdgeId)
	local rightEdge =util.getEdge(rightEdgeId)
	
	local leftNode
	local midNode
	local rightNode 
	local leftTangent
	local rightTangent 
	local midTangent1
	local midTangent2
	
	if leftEdge.node0 == rightEdge.node1 then
		midNode = leftEdge.node0 
		leftNode = rightEdge.node0
		leftTangent = util.v3(rightEdge.tangent0)
		midTangent1 = util.v3(rightEdge.tangent1)
		midTangent2 = util.v3(leftEdge.tangent0)
		rightTangent = util.v3(leftEdge.tangent1)
		rightNode = leftEdge.node1 
	elseif leftEdge.node0 == rightEdge.node0 then 
		midNode = leftEdge.node0 
		leftNode = leftEdge.node1
		leftTangent = -1*util.v3(leftEdge.tangent1)
		midTangent1 = -1*util.v3(leftEdge.tangent0)
		midTangent2 = util.v3(rightEdge.tangent0)
		rightTangent = util.v3(rightEdge.tangent1)
		rightNode = rightEdge.node1 
	elseif leftEdge.node1 == rightEdge.node1 then 
		midNode = leftEdge.node1
		leftNode = leftEdge.node0
		leftTangent = util.v3(leftEdge.tangent0)
		midTangent1 = util.v3(leftEdge.tangent1)
		midTangent2 = -1*util.v3(rightEdge.tangent1)
		rightTangent = -1*util.v3(rightEdge.tangent0)
		rightNode = rightEdge.node0 
	else 
		assert(leftEdge.node1 == rightEdge.node0)
		midNode = leftEdge.node1
		leftNode = leftEdge.node0
		leftTangent = util.v3(leftEdge.tangent0)
		midTangent1 = util.v3(leftEdge.tangent1)
		midTangent2 = util.v3(rightEdge.tangent0)
		rightTangent = util.v3(rightEdge.tangent1)
		rightNode = rightEdge.node1
	end
	local pLeft = { p = util.nodePos(leftNode), t = leftTangent, t2 = leftTangent } 
	local pMid =  { p = util.nodePos(midNode), t =  midTangent1, t2 = midTangent2 } 
	local pRight =  { p = util.nodePos(rightNode), t = rightTangent, t2 = rightTangent } 
	return util.createCombinedEdge(pLeft, pMid, pRight)
end
function util.getStreetEdge(edgeId) 
	if not api.engine.entityExists(edgeId) then 
		error("No entity exists with id: "..tostring(edgeId))
	end 
	return util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
end
function util.getTrackEdge(edgeId) 
	return util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_TRACK)
end
function util.getEmbankmentSlopeHigh(edgeId) 
	local streetEdge = util.getStreetEdge(edgeId)
	if streetEdge then 
		return util.streetTypeRepGet(streetEdge.streetType).embankmentSlopeHigh
	end
	local trackEdge = util.getTrackEdge(edgeId)
	local trackRes = api.res.trackTypeRep.get(trackEdge.trackType)
	return trackRes.embankmentSlopeHigh
end 


function util.calculateCollisionBoxSize(tOurs, tTheirs, ourWidth, theirEdgeId, zOffset)
	if not zOffset then zOffset = 12 end
	local crossingAngle = util.signedAngle(vec3.normalize(tTheirs), vec3.normalize(tOurs))
	if crossingAngle ~= crossingAngle then 
		debugPrint({nanAngle=crossingAngle, tOurs=tOurs, tTheirs=tTheirs}) 
	end
	if math.abs(crossingAngle) > math.rad(90) then 
		crossingAngle = math.rad(180)-math.abs(crossingAngle)
	end

	local theirWidth = util.getEdgeWidth(theirEdgeId, true) -- assume the other is double track
	if util.getStreetTypeCategory(theirEdgeId)=="highway" then 
		theirWidth = theirWidth*2 + 10 
	end
	local numDoubleTrackEdges  =  #util.findDoubleTrackEdges(theirEdgeId) 
	trace("The numDoubleTrackEdges for ",theirEdgeId, " was ",numDoubleTrackEdges)
	if numDoubleTrackEdges > 1 then
		theirWidth = theirWidth + numDoubleTrackEdges*trackWidth
	end 	
	local sinf =math.sin(math.abs(crossingAngle))
	local tanf =math.tan(math.abs(crossingAngle))
	local minimumOffsetGap = 2*(zOffset / util.getEmbankmentSlopeHigh(theirEdgeId))/sinf
	local theirRequiredSpan = minimumOffsetGap + ourWidth / sinf + theirWidth / tanf  
	local ourRequiredSpan = minimumOffsetGap + theirWidth / sinf + ourWidth / tanf 
	trace("calculated ourRequiredSpan=",ourRequiredSpan," theirRequiredSpan=",theirRequiredSpan," angle=",math.deg(crossingAngle)," sinf=",sinf," tanf=",tanf, " ourWidth=",ourWidth, " theirWidth=",theirWidth, "minimumOffsetGap=",minimumOffsetGap)
	return {
		theirRequiredSpan = math.ceil(theirRequiredSpan), -- round up to avoid strange bridge effects
		ourRequiredSpan = math.ceil(ourRequiredSpan)
	}
end

function util.searchForEntities(p, range, entityType, excludeData)
	local pos =p 
	if pos.x then 
		pos ={p.x, p.y}
	end
	return game.interface.getEntities({radius=range,pos = pos}, {type=entityType, includeData=not excludeData})
end
function util.searchForFirstEntity(p, range, entityType, filterFn)
	if not filterFn then filterFn = function() return true end end 
	for i, entity in pairs(util.searchForEntities(p, range, entityType)) do 
		if filterFn(entity) then 
			return entity
		end
	end
end

function util.searchForEntitiesWithFilter(p, range, entityType, filterFn)
	local res = {}
	for i, entity in pairs(util.searchForEntities(p, range, entityType)) do 
		if filterFn(entity) then 
			table.insert(res, entity)
		end
	end
	return res 
end

function util.searchForNearestIndustry(p, range) 
	if not range then range = 200 end 
	local result = {} 
	for industryId, industry in pairs(util.searchForEntities(p, range, "SIM_BUILDING")) do 
		table.insert(result, industry)
	end 
	if #result ==0 then return end 
	return util.evaluateWinnerFromSingleScore(result, function(industry) return util.distance(util.v3fromArr(industry.position), p)end)
end 

function util.setTangentsForStraightEdgeBetweenPositions(newEntity, node0Pos, node1Pos)
	local tangent = node1Pos - node0Pos
	util.setTangent(newEntity.comp.tangent0, tangent)
	util.setTangent(newEntity.comp.tangent1, tangent)
end
function util.setTangentsForStraightEdgeBetweenPositionsFlattened(newEntity, node0Pos, node1Pos)
	local dist = util.distance(node0Pos, node1Pos)
	local tangent = node1Pos - node0Pos
	tangent.z = 0 
	tangent = dist*vec3.normalize(tangent)
	util.setTangent(newEntity.comp.tangent0, tangent)
	util.setTangent(newEntity.comp.tangent1, tangent)
end

function util.setTangentsForStraightEdgeBetweenExistingNodes(newEntity)
	local node0 = newEntity.comp.node0
	local node1 = newEntity.comp.node1
	local node0Pos = util.nodePos(node0)
	local node1Pos = util.nodePos(node1)
	--util.setTangentsForStraightEdgeBetweenPositions(newEntity, node0Pos, node1Pos)
	local proposedTangent = node1Pos - node0Pos
	
	local function checkAngles(node, ourNode0) 
		local maxAngle = 0
		local tangent = proposedTangent
		local trialRotation1 = util.rotateXY(tangent, math.rad(30))
		local trialRotation2 = util.rotateXY(tangent, -math.rad(30))
		local maxAngle1 = 0 
		local maxAngle2 = 0
		for k, seg in pairs(util.getSegmentsForNode(node)) do 
				 
			local otherSeg = util.getEdge(seg)
			local theirNode0 = otherSeg.node0 == node
			
			local theirTangent = util.v3(theirNode0 and otherSeg.tangent0 or otherSeg.tangent1) 
			if ourNode0 == theirNode0 then 
				theirTangent = -1*theirTangent
			end 
			local angle = math.abs(util.signedAngle(tangent, theirTangent))
			trace("Inspecing angle between",edgeId, seg," angle was ",math.deg(angle))
			maxAngle=math.max(maxAngle, angle)
			maxAngle1 = math.max(maxAngle1, math.abs(util.signedAngle(trialRotation1, theirTangent)))
			maxAngle2 = math.max(maxAngle2, math.abs(util.signedAngle(trialRotation1, theirTangent)))
		end 
		trace("The max angle to another component was",math.deg(maxAngle)," other rotation trials were ",math.deg(maxAngle1) , math.deg(maxAngle2))
		if maxAngle > math.rad(120) then 
			
			local correction = maxAngle - math.rad(120)
			trace("Attempting  to correct, correction is ", math.deg(correction))
			if maxAngle1 < maxAngle and maxAngle1 < maxAngle2 then 
				tangent = util.rotateXY(tangent, correction)
			elseif maxAngle2 < maxAngle then 
				tangent = util.rotateXY(tangent, -correction)
			end 
		end 
		return tangent
	end
	util.setTangent(newEntity.comp.tangent0, checkAngles(node0, true) )
	util.setTangent(newEntity.comp.tangent1, checkAngles(node1, false) ) 
end
function util.scoreDistanceFromEdge(p, edgeId) 
	local edge = util.getEdge(edgeId)
	return math.min(util.distance(p, util.nodePos(edge.node0)), math.min(util.distance(p, util.getEdgeMidPoint(edgeId)), util.distance(p, util.nodePos(edge.node1)))) 
end 

function util.searchForNearestEntity(p, range, entityType, filterFn)
	local nodes = {} 
	if not range then range = 10 end
	if not filterFn then filterFn = function() return true end end
	if not p.x then p = util.v3fromArr(p) end
	for i ,node in pairs(util.searchForEntities(p, range, entityType)) do
		if filterFn(node) then 
			table.insert(nodes, node)
		end
		
	end
	
	return util.evaluateWinnerFromSingleScore(nodes, 
		function(p2)	
			if p2.type == "BASE_EDGE" then 
				return  util.scoreDistanceFromEdge(p, p2.id)
			end
			if p2.type == "TOWN_BUILDING" then 
--				local constructionId = p2.stockList
				local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(p2.id)
				return   util.distance(p, util.getConstructionPosition(constructionId) )
			end
			return util.distance(p, util.v3fromArr(p2.position)) 
		end
	) 
end
function util.searchForNearestStation(p, range, filterFn)
	local stations = {} 
	if not range then range = 200 end
	if not filterFn then filterFn = function() return true end end
	for i ,station in pairs(util.searchForEntities(p, range, "STATION")) do
		if filterFn(station) then 
			table.insert(stations, station.id)
		end
		
	end
	
	return util.evaluateWinnerFromSingleScore(stations, 
	function(s) return util.distance(p, util.getStationPosition(s)) end) 
end
function util.searchForNearestTrainStation(p, range)
	local filterFn = function(station) 
		return station.carriers.RAIL 
	end 
	return util.searchForNearestStation(p, range, filterFn)
end
function util.searchForNearestNode(p, range, filterFn)
	if type(p) =="number" then 
		p = util.nodePos(p)
	end 
	local nodes = {} 
	if not range then range = 10 end
	if not filterFn then filterFn = function() return true end end
	if not p.x then p = util.v3fromArr(p) end
	for i ,node in pairs(util.searchForEntities(p, range, "BASE_NODE")) do
		if filterFn(node) then 
			table.insert(nodes, node)
		end
		
	end
	
	return util.evaluateWinnerFromSingleScore(nodes, 
		function(p2)
			local v3p = util.v3fromArr(p2.position) -- not inline for debug purposes
			return util.distance(p, v3p) 
		end) 
end

function util.findMostCentralTownNode(town, allowNonUrbanRoads, range) 
	if type(town)=="number" then 
		town = util.getEntity(town)
	end 
	if not range then range = 100 end
	
	local options = {}
	local canAccept = function(node) 
		if #util.getTrackSegmentsForNode(node.id)>0 then 
			return false 
		end 
		if math.abs(node.position[3]-util.th(util.v3fromArr(node.position))) > 10 then 
			return false 
		end 
		local segs = util.getStreetSegmentsForNode(node.id)
		 
		for i, seg in pairs(segs) do 
			if util.getStreetTypeCategory(seg) == "highway" then 
				return false 
			end
		end 
		for i, seg in pairs(segs) do 
			if util.getEdge(seg).type~=0 then 
				return false 
			end
		end 
		if not allowNonUrbanRoads then 
			for i, seg in pairs(segs) do 
				if util.getStreetTypeCategory(seg) ~= "urban" then 
					return false 
				end
			end 
		end
		return true 	
	end 
	for i, node in pairs(util.searchForEntities(town.position, range, "BASE_NODE")) do 
		if canAccept(node) then 
			table.insert(options, {
				node = node, 
				scores = {
					util.distanceArr(town.position, node.position),
					1/#util.getStreetSegmentsForNode(node.id)--more is better 				
				}			
			})
		end 
	end 

	if #options ==0  and not allowNonUrbanRoads then 
		return util.findMostCentralTownNode(town, true, range) -- support mods that use a different street category
	end 
	if #options == 0 and range <= 100 then 
		return  util.findMostCentralTownNode(town, true, 2*range)
	end 
	if #options == 0 then 
		trace("WARNING! Unable to find a node for town",town.name)
		return 
	end 
	return util.evaluateWinnerFromScores(options).node
end  

function util.searchForNearestEdge(p, range, filterFn)
	local edges = {} 
	if not filterFn then filterFn = function() return true end end
	for i ,edgeId in pairs(util.searchForEntities(p, range, "BASE_EDGE", true)) do
		if filterFn(edgeId) then 
			table.insert(edges, edgeId)
		end
		
	end
	
	return util.evaluateWinnerFromSingleScore(edges, 
	function(edge) return util.distance(p, util.getEdgeMidPoint(edge)) end) 
end

function util.getUserCargoName(systemName)
	if not util.cargoUserNameCache then 
		util.cargoUserNameCache = {}
	end
	if not util.cargoUserNameCache[systemName] then 
		local idx = type(systemName) == "number" and systemName or api.res.cargoTypeRep.find(systemName)
		util.cargoUserNameCache[systemName]= api.res.cargoTypeRep.get(idx).name 
	end 
	return util.cargoUserNameCache[systemName]
end 
function util.getMapAreaKm2()
	local mapBoundary = util.getMapBoundary()
	return( 4*mapBoundary.x*mapBoundary.y)/(1000*1000)
end 
function util.getMapOfUserToSystemNames() 
	if not util.mapOfUserToSystemNames then 
		util.mapOfUserToSystemNames = {}
		for i, name in pairs(util.deepClone(api.res.cargoTypeRep.getAll())) do 
			util.mapOfUserToSystemNames[util.getUserCargoName(name)]=name
		end 
		
	end 
	return util.mapOfUserToSystemNames
end 

function util.isDoubleSlipSwitch(node)
	local nodeComp = util.getNode(node)
	return nodeComp.doubleSlipSwitch
end

function util.findNextEdgeInSameDirection(edgeId, node, mapFn, allowFrozenEdges)
	local edge = util.getEdge(edgeId)

	if not mapFn then 
		mapFn = util.getEntity(edgeId).track and util.getTrackSegmentsForNode or util.getStreetSegmentsForNode
	end
	local nextSegs = mapFn(node) 
	if #nextSegs == 2 then -- common case performance shortcut
		return edgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
	end 
	if #nextSegs  == 3 then 
		if node > 0 then 
			if #util.getStreetSegmentsForNode(node) == 3 then 
				local outboundEdge = util.getOutboundNodeDetailsForTJunction(node) 
				if edgeId == outboundEdge.edgeId then 
					trace("Not returning edge because the ",edgeId," for node ",node, " was a T-junction")
					return
				end 
			end 
		end 
	end 
	local isNode0  =  node == edge.node0
	local tangentToUse = isNode0 and -1*util.v3(edge.tangent0) or util.v3(edge.tangent1)
	local fallback
	local candidates = {} 
	for i, seg in pairs(nextSegs) do
		if seg ~= edgeId then
			local edge2 = util.getEdge(seg)
			local theyNode0 = node == edge2.node0
			local otherTangentToUse = theyNode0 and util.v3(edge2.tangent0) or  -1*util.v3(edge2.tangent1)
			local angle = math.abs(util.signedAngle(tangentToUse, otherTangentToUse))
			if angle> math.rad(90) then 
--				angle = math.abs(math.rad(180)-angle)
			end
			trace("comparing ",seg," with ", edgeId," the signedAngle was ",math.deg(angle),"around node",node)
			local tolerance = util.getComponent(seg, api.type.ComponentType.BASE_EDGE_TRACK) and math.rad(5) or math.rad(20)
			if angle < tolerance and (allowFrozenEdges or not util.isFrozenEdge(seg)) then
				local priorNode = node == edge.node0 and edge.node1 or edge.node0
				local expectedNextNode = node == edge2.node0 and edge2.node1 or edge2.node0
				local distPriorToNext =  util.distBetweenNodes(priorNode, expectedNextNode)
				local distFromPrior = util.distBetweenNodes(priorNode, node) 
				local naturalTangent2 = util.nodePos(edge2.node1)-util.nodePos(edge2.node0)
				if theyNode0 then 
					naturalTangent2 = -1*naturalTangent2
				end 
				local comparisonTangent = tangentToUse
				if theyNode0 == isNode0 then 
					comparisonTangent = -1*tangentToUse
				end 
				local angle2 = math.abs(util.signedAngle(comparisonTangent, naturalTangent2))
				trace("comparing ",seg," with ", edgeId," the distPriorToNext was ",distPriorToNext, " distFromPrior was ",distFromPrior,"angle2=",math.deg(angle2))
				--if distPriorToNext >  distFromPrior then
					trace("findNextEdgeInSameDirection: adding seg as candidate ",seg)
					table.insert(candidates, {
						edgeId = seg, 
						scores = { 
							angle,
							angle2 -- use the other tangent as a tie break
						}
					})
				--else 
				--	trace("findNextEdgeInSameDirection: NOT adding seg as candidate",seg)
				--end
			end
			if not fallback or util.isFrozenEdge(fallback) then
				fallback = seg
			end
		end
	end
	if #candidates == 0 then 
	
		assert(fallback~=edgeId)
		trace("findNextEdgeInSameDirection returning (fallback)",result,"from ",edgeId)
		return fallback
	end 
	local result=  util.evaluateWinnerFromScores(candidates).edgeId
	trace("findNextEdgeInSameDirection returning",result,"from ",edgeId)
	return result
end
local function findStation(constructionEntity)
	if constructionEntity ~= -1 then
		local station =  util.getComponent(constructionEntity, api.type.ComponentType.CONSTRUCTION).stations[1]
		--[[if station then 
			for i, edgeId in pairs(api.engine.system.catchmentAreaSystem.getStation2edgesMap()[station]) do 
				if api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId.entity) == constructionEntity then 
					trace("DID find",constructionEntity," in catchment area of ",station)
					return station
				end 
			end 
			trace("Did NOT find ",constructionEntity," in catchment area of ",station)
		end ]]--
		return station 
	end
end
function util.isBusStop(stationId, excludeTram) 
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	if station.cargo then 
		return false 
	end 
	if -1 ~= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId) then 
		return false 
	end 
	return not excludeTram or  util.getComponent(util.getEdgeForBusStop(stationId), api.type.ComponentType.BASE_EDGE_STREET).tramTrackType==0
end
function util.isTruckStop(stationId) 
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	if not station.cargo then 
		return false 
	end 
	if -1 ~= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId) then 
		return false 
	end 
	return true
end
function util.getBusStopsForTown(town, excludeTram) 
	if type(town)=="table" or type(town)=="userdata" then 
		town = town.id 
	end
	local townStations = util.deepClone(api.engine.system.stationSystem.getStations(town))
	local result = {}
	for i, stationId in pairs(townStations) do 
		if util.isBusStop(stationId, excludeTram) then
			table.insert(result, stationId)
		end
	end 
	return result
end 

function util.countBusStopsForTown(town) 
	return #util.getBusStopsForTown(town) 
end 

function util.getPerpendicularTangentAndDetailsForEdge(edgeId, node)
	local edge = util.getEdge(edgeId)
	if not node then 
		node = edge.node1
	end 
	local otherNode = edge.node1 == node and edge.node0 or edge.node1
	local nodePos = util.nodePos(node)
	local construction = util.searchForFirstEntity(nodePos, 200, "SIM_BUILDING")
	local constructionPos
	if not construction then 
		construction = util.searchForFirstEntity(nodePos, 200, "CONSTRUCTION")
		if construction then
			constructionPos = util.v3fromLegacyTransf(construction.transf)
		end
	else 
		constructionPos = util.v3fromArr(construction.position)
	end
	
	local tangent = util.v3(edge.tangent1)
	local perpTangent = util.rotateXY(tangent, math.rad(90))
	if constructionPos then -- find the perpendicular that moves away from the building
		local testPos = 50*vec3.normalize(perpTangent) + nodePos
		if util.distance(testPos, constructionPos) < util.distance(nodePos, constructionPos) then
			perpTangent = util.rotateXY(tangent, -math.rad(90))
		end
	end
	
	return { node=node, nodePos=nodePos, tangent=perpTangent, edgeId=edgeId, isDeadEnd=false, otherNode= otherNode, otherNodePos = util.nodePos(otherNode)}
end

function util.getConstructionPosition(constructionId) 
	local construction = util.getConstruction(constructionId)
	return  util.v3(construction.transf:cols(3))
end

function util.getDeadEndNodeDetails(node)
	local segs = util.getSegmentsForNode(node) 
	if not segs then 
		trace("WARNING! No segs for for node ",node)
		util.clearCacheNode2SegMaps() 
		segs = util.getSegmentsForNode(node) 
		trace("After clearing the cache segs was",segs)
	end 
	if #util.getStreetSegmentsForNode(node)  == 3 then 
		trace("call to getDeadEndNodeDetails actually has 3 segments, calling onto get outbound")
		return util.getOutboundNodeDetailsForTJunction(node) 
	end 
	if util.isCornerNode(node) then  
		if util.getStreetTypeCategory(segs[1]) == "entrance" and util.getStreetTypeCategory(segs[2]) ~= "entrance"  then 
			return util.getDeadEndTangentAndDetailsForEdge(segs[2], node)
		end
		--if util.getStreetTypeCategory(segs[1]) == "entrance" and util.getStreetTypeCategory(segs[2]) ~= "entrance"  then 
	end 
	return util.getDeadEndTangentAndDetailsForEdge(segs[1], node)
end

function util.getDeadEndTangentAndDetailsForEdge(edgeId, preferredNode) 
	local edge = util.getEdge(edgeId)
	if not preferredNode then preferredNode = edge.node1 end
	local segmentFn = util.getEntity(edgeId).track and util.getTrackSegmentsForNode or util.getStreetSegmentsForNode
	
	local node = preferredNode	
	local otherNode = node == edge.node1 and edge.node0 or edge.node1
	local tangent =  node == edge.node1 and util.v3(edge.tangent1) or -1*util.v3(edge.tangent0)
	local nextSegs = segmentFn(node) 
	if (#nextSegs ~= 1 and not util.isCornerNode(node)) or util.isFrozenNode(node) then
		local temp = node 
		node = otherNode 
		otherNode = temp
		nextSegs = segmentFn(node) 
		if #nextSegs ~= 1  and not util.isCornerNode(node) then
			trace("getDeadEndTangentAndDetailsForEdge: nextsegs still not 1 for edge ", edgeId, " falling back to perpendicular tangent")
			return util.getPerpendicularTangentAndDetailsForEdge(edgeId)
		end
		
		tangent = node == edge.node1 and util.v3(edge.tangent1) or -1*util.v3(edge.tangent0)
	end
	local nodePos = util.nodePos(node)
	return { node=node, nodePos=nodePos, tangent=tangent , edgeId=edgeId, isDeadEnd = true, otherNode =otherNode, otherNodePos = util.nodePos(otherNode), isNode0 = node==edge.node0 }
end
function util.countNearbyEntities (p, range, entityType)
	return #game.interface.getEntities({radius=range, pos={p.x, p.y, p.z}}, {type=entityType, includeData=false})
end
function util.countNearbyEntitiesCached(p, range, entityType)
	if not util.countEntityCaches then 
		util.countEntityCaches = {}
	end 
	if not util.countEntityCaches[entityType] then 
		util.countEntityCaches[entityType] = {}
	end 
	local hash = range + 1024 * util.pointHash2dFuzzy(p, 4)
	if not util.countEntityCaches[entityType][hash] then 
		 util.countEntityCaches[entityType][hash]=util.countNearbyEntities (p, range, entityType)
	end 
	return util.countEntityCaches[entityType][hash]
end 
function util.isStationNode(node)
	for i, edge in pairs(util.getSegmentsForNode(node) ) do
		if util.isFrozenEdge(edge) then 
			return true 
		end
	end
	return false
end

function util.stationHasConnectedTrack(station)
	for i, node in pairs(util.getFreeNodesForConstruction(api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station))) do 
		if #util.getTrackSegmentsForNode(node)>1 then 
			return true
		end
	end
	return false 
end

function util.findDoubleTrackEdge(edgeId, tolerance, allowJunctionEdge) 
	if not util.getTrackEdge(edgeId) then 
		return 
	end
	local edge = util.getEdge(edgeId)
	local node0 = util.findDoubleTrackNode(util.nodePos(edge.node0), util.v3(edge.tangent0), 1, tolerance)
	local node1 = util.findDoubleTrackNode(util.nodePos(edge.node1), util.v3(edge.tangent1), 1, tolerance)
	--trace("Attempting to find double track edge for edge",edgeId," discovered nodes ",node0, " and ",node1)
	if node0 and node1 then 
		local edgeId =  util.findEdgeConnectingNodes(node0, node1)
		if edgeId or not allowJunctionEdge then 
			return edgeId 
		end
	end
	if allowJunctionEdge and node0 then 
		local edgeId = util.findEdgeConnectingNodes(node0, edge.node1)
		if edgeId then 
			return edgeId 
		end
	end 
	if allowJunctionEdge and node1 then 
		return util.findEdgeConnectingNodes(node1, edge.node0)
	end 
end
function util.findDoubleTrackEdges(edgeId) 
	if not util.getTrackEdge(edgeId) then 
		return {} 
	end 
	local result = {} 
	local notEdges = {}
	for i = 1, 5 do 
		local edge2 = util.findDoubleTrackEdgeExpanded(edgeId, notEdges) 
		if edge2 then 
			table.insert(result, edge2) 
			notEdges[edge2]=true 
		else 
			break 
		end 
	end 
	return result
	
end 
function util.removeTrafficlights(build) 
	trace("removeTrafficlights begin")
	for i =1 , #build.proposal.proposal.addedNodes do
		local newNode = build.proposal.proposal.addedNodes[i]
		if newNode.comp.trafficLightPreference ==2 then 
			trace("Attempting to remove traffic light at ",i,"of",#build.proposal.proposal.addedNodes)
			newNode.comp.trafficLightPreference =1 
			build.proposal.proposal.addedNodes[i] = newNode 
		end
	end 
	trace("removeTrafficlights end")
end

function util.getStationName(stationId) 
	local name = util.getComponent(stationId, api.type.ComponentType.NAME)
	
	return name and name.name or ""
end 

function util.findDoubleTrackEdgeExpanded(edgeId, notEdges) 
	if not util.getTrackEdge(edgeId) then 
		return 
	end
	local firstTry = util.findDoubleTrackEdge(edgeId) 
	if not firstTry then 
		return 
	end 
	if firstTry and not notEdges[firstTry] then 
		return firstTry
	end 
	trace("Looking for expended double track edge, initial edge",firstTry," was already found")
	local edge = util.getEdge(edgeId)
	local p0 = util.nodePos(edge.node0)
	local p1 = util.nodePos(edge.node1)
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent1)
	local excludeEdge = util.getEdge(firstTry)
	local notNodes = {} 
	notNodes[excludeEdge.node0]=true 
	notNodes[excludeEdge.node1]=true 
	local tolerance = 1
	local strict = true
	for trackOffsets = 1, 4 do 
		for j = 1, 2 do -- loop twice to potentially pick up the other side 
			local node0 = util.findDoubleTrackNode(p0, t0, trackOffsets, tolerance, strict, notNodes)
			local node1 = util.findDoubleTrackNode(p1, t1, trackOffsets, tolerance, strict, notNodes)
		--trace("Attempting to find double track edge for edge",edgeId," discovered nodes ",node0, " and ",node1)
			if node0 and node1 then 
				local edgeId =  util.findEdgeConnectingNodes(node0, node1)
				if edgeId then 	
					if notEdges[edgeId] then 
						local excludeEdge = util.getEdge(edgeId)
						notNodes[excludeEdge.node0]=true 
						notNodes[excludeEdge.node1]=true 
					else 
						return edgeId 
					end
				end
			end
		end
	end 
	
	
	if allowJunctionEdge and node0 then 
		local edgeId = util.findEdgeConnectingNodes(node0, edge.node1)
		if edgeId then 
			return edgeId 
		end
	end 
	if allowJunctionEdge and node1 then 
		return util.findEdgeConnectingNodes(node1, edge.node0)
	end 
end
function util.findDoubleTrackEdgeOrJunctionEdge(edgeId)
	return util.findDoubleTrackEdge(edgeId, tolerance, true) 
end
function util.buildConnectingRoadToNearestNode(node, nextEdgeId, findConstructionEdge, newProposal, forbidRecurse, inputNode) 
	trace("buildConnectingRoadToNearestNode begin: was given node",node)
	if type(node) == "table" then 
		if node.id then 
			node = node.id 
		else 
			trace("buildConnectingRoadToNearestNode: searching for node")
			node = util.searchForNearestNode(node, 30, function(otherNode) 
				return #util.getStreetSegmentsForNode(otherNode.id)>0 and not util.isFrozenNode(otherNode.id)
			end).id
			trace("buildConnectingRoadToNearestNode: using node",node)
		end
	end
	if inputNode and type(inputNode) == "table" then 
		if inputNode.id then 
			inputNode = inputNode.id 
		else 
			trace("buildConnectingRoadToNearestNode: searching for node")
			inputNode = util.searchForNearestNode(inputNode, 30, function(otherNode) 
				return #util.getStreetSegmentsForNode(otherNode.id)>0 and not util.isFrozenNode(otherNode.id)
			end).id
			trace("buildConnectingRoadToNearestNode: using node",inputNode)
		end
	end
	--[[
	if node < 0 then 
		local edges = util.getSegmentsForNode(-node)
		local options = {} 
		for i , seg in pairs(edges) do 
			local edge = util.getEdge(seg)
			local otherNode = edge.node0 == -node and edge.node1 or edge.node0 
			local nodes =  util.searchForDeadEndNodes(util.nodePos(otherNode), 50)
			if #nodes > 0 then 
				node = otherNode
				break
			end
		end
		
	end]]--
	local excludeNodes = {} 
	if newProposal then 
		for i , edge in pairs(newProposal.streetProposal.edgesToAdd) do 
			excludeNodes[edge.comp.node0]=true
			excludeNodes[edge.comp.node1]=true
		end 
	end 
	trace("buildConnectingRoadToNearestNode: searching for otherNode")
	local otherNode = inputNode or util.searchForNearestNode(util.nodePos(node), 100, function(otherNode) 
		if excludeNodes[otherNode.id] then 
			trace("checking node:",otherNode.id,"but was in exclude nodes")
			if util.tracelog then 
				debugPrint({newProposal=newProposal})
			end 
			return false 
		end
		local result =  otherNode.id ~= node and #util.getStreetSegmentsForNode(otherNode.id) > 0 and not util.isFrozenNode(otherNode.id) and not util.findEdgeConnectingNodes(otherNode.id, node)
		trace("checking node:",otherNode.id,"isok?",result)
		if findConstructionEdge then
			local found = false 
			for i, seg in pairs(util.getStreetSegmentsForNode(otherNode.id)) do 
				if util.isFrozenEdge(seg) then 
					found = true 
					break 
				end 
			end
			return result and found
		end 
		return result
	end)
	trace("buildConnectingRoadToNearestNode: completed search for otherNode, otherNode was",otherNode)
	if not otherNode then
		trace("WARNING! no node found")
		if not forbidRecurse then 
			local segs =util.getSegmentsForNode(node)
			if #segs == 1 then 
				local seg = segs[1]
				if not util.isFrozenEdge(seg) then 
					local edge = util.getEdge(seg)
					local otherNode = node == edge.node0 and edge.node1 or edge.node0 
					if #util.getSegmentsForNode(otherNode) == 1 then 
						forbidRecurse = true
						return util.buildConnectingRoadToNearestNode(otherNode, nextEdgeId, findConstructionEdge, newProposal, forbidRecurse) 
					end 
				end 
			end 
		end 
		return 
	end
	if type(otherNode) == "number" then 
		otherNode = { id = otherNode }
		trace("Set the otherNode to table",otherNode)
		trace("otherNode.id=",otherNode.id)
	end 
	local edgeToCopy = util.getStreetSegmentsForNode(otherNode.id)[1]
	if not util.isFrozenEdge(edgeToCopy) and util.isFrozenEdge(util.getStreetSegmentsForNode(node)[1]) then 
		edgeToCopy = util.getStreetSegmentsForNode(node)[1]
	end 
	local entity =  util.copyExistingEdge(edgeToCopy)
	if nextEdgeId then 
		entity.entity = nextEdgeId
	end
	entity.comp.node0 = node 
	entity.comp.node1 = otherNode.id 
	util.setTangentsForStraightEdgeBetweenExistingNodes(entity)
	local testProposal= api.type.SimpleProposal.new()
	testProposal.streetProposal.edgesToAdd[1]=entity
	trace("buildConnectingRoadToNearestNode: setting up proposalData")
	if util.tracelog then 
		debugPrint(testProposal)
	end 
	util.validateProposal(testProposal)
	--if util.getStreetTypeCategory(entity.streetEdge.streetType) =="entrance" then 
	local proposalData = api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
	if #proposalData.errorState.messages > 0 or proposalData.errorState.critical then
		trace("buildConnectingRoadToNearestNode: error found with",util.newEdgeToString(entity))
		if util.isNodeConnectedToFrozenEdge(entity.comp.node1) then 
			local node = util.searchForNearestNode(util.nodePos(entity.comp.node1), 30, function(otherNode) 
				return #util.getStreetSegmentsForNode(otherNode.id)>0 and not util.isFrozenNode(otherNode.id) and entity.comp.node1~=otherNode.id
			end)
			if not node then 
				trace("No node found! Aborting")
				return
			end 
			entity.comp.node0 = node.id 
		else 
			local node = util.searchForNearestNode(util.nodePos(entity.comp.node0), 30, function(otherNode) 
				return #util.getStreetSegmentsForNode(otherNode.id)>0 and not util.isFrozenNode(otherNode.id) and entity.comp.node0~=otherNode.id
			end)
			if not node then 
				trace("No node found! Aborting")
				return
			end 
			entity.comp.node1 = node.id
		end 		
		util.setTangentsForStraightEdgeBetweenExistingNodes(entity)
		entity.streetEdge.streetType = util.smallCountryStreetType()
		trace("buildConnectingRoadToNearestNode: attempting to rectify with",util.newEdgeToString(entity))
	end
	--end
	--entity.streetEdge.streetType = util.smallCountryStreetType()
	trace("buildConnectingRoadToNearestNode: complete")
	if tracelog then 
		trace(debug.traceback())
	end 
	--print(debug.traceback())
	return entity
end


function util.getOutboundNodeDetailsForTJunction(node) 
	local segs = util.getStreetSegmentsForNode(node)
	assert(#segs == 3)
	local edge1 = util.getEdge(segs[1])
	local edge2 = util.getEdge(segs[2])
	local edge3 = util.getEdge(segs[3])
	
	local tangent1 = util.v3(edge1.node0 == node and edge1.tangent0 or edge1.tangent1)
	local tangent2 = util.v3(edge2.node0 == node and edge2.tangent0 or edge2.tangent1)
	local tangent3 = util.v3(edge3.node0 == node and edge3.tangent0 or edge3.tangent1)
	
	--trace("Signed angle between t1 and t2 =",math.deg(util.signedAngle(tangent1, tangent2)))
	--trace("Signed angle between t2 and t3 =",math.deg(util.signedAngle(tangent2, tangent3)))
	--local tEdge 
	--if math.abs(util.signedAngle(tangent1, tangent2)) % math.rad(180) < math.rad(10) then 
	--	tEdge= 3 
		--trace("Using edge 3")
	--elseif  math.abs(util.signedAngle(tangent2, tangent3)) % math.rad(180) < math.rad(10) then 
	--	tEdge = 1 
	--trace("Using edge 1")
	--else 
	--	tEdge = 2
		--trace("Using edge 2")
	--end
	
	local function correctAngle(angle) 
		local corrected = math.abs(angle) % math.rad(180)
		if corrected > math.rad(90) then 
			corrected = math.rad(180)-corrected
		end 
		return corrected
	end
	
	local angle1 = correctAngle(util.signedAngle(tangent1, tangent2)) 
	local angle2 = correctAngle(util.signedAngle(tangent2, tangent3)) 
	local angle3 = correctAngle(util.signedAngle(tangent1, tangent3))  
	
	
	local angles = { angle1, angle2, angle3 } 
	table.sort(angles)
	local tEdge 
	if angles[1] == angle1 then 
		tEdge= 3 
		
	elseif  angles[1] == angle2  then 
		tEdge = 1 
	
	else 
		assert(angles[1]==angle3)
		tEdge = 2
	
	end
	
	local edgeIdToUse = segs[tEdge] 
	local edge= util.getEdge(edgeIdToUse)
	local tangent = edge.node0 == node and -1*util.v3(edge.tangent0) or util.v3(edge.tangent1)
	
	--trace("For node, ",node," found the T-junction edge to be ",edgeIdToUse)
	return { tangent = tangent, edge = edge, edgeId = edgeIdToUse, node=node, nodePos=util.nodePos(node) }	
end

function util.findStopBetweenNodes(node0, node1, forbidRecurse)
	-- after building the stop the edgeId has changed so find the new one between existing nodes
 
	for i, edgeId in pairs(util.getSegmentsForNode(node0)) do
		for j, edgeId2 in pairs(util.getSegmentsForNode(node1)) do
			if edgeId == edgeId2 then 
				if not api.engine.entityExists(edgeId) and not forbidRecurse then 
					util.clearCacheNode2SegMaps()
					util.lazyCacheNode2SegMaps()
					return util.findStopBetweenNodes(node0, node1, true)
				end 
				local edge = util.getEdge(edgeId)
				if (not edge or #edge.objects == 0) and not forbidRecurse then 
					util.clearCacheNode2SegMaps()
					util.lazyCacheNode2SegMaps()
					return util.findStopBetweenNodes(node0, node1, true)
				end
				if not edge.objects[1] then 
					trace("WARNING! no edge object found for",edgeId,"between nodes",node0,node1)
					error("Could not find a stop")
				end 
				return edge.objects[1][1]
			end		
		end
	end
	if not forbidRecurse then 
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps()
		return util.findStopBetweenNodes(node0, node1, true)
	end 
	
end

util.getNearestBaseNodePosition = function(p, range)
	local dists = {}
	local distsMap = {}
	if not range then range = 100  end
	for k, node in pairs(game.interface.getEntities({radius=range, pos={p.x, p.y, p.z}}, {type="BASE_NODE", includeData=true})) do
		local p2 = util.v3fromArr(node.position)
		local dist = util.distance(p, p2)
		table.insert(dists, dist)
		distsMap[dist]={p=p2, node=node.id}
	end
	table.sort(dists)
	local dist = dists[1]
	if dist then 
		return distsMap[dist]
	end
end

function util.isOneWayStreet(edgeId) 
	if util.oneWayStreetCache and util.oneWayStreetCache[edgeId] then 
		return util.oneWayStreetCache[edgeId]==1
	end
	local streetEdge = util.getStreetEdge(edgeId)
	if not streetEdge then 
		return false 
	end 
	local streetRep = util.streetTypeRepGet(streetEdge.streetType)
	if #streetRep.laneConfigs == 3 then 
--		return true 
	end 
	local isForward = streetRep.laneConfigs[2].forward 
	for i = 3, #streetRep.laneConfigs-1 do 
		local nextLane = streetRep.laneConfigs[i] 
		--trace("Checking nextLane for edge",edgeId," isForward=",isForward," nextLane.forward=",nextLane.forward," at lane",i)
		if nextLane.forward ~= isForward then 	
			if util.oneWayStreetCache then 
				util.oneWayStreetCache[edgeId]=0
			end
			return false 
		end
	end 
	if util.oneWayStreetCache then 
		util.oneWayStreetCache[edgeId]=1
	end
	return true 
end 

function util.checkProposedTrackSegmentForCollisionsAndAdjust(p0, p1, edgeWidth)
	local nearbyIndustry  = util.searchForFirstEntity(p1, 200, "SIM_BUILDING")
	local correction = vec3.new(0,0,0)
	local count = 0
	if nearbyIndustry and math.abs(p1.z-nearbyIndustry.position[3])<50 then 
		local needsCorrection = false
		--trace("Checking for correction around",p1.x, p1.y)
		repeat 
			count = count + 1
			local dummyProposal = api.type.SimpleProposal.new()
			local node0Pos = correction+p0
			local node0 = util.newNodeWithPosition(node0Pos)
			node0.entity=-2
			local node1Pos = correction+p1
			local node1 = util.newNodeWithPosition(node1Pos)
			node1.entity=-3
			local newEntity = api.type.SegmentAndEntity.new()
			if edgeWidth == 5 then 
				newEntity.type = 1
				newEntity.trackEdge.trackType=api.res.trackTypeRep.find("standard.lua")
			else 
				newEntity.type = 0
				local streetType 
				if edgeWidth <= 16 then 
					streetType = api.res.streetTypeRep.find("standard/country_medium_new.lua")
				elseif edgeWidth <=24 then 
					streetType = api.res.streetTypeRep.find("standard/country_large_new.lua")
				else 
					streetType = api.res.streetTypeRep.find("standard/country_x_large_new.lua")
				end
				newEntity.streetEdge.streetType = streetType
			end
			newEntity.comp.node0=node0.entity
			newEntity.comp.node1=node1.entity
			util.setTangent(newEntity.comp.tangent0, node1Pos-node0Pos)
			util.setTangent(newEntity.comp.tangent1, node1Pos-node0Pos)
			dummyProposal.streetProposal.edgesToAdd[1]=newEntity
			dummyProposal.streetProposal.nodesToAdd[1]=node0
			dummyProposal.streetProposal.nodesToAdd[2]=node1
			local resultData = api.engine.util.proposal.makeProposalData(dummyProposal, util.initContext())
			local function checkIfNeedsCorrection()
				--[[if resultData.errorState.critical or #resultData.errorState.messages > 0 then 
					trace("Found an error")
					if tracelog then 
						debugPrint(resultData.errorState)
						debugPrint(resultData.collisionInfo)
					end
				end]]--
				for i, entity in pairs(resultData.collisionInfo.collisionEntities) do 
					if entity.entity == api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(nearbyIndustry.id) then 
						trace("Found collision with entity ",entity)
						return true
					end
				end
				return resultData.errorState.critical
			end
		 
			local didNeedCorrection = needsCorrection
			needsCorrection =  checkIfNeedsCorrection()
			if needsCorrection or didNeedCorrection then -- do an extra shift to give some margin
				local midPoint = 0.5*(node1Pos-node0Pos)+node0Pos 
				local vectorToIndustry = midPoint - util.v3fromArr(nearbyIndustry.position)
				correction = correction + 5*vec3.normalize(vectorToIndustry)
			end
			
		until not needsCorrection or count > 30
		if needsCorrection then 
			local node0Pos = correction+p0
			trace("warning, still needed correcting after 15 times, p0=",p0.x,p0.y," adjustedPos=",node0Pos.x,node0Pos.y)
		end
	end
	
	return correction	
end

util.checkProposedNodePositionAndShiftIfNecessary = function(p, range, isTrack)
	local nodeAndPos = util.getNearestBaseNodePosition(p, range)
	if not nodeAndPos then return p end
	local p2 =  nodeAndPos.p
	if isTrack and #util.getStreetSegmentsForNode(nodeAndPos.node)==0 then -- do not offset track against track
		return p
	end
	
	trace("checking p at ",p.x,p.y, " against p2, dist=", (p2 and util.distance(p,p2) or "nil"))
	local minDist = 15
	if p2 and util.distance(p, p2) < minDist then
		local dist = util.distance(p, p2) 
		local correction = minDist - dist
		local move = p-p2 
		local newPos = p + correction * vec3.normalize(move)
		trace("moving p from ", p.x, p.y," to ",newPos.x, newPos.y," due to proximity with node at ",p2.x,p2.y," new dist=",util.distance(newPos,p2))
		return newPos
	end
	return p
end
function util.isCornerNode(node)
	local segs = util.getStreetSegmentsForNode(node)
	if not segs then 
		trace("WARNING! No segs found for node",node)
		return false
	end 
	if #segs ~= 2 then 
		return false 
	end 
	local edge1 = util.getEdge(segs[1])
	local edge2 = util.getEdge(segs[2])
	local t1 = edge1.node0 == node and util.v3(edge1.tangent0) or util.v3(edge1.tangent1)
	local t2 = edge2.node0 == node and util.v3(edge2.tangent0) or util.v3(edge2.tangent1)
	local signedAngle = util.signedAngle(t1, t2)
	local isCornerNode = math.abs(math.abs(signedAngle)-math.rad(90)) < math.rad(30) 
	--trace("Determined that node ",node," was a corner node? ",isCornerNode," based on angle",math.deg(signedAngle))
	return isCornerNode
end 

function util.isDeadEndNode(node, allowCornerNodes)
	if #util.getStreetSegmentsForNode(node)==1 and #util.getTrackSegmentsForNode(node)==0 and not  util.isOneWayStreet(util.getStreetSegmentsForNode(node)[1]) then 
		return true 
	else 
		return allowCornerNodes and util.isCornerNode(node)
	end	
	 
end

function util.isDeadEndOrCornerNode(node) 
	return util.isDeadEndNode(node, true)
end

function util.searchForDeadEndNodes(position, searchRadius, allowCornerNodes, filterFn) 
	local result = {}
	if position.x then 
		position = util.v3ToArr(position)
	end
	if not filterFn then 
		filterFn = function(node)	
			local streetSegs =  util.getStreetSegmentsForNode(node)[1]
			return streetSegs and util.getStreetTypeCategory(streetSegs)~="highway" 
		end 
	end
	for i, node in pairs(game.interface.getEntities({pos=position, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		if util.isDeadEndNode(node, allowCornerNodes) and not util.isFrozenNode(node) and filterFn(node) then
			table.insert(result, node)
		end
	end
	return result
end
function util.searchForNearestStreetNode(position, searchRadius, optionalStreetCategory, optionalStreetCategory2) 
	local options = {}
	local v3Pos 
	if position.x then 
		v3Pos = position
		position = util.v3ToArr(position)
	else 
		v3Pos = util.v3fromArr(position)
	end 
	
	local function filterFn() return true end 
	if optionalStreetCategory then 
		filterFn = function(node) 
			for __, seg in pairs(util.getStreetSegmentsForNode(node)) do 	
				local streetCategory = util.getStreetTypeCategory(seg)
				if streetCategory==optionalStreetCategory or streetCategory==optionalStreetCategory2 then 
					return true 
				end
			end 
			return false 
		end 
	end
	for i, node in pairs(game.interface.getEntities({pos=position, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		if #util.getTrackSegmentsForNode(node)==0 and filterFn(node) then 
			local nodePos = util.nodePos(node)
			if math.abs(nodePos.z - v3Pos.z) <= 0.2*vec2.distance(nodePos, v3Pos) then 
				table.insert(options,{node= node, scores={util.distance(nodePos, v3Pos)}}) 
			end
		end
	end
	if #options  == 0  then
		return 
	end
	return util.evaluateWinnerFromScores(options).node
end

function util.searchForDeadEndHighwayNodes(position, searchRadius, filterFn) 
	local result = {}
	if not filterFn then filterFn = function() return true end end
	if position.x then 
		position = util.v3ToArr(position)
	end
	for i, node in pairs(game.interface.getEntities({pos=position, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		if #util.getStreetSegmentsForNode(node) == 1 and not util.isFrozenNode(node) and util.getStreetTypeCategory(util.getStreetSegmentsForNode(node)[1]) == "highway" and filterFn(node) then
			table.insert(result, node)
		end
	end
	local oldResult = util.deepClone(result)
	for i, node in pairs(oldResult) do -- its possible we just cut off the parallel node for example at the edge of the circle
		local parallelNode = util.findParallelHighwayNode(node)
		if parallelNode and #util.getStreetSegmentsForNode(node) == 1 and not util.contains(result, parallelNode) then 
			table.insert(result, parallelNode)
		end 
	end 
	return result
end

function util.searchForDeadTrackNodes(position, searchRadius) 
	local result = {}
	if position.x then 
		position = util.v3ToArr(position)
	end
	for i, node in pairs(game.interface.getEntities({pos=position, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		if #util.getStreetSegmentsForNode(node) == 0 and not util.isFrozenNode(node) and #util.getTrackSegmentsForNode(node) == 1 then
			table.insert(result, node)
		end
	end
	return result
end
function util.searchForHighwayNodes(position, searchRadius, filterFn, junctionOnly)
 
	local result = {}
	if position.x then 
		position = util.v3ToArr(position)
	end
	if not filterFn then filterFn = function() return true end end
	for i, node in pairs(game.interface.getEntities({pos=position, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		local segs = util.getStreetSegmentsForNode(node)
		if #segs == 3 and not util.isFrozenNode(node) and filterFn(node) then
			local foundParallel = false 
			local highwayCount = 0 
			for j, seg in pairs(segs) do
				local isHighway = util.getStreetTypeCategory(seg) == "highway"
				if isHighway  and util.findParallelHighwayEdge(seg) then 
					foundParallel = true 
 				end
				if isHighway then 
					highwayCount = highwayCount+1
				end
			end 
			if foundParallel and (not junctionOnly or highwayCount == 3) then 
				table.insert(result, node)
			end
		end
	end
	return result
end
function util.searchForJunctionHighwayNodes(position, searchRadius, filterFn)
	return util.searchForHighwayNodes(position, searchRadius, filterFn, true)

end
function util.searchForClosestDeadEndStreetOrTrackNode(position, searchRadius ) 
	local result = {}
	for i, node in pairs(game.interface.getEntities({pos=position, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		if (#util.getTrackSegmentsForNode(node)==1 or #util.getStreetSegmentsForNode(node) <= 3) and not util.isFrozenNode(node)   then
			table.insert(result, node)
		end
	end
	return util.evaluateWinnerFromSingleScore(result, 	function(node) return util.distance(util.nodePos(node), util.v3fromArr(position)) end)
end
function util.searchForClosestDeadEndNode(position, searchRadius, allowCornerNodes) 
	return util.evaluateWinnerFromSingleScore(util.searchForDeadEndNodes(position, searchRadius, allowCornerNodes),
		function(node) return util.distance(util.nodePos(node), position) end)
end

function util.isSuspensionBridgeAvailable() 
	return util.year() >= api.res.bridgeTypeRep.get(api.res.bridgeTypeRep.find("suspension.lua")).yearFrom
end
function util.isCableBridgeAvailable() 
	return util.year() >= api.res.bridgeTypeRep.get(api.res.bridgeTypeRep.find("cable.lua")).yearFrom
end
local function isCountryNode(node)
	if #util.getTrackSegmentsForNode(node) > 0 then 
		return false 
	end
	for __, seg in pairs(util.getStreetSegmentsForNode(node))do 
		if util.getStreetTypeCategory(seg) ~= "country" then 
			return false 
		end
	end
	return true
end
function util.isAdjacentToHighwayJunction(node)  
	local segs = util.getStreetSegmentsForNode(node)
	for i , seg in pairs(segs ) do 
		if util.getStreetTypeCategory(seg) == "highway" then 
			return false 
		end 
	end
	for i , seg in pairs(segs ) do  
		local edge = util.getEdge(seg) 
		local otherNode = node == edge.node0 and edge.node1 or edge.node0 
		for j, seg2 in pairs(util.getStreetSegmentsForNode(otherNode)) do 
			if  util.getStreetTypeCategory(seg2) == "highway" then 
				return true
			end
		end 	 
	end 
	return false
end
function util.searchForDeadEndOrCountryNodes(position, searchRadius, filterFn) 
		local result = {}
	if not filterFn then filterFn = function() return true end end
	for i, node in pairs(game.interface.getEntities({pos={position.x, position.y}, radius=searchRadius}, {type="BASE_NODE", includeData=false})) do 
		if (util.isDeadEndNode(node, true) or isCountryNode(node) or util.isAdjacentToHighwayJunction(node)) and not util.isFrozenNode(node) and #util.getStreetSegmentsForNode(node) < 4 and filterFn(node) then
			table.insert(result, node)
		end
	end
	return result
end

function util.searchForUncongestedDeadEndOrCountryNodes(position, searchRadius)
	local function uncongestedNodesFilter(node)
		if util.isDeadEndNode(node, true) then 
			return true 
		end 
		if util.isNodeConnectedToFrozenEdge(node) then  
			return false 
		end 
		local p = util.nodePos(node)
		if util.countNearbyEntitiesCached(p, 50, "BASE_EDGE") > 4 then 
			return false 
		end
		if util.countNearbyEntitiesCached(p, 50, "STATION") > 1 then 
			return false 
		end
		if util.countNearbyEntitiesCached(p, 50, "CONSTRUCTION") > 2 then 
			return false 
		end
		return true
	end 
	return util.searchForDeadEndOrCountryNodes(position, searchRadius, uncongestedNodesFilter) 
end 

function util.searchForFreeTrackEdges(position, searchRadius, filterFn) 
	local result = {}
	if not filterFn then filterFn = function(edgeId) return true end end
	local start = os.clock()
	local edges = game.interface.getEntities({pos={position.x, position.y}, radius=searchRadius}, {type="BASE_EDGE", includeData=true})
	local endTime = os.clock()
	trace("Spent ",(endTime-start)," to find ",util.size(edges))
	for edgeId, edge in pairs(edges) do 
		if edge.track
		--util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_TRACK) 
		and not util.isFrozenEdge(edgeId) then 
			--local edge = util.getEdge(edgeId)
			if #util.getTrackSegmentsForNode(edge.node0)==2 and #util.getTrackSegmentsForNode(edge.node1) == 2
				and #util.getStreetSegmentsForNode(edge.node0)==0 and #util.getStreetSegmentsForNode(edge.node1) == 0
				and filterFn(edgeId)
			then
				table.insert(result, edgeId)
			end
		end
	end
	return result
end

function util.stationFromStop(stop) 
	local stationGroup = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
	return stationGroup.stations[stop.station+1]
end

function util.findShortestDistanceNodePair(leftNodes, rightNodes, minDist, params, includeAllResults)
	if not minDist then minDist =0 end
	local nodePairs = {}
	local uniqueNessCheck = {}
	for i, leftNode in pairs(leftNodes) do 
		if not uniqueNessCheck[leftNode] then 
			uniqueNessCheck[leftNode] = {}
			for j, rightNode in pairs(rightNodes) do 
				if leftNode ~= rightNode and util.distBetweenNodes(leftNode, rightNode) > minDist and not uniqueNessCheck[leftNode][rightNode] then 
					table.insert(nodePairs, { leftNode, rightNode})
					uniqueNessCheck[leftNode][rightNode] = true
				end
			end
		end
	end
	local scoreFn = function(nodePair) return util.distBetweenNodes(nodePair[1], nodePair[2]) end
	local function countTrackNodes(node) 
		return #util.searchForDeadTrackNodes(util.nodePos(node), 50) 
	end 
	
	if params and params.isHighway then 
		trace("Including angle comparison for nodepair")
		local scoreFn2 = function(nodePair) 	
			local tangent = util.getDeadEndNodeDetails(nodePair[1]).tangent
			local tangent2 = -1*util.getDeadEndNodeDetails(nodePair[2]).tangent
			return math.abs(util.signedAngle(tangent, tangent2))
		end
		return util.evaluateWinnerFromScores(nodePairs, { 75, 25}, { scoreFn, scoreFn2})
	end 
	
	if params and not params.isCargo and params.isTrack  and #nodePairs > 1 or includeAllResults then 
		local allResults = util.evaluateAndSortFromScores(nodePairs, {1}, {scoreFn})
		if includeAllResults then 
			return allResults 
		end
		local best = allResults[1]
		for i = 2, math.min(4, #allResults) do 
			local secondBest = allResults[i] 
			local scoreDiff=  secondBest.scores[1]-best.scores[1]
			local bestDeadEndScore = countTrackNodes(best[1])+countTrackNodes(best[2])
			local secondBestDeadEndScore = countTrackNodes(secondBest[1])+countTrackNodes(secondBest[2])
			trace("The score diff of the second best was ", scoreDiff, " the bestDeadEndScore=",bestDeadEndScore," the secondBestDeadEndScore=",secondBestDeadEndScore)
			-- if we are nearly perpendicular then choose the side with the greatest dead ends more likely can extend the line
			if scoreDiff < 110 and secondBestDeadEndScore > bestDeadEndScore then 
				trace("Returning the second best result instead")
				return secondBest
			end
		end
	
		return best 
	end 
	
	return util.evaluateWinnerFromSingleScore(nodePairs, scoreFn)
end 
function util.findShortestDistanceNodePairs(leftNodes, rightNodes, minDist, params)
	return util.findShortestDistanceNodePair(leftNodes, rightNodes, minDist, params, true)
end 
local function scoreDeadEndNode(node)
	local num = #util.getStreetSegmentsForNode(node)
	if num == 1 then return 0 end
	if num == 3 then return 1 end
	return 2
end

function util.findShortestDistanceNodePairPreferringDeadEnds(leftNodes, rightNodes)
	local nodePairs = {}
	for i, leftNode in pairs(leftNodes) do 
		for j, rightNode in pairs(rightNodes) do 
			table.insert(nodePairs, { 
				nodePair={ leftNode, rightNode},
				scores = {
					util.distBetweenNodes(leftNode ,rightNode),
					scoreDeadEndNode(leftNode),
					scoreDeadEndNode(rightNode)
					}
				}
			)
		end
	end
	return util.evaluateWinnerFromScores(nodePairs, {75,25,25}).nodePair
end 

function util.findShortestDistanceStationPair(leftStations, rightStations)
	local stationPairs = {}
	for i, leftStation in pairs(leftStations) do 
		for j, rightStation in pairs(rightStations) do 
			table.insert(stationPairs, { leftStation, rightStation})
		end
	end
	return util.evaluateWinnerFromSingleScore(stationPairs, function(stationPair) return util.distBetweenStations(stationPair[1], stationPair[2]) end)
end 

function util.findParallelHighwayEdge(edgeId, tolerance )
	if not edgeId then return end
	local edge = util.getEdge(edgeId) 
	if not edge then 
		trace("WARNING! No edge found for edgeId=",edgeId) 
		return 
	end
	local searchRadius = math.max(50, util.calculateSegmentLengthFromEdge(edge))
	if tolerance then 
		searchRadius = searchRadius + tolerance
	end
	local fallback 
	for otherEdgeId, otherEdge in pairs(util.searchForEntities(util.getEdgeMidPoint(edgeId), searchRadius, "BASE_EDGE")) do 
		if otherEdgeId ~= edgeId and not otherEdge.track and util.getStreetTypeCategory(otherEdgeId) == "highway" then 
			local frontVector = util.nodePos(edge.node1) - util.v3fromArr(otherEdge.node0pos)
			local backVector = util.nodePos(edge.node0) - util.v3fromArr(otherEdge.node1pos)
			local angle1 = util.signedAngle(frontVector, util.v3(edge.tangent1))
			local angle2 = util.signedAngle(backVector, util.v3(edge.tangent0))
			local deflectionAngle = math.abs(util.signedAngle(util.v3(edge.tangent0), util.v3(edge.tangent1)))
			local check1 = math.abs(math.rad(90)-math.abs(angle1))
			local check2 = math.abs(math.rad(90)-math.abs(angle2))
			if check1 < math.rad(10) and check2 < math.rad(10) then 
				return otherEdgeId 
			else	 
				--trace("Not returning ",otherEdgeId," for ",edgeId," because the angles did not line up",math.deg(angle1), math.deg(angle2), math.deg(deflectionAngle))
				if check1< math.rad(30) and check2 < math.rad(30) and deflectionAngle < math.rad(80) then 
					fallback = otherEdgeId
				end
			end 
			
		end 
	end
	trace("Had to use fallback for parallel highway for ",edgeId," fallback=",fallback)
	if tolerance and not fallback then 
		local otherNode0 = util.findParallelHighwayNode(edge.node0)
		local otherNode1 = util.findParallelHighwayNode(edge.node1) 
		if otherNode0 and otherNode1 then 
			return util.findEdgeConnectingNodes(otherNode0, otherNode1)
		end 
		if otherNode0 then 
			for i, seg in pairs(util.getStreetSegmentsForNode(otherNode0)) do 
				local otherEdge = util.getEdge(seg)
				local theirOtherNode = otherEdge.node0==otherNode0 and otherEdge.node1 or otherEdge.node0
				if util.distBetweenNodes(theirOtherNode, edge.node1) < util.distBetweenNodes(otherNode0, edge.node1) then 
					return seg 
				end 
			end 
		end
		if otherNode1 then 
			for i, seg in pairs(util.getStreetSegmentsForNode(otherNode1)) do 
				local otherEdge = util.getEdge(seg)
				local theirOtherNode = otherEdge.node0==otherNode1 and otherEdge.node1 or otherEdge.node0
				if util.distBetweenNodes(theirOtherNode, edge.node0) < util.distBetweenNodes(otherNode1, edge.node0) then 
					return seg 
				end 
			end 
		end
	end 
	return fallback
end 

function util.findParallelHighwayNode(node)
	local thisEdgeId = util.getStreetSegmentsForNode(node)[1]
	if not thisEdgeId then return end 
	local parallelEdgeId = util.findParallelHighwayEdge(thisEdgeId)
	if not parallelEdgeId then return end
	if util.getEdge(thisEdgeId).node0 == node then 
		return util.getEdge(parallelEdgeId).node1
	else 
		return util.getEdge(parallelEdgeId).node0
	end 
end

local function discoverStreetEdgeRep() 
	local streetEdges = api.res.streetTypeRep.getAll()
	local result = {} 
	for __, streetTypeName in pairs(streetEdges) do 
		local idx = api.res.streetTypeRep.find(streetTypeName)
		local streetRep = api.res.streetTypeRep.get(idx)
		result[idx]=streetRep
	end 
	util.streetTypeRep = result
end 

function util.getStreetTypeRep() 
	if not util.streetTypeRep then 
		discoverStreetEdgeRep()
	end 
	return util.streetTypeRep
end 

function util.streetTypeRepGet(idx) 
	return util.getStreetTypeRep()[idx]
end 

local function getStreetTypeCategoryPrivate(edgeId)
	if edgeId < 1000 then 
		local edgeType = util.getStreetTypeRep()[edgeId]
		if edgeType then 
			return edgeType.categories  and edgeType.categories[1]
		end
	end 
	local streetEdge =util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
	if streetEdge then
		if string.find(api.res.streetTypeRep.getName(streetEdge.streetType), "entrance") then 
			return "entrance" -- want to distinguish these
		end
		local edgeType = util.getStreetTypeRep()[streetEdge.streetType]
		return edgeType.categories  and edgeType.categories[1]
	end
end

function util.getStreetTypeCategory(edgeId)
	if not util.streetTypeCategoryCache then 
		util.streetTypeCategoryCache = {}
	end 
	if not util.streetTypeCategoryCache[edgeId] then 
		util.streetTypeCategoryCache[edgeId] = getStreetTypeCategoryPrivate(edgeId) or "nil"
	end 
	local result = util.streetTypeCategoryCache[edgeId]
	if result == "nil" then 
		return nil 
	end 
	return result
end

function util.findClosestNode(nodes, node)
	local nodePos = util.nodePos(node)
	return util.evaluateWinnerFromSingleScore(nodes, function(otherNode) return util.distance(util.nodePos(otherNode), nodePos) end)
end

local function xyGrad(p1, p2)
	local diff = p2 - p1
	return diff.y / diff.x
end
function util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4, traceLogResult)
	if traceLogResult then 
		trace("Checking for collision between ",p1.x,p1.y," - ",p2.x, p2.y, " and ", p3.x,p3.y," - ",p4.x, p4.y)
	end

	--[[
		--https://stackoverflow.com/questions/10510973/collision-detection-between-two-lines
		A: y = mx + b
		B: y = Mx + B
		y(A) = y(B) means : mx + b = Mx + B which yields to x = (B - b)/(m - M) and by putting
		the x to the line A we find y = ((m*(B - b))/(m - M)) + b

		so : T : ((B - b)/(m - M) , ((m*(B - b))/(m - M)) + b)]]--
	
	local m = xyGrad(p1, p2)
	local b = p2.y-m*p2.x
	 
	local M =  xyGrad(p4, p3)
	local B = p3.y - M * p3.x
	
	local xupper = math.max(p2.x, p1.x)
	local xlower = math.min(p2.x, p1.x)
	local yupper = math.max(p2.y, p1.y)
	local ylower = math.min(p2.y, p1.y)
	local xupper2 = math.max(p3.x, p4.x)
	local xlower2 = math.min(p3.x, p4.x)
	local yupper2 = math.max(p3.y, p4.y)
	local ylower2 = math.min(p3.y, p4.y)	 

	local t = vec2.new((B - b)/(m - M) , ((m*(B - b))/(m - M)) + b)
	if p1.x == p2.x and p3.x == p4.x then 
		if p2.x ~= p3.x then
			if traceLogResult then 
				trace("double indeterminate detected but no collision possible ",p2.x, p3.x)
			end 
			return
		end
		if ylower2 >= ylower and yupper2 <= yupper then 
			t = vec2.new(p1.x , ylower2)
			trace("Double Indeterminate detected at p1.x=",p1.x," correcting, new t=",t.x,t.y)
		else 
			trace("No collision found")
			return
		end
	elseif math.abs(p1.x - p2.x) < 0.1 then 
		local x = (p1.x+p2.x)/2
		t = vec2.new(x , M*x + B)
		if traceLogResult then 
			trace("Indeterminate detected at p1.x=",p1.x," correcting, new t=",t.x,t.y)
		end 
	elseif math.abs(p3.x - p4.x) <0.1 then 
		local x = (p3.x+p4.x)/2
		t = vec2.new(x , m*x + b)
		if traceLogResult then 
			trace("Indeterminate detected at p3.x=",p3.x," correcting, new t=",t.x,t.y)
		end
	end
	if xupper == xlower then 
		xupper = xupper+0.1
		xlower = xlower-0.1
	end 
	if yupper == ylower then 
		yupper = yupper+0.1
		ylower = ylower-0.1
	end 
	if xupper2 == xlower2 then 
		xupper2 = xupper2+0.1
		xlower2 = xlower2-0.1
	end 
	if yupper2 == ylower2 then 
		yupper2 = yupper2+0.1
		ylower2 = ylower2-0.1
	end 
	
	--Checking for collision between 	3115	-45	 - 	3115	-195	 and 	3020.9760742188	-53.226398468018	 - 	3120	-50
	---Collision test was 	false	 at 	3115	,	-53.226398468018	 xlower=	3114.9	xupper=	3115.1	ylower=	-195	yupper=	-45	 xlower2=	3020.9760742188	xupper2=	3120	ylower2=	-53.226398468018	yupper2=	-50
	--m=	-inf	b=	inf	M=	0.032582009272637	B=	-151.65586893063
	--The conditions were:	true	true	false	true	true	true	false	true
	local isCollsion = t.x >= xlower and t.x <= xupper and t.y >= ylower and t.y <= yupper
				and	   t.x >= xlower2 and t.x <= xupper2 and t.y >= ylower2 and t.y <= yupper2
	if traceLogResult then 
		trace("The conditions were:",t.x >= xlower , t.x <= xupper , t.y >= ylower , t.y <= yupper,t.x >= xlower2 , t.x <= xupper2 , t.y >= ylower2 , t.y <= yupper2)
		if isCollsion then		
			trace("Collision test was ", isCollsion, " at ",t.x,",",t.y, " xlower=",xlower,"xupper=",xupper,"ylower=",ylower,"yupper=",yupper, " xlower2=",xlower2,"xupper2=",xupper2,"ylower2=",ylower2,"yupper2=",yupper2)
			trace("m=",m,"b=",b,"M=",M,"B=",B)
		elseif traceLogResult then
			trace("Collision test was ", isCollsion, " at ",t.x,",",t.y, " xlower=",xlower,"xupper=",xupper,"ylower=",ylower,"yupper=",yupper, " xlower2=",xlower2,"xupper2=",xupper2,"ylower2=",ylower2,"yupper2=",yupper2)
			trace("m=",m,"b=",b,"M=",M,"B=",B)
		end
	end
	if isCollsion then 
		return t 
	end
end

function util.checkIfPointLiesWithinVerticies(point, verticies)
	local count = 0 
	local testPoint = vec3.new(math.huge, point.y, point.z)
	
	-- Ray casting algorithm
	for i = 1, #verticies do 
		local p0 = i == 1 and verticies[#verticies] or verticies[i-1]
		local p1 = verticies[i]
		if util.checkFor2dCollisionBetweenPoints(p0, p1, point, testPoint) then 
			count = count+ 1
		end 
	end 
	trace("checkIfPointLiesWithinVerticies found",count,"items")
	return count % 2 == 1
end

function util.getNextFrozenNode(node)
	for i, seg in pairs(util.getSegmentsForNode(node) ) do
		local edge = util.getEdge(seg)
		if node~=edge.node0 and  util.isFrozenNode(edge.node0) then 
			return edge.node0 
		end
		if node~=edge.node1 and util.isFrozenNode(edge.node1) then 
			return edge.node0 
		end
	end

end

function util.invertEdge(edge) 
	return {
		p0 = edge.p1,
		p1 = edge.p0, 
		t0 = -1*edge.t1,
		t1 = -1*edge.t0	
	}
	
end 

function util.fullSolveForCollisionBetweenExistingAndProposedEdge(c, edgeId, newEdge, distanceFn, checkForDoubleTrack, allowEdgeExpansion, solveTheirOuterEdge, invertTheirs)
	local edge = util.getEdge(edgeId)
	local nodeBoundary = 0
	if not solveTheirOuterEdge and util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET) then 
		nodeBoundary = util.getEdgeWidth(edgeId) / 2 
	end
	local p1 = util.nodePos(edge.node0) - nodeBoundary * vec3.normalize(util.v3(edge.tangent0))
	local p2 = util.nodePos(edge.node1) + nodeBoundary * vec3.normalize(util.v3(edge.tangent1))
	 
	local existingEdgeAdjusted = false
	local adjVec
	if checkForDoubleTrack then
		local isHighway = util.getStreetTypeCategory(edgeId) == "highway"
		local count = 1
		local notNodes = {}
		local strict = true 
		local tolerance = 1
		for trackOffsets = 1, 4 do 
			for j = 1, 2 do 
				local otherNode0 = util.findDoubleTrackNode(edge.node0, nil, trackOffsets, tolerance, strict, notNodes)
				local otherNode1 = util.findDoubleTrackNode(edge.node1, nil, trackOffsets, tolerance, strict, notNodes)
				if isHighway then 
					otherNode0 = util.findParallelHighwayNode(edge.node0)
					otherNode1 = util.findParallelHighwayNode(edge.node1)
				end 
				 
				if otherNode0 and otherNode1 and util.findEdgeConnectingNodes(otherNode0, otherNode1) then 
					count = count + 1
					trace("Adjusting collision point for double track at edge ",edgeId)
				--	local adjp1 = 0.5*(p1 + util.nodePos(otherNode0))
				--	local adjp2 = 0.5*(p2 + util.nodePos(otherNode1))
				--	adjVec = 0.5*((p1-adjp1)+(p2-adjp2))
				--	p1 = adjp1
					--p2 = adjp2
					p1 = p1 + util.nodePos(otherNode0)
					p2 = p2 + util.nodePos(otherNode1)
					existingEdgeAdjusted = true
					if isHighway then 
						break 
					end
					notNodes[otherNode0]=true 
					notNodes[otherNode1]=true
				end
				if isHighway and count > 1 then 
					break 
				end
			end
		end
		p1 = 1/count*p1
		p2 = 1/count*p2
	end
	
	local existingEdge = { t0 = util.v3(edge.tangent0), t1=util.v3(edge.tangent1), p0=p1, p1=p2}
	if solveTheirOuterEdge then 
		local leftEdgeId = util.findNextEdgeInSameDirection(edgeId, edge.node0)
		local rightEdgeId = util.findNextEdgeInSameDirection(edgeId, edge.node1)
		if leftEdgeId and rightEdgeId then 
			local leftEdge = util.getEdge(leftEdgeId) 
			local rightEdge = util.getEdge(rightEdgeId) 
			local leftNode = leftEdge.node0 == edge.node0 and leftEdge.node1 or leftEdge.node0
			local rightNode = rightEdge.node0 == edge.node1 and rightEdge.node1 or rightEdge.node0
			local length = util.calculateSegmentLengthFromEdge(edge)+util.calculateSegmentLengthFromEdge(leftEdge)+util.calculate2dSegmentLengthFromEdge(rightEdge)
			existingEdge = { 
				t0 = length*vec3.normalize(leftNode == leftEdge.node0 and util.v3(leftEdge.tangent0) or -1*util.v3(leftEdge.tangent1)),
				t1 = length*vec3.normalize(rightNode == rightEdge.node0 and -1*util.v3(rightEdge.tangent0) or  util.v3(rightEdge.tangent1)),
				p0= util.nodePos(leftNode), 
				p1= util.nodePos(rightNode)
			}
		end 
	end 
	
	if not c then 
		c = util.hermite2(0.5, newEdge).p
	end
	
	if not distanceFn then 
		distanceFn = vec2.distance -- default to 2d as may want to offset heights 
	end
	local count = 0
	if invertTheirs then 
		existingEdge =  util.invertEdge(existingEdge) 
		trace("Inverting their edge")
	end 
	local otherEdge
	for i = 1, 200 do -- iterate the solution for a point that lies on both edges
		count = count+1
		local cBefore = c
		local theirSolution = util.solveForPosition(c, existingEdge, distanceFn)
		c=theirSolution.p1
		if not theirSolution.solutionConverged and not otherEdge and allowEdgeExpansion then
			trace("Their solution did not converge, increasing edge") 
			local node = vec2.distance(p1, c) < vec2.distance(p2, c) and edge.node0 or edge.node1
			otherEdge = util.findNextEdgeInSameDirection(edgeId, node)
			if otherEdge then 
				existingEdge= util.createCombinedEdgeFromExistingEdges(otherEdge, edgeId)
				if invertTheirs then 
					existingEdge = util.invertEdge(existingEdge)
				end 
				c=util.solveForPosition(c, existingEdge, distanceFn).p1
			end
		elseif not theirSolution.solutionConverged then
			c=util.solveForNearestHermitePosition(c, existingEdge, distanceFn)
		end
		local cMid = c
		local ourSolution = util.solveForPosition(c, newEdge,  distanceFn)
		c=ourSolution.p1
		if not ourSolution.solutionConverged then 
			--trace("Failed to converge to a solution finding our point , attempting to find hermite position")
			c=util.solveForNearestHermitePosition(c, newEdge, distanceFn)
		end
		if c.solutionIsNaN or theirSolution.solutionIsNaN or ourSolution.solutionIsNaN then 
			trace("WARNING! solveForCollision between proposed edges found NaN result")
			c.solutionIsNaN = true 
			break
		end 
	--	trace("At i=",i, " vec2.distance(cBefore, cMid)=",vec2.distance(cBefore, cMid), "vec2.distance(cMid,c)=",vec2.distance(cMid,c),"vec2.distance(cBefore,c)=",vec2.distance(cBefore,c))
		if vec2.distance(c, cBefore) < 0.1 and vec2.distance(c, cMid) < 0.1 then 
			break
		end
	end
	local maxDist = math.min(distanceFn(p1, p2), distanceFn(newEdge.p0, newEdge.p1))
	local solutionGap = distanceFn(util.solveForNearestHermitePosition(c, newEdge, distanceFn),util.solveForNearestHermitePosition(c, existingEdge, distanceFn))
	
	trace("Solution for collision converged after ",count," iterations. Maxdist=",maxDist, " solutionGap=",solutionGap)
	
	local existingEdgeSolution = util.solveForPosition(c, existingEdge,  vec2.distance)
	if adjVec then 
		existingEdgeSolution.p1 = adjVec+existingEdgeSolution.p1
	end
	local newEdgeSolution = util.solveForPosition(c, newEdge,  vec2.distance)
	return {
		c = c,
		existingEdgeSolution = existingEdgeSolution,
		newEdgeSolution = newEdgeSolution ,
		otherEdge = otherEdge,
		maxDist = maxDist,
		solutionGap = solutionGap,
		solutionConverged = newEdgeSolution.solutionConverged and existingEdgeSolution.solutionConverged,
		solutionIsNaN = newEdgeSolution.solutionIsNaN or existingEdgeSolution.solutionIsNaN
	}
end
function util.groundToggle()
	return util.newToggleButton("Standard", "ui/bridges/no_bridge.tga") 
end

function util.elevatedToggle()
	return util.newToggleButton("Elevated", "ui/bridges/cement.tga") 
end 

function util.undergroundToggle() 
	return util.newToggleButton("Underground", "ui/tunnels/railroad_old.tga") 
end

function util.createElevationButtonGroup(isPassenger) 
	local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	  
	local standard = util.groundToggle()
	local elevated = util.elevatedToggle()
	local underground = util.undergroundToggle()
	if isPassenger and util.isElevatedStationAvailable() then 
		elevated:setSelected(true, false)
	elseif util.isUndergroundStationAvailable() then 
		underground:setSelected(true, false)
	else 
		standard:setSelected(true, false)
	end
	buttonGroup:add(standard)
	buttonGroup:add(elevated)
	buttonGroup:add(underground)
	buttonGroup:setOneButtonMustAlwaysBeSelected(true)
	return buttonGroup, standard, elevated, underground
end

function util.memoize(inputFunction) 
	local cachedValue 
	return function() 
		if not cachedValue then 
			cachedValue = inputFunction()
		end 
		return cachedValue
	end 
end

function util.doDummyUpgrade(station) 
	if type(station)=="table" then 
		station = station.id 
	end
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local params = util.deepClone(construction.params)
	params.seed = nil
	return pcall(function() game.interface.upgradeConstruction(constructionId, construction.fileName, params)end)
end

function util.fullSolveForCollisionBetweenProposedEdges(edge1, edge2) 
	local c = util.solveForPositionHermiteFraction(0.5, edge1).p
	
	local count = 0
 
	for i = 1, 200 do -- iterate the solution for a point that lies on both edges
		count = count+1
		
		local cBefore = c
		local s1 = util.solveForPosition(c, edge1 )
		c = s1.p 
		
		local cMid = c
		local s2 = util.solveForPosition(c, edge2 )
		c = s2.p
		if s1.solutionIsNaN or s2.solutionIsNaN then 
			trace("WARNING! solveForCollision between proposed edges found NaN result")
			c.solutionIsNaN = true 
			break
		end 
		if util.distance(c, cBefore) < 0.1 and util.distance(c, cMid) < 0.1 and s1.solutionConverged and s2.solutionConverged then 
			break
		end
	end
	trace("Solution between proposed edges converged after ",count," iterations")
	return {
		c = c,
		edge1Solution = util.solveForPosition(c, edge1 ),
		edge2Solution = util.solveForPosition(c, edge2 ), 
	}
end 



function util.isIndustryOnSameCoast(mesh, entity) 
	return waterMeshUtil.isWaterMeshOnSameCoast(mesh, util.v3fromArr(game.interface.getEntity(entity).position))
end 

function util.maxBuildSlopeEdge(edgeId) 
	local trackEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_TRACK)
	if trackEdge then
		return api.res.trackTypeRep.get(trackEdge.trackType).maxSlopeBuild
	else 
		local streetEdge =  util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
		return util.streetTypeRepGet(streetEdge.streetType).maxSlopeBuild
	end
end


function util.checkCollisionBetweenExistingNodeAndProposedEdge(node, midP, tmid, proposedLength, proposedEdgeWidth) 
	local nodeSize = 0
	for i, seg in pairs(util.getSegmentsForNode(node)) do 
		nodeSize = math.max(nodeSize, util.getEdgeWidth(seg))
	end 
	local nodePos = util.nodePos(node)
	tmid = vec3.normalize(tmid)
	local tr = util.rotateXY(tmid, math.rad(90))
	local tl = util.rotateXY(tmid, -math.rad(90))
	local w = nodeSize / 2
	local p1 = nodePos + w*tmid
	local p2 = nodePos - w*tmid 
	local p1r = p1 + w*tr
	local p1l = p1 + w*tl
	local p2r = p2 + w*tr
	local p2l = p2 + w*tl
	
	
	local p3 = midP + 0.5*proposedLength * tmid 
	local p4 = midP - 0.5*proposedLength * tmid
	local w2 = proposedEdgeWidth / 2
	
	local p3r = p3 + w2*tr
	local p3l = p3 + w2*tl
	local p4r = p4 + w2*tr 
	local p4l = p4 + w2*tl
	return util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
		or util.checkFor2dCollisionBetweenPoints(p1r, p2r, p3r, p4r)
		or util.checkFor2dCollisionBetweenPoints(p1r, p2r, p3l, p4l)
		or util.checkFor2dCollisionBetweenPoints(p1l, p2l, p3r, p4r)
		or util.checkFor2dCollisionBetweenPoints(p1l, p2l, p3l, p4l)
end 
function util.checkCollisionBetweenExistingEdgeAndProposedEdge(edgeId, midP, tmid, proposedLength, proposedEdgeWidth) 
	local edge = util.getEdge(edgeId)
	local w = util.getEdgeWidth(edgeId)/2
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent1)
	t0.z = 0
	t1.z = 0 
	local tavg = vec3.normalize(t0+t1)
	
	local p1 = util.nodePos(edge.node0)
	local p2 = util.nodePos(edge.node1)
	local tr = util.rotateXY(tavg, math.rad(90))
	local tl = util.rotateXY(tavg, -math.rad(90))
	local p1r = p1 + w*tr
	local p1l = p1 + w*tl
	local p2r = p2 + w*tr
	local p2l = p2 + w*tl
	
	tmid = vec3.normalize(tmid)
	local p3 = midP + 0.5*proposedLength * tmid 
	local p4 = midP - 0.5*proposedLength * tmid
	local w2 = proposedEdgeWidth / 2
	local tr = util.rotateXY(tmid, math.rad(90))
	local tl = util.rotateXY(tmid, -math.rad(90))
	local p3r = p3 + w2*tr
	local p3l = p3 + w2*tl
	local p4r = p4 + w2*tr 
	local p4l = p4 + w2*tl
	return util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
		or util.checkFor2dCollisionBetweenPoints(p1r, p2r, p3r, p4r)
		or util.checkFor2dCollisionBetweenPoints(p1r, p2r, p3l, p4l)
		or util.checkFor2dCollisionBetweenPoints(p1l, p2l, p3r, p4r)
		or util.checkFor2dCollisionBetweenPoints(p1l, p2l, p3l, p4l)
end 

function util.checkCollisionBetweenExistingEdgeAndProposedNode(edgeId, p, t, pBefore, pAfter, tBefore, tAfter)
	local isBefore= false
	local edge = util.getEdge(edgeId)
	local p1 = util.nodePos(edge.node0)
	local p2 = util.nodePos(edge.node1)
	local p3 = p + 20 * vec3.normalize(t)
	local p4 = p 
	local c =  util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
	if not c then 
		p3 = p 
		p4 = p - 20 * vec3.normalize(t)
		c =  util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
		if c then 
			isBefore = true
		else 
			return  -- no collision point found
		end
	end
	
	
	local newEdge = isBefore and { t0 = tBefore, t1=t, p0=pBefore, p1=p} or {t0=t, t1=tAfter, p0=p, p1=pBefore}
	return util.fullSolveForCollisionBetweenExistingAndProposedEdge(c, edgeId, newEdge).c

end

function util.checkIfEdgesCollide(edgeId1, edgeId2)
	local edge1 = util.getEdge(edgeId1) 
	local edge2 = util.getEdge(edgeId2)
	if not edge1 or not edge2 then 
		error("Could not find edge "..tostring(edge1==nil).." "..tostring(edge2==nil).." for input "..tostring(edgeId1).." "..tostring(edgeId2))
	end 
	return util.checkFor2dCollisionBetweenPoints(
		util.nodePos(edge1.node0),
		util.nodePos(edge1.node1),
		util.nodePos(edge2.node0), 
		util.nodePos(edge2.node1))
end

function util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(edgeId, newEdge, checkForDoubleTrack, allowEdgeExpansion)
	local edge = util.getEdge(edgeId)
	local nodeBoundary = 0
	if util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET) then 
		if util.isDeadEndEdge(edgeId) then 
			nodeBoundary = util.getEdgeWidth(edgeId) / 2
		else 
			nodeBoundary = 1
		end 
	end
	local p1 = util.nodePos(edge.node0) - nodeBoundary * vec3.normalize(util.v3(edge.tangent0))
	local p2 = util.nodePos(edge.node1) + nodeBoundary * vec3.normalize(util.v3(edge.tangent1))
	local p3 = newEdge.p0
	local p4 = newEdge.p1 
	local c =  util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4)
	if c then 
		local solution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c, edgeId, newEdge, checkForDoubleTrack, allowEdgeExpansion)
		if solution.maxDist > solution.solutionGap then 
			return solution
		else 
			trace("Rejecting solution as it failed to converge")
		end
	end
end

function util.findEdgeConnectingNodes(node1, node2)
	if not api.engine.entityExists(node1) or not api.engine.entityExists(node2) or not util.getNode(node1) or not util.getNode(node2) then 
		trace("WARNING! findEdgeConnectingNodes, one or more node did not exist, aborting",node1,node2)
		return
	end 
	local segs1 = util.getSegmentsForNode(node1)
	local segs2 = util.getSegmentsForNode(node2)
	--trace("Looking for edge between",node1,node2,"found segs?",segs1~=nil,segs2~=nil)

	for i, edge in pairs(segs1) do
		for j, edge2 in pairs(segs2) do
			if edge == edge2 then 
				return edge
			end
		end
	end
end

function util.getEdgeIdFromEdge(edge) 
	if type(edge)=="number" then return edge end
	return util.findEdgeConnectingNodes(edge.node0, edge.node1)
end

util.isPointInsideIndustry = function(p) 
	-- this is a rough calculation intended that return false guarentees no collision
    -- industry is approx 160 square, so worst case distance to center is hypot(80, 80) ~ 120 
	for industryId, industry in pairs(game.interface.getEntities({radius=120, pos={p.x, p.y, p.z}}, {type="SIM_BUILDING", includeData=true})) do
		if util.distance(p, util.v3fromArr(industry.position)) <= 120 then
			return true
		end
	end
	return false
end
function util.pointHash2dFuzzy(p, fuzzFactor)
	return math.floor(0.5+p.x/fuzzFactor) + 100000 * math.floor(0.5+p.y/fuzzFactor)
end 
function util.pointHash2d(p)
	return math.floor(0.5+p.x) + 100000 * math.floor(0.5+p.y)
end 
function util.pointHash3d(p)
	return math.floor(0.5+p.x) + 100000 * math.floor(0.5+p.y) + (100000*100000) * math.floor(0.5+p.z)-- NB lua uses doubles up to 2^52 bits , this should be enough to combine (integer rounded) values
end 
function util.getFarmFields(industryId) 
	if util.farmFieldCache and util.farmFieldCache[industryId] then 
		return util.farmFieldCache[industryId]
	end
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industryId)
	local construction = util.getConstruction(constructionId)
 
	if construction.fileName == "industry/farm.con" then
		local p = util.v3(construction.transf:cols(3))
		local candidates = {}
		 api.engine.forEachEntityWithComponent(function(entity)  
			local field = util.getComponent(entity, api.type.ComponentType.FIELD)
			local dx = field.vertices[1].x-p.x 
			local dy = field.vertices[1].y-p.y 
			if math.sqrt(dx*dx + dy*dy) < 500 then -- hand written for peformance
				table.insert(candidates, field) 
			end 
		 end, api.type.ComponentType.FIELD)
		 local boxes = {}
		 for i, field in pairs(candidates) do 
			local xmax = -math.huge
			local xmin = math.huge 
			local ymax = -math.huge 
			local ymin = math.huge 
			for i, vertex in pairs(field.vertices) do 
				xmax = math.max(xmax, vertex.x)
				xmin = math.min(xmin, vertex.x)
				ymax = math.max(ymax, vertex.y)
				ymax = math.min(ymax, vertex.y)
			end
			table.insert(boxes, {
				isInBox = function(p)
					return p.x <= xmax and p.x>=xmin and p.y <= ymax and p.y>=ymin
				end 
			})
		end 
		if util.farmFieldCache then 
			util.farmFieldCache[industryId]=boxes 
		end 
		return boxes 
	end 
	if util.farmFieldCache then 
		util.farmFieldCache[industryId]={} 
	end 
	return {}

end 

util.isPointNearFarm = function(p)  
	local pointHash = util.pointHash2d(p)
	if pointHash ~= pointHash then return false end
	if util.farmCache and util.farmCache[pointHash] then 
		return util.farmCache[pointHash]==1
	end 
	
	for i, industryId in pairs(game.interface.getEntities({radius=300, pos={p.x, p.y, p.z}}, {type="SIM_BUILDING", includeData=false})) do
		for j, field in pairs(util.getFarmFields(industryId)) do 
			if field.isInBox(p) then 
				trace("Found a collision point inside a farm field at ",p.x,p.y)
				if util.farmCache then 
					util.farmCache[pointHash]=1
				end 
				return true 
			end 
		end
	end
	if util.farmCache then 
		util.farmCache[pointHash]=0
	end 
	return false
end
util.discoverCargoType = function(industry) 
	local cargoTypeSet = {}

	for k, v in pairs(api.res.cargoTypeRep.getAll()) do
		cargoTypeSet[v]=true
	end
	for k, v in pairs(industry.itemsProduced) do
		if cargoTypeSet[k] then
			return k
		end
	end

end



function util.checkForEdgeNearPosition(position, filterFn)
	if not filterFn then filterFn = function() return true end end
	for __, edge in pairs(util.searchForEntities(position, 90, "BASE_EDGE")) do
		if basicSearchForPositionOnEdge(edge, position) and filterFn(edge) then
			return edge.id
		end
	end
end

function util.filterYearFrom(item)
	if item.yearFrom == -1 then
		return false
	end
	return item.yearFrom <= util.year()  
end

function util.filterYearTo(item)
	if item.yearTo == -1 then  -- never visible
		return false
	end
	if item.yearTo == 0 then  -- always visible (no end)
		return true
	end
	return item.yearTo > util.year()
end

function util.filterYearFromAndTo(item)
	return item and util.filterYearFrom(item) and util.filterYearTo(item)
end
function util.newButton(text, icon, maxSize) 
	local comp 
	local hasText = text and string.len(text)>0
	local textView = hasText and api.gui.comp.TextView.new(_(text))
	trace("Translating",text,"translation was",_(text))
	local imageView = icon and api.gui.comp.ImageView.new(icon)
	if not maxSize then maxSize = 24 end
	if imageView then 
		imageView:setMaximumSize(api.gui.util.Size.new( maxSize, maxSize ))
	end
	if textView and imageView then 
		local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
		
		
		boxLayout:addItem(imageView)
		boxLayout:addItem(textView)
		comp = api.gui.comp.Component.new("AIBuilderButton")
		comp:setLayout(boxLayout)
	elseif textView then  
		comp = textView
	else 
		comp = imageView
	end 
	local button = api.gui.comp.Button.new(comp,false)
	button:addStyleClass("AIBuilderButton")
	return button
end
function util.newMutilIconButton(...) 
	local comp  = api.gui.comp.Component.new("AIBuilderButton")
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	for __, icon in pairs({...}) do 
		local imageView = api.gui.comp.ImageView.new(icon)
		local maxSize = 24 
		imageView:setMaximumSize(api.gui.util.Size.new( maxSize, maxSize ))
		boxLayout:addItem(imageView)
	end 
	  
	comp:setLayout(boxLayout)
	local button = api.gui.comp.Button.new(comp,false)
	button:addStyleClass("AIBuilderButton")
	return button
end
function util.newToggleButton(text, icon) 
	local comp 
	local textView = api.gui.comp.TextView.new(_(text))
	if icon then 
		local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
		local imageView = api.gui.comp.ImageView.new(icon)
		imageView:setMaximumSize(api.gui.util.Size.new( 24, 24 ))
		boxLayout:addItem(imageView)
		boxLayout:addItem(textView)
		comp = api.gui.comp.Component.new(" ")
		comp:setLayout(boxLayout)
	else 
		comp = textView
	end 
	local button = api.gui.comp.ToggleButton.new(comp)
--	button:addStyleClass("AIBuilderButton")
	return button
end

function util.createIconBar(...)
	trace("Creating icon bar")
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	for i, icon in pairs({...}) do
		trace("Adding icon ",icon)
		local imageView = api.gui.comp.ImageView.new(icon)
		imageView:setMaximumSize(api.gui.util.Size.new( 24, 24 ))
		boxLayout:addItem(imageView)
	end 
	local comp = api.gui.comp.Component.new(" ")
	comp:setLayout(boxLayout)
	return comp
end 
function util.evaluateAndSortFromScores(input, scoreWeights, scoreFns, minMaxScores)
	return util.evaluateWinnerFromScores(input, scoreWeights, scoreFns, true, minMaxScores)
end

function util.evaluateWinnerFromScores(input, scoreWeights, scoreFns, returnAllResults, minMaxScores)
	
	if scoreFns then
		--local beginScore = os.clock()
	--[[	for __, item in pairs(input) do
			item.scores = {}
			for i = 1, #scoreFns do
				item.scores[i]=scoreFns[i](item)
			end
		end]]--
		for i = 1, #scoreFns do
			local begin = os.clock()
			for __, item in pairs(input) do
				if i ==1 and not item.scores then 
					item.scores = {}
				end
				item.scores[i]=scoreFns[i](item)
			end
			--trace("Time taken to score at ",i," was ",(os.clock()-begin))
		end
		--trace("Time taken to score was ",(os.clock()-beginScore))
	end
	if not scoreWeights then 
		if not input[1] then
			if returnAllResults then 
				return input 
			else 
				return
			end
		end
		scoreWeights = {} 
		for k, v in pairs(input[1].scores) do 
			table.insert(scoreWeights, 50)
		end
	end
	 
	local scoreCount = #scoreWeights 
	assert(scoreCount>0)
	local minScores = {}
	local maxScores = {}
	for i = 1, scoreCount do 
		if minMaxScores then 
			maxScores[i]=minMaxScores[i]
		else 
			maxScores[i]=0
		end
		minScores[i]=math.huge
	end
	for __, item in pairs(input) do 
		for i = 1, scoreCount do  
			local rawScore = item.scores[i]
			if rawScore~=rawScore then
				trace("Warning, score was NAN for scoreindex ",i)
			else 
				maxScores[i] = math.max(maxScores[i], rawScore)
				minScores[i] = math.min(minScores[i], rawScore)
			end
		end
	end
	local scoreNormalisation = {} 
	for i = 1, scoreCount do
		if maxScores[i] == minScores[i] then 
			--trace("maxScores[i] == minScores[i] at ",i," maxScores[i]=",maxScores[i])
			scoreNormalisation[i] = 0 
		else 
			scoreNormalisation[i] = 100/(maxScores[i] - minScores[i])
		end
	end
	
	local scores = {}
	local scoresMap = {}
	
	for i, item in pairs(input) do
		item.scoreNormalised = {}
		item.score = 0
		for j = 1, scoreCount do 
			item.scoreNormalised[j] = (item.scores[j] - minScores[j])*scoreNormalisation[j]
			item.score = item.score + scoreWeights[j]*item.scoreNormalised[j]
		end  
		if item.score == item.score then -- filter anything gone NaN
			if returnAllResults then 
				if not scoresMap[item.score] then
					table.insert(scores, item.score)
					scoresMap[item.score] = {} 
				end
				table.insert(scoresMap[item.score], item)
			else 
				table.insert(scores, item.score)
				scoresMap[item.score] = item
			end 
		end
		
		item.i=i 
	end

	 
	table.sort(scores)
	local bestScore = scores[1]
	local bestItem = scoresMap[bestScore]
	
	if returnAllResults then
		local results = {} 
		for i = 1, #scores do 
			for score, item in pairs(scoresMap[scores[i]]) do 
				table.insert(results, item)
			end
		end
		--assert(bestItem == results[1])
		return results
	end
	

	--debugPrint({bestItem = bestItem, minScores=minScores, maxScores=maxScores, input=input})
	return bestItem
end

-- LLM-powered route selection wrapper
-- Always computes heuristic first, then optionally defers to LLM for final selection
function util.evaluateWinnerWithLLM(options, weights, scoreFns, context)
	-- 1. Compute heuristic scores first (provides fallback + context for LLM)
	local allResults = util.evaluateAndSortFromScores(options, weights, scoreFns)
	if #allResults == 0 then return nil end
	if #allResults == 1 then return allResults[1] end

	-- 2. Check daemon availability
	local socket_manager_ok, socket_manager = pcall(require, "socket_manager")
	if not socket_manager_ok or not socket_manager.is_daemon_running() then
		trace("[LLM] Daemon unavailable, using heuristic")
		return allResults[1]
	end

	-- 3. Build candidate list (top 5 to reduce token cost)
	local candidates = {}
	for i = 1, math.min(#allResults, 5) do
		local item = allResults[i]
		table.insert(candidates, {
			index = i,
			heuristic_rank = i,
			score = item.score or 0,
			data = util.extractLLMContext(item, context)
		})
	end

	-- 4. Call LLM
	trace("[LLM] Sending " .. #candidates .. " candidates to daemon")
	local response = socket_manager.evaluate_routes({
		context = context or {},
		candidates = candidates
	})

	-- 5. Use LLM choice or fallback
	local selected = response and tonumber(response.selected)
	if selected and selected >= 1 and selected <= #allResults then
		trace("[LLM] Selected #" .. selected .. ": " .. (response.reasoning or "no reason"))
		return allResults[selected]
	end

	trace("[LLM] No valid response, using heuristic fallback")
	return allResults[1]
end

-- Extract meaningful context from route option for LLM
function util.extractLLMContext(item, context)
	local data = {}

	-- Industry names
	if item.industry then data.industry = item.industry.name or "Unknown" end
	if item.industry1 then data.from = item.industry1.name or "Unknown" end
	if item.industry2 then data.to = item.industry2.name or "Unknown" end

	-- Cargo and distance
	if item.cargoType then data.cargo = item.cargoType end
	if item.distance then data.distance = math.floor(item.distance) end
	if item.routeLength then data.routeLength = math.floor(item.routeLength) end

	-- Town info
	if item.town then data.town = item.town.name end
	if item.town1 then data.town1 = item.town1.name end
	if item.town2 then data.town2 = item.town2.name end

	-- Add context type if provided
	if context and context.type then data.decision_type = context.type end

	return data
end

function util.evaluateWinnerFromSingleScore(items, scoreFn) 
	local input = {} 
	for k, v in pairs(items) do
		table.insert(input, { item=v }) -- need to wrap to allow scores to be added
	end
	if #input == 0 then return end
	local best = util.evaluateWinnerFromScores(input, { 100 }, { function(item) return scoreFn(item.item) end })
	if not best then 
		debugPrint({input=input, items=items}) 
	end
	return best.item -- unwrap
end
function util.evaluateAndSortFromSingleScore(items, scoreFn, limit) 
	local input = {} 
	for k, v in pairs(items) do
		table.insert(input, { item=v }) -- need to wrap to allow scores to be added
	end
	if #input == 0 then return input end
	local result = {} 
	
	local output = util.evaluateWinnerFromScores(input, { 100 }, { function(item) return scoreFn(item.item) end }, true)
	--if util.tracelog then debugPrint({input=input}) end 
	
	for i, item in pairs(output) do 
		--trace("Inserting item ",item)
		table.insert(result, item.item) -- unwrap
		if limit and #result >= limit then return result end
	end 
	return result 
end

function util.findOtherSegmentsForNode(node, segments)
	local segmentsSet = {}
	for _, seg in pairs(segments) do
		segmentsSet[seg]=true
	end
	local segs = util.getSegmentsForNode(node) 
	if not segs then	
		trace("WARNING! Unable to find segments for node ",node) 
		util.cacheNode2SegMaps()
		segs = util.getSegmentsForNode(node) 
		if not segs then 
			trace("WARNING! Still could not find") 
			return {}
		end
	end 
	local result = {}
	for i = 1, #segs do
		if not segmentsSet[segs[i]] then
			table.insert(result, segs[i])
		end
	end
	trace("found ",#result," other segments for node ",node)
	return result
end  
function util.findAllConnectedFreeTrackEdgesFollowingJunctionsRecursive(node,alreadySeen, edges) 

	local segs = util.getTrackSegmentsForNode(node)
	if not segs then 
		trace("WARNING! No segs found for node",node)
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps() 
		segs = util.getTrackSegmentsForNode(node)
	end
	local filteredSegs = {} 
	for i, seg in pairs(segs) do 
		if not util.isFrozenEdge(seg) and not alreadySeen[seg] then 
			local nextEdge = util.getEdge(seg)
			local nextNode =  nextEdge.node0 == node and nextEdge.node1 or nextEdge.node0
			alreadySeen[seg]=true
			table.insert(edges,nextEdge)
			util.findAllConnectedFreeTrackEdgesFollowingJunctionsRecursive(nextNode,alreadySeen, edges) 
		end 
	end 
end

function util.findAllConnectedFreeTrackEdgesFollowingJunctions(node) 
	local edges = {}
	local alreadySeen = {}
	util.findAllConnectedFreeTrackEdgesFollowingJunctionsRecursive(node,alreadySeen, edges) 
	trace("Found ",#edges," edges from node",node)
	return edges
end

function util.findAllConnectedFreeTrackEdgesAndStations(node, oneLineOnly, perpVec, excludeStartingJunctionEdges)
	local edges = {}
	local segs = util.getTrackSegmentsForNode(node)
	if not segs then 
		trace("WARNING! No segs found for node",node)
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps() 
		segs = util.getTrackSegmentsForNode(node)
	end
	local leftEdge = segs[1]
	local rightEdge = segs[2]
	local alreadySeen = {}
	local stations = {}
	local startNode = node
	local endNode = node 
	if #segs == 3 then 
		if oneLineOnly then 
			trace("findAllConnectedFreeTrackEdgesAndStations: Checking for oneLineOnly")
			local options = {}
			for i, seg in pairs(segs) do 
				if not util.isFrozenEdge(seg) then 
					table.insert(options, seg)
				else 
					leftEdge = seg
				end 
			end 
			
			if #options == 2 and perpVec then 
				local edge1 = util.getEdge(segs[1])
				local edge2 = util.getEdge(segs[2])
				local otherNode1 = edge1.node1 == node and edge1.node0 or edge1.node1
				local otherNode2 = edge2.node1 == node and edge2.node0 or edge2.node1
				local vector = util.vecBetweenNodes(otherNode1, otherNode2)
				local innerTangent = edge1.node1 == node and edge1.tangent1 or edge1.tangent0 
				local otherTangent1 = edge1.node1 == node and edge1.tangent0 or edge1.tangent1 
				local angle1 = util.signedAngle(perpVec, innerTangent)
				local angle2 = util.signedAngle(vector, otherTangent1)
				

				
			
				if util.sign(angle1)==util.sign(angle2) then -- expect the angles to be +/- 90 degrees, the sign determines the left or right handedness of them
					rightEdge = segs[2]
				else 
					rightEdge = segs[1]
				end 
				trace("findAllConnectedFreeTrackEdgesAndStations: Comparing the edges",segs[1],segs[2],"the angles were",math.deg(angle1),math.deg(angle2),"chosen",rightEdge)
			else 
				rightEdge = options[1]
			end 
			
--[[			if util.isFrozenEdge(segs[3]) then 
				if not util.isFrozenEdge(leftEdge) then 	
					trace("Setting left edge as frozenEdge")
					leftEdge = segs[3]
				elseif not util.isFrozenEdge(rightEdge) then 
					trace("Setting right edge as frozenEdge")
					rightEdge = segs[3]
				end
			end]]--
		else 
			if util.isFrozenEdge(leftEdge) then 
				leftEdge = segs[3]
			elseif util.isFrozenEdge(rightEdge) then 
				rightEdge = segs[3]
			end
		end
	end
	if excludeStartingJunctionEdges then 
		if leftEdge and util.isJunctionEdge(leftEdge) then 
			trace("findAllConnectedFreeTrackEdgesAndStations: excluding leftEdge",leftEdge)
			leftEdge = nil
		end 
		if rightEdge and util.isJunctionEdge(rightEdge) then 
			trace("findAllConnectedFreeTrackEdgesAndStations: excluding rightEdge",rightEdge)
			leftEdge = nil
		end 
	end 
	local nextEdge = leftEdge
	local function checkAndAddStation()
		if not nextEdge then 
			return 
		end
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(nextEdge)
		if constructionId ~= -1 then 
			local station = util.getConstruction(constructionId).stations[1]
			trace("Found edge",nextEdge,"with a construction",constructionId,"has station?",station)
			if station and  not util.contains(stations, station) then 
				table.insert(stations, station)
			end
			if not station and not oneLineOnly then 
				local p = util.getConstructionPosition(constructionId)
				local station = util.searchForFirstEntity(p, 150, "STATION", function(station) return station.carriers.RAIL end)
				trace("Attempted to find station nearby, found?",station)
				if station then 
					if not util.contains(stations, station.id) then 
						table.insert(stations, station.id)
					end
				end 
			end 
		end
	end
	local leftEdgeCount =0 
	if leftEdge then 
		local leftEdgeFull = util.getEdge(leftEdge)
		 
		local nextNode = leftEdgeFull.node0 == node and leftEdgeFull.node1 or leftEdgeFull.node0
		
		repeat
			checkAndAddStation()
			if oneLineOnly and util.isFrozenEdge(nextEdge) then break end
			nextEdge = util.findNextEdgeInSameDirection(nextEdge, nextNode, util.getTrackSegmentsForNode, true)
			if not nextEdge then break end
			if alreadySeen[nextEdge] then break end
			alreadySeen[nextEdge]=true
			local edge = util.getEdge(nextEdge)
			startNode = nextNode
			nextNode = nextNode == edge.node0 and edge.node1 or edge.node0 
			table.insert(edges, 1 , edge) -- insert reverse order  
		until util.isFrozenNode(nextNode)
		checkAndAddStation()
		leftEdgeCount = #edges
		if not alreadySeen[leftEdge] and not util.isFrozenEdge(leftEdge) then 
			alreadySeen[leftEdge]=true
			table.insert(edges,leftEdgeFull)
		end 
	end 
	if rightEdge then 
	
		local rightEdgeFull = util.getEdge(rightEdge)
		if not alreadySeen[rightEdge]  and not util.isFrozenEdge(rightEdge) then 
			alreadySeen[rightEdge]=true
			table.insert(edges,rightEdgeFull)
		end
		 nextEdge = rightEdge
		 local nextNode = rightEdgeFull.node0 == node and rightEdgeFull.node1 or rightEdgeFull.node0
		repeat 
			checkAndAddStation()
			if oneLineOnly and util.isFrozenEdge(nextEdge) then break end
			nextEdge = util.findNextEdgeInSameDirection(nextEdge, nextNode, util.getTrackSegmentsForNode, true)
			if not nextEdge then break end
			if alreadySeen[nextEdge] then break end
			alreadySeen[nextEdge]=true
			local edge = util.getEdge(nextEdge)
			endNode = nextNode
			nextNode = nextNode == edge.node0 and edge.node1 or edge.node0 
			table.insert(edges, edge)
			
		until util.isFrozenNode(nextNode)
		checkAndAddStation()
	end 
	local rightEdgeCount = #edges-leftEdgeCount
	trace("Found ",#edges," edges and ",#stations," stations connected to ",node," leftEdgeCount=",leftEdgeCount," rightEdgeCount=",rightEdgeCount, "startNode=",startNode,"endNode=",endNode)
	return {
		edges = edges,
		stations = stations,
		startNode = startNode, 
		endNode = endNode,
	}
end

function util.findAllConnectedFreeTrackEdges(node, oneLineOnly)
	return util.findAllConnectedFreeTrackEdgesAndStations(node, oneLineOnly).edges
end
function util.findBusStationForTown(town, position, excludeFull)
	local options =  {}
	for i, stationId in pairs(util.deepClone(api.engine.system.stationSystem.getStations(town))) do
		local station = util.getStation(stationId)
		if station and not station.cargo then 
			local construction = util.getConstructionForStation(stationId)
			if construction and construction.fileName=="station/street/modular_terminal.con"  then 
				local stationPos = util.getStationPosition(stationId)
				local score = 3
				local railStation = util.searchForFirstEntity(stationPos, 150, "STATION", function(station) return station.carriers.RAIL and not station.cargo  end)
				local airPort = util.searchForFirstEntity(stationPos, 150, "STATION", function(station) return station.carriers.AIR and not station.cargo  end)
				local shipPort = util.searchForFirstEntity(stationPos, 150, "STATION", function(station) return station.carriers.WATER and not station.cargo  end)
				if railStation then 
					score = 0 
				elseif airPort then 
					score = 1
				elseif shipPort then 
					score = 2
				end 
				local score2 = #api.engine.system.lineSystem.getLineStopsForStation(stationId) -- lower is better
				local score3 = 0
				if position then 
					score3 = util.distance(util.getStationPosition(stationId), position)
				end 
				if not excludeFull or score2 < 8  then 
					table.insert(options, {
						stationId = stationId,
						scores = { score, score2, score3 }
					})
				end
			end
		end
	end
	if #options > 0 then 
		return util.evaluateWinnerFromScores(options).stationId
	end 
end

function util.findBusStationOrBusStopForTown(town)
	local station = util.findBusStationForTown(town)
	if station then 
		return station 
	end
	for i, stationId in pairs(api.engine.system.stationSystem.getStations(town)) do
		local construction = util.getConstructionForStation(stationId)
		if not construction and not util.getComponent(stationId, api.type.ComponentType.STATION).cargo  then 
			return stationId
		end
	end 
end

function util.hasOnDeadEndNode(edgeId)
	local edge = util.getEdge(edgeId) 
	local segs1 = util.getSegmentsForNode(edge.node0)
	local segs2 = util.getSegmentsForNode(edge.node1) 
	return (#segs1 == 1) ~= (#segs2 == 1) -- exclusive OR
end 

function util.getMaxEdgeDeflectionAngle(edgeId) 
	local edge = util.getEdge(edgeId) 
	local t0 = util.v3(edge.tangent0)
	local t1 = util.v3(edge.tangent1) 
	local tNatural = util.nodePos(edge.node1) - util.nodePos(edge.node0)
	return math.max(math.abs(util.signedAngle(t0,t1)), math.max(math.abs(util.signedAngle(t0, tNatural)), math.abs(util.signedAngle(t1, tNatural))))
end 


function util.getCurrentTramTrackType()
	return util.year()>= game.config.tramCatenaryYearFrom and 2 or 1 
end

function util.copyExistingEdge(edgeId, nextEntityId, edgeObjectsToAdd, edgeObjectsToRemove) 
	local entity = api.type.SegmentAndEntity.new()
	if nextEntityId then 
		entity.entity=nextEntityId
	else 
		entity.entity = -edgeId
	end
	entity.playerOwned =util.getComponent(edgeId, api.type.ComponentType.PLAYER_OWNED)
	--trace("Set playerOwned")
	entity.comp = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
	--trace("Set edge")
	local trackEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_TRACK)
	if trackEdge then
		entity.trackEdge = trackEdge
		--trace("Set trackEdge")
		--trace("tracktype was ", entity.trackEdge.trackType)
		entity.type = 1
	else 
		entity.type = 0
		entity.streetEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
		
	end
	 
	if edgeObjectsToAdd    then 
		local newEdgeObjs = {}
		for i, edgeObj in pairs(entity.comp.objects) do 
			if edgeObjectsToRemove then 
				table.insert(edgeObjectsToRemove, edgeObj[1])
			end
			table.insert(edgeObjectsToAdd, util.copyEdgeObject(edgeObj, entity.entity))
			table.insert(newEdgeObjs, {-#edgeObjectsToAdd , edgeObj[2]})
		end 
		entity.comp.objects = newEdgeObjs 
		--trace("Set new edge objs")
	end 
	
	 
	return entity
end 

function util.isJunctionEdge(edgeId) 
	local edge = type(edgeId)=="number" and util.getEdge(edgeId) or edgeId
	return #util.getSegmentsForNode(edge.node0)> 2 or #util.getSegmentsForNode(edge.node1) > 2
end

function util.copyEdgeObject(edgeObj, edgeId, entity)
	local edgeObjId = edgeObj[1]
	local edgeObjFull = util.getComponent(edgeObjId, api.type.ComponentType.MODEL_INSTANCE_LIST).fatInstances[1]
	local position = util.v3(edgeObjFull.transf:cols(3))
	local newEdgeObj = api.type.SimpleStreetProposal.EdgeObject.new()
	local fileName = api.res.modelRep.getName(edgeObjFull.modelId)
	local naming = util.getComponent(edgeObjId, api.type.ComponentType.NAME)
	local originalEdgeId
	local left
	trace("copyEdgeObject: EdgeObj2 was ",edgeObj[2]," edgeObjId was ",edgeObjId," name was",naming.name)
	local oneWay = false
	local isSignal = false
	if edgeObj[2]== api.type.enum.EdgeObjectType.SIGNAL or edgeObj[2]== -api.type.enum.EdgeObjectType.SIGNAL then
		local signal = util.getComponent(edgeObjId, api.type.ComponentType.SIGNAL_LIST).signals[1]
		local edgePr =  signal.edgePr
		originalEdgeId  = edgePr.entity
		left = edgePr.index == 0
		isSignal = true
		oneWay = signal.type ==1
	else 
		originalEdgeId = util.getEdgeForBusStop(edgeObjId) 
		left = api.type.enum.EdgeObjectType.STOP_LEFT == edgeObj[2]
	end	
 
	
	local originalEdge = util.getEdge(originalEdgeId)
	local solution = util.solveForPositionOnExistingEdge(position,originalEdgeId)
	local param =  solution.frac
	local parallelVector = util.v3(edgeObjFull.transf:cols(0))
	local rotation = util.signedAngle(parallelVector, solution.t1)
	left = math.abs(rotation) > math.rad(90)
	trace("Edge object",edgeObjId ," on edge ",originalEdgeId,"Got rotation was ",math.deg(rotation)," left=",left)
	
	if not isSignal then 
		left = not left 
	end
    
	if entity then 
		local angle1 = math.abs(util.signedAngle(util.v3(originalEdge.tangent0), util.v3(entity.comp.tangent0)))
		local angle2 = math.abs(util.signedAngle(util.v3(originalEdge.tangent1), util.v3(entity.comp.tangent1)))
		trace("Inspecting relative rotation for signal replacement one edge ",originalEdgeId," angles were",math.deg(angle1), math.deg(angle2))
		if math.abs(math.rad(180)-angle1) < math.rad(15) and math.abs(math.rad(180)-angle2) < math.rad(15) then 
			trace("Edge ",originalEdgeId," appears to have been reversed, adjusting signals")
			left = not left 
			param = 1-param 
		end
	end
	
	
	newEdgeObj.edgeEntity = edgeId
	newEdgeObj.param = param
	newEdgeObj.oneWay = oneWay
	newEdgeObj.left = left
	newEdgeObj.model = fileName
	local playerOwned = util.getComponent(edgeObjId, api.type.ComponentType.PLAYER_OWNED)
	if playerOwned then
		newEdgeObj.playerEntity = playerOwned.player
	end
	newEdgeObj.name = naming.name
	return newEdgeObj
end
function util.findDepotLink(constructionId) 
	trace("finding depot link for ",constructionId)
	local construction =  util.getConstruction(constructionId)
	local edge = util.getComponent(construction.frozenEdges[1], api.type.ComponentType.BASE_EDGE)
	local frozenNode = construction.frozenNodes[1]
	local freeNode = edge.node0 == frozenNode and edge.node1 or edge.node0
	 
	local linkEdge =  util.findOtherSegmentsForNode(freeNode, {construction.frozenEdges[1]})[1]

	if linkEdge and not util.isFrozenEdge(linkEdge) then 
		local linkEdgeFull = util.getEdge(linkEdge)
		return {
			linkEdge = linkEdge, 
			depotNode = freeNode,
			p0 = util.nodePos(linkEdgeFull.node0),
			p1 = util.nodePos(linkEdgeFull.node1)
		}
	end
end

function util.isDepotLink(edgeId) 
	if util.isFrozenEdge(edgeId) then 
		return false 
	end
	local edge = util.getEdge(edgeId)
	for __ , node in pairs({edge.node0, edge.node1}) do 
		local segs = util.getSegmentsForNode(node)
		for i, seg in pairs(segs) do 
			local constructionId = util.isFrozenEdge(seg)
			if constructionId then 
				return #util.getConstruction(constructionId).depots > 0
		 	end 
		end 
	end 
	return false
end 

function util.copyExistingEdgeReplacingNode(edgeId, oldNode, newNode, nextEdgeId) 
	local entity = util.copyExistingEdge(edgeId, nextEdgeId)
	if entity.comp.node0 == oldNode then   
		entity.comp.node0 = newNode
	else 
		assert(entity.comp.node1==oldNode) 
		entity.comp.node1 = newNode
	end
	return entity
end

function util.getNumberOfStreetLanes(edgeId)
	local streetType 
	if type(edgeId)=="string" then 
		streetType = api.res.streetTypeRep.find(edgeId) 
	else 
		streetType = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET).streetType
	end
	return #util.streetTypeRepGet(streetType).laneConfigs
end

local function uncachedIsIndustryEdge(edgeId) 
	local streetEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
	if not streetEdge then 
		return false 
	end
	
	--[[if streetEdge.streetType == api.res.streetTypeRep.find("standard/country_small_old.lua") then 
		return false
	end--]]

	local industry = util.searchForFirstEntity(util.getEdgeMidPoint(edgeId), 200, "SIM_BUILDING")
	if not industry then 
		return false 
	end
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
	for __, index in pairs({0, util.getNumberOfStreetLanes(edgeId)-1}) do 
		local tpLinks = api.engine.system.tpNetLinkSystem.getLinkEntities(api.type.EdgeId.new(edgeId, index))
		for i, tpLinkId in pairs(tpLinks) do 
			local tpLink = util.getComponent(tpLinkId, api.type.ComponentType.TP_NET_LINK)
			if tpLink.to.edgeId.entity == constructionId or tpLink.from.edgeId.entity == constructionId then 
				trace("Found edge =",edgeId," WAS connected to industry ", industry.id)
				return true 
			end
		end
	end
	return false
end
function util.edgeHasTpLinks(edgeId) 
	if not util.tpLinksCache then 
		util.tpLinksCache  = {}
	end
	if util.tpLinksCache[edgeId]~= nil then 
		return util.tpLinksCache[edgeId]
	end 
	trace("Checking if edge has tplinks",edgeId)
	if not util.getStreetEdge(edgeId) then
		trace("Not a street edge")
		return false 
	end
	for __, index in pairs({0, util.getNumberOfStreetLanes(edgeId)-1}) do 
		local tpLinks = api.engine.system.tpNetLinkSystem.getLinkEntities(api.type.EdgeId.new(edgeId, index))
		if #tpLinks > 0 then 
			trace("Edge did have tpLinks")
			util.tpLinksCache[edgeId]=true 
			return true 
		end 
	end
	trace("No tp links found")
	util.tpLinksCache[edgeId]=false
	return false 
end 

function util.getParcelData()
	if not util.parcelData then 
		util.parcelData = api.engine.system.parcelSystem.getSegment2ParcelData()
	end 
	return util.parcelData
	
end 
function util.getParcel2BuildingMap()
	if not util.parcel2BuildingMap then 
		util.parcel2BuildingMap = api.engine.system.townBuildingSystem.getParcel2BuildingMap()
	end 
	return util.parcel2BuildingMap
end 
function util.edgeHasBuildings(edgeId)
	trace("edgeHasBuildings: inspecting",edgeId)
	--local p = util.getEdgeMidPoint(edgeId)
	--if util.searchForFirstEntity(p, 50, "TOWN_BUILDING") then 
		--local parcelData = util.getParcelData()

	-- NB cannot call the system getParcelData because it may crash for edges without parcels
--	local edgeParcelData = api.engine.system.parcelSystem.getParcelData(edgeId)
	local edgeParcelData = util.getParcelData()[edgeId]
	if edgeParcelData then 
		--local parcel2BuildingMap = util.getParcel2BuildingMap()
		for i, parcels in pairs({edgeParcelData.leftEntities,edgeParcelData.rightParcels}) do 
			for j, parcel in pairs(parcels) do 
				--trace("At i=",i,"j=",j,"checking if parcel",parcel,"hasBuilding")
				if api.engine.system.townBuildingSystem.hasBuilding(parcel) then 
					return true 
				end 
				--[[if parcel2BuildingMap[parcel] and #parcel2BuildingMap[parcel]>0 then 
					trace("edgeHasBuildings: DID find buildings for",edgeId)
					return true 
				end ]]---
			end 
		end 
	end 
	--end 
	trace("edgeHasBuildings: did NOT buildings for",edgeId)
	return false 
end 

function util.edgeHasTpLinksToStation(edgeId) 
	if not util.edgeHasTpLinks(edgeId) then 
		return false 
	end 
	for __, index in pairs({0, util.getNumberOfStreetLanes(edgeId)-1}) do 
		local tpLinks = api.engine.system.tpNetLinkSystem.getLinkEntities(api.type.EdgeId.new(edgeId, index)) 
		for j, link in pairs(tpLinks) do 
			local tpLink = util.getComponent(link, api.type.ComponentType.TP_NET_LINK)
			for k, linkedEntity in pairs({tpLink.from.edgeId.entity, tpLink.to.edgeId.entity}) do 
				local construction = util.getConstruction(linkedEntity)
				if construction and construction.stations[1] then 
					return true
				end 
			end  
		end
	end
	return false
end 

function util.isIndustryEdge(edgeId)
	if util.industryEdgeCache then 
		if not util.industryEdgeCache[edgeId] then 
			util.industryEdgeCache[edgeId] = uncachedIsIndustryEdge(edgeId)  and 1 or 0 
		end 
		return util.industryEdgeCache[edgeId]==1
	end 
	return uncachedIsIndustryEdge(edgeId)
end 

function util.isLinkEntitiesPresentOnStreet(edgeId) 
	local tpNetwork = util.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
	for i, tn in pairs(tpNetwork.edges) do 
		local linkedEntities = api.engine.system.tpNetLinkSystem.getLinkEntities(api.type.EdgeId.new(edgeId,i-1))
		for j, link in pairs(linkedEntities) do 
			return true
		end
	end
	return false

end 

function util.isDeadEndEdge(edgeId) 
	return (#util.getSegmentsForNode(util.getEdge(edgeId).node0)==1 or #util.getSegmentsForNode(util.getEdge(edgeId).node1)==1)
end

function util.isDeadEndEdgeNotIndustry(edgeId)  
	return not util.isIndustryEdge(edgeId) and util.isDeadEndEdge(edgeId) 
end


util.copyExistingEdgeReplacingNodeForCrossing = function(edgeId, oldNode, newNode, getOrMakeReplacedEdge ) 
	assert(oldNode~=newNode)
	
	local entity = getOrMakeReplacedEdge(edgeId)
	local isNode0 = false
	if entity.comp.node0 == oldNode then  
		isNode0=true
		entity.comp.node0 = newNode
	else 
		assert(entity.comp.node1==oldNode) 
		entity.comp.node1 = newNode
	end
	local nodeToRemove = isNode0 and entity.comp.node1 or entity.comp.node0
trace("copying edge ",edgeId," swapping ",oldNode," with ", newNode, " and removing node ", nodeToRemove)
	local nextSegs = util.findOtherSegmentsForNode(nodeToRemove, {   edgeId} )
	if   #nextSegs > 1 then 
		trace("Not doing any more because there were ",#nextSegs," for node")
		return 
	end
	local nextSegment = nextSegs[1]
	local originalTangent = util.v3(isNode0 and entity.comp.tangent0 or entity.comp.tangent1)
	local nextTangent = util.v3(isNode0 and entity.comp.tangent1 or entity.comp.tangent0)
	local totalTangentLength = vec3.length(originalTangent)
	local nextNode = nodeToRemove
	if nextSegment and not util.isFrozenEdge(nextSegment) and not util.isIndustryEdge(nextSegment) then
	 
		local nextEdge = util.getComponent(nextSegment, api.type.ComponentType.BASE_EDGE)
		
		nextTangent = util.v3(nodeToRemove == nextEdge.node0 and nextEdge.tangent1 or nextEdge.tangent0)
		nextNode = nodeToRemove == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
		totalTangentLength = vec3.length(originalTangent)+ vec3.length(nextTangent)
	end
	local correctedTangent0 = totalTangentLength * vec3.normalize(originalTangent)
	local correctedTangent1 = totalTangentLength * vec3.normalize(nextTangent)
	
	
	if nextSegment and (util.isDeadEndEdge(nextSegment) or 0 == #util.findOtherSegmentsForNode(nodeToRemove, { nextSegment,  edgeId} ) or util.isIndustryEdge(nextSegment))  then 
		trace("Skipping replacement of dead end edge")
		return
	end
	trace("Copying next edge ",nextSegment)
	local function checkAndSetTangent(tangent, t)
		local angle = util.signedAngle(tangent, t) 
		trace("checking tangent, angle between it and the old one was ",math.deg(angle))
		if math.abs(angle) > math.rad(90) then
			util.setTangent(tangent, -1*t)
		else 
			util.setTangent(tangent, t)
		end
	end
	if isNode0 then
		checkAndSetTangent(entity.comp.tangent0, correctedTangent0)	
		checkAndSetTangent(entity.comp.tangent1, correctedTangent1)
		entity.comp.node1 = nextNode
	else 
		checkAndSetTangent(entity.comp.tangent0, correctedTangent1)	
		checkAndSetTangent(entity.comp.tangent1, correctedTangent0) 
		entity.comp.node0 = nextNode
	end
 
	
	return entity
end

function util.getNodeAndTangentTable(edge) 
	if type(edge) == "number" then 
		edge = util.getEdge(edge)
	end 
	return {
		{
			node = edge.node0,
			tangent = util.v3(edge.tangent0)
			
		},
		{
			node = edge.node1,
			tangent = util.v3(edge.tangent1)
		}
	}
end

function util.findNearestAdjacentUnconnectedFreeNode(constructionId, node)
	local freeNodes = util.getFreeNodesForConstruction(constructionId)  
	local filteredNodes = {}
	local connectedNodes = {}
	for i, freeNode in pairs(freeNodes) do
		if node~=freeNode and util.distBetweenNodes(node, freeNode) < 80  then
			if  #util.getSegmentsForNode(freeNode)==1 then 
				table.insert(filteredNodes, freeNode)
			else 
				table.insert(connectedNodes, freeNode)
			end 
		end
	end
	local filteredNodes2 = {}
	
	for i, node1 in pairs(filteredNodes) do 
		local isOk = true 
		local distToTarget = util.distBetweenNodes(node1, node)
		for j, node2 in pairs(connectedNodes) do 
			local dist1 = util.distBetweenNodes(node1, node2)
			local dist2 = util.distBetweenNodes(node, node2)
			trace("Inspecting dead end node",node1,"comparing to connected node",node2,"dist was",distToTarget,"dist1=",dist1,"dist2=",dist2)
			if dist1 < distToTarget and dist2 < distToTarget  then -- need to exclude any nodes that are in between the target and proposed
				isOk = false 
				break 
			end 
		end 
		trace("Inspecting node",node1,"isOk?",isOk)
		if isOk then 
			table.insert(filteredNodes2, node1)
		end 
	end 
	
	if #filteredNodes2 > 0 then
		return util.findClosestNode(filteredNodes, node)
	end
end
function util.round(number)
	return math.floor(0.5+number)
end 
function util.isStationTerminus(station) 
	local construction = util.getConstructionForStation(station)
	if not construction then 
		return false 
	end
	if  construction.params.templateIndex then 
		return construction.params.templateIndex % 2 == 1
	end 
	local mainBuildingSlotId = 3400000 
	local terminusOffset = 300000
	local tenThousand = 10000
	
	--3701940 is a terminus
	local expectedId = (mainBuildingSlotId+terminusOffset)/tenThousand
	for moduleId, moduleDetails in pairs(construction.params.modules) do 
		if string.find(moduleDetails.name, "building") then 
			local truncated = util.round(moduleId / tenThousand)
			trace("Inspecting moduleId", moduleId, "comparing the truncated",truncated," to expected", expectedId)
			if truncated == expectedId then 
				return true 
			end
		end 
	end 
									  -- 3400000
									  --  300000
	--return construction.params.modules[3699960] -- address of the "head" building, not sure how reliable this is
	return false
end 

util.findFreeConnectedEdgesAndNodesForConstruction = function (constructionId)
	local result ={}
	local freeNodes = util.getFreeNodesForConstruction(constructionId)  
	
	local frozenEdgeSet = {}
	local construction = util.getConstruction(constructionId)
	local isTerminus= construction.params.templateIndex and construction.params.templateIndex % 2 == 1
	for i, edge in pairs(construction.frozenEdges) do
		frozenEdgeSet[edge]=true
	end
	for __, node in pairs(freeNodes) do
		local edges = util.deepClone(util.getSegmentsForNode(node) )
		for i = 1, #edges do
			local edge = edges[i]
			if not frozenEdgeSet[edge] then 
				result[edge]=node
			end
		end
	end
	trace("found ",util.size(result)," connnected nodes for ", constructionId)
	return result
end
function util.getOccupiedTerminalSet(stationId)
	local station = util.getStation(stationId)
	local terminals = #station.terminals 
	-- trace(debug.traceback())
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
	local stationGroupComp = util.getComponent(stationGroup, api.type.ComponentType.STATION_GROUP)
	local stationIdx = util.indexOf(stationGroupComp.stations, stationId) - 1
	local usedTerminals = {}
	for terminal =0 , terminals-1 do 
		local lineStopsForTerminal = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal)
		for i , lineId in pairs(lineStopsForTerminal ) do 
			if not usedTerminals[terminal] then 
				usedTerminals[terminal]=true 
			end 
			local line = util.getLine(lineId)
			for __, stop in pairs(line.stops) do 
				if stop.stationGroup == stationGroup and stop.station == stationIdx then 
					--trace("getOccupiedTerminalSet: Checking the alternativeTerminal at ",stop.stationGroup," for stationIdx",stationIdx)
					for __, alternativeTerminal in pairs(stop.alternativeTerminals) do 
						if alternativeTerminal.station == stationIdx and not usedTerminals[alternativeTerminal.terminal] then 
							 usedTerminals[alternativeTerminal.terminal]=true
						end 
					end 
				end 
			end 
		end 
	end 
	--trace("getOccupiedTerminalSet: end")
	return usedTerminals
end
function util.countFreeTerminalsForStation(stationId) 
	local station = util.getStation(stationId)
	local terminals = #station.terminals 
	local usedTerminals = util.getOccupiedTerminalSet(stationId)
	local numFreeTerminals =  terminals - util.size(usedTerminals)
	--trace("The numFreeTerminals for ",stationId," was ",numFreeTerminals)
	return numFreeTerminals
end

local function findPathToDeadEndNode(node) 
	trace("Checking findPathToDeadEndNode for ",node)
	local segs = util.getSegmentsForNode(node)
	local segToUse 
	for i, seg in pairs(segs) do 
		if not util.isFrozenEdge(seg) then 
			segToUse = seg 
			break 
		end 
	end 
	local nextEdge = segToUse
	if not nextEdge then 
		trace("findPathToDeadEndNode: Did not find a unfrozen edge")
		return false
	end 
	local edge = util.getEdge(nextEdge)
	local nextNode = edge.node0 == node and edge.node1 or edge.node0
	for i = 1,15 do 
		if #util.getSegmentsForNode(nextNode) == 1 then 
			trace("Found dead end edge",node)
			return true 
		end 
		nextEdge = util.findNextEdgeInSameDirection(nextEdge, nextNode, util.getTrackSegmentsForNode)
		edge = util.getEdge(nextEdge)
		nextNode = edge.node0 == nextNode and edge.node1 or edge.node0
		if util.isFrozenEdge(nextEdge) then 
			trace("Did not find dead end edge as it was frozen at",nextEdge)
			return false 
		end
	end 
	trace("Did not find dead end node")
	return false 
end 


function util.countFreeUnconnectedTerminalsForStation(stationId)
	local count = 0
	local usedTerminals = util.getOccupiedTerminalSet(stationId)
	local terminalToFreeNodesMap = util.getTerminalToFreeNodesMapForStation(stationId)
	for terminalId, nodes in pairs(terminalToFreeNodesMap) do 
		if not usedTerminals[terminalId-1] then 
			for i, node in pairs(nodes) do 
				if #util.getSegmentsForNode(node)==1 or findPathToDeadEndNode(node) then 
					count = count + 1 
					break 
				end
			end
		end
	end
	if util.tracelog then 
		local freeTerminals = util.countFreeTerminalsForStation(stationId) 
		debugPrint({usedTerminals=usedTerminals, terminalToFreeNodesMap=terminalToFreeNodesMap})
		assert(count <= freeTerminals,"expected <= "..freeTerminals.." but was "..count.." at station",stationId)
	end
	return count
end 


function util.getMinMaxEdgeHeights(edgeId)
	local edge = util.getEdge(edgeId)
	local p0 = util.nodePos(edge.node0)
	local p1 = util.nodePos(edge.node1)
	local pMid = util.solveForPositionHermiteFractionExistingEdge(0.5, edgeId).p
	-- technically this might not give exactly the min / max but close enough
	local minZ = math.min(p0.z,math.min( p1.z, pMid.z)) 
	local maxZ = math.max(p0.z,math.max(p1.z, pMid.z))
	
	return minZ, maxZ
end 

function util.getOtherNodeForEdge(edgeId, node)
	local edge = util.getEdge(edgeId)
	return edge.node0 == node and edge.node1 or edge.node0
end
util.getTerminalToFreeNodesMapForStation = function(stationId) 
	util.lazyCacheNode2SegMaps()
	local freeNodesSet= {}
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
		if constructionId == -1 then -- got the constructionId not the stationId
			constructionId = stationId
			stationId = util.getConstruction(constructionId).stations[1]
		end
	for i, node in pairs(util.getFreeNodesForConstruction(constructionId)) do
		freeNodesSet[node]=true
	end
	local vehicleNodes = {}
	local station = util.getComponent(stationId, api.type.ComponentType.STATION)
	for i, t in pairs(station.terminals) do 
		vehicleNodes[i] = t.vehicleNodeId.entity
	end
	local result = {}
	for i, node in pairs(vehicleNodes) do 
		local segs = util.getSegmentsForNode(node) 
		local left = segs[1]
		local right = segs[2]
		
		for j, seg in pairs({left, right}) do
			local nextNode = util.getOtherNodeForEdge(seg, node)
			local nextSeg = seg 
			local found = false
			local count =0 
			repeat  
				count = count + 1
				local nextSegs = util.getSegmentsForNode(nextNode)
				if freeNodesSet[nextNode] then
					if not result[i] then
						result[i]={}
					end
					table.insert(result[i],nextNode)
					found = true
				else 
					nextSeg = nextSegs[1] == nextSeg and nextSegs[2] or nextSegs[1]
					if not nextSeg then	
						break 
					end
					nextNode = util.getOtherNodeForEdge(nextSeg, nextNode)
				end
			until found or count > 1000
		end
	
	end
	trace("getTerminalToFreeNodesMapForStation found ",util.size(result)," free nodes for ", stationId)
	return result

end

function util.getAllFreeNodesForStation(stationId)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then -- got the constructionId not the stationId
		constructionId = stationId
	end 
	return util.getFreeNodesForConstruction(constructionId)
end
function util.isFreeTerminalZeroBased(stationId, terminal) 
	local occupiedTerminals = util.getOccupiedTerminalSet(stationId)
	return not occupiedTerminals[terminal]
end
function util.isFreeTerminalOneBased(stationId, terminal) 
	return util.isFreeTerminalZeroBased(stationId,terminal-1) 
end

function util.getFreeNodesForFreeTerminalsForStation(stationId ) 
	if util.freeNodesForFreeTerminalsForStationCache and util.freeNodesForFreeTerminalsForStationCache[stationId] then 
		return util.freeNodesForFreeTerminalsForStationCache[stationId]
	end 
	local originalStationId = stationId
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then -- got the constructionId not the stationId
		constructionId = stationId
		stationId = util.getConstruction(constructionId).stations[1]
	end
	
	local terminalToNodes = util.getTerminalToFreeNodesMapForStation(stationId) 
	local result = {}
	local alreadySeen = {} 
	local occupiedTerminals = util.getOccupiedTerminalSet(stationId)
	local station = util.getStation(stationId)
	for i, t in pairs(station.terminals) do
		if not occupiedTerminals[i-1] then
			if not terminalToNodes[i] then 
				trace("Could not find nodes for terminal at",i,"stationId=",stationId)
				debugPrint({terminalToNodes=terminalToNodes,station=station,occupiedTerminals=occupiedTerminals})
				error("Could not find nodes for terminal at "..i.." stationId="..stationId)
			end 
			for j, node in pairs(terminalToNodes[i]) do
				if not alreadySeen[node] then 
					alreadySeen[node] = true
					trace("Found node",node," for station ",stationId," at terminal ",i)
					table.insert(result, node)
				end 
			end
		end
	end
	 
	trace("getFreeNodesForFreeTerminalsForStation found ",#result," free nodes for ", stationId)
	if util.freeNodesForFreeTerminalsForStationCache then 
		util.freeNodesForFreeTerminalsForStationCache[originalStationId]=result
	end 
	return result
end

function util.isRailroadCrossing(node)
	return #util.getStreetSegmentsForNode(node)>0 and #util.getTrackSegmentsForNode(node)>0
end 


function util.isOldEdge(edgeId)
	local streetEdge = util.getStreetEdge(edgeId)
	local edgeType = util.getStreetTypeRep()[streetEdge.streetType]
	return edgeType.yearTo > 0 and edgeType.yearTo <= util.year() -- N.B. 0 and -1 are special values meaning (I think "forever" and "never"), and the yearTo is exclusive 
end

function util.getNewFromOldStreetType(streetType)
	local oldName = api.res.streetTypeRep.getName(streetType)
	local newName = string.gsub(oldName, "old","new") -- potentially could be made more robust
	local newStreetType = api.res.streetTypeRep.find(newName)
	if newStreetType ~= -1 then 
		return newStreetType
	end 
	trace("WARNING! Could not find a substiute for streetType",streetType,"using oldName=",oldName,"newName=",newName)
	return streetType
end

util.getFreeNodesToTerminalMapForStation = function(stationId)
	local result = {}
	for terminalId, nodes in pairs(util.getTerminalToFreeNodesMapForStation(stationId)) do 
		for i, node in pairs(nodes) do 
			result[node]=terminalId
		end
	end
	return result
end


function util.getComplementaryStationNode(node)
	local constructionId = util.isNodeConnectedToFrozenEdge(node)
	if not constructionId then 
		trace("WARNING! getComplementaryStationNode: Given a node not connected to a construction",node)
		return 
	end 
	 
	local nodesToTerminals = util.getFreeNodesToTerminalMapForStation(constructionId ) 
	local terminal = nodesToTerminals[node]
	local terminalsToNodes = util.getTerminalToFreeNodesMapForStation(constructionId)
	local nodes = terminalsToNodes[terminal]
	trace("Looking up terminal to node for station",constructionId,"got",node,"found nodes?",nodes)
	if not nodes then 
		debugPrint({nodesToTerminals=nodesToTerminals, terminal=terminal, terminalToNodes=terminalToNodes})
	end 
	if #nodes > 1 then 
		local node1 = nodes[1]
		local node2 = nodes[2]
		assert(node == node1 or node == node2)
		local  result = node1 == node and node2 or node1 
		trace("getComplementaryStationNode: returning",result,"for node",node)
		return result
	end 
	
end 
function util.isSingleSourceAndOutputIndustry(industry)
	if not industry.stockList then 
		return false 
	end
	return util.getConstruction(industry.stockList).fileName == "industry/construction_material.con" --TODO unhardcode
	 
end 
function util.isCongestedIndustry(industry)
	if not industry.stockList then 
		return false 
	end
	return util.getConstruction(industry.stockList).fileName == "industry/steel_mill.con" --TODO unhardcode
end 
function util.isPrimaryIndustry(industry) 
	return industry.itemsConsumed and industry.itemsConsumed._sum == 0 and industry.itemsProduced._sum > 0
end
function util.getFreeTerminal(stationId)
	local station = util.getStation(stationId)
	for i, t in pairs(station.terminals) do
		if #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, i-1)==0 then
			return i 
		end 
	end
end 
function util.getFreeTerminals(stationId)
	local result = {}
	local station = util.getStation(stationId)
	for i, t in pairs(station.terminals) do
		if #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, i-1)==0 then
			table.insert(result, i)
		end 
	end
	return result
end 
function util.getTerminalClosestToFreeTerminal(stationId)
	local freeNodes = util.getFreeNodesForFreeTerminalsForStation(stationId) 
	local options = {} 
	for terminalId, nodes in pairs(util.getTerminalToFreeNodesMapForStation(stationId)) do 
		for i, node in pairs(nodes) do 
			if not util.contains(freeNodes, node) then 
				for j , node2 in pairs(freeNodes) do 
					table.insert(options, 
						{node = node, scores = { util.distance(util.nodePos(node), util.nodePos(node2))}})
				end 
			end
		end 
	end
	trace("The options were",#options," the freeNodes were",#freeNodes, "for station",stationId)
	if #options == 0 then 
		return 1
	end
	local node = util.evaluateWinnerFromScores(options).node 
	return util.getFreeNodesToTerminalMapForStation(stationId)[node]
end

function util.getClosestDoubleFreeNodeToPosition(p, filterFn)
	if not filterFn then filterFn = function() return true end end
	local options = {}
	for i, node in pairs( game.interface.getEntities({radius=200, pos={p.x, p.y, p.z}}, {type="BASE_NODE", includeData=false})) do 
		if not util.isFrozenNode(node) and not util.isNodeConnectedToFrozenEdge(node) and #util.getTrackSegmentsForNode(node)==0 and filterFn(node) then 
			table.insert(options, node)
		end 
	end 
	return util.getNodeClosestToPosition(p, options)
end 

function util.getNodeClosestToPosition(p, nodes)
	if p.x~=p.x or p.y~=p.y then 
		error("NaN position provided")
	end 
	local dists = {}
	local distsMap = {}
	if not nodes then 
		nodes = game.interface.getEntities({radius=20, pos={p.x, p.y, p.z}}, {type="BASE_NODE", includeData=false})
	end
	for i, node in pairs(nodes) do 
		local nodePos = util.nodePos(node)
		local dist = util.distance(p, nodePos)
		--trace("inspecting node ",node," nodePos ",nodePos.x,nodePos.y," with ",p.x,p.y," dist=",dist  )
		table.insert(dists, dist)
		distsMap[dist]=node
	end
	table.sort(dists)
	if #dists ==0 then 
		return 
	end
	return distsMap[dists[1]]
end

function util.createOutFile() 
	print(getCurrentModId())
	local fileName = "res/textures/ui/testRead3.tga"
	local file = io.open(fileName,"wb")
	--file:write("hello")
	local width, height = 100, 100
	local pixels = {}
	for i = 1, width * height do
		table.insert(pixels, string.char(0, 0, 255)) -- R, G, B
	end

	-- Flatten pixel data
	local pixel_data = table.concat(pixels)
	  -- TGA Header (18 bytes)
    local header = string.char(
        0,          -- ID length
        0,          -- Color map type
        2,          -- Image type (uncompressed true-color)
        0,0,        -- Color map origin
        0,0,        -- Color map length
        0,          -- Color map depth
        0,0,        -- X-origin
        0,0,        -- Y-origin
        width % 256, math.floor(width / 256),
        height % 256, math.floor(height / 256),
        24,         -- Bits per pixel
        0           -- Image descriptor (origin bottom-left, no alpha)
    )
    file:write(header)

    -- Write pixels (in BGR format, bottom to top, left to right)
    for y = height - 1, 0, -1 do
        for x = 0, width - 1 do
            local index = (y * width + x) * 3 + 1
            local r, g, b = pixel_data:byte(index, index + 2)
            file:write(string.char(b, g, r))
        end
    end

   
	
	file:close()
	local fileName = "ui/testRead3.tga"
	--local fileName ="ui/construction/categories/asphalt@2x.tga"
	local imageView = api.gui.comp.ImageView.new(fileName)
	imageView:setImage(fileName, true)
	local window = api.gui.comp.Window.new("test", imageView)
	window:addHideOnCloseHandler()
	
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	local colors = {
		api.type.Vec3f.new(0,0,1),
		api.type.Vec3f.new(0,1,0),
		api.type.Vec3f.new(1,0,0),
		api.type.Vec3f.new(1,1,0),
	}
	
	local initialColor = colors[1]
	local widthOrMinusOne = -1
	local resetButton = false 
	local innerResetButton = false 
	local colorChooserButtobn = api.gui.comp.ColorChooserButton.new(colors, initialColor, widthOrMinusOne, resetButton , innerResetButton)
	layout:addItem(colorChooserButtobn)
	
	layout:addItem(api.gui.comp.Component.new("HorizonatalLine"))
	local colorChooser = api.gui.comp.ColorChooser.new(colors,resetButton)
	layout:addItem(colorChooser)
	layout:addItem(api.gui.comp.Component.new("HorizonatalLine"))
	
	local colorPicker = api.gui.comp.ColorPicker.new()
	layout:addItem(api.gui.comp.Component.new("HorizonatalLine"))
	layout:addItem(colorPicker)
	local maxX = 512
	local maxY = 512
	local rect = api.gui.util.Rect.new()
	
	local absLayout = api.gui.layout.AbsoluteLayout.new()
	local wrap = api.gui.comp.Component.new(" ")
	wrap:setLayout(absLayout)
	wrap:setMinimumSize(api.gui.util.Size.new(512,512))
	layout:addItem(wrap)
	
	local lineSize = 4
	local from = api.type.Vec2f.new(0, 0)
	local to = api.type.Vec2f.new(0, 0)
	 
	
		rect.x = 0-- math.floor(maxX/2)
		rect.y = math.floor(maxY/2)
		rect.w = maxX
		rect.h = maxY
	
	for i = 1, 1  do 
		local lineRender = api.gui.comp.LineRenderView.new()
		math.randomseed(os.clock()+i)
		
		lineRender:addLine(api.type.Vec2f.new(0,255*math.random()), api.type.Vec2f.new(255*math.random(),0))
		lineRender:setColor(api.type.Vec4f.new(1,1,1,1))
		lineRender:setWidth(1)
		absLayout:addItem(lineRender, rect)
	end 
		local lineRender = api.gui.comp.LineRenderView.new()
		lineRender:setColor(api.type.Vec4f.new(1,1,1,1))
		lineRender:setWidth(1)
	local maxNumElements = 2^13
	for i = 1, 8192  do 
	
		math.randomseed(os.clock()+i)
		
		lineRender:addLine(api.type.Vec2f.new(0,255*math.random()), api.type.Vec2f.new(255*math.random(),0))
		
	end 
	absLayout:addItem(lineRender, rect)
	local window2= api.gui.comp.Window.new("test", layout)
	window2:addHideOnCloseHandler()
end 

function util.getNodeAtPosition(p) 
	local node = util.getNodeClosestToPosition(p)
	if node and util.positionsEqual(p, util.nodePos(node),1) then 
		return node 
	end
end 
function util.positionsEqual2d (p0, p1, tolerance)
	if not tolerance then tolerance = 0.1 end
	
	
	
	return 
		math.abs(p0.x-p1.x)<tolerance
	and math.abs(p0.y-p1.y)<tolerance
end

function util.calculateGradient(p0, p1) 
	return (p1.z-p0.z) / vec2.distance(p0, p1)
end 

function util.findAllDoubleTrackNodes(startNode, tolerance, maxOffsets)
	if not tolerance then tolerance = 1 end
	if not maxOffsets then maxOffsets = 4 end
	local result = {}
	if #util.getTrackSegmentsForNode(startNode) == 0 then 
		return result
	end
	local edge = util.getEdge(util.getTrackSegmentsForNode(startNode)[1])
	local t = util.v3(edge.node0 == startNode and edge.tangent0 or edge.tangent1)
	local p = util.nodePos(startNode)
	for i, node in pairs(util.searchForEntities(p, 20+(maxOffsets*5), "BASE_NODE")) do
		if #util.getTrackSegmentsForNode(node.id) > 0 and node.id~=startNode then 
			for j = -maxOffsets, maxOffsets do 
				local expectedPos = util.nodePointPerpendicularOffset(p, t, j*trackWidth)
				if util.positionsEqual2d(expectedPos, util.v3fromArr(node.position),tolerance) then 
					table.insert(result, node.id)
					break
				end
			end 
		end
	end
	return result
end 

function util.findDoubleTrackNodeWithinSet(p, nodes, maxTrackOffsets)
	local notNodes = {}
	for trackOffsets = 1, maxTrackOffsets do 
		for j = 1, 2 do -- left / right 
			local candidateNode = util.findDoubleTrackNode(p, t, trackOffsets, tolerance, strict, notNodes)
			trace("looking for double track node within set, candidateNode=",candidateNode,"is withinSet?",nodes[candidateNode]==true)
			if nodes[candidateNode] then 
				return candidateNode
			else 
				notNodes[candidateNode]=true 
			end
		end 
	end 
	trace("WARNING! Unable to find a double track node within nodes")
	if util.tracelog then 
		debugPrint({p=p, nodes=nodes, maxTrackOffsets=maxTrackOffsets, notNodes=notNodes})
	end 
end 


function util.findDoubleTrackNodes(p, t, trackOffsets, tolerance, strict, notNodes, filterFn)
	if not tolerance then tolerance = 2 end
	if not trackOffsets then trackOffsets = 1 end
	if not notNodes then notNodes = {} end
	if not filterFn then filterFn = function() return true end end 
	local originalNode
	if type(p) == "number" then -- assume it is a nodeId
		if not t then  
			local segs = util.getTrackSegmentsForNode(p)
			if not segs then 
				trace("WARNING! findDoubleTrackNode: no segs found for",p)
				return {}
			end
			local edgeId = segs[1]
			if not edgeId then return {} end
			local edge = util.getEdge(edgeId)
			if not edge then	
				trace("WARNING! No edge found for",edgeId) 
				util.clearCacheNode2SegMaps() 
				edge = util.getEdge(util.getTrackSegmentsForNode(p)[1])
			end 
			t = util.v3(p == edge.node0 and edge.tangent0 or edge.tangent1)
		end	
		originalNode = p
		notNodes[originalNode]=true
		p = util.nodePos(p)
	else 
		local node = util.searchForNearestNode(p, 5, function(otherNode) 
			return #util.getTrackSegmentsForNode(otherNode.id)>0
		end) 
		if node and util.positionsEqual(p, util.v3fromArr(node.position), 0.1)  then 
			originalNode = node.id 
			notNodes[originalNode]=true
			--trace("findDoubleTrackNodes: using originalNode",originalNode," as exclusion node at ",p.x,p.y)
		end		
	end 
 
	local expectedPos = util.nodePointPerpendicularOffset(p, t, trackOffsets*trackWidth)
	local expectedPos2 = util.nodePointPerpendicularOffset(p, t, -trackOffsets*trackWidth)
	--trace("expectedPos=",expectedPos.x,expectedPos.y,"expectedPos2=",expectedPos2.x,expectedPos2.y)
	local candidates = {} 
	for i, node in pairs(util.searchForEntities(p, 20+(trackOffsets*5), "BASE_NODE")) do
		--trace("Inspecting node",node.id," at position ",node.position[1],node.position[2],node.position[3], "was notnode?",notNodes[node.id])
		if (util.positionsEqual(expectedPos, util.v3fromArr(node.position),tolerance, true ) or
			 util.positionsEqual(expectedPos2, util.v3fromArr(node.position),tolerance, true))
				and not notNodes[node.id] and filterFn(node.id) then 
			--	trace("Adding node as candidate")
			table.insert(candidates, node.id)
		else 
		--trace("Not adding node as candidate")
		end 
	end
--	trace("findDoubleTrackNodes: Found",#candidates, "expectedPos=",expectedPos.x,expectedPos.y,expectedPos.z,"expectedPos2=",expectedPos2.x, expectedPos2.y,expectedPos2.z, "tolerance=",tolerance)
	return candidates
end 
function util.findClosestDoubleTrackNode(targetP, p, t, trackOffsets, tolerance, strict, notNodes)
	return util.evaluateWinnerFromSingleScore(
		util.findDoubleTrackNodes(p, t, trackOffsets, tolerance, strict, notNodes),
		function(node)
			return util.distance(util.nodePos(node), targetP)
		end)
end 

function util.gatherDoubleTrackEdges(edgeId) 
	local result = {edgeId}
	if not util.getTrackEdge(edgeId) then 
		return result 
	end 
	local edge = util.getEdge(edgeId)
	local nodes = {}
	local alreadySeen = {}
	for i, node in pairs({edge.node0, edge.node1}) do 
		local t = i == 1 and util.v3(edge.tangent0)  or util.v3(edge.tangent1)
		for trackOffsets = 1,4 do  
			for j, node2 in pairs(util.findDoubleTrackNodes(node, t, trackOffsets, tolerance, strict, notNodes)) do 
				local thisTrackOffset = math.floor(util.distance(util.nodePos(node),util.nodePos(node2))/5+0.5)
				if i == 1 then 
					if not alreadySeen[node2] then 
						alreadySeen[node2]=true 
						nodes[thisTrackOffset]=node2
					end 
				else 
					if nodes[thisTrackOffset] then
						local otherEdge = util.findEdgeConnectingNodes(nodes[thisTrackOffset],node2)
						if otherEdge and not util.contains(result, otherEdge) then 
							table.insert(result, otherEdge)
							trace("Inserting the other edge",otherEdge,"as a double track edge for",edgeId)
						end 
					end 
				end 
			end  
			
			
		end 
	end 
	
	
	return result 
end 
	
function util.findDoubleTrackNode(p, t, trackOffsets, tolerance, strict, notNodes, filterFn)
	local candidates = util.findDoubleTrackNodes(p, t, trackOffsets, tolerance, strict, notNodes, filterFn)
	if #candidates == 1 then 
		return candidates[1]
	end
	if #candidates == 2 then 
		local node1 = candidates[1]
		local node2 = candidates[2]
		if util.isFrozenNode(node1) then 
			return node2 
		end
		if util.isFrozenNode(node2) then 
			return node1 
		end
		local chosenNode = node1
		local numberOfNodes = #util.findDoubleTrackNodes(node1, t, trackOffsets, tolerance, strict, {}, filterFn)
		if numberOfNodes > 1 then -- the other node in a 4 track layout
			chosenNode = node2 
		end
		trace("Found two doubleTrackNodes ",node1, " and ",node2," attempting to disambiguate, chosen ",chosenNode,"numberOfNodes=",numberOfNodes)
		--if util.tracelog then debugPrint({notNodes=notNodes}) end
		return chosenNode
	end 
	if strict then 
		return 
	end
	
	if type(p) == "number" then
		p = util.nodePos(p)
	end 
	-- fallback 
	local node = util.searchForNearestNode(p, 20, function(otherNode) 
		return math.abs(util.distance(util.nodePos(otherNode.id), p) -5 )<1 and #util.getTrackSegmentsForNode(otherNode.id)>0 and otherNode.id ~= originalNode
	end)
	if node then 
		return node.id 		
	end
	
	--trace("Could not find a node near ", expectedPos.x,expectedPos.y," or ", expectedPos2.x, expectedPos2.y)
end

function util.getClosestTransportNetworkNodePosition(p, constructionId, excludePositions)
	local positions = {}
	 --  27437 util.getComponent(27437, api.type.ComponentType.TRANSPORT_NETWORK).edges
	local tnComp = util.getComponent(constructionId, api.type.ComponentType.TRANSPORT_NETWORK)
	local z = util.getConstructionPosition(constructionId).z
	for i , tn in pairs(tnComp.edges) do
		for j, otherPos in pairs(excludePositions) do 
			if util.positionsEqual2d(tn.geometry.params.pos[1], otherPos) or 
				util.positionsEqual2d(tn.geometry.params.pos[2], otherPos)then 
				goto continue
			end
		end
		
		table.insert(positions, util.v2ToV3(tn.geometry.params.pos[1], z))
		table.insert(positions, util.v2ToV3(tn.geometry.params.pos[2], z))
		
		::continue::
	end
	return util.evaluateWinnerFromSingleScore(positions, function(p2) return vec2.distance(p, p2) end)
end

function util.positionsEqual(p0, p1, tolerance, testDistance)
	if not tolerance then
		tolerance = 0.01
		--trace("positionsEqual, defaulting tolerance to",tolerance)
	end
	if testDistance and util.distance(p0, p1) > tolerance then 
		return false 
	end
	return 
		math.abs(p0.x-p1.x)<tolerance
	and math.abs(p0.y-p1.y)<tolerance
	and math.abs(p0.z-p1.z)<tolerance
end
util.findFreeNodeForConstructionWithPosition = function (constructionId, p, tolerance)
	local freeNodes  = util.getFreeNodesForConstruction(constructionId)
	for __, node in pairs(freeNodes) do 
		if util.positionsEqual(util.nodePos(node), p, tolerance) then
			return node
		end
	end
	if util.tracelog then 
		debugPrint({noFreeNodesAtP=p, freeNodes=freeNodes}) 
	end
end

function util.getMaxLoan() 
	local function newCacheEntry() 
		util.maxLoanCacheEntry = { 
			maxLoan = util.getComponent(api.engine.util.getPlayer(), api.type.ComponentType.ACCOUNT).maximumLoan, -- the "account" is a very heavy weight object, want to avoid accessing it 
			year = util.year() -- for cache invalidation
		}
	end
	if not util.maxLoanCacheEntry or util.maxLoanCacheEntry.year ~= util.year() then 
		newCacheEntry() 
	end 
	return util.maxLoanCacheEntry.maxLoan
end 

util.scheduledBudget = 0
util.overdueBudget = 0 
-- Cash reserve the AI never spends below; the AI never borrows.
util.cashReserve = 1000000

function util.getAvailableBalance()
	-- Cash only: loan headroom is NEVER counted as spendable budget.
	local playerEntity = game.interface.getEntity(game.interface.getPlayer())
	local balance = playerEntity.balance 
	return balance
end 

function util.getAvailableBudget() 
	return util.getAvailableBalance()- util.scheduledBudget - util.cashReserve
end 

function util.isDoubleDeadEndEdge(edgeId) 
	local edge = util.getEdge(edgeId) 
	return #util.getSegmentsForNode(edge.node0)==1 and #util.getSegmentsForNode(edge.node1)==1
end 

function util.ensureBudget(amount) 
	trace("Processing request to ensure budget for",amount)
	local playerEntity = game.interface.getEntity(game.interface.getPlayer())
	local balance = playerEntity.balance 
	if amount > balance - util.cashReserve then 
		trace("ensureBudget: insufficient cash (balance=",balance," reserve=",util.cashReserve,") - NOT borrowing, skipping purchase")
		return false
	end 
	trace("Balance was sufficient")
	return true
end 

function util.hugeCircle() 
	return { pos = {0,0,0}, radius = math.huge }
end 

function util.getCarrierLookup() 
	if not util.carrierLookup then 
		util.carrierLookup  = getmetatable(api.type.enum.Carrier).__index -- this may be an expensive call so do once
 
	end 
	return util.carrierLookup
end 

function util.getCarrierForStation(stationId) 
	local station = util.getEntity(stationId) 
	for k, v in pairs(station.carriers) do 
		return util.getCarrierLookup()[k]
	end 
end 

function util.carrierNumberToString(carrier) 
	if type(carrier)=="number" then 
		for k, v in pairs(util.getCarrierLookup()) do 
			if v == carrier then 
				return k 
			end
		end 
	end 
	
	return carrier
end 

function util.isSafeToUpgradeToLargeHarbour(stationId)   
	-- need to check we have enough clearance for navigable waters
	local name = util.getName(stationId)
	trace("Checking if ",stationId,name," is safe to upgrade to large harbour")
	local construction = util.getConstructionForStation(stationId)
	local position = util.v3(construction.transf:cols(3))
	local stationParallelTangent = vec3.normalize(util.v3(construction.transf:cols(1)))
	for i = 100, 250 do 
		local p = position - i*stationParallelTangent 
		local th = util.th(p)
		if th > -10 then 
			trace("Determined ",stationId,name," is NOT safe to upgrade to large harbour based on test at ",p.x,p.y," th=",th)
			return false
		end 
	end 
	trace("Determined ",stationId,name," IS safe to upgrade to large harbour")
	return true 
end 

function util.copyProposal(proposal) 
	local newProposal = api.type.SimpleProposal.new() 
	for i = 1, #proposal.streetProposal.nodesToAdd do 
		newProposal.streetProposal.nodesToAdd[i] = proposal.streetProposal.nodesToAdd[i]
	end 
	for i = 1, #proposal.streetProposal.edgesToAdd do 
		newProposal.streetProposal.edgesToAdd[i] = proposal.streetProposal.edgesToAdd[i]
	end 
	for i = 1, #proposal.streetProposal.nodesToRemove do 
		newProposal.streetProposal.nodesToRemove[i] = proposal.streetProposal.nodesToRemove[i]
	end 
	for i = 1, #proposal.streetProposal.edgesToRemove do 
		newProposal.streetProposal.edgesToRemove[i] = proposal.streetProposal.edgesToRemove[i]
	end 
	for i = 1, #proposal.streetProposal.edgeObjectsToAdd do 
		newProposal.streetProposal.edgeObjectsToAdd[i] = proposal.streetProposal.edgeObjectsToAdd[i]
	end 
	for i = 1, #proposal.streetProposal.edgeObjectsToRemove do 
		newProposal.streetProposal.edgeObjectsToRemove[i] = proposal.streetProposal.edgeObjectsToRemove[i]
	end 
	for i = 1, #proposal.constructionsToAdd do 
		newProposal.constructionsToAdd[i] = proposal.constructionsToAdd[i]
	end 
	newProposal.constructionsToRemove = util.shallowClone(proposal.constructionsToRemove)
	return newProposal
end 

function util.findStationsMatchingTypeForTown(townId, stationType, carrier)
	local result ={}
	local stations = util.deepClone( api.engine.system.stationSystem.getStations(townId))-- seems to be needed to prevent random gc during iteration
	for __, stationId in pairs(stations) do
		local station = util.getComponent(stationId, api.type.ComponentType.STATION)
		if not station.cargo then
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
			if constructionId and constructionId ~= -1 then
				local construction = util.getConstruction(constructionId)
				if string.find(construction.fileName, stationType) and (not carrier or util.getEntity(stationId).carriers[carrier]) then -- vanilla file is "station/rail/modular_station/modular_station.con", broad search to support mods
					table.insert(result, stationId)
				end
			end 
		end
	end
	return result
end

function util.newLuaProposal() 
	local result = {} 
	result.streetProposal = {}
	result.streetProposal.nodesToAdd = {}
	result.streetProposal.edgesToAdd = {}
	result.streetProposal.nodesToRemove = {}
	result.streetProposal.edgesToRemove = {}
	result.streetProposal.edgeObjectsToAdd = {}
	result.streetProposal.edgeObjectsToRemove = {}
	
	result.constructionsToAdd = {}
	result.constructionsToRemove = {}
	result.old2new = {}
	result.isLuaProposal = true
	
	return result
end


function util.countRoadStationsForTown(townId) 
	return #util.findStationsMatchingTypeForTown(townId, "street")
end 
util.findPassengerTrainStationsForTown = function (townId)
	return util.findStationsMatchingTypeForTown(townId, "rail", "RAIL")
end
function util.findPassengerTrainStationsForTownWithCapacity(townId) 
	local res = {} 
	for i , station in pairs(util.findPassengerTrainStationsForTown(townId)) do 
		if #util.getStation(station).terminals < 11 then 
			table.insert(res, station)
		end 
	end 
	return res
end 


function util.findBestPassengerTrainStationForTown(townId) 
	local options = {}
	for __, station in pairs(util.findPassengerTrainStationsForTown(townId)) do 
		table.insert(options, {
			station = station,
			scores = { 256-util.countFreeTerminalsForStation(station) }
		})
	end 
	if #options == 0 then 	
		return 
	end 
	return util.evaluateWinnerFromScores(options).station
end 

function util.findAirportsForTown(townId)
	return util.findStationsMatchingTypeForTown(townId, "air")
end

function util.findPassengerHarboursForTown(townId)
	return util.findStationsMatchingTypeForTown(townId, "water")
end

util.gradientBetweenPoints = function(p0, p1)
	return (p1.z - p0.z) / vec2.distance(p0, p1)
end
function util.createScoreBetweenPoints(p0, p1, scoreFn)
	local numPoints = 100
	local distance = util.distance(p0,p1)
	
	local interval = math.ceil(distance / numPoints)
	--print("corrected interval = ",interval, "numPoints=",numPoints)
	local straightVec = vec3.normalize(p1 - p0)
	local perpVec = util.rotateXY(straightVec, math.rad(90))
	local score = 0 
	local numSamples = 0
	for i = 0, numPoints do
		for j = -2, 2 do
			local position = 100*j*perpVec + i*interval*straightVec + p0
			score = score + math.abs(scoreFn(position)) 
			numSamples = numSamples + 1
		end
	end
	if numSamples ==0 then 
		return 0 
	end 
	return score/numSamples
end
function util.nodeHasAtLeastOneNonUrbanNode(node)
	local segs = util.getStreetSegmentsForNode(node) 
	for i , seg in pairs(segs) do 
		if util.getStreetTypeCategory(seg) ~= "urban" then 
			return true 
		end
	end 	
	return false  
end 

function util.scoreWaterPoint(p)
	local th = util.th(p)
	local score = th < 0 and math.abs(4*th) or 0  
	local px = {-1,-1,1,1}
	local py = {1,-1,1,-1}
	for i = 1, 12 do 
		local offset =8
		local xoff = i <=8 and px[i%4+1] or 0
		local yoff = i >=4 and py[i%4+1] or 0
		local testP = vec2.new(p.x + xoff*offset, p.y+yoff*offset)
		th = util.th(testP)
		if th < 0 then score = score + math.abs(th) end
	end
	
	return score
	
	
	--local dist = util.distanceToNearestWaterVertex(p)
	--if dist == math.huge then
	--	return 0
	--end
	--return 1/ dist
end

function util.getWaterRouteDetailBetweenPoints(p0, p1) 

	local distance = util.distance(p0,p1) 
	local numPoints = math.ceil(distance / 90)
	local interval = math.ceil(distance / numPoints)
	trace("At a distance of ",distance,"calculated initial numPoints=",numPoints," sample interval:",interval, " interval*numPoints=",interval*numPoints)
	local straightVec = vec3.normalize(p1 - p0)
	local perpVec = util.rotateXY(straightVec, math.rad(90))
	local maxContinuousWater = 0
	local continuousWater = 0
	for i = 0, numPoints do
		local wasAllWater = true 
		for j = -2, 2 do
			local position = 100*j*perpVec + i*interval*straightVec + p0
			if util.th(position) > 0 then 
				wasAllWater = false 
				break 
			end
		end
		if wasAllWater then 
			continuousWater = continuousWater + 1 
			maxContinuousWater = math.max(maxContinuousWater, continuousWater)
		end 
	end
	
	local waterFraction = maxContinuousWater / numPoints
	local waterDistance = maxContinuousWater*interval
	return waterFraction, waterDistance
end 

util.scoreTerrainBetweenPoints = function(p0, p1, filterFn)  
	return util.createScoreBetweenPoints(p0, p1, function(p) return util.th(p)-p.z end)-- looking for deviations in terrain
end
util.scoreWaterBetweenPoints = function(p0, p1)
	return util.createScoreBetweenPoints(p0, p1, function(p) return util.scoreWaterPoint(p)  end)
end

function util.scoreFarmsBetweenPoints(p0, p1)
	return util.createScoreBetweenPoints(p0, p1, function(p) return util.isPointNearFarm(p) and 1 or 0 end)
end

function util.scoreEdgeCountBetweenPoints(p0, p1)
	return util.createScoreBetweenPoints(p0, p1, function(p) return util.countNearbyEntities(p, 50, "BASE_EDGE") end)
end
util.estimateRouteLength= function(points) 
	local result = 0
	for k, v in pairs(points) do
		--print("inspecting route length for ", v.entity)
		local edge = util.getComponent(v.entity, api.type.ComponentType.BASE_EDGE)
		if edge then 
			result = result + util.distance(util.nodePos(edge.node0), util.nodePos(edge.node1))			-- straight line distance small underestimate
		end
	end
	return result
end

function util.findEdgeConnectingPoints(p0, p1)
	local node0 = util.searchForNearestNode(p0,10)
	local node1 = util.searchForNearestNode(p1,10)
	if node0 and node1 then 
		return util.findEdgeConnectingNodes(node0.id, node1.id)
	end
end

function util.calculateRouteLength(edges)
	local distance = 0
	for i, edge in pairs(edges) do
		distance = distance + util.calculateSegmentLengthFromEdge(edge)
	end
	return distance
end



function util.calculateRouteLength2d(edges)
	local distance = 0
	for i, edge in pairs(edges) do
		distance = distance + util.calculate2dSegmentLengthFromEdge(edge)
	end
	return distance
end

function util.calculateEdgeGradient(edge) 
	if type(edge)=="number" then 
		edge = util.getEdge(edge)
	end
	local leftNodePos = util.nodePos(edge.node0)
	local rightNodePos = util.nodePos(edge.node1)
	local edgeGradient = (rightNodePos.z-leftNodePos.z) / util.calculate2dSegmentLengthFromEdge(edge)
	return edgeGradient
end

function util.calculateAngleConnectingEdges(edge1, edge2) 
	local commonNode = 	
		edge1.node0 == edge2.node0 and edge1.node0
	 or edge1.node1 == edge2.node0 and edge1.node1
	 or edge1.node0 == edge2.node1 and edge1.node0
	 or edge1.node1 == edge2.node1 and edge1.node1
	 
	local edge1Tangent = edge1.node0 == commonNode and edge1.tangent0 or edge1.tangent1
	local edge2Tangent = edge2.node0 == commonNode and edge2.tangent0 or edge2.tangent1
	local angle = math.abs(util.signedAngle(util.v3(edge1Tangent), util.v3(edge2Tangent)))
	if angle > math.rad(90) then 
		angle = math.abs(math.rad(180)-angle)
	end
	return angle
end

function util.checkIfStationInCatchmentArea(stationId, constructionId) 
	local tn = util.getComponent(constructionId, api.type.ComponentType.TRANSPORT_NETWORK)
	local catchmentAreaMap = api.engine.system.catchmentAreaSystem.getEdge2stationsMap() -- N.B. do not think we can deepClone this as relies on EdgeId keys
	for i, tnedge in pairs(tn.edges) do 
		for k = 1,2 do 
			local edgeId = api.type.EdgeId.new(tnedge.conns[k].entity, tnedge.conns[k].index) -- question is the conns[k] already of type EdgeId ?
			local stations = catchmentAreaMap[edgeId]
			if stations then 
				for __, station in pairs(stations) do 
					if station == stationId then 
						return true 
					end
				end
			end
		end
	end
	trace("The stationId",stationId,"was NOT found in the catchmentArea of",constructionId)
	return false
end
function util.checkIfStationInCatchmentAreaOfEdge(stationId, edgeId) 
	local tn = util.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
	local catchmentAreaMap = api.engine.system.catchmentAreaSystem.getEdge2stationsMap() -- N.B. do not think we can deepClone this as relies on EdgeId keys
	for i, tnedge in pairs(tn.edges) do 
		for k = 1,2 do 
			local edgeId = api.type.EdgeId.new(tnedge.conns[k].entity, tnedge.conns[k].index) -- question is the conns[k] already of type EdgeId ?
			local stations = catchmentAreaMap[edgeId]
			if stations then 
				for __, station in pairs(stations) do 
					if station == stationId then 
						return true 
					end
				end
			end
		end
	end
	trace("The stationId",stationId,"was NOT found in the catchmentArea of",edgeId)
	return false
end

function util.calculateMaxGradient(edges)
	local maxGradient = 0
	for i, edge in pairs(edges) do 
		maxGradient = math.max(maxGradient, math.abs(util.calculateEdgeGradient(edge)))
	end
	return maxGradient
end

function util.getMaxBuildGradient(edgeId)
	local trackEdge = util.getTrackEdge(edgeId) 
	if trackEdge then 
		return api.res.trackTypeRep.get(trackEdge.trackType).maxSlopeBuild
	else 
		local streetEdge = util.getStreetEdge(edgeId)
		return util.streetTypeRepGet(streetEdge.streetType).maxSlopeBuild
	end  
end

function util.getSignalIndexes(edges)
	local result = {}
	for i, edge in pairs(edges) do 
		for j = 1, #edge.objects do 
			if edge.objects[j][2] == api.type.enum.EdgeObjectType.SIGNAL then
				table.insert(result, i)
				break
			end
		end 
	end
	return result
end

util.copyEntity = function(edgeId, transformFn) 
		local entity = api.type.SegmentAndEntity.new()
		entity.entity = -edgeId
		entity.playerOwned =util.getComponent(edgeId, api.type.ComponentType.PLAYER_OWNED)
		entity.comp = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
		
		local trackEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_TRACK)
		if trackEdge then
			entity.trackEdge = trackEdge
		 
			entity.type = 1
		else 
			entity.type = 0
			entity.streetEdge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
			
		end
 
		if transformFn then transformFn(entity) end
		return entity
	end
 
function util.makelocateRow(industry)
	if not industry then 
		return api.gui.comp.TextView.new(_("Unknown"))
	end 
	if type(industry) == "number" then 
		industry = util.getEntity(industry)
	end 
	local boxLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	--local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate@2x.tga")
	--local imageView = api.gui.comp.ImageView.new("ui/design/window-content/locate_small@2x.tga")
	local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate.tga")
	local button = api.gui.comp.Button.new(imageView, true)
	button:onClick(function() 
		api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(industry.id, false)
	end)
	boxLayout:addItem(button)
	boxLayout:addItem(api.gui.comp.TextView.new(_(industry.name)))
	local comp= api.gui.comp.Component.new("")
	comp:setLayout(boxLayout)
	return comp
end

function util.makeSimplifiedLocateRow(entity)
	 
	--local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate@2x.tga")
	--local imageView = api.gui.comp.ImageView.new("ui/design/window-content/locate_small@2x.tga")
	local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate.tga")
	local button = api.gui.comp.Button.new(imageView, true)
	button:onClick(function() 
		pcall(function() api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(entity(), false)end)
	end)
	 
	return button
end

function util.isElevatedStationAvailable() 
	local constructionRepId = api.res.constructionRep.find("station/rail/modular_station/elevated_modular_station.con") 
	return -1~= constructionRepId and util.year() >= api.res.constructionRep.get(constructionRepId).availability.yearFrom 
end
function util.isUndergroundStationAvailable() 
	return -1 ~= api.res.constructionRep.find("station/rail/modular_station/underground_modular_station.con") 
end
function util.supportedRailStations() 
	return { 
		["station/rail/modular_station/modular_station.con"]=true,
		["station/rail/modular_station/underground_modular_station.con"]=true,
		["station/rail/modular_station/elevated_modular_station.con"]=true,
	}

end 
local function vec3ToString(p) 
	if not p then 
		return "unknown"
	end 
	return "["..tostring(p.x)..","..tostring(p.y)..","..tostring(p.z).."]"
end 

function util.newEdgeToString(entity, nodePosFn)
	local result = "[entity="..tostring(entity.entity).." connecting "..tostring(entity.comp.node0).." with "..tostring(entity.comp.node1) 
	if nodePosFn then 
		result = result.." t0="..vec3ToString(entity.comp.tangent0).." t1="..vec3ToString(entity.comp.tangent1).." p0="..vec3ToString(nodePosFn(entity.comp.node0)).." p1="..vec3ToString(nodePosFn(entity.comp.node1))
	end 
	return result.."]"
end 
function util.edgeToString(edgeId, edge)
	return "[edge="..tostring(edgeId).." connecting "..tostring(edge.node0).." with "..tostring(edge.node1).."]"
end 
function util.vecHasNan(vec)
	return vec.x ~= vec.x 
	or vec.y ~= vec.y
	or vec.z ~= vec.z
end 

function util.validateProposal(newProposal) -- better to fail fast than crash to desktop which happens even when trying to make test data
	local removedNodesMap = {}
	local removedEdgesMap = {}
	for i, edgeId in pairs(newProposal.streetProposal.edgesToRemove) do 
		assert(not removedEdgesMap[edgeId],"duplicated edge to remove "..tostring(edgeId))
		removedEdgesMap[edgeId]=true 
		local edge = util.getEdge(edgeId) 
		for __, node in pairs({edge.node0, edge.node1}) do 
			if not removedNodesMap[node] then 
				removedNodesMap[node]=1 
			else 
				removedNodesMap[node]=removedNodesMap[node]+1
			end 
		end 
	end 
	local removedNodesSet = {} 
	for i, node in pairs(newProposal.streetProposal.nodesToRemove) do 
		removedNodesSet[node]=i
	end 
	local uniquenessCheck = {}
	local newNodeSet ={}
	for i , newNode in pairs(newProposal.streetProposal.nodesToAdd) do 
		if uniquenessCheck[newNode.entity] then 
			debugPrint(newProposal)
			error("Failed uniqueness check at"..tostring(newNode.entity))
		end 
		uniquenessCheck[newNode.entity]=true 
		newNodeSet[newNode.entity]=true 
		if util.vecHasNan(newNode.comp.position) then 
			debugPrint(newProposal)
			error("newNode has Nan")
		end
	end 
	local newNodeToSegmentMap = {}
	local uniquenessCheck = {}
	for i, newEdge in pairs(newProposal.streetProposal.edgesToAdd) do 
		if uniquenessCheck[newEdge.entity] then 
			debugPrint(newProposal)
			error("Failed uniqueness check at"..tostring(newEdge.entity))
		end 
		uniquenessCheck[newEdge.entity] = true 
		for __, node in pairs({newEdge.comp.node0, newEdge.comp.node1}) do 
			if not newNodeToSegmentMap[node] then 
				newNodeToSegmentMap[node]= {}
			end 
			table.insert(newNodeToSegmentMap[node],-i) -- insert the index of the new edge
			if removedNodesMap[node] then				 
				removedNodesMap[node]=removedNodesMap[node]-1
			end 
			if removedNodesSet[node] then 
				debugPrint(newProposal)
				error("Tried to connect to removed node "..tostring(node))
			end 
			if node < 0 and not newNodeSet[node] then 
				debugPrint(newProposal)
				error("Unreferenced node "..tostring(node))
			end
		end
		if util.vecHasNan(newEdge.comp.tangent0) or util.vecHasNan(newEdge.comp.tangent1) then 
			debugPrint(newProposal)
			error("tangent has Nan")
		end 
	end 
	for node, edges in pairs(newNodeToSegmentMap) do 
		if node > 0 then 
			if not api.engine.entityExists(node) then 
				error("Node not exists "..tostring(node))
			end 
			for i, edge in pairs(util.getSegmentsForNode(node)) do 
				if not removedEdgesMap[edge] then 
					table.insert(edges, edge)
				end 
			end 
		end 
	end 
	
	local function getEdge(edgeId) 
		if edgeId < 0 then 
			return newProposal.streetProposal.edgesToAdd[-edgeId].comp
		else 
			return util.getEdge(edgeId)
		end 
	end 
	local function isStreetEdge(edgeId) 
		if edgeId < 0 then 
			return newProposal.streetProposal.edgesToAdd[-edgeId].type == 0
		else 
			return util.getStreetEdge(edgeId)
		end 
	end
	for node, edges in pairs(newNodeToSegmentMap) do -- if two roads enter a node at the same angle this can cause a crash later on by the games street developer when building towns
		for i, edgeId in pairs(edges) do 
			local edge = getEdge(edgeId)
			local ourNode0 = node == edge.node0
			for k, seg in pairs(edges) do 
				if seg ~= edgeId and  isStreetEdge(edgeId)  and  isStreetEdge(seg)  then 
					local otherSeg = getEdge(seg)
					
					local theirNode0 = otherSeg.node0 == node
					
					local theirTangent = util.v3(theirNode0 and otherSeg.tangent0 or otherSeg.tangent1)
					local ourTangent =   util.v3(ourNode0 and edge.tangent0 or edge.tangent1)
					if ourNode0 ~= theirNode0 then 
						theirTangent = -1*theirTangent
					end 
					local angle = math.abs(util.signedAngle(ourTangent, theirTangent))
					--trace("Inspecing angle between",edgeId, seg," angle was ",math.deg(angle))
					--maxAngles[j]=math.max(maxAngles[j], angle)
					if angle < math.rad(5) then 
						debugPrint(newProposal)
						trace("WARNING! Shallow angle detected at node",node,"angle was",angle,"between",edgeId,seg)
						error("Invalid setup for "..util.edgeToString(edgeId, edge).." "..util.edgeToString(seg, otherSeg).." angle was="..tostring(math.deg(angle)))
					end 
				end 
			end
		end  
	end 
	
	 
	local indexValid = true
	for node, count in pairs(removedNodesMap) do 
		if count == #util.getSegmentsForNode(node) then 
			if not removedNodesSet[node] then 
				trace("Adding in node",node," to remove")
				newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=node
			end 
		elseif removedNodesSet[node] and #newProposal.constructionsToRemove == 0 then 
			
			trace("WARNING! Node ",node," was removed but still referenced")
			if util.tracelog then print(debug.traceback()) end
			local index = removedNodesSet[node]
			if not indexValid then 
				index = util.indexOf(newProposal.streetProposal.nodesToRemove, node)
			end 
			newProposal.streetProposal.nodesToRemove[index]=nil
			indexValid = false
		end 
	end 
	for i, construction in pairs(newProposal.constructionsToAdd) do 
		if util.isTransfUnset(construction.transf) then 
			debugPrint(newProposal)
			error("Transf was unset") 
		end
		if util.isTransfContainsNaN(construction.transf) then 
			debugPrint(newProposal)
			error("Transf contains NaN")
		end
	end 
end

function util.isIndustryEntity(entity) 
	if not util.industryEntityCache then 
		util.industryEntityCache = {}
		api.engine.forEachEntityWithComponent(
			function(e)
				-- do it for both sim building and its construction
				util.industryEntityCache[e]=true
				util.industryEntityCache[api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(e)]=true
			end
			, api.type.ComponentType.SIM_BUILDING)
	end 
	return util.industryEntityCache[entity]
end 
function util.checkConnectionToIndustry(industry, edge)
	if type(edge)=="number" then 
		edge = { id = edge}
	end 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
	trace("About to inspect linked entities for", edge.id)
	local tpNetwork = util.getComponent(edge.id, api.type.ComponentType.TRANSPORT_NETWORK)
	for i, tn in pairs(tpNetwork.edges) do 
		local linkedEntities = api.engine.system.tpNetLinkSystem.getLinkEntities(api.type.EdgeId.new(edge.id,i-1))
		for j, link in pairs(linkedEntities) do 
			local tpLink = util.getComponent(link, api.type.ComponentType.TP_NET_LINK)
			if tpLink.from.edgeId.entity == constructionId or tpLink.to.edgeId.entity == constructionId then
				return true
			end				
		end
	end
	trace("Did not find a connection")
	return false
end
	
function util.findEdgeForIndustry(industry, range, findStationEnd, station)
	if not range then range =100 end
	--trace("finding edge for industry",industry.name," in range ",range," fundStationEnd=",findStationEnd)
	local fallback
	local candidates = {}
	for __, edge in pairs(game.interface.getEntities({radius=range, pos=industry.position}, {type="BASE_EDGE" , includeData=true})) do
		if edge.track then goto continue end
		local constructionEntity = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge.id)
		local edgesForNode0 = #util.getSegmentsForNode(edge.node0)
		local edgesForNode1 = #util.getSegmentsForNode(edge.node1)
		local isEdge0Frozen = util.isFrozenNode(edge.node0)
		local isEdge1Frozen = util.isFrozenNode(edge.node1)
		--trace("checking edge, ",edge.id," edgesForNode0=",edgesForNode0,"edgesForNode1=",edgesForNode1,"isEdge0Frozen=",isEdge0Frozen,"isEdge1Frozen=",isEdge1Frozen)
		if (edgesForNode0 ==1 and not isEdge0Frozen) 
		or (edgesForNode1 ==1 and not isEdge1Frozen)  then -- try to get the one with a dead end
			if station then 
				if util.checkIfStationInCatchmentAreaOfEdge(station, edge.id) then 
					return edge
				end 
			elseif findStationEnd then
				trace("found a dead end, now trying to find station, constructionEntity= ",constructionEntity)
				local station = findStation(constructionEntity)
				if station and util.checkIfStationInCatchmentArea(station, api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id))  then 
					return edge
				end
				trace("did not find station")
			elseif constructionEntity == -1 then			
				if util.checkConnectionToIndustry(industry, edge) then 
					local deadEndScore 
					if edgesForNode0 == 1 or edgesForNode0 == 0 then 
						deadEndScore = 0 
					else 
						deadEndScore = 1 
					end 
					if edgesForNode0 == 1 and edgesForNode1 == 1 then -- preference for only one dead end
						deadEndScore = 1 
					end 
					table.insert(candidates, { 
						edge= edge,
						scores = {
							300-util.distBetweenNodes(edge.node0, edge.node1),
							deadEndScore
						}
					})
 
				end
			end
		elseif util.checkConnectionToIndustry(industry, edge) then 
			table.insert(candidates, { 
							edge= edge,
							scores = {
								300-util.distBetweenNodes(edge.node0, edge.node1),
								1,
							}
						})
		end
		::continue::
	end
	if #candidates == 0 and range < 200 then 
		return  util.findEdgeForIndustry(industry, 200)
	end
	if #candidates == 0 then 
		trace("WARNING! Could not find any edges for ", industry.name, industry.id)
		if findStationEnd then 
			findStationEnd = false 
			return util.findEdgeForIndustry(industry, range, findStationEnd)
		end
		return
	end
	return util.evaluateWinnerFromScores(candidates, {75,25}).edge 
end

function util.depotBehindStation(depotConstruction, stationId) 
	local freeNodes = util.getFreeNodesForConstruction(depotConstruction)
	local freeNodes2 = util.getFreeNodesForConstruction(api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId))
	for i , node in pairs(freeNodes) do 
		for j, node2 in pairs(freeNodes2) do 
			if node == node2 or util.distBetweenNodes(node, node2) < 5 then 
				return true 
			end
		end 
	end 
	return false 
end
function util.edgeHasSpaceForDoubleTrack(edgeId)
	local edge = util.getEdge(edgeId)
	for i, node in pairs({edge.node0, edge.node1}) do 
		local tangent = i == 1 and edge.tangent0 or edge.tangent1 
		if #util.findDoubleTrackNodes(util.nodePos(node), tangent) > 1 then 
			return false
		end 
	end 
	return true 
end 

local function isStreetRepAvailable(streetRep) 
	
	if streetRep.yearFrom == -1 or streetRep.yearTo == -1 then 
		return false 
	end 
	local year = util.year()
	local yearTo = streetRep.yearTo == 0 and math.huge or streetRep.yearTo
	return year < yearTo and year >= streetRep.yearFrom
end 

function util.isEdgeConnectedToTrackSegments(edgeId)
	local edge = util.getEdge(edgeId) 
	for i, node in pairs({edge.node0, edge.node1}) do 
		if #util.getTrackSegmentsForNode(node) > 0 then 
			return true 
		end 
	end 
	return false 
end  


function util.getNextStreetTypeForEdge(edgeId) 
	local existingStreetType = util.getStreetEdge(edgeId).streetType
	if existingStreetType == api.res.streetTypeRep.find("standard/country_medium_one_way_new.lua") then -- short cut the common case
		return api.res.streetTypeRep.find("standard/country_large_one_way_new.lua") 
	end 
	if util.tracelog and existingStreetType == api.res.streetTypeRep.find("standard/country_large_one_way_new.lua") then 
		return existingStreetType 
	end
	
	local numLanes = util.getNumberOfStreetLanes(edgeId)
	local streetTypeCategory = util.getStreetTypeCategory(edgeId)
	local isOneWay = util.isOneWayStreet(edgeId)
	local targetNumLanes = isOneWay and numLanes + 1 or numLanes + 2
	for streetType , streetRep in pairs(util.getStreetTypeRep()) do
		if isStreetRepAvailable(streetRep)  then 
			if util.contains(streetRep.categories, streetTypeCategory) then 
				if #streetRep.laneConfigs == targetNumLanes then 
					return streetType
				end 
			end 
		end 
	end 
	
	
	return existingStreetType
end 

function util.isSecondRunwayAvailable()
	local mod = api.res.moduleRep.get(api.res.moduleRep.find("station/air/airport_2nd_runway.module"))
	return util.year() >= mod.availability.yearFrom
end 

-- Checks if point p is inside polygon poly (list of vec3 or vec2)
-- Uses Ray Casting algorithm
function util.pointInPolygon(p, poly)
    local inside = false
    local j = #poly
    for i = 1, #poly do
        if (poly[i].y > p.y) ~= (poly[j].y > p.y) and
           (p.x < (poly[j].x - poly[i].x) * (p.y - poly[i].y) / (poly[j].y - poly[i].y) + poly[i].x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function util.boxesIntersect(box1, box2) 
-- Check for separation on the X axis
    if (box1.max.x < box2.min.x) or (box1.min.x > box2.max.x) then
        return false
    end

    -- Check for separation on the Y axis
    if (box1.max.y < box2.min.y) or (box1.min.y > box2.max.y) then
        return false
    end

    -- Check for separation on the Z axis
    if (box1.max.z < box2.min.z) or (box1.min.z > box2.max.z) then
        return false
    end

    -- If no separation is found on any axis, they must be intersecting
    return true 
end 

function util.checkForCollisionWithPolygon(p0, p1, poly)
   -- for _, poly in pairs(polygons) do
        -- 1. Check if either endpoint is INSIDE the lot
        if util.pointInPolygon(p0, poly) or util.pointInPolygon(p1, poly) then
            return true
        end
        
        -- 2. Check if the line INTERSECTS any edge of the lot
        local numPoints = #poly
        for i = 1, numPoints do
            local pA = poly[i]
            local pB = poly[(i % numPoints) + 1] -- Wrap around to 1
            
            if util.checkFor2dCollisionBetweenPoints(p0, p1, pA, pB) then
                return true
            end
        end
   -- end
    
    return false
end

function util.checkForCollisionWithConstructions(p0, p1) 
	local pMid = 0.5*(p0+p1)
	local offset = 5
	local zOffset = 10 
	for i, entity in pairs(util.findIntersectingEntities(pMid, offset, zOffset)) do 
		if util.isConstruction(entity) and util.checkForCollisionWithConstructionLine(p0, p1, entity) then 
			return true 
		end 
	end 
	return false
end 
function util.checkForCollisionWithConstructionsPoint(p) 
	
	local offset = 5
	local zOffset = 10 
	for i, entity in pairs(util.findIntersectingEntities(p, offset, zOffset)) do 
		if util.isConstruction(entity) and util.checkForCollisionWithConstructionOnePoint(p, entity) then 
			return true 
		end 
	end 
	return false
end 
function util.checkForCollisionWithConstructionLine(p0, p1, constructionId)
	local lotList = util.getComponent(constructionId, api.type.ComponentType.LOT_LIST)
	if lotList then 
		for m, lot in pairs(lotList.lots) do 
			local vertices = lot.vertices
			if util.checkForCollisionWithPolygon(p0, p1, vertices) then 
				return true 
			end 
		end 
	end 
	return false 
end 
function util.checkForCollisionWithConstructionOnePoint(p, constructionId)
	local lotList = util.getComponent(constructionId, api.type.ComponentType.LOT_LIST)
	if lotList then 
		for m, lot in pairs(lotList.lots) do 
			local vertices = lot.vertices
			if util.pointInPolygon(p, vertices) then 
				return true 
			end 
		end 
	end 
	return false 
end 

function util.getClosestPoint2dLine(p0, p1, p)
    -- 1. Get the vector of the line segment (v)
    local dx = p1.x - p0.x
    local dy = p1.y - p0.y

    -- 2. Check if p0 and p1 are the same point to avoid division by zero
    if dx == 0 and dy == 0 then
        return {x = p0.x, y = p0.y}
    end

    -- 3. Calculate the squared length of the line segment
    -- (We use squared length to avoid a costly sqrt operation)
    local lenSq = dx * dx + dy * dy

    -- 4. Calculate the projection t
    -- t = ((p - p0) . (p1 - p0)) / |p1 - p0|^2
    local t = ((p.x - p0.x) * dx + (p.y - p0.y) * dy) / lenSq

    -- 5. Clamp t to the range [0, 1]
    -- If you want an infinite line instead of a segment, remove these two lines.
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end

    -- 6. Calculate the coordinates of the closest point
    return {
        x = p0.x + t * dx,
        y = p0.y + t * dy
    }
end
-- water mesh functions moved out 
util.getNearestVirtualRiverMeshContour = waterMeshUtil.getNearestVirtualRiverMeshContour
util.getRiverMeshInRange = waterMeshUtil.getRiverMeshInRange
util.getClosestWaterVerticies = waterMeshUtil.getClosestWaterVerticies
util.distanceToNearestWaterVertex = waterMeshUtil.distanceToNearestWaterVertex
util.getRiverMeshEntitiesInRange = waterMeshUtil.getRiverMeshEntitiesInRange

waterMeshUtil.evaluateAndSortFromSingleScore = util.evaluateAndSortFromSingleScore
waterMeshUtil.v3fromArr = util.v3fromArr
waterMeshUtil.v3 = util.v3
waterMeshUtil.deepClone = util.deepClone
waterMeshUtil.pointHash3d = util.pointHash3d
waterMeshUtil.distance = util.distance
waterMeshUtil.indexOf = util.indexOf
waterMeshUtil.shallowClone = util.shallowClone
waterMeshUtil.checkFor2dCollisionBetweenPoints = util.checkFor2dCollisionBetweenPoints
waterMeshUtil.evaluateWinnerFromScores = util.evaluateWinnerFromScores
waterMeshUtil.signedAngle = util.signedAngle
waterMeshUtil.pointHash2d = util.pointHash2d
return util