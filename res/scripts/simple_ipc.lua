--[[
    Simple File-Based IPC for TF2

    Direct communication with Python agents.
    No sockets, no daemon - just two files.

    Files:
      /tmp/tf2_cmd.json  - Commands FROM Python (we read)
      /tmp/tf2_resp.json - Responses TO Python (we write)

    Protocol:
      1. Poll command file for new commands
      2. If command found, execute it and write response
      3. Clear command file after processing
]]

local M = {}

-- DEFAULT 4X ONCE: set 4x when the mod first initializes, then respect the
-- player's own speed changes (pause/slow/fast) afterwards.
local speedInitDone = false
local function ensureDefaultSpeed4x()
    if speedInitDone then return end
    if api and api.cmd and game and game.interface and game.interface.setGameSpeed then
        speedInitDone = true
        pcall(function()
            api.cmd.sendCommand(api.cmd.make.setGameSpeed(4))
        end)
        log("DEFAULT_SPEED: initialized to 4x once; player speed changes now respected")
    end
end

-- File paths
local CMD_FILE = "/tmp/tf2_cmd.json"
local RESP_FILE = "/tmp/tf2_resp.json"
local LOG_FILE = "/tmp/tf2_simple_ipc.log"

-- State
local last_cmd_id = nil
local json = nil

-- Snapshot storage for state diffing
local snapshots = {}

-- Logging
local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

-- Get JSON encoder/decoder
local function get_json()
    if json then return json end
    local ok, mod = pcall(require, "json")
    if ok then json = mod end
    return json
end

-- Write response (direct write since os.rename may not be available in sandbox)
local function write_response(resp)
    local j = get_json()
    if not j then
        log("ERROR: No JSON encoder")
        return false
    end

    -- Safely encode to JSON
    local encode_ok, content = pcall(j.encode, resp)
    if not encode_ok then
        log("ERROR: JSON encode failed: " .. tostring(content))
        return false
    end

    -- Write directly to response file
    local f, err = io.open(RESP_FILE, "w")
    if not f then
        log("ERROR: Cannot open " .. RESP_FILE .. ": " .. tostring(err))
        return false
    end

    local write_ok, write_err = pcall(function()
        f:write(content)
        f:close()
    end)
    if not write_ok then
        log("ERROR: Write failed: " .. tostring(write_err))
        pcall(f.close, f)
        return false
    end

    log("RESP: " .. content:sub(1, 100))
    return true
end

-- Clear command file
local function clear_command()
    os.remove(CMD_FILE)
end

-- Command handlers
local handlers = {}

handlers.ping = function(params)
    return {status = "ok", data = "pong"}
end

handlers.query_game_state = function(params)
    local state = {}

    -- Use game.interface methods (more reliable than api.engine in game script context)
    local gameTime = game.interface.getGameTime()
    if gameTime and gameTime.date then
        state.year = tostring(gameTime.date.year or 1850)
        state.month = tostring(gameTime.date.month or 1)
        state.day = tostring(gameTime.date.day or 1)
    else
        state.year = "1850"
        state.month = "1"
        state.day = "1"
    end

    -- Get money via game.interface
    local player = game.interface.getPlayer()
    if player then
        local playerEntity = game.interface.getEntity(player)
        state.money = tostring(playerEntity and playerEntity.balance or 0)
    else
        state.money = "0"
    end

    -- Get game speed
    state.speed = tostring(game.interface.getGameSpeed() or 1)
    state.paused = game.interface.getGameSpeed() == 0 and "true" or "false"

    return {status = "ok", data = state}
end

handlers.query_towns = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local towns = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    for id, town in pairs(entities) do
        local pop = "0"
        if town.counts and town.counts.population then
            pop = tostring(town.counts.population)
        end
        table.insert(towns, {
            id = tostring(id),
            name = town.name or "Unknown",
            population = pop
        })
    end

    return {status = "ok", data = {towns = towns}}
end

