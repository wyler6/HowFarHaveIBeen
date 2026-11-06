"""Offline tests for HowFarHaveIBeen: runs the addon under Lua 5.1 (lupa) with a mocked WoW API.

Usage:  python tests/run_tests.py
Requires: pip install lupa
"""
import os
import sys
import traceback

try:
    from lupa import lua51 as lupa_rt
    RUNTIME = "lupa.lua51"
except ImportError:  # pragma: no cover
    try:
        from lupa import luajit21 as lupa_rt
        RUNTIME = "lupa.luajit21"
    except ImportError:
        import lupa as lupa_rt
        RUNTIME = "lupa (default runtime)"

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.dirname(HERE)  # the repo root IS the addon folder
ADDON = "HowFarHaveIBeen"
TOC_PATH = os.path.join(ADDON_DIR, ADDON + ".toc")


def read_toc_lua_files(path=TOC_PATH):
    """Every non-comment .toc line ending in .lua, in load order."""
    files = []
    with open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and line.lower().endswith(".lua"):
                files.append(line.replace("\\", "/"))
    if not files:
        raise SystemExit("No .lua files listed in %s" % path)
    return files


LUA_FILES = read_toc_lua_files()
DT = 0.05


def lpath(p):
    return p.replace("\\", "/")


class Env:
    """A fresh Lua state with the mock loaded and the addon started."""

    def __init__(self, db=None, start=True, setup=None):
        self.L = lupa_rt.LuaRuntime(unpack_returned_tuples=True)
        L = self.L
        self.G = L.globals()
        L.execute('dofile("%s")' % lpath(os.path.join(HERE, "wow_mock.lua")))
        self.MOCK = self.G.MOCK
        self.globals_before = set(self.G.keys())
        if setup:
            setup(self)
        if db is not None:
            self.G.HowFarHaveIBeenDB = db
        self.ns = L.table()
        loader = L.eval("function(path, name, ns) local f = assert(loadfile(path)); f(name, ns) end")
        for fname in LUA_FILES:
            loader(lpath(os.path.join(ADDON_DIR, *fname.split("/"))), ADDON, self.ns)
        if start:
            self.fire("ADDON_LOADED", ADDON)
            self.fire("PLAYER_LOGIN")
            self.fire("PLAYER_ENTERING_WORLD")

    # -- helpers ---------------------------------------------------------
    def tbl(self, **kw):
        return self.L.table_from(kw)

    def fire(self, event, *args):
        self.G.FireEvent(event, *args)

    def step(self, dt=DT):
        self.MOCK.time = self.MOCK.time + dt
        self.G.TickFrames(dt)

    def set_pos(self, x, y=0.0, inst=1):
        self.MOCK.unitPos = self.tbl(x=x, y=y, instanceID=inst)

    def set_map_pos(self, px, py=0.5):
        self.MOCK.mapPos = self.tbl(x=px, y=py)

    def run_line(self, seconds, speed, mode="unit", inst=1, x0=None):
        """Move along +x at `speed` yd/s for `seconds`, stepping 0.05 s."""
        self.MOCK.speed = speed
        n = int(round(seconds / DT))
        if mode == "unit":
            x = self.x_unit if x0 is None else x0
            for _ in range(n):
                x += speed * DT
                self.set_pos(x, 0.0, inst)
                self.step()
            self.x_unit = x
        elif mode == "map":
            w = self.MOCK.mapWorldSize[1]
            x = self.x_map if x0 is None else x0
            for _ in range(n):
                x += speed * DT
                self.set_map_pos(x / w)
                self.step()
            self.x_map = x
        else:  # "none": no position data at all
            for _ in range(n):
                self.step()

    x_unit = 100.0
    x_map = 400.0

    def totals(self):
        c = self.ns.char
        return {k: c[k] for k in ("walk", "run", "swim", "mount", "ghost")}

    def session(self):
        s = self.ns.GetSessionTotals()
        return {k: s[k] for k in ("walk", "run", "swim", "mount", "ghost")}

    def slash(self, text):
        self.G.SlashCmdList["HOWFAR"](text)

    def chat(self):
        return [v for _, v in sorted(self.MOCK.chat.items())]

    def texts(self):
        return [fs._text for _, fs in sorted(self.MOCK.fontStrings.items())]

    def tooltip(self):
        return [v for _, v in sorted(self.MOCK.tooltip.items())]


def approx(actual, expected, tol, label=""):
    assert abs(actual - expected) <= tol, "%s expected %s +/- %s, got %s" % (label, expected, tol, actual)


def only(env, cat, expected, tol):
    t = env.totals()
    approx(t[cat], expected, tol, cat)
    for k, v in t.items():
        if k != cat:
            assert v == 0, "%s should be 0, got %s" % (k, v)


# ---------------------------------------------------------------- tests
def t_a_run_unitposition():
    e = Env()
    e.run_line(10, 7)
    only(e, "run", 70, 1)


def t_b_walk():
    e = Env()
    e.run_line(10, 2.5)
    only(e, "walk", 25, 1)


