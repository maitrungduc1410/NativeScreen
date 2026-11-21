// swift-tools-version:5.9
// whisper.cpp (MIT) as a prebuilt framework, for captions in languages the system speech recognizer lacks.
// To update: pick a release on github.com/ggml-org/whisper.cpp that matches a tagged version, then replace the URL and
// set the checksum to `swift package compute-checksum whisper-<build>-xcframework.zip`.
import PackageDescription

let package = Package(
    name: "WhisperCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        // b5454 is the build of tag v1.9.5.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        )
    ]
)
