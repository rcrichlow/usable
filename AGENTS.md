# PROJECT KNOWLEDGE BASE

## OVERVIEW
Usable is a learning project to build a web browser from scratch in Zig.

The current codebase can:
- open a native X11 window on Linux,
- open a native Win32 window on Windows,
- fetch a URL synchronously with `std.http.Client`,
- parse a small subset of HTML into a DOM tree,
- build a separate layout tree,
- perform basic block/inline text layout with word wrapping,
- render text through FreeType into a software framebuffer.

The repository now contains working Linux/X11 and Windows/Win32 platform entrypoints that share the same app lifecycle and memory setup.

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
│   ├── win32_platform.zig   # Win32/GDI entrypoint, message loop, and DIB backbuffer
│   └── freetype_config/     # FreeType build overrides
├── vendor/freetype2/        # Vendored FreeType source
├── build.zig                # Zig build script and target wiring
├── README.md
└── AGENTS.md
```

## CURRENT CAPABILITIES
- Linux X11 window creation and event loop
- Double-buffered Linux backbuffer using MIT-SHM when available, with `XPutImage` fallback
- Async `XShmAttach` error detection via temporary X error handler; `shmdt` called on attach failure
- `XSync` before buffer reuse/destroy to drain pending blits
- Resize triggers backbuffer recreation and layout reflow to match new viewport width
- Resize reflow rebuilds layout from the existing DOM without refetching or reparsing the page
- Keycodes resolved via `XKeysymToKeycode` at startup (no hardcoded numeric values)
- Windows Win32 window creation and message loop
- Double-buffered Windows GDI backbuffer using 32-bit DIB sections
- HTTP fetching via `std.http.Client`
- Minimal HTML parsing for element/text nodes
- Comment and doctype skipping in the parser, including mixed-case doctypes
- Quote-aware tag scanning for `>` inside quoted attribute values
- Case-insensitive handling for HTML tag names used by parser/layout decisions
- Void-element handling in the parser
- Separate layout tree with block, inline, and anonymous boxes
- Word-based text fragmentation and wrapping
- FreeType LCD, grayscale, and monochrome bitmap rendering into a BGRA8 software buffer
- UTF-8-aware text iteration in `drawText` and `measureText`
- FreeType init failure is recorded permanently; no retry on subsequent frames
- Separate persistent and transient arenas for page data vs reflow data
- Stale persistent/transient pointers (`dom_tree`, `layout_tree`, `response_body`, `current_url`, `error_message`) nulled immediately when their arena is reset
- URL copied to a stack buffer before persistent reset to prevent use-after-free during navigate
- `parseWords` propagates OOM errors instead of silently returning an empty slice
- `paddingBox`, `borderBox`, `marginBox` correctly propagate x/y position

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Fetch, navigate, and reflow | `src/app.zig` | `navigate()` resets both arenas and loads a page; `reflow()` resets only transient layout state and rebuilds layout from the existing DOM |
| HTML parsing | `src/dom.zig` | Tree builder for elements/text, skips comments/doctypes, and stores raw attribute slices only |
| Layout tree construction | `src/layout.zig` | `buildLayoutTree()` filters non-visual nodes and creates block/inline/anonymous boxes |
| Text layout and measurement | `src/layout.zig` | `layout()` and `measureText()` perform word wrapping and fragment placement |
| Shared state and geometry | `src/types.zig` | DOM nodes, layout boxes, app memory, colors, framebuffer |
| FreeType bindings | `src/c_imports.zig` + `build.zig` | `@cImport` wrapper plus static library build wiring |
| Linux platform/runtime | `src/linux_platform.zig` | Main entrypoint used for native Linux builds |
| Windows platform/runtime | `src/win32_platform.zig` | Win32 entrypoint mirroring Linux app memory setup and render loop |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `BrowserState` | enum | `src/types.zig:5` | Idle / Loading / Loaded / Error browser lifecycle |
| `Node` | union | `src/types.zig:12` | DOM node union for element/text nodes |
| `LayoutBox` | struct | `src/types.zig:79` | Layout tree node with dimensions, children, and optional text fragments |
| `AppMemory` | struct | `src/types.zig:99` | Long-lived browser state, FreeType handles, arena, and storage slices |
| `OffscreenBuffer` | struct | `src/types.zig:142` | Software framebuffer and FreeType bitmap blitter |
| `DOM` | struct | `src/dom.zig:4` | Parser state and DOM root holder |
| `DOM.parse()` | fn | `src/dom.zig:15` | Minimal HTML parser |
| `buildLayoutTree()` | fn | `src/layout.zig:6` | Converts DOM nodes into layout boxes |
| `layout()` | fn | `src/layout.zig:208` | Computes layout box geometry and text fragments |
| `measureText()` | fn | `src/layout.zig:353` | Measures text using FreeType glyph metrics |
| `reflow()` | fn | `src/app.zig:65` | Resets transient layout state and rebuilds layout from the existing DOM |
| `navigate()` | fn | `src/app.zig:93` | Fetches a page into persistent storage, parses HTML, and triggers layout |
| `updateAndRender()` | fn | `src/app.zig:240` | Initializes FreeType on first frame and renders current state |
| `X11Backbuffer` | struct | `src/linux_platform.zig:142` | Linux double-buffered presentation layer |
| `ShmBuffer` | struct | `src/linux_platform.zig:39` | Single SHM-backed or malloc-backed X11 pixel buffer |

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

## VERIFIED CURRENT STATE (2026-04-11)
- Native `zig build` succeeds on this Linux environment.
- Native `zig build test` succeeds, but there are currently no Zig `test` blocks in the repo.
- `zig build --help` exposes `install`, `run`, and `test` steps.
- The DOM parser skips HTML comments and doctypes, including mixed-case doctypes.
- The DOM parser treats `>` inside quoted attribute values as part of the attribute, not the end of the tag.
- HTML tag-name comparisons used for void elements and layout classification are ASCII case-insensitive.

## IMPORTANT NOTES
- Linux and Windows both have verified buildable platform entrypoints.
- The initial Linux window size is `800x600`.
- The initial Windows client area also targets `800x600`.
- Linux defaults to `http://example.com` when no URL is passed on the command line.
- Windows also defaults to `http://example.com` when no URL is passed on the command line.
- On Linux and Windows, `F5` triggers navigation to the initial URL and `Escape` exits.
- The font path is hardcoded:
  - Linux: `/usr/share/fonts/noto/NotoSans-Regular.ttf`
  - Windows: `C:\Windows\Fonts\arial.ttf`
