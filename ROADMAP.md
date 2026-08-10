# Usable — Development Roadmap

A reference document for working through browser implementation from first principles.
Steps are ordered to maximize learning payoff and minimize blocking dependencies.
Each step builds directly on the last.

---

## How to Use This Document

This is not a spec. It is a map. The goal of each step is not just to make something
work — it is to understand *why* a real browser does it that particular way. Before
writing any code, read about how browsers actually handle the problem. Compare what
you find to what you end up building. The gaps between spec and reality are where
the most interesting learning happens.

When you finish a step, resist the urge to immediately move to the next one. Sit with
what you built. Break it intentionally. Load pages that expose its limits. That process
will tell you more than the implementation itself.

For each step, try to work in this order:
- Identify the browser concept you are trying to model.
- Identify the Zig concepts the feature will force you to practice.
- Find the smallest file/function boundary where the change belongs.
- Make one tiny HTML page or synthetic test case that should behave differently after
  the change.
- Implement the smallest useful version first, even if it is incomplete by browser
  standards.
- Write down the limitation you intentionally accepted before moving on.

---

## Zig Skills This Roadmap Exercises

Use this as a parallel learning map. When a step feels difficult, it is often because
one of these Zig ideas is also being exercised at the same time as the browser idea.

- **Slices and lifetimes:** DOM text, tag names, attributes, response bodies, and text
  fragments frequently point into larger buffers. Know which buffer owns the bytes and
  how long those bytes remain valid.
- **Optionals:** Missing attributes, absent layout trees, failed hit tests, and nullable
  C pointers are common. Practice making absence explicit instead of using sentinel
  values.
- **Error unions:** Parsing, allocation, HTTP fetches, and C library setup can fail.
  Decide which errors should propagate and which should turn into browser-visible
  fallback behavior.
- **Allocators:** This project intentionally separates page-lifetime data from
  layout-pass data. Most new features should ask whether data belongs in the persistent
  arena, the transient arena, temporary stack storage, or a platform-owned buffer.
- **Tagged unions and enums:** DOM nodes already use a tagged union. CSS values, display
  modes, parser states, and input events are natural places to practice the same idea.
- **C interop:** FreeType, X11, and Win32 require pointer handling, nullable pointers,
  integer casts, and respect for external ownership rules.
- **Integer and float conversions:** Layout uses floating-point coordinates, platform
  APIs use integers, and framebuffer drawing uses byte-level offsets. Be deliberate
  about every conversion.
- **Testing small units:** The browser is visual, but many pieces can be tested without
  opening a window: attribute parsing, CSS parsing, URL resolution, layout fragments,
  and hit testing.

---

## Suggested Step Template

Each roadmap step now includes practical scaffolding. Treat it as a checklist, not a
contract. If you discover a smaller path while working, prefer the smaller path.

- **Code starting points** tell you where to read first.
- **Implementation checkpoints** describe a reasonable sequence of small milestones.
- **Zig concepts practiced** call out the language/runtime ideas behind the work.
- **Tiny test pages** are hand-written HTML cases that should expose the behavior.
- **Definition of done** describes the minimum result before moving on.
- **Further reading/search terms** give concrete places to continue learning.

---

## Step 1 — Attribute Parsing

**Why this first:**
Nearly everything else in a browser depends on reading element attributes. CSS classes,
link targets, image sources, form field names — all of these live in attributes. Right
now `raw_attributes` is an unparsed string sitting on every element node, completely
unreadable by the rest of the code. Until you fix this, you are essentially stuck: you
cannot follow links, apply styles, load images, or identify elements by class or id.
This is the most load-bearing gap in the current codebase.

**What to think about:**
Attribute parsing sounds simple until you look at real HTML. Values can be quoted with
double quotes, single quotes, or not quoted at all. Attribute names are case-insensitive.
Some attributes are boolean flags with no value (`disabled`, `checked`, `hidden`). Some
values contain characters that look like delimiters. Some attributes appear multiple
times on the same element (technically invalid, but browsers handle it).

Think about what data structure makes attributes easy to query. A slice of name/value
pairs is the obvious choice, but consider how you will look things up. You will be
calling something like `getAttribute("href")` constantly during layout and painting —
how fast does that need to be? At this project's scale, a linear scan is fine, but it
is worth understanding why browsers use more sophisticated structures internally.

**Questions to sit with:**
- Where should attribute data live in memory? Should it point into the original HTML
  source buffer, or should values be copied? What are the lifetime implications of each?
- How does the HTML5 parsing spec handle the case where an attribute appears twice?
- What should `getAttribute` return when the attribute is absent? An optional? An empty
  string? How does your choice affect calling code?

**Learning directions:**
- Read the "before attribute name state" section of the HTML5 tokenizer spec. It is
  surprisingly detailed and will give you an appreciation for how much edge-case
  thinking goes into something that looks trivial.
- Look at how simple HTML parsers (not full spec-compliant ones) handle this.
  The difference in complexity is instructive.

**Code starting points:**
- `src/types.zig`: `ElementNode` currently stores `raw_attributes` only.
- `src/dom.zig`: `DOM.parse()` finds the tag name and leaves the rest as raw text.
- `src/layout.zig`: future display/style decisions will need easy attribute lookup.

