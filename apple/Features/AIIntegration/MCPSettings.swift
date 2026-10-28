#if os(macOS)
  import AppKit
  import SwiftUI

  struct MCPSettings: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkspaceState.self) private var workspace
    @State private var confirmEnable = false
    @State private var confirmRevoke = false
    var body: some View {
      if let service = workspace.mcp, let library = workspace.library {
        Section {
          Toggle(
            preferences.text("mcp.enabled"),
            isOn: Binding(
              get: { service.isEnabled },
              set: { enabled in
                if enabled { confirmEnable = true } else { service.setEnabled(false) }
              })
          ).accessibilityIdentifier("mcpEnabled")
          if let failure = service.failure { Copy(failure.localizationKey).foregroundStyle(.red) }
          if service.locked { Copy("mcp.locked").foregroundStyle(.secondary) }
        } footer: {
          Copy("mcp.scope")
        }
        Section {
          if library.hosts.isEmpty { Copy("mcp.noHosts").foregroundStyle(.secondary) }
          ForEach(library.hosts) { host in MCPHostPermissionRow(host: host, service: service) }
        } header: {
          Copy("mcp.hosts")
        }
        Section {
          Copy("mcp.installDetail").foregroundStyle(.secondary)
          Text(verbatim: service.installationCommand)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          HStack {
            Button(preferences.text("mcp.copyCommand")) {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(service.installationCommand, forType: .string)
            }
            Button(preferences.text("mcp.testConnection")) { service.testConnection() }
              .disabled(!service.isEnabled || service.testing).accessibilityIdentifier(
                "mcpTestConnection")
            if service.testing { ProgressView().controlSize(.small) }
          }
          if let result = service.testResult {
            Copy(result.localizationKey).foregroundStyle(
              result.code == "TEST_OK" ? Color.secondary : .red)
          }
          Copy("mcp.otherClients").font(.caption).foregroundStyle(.secondary)
          Text(verbatim: service.helperURL.path).font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
        } header: {
          Copy("mcp.install")
        }
        Section {
          Button(preferences.text("mcp.revokeAll"), role: .destructive) { confirmRevoke = true }
            .accessibilityIdentifier("mcpRevokeAll")
        } footer: {
          Copy("mcp.revokeDetail")
        }
        Section {
          if service.audit.isEmpty { Copy("mcp.noAudit").foregroundStyle(.secondary) }
          ForEach(service.audit.prefix(30)) { entry in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Copy(entry.tool.titleKey)
                Spacer()
                Text(entry.time, format: .dateTime.hour().minute().second())
              }
              HStack {
                Text(verbatim: entry.hostID?.uuidString ?? "—").font(
                  .system(.caption2, design: .monospaced))
                Spacer()
                Text(verbatim: entry.result).font(.caption.monospaced())
              }.foregroundStyle(.secondary)
            }
          }
          if !service.audit.isEmpty {
            Button(preferences.text("mcp.clearAudit")) { service.clearAudit() }
          }
        } header: {
          Copy("mcp.audit")
        } footer: {
          Copy("mcp.auditDetail")
        }
        .confirmationDialog(
          preferences.text("mcp.enableTitle"), isPresented: $confirmEnable,
          titleVisibility: .visible
        ) {
          Button(preferences.text("mcp.enableConfirm")) { service.setEnabled(true) }
          Button(preferences.text("action.cancel"), role: .cancel) {}
        } message: {
          Copy("mcp.enableDetail")
        }
        .confirmationDialog(
          preferences.text("mcp.revokeAll"), isPresented: $confirmRevoke, titleVisibility: .visible
        ) {
          Button(preferences.text("mcp.revokeAll"), role: .destructive) { service.revokeAll() }
          Button(preferences.text("action.cancel"), role: .cancel) {}
        } message: {
          Copy("mcp.revokeDetail")
        }
      } else {
        Copy("storage.error.unavailable").foregroundStyle(.secondary)
      }
    }
  }

  private struct MCPHostPermissionRow: View {
    @Environment(AppPreferences.self) private var preferences
    let host: StoredHost
    let service: MCPService
    @State private var expanded = false
    @State private var roots = ""
    @State private var services = ""
    @State private var invalid = false
    private var grant: MCPHostGrant? {
      let grant = service.policy.grants[host.id.uuidString]
      return grant?.identity == MCPHostGrant.identity(host) ? grant : nil
    }
    var body: some View {
      DisclosureGroup(isExpanded: $expanded) {
        ForEach(MCPTool.configurable) { tool in
          Toggle(
            preferences.text(tool.titleKey),
            isOn: Binding(
              get: { grant?.tools.contains(tool) == true },
              set: { enabled in
                var updated = grant ?? MCPHostGrant(host: host)
                if enabled { updated.tools.insert(tool) } else { updated.tools.remove(tool) }
                service.setGrant(updated.tools.isEmpty ? nil : updated, for: host.id)
              })
          )
          .accessibilityIdentifier("mcpTool.\(host.id).\(tool.rawValue)")
        }
        Copy("mcp.commandPolicy").font(.caption).foregroundStyle(.secondary)
        TextField(preferences.text("mcp.roots"), text: $roots, axis: .vertical).lineLimit(2...5)
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("mcpRoots")
        TextField(preferences.text("mcp.services"), text: $services, axis: .vertical).lineLimit(
          2...4
        )
        .textFieldStyle(.roundedBorder).accessibilityIdentifier("mcpServices")
        Copy("mcp.pathDetail").font(.caption).foregroundStyle(.secondary)
        Button(preferences.text("mcp.saveScope")) {
          let rootValues = roots.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }.filter { !$0.isEmpty }
          let serviceValues = services.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }.filter { !$0.isEmpty }
          guard rootValues.count <= 32, serviceValues.count <= 64,
            rootValues.allSatisfy(MCPPathPolicy.valid),
            serviceValues.allSatisfy(MCPRequest.validService)
          else {
            invalid = true
            return
          }
          invalid = false
          var updated = grant ?? MCPHostGrant(host: host)
          updated.roots = Array(Set(rootValues)).sorted()
          updated.services = Array(Set(serviceValues)).sorted()
          service.setGrant(updated, for: host.id)
        }
        if invalid { Copy("mcp.invalidScope").foregroundStyle(.red) }
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: host.title)
            Text(verbatim: "\(host.username)@\(host.hostname):\(host.port)").font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Copy(grant?.tools.isEmpty == false ? "mcp.authorized" : "mcp.notAuthorized").font(
            .caption
          ).foregroundStyle(.secondary)
        }
      }
      .onAppear {
        roots = grant?.roots.joined(separator: "\n") ?? ""
        services = grant?.services.joined(separator: "\n") ?? ""
      }
    }
  }
#endif
