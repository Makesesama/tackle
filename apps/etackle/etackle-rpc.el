;;; etackle-rpc.el --- JSON-RPC 2.0 stdio transport for the Tackle SDK  -*- lexical-binding: t; -*-

;; Author: Tackle contributors
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Transport layer for the Tackle SDK wire protocol (see
;; packages/tackle_sdk/PROTOCOL.md): spawn the host binary, speak
;; newline-delimited JSON-RPC 2.0 on stdin/stdout, correlate responses
;; to request ids, and deliver notifications to a handler.
;;
;; The layer knows frames, not agent semantics.  Output lines that are
;; not valid JSON are logged to the `*etackle-server-log*' buffer
;; instead of aborting the stream: the Burrito wrapper of the
;; `tackle' binary prints boot messages to stdout before the first
;; frame.  Server stderr also lands in that buffer.
;;
;; Parsed frames are alists whose keys are symbols (the shape
;; `json-parse-string' produces with `:object-type alist'), so
;; lookups use `(map-elt frame 'method).

;;; Code:

(require 'json)(require 'cl-lib)
(require 'map)

(defgroup etackle-rpc nil
  "JSON-RPC stdio transport for the Tackle SDK."
  :group 'tools)

(defvar etackle-rpc-log-buffer-name "*etackle-server-log*"
  "Name of the buffer holding server stderr and non-JSON stdout lines.")

(cl-defun etackle-rpc-start (program args
  &key on-notification on-exit)
  "Start the Tackle SDK server PROGRAM with ARGS; return the process.

ON-NOTIFICATION, if non-nil, is called with (METHOD PARAMS) for every
server-to-client notification.  ON-EXIT, if non-nil, is called with
PROC when the process dies; pending requests have already been failed
by then."
  (let ((proc (make-process
               :name "etackle-sdk"
               :buffer nil
               :command (cons program args)
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :stderr (get-buffer-create etackle-rpc-log-buffer-name)
               :filter #'etackle-rpc--filter
               :sentinel #'etackle-rpc--sentinel)))
    (etackle-rpc--initialize proc on-notification on-exit)
    proc))

(defun etackle-rpc--initialize (proc on-notification on-exit)
  "Attach transport state and handlers to PROC."
  (process-put proc 'etackle-rpc-chunks nil)
  (process-put proc 'etackle-rpc-pending (make-hash-table :test #'eql))
  (process-put proc 'etackle-rpc-next-id 0)
  (process-put proc 'etackle-rpc-on-notification on-notification)
  (process-put proc 'etackle-rpc-on-exit on-exit))

(defun etackle-rpc-request (proc method params &optional on-success on-error)
  "Send METHOD with PARAMS to PROC; return the request id.

ON-SUCCESS is called with the result object, ON-ERROR with
(CODE MESSAGE).  If PROC is not live, ON-ERROR is called
immediately with a nil code."
  (let* ((id (process-get proc 'etackle-rpc-next-id))
         (frame `(("jsonrpc" . "2.0")
                  ("id" . ,id)
                  ("method" . ,method)
                  ("params" . ,(or params nil)))))
    (process-put proc 'etackle-rpc-next-id (1+ id))
    (if (not (process-live-p proc))
        (when on-error (funcall on-error nil "server process is not running"))
      (puthash id (cons on-success on-error)
               (process-get proc 'etackle-rpc-pending))
      (process-send-string proc (concat (json-encode frame) "\n")))
    id))

(defun etackle-rpc-stop (proc)
  "Stop the server process PROC."
  (when (process-live-p proc)
    (delete-process proc)))

;; Input framing and dispatch

(defun etackle-rpc--filter (proc string)
  "Handle a chunk of stdout from PROC.
Complete lines are dispatched; a trailing partial line is kept as a
list of chunks so large single-line frames do not cause quadratic
string concatenation."
  (let ((chunks (cons string (process-get proc 'etackle-rpc-chunks))))
    (if (not (string-search "\n" string))
        (process-put proc 'etackle-rpc-chunks chunks)
      (let* ((data (apply #'concat (nreverse chunks)))
             (lines (split-string data "\n"))
             (rest (car (last lines))))
        (process-put proc 'etackle-rpc-chunks
                     (if (string-empty-p rest) nil (list rest)))
        (dolist (line (butlast lines))
          (unless (string-empty-p line)
            (etackle-rpc--handle-line proc line)))))))

(defun etackle-rpc--handle-line (proc line)
  "Dispatch one complete stdout LINE from PROC."
  (let ((frame (ignore-errors (json-parse-string line :object-type 'alist))))
    (cond
     ((not frame)
      (etackle-rpc--log "ignoring non-JSON output: %s" (etackle-rpc--ellipsize line)))
     ;; `assq' rather than `map-elt': an id of 0 or an empty result
     ;; object must still count as a response.
     ((and (assq 'id frame)
           (or (assq 'result frame) (assq 'error frame)))
      (etackle-rpc--dispatch-response proc frame))
     ((assq 'method frame)
      (let ((handler (process-get proc 'etackle-rpc-on-notification)))
        (when handler
          (funcall handler (map-elt frame 'method)
                   (or (map-elt frame 'params) nil)))))
     (t
      (etackle-rpc--log "ignoring unknown frame: %s" (etackle-rpc--ellipsize line))))))

(defun etackle-rpc--dispatch-response (proc frame)
  "Deliver the response FRAME to the callback registered for its id."
  (let* ((id (map-elt frame 'id))
         (pending (process-get proc 'etackle-rpc-pending))
         (callback (gethash id pending)))
    (remhash id pending)
    (when callback
      (let ((error (map-elt frame 'error)))
        (if error
            (let ((on-error (cdr callback)))
              (when on-error
                (funcall on-error (map-elt error 'code)
                         (map-elt error 'message))))
          (let ((on-success (car callback)))
            (when on-success
              (funcall on-success (map-elt frame 'result)))))))))

(defun etackle-rpc--sentinel (proc _event)
  "Fail pending requests and notify the host when PROC dies."
  (when (memq (process-status proc) '(exit signal failed))
    (etackle-rpc--fail-pending proc "server process exited")
    (let ((on-exit (process-get proc 'etackle-rpc-on-exit)))
      (when on-exit (funcall on-exit proc)))))

(defun etackle-rpc--fail-pending (proc reason)
  "Call the error callback of every pending request on PROC with REASON."
  (let ((pending (process-get proc 'etackle-rpc-pending)))
    (maphash (lambda (_id callback)
               (let ((on-error (cdr callback)))
                 (when on-error (funcall on-error nil reason))))
             pending)
    (clrhash pending)))

(defun etackle-rpc--log (format &rest args)
  "Append a diagnostic line to the server log buffer."
  (with-current-buffer (get-buffer-create etackle-rpc-log-buffer-name)
    (goto-char (point-max))
    (insert (apply #'format format args) "\n")))

(defun etackle-rpc--ellipsize (string &optional limit)
  "Return STRING truncated to LIMIT (default 200) characters."
  (let ((limit (or limit 200)))
    (if (<= (length string) limit)
        string
      (concat (substring string 0 limit) "..."))))

(provide 'etackle-rpc)
;;; etackle-rpc.el ends here