**Implementation checkpoints:**
- First define what structured attribute data should represent: name, optional value,
  boolean presence, and original casing vs normalized comparison.
- Parse the simplest quoted attribute form first.
- Add single-quoted values after double-quoted values work.
- Add unquoted values.
- Add boolean attributes with no explicit value.
- Decide how duplicate attribute names behave and document that choice.
- Add an attribute lookup helper before using attributes elsewhere.
- Add tests or debug cases before moving to CSS or links.

**Zig concepts practiced:**
- Slices that point into the response body instead of copying strings.
- Optional values for attributes that may be absent or boolean.
- Arena allocation for page-lifetime DOM data.
- ASCII case-insensitive comparison without changing the original bytes.
- Error handling for malformed input vs permissive browser behavior.

**Tiny test pages:**
- A page with one link using a double-quoted `href`.
- A page with single-quoted attributes.
- A page with unquoted attributes.
- A page with a boolean attribute such as `disabled` or `hidden`.
- A page with `>` inside a quoted attribute value to make sure existing tag scanning
  still works.

**Definition of done:**
- Attribute lookup can find `href`, `id`, `class`, and `style` regardless of attribute
  name casing.
- Boolean attributes are represented intentionally, not accidentally as parse failures.
- Existing parsing behavior for comments, doctypes, void elements, and quoted `>` still
  works.
- `raw_attributes` is either replaced or kept only for debugging/backstop purposes.

**Further reading/search terms:**
- HTML Living Standard tokenizer attribute states.
- HTML boolean attributes.
- HTML duplicate attributes parse error.
- Zig slices and allocator lifetimes.

---

## Step 2 — Inline Formatting Context

**Why this second:**
Right now, inline elements that should flow together horizontally each restart their
cursor independently from the left edge. `<p>Hello <b>world</b></p>` renders "Hello"
and "world" stacked on top of each other rather than side by side. This is the single
most visually broken behavior in the current layout engine. Fixing it requires
understanding one of the foundational concepts in CSS layout: the inline formatting
context.

**What to think about:**
The core idea is that a group of sibling inline elements should share a single "cursor"
as they flow across the page. Words from one element continue from where the previous
element left off, and line breaks happen cooperatively across the whole group — not
independently within each element.

This means your layout function can no longer process each inline child in isolation.
Inline children of the same block container need to be processed together, passing
state (the current x position, the current line's height, and which fragments belong
to the current line) from one child to the next.

Think about what "a line" means. A line is not a DOM node or a layout box — it is
an emergent concept that exists only during layout. A line is done when you run out
of width. At that point you commit the fragments on that line to their final positions
and start a new one. This is why CSS calls them "line boxes."

**Questions to sit with:**
- When a line wraps mid-element (e.g., a long word forces a break inside a `<span>`),
  the element's layout box spans multiple lines. How does your data model handle this?
- How do you handle vertical alignment within a line? If one inline element has a large
  font and another has a small font, how do you align their baselines?
- What happens when a block element appears in the middle of inline content? (CSS calls
  this a "block in inline" problem and the answer is surprising.)

**Learning directions:**
- Read the CSS2 spec section on "inline formatting contexts." It is dense, but reading
  it will reveal why the implementation is structured the way it is.
- Understanding the difference between "line boxes" (CSS) and "text runs" (lower-level
  text rendering) is important here. They are related but not the same thing.

**Code starting points:**
- `src/layout.zig`: `layout()` currently lays out inline children independently.
- `src/layout.zig`: `TextFragment` placement is word-based and already records x/y.
- `src/types.zig`: `LayoutBox.fragments` is where text output currently lands.
- `src/app.zig`: `paint()` already draws fragments and may not need to change first.

**Implementation checkpoints:**
- Start by observing the current broken case with text around a simple inline element.
- Identify where sibling inline boxes lose shared cursor state.
- Create a temporary layout-time concept of a line without making it a permanent DOM
  or layout node yet.
- Make adjacent inline text continue horizontally within the same block container.
- Make inline element children participate in the same cursor flow as surrounding text.
- Add wrapping across multiple inline siblings.
- Only after that, revisit line height, baselines, and multi-line inline boxes.

**Zig concepts practiced:**
- Passing mutable layout state through helper functions by pointer.
- Separating temporary stack state from arena-backed layout results.
- Modeling state with small structs rather than many loose parameters.
- Being careful with recursion when siblings need shared state.

**Tiny test pages:**
- A paragraph with plain text, a bold/span element, and more plain text after it.
- A paragraph where the inline element appears near the right edge and forces wrapping.
- A paragraph with several short inline elements in a row.
- A paragraph with one very long word to expose wrapping limitations.

**Definition of done:**
- Inline siblings in a block share one horizontal flow.
- Text before and after an inline element appears on the same line when space allows.
- Wrapping decisions consider the line as a whole, not each inline child separately.
- Known limitations, especially baseline alignment, are documented before moving on.

**Further reading/search terms:**
- CSS inline formatting context.
- CSS line boxes.
- CSS anonymous inline boxes.
- Text runs vs line layout.
- Zig pointer parameters and temporary structs.

