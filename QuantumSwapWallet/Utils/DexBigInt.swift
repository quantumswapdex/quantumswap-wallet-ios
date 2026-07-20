// DexBigInt.swift
// Minimal unsigned decimal-string arithmetic for LP remove-liquidity
// math (Android uses BigInteger). Avoids fixed-precision Decimal loss
// on large wei values.

import Foundation

enum DexBigInt {

    /// `(a * b) / denom` floored, all unsigned decimal digit strings.
    static func mulDiv(_ a: String, _ b: String, _ denom: String) -> String {
        let num = multiply(normalize(a), normalize(b))
        return divide(num, normalize(denom))
    }

    /// `a * small` where small is a non-negative Int.
    static func mulSmall(_ a: String, _ small: Int) -> String {
        if small <= 0 { return "0" }
        return multiply(normalize(a), String(small))
    }

    /// `a / small` floored.
    static func divSmall(_ a: String, _ small: Int) -> String {
        if small <= 0 { return "0" }
        return divide(normalize(a), String(small))
    }

    static func isPositive(_ s: String) -> Bool {
        let n = normalize(s)
        return n != "0"
    }

    // MARK: - Internals

    private static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "0" }
        var work = t
        if work.hasPrefix("+") { work.removeFirst() }
        if work.hasPrefix("-") { return "0" }
        guard work.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "0" }
        let stripped = work.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }

    private static func toDigits(_ s: String) -> [UInt8] {
        // little-endian digits
        return s.reversed().compactMap { c in
            guard let v = c.wholeNumberValue else { return nil }
            return UInt8(v)
        }
    }

    private static func fromDigits(_ digits: [UInt8]) -> String {
        var d = digits
        while d.count > 1 && d.last == 0 { d.removeLast() }
        if d.isEmpty { return "0" }
        return d.reversed().map { String($0) }.joined()
    }

    private static func multiply(_ a: String, _ b: String) -> String {
        if a == "0" || b == "0" { return "0" }
        let x = toDigits(a)
        let y = toDigits(b)
        var out = [UInt8](repeating: 0, count: x.count + y.count)
        for i in 0..<x.count {
            var carry = 0
            for j in 0..<y.count {
                let v = Int(out[i + j]) + Int(x[i]) * Int(y[j]) + carry
                out[i + j] = UInt8(v % 10)
                carry = v / 10
            }
            var k = i + y.count
            while carry > 0 {
                if k >= out.count { out.append(0) }
                let v = Int(out[k]) + carry
                out[k] = UInt8(v % 10)
                carry = v / 10
                k += 1
            }
        }
        return fromDigits(out)
    }

    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        // little-endian
        if a.count != b.count { return a.count > b.count ? 1 : -1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            if a[i] != b[i] { return a[i] > b[i] ? 1 : -1 }
        }
        return 0
    }

    private static func subtractInPlace(_ a: inout [UInt8], _ b: [UInt8]) {
        var borrow = 0
        for i in 0..<a.count {
            var v = Int(a[i]) - borrow - (i < b.count ? Int(b[i]) : 0)
            if v < 0 {
                v += 10
                borrow = 1
            } else {
                borrow = 0
            }
            a[i] = UInt8(v)
        }
        while a.count > 1 && a.last == 0 { a.removeLast() }
    }

    private static func divide(_ a: String, _ b: String) -> String {
        if b == "0" { return "0" }
        if a == "0" { return "0" }
        let x = toDigits(a)
        let y = toDigits(b)
        if compare(x, y) < 0 { return "0" }
        // Long division on digit strings (MSB first).
        var remainder: [UInt8] = []
        var quotientDigits: [UInt8] = []
        for digit in x.reversed() {
            remainder.insert(digit, at: 0)
            while remainder.count > 1 && remainder.last == 0 {
                remainder.removeLast()
            }
            var q: UInt8 = 0
            while compare(remainder, y) >= 0 {
                subtractInPlace(&remainder, y)
                q += 1
            }
            quotientDigits.append(q)
        }
        // quotientDigits is MSB-first; convert to little-endian for fromDigits
        let little = Array(quotientDigits.reversed())
        return fromDigits(little)
    }
}
