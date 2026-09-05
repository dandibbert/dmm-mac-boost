// swift-tools-version: 5.9
import PackageDescription
var products: [Product] = [.library(name: "BrowserCore", targets: ["BrowserCore"])]
var targets: [Target] = [.target(name: "BrowserCore"), .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"])]
#if os(macOS)
products.append(.executable(name: "Pagekeep", targets: ["Pagekeep"]))
targets += [
    .target(name: "WebKitBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("AppKit")]),
    .executableTarget(name: "Pagekeep", dependencies: ["BrowserCore", "WebKitBridge"], resources: [.copy("Resources")], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")])
]
#endif
let package = Package(name: "Pagekeep", platforms: [.macOS(.v14)], products: products, targets: targets, swiftLanguageVersions: [.v5])