---

## Step 3 — Scrolling

**Why this third:**
Any real page overflows the viewport. Without scrolling, you can only see the top of
whatever you load. This is also a good early opportunity to think about the relationship
between "layout coordinates" and "screen coordinates" — a distinction that becomes very
important as the rendering pipeline grows.

**What to think about:**
Scrolling is fundamentally a transform applied during painting, not during layout.
Layout always computes positions in "page space" — the coordinate system of the full
document, starting from (0, 0) at the top-left of the content. The viewport is a
window into that space. When you scroll, you move that window; the layout coordinates
do not change.

This means your render/paint function needs to know the current scroll offset and
subtract it from every position before drawing. A fragment at page-space y=800 should
only be drawn if the viewport scroll offset is close enough to 800 for it to be visible.
Clipping fragments that are entirely outside the viewport is an optimization, but
correctness comes first.

Think about what drives scrolling. Keyboard events (arrow keys, Page Up/Down, Home/End)
are the simplest. Mouse wheel events come next. Each platform delivers these differently.

**Questions to sit with:**
- The current layout reserves 40px at the top for a future address bar. How does scroll
  offset interact with that reserved space? Should the address bar scroll with the
  content or stay fixed?
- What is the maximum valid scroll offset? It depends on the total content height, which
  your layout engine already computes. How do you get that value to the input handler?
- What should happen when you navigate to a new page — should scroll reset to zero?
  What about when you resize the window?

**Learning directions:**
- Look up "paint order" in the CSS spec. It will give you a sense of how browsers
  think about the layering of painted output vs. layout coordinates.
- The concept of a "scroll container" in CSS is worth understanding even if you do not
  implement it yet.

**Code starting points:**
- `src/types.zig`: `AppMemory` is the likely place for current scroll state.
- `src/app.zig`: `paint()` and `drawText()` currently use layout coordinates directly.
- `src/linux_platform.zig`: input handling currently covers keyboard and resize.
- `src/win32_platform.zig`: input handling currently covers keyboard and resize.

**Implementation checkpoints:**
- Add vertical scroll state without changing layout coordinates.
- Apply the scroll offset only during painting.
- Clamp scroll offset so it cannot go before the top or beyond the document bottom.
- Reset scroll when navigating to a new page.
- Decide what resize should do to the current scroll position.
- Add keyboard scrolling before mouse wheel scrolling.
- Add simple clipping or skip drawing fragments that are clearly outside the viewport.

**Zig concepts practiced:**
- Adding persistent app state safely to a shared struct used by both platforms.
- Converting between integer input deltas and floating-point layout coordinates.
- Clamping values with clear bounds.
- Keeping coordinate-space transformations explicit.

**Tiny test pages:**
- A page with many paragraphs that extends far below the viewport.
- A page with a short body that should not scroll.
- A page with content just slightly taller than the viewport.
- A page loaded after scrolling another page to confirm scroll resets.

**Definition of done:**
- Layout positions remain in page space.
- Painting subtracts scroll offset consistently.
- Keyboard scrolling works on both supported platform paths or the unsupported path is
  explicitly noted.
- Scroll offset is clamped based on content height and viewport height.

**Further reading/search terms:**
- Browser viewport vs document coordinates.
- CSS scroll container.
- CSS overflow basics.
- X11 key events arrow keys Page Up Page Down.
- Win32 virtual key codes scrolling.

---

## Step 4 — Font-Size-Aware Layout

**Why this fourth:**
Currently all text renders at 16pt regardless of the element. `<h1>` looks identical
to `<p>`. Fixing this requires threading font size through your layout traversal and
varying FreeType settings per text box. It also forces you to confront a fundamental
layout dependency: the size of a text box depends on the font, which means you need
to know the font before you can measure the text.

**What to think about:**
Font size in CSS is inherited. If you set `font-size: 24px` on a `<div>`, everything
inside that `<div>` uses 24px unless overridden. This means your layout traversal
needs to carry a "current font size" value down the tree, updating it when it
encounters an element that specifies a different size.

Even before you have a real CSS engine, you can hardcode reasonable defaults per
tag name: `<h1>` gets 2em, `<h2>` gets 1.5em, `<h3>` gets 1.17em, and so on.
This gives you visual differentiation with almost no CSS infrastructure.

Think about what "1em" means. It means "the current font size." So `<h1>` at 2em
means twice the body font size, not twice some absolute value. This is why font
size in CSS is described as a cascade — each element's size is relative to its
parent's.

**Questions to sit with:**
- FreeType requires you to set the character size before measuring or rendering a glyph.
  If different elements use different font sizes, when do you switch sizes? Do you switch
  per text box? Per word? Per character? What are the performance implications?
- Line height is related to font size but not identical to it. A line of 16px text is
  typically taller than 16px because of descenders and leading. How does this interact
  with your line-box height calculations?
- What do you do with font size units that are not pixels? `em`, `rem`, `%`, `pt` —
  each requires different context to resolve.

**Learning directions:**
- Read about the CSS "cascade" and "inheritance." Font size is one of the most
  commonly inherited properties and a good one to start with.
