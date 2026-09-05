local util = require("ai_builder_base_util")
local vec3 = require "vec3"

local minimap = {}

local tracelog = util.tracelog 
 
local function trace(...) 	
	if tracelog then 
		print(...)
	end 
end

local displayResolutionChoices = tracelog and false -- used for debug / fine tuning

local drawRiverMeshes = false

 util.colourIncrement = 1

local function r(colour) 
	return util.colourIncrement*math.floor(math.min(255,colour)/util.colourIncrement)
end
 
local function stringifyColourStyle(colour) 
	local res=  	"AIMinimap-"..tostring(r(colour[1])).."-"..tostring(r(colour[2])).."-"..tostring(r(colour[3]))
	--print("stringifyColourStyle res was ",res)
	return res 
 end 

minimap.guiState = { 
	industryFilter = {},
	industryLocations = {},
	filter = {},
	resolution = 8,
	mapSize = 2
}

local guiState = minimap.guiState

local iconSize -- recycling for performance, cannot init here though "cannot access field gui"
local function newIcon(file) 
	if not iconSize then 
		iconSize = api.gui.util.Size.new(20, 20)
	end
	local icon = api.gui.comp.ImageView.new(file)
	icon:setMaximumSize(iconSize)
	icon:setMinimumSize(iconSize)
	return icon
end 
local colourKey = {
	track = { 99, 79 ,70},
	road = { 120, 112 ,120},
	--industry = {240, 0, 0},
	--townBuilding = {0, 240, 0},
	station = {0, 240, 240},
	town = { 255, 255,255},
	camera = { 255, 255,255},
}

local function toVec4f(colour) 
	return api.type.Vec4f.new(colour[1]/255, colour[2]/255, colour[3]/255, 1)
end 

local industryColours = { 
	["industry/chemical_plant.con"] = { 146, 124, 187},
	["industry/coal_mine.con"] = { 0, 0, 0},
	["industry/construction_material.con"] = { 177, 57, 57},
	["industry/farm.con"] = { 248, 184, 110},
	["industry/food_processing_plant.con"] = { 206, 146, 93},
	["industry/forest.con"] = { 55, 125, 34 },
	["industry/fuel_refinery.con"] = { 255, 135, 77 },
	["industry/goods_factory.con"] = { 158, 109, 70 },
	["industry/iron_ore_mine.con"] = { 204, 123, 83 },
	["industry/machines_factory.con"] = { 215, 215, 215} ,
	["industry/oil_refinery.con"]={86, 108, 121},
	["industry/oil_well.con"]={155, 176, 176},
 	["industry/quarry.con"] = { 163, 163 ,163},
	["industry/saw_mill.con"] = { 228, 188 ,160},
	["industry/steel_mill.con"] = { 81, 118 ,155},
	["industry/tools_factory.con"] = { 176, 207 ,221},
}

local nextIndustryColour  = 1

local industryIcons = {}

local function getIndustryIcon(fileName) 
	if not industryIcons[fileName] then 
		local fallbackIcon = "ui/icons/main-menu/map_industry@2x.tga"
		local repId = api.res.constructionRep.find(fileName)
		local icon 
		if repId == -1 then 
			trace("WARNING! No rep entry found for",fileName) 
		else 
			local construction = api.res.constructionRep.get(repId)
			local foundCargoType 
			local fallbackCargoType 
			for i, param in pairs(construction.params) do  
				local isInputCargo = param.key == "inputCargoTypeForAiBuilder" 
				local isOutputCargo = param.key == "outputCargoTypeForAiBuilder"
				if isInputCargo or isOutputCargo then 
					for j, cargoType in pairs(param.values) do 
						if cargoType ~= "NONE" then
							if isOutputCargo then 
								foundCargoType = cargoType
							else 
								fallbackCargoType = cargoType
							end 
							break -- just take the first
						end
						
					end
					if foundCargoType then 
						break
					end
				end 
			end
			local cargoType = foundCargoType or fallbackCargoType
			if cargoType then 
				 local cargoIdx = api.res.cargoTypeRep.find(cargoType)
				 if cargoIdx ~= -1 then 
					local cargoRep = api.res.cargoTypeRep.get(cargoIdx)
					icon = cargoRep.icon 
				 end 
			end
		end 
		industryIcons[fileName] = icon or fallbackIcon
	end 
	return industryIcons[fileName]
end 

