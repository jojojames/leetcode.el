;;; leetcode-submission-hook-tests.el --- Final verdict hooks -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)

(defun leetcode-submission-hook-test--resolved (value)
  "Return a promise resolved to VALUE."
  (let ((promise (aio-promise)))
    (aio-resolve promise (lambda () value))
    promise))

(ert-deftest leetcode-submission-hook-captured-before-judging ()
  (with-temp-buffer
    (let* ((source (current-buffer))
           (problem (make-leetcode-problem :id "1" :backend-id "1" :title-slug "two-sum"))
           (leetcode--problems (make-leetcode-problems :problems (list problem)))
           (response (generate-new-buffer " *leetcode-hook-response*"))
           (poll (aio-promise)) (callback nil) (observed nil) (new-attempt-called nil))
      (setq-local leetcode--problem-slug "two-sum")
      (setq-local leetcode-submission-result-hook nil)
      (insert "class Solution: pass")
      (add-hook 'leetcode-submission-result-hook
                (lambda (received result)
                  (setq observed (list (current-buffer) received result))) nil t)
      (with-current-buffer response
        (setq-local url-http-end-of-headers (point-min))
        (insert "{\"submission_id\":123}"))
      (unwind-protect
          (cl-letf (((symbol-function 'leetcode--ensure-login)
                     (lambda (&rest _) (leetcode-submission-hook-test--resolved nil)))
                    ((symbol-function 'leetcode--api-submit)
                     (lambda (&rest _) (leetcode-submission-hook-test--resolved (cons nil response))))
                    ((symbol-function 'leetcode--api-check-submission)
                     (lambda (_ _ handler) (setq callback handler) poll))
                    ((symbol-function 'leetcode--show-run-result) #'ignore))
            (let ((submission (leetcode-submit)))
              (cl-loop repeat 100 until callback do (accept-process-output nil 0.01))
              (should callback)
              (should-not observed)
              ;; The source buffer can be reused before the network completes.
              (setq-local leetcode-submission-result-hook
                          (list (lambda (&rest _) (setq new-attempt-called t))))
              (let ((result '((state . "SUCCESS") (status_code . 10))))
                (with-temp-buffer (funcall callback "1" result))
                (aio-resolve poll (lambda () nil))
                (aio-wait-for submission)
                (should (equal observed (list source problem result)))
                (should-not new-attempt-called))))
        (when (buffer-live-p response) (kill-buffer response))))))

(ert-deftest leetcode-submission-hook-never-runs-for-test-cases ()
  (with-temp-buffer
    (let* ((problem (make-leetcode-problem :id "1" :title-slug "two-sum"))
           (leetcode--problems (make-leetcode-problems :problems (list problem)))
           (called nil)
           (leetcode-submission-result-hook (list (lambda (&rest _) (setq called t))))
           (result-buffer nil))
      (setq-local leetcode--problem-slug "two-sum")
      (unwind-protect
          (cl-letf (((symbol-function 'leetcode--ensure-login)
                     (lambda (&rest _) (leetcode-submission-hook-test--resolved nil)))
                    ((symbol-function 'leetcode--prepare-result-buffer)
                     (lambda (_) (setq result-buffer (current-buffer))))
                    ((symbol-function 'leetcode--api-interpret-solution)
                     (lambda (_) (leetcode-submission-hook-test--resolved "runcode_test")))
                    ((symbol-function 'leetcode--api-check-submission)
                     (lambda (_ _ callback)
                       (funcall callback "1" '((state . "SUCCESS") (status_code . 10)))
                       (leetcode-submission-hook-test--resolved nil)))
                    ((symbol-function 'leetcode--show-run-result) #'ignore))
            (aio-wait-for (leetcode-try))
            (should result-buffer)
            (should-not called))
        nil))))

(provide 'leetcode-submission-hook-tests)
;;; leetcode-submission-hook-tests.el ends here