- Look up how FreeType interprets its size arguments. The relationship between points,
  pixels, and DPI is a common source of confusion.

**Code starting points:**
- `src/app.zig`: `init()` sets one FreeType character size globally today.
- `src/layout.zig`: `measureText()` assumes the current FreeType face size.
- `src/app.zig`: `drawText()` renders using the current FreeType face size.
- `src/types.zig`: text fragments may need enough style information to render later.

**Implementation checkpoints:**
- Start with hardcoded default font sizes for a few tags before parsing CSS values.
- Thread an inherited font-size value through layout tree construction or layout.
- Make measurement use the font size intended for the text being measured.
- Ensure rendering uses the same font size that measurement used.
- Decide where font size is stored so repainting does not lose the information.
- Revisit line height after different font sizes appear on the same page.

**Zig concepts practiced:**
- Carrying contextual state through tree traversal.
- Deciding whether data belongs on layout boxes, fragments, or temporary traversal state.
- Managing mutable C library state when measuring and drawing.
- Avoiding hidden dependencies between measurement and rendering.

**Tiny test pages:**
- A page with heading and paragraph elements.
- A page with nested elements where the child should inherit the parent size.
- A page with several heading levels.
- A page with large text that wraps differently from normal text.

**Definition of done:**
- Headings visibly differ from body text.
- Text measurement and text rendering agree for the same font size.
- Resize/reflow preserves font-size-dependent layout.
- Any unsupported CSS units are explicitly out of scope for this step.

**Further reading/search terms:**
- CSS font-size inheritance.
- CSS em rem px pt units.
- FreeType set char size vs pixel size.
- FreeType glyph metrics ascender descender advance.

---

## Step 5 — Basic CSS Parsing

**Why this fifth:**
Visual differentiation (colors, spacing, font weight) matters both for making pages
readable and for your own motivation. You do not need a full CSS engine to get
meaningful visual output. Start narrow: parse inline `style` attributes only (no
external stylesheets, no `<style>` blocks yet), and support a small, deliberate
subset of properties.

**What to think about:**
CSS parsing and CSS application are two separate problems. Parsing turns a string
like `"color: red; font-size: 18px"` into structured data. Application takes that
structured data and uses it to influence layout and painting. Keep these phases
distinct in your code.

The smallest useful property set for first pass: `color`, `background-color`,
`font-size`, `font-weight`, `display`, `margin`, and `padding`. These cover the
most visible aspects of page appearance and directly map to things your layout and
render code can already use (or nearly use).

Think about where computed styles live. They should live on the layout tree, not on
the DOM tree. The DOM represents the document structure; computed styles represent
how a particular layout box should be rendered. Keeping these separate means you
can rebuild the layout tree without re-parsing the DOM, and you can (eventually)
apply different styles for different media or states.

**Questions to sit with:**
- A "computed style" struct needs to distinguish between "this property was explicitly
  set to X" and "this property was not set and should inherit from the parent." How
  do you represent that distinction? Optionals? A separate bitmask of set properties?
- What should the default styles be for elements when no CSS is applied? Browsers have
  a built-in "user agent stylesheet" that provides these defaults. What is the minimal
  version of that you need?
- How do you parse CSS color values? `red`, `#ff0000`, `rgb(255, 0, 0)`, and
  `rgba(255, 0, 0, 1)` are all the same color. How much of this do you want to handle
  at first?

**Learning directions:**
- Read the CSS2 "visual formatting model" section. It is foundational to understanding
  why CSS is designed the way it is.
- The concept of "initial value," "inherited value," and "computed value" in CSS are
  distinct and worth understanding before you implement inheritance.

**Code starting points:**
- `src/types.zig`: add style-related data only where it has the right lifetime.
- `src/dom.zig`: structured attributes from Step 1 are needed to read inline `style`.
- `src/layout.zig`: layout needs computed values such as display, margin, padding, and
  font size.
- `src/app.zig`: painting needs computed color/background data.

**Implementation checkpoints:**
- Keep CSS declaration parsing separate from applying styles.
- Parse one property at a time rather than all CSS syntax at once.
- Start with properties that visibly affect existing rendering.
- Decide how invalid declarations are ignored.
- Define a minimal computed style with defaults.
- Apply inheritance only for properties that should inherit.
- Keep unsupported properties harmless.

**Zig concepts practiced:**
- Tokenizing a byte slice without unnecessary allocation.
- Modeling CSS values with enums, structs, or tagged unions.
- Representing optional specified values vs resolved computed values.
- Error-tolerant parsing where invalid input should not stop the page.

**Tiny test pages:**
- A paragraph with inline text color.
- A heading with a larger inline font size.
- A block with margin or padding that changes layout.
- A block with background color once box painting exists, or a note that it is waiting
  for Step 7.

**Definition of done:**
- Inline `style` attributes can affect at least color and font size.
- Invalid or unknown declarations are ignored without breaking the rest of the style.
- Computed style is separate from DOM structure.
- The supported property list is documented.