def t_b2_stop_after_run_is_not_walk():
    # Regression (seen in real saved data): the sample taken just after the
    # player stops has speed 0, but the distance it credits was covered at run
    # speed, so it must count as "run", not "walk".
    e = Env()
    for _ in range(10):
        e.run_line(1.1, 7)   # 1.1 s ends between samples, leaving distance in flight
        e.MOCK.speed = 0
        for _ in range(20):  # stand still for 1 s
            e.step()
    only(e, "run", 77, 1)


def t_c_cmap_path():
    e = Env(setup=lambda e: setattr(e.MOCK, "unitPositionExists", False))
    e.MOCK.mapWorldSize = e.L.table_from({1: 4000, 2: 2600})
    e.run_line(10, 7, mode="map")
    only(e, "run", 70, 1)
    assert e.ns.lastMethod == "position"


def t_d_speed_integration():
    e = Env()
    e.run_line(10, 7, mode="none")
    only(e, "run", 70, 2)
    assert e.ns.lastMethod == "speed"


def t_e_secret_speed():
    e = Env()
    e.MOCK.secretSpeed = True
    e.run_line(10, 7)  # position available
    approx(e.totals()["run"], 70, 3, "run w/ secret speed + position")
    e2 = Env()
    e2.MOCK.secretSpeed = True
    e2.run_line(10, 7, mode="none")
    assert sum(e2.totals().values()) == 0
    assert e2.ns.lastMethod == "none"
    e2.slash("debug")  # debug must also cope with secret speed


def t_f_categories():
    e = Env()
    e.MOCK.mounted = True
    e.run_line(10, 14)
    only(e, "mount", 140, 3)
    e = Env()
    e.MOCK.swimming = True
    e.run_line(10, 4.7)
    only(e, "swim", 47, 2)
    e = Env()
    e.MOCK.ghost = True
    e.MOCK.dead = True  # a ghost is flagged dead too; must still be tracked
    e.run_line(10, 7)
    only(e, "ghost", 70, 2)


def t_g_taxi():
    e = Env()
    e.MOCK.taxi = True
    e.run_line(10, 30)
    assert sum(e.totals().values()) == 0
    assert sum(e.session().values()) == 0


def t_h_jump():
    e = Env()
    e.run_line(3, 7)
    e.x_unit += 500
    e.run_line(3, 7)
    t = e.totals()["run"]
    approx(t, 42, 3, "run")
    assert t < 60


def t_i_boat():
    e = Env()
    e.MOCK.speed = 0
    x = 100.0
    for _ in range(200):
        x += 0.35  # carried along at 7 yd/s by a boat
        e.set_pos(x)
        e.step()
    assert sum(e.totals().values()) == 0


def t_j_space_change():
    e = Env()
    e.run_line(5, 7, inst=1)
    e.x_unit = 90000.0
    e.run_line(5, 7, inst=2)
    approx(e.totals()["run"], 70, 3, "run (instanceID change)")
    e = Env(setup=lambda e: setattr(e.MOCK, "unitPositionExists", False))
    e.run_line(5, 7, mode="map")
    e.MOCK.mapID = 2
    e.run_line(5, 7, mode="map", x0=3000.0)
    approx(e.totals()["run"], 70, 3, "run (mapID change)")


def t_k_time_gap():
    e = Env()
    e.run_line(5, 7)
    e.MOCK.time = e.MOCK.time + 5  # loading screen
    e.run_line(5, 7)
    approx(e.totals()["run"], 70, 4, "run")
    assert e.totals()["run"] < 80


def t_l_existing_db():
    e = Env(start=False)  # the pre-existing DB must be built inside the env's own Lua state
    e.G.HowFarHaveIBeenDB = e.L.eval(
        '{version=1, settings={units="km"}, chars={["Old-Realm"]={walk=100,run=200,swim=1,mount=2,ghost=3,firstSeen=5}}}')
    e.fire("ADDON_LOADED", "SomeOtherAddon")
    e.fire("ADDON_LOADED", ADDON)
    db = e.G.HowFarHaveIBeenDB
    assert db.settings.units == "km"
    assert db.settings.locked is False and db.settings.hidden is False
    assert db.chars["Old-Realm"].walk == 100 and db.chars["Old-Realm"].firstSeen == 5
    e.fire("PLAYER_LOGIN")
    assert e.ns.charKey == "Tester-Forever", e.ns.charKey
    assert db.chars["Tester-Forever"].run == 0
    approx(e.ns.OnFoot(e.ns.GetAccountTotals()), 300, 0.001, "account on foot")


def t_m_format():
    e = Env()
    f = e.ns.Format
    assert f(1760, "miles") == "1.00 mi", f(1760, "miles")
    assert f(1000 / 0.9144, "km") == "1.00 km", f(1000 / 0.9144, "km")
    assert "1,234,567" in f(1234567, "yards"), f(1234567, "yards")
    assert f(1234567, "yards").endswith(" yd")