-- Query buildings in a town with their positions and ACTUAL cargo demands
handlers.query_town_buildings = function(params)
    if not params or not params.town_id then
        return {status = "error", message = "Need town_id parameter"}
    end

    local town_id = tonumber(params.town_id)
    if not town_id then
        return {status = "error", message = "Invalid town_id"}
    end

    local buildings = {}
    local commercial = {}
    local residential = {}

    -- Get ACTUAL cargo demands from the game using getTownCargoSupplyAndLimit
    local cargoDemandsMap = {}  -- cargo -> {supply, limit, demand}
    local cargoDemandsStr = ""
    local ok, cargoSupplyAndLimit = pcall(function()
        return game.interface.getTownCargoSupplyAndLimit(town_id)
    end)

    if ok and cargoSupplyAndLimit then
        for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
            local supply = supplyAndLimit[1] or 0
            local limit = supplyAndLimit[2] or 0
            local demand = math.max(0, limit - supply)
            if demand > 0 then
                cargoDemandsMap[cargoName] = {
                    supply = supply,
                    limit = limit,
                    demand = demand
                }
                if cargoDemandsStr ~= "" then cargoDemandsStr = cargoDemandsStr .. ", " end
                cargoDemandsStr = cargoDemandsStr .. cargoName
            end
        end
    end

    -- Get town buildings
    local townBuildingMap = api.engine.system.townBuildingSystem.getTown2BuildingMap()
    local townBuildings = townBuildingMap[town_id] or {}

    log("QUERY_TOWN_BUILDINGS: town_id=" .. town_id .. " buildings=" .. #townBuildings .. " cargo_demands=" .. cargoDemandsStr)

    -- Calculate town center and categorize buildings
    local sumX, sumY, count = 0, 0, 0
    local buildingCargoTypes = {}  -- Track cargo types per building

    for i, buildingId in pairs(townBuildings) do
        local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(buildingId)
        local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil
        local buildingEntity = game.interface.getEntity(buildingId)

        -- Try to get cargo types this building consumes
        local buildingCargo = {}
        local ok2, constructionComp = pcall(function()
            return api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
        end)
        if ok2 and constructionComp and constructionComp.params and constructionComp.params.cargoTypes then
            for _, cargoType in ipairs(constructionComp.params.cargoTypes) do
                table.insert(buildingCargo, cargoType)
            end
        end

        if buildingEntity or construction then
            local position = (buildingEntity and buildingEntity.position) or (construction and construction.position) or nil

            if position then
                local x = position[1] or 0
                local y = position[2] or 0
                sumX = sumX + x
                sumY = sumY + y
                count = count + 1

                -- Categorize building by type
                local fileName = construction and construction.fileName or ""
                local buildingInfo = {
                    id = tostring(buildingId),
                    x = tostring(math.floor(x)),
                    y = tostring(math.floor(y)),
                    cargo_types = table.concat(buildingCargo, ",")
                }

                if fileName:find("commercial") or fileName:find("shop") or fileName:find("store") then
                    table.insert(commercial, buildingInfo)
                elseif fileName:find("residential") or fileName:find("house") then
                    table.insert(residential, buildingInfo)
                end
            end
        end
    end

    local town = game.interface.getEntity(town_id)
    local townPos = town and town.position or {0, 0, 0}

    -- Build detailed cargo demand info
    local cargoDetails = {}
    for cargoName, info in pairs(cargoDemandsMap) do
        table.insert(cargoDetails, cargoName .. ":" .. tostring(info.demand) .. "/" .. tostring(info.limit))
    end

    return {status = "ok", data = {
        town_id = tostring(town_id),
        town_name = town and town.name or "Unknown",
        building_count = tostring(#townBuildings),
        town_center_x = tostring(math.floor(townPos[1] or (count > 0 and sumX/count or 0))),
        town_center_y = tostring(math.floor(townPos[2] or (count > 0 and sumY/count or 0))),
        commercial_count = tostring(#commercial),
        residential_count = tostring(#residential),
        cargo_demands = cargoDemandsStr,  -- ACTUAL cargo demands (e.g., "FOOD, GOODS")
        cargo_details = table.concat(cargoDetails, "; ")  -- demand/limit per cargo
    }}
end

-- Query ALL towns with their ACTUAL cargo demands - for Claude to evaluate routing targets
handlers.query_town_demands = function(params)
    local towns = {}
    local allTowns = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    for townId, town in pairs(allTowns) do
        -- Get ACTUAL cargo demands using game API
        local cargoDemandsMap = {}
        local cargoDemandsStr = ""
        local ok, cargoSupplyAndLimit = pcall(function()
            return game.interface.getTownCargoSupplyAndLimit(townId)
        end)

        if ok and cargoSupplyAndLimit then
            for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
                local supply = supplyAndLimit[1] or 0
                local limit = supplyAndLimit[2] or 0
                local demand = math.max(0, limit - supply)
                if demand > 0 then
                    cargoDemandsMap[cargoName] = demand
                    if cargoDemandsStr ~= "" then cargoDemandsStr = cargoDemandsStr .. ", " end
                    cargoDemandsStr = cargoDemandsStr .. cargoName .. ":" .. tostring(demand)
                end
            end
        end

        local townPos = town.position or {0, 0, 0}

        -- Get building counts
        local townBuildingMap = api.engine.system.townBuildingSystem.getTown2BuildingMap()
        local townBuildings = townBuildingMap[townId] or {}

        table.insert(towns, {
            id = tostring(townId),
            name = town.name or "Unknown",
            x = tostring(math.floor(townPos[1] or 0)),
            y = tostring(math.floor(townPos[2] or 0)),
            population = tostring(town.population or 0),
            building_count = tostring(#townBuildings),
            cargo_demands = cargoDemandsStr  -- ACTUAL demands: "FOOD:50, GOODS:30" or empty if none
        })
    end

    log("QUERY_TOWN_DEMANDS: found " .. #towns .. " towns")
    return {status = "ok", data = {towns = towns}}
end

handlers.query_industries = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local industries = {}
    -- Get all SIM_BUILDING entities (industries) - this is what AI Builder uses
    local entities = game.interface.getEntities({radius=1e9}, {type="SIM_BUILDING", includeData=true})

    for id, industry in pairs(entities) do
        -- Industries have itemsProduced/itemsConsumed
        if industry.itemsProduced or industry.itemsConsumed then
            -- Get the construction for name/position info
            local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(id)
            local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil

            local name = industry.name or (construction and construction.name) or "Industry"
            local position = industry.position or (construction and construction.position) or {0, 0, 0}
            local fileName = construction and construction.fileName or ""

            table.insert(industries, {
                id = tostring(id),
                name = name,
                type = fileName:match("industry/(.-)%.") or "unknown",
                x = tostring(math.floor(position[1] or 0)),
                y = tostring(math.floor(position[2] or 0))
            })
        end
    end

    return {status = "ok", data = {industries = industries}}
end

handlers.query_lines = function(params)
    local util = require "ai_builder_base_util"
    local lines = {}

    -- Use line system API to get all lines
    local lineIds = api.engine.system.lineSystem.getLines()

    for i, lineId in pairs(lineIds) do
        local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
        local lineData = util.getComponent(lineId, api.type.ComponentType.LINE)
        local lineEntity = util.getEntity(lineId)

        -- Get frequency/rate data
        local rate = lineEntity and lineEntity.rate or 0
        local frequency = lineEntity and lineEntity.frequency or 0

        -- Calculate interval between vehicles (if we have vehicles)
        local interval = 0
        if #vehicles > 0 and frequency > 0 then
            interval = 1 / frequency  -- frequency is vehicles per second
        end

        table.insert(lines, {
            id = tostring(lineId),
            name = naming and naming.name or ("Line " .. lineId),
            vehicle_count = tostring(#vehicles),
            stop_count = tostring(lineData and #lineData.stops or 0),
            rate = tostring(rate),
            frequency = tostring(frequency),
            interval = tostring(math.floor(interval))  -- seconds between vehicles
        })
    end

    return {status = "ok", data = {lines = lines}}
end

-- Trigger AI Builder to optimize a line's vehicle count
handlers.optimize_line_vehicles = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Missing line_id parameter"}
    end

    local lineId = tonumber(params.line_id)
    if not lineId then
        return {status = "error", message = "Invalid line_id"}
    end

    log("OPTIMIZE_VEHICLES: Triggering AI Builder optimization for line " .. lineId)

    -- Queue the line for AI Builder's regular optimization cycle
    -- The AI Builder will check and add vehicles if needed during its next tick
    local ok, err = pcall(function()
        local lineManager = require "ai_builder_line_manager"
        -- Add to high priority queue for next evaluation
        if lineManager.addLineToEvaluationQueue then
            lineManager.addLineToEvaluationQueue(lineId, "HIGH")
        end
    end)

    if not ok then
        log("OPTIMIZE_VEHICLES: " .. tostring(err) .. " - AI Builder will handle naturally")
    end

    return {status = "ok", data = {line_id = lineId, action = "queued_for_optimization"}}
end

handlers.query_vehicles = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local vehicles = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="VEHICLE", includeData=true})

    for id, vehicle in pairs(entities) do
        table.insert(vehicles, {
            id = tostring(id),
            line = tostring(vehicle.line or -1)
        })
    end

    return {status = "ok", data = {vehicles = vehicles}}
end

handlers.query_stations = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local stations = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="STATION", includeData=true})

    for id, station in pairs(entities) do
        table.insert(stations, {
            id = tostring(id),
            name = station.name or "Station"
        })
    end

    return {status = "ok", data = {stations = stations}}
end

-- Snapshot state for later diffing
handlers.snapshot_state = function(params)
    local util = require "ai_builder_base_util"

    -- Generate unique snapshot ID
    local snapshot_id = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))

    -- Capture current state
    local snapshot = {
        timestamp = os.time(),
        game_state = {},
        lines = {},
        vehicles = {},
        money = "0"
    }

    -- Get game state
    local gameTime = game.interface.getGameTime()
    if gameTime and gameTime.date then
        snapshot.game_state.year = tostring(gameTime.date.year or 1850)
        snapshot.game_state.month = tostring(gameTime.date.month or 1)
    end

    -- Get money
    local player = game.interface.getPlayer()
    if player then
        local playerEntity = game.interface.getEntity(player)
        snapshot.money = tostring(playerEntity and playerEntity.balance or 0)
    end

    -- Get lines
    local lineIds = api.engine.system.lineSystem.getLines()
    for i, lineId in pairs(lineIds) do
        local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
        local lineData = util.getComponent(lineId, api.type.ComponentType.LINE)

        snapshot.lines[tostring(lineId)] = {
            id = tostring(lineId),
            name = naming and naming.name or ("Line " .. lineId),
            vehicle_count = #vehicles,
            stop_count = lineData and #lineData.stops or 0
        }
    end

    -- Get vehicles
    local vehicleEntities = game.interface.getEntities({radius=1e9}, {type="VEHICLE", includeData=true})
    for id, vehicle in pairs(vehicleEntities) do
        snapshot.vehicles[tostring(id)] = {
            id = tostring(id),
            line = tostring(vehicle.line or -1)
        }
    end

    -- Store snapshot
    snapshots[snapshot_id] = snapshot

    -- Clean up old snapshots (keep only last 10)
    local snapshotIds = {}
    for id, _ in pairs(snapshots) do
        table.insert(snapshotIds, id)
    end
    table.sort(snapshotIds)
    while #snapshotIds > 10 do
        local oldId = table.remove(snapshotIds, 1)
        snapshots[oldId] = nil
    end

    log("SNAPSHOT: Created " .. snapshot_id .. " with " .. #lineIds .. " lines")

    return {
        status = "ok",
        data = {
            snapshot_id = snapshot_id,
            lines_count = #lineIds,
            vehicles_count = util.tableSize and util.tableSize(vehicleEntities) or 0
        }
    }
end

-- Diff current state against a snapshot
handlers.diff_state = function(params)
    if not params or not params.snapshot_id then
        return {status = "error", message = "Missing snapshot_id parameter"}
    end

    local snapshot_id = params.snapshot_id
    local snapshot = snapshots[snapshot_id]

    if not snapshot then
        return {status = "error", message = "Snapshot not found: " .. snapshot_id}
    end

    local util = require "ai_builder_base_util"

    -- Get current state
    local current_lines = {}
    local current_vehicles = {}
    local current_money = "0"

    -- Get money
    local player = game.interface.getPlayer()
    if player then
        local playerEntity = game.interface.getEntity(player)
        current_money = tostring(playerEntity and playerEntity.balance or 0)
    end

    -- Get current lines
    local lineIds = api.engine.system.lineSystem.getLines()
    for i, lineId in pairs(lineIds) do
        local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
        local lineData = util.getComponent(lineId, api.type.ComponentType.LINE)

        current_lines[tostring(lineId)] = {
            id = tostring(lineId),
            name = naming and naming.name or ("Line " .. lineId),
            vehicle_count = #vehicles,
            stop_count = lineData and #lineData.stops or 0,
            type = lineData and lineData.stops and lineData.stops[1] and "ROAD" or "UNKNOWN"
        }
    end

    -- Get current vehicles
    local vehicleEntities = game.interface.getEntities({radius=1e9}, {type="VEHICLE", includeData=true})
    for id, vehicle in pairs(vehicleEntities) do
        current_vehicles[tostring(id)] = {
            id = tostring(id),
            line = tostring(vehicle.line or -1)
        }
    end

    -- Calculate diff
    local diff = {
        added = {lines = {}, vehicles = {}},
        removed = {lines = {}, vehicles = {}},
        changed = {lines = {}, money = nil}
    }

    -- Find added and changed lines
    for lineId, line in pairs(current_lines) do
        if not snapshot.lines[lineId] then
            table.insert(diff.added.lines, line)
            log("DIFF: Added line " .. lineId .. " (" .. line.name .. ")")
        elseif snapshot.lines[lineId].vehicle_count ~= line.vehicle_count then
            table.insert(diff.changed.lines, {
                id = lineId,
                name = line.name,
                old_vehicles = snapshot.lines[lineId].vehicle_count,
                new_vehicles = line.vehicle_count
            })
        end
    end

    -- Find removed lines
    for lineId, line in pairs(snapshot.lines) do
        if not current_lines[lineId] then
            table.insert(diff.removed.lines, line)
            log("DIFF: Removed line " .. lineId)
        end
    end

    -- Find added vehicles
    for vehicleId, vehicle in pairs(current_vehicles) do
        if not snapshot.vehicles[vehicleId] then
            table.insert(diff.added.vehicles, vehicle)
        end
    end

    -- Find removed vehicles
    for vehicleId, vehicle in pairs(snapshot.vehicles) do
        if not current_vehicles[vehicleId] then
            table.insert(diff.removed.vehicles, vehicle)
        end
    end

    -- Money change
    local old_money = tonumber(snapshot.money) or 0
    local new_money = tonumber(current_money) or 0
    if old_money ~= new_money then
        diff.changed.money = {
            old = tostring(old_money),
            new = tostring(new_money),
            delta = tostring(new_money - old_money)
        }
    end

    log("DIFF: " .. #diff.added.lines .. " lines added, " .. #diff.added.vehicles .. " vehicles added")

    return {
        status = "ok",
        data = {
            snapshot_id = snapshot_id,
            diff = diff,
            summary = {
                lines_added = #diff.added.lines,
                lines_removed = #diff.removed.lines,
                lines_changed = #diff.changed.lines,
                vehicles_added = #diff.added.vehicles,
                vehicles_removed = #diff.removed.vehicles
            }
        }
    }
end

handlers.pause = function(params)
    api.cmd.sendCommand(api.cmd.make.setGameSpeed(0))
    return {status = "ok"}
end

handlers.resume = function(params)
    api.cmd.sendCommand(api.cmd.make.setGameSpeed(4))
    return {status = "ok"}
end

handlers.set_speed = function(params)
    local s = tonumber(params and params.speed) or 4
    s = math.max(0, math.min(4, s))
    log("SET_SPEED: setting to " .. tostring(s))
    api.cmd.sendCommand(api.cmd.make.setGameSpeed(s))
    return {status = "ok", data = {speed = tostring(s)}}
end

-- Query terrain height at a position (water is below 0)
handlers.query_terrain_height = function(params)
    local x = tonumber(params and params.x) or 0
    local y = tonumber(params and params.y) or 0

    local vec2f = api.type.Vec2f.new(x, y)

    if not api.engine.terrain.isValidCoordinate(vec2f) then
        return {status = "error", message = "Invalid coordinates"}
    end

    local baseHeight = api.engine.terrain.getBaseHeightAt(vec2f)
    local currentHeight = api.engine.terrain.getHeightAt(vec2f)
    -- Water level is typically 0 in TF2
    local waterLevel = 0
    local isWater = baseHeight < waterLevel

    return {
        status = "ok",
        data = {
            x = tostring(x),
            y = tostring(y),
            base_height = tostring(baseHeight),
            current_height = tostring(currentHeight),
            water_level = tostring(waterLevel),
            is_water = isWater and "true" or "false"
        }
    }
end

-- Check if water path exists between two points (samples terrain along line)
handlers.check_water_path = function(params)
    local x1 = tonumber(params and params.x1) or 0
    local y1 = tonumber(params and params.y1) or 0
    local x2 = tonumber(params and params.x2) or 0
    local y2 = tonumber(params and params.y2) or 0
    local samples = tonumber(params and params.samples) or 20

    -- Water level is typically 0 in TF2
    local waterLevel = 0
    local waterPoints = 0
    local landPoints = 0
    local heights = {}

    for i = 0, samples do
        local t = i / samples
        local x = x1 + (x2 - x1) * t
        local y = y1 + (y2 - y1) * t
        local vec2f = api.type.Vec2f.new(x, y)

        if api.engine.terrain.isValidCoordinate(vec2f) then
            local h = api.engine.terrain.getBaseHeightAt(vec2f)
            table.insert(heights, h)
            if h < waterLevel then
                waterPoints = waterPoints + 1
            else
                landPoints = landPoints + 1
            end
        end
    end

    -- Consider water path viable if >70% of samples are water
    local waterRatio = waterPoints / (waterPoints + landPoints)
    local hasWaterPath = waterRatio > 0.7

    -- Also check endpoints - both should be near water for ship access
    local start_vec = api.type.Vec2f.new(x1, y1)
    local end_vec = api.type.Vec2f.new(x2, y2)
    local startNearWater = false
    local endNearWater = false

    -- Check 500m radius around start for water
    for dx = -500, 500, 100 do
        for dy = -500, 500, 100 do
            local check_vec = api.type.Vec2f.new(x1 + dx, y1 + dy)
            if api.engine.terrain.isValidCoordinate(check_vec) then
                if api.engine.terrain.getBaseHeightAt(check_vec) < waterLevel then
                    startNearWater = true
                    break
                end
            end
        end
        if startNearWater then break end
    end

    for dx = -500, 500, 100 do
        for dy = -500, 500, 100 do
            local check_vec = api.type.Vec2f.new(x2 + dx, y2 + dy)
            if api.engine.terrain.isValidCoordinate(check_vec) then
                if api.engine.terrain.getBaseHeightAt(check_vec) < waterLevel then
                    endNearWater = true
                    break
                end
            end
        end
        if endNearWater then break end
    end

    return {
        status = "ok",
        data = {
            water_points = tostring(waterPoints),
            land_points = tostring(landPoints),
            water_ratio = tostring(waterRatio),
            has_water_path = hasWaterPath and "true" or "false",
            start_near_water = startNearWater and "true" or "false",
            end_near_water = endNearWater and "true" or "false",
            ship_viable = (hasWaterPath and startNearWater and endNearWater) and "true" or "false"
        }
    }
end

handlers.add_money = function(params)
    local amount = tonumber(params and params.amount) or 50000000
    log("ADD_MONEY: Adding " .. tostring(amount))
    -- Use setBalance to add money to the player
    local playerEntity = game.interface.getEntity(game.interface.getPlayer())
    local newBalance = (playerEntity and playerEntity.balance or 0) + amount
    api.cmd.sendCommand(api.cmd.make.setBalance(newBalance))
    return {status = "ok", data = {added = amount, new_balance = newBalance}}
end

handlers.build_road = function(params)
    log("BUILD_ROAD: === START ===")
    log("BUILD_ROAD: params.cargo=" .. tostring(params and params.cargo or "nil"))
    
    local cargo = params and params.cargo or nil
    log("BUILD_ROAD: cargo extracted=" .. tostring(cargo))
    
    local opts = {ignoreErrors = false}
    if cargo then 
        opts.cargoFilter = cargo 
        log("BUILD_ROAD: cargoFilter set to " .. cargo)
    else
        log("BUILD_ROAD: WARNING - no cargo filter, will use AI Builder default")
    end

    if not api or not api.cmd then
        log("BUILD_ROAD: ERROR - api.cmd not available")
        return {status = "error", message = "api.cmd not available"}
    end

    log("BUILD_ROAD: Sending sendScriptEvent with opts.cargoFilter=" .. tostring(opts.cargoFilter))
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildNewIndustryRoadConnection",
            "",
            opts
        ))
    end)

    if not ok then
        log("BUILD_ROAD: ERROR - " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_ROAD: === SUCCESS - event sent with cargoFilter=" .. tostring(opts.cargoFilter) .. " ===")
    return {status = "ok", data = "build_started", cargo = cargo}
end

-- Build a connection between two specific industries using evaluation (recommended)
-- This runs the AI Builder's evaluation with preSelectedPair, ensuring all required
-- data is populated correctly before building.
handlers.build_industry_connection = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Missing industry1_id or industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_INDUSTRY_CONNECTION: " .. ind1_id .. " -> " .. ind2_id)

    -- Check if api is available
    if not api or not api.cmd then
        log("ERROR: api.cmd not available in this context")
        return {status = "error", message = "api.cmd not available"}
    end

    -- Send event with preSelectedPair to run evaluation then build
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildIndustryRoadConnectionEval",
            "",
            {
                preSelectedPair = {ind1_id, ind2_id},
                ignoreErrors = false
            }
        ))
    end)

    if not ok then
        log("BUILD_INDUSTRY_CONNECTION ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_INDUSTRY_CONNECTION: Script event sent")
    return {status = "ok", data = {industry1_id = ind1_id, industry2_id = ind2_id}}