**Further reading/search terms:**
- CSS declaration parsing.
- CSS initial inherited specified computed used values.
- CSS visual formatting model.
- MDN CSS cascade inheritance specificity.
- Zig tagged unions for value types.

---

## Step 6 — Link Navigation

**Why this sixth:**
A browser that cannot follow links is not really a browser. This step ties together
several earlier pieces: attribute parsing (to read `href`), layout (to know where
anchor boxes are on screen), input handling (to detect clicks), and navigation
(already implemented in `app.zig`). The integration work here is often more
instructive than the individual pieces.

**What to think about:**
Following a link requires knowing which part of the screen corresponds to which DOM
node — this is called "hit testing." Your layout tree already has position and
dimension information for every box. During a mouse click, you walk the layout tree
and find the innermost box whose bounds contain the click coordinates. If that box
(or one of its ancestors) is an `<a>` element with an `href`, you navigate.

Think about what "innermost" means in a tree. You want the most specific match — the
deepest box in the tree that contains the click point, not just the first one you find.
This is a depth-first search with a spatial condition.

Also think about how links should look different from regular text. Underlines and
color are the conventional signals. This requires either CSS (Step 5) or a hardcoded
special case for `<a>` elements during painting.

**Questions to sit with:**
- What scroll offset do you need to account for when hit-testing? The click coordinates
  come from the screen; the layout coordinates are in page space. You need to add the
  scroll offset back before comparing.
- What should happen when you click a link while a page is already loading? The current
  navigate function is synchronous, so this cannot happen yet — but it is worth
  thinking about.
- How do you handle relative URLs (e.g., `href="/about"` or `href="../page.html"`)?
  You need to resolve them against the current page's URL. What does that require?

**Learning directions:**
- Read about URL parsing. A URL is more structured than it looks: scheme, authority,
  path, query, fragment — each has different resolution rules for relative URLs.
- Hit testing is also used for hover effects and cursor changes. The same tree walk
  you build for clicks will be reused for those features later.

**Code starting points:**
- `src/types.zig`: layout boxes already have dimensions and optional DOM nodes.
- `src/app.zig`: `navigate()` already handles loading a URL synchronously.
- `src/app.zig`: `paint()` shows how to traverse the layout tree.
- `src/linux_platform.zig`: add mouse button events for Linux.
- `src/win32_platform.zig`: add mouse button events for Windows.

**Implementation checkpoints:**
- Add mouse click input at the platform layer.
- Convert screen coordinates into page coordinates by accounting for scroll offset.
- Walk the layout tree to find the deepest box containing the click point.
- Climb from the hit box toward ancestors until an anchor element is found.
- Read the anchor `href` using the attribute helper from Step 1.
- Start with absolute URLs before handling relative URLs.
- Add a simple visual distinction for links if CSS has not made them visible yet.

**Zig concepts practiced:**
- Returning optional pointers from tree searches.
- Recursive traversal with a clear tie-breaking rule for deepest match.
- Passing input events from platform code into shared app code.
- Handling URL string lifetime before navigation resets arenas.

**Tiny test pages:**
- A page with one absolute link.
- A page with a link inside a paragraph after inline layout is fixed.
- A page with multiple nearby links to test hit precision.
- A page with a relative link after URL resolution is attempted.

**Definition of done:**
- Clicking visible link text navigates to the target URL.
- Hit testing accounts for scroll offset.
- Non-link text does not navigate.
- Relative URL support is either implemented or clearly deferred.

**Further reading/search terms:**
- Browser hit testing layout tree.
- URL relative resolution path query fragment.
- X11 ButtonPress events.
- Win32 WM_LBUTTONDOWN.
- Zig optional pointer return values.

---

## Step 7 — Box Painting

**Why this seventh:**
Right now, element boxes are invisible. Only text is drawn. Adding background colors
and borders is what makes a page look like a page rather than a list of floating words.
This step requires drawing filled rectangles and border outlines in your software
framebuffer — a small but satisfying addition to `OffscreenBuffer`.

**What to think about:**
The order in which you paint things matters. CSS specifies a precise painting order to
handle overlapping elements correctly. At minimum: paint background colors first,
then borders, then content (text, images), then children. If you paint children before
backgrounds, children will appear behind their parent's background.

Think about clipping. A child box can extend outside its parent's bounds (due to
negative margins or overflow settings). Whether that child is visible or clipped
depends on the parent's `overflow` property. For now, not clipping is fine — it just
means some content may appear outside where you expect.

The relationship between the box model and painting is direct: the background fills
the border box (the area including padding but not margins), and the border is drawn
on the border edge. Getting these coordinates right requires your `paddingBox` and
`borderBox` helper functions, which already exist in `types.zig`.

**Questions to sit with:**
- How do you draw a border that is just 1px wide without it feeling aliased or
  muddy? Your framebuffer is BGRA8 — consider whether you want to subpixel-hint
  thin lines or just accept the integer grid.
- How do you handle `border-radius`? Rounded corners are a surprisingly complex
  rendering problem. It is fine to skip them for now, but understand why.
- What color do you use when no background or border is specified? Transparent means
  "show whatever is behind this element" — which requires compositing. Think about
  how your current framebuffer handles transparency.

