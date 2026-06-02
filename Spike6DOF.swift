// Strataris — 6DOF renderer SPIKE (experimental branch exp/6dof).
//
// Proves the path from the upright Voxel-Space heightmap raycaster to a true
// 3-axis (loops + barrel rolls) renderer, WITHOUT touching the shipping engine:
//
//   • the heightmap (Terrain) is turned into a GPU triangle mesh,
//   • rendered through a real Metal 3D pipeline (view/projection matrices +
//     depth buffer) from a quaternion free camera — so arbitrary pitch/roll
//     (including inverted) "just works",
//   • into a 480×270 offscreen texture, preserving the lo-fi pixel look when it
//     is later upscaled with the existing nearest-neighbour blit,
//   • with a view-ray sky so the horizon tilts and inverts correctly, and one
//     depth-tested marker object to confirm sprite/depth integration.
//
// Entry: `STRATARIS_6DOF_PNG=1` renders a set of camera orientations (level,
// pitched, rolled, inverted) to /tmp PPMs for inspection — the spike's
// pass-criteria check. A windowed free-fly mode is layered on next.

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
    let colorTex: MTLTexture
    private let depthTex: MTLTexture

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
    // like the voxel renderer's per-cell shading rather than smooth-interpolated.
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
        // Hues come from the planet theme (matches the voxel sky gradient).
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
            self.meshPipeline = try device.makeRenderPipelineState(descriptor: md)

            let sd = MTLRenderPipelineDescriptor()
            sd.vertexFunction = lib.makeFunction(name: "v_sky")
            sd.fragmentFunction = lib.makeFunction(name: "f_sky")
            sd.colorAttachments[0].pixelFormat = .rgba8Unorm
            sd.depthAttachmentPixelFormat = .depth32Float
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

        // Offscreen colour (shared so we can read it back headless) + depth.
        let cdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        cdesc.usage = [.renderTarget, .shaderRead]
        cdesc.storageMode = .shared
        guard let ct = device.makeTexture(descriptor: cdesc) else { return nil }
        self.colorTex = ct

        let ddesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        ddesc.usage = .renderTarget
        ddesc.storageMode = .private
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
        pass.colorAttachments[0].texture = colorTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
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

// MARK: - Headless capture (STRATARIS_6DOF_PNG=1)

