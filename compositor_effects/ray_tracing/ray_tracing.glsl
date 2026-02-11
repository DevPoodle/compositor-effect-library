#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant) uniform push_constants {
	ivec2 raster_size;
	vec3 viewport_top_left;
	vec3 delta_x;
	vec3 delta_y;
	vec3 camera;
	int frame;
} parameters;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness_texture;
layout(set = 0, binding = 3) uniform sampler2D sky_sampler;

struct Ray {
	vec3 origin;
	vec3 dir;
};

struct Sphere {
	vec3 origin;
	float radius;
	vec3 color;
	float roughness;
};

struct Hit {
	bool hit;
	float dist;
	vec3 normal;
	vec3 color;
	float roughness;
};

const int SAMPLES = 128;
const int BOUNCES = 5;

// https://jcgt.org/published/0009/03/02/
uint pcg(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float rand_float(inout uint state) {
	return pcg(state) / 4294967295.0;
}

float rand_float_range(inout uint state, float minimum, float maximum) {
	return rand_float(state) * (maximum - minimum) + minimum;
}

vec3 rand_vec3_range(inout uint state, float minimum, float maximum) {
	return vec3(
		rand_float_range(state, minimum, maximum),
		rand_float_range(state, minimum, maximum),
		rand_float_range(state, minimum, maximum)
	);
}

vec3 rand_unit_vector(inout uint state) {
	float length_squared = 2.0;
	vec3 vector = vec3(0.0);
	while (length_squared > 1.0) {
        vector = rand_vec3_range(state, -1.0, 1.0);
        length_squared = dot(vector, vector);
    }
	return vector / sqrt(length_squared);
}

vec2 rand_unit_square(inout uint state) {
	return vec2(rand_float_range(state, -0.5, 0.5), rand_float_range(state, -0.5, 0.5));
}

vec3 point_along_ray(Ray ray, float t, float offset) {
	return (ray.origin + ray.dir * offset) + ray.dir * t;
}

Hit ray_intersect_sphere(inout uint state, Ray ray, Sphere sphere) {
	Hit hit;
	hit.hit = false;
	
	vec3 oc = sphere.origin - ray.origin;
    float a = dot(ray.dir, ray.dir);
    float b = -2.0 * dot(ray.dir, oc);
    float c = dot(oc, oc) - sphere.radius * sphere.radius;
    float discriminant = b * b - 4.0 * a * c;
	
	if (discriminant < 0.0)
        return hit;
	hit.hit = true;
	hit.dist = -(b + sqrt(discriminant)) / (2.0 * a);
	hit.normal = normalize(point_along_ray(ray, hit.dist, 0.0) - sphere.origin);
	hit.color = sphere.color;
	hit.roughness = sphere.roughness;
    return hit;
}

Hit find_closest_hit(inout uint state, Ray ray) {
	Sphere spheres[4] = Sphere[](
		Sphere(vec3(-4.0,    0.0, 0.0),   1.2, vec3(0.95, 0.3, 0.4), 0.0),
		Sphere(vec3( 0.0,    0.0, 0.0),   1.2, vec3(0.4, 0.95, 0.3), 0.2),
		Sphere(vec3( 4.0,    0.0, 0.0),   1.2, vec3(0.3, 0.4, 0.95), 0.6),
		Sphere(vec3( 0.0, -101.0, 0.0), 100.0, vec3(0.95), 0.5)
	);
	Hit closest_hit;
	closest_hit.hit = false;
	for (int i = 0; i < 4; i++) {
		Hit hit = ray_intersect_sphere(state, ray, spheres[i]);
		if (hit.hit && hit.dist > 0.0 && (!closest_hit.hit || hit.dist < closest_hit.dist))
			closest_hit = hit;
	}
	return closest_hit;
}

vec3 get_environment(Ray ray) {
	float x_coord = atan(ray.dir.x, ray.dir.z) / (2.0 * 3.141592) + 0.5;
	float y_coord = -asin(ray.dir.y) / 3.141592 + 0.5;
	return texture(sky_sampler, vec2(x_coord, y_coord)).rgb;
}

vec4 bounce_ray(inout uint state, Ray ray) {
	int steps = BOUNCES;
	vec4 color = vec4(vec3(1.0), 0.0);
	while (steps > 0) {
		Hit hit = find_closest_hit(state, ray);
		if (!hit.hit)
			break;
		color.a = 1.0;
		ray.origin = point_along_ray(ray, hit.dist, 0.00001);
		vec3 perfect_reflection = reflect(ray.dir, hit.normal);
		vec3 scattered_reflection = normalize(hit.normal + rand_unit_vector(state));
		ray.dir = normalize(mix(perfect_reflection, scattered_reflection, hit.roughness));
		
		color.rgb *= hit.color;
		
		steps--;
	}
	color.rgb *= step(0, steps + 1) * get_environment(ray);
	if (steps == 0)
		color.rgb = vec3(0.0);
	
	return color;
}

void main() {
	vec2 size = parameters.raster_size;
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	
	if (uv.x >= size.x || uv.y >= size.y)
		return;
	
	uint state = uint(uv.x) + uint(uv.y) * uint(size.x) + parameters.frame * 747796405u;
	vec3 origin = parameters.viewport_top_left.xyz + uv.x * parameters.delta_x.xyz + uv.y * parameters.delta_y.xyz;
	
	vec4 color = vec4(0.0);
	for (int i = 0; i < SAMPLES; i++) {
		vec2 rand_offset = rand_unit_square(state);
		vec3 point = origin + rand_offset.x * parameters.delta_x.xyz + rand_offset.y * parameters.delta_y.xyz;
		Ray ray = Ray(point, normalize(point - parameters.camera.xyz));
		color += bounce_ray(state, ray) / SAMPLES;
	}
	
	if (color.a > 0.0)
		imageStore(color_image, ivec2(uv), color);
}