//! Flat AST for regex patterns.
//!
//! Three parallel arrays form the complete tree:
//!   nodes[]        — every node, emitted sequentially during parsing
//!   children[]     — child node indices, packed contiguously per parent
//!   class_items[]  — members (ranges / shorthands / properties) of each class
//!
//! No heap pointers inside nodes. Children and class members are referenced by
//! (start, len) index pairs into the respective arrays. This layout is
//! comptime-friendly (fixed arrays, no allocator), cache-friendly (sequential
//! access), and trivially serializable.
//!
//! The parser builds bottom-up, so the root is the LAST node emitted, not the
//! first. Always use `Ast.root` to find it — do not assume index 0.

const std = @import("std");
const utils = @import("utils");
const CodePoint = utils.unicode.CodePoint;

const token = @import("token.zig");

pub const PropertyId = token.PropertyId;
pub const GeneralCategoryGroup = token.GeneralCategoryGroup;
pub const Flags = token.Flags;
pub const PerlClassKind = token.PerlClassKind;

// ── Anchor kind ───────────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const AnchorKind = enum {
    /// ^ — respects multiline flag (matches after \n when multiline = true)
    line_begin,
    /// $ — respects multiline flag (matches before \n when multiline = true)
    line_end,
    /// \A — absolute input start, never affected by multiline
    input_begin,
    /// \z — absolute input end, never affected by multiline
    input_end,
    /// \b — position between a \w and a \W character
    word,
    /// \B — position between two \w or two \W characters
    non_word,
};

// ── Character class members ───────────────────────────────────────────────────

/// A single inclusive code_point range. A bare literal is encoded as lo == hi.
///
/// @stable-since: v0.1.0
pub const ClassRange = struct {
    lo: CodePoint,
    hi: CodePoint,
};

/// A Perl shorthand (`\d` `\w` `\s`) appearing inside a class.
/// `negated` is set for the uppercase forms (`\D` `\W` `\S`).
///
/// @stable-since: v0.1.0
pub const PerlItem = struct {
    kind: PerlClassKind,
    negated: bool,
};

/// A Unicode property test (`\p{...}` / `\P{...}`) appearing inside a class.
/// `negated` is set for the `\P{...}` form.
///
/// @stable-since: v0.1.0
pub const PropItem = struct {
    property: PropertyId,
    negated: bool,
};

/// One member of a character class. Classes are unions of members; a code_point
/// matches a class when it matches ANY member (then the class-level `negated`
/// flag, if set, inverts the result). Stored in class_items[].
///
/// This is also how standalone shorthands are represented: `\d` is a class with
/// a single `.perl` member, so the matcher has exactly one set-membership path.
///
/// @stable-since: v0.1.0
pub const ClassItem = union(enum) {
    /// `a` or `a-z`
    range: ClassRange,
    /// `\d` `\w` `\s` (and negated `\D` `\W` `\S`)
    perl: PerlItem,
    /// `\p{...}` / `\P{...}`
    property: PropItem,
};

// ── Quantifier bounds ─────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const Quantifier = struct {
    min: u32,
    /// null = unbounded (*, +, {m,})
    max: ?u32,
    /// false for *? +? ?? {m,n}?
    greedy: bool,
};

// ── Node tag ──────────────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const NodeTag = enum {
    // ── Composite — variable children via children[] ────────────────────────
    /// a|b|c  Two or more branches. children[] holds branch node indices.
    alternation,
    /// abc    One or more sequenced atoms. children[] holds atom node indices.
    concat,

    // ── Composite — single child ─────────────────────────────────────────────
    /// a* a+ a? a{m,n}  Wraps exactly one child with repetition bounds.
    range,
    /// (expr)   Capturing group. Wraps one child. Carries group index + name.
    capture,
    /// (?:expr) Non-capturing group. Wraps one child. No index, no name.
    non_capture,

    // ── Leaves — position assertions, consume no input ───────────────────────
    /// ^ $ \A \z \b \B
    anchor,

    // ── Leaves — consume exactly one code_point ───────────────────────────────
    /// Any single literal code_point after escape resolution.
    literal,
    /// .  Any code_point (behavior modified by dot_all flag).
    dot,
    /// [abc] [a-z] [^\d]  Character class referencing class_items[].
    /// Standalone \d \w \s \D \W \S are also char_class nodes with one
    /// `.perl` member, so every set-membership test funnels through one tag.
    char_class,
    /// \p{...} \P{...}  Unicode property test via ezi_code.
    unicode_property,
    /// \X  One full grapheme cluster via ezi_code segmentation.
    grapheme_cluster,
};

