//! Unicode property names the tree generator may emit. Each has two scanner-accepted
//! spellings (the printer picks one — a metamorphic rewrite), its semantics for the
//! reference matcher, and one sample member (witnesses, class-membership inputs).

const std = @import("std");
const ez = @import("ezi_code");
const P = ez.unicode.properties;
const S = ez.unicode.scripts;

pub const Group = enum { letter, cased_letter, mark, number, punctuation, symbol, separator, other };

pub const Sem = union(enum) {
    gc: P.GeneralCategory,
    group: Group,
    derived: P.DerivedProperty,
    /// ezi_gex resolves `Script_Extensions=` to the plain `Script` ranges (documented).
    script: S.ScriptType,
};

pub const Prop = struct { short: []const u8, long: []const u8, sem: Sem, sample: u21 };

pub const table = [_]Prop{
    .{ .short = "L", .long = "Letter", .sem = .{ .group = .letter }, .sample = 'q' },
    .{ .short = "LC", .long = "Cased_Letter", .sem = .{ .group = .cased_letter }, .sample = 'Q' },
    .{ .short = "M", .long = "Mark", .sem = .{ .group = .mark }, .sample = 0x0301 },
    .{ .short = "N", .long = "Number", .sem = .{ .group = .number }, .sample = '7' },
    .{ .short = "P", .long = "Punctuation", .sem = .{ .group = .punctuation }, .sample = '!' },
    .{ .short = "S", .long = "Symbol", .sem = .{ .group = .symbol }, .sample = '+' },
    .{ .short = "Z", .long = "Separator", .sem = .{ .group = .separator }, .sample = ' ' },
    .{ .short = "C", .long = "Other", .sem = .{ .group = .other }, .sample = '\t' },
    .{ .short = "Lu", .long = "Uppercase_Letter", .sem = .{ .gc = .uppercase_letter }, .sample = 'K' },
    .{ .short = "Ll", .long = "Lowercase_Letter", .sem = .{ .gc = .lowercase_letter }, .sample = 'k' },
    .{ .short = "Lt", .long = "Titlecase_Letter", .sem = .{ .gc = .titlecase_letter }, .sample = 0x01C5 },
    .{ .short = "Lm", .long = "Modifier_Letter", .sem = .{ .gc = .modifier_letter }, .sample = 0x02B0 },
    .{ .short = "Lo", .long = "Other_Letter", .sem = .{ .gc = .other_letter }, .sample = 0x65E5 },
    .{ .short = "Mn", .long = "Nonspacing_Mark", .sem = .{ .gc = .non_spacing_mark }, .sample = 0x0301 },
    .{ .short = "Nd", .long = "Decimal_Number", .sem = .{ .gc = .decimal_number }, .sample = 0x0663 },
    .{ .short = "Nl", .long = "Letter_Number", .sem = .{ .gc = .letter_number }, .sample = 0x2160 },
    .{ .short = "No", .long = "Other_Number", .sem = .{ .gc = .other_number }, .sample = 0x00B2 },
    .{ .short = "Pc", .long = "Connector_Punctuation", .sem = .{ .gc = .connector_punctuation }, .sample = '_' },
    .{ .short = "Pd", .long = "Dash_Punctuation", .sem = .{ .gc = .dash_punctuation }, .sample = '-' },
    .{ .short = "Ps", .long = "Open_Punctuation", .sem = .{ .gc = .open_punctuation }, .sample = '(' },
    .{ .short = "Po", .long = "Other_Punctuation", .sem = .{ .gc = .other_punctuation }, .sample = '#' },
    .{ .short = "Sm", .long = "Math_Symbol", .sem = .{ .gc = .math_symbol }, .sample = '+' },
    .{ .short = "Sc", .long = "Currency_Symbol", .sem = .{ .gc = .currency_symbol }, .sample = '$' },
    .{ .short = "So", .long = "Other_Symbol", .sem = .{ .gc = .other_symbol }, .sample = 0x00A9 },
    .{ .short = "Zs", .long = "Space_Separator", .sem = .{ .gc = .space_separator }, .sample = 0x3000 },
    .{ .short = "Cc", .long = "Control", .sem = .{ .gc = .control }, .sample = '\n' },
    .{ .short = "Cf", .long = "Format", .sem = .{ .gc = .format }, .sample = 0x200D },
    .{ .short = "Co", .long = "Private_Use", .sem = .{ .gc = .private_use }, .sample = 0xE000 },
    .{ .short = "Cn", .long = "Unassigned", .sem = .{ .gc = .unassigned }, .sample = 0x0378 },
    .{ .short = "Alphabetic", .long = "Alphabetic", .sem = .{ .derived = .alphabetic }, .sample = 'a' },
    .{ .short = "Lowercase", .long = "Lowercase", .sem = .{ .derived = .lowercase }, .sample = 0x00AA },
    .{ .short = "Uppercase", .long = "Uppercase", .sem = .{ .derived = .uppercase }, .sample = 'Z' },
    .{ .short = "Cased", .long = "Cased", .sem = .{ .derived = .cased }, .sample = 0x01C5 },
    .{ .short = "Math", .long = "Math", .sem = .{ .derived = .math }, .sample = '^' },
    .{ .short = "ID_Start", .long = "ID_Start", .sem = .{ .derived = .id_start }, .sample = 'x' },
    .{ .short = "XID_Continue", .long = "XID_Continue", .sem = .{ .derived = .xid_continue }, .sample = '9' },
    .{ .short = "Default_Ignorable_Code_Point", .long = "Default_Ignorable_Code_Point", .sem = .{ .derived = .default_ignorable_code_point }, .sample = 0x00AD },
    .{ .short = "Grapheme_Extend", .long = "Grapheme_Extend", .sem = .{ .derived = .grapheme_extend }, .sample = 0x0300 },
    .{ .short = "sc=Grek", .long = "Script=Greek", .sem = .{ .script = .greek }, .sample = 0x03B1 },
    .{ .short = "sc=Latn", .long = "Script=Latin", .sem = .{ .script = .latin }, .sample = 'a' },
    .{ .short = "sc=Cyrl", .long = "Script=Cyrillic", .sem = .{ .script = .cyrillic }, .sample = 0x0436 },
    .{ .short = "sc=Hani", .long = "Script=Han", .sem = .{ .script = .han }, .sample = 0x65E5 },
    .{ .short = "sc=Zyyy", .long = "Script=Common", .sem = .{ .script = .common }, .sample = '1' },
    .{ .short = "sc=Zinh", .long = "Script=Inherited", .sem = .{ .script = .inherited }, .sample = 0x0301 },
    .{ .short = "scx=Grek", .long = "Script_Extensions=Greek", .sem = .{ .script = .greek }, .sample = 0x03B1 },
};

pub fn indexOf(short: []const u8) ?u8 {
    for (table, 0..) |p, i| {
        if (std.mem.eql(u8, p.short, short)) return @intCast(i);
    }
    return null;
}

test "every property spelling is accepted by the scanner" {
    const gex = @import("ezi_gex");
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    for (table) |p| {
        for ([_][]const u8{ p.short, p.long }) |name| {
            const pat = try std.fmt.bufPrint(&buf, "\\p{{{s}}}", .{name});
            var diag: gex.Diagnostic = .{};
            const a = gex.parse(gpa, pat, &diag) catch {
                std.debug.print("scanner rejected {s}: {s}\n", .{ pat, @tagName(diag.code) });
                return error.PropertyRejected;
            };
            a.deinit(gpa);
        }
    }
}
