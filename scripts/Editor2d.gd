extends Node2D

## 2D floor plan editor.
## Units: centimeters in world space.

signal room_selected(polygon: PackedVector2Array)
signal project_changed
signal opening_placed(is_door: bool)

# Data model – simple dictionaries for prototype
var walls: Array[Dictionary] = []      # { id, p1:Vector2, p2:Vector2, thickness, height }
var doors: Array[Dictionary] = []      # { id, wall_id, offset_cm, width_cm, height_cm, sill_cm }
var windows: Array[Dictionary] = []    # same as doors
var devices: Array[Dictionary] = []    # { id, wall_id, type, width_cm, height_cm, dist_floor_cm, dist_left_cm }

var cached_rooms: Array = []
var rooms_dirty: bool = true

# Editor state
enum ToolMode {NONE, WALL, DOOR, WINDOW }
var mode: int = ToolMode.NONE

var next_wall_id: int = 1
var next_door_id: int = 1
var next_window_id: int = 1
var next_device_id: int = 1

# View transform
var pixels_per_cm: float = 2.0
var view_offset: Vector2 = Vector2.ZERO
var zoom: float = 1.0

# Dragging
var is_drawing_wall: bool = false
var wall_start_world: Vector2 = Vector2.ZERO
var last_opening_is_door: bool = true

var pan_active: bool = false
var pan_start_pos: Vector2 = Vector2.ZERO
var pan_start_offset: Vector2 = Vector2.ZERO

# --- Selection and editing state ---
# When not drawing (ToolMode.NONE), clicking on a wall, door or window
# selects that element for editing.  Selected walls are identified by
# their `id`, while openings (doors/windows) are tracked by their index
# within the corresponding array and a type string.  During a drag,
# `drag_mode` determines what is being manipulated: moving a whole
# wall (wall_move), dragging an endpoint (wall_p1 or wall_p2), or
# sliding an opening along its wall (opening).  `drag_start_world`
# stores the world coordinate where the drag began, and
# `drag_start_data` stores the original geometry of the element.
var selected_wall_id: int = -1
var selected_opening_idx: int = -1
var selected_opening_type: String = ""  # "door" or "window"
var drag_mode: String = ""
var drag_start_world: Vector2 = Vector2.ZERO
var drag_start_data: Dictionary = {}
var drag_active: bool = false

# When an element is selected in ToolMode.NONE, small on‑screen handles
# are drawn to allow moving or resizing that element.  These variables
# track whether the handles are visible and the rectangles (in screen
# coordinates) representing the move and resize buttons.  Their sizes are
# fixed in pixels, independent of zoom.
var handles_visible: bool = false
var move_handle_rect: Rect2 = Rect2()
var resize_handle_rect: Rect2 = Rect2()
var move_handle_size: Vector2 = Vector2(16, 16)
var resize_handle_size: Vector2 = Vector2(16, 16)

# A popup dialog used to modify the dimensions of the selected element.
var resize_dialog: AcceptDialog
var width_edit: LineEdit
var height_edit: LineEdit
var sill_edit: LineEdit
var sill_container: HBoxContainer
var delete_button: Button

var lbl_width: Label
var lbl_height: Label
var lbl_sill: Label

# Flags indicating what is currently selected for editing.  These are
# used to determine which dialog fields to show and how to update the
# data model when the user confirms the edit.
var selected_is_wall: bool = false
var selected_is_door: bool = false

# Grid
var grid_step_cm: float = 10.0   # VIZUÁLIS rács (10 cm-enként vonal)
var snap_step_cm: float = 1.0    # LOGIKAI snap (1 cm pontosság)
const ROOM_GRID_STEP_CM := 1.0   # szobakeresés rácslépése (1 cm)

var room_names: Array = []

# Selected room centroid and flag.  When a room is clicked, we store its
# centroid here to allow visual highlighting.  If no room is selected,
# `has_selected_room` is false.
var selected_room_centroid: Vector2 = Vector2.ZERO
var has_selected_room: bool = false

func _ready() -> void:
    set_process_unhandled_input(true)
    # Create a popup dialog for editing dimensions of walls, doors and windows.
    # The dialog contains labelled line edits for width, height and (for windows)
    # sill height measured from the floor.  When the user presses OK the
    # _on_resize_dialog_confirmed callback updates the data model.
    resize_dialog = AcceptDialog.new()
    resize_dialog.title = "Méretek módosítása"
    # Set the OK button text; we leave the default cancel button
    resize_dialog.get_ok_button().text = "OK"
    add_child(resize_dialog)
    delete_button = resize_dialog.add_button("Törlés", true, "delete")

    var vbox := VBoxContainer.new()
    resize_dialog.add_child(vbox)
    # Width row
    var row1 := HBoxContainer.new()
    vbox.add_child(row1)
    var lbl_w := Label.new()
    lbl_w.text = "Szélesség (cm):"
    row1.add_child(lbl_w)
    width_edit = LineEdit.new()
    width_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    width_edit.custom_minimum_size = Vector2(80, 20)
    row1.add_child(width_edit)
    lbl_width = lbl_w
    # Height row
    var row2 := HBoxContainer.new()
    vbox.add_child(row2)
    var lbl_h := Label.new()
    lbl_h.text = "Magasság (cm):"
    row2.add_child(lbl_h)
    height_edit = LineEdit.new()
    height_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    height_edit.custom_minimum_size = Vector2(80, 20)
    row2.add_child(height_edit)
    lbl_height = lbl_h
    # Sill row (only used for windows)
    sill_container = HBoxContainer.new()
    vbox.add_child(sill_container)
    var lbl_s := Label.new()
    lbl_s.text = "Padlótól (cm):"
    sill_container.add_child(lbl_s)
    sill_edit = LineEdit.new()
    sill_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    sill_edit.custom_minimum_size = Vector2(80, 20)
    sill_container.add_child(sill_edit)
    
    sill_container.visible = false
    # OK gomb
    resize_dialog.confirmed.connect(_on_resize_dialog_confirmed)
    # "Törlés" gomb -> custom_action("delete")
    resize_dialog.custom_action.connect(_on_resize_dialog_custom_action)

func _on_resize_dialog_custom_action(action: StringName) -> void:
    if action == "delete":
        _on_resize_dialog_delete()


func _on_resize_dialog_delete() -> void:
    # 1) Ha ajtó/ablak van kijelölve
    if selected_opening_type != "":
        if selected_opening_type == "door":
            if selected_opening_idx >= 0 and selected_opening_idx < doors.size():
                doors.remove_at(selected_opening_idx)
        else:
            if selected_opening_idx >= 0 and selected_opening_idx < windows.size():
                windows.remove_at(selected_opening_idx)

    # 2) Ha fal van kijelölve
    elif selected_wall_id != -1:
        var wall_id_to_remove := selected_wall_id

        # Ajtók törlése erről a falról
        for i in range(doors.size() - 1, -1, -1):
            var d: Dictionary = doors[i]
            if int(d.get("wall_id", -1)) == wall_id_to_remove:
                doors.remove_at(i)

        # Ablakok törlése erről a falról
        for i in range(windows.size() - 1, -1, -1):
            var w: Dictionary = windows[i]
            if int(w.get("wall_id", -1)) == wall_id_to_remove:
                windows.remove_at(i)

        # Eszközök törlése erről a falról (ha már lesznek használva)
        for i in range(devices.size() - 1, -1, -1):
            var dev: Dictionary = devices[i]
            if int(dev.get("wall_id", -1)) == wall_id_to_remove:
                devices.remove_at(i)

        # Maga a fal törlése
        for i in range(walls.size()):
            var wdict: Dictionary = walls[i]
            if int(wdict.get("id", -1)) == wall_id_to_remove:
                walls.remove_at(i)
                break

    # 3) Kijelölés és handlék reset
    selected_wall_id = -1
    selected_opening_idx = -1
    selected_opening_type = ""
    selected_is_wall = false
    selected_is_door = false
    drag_active = false
    drag_mode = ""
    handles_visible = false

    rooms_dirty = true
    emit_signal("project_changed")
    queue_redraw()
    _update_handles()
    resize_dialog.hide()



func set_mode_none() -> void:
    mode = ToolMode.NONE

