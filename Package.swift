// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Standalone Command Line Tools ship Testing.framework outside SwiftPM's default search path.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let selection = Process()
selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
selection.arguments = ["-p"]
let selectedOutput = Pipe()
selection.standardOutput = selectedOutput
selection.standardError = FileHandle.nullDevice
try? selection.run()
selection.waitUntilExit()
let selectedDeveloper = String(data: selectedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
let useCLTTesting = selectedDeveloper == "/Library/Developer/CommandLineTools" && FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwiftSettings: [SwiftSetting] = useCLTTesting ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkerSettings: [LinkerSetting] = useCLTTesting ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"])] : []

let package = Package(
    name: "Polaris",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PolarisCore", targets: ["PolarisCore"]),
        .executable(name: "PolarisApp", targets: ["PolarisApp"]),
        .executable(name: "polaris-mcp", targets: ["polaris-mcp"])
    ],
    targets: [
        .target(name: "PolarisCore"),
        .target(name: "PolarisMCP", dependencies: ["PolarisCore"]),
        .executableTarget(name: "PolarisApp", dependencies: ["PolarisCore"]),
        .executableTarget(name: "polaris-mcp", dependencies: ["PolarisMCP"]),
        .testTarget(name: "PolarisCoreTests", dependencies: ["PolarisCore"], swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "PolarisMCPTests", dependencies: ["PolarisMCP"], swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "PolarisAppTests", dependencies: ["PolarisApp"], swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings)
    ],
    swiftLanguageModes: [.v6]
)
