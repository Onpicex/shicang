// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ShicangCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ShicangCore", targets: ["ShicangCore"]),
        .executable(name: "shicang", targets: ["shicang"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "ShicangCore",
            dependencies: ["SwiftSoup"],
            resources: [.copy("Resources/Readability.js")]
        ),
        // 命令行：无界面跑提取 / 队列回归（不碰 iCloud，用临时目录）
        .executableTarget(name: "shicang", dependencies: ["ShicangCore"]),
        .testTarget(name: "ShicangCoreTests", dependencies: ["ShicangCore"]),
    ]
)
