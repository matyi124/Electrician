extends Node3D

## Simple 3D room visualizer.
## Builds wall meshes and a floor from a 2D polygon (cm units).

@onready var camera: Camera3D = $Camera3D
@onready var walls_root: Node3D = $Walls
@onready var floor_mesh: MeshInstance3D = $Floor
@onready var devices_root: Node3D = $Devices

# Default height of all walls in centimetres.  This defines the Y dimension
# for both walls and openings.  It can be overridden in the editor but
# remains constant during 3D generation.  The requirement is that all
# walls are 250 cm high.
var wall_height_cm: float = 250.0
var wall_thickness_cm: float = 10.0

## Colour used for all walls.  All wall segments share this same
## material so that the room has a uniform appearance.  You can
## adjust this value to any `Color` you prefer; the default is a
## slightly bluish grey.  Previously different wall segments could
## end up with different colours due to earlier experiments, but
## this constant ensures consistency.
var wall_color: Color = Color(0.25, 0.35, 0.45)

## Colours for openings.  Doors are a dark grey and windows a bright blue to
## ensure they are easy to spot against the walls.  You can tweak these
## values to taste.  Note that the saturation and brightness here are
## deliberately higher than the wall colour so that openings stand out.
const DOOR_COLOR: Color = Color(0.7, 0.4, 0.2)
const WINDOW_COLOR: Color = Color(0.2, 0.7, 0.9)

## Thickness of the extruded box used for doors and windows.  A larger value
## makes the opening geometry more visible while still avoiding z‑fighting
## with the wall mesh.  This value should remain less than or equal to
## wall_thickness_cm so that openings do not protrude beyond the wall.
const OPENING_THICKNESS_CM: float = 6.0

## Small gap (in cm) between the opening's front face and the wall's inner
## surface.  Without this, the door or window front is exactly coplanar
## with the wall, which causes z‑fighting when moving the camera.  A
## small gap pushes the opening slightly into the room so it renders
## cleanly.  You can adjust this value (e.g. 0.1–1.0).  It must be
## non‑negative and should be much smaller than the wall thickness.
const OPENING_GAP_CM: float = 0.5

# Center of the current room in world coordinates (X,Z) and mid-height on Y.
var room_center: Vector3 = Vector3.ZERO

# 2D center of the current room (on XZ plane).  This is used to
# determine which side of a wall is outside when offsetting for
# wall thickness.  It is computed in build_room() alongside
# room_center and stored so that `_create_wall_segment` can test
# normals against it.
var room_center2d: Vector2 = Vector2.ZERO

# Whether the camera should be placed inside the room at the centre. When true,
# orbit controls are disabled and the camera position is locked to
# `room_center`.
var inside_view: bool = false

@onready var ambient_env: WorldEnvironment = null
@onready var ceiling_root: Node3D = null

# Camera orbit state
var orbit_distance: float = 400.0  # cm
var orbit_yaw: float = deg_to_rad(45.0)
var orbit_pitch: float = deg_to_rad(-20.0)
var last_drag_pos: Vector2
var dragging: bool = false

var default_orbit_distance: float = 400.0  # default distance used when leaving inside view

## Exit the inside view and restore the default orbiting behaviour.
## This should be called when switching back to 2D so that the
## 3D camera returns to its original orbit settings.  It resets
## inside_view, restores orbit_distance and repositions the camera.
func exit_view() -> void:
    if not inside_view:
        return
    inside_view = false
    orbit_distance = default_orbit_distance
    # Reset pitch to a comfortable angle if it was clamped up when inside.
    orbit_pitch = clamp(orbit_pitch, deg_to_rad(-80), deg_to_rad(-5))
    _update_camera()

func _ready() -> void:
    set_process_unhandled_input(true)
    # Set up a basic ambient light so the room is illuminated from all directions.
    ambient_env = WorldEnvironment.new()
    var env := Environment.new()
    env.ambient_light_color = Color(1.0, 1.0, 1.0)
    env.ambient_light_energy = 1.0
    ambient_env.environment = env
    add_child(ambient_env)
    # Node to hold the ceiling mesh instance.
    ceiling_root = Node3D.new()
    add_child(ceiling_root)
    _update_camera()

