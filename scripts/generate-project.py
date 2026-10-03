#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
# CarPlay lists the app only with an entitlement Apple grants to a team on request. Until the team has it, a build
# for a device that asked for it would not sign, so only the simulator, which asks for no grant, carries it.
CARPLAY_ON_DEVICE = False
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def put(name, value):
    key = ident(name); objects[key] = value; return key

def q(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
def settings(values): return '{' + ''.join(f'{q(k) if "[" in k else k} = {q(v)}; ' for k, v in values.items()) + '}'
def config_list(name, values):
    ids = []
    for kind in ['Debug', 'Release']:
        vals = dict(values)
        vals['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if kind == 'Debug' else '-O'
        vals['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if kind == 'Debug' else 'dwarf-with-dsym'
        if kind == 'Debug': vals['ENABLE_TESTABILITY'] = 'YES'; vals['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(put(name+kind, f'{{isa = XCBuildConfiguration; buildSettings = {settings(vals)}; name = {kind};}}'))
    return put(name+'configs', '{isa = XCConfigurationList; buildConfigurations = ('+','.join(ids)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')

def files(folder, target=''):
    """`target` keeps the build files of a folder two targets compile apart: an Xcode build file belongs to one target."""
    children = []; builds = []; resources = []
    for path in sorted((root / folder).rglob('*')):
        if not path.is_file() or '.xcassets/' in str(path): continue
        rel = str(path.relative_to(root)); ext = path.suffix
        kind = {'.swift':'sourcecode.swift', '.plist':'text.plist.xml', '.xcprivacy':'text.xml', '.entitlements':'text.plist.entitlements'}.get(ext, 'text')
        ref = put(rel, f'{{isa = PBXFileReference; lastKnownFileType = {q(kind)}; path = {q(rel)}; sourceTree = SOURCE_ROOT;}}'); children.append(ref)
        if ext in ['.swift', '.xcprivacy']:
            build = put(rel+'build'+target, f'{{isa = PBXBuildFile; fileRef = {ref};}}')
            (builds if ext == '.swift' else resources).append(build)
    assets = root / folder / 'Assets.xcassets'
    if assets.exists():
        ref = put(str(assets.relative_to(root)), f'{{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {q(str(assets.relative_to(root)))}; sourceTree = SOURCE_ROOT;}}')
        children.append(ref); resources.append(put(str(assets.relative_to(root))+'build', f'{{isa = PBXBuildFile; fileRef = {ref};}}'))
    group = put(folder, f'{{isa = PBXGroup; children = ({",".join(children)},); name = {q(folder)}; sourceTree = "<group>";}}')
    return group, builds, resources

def phase(name, isa, builds): return put(name, f'{{isa = {isa}; buildActionMask = 2147483647; files = ({",".join(builds)}{"," if builds else ""}); runOnlyForDeploymentPostprocessing = 0;}}')
appgroup, appfiles, resources = files('App')
# The iPhone and iPad app runs on the Mac app's core (Mac/Core): one client for the client API (/api/v1) in both.
_, corefiles, _ = files('Mac/Core', target='ios')
testgroup, testfiles, _ = files('UITests')
macgroup, macfiles, macresources = files('Mac')
appref = put('appProduct', '{isa = PBXFileReference; explicitFileType = wrapper.application; path = Briareus.app; sourceTree = BUILT_PRODUCTS_DIR;}')
macref = put('macProduct', '{isa = PBXFileReference; explicitFileType = wrapper.application; path = Briareus.app; sourceTree = BUILT_PRODUCTS_DIR;}')
testref = put('testProduct', '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = BriareusUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;}')
products = put('Products', f'{{isa = PBXGroup; children = ({appref},{macref},{testref},); name = Products; sourceTree = "<group>";}}')
main = put('main', f'{{isa = PBXGroup; children = ({appgroup},{macgroup},{testgroup},{products},); sourceTree = "<group>";}}')
base = {'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'MACOSX_DEPLOYMENT_TARGET':'14.0', 'SDKROOT':'iphoneos', 'SWIFT_VERSION':'5.0', 'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES', 'GCC_C_LANGUAGE_STANDARD':'gnu17'}
projectconfigs = config_list('project', base)
appconfigs = config_list('app', {'PRODUCT_BUNDLE_IDENTIFIER':'com.okanetsolutions.briareus', 'PRODUCT_NAME':'Briareus', 'INFOPLIST_FILE':'App/Info.plist', 'TARGETED_DEVICE_FAMILY':'1,2', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'WG98W262CP', 'MARKETING_VERSION':'1.0', 'CURRENT_PROJECT_VERSION':'1', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
    # The iPhone and iPad app only: the Mac has an app of its own (Mac/), the Windows client's twin.
    'SUPPORTS_MACCATALYST':'NO', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO',
    'CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]':'App/Briareus-CarPlay.entitlements',
    **({'CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]':'App/Briareus-CarPlay.entitlements'} if CARPLAY_ON_DEVICE else {})})
# The Mac app: its own sources on the client API (/api/v1), laid out as the Windows client is.
macconfigs = config_list('mac', {'PRODUCT_BUNDLE_IDENTIFIER':'com.okanetsolutions.briareus', 'PRODUCT_NAME':'Briareus', 'SDKROOT':'macosx', 'SUPPORTED_PLATFORMS':'macosx', 'INFOPLIST_FILE':'Mac/Info.plist', 'CODE_SIGN_ENTITLEMENTS':'Mac/Briareus.entitlements', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'WG98W262CP', 'MARKETING_VERSION':'1.0', 'CURRENT_PROJECT_VERSION':'1', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'ENABLE_HARDENED_RUNTIME':'YES', 'COMBINE_HIDPI_IMAGES':'YES', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
testconfigs = config_list('tests', {'PRODUCT_BUNDLE_IDENTIFIER':'com.okanetsolutions.briareus.uitests', 'PRODUCT_NAME':'BriareusUITests', 'GENERATE_INFOPLIST_FILE':'YES', 'TEST_TARGET_NAME':'Briareus', 'TARGETED_DEVICE_FAMILY':'1,2', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'WG98W262CP', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
# The app's one dependency: Google's WebRTC, built as a binary Swift package, which carries the voice mode's audio to
# GPT-Realtime and back with its own echo cancellation, jitter buffer and audio session handling.
webrtcpackage = put('webrtcPackage', '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/stasel/WebRTC"; requirement = {kind = exactVersion; version = "154.0.0";};}')
webrtc = put('webrtcProduct', f'{{isa = XCSwiftPackageProductDependency; package = {webrtcpackage}; productName = WebRTC;}}')
webrtcbuild = put('webrtcBuild', f'{{isa = PBXBuildFile; productRef = {webrtc};}}')
phases = [phase('appSources','PBXSourcesBuildPhase',appfiles+corefiles),phase('appFrameworks','PBXFrameworksBuildPhase',[webrtcbuild]),phase('appResources','PBXResourcesBuildPhase',resources)]
apptarget = put('appTarget', f'{{isa = PBXNativeTarget; buildConfigurationList = {appconfigs}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = (); packageProductDependencies = ({webrtc},); name = Briareus; productName = Briareus; productReference = {appref}; productType = "com.apple.product-type.application";}}')
macphases = [phase('macSources','PBXSourcesBuildPhase',macfiles),phase('macFrameworks','PBXFrameworksBuildPhase',[]),phase('macResources','PBXResourcesBuildPhase',macresources)]
mactarget = put('macTarget', f'{{isa = PBXNativeTarget; buildConfigurationList = {macconfigs}; buildPhases = ({",".join(macphases)},); buildRules = (); dependencies = (); name = "Briareus Mac"; productName = Briareus; productReference = {macref}; productType = "com.apple.product-type.application";}}')
proxy = put('proxy', f'{{isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {apptarget}; remoteInfo = Briareus;}}')
dep = put('dep', f'{{isa = PBXTargetDependency; target = {apptarget}; targetProxy = {proxy};}}')
phases = [phase('testSources','PBXSourcesBuildPhase',testfiles),phase('testFrameworks','PBXFrameworksBuildPhase',[]),phase('testResources','PBXResourcesBuildPhase',[])]
testtarget = put('testTarget', f'{{isa = PBXNativeTarget; buildConfigurationList = {testconfigs}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = ({dep},); name = BriareusUITests; productName = BriareusUITests; productReference = {testref}; productType = "com.apple.product-type.bundle.ui-testing";}}')
project = put('project', f'{{isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; TargetAttributes = {{{apptarget} = {{CreatedOnToolsVersion = 16.0;}}; {mactarget} = {{CreatedOnToolsVersion = 16.0;}}; {testtarget} = {{CreatedOnToolsVersion = 16.0; TestTargetID = {apptarget};}};}};}}; buildConfigurationList = {projectconfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {main}; packageReferences = ({webrtcpackage},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({apptarget},{mactarget},{testtarget},);}}')
folder = root / 'Briareus.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{key} = {value};' for key,value in objects.items())+'\n}; rootObject = '+project+'; }\n')
schemes = folder/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def reference(target, name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Briareus.xcodeproj"/>'
appxml = reference(apptarget,'Briareus.app'); testxml = reference(testtarget,'BriareusUITests.xctest')
(schemes/'Briareus.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appxml}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{testxml}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appxml}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appxml}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
macxml = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{mactarget}" BuildableName="Briareus.app" BlueprintName="Briareus Mac" ReferencedContainer="container:Briareus.xcodeproj"/>'
(schemes/'Briareus Mac.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{macxml}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{macxml}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{macxml}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
