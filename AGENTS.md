# PROJECT KNOWLEDGE BASE

## OVERVIEW
Learning project to build a web browser from scratch in Zig. Minimal third-party deps (vendored FreeType only). Supports Linux (X11) and Windows (Win32/GDI).

## STRUCTURE
```
usable/
├── src/
│   ├── app.zig           # Browser core: HTTP, DOM, rendering
│   ├── dom.zig           # HTML parser (tree builder)
│   ├── linux_platform.zig  # X11 window & events
│   ├── win32_platform.zig # Win32/GDI window
│   └── freetype_config/  # FreeType build overrides
├── vendor/freetype2/     # Vendored font library
├── build.zig             # Zig build system
└── README.md
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Add HTML feature | `src/dom.zig` | Tree parser, no styling yet |
| Add layout engine | `src/dom.zig` + `src/app.zig` | Iterator discussed in recent convo |
| Platform layer | `src/*_platform.zig` | Swapped at build time via build.zig |
| Font rendering | `src/app.zig` | FreeType via @cImport |
| HTTP fetching | `src/app.zig` | `fetchUrl()` uses std.http.Client |
| Rendering | `src/app.zig` | `OffscreenBuffer` software renderer |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `DOM` | struct | `dom.zig:18` | HTML parser + tree |
| `Node` | union | `dom.zig:3` | Element/Text variant |
| `ElementNode` | struct | `dom.zig:8` | HTML element with children |
| `AppMemory` | struct | `app.zig:18` | Browser state + memory |
| `OffscreenBuffer` | struct | `app.zig:56` | Software framebuffer |
| `BrowserState` | enum | `app.zig:9` | Idle/Loading/Loaded/Error |
| `navigate()` | fn | `app.zig:163` | URL fetch + parse |
| `render()` | fn | `app.zig:216` | Main render loop |

## CONVENTIONS
- **Memory**: Arena allocator in `AppMemory.arena` for page content
- **Platform**: Conditional compile via build.zig (not runtime)
- **Rendering**: BGRA8 software buffer, no GPU
- **Error handling**: `try`/`catch` with typed errors

## ANTI-PATTERNS (THIS PROJECT)
- No code gen - hand-written DOM, platform layers
- No external deps beyond FreeType (vendored)
- No GPU rendering yet

## UNIQUE STYLES
- DOM tree built during parse (not streamed)
- FreeType built as static C library via Zig build
- Platform code in separate files, swapped at compile time

## COMMANDS
```bash
zig build        # Build executable
zig build run    # Build + run
zig build test   # Run tests (none yet)
```

## NOTES
- Font path hardcoded: `/usr/share/fonts/noto/NotoSans-Regular.ttf` (Linux), `C:\Windows\Fonts\arial.ttf` (Windows)
- No CSS yet - plain HTML rendering only
- 0 tests exist despite build.zig test scaffolding

## BOUNDARIES
- **Never**
  - generate code, propose code changes, or modify files unless the user explicitly requests it.
  - automate tasks or produce full implementations unless directly instructed.
- **Always**
  - minimize the amount of work performed on behalf of the user.
  - focus on explanations, reasoning, and conceptual clarity.
  - Default to high-level guidance and conceptual descriptions.
  - Ask clarifying questions when the user’s intent is unclear.
  - Keep responses concise unless the user asks for deeper detail.
