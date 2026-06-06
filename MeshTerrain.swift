// Strataris — GPU mesh-terrain renderer + quaternion flight camera.
//
// The game's world renderer. The heightmap (Terrain) is turned into a GPU
// triangle mesh and rendered through a Metal 3D pipeline (view/projection +
// depth buffer) from a quaternion free camera (`Camera6DOF`), so arbitrary
// pitch/roll — including inverted, for the level-3 Axis Unlock — "just works".
// It draws into a 480×270 offscreen texture (preserving the lo-fi pixel look
// under the nearest-neighbour blit) and reads that frame back into the 2D
// `Canvas2D` framebuffer, which then composites the HUD and cutscenes on top.
// A view-ray sky tilts/inverts the horizon correctly; enemy craft render as
// lit flat-shaded entities and effects as camera-facing billboards.
//
// Contents: math helpers (perspectiveRH, enemyModel) · Camera6DOF (restricted
// + full envelopes) · GPU uniforms · MeshTerrainRenderer (streaming patch,
// altitude LOD, staged terrain swap for warps, framebuffer readback).

import Metal
import simd
import Foundation
import QuartzCore

// MARK: - Math helpers

/// Right-handed perspective with Metal clip-space depth in [0, 1].
private func perspectiveRH(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tanf(fovY * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs, 0,  0,        0),
        SIMD4<Float>(0,  ys, 0,        0),
        SIMD4<Float>(0,  0,  zs,      -1),
        SIMD4<Float>(0,  0,  zs * near, 0)))
}

/// World transform for a craft: orient model-space (forward +Y, up +Z, right +X)
/// onto the enemy's facing, scaled to its world size, placed at its position.
func enemyModel(_ e: Enemy, scale s: Float) -> simd_float4x4 {
    let fwd = simd_normalize(SIMD3<Float>(e.fwdX, e.fwdY, e.fwdZ))
    var right = simd_cross(fwd, SIMD3<Float>(0, 0, 1))
    if simd_length(right) < 1e-4 { right = SIMD3<Float>(1, 0, 0) }   // facing ≈ world up
    right = simd_normalize(right)
    let up = simd_cross(right, fwd)
    return simd_float4x4(columns: (
        SIMD4<Float>(right * s, 0),
        SIMD4<Float>(fwd * s, 0),
        SIMD4<Float>(up * s, 0),
        SIMD4<Float>(e.x, e.y, e.z, 1)))
}

// MARK: - Free camera (quaternion orientation, no gimbal lock under loops)

struct Camera6DOF {
    enum Mode { case restricted, full }

    var position: SIMD3<Float>
    var orientation: simd_quatf
    var fovY: Float = 1.05            // ~60°
    var near: Float = 1
    var far: Float = 2600             // covers the altitude-scaled draw distance

    /// Flight envelope. `.restricted` (levels 1–2) clamps pitch and turns with a
    /// coordinated bank, keeping "up" near world-up so it feels like the shipping
    /// game; `.full` (the level-3 Axis Unlock perk) is unconstrained 6DOF.
    var mode: Mode = .restricted
    // Restricted-mode euler state (heading/pitch are authoritative there; bank is
    // an eased cosmetic roll for the coordinated turn).
    var heading: Float = 0
    var pitch: Float = 0
    var bank: Float = 0

    /// Orientation for level flight at heading 0 (forward -Y, up +Z).
    static let levelBase: simd_quatf = {
        let f = SIMD3<Float>(0, -1, 0), up = SIMD3<Float>(0, 0, 1)
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        return simd_quatf(simd_float3x3(columns: (r, u, -f)))
    }()

    /// Initial orientation: forward = world -Y, up = world +Z (matches the
    /// game's angle-0 heading), derived from an explicit basis.
    static func start(forward: SIMD3<Float> = SIMD3(0, -1, 0),
                      up: SIMD3<Float> = SIMD3(0, 0, 1),
                      position: SIMD3<Float>) -> Camera6DOF {
        let f = simd_normalize(forward)
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        let back = -f
        let m = simd_float3x3(columns: (r, u, back))     // body→world rotation
        return Camera6DOF(position: position, orientation: simd_quatf(m))
    }

    /// Build a restricted-envelope view directly from the game's flight scalars
    /// (heading/pitch/bank in radians), matching `flyRestricted`'s orientation
    /// construction. Used in Milestone-1 integration where the legacy `Camera`
    /// stays authoritative and the mesh view is derived from it each frame.
    static func restricted(position: SIMD3<Float>, heading: Float, pitch: Float,
                           bank: Float, speed: Float) -> Camera6DOF {
        var c = Camera6DOF(position: position, orientation: levelBase)
        c.mode = .restricted; c.heading = heading; c.pitch = pitch; c.bank = bank; c.speed = speed
        let qYaw   = simd_quatf(angle: heading, axis: SIMD3(0, 0, 1))
        let qPitch = simd_quatf(angle: pitch,   axis: SIMD3(1, 0, 0))
        let qBank  = simd_quatf(angle: bank,    axis: SIMD3(0, 0, -1))
        c.orientation = qYaw * levelBase * qPitch * qBank
        return c
    }

    var forward: SIMD3<Float> { orientation.act(SIMD3(0, 0, -1)) }
    var up:      SIMD3<Float> { orientation.act(SIMD3(0, 1, 0)) }
    var right:   SIMD3<Float> { orientation.act(SIMD3(1, 0, 0)) }

    /// Forward speed (world units/sec). Carried on the camera so the game's HUD
    /// readout and engine-audio pitch read it the same way they read the legacy
    /// `Camera.speed`.
    var speed: Float = 90

