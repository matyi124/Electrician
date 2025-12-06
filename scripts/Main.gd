extends Node

## Main script: switches between 2D and 3D views and wires UI buttons
## to the editor / room controllers.

@onready var editor2d: Node2D = $Editor2D
@onready var room3d: Node3D = $Room3D

@onready var room_menu: MenuButton = $CanvasLayer/HBoxContainer/RoomMenuButton
@onready var btn_room_rename: Button = $CanvasLayer/HBoxContainer/ButtonRenameRoom

@onready var dlg_room_rename: AcceptDialog = $CanvasLayer/RoomRenameDialog
@onready var dlg_room_name_edit: LineEdit = $CanvasLayer/RoomRenameDialog/VBoxContainer/NameEdit

var current_room_index: int = -1


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
    # Szobamenü popup kezelése
    var popup := room_menu.get_popup()
    popup.index_pressed.connect(_on_room_menu_index_pressed)

    btn_room_rename.pressed.connect(_on_room_rename_pressed)
    dlg_room_rename.confirmed.connect(_on_room_rename_confirmed)

    _refresh_room_menu()
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

func _refresh_room_menu() -> void:
    var rooms: Array = editor2d.call("get_room_names") as Array
    var popup := room_menu.get_popup()
    popup.clear()
    for i in range(rooms.size()):
        popup.add_item(rooms[i], i)

    room_menu.text = "Szobák"
    current_room_index = -1
    btn_room_rename.disabled = true

func _on_room_menu_index_pressed(idx: int) -> void:
    var rooms: Array = editor2d.call("get_room_names") as Array
    if idx < 0 or idx >= rooms.size():
        return

    current_room_index = idx
    room_menu.text = rooms[idx]
    btn_room_rename.disabled = false

    # Szoba középre hozása
    editor2d.call("focus_room", idx)

func _on_room_rename_pressed() -> void:
    if current_room_index < 0:
        return
    var rooms: Array = editor2d.call("get_room_names") as Array
    if current_room_index >= rooms.size():
        return

    dlg_room_name_edit.text = rooms[current_room_index]
    dlg_room_rename.popup_centered()
    dlg_room_name_edit.grab_focus()
    dlg_room_name_edit.caret_column = dlg_room_name_edit.text.length()

func _on_room_rename_confirmed() -> void:
    if current_room_index < 0:
        return
    var new_name := dlg_room_name_edit.text.strip_edges()
    if new_name == "":
        return

    editor2d.call("set_room_name", current_room_index, new_name)
    _refresh_room_menu()


func _show_2d() -> void:
    # Before returning to 2D, ensure the 3D controller exits inside view
    # and restores default camera orbit.  This prevents the camera
    # remaining locked when switching back to 3D later and avoids
    # accidental clearing of geometry.
    if room3d.has_method("exit_view"):
        room3d.call("exit_view")

    # Clear room selection in the 2D editor when switching back to 2D.  This
    # prevents the previous selection from remaining highlighted when the
    # user starts working on a new layout.
    if editor2d.has_method("clear_selected_room"):
        editor2d.call("clear_selected_room")

    editor2d.visible = true
    room3d.visible = false
    in_3d = false
    btn_3d.button_pressed = false

    # Request a redraw on the 2D editor in case visibility toggle doesn't
    # automatically trigger one.  Without this the grid and walls could
    # appear blank until interacting with the scene.
    if editor2d.has_method("queue_redraw"):
        editor2d.call("queue_redraw")


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

    # Attempt to use the currently selected room if available.  If no room has been
    # selected via click, fall back to the largest detected room.
    var poly: PackedVector2Array = current_room_polygon
    if poly == null or poly.size() < 3:
        # compute the largest room polygon if none selected
        poly = editor2d.call("get_room_polygon") as PackedVector2Array
    if poly.size() < 3:
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
    # Reset current_room_polygon after building 3D view
    current_room_polygon = PackedVector2Array()
    _show_3d()

func _on_opening_placed(is_door: bool) -> void:
    # Lerakás után az Editor2D-ben válasszuk ki az utolsó nyílást
    # és nyissuk meg a nagy "Méretek módosítása" ablakot
    editor2d.call("select_last_opening", is_door)


func _on_room_selected(polygon: PackedVector2Array) -> void:
    current_room_polygon = polygon

func _on_project_changed() -> void:
    _refresh_room_menu()

func _on_save_pressed() -> void:
    editor2d.call("save_project")

func _on_load_pressed() -> void:
    editor2d.call("load_project")
