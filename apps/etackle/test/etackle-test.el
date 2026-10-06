;;; etackle-test.el --- ERT tests for the etackle RPC layer  -*- lexical-binding: t; -*-

;; Run from apps/etackle with:
;;
;;   emacs -Q --batch -L . -l test/etackle-test.el \
;;       -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'etackle-rpc)

(defun etackle-test--fake-proc (on-notification)
  "Return a pipe process with RPC state and ON-NOTIFICATION installed."
  (let ((proc (make-pipe-process :name "etackle-test" :noquery t)))
    (etackle-rpc--initialize proc on-notification nil)
    proc))

(ert-deftest etackle-rpc-accumulates-partial-lines ()
  "A frame split across filter calls is dispatched once complete."
  (let* ((received nil)
         (proc (etackle-test--fake-proc
                (lambda (method params)
                  (push (list method params) received)))))
    (etackle-rpc--filter proc "{\"jsonrpc\":\"2.0\",\"meth")
    (etackle-rpc--filter proc "od\":\"event\",\"params\":{\"a\":1}}\n")
    (should (equal '(("event" ((a . 1)))) received))))

(ert-deftest etackle-rpc-handles-multiple-frames-per-chunk ()
  "Several frames in one chunk are dispatched in order."
  (let* ((received nil)
         (proc (etackle-test--fake-proc
                (lambda (method params)
                  (push (list method params) received)))))
    (etackle-rpc--filter
     proc
     "{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"n\":1}}\n{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"n\":2}}\n{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"n\":3}}\n")
    (should (equal '(("event" ((n . 3)))
                      ("event" ((n . 2)))
                      ("event" ((n . 1))))
                    received))))

(ert-deftest etackle-rpc-correlates-responses-by-id ()
  "A response is delivered to the callback registered for its id."
  (let* ((proc (etackle-test--fake-proc nil))
         (seen nil)
         (id (etackle-rpc-request proc "session/new" nil
                                  (lambda (result)
                                    (push (list 'ok result) seen))
                                  (lambda (_code message)
                                    (push (list 'err message) seen)))))
    (etackle-rpc--filter
     proc
     (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":{\"sessionId\":\"s1\"}}\n"
             id))
    (should (equal '((ok ((sessionId . "s1")))) seen))))

(ert-deftest etackle-rpc-delivers-error-responses ()
  "An error response reaches the error callback with code and message."
  (let* ((proc (etackle-test--fake-proc nil))
         (seen nil)
         (id (etackle-rpc-request proc "turn/start" nil
                                  (lambda (_result)
                                    (push 'ok seen))
                                  (lambda (code message)
                                    (push (list code message) seen)))))
    (etackle-rpc--filter
     proc
     (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"error\":{\"code\":-32000,\"message\":\"conflict\"}}\n"
             id))
    (should (equal '((-32000 "conflict")) seen))))

(ert-deftest etackle-rpc-accepts-empty-result ()
  "An empty result object still counts as a response."
  (let* ((proc (etackle-test--fake-proc nil))
         (seen nil)
         (id (etackle-rpc-request proc "shutdown" nil
                                  (lambda (_result)
                                    (push 'ok seen))
                                  (lambda (_code _message)
                                    (push 'err seen)))))
    (etackle-rpc--filter
     proc
     (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":{}}\n" id))
    (should (equal '(ok) seen))))

(ert-deftest etackle-rpc-tolerates-non-json-lines ()
  "Non-JSON stdout lines are logged, not signalled."
  (let* ((received nil)
         (proc (etackle-test--fake-proc
                (lambda (method _params)
                  (push method received)))))
    (etackle-rpc--filter proc "[i] Install path is being overridden\n")
    (etackle-rpc--filter
     proc
     "{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{}}\n")
    (should (equal '("event") received))))

(ert-deftest etackle-rpc-fails-pending-on-exit ()
  "Failing pending requests calls every error callback once."
  (let* ((proc (etackle-test--fake-proc nil))
         (seen nil))
    (etackle-rpc-request proc "tools/list" nil
                         (lambda (_result) (push 'ok seen))
                         (lambda (_code message) (push message seen)))
    (etackle-rpc-request proc "tools/list" nil
                         (lambda (_result) (push 'ok seen))
                         (lambda (_code message) (push message seen)))
    (etackle-rpc--fail-pending proc "server process exited")
    (should (equal '("server process exited" "server process exited") seen))
    (should (eq 0 (hash-table-count (process-get proc 'etackle-rpc-pending))))))

(ert-deftest etackle-rpc-request-on-dead-process ()
  "Requesting from a dead process calls the error callback immediately."
  (let* ((proc (etackle-test--fake-proc nil))
         (seen nil))
    (delete-process proc)
    (etackle-rpc-request proc "initialize" nil
                         (lambda (_result) (push 'ok seen))
                         (lambda (_code message) (push message seen)))
    (should (equal '("server process is not running") seen))))

(provide 'etackle-test)
;;; etackle-test.el ends here
