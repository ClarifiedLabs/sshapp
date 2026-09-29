//
//  TerminalGridMetrics.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

public struct TerminalGridMetrics: Sendable, Equatable {
    public var columns: UInt16
    public var rows: UInt16
    public var widthPixels: UInt32
    public var heightPixels: UInt32
    public var cellWidthPixels: UInt32
    public var cellHeightPixels: UInt32

    public init(
        columns: UInt16,
        rows: UInt16,
        widthPixels: UInt32,
        heightPixels: UInt32,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
    }
}
