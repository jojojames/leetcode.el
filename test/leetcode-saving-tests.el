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

(provide 'leetcode-saving-tests)
;;; leetcode-saving-tests.el ends here