end

-- Build a connection between two specific industries (bypasses AI Builder's evaluation)
handlers.build_connection = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Missing industry1_id or industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_CONNECTION: Getting industry entities " .. ind1_id .. " -> " .. ind2_id)

    -- Get industry entities from game
    local ind1 = game.interface.getEntity(ind1_id)
    local ind2 = game.interface.getEntity(ind2_id)

    if not ind1 then
        return {status = "error", message = "Industry 1 not found: " .. ind1_id}
    end
    if not ind2 then
        return {status = "error", message = "Industry 2 not found: " .. ind2_id}
    end

    -- Add IDs to entities
    ind1.id = ind1_id
    ind2.id = ind2_id

    log("BUILD_CONNECTION: Found industries: " .. tostring(ind1.name) .. " -> " .. tostring(ind2.name))

    -- Get positions for p0 and p1 (required by getTruckStationsToBuild)
    -- Convert from array format {1=x, 2=y, 3=z} to object format {x=..., y=..., z=...}
    local function posToVec3(pos)
        if not pos then return nil end
        return {
            x = pos[1] or pos.x or 0,
            y = pos[2] or pos.y or 0,
            z = pos[3] or pos.z or 0
        }
    end
    local p0 = posToVec3(ind1.position)
    local p1 = posToVec3(ind2.position)
    log("BUILD_CONNECTION: p0=(" .. tostring(p0.x) .. "," .. tostring(p0.y) .. "," .. tostring(p0.z) .. ")")
    log("BUILD_CONNECTION: p1=(" .. tostring(p1.x) .. "," .. tostring(p1.y) .. "," .. tostring(p1.z) .. ")")

    -- Determine transport type
    local transport_type = params.transport_type or "road"
    local carrier = api.type.enum.Carrier.ROAD
    local event_name = "buildNewIndustryRoadConnection"

    if transport_type == "rail" then
        carrier = api.type.enum.Carrier.RAIL
        event_name = "buildIndustryRailConnection"
    elseif transport_type == "water" or transport_type == "ship" then
        carrier = api.type.enum.Carrier.WATER
        event_name = "buildNewWaterConnection"
    end

    log("BUILD_CONNECTION: transport_type=" .. transport_type .. " carrier=" .. tostring(carrier))

    -- Create result object for AI Builder
    local result = {
        industry1 = ind1,
        industry2 = ind2,
        carrier = carrier,
        cargoType = params.cargo or nil,
        -- Required position vectors
        p0 = p0,
        p1 = p1,
        -- Other fields that may be needed
        isTown = false,
        needsNewRoute = true,
        isAutoBuildMode = true
    }

    -- Send to AI Builder with the pre-built result
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            event_name,
            "",
            {ignoreErrors = false, result = result, preSelectedPair = {ind1_id, ind2_id}}
        ))
    end)

    if not ok then
        log("BUILD_CONNECTION ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_CONNECTION: Script event sent with result")
    return {status = "ok", data = {industry1 = ind1.name, industry2 = ind2.name}}