    // Legacy-scalar bridge: derive the (heading, pitch, bank) the 2D HUD/radar
    // expect from the quaternion, so call sites never touch the orientation.
    // All mode-independent (valid in both restricted and full envelopes).

    /// Heading in the game's yaw convention, where level forward = (-sin a, -cos a).
    /// Feeds `drawRadar` so the scope spins correctly.
    var groundHeading: Float { let f = forward; return atan2f(-f.x, -f.y) }
    /// Nose elevation above the horizon (radians); feeds the attitude dial.
    var pitchAngle: Float { asinf(max(-1, min(1, forward.z))) }
    /// Bank/roll about the forward axis (radians); feeds the attitude dial.
    var bankAngle: Float { let r = right, u = up; return atan2f(-r.z, u.z) }

    func viewMatrix() -> simd_float4x4 {
        let r = right, u = up, b = -forward          // camera local +Z points backward
        let m = simd_float4x4(columns: (
            SIMD4<Float>(r, 0), SIMD4<Float>(u, 0), SIMD4<Float>(b, 0), SIMD4<Float>(position, 1)))
        return m.inverse
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        perspectiveRH(fovY: fovY, aspect: aspect, near: near, far: far)
    }

    /// Project a world point to framebuffer pixels (origin top-left, matching the
    /// rendered colour texture), returning the view-forward `depth` (>0 = in front)
    /// and `radiusScale` — the pixels-per-world-unit at that depth, so callers can
    /// size a reticle/lock box exactly as the perspective draw does. nil if behind
    /// the camera or well off-screen.
    func project(_ world: SIMD3<Float>, width: Int, height: Int)
        -> (x: Float, y: Float, depth: Float, radiusScale: Float)? {
        let aspect = Float(width) / Float(height)
        let clip = projectionMatrix(aspect: aspect) * (viewMatrix() * SIMD4<Float>(world, 1))
        let depth = clip.w                          // = view-forward distance for this proj
        if depth <= 0.5 { return nil }              // behind / on the camera plane
        let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
        if abs(ndcX) > 1.4 || abs(ndcY) > 1.4 { return nil }   // generous off-screen cull
        let sx = (ndcX * 0.5 + 0.5) * Float(width)
        let sy = (1 - (ndcY * 0.5 + 0.5)) * Float(height)      // flip V (texture origin top-left)
        let focalPx = Float(height) * 0.5 / tanf(fovY * 0.5)
        return (sx, sy, depth, focalPx / depth)
    }

    /// Apply body-frame rotations (radians). Right-multiplying keeps the axes in
    /// the ship's own frame, so a loop carries roll/yaw with it (no gimbal lock).
    mutating func rotateBody(pitch: Float, yaw: Float, roll: Float) {
        var q = orientation
        if pitch != 0 { q = q * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) }
        if yaw   != 0 { q = q * simd_quatf(angle: yaw,   axis: SIMD3(0, 1, 0)) }
        if roll  != 0 { q = q * simd_quatf(angle: roll,  axis: SIMD3(0, 0, -1)) }  // about forward
        orientation = q.normalized
    }

    /// Full 6DOF integration (level-3 Axis Unlock): free body-frame rotation.
    mutating func flyFull(pitch: Float, yaw: Float, roll: Float, dt: Float,
                          rate: Float = 1.9, yawRate: Float = 1.1) {
        rotateBody(pitch: pitch * rate * dt, yaw: yaw * yawRate * dt, roll: roll * rate * dt)
    }

    /// Restricted envelope (levels 1–2): a `turn` banks-and-yaws (coordinated
    /// turn), pitch is clamped, and "up" stays near world-up — the shipping feel.
    mutating func flyRestricted(turn: Float, pitchIn: Float, dt: Float,
                                yawRate: Float = 1.4, pitchRate: Float = 1.4,
                                maxPitch: Float = 0.5, bankMax: Float = 0.5,
                                levelRate: Float = 2.5) {
        heading += turn * yawRate * dt
        if pitchIn != 0 {
            pitch = max(-maxPitch, min(maxPitch, pitch + pitchIn * pitchRate * dt))
        } else {
            pitch += (0 - pitch) * min(1, dt * levelRate)       // hands-off → ease nose to level
        }
        bank += (-turn * bankMax - bank) * min(1, dt * 8)       // bank into the turn; level when straight
        let qYaw   = simd_quatf(angle: heading, axis: SIMD3(0, 0, 1))   // world up = +Z
        let qPitch = simd_quatf(angle: pitch,   axis: SIMD3(1, 0, 0))   // body right
        let qBank  = simd_quatf(angle: bank,    axis: SIMD3(0, 0, -1))  // body forward
        orientation = qYaw * Camera6DOF.levelBase * qPitch * qBank
    }

    /// Bank-to-turn (full 6DOF): yaw the heading about world-up in proportion to
    /// how banked the wings are, so rolling into a bank actually turns the craft
    /// like an aircraft (rolling alone wouldn't change heading). Zero when level.
    mutating func bankToTurn(dt: Float, gain: Float = 1.7) {
        let dyaw = right.z * gain * dt        // right wing low (right.z < 0) → turn right
        orientation = simd_quatf(angle: dyaw, axis: SIMD3(0, 0, 1)) * orientation
    }

    /// Hands-off auto-level for full 6DOF: ease the orientation toward upright at
    /// the current heading (wings level, nose to horizon) via the shortest arc,
    /// so releasing the stick recovers from any attitude — even inverted.
    mutating func autoLevelFull(dt: Float, rate: Float = 1.6) {
        let f = forward
        let horiz = sqrtf(f.x * f.x + f.y * f.y)
        let hd = horiz > 0.001 ? atan2f(f.x, -f.y) : heading
        let target = simd_quatf(angle: hd, axis: SIMD3(0, 0, 1)) * Camera6DOF.levelBase
        orientation = simd_slerp(orientation, target, min(1, dt * rate))
    }

    /// Switch envelope, keeping the view continuous. Entering restricted derives
    /// heading/pitch from the current facing and levels the wings.
    mutating func setMode(_ m: Mode) {
        guard m != mode else { return }
        if m == .restricted {
            let f = forward
            heading = atan2f(f.x, -f.y)
            pitch = asinf(max(-1, min(1, f.z)))
            bank = 0
        }
        mode = m
    }
}

