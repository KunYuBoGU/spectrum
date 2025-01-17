#if !defined INCLUDE_FRAGMENT_FOG
#define INCLUDE_FRAGMENT_FOG

float PhaseHenyeyGreenstein(float cosTheta, float g) {
	const float norm = 0.25 / pi;

	float gg = g * g;
	return (norm - norm * gg) * pow(1.0 + gg - 2.0 * g * cosTheta, -1.5);
}

//----------------------------------------------------------------------------//

#ifdef VL_AIR

#define SEA_LEVEL 63 // [4 63]

float CalculateAtmosphereRayleighDensity(vec3 worldPosition) {
	return FOG_AIR_DENSITY * exp(-atmosphere_inverseScaleHeights.x * (worldPosition.y - SEA_LEVEL));
}
float CalculateAtmosphereMieDensity(vec3 worldPosition) {
	return FOG_AIR_DENSITY * exp(-atmosphere_inverseScaleHeights.y * (worldPosition.y - SEA_LEVEL));
}
float CalculateMistDensity(vec3 worldPosition) {
	float heightFade = Pow4(smoothstep(32.0, 0.0, worldPosition.y - SEA_LEVEL));
	float timeFade   = sunAngle < 0.5 ? Pow2(smoothstep(0.1, 0.0, sunAngle)) : smoothstep(0.5, 1.0, sunAngle);

	float noise = 2.0 * GetNoise(worldPosition / 3.5);
	//float noise = 3.0 * Pow2(GetNoise(worldPosition / 3.5));

	return heightFade * timeFade * noise;
}

float GetDensity(vec3 worldPosition, int componentIndex) {
	switch (componentIndex) {
		case 0: return CalculateAtmosphereRayleighDensity(worldPosition);
		case 1: return CalculateAtmosphereMieDensity(worldPosition);
		case 2: return CalculateMistDensity(worldPosition);
		default: return 0.0;
	}
}
float GetPhase(float cosTheta, int componentIndex) {
	switch (componentIndex) {
		case 0: return PhaseRayleigh(cosTheta);
		case 1: return PhaseMie(cosTheta, atmosphere_mieg);
		case 2: return PhaseHenyeyGreenstein(cosTheta, 0.4);
		default: return 0.25 / pi;
	}
}

vec3 CalculateVolumeSunlighting(vec3 scenePosition, vec3 shadowPosition) {
	#ifdef SHADOW_INFINITE_RENDER_DISTANCE
		vec3 lighting = vec3(ReadShadowMaps(DistortShadowSpace(shadowPosition) * 0.5 + 0.5));
	#else
		vec3 lighting;
		if (dot(shadowPosition.xy, shadowPosition.xy) < 1.0) {
			lighting = vec3(ReadShadowMaps(DistortShadowSpace(shadowPosition) * 0.5 + 0.5));
		} else {
			lighting = vec3(1.0);
		}
	#endif

	#ifdef CLOUDS3D
		lighting *= GetCloudShadows(scenePosition);
	#endif

	return lighting;
}

vec3 CalculateFog(vec3 background, vec3 startPosition, vec3 endPosition, float skylight, float dither) {
	const int steps = VL_AIR_STEPS;

	vec3 worldIncrement = (endPosition - startPosition) / steps;
	vec3 worldPosition  = startPosition + worldIncrement * dither;
	     worldPosition += cameraPosition;

	vec3 shadowIncrement    = mat3(shadowModelView) * worldIncrement;
	     shadowIncrement   *= Diagonal(shadowProjection).xyz;
	     shadowIncrement.z /= SHADOW_DEPTH_SCALE;
	vec3 shadowPosition     = mat3(shadowModelView) * startPosition + shadowModelView[3].xyz;
	     shadowPosition     = Diagonal(shadowProjection).xyz * shadowPosition + shadowProjection[3].xyz;
	     shadowPosition.z  /= SHADOW_DEPTH_SCALE;
	     shadowPosition    += dither * shadowIncrement;

	float stepSize = length(worldIncrement);
	vec3 viewVector = worldIncrement / stepSize;

	//--//

	const int componentCount = 3;
	const vec3[componentCount] attenuationCoefficients = vec3[componentCount](atmosphere_coefficientsAttenuation[0], atmosphere_coefficientsAttenuation[1], vec3(0.01));
	const vec3[componentCount] scatteringCoefficients = vec3[componentCount](atmosphere_coefficientsScattering[0], atmosphere_coefficientsScattering[1], 0.9 * attenuationCoefficients[2]);

	float LoV = dot(viewVector, shadowLightVector);
	float[componentCount] phase;
	for (int compIdx = 0; compIdx < componentCount; ++compIdx) {
		phase[compIdx] = GetPhase(LoV, compIdx);
	}

	//--//

	vec3 scatteringSun = vec3(0.0);
	vec3 scatteringSky = vec3(0.0);
	vec3 transmittance = vec3(1.0);
	for (int i = 0; i < steps; ++i) {
		float[componentCount] density;
		float[componentCount] stepAirmass;
		vec3 opticalDepth = vec3(0.0);
		for (int compIdx = 0; compIdx < componentCount; ++compIdx) {
			density[compIdx] = GetDensity(worldPosition, compIdx);
			stepAirmass[compIdx] = density[compIdx] * stepSize;
			opticalDepth += attenuationCoefficients[compIdx] * stepAirmass[compIdx];
		}

		//--//

		vec3 stepTransmittance       = exp(-opticalDepth);
		vec3 stepTransmittedFraction = Clamp01((stepTransmittance - 1.0) / -opticalDepth);
		vec3 stepVisibleFraction     = transmittance * stepTransmittedFraction;

		//--//

		vec3 lightingSun = CalculateVolumeSunlighting(worldPosition - cameraPosition, shadowPosition);

		//--//

		vec3 stepScatteringSun = vec3(0.0);
		vec3 stepScatteringSky = vec3(0.0);
		for (int compIdx = 0; compIdx < componentCount; ++compIdx) {
			stepScatteringSun += scatteringCoefficients[compIdx] * stepAirmass[compIdx] * phase[compIdx];
			stepScatteringSky += scatteringCoefficients[compIdx] * stepAirmass[compIdx] * 0.25 / pi;
		}

		//--//

		scatteringSun += stepScatteringSun * stepVisibleFraction * lightingSun;
		scatteringSky += stepScatteringSky * stepVisibleFraction;
		transmittance *= stepTransmittance;

		worldPosition  += worldIncrement;
		shadowPosition += shadowIncrement;
	}

	scatteringSun *= illuminanceShadowlight * skylight;
	scatteringSky *= illuminanceSky * skylight;

	//--//

	vec3 scattering = scatteringSun + scatteringSky;

	return background * transmittance + scattering;
}

