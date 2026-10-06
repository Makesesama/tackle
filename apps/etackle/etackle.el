;;; etackle.el --- Emacs client for the Tackle SDK  -*- lexical-binding: t; -*-

;; Author: Tackle contributors
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; An Emacs frontend for the Tackle agent harness, speaking the Tackle
;; SDK wire protocol (packages/tackle_sdk/PROTOCOL.md) over stdio to
;; `tackle sdk'.  This is the first client for the SDK and is
;; deliberately basic: one session per directory, one turn at a time,
;; streamed assistant text, one-line tool summaries, and a client-side
;; queue for prompts typed while a turn is running.
;;
;; Layout follows the pilish pattern: the conversation renders in a
;; read-only chat buffer on top, and the next prompt is composed in an
;; ordinary editable buffer below it.
;;
;; Usage:
;;
;;   M-x etackle           start or switch to a session for
;;                         `default-directory'
;;   C-c C-c               (input buffer) send the prompt
;;   C-c C-k               (chat buffer) cancel the running turn
;;   Q                     (chat buffer) kill the session
;;   q                     (chat buffer) bury; the session keeps running
;;
;; The model is pinned via `etackle-model' because protocol version 1
;; has no model discovery.

;;; Code:

(require 'etackle-rpc)
(require 'map)
(require 'subr-x)

(defgroup etackle nil
  "Emacs client for the Tackle SDK."
  :group 'tools)

(defcustom etackle-program "jailed-tackle"
  "Tackle CLI binary that serves the SDK protocol.
It must support the `sdk' subcommand."
  :type '(string :tag "program"))

