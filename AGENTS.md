# PROJECT KNOWLEDGE BASE

## OVERVIEW
Usable is a learning project to build a web browser from scratch in Zig.

The current codebase can:
- open a native X11 window on Linux,
- fetch a URL synchronously with `std.http.Client`,
- parse a small subset of HTML into a DOM tree,
- build a separate layout tree,
- perform basic block/inline text layout with word wrapping,
- render text through FreeType into a software framebuffer.

The repository still contains a Win32/GDI platform file, but the Windows target is currently out of sync with the shared app/types API and does **not** build cleanly as of 2026-03-25.

## STRUCTURE
```text
usable/
├── src/
│   ├── app.zig              # Browser app logic: init, navigate, fetch, render
│   ├── dom.zig              # HTML parsing into DOM nodes
│   ├── layout.zig           # Layout tree construction and text layout
│   ├── types.zig            # Shared browser, layout, and framebuffer types
│   ├── c_imports.zig        # FreeType @cImport wrapper
│   ├── linux_platform.zig   # X11 entrypoint, event loop, backbuffer
│   ├── win32_platform.zig   # Win32/GDI entrypoint (currently stale/broken)
│   └── freetype_config/     # FreeType build overrides
├── vendor/freetype2/        # Vendored FreeType source
├── build.zig                # Zig build script and target wiring
├── README.md
└── AGENTS.md
```

## CURRENT CAPABILITIES
- Linux X11 window creation and event loop
- Double-buffered Linux backbuffer using MIT-SHM when available, with `XPutImage` fallback
- HTTP fetching via `std.http.Client`
- Minimal HTML parsing for element/text nodes
- Comment and doctype skipping in the parser
- Void-element handling in the parser
- Separate layout tree with block, inline, and anonymous boxes
- Word-based text fragmentation and wrapping
- FreeType LCD text rendering into a BGRA8 software buffer

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Fetch and navigate | `src/app.zig` | `navigate()` resets the arena, fetches the URL, parses HTML, and triggers layout |
| HTML parsing | `src/dom.zig` | Tree builder for elements/text, stores raw attribute slices only |
| Layout tree construction | `src/layout.zig` | `buildLayoutTree()` filters non-visual nodes and creates block/inline/anonymous boxes |
| Text layout and measurement | `src/layout.zig` | `layout()` and `measureText()` perform word wrapping and fragment placement |
| Shared state and geometry | `src/types.zig` | DOM nodes, layout boxes, app memory, colors, framebuffer |
| FreeType bindings | `src/c_imports.zig` + `build.zig` | `@cImport` wrapper plus static library build wiring |
| Linux platform/runtime | `src/linux_platform.zig` | Main entrypoint used for native Linux builds |
| Windows platform status | `src/win32_platform.zig` | File exists, but references outdated app APIs |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `BrowserState` | enum | `src/types.zig:5` | Idle / Loading / Loaded / Error browser lifecycle |
| `Node` | union | `src/types.zig:12` | DOM node union for element/text nodes |
| `LayoutBox` | struct | `src/types.zig:71` | Layout tree node with dimensions, children, and optional text fragments |
| `AppMemory` | struct | `src/types.zig:91` | Long-lived browser state, FreeType handles, arena, and storage slices |
| `OffscreenBuffer` | struct | `src/types.zig:130` | Software framebuffer and FreeType bitmap blitter |
| `DOM` | struct | `src/dom.zig:4` | Parser state and DOM root holder |
| `DOM.parse()` | fn | `src/dom.zig:15` | Minimal HTML parser |
| `buildLayoutTree()` | fn | `src/layout.zig:6` | Converts DOM nodes into layout boxes |
| `layout()` | fn | `src/layout.zig:213` | Computes layout box geometry and text fragments |
| `measureText()` | fn | `src/layout.zig:346` | Measures text using FreeType glyph metrics |
| `navigate()` | fn | `src/app.zig:51` | Fetches a page, parses it, and builds layout |
| `updateAndRender()` | fn | `src/app.zig:177` | Initializes FreeType on first frame and renders current state |
| `X11Backbuffer` | struct | `src/linux_platform.zig:108` | Linux double-buffered presentation layer |