enum Spike6DOF {
    static func runHeadlessCapture() {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let device = MTLCreateSystemDefaultDevice() else { print("6DOF: no Metal device"); return }
        let w = RenderConfig.width, h = RenderConfig.height
        let terrain = Terrain(seed: Renderer6DOFSeed)
        guard let r = MeshTerrainRenderer(device: device, terrain: terrain, width: w, height: h) else {
            print("6DOF: renderer init failed"); return
        }
        let groundZ = terrain.heightF(512, 560)
        let eye = SIMD3<Float>(512, 560, groundZ + 90)

        // (label, pitch, roll) applied to the level forward heading.
        let shots: [(String, Float, Float)] = [
            ("level",     0,           0),
            ("pitchup",  -0.5,         0),       // nose up ~29°
            ("pitchdown", 0.5,         0),
            ("roll45",    0,           0.785),
            ("roll90",    0,           1.5708),
            ("inverted",  0,           3.1416),  // barrel-rolled belly-up
        ]
        for (name, pitch, roll) in shots {
            var cam = Camera6DOF.start(position: eye)
            cam.rotateBody(pitch: pitch, yaw: 0, roll: roll)
            let rgb = r.renderToRGB(camera: cam)
            writePPM(rgb, w: w, h: h, path: "/tmp/strataris_6dof_\(name).ppm")
        }

        // Restricted-envelope sanity: level horizon; a coordinated bank when
        // turning; pitch that clamps at the envelope limit (no looping).
        var rcLevel = Camera6DOF.start(position: eye)        // starts .restricted
        rcLevel.flyRestricted(turn: 0, pitchIn: 0, dt: 1.0 / 60)
        writePPM(r.renderToRGB(camera: rcLevel), w: w, h: h, path: "/tmp/strataris_6dof_restricted_level.ppm")

        var rcBank = Camera6DOF.start(position: eye)
        for _ in 0..<30 { rcBank.flyRestricted(turn: 1, pitchIn: 0, dt: 1.0 / 30) }   // bank into a turn
        writePPM(r.renderToRGB(camera: rcBank), w: w, h: h, path: "/tmp/strataris_6dof_restricted_bank.ppm")

        var rcPitch = Camera6DOF.start(position: eye)
        for _ in 0..<120 { rcPitch.flyRestricted(turn: 0, pitchIn: 1, dt: 1.0 / 30) } // hold nose-up → clamps
        writePPM(r.renderToRGB(camera: rcPitch), w: w, h: h, path: "/tmp/strataris_6dof_restricted_pitchclamp.ppm")

        // Streaming check: advance horizontally a long way (past the 4096 wrap),
        // holding altitude above the terrain and looking down for a vista, while
        // recentering the patch. Every frame should still have terrain that fades
        // into fog — no hard edge, since the heightmap tiles.
        var py: Float = 560
        for step in 0..<6 {
            py -= 950
            let gz = terrain.heightF(512, py)
            var fcam = Camera6DOF.start(position: SIMD3(512, py, gz + 110))
            fcam.rotateBody(pitch: -0.45, yaw: 0, roll: 0)    // ~26° nose-down
            r.recenterIfNeeded(around: fcam.position, sync: true)
            let rgb = r.renderToRGB(camera: fcam)
            writePPM(rgb, w: w, h: h, path: "/tmp/strataris_6dof_flight\(step).ppm")
        }

        // Altitude-LOD check: from way up, the stride widens so the patch reaches
        // much further than at ground level.
        let hz = terrain.heightF(512, 560) + 850
        var hcam = Camera6DOF.start(position: SIMD3(512, 560, hz))
        hcam.rotateBody(pitch: -0.6, yaw: 0, roll: 0)
        r.recenterIfNeeded(around: hcam.position, sync: true)
        writePPM(r.renderToRGB(camera: hcam), w: w, h: h, path: "/tmp/strataris_6dof_highalt.ppm")

        // Enemy craft: spawn a field and render the cluster, depth-tested.
        let field = EnemyField(terrain: terrain, around: 512, cy: 512)
        let ents = field.enemies.map { (kind: $0.kind, model: enemyModel($0, scale: field.scale(for: $0.kind))) }
        let egz = terrain.heightF(512, 360)
        var ecam = Camera6DOF.start(position: SIMD3(512, 360, egz + 70))
        ecam.rotateBody(pitch: -0.1, yaw: 0, roll: 0)
        r.recenterIfNeeded(around: ecam.position, sync: true)
        // Stand-in effects: an explosion (additive core + glow), smoke (alpha), a bolt.
        func gz(_ x: Float, _ y: Float, _ up: Float) -> SIMD3<Float> { SIMD3(x, y, terrain.heightF(x, y) + up) }
        let fxStand: [Billboard] = [
            Billboard(center: gz(512, 250, 60), size: 12, color: SIMD4(1.0, 0.78, 0.35, 1.0), additive: true),
            Billboard(center: gz(512, 250, 60), size: 20, color: SIMD4(1.0, 0.42, 0.14, 0.6), additive: true),
            Billboard(center: gz(540, 280, 52), size: 14, color: SIMD4(0.55, 0.55, 0.60, 0.6), additive: false),
            Billboard(center: gz(486, 290, 38), size: 5,  color: SIMD4(1.0, 1.0, 0.6, 1.0), additive: true),
        ]
        writePPM(r.renderToRGB(camera: ecam, entities: ents, fx: fxStand), w: w, h: h, path: "/tmp/strataris_6dof_enemies.ppm")

        // Structures: bases are stamped into the heightfield, so they must render
        // as raised, recoloured mesh with no extra geometry — and a destroyed base
        // must vanish once the patch is rebuilt (the markTerrainDirty path).
        let sterr = Terrain(seed: Renderer6DOFSeed)
        let bases = StructureField(terrain: sterr, around: 512, cy: 512, count: 5)
        if let sr = MeshTerrainRenderer(device: device, terrain: sterr, width: w, height: h),
           let b0 = bases.structures.first {
            let bz = sterr.heightF(b0.x, b0.y)
            let campos = SIMD3<Float>(b0.x + 40, b0.y + 170, bz + 80)
            let fwd = simd_normalize(SIMD3<Float>(b0.x, b0.y, bz + 10) - campos)
            let scam = Camera6DOF.start(forward: fwd, position: campos)
            sr.recenterIfNeeded(around: scam.position, sync: true)
            writePPM(sr.renderToRGB(camera: scam), w: w, h: h, path: "/tmp/strataris_6dof_structures.ppm")
            bases.destroy(0)                          // flatten it back to pristine ground
            sr.markTerrainDirty()
            sr.recenterIfNeeded(around: scam.position, sync: true)
            writePPM(sr.renderToRGB(camera: scam), w: w, h: h, path: "/tmp/strataris_6dof_structures_destroyed.ppm")
            print("6DOF: wrote structures + structures_destroyed PPMs (base 0 at \(Int(b0.x)),\(Int(b0.y)))")
        }

        // Rough timing (GPU fill is trivial at 480×270; this is a sanity floor).
        let t0 = CACurrentMediaTime()
        let frames = 120
        for i in 0..<frames {
            var cam = Camera6DOF.start(position: eye)
            cam.rotateBody(pitch: 0, yaw: Float(i) * 0.05, roll: 0)
            _ = r.renderToRGB(camera: cam)        // includes a CPU readback + wait each frame
        }
        let ms = (CACurrentMediaTime() - t0) * 1000 / Double(frames)
        print(String(format: "6DOF: wrote 6 orientation + 6 flight PPMs to /tmp; ~%.2f ms/frame incl. readback+wait", ms))
    }

