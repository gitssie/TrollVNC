# appstorectl upstream snapshot

- Repository: https://github.com/appknox/appstorectl
- Pinned commit: `4b60f16b2066056cc9a9c53da9a61c1aa53fec2f`
- Retrieved: 2026-10-07
- Complete unmodified source snapshot: this directory (56 upstream files), downloaded from GitHub commit archive.
- License: MIT; retained in `LICENSE`.

Upstream is kept separate from our adapter and is not compiled wholesale into the module. It includes its original account, AuthKit, authentication, purchase and terminal CLI code. Terminal/stdin login handlers cannot be called as service interfaces without adaptation. Future functions will reuse reviewed upstream components through our public API, with license notices retained. No upstream source has been modified.

Minimal runtime declarations in `../apple/private/TVAppleNativeSelectors.h` and the new orchestration are independently authored; generated RuntimeBrowser headers are not copied. The asynchronous StoreServices logout pattern is referenced from `cli/logout.m`.

The sibling apple module now adapts the Store/AuthKit sign-in algorithm from `cli/login.m` and `cli/authkit.m` in `../apple/src/appstore/TVAppleStoreAuthentication.m`, replacing terminal input/logging with asynchronous providers. Its MIT notice is also retained in `../apple/docs/appstorectl-LICENSE`. Upstream files themselves remain unchanged.
