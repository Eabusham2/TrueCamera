// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TrueCameraCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TrueCameraCore", targets: ["TrueCameraCore"])],
    targets: [
        .target(name: "TrueCameraCore", path: "Core"),
        .testTarget(name: "TrueCameraCoreTests", dependencies: ["TrueCameraCore"], path: "Tests/TrueCameraCoreTests")
    ]
)
