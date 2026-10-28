import Foundation

struct SSHConfigIssue: Equatable, Sendable {
  let key: String
  var line: Int? = nil
  var directive: String? = nil
}

struct SSHConfigEntry: Identifiable, Sendable {
  var id: String { alias.lowercased() }
  let alias: String
  let hostname: String
  let username: String
  let port: UInt16
  let requiresPrivateKey: Bool
  let issues: [SSHConfigIssue]
  var canImport: Bool { issues.isEmpty }
}

struct SSHConfigParseResult: Sendable {
  let entries: [SSHConfigEntry]
  let diagnostics: [SSHConfigIssue]
}

enum SSHConfigParser {
  static let maximumBytes = 256 * 1024
  static let maximumEntries = 256

  enum ParseError: Error {
    case limit, encoding
    var localizationKey: String {
      switch self {
      case .limit: "sshConfig.error.limit"
      case .encoding: "sshConfig.error.encoding"
      }
    }
  }

  private struct Directive {
    let name: String
    let values: [String]
    let line: Int
  }

  private struct Block {
    let patterns: [String]?
    var directives: [Directive] = []
    func matches(_ alias: String) -> Bool {
      guard let patterns else { return true }
      var positive = false
      for pattern in patterns {
        if pattern.hasPrefix("!") {
          if SSHConfigParser.matches(String(pattern.dropFirst()), alias) { return false }
        } else if SSHConfigParser.matches(pattern, alias) {
          positive = true
        }
      }
      return positive
    }
  }

