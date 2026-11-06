"""Generate a dependency-free Xcode project; no Apple account or network needed."""
from pathlib import Path
import argparse
import hashlib
import json
import os
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]

def uid(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()

def plist(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + plist(k) + " = " + plist(v, level + 1) + ";\n"
                                 for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (level + 1) + plist(v, level + 1) + ",\n" for v in value) + "\t" * level + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--without-personal-resources", action="store_true")
    args = ap.parse_args()
    objects = {}
    def add(label, isa, **values):
        key = uid(label)
        objects[key] = {"isa": isa, **values}
        return key
    sources, app_children, resource_children, resource_builds = [], [], [], []
    for path in sorted((ROOT / "App").glob("*.swift")):
        ref = add(str(path.relative_to(ROOT)), "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
        app_children.append(ref)
        sources.append(add("build-" + path.name, "PBXBuildFile", fileRef=ref))
    app_children.append(add("info", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
    assets = ROOT / "App/Assets.xcassets"
    if assets.exists():
        ref = add("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="<group>")
        app_children.append(ref)
        resource_builds.append(add("build-assets", "PBXBuildFile", fileRef=ref))
    renderer = ROOT / "App/MathRenderer"
    if renderer.exists():
        ref = add("mathrenderer", "PBXFileReference", lastKnownFileType="folder", path="MathRenderer", sourceTree="<group>")
        app_children.append(ref)
        resource_builds.append(add("build-mathrenderer", "PBXBuildFile", fileRef=ref))
    if not args.without_personal_resources:
        for name in ("deck.json", "personal-state.bin", "resource-manifest.json"):
            if not (ROOT / "Resources" / name).exists():
                continue
            ref = add("resource-" + name, "PBXFileReference", lastKnownFileType="text.json" if name.endswith("json") else "file", path=name, sourceTree="<group>")
            resource_children.append(ref)
            resource_builds.append(add("build-" + name, "PBXBuildFile", fileRef=ref))
    app = add("appgroup", "PBXGroup", children=app_children, path="App", sourceTree="<group>")
    resources = add("resourcegroup", "PBXGroup", children=resource_children, path="Resources", sourceTree="<group>")
    product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="XKLStudy.app", sourceTree="BUILT_PRODUCTS_DIR")
    test_source = add("guide-ui-test-source", "PBXFileReference", lastKnownFileType="sourcecode.swift", path="GuideDisclosureUITests.swift", sourceTree="<group>")
    test_group = add("guide-ui-test-group", "PBXGroup", children=[test_source], path="tools/guide_ui_test", sourceTree="<group>")
    test_product = add("guide-ui-test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="GuideDisclosureUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", "PBXGroup", children=[product, test_product], name="Products", sourceTree="<group>")
    group = add("group", "PBXGroup", children=[app, resources, test_group, products], sourceTree="<group>")
    package = add("localpackage", "XCLocalSwiftPackageReference", relativePath=".")
    dependencies, framework_files = [], []
    for name in ("CPocket", "StudyCore"):
        ref = add("package-" + name, "XCSwiftPackageProductDependency", package=package, productName=name)
        dependencies.append(ref)
        framework_files.append(add("framework-" + name, "PBXBuildFile", productRef=ref))
    source_phase = add("sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
    resource_phase = add("resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
    framework_phase = add("frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=framework_files, runOnlyForDeploymentPostprocessing=0)
    project_configs, target_configs = [], []
    for config in ("Debug", "Release"):
        project_configs.append(add("project-" + config, "XCBuildConfiguration", name=config, buildSettings={
            "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "GCC_C_LANGUAGE_STANDARD": "gnu11", "SDKROOT": "iphoneos", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if config == "Debug" else "",
        }))
        target_configs.append(add("target-" + config, "XCBuildConfiguration", name=config, buildSettings={
            "PRODUCT_NAME": "XKLStudy", "PRODUCT_BUNDLE_IDENTIFIER": "local.xkl.study", "INFOPLIST_FILE": "App/Info.plist",
            "GENERATE_INFOPLIST_FILE": "NO", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
            "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1,2",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "CODE_SIGN_STYLE": "Automatic",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "SWIFT_EMIT_LOC_STRINGS": "YES",
        }))
    pcl = add("project-configs", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    tcl = add("target-configs", "XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = add("target", "PBXNativeTarget", buildConfigurationList=tcl, buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[], name="XKLStudy", packageProductDependencies=dependencies, productName="XKLStudy", productReference=product, productType="com.apple.product-type.application")
    test_build = add("guide-ui-test-build", "PBXBuildFile", fileRef=test_source)
    test_sources = add("guide-ui-test-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[test_build], runOnlyForDeploymentPostprocessing=0)
    test_frameworks = add("guide-ui-test-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    test_configs = []
    for config in ("Debug", "Release"):
        test_configs.append(add("guide-ui-test-" + config, "XCBuildConfiguration", name=config, buildSettings={
            "PRODUCT_NAME": "GuideDisclosureUITests", "PRODUCT_BUNDLE_IDENTIFIER": "local.xkl.study.guideuitests",
            "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "XKLStudy", "SWIFT_VERSION": "5.0",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphonesimulator"
        }))
    test_config_list = add("guide-ui-test-configs", "XCConfigurationList", buildConfigurations=test_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
    test_proxy = add("guide-ui-test-proxy", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1, remoteGlobalIDString=target, remoteInfo="XKLStudy")
    test_dependency = add("guide-ui-test-dependency", "PBXTargetDependency", target=target, targetProxy=test_proxy)
    test_target = add("guide-ui-test-target", "PBXNativeTarget", buildConfigurationList=test_config_list, buildPhases=[test_sources, test_frameworks], buildRules=[], dependencies=[test_dependency], name="GuideDisclosureUITests", productName="GuideDisclosureUITests", productReference=test_product, productType="com.apple.product-type.bundle.ui-testing")
    project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "16.0"}, test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": target}}}, buildConfigurationList=pcl, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["en", "Base", "zh-Hans"], mainGroup=group, packageReferences=[package], productRefGroup=products, projectDirPath="", projectRoot="", targets=[target, test_target])
    directory = ROOT / "XKLStudy.xcodeproj"
    directory.mkdir(exist_ok=True)
    (directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + plist({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n", encoding="utf-8")
    scheme_dir = directory / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="XKLStudy.app" BlueprintName="XKLStudy" ReferencedContainer="container:XKLStudy.xcodeproj"/>'
    test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="GuideDisclosureUITests.xctest" BlueprintName="GuideDisclosureUITests" ReferencedContainer="container:XKLStudy.xcodeproj"/>'
    fallback = escape(os.environ.get("GUIDE_TEST_DYLD_FALLBACK", ""), {'"': '&quot;'})
    (scheme_dir / "XKLStudy.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_reference}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO">{test_reference}</TestableReference></Testables><EnvironmentVariables><EnvironmentVariable key="GUIDE_TEST_DYLD_FALLBACK" value="{fallback}" isEnabled="YES"/></EnvironmentVariables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
    print(json.dumps({"project": "XKLStudy.xcodeproj", "swiftFiles": len(sources), "personalResourcesIncluded": bool(resource_children)}))

if __name__ == "__main__":
    main()
