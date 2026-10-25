;;; leetcode-workspace-tests.el --- Browser workflow tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)

(defun leetcode-workspace-test--response ()
  "Return a GraphQL response for a problem with a non-derived slug."
  '((data . ((question . ((questionFrontendId . "99999")
                         (questionId . "123456")
                         (title . "Workspace Example!")
                         (titleSlug . "workspace-test")
                         (difficulty . "Easy")
                         (likes . 1) (dislikes . 0)
                         (content . "<p>Return the input.</p>")
                         (exampleTestcaseList . ["[1,2]\n3"])
                         (codeSnippets . [((lang . "Python3")
                                           (langSlug . "python3")
                                           (code . "class Solution:\n    pass\n"))])))))))

(defmacro leetcode-workspace-test--with-response (response &rest body)
  "Run BODY with an HTTP GraphQL RESPONSE and isolated problem state."
  (declare (indent 1))
  `(let ((leetcode--problems (make-leetcode-problems))
         (response-buffer (generate-new-buffer " *leetcode-test-response*")))
     (unwind-protect
         (cl-letf (((symbol-function 'aio-url-retrieve)
                    (lambda (&rest _)
                      (with-current-buffer response-buffer
                        (erase-buffer)
                        (setq-local url-http-end-of-headers (point-min))
                        (insert (json-encode ,response)))
                      (let ((promise (aio-promise)))
                        (aio-resolve promise (lambda () (cons nil response-buffer)))
                        promise))))
           ,@body)
       (kill-buffer response-buffer))))

(ert-deftest leetcode-workspace-url-parsing ()
  (dolist (url '("https://leetcode.com/problems/two-sum/"
                 " https://leetcode.com/problems/two-sum/description/?envId=1 "
                 "https://www.leetcode.com/problems/two-sum?x=y"
                 "https://leetcode.com/problems/two-sum/#example"))
    (should (equal "two-sum" (leetcode--slug-from-url url))))
  (dolist (url '("two-sum" "https://evil.com/problems/two-sum/"
                 "https://leetcode.com.evil.com/problems/two-sum/"
                 "https://leetcode.com@evil.com/problems/two-sum/"
                 "file:///problems/two-sum/" "https://leetcode.com/problemset/"
                 "https://leetcode.com/problems/"))
    (should-error (leetcode--slug-from-url url) :type 'user-error)))

(ert-deftest leetcode-workspace-direct-fetch-and-registration ()
  (leetcode-workspace-test--with-response (leetcode-workspace-test--response)
    (let ((problem (aio-wait-for (leetcode--fetch-workspace-question "workspace-test"))))
      (should (equal (leetcode-problem-id problem) "99999"))
      (should (equal (leetcode-problem-backend-id problem) "123456"))
      (should (equal (leetcode-problem-testcases problem) '("[1,2]\n3")))
      (should (eq problem (leetcode--get-problem "workspace-test")))
      (aio-wait-for (leetcode--fetch-workspace-question "workspace-test"))
      (should (= 1 (length (leetcode-problems-problems leetcode--problems)))))))

(ert-deftest leetcode-workspace-api-error-does-not-register ()
  (leetcode-workspace-test--with-response '((data . ((question . nil))))
    (should-error (aio-wait-for (leetcode--fetch-workspace-question "missing"))
                  :type 'user-error)
    (should-not (leetcode-problems-problems leetcode--problems))))

(ert-deftest leetcode-workspace-copy-and-handoff ()
  (with-temp-buffer
    (let* ((kill-ring nil) (opened nil)
           (leetcode-browser-function (lambda (url) (setq opened url))))
      (insert "// local harness\n// code_start\nreturn 'λ';\n// code_end\n// tests")
      (leetcode-solution-mode 1)
      (setq-local leetcode--problem-slug "workspace-test"
                  leetcode--problem-url "https://leetcode.com/problems/workspace-test/")
      (rename-buffer " *renamed-leetcode-test*" t)
      (should (equal (leetcode--get-slug-title (current-buffer)) "workspace-test"))
      (leetcode-return-to-browser)
      (should (equal (current-kill 0) "\nreturn 'λ';\n"))
      (should (equal opened leetcode--problem-url)))))

(ert-deftest leetcode-workspace-command-guards ()
  (with-temp-buffer
    (should-error (leetcode-copy-solution) :type 'user-error)
    (should-error (leetcode-return-to-browser) :type 'user-error)))

(ert-deftest leetcode-workspace-timeout ()
  (let ((real-run-at-time (symbol-function 'run-at-time)))
    (cl-letf (((symbol-function 'leetcode--fetch-workspace-question)
               (lambda (_) (aio-promise)))
              ((symbol-function 'run-at-time)
               (lambda (time repeat function &rest args)
                 (apply real-run-at-time (if (equal time 30) 0.001 time)
                        repeat function args))))
      (should-error
       (aio-wait-for (leetcode-setup-from-url "https://leetcode.com/problems/two-sum/"))
       :type 'user-error))))

(ert-deftest leetcode-workspace-clipboard-fallback ()
  (let ((kill-ring '("https://leetcode.com/problems/two-sum/")))
    (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) nil)))
      (should (equal (leetcode--clipboard-problem-url)
                     "https://leetcode.com/problems/two-sum/")))))

(ert-deftest leetcode-workspace-interactive-url-without-prompt ()
  (cl-letf (((symbol-function 'gui-get-selection)
             (lambda (&rest _) " https://leetcode.com/problems/two-sum/description/ "))
            ((symbol-function 'read-string)
             (lambda (&rest _) (ert-fail "A valid clipboard URL must not prompt"))))
    (should (equal (eval (cadr (interactive-form #'leetcode-setup-from-url)) t)
                   '("https://leetcode.com/problems/two-sum/description/")))))

(ert-deftest leetcode-workspace-interactive-invalid-clipboard-prompts ()
  (let ((kill-ring '("https://leetcode.com/problems/previous-problem/"))
        (prompted nil))
    (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) "unrelated text"))
              ((symbol-function 'read-string)
               (lambda (&rest _)
                 (setq prompted t)
                 "https://leetcode.com/problems/two-sum/")))
      (should (equal (eval (cadr (interactive-form #'leetcode-setup-from-url)) t)
                     '("https://leetcode.com/problems/two-sum/")))
      (should prompted))))

(ert-deftest leetcode-workspace-setup-and-repeat ()
  (leetcode-workspace-test--with-response (leetcode-workspace-test--response)
    (let ((leetcode-save-solutions nil)
          (leetcode-open-problem-in-new-tab nil)
          (leetcode-prefer-language "python3")
          (leetcode--problem-titles nil)
          (initial-buffers (buffer-list)))
      (unwind-protect
          (save-window-excursion
            (let ((solution (aio-wait-for
                             (leetcode-setup-from-url
                              "https://leetcode.com/problems/workspace-test/description/"))))
              (with-current-buffer solution
                (should (derived-mode-p 'python-mode 'python-ts-mode))
                (should (equal (buffer-string) "class Solution:\n    pass\n"))
                (should (equal leetcode--problem-slug "workspace-test"))
                (should (equal leetcode--lang "python3"))
                (erase-buffer)
                (insert "my previous unsaved solution\n"))
              (should (equal (leetcode--testcase-buffer-data "99999") "[1,2]\n3"))
              (aio-wait-for (leetcode-setup-from-url "https://leetcode.com/problems/workspace-test/"))
              (should (equal (leetcode--buffer-content solution) "class Solution:\n    pass\n"))
              (let ((archive (seq-find
                              (lambda (buffer)
                                (string-prefix-p "workspace-test.py attempt " (buffer-name buffer)))
                              (buffer-list))))
                (should archive)
                (should (equal (leetcode--buffer-content archive)
                               "my previous unsaved solution\n")))))
        (dolist (buffer (seq-difference (buffer-list) initial-buffers))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest leetcode-workspace-saved-file-preservation ()
  (let* ((directory (make-temp-file "leetcode-workspace-" t))
         (leetcode-directory directory)
         (leetcode-save-solutions t)
         (leetcode-open-problem-in-new-tab nil)
         (leetcode-prefer-language "python3")
         (leetcode--problem-titles nil)
         (initial-buffers (buffer-list))
         (file (expand-file-name
                (format "99999_workspace-test_%s.py" (format-time-string "%Y-%m-%d"))
                directory)))
    (unwind-protect
        (save-window-excursion
          (write-region "saved previous solution\n" nil file nil 'silent)
          (leetcode-workspace-test--with-response (leetcode-workspace-test--response)
            (let ((solution (aio-wait-for
                             (leetcode-setup-from-url "https://leetcode.com/problems/workspace-test/"))))
              (should (equal (buffer-file-name solution) file))
              (should (equal (leetcode--buffer-content solution) "class Solution:\n    pass\n"))
              (with-temp-buffer
                (insert-file-contents file)
                (should (equal (buffer-string) "saved previous solution\n")))
              (should (seq-find
                       (lambda (buffer)
                         (and (string-prefix-p (concat (file-name-nondirectory file) " attempt ")
                                               (buffer-name buffer))
                              (equal (leetcode--buffer-content buffer) "saved previous solution\n")))
                       (buffer-list))))))
      (dolist (buffer (seq-difference (buffer-list) initial-buffers))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(provide 'leetcode-workspace-tests)
;;; leetcode-workspace-tests.el ends here
