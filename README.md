# Usable

Usable is a learning project to build a web browser from scratch using Zig. The primary goal is to 
understand how browsers work from the ground up by implementing core components manually rather 
than using existing engines. This will likely be ugly and naive for a while.

The project is currently targeting Linux with X11, with plans to support Win32 and macOS in the future.

## Design

This browser aims for minimal third-party dependencies. Most functionality is implemented using the 
Zig standard library or custom code. The main exception is FreeType, which is vendored and compiled 
from source to handle font rendering.

## Current Capabilities

- X11 window creation and event handling.
- HTTP fetching using the Zig standard library client.
- FreeType integration for text rendering.

## Future Work

- HTML tokenizer and parser
- Display common tags
- Form controls
- CSS selector matching
- Layout engine implementing the box model
- Integrate a JavaScript engine (no plans to build one of those)
- GPU acceleration
- SVG support
- Canvas support
- Unit tests?

## Prerequisites

- Zig 0.15.2 or newer
- X11 development libraries (libX11)

## Building

Build the project using the Zig build system:

```bash
zig build
```

Run the application:

```bash
zig build run
```
