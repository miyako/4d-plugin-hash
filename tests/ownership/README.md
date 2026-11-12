# Ownership regressions

`engine_harness.mm` links the real `4DPlugin.cpp`, the vendored OpenSSL (`a/libcrypto.a`), the plugin classes and the unchanged bundled `4D Plugin API` with ASan/UBSan. It also replaces the 4D engine (`Call4D`) with a synthetic one. That engine counts live engine strings and reference-counted pictures, and aborts on anything it does not model.

`Generate checksum` runs through `PluginMain` on a 3-byte temp file that the test creates and then deletes.

```sh
tests/ownership/run.sh . fixed                # every test must pass

B=$(mktemp -d); git archive <base-sha> | tar -x -C "$B"
tests/ownership/run.sh "$B" baseline          # named defects must fail, controls pass
```

| Test | Checks |
|---|---|
| `defect_1007_param_owner_leak` | the `EXECUTE METHOD` (1007) progress callback leaves no engine strings behind |
| `defect_picture_fromfile_ownership` | `C_PICTURE::fromFileAtPath` frees the path once and releases the loaded picture |
| `defect_picture_setbytes_leak` | `C_PICTURE::setBytes` releases the picture it creates |
| `defect_picture_createcopy_ownership` | `createCopy*` reads only the converted type and leaves no empty owners |
| `defect_picture_grayscale_owner_leak`, `defect_picture_getsize_owner_leak`, `defect_picture_thumbnail_owner_leak` | no empty picture owner leaks |
| `control_*` | progress arguments, abort, ByID result release, digests, `ARRAY_TEXT` transfer, picture parameter/return |

`C_PICTURE` is compiled into the plugin, but the `Generate checksum` command never calls it.

Not covered:
- Windows (`_wfopen` path) and a real 4D runtime.
- How the real engine treats the old value of a picture output parameter. The harness assumes the most forgiving model: the engine releases it.
