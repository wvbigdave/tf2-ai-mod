local util = require("ai_builder_base_util")
local transf = require("transf")
local vec2 = require("vec2")
local vec3 = require("vec3")
local paramHelper = require("ai_builder_base_param_helper")
local helper = require("ai_builder_station_template_helper")
local connectEval = require("ai_builder_new_connections_evaluation")
local routeBuilder = require("ai_builder_route_builder")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local interchangeutil = require "ai_builder_interchange_util"
local waterMeshUtil = require "ai_builder_water_mesh_util"
local proposalUtil = require "ai_builder_proposal_util"
local profiler = require "ai_builder_profiler"
local applyDummyShift = false

local constructionUtil = {}
routeBuilder.constructionUtil = constructionUtil
local trace = util.trace 

local function err(e) 
	trace(e)
	trace(debug.traceback())
end 

local function rotZTransl(rotation, position)
	-- not sure if correcting the angles is needed, was trying to resolve some unexplained errors
	if rotation > math.rad(360) then 
		rotation = rotation - math.rad(360)
		trace("Rotation out of bounds,  now ",math.deg(rotation))
	end 
	if rotation < -math.rad(360) then 
		rotation = rotation + math.rad(360)
		trace("Rotation out of bounds,  now ",math.deg(rotation))
	end 
	return transf.rotZTransl(rotation, position)
end 

local function getTownStreetType(numlanes) 
	local streetTypeName = util.year() >= 1925 and "standard/town_medium_new.lua" or "standard/town_medium_old.lua"
	if numlanes and numlanes > 4 then  
		streetTypeName = util.year() >= 1925 and "standard/town_large_new.lua" or "standard/town_large_old.lua"
	end 
	return api.res.streetTypeRep.find(streetTypeName)
end
local function initNewEntity(newProposal, numlanes) 
	local newEntity = api.type.SegmentAndEntity.new()
	newEntity.streetEdge.streetType = getTownStreetType(numlanes) 
	newEntity.entity=  -1-#newProposal.streetProposal.edgesToAdd
	newEntity.type = 0
	return newEntity
end	

local function checkProposalForErrors(proposal, printErrors, tryRemoveCollisionEdges, allowExtendedRemoval, ignoreWaterMesh)
	local originalNodesAdded = #proposal.streetProposal.nodesToAdd
	local originalEdgesAdded = #proposal.streetProposal.edgesToAdd
	if not xpcall(function()
		util.validateProposal(proposal) -- amazingly just calling the makeProposalData can cause a game crash 
	end, function(e) trace("checkProposalForErrors: an error was caught:",e) end) then 
		return {
			isError = true, 
			isActualError = true, 
			isCriticalError = true ,
		}
	end 
	trace("checkProposalForErrors: About to call makeProposalData")
	--debugPrint(proposal)
	local context = util.initContext()
	local resultData = api.engine.util.proposal.makeProposalData(proposal, context)
	trace("checkProposalForErrors: Finished makeProposalData")
	--debugPrint({proposalErrorState=resultData.errorState, tpNetLinkProposal=resultData.tpNetLinkProposal})
	local isError = #resultData.errorState.messages > 0 or resultData.errorState.critical
	local isConnected = #resultData.tpNetLinkProposal.toAdd > 0
	local isBuggedError = false 
	local isCriticalError = resultData.errorState.critical
	local allWereWaterMesh = #resultData.collisionInfo.collisionEntities > 0 
	local hasWaterMeshCollisions = false
	if isError and  #resultData.errorState.messages == 1 and resultData.errorState.messages[1]=="Collision" then
		local alreadySeen = {} 
		local collisionEdges = {}
		local collisionConstructions = {}
		local removedMap = {}
		for i, edgeId in pairs(proposal.streetProposal.edgesToRemove) do 
			removedMap[edgeId]=true
		end
		for i, node in pairs(proposal.streetProposal.nodesToRemove) do 
			removedMap[node]=true
		end
		local foundAll = true 
		local allowSelfCollisions = util.tracelog
		for i, entity in pairs(resultData.collisionInfo.collisionEntities) do 
			if not removedMap[entity.entity] then 
				if entity.entity> 0 or not allowSelfCollisions then 
					foundAll = false
				end
				if  util.isWaterMeshEntity(entity.entity) then 
					hasWaterMeshCollisions = true 
				else 
					--trace("Entity ",entity.entity," was NOT a water mesh")
					allWereWaterMesh = false 
				end
				 
			end
			if not alreadySeen[entity.entity] and not removedMap[entity.entity] then 
				alreadySeen[entity.entity]=true 
				if entity.entity > 0 then 
					if tryRemoveCollisionEdges then 
						local fullEntity = util.getEntity(entity.entity) 
						if fullEntity and fullEntity.type == "BASE_EDGE" and not fullEntity.track then 
							table.insert(collisionEdges, entity.entity)
						elseif fullEntity and fullEntity.type == "CONSTRUCTION" then 
							trace("Found collision with construction",entity.entity)
							table.insert(collisionConstructions, entity.entity)
						end 
					end 
				end 
			end 
		end
		if foundAll then 
			isBuggedError = true
			trace("Found all entities in the removed collision set")
		elseif tryRemoveCollisionEdges then 
			local removedConstructions = {}
			local removedEdges = {} 
			for i, edgeId in pairs(collisionEdges)  do 
				if (util.isDeadEndEdgeNotIndustry(edgeId) or allowExtendedRemoval) and util.getStreetTypeCategory(edgeId)~="highway" and not util.isFrozenEdge(edgeId) and #util.getEdge(edgeId).objects==0 then 
					proposal.streetProposal.edgesToRemove[1+#proposal.streetProposal.edgesToRemove]=edgeId
					trace("Removing edge",edgeId," to allow proposal test build")
					table.insert(removedEdges, edgeId)
				end  
				
			end
			
			if allowExtendedRemoval then 
				for i, construction in pairs(collisionConstructions) do 
					local depot = util.getConstruction(construction).depots[1]
					if depot and not util.isDepotContainingVehicles(depot) then 
						trace("Removing depot",depot,"for collision")
						table.insert(removedConstructions, construction)
					end 
				end 
			end 
			proposal.constructionsToRemove = removedConstructions
			
			local referencedNodes = {} 
			for i, edgeId in pairs(removedEdges) do 
			 
				local edge = util.getEdge(edgeId) 
				for j, node in pairs({edge.node0, edge.node1}) do 
					if not referencedNodes[node] then 
						referencedNodes[node] = 1 
					else 
						referencedNodes[node] = referencedNodes[node] + 1
					end 
				end 
			end 
			local removedNodes = {} 
			local remainingNodes = {}
			for node, count in pairs(referencedNodes) do 
				if count == #util.getSegmentsForNode(node) then 
					table.insert(removedNodes, node)
					proposal.streetProposal.nodesToRemove[1+#proposal.streetProposal.nodesToRemove]=node
				else 
					table.insert(remainingNodes, node)
				end
			end 
			
			  
		 
			local result =  checkProposalForErrors(proposal, printErrors, false, false, ignoreWaterMesh)
			result.removedEdges = removedEdges 
			result.removedNodes = removedNodes 
			result.removedConstructions = removedConstructions
			result.remainingNodes = remainingNodes
			trace("Following removal of the items, the result was",result.isError)
			if result.isError and util.tracelog then 
				--debugPrint({remainingCollisionEntities=result.collisionEntities, proposal=proposal})
			end
			return result
		end
		
	end
	local isActualError = (isError and not isBuggedError) or isCriticalError
	if ignoreWaterMesh and allWereWaterMesh and not isCriticalError then 
		isActualError = false 
	end
	local isOnlyBridgePillarCollision =  not isCriticalError and #resultData.errorState.messages == 1  and resultData.errorState.messages[1]== "Bridge pillar collision"
	trace("Collision result, isError=",isError," isConnected=",isConnected, " isActualError=",isActualError, " isCriticalError=",isCriticalError, " isBuggedError=",isBuggedError, " ignoreWaterMesh=",ignoreWaterMesh," allWereWaterMesh=",allWereWaterMesh)
	if isError and printErrors and util.tracelog then 
		--debugPrint(proposal)
		debugPrint(resultData.errorState)
		debugPrint(resultData.collisionInfo.collisionEntities)
		if isCriticalError then 
			debugPrint(proposal)
		end
	end
	if isCriticalError and resultData.errorState.messages[1] == "Internal error (see console for details)" then 
		trace("WARNING! Internal error detected") 
		debugPrint({originalProposal = proposal,originalNodesAdded=originalNodesAdded,originalEdgesAdded=originalEdgesAdded, fullresultdata=resultData})
	end
	local collisionEntitySet = {}
	local hasIndustryCollision = false 
	local hasSelfCollision = false
	for i, entity in pairs(resultData.collisionInfo.collisionEntities) do
		if not collisionEntitySet[entity.entity] then 
			collisionEntitySet[entity.entity]=true 
		end 
		if util.isIndustryEntity(entity.entity) then 
			hasIndustryCollision = true 
		end
		if entity.entity < 0 then 
			hasSelfCollision = true 
		end
	end 
	local tpLinks = {}
	for i, link in pairs(resultData.tpNetLinkProposal.toAdd) do
		if not util.contains(tpLinks, link.link.to.edgeId.entity) then 
			table.insert(tpLinks, link.link.to.edgeId.entity)
		end 
		if not util.contains(tpLinks, link.link.from.edgeId.entity) then 
			table.insert(tpLinks, link.link.from.edgeId.entity)
		end 
	end 
	return { 
		isError = isError,
		isConnected = isConnected,
		costs=resultData.costs, 
		isBuggedError=isBuggedError, 
		isActualError = isActualError, 
		isCriticalError=isCriticalError, 
		isOnlyBridgePillarCollision=isOnlyBridgePillarCollision,
		collisionEntities=resultData.collisionInfo.collisionEntities, 
		errorState = resultData.errorState, 
		hasWaterMeshCollisions= hasWaterMeshCollisions,
		collisionCount = util.size(collisionEntitySet),
		collisionEntitySet = collisionEntitySet,
		hasIndustryCollision = hasIndustryCollision,
		hasSelfCollision  = hasSelfCollision,
		tpLinks = tpLinks,
		removedConstructions = removedConstructions,
		resultData = resultData, -- need to retain this to avoid being gc'd 
	}
end

local function checkTrainStationForCollision(positionAndRotation, params, stationConstr, depotConstr, disableTestTrack)
	local testProposal = api.type.SimpleProposal.new() 
	--if not disableTestTrack then 
		trace("checkTrainStationForCollision: buildTestTrackSegment")
		constructionUtil.buildTestTrackSegment(testProposal, positionAndRotation, false, 80, params, true)
	--end
	local trackTestResult = checkProposalForErrors(testProposal)
	
	if trackTestResult.isError then 
		return trackTestResult
	end 
	
	local testProposal = api.type.SimpleProposal.new() 
	--testProposal.constructionsToAdd[1]=constructionUtil.copyNewConstruction(stationConstr)
	testProposal.constructionsToAdd[1]=stationConstr
	--[[if depotConstr then 
		local fullProposal = api.cmd.make.buildProposal(testProposal, util.initContext(), true)
		debugPrint(fullProposal)
		local	testProposal = api.type.SimpleProposal.new() 
		testProposal.constructionsToAdd[1]=depotConstr
		local fullProposal2 = api.cmd.make.buildProposal(testProposal, util.initContext(), true)
		debugPrint(fullProposal2)
		
		for i, node in pairs(fullProposal.proposal.proposal.addedNodes) do 
			for j, node2 in pairs(fullProposal2.proposal.proposal.addedNodes) do 
				if util.positionsEqual(node.comp.position, node2.comp.position,1) then 
					trace("Found nodes potentially at the same postion",node.entity,node2.entity," at",node.comp.position.x,node.comp.position.y)
				end 
			end 
			local nearbyNode  = util.searchForNearestNode(node.comp.position,20)
			if nearbyNode and util.distance(util.v3fromArr(nearbyNode.position), node.comp.position)< 5 then 
				trace("Found nearbyNode very close to position",nearbyNode.id)
			end 
		end 
	end ]]--
	
	if depotConstr then 
		--testProposal.constructionsToAdd[2]=constructionUtil.copyNewConstruction(depotConstr)
		testProposal.constructionsToAdd[2]=depotConstr
	end
	local testResult =  checkProposalForErrors(testProposal)
	--testResult.isError = testResult.isError or trackTestResult.isError
	if params.ignoreErrors and testResult.isError and not testResult.isCriticalError then 
		trace("overriding error as we are ignoring errors IsConnnected?",testResult.isConnected) 
		testResult.isError = false 
		if testResult.isConnected then 
			debugPrint({collisionEntities=testResult.collisionEntities})
		end
	end 
	testResult.testProposal = testProposal
	return testResult
end

local function checkConstructionForCollision(...) 
	trace("checking construction for collision")
	local dummyProposal = api.type.SimpleProposal.new()
	for i, c in pairs({...}) do 
		dummyProposal.constructionsToAdd[i]=c
	end
	
	return checkProposalForErrors(dummyProposal,true)
end

local function copyStreetProposal(newProposal, dummyProposal)
	for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
		dummyProposal.streetProposal.nodesToAdd[i]=node
	end 
	for i, node in pairs(newProposal.streetProposal.nodesToRemove) do 
		dummyProposal.streetProposal.nodesToRemove[i]=node
	end 
	for i, edge in pairs(newProposal.streetProposal.edgesToAdd) do 
		dummyProposal.streetProposal.edgesToAdd[i]=edge
	end
	for i, edge in pairs(newProposal.streetProposal.edgesToRemove) do 
		dummyProposal.streetProposal.edgesToRemove[i]=edge
	end
	for i, edgeObj in pairs(newProposal.streetProposal.edgeObjectsToAdd) do 
		dummyProposal.streetProposal.edgeObjectsToAdd[i]=edgeObj
	end
	for i, edgeObj in pairs(newProposal.streetProposal.edgeObjectsToRemove) do 
		dummyProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj
	end
end
local function copyProposal(newProposal, dummyProposal)
	copyStreetProposal(newProposal, dummyProposal)
	for i, constr in pairs(newProposal.constructionsToAdd) do 
		dummyProposal.constructionsToAdd[i]=constr
	end
	dummyProposal.constructionsToRemove = util.deepClone(newProposal.constructionsToRemove)
end
local function checkConstructionForCollisionWithProposal(newProposal, ...) 
	trace("checking construction for collision")
	local dummyProposal = api.type.SimpleProposal.new()
	copyStreetProposal(newProposal, dummyProposal) 
	
	for i, c in pairs({...}) do 
		dummyProposal.constructionsToAdd[i]=c
	end
	
	return checkProposalForErrors(dummyProposal,false)
end

local function trialBuildConnectRoad(leftNodeOrPos, rightNodeOrPos, inputProposal)
	local testProposal = api.type.SimpleProposal.new()
	local build -- remember have to keep this in the scope until its children are no needed
	local leftNode 
	local leftNodePos 
	local rightNode 
	local rightNodePos 
	local streetType = api.res.streetTypeRep.find("standard/country_small_new.lua")
	if inputProposal then 
		build = api.cmd.make.buildProposal(inputProposal, util.initContext(), true)
		if util.tracelog then 
			debugPrint({build=build})
		end
		
		local unfrozenNode = build.proposal.proposal.frozenNodes[1] + 2 -- 2 because want the next node (+1) and it is zero based (+1)
		rightNodePos = util.v3(build.proposal.proposal.addedNodes[unfrozenNode].comp.position)
		rightNode = build.proposal.proposal.addedNodes[unfrozenNode].entity
		for i, node in pairs(build.proposal.proposal.addedNodes) do 
			testProposal.streetProposal.nodesToAdd[i]=node 
		end 
		for i, seg in pairs(build.proposal.proposal.addedSegments) do
			testProposal.streetProposal.edgesToAdd[i]=seg 
			streetType = seg.streetEdge.streetType
		end 
		trace("trialBuildConnectRoad set the position to",rightNodePos.x,rightNodePos.y)
	end 


	
	if type(leftNodeOrPos) == "number" then 
		leftNode = leftNodeOrPos
		leftNodePos  = util.nodePos(leftNode)
	else 
		leftNodePos = leftNodeOrPos
		local newNode =util.newNodeWithPosition(leftNodePos, -3)
		leftNode = newNode.entity 
		testProposal.streetProposal.nodesToAdd[1]=newNode 
	end 
	if not inputProposal then 
		if type(rightNodeOrPos) == "number" then 
			rightNode = rightNodePos
			rightNodePos  = util.nodePos(rightNode)
		else 
			rightNodePos = rightNodeOrPos
			local newNode =util.newNodeWithPosition(rightNodePos, -4)
			rightNode = newNode.entity 
			testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=newNode 
		end
	end
	local entity = initNewEntity(testProposal)
	if #testProposal.streetProposal.edgesToAdd > 0 then 
		entity.entity = testProposal.streetProposal.edgesToAdd[#testProposal.streetProposal.edgesToAdd].entity-1
	end 
	entity.streetEdge.streetType = streetType
	entity.comp.node0 = leftNode 
	entity.comp.node1 = rightNode
	util.setTangent(entity.comp.tangent0, rightNodePos-leftNodePos)
	util.setTangent(entity.comp.tangent1, rightNodePos-leftNodePos)
	testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=entity
	if util.tracelog then 
		debugPrint(testProposal)
	end
	local result=  checkProposalForErrors(testProposal, true).isError
	trace("result of trial build for link was",result)
	return result 
end 

function constructionUtil.createRoadDepotConstruction(naming, position, angle)
	local roadDepotConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	roadDepotConstruction.fileName = "depot/road_depot_era_a.con"
	roadDepotConstruction.playerEntity = api.engine.util.getPlayer()
	 roadDepotConstruction.params={
		paramX = 0,  
		paramY = 0, 
		seed = 0, -- TODO check this might need to be 1
		year = util.year()}
	roadDepotConstruction.name = naming.name.." ".._("Road depot")
	local trnsf = rotZTransl(angle, position)
	roadDepotConstruction.transf = util.transf2Mat4f(trnsf)
	return roadDepotConstruction
end



function constructionUtil.createRailDepotConstruction(stationPosAndRotation, town, params, forceTerminus, perpOffset)
	local isCargo = params.isCargo
	if not perpOffset then perpOffset = 0 end
local construction = api.type.SimpleProposal.ConstructionEntity.new()
			construction.fileName = "depot/train_depot_era_a.con"
			construction.name=town.name.." ".._("Train depot")
			construction.playerEntity = api.engine.util.getPlayer()
			construction.params={ 
			  catenary = params.isElectricTrack  and 1 or 0,  
			  paramX = 0,
			  paramY = 0,
			  seed = 0,
			  trackType = params.isHighSpeedTrack  and 1 or 0, -- cosmetic
			  year = util.year(),
			}
			local stationRelativeAngle = stationPosAndRotation.stationRelativeAngle
			-- x is along the station, y is perpendicular to the station
			--local depotOffsety = perpOffset-15
			local depotOffsety = perpOffset-11
			if params.isCargo then 
				depotOffsety = perpOffset-16
			end 
			if stationRelativeAngle < 0 then 
				depotOffsety = depotOffsety - 5
				trace("Incrementing the depotOffsety for negative station relative angle to",depotOffsety) 
			end 
		--	depotOffsety = depotOffsety + 5
			local depotOffsetx = (params.stationLength/4)+28
			if params.stationLength < 200 then 
				depotOffsetx = depotOffsetx + 10
			end 
	 
			local rotation = stationPosAndRotation.rotation --+ math.rad(180)
			local stationPerpTangent = stationPosAndRotation.stationPerpTangent
			local stationParallelTangent = stationPosAndRotation.stationParallelTangent
			
			
			--local signedAngleToTown = util.signedAngle(nrmltrangent, vec3.normalize(vec3.new(straightlinevec.x, straightlinevec.y, 0)))
			--if signedAngleToTown > 0 then
			--	depotOffsetx = -depotOffsetx
				--depotOffsetx = depotOffsetx - 20
			--end
			local isTerminus =  not isCargo and params.buildTerminus[town.id]
			if isTerminus then 
				stationPerpTangent = util.rotateXY(stationParallelTangent, math.rad(90))
			end 
			
			if isTerminus or forceTerminus then 
				depotOffsety = -30
				if params.isQuadrupleTrack then 
					depotOffsety = depotOffsety - 15 
				end
				--depotOffsetx = -(params.stationLength/2)+20
				depotOffsetx = -(params.stationLength/2)+30
			--	if signedAngleToTown > 0 then
			--		depotOffsetx = -depotOffsetx 
			--	end
			end
			local stationOffset = (params.stationLength / 40) % 2 == 0 and 20 or 0 -- needs an offset for even number of modules
			
			 
			if stationRelativeAngle < 0 then
				stationOffset = -stationOffset
			end
		
			local heightBoost = false
			--local perpTangent = util.rotateXY(nrmltrangent, math.rad(90))
			local stationPos = stationPosAndRotation.position
			--assert(math.abs(vec3.length(perpTangent)-1)<0.001, "size was actually "..tostring(vec3.length(perpTangent)))
			local depotPos = stationPos + (depotOffsety*stationPerpTangent) + (depotOffsetx * stationParallelTangent) 
			trace("depotOffsetx=",depotOffsetx,"depotOffsety=",depotOffsety," params.isElevated=", params.isElevated," isTerminus=",isTerminus)
			if not isTerminus and (params.isElevated and util.isElevatedStationAvailable() or params.isUnderground and util.isUndergroundStationAvailable()) then 
				trace("Boosing elevationHeight")
				if params.isElevated then 
					depotPos.z = depotPos.z + params.elevationHeight/2
				else 
					depotPos.z = depotPos.z - params.elevationHeight/2
				end 
				heightBoost = true
			end
			
			if isTerminus then
				-- push the depot into the corner to keep it out of the way
				local trialDepotPos = (-2.5*depotOffsety)*stationPerpTangent+depotPos
				if connectEval.getDistanceToNearestCorner(trialDepotPos) < connectEval.getDistanceToNearestCorner(depotPos)
					and util.distance(trialDepotPos, util.v3fromArr(town.position)) > util.distance(depotPos, util.v3fromArr(town.position)) then
					trace("adjusting depot position to move into the corner")
					-- DISABLED
				--	depotPos=trialDepotPos
				end
			end
			
			
			if stationPosAndRotation.stationRelativeAngle < 0 or isTerminus or forceTerminus then
				rotation = rotation + math.rad(180)
			end
			
			 
			
			
			if isCargo and not forceTerminus then
				-- try to build the depot behind the station
				local trackWidth = 5
				local halfLength = params.stationLength/2
				trace("Stationoffset was ", stationOffset, " halfLength was ",halfLength, " at ",town.name)
				local trialDepotPos = stationPos  - (40 + halfLength) * stationParallelTangent + 2*trackWidth*stationPerpTangent-- + stationOffset*stationParallelTangent
				if not util.isPrimaryIndustry(town) then
					--trace("Non primary industry detected, shifting") -- keep it out of the way for potential future expansion
				--	trialDepotPos = trialDepotPos -60*stationParallelTangent  -3*trackWidth*stationPerpTangent
				end
				
				construction.transf = util.transf2Mat4f(rotZTransl(rotation, trialDepotPos))
				local checkResult =  checkConstructionForCollision(construction)
				--debugPrint({checkResult=checkResult})
				if not checkResult.isError and checkResult.costs < 250000 then 
					local testProposal = api.type.SimpleProposal.new() 
					local positionAndRotation = util.deepClone(stationPosAndRotation)
					-- check we can actually link to the depot without a road etc. in the way
					positionAndRotation.stationParallelTangent = -1*positionAndRotation.stationParallelTangent
					trace("Check if we can link to the depot calling buildTestTrackSegment")
					constructionUtil.buildTestTrackSegment(testProposal, positionAndRotation, false, 60, params)
					if not checkProposalForErrors(testProposal).isError then 
						trace("Shifted depot position to behind station ", trialDepotPos.x, trialDepotPos.y)
						depotPos = trialDepotPos
					end
				end
			end
			
			if not heightBoost then 
				depotPos.z = stationPos.z + 0.5 -- seems to be needed to get the track at the same level
			end 
			 
			construction.transf = util.transf2Mat4f(rotZTransl(rotation, depotPos))
			return construction
end

local function tryBuildStationUnderPass(newProposal, positionAndRotation, params)
	trace("Removing ",positionAndRotation.edgeToRemove," edge to make way for station")
	local baseEdgeStreet = util.getComponent(positionAndRotation.edgeToRemove, api.type.ComponentType.BASE_EDGE_STREET)
	local numlanes = #api.res.streetTypeRep.get(baseEdgeStreet.streetType).laneConfigs
	newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=positionAndRotation.edgeToRemove
	local segs = util.getSegmentsForNode(positionAndRotation.originalNode) 
	local removedSegs = {} 
	removedSegs[positionAndRotation.edgeToRemove]=true
	for i, seg in pairs(segs) do
		if util.isDeadEndEdgeNotIndustry(seg) then 
			trace("Removing seg=",seg)
			newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=seg
			removedSegs[seg]=true
		end
	end
	
	local originalEdge = util.getEdge(positionAndRotation.edgeToRemove)
	local otherNode = originalEdge.node0 == positionAndRotation.originalNode and originalEdge.node1 or originalEdge.node0
	if util.calculateSegmentLengthFromEdge(originalEdge) < 90 or params.buildCompleteRoute then 
		
		local nextSegs  = util.getSegmentsForNode(otherNode)
		if #nextSegs == 2 then 
			local nextEdge = positionAndRotation.edgeToRemove == nextSegs[1] and nextSegs[2] or nextSegs[1]
			newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=nextEdge
			removedSegs[nextEdge]=true
			local nextEdgeFull = util.getEdge(nextEdge)
			newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=otherNode
			trace("Original edge was short, removing next, removed edge",nextEdge," removedNode",otherNode)
			otherNode = otherNode == nextEdgeFull.node0 and nextEdgeFull.node1 or nextEdgeFull.node0
			trace("Changed otherNode to ",otherNode, " options were ", nextEdgeFull.node0, " or ", nextEdgeFull.node1)
		end
	end
		local originalNodePos = positionAndRotation.originalNodePos
	local otherNodePos =  util.nodePos(otherNode)
	local offsetAngle = util.signedAngle(otherNodePos-originalNodePos, positionAndRotation.tangent)
	local offsetLength = util.distance(otherNodePos,originalNodePos) * math.sin(math.abs(offsetAngle))
	local perpDistance = util.distance(otherNodePos,originalNodePos) * math.cos(offsetAngle)
	local minLength = 60 -- for a 10 meter drop, gives slope ~ 16% 
	local minLength2=  minLength+offsetLength
	
	trace("The offset angle for the underpass was ",math.deg(offsetAngle), " offsetLength=",offsetLength ,"perpDistance=",perpDistance, " minLength=",minLength)
	local isLeft = offsetAngle > 0
	
	if positionAndRotation.stationRelativeAngle > 0 then 
		isLeft = not isLeft
	end
	 

	local newNodePos = otherNodePos + ( isLeft and minLength2 or minLength)*positionAndRotation.busStationParallelTangent
	

	local newNodePos2 = originalNodePos + (isLeft and minLength or minLength2)*positionAndRotation.busStationParallelTangent
	newNodePos.z = math.min(newNodePos.z, originalNodePos.z - 10)
	local tangent = newNodePos - otherNodePos
	newNodePos2.z = originalNodePos.z - 10
	local diameter = util.distance(newNodePos2, newNodePos)
	local r = diameter /2 
	local circ = r*(4 * (math.sqrt(2) - 1)) 
	local midPointPos = 0.5*(newNodePos2 +newNodePos)+r*vec3.normalize(tangent)
	
	local nextNodeId = -1000-#newProposal.streetProposal.edgesToAdd-#newProposal.streetProposal.nodesToAdd
	local outerEdgeTangent
	local replacedOuterNode = false
	if perpDistance < 80 and #util.getSegmentsForNode(otherNode) ==2 then 
		trace("The perp distance was too short", perpDistance)
		local nextSegs  = util.getSegmentsForNode(otherNode)
		local nextEdge = removedSegs[nextSegs[1]] and nextSegs[2] or nextSegs[1]
		trace("Got next edge",nextEdge," for node",otherNode)
		if not util.isFrozenEdge(nextEdge) then 
			local nextEdgeFull = util.getEdge(nextEdge)
			newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=nextEdge
			removedSegs[nextEdge]=true
			newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=otherNode
			trace("Removed node ",otherNode," removed edge",nextEdge)
			local isNode0 = otherNode == nextEdgeFull.node0
			otherNode = isNode0  and nextEdgeFull.node1 or nextEdgeFull.node0
			replacedOuterNode= true
			--local segs= util.getSegmentsForNode(otherNode)
			--nextEdge = nextEdge == segs[1] and segs[2] or segs[1]
		--	nextEdgeFull = util.getEdge(nextEdge)
			outerEdgeTangent = isNode0 and util.v3(nextEdgeFull.tangent1) or -1*util.v3(nextEdgeFull.tangent0) 
			newNodePos = midPointPos + math.max(16, 80-perpDistance)*positionAndRotation.stationPerpTangent
		end 
	end 
	local newNode1 = util.newNodeWithPosition(newNodePos, nextNodeId)
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode1
	
	local newEntity = initNewEntity(newProposal, numlanes) 
	newEntity.comp.node0=otherNode 
	newEntity.comp.node1=newNode1.entity 
	
	tangent.z = 0 
	if replacedOuterNode then 
		local tangent = newNodePos - util.nodePos(otherNode)
		util.setTangent(newEntity.comp.tangent0, vec3.length(tangent)*vec3.normalize(outerEdgeTangent))
		util.setTangent(newEntity.comp.tangent1, tangent)
		trace("ReplacedOuter node for underpass, set tangent as",tangent.x,tangent.y," the tangent0 as ",newEntity.comp.tangent0.x,newEntity.comp.tangent0.y)
	else 
		util.setTangent(newEntity.comp.tangent0, tangent)
		util.setTangent(newEntity.comp.tangent1, tangent)
	end
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=newEntity
	

	
	
	local newNode2 = util.newNodeWithPosition(newNodePos2, nextNodeId-1)
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode2
	
	trace("The diameter was ",diameter," the half circumference was ",circ)
	midPointPos.z = midPointPos.z - 2
	local midPoint =  util.newNodeWithPosition(midPointPos, nextNodeId-2)
	
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=midPoint
	local newEntity2 = initNewEntity(newProposal, numlanes)
	newEntity2.comp.node0=newNode1.entity  
	newEntity2.comp.node1=midPoint.entity 
	local perpTangent = positionAndRotation.stationPerpTangent 
	if replacedOuterNode then 
		util.setTangents(newEntity2 , midPointPos-newNodePos)
	else 
		util.setTangent(newEntity2.comp.tangent0, circ*vec3.normalize(tangent))
		util.setTangent(newEntity2.comp.tangent1, -circ*vec3.normalize(perpTangent))
	end
	newEntity2.comp.type = 2
	newEntity2.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=newEntity2
	local newEntity3 = initNewEntity(newProposal, numlanes)
	newEntity3.comp.node0=midPoint.entity  
	newEntity3.comp.node1=newNode2.entity  
	util.setTangent(newEntity3.comp.tangent0, -circ*vec3.normalize(perpTangent))
	util.setTangent(newEntity3.comp.tangent1, -circ*vec3.normalize(tangent))
	newEntity3.comp.type = 2
	newEntity3.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=newEntity3
	--debugPrint(newProposal)
	-- last link in the chain will be built connecting the bus station, cannot do it here as we cannot access the bus construction node

	positionAndRotation.underPassNodePos=newNodePos2
	return numlanes
end
local function buildStationUnderPass(newProposal, positionAndRotation, params)
	local testProposal = api.type.SimpleProposal.new()
	tryBuildStationUnderPass(testProposal, positionAndRotation, params)
	local checkResult = checkProposalForErrors(testProposal)
	
	trace("buildStationUnderPass: checkResult was",checkResult.isError,"critical?",checkResult.isCriticalError)
	if not checkResult.isCriticalError then 
		return tryBuildStationUnderPass(newProposal, positionAndRotation, params)
	elseif util.tracelog then 
		debugPrint({testProposal=testProposal, checkResult=checkResult})
	end 
	positionAndRotation.underPassNodePos = nil
	return 4
end
constructionUtil.minOffsetConnected = math.huge 
constructionUtil.maxOffsetConnected = -math.huge
function constructionUtil.buildTrainStationConstruction(newProposal, town, positionAndRotation, params, includeDepot, otherTown, forceTerminus)
	local isCargo = params.isCargo
	--forceTerminus = true
	local stationParams =  { 
		catenary = params.isElectricTrack and 1 or 0,  
		length =  params.stationLengthParam,
		paramX = 0,  
		paramY = 0, 
		seed = 0, 
		templateIndex = isCargo and 6 or 2, 
		trackType =  params.isHighSpeedTrack  and 1 or 0,  -- 0 == standard, 1== high speed, NOT the same as api.res.trackTypeRep
		tracks = params.alwaysDoubleTrackStation and 1 or 0,--paramHelper.isDoubleTrack(isCargo) and 1 or 0,
		year = util.year(),}
	local isTerminus = false 
	if not isCargo and params.buildTerminus[town.id] then
		stationParams.templateIndex =1 
		isTerminus= true
		if params.alwaysDoubleTrackPassengerTerminus then 
			stationParams.tracks = 1
		end
	end
	if not isCargo and params.isQuadrupleTrack then 
		if town.isExpressStop then 
			stationParams.tracks = stationParams.tracks + 2
		else 
			stationParams.buildThroughTracks = true 
		end 
	end 
	if params.useDoubleTerminals and not isTerminus then
		local originalTracks = stationParams.tracks
		stationParams.tracks = (2*(originalTracks+1))-1
		trace("Increased tracks from ",originalTracks," to ",stationParams.tracks)
	end 
	if params.useDoubleTerminals and stationParams.buildThroughTracks then 
		trace("Increasing track count to 6 and removing through tracks")
		stationParams.tracks = 2+stationParams.tracks 
		stationParams.buildThroughTracks = false
	end 
	if isCargo and (forceTerminus or town.type=="TOWN") then 
		stationParams.templateIndex =7 
		isTerminus= true
		trace("Setting 2 tracks for cargo terminus") -- avoid problems moving the entrance building when upgrading
		params.tracks = 1
	end 
	local needsConnectRoad = true
	local numlanes = 4
	if positionAndRotation and positionAndRotation.edgeToRemove then 
		numlanes = buildStationUnderPass(newProposal, positionAndRotation, params)
	end
	 
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	--debugPrint({town=town, positionAndRotation=positionAndRotation})
	newConstruction.name=town.name
	local fileName = "station/rail/modular_station/modular_station.con"
	if not isCargo and params.isElevated and not isTerminus and util.isElevatedStationAvailable() then 
		fileName = "station/rail/modular_station/elevated_modular_station.con"
		stationParams.isElevated = true
		stationParams.pillars = 0
	elseif not isTerminus and params.isUnderground and util.isUndergroundStationAvailable() then 
		fileName = "station/rail/modular_station/underground_modular_station.con"
		stationParams.isUnderground = true
		stationParams.depth = 0
	end	
	newConstruction.fileName = fileName
	newConstruction.playerEntity = api.engine.util.getPlayer()
	stationParams.modules = util.setupModuleDetailsForTemplate(helper.createTemplateFn(stationParams))
	local perpOffset = numlanes > 4 and 8 or 0
	local stationOffset = (params.stationLength / 40) % 2 == 0 and 20 or 0 -- needs an offset for even number of modules
	local stationPos
	if positionAndRotation then 
		local stationRelativeAngle = positionAndRotation.stationRelativeAngle
		local parallelTangent =  vec3.normalize(positionAndRotation.stationParallelTangent)
		if stationRelativeAngle < 0 or isTerminus then
			stationOffset = -stationOffset
			if isTerminus then -- following tanken from transf
				local sz = math.sin(positionAndRotation.rotation)
				local cz = math.cos(positionAndRotation.rotation)
 		      --   vec4.new(cz, sz, .0, .0),
				--vec4.new(-sz, cz, .0, .0),
				trace("overriding the stationParallelTangent with",-sz,cz)
				parallelTangent = vec3.new(-sz, cz, .0)
			
			end 
			
			
		end
		--[[if isTerminus and #util.getSegmentsForNode(positionAndRotation.originalNode)==1 then 
			trace("Setting the offset positive for dead end terminus node")
			stationOffset = math.abs(stationOffset)
		end ]]--
		
		stationPos = positionAndRotation.position + perpOffset*positionAndRotation.stationPerpTangent + stationOffset * parallelTangent
		trace("in createTrainStationConstruction, isCargo=",isCargo, " stationParams.templateIndex=",stationParams.templateIndex, " stationRelativeAngle was", math.deg(stationRelativeAngle), " stationOffset=",stationOffset," stationPos",stationPos.x, stationPos.y,"perpOffset=",perpOffset,"at",town.name)
		 
		positionAndRotation.numlanes = numlanes
		positionAndRotation.actualStationPos = stationPos
		positionAndRotation.stationOffset = stationOffset
		local stationtransf = rotZTransl(positionAndRotation.rotation, stationPos) 
		trace("About to set the transf on the newConstruction")
		if util.tracelog then 
			debugPrint({stationtransf=stationtransf})
		end
		newConstruction.transf = util.transf2Mat4f(stationtransf)
		trace("Set the transf on the newConstruction")
	end
	
	local depotConstruction
	if includeDepot and positionAndRotation then
		depotConstruction = constructionUtil.createRailDepotConstruction(positionAndRotation, town,  params, forceTerminus, perpOffset)
	end
	newConstruction.params = stationParams
	trace("Set params on newConstruction")
	local testResult
	if isCargo and town.type ~= "TOWN" and positionAndRotation then 
		testResult = checkTrainStationForCollision(positionAndRotation, params, newConstruction, depotConstruction)
	end
	
	if isCargo and town.type ~= "TOWN" and (not positionAndRotation or testResult.isError or not testResult.isConnected) or forceTerminus then
		trace("potential collision detected, attemptting to resolve at ",town.name)
		local constructionOptions = {}
		 needsConnectRoad = false
		 
		--collectgarbage()
		local points =  {}
		local industryEdge
		if town.type == "INDUSTRY" then 
			local edge = util.findEdgeForIndustry(town)
			if edge then 
				industryEdge = edge
				table.insert(points, {
					p =	util.getEdgeMidPoint(edge.id), 
					t = vec3.normalize(util.rotateXY(util.v3fromArr(edge.tangent0),math.rad(90))),
					length = 0,
					isMidPointEdge = true
				})
			end 
		end 
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(town.id)	
		local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
		local z = construction.transf:cols(3).z
		local tnComp = util.getComponent(constructionId, api.type.ComponentType.TRANSPORT_NETWORK)
		for i , tn in pairs(tnComp.edges) do
			if tn.geometry.params.pos and tn.geometry.params.tangent then
				local p = util.v2ToV3(tn.geometry.params.pos[1], z)
				local t = vec3.normalize(util.v2ToV3(tn.geometry.params.tangent[1]))
				local length = tn.geometry.length
				if tn.geometry.width < 4 then -- the 4 wide are used for the visible stock
					for k = -20, 20, 10 do 
						table.insert(points, {
							p = p + k*t , 
							t= t,
							length = length,
							k = k,
							})
					end
				end
			end
		end
		for i, node in pairs(util.searchForDeadEndNodes(town.position, 200, true)) do 
			local nodeDetails = util.getDeadEndNodeDetails(node)
			table.insert(points, {
					p =	nodeDetails.nodePos, 
					t = vec3.normalize(util.rotateXY(nodeDetails.tangent,math.rad(90))),
					length = 0
					})
		end
	
		local pInd = util.v3fromArr(town.position)
		local pOth = util.v3fromArr(otherTown.position)
		local routeVector  = pOth - pInd
		trace("The number of points was  ",#points)
		for i = 1, #points do
			
			local p = points[i].p 
			local t = points[i].t
			local k = points[i].k
			local length = points[i].length
			if math.abs(vec3.length(p)) < 0.1 then -- corrupted data
				trace("Ignoring at ",i, " as apparently corrupt",p.x,p.y)
				goto continue
			end
			
			local mid = p+0.5*length*t
			trace("examining transport network, p=",p.x,p.y," t=",t.x,t.y, " mid=",mid.x,mid.y)
			if forceTerminus then 
				t = util.rotateXY(t, math.rad(90))
				trace("Rotating for terminus")
				if util.distance(mid+10*t, pInd) < util.distance(mid-10*t, pInd) then
					trace("inverting the stationParallelTangent for terminus")
					t = -1*t -- needs to point away from the industry
				else 
					trace("NOT inverting the stationParallelTangent for terminus")
				end  				
			end 
			
			local perpTangent = util.rotateXY(t,math.rad(90))
			local newRotation = -util.signedAngle(t, vec3.new(0,-1,0)) 
			if not forceTerminus and util.distance(mid+10*perpTangent, pInd) < util.distance(mid-10*perpTangent, pInd) then
				perpTangent = -1*perpTangent
				newRotation = newRotation + math.rad(180)
				trace("inverting the perp tangent")
			end
			local stationParallelTangent =t 
			local testP1 = mid-10*stationParallelTangent
			local testP2 = mid+10*stationParallelTangent
			local dist1 = util.distance(testP1, pOth)
			local dist2 = util.distance(testP2, pOth)
			trace("Inspecting stationParallelTangent, testP1 at ",testP1.x, testP1.y," testP2 at ",testP2.x, testP2.y, " dist1=",dist1, "dist2=",dist2," will invert?", dist1<dist2 and not forceTerminus)
			if not forceTerminus and dist1 < dist2 then
				stationParallelTangent = -1*stationParallelTangent -- always pointing towards other town
			end
			
			
			local offset = util.countNearbyEntities (mid, 15, "BASE_EDGE")>0 and 55 or 45
			local stationRelativeAngle = util.signedAngle(stationParallelTangent, perpTangent)
			local offset2 = 0
			if forceTerminus and true then 
				--trace("terminus, original rotation was ", math.deg(newRotation)," adding ",math.deg(stationRelativeAngle))
				--newRotation = newRotation + stationRelativeAngle 
				offset = offset + math.abs(stationOffset) + params.stationLength/2 +10
				newRotation = newRotation + math.rad(180)
				trace("terminus, new rotation was ", math.deg(newRotation), " new offset was ",offset )
			end
			local result
			local newPos
			local count = 0 
			repeat -- move the station closer to the industry until it connects
				count = count + 1
				if forceTerminus then 
					newPos = mid + offset*stationParallelTangent
				else 
					newPos = mid + offset*perpTangent --+ offset2*stationParallelTangent
				end
				local newPosAndRot = {}
				newPosAndRot.position = newPos
				newPosAndRot.rotation=newRotation
				newPosAndRot.stationPerpTangent = perpTangent
				newPosAndRot.stationParallelTangent = stationParallelTangent
				newPosAndRot.stationRelativeAngle = stationRelativeAngle
				if includeDepot then
					
					depotConstruction = constructionUtil.createRailDepotConstruction(newPosAndRot, town,  params, forceTerminus)
				end
				
				local stationOffset = (params.stationLength / 40) % 2 == 0 and 20 or 0 -- needs an offset for even number of modules 
				if stationRelativeAngle < 0 then
					stationOffset = -stationOffset
				end
				if forceTerminus then 
					stationOffset = 0
				end 
				stationPos = newPos + stationOffset * stationParallelTangent
				if forceTerminus and false  then 
					stationPos = newPos
					--newRotation = (newRotation+math.rad(180))%math.rad(360)
					newPosAndRot.stationParallelTangent = newPosAndRot.stationPerpTangent
				end
				
				newConstruction.transf = util.transf2Mat4f(rotZTransl(newRotation, stationPos))
				local constructionParallelTangent =  util.v3(newConstruction.transf:cols(1))			
				local constructionPerpTangent = util.v3(newConstruction.transf:cols(0))
				if not util.positionsEqual(constructionParallelTangent, stationParallelTangent, 0.01) then 
					trace("WARNING! difference detected between parallel tangent", constructionParallelTangent.x, constructionParallelTangent.y, " and ",stationParallelTangent.x, stationParallelTangent.y," the rotation was",math.deg(newRotation),"raw rotation=",newRotation,"forceTerminus?",forceTerminus)
					--[[if util.tracelog then 
						debugPrint({
							cols0 = newConstruction.transf:cols(0),
							cols1 = newConstruction.transf:cols(1),
							cols2 = newConstruction.transf:cols(2),
							cols3 = newConstruction.transf:cols(3),
					
						})
						if depotConstruction then 
							debugPrint({ 
								cols0 = depotConstruction.transf:cols(0),
								cols1 = depotConstruction.transf:cols(1),
								cols2 = depotConstruction.transf:cols(2),
								cols3 = depotConstruction.transf:cols(3),
							})
						end 
					end ]]--
				end 
				local offsetAngle = math.abs(util.signedAngle(constructionParallelTangent, stationParallelTangent))
				local correctedOffset = offsetAngle > math.rad(90) and math.rad(180)-offsetAngle or offsetAngle
				trace("The offsetAngle to the stationParallelTangent was ",math.deg(offsetAngle), " corrected was ",math.deg(correctedOffset))
				if correctedOffset > math.rad(1) then 
					trace("WARNING! Corrected offset was too high", math.deg(correctedOffset))
				end
				
				-- mysterios crash at coal mine
				--The offsetAngle to the stationParallelTangent was 	179.99999936976	 corrected was 	6.3023629912942e-07
				--Offset=	17	offset2=	0	forceTerminus=	nil	pos=	-4274.9129753303	-160.70836988015	 rotation=	150.9453911244
				trace("Offset=",offset,"offset2=",offset2,"forceTerminus=",forceTerminus,"pos=",stationPos.x,stationPos.y, " rotation=",math.deg(newRotation))
				 --if offset == 17 and   then 
				--	result = { isError = true, costs=math.huge, isCriticalError=true }
				--	trace("Overriding result to avoid checking at coal")
			--	else 
					result = checkTrainStationForCollision(newPosAndRot, params, newConstruction, depotConstruction, forceTerminus)
				--end
				 offset = offset - 2
				 if offset == 23 then -- HACK to prevent crash
					offset = 22 
				end
				if offset == 12 then 
					offset = 11
				end -- also 39
				if result.isError and result.isOnlyBridgePillarCollision then 
					trace("Overriding error as onlyBridgePillarCollision")
					result.isError = false 
				end
				if not util.isValidCoordinate(newPos) then 
					result.isError = true 
				end
				if util.tracelog and result.hasSelfCollision then 
					debugPrint({selfColliding=result})
					
				end 
				if industryEdge and result.collisionEntitySet[industryEdge.id] then 
					trace("Setting the industryCollision to true due to colliding with industry edge")
					result.hasIndustryCollision = true
				end 
			if result.isConnected and not result.isError then 
				constructionUtil.maxOffsetConnected = math.max(constructionUtil.maxOffsetConnected,offset)
				constructionUtil.minOffsetConnected = math.min(constructionUtil.minOffsetConnected,offset)
				trace("Construction connected at",offset,"maxOffsetConnected=",constructionUtil.maxOffsetConnected,"minOffsetConnected=",constructionUtil.minOffsetConnected)
			end 
			until result.isConnected and not result.isError or count > 100 or result.hasIndustryCollision
			if not result.isError  and result.isConnected then
				
				local angleToVector = math.abs(util.signedAngle(stationParallelTangent, vec3.normalize(routeVector)))
				
				if angleToVector > math.rad(90) then -- symmetric so take the best from either end 
					angleToVector = math.rad(180) - angleToVector
				end
				if forceTerminus then -- not symmetric
					angleToVector = math.abs(util.signedAngle(stationParallelTangent, routeVector))
				end
				
				trace("Collission resolved at ",newPos.x, newPos.y," rotation=",math.deg(newRotation), " angleToVector was ", math.deg(angleToVector))
				if util.tracelog then 
					result.originalP= p
					result.offset = offset
					result.angleToVectorDeg = math.deg(angleToVector)
				end 
				table.insert(constructionOptions, {
					pos = stationPos,
					rotation = newRotation,
					depotConstruction = depotConstruction,
					angleToVector = angleToVector,
					collisionEntities = result,
					scores = {
						angleToVector,
						result.costs,
						points[i].isEdgeMidPoint and 0 or 1
					}
				})
				 
				 trace("Accepted the option at ",p.x,p.y," as the result was error?",result.isError," is connected?",result.isConnected, "k=",k, "offset=",offset)
			else 
				trace("Rejected the option at ",p.x,p.y," as the result was error?",result.isError," is connected?",result.isConnected, "k=",k, "offset=",offset)
			end 			
			::continue::
		end
		trace("Number of valid construction options was ",#constructionOptions)
		local bestOption = util.evaluateWinnerFromScores(constructionOptions, { 75, 25, 10 })
		if bestOption then
			trace("The best option angle to vector was ",math.deg(bestOption.angleToVector))
			if util.tracelog then 
				--debugPrint({bestResultCollisionEntities=bestOption.collisionEntities})
			end
			newConstruction.transf = util.transf2Mat4f(rotZTransl(bestOption.rotation, bestOption.pos))
			depotConstruction = bestOption.depotConstruction
		elseif not params.reducedTestTrack then 
			trace("No options were found, attempting with reducedTestTrack")
			params.reducedTestTrack = true
			return constructionUtil.buildTrainStationConstruction(newProposal, town, positionAndRotation, params, includeDepot, otherTown, forceTerminus) 
		elseif includeDepot then
			includeDepot = false
			trace("No options were found, attempting with depot")
			return constructionUtil.buildTrainStationConstruction(newProposal, town, positionAndRotation, params, includeDepot, otherTown, forceTerminus) 
		elseif not forceTerminus then 
			forceTerminus = true 
			includeDepot = false
			trace("No options were found, attempting with terminus")
			return constructionUtil.buildTrainStationConstruction(newProposal, town, positionAndRotation, params, includeDepot, otherTown, forceTerminus) 
		end
	end 
	trace("About to set the new construction onto the proposal")
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]= newConstruction -- step sometimes crashes
	trace("Completed setting the construction on the proposal")
	if positionAndRotation then positionAndRotation.stationIdx = #newProposal.constructionsToAdd end
	if includeDepot then 
		trace("About to set the depotConstruction onto the proposal, depotConstruction was ",depotConstruction)
		newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]= depotConstruction
		if util.tracelog then 
			--debugPrint(newProposal)
		end 
		trace("Completed to set the depotConstruction onto the proposal")
		if positionAndRotation then  positionAndRotation.depotIdx = #newProposal.constructionsToAdd end
		trace("Set the depotIdx on to the posandrot")
	end
	trace("End buildTrainStationConstruction")
	--print(debug.traceback())
	return needsConnectRoad
end
 
function constructionUtil.buildTrainStationConstructionAtEndOfEdge(newProposal, town, edge, otherTown, params, includeDepot)
	profiler.beginFunction("buildTrainStationConstructionAtEndOfEdge")
	local nodeInfo = edge and util.getDeadEndTangentAndDetailsForEdge(edge.id)
	local positionAndRotation = edge and connectEval.getStationPositionAndRotation(town, nodeInfo, otherTown, params)
	local needsConnectRoad = constructionUtil.buildTrainStationConstruction(newProposal,town, positionAndRotation, params, includeDepot, otherTown)
	 
	if needsConnectRoad then
		-- util.buildShortStubRoadWithPosition(newProposal, nodeInfo.node, positionAndRotation.stationConnectPos)
	end
	profiler.endFunction("buildTrainStationConstructionAtEndOfEdge")
end

function constructionUtil.buildTestTrackSegment(testProposal, positionAndRotation, bothEnds, testLength, params, fullSegment)
	local stationLength2 = params.stationLength/2
	if not testLength then testLength = 60 end
	if params.reducedTestTrack then 
		testLength = testLength / 2 
	end
	local buildTo = bothEnds and 2 or 1
	for i = 1, buildTo do 
		local sign = i == 1 and 1 or -1
		--[[local stationOffset = (params.stationLength / 40) % 2 == 0 and 20 or 0 -- needs an offset for even number of modules 
		stationOffset = stationOffset + 2 -- otherwise it will collide with the station
		if positionAndRotation.stationRelativeAngle < 0 then
			stationOffset = -stationOffset
		end]]--
		local stationOffset = 2*sign
		local offsetFromMiddle = stationOffset + stationLength2 + 4 -- +4 to avoid building directly on top of the station node, but close enough to detect a collision
		local p1 = positionAndRotation.position + sign*offsetFromMiddle * positionAndRotation.stationParallelTangent
		p1 = p1 + 10*vec3.normalize(positionAndRotation.stationPerpTangent)
		local p2 = p1 + sign*testLength*positionAndRotation.stationParallelTangent
		if fullSegment then 
			p1 = p1 - sign*params.stationLength * positionAndRotation.stationParallelTangent
		end 
		
		trace("Inserting test track between ",p1.x,p1.y, " and ",p2.x,p2.y, " stationOffset was ",stationOffset, "offsetFromMiddle?",offsetFromMiddle)
		local entity = api.type.SegmentAndEntity.new()
		entity.type=1 
		local nextNodeId = -1000-#testProposal.streetProposal.edgesToAdd-#testProposal.streetProposal.nodesToAdd
		entity.comp.node0 = nextNodeId
		entity.comp.node1 = nextNodeId-1
		util.setTangent(entity.comp.tangent0, p2-p1)
		util.setTangent(entity.comp.tangent1, p2-p1)
		entity.entity = -1-#testProposal.streetProposal.edgesToAdd
		trace("Inserting test track between ",p1.x,p1.y, " and ",p2.x,p2.y, " stationOffset was ",stationOffset, "offsetFromMiddle?",offsetFromMiddle,"entity was",entity.entity)
		entity.trackEdge.trackType = api.res.trackTypeRep.find("standard.lua")
		testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=entity
		testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=util.newNodeWithPosition(p1,nextNodeId)
		testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=util.newNodeWithPosition(p2,nextNodeId-1)
	end
end

local function trialBuildConnectRoadToNearestNode(nodePos) 
	local nearestNode = util.searchForNearestNode(nodePos, 180, function(node) 
		if #util.getStreetSegmentsForNode(node.id) == 0 then 
			return false 
		end 
		if util.isFrozenNode(node.id) then 
			return false 
		end 
		for i, seg in pairs(util.getStreetSegmentsForNode(node.id)) do 
			if util.getStreetTypeCategory(seg) == "highway" then 
				return false
			end 
		end 
	
		return true
	end)
	if not nearestNode then 
		return false 
	end 
	local otherNodePos = util.v3fromArr(nearestNode.position)
	if util.positionsEqual(nodePos, otherNodePos, 5) then 
		return true 
	end 
	local testProposal = api.type.SimpleProposal.new() 
	local entity = initNewEntity(testProposal)
	local newNode = util.newNodeWithPosition(nodePos, -1000)
	entity.comp.node0 = newNode.entity 
	entity.comp.node1 = nearestNode.id 
	util.setTangents(entity, otherNodePos - nodePos)
	testProposal.streetProposal.nodesToAdd[1]= newNode 
	testProposal.streetProposal.edgesToAdd[1]=entity 
	local resultData = api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
	local isError = #resultData.errorState.messages > 0 or resultData.errorState.critical
	trace("Result of trialBuildConnectRoadToNearestNode to",nearestNode.id,"from",nodePos.x,nodePos.y," was isError?",isError)
	return not isError

end 

local function buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
	trace("buildTrainStationConstructionForTown: begin for",town.name)
	local isTerminus = params.buildTerminus[town.id]
	util.lazyCacheNode2SegMaps()
	if isTerminus then 
		includeDepot = false -- these end up getting in the way and being a general nuisance
	end 
	local function tryBuild(positionAndRotation)
		--local testProposal = util.newLuaProposal() 
		local testProposal = api.type.SimpleProposal.new()
		constructionUtil.buildTrainStationConstruction(testProposal, town, positionAndRotation, params, includeDepot, otherTown)
		if params.buildInitialBusNetwork and not positionAndRotation.existingBusStation then 
			constructionUtil.buildBusNetworkInitialInfrastructure(testProposal,town , positionAndRotation ,params)
		end
		
		trace("buildTrainStationConstructionForTown: completed call to buildTrainStationConstruction")
		local bothEnds = not isTerminus
		if params.isCargo then 
			bothEnds = false 
		end
		if not params.skipTrackSegment then 
			trace("buildTrainStationConstructionForTown: buildTestTrackSegment")
			constructionUtil.buildTestTrackSegment(testProposal, positionAndRotation, bothEnds, 80, params)
		end
		trace("buildTrainStationConstructionForTown: about to setupProposalFromLuaProposal")
		--return routeBuilder.setupProposalFromLuaProposal(testProposal)
		return testProposal
	end
	local options = {}
	if util.tracelog then debugPrint({townName=town.name, positionsForTown=positions}) end
	for i, position in pairs(positions) do
		
		local positionAndRotation = connectEval.getStationPositionAndRotation(town, position , otherTown, params, 0,thirdTown)
		
		local checkResult = checkProposalForErrors(tryBuild(positionAndRotation), true, true, params.removeConflictingEdges)
		local stationPos = positionAndRotation.actualStationPos
		if not params.allowLargeTerrainOffsets  and math.abs(util.th(stationPos)-stationPos.z) > 50 or not util.isValidCoordinate(stationPos) then 
			trace("Station proposal for town",town.name,"Rejecting position at ",stationPos.x, stationPos.y, " due to large terrain offset")
			goto continue 
		end
		if util.isUnderwater(stationPos) then 
			trace("Station proposal for town",town.name,"Rejecting position at ",stationPos.x, stationPos.y, " as it is underwater")
			goto continue 
		end
		if checkResult.isActualError and positionAndRotation.isVirtualDeadEndForTerminus then 
			trace("Attempting additional offset to correct error for terminus")
			positionAndRotation = connectEval.getStationPositionAndRotation(town, positions[i], otherTown, params, 90)
			checkResult = checkProposalForErrors(tryBuild(positionAndRotation), true, true)
			if not checkResult.isActualError then 
				local originalNodePos = positionAndRotation.originalNodePos
				local checkResult2 = trialBuildConnectRoadToNearestNode(originalNodePos)
				if not checkResult2 then 
					trace("Although the station is not an error could not connect")
					checkResult.isActualError = true 
					checkResult.isError = true
				end 
			end 
		end
		if checkResult.isCriticalError and util.tracelog and false then 
			--debugPrint(tryBuild(positionAndRotation))
			local dummyProposal = api.type.SimpleProposal.new()
			local testProposal = tryBuild(positionAndRotation) 
			proposalUtil.copyStreetProposal(testProposal, dummyProposal) 	
			api.cmd.sendCommand(api.cmd.make.buildProposal(dummyProposal, util.initContext(), true), function(res, success) 
				trace("Result of building street proposal was",success)
				debugPrint(dummyProposal)
			end)
			for i, constr in pairs(testProposal.constructionsToAdd) do 
				local dummyProposal = api.type.SimpleProposal.new()
				dummyProposal.constructionsToAdd[1]=constr 
				api.cmd.sendCommand(api.cmd.make.buildProposal(dummyProposal, util.initContext(), true), function(res, success) 
					trace("Result of building construction at i=",i,"was",success)
				end)
			end 
			return positionAndRotation
		end 
		--originalNodePos
		local canInsert = (not checkResult.isActualError) or params.ignoreErrors and not checkResult.isCriticalError and not checkResult.hasIndustryCollision 
		trace("Checking train station construction for position",position.node," isActualError",checkResult.isActualError," pos was",stationPos.x, stationPos.y, " positionAndRotation.angleToVector =",math.deg(positionAndRotation.angleToVector),"isCriticalError?",checkResult.isCriticalError,"checkResult.hasIndustryCollision?",checkResult.hasIndustryCollision,"params.ignoreErrors=",params.ignoreErrors," canInsert?",canInsert)
 		
		if canInsert then
			positionAndRotation.isBuggedError = checkResult.isBuggedError
			trace("Station proposal for town",town.name," being inserted at",i)
			if town.name == "Bangkok" and util.tracelog then 
				--local build = tryBuild(positionAndRotation)
				--local check = tryBuild(positionAndRotation)
				--debugPrint({build = tryBuild(positionAndRotation), check= checkProposalForErrors(tryBuild(positionAndRotation), true, true)})
			end 
			table.insert(options, { 
				checkResult = checkResult, 
				positionAndRotation = positionAndRotation,
				scores = {
					checkResult.costs > 2000000 and checkResult.costs or 0, -- do not score small differences in cost
					i, -- original preferred index
					checkResult.collisionCount,
					checkResult.hasWaterMeshCollisions and 1 or 0,
					positionAndRotation.angleToVector
				} 
			})
			if i == 1 then 
				 --break 
			end
		else 
			trace("Station proposal for town",town.name," had an error, trying next at",i)
		end
		::continue::
	end
	trace("Station proposal for town",town.name,"had", #options, " options of ",#positions)
	
	if #options > 0 then 
		local angleWeight = isTerminus and 75 or 25
		local weights = { 25, 100, 25, 25, angleWeight}
		local best = util.evaluateWinnerFromScores(options, weights)
		local positionAndRotation = best.positionAndRotation
		local checkResult = best.checkResult
		if checkResult.removedEdges then 
			trace("buildTrainStationConstructionForTown: Proposal found edges to remove")
			local uniquenessCheck = {} 
			for i, edgeId in pairs(checkResult.removedEdges) do 
				trace("buildTrainStationConstructionForTown: Removing edge",edgeId) -- 131349, 131468, 131365,
				newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
			end 
			for i, node in pairs(checkResult.removedNodes) do 
				trace("buildTrainStationConstructionForTown: Removing node",node)
				newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=node
			end 

		end 
		constructionUtil.buildTrainStationConstruction(newProposal, town, positionAndRotation, params, includeDepot, otherTown)
		if params.buildInitialBusNetwork and not positionAndRotation.existingBusStation then 
			constructionUtil.buildBusNetworkInitialInfrastructure(newProposal,town , positionAndRotation, params)
		end
		
		--if util.tracelog then debugPrint({winningPosition=best}) end NB may cause crash
		trace("buildTrainStationConstructionForTown: The best option for ",town.name," was node = ",positionAndRotation.originalNode, " angleToVector=",math.deg(positionAndRotation.angleToVector), " originalIdx=",best.scores[2])
		if util.tracelog then 
			for i , option in pairs(options) do 
				option.checkResult = nil
			end 
			debugPrint(options)
		end
		return positionAndRotation 
	end 
	
	

	if not params.allowLargeTerrainOffsets then  
		trace("buildTrainStationConstructionForTown: Setting allowLargeTerrainOffsets to true")
		params.allowLargeTerrainOffsets = true
		return buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
				
	end
	if not params.extendedNodeSearch then  
		trace("buildTrainStationConstructionForTown: Setting extendedNodeSearch to true")
		params.extendedNodeSearch = true
		positions = connectEval.evaluateBestPassengerStationLocation(town, otherTown, otherTown2, params)
		local res = buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
		params.extendedNodeSearch = false 
		return res
	end
	if (params.buildTerminus and params.buildTerminus[town.id] or params.isCargo) and not params.tryOtherRotation then  
		trace("buildTrainStationConstructionForTown: Setting tryOtherRotation to true")
		params.tryOtherRotation = true
		return buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
				
	end
	if not params.removeConflictingEdges and not params.isCargo and not params.isAutoBuildMode then 
		trace("buildTrainStationConstructionForTown: Setting removeConflictingEdges to true at Station proposal for town",town.name)
		params = util.shallowClone(params)
		params.removeConflictingEdges = true
		return buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
				
	end
	if not params.ignoreErrors and not params.isCargo and not params.isAutoBuildMode then 
		trace("buildTrainStationConstructionForTown: Setting ignoreErrors to true at Station proposal for town",town.name)
		params = util.shallowClone(params)
		params.ignoreErrors = true
		return buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
				
	end
	if not params.skipTrackSegment then 
		params = util.shallowClone(params)
		params.skipTrackSegment = true 
		return buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
	end 
	
	trace("WARNING! Station proposal for town",town.name,"found no build options!")
end

function constructionUtil.buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
	profiler.beginFunction("buildTrainStationConstructionForTown")
	local res = buildTrainStationConstructionForTown(newProposal, town, positions, includeDepot, otherTown, params, thirdTown)
	profiler.endFunction("buildTrainStationConstructionForTown")
	return res
end 

local function setupJunctionParams(params) 
	local constrParams = interchangeutil.defaultParams()
	constrParams.vanillahiwaysize = 0 
	--if not params.useSmallHighways then 
	--	constrParams.vanillahiwaysize = 1 
		--constrParams.noTail = true
	--end
	constrParams.useSmallHighways = params.useSmallHighways
	constrParams.stackinterchangelanes = 1
	if params.preferredHighwayRoadType == "standard/country_medium_one_way_new.lua" then
		constrParams.stackinterchangelanes = 0
	end 
	constrParams.aiBuilderInterchangeLaneCount = constrParams.stackinterchangelanes
--	constrParams.vanillahiwayheight = 20+0
	constrParams.vanillahiwayheight = 10 
	constrParams.Central = 1
	constrParams.highwayTailLength =2 
	constrParams.seed =0
	constrParams.connectingroadType = 3
	if params.majorStreetType == api.res.streetTypeRep.find("standard/town_x_large_new.lua") then 
		trace("Setting connecting road type to 4")
		constrParams.connectingroadType = 4
	end 
	constrParams.connectingTailLength = 2
	constrParams.offsetAngle = 0
	constrParams.special = 0 
	constrParams.gradeSeparate = 0
	constrParams.highWayBridgeType = 0 
	constrParams.highwaylevel = 0
	if params.isElevated then 
		constrParams.highwaylevel = 1
	elseif params.isUnderground then 
		constrParams.highwaylevel = 2
	end 
	constrParams.improvedJoinAngle = 0
	constrParams.juncount = 0
	constrParams.trafficside = 0
	constrParams.junctiongap = 1
	constrParams.offsetAngle = 45
	constrParams.year = util.year()
	constrParams.isUseVanillaRamps = api.res.streetTypeRep.find("1l_wide_sliproad2lequivalent.lua") == -1
	return constrParams
end


function constructionUtil.createHighwayJunction(town, positions, otherTown, callback, params, thirdTown)
	util.lazyCacheNode2SegMaps()
	trace("Begin createHighwayJunction for ",town.name,otherTown.name)
	if util.tracelog then debugPrint(positions) end
	local otherTownPos = util.v3fromArr(otherTown.position)
	local townVector = otherTownPos -util.v3fromArr(town.position)
	local distBetweenTowns = vec3.length(townVector)
	local midPoint = 0.5*(util.v3fromArr(otherTown.position)+util.v3fromArr(town.position))
	local midPointSearch = false
	local townNode = util.searchForNearestNode(town.position, 150, function(node) return #util.getTrackSegmentsForNode(node.id)==0 end).id
	local filterFn = function(node) 
		local totalDistance = util.distance(util.nodePos(node), otherTownPos) + util.distBetweenNodes(node, townNode)
		trace("The totalDistance was",totalDistance,"distBetweenTowns=",distBetweenTowns)
		if midPointSearch and totalDistance > 1.3*distBetweenTowns then 
			trace("Rejecting pair",node,townNode,"as the total dist is too high")
			return false
		end
		local foundPath= #pathFindingUtil.findRoadPathBetweenNodes(townNode, node) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(node, townNode) > 0
		trace("createHighwayJunction: initial look for path between",townNode,node," foundPath?",foundPath)
		if #util.getSegmentsForNode(node) == 1 then 
			local outboundTangent = util.getDeadEndNodeDetails(node).tangent 
			local angle = math.abs(util.signedAngle(townVector, outboundTangent))
			trace("The angle to the vector of the node ",node, " from ",town.name," to ",otherTown.name," was ",math.deg(angle))
			if angle > math.rad(100) and not connectEval.isCornerTown(town) then 
				foundPath = false 
				trace("Rejecting ",node, " as wrong angle")
			end 
		end
		if not midPointSearch and util.distance(util.v3fromArr(otherTown.position), util.nodePos(node)) < util.distance(util.v3fromArr(town.position), util.nodePos(node)) then 
			trace("Rejecting ",node," as it is closer to the other city")
			foundPath = false
		end 
		if midPointSearch and foundPath then 
			trace("checking for midPointSearch if it was a highwayroute at node",node)
			local routeInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(townNode, node)) or pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node, townNode))
			if not routeInfo.isHighwayRoute then
				trace("Found route but NOT highway!",node)
				foundPath = false 
			end
			trace("Teh routeinfo actualRouteToDist=",routeInfo.actualRouteToDist)
			if routeInfo.actualRouteToDist> 1.5 then 	
				trace("Rejecting on the basis of too long")
				foundPath = false 
			end
		end 
		if #util.getSegmentsForNode(node) == 3 then
			local foundMultiLaneHighway = false 
			for i, seg in pairs(util.getSegmentsForNode(node)) do 
				if util.getStreetTypeCategory(seg)=="highway" and util.getNumberOfStreetLanes(seg) > 3 then 
					foundMultiLaneHighway = true 
					break 
				end
			end 
			if not foundMultiLaneHighway then 
				trace("Not found multiLaneHighway, rejecting")
				foundPath = false 
			end 
		end 
		trace("createHighwayJunction looking for path between",townNode,node," foundPath?",foundPath)
		return foundPath
	end
	local searchRadius = math.min(1000, math.max(500, distBetweenTowns/2))
	local highwayNodes = util.searchForDeadEndHighwayNodes(town.position, searchRadius, filterFn) 
	if #highwayNodes == 0 then 
		 midPointSearch = true
		 highwayNodes = util.searchForDeadEndHighwayNodes(midPoint, distBetweenTowns/2, filterFn) 
	end 
	if #highwayNodes> 0 then 
		if not params.searchMap then 
			params.searchMap = {} 
		end  
		params.searchMap[town.id]=util.nodePos(highwayNodes[1]) 
		callback({}, true) 
		trace("Dead end highway nodes WERE found ",town.name," to connect with ",otherTown.name)
		return
	end 
	trace("Dead end highway nodes WERE NOT found ",town.name," to connect with ",otherTown.name)
	local junctionNodes = util.searchForHighwayNodes(midPoint, distBetweenTowns/2, filterFn)
	if #junctionNodes == 0 then 
		 midPointSearch = false
		junctionNodes = util.searchForHighwayNodes(town.position, searchRadius, filterFn)
	end 
	if #junctionNodes > 0 then 
		searchRadius = searchRadius + 1000-- may be a junction construction nearby check again for dead end nodes at greater distance
		trace("Searching for dead end highway nodes at radius",searchRadius," for town ",town.name)
		if #util.searchForDeadEndHighwayNodes(town.position, searchRadius, filterFn) > 0 then 
			if not params.searchMap then 
				params.searchMap = {} 
			end  
			params.searchMap[town.id]=util.nodePos(junctionNodes[1])
			callback({}, true) 
			return
		end 
		trace("Found junction nodes, begin building highway junction for ",town.name," to connect with ",otherTown.name, " there were ",#junctionNodes,"#junctionNodes")
		routeBuilder.buildTJunction(town, otherTown, callback, params,junctionNodes)
		return
	end 

	if not params.townJunctionOffset then 
		params.townJunctionOffset = 90
	end
	
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local highwayType = api.res.streetTypeRep.find(params.preferredHighwayRoadType)
	local isThreeLane = params.preferredHighwayRoadType == "standard/country_large_one_way_new.lua"

	local isTerminus   
	if params.buildTerminus then  
		trace("createHighwayJunction: The original isTerminus=",isTerminus," the overriden one is",params.buildTerminus[town.id])
		isTerminus = params.buildTerminus[town.id] 
	else 
		isTerminus = connectEval.shouldBuildTerminus(town, otherTown)
	end 
	-- isTerminus= true
	trace("createHighwayJunction for ",town.name,otherTown.name," determined isTerminus?",isTerminus)
	local townType = api.res.streetTypeRep.find(params.preferredUrbanRoadType)
	local offset = util.getStreetWidth(highwayType)+params.highwayMedianSize
	local onRampType = routeBuilder.getOnRampType()
	local townPos = util.v3fromArr(town.position)
	local function shouldBuildUnderground(positionAndRotation) 
		if params.isUnderground then 
			return true
		end 
		if params.isElevated then 
			return false  
		end 
		if isTerminus then 
			return false 
		end 
		if positionAndRotation.position.z > 100 and api.res.getBaseConfig().climate ~= "temperate.clima.lua" then 
			return true
		end 
		local airports = util.findAirportsForTown(town.id)
		if #airports > 0 then
			local airPortPos = util.getStationPosition(airports[1])
			local distance = util.distance(positionAndRotation.position, airPortPos)
			local shouldBuildUnderground = distance < 500
			trace("Found airport for town",town.name,"at distance of",distance,"should buildUnderground?",shouldBuildUnderground)
			if shouldBuildUnderground then 
				return true 
			end
		end 
		
		
		local foundNearbyBuildings = false
		  
		for sign = -1, 1, 2 do
			local testP = 250*sign*positionAndRotation.stationParallelTangent + positionAndRotation.position
			local countNearyBuildings = util.countNearbyEntities(testP, 50, "TOWN_BUILDING")
			trace("createHighwayJunction: Count nearby town buildings near",testP.x,testP.y,"was ",countNearyBuildings)
			if  countNearyBuildings > 0 then 
				trace("Found nearby town buildings near",testP.x,testP.y,"running underground")
				foundNearbyBuildings =  true 
			end
			if util.isUnderwater(testP) then 
				trace("Found underwater points, aborting underground")
				return false 
			end
		end 
		return foundNearbyBuildings 
	end 
--	local trumpetInterchange = "street/VanillaTrumpetInterchange.con"
	local trumpetInterchange = "AI_Builder_VanillaTrumpetInterchange.con"
	local foundTrumpetInterchange = api.res.constructionRep.find(trumpetInterchange)~= -1 and not params.disableTrumpetInterchange and not isTerminus
	local context = util.initContext()
	trace("Looking for trumpetInterchange",trumpetInterchange,"found?",foundTrumpetInterchange)
	local function buildHiwayJunction(positionAndRotation) 
		positionAndRotation.tangent = vec3.normalize(positionAndRotation.tangent)
		positionAndRotation.stationPerpTangent =vec3.normalize( positionAndRotation.stationPerpTangent)
		local tangent = positionAndRotation.stationParallelTangent
		local perpTangent = positionAndRotation.stationPerpTangent
		
		local junctionOffset = params.townJunctionOffset
		local minDistToTown = math.huge
		local isUnderground = shouldBuildUnderground(positionAndRotation) 

		 
		for i = -350, 350, 10 do 
			local testP = junctionOffset*perpTangent + i*tangent + positionAndRotation.position
			minDistToTown = math.min(minDistToTown, util.distance(testP, townPos))
		end 
		trace("The minDistToTown was ",minDistToTown, " for ",junctionOffset)
		if minDistToTown < 200 and not isUnderground then -- avoid blasting through the middle of a town 	
			junctionOffset = junctionOffset+(200-minDistToTown)
			trace("Increasing the junctionOffset to ",junctionOffset)
		end 
	
		if foundTrumpetInterchange  then 
			local construction =  api.type.SimpleProposal.ConstructionEntity.new() 
			local constrParams = setupJunctionParams(params) 
			construction.fileName = trumpetInterchange
			if isUnderground then 
				constrParams.highwaylevel = 2
			end 
			 
			local p = positionAndRotation.position + 180*positionAndRotation.tangent
			p.z = p.z + positionAndRotation.extraHeight
			local perpTangent = util.rotateXY(positionAndRotation.tangent, math.rad(90))
			local length = 130
			local maxTerrainOffset = -math.huge
			local minTerrainOffset = math.huge
			local needsElevation = false 
			local isOverWater = false 
			local needsDeconfliction = false
			local minConflictionHeight = math.huge 
			local maxConflictionHeight = -math.huge
			for i = -200, 200, 10 do 
				local testP = p+i*perpTangent
				local terrain = util.th(testP)
				if terrain < util.getWaterLevel() then 
					needsElevation = true 
					isOverWater = true 
					--constrParams.vanillahiwayheight = constrParams.vanillahiwayheight + 3 -- N.B. the increment is 5, so 5+10 = 15
				end 
				for i, node in pairs(util.searchForEntities(testP, 10, "BASE_NODE")) do 
					local z = node.position[3]
					minConflictionHeight = math.min(z-10, minConflictionHeight)
					maxConflictionHeight = math.max(z+10, maxConflictionHeight)
					if math.abs(z-testP.z) < 10 then 
						needsDeconfliction = true 
					end 
				end 
				for i , constr in pairs(util.searchForEntities(testP, 10, "CONSTRUCTION", true)) do 
					local p = util.getConstructionPosition(constr)
					local z = p.z 
					minConflictionHeight = math.min(z-10, minConflictionHeight)
					maxConflictionHeight = math.max(z+10, maxConflictionHeight)
					if math.abs(z-testP.z) < 10 then 
						needsDeconfliction = true 
					end 
				end 
				if math.abs(i)<= length then 
					local terrainOffset = testP.z - terrain 
					maxTerrainOffset = math.max(maxTerrainOffset, terrainOffset)
					minTerrainOffset = math.min(minTerrainOffset, terrainOffset)
				end
			end 
			trace("Inspecting location around the junction, minTerrainOffset=",minTerrainOffset,"maxTerrainOffset=",maxTerrainOffset,"around ",p.x,p.y,p.z,"needsDeconfliction?",needsDeconfliction)
			
			if needsDeconfliction then 
				local offset1 = p.z - minConflictionHeight 
				local offset2 = maxConflictionHeight - p.z 
				local goUnder = (offset1 < offset2 or isUnderground) and not isOverWater
				
				trace("Detected needs deconfliction, minConflictionHeight=",minConflictionHeight,"maxConflictionHeight=",maxConflictionHeight," offset1=",offset1,"offset2=",offset2,"goUnder?",goUnder)
				if goUnder then 
					constrParams.highwaylevel = 2
				else 
					needsElevation = true 
				end 
			
			end 
			if maxTerrainOffset < -15 and not needsElevation then 
				constrParams.special = 2 -- tunnel
				trace("Setting special to 2 at ",town.name)
			end 
			if needsElevation then 
				constrParams.highwaylevel = 1
			end 
			if minTerrainOffset > 15 then 
				constrParams.special = 1
				trace("Setting special to 1 at ",town.name)
			end 
			if isOverWater then 
				p.z = math.max(p.z, util.getWaterLevel()+15)
			end 

			
			--local rotation = positionAndRotation.rotation +math.rad(180)--+ math.rad(90)
			local rotation = math.rad(180)-util.signedAngle(positionAndRotation.tangent, vec3.new(0,1,0))
			trace("Attempting to build trumpetInterchange at ",p.x,p.y,p.z," with rotation",math.deg(rotation),"node=",positionAndRotation.originalNode,"offset=",params.townJunctionOffset,"at",town.name)
			construction.transf = util.transf2Mat4f(transf.rotZTransl(rotation,p))
			construction.params = constrParams
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToAdd[1] = construction 
			local fullProposal = api.cmd.make.buildProposal(newProposal, context, true)
			
			local nodesToAdd = {}
			local edgesToAdd =  {} 
			for i, edge in pairs(fullProposal.proposal.proposal.addedSegments) do 
				local newEntity = util.copySegmentAndEntity(edge, -1-#edgesToAdd)-- N.B. must always make explicit copy 
				local playerOwned = api.type.PlayerOwned.new() -- need to mark as player owned to prevent towns from building their own junctions
				playerOwned.player = api.engine.util.getPlayer()
				newEntity.playerOwned = playerOwned
				table.insert(edgesToAdd, newEntity) 
			end 
			
			local newEdgeNodeToSegMap = {}
			for i, edge in pairs(edgesToAdd) do 
				for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
					if not newEdgeNodeToSegMap[node] then 
						newEdgeNodeToSegMap[node]={}
					end 
					table.insert(newEdgeNodeToSegMap[node], edge)
				end 
			end 

			
			local replacedEdge 
			for i , node in pairs( fullProposal.proposal.proposal.addedNodes) do 
				local newNode = util.newNodeWithPosition(node.comp.position, -10000-#nodesToAdd)
				if #newEdgeNodeToSegMap[node.entity] == 1 then 
					local edge = newEdgeNodeToSegMap[node.entity][1]
					if util.getStreetTypeCategory(edge.streetEdge.streetType)~="highway" then 
						trace("Replacing the node with the new one at",positionAndRotation.originalNode)
						newNode.entity = positionAndRotation.originalNode
					end 
				end 
				
				
				
				if newNode.entity < 0 then 
					table.insert(nodesToAdd, newNode)
				end 	
				for j , edge in pairs(newEdgeNodeToSegMap[node.entity]) do 	
					local isNode0 = edge.comp.node0 == node.entity
					if isNode0 then 
						edge.comp.node0 = newNode.entity
					else 
						assert(edge.comp.node1 == node.entity)
						edge.comp.node1 = newNode.entity
					end 
					if newNode.entity > 0 then	
						replacedEdge = edge 
					end
				end 
				 
			end 
			
			local isNode0 = replacedEdge.comp.node0 > 0
			assert(not isNode0) -- should always be at node1 because of the construction
			if not isNode then 
				local nodeIndex = 1-1*replacedEdge.comp.node0-10000
				local newNode = nodesToAdd[nodeIndex]
				assert(newNode.entity == replacedEdge.comp.node0)
				local p0 = util.v3(newNode.comp.position)
				local p1 = util.nodePos(replacedEdge.comp.node1)
				local t0 = util.v3(replacedEdge.comp.tangent0)
				local t1 
				if #util.getSegmentsForNode(replacedEdge.comp.node1) == 2 then 
					t1 = util.v3(replacedEdge.comp.tangent1) -- keep
				else 
					t1 = -1*util.getDeadEndNodeDetails(replacedEdge.comp.node1).tangent 
				end
				local newLength = util.calculateTangentLength(p0, p1, t0, t1)
				util.setTangent(replacedEdge.comp.tangent0, newLength*vec3.normalize(t0))
				util.setTangent(replacedEdge.comp.tangent1, newLength*vec3.normalize(t1))
			end 
			
			local newProposal2 = api.type.SimpleProposal.new()
			for i, edge in pairs(edgesToAdd) do 
				newProposal2.streetProposal.edgesToAdd[i]=edge
			end 
			for i, node in pairs(nodesToAdd) do 
				newProposal2.streetProposal.nodesToAdd[i]=node
			end 
			return newProposal2
		end 
		
		local nodesToAdd = {}
		local edgesToAdd = {}
		local edgeObjectsToAdd = {}
		local edgesToRemove = {} 
		local alreadySeen = {}
		local removedEdges = {}
		local nodeToPositionMap = {}
		local newNodeMap = {}
		local function nextEdgeId() 
			return -1-#edgesToAdd
		end
		local nodeId = -1000
		local function nextNodeId()
			nodeId = nodeId -1
			return nodeId
		end 
		
		local function nodePos(node) 
			if node > 0 then 
				return util.nodePos(node) 
			else 
				return nodeToPositionMap[node]
			end 
		end 
		
		local function newEntity(node0, node1, streetType, doNotInsert) 
			local entity = api.type.SegmentAndEntity.new() 
			entity.type = 0
			entity.entity = nextEdgeId() 
			entity.comp.node0 = node0
			entity.comp.node1 = node1
			local p0 = nodePos(node0) 
			local p1 = nodePos(node1) 
			if p0.z - util.th(p0) > 5 and p1.z - util.th(p1) > 5 or util.isUnderwater(p0) or util.isUnderwater(p1) then 
				entity.comp.type = 1
				entity.comp.typeIndex = cement 
			elseif  p0.z - util.th(p0) < -10 and p1.z - util.th(p1) <-10 then 
				entity.comp.type = 2 
				entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")			
			end
			local t = p1 - p0
			util.setTangents(entity, t)  
			entity.streetEdge.streetType = streetType
			if not doNotInsert then 
				table.insert(edgesToAdd, entity)
			end
			return entity
		end 
		local exitRampLength = 35
		local function newHighwaySegment(newNode0, newNode1) 
			local entity = newEntity(newNode0, newNode1)
			entity.streetEdge.streetType = highwayType			
			return entity
		end 
		local nodesByHash = {}
		local function makeNewNode(p) 
			if nodesByHash[util.pointHash3d(p)] then 
				return nodesByHash[util.pointHash3d(p)]
			end 
			local newNode = util.newNodeWithPosition(p, nextNodeId())
			nodesByHash[util.pointHash3d(p)] = newNode
			table.insert(nodesToAdd, newNode)
			trace("buildHiwayJunction: makeNewNode: added node",newNode.entity,"at",p.x, p.y,p.z)
			nodeToPositionMap[newNode.entity]=p 
			newNodeMap[newNode.entity]=newNode
			return newNode.entity
		end 
		
		local function toEdge(entity) 
			return { 
				p0 = nodePos(entity.comp.node0),
				p1 = nodePos(entity.comp.node1),
				t0 = util.v3(entity.comp.tangent0),
				t1 = util.v3(entity.comp.tangent1)			
			}
		end 
		
		local linkEntity
		local innerJoinNode = positionAndRotation.originalNode
		local innerJoinNodePos = util.nodePos(innerJoinNode)
		local outerJoinNode
		local outerJoinNodePos
		local position = positionAndRotation.position
		if isTerminus and true then 
			local construction =  api.type.SimpleProposal.ConstructionEntity.new() 
			--local constrParams = setupJunctionParams(params) 
			local constrParams = interchangeutil.defaultParams()
			constrParams.seed = 0
			construction.fileName = "AI_Builder_Highway_Terminus.con"
			if params.preferredHighwayRoadType == "standard/country_medium_one_way_new.lua" then
				constrParams.aiBuilderInterchangeLaneCount = 0
			end 
			constrParams.aiBuilderInterchangeLevel = 0
			local p = positionAndRotation.position + 180*positionAndRotation.tangent
			p.z = p.z + positionAndRotation.extraHeight
			local perpTangent = util.rotateXY(positionAndRotation.tangent, math.rad(90))
			local length = 130
			local maxTerrainOffset = -math.huge
			local minTerrainOffset = math.huge
			local needsElevation = false 
			local isOverWater = false 
			for i = -200, 200, 10 do 
				local testP = p+i*perpTangent
				local terrain = util.th(testP)
				if terrain < util.getWaterLevel() then 
					needsElevation = true 
					isOverWater = true 
					--constrParams.vanillahiwayheight = constrParams.vanillahiwayheight + 3 -- N.B. the increment is 5, so 5+10 = 15
				end 
				if math.abs(i)<= length then 
					local terrainOffset = testP.z - terrain 
					maxTerrainOffset = math.max(maxTerrainOffset, terrainOffset)
					minTerrainOffset = math.min(minTerrainOffset, terrainOffset)
				end
			end 
			trace("Inspecting location around the junction, minTerrainOffset=",minTerrainOffset,"maxTerrainOffset=",maxTerrainOffset,"around ",p.x,p.y,p.z)
			
			
			if maxTerrainOffset < -15 and not needsElevation then 
				constrParams.special = 2 -- tunnel
				trace("Setting special to 2 at ",town.name)
			end 
			if needsElevation then 
				constrParams.aiBuilderInterchangeLevel = 1
			end 
			if minTerrainOffset > 15 then 
				constrParams.special = 1
				trace("Setting special to 1 at ",town.name)
			end 
			if isOverWater then 
				p.z = math.max(p.z, util.getWaterLevel()+15)
			end 
			
			--local rotation = positionAndRotation.rotation +math.rad(180)--+ math.rad(90)
			local rotation =  util.signedAngle(positionAndRotation.tangent, vec3.new(-1,0,0))
			local angleToVector =  util.signedAngle(positionAndRotation.tangent,townVector) 
			local perpTangent = util.rotateXY(positionAndRotation.tangent, math.rad(90))
			local angleToVector2 =  util.signedAngle(perpTangent,townVector) 
			trace("createHighwayJunction: the angle of tangent to angle to vector was",math.deg(angleToVector),"at ",town.name,"angleToVector2=",math.deg(angleToVector2))
			if math.abs(angleToVector2) > math.rad(90) then 
				 trace("Flipping rotation")
				 rotation = rotation + math.rad(180)
			end 
			trace("Attempting to build terminus at at ",p.x,p.y,p.z," with rotation",math.deg(rotation),"node=",positionAndRotation.originalNode,"offset=",params.townJunctionOffset)
			construction.transf = util.transf2Mat4f(transf.rotZTransl(rotation,p))
			construction.params = constrParams
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToAdd[1] = construction 
			local fullProposal = api.cmd.make.buildProposal(newProposal, context, true)
			
			local nodesToAdd = {}
			local edgesToAdd =  {} 
			for i, edge in pairs(fullProposal.proposal.proposal.addedSegments) do 
				local newEntity = util.copySegmentAndEntity(edge, -i-#edgesToAdd)-- N.B. must always make explicit copy 
				local playerOwned = api.type.PlayerOwned.new() -- need to mark as player owned to prevent towns from building their own junctions
				playerOwned.player = api.engine.util.getPlayer()
				newEntity.playerOwned = playerOwned
				table.insert(edgesToAdd, newEntity) 
			end 
			
			local newEdgeNodeToSegMap = {}
			for i, edge in pairs(edgesToAdd) do 
				for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
					if not newEdgeNodeToSegMap[node] then 
						newEdgeNodeToSegMap[node]={}
					end 
					table.insert(newEdgeNodeToSegMap[node], edge)
				end 
			end 
			
			local options = {}
			for i , node in pairs( fullProposal.proposal.proposal.addedNodes) do 
				if #newEdgeNodeToSegMap[node.entity] == 1 then 
					local edge = newEdgeNodeToSegMap[node.entity][1]
					if util.getStreetTypeCategory(edge.streetEdge.streetType)~="highway" then 
						table.insert(options, {
							nodeToReplace = node.entity,
							node = positionAndRotation.originalNode,
							scores = {util.distance(util.nodePos(positionAndRotation.originalNode), node.comp.position)}
						})
					end 
				end 
			end 
			local replacementNode = util.evaluateWinnerFromScores(options)
			
			local replacedEdge 
			for i , node in pairs( fullProposal.proposal.proposal.addedNodes) do 
				local newNode = util.newNodeWithPosition(node.comp.position, -10000-#nodesToAdd)
				--[[if #newEdgeNodeToSegMap[node.entity] == 1 then 
					local edge = newEdgeNodeToSegMap[node.entity][1]
					if util.getStreetTypeCategory(edge.streetEdge.streetType)~="highway" then 
						trace("Replacing the node with the new one at",positionAndRotation.originalNode)
						newNode.entity = positionAndRotation.originalNode
					end 
				end ]]--
				if replacementNode.nodeToReplace == node.entity then 
					newNode.entity = replacementNode.node
				end 
				if newNode.entity < 0 then 
					table.insert(nodesToAdd, newNode)
				end 	
				for j , edge in pairs(newEdgeNodeToSegMap[node.entity]) do 	
					local isNode0 = edge.comp.node0 == node.entity
					if isNode0 then 
						edge.comp.node0 = newNode.entity
					else 
						assert(edge.comp.node1 == node.entity)
						edge.comp.node1 = newNode.entity
					end 
					if newNode.entity > 0 then	
						replacedEdge = edge 
					end
				end 
				 
			end 
			
			--local isNode0 = replacedEdge.comp.node0 > 0
			--assert(not isNode0) -- should always be at node1 because of the construction
			if false then 
				local nodeIndex = 1-1*replacedEdge.comp.node0-10000
				local newNode = nodesToAdd[nodeIndex]
				assert(newNode.entity == replacedEdge.comp.node0)
				local p0 = util.v3(newNode.comp.position)
				local p1 = util.nodePos(replacedEdge.comp.node1)
				local t0 = util.v3(replacedEdge.comp.tangent0)
				local t1 
				if #util.getSegmentsForNode(replacedEdge.comp.node1) == 2 then 
					t1 = util.v3(replacedEdge.comp.tangent1) -- keep
				else 
					t1 = -1*util.getDeadEndNodeDetails(replacedEdge.comp.node1).tangent 
				end
				local newLength = util.calculateTangentLength(p0, p1, t0, t1)
				util.setTangent(replacedEdge.comp.tangent0, newLength*vec3.normalize(t0))
				util.setTangent(replacedEdge.comp.tangent1, newLength*vec3.normalize(t1))
			end 
			
			local newProposal2 = api.type.SimpleProposal.new()
			for i, edge in pairs(edgesToAdd) do
				edge.entity = -i -- nb safe to do here because there are no edgeobjects 			
				newProposal2.streetProposal.edgesToAdd[i]=edge
			end 
			for i, node in pairs(nodesToAdd) do 
				newProposal2.streetProposal.nodesToAdd[i]=node
			end 
			return newProposal2 
		
		end 
		
		if isTerminus and false  then -- disabled it does not work  reliably
			 local r = isThreeLane and 60 or 40
			--local r  = 60
			if positionAndRotation.extraRaduis then 
				trace("Adding extraRaduis",positionAndRotation.extraRaduis)
				r = r + positionAndRotation.extraRaduis
			end 
			local length = r * 4 * (math.sqrt(2)-1)
			trace("buildHiwayJunction: Adding startNode for terminus")
			local startNode = makeNewNode(position)
			local circleMidPoint = position + r*perpTangent
			newEntity(positionAndRotation.originalNode, startNode, townType)
			local sign = positionAndRotation.stationRelativeAngle < 0 and -1 or 1
			tangent = sign*tangent
			trace("buildHiwayJunction: Adding node2 for terminus")
			local node2 = makeNewNode(position + r*tangent + r*perpTangent)
			local entity1 = newEntity(startNode, node2, highwayType)
			util.setTangent(entity1.comp.tangent0, length*tangent)
			util.setTangent(entity1.comp.tangent1, length*perpTangent)
			trace("buildHiwayJunction: Adding node3 for terminus")
			local node3 = makeNewNode(position + 2*r*perpTangent)
			local entity2 = newEntity(node2, node3, highwayType)
			util.setTangent(entity2.comp.tangent0, length*perpTangent)
			util.setTangent(entity2.comp.tangent1, -length*tangent)
			trace("buildHiwayJunction: Adding node4 for terminus")
			local node4 = makeNewNode(position + r*perpTangent-r*tangent)
			local entity3 = newEntity(node3, node4, highwayType)
			util.setTangent(entity3.comp.tangent0, -length*tangent)
			util.setTangent(entity3.comp.tangent1, -length*perpTangent)
			local entity4 = newEntity(node4, startNode, highwayType)
			util.setTangent(entity4.comp.tangent0, -length*perpTangent)
			util.setTangent(entity4.comp.tangent1, length*tangent)
		
			local tangentToOtherTown = vec3.normalize(util.v3fromArr(otherTown.position)-circleMidPoint)
			local doNotBuildConnectPeice = true
			
			local startHighwayPos = circleMidPoint + 2*r * tangentToOtherTown
			if params.isElevated then 
				tangentToOtherTown.z = 0.1
				doNotBuildConnectPeice = false
				startHighwayPos.z = startHighwayPos.z + tangentToOtherTown.z*r				
			elseif isUnderground then 
				tangentToOtherTown.z = -0.1
				doNotBuildConnectPeice = false
				startHighwayPos.z = startHighwayPos.z - tangentToOtherTown.z*r
			end 
			local rightPos = util.nodePointPerpendicularOffset(startHighwayPos, tangentToOtherTown, -0.5*offset)
			local leftPos = util.nodePointPerpendicularOffset(startHighwayPos, tangentToOtherTown, 0.5*offset)
		 
			local outbound = newEntity( makeNewNode(rightPos), makeNewNode(rightPos+40*tangentToOtherTown), highwayType, doNotBuildConnectPeice)
		 
			local inbound = newEntity( makeNewNode(leftPos),makeNewNode(leftPos+40*tangentToOtherTown), highwayType, doNotBuildConnectPeice)
			local collisionEntityIds = {}
			local entities = {entity1, entity2, entity3, entity4}
			local leftConnect = circleMidPoint + 2*r * util.rotateXY(tangentToOtherTown, math.rad(35))
			local rightConnect = circleMidPoint + 2*r * util.rotateXY(tangentToOtherTown, -math.rad(35))
			local exitEntities = {inbound, outbound}
			local idx
			local collissionNodes = {} 
			collissionNodes[startNode]=true
			for j, connect in pairs({leftConnect, rightConnect}) do 
				local c 
				local collisionEntity 
				local function findCollisionPoint(extraOffset)
					for i , entity in pairs(entities) do 
						local p1 = nodePos(entity.comp.node0)
						local p2 = nodePos(entity.comp.node1)
						if extraOffset then 
							p1 = p1 - extraOffset*vec3.normalize(util.v3(entity.comp.tangent0))
							p2 = p2 + extraOffset*vec3.normalize(util.v3(entity.comp.tangent1))
						end 
						
						c = util.checkFor2dCollisionBetweenPoints(p1,p2 , circleMidPoint, connect) 
						if c then
							idx = i
							collisionEntity=entity 
							collisionEntityIds[entity.entity]=true
							break 
						end
					end 
				end 
				findCollisionPoint()
				if not c then 
					trace("First attempt to find collsion point failed, attempting again") 
					for extraOffset = 1, 20 do 
						findCollisionPoint(extraOffset) 
						trace("On ",extraOffset,"th attempt it was ",c)
						if c then break end
					end 
				end
				if not c then break end
				assert(c)
				local connectNode
				local edge =  toEdge(collisionEntity)
				local t = util.solveForPositionHermite(util.v2ToV3(c, connect.z),edge)
				local fullC = util.hermite2(t, edge) 
				local node0 = collisionEntity.comp.node0 
				local node1 = collisionEntity.comp.node1
				local tangent0 = util.v3(collisionEntity.comp.tangent0)
				local tangent1 = util.v3(collisionEntity.comp.tangent1)
				local isNode0 = false 
				local isNode1 = false 
				local connectTangent  = vec3.normalize(fullC.t)
				local minDist = math.min(vec2.distance(c, nodePos(node0)) , vec2.distance(c, nodePos(node1)))
				if collissionNodes[node0] and collissionNodes[node1] or minDist > 10 then -- always go down this
					connectNode = makeNewNode(fullC.p)
					trace("Creating new connectNode ",connectNode,"fullC.p=",fullC.p.x, fullC.p.y)
					local entity2 = newEntity(node0, connectNode, highwayType)
					util.setTangent(collisionEntity.comp.tangent0, t*tangent0)
					util.setTangent(collisionEntity.comp.tangent1, t*vec3.length(tangent1)*connectTangent)
					util.setTangent(entity2.comp.tangent0,(t-1)*vec3.length(tangent1)*connectTangent)
					util.setTangent(entity2.comp.tangent1, (t-1)*tangent1) 					
				elseif collissionNodes[node0] then 
					isNode1 = true 
					connectNode = node1
				elseif  collissionNodes[node1] then 
					isNode0 = true 
					connectNode = node0
				else 
					local isNode0 = vec2.distance(c, nodePos(node0)) < vec2.distance(c, nodePos(node1)) 
					isNode1 = not isNode0
					if isNode0 then
						connectNode = node0
					else 
						connectNode = node1 
					end 					
				end
				collissionNodes[connectNode]=true
	
				--[[local mint = offset / (0.5*math.pi*r)
				local maxt = 1-mint 
				if t < mint or t > maxt then 
					trace("Adjusting t as it was too close. t=",t," maxt=",maxt,"mint=",mint)
					t= math.min(maxt, math.max(t, mint))
					trace("t is now",t)
				end ]]--
				trace("Setting position on node",newNodeMap[connectNode]," to ",fullC.p.x,fullC.p.y)
				util.setPositionOnNode(newNodeMap[connectNode], fullC.p)
				
				--local entity2 = newEntity(node0, connectNode, highwayType)
				 trace("At j=",j," the connectNode was ",connectNode," the collisionEntity was ", collisionEntity.entity, " isNode0=",isNode0," idx=",idx)
				if isNode0 then 
					local lengthToEnd = t*vec3.length(tangent1)
					util.setTangent(collisionEntity.comp.tangent0, (1-t)*vec3.length(tangent0)*connectTangent)
					util.setTangent(collisionEntity.comp.tangent1, (1-t)*tangent1)
					local adjacentEdge = entities[idx-1]
					
					local currentLength = vec3.length(util.v3(adjacentEdge.comp.tangent0))
					local newLength = lengthToEnd + currentLength
					util.setTangent(adjacentEdge.comp.tangent0, (newLength/currentLength)*util.v3(adjacentEdge.comp.tangent0))
					util.setTangent(adjacentEdge.comp.tangent1, newLength*connectTangent)
				elseif isNode1 then
					local lengthToStart = (t-1)*vec3.length(tangent1)
					util.setTangent(collisionEntity.comp.tangent0, t*tangent0)
					util.setTangent(collisionEntity.comp.tangent1, t*vec3.length(tangent1)*connectTangent) 
					local adjacentEdge = entities[idx+1]
					local currentLength = vec3.length(util.v3(adjacentEdge.comp.tangent0))
					local newLength = lengthToStart + currentLength
					util.setTangent(adjacentEdge.comp.tangent0, newLength*connectTangent)
					util.setTangent(adjacentEdge.comp.tangent1, (newLength/currentLength)*util.v3(adjacentEdge.comp.tangent1))
				end
							  
				local exitEntity = exitEntities[j]
				local connectEntity = newEntity(connectNode, exitEntity.comp.node0, highwayType)
				local rotate = j == 1 and -math.rad(135) or -math.rad(45)
				local startTangent = util.rotateXY(util.v3(connectTangent), rotate)
				local exitTangent = util.v3(exitEntity.comp.tangent1)
				local connectLength = util.calculateTangentLength(nodePos(connectNode), nodePos(connectEntity.comp.node1), startTangent, exitTangent)
				util.setTangent(connectEntity.comp.tangent1,  connectLength*vec3.normalize(exitTangent))
				local sign = -1 
				
				util.setTangent(connectEntity.comp.tangent0, connectLength*vec3.normalize(startTangent))
				if j == 1 then 
					util.reverseNewEntity(connectEntity)
					
				end 
				--break
			end
			util.reverseNewEntity(inbound)
			
			for i = 2, #entities do 
				if not collisionEntityIds[entities[i-1].entity] and not collisionEntityIds[entities[i]] then 
					trace("Attempting to build link road at i=",i)
					for k, node in pairs({entities[i].comp.node0, entities[i].comp.node1}) do  
						if not collissionNodes[node] then
							local tangent = vec3.normalize(util.rotateXY(util.v3(entities[i].comp.tangent0), -math.rad(90)))
							local newProposal = {} 
							newProposal.streetProposal = {} 
							newProposal.streetProposal.edgesToAdd = {}
							newProposal.streetProposal.edgesToRemove = {}
							newProposal.streetProposal.nodesToAdd = { newNodeMap[node] }
							constructionUtil.buildLinkRoad(newProposal, node, tangent, 0, nodePos(node), nextNodeId)
							for i =1 , #newProposal.streetProposal.edgesToAdd do 
								local entity = newProposal.streetProposal.edgesToAdd[i]
								entity.entity  = nextEdgeId()
								table.insert(edgesToAdd, entity)
							end 
							for i = 2, #newProposal.streetProposal.nodesToAdd do 
								local newNode = newProposal.streetProposal.nodesToAdd[i]
								table.insert(nodesToAdd, newNode)
							end
						end
					end
				end 
			end
			
			--local outboundConnect = newEntity(collisionEntity.comp.node0, outbound.comp.node0, highwayType)
			--util.setTangent(outboundConnect.comp.tangent1, vec3.length(util.v3(outboundConnect.comp.tangent1))*vec3.normalize(util.v3(outbound.comp.tangent0)))
			--local inboundConnect = newEntity(inbound.comp.node1, collisionEntity.comp.node1, highwayType)
			--util.setTangent(inboundConnect.comp.tangent0, vec3.length(util.v3(inboundConnect.comp.tangent0))*vec3.normalize(util.v3(inbound.comp.tangent1)))
		elseif not (positionAndRotation.isVirtualDeadEnd and positionAndRotation.edgeToRemove) then 
			
			local testP = positionAndRotation.position + (junctionOffset + offset+ util.getStreetWidth(townType)) *perpTangent 
			while util.isUnderwater(testP)  and junctionOffset >= 35 do
				junctionOffset = junctionOffset - 5
				trace("Reduced junctionOffset to ", junctionOffset)
				testP = positionAndRotation.position + (junctionOffset + offset+ util.getStreetWidth(townType)) *perpTangent 
			end
			if junctionOffset > 40 then 
				position = positionAndRotation.position + junctionOffset*perpTangent
				innerJoinNodePos = position -35*perpTangent
				innerJoinNode = makeNewNode(innerJoinNodePos)
				newEntity(positionAndRotation.originalNode, innerJoinNode, townType ) 
			end
			local p = position + (offset+35)*perpTangent
			outerJoinNode = makeNewNode(p) 
			outerJoinNodePos = p
			linkEntity = newEntity(innerJoinNode, outerJoinNode, townType) 
			 
		else 
			local edge = util.getEdge(positionAndRotation.edgeToRemove)
			outerJoinNode = edge.node1 == innerJoinNode and edge.node0 or edge.node1 
			if util.calculateSegmentLengthFromEdge(edge) < 2*offset then 
				trace("Short segment detecting, using next node")
				local nextSegs = util.getStreetSegmentsForNode(outerJoinNode) 
				local nextEdgeId = nextSegs[1] == positionAndRotation.edgeToRemove and nextSegs[2] or nextSegs[1]
				local nextEdge = util.getEdge(nextEdgeId)
				outerJoinNode = outerJoinNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
			end
			outerJoinNodePos = util.nodePos(outerJoinNode)
		end
		trace("Building hiway junction, the innerJoinNode was ", innerJoinNode, " the outerJoinNode was ", outerJoinNode, " stationRelativeAngle was ",math.deg(positionAndRotation.stationRelativeAngle))
		local reversed = positionAndRotation.stationRelativeAngle < 0 
		if reversed then 
			tangent = -1*tangent 
		end
		local midOffset= 95
		if not isTerminus then 
			local prevNewNode
			local prevNewNode2
			for __ , i in pairs({-135, -midOffset, 0, midOffset, 135}) do 
				local p = position + i*tangent
				p.z = p.z + (isUnderground and -params.elevationHeight or params.elevationHeight)
				trace("buildHiwayJunction: Adding newNode at i=",i)
				local newNode =  makeNewNode(p)  
				local p2 = p + offset * perpTangent
				trace("buildHiwayJunction: Adding newNode2 at i=",i)
				local newNode2 =  makeNewNode(p2)  
				--params.leftHandTraffic
				local entity 
				local entity2 
				if prevNewNode then 
					entity = newEntity(prevNewNode, newNode, highwayType)
					entity2 = newEntity(newNode2, prevNewNode2, highwayType)
				end 
				if i == 0 then 
					if (entity.comp.type == 0 or entity2.comp.type == 0) and linkEntity then 
						if isUnderground then 
							linkEntity.comp.type = 1 
							linkEntity.comp.typeIndex = cement
						else 
							linkEntity.comp.type = 2 
							linkEntity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
						end
					end
				end 
				if math.abs(i) == midOffset  then
					local tangentForRamp = tangent 
					if i > 0 then 
						tangentForRamp = -1*tangent 
					end
					routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, newNode , p,tangentForRamp, entity.comp.type, innerJoinNode, innerJoinNodePos, params, nextEdgeId, nextNodeId, i<0, tangentForRamp)
					
					routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, newNode2 , p2,tangentForRamp, entity2.comp.type, outerJoinNode, outerJoinNodePos, params, nextEdgeId, nextNodeId, i > 0, tangentForRamp) 				
				
				 
				end
				prevNewNode = newNode 
				prevNewNode2 = newNode2 
			end
			--if positionAndRotation.stationRelativeAngle < 0 or  true then
			--	for i, newEdge in pairs(edgesToAdd) do 
			--		util.reverseNewEntity(newEdge)
			--	end 
			--end 
		end 
		
		--routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, true)
		return routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove)
	end
	local extraRaduii = {0}
	if isTerminus then 
		extraRaduii = { 0, 10, 20, 30, 40 }
	end
	local initialExtraOffset = town.type=="TOWN" and 45 or 0
	trace("Settting initial extraoffset to",initialExtraOffset)
	for extraHeight = 0, 15, 5 do 
		for i=1, #positions do
			for extraOffset = initialExtraOffset, 180, 45 do  
				params.townJunctionOffset=extraOffset
				local positionAndRotation = connectEval.getStationPositionAndRotation(town, positions[i], otherTown, params,0 ,thirdTown)
				positionAndRotation.extraRaduis = extraRaduis
				positionAndRotation.extraHeight = extraHeight
				local newProposal = buildHiwayJunction(positionAndRotation) 
				if not pcall(function() util.validateProposal(newProposal) end) then 
					trace("Proposal had an error, continueing")
					goto continue 
				end 
				newProposal = proposalUtil.attemptDeconfliction(newProposal)
				local checkResult = checkProposalForErrors(newProposal, true)
				 
				--if util.tracelog then debugPrint(newProposal) end
				if checkResult.isCriticalError then 
					
				end
				
				local canBuild = not checkResult.isCriticalError and (not checkResult.isError or params.ignoreErrors)
				local ignoreErrors = params.ignoreErrors
				if checkResult.isOnlyBridgePillarCollision then 
					canBuild = true 
					ignoreErrors = true 
				end
				if not canBuild and not checkResult.isCriticalError and not checkResult.isActualError then 
					canBuild = true 
					ignoreErrors = true 
				end
				if not canBuild and not checkResult.isCriticalError and #checkResult.errorState.messages==1 and checkResult.errorState.messages[1]=="Too much slope" then 
					canBuild = true 
					ignoreErrors = true 
					trace("Setting canBuild for too much slope")
				end 
				
				if canBuild then 
					if not params.searchMap then 
						params.searchMap = {}
					end
					params.searchMap[town.id]=positionAndRotation.position
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, context, ignoreErrors), function(res, success) 
					if success then 
						constructionUtil.addWork(function() routeBuilder.postBuildCheckEdgeTypes(res ) end)
					end 
					if callback then 
						callback(res, success)
					end 
					
					end )
					util.clearCacheNode2SegMaps()
					constructionUtil.addWork(function() 
						params = util.shallowClone(params)
						params.preferredUrbanRoadType = "standard/town_large_new.lua"
						params.isHighway = false
						routeBuilder.checkRoadRouteForUpgradeBetweenNodes(positionAndRotation.originalNode, townNode, params) 
					end)  
					return
				else 
					trace("Highway junction for town",town.name,"at",positions[i].nodePos.x,positions[i].nodePos.y," had an error, trying next, isCriticalError?",checkResult.isCriticalError)
				end
				::continue::
			 end
		end
	end
 	if not params.ignoreErrors then 
		trace("Unable to find a build, ignoring errrors")
		params.ignoreErrors  = true
		constructionUtil.createHighwayJunction(town, positions, otherTown, callback, params)
		params.ignoreErrors  = false
		return 
	elseif foundTrumpetInterchange then 
		trace("Unable to find a build, setting disableTrumpetInterchange to true")
		params.disableTrumpetInterchange  = true
		constructionUtil.createHighwayJunction(town, positions, otherTown, callback, params)
		params.disableTrumpetInterchange  = false
		return 
	end 
	callback({}, false)
 end

function constructionUtil.createRoadStationConstruction(position, rotation, params, naming, hasEntranceB, platL,platR, namePrefix, length)
	if not length then length = 2 end
	if length > 2 then 
		trace("WARNING! Max length >2",length)
		trace(debug.traceback())
		length = 2
	end
	local isCargo = params.isCargo
	local stationParams = { 
			catenary = 0,  
			length = length, 
			length2 = length,
			paramX = 0,  
			paramY = 0, 
			platL = platL and platL or 1,
			platR = platR and platR or 1,
			seed = 0, 
			templateIndex = isCargo and 3 or 2 , -- truck  
			suppressLargeEntry = isCargo  ,
			tramTrack = 0,
			year = util.year(),}
	if hasEntranceB and not params.hasEntranceB and not (isCargo and params.isAutoBuildMode) then
		stationParams.entrance_exit_b = 1
	end
	if params.isForTownTranshipment or params.includeLargeBuilding then 
		stationParams.includeLargeBuilding = true 
		stationParams.entrance_exit_b = 1
	end
	stationParams.includeSmallBuilding = params.includeSmallBuilding

	local modulebasics =  helper.createRoadTemplateFn(stationParams)
	local modules =  util.setupModuleDetailsForTemplate(modulebasics)  
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	newConstruction.name=naming.name..(namePrefix and " "..namePrefix.." " or " ")..(isCargo and _("Truck Station") or _("Bus Station"))
	local station = "station/street/modular_terminal.con"
	
	newConstruction.fileName = station
	newConstruction.playerEntity = api.engine.util.getPlayer()
	stationParams.modules = modules
	newConstruction.params = stationParams
	
			 
	local trnsf = rotZTransl(rotation, position)
	newConstruction.transf = util.transf2Mat4f(trnsf)
	return newConstruction
end

function constructionUtil.buildRoadStation(newProposal, position, rotation, params, naming, hasEntranceB, platL,platR, namePrefix, length)
	local newConstruction = constructionUtil.createRoadStationConstruction(position, rotation, params, naming, hasEntranceB, platL,platR, namePrefix, length)
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=newConstruction
end

local function getTypeFromMode(transportModes)
	if type(transportModes)=="string" then
		return transportModes
	end
	local TransportMode = api.type.enum.TransportMode
	for i, v in pairs(transportModes) do
		if type(i)=="string" then
			debugPrint({transportModes=transportModes}) 
			print(debug.traceback())
		end 
		local mode = i-1
		if v == 1 then
			if mode == TransportMode.BUS or mode == TransportMode.TRUCK then
				return "road"
			elseif mode == TransportMode.TRAIN or mode == TransportMode.ELECTRIC_TRAIN then
				return "train"
			elseif mode == TransportMode.SHIP or mode == TransportMode.SMALL_SHIP then
				return "ship"
			elseif mode == TransportMode.AIRCRAFT or mode == TransportMode.SMALL_AIRCRAFT then
				return "air"
			else 
				trace("unsupported transport type",mode)
			end
		end
	end
end
local function searchForDepotOfType(pos, depotType, range)
	if not depotType then
		trace("No depot type specified")
		return
	end
	if pos.x then
		pos = util.v3ToArr(pos)--needs to be an array
	end
	if not range then range = 200 end
	local circle = {radius=range, pos=pos}
	--debugPrint({searchCircle=circle})
	for i, constr in pairs(game.interface.getEntities(circle,{type="CONSTRUCTION", includeData=true})) do 
		if constr.depots[1] and string.find(constr.fileName, depotType) then
			return constr.id
		end
	end
end
function constructionUtil.searchForDepot(pos, transportModes, range)
	local depotType = getTypeFromMode(transportModes)
	return searchForDepotOfType(pos, depotType, range)
end

function constructionUtil.searchForRoadDepot(pos, range)
	return searchForDepotOfType(pos, "road", range)
end
function constructionUtil.searchForTramDepot(pos, range)
	return searchForDepotOfType(pos, "tram", range)
end
function constructionUtil.searchForShipDepot(pos, range)
	if not range then range = 500 end
	return searchForDepotOfType(pos, "ship", range)
end
function constructionUtil.searchForRailDepot(pos, arg2)
	local range = 200	
	local pos2 
	if arg2 then 
		if type(arg2)=="number" then 
			range = arg2
		else 
			pos2 = arg2
		end 
	
	end 
	
	local result =  searchForDepotOfType(pos, "train", range)
	if not result and pos2 then
		return searchForDepotOfType(pos2, "train", range)
	end
	return result
end

function constructionUtil.createTrainDepotConstructionAtEndOfEdge(town, edgeId, vectorToOtherTown, params)
	local nodeInfo = util.getDeadEndTangentAndDetailsForEdge(edgeId)
	local positionAndRotation = connectEval.getStationPositionAndRotation(town, nodeInfo, vectorToOtherTown, params)
	return constructionUtil.createRailDepotConstruction(positionAndRotation,  town, params)
end

local function findMatchingAvailableModel(models)
	for i, name in pairs(models) do
		-- api.res.modelRep.get(api.res.modelRep.find("station/bus/small_old.mdl"))
		local modelId = api.res.modelRep.find(name)
		local modelDetail = api.res.modelRep.get(modelId)
		--if tracelog then debugPrint({name=name,modelId=modelId,modelDetail=modelDetail}) end
		if util.filterYearFromAndTo(modelDetail.metadata.availability) then
			--trace("using model ",modelId," name=",name," for bus stop")
			return name
			
		end
	end
end

local function getBusStopModel() 
	local bustopmodels = {"station/bus/small_old.mdl","station/bus/small_mid.mdl","station/bus/small_new.mdl"}
	return findMatchingAvailableModel(bustopmodels)
end

local function getTruckStopModel()  
	return "station/road/small_cargo.mdl"
end

local function buildStop(edgeId, newProposal, modelType, param, name)
	if not name then name = "stop" end
	trace("begin building bus stop for edge",edgeId)
	local leftCopy = util.copyExistingEdge(edgeId)
	local nextEdgeId = -(1+#newProposal.streetProposal.edgesToAdd)
	local nextObjectId = -(1+#newProposal.streetProposal.edgeObjectsToAdd)
	leftCopy.entity = nextEdgeId
	local objects = util.deepClone(leftCopy.comp.objects)
	if #objects >= 2 then 
		trace("Unable to build stop for edgeId ",edgeId," already has two stops")
		return 
	end
	local left = #objects == 1
	if #objects == 1 then -- need to double check if this was user built the first might have been on the left
		left = objects[1][2] == api.type.enum.EdgeObjectType.STOP_RIGHT
		name = util.getComponent(objects[1][1], api.type.ComponentType.NAME).name
	end 
	table.insert(objects,  { nextObjectId, left and api.type.enum.EdgeObjectType.STOP_LEFT or api.type.enum.EdgeObjectType.STOP_RIGHT})
	leftCopy.comp.objects = objects -- for some reason have to reassign the table

	trace("about to set edges to remove on proposal at ",-nextEdgeId)
	newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
	trace("about to set edges to add on proposal")
	newProposal.streetProposal.edgesToAdd[-nextEdgeId]=leftCopy
	local newStop = api.type.SimpleStreetProposal.EdgeObject.new()
	newStop.left = left
	newStop.oneWay = false
	newStop.playerEntity = api.engine.util.getPlayer()
	newStop.edgeEntity = nextEdgeId
	newStop.name = name
	newStop.model = modelType 
	newStop.param = param
	newProposal.streetProposal.edgeObjectsToAdd[-nextObjectId]=newStop  
end

function constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
	 buildStop(edgeId, newProposal,getBusStopModel(), 0.5, name )
end

function constructionUtil.buildTruckStopOnProposal(edgeId, name, callback)
	local newProposal = api.type.SimpleProposal.new()
	buildStop(edgeId, newProposal,getTruckStopModel(), 0.5, name)
	util.clearCacheNode2SegMaps()
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), callback)
end

function constructionUtil.runConstructionTest()

end

function constructionUtil.buildLinkRoadForHarbourToIndustry(result, industry, index, stationPos, connectNode, industryEdge, newProposal, params, needsTranshipment, needsRoad, actualStationTangent)
	if industry.type == "TOWN" then 
		if needsTranshipment then 
			constructionUtil.buildCargoRoadStationForIndustry( result,industry, index, stationPos, newProposal, params)
		end
		trace("buildLinkRoadForHarbourToIndustry: industry",industry.id,"is actually a town, aborting")
		return newProposal
	end 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
	local stationConnectOffset = 35
	local midPoint = util.getEdgeMidPoint(industryEdge.id)
	
	local connectNode = util.getNodeClosestToPosition(stationPos, {industryEdge.node0, industryEdge.node1})
	local stationConnectNode = stationPos + stationConnectOffset*actualStationTangent
	local originalConnectNodePos = util.nodePos(connectNode)
	local connectVector = stationConnectNode-originalConnectNodePos
	local connectLength = vec3.length(connectVector)
	local needsAdditionalRoad = false
	local originalConnectNode = connectNode
	local needsSplit =  util.distance(midPoint, stationConnectNode) < util.distance(originalConnectNodePos, stationConnectNode)
	trace("Inspecing entity",industry.id," needsSplit?",needsSplit,"entity type was",industry.type)
	local splitEdge
	local function hasLinkedToConstruction(resultData)
		
		for i, link in pairs(resultData.tpNetLinkProposal.toAdd) do
			--debugPrint(link)
			if link.link.to.edgeId.entity == constructionId then
				return true
			end
		end
		return false
	end
	
	local function buildLinkRoad(newProposal)
		if true then 
			trace("Aborting buildLinkRoad")
			return
		end 
		local entity =  api.type.SegmentAndEntity.new()
		entity.entity = -1-#newProposal.streetProposal.edgesToAdd
		entity.type=0
		entity.comp.node0 = originalConnectNode
		entity.comp.node1 = newProposal.streetProposal.edgesToAdd[#newProposal.streetProposal.edgesToAdd].comp.node0
		local connectNodePos = type(connectNode) == "number" and util.nodePos(connectNode) or connectNode
		local tangent = connectNodePos - util.nodePos(originalConnectNode)
		if vec3.length(tangent) == 0 then 
			trace("WARNING! Build linkRoad got zero length tangent, aborting")
			return 
		end 
		local t0 = tangent 
		local t1 = tangent 
		for i, seg in pairs(util.getSegmentsForNode(originalConnectNode)) do 
			local otherEdge = util.getEdge(seg)
			local theyNode0 = otherEdge.node0 == originalConnectNode
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
		if #newProposal.streetProposal.edgesToAdd > 0 then 
			local lastEdge = newProposal.streetProposal.edgesToAdd[#newProposal.streetProposal.edgesToAdd ]
			if lastEdge.node0 == entity.comp.node1 then 
				local angle = util.signedAngle(lastEdge.comp.tangent0, t1)
				
				trace("Inspecting the angle to the new node, was",math.deg(angle))
				if math.abs(angle) < math.rad(10) then 
					trace("Shallow angle detected attempting to correct")
					local sign = angle > 0  and -1 or 1 
					t1 = util.rotateXYkeepingZ(t1, sign*math.rad(30))
					trace("After rotation the angle was",util.signedAngle(lastEdge.comp.tangent0, t1))
				end 
			end 
		end 
		
		util.setTangent(entity.comp.tangent0, t0)
		util.setTangent(entity.comp.tangent1, t1 )
		entity.streetEdge.streetType = util.smallCountryStreetType()
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
		trace("buildHarborForIndustry.buildLinkRoad: added entity",entity.entity,"linking",entity.comp.node0,entity.comp.node1)
	end
	trace("buildHarborForIndustry: Connect length for",industry.name," was ",connectLength,"needsRoad?",needsRoad,"needsTranshipment?",needsTranshipment)
	local isConnectRoadError = false 
	if needsRoad then 
		local testProposal = api.type.SimpleProposal.new()
		util.buildShortStubRoadWithPosition(testProposal, connectNode, stationConnectNode)
		local resultData = checkProposalForErrors(testProposal)
		isConnectRoadError = resultData.isError
	end 
	local excludePositions = {}
	local otherPos = util.getClosestTransportNetworkNodePosition(stationConnectNode, constructionId, excludePositions)
	otherPos = vec3.new(otherPos.x, otherPos.y, util.nodePos(originalConnectNode).z)
	local distance2 = vec2.distance(otherPos, stationConnectNode)
	if needsTranshipment and distance2 < 250 then 
		trace("Overriding the needsTranshipment to false for short distance")
		needsTranshipment = false 		
	end 
	if not needsTranshipment and distance2 > 400 then 
		trace("Overriding needsTranshipment to true")
		needsTranshipment = true 
		needsRoad = false
		isConnectRoadError = false 
	end 
	local hasLink = true 
	local streetType = util.smallCountryStreetType()
	if needsTranshipment then 
		constructionUtil.buildCargoRoadStationForIndustry( result,industry, index, stationPos, newProposal, params)
		
		
	elseif (connectLength > 230 or needsSplit) and needsRoad or isConnectRoadError then 
		local collision = false
		hasLink = false  
		
		local initialOffset = 4
		local offset = initialOffset
		connectNode = midPoint
		local hadLink
		local iterationCount= 0
	
		repeat
			if iterationCount == 51 then 
				excludePositions = {}
				offset = initialOffset
				streetType = util.mediumCountryStreetType()
				trace("Using medium street")
			end 			
			local dummyProposal = api.type.SimpleProposal.new()
			local connectNodePos = type(connectNode) == "number" and util.nodePos(connectNode) or connectNode
			if iterationCount == 0 and connectLength > 250 and connectLength > distance2 then
				trace("Overriding the connectNodePos to the otherPos",otherPos)
				connectVector = stationConnectNode-otherPos
				connectNode  = otherPos + offset*vec3.normalize(connectVector)	
				
				connectNodePos = connectNode  
				
			end
			local filterFn = function(edge) 
				return util.checkConnectionToIndustry(industry, edge)
			end 
			splitEdge = util.checkForEdgeNearPosition(connectNodePos, filterFn)
			if splitEdge then
				trace("spliting edge, ",splitEdge,"near",connectNodePos.x,connectNodePos.y)
				local edgeFull = util.getEdge(splitEdge)
				local vectorToIndustry = connectNodePos - stationPos
				local nodePos1 =util.nodePos(edgeFull.node1)
				local nodePos0 = util.nodePos(edgeFull.node0)
				local edgeVector = nodePos1 - nodePos0
				local angle = math.abs(util.signedAngle(vectorToIndustry, edgeVector))
				if angle > math.rad(90) then 
					angle = math.rad(180)-angle 
				end
				local minDist = math.min(util.distance(nodePos0, stationPos),math.min(util.distance(nodePos1,stationPos),util.distance(util.getEdgeMidPoint(splitEdge),stationPos)))
				trace("Inspecing the angle between edge ",edge," and station position, was",math.deg(angle),"The minDist was",minDist)
				if angle < math.rad(45) then
				
					splitEdge = false 
				 
					connectNode = util.distance(nodePos0, stationPos) < util.distance(nodePos1, stationPos) and edgeFull.node0 or edgeFull.node1
					trace("Shallow angle, cancelling edgeSplit using",connectNode)
				end  
				if minDist > 300 then 
					trace("Distance too high, aborting")
					splitEdge = false 
					otherPos = util.getClosestTransportNetworkNodePosition(stationConnectNode, constructionId, excludePositions)
					otherPos = vec3.new(otherPos.x, otherPos.y, util.nodePos(originalConnectNode).z)
					connectVector = stationConnectNode-otherPos
					connectNode  = otherPos + offset*vec3.normalize(connectVector)	
					trace("The new distance was ",vec2.distance(stationConnectNode, connectNode))
				end 
				
			end 
			if splitEdge then 
				
				util.splitRoadNearPointAndJoin(dummyProposal, splitEdge, connectNode, stationConnectNode)
				
			else 	
				util.buildShortStubRoadWithPosition(dummyProposal, connectNode, stationConnectNode, streetType)
			end
			
			if needsAdditionalRoad then
				buildLinkRoad(dummyProposal)
			end
			local errToUse = util.tracelog and constructionUtil.err or err 
			local resultData
			local wasCollission
			local isCriticalError
			 hasLink = false
			iterationCount = iterationCount + 1
			if not xpcall(function() 
				if util.tracelog then 
					debugPrint({dummyProposal=dummyProposal})
				end 
				dummyProposal = proposalUtil.attemptDeconfliction(dummyProposal)
			end, errToUse) then 
				trace("Error detected, continuing")
				wasCollission = true
				collision = true
				goto continue 
			end 
			resultData = api.engine.util.proposal.makeProposalData(dummyProposal, util.initContext())
			--debugPrint(proposalResult)
			
			wasCollission = util.contains(resultData.errorState.messages,"Collision")
			hasLink =  hasLinkedToConstruction(resultData)
			if hasLink or wasCollission then 	
				local connectNodePos = type(connectNode) == "number" and util.nodePos(connectNode) or connectNode
				local linkPos = util.getClosestTransportNetworkNodePosition(connectNodePos, constructionId, excludePositions)
				if linkPos then 
					local distance = vec2.distance(linkPos, stationConnectNode)
					
					trace("The linkPos was at a distance of ",distance,"distance2=",distance2,"at",industry.name)
					if distance > 280 or distance2 < distance and distance > 250 then 
						trace("Attempting another location as the distance was too high")
						hasLink = false
						otherPos = util.getClosestTransportNetworkNodePosition(stationConnectNode, constructionId, excludePositions)
						otherPos = vec3.new(otherPos.x, otherPos.y, util.nodePos(originalConnectNode).z)
						connectVector = stationConnectNode-otherPos
						connectNode  = otherPos + offset*vec3.normalize(connectVector)	
						trace("The new distance was ",vec2.distance(stationConnectNode, connectNode))
					end 
				else 
					hasLink = false
				end 
			end
			isCriticalError = resultData.errorState.critical
			trace("attempting to resolve collision, iteration:",iterationCount, " needsAdditionalRoad=",needsAdditionalRoad, " excludePositions=",#excludePositions, " was collision = ", wasCollission, "hasLink?",hasLink," isCriticalError=",isCriticalError,"at",industry.name,"offset=",offset)
			if not hasLink then 
				collision = true 
			end
			if hasLink and not isCriticalError then 
				hadLink = true
			else 
				hadLink = false
			end 
			if not hasLink and hadLink then 
				local otherPos = util.getClosestTransportNetworkNodePosition(stationConnectNode, constructionId, excludePositions)
				otherPos = vec3.new(otherPos.x, otherPos.y, util.nodePos(originalConnectNode).z)
				connectVector = stationConnectNode-otherPos
				connectNode  = otherPos + (offset-1)*vec3.normalize(connectVector)	 
				trace("Aborting as we are now unlinked to the construction")
				break
			end
			if wasCollission or isCriticalError then
				collision = true
				
				if offset >= 15 and not hasLink then 
					table.insert(excludePositions, otherPos)
					offset = initialOffset
					needsAdditionalRoad = false
				else 
					offset = offset + 1
				end
				local otherPos = util.getClosestTransportNetworkNodePosition(stationConnectNode, constructionId, excludePositions)
				otherPos = vec3.new(otherPos.x, otherPos.y, util.nodePos(originalConnectNode).z)
				connectVector = stationConnectNode-otherPos
				connectNode  = otherPos + offset*vec3.normalize(connectVector)	
			else 
				--if not hasLinkedToConstruction(proposalResult) then 
				--	table.insert(excludePositions, otherPos)
				--	offset = initialOffset
				--else

				--end
				if iterationCount > 2 and not hasLink then 
					if needsAdditionalRoad then
						table.insert(excludePositions, otherPos)
						offset = initialOffset
						needsAdditionalRoad = false
					else 
						needsAdditionalRoad = true
					end
				elseif  hasLink then
					trace("collision resolved with offset=",offset)
					collision = false
				
				end
			end
			::continue::
		until not collision or iterationCount > 100
	else 
		--[[local dummyProposal = api.type.SimpleProposal.new()
		util.buildShortStubRoadWithPosition(dummyProposal, connectNode, stationConnectNode)
		if not hasLinkedToConstruction(dummyProposal) then
			trace("Not linked to construction trying to attach to middle")
			util.splitRoadAtPoint(newProposal, industryEdge.id, midPoint)
			connectNode = midPoint
		end]]--
	end
	
	if not needsTranshipment then 
		if splitEdge then
			trace("buildHarborForIndustry: splitting edge",industry.name,"splitEdge=",splitEdge,"connectNode=",connectNode)
			util.splitRoadNearPointAndJoin(newProposal, splitEdge, connectNode, stationConnectNode)
		elseif needsRoad then 
			trace("buildHarborForIndustry: building short stub road",industry.name)
			util.buildShortStubRoadWithPosition(newProposal, connectNode, stationConnectNode,streetType)
		end
		local perpTangent = vec3.normalize(util.rotateXY(actualStationTangent, math.rad(90)))
		
		local harbourExitRoad1 = stationConnectNode + 20*perpTangent
		local harbourExitRoad2 = stationConnectNode - 20*perpTangent
		if needsRoad then 
			local lastEntity = newProposal.streetProposal.edgesToAdd[#newProposal.streetProposal.edgesToAdd]
			local angleToPerp = math.abs(util.signedAngle(lastEntity.comp.tangent1, perpTangent))
			if angleToPerp > math.rad(90) then 
				angleToPerp = math.rad(180)-angleToPerp
			end 
			trace("Building link road for cargo, angleToPerp was",math.deg(angleToPerp))
			if angleToPerp > math.rad(20) then 
				local stationNodeEntity = newProposal.streetProposal.nodesToAdd[#newProposal.streetProposal.nodesToAdd].entity 
				util.buildShortStubRoadWithPosition(newProposal, stationNodeEntity, harbourExitRoad1)
				util.buildShortStubRoadWithPosition(newProposal, stationNodeEntity, harbourExitRoad2)
			end
		end 
		if needsAdditionalRoad then
			trace("buildHarborForIndustry: needsAdditionalRoad, building link road",industry.name)
			buildLinkRoad(newProposal)
		end
	end
	return proposalUtil.attemptDeconfliction(newProposal), hasLink
end

function constructionUtil.createHarborConstruction(newProposal, industry, waterVerticies, includeRoadStation, indexes, isCargo, result, industryEdge)
	if not indexes then indexes = {} end
	util.lazyCacheNode2SegMaps()
	local params = { isCargo = isCargo, isForTownTranshipment=isCargo }
	local stationPos
	local actualStationTangent
	local needsRoad
	local newConstruction 
	local depotConstruction
	local roadStationConstruction
	local roadDepotConstruction
	local otherRoadStation
	local existingBusStation = not isCargo and util.findBusStationForTown(industry.id)
	trace("ExistingBusStation?",existingBusStation)
	local existingBusStationPos 
	local includeRoadDepot = includeRoadStation and not constructionUtil.searchForRoadDepot(industry.position, 750)
	local includeTramDepot = includeRoadStation and not includeRoadDepot and existingBusStation
	local stationTangent = vec3.new(0,1,0)
	local industryOrTownPos = util.v3fromArr(industry.position)
	local stationCount = util.countRoadStationsForTown(industry.id)
	local constructionResult
	local isError
	local isErrorForHarbour
	local backupOptions = {}
	local maxAtttempts = 500
	if not industryEdge and isCargo then 
		local isIndustry1 = industry.id == result.industry1.id 
		industryEdge = isIndustry1 and result.edge1 or result.edge2 
		trace("Did not initially find industry edge, attetmpting to find, got",industryEdge)
	end 
	trace("about to begin loop over water vertices")
	trace("the mnumber of water verticies was ",#waterVerticies)
	local lastAttempt = math.min(maxAtttempts,#waterVerticies)
	trace("The last attempt was ",lastAttempt)
	local startTime = os.clock()
	for i = 1, #waterVerticies do 
		local elapsed = os.clock() - startTime 
		trace("attempt ",i," of ",#waterVerticies," to place harbour at ",industry.name,"elapsed=",elapsed)
		if elapsed > 120 then 
			trace("WARNING, already spent 2 minutes attempting to place, aborting")
			break
		end 
		local position = vec3.new(waterVerticies[i].p.x, waterVerticies[i].p.y, util.getWaterLevel()+2)-- N.B.  the game end up building docks at 2m, so add 2
		local meshId = waterVerticies[i].mesh
		local waterMeshGroup = waterMeshUtil.getWaterMeshGroups()[meshId]
		result.selectedGroup = waterMeshGroup
		--local stationWaterOffset = 25
		--local stationWaterOffset = 30
		local stationWaterOffset = 28
		local industryVector = position - industryOrTownPos
		
		local industryDistance = vec3.length(industryVector)
		--debugPrint(waterVerticies)
		
		local industryRelativeRotation = util.signedAngle(stationTangent, industryVector)
		--local signedVertexAngle3 = util.signedAngle(stationTangent, vec3.new(waterVerticies[i].t.x, waterVerticies[i].t.y,0))
		local signedVertexAngle3 = util.signedAngle(stationTangent, waterVerticies[i].t)
		--local rotation = math.rad(90)+signedVertexAngle3
		local rotation =  signedVertexAngle3
		if math.abs(industryRelativeRotation-rotation) > math.rad(90) then
			--trace("flipping harbour rotation")
			--rotation = rotation + math.rad(180)
		end
		actualStationTangent = util.rotateXY(stationTangent, rotation)
		
		local stationConnectOffset = 35
		--local stationPos = position - stationWaterOffset*vec3.normalize(industryVector)
		--local stationConnectNode = stationPos - stationConnectOffset*vec3.normalize(industryVector)
		stationPos = position + stationWaterOffset*actualStationTangent
		local includeShipYard = not constructionUtil.searchForShipDepot(stationPos, 1000)
		local thisIncludeRoadStation = includeRoadStation
		for i, otherStation in pairs(util.searchForEntities(stationPos, 150, "STATION")) do 
			local stationConstr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(otherStation.id)
			if otherStation.cargo == isCargo and stationConstr ~= -1 and otherStation.carriers.ROAD then 
 				thisIncludeRoadStation = false 
				otherRoadStation = stationConstr
				break 
			end
		end
		
		needsRoad = not thisIncludeRoadStation
		for extraOffset = 0, 100,5 do
			
			stationPos = position + (-extraOffset+stationWaterOffset)*actualStationTangent
			trace("Attempting to place at position",stationPos.x,stationPos.y,"extraOffset=",extraOffset)
			for __, edge in pairs(util.searchForEntities(stationPos, 50, "BASE_EDGE")) do
				local midDist = util.distance(stationPos, util.getEdgeMidPoint(edge.id))
				local node0Dist = util.distance(stationPos,util.nodePos(edge.node0))
				local node1Dist = util.distance(stationPos,util.nodePos(edge.node1))
				local minDist = math.min(midDist, math.min(node0Dist, node1Dist))
				if not edge.track then 
					minDist = minDist - util.getStreetWidth(edge.streetType)/2
					if minDist < stationConnectOffset then
						local adjustment = minDist-stationConnectOffset  
						trace("found collision edge near by, adjusting position by",adjustment)
						stationPos = stationPos + adjustment*actualStationTangent
						needsRoad=false
						break
					end
				end
			end
		
			local baseParams={  
					  paramX = 0,
					  paramY = 0,
					  seed = 0,
					  templateIndex = isCargo and 1 or 0, --0 passenger, 1 cargo
					  size = paramHelper.isBuildBigHarbour(isCargo) and 1 or 0, -- 0 small, 1 big
					  terminals = 0, -- conversion is math.pow(2, params.terminals)
					  year = util.year(),
			}
			if not isCargo and stationCount >= 2 then 
				baseParams.includeSecondPassengerEntrance = true
			end 
			local modulebasics = helper.createHarbourTemplateFn(baseParams)
			baseParams.modules = util.setupModuleDetailsForTemplate(modulebasics)
			newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
			--debugPrint({town=town, positionAndRotation=positionAndRotation})
			newConstruction.name=industry.name.." ".._("Harbour")
			local station = "station/water/harbor_modular.con"
			 
			newConstruction.fileName = station
			newConstruction.playerEntity = api.engine.util.getPlayer()
		 
			newConstruction.params = baseParams
			local stationtransf = rotZTransl(rotation, stationPos) 
			newConstruction.transf = util.transf2Mat4f(stationtransf)
			
		

			if thisIncludeRoadStation then 
				local platR = isCargo and 1 or 2 
				local platL =1 
				local offset = isCargo and 55 or 58
				
				--offset = offset + 1
				
				local namePrefix = _("Port")
				local hasEntranceB = true 
				local busStationRotation = rotation -math.rad(90)
				if not isCargo  then 
					
					trace("The stationCount for ",industry.name," was ",stationCount) 
					if stationCount >= 2 then 
						platL = 0 
						offset = offset + 8 -- tram depot is longer, needed along with second pedestrian entrance
						--params.includeLargeBuilding = true 
						--busStationRotation = busStationRotation + math.rad(180)
					elseif stationCount == 1 then 
						platR = platR + 1 
						offset = offset + 8
					end 
				else 
					params.includeSmallBuilding = true 
				end 
				local busStationPos = stationPos + offset*actualStationTangent
				roadStationConstruction = constructionUtil.createRoadStationConstruction(busStationPos, busStationRotation, params, industry, hasEntranceB, platL,platR, namePrefix)
				local perpTangent = util.rotateXY(actualStationTangent, math.rad(90))
				--local depotPos = stationPos+65*perpTangent + 25*actualStationTangent
				--local depotPos = busStationPos+45*perpTangent - 49*actualStationTangent
				local depotOffset =   -50
				local depotPos = busStationPos+45*perpTangent + depotOffset*actualStationTangent
				local depotPos2 = busStationPos-45*perpTangent + depotOffset*actualStationTangent
				
				if util.distance(industryOrTownPos, depotPos) < util.distance(industryOrTownPos, depotPos2) then 
					depotPos = depotPos2 -- keep the depot on the other side in case we need to build a route
				end 
				if includeRoadDepot  then 
					roadDepotConstruction=constructionUtil.createRoadDepotConstruction(industry, depotPos, rotation+math.rad(180))
				elseif includeTramDepot then 
					roadDepotConstruction=constructionUtil.createTramDepotConstruction(industry, depotPos, rotation+math.rad(180))
				end			
			end
			trace("Checking harbour for collision without shipyard, rotation=",math.deg(rotation), " pos=",stationPos.x, stationPos.y)
			constructionResult = checkConstructionForCollision(newConstruction, roadStationConstruction, roadDepotConstruction)
			if thisIncludeRoadStation and constructionResult.isError and (includeRoadDepot or includeTramDepot) then
				constructionResult = checkConstructionForCollision(newConstruction, roadStationConstruction)
				trace("Checking harbour construction without road depot, is still error?",constructionResult.isError)
				if not constructionResult.isError then 
					roadDepotConstruction = nil 
					--includeRoadDepot = false 
					--includeTramDepot = false
					trace("Excluding the road/tram depot")
				end 
			end 
			
			if isCargo and not thisIncludeRoadStation then
			
				local isIndustry1 = industry.id == result.industry1.id 
				local industryEdge = isIndustry1 and result.edge1 or result.edge2 
				trace("Checking if really needs road, industryEdge=",industryEdge)
				local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
				local position = util.getConstructionPosition(constructionId)
				local connectNode = util.getNodeClosestToPosition(stationPos, {industryEdge.node0, industryEdge.node1})
				needsRoad = true 
				for i, tpLink in pairs(constructionResult.tpLinks) do 
					trace("Inspecting tpLink",tpLink)
					if tpLink < 0 then 
						goto continue 
					end
					if tpLink == constructionId then 
						needsRoad = false 
						trace("Direct link to industry detected")
						break 
					end 
					if tpLink == industryEdge.id or tpLink==industryEdge.node0 or tpLink==industryEdge.node1 then 
						needsRoad = false 
						trace("Direct link to industry edge detected")
						break 
					end 
					local tpNode = tpLink
					local tpEdge = util.getEdge(tpLink)
					if tpEdge then 
						if util.distance(position, util.nodePos(tpEdge.node0))<util.distance(position, util.nodePos(tpEdge.node1)) then
							tpNode = tpEdge.node0
						else 
							tpNode = tpEdge.node1 
						end 
					end 
					if not util.getConstruction(tpLink) and #pathFindingUtil.findRoadPathBetweenNodes(tpNode, connectNode, 300)>0 then 
						needsRoad = false 
						trace("Connected to another road with intermediate connection")
						break 
					end 
					::continue::
				end 
			end 
			isError = constructionResult.isError
			if isError and util.contains(constructionResult.errorState.messages,"Docks outside of navigable waters") then 
				trace("Docks outside of navigable waters detected at extraoffset",extraOffset,"aborting")
				break
			end 
			local wasError = isError 
			if needsRoad and not isError and isCargo then 
				local testProposal = api.type.SimpleProposal.new()
				local hasLink
				testProposal, hasLink = constructionUtil.buildLinkRoadForHarbourToIndustry(result, industry, index, stationPos, connectNode, industryEdge, testProposal, params, needsTranshipment, needsRoad, actualStationTangent)
				isError = not hasLink or checkProposalForErrors(testProposal).isError 
				trace("Checking the result of building the test proposal, is error was",isError)
			end
			if not isError then 
				break 
			end
			if isError and not wasError then 
				table.insert(backupOptions, {
					newConstruction = newConstruction, 
					depotConstruction = depotConstruction,
					roadStationConstruction = roadStationConstruction,
					roadDepotConstruction = roadDepotConstruction,
					stationPos = stationPos,
					actualStationTangent = actualStationTangent,
					needsRoad = false ,
					otherRoadStation= otherRoadStation,
					scores = {
						constructionResult.costs ,
						i -- sorted in original score
				}
			})
			end 
		end 
		--local meshGroups = pathFindingUtil.getWaterMeshGroups() 
		local function filterFn(vertex) 
			return vertex.mesh ~= meshId -- put the depot on a different vertex 
				--and meshGroups[vertex.mesh]==waterMeshGroup -- but still in the same group (i.e. it is connected)
		end
		--local range = 1000 
		---local minDist = 120 
		--local depotVerticies =util.getClosestWaterVerticies(stationPos, range, minDist, filterFn)
		local depotVerticies = util.copyTableWithFilter(waterVerticies, filterFn)
		if not depotVerticies or #depotVerticies == 0 then 
			includeShipYard = false 
		end 
		isErrorForHarbour = isError
		if includeShipYard and (not isError or i == lastAttempt) then 
			local wasOriginalError = isError 
			local originalErrorMessages = #constructionResult.errorState.messages 
			local originalCollisionCount = #constructionResult.collisionEntities
			depotConstruction = api.type.SimpleProposal.ConstructionEntity.new() 
			local depotParams={  
				  paramX = 0,
				  paramY = 0,
				  seed = 0,
				  year = util.year(),
			}
			depotConstruction.params = depotParams
			depotConstruction.name=industry.name.." ".._("Shipyard")
			depotConstruction.fileName = "depot/shipyard_era_a.con"
			depotConstruction.playerEntity = api.engine.util.getPlayer()
			local count = 0
			local function shouldBreak()
				if count > #depotVerticies then 
					trace("Aborting should break as count reached",count)
					return true 
				end
				if wasOriginalError then 
					return #constructionResult.errorState.messages == originalErrorMessages and #constructionResult.collisionEntities == originalCollisionCount
				else 
					return not isError 
				end 
			end 
			
			
			
			-- NB it seems the check proposal does not detect collision between the depot and harbour 
		
		 
		
			local nextIndex = i
			
			local depotOffset = 35
			repeat
			
				if nextIndex >= #depotVerticies then 
					nextIndex = 0 
				end
				count = count +1
				trace("Checking shipyard construction attempt number ",count,"nextIndex=",nextIndex,"of",#depotVerticies)
				trace("depotVerticies[nextIndex+1]=",depotVerticies[nextIndex+1])
				trace("depotVerticies[nextIndex+1].p=",depotVerticies[nextIndex+1].p)
				local depotPos = vec3.new(depotVerticies[nextIndex+1].p.x, depotVerticies[nextIndex+1].p.y, 2)--we know this is a water mesh point
				local depotRot= util.signedAngle(stationTangent, vec3.new(depotVerticies[nextIndex+1].t.x, depotVerticies[nextIndex+1].t.y,0))
				local mesh =  util.getComponent(depotVerticies[nextIndex+1].mesh, api.type.ComponentType.WATER_MESH)
				local contour = mesh.contours[depotVerticies[nextIndex+1].contour]
				if util.distance(depotPos, stationPos) > 120 then
					depotConstruction.transf = util.transf2Mat4f(rotZTransl(depotRot,depotPos ))
					trace("Checking harbour for collision with shipyard, depotRot=",math.deg(depotRot),"depotPos=",depotPos.x,depotPos.y)
					constructionResult = checkConstructionForCollision(newConstruction, depotConstruction, roadStationConstruction, roadDepotConstruction)
					isError = constructionResult.isError
				end
				local nextVertex = 1
				while not shouldBreak() do 
					
					trace("Harbour depot collision detected, attempting to correct ", nextVertex, nextIndex)
					if nextVertex <=#contour.vertices  then  
						local p = contour.vertices[nextVertex]
						local t = contour.normals[nextVertex]
						count = count +1
						for depotOffset = -40, 40, 5 do 
							depotPos = vec3.new(p.x, p.y, 2)+ depotOffset*vec3.normalize(vec3.new(t.x, t.y,0))
							depotRot= util.signedAngle(stationTangent, vec3.new(t.x, t.y,0))
							if util.distance(depotPos, stationPos) > 120 then
								depotConstruction.transf = util.transf2Mat4f(rotZTransl(depotRot,depotPos ))
								
								constructionResult = checkConstructionForCollision(newConstruction, depotConstruction, roadStationConstruction, roadDepotConstruction)
								isError = constructionResult.isError
								trace("Checking harbour for collision with shipyard2, depotRot=",math.deg(depotRot),"depotPos=",depotPos.x,depotPos.y, " depotOffset=",depotOffset,"isError?",isError)
								
							end
							if shouldBreak() then 
								break 
							end
						end
						nextVertex= nextVertex +1
						
					else
						nextVertex = 1
						nextIndex = nextIndex + 1
						break
					end
				end			
			until shouldBreak() or count >= lastAttempt
			if isError and not wasOriginalError then 
				trace("Aborting construction of shipyard as it overrides the original error")
				isError = false 
				depotConstruction =nil
			end 
		else 
			trace("Collision detected between harbour, road station and road depot")
		end
		if depotConstruction then 
			if  util.isTransfUnset(depotConstruction.transf) then 
				isError = true 
			else 
				constructionResult = checkConstructionForCollision(newConstruction, depotConstruction, roadStationConstruction, roadDepotConstruction)
				isError = constructionResult.isError
				if not isError then
					break
				end 
			end
		elseif not includeShipYard and not isError then 
			break 
		end
		--[[if constructionResult.isError and not constructionResult.isCriticalError then 
			table.insert(backupOptions, {
				newConstruction = newConstruction, 
				depotConstruction = depotConstruction,
				roadStationConstruction = roadStationConstruction,
				roadDepotConstruction = roadDepotConstruction,
				stationPos = stationPos,
				actualStationTangent = actualStationTangent,
				needsRoad = needsRoad,
				otherRoadStation= otherRoadStation,
				scores = {
					constructionResult.costs,
					#constructionResult.collisionEntities,
					#constructionResult.errorState.messages,
					i -- sorted in original score
				}
			})
		
		end ]]--
		
		if i > maxAtttempts then 
			trace("Still not found after ",maxAtttempts,"  exiting")
			break 
		end 
	end
	

	
	if isError and true then 
		if  #backupOptions > 0 then 
			trace("No result without error found attempting to use backup")
			local best = util.evaluateWinnerFromScores(backupOptions)
			if util.tracelog then debugPrint(best) end
			newConstruction = best.newConstruction
			depotConstruction = best.depotConstruction
			roadStationConstruction = best.roadStationConstruction
			roadDepotConstruction = best.roadDepotConstruction
			stationPos = best.stationPos
			actualStationTangent = best.actualStationTangent
			needsRoad = best.needsRoad
			otherRoadStation= best.therRoadStation
			isErrorForHarbour = false
		else 
			trace("Unable to build anything")
			if includeRoadStation then 
				trace("Attempting to build without road station")
				includeRoadStation = false 
				return constructionUtil.createHarborConstruction(newProposal, industry, waterVerticies, includeRoadStation, indexes, isCargo, result)
			end 
		end 
	end 
	if isErrorForHarbour then 
		error("Unable to build harbor at"..industry.name)-- need to prevent invalid builds 
	end 
	newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=newConstruction
	indexes.harbourIdx = #newProposal.constructionsToAdd
	if depotConstruction and not util.isTransfUnset(depotConstruction.transf) then 
		newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=depotConstruction
		indexes.shipyardIdx = #newProposal.constructionsToAdd
	end
	if roadStationConstruction then 
		newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=roadStationConstruction
		indexes.harbourRoadStationIdx = #newProposal.constructionsToAdd
	end
	if roadDepotConstruction then 
		newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=roadDepotConstruction
		indexes.harbourRoadDepotIdx = #newProposal.constructionsToAdd
	end
	
	return stationPos, actualStationTangent, needsRoad, otherRoadStation
end
function constructionUtil.upgradeToLargeHarbor(station)
	if not util.isSafeToUpgradeToLargeHarbour(station) then 
		trace("WARNING! Not safe to upgrade to large harbour, aborting")
		return
	end 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local params = util.deepClone(construction.params)
	local needsLarge =  params.size == 0
	local isCargo = util.getStation(station).cargo
	if  needsLarge then  
		params.size = 1 	
		params.templateIndex = isCargo and 1 or 0
		trace("Anout to get construction for station ", station, " constructionId = ",constructionId)
		params.modules =  util.setupModuleDetailsForTemplate(helper.createHarbourTemplateFn(params))   
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		params.seed = nil
		xpcall(function() game.interface.upgradeConstruction(constructionId, construction.fileName, params)end, constructionUtil.err)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())		 
	end
end 

function constructionUtil.buildRoadStationForHarbour(construction, result, newProposal, isCargo, station, index)
	local hasEntranceB = true
	if result.constructionIdxs[index].harbourRoadStationIdx then 
		trace("WARNING! Already built a road station construction at this location")
		trace(debug.traceback())
		return
	end 
	local params = {isCargo=isCargo, isForTownTranshipment=false}
	local stationName =util.getComponent(station, api.type.ComponentType.NAME).name
	local naming = {name=stationName.." ".._("Road Station")}
	local length = 2
	local stationPerpTangent = util.v3(construction.transf:cols(0))
	local stationParallelTangent = util.v3(construction.transf:cols(1))
	local stationPos = util.v3(construction.transf:cols(3))
	local connectNode
	local foundLocation = false
	local harborConstructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	for i = -50, 50, 5 do 
		local hasEntranceB = false
		--local parallelOffset = 50
		local startAt = 50
		local endAt = 70
		local increment = 4
		if math.abs(i)==50 then 
			startAt = 0
			endAt = 45
		end 
		for parallelOffset = startAt, endAt, increment do 
			local roadStationPos = stationPos + parallelOffset * stationParallelTangent + i*stationPerpTangent
			local angle = util.signedAngle(stationParallelTangent, vec3.new(0, -1, 0))
			
			local testProposal = api.type.SimpleProposal.new()
			copyStreetProposal(newProposal, testProposal)
			constructionUtil.buildRoadStation(testProposal, roadStationPos, -angle,params, naming, hasEntranceB, 1, 1,"",length)
			local testResult = checkProposalForErrors(testProposal)
			trace("Attempting to build road station at ",roadStationPos.x, roadStationPos.y," angle was",math.deg(angle), " isError?",testResult.isError,"parallelOffset=",parallelOffset,"perpOffset=",perpOffset)
			local tpLinks = testResult.tpLinks
			testResult.isConnected = false 
			for i, tpLink in pairs(testResult.tpLinks) do 
				trace("Inspecting tpLink",tpLink)
				 
				if tpLink == harborConstructionId then
					testResult.isConnected = true
				end 
			end 
			if not testResult.isError and testResult.isConnected then 
				constructionUtil.buildRoadStation(newProposal, roadStationPos, -angle, params, naming, hasEntranceB, 1, 1,"",length)
				result.constructionIdxs[index].harbourRoadStationIdx = #newProposal.constructionsToAdd 
			--[[	local expectedConnectNodePos = roadStationPos+50*stationParallelTangent
				connectNode = util.searchForNearestNode(expectedConnectNodePos)
				trace("Search for connectNode at ",expectedConnectNodePos.x,expectedConnectNodePos.y," result?",connectNode)]]--
				foundLocation = true
				break 
			end
		end
		if foundLocation then 
			break 
		end
	end
	if not foundLocation then 
		local nearbyIndustry = util.searchForFirstEntity(stationPos, 250, "SIM_BUILDING")
		if nearbyIndustry then 
			trace("No suitable location found, attempting to get from nearby industry")
			local p0 = stationPos
			local p1 = index == 1 and util.v3fromArr(result.industry1.position) or util.v3fromArr(result.industry2.position)
			local details = connectEval.getTruckStationToBuild(nearbyIndustry, result.cargoType, 1, p0, p1)
		
			local result = constructionUtil.buildTruckStationForIndustry(newProposal,details, result,params )
			if result and result.connectNode then 
				if not result.constructionIdxs then 
					result.constructionIdxs = {}
				end 
				if not result.constructionIdxs[index] then 
					result.constructionIdxs[index] = {}
				end 
				result.constructionIdxs[index].harbourConnectNode = result.connectNode 
			end 
		else 
			error("No suitable location was found near "..stationName.." id="..tostring(station))
		end
	end 
	
	--[[if connectNode then 
		result.constructionIdxs[index].harbourConnectNode = connectNode.id 
	end]]--
end 

function constructionUtil.checkHarborForUpgrade(station, needsTranshipment, result, index, newProposal)
	util.lazyCacheNode2SegMaps()
	if not station then 
		trace("WARNING! No station specified")
		trace(debug.traceback())
		return 
	end
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local params = util.deepClone(construction.params)
	local stationPos = util.getStationPosition(station)
	local isCargo = util.getStation(station).cargo --params.templateIndex == 1
	local needsLarge = paramHelper.isBuildBigHarbour(isCargo) and params.size == 0
	local needsTerminal = util.countFreeTerminalsForStation(station) == 0 
	if needsTerminal or needsLarge then 
		
		if needsTerminal then 
			params.terminals = params.terminals + 1 
		end
		if needsLarge then 
			params.size = 1
		end
		params.templateIndex = isCargo and 1 or 0
		trace("Anout to get construction for station ", station, " constructionId = ",constructionId)
	
		params.modules =  util.setupModuleDetailsForTemplate(helper.createHarbourTemplateFn(params))   
	 
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		params.seed = nil
		pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params)end)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())		 
	end
	trace("About to check needs transhipment road station, needsTranshipment?",needsTranshipment)
	if needsTranshipment then 
		result.needsNewRoute = true
		local industry = index == 1 and result.industry1 or result.industry2 	
		if not result.constructionIdxs then 	
			result.constructionIdxs = {} 
		end 
		if not result.constructionIdxs[index] then 
			result.constructionIdxs[index] = {}
		end 
		local needsDepot = false 
		if not constructionUtil.searchForNearestCargoRoadStation(stationPos, 250) then 
			constructionUtil.buildRoadStationForHarbour(construction, result, newProposal, isCargo, station, index)
			needsDepot = true
		end
		if industry.type~="TOWN" and not constructionUtil.searchForNearestCargoRoadStation(util.v3fromArr(industry.position), 350) then 
			trace("Building cargo road station")
			constructionUtil.buildCargoRoadStationForIndustry(result,industry, index, util.getStationPosition(station), newProposal, {isCargo=isCargo, isForTownTranshipment=false})
				
			if needsDepot then 
				local edge = index == 1 and result.edge1 or result.edge2
				constructionUtil.buildRoadDepotForSingleIndustry(newProposal, industry, edge, result, newProposal.constructionsToAdd[#newProposal.constructionsToAdd])
				result.constructionIdxs[index].roadDepotIdx = #newProposal.constructionsToAdd
				 
			end 
		elseif industry.type~="TOWN" then 
			if not result.existingRoadStations then 
				result.existingRoadStations = {} 
			end 
			local existingStation = constructionUtil.searchForNearestCargoRoadStation(util.v3fromArr(industry.position), 350) 
			constructionUtil.checkRoadStationForUpgrade(newProposal, existingStation, industry, result)
			result.existingRoadStations[index]=api.engine.system.streetConnectorSystem.getConstructionEntityForStation(existingStation)
		else 
			local edge = connectEval.findCargoEdgeForTown(industry, result.cargoType)
		 
			local node0 = edge.node0
			local node1 = edge.node1
			local cargoName = api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(result.cargoType)).name
			constructionUtil.buildTruckStopOnProposal(edge.id, industry.name.." "..cargoName.." ".._("Delivery"), function(res, success) 
				trace("Result of building truck stop was",success)
				util.clearCacheNode2SegMaps()
				result.truckStop = util.findStopBetweenNodes(node0, node1)
				trace("Found truckStop = ",result.truckStop)
			end )
		end 
	
	end 
end


function constructionUtil.buildHarborForTown(newProposal, town, otherTown, result)
	--local waterVerticies =  connectEval.getAppropriateWaterVerticiesForResult(town, otherTown, result)
	local waterVerticies = result.town1 == town and result.verticies1 or result.verticies2
	
	if #waterVerticies == 0 then 
		trace("WARNING! No water verticies found for ",town.name," to ",otherTown.name)
		return false 
	end
	profiler.beginFunction("buildHarborForTown")
	local index = town.id == result.town1.id and 1 or 2 
	if not result.constructionIdxs then 
		result.constructionIdxs = {}
	end 
	 
	result.constructionIdxs[index]={}
	local stationPos, actualStationTangent, needsRoad, otherRoadStation = constructionUtil.createHarborConstruction(newProposal, town, waterVerticies, true, result.constructionIdxs[index],false, result)
	if needsRoad then 
		local nodes = util.getFreeNodesForConstruction(otherRoadStation) 
		local node = util.evaluateWinnerFromSingleScore(nodes, function(node) return util.distance(util.nodePos(node), stationPos) end)
		local segs = util.getStreetSegmentsForNode(node)
		local stationEdgeId = util.isFrozenEdge(segs[1]) and segs[1] or segs[2]
		local stationEdge = util.getEdge(stationEdgeId)
		local tangent = vec3.normalize(util.v3(stationEdge.tangent1))
		local nodePos = util.nodePos(node)
		local naturalTangent = stationPos - nodePos
		local angle = util.signedAngle(tangent, naturalTangent)
		trace("The harbor needs road. The signed angle of the outbound tangent was ",math.deg(angle))
		if math.abs(angle) > math.rad(90) then 
			tangent = util.rotateXY(tangent, math.rad(90))
			local testP = nodePos + 10*tangent 
			if util.distance(testP, stationPos) > util.distance(nodePos, stationPos) then 
				trace("Inverting tangent") 
				tangent = -1 * tangent
			end
		end
		local stationConnectNodePos = stationPos + 35*actualStationTangent
		local newNode =util.newNodeWithPosition(stationConnectNodePos, -100*#newProposal.streetProposal.edgesToAdd-1000*#newProposal.streetProposal.nodesToAdd)
		
		
		local entity =  initNewEntity(newProposal)  
		entity.comp.node0 = node
		entity.comp.node1 = newNode.entity 
		util.setTangent(entity.comp.tangent0, vec3.length(naturalTangent)*tangent)
		util.setTangent(entity.comp.tangent1, naturalTangent)
	
		newProposal.streetProposal.nodesToAdd[#newProposal.streetProposal.nodesToAdd+1]=newNode
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
	end
	profiler.endFunction("buildHarborForTown")
	return true 
end
function constructionUtil.buildCargoRoadStationForIndustry(result, industry, index, stationPos, newProposal, params)
	if not params then 
		params = {isCargo=true} 
	end
	if industry.type=="TOWN" then 
		local edge = connectEval.findCargoEdgeForTown(industry, result.cargoType)
		 
		local node0 = edge.node0
		local node1 = edge.node1
		local cargoName = api.res.cargoTypeRep.get(api.res.cargoTypeRep.find(result.cargoType)).name
		constructionUtil.buildTruckStopOnProposal(edge.id, industry.name.." "..cargoName.." ".._("Delivery"), function(res, success) 
			result.truckStop = util.findStopBetweenNodes(node0, node1)
		end )
	else 
		local details = connectEval.getTruckStationToBuild(industry, result.cargoType, index, util.v3fromArr(industry.position), stationPos)
		local existingStation =  connectEval.checkForAppropriateCargoStation(industry, api.type.enum.Carrier.ROAD)
		if not existingStation then 
			if not result.constructionIdxs then 
				result.constructionIdxs = {}
			end 
			if not result.constructionIdxs[index] then 
				result.constructionIdxs[index]={}
			end
			 
			local buildResult = constructionUtil.buildTruckStationForIndustry(newProposal,details, result, params, false,stationPos)
			result.constructionIdxs[index].roadStationIdx = #newProposal.constructionsToAdd
			result.constructionIdxs[index].connectNode = buildResult.connectNode
		else 
			if not result.existingRoadStations then 
				result.existingRoadStations = {} 
			end 
			constructionUtil.checkRoadStationForUpgrade(newProposal, existingStation, industry, result)
			result.existingRoadStations[index]=api.engine.system.streetConnectorSystem.getConstructionEntityForStation(existingStation)
		end	
	end
end
function constructionUtil.buildHarborForIndustry(newProposal, industry, industryEdge, waterVerticies, needsTranshipment, result, index)
	-- FIX: Auto-calculate index if not provided (was causing nil index error)
	if not index then
		index = (result.industry1 and industry.id == result.industry1.id) and 1 or 2
		trace("buildHarborForIndustry: auto-calculated index=", index, " for industry=", industry.name)
	end
	trace("buildHarborForIndustry: BEGIN industry=", industry.name, " id=", industry.id, " index=", index, " needsTranshipment=", needsTranshipment)
	profiler.beginFunction("buildHarborForIndustry")
	if not result.constructionIdxs then 
		result.constructionIdxs = {}
	end 
	local params = {isCargo = true, isForTownTranshipment=false}--industry params
	result.constructionIdxs[index]={}
	local stationPos, actualStationTangent, needsRoad, otherRoadStation = constructionUtil.createHarborConstruction(newProposal, industry, waterVerticies,needsTranshipment,result.constructionIdxs[index], true, result, industryEdge)

	newProposal = constructionUtil.buildLinkRoadForHarbourToIndustry(result, industry, index, stationPos, connectNode, industryEdge, newProposal, params, needsTranshipment, needsRoad, actualStationTangent)
	profiler.endFunction("buildHarborForIndustry")
	trace("buildHarborForIndustry: END industry=", industry.name, " stationPos=", stationPos and stationPos.x or "nil", stationPos and stationPos.y or "nil")
	return proposalUtil.attemptDeconfliction(newProposal)
	--trace("attempting to build harbour at ",position.x, position.y," rotation=",math.deg(rotation), "other vertex point at ",waterVerticies[2].x, waterVerticies[2].y, " signedVertexAngle3=",math.deg(signedVertexAngle3), "connectVectorDist=",connectLength, " industryRelativeRotation=",math.deg(industryRelativeRotation), " industryDistance=",industryDistance)

	

end

local function inverseMapStationLengthParam(length) 
	local lmap = { 0, 1, 2, 3, 5, 7, 9 } -- from stationTemplateFn
	local lmapinv = {}
	for i, v in pairs(lmap) do 
		lmapinv[v]=i
	end 
	if not lmapinv[length] then	
		trace("Warning, lmapinv not found for ",length)
		return length 
	end
	return lmapinv[length]- 2
end
function constructionUtil.getStationLengthParam(stationId) 
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if not util.supportedRailStations()[construction.fileName] then 
		trace("Non standard station detected, defaulting")
		return 1
	end
	return construction.params.templateIndex and  inverseMapStationLengthParam(construction.params.length) or construction.params.length
end 
function constructionUtil.getStationLength(stationId)
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
	if construction.fileName == "station/rail/modular_station/elevated_modular_station.con" then 
		--return (construction.params.length+1)*40
	end 
	if not util.isStationTerminus(stationId) then 
		local terminalToNode = util.getTerminalToFreeNodesMapForStation(stationId) 
		local minLength = math.huge 
		for terminal, nodes in pairs(terminalToNode) do 
			minLength = math.min(util.distBetweenNodes(nodes[1], nodes[2]))
		end 
		return math.floor(minLength/40 + 0.1)*40
	end 
	--return paramHelper.getStationLength(constructionUtil.getStationLengthParam(stationId)  )
	local countModules = 0
	for i, mod in pairs(util.deepClone(construction.params.modules)) do 
		if string.find(mod.name, "_track") then
			countModules = countModules + 1
		end
	end 
	local terminalCount = #util.getStation(stationId).terminals
	local lengthFactor = math.ceil(countModules/terminalCount)
	trace("The length factor was calculated as",lengthFactor, "based on moduleCount:",moduleCount,"terminalCount=",terminalCount)
	--return paramHelper.getStationLength(constructionUtil.getStationLengthParam(stationId)  )
	return lengthFactor * 40
end 

function constructionUtil.mapStationParamsTracks(stationParams, stationId)
	if not stationParams.useLengthDirectly and stationId then 
		if not util.isStationTerminus(stationId) then 
			local terminalToNode = util.getTerminalToFreeNodesMapForStation(stationId) 
			local minLength = math.huge 
			for terminal, nodes in pairs(terminalToNode) do 
				minLength = math.min(util.distBetweenNodes(nodes[1], nodes[2]))
			end 
			local result = math.floor(minLength/40 + 0.1)-1
			stationParams.length = result
			stationParams.useLengthDirectly = true
			 
			trace("The length factor was calculated as ",result," for ",stationId," based on minLength=",minLength)
			return  
		end 
		-- nb the following does not work with through tracks
		local countModules = 0
		for i, mod in pairs(stationParams.modules) do 
			if string.find(mod.name, "_track") then
				countModules = countModules + 1
			end
		end 
		local terminalCount = #util.getStation(stationId).terminals
		local lengthFactor = math.ceil(countModules/terminalCount) - 1
		trace("The length factor was calculated as",lengthFactor, "based on moduleCount:",countModules,"terminalCount=",terminalCount)
		 
		stationParams.length = lengthFactor
		stationParams.useLengthDirectly = true
	elseif  stationParams.templateIndex and not stationParams.useLengthDirectly then
		stationParams.length = inverseMapStationLengthParam(stationParams.length) -- need to invert the length param to retreive the original
	end
end

function constructionUtil.checkRailDepotForUpgrades(constructionId, params, callback)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local depotParams = util.deepClone(construction.params)
	local needsUpgrade = false
	if depotParams.catenary == 0 and params.isElectricTrack then 
		needsUpgrade = true
		depotParams.catenary = 1
	end
	if depotParams.trackType == 0 and params.isHighSpeedTrack then 
		needsUpgrade = true
		depotParams.trackType = 1
	end
	local success = true 
	if needsUpgrade then  
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		depotParams.seed = nil
		success = pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, depotParams)end)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
	end
	if callback then 
		callback({}, success)
	end
end
function constructionUtil.checkStationForUpgrades(stationId, params)
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then 
		return 
	end
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if util.supportedRailStations()[construction.fileName]  then 
		constructionUtil.checkRailStationForUpgrades(stationId,constructionId ,construction,params)
		return 
	end
	if construction.fileName == "station/street/modular_terminal.con" and params.doubleTerminalUpgrade then
		-- Fix (community-reported): road stations never got a free terminal for
		-- double-terminal upgrades; reuse the existing road-station upgrade.
		if util.countFreeTerminalsForStation(stationId) == 0 then
			constructionUtil.upgradeRoadStation(nil, stationId, true, false, true)
		end
		return
	end
	if construction.fileName == "station/street/modular_terminal.con" and params.tramTrackType>0 then 
		constructionUtil.checkBusStationForUpgradeTramOnly(stationId) 
		return
	end
	trace("Non standard station detected, skipping")
end

local function fastDirectLengthUpgrade(stationId, freeSide, params, callback, depotConstr)
	local construction = util.getConstructionForStation(stationId)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local stationParams = util.deepClone(construction.params)
	local currentStationLength = constructionUtil.getStationLength(stationId)
	if currentStationLength >= params.targetStationLength then 
		trace("No upgrade required")
		if callback then 
			callback({}, true)
		end 
		return
	end 
	constructionUtil.setupTrainStationParams(stationId, stationParams)
	local oldStationLength = stationParams.length
	local stationLengthChange
	if oldStationLength > 2 then 
		stationLengthChange = 2
		
	else 
		stationLengthChange = 1
	end 
	

	stationParams.length = stationParams.length + stationLengthChange
	local offset = freeSide == "LEFT" and -1 or 1
	trace("Incrementing stationparams length by",stationLengthChange," for ",stationName,"isTerminus?",isTerminus,"freeSide=",freeSide,"offset=",offset)
	if not stationParams.parallelOffset then 
		stationParams.parallelOffset = 0 
	end 
	if depotConstr then 
		local depotOffset = offset*stationLengthChange*40
		local stationParallelTangent = vec3.normalize(util.v3(construction.transf:cols(1)))
		local offsetVector = depotOffset * stationParallelTangent
		local cols = depotConstr.transf:cols(3)
		cols.x = cols.x + offsetVector.x
		cols.y = cols.y + offsetVector.y
		
		trace("Setting the depotConstr to ",cols.x, cols.y)
		local newProposal = api.type.SimpleProposal.new()
		newProposal.constructionsToAdd[1] = depotConstr
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false),function(res, success) 
				trace("Result fastDirectLengthUpgrade add depot was",success)
				util.clearCacheNode2SegMaps()
				if success then 
					constructionUtil.addWork(function() 
						local constructionId = res.resultEntities[1]
						local construction = util.getConstruction(constructionId)
						local params = util.deepClone(construction.params)
						routeBuilder.buildDepotConnection(constructionUtil.standardCallback, constructionId, params)
					--	params.seed =nil
						--trace("About to call upgradeConstruction on ",constructionId," for depot link")
						--game.interface.upgradeConstruction(constructionId, construction.fileName, params)
					end)
				end 
		end) 
	end 
	
	
	stationParams.parallelOffset = stationParams.parallelOffset + offset
	local modulebasics =helper.createTemplateFn(stationParams, construction.fileName)
	
	local modules = util.setupModuleDetailsForTemplate(modulebasics)   
	stationParams.modules = modules 
	trace("fastDirectLengthUpgrade: About to execute upgradeConstruction for constructionId ",constructionId, " fileName was",construction.fileName," stationId",stationId," freeSide=",freeSide)
	stationParams.seed = nil
	local success = pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
	trace("About set player")
	game.interface.setPlayer(constructionId, game.interface.getPlayer())
	util.clearCacheNode2SegMaps()
	if callback then 
		callback({}, success)
	end 
end 

local function checkAndRemoveDepot(stationId)
	local stationPos = util.getStationPosition(stationId)
	local depotConstruction = searchForDepotOfType(stationPos, "train",350)
	  
	local depotConstructionFull 
	if depotConstruction then 
		depotConstructionFull = util.getConstruction(depotConstruction)
		if util.depotBehindStation(depotConstruction, stationId)  and not util.isDepotContainingVehicles(depotConstructionFull.depots[1]) then 
			trace("found depot behind station", depotConstruction, stationId)
			--local depot = util.getConstruction(construction).depots[1]
			--if depot and   
		else
			trace("Aborting depot removal",stationId)
			return  
		end
	else 
		trace("No depot found near",stationId)
		return 
	end 	
	local link =   util.findDepotLink(depotConstruction)
	local newProposal = api.type.SimpleProposal.new()
	newProposal.constructionsToRemove = { depotConstruction  } 
	local newConstruction = constructionUtil.copyConstruction(depotConstruction)
	if link then 
		newProposal.streetProposal.edgesToRemove[1] = link.linkEdge
		newProposal.streetProposal.nodesToRemove[1] = link.depotNode
		local cols = newConstruction.transf:cols(3)
		local edge = util.getEdge(link.linkEdge)
		--cols.x = cols.x + edge.tangent0.x  --- shift to avoid the edge
		--cols.y = cols.y + edge.tangent0.y  
		
	end 
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false),function(res, success) 
				trace("Result checkAndRemoveDepot was",success, " link found?",link)
				util.clearCacheNode2SegMaps()
	end )
	return newConstruction
end


local function isFreeOnOneSide(stationId)
	local freeNodesToTerminals = util.getFreeNodesToTerminalMapForStation(stationId) 
	local stationMidPoint
	for node , terminal in pairs(freeNodesToTerminals) do 
		local p = util.nodePos(node)
		if stationMidPoint then 
			stationMidPoint = stationMidPoint + p
		else 
			stationMidPoint = p
		end 
	end 
	stationMidPoint = (1/util.size(freeNodesToTerminals))*stationMidPoint 
	
	local constr = util.getConstructionForStation(stationId)
	local stationParallelTangent = util.v3(constr.transf:cols(1))
	
	local terminalsToFreeNodes = util.getTerminalToFreeNodesMapForStation(stationId)
	local seenLeftNode = false -- N.B. "left" and "right" are just labels 
	local seenRightNode = false
	
	for terminal, nodes in pairs(terminalsToFreeNodes) do 
		local node0 = nodes[1]
		local node1 = nodes[2]
		if not node1 then 
			return false 
		end
		local vector = util.vecBetweenNodes(node0, node1)
		local angle = math.abs(util.signedAngle(vector, stationParallelTangent))
		trace("The nodes",node0,node1,"made an angle to the vector of ",math.deg(angle)," at terminal",terminal)
		if angle > math.rad(90) then -- should be really either 0 or 180 
			local temp = node0 
			node0 = node1 
			node1 = temp 
		end 
		seenLeftNode = seenLeftNode or #util.getSegmentsForNode(node0) > 1
		seenRightNode = seenRightNode or #util.getSegmentsForNode(node1) > 1
		trace("After analysis nodes",node0,node1,"seenLeftNode?",seenLeftNode,"seenRightNode?",seenRightNode)
		if seenLeftNode and seenRightNode then 
			return false 
		end 
		for i , node in pairs(nodes) do -- a crude collision check to extend a track segment out from the empty node 
			if #util.getSegmentsForNode(node) == 1 then 
				local isError = proposalUtil.trialBuildFromDeadEndNode(node, 80).isError
				trace("Doing trial build at ",node,"isError?",isError)
				if isError then 
					trace("Aborting the build")
					return false 
				end 
				
			end 
		end 
	end 
	return seenLeftNode and "LEFT" or "RIGHT"
end 

local function cleanupDeadEnds(constructionId) 
	for i, node in pairs(util.getFreeNodesForConstruction(constructionId)) do 
		local segs = util.getSegmentsForNode(node)
		if #segs == 2 then 
			local nextSeg = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
		
			if util.getEdgeLength(nextSeg) < 5 then 
				trace("Inspecting possible short seg",nextSeg)
				local edge = util.getEdge(nextSeg)
				local nextNode = edge.node0 == node and edge.node1 or edge.node0
				if #util.getSegmentsForNode(nextNode) == 1 and #edge.objects == 0 then 
					trace("Discovered dead end, cleaning up")
					local newProposal = api.type.SimpleProposal.new()
					newProposal.streetProposal.edgesToRemove[1]=nextSeg 
					newProposal.streetProposal.nodesToRemove[1]=nextNode 
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),function(res, success) 
						trace("Result of attempt to ucleanupDeadEnds was",success)
						if success then 
							util.clearCacheNode2SegMaps()
						end
					end)
				end 
			end 
		end 
	end 
end 

function constructionUtil.upgradeStationLength(stationId, params, callback) 
	params.stationLengthUpgrade = true 
	params.targetStationLength = params.stationLength
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = util.getConstruction(constructionId)
	constructionUtil.checkRailStationForUpgrades(stationId,constructionId ,construction,params, callback)
	params.stationLengthUpgrade = false 
end 

function constructionUtil.checkRailStationForUpgrades(stationId,constructionId ,construction,params, callback)
	cleanupDeadEnds(constructionId) 
	if params.stationLengthUpgrade then 
		local terminalsToAdd = 0
		trace("checkRailStationForUpgrades: begin stationLengthUpgrade")
		--local callback = constructionUtil.standardCallback
		local depotRemoved = checkAndRemoveDepot(stationId)
		local freeOnOneSide = not util.isStationTerminus(stationId) and isFreeOnOneSide(stationId)
		if  freeOnOneSide  then 
			fastDirectLengthUpgrade(stationId, freeOnOneSide, params, callback, depotRemoved)
		else 
		
			constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminalsToAdd, doNotRemoveCrossover)
			return
		end
	end 
	if params.doubleTerminalUpgrade then 
		local terminalsToAdd = 0
		local stationOccurrances = 0
		local newTerminalConfiguration = {}
		newTerminalConfiguration.stationName = util.getStationName(stationId) -- debug
		newTerminalConfiguration.terminalsToDouble = {}
		local line = util.getLine(params.lineId)
		local stationsSeen = {}
		local isCircleLine = true 
		for i, stop in pairs(line.stops) do 
			local station = util.stationFromStop(stop)
			if stationsSeen[station] then 
				isCircleLine = false 
			else 
				stationsSeen[station]=true 
			end 
			if station == stationId then
				stationOccurrances = stationOccurrances + 1
				if #stop.alternativeTerminals == 0 then 
					terminalsToAdd = terminalsToAdd + 1
					newTerminalConfiguration.terminalsToDouble[stop.terminal+1]=true
				end
			end 
		end 
		local isTerminus = stationOccurrances == 1 and not isCircleLine
		local stationName = util.getName(stationId)
		trace("checkRailStationForUpgrades: doubleTerminalUpgrade determined terminals needed=",terminalsToAdd, "stationOccurrances=",stationOccurrances," at ",stationName)
		--local callback = constructionUtil.standardCallback
		if terminalsToAdd > 0 then 
			local station = util.getStation(stationId)

			local numFreeTerminals = util.countFreeUnconnectedTerminalsForStation(stationId)
			trace("checkRailStationForUpgrades: reducing terminalsToAdd by ",numFreeTerminals)
			terminalsToAdd = math.max(0, terminalsToAdd - numFreeTerminals) -- still enter the upgrade station even if zero as may need connections
			if (terminalsToAdd%2~=0) and util.getConstructionForStation(stationId).params.includeOffsideBuildings and false then -- TODO temp disabled as this causes failures when finding unconnected terminal nodes 
				trace("upgradeStationAddTerminal: increasing terminal count for offside bulding to make even, was",terminalsToAdd,"at",stationName)
				terminalsToAdd = terminalsToAdd + 1
			end
			local newNumTerminals = #station.terminals 
			local terminalOffset = terminalsToAdd
			newTerminalConfiguration.newConnectTerminals = {}
			newTerminalConfiguration.oldToNewTerminals = {}
			newTerminalConfiguration.isTerminus = isTerminus
			for i = newNumTerminals, 1, -1 do 
				if i ==1 then 
					terminalOffset = math.min(terminalOffset, 1)
				end
				if newTerminalConfiguration.terminalsToDouble[i] then
					if not isTerminus then 
						local connectTerminal = i+terminalOffset
						if terminalOffset <= 0 and i > 1 and i < newNumTerminals then 
							if util.isFreeTerminalOneBased(stationId, i-1) then 
								connectTerminal = i - 1
								trace("Setting connect terminal based on free terminal",connectTerminal," at ",i)
							elseif 	util.isFreeTerminalOneBased(stationId, i+1) then 
								connectTerminal = i + 1
								trace("Setting connect terminal based on free terminal",connectTerminal," at ",i)
							else 
								trace("WARNING! unable to find adjacent terminal")
							end 
						elseif i == 1 or util.size(newTerminalConfiguration.newConnectTerminals)+1== stationOccurrances then 
							local baseOffset = 1
							if isCircleLine and i%2 == 1 then -- if part of a circle we need to shift out the outer terminal to make space for the inner one 
								trace("At i=",i,"setting the base offset to terminalsToAdd")
								baseOffset = terminalsToAdd
							end 
							terminalOffset = i == newNumTerminals and terminalOffset or baseOffset
							
							if i == newNumTerminals then 
								newTerminalConfiguration.oldToNewTerminals[i]=i+terminalOffset-1
								newTerminalConfiguration.newConnectTerminals[i]=i+terminalOffset
							else 
								newTerminalConfiguration.oldToNewTerminals[i]=i+terminalOffset
								newTerminalConfiguration.newConnectTerminals[i]=i+terminalOffset-1
							end
							trace("Moving the inner side outwards at i=",i,"for station",stationName," setting oldToNewTerminals",newTerminalConfiguration.oldToNewTerminals[i]," and connect at ",newTerminalConfiguration.newConnectTerminals[i])
							break
						end 						
						trace("Setting the connect terminal at ",i," to ",connectTerminal)
						newTerminalConfiguration.newConnectTerminals[i]=connectTerminal
					end 
					terminalOffset = terminalOffset -1
				elseif terminalOffset == 0 then 
					if util.isFreeTerminalOneBased(stationId, i) then 
						trace("Setting the terminal offset to 1 to bring in the line")
						terminalOffset = 1
					end 
				end 
	
				if terminalOffset ~= 0 and not util.isFreeTerminalOneBased(stationId, i) and newTerminalConfiguration.newConnectTerminals[i] ~= i+terminalOffset then 
					newTerminalConfiguration.oldToNewTerminals[i]=i+terminalOffset
					trace("Mapping the old terminal",i," to ",newTerminalConfiguration.oldToNewTerminals[i],"at",stationName)
				end 
				if util.size(newTerminalConfiguration.newConnectTerminals)== stationOccurrances then 
					break 
				end
			end
			if util.tracelog then debugPrint({newTerminalConfiguration=newTerminalConfiguration}) end
			constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminalsToAdd, doNotRemoveCrossover, newTerminalConfiguration)
		end
		return
	end 
	local stationParams = util.deepClone(construction.params)
	local inputLength = stationParams.length
	local needsUpgrade = false
	local isElectricUpgrade = false 
	local isHighSpeedUpgrade = false
	if stationParams.catenary ~= 1 and params.isElectricTrack then 
		needsUpgrade = true
		isElectricUpgrade = true
		stationParams.catenary = 1
	end
	if stationParams.trackType ~= 1 and params.isHighSpeedTrack then 
		needsUpgrade = true
		isHighSpeedUpgrade = true
		stationParams.trackType = 1
	end
	
	local success = true
	if needsUpgrade then 
		local stationPos = util.getStationPosition(stationId)
		
		--local modulebasics = helper.createTemplateFn(stationParams, construction.fileName)
		--local modules = util.setupModuleDetailsForTemplate(modulebasics)  
		constructionUtil.setupTrainStationParams(stationId, stationParams)
		local target
		if isElectricUpgrade and isHighSpeedUpgrade then 
			target = "_high_speed_track_catenary"
		elseif isElectricUpgrade then
			target = "_track_catenary"
		else 
			assert(isHighSpeedUpgrade)
			target = "_high_speed_track"
		end 
		
		for i , mod in pairs(stationParams.modules) do 
			if string.find(mod.name, "_track") and not string.find(mod.name, target) then
				local result = string.gsub(mod.name, "_track", target)
				trace("Changing ",mod.name," to ",result)
				if api.res.moduleRep.find(result) ~= -1 then -- guard against doing something invalid
					mod.name = result
				else 
					trace("WARNING! Invalid result for module upgrade:",result)
				end 
			end
		end 
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		stationParams.seed = nil
		success = pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
		local depotConstr = constructionUtil.searchForRailDepot(stationPos)
		if depotConstr then 
			constructionUtil.checkRailDepotForUpgrades(depotConstr, params)
		end
		
	end
	if callback then 
		callback({}, success )
	end
end

function constructionUtil.setupTrainStationParams(stationId, stationParams)
	constructionUtil.mapStationParamsTracks(stationParams, stationId)
	if not stationParams.templateIndex then 
		--stationParams.length = inputLength
		local isCargo = util.getStation(stationId).cargo
		local isTerminus = util.isStationTerminus(stationId)--stationParams.modules[3699960]
		if isCargo then 
			if isTerminus then 
				stationParams.templateIndex = 7
			else 
				stationParams.templateIndex = 6
			end 
		else 
			if isTerminus then 
				stationParams.templateIndex = 1
			else 
				stationParams.templateIndex = 2
			end 
		end 
	end
end 

function constructionUtil.searchForNearestRoadStation(p, r , isCargo)
local options = {} 
	for i , station in pairs(util.searchForEntities(p,r, "STATION")) do 
		if station.carriers.ROAD and station.cargo==isCargo then 
			table.insert(options, { station=station.id, scores = { util.distance(p, util.getStationPosition(station.id))}})
		end
	end 
	if #options > 0 then 
		return util.evaluateWinnerFromScores(options).station 
	end
end
function constructionUtil.searchForNearestCargoRoadStation(p, r)
	return constructionUtil.searchForNearestRoadStation(p, r , true)
end

function constructionUtil.validateHarbourConnection(buildResult, result, transhipmentCallback)
	if result.station1 and result.station2 and not result.needsTranshipment1 and not result.needsTranshipment2 then 
		trace("validateHarbourConnection: skipping as both stations detetected and no transhipment required")
		return true 
	end
	util.lazyCacheNode2SegMaps()
	trace("validateHarbourConnection: got buildResult with resultEntities:",#buildResult.resultEntities)
	local nowNeedsTranshipment1 = false 
	local nowNeedsTranshipment2 = false
	--if not result.needsTranshipment1 and not result.needsTranshipment2 then 
	if not transhipmentCallback then 
		--local hasTwoStations = #buildResult.resultEntities > 2
		local hasTwoStations = result.constructionIdxs and #result.constructionIdxs==2 and result.constructionIdxs[1].harbourIdx and result.constructionIdxs[2].harbourIdx
		
		--local station1 = api.engine.system.streetConnectorSystem.getConstructionEntityForStation( buildResult.resultEntities[1])
		local edge1 = result.edge1
		local edge2 = result.edge2
		local construction1 = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(result.industry1.id)
		local construction2 = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(result.industry2.id)
		local valid
		local station1 = result.station1 or util.getConstruction(buildResult.resultEntities[result.constructionIdxs[1].harbourIdx]).stations[1]
		local station2
		if hasTwoStations then  
			--[[for i = #buildResult.resultEntities, 2, -1 do 
				local construction = util.getConstruction(buildResult.resultEntities[i])
				trace("Inspecting buildResult at ",i,"construction had stations?",#construction.stations>0)
				if construction.stations[1] then 
					station2 = construction.stations[1]
					break 
				end 
			end ]]--
			station2 = util.getConstruction(buildResult.resultEntities[result.constructionIdxs[2].harbourIdx]).stations[1]
			
			valid = util.checkIfStationInCatchmentArea(station1, construction1)  and util.checkIfStationInCatchmentArea(station2, construction2)  
			trace("Initial check of whether the the thing was valid is",valid)
		 	if not valid then 
				if not result.needsTranshipment1 and not util.checkIfStationInCatchmentArea(station1, construction1) then 
					result.needsTranshipment1 = true 
					nowNeedsTranshipment1 = true 
				end 
				if not result.needsTranshipment2 and not util.checkIfStationInCatchmentArea(station2, construction2)  then 
					result.needsTranshipment2 = true
					nowNeedsTranshipment2 = true
				end 
			end 
			result.station1 = station1 
			result.station2 = station2
		else  
			station2 = result.station2 or util.getConstruction(buildResult.resultEntities[result.constructionIdxs[2].harbourIdx]).stations[1]
			if result.station2 then  -- determines if the new harbor was at 1 or 2
				if not result.needsTranshipment1 then 
					valid = util.checkIfStationInCatchmentArea(station1, construction1)  
					result.needsTranshipment1 = true 
					nowNeedsTranshipment1 = true 
				end 
			else
				if not result.needsTranshipment2 then 
					trace("About to check if station",station2,"in catchment area",construction2)
					valid = util.checkIfStationInCatchmentArea(station2, construction2) 
					result.needsTranshipment2 = true 
					nowNeedsTranshipment2 = true 
				end 
			end  
			 
			
		end
	
		--[[if not pathFindingUtil.validateShipPath(station1, station2) then 
			trace("WARNING! Did not make a connection, rolling back")
			constructionUtil.rollbackHarbourConstruction(buildResult)
			return false 
		end]]--
		if valid then 
			return valid
		end
		if nowNeedsTranshipment1 or nowNeedsTranshipment2 then 
	
			
			trace("Attempting upgrade for transhipment, nowNeedsTranshipment1=",nowNeedsTranshipment1,"nowNeedsTranshipment2=",nowNeedsTranshipment2,"station1=",station1,"station2=",station2)
			local needsTranshipment = true 
			local newProposal = api.type.SimpleProposal.new()
			local function checkForShortDistance(station, industry)
				local p0 = util.getStationPosition(station) 
				local p1 = util.v3fromArr(industry.position)
				local distance = util.distance(p0, p1)
				trace("checkForShortDistance: The distance from",station,"to",industry.name,"was",distance)
				if distance < 300 then 
					local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
					local nearestBaseNode = util.getNearestBaseNodePosition(p0)
					if not nearestBaseNode then 
						trace("checkForShortDistance: no node found near",p0.x,p0.y)
						return false
					end 
					local tn = util.getComponent(constructionId, api.type.ComponentType.TRANSPORT_NETWORK)
					local connectionPoints = {}
					for i, tnEdge in pairs(tn.edges) do 
						if tnEdge.geometry.width < 4 then -- some edges are used for storage, discriminate based on the width
							for j = 1,2 do 
								local p = util.v2ToV3(tnEdge.geometry.params.pos[j] ,tnEdge.geometry.height[j])
								local t = vec3.normalize(util.v2ToV3(tnEdge.geometry.params.tangent[j] ))
								table.insert(connectionPoints, {
									p = p, 
									t = t, 
									scores = { vec2.distance(p,p0)}
								})
								
							end 
						end
					end 
					trace("checkForShortDistance: got ",#connectionPoints,"to inspect")
					for i , point in pairs(util.evaluateAndSortFromScores(connectionPoints)) do 
						local tPerp = util.rotateXY(point.t, math.rad(90))
						local offset = 12
						local testP = point.p - offset*tPerp 
						local testP2 = point.p + offset*tPerp 
						local positionToUse = util.distance(testP, p1) > util.distance(testP2,p1) and testP or testP2 
						local testProposal = api.type.SimpleProposal.new() 
						local node = nearestBaseNode.node
						trace("checkForShortDistance: Inspecting position",positionToUse.x,positionToUse.y,"the connect node at",node)
						util.buildShortStubRoadWithPosition(testProposal, node, positionToUse )
						if not checkProposalForErrors(testProposal).isError then 
							trace("Building on main proposal")
							util.buildShortStubRoadWithPosition(newProposal, node, positionToUse)
							return true 
						end 
						trace("Proposal had errors trying next")
						
					end 
					
				end 
				
				return false 
			end 
			if nowNeedsTranshipment1 then 
				local index = 1 
				if not checkForShortDistance(station1, result.industry1) then 
					constructionUtil.checkHarborForUpgrade(station1, needsTranshipment, result, index, newProposal)
				end 
			end 
			if nowNeedsTranshipment2 then 
				local index = 2 
				if not station2 then 
					debugPrint({buildResult=buildResult, result= result}) 
				end
				if not checkForShortDistance(station2, result.industry2) then 
					constructionUtil.checkHarborForUpgrade(station2, needsTranshipment, result, index, newProposal)
				end
			end
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),function(res, success) 
				trace("Result of attempt to upgrade harbour was",success)
				if success then 
					constructionUtil.addWork(function() 
						--[[local newBuildResult = { resultEntities = {}}
						for i, entity in pairs(res) do 
							table.insert(newBuildResult.resultEntities, entity) 
						end ]]--
						if util.checkIfStationInCatchmentArea(station1, api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(result.industry1.id)) then 
							trace("Overriding needsTranshipment1 to false, now in catchment area")
							result.needsTranshipment1 = false 
						end 
						local construction2 = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(result.industry2.id)
						if construction2 ~= -1 and util.checkIfStationInCatchmentArea(station2, construction2) then 
							trace("Overriding needsTranshipment1 to false, now in catchment area")
							result.needsTranshipment2 = false 
						end 
						--constructionUtil.validateHarbourConnection(buildResult, result)

						constructionUtil.validateHarbourConnection(res, result, true)
					end) -- call back ourselves after
				
				else 
					trace("WARNING! Could not upgrade harbour")
				end				
			end)
			return true
		end 
	
 	end 
	

	if nowNeedsTranshipment2 then 
	
	end
	
	local function completeTranshipmentRoute(index) 
		trace("completeTranshipmentRoute begin at index=",index,"for",result.industry1.name,result.industry2.name)
		local isTown = result.industry2.type == "TOWN" and index == 2
		local indexes = result.constructionIdxs and result.constructionIdxs[index]
		local station1Constr
		local station2Constr  
		if indexes then 
			station1Constr = indexes.harbourRoadStationIdx and buildResult.resultEntities[indexes.harbourRoadStationIdx]
			if indexes.roadStationIdx then 
				station2Constr = buildResult.resultEntities[indexes.roadStationIdx]
				
			elseif not isTown then 
				if not  result.existingRoadStations then 
				
				end
				station2Constr = result.existingRoadStations and result.existingRoadStations[index]
			end
		end 
		local harbor = index == 1 and result.station1 or result.station2 
		local industry = index == 1 and result.industry1 or result.industry2
		local newProposal = api.type.SimpleProposal.new()
		if not station1Constr and harbor then 
			local harbourPos = util.getStationPosition(harbor)
			local station1 = constructionUtil.searchForNearestCargoRoadStation(harbourPos,350)
			trace("attempt to find station1 was ",station1, " near ",harbourPos.x, harbourPos.y, "The harbour was",harbor)
			constructionUtil.checkRoadStationForUpgrade(newProposal, station1, industry, result)
			station1Constr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station1)
	 
		end 
		if not station2Constr and not isTown then 
			local station2 = constructionUtil.searchForNearestCargoRoadStation(util.v3fromArr(industry.position),250)
			constructionUtil.checkRoadStationForUpgrade(newProposal, station2, industry, result)
			station2Constr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station2)
		end 
		trace("Completing transhipment route, station constructions were",station1Constr,station2Constr)
		local stations = { 
			util.getConstruction(station1Constr).stations[1],
			isTown and result.truckStop or util.getConstruction(station2Constr).stations[1],
		}
		local hasEntranceB = {
			util.getConstruction(station1Constr).params.entrance_exit_b==1,
			not isTown and util.getConstruction(station2Constr).params.entrance_exit_b==1,
		}
		local params = paramHelper.getDefaultRouteBuildingParams(result.cargoType, false, false) 
		params.isForTranshipment = true
		local callback = function(res, success) 
			trace("completeTranshipmentRoute: success of building link roads was",success)
			if success then 
				util.clearCacheNode2SegMaps()
				constructionUtil.addWork(function() 
					local callback2 = function(res, success) 
						if success  then	
							util.clearCacheNode2SegMaps()
							constructionUtil.addWork(function() constructionUtil.lineManager.setupTrucks(result, stations, params, true) end)	 
						end
						constructionUtil.standardCallback(res, success)
					end 
					xpcall(function() -- this may fail if the main line failed to connect and was rolled back
						trace("Getting routeinfo between ",stations[1],stations[2])
						local routeInfo =  pathFindingUtil.getRoadRouteInfoBetweenStations(stations[1], stations[2])
						if not routeInfo or routeInfo.exceedsRouteToDistLimitForTrucks and not isTown then 
							trace("completeTranshipmentRoute: Building road route between stations, had routeInfo?",routeInfo)
							routeBuilder.buildRoadRouteBetweenStations(stations, callback2, params,result,hasEntranceB, index)
						else 
							routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callback2, params) 
						end
					end, err)
				end)
			else 
				trace("Callback to link the road station failed")
			end 
		end

	 
		if indexes then 
			local function addToProposal(entity, node) 
				if entity then 
					entity.entity = -1-#newProposal.streetProposal.edgesToAdd
					newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity 
				else
					trace("WARNING! no entity found while trying to build to ",node)
				end 
			end 
			if not isTown and indexes.connectNode then 
				trace("Adding link for connectNode")
				addToProposal(util.buildConnectingRoadToNearestNode(indexes.connectNode, -1, true, newProposal), indexes.connectNode)
				
			end 
			if  indexes.harbourRoadDepotIdx then 
				trace("Adding link for harbourRoadDepotIdx")
				local depotConstr = buildResult.resultEntities[indexes.harbourRoadDepotIdx]
				local depotNode = util.getEdge(util.getConstruction(depotConstr).frozenEdges[1]).node1
				addToProposal(util.buildConnectingRoadToNearestNode(depotNode, -2, true, newProposal),depotNode)
		 
			end 
			if indexes.roadDepotIdx then 
				trace("Adding link for roadDepotIdx")
				local depotConstr = buildResult.resultEntities[indexes.roadDepotIdx]
				local depotNode = util.getEdge(util.getConstruction(depotConstr).frozenEdges[1]).node1
				trace("Got depot node it was",depotNode)
				addToProposal(util.buildConnectingRoadToNearestNode(depotNode, -3, false, newProposal),depotNode)
				 
			end 
			if indexes.harbourConnectNode then
				trace("Adding link for harbourConnectNode")
				addToProposal(util.buildConnectingRoadToNearestNode(indexes.harbourConnectNode, -4, true, newProposal), indexes.harbourConnectNode)
			end
		end
		
		if isTown and station1Constr and util.distance(util.v3fromArr(result.industry2.position),util.getConstructionPosition(station1Constr)) < 1000 then 
			local nodes = util.getFreeNodesForConstruction(station1Constr)
			for i, node in pairs(nodes) do 
				local details = util.getDeadEndNodeDetails(node)
				local parallelTangent= vec3.normalize(details.tangent)
				local perpTangent= util.rotateXY(parallelTangent, math.rad(90))
				for j, tangent in pairs({parallelTangent, perpTangent}) do 
					for k, sign in pairs({-1,1}) do 
						local depth = 1
						local result = constructionUtil.buildLinkRoad(newProposal, node, sign*tangent, depth, nil, nil, params)
						trace("Harbour Result of try build at",i,j,k,"was",result)
					end 
				end 
			end 
		end 
		

		trace("Sending command to link the stations") 
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),callback)
	end 
	
	if result.needsTranshipment1 then 
		completeTranshipmentRoute(1)
	end 
	
	if result.needsTranshipment2 then 
		completeTranshipmentRoute(2)
	end 
	
	
	
	return true -- TODO 
end

function constructionUtil.rollbackHarbourConstruction(buildResult)
	trace("Rolling back harbour construction")
	local constructionsToRemove = util.deepClone(buildResult.resultEntities)
	local edgesToRemove = {}
	for i = #constructionsToRemove, 1, -1 do 
		local fullConstruction = util.getConstruction(constructionsToRemove[i])
		local depot = fullConstruction.depots[1]
		local station = fullConstruction.stations[1]
		local aborted = false
		if depot then 
			if util.isDepotContainingVehicles(depot) then 
				trace("Found vehicle in depot, aborting removal")
				table.remove(constructionsToRemove, i)
				aborted = true
			end  
		end 
		if not aborted then 
			local freeNodes = util.getFreeNodesForConstruction(constructionsToRemove[i])
			for j, node in pairs(freeNodes) do 
				for i, seg in pairs(util.getSegmentsForNode(node)) do 
					if not util.isFrozenEdge(seg) and not util.contains(edgesToRemove, seg) then 
						table.insert(edgesToRemove, seg)
					end 
				end 
			end 
		end
	end 
	local newProposal = routeBuilder.setupProposalAndDeconflict({}, {}, {}, edgesToRemove, {})
	newProposal.constructionsToRemove = constructionsToRemove
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
end

function constructionUtil.isTrainStationTerminus(stationId)
	local construction = util.getConstructionForStation(stationId)
	local stationParams = util.deepClone(construction.params)
	if  stationParams.templateIndex then 
		return  stationParams.templateIndex % 2 == 1
	else 
		return  stationParams.modules[3699960]
	end 
end 

function constructionUtil.upgradeStationAddTerminals(stationId, terminals, buildThroughTracks , params, otherTown)
	if otherTown then 
		constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminals)
		return		
	end 
	
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local stationParams = util.deepClone(construction.params)
	local inputLength = stationParams.length
	local stationPerpTangent = vec3.normalize(util.v3(construction.transf:cols(0)))
	
	--[[if not stationParams.length or not stationParams.useLengthDirectly then 
		local countModules = 0
		for i, mod in pairs(stationParams.modules) do 
			if string.find(mod.name, "_track") then
				countModules = countModules + 1
			end
		end 
		local terminalCount = #util.getStation(stationId).terminals
		local lengthFactor = math.ceil(countModules/terminalCount) - 2
		trace("The length factor was calculated as",lengthFactor, "based on moduleCount:",countModules,"terminalCount=",terminalCount)
		inputLength = lengthFactor
		stationParams.length = lengthFactor
		stationParams.useLengthDirectly = true
	else 
		constructionUtil.mapStationParamsTracks(stationParams)
	end	]]--
	constructionUtil.mapStationParamsTracks(stationParams, stationId)
	local isCargo = util.getStation(stationId).cargo
	
	stationParams.tracks = stationParams.tracks + terminals
	if stationParams.tracks >= 11 then 
		trace("Aborting straight upgrade for high track count")
		constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminals)
		return		
	end 
	
	trace("Input stationparams.length  was ",inputLength, " the recalculated length was ",stationParams.length," isCargo=",isCargo )
	local isTerminus = stationParams.templateIndex and stationParams.templateIndex % 2 == 1
	if not stationParams.templateIndex then 
		--stationParams.length = inputLength
		isTerminus = stationParams.modules[3699960]
		if isCargo then 
			if isTerminus then 
				stationParams.templateIndex = 7
			else 
				stationParams.templateIndex = 6
			end 
		else 
			if isTerminus then 
				stationParams.templateIndex = 1
			else 
				stationParams.templateIndex = 2
			end 
		end 
	end
	if buildThroughTracks then 
		stationParams.buildThroughTracks = buildThroughTracks
	end 
	local modulebasics =helper.createTemplateFn(stationParams, construction.fileName)
	
	local modules = util.setupModuleDetailsForTemplate(modulebasics)   
	stationParams.modules = modules 
	trace("upgradeStationAddTerminals: About to execute upgradeConstruction for constructionId ",constructionId, " fileName was",construction.fileName," stationId",stationId)
	stationParams.seed = nil
	pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
	trace("About set player")
	game.interface.setPlayer(constructionId, game.interface.getPlayer())
	util.clearCacheNode2SegMaps()
end
function constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminalsToAdd, doNotRemoveCrossover, newTerminalConfiguration, safeMode)
	if constructionUtil.failedUpgrades and constructionUtil.failedUpgrades[stationId] then 
		trace("WARNING! This has already failed upgrade, aborting")
		return
	end 
	
	local stationName = util.getName(stationId)
	trace("Begin upgradeStationAddTerminal for",stationId, stationName," terminalsToAdd=", terminalsToAdd)
	if not terminalsToAdd then  
		terminalsToAdd = 1
	end
	doNotRemoveCrossover = true
	local invocationCount =0 
	local changeLineCallbacks = {}
	local changeLineCallbackTerminals = {}
	
	 local edgesToRemove= {}
	 local edgeObjectsToRemove = {}
	 local nodesToAdd = {}
	 local edgeObjectsToAdd = {}
	 local edgesToAdd = {}

	 local replacedNodesMap = {}
	local wrappedCallback = function() 
		invocationCount = invocationCount  + 1
		trace("wrappedCallback invoked, count is ",invocationCount)
		if invocationCount == #changeLineCallbacks then -- only do this when all changes are complete
			constructionUtil.addWork(callback)
		end
	end
	local station = util.getStation(stationId)
	local isCargo = station.cargo
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local stationParams = util.deepClone(construction.params)
	if stationParams.includeOffsideBuildings and (terminalsToAdd%2~=0) and false then 
		trace("upgradeStationAddTerminal: increasing terminal count for offside bulding to make even, was",terminalsToAdd)
		terminalsToAdd = terminalsToAdd + 1
	end
	local stationPos = util.v3(construction.transf:cols(3))
	local stationParallelTangent = vec3.normalize(util.v3(construction.transf:cols(1)))
	local stationPerpTangent = vec3.normalize(util.v3(construction.transf:cols(0)))
	local position = util.v3(construction.transf:cols(3))
	local inputLength = stationParams.length
	constructionUtil.mapStationParamsTracks(stationParams, stationId)
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	newConstruction.transf = construction.transf
	local stationLengthChange = 0
	local isTerminus = util.isStationTerminus(stationId)
	if params.stationLengthUpgrade then 
		local currentStationLength = constructionUtil.getStationLength(stationId)
		if currentStationLength >= params.targetStationLength and not params.doubleTerminalUpgrade then 
			trace("No upgrade required,currentStationLength=",currentStationLength," target stationLength=",targetStationLength)
			if callback then 
				callback({}, true)
			end
			return
		end 
		local oldStationLength = stationParams.length
		if oldStationLength > 2 then 
			stationLengthChange = 2
			
		else 
			stationLengthChange = 1
		end 
		
		trace("Incrementing stationparams length by",stationLengthChange," for ",stationName,"isTerminus?",isTerminus)
		stationParams.length = stationParams.length + stationLengthChange
		if oldStationLength < 3 or isTerminus then 
			local isEven = oldStationLength % 2 == 0
			
		
			local sign = isEven and -1 or 1
			trace("The oldStationLength was",oldStationLength,"isEven?",isEven, "sign=",sign)
			local offset = 20
			if isTerminus then 
				--sign = -sign + 1
				sign = 2
				if oldStationLength == 2 then 
					sign = 0 
				end
				trace("terminus shift: The sign was ",sign)
			end 
			position = position + sign*offset*stationParallelTangent
			local cols = newConstruction.transf:cols(3)
			cols.x = position.x 
			cols.y = position.y 
			cols.z = position.z
		end
	end 
	trace("Input stationparams.length  was ",inputLength," recalculated was ",stationParams.length," isCargo=",isCargo )
	stationParams.tracks = stationParams.tracks + terminalsToAdd

	if not stationParams.catenary then 
		stationParams.catenary = 0
	end
	stationParams.catenary = math.max(stationParams.catenary, params.isElectricTrack and 1 or 0)
	trace("Output stationparams.length  was ", stationParams.length)
	--local isTerminus = stationParams.templateIndex and stationParams.templateIndex % 2 == 1
	
	if not stationParams.templateIndex then 
		--stationParams.length = inputLength
		--isTerminus = stationParams.modules[3699960]
		if isCargo then 
			if isTerminus then 
				stationParams.templateIndex = 7
			else 
				stationParams.templateIndex = 6
			end 
		else 
			if isTerminus then 
				stationParams.templateIndex = 1
			else 
				stationParams.templateIndex = 2
			end 
		end 
	end
	local modulebasics =helper.createTemplateFn(stationParams, construction.fileName)
	
	local modules = util.setupModuleDetailsForTemplate(modulebasics)   
	stationParams.modules = modules 
	
	newConstruction.name=stationName
	
	 newConstruction.fileName = construction.fileName
	newConstruction.playerEntity = api.engine.util.getPlayer() 

	newConstruction.params = stationParams  
	--local stationParallelTangent = util.v3(construction.transf:cols(1))
	--local position = util.v3(construction.transf:cols(3))
	if applyDummyShift then 
		
		position = position + 1*stationParallelTangent
		local cols = newConstruction.transf:cols(3)
		cols.x = position.x 
		cols.y = position.y 
		cols.z = position.z
	end 
	local stationWasOffset = false
	if stationParams.tracks >= 11 and stationParams.tracks%2 == 1 and terminalsToAdd > 0 then 
		trace("Applying shift, old position",position.x,position.y)
		local offset = 10 
		if stationParams.tracks >= 13 then 
			offset = 15
		end 
		position = position + offset*stationPerpTangent
		local cols = newConstruction.transf:cols(3)
		trace("Applying shift, new position",position.x,position.y)
		cols.x = position.x 
		cols.y = position.y 
		cols.z = position.z
		stationWasOffset = true
	end 
	if stationParams.buildThroughTracks and not params.stationLengthUpgrade and not params.doubleTerminalUpgrade then 
		-- not going to attempt any changes
		trace("Doing upgrade directly using game.interface.upgradeConstruction at",stationName)
		stationParams.seed = nil
		pcall(function() game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end) 
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
		if callback then 
			callback({}, true)
		end
		return
	end
	 local depotConstruction 
	 if (isTerminus and not params.stationLengthUpgrade) or newTerminalConfiguration then 	
		depotConstruction = searchForDepotOfType(stationPos, "train",350)
	 end
	 if params.stationLengthUpgrade  and not isTerminus then
		if not depotConstruction then 
			depotConstruction = searchForDepotOfType(stationPos, "train",350)
		end 
		if depotConstruction then 
			if util.depotBehindStation(depotConstruction, stationId) then 
				trace("found depot behind station", depotConstruction, stationId)
			else  
				depotConstruction = nil  -- TODO: need to look into this, currently conflicts with node replacement
			end
		end
	 end
	 local link
	 if depotConstruction then 
		 
		link = util.findDepotLink(depotConstruction)
	end
	 
	 if depotConstruction and not util.isDepotContainingVehicles(depotConstruction) then 
		local newProposal = api.type.SimpleProposal.new()
		newProposal.constructionsToRemove = { depotConstruction } 
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
		trace("upgradeStationAddTerminal: about to sent command to remove depot construction",stationId, stationName)
		api.cmd.sendCommand(build, function(res, success) 
			trace("upgradeStationAddTerminal: remove depot success was",success)
			if success then 
				util.clearCacheNode2SegMaps()
				util.lazyCacheNode2SegMaps()
			end 		
		end)
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps()
		if link then 
			local newLinkEdge = util.findEdgeConnectingPoints(link.p0, link.p1)
			local linkEdge
			trace("Removed depot, setting new link edge to ",newLinkEdge)
			if newLinkEdge then 
				local linkEdgeFull = util.getEdge(newLinkEdge)
				local freeNode = #util.getSegmentsForNode(linkEdgeFull.node0) == 1 and linkEdgeFull.node0 or linkEdgeFull.node1
				linkEdge = {
					linkEdge = newLinkEdge, 
					depotNode = freeNode,
					link.p0,
					link.p1
				}
			end 
			link = linkEdge
		end
		
		--[[local depotFreeNode = util.getFreeNodesForConstruction(depotConstruction)[1] 
		local segs = util.getSegmentsForNode(depotFreeNode)
		local shouldRemoveNode = false 
		if #segs > 1 then 
			local otherEdge = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
			if util.contains(newProposal.streetProposal.edgesToRemove, otherEdge) then 
				trace("Determined should remove depot node based on removed edge")
			else 
				trace("Determined should not remove depot node")
			end 
		else 
			shouldRemoveNode = true 
		end 
		if shouldRemoveNode and not util.contains(newProposal.streetProposal.nodesToRemove, depotFreeNode) then 
			trace("Removing depot node as it no longer refereced")
			newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=depotFreeNode 
		end]]--
	end
	 

	local connectedEdges = util.findFreeConnectedEdgesAndNodesForConstruction(constructionId)
	local freeNodesToTerminals = util.getFreeNodesToTerminalMapForStation(stationId) 
	local stationMidPoint
	for node , terminal in pairs(freeNodesToTerminals) do 
		local p = util.nodePos(node)
		if stationMidPoint then 
			stationMidPoint = stationMidPoint + p
		else 
			stationMidPoint = p
		end 
	end 
	stationMidPoint = (1/util.size(freeNodesToTerminals))*stationMidPoint 
	
	local crossoverEdges = {} 
	local removedSignals = {}
	if not constructionUtil.searchForRailDepot(util.getStationPosition(stationId)) and not isCargo and not doNotRemoveCrossover then 
		 for edgeId, node in pairs(connectedEdges) do
			local edge = util.getEdge(edgeId)
			local otherNode = edge.node0 == node and edge.node1 or edge.node0 
			if #util.getTrackSegmentsForNode(node) > 2
			and #util.getTrackSegmentsForNode(otherNode) > 2 then 
				crossoverEdges[edgeId]=true 
				for __, nextEdgeId in pairs(util.getTrackSegmentsForNode(otherNode)) do
					local nextEdge = util.getEdge(nextEdgeId)
					local otherOtherNode = otherNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
					if #util.getTrackSegmentsForNode(otherOtherNode) > 2 and not crossoverEdges[nextEdgeId] then 
						crossoverEdges[nextEdgeId]=true
					end
					
				end
			end
		 end
	end
	
	local oldNodeToEdgeMap = {}
	local oldNodeToFullEdgeMap = {}
	 local replacedEdgesMap = {}
	-- remove the existing edges to avoid failing construction due to shifted peices  
	if not applyDummyShift then 
		for edgeId, node in pairs(connectedEdges) do
			local entity = util.copyExistingEdge(edgeId)  
			crossoverEdges[edgeId]= entity
			replacedEdgesMap[edgeId]=entity
			for i, edgeObj in pairs(entity.comp.objects) do 
				removedSignals[edgeObj[1]]=util.copyEdgeObject(edgeObj, edgeId, entity)
			end 
			local terminal = freeNodesToTerminals[node]
			if newTerminalConfiguration and newTerminalConfiguration.newConnectTerminals[terminal] then 
				trace("Suppressing signals for the edge at node", node, " for terminal",terminal)
				entity.comp.objects = {}
			end 
		end
	end 

	 local function getOrMakeReplacedEdge(edgeId) 
		if not replacedEdgesMap[edgeId] then 
			local newEdge = util.copyExistingEdge(edgeId, -1-#edgesToAdd)
			table.insert(edgesToAdd, newEdge)
			table.insert(edgesToRemove, edgeId)
			replacedEdgesMap[edgeId] = newEdge
		end 
		return replacedEdgesMap[edgeId]
	 end 
	 local function getOrMakeReplacedNode(node) 
		if not replacedNodesMap[node] then 
			local newNode = util.copyExistingNode(node, -1000-#nodesToAdd)
			table.insert(nodesToAdd, newNode)
			replacedNodesMap[node]=newNode
			trace("Replaced node",node,"with",newNode.entity)
			for i, seg in pairs(util.getSegmentsForNode(node)) do 
				local entity = getOrMakeReplacedEdge(seg) 
				if entity.comp.node0 == node then 
					entity.comp.node0 = newNode.entity 
				elseif entity.comp.node1 == node then
					entity.comp.node1 = newNode.entity
				else 
					trace("WARNING! Unexpected node",node, " nodes were",entity.comp.node0, entity.comp.node1)
				end 
			end 
		end 
		return replacedNodesMap[node]
	 end 
	 local adjustmentRange = params.stationLengthUpgrade and 500 or 200
	 if isCargo then 
		adjustmentRange = 150
	 end 
	 if safeMode then 
		adjustmentRange = 100
	 end 
	 local newEdges = {}
	 local foundCrossoverNode = false 
	 local foundShortConnectEdge = false
	 local nodesByTerminal = {}
	 local routeEdges = {}
	 local specialTreatmentApplied = {}
	 local replacedNodeSearchPositions = {}
	 local anglesToStations = {}
	 local edgesToSmooth = {}
	 local foundCrossoverNodeByTerminal = {}
	 for edge, node in pairs(connectedEdges) do
		if not freeNodesToTerminals[node] then 
			if stationParams.buildThroughTracks then 
				freeNodesToTerminals[node] = -1
			elseif util.tracelog then 
				debugPrint({freeNodesToTerminals=freeNodesToTerminals,node=node}) 
			end
		end
		if not newEdges[freeNodesToTerminals[node]] then 
			newEdges[freeNodesToTerminals[node]] = {}
		end
		
		if not oldNodeToEdgeMap[node] then 
			oldNodeToEdgeMap[node] = {}
			oldNodeToFullEdgeMap[node] = {}
		end
		local terminalId = freeNodesToTerminals[node]
		if not nodesByTerminal[terminalId] then 
			nodesByTerminal[terminalId]={}
		end 
		for i, edge2 in pairs(util.getSegmentsForNode(node)) do 
			if not util.contains(oldNodeToEdgeMap[node], edge2) and not util.isFrozenEdge(edge2) then 
				table.insert(oldNodeToEdgeMap[node], edge2) -- need to save off the map prior to removing the segment 
				table.insert(oldNodeToFullEdgeMap[node], util.getEdge(edge2)) -- need to save off the map prior to removing the segment 
				local nextNode = node 
				local nextEdge = edge2
				for j = 1, 3 do 
					nodesByTerminal[terminalId][nextNode]=true -- N.B. routeinfo may path through a slipswitch
					nextEdge = util.findNextEdgeInSameDirection(nextEdge, nextNode)
					if not nextEdge then 
						trace("No nextEdge found at ",nextNode)
						break 
					end
					nextNode = util.getOtherNodeForEdge(nextEdge, nextNode)
					--if not oldNodeToEdgeMap[nextNode] then 
					--	oldNodeToEdgeMap[nextNode] = {}
						oldNodeToFullEdgeMap[nextNode] = {}
					--end
					local isCrossover = #util.getSegmentsForNode(nextNode)==4
					trace("Inspecting nextNode",nextNode,"isCrossover?",isCrossover)
					if isCrossover then 
						oldNodeToEdgeMap[nextNode] = {}
					end 
					
					for k, edge3 in pairs(util.getSegmentsForNode(nextNode)) do 
						--if not util.contains(oldNodeToEdgeMap[nextNode], edge3) then 
					--		table.insert(oldNodeToEdgeMap[nextNode], edge3) -- need to save off the map prior to removing the segment 
							table.insert(oldNodeToFullEdgeMap[nextNode], util.getEdge(edge3)) 
							if isCrossover then 
								table.insert(oldNodeToEdgeMap[nextNode],edge3)
							end 
						--end 
					end
				end 
			end
		end
		local edgeFull = util.getEdge(edge)
		local otherNode = node == edgeFull.node0 and edgeFull.node1 or edgeFull.node0 
	 
		if #util.getTrackSegmentsForNode(otherNode)==4 then 
			if not (util.getComponent(otherNode, api.type.ComponentType.BASE_NODE).doubleSlipSwitch and constructionUtil.searchForRailDepot(util.nodePos(otherNode))) then 
				foundCrossoverNode  = true 
				foundCrossoverNodeByTerminal[freeNodesToTerminals[node]]=true
				trace("Found crossover node")
			end 
		end 
		if util.calculateSegmentLengthFromEdge(edgeFull) < 10 then 
			trace("Found short edge",edge)
			foundShortConnectEdge = true 
		end
		
		local otherStationsForNode = {}
		local intermediateStationLookup = {}
		local thisRouteInfo -- NB have route info potentially on both sides of the station, disambiguate by the one passing through our node
		for __, stopInfo in pairs(constructionUtil.lineManager.getNeighbouringStationStops(stationId, terminalId)) do
			local nextTerminalId = stopInfo.terminal
			local nextStationId = stopInfo.station
			local angleToStation = util.signedAngle(stationParallelTangent, util.getStationPosition(nextStationId) - position)
			table.insert(anglesToStations, angleToStation)
			local routeInfo 
			local routeInfo2
			if stopInfo.isPriorStop then 
				routeInfo = pathFindingUtil.getRouteInfo( nextStationId,stationId, nextTerminalId,terminalId-1) 
				if not routeInfo then 
					routeInfo = pathFindingUtil.getRouteInfo( nextStationId,stationId, nil,terminalId-1) 
					trace("No route info found, attempting again without their terminal, found?",routeInfo~=nil)
					
					
				end 
			else 
				routeInfo = pathFindingUtil.getRouteInfo(stationId, nextStationId, terminalId-1, nextTerminalId)
				if not routeInfo then 
					routeInfo = pathFindingUtil.getRouteInfo(stationId, nextStationId, terminalId-1 )
					trace("No route info found, attempting again without their terminal, found?",routeInfo~=nil)
				end
			end 
			
			--= pathFindingUtil.getRouteInfo(stationId, nextStationId, terminalId-1, nextTerminalId)
			--local routeInfo2 = pathFindingUtil.getRouteInfo( nextStationId,stationId, nextTerminalId,terminalId-1)
			--[[if not routeInfo then 
				routeInfo = routeInfo2
			end]]--
			trace("Attempted to find routeInfo for stationId, nextStationId, terminalId, nextTerminalId=",stationId, nextStationId, terminalId-1, nextTerminalId," routeInfo~=nil?",routeInfo~=nil,"for",stationName, "priorStop?",stopInfo.isPriorStop)
			if routeInfo then 
				local edge1 = routeInfo.edges[routeInfo.firstFreeEdge].edge 
				local edge2 = routeInfo.edges[routeInfo.lastFreeEdge].edge 
				local isNodeFirstEdge= node == edge1.node0 or node == edge1.node1
				local isNodeLastEdge =  node == edge2.node0 or node == edge2.node1 
				trace("Looking for node",node,"at firstFreeEdge:",routeInfo.edges[routeInfo.firstFreeEdge].id,"or lastFreeEdge:",routeInfo.edges[routeInfo.lastFreeEdge].id,"isNodeFirstEdge?",isNodeFirstEdge,"isNodeLastEdge?",isNodeLastEdge)
				if isNodeFirstEdge or isNodeLastEdge then 
					thisRouteInfo = routeInfo
					local intermediateStations = routeInfo.getAllStations()
					trace("Found our node at ",node," intermediateStations count?",#intermediateStations)
					if #intermediateStations > 2 then
						local stationToUse
						if isNodeFirstEdge then 
							stationToUse = intermediateStations[2]
						else 
							stationToUse = intermediateStations[#intermediateStations-1]
						end 
						trace("Found intermediate station to use=",stationToUse)
						intermediateStationLookup[nextStationId]=stationToUse
						otherStationsForNode[stationToUse]=true
					else 
						otherStationsForNode[nextStationId]=true
					end 
				else 
					trace("Did NOT Found our node at ",node)
				end 
			else 
				trace("WARNING! No route info found for stationId, nextStationId, terminalId, nextTerminalId=",stationId, nextStationId, terminalId, nextTerminalId)
			end 
			--if not nodesByTerminal then 
		--		nodesByTerminal[terminalId] = {}
		--	end
			if routeInfo then 
				nodesByTerminal[terminalId] = util.combineSets(routeInfo.getAllNodes(), 	nodesByTerminal[terminalId])
				local routeInfoEdges = routeInfo.getAllEdges()
				trace("The number of route Info edges was",util.size(routeInfoEdges))
				routeEdges = util.combineSets(routeEdges, routeInfoEdges)
			end 
			if routeInfo2 then 
				nodesByTerminal[terminalId] = util.combineSets(routeInfo2.getAllNodes(), 	nodesByTerminal[terminalId])
				routeEdges = util.combineSets(routeEdges, routeInfo2.getAllEdges())
			end 
		end 
		local isDeadEnd = #util.getSegmentsForNode(otherNode) == 1 
		local isCrossoverNode = #util.getSegmentsForNode(otherNode) == 4
		local wasSpecialTreatmentApplied = false
		if not isDeadEnd and (not crossoverEdges[edge] or not applyDummyShift) then 
		
			local oldNodePos = util.nodePos(node)
			local isDoubleTerminalUpgrade = newTerminalConfiguration and newTerminalConfiguration.newConnectTerminals[terminalId] 
			local isCrossoverNeedingFix = newTerminalConfiguration and isCrossoverNode and newTerminalConfiguration.oldToNewTerminals[terminalId] 
			trace("Inserting details of edge and node connection, edge=",edge," node=",node, " freeNodesToTerminals[node]=",freeNodesToTerminals[node],"isDoubleTerminalUpgrade?",isDoubleTerminalUpgrade,"isCrossoverNeedingFix?",isCrossoverNeedingFix,"terminalId=",terminalId)
			if params.stationLengthUpgrade or isDoubleTerminalUpgrade or isCrossoverNeedingFix then 
				local isNode0 =  node == edgeFull.node0 
				local tangentToUse = vec3.normalize(isNode0 and util.v3(edgeFull.tangent0) or -1*util.v3(edgeFull.tangent1))
				local expectedChange = 20 * stationLengthChange
				if isTerminus then 
					expectedChange = expectedChange * 2 
				end
				local changeVector = expectedChange * tangentToUse
				if isCrossoverNeedingFix then 
					local newTerminal = newTerminalConfiguration.oldToNewTerminals[terminalId]
					local terminalDiff = newTerminal-terminalId 
					trace("isCrossoverNeedingFix: got terminalDiff=",terminalDiff)
					if terminalId%2==0 or newTerminal%2 == 1 then 
						trace("Increasing terminaldiff by one for platform")
						terminalDiff = terminalDiff+1
					end
					local trackWidth = 5
					--local sign = isTerminus and 1 or -1
				--	changeVector = (terminalDiff*trackWidth)*util.rotateXY(tangentToUse, sign* math.rad(90))
					changeVector = (terminalDiff*trackWidth)*stationPerpTangent
				end
				local newPosition = oldNodePos + changeVector
				trace("Adjusting oldNodePos for station length upgrade, the expected new Postion is at", newPosition.x, newPosition.y, " from the old position",oldNodePos.x, oldNodePos.y)
				oldNodePos = newPosition
				local edgeLength = util.calculateSegmentLengthFromEdge(edgeFull)
				local shouldRemoveNextEdge =  edgeLength < 2*expectedChange
				if isDoubleTerminalUpgrade then 
					shouldRemoveNextEdge = edgeLength < 80 and #util.getSegmentsForNode(otherNode) == 2
				end 
				local otherNodePos = util.nodePos(otherNode)
				local naturalVector = otherNodePos - newPosition
				local angle = math.abs(util.signedAngle(naturalVector, tangentToUse))
				if angle > 0 then 
					local projectedRadius = util.distance(otherNodePos, newPosition) / math.sin(angle)
					trace("The projectedRadius was",projectedRadius," based on angle of ",math.deg(angle))
					if projectedRadius < 90 then 
						trace("Setting should remove next edge based on projectedRadius")
						shouldRemoveNextEdge = true 
					end 
				end 
				local needsSpecialTreatment = isCrossoverNeedingFix or params.stationLengthUpgrade
				if #util.getTrackSegmentsForNode(otherNode) ~= 2 or #util.getStreetSegmentsForNode(otherNode)>0 then 
					trace("Cannot remove next edge due to other segments")
					if shouldRemoveNextEdge then 
						needsSpecialTreatment = true 
					end
					shouldRemoveNextEdge = false 
				end
				if util.isDoubleSlipSwitch(otherNode) then 
					trace("Requires special treatment for doubleslipswitch")
					needsSpecialTreatment = true 
				end
				if shouldRemoveNextEdge then 
					local segs = util.getTrackSegmentsForNode(otherNode) 
					local otherEdge = edge == segs[1] and segs[2] or segs[1]
					local otherEdgeFull = util.getEdge(otherEdge)
					local nextIsNode0 = otherEdgeFull.node0 == otherNode
					local nextNode =  nextIsNode0 and otherEdgeFull.node1 or otherEdgeFull.node0 
					if util.isDoubleSlipSwitch(nextNode) or #util.getSegmentsForNode(nextNode) > 2 then 
						shouldRemoveNextEdge = false 
						needsSpecialTreatment = true 
						trace("Found double slip swictch at ",nextNode," forcing special") 
					end						
				end 
				local edgeToShift = edge 
				local shiftInNextNode = false
				if  shouldRemoveNextEdge and not util.contains(edgesToRemove, otherEdge) and not params.stationLengthUpgrade then 
					
					local segs = util.getTrackSegmentsForNode(otherNode) 
					local otherEdge = edge == segs[1] and segs[2] or segs[1]
					trace("Removeing the outer edge as well for recalculated edge",otherEdge)
					table.insert(edgesToRemove, otherEdge)
					local otherEdgeFull = util.getEdge(otherEdge)
					for i, obj in pairs(otherEdgeFull.objects) do 
						table.insert(edgeObjectsToRemove, obj[1])
					end 
					local nextIsNode0 = otherEdgeFull.node0 == otherNode
					local nextNode =  nextIsNode0 and otherEdgeFull.node1 or otherEdgeFull.node0 
					local nextTangent = util.v3(nextIsNode0 and otherEdgeFull.tangent1 or otherEdgeFull.tangent0)
					if isNode0 ~= nextIsNode0 then 
						trace("Inverting the tangent for the next edge")
						nextTangent = -1*nextTangent
					end
					local copiedEdge = crossoverEdges[edge]
					if isNode0 then 
						copiedEdge.comp.node1 = nextNode 
						util.setTangent(copiedEdge.comp.tangent1, nextTangent)
					else 
						copiedEdge.comp.node0 = nextNode 
						util.setTangent(copiedEdge.comp.tangent0, nextTangent)
					end 
					otherNode = nextNode
					edgeToShift = otherEdge
					local newDist = util.distBetweenNodes(copiedEdge.comp.node0 , copiedEdge.comp.node1)
					local p0 = util.nodePos(copiedEdge.comp.node0)
					local p1 = util.nodePos(copiedEdge.comp.node1)
					local t0 = util.v3(copiedEdge.comp.tangent0)
					local t1 = util.v3(copiedEdge.comp.tangent1)
					local edgeLength = util.calcEdgeLength(p0, p1, t0, t1)
					trace("The newDist was",newDist, "between ",copiedEdge.comp.node0 , copiedEdge.comp.node1," using edgeLength calculation was",edgeLength)
					
					local maxSwitchDist = 100  -- determined experimnetally, 100m seems to be the limit for a switch
					if isDoubleTerminalUpgrade and edgeLength >  maxSwitchDist then
						shiftInNextNode = true 
						trace("Setting shiftInNextNode to true for distance")
					end 
					if shiftInNextNode then 
						local targetDistance = isNode0 and maxSwitchDist or (edgeLength-maxSwitchDist)
						trace("Setting the target distance to ",targetDistance,"for solve")
						local s = util.solveForPositionHermiteLength(targetDistance, {
							p0 = p0,
							p1 = p1,
							t0 = t0,
							t1 = t1,						
						})
						local p = s.p1
						local newNode = util.newNodeWithPosition(p, -1000-#nodesToAdd)
						table.insert(nodesToAdd, newNode)
						local newEdge = util.copySegmentAndEntity(copiedEdge, -1-#edgesToAdd)
						newEdge.comp.objects = {}
						table.insert(edgesToAdd, newEdge)
						if isNode0 then 
							newEdge.comp.node0 = newNode.entity
							util.setTangent(newEdge.comp.tangent0, s.t2)
							util.setTangent(newEdge.comp.tangent1, s.t3)
							
							copiedEdge.comp.node1 = newNode.entity 
							util.setTangent(copiedEdge.comp.tangent0, s.t0)
							util.setTangent(copiedEdge.comp.tangent1, s.t1)
						else 
							newEdge.comp.node1 = newNode.entity
							util.setTangent(newEdge.comp.tangent0, s.t0)
							util.setTangent(newEdge.comp.tangent1, s.t1)
							
							copiedEdge.comp.node0 = newNode.entity 
							util.setTangent(copiedEdge.comp.tangent0, s.t2)
							util.setTangent(copiedEdge.comp.tangent1, s.t3)
						end 
						replacedNodeSearchPositions[newNode.entity]=p
						trace("Setup new entity for redicing length edge")
						local routeInfo = thisRouteInfo
						local idx = routeInfo and routeInfo.indexOf(edge)
						local isOutbound =  isNode0 --details.oldNode == edge1.node0 or details.oldNode == edge1.node1 
						if not idx then 
							trace("shiftInNextNode: WARNING! Could not find index for",edge," skipping")
						else 
							local edge = routeInfo.edges[idx].edge
							local nextEdge = routeInfo.edges[idx+1].edge
							local isBackwards = edge.node0 == nextEdge.node1 or edge.node0 == nextEdge.node0 
							local paramBool = isBackwards ~= isOutbound
							--local signalParam = paramBool and 0.1 or 0.9
							local signalParam = 0.5
							local left = isBackwards
							trace("shiftInNextNode: Building signal on newEdge",newEdge.entity," isOutbound?",isOutbound,"isBackwards",isBackwards,"left=",left,"signalParam=",signalParam)
							routeBuilder.buildSignal(edgeObjectsToAdd, newEdge, left, signalParam, bothWays)
						end
						if util.tracelog then 
							debugPrint({newEdge= newEdge, copiedEdge = copiedEdge})
						end
					end 
				end 
				
				
				
				
				if needsSpecialTreatment and not isDoubleTerminalUpgrade then 
					local alreadySeen =  { [edge] = true, [edgeToShift]=true }
					local maxDepth = 20
					local minLength = (params.targetStationLength or constructionUtil.getStationLength(stationId))/2 + 100
					local maxLength = minLength + adjustmentRange
					local firstNodePos = util.nodePos(node)
					local distFromFirstNode = util.distance(firstNodePos, stationMidPoint)
					local searchRange = maxLength - distFromFirstNode
					trace("At node",node,"searching at a distance of",searchRange,"maxLength=",maxLength)
					local filterFn = function(otherNode) 
						return not util.isFrozenNode(otherNode.id) and #util.getTrackSegmentsForNode(otherNode.id) > 0 
						and (#pathFindingUtil.findRailPathBetweenNodes(node, otherNode.id) > 0 
						or #pathFindingUtil.findRailPathBetweenNodes(otherNode.id, node) > 0)
					
					end 
					
					local nodes = util.searchForEntitiesWithFilter(firstNodePos, searchRange, "BASE_NODE", filterFn)
					trace("needsSpecialTreatment: Search for nearbyNodes found",util.size(nodes),"starting at ",node)
					for __, nodeEntity in pairs(nodes) do -- crossover nodes need to have exactly the same offset applied on all segments to avoid "Construction not possible"
						local nodeId = nodeEntity.id
						local segs = util.getTrackSegmentsForNode(nodeId)
						if #segs == 4 then 
							trace("Found crossoverNode at ",nodeId)
							for i, seg in pairs(segs) do 
								local edge = util.getEdge(seg)
								local otherNode = edge.node0 == nodeId and edge.node1 or edge.node0 
								local dist = util.distance(util.nodePos(otherNode), stationMidPoint)
								minLength = math.max(minLength, dist)
								trace("Found node",otherNode,"at a dist of",dist,"adjusting minLength to ",minLength)
								
							end 
						end 
					end 
					maxLength = math.max(maxLength, minLength+math.max(100, adjustmentRange/2))
					local thisAdjustmentRange = maxLength-minLength
					trace("adjusted maxLength to ",maxLength,"thisAdjustmentRange=",thisAdjustmentRange)
					
					local function shiftNextNode(node, edgeId, depth) 
						trace("Shift next node, got",node,edgeId," depth=",depth)
						if freeNodesToTerminals[node] or util.isNodeConnectedToFrozenEdge(node) then 
							trace("Aborting as go to the station node")
							return 
						end
						if #util.getStreetSegmentsForNode(node) > 0 and safeMode then 
							trace("Aborting as street segments found",node)
							return
						end 
						if #util.getTrackSegmentsForNode(node) == 0 then 
							trace("Aborting as no track segments found",node)
							return
						end 
						if depth > maxDepth then 
							--trace("Aborting as depth too high")
							--return
						end
						local newNode = getOrMakeReplacedNode(node)
						local changeVectorToUse = changeVector 
						local segs = util.getSegmentsForNode(node)
						--if depth >= maxDepth-5 then 
							--local factor = (maxDepth+1-depth)/5
							--trace("At depth ",depth," change factor was",factor)
							--changeVectorToUse = factor*changeVector
						--end 
						local nodePos = util.nodePos(node)
						local originalDist = util.distance(nodePos, stationMidPoint)
						local doubleTrackNodes = util.findDoubleTrackNodes(node)
						for i, otherNode in pairs(doubleTrackNodes) do -- try to keep double track nodes together
							nodePos = nodePos + util.nodePos(otherNode)
						end 
						nodePos = (1/(1+#doubleTrackNodes))*nodePos -- take the average
						
						local dist = util.distance(nodePos, stationMidPoint)
						--local distBucket = math.floor((dist+0.5)/10)*10 -- keep nearby nodes shifted by the same amount 
						trace("The node",node,"was at a distance of ",dist, "originalDist was",originalDist)
						--dist = distBucket
						if dist > maxLength then 
							trace("Aborting as beyond max length")
							return 
						end 
						local factor = math.min(1, 1-(dist-minLength)/thisAdjustmentRange)
						trace("The change factor was calculated as ",factor)
						changeVectorToUse = factor * changeVector
						
						local p = util.nodePos(node)+changeVectorToUse
						trace("Setting position on node",node,"to ",p.x,p.y, " the change vector length was",vec3.length(changeVectorToUse))
						util.setPositionOnNode(newNode, p)
						replacedNodeSearchPositions[newNode.entity]=p
						
						if #segs == 2 and false then 	
							local nextEdge = segs[1] == edgeId and segs[2] or segs[1] 
							if util.getEdgeLength(nextEdge) > 2*expectedChange then 
								trace("Ending shift at ",nextEdge)
								return 
							end 
						end 
						for i, seg in pairs(segs) do 
							if not alreadySeen[seg] and not util.isFrozenEdge(seg) then 
								if factor < 1 and #segs == 2 then 
									trace("Adding edge for somoothing",seg)
									local replacedEdge = replacedEdgesMap[edgeId]
									if replacedEdge then 
										edgesToSmooth[-replacedEdge.entity]=replacedEdge
									end 
								end 
								alreadySeen[seg]=true
								local edgeFull = util.getEdge(seg)
								local nextNode = edgeFull.node0 == node and edgeFull.node1 or edgeFull.node0 
								shiftNextNode(nextNode, seg, depth+1)
							end 
						end 
					end 
					shiftNextNode(otherNode, edgeToShift, 1)
					specialTreatmentApplied[terminalId]=true
					wasSpecialTreatmentApplied = true
				end 
			end 
			table.insert(newEdges[terminalId], { oldNode=node, oldNodePos = oldNodePos, oldEdge = edge, otherStationsForNode=otherStationsForNode, otherNode=otherNode, intermediateStationLookup = intermediateStationLookup, routeInfo = thisRouteInfo, wasSpecialTreatmentApplied = wasSpecialTreatmentApplied})
		end
	 end
	 if params.stationLengthUpgrade and not safeMode then 
		proposalUtil.applySmoothing(edgesToSmooth, nodesToAdd)
		--routeBuilder.applyTangentCorrection(edgesToSmooth, nodesToAdd)
	 end 
	 if util.tracelog then
		--debugPrint({routeEdges=routeEdges})
		trace("Found countRouteEdges=",util.size(routeEdges))
	 end 
	local minimalTrackChanges = false 
	local reallyMinimalTrackChanges = false 
	local disableDepotRemoval = false
	local disableSmoothing = params.doubleTerminalUpgrade
	local otherTownPosition = otherTown and util.v3fromArr(otherTown.position) or vec3.new(0,0,0)
	if isTerminus and not newTerminalConfiguration then 
		local angleToNewStation = util.signedAngle(stationParallelTangent, otherTownPosition-position)
		trace("The signed angle to the new town was",math.deg(angleToNewStation))
		local shouldShift = false 
		if angleToNewStation > 0 then 
			shouldShift = true 
			trace("Setting shouldshift to true initially")
			for i, otherAngle in pairs(anglesToStations) do 
				if otherAngle > angleToNewStation then 
					trace("Setting should shift to false as the other angle was higher",math.deg(otherAngle))
					shouldShift = false 
					break
				end 
			end
		end 
		if shouldShift then 
		--position = position -stationParallelTangent
			local offset = terminalsToAdd *5  + math.floor(terminalsToAdd/2)*5
			trace("Applying offset of ",offset)
			
			position = position - offset * stationPerpTangent
			local cols = newConstruction.transf:cols(3)
			cols.x = position.x 
			cols.y = position.y 
			cols.z = position.z
			newTerminalConfiguration = {}
			newTerminalConfiguration.newConnectTerminals = {}
			newTerminalConfiguration.oldToNewTerminals = {}
			for i = 1, #station.terminals do 
				if not util.isFreeTerminalOneBased(stationId, i) then 
					newTerminalConfiguration.oldToNewTerminals[i] = i + terminalsToAdd
				end 
			end 
			
		end
	end 
	
	if link then 
		local linkEdgeId = link.linkEdge
		local depotNode = link.depotNode
		trace("found depot link",linkEdgeId )  
		
		table.insert(edgesToRemove, linkEdgeId)
			  
		local linkEdge = util.getEdge(linkEdgeId)
		local nextNode = depotNode == linkEdge.node0 and linkEdge.node1 or linkEdge.node0
		local crossoverNode
		local nextEdgeId = linkEdgeId
		trace("looking for next segments for depot link, starting with ",nextEdgeId, "and ",nextNode)
		if #util.getTrackSegmentsForNode(nextNode) == 4 then 
			crossoverNode = nextNode
		end
		while not util.isTrackJoinJunction(nextNode) do 
			nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
			trace("inspecting edge in the depot link chain: ",nextEdgeId, " and node ",nextNode," is in routeEdges?",routeEdges[nextEdgeId])
			if not nextEdgeId or util.isFrozenEdge(nextEdgeId) then 
				break 
			end
			if routeEdges[nextEdgeId] then 
				trace("WARNING! Found a route edge in the edges, aborting")
				break
			end 
			local nextEdge = util.getEdge(nextEdgeId)
			nextNode = nextEdge.node0 == nextNode and nextEdge.node1 or nextEdge.node0 
			if #util.getTrackSegmentsForNode(nextNode) == 4 then 
				crossoverNode = nextNode
			end 
			table.insert(edgesToRemove, nextEdgeId) 
		end 
		 
		trace("upgradeStationAddTerminal: removing depot, found crossoverNode?", crossoverNode)
		if crossoverNode and not util.isNodeConnectedToFrozenEdge(crossoverNode) then 
			local otherSegs = {}
			local foundEdgeSeg = false 
			for i, seg in pairs(util.getTrackSegmentsForNode(crossoverNode)) do
				if not util.contains(edgesToRemove, seg) then 
					table.insert(otherSegs, seg)
					if crossoverEdges[seg] then 
						foundEdgeSeg = #otherSegs 
					end
				end 
			end		
			if #otherSegs ~= 2 then 
				debugPrint({otherSegs=otherSegs})
			end 
			assert(#otherSegs == 2)
			local seg1 = otherSegs[1]
			local seg2 = otherSegs[2]
			
			local entity1 = util.copyExistingEdge(seg1, -1-#edgesToAdd)
			if foundEdgeSeg then 
				seg1 = otherSegs[foundEdgeSeg]
				seg2 = seg1 == otherSegs[1] and otherSegs[2] or otherSegs[1]
				entity1 = crossoverEdges[seg1]
				trace("Setting the edge to keep in removing crossover node at",seg1, "connecting",entity1.comp.node0, entity1.comp.node1)
			end 
			
			local entity2 = util.copyExistingEdge(seg2, -1-#edgesToAdd)
			local length1 = vec3.length(entity1.comp.tangent0)
			local length2 = vec3.length(entity2.comp.tangent0)  
			local isNode0 = entity2.comp.node0 == crossoverNode
			local replacementNode = isNode0 and entity2.comp.node1 or entity2.comp.node0
			local replacementTangent = util.v3(isNode0 and entity2.comp.tangent1 or entity2.comp.tangent0)
			local keepIsNode0 = entity1.comp.node0 == crossoverNode
			if keepIsNode0 == isNode0 then 
				replacementTangent = -1*replacementTangent
			end 
			trace("Removing ",seg2," lengthening",seg1," the replacementNode=",replacementNode,"isNode0=",isNode0,"keepIsNode0=",keepIsNode0,"foundEdgeSeg?",foundEdgeSeg)
			local combinedLength = length1+length2 
			if keepIsNode0 then 
				entity1.comp.node0 = replacementNode
				util.setTangent(entity1.comp.tangent0, combinedLength*vec3.normalize(replacementTangent))
				util.setTangent(entity1.comp.tangent1, combinedLength*vec3.normalize(util.v3(entity1.comp.tangent1)))
			else 
				entity1.comp.node1 = replacementNode
				util.setTangent(entity1.comp.tangent1, combinedLength*vec3.normalize(replacementTangent))
				util.setTangent(entity1.comp.tangent0, combinedLength*vec3.normalize(util.v3(entity1.comp.tangent0)))
			end 
			
			
			for i, edgeObj in pairs(entity2.comp.objects) do 
				if edgeObj[1] > 0 and not util.contains(edgeObjectsToRemove, edgeObj[1]) then 
					trace("Removing edge object for ",edgeObj[1])
					table.insert(edgeObjectsToRemove, edgeObj[1])
				end 
				 
			end 
			if not foundEdgeSeg then 
				table.insert(edgesToRemove, seg1)
				table.insert(edgesToAdd, entity1)
			end
			table.insert(edgesToRemove, seg2)
			trace("Removed node at ",crossoverNode," setup entity1 connecting",entity1.comp.node0, entity1.comp.node1)
		end 
	 end 
--	local disableTerminalChanges = false -- isCargo and foundCrossoverNode and stationParams.tracks >= 2
	--local disableTerminalChanges = isCargo and foundCrossoverNode and stationParams.tracks >= 2 or params.stationLengthUpgrade
	local disableTerminalChanges = params.stationLengthUpgrade
	if foundCrossoverNode then 
		disableTerminalChanges = true 
		trace("Disabling terminal changes due to crossover node")
	end 
	local cleanupStreetGraph = false
	 local function reconectEdges(res)
	 
		trace("Begin reconnecting edges, disableTerminalChanges=",disableTerminalChanges,"minimalTrackChanges=",minimalTrackChanges,"reallyMinimalTrackChanges=",reallyMinimalTrackChanges)
--		util.cacheNode2SegMapsIfNecessary()
		
		util.lazyCacheNode2SegMaps()
		
		local stationRange =   constructionUtil.getStationLength(stationId)/2 + 100
		local maxAdjustmentRange = stationRange + adjustmentRange
		local nodesToAdd = {}
		local edgesToAdd = {}
		local edgeObjectsToAdd = {}
		local edgesToRemove = {} 
		local edgeObjectsToRemove = {}
		
		local depotLinkRemoved = false
		local depotConstruction
		local depotParams = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", true)
		
		local alreadySeen = {}
		local removedEdges = {}
		for edgeId, edge in pairs(crossoverEdges) do 
			removedEdges[edgeId] = true 
		end 
		
		local function nextEdgeId() 
			return -1-#edgesToAdd
		end
		local function nextNodeId()
			return -1000-#nodesToAdd
		end
		local replacedEdgesMap = {}
		local inverseReplacedEdgesMap = {}
		local replacedNodesMap = {} 
		local inverseReplacedNodesMap = {} 
		local newNodesMap = {}
		local newNodeToSegmentMap = {}
		local function getPositionOfNode(node) 
			if node < 0 then 
				return util.v3(newNodesMap[node].comp.position)
			end 
			return util.nodePos(node)
		end 
		local function findOtherSegmentsForNode(node, edgeIds) 
			if oldNodeToEdgeMap[node] then 
				local result = {}
				for i, edgeId in pairs(oldNodeToEdgeMap[node]) do
				
					if not util.contains(edgeIds, edgeId) then	
						trace("Found otherSegmentForNode edgeId=",edgeId," for node",node)
						--return {edgeId} -- only ever one because triple junction is not a feature 
						table.insert(result, edgeId) 
					end
				end
				return result
			end 
			trace("Did not find otherSegmentForNode for node",node, " falling back")
			return util.findOtherSegmentsForNode(node, edgeIds) 
		end 
		
		local function findNextEdgeInSameDirection(edgeId, node )
			if oldNodeToEdgeMap[node] then 
				local result = {}
				for i, edgeId2 in pairs(oldNodeToEdgeMap[node]) do
				
					if edgeId2 ~= edgeId and not crossoverEdges[edgeId2] then	
						trace("Found findNextEdgeInSameDirection edgeId=",edgeId," for node",node)
						return  edgeId2  -- only ever one because triple junction is not a feature 
					end
				end 
			end 
			if crossoverEdges[edgeId] then 
				trace("Finding next edge in same direction falling back to remaining connected edge. EdgeId=",edgeId," node=",node) 
				return util.getTrackSegmentsForNode(node)[1]
			end 
			return util.findNextEdgeInSameDirection(edgeId, node )
		end 
		
		
		local function getOrMakeReplacedEdge(edge)
			if replacedEdgesMap[edge] then 
				return replacedEdgesMap[edge]
			else 
				local newEdge
				if crossoverEdges[edge] then 
					
					newEdge = util.copySegmentAndEntity(crossoverEdges[edge] , nextEdgeId()) -- NB. make a copy in case we need to start over
--					newEdge.entity = nextEdgeId()		
					trace("Removed edge found, using copy, replacing", edge, " with ",newEdge.entity)
					local newEdgeObjects = {}
					for i, edgeObj in pairs(newEdge.comp.objects) do 
						local newEdgeObj =  removedSignals[edgeObj[1]]
						newEdgeObj.edgeEntity = newEdge.entity
						table.insert(edgeObjectsToAdd, newEdgeObj)
						table.insert(newEdgeObjects, { -#edgeObjectsToAdd, edgeObj[2] })
					end 
					newEdge.comp.objects = newEdgeObjects
					if newEdge.comp.node0 < 0 then 
						local node = util.getNodeClosestToPosition(replacedNodeSearchPositions[newEdge.comp.node0])
						trace("Setting the newNode on node0 to ",node, "was newEdge.comp.node0",newEdge.comp.node0)
						if not node then debugPrint(replacedNodeSearchPositions) end
						newEdge.comp.node0 = node 
					end 
					if newEdge.comp.node1 < 0 then 
						local node = util.getNodeClosestToPosition(replacedNodeSearchPositions[newEdge.comp.node1])
						trace("Setting the newNode on node1 to ",node, "was newEdge.comp.node1",newEdge.comp.node1)
						newEdge.comp.node1 = node 
					end 
					if util.tracelog then debugPrint({newEdge=newEdge}) end
				else 
					trace("Fresh edge found, replacing, edgeId=",edge)
					newEdge = util.copyExistingEdge(edge,nextEdgeId() )
					local newEdgeObjects = {}
					for i, edgeObj in pairs(newEdge.comp.objects) do
						table.insert(edgeObjectsToRemove, edgeObj[1])
						local newEdgeObj =  util.copyEdgeObject(edgeObj, newEdge.entity)
						table.insert(edgeObjectsToAdd, newEdgeObj)
						table.insert(newEdgeObjects, { -#edgeObjectsToAdd, edgeObj[2] })
					end
					newEdge.comp.objects = newEdgeObjects
					table.insert(edgesToRemove, edge)
				end 
			
				if replacedNodesMap[newEdge.comp.node0] then 
					trace("changing node0 on crossover edge", newEdge.entity, " while replacing ",edge," oldNode=",newEdge.comp.node0, " newNode=",replacedNodesMap[newEdge.comp.node0].entity)
					newEdge.comp.node0 = replacedNodesMap[newEdge.comp.node0].entity
					table.insert(newNodeToSegmentMap[newEdge.comp.node0], newEdge)
				end

				if replacedNodesMap[newEdge.comp.node1] then 
					trace("changing node1 on crossover edge", newEdge.entity, " while replacing ",edge," oldNode=",newEdge.comp.node1, " newNode=",replacedNodesMap[newEdge.comp.node1].entity)
					newEdge.comp.node1 = replacedNodesMap[newEdge.comp.node1].entity
					table.insert(newNodeToSegmentMap[newEdge.comp.node1], newEdge)
				end
				table.insert(edgesToAdd, newEdge)
				replacedEdgesMap[edge] = newEdge
				alreadySeen[edge] = true
				inverseReplacedEdgesMap[newEdge.entity]=edge
				trace("reconectEdges.getOrMakeReplacedEdge: replaced",edge, "with",newEdge.entity)
				
				return newEdge
			end
		
		end
		local function getOrMakeReplacedNode(node, position, newNodeId, overridePosition)
			if node < 0 then 
				local newNode =  newNodesMap[node]
				if overridePosition then 
					util.setPositionOnNode(newNode, position)
				end
				return newNode
			end
			if replacedNodesMap[node] then 
				local newNode =  replacedNodesMap[node]
				if overridePosition then 
					util.setPositionOnNode(newNode, position)
				end
				return newNode
			else 
				local newNode = util.copyExistingNode(node, nextNodeId())
				util.setPositionOnNode(newNode, position)
				table.insert(nodesToAdd, newNode)
			--	newNodeId2 = newNodeId2 -1
				replacedNodesMap[node]=newNode
				inverseReplacedNodesMap[newNode.entity]=node				
				newNodesMap[newNode.entity]=newNode 
				if not newNodeToSegmentMap[newNode.entity] then 
					newNodeToSegmentMap[newNode.entity]={}
				end
				for edgeId, entity in pairs(replacedEdgesMap) do -- slow but robust
					if entity.comp.node0 == node then 
						trace("Setting node on edge",edgeId,"from",node,"to",newNode.entity," at node0")
						entity.comp.node0 = newNode.entity
						table.insert(newNodeToSegmentMap[newNode.entity], entity)
					end 
					if entity.comp.node1 == node then 
						entity.comp.node1 = newNode.entity
						trace("Setting node on edge",edgeId,"from",node,"to",newNode.entity," at node1")
						table.insert(newNodeToSegmentMap[newNode.entity], entity)
					end 
				end 
				
				
				trace("added new node with id ",newNode.entity," to replace ",node," nodesAdded so far=",#nodesToAdd)
				return newNode
			end
		end
		
		local constructionId = res.resultEntities[1]
		local stationId = util.getConstruction(constructionId).stations[1]
		local highestTerminal = #util.getStation(stationId).terminals
		local newTerminal = highestTerminal
		local startFrom = highestTerminal-terminalsToAdd
		--[[if highestTerminal == 2 and isTerminus then -- upgrading terminus from 1 to 2 track gives the new terminal as 1 and old as 2
			newTerminal = 1
			startFrom = 2
			local newEdges2 = {}
			newEdges2[2] = newEdges[1]
			newEdges = newEdges2
		end]]--
		
		local newTerminalNodesMap = util.getTerminalToFreeNodesMapForStation(stationId)
		
		local newTerminalNode = util.getNodeClosestToPosition(otherTownPosition,newTerminalNodesMap[newTerminal])
		local newTerminalNodePos = util.nodePos(newTerminalNode)
		local freeNodesToTerminals = util.getFreeNodesToTerminalMapForStation(stationId) 
		
		local function getClosestTerminal(otherPosition) 
			local closestNewNode = util.getNodeClosestToPosition(otherPosition,util.getFreeNodesForConstruction(constructionId))
			local closestTerminal =  freeNodesToTerminals[closestNewNode]
			trace("The closestTerminal was ",closestTerminal)
			return closestTerminal
		end
		local oldToNewNodes = {}
		local oldToNewNodesOriginal = {}
		local oldToNewTerminals = {}
		local stationEdges = {}
		local emptyTerminals = {}
		for terminal = 1, highestTerminal do 
--			emptyTerminals[i] = #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, i-1) == 0
			emptyTerminals[terminal] = util.isFreeTerminalOneBased(stationId, terminal) 
		end 	
		
		for i = startFrom, 1 , -1 do
			local newDetails = newEdges[i]
			if not newDetails then goto continue end
			local originalNodes = {}
			for __ , details in pairs(newDetails) do
				if not originalNodes[details.oldNode] then 
					originalNodes[details.oldNode]=true 
				end
			end
			trace("Check for details at terminal ",i," newDetails=",newDetails, " isTerminus=",isTerminus, " newTerminal=",newTerminal, " size of newDetails is ",util.size(originalNodes))
			
			for __ , details in pairs(newDetails) do
				stationEdges[details.oldEdge]=true
				if alreadySeen[details.oldNode] then goto continue end -- happens if two tracks connect to the same node
				alreadySeen[details.oldNode] = true
				local newNode = util.findFreeNodeForConstructionWithPosition(constructionId, details.oldNodePos, 2)
				trace("Looking for a node for construction",constructionId," at ",details.oldNodePos.x, details.oldNodePos.y," found",newNode)
				if not newNode then 
					local terminalToNodes = util.getTerminalToFreeNodesMapForStation(stationId) 
					
					local nodes = terminalToNodes[i]
					newNode = util.getNodeClosestToPosition( details.oldNodePos, nodes)
					trace("WARNING! No node found at expected location, attempting to use from terminalMap based on terminal=",i,"newNode=",newNode)
				end 
				oldToNewNodesOriginal[details.oldNode] = newNode
				local newNodePos = util.nodePos(newNode)
				local newTerminalNode = util.getNodeClosestToPosition(otherTownPosition,newTerminalNodesMap[newTerminal])
				local newTerminalNodePos = util.nodePos(newTerminalNode)
				if util.distance(newNodePos, newTerminalNodePos) < 80 and not newTerminalConfiguration then -- its on the same side
					
					local terminalId = freeNodesToTerminals[newNode]
					trace("examing terminal nodes due to proximity at terminal ", terminalId," at position ", details.oldNodePos.x, details.oldNodePos.y, " newNode=",newNode)
					local otherStationId 
					for __, stopInfo in pairs(constructionUtil.lineManager.getNeighbouringStationStops(stationId, terminalId)) do
						local nextStationId = stopInfo.station
						if details.intermediateStationLookup[stopInfo.station] then 
							nextStationId = details.intermediateStationLookup[stopInfo.station]
							trace("Using alternative station instead from lookup from",stopInfo.station," to ",nextStationId)
						end
						local connectNode = details.otherNode
						local nodePairs = util.findShortestDistanceNodePairs(newTerminalNodesMap[terminalId], util.getAllFreeNodesForStation(nextStationId))
						trace("Inspecting nextStationId=",nextStationId, " the newNode was",newNode, " is seen for this?",details.otherStationsForNode[nextStationId] )
						if util.tracelog then debugPrint({nodePairs=nodePairs}) end
						local nodePair = nodePairs[1]
						
						if isCargo and newNode ~= nodePair[1]   then 
							for j = 2, #nodePairs do  
								local nodePair2 = nodePairs[j]
								local scoreDiff=  nodePair2.scores[1]-nodePair.scores[1]
								local isForNewNode = newNode== nodePair2[1]
								trace("Inspecting the other node pair the scoreDiff was",scoreDiff, "isForNewNode?",isForNewNode)
								if scoreDiff < 80 and isForNewNode then -- with route combination we might end up choosing the other node
									trace("Swapping to consider the proximity node")
									nodePair = nodePair2
									break
								end
							end
						end
						
						local otherStationPosition = util.nodePos(nodePair[2]) --util.nodePos(util.getComponent(nextStationId, api.type.ComponentType.STATION).terminals[1].vehicleNodeId.entity)
						--if newNode == util.getNodeClosestToPosition(otherStationPosition,newTerminalNodesMap[terminalId]) then -- chance for 
						local isProximityNode = details.otherStationsForNode[nextStationId]
						trace("isProximityNode? ", isProximityNode, "newNode == nodePair[1]?",newNode == nodePair[1], "util.size(originalNodes)==1",  util.size(originalNodes)==1)
						if  isProximityNode then 
						
							local correctedOtherTownPosition = otherTownPosition
							--[[if isTerminus then
								local vector = vec3.normalize(newTerminalNodePos - otherTownPosition)
								local dist = util.distance(newTerminalNodePos, otherTownPosition)
								local tangent= vec3.normalize(util.v3(newEdge.comp.node0 == details.oldNode and newEdge.comp.tangent1 or newEdge.comp.tangent0))
								local tangent2= vec3.normalize(util.v3(newEdge.comp.node1 == details.oldNode and newEdge.comp.tangent1 or newEdge.comp.tangent0))
								local angle = util.signedAngle(vector, tangent)
								local angle2 = util.signedAngle(vector, tangent2)
								
								correctedOtherTownPosition = util.hermite(0.2, newTerminalNodePos, 1.5*dist*tangent, otherTownPosition, 1.5*dist*vector).p
								trace("Angle of heading was",math.deg(angle), " angle2 was",math.deg(angle2)," correctedTownPosition=",correctedOtherTownPosition.x,correctedOtherTownPosition.y)
							end]]--
							trace("The node was close to the station ",newNode)
							local nextNodePos = util.nodePos(util.getNextFrozenNode(newNode))
							local intoStationTangent = nextNodePos - newNodePos
							local outStationTangent = -1*intoStationTangent
							local angleToOtherTown = math.abs(util.signedAngle(outStationTangent, correctedOtherTownPosition-newNodePos))
							local angleToOtherStation = math.abs(util.signedAngle(outStationTangent, otherStationPosition-newNodePos))
						
							trace("The signed angle to the other station was",math.deg(angleToOtherTown)," and to town ",math.deg(angleToOtherStation))
							local intoStationOffset1 = 1
							local intoStationOffset2 = 1
							if angleToOtherStation > math.rad(90) and angleToOtherStation < math.rad(179) then 
								local behindAngle = angleToOtherStation-math.rad(90)
								intoStationOffset1 = intoStationOffset1 + params.trackWidth*math.tan(behindAngle)
								trace("Setting the intoStationOffset1 for collision test to ",intoStationOffset1)
							end 
							if angleToOtherTown > math.rad(90) and angleToOtherTown < math.rad(179) then 
								local behindAngle = angleToOtherTown-math.rad(90)
								intoStationOffset2 = intoStationOffset2 + params.trackWidth*math.tan(behindAngle)
								trace("Setting the intoStationOffset2 for collision test to ",intoStationOffset2)
							end 
							local newNodePos2 = intoStationOffset2*vec3.normalize(intoStationTangent)+newNodePos 
							local newTerminalNodePos2 = intoStationOffset1*vec3.normalize(intoStationTangent)+newTerminalNodePos
						
							trace("checking for collision between",newNodePos.x,newNodePos.y, " - ",otherStationPosition.x,otherStationPosition.y, " and ",newTerminalNodePos.x, newTerminalNodePos.y," and ",correctedOtherTownPosition.x, correctedOtherTownPosition.y)
							-- if the vector to the other station is more than 90 degrees offset then need to check for a collision "behind" the entrance
							local condition =  util.checkFor2dCollisionBetweenPoints(newNodePos, otherStationPosition, newTerminalNodePos, correctedOtherTownPosition, true) 
							or  util.checkFor2dCollisionBetweenPoints(newNodePos2, otherStationPosition, newTerminalNodePos, correctedOtherTownPosition, true) 
							or  util.checkFor2dCollisionBetweenPoints(newNodePos, otherStationPosition, newTerminalNodePos2, correctedOtherTownPosition, true) 
							or  getClosestTerminal(otherStationPosition) == highestTerminal and getClosestTerminal(correctedOtherTownPosition) == 1
							if condition and isCargo then 
								local angleToOtherTown =  util.signedAngle(outStationTangent, correctedOtherTownPosition-newNodePos)
								local angleToOtherStation =  util.signedAngle(outStationTangent, otherStationPosition-newNodePos)
								local differenceAngle = math.abs(angleToOtherTown-angleToOtherStation)
								trace("Double checking if terminal change needed, differenceAngle=",math.deg(differenceAngle),"params.allowCargoTrackSharing?",params.allowCargoTrackSharing)
								if params.allowCargoTrackSharing and differenceAngle < math.rad(30) then 
									trace("Overriding the track change to false")
									condition = false
								end 
							end 
							if condition then 
								local adjacentTerminal = newTerminal-1
								trace("swapping terminal nodes, starting with ",adjacentTerminal, " to",terminalId)
								for j = adjacentTerminal, terminalId, -1 do -- need to "walk" the terminal changes down from the highest terminal
									if not emptyTerminals[j] and not (isCargo and foundCrossoverNodeByTerminal[j]) then 
										local temp = newNode
										local oldTerminal = j
										newNode = newTerminalNode
										newTerminalNode = temp
										oldToNewTerminals[oldTerminal]=newTerminal
										trace("swapping terminal nodes, old terminal=",oldTerminal, " new terminal=",newTerminal)
										--table.insert(workItems, function() lineManager.changeTerminal(stationId, terminalId, newTerminal, function(res, success) workComplete=true end)end)
										local newTerminalCopy = newTerminal
										local stopAndLine = constructionUtil.lineManager.stopIndex(stationId, oldTerminal)
										table.insert(changeLineCallbacks, 1, function() constructionUtil.lineManager.changeTerminal(stationId, oldTerminal, newTerminalCopy, wrappedCallback, stopAndLine) end)
										table.insert(changeLineCallbackTerminals, 1, newTerminalCopy)
										emptyTerminals[oldTerminal] = true 
										emptyTerminals[newTerminal] = false 
										for m = newTerminal, 1, -1 do 
											if emptyTerminals[m] then 
												newTerminal = m -- reset this as the "free" terminal
												break
											end 
										end
									
										
									end
								end
								--[[
								local temp = newNode
								newNode = newTerminalNode
								newTerminalNode = newNode
								oldToNewTerminals[terminalId]=newTerminal
								--table.insert(workItems, function() lineManager.changeTerminal(stationId, terminalId, newTerminal, function(res, success) workComplete=true end)end)
								local newTerminalCopy = newTerminal
								table.insert(changeLineCallbacks, 1, function() constructionUtil.lineManager.changeTerminal(stationId, terminalId, newTerminalCopy, wrappedCallback) end)
								table.insert(changeLineCallbackTerminals, 1, newTerminalCopy)
								newTerminal = terminalId -- reset this as the "free" terminal
								--]]
								break
							end
						else 
							trace("The new node",newNode," was not the closest to the other station position",nodePair[1],nodePair[2],util.getNodeClosestToPosition(otherStationPosition,newTerminalNodesMap[terminalId]))
						end
					end
				else 
					trace("Was not a proximity node, no action taken, dist between ",newTerminalNode, " and ", newNode," was ", util.distance(newNodePos, newTerminalNodePos))
				end
				oldToNewNodes[details.oldNode]=newNode
			end 
			::continue::
		end
		if disableTerminalChanges then 
			trace("Disable terminal changes is true, resetting the oldToNewTerminals")
			oldToNewNodes = oldToNewNodesOriginal
			oldToNewTerminals = {}
			changeLineCallbacks = {}
		end
		
		if newTerminalConfiguration then 
			oldToNewTerminals = newTerminalConfiguration.oldToNewTerminals
			for oldTerminal, newTerminal in pairs(oldToNewTerminals) do 
				local stopAndLine = constructionUtil.lineManager.stopIndex(stationId, oldTerminal)
				table.insert(changeLineCallbacks, function() constructionUtil.lineManager.changeTerminal(stationId, oldTerminal, newTerminal, wrappedCallback, stopAndLine) end)
			end 
			if newTerminalConfiguration.isTerminus then 
				trace("Inserting callback for crossover")
				table.insert(changeLineCallbacks, function() routeBuilder.buildCrossoverForDoubleTerminals(params, stationId, wrappedCallback) end)
			end 
		end 
		
		local terminalChanges = util.size(oldToNewTerminals)
		if params.isCargo and terminalChanges > 0 and terminalChanges < highestTerminal-1 and  applyDummyShift  then -- check we have not tried to move one half of crossover 
			trace("Inspecting cargo terminal changes for crossover, there were", terminalChanges, " terminalChanges")
			 
			for old, new in pairs(util.deepClone(oldToNewTerminals)) do 
				 
				for __, newDetails in pairs(newEdges[old]) do 
					local originalNode = newDetails.oldNode 
					local segs = util.deepClone(util.getTrackSegmentsForNode(originalNode))
					 
					for i, seg in pairs(segs) do 
						local edge = util.getEdge(seg) 
						local nextNode = originalNode == edge.node0 and edge.node1 or edge.node0 
						local nextSegs = util.deepClone(util.getTrackSegmentsForNode(nextNode))
						local cancelled = false 
						if #nextSegs==4 then 
							trace("Discovered possible crossover at ",nextNode)
							for j, nextSeg in pairs(nextSegs) do 
								local nextEdge = util.getEdge(nextSeg)
								local nextNode2 = nextNode == edge.node0 and edge.node1 or edge.node0 
								if oldToNewNodes[nextNode2] then 
									local terminal= freeNodesToTerminals[node]
									local newTerminal = oldToNewTerminals[terminal]
									trace("Discovered it WAS a crossover at terminal", terminal, " newTerminal=",newTerminal)
									if not newTerminal then 
										trace("Cancelling terminal change") 
										oldToNewTerminals[old]=nil 
										oldToNewNodes[originalNode]=oldToNewNodesOriginal[originalNode]
										local changeTerminalIdx = util.indexOf(changeLineCallbackTerminals, new)
										trace("Removing ",changeTerminalIdx," of ",#changeLineCallbacks, " for ",new)
										if changeTerminalIdx ~= -1 then -- removed already
											table.remove(changeLineCallbacks, changeTerminalIdx)
											table.remove(changeLineCallbackTerminals, changeTerminalIdx)
										end
										cancelled = true
										break
									end
									
								end
							end
						end
						if cancelled then 
							break 
						end
					end
				end
			end 
		
		end
		
		if util.tracelog then debugPrint({station = stationName ,oldToNewTerminals=oldToNewTerminals, oldToNewNodes=oldToNewNodes, foundCrossoverNodeByTerminal=foundCrossoverNodeByTerminal}) end
		local lowestNewTerminal  = math.huge
		local lowestOldTerminal  = math.huge
		local doubleTerminalNodes = {}
		local nodesExpectedToChange = {}
		for oldTerminal, newTerminal in pairs(oldToNewTerminals) do 
			lowestNewTerminal = math.min(lowestNewTerminal, newTerminal)
			lowestOldTerminal = math.min(lowestOldTerminal, oldTerminal)
			nodesExpectedToChange = util.combineSets(nodesExpectedToChange, nodesByTerminal[oldTerminal])
			if newTerminalConfiguration and newTerminalConfiguration.newConnectTerminals[oldTerminal] then 
				doubleTerminalNodes = util.combineSets(doubleTerminalNodes, nodesByTerminal[oldTerminal])
			end 			
			
		end 
		for i = startFrom, -1 , -1 do -- NB go to -1 as the special terminal for through tracks
			local newDetails = newEdges[i]
			trace("Change track loop: Insepcting details for terminal at ",i, "newDetails=",newDetails)
			if not newDetails then goto continue2 end
			for __ , details in pairs(newDetails) do
				trace("Begin inspecting details for original edge",details.oldEdge, "for terminal at ",i,"wasSpecialTreatmentApplied?",details.wasSpecialTreatmentApplied)
				if alreadySeen[details.oldEdge] then 
					--trace("Skipping as already seen ", details.oldEdge)
					--goto continue3
				end
				local newNode = oldToNewNodes[details.oldNode]
				if isCargo and foundCrossoverNodeByTerminal[i] then 
					trace("Overriding the node choice for crossover at",i)
					newNode = oldToNewNodesOriginal[details.oldNode]
				end 
				local terminalGap = 0
				if oldToNewTerminals[i] then 
					local newTerminal = oldToNewTerminals[i]
					terminalGap = math.abs(i-newTerminal)
					newNode = util.getNodeClosestToPosition(details.oldNodePos,newTerminalNodesMap[newTerminal])
					trace("Terminal was changed from ",i, " to ",newTerminal," getting node at ",newNode, "terminalGap=",terminalGap)
				end
				if not newNode then 
					newNode =  util.getNodeClosestToPosition(details.oldNodePos,newTerminalNodesMap[i])
				end
				trace("At terminal ",i," replacing ",details.oldNode," with ",newNode)
				
				local newNodePos = util.nodePos(newNode)
				local trackChangeVector = newNodePos-details.oldNodePos
				if i == lowestOldTerminal and params.doubleTerminalUpgrade then 
					trace("Reducing scope of track change vector for new terminal at ",i)
					trackChangeVector = 0.5*trackChangeVector -- needed to smooth out changes and avoid colliding with other route
				end 
				
				local trackChangeLength = vec3.length(trackChangeVector)
				trace("The trackChangeLength was ",trackChangeLength)
				local perpSign = 1
				local outboundTangent = util.getDeadEndNodeDetails(newNode).tangent 
				local testP = util.nodePointPerpendicularOffset(details.oldNodePos, perpSign*outboundTangent, trackChangeLength)
				local testP2 = util.nodePointPerpendicularOffset(details.oldNodePos, -perpSign*outboundTangent, trackChangeLength)
				if util.distance(newNodePos, testP2) < util.distance(newNodePos,testP) then 
					perpSign = -perpSign
				end
				
				local terminalNode = newNode 
				if specialTreatmentApplied[i]  and not details.wasSpecialTreatmentApplied then 
					trace("Overriding the wasSpecialTreatmentApplied at",i)
					details.wasSpecialTreatmentApplied = true 
				end
				local trackVectorChanged = trackChangeLength  > 0.1 and not details.wasSpecialTreatmentApplied
				local multiNodeReplacement =  trackVectorChanged and not reallyMinimalTrackChanges
				trace("At terminal ",i," replacing ",details.oldNode," with ",newNode, " trackChangeLength=",trackChangeLength,"multiNodeReplacement=",multiNodeReplacement, " reallyMinimalTrackChanges=",reallyMinimalTrackChanges)
				local newNodeId =-1000*(#nodesToAdd+1)-100000*#edgesToAdd
				--local newNodeId2 = newNodeId
				trace("Initialisaing newNodeId to ",newNodeId)
				local secondNode
				local isNode0 
				local foundDoubleSlipSwitch = false
				local foundDoubleSlipSwitchMain = false 
				local foundDoubleSlipSwitchSecond = false 
				if util.isFrozenEdge(details.oldEdge) and not crossoverEdges[details.oldEdge] then 
					trace("WARNING! Found frozen edge",details.oldEdge, " skipping")
					goto continue3
				end 
				 
				local newEdge = getOrMakeReplacedEdge(details.oldEdge)
				local deflectionAngle = util.signedAngle(newEdge.comp.tangent0, newEdge.comp.tangent1)
				local oldEdge = details.oldEdge
				 
			 
				if newEdge.comp.node0 == details.oldNode or newEdge.comp.node0 == newNode then
					isNode0 = true
					newEdge.comp.node0 = newNode
					if not newNodeToSegmentMap[newEdge.comp.node0] then 
						newNodeToSegmentMap[newEdge.comp.node0] = {}
					end
					table.insert(newNodeToSegmentMap[newEdge.comp.node0],newEdge)
					secondNode = newEdge.comp.node1
					if multiNodeReplacement  and newEdge.comp.node1 > 0  then
					--	if replacedNodesMap[newEdge.comp.node1] then 
						--	newEdge.comp.node1 = replacedNodesMap[newEdge.comp.node1].entity
					--	else 
						--	newEdge.comp.node1 = newNodeId
					--	end 
						newEdge.comp.node1 = getOrMakeReplacedNode(newEdge.comp.node1, util.nodePos(newEdge.comp.node1), newNodeId).entity
						table.insert(newNodeToSegmentMap[newEdge.comp.node1],newEdge)
						trace("Setting the node1 on edge",newEdge.entity, " to ",newEdge.comp.node1)
					end
				else 
					assert(newEdge.comp.node1 == details.oldNode or newEdge.comp.node1 == newNode)
					isNode0 = false
					newEdge.comp.node1 = newNode
					if not newNodeToSegmentMap[newEdge.comp.node1] then 
						newNodeToSegmentMap[newEdge.comp.node1] = {}
					end
					table.insert(newNodeToSegmentMap[newEdge.comp.node1],newEdge)
					secondNode = newEdge.comp.node0
					if multiNodeReplacement and newEdge.comp.node0 > 0   then
					--	if replacedNodesMap[newEdge.comp.node0] then 
					--		newEdge.comp.node0 = replacedNodesMap[newEdge.comp.node0].entity
					--	else 
					--		newEdge.comp.node0 = newNodeId
					--	end 
						newEdge.comp.node0 = getOrMakeReplacedNode(newEdge.comp.node0, util.nodePos(newEdge.comp.node0), newNodeId).entity
						table.insert(newNodeToSegmentMap[newEdge.comp.node0],newEdge)
						trace("Setting the node0 on edge",newEdge.entity, " to ",newEdge.comp.node0)
					end
				 
				end
				local newTerminalConnectEntity
				if newTerminalConfiguration and newTerminalConfiguration.newConnectTerminals[i] then 
					local entity2 = util.copySegmentAndEntity(newEdge, -1-#edgesToAdd)
					table.insert(edgesToAdd, entity2)
					local connectTerminal = newTerminalConfiguration.newConnectTerminals[i]
					local connectNode = util.getNodeClosestToPosition(details.oldNodePos,newTerminalNodesMap[connectTerminal])
					if isNode0 then 
						entity2.comp.node0 = connectNode
					else 
						entity2.comp.node1 = connectNode
					end 
					trace("Setup the terminal connection edge between nodes",entity2.comp.node0, entity2.comp.node1)
					newTerminalConnectEntity = entity2
				end 
				if isNode0 then 
					deflectionAngle = -deflectionAngle
				end
				trace("The deflectionAngle was",math.deg(deflectionAngle),"isNode0=",isNode0)
				if rotateTrackVector then 
					trackChangeVector = util.rotateXY(trackChangeVector, deflectionAngle)
				end 
				local originalTrackChangeVector = trackChangeVector
				if multiNodeReplacement  and secondNode > 0 and util.getComponent(secondNode, api.type.ComponentType.BASE_NODE).doubleSlipSwitch then 
					trace("Met condition for second node replacement but suppressing")	
					if false then 
						foundDoubleSlipSwitch = true
						foundDoubleSlipSwitchMain = true
						local nextEdgeId = findNextEdgeInSameDirection(details.oldEdge, secondNode )
						local nextEdge = util.getEdge(nextEdgeId)
						oldEdge = nextEdgeId
						secondNode = secondNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
						if not alreadySeen[nextEdgeId] and not removedEdges[nextEdgeId] then 
							table.insert(edgesToRemove, nextEdgeId)
							alreadySeen[nextEdgeId]=true
							removedEdges[nextEdgeId]=true
						end
						local endTangent = util.v3(secondNode == nextEdge.node0 and nextEdge.tangent0 or nextEdge.tangent1)
						local dist = util.distance(details.oldNodePos, util.nodePos(secondNode))
						if isNode0 then 
							util.setTangent(newEdge.comp.tangent0, dist*vec3.normalize(util.v3(newEdge.comp.tangent0)))
							util.setTangent(newEdge.comp.tangent1, dist*vec3.normalize(endTangent))
						else 
							util.setTangent(newEdge.comp.tangent1, dist*vec3.normalize(util.v3(newEdge.comp.tangent1)))
							util.setTangent(newEdge.comp.tangent0, dist*vec3.normalize(endTangent))
						end
					end
				end
				
				
				local otherSegs =  findOtherSegmentsForNode(details.oldNode, {   details.oldEdge} ) 
				local secondEdge
				local thirdNode
				trace("There were ",#otherSegs," otherSegs")
				if #otherSegs == 1 then
					secondEdge = otherSegs[1]
					local secondNewEdge = getOrMakeReplacedEdge(secondEdge)
					local isNode0
					if secondNewEdge.comp.node0 == details.oldNode or secondNewEdge.comp.node0 == newNode then
						isNode0 = true
						secondNewEdge.comp.node0 = newNode
						if not newNodeToSegmentMap[secondNewEdge.comp.node0] then 
							newNodeToSegmentMap[secondNewEdge.comp.node0] = {}
						end
						table.insert(newNodeToSegmentMap[secondNewEdge.comp.node0],secondNewEdge)
						thirdNode = secondNewEdge.comp.node1
						if multiNodeReplacement and secondNewEdge.comp.node1 > 0   then
							--if replacedNodesMap[secondNewEdge.comp.node1] then 
							--	secondNewEdge.comp.node1 = replacedNodesMap[secondNewEdge.comp.node1].entity
							--else 
							--	secondNewEdge.comp.node1 = newNodeId-1
							--end 
							secondNewEdge.comp.node1 = getOrMakeReplacedNode(secondNewEdge.comp.node1, util.nodePos(secondNewEdge.comp.node1), newNodeId-1).entity
							table.insert(newNodeToSegmentMap[secondNewEdge.comp.node1],secondNewEdge)
							trace("Setting the node1 on secondNewEdge",secondNewEdge.entity, " to ",secondNewEdge.comp.node1)
						end
					else 
						isNode0 = false
						secondNewEdge.comp.node1 = newNode
						if not newNodeToSegmentMap[secondNewEdge.comp.node1] then 
							newNodeToSegmentMap[secondNewEdge.comp.node1] = {}
						end
						table.insert(newNodeToSegmentMap[secondNewEdge.comp.node1],secondNewEdge)
						thirdNode = secondNewEdge.comp.node0
						if multiNodeReplacement and secondNewEdge.comp.node0 > 0     then
							--if replacedNodesMap[secondNewEdge.comp.node0] then 
							--	secondNewEdge.comp.node0 = replacedNodesMap[secondNewEdge.comp.node0].entity
							--else 
							--	secondNewEdge.comp.node0 = newNodeId-1
							--end 
							secondNewEdge.comp.node0 = getOrMakeReplacedNode(secondNewEdge.comp.node0, util.nodePos(secondNewEdge.comp.node0), newNodeId-1).entity
							table.insert(newNodeToSegmentMap[secondNewEdge.comp.node0],secondNewEdge)
							trace("Setting the node0 on secondNewEdge",secondNewEdge.entity, " to ",secondNewEdge.comp.node0)
						end
					end 
					if multiNodeReplacement  and thirdNode > 0 and util.getComponent(thirdNode, api.type.ComponentType.BASE_NODE).doubleSlipSwitch then 
						
						trace("reconectEdges: Hit suspect condition - suppressing")
						if false then -- need to figure out why this was need, seems to just cause problems, maybe related to the change to preemptive removal
							foundDoubleSlipSwitch = true
							foundDoubleSlipSwitchSecond = true
							local nextEdgeId = findNextEdgeInSameDirection( secondEdge,thirdNode)
							local nextEdge = util.getEdge(nextEdgeId)
							thirdNode = thirdNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
							if not alreadySeen[nextEdgeId] and not removedEdges[nextEdgeId] then 
								table.insert(edgesToRemove, nextEdgeId)
								alreadySeen[nextEdgeId]=true
								removedEdges[nextEdgeId]=true
							end
							secondEdge = nextEdgeId
							local endTangent = util.v3(thirdNode == nextEdge.node0 and nextEdge.tangent0 or nextEdge.tangent1)
							local dist = util.distance(details.oldNodePos, util.nodePos(thirdNode))
							if isNode0 then 
								util.setTangent(secondNewEdge.comp.tangent0, dist*vec3.normalize(util.v3(secondNewEdge.comp.tangent0)))
								util.setTangent(secondNewEdge.comp.tangent1, dist*vec3.normalize(endTangent))
							else 
								util.setTangent(secondNewEdge.comp.tangent1, dist*vec3.normalize(util.v3(secondNewEdge.comp.tangent1)))
								util.setTangent(secondNewEdge.comp.tangent0, dist*vec3.normalize(endTangent))
							end
						end
					end
				end
				--nodesToRemove[#nodesToRemove+1]=details.oldNode
				
				if multiNodeReplacement and not details.wasSpecialTreatmentApplied  then
					local range = isTerminus and 500 or 200
					depotConstruction = not disableDepotRemoval and searchForDepotOfType(details.oldNodePos, "train",range)
					if depotConstruction then
						trace("found depot construction, checking distance",depotConstruction)
						local depotPos = util.getConstructionPosition(depotConstruction) 
						local distNew = util.distance(util.nodePos(newNode), depotPos)
						local distOld = util.distance(details.oldNodePos, depotPos) 
						if foundDoubleSlipSwitch or distNew > distOld or isTerminus then -- moved away from the depot
							trace("distance is greater, looking for link, distNew=",distNew,"distOld=",distOld," doubleSlipSwitch?",foundDoubleSlipSwitch)
							local link = util.findDepotLink(depotConstruction)
							if link then 
								local linkEdgeId = link.linkEdge
								local depotNode = link.depotNode
								trace("found depot link",linkEdgeId )
								depotLinkRemoved = true
								local linkTrackEdge = util.getComponent(linkEdgeId, api.type.ComponentType.BASE_EDGE_TRACK)
								depotParams.isElectricTrack = linkTrackEdge.catenary
								depotParams.isHighSpeedTrack = linkTrackEdge.trackType == api.res.trackTypeRep.find("high_speed.lua")
								if not alreadySeen[linkEdgeId] and not removedEdges[linkEdgeId] and not stationEdges[nextEdgeId]  then
									trace("Removing depot link edge ",linkEdgeId)
									table.insert(edgesToRemove, linkEdgeId)
									alreadySeen[linkEdgeId]=true
									removedEdges[linkEdgeId]=true
								else 
									trace("Not removing depot link edge",linkEdgeId,"already seen for",depotConstruction)
								end 
								local linkEdge = util.getComponent(linkEdgeId, api.type.ComponentType.BASE_EDGE)
								local nextNode = depotNode == linkEdge.node0 and linkEdge.node1 or linkEdge.node0
								--local nextSegs =  util.getTrackSegmentsForNode(nextNode)
								local nextEdgeId = linkEdgeId
								trace("looking for next segments for depot link, starting with ",nextEdgeId, "and ",nextNode)
								local foundOrphanedSlipSwitch = false
								while not util.isTrackJoinJunction(nextNode, oldNodeToFullEdgeMap) do 
									if #util.getTrackSegmentsForNode(nextNode) == 3 then -- if we are not a track join junction but have only 3 segs then need to exit soon
										trace("Marking the node",nextNode,"as orphaned slipswitch")
										foundOrphanedSlipSwitch = true 
									end 
									nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
									trace("inspecting edge in the depot link chain: ",nextEdgeId, " and node ",nextNode," routeEdges[nextEdgeId]?",routeEdges[nextEdgeId])
									if not nextEdgeId or util.isFrozenEdge(nextEdgeId) then 
										break 
									end
									if routeEdges[nextEdgeId] then 
										trace("WARNING! Found a route edge in the edges, aborting")
										break
									end 
									local nextEdge = util.getEdge(nextEdgeId)
									nextNode = nextEdge.node0 == nextNode and nextEdge.node1 or nextEdge.node0
									if #nextEdge.objects > 0 then 
										error("Found edge objects while removing depot link")
									end 
									--nextSegs = util.getTrackSegmentsForNode(nextNode)
									if not alreadySeen[nextEdgeId] and not stationEdges[nextEdgeId] and not removedEdges[nextEdgeId] then 
										trace("removing ", nextEdgeId," for depot link")
										table.insert(edgesToRemove, nextEdgeId)
										alreadySeen[nextEdgeId]=true
										removedEdges[nextEdgeId]=true
										
									end
									if foundOrphanedSlipSwitch then 
										trace("Breaking out of loop for removing depot links as found orphaned slip switch")
										break
									end 
								end
								
							end
							
							
						end
					end
					
					local overridePosition = true
				
					trace("The track change in position was ",trackChangeLength," moving next node to lineup")
					if not isNode0 then 
						perpSign = -perpSign
					end 
					if trackChangeLength > 5 then 
						--trackChangeVector = 5 * vec3.normalize(trackChangeVector)
						--trackChangeLength = 5
					end
					local function replaceNode(oldNode, newNodeId)
						--if oldNode >0  and  #util.getStreetSegmentsForNode(oldNode)~=0 then 
							--trace("Supressing replacement of road crossing node")
							--return oldNode
						--end
						
						--local oldNodePos = oldNode > 0 and util.nodePos(oldNode) or util.v3(replacedNodesMap[oldNode].comp.position)
						
						local newNodePos
						if oldNode > 0 then 
							local dist = util.distance(util.nodePos(oldNode), stationMidPoint)
							if terminalGap == 1 and util.findDoubleTrackNode(oldNode) and vec3.length(originalTrackChangeVector)>9 then 
								trace("WARNING! Discovered potential collision with change node, reducing track change vector")
								originalTrackChangeVector = 5*vec3.normalize(originalTrackChangeVector)
							end 
						 
							local factor = math.max(math.min(1, 1-(dist-stationRange)/adjustmentRange), 0)
							trace("The node",oldNode,"was at a distance of ",dist, "the calculated factor was",factor,"adjustmentRange=",adjustmentRange,"stationRange=",stationRange)
							
							newNodePos = util.nodePos(oldNode) + factor*originalTrackChangeVector   -- i.e. the same lateral shift
						end
						local newNode  = getOrMakeReplacedNode(oldNode, newNodePos, newNodeId, overridePosition)
						if not newNodeToSegmentMap[newNode.entity] then 
							newNodeToSegmentMap[newNode.entity] = {}
						end
						trace("after call to getOrMakeReplacedNode added new node with id ",newNode.entity," to replace ",oldNode," nodesAdded so far=",#nodesToAdd)
						return newNode.entity
					end
					
					-- to avoid sharp turns go one segment down the line and replace
					local function replaceNodeOnEdge(edge, oldNode, newNodeId)
						
					
						 
						local newEdge = getOrMakeReplacedEdge(edge)
						local isNode0
						if newEdge.comp.node0 == oldNode then
							newEdge.comp.node0 = newNodeId
							if oldToNewNodes[newEdge.comp.node1] then 
								newEdge.comp.node1 = oldToNewNodes[newEdge.comp.node1]
							end
							trace("replaceNodeOnEdge node0 inserting to newNodeToSegmentMap newNodeId=",newNodeId," for edge",newEdge.entity)
							table.insert(newNodeToSegmentMap[newNodeId], newEdge)
							isNode0 = true
						elseif newEdge.comp.node1 == oldNode then
							isNode0 = false
							trace("replaceNodeOnEdge node1 inserting to newNodeToSegmentMap newNodeId=",newNodeId," for edge",newEdge.entity)
							table.insert(newNodeToSegmentMap[newNodeId], newEdge)
							newEdge.comp.node1 = newNodeId
							if oldToNewNodes[newEdge.comp.node0] then 
								newEdge.comp.node0 = oldToNewNodes[newEdge.comp.node0]
							end
						end
						trace("replacing node on edge " , edge, "oldNode=",oldNode, " newNodeId=",newNodeId, " newEdgeId=",newEdge.entity, " isNode0=",isNode0, " terminalNode=",terminalNode," position=",newNodesMap[newNodeId].comp.position.x,newNodesMap[newNodeId].comp.position.y )
						
						
						  
						alreadySeen[edge]=true
						 
						return newEdge
					end
					-- the presence of a doubleSlipSwitch means that there is an extra node on one side
					local changeTo =  5--foundDoubleSlipSwitch and 7 or 6
					--local changeTo = foundDoubleSlipSwitch and 3 or 2
					if minimalTrackChanges then 
						changeTo = 2
					end
					if reallyMinimalTrackChanges then 
						changeTo =1 
					end
					local minK = 2
					local k = 1
					local rotateTrackVector = false
					local absoluteMaximumK = 20 
					if details.routeInfo then 
						local routeInfo = details.routeInfo 
						local numedges = routeInfo.lastFreeEdge - routeInfo.firstFreeEdge
						absoluteMaximumK = math.min(absoluteMaximumK, math.floor(numedges/2))
						trace("clamping the absoluteMaximumK based on numedges",numedges," to",absoluteMaximumK)
					end
					--for k = 1, changeTo do 
					while k <= changeTo and k<= absoluteMaximumK do 
						overridePosition = k == 1
						trace("Begin trackChange loop, k=",k,"changeTo=",changeTo)
						if secondNode < 0 then 
							trace("SecondNode was negative",secondNode," using lookup",inverseReplacedNodesMap[secondNode])
							secondNode = inverseReplacedNodesMap[secondNode]
						end 
						local nextSegs = findOtherSegmentsForNode(secondNode, {  --[[ oldEdge--]]} ) 
						if not nextSegs then 
							trace("WARNING! No nextSegs found for ",secondNode," aborting")
							break 
						end
						local canExit = #nextSegs < 3
						local minLength = math.huge 
						for i, edgeId in pairs(nextSegs) do 
							if api.engine.entityExists(edgeId) and util.getEdge(edgeId) and not util.isFrozenEdge(edgeId) then 
								minLength = math.min(minLength, util.calculateSegmentLengthFromEdge(edgeId))
							end
						end
						local maxDeflectionAngle = math.abs(deflectionAngle)-- TODO how to obtain this for the first segment
						local replacedEdge = newEdge
						--if k <= (foundDoubleSlipSwitchMain and 4 or 3) or minLength < 80 then 
							local newNodeId2 = replaceNode(secondNode, newNodeId)
							for i, edge in pairs(nextSegs) do
								if not removedEdges[edge] and not util.isFrozenEdge(edge) then
									replacedEdge = replaceNodeOnEdge(edge, secondNode , newNodeId2)
									maxDeflectionAngle = util.getMaxEdgeDeflectionAngle(edge) 
								end
							end
							if k == 1 and newTerminalConfiguration and newTerminalConfiguration.newConnectTerminals[i] then 
								if util.distance(getPositionOfNode(newTerminalConnectEntity.comp.node0), getPositionOfNode(newTerminalConnectEntity.comp.node1)) < 40 and false then 
									trace("Short distance detected for newTerminalConnectEntity, attempting to correct")
									if newTerminalConnectEntity.comp.node0 == replacedEdge.comp.node1 then 
										newTerminalConnectEntity.comp.node0 = replacedEdge.comp.node0 
										util.setTangent(newTerminalConnectEntity.comp.tangent0, replacedEdge.comp.tangent0)
									else 
										newTerminalConnectEntity.comp.node1 = replacedEdge.comp.node1
										util.setTangent(newTerminalConnectEntity.comp.tangent1, replacedEdge.comp.tangent1)
									end 
								elseif details.routeInfo and #replacedEdge.comp.objects == 0   then 
									local routeInfo =  details.routeInfo
									local edge1 = routeInfo.edges[routeInfo.firstFreeEdge].edge 
						
									local isOutbound = details.oldNode == edge1.node0 or details.oldNode == edge1.node1 
									local originalEdge = inverseReplacedEdgesMap[replacedEdge.entity]
									local idx = routeInfo.indexOf(originalEdge)
									if not idx then 
										trace("WARNING! Could not find index for",originalEdge," skipping")
									else 
										local edge = routeInfo.edges[idx].edge
										local nextEdge = routeInfo.edges[idx+1].edge
										local isBackwards = edge.node0 == nextEdge.node1 or edge.node0 == nextEdge.node0 
										local paramBool = isBackwards ~= isOutbound
										local signalParam = paramBool and 0.1 or 0.9
										local left = isBackwards
										trace("Building signal on replacedEdge",replacedEdge.entity," isOutbound?",isOutbound,"isBackwards",isBackwards,"left=",left,"signalParam=",signalParam)
										routeBuilder.buildSignal(edgeObjectsToAdd, replacedEdge, left, signalParam, bothWays)
									end
								else 
									trace("Did not build a signal because had signals?",#replacedEdge.comp.objects,"had routeInfo?",details.routeInfo)
								end 
							end 
							for trackOffset = 1, highestTerminal-1 do 
								if newTerminalConfiguration and (newTerminalConfiguration.newConnectTerminals[trackOffset] or newTerminalConfiguration.newConnectTerminals[i]) 
								--or params.doubleTerminalUpgrade 
								then 
									trace("Skipping double track lookup for terminal connect at ",trackOffset,"terminal",i)
									goto continue4 
								end
								trace("looking for a double track node for",secondNode," at track offset",trackOffset)
								local doubleTrackNodes = util.findDoubleTrackNodes(secondNode, nil, trackOffset)
								if #doubleTrackNodes == 0 then 
									break -- do not move unadjacent nodes
								end
								for __,  doubleTrackNode in pairs(doubleTrackNodes) do 
									trace("Inspecting doubleTrackNode",doubleTrackNode," is in nodesExpectedToChange?",nodesExpectedToChange[doubleTrackNode])
									if doubleTrackNode and not replacedNodesMap[doubleTrackNode] and nodesExpectedToChange[doubleTrackNode] and not doubleTerminalNodes[doubleTrackNode] then 
										trace("Found double track node", doubleTrackNode)
										newNodeId = newNodeId - 1
										local newNodeForDoubleTrack = replaceNode(doubleTrackNode, newNodeId)
										for i, edge in pairs(findOtherSegmentsForNode(doubleTrackNode, {  --[[ oldEdge--]]} ) ) do
											if not removedEdges[edge] and not util.isFrozenEdge(edge) then
												replaceNodeOnEdge(edge, doubleTrackNode , newNodeForDoubleTrack)
											end
										end
									end 
								end
								::continue4::
							end
							local nextEdge= findNextEdgeInSameDirection(oldEdge, secondNode)
							if #nextSegs == 4 and not reallyMinimalTrackChanges then 
								minK = minK + 1 
								changeTo = changeTo + 1 -- need extra
							end 
							if #nextSegs== 3 then -- 3 segs is ambiguous  
								trace("Found more than 2 segs, inspecting, original nextEdgeId was ",nextEdge, " for oldEdge ",oldEdge," and node ",secondNode)
								local options = {}
								local maxSegs = 0
								for i, seg in pairs(nextSegs) do 
									if seg ~= oldEdge and not removedEdges[seg] and not util.isFrozenEdge(seg) then 
										local otherEdge = util.getEdge(seg)
										local otherNode = otherEdge.node0 == secondNode and otherEdge.node1 or otherEdge.node0
										local segmentsForNode =  #util.getSegmentsForNode(otherNode)
										if oldNodeToEdgeMap[otherNode] then 
											trace("Using the original oldNodeToEdgeMap for scoring, previously was",segmentsForNode, " for node ",otherNode, " now ",#oldNodeToEdgeMap[otherNode])
											segmentsForNode = #oldNodeToEdgeMap[otherNode]
										end 
										maxSegs = math.max(maxSegs, segmentsForNode)
										table.insert(options, {
											nextEdgeId = seg, 
											otherNode =  otherNode,
											scores = { segmentsForNode }
										})
									end 
								end 
								if maxSegs > 2 then
									for i, details in pairs(util.evaluateAndSortFromScores(options)) do 
										if i == 1 then 
											nextEdge = details.nextEdgeId 
											trace("After finding multinodes set the nextEdgeid to ",nextEdge)
										else 
										--[[[
											newNodeId = newNodeId -1
											local newNodeId3 = replaceNode(details.otherNode, newNodeId)
											for i, edge in pairs(util.getSegmentsForNode(details.otherNode)) do
												if not removedEdges[edge] and not util.isFrozenEdge(edge) then
													replaceNodeOnEdge(edge, details.otherNode , newNodeId3)
												end
											end
											
										]]--
										end 
									end 
								else 
									trace("Retaining original edge selection")
								end 
							end 
							if nextEdge then 
								local nextEdgeFull = util.getEdge(nextEdge)
								local deflectionAngle = util.signedAngle(nextEdgeFull.tangent0, nextEdgeFull.tangent1)
								local deflectionAngle2 = util.signedAngle(nextEdgeFull.tangent1, nextEdgeFull.tangent0)
								local deflectionToUse = isNode0 and deflectionAngle or deflectionAngle2
								trace("At k=",k,"The deflectionAngle was",math.deg(deflectionAngle),"isNode0=",isNode0, " deflectionAngle2=",math.deg(deflectionAngle2))
								if rotateTrackVector then 
									trackChangeVector = util.rotateXY(trackChangeVector,  deflectionToUse)
								end
								oldEdge = nextEdge
								secondNode = nextEdgeFull.node0 == secondNode and nextEdgeFull.node1 or nextEdgeFull.node0
								if util.isDoubleSlipSwitch(secondNode) then 
									foundDoubleSlipSwitch = true 
								end
							else 
								trace("Unable to continue, no nextEdge was found, oldEdge=",oldEdge,"secondNode=", secondNode)
								break 
							end
						--end
						local minLength2 = math.huge
						local newNodeId3
						local replacedEdge2 
						if secondEdge then  
							if thirdNode < 0 then 
								thirdNode = inverseReplacedNodesMap[thirdNode]
							end
							local nextSegs2 = findOtherSegmentsForNode(thirdNode, {  --[[ secondEdge--]] } )
							if #nextSegs2 > 2 then 
								canExit = false 
							end
							for i, edgeId in pairs(nextSegs2) do 
								if api.engine.entityExists(edgeId) then
									minLength2 = math.min(minLength2, util.calculateSegmentLengthFromEdge(edgeId))
								end
							end
							--if k <= (foundDoubleSlipSwitchSecond and 4 or 3) or minLength2 < 80 then 
								newNodeId = newNodeId -1
								newNodeId3 = replaceNode(thirdNode, newNodeId)
								for i, edge in pairs(nextSegs2) do
									if not removedEdges[edge] and not util.isFrozenEdge(edge) then
										replacedEdge2 = replaceNodeOnEdge(edge, thirdNode , newNodeId3)
									end
								end
								local nextEdge= findNextEdgeInSameDirection(secondEdge, thirdNode)
								if not nextEdge then 
									trace("Unable to continue, no nextEdge was found, secondEdge=",secondEdge,"thirdNode=", thirdNode)
									break 
								end 
								local nextEdgeFull = util.getEdge(nextEdge)
								thirdNode = nextEdgeFull.node0 == thirdNode and nextEdgeFull.node1 or nextEdgeFull.node0 
								if util.isDoubleSlipSwitch(thirdNode) then 
									foundDoubleSlipSwitch = true 
								end
								secondEdge = nextEdge
							--end
						end
						newNodeId = newNodeId -1
						if minLength < 40 or minLength2 < 40 then 
							trace("Short length detected, increasing minK")
							canExit = false 
						end
						
						--trackChangeVector = (5-k) * vec3.normalize(trackChangeVector)
						--foundDoubleSlipSwitch and 3 or 2
						
						canExit = util.distance(stationMidPoint, util.nodePos(secondNode)) > maxAdjustmentRange
						trace("Changing track at k=",k, " minLength=",minLength,"minLength2=",minLength2, " oldEdge=",oldEdge,"secondNode=",secondNode, " terminalNode=",terminalNode," canExit?",canExit)
						
						if  not canExit then 
							minK = k +1
							changeTo = math.max(changeTo, k+2)
							trace("Increasing minK to ",minK, "as cannot exit, changing changeTo to",changeTo)
						end
						--minLength > 80 and minLength2 > 80 and 
						if k > minK and not minimalTrackChanges then 
--							local factor = (trackChangeLength-(k-minK))
							--local factor = 1-(k-changeTo)
							local factor = (k-changeTo) / (minK-changeTo)
							trace("Reducing track change vector to ",factor , " at k=",k, " foundDoubleSlipSwitch=",foundDoubleSlipSwitch)
							trackChangeVector = factor * trackChangeLength * vec3.normalize(trackChangeVector)
						end
						if canExit then 
							break 
						end
						--[[if k>minK and minLength > 80 and minLength2 > 80 and maxDeflectionAngle < math.rad(5) and vec3.length(trackChangeVector) < 5 then 
						 	if maxDeflectionAngle < math.rad(5) then 
								trace("Detected almost straight segment, attempting to smooth, was ",math.deg(maxDeflectionAngle))
								
								local lastNode = newNodesMap[newNodeId2]
								local halfTrackChangeVector = 0.5*trackChangeVector
								local lastP =  util.v3(lastNode.comp.position)
								local p = lastP-halfTrackChangeVector
								util.setPositionOnNode(lastNode, p)
								
								local backwards = replacedEdge.comp.node0 == newNodeId2
								if backwards then 
									halfTrackChangeVector = -1*halfTrackChangeVector
								end
								trace("Set position on last node to ",p.x, p.y, " from ",lastP.x,lastP.y, " backwards=",backwards)
								for __, replacedEdge in pairs(newNodeToSegmentMap[newNodeId2]) do 
									trace("Adjusting tangent on ",replacedEdge.entity," for ",newNodeId2)
									if replacedEdge.comp.node0 == newNodeId2 then 
										local otherP =getPositionOfNode( replacedEdge.comp.node1)
										util.setTangent(replacedEdge.comp.tangent0, util.v3(replacedEdge.comp.tangent0)+halfTrackChangeVector)
										--util.setTangent(replacedEdge.comp.tangent0, otherP-p)
									else 
										--local otherP =getPositionOfNode( replacedEdge.comp.node0)
										util.setTangent(replacedEdge.comp.tangent1, util.v3(replacedEdge.comp.tangent1)+halfTrackChangeVector)
									end 
								end
								if newNodeId3 then 
									local lastNode = newNodesMap[newNodeId3]
									local p = util.v3(lastNode.comp.position)-halfTrackChangeVector
									util.setPositionOnNode(lastNode, p)
									trace("Set position on last node2 to ",p.x, p.y)
									for __, replacedEdge in pairs(newNodeToSegmentMap[newNodeId3]) do  
										trace("Adjusting tangent on ",replacedEdge.entity," for ",newNodeId3)
										if replacedEdge.comp.node0 == newNodeId3 then 
											local otherP =getPositionOfNode( replacedEdge.comp.node1)
											util.setTangent(replacedEdge.comp.tangent0, util.v3(replacedEdge.comp.tangent0)+halfTrackChangeVector)
											--util.setTangent(replacedEdge.comp.tangent0, otherP-p)
										else 
											--local otherP =getPositionOfNode( replacedEdge.comp.node0)
											--util.setTangent(replacedEdge.comp.tangent1, p-otherP)
											util.setTangent(replacedEdge.comp.tangent1, util.v3(replacedEdge.comp.tangent1)+halfTrackChangeVector)
										end  
									end
								end
							end 
							trace("Ending the track adjustments at ",k)
							break 
						end ]]--
						k = k + 1
					end
					
				end
				::continue3::
			end
			::continue2::
		end
		
		
		if depotLinkRemoved then 
			local newNodeToSegmentMap = {} -- need to rebuild this, can't use it reliably 
			for i, edge in pairs(edgesToAdd) do 
				for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
					if not newNodeToSegmentMap[node] then 
						newNodeToSegmentMap[node] = {}
					end 
					table.insert(newNodeToSegmentMap[node], edge)
				end 
			end 
				
			trace("reconectEdges: Looking at the depotlink removal for the item")
			local removedIdx 
			for i , newNode in pairs(nodesToAdd) do 
				if newNode.comp.doubleSlipSwitch then 
					local newSegs = #newNodeToSegmentMap[newNode.entity]
					trace("reconectEdges: Found doubleSlipSwitch, checking, there were",newSegs, newNode.entity)
					if newSegs == 2 and not removedIdx then 
						local entity1 = newNodeToSegmentMap[newNode.entity][1]
						local entity2 = newNodeToSegmentMap[newNode.entity][2]
						local length1 = vec3.length(entity1.comp.tangent0)
						local length2 = vec3.length(entity2.comp.tangent0)
						local entityToRemove = length1 < length2 and entity1 or  entity2 
						local entityToKeep = entityToRemove == entity1 and entity2 or entity1 
						local node = newNode.entity
						local isNode0 = entityToRemove.comp.node0 == newNode.entity 
						local replacementNode = isNode0 and entityToRemove.comp.node1 or entityToRemove.comp.node0
						local replacementTangent = util.v3(isNode0 and entityToRemove.comp.tangent1 or entityToRemove.comp.tangent0)
						local keepIsNode0 = entityToKeep.comp.node0 == newNode.entity 
						if keepIsNode0 == isNode0 then 
							replacementTangent = -1*replacementTangent
						end 
						trace("Removing ",entityToRemove.entity," lengthening",entityToKeep.entity)
						local combinedLength = length1+length2 
						if keepIsNode0 then 
							entityToKeep.comp.node0 = replacementNode
							util.setTangent(entityToKeep.comp.tangent0, combinedLength*vec3.normalize(replacementTangent))
							util.setTangent(entityToKeep.comp.tangent1, combinedLength*vec3.normalize(util.v3(entityToKeep.comp.tangent1)))
						else 
							entityToKeep.comp.node1 = replacementNode
							util.setTangent(entityToKeep.comp.tangent1, combinedLength*vec3.normalize(replacementTangent))
							util.setTangent(entityToKeep.comp.tangent0, combinedLength*vec3.normalize(util.v3(entityToKeep.comp.tangent0)))
						end 
						for i, edgeObj in pairs(entityToRemove.comp.objects) do 
							if edgeObj[1] > 0 and not util.contains(edgeObjectsToRemove, edgeObj[1]) then 
								trace("Removing edge object for ",edgeObj[1])
								table.insert(edgeObjectsToRemove, edgeObj[1])
							end 
							if edgeObj[1] < 0 then 
								for i, edgeObj in pairs(edgeObjectsToAdd) do 
									if edgeObj.edgeEntity == entityToRemove.entity then 
										trace("Removing previously inserted edge object at ",i)
										table.remove(edgeObjectsToAdd, i) 
										break 
									end
								end 
							end 
						end 
						table.remove(nodesToAdd, i)
						table.remove(edgesToAdd, -entityToRemove.entity)
						removedIdx = -entityToRemove.entity
						trace("Removed node at ",i," removed entity at ",removedIdx)
					else 
						local originalNode = inverseReplacedNodesMap[newNode.entity] 
						debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd, edgesToRemove=edgesToRemove, newNodeToSegmentMap=newNodeToSegmentMap, newSegs=newSegs, originalNode = originalNode, originalSegsForNode=util.getSegmentsForNode(originalNode)})
						debugPrint({newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)})
						--error("Unexpected node count")
					end
				end 	
			end 
	
			if removedIdx then 
				trace("Renumbering entities")
				for i = removedIdx, #edgesToAdd do 
					edgesToAdd[i].entity = 1 + edgesToAdd[i].entity 
				end 
				for i, edgeObj in pairs(edgeObjectsToAdd) do 
					if edgeObj.edgeEntity < -removedIdx then 
						trace("Renumbering edge entity at ",i," for ",edgeObj.edgeEntity)
						edgeObj.edgeEntity = edgeObj.edgeEntity+1
					end 
				end 
			end 
		end 
		
		local function retry()
			changeLineCallbacks = {}
			changeLineCallbackTerminals = {}
			--cleanupStreetGraph = not cleanupStreetGraph 
			trace("Reattempt with cleanupStreetGraph=",cleanupStreetGraph)
			if not minimalTrackChanges then 
				trace("Failed reconnection, Attempting to run with minimalTrackChanges changes")
				minimalTrackChanges = true 
				constructionUtil.executeImmediateWork(function() reconectEdges(res) end)
			elseif not disableSmoothing then 
				trace("Failed reconnection, Attempting to run with disableSmoothing  ")
				disableSmoothing = true 
				constructionUtil.executeImmediateWork(function() reconectEdges(res) end)
			elseif not reallyMinimalTrackChanges then 
				trace("Failed reconnection, Attempting to run with reallyMinimalTrackChanges changes")
				reallyMinimalTrackChanges = true 
				if foundShortConnectEdge then 
					trace("Disabling terminal changs as a short edge was found")
					disableTerminalChanges = true 
				end
				constructionUtil.executeImmediateWork(function() reconectEdges(res) end)
			elseif not disableDepotRemoval then 
				trace("Failed reconnection, Attempting to run with disableDepotRemoval  ")
				disableDepotRemoval = true 
				constructionUtil.executeImmediateWork(function() reconectEdges(res) end)

			elseif not disableTerminalChanges then 
				trace("Failed reconnection, Attempting to run with terminal changes disabled")
				disableTerminalChanges = true 
				constructionUtil.executeImmediateWork(function() reconectEdges(res) end)
			else 
				constructionUtil.executeImmediateWork(function() 
					trace("Attempting segment by segment upgrade")
					local successCount =0
					for i = 1, #edgesToAdd do 
						local edge = edgesToAdd[i]
						if edge.comp.node0 > 0 and edge.comp.node1 > 0 then 
							local newProposal = api.type.SimpleProposal.new() 
							edge.comp.objects = {} -- TODO need to handle signalling
							newProposal.streetProposal.edgesToAdd[1]=edge 
							api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, context, true), function(res, success)  
								trace("Attempt of segment",i,"to build was",success)
								if success then 
									successCount = successCount+1
									if successCount == 1 then 
										for i=1, #changeLineCallbacks do 
											constructionUtil.addWork(changeLineCallbacks[i])  
										end
										if #changeLineCallbacks == 0 then 
											constructionUtil.addWork(callback) 
										end
									end
								end 
							end)
						end 
					end 
				end)
			end			
		end
		
		if not disableSmoothing then 
			trace("Applying smoothing")
		 	--proposalUtil.applySmoothing(edgesToAdd, nodesToAdd) 
		end 
		
		for oldNode, newNode   in pairs(replacedNodesMap) do 
			local streetSegs = util.getStreetSegmentsForNode(oldNode)
			if #streetSegs > 0 then 
				trace("upgradeStationAddTerminal.reconectEdges: inspecting street segments found for node",oldNode)
				for i , seg in pairs(streetSegs) do 
					if util.isIndustryEdge(seg) then 
						trace("Discovered industry edge, resetting position",seg, " resetting position from ",oldNode)
						util.setPositionOnNode(newNode, util.nodePos(oldNode))
						break 
					end 
				end 
			end 
		end 
		
		trace("Setting up proposal")
		local newProposal 
		--util.alwaysCorrectTangentLengths = false
		if params.stationLengthUpgrade then 
			--proposalUtil.applySmoothing(edgesToAdd, nodesToAdd) 
		end 
		routeBuilder.suppressTangentAlteration = true -- not params.stationLengthUpgrade
		if not xpcall(function() 
			newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
		end, function(err) print(err) end) then 
			if util.tracelog then 
				debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd, edgeObjectsToAdd=edgeObjectsToAdd, edgesToRemove=edgesToRemove, edgeObjectsToRemove=edgeObjectsToRemove})
			end 
			retry() 
			return
		end
		routeBuilder.suppressTangentAlteration = false
		for i,obj in pairs(edgeObjectsToRemove) do
			--newProposal.streetProposal.edgeObjectsToRemove[i]=obj
		end
		if isTerminus and depotLinkRemoved and not util.isDepotContainingVehicles(depotConstruction) then 
			newProposal.constructionsToRemove = { depotConstruction }
		end 
		if util.tracelog then debugPrint(newProposal) end
		local context = util.initContext()
		context.cleanupStreetGraph = cleanupStreetGraph
		local build = api.cmd.make.buildProposal(newProposal, context, true)
		trace("reconectEdges: Built proposal, about to send command to build",stationId, stationName) 
		 
		api.cmd.sendCommand(build, function(res, success) 
			xpcall(function() 
				trace(" attempt command reconnect station edges result was", tostring(success)," for ",stationName)
				if success then 
					util.clearCacheNode2SegMaps()	
					if util.tracelog then 
						-- game.interface.setGameSpeed(0)
					end
					-- need to defer the main callback to build route until all the change lines are complete
					for i=1, #changeLineCallbacks do
						if newTerminalConfiguration then 
							constructionUtil.executeImmediateWork(changeLineCallbacks[i])
						else 
							constructionUtil.addWork(changeLineCallbacks[i])
						end
					end
					if #changeLineCallbacks == 0 then 
						constructionUtil.addWork(callback) 
					end
					if depotLinkRemoved then
						if not isTerminus then 
							constructionUtil.addWorkWhenAllIsFinished(function() routeBuilder.buildDepotConnection(constructionUtil.standardCallback, depotConstruction, depotParams) end)
						end
					end
					if params.isAutoBuildMode and highestTerminal>=4  and not isCargo then  
						constructionUtil.addDelayedWork(function() constructionUtil.addWorkWhenAllIsFinished(function() constructionUtil.developStationOffside( { stationId=stationId}) end ) end)-- double delay 
					end 
					if stationWasOffset then 
						constructionUtil.addDelayedWork(function() constructionUtil.lineManager.revalidateRailLines(stationId) end)
					end 
				else 
					local diagnose = false
					if util.tracelog and diagnose then 
						
						constructionUtil.addWork(function() 
							--routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose) 
								local newProposal = routeBuilder.setupProposalAndDeconflict({}, {}, {}, edgesToRemove)
								local build = api.cmd.make.buildProposal(newProposal, context, true)
								api.cmd.sendCommand(build, function(res, success) 
									trace("Call to remove everything was",success)
									constructionUtil.addWork(function() 
										edgesToRemove = {}
										edgeObjectsToRemove = {}
										local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose) 
										local build = api.cmd.make.buildProposal(newProposal, context, true)
										api.cmd.sendCommand(build, function(res, success) 
											trace("Call to do second things was",success) 
										end)
									end)
								end)
							end) 
					else 
						retry()
					end
				end 
				constructionUtil.standardCallback(res, success)
			end, constructionUtil.err)
		end)  
	 end
	 



	
	
	 for edgeId, edge in pairs(crossoverEdges) do 
		trace("Removing edge, edgeId=",edgeId)
		if not util.contains(edgesToRemove, edgeId) then 
			if util.isFrozenEdge(edgeId) then 
				trace("WARNING! Attempted to remove frozen edge",edgeId)
			else 
				table.insert(edgesToRemove, edgeId)
			end
		end
	 end
	if params.stationLengthUpgrade then 
		--proposalUtil.applySmoothing(edgesToAdd, nodesToAdd) 
	end 
	 local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	 newProposal.constructionsToAdd[1] = newConstruction
	 local constructionsToRemove = {constructionId}
	 
	 
	 newProposal.constructionsToRemove  =  constructionsToRemove
	

	 if not applyDummyShift then 
		local alreadySeen = {}
		for i, node in pairs(newProposal.streetProposal.nodesToRemove) do 
			alreadySeen[node]=true
		end 
--		for node, terminal in pairs(freeNodesToTerminals) do 
--			trace("Removing node=",node)
--			newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=node
--		end 
		for edge, node in pairs(connectedEdges) do 
			if not alreadySeen[node] then 
				trace("Removing node=",node)
				newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=node
				alreadySeen[node]=true
			end 
			local edgeFull = util.getEdge(edge)
			local otherNode = node == edgeFull.node0 and edgeFull.node1 or edgeFull.node0 
			if #util.getSegmentsForNode(otherNode) == 1 then -- need cleanup or crash if a node has no segments
				if not alreadySeen[otherNode] then 
					trace("Isolated node detected, removing",otherNode)
					alreadySeen[otherNode] = true 
					newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=otherNode 
				end
			end 
		end 
		for edgeObjId, edgeObj in pairs(removedSignals) do 
			if not util.contains(newProposal.streetProposal.edgeObjectsToRemove, edgeObjId) then 
				newProposal.streetProposal.edgeObjectsToRemove[1+#newProposal.streetProposal.edgeObjectsToRemove]=edgeObjId 
			end
		end 
	 end 
	 local context = util.initContext()
--	 context.cleanupStreetGraph=true
	 context.cleanupStreetGraph = false
	 trace("About to generate test data")
	 local testData = api.engine.util.proposal.makeProposalData(newProposal, context)
	 trace("Test data generated")
	 if util.contains(testData.errorState.messages, "Collision") and isCargo then 
		trace("Collision found in the test data") 
		local newProposal = api.type.SimpleProposal.new()
		if util.tracelog then debugPrint(testData.collisionInfo.collisionEntities) end 
		local stationPos = util.getStationPosition(stationId)
		local height = stationPos.z
		local edges = {} 
		for i , entity in pairs(testData.collisionInfo.collisionEntities) do 
			if entity.entity > 0 and not edges[entity.entity] and util.getEdge(entity.entity) and not connectedEdges[entity.entity] and not util.contains(edgesToRemove,entity.entity)  then 
				edges[entity.entity] =true 
			end
		end 
		if util.tracelog then debugPrint({conflictEdges=edges}) end
		proposalUtil.deconflictEdges(edges, height, connectedEdges) 
	 end 

	 
	-- newProposal.old2new[constructionId]=1
			 trace(" newConstruction.params.length=", newConstruction.params.length)
	--if util.tracelog then debugPrint({oldParams=construction.params, newProposal=newProposal}) end
	
	if #testData.errorState.messages > 0 or testData.errorState.critical then 
		if util.tracelog then 
			debugPrint(newProposal)
			debugPrint(testData.errorState)
		end 
		trace("Error was discovered in proposed ugprade to construction",stationId, stationName)
	end 
	local replacedNodes = {} 
	for edgeId, edge in pairs(crossoverEdges) do 
		for i, node in pairs({edge.comp.node0, edge.comp.node1}) do 
			if not freeNodesToTerminals[node] and util.contains(newProposal.streetProposal.nodesToRemove, node) then 
				if not replacedNodes[node] then 
					trace("Found reference to old node",node,"being removed")
					replacedNodes[node] = util.nodePos(node)
				end 
			end
		end
	 end
	local build = api.cmd.make.buildProposal(newProposal, context, true)
	trace("upgradeStationAddTerminal: about to sent command to upgrade construction",stationId, stationName)
		api.cmd.sendCommand(build, function(res, success) 
			trace("upgradeStationAddTerminal: attempt command result was", tostring(success))
			util.clearCacheNode2SegMaps()
			if success then 
				--game.interface.setGameSpeed(0)
				constructionUtil.executeImmediateWork(function() 
					for edgeId, edge in pairs(util.shallowClone(crossoverEdges)) do 
						for i, node in pairs({edge.comp.node0, edge.comp.node1}) do 
							if replacedNodes[node] then 
								local newNode = util.getNodeClosestToPosition(replacedNodes[node])
								if not newNode then 
									if util.tracelog then 
										trace("WARNING! No new node found, removing edge")
										debugPrint({replacedNodes = replacedNodes})
									end 
									crossoverEdges[edgeId]=nil
								else  
									trace("upgradeStationAddTerminal: swapping the replaced node",node," for ",newNode) 
									if i == 1 then 
										edge.comp.node0 = newNode 
									else 
										edge.comp.node1 = newNode
									end 
									-- NO! If we replace the nodes the edges got change too...
									--[[if oldNodeToFullEdgeMap[node] then 
										oldNodeToFullEdgeMap[newNode] = oldNodeToFullEdgeMap[node]
										oldNodeToFullEdgeMap[node] = nil
									end 
									if oldNodeToEdgeMap[node] then 
										oldNodeToEdgeMap[newNode] = oldNodeToEdgeMap[node]
										oldNodeToEdgeMap[node] = nil
									end ]]--
								end
							end
						end
					 end 
					reconectEdges(res) 
				end)
				constructionUtil.standardCallback(res, success)
			elseif not doNotRemoveCrossover then 
				doNotRemoveCrossover = true 
				constructionUtil.executeImmediateWork(function() constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminalsToAdd, doNotRemoveCrossover, newTerminalConfiguration, safeMode) end)
				--constructionUtil.addWork(function()constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminalsToAdd, doNotRemoveCrossover, safeMode)end)
			elseif not safeMode then 
				safeMode = true
				constructionUtil.executeImmediateWork(function() constructionUtil.upgradeStationAddTerminal(stationId, otherTown, callback, params, terminalsToAdd, doNotRemoveCrossover, newTerminalConfiguration, safeMode) end)	
			else 
				debugPrint({res=res.resultProposalData})
				local success = false 
				if not params.stationLengthUpgrade then 
					trace("Attempting direct upgrade instead with upgradeConstruction",stationId, stationName)
					success = pcall(function() game.interface.upgradeConstruction(constructionId, construction.fileName, newConstruction.params)end)
					trace("direct upgrade success?",success)
				else 
					if not constructionUtil.failedUpgrades then
						constructionUtil.failedUpgrades = {}
					end 
					constructionUtil.failedUpgrades[stationId]=true 
					constructionUtil.addWork(function() error("Failed to upgrade "..stationName) end) -- to display in the ui
				end 
				if callback then 
					callback(res,success)
				else 
					constructionUtil.standardCallback(res, success)
				end
			end
		end)

end

local function tryBuildAirPortForTown(newProposal,town, nodeDetails, params, extraOffset)
	local newAirPort = "station/air/airport.con"
	local oldAirPort = "station/air/airfield.con"
	local fileName 
	local busPerpOffset
	local buildParams= {
			paramX = 0,
			paramY = 0,
			seed = 1,
			dir = 0, -- landing direction
			templateIndex = 0, -- 1 is cargo
			hangar = 0, -- this is true 
			terminals = 2, -- actually 3
			secondRunway = util.year() >= 1980 and not params.disableSecondRunway, 
			year = util.year()
		}
	local modulebasics
	if params.useSmallAirport or util.year() < api.res.constructionRep.get(api.res.constructionRep.find(newAirPort)).availability.yearFrom then 
		fileName = oldAirPort
		modulebasics = helper.createAirfieldTemplateFn(buildParams)
		busPerpOffset= 130
	else 
		fileName = newAirPort
		modulebasics = helper.createAirportTemplateFn(buildParams)
		busPerpOffset= 220
	end
	
	buildParams.modules = util.setupModuleDetailsForTemplate(modulebasics)   
	if not params.airportBaseCost then 
		params.airportBaseCost = 0 
		for i, mod in pairs(buildParams.modules) do 
			local moduleRep = api.res.moduleRep.get(api.res.moduleRep.find(mod.name))
			local cost = moduleRep.cost 
			if cost then 
				params.airportBaseCost = params.airportBaseCost + cost.price * cost.priceScale
			end 	
		end 
		trace("calculated the airport base cost as ",params.airportBaseCost)
	end 
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	--debugPrint({town=town, positionAndRotation=positionAndRotation})
	newConstruction.name=town.name.." ".._("Airport")

	 
	newConstruction.fileName = fileName
	newConstruction.playerEntity = api.engine.util.getPlayer()
 
	newConstruction.params = buildParams
	local tangent = util.v3(nodeDetails.tangent)
	tangent.z = 0
	tangent = vec3.normalize(tangent)
	local perpTangent = util.rotateXY(tangent,math.rad(90))
	local stationTangent = vec3.new(0,-1,0)
	if nodeDetails.existingBusStation then 
		trace("fixing offset")
		extraOffset.x =2 
		extraOffset.y = -215
		if fileName == oldAirPort then
			extraOffset.y = extraOffset.y +50
		end 
		--offset = -offset
	end 
	local basePosition =  nodeDetails.nodePos + extraOffset.x*tangent + extraOffset.y*perpTangent
	basePosition.z = basePosition.z + extraOffset.z
	basePosition.z = math.max(basePosition.z, util.getWaterLevel()+5)

	local offset = 125  

	local rotation =math.rad(180)-util.signedAngle(tangent, stationTangent)
	local position = basePosition + offset*tangent
	trace("attempting build at position ",position.x, position.y," rotation was ",math.deg(rotation), " node was ",nodeDetails.node," extraOffset=",extraOffset.x,extraOffset.y)
	newConstruction.transf = util.transf2Mat4f(rotZTransl(rotation, position))
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=newConstruction
	
	
	local busStationPos = basePosition +busPerpOffset*perpTangent
	local existingBusStationCount =  util.countRoadStationsForTown(town.id)
	local platL = existingBusStationCount == 0 and 2 or existingBusStationCount == 1 and 3 or 1
	trace("building bus station for airport, node has existing?",nodeDetails.existingBusStation~=nil," node was ",nodeDetails.node)
	if not nodeDetails.existingBusStation then 
		constructionUtil.buildRoadStation(newProposal, busStationPos, rotation+math.rad(90), params, town, true,platL,1 , _("Airport"))
		if existingBusStationCount == 0 then 
			newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=constructionUtil.createRoadDepotConstruction(town, busStationPos+100*perpTangent+30*tangent, rotation+math.rad(0))
		else 
			newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=constructionUtil.createTramDepotConstruction(town, busStationPos+100*perpTangent+30*tangent, rotation+math.rad(0))
		end
	end
	return position
end

function constructionUtil.setupAirportForCargo(airport,industry, result)
	local isTown = industry.type =="TOWN"
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(airport)
	local construction = util.getConstruction(constructionId)
	local cargoStation 
	for i, stationId in pairs(construction.stations) do 
		if util.getStation(stationId).cargo then 
			cargoStation = stationId 
		end
	end 
	local cargoTerminals = 1
	if cargoStation and util.countFreeTerminalsForStation(cargoStation) == 0 then 
		cargoTerminals = 1 + #util.getStation(cargoStation).terminals 
	end 
	local stationParams = util.deepClone(construction.params) 
	stationParams.buildOffsideCargoTerminal = true 
	stationParams.cargoTerminals = cargoTerminals
	 
	
	stationParams.modules = util.setupModuleDetailsForTemplate(helper.createAirportTemplateFn(stationParams))   
	
	trace("About to execute upgradeConstruction for constructionId ",constructionId)
	stationParams.seed = nil
	pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
	trace("About set player")
	game.interface.setPlayer(constructionId, game.interface.getPlayer())
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local construction = util.getConstruction(constructionId)
	local airportPosition = util.getStationPosition(airport)
	local stationParallelTangent = util.v3(construction.transf:cols(1))
	local stationPerpTangent = util.v3(construction.transf:cols(0))
	local roadStationPos = airportPosition + 370*stationParallelTangent - 220 * stationPerpTangent
	local airPortCargoRoadStation = constructionUtil.searchForNearestCargoRoadStation(roadStationPos, 150) 
	local params = paramHelper.getDefaultRouteBuildingParams(result.cargoType, false, false) 
	local newProposal = api.type.SimpleProposal.new()
	local roadDepotIdx
	if not airPortCargoRoadStation then
		local angle = -util.signedAngle(stationParallelTangent, vec3.new(0,1,0))
		local airportNaming = util.getComponent(airport, api.type.ComponentType.NAME)
		local naming = { name = airportNaming.name.." ".._("Transfer") } 
		local hasEntranceB = true
	
		constructionUtil.buildRoadStation(newProposal, roadStationPos, angle+math.rad(90), params, naming, hasEntranceB, 1, 1,"") 
		if not constructionUtil.searchForRoadDepot(roadStationPos, 500) then 
			newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=constructionUtil.createRoadDepotConstruction(airportNaming, roadStationPos-80*stationPerpTangent+30*stationParallelTangent,angle)
			roadDepotIdx = #newProposal.constructionsToAdd
		end
	end 
	local cargoType = result.cargoType
	local index = industry == result.industry1 and 1 or 2
	local details = connectEval.getTruckStationToBuild(industry, cargoType, index, util.v3fromArr(industry.position), airportPosition)
	local industryStation =  connectEval.checkForAppropriateCargoStation(industry, api.type.enum.Carrier.ROAD)
	local roadStationIdx
	local connectNode
	if not industryStation then  
		constructionUtil.buildCargoRoadStationForIndustry( result,industry, index, airportPosition, newProposal, params)
		if not isTown then  
			roadStationIdx = result.constructionIdxs[index].roadStationIdx  
			connectNode = result.constructionIdxs[index].connectNode
		end
	end
		
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
		trace(" About to sent command to build airport transfer")
		api.cmd.sendCommand(build, function(res, success) 
			trace(" attempt command result was", tostring(success))
			util.clearCacheNode2SegMaps()
			if success then 
				constructionUtil.addWork(function() 
					util.clearCacheNode2SegMaps()
					util.lazyCacheNode2SegMaps()
					local newProposal = api.type.SimpleProposal.new()
					if airPortCargoRoadStation then  
						constructionUtil.checkRoadStationForUpgrade(newProposal, airPortCargoRoadStation, industry, result)
					else 
						airPortCargoRoadStation = util.getConstruction(res.resultEntities[1]).stations[1]
					end 					
					if industryStation and not isTown then  
						constructionUtil.checkRoadStationForUpgrade(newProposal, industryStation, industry, result)
					elseif not isTown then 
						industryStation = util.getConstruction(res.resultEntities[roadStationIdx]).stations[1]
					else 
						industryStation = result.truckStop
					end					
					trace("Completing transhipment route, station constructions were",airPortCargoRoadStation,industryStation)
				
					
					local stations = { 
						airPortCargoRoadStation,
						industryStation,
					}
					local hasEntranceB = {
						true,
						not isTown and util.getConstructionForStation(industryStation).params.entrance_exit_b==1,
					}
				
					local callback = function(res, success) 
						util.clearCacheNode2SegMaps()
						if success then 
							constructionUtil.addWork(function() 
								local callback2 = function(res, success) 
									util.clearCacheNode2SegMaps()
									if success  then	
										constructionUtil.addWork(function() constructionUtil.lineManager.setupTrucks(result, stations, params) end)	 
									end
									constructionUtil.standardCallback(res, success)
								end 
								local pathFound = #pathFindingUtil.findRoadPathStations(airPortCargoRoadStation, industryStation) > 0
								trace("Building road between",airPortCargoRoadStation,industryStation," pathFound?",pathFound)
								if pathFound then 
									routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callback2, params) 
								else 
									routeBuilder.buildRoadRouteBetweenStations(stations, callback2, params,result,hasEntranceB, index)
								end
							end)
						else 
						trace("Callback to link the road station failed")
						debugPrint(res)
						end 
					end
					
				 
					if roadDepotIdx then 
						local depotConstr = res.resultEntities[roadDepotIdx]
						local depotNode = util.getEdge(util.getConstruction(depotConstr).frozenEdges[1]).node1
						local depotConnect = util.buildConnectingRoadToNearestNode(depotNode, -1, true, newProposal)
						--local streetType = api.res.streetTypeRep.find(paramHelper.getParams().preferredCountryRoadType)
						local streetType = api.res.streetTypeRep.find("standard/country_medium_new.lua") -- hard coding because of tight clearances
						depotConnect.streetEdge.streetType=streetType
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]= depotConnect
						local newEntity = initNewEntity(newProposal)
						local depotNodePos = util.nodePos(depotNode)
						local newNodePos = depotNodePos - 135* stationParallelTangent
						local newNode = util.newNodeWithPosition(newNodePos, -1000)
						newNode.comp.position.z = newNode.comp.position.z-10 -- avoid messing up tangents
						newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
						newEntity.comp.node0 = depotNode 
						newEntity.comp.node1 = newNode.entity
						newEntity.streetEdge.streetType=streetType
						util.setTangent(newEntity.comp.tangent0, newNodePos - depotNodePos)
						util.setTangent(newEntity.comp.tangent1, newNodePos - depotNodePos)
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]= newEntity
						local newNodePos2 = newNodePos - 250* stationParallelTangent
						local newNode2 = util.newNodeWithPosition(newNodePos2, -1001)
						newNode2.comp.position.z =  newNode.comp.position.z
						newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode2
						local underPass = initNewEntity(newProposal)
						underPass.comp.node0 = newNode.entity 
						underPass.comp.node1 = newNode2.entity
						util.setTangent(underPass.comp.tangent0, newNodePos2 - newNodePos)
						util.setTangent(underPass.comp.tangent1, newNodePos2 - newNodePos)
						underPass.comp.type = 2
						underPass.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
						underPass.streetEdge.streetType=streetType
						local playerOwned = api.type.PlayerOwned.new()
						playerOwned.player = api.engine.util.getPlayer()
						underPass.playerOwned = playerOwned -- prevent the tunnel section being "upgraded", pointless as it cannot hold any buildings
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]= underPass
						local newNodePos3 = newNodePos2 - 60* stationParallelTangent
						local newNode3 = util.newNodeWithPosition(newNodePos3, -1002)
						newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode3
						local newEntity2 = initNewEntity(newProposal)
						newEntity2.comp.node0 = newNode2.entity 
						newEntity2.comp.node1 = newNode3.entity
						newEntity2.streetEdge.streetType=streetType
						util.setTangent(newEntity2.comp.tangent0, newNodePos3 - newNodePos2)
						util.setTangent(newEntity2.comp.tangent1, newNodePos3 - newNodePos2)
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]= newEntity2
						
						local targetLocation = newNodePos3 - 60*stationParallelTangent+35*stationPerpTangent
						local linkNode =  util.getNodeClosestToPosition(targetLocation)
						trace("The targetLocation was at ",targetLocation.x, targetLocation.y," linkNode found?",linkNode)
						if linkNode then 
							local link = initNewEntity(newProposal)
							local linkNodePos = util.nodePos(linkNode)
							local dist = util.distance(linkNodePos, newNodePos3)*1.2
							link.comp.node0 = newNode3.entity 
							link.comp.node1 = linkNode 
							link.streetEdge.streetType=streetType
							util.setTangent(link.comp.tangent0, -dist * stationParallelTangent)
							util.setTangent(link.comp.tangent1, dist * vec3.normalize(stationPerpTangent-stationParallelTangent))
							newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]= link
						end 
					
					end
		
			
			
					if not isTown and connectNode then 
						local entity = util.buildConnectingRoadToNearestNode(connectNode, -1-#newProposal.streetProposal.edgesToAdd, true, newProposal)
						if not entity then 
							trace("WARNING! unable to find connection for ",connectNode)
						else 
							newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity 
						end
					end 
					
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),callback)
				
				end)
			end
			constructionUtil.standardCallback(res, success)
		end)
end 

function constructionUtil.buildAirPortForTown(town, allNodeDetails, params, callback)
	util.cacheNode2SegMapsIfNecessary()
	if not params then params = {} end
	local locationOptions = {} 
	local offsets = {0}
	local offsetsy = {0}
	  
	if params.tryExtraOffsets and not special then 
		for offset = 90, 180, 90 do 
			table.insert(offsets, offset) 
			table.insert(offsetsy, offset) 
			table.insert(offsetsy, -offset) 
		end
	end 
	local count = 0
	local foundExistingBusStation = false
	for i , nodeDetails in pairs(allNodeDetails) do
		for j, x in pairs(offsets) do
			for k, y in pairs(offsetsy) do
				local zOffsets = x > 0 and {-5, 0, 15} or {0}
				for m, z in pairs(zOffsets) do 
					count = count+1 
					local testProposal = api.type.SimpleProposal.new()
					local extraOffset = vec3.new(x,y,z)
					local position = tryBuildAirPortForTown(testProposal,town, nodeDetails, params, extraOffset)
					local distToMapBoundary = util.getDistToMapBoundary(position)
					trace("Trial position",position.x,position.y," distToMapBoundary =",distToMapBoundary)
					if distToMapBoundary < 350 then 
						goto continue 
					end
					local minZ = (nodeDetails.nodePos.z+z)-25
					if tracelog then debugPrint({testProposalBeforeErrorCheck=testProposal}) end
					local testResult = checkProposalForErrors(testProposal, true, true, minZ, true)
					if tracelog then debugPrint({testProposalAfterErrorCheck=testProposal}) end
					local canAccept =  true
					
					if testResult.removedEdges then  
						if #testResult.remainingNodes >2 then  	
							canAccept = false
						elseif 	#testResult.remainingNodes ==2 then 
							for i, node in pairs(testResult.remainingNodes) do 
								local offset = util.nodePos(node).z-minZ 
								trace("The offset was ",offset," for node ",node)
								if offset > 15 then 
									canAccept = false 
									break 
								end
							end 
						end
					end
					local costFactor = testResult.costs / params.airportBaseCost
					if canAccept and  params.isAutoBuildMode and costFactor > 3 then 
						trace("Rejecting the option due to high cost factor:",costFactor)
						canAccept = false 
					end 
					--[[0if nodeDetails.node == 218270 then 
						trace("Forcing accept, was",canAccept, " testResult.isActualError=",testResult.isActualError)
						canAccept = true 
						testResult.isActualError = false
					end]]--
					trace("buildAirPortForTown: ",nodeDetails.node,"canAccept?",canAccept, " costs=", testResult.costs, " costFactor=",costFactor)
					if not testResult.isActualError and canAccept then 
						table.insert(locationOptions, { 
						cost=testResult.costs, 
						nodeDetails=nodeDetails, 
						extraOffset= extraOffset, 
						removedEdges = testResult.removedEdges , 
						removedNodes=testResult.removedNodes, 
						remainingNodes=testResult.remainingNodes, 
						minZ = minZ,
						ignoreErrors = testResult.isError,
						removedConstructions = testResult.removedConstructions
						})
						if nodeDetails.existingBusStation then 
							trace("Found location with existing bus station, breaking")
							foundExistingBusStation = true
							break 
						end
					end 
				end
				::continue::
				if foundExistingBusStation then 
					break 
				end
			end
			if foundExistingBusStation then 
				break 
			end
		end
		if foundExistingBusStation then 
			break 
		end
		if params.tryExtraOffsets and #locationOptions > 10 then 
			break 
		end
	end
	trace("A total of ",count,"airport locations were considered, of which",#locationOptions," were valid")
	local best = util.evaluateWinnerFromSingleScore(locationOptions, function(location) return location.cost end) 
	if not best then 
		if not params.tryExtraOffsets then 
			params.tryExtraOffsets = true 
			return constructionUtil.buildAirPortForTown(town, allNodeDetails, params, callback)
		end
		if util.year() >= 1980 and not params.disableSecondRunway then 
			 params.disableSecondRunway=true
			 return constructionUtil.buildAirPortForTown(town, allNodeDetails, params, callback)
		end
		if not params.useSmallAirport then 
			params.useSmallAirport = true
			trace("falling back to useSmallAirport for",town.name)
			return constructionUtil.buildAirPortForTown(town, allNodeDetails, params, callback)
		end
		trace("No locations found for ", town.name)
		callback({}, false) 
		return
	end 
	local newProposal = api.type.SimpleProposal.new()
	trace("about to build airport for town on proposal, ", newProposal)
	local wrappedCallback = function(res, success) callback(res, success, best.nodeDetails) end
	if best.removedConstructions then 
		trace("Adding the removed constructions to the main proposal")
		newProposal.constructionsToRemove = best.removedConstructions
	end 
	if best.removedEdges then 
		-- nb boundind box extends 15 meters underground 
		local uniquenessCheck = {}
		for i=1, #best.removedEdges do 
			if not uniquenessCheck[best.removedEdges[i]] then 
				uniquenessCheck[best.removedEdges[i]]=true
				newProposal.streetProposal.edgesToRemove[i]=best.removedEdges[i]
			else 
				trace("WARNING! duplicate edge removal found",best.removedEdges[i])
			end
		end 
		for i=1, #best.removedNodes do 
			if not uniquenessCheck[best.removedNodes[i]] then 
				uniquenessCheck[best.removedNodes[i]]=true
				newProposal.streetProposal.nodesToRemove[i]=best.removedNodes[i]
			else 
				trace("WARNING! duplicate node removal found",best.removedNodes[i])
			end
		end 
		if #best.remainingNodes > 1 then 
			local oldNodePosition = {} 
			for __, node in pairs(util.combine(best.remainingNodes, best.removedNodes)) do 
				oldNodePosition[node]=util.nodePos(node)
			end 
			local newEdges = {}
			for i, edgeId in pairs(best.removedEdges) do  
				table.insert(newEdges, util.copyExistingEdge(edgeId))
			end
			trace("The count of remaining nodes was ",#best.remainingNodes)
			wrappedCallback = function(res, success) 
				if success then 
					constructionUtil.addWork(
					function() 
						util.cacheNode2SegMaps()
						local proposal = api.type.SimpleProposal.new() 
						local addedEdges = {}
						local addedNodes = {}
						 
						local newNodeMap = {}
						for i, node in pairs(util.combine(best.remainingNodes, best.removedNodes)) do 
							local newNode = util.newNodeWithPosition(oldNodePosition[node], -#proposal.streetProposal.nodesToAdd-1000)
							newNode.comp.position.z = math.min(newNode.comp.position.z, best.minZ)
							proposal.streetProposal.nodesToAdd[1+#proposal.streetProposal.nodesToAdd]=newNode
							newNodeMap[node]=newNode.entity 
						 
						end 
						local function mapNewNodes(entity) 
							if newNodeMap[entity.comp.node0] then 
								entity.comp.node0 =  newNodeMap[entity.comp.node0]
							end 
							if newNodeMap[entity.comp.node1] then 
								entity.comp.node1 =  newNodeMap[entity.comp.node1]
							end  
						end
						for i, entity in pairs(newEdges) do 
							local nextEdgeId = -1-#proposal.streetProposal.edgesToAdd
							entity.entity =  nextEdgeId
							entity.comp.type = 2
							entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
							mapNewNodes(entity) 
							local playerOwned = api.type.PlayerOwned.new()
							playerOwned.player = api.engine.util.getPlayer()
							entity.playerOwned = playerOwned
							proposal.streetProposal.edgesToAdd[-nextEdgeId]=entity
							 
						end 
						local removedSet = {}
						for i, node in pairs(best.remainingNodes) do 
							for j, seg in pairs(util.getSegmentsForNode(node)) do 
								if not uniquenessCheck[seg] then 
									local nextEdgeId = -1-#proposal.streetProposal.edgesToAdd
									local entity = util.copyExistingEdge(seg,nextEdgeId)
									mapNewNodes(entity) 
									proposal.streetProposal.edgesToAdd[-nextEdgeId]=entity
									proposal.streetProposal.edgesToRemove[1+#proposal.streetProposal.edgesToRemove]=seg
									  
									uniquenessCheck[seg]=true
								end 
							end 
							proposal.streetProposal.nodesToRemove[1+#proposal.streetProposal.nodesToRemove]=node  
						end 
						if util.tracelog then debugPrint({reconnectProposal=proposal}) end
						local build = api.cmd.make.buildProposal(proposal,  util.initContext(), true)
						api.cmd.sendCommand(build, constructionUtil.standardCallback)
					end)
				end
				callback(res, success, best.nodeDetails)
			end
		end 
	end
	
	
	tryBuildAirPortForTown(newProposal, town, best.nodeDetails, params, best.extraOffset)	
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), best.ignoreErrors)
	params.useSmallAirport = false
	params.disableSecondRunway = false 
	params.tryExtraOffsets = false
	api.cmd.sendCommand(build, wrappedCallback)
	
	 
end

function constructionUtil.buildBusNetworkInitialInfrastructure(newProposal,town, stationPosAndRot, params)
	local perpTangent = stationPosAndRot.busStationPerpTangent
	local tangent = stationPosAndRot.busStationParallelTangent 
	local rotation = stationPosAndRot.busStationRotation
	local busStationPos = stationPosAndRot.originalNodePos - 45*tangent
	busStationPos.z = math.max(busStationPos.z, 5+util.getWaterLevel())
	local busStationRelativeAngle = stationPosAndRot.busStationRelativeAngle
	local platL = params.isCargo and 1 or 2
	local platR = 1
	if busStationRelativeAngle < 0 then
		rotation = math.rad(180)+rotation
		platL = 1
		platR = params.isCargo and 1 or 2
	end
	trace("Bus station relativeAngle for ",town.name," was ",math.deg(busStationRelativeAngle)," removing edge",stationPosAndRot.originalEdgeId, " busStationPos=",busStationPos.x, busStationPos.y)
	
	constructionUtil.buildRoadStation(newProposal, busStationPos, rotation, params, town, true,platL, platR)
	stationPosAndRot.roadStationIdx = #newProposal.constructionsToAdd
	local roadDepotPos = stationPosAndRot.originalNodePos-50*perpTangent+50*tangent
	roadDepotPos.z =  (stationPosAndRot.originalNodePos.z + util.nodePos(stationPosAndRot.otherNode).z)/2
	local roadDepotConstruction = constructionUtil.createRoadDepotConstruction(town, roadDepotPos, rotation+
	math.rad(180))
	local testProposal = api.type.SimpleProposal.new()
	--[[for i, constr in pairs(newProposal.constructionsToAdd) do 
		testProposal.constructionsToAdd[i]=constr
	end 
	if #util.getSegmentsForNode(stationPosAndRot.originalNode) <= 2 and not stationPosAndRot.isVirtualDeadEndForTerminus then 
		testProposal.streetProposal.edgesToRemove[1+#testProposal.streetProposal.edgesToRemove]=stationPosAndRot.originalEdgeId
		testProposal.streetProposal.nodesToRemove[1+#testProposal.streetProposal.nodesToRemove]=stationPosAndRot.originalNode
	end]]--
	
	local shouldRemoveOriginalNode = #util.getSegmentsForNode(stationPosAndRot.originalNode) <= 2 and not stationPosAndRot.isVirtualDeadEndForTerminus
	if #util.getSegmentsForNode(stationPosAndRot.originalNode)==2 and not stationPosAndRot.edgeToRemove then 
		trace("Overriding shouldRemoveOriginalNode to false")
		shouldRemoveOriginalNode = false
	end 
	
	
	if shouldRemoveOriginalNode then 
		trace("buildBusNetworkInitialInfrastructure: Removing node",stationPosAndRot.originalNode,"and edge",stationPosAndRot.originalEdgeId)
		newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=stationPosAndRot.originalEdgeId
		newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=stationPosAndRot.originalNode
	end
	
	copyProposal(newProposal,testProposal )
	testProposal.constructionsToAdd[1+#testProposal.constructionsToAdd]=roadDepotConstruction
	local checkResult = checkProposalForErrors(testProposal,true, true)
	trace("Checkresult of road depot for ",town.name," was iserror? ",checkResult.isError)
	if not checkResult.isError and not params.isTerminus[town.id] then -- disabling road depot at terminus sometimes builds wrong side 
		newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=roadDepotConstruction
		stationPosAndRot.roadDepotIdx = #newProposal.constructionsToAdd

	else 
		stationPosAndRot.roadDepotIdx = nil
	end 	

	
	if stationPosAndRot.isVirtualDeadEnd and #util.getSegmentsForNode(stationPosAndRot.originalNode) == 3 then 
		trace("Checking for the overlapping edge at ",stationPosAndRot.originalNode, " busStationPos=",busStationPos.x, busStationPos.y)
		for i, seg in pairs(util.getSegmentsForNode(stationPosAndRot.originalNode)) do 
			local edgeMidPoint = util.getEdgeMidPoint(seg)
			local distanceToBusStation = util.distance(busStationPos,  edgeMidPoint)
			local edge = util.getEdge(seg)
			local angleToTangent = math.abs(util.signedAngle(tangent, util.getNaturalTangent(seg)))
			if angleToTangent > math.rad(90) then 
				angleToTangent = math.rad(180)-angleToTangent
			end 
			trace("Inspecting seg", seg, " dist was ",distanceToBusStation, " angle was ",math.deg(angleToTangent))
			if distanceToBusStation < 20 and angleToTangent < math.rad(15) and util.indexOf(newProposal.streetProposal.edgesToRemove, seg) == -1 then 
				trace("removing seg",seg," for bus station")
				newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=seg
			end 
		end 
	end 
	
	--[[
	local midPointPos =  util.getEdgeMidPoint(stationPosAndRot.originalEdgeId)
	for __, construction in pairs(util.searchForEntities(midPointPos, 50, "CONSTRUCTION")) do
		trace("Inspecting construction ",construction.id)
		local townBuildingId = construction.townBuildings[1]
		if townBuildingId then 
			local townBuilding = util.getComponent(townBuildingId, api.type.ComponentType.TOWN_BUILDING)
			for ___, parcelId in pairs(townBuilding.parcels) do 
				local parcel = util.getComponent(parcelId, api.type.ComponentType.PARCEL)
				if parcel.streetSegment == stationPosAndRot.originalEdgeId then
					local constructionsToRemove = util.deepClone(newProposal.constructionsToRemove)
					table.insert(constructionsToRemove, construction.id)
					newProposal.constructionsToRemove = constructionsToRemove
					debugPrint({constructionsToRemove=newProposal.constructionsToRemove})
					break
				end
			end
		end
	end
	]]--
	
	--local newNode = util.newNodeWithPosition(stationPosAndRot.originalNodePos)
	--newNode.entity = -stationPosAndRot.originalNode
	
	
	--debugPrint(newProposal)
	
end

function constructionUtil.buildBusStopEdge(edgeId, name, callback) 
	local newProposal =  api.type.SimpleProposal.new()
	constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	if not callback then 
		callback = constructionUtil.standardCallback
	end
	api.cmd.sendCommand(build, callback)
end

local function buildTownBusStops(_newProposal, town, callback)
local newProposal = api.type.SimpleProposal.new()
	if type(town) == "number" then 
		town = util.getEntity(town) 
	end
	local edgesForTown = connectEval.findBusStopEdgesForTown(town)
	local alreadySeen = {}
	for landUseType, edgeId in pairs(edgesForTown) do 
		--local edgeId = connectEval.findCentralEdgeByLandUseType(town, landUseType)
		local name = town.name.." "..landUseType.." ".._("Bus Stop")
		if not alreadySeen[edgeId] then
			constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
		else 
			trace("Tried to build busStop on edge",edgeId," but was already seen landUseType=",landUseType)
		end
		alreadySeen[edgeId]=true
	end
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace(" About to sent command to build bus stops link")
	util.clearCacheNode2SegMaps()
		api.cmd.sendCommand(build, function(res, success) 
			trace(" attempt command result was", tostring(success))
			if callback then 
				callback(res, success)
			end
		end)
end

function constructionUtil.buildTownBusStops(town, callback)
	buildTownBusStops(nil, town, callback)
end 

function constructionUtil.repositionBusStops(town, callback)
	
	if type(town)=="number" then 
		town = util.getEntity(town)
	end
	local excludeTram = true
	local existingStops = util.getBusStopsForTown(town, excludeTram) 
	trace("There were ",#existingStops, "for the town",town.name)
	if #existingStops > 6 and false then 
		trace("Skipping relocation of bus stops") 
		return 
	end
	local newProposal = api.type.SimpleProposal.new()
	local workAfter = {}
	local edgesForTown = connectEval.repositionBusStopEdgesForTown(town)
	local alreadySeen = {}
	for landUseType, edgeIds in pairs(edgesForTown) do 
		--local edgeId = connectEval.findCentralEdgeByLandUseType(town, landUseType)
		local name = town.name.." "..landUseType.." ".._("Bus Stop")
		if edgeIds.old and not alreadySeen[edgeIds.new] and edgeIds.new ~= edgeIds.old  then
			constructionUtil.buildBusStopOnProposal(edgeIds.new, newProposal, name)
			local replacement = util.copyExistingEdge(edgeIds.old, -#newProposal.streetProposal.edgesToAdd-1)
			local linesToMove = {}
			for i, edgeObjs in pairs(replacement.comp.objects) do 
				newProposal.streetProposal.edgeObjectsToRemove[#newProposal.streetProposal.edgeObjectsToRemove+1]=edgeObjs[1]
				local stationId = edgeObjs[1]
				for j, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(stationId)) do 
					table.insert(linesToMove, { lineId = lineId, stopIndex = constructionUtil.lineManager.getStopIndexForStation(lineId, stationId)})
				end 
			end 
			local edge = util.getEdge(edgeIds.new)
			local pos = util.getEdgeMidPoint(edgeIds.new)
			local node0 = edge.node0
			local node1 = edge.node1 
			if #replacement.comp.objects == 2 then 
				table.insert(workAfter, function()
					local newProposal = api.type.SimpleProposal.new() 
					util.clearCacheNode2SegMaps()
					util.lazyCacheNode2SegMaps()
					local newEdgeId = util.findEdgeConnectingNodes(node0, node1)
					trace("Adding second bus stop on the new edge",newEdgeId)
					constructionUtil.buildBusStopOnProposal(newEdgeId, newProposal, name)
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false), function(res, success) 
						util.clearCacheNode2SegMaps()
						if success then 
							constructionUtil.addWork(function() 
								util.lazyCacheNode2SegMaps()
								local newEdgeId = util.findEdgeConnectingNodes(node0, node1)
								local stationId = util.getEdge(newEdgeId).objects[1][1]
								for i, details in pairs(linesToMove) do 
									constructionUtil.lineManager.updateLineSetNewStation(details.lineId, details.stopIndex, stationId)
								end 									
							end) 
						end 
					end)
				end)
			else 
				table.insert(workAfter, function()
					util.lazyCacheNode2SegMaps()
					local newEdgeId = util.findEdgeConnectingNodes(node0, node1)
					local stationId = util.getEdge(newEdgeId).objects[1][1]
					for i, details in pairs(linesToMove) do 
						constructionUtil.lineManager.updateLineSetNewStation(details.lineId, details.stopIndex, stationId)
					end 
				end)
			end			
			replacement.comp.objects={}
			newProposal.streetProposal.edgesToAdd[#newProposal.streetProposal.edgesToAdd+1]=replacement
			newProposal.streetProposal.edgesToRemove[#newProposal.streetProposal.edgesToRemove+1]=edgeIds.old
		else 
			trace("Tried to build busStop on edge",edgeId," but was already seen landUseType=",landUseType)
		end
		alreadySeen[edgeIds.new]=true
	end
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace(" About to sent command to build bus stops link")
	
	local wrappedCallback = function(res, success) 
		
		if success then 
			util.clearCacheNode2SegMaps()
			for i, work in pairs(workAfter) do 
				constructionUtil.addWork(work) 
			end 
		end 
		constructionUtil.addDelayedWork(function() callback(res, success) end)
	end 
	
	api.cmd.sendCommand(build, wrappedCallback)
end	
function constructionUtil.buildLinkRoad(newProposal, startNode, tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)
	if not maxRemaining then maxRemaining = paramHelper.getDefaultRouteBuildingParams().maxBusLinkBuildLimit end
	if not costLimit then costLimit = 500000 end 
	if startNode > 0 and (not api.engine.entityExists(startNode) or not util.getNode(startNode)) then 
		trace("WARNING! node ", node , "was found to be invalid, aborting")
		return 
	end 
	if not startNodePos then startNodePos =  util.nodePos(startNode) end
	if not nextNodeId then 
		local nextId = -1000-#newProposal.streetProposal.nodesToAdd
		for i, nodeEntity in pairs(newProposal.streetProposal.nodesToAdd) do 
			nextId = math.min(nextId, nodeEntity.entity)
		end 
		nextNodeId = function() 
			nextId = nextId -1 
			return nextId
		end
	end
	
	if startNode > 0 and #util.getSegmentsForNode(startNode)==1 then 
		local nodeDetails = util.getDeadEndNodeDetails(startNode)
		local angle = math.abs(util.signedAngle(nodeDetails.tangent, tangent))
		if math.abs(math.rad(180)-angle) < math.rad(1) then 
			trace("Skipping building into existing construction, angle was",math.deg(angle))
			return false
		end 
		
	end 
	
	
	local linkNodePos = startNodePos +90*vec3.normalize(tangent)
	linkNodePos.z = util.th(linkNodePos, true)
	if linkNodePos.z - startNodePos.z > 15 then
		linkNodePos.z = startNodePos.z+15
	elseif startNodePos.z - linkNodePos.z > 15 then 
		linkNodePos.z = startNodePos.z-15
	end 
	local stationLink = initNewEntity(newProposal)
	local linkNode 
	local found = false
	for j = 20, 90, 10 do -- try to find another base node to make a connection with
		
		local testNodePos =  startNodePos +j*vec3.normalize(tangent)
		for i, node in pairs(util.searchForEntities(testNodePos, params and params.linkRoadSearchRadius or 25, "BASE_NODE")) do
			local streetSegments = util.getStreetSegmentsForNode(node.id) 
			local trackSegments = util.getTrackSegmentsForNode(node.id) 
			 
				 
			local hasStreetSegments = #streetSegments > 0
			local canJoin = hasStreetSegments and #trackSegments==0
			for __, seg in pairs(streetSegments) do 
				if util.getStreetTypeCategory(seg)=="highway" then 
					canJoin = false 
					break 
				end
				if util.getEdge(seg).type == 2 then 
					canJoin = false 
					break 
				end
			end 
			
			if canJoin and startNode~=node.id and not util.isNodeConnectedToFrozenEdge(node.id) then
				linkNode = node.id
				linkNodePos = util.nodePos(node.id)
				found=linkNode
				
			end
			
		end
		if found then break end
	end
	local testProposal = api.type.SimpleProposal.new()
	for i, edge in pairs(newProposal.streetProposal.edgesToAdd) do 
		testProposal.streetProposal.edgesToAdd[i]=edge
	end
	for i, edge in pairs(newProposal.streetProposal.edgesToRemove) do 
		testProposal.streetProposal.edgesToRemove[i]=edge
	end
	for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
		testProposal.streetProposal.nodesToAdd[i]=node
	end
	
	local newNode
	if not linkNode then
		for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
			if util.positionsEqual(linkNodePos, node.comp.position, 5) then 
				trace("Found a node with the postion, using",node.entity )
				linkNode = node.entity 
				maxRemaining = 0 -- no more links from this position to avoid double-connecting
				break 
			end 
		
		end 
	--[[	if not linkNode then 
			for i, otherNode in pairs(newProposal.streetProposal.nodesToAdd) do 
				if util.positionsEqual(linkNodePos, otherNode.comp.position) then 
					linkNode = otherNode.entity
					break
				end 
			end]] 
		if not linkNode then 
			newNode = util.newNodeWithPosition(linkNodePos, nextNodeId())
			testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]= newNode
		
			linkNode = newNode.entity
			trace("Created a new node:",linkNode )
		end 
	end
	trace("building station link ,linking ",startNode," with ",linkNode)
	stationLink.comp.node0= startNode
	stationLink.comp.node1= linkNode
	local needsTunnel = math.max(util.th(linkNodePos, true),util.th(linkNodePos)) - linkNodePos.z > 10 and math.max(util.th(startNodePos, true),util.th(startNodePos)) - startNodePos.z > 10
	if needsTunnel then 
		stationLink.comp.type = 2 
		stationLink.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	end 
	
	util.setTangentsForStraightEdgeBetweenPositionsFlattened(stationLink, startNodePos, linkNodePos, linkNode)
	--trace("Setting link on test  proposal")
	local constructionId = util.isNodeConnectedToFrozenEdge(linkNode) or util.isNodeConnectedToFrozenEdge(startNode)
	if util.positionsEqual(startNodePos, linkNodePos, 5) and constructionId then 
		trace("Discovered startPositions are nearly equal  attempting upgrade instead", startNodePos.x, startNodePos.y, " vs ",linkNodePos.x, linkNodePos.y)
		--local constructionId = util.getConstructionEntityForNode(linkNode)
		local construction = util.getConstruction(constructionId)
		local params = util.deepClone(construction.params)
		params.seed = nil
		trace("Calling upgradeConstruction on ",constructionId)
		if pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end) then 
			util.clearCacheNode2SegMaps() 
			util.lazyCacheNode2SegMaps()
			trace("Upgrade successful")
		else 
			trace("WARNING! upgrade NOT successful")
		end 
	else 
		testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=stationLink
	end
	--trace("checking test proposal for errors")
	--debugPrint(testProposal)
	local testResult
	if not xpcall(function() 
		testProposal = proposalUtil.validateProposal(testProposal)
		testResult =  checkProposalForErrors(testProposal, true)
	end, err) then 
		trace("link failed validation")
		return false
	end
	local costs = testResult.costs
	if not (params and params.ignoreCosts) and not testResult.isError and costs >= costLimit then 
		local singleProposal = api.type.SimpleProposal.new()
		singleProposal.streetProposal.edgesToAdd[1]=stationLink
		for i, node in pairs({stationLink.comp.node0, stationLink.comp.node1}) do 
			if node < 0 then 
				for j, newNode in pairs(testProposal.streetProposal.nodesToAdd) do 
					if newNode.entity == node then 
						singleProposal.streetProposal.nodesToAdd[1+#singleProposal.streetProposal.nodesToAdd]=newNode
						break
					end 
				end 
			end 
		end 
		local singleResult = checkProposalForErrors(singleProposal)
		costs = singleResult.costs 
		trace("The costs of the single result was",costs,"vs.",testResult.costs)
		
	end 
	 
	if not testResult.isError and (costs < costLimit or params and params.ignoreCosts) or 
		params and params.ignoreErrors and not testResult.isCriticalError and not testResult.hasWaterMeshCollisions
		and (startNode > 0 or linkNode > 0)

		then 
		if params and params.linkRoadFilter and not params.linkRoadFilter(testResult) then 
			trace("link was removed by the linkRoadFilter, linkNode=",linkNode)
			return false 
		end 
		--trace("success, adding to main proposal")
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=stationLink
		if newNode then 
			newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode 
		end
		if not found  and maxRemaining > 0 then
			-- keep building out in a grid pattern until we make a connection
			found = constructionUtil.buildLinkRoad(newProposal, linkNode, tangent, maxRemaining-1, linkNodePos, nextNodeId, params, costLimit)
			found = found or constructionUtil.buildLinkRoad(newProposal, linkNode, util.rotateXY(tangent, math.rad(90)), maxRemaining-1, linkNodePos, nextNodeId, params, costLimit) 
			found = found or constructionUtil.buildLinkRoad(newProposal, linkNode, util.rotateXY(tangent, -math.rad(90)), maxRemaining-1, linkNodePos, nextNodeId, params, costLimit)
		end
			
	else 
		 trace("not success, not adding to main proposal, linkNode=",linkNode,"costs=",costs)
		found = false
		--if util.tracelog then debugPrint(testResult) end 
	end
	
	return found
end
	
function constructionUtil.completeBusNetwork(newProposal, depotConstr, busStationConstr, town, stationPosAndRot, isCargo, params)
	if stationPosAndRot.existingBusStation then 
		trace("Not completing bus network as there was already a station")
		return 
	end
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local townNode = util.findMostCentralTownNode(town).id
	local stationNodes = util.getFreeNodesForConstruction(busStationConstr) 
	local stationNode = util.getNodeClosestToPosition(stationPosAndRot.originalNodePos, stationNodes)
	trace("constructionUtil.completeBusNetwork: completing bus network for",town.name,"stationNode was",stationNode)
	local depotLinkPos
	local depotLinkNode 
	local builtLinkRoad = false
	
	if stationPosAndRot.underPassNodePos then 
		local underPassNode = util.getNodeClosestToPosition(stationPosAndRot.underPassNodePos)
		local underPassLink = initNewEntity(newProposal, stationPosAndRot.numlanes)
		underPassLink.comp.node0 = stationNode
		underPassLink.comp.node1 = underPassNode
		util.setTangent(underPassLink.comp.tangent0, stationPosAndRot.underPassNodePos - util.nodePos(stationNode))
		util.setTangent(underPassLink.comp.tangent1, stationPosAndRot.underPassNodePos - util.nodePos(stationNode))
		underPassLink.comp.tangent0.z = 0 -- seems we need to zero these out to avoid a "construction not possible"
		underPassLink.comp.tangent1.z = 0 
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassLink
	end
	
	if depotConstr then 
		local depotNode = util.getFreeNodesForConstruction(depotConstr)[1]
		depotLinkPos = stationPosAndRot.originalNodePos - 50*stationPosAndRot.busStationPerpTangent
		depotLinkPos.z = util.nodePos(depotNode).z
		local newNode = util.newNodeWithPosition(depotLinkPos, -1000-#newProposal.streetProposal.nodesToAdd)
		newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode 
		depotLinkNode = newNode.entity
		local stationLink = initNewEntity(newProposal, stationPosAndRot.numlanes)  	 
		stationLink.comp.node0 = depotLinkNode
		
		stationLink.comp.node1 = stationNode
		util.setTangent(stationLink.comp.tangent0, util.nodePos(stationNode)-depotLinkPos)
		util.setTangent(stationLink.comp.tangent1, util.nodePos(stationNode)-depotLinkPos)
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=stationLink
		
		local depotRoad = initNewEntity(newProposal)
		depotRoad.comp.node0 = depotNode
		depotRoad.comp.node1 = depotLinkNode
		util.setTangent(depotRoad.comp.tangent0, depotLinkPos - util.nodePos(depotNode))
		util.setTangent(depotRoad.comp.tangent1, depotLinkPos - util.nodePos(depotNode))
		depotRoad.streetEdge.streetType = util.getComponent(util.getSegmentsForNode(depotNode)[1], api.type.ComponentType.BASE_EDGE_STREET).streetType
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=depotRoad
		
		local depotLink = initNewEntity(newProposal, stationPosAndRot.numlanes) 
		local otherNode = stationPosAndRot.otherNode 
		if not api.engine.entityExists(otherNode) or not util.getNode(otherNode) or not util.positionsEqual(stationPosAndRot.otherNodePos, util.nodePos(otherNode)) then 
			otherNode = util.getClosestDoubleFreeNodeToPosition(stationPosAndRot.otherNodePos)
		end 
		local hasTrackSegments = #util.getTrackSegmentsForNode(otherNode) > 0
		if stationPosAndRot.buildCompleteRoute or hasTrackSegments then 
			trace("constructionUtil.completeBusNetwork: considering alternative nodes was", otherNode," hasTrackSegments?",hasTrackSegments)
			local segs = util.getStreetSegmentsForNode(otherNode)
			local existingDistance = util.distance(depotLinkPos, util.nodePos(otherNode))
			if hasTrackSegments then 
				existingDistance = math.huge
			end 
			local options = {}
			for i, seg in pairs(segs) do 
				local edge = util.getEdge(seg)
				for j, node in pairs({edge.node0, edge.node1}) do
					if node~= otherNode and #util.getSegmentsForNode(node) < 4 and util.distance(depotLinkPos, util.nodePos(node)) < existingDistance and #util.getTrackSegmentsForNode(node) == 0  then 
						table.insert(options, node)
					end 
				end 
			end 
			trace("constructionUtil.completeBusNetwork: considering options for other  connect node found ",#options)
			if #options > 0 then 
				otherNode = util.evaluateWinnerFromSingleScore(options, function(node) return util.distance(util.nodePos(node), depotLinkPos) end)
				trace("Changed the other node to",otherNode)
			end 
		end 
		if #util.getStreetSegmentsForNode(otherNode)== 0 then 
	
			 
			local closeNode = util.searchForNearestNode(util.nodePos(otherNode), 90, function(node) 
				return #util.getStreetSegmentsForNode(node.id) > 0 
				and #util.getTrackSegmentsForNode(node.id) == 0 
				and util.getEdge(util.getStreetSegmentsForNode(node.id)[1]).type==0
				and not util.isNodeConnectedToFrozenEdge(node.id)
			end)
			trace("Detected that the was a no street segments at ",otherNode," foundAlternative?",closeNode~=nil)
			if closeNode then 
				otherNode = closeNode.id
			end 
		end 
		depotLink.comp.node0 = otherNode
		
		depotLink.comp.node1 = depotLinkNode
		util.setTangent(depotLink.comp.tangent0, depotLinkPos - util.nodePos(otherNode))
		util.setTangent(depotLink.comp.tangent1, depotLinkPos - util.nodePos(otherNode))
		util.setTangent(depotLink.comp.tangent1, vec3.length(util.v3(depotLink.comp.tangent1))*vec3.normalize(util.v3(stationLink.comp.tangent0)))-- need to make sure tangents line up
		
		local testProposal = api.type.SimpleProposal.new()
		for i, edge in pairs(newProposal.streetProposal.edgesToAdd) do 
			testProposal.streetProposal.edgesToAdd[i]=edge
		end
		for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
			testProposal.streetProposal.nodesToAdd[i]=node
		end
		testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=depotLink
		if not checkProposalForErrors(testProposal).isCriticalError  and #util.getStreetSegmentsForNode(otherNode)>0 then 
			newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=depotLink
			trace("completeBusNetwork: depotLinkPos was ",depotLinkPos.x, depotLinkPos.y, " dist to depotnode was ",util.distance(depotLinkPos, util.nodePos(depotNode)), " length of depotRoadTangent was ",vec3.length(util.v3(depotRoad.comp.tangent0)))
			builtLinkRoad=true 
		else 
			trace("WARNING! Could not correct for test proposal")
		end 
	else 
		
		--stationLink.comp.node0 = stationPosAndRot.otherNode 
		
		--util.setTangents(stationLink, util.nodePos(stationNode)- util.nodePos(stationPosAndRot.otherNode))
		
		local stationNode = stationNodes
		local filterFn = function(node) 
			if stationPosAndRot.underPassNodePos and node == util.getNodeClosestToPosition(stationPosAndRot.underPassNodePos) then 
				trace("stationLink: Rejecting node",node,"as underpass node")
				return false
			end 
			if #pathFindingUtil.findRoadPathBetweenNodes(node, townNode) > 0 then 
				local stationLink = initNewEntity(newProposal, stationPosAndRot.numlanes)
				stationLink.comp.node0 = node
				local stationNode = util.getNodeClosestToPosition(util.nodePos(node), stationNodes)
				stationLink.comp.node1 = stationNode
				util.setTangents(stationLink, util.nodePos(stationNode)- util.nodePos(node))
				local testProposal = api.type.SimpleProposal.new()
				testProposal.streetProposal.edgesToAdd[1]=stationLink
				local isError = checkProposalForErrors(testProposal).isError 
				trace("stationLink: Attempt to add entity",util.newEdgeToString(stationLink),"isError?",isError)
				return not isError				
			end 
			trace("stationLink: Rejecting node",node,"as no road path found")
			return false 
		end 
		local originalNode = util.getClosestDoubleFreeNodeToPosition(stationPosAndRot.originalNodePos, filterFn)
		if originalNode then 
			local stationLink = initNewEntity(newProposal, stationPosAndRot.numlanes)
			stationLink.comp.node0 = originalNode
			local stationNode = util.getNodeClosestToPosition(util.nodePos(originalNode), stationNodes)
			stationLink.comp.node1 = stationNode
		 
			util.setTangents(stationLink, util.nodePos(stationNode)- util.nodePos(originalNode))
			stationLink.comp.tangent0.z = 0 
			stationLink.comp.tangent1.z = 0 
			newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=stationLink	
			trace("completeBusNetwork: Setting up station link between nodes",stationLink.comp.node0, stationLink.comp.node1)
			builtLinkRoad = true 
		else 
			trace("WARNING! Failed to find node around",stationPosAndRot.originalNodePos.x,stationPosAndRot.originalNodePos.y)
		end 
	end 
	

	

	local stationNode2 = stationNode == stationNodes[1] and stationNodes[2] or stationNodes[1]
	local params = {}
	params.linkRoadSearchRadius= 25
	local angleToTangent = math.abs(util.signedAngle(stationPosAndRot.stationPerpTangent, stationPosAndRot.tangent))
	local factor = math.cos(angleToTangent)+math.sin(angleToTangent)
	params.linkRoadSearchRadius=  params.linkRoadSearchRadius*factor
	trace("The angleToTangent was ",math.deg(angleToTangent), " increasing the search by ",factor," to ",params.linkRoadSearchRadius)
	--[[constructionUtil.buildLinkRoad(newProposal, stationNode2,  -1*stationPosAndRot.busStationParallelTangent, 1, nil, nil, params )
	constructionUtil.buildLinkRoad(newProposal, stationNode2, -1*stationPosAndRot.busStationPerpTangent, 2, nil, nil, params)
	constructionUtil.buildLinkRoad(newProposal, stationNode, stationPosAndRot.busStationParallelTangent, 2, nil, nil, params)]]--
	if not builtLinkRoad  and depotLinkNode  then 
		trace("Attempting to link with link roads")
		constructionUtil.buildLinkRoad(newProposal, depotLinkNode,  -1*stationPosAndRot.busStationParallelTangent, 1, depotLinkPos, nil, params )
		constructionUtil.buildLinkRoad(newProposal, depotLinkNode, -1*stationPosAndRot.busStationPerpTangent, 2, depotLinkPos, nil, params)
		constructionUtil.buildLinkRoad(newProposal, depotLinkNode, stationPosAndRot.busStationParallelTangent, 2, depotLinkPos, nil, params)
	else 
		--constructionUtil.buildLinkRoad(newProposal, stationNode,  stationPosAndRot.busStationPerpTangent, 2, nil, nil, params)
	end 	
	--[[if stationPosAndRot.isTerminus then 
		constructionUtil.buildLinkRoad(newProposal, stationNode, -1*stationPosAndRot.busStationParallelTangent, 2, nil, nil, params)
	end]]--
	local testData = checkProposalForErrors(newProposal)
	if testData.isError and util.tracelog then 
		trace("completeBusNetwork: testData found error")
		local testData = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
		debugPrint(testData.errorState)
		debugPrint(testData.collisionEntities)
	end 
	for i, node in pairs({stationNode, stationNode2}) do 
		for j, tangent in pairs({stationPosAndRot.busStationPerpTangent, stationPosAndRot.busStationParallelTangent}) do 
			for k, sign in pairs({-1, 1}) do 
				local depth = 1
				if stationPosAndRot.isTerminus then 
					depth = 2
				end 
				local tryBuild = true 
				if not stationPosAndRot.isTerminus and j == 1 and sign == 1 then -- do not build along the busStationPerpTangent, for short stations this can block track
					tryBuild = false 
				end
				
				if tryBuild then 
					local result = constructionUtil.buildLinkRoad(newProposal, node, sign*tangent, depth, nil, nil, params)
					trace("Result of try build at",i,j,k,"was",result)
				else 
					trace("Suppressing build at",i,j,k)
				end 
			end 
		end 
	end 
	
	
	
	--constructionUtil.buildLinkRoad(newProposal, stationNode, -1*stationPosAndRot.busStationPerpTangent, 2, nil, nil, params)
	--debugPrint(newProposal)
	if not isCargo and  util.countRoadStationsForTown(town.id) <= 2 then 
		buildTownBusStops(newProposal, town)
	end
	local testData = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if testData.errorState.isCriticalError then 
		if util.tracelog then 
			trace("WARNING! Critical error found in building bus network")
			debugPrint({newProposal=newProposal, testData=testData})
			error("Unable to complete bus network")
		end 
	end 
	
	return proposalUtil.attemptDeconfliction(newProposal)	
end
function constructionUtil.completeHarbourBusNetwork(town, busStationConstr, depotConstr, harbourConstr)
	trace("completeHarbourBusNetwork: begin for",town.name)
	if not busStationConstr then 
		trace("WARNING! No busStationConstr specified, aborting")
		return 
	end
	util.lazyCacheNode2SegMaps()
	local stationNodes = util.getFreeNodesForConstruction(busStationConstr) 
	local newProposal = api.type.SimpleProposal.new()
	local depotNode = depotConstr and  util.getFreeNodesForConstruction(depotConstr)[1] or nil
	local stationNodes = util.getFreeNodesForConstruction(busStationConstr) 
	local stationNode1  = stationNodes[1]
	local stationNode2  = stationNodes[2]
	if depotNode and util.distance(util.nodePos(depotNode), util.nodePos(stationNodes[1])) > util.distance(util.nodePos(depotNode), util.nodePos(stationNodes[2]))  then
		stationNode2 = stationNodes[1]
		stationNode1 = stationNodes[2]
	end
	if depotNode then 
		local depotLink = initNewEntity(newProposal)  	
		depotLink.comp.node0 = stationNode1
		
		depotLink.comp.node1 = depotNode
		trace("building depot link, linking",stationNode1," to ", depotNode)
		
		
		util.setTangentsForStraightEdgeBetweenExistingNodes(depotLink)
		local depotEdge = util.getStreetEdge(util.getConstruction(depotConstr).frozenEdges[1])
		depotLink.streetEdge = depotEdge
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=depotLink
	end
	trace("Building link roads, stationNode1 was",stationNode1," stationNode2 was ",stationNode2)
	local stationNode1Pos = util.nodePos(stationNode1)
	local stationNode2Pos = util.nodePos(stationNode2)
	local stationNode2Tangent =  stationNode2Pos-stationNode1Pos
	local found = false
	local costLimit = 1000000
	local params = {}
	params.ignoreErrors = true
	params.ignoreCosts = true -- need to make sure we make a connection
	params.linkRoadFilter = function(testResult)
		return not ( -- we ignore errors but do not collide with our own constructions
			testResult.collisionEntitySet[harbourConstr] 
			or testResult.collisionEntitySet[busStationConstr]
			or depotConstr and testResult.collisionEntitySet[depotConstr])
	end 
	
	local nextNode = -1000
	local function nextNodeId()
		nextNode = nextNode -1
		return nextNode
	end
	
	local townNode = util.findMostCentralTownNode(town) 
	local function nodeFilterFn(node) 
		if node.id == stationNode1 or node.id == stationNode2 or util.isFrozenNode(node.id) then 
			return false 
		end
		if #util.getTrackSegmentsForNode(node.id) > 0 then 
			return false 
		end
		if #util.getStreetSegmentsForNode(node.id) > 3 then 
			return false 
		end		
		return #pathFindingUtil.findRoadPathBetweenNodes(node.id, townNode.id)>0 or #pathFindingUtil.findRoadPathBetweenNodes(townNode.id, node.id)>0
	end 
	local nearbyUrbanNode = util.searchForNearestNode(stationNode2Pos, 250, nodeFilterFn) 
	local canDirectLink = false 
	local linkedNodes = {}
	if nearbyUrbanNode then
		nearbyUrbanNode = nearbyUrbanNode.id
		local nodePos = util.nodePos(nearbyUrbanNode)
		local node2Closer = util.distance(nodePos, stationNode2Pos) < util.distance(nodePos, stationNode1Pos)
		local nearestNode = node2Closer and stationNode2 or stationNode1 
		local nearestNodePos = node2Closer and stationNode2Pos or stationNode1Pos 
		if util.distance(nodePos, nearestNodePos) < 90 and math.abs(nodePos.z-nearestNodePos.z) < 0.2*vec2.distance(nodePos, nearestNodePos) then
			local tangent = nearestNodePos - nodePos
			found = constructionUtil.buildLinkRoad(newProposal, nearestNode, tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)  
			if not found then 
				trace("Unable to link to nearbyUrbanNode attempting other")
				local otherNode = node2Closer and stationNode1 or stationNode2 
				local tangent = util.nodePos(nearestNode) - nodePos
				found = constructionUtil.buildLinkRoad(newProposal, nearestNode, tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)  
			end 
			trace("Result of building link road was",found)
			if found then 
				linkedNodes[nearestNode]=true
			end 
		end
	end
	trace("completeHarbourBusNetwork: The nearbyUrbanNode was",nearbyUrbanNode," for town",town.name )
	if depotNode then 
		local depotTangent = stationNode1Pos-util.nodePos(depotNode)
		if nearbyUrbanNode then 
			if not linkedNodes[stationNode1] then 
				found =    constructionUtil.buildLinkRoad(newProposal, stationNode1, depotTangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)  or found 
			end 
			if not linkedNodes[stationNode2] then 
				found = constructionUtil.buildLinkRoad(newProposal, stationNode2,depotTangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)  or found  
			end
		end
	elseif nearbyUrbanNode then
		found = found or  constructionUtil.buildLinkRoad(newProposal, stationNode1,stationNode2Tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)  
		found = found or constructionUtil.buildLinkRoad(newProposal, stationNode2, -1*stationNode2Tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)  
	end
	if nearbyUrbanNode then 
		found = found or constructionUtil.buildLinkRoad(newProposal, stationNode1, -1*stationNode2Tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit) 
		found = found or constructionUtil.buildLinkRoad(newProposal, stationNode2,stationNode2Tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)
	end
	if found and #pathFindingUtil.findRoadPathBetweenNodes(found, townNode.id)==0 then 
		trace("Found node",node," but no path was found")
		found = not found
	end 
	if not found then 
		local townPos = util.v3fromArr(town.position)
		local distToTown = util.distance(stationNode2Pos, townPos )
		local midPoint = 0.5*(townPos+stationNode2Pos)
		local filterFn = function(node) 
			return nodeFilterFn(node) and #util.getStreetSegmentsForNode(node.id) == 1
		end 
		
		local connectNode =  util.searchForNearestNode(midPoint, distToTown/2, filterFn) 
		trace("No connection found, attempting to build to ",connectNode)
		if not connectNode then 
			trace("Getting desperate, trying a direct link")
			local newProposal = api.type.SimpleProposal.new()
			local entity = util.buildConnectingRoadToNearestNode(stationNode2, -1, true, newProposal)
				if  entity then 
				
					trace("buildHarbourBusNetwork: building entity connecting nodes",entity.comp.node0,entity.comp.node1)
					newProposal.streetProposal.edgesToAdd[1]=entity 
					local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
		 
					api.cmd.sendCommand(build,function(res, success) 
						trace("Built linkRoad success was",success)
						constructionUtil.standardCallback(res,success)
					end)
					util.clearCacheNode2SegMaps()
				end 
			local newProposal = api.type.SimpleProposal.new()
			local entity2  =util.buildConnectingRoadToNearestNode(stationNode1, -1, true, newProposal)
			if  entity2 then  
					newProposal.streetProposal.edgesToAdd[1]=entity2 
					trace("buildHarbourBusNetwork: building entity connecting nodes",entity.comp.node0,entity.comp.node1)
					local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
					 
					api.cmd.sendCommand(build,function(res, success) 
						trace("Built linkRoad success was",success)
						constructionUtil.standardCallback(res,success)
					end)
					util.clearCacheNode2SegMaps()
				end 
		else 
			constructionUtil.addWork(function() 
				local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
				routeBuilder.buildRoute({stationNode2, connectNode.id}, params, constructionUtil.standardCallback)		
			end) 
		
		end
	end
	--buildTownBusStops(newProposal, town)
	local allNodes = {}
	for i, newNode in pairs(newProposal.streetProposal.nodesToAdd) do 
		assert(not allNodes[newNode.entity])
		allNodes[newNode.entity]=true
	end
	local referencedNodes = {}
	for i, newEdge in pairs(newProposal.streetProposal.edgesToAdd) do 
		for __, node in pairs({newEdge.comp.node0, newEdge.comp.node1}) do 
			if node< 0 and not referencedNodes[node] then 
				referencedNodes[node]=true 
			end
		end 
	end
	for node, bool in pairs(allNodes) do 
		if not referencedNodes[node] then 
			trace("WARNING! node ",node, " was not referenced")
		end
	end
	for node, bool in pairs(referencedNodes) do 
		if not allNodes[node] then 
			trace("WARNING! node ",node, " referenced a node not added")
		end
	end
	assert(util.size(allNodes)==util.size(referencedNodes))
	
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace(" About to sent command to build harbour link")
		api.cmd.sendCommand(build, function(res, success) 
			trace(" attempt command result was", tostring(success))
			util.clearCacheNode2SegMaps()
			if success then 
				if util.countRoadStationsForTown(town.id) <= 2 then 
					constructionUtil.addWork(function() 
						local newProposal = api.type.SimpleProposal.new()
						buildTownBusStops(newProposal, town)
						if util.tracelog then debugPrint(newProposal) end
						build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
						api.cmd.sendCommand(build, function(res, success) 
							trace(" attempt to build harbor bus stops result was", tostring(success))
							util.clearCacheNode2SegMaps()
						end)
					end)
				end 
				constructionUtil.addDelayedWork(function() constructionUtil.lineManager.setupTownBusNetwork( busStationConstr, town, "Harbour") end)
			else 
				if util.tracelog then debugPrint(res) end
			end
			--constructionUtil.standardCallback(res, success)
		end)

	
	
end
function constructionUtil.completeAirportBusNetwork( depotConstr, busStationConstr, town, nodeDetails)
	--assert(string.find(util.getComponent(depotConstr, api.type.ComponentType.CONSTRUCTION).fileName, "depot"))
	if nodeDetails.existingBusStation then 
		trace("Not completing bus network as there was already a station")
		return  
	end
	trace("completeAirportBusNetwork: begin for",town.name)
	util.lazyCacheNode2SegMaps()
	local newProposal = api.type.SimpleProposal.new()
	local backupProposal = api.type.SimpleProposal.new()
	assert(string.find(util.getComponent(busStationConstr, api.type.ComponentType.CONSTRUCTION).fileName, "station/street"))
	local depotNode = depotConstr and util.getFreeNodesForConstruction(depotConstr)[1]
	local stationNodes = util.getFreeNodesForConstruction(busStationConstr) 
	local stationNode1 
	local stationNode2 
	local nodePos =  nodeDetails.nodePos
	local isTramDepot = string.find(util.getComponent(depotConstr, api.type.ComponentType.CONSTRUCTION).fileName, "tram")
	if util.distance(nodePos, util.nodePos(stationNodes[1])) > util.distance(nodePos, util.nodePos(stationNodes[2])) then
		stationNode1 = stationNodes[1]
		stationNode2 = stationNodes[2]
	else 
		stationNode2 = stationNodes[1]
		stationNode1 = stationNodes[2]
	end
	if depotNode then 
		if util.distance(util.nodePos(stationNode1), util.nodePos(depotNode)) > util.distance(util.nodePos(stationNode2), util.nodePos(depotNode)) then 
			trace("completeAirportBusNetwork: swapping station nodes for link")
			local temp = stationNode1 
			stationNode1 = stationNode2 
			stationNode2 = temp
		end
		local depotLink = initNewEntity(newProposal)  	
		depotLink.comp.node0 = stationNode1
		
		depotLink.comp.node1 = depotNode
		trace("building depot link, linking",statioNode1," to ", depotNode)
		util.setTangentsForStraightEdgeBetweenExistingNodes(depotLink)
		if isTramDepot then 
			depotLink.streetEdge.tramTrackType = 2 -- by the airport era catenary must be availabile\
		end
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=depotLink
		backupProposal.streetProposal.edgesToAdd[1+#backupProposal.streetProposal.edgesToAdd]=depotLink
	end
	
	local stationNode2Pos = util.nodePos(stationNode2)
	local stationTangent = util.getDeadEndNodeDetails(stationNode2).tangent
	local angle = util.signedAngle(nodeDetails.tangent, stationTangent)
	local angle2 = math.abs(util.signedAngle(nodePos-stationNode2Pos, stationTangent))
	local needsAngleCorrection = angle2 > math.rad(10) 
	trace("The angle to the station tangent was", math.deg(angle)," angle2=",math.deg(angle2), "needsAngleCorrection?",needsAngleCorrection)
	local stationLink = initNewEntity(newProposal)  	 
	stationLink.comp.node0 = stationNode2
	
	local function findAppropriateNode()
		local result =  util.searchForNearestNode(nodeDetails.nodePos, 150, function(node) 
			for i, seg in pairs(util.getStreetSegmentsForNode(node.id)) do 
				if util.getStreetTypeCategory(seg)=="highway" then 
					return false 
				end
			end 
			return #util.getTrackSegmentsForNode(node.id)==0 and node.id ~=stationNode2 and node.id~=stationNode1 and not util.isFrozenNode(node.id) and #util.getStreetSegmentsForNode(node.id) < 4
		end )
		if result then 
			return result.id 
		else 
			trace("WARNING! No result found")
		end 
	end 
	if not api.engine.entityExists(nodeDetails.node) or not util.getNode(nodeDetails.node) or #util.getStreetSegmentsForNode(nodeDetails.node) == 4 then 
		trace("Possible invalid node, attempting to compensate at ",nodeDetails.node)
		nodeDetails.node = findAppropriateNode()
		nodePos = util.nodePos(nodeDetails.node)
	end

 	stationLink.comp.node1 = nodeDetails.node
	
	
	local dist = util.distance(stationNode2Pos, nodePos)
	
	local needsSecondSegment = dist> 1.5*90 or needsAngleCorrection
	trace("The dist of the airport station link was ",dist, "needsSecondSegment=",needsSecondSegment, "needsAngleCorrection=",needsAngleCorrection)
	local newNode
	local midPoint = 0.5*(stationNode2Pos+nodePos)
	if needsAngleCorrection then  
		local a = dist*math.cos(angle2)
		local o = dist*math.sin(angle2)
		local splitDist = math.max(a-o, 16)
		midPoint = stationNode2Pos + splitDist*vec3.normalize(stationTangent)
		trace("Setting the mid point at the splitDist=",splitDist," at ",midPoint.x, midPoint.y)
	end 
	
	local testProposal = api.type.SimpleProposal.new()
	testProposal.streetProposal.edgesToAdd[1 ]=stationLink
	local isError = checkProposalForErrors(testProposal).isError
	if isError then 
		trace("The stationLink was error, attempting other")
		stationLink.comp.node0 = stationNode1
		local testProposal = api.type.SimpleProposal.new()
		testProposal.streetProposal.edgesToAdd[1 ]=stationLink
		isError = checkProposalForErrors(testProposal).isError
		trace("Was still error = ",isError)
	end 
	
	if needsSecondSegment then 
		
		newNode = util.newNodeWithPosition(midPoint, -100-#newProposal.streetProposal.nodesToAdd)
		
		stationLink.comp.node1 = newNode.entity 
		local tangent = midPoint - stationNode2Pos
		util.setTangents(stationLink, tangent)
	else 
		util.setTangentsForStraightEdgeBetweenExistingNodes(stationLink)
	end	
	local testProposal = api.type.SimpleProposal.new()
	testProposal.streetProposal.edgesToAdd[1 ]=stationLink
	if newNode then 
		testProposal.streetProposal.nodesToAdd[1]=newNode
	end 
	local isError = checkProposalForErrors(testProposal).isError
	trace("completeAirportBusNetwork: building station link, linking",stationNode2," to ", nodeDetails.node, " isError=",isError, " base link nodes were",stationLink.comp.node0,stationLink.comp.node1)
	if isError then 
		trace("Not successful, rolling back")
		--newProposal.streetProposal.edgesToAdd[#newProposal.streetProposal.edgesToAdd]=nil 
	--if needsSecondSegment then 
	--		newProposal.streetProposal.nodesToAdd[#newProposal.streetProposal.nodesToAdd] = nil
		--end 
	else 
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=stationLink  
		if newNode then 
			newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd] = newNode
		end 
	end 	
	local costLimit = 5000000
	local perpTangent = util.rotateXY(nodeDetails.tangent, math.rad(90))
	local found = false
	for i, node in pairs({stationNode1, stationNode2}) do 
		for j, tangent in pairs({nodeDetails.tangent, perpTangent}) do 
			for k, sign in pairs({-1, 1}) do 
				local depth = 1
				  
				 
				local result = constructionUtil.buildLinkRoad(newProposal, node, sign*tangent, depth, nil, nil, params, costLimit)
				trace("completeAirportBusNetwork: Result of try build",node,"at",i,j,k,"was",result,"from node",node)
				found = found or result
			end 
		end 
	end
	
	

	if needsSecondSegment and not isError then 
		local stationLink2 = initNewEntity(newProposal) 
		stationLink2.comp.node0 = newNode.entity 
		stationLink2.comp.node1 = nodeDetails.node
		if needsAngleCorrection then 
			local t0 = vec3.normalize(stationTangent)
			local t1 = -1*vec3.normalize(nodeDetails.tangent)
			local tangentLength = util.calculateTangentLength(midPoint, nodePos , t0, t1)
			util.setTangent(stationLink2.comp.tangent0, tangentLength*t0)
			util.setTangent(stationLink2.comp.tangent1, tangentLength*t1)
		else 
			local tangent = nodePos- midPoint 
			util.setTangents(stationLink2, tangent)	
		end 
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=stationLink2	
	end
	--constructionUtil.buildLinkRoad(newProposal, stationNode1, -1*nodeDetails.tangent)
	if util.countRoadStationsForTown(town.id) <= 2 then 
		buildTownBusStops(newProposal, town)
	end
	--local isError = checkProposalForErrors(newProposal).isError
	if isError and not found then
		trace("completeAirportBusNetwork: Attempting route build")
		constructionUtil.addWork(function() 
			local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
			routeBuilder.buildRoute({stationNode2, nodeDetails.node}, params, constructionUtil.standardCallback)		
		end) 
		newProposal = backupProposal
	end 
	trace("completeAirportBusNetwork: end")
	return newProposal
end

local function checkIfCanAddPlatform(constructionId, left, templateIndex)
	collectgarbage() -- may be superstition but this function sometimes causes unexplained game crash, trying to mitigate
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local params = util.deepClone(construction.params)
	if util.tracelog then 
		debugPrint({paramsBefore=params})
	end 
	if left then
		params.platL = params.platL + 1
		if params.platL > 10 then 
			trace("checkIfCanAddPlatform: platL exceeds 10, aborting",params.platL)
			return false 
		end 
	else 
		params.platR = params.platR + 1
		if params.platR > 10 then 
			trace("checkIfCanAddPlatform: platR exceeds 10, aborting", params.platR)
			return false 
		end 
	end
	if params.includeLargeBuilding then 
		trace("Skipping check for includeLargeBuilding")
		return true 
	end

	params.templateIndex =  templateIndex
	
	params.suppressAllEntrances = true 
	params.modules =  util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params)) 
	params.suppressAllEntrances = false	
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	local naming = util.getComponent(constructionId, api.type.ComponentType.NAME)
	newConstruction.name= naming.name
		
	newConstruction.fileName = construction.fileName
	newConstruction.playerEntity = api.engine.util.getPlayer() 
		 
	newConstruction.params = params  
	newConstruction.transf = construction.transf
	local testProposal = api.type.SimpleProposal.new()
	
	-- superceded by using the supression of new road
	
	--[[local freeNodes = util.getFreeNodesForConstruction(constructionId)
	local alreadySeen = {}
	trace("Found ",util.size(freeNodes)," for construction",constructionId)
	for i, node in pairs(freeNodes) do
		local segs = util.getStreetSegmentsForNode(node)
		for j, seg in pairs(segs) do 
			if not util.isFrozenEdge(seg) and not alreadySeen[seg] then 
				alreadySeen[seg]=true
				trace("Removing segment ",seg," for platform check")
				 testProposal.streetProposal.edgesToRemove[1+#testProposal.streetProposal.edgesToRemove]=seg
			end
		end
		if #segs > 1 then 
			trace("Removing node ",node," for platform check")
		 	testProposal.streetProposal.nodesToRemove[1+#testProposal.streetProposal.nodesToRemove]=node
		end
		if #segs > 2 then 
			trace("Skipping check for large number of segments")-- seems to cause a game crash not clear why
			return true 
		end
	end--]]
	
	
	testProposal.constructionsToRemove = { constructionId} 
	testProposal.constructionsToAdd[1+#testProposal.constructionsToAdd] = newConstruction
	--testProposal.old2new[constructionId] = 1
	if util.tracelog then 
		trace("About to setup proposal checkIfCanAddPlatform")
		debugPrint(testProposal)
	end 
	
	local result = checkProposalForErrors(testProposal, true)
	trace("The check of whether to build on the ",(left and "left" or "right")," was ",result.isError)
	
	return not result.isError
end


function constructionUtil.buildTramOrBusStopsAlongRoute(station1, station2, params, callback, isTram)
	local maxDist = 4 * util.distBetweenStations(station1, station2) + 1000
	local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2, isTram, maxDist)
	if not routeInfo then 
		trace("WARNING! No route info found between stations, aborting") 
		callback({}, true)
		return
	end 
	local town = api.engine.system.stationSystem.getTown(station1)
	local segmentCount = routeInfo.lastFreeEdge - routeInfo.firstFreeEdge
	trace("The segmentCount of the route was ",segmentCount)
	local halfway = math.floor((routeInfo.firstFreeEdge+routeInfo.lastFreeEdge)/2)
	local startFrom = (segmentCount % 3 == 0 and 3 or 4)+routeInfo.firstFreeEdge  
	local buildEdges = {} 
	if segmentCount <= 6 then 
		buildEdges = { routeInfo.edges[halfway]}
	else 
		local lastIdx =0
		local function edgeIsSuitable(index)
			local edge = routeInfo.edges[index].edge
			local edgeId = routeInfo.edges[index].id
			if edge.type ~= 0 then 
				return false 
			end 
			local minLength = 40 
			local edgeWidth = util.getEdgeWidth(edgeId)
			for __, node in pairs({edge.node0 , edge.node1}) do
				if #util.getTrackSegmentsForNode(node)  > 0 then 
					return false 
				end 
				if #util.getSegmentsForNode(node) > 2  then -- obtuse angle junctions can prevent build
					if #util.getSegmentsForNode(node) == 3 then 
						local details = util.getOutboundNodeDetailsForTJunction(node)
						for __, seg in pairs(util.getSegmentsForNode(node)) do 
							if seg ~= details.edgeId then 
								local otherEdge = util.getEdge(seg)
								local otherTangent = otherEdge.node0 == node and otherEdge.tangent0 or otherEdge.tangent1 
								local angle = math.abs(util.signedAngle(otherTangent, details.tangent)) 
								if angle > math.rad(90) then 
									angle = math.rad(180)- angle
								end 
								local minNodeSize = edgeWidth * (1/math.tan(angle))
								if angle == math.rad(90) then 
									minNodeSize = 0
								end 
								trace("Calculated the minNodeSize as ",minNodeSize," for angle",math.deg(angle))
								minLength = math.max(minLength, edgeWidth+minNodeSize)
							end 
						end 
					else  -- simplified calculation for bigger junctions as calculating the node size is much harder
						local ourTangent = edge.node0 == node and edge.tangent1 or edge.tangent0
						for __, seg in pairs(util.getSegmentsForNode(node)) do 
							if seg ~= edgeId then 
								local otherEdge = util.getEdge(seg)
								local otherTangent = otherEdge.node0 == node and otherEdge.tangent0 or otherEdge.tangent1 
								local angle = math.abs(util.signedAngle(otherTangent,ourTangent)) 
								local angleMod90 = (angle+math.rad(5)) % math.rad(90)
								local overThreashold = angleMod90 > math.rad(10)
								trace("For a multi crossing junction, the angle was",math.deg(angle)," the angleMod90 was",math.deg(angleMod90), " overThreashold?",overThreashold)
								if overThreashold then 
									minLength = math.max(minLength, 70)
								end
							end 
						end 
						
						
					end
				end 
			end
			if util.calculateSegmentLengthFromEdge(edge) < minLength then 
				return false 
			end 
			if #edge.objects > 0 or #routeInfo.edges[index-1].edge.objects > 0 or #routeInfo.edges[index+1].edge.objects > 0 then 
				return false 
			end
			if index - lastIdx <= 1 then 
				return false 
			end
			return util.getStreetTypeCategory(edgeId) == "urban" 
		end
		local function insert(idx) 
			table.insert(buildEdges,routeInfo.edges[idx])
			lastIdx = idx
		end 
		
		for i = startFrom, routeInfo.lastFreeEdge-2, 3 do 
			trace("Building a tram stop on edgeIdx",(i-routeInfo.firstFreeEdge )," of ",segmentCount)
			if edgeIsSuitable(i)then 
				insert(i)
			elseif  edgeIsSuitable(i-1) then 
				insert(i-1)
			elseif edgeIsSuitable(i+1) then
				insert(i+1)
			end
		end 
	end 
	for i , edge in pairs(buildEdges) do 
		local edgeToUse = edge.edge 
		local edgeId = edge.id
		local node0 = edgeToUse.node0 
		local node1 = edgeToUse.node1
		local mode = isTram and _("Tram") or _("Bus")
		local name = util.getComponent(town, api.type.ComponentType.NAME).name.." "..mode.." ".._("stop").." "..tostring(i)
		local newProposal = api.type.SimpleProposal.new()
		constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
		trace("Building tram stops")
		api.cmd.sendCommand(build,function(res, success) 
			util.clearCacheNode2SegMaps()
			if success then 
				constructionUtil.addWork(function() 
					util.lazyCacheNode2SegMaps() 
					local newProposal = api.type.SimpleProposal.new()
					local newEdge = util.findEdgeConnectingNodes(node0, node1)
					constructionUtil.buildBusStopOnProposal(newEdge, newProposal, name)
					--local callbackToUse = i == #buildEdges and callback or constructionUtil.standardCallback
					local callbackToUse = i == 1 and callback or constructionUtil.standardCallback -- work executed in reverse order
					trace("Building second bus stop, will be calling back?",i==1)
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false), callbackToUse)
				end)
			else 
				trace("The tramp stop build failed")
				debugPrint(res)
				callback(res, success)
			end
		end) 
	end
end
function constructionUtil.buildTrainDepotAlongRoute(station1, station2, params, callback,offset, line )
	local options = {}
	if not offset then offset = 15 end  -- Initialize offset early

	local stations = {}
	if line then 
		for i = 1, #line.stops do 
			local stop = line.stops[i]
			table.insert(stations, util.stationFromStop(stop))  
		end 
	else 
		stations = { station1, station2} 
	end 
	for i = 1, #stations do
		local station1 = stations[i]
		local station2 = i==#stations and stations[1] or stations[i+1]
		local routeInfo = pathFindingUtil.getRouteInfo(station1, station2)

		-- Skip if no route found between stations (not connected yet)
		if not routeInfo then
			trace("buildTrainDepotAlongRoute: No route found between stations", station1, station2)
			goto continue_stations
		end

		local town1 = util.getEntity(api.engine.system.stationSystem.getTown(station1))
		local town2 = util.getEntity(api.engine.system.stationSystem.getTown(station2))

		for i = routeInfo.firstFreeEdge+4, routeInfo.lastFreeEdge-4 do 
			local edge = routeInfo.edges[i].edge
			local newPosAndRot = {}
			local priorEdge = routeInfo.edges[i-1].edge 
			local isBackwards = edge.node1 == priorEdge.node0 
			local stationParallelTangent = vec3.normalize(util.v3(edge.tangent1))
			if isBackwards then 
				stationParallelTangent = -1*stationParallelTangent
			end 
			local tangentAngle= math.abs(util.signedAngle(edge.tangent0, edge.tangent1))
			local perpTangent1 = util.rotateXY(stationParallelTangent, math.rad(90)) -- this arrangement always ensures the depot is built on the right hand side 
			local perpTangent2 = util.rotateXY(stationParallelTangent, -math.rad(90))
			local stationRelativeAngle = 0
			newPosAndRot.position = util.nodePos(edge.node1) + offset *perpTangent2
			newPosAndRot.rotation= math.rad(90)-util.signedAngle(perpTangent1, vec3.new(0, 1,0))
			local rotation  = vec3.xyAngle(perpTangent1)
			trace("The original rotation was",newPosAndRot.rotation,"the new rotation",rotation)
			newPosAndRot.rotation=rotation
			newPosAndRot.stationPerpTangent = perpTangent2
			newPosAndRot.stationParallelTangent = stationParallelTangent
			newPosAndRot.stationRelativeAngle = stationRelativeAngle
			local town 
			if i > 0.5*(routeInfo.firstFreeEdge + routeInfo.lastFreeEdge) then 
				town = town1
			else 
				town = town2
			end
			local isElectricTrack = util.getTrackEdge(routeInfo.edges[i].id).catenary	
			params.isElectricTrack = params.isElectricTrack or isElectricTrack
			local depot = constructionUtil.createRailDepotConstruction(newPosAndRot, town,  params, forceTerminus)
			trace("Attempting to build depot at",town.name,"isBackwards?",isBackwards)
			local checkResult = checkConstructionForCollision(depot)  
			if not checkResult.isError and util.isValidCoordinate(newPosAndRot.position) then
				table.insert(options, { depot = depot , scores = {
					checkResult.costs,
					util.countNearbyEntities(newPosAndRot.position, 100, "BASE_EDGE"),
					tangentAngle
				}})
			end


		end
		::continue_stations::
	end
	trace("Depot along route got ",#options)
	if #options == 0 and offset < 50 then
		trace("Attempting again with larger offset")
		constructionUtil.buildTrainDepotAlongRoute(station1, station2, params, callback,offset+5 )
		return
	end
	if #options == 0 then
		trace("buildTrainDepotAlongRoute: No valid depot locations found after all attempts")
		callback({error = "No valid depot locations found - stations may not be connected"}, false)
		return
	end
	local option = util.evaluateWinnerFromScores(options)
	if not option then
		trace("buildTrainDepotAlongRoute: Failed to evaluate best depot location")
		callback({error = "Failed to evaluate depot locations"}, false)
		return
	end
	local newProposal = api.type.SimpleProposal.new()
	newProposal.constructionsToAdd[1]=option.depot
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace("Building train depot")
	api.cmd.sendCommand(build,function(res, success) 
		if success then 
			util.clearCacheNode2SegMaps()
			constructionUtil.addWork(function() 
				routeBuilder.buildDepotConnection(callback, res.resultEntities[1], params) 
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end
function constructionUtil.buildDepotAlongRoute(station1, station2, params, carrier, callback, line)
	trace("buildDepotAlongRoute: got call to build between",station1,station2, "carrier=",carrier)
	--trace(debug.traceback())
	if carrier	 == api.type.enum.Carrier.RAIL then 
		constructionUtil.buildTrainDepotAlongRoute(station1, station2, params, callback,nil, line)
	end 
	if carrier	 == api.type.enum.Carrier.TRAM then 
		constructionUtil.buildTramDepotAlongRoute(station1, station2, params, callback)
	end
	if carrier	 == api.type.enum.Carrier.ROAD then 
		constructionUtil.buildRoadDepotAlongRoute(station1, station2, params, callback)
	end
	if carrier	 == api.type.enum.Carrier.WATER then 
		constructionUtil.buildShipDepotAlongRoute(station1, station2, params, callback)
	end
end
function constructionUtil.buildShipDepotAlongRoute(station1, station2, params, callback)
	trace("buildShipDepotAlongRoute begin")
	local depotConstruction = api.type.SimpleProposal.ConstructionEntity.new() 
	local depotParams={  
		  paramX = 0,
		  paramY = 0,
		  seed = 0,
		  year = util.year(),
	}
	depotConstruction.params = depotParams
	depotConstruction.name=_("Shipyard")
	depotConstruction.fileName = "depot/shipyard_era_a.con"
	depotConstruction.playerEntity = api.engine.util.getPlayer()

 
	local stationTangent = vec3.new(0,-1,0)
	local range = 1000 
	local minDist = 120 
	local meshGroups = pathFindingUtil.getWaterMeshGroups() 
	-- NB it seems the check proposal does not detect collision between the depot and harbour 
	local function filterFn(vertex) 
		return true or vertex.mesh ~= meshId -- put the depot on a different vertex 
			and meshGroups[vertex.mesh]==waterMeshGroup -- but still in the same group (i.e. it is connected)
	end
	local stationPos1 = util.getStationPosition(station1)
	local stationPos2 = util.getStationPosition(station2)	
	local depotVerticies = util.combine(util.getClosestWaterVerticies(stationPos1, range, minDist, filterFn), util.getClosestWaterVerticies(stationPos2, range, minDist, filterFn))

	local nextIndex = 1
	local count = 0
	local depotOffset = 35
	local lastAttempt = #depotVerticies
	repeat

		if nextIndex == #depotVerticies then 
			nextIndex = 0 
		end
		count = count +1
		trace("Checking shipyard construction attempt number ",count)
		local depotPos = vec3.new(depotVerticies[nextIndex+1].p.x, depotVerticies[nextIndex+1].p.y, 2)--we know this is a water mesh point
		local depotRot= util.signedAngle(stationTangent, vec3.new(depotVerticies[nextIndex+1].t.x, depotVerticies[nextIndex+1].t.y,0))
		local mesh =  util.getComponent(depotVerticies[nextIndex+1].mesh, api.type.ComponentType.WATER_MESH)
		local contour = mesh.contours[depotVerticies[nextIndex+1].contour]
		local isError
		if util.distance(depotPos, stationPos1) > 120 then
			depotConstruction.transf = util.transf2Mat4f(rotZTransl(depotRot,depotPos ))
			trace("Checking harbour for collision with shipyard, depotRot=",math.deg(depotRot),"depotPos=",depotPos.x,depotPos.y)
			local constructionResult = checkConstructionForCollision(depotConstruction)
			isError = constructionResult.isError
		end
		local nextVertex = 1
		while isError do 
			trace("Harbour depot collision detected, attempting to correct ", nextVertex, nextIndex)
			if nextVertex <=#contour.vertices  then  
				local p = contour.vertices[nextVertex]
				local t = contour.normals[nextVertex]
				for depotOffset = -40, 40, 5 do 
					depotPos = vec3.new(p.x, p.y, 2)+ depotOffset*vec3.normalize(vec3.new(t.x, t.y,0))
					depotRot= util.signedAngle(stationTangent, vec3.new(t.x, t.y,0))
					if util.distance(depotPos, stationPos1) > 120 then
						depotConstruction.transf = util.transf2Mat4f(rotZTransl(depotRot,depotPos ))
						trace("Checking harbour for collision with shipyard2, depotRot=",math.deg(depotRot),"depotPos=",depotPos.x,depotPos.y, " depotOffset=",depotOffset)
						local constructionResult = checkConstructionForCollision( depotConstruction)
						isError = constructionResult.isError
					end
					if isError then 
						break 
					end
				end
				nextVertex= nextVertex +1
				
			else
				nextVertex = 1
				nextIndex = nextIndex + 1
				break
			end
		end			
	until not isError or count >= lastAttempt
	local newProposal = api.type.SimpleProposal.new()
	
	newProposal.constructionsToAdd[1] = depotConstruction
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace("Building ship depot ")
	api.cmd.sendCommand(build,callback)
end

function constructionUtil.createTramDepotConstruction(naming, position, angle)
	if angle > math.rad(360) then 
		angle = angle - math.rad(360)
	end 
	if angle < -math.rad(360) then 
		angle = angle + math.rad(360)
	end
	local tramDepot = api.type.SimpleProposal.ConstructionEntity.new()
	tramDepot.fileName = "depot/tram_depot_era_a.con"
	tramDepot.playerEntity = api.engine.util.getPlayer()
	 tramDepot.params={
		paramX = 0,  
		paramY = 0, 
		seed = 0, 
		tramCatenary = util.year()>=game.config.tramCatenaryYearFrom and 1 or 0,			
		year = util.year()}
	tramDepot.name = naming.name.." ".._("Tram depot")
	local trnsf = rotZTransl(angle, position)
	tramDepot.transf = util.transf2Mat4f(trnsf)
	return tramDepot
end 

function constructionUtil.upgradeToElectricTramDepot(depotEntity)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(depotEntity)
	local construction = util.getConstruction(constructionId) 
	local params = util.deepClone(construction.params) 
	params.tramCatenary = 1
	params.seed = nil
	game.interface.upgradeConstruction(constructionId, construction.fileName, params)
	game.interface.setPlayer(constructionId, game.interface.getPlayer())
	util.clearCacheNode2SegMaps()
end 

function constructionUtil.replaceRoadDepotWithTramDepot(roadDepot)
	local roadDepotConstruction = util.getConstruction(roadDepot)
	local tramDepot = api.type.SimpleProposal.ConstructionEntity.new()
	tramDepot.fileName = "depot/tram_depot_era_a.con"
	tramDepot.playerEntity = api.engine.util.getPlayer()
	tramDepot.params={
		paramX = 0,  
		paramY = 0, 
		seed = 0, 
		tramCatenary = util.year()>=game.config.tramCatenaryYearFrom and 1 or 0,			
		year = util.year()}
	local name = util.getComponent(roadDepot, api.type.ComponentType.NAME).name
	tramDepot.name = string.gsub(name,_("Road"),_("Tram"))
	tramDepot.transf = roadDepotConstruction.transf
	
	local roadDepotEdge = util.getEdge(roadDepotConstruction.frozenEdges[1])
	local exitNode = util.isFrozenNode(roadDepotEdge.node0) and roadDepotEdge.node1 or roadDepotEdge.node0 
	local newProposal = api.type.SimpleProposal.new()
	local segs = util.getSegmentsForNode(exitNode)
	local connectNode 
	local frozenEdgeCount = 0
	if #segs > 1 then 
		for __, seg in pairs(segs) do 
			trace("Inspecting ",seg," connected to road depot",roadDepot)
			if not util.isFrozenEdge(seg) then 
				newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=seg 
				local edge = util.getEdge(seg) 
				connectNode = edge.node0 == exitNode and edge.node1 or edge.node0 
			else 
				frozenEdgeCount = frozenEdgeCount + 1
				if frozenEdgeCount > 1 then 
					trace("Found another frozenEdge, aborting!",seg)
					return 
				end
			end 
		end 
		newProposal.streetProposal.nodesToRemove[1]=exitNode
	end 
	newProposal.constructionsToRemove = { roadDepot } 
	newProposal.constructionsToAdd[1] = tramDepot
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace("Building tram depot replacement")
	api.cmd.sendCommand(build,function(res, success) 
		trace("Success was:",success)
		if success then 
			constructionUtil.addWork(function() 
				local entity = util.buildConnectingRoadToNearestNode(connectNode, -1, true, newProposal)
				if not entity then 
					trace("WARNING: could not find ",connectNode)
					return 
				end 
				local newProposal = api.type.SimpleProposal.new()
				newProposal.streetProposal.edgesToAdd[1]=entity 
				local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
				trace("Building tram depot replacement")
				api.cmd.sendCommand(build,function(res, success) 
					trace("Built linkRoad success was",success)
					constructionUtil.standardCallback(res,success)
				end)
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end 

function constructionUtil.buildTramDepotAlongRoute(station1, station2, params, callback, allowErrors, alreadyAttempted)
	local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2)
	if not routeInfo then 
		local function callbackThis(res, success) 
			if success then 
				constructionUtil.addWork(function() 	constructionUtil.buildTramDepotAlongRoute(station1, station2, params, callback, allowErrors, true) end)
			elseif callback then 
				callback(res, success)
			end
		end 
		if not alreadyAttempted then 
			constructionUtil.addWork(function() 
				local hasEntranceB = { false, false} 
				params.tramTrackType = util.getCurrentTramTrackType()
				local result = params
				routeBuilder.buildRoadRouteBetweenStations({station1, station2}, callbackThis, params,result, hasEntranceB, index)
					
			end) 
		end
		return
	end 
	local town = api.engine.system.stationSystem.getTown(station1)
	local existingDepot =  searchForDepotOfType(util.getEntity(town).position, "tram", 500) 
	if existingDepot then 
		local depotEntity = util.getComponent(existingDepot, api.type.ComponentType.CONSTRUCTION).depots[1]
		trace("Found a tram depot already")
		--return
	end
	
	local townName = util.getComponent(town, api.type.ComponentType.NAME) 
	local options = {} 
	local offset = 50

	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		--collectgarbage()
		local node = routeInfo.edges[i].edge.node1 
		local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(routeInfo.edges[i].id, node)
		local canAccept = #util.getTrackSegmentsForNode(node) == 0
		
		for i , seg in pairs(util.getSegmentsForNode(node)) do 
			if util.getEdgeLength(seg) < 40 then 
				canAccept = false 
			end 
		end 
		if canAccept then 
			for offset = 50, 70, 5 do 
				for j = -1, 1, 2 do 
					if j==-1 and #util.getSegmentsForNode(node) == 3 or #util.getSegmentsForNode(node) > 3 then goto continue end
					local tangent = j*vec3.normalize(nodeDetails.tangent)
					local position = nodeDetails.nodePos + offset*tangent
					local angle = util.signedAngle(tangent, vec3.new(0,1,0)) --+math.rad(90)
					--if j == -1 then angle = angle + math.rad(180) end
					trace("Checking if can build tram depot for ",townName.name)
					local tramDepot = constructionUtil.createTramDepotConstruction(townName, position, -angle)
					trace("Checking tram depot for collision")
					local checkResult = checkConstructionForCollision(tramDepot) 
					if not checkResult.isError or allowErrors and not checkResult.isCriticalError then 
						table.insert(options, { tramDepot = tramDepot, node=nodeDetails.node, scores = {checkResult.costs}})
					end
					--if #options > 3 then 
					--	break 
					--end
					::continue:: 
				end
			end
		end
	end
	if #options == 0 then 
		local newCallback = function(res, success) 
			trace("Attempt to build tram depot for town was",success)
			if success then 
				constructionUtil.addWork(function()
					params.tramTrackType = util.getCurrentTramTrackType()
					params.buildBusLanesWithTramLines = false
					params.tramOnlyUpgrade = true 
					local function routeFn() 
						local transportModes = {api.type.enum.TransportMode.BUS, api.type.enum.TransportMode.TRUCK}
						local depotEntity = util.getConstruction(res.resultEntities[1]).depots[1]
						local route1 = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, station1))
						local route2 = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, station2))
						trace("Attempting to find depot route, found?",route1,route2)
						if route1 and route2 then 
							return route1.actualRouteLength < route2.actualRouteLength and route1 or route2 
						end 						
						
						return route1 or route2
					end 
					routeBuilder.checkRoadForUpgradeOnly(routeFn, callback,  params ) 
				end)
			end 
		end 
		local isTram = true 
		constructionUtil.buildRoadDepotForTownComplete(town, isTram, newCallback)	
		return 
	end 
	if #options == 0 and not allowErrors then 
		constructionUtil.buildTramOrBusStopsAlongRoute(station1, station2, params, callback, true)
		return
	end 
	local option = util.evaluateWinnerFromScores(options) 
	local newProposal = api.type.SimpleProposal.new()
	trace("Gotten winner, setting up new proprosal")
	debugPrint(option.tramDepot)
	newProposal.constructionsToAdd[1]=option.tramDepot
	trace("About to build proposal")
	if allowErrors == nil then 
		allowErrors = false 
	end
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), allowErrors)
	trace("Building tram depot")
	api.cmd.sendCommand(build,function(res, success) 
		if success then 
			constructionUtil.addWork(function() 
				local entity = util.buildConnectingRoadToNearestNode(option.node, -1, true) 
				if not entity then 
					trace("WARNING! Unable to find entity for",option.node)
					return 
				end
				local newProposal = api.type.SimpleProposal.new()
				newProposal.streetProposal.edgesToAdd[1]=entity
				api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), callback)
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end
function constructionUtil.buildRoadDepotAlongRoute(station1, station2, params, callback)
	local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2)
	if not routeInfo then
		routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station2,station1 )
	end
	if not routeInfo then
		trace("buildRoadDepotAlongRoute: No route found between stations, trying fallback")
		local town = api.engine.system.stationSystem.getTown(station1)
		if town then
			-- Pass callback through to fallback - it's async
			constructionUtil.buildRoadDepotForTownComplete(town, false, callback)
		else
			trace("buildRoadDepotAlongRoute: No town found for station, failing")
			if callback then callback(nil, false) end
		end
		return
	end
	local town = api.engine.system.stationSystem.getTown(station1)
	local existingDepot =  searchForDepotOfType(util.getEntity(town).position, "road", 500) 
	if existingDepot then 
		local construction = util.getComponent(existingDepot, api.type.ComponentType.CONSTRUCTION)
		local depotEntity = construction.depots[1]
		if depotEntity and #pathFindingUtil.findRoadPathFromDepotToStationAndTerminal(existingDepot, station1, 0) > 0 then  
			trace("Found a road depot already")
			return
		end 
	end
	
	local townName = util.getComponent(town, api.type.ComponentType.NAME) 
	local options = {} 
	local offset = 70

	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		--collectgarbage()
		local node = routeInfo.edges[i].edge.node1 
		local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(routeInfo.edges[i].id, node)
		local canAccept = #util.getTrackSegmentsForNode(node) == 0
		
		for i , seg in pairs(util.getSegmentsForNode(node)) do 
			if util.getEdgeLength(seg) < 40 then 
				canAccept = false 
			end 
		end 
		if canAccept then 
			for j = -1, 1, 2 do 
				if j==-1 and #util.getSegmentsForNode(node) == 3 or #util.getSegmentsForNode(node) > 3 then goto continue end
				local tangent = j*vec3.normalize(nodeDetails.tangent)
				local position = nodeDetails.nodePos + offset*tangent
				local angle = util.signedAngle(tangent, vec3.new(0,1,0)) --+math.rad(90)
				trace("Checking if can build road depot for ",townName.name)
				local tramDepot = constructionUtil.createRoadDepotConstruction(townName, position, -angle)
				trace("Checking road depot for collision")
				local checkResult = checkConstructionForCollision(tramDepot) 
				if not checkResult.isError then 
					table.insert(options, { tramDepot = tramDepot, node=nodeDetails.node, scores = {checkResult.costs}})
				end
				--if #options > 3 then 
				--	break 
				--end
				::continue:: 
			end
		end
	end
	if #options == 0 then 
		trace("No options found attempting to build for town attempting build for town")
		constructionUtil.buildRoadDepotForTownComplete(town)	
		return
	end 
	local option = util.evaluateWinnerFromScores(options) 
	local newProposal = api.type.SimpleProposal.new()
	trace("Gotten winner, setting up new proprosal")
	--debugPrint(option.tramDepot)
	newProposal.constructionsToAdd[1]=option.tramDepot
	trace("About to build proposal")
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace("Building tram depot")
	api.cmd.sendCommand(build,function(res, success) 
		if success then 
			constructionUtil.addWork(function() 
				local entity = util.buildConnectingRoadToNearestNode(option.node, -1, true) 
				if not entity then 
					trace("WARNING! Unable to find entity for",option.node)
					return 
				end
				local newProposal = api.type.SimpleProposal.new()
				newProposal.streetProposal.edgesToAdd[1]=entity
				api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false), callback)
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end
function constructionUtil.upgradeRoadStation(newProposal, station, addTerminal, addEntranceB, executeImmediately, needsTram)
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
		if constructionId == -1 then 
			return
		end
		local stationFull = util.getStation(station)
		-- addEntranceB = false -- TODO figure out what causes crashing (TESTING: enabled)
		trace("Anout to get construction for station ", station, " constructionId = ",constructionId)
		local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
		local params = util.deepClone(construction.params)
		 --params.suppressLargeEntry = false -- may cause a crash when upgrading
		if params.includeLargeBuilding then 
			trace("Aborting upgradeRoadStation as large building is found") -- TODO fix crash when upgrading with buildings
			return
		end 
		if not params.templateIndex then 
			params.templateIndex = stationFull.cargo and 3 or 2
		end
		local needsUpgrade = addTerminal 
		if needsTram then 
			if params.tramTrack < util.getCurrentTramTrackType() then 
				needsUpgrade = true 
			end
			params.tramTrack = util.getCurrentTramTrackType()
	 	end
		
		
		if addEntranceB then 
			if params.entrance_exit_b ~= 1 then 
				needsUpgrade = true 
			end
			params.entrance_exit_b = 1
		end
		helper.determineActualRoadStationParams(params)
		trace("Entrance exit b",params.entrance_exit_b," addEntranceB?",addEntranceB)
		if addTerminal then
			local currentTerminals = #stationFull.terminals
			local terminalsToAdd = 1
			if type(addTerminal) == "number" then 
				terminalsToAdd = addTerminal
			else 
				local currentTerminals = #stationFull.terminals
				local terminalDeficit =   #api.engine.system.lineSystem.getLineStopsForStation(station)-currentTerminals
				trace("Determined terminal deficit as", terminalDeficit," at ",station)
				if terminalDeficit > 0 then 
					terminalsToAdd = terminalsToAdd + terminalDeficit
				end 
			end 	
			if (params.platL + params.platR) ~= currentTerminals then 
				trace("WARNING! Current terminal inconsistent at ",station, "platL=",params.platL,"platR=",params.platR,"currentTerminals=",currentTerminals)
				helper.correctRoadStationParams(params)
			end 
			
			if not util.getStation(station).cargo then -- passenger
				local fileName = ""
				for __, otherStation in pairs(util.searchForEntities(util.getStationPosition(station), 150, "STATION")) do 
					if not otherStation.cargo and otherStation.id~=station and  util.getConstructionForStation(otherStation.id) then 
						fileName = util.getConstructionForStation(otherStation.id).fileName 
						break
					end 
				end  
				if  fileName == "station/water/harbor_modular.con" then 
					params.platL = params.platL + terminalsToAdd -- away from the harbor
				else 
					if string.find(fileName, "elevated") or string.find(fileName, "underground") then 
						if params.platR < params.platL then  
							params.platR = params.platR + terminalsToAdd
						else 
							params.platL = params.platL + terminalsToAdd
						end
					else  
						if params.platR > params.platL then --always build on the side with more terminals already, as this is not touching the other station
							params.platR = params.platR + terminalsToAdd
						else 
							params.platL = params.platL + terminalsToAdd
						end
					end
				end
				if params.platL > 3 then 
					if not params.includeEntryExit then params.includeEntryExit = {} end 
					-- commented for now as sometimes causes crash
					--params.includeEntryExit[-2] = true
					end
				if params.platR > 3 then 
					if not params.includeEntryExit then params.includeEntryExit = {} end 
					--params.includeEntryExit[2] = true
					if params.platR > 5 then 
					--	params.includeEntryExit[4] = true
					end
				end				
			else 
				if params.platR > params.platL then 
					if checkIfCanAddPlatform(constructionId,true, params.templateIndex) or not checkIfCanAddPlatform(constructionId,false, params.templateIndex) then
						params.platL = params.platL + terminalsToAdd
					else 
						params.platR = params.platR + terminalsToAdd
					end
				else 
					if checkIfCanAddPlatform(constructionId,false, params.templateIndex) or not checkIfCanAddPlatform(constructionId,true, params.templateIndex)  then
						params.platR = params.platR + terminalsToAdd
					else 
						params.platL = params.platL + terminalsToAdd
					end
				end
			end
		end  
		params.platL = math.min(params.platL, 10)
		params.platR = math.min(params.platR, 10)
		local modules = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))   
		--[[for k, v in pairs(modules) do 
			if not params.modules[k] then 
				params.modules[k]=v 
			end 
		end ]]--
		params.modules = modules
		local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
		newConstruction.name=util.getComponent(station, api.type.ComponentType.NAME).name
		
		newConstruction.fileName = construction.fileName
		newConstruction.playerEntity = api.engine.util.getPlayer() 
		 
		newConstruction.params = params  
		newConstruction.transf = construction.transf
		if executeImmediately then
			if not needsUpgrade then 
				trace("Skipping as no upgrades were needed", station)
				return 
			end
			trace("About to execute upgradeConstruction for constructionId ",constructionId)
			
			
			trace("params.platL=",params.platL,"params.platR=",params.platR)
			
			local newProposal = api.type.SimpleProposal.new() 
			params.suppressAllEntrances = true 
			params.modules = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params)) 
			newConstruction.params = params 
			newProposal.constructionsToRemove = {constructionId}  
			newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd] = newConstruction
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
				function(res, success)
					trace("Command to rebuild bus station   was ",success)
					xpcall(
						function() 
							if not success then 
								debugPrint(res)
							end 
							params.suppressAllEntrances = false
							params.modules = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params)) 
							if success then 
								constructionId = res.resultEntities[1] 
							end 
							params.seed = nil
							if not pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end) and params.includeEntryExit then 
								params.includeEntryExit = nil
								pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end)
							end 
							trace("About set player")
							game.interface.setPlayer(constructionId, game.interface.getPlayer())
							util.clearCacheNode2SegMaps()
						end, 
					constructionUtil.err)
				end )
			 
			util.clearCacheNode2SegMaps()
			
			--if util.tracelog then debugPrint({oldParams = util.deepClone(construction.params), newParams = params}) end
			--[[
			if not pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end) and params.includeEntryExit then 
				params.includeEntryExit = nil
				pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end)
			end 
			trace("About set player")
			game.interface.setPlayer(constructionId, game.interface.getPlayer())
			--constructionUtil.addWork(function() constructionUtil.removeConstructionTrafficLights(constructionId) end)
			util.clearCacheNode2SegMaps()]]--
			return 
		end
		
	
	
		
		
		local constructionsToRemove = util.deepClone(newProposal.constructionsToRemove)
		table.insert(constructionsToRemove, constructionId)
		newProposal.constructionsToRemove = constructionsToRemove -- note reassignment of table necessary
		newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd] = newConstruction
		local freeNode
		for i, edgeId in pairs(construction.frozenEdges) do 
			local edge = util.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
			  freeNode = util.isFrozenNode(edge.node0) and edge.node1 or edge.node0 
			local otherSegs = util.getStreetSegmentsForNode(freeNode)
			if #otherSegs > 1 then 
				local otherEdge = otherSegs[1] == edgeId and otherSegs[2] or otherSegs[1]
				newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=otherEdge
			end
		end

end

function constructionUtil.checkBusStationForUpgrade(station, needsTram) 
	local addTerminal = util.countFreeTerminalsForStation(station) == 0 
	if addTerminal or needsTram then 
		if api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) == -1 then 
			local edgeId = util.getEdgeForBusStop(station)
			local edge = util.getEdge(edgeId) 
			if #edge.objects < 2 then 
				constructionUtil.buildBusStopEdge(edgeId)
			end 
		else 
			constructionUtil.upgradeRoadStation(nil, station, addTerminal, false, true, needsTram)
		end
	end
end

function constructionUtil.checkBusStationForUpgradeTramOnly(station) 
	constructionUtil.upgradeRoadStation(nil, station, false, false, true, true)
end


function constructionUtil.checkRoadStationForUpgrade(newProposal, station, industry, result, params)
	local needsExitB = false
	trace("checkRoadStationForUpgrade: begin for",station)
	local freeTerminalCount = util.countFreeTerminalsForStation(station)
	local needsTerminal = freeTerminalCount == 0
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	if constructionId == -1 then 
		return false 		
	end
	local otherIndustry = industry == result.industry1 and result.industry2 or result.industry1
	trace("Anout to get construction for station ", station, " constructionId = ",constructionId)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if result.needsNewRoute and construction.params.entrance_exit_b ~= 1 and industry.type~="TOWN" then 
		local vectorToIndustry = util.v3fromArr(otherIndustry.position) - util.getStationPosition(station)
		
		local frozenEdges =construction.frozenEdges
		if #frozenEdges == 1 then
			local frozenEdgeTangent = util.getComponent(frozenEdges[1], api.type.ComponentType.BASE_EDGE).tangent1 
			local angle = util.signedAngle(util.v3(frozenEdgeTangent), vectorToIndustry)
			trace("Inspecting station the angle was ",math.deg(angle))
			if math.abs(angle) > math.rad(90) then 
				trace("Determined needs exit b")
				needsExitB = true
			end
		end
		
	end
	if not needsExitB and construction.params.entrance_exit_b ~= 1  and industry.type~="TOWN" then 
		for i, otherStation in pairs(util.searchForEntities(util.getStationPosition(station), 150, "STATION")) do 
			if otherStation.id ~= station then 
				if otherStation.carriers.RAIL then 
					needsExitB = true 
					break 
				end
			end 
		end
	end
	
	local upgraded = false 
	if industry.type=="TOWN" then 
		needsExitB = false 
	end
	if params and params.isAutoBuildMode then 
		needsExitB = false
	end 
	if needsExitB or needsTerminal then 
		if needsTerminal and params and params.useDoubleTerminals then 
			needsTerminal = 2
		end 
		trace("Upgrading road station",station," for ",industry.name,"needsExitB=",needsExitB,"needsTerminal=",needsTerminal, "freeTerminalCount=",freeTerminalCount)
		constructionUtil.upgradeRoadStation(newProposal, station, needsTerminal, needsExitB, true)
		upgraded = {
			connectNode = freeNode,
			hasEntranceB = needsExitB
		}
	end
	
	local otherIndustryPos = util.v3fromArr(otherIndustry.position)
	local foundSuitableNode = false
	local deadEndNodes = util.searchForDeadEndNodes(util.getStationPosition(station), 200)
	for i, node in pairs(deadEndNodes) do
		
		local vectorToOtherIndustry = otherIndustryPos - util.getStationPosition(station)
		local nodeDetails = util.getDeadEndTangentAndDetailsForEdge(util.getStreetSegmentsForNode(node)[1])
		local angleToVector = util.signedAngle(vectorToOtherIndustry, nodeDetails.tangent) 
		trace("Looking for suitable dead end nodes, for node ",node," the angle to vector was",math.deg(angleToVector))
		if math.abs(angleToVector) < math.rad(60) then 
			foundSuitableNode = true
			break
		end
		
	end
	if result.needsNewRoute and not foundSuitableNode and industry.type~="TOWN" and false then -- temp disabled, doesn't do much useful 
		local rotations = { 0, math.rad(90), -math.rad(90) }
		for i = 1, 3 do 
			trace("Determined no dead end nodes near ",industry.name)
			local node = util.getFreeNodesForConstruction(constructionId)[1]
			local segs = util.getStreetSegmentsForNode(node)
			local nextEdgeId = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
			local nextEdge = util.getEdge(nextEdgeId)
			local nextNode = nextEdge.node0 == node and nextEdge.node1 or nextEdge.node0 
			local tangent = nextEdge.node0 == node and util.v3(nextEdge.tangent1) or -1*util.v3(nextEdge.tangent0)
			tangent = util.rotateXY(tangent, rotations[i])
			local nodePos = util.nodePos(nextNode)
			local newNodePos = nodePos + 160 * vec3.normalize(tangent)
			if util.distance(newNodePos, otherIndustryPos) > util.distance(nodePos, otherIndustryPos) or util.isFrozenNode(nextNode) then 
				goto continue
			end
			local newNode = util.newNodeWithPosition(newNodePos, -1000-#newProposal.streetProposal.nodesToAdd)
			local newEntity = util.copyExistingEdge(nextEdgeId, -1-#newProposal.streetProposal.edgesToAdd)
			newEntity.comp.node0 = nextNode
			newEntity.comp.node1 = newNode.entity
			util.setTangent(newEntity.comp.tangent0, newNodePos-nodePos)
			util.setTangent(newEntity.comp.tangent1, newNodePos-nodePos)
			local testProposal = api.type.SimpleProposal.new()
			testProposal.streetProposal.edgesToAdd[1]=newEntity
			testProposal.streetProposal.nodesToAdd[1]=newNode
			local result = checkProposalForErrors(testProposal)
			if result.isError then 
				trace("Could not build a stub road near industry")
			else 
				trace("Building stub road near industry")
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=newEntity
				newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
				if util.tracelog then debugPrint(newProposal) end
				break
			end
			::continue::
		end
	end
	
	return upgraded
end
 
function constructionUtil.buildRoadStationSplitEdge(edgeId ,params, naming)
	local edge = util.getEdge(edgeId)
	local baseTangent = vec3.new(0,1,0)
	local tangent = util.rotateXY(vec3.normalize(util.v3(edge.tangent0)+util.v3(edge.tangent1)), math.rad(90))
	local angle = util.signedAngle(tangent, baseTangent)
 
	trace("Attempting to place station at mid point")
	local midPoint = 0.5*(util.nodePos(edge.node0) + util.nodePos(edge.node1))
	local offset = 44+0.5*util.getEdgeWidth(edgeId)
	local length = 1
	local stationPos = midPoint +   offset * tangent
	trace("proposed stationPos is at",stationPos.x, stationPos.y, stationPos.z, " angle=",math.deg(angle), "tangent was",tangent.x,tangent.y, "edgeId=",edgeId,"midpoint=",midPoint.x,midPoint.y)
	local newProposal = api.type.SimpleProposal.new()
	newProposal.streetProposal.edgesToRemove[1] = edgeId 
	constructionUtil.buildRoadStation(newProposal, stationPos, -angle, params, naming, hasEntranceB, 1, 2,"",length)
	local isError = checkProposalForErrors(newProposal, true).isError
	trace("Is error?",isError)
	if isError then 
		newProposal = api.type.SimpleProposal.new()
		newProposal.streetProposal.edgesToRemove[1] = edgeId 
		stationPos = midPoint - offset*tangent 
		angle = angle+math.rad(180)
		constructionUtil.buildRoadStation(newProposal, stationPos, -angle, params, naming, hasEntranceB, 1, 2,"",length)
		isError = checkProposalForErrors(newProposal, true).isError
		trace("Is error after rotation?",isError)
	end
	
	local newNode = util.newNodeWithPosition(midPoint, -1000)
	newProposal.streetProposal.nodesToAdd[1]=newNode
	local newEdge1 = util.copyExistingEdge(edgeId, -1)
	local newEdge2 = util.copyExistingEdge(edgeId, -2)
	newEdge1.comp.node1 = newNode.entity
	newEdge2.comp.node0 = newNode.entity
	util.rescaleTangents(newEdge1, 0.5)
	util.rescaleTangents(newEdge2, 0.5)
	newProposal.streetProposal.edgesToAdd[1] = newEdge1 
	newProposal.streetProposal.edgesToAdd[2] = newEdge2 
	return newProposal, isError,midPoint
end  

function constructionUtil.buildCargoRoadStationNearestEdge(townId, p, existingStation, callback, ignoreErrors)
	constructionUtil.buildRoadStationNearestEdge(townId, p, existingStation, callback, ignoreErrors, true)
end 
function constructionUtil.buildBusStationNearestEdge(townId, p, existingStation, callback, ignoreErrors)
	constructionUtil.buildRoadStationNearestEdge(townId, p, existingStation, callback, ignoreErrors, false)
end 

function constructionUtil.buildRoadStationNearestEdge(townId, p, existingStation, callback, ignoreErrors, isCargo)
	local naming = util.getComponent(townId, api.type.ComponentType.NAME)
	local options = {}
	local function edgeIsOk(edgeId) 
		local edge = util.getEdge(edgeId)
		return #edge.objects == 0 and math.abs(util.signedAngle(edge.tangent0, edge.tangent1)) < math.rad(30) and edge.type == 0 and util.getEdgeLength(edgeId)> 60
	end 
	if existingStation then 
		for i, edgeIdFull in pairs( api.engine.system.catchmentAreaSystem.getStation2edgesMap()[existingStation]) do
			if util.getEdge(edgeIdFull.entity) and edgeIsOk(edgeIdFull.entity)  then 
				table.insert(options, {
					edgeId = edgeIdFull.entity, 
					scores = { util.distance(p, util.getEdgeMidPoint(edgeIdFull.entity))}
				})
			end 
		end 
	else 
		for edgeId, edge in pairs(util.searchForEntities(p, 250, "BASE_EDGE")) do 
			if not edge.track and edgeIsOk(edgeId)  then 
				table.insert(options, {
					edgeId = edgeId, 
					scores = { util.distance(p, util.getEdgeMidPoint(edgeId))}
				})
			end
		end 
	end 
	local params = {isCargo=isCargo}
	for i, option in pairs(util.evaluateAndSortFromScores(options)) do 
		local newProposal, isError , midPoint = constructionUtil.buildRoadStationSplitEdge(option.edgeId,params, naming)
		trace("Looking at the ",i,"th option, isError?",isError)
		if not isError or ignoreErrors then 
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
				function(res, success)
					trace("Command to build bus station   was ",success)
					if   success then 
						constructionUtil.addWork(function() 
							local connectNode = util.searchForNearestNode(midPoint)
							local entity = util.buildConnectingRoadToNearestNode(connectNode, -1-#newProposal.streetProposal.edgesToAdd, true, newProposal)
							if not entity then 
								trace("WARNING! Unable to find connect node for",connectNode)
								return 
							end 
							local newProposal = api.type.SimpleProposal.new()
							newProposal.streetProposal.edgesToAdd[1]=entity
							api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),function(res2, success)
								callback(res, success)
							end) 
						end)
						if not constructionUtil.searchForNearestRoadStation(p, 750) then 
							constructionUtil.addWork(function() constructionUtil.buildRoadDepotForTownComplete(townId) end)
						end 
					else
						callback(res, success)
						if util.tracelog then 
							debugPrint(res)
						end					
					end
				end)
			return
		end 
	end 
	if not ignoreErrors then 
		ignoreErrors = true 
		constructionUtil.buildRoadStationNearestEdge(townId, p, existingStation, callback, ignoreErrors, isCargo)
	end 
end
function constructionUtil.buildRoadDepotForTownComplete(townId, isTram, callback)	
	local town = util.getEntity(townId)
	for i, node in pairs(util.searchForDeadEndNodes(town.position, 750)) do 
		local nodeDetails = util.getDeadEndNodeDetails(node)
		local tangent = vec3.normalize(nodeDetails.tangent)
		local baseTangent = vec3.new(0,1,0)
 
		
		local perpTangent = util.rotateXY(tangent, math.rad(90))
		local angle = util.signedAngle(perpTangent, baseTangent)
		local depotPos = util.nodePos(node) + 60*perpTangent
		local roadDepotConstruction = constructionUtil.createRoadDepotConstruction(town, depotPos, -angle)
		if isTram then 
			roadDepotConstruction = constructionUtil.createTramDepotConstruction(town, depotPos,-angle)
		end 
		local isError = checkConstructionForCollision(roadDepotConstruction).isError
		trace("Checking road depot for ",node,"isError=",isError)
		if not isError then 
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToAdd[1] = roadDepotConstruction
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
				function(res, success)
					trace("Command to build road depot was ",success)
					if   success then 
						constructionUtil.addWork(function() 
							local entity = util.buildConnectingRoadToNearestNode(node, -1, true, newProposal)
							if not entity then 
								trace("WARNING!, unable to find a connection for",node)
								return 
							end 
							local newProposal = api.type.SimpleProposal.new() 
							newProposal.streetProposal.edgesToAdd[1]=entity
							api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), function(res2, success)
								if callback then 
									callback(res, success)
								end 
								util.clearCacheNode2SegMaps()
							end)							
						end)
					end
				end)
			break 
		end 
	end 
	

end


function constructionUtil.replaceConstruction(constructionId, mapParamsFn, callback)
	local newConstruction = constructionUtil.copyConstruction(constructionId)
	newConstruction.params = mapParamsFn(newConstruction.params)
	local newProposal = api.type.SimpleProposal.new()
	newProposal.constructionsToAdd[1] = newConstruction
	newProposal.constructionsToRemove = { constructionId } 
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), callback) 
end 

function constructionUtil.buildTruckStationForIndustry(newProposal,details, result,params, tryOtherNode, stationPos)
	local offset = 80
	local length = 2
	local townSource=  details.index == 1 and result.industry1.type=="TOWN"
	local town
	
	if townSource then
		local streetWidth = util.getEdgeWidth(details.edge.id)
		trace("reducing offset for town source, streetWidth was ",streetWidth)
		--offset = 52 
		offset = 44+0.5*streetWidth
		length = 1
		town = result.industry1
	end
	local industry = details.index == 1 and result.industry1 or result.industry2 
	trace("buildTruckStationForIndustry: Attempting to place for",industry.name,"the edge given was",details.edge and details.edge.id)
	local isEffectivelySingleConnection = util.isPrimaryIndustry(industry) or util.isSingleSourceAndOutputIndustry(industry)
	local isCongestedIndustry = util.isCongestedIndustry(industry)
	if not details.edge then 
	
		trace("WARNING! No edge specified, attempting to correct")
		
		if industry.type ~= "TOWN" then 
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industry.id)
			--[[local construction = util.getConstruction(constructionId)
			local constrParams = util.deepClone(construction.params)
			constrParams.seed = nil
			constrParams.upgrade = nil 
			trace("Adding edge: About to execute upgradeConstruction for constructionId ",constructionId," for ",industry.name)
			local success = pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, constrParams)end)
			trace("Result of upgradeConstruction was",success)]]--
			
			local function mapParamsFn(constrParams) 
				constrParams = util.deepClone(constrParams)
				constrParams.upgrade = nil 
				return constrParams
			end 
			local function callback(res, success) 
				trace("Result of replace construction to add the thingy was",success)
				if success then 
					constructionUtil.executeImmediateWork(function() 
						util.clearCacheNode2SegMaps()
						util.lazyCacheNode2SegMaps()
						details.edge = util.searchForFirstEntity(util.v3fromArr(industry.position), 300, "BASE_EDGE", function(edge) return util.isIndustryEdge(edge.id) end)
					end )
				end 
			
			end 
			
			constructionUtil.replaceConstruction(constructionId, mapParamsFn, callback)
			trace("Exit call to replace construction") -- luckily enough, it appears that if in the engine thread the callback executes immediately
		--	return
		
		end			
	end 
	local baseTangent = vec3.new(0,1,0)
	local nodedetails = util.getDeadEndTangentAndDetailsForEdge(details.edge.id)
	local nearbyTrainStation = util.searchForNearestTrainStation(nodedetails.nodePos, 100)
	if nearbyTrainStation then
		local trainStationPos = util.getStationPosition(nearbyTrainStation)
		local otherStationTangent = util.v3(util.getConstructionForStation(nearbyTrainStation).transf:cols(1))
		local angle = math.abs(util.signedAngle(nodedetails.tangent, otherStationTangent))
		trace("buildTruckStationForIndustry: Found nearby trainStation", nearbyTrainStation, " at an angle ",math.deg(angle)," result.needsNewRoute?",result.needsNewRoute)
		if angle > math.rad(45) and result.needsNewRoute then 
			local bestNode = util.distance(trainStationPos, util.nodePos(details.edge.node0)) < util.distance(trainStationPos, util.nodePos(details.edge.node1)) and details.edge.node1 or details.edge.node0 
			trace("buildTruckStationForIndustry: Found nearby trainStation", nearbyTrainStation, " selecting node",bestNode)
			nodedetails = util.getDeadEndTangentAndDetailsForEdge(details.edge.id, bestNode)
			local ourPosition = nodedetails.nodePos 
			local otherIndustry = details.otherPosition 
			local assumedLength = 150 -- a but longer than the station 
			local stationP1 = trainStationPos + assumedLength*otherStationTangent
			local stationP2 = trainStationPos - assumedLength*otherStationTangent
			local c = util.checkFor2dCollisionBetweenPoints(stationP1,stationP2 , ourPosition, otherIndustry) 
			trace("After inspecting for 2d collision between our route and the station, result was",c)
			if c then 
				trace("Attempting offside development")
				local proposalCopy = api.type.SimpleProposal.new()
				copyProposal(newProposal,proposalCopy )
				constructionUtil.developStationOffside({
					newProposal = proposalCopy,
					stationId = nearbyTrainStation,
					setupProposalOnly = true,
				})
				if checkProposalForErrors(proposalCopy).isError then 
					trace("Aborting offside development")
				else 
					constructionUtil.developStationOffside({
						newProposal = newProposal,
						stationId = nearbyTrainStation,
						setupProposalOnly = true,
					})
				end 
			end
		end
	end 
	local usingFarEndDeadEndNode = false
	local targetPosition = stationPos
	if not targetPosition then 
		targetPosition = details.otherPosition 
	end 
	
	if targetPosition then 
		
		local node0Pos = util.v3fromArr(details.edge.node0pos)
		local node1Pos = util.v3fromArr(details.edge.node1pos)
		local isNode0Closer = util.distance(targetPosition, node0Pos) < util.distance(targetPosition, node1Pos)
		trace("Checking isNode0Closer for short proximity, isNode0Closer?",isNode0Closer)
		if vec2.distance(targetPosition, node0Pos) < 150 or vec2.distance(targetPosition, node1Pos) < 150 then 
			trace("Inverting isNode0Closer for short proximity")
			isNode0Closer = not isNode0Closer
		end 
		local nodeToUse = isNode0Closer and details.edge.node0 or details.edge.node1 
		local otherNode = isNode0Closer and details.edge.node1 or details.edge.node0
		if #util.getSegmentsForNode(otherNode) == 1 and not tryOtherNode and isEffectivelySingleConnection then 
			trace("Other node was dead end, using instead")
			nodeToUse = otherNode
			usingFarEndDeadEndNode = true
		end 
		trace("getting dead end tangent details, using node",nodeToUse," segments count=", #util.getSegmentsForNode(nodeToUse))
		if #util.getSegmentsForNode(nodeToUse) == 1 then 
		 
			trace("actually getting dead end tangent details, using node",nodeToUse)
			nodedetails = util.getDeadEndNodeDetails(nodeToUse)
		end
	end 
	if tryOtherNode then 
		trace("Trying other node, using",tryOtherNode)
		nodedetails = util.getDeadEndNodeDetails(tryOtherNode)
		if not result.usedNodes then 
			result.usedNodes = {} 
		end 
		result.usedNodes[tryOtherNode]=true
	end
	local originalNodeDetails = nodedetails
	local edge = details.edge
	local tangent =  vec3.normalize(nodedetails.tangent) 
	local perpTangent =  util.rotateXY(tangent, math.rad(90))
	
	if nodedetails.isDeadEnd and not usingFarEndDeadEndNode  then 
		tangent = perpTangent
		perpTangent =  util.rotateXY(tangent, -math.rad(90))
		trace("Using the other tangen")
	end
	local function nextEntityId() 
		return  -1-#newProposal.streetProposal.edgesToAdd
	end
	
	local stationPos = nodedetails.nodePos + offset * tangent
	local thisIndustry = details.position
	if util.distance(stationPos, thisIndustry) < util.distance(nodedetails.nodePos, thisIndustry) then -- moved into the industry, need to go the other way
		trace("inverting the depot position")
		tangent = -1*tangent
		stationPos = nodedetails.nodePos + offset * tangent
		
	end 
	local baseAngle = util.signedAngle(tangent, baseTangent)
	local angle = baseAngle
	local angleToVector = util.signedAngle(tangent, details.routeVector)
	local angleOfDeadEnd = util.signedAngle(nodedetails.tangent, details.routeVector)
	trace("angle to vector of ",details.name," to route vector was ",math.deg(angleToVector), " connect node was ",nodedetails.node," result.needsNewRoute=",result.needsNewRoute, " angleOfDeadEnd=",math.deg(angleOfDeadEnd))
	local hasStubRoad = false
	local hasEntranceB = false
	if not townSource and  not params.isAutoBuildMode  then 
		for __, station in pairs(util.searchForEntities(stationPos, 200, "STATION")) do 
			if station.carriers.RAIL then 
				trace("Discovered nearby rail station") 
				hasEntranceB = true -- gives more connect options in potentially congested area 
				break
			end
		end
	end
	
	if math.abs(angleToVector) < math.rad(60) and result.needsNewRoute and not params.isAutoBuildMode  then
		if not townSource then 
			hasEntranceB=true
		end
	elseif nodedetails.isDeadEnd and result.needsNewRoute and math.abs(angleOfDeadEnd)> math.rad(120) and false then -- disabled, no longer useful
		local nextEdge = details.edge.id
		local nextNode =  nodedetails.otherNode
		local options ={} 
		for i = 1, 5 do 
			local nextEdgeId = util.findNextEdgeInSameDirection(nextEdge, nextNode)
			if not nextEdgeId then break end
			local nextEdge = util.getEdge(nextEdgeId)
			if nextEdge.type ~= 0 then 
				trace("Encountered a non standard edge", nextEdge.type, " exiting")
				break
			end
			nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0 
			if i > 2 then 
				if #util.getSegmentsForNode(nextNode) <= 2 then
					local tangent = util.v3(nextNode == nextEdge.node0 and nextEdge.tangent0 or nextEdge.tangent1)
					local angle = util.signedAngle(details.routeVector, tangent)
					local thisOptions = {}
					for j, rotation in pairs({math.rad(90), -math.rad(90)}) do 
						local perpTangent = util.rotateXY(vec3.normalize(tangent), rotation)
						local stubAngleToVector = util.signedAngle(perpTangent, details.routeVector)
						local stubAngleForScoring = math.abs(stubAngleToVector)--math.abs(math.rad(180)-math.abs(stubAngleToVector))
						local position = util.nodePos(nextNode) + 40* perpTangent
						local distance = util.distance(position, details.otherPosition)
						trace("The proposed angle was ",  math.deg(stubAngleToVector), " the angle for scoring was ", math.deg(stubAngleForScoring), " distance=",distance)
						local testOtherPos 
						local testProposal = api.type.SimpleProposal.new()
						util.buildShortStubRoadWithPosition(testProposal, nextNode, position,util.defaultStreetType(), nextEntityId())
						if not checkProposalForErrors(testProposal).isError then 
							table.insert(thisOptions, { 
								proposal = testProposal,
								distance = distance,
								scores = {
									stubAngleForScoring,
									distance
								}
							
							})
						end
					end
					if #thisOptions == 2 then 
						if thisOptions[1].distance < thisOptions[2].distance then 
							table.insert(options, thisOptions[1])
						else 
							table.insert(options, thisOptions[2])
						end
					elseif #thisOptions == 1 then 
						table.insert(options, thisOptions[1])
					end
				end
			end 
			if #util.getSegmentsForNode(nextNode) == 1 then 
				trace("Hit a dead end trying to find another node, exiting")
				break
			end
		end
		if #options > 0 then 
			
			local proposal = util.evaluateWinnerFromScores(options).proposal
			local entity = proposal.streetProposal.edgesToAdd[1]
			local newNode = proposal.streetProposal.nodesToAdd[1]
			 util.validateProposal(newProposal)
			trace("Building short stub road ",entity.entity,"connecting",entity.comp.node0, entity.comp.node1," newNode was",newNode.entity) 	
			newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity
			newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode 
			 
			hasStubRoad = true
		end
	end
	local count = 0
	local connectNode = nodedetails.node
	local isError = false
	local positionOptions = {}
	for i = -60, 60, 10 do 
		for j = -60, 60, 10 do
			local k = j < 0 and 0 or 180
			--for k = -90, 90, 90 do 
				table.insert(positionOptions, {
					offset = i, 
					perpOffset = j,
					angle = math.rad(k),
				})
			--end 
		end 
	end 
	trace("Built ",#positionOptions)
	local offsetUsed
	repeat
		trace("Checking road station for collision at ",stationPos.x,stationPos.y)
		local dummyProposal = api.type.SimpleProposal.new()
		copyStreetProposal(newProposal, dummyProposal)
		constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
		--debugPrint(dummyProposal)
		for i = 0, 3 do 
			--debugPrint(dummyProposal.constructionsToAdd[1].transf:cols(i))
		end 
		isError = checkProposalForErrors(dummyProposal).isError
		trace("Result of checking proposal for errors was ",isError)
		if not isError then 
			isError = trialBuildConnectRoad(connectNode, stationPos, dummyProposal)
			trace("Was not error but result of trying to build connect road from ",connectNode," to ", stationPos.x, stationPos.y, " was ",isError)
			if isError then 
				local searchPoint = 0.5*(util.nodePos(connectNode)+stationPos)
				local alternateNode = util.searchForNearestNode(searchPoint, 90, function(node)
					if util.isFrozenNode(node.id) then 
						return false 
					end 
					if #util.getTrackSegmentsForNode(node.id) > 0  then 
						return false 
					end 
					if connectNode == node.id then 
						return false
					end 
					local hadPath = #pathFindingUtil.findRoadPathBetweenNodes(connectNode, node.id) > 0 or util.findEdgeConnectingNodes(connectNode, node.id)
					trace("Inspecting nodes for alternateNode",connectNode, node.id,"hadPath?",hadPath)
					return hadPath
				end)
				trace("Searching for an alternateNode around",searchPoint.x, searchPoint.y," found?",alternateNode~=nil)
				if alternateNode then 
					isError = trialBuildConnectRoad(alternateNode.id, stationPos, dummyProposal)
					if not isError then 
						trace("Error was solved by using alternateNode instead",alternateNode.id," setting as connectNode")
						connectNode = alternateNode.id 
						break
					end 
				end 
			end
		end 
		if (isError or isCongestedIndustry)and count == 0 then 
			local edgeToChecks = townSource and connectEval.findCentralCargoEdges(town)  or {util.getEdgeIdFromEdge(edge)}
			for i, edgeId in pairs(edgeToChecks) do 
				for j = -1, 1, 2 do 
					local nodedetails=  util.getDeadEndTangentAndDetailsForEdge(edgeId)
					local tangent =  vec3.normalize(nodedetails.tangent) 
					local perpTangent =  util.rotateXY(tangent, j*math.rad(90))
					
					if nodedetails.isDeadEnd then 
						tangent = perpTangent
						perpTangent =  util.rotateXY(tangent, -j*math.rad(90))
					end
					local edge = util.getEdge(edgeId)
					dummyProposal = api.type.SimpleProposal.new()
					copyStreetProposal(newProposal, dummyProposal)
					angle = util.signedAngle(tangent, baseTangent)
					trace("Attempting to place station at mid point")
					local midPoint = 0.5*(util.nodePos(edge.node0) + util.nodePos(edge.node1))
					if townSource then 
						offset = 44+0.5*util.getEdgeWidth(edgeId)
					end
					stationPos = midPoint +   offset * tangent
					constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
					isError = checkProposalForErrors(dummyProposal).isError
					trace("Result of attempt to place station at mid point",midPoint.x, midPoint.y,"at",stationPos.x,stationPos.y,"was isError?",isError)
					if isError then 
						dummyProposal = api.type.SimpleProposal.new()
						copyStreetProposal(newProposal, dummyProposal)
						stationPos = midPoint - offset*tangent 
						angle = angle+math.rad(180)
						constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
						isError = checkProposalForErrors(dummyProposal).isError
						trace("Result of attempt to place station at mid point with 180 degree rotation from mid point",midPoint.x, midPoint.y,"at",stationPos.x,stationPos.y,"was isError?",isError)
					end
					if not isError then 
						 util.validateProposal(newProposal)
						trace("Error resolved at the midpoint, splitting road")
						local newNode = util.newNodeWithPosition(midPoint, -edge.node0)
						newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
						local entity1 = util.copyExistingEdge(edgeId, -1-#newProposal.streetProposal.edgesToAdd)
						entity1.comp.node1=newNode.entity
						local t =  midPoint-util.nodePos(edge.node0)
						util.setTangent(entity1.comp.tangent0,t)
						util.setTangent(entity1.comp.tangent1,t)
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity1
						local entity2 = util.copyExistingEdge(edgeId,-1-#newProposal.streetProposal.edgesToAdd)
						entity2.comp.node0=newNode.entity
						util.setTangent(entity2.comp.tangent0,t)
						util.setTangent(entity2.comp.tangent1,t)
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity2
						newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
						trace("Added entities",entity1.entity, entity2.entity,"connecting",entity1.comp.node0, entity1.comp.node1,"with",entity2.comp.node0,entity2.comp.node1)
						connectNode=midPoint
						 util.validateProposal(newProposal)
						break
					end 
				end 
				if not isError then 
					break 
				end
			end
			if not isError then 
				break 
			end
		end
		
		if isError then 
			
			 
			local newOffset = offset
			local perpOffset = (count % 4)*20
			if count <= 8 then 
				angle = nodedetails.isDeadEnd and baseAngle+math.rad(90) or baseAngle
				hasEntranceB = not townSource and (perpOffset > 0 or util.signedAngle(perpTangent, details.routeVector) < math.rad(60))
				newOffset = 0
			elseif count <= 16 then
				newOffset = - (count % 4)*20
				angle = baseAngle+ (baseAngle>0 and -math.rad(180) or math.rad(180))
			end 
			count = count + 1
			local nextOption = positionOptions[count]
			newOffset = nextOption.offset
			perpOffset = nextOption.perpOffset 
			angle = baseAngle + nextOption.angle
			stationPos = nodedetails.nodePos + perpOffset * perpTangent + newOffset * tangent
			trace("A collsion was detected, attempting to adjust. perpOffset=",perpOffset," angle=",math.deg(angle), " baseAngle = ", math.deg(baseAngle), " newOffset=",newOffset, " trialPos=",stationPos.x,stationPos.y)
			offsetUsed = perpOffset
		end
		
		--if count == 3 then break end
	until not isError or count >= #positionOptions
	if isError then 
		offsetUsed = nil 
	end
	count = 0
	while isError and count < 32 do
		count = count +1
		angle = baseAngle
		hasEntranceB = not params.isAutoBuildMode and not townSource -- helps give us more options in a potentially congested area
		
		local segs = util.getStreetSegmentsForNode(nodedetails.otherNode and nodedetails.otherNode or nodedetails.node)
		local nextEdgeId = segs[1] == nodedetails.edgeId and segs[2] or segs[1]
		trace("Road station still error, trying another node, nextEdgeId=",nextEdgeId,"count=",count)
		if not nextEdgeId then 
			goto continue 
		end
		local nextEdge = util.getEdge(nextEdgeId)
		if nextEdge.type ~= 0 then 
			trace("Found bridge or tunnel, attempting other side")
			nodedetails.edgeId = details.edge.id
			nodedetails.otherNode = originalNodeDetails.node
			goto continue
		end
		connectNode = nextEdge.node0 == nodedetails.otherNode and nextEdge.node1 or nextEdge.node0
		trace("Using connectNode=",connectNode,"nextEdgeId=",nextEdgeId," originalNode=",nodedetails.node," otherNode=",nodedetails.otherNode)
		if #util.getStreetSegmentsForNode(connectNode) == 3 then 
			nodedetails = util.getOutboundNodeDetailsForTJunction(connectNode) 
		elseif #util.getStreetSegmentsForNode(connectNode) == 2  then
			nodedetails = util.getPerpendicularTangentAndDetailsForEdge(nextEdgeId, connectNode)
		end
		nodedetails.tangent.z=0
		for sign = -1, 1, 2 do 
			for rot = 0, 180, 180 do 
				stationPos = nodedetails.nodePos +sign*offset * vec3.normalize(nodedetails.tangent)
				trace("Attempting to place station at ",stationPos.x, stationPos.y, " offsetSign was ", sign,"rot=",rot)
				angle =  util.signedAngle(nodedetails.tangent, baseTangent) + math.rad(rot)
				local dummyProposal = api.type.SimpleProposal.new()
				constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
				isError = checkProposalForErrors(dummyProposal).isError
				if not isError then 
					isError = trialBuildConnectRoad(nodedetails.node, stationPos, dummyProposal) 
				end 
				if not isError then 
					connectNode = nodedetails.node
					offsetUsed = sign*offset
					break 
				end
			end 
			if not isError then 
				break 
			end
		end
		::continue::
	end
	if isError and not tryOtherNode and nodedetails.otherNode then 
		trace("Still error, trying other node")
		return constructionUtil.buildTruckStationForIndustry(newProposal,details, result, params,nodedetails.otherNode, targetPosition) 
	end 
	
	if isError then 
		error("Unable to build truck station at "..industry.name)
	end 
	constructionUtil.buildRoadStation(newProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
	 util.validateProposal(newProposal)
	
	--if  not hasEntranceB and nodedetails.isDeadEnd and not hasStubRoad and not townSource then  
	if nodedetails.isDeadEnd and not hasStubRoad and not townSource then  
		if not offsetUsed then 
			offsetUsed = 20
		end
		if offsetUsed < 0 then 
			offsetUsed = -offsetUsed
		end 
		trace("Begin check on build short stub road for",industry.name, "offsetUsed=",offsetUsed)
		local testProposal = api.type.SimpleProposal.new()
		for i, newConstruction in pairs(newProposal.constructionsToAdd) do 
			testProposal.constructionsToAdd[i]=newConstruction
		end 
		util.buildShortStubRoad(testProposal, nodedetails.node, util.smallCountryStreetType(), nextEntityId(), offsetUsed) 
		if not checkProposalForErrors(testProposal).isError then 
			trace("buildShortStubRoad: passed validation, building")
			util.buildShortStubRoad(newProposal,nodedetails.node, util.smallCountryStreetType(), nextEntityId(), offsetUsed) 
		else 
			trace("buildShortStubRoad: failed validation, aborting")
		end 	
	else 
		trace("Did not meet conditions for stub road: hasEntranceB=",hasEntranceB,"isDeadEnd?",nodedetails.isDeadEnd,"hasStubRoad=",hasStubRoad,"townSource=",townSource)
	end 
	if not result.usedNodes then 
			result.usedNodes = {} 
	end 
	result.usedNodes[connectNode]=true 
	trace("Built road station, the connect node was ",connectNode, " the angle was",math.deg(-angle))
	return  { 
		connectNode = connectNode, 
		hasEntranceB = hasEntranceB ,
		index = details.index,
		isDeadEnd = nodedetails.isDeadEnd ,
		hasStubRoad = hasStubRoad,
		constructionIdx = #newProposal.constructionsToAdd
	}
end

function constructionUtil.buildRoadDepotForSingleIndustry(newProposal, industry, edge,result , stationConstr)
	local offset = 60
	local baseTangent = vec3.new(0,1,0)
	trace("Begin buildRoadDepotForSingleIndustry, had stationConstr?",stationConstr)
	if constructionUtil.searchForRoadDepot(industry.position, 500) or industry.type=="TOWN" then 
		return 
	end
	if util.isCongestedIndustry(industry) then 
		return 
	end
	if not edge then return end 
	local edgeId
	if type(edge)=="number" then 
		edgeId = edge 
		edge = util.getEdge(edgeId)
	else 
		edgeId = edge.id 
	end 
	if not api.engine.entityExists(edgeId) then 
		trace("WARNING! buildRoadDepotForSingleIndustry: No edge with id",edgeId,"exists, aborting")
		return 
	end 
    local nodedetails = util.getDeadEndTangentAndDetailsForEdge(edgeId)
	local roadDepotConnectNode = edge.node0 == nodedetails.node and edge.node1 or edge.node0
	if result.usedNodes and result.usedNodes[roadDepotConnectNode] then 
		trace("Aborting road depot build, depot node already used")
		return 
	end
	local tangentRotation = nodedetails.isDeadEnd and math.rad(90) or 0
	local tangent = util.rotateXY(vec3.normalize(nodedetails.tangent), tangentRotation)
	local perpTangent = util.rotateXY(tangent, math.rad(90))
	local roadDepotConnectPos = util.nodePos(roadDepotConnectNode)
	local junctionEdge = util.isJunctionEdge(edgeId)
	if junctionEdge then 
		trace("Aborting road depot build, junctionEdge discovered")
		return 
	end
	local depotPos = roadDepotConnectPos + offset * tangent
	trace("set roadDepotConnectNode=",roadDepotConnectNode, "depotPos=",depotPos.x,depotPos.y)
	local baseAngle = util.signedAngle(tangent, baseTangent) 
	local industryPos = util.v3fromArr(industry.position)
	if util.distance(depotPos, industryPos) < util.distance(nodedetails.nodePos, industryPos) then -- moved into the industry, need to go the other way
		tangent = -1*tangent
		perpTangent = -1*perpTangent
		depotPos = roadDepotConnectPos + offset * tangent
		trace("inverting the depot position, depotPos=",depotPos.x,depotPos.y)
		baseAngle = baseAngle + (baseAngle>0 and -math.rad(180) or math.rad(180))
	end
	local angle = baseAngle
	local roadDepotConstruction
	local isError = false
	local count = 0
	local perpOffsets = { 30, -30 , 60, -60 }
	repeat 
		roadDepotConstruction = constructionUtil.createRoadDepotConstruction(industry, depotPos, -angle)
		isError = checkConstructionForCollision(roadDepotConstruction , stationConstr).isError
		if not isError then 
			isError = trialBuildConnectRoad(roadDepotConnectNode, depotPos) 
		end 
		if  isError then 
			trace("Road depot had a collision, adjusting")
			angle = baseAngle + (count==0 and -math.rad(90) or math.rad(90))
			local perpOffset = perpOffsets[count%#perpOffsets+1]
			offset = 24
			 
			depotPos = roadDepotConnectPos + offset * tangent+ perpOffset * perpTangent
		
		end
		count = count + 1 
	until not isError or count > 4 
	local nextNode = roadDepotConnectNode
	local nextEdge = edgeId 
	while isError and count < 10 do 
		count = count + 1
		local segs = util.getStreetSegmentsForNode(nextNode)
		nextEdge = segs[1]==nextEdge and segs[2] or segs[1] 
		local edge = util.getEdge(nextEdge)
		nextNode = nextNode == edge.node0 and edge.node1 or edge.node0 
		if #util.getSegmentsForNode(nextNode) > 2 then 
			goto continue 
		end 
		local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(nextEdge, nextNode)

		if result.usedNodes and result.usedNodes[nodeDetails.node] or #util.getSegmentsForNode(nodeDetails.node)>2 or util.isFrozenNode(nodeDetails.node) then 
			goto continue 
		end
		roadDepotConnectNode = nodeDetails.node
		roadDepotConnectPos = nodeDetails.nodePos
		if constructionUtil.searchForRoadDepot(roadDepotConnectPos) then 
			trace("A depot was already discovered, no need to build")
			return
		end
		local offset = 60
		for sign = -1, 1, 2 do 
			local tangent = sign * vec3.normalize(nodeDetails.tangent)
			local depotPos = roadDepotConnectPos + offset * vec3.normalize(tangent)
			
			local angle = util.signedAngle(tangent, baseTangent) 
			trace("set roadDepotConnectNode=",roadDepotConnectNode, "depotPos=",depotPos.x,depotPos.y, " sign=",sign," angle=",math.deg(angle))
			roadDepotConstruction = constructionUtil.createRoadDepotConstruction(industry, depotPos, -angle)
			isError = checkConstructionForCollision(roadDepotConstruction , stationConstr).isError
			if not isError then 
				isError = trialBuildConnectRoad(roadDepotConnectNode, depotPos) 
				if not isError then 
					local testProposal =  util.copyProposal(newProposal) 
					testProposal.constructionsToAdd[1+#testProposal.constructionsToAdd]=roadDepotConstruction
					
					isError = checkProposalForErrors(testProposal).isError
					trace("Checking the testProposal against the road depot, result was?",isError)
				end 
			end 
			if not isError then break end 
		end
	
		
		::continue::
	end 
	if isError then 
		trace("Skipping construciton of road depot") 
		return 
	end
	trace("Used roadDepotConnectNode",roadDepotConnectNode)
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=roadDepotConstruction
	return junctionEdge and roadDepotConnectPos or roadDepotConnectNode
end

function constructionUtil.buildRoadDepotForIndustry(newProposal, result, stationsBuilt)
	local nodes = {}
 
	if result.industry1.type~="TOWN" and not (stationsBuilt[1] and stationsBuilt[1].hasEntranceB) then	
		local node = constructionUtil.buildRoadDepotForSingleIndustry(newProposal, result.industry1, result.edge1, result, newProposal.constructionsToAdd[1])
		if node then 
			table.insert(nodes, { node = node, constructionIdx = #newProposal.constructionsToAdd })
		end
	end
 
	if result.industry2.type~="TOWN" and not (stationsBuilt[2] and stationsBuilt[2].hasEntranceB) then
		local node =constructionUtil.buildRoadDepotForSingleIndustry(newProposal, result.industry2, result.edge2, result, newProposal.constructionsToAdd[#newProposal.constructionsToAdd])
		if node then 	
			table.insert(nodes, { node = node, constructionIdx = #newProposal.constructionsToAdd })
		end
	end
	return nodes
end

function constructionUtil.connectRoadDepotForTown(town)
	local depot = constructionUtil.searchForRoadDepot(town.position, 500)
	if depot then 
		local depotNode = util.getFreeNodesForConstruction(depot)[1]
		if #util.getStreetSegmentsForNode(depotNode)==1 then 
			local entity = util.buildConnectingRoadToNearestNode(depotNode)
			if not entity then 
				trace("WARNING: connectRoadDepotForTown unable to find connection for",depotNode)
				return
			end 
			local newProposal = api.type.SimpleProposal.new()
			newProposal.streetProposal.edgesToAdd[1]=entity
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
				function(res, success)
					trace("Command to build connecting road was ",success)
					if not success then 
						debugPrint(res) 
					end
				end)
		end
	end
end

function constructionUtil.removeStation(stationId)	
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then 
		local station = util.getComponent(stationId, api.type.ComponentType.STATION)
		local edgeId = station.terminals[1].vehicleNodeId.entity
		local newEdge = util.copyExistingEdge(edgeId) 
		local newProposal =api.type.SimpleProposal.new()
		for i, edgeObj in pairs(newEdge.comp.objects) do 
			newProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj[1]
		end
		newEdge.comp.objects = {}
		newProposal.streetProposal.edgesToAdd[1]=newEdge
		newProposal.streetProposal.edgesToRemove[1]=edgeId
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
	else 
		local newProposal =api.type.SimpleProposal.new()
		newProposal.constructionsToRemove = { constructionId }
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
	end


end

function constructionUtil.developStationOffside(params) 
	local stationId = params.stationId 
	if not stationId then 
		local stations = api.engine.system.stationSystem.getStations(params.town)
		for i, station in pairs(stations) do
			local stationFull = util.getEntity(station)
			if stationFull.carriers.RAIL and not stationFull.cargo then 
				stationId = station 
				break
			end 
		end 
	end 
	if not stationId then 
		trace("developStationOffside: WARNING! No station found for ",params.town)
		return 
	end 
	local stationPos = util.getStationPosition(stationId)
	local busStation = constructionUtil.searchForNearestRoadStation(stationPos, 100 , false)
	local stationLength = constructionUtil.getStationLength(stationId) 
	local constructionId =  api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	
	
	local stationParams = util.deepClone(construction.params)
	local stationParallelTangent = util.v3(construction.transf:cols(1))
	local stationPerpTangent = util.v3(construction.transf:cols(0))
	local isCargo = util.getStation(stationId).cargo
	local stationOffset = (stationLength / 40) % 2 == 0 and 20 or 0
	if not params.setupProposalOnly then 
		
		local name = util.getComponent(stationId, api.type.ComponentType.NAME).name
		if stationParams.includeOffsideBuildings then 
			trace("Ending early as offside buildings already present at ",name)
			return
		end 
		
		
	
		local trainDepot = constructionUtil.searchForRailDepot(stationPos, 150 , false)

		if busStation then 
			local busStationPos = util.getStationPosition(busStation)
			local testP = stationPos - 10 * stationParallelTangent
			if util.distance(testP, busStationPos) > util.distance(stationPos, busStationPos) then 
				trace("Inverting the stationParallelTangent based on bus station position at ",name)
				stationParallelTangent = -1*stationParallelTangent
				stationOffset = -stationOffset
			else 
				trace("NOT inverting the stationParallelTangent based on bus station position at",name)
			end 
		
		else 
			trace("WARNING! No bus station found")
		end 
		
		
		local inputLength = stationParams.length
		
		trace("Input stationparams.length  was ",stationParams.length," isCargo=",isCargo )
		
		stationParams.includeOffsideBuildings = true
	 
		trace("Output stationparams.length  was ", stationParams.length)
		local isTerminus = stationParams.templateIndex and stationParams.templateIndex % 2 == 1
		if not stationParams.templateIndex then 
			stationParams.length = inputLength
			isTerminus = stationParams.modules[3699960]
			if isCargo then 
				if isTerminus then 
					stationParams.templateIndex = 7
				else 
					stationParams.templateIndex = 6
				end 
			else 
				if isTerminus then 
					stationParams.templateIndex = 1
				else 
					stationParams.templateIndex = 2
				end 
			end 
		else 
			constructionUtil.mapStationParamsTracks(stationParams,stationId)
		end
		stationParams.tracks = #util.getStation(stationId).terminals - 1
		local modulebasics =helper.createTemplateFn(stationParams, construction.fileName)
		
		local modules = util.setupModuleDetailsForTemplate(modulebasics)   
		stationParams.modules = modules 
		stationParams.seed = nil
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
		util.lazyCacheNode2SegMaps()
	end
	
	local stationWidth = 5 * (math.max(stationParams.tracks,3)+1)*1.5 
	trace("Setting up for underpass, stationWidth was",stationWidth)
	if stationParams.buildThroughTracks then 
		stationWidth = stationWidth + 10
	end 
	if isCargo then 
		stationWidth = stationWidth + 10+5*math.floor((stationParams.tracks+1)/2)
		trace("Increased station width for cargo to ",stationWidth)
	end
	local stationPerpOffset = 38
	local offset = stationWidth + stationPerpOffset 
	local smallStreet = util.year() < 1925 and api.res.streetTypeRep.find("standard/town_small_old.lua") or api.res.streetTypeRep.find("standard/town_small_new.lua")
	if isCargo then 
		smallStreet = util.year() < 1925 and api.res.streetTypeRep.find("standard/country_small_old.lua") or api.res.streetTypeRep.find("standard/country_small_new.lua")
	end 
	local startPoint = offset*stationPerpTangent + stationOffset*stationParallelTangent + stationPos
		
	trace("The calculated station width was", stationWidth, " startPoint was ",startPoint.x, startPoint.y, "stationPerpTangent length=",vec3.length(stationPerpTangent)," stationParallelTangent length=",vec3.length(stationParallelTangent), " stationPos was",stationPos.x, stationPos.y)
	local newProposal = params.newProposal or api.type.SimpleProposal.new()
	local nextNodeId = -1000-#newProposal.streetProposal.nodesToAdd
	local function getNextNodeId() 
		nextNodeId = nextNodeId-1
		return nextNodeId
	end 
	
	
	local startNode = util.newNodeWithPosition(startPoint,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=startNode 
	local startNodeIdx = #newProposal.streetProposal.nodesToAdd
	local maxLinks = 3
	if trainDepot and not isCargo then 
		local depotPos = util.getConstructionPosition(trainDepot)
		local testP = startPoint - 90 * stationParallelTangent
		local testP2 = startPoint + 90 * stationParallelTangent
		local d1 = util.distance(testP, depotPos)
		local d2 = util.distance(testP2, depotPos)
		trace("Insepcting depot position at ",name," depotPos=",depotPos.x, depotPos.y," distances:" ,d1,d2)
		if d1 < d2  then 
			trace("Inverting the stationParallelTangent based on train depot")
			stationParallelTangent = -1*stationParallelTangent
		else 
			trace("NOT inverting the stationParallelTangent based on train depot")
		end 
	end
	if isCargo then 
		local industry = util.searchForFirstEntity(startPoint, 200, "SIM_BUILDING")
		if industry then 
			local industryPos = util.v3fromArr(industry.position)
			local testP = startPoint - 90 * stationParallelTangent
			local testP2 = startPoint + 90 * stationParallelTangent
			local d1 = util.distance(testP, industryPos)
			local d2 = util.distance(testP2, industryPos)
			trace("Insepcting industryPos position at ",name," industryPos=",industryPos.x, industryPos.y," distances:" ,d1,d2)
			if d1 < d2  then 
				trace("Inverting the stationParallelTangent based on industryPos ")
				stationParallelTangent = -1*stationParallelTangent
			else 
				trace("NOT inverting the stationParallelTangent based on industryPos ")
			end 
		end
		local existingNodePos = startPoint - (offset + 25)*stationPerpTangent
		local existingNode = util.searchForClosestDeadEndNode(existingNodePos, 50)
		trace("developStationOffside: Looking for a node near",existingNodePos.x,existingNodePos.y, " found?",existingNode)
		if existingNode then 
			local nodeDetails = util.getDeadEndNodeDetails(existingNode)
			local tangent = vec3.normalize(nodeDetails.tangent)
			local angle = math.abs(util.signedAngle(tangent, stationParallelTangent))
			if angle > math.rad(90) then 
				angle = math.rad(180) - angle 
			end 
			trace("developStationOffside: Found node: The angle to the tangent was",math.deg(angle))
			if angle < math.rad(5) then 
				trace("Using the road node for the stationParallelTangent")
				stationParallelTangent = tangent
			end 
		end
	end 
	if not isCargo then 
		constructionUtil.buildLinkRoad(newProposal, startNode.entity, -1*stationParallelTangent, maxLinks, startPoint,  getNextNodeId)
		constructionUtil.buildLinkRoad(newProposal, startNode.entity, stationParallelTangent, maxLinks, startPoint,  getNextNodeId)
		constructionUtil.buildLinkRoad(newProposal, startNode.entity, stationPerpTangent, maxLinks, startPoint,  getNextNodeId)
	else 
	--	constructionUtil.buildLinkRoad(newProposal, startNode.entity, stationPerpTangent, 0, startPoint,  getNextNodeId)
	end 
	local firstNode = startNode
	if not isCargo then 
		firstNode = newProposal.streetProposal.nodesToAdd[1+startNodeIdx]  
		if not firstNode then 
			trace("WARNING! Could not find firstNode, aborting")
			return 
		end
		firstNode.comp.position.z = stationPos.z 
		newProposal.streetProposal.nodesToAdd[1+startNodeIdx]=firstNode -- seems necessary to copy it back with these objects
	end
	local firstNodePos = util.v3(firstNode.comp.position)
	local streetWidth = 16
	local underPassOffset = 25
	local roadApproach = stationPerpOffset - 0.75*streetWidth
	local roadApproachPos = firstNodePos + roadApproach*stationParallelTangent - roadApproach*stationPerpTangent
	roadApproachPos.z = roadApproachPos.z - 4
	trace("The roadApproachPos was",roadApproachPos.x, roadApproachPos.y)
	local underPassSurfaceNode = util.newNodeWithPosition(roadApproachPos,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassSurfaceNode 
	local underPassLink = initNewEntity(newProposal)
	underPassLink.comp.node0 = firstNode.entity
	underPassLink.comp.node1 = underPassSurfaceNode.entity
	underPassLink.streetEdge.streetType = smallStreet
	local length = roadApproach  * 4 * (math.sqrt(2)-1)
	util.setTangent(underPassLink.comp.tangent0, -length*stationPerpTangent)
	util.setTangent(underPassLink.comp.tangent1, length*stationParallelTangent)
	underPassLink.comp.tangent1.z = -2
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassLink 
	
	local underPassStartPos = roadApproachPos + underPassOffset * vec3.normalize(util.v3(underPassLink.comp.tangent1))
	underPassStartPos.z = underPassStartPos.z - 4
	trace("The underPassStartPos was",underPassStartPos.x, underPassStartPos.y, underPassStartPos.z)
	local underPassRamp = initNewEntity(newProposal) 
	local underPassStartNode = util.newNodeWithPosition(underPassStartPos,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassStartNode  
	underPassRamp.comp.node0 = underPassSurfaceNode.entity 
	underPassRamp.comp.node1 = underPassStartNode.entity 
	underPassRamp.streetEdge.streetType = smallStreet
	local tangent =  underPassStartPos-roadApproachPos
	util.setTangent(underPassRamp.comp.tangent0,tangent)
	util.setTangent(underPassRamp.comp.tangent1,tangent)
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassRamp  
	
	local roadStationOffset = 1.5*streetWidth + stationWidth
	local connectNode
	
	
	local underPassEndPos = underPassStartPos - roadStationOffset*stationPerpTangent
	if isCargo then 
		--roadStationOffset = roadStationOffset + underPassOffset
		local searchPoint = stationPos - stationOffset *stationPerpTangent
		trace("developStationOffside: Looking for a node near",searchPoint.x,searchPoint.y)
		connectNode =util.searchForNearestNode(searchPoint, 100, function(otherNode) 
			return #util.getTrackSegmentsForNode(otherNode.id)==0 and not util.isFrozenNode(otherNode.id)
		end)
		trace("found? ",connectNode)
		if connectNode then 
			local connectNodePos = util.v3fromArr(connectNode.position)
			local distToStation = util.distance(connectNodePos, stationPos)
			local angle = math.abs(util.signedAngle(stationPos-connectNodePos, stationPerpTangent))
			local perpDistance = math.cos(angle)*distToStation
			trace("The connect node had a relative perp distance of ",perpDistance,"based on angle",math.deg(angle)," and distToStation=",distToStation)
	 
			local distToFirstNodePos = util.distance(connectNodePos, underPassStartPos)
			local angle = math.abs(util.signedAngle(underPassStartPos-connectNodePos, stationPerpTangent))
			local perpDistance = math.cos(angle)*distToFirstNodePos
			trace("The connect node had a relative perp distance of ",perpDistance,"based on angle",math.deg(angle)," and distToFirstNodePos=",distToFirstNodePos)
			underPassEndPos = underPassStartPos - perpDistance*stationPerpTangent
			trace("The underPassEndPos was",underPassEndPos.x, underPassEndPos.y)
		end 
	end
	local underPassEndNode = util.newNodeWithPosition(underPassEndPos,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassEndNode  
	local underPass = initNewEntity(newProposal) 
	underPass.comp.node0 = underPassStartNode.entity 
	underPass.comp.node1 = underPassEndNode.entity 
	local length = roadStationOffset  * 4 * (math.sqrt(2)-1)
	
	util.setTangent(underPass.comp.tangent0, length*vec3.normalize(tangent))
	util.setTangent(underPass.comp.tangent1, -length*vec3.normalize(tangent))
	underPass.comp.type=2
	underPass.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	underPass.streetEdge.streetType = smallStreet
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPass  
	
	local roadApproachPos2 = firstNodePos - (roadStationOffset+roadApproach)*stationPerpTangent

	trace("The roadApproachPos2 was",roadApproachPos2.x, roadApproachPos2.y)
	if not connectNode then 
		connectNode =util.searchForNearestNode(roadApproachPos2, 40, function(otherNode) 
			return #util.getTrackSegmentsForNode(otherNode.id)==0 and not util.isFrozenNode(otherNode.id)
		end)
	end
	local connectNodePos
	if not connectNode then 
		trace("no connect node found")
		connectNodePos = roadApproachPos2 - underPassOffset*stationPerpTangent
		local newNode = util.newNodeWithPosition(connectNodePos,  getNextNodeId() )
		newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode  
		
		connectNode = newNode.entity
--		return 
	else  
		connectNode = connectNode.id
		connectNodePos = util.nodePos(connectNode)
	end
	trace("The connect node was",connectNode)
	roadApproachPos2.z = connectNodePos.z
	local underPassSurfaceNode2entity
	if not isCargo then 
		local underPassSurfaceNode2 = util.newNodeWithPosition(roadApproachPos2,  getNextNodeId() )
		newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassSurfaceNode2 
		underPassSurfaceNode2entity = underPassSurfaceNode2.entity
	else
		underPassSurfaceNode2entity = connectNode
		roadApproachPos2 = connectNodePos
	end 	
	local underPassRamp2 = initNewEntity(newProposal)
	underPassRamp2.comp.node0 = underPassEndNode.entity
	underPassRamp2.comp.node1 = underPassSurfaceNode2entity
	underPassRamp2.streetEdge.streetType = smallStreet
	util.setTangent(underPassRamp2.comp.tangent0,roadApproachPos2-underPassEndPos)
	util.setTangent(underPassRamp2.comp.tangent1,roadApproachPos2-underPassEndPos)
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassRamp2  
	
	if not isCargo then 
		local underPassLink2 = initNewEntity(newProposal)
		underPassLink2.comp.node0 = underPassSurfaceNode2entity
		underPassLink2.comp.node1 = connectNode
		underPassLink2.streetEdge.streetType = smallStreet
		local length = roadApproach  * 4 * (math.sqrt(2)-1)
		local tangent= connectNodePos-roadApproachPos2
		util.setTangent(underPassLink2.comp.tangent0, tangent)
		util.setTangent(underPassLink2.comp.tangent1, tangent)
		--underPassLink2.comp.tangent1.z = 2
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassLink2 
	end
	
	if connectNode < 0 then 
		local found = constructionUtil.buildLinkRoad(newProposal, connectNode, -1*stationParallelTangent, maxLinks, connectNodePos,  getNextNodeId)
		found = found or constructionUtil.buildLinkRoad(newProposal, connectNode, stationParallelTangent, maxLinks, connectNodePos,  getNextNodeId)
		found = found or constructionUtil.buildLinkRoad(newProposal, connectNode, -1*stationPerpTangent, maxLinks, connectNodePos,  getNextNodeId)
		trace("Attempt to build connection from connectNode result was?",found)
	end
	
--	debugPrint(newProposal)
	if params.setupProposalOnly then 	
		return 
	end
	for i = 1 , #newProposal.streetProposal.nodesToAdd do
		local node = newProposal.streetProposal.nodesToAdd[1]
		local pos2f = api.type.Vec2f.new(node.comp.position.x,node.comp.position.y)
		constructionUtil.addWork(function() 
			api.cmd.sendCommand(api.cmd.make.developTown(pos2f), constructionUtil.standardCallback)
		end)
	end
	util.validateProposal(newProposal)
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
 
	
end 

function constructionUtil.buildRoadDepotForTown(newProposal, town)
	if constructionUtil.searchForRoadDepot(town.position, 500) then 
		return
	end
	local options = {}
	 
	for node , nodepos in pairs(connectEval.findDeadEndNodes(town, 500)) do 
		local testProposal = api.type.SimpleProposal.new()
		local nodeDetails = util.getDeadEndTangentAndDetailsForEdge(util.getStreetSegmentsForNode(node)[1])
		local depotPos = nodeDetails.nodePos + 30*vec3.normalize(nodeDetails.tangent) + 30*vec3.normalize(util.rotateXY(nodeDetails.tangent, math.rad(90)))
		local angle = util.signedAngle(vec3.new(0,1,0), vec3.normalize(nodeDetails.tangent))+math.rad(90)
		local roadDepotConstruction = constructionUtil.createRoadDepotConstruction(town, depotPos, angle)
		local testResult = checkConstructionForCollision(roadDepotConstruction , stationConstr)
		if not testResult.isError then 
			table.insert(options, { roadDepotConstruction=roadDepotConstruction, scores={ testResult.costs}})
		end
	end
	if #options > 0 then 
		local roadDepotConstruction = util.evaluateWinnerFromScores(options).roadDepotConstruction
		newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=roadDepotConstruction
	end
end
function constructionUtil.copyConstruction(constructionId)
	local construction = util.getConstruction(constructionId)
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	local nameComp = util.getComponent(constructionId, api.type.ComponentType.NAME)
	if nameComp then 
		newConstruction.name=nameComp.name 
	end
	newConstruction.fileName = construction.fileName 
	local playerEntity = util.getComponent(constructionId, api.type.ComponentType.PLAYER_OWNED)
	if playerEntity then 
		newConstruction.playerEntity = playerEntity.player
	end
	local params = util.deepClone(construction.params )
	params.seed = 0
	newConstruction.params = params
	newConstruction.transf =  construction.transf
	return newConstruction
end

function constructionUtil.copyNewConstruction(construction) 
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	 
	newConstruction.name=construction.name 
	 
	newConstruction.fileName = construction.fileName 
 
	newConstruction.playerEntity = construction.playerEntity
 
	local params = util.deepClone(construction.params )
	params.seed = 0
	newConstruction.params = params
	newConstruction.transf =  construction.transf
	return newConstruction
end
function constructionUtil.removeConstructionTrafficLights(constructionId) 
	trace("Begin constructionUtil.removeConstructionTrafficLights")
	local freeNodes = util.getFreeNodesForConstruction(constructionId)
	local construction = util.getConstruction(constructionId)
	local edgesToAdd = {}
	local edgesToRemove = {}
	local alreadySeen = {}
	local oldToNewEdges = {}
	local oldNodesByPosition = {}
	local freeNodesByPosition = {}
	for i, node in pairs(freeNodes) do 
		local p = util.nodePos(node)
		freeNodesByPosition[i]=p
		local hash = util.pointHash3d(p,2)
		oldNodesByPosition[hash]=node
		for i, seg in pairs(util.getSegmentsForNode(node)) do 
			if not alreadySeen[seg] and not util.isFrozenEdge(seg) then 
				table.insert(edgesToRemove, seg)
				local newEdge = util.copyExistingEdge(seg, -1-#edgesToAdd)
				table.insert(edgesToAdd, newEdge)
				oldToNewEdges[seg]=newEdge
			end
		end 
	end 
	local newProposal = api.type.SimpleProposal.new()
	for i , edge in pairs(edgesToAdd) do 
		--newProposal.streetProposal.edgesToAdd[i]=edge
	end 
	for i , edge in pairs(edgesToRemove) do 
		newProposal.streetProposal.edgesToRemove[i]=edge
	end 
	
	--[[for i , node in pairs(nodesToAdd) do 
		newProposal.streetProposal.nodesToAdd[i]=node
	end ]]--
	for i, node in pairs(freeNodes) do 
		if #util.getSegmentsForNode(node) > 1 then 
			newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=node
		end
	end 
	newProposal.constructionsToAdd[1]=constructionUtil.copyConstruction(constructionId)
	newProposal.constructionsToRemove = { constructionId } 
	--debugPrint({newProposal=newProposal})
	local context = util.initContext()
	local fullProposal = api.cmd.make.buildProposal(newProposal,context , true)
	--debugPrint({newProposal = newProposal, fullProposal = fullProposal})
	trace("There were ",#fullProposal.proposal.proposal.addedNodes," addedNodes")
	local originalFrozenEdges
	local newFreeNodes = {} 
	for i , edge in pairs(fullProposal.proposal.proposal.addedSegments) do 
		local originalSeg = fullProposal.proposal.proposal.removedSegments[i+#edgesToRemove]
		util.setTangent(edge.comp.tangent0, originalSeg.comp.tangent0)
		util.setTangent(edge.comp.tangent1, originalSeg.comp.tangent1)
		fullProposal.proposal.proposal.addedSegments[i]=edge
	end
	for i, node in pairs(fullProposal.proposal.proposal.addedNodes) do 
		if not util.contains(fullProposal.proposal.proposal.frozenNodes, i-1) then 
			local nearestOriginal = util.evaluateWinnerFromSingleScore(freeNodesByPosition, function(p) return util.distance(p, node.comp.position) end)
			trace("The nearestOriginal was at ",nearestOriginal.x,nearestOriginal.y, " vs",node.comp.position.x, node.comp.position.y)
			util.setPositionOnNode(node, nearestOriginal)
			fullProposal.proposal.proposal.addedNodes[i]=node
		end 
	end 	
	
	for i, node in pairs(fullProposal.proposal.proposal.addedNodes) do 
		node.comp.trafficLightPreference= 1
		fullProposal.proposal.proposal.addedNodes[i]=node 
		
		local hash = util.pointHash3d(node.comp.position, 2)
		local originalNode = oldNodesByPosition[hash]
		trace("Updated traffic light prefference at ",i," found originalnode?",originalNode)
		if originalNode then 
			for j, seg in pairs(util.getSegmentsForNode(originalNode)) do 
				if oldToNewEdges[seg] then 
					local edge = oldToNewEdges[seg]
					
						
					if edge.comp.node0 == originalNode then 
						edge.comp.node0 = node.entity
					else 
						edge.comp.node1 = node.entity
					end 
						 
						
					 
				end 
			end 
		end
	end 
	local nextEdgeId = fullProposal.proposal.proposal.addedSegments[#fullProposal.proposal.proposal.addedSegments].entity
	for i , edge in pairs(edgesToAdd) do 
		--newProposal.streetProposal.edgesToAdd[i]=edge
		edge.entity = nextEdgeId-i 
		fullProposal.proposal.proposal.addedSegments[1+#fullProposal.proposal.proposal.addedSegments]=edge
	end
	--debugPrint({fullProposalAfter=fullProposal})
	api.cmd.sendCommand(fullProposal,function(res, success) 
		trace("removeConstructionTrafficLights: result was",success)
		if not success then 
			debugPrint({res=res})
		end
	end)
end 
return constructionUtil