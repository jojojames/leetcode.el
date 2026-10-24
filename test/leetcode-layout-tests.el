;;; leetcode-layout-tests.el --- Preserve customized windows -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)

(defun leetcode-layout-test--resolved (value)
  "Return a promise resolved to VALUE."
  (let ((promise (aio-promise)))
    (aio-resolve promise (lambda () value))
    promise))

(defun leetcode-layout-test--run (command visible-result)
  "Verify COMMAND preserves a custom layout with VISIBLE-RESULT or without."
  (let* ((initial-buffers (buffer-list))
         (leetcode--problems
          (make-leetcode-problems
           :problems (list (make-leetcode-problem :id "99998" :backend-id "99998"
                                                  :title-slug "layout-test"))))
         (source (generate-new-buffer " *leetcode-layout-code*"))
         (unrelated (generate-new-buffer " *leetcode-layout-unrelated*"))
         (result (get-buffer-create (leetcode--result-buffer-name "99998"))))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer source)
          (with-current-buffer source
            (insert "pass\n")
            (setq-local leetcode--problem-slug "layout-test"))
          (set-window-buffer (split-window-right) unrelated)
          (when visible-result
            (set-window-buffer (split-window-below) result))
          (let ((selected (selected-window))
                (layout (mapcar (lambda (window)
                                  (list window (window-edges window) (window-buffer window)))
                                (window-list))))
            (cl-letf (((symbol-function 'leetcode-restore-layout)
                       (lambda () (ert-fail "Must not restore the standard layout")))
                      ((symbol-function 'leetcode--ensure-login)
                       (lambda (&rest _) (leetcode-layout-test--resolved nil)))
                      ((symbol-function 'leetcode--api-interpret-solution)
                       (lambda (_)
                         (should (equal (leetcode--buffer-content result) "Waiting for result..."))
                         (leetcode-layout-test--resolved "runcode_test")))
                      ((symbol-function 'leetcode--api-submit)
                       (lambda (&rest _)
                         (let ((buffer (generate-new-buffer " *leetcode-layout-response*")))
                           (with-current-buffer buffer
                             (setq-local url-http-end-of-headers (point-min))
                             (insert "{\"submission_id\": 123}"))
                           (leetcode-layout-test--resolved (cons nil buffer)))))
                      ((symbol-function 'leetcode--api-check-submission)
                       (lambda (_ problem callback)
                         (funcall callback (leetcode-problem-id problem) nil)
                         (leetcode-layout-test--resolved nil)))
                      ((symbol-function 'leetcode--show-testcases-result)
                       (lambda (_ _)
                         (with-current-buffer result (erase-buffer) (insert "Test complete"))))
                      ((symbol-function 'leetcode--show-submission-result)
                       (lambda (_ _)
                         (with-current-buffer result (erase-buffer) (insert "Submission complete")))))
              (aio-wait-for (funcall command)))
            (should (eq selected (selected-window)))
            (should (eq (window-buffer selected) source))
            (should (get-buffer-window unrelated))
            (should (get-buffer-window result))
            (when visible-result
              (should (equal layout
                             (mapcar (lambda (window)
                                       (list window (window-edges window) (window-buffer window)))
                                     (window-list)))))))
      (dolist (buffer (seq-difference (buffer-list) initial-buffers))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest leetcode-layout-visible-results ()
  (dolist (command '(leetcode-try leetcode-submit))
    (leetcode-layout-test--run command t)))

(ert-deftest leetcode-layout-hidden-results ()
  (dolist (command '(leetcode-try leetcode-submit))
    (leetcode-layout-test--run command nil)))

(provide 'leetcode-layout-tests)
;;; leetcode-layout-tests.el ends here
