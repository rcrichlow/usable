# Track 1 — Foundation Hardening Plan

This document is a step-by-step implementation guide for the first hardening pass
of the Usable browser engine. It is intentionally granular and still avoids full
code listings, but it is also written as a learning guide: each section explains
what to change, why that change matters, what to inspect before editing, and what
mistakes to watch for.

The goal of Track 1 is not to add features. The goal is to make the engine safer
to extend by tightening invariants, reducing accidental complexity, and turning
silent failure modes into explicit ones.

The plan covers, in order:

1. Logging module + replacing `std.debug.print`
2. `types.zig` cleanups (FBA fields, optional FT handles, non-optional `children`, `needs_render`)
3. `app.initMemory` extraction + platform updates
4. `ensureFontReady` + FreeType-init ordering
5. `layout.zig` allocator-error propagation
6. Render vs present split (with Win32 invalidation pattern)
7. Tests (`src/tests.zig` + in-file `test` blocks) and `build.zig` wiring

Verification steps live at the end.

---

## How To Use This Plan

Treat each major section as a small exercise in code reasoning, not just a list
of edits.

For each step:

1. Read the named functions first without editing.
2. Write down the invariant the step is trying to introduce or protect.
3. Predict what failure would happen today if that invariant were violated.
4. Make the smallest change that enforces the invariant.
5. Compile immediately.
6. Run the listed verification before moving on.

If you get stuck, ask two questions:

1. What owns this data or state?
2. Who is assuming it is valid, initialized, or available?

Those two questions are the spine of most of the hardening work in this track.

---

## 0. Ground Rules

- Make changes in the order listed. Each step should compile cleanly on Linux and
  Windows before moving on.
- Do not change observable behavior beyond what each step explicitly requires.
- Keep `AGENTS.md` in mind: persistent vs transient arena split, all stale
  pointers in `AppMemory` nulled when their arena resets, no GPU APIs, no CSS,
  no JS.
- After every step, run `zig build` for the host target. After step 7, also run
  `zig build test`.
- Prefer the smallest correct edit. If you are about to add a new helper, ask
  whether it is clarifying a real invariant or just moving code around.

### Learning Goal

Build the habit of changing one axis at a time. This track is deliberately
sequenced so that each step reduces ambiguity for the next one.

### Checkpoint Questions

- What invariant is this step order protecting?
- If you skipped ahead to tests or dirty rendering first, what assumptions would
  still be unstable?

---

## 1. Logging Module

### Why This Step Exists

The current code mixes signal and noise. Some prints are useful lifecycle events;
some are one-off breadcrumbs; some are large dumps that drown out real failures.
The point of this step is not just to rename `std.debug.print` to `log.debug`.
The point is to establish a vocabulary for diagnostics:

- `debug`: noisy local breadcrumbs
- `info`: noteworthy lifecycle events
- `warn`: unusual but recoverable states
- `err`: failures worth immediate attention

Once that vocabulary exists, later hardening work becomes easier because error
paths can report consistently.

### Before Editing

Read the current print sites in:

- `src/app.zig`
- `src/layout.zig`
- `src/linux_platform.zig`
- `src/win32_platform.zig`

As you read them, classify each print by intent, not by text. Ask:

- Is this describing normal lifecycle progress?
- Is this only useful while debugging a specific bug?
- Is this reporting a real failure?

Do that classification first; the code edits are then mostly mechanical.

### 1.1 Add the build option
- In `build.zig`, declare a build option named `debug-log` of type `?bool`
  (optional bool) with a description that mentions the default behavior.
- Compute the resolved value as `opt orelse (optimize == .Debug)`.
- Create an `Options` step (`b.addOptions`), add a single field
  `enable_debug_log: bool` set from the resolved value.
- Add the options module to the executable's root module imports under the name
  `build_options`.
- Apply the same wiring to whichever module ends up being the test root in
  step 7 so tests see the same flag.

### Reasoning

This keeps the default behavior aligned with build mode, while still allowing an
explicit override. That is usually the right shape for diagnostics: ergonomic in
Debug, quiet in release-style runs, but controllable when you need to inspect a
ReleaseSafe build.

