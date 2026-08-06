//
//  ShaderTypes.h
//  Sandkraft
//
//  The single source of truth for every struct that crosses the Swift ⇄ Metal
//  boundary. Included by the bridging header on the Swift side and by every
//  .metal file on the GPU side, so the two can never disagree about layout.
//
//  Layout rules observed throughout this file — do not break them:
//    · members are ordered widest-alignment first (4x4, then float4, then
//      float2, then scalars), which makes the C and MSL layouts identical
//      without any explicit packing attributes;
//    · every struct is padded to a multiple of 16 bytes;
//    · simd_float3 is deliberately never used — it is 16-byte aligned on both
//      sides but the trailing-pad rules are the easiest thing in the world to
//      get subtly wrong. float4 with a documented .w costs nothing.
//

#ifndef SandkraftShaderTypes_h
#define SandkraftShaderTypes_h

#include <simd/simd.h>

// MARK: - Sand field channel layout
//
// The simulation state lives in one RGBA32Float texture:
//
//   .r  depth      metres of loose sand standing on the hardpack
//   .g  moisture   0 bone dry · 0.5 damp (builds best) · 1 saturated (runs)
//   .b  packing    0 loose · 1 driven hard by the flat of a hand
//   .a  film       depth of free surface water sitting on top, metres
//
// Nothing else in the project may claim a channel. Everything derived —
// colour, score, audio, the score readout — is a function of these four.

// MARK: - Frame

/// Everything the renderer needs that changes once per frame. Bound to every
/// draw and dispatch in the frame at a fixed buffer index.
typedef struct {
    simd_float4x4 viewProjection;
    simd_float4x4 inverseViewProjection;
    simd_float4x4 lightViewProjection;
    simd_float4x4 view;

    simd_float4 cameraPosition;      // xyz world, w = tan(halfFovY)
    simd_float4 sunDirection;        // xyz normalised toward the sun, w = elevation in radians
    simd_float4 sunColor;            // rgb transmitted colour, w = disc intensity
    simd_float4 moonDirection;       // xyz, w = phase 0…1
    simd_float4 moonColor;           // rgb, w = intensity
    simd_float4 domain;              // minX, minZ, sizeX, sizeZ of the simulated square
    simd_float4 viewport;            // width, height, 1/width, 1/height in pixels

    simd_float2 texel;               // 1/simResolution, both axes
    float simResolution;             // texels along one edge of the sand texture
    float time;                      // seconds since the tide began, drives the waves

    float seaBase;                   // still-water height before the sets are added
    float waveAmplitude;             // global swell scale for this tide
    float fogK;                      // aerial perspective density
    float exposure;

    float night;                     // 0 full day … 1 full dark, derived from sun colour
    float shadowTexel;               // 1/shadowMapResolution
    float shadowEnabled;             // 0 or 1
    int32_t look;                    // index into the nine looks

    float dayFraction;               // 0…1 through the 24h cycle
    float contactShadowStrength;
    float _pad0;
    float _pad1;
} SKFrameUniforms;

// MARK: - Simulation

/// Brush and environment parameters for one substep of the sand solver.
typedef struct {
    simd_float4 domain;              // minX, minZ, sizeX, sizeZ
    simd_float4 brushA;              // stroke start x, z · radius · strength
    simd_float4 brushB;              // stroke end x, z · mode · mode parameter
    simd_float4 stamp;               // mould x, z · radius · height
    simd_float4 stamp2;              // detail · baseY · gate · active
    simd_float4 stamp3;              // mouldID · rotation · moisture · brush shape
                                     //   w: 0 round footprint, 1 square. Belongs
                                     //   to the stroke rather than to the mould,
                                     //   and is written after both stamp branches.

    simd_float2 texel;
    float simResolution;
    float dt;

    float time;
    float seaBase;
    float waveAmplitude;
    float erosion;                   // 0 disables every wave term, and most of the cost

    float sunDrying;
    float depositScale;              // >0 only on the first substep of a frame
    float _pad0;
    float _pad1;
} SKSimUniforms;

/// Brush modes. Mirrored by `ToolMode` in Swift — keep the two in step.
///  0 none · 1 dig · 2 pour · 3 pack · 4 wet · 5 carve · 6 rampart
///  7 drip · 8 level · 9 smooth · 11 scoop (filling a mould)

// MARK: - Look
//
// A look is data, not a shader variant. Nine copies of the terrain shader would
// be nine places to fix every bug; instead the shaders branch exactly once, on
// `treatment`, where the work is genuinely different rather than merely
// differently tuned.

typedef struct {
    simd_float4 sandTint;        // rgb, w = sand roughness
    simd_float4 wetTint;         // rgb, w = wet specular strength
    simd_float4 waterTint;       // rgb, w = micro-detail strength
    simd_float4 foamTint;        // rgb, w = ink outline weight

    float bandCount;
    float bandSoftness;
    float screenAngle;
    float screenScale;

    float exposure;
    float contrast;
    float saturation;
    float bloom;

    float vignette;
    float grain;
    float chromatic;
    float contourInterval;       // metres, `.contoured` treatment only

    int32_t treatment;           // 0 continuous · 1 banded · 2 separated · 3 contoured
    int32_t index;               // which of the nine, for palette selection
    float _pad0;
    float _pad1;
} SKLookUniforms;

