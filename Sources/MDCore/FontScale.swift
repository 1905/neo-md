/// Text size steps shared by the preview and the editor. A step index maps to a size factor.
public enum FontScale {
    /// Valid step indexes. Step 0 is the default size.
    public static let steps: ClosedRange<Int> = -3...5

    private static let factors: [Double] = [0.75, 0.85, 0.92, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8]

    /// The size factor for `step`. Out-of-range steps clamp to the nearest limit.
    public static func factor(step: Int) -> Double {
        factors[clamp(step) - steps.lowerBound]
    }

    /// `step` limited to `steps`.
    public static func clamp(_ step: Int) -> Int {
        min(max(step, steps.lowerBound), steps.upperBound)
    }
}
