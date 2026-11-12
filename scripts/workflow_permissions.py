"""Narrow zero-token exception for one reviewed complete workflow, not a YAML parser."""
import hashlib

# Any byte change needs a fresh review and pin update. Never infer absence of
# YAML overrides from line matching: quoted, escaped, flow and alias forms exist.
REVIEWED_WORKFLOW_SHA256 = 'e0e7ac0e85aa2eff34b2d3f6a828dd5931be5f78981835054033f650cfdf3d89'


def has_no_token_permissions(content):
    return hashlib.sha256(content.encode('utf-8')).hexdigest() == REVIEWED_WORKFLOW_SHA256
