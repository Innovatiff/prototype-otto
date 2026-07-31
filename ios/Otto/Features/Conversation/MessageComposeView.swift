import MessageUI
import SwiftUI
import UIKit

/// What the user is about to send: recipient number(s) and prefilled body.
struct ComposeRequest: Identifiable, Equatable {
    let id = UUID()
    let recipientName: String
    let recipients: [String]
    let body: String
}

/// The system message sheet, prefilled. The user taps send — Otto never
/// sends programmatically; iOS forbids it and there is no workaround.
struct MessageComposeView: UIViewControllerRepresentable {
    let request: ComposeRequest
    let onFinish: () -> Void

    static var canSend: Bool {
        MFMessageComposeViewController.canSendText()
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = request.recipients
        controller.body = request.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onFinish()
        }
    }
}
