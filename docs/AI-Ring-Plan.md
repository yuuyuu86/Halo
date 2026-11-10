# AI リング 実装計画

Halo の AI 機能を「設定はあるが中身がない」状態から、有効にすればすぐ使える状態にするための設計。

---

## 0. 現状の棚卸し

すでにあるもの:

- `AIProvider` プロトコルと `AIService`（登録・プロンプト展開）
- `AnthropicProvider`（**一度も実行されていない**）
- `AIConfig`（プロバイダ・モデル・エンドポイント・システムプロンプト・最大トークン）
- Keychain 読み書き（`Security`）と環境変数フォールバック
- 項目エディタの `.ai` アクション種別、`ResultSink`（クリップボード / ペースト / 通知）
- `SelectionReader`（AX 経由の選択テキスト取得）

足りないもの:

- 既定の AI リングとプロンプト（**有効にしても中身が空**）
- 実行中の表示、キャンセル、タイムアウト、リトライ
- ストリーミング
- 選択テキストの実用的な取得（AX だけでは多くのアプリで取れない）
- テスト（ネットワークを叩かずに検証する仕組み）

---

## 1. どのモデル API を使うか

3 系統を `AIProvider` の実装として並べる。既存のプロトコルがそのまま使えるので、上位（リング項目・実行経路・設定 UI）の変更は不要。

```swift
protocol AIProvider: Sendable {
    var identifier: String { get }
    func complete(prompt: String, input: String, config: AIConfig) async throws -> String
}
```

### A. Apple オンデバイス — `FoundationModels`（推奨・既定）

**この Mac 上でコンパイルと実行を確認済み**（macOS 26.5 / Xcode 26.6）。

```swift
import FoundationModels

let model = SystemLanguageModel.default
switch model.availability {
case .available:
    let session = LanguageModelSession(instructions: systemPrompt)
    let text = try await session.respond(to: prompt).content
case .unavailable(let reason):
    throw AIError.unavailable(reason)
}
```

確認できた API 表面:

| 呼び出し | 状態 |
|---|---|
| `SystemLanguageModel.default.availability` | 実行確認済み |
| `.available` / `.unavailable(UnavailableReason)` | 実行確認済み |
| `LanguageModelSession(instructions:)` | 実行確認済み |
| `try await session.respond(to:).content` | 実行確認済み |
| `session.streamResponse(to:)`（`for try await`） | 型チェック確認済み |
| `session.isResponding` | 型チェック確認済み |

- **長所**: API キー不要・無料・オフライン・データが端末外に出ない。Halo の「既定でネットに出ない」方針とそのまま噛み合う。有効化のハードルが実質ゼロ。
- **短所**: macOS 26 かつ Apple Intelligence が有効であることが前提。小型モデルなので長文要約や凝った指示は不得手。
- **注意**: この Mac では現在 `unavailable(.appleIntelligenceNotEnabled)` が返る。deployment target は macOS 14 なので `@available(macOS 26, *)` でのゲートと、使えないときの案内が必須。

### B. Anthropic Messages API（クラウド）

```
POST https://api.anthropic.com/v1/messages
x-api-key: <key>
anthropic-version: 2023-06-01
content-type: application/json

{"model": "...", "max_tokens": 1024, "system": "...",
 "messages": [{"role": "user", "content": "..."}]}
```

レスポンスは `content` 配列の `text` を連結。ストリーミングは `"stream": true` で SSE になるので、`URLSession.bytes(for:)` で行単位に読み、`data:` 行を JSON デコードして差分テキストを連結する。

モデル ID は Claude 5 系（`claude-opus-5` / `claude-sonnet-5` / `claude-fable-5`）と `claude-haiku-4-5-20251001`。ランチャー用途は応答が返るまでの体感が支配的なので、既定は `claude-sonnet-5`、軽い変換用に Haiku も選べるようにする。

エラーは非 2xx のボディに種別とメッセージが入る。401（キー不正）・429（レート制限）・5xx（過負荷）を日本語に翻訳して HUD に出し、429 と 5xx のみ指数バックオフで最大 2 回リトライする。

> リクエスト形状とヘッダは公開ドキュメントに基づく想定。**実キーで 1 回通してから確定させる**。キーがない場合はスタブテストまでで止める。

### C. OpenAI 互換 / ローカル（Ollama・LM Studio など）

`POST {endpoint}/v1/chat/completions` に `Authorization: Bearer`。ローカルで完結させたい場合の受け皿。同じプロトコルに載るので追加コストは小さい。

---

## 2. 入力の取得

| 入力 | API | 権限 |
|---|---|---|
| クリップボード | `NSPasteboard.general.string(forType:)` | 不要 |
| 選択テキスト（第一候補） | `AXUIElementCopyAttributeValue` で `kAXFocusedUIElement` → `kAXSelectedText` | アクセシビリティ |
| 選択テキスト（フォールバック） | `CGEvent` で ⌘C を合成 → `NSPasteboard.changeCount` を監視 → 取得後に元の内容へ復元 | アクセシビリティ |

