# tools/

Scripts that collapse the repetitive commit/release steps into a single
approvable command — review them once, approve `tools/<name>.sh`, and the
individual `git`/`gh`/`brew` steps stop prompting.

| script | what |
|---|---|
| `commit.sh "<msg>"` | `git add -A` + commit with the `Co-Authored-By` trailer, no GPG prompt |
| `release.sh <X.Y.Z>` | push main, tag, wait for the **build pkg** CI, bump the Homebrew formula, push the tap, `brew upgrade` |

Typical flow:

```sh
tools/commit.sh "cli: …"
tools/release.sh 0.4.6
```

`release.sh` assumes HEAD is the commit to ship and that `dist/homebrew/update-formula.sh`
+ the `millfolio/homebrew-tap` repo exist (they do).