func set_mode_wall() -> void:
    mode = ToolMode.WALL
    # Switch off any selection and hide edit handles when entering draw mode
    selected_wall_id = -1
    selected_opening_idx = -1
    selected_opening_type = ""
    drag_active = false
    drag_mode = ""
    handles_visible = false


func set_mode_door() -> void:
    mode = ToolMode.DOOR
    # Hide edit handles and clear selection when switching to door tool
    selected_wall_id = -1
    selected_opening_idx = -1
    selected_opening_type = ""
    drag_active = false
    drag_mode = ""
    handles_visible = false


func set_mode_window() -> void:
    mode = ToolMode.WINDOW
    # Hide edit handles and clear selection when switching to window tool
    selected_wall_id = -1
    selected_opening_idx = -1
    selected_opening_type = ""
    drag_active = false
    drag_mode = ""
    handles_visible = false


# ---- coordinate helpers ----

func world_to_screen(p: Vector2) -> Vector2:
    return view_offset + p * pixels_per_cm * zoom


func screen_to_world(p: Vector2) -> Vector2:
    return (p - view_offset) / (pixels_per_cm * zoom)


func snap_world_to_grid(p: Vector2) -> Vector2:
    var s: float = snap_step_cm
    return Vector2(
        round(p.x / s) * s,
        round(p.y / s) * s
    )

const ENDPOINT_SNAP_THRESHOLD_CM := 10.0

func snap_with_endpoints(p: Vector2) -> Vector2:
    # Először rácsra kerekítünk (1 cm)
    var snapped: Vector2 = snap_world_to_grid(p)
    var best_point: Vector2 = snapped
    var best_dist: float = ENDPOINT_SNAP_THRESHOLD_CM

    # Végigmegyünk az összes fal két végpontján
    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2

        var d1: float = p.distance_to(p1)
        if d1 < best_dist:
            best_dist = d1
            best_point = p1

        var d2: float = p.distance_to(p2)
        if d2 < best_dist:
            best_dist = d2
            best_point = p2

    return best_point

# ---- selection helpers ----
# Detect if a world point is near a wall or one of its endpoints.  Returns
# a dictionary with keys: type = "wall", wall_id, endpoint = "p1", "p2", or ""
# when selecting the middle of the wall.  Returns {"type": ""} when
# nothing is hit.
func _detect_wall_at(world: Vector2) -> Dictionary:
    var threshold: float = grid_step_cm * 0.5  # distance threshold in cm
    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        var seg: Vector2 = p2 - p1
        var seg_len: float = seg.length()
        if seg_len < 1e-3:
            continue
        var dir: Vector2 = seg / seg_len
        var diff: Vector2 = world - p1
        var proj: float = diff.dot(dir)
        if proj < 0.0 or proj > seg_len:
            continue
        var nearest: Vector2 = p1 + dir * proj
        var dist: float = world.distance_to(nearest)
        if dist <= threshold:
            var endpoint_threshold: float = grid_step_cm * 0.5
            if world.distance_to(p1) <= endpoint_threshold:
                return {"type": "wall", "wall_id": int(w.get("id")), "endpoint": "p1"}
            if world.distance_to(p2) <= endpoint_threshold:
                return {"type": "wall", "wall_id": int(w.get("id")), "endpoint": "p2"}
            return {"type": "wall", "wall_id": int(w.get("id")), "endpoint": ""}
    return {"type": ""}

# Detect if a world point is over a door or window along its wall.  For editing
# purposes we ignore the vertical extent (height) and only consider the
# projection of the point onto the wall segment.  Returns a dictionary
# with keys: type = "opening", opening_type ("door"/"window"), index,
# wall_id.  If nothing is detected, returns {"type": ""}.
func _detect_opening_at(world: Vector2) -> Dictionary:
    # Search doors first
    var threshold: float = grid_step_cm * 0.5
    for i in range(doors.size()):
        var d: Dictionary = doors[i]
        var wall_id: int = int(d.get("wall_id", -1))
        var width_cm: float = float(d.get("width_cm", 0.0))
        # Find wall definition
        var w_def = null
        for w_var in walls:
            var w: Dictionary = w_var
            if int(w.get("id", -1)) == wall_id:
                w_def = w
                break
        if w_def == null:
            continue
        var p1: Vector2 = w_def.get("p1") as Vector2
        var p2: Vector2 = w_def.get("p2") as Vector2
        var seg: Vector2 = p2 - p1
        var seg_len: float = seg.length()
        if seg_len < 1e-3:
            continue
        var dir: Vector2 = seg / seg_len
        var offset: float = float(d.get("offset_cm", 0.0))
        var start_point: Vector2 = p1 + dir * offset
        var end_point: Vector2 = start_point + dir * width_cm
        # Compute projection of world onto the segment direction
        var proj: float = (world - p1).dot(dir)
        if proj < offset - threshold or proj > offset + width_cm + threshold:
            continue
        # Compute perpendicular distance to the wall line
        var nearest: Vector2 = p1 + dir * proj
        var dist: float = world.distance_to(nearest)
        if dist <= threshold:
            return {"type": "opening", "opening_type": "door", "index": i, "wall_id": wall_id}
    # Windows
    for i in range(windows.size()):
        var w_def: Dictionary = windows[i]
        var wall_id2: int = int(w_def.get("wall_id", -1))
        var width_cm2: float = float(w_def.get("width_cm", 0.0))
        var wall_def = null
        for w_var in walls:
            var w: Dictionary = w_var
            if int(w.get("id", -1)) == wall_id2:
                wall_def = w
                break
        if wall_def == null:
            continue
        var p1_w: Vector2 = wall_def.get("p1") as Vector2
        var p2_w: Vector2 = wall_def.get("p2") as Vector2
        var seg2: Vector2 = p2_w - p1_w
        var seg2_len: float = seg2.length()
        if seg2_len < 1e-3:
            continue
        var dir2: Vector2 = seg2 / seg2_len
        var offset2: float = float(w_def.get("offset_cm", 0.0))
        var start_point2: Vector2 = p1_w + dir2 * offset2
        var end_point2: Vector2 = start_point2 + dir2 * width_cm2
        var proj2: float = (world - p1_w).dot(dir2)
        if proj2 < offset2 - threshold or proj2 > offset2 + width_cm2 + threshold:
            continue
        var nearest2: Vector2 = p1_w + dir2 * proj2
        var dist2: float = world.distance_to(nearest2)
        if dist2 <= threshold:
            return {"type": "opening", "opening_type": "window", "index": i, "wall_id": wall_id2}
    return {"type": ""}


