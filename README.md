# Floating AI

Small, floating AI chat windows for your Mac. Keep conversations beside your work, ask questions, search the web, and discuss images or documents using Codex or Claude.

**Version 0.3.3 · macOS 13 or later · Intel and Apple Silicon**

## 1. Install a chat provider

You need an internet connection and an account with access to Codex or Claude Code. Install **one or both** of the command-line tools below. Run the commands in **Terminal**.

Use the versions shown here for compatibility with this release. If you already have a compatible CLI installed and signed in, skip to step 2.

### Codex

Install Codex **0.163.0** and sign in with your ChatGPT account:

```sh
curl -fsSL https://raw.githubusercontent.com/openai/codex/main/scripts/install/install.sh \
  | sh -s -- --release 0.163.0
"$HOME/.local/bin/codex" --version
"$HOME/.local/bin/codex" login
```

If you prefer an OpenAI API key, skip `codex login` and add the key in Floating AI's Settings instead. API usage is billed separately from a ChatGPT subscription. See the [Codex installation guide](https://developers.openai.com/codex/cli) and [sign-in options](https://learn.chatgpt.com/docs/auth).

### Claude

Install Claude Code **2.1.307** and follow the browser sign-in prompts:

```sh
curl -fsSL https://claude.ai/install.sh | bash -s 2.1.307
"$HOME/.local/bin/claude" --version
"$HOME/.local/bin/claude" auth login
```

Claude may update automatically. If Floating AI later reports an unsupported version, update Floating AI or rerun the installation command above. See the [Claude Code installation guide](https://code.claude.com/docs/en/setup#install-a-specific-version).

These installers do not require Node.js or Homebrew.

## 2. Open Floating AI

Download the [universal ZIP](dist/Floating-AI-macOS-universal.zip) and unzip it, or use the files in this project's root folder. Choose either way to open the app:

- **Double-click:** open `./Floating AI.app` in Finder.
- **Terminal:** run `./floating_ai` from the same folder.

To use **`floating_ai` from any folder**, run this once from the folder containing the app and launcher:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/floating_ai" "$HOME/.local/bin/floating_ai"
```

Then launch it with:

```sh
floating_ai
```

If Terminal says `command not found`, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and open a new Terminal window. Keep the app and launcher together; if you move their folder, recreate the command link.

Look for the note icon in the **menu bar**. The app has no Dock icon.

The app is not notarized by Apple. If macOS blocks it, and you trust your download, follow [Apple's instructions](https://support.apple.com/en-us/102445) to allow it in **System Settings → Privacy & Security → Open Anyway**.

## 3. Connect and start chatting

Open **Settings** from the menu-bar icon:

- **Codex:** click **Use Local Codex** and select **Use Codex Sign-In**. If needed, click **Sign In to ChatGPT**. For an API key, select **OpenAI API Key**, enter your key, and click **Save & Connect**.
- **Claude:** click **Use Local Claude**. If needed, click **Sign In to Claude**, finish signing in through Terminal, then click **Reconnect**.

You can connect both providers. Choose **New Note…** from the menu bar, pick a model, give the note a title, and start chatting. Leave the reasoning setting at its default if you are unsure.

## Everyday controls

| Action | How |
| --- | --- |
| Send a message | **Enter** |
| Add a new line | **Shift+Enter** |
| Undo / redo draft edits | **⌘Z** / **⇧⌘Z** |
| Expand or collapse a note | Click its title; **Esc** also collapses it |
| Rename a note | Double-click its title |
| Move a note | Drag its title bar |
| Resize | Drag the window edges; drag the bar above the message box to resize the input area |
| Hide a note | Click **−**; reopen it from the menu bar |
| Manage multiple notes | Menu bar → **Manage Notes…** |
| Delete a note | Click **×** and confirm |

Undo applies to the current draft; it does not unsend messages. Deleting a note permanently removes it and its local conversation history. Hiding a note keeps its contents.

Notes save automatically. You can change the model and reasoning setting between messages, or stop a reply while it is generating.

To keep notes open when you click elsewhere, enable **Keep Notes Expanded** in **Settings**. This applies to all notes and is remembered between launches. You can still click a note's title or press **Esc** to collapse it.

Math formulas render automatically: use `$...$` or `\(...\)` inline, and `$$...$$` or `\[...\]` for a separate equation. Rendering works offline, including in saved conversations. Use **Copy message** to copy the original LaTeX; code blocks stay as code. No TeX installation is needed. Unsupported formulas remain readable as source.

## Images and documents

Paste an image, drag files onto a note, or click **Add Files…**. Supported formats include **PDF, DOCX, XLSX, text files, and images**. For a scanned PDF, ask about a specific page.

- Up to **20 attachments per message**, **100 MiB per file**, and **40 megapixels per image**.
- **Note Files** lets you reuse files already added to that note.
- Attachments are copied into the note, so moving the original file will not break the conversation.
- Removing an attachment from a draft keeps it in **Note Files**.

No separate PDF reader, Microsoft Office, or Python installation is needed.

## Privacy and troubleshooting

Notes and attachment copies are stored on your Mac. Messages and attachment content used to answer your questions are sent to the selected AI provider. An OpenAI API key entered in Settings is stored in macOS Keychain.

- **CLI not found:** click **Use Local Codex** or **Use Local Claude** in Settings. If needed, enter the executable's full path in the corresponding **CLI Path** field and reconnect. The installers above place them in `~/.local/bin`.
- **Unsupported version:** use Codex **0.163.x** or Claude Code **2.1.307** with this release.
- **Connection lost:** click **Reconnect** in Settings and check the conversation before resending. Messages are never resent automatically.
- **Message was not sent:** your draft is kept. Resolve the displayed storage error, then try again.
- **Installed a newer Floating AI:** quit the running app and reopen the new version.

For developers: build requirements and test results are in the [validation notes](docs/VALIDATION.md).

Floating AI is an independent project and is not affiliated with OpenAI or Anthropic.