def t_n_slash():
    e = Env()
    e.run_line(5, 7)
    e.slash("units km")
    assert e.G.HowFarHaveIBeenDB.settings.units == "km"
    e.slash("units furlongs")
    assert e.G.HowFarHaveIBeenDB.settings.units == "km"
    assert any("Usage" in m for m in e.chat())
    before = e.totals()["run"]
    assert before > 0
    e.slash("reset")
    assert e.totals()["run"] == before
    assert any("reset confirm" in m for m in e.chat())
    e.slash("reset confirm")
    assert sum(e.totals().values()) == 0
    n = len(e.chat())
    e.slash("debug")
    assert len(e.chat()) > n + 3
    n = len(e.chat())
    e.slash("")
    summary = " ".join(e.chat()[n:])
    assert "on foot" in summary and "session" in summary and "All characters" in summary
    e.slash("hide")
    assert e.G.HowFarHaveIBeenDB.settings.hidden is True
    e.slash("toggle")
    assert e.G.HowFarHaveIBeenDB.settings.hidden is False
    e.slash("lock")
    assert e.G.HowFarHaveIBeenDB.settings.locked is True
    e.slash("unlock")
    assert e.G.HowFarHaveIBeenDB.settings.locked is False
    e.slash("help")
    e.slash("bogus")


def t_o_chat_deferral():
    e = Env()
    e.MOCK.inCombat = True
    e.slash("units yards")
    assert len(e.chat()) == 0
    e.MOCK.inCombat = False
    e.fire("PLAYER_REGEN_ENABLED")
    assert len(e.chat()) == 1 and "yards" in e.chat()[0]
    e.fire("PLAYER_REGEN_ENABLED")
    assert len(e.chat()) == 1  # not re-sent


def t_p_ui():
    e = Env()
    panel = e.G.HowFarHaveIBeenFrame
    assert panel._shown is True
    e.run_line(3, 7)
    e.run_line(2, 7)  # more than a refresh interval passes
    e.G.HowFarHaveIBeenDB.settings.units = "yards"
    e.run_line(2, 7)
    texts = e.texts()
    assert any(t.startswith("On foot: ") and " yd" in t and not t.startswith("On foot: 0 ") for t in texts), texts
    assert any("Session: " in t for t in texts)
    # right-click opens the options window (it no longer cycles units)
    s = e.G.HowFarHaveIBeenDB.settings
    s.units = "miles"
    panel._scripts.OnMouseUp(panel, "LeftButton")
    assert e.G.HowFarHaveIBeenOptions is None
    panel._scripts.OnMouseUp(panel, "RightButton")
    assert e.G.HowFarHaveIBeenOptions._shown is True
    assert s.units == "miles"
    # tooltip
    panel._scripts.OnEnter(panel)
    tip = "\n".join(e.tooltip())
    for needle in ("How Far Have I Been", "Walked", "Ran", "Swam", "Rode", "As a ghost", "Total (this character)",
                   "This session", "All characters (on foot)", "Tracking since", "Method: Position",
                   "Drag to move", "Right-click: options"):
        assert needle in tip, "missing %r in tooltip:\n%s" % (needle, tip)
    panel._scripts.OnLeave(panel)
    # drag saves position
    panel._point = e.L.eval('{"CENTER", nil, "CENTER", 12, 34}')
    panel._scripts.OnDragStop(panel)
    assert s.point[1] == "CENTER" and s.point[4] == 34


def t_p2_ui_hidden_setting():
    e = Env(start=False)
    e.G.HowFarHaveIBeenDB = e.L.eval('{settings={hidden=true}}')
    e.fire("ADDON_LOADED", ADDON)
    e.fire("PLAYER_LOGIN")
    assert e.G.HowFarHaveIBeenFrame._shown is False


def t_q_no_leaked_globals():
    e = Env()
    e.run_line(1, 7)
    e.slash("options")  # builds the window and registers the popup
    new = set(e.G.keys()) - e.globals_before
    allowed = {"HowFarHaveIBeenDB", "HowFarHaveIBeenFrame", "HowFarHaveIBeenOptions",
               "SLASH_HOWFAR1", "SLASH_HOWFAR2"}
    assert new <= allowed, "leaked globals: %s" % sorted(new - allowed)


def t_r_standing_still_and_robust():
    e = Env()
    e.MOCK.speed = 0
    e.set_pos(10, 10)
    for _ in range(100):
        e.step()
    assert sum(e.totals().values()) == 0
    # no C_Map, no UnitPosition, no speed API at all: must not error
    e = Env()
    e.G.C_Map = None
    e.G.UnitPosition = None
    e.MOCK.unitPositionExists = False
    e.G.GetUnitSpeed = None
    for _ in range(50):
        e.step()
    e.slash("debug")


def t_s_current_source_standing_still():
    e = Env()
    e.MOCK.speed = 0
    e.set_pos(10, 10)
    assert e.ns.CurrentSource() == "UnitPosition"
    e.slash("debug")
    assert any("Position source right now: UnitPosition" in m for m in e.chat()), e.chat()
    assert any("This session:" in m and "by position" in m and "by speed estimate" in m for m in e.chat())


def t_s2_current_source_map_and_none():
    e = Env(setup=lambda e: setattr(e.MOCK, "unitPositionExists", False))
    e.set_map_pos(0.1, 0.5)
    assert e.ns.CurrentSource() == "map"
    e.slash("debug")
    assert any("Position source right now: map coordinates" in m for m in e.chat())
    e = Env(setup=lambda e: setattr(e.MOCK, "unitPositionExists", False))
    assert e.ns.CurrentSource() is None
    e.slash("debug")
    assert any("Position source right now: none" in m for m in e.chat()), e.chat()


