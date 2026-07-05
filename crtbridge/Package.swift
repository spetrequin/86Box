// swift-tools-version: 5.9
import PackageDescription
import Foundation

// CRTBridge — the C-ABI bridge that lets 86Box's C++/Obj-C++ Metal renderer drive
// the Swift CRTEngine. It lives in the 86Box tree (not CRTEngine) because it is
// 86Box-integration glue, not core engine code, and it uses ONLY CRTEngine's
// public API + resource bundle so CRTEngine needs no modifications.
//
// It depends on CRTEngine by path. 86Box's CMake passes the location via the
// CRTENGINE_DIR environment variable; otherwise it falls back to the sibling
// checkout layout (…/Code/Swift/CRTEngine relative to …/Code/C/86Box/crtbridge).
let crtEnginePath = ProcessInfo.processInfo.environment["CRTENGINE_DIR"]
    ?? "../../../Swift/CRTEngine"

let package = Package(
    name: "CRTBridge",
    platforms: [.macOS(.v13)],
    products: [
        // Dynamic so 86Box's CMake links it as an ordinary dylib; the Swift
        // runtime resolves via rpath to the OS /usr/lib/swift.
        .library(name: "CRTBridgeC", type: .dynamic, targets: ["CRTBridgeC"]),
    ],
    dependencies: [
        .package(path: crtEnginePath),
    ],
    targets: [
        .target(
            name: "CRTBridgeC",
            dependencies: [.product(name: "CRTEngine", package: "CRTEngine")],
            path: "Sources/CRTBridgeC",
            // crt_bridge.h is the C deliverable for 86Box, not a SwiftPM input.
            exclude: ["include/crt_bridge.h"]
        ),
    ]
)