# ---- input ----

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mb := event as InputEventMouseButton

        # Zoom
        if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
            zoom *= 1.1
            queue_redraw()
            # Recompute handle positions after zooming
            _update_handles()
            return
        if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
            zoom /= 1.1
            zoom = clamp(zoom, 0.2, 4.0)
            queue_redraw()
            # Recompute handle positions after zooming
            _update_handles()
            return

        # Panning – only middle mouse button (left button is reserved for selection)
        if mb.button_index == MOUSE_BUTTON_MIDDLE:
            if mb.pressed:
                pan_active = true
                pan_start_pos = mb.position
                pan_start_offset = view_offset
            else:
                pan_active = false
            return

        # Bal gomb – eszközök
        if mb.button_index == MOUSE_BUTTON_LEFT:
            if mb.pressed:
                _on_left_pressed(mb.position)
            else:
                _on_left_released(mb.position)

    elif event is InputEventMouseMotion:
        var mm := event as InputEventMouseMotion
        if pan_active:
            view_offset = pan_start_offset + (mm.position - pan_start_pos)
            queue_redraw()
            _update_handles()
        elif is_drawing_wall:
            queue_redraw()
        elif drag_active:
            var world: Vector2 = screen_to_world(mm.position)
            # Update based on drag_mode
            match drag_mode:
                "wall_move":
                    # Move both endpoints by the delta from drag start
                    var delta: Vector2 = world - drag_start_world
                    # Snap delta to grid
                    var snap_delta: Vector2 = snap_world_to_grid(delta) - snap_world_to_grid(Vector2.ZERO)
                    # Retrieve original positions
                    var orig_p1: Vector2 = drag_start_data.get("p1") as Vector2
                    var orig_p2: Vector2 = drag_start_data.get("p2") as Vector2
                    var new_p1: Vector2 = orig_p1 + snap_delta
                    var new_p2: Vector2 = orig_p2 + snap_delta
                    # Maintain orientation (horizontal or vertical) based on original wall direction
                    var dx: float = abs(orig_p2.x - orig_p1.x)
                    var dy: float = abs(orig_p2.y - orig_p1.y)
                    if dx > dy:
                        # horizontal wall
                        new_p1.y = snap_world_to_grid(orig_p1 + snap_delta).y
                        new_p2.y = new_p1.y
                    else:
                        # vertical wall
                        new_p1.x = snap_world_to_grid(orig_p1 + snap_delta).x
                        new_p2.x = new_p1.x
                    # Update wall
                    for idx in range(walls.size()):
                        var w: Dictionary = walls[idx]
                        if int(w.get("id", -1)) == selected_wall_id:
                            w["p1"] = new_p1
                            w["p2"] = new_p2
                            walls[idx] = w
                            break
                    queue_redraw()
                "wall_p1":
                    # Dragging the first endpoint; other endpoint is fixed
                    var orig_p2: Vector2 = drag_start_data.get("p2") as Vector2
                    var new_p1: Vector2 = snap_world_to_grid(world)
                    # Maintain orientation based on original segment
                    var seg: Vector2 = orig_p2 - new_p1
                    var dx2: float = abs(seg.x)
                    var dy2: float = abs(seg.y)
                    if dx2 > dy2:
                        new_p1.y = orig_p2.y
                    else:
                        new_p1.x = orig_p2.x
                    for idx in range(walls.size()):
                        var w: Dictionary = walls[idx]
                        if int(w.get("id", -1)) == selected_wall_id:
                            w["p1"] = new_p1
                            walls[idx] = w
                            break
                    queue_redraw()
                "wall_p2":
                    # Dragging the second endpoint; other endpoint is fixed
                    var orig_p1: Vector2 = drag_start_data.get("p1") as Vector2
                    var new_p2: Vector2 = snap_world_to_grid(world)
                    var seg2: Vector2 = new_p2 - orig_p1
                    var dx3: float = abs(seg2.x)
                    var dy3: float = abs(seg2.y)
                    if dx3 > dy3:
                        new_p2.y = orig_p1.y
                    else:
                        new_p2.x = orig_p1.x
                    for idx in range(walls.size()):
                        var w: Dictionary = walls[idx]
                        if int(w.get("id", -1)) == selected_wall_id:
                            w["p2"] = new_p2
                            walls[idx] = w
                            break
                    queue_redraw()
                "opening":
                    # Slide the selected opening along its wall
                    # Determine associated wall
                    var wall_id: int = drag_start_data.get("wall_id", -1)
                    var w_def = null
                    for w_var in walls:
                        var w: Dictionary = w_var
                        if int(w.get("id", -1)) == wall_id:
                            w_def = w
                            break
                    if w_def != null:
                        var p1: Vector2 = w_def.get("p1") as Vector2
                        var p2: Vector2 = w_def.get("p2") as Vector2
                        var segv: Vector2 = p2 - p1
                        var seg_len: float = segv.length()
                        if seg_len > 1e-3:
                            var dirv: Vector2 = segv / seg_len
                            # Project current world position onto wall
                            var proj: float = (world - p1).dot(dirv)
                            var width_orig: float = drag_start_data.get("width_cm")
                            # Clamp projection to keep opening within wall bounds
                            proj = clamp(proj - width_orig * 0.5, 0.0, seg_len - width_orig)
                            var new_offset: float = proj
                            # Snap offset to grid step (so openings align with grid)
                            var snap_offset: float = round(new_offset / snap_step_cm) * snap_step_cm
                            # Update the appropriate array
                            if selected_opening_type == "door":
                                var d_entry: Dictionary = doors[selected_opening_idx]
                                d_entry["offset_cm"] = snap_offset
                                doors[selected_opening_idx] = d_entry
                            elif selected_opening_type == "window":
                                var w_entry: Dictionary = windows[selected_opening_idx]
                                w_entry["offset_cm"] = snap_offset
                                windows[selected_opening_idx] = w_entry
                            queue_redraw()
                            # Recompute handle positions as the opening slides along the wall
                            _update_handles()

func _on_left_pressed(pos: Vector2) -> void:
    var world: Vector2 = screen_to_world(pos)

    match mode:
        ToolMode.NONE:
            # When no drawing tool is active, first check if the user
            # clicked on one of the edit handles.  Move and resize
            # operations only begin when the corresponding handle is
            # clicked; otherwise the click selects a new element.
            # Convert the mouse position to screen coordinates and test
            # against the handle rectangles.
            if handles_visible:
                # Move handle: start dragging the selected element
                if move_handle_rect.has_point(pos):
                    var world_pos: Vector2 = world
                    if selected_opening_type != "":
                        # Begin sliding a door or window along its wall
                        drag_mode = "opening"
                        drag_active = true
                        drag_start_world = world_pos
                        # Preserve the original offset and width of the opening
                        var entry: Dictionary
                        if selected_opening_type == "door":
                            entry = doors[selected_opening_idx]
                        else:
                            entry = windows[selected_opening_idx]
                        drag_start_data = {
                            "offset_cm": float(entry.get("offset_cm", 0.0)),
                            "width_cm": float(entry.get("width_cm", 0.0)),
                            "wall_id": int(entry.get("wall_id", -1))
                        }
                        return
                    elif selected_wall_id != -1:
                        # Begin moving the entire wall
                        var wall_def = _get_wall_by_id(selected_wall_id) as Dictionary
                        if wall_def != null:
                            drag_mode = "wall_move"
                            drag_active = true
                            drag_start_world = world_pos
                            drag_start_data = {"p1": wall_def.get("p1"), "p2": wall_def.get("p2")}
                            return
                # Resize handle: open the editing dialog
                if resize_handle_rect.has_point(pos):
                    _show_resize_dialog()
                    return
            # No handle was clicked; clear previous selection and look for a new one
            selected_wall_id = -1
            selected_opening_idx = -1
            selected_opening_type = ""
            drag_mode = ""
            drag_active = false
            handles_visible = false
            selected_is_wall = false
            selected_is_door = false
            # Try selecting an opening first
            var hit_opening := _detect_opening_at(world)
            if hit_opening.get("type", "") == "opening":
                selected_opening_idx = int(hit_opening.get("index", -1))
                selected_opening_type = hit_opening.get("opening_type", "")
                selected_wall_id = -1
                drag_active = false
                drag_mode = ""
                # Compute handle placement for this opening
                _update_handles()
                return
            # Try selecting a wall if no opening was hit
            var hit_wall := _detect_wall_at(world)
            if hit_wall.get("type", "") == "wall":
                selected_wall_id = int(hit_wall.get("wall_id", -1))
                selected_opening_idx = -1
                selected_opening_type = ""
                drag_active = false
                drag_mode = ""
                # Compute handle placement for this wall
                _update_handles()
                return
            # No element was hit – select the room under the cursor
            select_room_from_point(pos)
            return

        ToolMode.WALL:
            is_drawing_wall = true
            wall_start_world = snap_with_endpoints(world)


        ToolMode.DOOR, ToolMode.WINDOW:
            var wall_id := _find_nearest_wall(world)
            if wall_id != -1:
                var is_door: bool = (mode == ToolMode.DOOR)
                _place_opening(world, wall_id, is_door)
                rooms_dirty = true
                emit_signal("project_changed")
                queue_redraw()



