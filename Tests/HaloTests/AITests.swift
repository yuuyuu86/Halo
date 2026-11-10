import XCTest
@testable import Halo

/// The AI path has no network to stub — it runs on-device — so what is worth
/// pinning down is everything *around* the model: how prompts are assembled,
/// which items survive the ring filter, and whether the shipped ring is sane.
@MainActor
final class AITests: XCTestCase {

    // MARK: Prompt assembly

    func testPlaceholderIsReplacedInPlace() {
        let filled = AIService.shared.fill(prompt: "次を翻訳:\n\n{input}\n\n以上", input: "hello")
        XCTAssertEqual(filled, "次を翻訳:\n\nhello\n\n以上")
        XCTAssertFalse(filled.contains("{input}"))
    }

    func testPromptWithoutPlaceholderGetsTheInputAppended() {
        XCTAssertEqual(AIService.shared.fill(prompt: "要約して", input: "本文"),
                       "要約して\n\n本文")
    }

    func testEmptyInputDoesNotLeaveADanglingSeparator() {
        XCTAssertEqual(AIService.shared.fill(prompt: "こんにちは", input: ""), "こんにちは")
    }

    func testEmptyInputStillClearsThePlaceholder() {
        XCTAssertEqual(AIService.shared.fill(prompt: "a{input}b", input: ""), "ab")
    }

    func testSurroundingWhitespaceInTheTemplateIsTrimmed() {
        XCTAssertEqual(AIService.shared.fill(prompt: "  要約  \n", input: "x"), "要約\n\nx")
    }

    func testEveryOccurrenceOfThePlaceholderIsFilled() {
        XCTAssertEqual(AIService.shared.fill(prompt: "{input} / {input}", input: "z"), "z / z")
    }

    // MARK: Free-input items

    func testOnlyTypedInputItemsIgnoreTheRingFilter() {
        let typed = RingItem(title: "自由入力",
                             action: HaloAction(kind: .ai, value: "{input}",
                                                argument: AIInputSource.typed.rawValue))
        let fromSelection = RingItem(title: "要約",
                                     action: HaloAction(kind: .ai, value: "{input}",
                                                        argument: AIInputSource.selection.rawValue))
        let plain = RingItem(title: "Safari", action: .app("/Applications/Safari.app"))

        XCTAssertTrue(typed.ignoresRingFilter)
        XCTAssertFalse(fromSelection.ignoresRingFilter)
        XCTAssertFalse(plain.ignoresRingFilter)
    }

    func testTheAIRingKeepsAFreeInputTargetWhateverIsTyped() {
        // Typing a prompt filters every named item away; without an exempt
        // item there would be nothing left to send it to.
        let ring = DefaultConfig.ai()
        let query = "この文章を短くして"
        let surviving = ring.activeItems.filter {
            $0.ignoresRingFilter || $0.title.lowercased().contains(query.lowercased())
        }
        XCTAssertEqual(surviving.count, 1)
        XCTAssertTrue(surviving[0].ignoresRingFilter)
    }

    // MARK: Shipped ring

    func testEveryAIItemCarriesAPromptAndAKnownInputSource() {
        for item in DefaultConfig.ai().items {
            XCTAssertEqual(item.action.kind, .ai, "\(item.title)")
            XCTAssertFalse(item.action.value.trimmingCharacters(in: .whitespaces).isEmpty,
                           "「\(item.title)」にプロンプトがありません")
            XCTAssertNotNil(AIInputSource(rawValue: item.action.argument),
                            "「\(item.title)」の入力元が不正です")
        }
    }

    func testAIItemsNeverDiscardTheirOutput() {
        for item in DefaultConfig.ai().items {
            XCTAssertNotEqual(item.action.sink, .discard,
                              "「\(item.title)」は結果が捨てられてしまいます")
        }
    }

    func testTranslationItemsPasteAndSummariesDoNot() {
        let ring = DefaultConfig.ai()
        let translate = ring.items.first { $0.title == "日本語に" }
        let summarise = ring.items.first { $0.title == "要約" }
        XCTAssertEqual(translate?.action.sink, .paste, "翻訳は置き換えたい")
        XCTAssertEqual(summarise?.action.sink, .clipboard, "要約は元の文を消したくない")
    }

