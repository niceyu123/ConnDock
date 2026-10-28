#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--help"] {
  print("Usage: scripts/export-screenshots.swift <result.xcresult> [more.xcresult ...]")
  exit(arguments.isEmpty ? 2 : 0)
}
let manager = FileManager.default
let pattern = try NSRegularExpression(pattern: #"^((?:macos|iphone|ipad)-[a-z0-9-]+)_"#)
var count = 0
for argument in arguments {
  let result = URL(fileURLWithPath: argument).standardizedFileURL
  let staging = root.appendingPathComponent(
    "build/export-\(result.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "xcresulttool", "export", "attachments", "--path", result.path,
    "--output-path", staging.path, "--filter", "*.png",
  ]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
  let data = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
  let tests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
  for test in tests {
    for attachment in test["attachments"] as? [[String: Any]] ?? [] {
      guard let suggested = attachment["suggestedHumanReadableName"] as? String,
        let file = attachment["exportedFileName"] as? String,
        let match = pattern.firstMatch(
          in: suggested, range: NSRange(suggested.startIndex..., in: suggested)),
        let range = Range(match.range(at: 1), in: suggested)
      else { continue }
      let name = String(suggested[range]) + ".png"
      // SSH terminal output stays in ignored runtime artifacts, never in Git.
      let directory =
        name.contains("-phase6-")
        ? "build/phase6-screenshots"
        : name.contains("-phase5-")
          ? "build/phase5-screenshots"
          : name.contains("-phase4-")
            ? "build/phase4-screenshots"
            : name.contains("-phase3-")
              ? "build/phase3-screenshots"
              : name.contains("-phase2-")
                ? "build/phase2-screenshots"
                : name.contains("-phase1-") ? "build/phase1-screenshots" : "docs/screenshots"
      let destination = root.appendingPathComponent(directory, isDirectory: true)
      try manager.createDirectory(at: destination, withIntermediateDirectories: true)
      let output = destination.appendingPathComponent(name)
      // Copy the original XCTest PNG bytes; no composition or image editing.
      let bytes = try Data(contentsOf: staging.appendingPathComponent(file))
      try bytes.write(to: output, options: .atomic)
      print("Screenshot: \(directory)/\(name)")
      count += 1
    }
  }
}
guard count > 0 else {
  print("No named runtime screenshot attachments found.")
  exit(1)
}
print("Exported \(count) actual runtime screenshots.")