#endif

//----------------------------------------------------------------------------//

vec3 CalculateAirFog(vec3 background, vec3 startPosition, vec3 endPosition, vec3 viewVector, float LoV, float startSkylight, float endSkylight, float dither, bool sky) {
	float skylight = startSkylight * (1.0 - endSkylight) + endSkylight;

	#ifdef VL_AIR
		if (sky) {
			endPosition = startPosition + viewVector * far;
		}

		return CalculateFog(background, startPosition, endPosition, skylight, dither);
	#else
		vec2 phaseSun = AtmospherePhases(LoV, atmosphere_mieg);
		const vec2 phaseSky = vec2(0.25 / pi);

		const vec3 baseAttenuationCoefficient = atmosphere_coefficientsAttenuation[0] + atmosphere_coefficientsAttenuation[1] + atmosphere_coefficientsAttenuation[2];

		phaseSun.y *= endSkylight;

		vec3 lightingSky = illuminanceSky * startSkylight;
		vec3 lightingSun = illuminanceShadowlight * startSkylight * GetCloudShadows(startPosition);

		float depth = FOG_AIR_DENSITY * (sky ? far : distance(startPosition, endPosition));
		vec3 opticalDepth = baseAttenuationCoefficient * depth;

		vec3 transmittance   = exp(-opticalDepth);
		vec3 visibleFraction = (transmittance - 1.0) / -opticalDepth;

		vec3 scattering  = atmosphere_coefficientsScattering * (depth * phaseSun) * lightingSun;
			 scattering += atmosphere_coefficientsScattering * (depth * phaseSky) * lightingSky;
			 scattering *= visibleFraction;

		return background * transmittance + scattering;
	#endif
}

float FournierForandPhase(float cosPhi, float n, float mu) {
	float phi = acos(cosPhi);

	// Not sure if this is correct.
	float v = (3.0 - mu) / 2.0;
	float delta = (4.0 / (3.0 * Pow2(n - 1))) * Pow2(sin(phi / 2.0));
	float delta180 = 4.0 / (3.0 * Pow2(n - 1));

	float p1 = 1.0 / (4.0 * pi * Pow2(1.0 - delta) * pow(delta, v));
	float p2 = v * (1.0 - delta) - (1.0 - pow(delta, v)) + (delta * (1.0 - pow(delta, v)) - v * (1.0 - delta)) / Pow2(sin(phi / 2.0));
	float p3 = ((1.0 - pow(delta180, v)) / (16.0 * pi * (delta180 - 1.0) * pow(delta180, v))) * (3.0 * cosPhi * cosPhi - 1.0);
	return p1 * p2 + p3;
}