func build_room(polygon: PackedVector2Array, walls: Array, doors: Array, windows: Array, devices: Array) -> void:
    # Clear old meshes
    for c in walls_root.get_children():
        c.queue_free()
    for c in devices_root.get_children():
        c.queue_free()
    # Clear old ceiling mesh
    for c in ceiling_root.get_children():
        c.queue_free()

    if polygon.size() < 3:
        return

    # Ensure the polygon vertices are wound counter‑clockwise.  If the
    # signed area is negative, the vertices are clockwise and we reverse
    # them.  Correct winding is important for consistent triangulation
    # and wall orientation.
    var area: float = 0.0
    for i in range(polygon.size()):
        var p_i: Vector2 = polygon[i]
        var p_j: Vector2 = polygon[(i + 1) % polygon.size()]
        area += p_i.x * p_j.y - p_j.x * p_i.y
    # Copy to local variable; reverse order if needed to ensure CCW winding.
    var poly_local: PackedVector2Array = PackedVector2Array()
    # In screen coordinate system (Y axis down), a positive signed area indicates
    # clockwise winding.  We want counterclockwise (CCW) for proper outward normals.
    # So reverse when area > 0 (clockwise), keep as is when area < 0 (CCW).
    if area > 0.0:
        # Reverse vertices to make CCW
        for i in range(polygon.size()):
            poly_local.append(polygon[polygon.size() - 1 - i])
    else:
        # Create a copy of the original polygon
        for p in polygon:
            poly_local.append(p)


    # Compute the room centre in XZ plane and mid‑height on Y.  Used for the
    # inside camera view.  Use the possibly reordered local polygon.
    var centre2d: Vector2 = Vector2.ZERO
    for p in poly_local:
        centre2d += p
    centre2d /= poly_local.size()
    room_center = Vector3(centre2d.x, wall_height_cm * 0.5, centre2d.y)
    # Store the 2D centre for later use when computing outward normals.
    room_center2d = centre2d
    inside_view = true

    # Create the floor mesh with a custom colour (light grey).  A lighter floor
    # helps distinguish it from the walls and ceiling in the 3D view.  Adjust
    # these values if you prefer darker or lighter flooring.
    var floor_color := Color(0.8, 0.8, 0.8)
    var floor_mesh_res := _create_polygon_mesh(poly_local, 0.0, floor_color)
    floor_mesh.mesh = floor_mesh_res

    # Create the ceiling mesh with a distinct colour.  A very light colour
    # emphasises the presence of the ceiling when you look up in the 3D view.
    var ceiling_color := Color(0.95, 0.95, 0.95)
    var ceiling_mesh_res := _create_polygon_mesh(poly_local, wall_height_cm, ceiling_color)
    var ceiling_inst := MeshInstance3D.new()
    ceiling_inst.mesh = ceiling_mesh_res
    ceiling_root.add_child(ceiling_inst)

    # Build walls as individual segments.  Using separate box meshes per wall
    # segment avoids the complexity of generating an offset polygon and
    # works reliably for arbitrary convex or orthogonal room shapes.
    # Extrude each edge of the polygon as a wall.  Record which segments have
    # been extruded so we can avoid duplicating the geometry for duplicate
    # walls in the 2D data.
    var used_edges: Dictionary = {}
    for i in range(poly_local.size()):
        var a: Vector2 = poly_local[i]
        var b: Vector2 = poly_local[(i + 1) % poly_local.size()]
        _create_wall_segment(a, b)
        # Record both orientations as used
        var key1: String = str(a.x) + "," + str(a.y) + ":" + str(b.x) + "," + str(b.y)
        var key2: String = str(b.x) + "," + str(b.y) + ":" + str(a.x) + "," + str(a.y)
        used_edges[key1] = true
        used_edges[key2] = true
    # Additionally extrude all walls from the 2D data to handle interior partitions.
    for w_var in walls:
        var w: Dictionary = w_var
        var p1: Vector2 = w.get("p1") as Vector2
        var p2: Vector2 = w.get("p2") as Vector2
        var k1: String = str(p1.x) + "," + str(p1.y) + ":" + str(p2.x) + "," + str(p2.y)
        var k2: String = str(p2.x) + "," + str(p2.y) + ":" + str(p1.x) + "," + str(p1.y)
        if used_edges.has(k1) or used_edges.has(k2):
            continue
        used_edges[k1] = true
        used_edges[k2] = true
        _create_wall_segment(p1, p2)

    # Create door meshes for each door definition.  A door is represented as
    # a simple box extruded along the wall at a specified offset.  It is
    # positioned at the given offset measured from the start of the wall and
    # rests on the floor (sill height of 0).  Doors are coloured dark grey to
    # contrast with the walls.
    for d_var in doors:
        var d: Dictionary = d_var
        var wall_id: int = int(d.get("wall_id", -1))
        # Find the associated wall definition in the walls array
        # Use a generic variable for the wall definition.  We do not specify
        # a type here because assigning `null` to a typed Dictionary is
        # invalid in GDScript 4.  Instead we use an untyped variable and
        # later treat it as a Dictionary once it is found.
        var wall_def = null
        for w_var in walls:
            var w: Dictionary = w_var
            if int(w.get("id", -1)) == wall_id:
                wall_def = w
                break
        if wall_def == null:
            continue
        var p1_d: Vector2 = wall_def.get("p1") as Vector2
        var p2_d: Vector2 = wall_def.get("p2") as Vector2
        var offset_cm: float = float(d.get("offset_cm", 0.0))
        var width_cm: float = float(d.get("width_cm", 90.0))
        var height_cm: float = float(d.get("height_cm", 210.0))
        # Doors always have sill height 0 – they sit on the floor
        var sill_cm: float = 0.0
        # Use the constant door colour so doors remain visible against the wall.
        _create_opening_mesh(p1_d, p2_d, offset_cm, width_cm, height_cm, sill_cm, DOOR_COLOR)

    # Create window meshes for each window definition.  Windows are similar
    # to doors but can be placed at an elevation above the floor defined by
    # the sill height.  Windows are coloured light blue to differentiate
    # them from doors and walls.
    for win_var in windows:
        var wdef: Dictionary = win_var
        var wall_id2: int = int(wdef.get("wall_id", -1))
        var wall_def2 = null
        for w_var in walls:
            var w: Dictionary = w_var
            if int(w.get("id", -1)) == wall_id2:
                wall_def2 = w
                break
        if wall_def2 == null:
            continue
        var p1_w: Vector2 = wall_def2.get("p1") as Vector2
        var p2_w: Vector2 = wall_def2.get("p2") as Vector2
        var offset_cm2: float = float(wdef.get("offset_cm", 0.0))
        var width_cm2: float = float(wdef.get("width_cm", 120.0))
        var height_cm2: float = float(wdef.get("height_cm", 120.0))
        var sill_cm2: float = float(wdef.get("sill_cm", 90.0))
        # Use the constant window colour so windows remain visible against the wall.
        _create_opening_mesh(p1_w, p2_w, offset_cm2, width_cm2, height_cm2, sill_cm2, WINDOW_COLOR)

    # Simple device visualisation: colored boxes on walls (ignoring exact relation to walls for now)
    for d in devices:
        _create_device_mesh(d)

    # After creating geometry, update the camera to sit at the room centre.
    _update_camera()

