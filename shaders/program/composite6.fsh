#include "/settings.glsl"

//----------------------------------------------------------------------------//

// Viewport
uniform float viewWidth, viewHeight;

// Samplers
uniform sampler2D colortex3;

//----------------------------------------------------------------------------//

varying vec2 screenCoord;

//----------------------------------------------------------------------------//

void main() {
	#ifdef GLARE
	vec2 px = 1.0 / vec2(viewWidth, viewHeight);

	const float[5] weights = float[5](0.19947114, 0.29701803, 0.09175428, 0.01098007, 0.00050326);
	const float[5] offsets = float[5](0.00000000, 1.40733340, 3.29421497, 5.20181322, 7.13296424);

	vec3 glare = texture2D(colortex3, screenCoord).rgb * weights[0];
	for (int i = 1; i < 5; i++) {
		vec2 offset = offsets[i] * vec2(0.0, 1.0 / viewHeight);
		glare += texture2D(colortex3, screenCoord + offset).rgb * weights[i];
		glare += texture2D(colortex3, screenCoord - offset).rgb * weights[i];
	}

/* DRAWBUFFERS:3 */

	gl_FragData[0] = vec4(glare, 1.0);
	#else
	discard;
	#endif
}