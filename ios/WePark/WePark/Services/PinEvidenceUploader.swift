//
//  PinEvidenceUploader.swift
//  WePark
//
//  FT-15 / TF2-15 — Temporary Block-Scoped Restrictions, Stream B3 (write path + evidence
//  upload). Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §3.4 (write order),
//  §7 (photo evidence & PII), §12 (AC-S4's client-side counterpart).
//
//  Responsibilities:
//   - Uploads the captured evidence photo to the private `pin-evidence` Storage bucket via
//     the plain Storage REST API (`POST /storage/v1/object/{bucket}/{path}`). No Storage SDK
//     product is linked yet — `SupabaseClients.swift`'s header notes only the `Auth` product
//     is wired as of Stream A. This mirrors `CommunityPinService`'s existing "raw URLSession
//     + Codable, no SDK" convention for everything outside Auth.
//   - Inserts the matching `pin_evidence` row (`report_group_id`, `storage_path`,
//     `uploaded_by`).
//   - Owns the `{auth.uid()}/{report_group_id}/{filename}` object-path convention that the
//     schema's `storage.objects` RLS policies are keyed on
//     (`supabase/02f-block-scoped-restrictions.sql` §8: `auth.uid()::text ==
//     (storage.foldername(name))[1]`). Get this wrong and the insert policy rejects the
//     upload with a 403 — there is no other path shape that will pass RLS.
//
//  PII (spec §7 — this is the feature's sharpest edge):
//   - The evidence photo commonly contains a real name and phone number (the placard this
//     feature was designed around, per the spec's §1). This type never logs the storage
//     path, the filename, or any photo bytes/metadata anywhere, including to the console —
//     there is no `print`/`os_log` call anywhere in this file. Errors surface only HTTP
//     status codes, never request payloads or paths.
//   - Filenames are generated INTERNALLY (UUID-based, `fileExtension(forContentType:)`
//     picks the extension) — never derived from user input, the original capture/
//     camera-roll filename, or any text the user typed. No PII-bearing filename can leak
//     into the storage path, even by accident.
//   - The photo is never read back by this type or exposed through any public-facing
//     model. `pins_with_author` (every client's read path) gains no evidence-related
//     column — see `CommunityPin.swift`'s `hasEvidencePhoto` doc comment for the one
//     narrow, boolean-only trust-signal seam that exists instead (currently inert, OQ-5).
//
//  Auth: requires an authenticated session — both the storage insert policy and
//  `pin_evidence_insert_own` require `auth.uid()` to match the path prefix /
//  `uploaded_by` respectively. Mirrors `CommunityPinService`'s write-path auth pattern
//  (`authService.validAccessToken()` + `authService.currentUserId`).
//
//  Write-order note (§3.4, `supabase/02f-block-scoped-restrictions.sql` §4's "Known
//  accepted gap" comment): this type's `upload(...)` runs BEFORE any `pins` row exists for
//  the report — the caller (`CommunityPinService.insertBlockScopedReport`) generates
//  `report_group_id` up front and calls this first. See that method's doc comment for the
//  full partial-failure decision this ordering implies.
//
//  ── COMPILE-UNVERIFIED ──────────────────────────────────────────────────────────────────
//  Written on a Linux VPS with no Xcode/Swift toolchain — never compiled or run. Requires a
//  Mac `xcodebuild build` + `test` pass before merge. See the PR description.
//

import Foundation

// MARK: - PinEvidenceUploadError

/// Errors from `PinEvidenceUploader.upload(...)`.
enum PinEvidenceUploadError: Error {
    /// No valid auth session. Both the storage insert policy and `pin_evidence_insert_own`
    /// require a non-null `auth.uid()`.
    case notAuthenticated
    /// The captured photo has no bytes — nothing to upload. Defensive check; the UI layer
    /// (Stream B2) is expected to already gate Submit on a captured image (AC-R5), this is
    /// a second, independent guard at the write-path boundary.
    case emptyPhotoData
    /// The Storage REST API upload (`POST /storage/v1/object/pin-evidence/...`) returned a
    /// non-2xx status.
    case storageUploadFailed(statusCode: Int)
    /// The `pin_evidence` row insert returned a non-2xx status. By the time this can be
    /// thrown, the photo bytes already reached Storage — `upload(...)` best-effort deletes
    /// that now-orphaned object before rethrowing this error (see that method's body).
    case recordInsertFailed(statusCode: Int)
    /// Request body JSON encoding failed (should not happen for this fixed, simple payload
    /// shape — kept for parity with `CommunityPinWriteError.encodingFailure`).
    case encodingFailure
}

