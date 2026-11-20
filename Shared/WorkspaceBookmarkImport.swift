import Foundation
import PadCore

/// Both platforms share reading, destination validation and acknowledged completion.
@MainActor
extension Session {
    @discardableResult
    func importBookmarks(from file: URL, into space: UUID,
                         then done: @escaping @MainActor (BookmarkImportOutcome) -> Void) -> Task<Void, Never> {
        Task {
            guard canUseWorkspace else { done(.workspaceUnavailable); return }
            let read = await Task.detached(priority: .userInitiated) { () -> Result<BookmarkImport, BookmarkImportReadFailure>? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return BookmarkFile.readExport(data)
            }.value
            guard !Task.isCancelled else { done(.cancelled); return }
            switch read {
            case nil: done(.unreadable)
            case .some(.failure(let failure)): done(failure.outcome)
            case .some(.success(let bookmarks)):
                await finishBookmarkImport(bookmarks, into: space, then: done)
            }
        }
    }

    @discardableResult
    func importBookmarks(_ bookmarks: BookmarkImport, into space: UUID,
                         then done: @escaping @MainActor (BookmarkImportOutcome) -> Void) -> Task<Void, Never> {
        Task { await finishBookmarkImport(bookmarks, into: space, then: done) }
    }

    /// Saving a previous import must not report success for a space removed
    /// while the original save failed or while this retry was awaiting disk.
    @discardableResult
    func retryBookmarkImport(_ result: BookmarkImportOutcome,
                             then done: @escaping @MainActor (BookmarkImportOutcome) -> Void) -> Task<Void, Never> {
        Task {
            guard canUseWorkspace else { done(.workspaceUnavailable); return }
            let current = result.validatingDestination(in: workspace)
            guard current.needsSave else { done(current); return }
            let saved = await saveWorkspaceNow()
            let checked = current.validatingDestination(in: workspace)
            done(checked.acknowledgingSave(saved))
        }
    }

    private func finishBookmarkImport(_ bookmarks: BookmarkImport, into space: UUID,
                                      then done: @escaping @MainActor (BookmarkImportOutcome) -> Void) async {
        guard !Task.isCancelled else { done(.cancelled); return }
        guard canUseWorkspace else { done(.workspaceUnavailable); return }
        var result = change { $0.importBookmarks(bookmarks, into: space) }
        guard result.isComplete else { done(result); return }
        SiteIcons.shared.adopt(bookmarks.icons)
        let saved = await saveWorkspaceNow()
        guard let destination = workspace.space(space) else { done(.destinationMissing(bookmarks)); return }
        switch result {
        case let .imported(added, total, _, folders):
            result = .imported(added: added, total: total, space: destination.name, folders: folders)
        case let .duplicates(total, _): result = .duplicates(total: total, space: destination.name)
        default: break
        }
        done(result.acknowledgingSave(saved, retry: BookmarkImportRetry(bookmarks: bookmarks, destination: space)))
    }
}