func _on_left_released(pos: Vector2) -> void:
    # If we were dragging an existing element, finalise modifications
    if drag_active:
        drag_active = false
        drag_mode = ""
        # After modification, emit project_changed to update 3D view and
        # recompute handle positions so they follow the moved element.
        rooms_dirty = true
        emit_signal("project_changed")
        queue_redraw()
        _update_handles()
        return

    if mode == ToolMode.WALL and is_drawing_wall:
        is_drawing_wall = false
        var end_world: Vector2 = snap_with_endpoints(screen_to_world(pos))
        # If non‑perpendicular walls are not allowed, constrain the wall to
        # horizontal or vertical by snapping the lesser delta axis to the
        # starting coordinate.  This ensures walls run along grid lines only.
        var delta: Vector2 = end_world - wall_start_world
        if abs(delta.x) > abs(delta.y):
            # Horizontal wall: keep y same as start
            end_world.y = wall_start_world.y
        else:
            # Vertical wall: keep x same as start
            end_world.x = wall_start_world.x
        if end_world.distance_to(wall_start_world) <= 1.0:
            return

        # Do not add exact duplicate wall (same endpoints, order ignored)
        var epsilon := 0.1
        for w_var in walls:
            var w: Dictionary = w_var
            var p1: Vector2 = w.get("p1") as Vector2
            var p2: Vector2 = w.get("p2") as Vector2
            var same_dir := p1.distance_to(wall_start_world) < epsilon \
                and p2.distance_to(end_world) < epsilon
            var same_rev := p1.distance_to(end_world) < epsilon \
                and p2.distance_to(wall_start_world) < epsilon
            if same_dir or same_rev:
                return  # already have this wall

        var wall: Dictionary = {
            "id": next_wall_id,
            "p1": wall_start_world,
            "p2": end_world,
            # The height field is unused by the 3D visualiser, but set it
            # consistently to 250 cm to reflect the fixed wall height.
            "thickness": 10.0,
            "height": 250.0
        }
        next_wall_id += 1
        walls.append(wall)
        rooms_dirty = true
        emit_signal("project_changed")
        queue_redraw()


# ---- openings (doors / windows) ----

func _find_nearest_wall(world: Vector2) -> int:
    var min_dist: float = 999999.0
    var best_id: int = -1

    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        var wid: int = int(w.get("id", -1))

        var closest: Vector2 = Geometry2D.get_closest_point_to_segment(world, p1, p2)
        var seg_dist: float = closest.distance_to(world)

        if seg_dist < min_dist and seg_dist < 50.0:
            min_dist = seg_dist
            best_id = wid

    return best_id


func _place_opening(world: Vector2, wall_id: int, is_door: bool) -> void:
    var wall: Variant = _get_wall_by_id(wall_id)
    if wall == null:
        return

    var p1: Vector2 = wall.get("p1") as Vector2
    var p2: Vector2 = wall.get("p2") as Vector2

    # Projektáljuk a kattintást a falra...
    var proj: Vector2 = Geometry2D.get_closest_point_to_segment(world, p1, p2)
    # ...ÉS rácsra snap-eljük, hogy mindig ugyanarra a pontra essen
    var proj_snapped: Vector2 = snap_world_to_grid(proj)
    var offset_cm: float = p1.distance_to(proj_snapped)

    # Alap méretek (ajtó / ablak)
    var width_cm: float = 90.0 if is_door else 120.0
    var height_cm: float = 210.0 if is_door else 120.0
    var sill_cm: float = 0.0 if is_door else 90.0

    # Ugyanarra a falra ÉS közel ugyanarra az offsetre ne engedjen még egyet
    var epsilon := 0.1   # rács miatt elég kicsi lehet

    if is_door:
        for d_var in doors:
            var d_existing: Dictionary = d_var
            if int(d_existing.get("wall_id", -1)) == wall_id \
            and abs(float(d_existing.get("offset_cm", 0.0)) - offset_cm) < epsilon:
                return   # már van itt ajtó

        var d_new: Dictionary = {
            "id": next_door_id,
            "wall_id": wall_id,
            "offset_cm": offset_cm,
            "width_cm": width_cm,
            "height_cm": height_cm,
            "sill_cm": sill_cm
        }
        next_door_id += 1
        doors.append(d_new)
        last_opening_is_door = true

    else:
        for w_var in windows:
            var w_existing: Dictionary = w_var
            if int(w_existing.get("wall_id", -1)) == wall_id \
            and abs(float(w_existing.get("offset_cm", 0.0)) - offset_cm) < epsilon:
                return   # már van itt ablak

        var win_new: Dictionary = {
            "id": next_window_id,
            "wall_id": wall_id,
            "offset_cm": offset_cm,
            "width_cm": width_cm,
            "height_cm": height_cm,
            "sill_cm": sill_cm
        }
        next_window_id += 1
        windows.append(win_new)
        last_opening_is_door = false

    # Szólunk, hogy a projekt változott és van új nyílás
    rooms_dirty = true
    emit_signal("project_changed")
    emit_signal("opening_placed", is_door)
    queue_redraw()

func select_last_opening(is_door: bool) -> void:
    # Ha nincs egyetlen ajtó/ablak sem, nincs mit szerkeszteni
    if is_door:
        if doors.size() == 0:
            return
        selected_opening_type = "door"
        selected_opening_idx = doors.size() - 1
        var last_entry: Dictionary = doors[selected_opening_idx]
        selected_wall_id = int(last_entry.get("wall_id", -1))
    else:
        if windows.size() == 0:
            return
        selected_opening_type = "window"
        selected_opening_idx = windows.size() - 1
        var last_entry: Dictionary = windows[selected_opening_idx]
        selected_wall_id = int(last_entry.get("wall_id", -1))

    # Frissítsük a move/resize handlereket, hogy a kijelölés is látszódjon
    _update_handles()
    # És ugyanazt a nagy “Méretek módosítása” popupot nyitjuk meg,
    # amit eddig csak utólagos szerkesztéskor használtál
    _show_resize_dialog()


func update_last_opening(is_door: bool, width_cm: float, height_cm: float, sill_cm: float) -> void:
    if is_door:
        if doors.size() == 0:
            return
        var d: Dictionary = doors[doors.size() - 1]
        d["width_cm"] = width_cm
        d["height_cm"] = height_cm
        d["sill_cm"] = sill_cm
        doors[doors.size() - 1] = d
    else:
        if windows.size() == 0:
            return
        var w: Dictionary = windows[windows.size() - 1]
        w["width_cm"] = width_cm
        w["height_cm"] = height_cm
        w["sill_cm"] = sill_cm
        windows[windows.size() - 1] = w
    rooms_dirty = true
    emit_signal("project_changed")
    queue_redraw()


### handle drawing and editing -------------------------------------------------

# Recompute the positions of the move and resize handles based on the
# currently selected element.  This converts world coordinates to screen
# coordinates so the handles remain anchored to the element even when
# zooming or panning.  After recomputing, the view is queued for redraw.
func _update_handles() -> void:
    handles_visible = false
    selected_is_wall = false
    selected_is_door = false
    # Compute handle positions for an opening (door or window)
    if selected_opening_type != "":
        var entry: Dictionary
        if selected_opening_type == "door":
            if selected_opening_idx >= 0 and selected_opening_idx < doors.size():
                entry = doors[selected_opening_idx]
                selected_is_door = true
            else:
                queue_redraw()
                return
        else:
            if selected_opening_idx >= 0 and selected_opening_idx < windows.size():
                entry = windows[selected_opening_idx]
            else:
                queue_redraw()
                return
        var wall_id: int = int(entry.get("wall_id", -1))
        var wall = _get_wall_by_id(wall_id) as Dictionary
        if wall != null:
            var p1: Vector2 = wall.get("p1") as Vector2
            var p2: Vector2 = wall.get("p2") as Vector2
            var dir: Vector2 = (p2 - p1).normalized()
            var offset: float = float(entry.get("offset_cm", 0.0))
            var width_cm: float = float(entry.get("width_cm", 0.0))
            var start_w: Vector2 = p1 + dir * offset
            var end_w: Vector2 = start_w + dir * width_cm
            var mid_world: Vector2 = (start_w + end_w) * 0.5
            var mid_screen: Vector2 = world_to_screen(mid_world)
            var off_y: Vector2 = Vector2(0, -20)
            move_handle_rect = Rect2(mid_screen + off_y - move_handle_size * 0.5, move_handle_size)
            resize_handle_rect = Rect2(mid_screen - off_y - resize_handle_size * 0.5, resize_handle_size)
            handles_visible = true
    # Compute handle positions for a wall
    elif selected_wall_id != -1:
        selected_is_wall = true
        var wall2 = _get_wall_by_id(selected_wall_id) as Dictionary
        if wall2 != null:
            var p1_w: Vector2 = wall2.get("p1") as Vector2
            var p2_w: Vector2 = wall2.get("p2") as Vector2
            var mid_world2: Vector2 = (p1_w + p2_w) * 0.5
            var mid_screen2: Vector2 = world_to_screen(mid_world2)
            var off_y2: Vector2 = Vector2(0, -20)
            move_handle_rect = Rect2(mid_screen2 + off_y2 - move_handle_size * 0.5, move_handle_size)
            resize_handle_rect = Rect2(mid_screen2 - off_y2 - resize_handle_size * 0.5, resize_handle_size)
            handles_visible = true
    queue_redraw()


