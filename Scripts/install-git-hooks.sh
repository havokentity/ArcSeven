#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Rajesh D'Monte
#
# Install a pre-push hook that runs Scripts/preflight.sh.
# Hooks are not versioned by git, so this has to be run once per clone.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.git/hooks/pre-push"
cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Installed by Scripts/install-git-hooks.sh — run everything CI runs, first.
# Bypass with --no-verify when you genuinely mean to.
exec "$(git rev-parse --show-toplevel)/Scripts/preflight.sh"
HOOK_EOF
chmod +x "$HOOK"
echo "pre-push hook installed at $HOOK"
echo "Bypass with: git push --no-verify"