func _create_floor_mesh(polygon: PackedVector2Array) -> Mesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_color(Color(0.9, 0.9, 0.9))

    # Triangulate polygon
    var tri_indices := Geometry2D.triangulate_polygon(polygon)
    for i in range(0, tri_indices.size(), 3):
        var i0 := tri_indices[i]
        var i1 := tri_indices[i + 1]
        var i2 := tri_indices[i + 2]
        var p0 := Vector3(polygon[i0].x, 0.0, polygon[i0].y)
        var p1 := Vector3(polygon[i1].x, 0.0, polygon[i1].y)
        var p2 := Vector3(polygon[i2].x, 0.0, polygon[i2].y)
        st.add_vertex(p0)
        st.add_vertex(p1)
        st.add_vertex(p2)

    return st.commit()

# Create a flat Mesh for a polygon at a given Y height and with a given color.
func _create_polygon_mesh(polygon: PackedVector2Array, height_y: float, color: Color) -> Mesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_color(color)
    var tri_indices := Geometry2D.triangulate_polygon(polygon)
    for i in range(0, tri_indices.size(), 3):
        var i0 := tri_indices[i]
        var i1 := tri_indices[i + 1]
        var i2 := tri_indices[i + 2]
        var p0 := Vector3(polygon[i0].x, height_y, polygon[i0].y)
        var p1 := Vector3(polygon[i1].x, height_y, polygon[i1].y)
        var p2 := Vector3(polygon[i2].x, height_y, polygon[i2].y)
        st.add_vertex(p0)
        st.add_vertex(p1)
        st.add_vertex(p2)
    return st.commit()