    private static func writePPM(_ rgb: [UInt8], w: Int, h: Int, path: String) {
        var data = "P6\n\(w) \(h)\n255\n".data(using: .ascii)!
        data.append(contentsOf: rgb)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// Fixed seed for the spike scene (kept separate from the game's planet seeds).
let Renderer6DOFSeed: UInt32 = 7

// MARK: - Windowed free-fly mode (STRATARIS_6DOF=1)

#if canImport(AppKit)
import AppKit
import MetalKit
import Carbon.HIToolbox

/// Held-key state for the free-fly spike, integrated into the camera each frame.
private final class SpikeInput {
    var pitchUp = false, pitchDown = false
    var rollLeft = false, rollRight = false
    var yawLeft = false, yawRight = false
    var faster = false, slower = false
    var resetLevel = false
    var toggleMode = false

    func set(keyCode: Int, down: Bool) -> Bool {
        switch keyCode {
        case kVK_UpArrow:    pitchDown = down          // nose down (stick forward)
        case kVK_DownArrow:  pitchUp = down            // nose up   (stick back)
        case kVK_LeftArrow:  rollLeft = down
        case kVK_RightArrow: rollRight = down
        case kVK_ANSI_A:     yawLeft = down
        case kVK_ANSI_D:     yawRight = down
        case kVK_ANSI_W, kVK_ANSI_Equal: faster = down
        case kVK_ANSI_S, kVK_ANSI_Minus: slower = down
        case kVK_Space:      resetLevel = down
        case kVK_ANSI_T:     toggleMode = down         // restricted ↔ full (stand-in for L3 unlock)
        default: return false
        }
        return true
    }
}

/// MTKView that captures keys for the free-fly spike.
final class Spike6DOFView: MTKView {
    fileprivate let keys = SpikeInput()
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if !keys.set(keyCode: Int(e.keyCode), down: true)  { super.keyDown(with: e) } }
    override func keyUp(with e: NSEvent)   { if !keys.set(keyCode: Int(e.keyCode), down: false) { super.keyUp(with: e) } }
}

private let spikeBlitShader = """
#include <metal_stdlib>
using namespace metal;
struct VSOut { float4 position [[position]]; float2 uv; };
vertex VSOut v_blit(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
fragment float4 f_blit(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
"""

/// Drives the free-fly spike: integrates the quaternion camera from held keys
/// each frame, renders the mesh terrain to the offscreen texture, then upscales
/// it to the drawable with the same nearest-neighbour blit the game uses.
final class Spike6DOFController: NSObject, MTKViewDelegate {
    private let renderer: MeshTerrainRenderer
    private let terrain: Terrain
    private let enemies: EnemyField
    private var camera: Camera6DOF
    private weak var view: Spike6DOFView?
    private let blitQueue: MTLCommandQueue
    private var blitPipeline: MTLRenderPipelineState?
    private var lastTime: CFTimeInterval = 0
    private var speed: Float = 120
    private var modeLatch = false
    private var animTime: Float = 0

