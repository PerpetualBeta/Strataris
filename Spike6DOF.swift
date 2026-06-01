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

    var forward: SIMD3<Float> { orientation.act(SIMD3(0, 0, -1)) }
    var up:      SIMD3<Float> { orientation.act(SIMD3(0, 1, 0)) }
    var right:   SIMD3<Float> { orientation.act(SIMD3(1, 0, 0)) }

    func viewMatrix() -> simd_float4x4 {
        let r = right, u = up, b = -forward          // camera local +Z points backward
        let m = simd_float4x4(columns: (
            SIMD4<Float>(r, 0), SIMD4<Float>(u, 0), SIMD4<Float>(b, 0), SIMD4<Float>(position, 1)))
        return m.inverse
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        perspectiveRH(fovY: fovY, aspect: aspect, near: near, far: far)
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
        bank += (turn * bankMax - bank) * min(1, dt * 8)        // wings level when not turning
        let qYaw   = simd_quatf(angle: heading, axis: SIMD3(0, 0, 1))   // world up = +Z
        let qPitch = simd_quatf(angle: pitch,   axis: SIMD3(1, 0, 0))   // body right
        let qBank  = simd_quatf(angle: bank,    axis: SIMD3(0, 0, -1))  // body forward
        orientation = qYaw * Camera6DOF.levelBase * qPitch * qBank
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
}

private struct MeshVertex {
    var pos: SIMD3<Float>          // stride 16 in Swift (pos at 0, colour at 16)
    var color: SIMD4<Float>
}

// MARK: - Mesh-terrain renderer

