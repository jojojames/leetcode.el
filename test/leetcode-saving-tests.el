;;; leetcode-saving-tests.el --- Saving solutions -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)

(ert-deftest leetcode-saving-creates-directory-and-saves ()
  (let* ((root (make-temp-file "leetcode-saving-" t))
         (leetcode-directory (expand-file-name "nested/solutions" root))
         (leetcode-save-solutions t)
         (buffer nil)
         (file (expand-file-name "217_contains-duplicate.py" leetcode-directory)))
    (unwind-protect
        (progn
          (setq buffer (leetcode--get-code-buffer "217_contains-duplicate.py"))
          (should (file-directory-p leetcode-directory))
          (with-current-buffer buffer
            (should (equal buffer-file-name file))
            (insert "class Solution:\n    pass\n")
            (save-buffer))
          (with-temp-buffer
            (insert-file-contents file)
            (should (equal (buffer-string) "class Solution:\n    pass\n"))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest leetcode-saving-scratch-option ()
  (let* ((leetcode-save-solutions nil)
         (name (generate-new-buffer-name " *leetcode-saving-scratch*"))
         (buffer (leetcode--get-code-buffer name)))
    (unwind-protect
        (should-not (buffer-file-name buffer))
      (kill-buffer buffer))))

(ert-deftest leetcode-saving-date-separates-days-and-reuses-the-same-day ()
  (let* ((leetcode-directory (make-temp-file "leetcode-dated-" t))
         (leetcode-save-solutions t)
         (leetcode--lang "python3")
         (problem (make-leetcode-problem :id "746" :title-slug "min-cost-climbing-stairs"))
         (date "2026-10-24")
         (buffers nil))
    (unwind-protect
        (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) date)))
          (let* ((name (leetcode--get-code-buffer-name "Min Cost Climbing Stairs" problem))
                 (first (leetcode--get-code-buffer name)))
            (push first buffers)
            (should (equal name "746_min-cost-climbing-stairs_2026-10-24.py"))
            (should (eq first (leetcode--get-code-buffer name)))
            (with-current-buffer first (insert "previous day's solution"))
            (setq date "2026-10-25")
            (let* ((next-name (leetcode--get-code-buffer-name "Min Cost Climbing Stairs" problem))
                   (next (leetcode--get-code-buffer next-name)))
              (push next buffers)
              (should (equal next-name "746_min-cost-climbing-stairs_2026-10-25.py"))
              (should-not (eq first next))
              (should (equal (leetcode--buffer-content first) "previous day's solution"))
              (should (zerop (buffer-size next))))))
      (dolist (buffer buffers)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory leetcode-directory t))))

(provide 'leetcode-saving-tests)
;;; leetcode-saving-tests.el ends here