local function getIndustryColour(fileName) 
	
	if not industryColours[fileName] then 
		local baseColours = api.res.getBaseConfig().gui.lineColors
		local nextColour = baseColours[1 + nextIndustryColour % #baseColours]
		industryColours[fileName] = { 255*nextColour.x, 255*nextColour.y, 255*nextColour.z }
		nextIndustryColour = nextIndustryColour + 1
	end 
	
	return industryColours[fileName] 
end 

local function getIndustries() 
	local res = {}
	for i, name in pairs(api.res.constructionRep.getAll()) do
		if string.find(name, "industry") and not string.find(name, "extension")  then
			table.insert(res, name)
		end
	end
	table.sort(res)
	return res 
end
 

local function toggleAllVisibility() 
	if guiState.components then 
		for name, comp in pairs(guiState.components) do 
			comp:setVisible(not guiState.filter[name], true)
		end 
	end 	
	if guiState.industryComps then 
		for name, comps in pairs(guiState.industryComps) do 
			for i, comp in pairs(comps) do 
				comp:setVisible(not guiState.industryFilter[name], true)
			end
		end
	end 
	if guiState.townComponents then 
		for i, comp in pairs(guiState.townComponents) do 
			comp:setVisible(not guiState.filter["town"], true)
		end 
	end 
end 

local function toggleIndustryVisbility(fileName) 
	if guiState.industryComps[fileName] then 
		trace("Updating industry visibility for ", fileName)
		for i, comp in pairs(guiState.industryComps[fileName]) do 
			local isVisble = not guiState.industryFilter[fileName]  
			comp:setVisible(isVisble, true)
		end 	
	end 
end 

local function buildIndustrySelector() 
	 local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	local checkBoxes = {}
	 
	local masterCheckbox = api.gui.comp.CheckBox.new(_("Industries"))
	masterCheckbox:setSelected(true,false)
	local colHeaders = {
		masterCheckbox
	}		
	local masterToggleEvent = false 
	masterCheckbox:onToggle(function(b)
		masterToggleEvent = true 
		for i, checkbox in pairs(checkBoxes) do 
			checkbox:setSelected(b, true)
		end 
		masterToggleEvent = false
		addWork(toggleAllVisibility)
	end)
	local displayTable = api.gui.comp.Table.new(#colHeaders, selectable)
	--displayTable:setHeader(colHeaders)
	local minSize = api.gui.util.Size.new( 10, 10 )
	for i, fileName in pairs(getIndustries()) do 
		local checkbox = api.gui.comp.CheckBox.new("")
		table.insert(checkBoxes, checkbox)
		checkbox:setSelected(true, false)
		checkbox:onToggle(function(b) 
			guiState.industryFilter[fileName]=not b 
			if not masterToggleEvent then 
				addWork(function() toggleIndustryVisbility(fileName)  end)
			end
		end)
		local innerLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
		innerLayout:addItem(checkbox)  
		local colourComp = newIcon(getIndustryIcon(fileName))
		--colourComp:setMinimumSize(minSize)
		innerLayout:addItem(colourComp)
		local name = fileName
		local construction = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
		if construction.description and construction.description.name then 
			name = construction.description.name 
		end 
		innerLayout:addItem(api.gui.comp.TextView.new(_(name)))
		local wrapper = api.gui.comp.Component.new("")
		wrapper:setLayout(innerLayout)
--		boxLayout:addItem(innerLayout)
		displayTable:addRow({wrapper})
	end 
	--local wrapper =  api.gui.comp.ScrollArea.new(displayTable, "")
	--wrapper:ensureVisible(masterCheckbox)
	--return wrapper 
	boxLayout:addItem(masterCheckbox)
	boxLayout:addItem(displayTable) 
	local wrap = api.gui.comp.Component.new("wrap")
	wrap:setLayout(boxLayout)
	return wrap
--	return boxLayout
end 
local function buildKey() 
	local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	local colHeaders = {
		api.gui.comp.TextView.new(_("Key"))
	}		
	
	local displayTable = api.gui.comp.Table.new(#colHeaders, selectable)
	displayTable:setHeader(colHeaders)
	local minSize = api.gui.util.Size.new( 20, 20 )
	for i, name in pairs(util.getKeysAsTable(colourKey)) do -- NB iterate over keys to keep sort order consistent
		local colour = colourKey[name]
		local checkbox = api.gui.comp.CheckBox.new("")
		checkbox:setSelected(true, false)
		checkbox:onToggle(function(b) 
			guiState.filter[name]=not b 
			--addWork(guiState.refreshMap)
			addWork(toggleAllVisibility)
		end)
		local innerLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
		 
		innerLayout:addItem(checkbox)
		local colourComp 
		if name == "town" then 
			colourComp = newIcon("ui/icons/main-menu/map_town@2x.tga")
		else 
			colourComp = api.gui.comp.Component.new(stringifyColourStyle(colour))
		end
		colourComp:setMinimumSize(minSize)
		innerLayout:addItem(colourComp)
 
		innerLayout:addItem(api.gui.comp.TextView.new(_(name)))
		local wrapper = api.gui.comp.Component.new("")
		wrapper:setLayout(innerLayout)
--		boxLayout:addItem(innerLayout)
		displayTable:addRow({wrapper})
	end 
	
	debugPrint({displayTableMinSize = displayTable:calcMinimumSize()})
	--[[displayTable:setMinimumSize(displayTable:calcMinimumSize()) -- always show the top
	
	displayTable:onVisibilityChange(function(visible)
		if visible then 
			addWork(
				function()
					trace("setting minimum size for table")
					displayTable:setMinimumSize(displayTable:calcMinimumSize()) 
				end
			)
		end 
	end)]]--
	
	boxLayout:addItem(displayTable)
	boxLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local industryKey = buildIndustrySelector()
	boxLayout:addItem(industryKey)
	local wrap = api.gui.comp.Component.new("wrap")
	wrap:setLayout(boxLayout)
	--debugPrint({wrapMinSize = wrap:calcMinimumSize(), displayTableMinSize = displayTable:calcMinimumSize()})
	--wrap:setMinimumSize(wrap:calcMinimumSize())
 	return wrap, displayTable, industryKey
end
 
local thVec2f -- = api.type.Vec2f.new(0,0) -- N.B. cannot initialise here ... cannot access "type"

local function th(x,y)
	if not thVec2f then 
		thVec2f = api.type.Vec2f.new(0,0) -- turns out that creating a new object each time is expensive, just recycle this as not concerned with thread safety
	end
	thVec2f.x = x 
	thVec2f.y = y
	return api.engine.terrain.getBaseHeightAt(thVec2f)-util.getWaterLevel()
end



local mapBoundary
local function getMapBoundary() 
	local function discoverMapBoundary() 
		local x
		local y
		local vec2f = api.type.Vec2f.new(0,0)
		for i = 0, 50000  do
			vec2f.x = i 
			if not api.engine.terrain.isValidCoordinate(vec2f) then
				x = i-1 
				break
			end
		end
		vec2f.x = 0
		for i = 0, 50000 do
			vec2f.y = i
			if not api.engine.terrain.isValidCoordinate(vec2f) then
				y = i-1 
				break
			end
		end
		
		local maxZ = 0 
		for i = -x, x, 10 do 
			for j = -y, y, 10 do 
				maxZ = math.max(maxZ, th(i,j))
			end 
		end 
		trace("The map boundary was found at ",x,y, " maxZ = ",maxZ)
		return vec3.new( x, y ,maxZ)
	end
	if not mapBoundary then 
		mapBoundary = discoverMapBoundary()
	end 
	return mapBoundary
end 
 
 
 
 
local boxmin 
local boxmax 
local box3

local function findIntersectingEntities(x, y, offset)
	local result = {} 
	if not box3 then 
		boxmin = api.type.Vec3f.new(0,0,0)
		boxmax = api.type.Vec3f.new(0,0,0)
		box3 = api.type.Box3.new(boxmin, boxmax)
	end 
	-- recycling objects for performance 
	boxmin.x = x-offset
	boxmin.y = y-offset
	boxmin.z = -50
	
	boxmax.x = x+offset
	boxmax.y = y+offset
	boxmax.z = 10000
	
	-- NB tested in console, reassignment required 
	box3.min = boxmin 
	box3.max = boxmax
	--local box =  api.type.Box3.new(api.type.Vec3f.new(x,y, -50),api.type.Vec3f.new(x+offset,y+offset, 10000))
	local count = 0
	api.engine.system.octreeSystem.findIntersectingEntities(box3, function(entity, boundingVolume)
		table.insert(result, entity)
	end)
	return result 
end

 
local function textAndIcon(text, icon)
	local textView = api.gui.comp.TextView.new(_(text))
	local iconView = api.gui.comp.ImageView.new(icon)
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	boxLayout:addItem(textView)
	boxLayout:addItem(iconView)
	local comp = api.gui.comp.Component.new(" ")
	comp:setLayout(boxLayout)
	return comp	
end

local function buildColourForTerrrain(h)
	
	if h < 0 then 
		return { 0, 0 , 255+h }
	else 
		local base = 96
		local maxZ = getMapBoundary().z 
		local val = (h / maxZ)*(256-base)
		local newVal = val + base
	--	trace("The newVal was ",newVal," based on height of ",h, "maxZ=",maxZ)
		--newVal = math.min(maxC, 16*math.floor(newVal/16))
		return {newVal, newVal, 0} 
	end 
end 

local function buildResolutionLayout()
	local boxlayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	if displayResolutionChoices then 
		-- build map resolution choices
		local buttongroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
		local veryLow = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Very low')))
		local low = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Low')))
		local medium = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Medium')))
		local high = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('High')))
		local ultra = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Ultra')))
		medium:setSelected(true, false)
		buttongroup:add(veryLow)
		buttongroup:add(low)
		buttongroup:add(medium)
		buttongroup:add(high)
		buttongroup:add(ultra)
		ultra:setVisible(false, false)
		ultra:setTooltip(_("WARNING! May cause game lag!"))
		buttongroup:setOneButtonMustAlwaysBeSelected(true)
		
		boxlayout:addItem(api.gui.comp.TextView.new(_('Resolution').._(':')))
		boxlayout:addItem(buttongroup)
		
		local lookup = { 64, 8, 4, 2, 1}
		
		buttongroup:onCurrentIndexChanged(function(index) 
			guiState.resolution = lookup[index+1]
			addWork(guiState.refreshMap)
		end) 
	end
	
	-- build map size choices
	local buttongroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local small = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Small')))
	local medium = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Medium')))
	local large = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(_('Large'))) 
	medium:setSelected(true, false)
	buttongroup:add(small)
	buttongroup:add(medium)
	buttongroup:add(large)
  
	buttongroup:setOneButtonMustAlwaysBeSelected(true)
	
	boxlayout:addItem(api.gui.comp.TextView.new(_('Size').._(':')))
	boxlayout:addItem(buttongroup)
	
	local lookup = {  3, 2, 1}
	
	buttongroup:onCurrentIndexChanged(function(index) 
		guiState.mapSize = lookup[index+1]
		addWork(guiState.refreshMap)
	end)
	
	local wrap = api.gui.comp.Component.new("wrap")
	wrap:setLayout(boxlayout)
	return wrap
