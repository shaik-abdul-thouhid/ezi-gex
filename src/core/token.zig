//! Token types produced by the scanner.
//!
//! Every escape sequence and syntactic construct is fully resolved here.
//! By the time a Token leaves the scanner, there is no ambiguity:
//!   - `\n`  → Token{ .literal = 0x0A }
//!   - `\d`  → Token{ .class_digit }
//!   - `\p{Letter}` → Token{ .unicode_prop = .{ .general_category_group = .letter } }
//!   - `(`   → Token{ .l_paren }
//!   - `(?:` → Token{ .group_non_capture }

const std = @import("std");
const utils = @import("utils");
const CodePoint = utils.unicode.CodePoint;

const scripts = utils.unicode.scripts;
const props = utils.unicode.properties;

// ── Inline flags ──────────────────────────────────────────────────────────────

/// Mode flags toggled by `(?ims)` / `(?ims:...)` inline groups and consulted by
/// the matcher. The scanner only records them; it never acts on them. Defined
/// here (rather than in ast.zig) so both the token layer and the AST can share
/// the type without an import cycle — ast.zig imports token.zig, not the reverse.
///
/// @stable-since: v0.1.0
pub const Flags = packed struct {
    /// i — case-insensitive matching.
    case_insensitive: bool = false,
    /// m — `^`/`$` match around `\n`, not only at the input ends.
    multiline: bool = false,
    /// s — `.` also matches `\n` (dot-all / single-line).
    dot_all: bool = false,
    /// x — extended/verbose mode: in normal (non-class) context the scanner skips
    /// unescaped whitespace and `#`-to-end-of-line comments while lexing. Unlike the
    /// other flags this one is acted on at LEX time, so it takes effect only via an
    /// inline `(?x)` (not the front-door `Options`, which is applied after lexing).
    verbose: bool = false,

    /// The empty flag set (nothing toggled).
    pub const none: Flags = .{};

    /// Field-wise OR. Used to fold an inline `(?flags)` delta into the set of
    /// flags currently in effect.
    ///
    /// @stable-since: v0.1.0
    pub fn merge(self: Flags, other: Flags) Flags {
        return .{
            .case_insensitive = self.case_insensitive or other.case_insensitive,
            .multiline = self.multiline or other.multiline,
            .dot_all = self.dot_all or other.dot_all,
            .verbose = self.verbose or other.verbose,
        };
    }

    /// True when no flag bit is set.
    ///
    /// @stable-since: v0.1.0
    pub fn isEmpty(self: Flags) bool {
        return !self.case_insensitive and !self.multiline and !self.dot_all and !self.verbose;
    }
};

/// The three Perl shorthand character classes. In the AST these live as
/// `ClassItem.perl`; a standalone `\d`/`\w`/`\s` becomes a single-item class.
/// Definitions the matcher resolves through ezi_code (Unicode mode):
///   - digit : General_Category = Nd (decimal number)
///   - word  : Alphabetic ∪ Mark ∪ Nd ∪ Connector_Punctuation ∪ Join_Control
///   - space : White_Space
///
/// @stable-since: v0.1.0
pub const PerlClassKind = enum { digit, word, space };

// ── Unicode property identifier ──────────────────────────────────────────────

/// Aggregate General_Category groups (L, M, N, P, S, Z, C, LC).
/// These do not map to a single GeneralCategory variant — they cover
/// multiple variants and are handled separately in the matcher.
///
/// @stable-since: v0.1.0
pub const GeneralCategoryGroup = enum {
    letter, // L  — Lu Ll Lt Lm Lo
    cased_letter, // LC — Lu Ll Lt
    mark, // M  — Mn Mc Me
    number, // N  — Nd Nl No
    punctuation, // P  — Pc Pd Ps Pe Pi Pf Po
    symbol, // S  — Sm Sc Sk So
    separator, // Z  — Zs Zl Zp
    other, // C  — Cc Cf Cs Co Cn
};

