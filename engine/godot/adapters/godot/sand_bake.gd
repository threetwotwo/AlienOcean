## Sand bake 0.1.0 (test level thread, 28 Nov 2026): bakes the lagoon sand's fixed world-xy noise fields (look/sand_bake.gdshader) into two
## half-float textures with mipmaps over a box of island xy, once at load, and hands them to ground materials (look/ground_surface.gdshader,
## WS_BAKED). Removes about 90 of the ~136 noise hashes per sand pixel; the picture stays the same (A/B in tools/sand_bake_ab.gd).
## The fields are pure functions of xy (no z, no time), so a bake is exact up to texel filtering on floors, slopes and walls alike.
class_name SandBake
extends RefCounted

const TEXEL := 0.06          # m per texel: the finest baked lattice is 0.39 m (6.5 texels)
const MAX_PX := 8192

var tex_a: ImageTexture
var tex_b: ImageTexture
var box := Vector4()         # org xy, span xy (island frame, m)
var px := Vector2()
var ms := 0.0

## island-frame xy rectangle from Godot-frame meshes: island (x, y) = Godot (x, -z)
static func island_rect(meshes: Array, margin := 2.0) -> Rect2:
	var r := Rect2(); var first := true
	for mi in meshes:
		var a: AABB = mi.global_transform * mi.get_aabb()
		var q := Rect2(Vector2(a.position.x, -a.end.z), Vector2(a.size.x, a.size.z))
		r = q if first else r.merge(q); first = false
	return r.grow(margin)

func bake(host: Node, rect: Rect2, texel := TEXEL) -> void:
	var t0 := Time.get_ticks_usec()
	var n := Vector2i(mini(MAX_PX, int(ceil(rect.size.x / texel)) + 1), mini(MAX_PX, int(ceil(rect.size.y / texel)) + 1))
	px = Vector2(n)
	box = Vector4(rect.position.x, rect.position.y, (n.x - 1) * texel, (n.y - 1) * texel)
	var imgs := []
	for which in [0, 1]:
		imgs.append(await _render(host, n, which))
	tex_a = ImageTexture.create_from_image(imgs[0]); tex_b = ImageTexture.create_from_image(imgs[1])
	ms = (Time.get_ticks_usec() - t0) / 1000.0

func _render(host: Node, n: Vector2i, which: int) -> Image:
	var vp := SubViewport.new(); vp.size = n; vp.use_hdr_2d = true; vp.transparent_bg = true; vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var cr := ColorRect.new(); cr.size = Vector2(n); cr.position = Vector2.ZERO
	var m := ShaderMaterial.new(); m.shader = load("res://look/sand_bake.gdshader")
	m.set_shader_parameter("org", Vector2(box.x, box.y)); m.set_shader_parameter("span", Vector2(box.z, box.w))
	m.set_shader_parameter("px", px); m.set_shader_parameter("which", which)
	cr.material = m; vp.add_child(cr); host.add_child(vp)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img.get_format() != Image.FORMAT_RGBAH: img.convert(Image.FORMAT_RGBAH)
	img.generate_mipmaps()
	return img

## the bake's own check image (which = 2: each texel's position along the box, 0..1)
func render_check(host: Node, n: Vector2i) -> Image:
	px = Vector2(n); box = Vector4(0, 0, 1, 1)
	return await _render(host, n, 2)

func apply(m: ShaderMaterial, on := true) -> void:
	m.set_shader_parameter("sandA", tex_a); m.set_shader_parameter("sandB", tex_b)
	m.set_shader_parameter("sand_box", box); m.set_shader_parameter("sand_px", px)
	m.set_shader_parameter("sand_on", 1.0 if on else 0.0)

func bytes() -> int:
	return int(px.x * px.y * 8 * 2 * 4 / 3)   # two RGBA half-float textures with mip chains