- Rendering is currently text-focused. Element boxes are traversed, but there is no CSS styling, box painting, image rendering, or JavaScript execution.
- Parser attributes are stored as raw slices in `ElementNode.raw_attributes`; there is no parsed attribute model yet.
- Regular tag scanning is quote-aware, and tag-name comparisons are ASCII case-insensitive, but the parser is still intentionally minimal and not HTML5-complete.
- `layout.zig` drops whitespace-only text nodes and converts remaining text into per-word fragments for wrapping.
- There are many debug `std.debug.print` calls throughout fetch, layout, and platform code.

## CONVENTIONS
- Page-scoped content is split between `AppMemory.persistent_arena` and `AppMemory.transient_arena`.
- DOM, fetched response body, current URL, and error strings live in the persistent arena.
- Layout tree, text fragments, and layout scratch data live in the transient arena.
- Rendering uses a BGRA8 software buffer, not GPU APIs.
- Linux and Windows both allocate `32 MiB` persistent storage plus `64 MiB` transient storage in the platform layer.
- Layout uses `Dimensions` plus `margin` / `padding` / `border` helpers in `src/types.zig`.
- Mixed block/inline children under a block container are normalized with anonymous boxes.
- Non-visual elements skipped during layout include: `head`, `style`, `script`, `title`, `meta`, and `link`.
- `AppMemory` fields `dom_tree` and `layout_tree` are optional (`?`) and must be initialized to `null` in the platform layer; never `undefined`.
- `AppMemory.ft_init_failed` is set permanently on the first FreeType init failure and suppresses all retry attempts.
- `navigate()` resets both arenas before loading a new page; `reflow()` resets only the transient arena.
- All stale persistent/transient pointers in `AppMemory` are nulled immediately after the relevant arena reset before any new allocation.

## ANTI-PATTERNS / LIMITS (THIS PROJECT)
- Do not assume Linux and Windows have identical presentation internals; Linux uses X11/XShm paths while Windows uses GDI DIB blits.
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
- Windows presentation uses a double-buffered Win32/GDI backbuffer with front/back DIB sections and `BitBlt` presentation from `WM_PAINT`.
- When README claims and source/build results disagree, trust source files and verified build output.

## BOUNDARIES
- **Never**
  - generate code, propose code changes, or modify files unless the user explicitly requests it.
  - automate tasks or produce full implementations unless directly instructed.
- **Always**
  - minimize the amount of work performed on behalf of the user.
  - focus on explanations, reasoning, and conceptual clarity.
  - default to high-level guidance and conceptual descriptions.
  - ask clarifying questions when the user's intent is unclear.
  - keep responses concise unless the user asks for deeper detail.
  - trust the checked source/build state over README marketing language when they conflict.
