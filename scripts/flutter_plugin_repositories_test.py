#!/usr/bin/env python3
"""Offline Gradle integration tests. Set GRADLE_TEST_BIN to Gradle 8.14's binary."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'app/android/ci/flutter-plugin-repositories.init.gradle'


class NativeWorkflowOrderTest(unittest.TestCase):
    def test_generated_wrapper_is_not_required_before_flutter_build(self):
        workflow = (ROOT / '.github/workflows/native-checks.yml').read_text()
        android = workflow.split('  android-debug:', 1)[1].split('  ios-simulator:', 1)[0]
        init = android.index('name: Configure Flutter plugin dependency source')
        build = android.index('run: cd app && flutter build apk --debug')
        tests = android.index('name: Verify scoped repository policy (offline)')
        self.assertLess(init, build)
        self.assertLess(build, tests)
        self.assertNotIn('gradlew', android)
        self.assertNotIn('continue-on-error:', android)
        self.assertNotIn('if:', android)
        self.assertEqual(android.count("-p 'flutter_plugin_repositories_test.py'"), 1)
        self.assertIn('test -x "${gradle_bins[0]}"', android)


@unittest.skipUnless(os.environ.get('GRADLE_TEST_BIN'), 'GRADLE_TEST_BIN not set')
class FlutterPluginRepositoriesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env['GRADLE_USER_HOME'] = str(self.root / 'gradle-home')
        self.env['FLUTTER_ROOT'] = str(self.root / 'flutter')
        init = self.root / 'gradle-home/init.d'
        init.mkdir(parents=True)
        shutil.copyfile(SCRIPT, init / SCRIPT.name)

    def run_gradle(self):
        return subprocess.run(
            [self.env['GRADLE_TEST_BIN'], '--offline', '--no-daemon',
             '--console=plain', '-p', str(self.root), 'help'],
            env=self.env, text=True, capture_output=True, timeout=180,
        )

    def test_policy_applies_only_to_flutter_included_build(self):
        target = self.root / 'flutter/packages/flutter_tools/gradle'
        sibling = self.root / 'other-plugin'
        target.mkdir(parents=True)
        sibling.mkdir()
        (self.root / 'settings.gradle').write_text("""
assert pluginManagement.repositories.empty
rootProject.name = 'policy-test'
includeBuild('flutter/packages/flutter_tools/gradle')
includeBuild('other-plugin')
""")
        (target / 'settings.gradle').write_text("""
rootProject.name = 'flutter-tools-test'
def repos = pluginManagement.repositories
assert repos.size() == 2
assert repos[0].url.toString() == 'https://repo.maven.apache.org/maven2/'
assert repos[1].url.toString() == 'https://plugins.gradle.org/m2'
println 'SCOPED_FLUTTER_REPOSITORIES_OK'
""")
        (sibling / 'settings.gradle').write_text("""
rootProject.name = 'unrelated-plugin'
assert pluginManagement.repositories.empty
println 'UNRELATED_REPOSITORIES_UNCHANGED'
""")
        result = self.run_gradle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('SCOPED_FLUTTER_REPOSITORIES_OK', result.stdout)
        self.assertIn('UNRELATED_REPOSITORIES_UNCHANGED', result.stdout)

    def test_default_portal_fails_but_exact_module_route_resolves(self):
        # Synthetic JARs exercise real Gradle plugin resolution without network.
        target = self.root / 'flutter/packages/flutter_tools/gradle'
        target.mkdir(parents=True)
        central = self.root / 'central'
        portal = self.root / 'portal'
        portal.mkdir()
        module = central / 'org/jetbrains/kotlin/kotlin-compiler-embeddable/2.0.21'
        module.mkdir(parents=True)
        basename = 'kotlin-compiler-embeddable-2.0.21'
        (module / (basename + '.pom')).write_text("""
