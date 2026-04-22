# Previews

Screenshots shown inside the wizard so a new dev sees exactly what each
preset looks like before committing. Images are committed into the repo
and referenced by `raw.githubusercontent.com` URLs (CDN-cached, fast).

## Capturing a fresh `p10k-bundled.png`

1. Open a terminal (iTerm2 on Mac, Windows Terminal on WSL) at fullscreen
   or reasonable size (~1400×900 — enough to show 2 prompt rows clearly).
2. Run the demo helper in this folder to create a rich-state git repo:

   ```bash
   bash assets/previews/setup-demo.sh
   cd /tmp/p10k-demo
   ```

3. Inside the demo repo, trigger a couple of natural commands so the
   prompt shows real-world information:

   ```bash
   ls                        # show the demo files
   git status -sb            # visualize branch + dirty state
   echo 'new' > new-file     # creates an untracked file → prompt updates
   cd src/                   # nested dir → prompt shows truncated path
   git log --oneline -3      # some commit history on screen
   ```

4. Take a screenshot (native OS tool: `⌘+Shift+4` on Mac,
   Win+Shift+S on Windows). Capture from roughly 4 rows above the final
   prompt to the cursor line — shows prompt rendering clearly.
5. Save as `p10k-bundled.png` in this folder. Keep width ≥ 1200 px so
   the preview is readable when embedded.
6. Commit the screenshot:

   ```bash
   cd ~/dotfiles-template
   git add assets/previews/p10k-bundled.png
   git commit -m "assets: capture p10k bundled preview"
   git push
   ```

7. The wizard will reference it as:

   ```
   https://raw.githubusercontent.com/henryavila/dotfiles-template/main/assets/previews/p10k-bundled.png
   ```

## Other previews to add later

As the preset list grows, capture one image per major visual preset so
the wizard can reference a real render:

| Filename | Shows |
|---|---|
| `p10k-bundled.png` | the bundled Powerlevel10k config with a dirty repo |
| `btop-catppuccin.png` | btop running with the Catppuccin Mocha theme |
| `eza-catppuccin.png` | `eza -la --icons --git` output |
| `lazygit-catppuccin.png` | lazygit UI with Catppuccin |
| `nvim-bundled.png` | nvim opening a markdown file with the bundled init.lua |

Each image reused by the wizard when the matching preset comes up.

## URL convention

Raw (direct image, fast, works in terminals that render OSC-8 links):

```
https://raw.githubusercontent.com/<owner>/<repo>/main/assets/previews/<file>.png
```

Blob (GitHub preview page, browser-friendly):

```
https://github.com/<owner>/<repo>/blob/main/assets/previews/<file>.png
```

The wizard prints the blob URL by default — one click opens a clean preview page.
