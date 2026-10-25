;;; leetcode-anki.el --- Study LeetCode with Anki's scheduler -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1") (leetcode "0.1.27"))
;; Keywords: learning, tools

;;; Commentary:
;; Anki and its AnkiConnect add-on must be running.  Start with
;; `leetcode-anki-start', solve in Emacs, submit, and explicitly rate recall.
;; Anki's native reviewer selects cards and computes intervals.  No browser
;; extension or Org card-authoring package is required.

;;; Code:

(require 'leetcode)
(require 'url)
(require 'url-http)
(require 'json)
(require 'shr)
(require 'button)

(defvar url-http-response-status)
(defvar url-http-end-of-headers)

(defgroup leetcode-anki nil
  "Study LeetCode problems using Anki."
  :group 'leetcode)

(defcustom leetcode-anki-deck "LeetCode::NeetCode150"
  "Anki deck name to study, including its subdecks.
When nil, offer completion over AnkiConnect's deck list at session start."
  :type '(choice (const :tag "Choose at session start" nil) string)
  :group 'leetcode-anki)

(defcustom leetcode-anki-directory "~/Code/leetcode-neetcode-anki"
  "Repository containing LeetCode.apkg for `leetcode-anki-import-deck'.
This path is independent of the Anki deck name and solution directory."
  :type 'directory
  :group 'leetcode-anki)