func _create_wall_segment(a2d: Vector2, b2d: Vector2) -> void:
    var length_cm := a2d.distance_to(b2d)
    if length_cm < 1.0:
        return

    # Compute the direction vector along the segment and ignore offset.
    var seg: Vector2 = b2d - a2d
    if seg.length() == 0.0:
        return
    var dir2d: Vector2 = seg.normalized()
    # Create the box mesh: X dimension along wall length, Z dimension thickness.
    var mesh := BoxMesh.new()
    mesh.size = Vector3(length_cm, wall_height_cm, wall_thickness_cm)
    var inst := MeshInstance3D.new()
    inst.mesh = mesh
    # Apply the global wall colour.  Using a shared constant ensures
    # that every wall segment has exactly the same appearance.
    var wall_mat := StandardMaterial3D.new()
    wall_mat.albedo_color = wall_color
    inst.material_override = wall_mat
    # Position: centre between a and b without any offset.  This means the wall
    # extends equally on both sides of the 2D line.  While this slightly
    # intrudes into the interior, it ensures walls are visible and prevents
    # numerical issues with offsetting.
    var mid2d: Vector2 = (a2d + b2d) * 0.5
    var pos := Vector3(mid2d.x, wall_height_cm * 0.5, mid2d.y)
    inst.transform.origin = pos
    # Orientation: align the box's X axis with the wall direction.
    var angle_y := atan2(dir2d.y, dir2d.x)
    inst.rotation = Vector3(0.0, angle_y, 0.0)
    walls_root.add_child(inst)