final class MeshTerrainRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let meshDepth: MTLDepthStencilState        // less + write
    private let skyDepth: MTLDepthStencilState         // always + no write

    let width: Int, height: Int
    let colorTex: MTLTexture
    private let depthTex: MTLTexture

    // Streaming terrain patch: a fixed-size grid that recenters on the camera as
    // it flies. The heightmap wraps (Terrain & mask), so re-sampling a moving
    // window gives seamless, edgeless terrain in every direction.
    private let terrain: Terrain
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
    private let buildQueue = DispatchQueue(label: "cc.jorviksoftware.strataris.meshbuild")

    private let markerVBuf: MTLBuffer
    private let markerIBuf: MTLBuffer
    private let markerIndexCount: Int

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

    // Full-screen sky: reconstruct the world-space view ray per pixel from the
    // inverse view-projection, then colour by the ray's world-up (z) component
    // so the horizon is a true world plane that tilts and inverts with the camera.
    struct SkyU { float4x4 invViewProj; };
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
        float3 zenith  = float3(0.16, 0.34, 0.62);
        float3 horizon = float3(0.62, 0.74, 0.86);
        float3 ground  = float3(0.50, 0.58, 0.66);   // hazy, not dark — blends with fog
        float3 c = t >= 0.0 ? mix(horizon, zenith, smoothstep(0.0, 0.55, t))
                            : mix(horizon, ground, smoothstep(0.0, -0.5, t));
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
        } catch { print("6DOF: pipeline build failed — \(error)"); return nil }

        let dsMesh = MTLDepthStencilDescriptor()
        dsMesh.depthCompareFunction = .less; dsMesh.isDepthWriteEnabled = true
        self.meshDepth = device.makeDepthStencilState(descriptor: dsMesh)!
        let dsSky = MTLDepthStencilDescriptor()
        dsSky.depthCompareFunction = .always; dsSky.isDepthWriteEnabled = false
        self.skyDepth = device.makeDepthStencilState(descriptor: dsSky)!

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

        // A single bright marker object (a small pyramid) sitting on the terrain,
        // to confirm depth occlusion against the hills in the same pass.
        let mx = Float(patchCenterX), my = Float(patchCenterY - 40)
        let mz = terrain.heightF(mx, my) + 6
        let s: Float = 16, hgt: Float = 34
        let apex = SIMD3<Float>(mx, my, mz + hgt)
        let base = [SIMD3<Float>(mx - s, my - s, mz), SIMD3<Float>(mx + s, my - s, mz),
                    SIMD3<Float>(mx + s, my + s, mz), SIMD3<Float>(mx - s, my + s, mz)]
        let mcol = SIMD4<Float>(1.0, 0.25, 0.2, 1)
        var mverts = [MeshVertex]()
        for k in 0..<4 {
            mverts.append(MeshVertex(pos: base[k], color: mcol))
            mverts.append(MeshVertex(pos: base[(k + 1) % 4], color: mcol))
            mverts.append(MeshVertex(pos: apex, color: SIMD4(1, 0.6, 0.3, 1)))
        }
        let micount = mverts.count
        var midx = [UInt32](0..<UInt32(micount))
        self.markerIndexCount = micount
        guard let mvb = device.makeBuffer(bytes: mverts, length: mverts.count * MemoryLayout<MeshVertex>.stride),
              let mib = device.makeBuffer(bytes: &midx, length: midx.count * MemoryLayout<UInt32>.stride)
        else { return nil }
        self.markerVBuf = mvb; self.markerIBuf = mib
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
        if stride == cellStride && drift < recenterStep * stride { return }
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
    func encode(camera: Camera6DOF) -> MTLCommandBuffer? {
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
        var skyU = SkyUniforms(invViewProj: vp.inverse)
        enc.setRenderPipelineState(skyPipeline)
        enc.setDepthStencilState(skyDepth)
        enc.setFragmentBytes(&skyU, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Terrain + marker (depth-tested).
        // Fog fades terrain into the horizon colour before the patch edge, so the
        // seam where the mesh stops is hidden (the sky uses the same horizon hue).
        var u = MeshUniforms(mvp: vp,
                             eye: SIMD4<Float>(camera.position, 1),
                             fogColor: SIMD4<Float>(0.62, 0.74, 0.86, 1),
                             fogParams: SIMD4<Float>(worldHalf * 0.45, worldHalf * 0.82, 0, 0))
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(meshDepth)
        enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        enc.setVertexBuffer(vbufs[activeVB], offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                  indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)
        enc.setVertexBuffer(markerVBuf, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: markerIndexCount,
                                  indexType: .uint32, indexBuffer: markerIBuf, indexBufferOffset: 0)
        enc.endEncoding()
        return cmd
    }

    /// Render one frame and read the colour texture back as RGB bytes (headless).
    func renderToRGB(camera: Camera6DOF) -> [UInt8] {
        guard let cmd = encode(camera: camera) else { return [] }
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
    private var camera: Camera6DOF
    private weak var view: Spike6DOFView?
    private let blitQueue: MTLCommandQueue
    private var blitPipeline: MTLRenderPipelineState?
    private var lastTime: CFTimeInterval = 0
    private var speed: Float = 120
    private var modeLatch = false

    init?(device: MTLDevice, view: Spike6DOFView) {
        self.terrain = Terrain(seed: Renderer6DOFSeed)
        guard let r = MeshTerrainRenderer(device: device, terrain: terrain,
                                          width: RenderConfig.width, height: RenderConfig.height),
              let q = device.makeCommandQueue() else { return nil }
        self.renderer = r
        self.blitQueue = q
        self.view = view
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

    func draw(in mtkView: MTKView) {
        let now = CACurrentMediaTime()
        if lastTime == 0 { lastTime = now }
        let dt = Float(min(1.0 / 20.0, max(0.0, now - lastTime)))
        lastTime = now

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
        // Left-positive so → keypress banks/rolls right (matches the keypress).
        let bankIn  = (k.rollLeft ? 1 : 0) - (k.rollRight ? 1 : 0)
        if camera.mode == .restricted {
            // Arrows bank-and-turn (L/R) and pitch (U/D), clamped envelope.
            camera.flyRestricted(turn: Float(bankIn), pitchIn: Float(pitchIn), dt: dt)
        } else {
            // Full 6DOF: arrows roll/pitch, A/D yaw. Hands-off → ease back to level.
            let yaw = (k.yawLeft ? 1 : 0) - (k.yawRight ? 1 : 0)
            if pitchIn == 0 && bankIn == 0 && yaw == 0 {
                camera.autoLevelFull(dt: dt)
            } else {
                camera.flyFull(pitch: Float(pitchIn), yaw: Float(yaw), roll: Float(bankIn), dt: dt)
            }
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

        guard let cmd = renderer.encode(camera: camera) else { return }
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
