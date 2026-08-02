import Foundation

/// This is an Xcode-project test target (via `xcodegen`/`project.yml`), not a
/// Swift Package Manager target, so `Bundle.module` does not exist here.
/// `Bundle(for: FixtureBundleMarker.self)` resolves to the `RavenFeatureTests`
/// test bundle itself, where `project.yml`'s `Fixtures` resources phase
/// copies the JSON fixtures.
final class FixtureBundleMarker {}