end 



function minimap.refreshMap(outerLayout, guiState)
	local begin = os.clock() 
	 
	if guiState.connection then 
		connection:disconnect()
	end
	guiState.components = nil 
	guiState.industryComps = nil
	guiState.townComponents = nil
	for i =  outerLayout:getNumItems(), 1, -1 do 
		local item = outerLayout:getItem(i-1)
		outerLayout:removeItem(item)
		item:destroy()
	end

	trace("Removed previous layout in ",(os.clock()-begin))
	local absLayout = api.gui.layout.AbsoluteLayout.new()
	local mapBoundary = getMapBoundary()
	local maxSize = api.gui.util.getGameUI():getMainRendererComponent():getContentRect()
	local minSize =  guiState.resolution
	local extremeRatio = mapBoundary.y > 1.5*mapBoundary.x 
	local mapSizeFactor = guiState.mapSize
	if extremeRatio and guiState.mapSize > 1 and minSize > 1 then 
		minSize = minSize /2 
		mapSizeFactor = mapSizeFactor / 1.5
	end
	local maxH = math.floor((maxSize.h-minSize) / mapSizeFactor)
	local maxW = math.floor((maxSize.w-minSize) / mapSizeFactor)
	
	local scale = math.min(maxW / mapBoundary.x, maxH / mapBoundary.y) / 2
	
	--scale = scale / minSize
	local invScale = math.ceil(1/(scale/minSize))
	
	local startX = math.floor(scale * mapBoundary.x)
	local startY = math.floor(scale * mapBoundary.y)
	
	-- NB need to shave off the edges of the map to enable a 1-1 mapping of integer coordinates
	 local xMax = math.floor(mapBoundary.x/invScale)*invScale
	 local yMax = math.floor(mapBoundary.y/invScale)*invScale
	--local xMax = math.ceil(mapBoundary.x/invScale)*invScale
	--local yMax = math.ceil(mapBoundary.y/invScale)*invScale
	trace("The chosen scale was ",invScale, " from ", scale," Startx=",startX, " starty = ",startY, " maxH=",maxH, "maxW=",maxW, "calulated maxW should be",(2*mapBoundary.x/scale))
	
	trace("The xMax=",xMax," from ",mapBoundary.x," and yMax=",yMax," from ",mapBoundary.y)
	--debugPrint(maxSize)
	
	local count = 0 

 	local iconSize = 20
	---invScale = invScale*2
	
	--boxlayout:setName("Minimap-style")
	local mapScale = minSize/invScale
	local pixelSize = api.gui.util.Size.new( minSize, minSize )
	local function xCoord(x) 