/// What a `\p{...}` or `\P{...}` resolves to.
/// The scanner resolves the property name string into one of these variants.
/// The matcher dispatches to ezi_code with no further string parsing.
///
/// @stable-since: v0.1.0
pub const PropertyId = union(enum) {
    /// Single General_Category variant — e.g. \p{Lu}, \p{Uppercase_Letter}
    general_category: props.GeneralCategory,

    /// Aggregate category group — e.g. \p{L}, \p{Letter}, \p{N}
    general_category_group: GeneralCategoryGroup,

    /// DerivedCoreProperty — e.g. \p{Alphabetic}, \p{ID_Start}
    derived: props.DerivedProperty,

    /// Script property — e.g. \p{Script=Latin}
    script: scripts.ScriptType,

    /// Script_Extensions property — e.g. \p{Script_Extensions=Latin}
    script_extension: scripts.ScriptType,
};

// ── Property name lookup tables ───────────────────────────────────────────────
//
// These are used by the scanner to resolve \p{name} strings.
// Two separate maps:
//   - general_category_map : string → PropertyId (covers GC singles + groups)
//   - derived_property_map : string → props.DerivedProperty
//
// Scripts are NOT in these maps. They are handled by:
//   1. Detect "Script=" or "Sc=" prefix.
//   2. Try ezi_code's fromAbbreviation() with the 4-letter ISO 15924 code.
//   3. If that fails, try the long-name table below.
//
// Script_Extensions uses the same resolution, just stored as .script_extension.

