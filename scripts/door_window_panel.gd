extends Window
## Simple popup to edit last placed door / window dimensions.

signal values_applied(is_door: bool, width_cm: float, height_cm: float, sill_cm: float)

# true = door, false = window
var is_door: bool = true

@onready var width_edit: LineEdit  = $VBoxContainer/WidthEdit
@onready var height_edit: LineEdit = $VBoxContainer/HeightEdit
@onready var sill_edit: LineEdit   = $VBoxContainer/SillEdit
@onready var apply_button: Button  = $VBoxContainer/Button

# Editor2D node (we call update_last_opening on it)
@onready var editor2d: Node2D = get_node("../../Editor2D") as Node2D


func _ready() -> void:
	# start hidden
	visible = false

	# "OK" button
	apply_button.pressed.connect(_on_apply_pressed)

	# X gomb -> close_requested jel
	close_requested.connect(_on_close_requested)

	# Enter bármelyik mezőben -> alkalmaz + bezár
	width_edit.text_submitted.connect(_on_text_submitted)
	height_edit.text_submitted.connect(_on_text_submitted)
	sill_edit.text_submitted.connect(_on_text_submitted)


func open_for_last_opening(p_is_door: bool) -> void:
	## Called from Main.gd when we want to edit the last door/window.
	is_door = p_is_door

	# Fill defaults only if empty
	if width_edit.text == "":
		width_edit.text = "90" if is_door else "120"
	if height_edit.text == "":
		height_edit.text = "210" if is_door else "120"
	if sill_edit.text == "":
		sill_edit.text = "0" if is_door else "90"

	# Focus first field
	width_edit.grab_focus()

	popup_centered()


func _on_text_submitted(_text: String) -> void:
	_apply_and_close()


func _on_apply_pressed() -> void:
	_apply_and_close()


func _on_close_requested() -> void:
	# Only hide, do not change data
	hide()


func _apply_and_close() -> void:
	## Read values from LineEdits and send them back to Editor2D.
	var uj_szelesseg: float = float(width_edit.text)
	var uj_magassag: float = float(height_edit.text)
	var uj_parkany: float = float(sill_edit.text)

	# Update data model in Editor2D
	editor2d.call("update_last_opening", is_door, uj_szelesseg, uj_magassag, uj_parkany)

	# Emit optional signal if later Main.gd wants to listen
	emit_signal("values_applied", is_door, uj_szelesseg, uj_magassag, uj_parkany)

	hide()
