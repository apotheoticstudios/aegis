import SceneKit

/// The reactor's scene and animation, ported from the prototype's three.js scene and tick loop (#292). SceneKit calls
/// `renderer(_:updateAtTime:)` on its render thread; `mode` is the only state shared with the main thread.
final class ReactorScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    var mode: ReactorView.Mode {
        get { lock.withLock { wanted } }
        set { lock.withLock { wanted = newValue } }
    }

    private let lock = NSLock()
    private var wanted = ReactorView.Mode.idle

    // Render-thread state.
    private var tuning = Tuning(.idle)
    private var palette = Palette.cyan
    private var last: TimeInterval?
    private var clock: Float = 0
    private let root = SCNNode()
    private let shell = SCNNode()
    private let bandSpin = SCNNode()
    private let core = SCNNode()
    private let glow = SCNNode()
    private var arcs: [(node: SCNNode, speed: Float)] = []
    private let points = SCNMaterial()
    private let lines = ReactorScene.additive(opacity: 0.4)
    private let hotLines = ReactorScene.additive(opacity: 0.6)
    private let faceLines = ReactorScene.additive(opacity: 0.25)
    private let glowMaterial = ReactorScene.additive(opacity: 1)
    private let haloMaterial = ReactorScene.additive(opacity: 0.2)

    override init() {
        super.init()
        var random = SeededRandom()
        points.lightingModel = .constant
        points.blendMode = .add
        points.writesToDepthBuffer = false
        points.isDoubleSided = true
        points.shaderModifiers = [.fragment: Self.twinkle]
        scene.rootNode.addChildNode(root)
        for node in [shell, core] {
            root.addChildNode(node)
        }
        shell.addChildNode(SCNNode(geometry: shellPoints(&random)))
        shell.addChildNode(SCNNode(geometry: shards(&random)))
        let band = SCNNode()
        band.eulerAngles = SCNVector3(1.18, 0, 0.42)
        root.addChildNode(band)
        band.addChildNode(bandSpin)
        bandSpin.addChildNode(SCNNode(geometry: bandPoints(&random)))
        bandSpin.addChildNode(SCNNode(geometry: bandTicks(&random)))
        addArcs()
        core.addChildNode(SCNNode(geometry: corePoints(&random)))
        core.eulerAngles = SCNVector3(0.5, 0, -0.3)
        addSprites()
        addFace()
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.1
        camera.zFar = 50
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomThreshold = 0.35
        camera.bloomBlurRadius = 8
        camera.bloomIntensity = 0.7
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 4.45)
        scene.rootNode.addChildNode(cameraNode)
        apply(palette)
    }

    // MARK: - Animation (the prototype's tick)

    func renderer(_: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let step = Float(min(time - (last ?? time), 0.05))
        last = time
        let mode = mode
        let ease = min(1, step * 3)
        tuning.approach(Tuning(mode), ease)
        let colours: Palette = mode == .listening ? .amber : .cyan
        if palette != colours {
            palette.approach(colours, ease)
            apply(palette)
        }
        clock += step
        let spin = CGFloat(step * tuning.speed)
        // Speaking pulses the core and breathes the shell like a voice.
        let voice: Float = mode == .speaking
            ? abs(sin(clock * 7.3) * sin(clock * 2.1 + 0.6)) * (0.6 + 0.4 * sin(clock * 13)) : 0
        let breath = CGFloat(1 + (0.012 * sin(clock * 1.4) + voice * 0.045) * 0.7)
        shell.eulerAngles.y += spin * 0.12
        shell.eulerAngles.x += spin * 0.02
        shell.scale = SCNVector3(breath, breath, breath)
        bandSpin.eulerAngles.y -= spin * 0.22
        core.eulerAngles.y += spin * 0.9
        for arc in arcs {
            arc.node.eulerAngles.z += spin * CGFloat(arc.speed * 0.35 * tuning.arc)
        }
        let size = CGFloat(0.65 * tuning.glow * (1 + voice * 0.6) * (1 + 0.04 * sin(clock * 3.1)))
        glow.scale = SCNVector3(size, size, 1)
        root.eulerAngles = SCNVector3(0.18, CGFloat(sin(clock * 0.15) * 0.25), 0)
        cameraNode.camera?.bloomIntensity = CGFloat(tuning.bloom + voice * 0.5)
        points.setValue(NSNumber(value: tuning.flicker), forKey: "flicker")
    }

    private func apply(_ palette: Palette) {
        points.setValue(NSValue(scnVector3: palette.hot.vector), forKey: "hotColor")
        points.setValue(NSValue(scnVector3: palette.mid.vector), forKey: "midColor")
        points.setValue(NSValue(scnVector3: palette.deep.vector), forKey: "deepColor")
        lines.diffuse.contents = palette.mid.color
        faceLines.diffuse.contents = palette.mid.color
        hotLines.diffuse.contents = palette.hot.color
        glowMaterial.multiply.contents = palette.hot.color
        haloMaterial.multiply.contents = palette.deep.color
    }

    /// Each point's colour runs from deep through mid to hot by its heat, and it twinkles at its own pace.
    private static let twinkle = """
    #pragma arguments
    float3 hotColor;
    float3 midColor;
    float3 deepColor;
    float flicker;
    #pragma body
    float heat = _surface.diffuse.r;
    float seed = _surface.diffuse.g;
    float wave = 0.5 + 0.5 * sin(scn_frame.time * (0.5 + seed * 2.0) + seed * 80.0);
    float level = mix(1.0, wave * wave * 1.6, flicker);
    float3 tint = mix(deepColor, midColor, clamp(heat * 1.7, 0.0, 1.0));
    tint = mix(tint, hotColor, clamp(heat * 2.0 - 1.0, 0.0, 1.0));
    _output.color = float4(tint * level * 0.7, 1.0);
    """
}