def t_s3_current_source_before_login():
    e = Env(start=False)
    e.G.Sync()
    assert e.ns.CurrentSource() is None  # no position set yet


def t_t_method_yards():
    e = Env()
    e.run_line(10, 7)
    my = e.ns.methodYards
    total = sum(e.session().values())
    assert my.position >= 0.95 * total, (my.position, total)
    assert 0 < my.speed < 0.05 * total, (my.speed, total)
    e = Env()
    e.run_line(10, 7, mode="none")
    my = e.ns.methodYards
    total = sum(e.session().values())
    approx(my.speed, total, 0.01, "speed yards")
    assert total > 60 and my.position == 0


def t_u_tooltip_method_line():
    e = Env()
    panel = e.G.HowFarHaveIBeenFrame
    e.run_line(2, 7)
    panel._scripts.OnEnter(panel)
    assert "Method: Position (UnitPosition)" in e.tooltip(), e.tooltip()
    e = Env(setup=lambda e: setattr(e.MOCK, "unitPositionExists", False))
    e.set_map_pos(0.1, 0.5)
    e.G.HowFarHaveIBeenFrame._scripts.OnEnter(e.G.HowFarHaveIBeenFrame)
    assert "Method: Position (map)" in e.tooltip(), e.tooltip()
    e = Env()
    e.run_line(2, 7, mode="none")
    e.MOCK.unitPos = None
    e.G.HowFarHaveIBeenFrame._scripts.OnEnter(e.G.HowFarHaveIBeenFrame)
    assert "Method: Speed estimate" in e.tooltip(), e.tooltip()


# ---------------------------------------------------------------- milestones
FIVE_MI = 5 * 1760


def ms_env(preload=FIVE_MI - 10, cmds=()):
    e = Env()
    for c in cmds:
        e.slash(c)
    e.ns.char["run"] = preload
    return e


def sent(e):
    return [(e.MOCK.sent[i].msg, e.MOCK.sent[i].chatType) for i in range(1, len(e.MOCK.sent) + 1)]


def sounds(e):
    return [(e.MOCK.sounds[i].id, e.MOCK.sounds[i].channel) for i in range(1, len(e.MOCK.sounds) + 1)]


def t_ms1_cross_guild_sound_chat():
    e = ms_env()
    e.run_line(3, 7)
    s = sent(e)
    assert len(s) == 1, s
    msg, kind = s[0]
    assert kind == "GUILD" and "5 miles" in msg and "Tester" in msg and "-Forever" not in msg, s
    assert msg == "Tester has travelled 5 miles on foot!", msg
    assert "|" not in msg and len(msg) < 255
    assert sounds(e) == [(888, "Master")], sounds(e)
    assert any("Milestone!" in m and "5 miles" in m for m in e.chat()), e.chat()
    # ms2: keep going, still under 10 miles
    e.run_line(10, 7)
    assert len(sent(e)) == 1 and len(sounds(e)) == 1


def t_ms3_not_in_guild():
    e = ms_env()
    e.MOCK.inGuild = False
    e.run_line(3, 7)
    assert sent(e) == [] and len(sounds(e)) == 1


def t_ms4_announce_and_sound_off():
    e = ms_env(cmds=["announce off"])
    assert any("off" in m for m in e.chat())
    e.run_line(3, 7)
    assert sent(e) == [] and len(sounds(e)) == 1
    e = ms_env(cmds=["sound off"])
    e.run_line(3, 7)
    assert len(sent(e)) == 1 and sounds(e) == []
    e.slash("sound on")
    e.slash("announce on")
    s = e.G.HowFarHaveIBeenDB.settings
    assert s.milestoneSound is True and s.announceGuild is True


def t_ms5_combat_deferral():
    e = ms_env()
    e.MOCK.inCombat = True
    e.run_line(3, 7)
    assert len(sounds(e)) == 1 and sent(e) == []
    assert not any("Milestone!" in m for m in e.chat())  # local line queued too
    e.MOCK.inCombat = False
    e.fire("PLAYER_REGEN_ENABLED")
    assert len(sent(e)) == 1 and "5 miles" in sent(e)[0][0]
    assert any("Milestone!" in m for m in e.chat())
    e.fire("PLAYER_REGEN_ENABLED")
    assert len(sent(e)) == 1


def t_ms6_chat_lockdown_retry():
    e = ms_env()
    e.MOCK.chatLockdown = True
    e.run_line(3, 7)
    assert sent(e) == [] and len(sounds(e)) == 1
    e.MOCK.speed = 0
    for _ in range(40):  # 2 s, still locked
        e.step()
    assert sent(e) == []
    e.MOCK.chatLockdown = False
    for _ in range(110):  # 5.5 s
        e.step()
    assert len(sent(e)) == 1, sent(e)
    for _ in range(120):
        e.step()
    assert len(sent(e)) == 1