// MARK: - GPU uniforms (must match the MSL structs below; all fields 16-aligned)

private struct MeshUniforms {
    var mvp: simd_float4x4
    var eye: SIMD4<Float>          // xyz = camera position
    var fogColor: SIMD4<Float>     // xyz = fog/horizon colour
    var fogParams: SIMD4<Float>    // x = near, y = far
}

private struct SkyUniforms {
    var invViewProj: simd_float4x4
    var zenith: SIMD4<Float>       // sky hues from the planet theme
    var horizon: SIMD4<Float>
    var ground: SIMD4<Float>
}

private struct MeshVertex {
    var pos: SIMD3<Float>          // stride 16 in Swift (pos at 0, colour at 16)
    var color: SIMD4<Float>
}

private struct EntityVertex {
    var pos: SIMD3<Float>          // pos @0, normal @16, colour @32 — stride 48
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

private struct EntityUniforms {
    var vp: simd_float4x4          // proj * view
    var model: simd_float4x4       // per-craft world transform (rotate + scale + place)
    var eye: SIMD4<Float>          // camera position (fog distance)
    var light: SIMD4<Float>        // world light direction
    var fog: SIMD4<Float>          // x = near, y = far
}

private struct BillboardVertex {
    var center: SIMD3<Float>       // center @0, (cornerX, cornerY, size) @16, colour @32 — stride 48
    var cs: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct BillboardUniforms {
    var vp: simd_float4x4
    var camRight: SIMD4<Float>     // camera basis, for facing the quad at the camera
    var camUp: SIMD4<Float>
    var eye: SIMD4<Float>
    var fog: SIMD4<Float>
}

/// A camera-facing effect quad (explosion / smoke / bolt). `additive` brightens
/// (fire, tracers); otherwise it's alpha-blended (smoke).
struct Billboard {
    var center: SIMD3<Float>
    var size: Float
    var color: SIMD4<Float>
    var additive: Bool
}

// MARK: - Mesh-terrain renderer

final class MeshTerrainRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let entityPipeline: MTLRenderPipelineState
    private let bbAddPipeline: MTLRenderPipelineState  // additive billboards (fire/bolts)
    private let bbAlphaPipeline: MTLRenderPipelineState // alpha billboards (smoke)
    private let meshDepth: MTLDepthStencilState        // less + write
    private let skyDepth: MTLDepthStencilState         // always + no write
    private let fxDepth: MTLDepthStencilState          // less + NO write (occluded, but don't occlude)
    private var entityBuffers: [EnemyKind: (buf: MTLBuffer, count: Int)] = [:]
    private var fxBufs: [MTLBuffer]                    // pooled per-frame billboard verts
    private var fxBufIndex = 0
    private let fxCapacityVerts = 4096                 // ~680 billboards/frame

    let width: Int, height: Int
    let colorTex: MTLTexture                 // resolved (1×) colour read back / sampled
    private let depthTex: MTLTexture
    private let sampleCount: Int             // 4× MSAA where supported, else 1
    private let msaaColorTex: MTLTexture?    // multisample target, resolved into colorTex

    // Streaming terrain patch: a fixed-size grid that recenters on the camera as
    // it flies. The heightmap wraps (Terrain & mask), so re-sampling a moving
    // window gives seamless, edgeless terrain in every direction.
    private var terrain: Terrain            // swapped on warp via setTerrain (pipelines reused)
    private let patchN: Int                 // cells per side
    private let vertsPerSide: Int           // patchN + 1
    private let recenterStep: Int           // rebuild once the camera drifts this many cells
    private(set) var cellStride = 1         // world units per cell — grows with altitude (LOD)
    /// World half-extent of the patch (for fog/far tuning); scales with stride.
    var worldHalf: Float { Float(patchN / 2 * cellStride) }
    /// The fog far-distance from the last encoded frame — beyond it, craft have
    /// faded into the haze (used by the attract demo to only engage visible craft).
    private(set) var fogFarDistance: Float = 2600
    private let ibuf: MTLBuffer
    private let indexCount: Int
    private var vbufs: [MTLBuffer]          // pool, cycled so an in-flight frame isn't overwritten
    private var activeVB = 0
    private var centerCell: SIMD2<Int>      // patch centre, world coords (quantised to stride)
    private var building = false
    private var forceRebuild = false        // heightfield changed (e.g. a base crumbled) → rebuild the patch
    private let buildQueue = DispatchQueue(label: "cc.jorviksoftware.strataris.meshbuild")


    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MeshU { float4x4 mvp; float4 eye; float4 fogColor; float4 fogParams; };

    struct VIn  { float3 pos [[attribute(0)]]; float4 col [[attribute(1)]]; };
    // `flat` colour → no Gouraud blend, so the terrain reads chunky and banded
    // (per-cell shading) rather than smooth-interpolated.
    struct VOut { float4 position [[position]]; float4 color [[flat]]; float fogT; };

