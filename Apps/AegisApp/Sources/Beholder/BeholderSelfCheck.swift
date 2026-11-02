import Foundation

/// Where an Australian can see or limit what is held about them. Links only: Beholder never contacts, searches or
/// sends anything to these sites; the owner opens a page in the browser. Each page was checked on its own site on
/// `checked`; see docs/design/BEHOLDER-SOURCES.md.
enum BeholderSelfCheck {
    static let checked = "2026-11-02"

    /// A fixed HTTPS page, assembled locally.
    struct Page: Sendable, Equatable {
        let host: String
        let path: String

        var url: URL? {
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = host
            parts.path = path
            return parts.url
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case broker = "Data brokers", official = "Official opt-outs", breach = "Breaches"
    }

    struct Place: Identifiable, Sendable {
        let id: String
        let name: String
        let kind: Kind
        let what: String
        let action: String
        let page: Page
        /// Where the page was confirmed, when that differs from the page itself.
        var source: Page?
    }

    static let places: [Place] = [
        Place(
            id: "experian",
            name: "Experian Australia",
            kind: .broker,
            what: "Marketing data about people and households.",
            action: "Online form: ask to be excluded from marketing use.",
            page: Page(host: "www.experian.com.au", path: "/data-and-marketing/consumer-opt-out")
        ),
        Place(
            id: "equifax",
            name: "Equifax Do Not Contact",
            kind: .broker,
            what: "Equifax's marketing lists and pre-screened credit offers.",
            action: "Online form: opt out of marketing by phone, mail and email, and of pre-screened credit offers.",
            page: Page(host: "www.donotcontact.com.au", path: "/"),
            source: Page(host: "www.equifax.com.au", path: "/credit-reporting-policy")
        ),
        Place(
            id: "cotality",
            name: "Cotality (formerly CoreLogic)",
            kind: .broker,
            what: "Property data, including sales and listings.",
            action: "Write to its privacy officer to see or correct your details, or to leave its marketing lists.",
            page: Page(host: "www.cotality.com", path: "/au/legal/privacy-policy")
        ),
        Place(
            id: "doNotCall",
            name: "Do Not Call Register",
            kind: .official,
            what: "The Australian Government's register against telemarketing calls (ACMA).",
            action: "Register your numbers online. It doesn't stop scam calls.",
            page: Page(host: "www.donotcall.gov.au", path: "/consumers/register-your-numbers/")
        ),
        Place(
            id: "silentElector",
            name: "Silent elector (AEC)",
            kind: .official,
            what: "Keeps your address off future public editions of the electoral roll.",
            action: "Apply with a statutory declaration explaining the risk to your or your family's safety.",
            page: Page(host: "www.aec.gov.au", path: "/Enrolling_to_vote/Special_Category/silent-electors.htm")
        ),
        Place(
            id: "haveIBeenPwned",
            name: "Have I Been Pwned",
            kind: .breach,
            what: "Shows which known data breaches include an email address.",
            action: "Type your own email on its site. Beholder doesn't send it anywhere.",
            page: Page(host: "haveibeenpwned.com", path: "/")
        ),
    ]
}
