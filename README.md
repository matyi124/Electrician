# FloorPlanElectrician – egyszerű villamos alaprajz tervező (Godot 4)

Ez a projekt egy **asztali (PC-s) prototípus** Godot 4-ben, amelyen:

- 2D-ben lehet **falakat rajzolni** centiméter alapú rácson
- falakra **ajtókat** és **ablakokat** lehet tenni, majd a méreteiket szerkeszteni
- a bezárt alaprajzból egy egyszerű **3D-s helyiség** építhető
- a projekt adatai **JSON fájlba menthetők / onnan betölthetők**

A hangsúly a **villamos tervezés előkészítésén** van: a jövőben ide kerülhetnek a konnektorok, kapcsolók, lámpák stb.

---

## 1. Követelmények és futtatás

- Godot Engine **4.5.x** (a projekt jelenleg 4.5.1-gyel készült)
- A projekt gyökérben található `project.godot` fájlt kell megnyitni.
- Fő jelenet:  
  - `main2.tscn` (Godot-ban: *Projekt → Beállítások → Általános → Application / Run / Main Scene*)

Indítás:

1. Nyisd meg a projektet Godot-ban.
2. Állítsd be a `main2.tscn`-t fő jelenetnek (ha még nem az).
3. Nyomd meg a **Play** gombot.

---

## 2. Felhasználói felület – gombok és alap működés

A fő jelenet (`main2.tscn`) felépítése:

- `Main` (Node)
  - `Editor2D` (Node2D) – 2D alaprajz szerkesztő
  - `Room3D` (Node3D) – 3D nézet
  - `CanvasLayer`
    - `HBoxContainer`
      - `ButtonWall` – **Fal rajzolása**
      - `ButtonDoor` – **Ajtó**
      - `ButtonWindow` – **Ablak**
      - `Button3D` – **3D nézet**
      - `ButtonSave` – **Mentés**
      - `ButtonLoad` – **Betöltés**
    - `DoorWindowPanel` (Window) – felugró panel az ajtó/ablak méretekhez

### 2.1 Gombok viselkedése (Main.gd)

A `Main.gd` script kezeli a gombokat:

- A gombok **toggle módba** vannak állítva:
  - egyszeri kattintás → *bekapcsol* az adott mód  
  - második kattintás → *kikapcsol*, vissza “semleges” módba

Gombok hatása:

- **Fal rajzolása**
  - Bekapcsolva: bal egérgombbal falat rajzolsz.
  - Kikapcsolva: falrajzolás letiltva, bal egérgomb + középső egérgomb **mozgatja** a nézetet.
- **Ajtó**
  - Bekapcsolva: bal gombbal falra kattintva ajtót helyez el.
  - Ugyanarra a pontra nem tesz második ajtót.
  - Ajtó lerakása után felugrik a méretszerkesztő panel.
- **Ablak**
  - Ugyanaz, mint az ajtó, csak ablak paraméterekkel.
- **3D nézet**
  - Első kattintás: ha van zárt szoba, átvált 3D nézetre és felépíti a 3D szobát.
  - Második kattintás: visszavált 2D nézetre.
- **Mentés**
  - Elmenti a projektet `user://projektek/alap.json` fájlba.
- **Betöltés**
  - Beolvassa ugyanebből a fájlból a falakat/ajtókat/ablakokat.

---

## 3. 2D editor – Editor2d.gd

### 3.1 Adatmodell

A `Editor2d.gd` a következő, nagyon egyszerű adatszerkezetet használja:

```gdscript
var walls:    Array[Dictionary] = []  # { id, p1:Vector2, p2:Vector2, thickness, height }
var doors:    Array[Dictionary] = []  # { id, wall_id, offset_cm, width_cm, height_cm, sill_cm }
var windows:  Array[Dictionary] = []  # ugyanaz, mint doors
var devices:  Array[Dictionary] = []  # { id, wall_id, type, width_cm, height_cm, dist_floor_cm, dist_left_cm }
```