end

handlers.enable_auto_build = function(params)
    -- Enable AI Builder's auto-build options
    local options = {
        autoEnableTruckFreight = true,
        autoEnableLineManager = true,
    }

    -- Add optional settings from params
    if params then
        if params.trucks ~= nil then options.autoEnableTruckFreight = params.trucks end
        if params.trains ~= nil then options.autoEnableFreightTrains = params.trains end
        if params.buses ~= nil then options.autoEnableIntercityBus = params.buses end
        if params.ships ~= nil then options.autoEnableShipFreight = params.ships end
        if params.full ~= nil then options.autoEnableFullManagement = params.full end
    end

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script",
        "aiEnableOptions",
        "",
        {aiEnableOptions = options}
    ))
    return {status = "ok", data = options}
end

handlers.disable_auto_build = function(params)
    -- Disable ALL AI Builder auto-build options
    local options = {
        autoEnablePassengerTrains = false,
        autoEnableFreightTrains = false,
        autoEnableTruckFreight = false,
        autoEnableIntercityBus = false,
        autoEnableShipFreight = false,
        autoEnableShipPassengers = false,
        autoEnableAirPassengers = false,
        autoEnableLineManager = false,
        autoEnableHighwayBuilder = false,
        autoEnableAirFreight = false,
        autoEnableFullManagement = false,
        autoEnableExpandingBusCoverage = false,
        autoEnableExpandingCargoCoverage = false,
    }

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script",
        "aiEnableOptions",
        "",
        {aiEnableOptions = options}
    ))
    return {status = "ok", data = {message = "All auto-build options disabled", options = options}}
end

-- Build cargo delivery route from industry to town
-- Completes supply chains by delivering final products (FOOD, TOOLS, etc.) to towns
handlers.build_cargo_to_town = function(params)
    if not params or not params.industry_id or not params.town_id then
        return {status = "error", message = "Need industry_id and town_id"}
    end

    local ind_id = tonumber(params.industry_id)
    local town_id = tonumber(params.town_id)

    if not ind_id or not town_id then
        return {status = "error", message = "Invalid IDs (must be numbers)"}
    end

    log("BUILD_CARGO_TO_TOWN: " .. ind_id .. " -> town " .. town_id)

    -- Get source industry
    local industry = game.interface.getEntity(ind_id)
    if not industry then
        return {status = "error", message = "Industry not found: " .. ind_id}
    end

    -- Get town
    local town = game.interface.getEntity(town_id)
    if not town then
        return {status = "error", message = "Town not found: " .. town_id}
    end

    log("BUILD_CARGO_TO_TOWN: " .. industry.name .. " -> " .. town.name)

    -- Create the evaluation parameters with preSelectedPair
    -- The AI Builder handles TOWN as second entity specially
    local evalParams = {
        preSelectedPair = {ind_id, town_id},
        maxDist = 1e9,  -- Allow any distance (Claude already validated)
        cargoFilter = params.cargo or nil,  -- Optional cargo filter
        isTownDelivery = true
    }

    -- Send to AI Builder for town delivery build
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildCargoToTown",  -- New event handler needed in ai_builder_script
            "",
            evalParams
        ))
    end)

    if not ok then
        log("BUILD_CARGO_TO_TOWN ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_CARGO_TO_TOWN: Event sent for " .. industry.name .. " -> " .. town.name)
    return {status = "ok", data = {
        industry = industry.name,
        town = town.name,
        cargo = params.cargo
    }}
end

-- Build intra-city bus network for a town
handlers.build_town_bus = function(params)
    if not params or not params.town_id then
        return {status = "error", message = "Need town_id"}
    end

    local town_id = tonumber(params.town_id)
    if not town_id then
        return {status = "error", message = "Invalid town_id (must be number)"}
    end

    log("BUILD_TOWN_BUS: town " .. town_id)

    -- Send event to build town bus network
    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildNewTownBusStop", "", {town = town_id}))

    return {status = "ok", data = {
        message = "Town bus network build triggered",
        town_id = tostring(town_id)
    }}
end

-- Build a multi-stop route - bypasses AI Builder evaluation
-- Uses DAG-indicated industries directly
handlers.build_multistop_route = function(params)
    if not params or not params.industry_ids or #params.industry_ids < 2 then
        return {status = "error", message = "Need industry_ids array with at least 2 IDs"}
    end

    log("BUILD_MULTISTOP: " .. #params.industry_ids .. " stops")

    -- Get all industry entities
    local industries = {}
    local names = {}
    for i, id_str in ipairs(params.industry_ids) do
        local ind_id = tonumber(id_str)
        if not ind_id then
            return {status = "error", message = "Invalid ID at position " .. i}
        end

        local ind = game.interface.getEntity(ind_id)
        if not ind then
            return {status = "error", message = "Industry not found: " .. ind_id}
        end

        -- Add required fields for buildMultiStopCargoRoute
        ind.id = ind_id
        ind.type = "INDUSTRY"
        table.insert(industries, ind)
        table.insert(names, ind.name)
        log("BUILD_MULTISTOP: Stop " .. i .. ": " .. ind.name .. " (ID " .. ind_id .. ")")
    end

    -- Build the route directly - NO EVALUATION
    local event_params = {
        industries = industries,
        lineName = params.line_name or "DAG Route",
        defaultCargoType = params.cargo or "COAL",
        transportMode = params.transport_mode or "ROAD",  -- "ROAD" or "RAIL"
        targetRate = params.target_rate or 100
    }

    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildMultiStopCargoRoute",
            "",
            event_params
        ))
    end)

    if not ok then
        log("BUILD_MULTISTOP ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_MULTISTOP: Event sent for " .. #industries .. " stops")
    return {status = "ok", data = {
        industries = names,
        mode = params.transport_mode or "ROAD",
        stops = #industries
    }}
end

-- Line manipulation handlers for two-step multi-stop strategy

-- Create a line from existing station IDs
handlers.create_line_from_stations = function(params)
    if not params or not params.station_ids or #params.station_ids < 2 then
        return {status = "error", message = "Need station_ids array with at least 2 station IDs"}
    end

    local util = require "ai_builder_base_util"
    local line = api.type.Line.new()

    for i, stationIdStr in pairs(params.station_ids) do
        local stationId = tonumber(stationIdStr)
        local stop = api.type.Line.Stop.new()
        stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)

        -- Get station data to determine terminal
        local stationData = util.getComponent(stationId, api.type.ComponentType.STATION)
        if stationData then
            stop.station = stationId
            stop.terminal = 0  -- Use first terminal
        end

        line.stops[i] = stop
    end

    local lineName = params.name or ("Line " .. os.time())
    -- Use Vec3f for line color (RGB 0-1)
    local lineColor = api.type.Vec3f.new(math.random(), math.random(), math.random())

    local createCmd = api.cmd.make.createLine(lineName, lineColor, game.interface.getPlayer(), line)

    local resultLineId = nil
    api.cmd.sendCommand(createCmd, function(res, success)
        if success then
            resultLineId = res.resultEntity
            log("Created line " .. tostring(resultLineId) .. " with " .. #params.station_ids .. " stops")
        else
            log("Failed to create line: " .. tostring(res))
        end
    end)

    return {status = "ok", message = "Line creation command sent", line_name = lineName}
end

-- Delete a line
handlers.delete_line = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end

    local lineId = tonumber(params.line_id)
    api.cmd.sendCommand(api.cmd.make.deleteLine(lineId))
    log("Deleted line " .. tostring(lineId))

    return {status = "ok", message = "Line deleted", line_id = tostring(lineId)}
end

-- Sell a vehicle
handlers.sell_vehicle = function(params)
    if not params or not params.vehicle_id then
        return {status = "error", message = "Need vehicle_id parameter"}
    end

    local vehicleId = tonumber(params.vehicle_id)
    api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleId))
    log("Sold vehicle " .. tostring(vehicleId))

    return {status = "ok", message = "Vehicle sold", vehicle_id = tostring(vehicleId)}
end