vec3 CalculateWaterFog(vec3 background, vec3 startPosition, vec3 endPosition, vec3 viewVector, float LoV, float skylight, float dither, bool sky) {
	vec3 waterScatteringAlbedo = SrgbToLinear(vec3(WATER_SCATTERING_R, WATER_SCATTERING_G, WATER_SCATTERING_B) / 255.0);
	vec3 baseAttenuationCoefficient = -log(SrgbToLinear(vec3(WATER_TRANSMISSION_R, WATER_TRANSMISSION_G, WATER_TRANSMISSION_B) / 255.0)) / WATER_REFERENCE_DEPTH;

	const float isotropicPhase = 0.25 / pi;

	//#define sunlightPhase isotropicPhase
	#ifdef WATER_REALISTIC_PHASE_FUNCTION
	float sunlightPhase = FournierForandPhase(LoV, 1.4, 4.4); // Accurate-ish for water
	#else
	float sunlightPhase = PhaseHenyeyGreenstein(LoV, 0.5);
	#endif

	#ifdef UNDERWATER_ADAPTATION
		float fogDensity = isEyeInWater == 1 ? fogDensity : 0.1;
	#else
		const float fogDensity = 0.1;
	#endif

	#ifdef VL_WATER
		const int steps = VL_WATER_STEPS;

		//--//

		vec3 incrementWorld = (endPosition - startPosition) / steps;
		vec3 worldPosition  = startPosition + incrementWorld * dither;

		vec3 incrementShadow    = mat3(shadowModelView) * incrementWorld;
			 incrementShadow   *= Diagonal(shadowProjection).xyz;
			 incrementShadow.z /= SHADOW_DEPTH_SCALE;
		vec3 shadowPosition     = mat3(shadowModelView) * startPosition + shadowModelView[3].xyz;
			 shadowPosition     = Diagonal(shadowProjection).xyz * shadowPosition + shadowProjection[3].xyz;
			 shadowPosition.z  /= SHADOW_DEPTH_SCALE;
			 shadowPosition    += incrementShadow * dither;

		float stepSize = length(incrementWorld);

		//--//

		vec3 stepOpticalDepth  = baseAttenuationCoefficient * fogDensity * stepSize;
		vec3 stepTransmittance = exp(-stepOpticalDepth);

		vec3 scatteringSun = vec3(0.0);
		vec3 scatteringSky = vec3(0.0);
		vec3 transmittance = vec3(1.0);
		for (int i = 0; i < steps; ++i, worldPosition += incrementWorld, shadowPosition += incrementShadow) {
			vec3 shadowCoord = DistortShadowSpace(shadowPosition) * 0.5 + 0.5;

			#ifdef SHADOW_INFINITE_RENDER_DISTANCE
				vec3 lightingSun = vec3(ReadShadowMaps(shadowCoord));
			#else
				vec3 lightingSun;
				if (dot(shadowPosition.xy, shadowPosition.xy) < 1.0) {
					lightingSun = vec3(ReadShadowMaps(shadowCoord));
				} else {
					lightingSun = vec3(1.0);
				}
			#endif

			#ifdef CLOUDS3D
				lightingSun *= GetCloudShadows(worldPosition);
			#endif

			if (texture(shadowcolor0, shadowCoord.xy).a > 0.5) {
				float waterDepth = SHADOW_DEPTH_RADIUS * Max0(shadowCoord.z - textureLod(shadowtex0, shadowCoord.xy, 0.0).r);

				if (waterDepth > 0.0) {
					lightingSun *= exp(-baseAttenuationCoefficient * fogDensity * waterDepth);

					#if defined VL_WATER_CAUSTICS && defined CAUSTICS
						lightingSun *= CalculateCaustics(worldPosition, waterDepth, 0.5, 1.0);
					#endif
				}
			}

			//--//

			scatteringSun += transmittance * lightingSun;
			scatteringSky += transmittance;
			transmittance *= stepTransmittance;
		}

		//--//

		vec3 stepTransmittedFraction = Clamp01((stepTransmittance - 1.0) / -stepOpticalDepth);

		vec3 scattering  = scatteringSun * sunlightPhase * illuminanceShadowlight * skylight;
			 scattering += scatteringSky * isotropicPhase * illuminanceSky * skylight;
			 scattering *= waterScatteringAlbedo * stepOpticalDepth * stepTransmittedFraction;

		//--//

		if (sky) {
			vec3 lighting = illuminanceShadowlight * sunlightPhase * skylight;
			#ifdef CLOUDS3D
				if (isEyeInWater == 1) {
					lighting *= GetCloudShadows(gbufferModelViewInverse[3].xyz);
				}
			#endif
			lighting += illuminanceSky * isotropicPhase * skylight;

			scattering += lighting * waterScatteringAlbedo * transmittance;
			transmittance = vec3(0.0);
		}
	#else
		vec3 lighting = illuminanceSky * isotropicPhase * skylight;
		if (isEyeInWater == 1) {
			lighting += illuminanceShadowlight * sunlightPhase * skylight * GetCloudShadows(startPosition);
		} else {
			#if defined PROGRAM_COMPOSITE
				lighting += illuminanceShadowlight * sunlightPhase * SrgbToLinear(texture(colortex7, screenCoord).rgb);
			#else
				lighting += illuminanceShadowlight * sunlightPhase; // TODO: shadows
			#endif
		}

		if (sky) {
			return lighting * waterScatteringAlbedo;
		}

		float waterDepth   = distance(startPosition, endPosition);
		vec3  opticalDepth = baseAttenuationCoefficient * fogDensity * waterDepth;

		vec3 transmittance   = exp(-opticalDepth);
		vec3 unlitScattering = waterScatteringAlbedo - waterScatteringAlbedo * transmittance;
		vec3 scattering      = lighting * unlitScattering;
	#endif

	return background * transmittance + scattering;
}

#endif
