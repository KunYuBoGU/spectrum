#if !defined INCLUDE_FRAGMENT_SPECULARLIGHTING
#define INCLUDE_FRAGMENT_SPECULARLIGHTING

//#define SPECULAR_EXACT_FRESNEL

vec3 CalculateSpecularHighlight(float NdotL, float NdotV, float VdotL, float VdotH, float roughness, vec3 n, vec3 k, float angularRadius) {
	float alpha2 = roughness * roughness;

	vec3 brdf = CalculateSpecularBRDFSphere(NdotL, NdotV, VdotL, VdotH, alpha2, n, k, angularRadius);

	/* NdotL modified to fade to 0 only when the light is fully occluded (rather than when light is only halfway occluded)
	float sinLightRadius = sin(angularRadius);
	return brdf * Clamp01((NdotL + sinLightRadius) / (1.0 + sinLightRadius));
	//*/ return brdf * NdotL;
}

//--//

#if defined PROGRAM_COMPOSITE1 || defined PROGRAM_WATER || defined PROGRAM_HAND_WATER
	vec3 GetFacetGGX(
		vec3 viewDirection,
		vec2 roughness, // along x and y axis of input space used for the view direction
		vec2 xy // uniform random numbers from 0 to 1 - x can be limited to < 1 to clamp tail
	) {
		// GGX VNDF sampling
		// http://www.jcgt.org/published/0007/04/01/

		// transform view direction to hemisphere (section 3.2)
		viewDirection = normalize(vec3(roughness * viewDirection.xy, viewDirection.z));

		// orthonrmal basis (section 4.1)
		float clsq = dot(viewDirection.yx, viewDirection.yx);
		vec3 T1 = vec3(clsq > 0.0 ? vec2(-viewDirection.y, viewDirection.x) * inversesqrt(clsq) : vec2(1.0, 0.0), 0.0);
		vec3 T2 = vec3(-T1.y * viewDirection.z, viewDirection.z * T1.x, viewDirection.x * T1.y - T1.x * viewDirection.y);

		// parameterization of the projected area (section 4.2)
		float r = sqrt(xy.x);
		float phi = tau * xy.y;

		float t1 = r * cos(phi);
		float tmp = clamp(1.0 - t1 * t1, 0.0, 1.0);
		float t2 = mix(sqrt(tmp), r * sin(phi), 0.5 + 0.5 * viewDirection.z);

		// reprojection onto hemisphere (section 4.3)
		vec3 normalH = t1 * T1 + t2 * T2 + sqrt(clamp(tmp - t2 * t2, 0.0, 1.0)) * viewDirection;

		// transform normal back to ellipsoid (sectrion 3.4)
		return normalize(vec3(roughness * normalH.xy, normalH.z));
	}

	vec3 GenerateSsrFacet(vec3 tangentView, vec3 normal, float roughness, float index, const float ditherSize) {
		vec2 xy = vec2(fract(index * ditherSize * phi) * (1.0 - SSR_TAIL_CLAMP), index / SSR_RAY_COUNT); // forms a lattice
		vec3 facet = GetFacetGGX(-tangentView, vec2(roughness), xy);

		vec2 axis = normalize(vec2(-normal.y, normal.x));
		vec3 p1 = normal.z * facet;
		vec3 p2 = sqrt(1.0 - normal.z * normal.z) * cross(vec3(axis, 0.0), facet);
		vec2 p3 = (1.0 - normal.z) * dot(axis.xy, facet.xy) * axis;
		return p1 + p2 + vec3(p3, 0.0);
	}

	float CalculateReflectionMip(vec3 position, vec3 hitPosition, float roughness) {
		// Simple mip level calculation for SSR.
		float positionalScale = distance(position, hitPosition) / -hitPosition.z; // ray length and perspective divide
		float projectionScale = gbufferProjection[1].y;                           // field of view
		float sampleScale     = viewResolution.y * inversesqrt(SSR_RAY_COUNT);    // resolution and sample count

		// This part should really be specific to the distribution, but just "roughness" works well enough most of the time.
		// If it's gonna be accurate it needs to be a little more complicated though.
		float roughnessScale = roughness;

		return log2(positionalScale * projectionScale * sampleScale * roughnessScale);
	}

	vec3 TraceSsrRay(sampler2D sampler, mat3 position, vec3 rayDirection, float NdotL, float roughness, float skyFade, float dither) {
		vec3 hitPosition       = position[0];
		vec3 hitPositionView   = position[1];
		vec3 hitPositionScene  = position[2];
		vec3 rayDirectionWorld = mat3(gbufferModelViewInverse) * rayDirection;
		bool intersected       = true;

		if (NdotL > 0.0) { // Raytrace if not self-intersecting
			intersected      = RaytraceIntersection(hitPosition, position[1], rayDirection, SSR_RAY_STEPS, SSR_RAY_REFINEMENTS);
			hitPositionView  = intersected ? ScreenSpaceToViewSpace(hitPosition, gbufferProjectionInverse) : rayDirection * 100.0;
			hitPositionScene = mat3(gbufferModelViewInverse) * hitPositionView + gbufferModelViewInverse[3].xyz;
		}

		vec3 result = vec3(0.0);
		if (intersected) {
			//float lod = CalculateReflectionMip(position[1], hitPositionView, roughness);
			result = DecodeRGBE8(textureLod(sampler, hitPosition.xy, 0.0));
		} else if (isEyeInWater == 0) {
			result = texture(colortex6, ProjectSky(rayDirectionWorld)).rgb * skyFade;
		}

		float VdotL = dot(rayDirectionWorld, shadowLightVector);
		if (isEyeInWater == 1) {
			result = CalculateWaterFog(result, position[2], hitPositionScene, rayDirectionWorld, VdotL, skyFade, dither, !intersected);
		} else {
			result = CalculateAirFog(result, position[2], hitPositionScene, rayDirectionWorld, VdotL, skyFade, skyFade, dither, !intersected);
		}

		return result;
	}

	vec3 CalculateSsr(sampler2D sampler, mat3 position, vec3 normal, float NdotV, float roughness, vec3 n, vec3 k, float skyFade, bool isWater, float dither, const float ditherSize) {
		float roughnessSquared = roughness * roughness;
		vec3 viewDirection = normalize(position[1]);
		normal = mat3(gbufferModelView) * normal;

		vec3 tangentView = Rotate(viewDirection, normal, vec3(0, 0, 1));

		vec3 reflection = vec3(0.0);
		for (int i = 0; i < SSR_RAY_COUNT; ++i) {
			vec3 facetNormal = GenerateSsrFacet(tangentView, normal, roughness, i + dither, ditherSize);

			float MdotV /* = MdotL */ = dot(facetNormal, -viewDirection);
			#define MdotL MdotV // MdotL and MdotV are identical for specular

			vec3 rayDirection = reflect(viewDirection, facetNormal);
			float NdotL = abs(dot(normal, rayDirection));

			vec3 reflectionSample = TraceSsrRay(sampler, position, rayDirection, NdotL, roughness, skyFade, dither);

			reflectionSample *= FresnelDielectric(MdotV, (isEyeInWater == 1 && isWater ? 1.333 : 1.0002275) / n);
			reflectionSample *= G2OverG1SmithGGX(NdotV, NdotL, roughnessSquared);

			reflection += reflectionSample;
		} reflection /= SSR_RAY_COUNT;

		return reflection;
	}
#endif

#endif