-- Add vehicle(s) to a line
handlers.add_vehicle_to_line = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end

    local lineId = tonumber(params.line_id)
    if not lineId then
        return {status = "error", message = "Invalid line_id (must be number)"}
    end

    local count = tonumber(params.count) or 1
    if count < 1 or count > 10 then
        return {status = "error", message = "count must be 1-10"}
    end

    log("ADD_VEHICLE: Adding " .. count .. " vehicles to line " .. lineId)

    local ok, result = pcall(function()
        local lineManager = require "ai_builder_line_manager"
        local vehicleUtil = require "ai_builder_vehicle_util"
        local util = require "ai_builder_base_util"

        -- Get line info to determine carrier type
        local line = util.getComponent(lineId, api.type.ComponentType.LINE)
        if not line then
            return {status = "error", message = "Line not found: " .. tostring(lineId)}
        end

        -- Determine carrier type from line
        local carrier = api.type.enum.Carrier.ROAD
        if line.vehicleInfo and line.vehicleInfo.transportModes then
            local modes = line.vehicleInfo.transportModes
            if modes[api.type.enum.TransportMode.TRAIN+1] and modes[api.type.enum.TransportMode.TRAIN+1] > 0 then
                carrier = api.type.enum.Carrier.RAIL
            elseif modes[api.type.enum.TransportMode.SHIP+1] and modes[api.type.enum.TransportMode.SHIP+1] > 0 then
                carrier = api.type.enum.Carrier.WATER
            elseif modes[api.type.enum.TransportMode.AIRCRAFT+1] and modes[api.type.enum.TransportMode.AIRCRAFT+1] > 0 then
                carrier = api.type.enum.Carrier.AIR
            end
        end

        -- Find depots for this line
        local depotOptions = lineManager.findDepotsForLine(lineId, carrier)
        if not depotOptions or #depotOptions == 0 then
            return {status = "error", message = "No depot found for line " .. tostring(lineId)}
        end

        -- Build vehicle config based on carrier type
        local vehicleConfig
        if carrier == api.type.enum.Carrier.ROAD then
            vehicleConfig = vehicleUtil.buildUrbanBus()
        elseif carrier == api.type.enum.Carrier.RAIL then
            vehicleConfig = vehicleUtil.buildLocomotive()
        else
            vehicleConfig = vehicleUtil.buildUrbanBus() -- fallback
        end

        -- Queue vehicles for purchase
        for i = 1, count do
            lineManager.addWork(function()
                lineManager.buyVehicleForLine(lineId, i, depotOptions, vehicleConfig)
            end)
        end

        return {status = "ok", data = {
            line_id = tostring(lineId),
            vehicles_queued = tostring(count),
            carrier = carrier == api.type.enum.Carrier.ROAD and "road" or
                      carrier == api.type.enum.Carrier.RAIL and "rail" or
                      carrier == api.type.enum.Carrier.WATER and "water" or "air"
        }}
    end)

    if ok then
        return result
    else
        return {status = "error", message = "Failed to add vehicles: " .. tostring(result)}
    end
end

-- Reassign vehicle to a different line
handlers.reassign_vehicle = function(params)
    if not params or not params.vehicle_id or not params.line_id then
        return {status = "error", message = "Need vehicle_id and line_id parameters"}
    end

    local vehicleId = tonumber(params.vehicle_id)
    local lineId = tonumber(params.line_id)

    -- Use setLine command to reassign vehicle (args: vehicle, line, stopIndex)
    local stopIndex = tonumber(params.stop_index) or 0
    api.cmd.sendCommand(api.cmd.make.setLine(vehicleId, lineId, stopIndex))
    log("Reassigned vehicle " .. tostring(vehicleId) .. " to line " .. tostring(lineId) .. " at stop " .. tostring(stopIndex))

    return {status = "ok", message = "Vehicle reassigned", vehicle_id = tostring(vehicleId), line_id = tostring(lineId)}
end