def t_ms7_km():
    e = ms_env(preload=10 * 1000 / 0.9144 - 10, cmds=["milestone 10 km"])
    assert any("Milestones every 10 km" in m for m in e.chat()), e.chat()
    e.run_line(3, 7)
    s = sent(e)
    assert len(s) == 1 and "10 km" in s[0][0], s


def t_ms8_off():
    e = ms_env(cmds=["milestone off"])
    e.run_line(3, 7)
    assert sent(e) == [] and sounds(e) == []
    assert not any("Milestone!" in m for m in e.chat())
    st = e.G.HowFarHaveIBeenDB.settings
    assert st.milestonesOn is False and st.milestoneStep == 5  # step is kept while off


def t_ms9_swim_mount_ghost_no_milestone():
    e = ms_env()
    e.MOCK.swimming = True
    e.run_line(10, 4.7)
    assert sent(e) == [] and sounds(e) == []
    e = ms_env()
    e.MOCK.mounted = True
    e.run_line(10, 14)
    assert sent(e) == [] and sounds(e) == []


def t_ms10_test_command():
    e = Env()
    e.slash("milestone test")
    assert len(sounds(e)) == 1 and sent(e) == []
    assert any("Milestone!" in m for m in e.chat())
    assert any("guild" in m.lower() and "skipped" in m for m in e.chat())


def t_ms11_defaults_merge():
    e = Env(start=False)
    e.G.HowFarHaveIBeenDB = e.L.eval(
        '{version=1, settings={units="km", locked=true}, chars={["Tester-Forever"]={walk=0,run=99999,swim=0,mount=0,ghost=0,firstSeen=5}}}')
    e.fire("ADDON_LOADED", ADDON)
    e.fire("PLAYER_LOGIN")
    s = e.G.HowFarHaveIBeenDB.settings
    assert s.milestoneStep == 5 and s.milestoneUnit == "miles"
    assert s.announceGuild is True and s.milestoneSound is True
    assert s.units == "km" and s.locked is True
    assert sent(e) == [] and sounds(e) == []  # loading never triggers a milestone


def t_ms12_singular():
    e = ms_env(preload=1760 - 10, cmds=["milestone 1 miles"])
    e.run_line(3, 7)
    s = sent(e)
    assert len(s) == 1 and "1 mile on" in s[0][0] and "1 miles" not in s[0][0], s
    assert any("Milestones every 1 mile." in m for m in e.chat()), e.chat()


def t_ms13_summary_and_slash_validation():
    e = Env()
    e.slash("")
    assert any("Next milestone: 5 miles (5.00 to go)" in m for m in e.chat()), e.chat()
    e.slash("milestone 3")  # default display unit is miles
    s = e.G.HowFarHaveIBeenDB.settings
    assert s.milestoneStep == 3 and s.milestoneUnit == "miles"
    e.slash("units km")
    e.slash("milestone 2")
    assert s.milestoneStep == 2 and s.milestoneUnit == "km"
    e.slash("units yards")
    e.slash("milestone 4")
    assert s.milestoneUnit == "miles"
    for bad in ("milestone", "milestone -1", "milestone 0", "milestone abc", "milestone 5 furlongs"):
        n = len(e.chat())
        e.slash(bad)
        assert any("Usage" in m for m in e.chat()[n:]), bad
    assert s.milestoneStep == 4
    e.slash("announce maybe")
    e.slash("milestone off")
    n = len(e.chat())
    e.slash("")
    assert any("Milestones: off" in m for m in e.chat()[n:])
    e.slash("help")
    assert any("milestone" in m for m in e.chat())


# ---------------------------------------------------------------- options window
RESET_POPUP = "HOWFARHAVEIBEEN_RESET"


def widgets(e):
    return e.ns.Options.widgets


def click(w):
    w.Click(w)


def is_checked(w):
    return bool(w.GetChecked(w))


def is_enabled(w):
    return bool(w.IsEnabled(w))


def settings_of(e):
    return e.G.HowFarHaveIBeenDB.settings


def special_frames(e):
    return [v for _, v in e.G.UISpecialFrames.items()]


def opened(preload=None, cmds=()):
    e = Env()
    for c in cmds:
        e.slash(c)
    if preload is not None:
        e.ns.char["run"] = preload
    e.slash("options")
    return e


def t_opt01_slash_toggle_and_special_frames():
    e = Env()
    assert e.G.HowFarHaveIBeenOptions is None  # built lazily
    e.slash("options")
    win = e.G.HowFarHaveIBeenOptions
    assert win is not None and win._shown is True
    assert e.G.rawequal(e.ns.Options.frame, win)
    assert "HowFarHaveIBeenOptions" in special_frames(e)
    e.slash("options")
    assert win._shown is False
    e.slash("config")
    assert win._shown is True
    e.slash("config")
    assert win._shown is False
    assert special_frames(e).count("HowFarHaveIBeenOptions") == 1
    e.slash("help")
    assert any("options" in m and "config" in m for m in e.chat())


