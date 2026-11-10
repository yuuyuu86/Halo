# 配布手順

`Scripts/release.sh` がユニバーサルバイナリのビルド・署名・公証・DMG 作成をまとめて行います。
**署名と公証には Apple Developer アカウントが必要**なので、その部分だけは手元で実行してください。

---

## 1. 何もしない場合

```bash
./Scripts/release.sh
```

ユニバーサル（arm64 + x86_64）の `build/Halo.app` と `build/Halo-0.1.0.dmg` ができます。
署名はアドホックなので、**自分の Mac では動きますが、他の Mac では Gatekeeper に止められます**。

---

## 2. 配布用に署名する

### 必要なもの

- Apple Developer Program のメンバーシップ（年額）
- **Developer ID Application** 証明書

証明書は Xcode の Settings → Accounts → Manage Certificates → `+` → Developer ID Application
から作成できます。作成後、識別名を確認します。

```bash
security find-identity -v -p codesigning
```

`Developer ID Application: Your Name (TEAM_ID)` の行が目的のものです。

### 公証用の資格情報を Keychain に保存する

App Store Connect で**App 用パスワード**を作成し（appleid.apple.com → サインインとセキュリティ →
App 用パスワード）、`notarytool` に登録します。

```bash
xcrun notarytool store-credentials "halo-notary" --apple-id "you@example.com" --team-id "TEAM_ID"
```

パスワードを聞かれたら App 用パスワードを入力します。以降 `--keychain-profile halo-notary` で使えます。

### 実行

```bash
export HALO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
export HALO_NOTARY_PROFILE="halo-notary"
./Scripts/release.sh
```

公証は数分かかります。完了すると DMG と .app の両方にステープルされ、
`spctl` での検証結果が表示されます。

---

## 3. 確認

配布前に、**ビルドしていない Mac で**次を確認してください。

```bash
spctl --assess --type execute --verbose=2 /Applications/Halo.app
```

`accepted` かつ `source=Notarized Developer ID` になっていれば、
ダウンロードしたユーザーが警告なしで起動できます。

---

## 注意点

### ハードened ランタイム

公証にはハードンドランタイムが必須です。`release.sh` は `--options runtime` を付けています。
Halo はシェルスクリプトと `osascript` を子プロセスとして起動しますが、これは制限に触れません。

### 権限のリセット

署名の identity が変わると、macOS はアクセシビリティ権限を**別のアプリとして扱います**。
アドホック署名から Developer ID に切り替えたときは、
システム設定 → プライバシーとセキュリティ → アクセシビリティ で古い Halo を削除し、
新しいものを追加し直してください。

### サンドボックス

Halo は意図的に非サンドボックスです。任意のアプリを起動し、ユーザーのシェルスクリプトを実行し、
他のアプリを操作するため、サンドボックス下では成立しません。App Store 配布は想定していません。

### 自動更新

未実装です。導入する場合は Sparkle が定番ですが、appcast を置く HTTPS の配信先と
EdDSA 署名鍵の管理が別途必要になります。現状は DMG を差し替える運用を想定しています。
