// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Asks the user's own `claude` CLI, in a separate one-shot call, to explain a request. The call can only read
/// files in the project (Read, Grep, Glob), loads no project settings or hooks, and cannot approve anything.
public struct ClaudeAdvisor: RequestAdvisor {
    public var executable: URL
    public var workingDirectory: URL
    public var auth: AuthMode
    public var baseEnvironment: [String: String]
    public var model: String
    public var timeout: TimeInterval

    public init(executable: URL, workingDirectory: URL, auth: AuthMode, baseEnvironment: [String: String],
                model: String = "haiku", timeout: TimeInterval = 60) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.auth = auth
        self.baseEnvironment = baseEnvironment
        self.model = model
        self.timeout = timeout
    }

    public func summarize(_ request: PermissionRequest, assessment: PermissionAssessment, project: String?) async throws -> String {
        try await run(AdvisorPrompt.summary(request, assessment: assessment, project: project))
    }

    public func answer(_ question: String, about request: PermissionRequest, assessment: PermissionAssessment,
                       project: String?, earlier: [AdvisorTurn]) async throws -> String {
        try await run(AdvisorPrompt.question(question, request: request, assessment: assessment, project: project, earlier: earlier))
    }

    func arguments(prompt: String) -> [String] {
        ["-p", "--model", model, "--output-format", "text",
         "--tools", "Read,Grep,Glob",
         // User-level settings only: a repository's own hooks and allow rules must not run for this call either.
         "--setting-sources", "user",
         "--no-session-persistence",
         "--append-system-prompt", AdvisorPrompt.system,
         "--", prompt]
    }

    func run(_ prompt: String) async throws -> String {
        let environment = LaunchConfiguration(executable: executable, workingDirectory: workingDirectory, auth: auth,
                                              baseEnvironment: baseEnvironment).environment()
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(executable, arguments: arguments(prompt: prompt), environment: environment,
                                                 currentDirectory: workingDirectory, timeout: timeout)
        } catch {
            throw AdvisorError.failed("Could not reach Claude for an explanation.")
        }
        guard output.status == 0 else {
            throw AdvisorError.failed("Claude could not explain this (exit \(output.status)).")
        }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AdvisorError.empty }
        return String(text.prefix(1_500))
    }
}
