## All client UI, built in code: login, HUD, systems bar, target, chat, station window, system map.
extends CanvasLayer

const Hex = preload("res://scripts/shared/hex.gd")
const World = preload("res://scripts/shared/world_def.gd")
const Items = preload("res://scripts/shared/items_db.gd")

var client

# login
var login_panel: PanelContainer
var f_host: LineEdit
var f_port: LineEdit
var f_user: LineEdit
var f_pass: LineEdit
var l_status: Label

# hud
var hud: Control
var l_info: RichTextLabel
var bar_hp: ProgressBar
var bar_sh: ProgressBar
var bar_en: ProgressBar
var slot_box: HBoxContainer
var slot_buttons: Array = []
var target_panel: PanelContainer
var l_target: Label
var tbar_hp: ProgressBar
var tbar_sh: ProgressBar
var chat_log: RichTextLabel
var chat_edit: LineEdit
var toast_box: VBoxContainer
var help_panel: PanelContainer
var l_channel: Label
var map: Control

# station
var station_panel: PanelContainer
var st_title: Label
var tab_hangar: VBoxContainer
var tab_shop: VBoxContainer
var tab_market: VBoxContainer
var market_item: OptionButton
var market_qty: SpinBox
var market_price: SpinBox


func _ready() -> void:
	_build_login()
	_build_hud()
	_build_station()
	map = SystemMap.new()
	map.client = client
	map.visible = false
	map.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(map)
	client.player_changed.connect(_on_player_changed)
	client.station_changed.connect(_rebuild_station)
	client.docked_changed.connect(_on_docked_changed)
	show_login("")


# ================================================================ helpers

func _label(text := "", size := 14) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	b.focus_mode = Control.FOCUS_NONE
	return b


func _bar(col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(260, 18)
	b.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = col
	b.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.6)
	b.add_theme_stylebox_override("background", bg)
	var l := _label("", 12)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.name = "L"
	b.add_child(l)
	return b


func _set_bar(b: ProgressBar, v: float, m: float, label: String) -> void:
	b.max_value = maxf(m, 0.001)
	b.value = v
	b.get_node("L").text = "%s  %d / %d" % [label, int(ceil(v)), int(m)]


func _panel_style(alpha := 0.82) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.07, 0.12, alpha)
	s.border_color = Color(0.3, 0.45, 0.7, 0.8)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.set_content_margin_all(8)
	return s


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	return p


func _anchor(c: Control, preset: Control.LayoutPreset, margin: int) -> void:
	c.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE, margin)
	match preset:
		Control.PRESET_TOP_RIGHT, Control.PRESET_CENTER_RIGHT:
			c.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		Control.PRESET_CENTER_BOTTOM, Control.PRESET_CENTER_TOP:
			c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	match preset:
		Control.PRESET_BOTTOM_LEFT, Control.PRESET_CENTER_BOTTOM:
			c.grow_vertical = Control.GROW_DIRECTION_BEGIN
		Control.PRESET_CENTER_RIGHT:
			c.grow_vertical = Control.GROW_DIRECTION_BOTH


## Full-screen CenterContainer that lets clicks through to the game.
func _centered(parent: Node) -> CenterContainer:
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(cc)
	return cc


func _clear(c: Node) -> void:
	for ch in c.get_children():
		ch.queue_free()


# ================================================================ login

