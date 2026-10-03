class_name FakeLiveLink
extends LiveTransport
## In-process connection between a LiveSender (this object is its LiveTransport) and a LiveReplica, with
## injectable faults: drop, duplicate, reorder, delay and backpressure. The sender's side accumulates messages in
## `wire`; deliver() moves them to the replica, feeding the replica's replies straight back to the sender.
## `faults` maps a 0-based message number to "drop", "dup", "swap" (exchange with the next message) or "delay:N"
## (hold back for N deliver() calls). `stalled` stops delivery entirely (backpressure: backlog_bytes() grows).

var sender: LiveSender
var replica: LiveReplica
var open := true
var stalled := false
var drop_all := false  # every message sent while set is lost
var faults: Dictionary = {}
var wire: Array = []  # {text: String} or {bin: PackedByteArray}, plus {hold: int}
var sent_count := 0
var delivered_texts := 0
var delivered_frames := 0
var max_backlog := 0
var now_msec := 0
var log: Array[String] = []  # types of text messages delivered, in order
var recording := false
var recorded: Array = []  # every delivered message when `recording`

var _backlog := 0
var _held: Dictionary = {}


func _init(p_sender: LiveSender, p_replica: LiveReplica) -> void:
	sender = p_sender
	replica = p_replica


func is_open() -> bool:
	return open


func backlog_bytes() -> int:
	return _backlog


func send_text(text: String) -> bool:
	return _put({"text": text}, text.length())


func send_binary(data: PackedByteArray) -> bool:
	return _put({"bin": data}, data.size())


func _put(msg: Dictionary, size: int) -> bool:
	if not open:
		return false
	msg["hold"] = 0
	msg["size"] = size
	var fault: String = faults.get(sent_count, "")
	sent_count += 1
	_backlog += size
	max_backlog = maxi(max_backlog, _backlog)
	if fault == "drop" or drop_all:
		_backlog -= size
		return true
	if fault.begins_with("delay:"):
		msg["hold"] = int(fault.substr(6))
	if fault == "swap":
		_held = msg  # goes out right after the next message
		return true
	wire.append(msg)
	if fault == "dup":
		wire.append(msg.duplicate())
		_backlog += size
	if not _held.is_empty():
		wire.append(_held)
		_held = {}
	return true


## Delivers up to `max_messages` queued messages (all by default) and the replica's replies. Returns the count.
func deliver(max_messages: int = 1 << 30) -> int:
	var n := 0
	var kept: Array = []
	for msg: Dictionary in wire:
		if stalled or n >= max_messages or int(msg.hold) > 0:
			if int(msg.hold) > 0:
				msg.hold = int(msg.hold) - 1
			kept.append(msg)
			continue
		n += 1
		_backlog -= int(msg.size)
		if recording:
			recorded.append(msg)
		if msg.has("text"):
			delivered_texts += 1
			log.append(_type_of(msg.text))
			replica.on_text(msg.text, now_msec)
		else:
			delivered_frames += 1
			replica.on_binary(msg.bin)
	wire = kept
	for reply in replica.take_outgoing():
		sender.on_text(reply)
	return n


func _type_of(text: String) -> String:
	var json := JSON.new()
	json.parse(text)
	return str((json.data as Dictionary).get("type", "?"))


## Feeds recorded messages [from, to) to the replica again (a duplicate delivery).
func redeliver(from: int, to: int) -> void:
	for i in range(from, mini(to, recorded.size())):
		var msg: Dictionary = recorded[i]
		if msg.has("text"):
			replica.on_text(msg.text, now_msec)
		else:
			replica.on_binary(msg.bin)
	for reply in replica.take_outgoing():
		sender.on_text(reply)


## Pumps, delivers and ticks until nothing moves (bounded). Returns the number of rounds.
func settle(max_rounds: int = 400) -> int:
	for round in max_rounds:
		now_msec += 100
		sender.tick(now_msec)
		sender.flush_snapshot()
		var moved := sender.pump(self)
		moved += deliver()
		replica.tick(now_msec)
		if moved == 0 and not sender.snapshot_pending() and wire.is_empty():
			return round
	return max_rounds