### 1.2 Create `src/log.zig`
- Import `std` and `@import("build_options")`.
- Expose four functions: `debug`, `info`, `warn`, `err`. All four take the
  same `comptime fmt: []const u8, args: anytype` shape used by
  `std.debug.print`.
- For `warn` and `err`: always forward to `std.debug.print` (consider
  prefixing with `"[warn] "` / `"[err] "` for grep-ability).
- For `debug` and `info`: gate the body behind
  `comptime build_options.enable_debug_log`. When disabled, the body must
  compile out (use a `comptime` `if` so the call site has zero runtime cost).
- Optional: prefix `info` with `"[info] "` for symmetry.

### Reasoning

The important detail here is the compile-time gate. This is not just about
printing less; it is about ensuring debug logging does not become a hidden
runtime branch spread throughout the codebase.

### 1.3 Replace `std.debug.print` call sites
Walk each file and reclassify every print:

- `src/app.zig`
  - FT init progress prints, font path print, family-name print -> `debug`
  - Fetch status print -> `info`
  - Body dump (`"Body: {s}\n"`) -> `debug`
  - Fetch / parse / DOM-build / layout-build error prints -> `err`
  - `navigate` `"navigating to: ..."` -> `info`
  - "buffer width" / "window width" debug breadcrumbs -> `debug`
- `src/dom.zig` - none currently active beyond the commented-out `dump`. Leave
  `dump` alone but, if you re-enable it, route it through `log.debug`.
- `src/layout.zig` - every `std.debug.print` (tag/box-type breadcrumbs, child
  type prints, "layout_box content width" prints) -> `debug`. Allocation
  failure prints disappear in step 5 (replaced by `try`).
- `src/linux_platform.zig`
  - SHM/XPutImage path selection print -> `info`
  - Key-pressed print -> `debug`
  - Resize print -> `info`
  - "Failed to open X display" / args parse failure -> `err`
- `src/win32_platform.zig` - same classification scheme: lifecycle -> `info`,
  per-frame breadcrumbs -> `debug`, failures -> `err`.

### Common Mistakes

- Renaming calls without rethinking their level.
- Treating all current prints as equally useful.
- Leaving a huge body dump at `info` and then concluding the logging layer is
  still noisy.

### 1.4 Verify
- `zig build` is clean.
- `zig build run -- http://example.com` produces the same stream as today
  (Debug mode default).
- `zig build -Doptimize=ReleaseSafe` produces a quiet binary.
- `zig build -Ddebug-log=true -Doptimize=ReleaseSafe` is verbose again.
- `zig build -Ddebug-log=false` is quiet even in Debug.

### Checkpoint Questions

- Which messages are for humans operating the program, and which are for you as
  the developer inspecting internals?
- If a future failure happens in `layout.zig`, will the log now make that more
  or less obvious than before?

---

## 2. `types.zig` Cleanups

### Why This Step Exists

This step tightens several type-level invariants:

- a `LayoutBox` always has a `children` list, even if it is empty
- FreeType handles are either present or absent, not "maybe initialized but
  stored in `undefined`"
- the memory backing the arenas becomes part of `AppMemory`'s stable structure
- render dirtiness becomes explicit state instead of implicit behavior

These are good hardening changes because they move assumptions out of comments
and call-site folklore and into the type shapes themselves.

### Before Editing

Read these areas first:

- `types.zig`: `LayoutBox`, `AppMemory`
- `app.zig`: `paint`, `drawText`, `reflow`
- `layout.zig`: `buildLayoutTree`, `layout`

As you read, ask:

- Which fields are optional because the value is truly absent?
- Which fields are optional only because the construction pattern is awkward?
- Which fields are currently relying on "we promise to initialize this first"?

### 2.1 Make `LayoutBox.children` non-optional with `.empty`
- Change the field to a non-optional `std.ArrayList(*LayoutBox)`.
- Default-initialize it to `.empty` at the field declaration so callers can
  construct a `LayoutBox` without a separate list-init step.