## BUILD / PLATFORM DETAILS
- `build.zig` creates an executable named `usable`.
- The root source file is selected at build time by target OS:
  - Windows -> `src/win32_platform.zig`
  - everything else -> `src/linux_platform.zig`
- `libc` is always linked.
- Linux builds link `X11` and `Xext`.
- Windows builds link `gdi32`.
- FreeType is built from vendored C sources as a static library.
- FreeType config override headers come from `src/freetype_config`.
- `exe.addIncludePath("vendor/freetype2/include")` exposes headers for `@cImport`.

## COMMANDS
```bash
zig build                 # Build the native target
zig build run             # Build and run
zig build run -- <url>    # Run with a custom initial URL
zig build test            # Run the configured test step for the current target
zig build --help          # Show available steps/options
```

## VERIFIED CURRENT STATE (2026-03-25)
- Native `zig build` succeeds on this Linux environment.
- Native `zig build test` succeeds, but there are currently no Zig `test` blocks in the repo.
- `zig build --help` exposes `install`, `run`, and `test` steps.
- Cross-building for `x86_64-windows-gnu` currently fails.

## IMPORTANT NOTES
- Linux currently appears to be the only verified working target.
- `src/win32_platform.zig` still refers to `app.AppMemory`, `app.OffscreenBuffer`, and `app.start()`, but `src/app.zig` no longer exports those symbols. Treat Windows support as stale until fixed.
- The initial Linux window size is `800x600`.
- Linux defaults to `http://example.com` when no URL is passed on the command line.
- On Linux, `F5` triggers navigation to the initial URL and `Escape` exits.
- The font path is hardcoded:
  - Linux: `/usr/share/fonts/noto/NotoSans-Regular.ttf`
  - Windows: `C:\Windows\Fonts\arial.ttf`
- Rendering is currently text-focused. Element boxes are traversed, but there is no CSS styling, box painting, image rendering, or JavaScript execution.
- Parser attributes are stored as raw slices in `ElementNode.raw_attributes`; there is no parsed attribute model yet.
- `layout.zig` drops whitespace-only text nodes and converts remaining text into per-word fragments for wrapping.
- There are many debug `std.debug.print` calls throughout fetch, layout, and platform code.

## CONVENTIONS
- Page-scoped content is allocated from `AppMemory.arena` and reset on each navigation.
- DOM, layout tree, and fetched response body all live off the page arena.
- Rendering uses a BGRA8 software buffer, not GPU APIs.
- Layout uses `Dimensions` plus `margin` / `padding` / `border` helpers in `src/types.zig`.
- Mixed block/inline children under a block container are normalized with anonymous boxes.
- Non-visual elements skipped during layout include: `head`, `style`, `script`, `title`, `meta`, and `link`.

## ANTI-PATTERNS / LIMITS (THIS PROJECT)
- Do not assume Windows support is currently working just because `src/win32_platform.zig` exists.
- Do not assume CSS, JavaScript, images, forms, cookies, or async networking exist.
- No code generation; parsing, layout, and platform layers are handwritten.
- No external runtime dependencies beyond vendored FreeType and platform system libraries.
- No GPU rendering yet.
- No real automated test coverage yet.

## UNIQUE STYLES
- The DOM parser builds the tree directly while scanning the HTML source.
- The layout tree is separate from the DOM tree rather than storing layout directly on DOM nodes.
- Text layout is currently word-oriented: text nodes become positioned fragments instead of a single painted run.
- Linux presentation uses a double-buffered X11 backbuffer with MIT-SHM fast path and malloc/XImage fallback.
- When README claims and source/build results disagree, trust source files and verified build output.

## BOUNDARIES
- **Never**
  - generate code, propose code changes, or modify files unless the user explicitly requests it.
  - automate tasks or produce full implementations unless directly instructed.
  - claim Windows is supported without verifying the build first.
- **Always**
  - minimize the amount of work performed on behalf of the user.
  - focus on explanations, reasoning, and conceptual clarity.
  - default to high-level guidance and conceptual descriptions.
  - ask clarifying questions when the user's intent is unclear.
  - keep responses concise unless the user asks for deeper detail.
  - trust the checked source/build state over README marketing language when they conflict.