// MARK: - Geometry (the prototype's builders, same counts at its small-screen quality)

private extension ReactorScene {
    static let quality: Float = 0.4

    static func additive(opacity: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        material.transparency = opacity
        return material
    }

    func shellPoints(_ random: inout SeededRandom) -> SCNGeometry {
        var cloud = PointCloud()
        for _ in 0 ..< Int(1100 * Self.quality) {
            let normal = random.direction()
            let along = random.tangent(normal)
            let radius = random.next() < 0.88 ? 0.97 + random.next() * 0.1 : 1.08 + random.next() * 0.22
            let length = 0.02 + random.next() * 0.11
            let count = 5 + Int(random.next() * 12)
            let heat = random.next() < 0.12 ? 0.75 + random.next() * 0.25 : 0.25 + random.next() * 0.4
            for index in 0 ..< count {
                let offset = (Float(index) / Float(count) - 0.5) * length
                let jitter = SIMD3(random.gauss(), random.gauss(), random.gauss()) * 0.004
                cloud.add(
                    normal * radius + along * offset + jitter,
                    size: 0.8 + random.next() * 1.8,
                    heat: heat * (0.8 + random.next() * 0.4),
                    seed: random.next()
                )
            }
        }
        return cloud.geometry(points)
    }

    func shards(_ random: inout SeededRandom) -> SCNGeometry {
        var ends: [SIMD3<Float>] = []
        for _ in 0 ..< Int(1700 * Self.quality) {
            let normal = random.direction()
            let start = normal * (0.92 + random.next() * 0.24)
            let along = random.next() < 0.3 ? normal : random.tangent(normal)
            ends += [start, start + along * (0.02 + random.next() * 0.08)]
        }
        return Self.segments(ends, lines)
    }

    func bandPoints(_ random: inout SeededRandom) -> SCNGeometry {
        var cloud = PointCloud()
        for _ in 0 ..< Int(9000 * Self.quality) {
            let angle = random.next() * 2 * .pi
            // Gaps in the band, as in the prototype.
            guard sin(angle * 7) + sin(angle * 13 + 1.3) + 0.6 * sin(angle * 29) >= -0.7 else { continue }
            let radius = 1 + abs(random.gauss()) * 0.07 * (random.next() < 0.2 ? 2.4 : 1)
            let point = SIMD3(cos(angle) * radius, random.gauss() * 0.028, sin(angle) * radius)
            cloud.add(point, size: 0.9 + random.next() * 2, heat: 0.45 + random.next() * 0.5, seed: random.next())
        }
        return cloud.geometry(points)
    }

    func bandTicks(_ random: inout SeededRandom) -> SCNGeometry {
        var ends: [SIMD3<Float>] = []
        for _ in 0 ..< Int(420 * Self.quality) {
            let angle = random.next() * 2 * .pi
            let inner = 0.96 + random.next() * 0.05
            let outer = inner + 0.04 + random.next() * 0.16
            ends += [
                SIMD3(cos(angle) * inner, 0, sin(angle) * inner),
                SIMD3(cos(angle) * outer, (random.next() - 0.5) * 0.02, sin(angle) * outer),
            ]
        }
        return Self.segments(ends, lines)
    }

