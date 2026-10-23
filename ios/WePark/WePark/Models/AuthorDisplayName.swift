//
//  AuthorDisplayName.swift
//  WePark
//
//  Open item #38 (account deletion) — the ONE shared label for de-attributed crowd content.
//  Contract: `supabase/10-account-deletion.sql` header, "Chat/board display for de-attributed
//  content".
//
//  When an account is deleted the server keeps the user's pins and chat messages but NULLs
//  `author_id` (the `*_with_author` views then return `author_username = NULL`). Those rows must
//  read "Former neighbor" — on EVERY surface (chat rows, crew-feed rows, block detail), never a
//  crash and never hidden.
//
//  The rule is deliberately narrow, because NULL `author_id` is ALSO how open-data pins are
//  represented ("Authorship (null = seeded by open-data pipeline)", `source` = `open_data` /
//  `hybrid`) and system-tracker chat lines have no human author either:
//    - chat:  `messageType == .user`  AND `authorId == nil`  ->  "Former neighbor"
//    - pins:  `source == .crowd`      AND `authorId == nil`  ->  "Former neighbor"
//  Everything else keeps the pre-existing fallback, "Neighbor" — including a crowd row whose
//  `authorId` is NON-nil but whose `authorUsername` is nil (a Realtime-pushed INSERT/UPDATE
//  never carries the view's joined username; the author still exists, so "Former" would be a
//  lie).
//
//  Every function is `nonisolated` (the target defaults to MainActor isolation) so plain
//  synchronous XCTest methods can call them. The core takes only primitives; it reads no
//  MainActor-isolated constant and compares no nested enum with `==`.
//

import Foundation

enum AuthorDisplayName {

    /// Label for a user-authored row whose author's account was deleted.
    nonisolated static let formerNeighbor = "Former neighbor"

    /// Pre-existing fallback for a row with no displayable name that is NOT a deleted-author
    /// crowd row (open-data pins, system-tracker lines, a live author with no joined username).
    nonisolated static let neighbor = "Neighbor"

    /// The shared rule. `isUserAuthored` is "this row is crowd/user content" (`source == crowd`
    /// for a pin, `message_type == 'user'` for chat) — open-data and system rows pass `false`.
    nonisolated static func resolve(
        username: String?,
        authorId: UUID?,
        isUserAuthored: Bool
    ) -> String {
        if let username {
            return username
        }
        if authorId == nil && isUserAuthored {
            return formerNeighbor
        }
        return neighbor
    }

    /// Pin author label. Only `source == .crowd` rows can ever read "Former neighbor".
    nonisolated static func name(for pin: CommunityPin) -> String {
        var isCrowd = false
        if case .crowd = pin.source {
            isCrowd = true
        }
        return resolve(username: pin.authorUsername, authorId: pin.authorId, isUserAuthored: isCrowd)
    }

    /// Chat author label. Only `message_type == 'user'` rows can ever read "Former neighbor".
    nonisolated static func name(for message: ZoneMessage) -> String {
        var isUserMessage = false
        if case .user = message.messageType {
            isUserMessage = true
        }
        return resolve(username: message.authorUsername, authorId: message.authorId, isUserAuthored: isUserMessage)
    }
}