def t_opt02_widgets_reflect_settings_on_show():
    e = Env()
    e.slash("units km")
    e.slash("milestone 2 km")
    e.slash("options")
    w = widgets(e)
    assert is_checked(w.unitKm) and not is_checked(w.unitMiles) and not is_checked(w.unitYards)
    assert is_checked(w.stepKm) and not is_checked(w.stepMiles)
    assert w.step.GetText(w.step) == "2"
    assert is_checked(w.milestonesOn) and is_checked(w.showPanel) and not is_checked(w.lockPanel)
    # Slash changes made while hidden show up on the next open.
    e.slash("options")
    e.slash("units yards")
    e.slash("lock")
    e.slash("hide")
    e.slash("milestone off")
    e.slash("announce off")
    e.slash("sound off")
    e.slash("options")
    assert is_checked(w.unitYards) and not is_checked(w.unitKm)
    assert is_checked(w.lockPanel) and not is_checked(w.showPanel)
    assert not is_checked(w.milestonesOn) and not is_checked(w.announceGuild) and not is_checked(w.sound)
    assert w.step.GetText(w.step) == "2"
    assert "Milestones: off" in w.nextText.GetText(w.nextText)


def t_opt03_show_and_lock_checkboxes():
    e = opened()
    w = widgets(e)
    panel = e.G.HowFarHaveIBeenFrame
    s = settings_of(e)
    click(w.showPanel)
    assert s.hidden is True and panel._shown is False
    click(w.showPanel)
    assert s.hidden is False and panel._shown is True
    click(w.lockPanel)
    assert s.locked is True
    click(w.lockPanel)
    assert s.locked is False


def t_opt04_units_radios():
    e = opened()
    w = widgets(e)
    s = settings_of(e)
    e.run_line(3, 7)
    click(w.unitKm)
    assert s.units == "km"
    assert is_checked(w.unitKm) and not is_checked(w.unitMiles) and not is_checked(w.unitYards)
    assert any(t.startswith("On foot") and "km" in t for t in e.texts()), e.texts()
    click(w.unitYards)
    assert s.units == "yards" and is_checked(w.unitYards) and not is_checked(w.unitKm)
    click(w.unitYards)  # clicking the selected radio keeps it selected
    assert s.units == "yards" and is_checked(w.unitYards)
    click(w.unitMiles)
    assert s.units == "miles" and is_checked(w.unitMiles) and not is_checked(w.unitYards)


SUB_CONTROLS = ("step", "stepMiles", "stepKm", "announceGuild", "sound", "test")


def t_opt05_milestones_toggle():
    e = opened(preload=FIVE_MI - 10)
    w = widgets(e)
    s = settings_of(e)
    click(w.milestonesOn)
    assert s.milestonesOn is False
    for name in SUB_CONTROLS:
        assert not is_enabled(w[name]), name
    assert is_enabled(w.milestonesOn)
    assert "Milestones: off" in w.nextText.GetText(w.nextText)
    n = len(e.chat())
    e.run_line(3, 7)
    assert sounds(e) == [] and sent(e) == []
    assert not any("Milestone!" in m for m in e.chat()[n:])
    click(w.milestonesOn)
    assert s.milestonesOn is True and s.milestoneStep == 5
    assert w.step.GetText(w.step) == "5"
    for name in SUB_CONTROLS:
        assert is_enabled(w[name]), name
    assert "Next milestone: 5 miles" in w.nextText.GetText(w.nextText)
    # Now on again: a boundary crossing announces.
    e.ns.char["run"] = FIVE_MI * 2 - 10
    e.run_line(3, 7)
    assert len(sent(e)) == 1 and len(sounds(e)) == 1, (sent(e), sounds(e))


def t_opt05b_disabled_controls_ignore_clicks():
    e = opened(cmds=["milestone off"])
    w = widgets(e)
    assert not is_enabled(w.test) and not is_enabled(w.announceGuild)
    click(w.test)
    click(w.announceGuild)
    assert sounds(e) == [] and settings_of(e).announceGuild is True


def t_opt06_step_editbox():
    e = opened()
    w = widgets(e)
    box = w.step
    s = settings_of(e)
    box.SetText(box, "3")
    box._scripts.OnEnterPressed(box)
    assert s.milestoneStep == 3 and box.GetText(box) == "3"
    for bad in ("abc", "-1", "0", "", "1000000", "inf"):
        box.SetText(box, bad)
        box._scripts.OnEnterPressed(box)
        assert s.milestoneStep == 3, bad
        assert box.GetText(box) == "3", (bad, box.GetText(box))
    box.SetText(box, "7")
    box._scripts.OnEditFocusLost(box)
    assert s.milestoneStep == 7 and box.GetText(box) == "7"
    box.SetText(box, "oops")
    box._scripts.OnEditFocusLost(box)
    assert s.milestoneStep == 7 and box.GetText(box) == "7"
    box.SetText(box, "2.5")
    box._scripts.OnEnterPressed(box)
    assert s.milestoneStep == 2.5 and box.GetText(box) == "2.5"
    # a real focus cycle also applies
    box.SetText(box, "4")
    box.SetFocus(box)
    box.ClearFocus(box)
    assert s.milestoneStep == 4
    # milestone unit radios
    click(w.stepKm)
    assert s.milestoneUnit == "km" and is_checked(w.stepKm) and not is_checked(w.stepMiles)
    click(w.stepMiles)
    assert s.milestoneUnit == "miles" and is_checked(w.stepMiles) and not is_checked(w.stepKm)
    # the live text follows the step
    box.SetText(box, "6")
    box._scripts.OnEnterPressed(box)
    e.slash("options")
    e.slash("options")
    assert "Next milestone: 6 miles" in w.nextText.GetText(w.nextText)