    func corePoints(_ random: inout SeededRandom) -> SCNGeometry {
        var cloud = PointCloud()
        for _ in 0 ..< Int(2600 * Self.quality) {
            cloud.add(
                random.direction() * (abs(random.gauss()) * 0.09 + 0.02),
                size: 1.2 + random.next() * 2.4,
                heat: 0.85 + random.next() * 0.15,
                seed: random.next()
            )
        }
        for arm in 0 ..< 4 {
            for _ in 0 ..< Int(500 * Self.quality) {
                let along = random.next()
                let angle = along * 7 + Float(arm) * 1.57
                let radius = 0.06 + along * 0.42
                let jitter = SIMD3(random.gauss(), random.gauss(), random.gauss()) * 0.012
                let point = SIMD3(cos(angle) * radius, sin(along * 9 + Float(arm)) * 0.06, sin(angle) * radius) + jitter
                cloud.add(point, size: 0.8 + random.next() * 1.6, heat: 0.9 - along * 0.5, seed: random.next())
            }
        }
        return cloud.geometry(points)
    }

    /// Six partial rings at odd angles, each turning at its own speed.
    func addArcs() {
        let arcs = [
            Arc(radius: 0.62, length: 2.3, hot: true, tilt: SCNVector3(0.2, 0.9, 0.1), speed: 0.5),
            Arc(radius: 0.7, length: 1.4, hot: false, tilt: SCNVector3(1.2, 0.3, 0.6), speed: -0.8),
            Arc(radius: 0.52, length: 3.4, hot: false, tilt: SCNVector3(-0.6, 1.4, 0.2), speed: 1.1),
            Arc(radius: 0.82, length: 2.0, hot: false, tilt: SCNVector3(0.4, -0.7, 1.1), speed: -0.4),
            Arc(radius: 0.36, length: 4.2, hot: true, tilt: SCNVector3(1.5, 0.2, -0.4), speed: 1.6),
            Arc(radius: 0.9, length: 1.1, hot: false, tilt: SCNVector3(-1.1, 0.5, 0.9), speed: 0.7),
        ]
        for arc in arcs {
            let holder = SCNNode()
            holder.eulerAngles = arc.tilt
            let steps = 90
            var ends: [SIMD3<Float>] = []
            for step in 0 ..< steps {
                let from = arc.length * Float(step) / Float(steps)
                let to = arc.length * Float(step + 1) / Float(steps)
                ends += [SIMD3(cos(from) * arc.radius, sin(from) * arc.radius, 0), SIMD3(cos(to) * arc.radius, sin(to) * arc.radius, 0)]
            }
            let node = SCNNode(geometry: Self.segments(ends, arc.hot ? hotLines : lines))
            holder.addChildNode(node)
            root.addChildNode(holder)
            self.arcs.append((node, arc.speed))
        }
    }

    /// The hot centre and its wide halo, always facing the camera.
    func addSprites() {
        for (node, material, size) in [(glow, glowMaterial, CGFloat(1)), (SCNNode(), haloMaterial, CGFloat(3.4))] {
            let plane = SCNPlane(width: size, height: size)
            material.diffuse.contents = Self.softDot
            plane.materials = [material]
            node.geometry = plane
            node.constraints = [SCNBillboardConstraint()]
            root.addChildNode(node)
        }
    }

    /// A ring of ticks and a broken outer ring, flat to the viewer like a watch face.
    func addFace() {
        let face = SCNNode()
        face.constraints = [SCNBillboardConstraint()]
        var ends: [SIMD3<Float>] = []
        for index in 0 ..< 240 {
            let angle = Float(index) / 240 * 2 * .pi
            guard sin(angle * 3 + 0.7) <= 0.82 else { continue }
            let length: Float = index % 10 == 0 ? 0.07 : index % 2 == 0 ? 0.035 : 0.02
            ends += [SIMD3(cos(angle) * 1.34, sin(angle) * 1.34, 0), SIMD3(cos(angle) * (1.34 + length), sin(angle) * (1.34 + length), 0)]
        }
        for step in 0 ..< 120 {
            let from = 0.3 + 4.6 * Float(step) / 120
            let to = 0.3 + 4.6 * Float(step + 1) / 120
            ends += [SIMD3(cos(from) * 1.46, sin(from) * 1.46, 0), SIMD3(cos(to) * 1.46, sin(to) * 1.46, 0)]
        }
        face.geometry = Self.segments(ends, faceLines)
        root.addChildNode(face)
    }

    static func segments(_ ends: [SIMD3<Float>], _ material: SCNMaterial) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: ends.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: Array(0 ..< Int32(ends.count)), primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    /// A white dot that fades to nothing, for the glow sprites.
    static let softDot: CGImage? = {
        let side = 128
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 0.55),
                CGColor(gray: 1, alpha: 0.12),
                CGColor(gray: 1, alpha: 0),
            ] as CFArray,
            locations: [0, 0.18, 0.5, 1]
        ) else { return nil }
        let center = CGPoint(x: side / 2, y: side / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: CGFloat(side / 2),
            options: []
        )
        return context.makeImage()
    }()
}

