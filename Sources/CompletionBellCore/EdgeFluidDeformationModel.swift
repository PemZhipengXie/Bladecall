import Foundation

public struct EdgePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct EdgeFluidDeformation: Equatable, Sendable {
    public let attractionStrength: Double
    public let bulgeDirectionX: Double
    public let bulgeDirectionY: Double
    public let bulgeAmplitude: Double
    public let bridgeNeckWidth: Double
    public let fusionProgress: Double
    public let needsAnimation: Bool

    public init(
        attractionStrength: Double,
        bulgeDirectionX: Double,
        bulgeDirectionY: Double,
        bulgeAmplitude: Double,
        bridgeNeckWidth: Double,
        fusionProgress: Double,
        needsAnimation: Bool
    ) {
        self.attractionStrength = attractionStrength
        self.bulgeDirectionX = bulgeDirectionX
        self.bulgeDirectionY = bulgeDirectionY
        self.bulgeAmplitude = bulgeAmplitude
        self.bridgeNeckWidth = bridgeNeckWidth
        self.fusionProgress = fusionProgress
        self.needsAnimation = needsAnimation
    }

    public static let zero = EdgeFluidDeformation(
        attractionStrength: 0,
        bulgeDirectionX: 0,
        bulgeDirectionY: 0,
        bulgeAmplitude: 0,
        bridgeNeckWidth: 0,
        fusionProgress: 0,
        needsAnimation: false
    )

    public func quantized() -> EdgeFluidDeformation {
        EdgeFluidDeformation(
            attractionStrength: Self.quantize(attractionStrength, step: 0.01),
            bulgeDirectionX: Self.quantize(bulgeDirectionX, step: 0.02),
            bulgeDirectionY: Self.quantize(bulgeDirectionY, step: 0.02),
            bulgeAmplitude: Self.quantize(bulgeAmplitude, step: 0.01),
            bridgeNeckWidth: Self.quantize(bridgeNeckWidth, step: 0.01),
            fusionProgress: Self.quantize(fusionProgress, step: 0.01),
            needsAnimation: needsAnimation
        )
    }

    private static func quantize(_ value: Double, step: Double) -> Double {
        let rounded = (value / step).rounded() * step
        if rounded == 0, value != 0 { return value > 0 ? step : -step }
        return rounded
    }
}

/// Pointer-driven liquid values. Targets are sampled at input cadence, while
/// every visible scalar follows a small damped spring so reversals preserve
/// momentum instead of restarting a duration-based easing curve.
public final class EdgeFluidDeformationModel {
    private let fusionInDuration: TimeInterval
    private let fusionOutDuration: TimeInterval
    private let bounce: Double
    private var expanded = false
    private var lastNow: Date
    private var transitionStartedAt: Date?
    private var transitionToExpanded = false
    private var attraction = SpringValue()
    private var amplitude = SpringValue()
    private var neck = SpringValue()
    private var fusion = SpringValue()

    public init(
        fusionInDuration: TimeInterval = 0.22,
        fusionOutDuration: TimeInterval = 0.13,
        bounce: Double = 0.20,
        now: Date = Date()
    ) {
        self.fusionInDuration = max(0.05, fusionInDuration)
        self.fusionOutDuration = max(0.05, fusionOutDuration)
        self.bounce = min(0.25, max(0.15, bounce))
        self.lastNow = now
    }