## Create a mesh instance for a door or window on a given wall segment.
## `a2d` and `b2d` define the start and end of the wall in 2D.  The opening
## is positioned along the wall at `offset_cm` from `a2d`.  The width and
## height define its size, and `sill_cm` specifies the bottom height above
## the floor.  A `color` parameter allows doors and windows to be
## differentiated visually.  Openings are centred across the wall
## thickness.
func _create_opening_mesh(a2d: Vector2, b2d: Vector2, offset_cm: float, width_cm: float, height_cm: float, sill_cm: float, color: Color) -> void:
    var seg: Vector2 = b2d - a2d
    var length_cm := seg.length()
    if length_cm <= 0.001:
        return
    var dir2d: Vector2 = seg.normalized()
    # Midpoint of the opening along the wall (offset to centre of opening)
    var mid_offset: float = offset_cm + width_cm * 0.5
    # Compute world position of the opening's centre on XZ plane
    var centre2d: Vector2 = a2d + dir2d * mid_offset
    # Create a box mesh representing the opening.  We use a reduced
    # thickness so that the opening does not z‑fight with the wall surface.
    # A constant thickness of 4 cm (or half the wall thickness if thinner)
    # makes doors and windows visually distinct but avoids overlapping the
    # wall.  You can adjust this value as desired.
    # Use a fixed thickness for openings so they stand out from the wall.  We cap
    # it at the wall thickness to ensure the opening does not extend beyond
    # the wall into the exterior space.
    var thickness_cm: float = min(OPENING_THICKNESS_CM, wall_thickness_cm)
    var mesh := BoxMesh.new()
    mesh.size = Vector3(width_cm, height_cm, thickness_cm)
    var inst := MeshInstance3D.new()
    inst.mesh = mesh
    var mat := StandardMaterial3D.new()
    mat.albedo_color = color
    inst.material_override = mat
    # Compute a normal vector perpendicular to the wall in 2D.  We will
    # offset the opening along this direction so that it sits flush
    # against the interior side of the wall and does not intersect the
    # wall mesh.  The orientation of the normal is chosen so it always
    # points towards the room centre.  If the dot product between the
    # normal and (centre -> room centre) is negative (i.e. normal points
    # away from the room centre), we invert it.
    var norm2d: Vector2 = Vector2(dir2d.y, -dir2d.x)
    var to_centre: Vector2 = room_center2d - centre2d
    if norm2d.dot(to_centre) < 0.0:
        norm2d = -norm2d
    norm2d = norm2d.normalized()
    # Compute the distance from the wall centre to the opening centre.  We
    # subtract a small gap so that the front face of the opening sits just
    # inside the interior surface.  This avoids z‑fighting when the
    # opening and wall surfaces would otherwise be coplanar.  Clamp the
    # result to zero to avoid negative offsets on extremely thin walls.
    var offset_dist: float = (wall_thickness_cm - thickness_cm) * 0.5 - OPENING_GAP_CM
    if offset_dist < 0.0:
        offset_dist = 0.0
    var offset_vec2d: Vector2 = norm2d * offset_dist
    # Position: centre in 3D, offset along the normal and with Y = sill + half height
    var pos := Vector3(centre2d.x + offset_vec2d.x, sill_cm + height_cm * 0.5, centre2d.y + offset_vec2d.y)
    inst.transform.origin = pos
    # Orient the opening to align with the wall
    var angle_y: float = atan2(dir2d.y, dir2d.x)
    inst.rotation = Vector3(0.0, angle_y, 0.0)
    walls_root.add_child(inst)