    func testDefaultConfigIncludesAWayToReachTheAIRing() {
        let config = DefaultConfig.make()
        let root = config.rootRing
        XCTAssertNotNil(root?.items.first {
            $0.action.kind == .subring && $0.action.value == DefaultConfig.aiID
        }, "ルートリングから AI に到達できません")
        XCTAssertNotNil(config.ring(withID: DefaultConfig.aiID))
    }

    // MARK: Config

    func testAKnownProviderIsLeftAlone() {
        var config = HaloConfig()
        config.ai.provider = "apple"
        XCTAssertEqual(ConfigStore.migrate(config).ai.provider, "apple")
    }

    func testAIIsOffUntilTheUserTurnsItOn() {
        XCTAssertFalse(AIConfig.default.enabled)
        XCTAssertFalse(HaloConfig().ai.enabled)
    }

    func testAIConfigWrittenBeforeTheOnDeviceSwitchStillDecodes() throws {
        // The old shape carried endpoint / model / apiKeyEnvVar.
        let json = """
        {"enabled": true, "provider": "anthropic", "model": "claude-sonnet-5",
         "endpoint": "https://example.com", "apiKeyEnvVar": "KEY",
         "systemPrompt": "be brief", "maxTokens": 512}
        """
        let config = try JSONDecoder().decode(AIConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.systemPrompt, "be brief")
        XCTAssertEqual(config.maxTokens, 512)
        XCTAssertEqual(config.temperature, 0.3, "無かった項目は既定値になること")
    }

    func testAIConfigRoundTrips() throws {
        var config = AIConfig.default
        config.enabled = true
        config.temperature = 0.9
        config.systemPrompt = "custom"
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AIConfig.self, from: data), config)
    }

    // MARK: Migration

    func testMigrationAddsTheAIRingAndAWayToReachIt() {
        var config = HaloConfig()
        config.version = 2
        config.rings = [Ring(id: "mine", title: "自分のリング")]
        config.rootRingID = "mine"

        let migrated = ConfigStore.migrate(config)
        XCTAssertEqual(migrated.version, HaloConfig.currentVersion)
        XCTAssertNotNil(migrated.ring(withID: DefaultConfig.aiID))

        let root = migrated.ring(withID: "mine")
        XCTAssertNotNil(root?.items.first {
            $0.action.kind == .subring && $0.action.value == DefaultConfig.aiID
        })
        XCTAssertEqual(root?.title, "自分のリング", "既存のリングは残ること")
    }

    func testAStaleProviderIsRepairedRegardlessOfVersion() {
        // The repair must not be gated on the version: a config already stamped
        // current can still name a provider that no longer exists.
        var config = HaloConfig()
        config.version = HaloConfig.currentVersion
        config.ai.provider = "anthropic"
        config.ai.systemPrompt =
            "You are Halo, a concise macOS assistant. Answer with the transformed text only."

        let migrated = ConfigStore.migrate(config)
        XCTAssertEqual(migrated.ai.provider, "apple")
        XCTAssertEqual(migrated.ai.systemPrompt, AIConfig.defaultSystemPrompt,
                       "手つかずの旧プロンプトは差し替える")
    }

    func testMigrationKeepsASystemPromptTheUserWrote() {
        var config = HaloConfig()
        config.version = HaloConfig.currentVersion
        config.ai.provider = "anthropic"
        config.ai.systemPrompt = "常に関西弁で答えて"

        let migrated = ConfigStore.migrate(config)
        XCTAssertEqual(migrated.ai.provider, "apple")
        XCTAssertEqual(migrated.ai.systemPrompt, "常に関西弁で答えて",
                       "自分で書いたプロンプトは残すこと")
    }

    func testMigrationDoesNotAddTheAIEntryTwice() {
        var config = HaloConfig()
        config.version = 2
        config.rings = [Ring(id: "mine", title: "R")]
        config.rootRingID = "mine"

        let once = ConfigStore.migrate(config)
        var again = once
        again.version = 2                      // pretend an older build wrote it
        let twice = ConfigStore.migrate(again)

        let entries = twice.ring(withID: "mine")?.items.filter {
            $0.action.kind == .subring && $0.action.value == DefaultConfig.aiID
        }
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(twice.rings.filter { $0.id == DefaultConfig.aiID }.count, 1)
    }
}

