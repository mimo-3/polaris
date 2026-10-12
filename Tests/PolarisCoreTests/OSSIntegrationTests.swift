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
        let directory = root.appendingPathComponent("oss-fix-integration-\(UUID().uuidString)")
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
        let marker = directory.appendingPathComponent("oss-fix-injected")
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

    @Test(arguments: [false, true]) func testBundleUsesExplicitIdentityAndSharedVersionDefaults(overrides: Bool) throws {
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
          *" --show-bin-path "*) printf '%s\n' "$OSS_FIX_BIN_DIR" ;;
        esac
        """, at: commands.appendingPathComponent("swift"))
        try script("""
        #!/bin/sh
        printf '%s\n' "$*" >> "$OSS_FIX_CODESIGN_LOG"
        """, at: commands.appendingPathComponent("codesign"))
        let log = fixture.appendingPathComponent("oss-fix-codesign.log")
        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("bundle.sh").path], environment: [
            "PATH": commands.path + ":/usr/bin:/bin",
            "OSS_FIX_BIN_DIR": binaries.path,
            "OSS_FIX_CODESIGN_LOG": log.path,
            "VERSION": overrides ? "2.4.6" : "",
            "BUILD_NUMBER": overrides ? "42" : "",
            "BUNDLE_IDENTIFIER": overrides ? "org.example.polaris" : "",
            "SIGNING_IDENTITY": overrides ? "Developer ID Application: Explicit" : ""
        ])
        #expect(result.status == 0, "\(result.output)")
        let plist = fixture.appendingPathComponent("build/Polaris.app/Contents/Info.plist")
        let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == (overrides ? "org.example.polaris" : "dev.mimo.polaris"))
        #expect(info["CFBundleVersion"] as? String == (overrides ? "42" : "1"))
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
        let marker = fixture.appendingPathComponent("oss-fix-built")
        try script("#!/bin/sh\ntouch " + ShellCommand.quote(marker.path) + "\n", at: scripts.appendingPathComponent("bundle.sh"))
        let result = try run("/bin/bash", arguments: [scripts.appendingPathComponent("release.sh").path], environment: ["SIGNING_IDENTITY": identity])
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

}
