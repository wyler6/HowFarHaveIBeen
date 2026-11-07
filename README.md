# How Far Have I Been

A World of Warcraft addon for **WoW Forever** (patch 1.60.1, interface 16001) that measures how far your
character has travelled, split into walked, ran, swam, rode and "as a ghost". Totals are saved per character
(in yards) and shown in a small draggable panel, a tooltip, and via slash command.

## Install
Install it from CurseForge, or copy the addon files (`HowFarHaveIBeen.toc` and the `.lua` files) into a folder named
`HowFarHaveIBeen` under `<WoW>\_forever_\Interface\AddOns\` and enable it at the character select screen.

## Commands (`/howfar` or `/hfib`)
| Command | Effect |
|---|---|
| (none) | Summary: on-foot total (walked/ran), swam, rode, ghost, this session, all characters, next milestone |
| `show` / `hide` / `toggle` | Show or hide the panel |
| `lock` / `unlock` | Prevent or allow dragging |
| `units miles\|km\|yards` | Display units |
| `milestone <n> [miles\|km]` | Announce every n miles/km on foot and turn milestones on (default 5 miles; unit defaults to your display unit if miles or km) |
| `milestone progressive [miles\|km]` | Progressive milestones: every 1 up to 5, then 10, 20 ... 100, 200 ... 1000, 2000 ... in the chosen unit |
| `milestone off` | Turn milestones off (the step is remembered) |
| `milestone test` | Play the sound and print the local line; never posts to guild |
| `announce on\|off` | Turn the guild message on or off |
| `sound on\|off` | Turn the milestone sound on or off |
| `options` / `config` | Open or close the options window |
| `reset` / `reset confirm` | Erase this character's totals (needs `confirm`) |
| `debug` | Show which position/speed APIs work right now and the last measuring method |
| `help` | List commands |

The panel: left-drag to move (unless locked), right-click to open the options window. Hover for the full breakdown.

## Options window
Open it with right-click on the panel, `/howfar options` (or `/howfar config`, `/hfib options`), or the
**Open options** button in Esc > Options > AddOns > How Far Have I Been. Esc closes it, and it can be dragged.
Every change takes effect immediately, and the window re-reads your settings each time it opens, so slash-command
changes show up too.

- **Display:** show or hide the panel, lock its position, choose Miles / Kilometres / Yards, and reset the panel to its
  default position.
- **Milestones:** switch milestones on or off, set how often (**Every** a number above 0, or **Progressive**, in miles or km; press Enter or click away
  to apply, invalid input is reverted), post in guild chat, play the level-up sound, a **Test milestone** button (sound
  and local message only, never guild), and a live "next milestone" line. The milestone options are greyed out while
  milestones are off.
- **Data:** **Reset this character's totals...** asks for confirmation before erasing anything.

## Milestones
Whenever this character's on-foot distance (walked + ran) crosses a multiple of the milestone step, the addon:

1. plays the level-up sound (also in combat),
2. prints "Milestone! You've travelled 10 miles on foot." to your chat,
3. if guild announcements are on and you are in a guild, says to guild chat:
   `<First Last> has travelled 10 miles on foot!`.

The default is every 5 miles. Choose **progressive** (`/howfar milestone progressive` or the Options window) to get milestones every 1 up to 5, then 10, 20 ... 100, then every 100 up to 1000, and so on; switching modes never fires a milestone retroactively. Swimming, riding and ghost distance never trigger a milestone, and loading your saved
data never does either. Guild chat is not sent during combat or while chat messaging is locked down; the message is
queued and sent once, when combat ends or the lockdown lifts (retried every 5 s). `/howfar milestone test` plays the
sound and prints the local line but never posts to guild.

## How it measures
Every 0.25 s the addon samples your position. It prefers `UnitPosition` (world yards) and falls back to
`C_Map.GetPlayerMapPosition` scaled by `C_Map.GetMapWorldSize`. Each step is clipped to what your current speed could
produce (so boats, elevators and knockbacks are not credited), teleport-sized jumps are discarded, and gaps over
2 s (loading screens) are ignored. Where no position is available (e.g. instances) it integrates your speed over time.
Taxis, vehicles and being a corpse are excluded; standing still (including riding a boat, where your own speed is 0)
counts nothing. Speed below 4 yd/s on foot counts as walking, otherwise running.

Forever's "secret values" can make API results unusable; every value is guarded with `issecretvalue`, and distance
simply isn't counted when speed and position are both hidden. Chat output is queued during combat and printed when
combat ends, because printing in combat taints chat history on Forever.

Saved data lives in the account-wide `HowFarHaveIBeenDB`.

## Development
The repo root is the addon folder: `HowFarHaveIBeen.toc` and the `.lua` files sit at the top level, and
`.pkgmeta` keeps development files (`tests/`, `tools/`, `.github/`) out of the release zip.

### Running the tests
Offline, using Lua 5.1 via [lupa](https://pypi.org/project/lupa/) and a mocked WoW API. The Lua files are loaded
in the order listed in the `.toc`, so a file added there is picked up automatically.

    python -m venv venv
    venv\Scripts\activate        (Linux/macOS: source venv/bin/activate)
    pip install lupa
    python tests/run_tests.py

Exits non-zero on any failure. GitHub Actions runs the same thing on every push and pull request.

### Deploying to the game
Copies the `.toc`, the Lua files it lists, `README.md` and `CHANGELOG.md` to
`F:\World of Warcraft\_forever_\Interface\AddOns\HowFarHaveIBeen` (SavedVariables are never touched):

    pwsh tools/deploy.ps1
    pwsh tools/deploy.ps1 -WowAddOns "D:\Games\WoW\_forever_\Interface\AddOns"

Then `/reload` in game.

### Icon
The source is `art/logo.png`. To regenerate the in-game icon (`Media/icon.tga`) and the CurseForge logo:

    pip install Pillow numpy
    python tools/gen_icons.py

Upload `art/curseforge-logo-400.png` as the CurseForge project logo. Only `Media/icon.tga` ships; `art/` is ignored by `.pkgmeta`.

### Releasing
1. Bump `## Version` in `HowFarHaveIBeen.toc`.
2. Add a matching section to `CHANGELOG.md`.
3. Commit, then tag and push:

        git tag vX.Y.Z && git push origin vX.Y.Z

GitHub Actions runs the tests, packages the addon with
[BigWigsMods/packager](https://github.com/BigWigsMods/packager), uploads it to CurseForge, and
publishes a GitHub release for the tag with the same zip attached.

### One-time setup
1. Create the project on CurseForge and copy its Project ID from the "About Project" box.
2. Add `## X-Curse-Project-ID: <id>` to `HowFarHaveIBeen.toc`.
3. Create an API token at <https://authors.curseforge.com/#/settings/api-tokens> and add it as the `CF_API_TOKEN`
   repository secret (Settings > Secrets and variables > Actions).

The release workflow fails early, with a clear message, if either the project id or the token is missing.

## License

MIT. See [LICENSE](LICENSE).
