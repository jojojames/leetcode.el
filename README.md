[![MELPA](https://melpa.org/packages/leetcode-badge.svg)](https://melpa.org/#/leetcode)
# Introduction

LeetCode brings you offer, and now Emacs brings you LeetCode!

# Usage

## Solve in Emacs, submit in the browser

This workflow works with browser extensions such as Leetcode Anki:

1. Select a problem in your browser and copy its URL.
2. Run `M-x leetcode-setup-from-url`. A valid problem URL on the clipboard
   starts the workflow immediately; otherwise you are prompted. If the
   clipboard is empty or unavailable, the latest kill is used when valid.
   No problems-list setup is needed.
   New solving workspaces open in named Emacs tabs by default, preserving
   the previous workspace. Set `leetcode-open-problem-in-new-tab` to nil
   to keep using the current tab. Description previews stay in place.
3. Edit the starter code and example test inputs in Emacs. Use `C-c C-t`
   (`leetcode-try`) to run the inputs on LeetCode and view results in Emacs.
   Remote testing uses the client's existing LeetCode login/cookie setup;
   this is not a local Python test runner.
   Testing and submitting preserve your window arrangement, reusing the
   result window if visible. Use `C-c C-r` to restore the standard layout.
4. Use `C-c C-b` (`leetcode-return-to-browser`) to copy the submission code
   and open the problem. Paste, submit, and rate your recall in the browser.
   `C-c C-w` (`leetcode-copy-solution`) copies code without opening a browser.

Every URL setup starts a fresh attempt. Existing solution code is preserved
in a separate buffer named `... attempt TIMESTAMP`; save it if you want to
retain it across Emacs sessions. Existing solution files are not overwritten
until you save the fresh solution. Example inputs reset for the new attempt.

`leetcode-browser-function` defaults to `browse-url`. Customize it to open
the browser/profile where your review extension is installed. Submit in that
browser so the extension can observe the Accepted verdict.

## Review an Anki deck from Emacs

See [the Anki integration guide](anki/README.md) for installation, deck setup,
Emacs review commands, and the optional scheduling add-on.

## Browse problems in Emacs

![screencast](images/screencast.gif)

1. Execute `leetcode` command, and in problem list buffer:

| Keymap              | Description                              |
|---------------------|------------------------------------------|
| o                   | show current problem                     |
| O                   | show problem by prompting problem id     |
| v                   | view the current problem                 |
| V                   | view a problem by prompting problem id   |
| b                   | show the current problem in browser      |
| B                   | show a problem by  problem id in browser |
| c                   | start coding the current problem         |
| C                   | start coding a problem by problem id     |
| s                   | filter problems by regex                 |
| t                   | filter problems by tag                   |
| T                   | toggle tag display                       |
| d                   | filter problems by difficulty            |
| r                   | reset filters                            |
| P                   | toggle paid problems display             |
| g (z for evil-mode) | refresh without fetching from LeetCode   |
| G (Z for evil-mode) | refresh all problems                     |
| L                   | change prefer language                   |
| RET                 | show current problem                     |
| TAB                 | view current problem                     |

2. Press `<RET>`, show problem detail, move cursor to "solve it", press `<RET>` again, start coding!

3. After finishing your code, you can edit testcase and execute `leetcode-try` or execute `leetcode-submit`.

![leetcode-submit](images/leetcode-submit.png)


In `leetcode-solution-mode`, you will have:

| Keymap  | Description            |
|---------|------------------------|
| C-c C-t | run code with testcase |
| C-c C-s | submit                 |
| C-c C-r | restore window layout  |

You can also disable IDE-like features by adding hook to `leetcode-solution-mode-hook`:

``` elisp
(add-hook 'leetcode-solution-mode-hook
          (lambda() (flycheck-mode -1)))
```

# Installation

- Vanilla Emacs: `package-install` it from melpa directly
- [Spacemacs](https://github.com/syl20bnr/spacemacs):
  [leetcode-emacs-layer](https://github.com/anmoljagetia/leetcode-emacs-layer)

LeetCode do not allow third party login, one workaround is restore LeetCode session from local Firefox or Chrome cookies. By default, this package will install a Python3 package called [my\_cookies](https://github.com/kaiwk/my_cookies), or you can install it manually: `pip3 install my_cookies`.

Since we are using [shr.el](https://www.emacswiki.org/emacs/HtmlRendering) to render HTML, you may also want to look at [shrface](https://github.com/chenyanming/shrface).

## Manually

1. Clone this repository and install all dependencies
2. Move it to your load-path
3. Require it in your emacs config

# Configuration

You can set your preferred LeetCode programming language and SQL by setting `leetcode-prefer-language` and `leetcode-prefer-sql`:

If you prefer not to see problems' tags in the `*leetcode**`buffer by default. set `leetcode-prefer-tag-display` to nil

```elisp
(setq leetcode-prefer-language "python3")
(setq leetcode-prefer-sql "mysql")
```

All supported languages can be found in variable `leetcode--lang-suffixes`.

Solution buffers visit files in `leetcode-directory` by default. Save with
`C-x C-s`; files are named `<problem-id>_<problem-slug>_YYYY-MM-DD.<extension>`.
The date uses your local timezone. Reviews on different days keep separate
files; attempts on the same day reuse that day's file.
The directory and any missing parents are created automatically. Customize
the location, or set `leetcode-save-solutions` to nil for scratch buffers:

```elisp
(setq leetcode-save-solutions t)
(setq leetcode-directory "~/leetcode")
```

Saving a solution also runs its current test inputs through `leetcode-try`
by default, just like `C-c C-t`. This runs remotely on LeetCode and uses
the existing login setup. Solution buffers disable automatic saving,
including `auto-save-visited-mode`, so idle autosaves cannot trigger tests.
It does not submit the solution. To turn testing on save off:

```elisp
(setq leetcode-run-on-save nil)
```

# Work with Org Mode

`leetcode-show-problem-by-slug` will let you put to org files with a link in this format to show the question after the *leetcode* buffer is load like [elisp:(leetcode-show-problem-by-slug (leetcode--slugify-title "ZigZag Conversion"))]

# Debug

Call `leetcode-toggle-debug`, log will output in `*leetcode-log*` buffer.
