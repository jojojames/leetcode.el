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
| Solution directory | `~/Code/leetcode` |
| Problem workspaces | New named Emacs tab per problem |
| Tests | Remote LeetCode tests after manual saves |
| Anki | macOS Anki 26.9.3 with its current scheduler (SM-2 or FSRS) |
| API | AnkiConnect API v6, `http://127.0.0.1:8765` |
| Deck source | https://github.com/jojojames/leetcode-neetcode-anki |
| Deck repository | `~/Code/leetcode-neetcode-anki` |
| Study deck | `LeetCode::NeetCode150`, including topic subdecks |
| New problems per day | 1 |
| Review limit per day | 200 |

The current setup is tested with Anki 26.9.3. The Emacs client uses
AnkiConnect's reviewer API v6. The bundled add-on supports both current
Anki/FSRS and the earlier 2.1.33 Python v2 scheduler.

### 1. Load the Emacs integration

Both Lisp files live in this repository. Install the client fork, then
load its companion without requesting a separate archive package:

```elisp
(use-package leetcode
  :vc (:url "https://github.com/jojojames/leetcode.el" :rev :newest)
  :demand t
  :custom
  (leetcode-prefer-language "python3")
  (leetcode-directory "~/Code/leetcode")
  (leetcode-save-solutions t)
  (leetcode-run-on-save t)
  (leetcode-open-problem-in-new-tab t))

(use-package leetcode-anki
  :ensure nil
  :after leetcode
  :demand t
  :custom
  (leetcode-anki-deck "LeetCode::NeetCode150")
  (leetcode-anki-directory "~/Code/leetcode-neetcode-anki")
  (leetcode-anki-agent-shell-config 'same))
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

Use a current AnkiConnect build compatible with your Anki version. The
2021 AnkiConnect used with 2.1.33 imports PyQt5 and cannot run on current
Qt6-based Anki. Use Anki's add-on update command or install the current
[official source](https://git.sr.ht/~foosoft/anki-connect) (`plugin/` goes
in the `2055492159` add-on directory). Our 26.9.3 setup is tested with
AnkiConnect commit `62fc13d` from October 20, 2026. Preserve its local
configuration when updating and restart Anki afterward.

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
| Maximum reviews/day | 3 |
| Maximum interval | 100 days |
| Learning steps | 1 day (`1440` minutes) |
| Relearning steps after Again | 1 day (`1440` minutes) |
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

| Initial rating | Next review |
| --- | --- |
| Again | 1 day, using the preset’s native learning/relearning step |
| Hard | 3 days |
| Good | 4 days |
| Easy | 5 days |

Hard, Good, or Easy graduates a new problem into the review queue.
Subsequent reviews use this interval ladder (days between appearances):

**3 → 4 → 5 → 7 → 10 → 14 → 18 → 24 → 30 → 40 → 50 → 65 → 80 → 100**

Hard holds the current interval, bounded by 3 and 100 days. Good chooses
one strictly greater step; Easy chooses two, stopping at the maximum.
Existing off-ladder intervals advance to the next greater steps. Late
reviews use the scheduled interval without a lateness bonus. Again uses
native relearning with a one-day delay; the next successful rating restarts
at 3 days.
Existing due dates remain unchanged until a card is next rated.

The add-on changes native passing answer states before displaying or
recording them, so Anki, Emacs, and review history agree on the interval.
It keeps each rating's predicted FSRS memory state, lapse count, ease,
and native undo. Native ease multipliers do not control ladder intervals.
Other decks and ordinary filtered decks retain native scheduling; the
add-on's LeetCode Random deck uses the same ladder. On the older 2.1.33
scheduler, a compatibility path records the native rating and explicitly
reschedules the card; that legacy path retains the original native
interval in review history.

Without this add-on, `leetcode-anki.el` still works and uses Anki's native
intervals throughout, except that force-next requires its API bridge.
Set the add-on's `days` configuration to `{}` to keep the bridge while
using native intervals throughout. Disable the add-on in Anki and restart
to remove both features. Existing due dates stay as previously scheduled.

### Updating intervals with Codex

Make scheduling changes in this Git repository first, then install the
updated add-on into Anki. The installed `addons21/leetcode_intervals/`
directory is a runtime copy, not a Git checkout. Editing only that copy
leaves changes untracked and a later installation can overwrite them.

The source files are:

- [config.json](leetcode_intervals/config.json): starting delays (`days`,
  where `2` = Hard, `3` = Good, and `4` = Easy), plus any interval ladder
  supported by the implementation.
- [__init__.py](leetcode_intervals/__init__.py): scheduling rules, including
  whether graduated reviews use native growth or a custom ladder.
- [config.md](leetcode_intervals/config.md): configuration help displayed
  by Anki. Keep this and the scheduling description above in sync.

Changing starting delays alone does not change graduated review growth.
A custom ladder requires Python support as well as configuration. Do not
assume that adding an `intervals` key to an older add-on enables it.

For example, open this repository in Codex and ask:

> Update the Anki add-on source under `anki/leetcode_intervals`. Use initial
> Hard/Good/Easy delays of 3/4/5 days and the interval ladder
> 3, 4, 5, 7, 10, 14, 18, 24, 30, 40, 50, 65, 80, 100 days. For graduated
> reviews, Hard holds the current interval, Good advances to the next
> greater step, and Easy advances to the second greater step, capped at
> 100 days. Again uses native relearning, then a successful relearning
> answer restarts at 3 days. Handle existing off-ladder intervals and
> preserve other decks, native undo, and the AnkiConnect bridges. Update
> the scheduling tests, configuration help, and README; run the tests.
> Compare the installed copy before replacing it so local changes are
> preserved. Install the tested source and tell me to restart Anki.
> Set the NeetCode150 preset to 3 reviews/day, 1 new/day, and a 100-day
> maximum using Anki's supported interface. Preserve unrelated Git changes
> and show me the diff before committing.

After reviewing and testing source changes, copy the three source files
into the installed directory:

```sh
cp anki/leetcode_intervals/{__init__.py,config.json,config.md} \
  "$HOME/Library/Application Support/Anki2/addons21/leetcode_intervals/"
