//
//  ManageRowActions.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 인스펙터·컨텍스트 메뉴 액션 묶음. `ManageViewController`가 구성해
/// SwiftUI 인스펙터에 주입한다(뷰는 동작 구현을 모름 — 분리).
struct ManageRowActions {
    var resume: (ManageRowModel) -> Void
    var reveal: (ManageRowModel) -> Void
    var openFolder: (ManageRowModel) -> Void
    var openTerminal: (ManageRowModel) -> Void
    var copyCommand: (ManageRowModel) -> Void
    var export: (ManageRowModel) -> Void
    /// 단일 행 휴지통(P4에서 마찰·Undo 연결).
    var trashRow: (ManageRowModel) -> Void
    /// 선택 묶음 휴지통(collector — P4).
    var trashSelected: () -> Void
}