  /// Reads only the selected document. No Includes, key paths, tokens, or commands are evaluated.
  static func parse(_ text: String, defaultUsername: String = "") throws -> SSHConfigParseResult {
    guard text.utf8.count <= maximumBytes else { throw ParseError.limit }
    guard
      !text.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)
      })
    else { throw ParseError.encoding }
    let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count <= 8192 else { throw ParseError.limit }
    var blocks = [Block(patterns: nil)]
    var aliases: [String] = []
    var seen: Set<String> = []
    var diagnostics: [SSHConfigIssue] = []
    func diagnose(_ issue: SSHConfigIssue) {
      if diagnostics.count < 64 { diagnostics.append(issue) }
    }
    for (offset, line) in lines.enumerated() {
      guard line.utf8.count <= 8192 else { throw ParseError.limit }
      let number = offset + 1
      let directive: Directive
      do {
        guard let parsed = try tokenize(String(line), line: number) else { continue }
        directive = parsed
      } catch {
        diagnose(SSHConfigIssue(key: "sshConfig.issue.syntax", line: number))
        continue
      }
      switch directive.name {
      case "host":
        guard !directive.values.isEmpty, directive.values.count <= 128,
          directive.values.allSatisfy(validPattern)
        else {
          diagnose(SSHConfigIssue(key: "sshConfig.issue.syntax", line: number))
          continue
        }
        blocks.append(Block(patterns: directive.values))
        for alias in directive.values
        where !alias.hasPrefix("!") && !alias.contains("*")
          && !alias.contains("?")
        {
          if seen.insert(alias.lowercased()).inserted { aliases.append(alias) }
        }
        guard aliases.count <= maximumEntries else { throw ParseError.limit }
      case "include", "match":
        // An included file can introduce Host/Match boundaries, while Match can depend
        // on commands, canonicalisation, or other runtime context. Scope is unknowable.
        diagnose(
          SSHConfigIssue(key: "sshConfig.issue.context", line: number, directive: directive.name))
        if directive.name == "match" { blocks.append(Block(patterns: [])) }
      case "hostname", "user", "port", "identityfile":
        guard directive.values.count == 1 else {
          diagnose(SSHConfigIssue(key: "sshConfig.issue.syntax", line: number))
          continue
        }
        blocks[blocks.count - 1].directives.append(directive)
      default:
        blocks[blocks.count - 1].directives.append(directive)
      }
    }
    let entries = aliases.map { alias in
      resolve(
        alias: alias, blocks: blocks, diagnostics: diagnostics, defaultUsername: defaultUsername)
    }
    return SSHConfigParseResult(entries: entries, diagnostics: diagnostics)
  }

  private static func resolve(
    alias: String, blocks: [Block], diagnostics: [SSHConfigIssue], defaultUsername: String
  ) -> SSHConfigEntry {
    var first: [String: Directive] = [:]
    var issues: [SSHConfigIssue] = []
    var requiresPrivateKey = false
    for block in blocks where block.matches(alias) {
      for item in block.directives {
        if item.name == "identityfile" {
          if item.values.first?.isEmpty != false {
            if issues.count < 16 {
              issues.append(SSHConfigIssue(key: "sshConfig.issue.identityFile", line: item.line))
            }
          } else if item.values.first?.lowercased() != "none" {
            // IdentityFile is additive in OpenSSH; keep only a nonsecret auth hint.
            requiresPrivateKey = true
          }
        } else if ["hostname", "user", "port"].contains(item.name) {
          if first[item.name] == nil { first[item.name] = item }
        } else if issues.count < 16 {
          issues.append(
            SSHConfigIssue(
              key: "sshConfig.issue.unsupported", line: item.line, directive: item.name))
        }
      }
    }
    let hostname = first["hostname"]?.values.first ?? alias
    let username =
      first["user"]?.values.first
      ?? defaultUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    let portValue = first["port"]?.values.first ?? "22"
    let parsedPort =
      portValue.utf8.allSatisfy { (48...57).contains($0) }
      ? UInt16(portValue) : nil
    if !validHostname(hostname) {
      issues.append(SSHConfigIssue(key: "sshConfig.issue.hostname", line: first["hostname"]?.line))
    }
    if !validUsername(username) {
      issues.append(SSHConfigIssue(key: "sshConfig.issue.username", line: first["user"]?.line))
    }
    if parsedPort == nil || parsedPort == 0 {
      issues.append(SSHConfigIssue(key: "sshConfig.issue.port", line: first["port"]?.line))
    }
    return SSHConfigEntry(
      alias: alias, hostname: hostname, username: username, port: parsedPort ?? 22,
      requiresPrivateKey: requiresPrivateKey,
      issues: Array((diagnostics + issues).prefix(16)))
  }

  private static func validHostname(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 253 && !value.hasPrefix("-")
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "-._:".unicodeScalars.contains($0)
      }
  }

  private static func validUsername(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && !value.contains(where: { $0.isWhitespace || "%$".contains($0) })
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validPattern(_ value: String) -> Bool {
    let pattern = value.hasPrefix("!") ? String(value.dropFirst()) : value
    return !pattern.isEmpty && pattern.utf8.count <= 253
      && !pattern.contains(where: { $0.isWhitespace || ",/@%$!#=\\[]".contains($0) })
      && !pattern.hasPrefix("-")
  }

  /// OpenSSH Host matching is case-insensitive and supports only * and ? globs.
  private static func matches(_ pattern: String, _ alias: String) -> Bool {
    let pattern = Array(pattern.lowercased().utf8)
    let value = Array(alias.lowercased().utf8)
    var p = 0
    var v = 0
    var star: Int?
    var retry = 0
    while v < value.count {
      if p < pattern.count && (pattern[p] == 63 || pattern[p] == value[v]) {
        p += 1
        v += 1
      } else if p < pattern.count && pattern[p] == 42 {
        star = p
        p += 1
        retry = v
      } else if let star {
        retry += 1
        v = retry
        p = star + 1
      } else {
        return false
      }
    }
    while p < pattern.count && pattern[p] == 42 { p += 1 }
    return p == pattern.count
  }

  private enum SyntaxError: Error { case invalid }

  private static func tokenize(_ line: String, line number: Int) throws -> Directive? {
    let characters = Array(line)
    var index = 0
    func skipWhitespace() {
      while index < characters.count && characters[index].isWhitespace { index += 1 }
    }
    skipWhitespace()
    guard index < characters.count, characters[index] != "#" else { return nil }
    var key = ""
    while index < characters.count && !characters[index].isWhitespace && characters[index] != "=" {
      key.append(characters[index])
      index += 1
    }
    guard !key.isEmpty, key.utf8.count <= 64,
      key.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
      }),
      key.utf8.first.map({ (65...90).contains($0) || (97...122).contains($0) }) == true
    else { throw SyntaxError.invalid }
    skipWhitespace()
    if index < characters.count && characters[index] == "=" {
      index += 1
      skipWhitespace()
    }
    var values: [String] = []
    var token = ""
    var started = false
    var quoted = false
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        index += 1
        guard index < characters.count else { throw SyntaxError.invalid }
        let escaped = characters[index]
        guard escaped == "\\" || escaped == "\"" || escaped == "#" || escaped.isWhitespace else {
          throw SyntaxError.invalid
        }
        token.append(escaped)
        started = true
      } else if character == "\"" {
        quoted.toggle()
        started = true
      } else if !quoted && character == "#" {
        break
      } else if !quoted && character.isWhitespace {
        if started {
          values.append(token)
          token = ""
          started = false
        }
      } else {
        token.append(character)
        started = true
      }
      guard values.count <= 128 else { throw SyntaxError.invalid }
      index += 1
    }
    guard !quoted else { throw SyntaxError.invalid }
    if started { values.append(token) }
    guard !values.isEmpty else { throw SyntaxError.invalid }
    return Directive(name: key.lowercased(), values: values, line: number)
  }
}
