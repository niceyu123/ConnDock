#if os(macOS)
  import CryptoKit
  import Foundation

  indirect enum MCPValue: Codable, Equatable, Sendable {
    case object([String: MCPValue])
    case array([MCPValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    init(from decoder: any Decoder) throws {
      let value = try decoder.singleValueContainer()
      if value.decodeNil() {
        self = .null
      } else if let item = try? value.decode(Bool.self) {
        self = .bool(item)
      } else if let item = try? value.decode(String.self) {
        self = .string(item)
      } else if let item = try? value.decode(Double.self) {
        self = .number(item)
      } else if let item = try? value.decode([String: MCPValue].self) {
        self = .object(item)
      } else {
        self = .array(try value.decode([MCPValue].self))
      }
    }
    func encode(to encoder: any Encoder) throws {
      var value = encoder.singleValueContainer()
      switch self {
      case .object(let item): try value.encode(item)
      case .array(let item): try value.encode(item)
      case .string(let item): try value.encode(item)
      case .number(let item): try value.encode(item)
      case .bool(let item): try value.encode(item)
      case .null: try value.encodeNil()
      }
    }
    var text: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
  }

  struct MCPFailure: Error, Codable, Equatable, Sendable {
    let code: String
    init(_ code: String) { self.code = code }
    var localizationKey: String { "mcp.error.\(code)" }
  }

  struct MCPResponse: Codable, Sendable {
    let ok: Bool
    let data: MCPValue?
    let error: MCPFailure?
    static func success(_ data: MCPValue) -> Self { Self(ok: true, data: data, error: nil) }
    static func failure(_ code: String) -> Self {
      Self(ok: false, data: nil, error: MCPFailure(code))
    }
  }

  enum MCPTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case listHosts = "list_hosts"
    case getHostInfo = "get_host_info"
    case getServerMetrics = "get_server_metrics"
    case getServiceStatus = "get_service_status"
    case sftpList = "sftp_list"
    case sshExec = "ssh_exec"
    var id: String { rawValue }
    var titleKey: String { "mcp.tool.\(rawValue)" }
    static var configurable: [Self] { allCases.filter { $0 != .listHosts } }
  }

  struct MCPRequest: Sendable {
    let tool: MCPTool
    var hostID: UUID?
    var command: String?
    var timeout: UInt32 = 20
    var path: String?
    var serviceName: String?

    static func parse(tool name: String, arguments: [String: MCPValue]) throws -> Self {
      guard let tool = MCPTool(rawValue: name) else { throw MCPFailure("UNKNOWN_TOOL") }
      let allowed: Set<String>
      switch tool {
      case .listHosts: allowed = []
      case .getHostInfo, .getServerMetrics: allowed = ["host_id"]
      case .getServiceStatus: allowed = ["host_id", "service_name"]
      case .sftpList: allowed = ["host_id", "path"]
      case .sshExec: allowed = ["host_id", "command", "timeout"]
      }
      guard Set(arguments.keys).isSubset(of: allowed) else { throw MCPFailure("INVALID_ARGUMENTS") }
      var result = Self(tool: tool)
      if tool != .listHosts {
        guard let text = arguments["host_id"]?.text, text.utf8.count == 36,
          let id = UUID(uuidString: text)
        else { throw MCPFailure("INVALID_ARGUMENTS") }
        result.hostID = id
      }
      switch tool {
      case .sshExec:
        guard let command = arguments["command"]?.text, !command.isEmpty,
          command.utf8.count <= 8192,
          !command.unicodeScalars.contains(where: { scalar in
            (CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t")
              || scalar.properties.generalCategory == .format
          })
        else { throw MCPFailure("INVALID_ARGUMENTS") }
        result.command = command
        if let value = arguments["timeout"] {
          guard let number = value.number, number.isFinite, number.rounded() == number,
            (1...60).contains(number)
          else { throw MCPFailure("INVALID_ARGUMENTS") }
          result.timeout = UInt32(number)
        }
      case .getServiceStatus:
        guard let service = arguments["service_name"]?.text, validService(service) else {
          throw MCPFailure("INVALID_ARGUMENTS")
        }
        result.serviceName = service.hasSuffix(".service") ? service : service + ".service"
      case .sftpList:
        guard let path = arguments["path"]?.text, MCPPathPolicy.valid(path) else {
          throw MCPFailure("PATH_NOT_AUTHORIZED")
        }
        result.path = path
      default: break
      }
      return result
    }

    static func validService(_ name: String) -> Bool {
      !name.isEmpty && name.utf8.count <= 128 && name.first?.isASCII == true
        && name.first?.isLetter == true
        && name.utf8.allSatisfy {
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 64, 95].contains($0)
        }
        && !name.contains("..") && !name.hasSuffix(".")
        && (!name.contains(".") || name.hasSuffix(".service"))
    }
  }

  enum MCPPathPolicy {
    static func valid(_ path: String) -> Bool {
      guard path.hasPrefix("/"), path.utf8.count <= 4096,
        !path.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        })
      else { return false }
      let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
      guard !parts.contains(".."), !parts.contains("."), !path.contains("//") else { return false }
      let blocked: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".kube", ".azure", ".credentials", ".env",
      ]
      guard !parts.contains(where: { blocked.contains($0.lowercased()) }) else { return false }
      let normalized =
        path.count > 1 ? path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
      return !["proc", "sys", "dev", "etc/ssh"].contains {
        normalized == $0 || normalized.hasPrefix($0 + "/")
      }
    }
    static func allows(_ path: String, roots: [String]) -> Bool {
      guard valid(path) else { return false }
      return roots.contains { root in
        guard valid(root) else { return false }
        let root = root == "/" ? "/" : root.trimmingTrailingSlash
        return path == root || (root == "/" ? true : path.hasPrefix(root + "/"))
      }
    }
  }

  extension String {
    fileprivate var trimmingTrailingSlash: String {
      var result = self
      while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
      return result
    }
  }

  struct MCPHostGrant: Codable, Equatable {
    let identity: String
    var tools: Set<MCPTool>
    var roots: [String] = []
    var services: [String] = []
    @MainActor init(
      host: StoredHost, tools: Set<MCPTool> = [], roots: [String] = [], services: [String] = []
    ) {
      identity = Self.identity(host)
      self.tools = tools
      self.roots = roots
      self.services = services
    }
    @MainActor static func identity(_ host: StoredHost) -> String {
      let fields = [
        host.hostname.lowercased(), String(host.port), host.username, host.authMethodRaw,
      ]
      let data = (try? JSONEncoder().encode(fields)) ?? Data()
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }

  struct MCPPolicy: Codable {
    var enabled = false
    var grants: [String: MCPHostGrant] = [:]
    @MainActor func allows(_ tool: MCPTool, host: StoredHost) -> Bool {
      guard enabled, host.deletedAt == nil, let grant = grants[host.id.uuidString],
        grant.identity == MCPHostGrant.identity(host), !grant.tools.isEmpty
      else { return false }
      return tool == .listHosts || grant.tools.contains(tool)
    }
  }
#endif
