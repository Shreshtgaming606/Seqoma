import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "AccentColor" asset catalog color resource.
    static let accent = DeveloperToolsSupport.ColorResource(name: "AccentColor", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "HeroBeach" asset catalog image resource.
    static let heroBeach = DeveloperToolsSupport.ImageResource(name: "HeroBeach", bundle: resourceBundle)

    /// The "HeroBeachNight" asset catalog image resource.
    static let heroBeachNight = DeveloperToolsSupport.ImageResource(name: "HeroBeachNight", bundle: resourceBundle)

    /// The "HeroDay1" asset catalog image resource.
    static let heroDay1 = DeveloperToolsSupport.ImageResource(name: "HeroDay1", bundle: resourceBundle)

    /// The "HeroDay2" asset catalog image resource.
    static let heroDay2 = DeveloperToolsSupport.ImageResource(name: "HeroDay2", bundle: resourceBundle)

    /// The "HeroDay3" asset catalog image resource.
    static let heroDay3 = DeveloperToolsSupport.ImageResource(name: "HeroDay3", bundle: resourceBundle)

    /// The "HeroDay4" asset catalog image resource.
    static let heroDay4 = DeveloperToolsSupport.ImageResource(name: "HeroDay4", bundle: resourceBundle)

}

