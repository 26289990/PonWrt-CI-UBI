`040-improve-logging-upstream.patch` is an unchanged copy from
ImmortalWrt packages commit `e765fb8870b5911992eb4b5a1624ad451e42f4a8`
(2026-10-20), which refreshed the miniupnpd 2.3.11 patches:
https://github.com/immortalwrt/packages/commit/e765fb8870b5911992eb4b5a1624ad451e42f4a8

The failed Actions run 40138763806 pinned packages to
`72c7391fb2d04080afd0bfe919605749f81eb747`, which contains this same patch.
SHA256: `69fb7a80e422b6533086b48c1a531eb2eb20c068a8a7f0722fc11ce905e83f23`.

This fixture reproduces the failure without network access and checks that
customization preserves the upstream fix while rejecting unreviewed changes.
