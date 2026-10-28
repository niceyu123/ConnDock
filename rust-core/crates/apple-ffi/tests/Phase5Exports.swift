// Compile only: this consumer never connects to a host or executes a command.
func checkPhase5Exports(
  connection: SshConnection,
  files: RemoteFiles,
  operation: RemoteOperation
) async throws {
  connection.setInputSuspended(suspended: true)
  try await connection.checkConnection(operation: operation)
  connection.setInputSuspended(suspended: false)
  let directory: RemoteDirectoryListing = try await files.listAuthorizedDirectory(
    path: "/srv/app", allowedRoots: ["/srv/app"], operation: operation
  )
  let command: CommandOutput = try await connection.executeCommand(
    command: "true", timeoutSeconds: 1, operation: operation
  )
  let status: ServiceStatus = try await connection.serviceStatus(
    serviceName: "ssh.service", operation: operation
  )
  let _: UInt32? = command.exitCode
  _ = (directory.path, directory.entries, command.stdout, command.stderr, command.truncated)
  _ = (
    status.name, status.loadState, status.activeState, status.subState, status.unitFileState,
    status.activeEnterTimestamp
  )
}