/// Entries for the general category + group lookup.
/// Keys are the exact strings a user may write inside \p{...}.
pub const gc_map_entries = [_]struct { key: []const u8, val: PropertyId }{
    // ── Groups (aggregate) ──────────────────────────────────────────────────
    .{ .key = "L", .val = .{ .general_category_group = .letter } },
    .{ .key = "Letter", .val = .{ .general_category_group = .letter } },

    .{ .key = "LC", .val = .{ .general_category_group = .cased_letter } },
    .{ .key = "Cased_Letter", .val = .{ .general_category_group = .cased_letter } },

    .{ .key = "M", .val = .{ .general_category_group = .mark } },
    .{ .key = "Mark", .val = .{ .general_category_group = .mark } },

    .{ .key = "N", .val = .{ .general_category_group = .number } },
    .{ .key = "Number", .val = .{ .general_category_group = .number } },

    .{ .key = "P", .val = .{ .general_category_group = .punctuation } },
    .{ .key = "Punctuation", .val = .{ .general_category_group = .punctuation } },

    .{ .key = "S", .val = .{ .general_category_group = .symbol } },
    .{ .key = "Symbol", .val = .{ .general_category_group = .symbol } },

    .{ .key = "Z", .val = .{ .general_category_group = .separator } },
    .{ .key = "Separator", .val = .{ .general_category_group = .separator } },

    .{ .key = "C", .val = .{ .general_category_group = .other } },
    .{ .key = "Other", .val = .{ .general_category_group = .other } },

    // ── Single variants ─────────────────────────────────────────────────────
    // Letters
    .{ .key = "Lu", .val = .{ .general_category = .uppercase_letter } },
    .{ .key = "Uppercase_Letter", .val = .{ .general_category = .uppercase_letter } },

    .{ .key = "Ll", .val = .{ .general_category = .lowercase_letter } },
    .{ .key = "Lowercase_Letter", .val = .{ .general_category = .lowercase_letter } },

    .{ .key = "Lt", .val = .{ .general_category = .titlecase_letter } },
    .{ .key = "Titlecase_Letter", .val = .{ .general_category = .titlecase_letter } },

    .{ .key = "Lm", .val = .{ .general_category = .modifier_letter } },
    .{ .key = "Modifier_Letter", .val = .{ .general_category = .modifier_letter } },

    .{ .key = "Lo", .val = .{ .general_category = .other_letter } },
    .{ .key = "Other_Letter", .val = .{ .general_category = .other_letter } },

    // Marks
    .{ .key = "Mn", .val = .{ .general_category = .non_spacing_mark } },
    .{ .key = "Nonspacing_Mark", .val = .{ .general_category = .non_spacing_mark } },

    .{ .key = "Mc", .val = .{ .general_category = .spacing_mark } },
    .{ .key = "Spacing_Mark", .val = .{ .general_category = .spacing_mark } },

    .{ .key = "Me", .val = .{ .general_category = .enclosing_mark } },
    .{ .key = "Enclosing_Mark", .val = .{ .general_category = .enclosing_mark } },

    // Numbers
    .{ .key = "Nd", .val = .{ .general_category = .decimal_number } },
    .{ .key = "Decimal_Number", .val = .{ .general_category = .decimal_number } },

    .{ .key = "Nl", .val = .{ .general_category = .letter_number } },
    .{ .key = "Letter_Number", .val = .{ .general_category = .letter_number } },

    .{ .key = "No", .val = .{ .general_category = .other_number } },
    .{ .key = "Other_Number", .val = .{ .general_category = .other_number } },

    // Punctuation
    .{ .key = "Pc", .val = .{ .general_category = .connector_punctuation } },
    .{ .key = "Connector_Punctuation", .val = .{ .general_category = .connector_punctuation } },

    .{ .key = "Pd", .val = .{ .general_category = .dash_punctuation } },
    .{ .key = "Dash_Punctuation", .val = .{ .general_category = .dash_punctuation } },

    .{ .key = "Ps", .val = .{ .general_category = .open_punctuation } },
    .{ .key = "Open_Punctuation", .val = .{ .general_category = .open_punctuation } },

    .{ .key = "Pe", .val = .{ .general_category = .close_punctuation } },
    .{ .key = "Close_Punctuation", .val = .{ .general_category = .close_punctuation } },

    .{ .key = "Pi", .val = .{ .general_category = .initial_punctuation } },
    .{ .key = "Initial_Punctuation", .val = .{ .general_category = .initial_punctuation } },

    .{ .key = "Pf", .val = .{ .general_category = .final_punctuation } },
    .{ .key = "Final_Punctuation", .val = .{ .general_category = .final_punctuation } },

    .{ .key = "Po", .val = .{ .general_category = .other_punctuation } },
    .{ .key = "Other_Punctuation", .val = .{ .general_category = .other_punctuation } },

    // Symbols
    .{ .key = "Sm", .val = .{ .general_category = .math_symbol } },
    .{ .key = "Math_Symbol", .val = .{ .general_category = .math_symbol } },

    .{ .key = "Sc", .val = .{ .general_category = .currency_symbol } },
    .{ .key = "Currency_Symbol", .val = .{ .general_category = .currency_symbol } },

    .{ .key = "Sk", .val = .{ .general_category = .modifier_symbol } },
    .{ .key = "Modifier_Symbol", .val = .{ .general_category = .modifier_symbol } },

    .{ .key = "So", .val = .{ .general_category = .other_symbol } },
    .{ .key = "Other_Symbol", .val = .{ .general_category = .other_symbol } },

    // Separators
    .{ .key = "Zs", .val = .{ .general_category = .space_separator } },
    .{ .key = "Space_Separator", .val = .{ .general_category = .space_separator } },

    .{ .key = "Zl", .val = .{ .general_category = .line_separator } },
    .{ .key = "Line_Separator", .val = .{ .general_category = .line_separator } },

    .{ .key = "Zp", .val = .{ .general_category = .paragraph_separator } },
    .{ .key = "Paragraph_Separator", .val = .{ .general_category = .paragraph_separator } },

    // Other
    .{ .key = "Cc", .val = .{ .general_category = .control } },
    .{ .key = "Control", .val = .{ .general_category = .control } },

    .{ .key = "Cf", .val = .{ .general_category = .format } },
    .{ .key = "Format", .val = .{ .general_category = .format } },

    .{ .key = "Cs", .val = .{ .general_category = .surrogate } },
    .{ .key = "Surrogate", .val = .{ .general_category = .surrogate } },

    .{ .key = "Co", .val = .{ .general_category = .private_use } },
    .{ .key = "Private_Use", .val = .{ .general_category = .private_use } },

    .{ .key = "Cn", .val = .{ .general_category = .unassigned } },
    .{ .key = "Unassigned", .val = .{ .general_category = .unassigned } },
};