-- Merge multiple P2P lines into one multi-stop line
-- Takes station IDs from the lines and creates a new combined line
handlers.merge_lines = function(params)
    if not params or not params.line_ids or #params.line_ids < 2 then
        return {status = "error", message = "Need line_ids array with at least 2 line IDs"}
    end

    local util = require "ai_builder_base_util"
    local allStations = {}
    local allVehicles = {}
    local stationsSeen = {}

    -- Collect all stations and vehicles from the lines
    for i, lineIdStr in pairs(params.line_ids) do
        local lineId = tonumber(lineIdStr)
        local line = util.getComponent(lineId, api.type.ComponentType.LINE)

        if line then
            for j, stop in pairs(line.stops) do
                -- Get station from stop using proper API
                local stationGroupComp = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
                if stationGroupComp and stationGroupComp.stations then
                    local stationId = stationGroupComp.stations[stop.station + 1]
                    if stationId and not stationsSeen[stationId] then
                        table.insert(allStations, stationId)
                        stationsSeen[stationId] = true
                    end
                end
            end

            -- Get vehicles for this line
            local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
            for k, vehicleId in pairs(vehicles) do
                table.insert(allVehicles, vehicleId)
            end
        end
    end

    if #allStations < 2 then
        return {status = "error", message = "Not enough unique stations found in lines"}
    end

    -- Create new combined line
    local line = api.type.Line.new()
    for i, stationId in pairs(allStations) do
        local stop = api.type.Line.Stop.new()
        stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
        -- Get station index within the station group
        local stationGroupComp = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
        stop.station = util.indexOf(stationGroupComp.stations, stationId) - 1
        stop.terminal = 0
        line.stops[i] = stop
    end

    local lineName = params.name or ("Combined Line " .. os.time())
    -- Use Vec3f for line color (RGB 0-1)
    local lineColor = api.type.Vec3f.new(math.random(), math.random(), math.random())

    log("Merging " .. #params.line_ids .. " lines into " .. lineName .. " with " .. #allStations .. " stations and " .. #allVehicles .. " vehicles")

    local createCmd = api.cmd.make.createLine(lineName, lineColor, game.interface.getPlayer(), line)
    api.cmd.sendCommand(createCmd, function(res, success)
        if success then
            local newLineId = res.resultEntity
            log("Created merged line " .. tostring(newLineId))

            -- Reassign all vehicles to the new line (use stopIndex 0)
            for i, vehicleId in pairs(allVehicles) do
                api.cmd.sendCommand(api.cmd.make.setLine(vehicleId, newLineId, 0))
            end

            -- Delete the old lines
            for i, lineIdStr in pairs(params.line_ids) do
                local lineId = tonumber(lineIdStr)
                api.cmd.sendCommand(api.cmd.make.deleteLine(lineId))
            end

            log("Merged " .. #allVehicles .. " vehicles and deleted " .. #params.line_ids .. " old lines")
        else
            log("Failed to create merged line")
        end
    end)

    return {status = "ok", message = "Merge initiated", station_count = tostring(#allStations), vehicle_count = tostring(#allVehicles)}
end

-- Build rail connection using AI Builder's rail evaluation
handlers.build_rail_connection = function(params)
    log("BUILD_RAIL: Triggering AI Builder rail connection evaluation")

    -- Use the AI Builder's rail connection evaluator
    local event_params = {
        ignoreErrors = false
    }

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildIndustryRailConnection", "", event_params))

    return {status = "ok", data = {
        message = "Rail connection evaluation triggered",
        mode = "RAIL"
    }}
end

-- Build rail connection between specific industries (bypasses evaluation)
-- Uses preSelectedPair to force buildIndustryRailConnection to use specific industries
handlers.build_specific_rail_route = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Need industry1_id and industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_SPECIFIC_RAIL: " .. ind1_id .. " -> " .. ind2_id)

    -- Use preSelectedPair to force specific industry pair
    -- Allow ignoreErrors to be passed as parameter, default to true for depot issues
    local ignore = params.ignoreErrors ~= "false"
    local event_params = {
        preSelectedPair = {ind1_id, ind2_id},
        ignoreErrors = ignore
    }
    log("BUILD_SPECIFIC_RAIL: ignoreErrors=" .. tostring(ignore))

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildIndustryRailConnection", "", event_params))

    return {status = "ok", data = {
        message = "Rail route build triggered for specific industries",
        industry1_id = tostring(ind1_id),
        industry2_id = tostring(ind2_id),
        mode = "RAIL"
    }}
end

-- Build water/ship connection between industries
-- Uses AI Builder's buildNewWaterConnections which auto-evaluates water routes
handlers.build_water_connection = function(params)
    log("BUILD_WATER: Triggering AI Builder water connection evaluation")

    -- Use the AI Builder's water connection evaluator
    -- It will find the best unconnected water routes and build them
    local event_params = {
        ignoreErrors = false
    }

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildNewWaterConnections", "", event_params))

    return {status = "ok", data = {
        message = "Water connection evaluation triggered",
        mode = "WATER"
    }}
end

-- Build water/ship connection between specific industries (bypasses evaluation)
handlers.build_specific_water_route = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Need industry1_id and industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_SPECIFIC_WATER: " .. ind1_id .. " -> " .. ind2_id)

    -- Get industry entities
    local ind1 = game.interface.getEntity(ind1_id)
    local ind2 = game.interface.getEntity(ind2_id)

    if not ind1 then
        return {status = "error", message = "Industry 1 not found: " .. ind1_id}
    end
    if not ind2 then
        return {status = "error", message = "Industry 2 not found: " .. ind2_id}
    end

    ind1.id = ind1_id
    ind2.id = ind2_id

    log("BUILD_SPECIFIC_WATER: " .. tostring(ind1.name) .. " -> " .. tostring(ind2.name))

    -- Create result object with specific industries
    -- buildNewWaterConnections will use these directly instead of evaluating
    local result = {
        industry1 = ind1,
        industry2 = ind2,
        cargoType = params.cargo or "OIL"
    }

    -- Wrap in {result = ...} because event handler expects param.result
    log("BUILD_SPECIFIC_WATER: Sending script event...")
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script", "buildNewWaterConnections", "", {result = result}))
    end)

    if not ok then
        log("BUILD_SPECIFIC_WATER: ERROR sending event: " .. tostring(err))
        return {status = "error", message = "Failed to send script event: " .. tostring(err)}
    end

    log("BUILD_SPECIFIC_WATER: Script event sent successfully")

    return {status = "ok", data = {
        message = "Water route build triggered for specific industries",
        industry1 = ind1.name,
        industry2 = ind2.name,
        mode = "WATER"
    }}
end

-- ============================================================================
-- SUPPLY CHAIN STRATEGY SYSTEM
-- Evaluates complete supply chains from town demands backward through all
-- production tiers, with profitability analysis and multi-round planning.
-- ============================================================================

-- Cargo values per unit (approximate, scaled for year 1850-1900)
local CARGO_VALUES = {
    FOOD = 150,
    GOODS = 250,
    MACHINES = 280,
    TOOLS = 200,
    FUEL = 180,
    CONSTRUCTION_MATERIALS = 160,
    GRAIN = 80,
    LOGS = 60,
    PLANKS = 100,
    COAL = 70,
    IRON_ORE = 75,
    STEEL = 150,
    OIL = 120,
    STONE = 50,
    LIVESTOCK = 100
}

-- Supply chain definitions: what's needed to produce each final cargo
-- Each chain shows phases from raw material -> intermediate -> final product -> town
local CHAIN_DEFINITIONS = {
    FOOD = {
        description = "Farm produces GRAIN, Food Processing converts to FOOD",
        phases = {
            {producer_types = {"farm"}, cargo_out = "GRAIN", cargo_in = nil},
            {producer_types = {"food_processing_plant", "food"}, cargo_out = "FOOD", cargo_in = "GRAIN", delivers_to = "TOWN"}
        }
    },
    GOODS = {
        description = "Forest produces LOGS, Sawmill makes PLANKS, Goods Factory makes GOODS",
        phases = {
            {producer_types = {"forest"}, cargo_out = "LOGS", cargo_in = nil},
            {producer_types = {"saw_mill", "sawmill"}, cargo_out = "PLANKS", cargo_in = "LOGS"},
            {producer_types = {"goods_factory", "goods"}, cargo_out = "GOODS", cargo_in = "PLANKS", delivers_to = "TOWN"}
        }
    },
    TOOLS = {
        description = "Forest produces LOGS, Sawmill makes PLANKS, Tools Factory makes TOOLS",
        phases = {
            {producer_types = {"forest"}, cargo_out = "LOGS", cargo_in = nil},
            {producer_types = {"saw_mill", "sawmill"}, cargo_out = "PLANKS", cargo_in = "LOGS"},
            {producer_types = {"tool_factory", "tools"}, cargo_out = "TOOLS", cargo_in = "PLANKS", delivers_to = "TOWN"}
        }
    },
    MACHINES = {
        description = "Iron Mine + Coal Mine -> Steel Mill -> Machine Factory",
        phases = {
            {producer_types = {"iron_ore_mine", "iron"}, cargo_out = "IRON_ORE", cargo_in = nil},
            {producer_types = {"coal_mine", "coal"}, cargo_out = "COAL", cargo_in = nil},
            {producer_types = {"steel_mill", "steel"}, cargo_out = "STEEL", cargo_in = "IRON_ORE,COAL"},
            {producer_types = {"machine_factory", "machines"}, cargo_out = "MACHINES", cargo_in = "STEEL", delivers_to = "TOWN"}
        }
    },
    FUEL = {
        description = "Oil Well produces OIL, Oil Refinery OR Fuel Refinery makes FUEL",
        phases = {
            {producer_types = {"oil_well"}, cargo_out = "OIL", cargo_in = nil},
            {producer_types = {"oil_refinery", "fuel_refinery"}, cargo_out = "FUEL", cargo_in = "OIL", delivers_to = "TOWN"}
        }
    },
    CONSTRUCTION_MATERIALS = {
        description = "Quarry produces STONE, processed to CONSTRUCTION_MATERIALS",
        phases = {
            {producer_types = {"quarry", "stone"}, cargo_out = "STONE", cargo_in = nil},
            {producer_types = {"building_materials", "construction"}, cargo_out = "CONSTRUCTION_MATERIALS", cargo_in = "STONE", delivers_to = "TOWN"}
        }
    }
}

-- Transport mode characteristics
-- ROAD: Low setup cost, low capacity, good for short distances (<3km)
-- RAIL: High setup cost, high capacity, good for medium-long distances (3-15km)
-- WATER: Medium setup cost, very high capacity, requires water access, good for bulk/long distance
local TRANSPORT_MODES = {
    ROAD = {
        cost_per_km = 40000,      -- Road + truck stations
        station_cost = 100000,    -- Truck stop
        capacity_per_vehicle = 20, -- Cargo units per truck
        maintenance_rate = 0.005, -- 0.5% of build cost per month
        speed_factor = 1.0,       -- Base speed
        min_efficient_dist = 0,   -- Good for any distance
        max_efficient_dist = 5000 -- Less efficient beyond 5km
    },
    RAIL = {
        cost_per_km = 120000,     -- Track + signaling
        station_cost = 400000,    -- Freight station
        capacity_per_vehicle = 100, -- Cargo units per train
        maintenance_rate = 0.003, -- 0.3% (more efficient at scale)
        speed_factor = 2.0,       -- Faster than trucks
        min_efficient_dist = 3000, -- Needs distance to justify setup
        max_efficient_dist = 50000 -- Efficient for long hauls
    },
    WATER = {
        cost_per_km = 20000,      -- Just dredging/buoys (water is free)
        station_cost = 300000,    -- Harbor/dock
        capacity_per_vehicle = 200, -- Cargo units per ship
        maintenance_rate = 0.004, -- 0.4%
        speed_factor = 0.8,       -- Slower than trucks
        min_efficient_dist = 2000, -- Needs some distance
        max_efficient_dist = 100000, -- Very efficient for long hauls
        requires_water = true     -- Must have water access
    }
}

-- Check if a position is near water (simplified - checks if near coast/river)
local function has_water_access(position, water_bodies)
    if not position then return false end
    -- Check if any water body is within 500m
    for _, water in ipairs(water_bodies or {}) do
        local dist = calc_distance(position, water.position)
        if dist < 500 then
            return true
        end
    end
    return false
end

-- Estimate profitability of a supply chain route for a specific transport mode
local function estimate_profitability(cargo, distance_m, monthly_demand, year, transport_mode)
    year = year or 1850
    transport_mode = transport_mode or "ROAD"
    local mode = TRANSPORT_MODES[transport_mode] or TRANSPORT_MODES.ROAD

    local distance_km = distance_m / 1000

    -- Build costs scale with year (earlier = cheaper but slower vehicles)
    local era_multiplier = 1.0
    if year < 1880 then era_multiplier = 0.8
    elseif year < 1920 then era_multiplier = 1.0
    elseif year < 1960 then era_multiplier = 1.5
    else era_multiplier = 2.0 end

    -- Calculate infrastructure cost based on mode
    local cost_per_km = mode.cost_per_km * era_multiplier
    local station_cost = mode.station_cost * era_multiplier

    local build_cost = distance_km * cost_per_km + station_cost * 2  -- 2 stations per segment

    -- Revenue based on cargo value and demand
    local cargo_value = CARGO_VALUES[cargo] or 100

    -- Capacity depends on transport mode
    local transported = math.min(monthly_demand, mode.capacity_per_vehicle * 2.5)  -- ~2.5 trips/month
    local monthly_revenue = transported * cargo_value

    -- Operating costs (maintenance scales with mode efficiency)
    local monthly_cost = build_cost * mode.maintenance_rate

    local monthly_profit = monthly_revenue - monthly_cost
    local annual_roi = 0
    local payback_months = 999

    if build_cost > 0 and monthly_profit > 0 then
        annual_roi = (monthly_profit * 12) / build_cost * 100
        payback_months = build_cost / monthly_profit
    end

    -- Calculate efficiency score based on distance vs mode characteristics
    local efficiency = 1.0
    if distance_m < mode.min_efficient_dist then
        efficiency = distance_m / mode.min_efficient_dist  -- Penalty for too short
    elseif distance_m > mode.max_efficient_dist then
        efficiency = mode.max_efficient_dist / distance_m  -- Penalty for too long
    end

    return {
        build_cost = math.floor(build_cost),
        monthly_revenue = math.floor(monthly_revenue),
        monthly_cost = math.floor(monthly_cost),
        monthly_profit = math.floor(monthly_profit),
        annual_roi = math.floor(annual_roi * efficiency * 10) / 10,  -- Adjusted by efficiency
        payback_months = math.floor(payback_months),
        efficiency = math.floor(efficiency * 100),
        transport_mode = transport_mode
    }
end

-- Evaluate all transport modes and return the best one
local function find_best_transport_mode(cargo, distance_m, monthly_demand, year, has_water)
    local best_mode = "ROAD"
    local best_roi = -999
    local all_modes = {}

    for mode_name, mode_config in pairs(TRANSPORT_MODES) do
        -- Skip water if no water access
        if mode_name == "WATER" and not has_water then
            -- Skip
        else
            local profit = estimate_profitability(cargo, distance_m, monthly_demand, year, mode_name)
            all_modes[mode_name] = profit

            if profit.annual_roi > best_roi then
                best_roi = profit.annual_roi
                best_mode = mode_name
            end
        end
    end

    return best_mode, all_modes
end

-- Calculate distance between two positions
local function calc_distance(pos1, pos2)
    if not pos1 or not pos2 then return 999999 end
    local x1 = pos1[1] or pos1.x or 0
    local y1 = pos1[2] or pos1.y or 0
    local x2 = pos2[1] or pos2.x or 0
    local y2 = pos2[2] or pos2.y or 0
    return math.sqrt((x2-x1)^2 + (y2-y1)^2)
end

-- Check if industry type matches any of the producer_types
local function matches_producer_type(industry_type, producer_types)
    if not industry_type then return false end
    local lower_type = industry_type:lower()
    for _, pt in ipairs(producer_types) do
        if lower_type:find(pt:lower()) then
            return true
        end
    end
    return false
end

-- Evaluate all possible supply chains based on town demands
-- Now evaluates ROAD, RAIL, and WATER transport modes
handlers.evaluate_supply_chains = function(params)
    log("EVALUATE_SUPPLY_CHAINS: Starting multi-mode evaluation")

    -- Get current budget
    local player = game.interface.getPlayer()
    local playerEntity = player and game.interface.getEntity(player) or nil
    local current_money = playerEntity and playerEntity.balance or 0
    local budget = tonumber(params and params.budget) or (current_money * 0.3)  -- Default to 30% of funds

    -- Get current year
    local gameTime = game.interface.getGameTime()
    local year = (gameTime and gameTime.date and gameTime.date.year) or 1850

    -- Get all towns with demands
    local allTowns = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    -- Get all industries
    local allIndustries = game.interface.getEntities({radius=1e9}, {type="SIM_BUILDING", includeData=true})

    -- Collect water body positions (oil wells, refineries near water, harbors)
    -- For simplicity, assume industries with "oil", "harbor", "port", "dock" in name have water access
    local water_industries = {}

    -- Index industries by type for fast lookup
    local industries_by_type = {}
    local industry_list = {}
    for id, industry in pairs(allIndustries) do
        if industry.itemsProduced or industry.itemsConsumed then
            local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(id)
            local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil
            local fileName = construction and construction.fileName or ""
            local industry_type = fileName:match("industry/(.-)%.") or "unknown"
            local name_lower = (industry.name or ""):lower()

            -- Check for water access indicators
            local has_water = name_lower:find("oil") or name_lower:find("harbor") or
                              name_lower:find("port") or name_lower:find("dock") or
                              name_lower:find("refinery") or industry_type:find("oil")

            local ind_data = {
                id = id,
                name = industry.name or "Unknown",
                type = industry_type,
                position = industry.position or (construction and construction.position) or {0, 0, 0},
                produces = industry.itemsProduced or {},
                consumes = industry.itemsConsumed or {},
                has_water_access = has_water
            }

            table.insert(industry_list, ind_data)

            if has_water then
                table.insert(water_industries, ind_data)
            end

            -- Index by type
            if not industries_by_type[industry_type] then
                industries_by_type[industry_type] = {}
            end
            table.insert(industries_by_type[industry_type], ind_data)
        end
    end

    log("EVALUATE_SUPPLY_CHAINS: Found " .. #industry_list .. " industries, " .. #water_industries .. " with water access")

    -- Collect all supply chain opportunities
    local chains = {}
    local chain_count = 0

    for townId, town in pairs(allTowns) do
        local townPos = town.position or {0, 0, 0}
        local townName = town.name or "Unknown"

        -- Check if town has water access (near any water industry)
        local town_has_water = false
        for _, wi in ipairs(water_industries) do
            if calc_distance(townPos, wi.position) < 3000 then
                town_has_water = true
                break
            end
        end

        -- Get actual cargo demands for this town
        local ok, cargoSupplyAndLimit = pcall(function()
            return game.interface.getTownCargoSupplyAndLimit(townId)
        end)

        if ok and cargoSupplyAndLimit then
            for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
                local supply = supplyAndLimit[1] or 0
                local limit = supplyAndLimit[2] or 0
                local demand = math.max(0, limit - supply)

                if demand > 5 then  -- Only consider meaningful demands
                    local chain_def = CHAIN_DEFINITIONS[cargoName]

                    if chain_def then
                        -- Find industries that can produce the final cargo
                        local final_phase = chain_def.phases[#chain_def.phases]

                        for _, ind in ipairs(industry_list) do
                            if matches_producer_type(ind.type, final_phase.producer_types) then
                                -- Found a potential final producer
                                local distance = calc_distance(ind.position, townPos)

                                -- Check water access for this route
                                local route_has_water = ind.has_water_access and town_has_water

                                -- Find best transport mode for final leg
                                local best_mode, all_modes = find_best_transport_mode(
                                    cargoName, distance, demand, year, route_has_water)

                                -- Calculate profitability for the final leg with best mode
                                local profit = estimate_profitability(cargoName, distance, demand, year, best_mode)

                                -- Build the full phase list with actual industry candidates
                                local phases = {}
                                local total_distance = distance
                                local total_cost_road = 0
                                local total_cost_rail = 0
                                local total_cost_best = profit.build_cost
                                local valid_chain = true
                                local chain_has_water = route_has_water

                                -- Work backward through the chain phases
                                local current_pos = ind.position
                                local current_ind = ind

                                for phase_idx = #chain_def.phases, 1, -1 do
                                    local phase = chain_def.phases[phase_idx]

                                    if phase_idx == #chain_def.phases then
                                        -- Final phase: industry -> town
                                        -- Calculate costs for all modes
                                        local road_profit = estimate_profitability(cargoName, distance, demand, year, "ROAD")
                                        local rail_profit = estimate_profitability(cargoName, distance, demand, year, "RAIL")

                                        total_cost_road = total_cost_road + road_profit.build_cost
                                        total_cost_rail = total_cost_rail + rail_profit.build_cost

                                        table.insert(phases, 1, {
                                            from = ind.name,
                                            from_id = tostring(ind.id),
                                            from_type = ind.type,
                                            to = townName,
                                            to_id = tostring(townId),
                                            cargo = cargoName,
                                            distance = tostring(math.floor(distance)),
                                            is_town_delivery = "true",
                                            best_mode = best_mode,
                                            road_cost = tostring(road_profit.build_cost),
                                            rail_cost = tostring(rail_profit.build_cost),
                                            water_available = route_has_water and "true" or "false"
                                        })
                                    else
                                        -- Find nearest source industry for this phase
                                        local best_source = nil
                                        local best_dist = 1e9

                                        for _, source_ind in ipairs(industry_list) do
                                            if matches_producer_type(source_ind.type, phase.producer_types) then
                                                local dist = calc_distance(source_ind.position, current_pos)
                                                if dist < best_dist then
                                                    best_dist = dist
                                                    best_source = source_ind
                                                end
                                            end
                                        end

                                        if best_source then
                                            -- Check water access for this leg
                                            local leg_has_water = best_source.has_water_access and current_ind.has_water_access

                                            -- Find best mode for this leg
                                            local leg_best_mode, _ = find_best_transport_mode(
                                                phase.cargo_out, best_dist, demand, year, leg_has_water)

                                            local phase_profit = estimate_profitability(
                                                phase.cargo_out, best_dist, demand, year, leg_best_mode)
                                            local road_profit = estimate_profitability(
                                                phase.cargo_out, best_dist, demand, year, "ROAD")
                                            local rail_profit = estimate_profitability(
                                                phase.cargo_out, best_dist, demand, year, "RAIL")

                                            total_cost_road = total_cost_road + road_profit.build_cost
                                            total_cost_rail = total_cost_rail + rail_profit.build_cost
                                            total_cost_best = total_cost_best + phase_profit.build_cost

                                            table.insert(phases, 1, {
                                                from = best_source.name,
                                                from_id = tostring(best_source.id),
                                                from_type = best_source.type,
                                                to = current_ind.name,
                                                to_id = tostring(current_ind.id),
                                                cargo = phase.cargo_out,
                                                distance = tostring(math.floor(best_dist)),
                                                best_mode = leg_best_mode,
                                                road_cost = tostring(road_profit.build_cost),
                                                rail_cost = tostring(rail_profit.build_cost),
                                                water_available = leg_has_water and "true" or "false"
                                            })

                                            total_distance = total_distance + best_dist
                                            current_pos = best_source.position
                                            current_ind = best_source

                                            if leg_has_water then chain_has_water = true end
                                        else
                                            valid_chain = false
                                            break
                                        end
                                    end
                                end

                                if valid_chain and #phases > 0 then
                                    -- Calculate ROI for each transport strategy
                                    local function calc_roi(total_cost, monthly_rev)
                                        local monthly_cost = total_cost * 0.004  -- Average maintenance
                                        local monthly_profit = monthly_rev - monthly_cost
                                        if total_cost > 0 and monthly_profit > 0 then
                                            return (monthly_profit * 12) / total_cost * 100
                                        end
                                        return 0
                                    end

                                    local roi_road = calc_roi(total_cost_road, profit.monthly_revenue)
                                    local roi_rail = calc_roi(total_cost_rail, profit.monthly_revenue)
                                    local roi_best = calc_roi(total_cost_best, profit.monthly_revenue)

                                    -- Determine overall best mode based on distance and demand
                                    local recommended_mode = "ROAD"
                                    local recommended_cost = total_cost_road
                                    local best_roi = roi_road

                                    if total_distance > 5000 and demand > 30 then
                                        -- Rail better for long distance + high demand
                                        if roi_rail > roi_road * 0.8 then  -- Rail within 20% is worth it for capacity
                                            recommended_mode = "RAIL"
                                            recommended_cost = total_cost_rail
                                            best_roi = roi_rail
                                        end
                                    end

                                    if chain_has_water and total_distance > 3000 and
                                       (cargoName == "FUEL" or cargoName == "CRUDE" or cargoName == "OIL") then
                                        recommended_mode = "WATER"
                                        -- Water cost estimated
                                        recommended_cost = total_cost_road * 0.6  -- Water is cheaper
                                        best_roi = roi_road * 1.3
                                    end

                                    chain_count = chain_count + 1

                                    -- Generate recommendation
                                    local recommendation = "SKIP - Low ROI"
                                    if best_roi > 50 then
                                        recommendation = "BUILD " .. recommended_mode .. " - Excellent ROI"
                                    elseif best_roi > 25 then
                                        recommendation = "BUILD " .. recommended_mode .. " - Good ROI"
                                    elseif best_roi > 10 then
                                        recommendation = "CONSIDER " .. recommended_mode .. " - Moderate ROI"
                                    elseif best_roi > 5 then
                                        recommendation = "MARGINAL " .. recommended_mode .. " - Low ROI"
                                    end

                                    if recommended_cost > budget then
                                        recommendation = "DEFER - Over budget (" .. recommended_mode .. ")"
                                    end

                                    table.insert(chains, {
                                        town = townName,
                                        town_id = tostring(townId),
                                        cargo = cargoName,
                                        demand = tostring(demand),
                                        phases = phases,
                                        phase_count = tostring(#phases),
                                        total_distance = tostring(math.floor(total_distance)),
                                        -- Transport mode comparison
                                        recommended_mode = recommended_mode,
                                        estimated_cost = tostring(math.floor(recommended_cost)),
                                        road_cost = tostring(math.floor(total_cost_road)),
                                        rail_cost = tostring(math.floor(total_cost_rail)),
                                        water_available = chain_has_water and "true" or "false",
                                        -- ROI comparison
                                        estimated_monthly_revenue = tostring(math.floor(profit.monthly_revenue)),
                                        roi_annual = tostring(math.floor(best_roi * 10) / 10) .. "%",
                                        roi_road = tostring(math.floor(roi_road * 10) / 10) .. "%",
                                        roi_rail = tostring(math.floor(roi_rail * 10) / 10) .. "%",
                                        priority = best_roi,  -- Used for sorting
                                        recommendation = recommendation
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort by ROI (highest first)
    table.sort(chains, function(a, b) return (a.priority or 0) > (b.priority or 0) end)

    -- Convert priority to rank and make it a string
    for i, chain in ipairs(chains) do
        chain.priority = tostring(i)
    end

    -- Count affordable chains
    local affordable_count = 0
    local remaining = budget
    for _, chain in ipairs(chains) do
        local cost = tonumber(chain.estimated_cost) or 0
        if cost <= remaining then
            affordable_count = affordable_count + 1
            remaining = remaining - cost
        end
    end

    log("EVALUATE_SUPPLY_CHAINS: Found " .. #chains .. " potential chains, " .. affordable_count .. " affordable")

    return {
        status = "ok",
        data = {
            chains = chains,
            budget = tostring(math.floor(budget)),
            current_money = tostring(math.floor(current_money)),
            affordable_chains = tostring(affordable_count),
            year = tostring(year),
            industry_count = tostring(#industry_list),
            water_access_industries = tostring(#water_industries),
            transport_modes = "ROAD,RAIL,WATER"
        }
    }
end

-- Plan a multi-round build strategy based on budget
handlers.plan_build_strategy = function(params)
    log("PLAN_BUILD_STRATEGY: Starting planning")

    -- Get current budget
    local player = game.interface.getPlayer()
    local playerEntity = player and game.interface.getEntity(player) or nil
    local current_money = playerEntity and playerEntity.balance or 0

    local budget = tonumber(params and params.budget) or (current_money * 0.3)
    local rounds = tonumber(params and params.rounds) or 3
    local min_roi = tonumber(params and params.min_roi) or 10  -- Minimum ROI% to consider

    -- Get all chain candidates
    local eval_result = handlers.evaluate_supply_chains({budget = tostring(budget * rounds)})

    if eval_result.status ~= "ok" then
        return eval_result
    end

    local chains = eval_result.data.chains

    -- Filter chains by minimum ROI
    local viable_chains = {}
    for _, chain in ipairs(chains) do
        local roi = tonumber(chain.roi_annual:match("([%d%.]+)")) or 0
        if roi >= min_roi then
            table.insert(viable_chains, chain)
        end
    end

    -- Allocate chains to rounds
    local plan = {}
    local remaining_budget = budget
    local planned_chains = {}

    for round = 1, rounds do
        plan[round] = {
            round = tostring(round),
            routes = {},
            total_cost = 0,
            expected_revenue = 0
        }

        for _, chain in ipairs(viable_chains) do
            if not planned_chains[chain] then
                local cost = tonumber(chain.estimated_cost) or 0
                local revenue = tonumber(chain.estimated_monthly_revenue) or 0

                if cost <= remaining_budget then
                    table.insert(plan[round].routes, {
                        town = chain.town,
                        town_id = chain.town_id,
                        cargo = chain.cargo,
                        phases = chain.phases,
                        cost = chain.estimated_cost,
                        roi = chain.roi_annual,
                        transport_mode = chain.recommended_mode or "ROAD"
                    })
                    plan[round].total_cost = plan[round].total_cost + cost
                    plan[round].expected_revenue = plan[round].expected_revenue + revenue
                    remaining_budget = remaining_budget - cost
                    planned_chains[chain] = true
                end
            end
        end

        -- Convert numbers to strings for TF2
        plan[round].total_cost = tostring(math.floor(plan[round].total_cost))
        plan[round].expected_revenue = tostring(math.floor(plan[round].expected_revenue))
        plan[round].route_count = tostring(#plan[round].routes)

        -- After first round, assume some revenue comes in (simplified model)
        if round < rounds then
            remaining_budget = remaining_budget + (plan[round].expected_revenue * 3)  -- 3 months of revenue
        end
    end

    -- Calculate total planned
    local total_planned_cost = 0
    local total_planned_routes = 0
    for _, round_plan in ipairs(plan) do
        total_planned_cost = total_planned_cost + tonumber(round_plan.total_cost)
        total_planned_routes = total_planned_routes + #round_plan.routes
    end

    log("PLAN_BUILD_STRATEGY: Created " .. rounds .. "-round plan with " .. total_planned_routes .. " routes")

    return {
        status = "ok",
        data = {
            plan = plan,
            rounds = tostring(rounds),
            initial_budget = tostring(math.floor(budget)),
            total_planned_cost = tostring(math.floor(total_planned_cost)),
            total_routes = tostring(total_planned_routes),
            unplanned_viable = tostring(#viable_chains - total_planned_routes)
        }
    }
end

-- Poll for commands and process them
function M.poll()
    -- Set 4x once on first tick, then respect player speed changes
    ensureDefaultSpeed4x()

    local j = get_json()
    if not j then
        -- Try to log that JSON isn't available
        log("ERROR: JSON module not loaded")
        return
    end

    -- Check for command file
    local f = io.open(CMD_FILE, "r")
    if not f then return end

    local content = f:read("*a")
    f:close()

    if not content or #content == 0 then return end

    -- Parse command
    local ok, cmd = pcall(j.decode, content)
    if not ok or not cmd then
        log("ERROR: Bad JSON: " .. tostring(content):sub(1, 50))
        clear_command()
        return
    end

    -- Check if already processed (using timestamp to avoid stuck state)
    local cmd_id = cmd.id
    if cmd_id == last_cmd_id then
        return  -- Already processed this command
    end

    log("RECV: " .. tostring(cmd.cmd) .. " id=" .. tostring(cmd_id))

    -- IMMEDIATELY mark as processed to prevent re-processing
    last_cmd_id = cmd_id

    -- Get handler
    local handler = handlers[cmd.cmd]
    local resp

    -- NOTE: no forced game speed here - player speed changes are respected.

    if handler then
        log("EXEC: " .. tostring(cmd.cmd))
        local success, result = pcall(handler, cmd.params)
        if success then
            resp = result
            log("OK: " .. tostring(cmd.cmd))
        else
            resp = {status = "error", message = tostring(result)}
            log("FAIL: " .. tostring(result))
        end
    else
        resp = {status = "error", message = "Unknown command: " .. tostring(cmd.cmd)}
        log("UNKNOWN: " .. tostring(cmd.cmd))
    end

    log("PRE_WRITE")

    -- Add request ID to response
    if resp then
        resp.id = cmd_id
        log("RESP_READY: " .. type(resp))
    else
        log("ERROR: resp is nil!")
        resp = {status = "error", message = "nil response", id = cmd_id}
    end

    -- Write response with error handling
    local write_success, write_result = pcall(function()
        return write_response(resp)
    end)

    if write_success then
        if write_result then
            log("SENT: id=" .. tostring(cmd_id))
        else
            log("WRITE_FAIL: id=" .. tostring(cmd_id))
        end
    else
        log("WRITE_ERROR: " .. tostring(write_result))
    end

    -- Clear command file
    clear_command()
    log("DONE: " .. tostring(cmd_id))
end

-- Initialize
function M.init()
    log("=== Simple IPC initialized ===")
    -- Clear any stale files
    pcall(os.remove, CMD_FILE)
    pcall(os.remove, RESP_FILE)
end

return M
