;;; leetcode-anki-agent-shell-tests.el --- Agent shell layouts -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode-anki)
(require 'leetcode-tabs-tests)

(ert-deftest leetcode-anki-agent-shell-reuses-exact-directory-and-keeps-layout ()
  (leetcode-tabs-test--with-workspace
    (let* ((directory (make-temp-file "leetcode-agent-" t))
           (shell (generate-new-buffer " *leetcode-same-agent*"))
           (unrelated (generate-new-buffer " *leetcode-other-agent*"))
           (leetcode-anki-agent-shell-config 'same)
           (selected (selected-window))
           (right (get-buffer-window other)))
      (unwind-protect
          (progn
            (with-current-buffer source
              (setq default-directory (file-name-as-directory directory)))
            (with-current-buffer shell
              (setq default-directory (file-name-as-directory directory)))
            (with-current-buffer unrelated (setq default-directory "/"))
            (cl-letf (((symbol-function 'require)
                       (lambda (feature &rest _) (should (eq feature 'agent-shell)) t))
                      ((symbol-function 'agent-shell-buffers) (lambda () (list unrelated shell)))
                      ((symbol-function 'agent-shell-new-shell)
                       (lambda () (ert-fail "Existing same-directory shell must be reused"))))
              (leetcode-anki--setup-agent-shell source)
              (should (eq (selected-window) selected))
              (should (eq (window-buffer right) other))
              (let ((window (get-buffer-window shell)))
                (should window)
                (should (= (window-total-width window) (window-total-width selected)))
                (should (> (nth 1 (window-edges window))
                           (nth 1 (window-edges selected)))))))
        (delete-directory directory t)))))

(ert-deftest leetcode-anki-agent-shell-new-and-same-without-match-create-locally ()
  (dolist (policy '(new same))
    (leetcode-tabs-test--with-workspace
      (let* ((directory (make-temp-file "leetcode-agent-" t))
             (existing (generate-new-buffer " *leetcode-old-agent*"))
             (created nil) (shells (list existing))
             (leetcode-anki-agent-shell-config policy))
        (unwind-protect
            (progn
              (with-current-buffer source
                (setq default-directory (file-name-as-directory directory)))
              (with-current-buffer existing
                (setq default-directory (if (eq policy 'new)
                                            (file-name-as-directory directory) "/")))
              (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                        ((symbol-function 'agent-shell-buffers) (lambda () shells))
                        ((symbol-function 'agent-shell-new-shell)
                         (lambda ()
                           (should (file-equal-p default-directory directory))
                           (should (equal (funcall agent-shell-cwd-function) default-directory))
                           (should-not agent-shell-context-sources)
                           (should (eq agent-shell-session-strategy 'new))
                           (setq created (generate-new-buffer " *leetcode-new-agent*"))
                           (with-current-buffer created
                             (setq default-directory (file-name-as-directory directory)))
                           (push created shells)
                           ;; Exercise the same display action used by real agent-shell.
                           (display-buffer created agent-shell-display-action))))
                (leetcode-anki--setup-agent-shell source)
                (should created)
                (should (get-buffer-window created))
                (should (eq (window-buffer (selected-window)) source))
                (should (= (length (window-list)) 3))))
          (delete-directory directory t))))))

(ert-deftest leetcode-anki-agent-shell-disabled-and-startup-failure ()
  (leetcode-tabs-test--with-workspace
    (let ((leetcode-anki-agent-shell-config nil))
      (cl-letf (((symbol-function 'require)
                 (lambda (&rest _) (ert-fail "Disabled integration must not load agent-shell"))))
        (leetcode-anki--setup-agent-shell source))
      (should (= (length (window-list)) 2)))
    (let ((leetcode-anki-agent-shell-config 'new))
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'agent-shell-buffers) (lambda () nil))
                ((symbol-function 'agent-shell-new-shell)
                 (lambda () (error "Agent executable unavailable"))))
        (leetcode-anki--setup-agent-shell source)
        (should (eq (window-buffer (selected-window)) source))
        (should (= (length (window-list)) 2))))))

;;; leetcode-anki-agent-shell-tests.el ends here
