#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let data = try Data(
  contentsOf: root.appendingPathComponent("apple/Resources/Localizable.xcstrings"))
let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let strings = catalog["strings"] as! [String: [String: Any]]
var errors: [String] = []
for (key, entry) in strings {
  let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
  for language in ["zh-Hans", "en"] {
    let unit = localizations[language]?["stringUnit"] as? [String: String]
    if unit?["state"] != "translated" || unit?["value"]?.isEmpty != false {
      errors.append("\(key): missing reviewed \(language) translation")
    }
  }
}
let pattern =
  #"(?:Copy\(|\.text\(|key: |labelKey: |title: |detail: )"([a-zA-Z][a-zA-Z0-9]*\.[a-zA-Z0-9.]+)""#
let expression = try NSRegularExpression(pattern: pattern)
for directory in ["apple/Shared", "apple/Features"] {
  let files = FileManager.default.enumerator(
    at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)!
  for case let url as URL in files where url.pathExtension == "swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    let range = NSRange(source.startIndex..., in: source)
    for match in expression.matches(in: source, range: range) {
      let key = String(source[Range(match.range(at: 1), in: source)!])
      if strings[key] == nil { errors.append("\(url.lastPathComponent): unknown key \(key)") }
    }
  }
}
if errors.isEmpty {
  print("String Catalog: \(strings.count) keys, zh-Hans/en complete; source keys valid")
} else {
  for error in errors { print(error) }
  exit(1)
}
