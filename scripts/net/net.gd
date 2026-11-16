## Network bridge (autoload "Net"). Every RPC lives here so the node path is identical
## on server and clients. Calls are forwarded to whichever handler is active.
extends Node

const PROTOCOL_VERSION := 1
const DEFAULT_PORT := 7777

var server_handler: Object = null # set on the dedicated server
var client_handler: Object = null # set on game clients


# ---------- client -> server ----------

@rpc("any_peer", "call_remote", "reliable")
func c_login(username: String, password: String, version: int) -> void:
	if server_handler:
		server_handler.on_login(multiplayer.get_remote_sender_id(), username, password, version)


@rpc("any_peer", "call_remote", "reliable")
func c_cmd(cmd: String, args: Dictionary) -> void:
	if server_handler:
		server_handler.on_cmd(multiplayer.get_remote_sender_id(), cmd, args)


# ---------- server -> client ----------

## Per-tick world snapshot (unreliable, newest wins).
@rpc("authority", "call_remote", "unreliable_ordered")
func s_state(data: Dictionary) -> void:
	if client_handler:
		client_handler.on_state(data)


## Reliable events: login result, entity info, inventory, chat, station data, notices.
@rpc("authority", "call_remote", "reliable")
func s_msg(type: String, data: Dictionary) -> void:
	if client_handler:
		client_handler.on_msg(type, data)


func send_msg(peer: int, type: String, data: Dictionary) -> void:
	s_msg.rpc_id(peer, type, data)


func send_state(peer: int, data: Dictionary) -> void:
	s_state.rpc_id(peer, data)
