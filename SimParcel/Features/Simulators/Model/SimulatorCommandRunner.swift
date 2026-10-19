import Foundation

struct SimulatorCommandRunner: SimulatorCommandRunning {
    /// Runs a command without blocking a thread while waiting for it, and returns its standard output.
    /// Standard error is kept separate so warnings cannot corrupt JSON output.
    func output(_ executable: String, _ arguments: [String]) async throws -> Data {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        async let output = Self.readToEnd(outputPipe.fileHandleForReading)
        async let errorOutput = Self.readToEnd(errorPipe.fileHandleForReading)

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }

                do {
                    try process.run()
                    if Task.isCancelled {
                        process.terminate()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            _ = try? await (output, errorOutput)
            throw SimulatorServiceError.commandFailed(
                "Could not run \(executable): \(error.localizedDescription)"
            )
        }

        let (outputData, errorData) = try await (output, errorOutput)
        guard status == 0 else {
            let message = [errorData, outputData]
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                .map(SimulatorService.conciseMessage)
            throw SimulatorServiceError.commandFailed(message ?? "\(executable) exited with status \(status).")
        }

        try Task.checkCancellation()

        return outputData
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }

        return data
    }
}
