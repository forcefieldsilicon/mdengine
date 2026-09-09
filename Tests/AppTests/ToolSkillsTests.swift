import XCTest
@testable import LAMMPSCore

/// Every registered analysis tool has a skill file for user sessions, and the
/// skill lists every default parameter key — so a parameter change without a
/// skill update fails the build. (arvand 2026-09-08: "every tool should have
/// skills too, and every change should update the respective skill".)
final class ToolSkillsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryToolHasASkillListingItsParameters() throws {
        let registry = ToolRegistry(); registry.registerBuiltIns()
        let manual = try String(contentsOf: repoRoot.appendingPathComponent("docs/manual/html/tools.html"), encoding: .utf8)
        var problems: [String] = []
        for meta in registry.metadata {
            let path = repoRoot.appendingPathComponent("skills/tools/\(meta.id)/SKILL.md")
            guard let skill = try? String(contentsOf: path, encoding: .utf8) else {
                problems.append("\(meta.id): missing skills/tools/\(meta.id)/SKILL.md"); continue
            }
            if !skill.contains("name: tool-\(meta.id)") { problems.append("\(meta.id): frontmatter name must be tool-\(meta.id)") }
            if let data = registry.tool(meta.id)?.defaultParametersJSON,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in obj.keys where !skill.contains("`\(key)`") {
                    problems.append("\(meta.id): parameter `\(key)` not documented in its skill")
                }
            }
            if !manual.contains("<h2 id=\"\(meta.id)\">") { problems.append("\(meta.id): no manual section <h2 id=\"\(meta.id)\">") }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testSkillsIndexListsEveryTool() throws {
        let registry = ToolRegistry(); registry.registerBuiltIns()
        let index = try String(contentsOf: repoRoot.appendingPathComponent("skills/README.md"), encoding: .utf8)
        for meta in registry.metadata {
            XCTAssertTrue(index.contains("tools/\(meta.id)/"), "skills/README.md does not list \(meta.id)")
        }
    }
}
