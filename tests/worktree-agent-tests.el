;;; worktree-agent-tests.el --- Chats across working copies -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'package)
(defconst my-wta-config (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(setq user-emacs-directory (file-name-as-directory (file-truename (make-temp-file "emacs-wt-agent-" t)))
      package-user-dir (expand-file-name "elpa" my-wta-config))
(package-initialize)
(load (expand-file-name "projects.el" my-wta-config) nil t)
(load (expand-file-name "pi-panel.el" my-wta-config) nil t)

(defconst my-wta-real-start-chat (symbol-function 'my-pi-start-chat)
  "The unstubbed starter, to check it refuses unavailable copies before any agent starts.")

(defmacro my-wta-test (&rest body)
  "BODY sees ROOT (original), COPY-DIR (copy c1), a chat x in the copy and STARTED."
  `(let* ((user-emacs-directory (file-name-as-directory (file-truename (make-temp-file "wta-" t))))
          (my-pi-history-db nil)
          (root (expand-file-name "orig/" user-emacs-directory))
          (copy-dir (expand-file-name "copy/" user-emacs-directory))
          (my-pi-accepted-contexts (make-hash-table :test #'equal))
          started switched)
     (make-directory root t) (make-directory (expand-file-name ".git" copy-dir) t)
     (unwind-protect
         (cl-letf (((symbol-function 'my-pi-start-chat) (lambda (r &rest _) (push r started) 'agent))
                   ((symbol-function 'my-wt-switch) (lambda (copy) (push (plist-get copy :directory) switched) copy)))
           (let ((orig (my-wt-register root)))
             (my-wt-write (lambda (db) (sqlite-execute db "INSERT INTO working_copies(copy_id,project_id,role,directory,vcs_root,owned,state,vcs,created_at)
                                                           VALUES ('c1',?,'copy',?,?,1,'ready','git','2026')"
                                                           (list (plist-get orig :project_id) copy-dir copy-dir))))
             (my-pi-history-register "x" copy-dir)
             (my-pi-history-update "x" :title "Copy chat" :branch "feature")
             (sqlite-execute (my-pi-history-open) "INSERT INTO messages VALUES ('x','m1',0,'user',NULL,'offline question')")
             ,@body))
       (dolist (b (buffer-list)) (when (string-prefix-p "*Pi transcript" (buffer-name b)) (kill-buffer b)))
       (delete-other-windows)
       (when my-pi-history-db (sqlite-close my-pi-history-db))
       (delete-directory user-emacs-directory t))))

(ert-deftest my-wta-deleted-copy-opens-offline-without-agent ()
  (my-wta-test
   (my-wt-update "c1" :state "deleted")
   (delete-directory copy-dir t)
   (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab))) root)
   (let ((buffer (my-pi-open-chat root "x")))
     (should (bufferp buffer))
     (should (with-current-buffer buffer (string-match-p "offline question" (buffer-string))))
     (should (with-current-buffer buffer (null my-pi-root)))
     (should (equal (buffer-local-value 'my-pi-offline-root buffer) copy-dir))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
       (should (equal (cadr (should-error (my-pi-history-show copy-dir) :type 'user-error))
                      "Chat picker requires a graphical Emacs")))
     (let (picked-root)
       (with-current-buffer buffer
         (let ((action (lookup-key (get-text-property 0 'local-map header-line-format)
                                   [header-line mouse-1])))
           (should (commandp action))
           (cl-letf (((symbol-function 'my-pi-history-show) (lambda (root) (setq picked-root root))))
             (call-interactively action))))
       (should (equal picked-root copy-dir)))
     (let (new-root)
       (with-current-buffer buffer
         (should (< (length header-line-format) 30))
         (should (eq (get-text-property (1+ (point-min)) 'face) 'agent-shell-chat-me-label))
         (should (text-property-any (point-min) (point-max) 'face 'my-pi-offline-label))
         (should (string-search " Chat Name \nCopy chat\n\n" (buffer-string)))
         (should (string-search " Branch \nfeature\n\n" (buffer-string)))
         (should (string-search (concat " Path \n" copy-dir "\n\n") (buffer-string)))
         (save-excursion
           (goto-char (point-min))
           (search-forward " Path \n")
           (should (eq (char-after) ?/))
           (should (equal (get-text-property (point) 'line-prefix) "  "))
           (should (equal (get-text-property (point) 'wrap-prefix) "  ")))
         (let ((action (lookup-key (get-text-property (string-search "+" header-line-format)
                                                     'local-map header-line-format)
                                   [header-line mouse-1])))
           (should (commandp action))
           (cl-letf (((symbol-function 'my-pi-new-chat) (lambda (root) (setq new-root root))))
             (call-interactively action))))
       (should (equal new-root root)))
     (should-not started)
     (should-not switched)
     (should-not (file-exists-p copy-dir)))))

(ert-deftest my-wta-chat-of-other-copy-runs-in-its-own-copy ()
  (my-wta-test
   (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "feature" :revision nil))))
     (my-pi-open-chat root "x")
     (should (equal switched (list copy-dir)))
     (should (equal started (list copy-dir))))))

(ert-deftest my-wta-offline-transcript-uses-chat-labels-and-markdown ()
  (my-wta-test
   (let ((body "## Result\n\nA **clear** answer with `code`.\n\n- First item\n- Second item\n\n```text\n**literal**\n```\n"))
     (sqlite-execute (my-pi-history-open)
                     "INSERT INTO messages VALUES ('x','m2',1,'assistant',NULL,?)" (list body))
     (my-wt-update "c1" :state "deleted")
     (delete-directory copy-dir t)
     (let ((buffer (my-pi-open-chat root "x")))
       (with-current-buffer buffer
         (should buffer-read-only)
         (should visual-line-mode)
         (should (text-property-any (point-min) (point-max) 'face 'agent-shell-chat-me-label))
         (should (text-property-any (point-min) (point-max) 'face 'agent-shell-chat-agent-label))
         (goto-char (point-min))
         (search-forward "clear")
         (should (memq 'agent-shell-markdown-bold
                       (ensure-list (get-text-property (1- (point)) 'face))))
         (should-not (string-search "**clear**" (buffer-string)))
         (should (string-search "**literal**" (buffer-string))))
       (should (equal (caar (sqlite-select (my-pi-history-open)
                                          "SELECT body FROM messages WHERE session_id='x' AND message_id='m2'")) body))
       (should-not started)
       (should-not switched)
       (should-not (file-exists-p copy-dir))))))

(ert-deftest my-wta-branch-change-is-confirmed-before-continuing ()
  (my-wta-test
   (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "other" :revision nil)))
             ((symbol-function 'yes-or-no-p) (lambda (prompt) (should (string-match-p "feature.*other" prompt)) nil)))
     (should (bufferp (my-pi-open-chat copy-dir "x")))
     (should-not started))
   (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "other" :revision nil)))
             ((symbol-function 'yes-or-no-p) (lambda (_) t)))
     (my-pi-open-chat copy-dir "x")
     (should (equal started (list copy-dir))))))

(ert-deftest my-wta-unrelated-project-chat-is-rejected ()
  (my-wta-test
   (let ((other (expand-file-name "other/" user-emacs-directory)))
     (make-directory other)
     (my-wt-register other)
     (should-error (my-pi-open-chat other "x") :type 'user-error))))

(ert-deftest my-wta-background-permission-does-not-steal-focus ()
  (my-wta-test
   (let ((window (selected-window)) (shown (window-buffer)))
     (with-temp-buffer
       (setq-local my-pi-root copy-dir)
       (cl-letf (((symbol-function 'agent-shell-session-id) (lambda (&rest _) "x"))
                 ((symbol-function 'my-pi-update-headers) #'ignore))
         (my-pi-on-event '((:event . permission-request)))))
     (should (eq (selected-window) window))
     (should (eq (window-buffer) shown))
     (should (equal (plist-get (my-pi-history-get "x") :turn_state) "needs-input"))
     ;; The other copy's request shows as attention in the original's tree header.
     (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) root)
     (clrhash my-wt-attention-cache)
     (should (string-match-p "●" (my-wt-header))))))

(defmacro my-wta-agent (&rest body)
  "Run BODY in a fake idle Pi buffer bound to chat x in COPY-DIR; SENT counts submissions."
  `(let ((agent (generate-new-buffer "*wta-agent*")) (sent 0) (asked 0))
     (unwind-protect
         (with-current-buffer agent
           (setq major-mode 'agent-shell-mode default-directory copy-dir)
           (setq-local my-pi-root copy-dir)
           (cl-letf (((symbol-function 'agent-shell-session-id) (lambda (&rest _) "x")))
             (cl-flet ((submit () (with-current-buffer agent (my-pi-guard-submit (lambda () (cl-incf sent))))))
               ,@body)))
       (kill-buffer agent))))

(defun my-wta-sha (char) (make-string 40 char))

(ert-deftest my-wta-delete-with-ordinary-buffers-reaches-confirmation ()
  (my-wta-test
   (with-temp-buffer
     (setq default-directory copy-dir major-mode 'go-ts-mode)
     (rename-buffer "wta-source.go" t)
     (should-not (my-pi-live-p (current-buffer)))
     (setq major-mode 'dired-mode)
     (should-not (my-pi-live-p (current-buffer)))
     (let (asked)
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (setq asked t) nil))
                 ((symbol-function 'my-wt-delete) (lambda (&rest _) (ert-fail "Deletion was not confirmed"))))
         (my-wt-picker-delete (my-wt-copy "c1"))
         (should asked))))))

(defmacro my-wta-client (&rest body)
  "Run BODY with a real ACP transport to cat, without starting an AI session."
  `(let* ((agent (generate-new-buffer "wta-client"))
          (default-directory copy-dir)
          (client (acp-make-client :command "cat" :context-buffer agent)))
     (unwind-protect
         (progn
           (acp--start-client :client client)
           (with-current-buffer agent
             (setq major-mode 'agent-shell-mode default-directory copy-dir)
             (setq-local agent-shell--state (list (cons :client client) (cons :tool-calls nil))
                         shell-maker--config (make-shell-maker-config :name "agent")
                         shell-maker--busy nil))
           ,@body)
       (acp-shutdown :client client)
       (when (buffer-live-p agent) (kill-buffer agent)))))

(ert-deftest my-wta-delete-allows-idle-agent-stderr ()
  (my-wta-test
   (my-wta-client
    (should (my-pi-live-p agent))
    (should (eq (agent-shell-status :shell-buffer agent) 'ready))
    (should-not (my-wt-delete-blockers (my-wt-copy "c1"))))))

(ert-deftest my-wta-delete-still-blocks-busy-and-blocked-agents ()
  (my-wta-test
   (my-wta-client
    (with-current-buffer agent (setq shell-maker--busy t))
    (dolist (blocked '(nil t))
      (with-current-buffer agent
        (map-put! agent-shell--state :tool-calls
                  (when blocked '(("tool" . ((:permission-request-id . "permission")))))))
      (should (eq (agent-shell-status :shell-buffer agent) (if blocked 'blocked 'busy)))
      (should (seq-some (lambda (reason) (string-match-p "An agent task is running" reason))
                        (my-wt-delete-blockers (my-wt-copy "c1"))))))))

(ert-deftest my-wta-delete-still-blocks-unowned-stderr-process ()
  (my-wta-test
   (my-wta-client
    (with-temp-buffer
      (rename-buffer "acp-client-stderr(unowned)" t)
      (setq default-directory copy-dir)
      (let ((process (make-pipe-process :name "unowned stderr" :buffer (current-buffer) :noquery t)))
        (unwind-protect
            (should (seq-some (lambda (reason) (string-match-p "Processes still run there:.*unowned stderr" reason))
                              (my-wt-delete-blockers (my-wt-copy "c1"))))
          (delete-process process)))))))

(ert-deftest my-wta-live-prompt-requires-confirmation-on-branch-change ()
  (my-wta-test
   (should (advice-member-p #'my-pi-guard-submit 'shell-maker-submit))
   (should (advice-member-p #'my-pi-guard-submit 'agent-shell--busy-submit))
   (let ((now '(:branch "other" :revision nil)) (answer nil))
     (my-wta-agent
      (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) now))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf asked) answer)))
        ;; Opening the live chat keeps it visible, but does not unlock prompts.
        (let ((my-pi-sessions (make-hash-table :test #'equal)))
          (puthash "x" agent my-pi-sessions)
          (cl-letf (((symbol-function 'my-pi-live-p) (lambda (b) (eq b agent)))
                    ((symbol-function 'my-pi-display-buffer) (lambda (&rest _) (selected-window))))
            (should (eq (my-pi-open-chat copy-dir "x") agent))))
        (should-error (submit) :type 'user-error)          ; declined: nothing sent
        (should (= sent 0)) (should (= asked 1))
        (should-not started)
        (setq answer t)
        (submit)
        (should (= sent 1)) (should (= asked 2))
        (should (equal (buffer-local-value (quote default-directory) agent) copy-dir)) ; still its own copy
        (submit)                                          ; accepted context is remembered
        (should (= sent 2)) (should (= asked 2))
        (should (equal (plist-get (my-pi-history-get "x") :branch) "feature")) ; metadata kept
        (setq now '(:branch "third" :revision nil) answer nil)
        (should-error (submit) :type 'user-error)
        (should (= sent 2)))))))

(ert-deftest my-wta-unchanged-and-detached-contexts ()
  (my-wta-test
   (let ((now (list :branch "feature" :revision (my-wta-sha ?b))))
     (my-wta-agent
      (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) now))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf asked) nil)))
        (submit) (submit)                                  ; commits on the same branch are fine
        (should (= sent 2)) (should (= asked 0))
        ;; A chat begun detached is pinned to its commit, not to "no branch".
        (my-pi-history-update "x" :branch "" :revision (my-wta-sha ?a))
        (setq now (list :branch nil :revision (my-wta-sha ?a)))
        (submit) (should (= asked 0))
        (setq now (list :branch nil :revision (my-wta-sha ?c)))
        (should-error (submit) :type 'user-error) (should (= asked 1))
        ;; Older records stored a branch name as the revision: unknown, so ask.
        (my-pi-history-update "x" :revision "main")
        (setq now (list :branch nil :revision (my-wta-sha ?a)))
        (should-error (submit) :type 'user-error) (should (= asked 2))
        ;; An unreadable context is never assumed safe.
        (my-pi-history-update "x" :branch "feature")
        (setq now nil)
        (should-error (submit) :type 'user-error) (should (= asked 3))
        (should (= sent 3)))))))

(ert-deftest my-wta-unavailable-selected-copy-gets-no-agent-work ()
  (my-wta-test
   (delete-directory (expand-file-name ".git" copy-dir))   ; e.g. an unmounted, empty root
   (let ((buffer (my-pi-open-chat copy-dir "x")))           ; already the selected root
     (should (with-current-buffer buffer (string-match-p "offline question" (buffer-string))))
     (should-not started)
     (should-not switched))
   (should-error (funcall my-wta-real-start-chat copy-dir) :type 'user-error)
   (my-wta-agent
    (should-error (submit) :type 'user-error)
    (should (= sent 0)))
   (make-directory (expand-file-name ".git" copy-dir))     ; available again
   (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "feature" :revision nil))))
     (my-pi-open-chat copy-dir "x")
     (should (equal started (list copy-dir))))))

(ert-deftest my-wta-new-chat-records-commit-id ()
  (my-wta-test
   (let* ((repo (expand-file-name "repo/" user-emacs-directory)))
     (make-directory repo)
     (dolist (args '(("init" "-q" "-b" "main") ("config" "user.email" "t@example.com") ("config" "user.name" "T")
                     ("config" "commit.gpgsign" "false") ("commit" "-q" "--allow-empty" "-m" "init")))
       (should (zerop (car (apply #'my-wt-call repo "git" args)))))
     (let ((sha (string-trim (cdr (my-wt-call repo "git" "rev-parse" "HEAD")))))
       (my-wt-register repo)
       (my-pi-history-register "fresh" repo)
       (my-pi-record-context "fresh" repo)
       (should (equal (plist-get (my-pi-history-get "fresh") :branch) "main"))
       (should (equal (plist-get (my-pi-history-get "fresh") :revision) sha))
       ;; A resumed older chat keeps having no recorded context.
       (my-pi-history-register "old" repo)
       (my-pi-history-update "old" :first_prompt_at "2026-01-01")
       (my-pi-record-context "old" repo)
       (should-not (plist-get (my-pi-history-get "old") :branch))))))

;;; Queued prompts through the real queue processor

(defmacro my-wta-queue (pending draft &rest body)
  "BODY runs in a Pi shell with PENDING prompts queued and DRAFT typed at the prompt.
The real `agent-shell--prompt-queue-process-next' and insertion code run with
the working-copy guard installed; only the final send is faked, inside the
guard, recording each submitted text in SENT."
  `(let ((shell (generate-new-buffer "*wta-queue*")) (sent nil)
         (agent-shell-persistent-prompt-enabled t))
     (cl-labels ((fake-send ()
                   (let ((start (agent-shell--prompt-input-start)))
                     (push (buffer-substring start (point-max)) sent)
                     (delete-region start (point-max)))))
       (advice-add 'shell-maker-submit :override #'fake-send '((depth . 100)))
       (unwind-protect
           (with-current-buffer shell
             (setq major-mode 'agent-shell-mode default-directory copy-dir)
             (setq-local my-pi-root copy-dir
                         shell-maker--config (make-shell-maker-config :name "agent")
                         agent-shell--state (list (cons :session (list (cons :id "x")))
                                                  (cons :pending-prompts ,pending)))
             (insert "Pi> ")
             (setq-local comint-last-prompt (cons (copy-marker (point-min)) (copy-marker (point))))
             (insert ,draft)
             (cl-letf (((symbol-function 'agent-shell-session-id) (lambda (&rest _) "x")))
               ,@body))
         (advice-remove 'shell-maker-submit #'fake-send)
         (kill-buffer shell)))))

(defun my-wta-input ()
  (buffer-substring (agent-shell--prompt-input-start) (point-max)))

(ert-deftest my-wta-refused-queue-keeps-draft-and-prompts ()
  (my-wta-test
   (should (advice-member-p #'my-pi-guard-queue 'agent-shell--prompt-queue-process-next))
   (let ((first (propertize "first queued" 'face 'bold)) (draft (propertize "half typed" 'face 'italic)))
     (my-wta-queue (list first "second queued") draft
      (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "other" :revision nil)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (agent-shell--prompt-queue-process-next))
      (should-not sent)
      (should (equal (my-wta-input) draft))
      (should (eq (get-text-property 0 'face (my-wta-input)) 'italic))
      (let ((pending (map-elt agent-shell--state :pending-prompts)))
        (should (equal pending (list first "second queued")))
        (should (eq (car pending) first)))))))

(ert-deftest my-wta-unavailable-copy-keeps-queue ()
  (my-wta-test
   (delete-directory (expand-file-name ".git" copy-dir))
   (my-wta-queue (list "queued") "draft"
    (agent-shell--prompt-queue-process-next)
    (should-not sent)
    (should (equal (my-wta-input) "draft"))
    (should (equal (map-elt agent-shell--state :pending-prompts) '("queued"))))))

(ert-deftest my-wta-failed-queue-submission-is-restored ()
  (my-wta-test
   ;; The early check passes, but the send itself fails before anything goes out.
   (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "feature" :revision nil))))
     (let ((draft (propertize "draft" 'face 'italic)))
       (my-wta-queue (list "one" "two") draft
        (advice-add 'shell-maker-submit :override (lambda () (error "Simulated send failure")) '((depth . 100) (name . wta-fail)))
        (unwind-protect (agent-shell--prompt-queue-process-next)
          (advice-remove 'shell-maker-submit 'wta-fail))
        (should (equal (my-wta-input) draft))
        (should (eq (get-text-property 0 'face (my-wta-input)) 'italic))
        (should (equal (map-elt agent-shell--state :pending-prompts) '("one" "two"))))))))

(ert-deftest my-wta-accepted-queue-sends-once-and-restores-draft ()
  (my-wta-test
   (let ((asked 0))
     (cl-letf (((symbol-function 'my-wt-context-now) (lambda (_) '(:branch "other" :revision nil)))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf asked) t)))
       (let ((agent-shell-prompt-queue-merge t))
         (my-wta-queue (list "one" "two") "draft"
          (agent-shell--prompt-queue-process-next)
          (should (equal sent '("one\n\ntwo")))         ; merged, exactly once
          (should (= asked 1))                          ; one question for the batch
          (should-not (map-elt agent-shell--state :pending-prompts))
          (should (equal (my-wta-input) "draft"))))
       (let ((agent-shell-prompt-queue-merge nil))
         (my-wta-queue (list "one" "two") ""
          (agent-shell--prompt-queue-process-next)
          (should (equal sent '("one")))                ; merge off: first only, in order
          (should (equal (map-elt agent-shell--state :pending-prompts) '("two")))))))))
