;;; leetcode-polling-tests.el --- Result polling tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)

(defun leetcode-polling-test--resolved (value)
  "Return a promise resolved to VALUE."
  (let ((promise (aio-promise)))
    (aio-resolve promise (lambda () value))
    promise))

(defmacro leetcode-polling-test--with-polls (responses &rest body)
  "Run BODY with queued poll RESPONSES and no login or sleep."
  (declare (indent 1))
  `(let ((responses ,responses) (requests 0) (delays nil) (response-buffers nil))
     (unwind-protect
         (cl-letf (((symbol-function 'leetcode--common-extra-headers)
                    (lambda () (leetcode-polling-test--resolved nil)))
                   ((symbol-function 'aio-sleep)
                    (lambda (delay) (push delay delays) (leetcode-polling-test--resolved nil)))
                   ((symbol-function 'aio-url-retrieve)
                    (lambda (_)
                      (cl-incf requests)
                      (let* ((response (pop responses))
                             (buffer (generate-new-buffer " *leetcode-poll-test*")))
                        (push buffer response-buffers)
                        (with-current-buffer buffer
                          (setq-local url-http-end-of-headers (point-min))
                          (setq-local url-http-response-status
                                      (or (nth 2 (plist-get (car response) :error)) 200))
                          (insert (json-encode (cdr response))))
                        (leetcode-polling-test--resolved (cons (car response) buffer))))))
           ,@body)
       (dolist (buffer response-buffers)
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest leetcode-polling-pending-to-success ()
  (leetcode-polling-test--with-polls
      '((nil . ((state . "PENDING")))
        (nil . ((state . "STARTED")))
        (nil . ((state . "RUNNING_TESTS")))
        (nil . ((state . "SUCCESS") (status_code . 10))))
    (let ((problem (make-leetcode-problem :id "217" :title-slug "contains-duplicate"))
          (result nil))
      (aio-wait-for
       (leetcode--api-check-submission
        "runcode_test" problem (lambda (id data) (setq result (cons id data)))))
      (should (= requests 4))
      (should (equal (reverse delays) (quote (1 2 4))))
      (should (equal (car result) "217"))
      (should (= (alist-get 'status_code (cdr result)) 10))
      (should-not (seq-some #'buffer-live-p response-buffers)))))

(ert-deftest leetcode-polling-http-and-state-errors ()
  (dolist (response '(((:error (error http 403)) . nil)
                      (nil . ((state . "UNRECOGNIZED")))))
    (leetcode-polling-test--with-polls (list response)
      (should-error
       (aio-wait-for
        (leetcode--api-check-submission
         "runcode_test" (make-leetcode-problem :id "217" :title-slug "contains-duplicate")
         (lambda (&rest _) (ert-fail "Error response must not complete"))))
       :type 'user-error)
      (should (= requests 1))
      (should-not (seq-some #'buffer-live-p response-buffers)))))

(ert-deftest leetcode-polling-rate-limit-stops-without-retrying ()
  (leetcode-polling-test--with-polls
      '(((:error (error http 429)) . nil))
    (let ((error (should-error
                  (aio-wait-for
                   (leetcode--api-check-submission
                    "runcode_test" (make-leetcode-problem :id "217" :title-slug "contains-duplicate")
                    (lambda (&rest _) (ert-fail "Must not complete"))))
                  :type 'user-error)))
      (should (string-match-p "rate limit.*429" (error-message-string error))))
    (should (= requests 1))
    (should-not delays)
    (should-not (seq-some #'buffer-live-p response-buffers))))

(ert-deftest leetcode-polling-timeout ()
  (let ((leetcode-result-timeout 0.01))
    (cl-letf (((symbol-function 'leetcode--common-extra-headers)
               (lambda () (leetcode-polling-test--resolved nil)))
              ((symbol-function 'aio-url-retrieve) (lambda (_) (aio-promise))))
      (should-error
       (aio-wait-for
        (leetcode--api-check-submission
         "runcode_test" (make-leetcode-problem :id "217" :title-slug "contains-duplicate")
         #'ignore))
       :type 'user-error))))

(provide 'leetcode-polling-tests)
;;; leetcode-polling-tests.el ends here