/// Entries for DerivedCoreProperty lookup.
/// Keys are the exact strings a user may write inside \p{...}.
pub const derived_map_entries = [_]struct { key: []const u8, val: props.DerivedProperty }{
    .{ .key = "Math", .val = .math },
    .{ .key = "Alphabetic", .val = .alphabetic },
    .{ .key = "Lowercase", .val = .lowercase },
    .{ .key = "Uppercase", .val = .uppercase },
    .{ .key = "Cased", .val = .cased },
    .{ .key = "Case_Ignorable", .val = .case_ignorable },
    .{ .key = "Changes_When_Lowercased", .val = .changes_when_lowercased },
    .{ .key = "Changes_When_Uppercased", .val = .changes_when_uppercased },
    .{ .key = "Changes_When_Titlecased", .val = .changes_when_titlecased },
    .{ .key = "Changes_When_Casefolded", .val = .changes_when_casefolded },
    .{ .key = "Changes_When_Casemapped", .val = .changes_when_casemapped },
    .{ .key = "ID_Start", .val = .id_start },
    .{ .key = "ID_Continue", .val = .id_continue },
    .{ .key = "XID_Start", .val = .xid_start },
    .{ .key = "XID_Continue", .val = .xid_continue },
    .{ .key = "Default_Ignorable_Code_Point", .val = .default_ignorable_code_point },
    .{ .key = "Grapheme_Extend", .val = .grapheme_extend },
    .{ .key = "Grapheme_Base", .val = .grapheme_base },
    .{ .key = "Grapheme_Link", .val = .grapheme_link },
};

