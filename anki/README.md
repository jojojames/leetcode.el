# LeetCode reviews with Anki from Emacs

`leetcode-anki.el` drives Anki's native reviewer through AnkiConnect. Anki
selects the next problem using its learning queues, review order, daily
limits, and subdecks. Emacs opens the solution, runs tests, submits it, and
asks you to rate recall. A browser extension and Org authoring package are
not required. Anki must stay running, but review actions happen in Emacs.

## Canonical setup

This guide describes the working setup used to develop this integration:

| Component | Configuration |
| --- | --- |
| Emacs | 31, Evil, and `use-package` with `:vc` |
| Client fork | https://github.com/jojojames/leetcode.el |
| Language | Python 3 (`python3`) |
| Solution directory | `~/leetcode` |
| Problem workspaces | New named Emacs tab per problem |
| Tests | Remote LeetCode tests after manual saves |
| Anki | macOS Anki 2.1.33 with its Python v2 scheduler |
| API | AnkiConnect API v6, `http://127.0.0.1:8765` |
| Deck source | https://github.com/jojojames/leetcode-neetcode-anki |
| Deck repository | `~/Code/leetcode-neetcode-anki` |
| Study deck | `LeetCode::NeetCode150`, including topic subdecks |
| New problems per day | 1 |
| Review limit per day | 200 |

Anki 2.1.33 is the version tested here, not a requirement to downgrade a
newer installation. The Emacs client uses AnkiConnect's reviewer API. The
optional Python scheduling add-on below is specific to the older v2
scheduler and does not support newer Rust/FSRS schedulers.

### 1. Load the Emacs integration

Both Lisp files live in this repository. Install the client fork, then
load its companion without requesting a separate archive package:

```elisp
(use-package leetcode
  :vc (:url "https://github.com/jojojames/leetcode.el" :rev :newest)
  :demand t
  :custom
  (leetcode-prefer-language "python3")
  (leetcode-directory "~/leetcode")
  (leetcode-save-solutions t)
  (leetcode-run-on-save t)
  (leetcode-open-problem-in-new-tab t))

(use-package leetcode-anki
  :ensure nil
  :after leetcode
  :demand t
  :custom
  (leetcode-anki-deck "LeetCode::NeetCode150")
  (leetcode-anki-directory "~/Code/leetcode-neetcode-anki"))
```

Solution buffers disable ordinary autosave and `auto-save-visited-mode`.
Manual saves still trigger tests. Set `leetcode-run-on-save` to nil to run
only explicit tests with `C-c C-t`.

