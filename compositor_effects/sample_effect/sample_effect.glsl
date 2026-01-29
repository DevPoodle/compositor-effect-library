#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant) uniform push_constants {
	mat4 inv_proj_mat;
	vec2 raster_size;
	float mode;
} parameters;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness_texture;

float get_linear_depth(vec2 uv) {
	float raw_depth = texture(depth_texture, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
	vec4 view = parameters.inv_proj_mat * vec4(ndc, 1.0);
	view.xyz /= view.w;
	return -view.z;
}

vec4 get_normal_roughness(vec2 uv) {
	vec4 normal_roughness = texture(normal_roughness_texture, uv);
	float roughness = normal_roughness.w;
	if (roughness > 0.5)
		roughness = 1.0 - roughness;
	roughness /= (127.0 / 255.0);
	return vec4(normalize(normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

void main() {
	vec2 size = parameters.raster_size;
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	vec2 uv_normalized = uv / size;
	
	if (uv.x >= size.x || uv.y >= size.y)
		return;
	
	vec4 color = imageLoad(color_image, uv);
	float depth = texture(depth_texture, uv_normalized).r;
	vec4 normal_roughness = get_normal_roughness(uv_normalized);
	
	switch (int(parameters.mode)) {
		case 0:
			imageStore(color_image, uv, vec4(color.rgb, 1.0));
			break;
		case 1:
			imageStore(color_image, uv, vec4(vec3(12.0 * depth - 0.1), 1.0));
			break;
		case 2:
			imageStore(color_image, uv, vec4(normal_roughness.xyz, 1.0));
			break;
		case 3:
			imageStore(color_image, uv, vec4(vec3(normal_roughness.w), 1.0));
			break;
	}
}