func _build_login() -> void:
	login_panel = _panel()
	login_panel.custom_minimum_size = Vector2(380, 0)
	_centered(self).add_child(login_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	login_panel.add_child(v)
	var title := _label("SPACE MMO", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := _label("A hex-grid solar system", 13)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	f_host = _field(v, "Server address", "127.0.0.1")
	f_port = _field(v, "Port", str(Net.DEFAULT_PORT))
	f_user = _field(v, "Pilot name (new names create an account)", "")
	f_pass = _field(v, "Password", "")
	f_pass.secret = true
	f_pass.text_submitted.connect(func(_t): _do_login())
	_load_login_prefs()
	v.add_child(_button("Connect", _do_login))
	var host_btn := _button("Start a local server on this PC", func():
		client.start_local_server(int(f_port.text))
		f_host.text = "127.0.0.1")
	v.add_child(host_btn)
	l_status = _label("", 13)
	l_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(l_status)


func _field(parent: Control, caption: String, value: String) -> LineEdit:
	parent.add_child(_label(caption, 12))
	var e := LineEdit.new()
	e.text = value
	parent.add_child(e)
	return e


func _load_login_prefs() -> void:
	var cf := ConfigFile.new()
	if cf.load("user://client.cfg") == OK:
		f_host.text = cf.get_value("login", "host", f_host.text)
		f_port.text = str(cf.get_value("login", "port", f_port.text))
		f_user.text = cf.get_value("login", "user", "")


func _do_login() -> void:
	var cf := ConfigFile.new()
	cf.set_value("login", "host", f_host.text)
	cf.set_value("login", "port", f_port.text)
	cf.set_value("login", "user", f_user.text)
	cf.save("user://client.cfg")
	client.connect_to(f_host.text.strip_edges(), int(f_port.text), f_user.text.strip_edges(), f_pass.text)


func login_status(t: String) -> void:
	l_status.text = t


func show_login(msg: String) -> void:
	login_panel.visible = true
	login_panel.get_parent().visible = true
	hud.visible = false
	station_panel.visible = false
	if map:
		map.visible = false
	login_status(msg)


func show_game() -> void:
	login_panel.get_parent().visible = false
	hud.visible = true


# ================================================================ HUD

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)

	# top-left info
	var info_p := _panel()
	info_p.position = Vector2(10, 10)
	info_p.custom_minimum_size = Vector2(360, 0)
	hud.add_child(info_p)
	l_info = RichTextLabel.new()
	l_info.bbcode_enabled = true
	l_info.fit_content = true
	l_info.scroll_active = false
	l_info.custom_minimum_size = Vector2(350, 0)
	l_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_p.add_child(l_info)

	# bottom centre: bars + systems
	var bottom := VBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(bottom)
	_anchor(bottom, Control.PRESET_CENTER_BOTTOM, 10)
	l_channel = _label("", 14)
	l_channel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bottom.add_child(l_channel)
	var bars := HBoxContainer.new()
	bars.alignment = BoxContainer.ALIGNMENT_CENTER
	bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_child(bars)
	bar_hp = _bar(Color(0.25, 0.75, 0.3))
	bar_sh = _bar(Color(0.25, 0.5, 0.95))
	bar_en = _bar(Color(0.9, 0.75, 0.2))
	bars.add_child(bar_hp)
	bars.add_child(bar_sh)
	bars.add_child(bar_en)
	slot_box = HBoxContainer.new()
	slot_box.alignment = BoxContainer.ALIGNMENT_CENTER
	slot_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_child(slot_box)

	# target panel top-right
	target_panel = _panel()
	target_panel.custom_minimum_size = Vector2(280, 0)
	hud.add_child(target_panel)
	_anchor(target_panel, Control.PRESET_TOP_RIGHT, 10)
	var tv := VBoxContainer.new()
	target_panel.add_child(tv)
	l_target = _label("", 14)
	tv.add_child(l_target)
	tbar_hp = _bar(Color(0.8, 0.3, 0.25))
	tbar_sh = _bar(Color(0.25, 0.5, 0.95))
	tv.add_child(tbar_hp)
	tv.add_child(tbar_sh)

	# chat bottom-left
	var chat_p := _panel()
	chat_p.custom_minimum_size = Vector2(380, 190)
	chat_p.add_theme_stylebox_override("panel", _panel_style(0.55))
	hud.add_child(chat_p)
	_anchor(chat_p, Control.PRESET_BOTTOM_LEFT, 10)
	var cv := VBoxContainer.new()
	chat_p.add_child(cv)
	chat_log = RichTextLabel.new()
	chat_log.bbcode_enabled = true
	chat_log.scroll_following = true
	chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_log.add_theme_font_size_override("normal_font_size", 13)
	cv.add_child(chat_log)
	chat_edit = LineEdit.new()
	chat_edit.placeholder_text = "Press Enter to chat  (/who, /where)"
	chat_edit.text_submitted.connect(_send_chat)
	cv.add_child(chat_edit)

	# toasts
	toast_box = VBoxContainer.new()
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(toast_box)
	_anchor(toast_box, Control.PRESET_CENTER_TOP, 70)

	# help
	help_panel = _panel()
	help_panel.visible = false
	_centered(hud).add_child(help_panel)
	var hl := _label("""CONTROLS
Right-click hex ........ move selected units
Right-click enemy ...... target it (selected drones attack)
Left-click enemy ....... set target
Left-click / drag ...... select your ship & drones (Shift adds)
1-9, 0 ................. activate system / use consumable on target
Right-click a system ... toggle auto-fire for that weapon
Tab .................... target nearest (mercs first)
F ...................... dock / undock (near a planet)
M ...................... system map (click to travel)
S stop   R recall drones   A select all units
Space .. re-centre camera   Middle-drag .. pan   Wheel .. zoom
Enter .. chat   H .. this help   Esc .. clear target""", 14)
	hl.add_theme_font_override("font", SystemFont.new())
	help_panel.add_child(hl)


func toggle_help() -> void:
	help_panel.visible = not help_panel.visible


func focus_chat() -> void:
	chat_edit.grab_focus()


func _send_chat(t: String) -> void:
	if t.strip_edges() != "":
		client.cmd("chat", {"text": t})
	chat_edit.text = ""
	chat_edit.release_focus()


func chat_line(from: String, text: String) -> void:
	if from == "":
		chat_log.append_text("[color=#8899aa]* %s[/color]\n" % text.replace("[", "(").replace("]", ")"))
	else:
		chat_log.append_text("[color=#66ccff]%s:[/color] %s\n" % [from, text.replace("[", "(").replace("]", ")")])


func toast(text: String, kind := "info") -> void:
	var l := _label(text, 16)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", {"error": Color(1, 0.5, 0.45), "good": Color(0.5, 1, 0.5)}.get(kind, Color(0.9, 0.95, 1)))
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	toast_box.add_child(l)
	while toast_box.get_child_count() > 5:
		toast_box.get_child(0).free()
	var tw := create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(l, "modulate:a", 0.0, 0.8)
	tw.tween_callback(l.queue_free)


func _on_player_changed() -> void:
	_rebuild_slots()
	_on_docked_changed()


func _rebuild_slots() -> void:
	_clear(slot_box)
	slot_buttons.clear()
	var i := 0
	var all: Array = client.system_slots() + client.consumable_slots()
	for s in all:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(110, 62)
		b.clip_text = true
		b.add_theme_font_size_override("font_size", 12)
		var idx := i
		b.pressed.connect(func(): client.activate_slot(idx))
		b.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT and not s.key.begins_with("item:"):
				var on: bool = not client.player.get("auto_fire", {}).get(s.key, false)
				client.cmd("auto", {"port": s.key, "on": on}))
		b.tooltip_text = "%s\n%s" % [s.def.name, s.def.get("desc", "")]
		slot_box.add_child(b)
		slot_buttons.append({"btn": b, "slot": s, "hotkey": str((i + 1) % 10)})
		i += 1