(defcustom leetcode-anki-url "http://127.0.0.1:8765"
  "AnkiConnect HTTP endpoint."
  :type 'string
  :group 'leetcode-anki)

(defcustom leetcode-anki-request-timeout 5
  "Maximum seconds to wait for an AnkiConnect request."
  :type 'number
  :group 'leetcode-anki)

(defcustom leetcode-anki-agent-shell-config 'same
  "How to display an agent shell when opening a new Anki problem.
With `same', reuse the most recently visited agent shell whose working
directory matches the solution directory, or start one if none exists.
With `new', always start a new shell.  With nil, do nothing.
Display the shell below the solution, keeping the problem and tests on
the right.  Starting a shell uses `agent-shell-new-shell' and its agent
selection; no prompt or solution is sent to the agent automatically."
  :type '(choice (const :tag "Reuse a shell from the solution directory" same)
                 (const :tag "Start a new shell for each problem" new)
                 (const :tag "Disable agent-shell integration" nil))
  :group 'leetcode-anki)

(defvar agent-shell-display-action)
(defvar agent-shell-cwd-function)
(defvar agent-shell-context-sources)
(defvar agent-shell-session-strategy)
(defvar agent-shell-prefer-viewport-interaction)
(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-new-shell "agent-shell")
(declare-function evil-define-key* "evil-core")

(cl-defstruct (leetcode-anki--session (:constructor leetcode-anki--make-session))
  card-id slug deck buffer (state 'loading) prompt-pending)

(defvar leetcode-anki--active nil
  "Current review session, distinct even when a card is repeated later.")
(defvar leetcode-anki--selected-deck nil
  "Deck selected for the current native Anki reviewer session.")
(defvar-local leetcode-anki--session nil
  "Review session associated with this solution buffer.")
(defvar-local leetcode-anki--problem-tab nil
  "Name of the tab containing this Anki solution's workspace.")
(defvar-local leetcode-anki--view-card nil
  "Anki card displayed in this card-view buffer.")
(defvar-local leetcode-anki--view-revealed nil
  "Whether the answer is revealed in this card-view buffer.")

(defun leetcode-anki--request (action &optional params)
  "Call AnkiConnect ACTION with PARAMS, returning its result.
Signal errors explicitly; never silently treat API errors as empty decks."
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data
          (encode-coding-string
           (json-encode (append `((action . ,action) (version . 6))
                                (when params `((params . ,params))))) 'utf-8))
         (buffer (condition-case err
                     (url-retrieve-synchronously leetcode-anki-url t t
                                                 leetcode-anki-request-timeout)
                   (error (user-error "Cannot reach AnkiConnect; start Anki: %s"
                                      (error-message-string err))))))
    (unless buffer
      (user-error "AnkiConnect timed out; check that Anki is running"))
    (unwind-protect
        (with-current-buffer buffer
          (unless (equal url-http-response-status 200)
            (user-error "AnkiConnect HTTP error: %s" url-http-response-status))
          (goto-char url-http-end-of-headers)
          (let* ((json-object-type 'alist) (json-array-type 'list)
                 (json-false :false) (json-null nil)
                 (response (json-read)))
            (when (alist-get 'error response)
              (user-error "AnkiConnect %s: %s" action (alist-get 'error response)))
            (alist-get 'result response)))
      (kill-buffer buffer))))

(defun leetcode-anki--require-success (action &optional params)
  "Call ACTION with PARAMS and require an affirmative API result."
  (unless (eq t (leetcode-anki--request action params))
    (user-error "AnkiConnect could not complete %s" action)))

(defun leetcode-anki--choose-deck (&optional choose)
  "Resolve the configured deck, prompting when CHOOSE or configuration is nil."
  (let* ((decks (leetcode-anki--request "deckNames"))
         (deck (if (or choose (null leetcode-anki-deck))
                   (completing-read "Anki deck: " decks nil t)
                 leetcode-anki-deck)))
    (unless (member deck decks)
      (user-error "Anki deck %s not found; import the deck or select another" deck))
    deck))

(defun leetcode-anki--current-card ()
  "Return the native reviewer's card, or nil when no card is ready."
  (when (eq t (leetcode-anki--request "guiReviewActive"))
    (leetcode-anki--request "guiCurrentCard")))

(defun leetcode-anki--slug (card)
  "Read and validate the LeetCode slug field in CARD."
  (let ((slug (alist-get 'value (alist-get 'slug (alist-get 'fields card)))))
    (unless (and (stringp slug)
                 (string-match-p "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'" slug))
      (user-error "Anki card has no valid LeetCode slug field"))
    slug))

(defun leetcode-anki--verify (session)
  "Return the current Anki card if it still belongs to SESSION."
  (unless (and (eq session leetcode-anki--active)
               (eq (leetcode-anki--session-state session) 'solving)
               (buffer-live-p (leetcode-anki--session-buffer session))
               (eq (buffer-local-value 'leetcode-anki--session
                                       (leetcode-anki--session-buffer session)) session))
    (user-error "This Anki review is already rated, inactive, or awaiting confirmation"))
  (let ((card (leetcode-anki--current-card)))
    (unless (and card
                 (equal (alist-get 'cardId card) (leetcode-anki--session-card-id session))
                 (equal (alist-get 'deckName card) (leetcode-anki--session-deck session))
                 (equal (leetcode-anki--slug card) (leetcode-anki--session-slug session)))
      (user-error "Anki's current card changed; run leetcode-anki-next before rating"))
    card))

(defun leetcode-anki--observe (promise)
  "Make errors from asynchronous setup PROMISE visible to command users."
  (aio-listen promise
              (lambda (result)
                (condition-case err (funcall result)
                  (error (message "LeetCode Anki setup failed: %s"
                                  (error-message-string err))))))
  promise)

(defun leetcode-anki--resize-solution-column (window)
  "Give WINDOW's code/agent column 51 percent of its horizontal split."
  (let ((column window)
        (parent (window-parent window)))
    ;; Ascend through the code/agent vertical stack to resize both panes.
    (while (and parent
                (= (window-total-width parent) (window-total-width column)))
      (setq column parent
            parent (window-parent parent)))
    (when parent
      (let ((delta (- (round (* 0.51 (window-total-width parent)))
                      (window-total-width column))))
        (unless (zerop delta)
          (window-resize column delta t))))))

(defun leetcode-anki--setup-agent-shell (solution)
  "Display an agent shell below SOLUTION according to the configured policy.
Agent startup errors or cancellation leave the Anki attempt usable."
  (when leetcode-anki-agent-shell-config
    (condition-case err
        (when (require 'agent-shell nil t)
          (let* ((code-window (get-buffer-window solution))
                 (directory (with-current-buffer solution
                              (file-name-as-directory
                               (expand-file-name
                                (if buffer-file-name
                                    (file-name-directory buffer-file-name)
                                  default-directory)))))
                 (before (agent-shell-buffers))
                 (shell (and (eq leetcode-anki-agent-shell-config 'same)
                             (seq-find
                              (lambda (buffer)
                                (and (buffer-live-p buffer)
                                     (file-equal-p
                                      directory
                                      (buffer-local-value 'default-directory buffer))))
                              before)))
                 (shell-window nil)
                 (display
                  (lambda (buffer _alist)
                    (unless (window-live-p code-window)
                      (user-error "The solution window is no longer visible"))
                    (unless (window-live-p shell-window)
                      (setq shell-window (split-window code-window nil 'below)))
                    (set-window-buffer shell-window buffer)
                    (leetcode-anki--resize-solution-column code-window)
                    shell-window)))
            (save-selected-window
              (unless shell
                (with-current-buffer solution
                  (let ((default-directory directory)
                        (agent-shell-cwd-function (lambda () directory))
                        (agent-shell-display-action (list (list display)))
                        (display-buffer-overriding-action (list (list display)))
                        (agent-shell-context-sources nil)
                        (agent-shell-session-strategy 'new)
                        (agent-shell-prefer-viewport-interaction nil))
                    (agent-shell-new-shell)))
                (setq shell
                      (seq-find (lambda (buffer)
                                  (and (not (memq buffer before))
                                       (file-equal-p
                                        directory
                                        (buffer-local-value 'default-directory buffer))))
                                (agent-shell-buffers))))
              (when shell
                (funcall display shell nil)))))
      (quit (message "Agent shell cancelled; the Anki problem is ready"))
      (error (message "Agent shell unavailable; the Anki problem is ready: %s"
                      (error-message-string err))))))

(aio-defun leetcode-anki--open-card (card)
  "Prepare CARD in Emacs and associate the resulting buffer with its review."
  (unless (integerp (alist-get 'cardId card))
    (user-error "Anki returned a card without a numeric card ID"))
  (let* ((slug (leetcode-anki--slug card))
         (session (leetcode-anki--make-session
                   :card-id (alist-get 'cardId card) :slug slug
                   :deck (alist-get 'deckName card))))
    (setq leetcode-anki--active session)
    (condition-case err
        (let ((buffer (aio-await
                       (leetcode-setup-from-url
                        (format "https://leetcode.com/problems/%s/" slug)))))
          (setf (leetcode-anki--session-buffer session) buffer
                (leetcode-anki--session-state session) 'solving)
          (with-current-buffer buffer
            (setq-local leetcode-anki--session session
                        leetcode-anki--problem-tab (alist-get 'name (tab-bar--current-tab)))
            ;; The submission command snapshots this closure before it awaits
            ;; network requests, protecting a later attempt in the same buffer.
            (add-hook 'leetcode-submission-result-hook
                      (lambda (problem result)
                        (leetcode-anki--submission-result session problem result))
                      nil t))
          (leetcode-anki--setup-agent-shell buffer)
          (message "Anki problem ready: %s; submit or M-x leetcode-anki-rate" slug)
          buffer)
      (error
       (setf (leetcode-anki--session-state session) 'failed)
       (signal (car err) (cdr err))))))

(defun leetcode-anki-next ()
  "Open the native Anki reviewer's current card in Emacs.
Resume an unfinished attempt without resetting its code.  After rating,
Anki has already advanced its queue; this opens that next card."
  (interactive)
  (if (null leetcode-anki--selected-deck)
      (leetcode-anki-start)
    (when (and leetcode-anki--active
               (eq (leetcode-anki--session-state leetcode-anki--active) 'loading))
      (user-error "A LeetCode Anki problem is still loading"))
    (let ((card (leetcode-anki--current-card)))
      (if (null card)
          (message "No Anki cards ready in %s; M-x leetcode-anki-next-force for another new problem"
                   leetcode-anki--selected-deck)
        (let ((deck (alist-get 'deckName card)))
          (unless (or (equal deck leetcode-anki--selected-deck)
                      (string-prefix-p (concat leetcode-anki--selected-deck "::") deck))
            (user-error "Anki is reviewing a different deck; run leetcode-anki-start")))
        (if (and leetcode-anki--active
                 (equal (alist-get 'cardId card)
                        (leetcode-anki--session-card-id leetcode-anki--active))
                 (memq (leetcode-anki--session-state leetcode-anki--active) '(solving rating uncertain))
                 (buffer-live-p (leetcode-anki--session-buffer leetcode-anki--active)))
            (progn
              (leetcode-anki--resume-solution
               (leetcode-anki--session-buffer leetcode-anki--active))
              (message "Current Anki attempt resumed; rate recall before advancing"))
          (leetcode-anki--observe (leetcode-anki--open-card card)))))))

;;;###autoload
(defun leetcode-anki-next-force (&optional count)
  "Open another problem, extending today's new-card allowance if needed.
Add COUNT new cards to today's allowance (default 1, or a prefix argument).
Keep the deck's permanent daily limit and native card ordering unchanged.
Requires the bundled Anki add-on's AnkiConnect bridge.  An available card
or unfinished attempt is handled by `leetcode-anki-next' without extending
the allowance.  An uncertain rating must be resolved before continuing."
  (interactive "p")
  (setq count (or count 1))
  (unless (and (integerp count) (> count 0))
    (user-error "The number of extra problems must be a positive integer"))
  (when (and leetcode-anki--active
             (memq (leetcode-anki--session-state leetcode-anki--active)
                   '(loading rating uncertain)))
    (user-error "The current Anki attempt is loading or its rating is awaiting confirmation"))
  (unless leetcode-anki--selected-deck
    (let ((deck (leetcode-anki--choose-deck)))
      (leetcode-anki--require-success "guiDeckReview" `((name . ,deck)))
      (setq leetcode-anki--selected-deck deck)))
  (cond
   ((leetcode-anki--current-card) (leetcode-anki-next))
   ((and leetcode-anki--active
         (eq (leetcode-anki--session-state leetcode-anki--active) 'solving))
    (user-error "The unfinished attempt lost its Anki card; resolve it before forcing another"))
   ((eq t (condition-case err
              (leetcode-anki--request
               "leetcodeExtendNewCards"
               `((deck . ,leetcode-anki--selected-deck) (count . ,count)))
            (error
             (if (string-match-p "unsupported action" (error-message-string err))
                 (user-error "Force-next requires the updated bundled Anki add-on; install it and restart Anki")
               (signal (car err) (cdr err))))))
    (leetcode-anki-next))
   (t (message "No unstudied problems available in %s" leetcode-anki--selected-deck))))

;;;###autoload
(defun leetcode-anki-start (&optional deck)
  "Start reviewing DECK entirely from Emacs.
Use `leetcode-anki-deck' by default, or prompt when it is nil."
  (interactive)
  (when (and leetcode-anki--active
             (eq (leetcode-anki--session-state leetcode-anki--active) 'loading))
    (user-error "A LeetCode Anki problem is still loading"))
  (let ((name (or deck (leetcode-anki--choose-deck))))
    (leetcode-anki--require-success "guiDeckReview" `((name . ,name)))
    (setq leetcode-anki--selected-deck name
          leetcode-anki--active nil)
    (leetcode-anki-next)))

(defun leetcode-anki-select-deck ()
  "Choose a deck from Anki and start its review session."
  (interactive)
  (leetcode-anki-start (leetcode-anki--choose-deck t)))

(defun leetcode-anki--rating-options (card)
  "Return rating labels and numeric answer buttons for CARD."
  (let* ((buttons (alist-get 'buttons card))
         (intervals (alist-get 'nextReviews card))
         (names (pcase (length buttons)
                  (4 '("Again" "Hard" "Good" "Easy"))
                  (3 '("Again" "Good" "Easy"))
                  (2 '("Again" "Good"))
                  (_ (user-error "Unsupported Anki answer buttons: %S" buttons)))))
    (cl-mapcar (lambda (button name interval)
                 (cons (format "%s (%s)" name interval) button))
               buttons names intervals)))

(defun leetcode-anki-rate (&optional ease)
  "Rate recall for the current solution's Anki review.
Prompt with Anki's real intervals unless numeric EASE is supplied.
Choosing Not now, or cancelling, leaves the review unrated."
  (interactive)
  (let* ((session (or leetcode-anki--session leetcode-anki--active))
         (_ (unless session (user-error "Start a review with leetcode-anki-start")))
         (card (leetcode-anki--verify session))
         (options (leetcode-anki--rating-options card))
         (answer (or ease
                     (cdr (assoc (completing-read "Recall: "
                                                  (append (mapcar #'car options) '("Not now"))
                                                  nil t nil nil "Not now")
                                 options)))))
    (when answer
      (unless (memq answer (alist-get 'buttons card))
        (user-error "Anki does not offer that rating for this card"))
      ;; Recheck after the prompt and after revealing the answer, since Anki
      ;; can also be used independently while Emacs is waiting for input.
      (leetcode-anki--verify session)
      (leetcode-anki--require-success "guiShowAnswer")
      (leetcode-anki--verify session)
      (setf (leetcode-anki--session-state session) 'rating)
      (condition-case err
          (if (eq t (leetcode-anki--request "guiAnswerCard" `((ease . ,answer))))
              (progn
                (setf (leetcode-anki--session-state session) 'rated)
                (message "Anki recall recorded; M-x leetcode-anki-next for the next problem")
                t)
            (setf (leetcode-anki--session-state session) 'solving)
            (user-error "Anki declined the rating; the review remains unrated"))
        (error
         (when (eq (leetcode-anki--session-state session) 'rating)
           (setf (leetcode-anki--session-state session) 'uncertain))
         (signal (car err) (cdr err)))))))

(defun leetcode-anki--prompt-after-submission (session)
  "Offer an explicit recall rating for SESSION after an Accepted verdict."
  (if (active-minibuffer-window)
      (run-at-time 0.5 nil #'leetcode-anki--prompt-after-submission session)
    (setf (leetcode-anki--session-prompt-pending session) nil)
    (when (and (eq session leetcode-anki--active)
               (eq (leetcode-anki--session-state session) 'solving)
               (buffer-live-p (leetcode-anki--session-buffer session)))
      (with-current-buffer (leetcode-anki--session-buffer session)
        (condition-case err (leetcode-anki-rate)
          (quit (message "Anki recall left unrated; use leetcode-anki-rate later"))
          (error (message "Anki recall left unrated: %s" (error-message-string err))))))))

(defun leetcode-anki--submission-result (session problem result)
  "Handle a final LeetCode RESULT for PROBLEM associated with SESSION."
  (when (and (eq session leetcode-anki--active)
             (eq (leetcode-anki--session-state session) 'solving)
             (buffer-live-p (leetcode-anki--session-buffer session))
             (eq (buffer-local-value 'leetcode-anki--session
                                     (leetcode-anki--session-buffer session)) session)
             (equal (leetcode-problem-title-slug problem) (leetcode-anki--session-slug session))
             (or (equal (alist-get 'status_code result) 10)
                 (equal (alist-get 'status_msg result) "Accepted"))
             (not (leetcode-anki--session-prompt-pending session)))
    (setf (leetcode-anki--session-prompt-pending session) t)
    (run-at-time 0 nil #'leetcode-anki--prompt-after-submission session)))

(defun leetcode-anki-import-deck ()
  "Import LeetCode.apkg from `leetcode-anki-directory' into running Anki."
  (interactive)
  (let ((file (expand-file-name "LeetCode.apkg" leetcode-anki-directory)))
    (unless (file-readable-p file)
      (user-error "No readable deck package at %s" file))
    (leetcode-anki--require-success "importPackage" `((path . ,file)))
    (message "LeetCode deck imported; start with M-x leetcode-anki-start")))

(defun leetcode-anki--resume-solution (buffer)
  "Select BUFFER's problem tab, if it still exists, then display BUFFER."
  (let ((name (buffer-local-value 'leetcode-anki--problem-tab buffer)))
    (when (and name (seq-some (lambda (tab) (equal name (alist-get 'name tab)))
                              (tab-bar-tabs)))
      (tab-bar-switch-to-tab name)))
  (pop-to-buffer buffer))

(defvar leetcode-anki-card-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'leetcode-anki-view-card)
    (define-key map (kbd "a") #'leetcode-anki-view-answer)
    (define-key map (kbd "r") #'leetcode-anki-rate)
    (define-key map (kbd "n") #'leetcode-anki-next)
    (define-key map (kbd "q") #'tab-bar-close-tab)
    map)
  "Keymap for the rendered Anki card view.")

(define-derived-mode leetcode-anki-card-mode special-mode "LeetCode Anki"
  "View the current Anki card in Emacs.
Use a to reveal the answer, g to refresh, r to rate recall,
n to open or resume the problem, and q to close the view tab."
  :group 'leetcode-anki)

(with-eval-after-load 'evil
  (evil-define-key* 'normal leetcode-anki-card-mode-map
    (kbd "gr") #'leetcode-anki-view-card
    (kbd "a") #'leetcode-anki-view-answer
    (kbd "r") #'leetcode-anki-rate
    (kbd "n") #'leetcode-anki-next
    (kbd "q") #'tab-bar-close-tab))

(defun leetcode-anki--render-card-view ()
  "Render the current buffer's Anki card, revealing the answer on request."
  (let* ((inhibit-read-only t)
         (card leetcode-anki--view-card)
         (session leetcode-anki--session)
         (html (or (alist-get (if leetcode-anki--view-revealed 'answer 'question) card)
                   "<p>No card content available.</p>"))
         (document (with-temp-buffer
                     (insert html)
                     (libxml-parse-html-region (point-min) (point-max)))))
    (erase-buffer)
    (insert (propertize (format "Anki · %s\n" (leetcode-anki--slug card)) 'face 'bold))
    (insert (format "%s\n\n" (alist-get 'deckName card)))
    (let ((shr-inhibit-images t)
          (shr-use-fonts nil))
      (shr-insert-document document))
    (goto-char (point-max))
    (insert "\n\n")
    (unless leetcode-anki--view-revealed
      (insert-text-button "Show answer" 'follow-link t
                          'action (lambda (_) (leetcode-anki-view-answer)))
      (insert "   "))
    (insert-text-button "Open / resume problem" 'follow-link t
                        'action (lambda (_) (leetcode-anki-next)))
    (insert "   ")
    (insert-text-button "Refresh" 'follow-link t
                        'action (lambda (_) (leetcode-anki-view-card)))
    (insert "\n\n")
    (cond
     ((and session (eq (leetcode-anki--session-state session) 'rated))
      (insert "Recall recorded. Use n for the next problem.\n"))
     ((and session (eq session leetcode-anki--active)
           (eq (leetcode-anki--session-state session) 'solving))
      (if (not leetcode-anki--view-revealed)
          (insert "Reveal the answer with a, or use r to rate recall.\n")
        (dolist (option (leetcode-anki--rating-options card))
          (insert-text-button
           (car option) 'follow-link t 'leetcode-anki-ease (cdr option)
           'action (lambda (button)
                     (leetcode-anki--view-rate (button-get button 'leetcode-anki-ease))))
          (insert "   "))
        (insert "\n")))
     (t (insert "Open this problem in Emacs before rating its review.\n")))
    (goto-char (point-min))))

(defun leetcode-anki--view-rate (ease)
  "Record EASE from a card-view button and update the view."
  (unless leetcode-anki--session
    (user-error "This view is not associated with a solution; open the problem first"))
  (leetcode-anki-rate ease)
  (leetcode-anki--render-card-view))

(defun leetcode-anki-view-answer ()
  "Reveal the displayed Anki card's answer without recording a review."
  (interactive)
  (unless (derived-mode-p 'leetcode-anki-card-mode)
    (user-error "Run this command in the Anki card view"))
  (let ((current (leetcode-anki--current-card)))
    (unless (and current (equal (alist-get 'cardId current)
                               (alist-get 'cardId leetcode-anki--view-card)))
      (user-error "Anki's current card changed; refresh the view with g")))
  (setq leetcode-anki--view-revealed t)
  (leetcode-anki--render-card-view))

;;;###autoload
(defun leetcode-anki-view-card ()
  "Render Anki's current problem in a separate, reusable Emacs tab.
Show the question first; a reveals the answer without rating the card.
This renders card HTML with SHR, rather than embedding Anki's application
window.  JavaScript and Anki-specific CSS are not executed."
  (interactive)
  (let ((card (leetcode-anki--current-card))
        (name "Anki: LeetCode")
        (buffer (get-buffer-create "*LeetCode Anki*")))
    (unless card (user-error "No current Anki card; start with leetcode-anki-start"))
    (leetcode-anki--slug card)
    (if (seq-some (lambda (tab) (equal name (alist-get 'name tab))) (tab-bar-tabs))
        (tab-bar-switch-to-tab name)
      (tab-bar-new-tab)
      (tab-bar-rename-tab name))
    (delete-other-windows)
    (switch-to-buffer buffer)
    (leetcode-anki-card-mode)
    (setq-local leetcode-anki--view-card card
                leetcode-anki--view-revealed nil
                leetcode-anki--session
                (and leetcode-anki--active
                     (equal (alist-get 'cardId card)
                            (leetcode-anki--session-card-id leetcode-anki--active))
                     leetcode-anki--active))
    (leetcode-anki--render-card-view)
    buffer))

(provide 'leetcode-anki)
;;; leetcode-anki.el ends here
