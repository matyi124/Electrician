extends Node

## Main script: switches between 2D and 3D views and wires UI buttons
## to the editor / room controllers.

@onready var editor2d: Node2D = $Editor2D
@onready var room3d: Node3D = $Room3D

@onready var btn_wall: Button = $CanvasLayer/HBoxContainer/ButtonWall
@onready var btn_door: Button = $CanvasLayer/HBoxContainer/ButtonDoor
@onready var btn_window: Button = $CanvasLayer/HBoxContainer/ButtonWindow
@onready var btn_3d: Button = $CanvasLayer/HBoxContainer/Button3D
@onready var btn_save: Button = $CanvasLayer/HBoxContainer/ButtonSave
@onready var btn_load: Button = $CanvasLayer/HBoxContainer/ButtonLoad
@onready var door_window_panel: Window = $CanvasLayer/DoorWindowPanel

var current_room_polygon: PackedVector2Array = PackedVector2Array()
var in_3d: bool = false

func _ready() -> void:
   # Make editor tool buttons toggleable
    btn_wall.toggle_mode = true
    btn_door.toggle_mode = true
    btn_window.toggle_mode = true
    btn_3d.toggle_mode = true

    btn_wall.button_pressed = false
    btn_door.button_pressed = false
    btn_window.button_pressed = false
    btn_3d.button_pressed = false
    # Connect editor signals
    if editor2d.has_signal("room_selected"):
        editor2d.connect("room_selected", Callable(self, "_on_room_selected"))
    if editor2d.has_signal("project_changed"):
        editor2d.connect("project_changed", Callable(self, "_on_project_changed"))
    if editor2d.has_signal("opening_placed"):
        editor2d.connect("opening_placed", Callable(self, "_on_opening_placed"))

    # Button signals ...
    btn_wall.pressed.connect(_on_wall_mode_pressed)
    btn_door.pressed.connect(_on_door_mode_pressed)
    btn_window.pressed.connect(_on_window_mode_pressed)
    btn_3d.pressed.connect(_on_3d_view_pressed)
    btn_save.pressed.connect(_on_save_pressed)
    btn_load.pressed.connect(_on_load_pressed)

    _show_2d()

func _show_2d() -> void:
    editor2d.visible = true
    room3d.visible = false
    in_3d = false
    btn_3d.button_pressed = false


func _show_3d() -> void:
    editor2d.visible = false
    room3d.visible = true
    in_3d = true
    btn_3d.button_pressed = true


func _on_wall_mode_pressed() -> void:
    if btn_wall.button_pressed:
        btn_door.button_pressed = false
        btn_window.button_pressed = false
        editor2d.call("set_mode_wall")
    else:
        editor2d.call("set_mode_none")


func _on_door_mode_pressed() -> void:
    if btn_door.button_pressed:
        btn_wall.button_pressed = false
        btn_window.button_pressed = false
        editor2d.call("set_mode_door")
    else:
        editor2d.call("set_mode_none")


func _on_window_mode_pressed() -> void:
    if btn_window.button_pressed:
        btn_wall.button_pressed = false
        btn_door.button_pressed = false
        editor2d.call("set_mode_window")
    else:
        editor2d.call("set_mode_none")



func _on_3d_view_pressed() -> void:
    # Ha már 3D-ben vagyunk, ugyanazzal a gombbal lépjünk vissza 2D-be
    if in_3d:
        _show_2d()
        return

    # Mindig az aktuális falakból számolunk szobapolygont
    var poly: PackedVector2Array = editor2d.call("get_room_polygon") as PackedVector2Array
    if poly.size() == 0:
        push_warning("Nincs zárt szoba a 3D nézethez. Zárd körbe a falakat.")
        btn_3d.button_pressed = false
        return

    var project_data: Dictionary = editor2d.call("get_project_data") as Dictionary

    room3d.call(
        "build_room",
        poly,
        project_data.get("walls", []),
        project_data.get("doors", []),
        project_data.get("windows", []),
        project_data.get("devices", [])
    )

    _show_3d()

func _on_opening_placed(is_door: bool) -> void:
    # Ajtó/ablak lerakása után automatikusan nyissuk meg a panelt
    door_window_panel.call("open_for_last_opening", is_door)

func _on_room_selected(polygon: PackedVector2Array) -> void:
    current_room_polygon = polygon

func _on_project_changed() -> void:
    # For auto-save later; currently empty.
    pass

func _on_save_pressed() -> void:
    editor2d.call("save_project")

func _on_load_pressed() -> void:
    editor2d.call("load_project")