```

Restart Anki to load Python changes. Check the effective configuration in
**Tools → Add-ons → select the add-on → Config**: Anki can retain user
configuration separately from `config.json`, so update saved overrides to
match. Confirm the interval labels on the next due card in Anki or Emacs
without rating a card merely to test it. Existing due dates are preserved;
new intervals apply when cards are next rated.

Daily limits and Anki's native maximum interval live in the deck preset,
not these source files. Set them in the deck's **Options** (or through its
supported API); committing the add-on does not save those database settings.
Same-day learning retries can exceed the review-card limit. A low daily
limit defers excess due cards rather than changing their scheduled dates.

Review `git diff` and commit the relevant source, tests, and documentation
in this repository. Keep unrelated changes out of the commit. The installed
Anki copy does not need its own Git repository.

## Daily workflow

1. Run `M-x leetcode-anki-start` to start the configured deck. Anki chooses
   the card and Emacs creates its problem workspace in a new tab.
2. Edit the file in `~/Code/leetcode`. Save to run examples, or use `C-c C-t`.
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

Solution files include the local date, for example
`746_min-cost-climbing-stairs_2026-10-24.py`. A review on another day opens
a separate file, preserving previous days' solutions. Same-day attempts
reuse the same file; URL setup still preserves replaced code in an attempt
buffer until you explicitly save or discard that buffer.

When Anki reports no cards ready because you reached today's new-card
limit, run **`M-x leetcode-anki-next-force`** to unlock one extra new
problem. With `C-u 3 M-x leetcode-anki-next-force`, unlock three instead.
This uses the same scheduler operation as Anki's Custom Study action to
increase today's new-card allowance, including parent/subdeck limits.
The permanent daily preset stays at one, tomorrow's allowance is unchanged,
and Anki still selects the next problem. No card is created or rated by
this command. It introduces existing, unstudied cards from the imported deck.

An available card or unfinished attempt is opened/resumed normally without
raising the allowance. Loading or uncertain ratings must be resolved first.
If there are no unstudied cards left, the command reports that without
extending the allowance. Force-next does not pull future reviews forward
or raise the review-card daily limit. Update the installed add-on copy and
restart Anki if the command reports an unsupported API action.

Use **`M-x leetcode-anki-next-force-random`** for the random version of
`leetcode-anki-next-force`: choose a random topic, then a random unstudied
problem, instead of taking the next card in deck order. It extends today's
allowance by one and uses the same submission-result hook, recall prompt,
starting intervals, and future review scheduling. Permanent daily limits
are unchanged. An unfinished attempt is resumed rather than replaced.
**`C-u M-x leetcode-anki-next-force-random`** lets you choose a deck or subdeck.

The current Anki add-on uses a one-card native filtered deck named
**LeetCode Random** to select that exact card outside the ordered queue,
with rescheduling enabled. This is an implementation detail; rate the
problem normally. Cards return to their original topic deck, including
Again answers with their short learning delay. Other filtered decks retain
native behavior. The command requires current Anki and the updated bundled
add-on. No cards are rated automatically.

Saving, testing, revealing the answer, and failed submissions never rate
a card. Only an explicit rating advances its review. The integration
checks both the Anki card ID and the solution attempt identity, and prevents
repeated submissions from rating the same attempt twice. If a rating loses
its API connection, its outcome is uncertain and it is not automatically
retried; check Anki before starting another attempt.

## Agent shell alongside a problem

`leetcode-anki-agent-shell-config` controls the optional integration when a
new problem workspace opens. Install `agent-shell` in Emacs and configure
the agents you want to use. The default is `same`:

| Value | Behavior |
| --- | --- |
| `same` | Reuse the most recently visited shell whose working directory matches the solution directory; start one if none exists |
| `new` | Start a new shell for every problem |
| `nil` | Disable the integration |

Matching uses the solution's directory (`~/Code/leetcode` in this setup),
including equivalent symlink paths. A shell from `~/.emacs.d` or another
project is not reused. New shells use `agent-shell-new-shell`, with the
solution directory as their working directory and a fresh session. Agent
selection follows that command's preferred-agent/selection behavior.

The workspace keeps code above the agent shell on the left (51% width), with
the description, test inputs, and results on the right (49%). Focus stays in the code
buffer. No question, solution, or prompt is sent automatically. Startup
failure or cancellation leaves the Anki problem usable. Resuming an
unfinished attempt does not start another shell.

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
  override and the `leetcodeExtendNewCards` AnkiConnect bridge used by
  force-next. Installing it is independent of loading the Emacs code.

## Verifying scheduler compatibility

The legacy unit tests run without Anki. The current-scheduler tests use
real temporary Anki collections, including due dates, review history,
growing intervals, FSRS memory/relearning, and daily-limit extensions.
They never open your installed profile. With the canonical macOS app:

```sh
python3 -B -m unittest discover -s test -p 'test_anki_intervals.py'
PYTHONPATH=/Applications/Anki.app/Contents/Resources/app_packages \
  python3.13 -B -m unittest discover -s test -p 'test_anki_intervals_modern.py'
```

The Python minor version must match the one bundled with Anki (3.13 for
26.9.3). Run these from the root of the client repository.