**フォールバックが実質必須**。AX で選択テキストを公開しないアプリが多く、いまの `SelectionReader` だけでは「選択テキスト」を指定してもクリップボードに落ちるだけになる。

⌘C フォールバックはユーザーのクリップボードを一時的に壊すので、`changeCount` で新しい内容を取ったあと**必ず元の内容を書き戻す**。

**自由入力プロンプト**は、リングの絞り込み入力をそのまま流用する（項目に「自由入力」フラグを立て、`filter` の文字列をプロンプトとして渡す）。余分な入力窓を出さずに済む。

---

## 3. 出力・実行中の見せ方

既存の `ResultSink` をそのまま使う（クリップボード / その場ペースト / HUD）。

ストリーミング中は HUD に流し込む。`HaloHUD` に `update(body:)` を足すだけで済む。長文は HUD に収まらないので、全文はクリップボードへ入れて HUD には先頭のみ出す。

---

## 4. キャンセル・タイムアウト・失敗

- 実行中の `Task` を保持し、Esc とメニューバーからキャンセル。`URLSession` は `Task.cancel()` で中断される。
- `URLSessionConfiguration.timeoutIntervalForRequest = 30`
- 失敗は `HaloNotifier.failure`（HUD 橙・4 秒）。ステータスコードを日本語の対処に翻訳する。

---

## 5. キーの扱いとプライバシー

- Keychain（`Security`）に保存。`kSecAttrAccessible` に `kSecAttrAccessibleAfterFirstUnlock` を追加する。
- config.json とログには**絶対に書かない**（現状維持）。
- 既定は AI 無効のまま。
- **クラウドのプロバイダを選んだときだけ**、何が送信されるかを設定画面に明示する。
- 「送信前に内容を確認」オプションを用意する（初回のみ／常時）。
- Apple オンデバイスを選んだときは「端末外に出ません」と明示する。

---

## 6. 既定の AI リング

| 項目 | 入力 | 出力 |
|---|---|---|
| 日本語へ翻訳 | 選択テキスト | その場にペースト |
| 英語へ翻訳 | 選択テキスト | その場にペースト |
| 要約 | 選択テキスト | クリップボード |
| 文章を整える | 選択テキスト | その場にペースト |
| 丁寧にする | 選択テキスト | その場にペースト |
| コードを説明 | 選択テキスト | HUD |
| 正規表現を作る | 自由入力 | クリップボード |
| 自由入力 | 打った文字列 | クリップボード |

AI が無効なあいだはリング自体を隠す（空のリングを summon して beep するのを避ける）。

---

## 7. ファイル構成

```
Core/AI/
├── AIService.swift              登録・プロンプト展開・キー解決（既存を整理）
├── AIRun.swift                  実行の状態機械（キャンセル・リトライ・ストリーミング）
├── AppleOnDeviceProvider.swift  FoundationModels（新規）
├── AnthropicProvider.swift      既存を分離＋ストリーミング
└── OpenAICompatibleProvider.swift  新規
```

`Model/DefaultConfig.swift` に AI リングを追加。`UI/Preferences/AIPane.swift` にプロバイダ選択・**疎通テストボタン**・送信確認トグルを追加。

---

## 8. テスト方針

ネットワークを叩かずに検証する。`URLProtocol` のスタブを差した `URLSession` をプロバイダに注入し、次を確認する。

- 正常応答のテキスト抽出
- 401 / 429 / 5xx がそれぞれ想定のエラーに変換されること
- 壊れた JSON で落ちないこと
- SSE がチャンク境界をまたいでも正しく連結されること
- 429 と 5xx のみリトライし、401 はリトライしないこと
- プロンプト展開（`{input}` あり / なし）

Apple オンデバイスは availability の分岐のみ（この Mac では実モデルが無効なため）。

---

## 9. 段取り

1. プロバイダ層の整理＋`URLProtocol` テスト基盤
2. Apple オンデバイスプロバイダ — キー不要なので**最初に通しで動く**
3. Anthropic のストリーミングとエラー翻訳
4. 選択テキストの ⌘C フォールバック
5. 既定 AI リング＋設定画面（疎通テスト・送信確認）
6. OpenAI 互換プロバイダ

---

## 10. 確認したいこと

1. **クラウドを使うか、オンデバイスだけにするか。** オンデバイスのみなら 3・6 を落とせて、キー管理と送信確認の UI も要らなくなる。
2. **Anthropic の API キーはあるか。** なければ実リクエストでの検証ができないので、スタブテストまでで止めることになる。
3. **この Mac の Apple Intelligence を有効にできるか。** 現在 `appleIntelligenceNotEnabled` で、有効化してもらえればオンデバイス経路を実機で通しで確認できる。
