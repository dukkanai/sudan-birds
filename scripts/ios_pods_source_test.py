#!/usr/bin/env python3
"""Offline checks for reviewed CocoaPods source integration; no native build claim."""
import hashlib
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'app/ios'


class PodsSourceTest(unittest.TestCase):
    def test_pinned_flutter_template_matches_captured_lock(self):
        # Flutter 3.38.5 templates/cocoapods/Podfile-ios, copied without edits.
        checksum = hashlib.sha1((IOS / 'Podfile').read_bytes()).hexdigest()
        self.assertEqual(checksum, '3c63482e143d1b91d2d2560aee9fb04ecc74ac7e')
        lock = (IOS / 'Podfile.lock').read_text()
        self.assertIn('PODFILE CHECKSUM: ' + checksum, lock)
        self.assertIn('COCOAPODS: 1.17.0', lock)
        for forbidden in ('/Users/', '/workspace/', '/private/', 'https://'):
            self.assertNotIn(forbidden, lock)

    def test_workspace_and_configs_reference_generated_pods_relatively(self):
        workspace = ET.parse(IOS / 'Runner.xcworkspace/contents.xcworkspacedata').getroot()
        self.assertEqual([node.attrib['location'] for node in workspace.findall('FileRef')],
                         ['group:Runner.xcodeproj', 'group:Pods/Pods.xcodeproj'])
        for mode in ('Debug', 'Release'):
            self.assertEqual((IOS / f'Flutter/{mode}.xcconfig').read_text(),
                             f'#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.{mode.lower()}.xcconfig"\n'
                             '#include "Generated.xcconfig"\n')

    def test_registered_identity_and_entitlement_paths_remain_exact(self):
        project = (IOS / 'Runner.xcodeproj/project.pbxproj').read_text()
        bundles = re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', project)
        self.assertEqual(sorted(bundles), sorted(['com.nextaura.sudanbirds'] * 3
                                               + ['com.nextaura.sudanbirds.RunnerTests'] * 3))
        self.assertEqual(re.findall(r'CODE_SIGN_ENTITLEMENTS = ([^;]+);', project),
                         ['Runner/Runner.entitlements'] * 3)
        self.assertNotRegex(project, r'/(?:Users|workspace|private)/')
        self.assertEqual(project.count('name = "[CP] Check Pods Manifest.lock";'), 2)
        self.assertEqual(project.count('name = "[CP] Embed Pods Frameworks";'), 1)

    def test_ci_rejects_tracked_drift_and_inert_workflow_digest_matches(self):
        path = '.github/workflows/native-checks.yml'
        workflow = (ROOT / path).read_text()
        build = workflow.index('flutter build ios --simulator --debug --no-codesign')
        gate = workflow.index('run: git diff --quiet HEAD -- app/ios')
        capture = workflow.index('name: Capture unsigned iOS simulator dependency evidence')
        self.assertLess(build, gate)
        self.assertLess(gate, capture)
        config = json.loads((ROOT / 'docs/examples/ios-staging/config.json').read_text())
        self.assertIs(config['enabled'], False)
        # Do not infer signed archive readiness from unsigned simulator preparation.
        entries = [entry for value in config.values() if isinstance(value, list)
                   for entry in value if isinstance(entry, dict) and entry.get('path') == path]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['sha256'], hashlib.sha256((ROOT / path).read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
