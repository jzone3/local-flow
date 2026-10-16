import Foundation

/// Built-in word lists by what the user does. Picked in setup ("What do you do?") and in Settings → Dictionary;
/// a pack's terms are added to the dictionary on top of the base list and removed again when it is deselected.
struct VocabularyPack: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let terms: [String]

    static let all: [VocabularyPack] = [
        VocabularyPack(id: "engineering", name: "Software engineer", icon: "pack-engineering", terms: [
            "React", "Node.js", "Rust", "Go", "Swift", "SwiftUI", "Xcode", "VS Code", "Docker", "AWS", "GCP", "Azure",
            "Terraform", "GraphQL", "REST", "OAuth", "JSON", "YAML", "CLI", "regex", "npm", "pnpm", "Git", "pull request",
            "refactor", "backend", "frontend", "DevOps", "Redis", "MongoDB", "Supabase", "Datadog", "Sentry", "webhook",
            "Linux", "Ubuntu", "Bash", "localhost", "Claude Code", "Copilot", "RAG", "MCP",
        ]),
        VocabularyPack(id: "product", name: "Product & design", icon: "pack-product", terms: [
            "Miro", "roadmap", "PRD", "MVP", "user research", "wireframe", "Framer", "Webflow", "Storybook", "A/B test",
            "NPS", "DAU", "MAU", "Amplitude", "Mixpanel", "PostHog", "Hotjar", "Dovetail", "UX", "UI", "Lottie", "Sketch",
            "Zeplin", "onboarding", "design system", "Tailwind", "retention", "churn",
        ]),
        VocabularyPack(id: "founder", name: "Founder & business", icon: "pack-founder", terms: [
            "Y Combinator", "YC", "SAFE", "cap table", "ARR", "MRR", "CAC", "LTV", "churn", "runway", "Series A",
            "seed round", "term sheet", "pitch deck", "board deck", "GTM", "go-to-market", "Carta", "Mercury", "Brex",
            "Ramp", "Gusto", "Rippling", "Deel", "QuickBooks", "EBITDA", "P&L", "B2B", "B2C", "PMF", "a16z", "Sequoia",
        ]),
        VocabularyPack(id: "sales", name: "Sales & marketing", icon: "pack-sales", terms: [
            "Apollo", "Outreach", "Gong", "ZoomInfo", "Clay", "SEO", "SEM", "CTA", "CRM", "ICP", "SDR", "AE", "pipeline",
            "quota", "MQL", "Mailchimp", "Klaviyo", "Google Ads", "Meta Ads", "Canva", "Webflow", "UTM", "CPC", "CTR",
            "ROAS", "Instagram", "Substack", "newsletter", "ABM", "upsell", "demo",
        ]),
        VocabularyPack(id: "finance", name: "Finance & accounting", icon: "pack-finance", terms: [
            "EBITDA", "GAAP", "IFRS", "Excel", "QuickBooks", "NetSuite", "Xero", "Bloomberg", "S&P 500", "Nasdaq", "ETF",
            "IPO", "M&A", "DCF", "IRR", "NPV", "ROI", "YoY", "QoQ", "401(k)", "Roth IRA", "accrual", "amortization",
            "FP&A", "CFO", "CPA", "audit", "invoice", "payroll",
        ]),
        VocabularyPack(id: "health", name: "Healthcare", icon: "pack-health", terms: [
            "HIPAA", "EHR", "EMR", "Epic", "Cerner", "ICD-10", "CPT", "PHI", "telehealth", "MRI", "CT scan", "ECG", "BMI",
            "PCP", "ER", "ICU", "triage", "prognosis", "diagnosis", "chronic", "acute", "pediatric", "oncology",
            "cardiology", "ibuprofen", "acetaminophen", "mg", "mL",
        ]),
        VocabularyPack(id: "legal", name: "Legal", icon: "pack-legal", terms: [
            "NDA", "LLC", "C corp", "IP", "GDPR", "CCPA", "SOC 2", "MSA", "SOW", "DPA", "indemnification", "arbitration",
            "due diligence", "pro bono", "subpoena", "affidavit", "litigation", "plaintiff", "defendant", "counsel",
            "DocuSign", "Clio", "Westlaw", "LexisNexis", "jurisdiction", "statute",
        ]),
        VocabularyPack(id: "student", name: "Student & research", icon: "pack-student", terms: [
            "GPA", "SAT", "ACT", "GRE", "MCAT", "LSAT", "PhD", "MBA", "thesis", "dissertation", "citation", "APA", "MLA",
            "Zotero", "Google Scholar", "arXiv", "Canvas", "Blackboard", "Coursera", "Khan Academy", "Grammarly",
            "Quizlet", "syllabus", "office hours", "TA", "peer review", "hypothesis",
        ]),
    ]

    static func pack(_ id: String) -> VocabularyPack? { all.first { $0.id == id } }

    /// Rewrites `text` so it contains exactly the selected packs' terms on top of whatever else is in it.
    /// Terms the user typed, the base list and rules are left alone; only terms that belong solely to a
    /// now-deselected pack are removed.
    static func apply(selected: Set<String>, previouslySelected: Set<String>, to text: String) -> String {
        let keep = Set((Vocabulary(text: Vocabulary.defaultText).terms
            + all.filter { selected.contains($0.id) }.flatMap(\.terms)).map { $0.lowercased() })
        let dropped = Set(all.filter { previouslySelected.contains($0.id) && !selected.contains($0.id) }
            .flatMap(\.terms).map { $0.lowercased() }).subtracting(keep)

        // Work on the raw lines so the user's comments, blank lines and ordering survive.
        var lines = text.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.contains("=>") { return true }
            return !dropped.contains(t.lowercased())
        }
        let existing = Set(Vocabulary(text: lines.joined(separator: "\n")).terms.map { $0.lowercased() })
        var seen = Set<String>()
        let add = all.filter { selected.contains($0.id) }.flatMap(\.terms)
            .filter { !existing.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines += add
        let out = lines.joined(separator: "\n")
        return out
    }
}
