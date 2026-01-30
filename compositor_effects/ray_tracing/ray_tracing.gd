@tool
extends CompositorEffect
class_name RayTracing

@export_tool_button("Reload Shader", "Reload") var reload_button := reload_shader

const SHADER_PATH := "res://compositor_effects/ray_tracing/ray_tracing.glsl"

var shader: ComputeHelper
var color_image_uniform: ImageUniform
var depth_sampler_uniform: SamplerUniform
var normal_roughness_sampler_uniform: SamplerUniform
var sky_sampler_uniform: SamplerUniform

var camera: Camera3D
var frame: int = 0
var sky_is_valid := false

func _init() -> void:
	needs_normal_roughness = true
	color_image_uniform = ImageUniform.new()
	depth_sampler_uniform = SamplerUniform.new()
	depth_sampler_uniform.sampler = ComputeHelper.rd.sampler_create(RDSamplerState.new())
	normal_roughness_sampler_uniform = SamplerUniform.new()
	normal_roughness_sampler_uniform.sampler = ComputeHelper.rd.sampler_create(RDSamplerState.new())
	reload_shader()

func reload_shader() -> void:
	shader = ComputeHelper.create(SHADER_PATH)
	shader.add_uniform_array([
		color_image_uniform,
		depth_sampler_uniform,
		normal_roughness_sampler_uniform
	])
	sky_is_valid = false

func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	frame += 1
	if frame > 65536:
		frame = 0
	
	var render_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	if !render_buffers:
		return
	
	if !sky_is_valid:
		var environment := render_data.get_environment()
		var sky_image := RenderingServer.environment_bake_panorama(environment, false, Vector2(1080.0, 540.0))
		sky_sampler_uniform = SamplerUniform.create(sky_image)
		shader.add_uniform(sky_sampler_uniform)
		sky_is_valid = true
	
	var size := render_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	
	var groups := Vector3i((size.x - 1.0) / 8.0 + 1.0, (size.y - 1.0) / 8.0 + 1.0, 1.0)
	
	var projection := render_data.get_render_scene_data().get_cam_projection()
	var near := -projection.get_z_near()
	var aspect := -projection.get_aspect()
	var viewport_width := -2.0 * near * tan(deg_to_rad(projection.get_fov()) / 2.0)
	var viewport_height := viewport_width / aspect
	
	var delta_x := Vector3(-viewport_width / size.x, 0.0, 0.0)
	var delta_y := Vector3(0.0, viewport_height / size.y, 0.0)
	var viewport_size := Vector3(-viewport_width, viewport_height, 0.0)
	var viewport_top_left := -Vector3(0.0, 0.0, near) - viewport_size / 2.0 + 0.5 * (delta_x + delta_y)
	
	var transform := render_data.get_render_scene_data().get_cam_transform()
	var translation := transform.origin
	var rotation := transform.basis.inverse()
	
	viewport_top_left *= rotation
	viewport_top_left += translation
	
	delta_x *= rotation
	delta_y *= rotation
	
	var parameters := PackedFloat32Array([
		size.x, size.y, 0.0, 0.0,
		viewport_top_left.x, viewport_top_left.y, viewport_top_left.z, 0.0,
		delta_x.x, delta_x.y, delta_x.z, 0.0,
		delta_y.x, delta_y.y, delta_y.z, 0.0,
		translation.x, translation.y, translation.z, 0.0,
	])
	var push_constant := parameters.to_byte_array()
	push_constant.resize(push_constant.size() + 4)
	push_constant.encode_u32(push_constant.size() - 4, frame)
	
	color_image_uniform.texture = render_buffers.get_color_layer(0)
	depth_sampler_uniform.texture = render_buffers.get_depth_layer(0)
	normal_roughness_sampler_uniform.texture = render_buffers.get_texture("forward_clustered", "normal_roughness")
	
	shader.run(groups, push_constant)
	shader.uniform_set_dirty = true