# Draw the move and resize handles on the canvas.  The handles use
# semi‑transparent colours and simple square shapes so they stand out
# against the plan drawing.  This function is called from _draw().
func _draw_handles() -> void:
    if not handles_visible:
        return
    var move_col: Color = Color(0.9, 0.3, 0.3, 0.8)  # reddish for move
    var resize_col: Color = Color(0.3, 0.8, 0.3, 0.8)  # greenish for resize
    draw_rect(move_handle_rect, move_col, true)
    draw_rect(resize_handle_rect, resize_col, true)


# Display the resize dialog populated with the current dimensions of the
# selected element.  For windows the sill container is shown so the
# sill height can be edited; for doors and walls it is hidden.  The
# dialog is centred on the viewport when opened.
func _show_resize_dialog() -> void:
    if selected_opening_type != "":
        var entry: Dictionary
        if selected_opening_type == "door":
            if selected_opening_idx < 0 or selected_opening_idx >= doors.size():
                return
            entry = doors[selected_opening_idx]
            selected_is_door = true
        else:
            if selected_opening_idx < 0 or selected_opening_idx >= windows.size():
                return
            entry = windows[selected_opening_idx]
            selected_is_door = false
        width_edit.text = str(entry.get("width_cm", 0.0))
        height_edit.text = str(entry.get("height_cm", 0.0))
        if selected_opening_type == "window":
            sill_container.visible = true
            sill_edit.text = str(entry.get("sill_cm", 0.0))
        else:
            sill_container.visible = false
        resize_dialog.popup_centered()
    elif selected_wall_id != -1:
        var wall = _get_wall_by_id(selected_wall_id) as Dictionary
        if wall == null:
            return
        selected_is_wall = true
        selected_is_door = false
        width_edit.text = str(wall.get("thickness", 10.0))
        height_edit.text = str(wall.get("height", 250.0))
        sill_container.visible = false
        resize_dialog.popup_centered()


# Callback invoked when the user presses the OK button in the resize dialog.
# It parses the input values and updates the corresponding dictionary in
# the data model.  After modification it emits project_changed and
# refreshes the editor view.
func _on_resize_dialog_confirmed() -> void:
    var new_width: float = 0.0
    var new_height: float = 0.0
    var new_sill: float = 0.0
    if width_edit.text != "":
        new_width = float(width_edit.text)
    if height_edit.text != "":
        new_height = float(height_edit.text)
    if sill_container.visible and sill_edit.text != "":
        new_sill = float(sill_edit.text)
    # Update selected element
    if selected_opening_type != "":
        if selected_opening_type == "door":
            if selected_opening_idx >= 0 and selected_opening_idx < doors.size():
                var d: Dictionary = doors[selected_opening_idx]
                d["width_cm"] = new_width
                d["height_cm"] = new_height
                d["sill_cm"] = new_sill
                doors[selected_opening_idx] = d
        else:
            if selected_opening_idx >= 0 and selected_opening_idx < windows.size():
                var win: Dictionary = windows[selected_opening_idx]
                win["width_cm"] = new_width
                win["height_cm"] = new_height
                win["sill_cm"] = new_sill
                windows[selected_opening_idx] = win
    elif selected_wall_id != -1:
        var wdict: Dictionary = _get_wall_by_id(selected_wall_id) as Dictionary
        if wdict != null:
            wdict["thickness"] = new_width
            wdict["height"] = new_height
            # Write back into the walls array
            for i in range(walls.size()):
                var tmp: Dictionary = walls[i]
                if int(tmp.get("id", -1)) == selected_wall_id:
                    walls[i] = wdict
                    break
    rooms_dirty = true
    emit_signal("project_changed")
    queue_redraw()
    _update_handles()


# ---- drawing ----

func _draw() -> void:
    _draw_grid()
    _draw_room_outline()      # SZÍNEZÉS ELŐRE, ALULRA
    _draw_walls()
    _draw_openings()          # FALAK FÖLÉ
    _draw_current_wall_preview()
    _draw_handles()


    # Draw handles for the currently selected element (if any).  These
    # handles appear when no drawing tool is active and an element is
    # selected.  They allow the user to move or resize the element.
    _draw_handles()


func _draw_grid() -> void:
    var viewport_size: Vector2 = get_viewport_rect().size
    var step_px: float = grid_step_cm * pixels_per_cm * zoom
    if step_px < 1.0:
        return        # vagy akár ezt is elhagyhatod, ha nem laggol


    var origin: Vector2 = world_to_screen(Vector2.ZERO)
    var color: Color = Color(0.85, 0.85, 0.85)

    var start_x: float = fmod(origin.x, step_px)
    var x: float = start_x
    while x < viewport_size.x:
        draw_line(Vector2(x, 0), Vector2(x, viewport_size.y), color, 1.0)
        x += step_px

    var start_y: float = fmod(origin.y, step_px)
    var y: float = start_y
    while y < viewport_size.y:
        draw_line(Vector2(0, y), Vector2(viewport_size.x, y), color, 1.0)
        y += step_px


func _draw_walls() -> void:
    for w_var in walls:
        var w: Dictionary = w_var

        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2

        var p1s: Vector2 = world_to_screen(p1)
        var p2s: Vector2 = world_to_screen(p2)
        draw_line(p1s, p2s, Color.BLACK, 3.0)

        # Dimension text
        var length_cm: float = p1.distance_to(p2)
        var mid: Vector2 = (p1 + p2) * 0.5
        var text: String = str(round(length_cm)) + " cm"
        var font: Font = ThemeDB.fallback_font
        var pos: Vector2 = world_to_screen(mid) + Vector2(5, -5)
        draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14.0, Color.BLACK)


func _draw_openings() -> void:
    # Ajtók – világos kék, vastagabb
    for d_var in doors:
        var d: Dictionary = d_var
        var wall_id: int = int(d.get("wall_id", -1))
        var wall: Dictionary = _get_wall_by_id(wall_id) as Dictionary
        if wall == null:
            continue

        var offset_cm: float = float(d.get("offset_cm", 0.0))
        var width_cm: float = float(d.get("width_cm", 90.0))

        _draw_opening_on_wall(wall, offset_cm, width_cm, Color(0.1, 0.9, 1.0), true)

    # Ablakok – élénk zöld
    for w_var in windows:
        var win: Dictionary = w_var
        var wall_id2: int = int(win.get("wall_id", -1))
        var wall2: Dictionary = _get_wall_by_id(wall_id2) as Dictionary
        if wall2 == null:
            continue

        var offset_cm2: float = float(win.get("offset_cm", 0.0))
        var width_cm2: float = float(win.get("width_cm", 120.0))

        _draw_opening_on_wall(wall2, offset_cm2, width_cm2, Color(0.4, 1.0, 0.4), false)




func _get_wall_by_id(id: int) -> Variant:
    for w_var in walls:
        var w: Dictionary = w_var
        var wid: int = int(w.get("id", -1))
        if wid == id:
            return w
    return null


func _draw_opening_on_wall(
        wall: Dictionary,
        offset_cm: float,
        width_cm: float,
        color: Color,
        is_door: bool) -> void:
    var p1: Vector2 = wall.get("p1") as Vector2
    var p2: Vector2 = wall.get("p2") as Vector2
    var dir: Vector2 = (p2 - p1).normalized()
    var start: Vector2 = p1 + dir * offset_cm
    var endp: Vector2 = start + dir * width_cm

    var start_s: Vector2 = world_to_screen(start)
    var end_s: Vector2 = world_to_screen(endp)

    # Ajtó legyen picit vastagabb, mint ablak
    var thickness: float = 7.0 if is_door else 5.0

    draw_line(start_s, end_s, color, thickness)

    # Kis "fülek" a két végén, merőlegesen a falra
    var screen_dir: Vector2 = (end_s - start_s).normalized()
    var normal: Vector2 = Vector2(-screen_dir.y, screen_dir.x)
    var tick_len: float = 8.0

    draw_line(start_s - normal * tick_len, start_s + normal * tick_len, color, thickness)
    draw_line(end_s - normal * tick_len, end_s + normal * tick_len, color, thickness)



