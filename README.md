# Usable

Usable is a learning project to build a web browser from scratch using Zig. The primary goal is to 
understand how browsers work from the ground up by implementing core components manually rather 
than using existing engines. This will likely be ugly and naive for a while.

The project currently supports Linux (X11) and Windows (Win32/GDI), with plans to add macOS in the future.

## Design

This browser aims for minimal third-party dependencies. Most functionality is implemented using the 
Zig standard library or custom code. The main exception is FreeType, which is vendored and compiled 
from source to handle font rendering.

## Current Capabilities

- X11 window creation and event handling.
- HTTP fetching using the Zig standard library client.
- FreeType integration for text rendering.

## Platform Layers

The platform layers (Linux/X11 and Windows/Win32) are currently a minimal starting point to get the 
browser rendering. They will likely need significant revision as the browser architecture evolves, 
particularly around:

- Better separation between platform code and browser logic
- Shared rendering abstractions
- Event handling consistency across platforms
- Platform-specific optimizations (e.g., hardware acceleration)
- Browser UI controls

## Future Work

### Core Browser Features

- HTML tokenizer and parser
- Display common tags
- Form controls
- CSS selector matching
- Layout engine implementing the box model
- URL parsing and navigation
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