- Search the codebase for `box.children orelse`, `box.children.?`,
  `child.children = ...`, etc., and remove the optionality plumbing.
  - In `src/app.zig` `paint`, the `if (box.children) |children|` blocks
    collapse into direct iteration over `box.children.items`.
  - In `src/layout.zig` `layout`, same collapse.
  - In `src/layout.zig` `buildLayoutTree`:
    - Drop the `initCapacity` call on the element branch; rely on `.empty`
      and `append` growth.
    - Drop the `initCapacity` call on the text branch entirely (text boxes
      never get children).
    - Drop the `initCapacity` call on the anonymous-box construction; rely
      on `.empty` and `append` growth.

### Reasoning

An empty children list is not the same thing as "no children field exists".
Making it non-optional expresses the real model more accurately and removes a
lot of branch noise from traversal code.

### 2.2 Make FT handles optional and `null`-initialized
- Change `AppMemory.ft_library` to `?ft.FT_Library` with default `null`.
- Change `AppMemory.ft_face` to `?ft.FT_Face` with default `null`.
- In `src/app.zig` `init`, after success, write the values directly; the field
  type does the optional wrapping.
- In `src/app.zig` `drawText` and `src/layout.zig` `measureText`, both already
  receive a possibly-null face via `memory.ft_face` / direct argument.
  Once step 4 is in place, `ensureFontReady` guarantees these are non-null at
  call time, so the existing `face.?` / `memory.ft_face.?` accesses stay valid.
- Remove `undefined` initializers for `ft_library` / `ft_face` from both
  platform files (will be revisited in step 3 anyway).

### Reasoning

`undefined` is appropriate when a value is definitely written before any read.
That is not a property you want to assume about long-lived app state. Optional
types make the "not initialized yet" state explicit and visible.

### 2.3 Add FBA fields to `AppMemory`
- Add `persistent_fba: std.heap.FixedBufferAllocator` and
  `transient_fba: std.heap.FixedBufferAllocator` fields.
- Do not give them defaults; they will be initialized in place by
  `app.initMemory` in step 3.
- Document via a short comment that `persistent_arena` / `transient_arena` are
  built from these FBA fields and therefore must not be moved after init.

### Reasoning

This is the key lifetime fix in the track. The allocator returned by an FBA is
not a detached value object; it references the allocator state inside the FBA.
That means the FBA must outlive every arena allocation routed through it.

### 2.4 Add `needs_render`
- Add `needs_render: bool = true` to `AppMemory` so the first frame after
  startup always paints.

### Reasoning

This makes "does the app need a freshly rendered frame?" part of the model,
instead of something inferred from control flow in the platform loops.

### Common Mistakes

- Replacing optionals mechanically without asking whether absence is still a
  meaningful state.
- Default-initializing `children` by allocating a list instead of using
  `.empty`.
- Adding FBA fields without yet understanding why returning an arena-backed
  struct by value can be dangerous.

### 2.5 Verify
- `zig build` is clean. Behavior unchanged.

### Checkpoint Questions

- Which of these type changes removed branches from the code, and which removed
  hidden invalid states?
- After this step, what invalid `AppMemory` states are still possible?

---

## 3. Memory Init Extraction (`app.initMemory`)

### Why This Step Exists

The current Linux and Win32 platform entrypoints duplicate the same memory setup.
That duplication is annoying, but the deeper issue is that extracting it the
wrong way introduces a lifetime bug. This step is about learning to recognize
when "factor out shared code" is safe and when ownership/lifetime makes it more
subtle.

### Before Editing

Read the current memory setup in both platform files from the raw storage slice
split down to the `AppMemory` literal.

Write down the chain of ownership:

1. who owns the raw `[]u8` slices
2. who owns the FBAs
3. who owns the arenas
4. where `AppMemory` lives

Then ask: if a helper function returns an `AppMemory` by value, which of those
objects might have been constructed on the helper's stack?

If you can answer that clearly before editing, you understand the main risk.