/// Long script name → ISO 15924 abbreviation.
/// Used when the user writes \p{Script=Latin} or \p{Script=Cyrillic} etc.
/// ezi_code's fromAbbreviation() handles the 4-letter codes directly,
/// so we only need the long → short mapping here.
pub const script_long_name_entries = [_]struct { key: []const u8, abbr: []const u8 }{
    .{ .key = "Adlam", .abbr = "Adlm" },
    .{ .key = "Caucasian_Albanian", .abbr = "Aghb" },
    .{ .key = "Ahom", .abbr = "Ahom" },
    .{ .key = "Arabic", .abbr = "Arab" },
    .{ .key = "Imperial_Aramaic", .abbr = "Armi" },
    .{ .key = "Armenian", .abbr = "Armn" },
    .{ .key = "Avestan", .abbr = "Avst" },
    .{ .key = "Balinese", .abbr = "Bali" },
    .{ .key = "Bamum", .abbr = "Bamu" },
    .{ .key = "Bassa_Vah", .abbr = "Bass" },
    .{ .key = "Batak", .abbr = "Batk" },
    .{ .key = "Bengali", .abbr = "Beng" },
    .{ .key = "Beria_Erfe", .abbr = "Berf" },
    .{ .key = "Bhaiksuki", .abbr = "Bhks" },
    .{ .key = "Bopomofo", .abbr = "Bopo" },
    .{ .key = "Brahmi", .abbr = "Brah" },
    .{ .key = "Braille", .abbr = "Brai" },
    .{ .key = "Buginese", .abbr = "Bugi" },
    .{ .key = "Buhid", .abbr = "Buhd" },
    .{ .key = "Chakma", .abbr = "Cakm" },
    .{ .key = "Canadian_Aboriginal", .abbr = "Cans" },
    .{ .key = "Carian", .abbr = "Cari" },
    .{ .key = "Cham", .abbr = "Cham" },
    .{ .key = "Cherokee", .abbr = "Cher" },
    .{ .key = "Chorasmian", .abbr = "Chrs" },
    .{ .key = "Coptic", .abbr = "Copt" },
    .{ .key = "Cypro_Minoan", .abbr = "Cpmn" },
    .{ .key = "Cypriot", .abbr = "Cprt" },
    .{ .key = "Cyrillic", .abbr = "Cyrl" },
    .{ .key = "Devanagari", .abbr = "Deva" },
    .{ .key = "Dives_Akuru", .abbr = "Diak" },
    .{ .key = "Dogra", .abbr = "Dogr" },
    .{ .key = "Deseret", .abbr = "Dsrt" },
    .{ .key = "Duployan", .abbr = "Dupl" },
    .{ .key = "Egyptian_Hieroglyphs", .abbr = "Egyp" },
    .{ .key = "Elbasan", .abbr = "Elba" },
    .{ .key = "Elymaic", .abbr = "Elym" },
    .{ .key = "Ethiopic", .abbr = "Ethi" },
    .{ .key = "Garay", .abbr = "Gara" },
    .{ .key = "Georgian", .abbr = "Geor" },
    .{ .key = "Glagolitic", .abbr = "Glag" },
    .{ .key = "Gunjala_Gondi", .abbr = "Gong" },
    .{ .key = "Masaram_Gondi", .abbr = "Gonm" },
    .{ .key = "Gothic", .abbr = "Goth" },
    .{ .key = "Grantha", .abbr = "Gran" },
    .{ .key = "Greek", .abbr = "Grek" },
    .{ .key = "Gujarati", .abbr = "Gujr" },
    .{ .key = "Gurung_Khema", .abbr = "Gukh" },
    .{ .key = "Gurmukhi", .abbr = "Guru" },
    .{ .key = "Hangul", .abbr = "Hang" },
    .{ .key = "Han", .abbr = "Hani" },
    .{ .key = "Hanunoo", .abbr = "Hano" },
    .{ .key = "Hatran", .abbr = "Hatr" },
    .{ .key = "Hebrew", .abbr = "Hebr" },
    .{ .key = "Hiragana", .abbr = "Hira" },
    .{ .key = "Anatolian_Hieroglyphs", .abbr = "Hluw" },
    .{ .key = "Pahawh_Hmong", .abbr = "Hmng" },
    .{ .key = "Nyiakeng_Puachue_Hmong", .abbr = "Hmnp" },
    .{ .key = "Katakana_Or_Hiragana", .abbr = "Hrkt" },
    .{ .key = "Old_Hungarian", .abbr = "Hung" },
    .{ .key = "Old_Italic", .abbr = "Ital" },
    .{ .key = "Javanese", .abbr = "Java" },
    .{ .key = "Kayah_Li", .abbr = "Kali" },
    .{ .key = "Katakana", .abbr = "Kana" },
    .{ .key = "Kawi", .abbr = "Kawi" },
    .{ .key = "Kharoshthi", .abbr = "Khar" },
    .{ .key = "Khmer", .abbr = "Khmr" },
    .{ .key = "Khojki", .abbr = "Khoj" },
    .{ .key = "Khitan_Small_Script", .abbr = "Kits" },
    .{ .key = "Kannada", .abbr = "Knda" },
    .{ .key = "Kirat_Rai", .abbr = "Krai" },
    .{ .key = "Kaithi", .abbr = "Kthi" },
    .{ .key = "Tai_Tham", .abbr = "Lana" },
    .{ .key = "Lao", .abbr = "Laoo" },
    .{ .key = "Latin", .abbr = "Latn" },
    .{ .key = "Lepcha", .abbr = "Lepc" },
    .{ .key = "Limbu", .abbr = "Limb" },
    .{ .key = "Linear_A", .abbr = "Lina" },
    .{ .key = "Linear_B", .abbr = "Linb" },
    .{ .key = "Lisu", .abbr = "Lisu" },
    .{ .key = "Lycian", .abbr = "Lyci" },
    .{ .key = "Lydian", .abbr = "Lydi" },
    .{ .key = "Mahajani", .abbr = "Mahj" },
    .{ .key = "Makasar", .abbr = "Maka" },
    .{ .key = "Mandaic", .abbr = "Mand" },
    .{ .key = "Manichaean", .abbr = "Mani" },
    .{ .key = "Marchen", .abbr = "Marc" },
    .{ .key = "Medefaidrin", .abbr = "Medf" },
    .{ .key = "Mende_Kikakui", .abbr = "Mend" },
    .{ .key = "Meroitic_Cursive", .abbr = "Merc" },
    .{ .key = "Meroitic_Hieroglyphs", .abbr = "Mero" },
    .{ .key = "Malayalam", .abbr = "Mlym" },
    .{ .key = "Modi", .abbr = "Modi" },
    .{ .key = "Mongolian", .abbr = "Mong" },
    .{ .key = "Mro", .abbr = "Mroo" },
    .{ .key = "Meetei_Mayek", .abbr = "Mtei" },
    .{ .key = "Multani", .abbr = "Mult" },
    .{ .key = "Myanmar", .abbr = "Mymr" },
    .{ .key = "Nag_Mundari", .abbr = "Nagm" },
    .{ .key = "Nandinagari", .abbr = "Nand" },
    .{ .key = "Old_North_Arabian", .abbr = "Narb" },
    .{ .key = "Nabataean", .abbr = "Nbat" },
    .{ .key = "Newa", .abbr = "Newa" },
    .{ .key = "Nko", .abbr = "Nkoo" },
    .{ .key = "Nushu", .abbr = "Nshu" },
    .{ .key = "Ogham", .abbr = "Ogam" },
    .{ .key = "Ol_Chiki", .abbr = "Olck" },
    .{ .key = "Ol_Onal", .abbr = "Onao" },
    .{ .key = "Old_Turkic", .abbr = "Orkh" },
    .{ .key = "Oriya", .abbr = "Orya" },
    .{ .key = "Osage", .abbr = "Osge" },
    .{ .key = "Osmanya", .abbr = "Osma" },
    .{ .key = "Old_Uyghur", .abbr = "Ougr" },
    .{ .key = "Palmyrene", .abbr = "Palm" },
    .{ .key = "Pau_Cin_Hau", .abbr = "Pauc" },
    .{ .key = "Old_Permic", .abbr = "Perm" },
    .{ .key = "Phags_Pa", .abbr = "Phag" },
    .{ .key = "Inscriptional_Pahlavi", .abbr = "Phli" },
    .{ .key = "Psalter_Pahlavi", .abbr = "Phlp" },
    .{ .key = "Phoenician", .abbr = "Phnx" },
    .{ .key = "Miao", .abbr = "Plrd" },
    .{ .key = "Inscriptional_Parthian", .abbr = "Prti" },
    .{ .key = "Rejang", .abbr = "Rjng" },
    .{ .key = "Hanifi_Rohingya", .abbr = "Rohg" },
    .{ .key = "Runic", .abbr = "Runr" },
    .{ .key = "Samaritan", .abbr = "Samr" },
    .{ .key = "Old_South_Arabian", .abbr = "Sarb" },
    .{ .key = "Saurashtra", .abbr = "Saur" },
    .{ .key = "SignWriting", .abbr = "Sgnw" },
    .{ .key = "Shavian", .abbr = "Shaw" },
    .{ .key = "Sharada", .abbr = "Shrd" },
    .{ .key = "Siddham", .abbr = "Sidd" },
    .{ .key = "Sidetic", .abbr = "Sidt" },
    .{ .key = "Khudawadi", .abbr = "Sind" },
    .{ .key = "Sinhala", .abbr = "Sinh" },
    .{ .key = "Sogdian", .abbr = "Sogd" },
    .{ .key = "Old_Sogdian", .abbr = "Sogo" },
    .{ .key = "Sora_Sompeng", .abbr = "Sora" },
    .{ .key = "Soyombo", .abbr = "Soyo" },
    .{ .key = "Sundanese", .abbr = "Sund" },
    .{ .key = "Sunuwar", .abbr = "Sunu" },
    .{ .key = "Syloti_Nagri", .abbr = "Sylo" },
    .{ .key = "Syriac", .abbr = "Syrc" },
    .{ .key = "Tagbanwa", .abbr = "Tagb" },
    .{ .key = "Takri", .abbr = "Takr" },
    .{ .key = "Tai_Le", .abbr = "Tale" },
    .{ .key = "New_Tai_Lue", .abbr = "Talu" },
    .{ .key = "Tamil", .abbr = "Taml" },
    .{ .key = "Tangut", .abbr = "Tang" },
    .{ .key = "Tai_Viet", .abbr = "Tavt" },
    .{ .key = "Tai_Yo", .abbr = "Tayo" },
    .{ .key = "Telugu", .abbr = "Telu" },
    .{ .key = "Tifinagh", .abbr = "Tfng" },
    .{ .key = "Tagalog", .abbr = "Tglg" },
    .{ .key = "Thaana", .abbr = "Thaa" },
    .{ .key = "Thai", .abbr = "Thai" },
    .{ .key = "Tibetan", .abbr = "Tibt" },
    .{ .key = "Tirhuta", .abbr = "Tirh" },
    .{ .key = "Tangsa", .abbr = "Tnsa" },
    .{ .key = "Todhri", .abbr = "Todr" },
    .{ .key = "Tolong_Siki", .abbr = "Tols" },
    .{ .key = "Toto", .abbr = "Toto" },
    .{ .key = "Tulu_Tigalari", .abbr = "Tutg" },
    .{ .key = "Ugaritic", .abbr = "Ugar" },
    .{ .key = "Vai", .abbr = "Vaii" },
    .{ .key = "Vithkuqi", .abbr = "Vith" },
    .{ .key = "Warang_Citi", .abbr = "Wara" },
    .{ .key = "Wancho", .abbr = "Wcho" },
    .{ .key = "Old_Persian", .abbr = "Xpeo" },
    .{ .key = "Cuneiform", .abbr = "Xsux" },
    .{ .key = "Yezidi", .abbr = "Yezi" },
    .{ .key = "Yi", .abbr = "Yiii" },
    .{ .key = "Zanabazar_Square", .abbr = "Zanb" },
    .{ .key = "Inherited", .abbr = "Zinh" },
    .{ .key = "Common", .abbr = "Zyyy" },
    .{ .key = "Unknown", .abbr = "Zzzz" },
};

