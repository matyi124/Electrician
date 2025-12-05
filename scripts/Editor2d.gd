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

# Grid
var grid_step_cm: float = 20.0

func _ready() -> void:
    set_process_unhandled_input(true)

func set_mode_none() -> void:
    mode = ToolMode.NONE

func set_mode_wall() -> void:
    mode = ToolMode.WALL


func set_mode_door() -> void:
    mode = ToolMode.DOOR


func set_mode_window() -> void:
    mode = ToolMode.WINDOW


# ---- coordinate helpers ----

func world_to_screen(p: Vector2) -> Vector2:
    return view_offset + p * pixels_per_cm * zoom


func screen_to_world(p: Vector2) -> Vector2:
    return (p - view_offset) / (pixels_per_cm * zoom)


func snap_world_to_grid(p: Vector2) -> Vector2:
    var s: float = grid_step_cm
    return Vector2(
        round(p.x / s) * s,
        round(p.y / s) * s
    )


# ---- input ----

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mb := event as InputEventMouseButton

        # Zoom
        if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
            zoom *= 1.1
            queue_redraw()
            return
        if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
            zoom /= 1.1
            zoom = clamp(zoom, 0.2, 4.0)
            queue_redraw()
            return

        # Panning – middle button VAGY bal gomb, ha nincs aktív eszköz
        if mb.button_index == MOUSE_BUTTON_MIDDLE or (mb.button_index == MOUSE_BUTTON_LEFT and mode == ToolMode.NONE):
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
        elif is_drawing_wall:
            queue_redraw()

func _on_left_pressed(pos: Vector2) -> void:
    var world: Vector2 = screen_to_world(pos)

    match mode:
        ToolMode.NONE:
            # Nothing to do, panning already handled in _unhandled_input
            pass

        ToolMode.WALL:
            is_drawing_wall = true
            wall_start_world = snap_world_to_grid(world)

        ToolMode.DOOR, ToolMode.WINDOW:
            var wall_id := _find_nearest_wall(world)
            if wall_id != -1:
                var is_door: bool = (mode == ToolMode.DOOR)
                _place_opening(world, wall_id, is_door)
                emit_signal("project_changed")
                queue_redraw()



func _on_left_released(pos: Vector2) -> void:
    if mode == ToolMode.WALL and is_drawing_wall:
        is_drawing_wall = false
        var end_world: Vector2 = snap_world_to_grid(screen_to_world(pos))
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
            "thickness": 10.0,
            "height": 270.0
        }
        next_wall_id += 1
        walls.append(wall)
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
    emit_signal("project_changed")
    emit_signal("opening_placed", is_door)
    queue_redraw()



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

    emit_signal("project_changed")
    queue_redraw()


# ---- drawing ----

func _draw() -> void:
    _draw_grid()
    _draw_walls()
    _draw_openings()
    _draw_current_wall_preview()
    _draw_room_outline()


func _draw_grid() -> void:
    var viewport_size: Vector2 = get_viewport_rect().size
    var step_px: float = grid_step_cm * pixels_per_cm * zoom
    if step_px < 5.0:
        return

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
    # Doors in blue
    for d_var in doors:
        var d: Dictionary = d_var
        var wall_id: int = int(d.get("wall_id", -1))
        var wall: Dictionary = _get_wall_by_id(wall_id) as Dictionary
        if wall == null:
            continue

        var offset_cm: float = float(d.get("offset_cm", 0.0))
        var width_cm: float = float(d.get("width_cm", 90.0))

        _draw_opening_on_wall(wall, offset_cm, width_cm, Color(0.2, 0.4, 1.0))

    # Windows in green
    for w_var in windows:
        var win: Dictionary = w_var
        var wall_id2: int = int(win.get("wall_id", -1))
        var wall2: Dictionary = _get_wall_by_id(wall_id2) as Dictionary
        if wall2 == null:
            continue

        var offset_cm2: float = float(win.get("offset_cm", 0.0))
        var width_cm2: float = float(win.get("width_cm", 120.0))

        _draw_opening_on_wall(wall2, offset_cm2, width_cm2, Color(0.2, 0.8, 0.2))




func _get_wall_by_id(id: int) -> Variant:
    for w_var in walls:
        var w: Dictionary = w_var
        var wid: int = int(w.get("id", -1))
        if wid == id:
            return w
    return null




func _draw_opening_on_wall(wall: Dictionary, offset_cm: float, width_cm: float, color: Color) -> void:
    var p1: Vector2 = wall.get("p1") as Vector2
    var p2: Vector2 = wall.get("p2") as Vector2
    var dir: Vector2 = (p2 - p1).normalized()
    var start: Vector2 = p1 + dir * offset_cm
    var endp: Vector2 = start + dir * width_cm
    draw_line(world_to_screen(start), world_to_screen(endp), color, 4.0)


func _draw_current_wall_preview() -> void:
    if not is_drawing_wall:
        return
    var mouse_pos: Vector2 = get_viewport().get_mouse_position()
    var world_end: Vector2 = snap_world_to_grid(screen_to_world(mouse_pos))
    draw_line(world_to_screen(wall_start_world), world_to_screen(world_end), Color(0.7, 0.0, 0.0), 2.0)


# ---- room detection & drawing ----

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
    # Start from convex hull of wall endpoints
    var poly: PackedVector2Array = _compute_room_polygon()
    if poly.size() < 3:
        return _compute_room_polygon()

    # Check: every edge of the polygon must correspond to an actual wall segment
    var eps := 1.0
    var count_edges := poly.size()
    for i in range(count_edges):
        var a: Vector2 = poly[i]
        var b: Vector2 = poly[(i + 1) % count_edges]
        var edge_ok: bool = false

        for w_var in walls:
            var w: Dictionary = w_var
            var p1: Vector2 = w.get("p1") as Vector2
            var p2: Vector2 = w.get("p2") as Vector2

            var match_ab := a.distance_to(p1) < eps and b.distance_to(p2) < eps
            var match_ba := a.distance_to(p2) < eps and b.distance_to(p1) < eps
            if match_ab or match_ba:
                edge_ok = true
                break

        if not edge_ok:
            # Not a closed room, return empty
            return PackedVector2Array()

    return poly

func _draw_room_outline() -> void:
    var poly: PackedVector2Array = get_room_polygon()
    if poly.size() < 3:
        return

    var screen_poly: PackedVector2Array = PackedVector2Array()
    for p in poly:
        screen_poly.append(world_to_screen(p))

    draw_colored_polygon(screen_poly, Color(1, 1, 0, 0.05))
    var closed := PackedVector2Array(screen_poly)
    closed.append(screen_poly[0])
    draw_polyline(closed, Color(1, 0.7, 0), 2.0)

func select_room_from_point(screen_pos: Vector2) -> void:
    var poly: PackedVector2Array = get_room_polygon()
    if poly.size() < 3:
        return
    var world_pos: Vector2 = screen_to_world(screen_pos)
    if Geometry2D.is_point_in_polygon(world_pos, poly):
        emit_signal("room_selected", poly)


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
        emit_signal("project_changed")
