extends Node3D

## Simple 3D room visualizer.
## Builds wall meshes and a floor from a 2D polygon (cm units).

@onready var camera: Camera3D = $Camera3D
@onready var walls_root: Node3D = $Walls
@onready var floor_mesh: MeshInstance3D = $Floor
@onready var devices_root: Node3D = $Devices

var wall_height_cm: float = 270.0
var wall_thickness_cm: float = 10.0

# Camera orbit state
var orbit_distance: float = 400.0  # cm
var orbit_yaw: float = deg_to_rad(45.0)
var orbit_pitch: float = deg_to_rad(-20.0)
var last_drag_pos: Vector2
var dragging: bool = false

func _ready() -> void:
	set_process_unhandled_input(true)
	_update_camera()

func build_room(polygon: PackedVector2Array, walls: Array, doors: Array, windows: Array, devices: Array) -> void:
	# Clear old meshes
	for c in walls_root.get_children():
		c.queue_free()
	for c in devices_root.get_children():
		c.queue_free()

	if polygon.size() < 3:
		return

	# Floor: simple polygon extruded very slightly or flat mesh.
	var floor := _create_floor_mesh(polygon)
	floor_mesh.mesh = floor

	# Build wall segments along polygon edges
	for i in range(polygon.size()):
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % polygon.size()]
		_create_wall_segment(a, b)

	# Simple device visualisation: colored boxes on walls (ignoring exact relation to walls for now)
	for d in devices:
		_create_device_mesh(d)

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

func _create_wall_segment(a2d: Vector2, b2d: Vector2) -> void:
	var length_cm := a2d.distance_to(b2d)
	if length_cm < 1.0:
		return

	var mesh := BoxMesh.new()
	mesh.size = Vector3(length_cm, wall_height_cm, wall_thickness_cm)

	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = StandardMaterial3D.new()
	inst.material_override.albedo_color = Color(0.9, 0.9, 0.95)

	# Position: center between a and b, at half height.
	var mid2d := (a2d + b2d) * 0.5
	var pos := Vector3(mid2d.x, wall_height_cm * 0.5, mid2d.y)
	inst.transform.origin = pos

	# Orientation: align with segment direction
	var dir2d := (b2d - a2d).normalized()
	var angle_y := atan2(dir2d.x, dir2d.y)  # Godot Z forward, X right
	inst.rotation = Vector3(0.0, angle_y, 0.0)

	walls_root.add_child(inst)

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
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			orbit_distance *= 1.1
			_update_camera()

	elif event is InputEventMouseMotion and dragging:
		var mm := event as InputEventMouseMotion
		var delta := mm.position - last_drag_pos
		last_drag_pos = mm.position
		orbit_yaw -= delta.x * 0.01
		orbit_pitch = clamp(orbit_pitch - delta.y * 0.01, deg_to_rad(-80), deg_to_rad(-5))
		_update_camera()

func _update_camera() -> void:
	var target := Vector3.ZERO
	var x := orbit_distance * sin(orbit_yaw) * cos(orbit_pitch)
	var y := orbit_distance * sin(orbit_pitch)
	var z := orbit_distance * cos(orbit_yaw) * cos(orbit_pitch)
	camera.transform.origin = target + Vector3(x, y, z)
	camera.look_at(target, Vector3.UP)
