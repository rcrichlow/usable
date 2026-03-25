# Usable

Usable is a learning project to build a web browser from scratch using Zig. The primary goal is to 
understand how browsers work from the ground up by implementing core components manually rather 
than using existing engines. This will likely be ugly and naive for a while.

The project currently builds and runs on Linux (X11). A Windows (Win32/GDI) platform layer is still in the repository, but it is currently out of sync with the shared browser code and does not build cleanly today; bringing it back into a working state is still intended. macOS may be added in the future.

## Design

This browser aims for minimal third-party dependencies. Most functionality is implemented using the 
Zig standard library or custom code. The main exception is FreeType, which is vendored and compiled 
from source to handle font rendering.

## Current Capabilities

- Linux X11 window creation and event handling.
- Double-buffered Linux software backbuffer with MIT-SHM when available and `XPutImage` fallback.
- Synchronous HTTP fetching using the Zig standard library client.
- Minimal HTML parsing into a DOM tree, including element and text nodes.
- Basic layout-tree construction with block, inline, and anonymous boxes.
- Basic word-wrapped text layout and FreeType-based software text rendering.

## Platform Layers

The platform layers are still a minimal starting point to get the browser rendering. Linux/X11 is the currently working path. The Windows/Win32 layer is presently stale and needs to be brought back in sync with the shared app/types API, but it is meant to be fixed rather than removed. Both platform layers will likely need significant revision as the browser architecture evolves, particularly around:

- Better separation between platform code and browser logic
- Shared rendering abstractions
- Event handling consistency across platforms
- Platform-specific optimizations (e.g., hardware acceleration)
- Browser UI controls

## Future Work

### Core Browser Features

- More complete HTML parsing and DOM support
- Display more common tags and richer page structure
- Form controls
- CSS selector matching
- Layout engine beyond the current basic block/inline text flow
- Navigation improvements and better URL handling
- Tabbed browsing
- Bookmarks and history

### Browser Interface

- Address bar and navigation controls
- Tab bar UI
- Bookmarks bar
- Context menus
- Scrollbars

### Rendering

- Image decoding (JPEG, PNG, WebP, GIF)
- GPU acceleration
- SVG support
- Canvas support

### Networking

- HTTP/2 and HTTP/3 support
- Cookie handling and caching

### Storage

- LocalStorage / SessionStorage
- Download manager

### Other

- Integrate a JavaScript engine (no plans to build one of those)
- WebGL support
- Basic DevTools (inspector, console)
- Unit tests

## Prerequisites

- Zig 0.15.2 or newer
- X11 development libraries (libX11) - Linux only

## Building

Build the project using the Zig build system:

```bash
zig build
```

Run the application:

```bash
zig build run
```