// ── Node data ─────────────────────────────────────────────────────────────────

/// Data payload for alternation and concat nodes.
/// children[start .. start + len] are the node indices of the branches/atoms.
pub const ChildrenData = struct {
    /// Index into children[] where this node's child list begins.
    start: u32,
    /// Number of children.
    len: u32,
};

/// Data payload for range (quantifier) nodes.
pub const RangeData = struct {
    /// Index of the single child node in nodes[].
    child: u32,
    quantifier: Quantifier,
};

/// Data payload for capture groups.
pub const CaptureData = struct {
    /// Index of the child node (the group body) in nodes[].
    child: u32,
    /// Sequential capture group number, 1-based (group 0 is the whole match).
    index: u32,
    /// Index into names[] if this is a named capture (?<name>...), else null.
    name: ?u32,
};

/// Data payload for non-capturing groups.
/// Wraps a single child. May also carry an inline-flag delta when produced by
/// the scoped `(?flags:...)` form: `flags_add`/`flags_remove` are the flags this
/// group turns on/off for its body. Both are empty for a plain `(?:...)`.
pub const NonCaptureData = struct {
    child: u32,
    flags_add: Flags = .{},
    flags_remove: Flags = .{},
};

/// Data payload for anchor nodes.
pub const AnchorData = struct {
    kind: AnchorKind,
};

/// Data payload for literal nodes.
pub const LiteralData = struct {
    code_point: CodePoint,
};

/// Data payload for character class nodes.
pub const CharClassData = struct {
    /// Index into class_items[] where this class's members begin.
    start: u32,
    /// Number of ClassItem entries.
    len: u32,
    /// True for [^...] — match any code_point NOT covered by the members.
    negated: bool,
};

/// Data payload for unicode property nodes.
pub const UnicodePropData = struct {
    property: PropertyId,
    /// True for \P{...} — match any code_point NOT satisfying the property.
    negated: bool,
};

// ── Node ──────────────────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const Node = struct {
    tag: NodeTag,
    data: Data,

    pub const Data = union {
        /// alternation, concat
        children: ChildrenData,
        /// range
        range: RangeData,
        /// capture
        capture: CaptureData,
        /// non_capture
        non_capture: NonCaptureData,
        /// anchor
        anchor: AnchorData,
        /// literal
        literal: LiteralData,
        /// char_class
        char_class: CharClassData,
        /// unicode_property
        unicode_prop: UnicodePropData,
        /// dot, grapheme_cluster — no payload
        none: void,
    };
};

// ── AST ───────────────────────────────────────────────────────────────────────