extension PinEvidenceUploadError: LocalizedError {
    /// User-facing copy. Deliberately generic and never includes a status code, a path, or
    /// any server-provided message text verbatim — those could in principle echo back
    /// request details we don't want surfaced (§7 PII posture: fail closed on wording too).
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You need to be signed in to attach evidence. Try again in a moment."
        case .emptyPhotoData:
            return "No photo was captured."
        case .storageUploadFailed, .recordInsertFailed:
            return "Couldn't upload your evidence photo. Check your connection and try again."
        case .encodingFailure:
            return "Something went wrong preparing your report. Try again."
        }
    }
}

// MARK: - PinEvidenceUploadResult

/// Result of a successful evidence upload.
struct PinEvidenceUploadResult {
    /// Path within the private `pin-evidence` bucket: `{auth.uid()}/{report_group_id}/{filename}`.
    /// Callers must not surface this in any user-visible UI or log (§7).
    let storagePath: String
    /// The inserted `pin_evidence.id`, if the server returned a representation. `nil` is not
    /// an error — the row was still inserted; this is a convenience value only, currently
    /// unused by any caller (kept for forward-compat, e.g. a future moderation tool).
    let evidenceId: UUID?
}

// MARK: - PinEvidenceUploader

/// Uploads block-scoped restriction report evidence photos (FT-15/TF2-15 §7) and records
/// the matching `pin_evidence` row.
///
/// `@MainActor` to match `CommunityPinService` / `SupabaseAuthService` — every call into
/// `authService` reads as a synchronous same-actor access (no `await` needed on its
/// properties), matching the rest of the write-path code style in this codebase.
@MainActor
final class PinEvidenceUploader {

    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private let urlSession: URLSession
    private let authService: SupabaseAuthService

    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL (e.g. `https://<project>.supabase.co`).
    ///   - supabaseAnonKey: The anon/public API key. NEVER hardcode this value in source.
    ///   - urlSession: Injectable for tests (MockURLProtocol pattern, matching
    ///     `CommunityPinService`). Defaults to `.shared`.
    ///   - authService: Provides the JWT + `auth.uid()` for the authenticated upload/insert.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared,
        authService: SupabaseAuthService
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.authService = authService
    }

    // MARK: - Upload

    /// Uploads `photoData` to the private `pin-evidence` bucket, then inserts a matching
    /// `pin_evidence` row.
    ///
    /// If the `pin_evidence` row insert fails AFTER the Storage upload already succeeded,
    /// this method attempts to best-effort delete the now-orphaned Storage object before
    /// rethrowing.
    ///
    /// **Known limitation, flagged honestly rather than overclaimed:** as of this
    /// migration, `supabase/02f-block-scoped-restrictions.sql` §8 deliberately ships NO
    /// delete policy on `storage.objects` in phase 1 ("No update/delete storage policy in
    /// phase 1 — same rationale as the pin_evidence table RLS above"). That means this
    /// delete attempt will itself be rejected by RLS (403) on the CURRENT schema — so in
    /// practice today, a `pin_evidence` row-insert failure DOES leave an orphaned Storage
    /// object with zero DB trace, despite this method's attempt. The call is kept anyway
    /// (harmless — its failure is swallowed, matching the "nothing safe to retry" reasoning
    /// below) because it costs nothing and becomes a real fix automatically the moment a
    /// future migration adds an owner-scoped delete policy, without requiring a change to
    /// this file. This specific orphan shape is a materially smaller risk than it sounds:
    /// the bucket is private, the path is keyed to the uploader's own `auth.uid()`, and §7
    /// already accepts "no automatic deletion in phase 1" as the retention posture for
    /// evidence that DOES have a DB row — an occasional evidence object with no DB row at
    /// all is the same PII-exposure risk (none, to anyone but the uploader), just without a
    /// pointer to it. Not re-litigated here; flagged for the orchestrator/PR description.
    ///
    /// A failure of the delete-attempt itself is swallowed regardless of cause; there is
    /// nothing safe to retry without risking touching an unrelated object on a later call.
    /// See the doc comment on `CommunityPinService.insertBlockScopedReport` for the broader
    /// partial-failure decision this fits into.
    ///
    /// - Parameters:
    ///   - photoData: Raw image bytes (e.g. `UIImage.jpegData(compressionQuality:)` output).
    ///   - contentType: MIME type of `photoData`. Default `"image/jpeg"`.
    ///   - reportGroupId: The client-generated UUID shared by this report's N `pins` rows.
    ///     Per §3.4, this call happens BEFORE any of those rows exist.
    /// - Returns: The storage path and (if returned) the inserted row's id.
    /// - Throws: `PinEvidenceUploadError`.
    func upload(
        photoData: Data,
        contentType: String = "image/jpeg",
        reportGroupId: UUID
    ) async throws -> PinEvidenceUploadResult {
        guard !photoData.isEmpty else {
            throw PinEvidenceUploadError.emptyPhotoData
        }
        guard let jwt = await authService.validAccessToken(),
              let userId = authService.currentUserId else {
            throw PinEvidenceUploadError.notAuthenticated
        }

        let filenameExtension = Self.fileExtension(forContentType: contentType)
        let filename = "\(UUID().uuidString)\(filenameExtension)"

        // Path convention is FIXED by the schema's storage.objects RLS policies — the
        // leading segment MUST be the uploader's own auth.uid(), or both the select and
        // insert policies reject the object. See this file's header for the exact policy.
        let objectPath = "\(userId.uuidString)/\(reportGroupId.uuidString)/\(filename)"

        try await uploadObject(data: photoData, contentType: contentType, objectPath: objectPath, jwt: jwt)

        do {
            let evidenceId = try await insertEvidenceRecord(
                storagePath: objectPath,
                reportGroupId: reportGroupId,
                uploadedBy: userId,
                jwt: jwt
            )
            return PinEvidenceUploadResult(storagePath: objectPath, evidenceId: evidenceId)
        } catch {
            await deleteObjectBestEffort(objectPath: objectPath, jwt: jwt)
            throw error
        }
    }

    // MARK: - Storage upload (Storage REST API — no Storage SDK product linked yet)

    private func uploadObject(
        data: Data,
        contentType: String,
        objectPath: String,
        jwt: String
    ) async throws {
        let url = supabaseURL.appendingPathComponent("storage/v1/object/pin-evidence/\(objectPath)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PinEvidenceUploadError.storageUploadFailed(statusCode: status)
        }
    }

    /// Best-effort compensating delete for a Storage object left behind by a failed
    /// `pin_evidence` row insert. Failures here are swallowed — see `upload(...)`'s doc
    /// comment for why that's the correct behavior, not an oversight.
    private func deleteObjectBestEffort(objectPath: String, jwt: String) async {
        let url = supabaseURL.appendingPathComponent("storage/v1/object/pin-evidence/\(objectPath)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        _ = try? await urlSession.data(for: request)
    }

    // MARK: - pin_evidence row insert

    private func insertEvidenceRecord(
        storagePath: String,
        reportGroupId: UUID,
        uploadedBy: UUID,
        jwt: String
    ) async throws -> UUID? {
        let payload: [String: Any] = [
            "report_group_id": reportGroupId.uuidString,
            "storage_path":    storagePath,
            "uploaded_by":     uploadedBy.uuidString,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw PinEvidenceUploadError.encodingFailure
        }

        let url = supabaseURL.appendingPathComponent("rest/v1/pin_evidence")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PinEvidenceUploadError.recordInsertFailed(statusCode: status)
        }

        // Best-effort id extraction — a decode failure here does NOT mean the insert
        // failed (the HTTP status already confirmed success above); it just means the
        // caller doesn't get a convenience id back.
        struct EvidenceRow: Decodable { let id: UUID }
        guard let rows = try? JSONDecoder().decode([EvidenceRow].self, from: data) else {
            return nil
        }
        return rows.first?.id
    }

    // MARK: - Helpers

    private static func fileExtension(forContentType contentType: String) -> String {
        switch contentType {
        case "image/png":               return ".png"
        case "image/heic":              return ".heic"
        case "image/jpeg", "image/jpg": return ".jpg"
        default:                        return ".jpg"
        }
    }
}