    vertex VOut v_mesh(VIn in [[stage_in]], constant MeshU& u [[buffer(1)]]) {
        VOut o;
        o.position = u.mvp * float4(in.pos, 1.0);
        o.color = in.col;
        float d = distance(in.pos, u.eye.xyz);
        o.fogT = clamp((d - u.fogParams.x) / max(1.0, u.fogParams.y - u.fogParams.x), 0.0, 1.0);
        return o;
    }
    fragment float4 f_mesh(VOut in [[stage_in]], constant MeshU& u [[buffer(1)]]) {
        // Fade to transparent with distance and let the sky (drawn first) show
        // through, so the patch edge dissolves into the exact sky — no hard seam,
        // no colour mismatch.
        return float4(in.color.rgb, 1.0 - in.fogT);
    }

    // Lit, flat-shaded craft (enemies). Per-face normals → faceted look; shading
    // rotates with the craft. Fades with distance like the terrain.
    struct EntU { float4x4 vp; float4x4 model; float4 eye; float4 light; float4 fog; };
    struct EVIn  { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float4 col [[attribute(2)]]; };
    struct EVOut { float4 position [[position]]; float3 shaded; float fogT; };

    vertex EVOut v_entity(EVIn in [[stage_in]], constant EntU& u [[buffer(1)]]) {
        float4 wp = u.model * float4(in.pos, 1.0);
        float3x3 rot = float3x3(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz);
        float3 n = normalize(rot * in.nrm);
        float d = max(0.0, dot(n, normalize(u.light.xyz)));
        EVOut o;
        o.position = u.vp * wp;
        o.shaded = in.col.rgb * (0.45 + 0.55 * d);
        float dist = distance(wp.xyz, u.eye.xyz);
        o.fogT = clamp((dist - u.fog.x) / max(1.0, u.fog.y - u.fog.x), 0.0, 1.0);
        return o;
    }
    fragment float4 f_entity(EVOut in [[stage_in]]) {
        return float4(in.shaded, 1.0 - in.fogT);
    }

    // Camera-facing billboard (effects): the quad corner is offset along the
    // camera's right/up axes, so it always faces the viewer. Soft round falloff.
    struct BBU { float4x4 vp; float4 camRight; float4 camUp; float4 eye; float4 fog; };
    struct BVIn  { float3 center [[attribute(0)]]; float4 cs [[attribute(1)]]; float4 col [[attribute(2)]]; };
    struct BVOut { float4 position [[position]]; float4 color; float2 uv; float fogT; };

    vertex BVOut v_bb(BVIn in [[stage_in]], constant BBU& u [[buffer(1)]]) {
        float3 wp = in.center + u.camRight.xyz * (in.cs.x * in.cs.z) + u.camUp.xyz * (in.cs.y * in.cs.z);
        BVOut o;
        o.position = u.vp * float4(wp, 1.0);
        o.color = in.col;
        o.uv = in.cs.xy;
        float dist = distance(in.center, u.eye.xyz);
        o.fogT = clamp((dist - u.fog.x) / max(1.0, u.fog.y - u.fog.x), 0.0, 1.0);
        return o;
    }
    fragment float4 f_bb(BVOut in [[stage_in]]) {
        float a = in.color.a * (1.0 - in.fogT) * clamp(1.0 - length(in.uv), 0.0, 1.0);  // soft disc
        return float4(in.color.rgb, a);
    }

    // Full-screen sky: reconstruct the world-space view ray per pixel from the
    // inverse view-projection, then colour by the ray's world-up (z) component
    // so the horizon is a true world plane that tilts and inverts with the camera.
    struct SkyU { float4x4 invViewProj; float4 zenith; float4 horizon; float4 ground; };
    struct SOut { float4 position [[position]]; float2 ndc; };

