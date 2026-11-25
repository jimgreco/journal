import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The entry's text box. It behaves like a plain text editor, except that
/// Paste with a photo on the clipboard hands the photo to `onPastePhotos`
/// (SwiftUI's TextEditor offers no Paste at all for a photo).
struct EntryTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEnabled = true
    var minHeight: CGFloat = 220
    let onPastePhotos: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        // The form scrolls; the box grows with its text instead.
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onPastePhotos = onPastePhotos
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        view.isEditable = isEnabled
        view.isSelectable = isEnabled
        view.wantsFocus = isFocused && isEnabled
        if view.wantsFocus {
            if !view.isFirstResponder, view.window != nil { view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(minHeight, fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EntryTextEditor
        init(_ parent: EntryTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
            (textView as? PastingTextView)?.keepCaretVisible()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class PastingTextView: UITextView {
    var onPastePhotos: (([UIImage]) -> Void)?
    /// Focus asked for before the view was on screen.
    var wantsFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, wantsFocus, !isFirstResponder { becomeFirstResponder() }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let photos = PhotoClipboard.photos()
        if photos.isEmpty {
            super.paste(sender)
        } else {
            onPastePhotos?(photos)
        }
    }

    /// The box doesn't scroll itself, so nudge the form when typing runs off
    /// the bottom.
    func keepCaretVisible() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let range = self.selectedTextRange else { return }
            var ancestor = self.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
            let caret = self.caretRect(for: range.end).insetBy(dx: 0, dy: -12)
            scroll.scrollRectToVisible(self.convert(caret, to: scroll), animated: false)
        }
    }
}

@MainActor
enum PhotoClipboard {
    static var hasPhotos: Bool { UIPasteboard.general.hasImages }

    static func photos() -> [UIImage] {
        guard UIPasteboard.general.hasImages else { return [] }
        return UIPasteboard.general.images ?? []
    }

    static func copy(jpeg: Data) {
        UIPasteboard.general.setData(jpeg, forPasteboardType: UTType.jpeg.identifier)
    }
}