--		return math.floor((minSize/2)+(mapScale*(x+xMax)))
		return math.floor((0/2)+(mapScale*(x+xMax)))
	end 
	local function yCoord(y) 
	--	return math.floor((minSize/2)+(mapScale*(-y+yMax)))--NB map is "upside down" without inverting y, starts zero at top
		return math.floor((minSize/2)+(mapScale*(-y+yMax)))
	end
	local ySet = {}
	guiState.pixelSize = pixelSize
	local maxX = 0
	local maxY = 0
	local rect = api.gui.util.Rect.new()
	for x = -xMax, xMax, invScale do  
		
		for y = -yMax, yMax, invScale do 
			count = count + 1
			local terrainHeight = th(x,y) 
			local terrainColour = buildColourForTerrrain(terrainHeight)
		 
			local pixel = api.gui.comp.Component.new(stringifyColourStyle(terrainColour)) 
				 
			-- local rect = api.gui.util.Rect.new()
			 rect.x = xCoord(x)
			 rect.y = yCoord(y)
			 rect.w = minSize
			 rect.h = minSize
			 maxX = math.max(rect.x, maxX)
			 maxY = math.max(rect.y, maxY)
 

			 absLayout:addItem(pixel, rect)
 
		end 
	end  
	local lineSize = 4
	local from = api.type.Vec2f.new(0, 0)
	local to = api.type.Vec2f.new(0, 0)
	maxX = maxX + minSize 
	maxY = maxY + minSize --/2
	
		rect.x = 0-- math.floor(maxX/2)
		rect.y = math.floor(maxY/2)
		rect.w = maxX
		rect.h = maxY
	local maxEdges = 5000 -- arrived at experimentally, not sure exacly what the number is but exceeding "mnum_elements" causes crash to desktop!
	if drawRiverMeshes then  
		local lineRendererCompWater = api.gui.comp.LineRenderView.new()
		absLayout:addItem(lineRendererCompWater, rect)
		local count = 0
		api.engine.forEachEntityWithComponent(function(entity)
			local mesh = util.getComponent(entity, api.type.ComponentType.WATER_MESH)
			--local rect = api.gui.util.Rect.new()
			count = count + 1
			if count >= maxEdges then 
				return 
			end
			for i = 1, #mesh.contours  do 
				for j = 2, #mesh.contours[i].vertices do 
					local p0 = mesh.contours[i].vertices[j-1]
					local p1 = mesh.contours[i].vertices[j]
					from.x = xCoord(p0.x)
					from.y = yCoord(p0.y)
					to.x = xCoord(p1.x)
					to.y = yCoord(p1.y)
					lineRendererCompWater:addLine(from, to)
				end
			end
		end, api.type.ComponentType.WATER_MESH)
		lineRendererCompWater:setWidth(minSize)
		lineRendererCompWater:setColor(toVec4f({0, 0, 255}))
	end	
	local lineRendererComp = api.gui.comp.LineRenderView.new()
	absLayout:addItem(lineRendererComp, rect)
	local lineRendererCompTrack = api.gui.comp.LineRenderView.new()
	absLayout:addItem(lineRendererCompTrack, rect)
	local lineRendererCompStation = api.gui.comp.LineRenderView.new()
	absLayout:addItem(lineRendererCompStation, rect)
	local lineRendererCompCamera = api.gui.comp.LineRenderView.new()
	absLayout:addItem(lineRendererCompCamera, rect)
	local lineRendererCompEntity = api.gui.comp.LineRenderView.new()
	absLayout:addItem(lineRendererCompEntity, rect)
	lineRendererCompEntity:setWidth(lineSize*2)
	lineRendererCompEntity:setColor(toVec4f({255, 255, 255}))
	function guiState.clearLines() 
		lineRendererCompEntity:clear()
	end 
	function guiState.addLine(entity1, entity2) 
		local p0 = util.v3fromArr(util.getEntity(entity1).position)
		local p1 = util.v3fromArr(util.getEntity(entity2).position)
	
		from.x = xCoord(p0.x)
		from.y = yCoord(p0.y)
		to.x = xCoord(p1.x)
		to.y = yCoord(p1.y)
		lineRendererCompEntity:addLine(from, to)
	end 
	
	local function refreshEdgesAndStations() 
		lineRendererCompTrack:clear()
		lineRendererCompStation:clear()
		lineRendererComp:clear()
		local trackCount = 0
		local roadCount = 0
		local edges ={} 
		local beginSettingUpEdges = os.clock()
		util.lazyCacheNode2SegMaps()
		api.engine.forEachEntityWithComponent(function(entity)
			if not util.isFrozenEdge(entity) then 
				local edge = game.interface.getEntity(entity)
				-- following is inlined for performance
				local dx = edge.node1pos[1]-edge.node0pos[1] 
				local dy = edge.node1pos[2]-edge.node0pos[2]
				if math.sqrt(dx*dx + dy*dy) > 40 then -- avoid short edges, not likely to be visible
					table.insert(edges, edge)
				end
			end 
		end, 
		api.type.ComponentType.BASE_EDGE)
		
		 
		local filterEdges = #edges > maxEdges
		trace("There were ",#edges, "prior to filtering")	
		if filterEdges then 
			local unfilteredEdges = edges 
			local ignoreEdges = {}
			local trackEdgeCount = 0
			edges = {}
			for i, edge in pairs(unfilteredEdges) do 
				if edge.track then 
					trackEdgeCount = trackEdgeCount+1
					if not ignoreEdges[edge.id] then 
						local doubleTrackEdge = util.findDoubleTrackEdge(edge.id)
						if doubleTrackEdge and not ignoreEdges[doubleTrackEdge] then 
							ignoreEdges[doubleTrackEdge]=true 
						end 
						table.insert(edges, edge)
					end 
				else 
					if util.getStreetTypeCategory(edge.id)~="urban" then 
						table.insert(edges, edge)
					end 
				end 
			end 
			trace("The size of ignoredEdges was ",util.size(ignoreEdges)," vs a total of ",trackEdgeCount," track edges")
		end 
		trace("There were ",#edges, "after filtering")	

		for i, edge in pairs(edges) do 
			--trace("The trackCount was ",trackCount," the roadCount was ",roadCount)
		--	local from = api.type.Vec2f.new(xCoord(edge.node0pos[1]), yCoord(edge.node0pos[2]))
			--local to = api.type.Vec2f.new(xCoord(edge.node1pos[1]), yCoord(edge.node1pos[2]))
			from.x = xCoord(edge.node0pos[1])
			from.y = yCoord(edge.node0pos[2])
			to.x = xCoord(edge.node1pos[1])
			to.y = yCoord(edge.node1pos[2])
			if edge.track then 
				trackCount = trackCount + 1 
				if trackCount < maxEdges then 
					lineRendererCompTrack:addLine(from, to)
				end
			else 
				roadCount = roadCount + 1
				if roadCount < maxEdges then 
					lineRendererComp:addLine(from, to)
				end
			end 
			if roadCount >= maxEdges and trackCount >= maxEdges then 
				trace("cutting off as max edges reached")
				break 
			end 
		end
		
		api.engine.forEachEntityWithComponent(function(entity)
			if not util.isFrozenEdge(entity) then 
				local edge = game.interface.getEntity(entity)
				-- following is inlined for performance
				local dx = edge.node1pos[1]-edge.node0pos[1] 
				local dy = edge.node1pos[2]-edge.node0pos[2]
				if math.sqrt(dx*dx + dy*dy) > 40 then -- avoid short edges, not likely to be visible
					table.insert(edges, edge)
				end
			end 
		end, 
		api.type.ComponentType.BASE_EDGE)
		
		
		api.engine.forEachEntityWithComponent(function(entity)
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(entity)
			if constructionId ~= -1 then -- bus/truck stops have no construction
				local construction = util.getConstruction(constructionId)
				local position = util.v3(construction.transf:cols(3))
				local stationParallelTangent = util.v3(construction.transf:cols(1))
				if string.find(construction.fileName,"station/air/") then 
					stationParallelTangent = util.v3(construction.transf:cols(0))
				end 
				local bbox 
				pcall(function() bbox = util.getComponent(constructionId, api.type.ComponentType.BOUNDING_VOLUME) end)
				if not bbox then 
					trace("Unable to find bbox for ",constructionId)
					return 
				end  
				local size = math.max((bbox.bbox.max.x - bbox.bbox.min.x), (bbox.bbox.max.y - bbox.bbox.min.y))-- only approximate but good enough 
				local p0 = position - (size/2) * stationParallelTangent
				local p1 = position + (size/2) * stationParallelTangent
		
				from.x = xCoord(p0.x)
				from.y = yCoord(p0.y)
				to.x = xCoord(p1.x)
				to.y = yCoord(p1.y)
				lineRendererCompStation:addLine(from, to)
			end 
		end, 
		api.type.ComponentType.STATION)
		util.clearCacheNode2SegMaps()
		trace("The count was ", count, " the time to construct was ",(os.clock()-begin), "maxX=",maxX, "maxY=",maxY," minSize=",minSize," setup edges took",(os.clock()-beginSettingUpEdges))
	end
	refreshEdgesAndStations()
	lineRendererComp:setColor(toVec4f(colourKey.road))
	lineRendererComp:setWidth(lineSize)
	lineRendererCompTrack:setColor(toVec4f(colourKey.track))
	lineRendererCompTrack:setWidth(lineSize)
	lineRendererCompStation:setColor(toVec4f(colourKey.station))
	lineRendererCompStation:setWidth(lineSize*2)
	lineRendererCompCamera:setColor(toVec4f(colourKey.camera))
	lineRendererCompCamera:setWidth(lineSize)


	--[[for y = 1, maxY, minSize  do 
		if not ySet[y] then 
			trace("Y is missing at ",y, " priorY=",ySet[y-1]," nextY=",ySet[y+1])
		end
	end ]]--
	local entityComps = {}
	if guiState.displayIndustries or true then 
		api.engine.forEachEntityWithComponent(function(entity)
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(entity)
			local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
			local fileName = construction.fileName
			local pixel = newIcon(getIndustryIcon(fileName)) 
			--local size = pixel:calcMinimumSize()
			--trace("The industryComponent size was",size.w,size.h) -- 25
			--local rect = api.gui.util.Rect.new()
			rect.x = xCoord(construction.transf:cols(3).x) -iconSize
			rect.y = yCoord(construction.transf:cols(3).y)

			rect.w = 0--math.ceil(iconSize/2)
			rect.h = 0--math.ceil(iconSize/2)
			local name = util.getComponent(constructionId, api.type.ComponentType.NAME)
			if name then 
				pixel:setTooltip(_(name.name))
			end
			pixel:insertMouseListener(function(mouseEvent) 
				if mouseEvent.button == 0 and mouseEvent.type == 2 then -- left / clicked  
					if guiState.entitySelectedListener then 
						pcall(function()  guiState.entitySelectedListener(entity) end )
					end
					--pcall(function() api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(entity, false) end )
					return true
				end 
				return false 
			end)
			absLayout:addItem(pixel, rect)
			if not guiState.industryComps then 
				guiState.industryComps = {}
			end 
			if not guiState.industryComps[fileName] then 
				guiState.industryComps[fileName] ={} 
			end 
			table.insert(guiState.industryComps[fileName], pixel)
			entityComps[entity]=pixel
		end, 
		api.type.ComponentType.SIM_BUILDING)
	end
	guiState.townComponents = {}
	api.engine.forEachEntityWithComponent(function(entity)
		local town = game.interface.getEntity(entity)
		--local rect = api.gui.util.Rect.new()
		rect.x = xCoord(town.position[1])-iconSize
		rect.y = yCoord(town.position[2])
		rect.w = iconSize
		rect.h = iconSize
		--stringifyColourStyle(colour)
		local pixel = newIcon("ui/icons/main-menu/map_town@2x.tga") 
	--	local size = pixel:calcMinimumSize()
		--trace("The townComponent size was",size.w,size.h) -- 16
		pixel:setTooltip(_(town.name))
		pixel:insertMouseListener(function(mouseEvent) 
			if mouseEvent.button == 0 and mouseEvent.type == 2 then -- left / clicked  
				if guiState.entitySelectedListener then 
					pcall(function()  guiState.entitySelectedListener(entity) end )
				end
				return true
			end 
			return false 
		end)
		table.insert(guiState.townComponents, pixel)
		absLayout:addItem(pixel, rect)
		entityComps[entity]=pixel
	end, api.type.ComponentType.TOWN)
	
	

	
	guiState.components = {}
	guiState.components.track = lineRendererCompTrack
	guiState.components.road = lineRendererComp 
	guiState.components.station = lineRendererCompStation
	guiState.components.camera = lineRendererCompCamera
	
	local wrap = api.gui.comp.Component.new("")
	wrap:setLayout(absLayout)

	local uiScale = guiState.uiScale

	--local minimumSize = api.gui.util.Size.new(math.ceil((maxX+(invScale/minSize))/uiScale), math.ceil((maxY+(invScale/minSize))/uiScale))
	local minimumSize = api.gui.util.Size.new(math.ceil(maxX/uiScale), math.ceil(maxY/uiScale))
	--local minimumSize = api.gui.util.Size.new(maxX, maxY)
	local sizeFactor = 2
	if extremeRatio then 
		sizeFactor = sizeFactor/1.5
	end
	local maxSize1d = minSize + math.min(math.ceil((maxSize.h /sizeFactor)/uiScale),  math.ceil((maxSize.w /sizeFactor)/uiScale))
	trace("Calculated a size factor of ",maxSize1d," based on ",maxSize.w,maxSize.h, " uiScale=",uiScale ,"maxX=",maxX,"maxY=",maxY, "minimumSize=",minimumSize.w,minimumSize.h)
	local maximumSize = api.gui.util.Size.new(maxSize1d,maxSize1d)

	
	 wrap:setMinimumSize(minimumSize)
	wrap:setGravity(0.5,0.5)

	local scrollArea = api.gui.comp.ScrollArea.new(wrap, "")
	scrollArea:setHorizontalScrollBarPolicy(api.gui.comp.ScrollBarPolicy.AS_NEEDED) -- ALWAYS_OFF, SIMPLE, ALWAYS_ON
	scrollArea:setVerticalScrollBarPolicy(api.gui.comp.ScrollBarPolicy.AS_NEEDED) 
 
	scrollArea:setMaximumSize(maximumSize)
	scrollArea:setMinimumSize(api.gui.util.Size.new(math.min(maxSize1d, minimumSize.w),math.min(maxSize1d, minimumSize.h)))
	
	outerLayout:addItem(scrollArea)
	
	local camera = api.gui.util.getGameUI():getMainRendererComponent():getCameraController()
	local lastCameraData
	local targetLength =   (8*lineSize) / mapScale
	-- Camera view circle scaling (was missing upstream -> "attempt to perform
	-- arithmetic on global 'circleScale'" crash whenever the minimap opened).
	-- circleScale maps camera height (z) to a viewport radius in world units;
	-- min/max clamp the circle to a sane range for any map size.
	local circleScale = 0.5
	local minRadius = 50
	local maxRadius = math.max(mapBoundary.x, mapBoundary.y) / 2
    guiState.connection = scrollArea:onStep(function()
        -- Agent polling enabled with 100ms timeout - polls every 500ms via rate limiting
        local agent = require "ai_builder_agent"
        local success, err = pcall(agent.poll)
        
        if guiState.filter.camera then 
            return 
        end
        local cameraData = camera:getCameraData()
		if lastCameraData and lastCameraData.x == cameraData.x and lastCameraData.y == cameraData.y and lastCameraData.z == cameraData.z then 
			return 
		end
		lastCameraData = cameraData
		
		local camX = cameraData.x 
		local camY = cameraData.y
	
		local radius = math.min(maxRadius, math.max(minRadius, circleScale * cameraData.z))
	
		local num = math.min(128, math.max(8,math.ceil((2*math.pi*radius)/targetLength)))
	
		--trace("refreshing camera, radius was",radius, "num was ",num, " targetLength=",targetLength," minRadius=",minRadius,"maxRadius=", maxRadius)
		lineRendererCompCamera:clear() 
		local priorX 
		local priorY 
		for i = 0, num do
			local a = 2.0 * math.pi * (i - 1) / num
			local x = camX + radius * math.cos(a)
			local y = camY + radius * math.sin(a)  
			if i > 0 then 
				from.x = xCoord(priorX)
				from.y = yCoord(priorY)
				to.x = xCoord(x)
				to.y = yCoord(y)
				lineRendererCompCamera:addLine(from, to)
			end 
			priorX = x 
			priorY = y  
		end
	end)
	scrollArea:setGravity(0.5,0.5)
	guiState.excludeEntities = {}
	function guiState.toggleAllVisibility() 
		--[[if guiState.components then 
			for name, comp in pairs(guiState.components) do 
				comp:setVisible(not guiState.filter[name], true)
			end 
		end ]]--	
		if guiState.industryComps then 
			for name, comps in pairs(guiState.industryComps) do 
				for i, comp in pairs(comps) do 
					comp:setVisible(not guiState.filter["industry"], true)
				end
			end
		end 
		if guiState.townComponents then 
			for i, comp in pairs(guiState.townComponents) do 
				comp:setVisible(not guiState.filter["town"], true)
			end 
		end 
		if guiState.allowedEntities then
			debugPrint({allowedEntities=guiState.allowedEntities})
			for entity, comp in pairs(entityComps) do 
				trace("Checking entity, ",entity," is allowed?",guiState.allowedEntities[entity])
				comp:setVisible(guiState.allowedEntities[entity] or false, true)
			end 
		end 
	end 
	guiState.refreshEdgesAndStations = refreshEdgesAndStations
	--toggleAllVisibility() 
end 

local function buildWindow(button)
	
	
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	local mapView = api.gui.layout.BoxLayout.new("VERTICAL");

	 
	local resolutionLayout  = buildResolutionLayout()
	mapView:addItem(resolutionLayout)
	 
	local mapHolder = api.gui.layout.BoxLayout.new("VERTICAL");
	mapHolder:setGravity(0.5, 0.5)
	mapView:addItem(mapHolder)
 
	local mapWrap = api.gui.comp.Component.new("wrap")
	mapWrap:setLayout(mapView)
	boxLayout:addItem(mapWrap)
	
	local mapKey, topKey, industryKey = buildKey()
	boxLayout:addItem(mapKey)
		
	guiState.refreshMap = function() 
		local begin = os.clock()
		refreshMap(mapHolder) 
		local minSize = mapWrap:calcMinimumSize()
		local minSizeKey = mapKey:calcMinimumSize()
		local newH = math.ceil(minSize.h/guiState.uiScale)
		if minSize.h < minSizeKey.h and minSizeKey.h - minSize.h < 100 then 
			newH = math.ceil(minSizeKey.h/guiState.uiScale)+8 -- grow a little bit to avoid scroll bars
		end 
		
		local topKeySize = topKey:calcMinimumSize()
		local offsetHeight = math.ceil(newH - topKeySize.h/guiState.uiScale)
		local maxSizeKey = api.gui.util.Size.new(minSizeKey.w,offsetHeight)
		industryKey:setMaximumSize(maxSizeKey)
		if util.tracelog then 
			debugPrint({minSize=minSize, minSizeKey = minSizeKey, maxSizeKey=maxSizeKey, topKeySize=topKeySize})
		end 
		trace("Completed minimap refresh in ",(os.clock()-begin))
	end
	
	
    local window = api.gui.comp.Window.new(_('Mini map'), boxLayout)
	
	 window:addHideOnCloseHandler()
	 window:onClose(function() 
	 
		button:setSelected(false, false)
		addWork(function() -- cleanup
				trace("Minimap onClose: Begin")
				guiState.components = nil 
				guiState.industryComps = nil
				guiState.townComponents = nil
				if guiState.connection then 
					trace("Disconnecting") 
					guiState.connection:disconnect()
				end 
				guiState.connection = nil
				for i =  mapHolder:getNumItems(), 1, -1 do 
					trace("Minimap onClose: Removing item at i=",i)
					local item = mapHolder:getItem(i-1)
					mapHolder:removeItem(item)
					item:destroy()
				end
				trace("Minimap onClose: Complete, luaUsedMemory=",math.ceil(api.util.getLuaUsedMemory()/1024))
			end) 
	 end)


	return {
		window = window,
		refresh = function() 

			
			guiState.refreshMap()
		end 
	}
end

function minimap.cleanup(outerLayout, guiState)
	guiState.components = nil 
	guiState.industryComps = nil
	guiState.townComponents = nil
	if guiState.connection then 
		trace("Disconnecting") 
		guiState.connection:disconnect()
	end 
	guiState.connection = nil
	for i =  outerLayout:getNumItems(), 1, -1 do 
		trace("Minimap onClose: Removing item at i=",i)
		local item = outerLayout:getItem(i-1)
		outerLayout:removeItem(item)
		item:destroy()
	end
end
function minimap.setup(outerLayout, guiState)
	local appConfig = api.util.getAppConfig()
	if appConfig.uiAutoScaling then 
		if not guiState.uiScale then 
			local dummyText =api.gui.comp.TextView.new("TEST")
			local originalSize = dummyText:calcMinimumSize()  
			outerLayout:addItem(dummyText)
			local newSize = dummyText:calcMinimumSize()
			outerLayout:removeItem(dummyText)
			dummyText:destroy() 
			guiState.uiScale = math.floor(4*((( newSize.h / originalSize.h)+( newSize.w / originalSize.w)) / 2)+0.5)/4
			trace("THe calculated ui scales based on h/w were",( newSize.h / originalSize.h),( newSize.w / originalSize.w), " uiScale=",guiState.uiScale)
		end
	else 
		guiState.uiScale = appConfig.uiScaling 
	end  
end

function minimap.buildMap(outerLayout, guiState)
	minimap.setup(outerLayout, guiState)
	minimap.refreshMap(outerLayout, guiState)
end

function minimap.setVisibilityListener(window, outerLayout, guiState)
	local originalSize = window:calcMinimumSize()
	window:onVisibilityChange(function(isVisible) 
		trace("Inside minimap onVisibilityChange:",isVisible)
		minimap.addWork( -- need to wait for the next UI step to actually calculate ui scale
			function() 
				if isVisible then  
					minimap.buildMap(outerLayout, guiState)
				else 
					minimap.cleanup(outerLayout, guiState)
				end
			end)
	end)
end 



return minimap