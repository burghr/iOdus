# Wine 11 patches

`scripts/build-wine-runtime.sh` applies these patches to the Wine source of
CrossOver 26.3, in name order. A patch that is already in the tree is skipped.

| Patch | Source | Why |
|---|---|---|
| `apisetschema-debug-minidump.patch` | iOdus | DIRT 5 imports `api-ms-win-core-debug-minidump-l1-1-0`, which the schema did not define. |
| `winebus-input-gate.patch` | iOdus | The controller driver stops the game input while the iOdus overlay is open. |
| `builtin-by-file-name.patch` | iOdus | A builtin listed in `WINE_BUILTIN_BY_FILE_NAME` is found by its file name, not its export name. The D3DMetal 4 runtime renames Apple's `d3d12.dll` to `d3d12_d3dmetal.dll` (no change to its content) so that the `d3d12.dll` layer can take its name. |
| `winemac-wgl-no-error.patch` | iOdus | The Mac driver accepts `WGL_CONTEXT_OPENGL_NO_ERROR_ARB`, which win32u lists; Grim Fandango Remastered asks for it (issue #4). |
| `highball-0017-kernelbase-getintegrateddisplaysize-stub.patch` | [Highball engine](https://github.com/gauthierpiarrette/highball-engine) 0017, a backport of upstream Wine c68ed23672 (Paul Gofman) | Forza Horizon 6 calls `GetIntegratedDisplaySize`. |
| `highball-0018-macos-commit-charge-is-the-footprint.patch` | Highball engine 0018 | Wine reported address space as memory in use; Forza Horizon 6 warned about low memory. |
| `highball-0019-advapi32-credenumerate-empty-keychain-is-not-an-error.patch` | [Highball engine 0019](https://github.com/gauthierpiarrette/highball-engine/blob/main/patches/0019-advapi32-credenumerate-empty-keychain-is-not-an-error.patch) | `CredEnumerateW` must preserve matching registry credentials when the macOS Keychain has no match. Minecraft Dungeons otherwise stalls after Microsoft sign-in. |
| `highball-0029-concrt140-msvcp90-concurrent-vector-from-upstream.patch` | Highball engine 0029, a backport of upstream Wine de43f5434fe and d5c7ea9089e (Piotr Caban) | Forza Horizon 6 crashed in its first minute in `concrt140`. |

The Highball patches are unchanged copies. Like Wine, they are under the
GNU LGPL 2.1 or later (the Highball engine repository is LGPL-2.1). Thanks to
the Highball project for finding and documenting these fixes.

The local regression probe in `scripts/wine11-tests/credenumerate.c` writes a
uniquely named dummy credential, verifies direct and filtered reads, deletes it,
and checks that a missing credential still returns `ERROR_NOT_FOUND`. It makes
no network requests and prints no credential contents. Compile it with
`x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -o credenumerate.exe scripts/wine11-tests/credenumerate.c -ladvapi32`
and run it with the Wine runtime being tested in a disposable `WINEPREFIX`.
Before patch 0019, the filtered read fails with error 1168 even though its count
is 1; after the patch it succeeds, while the missing-credential check still
returns error 1168 and count 0.
