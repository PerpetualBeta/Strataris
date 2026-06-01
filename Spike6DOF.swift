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
    var position: SIMD3<Float>
    var orientation: simd_quatf
    var fovY: Float = 1.05            // ~60°
    var near: Float = 1
    var far: Float = 1600

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
    let patchHalf: Float                    // world half-extent (for fog tuning)
    private let recenterStep: Int           // rebuild once the camera drifts this many cells
    private let ibuf: MTLBuffer
    private let indexCount: Int
    private var vbufs: [MTLBuffer]          // pool, cycled so an in-flight frame isn't overwritten
    private var activeVB = 0
    private var centerCell: SIMD2<Int>
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
        float3 c = mix(in.color.rgb, u.fogColor.rgb, in.fogT);   // full fog at the patch edge
        return float4(c, 1.0);
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
        float3 ground  = float3(0.30, 0.32, 0.30);
        float3 c = t >= 0.0 ? mix(horizon, zenith, smoothstep(0.0, 0.55, t))
                            : mix(horizon, ground, smoothstep(0.0, -0.35, t));
        return float4(c, 1.0);
    }
    """

    init?(device: MTLDevice, terrain: Terrain, width: Int, height: Int,
          patchCells: Int = 640, patchCenterX: Int = 512, patchCenterY: Int = 512) {
        self.device = device
        self.width = width
        self.height = height
        self.terrain = terrain
        self.patchN = patchCells
        self.vertsPerSide = patchCells + 1
        self.patchHalf = Float(patchCells) / 2
        self.recenterStep = max(8, patchCells / 8)
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
                                                       center: SIMD2<Int>(patchCenterX, patchCenterY))
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
    /// into world-space vertices. Static so it's safe to call off the main thread.
    private static func buildVertices(terrain: Terrain, patchN n: Int, center: SIMD2<Int>) -> [MeshVertex] {
        let x0 = center.x - n / 2, y0 = center.y - n / 2
        var verts = [MeshVertex](); verts.reserveCapacity((n + 1) * (n + 1))
        for j in 0...n {
            let wy = Float(y0 + j)
            for i in 0...n {
                let wx = Float(x0 + i)
                let h = terrain.heightF(wx, wy)
                let c = terrain.colorAt(wx, wy)
                let col = SIMD4<Float>(Float(c & 0xFF) / 255, Float((c >> 8) & 0xFF) / 255,
                                       Float((c >> 16) & 0xFF) / 255, 1)
                verts.append(MeshVertex(pos: SIMD3(wx, wy, h), color: col))
            }
        }
        return verts
    }

    private func swapIn(_ verts: [MeshVertex], center: SIMD2<Int>) {
        let next = (activeVB + 1) % vbufs.count
        verts.withUnsafeBytes { raw in
            vbufs[next].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        activeVB = next; centerCell = center; building = false
    }

    /// Recenter the patch on the camera once it drifts past `recenterStep` cells.
    /// Async (default): rebuild on a background queue, swap on the main thread.
    /// `sync: true` rebuilds inline (headless capture has no run loop to drain
    /// the main queue). Terrain wraps, so this never hits an edge.
    func recenterIfNeeded(around pos: SIMD3<Float>, sync: Bool = false) {
        if building { return }
        let cell = SIMD2<Int>(Int(pos.x.rounded()), Int(pos.y.rounded()))
        if max(abs(cell.x - centerCell.x), abs(cell.y - centerCell.y)) < recenterStep { return }
        building = true
        if sync {
            swapIn(MeshTerrainRenderer.buildVertices(terrain: terrain, patchN: patchN, center: cell), center: cell)
            return
        }
        let n = patchN, terrain = self.terrain
        buildQueue.async { [weak self] in
            let verts = MeshTerrainRenderer.buildVertices(terrain: terrain, patchN: n, center: cell)
            DispatchQueue.main.async { self?.swapIn(verts, center: cell) }
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
                             fogParams: SIMD4<Float>(patchHalf * 0.55, patchHalf * 0.92, 0, 0))
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

    init?(device: MTLDevice, view: Spike6DOFView) {
        self.terrain = Terrain(seed: Renderer6DOFSeed)
        guard let r = MeshTerrainRenderer(device: device, terrain: terrain,
                                          width: RenderConfig.width, height: RenderConfig.height,
                                          patchCells: 512),
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
        let rate: Float = 1.9, yawRate: Float = 1.1
        let pitch = (k.pitchUp ? rate : 0) - (k.pitchDown ? rate : 0)
        let roll  = (k.rollRight ? rate : 0) - (k.rollLeft ? rate : 0)
        let yaw   = (k.yawLeft ? yawRate : 0) - (k.yawRight ? yawRate : 0)
        camera.rotateBody(pitch: pitch * dt, yaw: yaw * dt, roll: roll * dt)
        if k.resetLevel {
            camera = Camera6DOF.start(position: camera.position)   // snap upright
        }
        if k.faster { speed = min(420, speed + 160 * dt) }
        if k.slower { speed = max(0, speed - 160 * dt) }
        camera.position += camera.forward * speed * dt
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
