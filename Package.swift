// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "quill",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                "WebRTCAudio",
            ],
            exclude: ["AppIcon.icns", "AppIcon.svg", "Info.plist", "quill.entitlements"],
            linkerSettings: [
                // Keeps `swift run` and the raw binary working: TCC can still
                // attribute microphone and system-audio capture without the
                // .app wrapper that bundle.sh builds for a real install.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/quill/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .target(
            name: "WebRTCAudio",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("webrtc_audio"),
                .headerSearchPath("webrtc_audio/audio_processing"),
                .headerSearchPath("webrtc_audio/audio_processing/logging"),
                .headerSearchPath("webrtc_audio/abseil"),
                .define("WEBRTC_POSIX"),
                .define("WEBRTC_MAC"),
                .unsafeFlags(["-include", "compat_includes.h"]),
            ],
            cxxSettings: [
                .headerSearchPath("webrtc_audio"),
                .headerSearchPath("webrtc_audio/audio_processing"),
                .headerSearchPath("webrtc_audio/audio_processing/logging"),
                .headerSearchPath("webrtc_audio/abseil"),
                .define("WEBRTC_POSIX"),
                .define("WEBRTC_MAC"),
                .unsafeFlags([
                    "-include", "compat_includes.h",
                    "-Wno-deprecated-builtins", "-Wno-deprecated-declarations",
                    "-Wno-unused-variable",
                ]),
            ]
        ),
        .testTarget(
            name: "quillTests",
            dependencies: ["quill"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
