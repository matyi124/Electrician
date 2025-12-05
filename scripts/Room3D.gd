extends Node3D

## Egyszerű 3D szoba-vizualizáló.
## A 2D alaprajz pontjait cm-ben kapja, ezt rakjuk a 3D világba.

@onready var camera: Camera3D = $Camera3D
@onready var walls_root: Node3D = $Walls
@onready var floor_mesh: MeshInstance3D = $Floor
@onready var devices_root: Node3D = $Devices

var wall_height_cm: float = 270.0
var wall_thickness_cm: float = 10.0

var has_room: bool = false
var room_half_extent: float = 200.0    # kb. „rádiusz” cm-ben

# Kamera orbit állapot
var orbit_distance: float = 400.0
var orbit_yaw: float = deg_to_rad(0.0)      # jobbra-balra forgás
var orbit_pitch: float = deg_to_rad(0.0)    # fel-le forgás (0 = vízszintes)
var last_drag_pos: Vector2
var dragging: bool = false

# A kamera által nézett pont (szoba közepe, kb. szemmagasságban)
var _target: Vector3 = Vector3.ZERO


func _ready() -> void:
    set_process_unhandled_input(true)
    _update_camera()


func build_room(
        polygon: PackedVector2Array,
        walls: Array,
        doors: Array,
        windows: Array,
        devices: Array
    ) -> void:

    # Régi mesh-ek törlése
    for c in walls_root.get_children():
        c.queue_free()
    for c in devices_root.get_children():
        c.queue_free()
    floor_mesh.mesh = null
    has_room = false

    if polygon.size() < 3:
        return

    # ---------- 1) Szoba középre igazítása ----------
    # Határoló téglalap 2D-ben
    var min_x := INF
    var min_y := INF
    var max_x := -INF
    var max_y := -INF
    for p in polygon:
        if p.x < min_x: min_x = p.x
        if p.y < min_y: min_y = p.y
        if p.x > max_x: max_x = p.x
        if p.y > max_y: max_y = p.y

    var center2d := Vector2(
        (min_x + max_x) * 0.5,
        (min_y + max_y) * 0.5
    )

    # A polygont átrakjuk úgy, hogy a közepe (0,0) legyen
    var local_poly := PackedVector2Array()
    for p in polygon:
        local_poly.append(p - center2d)

    # Ebből számolunk egy kb. rádiuszt a kamerához
    var size_x := max_x - min_x
    var size_y := max_y - min_y
    room_half_extent = max(size_x, size_y) * 0.5
    room_half_extent = max(room_half_extent, 150.0)

    # ---------- 2) Padló létrehozása ----------
    var floor := _create_floor_mesh(local_poly)
    floor_mesh.mesh = floor

    # ---------- 3) Falak létrehozása a polygon élei mentén ----------
    for i in range(local_poly.size()):
        var a2d: Vector2 = local_poly[i]
        var b2d: Vector2 = local_poly[(i + 1) % local_poly.size()]
        _create_wall_segment(a2d, b2d)

    # (Később ide jöhetnek ajtók/ablakok, devices stb.)

    has_room = true

    # ---------- 4) Kamera beállítása: BENT legyen a szobában ----------
    # Célpont: szoba közepe kb. szemmagasságban (160 cm)
    _target = Vector3(0.0, 160.0, 0.0)

    # Kezdő távolság: kb. a szoba fele (hogy biztosan ne a falon kívül legyünk)
    orbit_distance = room_half_extent * 0.6
    orbit_distance = clamp(orbit_distance, 120.0, room_half_extent * 1.2)

    # Kezdő irány: egy kicsit „hátrább” nézzünk lefele
    orbit_yaw = deg_to_rad(45.0)
    orbit_pitch = deg_to_rad(-10.0)

    _update_camera()


func _create_floor_mesh(polygon: PackedVector2Array) -> Mesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.85, 0.85, 0.88)
    st.set_material(mat)

    # Polygon trianguláció 2D-ben
    var tri_indices := Geometry2D.triangulate_polygon(polygon)
    for i in range(0, tri_indices.size(), 3):
        var i0 := tri_indices[i]
        var i1 := tri_indices[i + 1]
        var i2 := tri_indices[i + 2]

        var p0 := polygon[i0]
        var p1 := polygon[i1]
        var p2 := polygon[i2]

        st.add_vertex(Vector3(p0.x, 0.0, p0.y))
        st.add_vertex(Vector3(p1.x, 0.0, p1.y))
        st.add_vertex(Vector3(p2.x, 0.0, p2.y))

    return st.commit()


func _create_wall_segment(a2d: Vector2, b2d: Vector2) -> void:
    var length_cm := a2d.distance_to(b2d)
    if length_cm < 1.0:
        return

    var mesh := BoxMesh.new()
    mesh.size = Vector3(length_cm, wall_height_cm, wall_thickness_cm)

    var inst := MeshInstance3D.new()
    inst.mesh = mesh

    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.3, 0.3, 0.35)
    inst.material_override = mat

    # Középpont
    var mid2d := (a2d + b2d) * 0.5
    var pos := Vector3(mid2d.x, wall_height_cm * 0.5, mid2d.y)
    inst.transform.origin = pos

    # Irány -> Y körüli szög
    var dir2d := (b2d - a2d).normalized()
    var angle_y := atan2(dir2d.x, dir2d.y)  # Godot: Z előre, X jobbra
    inst.rotation = Vector3(0.0, angle_y, 0.0)

    walls_root.add_child(inst)


func _create_device_mesh(device: Dictionary) -> void:
    # (egyelőre nem hívjuk sehonnan, maradhat a későbbi fejlesztéshez)
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

    inst.transform.origin = Vector3(dist_left_cm, dist_floor_cm, 0.0)
    devices_root.add_child(inst)


# --- Kamera orbit vezérlés ---

func _unhandled_input(event: InputEvent) -> void:
    if not has_room:
        return

    if event is InputEventMouseButton:
        var mb := event as InputEventMouseButton
        if mb.button_index == MOUSE_BUTTON_RIGHT:
            if mb.pressed:
                dragging = true
                last_drag_pos = mb.position
            else:
                dragging = false
        elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
            orbit_distance *= 0.9
            orbit_distance = max(orbit_distance, room_half_extent * 0.3)
            _update_camera()
        elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
            orbit_distance *= 1.1
            _update_camera()

    elif event is InputEventMouseMotion and dragging:
        var mm := event as InputEventMouseMotion
        var delta := mm.position - last_drag_pos
        last_drag_pos = mm.position
        orbit_yaw -= delta.x * 0.01
        orbit_pitch = clamp(
            orbit_pitch - delta.y * 0.01,
            deg_to_rad(-80),
            deg_to_rad(10)
        )
        _update_camera()


func _update_camera() -> void:
    # Középpont: ahol „állunk”
    var center := _target

    # Az orbit_distance-ből XZ és Y komponens
    var xz_dist := orbit_distance * cos(orbit_pitch)
    var cam_y := center.y + orbit_distance * sin(orbit_pitch)
    var cam_x := center.x + xz_dist * sin(orbit_yaw)
    var cam_z := center.z + xz_dist * cos(orbit_yaw)

    camera.transform.origin = Vector3(cam_x, cam_y, cam_z)
    camera.look_at(center, Vector3.UP)