**Learning directions:**
- The CSS "paint order" specification is worth skimming. It explains why elements
  are drawn in a specific order and how `z-index` and stacking contexts complicate it.
- Looking at how other software renderers handle anti-aliasing for thin rectangles
  is useful background, even if you do not implement it yet.

**Code starting points:**
- `src/types.zig`: `OffscreenBuffer` currently clears and draws FreeType bitmaps.
- `src/types.zig`: `Dimensions.paddingBox()`, `borderBox()`, and `marginBox()` already
  compute useful geometry.
- `src/app.zig`: `paint()` controls traversal order.
- `src/layout.zig`: dimensions currently exist even though boxes are not painted.

**Implementation checkpoints:**
- Add a framebuffer operation for filled rectangles.
- Add a framebuffer operation for simple rectangular borders.
- Paint element backgrounds before text content.
- Paint borders after backgrounds but before or around content intentionally.
- Use the existing box-model helper methods instead of recalculating geometry by hand.
- Add clipping later; start with correct coordinates first.

**Zig concepts practiced:**
- Byte-level framebuffer writes and pointer arithmetic.
- Integer conversion from floating-point layout rectangles to pixel rectangles.
- Bounds checks to avoid writing outside the buffer.
- Reusing struct methods to avoid duplicating geometry logic.

**Tiny test pages:**
- A block with background color.
- A block with padding and background color to verify the painted area.
- A block with a simple border.
- Nested blocks with different backgrounds to observe paint order.

**Definition of done:**
- Backgrounds and borders use border-box/padding-box semantics intentionally.
- Text remains visible after backgrounds are painted.
- Drawing is clipped or safely bounded to the framebuffer.
- Unsupported features such as border radius and transparency are documented.

**Further reading/search terms:**
- CSS box model painting backgrounds borders.
- CSS painting order.
- Software renderer rectangle fill clipping.
- BGRA pixel format.

---

## Step 8 — Address Bar

**Why this eighth:**
The current interaction model — press F5 to reload the hardcoded URL — is the biggest
usability limitation. An address bar turns the project from a static page renderer
into something interactive. It also introduces UI widget implementation, which is a
genuinely different kind of problem from document rendering.

**What to think about:**
An address bar is a text input widget. Text input requires: capturing keyboard
characters (not just key codes), maintaining a string buffer that grows and shrinks
as the user types, drawing the current text content, and drawing a cursor that shows
the insertion point. Each platform delivers keyboard input differently — Win32 uses
`WM_CHAR`, while X11 requires `XLookupString` or XInput2.

Think about the cursor. A blinking cursor is a timed animation — it requires a
concept of "wall clock time" to know when to toggle visibility. The Linux platform
already has a frame timer; you can derive cursor blink state from it.

Think about the address bar's relationship to the rest of the layout. It should be
fixed at the top of the viewport, not scrolling with the page content. The 40px
offset currently reserved in `reflow()` is waiting for exactly this.

**Questions to sit with:**
- What happens when the user's typed URL is longer than the address bar can display?
  You need some form of horizontal text scrolling within the input field.
- How do you handle the Enter key? You need to distinguish it from other keys and
  use it to trigger navigation.
- Should the address bar update to show the current URL when navigation completes?
  What about during loading?

**Learning directions:**
- Look at how browsers handle address bar interactions. The URL displayed is often
  different from the raw URL (e.g., stripping `https://`, showing the domain in bold).
  These are UX decisions, not technical requirements, but they are interesting.
- Text editing in a simple input field is a microcosm of the same problems in a full
  text editor: cursor movement, selection, clipboard, undo. You are implementing the
  simplest possible version.

**Code starting points:**
- `src/app.zig`: `render()` already draws a temporary current-URL line at the top.
- `src/app.zig`: `navigate()` can be called after Enter is pressed.
- `src/types.zig`: `AppMemory` may need UI state for focus, input text, cursor, and
  blink timing.
- `src/linux_platform.zig`: X11 key events need character translation, not just keycodes.
- `src/win32_platform.zig`: Win32 has separate keydown and character messages.

**Implementation checkpoints:**
- Draw a fixed address bar area before adding text editing.
- Store editable address text separately from `current_url`.
- Capture printable characters.
- Add Backspace before adding cursor movement.
- Add Enter-to-navigate.
- Add focus rules so typing only edits the bar when intended.
- Add cursor drawing without worrying about blinking first.
- Add horizontal scrolling for long URLs later.

**Zig concepts practiced:**
- Mutable byte buffers for user-edited text.
- Distinguishing keyboard control keys from text input.
- Persistent UI state that survives frames but resets intentionally.
- UTF-8 tradeoffs: byte cursor first vs codepoint-aware editing later.
- Platform-specific input translated into shared app behavior.

**Tiny test pages:**
- Any page loaded from a typed absolute URL.
- A deliberately invalid URL to check error handling.
- A long URL to expose text clipping/scrolling needs.
- A reload of the current page after editing the address text.

**Definition of done:**
- The address bar is fixed and does not scroll with page content.
- Printable typing, Backspace, and Enter work for basic ASCII URLs.
- Navigation from typed input uses the same page-loading path as F5/link navigation.
- Limitations around selection, clipboard, Unicode editing, and long text are documented.

