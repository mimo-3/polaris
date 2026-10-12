import Testing
import Foundation
import Darwin
import PolarisCore

final class OSSIntegrationTests {
    private var homes: [URL] = []
    deinit { for home in homes { try? FileManager.default.removeItem(at: home) } }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func home() throws -> URL {
        let directory = root.appendingPathComponent("polaris-test-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        homes.append(directory)
        return directory
    }
    private func run(_ executable: String, arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private func script(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        #expect(chmod(url.path, 0o700) == 0)
    }

    @Test func testShellQuotedPathSurvivesSpacesQuotesAndSubstitutions() throws {
        let directory = try home()
        let marker = directory.appendingPathComponent("polaris-test-injected")
        let path = "/Applications/Mimo's $(touch \(marker.path)) `echo wrong` Polaris.app/bin"
        let result = try run("/bin/sh", arguments: ["-c", "printf '%s' " + ShellCommand.quote(path)])
        #expect(result.status == 0)
        #expect(result.output == path)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor @Test func testOperationQueueAppliesResetAfterSlowOldResponse() async {
        let queue = StateOperationQueue()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var revisions: [Int] = []
        let oldRead = queue.enqueue {
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            revisions.append(99)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let reset = queue.enqueue { revisions.append(1) }
        await _Concurrency.Task.yield()
        release.continuation.yield(())
        await oldRead.value
        await reset.value
        #expect(revisions == [99, 1])
    }

    @Test func testVersionUsesBundleMetadataAndFallsBackForMissingMetadata() throws {
        let directory = try home()
        let plist = directory.appendingPathComponent("Info.plist")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.4.6"], format: .xml, options: 0)
        try bytes.write(to: plist)
        #expect(PolarisVersion.version(infoPlistURL: plist) == "2.4.6")
        #expect(PolarisVersion.version(infoPlistURL: directory.appendingPathComponent("missing.plist")) == PolarisVersion.defaultVersion)
        try Data("broken".utf8).write(to: plist)
        #expect(PolarisVersion.version(infoPlistURL: plist) == PolarisVersion.defaultVersion)
    }

    @Test func testInstallCopyFailureLeavesOldApplicationAndCleansStaging() throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        let commands = fixture.appendingPathComponent("commands")
        let destination = fixture.appendingPathComponent("Applications")
        let previous = destination.appendingPathComponent("Polaris.app")
        for directory in [scripts, commands, previous] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/install.sh"), to: scripts.appendingPathComponent("install.sh"))
        try Data("previous".utf8).write(to: previous.appendingPathComponent("marker"))
        try script("#!/bin/sh\nexit 42\n", at: commands.appendingPathComponent("ditto"))

        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("install.sh").path], environment: ["INSTALL_DIR": destination.path, "PATH": commands.path + ":/usr/bin:/bin"])

        #expect(result.status != 0)
        #expect(try String(contentsOf: previous.appendingPathComponent("marker"), encoding: .utf8) == "previous")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Polaris.app"])
    }