**Mértékegység:** minden **cm-ben** van tárolva.

- `p1`, `p2`: fal két végpontja (világkoordináta, centiméter)
- `offset_cm`: az ajtó/ablak bal széle a fal `p1` pontjától mérve, cm
- `width_cm`, `height_cm`: nyílás szélesség/magasság cm-ben
- `sill_cm`: ablak parapet magasság (padlótól)

### 3.2 Szerkesztő módok

```gdscript
enum ToolMode { NONE, WALL, DOOR, WINDOW }
var mode: int = ToolMode.NONE   # induláskor csak mozgatás
```

**NONE**

- Nincs aktív eszköz.
- Bal egérgomb és középső egérgomb is **panning-et** csinál (nézet mozgatása).

**WALL**

- Bal gomb lenyomás → fal kezdőpont rácshoz “snapelve”
- Bal gomb felengedés → végpont rácshoz snapelve → fal mentése
- Ha az új fal pontosan ugyanaz, mint egy már létező (ugyanaz a két végpont), akkor **nem** menti (duplikáció védelem).

**DOOR / WINDOW**

- Bal gomb → megkeresi a legközelebbi falat (`_find_nearest_wall`).
- A kattintás pontját a falra vetíti, majd **rácsra snapeli** → ez lesz a nyílás helye.
- Ugyanarra a falra és pontosan ugyanarra az offsetre nem enged második ajtót/ablakot.
- Lerakás után jelez:
  - `project_changed` signal
  - `opening_placed(is_door)` signal → ezt a `Main.gd` figyeli és felnyitja a méretszerkesztő ablakot.

### 3.3 Koordináta rendszer és rács

- `pixels_per_cm = 2.0`  
  → 1 cm = 2 pixelt jelent a képernyőn (zoom előtt).
- `view_offset` + `zoom` határozza meg, hogyan kerülnek a világkoordináták a képernyőre.

Segédfüggvények:

- `world_to_screen(p: Vector2) -> Vector2`
- `screen_to_world(p: Vector2) -> Vector2`
- `snap_world_to_grid(p: Vector2) -> Vector2` – `grid_step_cm` alapján rácsra kerekít.

### 3.4 Input kezelés

`_unhandled_input(event)`:

- Görgő: zoom in/out.
- Középső gomb (vagy bal gomb, ha `mode == NONE`): panning.
- Bal gomb:
  - `pressed` → `_on_left_pressed`
  - `released` → `_on_left_released`

### 3.5 Rajzolás (_draw)

A `Node2D._draw()` metódusban történik:

1. **Rács** (`_draw_grid`)
2. **Falak** fekete vonallal (`_draw_walls`)
   - fölöttük szövegben a hosszuk: „160.0 cm”
3. **Ajtók** kékkel, **ablakok** zölddel (`_draw_openings`)
4. **Éppen rajzolt fal preview** pirosas vonallal (`_draw_current_wall_preview`)
5. **Szoba kitöltése** halvány sárgával (`_draw_room_outline`)

---

## 4. Szoba detektálás és 3D-re küldés

### 4.1 Szoba poligon (Editor2d.gd)

A szobát nagyon egyszerűen kezeljük:

```gdscript
func _compute_room_polygon() -> PackedVector2Array:
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
        if not (k2 in adjacency[k1]):
            adjacency[k1].append(k2)
        if not (k1 in adjacency[k2]):
            adjacency[k2].append(k1)
        adjacency[k1].append(k2)
        adjacency[k2].append(k1)

    if adjacency.size() < 3:
        return PackedVector2Array()

    # Zárt szoba: minden csúcs foka legyen 2
    for key in adjacency.keys():
        var degree: int = (adjacency[key] as Array).size()
        if degree != 2:
            return PackedVector2Array()

    # Járjuk végig a ciklust, hogy sorrendezett poligont kapjunk
    var start_key: String = adjacency.keys()[0]
    var prev_key: String = ""
    var current_key: String = start_key
    var polygon := PackedVector2Array()

    for i in range(adjacency.size() + 2):
        polygon.append(point_lookup[current_key])
        var neighbors: Array = adjacency[current_key]
        var next_key: String = ""
        for n in neighbors:
            if String(n) != prev_key:
                next_key = String(n)
                break

        if next_key == "":
            return PackedVector2Array()

        if next_key == start_key:
            if polygon.size() >= 3:
                return polygon
            return PackedVector2Array()

        prev_key = current_key
        current_key = next_key

    return PackedVector2Array()
```

`get_room_polygon()` annyit tesz, hogy meghívja a fenti számítást és visszaadja az eredményt.

Tehát:

- A falak végpontjait **összepárosítjuk**, 5 cm-es toleranciával egyesítjük a közeli pontokat.
- Ha valamelyik sarok csak majdnem ér össze, a program megpróbálja automatikusan összekapcsolni, hogy a hurok bezáródjon.
- Csak akkor ad vissza poligont, ha minden csúcspont foka 2, és a bejárás az összes sarokig eljut.
- Bonyolultabb, elágazó alaprajzokra jelenleg még nem alkalmas, de a körbezárt helyiség most már megbízhatóbban felismerhető a nagyobb tolerancia, az automatikus sarokzárás és a stabil bejárási irány miatt.

### 4.2 3D gomb (Main.gd)

`_on_3d_view_pressed()`:

1. Ha már 3D-ben vagyunk → visszavált 2D-be (`_show_2d()`).
2. Ha 2D-ben vagyunk:
   - elkéri az Editor2D-től a szobapolygont: `editor2d.get_room_polygon()`
   - ha üres → **warning**: „Nincs zárt szoba…”
   - ha nem üres:
     - elkéri a teljes projekt adatot: `editor2d.get_project_data()`
     - meghívja `Room3D.build_room(...)`
     - majd átvált 3D nézetre (`_show_3d()`)

---

## 5. 3D nézet – Room3D.gd

A `Room3D` egy nagyon egyszerű vizualizáló:

- `Walls` (Node3D) – ide kerülnek a falak
- `Floor` (MeshInstance3D) – itt van a padló mesh
- `Devices` (Node3D) – ide kerülhetnek a villamos berendezések dobozkái
- `Camera3D` – körbe forgatható kamera

### 5.1 Szoba felépítése

`build_room(polygon, walls, doors, windows, devices)`:

1. Törli az előző fal- és device mesh-eket.
2. A `polygon` alapján **padló mesh** készül:
   - `Geometry2D.triangulate_polygon(polygon)` – háromszögekre bontás
   - mindegyik háromszögből `SurfaceTool`-lal vertexek
3. Minden poligon élre létrejön egy 3D fal:
   - BoxMesh, `length_cm x wall_height_cm x wall_thickness_cm`
   - pozíció: két pont közepe, fél magasságban
   - elforgatás: a 2D irány alapján az Y tengely körül
4. A `devices` tömbből egyszerű kis dobozok készülnek (egyelőre csak demonstráció).

### 5.2 Kamera mozgatása

- **Jobb egérgomb drag** → kamera körbeforgatása a szoba körül
- **Egérgörgő**:
  - felfelé: közelebb zoom
  - lefelé: távolabb zoom

Az `_update_camera()` kiszámolja a kamera pozíciót gömbi koordinátákból:

```gdscript
var x := orbit_distance * sin(orbit_yaw) * cos(orbit_pitch)
var y := orbit_distance * sin(orbit_pitch)
var z := orbit_distance * cos(orbit_yaw) * cos(orbit_pitch)
camera.transform.origin = Vector3(x, y, z)
camera.look_at(Vector3.ZERO, Vector3.UP)
```

---

