// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ConnDockKit",
  defaultLocalization: "zh-Hans",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "ConnDockKit", targets: ["ConnDockKit"])],
  dependencies: [
    .package(path: "Packages/SSHCoreBridge"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
  ],
  targets: [
    .target(
      name: "ConnDockKit",
      dependencies: ["SSHCoreBridge", "SwiftTerm"],
      path: ".",
      exclude: ["Apps", "Artwork", "Privacy", "Generated", "Release"],
      sources: ["Shared", "Features"],
      resources: [.process("Resources")]
    )
  ],
  swiftLanguageModes: [.v6]
)
