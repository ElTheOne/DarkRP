# DarkRP Mega Drive runtime

This runtime hosts Genesis Plus GX through a minimal libretro frontend. Video is
converted to RGBA in scalar WebAssembly and displayed with Canvas2D, so it does
not require WebGL in Garry's Mod DHTML.

Build:

```sh
chmod +x build.sh
./build.sh
```

Generated assets:

- `megadrive.js`
- `megadrive.wasm`
- `index.html`

The build pins Genesis Plus GX commit
`fa4dca561e08d5be9077419f7b255e1da213ed21`. Distribute the upstream license
with public releases.
