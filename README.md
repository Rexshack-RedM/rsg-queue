# rsg-queue

**Version 1.1.0** · A modern connect queue for RSG Framework RedM servers. Players wait in line on a styled Adaptive Card, and VIP members you manage get priority, reserved slots and tiers.

Dependencies: `rsg-core`, `oxmysql` (no ox_lib).

Full developer and server owner documentation: [DOCS.md](DOCS.md)

## Features
- Queue card shown for a minimum time (`Config.MinCardTime`) so every player sees your banner and links
- Priority queue with a live Adaptive Card (position, tier, time waited, link buttons such as Discord and your store)
- Tiered VIP levels (Bronze / Silver / Gold by default, fully configurable)
- VIP with expiry (days) or permanent, stored in the database
- Reserved slots that only VIP members and staff can use
- Crash grace period: dropped players keep a priority boost for a few minutes
- Staff priority via an ace permission
- In-game admin panel (`/queue`): view the queue, move a player to the front, remove them, add or remove VIPs
- Console command for txAdmin and Tebex automation
- Database tables built automatically on first start
- 10 languages

## Installation
1. Put `rsg-queue` in your resources folder (for example `resources/[framework]/rsg-queue`).
2. Start it **after** `oxmysql` and `rsg-core`, and as early as possible after them:
   ```cfg
   ensure oxmysql
   ensure rsg-core
   ensure rsg-queue
   ```
3. Database: tables are created automatically on first start. To install manually, set `Config.AutoDatabase = false` and import `install.sql`.
4. Optional, give staff top priority:
   ```cfg
   add_ace group.admin rsgqueue.staff allow
   ```
5. Set your `sv_maxclients` as normal. The queue holds players whenever the server is full.

## Configuration (`shared/config.lua`)
| Option | Default | Description |
|---|---|---|
| `AutoDatabase` | `true` | Create tables on start; set false to use `install.sql` |
| `Debug` | `false` | Print queue activity to the console |
| `ServerName` | `'My RSG Server'` | Title on the queue card |
| `CardImage` | `''` | Optional banner image URL on the card |
| `UpdateInterval` | `2000` | ms between card refreshes |
| `MinCardTime` | `5` | Seconds the queue card always shows, even with a free slot (`0` = join instantly) |
| `ConnectTimeout` | `180` | Seconds an admitted player has to load in before their slot is freed |
| `VipRefresh` | `300` | Seconds between VIP reloads (for expiry) |
| `ReservedSlots` | `4` | Slots only VIPs and staff can use |
| `AdminPermission` | `'admin'` | rsg-core permission for admin commands and panel |
| `StaffAce` | `'rsgqueue.staff'` | Ace that gives staff priority and reserved access |
| `StaffPriority` | `100` | Priority given to staff |
| `Grace.enabled` | `true` | Enable crash grace |
| `Grace.minutes` | `5` | How long the boost lasts after dropping |
| `Grace.priority` | `50` | Priority added on reconnect |
| `Tiers` | bronze 10, silver 20, gold 30 | `label`, `priority`, `reserved` per tier |
| `Links` | Discord, Become a VIP | Buttons on the queue card |

## How to use
| Command | Permission | Description |
|---|---|---|
| `/queue` | admin | Open the queue admin panel |
| `/vipadd [id or identifier] [tier] [days]` | admin | Add or update a VIP (`0` days = permanent) |
| `/vipremove [id or identifier]` | admin | Remove a VIP |
| `queuevip add <id or identifier> <tier> [days]` | server console | For txAdmin / Tebex |
| `queuevip remove <id or identifier>` | server console | For txAdmin / Tebex |

Identifiers can be any player identifier, for example `license:abc123...` or `discord:123456789`. Using an online player's server ID stores their Rockstar license.

**Tebex example** (command on purchase): `queuevip add {discord} gold 30` (use `discord:{id}` if your Tebex variable does not include the prefix).

## Developer examples
```lua
-- server
local isVip, tier, expires = exports['rsg-queue']:IsVip('license:abc123')
exports['rsg-queue']:AddVip('discord:123456789', 'silver', 30, 'John Smith')
exports['rsg-queue']:RemoveVip('discord:123456789')
print(exports['rsg-queue']:GetQueueSize())
```

## Locales
`en`, `de`, `el`, `es`, `fr`, `ja`, `nl`, `pl`, `pt-br`, `ro` (set with `setr rsg:locale de`).

Support: https://buymeacoffee.com/rexshack