func _draw_current_wall_preview() -> void:
    if not is_drawing_wall:
        return
    var mouse_pos: Vector2 = get_viewport().get_mouse_position()
    var world_end: Vector2 = snap_world_to_grid(screen_to_world(mouse_pos))
    draw_line(world_to_screen(wall_start_world), world_to_screen(world_end), Color(0.7, 0.0, 0.0), 2.0)


# ---- room detection & drawing ----

##
## Room detection using a planar graph approach.
##
## We treat the set of wall segments as undirected edges of a planar graph,
## merge endpoints that are very close together, and sort adjacency lists
## around each vertex by angle.  We then traverse each oriented edge in
## the graph exactly once to enumerate all faces (rooms).  The unbounded
## external face has the largest area and is discarded.  The remaining
## faces correspond to enclosed rooms.

var _planar_eps: float = 0.5

# Comparator for sorting adjacency edges by their angle about the vertex.
func _compare_pair(a: Dictionary, b: Dictionary) -> bool:
    # Sort ascending by angle; break ties by distance (closer first).
    # When two edges have the exact same angle, sorting solely by
    # angle can lead to ambiguous ordering for collinear edges.  To
    # ensure deterministic behaviour, also sort by distance from
    # the pivot vertex if the angles are effectively equal.  This
    # comparator returns true if `a` should come before `b`.
    var angle_a: float = a.get("angle")
    var angle_b: float = b.get("angle")
    if abs(angle_a - angle_b) > 0.0001:
        return angle_a < angle_b
    # Tie‑break by distance: prefer the closer neighbor first.  Using
    # distance instead of id ensures that collinear edges are ordered
    # consistently (shorter segment first) which helps the face
    # traversal algorithm discover enclosed faces for orthogonal
    # layouts.
    var dist_a: float = a.get("dist")
    var dist_b: float = b.get("dist")
    return dist_a < dist_b

# Build a planar graph representation of the current walls.
# Returns a dictionary with:
#   "vertices": PackedVector2Array of unique vertices (wall endpoints merged by epsilon)
#   "adj": Array of arrays of ints, adjacency list for each vertex
func _build_planar_graph() -> Dictionary:
    var verts: PackedVector2Array = PackedVector2Array()
    var adj: Array = []

    # Helper to find an existing vertex within epsilon or append and return new index.
    # Use a local lambda assigned to a variable rather than a nested function definition,
    # since Godot does not allow nested named functions within other functions.  The
    # lambda captures `verts` and `adj` from the surrounding scope.
    var get_vert_index := func(p: Vector2) -> int:
        for i in range(verts.size()):
            if verts[i].distance_to(p) < _planar_eps:
                return i
        verts.append(p)
        adj.append([])
        return verts.size() - 1

    # Add vertices and edges for each wall segment
    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        var i: int = get_vert_index.call(p1)
        var j: int = get_vert_index.call(p2)
        # Avoid duplicate edges
        if not adj[i].has(j):
            adj[i].append(j)
        if not adj[j].has(i):
            adj[j].append(i)

    # Sort adjacency lists by angle around each vertex (counterclockwise order)
    for i in range(verts.size()):
        var pairs: Array = []
        for j in adj[i]:
            var dir: Vector2 = verts[j] - verts[i]
            var ang: float = atan2(dir.y, dir.x)
            if ang < 0.0:
                ang += TAU
            # Also record the squared distance to break ties when angles
            # coincide (e.g. collinear segments).  Squared distance is
            # sufficient and avoids an extra square root.
            var dist: float = dir.length_squared()
            pairs.append({"idx": j, "angle": ang, "dist": dist})
        # Sort by angle ascending
        pairs.sort_custom(Callable(self, "_compare_pair"))
        # Replace adjacency with sorted indices
        var sorted_indices: Array = []
        for d in pairs:
            sorted_indices.append(int(d.get("idx")))
        adj[i] = sorted_indices

    return {"vertices": verts, "adj": adj}

# Find all faces (rooms) from a planar graph.  Returns an array of PackedVector2Array.
func _find_room_faces(graph_data: Dictionary) -> Array:
    var faces: Array = []
    var visited: Dictionary = {}
    var verts: PackedVector2Array = graph_data.get("vertices") as PackedVector2Array
    var adj: Array = graph_data.get("adj") as Array
    var n: int = verts.size()
    # Traverse each oriented edge
    for i in range(n):
        var neigh: Array = adj[i]
        for j_idx in neigh:
            var key: String = str(i) + "_" + str(j_idx)
            if visited.has(key):
                continue
            # Start tracing a new face
            var face: PackedVector2Array = PackedVector2Array()
            var curr_i: int = i
            var curr_j: int = j_idx
            while true:
                # Mark this oriented edge as visited
                visited[key] = true
                # Append the starting vertex of the edge
                face.append(verts[curr_i])
                # Determine the next oriented edge by taking the predecessor of curr_i in adj[curr_j]
                var neigh2: Array = adj[curr_j]
                # Find index of curr_i in adjacency list of curr_j
                var idx: int = -1
                for t in range(neigh2.size()):
                    if neigh2[t] == curr_i:
                        idx = t
                        break
                if idx == -1:
                    break # shouldn't happen
                # Predecessor (rotate one step backwards)
                var next_j: int = neigh2[(idx - 1 + neigh2.size()) % neigh2.size()]
                var next_i: int = curr_j
                # Update for next iteration
                curr_i = next_i
                curr_j = next_j
                key = str(curr_i) + "_" + str(curr_j)
                if curr_i == i and curr_j == j_idx:
                    # Completed the cycle
                    break
            # Compute absolute area to filter out degenerate faces later
            var area: float = 0.0
            for k in range(face.size()):
                var a: Vector2 = face[k]
                var b: Vector2 = face[(k + 1) % face.size()]
                area += a.x * b.y - b.x * a.y
            var abs_area: float = abs(area) * 0.5
            # Ignore tiny faces (area too small)
            if abs_area < 1e-2:
                continue
            faces.append({"poly": face, "area": abs_area})
    # Remove the face with the largest area (the external region)
    if faces.size() > 0:
        var max_idx: int = 0
        var max_area: float = faces[0].get("area")
        for idx in range(1, faces.size()):
            var area_tmp: float = faces[idx].get("area")
            if area_tmp > max_area:
                max_area = area_tmp
                max_idx = idx
        faces.remove_at(max_idx)
    # Convert to an array of PackedVector2Array
    var result: Array = []
    for f in faces:
        result.append(f.get("poly"))
    return result

# Public helper: returns a list of polygons representing each detected room.
## Visszaadja az aktuális szoba-poligonokat (cache-elve).
func get_rooms() -> Array:
    # Ha nincs változás, használd a cache-t
    if not rooms_dirty:
        return cached_rooms

    # 1) Grid-alapú módszer (ortogonális alaprajzokra)
    var grid_rooms: Array = _compute_rooms_grid()
    var result: Array
    if grid_rooms.size() > 0:
        result = grid_rooms
    else:
        # 2) Planar-graph fallback bonyolultabb esetekre
        var graph_data: Dictionary = _build_planar_graph()
        var faces: Array = _find_room_faces(graph_data)
        result = faces

    cached_rooms = result
    _sync_room_names()
    rooms_dirty = false
    return cached_rooms

func _sync_room_names() -> void:
    var new_names: Array = []
    for i in range(cached_rooms.size()):
        if i < room_names.size() and room_names[i] != "":
            new_names.append(room_names[i])
        else:
            new_names.append("Szoba " + str(i + 1))
    room_names = new_names

func get_room_names() -> Array:
    # Gondoskodunk róla, hogy a cache friss legyen
    get_rooms()
    return room_names


func set_room_name(index: int, new_name: String) -> void:
    if index < 0 or index >= room_names.size():
        return
    room_names[index] = new_name
    queue_redraw()

