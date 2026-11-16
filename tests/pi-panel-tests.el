;;; pi-panel-tests.el --- Pi panel regression checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'package)
(let* ((root (expand-file-name ".." (file-name-directory load-file-name)))
       (package-user-dir (expand-file-name "elpa" root))
       (user-emacs-directory (make-temp-file "pi-mode-line-" t)))
  (unwind-protect
      (progn
        (package-initialize)
        (load (expand-file-name "pi-panel.el" root) nil t))
    (delete-directory user-emacs-directory t)))

(ert-deftest my-pi-notification-styles-info-and-warnings ()
  (dolist (level '("info" "warning" "error" nil))
    (let* ((notification
            `((method . "session/update")
              (params (update (sessionUpdate . "agent_message_chunk")
                              (content (type . "text") (text . "Skill catalog: test"))
                              (_meta (piAcp (notify (level . ,level))))))))
           (adapted (agent-shell-pi--notification-adapter :acp-notification notification))
           (text (map-nested-elt adapted '(params update content text))))
      (should (equal text "Skill catalog: test"))
      (should (eq (get-text-property 0 'face text)
                  (and (member level '("info" "warning")) 'my-pi-notification)))
      (should-not (get-text-property
                   0 'face (map-nested-elt notification '(params update content text)))))))

(ert-deftest my-pi-notification-style-survives-rendering-without-leaking ()
  (dolist (suffix '("" "\n\n"))
    (with-temp-buffer
      (let* ((notification
              `((params (update (sessionUpdate . "agent_message_chunk")
                                (content (type . "text")
                                         (text . ,(concat "Handshake completed. **Ready**" suffix)))
                                (_meta (piAcp (notify (level . "info"))))))))
             (text (map-nested-elt (my-pi-style-notification notification)
                                   '(params update content text))))
        ;; Exercise both batched chunks and a later streamed answer.
        (dolist (chunk (list (concat "Before.\n\n" text)
                             (concat "\nBetween.\n" text "\nBatched answer.")
                             "\nLater answer.\n"))
          (let* ((inhibit-read-only t)
                 (range (agent-shell-ui-update-fragment
                         (agent-shell-ui-make-fragment-model
                          :namespace-id 1 :block-id "agent_message_chunk" :body chunk)
                         :append t)))
            (save-restriction
              (narrow-to-region (map-nested-elt range '(:body :start))
                                (map-nested-elt range '(:body :end)))
              (agent-shell--render-markdown :render-images nil :external-renderers nil))))
        (goto-char (point-min))
        (search-forward "Handshake")
        (should (eq (get-text-property (1- (point)) 'face) 'my-pi-notification))
        (dolist (answer '("Before" "Between" "Batched answer" "Later answer"))
          (goto-char (point-min))
          (search-forward answer)
          (should-not (get-text-property (1- (point)) 'face))
          (should-not (get-text-property (1- (point)) 'font-lock-face)))))))

(ert-deftest my-pi-picker-flattens-multiline-titles ()
  (with-temp-buffer
    (my-pi-history-mode)
    (setq my-pi-picker-root "/project/"
          my-pi-picker-results '((:id "chat" :project_root "/project/"
                                 :title "Alert:\r\n \n\tklg06-host gpu-i  " :created_at "2026")))
    (cl-letf (((symbol-function 'my-wt-copy-at) (lambda (_) nil)))
      (my-pi-picker-render))
    (goto-char (point-min))
    (search-forward "klg06-host")
    (let ((button (button-at (1- (point)))))
      (should (equal (button-label button) "Alert: klg06-host gpu-i"))
      (should (equal (get-text-property (point) 'pi-chat-id) "chat"))
      (beginning-of-line)
      (should (looking-at "  Alert: klg06-host")))))

(ert-deftest my-pi-picker-labels-current-original-and-other-copies ()
  (let ((my-pi-picker-root "/original/")
        (copy '(:directory "/original/" :role "original" :state "ready")))
    (cl-letf (((symbol-function 'my-wt-copy-at) (lambda (_) copy))
              ((symbol-function 'my-wt-label) (lambda (_) "CLOUD-123")))
      (let ((label (my-pi-picker-copy-label '(:project_root "/original/"))))
        (should (equal label "  [⌂ CLOUD-123]"))
        (should (eq (get-text-property 2 'face label) 'my-pi-history-branch))
        (should (equal (get-text-property 2 'help-echo label) "Original\n/original/")))
      (setq copy '(:directory "/copy/" :role "copy" :state "deleted"))
      (let ((label (my-pi-picker-copy-label '(:project_root "/copy/"))))
        (should (equal label "  [⧉ CLOUD-123, deleted]"))
        (should (eq (get-text-property 2 'face label) 'my-pi-history-branch))
        (should (equal (get-text-property 2 'help-echo label) "Working copy\n/copy/"))))))

(ert-deftest my-pi-mode-line-keeps-one-interactive-thinking-control ()
  ;; Other agents and legacy pi versions must retain their session mode.
  (dolist (case '((pi t 1) (other t 2) (pi nil 1)))
    (pcase-let ((`(,agent ,thought-option ,count) case))
      (with-temp-buffer
        (setq major-mode 'agent-shell-mode)
        (setq-local agent-shell--state
                    `((:buffer . ,(current-buffer))
                      (:agent-config . ((:identifier . ,agent)))
                      (:session . ((:mode-id . "medium")
                                   (:modes . (((:id . "medium") (:name . "Thinking: medium"))))
                                   (:config-options .
                                    ,(when thought-option
                                       '(((:id . "thought_level")
                                          (:category . "thought_level")
                                          (:current-value . "medium")
                                          (:options . (((:value . "medium")
                                                        (:name . "Thinking: medium"))))))))))))
        (my-pi-setup-mode-line)
        (let* ((before (copy-tree agent-shell--state))
               (line (eval (cadr (cadr mode-line-format)) t))
               (start (string-match "Thinking" line))
               (map (and start (get-text-property start 'local-map line))))
          (should (= count (1- (length (split-string line "Thinking")))))
          (should (keymapp (lookup-key map [mode-line mouse-1])))
          (when thought-option
            (should (eq (get-text-property start 'face line) 'agent-shell-thought-level))
            (should (lookup-key (lookup-key map [mode-line mouse-1]) [thought-level-medium])))
          (should (equal before agent-shell--state)))))))

(ert-deftest my-pi-reloaded-buffer-tracks-running-turns ()
  (let* ((user-emacs-directory (make-temp-file "pi-reload-" t))
         (my-pi-history-db nil)
         (my-pi-sessions (make-hash-table :test #'equal))
         (process (make-pipe-process :name "pi-test" :noquery t)))
    (unwind-protect
        (with-temp-buffer
          ;; agent-shell-reload creates a fresh buffer without my-pi-start-chat.
          (setq major-mode 'agent-shell-mode default-directory user-emacs-directory)
          (setq-local shell-maker--config (make-shell-maker-config :name "Agent")
                      agent-shell--state
                      (agent-shell--make-state :buffer (current-buffer)
                                               :agent-config '((:identifier . pi))))
          (setf (map-elt agent-shell--state :client) `((:process . ,process))
                (map-elt (map-elt agent-shell--state :session) :id) "reloaded")
          (my-pi-attach)
          (should (equal my-pi-root (my-pi-history-root default-directory)))
          (my-pi-attach)
          (should (= 1 (length (map-elt agent-shell--state :event-subscriptions))))
          (agent-shell--emit-event :event 'input-submitted :data '((:prompt . "hello")))
          (should (equal (plist-get (my-pi-history-get "reloaded") :turn_state) "running"))
          (should (string-match-p "1 running" my-pi-header))
          (cl-letf (((symbol-function 'my-pi-history-refresh) #'ignore))
            (agent-shell--emit-event :event 'turn-complete :data '((:stop-reason . "end_turn"))))
          (should (string-match-p "0 running" my-pi-header))
          ;; Loading the fix into an already busy buffer repairs missed input events.
          (setq-local shell-maker--busy t)
          (my-pi-attach)
          (should (string-match-p "1 running" my-pi-header)))
      (delete-process process)
      (when my-pi-history-db (sqlite-close my-pi-history-db))
      (delete-directory user-emacs-directory t))))

