#!/bin/bash
# Converts a spec markdown file to a styled standalone HTML page and opens it
# in the default browser. Wired to a Claude Code PostToolUse hook (see
# .claude/settings.json) so every spec written under docs/superpowers/specs/
# opens rendered; also usable by hand:
#
#   scripts/spec-to-html.sh docs/superpowers/specs/2026-07-04-foo-design.md
#
# Output lands in .build/specs-html/ (gitignored via .build/). Requires pandoc.
set -euo pipefail

md="${1:?usage: spec-to-html.sh <spec.md> [--no-open]}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$repo_root/.build/specs-html"
mkdir -p "$out_dir"

base="$(basename "${md%.md}")"
out="$out_dir/$base.html"

style="$(mktemp -t spec-css)"
trap 'rm -f "$style"' EXIT
cat > "$style" <<'CSS'
<style>
  body { max-width: 46rem; margin: 2rem auto; padding: 0 1.25rem;
         font: 16px/1.6 -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; }
  h1 { font-size: 1.6rem; line-height: 1.3; border-bottom: 2px solid #e5e5ea; padding-bottom: .4rem; }
  h2 { font-size: 1.25rem; margin-top: 2.2rem; border-bottom: 1px solid #e5e5ea; padding-bottom: .3rem; }
  h3 { font-size: 1.05rem; margin-top: 1.6rem; }
  code { background: #f2f2f7; padding: .1em .35em; border-radius: 4px;
         font: .875em ui-monospace, "SF Mono", Menlo, monospace; }
  pre { background: #f2f2f7; padding: .9rem 1rem; border-radius: 8px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; width: 100%; font-size: .925em; }
  th, td { border: 1px solid #d1d1d6; padding: .45rem .6rem; text-align: left; vertical-align: top; }
  th { background: #f2f2f7; }
  blockquote { border-left: 3px solid #d1d1d6; margin-left: 0; padding-left: 1rem; color: #6e6e73; }
  a { color: #0066cc; }
  @media (prefers-color-scheme: dark) {
    body { background: #1c1c1e; color: #f2f2f7; }
    h1, h2 { border-color: #3a3a3c; }
    code, pre, th { background: #2c2c2e; }
    th, td { border-color: #48484a; }
    blockquote { border-color: #48484a; color: #98989d; }
    a { color: #409cff; }
  }
</style>
CSS

pandoc --standalone --from gfm --to html5 \
  --metadata title="$base" \
  --include-in-header "$style" \
  "$md" -o "$out"

if [[ "${2:-}" != "--no-open" ]]; then
  open "$out"
fi
echo "$out"
