#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant) uniform push_constants {
	mat4 inv_proj_mat;
	vec2 raster_size;
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
	return vec4(normalize(normal_roughness.xyz * 2.0 - 1.0), roughness);
}

const vec2 TARGET_RESOLUTION = vec2(320.0, 180.0);

const float DITHER_AMOUNT = 0.2;
const float NUM_COLORS = 16.0;
const float INV_NUM_COLORS_SQUARED = 1.0 / (NUM_COLORS * NUM_COLORS);
const mat4 BAYER_MATRIX = mat4(
	vec4(0.0, 8.0, 2.0, 10.0), vec4(12.0, 4.0, 14.0, 6.0), vec4(3.0, 11.0, 1.0, 9.0), vec4(15.0, 7.0, 13.0, 5.0)
);

void main() {
	vec2 size = parameters.raster_size;
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	vec2 uv_normalized = uv / size;
	
	if (uv.x >= size.x || uv.y >= size.y)
		return;
	
	vec2 rounded_uv = floor(uv / size * TARGET_RESOLUTION) / TARGET_RESOLUTION;
	vec4 screen_color = imageLoad(color_image, ivec2(floor(rounded_uv * size)));
	
	ivec2 map_coord = ivec2(mod(rounded_uv * TARGET_RESOLUTION, 4.0));
	float dither = BAYER_MATRIX[map_coord.x][map_coord.y] * INV_NUM_COLORS_SQUARED - 0.5;
	vec4 dithered_color = screen_color + dither * DITHER_AMOUNT;
	vec4 quantized_color = vec4((floor(screen_color * (NUM_COLORS - 1.0) + 0.5) / (NUM_COLORS - 1.0)).rgb, 1.0);
	
	vec2 uv_samples[3] = {
		rounded_uv,
		rounded_uv + vec2(1.0, 0.0) / TARGET_RESOLUTION,
		rounded_uv + vec2(0.0, 1.0) / TARGET_RESOLUTION
	};
	
	float dc = get_linear_depth(uv_samples[0]);
	float d0 = get_linear_depth(uv_samples[1]);
	float d1 = get_linear_depth(uv_samples[2]);
	
	vec3 nc = get_normal_roughness(uv_samples[0]).xyz;
	vec3 n0 = get_normal_roughness(uv_samples[1]).xyz;
	vec3 n1 = get_normal_roughness(uv_samples[2]).xyz;
	
	float normal_difference = distance(nc, n0) * step(nc.x, n0.x) + distance(nc, n1) * step(n1.y, nc.y);
	float normal_border = step(0.01, normal_difference);
	
	float depth_difference = abs(dc - d0) + abs(dc - d1);
	float depth_border = 1.0 - clamp(step(dc / 8.0 + 0.5, depth_difference), 0.0, 1.0);
	
	imageStore(color_image, ivec2(uv), depth_border * (1.0 + normal_border * 2.5) * quantized_color);
}