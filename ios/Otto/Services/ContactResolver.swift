import Contacts
import Foundation

/// Resolves a spoken name ("Marissa") to a texting-capable contact.
///
/// Permission is requested in context — at the first draft, not at launch.
/// CNContact itself is not Sendable, so matches are flattened to value
/// structs before leaving the actor.
actor ContactResolver {

    struct Candidate: Sendable, Identifiable, Equatable {
        let id: String
        let displayName: String
        let phoneNumber: String
    }

    enum Outcome: Sendable {
        case denied
        case none
        case matches([Candidate])
    }

    private let store = CNContactStore()

    func resolve(name: String) async -> Outcome {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if !granted {
                return .denied
            }
        case .denied, .restricted:
            return .denied
        case .authorized, .limited:
            break
        @unknown default:
            return .denied
        }

        do {
            let keys: [any CNKeyDescriptor] = [
                CNContactGivenNameKey as any CNKeyDescriptor,
                CNContactFamilyNameKey as any CNKeyDescriptor,
                CNContactPhoneNumbersKey as any CNKeyDescriptor,
            ]
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: name),
                keysToFetch: keys
            )
            let candidates = contacts.compactMap { (contact: CNContact) -> Candidate? in
                guard let number = Self.bestNumber(of: contact) else { return nil }
                let display = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return Candidate(
                    id: contact.identifier,
                    displayName: display.isEmpty ? name : display,
                    phoneNumber: number
                )
            }
            return candidates.isEmpty ? .none : .matches(candidates)
        } catch {
            print("ContactResolver: lookup failed: \(error)")
            return .none
        }
    }

    /// Prefers a mobile-labeled number (texting target), else the first one.
    private static func bestNumber(of contact: CNContact) -> String? {
        let numbers = contact.phoneNumbers
        let mobileLabels: Set<String?> = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone]
        if let mobile = numbers.first(where: { mobileLabels.contains($0.label) }) {
            return mobile.value.stringValue
        }
        return numbers.first?.value.stringValue
    }
}