(defcustom etackle-sdk-args '("sdk")
  "Arguments passed to `etackle-program' to serve the SDK protocol."
  :type '(repeat string))

(defcustom etackle-model "openai-codex/gpt-6.1-sol"
  "Model ref (\"adapter/model\") used for new sessions.
The SDK protocol has no model discovery yet, so this is pinned."
  :type '(string :tag "adapter/model"))

(defcustom etackle-system-prompt nil
  "Optional system prompt for new sessions."
  :type '(choice (const :tag "none" nil) string))

(defcustom etackle-delta-flush-interval 0.05
  "Seconds to batch streamed text before inserting it into the chat.
Per-delta insertion makes font-lock and window display quadratic in
long replies; coalescing keeps the chat responsive."
  :type 'number)

(defface etackle-user '((t :weight bold))
  "Face for user message headers.")

(defface etackle-assistant '((t :weight bold))
  "Face for assistant message headers.")

(defface etackle-tool '((t :inherit shadow))
  "Face for tool activity lines.")

(defface etackle-reasoning '((t :inherit font-lock-comment-face :slant italic))
  "Face for streamed reasoning text.")

(defface etackle-error '((t :inherit error))
  "Face for error messages.")

;; Session state lives in the chat buffer.

(defvar-local etackle--proc nil
  "SDK server process of this session.")

(defvar-local etackle--session-id nil
  "SDK session id of this session.")

(defvar-local etackle--status 'starting
  "Session status: `starting', `idle', `running', or `dead'.")

(defvar-local etackle--phase nil
  "Current agent phase from `status_change' events, or nil.")

(defvar-local etackle--turn-id nil
  "Id of the running turn, or nil.")

(defvar-local etackle--pending-text ""
  "Streamed assistant text waiting to be flushed into the chat.")

(defvar-local etackle--pending-reasoning ""
  "Streamed reasoning text waiting to be flushed into the chat.")

(defvar-local etackle--flush-timer nil
  "Timer that will flush pending deltas, or nil.")

(defvar-local etackle--queue nil
  "Prompts submitted while a turn was running, oldest first.")

(defvar-local etackle--input-buffer nil
  "The composition buffer of this session.")

(defvar-local etackle--tokens nil
  "Formatted token usage of the latest `usage' event, or nil.")

(defvar-local etackle--closing nil
  "Non-nil while the session is being torn down.")

(defvar-local etackle--assistant-header-shown nil
  "Non-nil once an \"assistant\" header was inserted for the current message.")

(defvar-local etackle--chat-buffer nil
  "The chat buffer of this input buffer.")

(defmacro etackle--with-buffer (buffer &rest body)
  "Evaluate BODY with BUFFER current if it is live."
  (declare (indent 1) (debug (symbolp body)))
  `(when (buffer-live-p ,buffer)
     (with-current-buffer ,buffer ,@body)))

;;; Entry point

;;;###autoload
(defun etackle (&optional directory)
  "Start or switch to a Tackle session for DIRECTORY.
DIRECTORY defaults to `default-directory'.  One session exists per
directory, with a chat buffer and a prompt buffer."
  (interactive)
  (let* ((directory (abbreviate-file-name
                     (directory-file-name
                      (expand-file-name (or directory default-directory)))))
         (chat (or (get-buffer (etackle--buffer-name directory))
                   (etackle--create-session directory))))
    (etackle--display chat)))

(defun etackle--buffer-name (directory)
  "Return the chat buffer name for DIRECTORY."
  (format "*etackle:%s*" directory))

(defun etackle--create-session (directory)
  "Create and start a chat buffer for DIRECTORY; return it."
  (let ((chat (get-buffer-create (etackle--buffer-name directory))))
    (with-current-buffer chat
      (etackle-chat-mode)
      (setq default-directory directory)
      (etackle--start))
    chat))

;;; Buffers and windows

(define-derived-mode etackle-chat-mode special-mode "Tackle"
  "Major mode for Tackle chat buffers.
The buffer is read-only; prompts are composed in the input buffer.
\\{etackle-chat-mode-map}"
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'etackle--cleanup nil t))

(define-derived-mode etackle-input-mode text-mode "Tackle Input"
  "Major mode for composing Tackle prompts.
\\<etackle-input-mode-map>\\[etackle-send] sends the buffer's text;
the session queues it when a turn is already running."
  (visual-line-mode 1))

(define-key etackle-input-mode-map (kbd "C-c C-c") #'etackle-send)
(define-key etackle-chat-mode-map (kbd "C-c C-k") #'etackle-cancel-turn)
(define-key etackle-chat-mode-map (kbd "Q") #'etackle-quit)

(defun etackle--display (chat)
  "Show the CHAT buffer above its input buffer and focus the input."
  (let ((input (etackle--ensure-input-buffer chat)))
    (unless (get-buffer-window chat)
      (display-buffer chat '(display-buffer-pop-up-window)))
    (let ((chat-window (get-buffer-window chat)))
      (when (and chat-window (not (get-buffer-window input)))
        (with-selected-window chat-window
          (let ((below (split-window-below)))
            (set-window-buffer below input)
            (fit-window-to-buffer below nil 3)))))
    (select-window (or (get-buffer-window input)
                       (get-buffer-window chat)
                       (selected-window)))))

(defun etackle--ensure-input-buffer (chat)
  "Return the live input buffer of CHAT, creating it if needed."
  (let ((existing (buffer-local-value 'etackle--input-buffer chat)))
    (if (buffer-live-p existing)
        existing
      (let ((input (get-buffer-create (concat (buffer-name chat) " input"))))
        (with-current-buffer input
          (etackle-input-mode)
          (setq etackle--chat-buffer chat))
        (with-current-buffer chat
          (setq etackle--input-buffer input))
        input))))

;;; Session lifecycle

(defun etackle--start ()
  "Start the SDK server and create a session (chat buffer current)."
  (etackle--insert "Starting %s %s...\n"
                   etackle-program
                   (mapconcat #'identity etackle-sdk-args " "))
  (let ((chat (current-buffer)))
    (setq etackle--proc
          (etackle-rpc-start
           etackle-program etackle-sdk-args
           :on-notification (lambda (method params)
                              (etackle--with-buffer chat
                                (etackle--handle-notification method params)))
           :on-exit (lambda (_proc)
                      (etackle--with-buffer chat
                        (etackle--handle-exit))))))
  (etackle--request "initialize" nil #'etackle--on-initialized))

(defun etackle--on-initialized (result)
  "Continue startup after `initialize'; check the protocol version."
  (let ((version (map-elt result 'protocolVersion)))
    (if (equal version 1)
        (etackle--new-session)
      (etackle--set-status 'dead)
      (etackle--insert-string
       (format "Unsupported SDK protocol version %s; this client speaks 1.\n"
               version)
       'etackle-error))))

(defun etackle--new-session ()
  "Create the SDK session for this chat buffer."
  (let ((params `(("model" . ,etackle-model))))
    (when etackle-system-prompt
      (setq params (append params `(("systemPrompt" . ,etackle-system-prompt)))))
    (etackle--request "session/new" params #'etackle--on-session)))

(defun etackle--on-session (result)
  "Store the session id and become ready for prompts."
  (setq etackle--session-id (map-elt result 'sessionId))
  (etackle--set-status 'idle)
  (etackle--insert "Ready.  Model: %s\n\n" etackle-model)
  (etackle--drain-queue))

(defun etackle--handle-exit ()
  "Mark the session dead when the server process exits."
  (when etackle--flush-timer
    (cancel-timer etackle--flush-timer)
    (setq etackle--flush-timer nil))
  (unless etackle--closing
    (etackle--flush-deltas)
    (etackle--set-status 'dead)
    (etackle--insert-string "\nserver process exited\n" 'etackle-error)))

(defun etackle--cleanup ()
  "Tear down the session; installed on the chat buffer's kill hook."
  (setq etackle--closing t)
  (when etackle--flush-timer
    (cancel-timer etackle--flush-timer))
  (when (process-live-p etackle--proc)
    (delete-process etackle--proc))
  (when (buffer-live-p etackle--input-buffer)
    (kill-buffer etackle--input-buffer)))

(defun etackle-quit ()
  "Kill this session: stop the server process and delete both buffers."
  (interactive)
  (when (y-or-n-p "Quit Tackle session? ")
    (etackle--cleanup)
    (kill-buffer (current-buffer))))

(defun etackle-cancel-turn ()
  "Request cancellation of the running turn."
  (interactive)
  (if etackle--turn-id
      (etackle--request "turn/cancel"
                        `(("turnId" . ,etackle--turn-id)))
    (user-error "No running turn")))

;;; Requests

(defun etackle--request (method params &optional on-success on-error)
  "Send METHOD with PARAMS in the current chat buffer's session.
Callbacks run with the chat buffer current."
  (let ((chat (current-buffer)))
    (etackle-rpc-request
     etackle--proc method params
     (when on-success
       (lambda (result)
         (etackle--with-buffer chat (funcall on-success result))))
     (when on-error
       (lambda (code message)
         (etackle--with-buffer chat (funcall on-error code message)))))))

;;; Prompts and turns

(defun etackle-send ()
  "Send the input buffer's text as the next prompt.
When a turn is running, the prompt is queued and sent when the turn
ends."
  (interactive)
  (let ((chat etackle--chat-buffer))
    (unless (buffer-live-p chat)
      (user-error "No chat buffer for this input buffer"))
    (let ((text (string-trim (buffer-substring (point-min) (point-max)))))
      (when (string-empty-p text)
        (user-error "Nothing to send"))
      (with-current-buffer chat
        (unless (memq etackle--status '(idle starting running))
          (user-error "The session is not running (start it with M-x etackle)")))
      ;; The draft is only cleared once it is accepted.
      (erase-buffer)
      (with-current-buffer chat
        (etackle--submit text)))))

(defun etackle--submit (text)
  "Submit TEXT to the session (chat buffer current)."
  (pcase etackle--status
    ('idle (etackle--start-turn text))
    ((or 'starting 'running)
     (setq etackle--queue (append etackle--queue (list text)))
     (message "Queued; it will be sent when the current turn ends"))
    (_ (user-error "The session is not running (start it with M-x etackle)"))))

(defun etackle--start-turn (text)
  "Echo TEXT and start a turn with it (chat buffer current)."
  (etackle--flush-deltas)
  (etackle--insert-block "you" 'etackle-user text)
  (etackle--set-status 'running)
  (etackle--request "turn/start"
                    `(("sessionId" . ,etackle--session-id)
                      ("input" . ,text))
                    #'etackle--on-turn-started
                    #'etackle--on-turn-error))

(defun etackle--on-turn-started (result)
  "Record the id of the accepted turn."
  (setq etackle--turn-id (map-elt result 'turnId)))

(defun etackle--on-turn-error (_code message)
  "Handle a rejected `turn/start' request."
  (etackle--set-status 'idle)
  (etackle--insert-string (format "turn failed to start: %s\n" message)
                          'etackle-error)
  (etackle--drain-queue))

(defun etackle--drain-queue ()
  "Start the next queued prompt when the session is idle."
  (when (and etackle--queue (eq etackle--status 'idle))
    (etackle--start-turn (pop etackle--queue))))

;;; Notifications

(defun etackle--handle-notification (method params)
  "Dispatch a server notification (chat buffer current)."
  (pcase method
    ("event" (etackle--handle-event (map-elt params 'event)))
    ("turn/end" (etackle--handle-turn-end params))
    ("server/error"
     (etackle--insert-string (format "server error: %s\n"
                                     (map-elt params 'message))
                            'etackle-error))
    (_ nil)))

(defun etackle--handle-event (event)
  "Render one streamed EVENT (chat buffer current).
Unknown event types and data fields are ignored, as the protocol
requires."
  (let* ((type (map-elt event 'type))
         (data (or (map-elt event 'data) nil)))
    (pcase type
      ("message_start"
       (etackle--flush-deltas)
       (setq etackle--assistant-header-shown nil))
      ("message_delta"
       (let ((delta (map-elt data 'delta))
             (field (map-elt data 'field)))
         ;; Tool-input deltas duplicate the arguments that `tool_start'
         ;; already shows; skip them.
         (when (and delta (not (equal field "tool_input")))
           ;; Insert the header lazily so tool-call-only messages do
           ;; not leave a dangling header with no text under it.
           (unless etackle--assistant-header-shown
             (setq etackle--assistant-header-shown t)
             (etackle--insert-string "\nassistant\n\n" 'etackle-assistant))
           (if (equal field "reasoning")
               (setq etackle--pending-reasoning
                     (concat etackle--pending-reasoning delta))
             (setq etackle--pending-text
                   (concat etackle--pending-text delta)))
           (etackle--arm-flush))))
      ("message_end"
       (etackle--flush-deltas)
       (setq etackle--assistant-header-shown nil))
      ("tool_start"
       (etackle--flush-deltas)
       (etackle--insert-tool-line (map-elt data 'name)
                                  (map-elt data 'arguments)))
      ("tool_end"
       (etackle--insert-string
        (etackle--tool-summary (map-elt data 'name) (map-elt data 'result))
        'etackle-tool))
      ("tool_error"
       (etackle--flush-deltas)
       (etackle--insert-string
        (format "tool error (%s): %s\n"
                (or (map-elt data 'name) "unknown")
                (or (map-elt data 'error) "failed"))
        'etackle-error))
      ("error"
       (etackle--flush-deltas)
       (etackle--insert-string
        (format "error: %s\n" (or (map-elt data 'error) "unknown error"))
        'etackle-error))
      ("usage" (etackle--update-usage data))
      ("status_change"
       (setq etackle--phase (map-elt data 'status))
       (etackle--update-mode-line))
      (_ nil))))

(defun etackle--handle-turn-end (params)
  "Settle the turn (chat buffer current)."
  (etackle--flush-deltas)
  (pcase (map-elt params 'result)
    ("error"
     (etackle--insert-string (format "\nturn failed: %s\n"
                                     (or (map-elt params 'error) "unknown"))
                            'etackle-error))
    ("cancelled" (etackle--insert-string "\nturn cancelled\n" 'etackle-tool))
    (_ nil))
  (setq etackle--turn-id nil
        etackle--phase nil)
  (etackle--set-status 'idle)
  (etackle--drain-queue))

;;; Rendering

(defun etackle--insert (format &rest args)
  "Insert formatted text at the end of the chat buffer."
  (etackle--insert-string (apply #'format format args) nil))

(defun etackle--insert-string (string &optional face)
  "Insert STRING at the end of the chat buffer, optionally with FACE.
Point follows the insertion when it was already at the end."
  (let ((inhibit-read-only t)
        (follow (eq (point) (point-max))))
    (save-excursion
      (goto-char (point-max))
      (insert (if face (propertize string 'face face) string)))
    (when follow
      (goto-char (point-max)))))

(defun etackle--insert-block (header face text)
  "Insert a message block: HEADER with FACE, then TEXT."
  (etackle--insert-string (format "\n%s\n\n" header) face)
  (etackle--insert "%s\n" text))

(defun etackle--insert-tool-line (name arguments)
  "Insert a one-line summary of a starting tool call."
  (let ((summary
         (cond
          ((not arguments) "")
          ((stringp arguments) (etackle--truncate arguments 120))
          (t (etackle--truncate (json-encode arguments) 120)))))
    (etackle--insert-string
     (format ">> %s %s\n" (or name "tool") summary)
     'etackle-tool)))

(defun etackle--tool-summary (name result)
  "Return a one-line completion summary for a tool call."
  (let ((detail
         (if (stringp result)
             (let ((first-line (car (split-string result "\n" t))))
               (if (string-empty-p (or first-line ""))
                   ""
                 (concat " -- " (etackle--truncate first-line 100))))
           "")))
    (format "<< %s done%s\n" (or name "tool") detail)))

(defun etackle--truncate (string limit)
  "Return STRING truncated to LIMIT characters."
  (if (<= (length string) limit)
      string
    (concat (substring string 0 limit) "...")))

(defun etackle--arm-flush ()
  "Schedule a flush of the pending deltas (chat buffer current)."
  (unless etackle--flush-timer
    (let ((chat (current-buffer)))
      (setq etackle--flush-timer
            (run-at-time etackle-delta-flush-interval nil
                         (lambda ()
                           (etackle--with-buffer chat
                             (etackle--flush-deltas))))))))

(defun etackle--flush-deltas ()
  "Insert the pending streamed text into the chat buffer."
  (when etackle--flush-timer
    (cancel-timer etackle--flush-timer)
    (setq etackle--flush-timer nil))
  ;; Reasoning and text are coalesced separately, so one flush batch
  ;; can reorder them slightly; both stay within the same message.
  (unless (string-empty-p etackle--pending-reasoning)
    (etackle--insert-string etackle--pending-reasoning 'etackle-reasoning)
    (setq etackle--pending-reasoning ""))
  (unless (string-empty-p etackle--pending-text)
    (etackle--insert "%s" etackle--pending-text)
    (setq etackle--pending-text "")))

;;; Mode line

(defun etackle--set-status (status)
  "Set the session STATUS and refresh the mode line."
  (setq etackle--status status)
  (etackle--update-mode-line))

(defun etackle--update-mode-line ()
  "Refresh the status indicator in the chat buffer's mode line."
  (let ((status
         (pcase etackle--status
           ('starting "starting")
           ('idle "ready")
           ('running (format "running (%s)" (or etackle--phase "working")))
           (_ "dead"))))
    (setq mode-line-process
          (concat " [" status "]"
                  (if etackle--tokens (format " %s" etackle--tokens) "")))
    (force-mode-line-update)))

(defun etackle--update-usage (data)
  "Record token usage from a `usage' event."
  (let ((input (map-elt data 'input_tokens))
        (output (map-elt data 'output_tokens)))
    (when (or input output)
      (setq etackle--tokens
            (format "%s in / %s out" (or input "?") (or output "?")))
      (etackle--update-mode-line))))

(provide 'etackle)
;;; etackle.el ends here
