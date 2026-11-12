#!/usr/bin/env python3
"""Nonsecret staging build configuration. No signing/provisioning/upload."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from ios_staging_guard import Blocked, CONFIG, ROOT, require, runtime_config, validate_config
from ios_staging_sign import child_environment


def main():
    try:
        c = runtime_config(json.loads(CONFIG.read_text()), os.environ)
        validate_config(c)
        require(sys.platform == 'darwin', 'Native configuration needs macOS.')
        project = (ROOT / 'app/ios/Runner.xcodeproj/project.pbxproj').read_text()
        # No hidden on-run bundle rewrite: final staging identity must be part of the reviewed source.
        require(project.count('PRODUCT_BUNDLE_IDENTIFIER = ' + c['bundle_id'] + ';') == 3,
                'All Runner configurations must already use the approved app ID in source.')
        publishable = os.environ.get('BIRDS_STAGING_PUBLISHABLE_KEY', '')
        require(re.fullmatch(r'sb_publishable_[A-Za-z0-9_-]{16,256}', publishable) is not None,
                'A staging publishable key is required. Service-role/secret/legacy JWT keys are rejected.')
        # Only nonsecret runtime configuration is compiled into the client.
        command = ['flutter', 'build', 'ios', '--release', '--config-only', '--no-codesign',
                   '--build-name=' + c['build_version'], '--build-number=' + c['build_number'],
                   '--dart-define=SUPABASE_URL=' + c['supabase_url'],
                   '--dart-define=SUPABASE_ANON_KEY=' + publishable,
                   '--dart-define=AUTH_REDIRECT_URL=' + c['auth_redirect']]
        require(subprocess.run(command, cwd=ROOT / 'app', env=child_environment(os.environ),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900).returncode == 0,
                'Flutter native configuration failed; raw output suppressed.')
        require(subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=ROOT).returncode == 0,
                'Flutter modified tracked source. Review and commit migrations, then rerun all gates.')
        print('Nonsecret staging build configuration prepared; no signing performed.')
        return 0
    except Blocked as error:
        print('BLOCKED: ' + str(error), file=sys.stderr)
    except Exception:
        print('BLOCKED: Native preparation failed.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
