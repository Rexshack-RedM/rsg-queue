local RSGCore = exports['rsg-core']:GetCoreObject()

local Queue      = {}  -- waiting entries
local Connecting = {}  -- [license] = expiry time (admitted, still loading in)
local Grace      = {}  -- [license] = expiry time (dropped recently)
local VipCache   = {}  -- [identifier] = { tier, name, expires }
local Ready      = false

local function dbg(...) if Config.Debug then print('^3[rsg-queue]^7', ...) end end

local function notify(src, msg, ntype)
    if src == 0 then print('[rsg-queue] ' .. msg) return end
    TriggerClientEvent('RSGCore:Client:Notify', src, { title = locale('ui_title'), description = msg, type = ntype or 'inform' })
end

---------------------------------
-- database
---------------------------------
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS `rsg_queue_vip` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(80) NOT NULL,
    `name` VARCHAR(100) DEFAULT NULL,
    `tier` VARCHAR(30) NOT NULL,
    `expires_at` DATETIME DEFAULT NULL,
    `added_by` VARCHAR(100) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
]]

local function ensureDatabase()
    local ok, err = pcall(function() MySQL.query.await(SCHEMA) end)
    if not ok then
        print('^1[rsg-queue] database setup failed: ' .. tostring(err) .. '^7')
        return false
    end
    print('^2[rsg-queue] database tables ready^7')
    return true
end