    public func update(
        pointer: EdgePoint?,
        tagRect: EdgeRect,
        proximityThreshold: Double,
        allowsMotion: Bool,
        isExpanded: Bool,
        at now: Date
    ) -> EdgeFluidDeformation {
        let effectiveNow = max(lastNow, now)
        let dt = min(0.05, max(0, effectiveNow.timeIntervalSince(lastNow)))
        lastNow = effectiveNow
        guard allowsMotion else {
            expanded = isExpanded
            attraction = SpringValue()
            amplitude = SpringValue()
            neck = SpringValue()
            fusion = SpringValue()
            return .zero
        }

        if isExpanded != expanded {
            expanded = isExpanded
            transitionStartedAt = effectiveNow
            transitionToExpanded = isExpanded
        }
        let proximity = pointerParameters(pointer: pointer, tagRect: tagRect, threshold: proximityThreshold)
        // Leaving the field sets the targets to zero; the springs must be
        // allowed to decay toward it. Snapping straight to .zero here would
        // discard their velocity and reintroduce the mechanical feel.
        if !expanded && proximity.strength == 0 && transitionStartedAt == nil
            && attraction.isSettled && amplitude.isSettled && neck.isSettled && fusion.isSettled {
            attraction = SpringValue()
            amplitude = SpringValue()
            neck = SpringValue()
            fusion = SpringValue()
            return .zero
        }
        let fusionTarget = max(proximity.fusion, expanded ? 1 : 0)
        let response = fusionTarget > fusion.value ? fusionInDuration : fusionOutDuration
        let fusionValue = fusion.step(toward: fusionTarget, dt: dt, duration: response, bounce: bounce)
        if let transitionStartedAt,
           effectiveNow.timeIntervalSince(transitionStartedAt) >= response {
            fusion.value = fusionTarget
            fusion.velocity = 0
            self.transitionStartedAt = nil
        }
        // Pointer-derived scalars are sampled targets, not the rendered values:
        // each rides its own spring so the shape carries momentum and a
        // reversal mid-flight keeps its velocity instead of restarting.
        let attractionValue = attraction.step(
            toward: proximity.strength,
            dt: dt,
            duration: proximity.strength > attraction.value ? fusionInDuration : fusionOutDuration,
            bounce: bounce
        )
        let rebound = !expanded && transitionToExpanded == false && transitionStartedAt != nil
            ? sin(min(1, effectiveNow.timeIntervalSince(transitionStartedAt!) / response) * .pi) * 0.12
            : 0
        let amplitudeTarget = max(proximity.amplitude, fusionValue * 0.34 + rebound)
        let amplitudeValue = amplitude.step(
            toward: amplitudeTarget,
            dt: dt,
            duration: amplitudeTarget > amplitude.value ? fusionInDuration : fusionOutDuration,
            bounce: bounce
        )
        let neckTarget = max(proximity.neck, fusionValue)
        let neckValue = neck.step(
            toward: neckTarget,
            dt: dt,
            duration: neckTarget > neck.value ? fusionInDuration : fusionOutDuration,
            bounce: bounce
        )
        let animating = fusion.isMoving(toward: fusionTarget)
            || attraction.isMoving(toward: proximity.strength)
            || amplitude.isMoving(toward: amplitudeTarget)
            || neck.isMoving(toward: neckTarget)
            || transitionStartedAt != nil
        if !animating && fusionValue < 0.0001 && attractionValue < 0.0001 && amplitudeValue < 0.0001 && neckValue < 0.0001 {
            return .zero
        }
        let direction = proximity.strength > 0 ? (proximity.directionX, proximity.directionY) : (-1.0, 0.0)
        return EdgeFluidDeformation(
            attractionStrength: attractionValue,
            bulgeDirectionX: direction.0,
            bulgeDirectionY: direction.1,
            bulgeAmplitude: min(1, max(0, amplitudeValue)),
            bridgeNeckWidth: min(1, max(0, neckValue)),
            fusionProgress: min(1, max(0, fusionValue)),
            needsAnimation: animating
        ).quantized()
    }

    private func pointerParameters(
        pointer: EdgePoint?,
        tagRect: EdgeRect,
        threshold: Double
    ) -> (strength: Double, directionX: Double, directionY: Double, amplitude: Double, neck: Double, fusion: Double) {
        guard let pointer, threshold > 0, tagRect.width > 0, tagRect.height > 0 else {
            return (0, 0, 0, 0, 0, 0)
        }
        let closestX = min(tagRect.maxX, max(tagRect.minX, pointer.x))
        let closestY = min(tagRect.maxY, max(tagRect.minY, pointer.y))
        let distance = hypot(pointer.x - closestX, pointer.y - closestY)
        guard distance < threshold else { return (0, 0, 0, 0, 0, 0) }
        let linear = min(1, max(0, 1 - distance / threshold))
        let strength = smoothstep(linear)
        let vectorX = pointer.x - (tagRect.minX + tagRect.width / 2)
        let vectorY = pointer.y - (tagRect.minY + tagRect.height / 2)
        let length = hypot(vectorX, vectorY)
        let directionX = length > 0.000001 ? vectorX / length : -1
        let directionY = length > 0.000001 ? vectorY / length : 0
        let neck = smoothstep(min(1, max(0, (strength - 0.22) / 0.78)))
        let fusion = smoothstep(min(1, max(0, (strength - 0.62) / 0.38)))
        return (strength, directionX, directionY, strength, neck, fusion)
    }

    private func smoothstep(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }
}

private struct SpringValue {
    var value = 0.0
    var velocity = 0.0

    /// At rest AND at zero — used to decide the shape may be dropped entirely.
    var isSettled: Bool { abs(value) < 0.002 && abs(velocity) < 0.004 }

    /// Still travelling toward its target. Distinct from `isSettled`: a spring
    /// parked at 1.0 is not settled but is not moving either, and must not keep
    /// the render timer alive.
    func isMoving(toward target: Double) -> Bool {
        abs(value - target) > 0.002 || abs(velocity) > 0.004
    }

    mutating func step(toward target: Double, dt: TimeInterval, duration: TimeInterval, bounce: Double) -> Double {
        guard dt > 0 else { return value }
        let stiffness = 16 / max(0.0025, duration * duration)
        let damping = 2 * sqrt(stiffness) * (1 - bounce * 0.45)
        let acceleration = (target - value) * stiffness - velocity * damping
        velocity += acceleration * dt
        value += velocity * dt
        if abs(value - target) < 0.002 && abs(velocity) < 0.004 {
            value = target
            velocity = 0
        }
        return value
    }
}
