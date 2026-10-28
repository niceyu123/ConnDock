import Foundation

enum TerminalSplitAxis: String, CaseIterable {
  case horizontal, vertical
  var key: String { "terminal.split.\(rawValue)" }
  var symbol: String { self == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

struct TerminalSplit: Equatable {
  let first: UUID
  let second: UUID
  var axis: TerminalSplitAxis

  func contains(_ id: UUID) -> Bool { first == id || second == id }
  func companion(of id: UUID) -> UUID { first == id ? second : first }
}
