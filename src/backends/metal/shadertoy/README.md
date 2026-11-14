# Shadertoy backend

`M-x appine-shadertoy` runs a [Shadertoy](https://www.shadertoy.com) shader in
an appine tab. Its GLSL is translated to Metal Shading Language when the tab
opens; nothing is precompiled.

## Opening a shader

The command takes one of:

- **A file**: Shadertoy JSON (what the API returns, or an export), or bare
  GLSL with a `mainImage` function.
- **A Shadertoy link or shader ID**: fetched through Shadertoy's official API,
  which needs your key in `appine-shadertoy-api-key` (create one at
  shadertoy.com/myapps) and serves only shaders published as "public + API".
  Fetched shaders are cached in `~/Library/Caches/appine/shadertoy/`.

Compile errors show in the tab, with line numbers relative to the pass's code.

## How it works

1. `AppineShadertoyTranslator.m` wraps each pass like Shadertoy does (uniform
   block, `iChannel0..3`, a `main` that calls `mainImage`), compiles it to
   SPIR-V with **shaderc**, and turns that into MSL with **SPIRV-Cross**. Both
   come from the LunarG Vulkan SDK and are linked statically, so the module
   needs no SDK at runtime. Without the SDK appine still builds
   (`Settings/binmac/init/vulkan-init.sh` installs it), and the tab says what
   is missing.
2. `AppineShadertoyRenderer.m` compiles the MSL and runs the passes each frame:
   Buffer A-D in order, then Image. Buffers are float textures that ping-pong,
   so a buffer reading itself sees its previous frame. Common is prepended to
   every pass.
3. Coordinates: passes use Metal's top-left `gl_FragCoord` as if it were
   Shadertoy's bottom-left, so everything renders upside down in memory,
   consistently. The final copy to the view flips it once.

## Supported

`iResolution`, `iTime`, `iTimeDelta`, `iFrameRate`, `iFrame`, `iMouse` (click
and drag in the tab), `iDate`, `iSampleRate`, `iChannelTime`,
`iChannelResolution`; buffer inputs with their filter (nearest, linear,
mipmap) and wrap (clamp, repeat) settings.

## Not supported

- Shadertoy's own media is not bundled: texture, cubemap and volume inputs are
  replaced by noise. Shaders that only need "some noise texture" look right;
  ones that show a specific picture do not.
- Keyboard, music, microphone, video and webcam inputs read as black.
- Sound and Cubemap passes are skipped.

Each replacement is logged (NSLog, prefix `[appine-shadertoy]`).

The approach follows three references: MetalToy (a live Metal shader
playground), Phosphor (Shadertoy conventions on Metal) and FragCoord (Shadertoy
GLSL exported to Metal). Unlike Phosphor's source-level rewriting, translation
here goes through a real GLSL compiler, so any valid Shadertoy GLSL translates.
