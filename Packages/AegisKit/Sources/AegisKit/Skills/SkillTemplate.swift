// Ported from OpenJarvis (open-jarvis/OpenJarvis on GitHub), src/openjarvis/skills/executor.py,
// commit 6ae98f0, Copyright the OpenJarvis authors, Apache License 2.0. Changes: translated to Swift for Aegis; string context only, no
// execution.

import Foundation

/// Single-pass OpenJarvis placeholder substitution, preserving unknown keys verbatim.
public enum SkillTemplate {
    public static func render(_ template: String, context: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{(\w+)\}"#) else { return template }
        var result = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: template),
                  let value = context[String(template[keyRange])], let range = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
}