def t_opt07_guild_and_sound_checkboxes():
    e = opened()
    w = widgets(e)
    s = settings_of(e)
    click(w.announceGuild)
    assert s.announceGuild is False
    click(w.sound)
    assert s.milestoneSound is False
    click(w.announceGuild)
    click(w.sound)
    assert s.announceGuild is True and s.milestoneSound is True


def t_opt08_test_button():
    e = opened(cmds=["sound off"])
    w = widgets(e)
    click(w.test)
    assert len(sounds(e)) == 1 and sent(e) == []  # test always sounds, never messages the guild
    assert any("Milestone!" in m for m in e.chat())


def t_opt09_reset_totals():
    e = opened()
    e.run_line(5, 7)
    w = widgets(e)
    before = e.totals()["run"]
    assert before > 0
    click(w.resetTotals)
    assert [e.MOCK.popups[i] for i in range(1, len(e.MOCK.popups) + 1)] == [RESET_POPUP]
    assert e.totals()["run"] == before  # nothing changes until confirmed
    dlg = e.G.StaticPopupDialogs[RESET_POPUP]
    assert dlg.text == "Erase all distance totals for this character?"
    assert dlg.timeout == 0 and dlg.whileDead is True and dlg.hideOnEscape is True
    assert dlg.button1 and dlg.button2
    dlg.OnAccept()
    assert sum(e.totals().values()) == 0


def t_opt10_reset_position():
    e = opened()
    w = widgets(e)
    panel = e.G.HowFarHaveIBeenFrame
    s = settings_of(e)
    panel._point = e.L.eval('{"CENTER", nil, "CENTER", 12, 34}')
    panel._scripts.OnDragStop(panel)
    assert s.point is not None
    click(w.resetPosition)
    assert s.point is None
    assert panel._point[1] == "TOP" and panel._point[5] == -120


def t_opt11_settings_registration():
    e = Env(start=False)
    assert len(e.MOCK.settingsCategories) == 0  # never at file load
    e.fire("ADDON_LOADED", ADDON)
    assert len(e.MOCK.settingsCategories) == 0
    e.fire("PLAYER_LOGIN")
    assert len(e.MOCK.settingsCategories) == 1 and len(e.MOCK.settingsRegistered) == 1
    cat = e.MOCK.settingsCategories[1]
    assert cat.name == "How Far Have I Been" and cat.GetID() == 77
    assert e.G.rawequal(e.MOCK.settingsRegistered[1], cat)
    e.fire("PLAYER_LOGIN")
    e.fire("PLAYER_ENTERING_WORLD")
    assert len(e.MOCK.settingsCategories) == 1 and len(e.MOCK.settingsRegistered) == 1
    assert any("walked, run, swum and ridden" in t for t in e.texts())
    btn = e.ns.Options.canvasButton
    assert btn.GetText(btn) == "Open options"
    assert e.G.HowFarHaveIBeenOptions is None
    btn._scripts.OnClick(btn)
    assert e.G.HowFarHaveIBeenOptions._shown is True
    assert e.G.rawequal(e.MOCK.hiddenPanels[1], e.G.SettingsPanel)
    # no Settings API: silently skipped
    e = Env(setup=lambda e: setattr(e.G, "Settings", None))
    assert len(e.MOCK.settingsCategories) == 0 and e.ns.Options.canvasButton is None
    e.slash("options")
    assert e.G.HowFarHaveIBeenOptions._shown is True


def t_opt12_migration():
    for bad in ("0", "-3", '"abc"'):
        e = Env(start=False)
        e.G.HowFarHaveIBeenDB = e.L.eval('{settings={milestoneStep=%s}}' % bad)
        e.fire("ADDON_LOADED", ADDON)
        e.fire("PLAYER_LOGIN")
        s = settings_of(e)
        assert s.milestonesOn is False and s.milestoneStep == 5, bad
    e = Env(start=False)
    e.G.HowFarHaveIBeenDB = e.L.eval('{settings={milestoneStep=10}}')
    e.fire("ADDON_LOADED", ADDON)
    e.fire("PLAYER_LOGIN")
    s = settings_of(e)
    assert s.milestonesOn is True and s.milestoneStep == 10
    e = Env()  # fresh install
    assert settings_of(e).milestonesOn is True and settings_of(e).milestoneStep == 5
    # slash: setting a step turns milestones back on
    e.slash("milestone off")
    assert settings_of(e).milestonesOn is False
    e.slash("milestone 3")
    assert settings_of(e).milestonesOn is True and settings_of(e).milestoneStep == 3


def t_opt13_right_click_opens_options():
    e = Env()
    panel = e.G.HowFarHaveIBeenFrame
    panel._scripts.OnMouseUp(panel, "RightButton")
    win = e.G.HowFarHaveIBeenOptions
    assert win._shown is True
    panel._scripts.OnMouseUp(panel, "RightButton")
    assert win._shown is False