// ── Comptime-built lookup maps ────────────────────────────────────────────────

fn buildGcKvs() [gc_map_entries.len]struct { []const u8, PropertyId } {
    var kvs: [gc_map_entries.len]struct { []const u8, PropertyId } = undefined;
    for (gc_map_entries, 0..) |e, i| kvs[i] = .{ e.key, e.val };
    return kvs;
}

fn buildDerivedKvs() [derived_map_entries.len]struct { []const u8, props.DerivedProperty } {
    var kvs: [derived_map_entries.len]struct { []const u8, props.DerivedProperty } = undefined;
    for (derived_map_entries, 0..) |e, i| kvs[i] = .{ e.key, e.val };
    return kvs;
}

fn buildScriptLongNameKvs() [script_long_name_entries.len]struct { []const u8, []const u8 } {
    var kvs: [script_long_name_entries.len]struct { []const u8, []const u8 } = undefined;
    for (script_long_name_entries, 0..) |e, i| kvs[i] = .{ e.key, e.abbr };
    return kvs;
}

const gc_kvs = buildGcKvs();
const derived_kvs = buildDerivedKvs();
const script_long_kvs = buildScriptLongNameKvs();

/// General category + group lookup. Call in scanner when parsing \p{...}
/// and the name does not start with "Script=" or "Script_Extensions=".
pub const gc_map = std.StaticStringMap(PropertyId).initComptime(&gc_kvs);