func focus_room(index: int) -> void:
    var rooms: Array = get_rooms()
    if index < 0 or index >= rooms.size():
        return
    var poly: PackedVector2Array = rooms[index]
    if poly.size() < 3:
        return

    # Szoba centroid world-ben
    var centroid: Vector2 = Vector2.ZERO
    for p in poly:
        centroid += p
    centroid /= poly.size()

    # Highlight állapot
    selected_room_centroid = centroid
    has_selected_room = true
    rooms_dirty = true
    emit_signal("room_selected", poly)

    # Kamera középre húzása
    var viewport_size: Vector2 = get_viewport_rect().size
    var target_screen_center: Vector2 = viewport_size * 0.5
    var current_center_screen: Vector2 = world_to_screen(centroid)
    var delta: Vector2 = target_screen_center - current_center_screen
    view_offset += delta

    queue_redraw()

func delete_room(index: int) -> void:
    var rooms: Array = get_rooms()
    if index < 0 or index >= rooms.size():
        return
    var poly: PackedVector2Array = rooms[index]
    if poly.size() < 3:
        return

    # Szoba centroid – ehhez képest toljuk be a tesztpontot
    var centroid: Vector2 = Vector2.ZERO
    for p in poly:
        centroid += p
    centroid /= poly.size()

    # Összes fal végig, visszafelé törölve
    for i in range(walls.size() - 1, -1, -1):
        var w: Dictionary = walls[i]
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2

        # Fal közepe → félúton beljebb a szoba felé
        var mid: Vector2 = (p1 + p2) * 0.5
        var test_point: Vector2 = (mid + centroid) * 0.5

        if Geometry2D.is_point_in_polygon(test_point, poly):
            var wall_id: int = int(w.get("id", -1))

            # Nyílások és eszközök leszedése erről a falról
            for j in range(doors.size() - 1, -1, -1):
                if int(doors[j].get("wall_id", -1)) == wall_id:
                    doors.remove_at(j)

            for j in range(windows.size() - 1, -1, -1):
                if int(windows[j].get("wall_id", -1)) == wall_id:
                    windows.remove_at(j)

            for j in range(devices.size() - 1, -1, -1):
                if int(devices[j].get("wall_id", -1)) == wall_id:
                    devices.remove_at(j)

            walls.remove_at(i)

    rooms_dirty = true
    has_selected_room = false
    selected_room_centroid = Vector2.ZERO
    rooms_dirty = true
    emit_signal("project_changed")
    queue_redraw()

#
# Fallback room detection using a grid flood‑fill.  This method works
# for orthogonal floor plans where walls align with the grid.  It
# constructs a grid covering the entire plan, marks wall positions as
# blocked between adjacent cells, and flood‑fills from outside to find
# interior regions.  Each interior region is then converted to a
# polygon by tracing its outer boundary.
func _compute_rooms_grid() -> Array:
    # Ensure there are walls to process
    if walls.size() == 0:
        return []
    var s: float = ROOM_GRID_STEP_CM
    # Determine bounding box of wall endpoints
    var min_x: float = 1e12
    var min_y: float = 1e12
    var max_x: float = -1e12
    var max_y: float = -1e12
    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        min_x = min(min_x, p1.x, p2.x)
        min_y = min(min_y, p1.y, p2.y)
        max_x = max(max_x, p1.x, p2.x)
        max_y = max(max_y, p1.y, p2.y)
    # Expand bounding box by one grid cell in all directions to include outside
    var min_i: int = int(floor(min_x / s)) - 1
    var max_i: int = int(ceil(max_x / s)) + 1
    var min_j: int = int(floor(min_y / s)) - 1
    var max_j: int = int(ceil(max_y / s)) + 1
    var width_i: int = max_i - min_i
    var width_j: int = max_j - min_j
    if width_i <= 0 or width_j <= 0:
        return []
    # Arrays indicating if there is a wall on the east or south side of each cell
    var blocked_east := []
    var blocked_south := []
    for i in range(width_i):
        var row_e: Array = []
        var row_s: Array = []
        for j in range(width_j):
            row_e.append(false)
            row_s.append(false)
        blocked_east.append(row_e)
        blocked_south.append(row_s)
    # Populate blocked edges from walls
    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        # Horizontal wall if the x difference is greater or equal to y difference
        if abs(p1.x - p2.x) >= abs(p1.y - p2.y):
            # Horizontal wall
            var y_line: float = p1.y
            var j_line: int = int(round(y_line / s)) - min_j
            var i1: int = int(round(min(p1.x, p2.x) / s)) - min_i
            var i2: int = int(round(max(p1.x, p2.x) / s)) - min_i
            for ii in range(i1, i2):
                var j_above: int = j_line - 1
                # Mark the south edge of the cell above as blocked
                if j_above >= 0 and j_above < width_j and ii >= 0 and ii < width_i:
                    blocked_south[ii][j_above] = true
        else:
            # Vertical wall
            var x_line: float = p1.x
            var i_line: int = int(round(x_line / s)) - min_i
            var j1: int = int(round(min(p1.y, p2.y) / s)) - min_j
            var j2: int = int(round(max(p1.y, p2.y) / s)) - min_j
            for jj in range(j1, j2):
                var i_left: int = i_line - 1
                # Mark the east edge of the cell to the left as blocked
                if i_left >= 0 and i_left < width_i and jj >= 0 and jj < width_j:
                    blocked_east[i_left][jj] = true
    # Prepare visited array for flood fill
    var visited: Array = []
    for i in range(width_i):
        var row: Array = []
        for j in range(width_j):
            row.append(false)
        visited.append(row)
    # Flood fill the exterior starting from (0,0)
    var outside_queue: Array = []
    outside_queue.append(Vector2i(0, 0))
    visited[0][0] = true
    while outside_queue.size() > 0:
        var cell: Vector2i = outside_queue.pop_front()
        var ci: int = cell.x
        var cj: int = cell.y
        # East neighbour
        if ci < width_i - 1 and not blocked_east[ci][cj] and not visited[ci + 1][cj]:
            visited[ci + 1][cj] = true
            outside_queue.append(Vector2i(ci + 1, cj))
        # West neighbour
        if ci > 0 and not blocked_east[ci - 1][cj] and not visited[ci - 1][cj]:
            visited[ci - 1][cj] = true
            outside_queue.append(Vector2i(ci - 1, cj))
        # South neighbour (down in Godot coordinate system)
        if cj < width_j - 1 and not blocked_south[ci][cj] and not visited[ci][cj + 1]:
            visited[ci][cj + 1] = true
            outside_queue.append(Vector2i(ci, cj + 1))
        # North neighbour (up)
        if cj > 0 and not blocked_south[ci][cj - 1] and not visited[ci][cj - 1]:
            visited[ci][cj - 1] = true
            outside_queue.append(Vector2i(ci, cj - 1))
    # Identify interior regions (rooms)
    var rooms: Array = []
    for i_idx in range(width_i):
        for j_idx in range(width_j):
            # Skip already visited (exterior) cells
            if visited[i_idx][j_idx]:
                continue
            # Collect all cells in this interior region
            var region_cells: Array = []
            var region_queue: Array = []
            region_queue.append(Vector2i(i_idx, j_idx))
            visited[i_idx][j_idx] = true
            while region_queue.size() > 0:
                var cell2: Vector2i = region_queue.pop_front()
                var ci2: int = cell2.x
                var cj2: int = cell2.y
                region_cells.append(cell2)
                # east
                if ci2 < width_i - 1 and not blocked_east[ci2][cj2] and not visited[ci2 + 1][cj2]:
                    visited[ci2 + 1][cj2] = true
                    region_queue.append(Vector2i(ci2 + 1, cj2))
                # west
                if ci2 > 0 and not blocked_east[ci2 - 1][cj2] and not visited[ci2 - 1][cj2]:
                    visited[ci2 - 1][cj2] = true
                    region_queue.append(Vector2i(ci2 - 1, cj2))
                # south
                if cj2 < width_j - 1 and not blocked_south[ci2][cj2] and not visited[ci2][cj2 + 1]:
                    visited[ci2][cj2 + 1] = true
                    region_queue.append(Vector2i(ci2, cj2 + 1))
                # north
                if cj2 > 0 and not blocked_south[ci2][cj2 - 1] and not visited[ci2][cj2 - 1]:
                    visited[ci2][cj2 - 1] = true
                    region_queue.append(Vector2i(ci2, cj2 - 1))
            # Convert region cells to polygon via boundary edges
            var edges: Dictionary = {}
            for cell3 in region_cells:
                var ci3: int = cell3.x
                var cj3: int = cell3.y
                # world coordinates for the corners of the cell
                var cx: int = ci3 + min_i
                var cy: int = cj3 + min_j
                var x1: float = cx * s
                var y1: float = cy * s
                var x2: float = (cx + 1) * s
                var y2: float = (cy + 1) * s
                # define the four edges (clockwise orientation)
                var pts: Array = [Vector2(x1, y1), Vector2(x2, y1), Vector2(x2, y2), Vector2(x1, y2)]
                for k in range(4):
                    var start_p: Vector2 = pts[k]
                    var end_p: Vector2 = pts[(k + 1) % 4]
                    var key_fwd: String = str(start_p.x) + "," + str(start_p.y) + ":" + str(end_p.x) + "," + str(end_p.y)
                    var key_rev: String = str(end_p.x) + "," + str(end_p.y) + ":" + str(start_p.x) + "," + str(start_p.y)
                    if edges.has(key_rev):
                        edges.erase(key_rev)
                    else:
                        edges[key_fwd] = [start_p, end_p]
            # Now edges contains only boundary edges in arbitrary order
            if edges.size() == 0:
                continue
            # Build polygon by walking through the edges
            var poly_points: Array = []
            # pick an arbitrary edge to start
            var first_key: String = edges.keys()[0]
            var first_pair: Array = edges[first_key]
            var start_pt: Vector2 = first_pair[0]
            var current_pt: Vector2 = first_pair[1]
            poly_points.append(start_pt)
            edges.erase(first_key)
            # Follow edges until we return to start
            while true:
                poly_points.append(current_pt)
                if current_pt == start_pt:
                    break
                var found_next: bool = false
                # find an edge starting from current_pt
                for key in edges.keys():
                    var pair2: Array = edges[key]
                    if pair2[0] == current_pt:
                        current_pt = pair2[1]
                        edges.erase(key)
                        found_next = true
                        break
                if not found_next:
                    # If no continuation was found, we may have a dangling edge; stop
                    break
            # Convert poly_points to PackedVector2Array
            var poly_vec: PackedVector2Array = PackedVector2Array()
            for pt in poly_points:
                poly_vec.append(pt)
            rooms.append(poly_vec)
    return rooms

