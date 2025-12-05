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

# Rooms
var room_polygons: Array[PackedVector2Array] = []
var selected_room_index: int = -1
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

func _point_key(p: Vector2) -> String:
    var snapped := p.snapped(Vector2(0.01, 0.01))
    return str(snapped.x) + ":" + str(snapped.y)

func _merge_point(p: Vector2, merged: Array[Vector2], eps: float) -> Vector2:
    for existing in merged:
        if existing.distance_to(p) <= eps:
            return existing
    merged.append(p)
    return p


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
            # Room selection when no drawing tool is active
            select_room_from_point(pos)

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
        _mark_rooms_dirty()
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
    _draw_room_outlines()


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

func _build_graph() -> Dictionary:
    var merged_points: Array[Vector2] = []
    var point_lookup: Dictionary = {}
    var adjacency: Dictionary = {}
    var merge_eps: float = 0.5

    for w_var in walls:
        var w: Dictionary = w_var
        var raw_p1: Vector2 = w.get("p1") as Vector2
        var raw_p2: Vector2 = w.get("p2") as Vector2
        var p1: Vector2 = _merge_point(raw_p1, merged_points, merge_eps)
        var p2: Vector2 = _merge_point(raw_p2, merged_points, merge_eps)

        var k1 := _point_key(p1)
        var k2 := _point_key(p2)
        point_lookup[k1] = p1
        point_lookup[k2] = p2

        if not adjacency.has(k1):
            adjacency[k1] = []
        if not adjacency.has(k2):
            adjacency[k2] = []
        if not adjacency[k1].has(k2):
            adjacency[k1].append(k2)
        if not adjacency[k2].has(k1):
            adjacency[k2].append(k1)

    return {
        "points": point_lookup,
        "adj": adjacency
    }


func _mark_rooms_dirty() -> void:
    rooms_dirty = true
    selected_room_index = -1


func _polygon_centroid(poly: PackedVector2Array) -> Vector2:
    var area: float = 0.0
    var cx: float = 0.0
    var cy: float = 0.0

    for i in range(poly.size()):
        var p0 := poly[i]
        var p1 := poly[(i + 1) % poly.size()]
        var cross := p0.x * p1.y - p1.x * p0.y
        area += cross
        cx += (p0.x + p1.x) * cross
        cy += (p0.y + p1.y) * cross

    if abs(area) < 0.0001:
        return poly[0] if poly.size() > 0 else Vector2.ZERO

    var scale := 1.0 / (3.0 * area)
    return Vector2(cx * scale, cy * scale)


func _next_neighbor(prev_key: String, current_key: String, adjacency: Dictionary, point_lookup: Dictionary) -> String:
    var neighbors: Array = adjacency.get(current_key, [])
    if neighbors.size() == 0:
        return ""

    var current: Vector2 = point_lookup[current_key]
    var prev: Vector2 = point_lookup.get(prev_key, current)
    var best_key: String = ""
    var best_diff: float = TAU
    var angle_prev: float = atan2(prev.y - current.y, prev.x - current.x)

    for n in neighbors:
        var n_key := String(n)
        if n_key == prev_key and neighbors.size() == 1:
            continue
        var neighbor: Vector2 = point_lookup[n_key]
        var angle_next: float = atan2(neighbor.y - current.y, neighbor.x - current.x)
        var diff: float = fposmod(angle_next - angle_prev, TAU)
        if diff == 0.0:
            diff = TAU
        if diff < best_diff:
            best_diff = diff
            best_key = n_key

    return best_key


func _compute_room_polygons() -> Array[PackedVector2Array]:
    var graph := _build_graph()
    var point_lookup: Dictionary = graph.get("points", {})
    var adjacency: Dictionary = graph.get("adj", {})

    var polygons: Array[PackedVector2Array] = []
    if adjacency.size() < 3:
        return polygons

    var visited: Dictionary = {}

    for from_key in adjacency.keys():
        for to_key in adjacency[from_key]:
            var dir_key := String(from_key) + "->" + String(to_key)
            if visited.has(dir_key):
                continue

            var polygon := PackedVector2Array()
            var start_from: String = String(from_key)
            var start_to: String = String(to_key)
            var current_from: String = start_from
            var current_to: String = start_to

            var safety: int = adjacency.size() * 8
            while safety > 0:
                safety -= 1
                visited[current_from + "->" + current_to] = true
                polygon.append(point_lookup[current_from])

                var next_key := _next_neighbor(current_from, current_to, adjacency, point_lookup)
                if next_key == "":
                    break

                current_from = current_to
                current_to = next_key

                if current_from == start_from and current_to == start_to:
                    polygon.append(point_lookup[current_from])
                    break

            if polygon.size() >= 4:
                polygon.remove_at(polygon.size() - 1)  # remove duplicate closing point
                var area := Geometry2D.signed_polygon_area(polygon)
                if abs(area) > 0.1:
                    if area < 0.0:
                        polygon = polygon.reversed()

                    var is_duplicate: bool = false
                    for existing in polygons:
                        if existing.size() != polygon.size():
                            continue

                        var offset := -1
                        for i in range(existing.size()):
                            if polygon[0].distance_to(existing[i]) <= 0.1:
                                offset = i
                                break

                        if offset == -1:
                            continue

                        var all_close := true
                        for i in range(polygon.size()):
                            var idx := (i + offset) % polygon.size()
                            if abs(polygon[i].distance_to(existing[idx])) > 0.1:
                                all_close = false
                                break

                        if all_close:
                            is_duplicate = true
                            break
                    if not is_duplicate:
                        polygons.append(polygon)

    if polygons.size() <= 1:
        return polygons

    # Remove likely outer hull if it contains other polygons (avoid dropping large actual rooms)
    var areas: Array[float] = []
    for poly in polygons:
        areas.append(abs(Geometry2D.signed_polygon_area(poly)))

    var outer_index: int = -1
    var max_area: float = -1.0
    for i in range(polygons.size()):
        if areas[i] > max_area:
            max_area = areas[i]
            outer_index = i

    if outer_index >= 0:
        var candidate := polygons[outer_index]
        var contains_other: bool = false
        for j in range(polygons.size()):
            if j == outer_index:
                continue
            var test_point: Vector2 = _polygon_centroid(polygons[j])
            if Geometry2D.is_point_in_polygon(test_point, candidate):
                contains_other = true
                break

        if contains_other:
            polygons.remove_at(outer_index)

    if polygons.is_empty():
        var fallback := _build_single_loop_polygon(adjacency, point_lookup)
        if fallback.size() >= 3:
            polygons.append(fallback)

    return polygons