// MARK: - Terrain

typedef struct {
    simd_float4 cursor;          // xz world, z = radius, w = active 0/1
    simd_float4 ghost;           // radius, rotation, shape index, active 0/1
    simd_float4 ghost2;          // detail, height, baseY, moisture
    simd_float4 ghostOrigin;     // xz world of the pending mould, zw unused

    float gridEdge;              // vertices along one edge
    float outer;                 // 0 inner grid, 1 skirt
    float cell;                  // domain.z / simResolution, in metres
    float lanternCount;
} SKTerrainUniforms;

/// A point light on the beach. Lanterns, and nothing else — a general light list
/// would be a nice piece of engineering and would not change a single pixel.
typedef struct {
    simd_float4 position;        // xyz world, w = radius
    simd_float4 color;           // rgb, w = intensity
} SKPointLight;

// MARK: - Particles

typedef struct {
    simd_float4 position;            // xyz world, w = age in seconds
    simd_float4 velocity;            // xyz m/s, w = lifetime in seconds
    simd_float4 payload;             // r = sand volume carried, g = moisture,
                                     // b = size, a = kind (0 grain, 1 spray, 2 foam, 3 dust)
} SKParticle;

typedef struct {
    simd_float4 domain;
    simd_float4 spawnA;              // xyz origin, w = count requested this frame
    simd_float4 spawnB;              // xyz initial velocity, w = spread

    simd_float2 texel;
    float simResolution;
    float dt;

    float time;
    float seaBase;
    float waveAmplitude;
    float gravity;

    uint32_t capacity;
    uint32_t seed;
    float depositFixedPointScale;    // volume → fixed point for the atomic accumulator
    float _pad0;
} SKParticleUniforms;

// MARK: - Props

/// One adornment standing in the sand. Instanced; the vertex shader builds the
/// geometry procedurally from `kind`.
typedef struct {
    simd_float4 position;            // xyz world, w = scale
    simd_float4 orientation;         // xy lean axis, z lean angle in radians, w = yaw
    simd_float4 state;               // r = health 0…1, g = wetness, b = toppled 0/1,
                                     // a = seconds since placed
    simd_float4 tint;                // rgb, a = kind index
} SKProp;

// MARK: - Post

typedef struct {
    simd_float4 viewport;            // width, height, 1/width, 1/height

    float exposure;
    float bloomStrength;
    float vignette;
    float grain;

    float time;
    float night;
    int32_t look;
    float transition;                // 0…1 cross-fade when the look changes

    float chromatic;
    float contrast;
    float saturation;
    float inkOutline;                // 0 disables the edge pass entirely

    // Depth of field. Cheap: the half-resolution bloom blur is reused as the
    // out-of-focus source, so the miniature-diorama look costs one extra mix.
    float focusDistance;             // metres
    float aperture;                  // 0 disables
    float nearPlane;
    float farPlane;

    // Supersample resolve. When the offscreen targets are rendered larger than
    // the drawable, the composite gathers a small tent instead of a single tap —
    // one bilinear sample of a 1.35× buffer is still a point sample as far as
    // aliasing is concerned.
    simd_float2 resolveTexel;        // half a texel of the *source*, in UV
    float resolveStrength;           // 0 when not supersampling
    float _pad1;
} SKPostUniforms;

// MARK: - Sky

typedef struct {
    simd_float4 sunDirection;        // xyz, w = elevation in radians
    simd_float4 moonDirection;       // xyz, w = phase
    simd_float4 groundAlbedo;        // rgb, w = unused

    float turbidity;
    float cloudCover;                // 0 clear … 1 overcast
    float cloudDrift;                // accumulated wind offset, metres
    float time;

    float rayleighScale;
    float mieScale;
    float exposure;
    int32_t look;
} SKSkyUniforms;

// MARK: - Metrics
//
// One of these is produced per frame by a two-stage GPU reduction and read on
// the CPU a frame later. Every number the interface shows about the state of
// the beach comes from here, so it is worth being precise about units.

typedef struct {
    float totalVolume;               // m³ of loose sand in the domain — conserved
    float standingWorth;             // score: volume above the high-water line, weighted by packing
    float packedVolume;              // m³ of sand built above pristine and genuinely packed
    float peakHeight;                // highest built point, metres relative to the high-water line

    float wettedArea;                // m² currently under film or saturated
    float moatVolume;                // m³ of open space below the pristine profile
    float meanMoisture;
    float meanPacking;
} SKMetrics;

/// GPU raycast result. Two texels: [0] is the hit point, [1] the sand under it.
typedef struct {
    simd_float4 point;               // xyz world hit, w = 1 on hit
    simd_float4 sand;                // moisture, packing, depth, bedrock height
} SKPickResult;

#endif /* SandkraftShaderTypes_h */
