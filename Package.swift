// swift-tools-version: 5.9
import PackageDescription

var modelSources = ["PocketEngine.swift", "StudyModels.swift", "StudyHistory.swift", "ContentImportTransaction.swift",
    "ExamModels.swift", "ExamLearningEngine.swift", "ConceptStudy.swift", "ConceptTeaching.swift",
    "ConceptGuidance.swift", "ConceptGuidanceStore.swift", "ConceptDiagram.swift", "ConceptSyllabus.swift", "RecallStudy.swift", "MathPractice.swift"]
var modelExcludes = ["StudyApp.swift", "StudyStore.swift", "BluetoothLink.swift", "DurableFile.swift",
    "Info.plist", "Assets.xcassets", "ExamStore.swift", "ExamView.swift", "ConceptStore.swift", "ConceptView.swift",
    "StudyFlow.swift", "StudyHomeView.swift", "ConceptGuidanceView.swift", "ConceptDiagramView.swift", "ConceptSyllabusTreeView.swift", "RecallStore.swift", "RecallView.swift", "MathStore.swift", "MathView.swift"]
#if os(macOS)
// Exercise real import/persistence against temporary directories on the build host.
modelSources += ["ConceptStore.swift", "DurableFile.swift", "StudyFlow.swift", "RecallStore.swift", "MathStore.swift"]
modelExcludes.removeAll { ["ConceptStore.swift", "DurableFile.swift", "StudyFlow.swift", "RecallStore.swift", "MathStore.swift"].contains($0) }
#endif

let package = Package(
    name: "XKLStudy",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CPocket", targets: ["CPocket"]),
        .library(name: "StudyCore", targets: ["StudyCore"])
    ],
    targets: [
        .target(name: "CPocket", path: "Sources/CPocket", exclude: ["source-manifest.json", "SNAPSHOT_FORMAT.md", "UPSTREAM-LICENSE.txt"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("internal")]),
        .target(name: "StudyCore", path: "Sources/StudyCore"),
        .target(name: "StudyClientModel", dependencies: ["StudyCore", "CPocket"], path: "App",
                exclude: modelExcludes, sources: modelSources),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"], path: "Tests/StudyCoreTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "StudyIntegrationTests", dependencies: ["StudyCore", "CPocket"], path: "Tests/StudyIntegrationTests"),
        .testTarget(name: "StudyClientModelTests", dependencies: ["StudyClientModel", "CPocket"], path: "Tests/StudyClientModelTests")
    ],
    swiftLanguageVersions: [.v5],
    cLanguageStandard: .c11
)