## 6. Ajtó/ablak méretszerkesztő – door_window_panel.gd

A `DoorWindowPanel` egy `Window` típusú felugró ablak:

- `WidthEdit` – szélesség (cm)
- `HeightEdit` – magasság (cm)
- `SillEdit` – parapet (cm)
- `Button` – „OK” gomb

### 6.1 Nyitás

A `Main.gd` figyeli az `opening_placed(is_door)` signalt:

```gdscript
func _on_opening_placed(is_door: bool) -> void:
    door_window_panel.call("open_for_last_opening", is_door)
```

`open_for_last_opening`:

1. Elmenti, hogy ajtó vagy ablak.
2. Ha az input mezők üresek, kitölti alapértékekkel:
   - ajtó: 90 / 210 / 0
   - ablak: 120 / 120 / 90
3. Fókusz a szélesség mezőre.
4. `popup_centered()` – ablak középre nyitása.

### 6.2 Mentés és bezárás

- `OK` gomb vagy Enter bármelyik mezőben:
  - `_apply_and_close()`:
    - kiolvassa a három értéket float-ként,
    - `editor2d.update_last_opening(is_door, width, height, sill)`
    - `values_applied` signalt is kiadja (ha később még használni akarjuk),
    - végül `hide()` – bezárja az ablakot.

- Az X gomb a `close_requested` jelzésen keresztül csak `hide()`-ot hív, **nem** módosít semmit az adatokon.

---

## 7. Mentés / betöltés

### 7.1 JSON struktúra

A `Editor2d.gd.get_project_data()` adja vissza:

```jsonc
{
  "walls":   [ { ... }, ... ],
  "doors":   [ { ... }, ... ],
  "windows": [ { ... }, ... ],
  "devices": [ { ... }, ... ]
}
```

### 7.2 Mentés

`save_project()`:

- JSON-re alakítja a fenti adatot (`JSON.stringify`).
- Létrehozza a `user://projektek` könyvtárat, ha még nem létezik.
- `user://projektek/alap.json` fájlba írja.

### 7.3 Betöltés

`load_project()`:

- Ha a fájl nem létezik → warning: „Nincs mentett projekt.”
- Ha létezik:
  - beolvassa a JSON-t,
  - a `walls`, `doors`, `windows`, `devices` mezőket tömbökként visszaírja a szerkesztőbe,
  - `queue_redraw()` – újrarajzolás,
  - `project_changed` signal.

---

## 8. Jelenlegi korlátok, ötletek továbbfejlesztésre

**Korlátok:**

- Csak **egy egyszerű, konvex szoba** kezelhető értelmesen (a convex hull miatt).
- Falakat, ajtókat, ablakokat **utólag mozgatni/törölni** egyelőre nem lehet – csak újrarajzolással.
- A 3D nézetben az ajtók/ablakok még **nincsenek kivágva** a falból, csak a falak látszanak.
- `devices` még csak demonstráció, nincs rá külön UI.

**Lehetséges fejlesztések:**

- Több helyiség (nem konvex, több poligon) kezelése.
- Falak kijelölése, mozgatása, törlése.
- Ajtók/ablakok vizuális jelzése 3D-ben, fal kivágása.
- Villamos berendezések (konnektor/switch) felvétele 2D-ben és megjelenítése 3D-ben.
- Több projekt, fájlválasztó a `user://projektek` mappából.

---

## Verziótörténet

- v0.1.0 – Zárt szoba felismerésének javítása (nagyobb tolerancia, automatikus sarokzárás), README bővítése.
- v0.2.0 – Többszobás detektálás stabilizálása, külső kontúr kiszűrése, kiválasztott szobák frissítése betöltéskor.
- v0.3.0 – Egyszerű zárt falhurkok megbízható felismerése és a 3D falak tájolási hibájának javítása.
- v0.4.0 – Sarokponthoz igazított gráfépítés a különálló falak automatikus összekapcsolásához.