LeetCode requests use the core client's browser-cookie authentication. Our
setup obtains cookies from Google Chrome; log into LeetCode there first and
configure the client's `my_cookies` integration as described in the
[client README](../README.md#installation). AnkiConnect access is independent
of the LeetCode login.

### 2. Import the deck

Install and enable AnkiConnect in Anki (add-on ID `2055492159`). Leave Anki
running with your intended profile open.

```sh
git clone https://github.com/jojojames/leetcode-neetcode-anki \
  ~/Code/leetcode-neetcode-anki
```

Run `M-x leetcode-anki-import-deck` to import `LeetCode.apkg` from that
repository, or import the package through Anki. The package contains many
more problems; selecting `LeetCode::NeetCode150` restricts study to those
150 problems and their topic subdecks. The cards contain a `slug` field,
which the integration converts into a LeetCode problem URL.

`leetcode-anki-directory` is the deck source directory, not an Anki deck
name or a solution directory. Set `leetcode-anki-deck` to nil to choose
from Anki's deck list at session start. `leetcode-anki-select-deck` switches
the selected study deck explicitly.

### 3. Set the deck options

The imported deck's original preset had **0 new cards per day**, which
prevented Anki from selecting a new problem. Our setup uses a separate
preset named **LeetCode NeetCode150** with:

| Option | Value |
| --- | --- |
| New cards/day | 1 |
| Maximum reviews/day | 200 |
| Learning steps | 1 minute, 10 minutes |
| Relearning steps after Again | 1 minute |
| Starting ease | 250% |
| Review Hard multiplier | 1.2 |
| Review Easy bonus | 1.3 |
| Review interval modifier | 100% |

Assign that preset to `LeetCode::NeetCode150` and all its topic subdecks.
The parent `LeetCode` deck must also allow new cards: on this older
scheduler, a parent limit of zero blocks studying its children. Our setup
assigns the same preset to that parent. Unrelated decks keep their own
presets. The scheduling add-on itself only targets NeetCode150.

### 4. Install the optional problem-sized learning intervals

[leetcode_intervals](leetcode_intervals/__init__.py) is a small custom
add-on written in this repository. It is separate from AnkiConnect and is
not an AnkiWeb download. Our setup installs a copy at:

```text
~/Library/Application Support/Anki2/addons21/leetcode_intervals/
```

From the root of the client repository:

```sh
cp -R anki/leetcode_intervals \
  "$HOME/Library/Application Support/Anki2/addons21/"
```

Restart Anki after installing or updating the copy. Configure it through
Anki's add-on configuration dialog. The defaults in
[config.json](leetcode_intervals/config.json) select
`LeetCode::NeetCode150` and all its topic subdecks:

| Rating while learning or relearning | Next review |
| --- | --- |
| Again | Native retry step, about 1 minute with our preset |
| Hard | 2 days |
| Good | 5 days |
| Easy | 10 days |

Hard, Good, or Easy moves the problem into Anki's graduated review queue.
**Subsequent reviews use Anki's native growing intervals**, based on the
card's history and rating. Easy does not mean reviewing every ten days
forever. A lapse returns the card to native relearning, whose next
successful rating uses the starting delays above again.

The add-on changes both interval previews and answer handling, so Anki and
Emacs show the same intervals. It records the native rating first, then
uses Anki's native rescheduling operation to set the learning interval,
preserving the card's existing ease. Review history retains the native
scheduled interval for that learning rating; the actual due date reflects
the override. Graduated review scheduling, other decks, and filtered-deck
reviews retain native behavior.

Without this add-on, `leetcode-anki.el` still works and uses Anki's native
intervals throughout. Disable the add-on in Anki and restart to remove the
override. Existing due dates stay as previously scheduled.

## Daily workflow

1. Run `M-x leetcode-anki-start` to start the configured deck. Anki chooses
   the card and Emacs creates its problem workspace in a new tab.
2. Edit the file in `~/leetcode`. Save to run examples, or use `C-c C-t`.
   These tests run on LeetCode, not in a local Python test runner.
3. Submit with `C-c C-s`. After the final Accepted verdict, Emacs prompts
   for recall with Anki's actual interval choices. Acceptance does not
   choose a rating automatically; account for hints and effort yourself.
4. Choose Again, Hard, Good, or Easy to record the review, or **Not now**
   to defer. Run `M-x leetcode-anki-rate` manually after giving up or after
   a failed submission. Cancelling leaves the review unrated.
5. Run `M-x leetcode-anki-next` to open the next native-selected problem.
   During an unfinished attempt, this resumes the existing solution tab
   without resetting code.

Saving, testing, revealing the answer, and failed submissions never rate
a card. Only an explicit rating advances its review. The integration
checks both the Anki card ID and the solution attempt identity, and prevents
repeated submissions from rating the same attempt twice. If a rating loses
its API connection, its outcome is uncertain and it is not automatically
retried; check Anki before starting another attempt.

## View the current card in Emacs

`M-x leetcode-anki-view-card` opens or refreshes the separate, reusable
**Anki: LeetCode** tab. It renders question/answer HTML using SHR;
Anki-specific CSS and JavaScript are not supported. The answer stays hidden
until revealed. After revealing, rating buttons show actual intervals.

| Action | Standard key | Evil normal-state key |
| --- | --- | --- |
| Refresh | `g` | `gr` |
| Reveal answer | `a` | `a` |
| Rate recall | `r` | `r` |
| Open/resume problem | `n` | `n` |
| Close card tab | `q` | `q` |

The Evil bindings are installed by `leetcode-anki.el` using
`with-eval-after-load`; no Evil local state map is replaced.

## Source boundaries

- `leetcode.el` handles LeetCode requests, solution workspaces, saving,
  tests, submissions, and the generic final-verdict hook.
- `leetcode-anki.el` handles AnkiConnect, review sessions, recall prompts,
  the card view, and its Evil bindings. It attaches an attempt-specific
  buffer-local `leetcode-submission-result-hook`, which runs after the
  final verdict in the originating solution buffer.
- `anki/leetcode_intervals` contains the optional Anki-side scheduling
  override. Installing it is independent of loading the Emacs code.
