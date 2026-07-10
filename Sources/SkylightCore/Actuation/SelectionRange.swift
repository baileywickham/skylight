import Foundation

/// Pure resolution of a text match to an NSRange in the element's value, with
/// optional prefix/suffix disambiguation. select → the match's range;
/// cursor_before/after → a zero-length range at the match's start/end.
///
/// All offsets are UTF-16 code units (NSString/NSRange convention), which is
/// what kAXSelectedTextRangeAttribute expects — Swift Character offsets would
/// drift on emoji/accents. The search is `.literal` so the matched range's
/// length always equals the needle's UTF-16 length and the prefix/text offset
/// arithmetic below stays exact even for composed vs decomposed forms.
public func resolveSelectionRange(in value: String, text: String, prefix: String?,
                                  suffix: String?, selectionType: String) throws -> NSRange {
    guard ["select", "cursor_before", "cursor_after"].contains(selectionType) else {
        throw SkyServiceError(code: .invalidParams,
                              message: "selection_type must be select|cursor_before|cursor_after")
    }
    let needle = (prefix ?? "") + text + (suffix ?? "")
    let ns = value as NSString
    let found = ns.range(of: needle, options: .literal)
    guard found.location != NSNotFound else {
        throw SkyServiceError(code: .elementNotActionable,
                              message: "text '\(text)' not found in element value — call get_app_state and retry")
    }
    // The match range for `text` itself sits after the prefix, of text's UTF-16 length.
    let prefixLen = (prefix as NSString?)?.length ?? 0
    let textLen = (text as NSString).length
    let matchRange = NSRange(location: found.location + prefixLen, length: textLen)
    switch selectionType {
    case "select": return matchRange
    case "cursor_before": return NSRange(location: matchRange.location, length: 0)
    default: return NSRange(location: matchRange.location + matchRange.length, length: 0) // cursor_after
    }
}
