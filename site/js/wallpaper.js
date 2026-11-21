// A procedural aurora drawn with one full-screen WebGL triangle.

const VERTEX = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAGMENT = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 uRes;
uniform float uTime;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p = m * p;
    a *= 0.5;
  }
  return v;
}

// One curtain of light: a sharp lower edge, a long fade upward, and rays.
vec3 curtain(vec2 w, float fi, float t, float f) {
  float y = 0.13 * sin(w.x * (1.2 + 0.45 * fi) + t * (1.3 + 0.4 * fi) + fi * 2.3)
          + 0.06 * sin(w.x * 3.1 - t * 1.1 + fi * 4.0)
          + 0.26 * (fi - 1.0) - 0.05;
  float d = w.y - y;
  float edge = d > 0.0 ? exp(-d * (3.2 + 1.5 * fi)) : exp(d * 30.0);
  float rays = 0.3 + 0.7 * pow(noise(vec2(w.x * 13.0 + fi * 7.0, t * 0.8 + w.y * 0.6)), 1.6);
  vec3 low = fi < 0.5 ? vec3(0.16, 0.86, 0.72) : fi < 1.5 ? vec3(0.20, 0.70, 0.86) : vec3(0.30, 0.42, 0.95);
  vec3 high = fi < 1.5 ? vec3(0.36, 0.34, 0.92) : vec3(0.78, 0.36, 0.70);
  vec3 c = mix(low, high, smoothstep(0.0, 0.55, d));
  return c * edge * rays * (0.45 + 0.9 * f);
}

