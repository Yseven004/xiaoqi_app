#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_page;
out vec4 fragColor;

float chroma(vec3 c) {
  return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 pixel = texture(u_page, uv);
  vec3 rgb = pixel.rgb / max(pixel.a, 0.001);
  float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
  vec3 paper = vec3(25.0, 27.0, 30.0) / 255.0;
  vec3 ink = vec3(230.0, 227.0, 220.0) / 255.0;
  vec3 neutral = mix(ink, paper, luma);
  // Keep the local colour of charts and illustrations. Requiring colour on
  // all sides protects neutral detail inside a photo without creating white
  // halos around coloured headings on paper.
  vec2 dx = vec2(4.0 / u_size.x, 0.0);
  vec2 dy = vec2(0.0, 4.0 / u_size.y);
  float neighbours = min(
    min(chroma(texture(u_page, uv - dx).rgb), chroma(texture(u_page, uv + dx).rgb)),
    min(chroma(texture(u_page, uv - dy).rgb), chroma(texture(u_page, uv + dy).rgb)));
  float keepColour = smoothstep(0.10, 0.27, max(chroma(rgb), neighbours));
  fragColor = vec4(mix(neutral, rgb * 0.86, keepColour) * pixel.a, pixel.a);
}
