# How Far Have I Been

*Because "are we there yet?" deserves a real answer.*

---

**How Far Have I Been** keeps count of how far your character has travelled in Azeroth. Walk, run, swim, ride, even wander around as a ghost: every yard is tallied per character and shown in a small panel you can put anywhere on your screen.

Built for **WoW Forever**.

---

## Features

- Tracks **on-foot distance** (walked and ran) for every character
- Separate totals for **swimming**, **mounted** and **ghost** travel
- Ignores flight paths, boats and zeppelins, teleports and loading screens, so only your own travel counts
- A **draggable panel** with a detailed tooltip: hover it for the full breakdown
- Totals for **this session** and for **all of your characters**
- **Milestones**: every N miles or km on foot, the level-up sound plays and a message goes to guild chat with your character's full Forever name (first name and surname)
- Guild messages are held back during combat or chat lockdown and sent as soon as it ends
- Choose miles, kilometres or yards
- A full **options window**, no commands required

---

## How to use it

- **Move the panel:** left-click and drag (unless you have locked it)
- **Open options:** right-click the panel, type `/howfar options`, or go to Esc > Options > AddOns > How Far Have I Been
- **See the breakdown:** hover over the panel

---

## Slash Commands

Use `/howfar` or `/hfib`.

| Command | Description |
|---|---|
| `/howfar` | Print a summary of your totals |
| `/howfar show` / `hide` / `toggle` | Show or hide the panel |
| `/howfar lock` / `unlock` | Stop or allow dragging the panel |
| `/howfar units miles\|km\|yards` | Choose display units |
| `/howfar milestone <n> [miles\|km]` | Announce every n miles or km and turn milestones on |
| `/howfar milestone off` | Turn milestones off |
| `/howfar milestone test` | Preview the sound and message locally (never posts to guild) |
| `/howfar announce on\|off` | Turn the guild message on or off |
| `/howfar sound on\|off` | Turn the milestone sound on or off |
| `/howfar options` | Open or close the options window |
| `/howfar reset confirm` | Erase this character's totals |
| `/howfar help` | List all commands |

---

## How distance is measured

The addon checks your position several times a second and adds up the real distance you moved. Where the game hides your position (inside instances, for example) it works it out from your speed and the time that passed instead. Taxis, boats, teleports, loading screens and being a corpse never add to your total, and neither does standing still.

---

## Milestones

Every time your on-foot distance (walked plus ran) passes a multiple of your chosen step, you get the level-up sound, a message in your chat, and, if you are in a guild and announcements are on, a guild message such as:

`Firstname Surname has travelled 10 miles on foot! (How Far Have I Been)`

The default is every 5 miles. Swimming, mounted and ghost distance never trigger a milestone.

---

## Installation

Install via the CurseForge app, or drop the `HowFarHaveIBeen` folder into your `_forever_/Interface/AddOns` directory and reload.

Made for **WoW Forever** (interface 16001).
