## Entry point. Picks a mode from command-line arguments:
##   (no args)          game client with login screen
##   -- --server        dedicated headless server (also the default when run with --headless)
##   -- --bot NAME      headless test bot that connects, flies and fights
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var all := OS.get_cmdline_args()
	if "--bot" in args:
		add_child(preload("res://scripts/client/bot.gd").new())
	elif "--server" in args or "--server" in all or DisplayServer.get_name() == "headless":
		add_child(preload("res://scripts/server/server.gd").new())
	else:
		add_child(preload("res://scripts/client/client.gd").new())