/// DerivedCoreProperty lookup. Call after gc_map.get() returns null.
pub const derived_map = std.StaticStringMap(props.DerivedProperty).initComptime(&derived_kvs);

/// Long script name → ISO 15924 abbreviation.
/// After stripping "Script=" or "Script_Extensions=" prefix, try
/// scripts.fromAbbreviation(name) first (handles 4-letter codes),
/// then fall back to this map for long names.
pub const script_long_name_map = std.StaticStringMap([]const u8).initComptime(&script_long_kvs);

/// Resolve a property name string to a PropertyId, or null if unrecognised.
/// This is the single entry point the scanner calls for \p{name} and \P{name}.
///
/// Protocol:
///   1. Check for "Script=" / "Sc=" / "Script_Extensions=" / "scx=" prefix.
///      If found, strip prefix and resolve the remainder as a ScriptType.
///   2. Try gc_map (general categories and groups).
///   3. Try derived_map (DerivedCoreProperties).
///   Returns null → scanner emits error.InvalidUnicodeProperty.
///
/// @stable-since: v0.1.0
pub fn resolveProperty(name: []const u8) ?PropertyId {
    // ── Script_Extensions prefix ─────────────────────────────────────────
    // Strip by the matched prefix's own length. (Both the long and short forms
    // carry 'c' at index 1 — "Script"/"sc" — so the prefix must be matched by
    // name, not by a single character.)
    if (stripEitherPrefix(name, "Script_Extensions=", "scx=")) |rest| {
        if (resolveScriptType(rest)) |st|
            return PropertyId{ .script_extension = st };
        return null;
    }

    // ── Script prefix ────────────────────────────────────────────────────
    if (stripEitherPrefix(name, "Script=", "sc=")) |rest| {
        if (resolveScriptType(rest)) |st|
            return PropertyId{ .script = st };
        return null;
    }

    // ── General category / group ─────────────────────────────────────────
    if (gc_map.get(name)) |pid| return pid;

    // ── DerivedCoreProperty ──────────────────────────────────────────────
    if (derived_map.get(name)) |dp|
        return PropertyId{ .derived = dp };

    return null;
}

