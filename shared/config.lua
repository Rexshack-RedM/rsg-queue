Config = {}

---------------------------------
-- database
---------------------------------
Config.AutoDatabase = true   -- create tables on start; set false and import install.sql to install manually

---------------------------------
-- general
---------------------------------
Config.Debug          = false
Config.ServerName     = 'My RSG Server'   -- shown at the top of the queue card
Config.CardImage      = ''                -- optional banner image url (https) for the queue card, '' = none
Config.UpdateInterval = 2000              -- ms between queue card refreshes
Config.MinCardTime    = 10                 -- seconds the queue card always shows, even with a free slot (0 = join instantly)
Config.ConnectTimeout = 180               -- seconds an admitted player may take to load in before their slot is freed
Config.VipRefresh     = 300               -- seconds between VIP cache reloads from the database (expiry)

---------------------------------
-- slots
---------------------------------
-- slots kept free for VIP/staff only. Public players can fill (sv_maxclients - ReservedSlots)
Config.ReservedSlots = 4

---------------------------------
-- permissions
---------------------------------
Config.AdminPermission = 'admin'           -- rsg-core permission for /queue, /vipadd, /vipremove
Config.StaffAce        = 'rsgqueue.staff'  -- ace that gives staff top priority + reserved slot access
Config.StaffPriority   = 100

---------------------------------
-- crash grace period
---------------------------------
-- players who drop keep a priority boost for a few minutes so they can rejoin quickly
Config.Grace = {
    enabled  = true,
    minutes  = 5,
    priority = 50,   -- added on top of any VIP priority
}

---------------------------------
-- VIP tiers (key is stored in the database)
---------------------------------
-- priority: higher goes first | reserved: may use reserved slots
Config.Tiers = {
    bronze = { label = 'Bronze', priority = 10, reserved = true },
    silver = { label = 'Silver', priority = 20, reserved = true },
    gold   = { label = 'Gold',   priority = 30, reserved = true },
}

---------------------------------
-- buttons shown on the queue card
---------------------------------
Config.Links = {
    { title = 'Discord',      url = 'https://discord.gg/yourinvite' },
    { title = 'Become a VIP', url = 'https://yourstore.tebex.io' },
}
