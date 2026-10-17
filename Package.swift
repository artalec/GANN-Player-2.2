// swift-tools-version: 6.0
// Xcode 16 (Swift 6.0). Языковой режим остаётся Swift 5, чтобы переход не
// превратился в переписывание всего кода под строгий параллелизм.

import PackageDescription

let package = Package(
    name: "DJPlayer",
    // Версия платформы должна совпадать с LSMinimumSystemVersion в Resources/Info.plist,
    // иначе приложение запускается на системе, где нужных символов нет, и падает при старте.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DJPlayer", targets: ["DJPlayer"]),
        // Модели и хранилище вынесены в отдельный модуль: он не зависит от
        // AppKit/SwiftUI, поэтому его можно покрыть обычными юнит-тестами.
        .library(name: "DJPlayerCore", targets: ["DJPlayerCore"])
    ],
    targets: [
        .target(
            name: "DJPlayerCore",
            path: "Sources/DJPlayerCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "DJPlayer",
            dependencies: ["DJPlayerCore"],
            path: "Sources/DJPlayer",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "DJPlayerCoreTests",
            dependencies: ["DJPlayerCore"],
            path: "Tests/DJPlayerCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
