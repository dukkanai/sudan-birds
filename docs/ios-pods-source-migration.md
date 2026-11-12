# Reviewed CocoaPods source integration

The unsigned simulator artifact from [run 43247380853](https://github.com/dukkanai/sudan-birds/actions/runs/43247380853), artifact 13956884131, records the CocoaPods-integrated Xcode project and lockfile. Their bytes were checked against the artifact manifest. The migration retains those reviewed files instead of letting every clean runner modify tracked native source during dependency setup.

The project diff consists of Pods framework/config references and groups, manifest-check and framework-embedding build phases, RunnerTests base configuration references, and ordering of three existing build settings. Registered bundle identifiers and signing entitlement paths are unchanged. No signing authority or capability is added.

`Podfile` is copied exactly from the [Flutter 3.38.5 template](https://github.com/flutter/flutter/blob/3.38.5/packages/flutter_tools/templates/cocoapods/Podfile-ios). Its SHA-1 matches the captured lockfile's Podfile checksum. Debug/Release configs include their relative Pods configurations before Generated.xcconfig, matching pinned Flutter setup behavior. The workspace references the generated Pods project. Generated Pods, Flutter settings and private runner paths are not committed.

Native CI rejects tracked `app/ios` drift after the unsigned simulator build and before evidence capture. The signing preparation's existing whole-repository tracked-drift guard remains unchanged. The proposed signing configuration remains disabled; only its reviewed native-workflow digest changes.

Offline source tests establish template/lock consistency, relative integration paths, exact identity and CI guard placement. They do not execute CocoaPods, Xcode, a signed archive or an upload. The next native CI run must establish that integration is stable on its actual runner. A changed dependency graph or CocoaPods output fails closed and needs review, not a relaxed drift guard.
