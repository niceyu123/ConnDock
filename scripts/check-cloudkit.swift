#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = FileManager.default
let output = root.appendingPathComponent("build/phase4-configuration", isDirectory: true)
try manager.createDirectory(at: output, withIntermediateDirectories: true)

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() {
    throw NSError(
      domain: "CloudKitConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

for platform in ["macOS", "iOS"] {
  let info =
    try PropertyListSerialization.propertyList(
      from: Data(contentsOf: root.appendingPathComponent("apple/Apps/\(platform)/Info.plist")),
      format: nil) as! [String: Any]
  try require(
    info["ConnDockCloudKitContainer"] as? String == "iCloud.com.ruohai.conndock",
    "Incorrect \(platform) container Info")
  for configuration in ["Debug", "Release", "Local"] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.currentDirectoryURL = root
    process.arguments = [
      "xcodebuild", "-project", "apple/ConnDock.xcodeproj", "-scheme", "ConnDock-\(platform)",
      "-configuration", configuration, "-sdk", platform == "macOS" ? "macosx" : "iphoneos",
      "-skipPackagePluginValidation", "-disableAutomaticPackageResolution", "-showBuildSettings",
      "-json",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    let log = output.appendingPathComponent("\(platform)-\(configuration).log")
    manager.createFile(atPath: log.path, contents: nil)
    let errors = try FileHandle(forWritingTo: log)
    process.standardError = errors
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try errors.close()
    try require(
      process.terminationStatus == 0, "Unable to read build settings: \(platform) \(configuration)")
    try data.write(to: output.appendingPathComponent("\(platform)-\(configuration).json"))
    let records = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let record = records.first { $0["target"] as? String == "ConnDock-\(platform)" }!
    let settings = record["buildSettings"] as! [String: String]
    let local = configuration == "Local"
    try require(settings["ARCHS"] == "arm64", "Only Apple Silicon / arm64 is supported")
    try require(
      settings["PRODUCT_BUNDLE_IDENTIFIER"]
        == (local ? "local.SSHClient.\(platform)" : "com.ruohai.conndock"), "Unexpected Bundle ID")
    try require(settings["CODE_SIGN_STYLE"] == "Automatic", "Automatic signing is not configured")
    try require(
      settings["CONNDOCK_CLOUDKIT_ENABLED"] == (local ? "NO" : "YES"),
      "Incorrect cloud runtime switch")
    if !local { try require(settings["DEVELOPMENT_TEAM"] == "86HC8YA388", "Incorrect Team") }
    let entitlement = root.appendingPathComponent("apple/" + settings["CODE_SIGN_ENTITLEMENTS"]!)
    let values =
      try PropertyListSerialization.propertyList(from: Data(contentsOf: entitlement), format: nil)
      as! [String: Any]
    if local {
      try require(
        values["com.apple.developer.icloud-services"] == nil,
        "Local build must not request CloudKit")
    } else {
      try require(
        values["com.apple.developer.icloud-container-identifiers"] as? [String] == [
          "iCloud.com.ruohai.conndock"
        ], "Incorrect entitlement container")
      try require(
        values["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"],
        "CloudKit is not enabled")
      try require(
        settings["CONNDOCK_CLOUDKIT_ENVIRONMENT"]
          == (configuration == "Release" ? "Production" : "Development"),
        "Incorrect cloud environment")
    }
    if platform == "macOS" {
      try require(
        values["com.apple.security.app-sandbox"] as? Bool == true, "Sandbox must be enabled")
      try require(
        values["com.apple.security.network.client"] as? Bool == true,
        "Outgoing connections must be enabled")
      try require(
        values["com.apple.security.network.server"] as? Bool == true,
        "Phase 5 local IPC requires macOS network.server")
      try require(
        values["com.apple.security.application-groups"] as? [String]
          == (local ? nil : ["86HC8YA388.com.ruohai.conndock.mcp"]),
        "Incorrect macOS MCP IPC group")
    } else {
      try require(
        values["com.apple.security.application-groups"] == nil,
        "iOS must not enable the macOS MCP group")
      try require(
        values["com.apple.security.network.server"] as? Bool != true,
        "iOS must not enable the macOS MCP listener")
    }
    print("PASS: \(platform) \(configuration) Bundle/Team/CloudKit/entitlements policy")
  }
}
print(
  "Source/generated build settings are consistent. This does not verify a provisioning profile, signature or live iCloud sync."
)
