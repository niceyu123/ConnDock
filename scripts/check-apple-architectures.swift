#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let framework = root.appendingPathComponent(
  "apple/Packages/SSHCoreBridge/Artifacts/ConnDockFFI.xcframework")
let info =
  try PropertyListSerialization.propertyList(
    from: Data(contentsOf: framework.appendingPathComponent("Info.plist")), format: nil)
  as! [String: Any]
let libraries = info["AvailableLibraries"] as! [[String: Any]]
func require(_ condition: Bool, _ message: String) {
  if !condition {
    fputs(message + "\n", stderr)
    exit(1)
  }
}
func check(_ binary: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = ["lipo", "-archs", binary.path]
  let pipe = Pipe()
  process.standardOutput = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let architectures = String(decoding: data, as: UTF8.self).trimmingCharacters(
    in: .whitespacesAndNewlines)
  require(
    process.terminationStatus == 0 && architectures == "arm64",
    "Unsupported binary architecture: \(binary.lastPathComponent) (\(architectures))")
  print("PASS arm64 only: \(binary.path)")
}
require(libraries.count == 3, "Expected only macOS arm64, iOS arm64 and iOS Simulator arm64 slices")
var platforms: Set<String> = []
for library in libraries {
  let identifier = library["LibraryIdentifier"] as! String
  let platform = library["SupportedPlatform"] as! String
  let variant = library["SupportedPlatformVariant"] as? String ?? "device"
  platforms.insert("\(platform)-\(variant)")
  require(
    library["SupportedArchitectures"] as? [String] == ["arm64"],
    "Unexpected XCFramework slice: \(identifier)")
  try check(
    framework.appendingPathComponent(identifier).appendingPathComponent(
      library["LibraryPath"] as! String))
}
require(
  platforms == ["macos-device", "ios-device", "ios-simulator"], "Unexpected XCFramework platforms")
for path in CommandLine.arguments.dropFirst() { try check(URL(fileURLWithPath: path)) }
print("Intel / Universal macOS artifacts are not supported.")
