;;; leetcode-request-tests.el --- HTTP request encoding -*- lexical-binding: t; -*-

(require 'ert)
(require 'leetcode)
(require 'url-http)

(defvar url-http-target-url)
(defvar url-http-method)
(defvar url-http-data)
(defvar url-http-extra-headers)
(defvar url-http-proxy)
(defvar url-http-referer)
(defvar url-http-extensions-header)

(ert-deftest leetcode-request-unicode-tests-and-submissions ()
  (let* ((code "# Correct—it’s Fibonacci. 日本語 🐍\nclass Solution: pass")
         (input "[\"é\",\"你好\"]")
         (problem (make-leetcode-problem :id "70" :backend-id "70"
                                         :title-slug "climbing-stairs"))
         (leetcode--lang "python3")
         (requests nil)
         (responses nil))
    (cl-labels ((resolved (value)
                  (let ((promise (aio-promise)))
                    (aio-resolve promise (lambda () value))
                    promise)))
      (unwind-protect
          (cl-letf (((symbol-function 'leetcode--common-extra-headers)
                     (lambda () (resolved nil)))
                    ((symbol-function 'leetcode--code-buffer-data) (lambda () code))
                    ((symbol-function 'leetcode--testcase-buffer-data) (lambda (_) input))
                    ((symbol-function 'aio-url-retrieve)
                     (lambda (url)
                       (should-not (multibyte-string-p url-request-data))
                       (should-not (string-match-p "[^[:ascii:]]" url-request-data))
                       ;; Real HTTP assembly mixes byte data and multibyte
                       ;; header values, including Referer and cookie strings.
                       (let* ((url-http-target-url (url-generic-parse-url url))
                              (url-http-method "POST")
                              (url-http-data url-request-data)
                              (url-http-extra-headers
                               (list (cons "Referer" (string-to-multibyte url))))
                              (url-http-proxy nil)
                              (url-http-referer nil)
                              (url-http-extensions-header nil)
                              (request (url-http-create-request)))
                         (should (= (length request) (string-bytes request))))
                       (push (cons url
                                   (json-read-from-string
                                    (decode-coding-string url-request-data 'utf-8)))
                             requests)
                       (let ((buffer (generate-new-buffer " *leetcode-request-test*")))
                         (push buffer responses)
                         (with-current-buffer buffer
                           (setq-local url-http-end-of-headers (point-min))
                           (insert "{\"interpret_id\":\"test-id\"}"))
                         (resolved (cons nil buffer))))))
            (should (equal (aio-wait-for (leetcode--api-interpret-solution problem))
                           "test-id"))
            (aio-wait-for (leetcode--api-submit "70" "climbing-stairs" code))
            (should (= (length requests) 2))
            (dolist (request requests)
              (should (equal (alist-get 'typed_code (cdr request)) code)))
            (should (equal (alist-get 'data_input (cdr (cadr requests))) input)))
        (mapc #'kill-buffer responses)))))

(ert-deftest leetcode-request-unicode-graphql ()
  (let ((payload (leetcode--graphql-payload "example" "query { example }"
                                           '((text . "é—你好")))))
    (should-not (multibyte-string-p payload))
    (should (equal (alist-get 'text
                             (alist-get 'variables
                                        (json-read-from-string
                                         (decode-coding-string payload 'utf-8))))
                   "é—你好"))))

;;; leetcode-request-tests.el ends here
