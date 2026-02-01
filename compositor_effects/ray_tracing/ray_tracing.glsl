#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant) uniform push_constants {
	vec2 raster_size;
	vec2 reserved;
	vec4 viewport_top_left;
	vec4 delta_x;
	vec4 delta_y;
	vec4 camera;
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
const int BOUNCES = 4;

// https://jcgt.org/published/0009/03/02/
uint pcg(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float randFloat(inout uint state) {
	return pcg(state) / 4294967295.0;
}

float randFloatRange(inout uint state, float minimum, float maximum) {
	return randFloat(state) * (maximum - minimum) + minimum;
}

vec3 randVec3Range(inout uint state, float minimum, float maximum) {
	return vec3(
		randFloatRange(state, minimum, maximum),
		randFloatRange(state, minimum, maximum),
		randFloatRange(state, minimum, maximum)
	);
}

vec3 randUnitVector(inout uint state) {
	float lengthSquared = 2.0;
	vec3 vector = vec3(0.0);
	while (lengthSquared > 1.0) {
        vector = randVec3Range(state, -1.0, 1.0);
        lengthSquared = dot(vector, vector);
    }
	return vector / sqrt(lengthSquared);
}

vec2 randUnitSquare(inout uint state) {
	return vec2(randFloatRange(state, -0.5, 0.5), randFloatRange(state, -0.5, 0.5));
}

vec3 pointAlongRay(Ray ray, float t, float offset) {
	return (ray.origin + ray.dir * offset) + ray.dir * t;
}

Hit rayIntersectSphere(inout uint state, Ray ray, Sphere sphere) {
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
	hit.normal = normalize(pointAlongRay(ray, hit.dist, 0.0) - sphere.origin);
	hit.color = sphere.color;
	hit.roughness = sphere.roughness;
    return hit;
}

Hit findClosestHit(inout uint state, Ray ray) {
	Sphere spheres[4] = Sphere[](
		Sphere(vec3(-4.0,    0.0, 0.0),   1.2, vec3(0.95, 0.3, 0.4), 0.0),
		Sphere(vec3( 0.0,    0.0, 0.0),   1.2, vec3(0.4, 0.95, 0.3), 0.2),
		Sphere(vec3( 4.0,    0.0, 0.0),   1.2, vec3(0.3, 0.4, 0.95), 0.6),
		Sphere(vec3( 0.0, -101.0, 0.0), 100.0, vec3(0.95), 0.5)
	);
	Hit closestHit;
	closestHit.hit = false;
	for (int i = 0; i < 4; i++) {
		Hit hit = rayIntersectSphere(state, ray, spheres[i]);
		if (hit.hit && hit.dist > 0.0 && (!closestHit.hit || hit.dist < closestHit.dist))
			closestHit = hit;
	}
	return closestHit;
}

vec3 getEnvironment(Ray ray) {
	float x_coord = atan(ray.dir.x, ray.dir.z) / (2.0 * 3.141592) + 0.5;
	float y_coord = -asin(ray.dir.y) / 3.141592 + 0.5;
	return texture(sky_sampler, vec2(x_coord, y_coord)).rgb;
}

vec4 bounceRay(inout uint state, Ray ray) {
	int steps = BOUNCES;
	vec4 color = vec4(vec3(1.0), 0.0);
	while (steps > 0) {
		Hit hit = findClosestHit(state, ray);
		if (!hit.hit)
			break;
		color.a = 1.0;
		ray.origin = pointAlongRay(ray, hit.dist, 0.00001);
		vec3 perfectReflection = reflect(ray.dir, hit.normal);
		vec3 scatteredReflection = normalize(hit.normal + randUnitVector(state));
		ray.dir = normalize(mix(perfectReflection, scatteredReflection, hit.roughness));
		
		color.rgb *= hit.color;
		
		steps--;
	}
	color.rgb *= step(0, steps + 1) * getEnvironment(ray);
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
		vec2 randOffset = randUnitSquare(state);
		vec3 point = origin + randOffset.x * parameters.delta_x.xyz + randOffset.y * parameters.delta_y.xyz;
		Ray ray = Ray(point, normalize(point - parameters.camera.xyz));
		color += bounceRay(state, ray) / SAMPLES;
	}
	
	if (color.a > 0.0)
		imageStore(color_image, ivec2(uv), color);
}