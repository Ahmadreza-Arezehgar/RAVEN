//
//  Data+Extensions.swift
//  RAVEN
//
//  Safe string-to-Data conversion — eliminates force-unwrap on .data(using:)!

import Foundation

extension Data {
    /// Safely append a UTF-8 string to this Data buffer.
    /// Replaces the dangerous `"...".data(using: .utf8)!` pattern.
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