### 3.1 Add the helper
- In `src/app.zig`, add `pub fn initMemory(memory: *types.AppMemory, persistent: []u8, transient: []u8) void`.
- Inside, in this order:
  1. Initialize `memory.persistent_fba` and `memory.transient_fba` in place
     using `std.heap.FixedBufferAllocator.init` on the provided slices.
  2. Initialize `memory.persistent_arena` and `memory.transient_arena` from
     `memory.persistent_fba.allocator()` / `memory.transient_fba.allocator()`.
     This is the critical part: arenas reference the FBA fields, which now
     live inside `AppMemory` itself.
  3. Set `ft_library = null`, `ft_face = null`, `ft_is_initialized = false`,
     `ft_init_failed = false`.
  4. Set `browser_state = .Idle`.
  5. Set `current_url`, `response_body`, `error_message` to empty slices.
  6. Set `dom_tree = null`, `layout_tree = null`.
  7. Set the default colors (white background, black text).
  8. Save `persistent` / `transient` slices into
     `persistent_storage` / `transient_storage`.
  9. Set `needs_render = true`.

### Reasoning

The order matters. The arenas should be built only after the in-place FBAs are
written, because those arena allocators are going to reference the FBA fields.
This is the kind of code where construction order is part of correctness, not
just style.

### 3.2 Update `src/linux_platform.zig`
- Keep the existing slice allocations (`persistent`, `transient`).
- Replace the inline `AppMemory` literal with:
  - `var app_memory: types.AppMemory = undefined;`
  - `app.initMemory(&app_memory, persistent, transient);`
- Remove the now-unused stack-local `persistent_buffer`, `transient_buffer`,
  `persistent_arena`, `transient_arena` locals.
- Confirm nothing else still references those locals.

### 3.3 Update `src/win32_platform.zig`
- Apply the same edits. The Win32 file currently mirrors the Linux setup, so
  the diff should be structurally identical.

### Common Mistakes

- Returning `AppMemory` by value from a helper that constructed local FBAs.
- Fixing the duplication but not the lifetime issue.
- Reordering initialization casually without checking which fields reference
  earlier fields.

### 3.4 Verify
- `zig build` clean on both platforms.
- `zig build run -- http://example.com` still works end-to-end.
- Particularly important: navigate, then resize. If the FBA-lifetime fix is
  wrong, this is when corruption would surface.

### Checkpoint Questions

- Which value now owns the allocator state the arenas depend on?
- Why is an in-place initializer safer here than a value-returning constructor?

---

## 4. FreeType Init Ordering

### Why This Step Exists

This step removes an accidental ordering dependency. Right now the code works
because the platform loops happen to initialize FreeType before the user triggers
navigation or reflow. That is not a guaranteed invariant; it is a coincidence of
control flow. Hardening work tries to eliminate exactly these "works today, but
only because of call order" assumptions.

### Before Editing

Trace the current path from user input to text measurement:

- platform key handler -> `app.navigate`
- `app.navigate` -> `app.reflow`
- `app.reflow` -> `layout.layout`
- `layout.layout` -> `measureText`

Then separately trace where font initialization happens today:

- `app.updateAndRender` -> `app.init`

The teaching question for this step is simple: what guarantees, today, that
`measureText` does not run before `app.init`? If the answer is "the current
event loop happens to do that first," then the code is relying on sequence,
not on a protected invariant.

### 4.1 Introduce `ensureFontReady`
- Add a private helper in `src/app.zig`:
  `fn ensureFontReady(memory: *types.AppMemory) !void`.
- Behavior:
  - If `memory.ft_is_initialized` is true, return success.
  - If `memory.ft_init_failed` is true, return an explicit error
    (e.g., `error.FontUnavailable`).
  - Otherwise call the existing `init(memory)`. On error, the existing code
    in `updateAndRender` already sets `ft_init_failed = true` after a failed
    attempt; mirror that behavior here so the failure is sticky, then
    propagate the original error.
- Prefer the smallest explicit error set you can reasonably name. If you widen
  it temporarily for convenience, do it consciously and tighten later.

### Reasoning

The helper turns a timing assumption into an API-level contract: any path that
needs fonts must ensure they are ready before proceeding. That is easier to
understand, easier to reuse, and much safer against future refactors.