local function loadVips()
    local rows = MySQL.query.await([[SELECT identifier, name, tier, UNIX_TIMESTAMP(expires_at) AS expires
        FROM rsg_queue_vip WHERE expires_at IS NULL OR expires_at > NOW()]]) or {}
    local cache = {}
    for _, r in ipairs(rows) do
        if Config.Tiers[r.tier] then
            cache[r.identifier] = { tier = r.tier, name = r.name, expires = r.expires }
        end
    end
    VipCache = cache
    dbg(('loaded %d VIPs'):format(#rows))
end

---------------------------------
-- priority & slots
---------------------------------
local function getPriority(src, license)
    local info = { priority = 0, tier = nil, label = locale('card_standard'), reserved = false, grace = false }
    local now = os.time()

    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        local vip = VipCache[id]
        if vip and (not vip.expires or vip.expires > now) then
            local t = Config.Tiers[vip.tier]
            if t and t.priority > info.priority then
                info.priority, info.tier, info.label, info.reserved = t.priority, vip.tier, t.label, t.reserved
            end
        end
    end

    if Config.StaffAce and IsPlayerAceAllowed(src, Config.StaffAce) and Config.StaffPriority > info.priority then
        info.priority, info.tier, info.label, info.reserved = Config.StaffPriority, 'staff', 'Staff', true
    end

    if Config.Grace.enabled and Grace[license] then
        if Grace[license] > now then
            info.priority = info.priority + Config.Grace.priority
            info.grace = true
        else
            Grace[license] = nil
        end
    end
    return info
end

local function usedSlots()
    local n, now = #GetPlayers(), os.time()
    for lic, exp in pairs(Connecting) do
        if exp < now then Connecting[lic] = nil else n = n + 1 end
    end
    return n
end

local function hasSlot(entry)
    local max = GetConvarInt('sv_maxclients', 48)
    local limit = entry.reserved and max or (max - Config.ReservedSlots)
    return usedSlots() < limit
end

local function sortQueue()
    table.sort(Queue, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.joined < b.joined
    end)
end

local function removeEntry(entry)
    for i, e in ipairs(Queue) do
        if e == entry then table.remove(Queue, i) return end
    end
end

local function positionOf(entry)
    for i, e in ipairs(Queue) do if e == entry then return i end end
    return 0
end

local function fmtTime(sec)
    return ('%02d:%02d'):format(math.floor(sec / 60), sec % 60)
end

---------------------------------
-- adaptive card
---------------------------------
local function buildCard(entry)
    local body = {}
    if Config.CardImage ~= '' then
        body[#body + 1] = { type = 'Image', url = Config.CardImage, horizontalAlignment = 'Center', size = 'Stretch' }
    end
    body[#body + 1] = { type = 'TextBlock', text = Config.ServerName, size = 'ExtraLarge', weight = 'Bolder', horizontalAlignment = 'Center', wrap = true }
    body[#body + 1] = { type = 'TextBlock', text = locale('card_title'):upper(), isSubtle = true, horizontalAlignment = 'Center', spacing = 'None' }
    body[#body + 1] = {
        type = 'TextBlock', size = 'Large', weight = 'Bolder', horizontalAlignment = 'Center', spacing = 'Medium',
        text = locale('card_position', positionOf(entry), #Queue),
    }
    body[#body + 1] = {
        type = 'FactSet', spacing = 'Medium',
        facts = {
            { title = locale('card_tier_title'), value = entry.label },
            { title = locale('card_waited_title'), value = fmtTime(os.time() - entry.joined) },
        },
    }
    if entry.grace then
        body[#body + 1] = { type = 'TextBlock', text = locale('card_grace'), color = 'Good', horizontalAlignment = 'Center', wrap = true }
    end
    if not entry.tier then
        body[#body + 1] = { type = 'TextBlock', text = locale('tip_vip'), isSubtle = true, horizontalAlignment = 'Center', wrap = true, spacing = 'Medium' }
    end

    local actions = {}
    for _, l in ipairs(Config.Links) do
        actions[#actions + 1] = { type = 'Action.OpenUrl', title = l.title, url = l.url }
    end

    return json.encode({
        type = 'AdaptiveCard',
        ['$schema'] = 'http://adaptivecards.io/schemas/adaptive-card.json',
        version = '1.3',
        body = body,
        actions = actions,
    })
end

---------------------------------
-- connecting
---------------------------------
AddEventHandler('playerConnecting', function(name, _, deferrals)
    local src = source
    deferrals.defer()
    Wait(0)
    deferrals.update(locale('checking'))

    local waited = 0
    while not Ready and waited < 15000 do Wait(500) waited = waited + 500 end

    local license = GetPlayerIdentifierByType(src, 'license')
    if not license then
        deferrals.done(locale('no_license'))
        return
    end

    -- drop any older entry for the same license (reconnect spam)
    for _, e in ipairs(Queue) do
        if e.license == license then e.replaced = true end
    end

    local info = getPriority(src, license)
    local entry = {
        src = src, license = license, name = name,
        priority = info.priority, tier = info.tier, label = info.label,
        reserved = info.reserved, grace = info.grace, joined = os.time(),
    }
    Queue[#Queue + 1] = entry
    sortQueue()
    dbg(('%s queued (priority %d)'):format(name, entry.priority))

    local started    = GetGameTimer()
    local minCardMs  = math.max(0, (Config.MinCardTime or 0) * 1000)
    local nextCard   = 0

    local function freeHeldSlot()
        if entry.admit then Connecting[license] = nil end
    end

    while true do
        if entry.replaced then removeEntry(entry) freeHeldSlot() return end
        if entry.removed then
            removeEntry(entry)
            freeHeldSlot()
            deferrals.done(locale('removed_by_admin'))
            return
        end
        if not GetPlayerName(src) then -- left while waiting
            removeEntry(entry)
            freeHeldSlot()
            return
        end
        local now = GetGameTimer()
        -- admitted: let them in once the card has been on screen for MinCardTime
        if entry.admit and now - started >= minCardMs then
            removeEntry(entry)
            if entry.grace then Grace[license] = nil end
            Connecting[license] = os.time() + Config.ConnectTimeout -- restart load-in timer from now
            deferrals.update(locale('joining'))
            Wait(500)
            deferrals.done()
            return
        end
        if now >= nextCard then
            deferrals.presentCard(buildCard(entry))
            nextCard = now + Config.UpdateInterval
        end
        Wait(250)
    end
end)

-- admit players while slots are free
CreateThread(function()
    while true do
        Wait(1000)
        if Ready and #Queue > 0 then
            sortQueue()
            for _, e in ipairs(Queue) do
                if not e.admit and not e.removed and not e.replaced and hasSlot(e) then
                    e.admit = true
                    Connecting[e.license] = os.time() + Config.ConnectTimeout
                    dbg(('admitting %s'):format(e.name))
                    break
                end
            end
        end
    end
end)

AddEventHandler('playerJoining', function()
    local license = GetPlayerIdentifierByType(source, 'license')
    if license then Connecting[license] = nil end
end)

AddEventHandler('playerDropped', function()
    local license = GetPlayerIdentifierByType(source, 'license')
    if not license then return end
    Connecting[license] = nil
    if Config.Grace.enabled then
        Grace[license] = os.time() + Config.Grace.minutes * 60
    end
end)

---------------------------------
-- VIP management
---------------------------------
local function validIdentifier(id)
    return type(id) == 'string' and #id <= 80 and id:match('^%a+:[%w]+$') ~= nil
end

local function addVip(identifier, tier, days, name, by)
    if not validIdentifier(identifier) then return false, locale('invalid_target') end
    if not Config.Tiers[tier] then return false, locale('invalid_tier', tostring(tier)) end
    days = math.floor(tonumber(days) or 0)
    if days < 0 or days > 3650 then days = 0 end
    name = type(name) == 'string' and name:sub(1, 100) or nil
    if name == '' then name = nil end

    if days > 0 then
        MySQL.query.await([[INSERT INTO rsg_queue_vip (identifier, name, tier, expires_at, added_by)
            VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL ? DAY), ?)
            ON DUPLICATE KEY UPDATE tier = VALUES(tier), expires_at = VALUES(expires_at),
            name = COALESCE(VALUES(name), name), added_by = VALUES(added_by)]],
            { identifier, name, tier, days, by })
    else
        MySQL.query.await([[INSERT INTO rsg_queue_vip (identifier, name, tier, expires_at, added_by)
            VALUES (?, ?, ?, NULL, ?)
            ON DUPLICATE KEY UPDATE tier = VALUES(tier), expires_at = NULL,
            name = COALESCE(VALUES(name), name), added_by = VALUES(added_by)]],
            { identifier, name, tier, by })
    end
    loadVips()
    return true, locale('vip_added', identifier, Config.Tiers[tier].label)
end

local function removeVip(identifier)
    if not validIdentifier(identifier) then return false, locale('invalid_target') end
    local affected = MySQL.update.await('DELETE FROM rsg_queue_vip WHERE identifier = ?', { identifier })
    loadVips()
    if not affected or affected < 1 then return false, locale('vip_not_found', identifier) end
    return true, locale('vip_removed', identifier)
end

-- server id -> license identifier + name, or pass an identifier through
local function resolveTarget(arg)
    local id = tonumber(arg)
    if id and GetPlayerName(id) then
        return GetPlayerIdentifierByType(id, 'license'), GetPlayerName(id)
    end
    if validIdentifier(arg) then return arg, nil end
    return nil
end

local function byName(src)
    if src == 0 then return 'console' end
    return GetPlayerName(src) or tostring(src)
end

---------------------------------
-- admin panel data
---------------------------------
local function getAdminData()
    sortQueue()
    local now, q = os.time(), {}
    for i, e in ipairs(Queue) do
        q[#q + 1] = { pos = i, src = e.src, name = e.name, label = e.label, priority = e.priority, waited = fmtTime(now - e.joined), grace = e.grace }
    end
    local rows = MySQL.query.await([[SELECT identifier, name, tier, DATE_FORMAT(expires_at, '%Y-%m-%d %H:%i') AS expires,
        (expires_at IS NOT NULL AND expires_at <= NOW()) AS expired, added_by FROM rsg_queue_vip ORDER BY tier, name]]) or {}
    local tiers = {}
    for k, t in pairs(Config.Tiers) do tiers[#tiers + 1] = { key = k, label = t.label, priority = t.priority } end
    table.sort(tiers, function(a, b) return a.priority > b.priority end)
    for _, r in ipairs(rows) do
        r.label = Config.Tiers[r.tier] and Config.Tiers[r.tier].label or r.tier
        r.expired = r.expired == 1 or r.expired == true
    end
    return {
        queue = q, vips = rows, tiers = tiers,
        online = #GetPlayers(), max = GetConvarInt('sv_maxclients', 48), reserved = Config.ReservedSlots,
    }
end

RSGCore.Functions.CreateCallback('rsg-queue:server:getAdminData', function(source, cb)
    if not RSGCore.Functions.HasPermission(source, Config.AdminPermission) then return cb(nil) end
    cb(getAdminData())
end)

RSGCore.Functions.CreateCallback('rsg-queue:server:adminAction', function(source, cb, action, data)
    if not RSGCore.Functions.HasPermission(source, Config.AdminPermission) then
        return cb({ ok = false, msg = locale('no_permission') })
    end
    data = type(data) == 'table' and data or {}
    local ok, msg = false, locale('invalid_target')

    if action == 'vip_add' then
        ok, msg = addVip(data.identifier, data.tier, data.days, data.name, byName(source))
    elseif action == 'vip_remove' then
        ok, msg = removeVip(data.identifier)
    elseif action == 'queue_front' or action == 'queue_remove' then
        local target = tonumber(data.src)
        for _, e in ipairs(Queue) do
            if e.src == target then
                if action == 'queue_front' then
                    local top = 0
                    for _, o in ipairs(Queue) do top = math.max(top, o.priority) end
                    e.priority, e.reserved = top + 1, true
                    ok, msg = true, locale('queue_moved')
                else
                    e.removed = true
                    ok, msg = true, locale('queue_removed')
                end
                break
            end
        end
    end
    cb({ ok = ok, msg = msg, data = getAdminData() })
end)

---------------------------------
-- commands
---------------------------------
RSGCore.Commands.Add('queue', locale('cmd_queue'), {}, false, function(source)
    TriggerClientEvent('rsg-queue:client:openAdmin', source, getAdminData())
end, Config.AdminPermission)

RSGCore.Commands.Add('vipadd', locale('cmd_vipadd'), {
    { name = 'target', help = locale('arg_target') },
    { name = 'tier', help = locale('arg_tier') },
    { name = 'days', help = locale('arg_days') },
}, true, function(source, args)
    local identifier, name = resolveTarget(args[1])
    if not identifier then return notify(source, locale('invalid_target'), 'error') end
    local ok, msg = addVip(identifier, args[2], args[3], name, byName(source))
    notify(source, msg, ok and 'success' or 'error')
end, Config.AdminPermission)

RSGCore.Commands.Add('vipremove', locale('cmd_vipremove'), {
    { name = 'target', help = locale('arg_target') },
}, true, function(source, args)
    local identifier = resolveTarget(args[1])
    if not identifier then return notify(source, locale('invalid_target'), 'error') end
    local ok, msg = removeVip(identifier)
    notify(source, msg, ok and 'success' or 'error')
end, Config.AdminPermission)

-- console only (txAdmin / Tebex): queuevip add <identifier|id> <tier> [days] | queuevip remove <identifier|id>
RegisterCommand('queuevip', function(source, args)
    if source ~= 0 then return end
    local identifier, name = resolveTarget(args[2])
    if not identifier then return print('[rsg-queue] ' .. locale('invalid_target')) end
    local ok, msg
    if args[1] == 'add' then
        ok, msg = addVip(identifier, args[3], args[4], name, 'console')
    elseif args[1] == 'remove' then
        ok, msg = removeVip(identifier)
    else
        return print('[rsg-queue] usage: queuevip add <identifier|id> <tier> [days] | queuevip remove <identifier|id>')
    end
    print(('[rsg-queue] %s%s^7'):format(ok and '^2' or '^1', msg))
end, true)

---------------------------------
-- exports
---------------------------------
exports('AddVip', function(identifier, tier, days, name) return addVip(identifier, tier, days, name, GetInvokingResource() or 'export') end)
exports('RemoveVip', removeVip)
exports('IsVip', function(identifier)
    local v = VipCache[identifier]
    if not v then return false end
    return true, v.tier, v.expires
end)
exports('GetQueueSize', function() return #Queue end)
exports('GetQueue', function()
    local q = {}
    for i, e in ipairs(Queue) do q[i] = { name = e.name, tier = e.tier, priority = e.priority, joined = e.joined } end
    return q
end)

---------------------------------
-- startup
---------------------------------
CreateThread(function()
    if Config.AutoDatabase and not ensureDatabase() then return end
    loadVips()
    Ready = true
    while true do
        Wait(Config.VipRefresh * 1000)
        loadVips()
    end
end)