# ---- room polygon helper for 3D view ----

func _compute_room_polygon() -> PackedVector2Array:
    var points: PackedVector2Array = PackedVector2Array()

    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        points.append(p1)
        points.append(p2)

    if points.size() < 3:
        return PackedVector2Array()

    # Ebből lesz egy egyszerű konvex szoba – prototípusnak elég
    return Geometry2D.convex_hull(points)


func get_room_polygon() -> PackedVector2Array:
    # Return a single polygon for 3D view.  If multiple rooms exist, choose
    # the one with the largest area.  If none exist, fall back to the convex
    # hull of all wall endpoints (simple prototype behaviour).
    var rooms: Array = get_rooms()
    if rooms.size() > 0:
        var max_area: float = -1.0
        var best_poly: PackedVector2Array = PackedVector2Array()
        for poly in rooms:
            if poly.size() < 3:
                continue
            var area := 0.0
            for i in range(poly.size()):
                var a: Vector2 = poly[i]
                var b: Vector2 = poly[(i + 1) % poly.size()]
                area += a.x * b.y - b.x * a.y
            var abs_area: float = abs(area) * 0.5
            if abs_area > max_area:
                max_area = abs_area
                best_poly = poly
        return best_poly
    # Fallback: compute a simple convex hull from endpoints; ensure it is closed
    return _compute_room_polygon()

func _draw_room_outline() -> void:
    # Szobák kirajzolása: kitöltés + kontúr + név
    var rooms: Array = get_rooms()
    if rooms.is_empty():
        return

    var font: Font = ThemeDB.fallback_font
    var idx: int = 0

    for poly in rooms:
        if poly.size() < 3:
            idx += 1
            continue

        # World → screen + centroid
        var screen_poly := PackedVector2Array()
        var centroid: Vector2 = Vector2.ZERO
        for p in poly:
            var sp: Vector2 = world_to_screen(p)
            screen_poly.append(sp)
            centroid += p
        centroid /= poly.size()
        var centroid_screen: Vector2 = world_to_screen(centroid)

        # Kijelölt szoba-e? (centroid alapján)
        var is_selected := false
        if has_selected_room:
            if centroid.distance_to(selected_room_centroid) < grid_step_cm * 0.1:
                is_selected = true

        # Színek kijelölt / nem kijelölt állapotra
        var fill_color: Color
        var outline_color: Color
        var outline_width: float
        if is_selected:
            fill_color = Color(0.6, 0.8, 1.0, 0.15)
            outline_color = Color(0.0, 0.4, 1.0)
            outline_width = 3.0
        else:
            fill_color = Color(1.0, 1.0, 0.0, 0.05)
            outline_color = Color(1.0, 0.7, 0.0)
            outline_width = 2.0

        # Kitöltés + kontúr
        draw_colored_polygon(screen_poly, fill_color)
        var closed := PackedVector2Array(screen_poly)
        closed.append(screen_poly[0])
        draw_polyline(closed, outline_color, outline_width)

        # --- SZOBANÉV ---
        var name_text: String
        if idx >= 0 and idx < room_names.size():
            name_text = room_names[idx]
        else:
            name_text = "Szoba " + str(idx + 1)

        var text_size: Vector2 = font.get_string_size(name_text)
        var text_pos: Vector2 = centroid_screen - Vector2(text_size.x * 0.5, 0.0)
        draw_string(
            font,
            text_pos,
            name_text,
            HORIZONTAL_ALIGNMENT_LEFT,
            -1.0,
            16.0,
            Color(0, 0, 0)
        )

        idx += 1



func select_room_from_point(screen_pos: Vector2) -> void:
    # Determine which room (if any) contains the clicked point.  Iterate
    # through all detected rooms and emit the selection signal for the
    # first one that contains the point.
    var rooms: Array = get_rooms()
    if rooms.size() == 0:
        # Clear selection if no rooms exist
        has_selected_room = false
        queue_redraw()
        return
    var world_pos: Vector2 = screen_to_world(screen_pos)
    var found: bool = false
    for poly in rooms:
        if Geometry2D.is_point_in_polygon(world_pos, poly):
            # Compute centroid of this polygon for highlighting
            var centroid: Vector2 = Vector2.ZERO
            for p in poly:
                centroid += p
            centroid /= poly.size()
            selected_room_centroid = centroid
            has_selected_room = true
            rooms_dirty = true
            emit_signal("room_selected", poly)
            queue_redraw()
            found = true
            break
    if not found:
        # Clicked outside any room: clear selection
        has_selected_room = false
        queue_redraw()

func clear_selected_room() -> void:
    # Clear any currently selected room and refresh drawing.  This is
    # called when exiting 3D view or when selection is reset by the
    # main controller.
    has_selected_room = false
    selected_room_centroid = Vector2.ZERO
    queue_redraw()


# ---- saving / loading ----

func get_project_data() -> Dictionary:
    return {
        "walls": walls,
        "doors": doors,
        "windows": windows,
        "devices": devices
    }


func save_project() -> void:
    var data: Dictionary = get_project_data()
    var json: String = JSON.stringify(data)

    var dir := DirAccess.open("user://")
    if dir and not dir.dir_exists("projektek"):
        dir.make_dir("projektek")

    var f := FileAccess.open("user://projektek/alap.json", FileAccess.WRITE)
    if f:
        f.store_string(json)
        f.close()


func load_project() -> void:
    if not FileAccess.file_exists("user://projektek/alap.json"):
        push_warning("Nincs mentett projekt.")
        return

    var f := FileAccess.open("user://projektek/alap.json", FileAccess.READ)
    if f == null:
        return
    var text: String = f.get_as_text()
    f.close()

    var result : Variant = JSON.parse_string(text)
    if result is Dictionary:
        var d: Dictionary = result
        walls = d.get("walls", []) as Array
        doors = d.get("doors", []) as Array
        windows = d.get("windows", []) as Array
        devices = d.get("devices", []) as Array

        queue_redraw()
        rooms_dirty = true
        emit_signal("project_changed")