void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  vec2 p = (gl_FragCoord.xy - 0.5 * uRes) / uRes.y;
  float t = uTime * 0.05;

  vec2 q = vec2(fbm(p * 1.2 + vec2(0.0, t)), fbm(p * 1.2 + vec2(5.2, -t)));
  vec2 w = p + 0.35 * (q - 0.5);
  float f = fbm(w * 1.6 + vec2(t * 0.7, -t * 0.4));

  vec3 light = vec3(0.0);
  for (int i = 0; i < 3; i++) {
    light += curtain(w, float(i), t, f) * (0.55 - 0.1 * float(i));
  }
  light += vec3(0.05, 0.10, 0.22) * (1.0 - smoothstep(0.0, 1.1, length(p - vec2(-0.5, -0.5)))) * 0.5;

  vec3 base = mix(vec3(0.008, 0.010, 0.014), vec3(0.020, 0.024, 0.040), uv.y);
  vec3 col = 1.0 - exp(-(base + light) * 1.6);
  col *= mix(0.45, 1.0, (1.0 - smoothstep(0.2, 1.3, length(p * vec2(0.75, 1.0)))));
  col += (hash(gl_FragCoord.xy + fract(uTime)) - 0.5) / 255.0;
  gl_FragColor = vec4(col, 1.0);
}
`;

/** Renderer for one canvas. `ok` is false when WebGL is unavailable. */
export class Wallpaper {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {{scale?: number, maxPixelRatio?: number}} options
   *   scale renders below CSS size; the soft gradients upscale without loss.
   */
  constructor(canvas, { scale = 0.5, maxPixelRatio = 1.5 } = {}) {
    this.canvas = canvas;
    this.scale = scale;
    this.maxPixelRatio = maxPixelRatio;
    this.gl = null;
    this.ok = this.#setUp();
    /** Set by the owner; called after the context is lost or restored. */
    this.onContextChange = () => {};
    canvas.addEventListener("webglcontextlost", (e) => {
      e.preventDefault();
      this.ok = false;
      this.onContextChange();
    });
    canvas.addEventListener("webglcontextrestored", () => {
      this.ok = this.#setUp();
      this.resize();
      this.onContextChange();
    });
  }

  #setUp() {
    const gl = this.canvas.getContext("webgl", {
      alpha: false,
      antialias: false,
      depth: false,
      stencil: false,
      powerPreference: "low-power",
    });
    if (!gl) return false;
    const program = gl.createProgram();
    for (const [type, source] of [
      [gl.VERTEX_SHADER, VERTEX],
      [gl.FRAGMENT_SHADER, FRAGMENT],
    ]) {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return false;
      gl.attachShader(program, shader);
    }
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return false;
    gl.useProgram(program);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const pos = gl.getAttribLocation(program, "aPos");
    gl.enableVertexAttribArray(pos);
    gl.vertexAttribPointer(pos, 2, gl.FLOAT, false, 0, 0);
    this.uRes = gl.getUniformLocation(program, "uRes");
    this.uTime = gl.getUniformLocation(program, "uTime");
    this.gl = gl;
    this.width = 0;
    this.height = 0;
    return true;
  }

  /** Match the drawing buffer to the canvas's CSS size. Returns true if it changed. */
  resize() {
    const ratio = Math.min(window.devicePixelRatio || 1, this.maxPixelRatio) * this.scale;
    const width = Math.max(1, Math.round(this.canvas.clientWidth * ratio));
    const height = Math.max(1, Math.round(this.canvas.clientHeight * ratio));
    if (width === this.width && height === this.height) return false;
    this.width = this.canvas.width = width;
    this.height = this.canvas.height = height;
    return true;
  }

  /** Draw the scene at `seconds` of scene time. */
  draw(seconds) {
    if (!this.ok) return;
    const gl = this.gl;
    gl.viewport(0, 0, this.width, this.height);
    gl.uniform2f(this.uRes, this.width, this.height);
    // Wrap the clock so float precision holds on long sessions.
    gl.uniform1f(this.uTime, seconds % 2000);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}

/**
 * Decides which display frames to draw so `cap` fps holds evenly. It banks
 * elapsed time instead of comparing against the last draw, so a 144 Hz
 * display gets 60 draws a second, not the 48 that "wait one whole interval"
 * would give.
 */
export function createPacer(cap = 60) {
  let bank = 0;
  let last = 0;
  return {
    setCap(value) {
      cap = value;
    },
    reset() {
      bank = 0;
      last = 0;
    },
    /** True when the frame at `now` (ms) should be drawn. */
    accept(now) {
      if (!last) {
        last = now;
        return true;
      }
      const interval = 1000 / cap;
      const gap = now - last;
      last = now;
      // A stall is not owed back as extra frames: draw once and start over.
      if (gap > interval * 1.5) {
        bank = 0;
        return true;
      }
      bank += gap;
      // 1.5 ms of slack keeps a 60 Hz display on a 60 fps cap despite jitter.
      if (bank < interval - 1.5) return false;
      bank -= interval;
      return true;
    },
  };
}

/**
 * A requestAnimationFrame loop capped at `fps` that is cancelled outright
 * when stopped. `onStats` gets the frames drawn in the last second.
 */
export function createLoop(draw, { fps = 60, startTime = 40, onStats = () => {} } = {}) {
  let raf = 0;
  const pacer = createPacer(fps);
  let lastDraw = 0;
  let sceneTime = startTime;
  let speed = 1;
  let cap = fps;
  let lastStats = 0;
  const drawn = [];

  function frame(now) {
    raf = requestAnimationFrame(frame);
    if (!pacer.accept(now)) return;
    const dt = lastDraw ? Math.min(now - lastDraw, 100) / 1000 : 0;
    lastDraw = now;
    sceneTime += dt * speed;
    draw(sceneTime, dt);
    if (!raf) return; // the draw callback stopped the loop
    drawn.push(now);
    while (drawn.length && drawn[0] <= now - 1000) drawn.shift();
    if (now - lastStats > 250) {
      lastStats = now;
      onStats(Math.min(cap, drawn.length));
    }
  }

  return {
    get running() {
      return raf !== 0;
    },
    get time() {
      return sceneTime;
    },
    start() {
      if (raf) return;
      lastDraw = 0;
      pacer.reset();
      raf = requestAnimationFrame(frame);
    },
    stop() {
      if (!raf) return;
      cancelAnimationFrame(raf);
      raf = 0;
      drawn.length = 0;
      onStats(0);
    },
    setFps(value) {
      cap = value;
      pacer.setCap(value);
    },
    setSpeed(value) {
      speed = value;
    },
  };
}
