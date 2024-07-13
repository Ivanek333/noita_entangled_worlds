local inventory_helper = dofile_once("mods/quant.ew/files/src/inventory_helper.lua")
local ctx = dofile_once("mods/quant.ew/files/src/ctx.lua")
local net = dofile_once("mods/quant.ew/files/src/net.lua")
local util = dofile_once("mods/quant.ew/files/src/util.lua")

dofile_once("data/scripts/lib/coroutines.lua")

local rpc = net.new_rpc_namespace()

local item_sync = {}

local pending_remove = {}

function item_sync.ensure_notify_component(ent)
    local notify = EntityGetFirstComponentIncludingDisabled(ent, "LuaComponent", "ew_notify_component")
        if notify == nil then
            EntityAddComponent2(ent, "LuaComponent", {
                _tags = "enabled_in_world,enabled_in_hand,enabled_in_inventory,ew_notify_component",
                script_throw_item = "mods/quant.ew/files/cbs/item_notify.lua",
                script_item_picked_up = "mods/quant.ew/files/cbs/item_notify.lua",
                -- script_kick = "mods/quant.ew/files/cbs/item_notify.lua",
            })
        end
end

local function mark_in_inventory(my_player)
    local items = inventory_helper.get_all_inventory_items(my_player)
    for _, ent in pairs(items) do
        item_sync.ensure_notify_component(ent)
    end
end

local function allocate_global_id()
    local current = tonumber(GlobalsGetValue("ew_global_item_id", "1"))
    GlobalsSetValue("ew_global_item_id", tostring(current+1))
    return current
end

local function is_item_on_ground(item)
    return EntityGetComponent(item, "SimplePhysicsComponent") ~= nil or EntityGetComponent(item, "PhysicsBodyComponent")
end

function item_sync.get_global_item_id(item)
    local gid = EntityGetFirstComponentIncludingDisabled(item, "VariableStorageComponent", "ew_global_item_id")
    if gid == nil then
        GamePrint("Item has no gid")
        return 0
    end
    local ret = ComponentGetValue2(gid, "value_int")
    return ret or 0
end

function item_sync.remove_item_with_id(gid)
    table.insert(pending_remove, gid)
end

function item_sync.remove_item_with_id_now(gid)
    local global_items = EntityGetWithTag("ew_global_item")
    for _, item in ipairs(global_items) do
        local i_gid = item_sync.get_global_item_id(item)
        if i_gid == gid then
            EntityKill(item)
        end
    end
end

function item_sync.host_localize_item(gid, peer_id)
    if ctx.item_prevent_localize[gid] then
        GamePrint("Item localize for "..gid.." prevented")
    end
    ctx.item_prevent_localize[gid] = true
    
    if table.contains(pending_remove, gid) then
        GamePrint("Item localize prevented, already taken")
        return
    end

    if peer_id ~= ctx.my_id then
        item_sync.remove_item_with_id(gid)
    end
    rpc.item_localize(peer_id, gid)
end

function item_sync.make_item_global(item, instant)
    async(function()
        if not instant then
            wait(1) -- Wait 1 frame so that game sets proper velocity.
        end
        if not EntityGetIsAlive(item) then
            GamePrint("Thrown item vanished before we could send it")
            return
        end
        local gid = EntityGetFirstComponentIncludingDisabled(item, "VariableStorageComponent", "ew_global_item_id")
        local id = ComponentGetValue2(gid, "value_int")
        if gid == nil then
            id = allocate_global_id()
            EntityAddComponent2(item, "VariableStorageComponent", {
                _tags = "enabled_in_world,enabled_in_hand,enabled_in_inventory,ew_global_item_id",
                value_int = id,
            })
        end
        local vel = EntityGetFirstComponentIncludingDisabled(item, "VelocityComponent")
        if vel then
            local vx, vy = ComponentGetValue2(vel, "mVelocity")
        end
        local item_data = inventory_helper.serialize_single_item(item)
        item_data.g_d = id
        ctx.item_prevent_localize[id] = false
        rpc.item_global(item_data)
    end)
