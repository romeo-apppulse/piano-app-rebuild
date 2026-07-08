//
//  MonsterImagePicker.swift
//  PianoApp
//
//  A Files / iCloud-Drive image picker for monster art. Uses `asCopy: true`, so the delegate
//  receives a temporary copy it can read directly — no `startAccessingSecurityScopedResource`
//  dance — which we immediately hand to MonsterImageStore to land under a fresh name in our
//  own directory. Deliberately thin: all the logic that can break lives in MonsterImageStore
//  (unit-tested); this is just plumbing, which is why it isn't UI-tested.
//

import SwiftUI
import UniformTypeIdentifiers

struct MonsterImagePicker: UIViewControllerRepresentable {
    /// Where stored art lives — always `GameStore.imageDirectory`.
    let directory: URL
    /// Filename on success, or a `MonsterImageStore.StoreError` on failure. Not called on cancel.
    let onResult: (Result<String, Error>) -> Void
    /// Called on Cancel. The document picker dismisses ITSELF (UIKit-initiated), which does not
    /// reset a `.sheet(item:)` binding — so without this, re-tapping the SAME row can't re-present
    /// the picker (unchanged item identity → no re-presentation). The caller clears its binding here.
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: MonsterImagePicker
        init(_ parent: MonsterImagePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onResult(Result { try MonsterImageStore.store(pickedFileAt: url, into: parent.directory) })
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
