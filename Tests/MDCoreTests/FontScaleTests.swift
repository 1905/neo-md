import Testing
@testable import MDCore

@Test func fontScaleStepZeroIsOne() {
    #expect(FontScale.factor(step: 0) == 1.0)
}

@Test func fontScaleLimits() {
    #expect(FontScale.steps == -3...5)
    #expect(FontScale.clamp(6) == 5)
    #expect(FontScale.clamp(-4) == -3)
    #expect(FontScale.clamp(2) == 2)
    #expect(FontScale.factor(step: 6) == 1.8)
    #expect(FontScale.factor(step: -9) == 0.75)
}

@Test func fontScaleFactorTable() {
    let table: [Int: Double] = [-3: 0.75, -2: 0.85, -1: 0.92, 0: 1.0, 1: 1.1, 2: 1.25, 3: 1.4, 4: 1.6, 5: 1.8]
    for step in FontScale.steps {
        #expect(FontScale.factor(step: step) == table[step], "step \(step)")
    }
}