/// Points in three sizes; each point's colour carries its heat (red) and twinkle seed (green) for the shader.
private struct PointCloud {
    private var positions: [SCNVector3] = []
    private var tags: [SIMD4<Float>] = []
    private var sizes: [Float] = []

    mutating func add(_ point: SIMD3<Float>, size: Float, heat: Float, seed: Float) {
        positions.append(SCNVector3(point.x, point.y, point.z))
        tags.append(SIMD4(heat, seed, 0, 1))
        sizes.append(size)
    }

    func geometry(_ material: SCNMaterial) -> SCNGeometry {
        let colours = SCNGeometrySource(
            data: tags.withUnsafeBytes { Data($0) }, semantic: .color, vectorCount: tags.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        // The prototype sizes points per vertex; SceneKit sizes per element, so they go in three buckets.
        let elements = [(0 as Float, 1.6 as Float, 0.008), (1.6, 2.4, 0.013), (2.4, 9, 0.019)].map { low, high, scale in
            let indices = sizes.indices.filter { sizes[$0] >= low && sizes[$0] < high }.map { Int32($0) }
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = scale
            element.minimumPointScreenSpaceRadius = 0.5
            element.maximumPointScreenSpaceRadius = 4
            return element
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), colours], elements: elements)
        geometry.materials = [material]
        return geometry
    }
}

/// One of the orbiting partial rings: its size, how far round it goes, its tilt and its turning speed.
private struct Arc {
    let radius: Float
    let length: Float
    let hot: Bool
    let tilt: SCNVector3
    let speed: Float
}

/// The prototype's per-state settings, eased towards each frame.
private struct Tuning {
    var speed: Float, flicker: Float, arc: Float, glow: Float, bloom: Float

    init(_ mode: ReactorView.Mode) {
        switch mode {
        case .thinking: (speed, flicker, arc, glow, bloom) = (1.8, 0.8, 2.4, 1.0, 0.9)
        case .speaking: (speed, flicker, arc, glow, bloom) = (1.0, 0.6, 1.2, 1.1, 0.9)
        case .idle, .listening: (speed, flicker, arc, glow, bloom) = (0.6, 0.45, 0.6, 0.8, 0.7)
        }
    }

    mutating func approach(_ target: Tuning, _ ease: Float) {
        speed += (target.speed - speed) * ease
        flicker += (target.flicker - flicker) * ease
        arc += (target.arc - arc) * ease
        glow += (target.glow - glow) * ease
        bloom += (target.bloom - bloom) * ease
    }
}

/// Hot, mid and deep colours: cyan normally, amber while listening.
private struct Palette: Equatable {
    var hot: SIMD3<Float>, mid: SIMD3<Float>, deep: SIMD3<Float>

    static let cyan = Palette(hot: SIMD3(0.886, 0.988, 1), mid: SIMD3(0.31, 0.82, 0.91), deep: SIMD3(0.059, 0.353, 0.439))
    static let amber = Palette(hot: SIMD3(1, 0.902, 0.69), mid: SIMD3(1, 0.604, 0.18), deep: SIMD3(0.659, 0.267, 0.047))

    mutating func approach(_ target: Palette, _ ease: Float) {
        hot += (target.hot - hot) * ease
        mid += (target.mid - mid) * ease
        deep += (target.deep - deep) * ease
        // Snap once close, so recolouring stops.
        if simd_distance(hot, target.hot) + simd_distance(mid, target.mid) + simd_distance(deep, target.deep) < 0.003 {
            self = target
        }
    }
}

private extension SIMD3<Float> {
    var vector: SCNVector3 {
        SCNVector3(x, y, z)
    }

    var color: NSColor {
        NSColor(red: CGFloat(x), green: CGFloat(y), blue: CGFloat(z), alpha: 1)
    }
}

/// The same reactor every launch: a fixed-seed SplitMix64.
private struct SeededRandom {
    private var state: UInt64 = 0x5EED_1A12_C0DE

    /// 0 ..< 1.
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((mixed ^ (mixed >> 31)) >> 40) / Float(1 << 24)
    }

    mutating func gauss() -> Float {
        let first = max(next(), .leastNonzeroMagnitude)
        return sqrt(-2 * log(first)) * cos(2 * .pi * next())
    }

    /// A random direction on the unit sphere.
    mutating func direction() -> SIMD3<Float> {
        let height = next() * 2 - 1
        let angle = next() * 2 * .pi
        let ring = sqrt(1 - height * height)
        return SIMD3(ring * cos(angle), height, ring * sin(angle))
    }

    /// A random unit vector at right angles to `normal`.
    mutating func tangent(_ normal: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let first = simd_normalize(simd_cross(normal, axis))
        let second = simd_cross(normal, first)
        let angle = next() * 2 * .pi
        return first * cos(angle) + second * sin(angle)
    }
}