    init?(device: MTLDevice, view: Spike6DOFView) {
        self.terrain = Terrain(seed: Renderer6DOFSeed)
        guard let r = MeshTerrainRenderer(device: device, terrain: terrain,
                                          width: RenderConfig.width, height: RenderConfig.height),
              let q = device.makeCommandQueue() else { return nil }
        self.renderer = r
        self.blitQueue = q
        self.view = view
        self.enemies = EnemyField(terrain: terrain, around: 512, cy: 512)
        let g = terrain.heightF(512, 600)
        self.camera = Camera6DOF.start(position: SIMD3(512, 600, g + 90))
        super.init()
        if let lib = try? device.makeLibrary(source: spikeBlitShader, options: nil) {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "v_blit")
            d.fragmentFunction = lib.makeFunction(name: "f_blit")
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            blitPipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Looping stand-in explosions + smoke near the enemy cluster, so the
    /// billboard path is visible while flying (the spike has no Combat/Smoke).
    private func standInEffects() -> [Billboard] {
        func gz(_ x: Float, _ y: Float, _ up: Float) -> SIMD3<Float> { SIMD3(x, y, terrain.heightF(x, y) + up) }
        var fx = [Billboard]()
        let spots: [(Float, Float, Float)] = [(512, 460, 0), (470, 360, 0.9), (560, 300, 1.7)]
        for (x, y, off) in spots {
            let p = (animTime * 0.6 + off).truncatingRemainder(dividingBy: 1.0)   // 0..1 loop
            let a = 1 - p
            let size = 8 + p * 24
            fx.append(Billboard(center: gz(x, y, 55), size: size, color: SIMD4(1.0, 0.70, 0.28, a), additive: true))
            fx.append(Billboard(center: gz(x, y, 55), size: size * 1.4, color: SIMD4(1.0, 0.38, 0.12, a * 0.55), additive: true))
            fx.append(Billboard(center: gz(x + 6, y, 55 + p * 35), size: 12 + p * 16,
                                color: SIMD4(0.50, 0.50, 0.55, a * 0.5), additive: false))   // smoke
        }
        return fx
    }

    func draw(in mtkView: MTKView) {
        let now = CACurrentMediaTime()
        if lastTime == 0 { lastTime = now }
        let dt = Float(min(1.0 / 20.0, max(0.0, now - lastTime)))
        lastTime = now
        animTime += dt

        let k = (view?.keys) ?? SpikeInput()

        // T toggles the flight envelope (stands in for reaching the level-3 Axis
        // Unlock perk); reflect it in the window title.
        if k.toggleMode && !modeLatch {
            modeLatch = true
            camera.setMode(camera.mode == .restricted ? .full : .restricted)
            view?.window?.title = camera.mode == .restricted
                ? "Strataris — 6DOF (RESTRICTED envelope)"
                : "Strataris — 6DOF (FULL — Axis Unlock)"
        }
        if !k.toggleMode { modeLatch = false }

        let pitchIn = (k.pitchUp ? 1 : 0) - (k.pitchDown ? 1 : 0)
        let rollIn  = (k.rollRight ? 1 : 0) - (k.rollLeft ? 1 : 0)   // right-positive
        if camera.mode == .restricted {
            // Arrows bank-and-turn (L/R) and pitch (U/D), clamped envelope.
            camera.flyRestricted(turn: Float(-rollIn), pitchIn: Float(pitchIn), dt: dt)
        } else {
            // Full 6DOF: arrows roll/pitch, A/D yaw. Hands-off → ease back to level.
            let yaw = (k.yawLeft ? 1 : 0) - (k.yawRight ? 1 : 0)
            if pitchIn == 0 && rollIn == 0 && yaw == 0 {
                camera.autoLevelFull(dt: dt)
            } else {
                camera.flyFull(pitch: Float(pitchIn), yaw: Float(yaw), roll: Float(rollIn), dt: dt)
            }
            camera.bankToTurn(dt: dt)        // banking changes heading, like an aircraft
        }
        if k.resetLevel {                              // Space → recover to level flight
            camera.setMode(.restricted)
            camera.pitch = 0; camera.bank = 0
            camera.flyRestricted(turn: 0, pitchIn: 0, dt: dt)
            view?.window?.title = "Strataris — 6DOF (RESTRICTED envelope)"
        }

        if k.faster { speed = min(420, speed + 160 * dt) }
        if k.slower { speed = max(0, speed - 160 * dt) }
        camera.position += camera.forward * speed * dt

        // Ground collision: keep the ship above the terrain (no falling through).
        let floor = terrain.heightF(camera.position.x, camera.position.y) + 10
        if camera.position.z < floor { camera.position.z = floor }

        renderer.recenterIfNeeded(around: camera.position)

        let ents = enemies.enemies.map {
            (kind: $0.kind, model: enemyModel($0, scale: enemies.scale(for: $0.kind)))
        }
        guard let cmd = renderer.encode(camera: camera, entities: ents, fx: standInEffects()) else { return }
        if let drawable = mtkView.currentDrawable,
           let pass = mtkView.currentRenderPassDescriptor,
           let pipe = blitPipeline,
           let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(pipe)
            enc.setFragmentTexture(renderer.colorTex, index: 0)
            // Letterbox the fixed-aspect framebuffer into the drawable.
            let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
            if dw > 0, dh > 0 {
                let target = Double(RenderConfig.width) / Double(RenderConfig.height)
                var vw = dw, vh = dh, vx = 0.0, vy = 0.0
                if dw / dh > target { vw = dh * target; vx = (dw - vw) / 2 }
                else { vh = dw / target; vy = (dh - vh) / 2 }
                enc.setViewport(MTLViewport(originX: vx, originY: vy, width: vw, height: vh, znear: 0, zfar: 1))
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cmd.present(drawable)
        }
        cmd.commit()
    }
}
#endif