### 4.2 Call it from `navigate` and `reflow`
- At the very top of `reflow`, call `ensureFontReady`. On failure:
  - Log the error via `log.err`.
  - **Do not** set `browser_state = .Error`. Without a font we cannot draw
    error text, so the visible error UI is meaningless. Restoring a visible
    error path is a Track 2 follow-up dependent on a fallback font.
  - Return early.
- At the very top of `navigate`, call `ensureFontReady` *before* resetting
  the persistent arena. Same failure handling: log and return. Doing this
  before the reset preserves whatever was previously displayed.

### Reasoning

The ordering inside `navigate` is important. If you reset persistent state first
and then discover fonts are unavailable, you lose the previous page for no good
reason. This is a useful general lesson: validate prerequisites before tearing
down working state.

### 4.3 Leave `updateAndRender` alone
- Its existing lazy-init call now becomes a no-op when already initialized
  (because `ensureFontReady` short-circuits on `ft_is_initialized`). The
  Idle screen continues to paint as today.

### Common Mistakes

- Calling `ensureFontReady` too late in `navigate`, after destructive resets.
- Setting `.Error` for a condition that the renderer cannot visibly display.
- Treating the bug as theoretical because the current app happens not to crash.

### 4.4 Verify
- `zig build` clean.
- Hot path works: launch -> F5 -> page renders.
- Manually force a font failure (temporarily point the font path at a missing
  file) and confirm the app keeps running on the Idle screen, prints an
  `err`-level log line on each navigate attempt, and does not crash.

### Checkpoint Questions

- What hidden assumption did this helper make explicit?
- Why is preserving the previous frame/state better than resetting into a state
  that cannot be rendered?

---

## 5. `layout.zig` Allocator-Error Propagation

### Why This Step Exists

This is the main "stop swallowing allocator failures" step. Right now parts of
layout may print an allocation error and then keep going with partially-built
state. That makes failures harder to reason about because the program no longer
has a clear success/failure boundary.

The point of this step is to convert layout work into a fallible operation with
explicit propagation, so callers can decide how to fail cleanly.

### Before Editing

Read `buildLayoutTree`, `parseWords`, and `layout` in full. For each `catch`,
write down what happens after the failure today.

Ask:

- does the function return early?
- does it continue with a partial object?
- does the caller have any idea that something went wrong?

If the answer to the last question is "not reliably," that is the exact problem
this step fixes.

### 5.1 Change return types
- `pub fn buildLayoutTree(...) std.mem.Allocator.Error!?*types.LayoutBox`.
- `pub fn layout(...) std.mem.Allocator.Error!void`.

### Reasoning

These signatures tell the truth: both operations can fail due to allocation.
Once the signature is honest, the rest of the refactor becomes much more direct.

### 5.2 Replace every swallow site with `try`
- Walk `src/layout.zig` and replace each `catch |err| std.debug.print(...)`
  pattern with `try`. There are several:
  - `allocator.create(types.LayoutBox)` (multiple places)
  - `std.ArrayList(*types.LayoutBox).initCapacity(allocator, ...)` - if you
    completed step 2.1 these may already be removed
  - `layout_box.?.children.append(...)` and similar
  - `parseWords` already propagates; leave it alone
  - `std.ArrayList(types.TextFragment).initCapacity(...)`
  - The fragment `append(...)` inside the word loop
- Each affected helper either returns the error or remains infallible - be
  consistent with the new signatures.

### Reasoning

The goal is not "replace `catch` with `try` everywhere" mechanically. The goal
is to remove states where the layout tree or fragment list is only half-built but
still treated as valid. Every swallow site should be evaluated through that lens.

### 5.3 Update `app.reflow`
- `reflow` now needs to handle the fallible `buildLayoutTree` and `layout`.
- Wrap the call(s) in a single `catch |err|` block:
  - Log via `log.err`.
  - Set `browser_state = .Error`.
  - Set `error_message` to a duped `"Out of memory during layout"` string
    (note the persistent arena was *not* reset by `reflow`, so the dupe is
    safe).
  - Set `needs_render = true` so the error message paints (this depends on
    step 6, but make the assignment now).
  - Return.

### Reasoning