## Compute an outward offset polygon from a 2D CCW polygon.  The offset
## distance is measured from the original polygon edges along their outward
## normals.  For convex polygons this yields a valid shape; concave shapes
## may self‑intersect.
func _compute_offset_polygon(poly: PackedVector2Array, offset: float) -> PackedVector2Array:
    var n: int = poly.size()
    var off_poly := PackedVector2Array()
    if n < 3:
        return off_poly
    # Compute the centre of the polygon (used to determine outward normal directions).
    var centre: Vector2 = Vector2.ZERO
    for p in poly:
        centre += p
    centre /= n
    # Precompute outward normals for each segment.
    var normals: Array = []
    normals.resize(n)
    for i in range(n):
        var a: Vector2 = poly[i]
        var b: Vector2 = poly[(i + 1) % n]
        var seg: Vector2 = b - a
        var seg_len: float = seg.length()
        if seg_len < 1e-8:
            normals[i] = Vector2.ZERO
            continue
        var dir2d: Vector2 = seg / seg_len
        # Candidate normal from cross(up, dir) i.e. (dy, -dx)
        var n2d: Vector2 = Vector2(dir2d.y, -dir2d.x)
        # Determine if this normal points towards the centre; if so, flip it
        var mid: Vector2 = (a + b) * 0.5
        var to_centre: Vector2 = centre - mid
        if n2d.dot(to_centre) > 0.0:
            n2d = -n2d
        normals[i] = n2d.normalized()
    # Compute intersection points for the offset polygon
    for i in range(n):
        var a_prev: Vector2 = poly[(i - 1 + n) % n]
        var a_curr: Vector2 = poly[i]
        var u_prev: Vector2 = (a_curr - a_prev)
        var len_prev: float = u_prev.length()
        if len_prev < 1e-8:
            u_prev = normals[(i - 1 + n) % n]
        else:
            u_prev /= len_prev
        var u_curr: Vector2 = (poly[(i + 1) % n] - a_curr)
        var len_curr: float = u_curr.length()
        if len_curr < 1e-8:
            u_curr = normals[i]
        else:
            u_curr /= len_curr
        var n_prev2: Vector2 = normals[(i - 1 + n) % n]
        var n_curr2: Vector2 = normals[i]
        # Offset points on the two lines
        var p1: Vector2 = a_curr + n_prev2 * offset
        var p2: Vector2 = a_curr + n_curr2 * offset
        # Solve intersection of lines p1 + u_prev * t and p2 + u_curr * s
        var denom: float = u_prev.x * u_curr.y - u_prev.y * u_curr.x
        var intersect: Vector2
        if abs(denom) < 1e-8:
            # Parallel or nearly parallel edges; move the point along average normal
            var avg_n: Vector2 = (n_prev2 + n_curr2)
            if avg_n.length() > 1e-8:
                avg_n = avg_n.normalized()
            intersect = a_curr + avg_n * offset
        else:
            var diff: Vector2 = p2 - p1
            var t: float = (diff.x * u_curr.y - diff.y * u_curr.x) / denom
            intersect = p1 + u_prev * t
        off_poly.append(intersect)
    return off_poly

## Generate a wall mesh by connecting a CCW polygon and its outward offset polygon.
## The resulting mesh consists of two faces per edge: an inner face (towards
## the room) and an outer face (outside wall).  Floor and ceiling surfaces are
## generated separately, so we don't seal the top or bottom of the walls here.
func _create_wall_mesh(inner_poly: PackedVector2Array, outer_poly: PackedVector2Array) -> Mesh:
    var n = inner_poly.size()
    if n < 3 or outer_poly.size() != n:
        return null
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    # Use a consistent wall color (slightly off‑white)
    var wall_color := Color(0.85, 0.85, 0.88)
    st.set_color(wall_color)
    for i in range(n):
        var j: int = (i + 1) % n
        var p0: Vector2 = inner_poly[i]
        var p1: Vector2 = inner_poly[j]
        var q0: Vector2 = outer_poly[i]
        var q1: Vector2 = outer_poly[j]
        # Convert to 3D points
        var p0_bottom: Vector3 = Vector3(p0.x, 0.0, p0.y)
        var p0_top: Vector3 = Vector3(p0.x, wall_height_cm, p0.y)
        var p1_bottom: Vector3 = Vector3(p1.x, 0.0, p1.y)
        var p1_top: Vector3 = Vector3(p1.x, wall_height_cm, p1.y)
        var q0_bottom: Vector3 = Vector3(q0.x, 0.0, q0.y)
        var q0_top: Vector3 = Vector3(q0.x, wall_height_cm, q0.y)
        var q1_bottom: Vector3 = Vector3(q1.x, 0.0, q1.y)
        var q1_top: Vector3 = Vector3(q1.x, wall_height_cm, q1.y)
        # Outer face (facing outward): q0_bottom -> q1_bottom -> q0_top and q0_top -> q1_bottom -> q1_top
        st.add_vertex(q0_bottom)
        st.add_vertex(q1_bottom)
        st.add_vertex(q0_top)
        st.add_vertex(q0_top)
        st.add_vertex(q1_bottom)
        st.add_vertex(q1_top)
        # Inner face (facing inward): p0_bottom -> p0_top -> p1_bottom and p0_top -> p1_top -> p1_bottom
        st.add_vertex(p0_bottom)
        st.add_vertex(p0_top)
        st.add_vertex(p1_bottom)
        st.add_vertex(p0_top)
        st.add_vertex(p1_top)
        st.add_vertex(p1_bottom)
    return st.commit()