/// If `name` starts with `long` or `short`, return the remainder; else null.
/// Kept as a function (rather than an inline `orelse` chain) so the result type
/// stays `?[]const u8` even when `name` is comptime-known and the first prefix
/// matches — an inline `a orelse b` would comptime-fold to a non-optional there
/// and break the `if (...) |rest|` capture.
fn stripEitherPrefix(name: []const u8, comptime long: []const u8, comptime short: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, long)) return name[long.len..];
    if (std.mem.startsWith(u8, name, short)) return name[short.len..];
    return null;
}

/// Resolve a script name (either 4-letter ISO 15924 code or long name)
/// to a ScriptType. Returns null for unrecognised names.
///
/// @stable-since: v0.1.0
pub fn resolveScriptType(name: []const u8) ?scripts.ScriptType {
    // 4-letter ISO 15924 code — direct lookup in ezi_code.
    if (name.len == 4) {
        if (scripts.fromAbbreviation(name)) |st| return st;
    }
    // Long name — map to abbreviation first, then resolve.
    if (script_long_name_map.get(name)) |abbr| {
        return scripts.fromAbbreviation(abbr);
    }
    return null;
}

/// @stable-since: v0.1.0
pub const Token = union(enum) {
    /// Any single codepoint — whether written literally or via escape.
    /// `\n` → literal(0x0A), `\(` → literal('('), `a` → literal('a').
    literal: CodePoint,

    /// \p{...} — positive Unicode property match.
    unicode_prop: PropertyId,

    /// \P{...} — negated Unicode property match.
    unicode_non_prop: PropertyId,

    /// Digit sequence inside {m,n} — e.g. the `3` and `7` in `{3,7}`.
    number: u32,

    /// (?<name>...) — the name slice points into the original pattern string.
    group_named: []const u8,

    /// (?ims) / (?ims:...) / (?-i) — inline flag change. `add` holds the flags
    /// turned on, `remove` the flags turned off. `scoped` is true for the
    /// `(?flags:...)` form (opens a group body); false for the bare `(?flags)`
    /// form (mutates the enclosing context).
    group_flag: struct {
        add: Flags,
        remove: Flags,
        scoped: bool,
    },

    // ── No-payload tokens ────────────────────────────────────────────────────

    /// .  — matches any codepoint (subject to dot_all flag).
    dot,

    /// |
    pipe,

    /// *  — greedy zero-or-more.
    star,

    /// +  — greedy one-or-more.
    plus,

    /// ?  — greedy zero-or-one (when following an atom).
    question,

    /// The trailing ? that makes a quantifier lazy: *? +? ?? {m,n}?
    question_lazy,

    /// (
    l_paren,

    /// )
    r_paren,

    /// [  — start of character class.
    l_bracket,

    /// ]  — end of character class.
    r_bracket,

    /// {  — start of counted repetition.
    l_brace,

    /// }  — end of counted repetition.
    r_brace,

    /// ^  outside a character class — line/input start anchor.
    caret,

    /// $  — line/input end anchor.
    dollar,

    /// ,  inside {m,n}.
    comma,

    /// -  inside a character class — range separator.
    dash,

    /// \d
    class_digit,

    /// \D
    class_non_digit,

    /// \w
    class_word,

    /// \W
    class_non_word,

    /// \s
    class_space,

    /// \S
    class_non_space,

    /// \X — one full grapheme cluster.
    grapheme,

    /// \b — word boundary.
    word_boundary,

    /// \B — non-word boundary.
    non_word_boundary,

    /// \A — absolute input start.
    anchor_start,

    /// \z — absolute input end.
    anchor_end,

    /// (?:
    group_non_capture,

    /// End of pattern.
    eof,
};
