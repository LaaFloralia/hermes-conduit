#if LAA_BUILD
import Foundation

/// Money on the Usage screen reads the same everywhere. A cost read as a raw
/// counter once printed `$1.567807402`: dollars keep cents, and an amount
/// below one dollar keeps two significant digits (0.057, 0.0057), never more
/// than four decimals. A smaller nonzero cost reads as below one
/// ten-thousandth rather than as a row of zeros.
enum LAAUsageMoney {
    static func text(_ number: Double?, locale: Locale) -> String {
        guard let number, number.isFinite else { return "未取得" }
        if number == 0 { return format(0, decimals: 2, locale: locale) }
        let magnitude = abs(number)
        let decimals = magnitude >= 0.1 ? 2 : magnitude >= 0.01 ? 3 : 4
        let scale = pow(10, Double(decimals))
        let rounded = (magnitude * scale).rounded() / scale
        guard rounded > 0 else { return number > 0 ? "<$0.0001" : "未取得" }
        return (number < 0 ? "-" : "") + format(rounded, decimals: decimals, locale: locale)
    }

    private static func format(_ number: Double, decimals: Int, locale: Locale) -> String {
        "$" + number.formatted(.number.locale(locale).precision(.fractionLength(decimals)))
    }
}
#endif