**Further reading/search terms:**
- X11 XLookupString text input.
- Win32 WM_CHAR vs WM_KEYDOWN.
- Text input cursor model.
- Browser location bar UX.
- Zig ArrayList for mutable text buffers.

---

## Step 9 — `<style>` Block and Selector Matching

**Why this ninth:**
Inline styles only get you so far. Real pages define their appearance in `<style>`
blocks or external stylesheets. Implementing a CSS selector engine — even a simple
one — exposes you to one of the most algorithmically interesting parts of browser
engineering: matching rules to elements efficiently.

**What to think about:**
CSS selectors range from trivial (type selectors: `p`, `div`) to complex (`:nth-child`,
pseudo-elements, combinators). For a first pass, type selectors, class selectors
(`.foo`), and id selectors (`#bar`) cover the majority of what simple pages actually
use.

The cascade is the hard part. Multiple rules can match the same element. Which one
wins? CSS specificity determines this: id selectors beat class selectors beat type
selectors. If specificity is equal, the rule that appears later in the stylesheet wins.
You need a way to compute specificity and sort or merge rules.

Think about when to apply styles. You could apply them during DOM parsing, during
layout tree construction, or as a separate pass between them. A separate "style
resolution" pass is the cleanest architecture because it keeps concerns separate.

**Questions to sit with:**
- What is the correct order to apply a user-agent stylesheet (your built-in defaults),
  an author stylesheet (from the page), and inline styles? CSS defines this precisely.
- How do you handle a selector you do not recognize? Silently ignoring it is the
  correct behavior — do not abort or error on unknown selectors.
- Inheritance means a computed style depends on the parent's computed style. This
  requires that you process the tree top-down during style resolution, parent before
  children. Does your current traversal order support this?

**Learning directions:**
- The CSS "cascade" and "specificity" sections of the spec are worth reading carefully.
  These concepts are central to CSS and often misunderstood.
- Look up how the Servo browser engine (Mozilla's Rust-based experimental engine)
  handled selector matching. Their "stylo" work has good documentation on the
  algorithmic challenges.

**Code starting points:**
- `src/dom.zig`: `<style>` elements are currently skipped as non-visual later, but their
  text content can still be parsed from the DOM.
- `src/layout.zig`: non-visual filtering currently excludes `style` from layout output.
- `src/types.zig`: style rules and selectors need page-lifetime storage.
- `src/layout.zig` or a future style module: computed style should be resolved before
  layout uses it.

**Implementation checkpoints:**
- Extract text from `<style>` blocks without rendering it.
- Parse a simple list of CSS rules.
- Support type selectors first.
- Add class selectors after attribute parsing can read `class`.
- Add id selectors after attribute parsing can read `id`.
- Compute specificity for the supported selector subset.
- Resolve styles top-down so inheritance has parent context.
- Keep unknown selectors and declarations ignorable.

**Zig concepts practiced:**
- Page-lifetime arrays of rules, selectors, and declarations.
- Tree traversal that combines parent context with matching rules.
- Sorting or comparing specificity without overbuilding the engine.
- Designing small modules when parser/style/layout concerns start to separate.

**Tiny test pages:**
- A page with a type selector changing all paragraphs.
- A page with a class selector changing one element among several.
- A page with an id selector overriding a type selector.
- A page where later equal-specificity rules override earlier ones.

**Definition of done:**
- `<style>` text is parsed but not rendered as page text.
- Type, class, and id selectors work for simple cases.
- Specificity and source order decide conflicts for the supported subset.
- Unknown selector syntax is ignored without aborting the whole stylesheet.

**Further reading/search terms:**
- CSS selector specificity.
- CSS cascade origins order.
- CSS rule parsing error recovery.
- Servo Stylo selector matching overview.
- Zig sorting/comparison patterns.

---

## Step 10 — Image Decoding

**Why this tenth:**
Most real pages include images. `<img>` tags currently parse correctly but render as
nothing because there is no image decoding pipeline. Adding image support requires
reading attributes (Step 1), fetching sub-resources, decoding pixel data, and blitting
it into your framebuffer.

**What to think about:**
Images are a sub-resource problem: loading a page is no longer a single HTTP request
but potentially dozens. Each `<img>` tag's `src` might be a relative URL (requiring
URL resolution from Step 6), a data URI, or an absolute URL. Even with synchronous
fetching, handling multiple images requires deciding which to load and in what order.

Format support is a separate concern. PNG and JPEG cover the vast majority of images
on the web. You will need a decoder for each. Vendoring a minimal single-file decoder
(like `stb_image`) is the pragmatic choice; writing your own PNG decoder from the spec
is an excellent learning exercise if that is the goal.

Think about sizing. Images have intrinsic dimensions (the pixel dimensions of the
decoded image), but CSS can override them with `width` and `height` properties, or
the `<img>` tag's own `width`/`height` attributes. Scaling a decoded image requires
at minimum a nearest-neighbor resample into your framebuffer.