/// The review step stands between the model and the user's document, so its
/// default and its wiring matter more than most settings.
final class AIReviewTests: XCTestCase {

    func testReviewIsOnByDefault() {
        XCTAssertTrue(AIConfig.default.reviewBeforeApplying,
                      "既定で確認を挟むこと。選択範囲の置き換えは取り消しにくい")
        XCTAssertTrue(HaloConfig().ai.reviewBeforeApplying)
    }

    func testConfigWrittenBeforeTheReviewStepDefaultsToReviewing() throws {
        let json = """
        {"enabled": true, "provider": "apple", "systemPrompt": "s",
         "temperature": 0.3, "maxTokens": 1024}
        """
        let config = try JSONDecoder().decode(AIConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.reviewBeforeApplying,
                      "設定が無い古いファイルでも、安全側に倒すこと")
    }

    func testReviewFlagRoundTrips() throws {
        var config = AIConfig.default
        config.reviewBeforeApplying = false
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(try JSONDecoder().decode(AIConfig.self, from: data).reviewBeforeApplying)
    }

    func testItemsThatRewriteTextUsePasteSoTheyOfferReplacement() {
        // The review panel only shows "置き換える" for paste-sink items, so the
        // rewriting prompts have to be marked that way.
        let rewriting = ["日本語に", "英語に", "整える", "丁寧に"]
        for title in rewriting {
            let item = DefaultConfig.ai().items.first { $0.title == title }
            XCTAssertEqual(item?.action.sink, .paste, "「\(title)」は置き換えを提案すべき")
        }
    }

    func testItemsThatProduceNewTextDoNotReplaceTheSelection() {
        for title in ["要約", "コードを説明", "自由入力"] {
            let item = DefaultConfig.ai().items.first { $0.title == title }
            XCTAssertNotEqual(item?.action.sink, .paste,
                              "「\(title)」で元の文が消えてはいけない")
        }
    }
}

/// Localisation is easy to half-do: a string that was never wrapped, or a
/// translation whose key no longer exists in the source. These check the two
/// shipped strings files against each other and against the source.
final class LocalizationTests: XCTestCase {

    private var resourcesURL: URL {
        // Tests run from the package root.
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
    }

    private func entries(_ locale: String) throws -> [String: String] {
        let url = resourcesURL
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: String]
        return try XCTUnwrap(parsed)
    }

    func testBothLocalisationsParse() throws {
        XCTAssertFalse(try entries("ja").isEmpty)
        XCTAssertFalse(try entries("en").isEmpty)
    }

    func testEveryJapaneseKeyHasAnEnglishTranslation() throws {
        let ja = try entries("ja")
        let en = try entries("en")
        let missing = ja.keys.filter { en[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "英訳がありません: \(missing.prefix(10))")
    }

    func testEnglishTranslationsAreNotJustTheJapanese() throws {
        let en = try entries("en")
        let japanese = try NSRegularExpression(pattern: "[\\u3040-\\u30ff\\u4e00-\\u9fff]")
        let untranslated = en.filter { _, value in
            let range = NSRange(value.startIndex..., in: value)
            return japanese.firstMatch(in: value, range: range) != nil
        }
        XCTAssertTrue(untranslated.isEmpty,
                      "日本語のまま残っています: \(untranslated.keys.sorted().prefix(10))")
    }

    func testFormatSpecifiersMatchBetweenLocales() throws {
        let ja = try entries("ja")
        let en = try entries("en")
        let spec = try NSRegularExpression(pattern: "%(?:@|lld|d|\\.?[0-9]*f)")

        func specifiers(_ s: String) -> [String] {
            let range = NSRange(s.startIndex..., in: s)
            return spec.matches(in: s, range: range).map {
                String(s[Range($0.range, in: s)!])
            }
        }

        for (key, english) in en {
            guard ja[key] != nil else { continue }
            XCTAssertEqual(specifiers(key).sorted(), specifiers(english).sorted(),
                           "書式指定子が一致しません: \(key)")
        }
    }

    func testJapaneseFileIsAnIdentityMapping() throws {
        let ja = try entries("ja")
        for (key, value) in ja {
            XCTAssertEqual(key, value, "ja は開発言語なのでキーと値が一致すること")
        }
    }
}