func _process(_delta: float) -> void:
	if not hud.visible:
		return
	var c = client
	var p: Dictionary = c.player
	var me: Dictionary = c.me
	var e: Dictionary = c.ents.get(c.my_id, {})
	var st: Dictionary = p.get("stats", {})
	var hp: float = e.get("hp", me.get("hp", 0))
	var sh: float = e.get("sh", me.get("sh", 0))
	_set_bar(bar_hp, hp, st.get("max_hp", 1), "HULL")
	_set_bar(bar_sh, sh, st.get("max_shield", 0), "SHIELD")
	_set_bar(bar_en, me.get("en", 0), me.get("men", st.get("max_energy", 1)), "ENERGY")

	# info
	var h: Vector2i = c.my_hex()
	var safe: String = c.world.safe_zone_at(h)
	var lvl: int = p.get("level", 1)
	var xp: int = p.get("xp", 0)
	var zone := World.zone_name(h)
	var where := "[color=#77ff88]SAFE ZONE (%s)[/color]" % World.get_planet(safe).get("name", "") if safe != "" else "[color=#ff6655]PVP - HOSTILE SPACE[/color]"
	if c.is_docked():
		where = "[color=#88ccff]DOCKED at %s[/color]" % World.get_planet(p.docked_at).name
	var dock_hint := ""
	if not c.is_docked() and c.world.dock_planet_at(h) != "":
		dock_hint = "\n[color=#88ccff]Press F to dock at %s[/color]" % World.get_planet(c.world.dock_planet_at(h)).name
	l_info.text = "[b]%s[/b]  Lv %d   [color=#aaaaaa](%d / %d xp)[/color]\nCredits: [color=#ffdd55]%d cr[/color]\n%s  [color=#aaaaaa]%s, threat T%d[/color]\nHex %d, %d   Speed %.1fs/hex   Drones %d\n%s%s" % [
		p.get("name", ""), lvl, xp, Items.xp_for_level(lvl + 1), p.get("credits", 0),
		Items.item_name(p.get("hull", "")), zone, World.zone_tier(h), h.x, h.y,
		st.get("move_ticks", 15) / float(World.TICK_RATE), me.get("drones", []).size(), where, dock_hint]

	# channel
	if me.has("ch"):
		var ch: Dictionary = me.ch
		l_channel.text = "Channeling %s ... %.1fs" % [ch.key, ch.left / float(World.TICK_RATE)]
	else:
		l_channel.text = ""

	# slots
	var cds: Dictionary = me.get("cd", {})
	var af: Dictionary = p.get("auto_fire", {})
	for sb in slot_buttons:
		var s: Dictionary = sb.slot
		var act: Dictionary = s.def.active
		var txt := "[%s] " % sb.hotkey
		if s.has("port"):
			txt += s.port.name
		else:
			txt += "x%d" % s.qty
		txt += "\n" + s.def.name
		var cd: int = cds.get(s.key, 0)
		if cd > 0:
			txt += "\nCD %.1fs" % (cd / float(World.TICK_RATE))
		else:
			var extra := []
			if act.get("energy", 0) > 0 and s.has("port"):
				extra.append("%d en" % act.energy)
			if act.has("range"):
				extra.append("r%d" % act.range)
			if af.get(s.key, false):
				extra.append("AUTO")
			txt += "\n" + " ".join(extra)
		sb.btn.text = txt
		var usable: bool = cd <= 0 and (not s.has("port") or me.get("en", 0) >= act.get("energy", 0))
		sb.btn.modulate = Color(1, 1, 1) if usable else Color(0.55, 0.55, 0.6)

	# target
	var t: Dictionary = c.ents.get(c.target_id, {})
	target_panel.visible = not t.is_empty()
	if not t.is_empty():
		var inf: Dictionary = c.info(c.target_id)
		var kind: String = inf.get("kind", "?")
		var rel := "Mercenary" if kind == "merc" else ("Drone" if kind == "drone" else "Pilot")
		l_target.text = "%s\n%s  -  %s  -  %d hexes" % [inf.get("name", "?"), rel, Items.item_name(inf.get("hull", "")) if kind != "drone" else "", Hex.distance(h, t.hex)]
		_set_bar(tbar_hp, t.hp, t.mhp, "HULL")
		_set_bar(tbar_sh, t.sh, t.msh, "SHIELD")
		tbar_sh.visible = t.msh > 0