    @Test func testInstallAtomicallyReplacesPreviousApplication() throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        let destination = fixture.appendingPathComponent("Applications")
        let previous = destination.appendingPathComponent("Polaris.app")
        let candidate = fixture.appendingPathComponent("build/Polaris.app")
        for directory in [scripts, previous, candidate] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/install.sh"), to: scripts.appendingPathComponent("install.sh"))
        try Data("previous".utf8).write(to: previous.appendingPathComponent("marker"))
        try Data("candidate".utf8).write(to: candidate.appendingPathComponent("marker"))

        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("install.sh").path], environment: ["INSTALL_DIR": destination.path])

        #expect(result.status == 0, "\(result.output)")
        #expect(try String(contentsOf: previous.appendingPathComponent("marker"), encoding: .utf8) == "candidate")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Polaris.app"])
    }

    @Test func testInstallStagesInHiddenProductDirectory() throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        let commands = fixture.appendingPathComponent("commands")
        let destination = fixture.appendingPathComponent("Applications")
        let stagingLog = fixture.appendingPathComponent("polaris-test-staging.log")
        for directory in [scripts, commands, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/install.sh"), to: scripts.appendingPathComponent("install.sh"))
        try script("#!/bin/sh\nprintf '%s' \"$2\" > \"$POLARIS_TEST_STAGING_LOG\"\nmkdir -p \"$2\"\n", at: commands.appendingPathComponent("ditto"))

        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("install.sh").path], environment: [
            "INSTALL_DIR": destination.path,
            "PATH": commands.path + ":/usr/bin:/bin",
            "POLARIS_TEST_STAGING_LOG": stagingLog.path
        ])

        #expect(result.status == 0, "\(result.output)")
        let stagedApp = URL(fileURLWithPath: try String(contentsOf: stagingLog, encoding: .utf8))
        #expect(stagedApp.deletingLastPathComponent().lastPathComponent.hasPrefix(".polaris-install-"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Polaris.app"])
    }

    @Test func testInstallExplainsUnsupportedAtomicSwapAndPreservesPreviousApp() throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        let commands = fixture.appendingPathComponent("commands")
        let destination = fixture.appendingPathComponent("Applications")
        let previous = destination.appendingPathComponent("Polaris.app")
        let candidate = fixture.appendingPathComponent("build/Polaris.app")
        for directory in [scripts, commands, previous, candidate] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/install.sh"), to: scripts.appendingPathComponent("install.sh"))
        try Data("previous".utf8).write(to: previous.appendingPathComponent("marker"))
        try Data("candidate".utf8).write(to: candidate.appendingPathComponent("marker"))
        // Inject only the OS call boundary; execute the real installer Python body.
        let injector = fixture.appendingPathComponent("polaris-test-unsupported-swap.py")
        try Data("""
        import ctypes
        import errno
        import sys
        class UnsupportedRename:
            def __call__(self, *args):
                ctypes.set_errno(errno.ENOTSUP)
                return -1
        class Library:
            renamex_np = UnsupportedRename()
        ctypes.CDLL = lambda *args, **kwargs: Library()
        sys.argv = sys.argv[1:]
        exec(compile(sys.stdin.read(), '<installer>', 'exec'))
        """.utf8).write(to: injector)
        try script("#!/bin/sh\nexec /usr/bin/python3 " + ShellCommand.quote(injector.path) + " \"$@\"\n", at: commands.appendingPathComponent("python3"))

        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("install.sh").path], environment: [
            "INSTALL_DIR": destination.path, "PATH": commands.path + ":/usr/bin:/bin"
        ])

        #expect(result.status != 0)
        #expect(result.output.contains("APFS"), "\(result.output)")
        #expect(try String(contentsOf: previous.appendingPathComponent("marker"), encoding: .utf8) == "previous")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Polaris.app"])
    }

    @Test func testCIUsesPinnedRunnerCheckoutAndBoundedPullRequestJobs() throws {
        let parsed = try run("/usr/bin/ruby", arguments: ["-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", root.appendingPathComponent(".github/workflows/ci.yml").path])
        #expect(parsed.status == 0, "\(parsed.output)")
        let workflow = try #require(JSONSerialization.jsonObject(with: Data(parsed.output.utf8)) as? [String: Any])
        // Ruby's YAML 1.1 parser reads the GitHub Actions `on` key as true.
        let events = try #require((workflow["on"] ?? workflow["true"]) as? [String: Any])
        let push = try #require(events["push"] as? [String: Any])
        #expect(push["branches"] as? [String] == ["main"])
        #expect(events.keys.contains("pull_request"))
        let jobs = try #require(workflow["jobs"] as? [String: [String: Any]])
        let job = try #require(jobs["test"])
        #expect(job["runs-on"] as? String == "macos-15")
        let timeout = try #require(job["timeout-minutes"] as? Int)
        #expect(timeout > 0 && timeout <= 60)
        let concurrency = try #require((workflow["concurrency"] ?? job["concurrency"]) as? [String: Any])
        #expect(concurrency["cancel-in-progress"] as? Bool == true)
        #expect((concurrency["group"] as? String)?.contains("github.ref") == true)
        let steps = try #require(job["steps"] as? [[String: Any]])
        let checkout = try #require(steps.compactMap { $0["uses"] as? String }.first { $0.hasPrefix("actions/checkout@") })
        #expect(checkout.range(of: #"^actions/checkout@[a-f0-9]{40}$"#, options: .regularExpression) != nil)
        let selection = try #require(steps.compactMap { $0["run"] as? String }.first { $0.contains("xcode-select") })
        #expect(selection.contains("/Applications/Xcode_"))

        // Missing Xcode must abort before requesting elevated selection.
        let fixture = try home()
        let commands = fixture.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let selected = fixture.appendingPathComponent("polaris-test-selected")
        for command in ["sudo", "xcode-select"] {
            try script("#!/bin/sh\ntouch " + ShellCommand.quote(selected.path) + "\n", at: commands.appendingPathComponent(command))
        }
        let absent = selection.replacingOccurrences(of: "/Applications/", with: fixture.appendingPathComponent("missing").path + "/")
        let result = try run("/bin/bash", arguments: ["-e", "-c", absent], environment: ["PATH": commands.path + ":/usr/bin:/bin"])
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: selected.path))
    }

    @Test(arguments: [0, 3]) func testTestScriptRejectsZeroSwiftTestingCases(count: Int) throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        let commands = fixture.appendingPathComponent("commands")
        for directory in [scripts, commands] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/test.sh"), to: scripts.appendingPathComponent("test.sh"))
        try script("#!/bin/sh\nprintf '%s\\n' '/Applications/Xcode.app/Contents/Developer'\n", at: commands.appendingPathComponent("xcode-select"))
        try script("#!/bin/sh\nprintf '%s\\n' '✔ Test run with \(count) tests passed after 0.01 seconds.'\n", at: commands.appendingPathComponent("swift"))

        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("test.sh").path], environment: ["PATH": commands.path + ":/usr/bin:/bin"])

        #expect((result.status == 0) == (count > 0), "\(result.output)")
    }

    @Test(arguments: [false, true], [false, true]) func testBundleUsesExplicitIdentityAndGitBuildNumberDefaults(overrides: Bool, gitAvailable: Bool) throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        let commands = fixture.appendingPathComponent("commands")
        let binaries = fixture.appendingPathComponent("binaries")
        let core = fixture.appendingPathComponent("Sources/PolarisCore")
        for directory in [scripts, commands, binaries, core] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/bundle.sh"), to: scripts.appendingPathComponent("bundle.sh"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("Sources/PolarisCore/PolarisVersion.swift"), to: core.appendingPathComponent("PolarisVersion.swift"))
        for name in ["PolarisApp", "polaris-mcp"] { try Data(name.utf8).write(to: binaries.appendingPathComponent(name)) }
        try script("""
        #!/bin/sh
        case " $* " in
          *" --show-bin-path "*) printf '%s\n' "$POLARIS_TEST_BIN_DIR" ;;
        esac
        """, at: commands.appendingPathComponent("swift"))
        try script("""
        #!/bin/sh
        printf '%s\n' "$*" >> "$POLARIS_TEST_CODESIGN_LOG"
        """, at: commands.appendingPathComponent("codesign"))
        try script(gitAvailable
            ? "#!/bin/sh\n[ \"$*\" = 'rev-list --count HEAD' ] || exit 2\nprintf '%s\\n' 137\n"
            : "#!/bin/sh\nexit 127\n", at: commands.appendingPathComponent("git"))
        let log = fixture.appendingPathComponent("polaris-test-codesign.log")
        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("bundle.sh").path], environment: [
            "PATH": commands.path + ":/usr/bin:/bin",
            "POLARIS_TEST_BIN_DIR": binaries.path,
            "POLARIS_TEST_CODESIGN_LOG": log.path,
            "VERSION": overrides ? "2.4.6" : "",
            "BUILD_NUMBER": overrides ? "42" : "",
            "BUNDLE_IDENTIFIER": overrides ? "org.example.polaris" : "",
            "SIGNING_IDENTITY": overrides ? "Developer ID Application: Explicit" : ""
        ])
        #expect(result.status == 0, "\(result.output)")
        let plist = fixture.appendingPathComponent("build/Polaris.app/Contents/Info.plist")
        let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == (overrides ? "org.example.polaris" : "dev.mimo.polaris"))
        #expect(info["CFBundleVersion"] as? String == (overrides ? "42" : (gitAvailable ? "137" : "1")))
        #expect(PolarisVersion.version(infoPlistURL: plist) == (overrides ? "2.4.6" : PolarisVersion.defaultVersion))
        let signing = try String(contentsOf: log, encoding: .utf8)
        #expect(signing.contains(overrides ? "--sign Developer ID Application: Explicit" : "--sign -"))
        #expect(signing.contains("--timestamp") == overrides)
    }

    @Test(arguments: ["", "-"]) func testReleaseRejectsMissingOrAdHocIdentityBeforeBuilding(identity: String) throws {
        let fixture = try home()
        let scripts = fixture.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/release.sh"), to: scripts.appendingPathComponent("release.sh"))
        let marker = fixture.appendingPathComponent("polaris-test-built")
        try script("#!/bin/sh\ntouch " + ShellCommand.quote(marker.path) + "\n", at: scripts.appendingPathComponent("bundle.sh"))
        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("release.sh").path], environment: ["SIGNING_IDENTITY": identity])
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

}
