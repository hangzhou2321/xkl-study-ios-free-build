"""Generate a dependency-free Xcode project; no Apple account or network needed."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]

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
    app_info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    version_settings = {
        "MARKETING_VERSION": app_info["CFBundleShortVersionString"],
        "CURRENT_PROJECT_VERSION": app_info["CFBundleVersion"],
    }
    sources, refs, app_children, resource_children, resource_builds = [], {}, [], [], []
    for path in sorted((ROOT / "App").glob("*.swift")):
        ref = add(path.relative_to(ROOT).as_posix(), "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
        app_children.append(ref)
        refs[path.name] = ref
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
    widget_name = "StudyPaceWidget"
    widget_source = add("widget-source", "PBXFileReference", lastKnownFileType="sourcecode.swift", path=widget_name + ".swift", sourceTree="<group>")
    widget_info = add("widget-info", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>")
    widget = add("widget-group", "PBXGroup", children=[widget_source, widget_info], path=widget_name, sourceTree="<group>")
    widget_product = add("widget-product", "PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex=0, path=widget_name + ".appex", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", "PBXGroup", children=[product, widget_product], name="Products", sourceTree="<group>")
    group = add("group", "PBXGroup", children=[app, widget, resources, products], sourceTree="<group>")
    package = add("localpackage", "XCLocalSwiftPackageReference", relativePath=".")
    dependencies, framework_files = [], []
    for name in ("CPocket", "StudyCore"):
        ref = add("package-" + name, "XCSwiftPackageProductDependency", package=package, productName=name)
        dependencies.append(ref)
        framework_files.append(add("framework-" + name, "PBXBuildFile", productRef=ref))
    source_phase = add("sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
    resource_phase = add("resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
    framework_phase = add("frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=framework_files, runOnlyForDeploymentPostprocessing=0)
    widget_builds = [add("build-widget", "PBXBuildFile", fileRef=widget_source),
                     add("widget-activity-attributes", "PBXBuildFile", fileRef=refs["StudyPaceActivityAttributes.swift"])]
    widget_sources = add("widget-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=widget_builds, runOnlyForDeploymentPostprocessing=0)
    embedded = add("embed-widget-product", "PBXBuildFile", fileRef=widget_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy", "CodeSignOnCopy"]})
    embed_phase = add("embed-widget", "PBXCopyFilesBuildPhase", name="Embed App Extensions", dstPath="", dstSubfolderSpec=13,
                      buildActionMask=2147483647, files=[embedded], runOnlyForDeploymentPostprocessing=0)
    project_configs, target_configs, widget_configs = [], [], []
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
            "GENERATE_INFOPLIST_FILE": "NO", **version_settings,
            "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1,2",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "CODE_SIGN_STYLE": "Automatic",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "SWIFT_EMIT_LOC_STRINGS": "YES",
        }))
        widget_configs.append(add("widget-" + config, "XCBuildConfiguration", name=config, buildSettings={
            "PRODUCT_NAME": widget_name, "PRODUCT_BUNDLE_IDENTIFIER": "local.xkl.study.pace",
            "INFOPLIST_FILE": "StudyPaceWidget/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", **version_settings,
            "SKIP_INSTALL": "YES", "APPLICATION_EXTENSION_API_ONLY": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
            "CODE_SIGN_STYLE": "Automatic",
        }))
    pcl = add("project-configs", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    tcl = add("target-configs", "XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    wcl = add("widget-configs", "XCConfigurationList", buildConfigurations=widget_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    widget_target = add("widget-target", "PBXNativeTarget", buildConfigurationList=wcl, buildPhases=[widget_sources],
                        buildRules=[], dependencies=[], name=widget_name, productName=widget_name,
                        productReference=widget_product, productType="com.apple.product-type.app-extension")
    proxy = add("widget-proxy", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1,
                remoteGlobalIDString=widget_target, remoteInfo=widget_name)
    dependency = add("widget-dependency", "PBXTargetDependency", target=widget_target, targetProxy=proxy)
    target = add("target", "PBXNativeTarget", buildConfigurationList=tcl, buildPhases=[source_phase, framework_phase, resource_phase, embed_phase], buildRules=[], dependencies=[dependency], name="XKLStudy", packageProductDependencies=dependencies, productName="XKLStudy", productReference=product, productType="com.apple.product-type.application")
    project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "16.0"}}}, buildConfigurationList=pcl, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["en", "Base", "zh-Hans"], mainGroup=group, packageReferences=[package], productRefGroup=products, projectDirPath="", projectRoot="", targets=[target, widget_target])
    directory = ROOT / "XKLStudy.xcodeproj"
    directory.mkdir(exist_ok=True)
    (directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + plist({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n", encoding="utf-8")
    scheme_dir = directory / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="XKLStudy.app" BlueprintName="XKLStudy" ReferencedContainer="container:XKLStudy.xcodeproj"/>'
    (scheme_dir / "XKLStudy.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
    print(json.dumps({"project": "XKLStudy.xcodeproj", "swiftFiles": len(sources), "personalResourcesIncluded": bool(resource_children)}))

if __name__ == "__main__":
    main()
