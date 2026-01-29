#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant) uniform push_constants {
	mat4 inv_proj_mat;
	vec2 raster_size;
} parameters;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;

float get_linear_depth(vec2 uv) {
	float raw_depth = texture(depth_texture, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
	vec4 view = parameters.inv_proj_mat * vec4(ndc, 1.0);
	view.xyz /= view.w;
	return -view.z;
}

float get_cutoff(float depth) {
	return 0.5 + depth / 8.0;
}

const float RADIUS = 2.0;

void main() {
	vec2 size = parameters.raster_size;
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	vec2 uv_normalized = uv / size;
	
	if (uv.x >= size.x || uv.y >= size.y)
		return;
	
	vec4 color = imageLoad(color_image, uv);
	float depth = get_linear_depth(uv_normalized);
	float depth_border = 1.0;
	
	for (float x = -RADIUS; x <= RADIUS; x++) {
		for (float y = -RADIUS; y <= RADIUS; y++) {
			if (length(vec2(x, y)) > RADIUS)
				continue;
			float offset_depth = get_linear_depth(uv_normalized + vec2(x, y) / size);
			if (abs(depth - offset_depth) > get_cutoff(min(depth, offset_depth))) {
				float dist = abs(depth - offset_depth) - get_cutoff(min(depth, offset_depth));
				depth_border = max(0.0, 1.0 - dist * 0.5);
				break;
			}
		}
		if (depth_border == 0.0)
			break;
	}
	imageStore(color_image, uv, vec4(color.rgb * depth_border, 1.0));
}