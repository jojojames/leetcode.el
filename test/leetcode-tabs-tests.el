;;; leetcode-tabs-tests.el --- Core problem workspaces -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)

(defmacro leetcode-tabs-test--with-workspace (&rest body)
  "Run BODY with an isolated tab configuration and two-window workspace."
  (declare (indent 0))
  `(let ((saved-tabs (copy-tree (frame-parameter nil 'tabs)))
         (saved-windows (current-window-configuration))
         (saved-tab-bar-mode tab-bar-mode)
         (tab-bar-show t)
         (initial-buffers (buffer-list))
         (source (generate-new-buffer " *leetcode-tab-source*"))
         (other (generate-new-buffer " *leetcode-tab-other*")))
     (unwind-protect
         (progn
           (tab-bar-mode 1)
           (set-frame-parameter nil 'tabs nil)
           (delete-other-windows)
           (switch-to-buffer source)
           (set-window-buffer (split-window-right) other)
           (tab-bar-rename-tab "Workspace test")
           ,@body)
       (set-frame-parameter nil 'tabs saved-tabs)
       (set-window-configuration saved-windows)
       (tab-bar-mode (if saved-tab-bar-mode 1 -1))
       (dolist (buffer (seq-difference (buffer-list) initial-buffers))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer)))))

(ert-deftest leetcode-tabs-workspace-respects-setting ()
  (dolist (setting '(t nil))
    (leetcode-tabs-test--with-workspace
      (let* ((leetcode-open-problem-in-new-tab setting)
             (leetcode-save-solutions nil)
             (leetcode-prefer-language "python3")
             (leetcode--problem-titles nil)
             (problem (make-leetcode-problem
                       :id "99997" :title "Tab Test" :title-slug "tab-test"
                       :difficulty "Easy" :likes 0 :dislikes 0
                       :content "<p>Keep the original workspace.</p>"
                       :testcases '("1")
                       :snippets (list (make-leetcode-snippet
                                        :lang-slug "python3" :code "class Solution: pass\n"))))
             (leetcode--problems (make-leetcode-problems :problems (list problem)))
             (original (mapcar (lambda (window) (list (window-buffer window) (window-total-width window)))
                               (window-list))))
        (should (buffer-live-p (leetcode--start-coding problem)))
        (should (= (length (tab-bar-tabs)) (if setting 2 1)))
        (when setting
          (should (string-prefix-p "LC 99997:" (alist-get 'name (tab-bar--current-tab))))
          (tab-bar-switch-to-tab "Workspace test")
          (should (equal original
                         (mapcar (lambda (window) (list (window-buffer window) (window-total-width window)))
                                 (window-list)))))))))

(ert-deftest leetcode-tabs-submission-rendering-does-not-rebuild-layout ()
  (leetcode-tabs-test--with-workspace
    (let ((selected (selected-window)))
      (leetcode--show-run-result #'leetcode--show-submission-result "99996"
                                 '((status_code . 13) (status_msg . "Output Limit Exceeded")))
      (should (eq selected (selected-window)))
      (should (eq (window-buffer) source))
      (should (get-buffer-window other))
      (should (get-buffer-window (leetcode--result-buffer-name "99996"))))))

(provide 'leetcode-tabs-tests)
;;; leetcode-tabs-tests.el ends here
