//
//  ManageTableView.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import AppKit

/// 키보드 단축키(⌫=선택 항목 휴지통)를 위한 NSTableView 서브클래스.
/// ↑↓ 행 이동·선택은 NSTableView 기본 동작.
final class ManageTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:       // delete, forward delete
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}
