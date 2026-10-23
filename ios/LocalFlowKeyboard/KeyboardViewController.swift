import UIKit

/// A minimal keyboard: Dictate opens Local Flow (which starts listening), Insert types the last transcript.
/// Nothing records here; the app does all the listening in the foreground.
final class KeyboardViewController: UIInputViewController {
    private let dictateButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)
    private let note = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        // The Mac app's listening bar: a black pill with the white mic glyph.
        var dictate = UIButton.Configuration.filled()
        dictate.title = "Dictate"
        dictate.image = Self.glyph("mic", size: 18)
        dictate.imagePadding = 10
        dictate.baseBackgroundColor = .black
        dictate.baseForegroundColor = .white
        dictate.cornerStyle = .capsule
        dictate.background.strokeColor = UIColor.white.withAlphaComponent(0.18)
        dictate.background.strokeWidth = 1
        dictate.titleTextAttributesTransformer = Self.font(.systemFont(ofSize: 17, weight: .medium))
        dictateButton.configuration = dictate
        dictateButton.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)

        var insert = UIButton.Configuration.gray()
        insert.title = "Insert"
        insert.image = Self.glyph("text-lines", size: 18)
        insert.imagePadding = 10
        insert.titleTextAttributesTransformer = Self.font(.systemFont(ofSize: 17, weight: .medium))
        insert.baseForegroundColor = .label
        insert.cornerStyle = .large
        insert.titleLineBreakMode = .byTruncatingTail
        insert.subtitleLineBreakMode = .byTruncatingTail
        insertButton.configuration = insert
        insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)

        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.textAlignment = .center
        note.numberOfLines = 2

        let topRow = UIStackView(arrangedSubviews: [dictateButton, insertButton])
        topRow.spacing = 8
        topRow.distribution = .fillEqually

        nextKeyboardButton.configuration = Self.key(image: "globe")
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let space = Self.keyButton(title: "space", action: #selector(spaceTapped), target: self)
        let delete = Self.keyButton(image: "delete.left", action: #selector(deleteTapped), target: self)
        let enter = Self.keyButton(title: "return", action: #selector(returnTapped), target: self)
        let bottomRow = UIStackView(arrangedSubviews: [nextKeyboardButton, space, delete, enter])
        bottomRow.spacing = 6
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [nextKeyboardButton, delete] { button.widthAnchor.constraint(equalToConstant: 48).isActive = true }
        enter.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let stack = UIStackView(arrangedSubviews: [topRow, note, bottomRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            topRow.heightAnchor.constraint(equalToConstant: 96),
            bottomRow.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    override func viewWillLayoutSubviews() {
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    /// The transcript may have changed while the user was in the app.
    private func refresh() {
        let last = hasFullAccess ? SharedStore.lastTranscript : nil
        insertButton.configuration?.subtitle = last.map { String($0.prefix(40)) }
        insertButton.isEnabled = last?.isEmpty == false
        if !hasFullAccess {
            note.text = "Turn on Allow Full Access in Settings → Local Flow → Keyboards to use Insert."
        } else if last == nil {
            note.text = "Tap Dictate and speak. You come back here; tap Insert."
        } else {
            note.text = nil
        }
        note.isHidden = note.text == nil
    }

    @objc private func dictateTapped() { openApp(SharedStore.dictateURL(returningTo: HostApp.bundleID(of: self))) }

    @objc private func insertTapped() {
        refresh()
        guard let text = SharedStore.lastTranscript, !text.isEmpty else { return }
        let proxy = textDocumentProxy
        proxy.insertText(TextCleanup.fit(text, before: proxy.documentContextBeforeInput ?? "", after: proxy.documentContextAfterInput ?? ""))
    }

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func deleteTapped() { textDocumentProxy.deleteBackward() }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }

    /// Extensions can't call UIApplication.open directly, so walk the responder chain to the host's UIApplication
    /// and call its public openURL:options:completionHandler: (the old openURL: is a no-op since iOS 18).
    private func openApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, UnsafeRawPointer?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }

    /// The Mac app's glyphs (its Icons asset catalog), sized for a button.
    private static func glyph(_ name: String, size: CGFloat) -> UIImage? {
        guard let image = UIImage(named: name, in: Bundle(for: KeyboardViewController.self), with: nil) else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }.withRenderingMode(.alwaysTemplate)
    }

    private static func font(_ font: UIFont) -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
    }

    private static func key(title: String? = nil, image: String? = nil) -> UIButton.Configuration {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = image.flatMap { UIImage(systemName: $0) }
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        return config
    }

    private static func keyButton(title: String? = nil, image: String? = nil, action: Selector, target: Any) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = key(title: title, image: image)
        button.addTarget(target, action: action, for: .touchUpInside)
        return button
    }
}
