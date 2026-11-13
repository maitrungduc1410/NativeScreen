import Foundation
import Metal
import CoreImage

/// GPU effects that CoreImage has no filter for: the magnifier lens (loupe zoom), camera motion blur and the click ripple.
/// The Metal source is compiled at launch with `makeLibrary(source:)`, so the build needs no Metal toolchain,
/// and each kernel runs inside a `CIImageProcessorKernel` so it slots into the CoreImage compositor graph.
///
/// See `spec/03-CINEMATIC-ENGINE-AND-MATH.md` (Pass 5) for the behavior both kernels implement.
public final class EffectKernels {
    public static let shared = EffectKernels()

    let lensPipeline: MTLComputePipelineState?
    let motionBlurPipeline: MTLComputePipelineState?
    let clickRipplePipeline: MTLComputePipelineState?
    let sampler: MTLSamplerState?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            lensPipeline = nil
            motionBlurPipeline = nil
            clickRipplePipeline = nil
            sampler = nil
            return
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        let library: MTLLibrary?
        do {
            library = try device.makeLibrary(source: Self.metalSource, options: options)
        } catch {
            NSLog("EffectKernels: shader compile failed: \(error)")
            library = nil
        }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library?.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        lensPipeline = pipeline("magnifierLens")
        motionBlurPipeline = pipeline("cameraMotionBlur")
        clickRipplePipeline = pipeline("clickRipple")

        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        desc.normalizedCoordinates = true
        sampler = device.makeSamplerState(descriptor: desc)
    }

    // MARK: - Magnifier lens

    /// Draws a round magnifying lens over `inputImage`: magnified content, a refracting rim with slight color fringing,
    /// a soft gloss and rim light, and a drop shadow on what is under the lens. `presence` fades the whole lens in and out.
    /// `centerPx` and `canvasRect` are in CoreImage coordinates (bottom-left origin).
    public static func applyMagnifierLens(
        to inputImage: CIImage,
        magnifiedContent: CIImage,
        canvasRect: CGRect,
        centerPx: CGPoint,
        radiusPx: CGFloat,
        zoomScale: CGFloat,
        rimRatio: CGFloat,
        colorFringe: CGFloat,
        presence: CGFloat
    ) -> CIImage {
        guard shared.lensPipeline != nil, presence > 0.005, radiusPx > 2.0, zoomScale > 1.001 else {
            return inputImage
        }
        let uniforms = LensUniforms(
            center: SIMD2(Float(centerPx.x - canvasRect.minX), Float(canvasRect.maxY - centerPx.y)),
            radius: Float(radiusPx),
            zoom: Float(zoomScale),
            rimRatio: Float(min(0.6, max(0.05, rimRatio))),
            fringe: Float(min(1.5, max(0.0, colorFringe))),
            presence: Float(min(1.0, presence))
        )
        return run(.lens, on: inputImage, canvasRect: canvasRect, uniforms: uniforms,
                   secondInput: magnifiedContent)
    }

    // MARK: - Click ripple

    /// One uniform per wave: center x, y in pixels, front radius in pixels, signed strength.
    fileprivate struct ClickRippleUniforms {
        var wave0: SIMD4<Float>
        var wave1: SIMD4<Float>
        var wave2: SIMD4<Float>
        var waveCount: Int32
        var bandWidth: Float
        var pull: Float
        var fringe: Float
        var coreRadius: Float
    }

    /// Bends the screen content around each click like a ring spreading through glass. Nothing is drawn on top:
    /// a band moves outward from the click, pushes pixels along its radius with a bounce that dies away, and splits
    /// color slightly where it bends. Lengths scale with the longer side of the screen rect.
    public static func applyClickRipple(
        to inputImage: CIImage,
        canvasRect canvas: CGRect,
        screenRect: CGRect,
        waves: [SpringTrajectorySolver.ClickWave]
    ) -> CIImage {
        guard shared.clickRipplePipeline != nil, !waves.isEmpty else { return inputImage }
        let reach = Float(max(screenRect.width, screenRect.height))

        func encoded(_ index: Int) -> SIMD4<Float> {
            guard index < waves.count else { return .zero }
            let wave = waves[index]
            let seconds = Float(wave.ageMs / 1000.0)
            let life = seconds / Float(SpringTrajectorySolver.clickWaveDurationMs / 1000.0)
            let fadeOut = 1.0 - min(1.0, max(0.0, (life - 0.7) / 0.3))
            let bounce = exp(-3.4 * seconds) * sin(8.8 * seconds) * fadeOut
            let x = screenRect.minX + CGFloat(wave.position01.x) * screenRect.width
            let y = screenRect.minY + CGFloat(1.0 - wave.position01.y) * screenRect.height
            return SIMD4(
                Float(x - canvas.minX),
                Float(canvas.maxY - y),
                reach * (0.012 + 0.24 * seconds),
                bounce
            )
        }

        let uniforms = ClickRippleUniforms(
            wave0: encoded(0),
            wave1: encoded(1),
            wave2: encoded(2),
            waveCount: Int32(min(waves.count, 3)),
            bandWidth: reach * 0.042,
            pull: reach * 0.013,
            fringe: reach * 0.0035,
            coreRadius: reach * 0.03
        )
        return run(.clickRipple, on: inputImage, canvasRect: canvas, uniforms: uniforms)
    }

    // MARK: - Camera motion blur

    /// Simulates a camera shutter while the zoom camera moves. `rectNow` is where the screen sits on the canvas in this
    /// frame and `rectPrevious` where it sat one frame earlier (CoreImage coordinates). The shutter stays open for
    /// `shutter` (0...1) of that frame interval, and every pixel averages what passed under it during that time.
    public static func applyCameraMotionBlur(
        to positionedScreen: CIImage,
        canvasRect: CGRect,
        rectNow: CGRect,
        rectPrevious: CGRect,
        shutter: CGFloat,
        isExportQuality: Bool
    ) -> CIImage {
        guard shared.motionBlurPipeline != nil, shutter > 0.01 else { return positionedScreen }

        // Where the screen was when the shutter opened. Less than half a pixel of travel everywhere: nothing to blur.
        let opened = CGRect(
            x: rectNow.minX + (rectPrevious.minX - rectNow.minX) * shutter,
            y: rectNow.minY + (rectPrevious.minY - rectNow.minY) * shutter,
            width: rectNow.width + (rectPrevious.width - rectNow.width) * shutter,
            height: rectNow.height + (rectPrevious.height - rectNow.height) * shutter
        )
        let travel = max(
            abs(opened.minX - rectNow.minX), abs(opened.maxX - rectNow.maxX),
            abs(opened.minY - rectNow.minY), abs(opened.maxY - rectNow.maxY)
        )
        guard travel >= 0.5 else { return positionedScreen }

        func topDown(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(
                Float(r.minX - canvasRect.minX),
                Float(canvasRect.maxY - r.maxY),
                Float(max(1.0, r.width)),
                Float(max(1.0, r.height))
            )
        }
        let uniforms = MotionBlurUniforms(
            rectNow: topDown(rectNow),
            rectPrevious: topDown(rectPrevious),
            shutter: Float(min(1.0, shutter)),
            pixelsPerSample: isExportQuality ? 3.0 : 10.0,
            maxSamples: isExportQuality ? 24 : 8
        )
        return run(.motionBlur, on: positionedScreen, canvasRect: canvasRect, uniforms: uniforms)
    }

    // MARK: - Dispatch

    fileprivate enum Kind: Int {
        case lens
        case motionBlur
        case clickRipple
    }

    fileprivate struct LensUniforms {
        var center: SIMD2<Float>
        var radius: Float
        var zoom: Float
        var rimRatio: Float
        var fringe: Float
        var presence: Float
    }

    fileprivate struct MotionBlurUniforms {
        var rectNow: SIMD4<Float>
        var rectPrevious: SIMD4<Float>
        var shutter: Float
        var pixelsPerSample: Float
        var maxSamples: Int32
    }

    private static func run<U>(_ kind: Kind, on image: CIImage, canvasRect: CGRect, uniforms: U,
                               secondInput: CIImage? = nil) -> CIImage {
        // Pad to the stride: Metal sizes the struct with its trailing padding.
        var bytes = withUnsafeBytes(of: uniforms) { Data($0) }
        bytes.append(Data(count: MemoryLayout<U>.stride - bytes.count))
        var args: [String: Any] = [
            EffectKernelProcessor.kindKey: kind.rawValue,
            EffectKernelProcessor.uniformsKey: bytes,
            EffectKernelProcessor.canvasKey: CIVector(cgRect: canvasRect)
        ]
        if let secondInput { args[EffectKernelProcessor.secondRectKey] = CIVector(cgRect: secondInput.extent) }
        guard let out = try? EffectKernelProcessor.apply(
            withExtent: canvasRect,
            inputs: [image.cropped(to: canvasRect)] + (secondInput.map { [$0] } ?? []),
            arguments: args
        ) else {
            return image
        }
        return out.cropped(to: canvasRect)
    }

    // MARK: - Metal source

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Textures are addressed top-down here (row 0 is the top of the canvas); the Swift side converts rects and points.

    struct LensUniforms {
        float2 center;
        float radius;
        float zoom;
        float rimRatio;
        float fringe;
        float presence;
    };

    struct MotionBlurUniforms {
        float4 rectNow;      // x, y, width, height in pixels
        float4 rectPrevious;
        float shutter;
        float pixelsPerSample;
        int maxSamples;
    };

    struct ClickRippleUniforms {
        float4 waves[3];     // center x, y in pixels, front radius in pixels, signed strength
        int waveCount;
        float bandWidth;
        float pull;
        float fringe;
        float coreRadius;
    };

    inline float4 sampleAt(texture2d<float, access::sample> tex, sampler s, float2 px, float2 size) {
        return tex.sample(s, px / size);
    }

    kernel void clickRipple(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        sampler smp [[sampler(0)]],
        constant ClickRippleUniforms &u [[buffer(0)]],
        constant float4 &regions [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

        // Under a zoom, CoreImage renders only the visible part, so textures are not the whole canvas.
        // Everything here is in canvas pixels; `regions` gives where each texture starts on the canvas.
        float2 srcSize = float2(src.get_width(), src.get_height());
        float2 px = float2(gid) + 0.5 + regions.xy;
        float2 displacement = float2(0.0);
        float2 split = float2(0.0);
        for (int i = 0; i < u.waveCount; i++) {
            float4 wave = u.waves[i];
            float2 offset = px - wave.xy;
            float dist = length(offset);
            float band = (dist - wave.z) / u.bandWidth;
            if (dist < 0.001 || abs(band) > 3.0) { continue; }
            float2 radial = offset / dist;
            float weight = exp(-band * band * 3.5) * smoothstep(0.0, u.coreRadius, dist);
            displacement += radial * wave.w * weight * u.pull;
            split += radial * abs(wave.w) * weight * (1.0 - weight) * 4.0 * u.fringe;
        }

        if (all(displacement == float2(0.0))) {
            dst.write(sampleAt(src, smp, px - regions.zw, srcSize), gid);
            return;
        }

        // Red and blue bend a little apart from green, only where the band is moving through.
        float2 at = px - displacement - regions.zw;
        float4 green = sampleAt(src, smp, at, srcSize);
        float4 red = sampleAt(src, smp, at - split, srcSize);
        float4 blue = sampleAt(src, smp, at + split, srcSize);
        dst.write(float4(red.r, green.g, blue.b, green.a), gid);
    }

    kernel void magnifierLens(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        texture2d<float, access::sample> content [[texture(2)]],
        sampler smp [[sampler(0)]],
        constant LensUniforms &u [[buffer(0)]],
        constant float4 &regions [[buffer(1)]],
        constant float2 &contentOrigin [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) { return; }

        float2 px = float2(gid) + 0.5 + regions.xy;
        float2 srcSize = float2(src.get_width(), src.get_height());
        float2 contentSize = float2(content.get_width(), content.get_height());
        float4 under = sampleAt(src, smp, px - regions.zw, srcSize);
        float2 offset = px - u.center;
        float dist = length(offset);
        float R = u.radius;

        // Drop shadow: a blurred disc a little below the lens, only visible outside the glass.
        float shadowSigma = R * 0.10;
        float shadowDist = length(offset - float2(0.0, R * 0.07)) - R * 0.98;
        float shadow = 0.30 * exp(-0.5 * pow(max(shadowDist, 0.0) / shadowSigma, 2.0));
        float coverage = clamp(R - dist + 0.5, 0.0, 1.0);
        float4 outside = float4(under.rgb * (1.0 - shadow * u.presence * (1.0 - coverage)), under.a);

        if (coverage <= 0.0) {
            dst.write(outside, gid);
            return;
        }

        // Lens body. r is 0 at the center and 1 at the edge; inside the rim band the glass bends outward,
        // so the edge shows content from further out (barrel-like) the way a thick convex lens does.
        float r = dist / R;
        float rimStart = 1.0 - u.rimRatio;
        float rim = smoothstep(rimStart, 1.0, r);
        float2 lensOffset = offset;
        float bend = 1.0 + 0.55 * rim * rim;

        // Color fringing grows toward the rim: red bends a bit less than blue.
        float spread = 0.045 * u.fringe * rim;
        float2 baseRel = lensOffset * bend;
        float4 g = sampleAt(content, smp, u.center + baseRel - contentOrigin, contentSize);
        float rr = sampleAt(content, smp, u.center + baseRel * (1.0 - spread) - contentOrigin, contentSize).r;
        float bb = sampleAt(content, smp, u.center + baseRel * (1.0 + spread) - contentOrigin, contentSize).b;
        float3 glass = float3(rr, g.g, bb);

        // Light comes from the top left.
        float2 dir = dist > 0.001 ? offset / dist : float2(0.0, -1.0);
        float2 toLight = normalize(float2(-0.45, -0.9));
        float facing = dot(dir, toLight); // 1 on the lit side of the rim, -1 opposite

        // Soft gloss over the upper half, fading out before the rim.
        float gloss = smoothstep(0.25, -0.85, offset.y / R) * (1.0 - smoothstep(0.55, 0.95, r)) * 0.07;
        glass += gloss;

        // The rim: slightly darker glass, a crisp highlight on the lit side and a faint one opposite.
        glass *= 1.0 - 0.10 * rim * (0.6 - 0.4 * facing);
        float edgePx = R - dist;
        float ringWidth = max(1.5, R * 0.018);
        float ring = exp(-edgePx / ringWidth);
        float highlight = ring * (0.55 * smoothstep(0.1, 0.9, facing) + 0.18 * smoothstep(0.3, 0.95, -facing));
        glass = glass + (1.0 - glass) * clamp(highlight, 0.0, 1.0);

        float mixAmount = coverage * u.presence;
        float4 result = float4(mix(outside.rgb, glass, mixAmount), mix(outside.a, max(g.a, under.a), mixAmount));
        dst.write(result, gid);
    }

    // Approximate display gamma; good enough to average light instead of encoded values.
    inline float4 toLinear(float4 c) {
        float a = c.a;
        if (a <= 0.0001) { return float4(0.0); }
        float3 straight = clamp(c.rgb / a, 0.0, 1.0);
        return float4(pow(straight, 2.2) * a, a);
    }

    inline float4 fromLinear(float4 c) {
        float a = c.a;
        if (a <= 0.0001) { return float4(0.0); }
        float3 straight = clamp(c.rgb / a, 0.0, 1.0);
        return float4(pow(straight, 1.0 / 2.2) * a, a);
    }

    // Per-pixel jitter so the finite samples read as grain instead of stepped copies.
    inline float pixelNoise(float2 px) {
        return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
    }

    // At time t (0 = previous frame, 1 = now) the screen sits at lerp(previous, now, t). Returns where the point of the
    // screen that was under `px` at time t is drawn in the current frame.
    inline float2 mapToNow(float2 px, float4 previous, float4 now, float t) {
        float4 r = mix(previous, now, t);
        float2 local = (px - r.xy) / r.zw;
        return now.xy + local * now.zw;
    }

    kernel void cameraMotionBlur(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        sampler smp [[sampler(0)]],
        constant MotionBlurUniforms &u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        float2 size = float2(dst.get_width(), dst.get_height());
        if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) { return; }
        float2 px = float2(gid) + 0.5;

        float2 opened = mapToNow(px, u.rectPrevious, u.rectNow, 1.0 - u.shutter);
        float travel = length(opened - px);
        if (travel < 0.5) {
            dst.write(sampleAt(src, smp, px, size), gid);
            return;
        }

        int count = clamp(int(ceil(travel / u.pixelsPerSample)), 2, max(2, u.maxSamples));
        float jitter = pixelNoise(px);
        float4 sum = float4(0.0);
        for (int i = 0; i < count; ++i) {
            float t = 1.0 - u.shutter * ((float(i) + jitter) / float(count));
            sum += toLinear(sampleAt(src, smp, mapToNow(px, u.rectPrevious, u.rectNow, t), size));
        }
        dst.write(fromLinear(sum / float(count)), gid);
    }
    """
}

/// Runs one of the `EffectKernels` compute pipelines on a CoreImage input.
private final class EffectKernelProcessor: CIImageProcessorKernel {
    static let kindKey = "kind"
    static let uniformsKey = "uniforms"
    static let canvasKey = "canvas"
    static let secondRectKey = "secondRect"

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        let kernels = EffectKernels.shared
        guard let input = inputs?.first,
              let inTexture = input.metalTexture,
              let outTexture = output.metalTexture,
              let commandBuffer = output.metalCommandBuffer,
              let rawKind = arguments?[kindKey] as? Int,
              let kind = EffectKernels.Kind(rawValue: rawKind),
              let uniforms = arguments?[uniformsKey] as? Data,
              let sampler = kernels.sampler else {
            return
        }
        let pipeline: MTLComputePipelineState?
        switch kind {
        case .lens: pipeline = kernels.lensPipeline
        case .motionBlur: pipeline = kernels.motionBlurPipeline
        case .clickRipple: pipeline = kernels.clickRipplePipeline
        }
        guard let pipeline, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inTexture, index: 0)
        encoder.setTexture(outTexture, index: 1)
        if kind == .lens, let content = inputs?.dropFirst().first, let texture = content.metalTexture {
            encoder.setTexture(texture, index: 2)
            let canvas = (arguments?[canvasKey] as? CIVector)?.cgRectValue ?? output.region
            var origin = SIMD2<Float>(Float(content.region.minX - canvas.minX), Float(canvas.maxY - content.region.maxY))
            encoder.setBytes(&origin, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
        }
        encoder.setSamplerState(sampler, index: 0)
        uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: uniforms.count, index: 0) }

        // Top-left of the output and input textures in top-down canvas pixels.
        let canvas = (arguments?[canvasKey] as? CIVector)?.cgRectValue ?? output.region
        var regions = SIMD4<Float>(
            Float(output.region.minX - canvas.minX),
            Float(canvas.maxY - output.region.maxY),
            Float(input.region.minX - canvas.minX),
            Float(canvas.maxY - input.region.maxY)
        )
        encoder.setBytes(&regions, length: MemoryLayout<SIMD4<Float>>.size, index: 1)

        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: outTexture.width, height: outTexture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// The kernels sample anywhere on the canvas (magnified, trailing or bent content), so they need the whole input.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        if input == 1, let rect = arguments?[secondRectKey] as? CIVector { return rect.cgRectValue }
        return (arguments?[canvasKey] as? CIVector)?.cgRectValue ?? outputRect
    }

    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at input: Int32) -> CIFormat { .BGRA8 }
    override class var synchronizeInputs: Bool { false }
}