This is one of the most instructive spots in the plan. `reflow` resets the
transient arena, not the persistent arena. That means the error message can be
allocated in persistent storage even while layout reconstruction fails. The key
lesson is to reason about arena lifetime by scope of data, not by where the code
happens to sit.

### 5.4 Update `app.navigate`
- `navigate` indirectly invokes `layout` via `reflow`. The `reflow` error
  path above already handles the failure. Confirm `navigate` does not need
  additional changes beyond the existing `if (memory.layout_tree == null) return;`
  check.

### Common Mistakes

- Preserving partial layout data after an allocation failure.
- Logging the error but not changing control flow.
- Forgetting which arena is safe to allocate the error string into.

### 5.5 Verify
- `zig build` clean.
- Smoke test: navigate works, resize works, no warnings.
- Optional sanity: temporarily shrink the transient slice (e.g., to 64 KiB)
  and confirm an OOM produces an Error state instead of a panic or silent
  half-rendered page. Restore the original size after.

### Checkpoint Questions

- After this step, what does a layout OOM look like to the caller?
- Which partially-valid states are no longer reachable?

---

## 6. Render vs Present Split

### Why This Step Exists

Rendering and presenting are related, but they are not the same operation.

- rendering: draw a new frame into the backbuffer
- presenting: show an already-rendered frame to the OS window surface

Today the platform loops effectively do both every iteration. That wastes work
when nothing changed. But the fix is not "stop painting unless dirty" in the
generic sense, because the OS may still ask the window to repaint an existing
frame after occlusion or uncover.

This step is about learning to separate those responsibilities cleanly.

### Before Editing

Read the Linux event loop and the Win32 message loop side by side.

Identify:

- where a new frame is produced
- where the front buffer is shown again without recomputing content
- which events mutate app state
- which events merely request the current visible contents be presented again

If you can name those separately before editing, the code changes become much
more straightforward.

### 6.1 `AppMemory.needs_render` lifecycle
- Already declared in step 2.4.
- Set `true` in:
  - `app.navigate` (just before returning successfully)
  - `app.reflow` (just before returning successfully, and on the error
    branches that set state)
- Set `false` only in the platform main loops, immediately after a successful
  render+present cycle.

### Reasoning

Keeping the "dirty" bit in app state makes the model explicit: app logic marks
content stale; platform code decides when to satisfy that need by rendering.