func _create_device_mesh(device: Dictionary) -> void:
    # Very simple: colored small box; ignores which wall it is on for now,
    # but uses dist_left_cm as X and dist_floor_cm as Y.
    var width_cm: float = device.get("width_cm", 8.0)
    var height_cm: float = device.get("height_cm", 8.0)
    var dist_floor_cm: float = device.get("dist_floor_cm", 100.0)
    var dist_left_cm: float = device.get("dist_left_cm", 50.0)

    var mesh := BoxMesh.new()
    mesh.size = Vector3(width_cm, height_cm, 4.0)

    var inst := MeshInstance3D.new()
    inst.mesh = mesh
    var mat := StandardMaterial3D.new()
    var t := str(device.get("type", "SOCKET"))
    match t:
        "SOCKET":
            mat.albedo_color = Color(0.9, 0.9, 0.2)
        "SWITCH":
            mat.albedo_color = Color(0.2, 0.9, 0.9)
        _:
            mat.albedo_color = Color(0.9, 0.5, 0.2)
    inst.material_override = mat

    # For the prototype, just place on one wall: world X = dist_left_cm, Z = 0
    inst.transform.origin = Vector3(dist_left_cm, dist_floor_cm, 0.0)

    devices_root.add_child(inst)

# --- Camera orbit controls ---

func _unhandled_input(event: InputEvent) -> void:
    # Orbit/camera controls.  When inside_view is true, the camera position
    # remains at the room centre and only the orientation (yaw/pitch) can
    # change.  When inside_view is false, the camera orbits around the
    # origin and zooms in/out.  In both cases right mouse drag rotates
    # the view; scroll wheel zoom only applies outside.
    if event is InputEventMouseButton:
        var mb: InputEventMouseButton = event as InputEventMouseButton
        # Start/stop dragging on right mouse button
        if mb.button_index == MOUSE_BUTTON_RIGHT:
            if mb.pressed:
                dragging = true
                last_drag_pos = mb.position
            else:
                dragging = false
            return
        # Handle zoom only when not inside the room
        if not inside_view:
            if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
                orbit_distance *= 0.9
                _update_camera()
                return
            elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
                orbit_distance *= 1.1
                _update_camera()
                return

    elif event is InputEventMouseMotion and dragging:
        var mm: InputEventMouseMotion = event as InputEventMouseMotion
        var delta: Vector2 = mm.position - last_drag_pos
        last_drag_pos = mm.position
        # Update yaw/pitch based on drag delta
        orbit_yaw -= delta.x * 0.01
        # Allow full vertical look when inside the room, clamping pitch symmetrically.
        if inside_view:
            orbit_pitch = clamp(orbit_pitch - delta.y * 0.01, deg_to_rad(-80), deg_to_rad(80))
        else:
            # Outside the room we restrict pitch so the camera remains above the ground.
            orbit_pitch = clamp(orbit_pitch - delta.y * 0.01, deg_to_rad(-80), deg_to_rad(-5))
        _update_camera()
        return

func _update_camera() -> void:
    # When inside_view is enabled, position the camera at the room centre and
    # orient it using the orbit angles.  Otherwise use the default orbit
    # behaviour outside the room.
    if inside_view:
        # Set the camera position to the computed room centre
        camera.transform.origin = room_center
        # Orient the camera based on current pitch/yaw angles.  Positive yaw
        # rotates right around Y and positive pitch rotates up around X.
        camera.rotation = Vector3(orbit_pitch, orbit_yaw, 0.0)
        return

    var target := Vector3.ZERO
    var x := orbit_distance * sin(orbit_yaw) * cos(orbit_pitch)
    var y := orbit_distance * sin(orbit_pitch)
    var z := orbit_distance * cos(orbit_yaw) * cos(orbit_pitch)
    camera.transform.origin = target + Vector3(x, y, z)
    camera.look_at(target, Vector3.UP)