/// The complete parsed regex. Flat arrays plus metadata.
///
/// Comptime path: the slices point at fixed-size comptime const arrays sized to
/// an O(pattern.len) upper bound, then sliced to the exact lengths used.
///
/// Runtime path: the slices are heap-allocated by the parser, sized exactly.
/// Free them with `deinit` once they are no longer needed (after NFA
/// compilation, when the NFA has copied out whatever it needs).
///
/// @stable-since: v0.1.0
pub const Ast = struct {
    /// Every node. `nodes[root]` is the tree root.
    nodes: []const Node,
    /// Packed child index lists. Indexed by ChildrenData.{start, len}.
    children: []const u32,
    /// Packed character-class members. Indexed by CharClassData.{start, len}.
    class_items: []const ClassItem,
    /// Capture group names in declaration order.
    /// names[i] is the name for the capture whose CaptureData.name == i.
    /// The slices borrow the original pattern string; they are not copied.
    names: []const []const u8,
    /// Index of the root node in nodes[]. The root is the last-emitted node, so
    /// this is generally nodes.len - 1, never assume 0.
    root: u32,
    /// Total number of capture groups (group 0, the whole match, is not counted).
    capture_count: u32,
    /// Global flags accumulated from bare `(?flags)` directives.
    flags: Flags = .{},

    /// Free the heap arrays of a runtime-parsed AST. The `names` entries point
    /// into the original pattern and are NOT freed — only the `names` array is.
    /// Never call this on a comptime-built AST (its slices are const data).
    ///
    /// @stable-since: v0.1.0
    pub fn deinit(self: Ast, allocator: std.mem.Allocator) void {
        if (self.nodes.len != 0) allocator.free(self.nodes);
        if (self.children.len != 0) allocator.free(self.children);
        if (self.class_items.len != 0) allocator.free(self.class_items);
        if (self.names.len != 0) allocator.free(self.names);
    }
};

// ── Concrete node constructors (helpers for the parser) ───────────────────────
//
// These return a fully-formed Node value ready to be appended to nodes[].
// They do not allocate — the parser owns the arrays and passes indices in.

pub fn makeAlternation(children_start: u32, children_len: u32) Node {
    return .{
        .tag = .alternation,
        .data = .{ .children = .{ .start = children_start, .len = children_len } },
    };
}

pub fn makeConcat(children_start: u32, children_len: u32) Node {
    return .{
        .tag = .concat,
        .data = .{ .children = .{ .start = children_start, .len = children_len } },
    };
}

pub fn makeRange(child: u32, min: u32, max: ?u32, greedy: bool) Node {
    return .{
        .tag = .range,
        .data = .{
            .range = .{
                .child = child,
                .quantifier = .{ .min = min, .max = max, .greedy = greedy },
            },
        },
    };
}

pub fn makeCapture(child: u32, index: u32, name: ?u32) Node {
    return .{
        .tag = .capture,
        .data = .{ .capture = .{ .child = child, .index = index, .name = name } },
    };
}

pub fn makeNonCapture(child: u32) Node {
    return .{
        .tag = .non_capture,
        .data = .{ .non_capture = .{ .child = child } },
    };
}

pub fn makeNonCaptureScoped(child: u32, flags_add: Flags, flags_remove: Flags) Node {
    return .{
        .tag = .non_capture,
        .data = .{ .non_capture = .{
            .child = child,
            .flags_add = flags_add,
            .flags_remove = flags_remove,
        } },
    };
}

pub fn makeAnchor(kind: AnchorKind) Node {
    return .{
        .tag = .anchor,
        .data = .{ .anchor = .{ .kind = kind } },
    };
}

pub fn makeLiteral(code_point: CodePoint) Node {
    return .{
        .tag = .literal,
        .data = .{ .literal = .{ .code_point = code_point } },
    };
}

pub fn makeDot() Node {
    return .{ .tag = .dot, .data = .{ .none = {} } };
}

pub fn makeCharClass(ranges_start: u32, ranges_len: u32, negated: bool) Node {
    return .{
        .tag = .char_class,
        .data = .{
            .char_class = .{
                .start = ranges_start,
                .len = ranges_len,
                .negated = negated,
            },
        },
    };
}

pub fn makeUnicodeProp(property: PropertyId, negated: bool) Node {
    return .{
        .tag = .unicode_property,
        .data = .{ .unicode_prop = .{ .property = property, .negated = negated } },
    };
}

pub fn makeGraphemeCluster() Node {
    return .{ .tag = .grapheme_cluster, .data = .{ .none = {} } };
}