### 6.2 Linux main loop (`src/linux_platform.zig`)
- Inside the per-frame loop, after the X event drain:
  - Mark `needs_render = true` from the event handlers that actually mutate
    state:
    - `KeyPress` for F5 (navigate already sets it; mark it explicitly here
      anyway so future keys don't silently miss the flag).
    - `ConfigureNotify` (after calling `reflow`).
  - Replace the unconditional render+blit with:
    - if `app_memory.needs_render`:
      - Refresh `render = backbuffer.getRenderBuffer()` and update
        `buffer.memory` / `buffer.pitch` (already done).
      - Call `app.updateAndRender(...)`.
      - Call `backbuffer.blitAndSwap(...)`.
      - Call `XFlush`.
      - Set `app_memory.needs_render = false`.
    - else: skip render and blit; nothing to present.
- `Expose` continues to call `backbuffer.blitFront(...)` unconditionally so
  occlusion repaints work even when nothing changed.
- Frame pacing (sleep to hit ~60 FPS) stays as-is so the loop still yields
  the CPU when idle.

### 6.3 Win32 main loop (`src/win32_platform.zig`)
- Mirror the Linux changes for state-mutating events:
  - The F5 navigate path sets `needs_render = true` indirectly via
    `navigate`; set it explicitly in the keypress handler too.
  - `WM_SIZE` (or whatever the resize handler is named): after recreating
    the backbuffer and calling `reflow`, set `needs_render = true`.
- In the main message-pump loop, after pumping pending messages:
  - if `app_memory.needs_render`:
    - Call `app.updateAndRender(...)`.
    - Swap front/back via the existing backbuffer helper.
    - Call `InvalidateRect(hwnd, null, FALSE)` to request a `WM_PAINT`.
    - Set `app_memory.needs_render = false`.
  - else: nothing.
- `WM_PAINT` continues to do `BeginPaint` -> blit front DIB -> `EndPaint`.
  This handles both the invalidations we requested above and OS-driven
  occlusion repaints uniformly.

### Common Mistakes

- Using one dirty flag to suppress both render and repaint events from the OS.
- Breaking `Expose` / `WM_PAINT` because "nothing changed".
- Clearing `needs_render` before a successful render/present cycle completes.

### 6.4 Verify
- Linux: navigate, resize, drag another window across to occlude/uncover,
  leave idle 5 s. Expected: rendering correct, occlusion repaint works,
  CPU drops near zero when idle.
- Windows: same scenarios. Expected: exactly one render + one `WM_PAINT`
  per state change; no render storm during a resize drag (multiple
  `WM_SIZE`s collapse into multiple renders, but each is followed by a
  single paint).

### Checkpoint Questions

- Which events require a new frame, and which only require the front buffer to
  be shown again?
- Why would gating `WM_PAINT` or `Expose` on `needs_render` be wrong?

---

## 7. Tests

### Why This Step Exists

This step turns the hardening work into something you can keep. The tests are
not just there to catch regressions later; they are also a way to force yourself
to state the intended behavior precisely enough that the compiler and test runner
can check it.

### How To Approach This Step

Prefer an incremental loop instead of writing the entire suite in one shot:

1. pick one behavior
2. write one failing test
3. run `zig build test` and watch it fail for the expected reason
4. implement or adjust the code
5. rerun until it passes
6. move to the next behavior

This is slower per test, but much better for learning. It keeps each test tied
to a concrete piece of reasoning.

### Before Editing

Decide which tests exercise public behavior and which tests are really about a
private helper or algebraic invariant.

Use that distinction to place tests:

- public surface -> `src/tests.zig`
- private implementation details that should stay private -> in-file `test`
  blocks next to the code

That placement decision is itself part of the design.

### 7.1 `src/tests.zig`
- New file. Imports `std`, `dom.zig`, `layout.zig`, `types.zig`, and
  `c_imports.zig` (transitively pulled in by `layout.zig`).
- Each test is a top-level `test "name" { ... }` block.

#### DOM parser tests
- empty input -> `DOM.root == null`
- single element `<p></p>` -> root is `Element` with tag `p`
- nested elements -> child structure correct
- terminated comment `<!-- ... -->` between tags -> comment skipped, sibling
  text preserved
- unterminated comment at EOF -> parser does not infinite loop, returns
  cleanly
- mixed-case doctype `<!DocType html>` -> skipped, no element created
- void element (e.g., `<br>`) inside a parent -> child added but parent stack
  not pushed; subsequent siblings remain siblings, not children of `<br>`
- quoted `>` inside an attribute value (`<a title="a > b">x</a>`) -> the
  greater-than inside the quotes does not terminate the tag
- mixed-case tag names (`<DIV><P></P></DIV>`) -> tag-name comparisons used
  by void/block/non-visual checks are case-insensitive
- text node creation between tags -> `Text` child present with expected
  content slice

#### `buildLayoutTree` shape tests
- non-visual filtering: an element subtree containing `<head>`, `<style>`,
  `<script>`, `<title>`, `<meta>`, `<link>` produces no layout boxes for
  those nodes
- block vs inline classification: `<div>` -> `.Block`, `<span>` -> `.Inline`
- anonymous-block insertion: a block parent with mixed inline + block
  children gets anonymous wrapper boxes around the inline runs, and the
  block children remain direct children of the parent
- whitespace-only text nodes are dropped (no layout box created)

### Reasoning

These are good first-pass tests because they cover logic that is deterministic,
structural, and independent of the platform event loops. They also lock in
several behaviors already described in `AGENTS.md`, which is useful when future
refactors happen.

### 7.2 In-file `test` blocks in `types.zig`
- Tests for `Dimensions.paddingBox`, `borderBox`, `marginBox`:
  - Build a `Dimensions` with non-zero content rect (e.g., x=10, y=20,
    w=100, h=50) and non-zero edge sizes (different per side to catch
    swapped fields).
  - Assert each box's x/y/width/height matches the expected algebra.
  - One test per method keeps failures localized.

### Reasoning

These are pure value-transform tests. Keeping them next to the code emphasizes
that they are really part of the type's contract.

### 7.3 In-file `test` blocks in `layout.zig`
- Tests for `parseWords`. `parseWords` stays file-private; the tests live
  next to it.
  - empty string -> empty slice
  - leading/trailing whitespace only -> empty slice
  - mixed `\t \n \r ` separators -> tokens with no whitespace
  - single word, no separators -> one token equal to the input
  - using `std.testing.failing_allocator` -> confirm the function returns
    `error.OutOfMemory` rather than swallowing it (this locks in the
    contract you fixed earlier).

### Reasoning

This is a good example of not widening module API just for tests. If a helper is
private by design, prefer testing it locally rather than making it `pub` out of
convenience.

### 7.4 `build.zig` test step
- Add a test compile step whose root is `src/tests.zig`.
- Link the same C dependencies the executable links (libc, FreeType static
  lib, FreeType include path, FreeType config override path). Skip platform
  libraries (`X11`, `Xext`, `gdi32`); the test root never imports the
  platform files.
- Make sure the `build_options` import is added to the test root module too,
  matching the executable, so any future use of `log.zig` from tests works.
- Wire the test step so `zig build test` runs both `src/tests.zig` and any
  in-file `test` blocks reachable from the modules it imports (Zig does
  this automatically for transitively-imported files).

### Common Mistakes

- Making a helper `pub` only to test it.
- Writing a long list of tests before ever running them once.
- Forgetting that importing `layout.zig` brings FreeType into the test build.

### 7.5 Verify
- `zig build test` runs and reports all tests pass.
- Intentionally break one assertion (e.g., flip an expected value) and
  confirm the failure is reported; revert.

### Checkpoint Questions

- Which tests protect public behavior, and which protect private invariants?
- If one of these tests fails in the future, what regression would it most
  likely indicate?

---

## 8. Final Verification Checklist

- [ ] `zig build` succeeds on Linux.
- [ ] `zig build` succeeds on Windows.
- [ ] `zig build test` runs the new tests and they pass.
- [ ] `zig build -Doptimize=ReleaseSafe` produces a quiet binary.
- [ ] `zig build -Ddebug-log=true -Doptimize=ReleaseSafe` is verbose again.
- [ ] `zig build -Ddebug-log=false` is quiet even in Debug.
- [ ] `zig build run -- http://example.com` works: F5 loads, resize reflows,
      occlusion repaint works, idle CPU is low.
- [ ] First navigate after startup does not crash on the FT path
      (proves `ensureFontReady` ordering fix).
- [ ] Forcing a font load failure leaves the app running on the Idle screen
      with `err`-level log output, no crash.
- [ ] Navigate + resize stress (several rapid resizes) does not corrupt the
      DOM/layout (proves `AppMemory`-internal FBA lifetime fix).

### Final Reflection Questions

Before moving on to Track 2, answer these in your own words:

1. Which invariants are now encoded in types rather than in call ordering?
2. Which failure modes are now explicit rather than logged-and-ignored?
3. Which platform behaviors now present cached work rather than recomputing it?
4. Which parts of the code still rely on implicit assumptions and should be
   candidates for future hardening?

If you cannot answer those clearly, reread the modified sections before moving
on. The point of this track is as much to sharpen your reasoning model as it is
to improve the code.

---

## 9. Track 2 Follow-ups (Out of Scope Here)

Captured so they are not lost:

- Restore a visible Error UI for font failures by introducing a fallback
  rendering path (e.g., a tiny embedded bitmap font) so the engine can draw
  errors even with no usable TTF.
- Split `layout.zig` into a pure logic module and a FreeType-dependent
  measurement module (e.g., `text_metrics.zig`) so logic tests can run
  without linking FreeType. Sequence this with the bold/italic/heading work
  in Track 2 so the seam is designed once.
- Move attribute parsing into a structured `[]Attribute{name, value}` model
  on `ElementNode`. Required before CSS, links, or any feature that touches
  `id`/`class`/`href`/`src`/`style`.