**Questions to sit with:**
- Where does decoded image data live in memory? It should probably go in the persistent
  arena alongside the DOM, but a large image can consume a significant portion of your
  32 MiB budget.
- What do you do if an image fails to load? Browsers show a broken image icon. Even
  a simple colored rectangle placeholder is better than nothing.
- How does image layout interact with inline flow? An `<img>` inside a `<p>` is treated
  as an inline element, meaning it participates in line-box layout and can have text
  flowing beside it.

**Learning directions:**
- Reading the PNG spec (or a good summary of it) before using a library gives you
  a deep appreciation for the complexity of a format that looks simple from the outside.
- Look up "replaced elements" in CSS. Images are the canonical example — elements
  whose content comes from outside the document and have intrinsic dimensions.

**Code starting points:**
- `src/dom.zig`: `<img>` is already treated as a void element.
- `src/types.zig`: decoded image data needs a page-lifetime representation.
- `src/layout.zig`: images need layout dimensions and may participate in inline flow.
- `src/app.zig`: fetching subresources can reuse some ideas from `fetchUrl()`.
- `src/types.zig`: `OffscreenBuffer` needs an image blit path in addition to text.

**Implementation checkpoints:**
- Read `src` attributes from image elements.
- Start with absolute image URLs before relative URL resolution.
- Decide whether images load during navigation, layout, or a separate resource pass.
- Add a decoded image representation with width, height, format, and pixel data.
- Add placeholder layout before successful decoding.
- Blit unscaled images first.
- Add simple scaling only after intrinsic-size rendering works.
- Consider memory limits before loading many large images.

**Zig concepts practiced:**
- Owning large page-lifetime byte buffers.
- Integrating external C libraries or Zig packages if you choose a decoder.
- Representing resource loading success/failure explicitly.
- Avoiding accidental arena exhaustion with large decoded data.
- Copying/blitting pixel buffers with bounds checks.

**Tiny test pages:**
- A page with one small image using an absolute URL.
- A page with text before and after an image.
- A page with a broken image URL.
- A page with several images to expose memory and sequencing decisions.

**Definition of done:**
- At least one image format can be decoded and drawn.
- Broken images produce an intentional placeholder or omission.
- Image dimensions affect layout instead of being painted at arbitrary positions.
- Memory ownership for encoded and decoded image data is documented.

**Further reading/search terms:**
- CSS replaced elements.
- Image intrinsic dimensions.
- PNG file format overview.
- stb_image integration considerations.
- Software image blitting nearest neighbor scaling.

---

## Cross-Cutting Concerns

These themes run through all of the steps above. Keeping them in mind throughout
will make your implementation more coherent.

**Memory and lifetime:**
Every feature you add will need arena allocation decisions. Ask: does this data live
for the lifetime of a page (persistent arena) or just a single layout pass (transient
arena)? Attribute data lives as long as the DOM. Computed styles live as long as the
layout tree. Decoded images live as long as the page.

**Separation of concerns:**
The DOM tree should know nothing about layout. The layout tree should know nothing
about painting. The paint layer should know nothing about networking. When you find
yourself reaching across these layers directly, it is worth pausing to ask whether
there is a cleaner boundary.

**Debugging incrementally:**
Load the simplest possible page that exercises each feature you are building. Write it
by hand. Know exactly what output you expect before you run it. The ability to construct
a minimal failing case is more valuable than any debugger.

**When to look at the spec vs. when to look at existing code:**
The HTML and CSS specs are authoritative but dense. Use them to understand *why*
something works the way it does. Use existing browser engines (Firefox, WebKit) to
understand *how* it is actually implemented. Both are necessary; neither alone is
sufficient.

**Trust the rendering output over your mental model:**
When something looks wrong, believe what you see. It is easy to convince yourself
that the logic is correct and that the visual output must be lying. It is almost
always the other way around.

---

## What This Project Does Not Need (Yet)

These are real browser concerns that are out of scope for the current learning arc.
Knowing what to exclude is as important as knowing what to include.

- JavaScript execution
- CSS `position: absolute/fixed/sticky`
- CSS flexbox or grid
- CSS animations or transitions
- HTTP caching
- Cookies or sessions
- Forms submission
- HTTPS certificate validation (the standard library handles this minimally)
- Multiple tabs or windows
- GPU-accelerated rendering
- Accessibility tree
- Extensions or developer tools

---

## Known Issues to Revisit Eventually

These are existing rough edges in the codebase that do not block progress but are
worth fixing when you circle back:

- `BoxType.Anonymous` has a misleading comment saying "elements that aren't rendered."
  Anonymous boxes are rendered — they are synthetic block wrappers. The comment is wrong.
- There are many `std.debug.print` calls throughout the codebase that will become noise
  on any real page. Eventually these should be gated behind a build-time debug flag.
- The Windows frame timer (`Sleep(1)`) is cruder than the Linux monotonic clock approach.
  Worth aligning for consistency.
- `parseWords` in `layout.zig` notes that a slice/range-based approach would be more
  memory-efficient than allocating individual word strings.
- The `AppMemory` struct has a TODO acknowledging it is not the ideal approach to state
  management. Worth revisiting once the feature set stabilizes.