# ================================================================ station

func _build_station() -> void:
	station_panel = _panel()
	station_panel.custom_minimum_size = Vector2(580, 640)
	station_panel.visible = false
	add_child(station_panel)
	_anchor(station_panel, Control.PRESET_CENTER_RIGHT, 10)
	var v := VBoxContainer.new()
	station_panel.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	st_title = _label("Station", 20)
	st_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(st_title)
	top.add_child(_button("Set as Home", func(): client.cmd("set_home")))
	top.add_child(_button("Undock (F)", func(): client.cmd("undock")))
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(tabs)
	tab_hangar = _scroll_tab(tabs, "Hangar & Cargo")
	tab_shop = _scroll_tab(tabs, "Shop")
	tab_market = _scroll_tab(tabs, "Player Market")


func _scroll_tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	return v


func _on_docked_changed() -> void:
	station_panel.visible = client.is_docked()
	_rebuild_station()


func _row(parent: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	parent.add_child(r)
	return r


func _item_label(id: String, extra := "") -> Label:
	var it := Items.get_item(id)
	var l := _label("%s%s  [%s]" % [it.get("name", id), extra, it.get("type", "")], 13)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.tooltip_text = _describe(id)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	return l


func _describe(id: String) -> String:
	var it := Items.get_item(id)
	var lines := [it.get("name", id), it.get("desc", ""), "Level %d   Price %d cr" % [it.get("level", 1), it.get("price", 0)]]
	if it.type == "hull":
		lines.append("Hull %d  Cargo %d  Energy %d  Speed %.1fs/hex" % [it.hp, it.cargo, it.energy, it.move_ticks / 6.0])
		var ps := []
		for p in it.ports:
			ps.append("%s(%s)" % [p.name, p.kind])
		lines.append("Ports: " + ", ".join(ps))
	for k in it.get("stats", {}):
		lines.append("%s: %s" % [k, it.stats[k]])
	var a: Dictionary = it.get("active", {})
	if not a.is_empty():
		var parts := []
		for k in ["effect", "damage", "amount", "range", "energy", "cooldown", "channel"]:
			if a.has(k):
				parts.append("%s %s" % [k, a[k]])
		lines.append("Active: " + ", ".join(parts))
	return "\n".join(lines)


func _rebuild_station() -> void:
	if not station_panel.visible:
		return
	var p: Dictionary = client.player
	var sd: Dictionary = client.station
	st_title.text = "%s Station   -   %d cr" % [World.get_planet(sd.get("planet", p.get("docked_at", ""))).get("name", "?"), p.get("credits", 0)]

	# ---- hangar
	_clear(tab_hangar)
	var hull := Items.get_item(p.get("hull", ""))
	tab_hangar.add_child(_label("SHIP: %s   (cargo %d / %d)" % [hull.get("name", "?"), p.get("cargo", []).size(), hull.get("cargo", 0)], 15))
	var eq: Dictionary = p.get("equipped", {})
	for port in hull.get("ports", []):
		var r := _row(tab_hangar)
		var pl := _label("%s (%s%s)" % [port.name, port.kind, (", arc %d°" % port.arc) if port.has("arc") else ""], 13)
		pl.custom_minimum_size.x = 190
		r.add_child(pl)
		if eq.has(port.id):
			r.add_child(_item_label(eq[port.id]))
			var pid: String = port.id
			r.add_child(_button("Unequip", func(): client.cmd("unequip", {"port": pid})))
		else:
			var el := _label("- empty -", 13)
			el.modulate = Color(0.6, 0.6, 0.6)
			el.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.add_child(el)
	tab_hangar.add_child(HSeparator.new())
	tab_hangar.add_child(_label("CARGO", 15))
	for s in p.get("cargo", []):
		var id: String = s.id
		var it := Items.get_item(id)
		var r := _row(tab_hangar)
		r.add_child(_item_label(id, " x%d" % int(s.qty)))
		if it.get("type", "") == "hull":
			r.add_child(_button("Fly", func(): client.cmd("set_hull", {"item": id})))
		elif it.has("slot"):
			var menu := MenuButton.new()
			menu.text = "Equip"
			menu.flat = false
			var targets := []
			for port in hull.get("ports", []):
				if Items.fits(id, port):
					targets.append(port.id)
					menu.get_popup().add_item(port.name)
			menu.get_popup().id_pressed.connect(func(i): client.cmd("equip", {"item": id, "port": targets[i]}))
			menu.disabled = targets.is_empty()
			r.add_child(menu)
		r.add_child(_button("Sell %d" % Items.sell_price(id), func(): client.cmd("sell", {"item": id, "qty": 1})))
		if int(s.qty) > 1:
			var q := int(s.qty)
			r.add_child(_button("Sell all", func(): client.cmd("sell", {"item": id, "qty": q})))

	# ---- shop
	_clear(tab_shop)
	for id in sd.get("shop", []):
		var it := Items.get_item(id)
		var r := _row(tab_shop)
		r.add_child(_item_label(id, "  Lv%d" % it.get("level", 1)))
		var pr := _label("%d cr" % it.price, 13)
		pr.custom_minimum_size.x = 70
		r.add_child(pr)
		var iid: String = id
		r.add_child(_button("Buy", func(): client.cmd("buy", {"item": iid, "qty": 1})))
		if Items.stack_size(id) > 1:
			r.add_child(_button("x10", func(): client.cmd("buy", {"item": iid, "qty": 10})))

	# ---- market
	_clear(tab_market)
	tab_market.add_child(_label("Listings at this station (other players can buy these, even while you're offline)", 12))
	var listings: Array = sd.get("market", [])
	if listings.is_empty():
		tab_market.add_child(_label("No listings.", 13))
	for l in listings:
		var r := _row(tab_market)
		r.add_child(_item_label(l.item, " x%d" % int(l.qty)))
		r.add_child(_label("%d cr ea  by %s" % [int(l.price), l.seller_name], 12))
		var lid := int(l.id)
		if l.seller == str(p.get("name", "")).to_lower():
			r.add_child(_button("Cancel", func(): client.cmd("market_cancel", {"listing": lid})))
		else:
			r.add_child(_button("Buy %d" % (int(l.price) * int(l.qty)), func(): client.cmd("market_buy", {"listing": lid})))
	tab_market.add_child(HSeparator.new())
	tab_market.add_child(_label("Sell to players:", 14))
	var r2 := _row(tab_market)
	market_item = OptionButton.new()
	market_item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ids := []
	for s in p.get("cargo", []):
		if not s.id in ids:
			ids.append(s.id)
			market_item.add_item(Items.item_name(s.id))
	r2.add_child(market_item)
	market_qty = SpinBox.new()
	market_qty.min_value = 1
	market_qty.max_value = 999
	market_qty.prefix = "qty"
	r2.add_child(market_qty)
	market_price = SpinBox.new()
	market_price.min_value = 1
	market_price.max_value = 10000000
	market_price.value = 100
	market_price.suffix = "cr"
	r2.add_child(market_price)
	r2.add_child(_button("List", func():
		if market_item.selected >= 0:
			client.cmd("market_list", {"item": ids[market_item.selected], "qty": int(market_qty.value), "price": int(market_price.value)})))


# ================================================================ system map

func toggle_map() -> void:
	map.visible = not map.visible


func map_visible() -> bool:
	return map.visible


class SystemMap extends Control:
	var client

	func _scale() -> float:
		return minf(size.x, size.y) * 0.47 / (World.MAP_RADIUS * Hex.STEP)

	func _process(_d: float) -> void:
		if visible:
			queue_redraw()

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			var wp: Vector2 = (ev.position - size * 0.5) / _scale()
			var h := Hex.from_pixel(wp)
			if Hex.distance(h, Vector2i.ZERO) <= World.MAP_RADIUS and not client.is_docked():
				client.order_move(h)
			accept_event()
		elif ev is InputEventKey:
			pass

	func _draw() -> void:
		var c := size * 0.5
		var s := _scale()
		var font := ThemeDB.fallback_font
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.02, 0.05, 0.93))
		draw_circle(c, World.MAP_RADIUS * Hex.STEP * s, Color(0.05, 0.07, 0.12))
		# zones
		for z in World.ZONES:
			draw_arc(c, z.max * Hex.STEP * s, 0, TAU, 128, Color(1, 0.3, 0.2, 0.05 + z.tier * 0.012), 1)
			var lp := c + Vector2(0, -(z.min + z.max) * 0.5 * Hex.STEP * s)
			draw_string(font, lp + Vector2(4, 4), "%s T%d" % [z.name, z.tier], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.6, 0.5, 0.6))
		draw_arc(c, (World.BELT_INNER + World.BELT_OUTER) * 0.5 * Hex.STEP * s, 0, TAU, 128, Color(0.5, 0.45, 0.4, 0.35), (World.BELT_OUTER - World.BELT_INNER) * Hex.STEP * s)
		draw_circle(c, World.SUN_RADIUS * Hex.STEP * s + 3, Color(1, 0.8, 0.3))
		for p in World.PLANETS:
			draw_arc(c, p.orbit * Hex.STEP * s, 0, TAU, 128, Color(1, 1, 1, 0.08), 1)
			var pp: Vector2 = c + client.world.planet_pos[p.id] * s
			draw_circle(pp, maxf(p.safe * Hex.STEP * s, 4), Color(0.3, 1, 0.4, 0.15))
			draw_circle(pp, maxf(p.radius * Hex.STEP * s, 3), p.color)
			draw_string(font, pp + Vector2(6, -6), p.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		var mh: Vector2i = client.my_hex()
		var mp: Vector2 = c + Hex.to_pixel(mh) * s
		draw_circle(mp, 5, Color(0.3, 1, 0.4))
		draw_arc(mp, 9, 0, TAU, 24, Color(0.3, 1, 0.4), 2)
		var g = client.me.get("goal")
		if g != null:
			var gp: Vector2 = c + Hex.to_pixel(g) * s
			draw_line(mp, gp, Color(0.3, 1, 0.4, 0.5), 1)
			draw_circle(gp, 3, Color(0.3, 1, 0.4))
		draw_string(font, Vector2(20, 30), "SYSTEM MAP  -  click to set a course  -  M to close", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