def t_opt14_next_text_updates():
    e = opened()
    w = widgets(e)
    before = w.nextText.GetText(w.nextText)
    assert before.startswith("Next milestone: 5 miles (5.00 to go)"), before
    e.run_line(3, 7)
    after = w.nextText.GetText(w.nextText)
    assert after.startswith("Next milestone: 5 miles") and after != before, (before, after)
    # hidden: the timer does not touch it
    e.slash("options")
    e.run_line(3, 7)
    assert w.nextText.GetText(w.nextText) == after


# ---------------------------------------------------------------- full name / surname
def surname_env(surname, name="Tester", setup=None):
    def _setup(env):
        env.MOCK.surname = surname
        env.MOCK.name = name
        if setup:
            setup(env)
    e = Env(setup=_setup)
    e.MOCK.surname = surname
    e.ns.char["run"] = FIVE_MI - 10
    e.run_line(3, 7)
    return e


def t_nm1_guild_message_full_name():
    e = surname_env("Ashvale")
    s = sent(e)
    assert len(s) == 1, s
    assert s[0][0] == "Tester Ashvale has travelled 5 miles on foot!", s
    assert any("Milestone! You've travelled 5 miles on foot." in m for m in e.chat()), e.chat()


def t_nm2_no_surname():
    for sn in (None, ""):
        e = surname_env(sn)
        assert sent(e)[0][0] == "Tester has travelled 5 miles on foot!", sent(e)


def t_nm3_secret_surname():
    e = surname_env(None, setup=lambda env: setattr(env.MOCK, "surname", env.MOCK.SECRET))
    assert sent(e)[0][0].startswith("Tester has travelled 5 miles"), sent(e)


def t_nm4_no_doubled_surname():
    e = surname_env("Ashvale", name="Tester Ashvale")
    assert sent(e)[0][0] == "Tester Ashvale has travelled 5 miles on foot!", sent(e)


def t_nm5_separator_constant():
    def setup(env):
        env.L.execute('Constants = {CharacterNameSeparatorConsts = {CHARACTERNAME_SURNAME_SEPARATOR = "_"}}')
    e = surname_env("Ashvale", setup=setup)
    assert sent(e)[0][0].startswith("Tester_Ashvale has travelled"), sent(e)
    assert e.ns.charKey == "Tester_Ashvale-Forever", e.ns.charKey


def t_nm6_summary_full_name():
    e = Env(setup=lambda env: setattr(env.MOCK, "surname", "Ashvale"))
    e.slash("")
    first = [m for m in e.chat() if "on foot:" in m][0]
    assert "Tester Ashvale on foot:" in first and "Forever" not in first, first


def preload_env(chars_lua, surname):
    e = Env(start=False)
    e.MOCK.surname = surname
    e.G.HowFarHaveIBeenDB = e.L.eval('{version=1, settings={}, chars=%s}' % chars_lua)
    e.fire("ADDON_LOADED", ADDON)
    e.fire("PLAYER_LOGIN")
    return e


def t_nm7_migration():
    e = preload_env('{["Tester-Forever"]={walk=0,run=500,swim=0,mount=0,ghost=0,firstSeen=5}}', "Ashvale")
    chars = e.G.HowFarHaveIBeenDB.chars
    assert e.ns.charKey == "Tester Ashvale-Forever", e.ns.charKey
    assert chars["Tester Ashvale-Forever"].run == 500 and chars["Tester Ashvale-Forever"].firstSeen == 5
    assert chars["Tester-Forever"] is None
    assert e.ns.char.run == 500
    approx(e.ns.OnFoot(e.ns.GetAccountTotals()), 500, 0.001, "account on foot")


def t_nm8_no_migration_overwrite():
    e = preload_env('{["Tester-Forever"]={walk=0,run=500,swim=0,mount=0,ghost=0,firstSeen=5},'
                    '["Tester Ashvale-Forever"]={walk=0,run=77,swim=0,mount=0,ghost=0,firstSeen=9}}', "Ashvale")
    chars = e.G.HowFarHaveIBeenDB.chars
    assert chars["Tester Ashvale-Forever"].run == 77 and chars["Tester Ashvale-Forever"].firstSeen == 9
    assert chars["Tester-Forever"].run == 500
    assert e.ns.char.run == 77


def t_nm9_no_surname_keeps_old_key():
    e = preload_env('{["Tester-Forever"]={walk=0,run=500,swim=0,mount=0,ghost=0,firstSeen=5}}', None)
    chars = e.G.HowFarHaveIBeenDB.chars
    assert e.ns.charKey == "Tester-Forever", e.ns.charKey
    assert chars["Tester-Forever"].run == 500 and e.ns.char.run == 500


TESTS = [(n[2:], f) for n, f in sorted(globals().items()) if n.startswith("t_") and callable(f)]


def main():
    print("Lua runtime: %s (%s)" % (RUNTIME, lupa_rt.LuaRuntime().eval("_VERSION")))
    failed = 0
    for name, fn in TESTS:
        try:
            fn()
            print("PASS  %s" % name)
        except Exception:
            failed += 1
            print("FAIL  %s" % name)
            traceback.print_exc()
    print("\n%d passed, %d failed" % (len(TESTS) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
