// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TorusDrawingClient",
    platforms: [.macOS(.v12), .iOS(.v15), .visionOS(.v1)],
    products: [
        .library(name: "TorusDrawingClient", targets: ["TorusDrawingClient"]),
        .executable(name: "torus-client", targets: ["TorusCLI"])
    ],
    targets: [
        .target(name: "TorusDrawingClient"),
        .executableTarget(name: "TorusCLI", dependencies: ["TorusDrawingClient"]),
        .testTarget(name: "TorusDrawingClientTests", dependencies: ["TorusDrawingClient"])
    ]
)
