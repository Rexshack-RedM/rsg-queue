# rsg-queue documentation

## Contents
1. [Architecture](#architecture)
2. [How the queue works](#how-the-queue-works)
3. [Priority rules](#priority-rules)
4. [Server exports](#server-exports)
5. [Events and callbacks](#events-and-callbacks)
6. [Commands](#commands)
7. [Database schema](#database-schema)
8. [Security model](#security-model)
9. [Server owner how-tos](#server-owner-how-tos)
10. [Troubleshooting](#troubleshooting)

## Architecture
| File | Purpose |
|---|---|
| `fxmanifest.lua` | Manifest, rsg-core locales, NUI files |
| `shared/config.lua` | All settings (tiers, slots, grace, links) |
| `server/server.lua` | Queue, deferrals and Adaptive Card, VIP cache and DB, admin callbacks, commands, exports |
| `client/client.lua` | Opens and closes the admin NUI and relays its actions |
| `html/` | Admin panel (house leather & gold style, custom dropdown) |
| `locales/*.json` | 10 languages, same keys |
| `install.sql` | Manual schema (same as auto-build) |

## How the queue works
1. `playerConnecting` defers the connection and reads the player's `license` identifier (players without one are rejected).
2. The player's priority is worked out (see below) and they are added to the queue. An older entry with the same license is dropped, so reconnect spam does not create duplicates.
3. A single server loop runs every second, sorts the queue (priority high to low, then join time) and admits the **first entry that fits a slot**:
   - Public players can fill up to `sv_maxclients - ReservedSlots`.
   - Entries with `reserved = true` (VIP tiers with `reserved`, staff, players moved to the front) can use all slots.
   This means a VIP behind a public player can still take a reserved slot.
4. Admitted players count as "connecting" until `playerJoining` fires or `ConnectTimeout` passes, so slots are not double-booked.
5. Once admitted, a player still sees the card until it has been on screen for `Config.MinCardTime` seconds (their slot is held meanwhile, and the `ConnectTimeout` load-in timer restarts when they actually join). Set it to `0` to join instantly.
6. While waiting, the card refreshes every `UpdateInterval` ms. Players who close the game leave the queue automatically.

## Priority rules
| Source | Priority | Reserved slot access |
|---|---|---|
| No VIP | 0 | No |
| VIP tier | `Config.Tiers[tier].priority` (highest matching identifier wins) | `Config.Tiers[tier].reserved` |
| Staff ace (`Config.StaffAce`) | `Config.StaffPriority` if higher | Yes |
| Crash grace | `+ Config.Grace.priority` on top of the above, within `Grace.minutes` of dropping | Unchanged |
| Admin "Front" | Current top priority + 1 | Yes |

VIPs are matched against **every** identifier the player has, so one row can use either `license:` or `discord:`. Expired rows are ignored and reloaded every `VipRefresh` seconds or straight after any change.

## Server exports
| Export | Parameters | Returns |
|---|---|---|
| `AddVip(identifier, tier, days, name?)` | identifier `type:value`, tier key, days (0 = permanent, max 3650), optional name | `ok, message` |
| `RemoveVip(identifier)` | identifier | `ok, message` |
| `IsVip(identifier)` | identifier | `false` or `true, tier, expiresUnix|nil` (cache) |
| `GetQueueSize()` | | number waiting |
| `GetQueue()` | | `{ name, tier, priority, joined }[]` in queue order |

```lua
local ok, msg = exports['rsg-queue']:AddVip('license:abc123', 'gold', 0, 'Arthur')
```

## Events and callbacks
| Name | Side | Description |
|---|---|---|
| `rsg-queue:client:openAdmin` (net) | client | Opens the panel with data. Only sent by the `/queue` command |
| `rsg-queue:server:getAdminData` (callback) | server | Returns `{ queue, vips, tiers, online, max, reserved }`; `nil` without permission |
| `rsg-queue:server:adminAction` (callback) | server | `(action, data)` with action `vip_add`, `vip_remove`, `queue_front`, `queue_remove`; returns `{ ok, msg, data }` |

## Commands
See README. Admin commands use rsg-core's permission system (`Config.AdminPermission`). `queuevip` only runs from the server console (source 0).

## Database schema
`rsg_queue_vip`
| Column | Type | Notes |
|---|---|---|
| `id` | INT AI | Primary key |
| `identifier` | VARCHAR(80) | Unique, e.g. `license:...`, `discord:...` |
| `name` | VARCHAR(100) | Optional display name |
| `tier` | VARCHAR(30) | Key from `Config.Tiers` |
| `expires_at` | DATETIME | `NULL` = permanent |
| `added_by` | VARCHAR(100) | Admin name, `console` or resource name |
| `created_at` | TIMESTAMP | Created time |

Adding a VIP that already exists updates its tier and expiry (it does not stack days).

## Security model
- Priority is decided only on the server from the database, aces and the server's own records. Nothing comes from the client.
- Both admin callbacks check `RSGCore.Functions.HasPermission(source, Config.AdminPermission)` on every call.
- Identifiers are validated (`type:value`, letters and digits only, max 80 chars), tiers must exist in config, days are clamped to 0–3650, and all SQL uses `?` parameters.
- NUI text is escaped before rendering.
- Scripts calling the exports must do their own permission checks before granting VIP.

## Server owner how-tos
- **Add a tier:** add `diamond = { label = 'Diamond', priority = 40, reserved = true }` to `Config.Tiers`, then restart.
- **Priority without reserved slots:** set `reserved = false` on that tier.
- **No reserved slots at all:** `Config.ReservedSlots = 0`.
- **Renaming a tier key:** existing rows with the old key are ignored; update them with SQL (`UPDATE rsg_queue_vip SET tier = 'new' WHERE tier = 'old'`).

## Troubleshooting
| Problem | Fix |
|---|---|
| Players connect instantly with no queue | The server is not full and `MinCardTime` is `0`; raise `MinCardTime` to always show the card |
| "database setup failed" in console | Check oxmysql connection string; or set `AutoDatabase = false` and import `install.sql` |
| VIP not getting priority | Check the stored identifier matches one the player has (`license:` vs `license2:`), and that it has not expired |
| Card stuck on "Checking your connection" | rsg-queue failed to start its database; see console |
| Staff not prioritised | Add `add_ace group.admin rsgqueue.staff allow` (or your group) to server.cfg |
| Another resource also defers connections | Fine, but start rsg-queue early so the queue card shows first |

Support: https://buymeacoffee.com/rexshack
