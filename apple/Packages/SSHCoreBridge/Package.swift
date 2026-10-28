// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SSHCoreBridge",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "SSHCoreBridge", targets: ["SSHCoreBridge"])],
  targets: [
    .binaryTarget(name: "ConnDockFFI", path: "Artifacts/ConnDockFFI.xcframework"),
    .target(name: "SSHCoreBridge", dependencies: ["ConnDockFFI"]),
  ],
  swiftLanguageModes: [.v6]
)