<project><modelVersion>4.0.0</modelVersion><groupId>org.jetbrains.kotlin</groupId>
<artifactId>kotlin-compiler-embeddable</artifactId><version>2.0.21</version></project>
""")
        with zipfile.ZipFile(module / (basename + '.jar'), 'w') as jar:
            jar.writestr('META-INF/gradle-plugins/fixture.compiler.properties',
                         'implementation-class=org.gradle.api.plugins.BasePlugin')
        (self.root / 'settings.gradle').write_text("""
rootProject.name = 'resolution-test'
includeBuild('flutter/packages/flutter_tools/gradle')
""")
        (target / 'settings.gradle').write_text(f"""
pluginManagement {{
    // Replace only endpoints in this offline fixture; retain the init filters.
    repositories {{
        if (empty) {{ maven {{ url = uri('{portal.as_uri()}') }} }}
        else {{
            getAt(0).url = uri('{central.as_uri()}')
            getAt(1).url = uri('{portal.as_uri()}')
        }}
    }}
    resolutionStrategy.eachPlugin {{
        useModule('org.jetbrains.kotlin:kotlin-compiler-embeddable:2.0.21')
    }}
}}
rootProject.name = 'synthetic-flutter-tools'
""")
        (target / 'build.gradle').write_text("""
plugins { id 'fixture.compiler' version '1.0' }
assert plugins.hasPlugin('base')
println 'EXACT_MODULE_PLUGIN_RESOLVED'
""")
        init = self.root / 'gradle-home/init.d' / SCRIPT.name
        init.unlink()
        baseline = self.run_gradle()
        self.assertNotEqual(baseline.returncode, 0)
        self.assertIn('was not found', baseline.stdout + baseline.stderr)
        shutil.copyfile(SCRIPT, init)
        fixed = self.run_gradle()
        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        self.assertIn('EXACT_MODULE_PLUGIN_RESOLVED', fixed.stdout)

        # A selected module must not silently fall back to the portal.
        portal_module = portal / module.relative_to(central)
        portal_module.parent.mkdir(parents=True)
        shutil.move(str(module), portal_module)
        # New Gradle user home prevents an artifact-cache hit from hiding routing.
        self.env['GRADLE_USER_HOME'] = str(self.root / 'fresh-gradle-home')
        fresh_init = Path(self.env['GRADLE_USER_HOME']) / 'init.d'
        fresh_init.mkdir(parents=True)
        shutil.copyfile(SCRIPT, fresh_init / SCRIPT.name)
        fallback = self.run_gradle()
        self.assertNotEqual(fallback.returncode, 0)
        self.assertIn('was not found', fallback.stdout + fallback.stderr)

        # An unrelated module is NOT routed to Central, but can use the portal.
        other = central / 'org/example/portal-plugin/1.0'
        other.mkdir(parents=True)
        (other / 'portal-plugin-1.0.pom').write_text("""
<project><modelVersion>4.0.0</modelVersion><groupId>org.example</groupId>
<artifactId>portal-plugin</artifactId><version>1.0</version></project>
""")
        shutil.copyfile(portal_module / (basename + '.jar'),
                        other / 'portal-plugin-1.0.jar')
        settings = target / 'settings.gradle'
        settings.write_text(settings.read_text().replace(
            'org.jetbrains.kotlin:kotlin-compiler-embeddable:2.0.21',
            'org.example:portal-plugin:1.0'))
        unrelated = self.run_gradle()
        self.assertNotEqual(unrelated.returncode, 0)
        self.assertIn('was not found', unrelated.stdout + unrelated.stderr)
        portal_other = portal / other.relative_to(central)
        portal_other.parent.mkdir(parents=True)
        shutil.move(str(other), portal_other)
        portal_result = self.run_gradle()
        self.assertEqual(portal_result.returncode, 0,
                         portal_result.stdout + portal_result.stderr)
        self.assertIn('EXACT_MODULE_PLUGIN_RESOLVED', portal_result.stdout)

    def test_missing_flutter_root_fails_closed(self):
        self.env.pop('FLUTTER_ROOT')
        (self.root / 'settings.gradle').write_text("rootProject.name = 'missing-sdk'")
        result = self.run_gradle()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FLUTTER_ROOT is required', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