    vertex SOut v_sky(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0)(2,0)(0,2)
        SOut o;
        o.position = float4(p * 2.0 - 1.0, 1.0, 1.0);  // z=1 (far)
        o.ndc = p * 2.0 - 1.0;
        return o;
    }
    fragment float4 f_sky(SOut in [[stage_in]], constant SkyU& u [[buffer(0)]]) {
        float4 np = u.invViewProj * float4(in.ndc, 0.0, 1.0); np /= np.w;
        float4 fp = u.invViewProj * float4(in.ndc, 1.0, 1.0); fp /= fp.w;
        float3 dir = normalize(fp.xyz - np.xyz);
        float t = dir.z;                                // world up = +z
        // Hues come from the planet theme.
        float3 c = t >= 0.0 ? mix(u.horizon.rgb, u.zenith.rgb, smoothstep(0.0, 0.55, t))
                            : mix(u.horizon.rgb, u.ground.rgb, smoothstep(0.0, -0.5, t));
        return float4(c, 1.0);
    }
    """

    init?(device: MTLDevice, terrain: Terrain, width: Int, height: Int,
          patchCells: Int = 1024, patchCenterX: Int = 512, patchCenterY: Int = 512) {
        self.device = device
        self.width = width
        self.height = height
        self.terrain = terrain
        self.patchN = patchCells
        self.vertsPerSide = patchCells + 1
        // Recenter often enough that the patch edge always stays beyond the fog
        // (worldHalf - drift > fog end), so the seam never peeks out — new terrain
        // is born fully fogged and fades in rather than popping.
        self.recenterStep = max(8, patchCells / 12)
        self.centerCell = SIMD2<Int>(patchCenterX, patchCenterY)
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        // 4× MSAA where supported — smooths the edges between adjacent flat-shaded
        // terrain triangles (coastlines, height-band boundaries) without losing
        // the chunky look. Falls back to 1× on any device that can't do it.
        let sc = device.supportsTextureSampleCount(4) ? 4 : 1
        self.sampleCount = sc

        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: MeshTerrainRenderer.shaderSource, options: nil) }
        catch { print("6DOF: shader compile failed — \(error)"); return nil }

        // Vertex layout: float3 pos @0, float4 colour @16, stride 32.
        let vdesc = MTLVertexDescriptor()
        vdesc.attributes[0].format = .float3; vdesc.attributes[0].offset = 0;  vdesc.attributes[0].bufferIndex = 0
        vdesc.attributes[1].format = .float4; vdesc.attributes[1].offset = 16; vdesc.attributes[1].bufferIndex = 0
        vdesc.layouts[0].stride = 32

        do {
            let md = MTLRenderPipelineDescriptor()
            md.vertexFunction = lib.makeFunction(name: "v_mesh")
            md.fragmentFunction = lib.makeFunction(name: "f_mesh")
            md.vertexDescriptor = vdesc
            md.colorAttachments[0].pixelFormat = .rgba8Unorm
            // Alpha-blend so distant terrain dissolves into the sky behind it.
            md.colorAttachments[0].isBlendingEnabled = true
            md.colorAttachments[0].rgbBlendOperation = .add
            md.colorAttachments[0].alphaBlendOperation = .add
            md.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            md.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            md.colorAttachments[0].sourceAlphaBlendFactor = .one
            md.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            md.depthAttachmentPixelFormat = .depth32Float
            md.rasterSampleCount = sc
            self.meshPipeline = try device.makeRenderPipelineState(descriptor: md)

            let sd = MTLRenderPipelineDescriptor()
            sd.vertexFunction = lib.makeFunction(name: "v_sky")
            sd.fragmentFunction = lib.makeFunction(name: "f_sky")
            sd.colorAttachments[0].pixelFormat = .rgba8Unorm
            sd.depthAttachmentPixelFormat = .depth32Float
            sd.rasterSampleCount = sc
            self.skyPipeline = try device.makeRenderPipelineState(descriptor: sd)

            // Entity (craft) layout: float3 pos @0, float3 normal @16, float4 col @32.
            let evd = MTLVertexDescriptor()
            evd.attributes[0].format = .float3; evd.attributes[0].offset = 0;  evd.attributes[0].bufferIndex = 0
            evd.attributes[1].format = .float3; evd.attributes[1].offset = 16; evd.attributes[1].bufferIndex = 0
            evd.attributes[2].format = .float4; evd.attributes[2].offset = 32; evd.attributes[2].bufferIndex = 0
            evd.layouts[0].stride = 48
            let ed = MTLRenderPipelineDescriptor()
            ed.vertexFunction = lib.makeFunction(name: "v_entity")
            ed.fragmentFunction = lib.makeFunction(name: "f_entity")
            ed.vertexDescriptor = evd
            ed.colorAttachments[0].pixelFormat = .rgba8Unorm
            ed.colorAttachments[0].isBlendingEnabled = true
            ed.colorAttachments[0].rgbBlendOperation = .add
            ed.colorAttachments[0].alphaBlendOperation = .add
            ed.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            ed.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            ed.colorAttachments[0].sourceAlphaBlendFactor = .one
            ed.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            ed.depthAttachmentPixelFormat = .depth32Float
            ed.rasterSampleCount = sc
            self.entityPipeline = try device.makeRenderPipelineState(descriptor: ed)

            // Billboard layout: float3 center @0, float4 (corner.xy, size) @16, float4 col @32.
            let bvd = MTLVertexDescriptor()
            bvd.attributes[0].format = .float3; bvd.attributes[0].offset = 0;  bvd.attributes[0].bufferIndex = 0
            bvd.attributes[1].format = .float4; bvd.attributes[1].offset = 16; bvd.attributes[1].bufferIndex = 0
            bvd.attributes[2].format = .float4; bvd.attributes[2].offset = 32; bvd.attributes[2].bufferIndex = 0
            bvd.layouts[0].stride = 48
            func bbPipeline(additive: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: "v_bb")
                d.fragmentFunction = lib.makeFunction(name: "f_bb")
                d.vertexDescriptor = bvd
                d.colorAttachments[0].pixelFormat = .rgba8Unorm
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].rgbBlendOperation = .add
                d.colorAttachments[0].alphaBlendOperation = .add
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                d.depthAttachmentPixelFormat = .depth32Float
                d.rasterSampleCount = sc
                return try device.makeRenderPipelineState(descriptor: d)
            }
            self.bbAddPipeline = try bbPipeline(additive: true)
            self.bbAlphaPipeline = try bbPipeline(additive: false)
        } catch { print("6DOF: pipeline build failed — \(error)"); return nil }

        let dsMesh = MTLDepthStencilDescriptor()
        dsMesh.depthCompareFunction = .less; dsMesh.isDepthWriteEnabled = true
        self.meshDepth = device.makeDepthStencilState(descriptor: dsMesh)!
        let dsSky = MTLDepthStencilDescriptor()
        dsSky.depthCompareFunction = .always; dsSky.isDepthWriteEnabled = false
        self.skyDepth = device.makeDepthStencilState(descriptor: dsSky)!
        let dsFx = MTLDepthStencilDescriptor()
        dsFx.depthCompareFunction = .less; dsFx.isDepthWriteEnabled = false  // occluded by world, won't occlude
        self.fxDepth = device.makeDepthStencilState(descriptor: dsFx)!
        var fxPool = [MTLBuffer]()
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: fxCapacityVerts * MemoryLayout<BillboardVertex>.stride,
                                            options: .storageModeShared) else { return nil }
            fxPool.append(b)
        }
        self.fxBufs = fxPool

        // Offscreen colour (shared so we can read it back headless) — the MSAA
        // pass resolves into this 1× texture. + depth (multisample to match).
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .shared
        guard let ct = device.makeTexture(descriptor: cdesc) else { return nil }
        self.colorTex = ct

        if sc > 1 {
            let mdesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            mdesc.textureType = .type2DMultisample
            mdesc.sampleCount = sc
            mdesc.usage = .renderTarget
            mdesc.storageMode = .private
            guard let mt = device.makeTexture(descriptor: mdesc) else { return nil }
            self.msaaColorTex = mt
        } else {
            self.msaaColorTex = nil
        }

        let ddesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        ddesc.usage = .renderTarget
        ddesc.storageMode = .private
        if sc > 1 { ddesc.textureType = .type2DMultisample; ddesc.sampleCount = sc }
        guard let dt = device.makeTexture(descriptor: ddesc) else { return nil }
        self.depthTex = dt

        // Index buffer — fixed grid topology, built once and reused as the patch
        // recenters (only the vertex positions/colours change).
        let n = patchCells
        var idx = [UInt32](); idx.reserveCapacity(n * n * 6)
        let row = UInt32(n + 1)
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt32(j) * row + UInt32(i)
                let b = a + 1, c = a + row, d = c + 1
                idx.append(contentsOf: [a, c, b,  b, c, d])
            }
        }
        self.indexCount = idx.count
        guard let ib = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride)
        else { return nil }
        self.ibuf = ib

        // Pool of vertex buffers (cycled so a build never overwrites the buffer
        // a frame is still reading). Fill the first with the start window.
        let vcap = (n + 1) * (n + 1) * MemoryLayout<MeshVertex>.stride
        var pool = [MTLBuffer]()
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: vcap, options: .storageModeShared) else { return nil }
            pool.append(b)
        }
        self.vbufs = pool
        let verts0 = MeshTerrainRenderer.buildVertices(terrain: terrain, patchN: n,
                                                       center: SIMD2<Int>(patchCenterX, patchCenterY), stride: 1)
        verts0.withUnsafeBytes { raw in pool[0].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) }

        // Per-kind craft meshes → GPU buffers (built once).
        let kinds: [(EnemyKind, Mesh)] = [(.fighter, .fighter()), (.destroyer, .destroyer()),
                                          (.drone, .drone()), (.mothership, .mothership())]
        for (kind, mesh) in kinds {
            if let eb = MeshTerrainRenderer.buildEntityBuffer(device: device, mesh: mesh) {
                entityBuffers[kind] = eb
            }
        }
    }

    /// Expand a Mesh into flat-shaded triangles (one face normal per triangle).
    private static func buildEntityBuffer(device: MTLDevice, mesh: Mesh) -> (buf: MTLBuffer, count: Int)? {
        let base = SIMD4<Float>(mesh.color.0 / 255, mesh.color.1 / 255, mesh.color.2 / 255, 1)
        var verts = [EntityVertex]()
        for f in mesh.faces {
            let a = SIMD3<Float>(mesh.verts[f.0].0, mesh.verts[f.0].1, mesh.verts[f.0].2)
            let b = SIMD3<Float>(mesh.verts[f.1].0, mesh.verts[f.1].1, mesh.verts[f.1].2)
            let c = SIMD3<Float>(mesh.verts[f.2].0, mesh.verts[f.2].1, mesh.verts[f.2].2)
            let n = simd_normalize(simd_cross(b - a, c - a))
            verts.append(EntityVertex(pos: a, normal: n, color: base))
            verts.append(EntityVertex(pos: b, normal: n, color: base))
            verts.append(EntityVertex(pos: c, normal: n, color: base))
        }
        guard let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<EntityVertex>.stride)
        else { return nil }
        return (buf, verts.count)
    }

    /// Sample a `patchN`-cell window of the (wrapping) heightmap around `center`
    /// at `stride` world units per cell, into world-space vertices. Larger stride
    /// → coarser mesh covering more ground (used at altitude). Static so it's safe
    /// to call off the main thread.
    private static func buildVertices(terrain: Terrain, patchN n: Int, center: SIMD2<Int>, stride: Int) -> [MeshVertex] {
        let x0 = center.x - (n / 2) * stride, y0 = center.y - (n / 2) * stride
        var verts = [MeshVertex](); verts.reserveCapacity((n + 1) * (n + 1))
        for j in 0...n {
            let wy = Float(y0 + j * stride)
            for i in 0...n {
                let wx = Float(x0 + i * stride)
                let h = terrain.heightF(wx, wy)
                let c = terrain.colorAt(wx, wy)
                let col = SIMD4<Float>(Float(c & 0xFF) / 255, Float((c >> 8) & 0xFF) / 255,
                                       Float((c >> 16) & 0xFF) / 255, 1)
                verts.append(MeshVertex(pos: SIMD3(wx, wy, h), color: col))
            }
        }
        return verts
    }

    /// Cell stride for a given height above the terrain — coarser (wider) the
    /// higher you climb, so the view reaches further without more vertices.
    private func strideForAltitude(_ pos: SIMD3<Float>) -> Int {
        let alt = pos.z - terrain.heightF(pos.x, pos.y)
        return max(1, min(4, 1 + Int(alt / 250)))
    }

    private func swapIn(_ verts: [MeshVertex], center: SIMD2<Int>, stride: Int) {
        let next = (activeVB + 1) % vbufs.count
        verts.withUnsafeBytes { raw in
            vbufs[next].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        activeVB = next; centerCell = center; cellStride = stride; building = false
    }

    /// Recenter (and re-LOD) the patch on the camera. Rebuilds when the camera
    /// drifts past `recenterStep` cells OR the altitude stride changes. Async by
    /// default; `sync: true` rebuilds inline (headless capture has no run loop to
    /// drain the main queue). Terrain wraps, so this never hits an edge.
    func recenterIfNeeded(around pos: SIMD3<Float>, sync: Bool = false) {
        if building { return }
        let stride = strideForAltitude(pos)
        // Quantise the centre to the stride grid so vertices don't shimmer as the
        // window slides at stride > 1.
        let q = Float(stride)
        let cell = SIMD2<Int>(Int((pos.x / q).rounded()) * stride, Int((pos.y / q).rounded()) * stride)
        let drift = max(abs(cell.x - centerCell.x), abs(cell.y - centerCell.y))
        // A forced rebuild (heightfield mutated under the patch) overrides the
        // drift/LOD short-circuit so a crumbling base shows up promptly.
        if !forceRebuild && stride == cellStride && drift < recenterStep * stride { return }
        forceRebuild = false
        building = true
        if sync {
            swapIn(MeshTerrainRenderer.buildVertices(terrain: terrain, patchN: patchN, center: cell, stride: stride),
                   center: cell, stride: stride)
            return
        }
        let n = patchN, terrain = self.terrain
        buildQueue.async { [weak self] in
            let verts = MeshTerrainRenderer.buildVertices(terrain: terrain, patchN: n, center: cell, stride: stride)
            DispatchQueue.main.async { self?.swapIn(verts, center: cell, stride: stride) }
        }
    }

    /// Encode one frame into `colorTex`. Returns the command buffer (caller may
    /// add a blit/present and commit, or commit + wait for headless readback).
    /// `entities` are craft to draw (kind + world transform), depth-tested.
    /// `fx` are camera-facing effect billboards (depth-tested, blended).
    func encode(camera: Camera6DOF,
                entities: [(kind: EnemyKind, model: simd_float4x4)] = [],
                fx: [Billboard] = []) -> MTLCommandBuffer? {
        let aspect = Float(width) / Float(height)
        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let vp = proj * view

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let msaa = msaaColorTex {
            pass.colorAttachments[0].texture = msaa            // render multisampled…
            pass.colorAttachments[0].resolveTexture = colorTex // …resolve into the 1× readback texture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = colorTex
            pass.colorAttachments[0].storeAction = .store
        }
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        // Sky first (fills the background; the horizon plane tilts with the camera).
        // Per-planet atmosphere: sky/haze hues from the terrain's theme, so each
        // world keeps its own look through the mesh renderer (Vulcan's ash, the
        // violet Vesper twilight, …). Below-horizon haze is the horizon hue
        // dimmed a touch, exactly as the old hardcoded blue was.
        let th = terrain.theme
        func themeC(_ c: (UInt8, UInt8, UInt8), _ s: Float = 1) -> SIMD4<Float> {
            SIMD4<Float>(Float(c.0) / 255 * s, Float(c.1) / 255 * s, Float(c.2) / 255 * s, 1)
        }
        var skyU = SkyUniforms(invViewProj: vp.inverse,
                               zenith: themeC(th.skyTop),
                               horizon: themeC(th.skyHaze),
                               ground: themeC(th.skyHaze, 0.82))
        enc.setRenderPipelineState(skyPipeline)
        enc.setDepthStencilState(skyDepth)
        enc.setFragmentBytes(&skyU, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Terrain (depth-tested).
        // Fog fades terrain into the horizon colour before the patch edge, so the
        // seam where the mesh stops is hidden (the sky uses the same horizon hue).
        //
        // Fog distance follows ALTITUDE continuously rather than jumping with the
        // discrete LOD stride (which doubles worldHalf at each step — a jarring
        // snap). Stride k+1 engages at alt = 250·k; fog starts there at the
        // previous stride's distance and ramps to the new stride's over the next
        // 150 units of climb, so the horizon recedes/advances smoothly. Clamped
        // to the LIVE patch's stride so the few frames where an async rebuild
        // lags the altitude can't push fog past the patch edge.
        let alt = camera.position.z - terrain.heightF(camera.position.x, camera.position.y)
        let band = min(3, max(0, Int(alt / 250)))
        let ramp: Float = band == 0 ? 1
            : Float(band) + min(1, max(0, (alt - Float(band) * 250) / 150))
        let strideF = min(Float(cellStride), ramp)
        let fogFar = Float(patchN / 2) * 0.82 * strideF
        fogFarDistance = fogFar
        let fogP = SIMD4<Float>(fogFar * 0.55, fogFar, 0, 0)
        var u = MeshUniforms(mvp: vp,
                             eye: SIMD4<Float>(camera.position, 1),
                             fogColor: themeC(th.skyHaze),
                             fogParams: fogP)
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(meshDepth)
        enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        enc.setVertexBuffer(vbufs[activeVB], offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                  indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)

        // Craft (depth-tested, lit, distance-faded).
        if !entities.isEmpty {
            var eu = EntityUniforms(vp: vp, model: matrix_identity_float4x4,
                                    eye: SIMD4<Float>(camera.position, 1),
                                    light: SIMD4<Float>(simd_normalize(SIMD3<Float>(-1, 0.35, 0.9)), 0),
                                    fog: fogP)
            enc.setRenderPipelineState(entityPipeline)
            enc.setDepthStencilState(meshDepth)
            for (kind, model) in entities {
                guard let eb = entityBuffers[kind] else { continue }
                eu.model = model
                enc.setVertexBytes(&eu, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                enc.setVertexBuffer(eb.buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: eb.count)
            }
        }

        // Effect billboards: additive (fire/bolts) then alpha (smoke); depth-tested
        // against the world but not writing depth, so they layer and don't occlude.
        if !fx.isEmpty {
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, -1), (1, 1), (-1, 1)]
            var verts = [BillboardVertex](); verts.reserveCapacity(fx.count * 6)
            func emit(_ b: Billboard) {
                for (cx, cy) in corners {
                    verts.append(BillboardVertex(center: b.center, cs: SIMD4(cx, cy, b.size, 0), color: b.color))
                }
            }
            for b in fx where b.additive { emit(b) }
            let addCount = verts.count
            for b in fx where !b.additive { emit(b) }
            let cap = fxCapacityVerts
            if verts.count > cap { verts.removeLast(verts.count - cap) }   // safety clamp
            if !verts.isEmpty {
                let buf = fxBufs[fxBufIndex]; fxBufIndex = (fxBufIndex + 1) % fxBufs.count
                verts.withUnsafeBytes { raw in buf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
                var bu = BillboardUniforms(vp: vp,
                                           camRight: SIMD4<Float>(camera.right, 0),
                                           camUp: SIMD4<Float>(camera.up, 0),
                                           eye: SIMD4<Float>(camera.position, 1),
                                           fog: fogP)
                enc.setDepthStencilState(fxDepth)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&bu, length: MemoryLayout<BillboardUniforms>.stride, index: 1)
                let addN = min(addCount, verts.count)
                if addN > 0 {
                    enc.setRenderPipelineState(bbAddPipeline)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: addN)
                }
                if verts.count > addN {
                    enc.setRenderPipelineState(bbAlphaPipeline)
                    enc.drawPrimitives(type: .triangle, vertexStart: addN, vertexCount: verts.count - addN)
                }
            }
        }
        enc.endEncoding()
        return cmd
    }

    /// Force the next `recenterIfNeeded` to rebuild the patch even if the camera
    /// hasn't drifted — call when the heightfield itself changed under the patch
    /// (a structure took damage / was destroyed and re-stamped the terrain).
    func markTerrainDirty() { forceRebuild = true }

    /// Swap the heightfield this renderer streams (a new planet on warp), reusing
    /// all pipelines/textures (no shader recompile). Rebuilds the active patch
    /// synchronously so the very next frame shows the new world. Use for loads /
    /// restarts (off the hot path); for warps, prefer stage/commit below.
    func setTerrain(_ t: Terrain, centerX: Int = 512, centerY: Int = 512) {
        terrain = t
        building = false; forceRebuild = false
        let center = SIMD2<Int>(centerX, centerY)
        swapIn(MeshTerrainRenderer.buildVertices(terrain: t, patchN: patchN, center: center, stride: 1),
               center: center, stride: 1)
    }

    private var stagedVerts: [MeshVertex]?
    private var stagedTerrain: Terrain?
    private var stagedCenter = SIMD2<Int>(512, 512)

    /// Build the patch for an upcoming terrain off the main thread (during the
    /// warp cut-scene, alongside the async planet gen) so the swap-in at
    /// `commitStagedTerrain` is instant — no hitch when the new world drops in.
    func stageTerrain(_ t: Terrain, centerX: Int = 512, centerY: Int = 512) {
        let center = SIMD2<Int>(centerX, centerY)
        let n = patchN
        buildQueue.async { [weak self] in
            let v = MeshTerrainRenderer.buildVertices(terrain: t, patchN: n, center: center, stride: 1)
            DispatchQueue.main.async {
                self?.stagedVerts = v; self?.stagedTerrain = t; self?.stagedCenter = center
            }
        }
    }

    /// Activate a previously `stageTerrain`'d patch instantly. If staging hasn't
    /// finished (rare), falls back to a synchronous build of `fallback` — unless
    /// `fallback` is already live (an earlier commit, e.g. at warp-descent start,
    /// makes the finalize-time call a no-op rather than a redundant sync rebuild).
    func commitStagedTerrain(fallback: Terrain, centerX: Int = 512, centerY: Int = 512) {
        if let v = stagedVerts, let st = stagedTerrain {
            terrain = st; building = false; forceRebuild = false
            swapIn(v, center: stagedCenter, stride: 1)
            stagedVerts = nil; stagedTerrain = nil
        } else if terrain !== fallback {
            setTerrain(fallback, centerX: centerX, centerY: centerY)
        }
    }

    /// Render one frame and copy the colour texture straight into a packed-RGBA
    /// `UInt32` framebuffer (the game's CPU framebuffer), so the existing 2D HUD /
    /// cockpit / cutscene draws can composite on top. The texture is `rgba8Unorm`
    /// (bytes R,G,B,A) which is bit-identical to the framebuffer's packed layout
    /// (R | G<<8 | B<<16), so the bytes drop in with no conversion.
    func renderInto(_ framebuffer: UnsafeMutablePointer<UInt32>, camera: Camera6DOF,
                    entities: [(kind: EnemyKind, model: simd_float4x4)] = [],
                    fx: [Billboard] = []) {
        guard let cmd = encode(camera: camera, entities: entities, fx: fx) else { return }
        cmd.commit(); cmd.waitUntilCompleted()
        framebuffer.withMemoryRebound(to: UInt8.self, capacity: width * height * 4) { bytes in
            colorTex.getBytes(bytes, bytesPerRow: width * 4,
                              from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
    }

    /// Render one frame and read the colour texture back as RGB bytes (headless).
    func renderToRGB(camera: Camera6DOF, entities: [(kind: EnemyKind, model: simd_float4x4)] = [],
                     fx: [Billboard] = []) -> [UInt8] {
        guard let cmd = encode(camera: camera, entities: entities, fx: fx) else { return [] }
        cmd.commit(); cmd.waitUntilCompleted()
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        colorTex.getBytes(&rgba, bytesPerRow: width * 4,
                          from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i*3+0] = rgba[i*4+0]; rgb[i*3+1] = rgba[i*4+1]; rgb[i*3+2] = rgba[i*4+2]
        }
        return rgb
    }
}