func _build_single_loop_polygon(adjacency: Dictionary, point_lookup: Dictionary) -> PackedVector2Array:
    if adjacency.size() < 3:
        return PackedVector2Array()

    for key in adjacency.keys():
        var neighbors: Array = adjacency.get(key, [])
        if neighbors.size() != 2:
            return PackedVector2Array()  # not a simple loop

    var start_key: String = String(adjacency.keys()[0])
    var prev_key: String = String(adjacency[start_key][0])
    var current_key: String = start_key
    var polygon := PackedVector2Array()
    var max_steps: int = adjacency.size() * 2

    while max_steps > 0:
        max_steps -= 1
        polygon.append(point_lookup[current_key])
        var neighbors: Array = adjacency.get(current_key, [])
        var next_key: String = String(neighbors[0]) if String(neighbors[0]) != prev_key else String(neighbors[1])
        prev_key = current_key
        current_key = next_key
        if current_key == start_key:
            break

    if polygon.size() < 3:
        return PackedVector2Array()

    var closed := PackedVector2Array(polygon)
    closed.append(polygon[0])
    if Geometry2D.is_polygon_self_intersecting(closed):
        return PackedVector2Array()

    if Geometry2D.signed_polygon_area(polygon) < 0.0:
        polygon = polygon.reversed()

    return polygon


func get_room_polygons() -> Array[PackedVector2Array]:
    if rooms_dirty:
        room_polygons = _compute_room_polygons()
        rooms_dirty = false
    if selected_room_index >= room_polygons.size():
        selected_room_index = -1
    return room_polygons


func get_room_polygon() -> PackedVector2Array:
    var polys: Array[PackedVector2Array] = get_room_polygons()
    if selected_room_index >= 0 and selected_room_index < polys.size():
        return polys[selected_room_index]
    if polys.size() > 0:
        return polys[0]
    return PackedVector2Array()


func _draw_room_outlines() -> void:
    var polys: Array[PackedVector2Array] = get_room_polygons()
    for i in range(polys.size()):
        var poly: PackedVector2Array = polys[i]
        if poly.size() < 3:
            continue

        var screen_poly: PackedVector2Array = PackedVector2Array()
        for p in poly:
            screen_poly.append(world_to_screen(p))

        var fill_color := Color(1, 1, 0, 0.05)
        var line_color := Color(1, 0.7, 0)
        if i == selected_room_index:
            fill_color = Color(0.4, 0.8, 1.0, 0.1)
            line_color = Color(0.2, 0.4, 1.0)

        draw_colored_polygon(screen_poly, fill_color)
        var closed := PackedVector2Array(screen_poly)
        closed.append(screen_poly[0])
        draw_polyline(closed, line_color, 2.0)


func select_room_from_point(screen_pos: Vector2) -> void:
    var polys: Array[PackedVector2Array] = get_room_polygons()
    var world_pos: Vector2 = screen_to_world(screen_pos)
    selected_room_index = -1

    for i in range(polys.size()):
        var poly: PackedVector2Array = polys[i]
        if poly.size() < 3:
            continue
        if Geometry2D.is_point_in_polygon(world_pos, poly):
            selected_room_index = i
            emit_signal("room_selected", poly)
            queue_redraw()
            return

    emit_signal("room_selected", PackedVector2Array())
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

    var err := DirAccess.make_dir_recursive_absolute("user://projektek")
    if err != OK:
        push_warning("Nem sikerült létrehozni a mentési mappát (" + str(err) + ").")
        return

    var f := FileAccess.open("user://projektek/alap.json", FileAccess.WRITE)
    if f == null:
        push_warning("Nem sikerült megnyitni a mentési fájlt írásra.")
        return

    f.store_string(json)
    f.close()


func load_project() -> void:
    if not FileAccess.file_exists("user://projektek/alap.json"):
        push_warning("Nincs mentett projekt.")
        return

    var f := FileAccess.open("user://projektek/alap.json", FileAccess.READ)
    if f == null:
        push_warning("Nem sikerült megnyitni a mentési fájlt olvasásra.")
        return
    var text: String = f.get_as_text()
    f.close()

    var result : Variant = JSON.parse_string(text)
    if result is not Dictionary:
        push_warning("Hibás vagy sérült projektfájl.")
        return

    var d: Dictionary = result
    walls = d.get("walls", []) as Array
    doors = d.get("doors", []) as Array
    windows = d.get("windows", []) as Array
    devices = d.get("devices", []) as Array

    _mark_rooms_dirty()

    queue_redraw()
    emit_signal("project_changed")