end

local function get_global_ent(key)
    local val = tonumber(GlobalsGetValue(key, "0"))
    GlobalsSetValue(key, "0")
    if val ~= 0 then
        return val
    end
end

local function remove_client_items_from_world()
    if GameGetFrameNum() % 5 ~= 3 then
        return
    end
    for _, item in ipairs(EntityGetWithTag("ew_client_item")) do
        if is_item_on_ground(item) then
            EntityKill(item)
        end
    end
end

function item_sync.on_world_update_host()
    local my_player = ctx.my_player
    if GameGetFrameNum() % 5 == 4 then
        mark_in_inventory(my_player)
    end
    local thrown_item = get_global_ent("ew_thrown")
    if thrown_item ~= nil then
        EntityAddTag(thrown_item, "ew_global_item")
       item_sync.make_item_global(thrown_item)
    end
    local picked_item = get_global_ent("ew_picked")
    if picked_item ~= nil and EntityHasTag(picked_item, "ew_global_item") then
        local gid = item_sync.get_global_item_id(picked_item)
        item_sync.host_localize_item(gid, ctx.my_id)
    end
    remove_client_items_from_world()
end

function item_sync.on_world_update_client()
    local my_player = ctx.my_player
    if GameGetFrameNum() % 5 == 4 then
        mark_in_inventory(my_player)
    end
    local thrown_item = get_global_ent("ew_thrown")
    if thrown_item ~= nil and not EntityHasTag(thrown_item, "ew_client_item") then
        async(function ()
            wait(1) -- Wait 1 frame so that game sets proper velocity.
            if not EntityGetIsAlive(thrown_item) then
                GamePrint("Thrown item vanished before we could send it")
                return
            end
            rpc.item_upload(inventory_helper.serialize_single_item(thrown_item))
            EntityKill(thrown_item)
        end)
    end
    
    local picked_item = get_global_ent("ew_picked")
    if picked_item ~= nil and EntityHasTag(picked_item, "ew_global_item") then
        local gid = item_sync.get_global_item_id(picked_item)
        rpc.item_localize_req(gid)
    end
    remove_client_items_from_world()
end

function item_sync.on_world_update()
    -- TODO check that we not removing item we are going to pick now, instead of checking if picker gui is open.
    if not ctx.is_wand_pickup then
        if #pending_remove > 0 then
            local gid = table.remove(pending_remove)
            item_sync.remove_item_with_id_now(gid)
        end
    end
end

function item_sync.upload(item_data)
    local item = inventory_helper.deserialize_single_item(item_data)
    EntityAddTag(item, "ew_global_item")
    item_sync.ensure_notify_component(item)
    item_sync.make_item_global(item, true)
end

rpc.opts_reliable()
function rpc.item_global(item_data)
    if ctx.rpc_peer_id ~= ctx.host_id then
        return
    end
    local item = inventory_helper.deserialize_single_item(item_data)
    EntityAddTag(item, "ew_global_item")
    item_sync.ensure_notify_component(item)
    -- GamePrint("Got global item: "..item)
    local gid = EntityGetFirstComponentIncludingDisabled(item, "VariableStorageComponent", "ew_global_item_id")
    if gid == nil then
        EntityAddComponent2(item, "VariableStorageComponent", {
            _tags = "ew_global_item_id",
            value_int = item_data.gid
        })
    else
        ComponentSetValue2(gid, "value_int", item_data.gid)
    end
end

rpc.opts_reliable()
function rpc.item_localize(l_peer_id, item_id)
    if l_peer_id ~= ctx.my_id then
        item_sync.remove_item_with_id(item_id)
    end
end

rpc.opts_reliable()
function rpc.item_localize_req(gid)
    if not ctx.is_host then
        return
    end
    item_sync.host_localize_item(gid, ctx.rpc_peer_id)
end

rpc.opts_reliable()
function rpc.item_upload(item_data)
    if not ctx.is_host then
        return
    end
    item_sync.upload(item_data)
end

return item_sync